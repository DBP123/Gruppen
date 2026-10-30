import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The block view: stacks of blocks that snap together, on a canvas you can
// zoom and scroll.
//
// **Two kinds of drag, two kinds of payload.** Blocks travel as plain text
// and are caught by the canvas; output pills travel as a URL and are caught
// by input slots. Different types, so a block dragged across an input never
// lands in it, and a value dragged across the canvas never becomes a block.

/// The gaps between blocks, as each stack lays out.
struct InsertionPointsKey: PreferenceKey {
    static let defaultValue: [InsertionPoint] = []
    static func reduce(value: inout [InsertionPoint], nextValue: () -> [InsertionPoint]) {
        value.append(contentsOf: nextValue())
    }
}

/// A value pill on its way to an input, as a URL so only inputs take it.
enum ValueDrag {
    static func provider(_ source: ValueSource) -> NSItemProvider {
        let string = DragPayload.value(source).string
        let encoded = string.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return NSItemProvider(object: URL(string: "gruppen-value:\(encoded)")! as NSURL)
    }

    static func read(_ providers: [NSItemProvider], _ done: @escaping @MainActor @Sendable (ValueSource) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            guard let url = object as? URL, url.scheme == "gruppen-value",
                  let string = url.absoluteString.dropFirst("gruppen-value:".count).removingPercentEncoding,
                  case .value(let source)? = DragPayload(string: string) else { return }
            Task { @MainActor in done(source) }
        }
        return true
    }
}

// MARK: - Canvas

struct BlockCanvas: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        let flow = model.flow
        let size = canvasSize(flow)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                DotGrid()
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = [] }

                VStack(alignment: .leading, spacing: 18) {
                    if !model.isBlock { triggers(flow) }
                    body(flow)
                }
                .padding(40)

                ForEach(flow.loose) { stack in
                    LooseStackView(stack: stack)
                        .offset(x: stack.position.x, y: stack.position.y)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(name: "canvas")
            .onPreferenceChange(InsertionPointsKey.self) { model.insertionPoints = $0 }
            .onDrop(of: [.utf8PlainText, .plainText], delegate: CanvasDrop(model: model))
            .scaleEffect(model.zoom, anchor: .topLeading)
            .frame(width: size.width * model.zoom, height: size.height * model.zoom, alignment: .topLeading)
        }
        .background(Theme.panel)
        .gesture(MagnificationGesture().onChanged { scale in
            model.zoom = min(2, max(0.5, model.zoom * (1 + (scale - 1) * 0.08)))
        })
    }

    private func triggers(_ flow: Flow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("WHEN")
            if flow.triggers.isEmpty {
                Hint(text: "Drag a When block here — without one, it runs only by hand")
            }
            StackView(ref: .triggers, blocks: flow.triggers)
        }
    }

    private func body(_ flow: Flow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(model.isBlock ? "INSIDE THIS BLOCK" : "DO")
            if flow.body.isEmpty {
                Hint(text: "Drag blocks here from the left, or double-click one")
            }
            StackView(ref: .body, blocks: flow.body)
        }
    }

    /// Big enough for everything, with room to drop beyond it.
    private func canvasSize(_ flow: Flow) -> CGSize {
        let farthest = flow.loose.reduce(CGPoint(x: 0, y: 0)) {
            CGPoint(x: max($0.x, $1.position.x), y: max($0.y, $1.position.y))
        }
        let rows = CGFloat(flow.allBlocks.count) * 70
        return CGSize(width: max(1400, farthest.x + 700), height: max(1100, max(farthest.y + 600, rows + 400)))
    }
}

/// Where a dragged block lands.
private struct CanvasDrop: DropDelegate {
    let model: EditorModel

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        let moving: Bool = { if case .blocks(let source, _, _)? = model.dragging { return source == model.document.id }; return false }()
        return DropProposal(operation: moving ? .move : .copy)
    }

    func dropExited(info: DropInfo) { model.target = nil }

    func performDrop(info: DropInfo) -> Bool {
        let point = info.location
        // In this window the drag is already known; from another, it is read
        // from the pasteboard.
        if let payload = model.dragging {
            model.target = model.insertion(near: point, for: payload)
            model.drop(payload, at: point)
            return true
        }
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let payload = DragPayload(string: string) else { return }
            Task { @MainActor in
                model.target = model.insertion(near: point, for: payload)
                model.drop(payload, at: point)
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let next = model.insertion(near: info.location, for: model.dragging)
        if next != model.target { model.target = next }
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
            for x in stride(from: spacing, to: size.width, by: spacing) {
                for y in stride(from: spacing, to: size.height, by: spacing) {
                    context.fill(dot.offsetBy(dx: x, dy: y), with: .color(.white.opacity(0.05)))
                }
            }
        }
    }
}

