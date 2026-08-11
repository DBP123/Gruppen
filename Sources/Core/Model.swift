import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

/// A recorded global key combination.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32
    /// What to draw for the key itself — "D", "F5", "␣".
    var label: String

    /// Spaced out because the modifier glyphs collide at monospace widths.
    var display: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(label)
        return parts.joined(separator: " ")
    }

    /// Shift alone is not enough — a shortcut with no ⌘/⌥/⌃ would swallow
    /// ordinary typing system-wide.
    var isValid: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }
}

/// One application that belongs to a group.
struct AppEntry: Identifiable, Codable, Hashable {
    var name: String
    var bundleID: String
    var path: String

    var id: String { bundleID.isEmpty ? path : bundleID }
    var url: URL { URL(fileURLWithPath: path) }

    /// Builds an entry from a `.app` bundle on disk. Returns nil for anything
    /// that isn't a readable application bundle.
    init?(url: URL) {
        guard url.pathExtension == "app", let bundle = Bundle(url: url) else { return nil }
        path = url.path
        bundleID = bundle.bundleIdentifier ?? ""
        name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
    }

    var icon: NSImage { IconCache.shared.icon(for: url) }

    /// Every running process belonging to this app: the app itself, matched by
    /// bundle id or by location, plus any helper app nested inside the bundle.
    ///
    /// The nested case matters more than it sounds. Some apps hand off to a
    /// helper and immediately exit — Backdrop, for instance, leaves only
    /// `Backdrop.app/Contents/Resources/BackdropWallpaper.app` running — so
    /// matching the top-level bundle id alone reports them as not running and
    /// leaves nothing for deactivation to close.
    func instances(among running: [NSRunningApplication]) -> [NSRunningApplication] {
        let bundlePath = url.standardizedFileURL.path
        return running.filter { candidate in
            if !bundleID.isEmpty, candidate.bundleIdentifier == bundleID { return true }
            guard let path = candidate.bundleURL?.standardizedFileURL.path else { return false }
            return path == bundlePath || path.hasPrefix(bundlePath + "/")
        }
    }

    var runningInstances: [NSRunningApplication] {
        instances(among: NSWorkspace.shared.runningApplications)
    }

    /// Membership test against a snapshot prepared once per poll.
    ///
    /// `instances(among:)` allocates a filtered array for every app on every
    /// tick; this answers the same question with a set lookup and, only when
    /// that misses, a scan for a nested helper.
    func isRunning(identifiers: Set<String>, bundlePaths: [String]) -> Bool {
        if !bundleID.isEmpty, identifiers.contains(bundleID) { return true }
        let bundlePath = url.standardizedFileURL.path
        let nested = bundlePath + "/"
        return bundlePaths.contains { $0 == bundlePath || $0.hasPrefix(nested) }
    }

    var isRunning: Bool { !runningInstances.isEmpty }
}

/// A script attached to a Gruppe, run when files are dropped on it.
///
/// The parameters and the source are kept separately on purpose: editing a
/// preset's fields regenerates the source, right up until the source is edited
/// by hand, at which point `isCustomised` latches and the generated version
/// never overwrites the user's work.
struct ScriptConfig: Codable, Hashable {
    enum Interpreter: String, Codable, CaseIterable, Identifiable {
        case bash, zsh, python3, jxa
        var id: String { rawValue }

        var label: String {
            switch self {
            case .bash: return "Bash"
            case .zsh: return "Zsh"
            case .python3: return "Python 3"
            case .jxa: return "JavaScript (JXA)"
            }
        }

        /// Candidates in preference order. The first one that exists and is
        /// executable wins, so a Homebrew python3 is found without hard-coding
        /// anyone's machine.
        var candidatePaths: [String] {
            switch self {
            case .bash: return ["/bin/bash"]
            case .zsh: return ["/bin/zsh"]
            case .python3: return ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            case .jxa: return ["/usr/bin/osascript"]
            }
        }

        /// JXA needs to be told it is not AppleScript.
        var leadingArguments: [String] {
            self == .jxa ? ["-l", "JavaScript"] : []
        }

        var fileExtension: String {
            switch self {
            case .bash, .zsh: return "sh"
            case .python3: return "py"
            case .jxa: return "js"
            }
        }
    }

