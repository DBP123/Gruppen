import AppKit
import Combine
import SwiftUI

/// What an editor window edits: a flow, or the inside of a block made by
/// packaging other blocks. Both are a stack of blocks on a canvas; a packaged
/// block's inputs are what its stack reads as the trigger.
enum EditorDocument: Hashable {
    case flow(UUID)
    case block(UUID)

    var id: UUID {
        switch self {
        case .flow(let id), .block(let id): return id
        }
    }
}

/// Something being dragged over the canvas.
enum DragPayload: Codable, Equatable {
    /// A block from the palette.
    case new(definition: String)
    /// Blocks already on a canvas — moved within their own window, copied
    /// into another.
    case blocks(document: UUID, ids: [UUID], copies: [Block])
    /// An output pill, to bind an input to.
    case value(ValueSource)

    private static let prefix = "gruppen-drag:"

    var string: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + (String(data: data, encoding: .utf8) ?? "")
    }

    init?(string: String) {
        guard string.hasPrefix(Self.prefix),
              let data = string.dropFirst(Self.prefix.count).data(using: .utf8),
              let payload = try? JSONDecoder().decode(DragPayload.self, from: data) else { return nil }
        self = payload
    }

    var provider: NSItemProvider { NSItemProvider(object: string as NSString) }
}

/// Where a drop would go: between two blocks of a stack.
struct InsertionPoint: Equatable {
    var stack: StackRef
    var index: Int
    /// The line drawn there, in canvas coordinates.
    var line: CGRect
}

/// One editor's state: the document, the selection, the view, and the drag in
/// progress. Edits go straight through to the library — it is the one source
/// of truth — with the value from before kept for undo.
@MainActor
final class EditorModel: ObservableObject {
    enum Mode: String { case blocks, graph }

    let document: EditorDocument
    let library: FlowLibrary
    let engine: FlowEngine
    weak var undoManager: UndoManager?

    @Published var selection: Set<UUID> = []
    @Published var mode: Mode = .blocks
    @Published var zoom: CGFloat = 1
    @Published var showConsole = true
    /// What is being dragged, set the moment a drag starts in this window.
    @Published var dragging: DragPayload?
    /// Where it would land.
    @Published var target: InsertionPoint?
    /// A past run shown on the canvas instead of the live one.
    @Published var viewing: FlowRunRecord?
    /// A code line an error pointed at, by block.
    @Published var errorLines: [UUID: Int] = [:]

    /// Gaps between blocks, reported by the stacks as they lay out.
    var insertionPoints: [InsertionPoint] = []

    private var forwarding: [AnyCancellable] = []
    private var lastCoalesce: (key: String, at: Date)?

