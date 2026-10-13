import AppKit
import Foundation

/// A script in the library: one trigger, then its steps in order, then how it
/// reports.
///
/// Standalone by construction: a script belongs to the library, not to a Gruppe
/// or a shelf. Files flow down the steps — each one receives the current list
/// and hands on a list of its own — so "zip what landed, then move the zip" is
/// two steps rather than a shell script.
struct Script: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var isActive: Bool

    var trigger: ScriptTrigger
    var steps: [ScriptStep]
    var output: ScriptOutput
    /// Listed in the menu bar dropdown with a run key.
    var pinnedToMenuBar: Bool

    init(id: UUID = UUID(),
         name: String = "New script",
         isActive: Bool = false,
         trigger: ScriptTrigger = .init(),
         steps: [ScriptStep] = [.make(.shell)],
         output: ScriptOutput = .init(),
         pinnedToMenuBar: Bool = false) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.trigger = trigger
        self.steps = steps
        self.output = output
        self.pinnedToMenuBar = pinnedToMenuBar
    }

    /// Every step is set up, so a run has a chance of doing what it says.
    var isComplete: Bool { !steps.isEmpty && steps.allSatisfy(\.isConfigured) }

    /// Whether this is complete enough to arm. A trigger with nothing to watch
    /// is not a trigger, and a step with nothing to act on is not a step.
    var isArmable: Bool { isActive && trigger.isConfigured && isComplete }

    /// Decoded by hand, leniently: synthesised decoding treats a missing key as
    /// an error even when the property has a default, so every field added here
    /// would otherwise invalidate every library in the field. A script that
    /// fails to decode is a script that silently disappears.
    ///
    /// **Migration.** A library written before steps existed has one `action`
    /// and one `feedback` instead. That action becomes step 01, unchanged — the
    /// same `ScriptAction` runs it — and the feedback becomes the output.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? "Untitled script"
        isActive = try box.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        trigger = try box.decodeIfPresent(ScriptTrigger.self, forKey: .trigger) ?? ScriptTrigger()
        pinnedToMenuBar = try box.decodeIfPresent(Bool.self, forKey: .pinnedToMenuBar) ?? false

        if let steps = try box.decodeIfPresent([ScriptStep].self, forKey: .steps) {
            self.steps = steps
            output = try box.decodeIfPresent(ScriptOutput.self, forKey: .output) ?? ScriptOutput()
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let action = try legacy.decodeIfPresent(ScriptAction.self, forKey: .action) ?? ScriptAction()
            steps = [ScriptStep(migrating: action)]
            let feedback = (try? legacy.decodeIfPresent(String.self, forKey: .feedback)) ?? nil
            output = ScriptOutput(legacyFeedback: feedback ?? "")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isActive, trigger, steps, output, pinnedToMenuBar
    }

    private enum LegacyKeys: String, CodingKey {
        case action, feedback
    }
}

// MARK: - Steps

