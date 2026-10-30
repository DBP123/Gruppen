import AppKit
import SwiftUI

/// One flow's editor: the palette, the canvas, the inspector, the console.
struct FlowEditor: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        if model.exists {
            VStack(spacing: 0) {
                EditorToolbar()
                DashedRule()
                HStack(spacing: 0) {
                    BlockPalette()
                    Divider().overlay(Theme.borderSubtle)
                    VStack(spacing: 0) {
                        switch model.mode {
                        case .blocks: BlockCanvas()
                        case .graph: GraphView()
                        }
                        if model.showConsole {
                            Divider().overlay(Theme.borderSubtle)
                            Console()
                        }
                    }
                    Divider().overlay(Theme.borderSubtle)
                    Inspector()
                }
            }
            .background(Theme.panel)
            .preferredColorScheme(.dark)
        } else {
            Text("This flow was deleted.").font(Theme.sans(13)).foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panel)
        }
    }
}

private struct EditorToolbar: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        let flow = model.flow
        HStack(spacing: 10) {
            Image(systemName: flow.glyph).foregroundStyle(Theme.orange)
            TextField("Name", text: Binding(get: { flow.name }, set: { name in
                model.edit("Rename", coalescing: "name") { $0.name = name }
            }))
            .textFieldStyle(.plain)
            .font(Theme.sans(15, .semibold))
            .frame(maxWidth: 260)
            if !model.isBlock {
                FlowLamp(flow: flow)
                Text(FlowCheck.sentence(for: flow, registry: model.registry))
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()

            SegmentedChoice(options: ["Blocks", "Graph"], selection: Binding(
                get: { model.mode == .blocks ? 0 : 1 }, set: { model.mode = $0 == 0 ? .blocks : .graph }),
                help: ["Stacks that snap together", "Nodes and wires — every binding drawn"])
                .frame(width: 150)

            HStack(spacing: 2) {
                Button { model.zoom = max(0.5, model.zoom - 0.1) } label: { Image(systemName: "minus") }
                Text("\(Int((model.zoom * 100).rounded()))%").font(Theme.mono(10)).frame(width: 38)
                    .onTapGesture { model.zoom = 1 }
                Button { model.zoom = min(2, model.zoom + 0.1) } label: { Image(systemName: "plus") }
            }
            .industrialButton(.ghost, compact: true)

            if !model.showConsole {
                Button { model.showConsole = true } label: { Image(systemName: "terminal") }
                    .industrialButton(.ghost, compact: true).help("Show the console")
            }

            if !model.isBlock {
                let running = model.trace?.isRunning == true
                if running {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .industrialButton(.danger)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.run() } label: { Label("Run", systemImage: "play.fill") }
                        .industrialButton(.primary)
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(flow.body.isEmpty || model.issues.contains { $0.severity == .error })
                        .help(model.issues.first { $0.severity == .error }?.message ?? "Run it now, with the test input — ⌘R")
                }
                Menu {
                    Button("Export…") { FlowFiles.export(flow.id, library: model.library) }
                    Button("Duplicate") {
                        if let copy = model.library.duplicate(flow.id) { FlowEditorWindows.shared.open(.flow(copy.id)) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuKey(compact: true)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Theme.housing)
    }
}

// MARK: - Windows

/// Every open editor, one window per flow or block.
@MainActor
final class FlowEditorWindows: NSObject, NSWindowDelegate {
    static let shared = FlowEditorWindows()

    private var windows: [EditorDocument: NSWindow] = [:]
    private var monitors: [EditorDocument: Any] = [:]
    private var models: [EditorDocument: EditorModel] = [:]
    /// The library, for windows opened from outside an editor.
    private(set) weak var library: FlowLibrary?
    private weak var engine: FlowEngine?
    private weak var store: GroupStore?
    private weak var workspaces: WorkspaceEngine?
    private weak var settings: AppSettings?

    func attach(library: FlowLibrary, engine: FlowEngine, store: GroupStore, workspaces: WorkspaceEngine, settings: AppSettings) {
        self.library = library
        self.engine = engine
        self.store = store
        self.workspaces = workspaces
        self.settings = settings
    }

    func open(_ document: EditorDocument) {
        if let window = windows[document] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let library, let engine, let store, let workspaces, let settings else { return }
        let model = EditorModel(document: document, library: library, engine: engine)
        let root = FlowEditor()
            .environmentObject(model)
            .environmentObject(library)
            .environmentObject(engine)
            .environmentObject(store)
            .environmentObject(workspaces)
            .environmentObject(settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 600)
        window.contentView = NSHostingView(rootView: root)
        window.title = model.flow.name
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        // Remembered per flow: each editor opens where you last left it.
        window.setFrameAutosaveName("FlowEditor.\(document.id.uuidString)")
        if !window.setFrameUsingName("FlowEditor.\(document.id.uuidString)") { window.center() }
        model.undoManager = window.undoManager
        windows[document] = window
        models[document] = model
        monitors[document] = keyMonitor(for: model, in: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ document: EditorDocument) { windows[document]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let document = windows.first(where: { $0.value === window })?.key else { return }
        if let monitor = monitors.removeValue(forKey: document) { NSEvent.removeMonitor(monitor) }
        windows[document] = nil
        models[document] = nil
        library?.saveNow()
    }

    /// The canvas's keys, only while its window is key and no text field has
    /// the keyboard: ⌫ deletes, ⌘C ⌘V ⌘D copy, paste, duplicate, the arrows
    /// walk the blocks, ⌘B a breakpoint, ⌘/ skip, Space finds a block, ⌘±
    /// zoom.
    private func keyMonitor(for model: EditorModel, in window: NSWindow) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak model] event in
            guard let window, let model, event.window === window else { return event }
            let typing = window.firstResponder is NSText
            // Arrow keys always carry the numeric-pad and function flags; only
            // the modifier keys decide what a press means.
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers ?? ""
            let handled: Bool = MainActor.assumeIsolated {
                if flags == .command {
                    switch key {
                    case "=", "+": model.zoom = min(2, model.zoom + 0.1); return true
                    case "-": model.zoom = max(0.5, model.zoom - 0.1); return true
                    case "0": model.zoom = 1; return true
                    default: break
                    }
                }
                guard !typing else { return false }
                switch (flags, event.keyCode, key) {
                case ([], 51, _), ([], 117, _), (.command, 51, _):
                    guard !model.selection.isEmpty else { return false }
                    model.delete(model.selection)
                    return true
                case (.command, _, "c"): model.copy(model.selection); return !model.selection.isEmpty
                case (.command, _, "v"): model.paste(); return true
                case (.command, _, "d"): model.duplicate(model.selection); return true
                case (.command, _, "b"):
                    for id in model.selection { model.update(id, "Breakpoint") { $0.hasBreakpoint.toggle() } }
                    return true
                case (.command, _, "/"):
                    for id in model.selection { model.update(id, "Skip") { $0.isDisabled.toggle() } }
                    return true
                case ([], 125, _): model.selectNeighbour(1); return true
                case ([], 126, _): model.selectNeighbour(-1); return true
                case ([], _, " "):
                    NotificationCenter.default.post(name: .flowEditorFindBlock, object: model.document.id); return true
                case ([], 53, _):
                    model.selection = []; return true
                default:
                    return false
                }
            }
            return handled ? nil : event
        }
    }
}