    init(document: EditorDocument, library: FlowLibrary, engine: FlowEngine) {
        self.document = document
        self.library = library
        self.engine = engine
        // The library is what changes; whoever shows this model redraws with it.
        forwarding.append(library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        forwarding.append(engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    // MARK: The document

    var registry: BlockRegistry { library.registry }

    var customBlock: CustomBlock? {
        guard case .block(let id) = document else { return nil }
        return library.blocks.first { $0.id == id }
    }

    /// The document as a flow. A packaged block is shown as a flow with no
    /// hats whose body is its stack.
    var flow: Flow {
        switch document {
        case .flow(let id):
            return library.flow(id) ?? Flow(id: id, name: "Deleted flow")
        case .block(let id):
            guard let block = customBlock, case .blocks(let stack) = block.body else {
                return Flow(id: id, name: "Deleted block")
            }
            return Flow(id: id, name: block.title, glyph: block.glyph, body: stack)
        }
    }

    var exists: Bool {
        switch document {
        case .flow(let id): return library.flow(id) != nil
        case .block: return customBlock != nil
        }
    }

    var isBlock: Bool { if case .block = document { return true }; return false }

    var checkContext: FlowCheck.Context {
        if let block = customBlock { return FlowCheck.context(forPackaged: block, registry: registry) }
        return FlowCheck.context(for: flow, registry: registry)
    }

    var issues: [FlowIssue] {
        if isBlock { return FlowCheck.issues(in: flow.body, context: checkContext) }
        return FlowCheck.issues(in: flow, registry: registry)
    }

    func issues(for block: UUID) -> [FlowIssue] { issues.filter { $0.block == block } }

    /// Changes the document, keeping what it was for undo. Edits sharing a
    /// `coalescing` key within a second are one undo step — typing a name is
    /// one change, not one per letter.
    func edit(_ action: String, coalescing key: String? = nil, _ change: (inout Flow) -> Void) {
        let before = flow
        var after = before
        change(&after)
        guard after != before else { return }
        apply(after)
        if let key, let last = lastCoalesce, last.key == key, Date().timeIntervalSince(last.at) < 1 {
            lastCoalesce = (key, Date())
            return
        }
        lastCoalesce = key.map { ($0, Date()) }
        registerUndo(restoring: before, action: action)
    }

    private func registerUndo(restoring value: Flow, action: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            let current = model.flow
            model.apply(value)
            model.lastCoalesce = nil
            model.registerUndo(restoring: current, action: action)
        }
        undoManager?.setActionName(action)
    }

    private func apply(_ value: Flow) {
        switch document {
        case .flow:
            library.update(value)
        case .block:
            guard var block = customBlock else { return }
            block.title = value.name
            block.glyph = value.glyph
            block.body = .blocks(value.body)
            library.saveBlock(block)
        }
    }

    // MARK: Blocks

    func definition(_ block: Block) -> BlockDefinition { registry.definition(block.definition) }

    /// Adds a block from the palette: after the selected block, or at the end
    /// of the body — a hat goes to the top.
    func add(_ definitionID: String) {
        let block = Block(definitionID)
        let isHat = registry.definition(definitionID).isHat
        guard !(isHat && isBlock) else { return }
        edit("Add \(registry.definition(definitionID).title)") { flow in
            if isHat {
                flow.insert([block], into: .triggers, at: flow.triggers.count, registry: registry)
            } else if let selected = selection.first, let (stack, index) = flow.location(of: selected), !stack.holdsHats {
                flow.insert([block], into: stack, at: index + 1, registry: registry)
            } else {
                flow.insert([block], into: .body, at: flow.body.count, registry: registry)
            }
            flow.bindNaturally(block.id, registry: registry)
        }
        selection = [block.id]
    }

    func drop(_ payload: DragPayload, at point: CGPoint) {
        let target = self.target
        self.target = nil
        dragging = nil
        switch payload {
        case .new(let definitionID):
            let block = Block(definitionID)
            guard !(registry.definition(definitionID).isHat && isBlock) else { return }
            edit("Add \(registry.definition(definitionID).title)") { flow in
                if let target {
                    flow.insert([block], into: target.stack, at: target.index, registry: registry)
                } else if registry.definition(definitionID).isHat {
                    flow.insert([block], into: .triggers, at: flow.triggers.count, registry: registry)
                } else {
                    flow.addLoose([block], at: point, registry: registry)
                }
                flow.bindNaturally(block.id, registry: registry)
            }
            selection = [block.id]
        case .blocks(let source, let ids, let copies):
            if source == document.id {
                edit(ids.count == 1 ? "Move block" : "Move blocks") { flow in
                    if let target {
                        flow.move(ids, to: target.stack, at: target.index, registry: registry)
                    } else {
                        let blocks = flow.remove(Set(ids))
                        flow.addLoose(blocks, at: point, registry: registry)
                    }
                }
            } else {
                let fresh = Block.copies(of: copies)
                edit("Paste blocks") { flow in
                    if let target {
                        flow.insert(fresh, into: target.stack, at: target.index, registry: registry)
                    } else {
                        flow.addLoose(fresh, at: point, registry: registry)
                    }
                }
                selection = Set(fresh.map(\.id))
            }
        case .value:
            break
        }
    }

    /// The nearest gap to `point` that `payload` may go into, or nil for
    /// empty canvas.
    func insertion(near point: CGPoint, for payload: DragPayload?) -> InsertionPoint? {
        let hats: Bool? = {
            switch payload {
            case .new(let id): return registry.definition(id).isHat
            case .blocks(_, _, let copies): return copies.first.map { registry.definition($0.definition).isHat }
            default: return nil
            }
        }()
        guard let hats else { return nil }
        let moving: Set<UUID> = { if case .blocks(_, let ids, _) = payload { return Set(ids) }; return [] }()
        let candidates = insertionPoints.filter { point in
            guard point.stack.holdsHats == hats else { return false }
            // Not into the slots of a block being moved.
            if case .slot(let owner, _) = point.stack, flow.isInside(owner, anyOf: moving) { return false }
            return true
        }
        return candidates
            .filter { abs($0.line.midY - point.y) < 26 && point.x > $0.line.minX - 30 && point.x < $0.line.maxX + 60 }
            .min { abs($0.line.midY - point.y) < abs($1.line.midY - point.y) }
    }

    /// What dragging `block` picks up: it alone, the selection it is part
    /// of, or — with ⇧ — it and the blocks under it.
    func dragPayload(for block: Block) -> DragPayload {
        let current = flow
        var ids = [block.id]
        if NSEvent.modifierFlags.contains(.shift) {
            ids = current.blockAndFollowing(block.id)
        } else if selection.contains(block.id), selection.count > 1 {
            ids = current.allBlocks.map(\.id).filter(selection.contains)
        }
        let payload = DragPayload.blocks(document: document.id, ids: ids,
                                         copies: ids.compactMap { current.block($0) })
        dragging = payload
        return payload
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        edit(ids.count == 1 ? "Delete block" : "Delete blocks") { flow in
            let removed = flow.remove(ids)
            flow.dropBindings(to: Set(Block.flatten(removed).map(\.id)))
        }
        selection.subtract(ids)
    }

    func update(_ id: UUID, _ action: String, coalescing key: String? = nil, _ change: (inout Block) -> Void) {
        edit(action, coalescing: key) { $0.update(id, change) }
    }

    func setInput(_ block: UUID, _ port: String, _ source: ValueSource?) {
        update(block, "Change \(port)", coalescing: "\(block).\(port)") { $0.inputs[port] = source }
    }

    func duplicate(_ ids: Set<UUID>) {
        let current = flow
        guard let first = current.allBlocks.first(where: { ids.contains($0.id) }),
              let (stack, index) = current.location(of: first.id), let siblings = current.stack(stack) else { return }
        let picked = siblings.filter { ids.contains($0.id) }
        let copies = Block.copies(of: picked)
        edit("Duplicate") { flow in
            flow.insert(copies, into: stack, at: index + picked.count, registry: registry)
        }
        selection = Set(copies.map(\.id))
    }

    // MARK: Clipboard

    static let pasteboardType = NSPasteboard.PasteboardType("com.dhilanpatel.gruppen.blocks")

    func copy(_ ids: Set<UUID>) {
        let current = flow
        let blocks = current.allBlocks.filter { ids.contains($0.id) }
            .filter { block in !blocks(current, containing: block.id, among: ids) }
        guard !blocks.isEmpty, let data = try? JSONEncoder().encode(blocks) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.pasteboardType)
    }

    /// Whether `id` is inside another of `ids` — copied with it already.
    private func blocks(_ flow: Flow, containing id: UUID, among ids: Set<UUID>) -> Bool {
        flow.isInside(id, anyOf: ids.subtracting([id]))
    }

    func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let blocks = try? JSONDecoder().decode([Block].self, from: data) else { return }
        let copies = Block.copies(of: blocks)
        edit("Paste") { flow in
            let hats = copies.filter { registry.definition($0.definition).isHat }
            let rest = copies.filter { !registry.definition($0.definition).isHat }
            if !isBlock { flow.insert(hats, into: .triggers, at: flow.triggers.count, registry: registry) }
            if let selected = selection.first, let (stack, index) = flow.location(of: selected), !stack.holdsHats {
                flow.insert(rest, into: stack, at: index + 1, registry: registry)
            } else {
                flow.insert(rest, into: .body, at: flow.body.count, registry: registry)
            }
        }
        selection = Set(copies.map(\.id))
    }

