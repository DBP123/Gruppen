import AppKit
import SwiftUI

/// The Script Builder: a library on the left, and one script's four blocks on
/// the right — what it is, when it runs, what it does, how it answers.
struct ScriptBuilderView: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var triggers: ScriptTriggerCoordinator

    @State private var selection: UUID?

    private var selected: Script? {
        guard let id = selection ?? library.scripts.first?.id else { return nil }
        return library.scripts.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            libraryList
            Divider().overlay(Theme.machinedBorder)
            if let script = selected {
                ScriptDetail(script: script).id(script.id)
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
                        LibraryRow(script: script,
                                   isSelected: (selection ?? library.scripts.first?.id) == script.id)
                            .onTapGesture { selection = script.id }
                            .contextMenu {
                                Button("Duplicate") { library.duplicate(script) }
                                Button("Delete") {
                                    library.remove(script)
                                    if selection == script.id { selection = nil }
                                }
                            }
                    }
                }
                .padding(10)
            }
            Divider().overlay(Theme.machinedBorder)
            Button {
                let script = library.add()
                selection = script.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("New script").font(Theme.sans(12, .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.root)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text("No scripts yet")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textSecondary)
            Text("A script runs on an event you choose and is not tied to a Gruppe.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var library: ScriptLibrary
    let script: Script
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            LED(color: Theme.ambient, lit: script.isArmable, size: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(script.name)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(script.trigger.kind.label)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(fill: isSelected ? Color(hex: 0x17171A) : Theme.machined,
                  border: isSelected ? Theme.ambient : Theme.machinedBorder)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

private struct ScriptDetail: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var triggers: ScriptTriggerCoordinator

    let script: Script
    @State private var draft: Script
    @State private var showingSource = false
    @State private var showingLog = false
    @State private var running = false

    init(script: Script) {
        self.script = script
        _draft = State(initialValue: script)
    }

    var body: some View {
        SettingsScroll {
            metadata
            trigger
            action
            feedback
            testBlock
        }
    }

    // MARK: 1 — Metadata

    private var metadata: some View {
        LabeledSection(label: "Automation Status") {
            MachinedField(text: binding(\.name), placeholder: "Script name", width: nil)
                .panelRow()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.isActive ? "Active (Listening for triggers)"
                                        : "Inactive (Manual run only)")
                        .font(Theme.sans(13, .medium))
                        .foregroundStyle(draft.isActive ? Theme.textPrimary : Theme.textSecondary)
                    Text(draft.isActive
                         ? (draft.isArmable
                            ? "Listening for its trigger."
                            : "Enabled, but the trigger below is incomplete.")
                         : "Script will only run when the Run button is pressed.")
                        .font(Theme.mono(10))
                        .foregroundStyle(draft.isArmable ? Theme.green
                                         : (draft.isActive ? Theme.red : Theme.textMuted))
                }
                Spacer()
                Toggle("", isOn: binding(\.isActive))
                    .labelsHidden()
                    .toggleStyle(.industrial)
            }
            .panelRow()
        }
    }

    // MARK: 2 — Trigger

    private var trigger: some View {
        LabeledSection(label: "Trigger Event") {
            FootNote("Choose the system event that automatically invokes this script.")
            MachinedMenu(label: draft.trigger.kind.label, detail: draft.trigger.kind.detail) {
                ForEach(ScriptTrigger.Kind.allCases) { kind in
                    Button(kind.label) { update { $0.trigger.kind = kind } }
                }
            }

            switch draft.trigger.kind {
            case .folderWatch:
                PathRow(title: "Watched folder",
                        path: draft.trigger.watchedFolder,
                        placeholder: "Choose a folder",
                        action: chooseFolder)
                FootNote("Kernel-fed via FSEvents. Files already in the folder are ignored — only new arrivals run the script, and their paths are the arguments.")
            case .hotkey:
                ShortcutRow(shortcut: draft.trigger.shortcut) { recorded in
                    update { $0.trigger.shortcut = recorded }
                }
            case .appLifecycle:
                MachinedMenu(label: draft.trigger.appMatch.label,
                             detail: draft.trigger.appMatch.detail) {
                    ForEach(ScriptTrigger.AppMatch.allCases) { match in
                        Button(match.label) { update { $0.trigger.appMatch = match } }
                    }
                }
                if draft.trigger.appMatch == .bundleIdentifier {
                    PathRow(title: "Application",
                            path: draft.trigger.appName.isEmpty ? draft.trigger.bundleIdentifier : draft.trigger.appName,
                            placeholder: "Choose an app",
                            action: chooseApp)
                } else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Process name").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                            Text("As it appears in Activity Monitor or `ps` — java, node, python3")
                                .font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        MachinedField(text: binding(\.trigger.processName), placeholder: "java", width: 140)
                    }
                    .panelRow()
                    FootNote("macOS announces applications starting and stopping, but not bare Unix processes starting. So a process name fires on quit for anything already running when this was enabled, and on launch only when the process is a real app bundle. Catching any process launch would need a scan on a timer, which this app does not do.")
                }
                MachinedMenu(label: "When it \(draft.trigger.appEvent.label)", detail: nil) {
                    ForEach(ScriptTrigger.AppEvent.allCases) { event in
                        Button("When it \(event.label)") { update { $0.trigger.appEvent = event } }
                    }
                }
            case .systemState:
                MachinedMenu(label: draft.trigger.systemEvent.label, detail: nil) {
                    ForEach(ScriptTrigger.SystemEvent.allCases) { event in
                        Button(event.label) { update { $0.trigger.systemEvent = event } }
                    }
                }
                if draft.trigger.systemEvent.usesThreshold {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Threshold").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                            Text("Fires once, on the way down")
                                .font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Text("\(draft.trigger.threshold)%")
                            .font(Theme.mono(11)).foregroundStyle(Theme.orange)
                        IndustrialSlider(value: Binding(
                            get: { Double(draft.trigger.threshold) },
                            set: { newValue in
                                update { script in script.trigger.threshold = Int(newValue.rounded()) }
                            }
                        ), range: 5...95, step: 5)
                        .frame(width: 160)
                    }
                    .panelRow()
                }
                FootNote("Power events come from IOKit's notification source. CPU thresholds are deliberately absent — there is no notification for them, and sampling on a timer is the one thing this app does not do.")
            case .customNotification:
                MachinedMenu(label: draft.trigger.notificationScope.label,
                             detail: draft.trigger.notificationScope.detail) {
                    ForEach(ScriptTrigger.NotificationScope.allCases) { scope in
                        Button(scope.label) { update { $0.trigger.notificationScope = scope } }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notification name").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    MachinedField(text: binding(\.trigger.notificationName),
                                  placeholder: "com.example.somethingHappened", width: nil)
                    Text(draft.trigger.notificationScope == .darwin
                         ? "Test it from a terminal: notifyutil -p \(draft.trigger.notificationName.isEmpty ? "your.name.here" : draft.trigger.notificationName)"
                         : "Posted by other apps through NSDistributedNotificationCenter.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                }
                .panelRow()
            case .manual:
                FootNote("Nothing arms this. Use the run buttons at the bottom of the page.")
            }
        }
    }

    // MARK: 3 — Action

    private var action: some View {
        LabeledSection(label: "Execution Action") {
            FootNote("Define the command or script logic executed when the trigger fires.")

            MachinedMenu(label: draft.action.kind.label, detail: draft.action.kind.detail) {
                ForEach(ScriptAction.Kind.allCases) { kind in
                    Button(kind.label) { update { $0.action.kind = kind } }
                }
            }

            switch draft.action.kind {
            case .shellCommand:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    MachinedField(text: binding(\.action.command),
                                  placeholder: "open -a Finder", width: nil)
                }
                .panelRow()
            case .scriptCode:
                MachinedMenu(label: draft.action.interpreter.label,
                             detail: ScriptExecutionEngine.interpreterExists(draft.action.interpreter)
                                ? draft.action.interpreter.path
                                : "Not found at \(draft.action.interpreter.path)") {
                    ForEach(ScriptAction.Interpreter.allCases) { interpreter in
                        Button(interpreter.label) { update { $0.action.interpreter = interpreter } }
                    }
                }
            case .webhook:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target URL").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    MachinedField(text: binding(\.action.webhookURL),
                                  placeholder: "https://example.com/hook", width: nil)
                }
                .panelRow()
                MachinedMenu(label: draft.action.httpMethod.label,
                             detail: draft.action.httpMethod == .post
                                ? "Sends the incoming file paths as a JSON body."
                                : "Sends the request with no body.") {
                    ForEach(ScriptAction.HTTPMethod.allCases) { method in
                        Button(method.label) { update { $0.action.httpMethod = method } }
                    }
                }
            }

            if draft.action.isProcess {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { showingSource.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showingSource ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                            Text(showingSource ? "Hide Source" : "Inspect Source")
                                .font(Theme.sans(12, .medium))
                        }
                    }
                    .industrialButton(.secondary)
                    if draft.action.isCustomised {
                        Chip(text: "EDITED", tint: Theme.ambient, size: 9)
                        Button("Revert to generated") {
                            update { $0.action.isCustomised = false; $0.action.source = "" }
                        }
                        .industrialButton(.ghost)
                    }
                    Spacer()
                }
                if showingSource {
                    SourceInspector(text: Binding(
                        get: { draft.action.effectiveSource },
                        set: { newValue in
                            update { $0.action.source = newValue; $0.action.isCustomised = true }
                        }
                    ))
                    FootNote("Incoming file paths are passed as standard arguments — $1, $2, \"$@\" — never inserted into the command text.")
                }
            }
        }
    }

    // MARK: 4 — Feedback

    private var feedback: some View {
        LabeledSection(label: "Execution Feedback") {
            FootNote("Configure how the app responds upon script completion.")
            MachinedMenu(label: draft.feedback.label, detail: draft.feedback.detail) {
                ForEach(ScriptFeedback.allCases) { option in
                    Button(option.label) { update { $0.feedback = option } }
                }
            }
        }
    }

    // MARK: Test + log

    private var testBlock: some View {
        LabeledSection(label: "Run") {
            HStack(spacing: 8) {
                Button("Run") { runNow(paths: []) }
                    .industrialButton(.secondary)
                    .disabled(running)
                Button("Run on Files…") { chooseAndRun() }
                    .industrialButton(.secondary)
                    .disabled(running)
                if running {
                    Text("Running…").font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showingLog.toggle() }
                } label: {
                    Text(showingLog ? "Hide log" : "Log")
                        .font(Theme.sans(12, .medium))
                }
                .industrialButton(.ghost)
            }
            .panelRow()

            FootNote(draft.trigger.kind.providesFiles
                     ? "This trigger passes files. Each path arrives as a standard argument — $1, $2, \"$@\". Run executes with no arguments; Run on Files… lets you supply them by hand."
                     : "This trigger passes no files, so the script runs with no arguments. Run on Files… lets you supply some for testing; they arrive as $1, $2.")

            if showingLog {
                let entries = library.logs[draft.id] ?? []
                if entries.isEmpty {
                    FootNote("Nothing has run yet.")
                } else {
                    LogDrawer(entries: entries.reversed()) { library.clearLog(for: draft.id) }
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
        guard let url = pickDirectory(title: "Watch which folder?") else { return }
        update { $0.trigger.watchedFolder = url.path }
    }


    private func pickDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
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

// MARK: - Controls

/// A machined dropdown.
///
/// `.menuStyle(.borderlessButton)` discards the supplied label and draws its own
/// compact one — chevron on the left, no detail line. `.button` keeps the label
/// as written, and `.buttonStyle(.plain)` removes the rest of the system chrome.
private struct MachinedMenu<Content: View>: View {
    let label: String
    var detail: String?
    @State private var hovering = false
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    if let detail {
                        // Wraps rather than truncating: these lines exist to say
                        // exactly what happens, and half a sentence with an
                        // ellipsis in it is worse than no sentence.
                        Text(detail)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? Theme.ambient : Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .machined(fill: hovering ? Color(hex: 0x17171A) : Theme.machined)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct MachinedField: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat?

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .machined()
    }
}

private struct PathRow: View {
    let title: String
    let path: String
    let placeholder: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Text(path.isEmpty ? placeholder : path)
                    .font(Theme.mono(10))
                    .foregroundStyle(path.isEmpty ? Theme.textMuted : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: action).industrialButton(.secondary)
        }
        .panelRow()
    }
}

