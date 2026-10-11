import AppKit
import SwiftUI

/// The Script Builder: a library on the left, and one script on the right
/// drawn as a flow — three connected blocks read left to right, *when* this
/// happens → *do* that → *then* answer like so.
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
            LED(color: Theme.ambient, lit: script.isArmable, size: 6)
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

private extension ScriptAction.Kind {
    var glyph: String {
        switch self {
        case .shellCommand: return "terminal"
        case .scriptCode: return "curlybraces"
        case .webhook: return "network"
        }
    }
}

private extension ScriptFeedback {
    var glyph: String {
        switch self {
        case .silent: return "speaker.slash"
        case .banner: return "bell.badge"
        case .audio: return "speaker.wave.2"
        case .log: return "doc.text"
        }
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

/// One script as a flow: a header with its name and run controls, then the
/// three blocks joined by arrows. The arrows light when the script is live —
/// switched on with a complete trigger — so a glance says whether it will fire.
private struct ScriptDetail: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var triggers: ScriptTriggerCoordinator

    let script: Script
    let onDelete: () -> Void
    @State private var draft: Script
    @State private var showingSource = false
    @State private var running = false

    init(script: Script, onDelete: @escaping () -> Void) {
        self.script = script
        self.onDelete = onDelete
        _draft = State(initialValue: script)
    }

    private var isLive: Bool { draft.isArmable && draft.trigger.kind != .manual }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                flow
                if showingSource && draft.action.isProcess { sourceCard }
                runs
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel.grain(0.26))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LED(color: Theme.ambient, lit: isLive, size: 8)
            TextField("Script name", text: binding(\.name))
                .textFieldStyle(.plain)
                .font(Theme.sans(18, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            if draft.trigger.kind != .manual {
                Text("Automatic").font(Theme.sans(12)).foregroundStyle(Theme.textSecondary)
                Toggle("", isOn: binding(\.isActive))
                    .labelsHidden()
                    .toggleStyle(.industrial)
                    .help(draft.isActive && !draft.isArmable
                          ? "On, but the trigger is not finished"
                          : "Run whenever the trigger fires")
            }
            Button { runNow(paths: []) } label: {
                Label(running ? "Running…" : "Run", systemImage: "play.fill")
            }
            .industrialButton(.primary)
            .disabled(running)
            Menu {
                Button("Run on files…", action: chooseAndRun)
                Divider()
                Button("Duplicate") { library.duplicate(draft) }
                Button("Delete", action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuKey()
        }
    }

    // MARK: Flow

    /// Side by side when there is room, stacked when there is not.
    private var flow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) { blocks(vertical: false) }
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) { blocks(vertical: true) }
        }
    }

    @ViewBuilder private func blocks(vertical: Bool) -> some View {
        whenBlock
        FlowArrow(lit: isLive, vertical: vertical)
        doBlock
        FlowArrow(lit: isLive, vertical: vertical)
        thenBlock
    }

    private var whenBlock: some View {
        FlowBlock(step: "WHEN", tint: Theme.cyan, icon: draft.trigger.kind.glyph,
                  title: draft.trigger.kind.label, help: draft.trigger.kind.detail,
                  complete: draft.trigger.isConfigured) {
            ForEach(ScriptTrigger.Kind.allCases) { kind in
                Button(kind.label) { update { $0.trigger.kind = kind } }
            }
        } content: {
            whenContent
        }
    }

    @ViewBuilder private var whenContent: some View {
        switch draft.trigger.kind {
        case .folderWatch:
            PickKey(icon: "folder.fill",
                    value: draft.trigger.watchedFolder.isEmpty ? nil
                        : URL(fileURLWithPath: draft.trigger.watchedFolder).lastPathComponent,
                    placeholder: "Choose a folder",
                    help: draft.trigger.watchedFolder.isEmpty
                        ? "Only new arrivals run the script; their paths are the arguments"
                        : draft.trigger.watchedFolder,
                    action: chooseFolder)
        case .hotkey:
            ShortcutKeys(shortcut: draft.trigger.shortcut) { recorded in
                update { $0.trigger.shortcut = recorded }
            }
        case .appLifecycle:
            HStack(spacing: 6) {
                Menu {
                    ForEach(ScriptTrigger.AppMatch.allCases) { match in
                        Button(match.label) { update { $0.trigger.appMatch = match } }
                    }
                } label: { MenuKeyLabel(title: draft.trigger.appMatch.label, compact: false) }
                .menuKey()
                .help(draft.trigger.appMatch.detail)
                Menu {
                    ForEach(ScriptTrigger.AppEvent.allCases) { event in
                        Button(event.label) { update { $0.trigger.appEvent = event } }
                    }
                } label: { MenuKeyLabel(title: draft.trigger.appEvent.label, compact: false) }
                .menuKey()
            }
            if draft.trigger.appMatch == .bundleIdentifier {
                PickKey(icon: "app",
                        value: draft.trigger.appName.isEmpty
                            ? (draft.trigger.bundleIdentifier.isEmpty ? nil : draft.trigger.bundleIdentifier)
                            : draft.trigger.appName,
                        placeholder: "Choose an app",
                        help: draft.trigger.bundleIdentifier,
                        action: chooseApp)
            } else {
                FlowField(text: binding(\.trigger.processName), placeholder: "Process name, e.g. java")
                    .help("macOS announces apps starting and stopping, not bare processes. A process name fires on quit, and on launch only for a real app bundle.")
            }
        case .systemState:
            Menu {
                ForEach(ScriptTrigger.SystemEvent.allCases) { event in
                    Button(event.label) { update { $0.trigger.systemEvent = event } }
                }
            } label: { MenuKeyLabel(title: draft.trigger.systemEvent.label, compact: false) }
            .menuKey()
            if draft.trigger.systemEvent.usesThreshold {
                HStack(spacing: 10) {
                    IndustrialSlider(value: Binding(
                        get: { Double(draft.trigger.threshold) },
                        set: { newValue in update { $0.trigger.threshold = Int(newValue.rounded()) } }
                    ), range: 5...95, step: 5)
                    Text("\(draft.trigger.threshold)%")
                        .font(Theme.mono(11)).foregroundStyle(Theme.orange)
                        .frame(width: 34, alignment: .trailing)
                }
                .help("Fires once, on the way down")
            }
        case .customNotification:
            Menu {
                ForEach(ScriptTrigger.NotificationScope.allCases) { scope in
                    Button(scope.label) { update { $0.trigger.notificationScope = scope } }
                }
            } label: { MenuKeyLabel(title: draft.trigger.notificationScope.label, compact: false) }
            .menuKey()
            .help(draft.trigger.notificationScope.detail)
            FlowField(text: binding(\.trigger.notificationName), placeholder: "com.example.somethingHappened")
                .help(draft.trigger.notificationScope == .darwin
                      ? "Test it from a terminal: notifyutil -p \(draft.trigger.notificationName.isEmpty ? "your.name.here" : draft.trigger.notificationName)"
                      : "Posted by other apps through NSDistributedNotificationCenter")
        case .manual:
            EmptyView()
        }
    }

    private var doBlock: some View {
        FlowBlock(step: "DO", tint: Theme.orange, icon: draft.action.kind.glyph,
                  title: draft.action.kind.label, help: draft.action.kind.detail,
                  complete: draft.action.isConfigured) {
            ForEach(ScriptAction.Kind.allCases) { kind in
                Button(kind.label) { update { $0.action.kind = kind } }
            }
        } content: {
            switch draft.action.kind {
            case .shellCommand:
                FlowField(text: binding(\.action.command), placeholder: "open -a Finder", multiline: true)
            case .scriptCode:
                Menu {
                    ForEach(ScriptAction.Interpreter.allCases) { interpreter in
                        Button(interpreter.label) { update { $0.action.interpreter = interpreter } }
                    }
                } label: { MenuKeyLabel(title: draft.action.interpreter.label, compact: false) }
                .menuKey()
                .help(ScriptExecutionEngine.interpreterExists(draft.action.interpreter)
                      ? draft.action.interpreter.path
                      : "Not installed at \(draft.action.interpreter.path)")
            case .webhook:
                FlowField(text: binding(\.action.webhookURL), placeholder: "https://example.com/hook")
                Menu {
                    ForEach(ScriptAction.HTTPMethod.allCases) { method in
                        Button(method.label) { update { $0.action.httpMethod = method } }
                    }
                } label: { MenuKeyLabel(title: draft.action.httpMethod.label, compact: false) }
                .menuKey()
                .help(draft.action.httpMethod == .post
                      ? "Sends the incoming file paths as a JSON body"
                      : "Sends the request with no body")
            }
            if draft.action.isProcess {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showingSource.toggle() }
                } label: {
                    Label(showingSource ? "Hide source" : "Edit source",
                          systemImage: draft.action.isCustomised ? "pencil.circle.fill" : "chevron.left.forwardslash.chevron.right")
                }
                .industrialButton(.ghost)
            }
        }
    }

    private var thenBlock: some View {
        FlowBlock(step: "THEN", tint: Theme.purple, icon: draft.feedback.glyph,
                  title: draft.feedback.label, help: draft.feedback.detail, complete: true) {
            ForEach(ScriptFeedback.allCases) { option in
                Button(option.label) { update { $0.feedback = option } }
            }
        } content: {
            EmptyView()
        }
    }

    // MARK: Source

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SOURCE")
                    .font(Theme.mono(10, .semibold)).tracking(1.1)
                    .foregroundStyle(Theme.textMuted)
                    .help("File paths arrive as arguments — $1, $2, \"$@\" — never inserted into the text")
                if draft.action.isCustomised {
                    Chip(text: "EDITED", tint: Theme.ambient, size: 9)
                    Spacer()
                    Button("Revert") {
                        update { $0.action.isCustomised = false; $0.action.source = "" }
                    }
                    .industrialButton(.ghost, compact: true)
                    .help("Back to the source generated from the blocks above")
                }
            }
            SourceInspector(text: Binding(
                get: { draft.action.effectiveSource },
                set: { newValue in update { $0.action.source = newValue; $0.action.isCustomised = true } }
            ))
        }
        .transition(.opacity)
    }

    // MARK: Runs

    /// The last runs, newest first, once there are any.
    @ViewBuilder private var runs: some View {
        let entries = Array((library.logs[draft.id] ?? []).reversed())
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("RUNS")
                        .font(Theme.mono(10, .semibold)).tracking(1.1)
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("Clear") { library.clearLog(for: draft.id) }
                        .industrialButton(.ghost, compact: true)
                }
                RunList(entries: entries)
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