    /// Moves the selection up or down to the next block in reading order.
    func selectNeighbour(_ offset: Int) {
        let order = flow.allBlocks.map(\.id)
        guard !order.isEmpty else { return }
        guard let current = selection.first, let index = order.firstIndex(of: current) else {
            selection = [order[offset > 0 ? 0 : order.count - 1]]
            return
        }
        selection = [order[min(max(0, index + offset), order.count - 1)]]
    }

    // MARK: Packaging

    /// Turns the selected blocks — consecutive in one stack — into a block of
    /// their own, and puts it where they were.
    func packageSelection(title: String) {
        let current = flow
        guard let first = current.allBlocks.first(where: { selection.contains($0.id) }),
              let (stack, index) = current.location(of: first.id), let siblings = current.stack(stack) else { return }
        let run = Array(siblings[index...].prefix { selection.contains($0.id) })
        guard !run.isEmpty else { return }
        let later = Array(siblings[(index + run.count)...]) + (stack == .body ? [] : current.body)
        let packaged = CustomBlock.package(run, title: title, readBy: later, registry: registry)
        library.saveBlock(packaged.block)
        edit("Package as block") { flow in
            _ = flow.remove(Set(run.map(\.id)))
            flow.insert([packaged.call], into: stack, at: index, registry: library.registry)
            func repoint(_ blocks: inout [Block]) {
                for i in blocks.indices {
                    blocks[i].inputs = blocks[i].inputs.mapValues { $0.replacing(packaged.readers) }
                    for slot in blocks[i].children.indices { repoint(&blocks[i].children[slot]) }
                }
            }
            repoint(&flow.body)
            for i in flow.loose.indices { repoint(&flow.loose[i].blocks) }
        }
        selection = [packaged.call.id]
    }

