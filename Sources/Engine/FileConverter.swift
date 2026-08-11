import AppKit
import CoreText
import Foundation
import UniformTypeIdentifiers

/// Converts shelved files into other formats.
///
/// Everything here is done with what the system already ships: `sips` for
/// images, `textutil` for documents, `afconvert` for audio, and CoreGraphics
/// where a real renderer is needed. No frameworks, no helpers, no bundled
/// binaries — and nothing runs until a conversion is actually asked for.
///
/// The offered targets are deliberately narrow. A menu that lists every format
/// a tool *can* emit is a menu nobody reads; these are the conversions people
/// actually want, per family, with the source's own format left out.
enum FileConverter {
    struct Target: Identifiable, Hashable {
        /// Shown on the button — "PNG", "PDF".
        let label: String
        let ext: String
        var id: String { ext }
    }

    /// What a set of files can turn into. Empty unless every file is of the same
    /// family, which is what makes converting a multi-selection meaningful.
    static func targets(for urls: [URL]) -> [Target] {
        guard !urls.isEmpty else { return [] }
        let families = Set(urls.map { family(of: $0) })
        guard families.count == 1, let family = families.first, family != .unsupported else { return [] }

        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        // Nothing converts to what it already is — unless the selection is
        // mixed, in which case normalising to one format is the point.
        return family.targets.filter { extensions.count > 1 || !extensions.contains($0.ext) }
    }

    enum Family: Hashable {
        case image
        case document
        case audio
        case unsupported

        var targets: [Target] {
            switch self {
            case .image:
                return [.init(label: "PNG", ext: "png"),
                        .init(label: "JPEG", ext: "jpg"),
                        .init(label: "HEIC", ext: "heic"),
                        .init(label: "TIFF", ext: "tiff"),
                        .init(label: "PDF", ext: "pdf")]
            case .document:
                return [.init(label: "PDF", ext: "pdf"),
                        .init(label: "DOCX", ext: "docx"),
                        .init(label: "RTF", ext: "rtf"),
                        .init(label: "HTML", ext: "html"),
                        .init(label: "TXT", ext: "txt")]
            case .audio:
                return [.init(label: "M4A", ext: "m4a"),
                        .init(label: "WAV", ext: "wav"),
                        .init(label: "AIFF", ext: "aiff")]
            case .unsupported:
                return []
            }
        }
    }

    static func family(of url: URL) -> Family {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp":
            return .image
        case "txt", "md", "markdown", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "csv", "json":
            return .document
        case "wav", "aiff", "aif", "m4a", "mp3", "caf", "aac":
            return .audio
        default:
            return .unsupported
        }
    }

    enum ConversionError: LocalizedError {
        case toolFailed(String, String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let message):
                return message.isEmpty ? "\(tool) could not convert this." : message
            case .unreadable(let name):
                return "\(name) could not be read."
            }
        }
    }

    /// Converts each file and returns the results. Off the main actor: every
    /// path here is either a subprocess or a render.
    nonisolated static func convert(_ urls: [URL], to target: Target) throws -> [URL] {
        try urls.map { try convert($0, to: target) }
    }

    nonisolated static func convert(_ url: URL, to target: Target) throws -> URL {
        let output = destination(for: url, ext: target.ext)
        switch family(of: url) {
        case .image:
            if target.ext == "pdf" {
                try imageToPDF(url, output: output)
            } else {
                try run("/usr/bin/sips",
                        ["-s", "format", sipsFormat(for: target.ext), url.path, "--out", output.path])
            }
        case .document:
            if target.ext == "pdf" {
                try documentToPDF(url, output: output)
            } else {
                try run("/usr/bin/textutil",
                        ["-convert", target.ext, url.path, "-output", output.path])
            }
        case .audio:
            try run("/usr/bin/afconvert",
                    ["-f", audioContainer(for: target.ext), "-d", audioFormat(for: target.ext),
                     url.path, output.path])
        case .unsupported:
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        return output
    }

    // MARK: - Renderers

    /// One image, one page, at the image's own size.
    private nonisolated static func imageToPDF(_ url: URL, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ConversionError.unreadable(url.lastPathComponent) }

        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    /// Text and word-processing documents, paginated onto US Letter.
    ///
    /// `textutil` has no PDF output and `sips` does not do text, so this is done
    /// with CoreText directly: read the document into an attributed string —
    /// which covers txt, rtf, doc and docx — then let a framesetter walk it page
    /// by page until the content runs out.
    private nonisolated static func documentToPDF(_ url: URL, output: URL) throws {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        guard let text = try? NSAttributedString(url: url, options: options,
                                                 documentAttributes: nil),
              text.length > 0
        else { throw ConversionError.unreadable(url.lastPathComponent) }

        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54
        let textBox = page.insetBy(dx: margin, dy: margin)

        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var start = 0
        while start < text.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textBox, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            // A page that fits nothing would loop forever on a single
            // unbreakable run; stop instead of hanging.
            guard visible.length > 0 else { break }
            start += visible.length
        }
        context.closePDF()
    }

    // MARK: - Tools

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw ConversionError.toolFailed((tool as NSString).lastPathComponent,
                                             message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private nonisolated static func sipsFormat(for ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "jpeg"
        case "tiff", "tif": return "tiff"
        default: return ext
        }
    }

    private nonisolated static func audioContainer(for ext: String) -> String {
        switch ext {
        case "m4a": return "m4af"
        case "wav": return "WAVE"
        default: return "AIFF"
        }
    }

    private nonisolated static func audioFormat(for ext: String) -> String {
        // AAC for m4a; 16-bit little-endian PCM for wave, big-endian for aiff.
        switch ext {
        case "m4a": return "aac"
        case "wav": return "LEI16"
        default: return "BEI16"
        }
    }

    /// Next to the original when that is writable — a converted file belongs
    /// beside the one it came from — and in scratch when it is not, which is the
    /// case for anything dragged out of a read-only location.
    private nonisolated static func destination(for url: URL, ext: String) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let writable = FileManager.default.isWritableFile(atPath: folder.path)
        let directory = writable ? folder : IngestionManager.scratch

        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
