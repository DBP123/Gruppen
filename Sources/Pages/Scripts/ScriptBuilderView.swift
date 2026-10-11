import AppKit
import SwiftUI

/// The Script Builder: a library on the left, and one script on the right,
/// read top to bottom as a sentence — *when* this happens, *do* that, *then*
/// answer like so — with a run bar at the foot.
///
/// Same grammar as the Stash and Telemetry pages: cards of rows, a title and a
/// control per row, and no line of grey under anything. What a choice means is
/// its tooltip; the caveats that used to be paragraphs of footnote are too.
struct ScriptBuilderView: View {
    @EnvironmentObject private var library: ScriptLibrary

    @State private var selection: UUID?

    private var selectedID: UUID? { selection ?? library.scripts.first?.id }
    private var selected: Script? { library.scripts.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            libraryList
            Divider().overlay(Theme.machinedBorder)
            if let script = selected {
                ScriptDetail(script: script, onDelete: { delete(script) }).id(script.id)
            } else {
                emptyState
            }
        }
        .background(Theme.panel)
    }

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(library.scripts) { script in
                        LibraryRow(script: script, isSelected: selectedID == script.id)
                            .onTapGesture { selection = script.id }
                            .contextMenu {
                                Button("Duplicate") { library.duplicate(script) }
                                Button("Delete") { delete(script) }
                            }
                    }
                }
                .padding(10)
            }
            Button(action: newScript) {
                Label("New script", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .industrialButton(.secondary)
            .padding(10)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.root)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Button("New script", action: newScript)
                .industrialButton(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func newScript() {
        selection = library.add().id
    }

    private func delete(_ script: Script) {
        library.remove(script)
        if selection == script.id { selection = nil }
    }
}

/// A script in the library: whether it is listening, its name, and an icon
/// for what sets it off.
private struct LibraryRow: View {
    let script: Script
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            LED(color: Theme.ambient, lit: script.isActive && script.isArmable, size: 6)
            Text(script.name)
                .font(Theme.sans(12, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: script.trigger.kind.glyph)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Theme.ambient : Theme.textMuted)
                .help(script.trigger.kind.label)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(fill: isSelected ? Color(hex: 0x17171A) : Theme.machined,
                  border: isSelected ? Theme.ambient : Theme.machinedBorder)
        .contentShape(Rectangle())
    }
}

private extension ScriptTrigger.Kind {
    var glyph: String {
        switch self {
        case .folderWatch: return "folder"
        case .hotkey: return "command"
        case .appLifecycle: return "app.badge"
        case .systemState: return "bolt"
        case .customNotification: return "bell"
        case .manual: return "hand.tap"
        }
    }
}

// MARK: - Detail

