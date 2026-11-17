import AppKit

/// The parts of macOS that Gruppen never adds to a Gruppe and never quits.
///
/// Closing a Gruppe quits its apps, and a Gruppe can be closed by one keypress
/// on its hotkey. Some apps are not apps in that sense: quitting loginwindow
/// logs you out on the spot, with whatever was unsaved; the Dock, Finder,
/// SystemUIServer and Control Center are the desktop itself. None of them
/// belongs in a list of things to switch off.
///
/// Checked when apps are added, and again on the way out — a Gruppe written
/// by an older build, or edited by hand, may already hold one.
enum ProtectedApps {
    static let bundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.wallpaper.agent",
        "com.dhilanpatel.gruppen",
        "com.dhilanpatel.gruppen.beta",
    ]

    /// System agents live here. Its `Applications` subfolder is different —
    /// Screen Sharing, Archive Utility, Directory Utility are ordinary apps
    /// someone might well group.
    private static let coreServices = "/System/Library/CoreServices/"
    private static let coreServicesApps = "/System/Library/CoreServices/Applications/"

    static func isProtected(bundleID: String?, path: String?) -> Bool {
        if let bundleID, !bundleID.isEmpty, bundleIDs.contains(bundleID) { return true }
        if let own = Bundle.main.bundleIdentifier, bundleID == own { return true }
        if let path {
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            if standard.hasPrefix(coreServices), !standard.hasPrefix(coreServicesApps) { return true }
        }
        return false
    }

    static func isProtected(_ entry: AppEntry) -> Bool {
        isProtected(bundleID: entry.bundleID, path: entry.path)
    }

    /// A running process: also Gruppen itself by pid, since the bundle
    /// identifier is nil when it runs outside a bundle.
    static func isProtected(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == NSRunningApplication.current.processIdentifier { return true }
        return isProtected(bundleID: app.bundleIdentifier, path: app.bundleURL?.path)
    }

    /// Says, once, why some of what was dropped or picked did not go in.
    @MainActor
    static func explainRefusal(_ names: [String]) {
        guard !names.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? "\(names[0]) can't be added to a Gruppe"
            : "\(names.count) apps can't be added to a Gruppe"
        alert.informativeText = "macOS needs \(names.count == 1 ? "it" : names.joined(separator: ", ")) running. "
            + "Closing a Gruppe quits its apps, and quitting this would log you out or restart part of the desktop."
        alert.alertStyle = .informational
        alert.runModal()
    }
}
