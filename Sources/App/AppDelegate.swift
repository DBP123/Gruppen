import AppKit

/// Process-level concerns: single instance, activation policy, reopen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `GruppenApp` so the delegate can tear the overlays down on quit.
    @MainActor static var willTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handOffToRunningInstance() else { return }
        let showDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    /// Copies of the same bundle in different locations are separate processes
    /// as far as LaunchServices is concerned, so a second Gruppen really can
    /// start. If one is already running, focus it and bow out.
    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let mine = NSRunningApplication.current.processIdentifier
        let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
        guard let existing else { return false }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    /// Clicking the Dock icon with no window open should bring the one window
    /// back, not make another.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard !flag else { return true }
        if let window = NSApp.windows.first(where: { $0.title == GruppenApp.mainWindowTitle }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Closing the window should not quit a workspace manager — the menu bar
    /// item, the overlays and the hotkeys keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.object(forKey: "showMenuBar") as? Bool == false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.willTerminate?() }
    }
}
