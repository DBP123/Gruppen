import AppKit
import ServiceManagement
import SwiftUI

/// App-level preferences. Group data lives in `GroupStore`; this is everything
/// that describes how Gruppen itself behaves.
@MainActor
final class AppSettings: ObservableObject {
    /// Panels live outside the SwiftUI scene graph and can't inherit the
    /// environment, so they read the same instance from here.
    static let shared = AppSettings()

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLoginItem()
        }
    }

    @Published var showMenuBar: Bool {
        didSet {
            // SwiftUI writes back to `isInserted` bindings during scene
            // updates. @Published republishes on *every* assignment, equal or
            // not, so an unguarded didSet turns that write-back into an
            // infinite update loop.
            guard showMenuBar != oldValue else { return }
            defaults.set(showMenuBar, forKey: Keys.showMenuBar)
            ensureReachable(changed: .menuBar)
        }
    }

    @Published var showDockIcon: Bool {
        didSet {
            guard showDockIcon != oldValue else { return }
            defaults.set(showDockIcon, forKey: Keys.showDockIcon)
            applyActivationPolicy()
            ensureReachable(changed: .dockIcon)
        }
    }

    /// Bring a Gruppe's windows forward when it is launched. Off by default so
    /// activating a workspace never yanks focus mid-task.
    @Published var activateOnLaunch: Bool {
        didSet {
            guard activateOnLaunch != oldValue else { return }
            defaults.set(activateOnLaunch, forKey: Keys.activateOnLaunch)
        }
    }

    /// Master switch for stashes and their triggers.
    @Published var stashEnabled: Bool {
        didSet { persist(stashEnabled, oldValue, Keys.stashEnabled) }
    }

    /// The three ways a stash can be summoned, each switchable on its own.
    /// Read at the moment a drag begins, so flipping one takes effect on the
    /// next drag with nothing to re-arm.
    @Published var stashNotchEnabled: Bool {
        didSet { persist(stashNotchEnabled, oldValue, Keys.stashNotch) }
    }
    @Published var stashEdgeEnabled: Bool {
        didSet { persist(stashEdgeEnabled, oldValue, Keys.stashEdge) }
    }
    @Published var stashShakeEnabled: Bool {
        didSet { persist(stashShakeEnabled, oldValue, Keys.stashShake) }
    }

    /// Whether dragging a file off a stash moves it or copies it.
    ///
    /// Off — copy — by default, because that is what a stash has always done
    /// and a setting that silently changed where people's files end up would be
    /// a bad surprise. Read when each drag begins, so a change applies to the
    /// next drag. See `StashDragOut` for how the choice reaches the receiver.
    @Published var stashMovesOnDragOut: Bool {
        didSet { persist(stashMovesOnDragOut, oldValue, Keys.stashMoveOnDragOut) }
    }

    /// What the notch stash's close key does with the files on it: off, the
    /// tray slides away and keeps them for next time; on, it empties first.
    ///
    /// Off by default, because keeping is what closing has always done, and
    /// only the close key reads it — a tray withdrawing on its own, at the end
    /// of a drag or with its display unplugged, never clears anything.
    @Published var notchCloseClearsStash: Bool {
        didSet { persist(notchCloseClearsStash, oldValue, Keys.notchCloseClears) }
    }

    /// Where "Export as Zip" writes to.
    @Published var exportPath: String {
        didSet {
            guard exportPath != oldValue else { return }
            defaults.set(exportPath, forKey: Keys.exportPath)
        }
    }

    var exportDirectory: URL {
        exportPath.isEmpty ? StashExporter.defaultDestination : URL(fileURLWithPath: exportPath)
    }

    /// Master switch for the telemetry modules in the menu bar dropdown. Off
    /// means no module can exist at all, whatever `WidgetManager` has stored.
    @Published var showPerformanceMonitor: Bool {
        didSet { persist(showPerformanceMonitor, oldValue, Keys.performanceMonitor) }
    }

    /// Summons a shelf in front of everything, from anywhere. Nil for none.
    @Published var stashShortcut: Shortcut? {
        didSet { persist(stashShortcut, oldValue, Keys.stashShortcut) }
    }

    /// Hides every floating stash on screen, or brings the hidden ones back
    /// when none are showing. Nil for none.
    @Published var stashToggleShortcut: Shortcut? {
        didSet { persist(stashToggleShortcut, oldValue, Keys.stashToggleShortcut) }
    }

    @Published private(set) var loginItemError: String?

    /// Posted after any surface-related preference changes, so the overlay
    /// coordinator can reconcile without a Combine sink per property.
    static let didChange = Notification.Name("GruppenSettingsDidChange")

    private func persist(_ value: Bool, _ oldValue: Bool, _ key: String) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Shortcuts are stored as JSON, and nil removes the key.
    private func persist(_ value: Shortcut?, _ oldValue: Shortcut?, _ key: String) {
        guard value != oldValue else { return }
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func shortcut(forKey key: String) -> Shortcut? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private enum Keys {
        static let showMenuBar = "showMenuBar"
        static let showDockIcon = "showDockIcon"
        static let activateOnLaunch = "activateOnLaunch"
        static let stashEnabled = "stashEnabled"
        static let stashNotch = "stashNotchEnabled"
        static let stashEdge = "stashEdgeEnabled"
        static let stashShake = "stashShakeEnabled"
        static let stashMoveOnDragOut = "stashMovesOnDragOut"
        static let notchCloseClears = "notchCloseClearsStash"
        static let performanceMonitor = "showPerformanceMonitor"
        static let exportPath = "stashExportPath"
        static let stashShortcut = "stashSummonShortcut"
        static let stashToggleShortcut = "stashToggleShortcut"
    }

    private enum Toggle { case menuBar, dockIcon }

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Keys.showMenuBar: true,
            Keys.showDockIcon: true,
            Keys.activateOnLaunch: false,
            Keys.stashEnabled: true,
            Keys.stashNotch: true,
            Keys.stashEdge: true,
            Keys.stashShake: true,
            Keys.stashMoveOnDragOut: false,
            Keys.notchCloseClears: false,
            Keys.performanceMonitor: true,
        ])
        showMenuBar = defaults.bool(forKey: Keys.showMenuBar)
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        activateOnLaunch = defaults.bool(forKey: Keys.activateOnLaunch)
        stashEnabled = defaults.bool(forKey: Keys.stashEnabled)
        stashNotchEnabled = defaults.bool(forKey: Keys.stashNotch)
        stashEdgeEnabled = defaults.bool(forKey: Keys.stashEdge)
        stashShakeEnabled = defaults.bool(forKey: Keys.stashShake)
        stashMovesOnDragOut = defaults.bool(forKey: Keys.stashMoveOnDragOut)
        notchCloseClearsStash = defaults.bool(forKey: Keys.notchCloseClears)
        showPerformanceMonitor = defaults.bool(forKey: Keys.performanceMonitor)
        exportPath = defaults.string(forKey: Keys.exportPath) ?? StashExporter.defaultDestination.path
        stashShortcut = Self.shortcut(forKey: Keys.stashShortcut)
        stashToggleShortcut = Self.shortcut(forKey: Keys.stashToggleShortcut)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Only touches the policy when it actually differs — repeatedly setting
    /// it churns the Dock and window server, which is felt system-wide.
    func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    /// Refresh from the system — the user can revoke the login item in System
    /// Settings without us hearing about it.
    func refreshLoginItemStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin {
            launchAtLogin = enabled
        }
    }

    private func applyLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            // Don't leave the switch claiming something that did not happen.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Turning off the Dock icon *and* the menu bar item would leave no way to
    /// reach the app, so the last one standing refuses to switch off.
    private func ensureReachable(changed: Toggle) {
        guard !showMenuBar, !showDockIcon else { return }
        switch changed {
        case .menuBar: showDockIcon = true
        case .dockIcon: showMenuBar = true
        }
    }
}
