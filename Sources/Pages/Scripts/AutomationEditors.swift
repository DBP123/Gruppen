import AppKit
import SwiftUI

// The editors that fold out of an automation's card: what sets it off, the
// conditions a rule's files must pass, each step's settings, and how it
// reports. Compact mono rows — a label and its control — so a card opened up
// still reads as part of the same instrument.

// MARK: - Rows and controls

/// An engraved label and its control.
struct EditorRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.mono(8.5, .semibold)).tracking(0.9)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 78, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }
}

/// A dropdown key showing the current choice.
struct SlotMenu<Items: View>: View {
    let value: String
    var help: String? = nil
    @ViewBuilder let items: Items

    var body: some View {
        Menu { items } label: { MenuKeyLabel(title: value) }
            .menuKey(compact: true)
            .help(help ?? value)
    }
}

struct SlotField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .recessed(cornerRadius: 4)
    }
}

/// A key naming the chosen folder or app, or asking for one. The full path is
/// the tooltip.
struct PickKey: View {
    let glyph: String
    let value: String?
    let placeholder: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: glyph)
                Text(value ?? placeholder).lineLimit(1).truncationMode(.middle)
            }
        }
        .industrialButton(.secondary, compact: true)
        .help(help.isEmpty ? (value ?? placeholder) : help)
    }
}

/// A slider and its value, for counts — hours, seconds, days, megabytes.
struct CountRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        EditorRow(label: label) {
            IndustrialSlider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                             range: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .frame(width: 160)
            Text("\(value)\(unit)")
                .font(Theme.mono(10.5).monospacedDigit())
                .foregroundStyle(Theme.orange)
        }
    }
}

struct SourceEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 110, maxHeight: 280)
            .recessed(cornerRadius: 5)
    }
}

private func folderName(_ path: String) -> String? {
    path.isEmpty ? nil : (path as NSString).lastPathComponent
}

// MARK: - What sets it off

struct TriggerEditor: View {
    @Binding var trigger: ScriptTrigger
    let kinds: [ScriptTrigger.Kind]
    @EnvironmentObject private var store: GroupStore

