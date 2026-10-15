import Foundation

/// The three kinds of automation, read straight off a script's trigger: a
/// folder makes it a **rule**, nothing (or only a hotkey) makes it an
/// **action** you run, and anything else makes it a **trigger** that runs on
/// its own. No stored field — a script is always in exactly one section.
enum AutomationSection: String, CaseIterable, Identifiable {
    case rules, actions, triggers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rules: return "RULES"
        case .actions: return "ACTIONS"
        case .triggers: return "TRIGGERS"
        }
    }

    var help: String {
        switch self {
        case .rules: return "Watch a folder and file what lands in it"
        case .actions: return "Things you run from a hotkey, the palette or the menu bar"
        case .triggers: return "Things that run on their own when something changes"
        }
    }

    var emptyText: String {
        switch self {
        case .rules: return "No rules yet"
        case .actions: return "No actions yet"
        case .triggers: return "No triggers yet"
        }
    }

    /// The trigger kinds this section's editor offers.
    var triggerKinds: [ScriptTrigger.Kind] {
        switch self {
        case .rules: return [.folderWatch]
        case .actions: return [.manual, .hotkey]
        case .triggers: return [.display, .wifi, .audioDevice, .schedule, .gruppe,
                                .appLifecycle, .systemState, .customNotification]
        }
    }

    var templates: [AutomationTemplate] {
        switch self {
        case .rules: return AutomationTemplate.rules
        case .actions: return AutomationTemplate.actions
        case .triggers: return AutomationTemplate.triggers
        }
    }
}

extension Script {
    var section: AutomationSection {
        switch trigger.kind {
        case .folderWatch: return .rules
        case .manual, .hotkey: return .actions
        default: return .triggers
        }
    }
}

/// A ready-made automation: a name, an icon, and the script it starts as.
/// Anything left unset — the destination folder, the workspace — shows amber
/// on the card and opens the editor at it.
struct AutomationTemplate: Identifiable, Sendable {
    let name: String
    let glyph: String
    let make: @Sendable () -> Script
    var id: String { name }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private static func path(_ relative: String) -> String { home + "/" + relative }

    private static func rule(_ name: String, glyph: String, in folder: String,
                             _ conditions: [RuleCondition], matchAll: Bool = true,
                             _ steps: [ScriptStep]) -> AutomationTemplate {
        AutomationTemplate(name: name, glyph: glyph) {
            var script = Script(name: name, isActive: false, steps: steps)
            script.trigger.kind = .folderWatch
            script.trigger.watchedFolder = folder
            script.trigger.conditions = conditions
            script.trigger.matchAll = matchAll
            return script
        }
    }

    private static func step(_ kind: ScriptStep.Kind, _ configure: (inout ScriptStep) -> Void = { _ in }) -> ScriptStep {
        var step = ScriptStep.make(kind)
        configure(&step)
        return step
    }

    /// A destination a template names, made if it is missing, so the rule is
    /// ready to switch on.
    private static func folder(_ relative: String) -> String {
        let full = path(relative)
        try? FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    static let rules: [AutomationTemplate] = [
        rule("Canvas PDFs to a course folder", glyph: "graduationcap", in: path("Downloads"),
             [RuleCondition(.family, family: .pdf), RuleCondition(.downloadedFrom, text: "instructure")],
             [step(.moveTo)]),
        rule("Unzip downloads", glyph: "archivebox", in: path("Downloads"),
             [RuleCondition(.ext, text: "zip")], [step(.unzip)]),
        AutomationTemplate(name: "File screenshots by date", glyph: "camera.viewfinder") {
            var script = Script(name: "File screenshots by date",
                                steps: [step(.rename) { $0.renameStyle = .clean },
                                        step(.moveTo) { $0.folder = folder("Pictures/Screenshots"); $0.subfolder = .month }])
            script.trigger.kind = .folderWatch
            script.trigger.watchedFolder = path("Desktop")
            script.trigger.conditions = [RuleCondition(.nameStartsWith, text: "Screenshot")]
            return script
        },
        rule("HEIC photos to JPEG", glyph: "photo", in: path("Downloads"),
             [RuleCondition(.ext, text: "heic")], [step(.convert) { $0.format = "jpg" }]),
        rule("Bin old installers", glyph: "shippingbox", in: path("Downloads"),
             [RuleCondition(.family, family: .installer), RuleCondition(.olderThan, number: 7)],
             [step(.trash)]),
        AutomationTemplate(name: "Archive an old Desktop", glyph: "archivebox.circle") {
            var script = Script(name: "Archive an old Desktop",
                                steps: [step(.moveTo) { $0.folder = folder("Desktop/Archive") }])
            script.trigger.kind = .folderWatch
            script.trigger.watchedFolder = path("Desktop")
            script.trigger.conditions = [RuleCondition(.olderThan, number: 30)]
            return script
        },
    ]

    private static func action(_ kind: ScriptStep.Kind) -> AutomationTemplate {
        AutomationTemplate(name: kind.label, glyph: kind.glyph) {
            Script(name: kind.label, isActive: true, steps: [step(kind)])
        }
    }

    static let actions: [AutomationTemplate] = [
        action(.cleanLink), action(.cleanText), action(.saveClipboardImage), action(.snippet),
        action(.darkMode), action(.mute), action(.keepAwake), action(.lockScreen),
        action(.ejectDisks), action(.emptyTrash), action(.runShortcut),
    ]

    private static func trigger(_ name: String, glyph: String,
                                _ configure: @escaping @Sendable (inout ScriptTrigger) -> Void,
                                _ steps: [ScriptStep]) -> AutomationTemplate {
        AutomationTemplate(name: name, glyph: glyph) {
            var script = Script(name: name, isActive: true, steps: steps)
            configure(&script.trigger)
            return script
        }
    }

    static let triggers: [AutomationTemplate] = [
        trigger("Monitor in, workspace on", glyph: "display",
                { $0.kind = .display; $0.edge = .on }, [step(.activateWorkspace)]),
        trigger("Headphones in, Music on", glyph: "headphones",
                { $0.kind = .audioDevice; $0.match = "AirPods" },
                [step(.openApp) { $0.appBundleID = "com.apple.Music"; $0.appName = "Music" }]),
        trigger("Mornings, open a folder", glyph: "sunrise",
                { $0.kind = .schedule; $0.minuteOfDay = 8 * 60 + 30; $0.weekdays = [2, 3, 4, 5, 6] },
                [step(.openFolder)]),
        trigger("On a network, mute", glyph: "wifi",
                { $0.kind = .wifi }, [step(.mute)]),
        trigger("Unplugged, quit an app", glyph: "battery.50",
                { $0.kind = .systemState; $0.systemEvent = .powerDisconnected }, [step(.quitApp)]),
    ]
}
