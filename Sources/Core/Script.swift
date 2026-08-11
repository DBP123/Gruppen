import AppKit
import Foundation

/// A script in the library.
///
/// Standalone by construction: a script belongs to the library, not to a Gruppe
/// or a shelf. What makes it run is its `trigger`, what it does is its `action`,
/// and what happens afterwards is its `feedback` — three independent choices,
/// none of which imply the others.
struct Script: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var isActive: Bool

    var trigger: ScriptTrigger
    var action: ScriptAction
    var feedback: ScriptFeedback

    init(id: UUID = UUID(),
         name: String = "New script",
         isActive: Bool = false,
         trigger: ScriptTrigger = .init(),
         action: ScriptAction = .init(),
         feedback: ScriptFeedback = .silent) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.trigger = trigger
        self.action = action
        self.feedback = feedback
    }

    /// Whether this is complete enough to arm. A trigger with nothing to watch
    /// is not a trigger.
    var isArmable: Bool {
        isActive && trigger.isConfigured && !action.effectiveSource.isEmpty
    }
}

// MARK: - Trigger

/// When a script runs. Every kind here is fed by an event the system already
/// posts — a filesystem event, a hotkey, a workspace notification, a power
/// notification. None of them is a clock.
struct ScriptTrigger: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case folderWatch
        case hotkey
        case appLifecycle
        case systemState
        case customNotification
        /// Only ever run by hand from the builder.
        case manual

        var id: String { rawValue }

        var label: String {
            switch self {
            case .folderWatch: return "A file lands in a folder"
            case .hotkey: return "I press a key combination"
            case .appLifecycle: return "An app or process starts or stops"
            case .systemState: return "The Mac's state changes"
            case .customNotification: return "A named system notification"
            case .manual: return "Only when I press Run"
            }
        }

        var detail: String {
            switch self {
            case .folderWatch:
                return "Each new file's full path is passed to the script"
            case .hotkey:
                return "No files are passed — the script runs on its own"
            case .appLifecycle:
                return "Match an app bundle, or a Unix process name like java or node"
            case .systemState:
                return "Sleep, wake, power connected, or a battery threshold"
            case .customNotification:
                return "Any Darwin or distributed notification name you know of"
            case .manual:
                return "Nothing arms it; you run it from this page"
            }
        }

        /// Whether this trigger hands the script any file paths at all. Used to
        /// say so plainly in the UI instead of leaving it to be discovered.
        var providesFiles: Bool { self == .folderWatch }
    }

    /// How an app-lifecycle trigger identifies its target.
    enum AppMatch: String, Codable, CaseIterable, Identifiable {
        case bundleIdentifier
        case processName
        var id: String { rawValue }

        var label: String {
            self == .bundleIdentifier ? "Application" : "Process name"
        }

        var detail: String {
            self == .bundleIdentifier
                ? "Pick an app; matched on its bundle identifier"
                : "Match the Unix executable name — java, node, python3"
        }
    }

    /// Which notification centre a custom trigger listens on.
    enum NotificationScope: String, Codable, CaseIterable, Identifiable {
        case darwin
        case distributed
        var id: String { rawValue }

        var label: String { self == .darwin ? "Darwin (system-wide)" : "Distributed (per user)" }
        var detail: String {
            self == .darwin
                ? "notifyutil -p <name>, or any CFNotificationCenter Darwin post"
                : "NSDistributedNotificationCenter, as posted by other apps"
        }
    }

    enum AppEvent: String, Codable, CaseIterable, Identifiable {
        case launched, quit
        var id: String { rawValue }
        var label: String { self == .launched ? "launches" : "quits" }
    }

    enum SystemEvent: String, Codable, CaseIterable, Identifiable {
        case willSleep, didWake, powerConnected, powerDisconnected, batteryBelow
        var id: String { rawValue }

        var label: String {
            switch self {
            case .willSleep: return "Mac goes to sleep"
            case .didWake: return "Mac wakes"
            case .powerConnected: return "Power connected"
            case .powerDisconnected: return "Power disconnected"
            case .batteryBelow: return "Battery drops below…"
            }
        }

        var usesThreshold: Bool { self == .batteryBelow }
    }

    var kind: Kind = .manual

    /// `folderWatch`
    var watchedFolder: String = ""
    /// `hotkey`
    var shortcut: Shortcut?
    /// `appLifecycle`
    var appMatch: AppMatch = .bundleIdentifier
    var bundleIdentifier: String = ""
    var appName: String = ""
    /// Unix executable name, when matching by process rather than bundle.
    var processName: String = ""
    var appEvent: AppEvent = .launched
    /// `systemState`
    var systemEvent: SystemEvent = .batteryBelow
    var threshold: Int = 20
    /// `customNotification`
    var notificationScope: NotificationScope = .darwin
    var notificationName: String = ""

    var isConfigured: Bool {
        switch kind {
        case .folderWatch: return !watchedFolder.isEmpty
        case .hotkey: return shortcut?.isValid == true
        case .appLifecycle:
            return appMatch == .bundleIdentifier ? !bundleIdentifier.isEmpty : !processName.isEmpty
        case .customNotification: return !notificationName.isEmpty
        case .systemState, .manual: return true
        }
    }

    var summary: String {
        switch kind {
        case .folderWatch:
            return watchedFolder.isEmpty
                ? "No folder chosen"
                : "Files landing in \((watchedFolder as NSString).lastPathComponent)"
        case .hotkey:
            return shortcut?.display ?? "No shortcut recorded"
        case .appLifecycle:
            let target = appMatch == .bundleIdentifier
                ? (appName.isEmpty ? bundleIdentifier : appName)
                : processName
            return target.isEmpty ? "Nothing chosen" : "\(target) \(appEvent.label)"
        case .systemState:
            return systemEvent.usesThreshold ? "Battery below \(threshold)%" : systemEvent.label
        case .customNotification:
            return notificationName.isEmpty ? "No name given" : notificationName
        case .manual:
            return "Run from here only"
        }
    }
}

