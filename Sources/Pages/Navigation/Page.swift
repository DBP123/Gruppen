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
/// **Declaration order is navigation order.** The rail is built from
/// `Page.available`, which filters `allCases`, so moving a case moves the tool.
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
    /// Built, working, and deliberately not shipped — see `isInThisBuild`.
    case metrics = "Metrics"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .telemetry: return "gauge.open.with.lines.needle.33percent"
        case .stash: return "tray.2.fill"
        case .scripts: return "chevron.left.forwardslash.chevron.right"
        case .workspaces: return "square.grid.2x2.fill"
        case .metrics: return "chart.bar.doc.horizontal"
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
        case .metrics: return "Data"
        case .settings: return "Settings"
        }
    }

    /// Chip shown beside the title in the tool header.
    var badge: String {
        switch self {
        case .telemetry: return "HARDWARE"
        case .stash: return "SHELF"
        case .scripts: return "AUTOMATION"
        case .workspaces: return "SYSTEM OVERVIEW"
        case .metrics: return "DATA"
        case .settings: return "KONFIGURATION"
        }
    }

    /// Whether the tool actually does anything yet. Planned tools render an
    /// honest placeholder rather than a mock-up of features that don't exist.
    var isImplemented: Bool { true }

    /// Whether the tool carries its own isolated settings pane.
    ///
    /// Telemetry's pane is Guardrails — which module is armed, which appears on
    /// the dashboard, which is pinned to the menu bar. It used to be a rail entry
    /// of its own, which put the dashboard and the switches that configure it in
    /// two different places.
    var hasSettingsPane: Bool {
        switch self {
        case .telemetry, .workspaces, .stash: return true
        case .scripts, .metrics, .settings: return false
        }
    }

    /// Label for the settings-pane chip, since "TOOL SETTINGS" undersells a page
    /// that is really the telemetry cost model.
    var settingsPaneBadge: String {
        self == .telemetry ? "GUARDRAILS" : "TOOL SETTINGS"
    }

    /// Whether this build offers the tool at all.
    ///
    /// Data captures system events into SQLite and works, but it is not part of
    /// what Gruppen is for any more, so it ships switched off rather than
    /// deleted: the views, the store and the collector all still compile and are
    /// still covered by the tests. Flip to a debug build and it is back in the
    /// rail, unchanged.
    var isInThisBuild: Bool {
        #if DEBUG
        return true
        #else
        return self != .metrics
        #endif
    }

    var summary: String {
        switch self {
        case .telemetry:
            return "Every hardware sensor this Mac exposes, live."
        case .stash:
            return "A shelf for files in transit. Drag to the notch or shake to open it."
        case .scripts:
            return "Attach a script to a Gruppe. Dropping files on it runs the script with their paths."
        case .workspaces:
            return "Group applications, launch them together, close them together."
        case .metrics:
            return "Capture system events, keep the fields you want, and export the table."
        case .settings:
            return "Application-wide preferences."
        }
    }
}