private struct Hint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.sans(12))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 360, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd)
                .strokeBorder(Theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

/// A stack on its own, off to the side: dimmed, since it never runs, and
/// moved by its grip.
private struct LooseStackView: View {
    let stack: LooseStack
    @EnvironmentObject private var model: EditorModel
    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .bold))
                Text("NOT CONNECTED — NEVER RUNS").font(Theme.mono(8.5, .semibold)).tracking(0.8)
            }
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { offset = $0.translation }
                .onEnded { value in
                    offset = .zero
                    model.edit("Move stack") { flow in
                        guard let index = flow.loose.firstIndex(where: { $0.id == stack.id }) else { return }
                        flow.loose[index].position.x = max(0, flow.loose[index].position.x + value.translation.width)
                        flow.loose[index].position.y = max(0, flow.loose[index].position.y + value.translation.height)
                    }
                })
            StackView(ref: .loose(stack.id), blocks: stack.blocks)
                .opacity(0.62)
        }
        .offset(offset)
    }
}

// MARK: - Stack

struct StackView: View {
    let ref: StackRef
    let blocks: [Block]
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                gap(index)
                BlockView(block: block)
            }
            gap(blocks.count)
        }
    }

    /// The space between two blocks: where the insertion line shows, and the
    /// frame the drop is measured against.
    private func gap(_ index: Int) -> some View {
        let lit = model.target?.stack == ref && model.target?.index == index
        return ZStack(alignment: .leading) {
            Color.clear.frame(width: 300, height: blocks.isEmpty && ref != .triggers && ref != .body ? 22 : 7)
            if lit {
                Capsule().fill(Theme.orange).frame(width: 300, height: 3)
                    .shadow(color: Theme.orange.opacity(0.7), radius: 4)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: InsertionPointsKey.self,
                                   value: [InsertionPoint(stack: ref, index: index, line: proxy.frame(in: .named("canvas")))])
        })
    }
}

// MARK: - Block

struct BlockView: View {
    let block: Block
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        let definition = model.definition(block)
        let run = model.runState(block.id)
        let issues = model.issues(for: block.id)
        let available = FlowCheck.available(at: block.id, in: model.flow.body + model.flow.loose.flatMap(\.blocks),
                                            context: model.checkContext)
        let selected = model.selection.contains(block.id)