// MARK: - Action

/// What a script does when its trigger fires.
struct ScriptAction: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case shellCommand, scriptCode, webhook
        var id: String { rawValue }

        var label: String {
            switch self {
            case .shellCommand: return "Shell Command"
            case .scriptCode: return "Script Code"
            case .webhook: return "Webhook"
            }
        }

        var detail: String {
            switch self {
            case .shellCommand: return "Run a native Zsh terminal command."
            case .scriptCode: return "Execute raw Zsh or JXA code in a built-in editor."
            case .webhook: return "Send an HTTP POST/GET request to a target URL."
            }
        }
    }

    enum Interpreter: String, Codable, CaseIterable, Identifiable {
        case zsh, jxa
        var id: String { rawValue }

        var label: String { self == .zsh ? "Zsh" : "JavaScript (JXA)" }
        var path: String { self == .zsh ? "/bin/zsh" : "/usr/bin/osascript" }
        /// JXA has to be told it is not AppleScript.
        var leadingArguments: [String] { self == .jxa ? ["-l", "JavaScript"] : [] }
        var fileExtension: String { self == .zsh ? "zsh" : "js" }
    }

    enum HTTPMethod: String, Codable, CaseIterable, Identifiable {
        case post, get
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    var kind: Kind = .shellCommand
    var interpreter: Interpreter = .zsh

    /// `shellCommand`
    var command: String = ""
    /// `webhook`
    var webhookURL: String = ""
    var httpMethod: HTTPMethod = .post

    /// The editor's contents, once it has been edited.
    var source: String = ""
    /// Latches on the first hand edit; after that the generated version never
    /// writes over it.
    var isCustomised: Bool = false

    /// Whether this action runs a subprocess at all.
    var isProcess: Bool { kind != .webhook }

    /// The interpreter that will actually be used.
    ///
    /// A shell command *is* zsh, whatever the stored interpreter says. Without
    /// this, choosing JXA in Script Code and then switching to Shell Command
    /// left a zsh script being handed to `osascript`, which fails with a
    /// syntax error nobody could reasonably diagnose. Caught by a test that had
    /// made exactly that mistake.
    var effectiveInterpreter: Interpreter { kind == .shellCommand ? .zsh : interpreter }

    var isConfigured: Bool {
        switch kind {
        case .shellCommand: return !command.isEmpty || isCustomised
        case .scriptCode: return !effectiveSource.isEmpty
        case .webhook: return URL(string: webhookURL)?.scheme?.hasPrefix("http") == true
        }
    }

    /// Paths arrive as arguments — `"$@"` in zsh, `run(paths)` in JXA — and are
    /// never interpolated into the text.
    var generatedSource: String {
        switch kind {
        case .shellCommand:
            return """
            #!/bin/zsh
            set -euo pipefail
            # Every incoming path is appended as an argument.
            \(command.isEmpty ? "echo" : command) "$@"
            """
        case .scriptCode, .webhook:
            switch interpreter {
            case .zsh:
                return """
                #!/bin/zsh
                set -euo pipefail
                # "$@" holds every path this trigger produced.
                for f in "$@"; do
                  echo "$f"
                done
                """
            case .jxa:
                return """
                // Every path this trigger produced arrives as an argument.
                function run(paths) {
                  paths.forEach(function (p) { console.log(p) })
                  return paths.length ? paths.length + " item(s)" : "triggered"
                }
                """
            }
        }
    }

    var effectiveSource: String {
        let effective = isCustomised && !source.isEmpty ? source : generatedSource
        return effective.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lenient on purpose: a library written by an earlier build used a
    /// different set of cases, and a script that fails to decode is a script
    /// that silently disappears.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = ((try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .shellCommand
        interpreter = ((try? container.decodeIfPresent(Interpreter.self, forKey: .interpreter)) ?? nil) ?? .zsh
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        webhookURL = try container.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
        httpMethod = ((try? container.decodeIfPresent(HTTPMethod.self, forKey: .httpMethod)) ?? nil) ?? .post
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        isCustomised = try container.decodeIfPresent(Bool.self, forKey: .isCustomised) ?? false
    }
}

// MARK: - Feedback

/// What happens once a run finishes.
enum ScriptFeedback: String, Codable, CaseIterable, Identifiable {
    case silent
    case banner
    case audio
    case log

    var id: String { rawValue }

    var label: String {
        switch self {
        case .silent: return "None (Silent)"
        case .banner: return "System Notification (Banner)"
        case .audio: return "Audio Alert"
        case .log: return "Debug Log"
        }
    }

    var detail: String {
        switch self {
        case .silent: return "Runs with no visible or audible result."
        case .banner: return "Posts a notification carrying the first line of output."
        case .audio: return "Plays a system sound on success, and a different one on failure."
        case .log: return "Keeps the full transcript in the drawer below."
        }
    }

    /// Anything unrecognised — including the deposit-on-shelf option an earlier
    /// build wrote — reads back as silent rather than failing the whole library.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScriptFeedback(rawValue: raw) ?? .silent
    }
}
