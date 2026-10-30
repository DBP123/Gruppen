import AppKit
import SwiftUI

/// The right-hand column: everything about the selected block, or — with
/// nothing selected — the flow itself.
struct Inspector: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.selection.count == 1, let id = model.selection.first, let block = model.flow.block(id) {
                    BlockInspector(block: block)
                } else if model.selection.count > 1 {
                    selectionSummary
                } else {
                    FlowInspector()
                }
            }
            .padding(14)
        }
        .frame(width: 318)
        .background(Theme.machined)
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorTitle(glyph: "square.on.square", title: "\(model.selection.count) blocks", tint: Theme.textSecondary)
            Button("Package as a block…") {
                FlowDialogs.name(title: "Package as a block", prompt: "What should the new block be called?",
                                 initial: "My block") { model.packageSelection(title: $0) }
            }
            .industrialButton(.secondary)
            .help("The selected blocks become one block in your palette; what they read from outside becomes its inputs")
            Button("Duplicate") { model.duplicate(model.selection) }.industrialButton(.quiet)
            Button("Delete", role: .destructive) { model.delete(model.selection) }.industrialButton(.danger)
        }
    }
}

private struct InspectorTitle: View {
    let glyph: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: glyph).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.14)))
            Text(title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.mono(8.5, .semibold)).tracking(1.1).foregroundStyle(Theme.textMuted)
            content
        }
    }
}

// MARK: - A block

