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

    /// Show the "Suggested Gruppen" chips on the overview. Some people know
    /// exactly what they want and would rather not be offered anything.
    @Published var showSuggestions: Bool {
        didSet {
            guard showSuggestions != oldValue else { return }
            defaults.set(showSuggestions, forKey: Keys.showSuggestions)
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

    /// Master switch for the stash shelf and its triggers.
    @Published var stashEnabled: Bool {
        didSet { persist(stashEnabled, oldValue, Keys.stashEnabled) }
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

    /// Shows CPU/RAM in the menu bar dropdown. Sampling runs only while that
    /// menu is open, so this costs nothing when it is closed.
    @Published var showPerformanceMonitor: Bool {
        didSet { persist(showPerformanceMonitor, oldValue, Keys.performanceMonitor) }
    }

    /// Summons a shelf in front of everything, from anywhere. Nil for none.
    @Published var stashShortcut: Shortcut? {
        didSet {
            guard stashShortcut != oldValue else { return }
            if let stashShortcut, let data = try? JSONEncoder().encode(stashShortcut) {
                defaults.set(data, forKey: Keys.stashShortcut)
            } else {
                defaults.removeObject(forKey: Keys.stashShortcut)
            }
        }
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

    private enum Keys {
        static let showMenuBar = "showMenuBar"
        static let showDockIcon = "showDockIcon"
        static let activateOnLaunch = "activateOnLaunch"
        static let showSuggestions = "showSuggestions"
        static let stashEnabled = "stashEnabled"
        static let performanceMonitor = "showPerformanceMonitor"
        static let exportPath = "stashExportPath"
        static let stashShortcut = "stashSummonShortcut"
    }

    private enum Toggle { case menuBar, dockIcon }

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Keys.showMenuBar: true,
            Keys.showDockIcon: true,
            Keys.activateOnLaunch: false,
            Keys.showSuggestions: true,
            Keys.stashEnabled: true,
            Keys.performanceMonitor: true,
        ])
        showMenuBar = defaults.bool(forKey: Keys.showMenuBar)
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        activateOnLaunch = defaults.bool(forKey: Keys.activateOnLaunch)
        showSuggestions = defaults.bool(forKey: Keys.showSuggestions)
        stashEnabled = defaults.bool(forKey: Keys.stashEnabled)
        showPerformanceMonitor = defaults.bool(forKey: Keys.performanceMonitor)
        exportPath = defaults.string(forKey: Keys.exportPath) ?? StashExporter.defaultDestination.path
        stashShortcut = defaults.data(forKey: Keys.stashShortcut)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
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