// MARK: - Flow pieces

/// One step of the flow: its colour and icon, the choice for this step as a
/// dropdown title, and whatever that choice needs set underneath.
///
/// Its border takes the step's colour once the step is complete, so an
/// unfinished trigger or action is the one block left unlit.
private struct FlowBlock<Choices: View, Content: View>: View {
    let step: String
    let tint: Color
    let icon: String
    let title: String
    let help: String
    let complete: Bool
    @ViewBuilder let choices: Choices
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
                Text(step)
                    .font(Theme.mono(10, .semibold)).tracking(1.4)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }

            Menu { choices } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hovering ? tint : Theme.textMuted)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { hovering = $0 }
            .help(help)

            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 210, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .machined(cornerRadius: 12, border: complete ? tint.opacity(0.55) : Theme.machinedBorder)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The join between two blocks. Lit while the script is live.
private struct FlowArrow: View {
    let lit: Bool
    let vertical: Bool

    var body: some View {
        Image(systemName: vertical ? "arrow.down" : "arrow.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(lit ? Theme.ambient : Theme.textMuted.opacity(0.6))
            .shadow(color: lit ? Theme.ambient.opacity(0.7) : .clear, radius: 5)
            .frame(width: vertical ? nil : 30, height: vertical ? 26 : nil)
            .frame(maxHeight: vertical ? nil : .infinity)
            .animation(.easeOut(duration: 0.2), value: lit)
    }
}

/// A text field sized for a block.
private struct FlowField: View {
    @Binding var text: String
    let placeholder: String
    var multiline = false

    var body: some View {
        TextField(placeholder, text: $text, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 1...4 : 1...1)
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .machined()
    }
}

/// A key naming the chosen folder or app, or asking for one. The full path
/// is the tooltip.
private struct PickKey: View {
    let icon: String
    let value: String?
    let placeholder: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(value ?? placeholder).lineLimit(1).truncationMode(.middle)
            }
        }
        .industrialButton(.secondary)
        .help(help)
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

/// Each run: when, whether it worked, and what it said.
private struct RunList: View {
    let entries: [ScriptLibrary.LogEntry]

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(entry.failed ? Theme.red : Theme.green)
                            .frame(width: 6, height: 6)
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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .machined(cornerRadius: 10)
    }
}
