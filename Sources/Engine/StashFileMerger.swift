import AppKit
import Foundation
import PDFKit

/// Combines several shelved files into one.
///
/// ## The rule
///
/// A merge of like things stays in their own format; a merge of unlike things
/// becomes a PDF, because PDF is the only format that can hold a photo, a
/// spreadsheet export and someone else's contract on consecutive pages.
///
/// ```
///   all plain text   ->  one .txt, concatenated with a named separator
///   all PDFs         ->  one .pdf, pages appended in shelf order
///   all images       ->  one .pdf, a page per image at the image's own size
///   anything else    ->  one .pdf, everything rendered onto US Letter
/// ```
///
/// Images get their own size in the all-images case and a letter page in the
/// mixed case, and that is deliberate rather than inconsistent. A contact sheet
/// of twenty photos should not have white bars down the sides of every page; a
/// document that alternates between a screenshot and two pages of text should not
/// change paper size halfway through.
///
/// ## What this does not re-implement
///
/// Paginating an attributed string onto PDF pages, and getting a `CGImage` into a
/// PDF at the right size, are both already solved in `FileConverter` — measured,
/// commented, and carrying a fix for the infinite loop an unbreakable run
/// produces. So the mixed path converts each non-PDF input to a one-file PDF
/// through those same renderers and appends its pages, rather than growing a
/// second copy of the same CoreText walk. It costs a temporary file per input and
/// buys exactly one implementation of the hard part.
///
/// Everything is off the main actor: every path here is a file read, a render, or
/// both.
enum StashFileMerger {
    // MARK: - What a selection is

    /// Which of the four merges applies.
    enum Plan: Equatable {
        /// Every input is plain text; the result is text.
        case text
        /// Every input is already a PDF.
        case pdf
        /// Every input is an image.
        case images
        /// Mixed, or contains something none of the above covers.
        case mixed

        /// What the button should say.
        var label: String {
            switch self {
            case .text: return "Combine into TXT"
            case .pdf, .images, .mixed: return "Combine into PDF"
            }
        }

        /// The extension the merged file gets.
        var ext: String { self == .text ? "txt" : "pdf" }
    }

    /// The kinds of input the merger can tell apart.
    ///
    /// Narrower than `FileConverter.Family` on purpose. That one answers "what
    /// can this be converted to", which groups `.txt` with `.docx` because
    /// `textutil` reads both. This one answers "can these be concatenated as
    /// themselves", and the answer for `.docx` is no — appending the bytes of two
    /// Word files produces a corrupt Word file, so a pair of them is a PDF merge.
    enum Ingredient: Equatable {
        case plainText
        case pdf
        case image
        /// Readable, but not concatenable as itself — rtf, docx, odt.
        case richText
        case unsupported
    }