        VStack(alignment: .leading, spacing: 6) {
            header(definition, run: run, issues: issues, available: available)
            if !definition.outputs.isEmpty && !definition.isHatWithoutOutputs {
                outputs(definition, run: run)
            }
            // A failure, or what a block says for itself — not a repeat of the
            // value its pill already shows.
            if let message = run.message, !message.isEmpty,
               run.state == .failed || (run.state == .finished && run.outputs["message"] != nil) {
                Text(message)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(run.state == .failed ? Theme.red : Theme.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if !block.note.isEmpty {
                Text(block.note).font(Theme.sans(10.5).italic()).foregroundStyle(Theme.textMuted).lineLimit(2)
            }
            if case .container(let labels) = definition.shape {
                slots(definition, labels: labels)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(minWidth: 260, alignment: .leading)
        .background(BlockBackground(tint: definition.tint, hat: definition.isHat, state: run.state))
        .overlay(alignment: .leading) {
            if block.hasBreakpoint {
                Circle().fill(Theme.red).frame(width: 9, height: 9).offset(x: -15).help("Breakpoint: a run from here pauses before this block")
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: definition.isHat ? 13 : 8, style: .continuous)
                .strokeBorder(selected ? Theme.orange : (model.trace?.pausedAt == block.id ? Theme.amber : .clear),
                              lineWidth: selected ? 1.6 : 2)
        }
        .opacity(block.isDisabled ? 0.42 : 1)
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                if model.selection.remove(block.id) == nil { model.selection.insert(block.id) }
            } else {
                model.selection = [block.id]
            }
        }
        .onDrag { model.dragPayload(for: block).provider }
        .contextMenu { BlockMenu(block: block, definition: definition) }
    }

    private func header(_ definition: BlockDefinition, run: (state: BlockTrace.State?, outputs: [String: Value], message: String?),
                        issues: [FlowIssue], available: [AvailableValue]) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: definition.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(definition.tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(definition.tint.opacity(0.14)))
            WrapLayout(spacing: 5, lineSpacing: 5) {
                ForEach(Array(definition.phraseParts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .words(let words):
                        Text(words)
                            .font(Theme.sans(12.5, .medium))
                            .foregroundStyle(block.isDisabled ? Theme.textMuted : Theme.textPrimary)
                            .strikethrough(block.isDisabled)
                    case .input(let name):
                        if let port = definition.input(name) {
                            InputSlot(block: block, port: port, available: available,
                                      issue: issues.filter { $0.port == name }.map(\.severity).max())
                        }
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 4)
            // Issues with an input on the block's face show there; the rest
            // show here.
            if let worst = issues.filter({ issue in issue.port.map { !definition.phrase.contains("{\($0)}") } ?? true })
                .max(by: { $0.severity < $1.severity }) {
                Image(systemName: worst.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(worst.severity == .error ? Theme.red : Theme.amber)
                    .help(worst.message)
            }
            RunMark(state: run.state)
        }
    }

    private func outputs(_ definition: BlockDefinition, run: (state: BlockTrace.State?, outputs: [String: Value], message: String?)) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textMuted)
            ForEach(definition.outputs) { port in
                OutputPill(block: block, port: port, value: run.outputs[port.name])
            }
        }
        .padding(.leading, 30)
    }

    private func slots(_ definition: BlockDefinition, labels: [String]) -> some View {
        let isLanes = definition.implementation.isParallel
        let count = isLanes ? max(2, block.children.count) : labels.count
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text((isLanes ? "lane \(index + 1)" : labels[index]).uppercased())
                            .font(Theme.mono(8.5, .semibold)).tracking(0.9)
                            .foregroundStyle(definition.tint.opacity(0.85))
                        if isLanes && count > 2 {
                            Button { removeLane(index) } label: { Image(systemName: "minus.circle").font(.system(size: 9)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.textMuted).help("Remove this lane")
                        }
                    }
                    StackView(ref: .slot(block: block.id, index: index),
                              blocks: index < block.children.count ? block.children[index] : [])
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(definition.tint.opacity(0.35)).frame(width: 2)
                        }
                }
            }
            if isLanes {
                Button { model.update(block.id, "Add lane") { $0.children.append([]) } } label: {
                    Label("Lane", systemImage: "plus").font(Theme.sans(10.5))
                }
                .industrialButton(.ghost, compact: true)
            }
        }
        .padding(.leading, 6)
    }

    private func removeLane(_ index: Int) {
        model.update(block.id, "Remove lane") { block in
            if index < block.children.count { block.children.remove(at: index) }
        }
    }
}

extension BlockDefinition {
    /// Hats like "Run by hand" have nothing to hand over; no pill row.
    var isHatWithoutOutputs: Bool { isHat && outputs.isEmpty }
}

extension Implementation {
    var isParallel: Bool { if case .control(.parallel) = self { return true }; return false }
}

/// A block's body: raised, with its category's colour down the left edge. A
/// hat has a rounder top, the way it starts a stack.
private struct BlockBackground: View {
    let tint: Color
    let hat: Bool
    let state: BlockTrace.State?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: hat ? 13 : 8, style: .continuous)
        shape
            .fill(Theme.surfaceTop)
            .overlay(alignment: .leading) {
                Rectangle().fill(tint).frame(width: 3)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(state == .failed ? Theme.red.opacity(0.8) : Theme.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .background {
                if state == .running {
                    shape.fill(Theme.orange.opacity(0.35)).blur(radius: 8).pulsing(true, to: 0.3, duration: 0.7)
                }
            }
    }
}

// MARK: - Inputs and outputs

/// One input on a block's face: what it is set to, a pill when it reads
/// another block. Click to edit; drop an output pill on it to bind it.
struct InputSlot: View {
    let block: Block
    let port: Port
    let available: [AvailableValue]
    let issue: FlowIssue.Severity?
    @EnvironmentObject private var model: EditorModel
    @State private var editing = false
    @State private var targeted = false

