import AppKit
import SwiftUI

/// The page in the main window: your flows, the blocks you made, and the setup
/// code needs. Building happens in each flow's own editor window — a canvas
/// wants the room.
struct FlowsPage: View {
    @EnvironmentObject private var library: FlowLibrary
    @EnvironmentObject private var engine: FlowEngine
    @AppStorage("flows.tab") private var tab = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SegmentedChoice(options: ["Flows", "Blocks", "Setup"], selection: $tab,
                                help: ["What runs, and when", "Blocks you made, for any flow", "Code's environment, secrets and permissions"])
                    .frame(width: 330)
                switch tab {
                case 1: BlocksTab()
                case 2: SetupTab()
                default: FlowsTab()
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel.grain(0.26))
    }
}

// MARK: - Flows

private struct FlowsTab: View {
    enum Filter: String, CaseIterable { case all = "All", on = "On", byHand = "By hand", failing = "Failing" }

    @EnvironmentObject private var library: FlowLibrary
    @EnvironmentObject private var engine: FlowEngine
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var showingTemplates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    TextField("Find a flow", text: $query).textFieldStyle(.plain).font(Theme.sans(12))
                }
                .padding(.horizontal, 9).padding(.vertical, 6).recessed(cornerRadius: 6).frame(width: 220)
                ForEach(Filter.allCases, id: \.self) { option in
                    Button(option.rawValue) { filter = option }
                        .industrialButton(filter == option ? .secondary : .ghost, compact: true)
                }
                Spacer()
                Menu {
                    Button("From a template…") { showingTemplates = true }
                    Button("Blank") { open(library.add(Flow(name: "New flow"))) }
                    Divider()
                    Button("Import…") { if let flow = FlowFiles.importFiles(library: library) { open(flow) } }
                } label: { Label("New", systemImage: "plus") }
                    .menuKey()
            }

            let shown = flows
            if library.flows.isEmpty {
                EmptyFlows { showingTemplates = true } blank: { open(library.add(Flow(name: "New flow"))) }
            } else if shown.isEmpty {
                Text("NOTHING MATCHES").font(Theme.mono(10, .semibold)).tracking(1.1).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            ForEach(shown) { flow in FlowCard(flow: flow) }

            PaletteShortcutCard()
        }
        .sheet(isPresented: $showingTemplates) {
            TemplateGallery { template in
                showingTemplates = false
                if let template { open(library.add(template.make())) }
            }
        }
    }

    private var flows: [Flow] {
        let registry = library.registry
        let needle = query.trimmingCharacters(in: .whitespaces)
        return library.flows.filter { flow in
            if !needle.isEmpty, !flow.name.localizedCaseInsensitiveContains(needle) { return false }
            switch filter {
            case .all: return true
            case .on: return flow.isEnabled
            case .byHand: return flow.triggers.isEmpty || flow.triggers.contains { $0.definition == Catalog.manual }
            case .failing: return library.lastRun(flow.id)?.outcome == .failed || !flow.isRunnable(registry: registry)
            }
        }
    }

    private func open(_ flow: Flow) { FlowEditorWindows.shared.open(.flow(flow.id)) }
}

/// One flow: its lamp, its name, the sentence it reads as, how it last went,
/// and its keys.
private struct FlowCard: View {
    let flow: Flow
    @EnvironmentObject private var library: FlowLibrary
    @EnvironmentObject private var engine: FlowEngine
    @State private var hovering = false

