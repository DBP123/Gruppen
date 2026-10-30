import AppKit
import SwiftUI

/// Editing one input: type a value, or pick one of the values before it. The
/// same view in a slot's popover and in the inspector.
struct InputEditor: View {
    let blockID: UUID
    let port: Port
    var compact = false
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        if let block = model.flow.block(blockID) {
            content(block)
        }
    }

    private func content(_ block: Block) -> some View {
        let source = block.inputs[port.name]
        // What fits exactly; what converts only when nothing does — every
        // value converts to text, and offering files for a format is noise.
        let candidates = port.takesValues
            ? FlowCheck.available(at: blockID, in: model.flow.body + model.flow.loose.flatMap(\.blocks), context: model.checkContext)
            : []
        let exact = candidates.filter { Conversion.from($0.type, to: port.type) == .exact }
        let available = exact.isEmpty ? candidates.filter { Conversion.from($0.type, to: port.type) == .converts } : exact
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(port.label).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.textPrimary)
                ValuePill(label: port.type.label, type: port.type, compact: true)
                Spacer()
                if source != nil {
                    Button("Reset") { model.setInput(blockID, port.name, nil) }
                        .industrialButton(.ghost, compact: true)
                        .help("Back to \(InputText.literal(port.defaultValue, port: port))")
                }
            }
            if !port.help.isEmpty {
                Text(port.help).font(Theme.sans(11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }

            switch source {
            case .template(let parts)?:
                TemplateEditor(parts: parts, available: available,
                               set: { model.setInput(blockID, port.name, .template($0)) },
                               plain: { model.setInput(blockID, port.name, .literal(.text($0))) })
            case .output?, .trigger?, .variable?:
                let found = available.first { $0.binding == source }
                HStack {
                    ValuePill(label: found?.label ?? "a value that isn't there", type: found?.type ?? .any, source: found?.source)
                    Text(found?.source ?? "").font(Theme.sans(11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer()
                    Button("Type a value") { model.setInput(blockID, port.name, nil) }.industrialButton(.quiet, compact: true)
                }
                if let found, Conversion.from(found.type, to: port.type) == .converts {
                    Text("\(found.type.label) is converted to \(port.type.label.lowercased()) when it runs.")
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.amber)
                }
            default:
                LiteralEditor(port: port, value: source?.literal ?? port.defaultValue, compact: compact,
                              language: EditorModel.language(of: block, registry: model.registry),
                              errorLine: model.errorLines[blockID]) { value in
                    model.setInput(blockID, port.name, .literal(value))
                }
                if port.type == .text || port.type == .any, !available.isEmpty, port.control != .code {
                    Button {
                        let text = source?.literal?.coerced(to: .text)?.text ?? ""
                        model.setInput(blockID, port.name, .template(text.isEmpty ? [] : [.text(text)]))
                    } label: { Label("Mix in values", systemImage: "text.badge.plus") }
                        .industrialButton(.ghost, compact: true)
                        .help("Text with values dropped into it")
                }
            }

            if !available.isEmpty, !isTemplate(source) {
                DashedRule()
                Text("OR USE").font(Theme.mono(8.5, .semibold)).tracking(1).foregroundStyle(Theme.textMuted)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(available) { value in
                            Button { model.setInput(blockID, port.name, value.binding) } label: {
                                HStack {
                                    ValuePill(label: value.label, type: value.type, compact: true)
                                    Text(value.source).font(Theme.sans(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    Spacer()
                                    if source == value.binding {
                                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.orange)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: compact ? 150 : 220)
            }
        }
    }

    private func isTemplate(_ source: ValueSource?) -> Bool {
        if case .template? = source { return true }
        return false
    }
}

// MARK: - Literal values

/// A typed-in value, edited with the control its port asks for.
struct LiteralEditor: View {
    let port: Port
    let value: Value
    var compact = false
    var language: CodeLanguage = .zsh
    var errorLine: Int? = nil
    let set: (Value) -> Void

    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var workspaces: WorkspaceEngine
    @EnvironmentObject private var model: EditorModel

    private var text: Binding<String> {
        Binding(get: { value.coerced(to: .text)?.text ?? "" }, set: { set(.text($0)) })
    }

    var body: some View {
        switch port.control {
        case .text:
            TextField(port.label, text: text).textFieldStyle(.plain).fieldChrome()
        case .multiline:
            TextEditor(text: text).font(Theme.mono(11)).scrollContentBackground(.hidden)
                .frame(height: compact ? 90 : 120).fieldChrome()
        case .number:
            TextField(port.label, value: Binding(get: { value.coerced(to: .number)?.number ?? 0 },
                                                 set: { set(.number($0)) }), format: .number)
                .textFieldStyle(.plain).fieldChrome().frame(width: 120)
        case .toggle:
            Toggle(port.label, isOn: Binding(get: { value.coerced(to: .bool)?.flag ?? false }, set: { set(.bool($0)) }))
                .toggleStyle(.industrial)
        case .choice:
            Picker("", selection: text) {
                ForEach(port.choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .folder, .file:
            HStack {
                TextField(port.control == .folder ? "~/Folder" : "~/File", text: text).textFieldStyle(.plain).fieldChrome()
                Button("Choose…") {
                    if port.control == .folder {
                        if let url = Pickers.folder(title: port.label) { set(.text(Self.tilde(url.path))) }
                    } else if let url = Pickers.files(title: port.label, prompt: "Choose").first {
                        set(.text(Self.tilde(url.path)))
                    }
                }
                .industrialButton(.secondary, compact: true)
            }
        case .app:
            HStack {
                if let id = value.text, !id.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                }
                TextField("Bundle id, or a process name", text: text).textFieldStyle(.plain).fieldChrome()
                Button("Choose…") { if let app = Pickers.app() { set(.text(app.bundleID)) } }
                    .industrialButton(.secondary, compact: true)
            }
        case .gruppe:
            Menu {
                ForEach(store.groups) { group in Button(group.name) { set(.text(Pick.join(group.id, group.name))) } }
            } label: { MenuKeyLabel(title: Pick.split(text.wrappedValue).1.isEmpty ? "Choose a Gruppe" : Pick.split(text.wrappedValue).1, compact: false) }
                .menuKey()
        case .workspace:
            Menu {
                ForEach(workspaces.profiles) { profile in Button(profile.name) { set(.text(Pick.join(profile.id, profile.name))) } }
            } label: { MenuKeyLabel(title: Pick.split(text.wrappedValue).1.isEmpty ? "Choose a workspace" : Pick.split(text.wrappedValue).1, compact: false) }
                .menuKey()
        case .hotkey:
            ShortcutKeys(shortcut: HotkeyValue.shortcut(text.wrappedValue),
                         onRecordingChange: { recording in
                             recording ? model.engine.triggers.suspendHotkeys() : model.engine.triggers.resumeHotkeys()
                         },
                         onRecord: { set(.text(HotkeyValue.text($0))) })
        case .time:
            DatePicker("", selection: Binding(get: {
                Calendar.current.date(bySettingHour: Int(value.number ?? 0) / 60, minute: Int(value.number ?? 0) % 60,
                                      second: 0, of: Date()) ?? Date()
            }, set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set(.number(Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))))
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
        case .weekdays:
            WeekdayPicker(days: Schedule.days(text.wrappedValue)) { set(.text(Schedule.text($0))) }
        case .secret:
            SecretPicker(name: text.wrappedValue) { set(.text($0)) }
        case .code:
            CodeEditor(text: text, language: language, errorLine: errorLine)
                .frame(height: compact ? 260 : 340)
        }
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension View {
    /// An input field's recess.
    func fieldChrome() -> some View {
        self.font(Theme.sans(12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .recessed(cornerRadius: 5)
    }
}

extension EditorModel {
    /// The language a block's code is written in.
    static func language(of block: Block, registry: BlockRegistry) -> CodeLanguage {
        switch registry.definition(block.definition).implementation {
        case .inlineCode(let language): return language
        case .code(let spec): return spec.language
        default: return .zsh
        }
    }
}

/// Seven keys, one per day, lit when the schedule runs then.
struct WeekdayPicker: View {
    let days: Set<Int>
    let set: (Set<Int>) -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Monday first, as a week reads.
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = days.contains(day)
                Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                    var next = days
                    if on { next.remove(day) } else { next.insert(day) }
                    set(next)
                }
                .font(Theme.mono(10.5, .semibold))
                .frame(width: 26, height: 22)
                .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.orange : Theme.input))
                .buttonStyle(.plain)
            }
        }
    }
}

/// Picks a secret from the Keychain by name, or makes a new one.
struct SecretPicker: View {
    let name: String
    let set: (String) -> Void
    @State private var names = Secrets.names()

    var body: some View {
        Menu {
            ForEach(names, id: \.self) { secret in Button(secret) { set(secret) } }
            if !names.isEmpty { Divider() }
            Button("New secret…") {
                if let made = SecretsDialog.add() {
                    names = Secrets.names()
                    set(made)
                }
            }
        } label: {
            MenuKeyLabel(title: name.isEmpty ? "Choose a secret" : "🔒 \(name)", compact: false)
        }
        .menuKey()
    }
}

// MARK: - Templates

/// Text with values dropped in: pieces of text and pills, in order.
struct TemplateEditor: View {
    let parts: [TextPart]
    let available: [AvailableValue]
    let set: ([TextPart]) -> Void
    /// Back to plain typed text, the values dropped.
    let plain: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WrapLayout(spacing: 4, lineSpacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    switch part {
                    case .text(let text):
                        TextField("text", text: Binding(get: { text }, set: { replace(index, .text($0)) }))
                            .textFieldStyle(.plain)
                            .font(Theme.mono(11))
                            .frame(width: max(40, CGFloat(text.count) * 7 + 16))
                            .padding(.horizontal, 4).padding(.vertical, 3)
                            .recessed(cornerRadius: 4)
                    case .value(let source):
                        let found = available.first { $0.binding == source }
                        HStack(spacing: 2) {
                            ValuePill(label: found?.label ?? "missing", type: found?.type ?? .any, compact: true)
                            Button { remove(index) } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
            HStack {
                Menu {
                    ForEach(available) { value in
                        Button("\(value.label) — \(value.source)") { set(parts + [.value(value.binding)]) }
                    }
                } label: { MenuKeyLabel(title: "Add a value") }
                    .menuKey(compact: true)
                Button("Add text") { set(parts + [.text(" ")]) }.industrialButton(.ghost, compact: true)
                Spacer()
                Button("Plain text") {
                    let flat = parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
                    plain(flat)
                }
                .industrialButton(.quiet, compact: true)
                .help("Drop the values and keep the words")
            }
        }
    }

    private func replace(_ index: Int, _ part: TextPart) {
        var next = parts
        next[index] = part
        set(next)
    }

    private func remove(_ index: Int) {
        var next = parts
        next.remove(at: index)
        set(next)
    }
}