// MARK: - Dialogs

extension FlowDialogs {
    /// Asks for a name, and calls back with it unless cancelled.
    static func name(title: String, prompt: String, initial: String, done: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { done(name) }
    }
}

/// Adding a secret: its name and its value, straight into the Keychain.
@MainActor
enum SecretsDialog {
    static func add() -> String? {
        let alert = NSAlert()
        alert.messageText = "New secret"
        alert.informativeText = "Kept in your Keychain. Flows that use it get it as an environment variable; it never appears in a flow file, the console or a run's history."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        stack.orientation = .vertical
        stack.spacing = 8
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        name.placeholderString = "Name — OpenAI key"
        let value = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        value.placeholderString = "Value"
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(value)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let key = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.stringValue.isEmpty, Secrets.set(key, value.stringValue) else { return nil }
        return key
    }
}

/// Import and export, with the code an imported file carries shown first.
@MainActor
enum FlowFiles {
    static func export(_ id: UUID, library: FlowLibrary) {
        guard let flow = library.flow(id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(flow.name).gruppenflow"
        panel.title = "Export \(flow.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !library.export(id, to: url) { fail("Couldn't save \(url.lastPathComponent)") }
    }

    static func exportBlock(_ id: UUID, library: FlowLibrary) {
        guard let block = library.blocks.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(block.title).gruppenblock"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !library.exportBlock(id, to: url) { fail("Couldn't save \(url.lastPathComponent)") }
    }

    /// Reads each file, shows any code in it, and adds it only on a yes.
    @discardableResult
    static func importFiles(library: FlowLibrary) -> Flow? {
        var last: Flow?
        for url in Pickers.files(title: "Import a flow or block", prompt: "Import") {
            do {
                let incoming = try library.read(url)
                guard confirm(incoming, name: url.lastPathComponent) else { continue }
                if let flow = library.add(incoming) { last = flow }
            } catch {
                fail("Couldn't import \(url.lastPathComponent)", error.localizedDescription)
            }
        }
        return last
    }

    /// Code from a file is code that will run on this Mac as you. It is shown
    /// before anything from the file can.
    private static func confirm(_ incoming: FlowLibrary.Incoming, name: String) -> Bool {
        guard !incoming.code.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "\(name) contains code"
        alert.informativeText = "It would run on this Mac with your permissions. Read it before you import it. Imported flows arrive switched off."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        let text = incoming.code.map { "── \($0.place) (\($0.spec.language.label)) ──\n\($0.spec.source)" }.joined(separator: "\n\n")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        if let view = scroll.documentView as? NSTextView {
            view.string = text
            view.isEditable = false
            view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func fail(_ title: String, _ detail: String = "") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
