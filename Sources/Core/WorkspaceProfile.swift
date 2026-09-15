import AppKit
import Foundation
import SwiftUI

/// A whole working context, in one record.
///
/// A Gruppe is a set of apps you turn on and off. A *profile* is the environment
/// those apps live in: which telemetry you want in front of you, what the Dock
/// holds, which desktop you are on, and the reference material that comes with
/// the job. Activating one is a context switch, not a launch.
///
/// Every section is optional and every section is skipped when empty, so a
/// profile that only swaps the Dock touches nothing else. That is deliberate:
/// a profile is a set of *stated* intentions, and anything it does not state it
/// must leave exactly as it found it.
struct WorkspaceProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String = Theme.defaultGroupHex
    /// Global combination that activates this profile.
    var shortcut: Shortcut?

    // MARK: Stage 1 — telemetry

    /// The telemetry layout to switch to, or nil to leave the monitor alone.
    var telemetry: TelemetryLayout?

    // MARK: Stage 2 — Dock

    /// Apps to pin in the Dock, left to right. Only written when
    /// `replacesDock` is on — an empty list with the switch on would blank the
    /// Dock, which is never what someone meant to configure.
    var dockApps: [AppEntry] = []
    /// Whether this profile rewrites the Dock at all.
    var replacesDock: Bool = false

    // MARK: Stage 3 — desktop

    /// Desktop to switch to, 1-based, or nil for "stay where you are".
    ///
    /// Capped at 10 because the only public route to a specific desktop is the
    /// "Switch to Desktop N" keyboard shortcut, and macOS defines exactly ten of
    /// them. See `SpaceManager` for why this is the least reliable thing a
    /// profile can ask for.
    var spaceIndex: Int?

    // MARK: Stage 4 — payload

    /// Apps to launch. Anything already running is left alone.
    var launches: [AppEntry] = []
    /// Apps to close. Gruppen never appears here, whatever is configured.
    var terminates: [AppEntry] = []
    /// Web links to open in the default browser.
    var links: [String] = []
    /// Folders to open in Finder. Tildes are expanded at activation time, so a
    /// profile stays portable between machines.
    var folders: [String] = []
    /// A script from the library to run last, or nil.
    ///
    /// A library script rather than a loose `.sh` path: scripts are already a
    /// first-class thing in this app, with argv-safe execution, a transcript and
    /// a feedback setting. Pointing at a bare file would be a second, worse
    /// script runner living inside the workspace engine.
    var scriptID: UUID?

    var color: Color { Color(hex: colorHex) }
    var shortcutDisplay: String? { shortcut?.display }

    /// Whether this profile would actually do anything.
    var isEmpty: Bool {
        telemetry == nil && !replacesDock && spaceIndex == nil
            && launches.isEmpty && terminates.isEmpty
            && links.isEmpty && folders.isEmpty && scriptID == nil
    }

    /// One line describing what activating this does, for the card face.
    var summary: String {
        var parts: [String] = []
        if telemetry != nil { parts.append("telemetry") }
        if replacesDock { parts.append("\(dockApps.count) in dock") }
        if let spaceIndex { parts.append("desktop \(spaceIndex)") }
        if !launches.isEmpty { parts.append("\(launches.count) launch") }
        if !terminates.isEmpty { parts.append("\(terminates.count) quit") }
        if !links.isEmpty { parts.append("\(links.count) link\(links.count == 1 ? "" : "s")") }
        if !folders.isEmpty { parts.append("\(folders.count) folder\(folders.count == 1 ? "" : "s")") }
        if scriptID != nil { parts.append("script") }
        return parts.isEmpty ? "Nothing configured" : parts.joined(separator: " · ")
    }

    init(name: String, colorHex: String = Theme.defaultGroupHex) {
        self.name = name
        self.colorHex = colorHex
    }

    /// Decoded by hand, like `AppGroup`, so a profile written by an earlier
    /// build still loads: synthesised decoding treats a missing key as an error
    /// even when the property has a default, which would make every future field
    /// a breaking change to everyone's saved file.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try box.decode(String.self, forKey: .name)
        colorHex = try box.decodeIfPresent(String.self, forKey: .colorHex) ?? Theme.defaultGroupHex
        shortcut = try box.decodeIfPresent(Shortcut.self, forKey: .shortcut)
        telemetry = try box.decodeIfPresent(TelemetryLayout.self, forKey: .telemetry)
        dockApps = try box.decodeIfPresent([AppEntry].self, forKey: .dockApps) ?? []
        replacesDock = try box.decodeIfPresent(Bool.self, forKey: .replacesDock) ?? false
        spaceIndex = try box.decodeIfPresent(Int.self, forKey: .spaceIndex)
        launches = try box.decodeIfPresent([AppEntry].self, forKey: .launches) ?? []
        terminates = try box.decodeIfPresent([AppEntry].self, forKey: .terminates) ?? []
        links = try box.decodeIfPresent([String].self, forKey: .links) ?? []
        folders = try box.decodeIfPresent([String].self, forKey: .folders) ?? []
        scriptID = try box.decodeIfPresent(UUID.self, forKey: .scriptID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, shortcut, telemetry, dockApps, replacesDock
        case spaceIndex, launches, terminates, links, folders, scriptID
    }
}

