import AppKit
import SwiftUI

/// The quick palette: a hotkey anywhere brings up a small panel of things to
/// run — your flows first, most recently used at the top, then the built-in
/// tools. Type to filter, arrows to move, Return to run, Escape to close.
///
/// A non-activating panel that can still take the keyboard, the way Spotlight
/// is: you type into it without Gruppen coming to the front, and the app you
/// were in is still the one a pasted snippet or a cleaned link goes back to.
@MainActor
final class QuickPalette {
    static let shared = QuickPalette()

    private var panel: PalettePanel?
    private weak var engine: FlowEngine?

    private init() {}

    func attach(engine: FlowEngine) {
        self.engine = engine
        applyShortcut()
    }

    func applyShortcut() {
        HotkeyCenter.shared.unregisterAll(owner: "palette")
        guard engine != nil, let shortcut = AppSettings.shared.paletteShortcut else { return }
        HotkeyCenter.shared.register(shortcut, owner: "palette") { [weak self] in self?.toggle() }
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        guard let engine else { return }
        let view = PaletteView(onRun: { [weak self] item in self?.run(item) },
                               onClose: { [weak self] in self?.close() })
            .environmentObject(engine)
            .environmentObject(engine.library)
        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 560, height: 420)
        host.frame = NSRect(origin: .zero, size: size)
        let panel = self.panel ?? PalettePanel(size: size)
        panel.contentView = host
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - frame.height * 0.12))
        }
        panel.onResign = { [weak self] in self?.close() }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Closes first, so the app that was in front is in front again by the
    /// time a snippet pastes or a link is cleaned.
    private func run(_ item: PaletteItem) {
        close()
        switch item {
        case .flow(let flow):
            engine?.run(flow.id, source: "Palette")
        case .tool(let tool):
            engine?.runOnce(tool.block, title: tool.title)
        }
    }
}

/// Borderless, floating, and able to become key without activating the app.
private final class PalettePanel: NSPanel {
    var onResign: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }

    override func cancelOperation(_ sender: Any?) { onResign?() }
}

/// Something the palette can run.
enum PaletteItem: Identifiable {
    case flow(Flow)
    case tool(Preset)

    /// A built-in block run on its own, with its settings filled in.
    struct Preset {
        var title: String
        var block: Block
    }

    var id: String {
        switch self {
        case .flow(let flow): return flow.id.uuidString
        case .tool(let tool): return tool.title
        }
    }

    var title: String {
        switch self {
        case .flow(let flow): return flow.name
        case .tool(let tool): return tool.title
        }
    }

    var glyph: String {
        switch self {
        case .flow(let flow): return flow.glyph
        case .tool(let tool): return Catalog.definition(tool.block.definition)?.glyph ?? "bolt"
        }
    }

    /// The built-in tools, there before any flow has been made.
    static let tools: [PaletteItem] = {
        func tool(_ title: String, _ id: String, _ inputs: [String: Value] = [:]) -> PaletteItem {
            .tool(Preset(title: title, block: Block(id, inputs: inputs.mapValues(ValueSource.literal))))
        }
        return [
            tool("Clean copied link", "clip.clean", ["what": .text("link")]),
            tool("Clean copied text", "clip.clean", ["what": .text("text")]),
            tool("Save copied image", "clip.saveImage"),
            tool("Toggle Dark Mode", "system.appearance"),
            tool("Toggle mute", "system.mute"),
            tool("Keep awake for an hour", "system.keepAwake"),
            tool("Lock screen", "system.lock"),
            tool("Hide or show stashes", "gruppen.toggleStashes"),
            tool("Open a stash", "gruppen.openStash"),
            tool("Eject disks", "system.eject"),
            tool("Empty Trash", "system.emptyTrash"),
        ]
    }()
}

private struct PaletteView: View {
    @EnvironmentObject private var library: FlowLibrary
    @EnvironmentObject private var engine: FlowEngine
    let onRun: (PaletteItem) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    /// Your flows that run by hand, most recently run first, then the tools —
    /// filtered.
    private var items: [PaletteItem] {
        let registry = library.registry
        let flows = engine.manualFlows
            .filter { !$0.body.isEmpty && $0.isRunnable(registry: registry) }
            .sorted { (library.lastRun($0.id)?.date ?? .distantPast) > (library.lastRun($1.id)?.date ?? .distantPast) }
            .map(PaletteItem.flow)
        let all = flows + PaletteItem.tools
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.rays").foregroundStyle(Theme.orange)
                TextField("Run a flow or a tool…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(17))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { if items.indices.contains(selected) { onRun(items[selected]) } }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            DashedRule()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selected)
                                .id(index)
                                .onTapGesture { onRun(item) }
                        }
                        if items.isEmpty {
                            Text("NOTHING MATCHES")
                                .font(Theme.mono(10, .semibold)).tracking(1.1)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.vertical, 30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { proxy.scrollTo($0) }
            }
        }
        .frame(width: 560, height: 420)
        .raisedPanel(cornerRadius: 12)
        .onAppear { focused = true; selected = 0 }
        .onChange(of: query) { _ in selected = 0 }
        .background(
            // Arrow keys move the selection while the field keeps the focus.
            Group {
                Button("") { selected = max(selected - 1, 0) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { selected = min(selected + 1, max(items.count - 1, 0)) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { onClose() }.keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
        )
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.glyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.orange : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .recessed(cornerRadius: 6, fill: .black.opacity(0.35))
            Text(item.title)
                .font(Theme.sans(13, selected ? .semibold : .regular))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if case .flow(let flow) = item,
               let shortcut = flow.triggers.lazy.compactMap({ HotkeyValue.shortcut($0.text("keys")) }).first {
                KeyBadge(text: shortcut.display)
            }
            if case .tool = item {
                Text("TOOL").font(Theme.mono(8, .semibold)).tracking(0.8).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
    }
}
