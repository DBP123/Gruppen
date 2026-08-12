import SwiftUI

/// Only one window remains: Settings is a page inside it, not a separate scene.
enum WindowID {
    static let main = "main"
    /// Also how the one window is found again when it has been closed and the
    /// app is reopened from the Dock or from a menu bar item.
    static let mainWindowTitle = "Gruppen"
}

/// Every tool Gruppen hosts, present and planned.
///
/// Adding a tool is: a case here, a view in `Sources/Tools/`, and one line in
/// `ToolHost`. Nothing else in the app needs to know it exists.
enum Page: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces"
    case stash = "Stash"
    case scripts = "Script Builder"
    case metrics = "Metrics"
    case guardrails = "Resource Guardrails"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .workspaces: return "square.grid.2x2.fill"
        case .stash: return "tray.2.fill"
        case .scripts: return "chevron.left.forwardslash.chevron.right"
        case .metrics: return "chart.bar.doc.horizontal"
        case .guardrails: return "cpu"
        case .settings: return "gearshape.fill"
        }
    }

    /// Short form for the collapsed rail and the window title.
    var shortTitle: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .stash: return "Stash"
        case .scripts: return "Scripts"
        case .metrics: return "Metrics"
        case .guardrails: return "Guardrails"
        case .settings: return "Settings"
        }
    }

    /// Chip shown beside the title in the tool header.
    var badge: String {
        switch self {
        case .workspaces: return "SYSTEM OVERVIEW"
        case .stash: return "SHELF"
        case .scripts: return "AUTOMATION"
        case .metrics: return "DATA"
        case .guardrails: return "TELEMETRY"
        case .settings: return "KONFIGURATION"
        }
    }

    /// Whether the tool actually does anything yet. Planned tools render an
    /// honest placeholder rather than a mock-up of features that don't exist.
    var isImplemented: Bool {
        switch self {
        case .workspaces, .stash, .scripts, .metrics, .guardrails, .settings: return true
        }
    }

    /// Whether the tool carries its own isolated settings pane.
    var hasSettingsPane: Bool {
        switch self {
        case .workspaces, .stash: return true
        case .scripts, .metrics, .guardrails, .settings: return false
        }
    }

    var summary: String {
        switch self {
        case .workspaces:
            return "Group applications, launch them together, close them together."
        case .stash:
            return "A shelf for files in transit. Drag to the notch or shake to open it."
        case .scripts:
            return "Attach a script to a Gruppe. Dropping files on it runs the script with their paths."
        case .metrics:
            return "Capture system events, keep the fields you want, and export the table."
        case .guardrails:
            return "Every hardware module, and what each one costs to keep watching."
        case .settings:
            return "Application-wide preferences."
        }
    }
}