    var body: some View {
        let registry = library.registry
        let issues = FlowCheck.issues(in: flow, registry: registry).filter { $0.severity == .error }
        let last = library.lastRun(flow.id)
        let running = engine.traces[flow.id]?.isRunning == true
        HStack(spacing: 12) {
            FlowLamp(flow: flow)
            Image(systemName: flow.glyph).font(.system(size: 14)).foregroundStyle(Theme.orange)
                .frame(width: 34, height: 34).recessed(cornerRadius: 8, fill: .black.opacity(0.35))
            VStack(alignment: .leading, spacing: 3) {
                Text(flow.name).font(Theme.sans(13.5, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(FlowCheck.sentence(for: flow, registry: registry)).font(Theme.sans(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let first = issues.first {
                    Label(first.message, systemImage: "exclamationmark.octagon").font(Theme.sans(11)).foregroundStyle(Theme.red).lineLimit(1)
                } else if let last {
                    HStack(spacing: 5) {
                        Circle().fill(last.outcome == .succeeded ? Theme.green : (last.outcome == .failed ? Theme.red : Theme.amber))
                            .frame(width: 5, height: 5)
                        Text("\(Stamp.moment(last.date)) · \(last.message)").font(Theme.mono(10)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 10)
            Button(running ? "Stop" : "Run") {
                if running { engine.stop(flow.id) } else { engine.run(flow.id, source: "Manual") }
            }
            .industrialButton(running ? .danger : .secondary, compact: true)
            .disabled(!running && (flow.body.isEmpty || !issues.isEmpty))
            Button("Edit") { FlowEditorWindows.shared.open(.flow(flow.id)) }.industrialButton(.quiet, compact: true)
            if !flow.triggers.isEmpty {
                Toggle("", isOn: Binding(get: { flow.isEnabled }, set: { on in
                    var next = flow; next.isEnabled = on; library.update(next)
                }))
                .labelsHidden().toggleStyle(.industrial)
                .disabled(!issues.isEmpty && !flow.isEnabled)
                .help(issues.isEmpty ? "Run whenever its trigger fires" : "Fix what's wrong first")
            }
            Menu {
                Button("Duplicate") { library.duplicate(flow.id) }
                Button("Export…") { FlowFiles.export(flow.id, library: library) }
                Divider()
                Button("Delete", role: .destructive) { delete() }
            } label: { Image(systemName: "ellipsis") }
                .menuKey(compact: true)
        }
        .padding(12)
        .raisedPanel(rail: flow.isEnabled && issues.isEmpty && !flow.triggers.isEmpty ? Theme.ambient : nil)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { FlowEditorWindows.shared.open(.flow(flow.id)) }
    }

    private func delete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(flow.name)”?"
        alert.informativeText = "Its history goes with it. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FlowEditorWindows.shared.close(.flow(flow.id))
        engine.stop(flow.id)
        library.remove(flow.id)
    }
}

private struct EmptyFlows: View {
    let templates: () -> Void
    let blank: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundStyle(Theme.orange)
            Text("Make the Mac do things for you").font(Theme.sans(16, .semibold)).foregroundStyle(Theme.textPrimary)
            Text("Snap blocks together — a trigger, then what happens — or write code where blocks run out.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            HStack {
                Button("Start from a template", action: templates).industrialButton(.primary)
                Button("Blank flow", action: blank).industrialButton(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .raisedPanel()
    }
}

private struct TemplateGallery: View {
    let done: (FlowTemplate?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Start from a template").font(Theme.sans(16, .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Cancel") { done(nil) }.industrialButton(.quiet).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(FlowTemplate.all) { template in
                        Button { done(template) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: template.glyph).font(.system(size: 14)).foregroundStyle(Theme.orange)
                                    .frame(width: 30, height: 30).recessed(cornerRadius: 7, fill: .black.opacity(0.35))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.name).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.textPrimary)
                                    Text(template.summary).font(Theme.sans(11.5)).foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                            .raisedPanel()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Templates arrive switched off — open one, check its folders, then switch it on.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textMuted)
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .background(Theme.panel)
    }
}

private struct PaletteShortcutCard: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        SettingsCard(rail: settings.paletteShortcut == nil ? nil : Theme.ambient) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.rays").foregroundStyle(Theme.orange)
                Text("Quick palette").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.textPrimary)
                    .help("Opens from anywhere: your flows that run by hand, most recent first, then the built-in tools")
                Spacer(minLength: 12)
                if settings.paletteShortcut != nil {
                    Button("Open") { QuickPalette.shared.show() }.industrialButton(.quiet)
                }
                ShortcutKeys(shortcut: settings.paletteShortcut) { settings.paletteShortcut = $0 }
            }
            .cardRow()
        }
        .padding(.top, 8)
    }
}

