import SwiftUI

/// Only one window remains: Settings is a page inside it, not a separate scene.
enum WindowID {
    static let main = "main"
    /// Also how the one window is found again when it has been closed and the
    /// app is reopened from the Dock or from a menu bar item.
    static let mainWindowTitle = "Gruppen"
}

/// Every tool Gruppen hosts.
///
/// **Declaration order is navigation order.** The rail is built from
/// `allCases`, so moving a case moves the tool.
/// Telemetry is first because it is what the app is now for: the dashboard is
/// the landing page, and everything else is a tool you go and get.
///
/// Adding a tool is: a case here, a view in `Sources/Pages/`, and one line in
/// `ToolHost`. Nothing else in the app needs to know it exists.
enum Page: String, CaseIterable, Identifiable {
    case telemetry = "Telemetry"
    case stash = "Stash"
    case scripts = "Script Builder"
    case workspaces = "Workspaces"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .telemetry: return "gauge.open.with.lines.needle.33percent"
        case .stash: return "tray.2.fill"
        case .scripts: return "chevron.left.forwardslash.chevron.right"
        case .workspaces: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        }
    }

    /// Short form for the collapsed rail and the window title.
    var shortTitle: String {
        switch self {
        case .telemetry: return "Telemetry"
        case .stash: return "Stash"
        case .scripts: return "Scripts"
        case .workspaces: return "Workspaces"
        case .settings: return "Settings"
        }
    }

    /// Chip shown beside the title in the tool header — when it says something
    /// the title does not. Stash has none: its chip read "STASH" beside the
    /// title "STASH".
    var badge: String? {
        switch self {
        case .telemetry: return "WIDGETS"
        case .stash: return nil
        case .scripts: return "AUTOMATION"
        case .workspaces: return "SYSTEM OVERVIEW"
        case .settings: return "KONFIGURATION"
        }
    }

    /// Whether the tool carries its own isolated settings pane.
    ///
    /// Telemetry's pane is its settings — which module is armed, which appears on
    /// the dashboard, which is pinned to the menu bar. It used to be a rail entry
    /// of its own, which put the dashboard and the switches that configure it in
    /// two different places.
    var hasSettingsPane: Bool {
        switch self {
        case .telemetry, .workspaces: return true
        case .stash, .scripts, .settings: return false
        }
    }

    /// Label for the settings-pane chip. Just "SETTINGS": the tool's name is
    /// already the title beside it, and "TELEMETRY  TELEMETRY SETTINGS" said
    /// it twice.
    var settingsPaneBadge: String { "SETTINGS" }

    var summary: String {
        switch self {
        case .telemetry:
            return "Every hardware sensor this Mac exposes, live."
        case .stash:
            return "A stash for files in transit. Drag to the notch or shake to open it."
        case .scripts:
            return "Attach a script to a Gruppe. Dropping files on it runs the script with their paths."
        case .workspaces:
            return "Group applications, launch them together, close them together."
        case .settings:
            return "Application-wide preferences."
        }
    }
}