/// Records a global shortcut, through the same `KeyRecorder` the Gruppe editor
/// uses — escape abandons, delete clears, and anything without ⌘/⌥/⌃ keeps
/// listening rather than binding a bare key system-wide.
private struct ShortcutRow: View {
    let shortcut: Shortcut?
    let onRecord: (Shortcut?) -> Void

    @StateObject private var recorder = KeyRecorder()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Keyboard Shortcut").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Text(recorder.isRecording ? "Press keys to set shortcut"
                                          : "Requires ⌘, ⌥ or ⌃")
                    .font(Theme.mono(10))
                    .foregroundStyle(recorder.isRecording ? Theme.ambient : Theme.textMuted)
            }
            Spacer()
            if let shortcut, !recorder.isRecording {
                KeyBadge(text: shortcut.display)
                Button("Clear") { onRecord(nil) }.industrialButton(.ghost)
            }
            Button(recorder.isRecording ? "Cancel" : "Record Shortcut") {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start { recorded in onRecord(recorded) }
                }
            }
            .industrialButton(recorder.isRecording ? .danger : .secondary)
        }
        .panelRow()
        .onDisappear { recorder.stop() }
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

private struct LogDrawer: View {
    let entries: [ScriptLibrary.LogEntry]
    let onClear: () -> Void

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(entries.count) run(s)").font(Theme.mono(9)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button("Clear", action: onClear).industrialButton(.ghost)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.stamp.string(from: entry.date))
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.textMuted.opacity(0.8))
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
        }
        .padding(10)
        .machined(cornerRadius: Theme.radiusMd)
    }
}
