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
    static func unique(_ name: String, in folder: URL, isDirectory: Bool = false) -> URL {
        let free = unique(name, isDirectory: isDirectory) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return folder.appendingPathComponent(free, isDirectory: isDirectory)
    }
}