    var body: some View {
        if kinds.count > 1 {
            EditorRow(label: "WHEN") {
                SlotMenu(value: trigger.kind.label, help: trigger.kind.detail) {
                    ForEach(kinds) { kind in
                        Button { trigger.kind = kind } label: { Label(kind.label, systemImage: kind.glyph) }
                    }
                }
            }
        }

        switch trigger.kind {
        case .folderWatch:
            EditorRow(label: "FOLDER") {
                PickKey(glyph: "folder.fill", value: folderName(trigger.watchedFolder),
                        placeholder: "Choose a folder", help: trigger.watchedFolder) {
                    if let url = Pickers.folder(title: "Watch which folder?") { trigger.watchedFolder = url.path }
                }
            }
            ConditionsEditor(trigger: $trigger)
        case .hotkey, .manual:
            EditorRow(label: "HOTKEY") {
                ShortcutKeys(shortcut: trigger.shortcut) { recorded in
                    trigger.shortcut = recorded
                    trigger.kind = recorded == nil ? .manual : .hotkey
                }
            }
        case .appLifecycle:
            EditorRow(label: "MATCH") {
                SlotMenu(value: trigger.appMatch.label, help: trigger.appMatch.detail) {
                    ForEach(ScriptTrigger.AppMatch.allCases) { match in
                        Button(match.label) { trigger.appMatch = match }
                    }
                }
            }
            if trigger.appMatch == .bundleIdentifier {
                EditorRow(label: "APP") {
                    PickKey(glyph: "app",
                            value: trigger.appName.isEmpty ? (trigger.bundleIdentifier.isEmpty ? nil : trigger.bundleIdentifier)
                                                           : trigger.appName,
                            placeholder: "Choose an app") {
                        if let app = Pickers.app() {
                            trigger.bundleIdentifier = app.bundleID
                            trigger.appName = app.name
                        }
                    }
                }
            } else {
                EditorRow(label: "PROCESS") {
                    SlotField(text: $trigger.processName, placeholder: "java")
                        .help("macOS announces apps starting and stopping, not bare processes. A process name fires on quit, and on launch only for a real app bundle.")
                }
            }
            EditorRow(label: "WHEN IT") {
                SlotMenu(value: trigger.appEvent.label) {
                    ForEach(ScriptTrigger.AppEvent.allCases) { event in
                        Button(event.label) { trigger.appEvent = event }
                    }
                }
            }
        case .systemState:
            EditorRow(label: "EVENT") {
                SlotMenu(value: trigger.systemEvent.label) {
                    ForEach(ScriptTrigger.SystemEvent.allCases) { event in
                        Button(event.label) { trigger.systemEvent = event }
                    }
                }
            }
            if trigger.systemEvent.usesThreshold {
                CountRow(label: "BELOW", value: $trigger.threshold, range: 5...95, unit: "%")
                    .help("Fires once, on the way down")
            }
        case .customNotification:
            EditorRow(label: "SCOPE") {
                SlotMenu(value: trigger.notificationScope.label, help: trigger.notificationScope.detail) {
                    ForEach(ScriptTrigger.NotificationScope.allCases) { scope in
                        Button(scope.label) { trigger.notificationScope = scope }
                    }
                }
            }
            EditorRow(label: "NAME") {
                SlotField(text: $trigger.notificationName, placeholder: "com.example.somethingHappened")
            }
        case .display:
            EditorRow(label: "WHEN") {
                ChoiceSwitch(left: "Connected", right: "Disconnected",
                             isRight: Binding(get: { trigger.edge == .off }, set: { trigger.edge = $0 ? .off : .on }))
                    .frame(width: 260)
            }
        case .wifi:
            EditorRow(label: "NETWORK") {
                SlotField(text: $trigger.match, placeholder: "eduroam")
                    .help("The network's exact name. macOS shares it only with Location Services on for Gruppen")
            }
        case .audioDevice:
            EditorRow(label: "DEVICE") {
                SlotField(text: $trigger.match, placeholder: "AirPods")
                    .help("Runs when the sound output switches to a device whose name contains this")
            }
        case .schedule:
            EditorRow(label: "TIME") {
                DatePicker("", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: trigger.minuteOfDay / 60,
                                                 minute: trigger.minuteOfDay % 60, second: 0, of: Date()) ?? Date() },
                    set: {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                        trigger.minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    }), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(width: 90)
            }
            EditorRow(label: "DAYS") {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = trigger.weekdays.contains(day)
                        Button(String(Calendar.current.veryShortWeekdaySymbols[day - 1])) {
                            if on { trigger.weekdays.remove(day) } else { trigger.weekdays.insert(day) }
                        }
                        .industrialButton(on ? .primary : .quiet, compact: true)
                    }
                }
            }
        case .gruppe:
            EditorRow(label: "GRUPPE") {
                SlotMenu(value: trigger.gruppeName.isEmpty ? "Choose one" : trigger.gruppeName) {
                    ForEach(store.groups) { group in
                        Button(group.name) { trigger.gruppeID = group.id; trigger.gruppeName = group.name }
                    }
                }
            }
            EditorRow(label: "WHEN IT") {
                ChoiceSwitch(left: "Launches", right: "Closes",
                             isRight: Binding(get: { trigger.edge == .off }, set: { trigger.edge = $0 ? .off : .on }))
                    .frame(width: 220)
            }
        }
    }
}

/// A rule's conditions: each a kind and its value, and whether a file must
/// pass all of them or any one.
struct ConditionsEditor: View {
    @Binding var trigger: ScriptTrigger

    var body: some View {
        ForEach($trigger.conditions) { $condition in
            EditorRow(label: condition.id == trigger.conditions.first?.id ? "IF" : (trigger.matchAll ? "AND" : "OR")) {
                SlotMenu(value: condition.kind.label) {
                    ForEach(RuleCondition.Kind.allCases) { kind in
                        Button(kind.label) { condition.kind = kind }
                    }
                }
                value($condition)
                Button {
                    trigger.conditions.removeAll { $0.id == condition.id }
                } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .industrialButton(.ghost, compact: true)
                .help("Remove this condition")
            }
        }
        EditorRow(label: trigger.conditions.isEmpty ? "IF" : "") {
            Menu {
                ForEach(RuleCondition.Kind.allCases) { kind in
                    Button(kind.label) { trigger.conditions.append(RuleCondition(kind)) }
                }
            } label: { MenuKeyLabel(title: trigger.conditions.isEmpty ? "Any file — add a condition" : "Add a condition") }
            .menuKey(compact: true)
            if trigger.conditions.count > 1 {
                ChoiceSwitch(left: "All of these", right: "Any of these",
                             isRight: Binding(get: { !trigger.matchAll }, set: { trigger.matchAll = !$0 }))
                    .frame(width: 220)
            }
        }
    }