    // MARK: Running

    var trace: RunTrace? { engine.traces[document.id] }

    /// What the canvas shows for `block`: from the past run being viewed, or
    /// the live one.
    func runState(_ block: UUID) -> (state: BlockTrace.State?, outputs: [String: Value], message: String?) {
        if let viewing {
            let trace = viewing.blocks.first { $0.block == block }
            return (trace?.state, trace?.outputs ?? [:], trace?.message)
        }
        guard let trace else { return (nil, [:], nil) }
        return (trace.states[block], trace.outputs[block] ?? [:], trace.messages[block])
    }

    /// Runs the flow from the editor: breakpoints honoured, the hats' sample
    /// input standing in for a real event.
    func run() {
        guard case .flow(let id) = document else { return }
        viewing = nil
        errorLines = [:]
        let sample = flow.triggers.reduce(into: [String: Value]()) { $0.merge($1.sample) { first, _ in first } }
        library.saveNow()
        let trace = engine.run(id, trigger: sample, source: "Editor", debug: true)
        watchForErrorLine(trace)
    }

    func stop() { engine.stop(document.id) }

    func resume() { if let debugger = trace?.debugger { Task { await debugger.resume() } } }
    func step() { if let debugger = trace?.debugger { Task { await debugger.step() } } }

    /// When a code block fails on a line, marks that line in its editor.
    private func watchForErrorLine(_ trace: RunTrace?) {
        guard let trace else { return }
        forwarding.append(trace.$messages.sink { [weak self] messages in
            guard let self else { return }
            for (block, message) in messages where trace.states[block] == .failed || message.hasPrefix("Line ") {
                if let line = Int(message.dropFirst(5).prefix { $0.isNumber }) { self.errorLines[block] = line }
            }
        })
    }
}

extension Flow {
    /// Every block on the canvas — hats, body and loose stacks — in reading
    /// order.
    var allBlocks: [Block] { Block.flatten(triggers + body + loose.flatMap(\.blocks)) }
}