    enum Preset: String, Codable, CaseIterable, Identifiable {
        case move, transform, runCommand, copyPath, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .move: return "Move files"
            case .transform: return "Transform each file"
            case .runCommand: return "Run a command"
            case .copyPath: return "Copy paths"
            case .custom: return "Custom"
            }
        }

        var detail: String {
            switch self {
            case .move: return "Move everything dropped into a folder"
            case .transform: return "Run a command once per file"
            case .runCommand: return "Run a command once, with every path as an argument"
            case .copyPath: return "Put the dropped paths on the clipboard"
            case .custom: return "Write it yourself"
            }
        }

        var usesDirectory: Bool { self == .move }
        var usesFilter: Bool { self == .move || self == .transform }
        var usesCommand: Bool { self == .transform || self == .runCommand }
    }

    var isEnabled: Bool = false
    var preset: Preset = .move
    var interpreter: Interpreter = .bash

    /// Preset parameters. These are handed to the script as environment
    /// variables rather than pasted into it, so a folder name with a quote in it
    /// cannot change what the script does.
    var directory: String = ""
    var fileExtension: String = ""
    var command: String = ""

    /// The script itself.
    var source: String = ""
    /// Latches the first time the source is edited by hand.
    var isCustomised: Bool = false

    /// The environment a run should carry.
    var environment: [String: String] {
        ["GRUPPEN_DEST": directory,
         "GRUPPEN_EXT": fileExtension.replacingOccurrences(of: ".", with: "")]
    }

    /// The source a preset produces, given the current parameters.
    ///
    /// Paths arrive as arguments — `"$@"` in shell, `sys.argv[1:]` in Python —
    /// and are never interpolated into the text, which is what keeps a file
    /// named `; rm -rf ~` a file name rather than a command.
    var generatedSource: String {
        switch interpreter {
        case .bash, .zsh:
            switch preset {
            case .move:
                return """
                #!/bin/bash
                set -euo pipefail
                # Every dropped path arrives as an argument.
                dest="${GRUPPEN_DEST:-$HOME/Desktop}"
                only="${GRUPPEN_EXT:-}"
                mkdir -p "$dest"
                for f in "$@"; do
                  if [ -z "$only" ] || [ "${f##*.}" = "$only" ]; then
                    mv -n -- "$f" "$dest/"
                    echo "moved $(basename "$f")"
                  fi
                done
                """
            case .transform:
                return """
                #!/bin/bash
                set -euo pipefail
                only="${GRUPPEN_EXT:-}"
                for f in "$@"; do
                  if [ -z "$only" ] || [ "${f##*.}" = "$only" ]; then
                    \(command.isEmpty ? "echo \"$f\"" : command) "$f"
                  fi
                done
                """
            case .runCommand:
                return """
                #!/bin/bash
                set -euo pipefail
                \(command.isEmpty ? "echo" : command) "$@"
                """
            case .copyPath:
                return """
                #!/bin/bash
                set -euo pipefail
                printf '%s\\n' "$@" | pbcopy
                echo "copied $# path(s)"
                """
            case .custom:
                return """
                #!/bin/bash
                set -euo pipefail
                # "$@" is every dropped path, in the order they were dropped.
                for f in "$@"; do
                  echo "$f"
                done
                """
            }
        case .python3:
            return """
            #!/usr/bin/env python3
            import os, sys

            paths = sys.argv[1:]
            dest = os.environ.get("GRUPPEN_DEST", "")
            only = os.environ.get("GRUPPEN_EXT", "")

            for path in paths:
                if only and not path.lower().endswith("." + only.lower()):
                    continue
                print(path)
            """
        case .jxa:
            return """
            // Every dropped path arrives as an argument.
            function run(paths) {
              paths.forEach(function (p) { console.log(p) })
              return paths.length + " path(s)"
            }
            """
        }
    }

    /// What should actually be executed.
    var effectiveSource: String {
        isCustomised && !source.isEmpty ? source : generatedSource
    }

    var summary: String {
        guard isEnabled else { return "No script" }
        return "\(preset.label) · \(interpreter.label)"
    }
}

/// A named set of apps that can be turned on and off together.
struct AppGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var apps: [AppEntry] = []
    /// Whether the user last activated this group. Persisted so the state
    /// survives a relaunch of Gruppen itself.
    var isActive: Bool = false
    var colorHex: String = Theme.defaultGroupHex
    /// Global key combination that toggles this Gruppe, or nil for none.
    var shortcut: Shortcut?
    /// What the primary action does when a Gruppe is *partly* running.
    /// `true` finishes the launch, `false` closes whatever is up.
    var fillsWhenPartial: Bool = true
    /// Launch in list order and terminate in reverse, pausing between steps.
    var isSequenced: Bool = false
    /// Seconds between steps of a sequenced launch or termination.
    var sequenceDelay: TimeInterval = 0.5
    /// Runs when files are dropped on this Gruppe. Nil until one is built.
    var script: ScriptConfig?

    var color: Color { Color(hex: colorHex) }

    var shortcutDisplay: String? { shortcut?.display }

    init(name: String, apps: [AppEntry] = [], colorHex: String = Theme.defaultGroupHex) {
        self.name = name
        self.apps = apps
        self.colorHex = colorHex
    }

    /// Decoded by hand so that groups written by earlier versions — which had
    /// no colour or shortcut — still load. Synthesised decoding treats a
    /// missing key as an error even when the property has a default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        apps = try container.decodeIfPresent([AppEntry].self, forKey: .apps) ?? []
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        // Colours used to be stored as a packed integer.
        if let hex = try? container.decode(String.self, forKey: .colorHex) {
            colorHex = hex
        } else if let packed = try? container.decode(UInt32.self, forKey: .colorHex) {
            colorHex = String(format: "#%06X", packed & 0xFFFFFF)
        } else {
            colorHex = Theme.defaultGroupHex
        }
        fillsWhenPartial = try container.decodeIfPresent(Bool.self, forKey: .fillsWhenPartial) ?? true
        isSequenced = try container.decodeIfPresent(Bool.self, forKey: .isSequenced) ?? false
        sequenceDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .sequenceDelay) ?? 0.5
        script = try container.decodeIfPresent(ScriptConfig.self, forKey: .script)

        if let recorded = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) {
            shortcut = recorded
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .shortcutKey) {
            // Pre-recorder builds stored a bare letter that always meant ⌥⌘.
            shortcut = KeyLabels.keyCode(forLetter: legacy).map {
                Shortcut(keyCode: $0, modifiers: UInt32(cmdKey | optionKey), label: legacy.uppercased())
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, apps, isActive, colorHex, shortcut, fillsWhenPartial
        case isSequenced, sequenceDelay, script
        /// Read-only: written by builds before the shortcut recorder.
        case shortcutKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(apps, forKey: .apps)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
        try container.encode(fillsWhenPartial, forKey: .fillsWhenPartial)
        try container.encode(isSequenced, forKey: .isSequenced)
        try container.encode(sequenceDelay, forKey: .sequenceDelay)
        try container.encodeIfPresent(script, forKey: .script)
    }
}