// MARK: - Blocks

private struct BlocksTab: View {
    @EnvironmentObject private var library: FlowLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Code you wrote, or blocks you packaged, given inputs and outputs — in every flow's palette under My blocks.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach(CodeLanguage.allCases) { language in
                        Button(language.label) { BlockDesigner.openNew(language) }
                    }
                    Divider()
                    Button("Import…") { FlowFiles.importFiles(library: library) }
                } label: { Label("New block", systemImage: "plus") }
                    .menuKey()
            }
            if library.blocks.isEmpty {
                Text("NO BLOCKS YET — MAKE ONE HERE, OR FROM A CODE BLOCK ON A CANVAS")
                    .font(Theme.mono(10, .semibold)).tracking(1.1).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .strokeBorder(Theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
            ForEach(library.blocks) { block in
                let users = library.flows(using: block.id)
                HStack(spacing: 12) {
                    Image(systemName: block.glyph).font(.system(size: 13)).foregroundStyle(Theme.crimson)
                        .frame(width: 32, height: 32).recessed(cornerRadius: 8, fill: .black.opacity(0.35))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.title).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(kind(block) + " · " + (users.isEmpty ? "not used yet" : "used by \(users.count == 1 ? users[0].name : "\(users.count) flows")"))
                            .font(Theme.sans(11)).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 4) {
                            ForEach(block.inputs) { ValuePill(label: $0.label, type: $0.type, compact: true) }
                            if !block.outputs.isEmpty {
                                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(Theme.textMuted)
                            }
                            ForEach(block.outputs) { ValuePill(label: $0.label, type: $0.type, compact: true) }
                        }
                    }
                    Spacer()
                    Button("Edit") { BlockDesigner.open(block) }.industrialButton(.quiet, compact: true)
                    Menu {
                        Button("Export…") { FlowFiles.exportBlock(block.id, library: library) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(block, users: users) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuKey(compact: true)
                }
                .padding(12)
                .raisedPanel()
            }
        }
    }

    private func kind(_ block: CustomBlock) -> String {
        switch block.body {
        case .code(let spec): return spec.language.label
        case .blocks(let stack): return "\(Block.flatten(stack).count) blocks"
        }
    }

    private func delete(_ block: CustomBlock, users: [Flow]) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(block.title)”?"
        alert.informativeText = users.isEmpty ? "No flow uses it."
            : "\(users.map(\.name).joined(separator: ", ")) use\(users.count == 1 ? "s" : "") it; there it becomes a Missing block until you replace it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FlowEditorWindows.shared.close(.block(block.id))
        library.deleteBlock(block.id)
    }
}

// MARK: - Setup

private struct SetupTab: View {
    @State private var snapshot: UserEnvironment.Snapshot?
    @State private var refreshing = false
    @State private var secrets = Secrets.names()
    @State private var environments = PackageEnvironments.list()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("YOUR SHELL")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if let snapshot {
                            LED(color: snapshot.problem == nil ? Theme.green : Theme.amber, lit: true, size: 7)
                            Text(snapshot.problem.map { "Using the basic PATH — \($0)" }
                                 ?? "Code runs with your shell's environment, as of \(Stamp.moment(snapshot.capturedAt))")
                                .font(Theme.sans(12.5)).foregroundStyle(Theme.textPrimary)
                        } else {
                            Text("Reading your shell…").font(Theme.sans(12.5)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button(refreshing ? "Reading…" : "Read again") {
                            refreshing = true
                            Task {
                                snapshot = await UserEnvironment.shared.refresh()
                                refreshing = false
                            }
                        }
                        .industrialButton(.quiet, compact: true).disabled(refreshing)
                        .help("After installing something, or changing your .zshrc")
                    }
                    if let path = snapshot?.variables["PATH"] {
                        Text(path.split(separator: ":").joined(separator: "\n"))
                            .font(Theme.mono(10)).foregroundStyle(Theme.textMuted).textSelection(.enabled).lineLimit(8)
                    }
                    Text("Homebrew, pyenv, nvm and your exports, as Terminal has them — so a script that works there works here.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.textMuted)
                }
                .padding(12)
            }