    static func ingredient(of url: URL) -> Ingredient {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "csv", "json", "log", "xml", "yml", "yaml":
            return .plainText
        case "pdf":
            return .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp":
            return .image
        case "rtf", "rtfd", "doc", "docx", "odt", "html", "htm":
            return .richText
        default:
            return .unsupported
        }
    }

    /// Decides the merge for a set of files. Nil when there is nothing to merge:
    /// fewer than two inputs, or something in the set that cannot be read at all.
    ///
    /// **Two is the floor, and it is a real constraint rather than a UI nicety.**
    /// "Combine" on one file would produce a copy of that file under a new name,
    /// which is not a merge and is not what anybody pressing the button wants.
    static func plan(for urls: [URL]) -> Plan? {
        guard urls.count > 1 else { return nil }
        let kinds = Set(urls.map(ingredient(of:)))
        // One unreadable file poisons the batch. Silently dropping it would
        // produce a document missing a page the user selected, which is worse
        // than refusing — they can deselect it themselves and see what they did.
        guard !kinds.contains(.unsupported) else { return nil }
        if kinds == [.plainText] { return .text }
        if kinds == [.pdf] { return .pdf }
        if kinds == [.image] { return .images }
        return .mixed
    }

    enum MergeError: LocalizedError {
        case notEnough
        case unreadable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notEnough:
                return "Pick at least two files to combine."
            case .unreadable(let name):
                return "\(name) could not be read."
            case .writeFailed(let name):
                return "\(name) could not be written."
            }
        }
    }

    // MARK: - Entry points

    /// Combines a shelf selection.
    ///
    /// The signature the caller wants — it has `StashItem`s, not URLs — but the
    /// work happens on a detached task, so the items are reduced to their paths
    /// here on the main actor first. `StashItem` holds an `NSImage`-producing
    /// accessor and is not `Sendable`; its paths are.
    @MainActor
    static func combineStashItems(_ items: [StashItem], outputURL: URL? = nil) async throws -> URL {
        let urls = items.compactMap(\.fileURL)
        guard urls.count > 1 else { throw MergeError.notEnough }
        return try await Task.detached(priority: .userInitiated) {
            try combine(urls, outputURL: outputURL)
        }.value
    }

    /// Combines files already off the main actor.
    ///
    /// `outputURL` is honoured when given. When it is not, the result lands in
    /// the stash's scratch directory for the reason `FileConverter.destination`
    /// spells out: a merge is a thing held on the shelf until you drag it
    /// somewhere, not a file that appears uninvited in the folder you happened to
    /// be selecting from.
    nonisolated static func combine(_ urls: [URL], outputURL: URL? = nil) throws -> URL {
        guard let plan = plan(for: urls) else { throw MergeError.notEnough }
        let output = outputURL ?? destination(for: urls, ext: plan.ext)

        switch plan {
        case .text: try mergeText(urls, output: output)
        case .pdf: try mergePDFs(urls, output: output)
        case .images: try mergeImages(urls, output: output)
        case .mixed: try mergeMixed(urls, output: output)
        }
        return output
    }

    // MARK: - Text

    /// Concatenates plain text with a separator that names each source.
    ///
    /// The separator is not decoration. Twelve log files run together with no
    /// marks in between is one unreadable file; the whole point of merging them
    /// is to read them in order, which means knowing where each one started.
    ///
    /// Read as bytes and decoded per file, because a folder of logs is quite
    /// likely to hold one that is not UTF-8. A file that will not decode as UTF-8
    /// is retried as ISO Latin-1, which cannot fail — every byte sequence is
    /// valid Latin-1 — so a stray byte costs mojibake on one line instead of
    /// failing the merge.
    private nonisolated static func mergeText(_ urls: [URL], output: URL) throws {
        var merged = ""
        for url in urls {
            try autoreleasepool {
                guard let data = try? Data(contentsOf: url) else {
                    throw MergeError.unreadable(url.lastPathComponent)
                }
                let body = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                if !merged.isEmpty { merged += "\n\n" }
                merged += "===== \(url.lastPathComponent) =====\n\n"
                merged += body
                // Exactly one trailing newline per section, whether the source
                // had none or six, so the separators line up.
                if !body.hasSuffix("\n") { merged += "\n" }
            }
        }
        guard let data = merged.data(using: .utf8) else {
            throw MergeError.writeFailed(output.lastPathComponent)
        }
        do {
            try data.write(to: output, options: .atomic)
        } catch {
            throw MergeError.writeFailed(output.lastPathComponent)
        }
    }

    // MARK: - PDF

    /// Appends whole PDFs in order.
    private nonisolated static func mergePDFs(_ urls: [URL], output: URL) throws {
        let merged = PDFDocument()
        for url in urls {
            try autoreleasepool {
                guard let document = PDFDocument(url: url) else {
                    throw MergeError.unreadable(url.lastPathComponent)
                }
                append(document, to: merged)
            }
        }
        try write(merged, to: output)
    }

    /// One page per image, each at the image's own pixel size.
    ///
    /// Routed through `FileConverter.imageToPDF` rather than `PDFPage(image:)`.
    /// That initialiser sizes its page from the `NSImage`'s *point* size, which
    /// for a 2x screenshot is half the pixels — so a Retina capture merged that
    /// way comes out at 72 dpi and visibly soft. Going via CoreGraphics keeps the
    /// media box at the image's real dimensions, which is the behaviour this app
    /// already ships for a single image → PDF conversion.
    private nonisolated static func mergeImages(_ urls: [URL], output: URL) throws {
        try withStagingDirectory { staging in
            let merged = PDFDocument()
            for (index, url) in urls.enumerated() {
                try autoreleasepool {
                    let page = staging.appendingPathComponent("\(index).pdf")
                    try FileConverter.imageToPDF(url, output: page)
                    guard let document = PDFDocument(url: page) else {
                        throw MergeError.unreadable(url.lastPathComponent)
                    }
                    append(document, to: merged)
                }
            }
            try write(merged, to: output)
        }
    }

    /// The everything case: images, text, rich text and PDFs into one document.
    ///
    /// Each input becomes a small PDF of its own and its pages are appended.
    /// A PDF input is taken as it is; everything else goes through the renderer
    /// that already knows how to draw it.
    ///
    /// Images are normalised to US Letter here, unlike the all-images path: a
    /// document whose paper size changes between a screenshot and a page of text
    /// is one nobody can print.
    private nonisolated static func mergeMixed(_ urls: [URL], output: URL) throws {
        try withStagingDirectory { staging in
            let merged = PDFDocument()
            for (index, url) in urls.enumerated() {
                try autoreleasepool {
                    let source: URL
                    switch ingredient(of: url) {
                    case .pdf:
                        source = url
                    case .image:
                        let page = staging.appendingPathComponent("\(index).pdf")
                        try imageOnLetter(url, output: page)
                        source = page
                    case .plainText, .richText:
                        let page = staging.appendingPathComponent("\(index).pdf")
                        try FileConverter.documentToPDF(url, output: page)
                        source = page
                    case .unsupported:
                        throw MergeError.unreadable(url.lastPathComponent)
                    }
                    guard let document = PDFDocument(url: source) else {
                        throw MergeError.unreadable(url.lastPathComponent)
                    }
                    append(document, to: merged)
                }
            }
            try write(merged, to: output)
        }
    }

    /// One image, centred on a US Letter page, scaled to fit with a margin and
    /// its aspect ratio kept.
    ///
    /// Only ever scales *down*. Blowing a 200px icon up to fill a page would be
    /// a decision the merge has no business making — it would look like a broken
    /// render rather than a small image.
    private nonisolated static func imageOnLetter(_ url: URL, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0
        else { throw MergeError.unreadable(url.lastPathComponent) }

        var page = CGRect(x: 0, y: 0, width: Self.letterWidth, height: Self.letterHeight)
        let box = page.insetBy(dx: Self.letterMargin, dy: Self.letterMargin)
        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else {
            throw MergeError.writeFailed(output.lastPathComponent)
        }
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(box.width / size.width, box.height / size.height, 1)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: box.midX - drawn.width / 2,
                                       y: box.midY - drawn.height / 2,
                                       width: drawn.width,
                                       height: drawn.height))
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - Plumbing

    /// US Letter at 72 dpi, and the margin the text renderer already uses.
    private static let letterWidth: CGFloat = 612
    private static let letterHeight: CGFloat = 792
    private static let letterMargin: CGFloat = 54

    /// Copies every page of `document` onto the end of `merged`.
    ///
    /// `PDFDocument.insert(_:at:)` takes a `PDFPage`, so this walks the pages
    /// rather than the document. The page objects keep a reference to the
    /// document they came from, which is why the source document has to stay
    /// alive until the merged one is written — it is, because the write happens
    /// inside the same call that reads them all.
    private nonisolated static func append(_ document: PDFDocument, to merged: PDFDocument) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            merged.insert(page, at: merged.pageCount)
        }
    }

    private nonisolated static func write(_ document: PDFDocument, to output: URL) throws {
        guard document.pageCount > 0, document.write(to: output) else {
            throw MergeError.writeFailed(output.lastPathComponent)
        }
    }

    /// A temporary directory for the per-input PDFs, removed however the body
    /// exits. Under the system temporary directory rather than the stash's
    /// scratch, so a half-finished merge cannot leave pages sitting in the
    /// folder the shelf treats as its own.
    private nonisolated static func withStagingDirectory<R>(_ body: (URL) throws -> R) throws -> R {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("gruppen-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        return try body(staging)
    }

    /// `Combined-<n>-items.<ext>` in scratch, never overwriting.
    ///
    /// Named for what it is rather than after the first input: `report.pdf`
    /// holding six merged documents is a file that lies about itself the next
    /// time you look at it.
    private nonisolated static func destination(for urls: [URL], ext: String) -> URL {
        let base = "Combined-\(urls.count)-items"
        var candidate = IngestionManager.scratch.appendingPathComponent("\(base).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = IngestionManager.scratch.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
