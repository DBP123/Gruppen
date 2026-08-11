import AppKit
import Foundation

/// Which applications are running, maintained from system events only.
///
/// This replaces a 2-second timer that re-walked the process list forever. That
/// timer was the single largest idle cost in the app — it dominated every idle
/// profile — and it is gone: this object updates when macOS says something
/// launched or quit, and at explicit moments when a human is about to look.
///
/// **The caveat, stated plainly:** `NSWorkspace` does *not* post launch or
/// terminate notifications for `LSUIElement` menu-bar agents. Measured, not
/// assumed. So notifications alone would let those apps' indicators go stale.
/// Rather than reintroduce a timer, the tracker also refreshes on the moments
/// that precede someone actually reading the state — the app becoming active, a
/// window appearing, and immediately after Gruppen itself launches or closes
/// something. All free when idle.
@MainActor
final class RunningAppTracker: ObservableObject {
    @Published private(set) var activeBundleIDs: Set<String> = []
    /// Bundle locations, for apps that hand off to a nested helper.
    @Published private(set) var activeBundlePaths: Set<String> = []

    /// Posted after the running set actually changes.
    static let didChange = Notification.Name("GruppenRunningAppsDidChange")

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }

        // Someone is about to look at the window: catch up on anything the
        // notifications missed.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// One pass over the process list. Called from events, never on a schedule.
    func refresh() {
        let running = NSWorkspace.shared.runningApplications

        var identifiers = Set<String>(minimumCapacity: running.count)
        var paths = Set<String>(minimumCapacity: running.count)
        for application in running {
            if let identifier = application.bundleIdentifier { identifiers.insert(identifier) }
            if let path = application.bundleURL?.standardizedFileURL.path { paths.insert(path) }
        }

        let changed = identifiers != activeBundleIDs || paths != activeBundlePaths
        if identifiers != activeBundleIDs { activeBundleIDs = identifiers }
        if paths != activeBundlePaths { activeBundlePaths = paths }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// Whether an app entry has anything running, including a helper nested
    /// inside its bundle.
    func isRunning(_ app: AppEntry) -> Bool {
        if !app.bundleID.isEmpty, activeBundleIDs.contains(app.bundleID) { return true }
        let bundlePath = app.url.standardizedFileURL.path
        if activeBundlePaths.contains(bundlePath) { return true }
        let nested = bundlePath + "/"
        return activeBundlePaths.contains { $0.hasPrefix(nested) }
    }
}
