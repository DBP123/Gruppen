import SwiftUI

/// Only one window remains: Settings is a page inside it, not a separate scene.
enum WindowID {
    static let main = "main"
}

/// Every tool Gruppen hosts, present and planned.
///
/// Adding a tool is: a case here, a view in `Sources/Tools/`, and one line in
/// `ToolHost`. Nothing else in the app needs to know it exists.
enum Page: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces"
    case stash = "Stash"
    case scripts = "Script Builder"
    case guardrails = "Resource Guardrails"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .workspaces: return "square.grid.2x2.fill"
        case .stash: return "tray.2.fill"
        case .scripts: return "chevron.left.forwardslash.chevron.right"
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
        case .guardrails: return "PLANNED"
        case .settings: return "KONFIGURATION"
        }
    }

    /// Whether the tool actually does anything yet. Planned tools render an
    /// honest placeholder rather than a mock-up of features that don't exist.
    var isImplemented: Bool {
        switch self {
        case .workspaces, .stash, .scripts, .settings: return true
        case .guardrails: return false
        }
    }

    /// Whether the tool carries its own isolated settings pane.
    var hasSettingsPane: Bool {
        switch self {
        case .workspaces, .stash: return true
        case .scripts, .guardrails, .settings: return false
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
        case .guardrails:
            return "Watch CPU, memory and battery draw, and act when a Gruppe misbehaves."
        case .settings:
            return "Application-wide preferences."
        }
    }
}