            SectionLabel("LANGUAGES")
            SettingsCard {
                ForEach(Array(CodeLanguage.allCases.enumerated()), id: \.element) { index, language in
                    if index > 0 { CardDivider() }
                    InterpreterRow(language: language, path: snapshot?.variables["PATH"] ?? UserEnvironment.fallbackPath)
                }
            }

            SectionLabel("PACKAGES")
            SettingsCard {
                HStack {
                    let total = environments.reduce(Int64(0)) { $0 + $1.bytes }
                    Text(environments.isEmpty ? "No package environments yet"
                         : "\(environments.count) environment\(environments.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("Remove all") {
                        PackageEnvironments.removeAll()
                        environments = PackageEnvironments.list()
                    }
                    .industrialButton(.quiet, compact: true).disabled(environments.isEmpty)
                    .help("They are rebuilt the next time a block needs one")
                }
                .cardRow()
            }

            SectionLabel("SECRETS")
            SettingsCard {
                ForEach(secrets, id: \.self) { name in
                    HStack {
                        Image(systemName: "key").font(.system(size: 10)).foregroundStyle(Theme.amber)
                        Text(name).font(Theme.sans(12.5)).foregroundStyle(Theme.textPrimary)
                        Text("$\(Secrets.variable(for: name))").font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button("Delete") { Secrets.delete(name); secrets = Secrets.names() }
                            .industrialButton(.ghost, compact: true)
                    }
                    .cardRow()
                    CardDivider()
                }
                HStack {
                    Text("API keys and passwords, kept in your Keychain — never in a flow file or a run's history.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("New secret…") { if SecretsDialog.add() != nil { secrets = Secrets.names() } }
                        .industrialButton(.quiet, compact: true)
                }
                .cardRow()
            }

            SectionLabel("PERMISSIONS")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    PermissionList(permissions: [.accessibility, .fullDiskAccess, .screenRecording, .location])
                    Text("Scripts run as part of Gruppen, so these switches cover every flow. Permission to control another app is asked for the first time a flow does it.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }

            SectionLabel("FROM TERMINAL")
            CommandCard()
        }
        .task { snapshot = await UserEnvironment.shared.current() }
    }
}

private struct InterpreterRow: View {
    let language: CodeLanguage
    let path: String
    @State private var chosen: String?

    var body: some View {
        let found = Interpreters.available(for: language, path: path)
        HStack {
            Text(language.label).font(Theme.sans(12.5)).foregroundStyle(Theme.textPrimary).frame(width: 190, alignment: .leading)
            if found.isEmpty {
                Text(CodeRunner.missing(language)).font(Theme.sans(11)).foregroundStyle(Theme.amber).lineLimit(2)
            } else {
                Picker("", selection: Binding(get: { chosen ?? found[0].path }, set: { path in
                    chosen = path
                    Interpreters.choose(path, for: language)
                })) {
                    ForEach(found) { Text("\($0.path)  —  \($0.origin)").tag($0.path) }
                }
                .labelsHidden()
            }
        }
        .cardRow()
        .onAppear { chosen = Interpreters.chosen(for: language) }
    }
}

/// How to get `gruppen run` into Terminal: one link, made once.
private struct CommandCard: View {
    private var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gruppen").path }
    private var command: String { "ln -sf \"\(helper)\" /usr/local/bin/gruppen" }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run any flow from Terminal, cron or another app:").font(Theme.sans(12.5)).foregroundStyle(Theme.textPrimary)
                Text("gruppen run \"Flow name\" --key value --file ~/Desktop/x.pdf")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                Text("It waits for the flow to finish and prints how it went. To put the command on your PATH, run this once in Terminal:")
                    .font(Theme.sans(11)).foregroundStyle(Theme.textMuted)
                HStack {
                    Text(command).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .industrialButton(.quiet, compact: true)
                }
            }
            .padding(12)
        }
    }
}