/// One thing a script does. Built-in steps cover the common jobs without a
/// line of code; the code steps run through `ScriptExecutionEngine` exactly as
/// a whole script used to.
///
/// One flat value rather than an enum with a payload per kind: each kind reads
/// only the fields it needs, decoding stays lenient field by field, and a step
/// switched from one kind to another keeps what you typed for the first.
struct ScriptStep: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case moveTo, copyTo, rename, zip, unzip, convert, compress, combinePDF, tag, stash, reveal, open, trash
        case openApp, openFolder, openURL, quitApp, hideApp
        case darkMode, mute, keepAwake, lockScreen, emptyTrash, ejectDisks
        case launchGruppe, activateWorkspace, openStash, toggleStashes
        case cleanText, cleanLink, changeCase, saveClipboardImage, snippet
        case runShortcut, shell, javascript, applescript, webhook
        case wait

        var id: String { rawValue }

        var group: Group {
            switch self {
            case .moveTo, .copyTo, .rename, .zip, .unzip, .convert, .compress, .combinePDF,
                 .tag, .stash, .reveal, .open, .trash: return .files
            case .openApp, .openFolder, .openURL, .quitApp, .hideApp: return .apps
            case .darkMode, .mute, .keepAwake, .lockScreen, .emptyTrash, .ejectDisks: return .system
            case .launchGruppe, .activateWorkspace, .openStash, .toggleStashes: return .gruppen
            case .cleanText, .cleanLink, .changeCase, .saveClipboardImage, .snippet: return .clipboard
            case .runShortcut, .shell, .javascript, .applescript, .webhook: return .code
            case .wait: return .flow
            }
        }

        var label: String {
            switch self {
            case .moveTo: return "Move to"
            case .copyTo: return "Copy to"
            case .rename: return "Rename"
            case .zip: return "Zip"
            case .unzip: return "Unzip"
            case .convert: return "Convert"
            case .compress: return "Compress images"
            case .combinePDF: return "Combine to PDF"
            case .tag: return "Add a tag"
            case .stash: return "Put on a stash"
            case .reveal: return "Reveal in Finder"
            case .open: return "Open"
            case .trash: return "Move to Trash"
            case .openApp: return "Open app"
            case .openFolder: return "Open folder"
            case .openURL: return "Open URL"
            case .quitApp: return "Quit app"
            case .hideApp: return "Hide app"
            case .darkMode: return "Toggle Dark Mode"
            case .mute: return "Toggle mute"
            case .keepAwake: return "Keep awake"
            case .lockScreen: return "Lock screen"
            case .emptyTrash: return "Empty Trash"
            case .ejectDisks: return "Eject disks"
            case .launchGruppe: return "Launch a Gruppe"
            case .activateWorkspace: return "Activate a workspace"
            case .openStash: return "Open a stash"
            case .toggleStashes: return "Hide or show stashes"
            case .cleanText: return "Clean copied text"
            case .cleanLink: return "Clean copied link"
            case .changeCase: return "Change case"
            case .saveClipboardImage: return "Save copied image"
            case .snippet: return "Paste a snippet"
            case .runShortcut: return "Run a Shortcut"
            case .shell: return "Shell"
            case .javascript: return "JavaScript"
            case .applescript: return "AppleScript"
            case .webhook: return "Webhook"
            case .wait: return "Wait"
            }
        }

        var glyph: String {
            switch self {
            case .moveTo: return "arrow.right.square"
            case .copyTo: return "doc.on.doc"
            case .rename: return "character.cursor.ibeam"
            case .zip: return "doc.zipper"
            case .unzip: return "archivebox"
            case .convert: return "arrow.triangle.2.circlepath"
            case .compress: return "arrow.down.right.and.arrow.up.left"
            case .combinePDF: return "doc.richtext"
            case .tag: return "tag"
            case .stash: return "tray.and.arrow.down"
            case .reveal: return "magnifyingglass"
            case .open: return "arrow.up.forward.app"
            case .trash: return "trash"
            case .openApp: return "macwindow"
            case .openFolder: return "folder"
            case .openURL: return "link"
            case .quitApp: return "power"
            case .hideApp: return "eye.slash"
            case .darkMode: return "circle.lefthalf.filled"
            case .mute: return "speaker.slash"
            case .keepAwake: return "cup.and.saucer"
            case .lockScreen: return "lock"
            case .emptyTrash: return "trash.slash"
            case .ejectDisks: return "eject"
            case .launchGruppe: return "square.grid.2x2"
            case .activateWorkspace: return "rectangle.3.group"
            case .openStash: return "tray"
            case .toggleStashes: return "tray.2"
            case .cleanText: return "text.badge.checkmark"
            case .cleanLink: return "link.badge.plus"
            case .changeCase: return "textformat"
            case .saveClipboardImage: return "photo.on.rectangle"
            case .snippet: return "text.quote"
            case .runShortcut: return "square.stack.3d.up"
            case .shell: return "terminal"
            case .javascript: return "curlybraces"
            case .applescript: return "applescript"
            case .webhook: return "network"
            case .wait: return "hourglass"
            }
        }

        /// Whether the step works on the files coming down the bus. The others
        /// pass them straight through.
        var usesFiles: Bool { group == .files || self == .openApp || group == .code }
    }

    enum Group: String, CaseIterable, Identifiable {
        case files, apps, system, gruppen, clipboard, code, flow
        var id: String { rawValue }
        var label: String {
            switch self {
            case .files: return "Files"
            case .apps: return "Open & apps"
            case .system: return "System"
            case .gruppen: return "Gruppen"
            case .clipboard: return "Clipboard"
            case .code: return "Shortcuts & code"
            case .flow: return "Flow"
            }
        }
        var kinds: [Kind] { Kind.allCases.filter { $0.group == self } }
    }

    /// Where a move or copy puts each file inside its folder.
    enum Subfolder: String, Codable, CaseIterable, Identifiable {
        case none, month, site
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Straight in"
            case .month: return "By month"
            case .site: return "By site downloaded from"
            }
        }
    }

    var id: UUID
    var kind: Kind

    /// `moveTo`, `copyTo`, `zip`, `openFolder`, `saveClipboardImage` (empty
    /// means the download folder where that makes sense).
    var folder: String = ""
    /// `moveTo`, `copyTo`.
    var subfolder: Subfolder = .none
    /// `rename`.
    var renameStyle: RenameStyle = .datePrefix
    /// `changeCase`.
    var caseStyle: CaseStyle = .sentence
    /// `rename` prefix, `tag` name, `snippet` text, `runShortcut` name.
    var text: String = ""
    /// `keepAwake`.
    var hours: Int = 1
    /// `convert`: the target extension — "pdf", "png".
    var format: String = ""
    /// `openApp`, `quitApp`, `hideApp`.
    var appBundleID: String = ""
    var appName: String = ""
    /// `launchGruppe`, `activateWorkspace`: which one, and its name for display
    /// should it since have been deleted.
    var targetID: UUID?
    var targetName: String = ""
    /// `openURL`.
    var url: String = ""
    /// `wait`.
    var seconds: Int = 2
    /// `shell`, `javascript`, `applescript`, `webhook` — the same action type
    /// a whole script used to be, so the engine that runs it is unchanged.
    var code: ScriptAction = ScriptAction()

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
        code = Self.code(for: kind, from: ScriptAction())
    }

    static func make(_ kind: Kind) -> ScriptStep { ScriptStep(kind: kind) }

    /// A pre-steps action, as step 01. Shell commands, zsh and JXA code, and
    /// webhooks all carry over with their source untouched.
    init(migrating action: ScriptAction) {
        id = UUID()
        switch action.kind {
        case .shellCommand: kind = .shell
        case .webhook: kind = .webhook
        case .scriptCode:
            switch action.interpreter {
            case .zsh: kind = .shell
            case .jxa: kind = .javascript
            case .applescript: kind = .applescript
            }
        }
        code = action
        if action.kind == .scriptCode, action.interpreter == .zsh {
            // Zsh code is a shell step whose source has been written by hand.
            code.kind = .shellCommand
            code.source = action.effectiveSource
            code.isCustomised = true
        }
    }

    /// Changes what this step is, keeping every field so switching back loses
    /// nothing.
    mutating func setKind(_ newKind: Kind) {
        kind = newKind
        code = Self.code(for: newKind, from: code)
    }

    /// The action a code step runs: shell is a command line, JavaScript and
    /// AppleScript are an editor's worth of source, a webhook is a request.
    private static func code(for kind: Kind, from action: ScriptAction) -> ScriptAction {
        var action = action
        switch kind {
        case .shell: action.kind = .shellCommand
        case .javascript: action.kind = .scriptCode; action.interpreter = .jxa
        case .applescript: action.kind = .scriptCode; action.interpreter = .applescript
        case .webhook: action.kind = .webhook
        default: break
        }
        return action
    }

    var isConfigured: Bool {
        switch kind {
        case .moveTo, .copyTo, .openFolder: return !folder.isEmpty
        case .convert: return !format.isEmpty
        case .rename: return renameStyle != .textPrefix || !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .tag, .snippet, .runShortcut: return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .openApp, .quitApp, .hideApp: return !appBundleID.isEmpty
        case .launchGruppe, .activateWorkspace: return targetID != nil
        case .openURL: return URL(string: url)?.scheme != nil
        case .webhook, .shell, .javascript, .applescript: return code.isConfigured
        case .wait: return seconds > 0
        case .keepAwake: return hours > 0
        case .zip, .unzip, .compress, .combinePDF, .stash, .reveal, .open, .trash,
             .darkMode, .mute, .lockScreen, .emptyTrash, .ejectDisks, .openStash, .toggleStashes,
             .cleanText, .cleanLink, .changeCase, .saveClipboardImage:
            return true
        }
    }

    /// The one line a card or slot shows for this step.
    var summary: String {
        func name(_ path: String, or empty: String) -> String {
            path.isEmpty ? empty : (path as NSString).lastPathComponent
        }
        switch kind {
        case .moveTo, .copyTo:
            let into = name(folder, or: "Choose a folder")
            return subfolder == .none ? into : "\(into), \(subfolder.label.lowercased())"
        case .zip: return name(folder, or: "Into the download folder")
        case .rename:
            return renameStyle == .textPrefix ? "Prefix “\(text)”" : renameStyle.label
        case .unzip: return "Beside the archive, then bins it"
        case .convert: return format.isEmpty ? "Choose a format" : "To \(format.uppercased())"
        case .compress: return "JPEG, 75% quality"
        case .combinePDF: return "Every file into one PDF"
        case .tag: return text.isEmpty ? "Name a tag" : text
        case .stash: return "Onto a new stash"
        case .reveal: return "Selected in Finder"
        case .open: return "In their default apps"
        case .trash: return "Recoverable from the Trash"
        case .openApp, .quitApp, .hideApp:
            return appName.isEmpty ? (appBundleID.isEmpty ? "Choose an app" : appBundleID) : appName
        case .openFolder: return name(folder, or: "Choose a folder")
        case .launchGruppe, .activateWorkspace: return targetName.isEmpty ? "Choose one" : targetName
        case .openURL: return url.isEmpty ? "No URL" : url
        case .darkMode: return "Light ↔ dark"
        case .mute: return "Sound on ↔ off"
        case .keepAwake: return "For \(hours) hour\(hours == 1 ? "" : "s")"
        case .lockScreen: return "Asks for your password"
        case .emptyTrash: return "Deletes for good"
        case .ejectDisks: return "Every removable disk"
        case .openStash: return "Under the pointer"
        case .toggleStashes: return "Every floating stash"
        case .cleanText: return "Plain text, tidy spacing"
        case .cleanLink: return "Strips tracking"
        case .changeCase: return caseStyle.label
        case .saveClipboardImage: return name(folder, or: "Into the download folder")
        case .snippet: return text.isEmpty ? "Write the snippet" : text.replacingOccurrences(of: "\n", with: " ")
        case .runShortcut: return text.isEmpty ? "Name a Shortcut" : text
        case .webhook:
            let host = URL(string: code.webhookURL)?.host ?? "No URL"
            return "\(code.httpMethod.label) \(host)"
        case .shell:
            if code.isCustomised {
                return code.source.split(separator: "\n").first.map(String.init) ?? "Empty"
            }
            return code.command.isEmpty ? "No command" : code.command
        case .javascript, .applescript:
            let lines = code.effectiveSource.split(separator: "\n").count
            return code.isCustomised ? "\(lines) lines" : "Template"
        case .wait:
            return "\(seconds)s"
        }
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = ((try? box.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .shell
        folder = try box.decodeIfPresent(String.self, forKey: .folder) ?? ""
        subfolder = ((try? box.decodeIfPresent(Subfolder.self, forKey: .subfolder)) ?? nil) ?? .none
        renameStyle = ((try? box.decodeIfPresent(RenameStyle.self, forKey: .renameStyle)) ?? nil) ?? .datePrefix
        caseStyle = ((try? box.decodeIfPresent(CaseStyle.self, forKey: .caseStyle)) ?? nil) ?? .sentence
        text = try box.decodeIfPresent(String.self, forKey: .text) ?? ""
        hours = try box.decodeIfPresent(Int.self, forKey: .hours) ?? 1
        format = try box.decodeIfPresent(String.self, forKey: .format) ?? ""
        appBundleID = try box.decodeIfPresent(String.self, forKey: .appBundleID) ?? ""
        appName = try box.decodeIfPresent(String.self, forKey: .appName) ?? ""
        targetID = try box.decodeIfPresent(UUID.self, forKey: .targetID)
        targetName = try box.decodeIfPresent(String.self, forKey: .targetName) ?? ""
        url = try box.decodeIfPresent(String.self, forKey: .url) ?? ""
        seconds = try box.decodeIfPresent(Int.self, forKey: .seconds) ?? 2
        code = try box.decodeIfPresent(ScriptAction.self, forKey: .code) ?? ScriptAction()
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, folder, subfolder, renameStyle, caseStyle, text, hours
        case format, appBundleID, appName, targetID, targetName, url, seconds, code
    }
}

// MARK: - Output

/// How a run reports itself, separately for success and failure. The run is
/// always recorded in the history whatever is chosen here.
struct ScriptOutput: Codable, Hashable {
    enum Alert: String, Codable, CaseIterable, Identifiable {
        case none, notification, sound
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "Nothing"
            case .notification: return "Notification"
            case .sound: return "Sound"
            }
        }
    }

    var onSuccess: Alert = .none
    /// A notification by default: a failure nobody hears about is a script
    /// that quietly stopped working.
    var onFailure: Alert = .notification

    init(onSuccess: Alert = .none, onFailure: Alert = .notification) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    /// The single feedback setting from before steps: it applied to success
    /// and failure alike.
    init(legacyFeedback raw: String) {
        switch raw {
        case "banner": self.init(onSuccess: .notification, onFailure: .notification)
        case "audio": self.init(onSuccess: .sound, onFailure: .sound)
        default: self.init(onSuccess: .none, onFailure: .none)
        }
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        onSuccess = ((try? box.decodeIfPresent(Alert.self, forKey: .onSuccess)) ?? nil) ?? .none
        onFailure = ((try? box.decodeIfPresent(Alert.self, forKey: .onFailure)) ?? nil) ?? .notification
    }

    private enum CodingKeys: String, CodingKey { case onSuccess, onFailure }
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
        case display
        case wifi
        case audioDevice
        case schedule
        case gruppe
        /// Only ever run by hand — its key, the palette or the menu bar.
        case manual

        var id: String { rawValue }

        var label: String {
            switch self {
            case .folderWatch: return "A file lands in a folder"
            case .hotkey: return "I press a key combination"
            case .appLifecycle: return "An app or process starts or stops"
            case .systemState: return "The Mac's state changes"
            case .customNotification: return "A named system notification"
            case .display: return "A display is plugged in or out"
            case .wifi: return "I join a Wi-Fi network"
            case .audioDevice: return "Headphones or speakers connect"
            case .schedule: return "At a time of day"
            case .gruppe: return "A Gruppe launches or closes"
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
            case .display:
                return "An external display connecting or disconnecting"
            case .wifi:
                return "Joining a named network. macOS only tells apps the network name with Location Services on"
            case .audioDevice:
                return "The sound output switching to a device whose name contains what you type"
            case .schedule:
                return "One wake-up at the next matching time — nothing runs in between"
            case .gruppe:
                return "One of your Gruppen launching or closing"
            case .manual:
                return "Nothing arms it; you run it from this page"
            }
        }

        /// Whether this trigger hands the script any file paths at all. Used to
        /// say so plainly in the UI instead of leaving it to be discovered.
        var providesFiles: Bool { self == .folderWatch }

        var glyph: String {
            switch self {
            case .folderWatch: return "folder"
            case .hotkey: return "command"
            case .appLifecycle: return "app.badge"
            case .systemState: return "bolt"
            case .customNotification: return "bell"
            case .display: return "display"
            case .wifi: return "wifi"
            case .audioDevice: return "headphones"
            case .schedule: return "clock"
            case .gruppe: return "square.grid.2x2"
            case .manual: return "hand.tap"
            }
        }

        /// One word, for the run history: what set this run off.
        var shortLabel: String {
            switch self {
            case .folderWatch: return "Folder"
            case .hotkey: return "Shortcut"
            case .appLifecycle: return "App"
            case .systemState: return "System"
            case .customNotification: return "Notification"
            case .display: return "Display"
            case .wifi: return "Wi-Fi"
            case .audioDevice: return "Audio"
            case .schedule: return "Schedule"
            case .gruppe: return "Gruppe"
            case .manual: return "Manual"
            }
        }
    }

    /// How an app-lifecycle trigger identifies its target.
    enum AppMatch: String, Codable, CaseIterable, Identifiable {
        case bundleIdentifier
        case processName
        var id: String { rawValue }

        var label: String {
            self == .bundleIdentifier ? "An app" : "A process name"
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

    enum Edge: String, Codable, CaseIterable, Identifiable {
        case on, off
        var id: String { rawValue }
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
    /// `folderWatch`: only files passing these run the steps — all of them,
    /// or any one, per `matchAll`. None means every new file.
    var conditions: [RuleCondition] = []
    var matchAll: Bool = true
    /// `display` (connected / disconnected), `audioDevice` (connected only is
    /// offered), `gruppe` (launched / closed).
    var edge: Edge = .on
    /// `wifi`: network name. `audioDevice`: part of the device's name.
    var match: String = ""
    /// `schedule`: minutes after midnight, and the weekdays it runs on —
    /// 1 Sunday … 7 Saturday, `Calendar`'s numbering.
    var minuteOfDay: Int = 8 * 60 + 30
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// `gruppe`.
    var gruppeID: UUID?
    var gruppeName: String = ""

    var isConfigured: Bool {
        switch kind {
        case .folderWatch: return !watchedFolder.isEmpty
        case .hotkey: return shortcut?.isValid == true
        case .appLifecycle:
            return appMatch == .bundleIdentifier ? !bundleIdentifier.isEmpty : !processName.isEmpty
        case .customNotification: return !notificationName.isEmpty
        case .wifi, .audioDevice: return !match.trimmingCharacters(in: .whitespaces).isEmpty
        case .schedule: return !weekdays.isEmpty
        case .gruppe: return gruppeID != nil
        case .systemState, .display, .manual: return true
        }
    }

    /// Whether `url` passes the rule's conditions.
    func admits(_ url: URL, now: Date = Date()) -> Bool {
        guard !conditions.isEmpty else { return true }
        return matchAll ? conditions.allSatisfy { $0.matches(url, now: now) }
                        : conditions.contains { $0.matches(url, now: now) }
    }

    /// A rule with an age condition also applies to files already sitting in
    /// the folder — "older than 7 days" is never true of something arriving.
    var sweepsExisting: Bool { conditions.contains { $0.kind == .olderThan } }

    /// The next time a schedule trigger is due after `date`.
    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        guard kind == .schedule, !weekdays.isEmpty else { return nil }
        var components = DateComponents()
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        return weekdays.compactMap { weekday -> Date? in
            var wanted = components
            wanted.weekday = weekday
            return calendar.nextDate(after: date, matching: wanted, matchingPolicy: .nextTime)
        }.min()
    }

    init() {}

    /// Lenient, like `ScriptAction` beside it. This type was the gap: it had
    /// synthesised decoding, so a library written before any one of these
    /// twelve fields existed failed on a missing key — and because the library
    /// is decoded as `[Script]` in one go, that took every *other* script in
    /// the file with it. An unrecognised enum case falls back to its default
    /// rather than throwing, for the same reason.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        kind = ((try? box.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .manual
        watchedFolder = try box.decodeIfPresent(String.self, forKey: .watchedFolder) ?? ""
        shortcut = try box.decodeIfPresent(Shortcut.self, forKey: .shortcut)
        appMatch = ((try? box.decodeIfPresent(AppMatch.self, forKey: .appMatch)) ?? nil) ?? .bundleIdentifier
        bundleIdentifier = try box.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        appName = try box.decodeIfPresent(String.self, forKey: .appName) ?? ""
        processName = try box.decodeIfPresent(String.self, forKey: .processName) ?? ""
        appEvent = ((try? box.decodeIfPresent(AppEvent.self, forKey: .appEvent)) ?? nil) ?? .launched
        systemEvent = ((try? box.decodeIfPresent(SystemEvent.self, forKey: .systemEvent)) ?? nil) ?? .batteryBelow
        threshold = try box.decodeIfPresent(Int.self, forKey: .threshold) ?? 20
        notificationScope = ((try? box.decodeIfPresent(NotificationScope.self, forKey: .notificationScope)) ?? nil) ?? .darwin
        notificationName = try box.decodeIfPresent(String.self, forKey: .notificationName) ?? ""
        conditions = try box.decodeIfPresent([RuleCondition].self, forKey: .conditions) ?? []
        matchAll = try box.decodeIfPresent(Bool.self, forKey: .matchAll) ?? true
        edge = ((try? box.decodeIfPresent(Edge.self, forKey: .edge)) ?? nil) ?? .on
        match = try box.decodeIfPresent(String.self, forKey: .match) ?? ""
        minuteOfDay = try box.decodeIfPresent(Int.self, forKey: .minuteOfDay) ?? 8 * 60 + 30
        weekdays = try box.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? [2, 3, 4, 5, 6]
        gruppeID = try box.decodeIfPresent(UUID.self, forKey: .gruppeID)
        gruppeName = try box.decodeIfPresent(String.self, forKey: .gruppeName) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case kind, watchedFolder, shortcut, appMatch, bundleIdentifier, appName
        case processName, appEvent, systemEvent, threshold, notificationScope, notificationName
        case conditions, matchAll, edge, match, minuteOfDay, weekdays, gruppeID, gruppeName
    }

    var weekdaySummary: String {
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
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
        case .display:
            return edge == .on ? "A display connects" : "A display disconnects"
        case .wifi:
            return match.isEmpty ? "Name a network" : "Joining \(match)"
        case .audioDevice:
            return match.isEmpty ? "Name a device" : "\(match) connects"
        case .schedule:
            return String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60) + " · " + weekdaySummary
        case .gruppe:
            let name = gruppeName.isEmpty ? "A Gruppe" : gruppeName
            return edge == .on ? "\(name) launches" : "\(name) closes"
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
            case .shellCommand: return "Run a shell command"
            case .scriptCode: return "Run a script"
            case .webhook: return "Call a webhook"
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
        case zsh, jxa, applescript
        var id: String { rawValue }

        var label: String {
            switch self {
            case .zsh: return "Zsh"
            case .jxa: return "JavaScript"
            case .applescript: return "AppleScript"
            }
        }
        var path: String { self == .zsh ? "/bin/zsh" : "/usr/bin/osascript" }
        /// JXA has to be told it is not AppleScript.
        var leadingArguments: [String] { self == .jxa ? ["-l", "JavaScript"] : [] }
        var fileExtension: String {
            switch self {
            case .zsh: return "zsh"
            case .jxa: return "js"
            case .applescript: return "applescript"
            }
        }
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
            case .applescript:
                return """
                -- Every path this trigger produced arrives in argv.
                on run argv
                  return (count of argv) as text & " item(s)"
                end run
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
