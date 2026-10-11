import AppKit
import SwiftUI

// The slots of a script module — IN, the numbered steps, OUT — and the editors
// that fold out of them. Every one is the same machined slot with an engraved
// tag, so the module reads as one instrument rather than a form.

// MARK: - Slot chrome

/// One slot: tag, glyph, engraved kind and its one-line value, folding open to
/// edit. Step slots also carry their reorder and remove keys, shown on hover.
struct ScriptSlot<Editor: View>: View {
    let tag: String
    let glyph: String
    let title: String
    let summary: String
    /// Not set up yet: the value reads amber, the same colour as the lamp of a
    /// script that is on but cannot arm.
    var needsSetup = false
    var isOpen: Bool
    var canOpen = true
    var onToggle: () -> Void
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @ViewBuilder let editor: Editor

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen && canOpen {
                DashedRule().padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 8) { editor }
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .machined(cornerRadius: 6, fill: Theme.well,
                  border: isOpen && canOpen ? Theme.ambient.opacity(0.45) : Theme.machinedBorder)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(tag)
                .font(Theme.mono(8.5, .semibold)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 17)
                .recessed(cornerRadius: 3)
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOpen ? Theme.orange : Theme.textSecondary)
                .frame(width: 14)
            Text(title.uppercased())
                .font(Theme.mono(9.5, .semibold)).tracking(1)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize()
            Text(summary)
                .font(Theme.mono(10))
                .foregroundStyle(needsSetup ? Theme.amber : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if onRemove != nil {
                HStack(spacing: 0) {
                    if let onMoveUp { SlotKey(glyph: "chevron.up", help: "Move up", action: onMoveUp) }
                    if let onMoveDown { SlotKey(glyph: "chevron.down", help: "Move down", action: onMoveDown) }
                    if let onRemove { SlotKey(glyph: "xmark", help: "Remove this step", action: onRemove) }
                }
                // Faded rather than removed, so the keys cannot vanish from
                // under the pointer — the same rule as the telemetry cards.
                .opacity(hovering ? 1 : 0)
            }
            if canOpen {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture { if canOpen { withAnimation(.easeOut(duration: 0.16)) { onToggle() } } }
    }
}

private struct SlotKey: View {
    let glyph: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// An engraved label and its control, inside an open slot.
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

/// A dropdown key showing the current choice, sized for a slot.
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

struct SourceEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 150, maxHeight: 320)
            .recessed(cornerRadius: 5)
    }
}

// MARK: - IN

struct TriggerEditor: View {
    @Binding var trigger: ScriptTrigger

    var body: some View {
        EditorRow(label: "TYPE") {
            SlotMenu(value: trigger.kind.label, help: trigger.kind.detail) {
                ForEach(ScriptTrigger.Kind.allCases) { kind in
                    Button { trigger.kind = kind } label: { Label(kind.label, systemImage: kind.glyph) }
                }
            }
        }

        switch trigger.kind {
        case .folderWatch:
            EditorRow(label: "FOLDER") {
                PickKey(glyph: "folder.fill",
                        value: trigger.watchedFolder.isEmpty ? nil : (trigger.watchedFolder as NSString).lastPathComponent,
                        placeholder: "Choose a folder",
                        help: trigger.watchedFolder.isEmpty
                            ? "New arrivals run the script; their paths come down the bus"
                            : trigger.watchedFolder) {
                    if let url = Pickers.folder(title: "Watch which folder?") { trigger.watchedFolder = url.path }
                }
            }
        case .hotkey:
            EditorRow(label: "SHORTCUT") {
                ShortcutKeys(shortcut: trigger.shortcut) { trigger.shortcut = $0 }
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
                EditorRow(label: "BELOW") {
                    IndustrialSlider(value: Binding(get: { Double(trigger.threshold) },
                                                    set: { trigger.threshold = Int($0.rounded()) }),
                                     range: 5...95, step: 5)
                        .frame(width: 160)
                    Text("\(trigger.threshold)%")
                        .font(Theme.mono(10.5).monospacedDigit())
                        .foregroundStyle(Theme.orange)
                }
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
                    .help(trigger.notificationScope == .darwin
                          ? "Test it from a terminal: notifyutil -p \(trigger.notificationName.isEmpty ? "your.name.here" : trigger.notificationName)"
                          : "Posted by other apps through NSDistributedNotificationCenter")
            }
        case .manual:
            EmptyView()
        }
    }
}

// MARK: - Steps

struct StepEditor: View {
    @Binding var step: ScriptStep
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var workspaces: WorkspaceEngine