private struct ScriptDetail: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var triggers: ScriptTriggerCoordinator

    let script: Script
    let onDelete: () -> Void
    @State private var draft: Script
    @State private var showingSource = false
    @State private var showingLog = false
    @State private var running = false

    init(script: Script, onDelete: @escaping () -> Void) {
        self.script = script
        self.onDelete = onDelete
        _draft = State(initialValue: script)
    }

    var body: some View {
        SettingsScroll {
            header
            LabeledSection(label: "WHEN") { SettingsCard { whenRows } }
            LabeledSection(label: "DO") { SettingsCard { doRows } }
            LabeledSection(label: "THEN") {
                SettingsCard {
                    MenuRow(title: "After it runs", value: draft.feedback.label, help: draft.feedback.detail) {
                        ForEach(ScriptFeedback.allCases) { option in
                            Button(option.label) { update { $0.feedback = option } }
                        }
                    }
                }
            }
            runBar
        }
    }

    // MARK: Header

    /// The name, and whether it listens. A manual script has nothing to
    /// listen for, so it gets no switch.
    private var header: some View {
        SettingsCard {
            HStack(spacing: 10) {
                TextField("Script name", text: binding(\.name))
                    .textFieldStyle(.plain)
                    .font(Theme.sans(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Menu {
                    Button("Duplicate") { library.duplicate(draft) }
                    Button("Delete", action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuKey()
            }
            .cardRow()

            if draft.trigger.kind != .manual {
                CardDivider()
                HStack(spacing: 10) {
                    Text("Run automatically").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    if draft.isActive && !draft.isArmable {
                        Chip(text: "TRIGGER INCOMPLETE", tint: Theme.red, size: 9)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: binding(\.isActive))
                        .labelsHidden()
                        .toggleStyle(.industrial)
                }
                .cardRow()
            }
        }
    }

    // MARK: When

    @ViewBuilder private var whenRows: some View {
        MenuRow(title: "Trigger", value: draft.trigger.kind.label, help: draft.trigger.kind.detail) {
            ForEach(ScriptTrigger.Kind.allCases) { kind in
                Button(kind.label) { update { $0.trigger.kind = kind } }
            }
        }

        switch draft.trigger.kind {
        case .folderWatch:
            CardDivider()
            PickRow(title: "Folder", icon: "folder.fill",
                    value: draft.trigger.watchedFolder.isEmpty ? nil
                        : URL(fileURLWithPath: draft.trigger.watchedFolder).lastPathComponent,
                    help: draft.trigger.watchedFolder.isEmpty
                        ? "Only new arrivals run the script; their paths are the arguments"
                        : draft.trigger.watchedFolder,
                    action: chooseFolder)
        case .hotkey:
            CardDivider()
            HStack(spacing: 8) {
                Text("Shortcut").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 12)
                ShortcutKeys(shortcut: draft.trigger.shortcut) { recorded in
                    update { $0.trigger.shortcut = recorded }
                }
            }
            .cardRow()
        case .appLifecycle:
            CardDivider()
            MenuRow(title: "Match", value: draft.trigger.appMatch.label, help: draft.trigger.appMatch.detail) {
                ForEach(ScriptTrigger.AppMatch.allCases) { match in
                    Button(match.label) { update { $0.trigger.appMatch = match } }
                }
            }
            CardDivider()
            if draft.trigger.appMatch == .bundleIdentifier {
                PickRow(title: "App", icon: "app",
                        value: draft.trigger.appName.isEmpty
                            ? (draft.trigger.bundleIdentifier.isEmpty ? nil : draft.trigger.bundleIdentifier)
                            : draft.trigger.appName,
                        help: draft.trigger.bundleIdentifier,
                        action: chooseApp)
            } else {
                FieldRow(title: "Process", text: binding(\.trigger.processName), placeholder: "java")
                    .help("macOS announces apps starting and stopping, not bare processes. A process name fires on quit, and on launch only for a real app bundle.")
            }
            CardDivider()
            MenuRow(title: "Fires when it", value: draft.trigger.appEvent.label) {
                ForEach(ScriptTrigger.AppEvent.allCases) { event in
                    Button(event.label) { update { $0.trigger.appEvent = event } }
                }
            }
        case .systemState:
            CardDivider()
            MenuRow(title: "Event", value: draft.trigger.systemEvent.label) {
                ForEach(ScriptTrigger.SystemEvent.allCases) { event in
                    Button(event.label) { update { $0.trigger.systemEvent = event } }
                }
            }
            if draft.trigger.systemEvent.usesThreshold {
                CardDivider()
                HStack(spacing: 12) {
                    Text("Below").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 12)
                    Text("\(draft.trigger.threshold)%")
                        .font(Theme.mono(11)).foregroundStyle(Theme.orange)
                    IndustrialSlider(value: Binding(
                        get: { Double(draft.trigger.threshold) },
                        set: { newValue in update { $0.trigger.threshold = Int(newValue.rounded()) } }
                    ), range: 5...95, step: 5)
                    .frame(width: 160)
                }
                .cardRow()
                .help("Fires once, on the way down")
            }
        case .customNotification:
            CardDivider()
            MenuRow(title: "Scope", value: draft.trigger.notificationScope.label,
                    help: draft.trigger.notificationScope.detail) {
                ForEach(ScriptTrigger.NotificationScope.allCases) { scope in
                    Button(scope.label) { update { $0.trigger.notificationScope = scope } }
                }
            }
            CardDivider()
            FieldRow(title: "Name", text: binding(\.trigger.notificationName),
                     placeholder: "com.example.somethingHappened")
                .help(draft.trigger.notificationScope == .darwin
                      ? "Test it from a terminal: notifyutil -p \(draft.trigger.notificationName.isEmpty ? "your.name.here" : draft.trigger.notificationName)"
                      : "Posted by other apps through NSDistributedNotificationCenter")
        case .manual:
            EmptyView()
        }
    }

    // MARK: Do

    @ViewBuilder private var doRows: some View {
        MenuRow(title: "Action", value: draft.action.kind.label, help: draft.action.kind.detail) {
            ForEach(ScriptAction.Kind.allCases) { kind in
                Button(kind.label) { update { $0.action.kind = kind } }
            }
        }

        switch draft.action.kind {
        case .shellCommand:
            CardDivider()
            FieldRow(title: "Command", text: binding(\.action.command), placeholder: "open -a Finder")
        case .scriptCode:
            CardDivider()
            MenuRow(title: "Language", value: draft.action.interpreter.label,
                    help: draft.action.interpreter.path,
                    warning: ScriptExecutionEngine.interpreterExists(draft.action.interpreter)
                        ? nil : "NOT INSTALLED") {
                ForEach(ScriptAction.Interpreter.allCases) { interpreter in
                    Button(interpreter.label) { update { $0.action.interpreter = interpreter } }
                }
            }
        case .webhook:
            CardDivider()
            FieldRow(title: "URL", text: binding(\.action.webhookURL), placeholder: "https://example.com/hook")
            CardDivider()
            MenuRow(title: "Method", value: draft.action.httpMethod.label,
                    help: draft.action.httpMethod == .post
                        ? "Sends the incoming file paths as a JSON body"
                        : "Sends the request with no body") {
                ForEach(ScriptAction.HTTPMethod.allCases) { method in
                    Button(method.label) { update { $0.action.httpMethod = method } }
                }
            }
        }

        if draft.action.isProcess {
            CardDivider()
            HStack(spacing: 8) {
                Text("Source").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    .help("File paths arrive as arguments — $1, $2, \"$@\" — never inserted into the text")
                if draft.action.isCustomised {
                    Chip(text: "EDITED", tint: Theme.ambient, size: 9)
                }
                Spacer(minLength: 12)
                if draft.action.isCustomised {
                    Button("Revert") {
                        update { $0.action.isCustomised = false; $0.action.source = "" }
                    }
                    .industrialButton(.ghost)
                    .help("Back to the source generated from the settings above")
                }
                Button(showingSource ? "Hide" : "Edit") {
                    withAnimation(.easeOut(duration: 0.16)) { showingSource.toggle() }
                }
                .industrialButton(.secondary)
            }
            .cardRow()
            if showingSource {
                SourceInspector(text: Binding(
                    get: { draft.action.effectiveSource },
                    set: { newValue in update { $0.action.source = newValue; $0.action.isCustomised = true } }
                ))
                .padding([.horizontal, .bottom], 12)
            }
        }
    }

    // MARK: Run

    private var runBar: some View {
        SettingsCard {
            HStack(spacing: 8) {
                Button {
                    runNow(paths: [])
                } label: {
                    Label(running ? "Running…" : "Run", systemImage: "play.fill")
                }
                .industrialButton(.primary)
                .disabled(running)
                Button("Run on files…", action: chooseAndRun)
                    .industrialButton(.secondary)
                    .disabled(running)
                    .help("The files arrive as $1, $2, \"$@\"")
                Spacer(minLength: 12)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showingLog.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text("Log")
                        Image(systemName: showingLog ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .industrialButton(.ghost)
            }
            .cardRow()

            if showingLog {
                CardDivider()
                LogList(entries: (library.logs[draft.id] ?? []).reversed()) {
                    library.clearLog(for: draft.id)
                }
            }
        }
    }

    // MARK: Plumbing

    private func binding<Value>(_ keyPath: WritableKeyPath<Script, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    /// One place a change is applied and persisted, so the editor cannot drift
    /// from what is armed.
    private func update(_ change: (inout Script) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        draft = next
        library.update(next)
    }

    private func runNow(paths: [URL]) {
        running = true
        showingLog = true
        triggers.run(draft, paths: paths)
        // The run reports itself into the library log; this only clears the
        // button state.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            running = false
        }
    }

    private func chooseAndRun() {
        let panel = NSOpenPanel()
        panel.title = "Run \(draft.name) on…"
        panel.prompt = "Run"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        runNow(paths: panel.urls)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Watch which folder?"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.trigger.watchedFolder = url.path }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Which application?"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier
        else { return }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        update {
            $0.trigger.bundleIdentifier = identifier
            $0.trigger.appName = name
        }
    }
}

// MARK: - Rows

/// A title, and a dropdown key showing the current choice. What the choice
/// means is the key's tooltip.
private struct MenuRow<Content: View>: View {
    let title: String
    let value: String
    var help: String? = nil
    var warning: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            if let warning { Chip(text: warning, tint: Theme.red, size: 9) }
            Spacer(minLength: 12)
            Menu { content } label: { MenuKeyLabel(title: value, compact: false) }
                .menuKey()
                .help(help ?? value)
        }
        .cardRow()
    }
}

/// A title, and a text field filling the rest of the row.
private struct FieldRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .machined()
        }
        .cardRow()
    }
}

/// A title, and a key naming the chosen folder or app — "Choose…" until there
/// is one. The full path is the tooltip.
private struct PickRow: View {
    let title: String
    let icon: String
    let value: String?
    let help: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11))
                    Text(value ?? "Choose…").lineLimit(1).truncationMode(.middle)
                }
            }
            .industrialButton(.secondary)
            .help(help)
        }
        .cardRow()
    }
}

private struct SourceInspector: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 200, maxHeight: 340)
            .machined(cornerRadius: Theme.radiusMd)
    }
}

/// The runs, newest first, inside the run bar's card.
private struct LogList: View {
    let entries: [ScriptLibrary.LogEntry]
    let onClear: () -> Void

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        if entries.isEmpty {
            Text("Nothing has run yet")
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textSecondary)
                .cardRow()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Self.stamp.string(from: entry.date))
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.textMuted)
                                Text(entry.text)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(entry.failed ? Theme.red : Theme.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                Button("Clear log", action: onClear)
                    .industrialButton(.ghost)
            }
            .cardRow()
        }
    }
}