private struct BlockInspector: View {
    let block: Block
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        let definition = model.definition(block)
        let run = model.runState(block.id)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                InspectorTitle(glyph: definition.glyph, title: definition.title, tint: definition.tint)
                if !definition.help.isEmpty {
                    Text(definition.help).font(Theme.sans(11.5)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let issues = model.issues(for: block.id)
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues) { issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon" : "exclamationmark.triangle")
                            .font(Theme.sans(11.5))
                            .foregroundStyle(issue.severity == .error ? Theme.red : Theme.amber)
                    }
                }
            }

            // A code block is its code: that comes first, its settings after.
            if let code = definition.inputs.first(where: { $0.control == .code }) {
                codeSection(block, port: code)
                DashedRule()
            }
            ForEach(definition.inputs.filter { $0.control != .code }) { port in
                InputEditor(blockID: block.id, port: port)
                DashedRule()
            }

            if definition.isHat && !definition.outputs.isEmpty {
                SampleInput(block: block, definition: definition)
            }

            if !definition.outputs.isEmpty {
                InspectorSection(title: definition.isHat ? "HANDS OVER" : "OUTPUTS") {
                    ForEach(definition.outputs) { port in
                        HStack {
                            OutputPill(block: block, port: port, value: run.outputs[port.name])
                            Spacer()
                        }
                    }
                    Text("Drag a pill onto any input below this block.").font(Theme.sans(10.5)).foregroundStyle(Theme.textMuted)
                }
            }

            let needs = Set(definition.permissions + inferredPermissions(block, definition))
            if !needs.isEmpty {
                InspectorSection(title: "NEEDS") { PermissionList(permissions: Array(needs)) }
            }

            if !definition.isHat {
                InspectorSection(title: "WHEN IT RUNS") {
                    Picker("If it fails", selection: Binding(get: { block.onFailure }, set: { policy in
                        model.update(block.id, "If it fails") { $0.onFailure = policy }
                    })) {
                        ForEach([FailurePolicy.stop, .continue, .retry(1), .retry(3), .retry(5)], id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    Toggle("Pause here when run from the editor", isOn: Binding(get: { block.hasBreakpoint }, set: { on in
                        model.update(block.id, "Breakpoint") { $0.hasBreakpoint = on }
                    })).toggleStyle(.industrial).font(Theme.sans(12))
                    Toggle("Skip this block", isOn: Binding(get: { block.isDisabled }, set: { on in
                        model.update(block.id, on ? "Disable" : "Enable") { $0.isDisabled = on }
                    })).toggleStyle(.industrial).font(Theme.sans(12))
                }
            }

            InspectorSection(title: "NOTE") {
                TextField("A note for yourself", text: Binding(get: { block.note }, set: { note in
                    model.update(block.id, "Note", coalescing: "\(block.id).note") { $0.note = note }
                }), axis: .vertical)
                .textFieldStyle(.plain).fieldChrome()
            }

            if let message = run.message, !message.isEmpty {
                InspectorSection(title: "LAST RUN") {
                    Text(message).font(Theme.mono(10.5))
                        .foregroundStyle(run.state == .failed ? Theme.red : Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func codeSection(_ block: Block, port: Port) -> some View {
        let language = EditorModel.language(of: block, registry: model.registry)
        let source = block.inputs[port.name]?.literal?.text ?? port.defaultValue.text ?? ""
        return InspectorSection(title: language.label.uppercased()) {
            LiteralEditor(port: port, value: .text(source), language: language,
                          errorLine: model.errorLines[block.id]) { value in
                model.setInput(block.id, port.name, .literal(value))
            }
            HStack {
                Button("Open in editor…") {
                    let id = block.id
                    ExternalEdit.open(source, language: language, name: model.flow.name, block: id) { text in
                        model.setInput(id, port.name, .literal(.text(text)))
                    }
                }
                .industrialButton(.quiet, compact: true)
                .help("Edit it in the app you use for code; every save comes back here")
                Spacer()
                if case .inlineCode = model.definition(block).implementation {
                    Button("Make a block…") { BlockDesigner.open(fromCode: block, model: model) }
                        .industrialButton(.secondary, compact: true)
                        .help("Give it named inputs and outputs, and it joins the palette for any flow")
                }
            }
            InterpreterNote(language: language)
        }
    }

    private func inferredPermissions(_ block: Block, _ definition: BlockDefinition) -> [Permission] {
        switch definition.implementation {
        case .inlineCode(let language):
            return Permissions.inferred(from: CodeSpec(language, source: block.inputs["code"]?.literal?.text ?? ""))
        case .code(let spec):
            return Permissions.inferred(from: spec)
        default:
            return []
        }
    }
}

/// What a hat pretends to hand over when the flow is run from the editor.
private struct SampleInput: View {
    let block: Block
    let definition: BlockDefinition
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection(title: "TEST WITH") {
            ForEach(definition.outputs) { port in
                HStack {
                    ValuePill(label: port.label, type: port.type, compact: true)
                    Spacer()
                    if port.type == .files {
                        let files = block.sample[port.name]?.urls ?? []
                        Text(files.isEmpty ? "none" : FileOps.count(files)).font(Theme.sans(11)).foregroundStyle(Theme.textSecondary)
                        Button("Choose…") {
                            let picked = Pickers.files(title: "Files to test with", prompt: "Use")
                            model.update(block.id, "Test files") { $0.sample[port.name] = .files(picked) }
                        }
                        .industrialButton(.quiet, compact: true)
                    } else {
                        TextField("sample", text: Binding(get: { block.sample[port.name]?.coerced(to: .text)?.text ?? "" },
                                                          set: { text in model.update(block.id, "Test value", coalescing: "\(block.id).sample.\(port.name)") {
                                                              $0.sample[port.name] = Value.text(text).coerced(to: port.type) ?? .text(text)
                                                          } }))
                            .textFieldStyle(.plain).fieldChrome().frame(width: 140)
                    }
                }
            }
            Text("Run in the editor uses these instead of waiting for the real thing.")
                .font(Theme.sans(10.5)).foregroundStyle(Theme.textMuted)
        }
    }
}

/// Which program runs this language, and how to change it.
struct InterpreterNote: View {
    let language: CodeLanguage
    @State private var path: String?

    var body: some View {
        Text(path.map { "Runs with \($0)" } ?? "Finding \(language.shortLabel)…")
            .font(Theme.mono(9.5)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            .task(id: language) {
                let snapshot = await UserEnvironment.shared.current()
                let found = Interpreters.resolve(CodeSpec(language), path: snapshot.variables["PATH"] ?? UserEnvironment.fallbackPath)
                path = found ?? "nothing — install it, or pick one in Setup"
            }
    }
}

/// Each permission, whether it is granted, and the way to the switch.
struct PermissionList: View {
    let permissions: [Permission]
    @State private var states: [Permission: Permissions.State] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(permissions.sorted { $0.id < $1.id }) { permission in
                HStack(spacing: 8) {
                    Image(systemName: permission.glyph).font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(tint(states[permission]))
                    Text(permission.label).font(Theme.sans(11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    switch states[permission] {
                    case .granted?: Text("ALLOWED").font(Theme.mono(8.5, .semibold)).foregroundStyle(Theme.green)
                    default:
                        Button("Open Settings") { NSWorkspace.shared.open(permission.settingsURL) }
                            .industrialButton(.quiet, compact: true)
                            .help(permission.advice)
                    }
                }
            }
        }
        .task(id: permissions.map(\.id).sorted().joined()) {
            // Automation's check can block on the app it asks about.
            let found = await Task.detached { () -> [Permission: Permissions.State] in
                var found: [Permission: Permissions.State] = [:]
                for permission in permissions { found[permission] = Permissions.state(of: permission) }
                return found
            }.value
            states = found
        }
    }

    private func tint(_ state: Permissions.State?) -> Color {
        switch state {
        case .granted?: return Theme.green
        case .denied?: return Theme.red
        default: return Theme.amber
        }
    }
}

// MARK: - The flow

private struct FlowInspector: View {
    @EnvironmentObject private var model: EditorModel
    @State private var secretNames = Secrets.names()

    var body: some View {
        let flow = model.flow
        let issues = model.issues
        VStack(alignment: .leading, spacing: 16) {
            InspectorTitle(glyph: flow.glyph, title: model.isBlock ? "This block" : "This flow", tint: Theme.orange)

            InspectorSection(title: "NAME") {
                TextField("Name", text: Binding(get: { flow.name }, set: { name in
                    model.edit("Rename", coalescing: "name") { $0.name = name }
                })).textFieldStyle(.plain).fieldChrome()
                GlyphPicker(glyph: flow.glyph) { glyph in model.edit("Icon") { $0.glyph = glyph } }
            }

            if model.isBlock, let block = model.customBlock {
                Button("Inputs, outputs and description…") { BlockDesigner.open(block) }
                    .industrialButton(.secondary)
            } else {
                InspectorSection(title: "SWITCHED ON") {
                    Toggle(flow.triggers.isEmpty ? "Runs only by hand" : "Runs when its trigger fires",
                           isOn: Binding(get: { flow.isEnabled }, set: { on in model.edit(on ? "Switch on" : "Switch off") { $0.isEnabled = on } }))
                        .toggleStyle(.industrial).font(Theme.sans(12))
                        .disabled(flow.triggers.isEmpty || issues.contains { $0.severity == .error })
                    Toggle("In the menu bar", isOn: Binding(get: { flow.pinned }, set: { on in model.edit("Menu bar") { $0.pinned = on } }))
                        .toggleStyle(.industrial).font(Theme.sans(12))
                }

                InspectorSection(title: "WHILE IT'S RUNNING") {
                    Picker("If it fires again", selection: Binding(get: { flow.policy.concurrency }, set: { value in
                        model.edit("If it fires again") { $0.policy.concurrency = value }
                    })) {
                        ForEach(FlowPolicy.Concurrency.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Text("Stop after").font(Theme.sans(12))
                        TextField("", value: Binding(get: { flow.policy.timeout }, set: { value in
                            model.edit("Time limit", coalescing: "timeout") { $0.policy.timeout = max(0, value) }
                        }), format: .number).textFieldStyle(.plain).fieldChrome().frame(width: 60)
                        Text("seconds — 0 for never").font(Theme.sans(11)).foregroundStyle(Theme.textMuted)
                    }
                    Picker("Notify me", selection: Binding(get: { flow.policy.notify }, set: { value in
                        model.edit("Notify") { $0.policy.notify = value }
                    })) {
                        ForEach(FlowPolicy.Notify.allCases) { Text($0.label).tag($0) }
                    }
                }

                InspectorSection(title: "FOR CODE BLOCKS") {
                    EnvironmentEditor(variables: flow.environment) { variables in
                        model.edit("Environment", coalescing: "environment") { $0.environment = variables }
                    }
                    if !secretNames.isEmpty {
                        Text("Secrets, as environment variables:").font(Theme.sans(11)).foregroundStyle(Theme.textSecondary)
                        ForEach(secretNames, id: \.self) { name in
                            Toggle("\(name) → $\(Secrets.variable(for: name))", isOn: Binding(
                                get: { flow.secrets.contains(name) },
                                set: { on in model.edit("Secrets") { flow in
                                    if on { flow.secrets.append(name) } else { flow.secrets.removeAll { $0 == name } }
                                } }))
                            .toggleStyle(.checkbox).font(Theme.mono(10.5))
                        }
                    }
                    Button("New secret…") { if SecretsDialog.add() != nil { secretNames = Secrets.names() } }
                        .industrialButton(.ghost, compact: true)
                }

                InspectorSection(title: "FROM OUTSIDE") {
                    let command = "gruppen run \"\(flow.name)\""
                    HStack {
                        Text(command).font(Theme.mono(10.5)).foregroundStyle(Theme.textPrimary).textSelection(.enabled).lineLimit(1)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .industrialButton(.quiet, compact: true)
                    }
                    Text("Or open gruppen://run/\(flow.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? flow.name) — from Terminal, Raycast, Shortcuts or another app. Setup has the command.")
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }

            let permissions = Set(flow.allBlocks.flatMap { model.definition($0).permissions })
            if !permissions.isEmpty {
                InspectorSection(title: "NEEDS") { PermissionList(permissions: Array(permissions)) }
            }

            if !issues.isEmpty {
                InspectorSection(title: "NEEDS A LOOK") {
                    ForEach(issues) { issue in
                        Button {
                            model.selection = [issue.block]
                        } label: {
                            Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon" : "exclamationmark.triangle")
                                .font(Theme.sans(11.5))
                                .foregroundStyle(issue.severity == .error ? Theme.red : Theme.amber)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// `NAME=value`, one per line.
private struct EnvironmentEditor: View {
    let variables: [String: String]
    let set: ([String: String]) -> Void
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.mono(10.5))
            .scrollContentBackground(.hidden)
            .frame(height: 64)
            .fieldChrome()
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("NAME=value, one per line").font(Theme.mono(10.5)).foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 13).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .onAppear { text = variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") }
            .onChange(of: text) { text in
                var parsed: [String: String] = [:]
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { parsed[key] = String(line[line.index(after: equals)...]) }
                }
                if parsed != variables { set(parsed) }
            }
    }
}

/// A short row of icons to choose from.
struct GlyphPicker: View {
    let glyph: String
    let set: (String) -> Void

    static let choices = ["point.3.connected.trianglepath.dotted", "bolt", "folder", "doc", "tray", "wand.and.rays",
                          "terminal", "clock", "bell", "network", "photo", "music.note", "square.grid.2x2", "sparkles",
                          "hammer", "paperplane", "cube", "shippingbox"]

    var body: some View {
        WrapLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Self.choices, id: \.self) { choice in
                Button { set(choice) } label: {
                    Image(systemName: choice).font(.system(size: 11))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(choice == glyph ? Theme.onAccent : Theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 5).fill(choice == glyph ? Theme.orange : Theme.input))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
