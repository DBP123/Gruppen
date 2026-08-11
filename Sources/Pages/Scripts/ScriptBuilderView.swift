import AppKit
import SwiftUI

/// The Script Builder.
///
/// Two layers, one screen: a preset and a few fields for people who want a
/// working automation without writing anything, and a drawer underneath holding
/// the actual source for people who do. The drawer is not a different mode —
/// it is the same script, and editing it there simply stops the preset from
/// regenerating over the top.
struct ScriptBuilderView: View {
    @EnvironmentObject private var store: GroupStore

    @State private var selection: UUID?

    private var selectedGroup: AppGroup? {
        guard let selection else { return store.groups.first }
        return store.groups.first { $0.id == selection } ?? store.groups.first
    }

    var body: some View {
        SettingsScroll {
            if store.groups.isEmpty {
                LabeledSection(label: "NO GRUPPEN") {
                    FootNote("A script is attached to a Gruppe and runs when files are dropped on it. Make a Gruppe first.")
                }
            } else {
                LabeledSection(label: "GRUPPE") {
                    GruppePicker(selection: $selection)
                }
                if let group = selectedGroup {
                    ScriptEditor(group: group)
                        .id(group.id)
                }
            }
        }
    }
}

/// Which Gruppe the script belongs to, and whether it has one.
private struct GruppePicker: View {
    @EnvironmentObject private var store: GroupStore
    @Binding var selection: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.groups) { group in
                    let active = (selection ?? store.groups.first?.id) == group.id
                    Button { selection = group.id } label: {
                        HStack(spacing: 6) {
                            LED(color: group.color,
                                lit: group.script?.isEnabled == true,
                                size: 6)
                            Text(group.name).font(Theme.sans(11, .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .machined(fill: active ? Color(hex: 0x17171A) : Theme.machined,
                              border: active ? Theme.ambient : Theme.machinedBorder)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

/// Everything about one Gruppe's script.
private struct ScriptEditor: View {
    @EnvironmentObject private var store: GroupStore
    let group: AppGroup

    @State private var config: ScriptConfig
    @State private var showingSource = false
    @State private var console: String?
    @State private var consoleFailed = false
    @State private var running = false

    init(group: AppGroup) {
        self.group = group
        _config = State(initialValue: group.script ?? ScriptConfig())
    }

    var body: some View {
        Group {
            LabeledSection(label: "TRIGGER") {
                SettingToggle(title: "Run on drop",
                              detail: "Dropping files on \(group.name) runs this script instead of opening them",
                              isOn: binding(\.isEnabled))
                FootNote("Paths arrive as arguments — $1, $2, \"$@\" — so a file name is never treated as part of the command.")
            }

            LabeledSection(label: "PRESET") {
                MachinedMenu(label: config.preset.label, detail: config.preset.detail) {
                    ForEach(ScriptConfig.Preset.allCases) { preset in
                        Button(preset.label) { update { $0.preset = preset } }
                    }
                }
                if config.preset.usesDirectory { directoryRow }
                if config.preset.usesFilter { filterRow }
                if config.preset.usesCommand { commandRow }
            }

            LabeledSection(label: "INTERPRETER") {
                MachinedMenu(label: config.interpreter.label,
                             detail: interpreterDetail) {
                    ForEach(ScriptConfig.Interpreter.allCases) { interpreter in
                        Button(interpreter.label) { update { $0.interpreter = interpreter } }
                    }
                }
            }

            sourceDrawer

            LabeledSection(label: "TEST") {
                HStack(spacing: 8) {
                    Button("Run on files…", action: testRun)
                        .industrialButton(.secondary)
                        .disabled(running)
                    if running {
                        Text("Running…").font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                }
                .panelRow()
                if let console {
                    ConsoleView(text: console, failed: consoleFailed)
                }
            }
        }
    }

    // MARK: Preset fields

    private var directoryRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Destination").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Text(config.directory.isEmpty ? "~/Desktop" : config.directory)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: chooseDirectory)
                .industrialButton(.secondary)
        }
        .panelRow()
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Only this extension").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Text("Leave empty for everything").font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            MachinedField(text: binding(\.fileExtension), placeholder: "pdf", width: 90)
        }
        .panelRow()
    }

    private var commandRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            MachinedField(text: binding(\.command), placeholder: "sips -s format png", width: nil)
            Text(config.preset == .transform
                 ? "Run once per file, with the path appended."
                 : "Run once, with every path appended.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
        }
        .panelRow()
    }

    // MARK: Source

    private var sourceDrawer: some View {
        LabeledSection(label: "SOURCE") {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showingSource.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showingSource ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(showingSource ? "Hide source" : "Show source")
                            .font(Theme.sans(12, .medium))
                    }
                }
                .industrialButton(.secondary)

                if config.isCustomised {
                    Chip(text: "EDITED", tint: Theme.ambient, size: 9)
                    Button("Revert to preset") {
                        update { $0.isCustomised = false; $0.source = "" }
                    }
                    .industrialButton(.ghost)
                }
                Spacer()
            }

            if showingSource {
                SourceInspector(text: Binding(
                    get: { config.effectiveSource },
                    set: { newValue in
                        update { $0.source = newValue; $0.isCustomised = true }
                    }
                ))
            }
        }
    }

    // MARK: Actions

    private var interpreterDetail: String {
        if let path = ScriptExecutionEngine.resolveInterpreter(config.interpreter) {
            return path
        }
        return "Not installed — looked in \(config.interpreter.candidatePaths.joined(separator: ", "))"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ScriptConfig, Value>) -> Binding<Value> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// One place where a change is applied and persisted, so the editor cannot
    /// drift from what will actually run.
    private func update(_ change: (inout ScriptConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        config = next
        store.setScript(next, for: group)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a destination"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.directory = url.path }
    }

    /// Runs the script for real, on files the user picks. There is no dry run:
    /// a script that moves files would have to be lied to about what it is
    /// doing, and a test that does something different from the real thing is
    /// worse than no test.
    private func testRun() {
        let panel = NSOpenPanel()
        panel.title = "Run \(group.name)'s script on…"
        panel.prompt = "Run"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        let script = config
        running = true
        console = nil
        Task {
            do {
                let run = try await ScriptExecutionEngine.run(script, paths: urls)
                await MainActor.run {
                    consoleFailed = false
                    console = run.transcript.isEmpty
                        ? String(format: "exit 0 · %.2fs", run.duration)
                        : run.transcript + String(format: "\n\nexit 0 · %.2fs", run.duration)
                    running = false
                }
            } catch {
                await MainActor.run {
                    consoleFailed = true
                    console = error.localizedDescription
                    running = false
                }
            }
        }
    }
}

// MARK: - Controls

/// A machined dropdown. `Menu` with the system's own chrome stripped off, so it
/// matches the panels rather than the rest of macOS.
private struct MachinedMenu<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .machined()
    }
}

/// A recessed text field.
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

/// The source drawer's editor.
private struct SourceInspector: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 200, maxHeight: 320)
            .machined(cornerRadius: Theme.radiusMd)
    }
}

/// stdout and stderr, after the fact.
private struct ConsoleView: View {
    let text: String
    let failed: Bool

    var body: some View {
        ScrollView {
            Text(text)
                .font(Theme.mono(10))
                .foregroundStyle(failed ? Theme.red : Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
        .padding(8)
        .machined(cornerRadius: Theme.radiusMd)
    }
}