    @ViewBuilder private func value(_ condition: Binding<RuleCondition>) -> some View {
        switch condition.wrappedValue.kind {
        case .family:
            SlotMenu(value: condition.wrappedValue.family.label) {
                ForEach(FileFamily.allCases) { family in
                    Button(family.label) { condition.wrappedValue.family = family }
                }
            }
        case .ext:
            SlotField(text: condition.text, placeholder: "pdf").frame(width: 90)
        case .nameContains, .nameStartsWith:
            SlotField(text: condition.text, placeholder: "ENGR 133").frame(width: 160)
        case .downloadedFrom:
            SlotField(text: condition.text, placeholder: "instructure").frame(width: 160)
                .help("Part of the address the file was downloaded from — the browser records it as it saves")
        case .olderThan, .largerThan:
            IndustrialSlider(value: Binding(get: { Double(condition.wrappedValue.number) },
                                            set: { condition.wrappedValue.number = Int($0.rounded()) }),
                             range: 1...(condition.wrappedValue.kind == .olderThan ? 90 : 500), step: 1)
                .frame(width: 120)
            Text("\(condition.wrappedValue.number)\(condition.wrappedValue.kind == .olderThan ? " days" : " MB")")
                .font(Theme.mono(10.5).monospacedDigit())
                .foregroundStyle(Theme.orange)
        }
    }
}

// MARK: - Steps

struct StepEditor: View {
    @Binding var step: ScriptStep
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var workspaces: WorkspaceEngine

    var body: some View {
        switch step.kind {
        case .moveTo, .copyTo:
            EditorRow(label: "TO") { folderKey("Choose a folder") }
            EditorRow(label: "SORT") {
                SlotMenu(value: step.subfolder.label) {
                    ForEach(ScriptStep.Subfolder.allCases) { style in
                        Button(style.label) { step.subfolder = style }
                    }
                }
            }
        case .zip, .saveClipboardImage:
            EditorRow(label: "INTO") {
                folderKey("Download folder")
                if !step.folder.isEmpty {
                    Button("Use download folder") { step.folder = "" }.industrialButton(.ghost, compact: true)
                }
            }
        case .openFolder:
            EditorRow(label: "FOLDER") { folderKey("Choose a folder") }
        case .rename:
            EditorRow(label: "HOW") {
                SlotMenu(value: step.renameStyle.label) {
                    ForEach(RenameStyle.allCases) { style in Button(style.label) { step.renameStyle = style } }
                }
                if step.renameStyle == .textPrefix {
                    SlotField(text: $step.text, placeholder: "ENGR133").frame(width: 140)
                }
            }
        case .convert:
            EditorRow(label: "TO") {
                SlotMenu(value: step.format.isEmpty ? "Choose a format" : step.format.uppercased()) {
                    ForEach(Self.formats, id: \.title) { family in
                        Section(family.title) {
                            ForEach(family.targets) { target in Button(target.label) { step.format = target.ext } }
                        }
                    }
                }
            }
        case .tag:
            EditorRow(label: "TAG") { SlotField(text: $step.text, placeholder: "School").frame(width: 160) }
        case .openApp, .quitApp, .hideApp:
            EditorRow(label: "APP") {
                PickKey(glyph: "app",
                        value: step.appName.isEmpty ? (step.appBundleID.isEmpty ? nil : step.appBundleID) : step.appName,
                        placeholder: "Choose an app") {
                    if let app = Pickers.app() {
                        step.appBundleID = app.bundleID
                        step.appName = app.name
                    }
                }
            }
        case .launchGruppe:
            EditorRow(label: "GRUPPE") {
                SlotMenu(value: step.targetName.isEmpty ? "Choose one" : step.targetName) {
                    ForEach(store.groups) { group in
                        Button(group.name) { step.targetID = group.id; step.targetName = group.name }
                    }
                }
            }
        case .activateWorkspace:
            EditorRow(label: "PROFIL") {
                SlotMenu(value: step.targetName.isEmpty ? "Choose one" : step.targetName) {
                    ForEach(workspaces.profiles) { profile in
                        Button(profile.name) { step.targetID = profile.id; step.targetName = profile.name }
                    }
                }
            }
        case .openURL:
            EditorRow(label: "URL") { SlotField(text: $step.url, placeholder: "https://…") }
        case .keepAwake:
            CountRow(label: "FOR", value: $step.hours, range: 1...12, unit: "h")
        case .changeCase:
            EditorRow(label: "TO") {
                SlotMenu(value: step.caseStyle.label) {
                    ForEach(CaseStyle.allCases) { style in Button(style.label) { step.caseStyle = style } }
                }
            }
        case .snippet:
            SourceEditor(text: $step.text)
                .help("Pasted where you are typing — with Accessibility on. Otherwise it is copied for ⌘V")
        case .runShortcut:
            EditorRow(label: "SHORTCUT") {
                SlotField(text: $step.text, placeholder: "Do Not Disturb").frame(width: 200)
                    .help("The name of a Shortcut in the Shortcuts app. Files, if any, are passed in as its input")
            }
        case .webhook:
            EditorRow(label: "URL") { SlotField(text: $step.code.webhookURL, placeholder: "https://example.com/hook") }
            EditorRow(label: "METHOD") {
                SlotMenu(value: step.code.httpMethod.label,
                         help: step.code.httpMethod == .post ? "Sends the file paths as a JSON body" : "Sends no body") {
                    ForEach(ScriptAction.HTTPMethod.allCases) { method in Button(method.label) { step.code.httpMethod = method } }
                }
            }
        case .shell:
            if step.code.isCustomised {
                source
            } else {
                EditorRow(label: "COMMAND") {
                    SlotField(text: $step.code.command, placeholder: "open -a Finder")
                        .help("The files arrive as arguments — $1, $2, \"$@\" — never inserted into the text")
                    Button("Write a script") {
                        step.code.source = step.code.generatedSource
                        step.code.isCustomised = true
                    }
                    .industrialButton(.ghost, compact: true)
                }
            }
        case .javascript, .applescript:
            source
        case .wait:
            CountRow(label: "SECONDS", value: $step.seconds, range: 1...60, unit: "s")
        case .unzip, .compress, .combinePDF, .stash, .reveal, .open, .trash,
             .darkMode, .mute, .lockScreen, .emptyTrash, .ejectDisks, .openStash, .toggleStashes,
             .cleanText, .cleanLink:
            EmptyView()
        }
    }

