import AppKit
import SwiftUI

/// The quick palette: a hotkey anywhere brings up a small panel of things to
/// run — your actions first, most recently used at the top, then the built-in
/// tools. Type to filter, arrows to move, Return to run, Escape to close.
///
/// A non-activating panel that can still take the keyboard, the way Spotlight
/// is: you type into it without Gruppen coming to the front, and the app you
/// were in is still the one a pasted snippet or a cleaned link goes back to.
@MainActor
final class QuickPalette {
    static let shared = QuickPalette()

    private var panel: PalettePanel?
    private weak var library: ScriptLibrary?
    private weak var triggers: ScriptTriggerCoordinator?

    private init() {}

    func attach(library: ScriptLibrary, triggers: ScriptTriggerCoordinator) {
        self.library = library
        self.triggers = triggers
        applyShortcut()
    }

    func applyShortcut() {
        HotkeyCenter.shared.unregisterAll(owner: "palette")
        guard library != nil, let shortcut = AppSettings.shared.paletteShortcut else { return }
        HotkeyCenter.shared.register(shortcut, owner: "palette") { [weak self] in self?.toggle() }
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        guard let library, triggers != nil else { return }
        let view = PaletteView(onRun: { [weak self] item in self?.run(item) },
                               onClose: { [weak self] in self?.close() })
            .environmentObject(library)
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
        case .script(let script):
            triggers?.run(script, paths: [], source: "Palette")
        case .tool(let step):
            Task {
                do {
                    _ = try await ScriptRunner.perform(step, files: [], hooks: triggers?.hooks ?? .init())
                } catch {
                    Notifier.post(title: step.kind.label, body: error.localizedDescription) { _ in }
                }
            }
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
    case script(Script)
    case tool(ScriptStep)

    var id: String {
        switch self {
        case .script(let script): return script.id.uuidString
        case .tool(let step): return step.kind.rawValue + step.caseStyle.rawValue
        }
    }

    var title: String {
        switch self {
        case .script(let script): return script.name
        case .tool(let step): return step.kind == .changeCase ? "Change case to \(step.caseStyle.label)" : step.kind.label
        }
    }

    var glyph: String {
        switch self {
        case .script(let script): return script.steps.first?.kind.glyph ?? "bolt"
        case .tool(let step): return step.kind.glyph
        }
    }

    /// The built-in tools, there before any action has been made.
    static let tools: [PaletteItem] = {
        var steps: [ScriptStep] = [.make(.cleanLink), .make(.cleanText)]
        for style in CaseStyle.allCases {
            var step = ScriptStep.make(.changeCase)
            step.caseStyle = style
            steps.append(step)
        }
        steps += [.make(.saveClipboardImage), .make(.darkMode), .make(.mute), .make(.keepAwake),
                  .make(.lockScreen), .make(.toggleStashes), .make(.openStash), .make(.ejectDisks), .make(.emptyTrash)]
        return steps.map(PaletteItem.tool)
    }()
}

private struct PaletteView: View {
    @EnvironmentObject private var library: ScriptLibrary
    let onRun: (PaletteItem) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    /// Your actions, most recently run first, then the tools — filtered.
    private var items: [PaletteItem] {
        let actions = library.scripts
            .filter { $0.section == .actions && $0.isComplete }
            .sorted { (library.runs[$0.id]?.last?.date ?? .distantPast) > (library.runs[$1.id]?.last?.date ?? .distantPast) }
            .map(PaletteItem.script)
        // A tool you have also saved as an action appears once, as yours.
        let saved = Set(library.scripts.filter { $0.section == .actions && $0.steps.count == 1 }
            .map { $0.steps[0].kind.rawValue + $0.steps[0].caseStyle.rawValue })
        let tools = PaletteItem.tools.filter { !saved.contains($0.id) }
        let all = actions + tools
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.rays").foregroundStyle(Theme.orange)
                TextField("Run an action…", text: $query)
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
            if case .script(let script) = item, let shortcut = script.trigger.shortcut {
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
