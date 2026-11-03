import Foundation

/// The app's name and where it keeps its files.
///
/// A beta build — `build.sh` with a `CHANNEL` file saying `beta`, compiled
/// with `-D BETA` — is a separate app: "Gruppen Beta", with its own folder,
/// so the release and the beta installed side by side never read or write
/// each other's groups, profiles or Dock backup.
enum AppPaths {
    #if BETA
    static let name = "Gruppen Beta"
    #else
    static let name = "Gruppen"
    #endif

    /// `~/Library/Application Support/<name>`, made if it is missing.
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// A file in the support folder.
    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    /// Where stashed items that are not files yet are written, under the
    /// system's temporary folder so it reclaims them.
    static var stashScratch: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)-Stash", isDirectory: true)
    }
}
