import Foundation

/// Naming a file so it never lands on another: `Report.pdf`, `Report 2.pdf`,
/// `Report 3.pdf`… — Finder's way, so a copy Gruppen makes reads like a copy
/// Finder would have made.
enum FileName {
    /// `name` numbered: `numbered("Report.pdf", 2)` is `Report 2.pdf`. A folder
    /// keeps its whole name as the base — `v1.2` is not `v1 2.2`.
    static func numbered(_ name: String, _ number: Int, isDirectory: Bool = false) -> String {
        guard number > 1 else { return name }
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name) \(number)" }
        return "\((name as NSString).deletingPathExtension) \(number).\(ext)"
    }

    /// The first of `name`, `name 2`, `name 3`… that `isTaken` turns down.
    static func unique(_ name: String, isDirectory: Bool = false, isTaken: (String) -> Bool) -> String {
        var number = 1
        while isTaken(numbered(name, number, isDirectory: isDirectory)) { number += 1 }
        return numbered(name, number, isDirectory: isDirectory)
    }

    /// A URL in `folder` for `name` that nothing on disk is using yet.
    ///
    /// The name is always made safe first (see `sanitized`), because it is
    /// often not ours: a web server's file name, the name a dragging app
    /// suggests, an archive's. Whatever it says, the result is a direct child of
    /// `folder`.
    static func unique(_ name: String, in folder: URL, isDirectory: Bool = false) -> URL {
        let safe = sanitized(name)
        let free = unique(safe, isDirectory: isDirectory) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return folder.appendingPathComponent(free, isDirectory: isDirectory)
    }

    /// The longest name kept, in UTF-8 bytes. Below the file system's 255 so
    /// that numbering a copy (`" 12"`) still fits.
    static let maxBytes = 240

    /// `name` as one harmless path component.
    ///
    /// - `/` and `:` (both path separators to macOS), NUL and other control
    ///   characters become `-`, so `../../.zshrc` cannot climb out of the
    ///   folder it is written to.
    /// - A leading `.` or `-` is dropped: one hides the file, the other makes
    ///   it read as an option to any tool it is later handed to.
    /// - Longer than `maxBytes` is cut, keeping the extension.
    /// - Nothing left at all is `fallback`.
    static func sanitized(_ name: String, fallback: String = "Untitled") -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let unsafe = scalar == "/" || scalar == ":" || scalar.value < 0x20 || scalar.value == 0x7F
            scalars.append(unsafe ? "-" : scalar)
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = cleaned.first, first == "." || first == "-" || first == " " {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return fallback }
        guard cleaned.utf8.count > maxBytes else { return cleaned }

        let ext = (cleaned as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 16 ? "." + ext : ""
        var stem = suffix.isEmpty ? cleaned : (cleaned as NSString).deletingPathExtension
        while !stem.isEmpty, stem.utf8.count + suffix.utf8.count > maxBytes { stem.removeLast() }
        return stem.isEmpty ? fallback : stem + suffix
    }
}
