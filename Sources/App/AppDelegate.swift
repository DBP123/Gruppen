import AppKit

/// Process-level concerns: single instance, activation policy, reopen, and shutdown.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by `GruppenApp` so the delegate can tear overlays down on quit.
    static var willTerminate: (() -> Void)?

    /// A stable identifier used once the main configuration window has been found.
    ///
    /// The title fallback keeps this file compatible with the current window setup.
    /// Ideally, assign this identifier when the NSWindow is originally created.
    private static let mainWindowIdentifier =
        NSUserInterfaceItemIdentifier("Gruppen.mainWindow")

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Do the duplicate-process handoff as early in the AppKit lifecycle as
        // possible so the second copy performs minimal initialization.
        guard !handOffToRunningInstance() else { return }

        let showDock =
            UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true

        // Gruppen guarantees elsewhere that the Dock icon and menu-bar item
        // cannot both be hidden, so .accessory is safe when the Dock is hidden.
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    /// Copies of the same bundle in different locations are separate processes
    /// as far as LaunchServices is concerned. If another Gruppen process with
    /// the same bundle identifier is already running, hand activation to it
    /// and terminate this duplicate.
    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = NSRunningApplication.current.processIdentifier

        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: {
                $0.processIdentifier != currentPID &&
                !$0.isTerminated
            })
        else {
            return false
        }

        // On modern macOS, explicitly yield activation before asking the
        // existing process to activate. This is the cooperative-activation
        // path and avoids relying on deprecated "ignore other apps" behavior.
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: existing)
        }

        _ = existing.activate()

        NSApp.terminate(nil)
        return true
    }

    // MARK: - Reopen

    /// Clicking the Dock icon should restore the existing configuration window
    /// rather than allowing AppKit to perform its default reopen behavior.
    ///
    /// `hasVisibleWindows` is intentionally not used as the decision-maker:
    /// Gruppen can have visible overlay windows even while the configuration
    /// window itself is closed.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let window = mainConfigurationWindow() else {
            // If the SwiftUI scene has actually destroyed the NSWindow rather
            // than retaining it, allow the app's normal reopen path to try to
            // recreate the window.
            activate(sender)
            return true
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        activate(sender)

        // We restored the existing window ourselves. Returning false prevents
        // AppKit from doing additional default reopen work.
        return false
    }

    /// `NSApplication.activate()` — no arguments — replaced the deprecated
    /// `activate(ignoringOtherApps:)` in macOS 14. The deployment target here
    /// is 13, so the call site needs both.
    private func activate(_ app: NSApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
    }

    /// Finds the main configuration window using a stable identifier once
    /// available. The title lookup is retained as a compatibility fallback
    /// for the current window creation code, then the identifier is attached
    /// so future lookups do not depend on the displayed title.
    private func mainConfigurationWindow() -> NSWindow? {
        if let window = NSApp.windows.first(where: {
            $0.identifier == Self.mainWindowIdentifier
        }) {
            return window
        }

        guard let window = NSApp.windows.first(where: {
            // Inlined rather than referencing `WindowID.mainWindowTitle`: that
            // type is defined in a file this target does not compile, and the
            // title itself ("Gruppen") is what `WindowID` is fixed to, so this
            // is the one place still allowed to know it directly.
            $0.title == "Gruppen"
        }) else {
            return nil
        }

        window.identifier = Self.mainWindowIdentifier
        return window
    }

    // MARK: - Termination

    /// Closing the configuration window does not quit Gruppen.
    ///
    /// The app guarantees that at least one access point remains available:
    /// either the Dock icon or the menu-bar item. Background features, hotkeys,
    /// and overlays therefore continue running after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.willTerminate?()
    }
}
