import AppKit
import Foundation

/// Rewrites the Dock's pinned applications, and puts them back.
///
/// ## Why `CFPreferences` and not a write to the .plist file
///
/// `~/Library/Preferences/com.apple.dock.plist` is not the Dock's preferences —
/// it is `cfprefsd`'s cache of them, and `cfprefsd` owns the file. Writing it
/// directly races the daemon: the change either lands and is overwritten
/// moments later, or is thrown away outright when the Dock next syncs. Going
/// through `CFPreferences` hands the change to the daemon that owns the domain,
/// which is the difference between a Dock swap that works and one that works
/// most of the time.
///
/// ## Why the Dock is killed rather than asked
///
/// The Dock reads `persistent-apps` once, at startup. There is no public way to
/// tell it to re-read; `killall Dock` is the documented folklore, and it works
/// because `launchd` keeps the Dock alive and restarts it immediately. This does
/// the same thing without a subprocess: `forceTerminate()` on the running Dock
/// is exactly the `SIGKILL` that `killall` sends, through an API rather than a
/// shell.
///
/// ## What this costs the user, stated plainly
///
/// Restarting the Dock is visible. It flashes, Mission Control's window
/// arrangement is rebuilt, and minimised windows lose their Dock position for a
/// moment. That is unavoidable, and it is why `WorkspaceProfile.replacesDock`
/// is a separate switch rather than something every profile does.
@MainActor
enum DockManager {
    private static let domain = "com.apple.dock" as CFString
    private static let persistentApps = "persistent-apps" as CFString

    // MARK: Reading

    /// The Dock's current pinned apps, as bundle paths.
    ///
    /// Read through `CFPreferences` for the same reason writes go through it —
    /// asking the file gives you whatever the daemon last flushed, which is not
    /// necessarily what the Dock is holding.
    static func currentTiles() -> [[String: Any]] {
        CFPreferencesCopyAppValue(persistentApps, domain) as? [[String: Any]] ?? []
    }

    /// Bundle paths for the tiles currently in the Dock, in order.
    static func currentPaths() -> [String] {
        currentTiles().compactMap(path(fromTile:))
    }

    /// Digs the file path out of one tile. Tiles that are not app tiles — stacks,
    /// spacers, anything a future macOS invents — have no `file-data` and are
    /// skipped rather than guessed at.
    private static func path(fromTile tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let string = file["_CFURLString"] as? String,
              let url = URL(string: string) else { return nil }
        return url.path
    }

    // MARK: The original Dock

    /// Where the Dock as it was before Gruppen first touched it is kept.
    ///
    /// Not `UserDefaults`: this is the one piece of state whose loss the user
    /// cannot repair from inside the app, so it lives beside the groups and the
    /// scripts as a file they can see, copy, and read.
    private static var backupURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Gruppen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("dock-original.plist")
    }

    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// Saves the Dock exactly as it stands, once and only once.
    ///
    /// Called before the first write and never again: a second capture taken
    /// after a profile is active would record *Gruppen's* Dock as the original,
    /// and the way back would be gone.
    @discardableResult
    static func captureOriginalIfNeeded() -> Bool {
        guard !hasBackup else { return false }
        let tiles = currentTiles()
        guard !tiles.isEmpty else { return false }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: tiles,
                                                             format: .xml,
                                                             options: 0) else { return false }
        try? data.write(to: backupURL, options: .atomic)
        GroupStore.log("DOCK captured original — \(tiles.count) tile(s) -> \(backupURL.lastPathComponent)")
        return true
    }

    /// Puts the Dock back to what it was before any profile touched it.
    static func restoreOriginal() -> WorkspaceActivationReport.Outcome {
        guard let data = try? Data(contentsOf: backupURL),
              let tiles = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [[String: Any]]
        else { return .failed("no saved Dock to restore") }

        write(tiles)
        restartDock()
        GroupStore.log("DOCK restored original — \(tiles.count) tile(s)")
        return .done("restored \(tiles.count) original tile(s)")
    }

    // MARK: Writing

    /// Replaces the Dock's pinned apps with `apps`, in order.
    ///
    /// Apps whose bundle is no longer on disk are dropped rather than written as
    /// dead tiles — a Dock full of question marks is worse than a short Dock. The
    /// count of what was skipped comes back in the outcome so the user is told,
    /// rather than left to notice.
    static func apply(_ apps: [AppEntry]) -> WorkspaceActivationReport.Outcome {
        guard !apps.isEmpty else { return .skipped("no apps configured") }

        captureOriginalIfNeeded()

        let existing = apps.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return .failed("none of the \(apps.count) apps exist on disk") }

        // Already correct: the Dock is expensive to restart, and restarting it
        // to produce the arrangement it already has is pure cost.
        let wanted = existing.map { URL(fileURLWithPath: $0.path).standardized.path }
        if currentPaths().map({ URL(fileURLWithPath: $0).standardized.path }) == wanted {
            return .skipped("dock already matches")
        }

        write(existing.map(tile(for:)))
        restartDock()

        let missing = apps.count - existing.count
        let detail = missing > 0 ? " (\(missing) missing app(s) skipped)" : ""
        GroupStore.log("DOCK applied \(existing.count) tile(s)\(detail)")
        return .done("\(existing.count) app(s) pinned\(detail)")
    }

    /// One Dock tile.
    ///
    /// Deliberately minimal. A real tile also carries `GUID`, `book`,
    /// `file-mod-date` and `file-type`; the Dock regenerates every one of those
    /// on read, and a stale `book` — a security-scoped bookmark to a path that
    /// has since moved — is actively worse than no bookmark at all.
    private static func tile(for app: AppEntry) -> [String: Any] {
        var data: [String: Any] = [
            "file-data": [
                // `isDirectory: true` is load-bearing, not decoration. The Dock
                // writes app URLs with a trailing slash — verified against this
                // machine's own tiles — and the bare `URL(fileURLWithPath:)`
                // only adds one if it can stat the path and find a directory. A
                // bundle that is momentarily unreadable would then be written
                // without the slash, in a format the Dock did not author. An
                // `.app` is always a directory, so say so rather than asking.
                "_CFURLString": URL(fileURLWithPath: app.path, isDirectory: true).absoluteString,
                "_CFURLStringType": 15,
            ],
            "file-label": app.name,
        ]
        if !app.bundleID.isEmpty { data["bundle-identifier"] = app.bundleID }
        return ["tile-data": data, "tile-type": "file-tile"]
    }

    private static func write(_ tiles: [[String: Any]]) {
        CFPreferencesSetValue(persistentApps,
                              tiles as CFArray,
                              domain,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize(domain)
    }

    /// The native equivalent of `killall Dock`. `launchd` restarts it.
    private static func restartDock() {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        // `terminate()` sends a quit Apple Event the Dock does not answer, so
        // this has to be the hard kill — the same signal `killall` sends.
        dock.forEach { $0.forceTerminate() }
    }
}