    var body: some View {
        EditorRow(label: "TYPE") {
            SlotMenu(value: step.kind.label) { StepKindItems { step.setKind($0) } }
        }

        switch step.kind {
        case .moveTo, .copyTo, .zip:
            EditorRow(label: "FOLDER") {
                PickKey(glyph: "folder.fill",
                        value: step.folder.isEmpty ? nil : (step.folder as NSString).lastPathComponent,
                        placeholder: step.kind == .zip ? "Download folder" : "Choose a folder",
                        help: step.folder) {
                    if let url = Pickers.folder(title: "Which folder?") { step.folder = url.path }
                }
                if step.kind == .zip && !step.folder.isEmpty {
                    Button("Use download folder") { step.folder = "" }
                        .industrialButton(.ghost, compact: true)
                }
            }
        case .convert:
            EditorRow(label: "TO") {
                SlotMenu(value: step.format.isEmpty ? "Choose a format" : step.format.uppercased()) {
                    ForEach(Self.formats, id: \.title) { family in
                        Section(family.title) {
                            ForEach(family.targets) { target in
                                Button(target.label) { step.format = target.ext }
                            }
                        }
                    }
                }
            }
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
            EditorRow(label: "WORKSPACE") {
                SlotMenu(value: step.targetName.isEmpty ? "Choose one" : step.targetName) {
                    ForEach(workspaces.profiles) { profile in
                        Button(profile.name) { step.targetID = profile.id; step.targetName = profile.name }
                    }
                }
            }
        case .openURL:
            EditorRow(label: "URL") { SlotField(text: $step.url, placeholder: "https://…") }
        case .webhook:
            EditorRow(label: "URL") { SlotField(text: $step.code.webhookURL, placeholder: "https://example.com/hook") }
            EditorRow(label: "METHOD") {
                SlotMenu(value: step.code.httpMethod.label,
                         help: step.code.httpMethod == .post ? "Sends the file paths as a JSON body" : "Sends no body") {
                    ForEach(ScriptAction.HTTPMethod.allCases) { method in
                        Button(method.label) { step.code.httpMethod = method }
                    }
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
            if !ScriptExecutionEngine.interpreterExists(step.code.effectiveInterpreter) {
                Text("NOT INSTALLED AT \(step.code.effectiveInterpreter.path)")
                    .font(Theme.mono(8.5, .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.red)
            }
            source
        case .wait:
            EditorRow(label: "SECONDS") {
                IndustrialSlider(value: Binding(get: { Double(step.seconds) },
                                                set: { step.seconds = Int($0.rounded()) }),
                                 range: 1...60, step: 1)
                    .frame(width: 160)
                Text("\(step.seconds)s")
                    .font(Theme.mono(10.5).monospacedDigit())
                    .foregroundStyle(Theme.orange)
            }
        case .combinePDF, .stash, .reveal:
            EmptyView()
        }
    }

    /// The code itself, with a way back to the generated version once edited.
    @ViewBuilder private var source: some View {
        SourceEditor(text: Binding(get: { step.code.effectiveSource },
                                   set: { step.code.source = $0; step.code.isCustomised = true }))
        if step.code.isCustomised {
            HStack(spacing: 8) {
                Chip(text: "EDITED", tint: Theme.ambient, size: 8.5)
                Button("Revert") { step.code.isCustomised = false; step.code.source = "" }
                    .industrialButton(.ghost, compact: true)
                    .help(step.kind == .shell ? "Back to a one-line command" : "Back to the template")
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

/// Whether a step has anything to set. Those that do not — combine, stash,
/// reveal — do not fold open at all.
extension ScriptStep.Kind {
    var hasSettings: Bool {
        switch self {
        case .combinePDF, .stash, .reveal: return false
        default: return true
        }
    }
}

/// Every step kind, grouped, for the add-step key and a step's type menu.
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

// MARK: - OUT

struct OutputEditor: View {
    @Binding var output: ScriptOutput

    var body: some View {
        EditorRow(label: "ON SUCCESS") { alertMenu($output.onSuccess) }
        EditorRow(label: "ON FAILURE") { alertMenu($output.onFailure) }
    }

    private func alertMenu(_ alert: Binding<ScriptOutput.Alert>) -> some View {
        SlotMenu(value: alert.wrappedValue.label) {
            ForEach(ScriptOutput.Alert.allCases) { option in
                Button(option.label) { alert.wrappedValue = option }
            }
        }
    }
}

extension ScriptOutput {
    var summary: String {
        if onSuccess == onFailure { return onSuccess == .none ? "Silent" : "\(onSuccess.label) either way" }
        return "OK \(onSuccess.label.lowercased()) · fail \(onFailure.label.lowercased())"
    }
}

// MARK: - Pickers

enum Pickers {
    static func folder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func app() -> (bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.title = "Which application?"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return (identifier, name)
    }

    static func files(title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Run"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
