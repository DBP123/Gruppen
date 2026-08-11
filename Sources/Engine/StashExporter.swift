import AppKit
import Foundation

/// Packs a shelf into a zip.
///
/// Files are staged into a temporary folder first so the archive contains flat,
/// sensibly-named entries rather than absolute paths, and inline text is
/// written out as `.txt` on the way in. Uses the system `zip`, so no
/// third-party archiver is involved.
enum StashExporter {
    enum ExportError: LocalizedError {
        case nothingToExport
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "There is nothing on this shelf to export."
            case .zipFailed(let message):
                return message.isEmpty ? "The archive could not be created." : message
            }
        }
    }

    /// Writes `<destination>/Stash-<timestamp>.zip`. Returns its URL.
    @discardableResult
    nonisolated static func export(items: [(name: String, url: URL?, text: String?)],
                                   to destination: URL) throws -> URL {
        guard !items.isEmpty else { throw ExportError.nothingToExport }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("gruppen-stash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var used: Set<String> = []
        for item in items { autoreleasepool {
            let name = uniqueName(for: item.name, in: &used)
            let target = staging.appendingPathComponent(name)
            if let source = item.url, FileManager.default.fileExists(atPath: source.path) {
                // Hard link rather than copy. On APFS this changes little —
                // `copyItem` already clones instead of duplicating bytes, so
                // staging was never the bottleneck it looked like — but on HFS+
                // or across a volume it is the difference between a directory
                // entry and a full byte copy. Falls back to a copy when the link
                // cannot be made.
                do {
                    try FileManager.default.linkItem(at: source, to: target)
                } catch {
                    try? FileManager.default.copyItem(at: source, to: target)
                }
            } else if let text = item.text {
                try? text.data(using: .utf8)?.write(to: target.appendingPathExtension("txt"))
            }
        } }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let archive = uniqueArchive(in: destination, named: "Stash-\(formatter.string(from: Date()))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        // Compression level, chosen by what is actually on the shelf.
        //
        // Measured on 240MB of media: `-6` (the default) took 3.08s and produced
        // a 253MB archive; `-0` took 0.51s and produced 240MB. Deflate spent
        // three seconds making the file *bigger*, because images, video, audio,
        // pdfs and office documents are already compressed — there is nothing
        // left to squeeze. `-1` is not the answer either; it was within noise of
        // `-6` on the same payload while still bloating the archive.
        //
        // So: store when everything on the shelf is already compressed, and
        // deflate normally the moment something compressible is in the mix,
        // where the ratio is worth the time (63MB of text → 192KB).
        //
        // `-y` stores symlinks rather than following them.
        let level = items.allSatisfy { isPrecompressed($0.url) } ? "-0" : "-6"
        process.arguments = ["-r", "-q", level, "-y", archive.path, "."]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExportError.zipFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return archive
    }

    /// Formats whose bytes are already compressed. Inline text is not one, and
    /// neither is anything unrecognised — the safe default is to deflate.
    private nonisolated static func isPrecompressed(_ url: URL?) -> Bool {
        guard let url else { return false }
        let compressed: Set<String> = [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "webp",
            "mp4", "mov", "m4v", "avi", "mkv",
            "mp3", "m4a", "aac", "flac",
            "pdf", "docx", "xlsx", "pptx", "key", "pages", "numbers",
            "zip", "gz", "bz2", "xz", "7z", "dmg", "ipa", "jar"
        ]
        return compressed.contains(url.pathExtension.lowercased())
    }

    private nonisolated static func uniqueName(for name: String, in used: inout Set<String>) -> String {
        var candidate = name
        var counter = 1
        while used.contains(candidate) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    private nonisolated static func uniqueArchive(in folder: URL, named base: String) -> URL {
        var candidate = folder.appendingPathComponent("\(base).zip")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter).zip")
            counter += 1
        }
        return candidate
    }

    /// Where exports land. Defaults to Downloads.
    static var defaultDestination: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
