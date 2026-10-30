import AppKit
import SwiftUI

/// Designing a block of your own: what it is called, how it reads, what goes
/// in and what comes out — and its code, or the blocks it was packaged from.
///
/// Edited as a draft and saved on Save, unlike flows: a block is used by other
/// flows, and changing its ports halfway through typing a name would ripple
/// into every one of them.
struct BlockDesigner: View {
    @State var draft: CustomBlock
    /// Called with the saved block.
    var onSave: (CustomBlock) -> Void = { _ in }
    let close: () -> Void
    @EnvironmentObject private var library: FlowLibrary

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: draft.glyph).foregroundStyle(Theme.crimson)
                Text(library.blocks.contains { $0.id == draft.id } ? "Edit block" : "New block")
                    .font(Theme.sans(15, .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Cancel", action: close).industrialButton(.quiet)
                Button("Save") {
                    library.saveBlock(draft)
                    onSave(draft)
                    close()
                }
                .industrialButton(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || duplicateNames)
            }
            .padding(14)
            .background(Theme.housing)
            DashedRule()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { form.padding(16) }.frame(width: 470)
                Divider().overlay(Theme.borderSubtle)
                bodyEditor.padding(16)
            }
        }
        .frame(minWidth: 1040, minHeight: 640)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private var duplicateNames: Bool {
        let inputs = draft.inputs.map(\.name), outputs = draft.outputs.map(\.name)
        return Set(inputs).count != inputs.count || Set(outputs).count != outputs.count
            || inputs.contains(where: \.isEmpty) || outputs.contains(where: \.isEmpty)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("NAME") { TextField("Resize images", text: $draft.title).textFieldStyle(.plain).fieldChrome() }
            field("ICON") { GlyphPicker(glyph: draft.glyph) { draft.glyph = $0 } }
            field("HOW IT READS") {
                TextField("Resize {files} to {width} pixels", text: $draft.phrase).textFieldStyle(.plain).fieldChrome()
                Text("Name an input in braces and it sits in the sentence, on the block itself. Empty: just the name.")
                    .font(Theme.sans(10.5)).foregroundStyle(Theme.textMuted)
                // A preview of the face, as it will read.
                let preview = PhrasePart.parse(draft.phrase.isEmpty ? draft.title : draft.phrase, inputs: draft.inputs)
                WrapLayout(spacing: 5) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .words(let words): Text(words).font(Theme.sans(12, .medium))
                        case .input(let name):
                            ValuePill(label: name, type: draft.inputs.first { $0.name == name }?.type ?? .any, compact: true)
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceTop))
            }
            field("WHAT IT DOES") {
                TextField("One sentence, shown in the palette and the inspector", text: $draft.help, axis: .vertical)
                    .textFieldStyle(.plain).fieldChrome()
            }
            ports("INPUTS", $draft.inputs, isInput: true)
            ports("OUTPUTS", $draft.outputs, isInput: false)
            if duplicateNames {
                Text("Every input and output needs a name of its own.").font(Theme.sans(11)).foregroundStyle(Theme.red)
            }
            let users = library.flows(using: draft.id)
            if !users.isEmpty {
                Text("Used by \(users.map(\.name).joined(separator: ", ")). Saving updates them; an input you remove is dropped from each.")
                    .font(Theme.sans(10.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.mono(8.5, .semibold)).tracking(1.1).foregroundStyle(Theme.textMuted)
            content()
        }
    }

    private func ports(_ title: String, _ ports: Binding<[Port]>, isInput: Bool) -> some View {
        field(title) {
            ForEach(ports.wrappedValue.indices, id: \.self) { index in
                PortRow(port: ports[index], isInput: isInput) { ports.wrappedValue.remove(at: index) }
            }
            Button {
                var name = isInput ? "input" : "result"
                var counter = 2
                while ports.wrappedValue.contains(where: { $0.name == name }) { name = (isInput ? "input" : "result") + "\(counter)"; counter += 1 }
                ports.wrappedValue.append(Port(name, nil, .text, optional: !isInput))
            } label: { Label(isInput ? "Add an input" : "Add an output", systemImage: "plus") }
                .industrialButton(.ghost, compact: true)
            Text(isInput ? "Your code gets each as gruppen.inputs[\"name\"], $GRUPPEN_IN_NAME, and file inputs as arguments."
                         : "Your code hands each on with gruppen.out(name=…) — or `out name value` in shell.")
                .font(Theme.sans(10.5)).foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder private var bodyEditor: some View {
        switch draft.body {
        case .code(let spec):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("", selection: Binding(get: { spec.language }, set: { language in
                        var next = spec; next.language = language; draft.body = .code(next)
                    })) {
                        ForEach(CodeLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 220)
                    Spacer()
                    InterpreterNote(language: spec.language)
                }
                CodeEditor(text: Binding(get: { spec.source }, set: { source in
                    var next = spec; next.source = source; draft.body = .code(next)
                }), language: spec.language, errorLine: nil)
                .frame(maxHeight: .infinity)
                if spec.language.supportsPackages {
                    field("PACKAGES") {
                        TextField(spec.language == .python ? "requests, pillow" : "lodash, axios",
                                  text: Binding(get: { spec.packages.joined(separator: ", ") }, set: { text in
                                      var next = spec
                                      next.packages = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                          .filter { !$0.isEmpty }
                                      draft.body = .code(next)
                                  }))
                        .textFieldStyle(.plain).fieldChrome()
                        Text("Installed once into an environment kept for this list, the first time it runs.")
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.textMuted)
                    }
                }
                let needs = Permissions.inferred(from: spec)
                if !needs.isEmpty {
                    field("PROBABLY NEEDS") { PermissionList(permissions: needs) }
                }
            }
        case .blocks(let stack):
            VStack(alignment: .leading, spacing: 12) {
                Text("Made of \(Block.flatten(stack).count) blocks").font(Theme.sans(14, .semibold))
                Text("Its inputs are what those blocks read from outside; its outputs, what came after them read back.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.textSecondary)
                Button("Edit its blocks…") {
                    library.saveBlock(draft)
                    FlowEditorWindows.shared.open(.block(draft.id))
                }
                .industrialButton(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One input or output: name, label, type, and for inputs how it is edited
/// and what it starts as.
private struct PortRow: View {
    @Binding var port: Port
    let isInput: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("name", text: Binding(get: { port.name }, set: { port.name = Self.key($0) }))
                    .textFieldStyle(.plain).font(Theme.mono(11)).fieldChrome().frame(width: 110)
                TextField("Label", text: $port.label).textFieldStyle(.plain).fieldChrome()
                Picker("", selection: Binding(get: { port.type }, set: { type in
                    port.type = type
                    if isInput { port.control = PortControl.natural(for: type) }
                })) {
                    ForEach(ValueType.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 96)
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Theme.textMuted)
            }
            if isInput {
                HStack(spacing: 6) {
                    Picker("", selection: $port.control) {
                        ForEach(PortControl.forCustomBlocks) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    TextField(port.control == .choice ? "Choices, comma separated" : "Starts as",
                              text: Binding(get: {
                                  port.control == .choice ? port.choices.joined(separator: ", ")
                                      : (port.defaultValue.coerced(to: .text)?.text ?? "")
                              }, set: { text in
                                  if port.control == .choice {
                                      port.choices = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                      port.defaultValue = port.choices.first.map(Value.text) ?? .nothing
                                  } else {
                                      port.defaultValue = text.isEmpty ? .nothing : (Value.text(text).coerced(to: port.type) ?? .text(text))
                                  }
                              }))
                        .textFieldStyle(.plain).fieldChrome()
                    Toggle("Optional", isOn: $port.isOptional).toggleStyle(.checkbox).font(Theme.sans(11))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceTop))
    }

    /// Names are what code reads, so letters, digits and underscores only.
    static func key(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(32))
    }
}

// MARK: - Opening

extension BlockDesigner {
    private static var windows: [UUID: NSWindow] = [:]

    /// Edits a block you have already made.
    static func open(_ block: CustomBlock, onSave: @escaping (CustomBlock) -> Void = { _ in }) {
        if let window = windows[block.id] { window.makeKeyAndOrderFront(nil); return }
        guard let library = FlowEditorWindows.shared.library else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let id = block.id
        let view = BlockDesigner(draft: block, onSave: onSave) {
            windows[id]?.close()
            windows[id] = nil
        }
        .environmentObject(library)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        windows[block.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A new code block of `language`, from the Blocks page.
    static func openNew(_ language: CodeLanguage) {
        let block = CustomBlock(title: "My block", glyph: CodeTemplates.glyph(language),
                                inputs: [Port("input", "Input", .any, .text, optional: true)],
                                outputs: [Port("result", "Result", .any)],
                                body: .code(CodeSpec(language, source: CodeTemplates.starter(language))))
        open(block)
    }

    /// A code block on a canvas, made into a block of its own — and, once
    /// saved, the one on the canvas replaced by it, wired the same way.
    static func open(fromCode block: Block, model: EditorModel) {
        guard case .inlineCode(let language) = model.definition(block).implementation else { return }
        let source = block.inputs["code"]?.literal?.text ?? CodeTemplates.starter(language)
        let packages = (block.inputs["packages"]?.literal?.text ?? "").split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let custom = CustomBlock(title: "My \(language.shortLabel) block", glyph: CodeTemplates.glyph(language),
                                 phrase: "", inputs: [Port("input", "Input", .any, .text, optional: true)],
                                 outputs: [Port("output", "Output", .text), Port("result", "Result", .any)],
                                 body: .code(CodeSpec(language, source: source, packages: packages)))
        let blockID = block.id
        open(custom) { saved in
            model.update(blockID, "Make a block") { placed in
                let input = placed.inputs["input"]
                placed.definition = saved.definitionID
                placed.inputs = input.map { ["input": $0] } ?? [:]
            }
        }
    }
}