    var body: some View {
        Button { editing = true } label: { face }
            .buttonStyle(.plain)
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                InputEditor(blockID: block.id, port: port, compact: true)
                    .environmentObject(model)
                    .frame(width: port.control == .code ? 520 : 320)
                    .padding(12)
                    .background(Theme.panel)
            }
            .onDrop(of: [.url], isTargeted: $targeted) { providers in
                ValueDrag.read(providers) { source in model.setInput(block.id, port.name, source) }
            }
    }

    @ViewBuilder private var face: some View {
        let source = block.inputs[port.name]
        switch source {
        case .output?, .trigger?, .variable?:
            let found = available.first { $0.binding == source }
            ValuePill(label: found?.label ?? InputText.summary(source, port: port), type: found?.type ?? .any,
                      source: found?.source)
                .overlay(Capsule().strokeBorder(targeted ? Theme.orange : issueTint, lineWidth: targeted || issue != nil ? 1.5 : 0))
        default:
            let empty = source == nil && (port.defaultValue.isNothing || port.defaultValue == .text(""))
            Text(InputText.summary(source, port: port))
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(empty ? Theme.textMuted : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(targeted ? Theme.orange : (issue != nil ? issueTint : port.type.tint.opacity(0.35)),
                                  style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: empty ? [3, 2] : [])))
                .help(port.help.isEmpty ? port.label : "\(port.label): \(port.help)")
        }
    }

    private var issueTint: Color { issue == .error ? Theme.red : (issue == .warning ? Theme.amber : .clear) }
}

/// One output, as a pill to drag onto an input further down. Shows what it
/// held on the last run.
struct OutputPill: View {
    let block: Block
    let port: Port
    let value: Value?
    @State private var inspecting = false

    var body: some View {
        HStack(spacing: 3) {
            ValuePill(label: port.label, type: port.type, compact: true)
                .onDrag { ValueDrag.provider(.output(block: block.id, port: port.name)) }
            if let value {
                Button { inspecting = true } label: {
                    Text(value.summary).font(Theme.mono(9)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $inspecting) { ValueInspector(value: value).frame(width: 360, height: 260) }
            }
        }
    }
}

/// A value from a run, in full: text as text, files as rows to reveal, data
/// as JSON.
struct ValueInspector: View {
    let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ValuePill(label: value.type.label, type: value.type)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.text(value), forType: .string)
                }
                .industrialButton(.quiet, compact: true)
            }
            ScrollView {
                if case .files(let urls) = value {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(urls, id: \.self) { url in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                Text(url.lastPathComponent).font(Theme.sans(12)).lineLimit(1)
                                Spacer()
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    .industrialButton(.ghost, compact: true)
                            }
                        }
                    }
                } else {
                    Text(Self.text(value))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Theme.panel)
    }

    /// Text as itself, files as their paths, everything else as JSON.
    static func text(_ value: Value) -> String {
        switch value {
        case .text(let text): return text
        case .files(let urls): return urls.map(\.path).joined(separator: "\n")
        default: return value.jsonText(pretty: true)
        }
    }
}

// MARK: - Context menu

private struct BlockMenu: View {
    let block: Block
    let definition: BlockDefinition
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        let targets = model.selection.contains(block.id) ? model.selection : [block.id]
        Button("Duplicate") { model.duplicate(targets) }
        Button("Copy") { model.copy(targets) }
        Divider()
        Button(block.isDisabled ? "Enable" : "Disable") {
            model.update(block.id, block.isDisabled ? "Enable" : "Disable") { $0.isDisabled.toggle() }
        }
        if !definition.isHat {
            Button(block.hasBreakpoint ? "Remove breakpoint" : "Add breakpoint") {
                model.update(block.id, "Breakpoint") { $0.hasBreakpoint.toggle() }
            }
            Menu("If it fails") {
                ForEach([FailurePolicy.stop, .continue, .retry(1), .retry(3)], id: \.self) { policy in
                    Button(policy.label + (block.onFailure == policy ? " ✓" : "")) {
                        model.update(block.id, "If it fails") { $0.onFailure = policy }
                    }
                }
            }
            Divider()
            Button("Package as a block…") {
                if !model.selection.contains(block.id) { model.selection = [block.id] }
                FlowDialogs.name(title: "Package as a block", prompt: "What should the new block be called?",
                                 initial: definition.title) { name in model.packageSelection(title: name) }
            }
            if case .inlineCode = definition.implementation {
                Button("Make a reusable block…") { BlockDesigner.open(fromCode: block, model: model) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(targets) }
    }
}