    private func folderKey(_ placeholder: String) -> some View {
        PickKey(glyph: "folder.fill", value: folderName(step.folder), placeholder: placeholder, help: step.folder) {
            if let url = Pickers.folder(title: "Which folder?") { step.folder = url.path }
        }
    }

    @ViewBuilder private var source: some View {
        SourceEditor(text: Binding(get: { step.code.effectiveSource },
                                   set: { step.code.source = $0; step.code.isCustomised = true }))
        if step.code.isCustomised {
            HStack(spacing: 8) {
                Chip(text: "EDITED", tint: Theme.ambient, size: 8.5)
                Button("Revert") { step.code.isCustomised = false; step.code.source = "" }
                    .industrialButton(.ghost, compact: true)
                Spacer()
            }
        }
    }

    private static let formats: [(title: String, targets: [FileConverter.Target])] = [
        ("Images", FileConverter.Family.image.targets),
        ("Documents", FileConverter.Family.document.targets),
        ("Audio", FileConverter.Family.audio.targets),
    ]
}

extension ScriptStep.Kind {
    /// Whether a step has anything to set.
    var hasSettings: Bool {
        switch self {
        case .unzip, .compress, .combinePDF, .stash, .reveal, .open, .trash,
             .darkMode, .mute, .lockScreen, .emptyTrash, .ejectDisks, .openStash, .toggleStashes,
             .cleanText, .cleanLink:
            return false
        default:
            return true
        }
    }
}

/// Every step kind, grouped, for the add-step menu.
struct StepKindItems: View {
    let pick: (ScriptStep.Kind) -> Void

    var body: some View {
        ForEach(ScriptStep.Group.allCases) { group in
            Section(group.label) {
                ForEach(group.kinds) { kind in
                    Button { pick(kind) } label: { Label(kind.label, systemImage: kind.glyph) }
                }
            }
        }
    }
}

// MARK: - How it reports

struct OutputEditor: View {
    @Binding var output: ScriptOutput

    var body: some View {
        EditorRow(label: "IF IT WORKS") { alertMenu($output.onSuccess) }
        EditorRow(label: "IF IT FAILS") { alertMenu($output.onFailure) }
    }

    private func alertMenu(_ alert: Binding<ScriptOutput.Alert>) -> some View {
        SlotMenu(value: alert.wrappedValue.label) {
            ForEach(ScriptOutput.Alert.allCases) { option in Button(option.label) { alert.wrappedValue = option } }
        }
    }
}
