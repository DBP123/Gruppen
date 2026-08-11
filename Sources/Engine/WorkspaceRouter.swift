import AppKit
import Foundation

/// Hands files to a Gruppe's apps.
///
/// **It never launches anything.** Sending to a Gruppe is a way to put a file in
/// front of a workspace that is already up, not a way to start one — an earlier
/// version called `launchGroup` first, so dropping a file on an idle Gruppe
/// booted every app in it. Activating a Gruppe is a deliberate act and stays on
/// the Aktivieren button.
enum WorkspaceRouter {
    /// What happened to one send, in the only detail the UI needs.
    enum Outcome {
        case sent
        /// The Gruppe was not running, so there was nothing to hand the file to.
        case notRunning
        /// The apps are up but none of them would take the file.
        case refused
    }

    @MainActor
    static func send(_ urls: [URL], to group: AppGroup) async -> Outcome {
        // A Gruppe with a script *is* the script. Dropping on it runs that,
        // rather than opening the files in its apps, and it does not need the
        // Gruppe to be running — a script has no windows to be up.
        if let script = group.script, script.isEnabled {
            do {
                let run = try await ScriptExecutionEngine.run(script, paths: urls)
                GroupStore.log("SCRIPT \"\(group.name)\" — \(urls.count) path(s), "
                               + String(format: "%.2fs", run.duration))
                return .sent
            } catch {
                GroupStore.log("SCRIPT \"\(group.name)\" failed — \(error.localizedDescription)")
                return .refused
            }
        }

        guard group.isActive else {
            GroupStore.log("ROUTE \"\(group.name)\" — not running, nothing sent")
            return .notRunning
        }
        guard !urls.isEmpty else { return .refused }

        var delivered = 0
        for url in urls {
            var landedSomewhere = false
            for app in group.apps {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                do {
                    _ = try await NSWorkspace.shared.open([url],
                                                          withApplicationAt: app.url,
                                                          configuration: configuration)
                    landedSomewhere = true
                } catch {
                    // An app refusing a type it does not handle is ordinary, not
                    // an error worth surfacing — only a file that lands nowhere
                    // at all is.
                    NSLog("Gruppen: %@ would not open %@ — %@",
                          app.name, url.lastPathComponent, error.localizedDescription)
                }
            }
            if landedSomewhere { delivered += 1 }
        }

        GroupStore.log("ROUTE \(delivered)/\(urls.count) -> \"\(group.name)\"")
        return delivered == urls.count ? .sent : .refused
    }
}