/// A snapshot of what the telemetry monitor is showing.
///
/// Stored as raw strings rather than `Set<WidgetKind>` and
/// `[WidgetKind: MenuBarDisplayMode]`. Swift only encodes a dictionary as a JSON
/// object when its key is `String` or `Int`; a `WidgetKind` key would silently
/// serialise as a flat alternating array, which is unreadable in a file people
/// are invited to look at. Sorted on capture so the saved file diffs cleanly.
struct TelemetryLayout: Codable, Hashable {
    var armed: [String]
    var panel: [String]
    var pinned: [String]
    /// Widget raw value -> menu bar display mode raw value.
    var modes: [String: String]

    init(armed: [String], panel: [String], pinned: [String], modes: [String: String]) {
        self.armed = armed.sorted()
        self.panel = panel.sorted()
        self.pinned = pinned.sorted()
        self.modes = modes
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        armed = try box.decodeIfPresent([String].self, forKey: .armed) ?? []
        panel = try box.decodeIfPresent([String].self, forKey: .panel) ?? []
        pinned = try box.decodeIfPresent([String].self, forKey: .pinned) ?? []
        modes = try box.decodeIfPresent([String: String].self, forKey: .modes) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case armed, panel, pinned, modes }

    /// What the user sees on the profile card.
    var summary: String {
        "\(armed.count) armed · \(pinned.count) in menu bar"
    }
}

// MARK: - Activation reporting

/// What actually happened when a profile was activated.
///
/// Every stage reports rather than throwing. A profile is a list of independent
/// intentions — a missing folder must not stop the apps from launching — so the
/// engine runs all of them and hands back the record. The UI shows it; the log
/// keeps it.
struct WorkspaceActivationReport {
    enum Outcome: Equatable {
        case done(String)
        /// Nothing to do — the stage was not configured, or was already true.
        case skipped(String)
        case failed(String)

        var isFailure: Bool { if case .failed = self { return true }; return false }

        var text: String {
            switch self {
            case .done(let text), .skipped(let text), .failed(let text): return text
            }
        }
    }

    struct Line: Identifiable {
        let id = UUID()
        let stage: String
        let outcome: Outcome
    }

    var profileName: String
    var lines: [Line] = []
    var startedAt = Date()
    var duration: TimeInterval = 0

    mutating func add(_ stage: String, _ outcome: Outcome) {
        lines.append(Line(stage: stage, outcome: outcome))
    }

    var failures: [Line] { lines.filter(\.outcome.isFailure) }
    var didAnything: Bool { lines.contains { if case .done = $0.outcome { return true }; return false } }

    /// The line written to `~/Library/Logs/Gruppen.log`.
    var transcript: String {
        let body = lines.map { "  \($0.stage): \($0.outcome.text)" }.joined(separator: "\n")
        return "PROFILE \"\(profileName)\" — " + String(format: "%.2fs", duration) + "\n" + body
    }
}
