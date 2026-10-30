import CoreGraphics
import Foundation

/// A stack of blocks inside a flow: the hats, the body, a loose stack, or one
/// slot of a container.
enum StackRef: Hashable, Sendable {
    case triggers
    case body
    case loose(UUID)
    case slot(block: UUID, index: Int)

    /// Whether hats go here. Only the trigger stack takes them, and only it.
    var holdsHats: Bool { self == .triggers }
}

/// The edits the canvas and the graph make, as plain operations on the value
/// — so they are tested without a window, and undo is a matter of keeping the
/// value from before.
extension Flow {
    func stack(_ ref: StackRef) -> [Block]? {
        switch ref {
        case .triggers: return triggers
        case .body: return body
        case .loose(let id): return loose.first { $0.id == id }?.blocks
        case .slot(let owner, let index):
            guard let block = block(owner), index < block.children.count else { return nil }
            return block.children[index]
        }
    }

    /// Changes the stack `ref` in place. False when there is no such stack.
    @discardableResult
    mutating func modify(_ ref: StackRef, _ change: (inout [Block]) -> Void) -> Bool {
        switch ref {
        case .triggers: change(&triggers); return true
        case .body: change(&body); return true
        case .loose(let id):
            guard let index = loose.firstIndex(where: { $0.id == id }) else { return false }
            change(&loose[index].blocks)
            return true
        case .slot(let owner, let slot):
            var found = false
            update(owner) { block in
                while block.children.count <= slot { block.children.append([]) }
                change(&block.children[slot])
                found = true
            }
            return found
        }
    }

    /// Changes the block `id`, wherever it sits.
    mutating func update(_ id: UUID, _ change: (inout Block) -> Void) {
        func visit(_ stack: inout [Block]) -> Bool {
            for index in stack.indices {
                if stack[index].id == id { change(&stack[index]); return true }
                for slot in stack[index].children.indices where visit(&stack[index].children[slot]) { return true }
            }
            return false
        }
        if visit(&triggers) || visit(&body) { return }
        for index in loose.indices where visit(&loose[index].blocks) { return }
    }

    /// Where the block `id` sits: its stack and its place in it.
    func location(of id: UUID) -> (stack: StackRef, index: Int)? {
        func find(_ stack: [Block], _ ref: StackRef) -> (StackRef, Int)? {
            for (index, block) in stack.enumerated() {
                if block.id == id { return (ref, index) }
                for (slot, child) in block.children.enumerated() {
                    if let found = find(child, .slot(block: block.id, index: slot)) { return found }
                }
            }
            return nil
        }
        if let found = find(triggers, .triggers) ?? find(body, .body) { return found }
        for stack in loose { if let found = find(stack.blocks, .loose(stack.id)) { return found } }
        return nil
    }

    /// Puts `blocks` into `ref` at `index`, keeping hats out of the body and
    /// everything else out of the triggers.
    mutating func insert(_ blocks: [Block], into ref: StackRef, at index: Int, registry: BlockRegistry) {
        let fitting = blocks.filter { registry.definition($0.definition).isHat == ref.holdsHats }
        guard !fitting.isEmpty else { return }
        modify(ref) { stack in stack.insert(contentsOf: fitting, at: min(max(0, index), stack.count)) }
    }

    /// A new loose stack at `point`, for blocks dropped on empty canvas.
    mutating func addLoose(_ blocks: [Block], at point: CGPoint, registry: BlockRegistry) {
        let fitting = blocks.filter { !registry.definition($0.definition).isHat }
        guard !fitting.isEmpty else { return }
        loose.append(LooseStack(position: point, blocks: fitting))
    }

    /// Takes the blocks `ids` out of wherever they are — a container with its
    /// contents — and returns them in the order they were found. Loose stacks
    /// left empty go too.
    @discardableResult
    mutating func remove(_ ids: Set<UUID>) -> [Block] {
        var removed: [Block] = []
        func strip(_ stack: inout [Block]) {
            var kept: [Block] = []
            for var block in stack {
                if ids.contains(block.id) { removed.append(block); continue }
                for slot in block.children.indices { strip(&block.children[slot]) }
                kept.append(block)
            }
            stack = kept
        }
        strip(&triggers)
        strip(&body)
        for index in loose.indices { strip(&loose[index].blocks) }
        loose.removeAll { $0.blocks.isEmpty }
        return removed
    }

    /// Moves `ids` to `index` in `ref`. The index is the one the insertion
    /// line showed — counted before anything was taken out — so moving a
    /// block down its own stack lands where it was dropped.
    mutating func move(_ ids: [UUID], to ref: StackRef, at index: Int, registry: BlockRegistry) {
        let moving = Set(ids)
        // A container cannot go inside itself.
        if case .slot(let owner, _) = ref, isInside(owner, anyOf: moving) { return }
        var target = index
        if let stack = stack(ref) {
            target -= stack.prefix(index).filter { moving.contains($0.id) }.count
        }
        let blocks = remove(moving)
        // The loose stack the blocks came from may have gone with them.
        if case .loose(let id) = ref, !loose.contains(where: { $0.id == id }) {
            addLoose(blocks, at: .zero, registry: registry)
            return
        }
        insert(blocks, into: ref, at: target, registry: registry)
    }

    /// Whether the block `id` is one of `ancestors` or sits inside one.
    func isInside(_ id: UUID, anyOf ancestors: Set<UUID>) -> Bool {
        if ancestors.contains(id) { return true }
        for ancestor in ancestors {
            guard let block = block(ancestor) else { continue }
            if Block.flatten(block.children.flatMap { $0 }).contains(where: { $0.id == id }) { return true }
        }
        return false
    }

    /// The block `id` and every block after it in its stack — what ⇧-drag
    /// picks up.
    func blockAndFollowing(_ id: UUID) -> [UUID] {
        guard let (ref, index) = location(of: id), let stack = stack(ref) else { return [id] }
        return stack[index...].map(\.id)
    }

    // MARK: Binding new blocks

    /// Binds a new block's empty file input to the latest files before it,
    /// and a code block's input likewise. Drop "Zip" under "A file lands in
    /// a folder" and it zips what landed, with nothing to wire.
    mutating func bindNaturally(_ id: UUID, registry: BlockRegistry) {
        guard let block = block(id) else { return }
        let definition = registry.definition(block.definition)
        let context = FlowCheck.context(for: self, registry: registry)
        let available = FlowCheck.available(at: id, in: body + loose.flatMap(\.blocks), context: context)
        guard let latestFiles = available.last(where: { $0.type == .files }) else { return }
        update(id) { block in
            for port in definition.inputs where block.inputs[port.name] == nil {
                if port.type == .files || (port.name == "input" && definition.category == .code)
                    || (port.name == "items" && port.type == .any) {
                    block.inputs[port.name] = latestFiles.binding
                    return
                }
            }
        }
    }

    // MARK: Clean-up

    /// Bindings that read a block no longer in the flow, cleared — what
    /// deleting a block leaves behind otherwise is a red slot with no story.
    mutating func dropBindings(to removed: Set<UUID>) {
        func clean(_ stack: inout [Block]) {
            for index in stack.indices {
                stack[index].inputs = stack[index].inputs.filter { !$0.value.sources.contains(where: removed.contains) }
                for slot in stack[index].children.indices { clean(&stack[index].children[slot]) }
            }
        }
        clean(&body)
        for index in loose.indices { clean(&loose[index].blocks) }
    }
}

extension FlowCheck {
    /// The sentence a flow reads as in the library: "When a file lands in
    /// Downloads", "At 08:30 on weekdays", "When I run it".
    static func sentence(for flow: Flow, registry: BlockRegistry) -> String {
        guard !flow.triggers.isEmpty else { return "When I run it" }
        return flow.triggers.map { phrase(for: $0, registry: registry) }.joined(separator: ", or ")
    }

    /// A block's phrase with its typed inputs written in.
    static func phrase(for block: Block, registry: BlockRegistry) -> String {
        let definition = registry.definition(block.definition)
        return definition.phraseParts.map { part -> String in
            switch part {
            case .words(let words): return words
            case .input(let name):
                guard let port = definition.input(name) else { return name }
                return InputText.summary(block.inputs[name], port: port)
            }
        }.joined(separator: " ")
    }
}

/// An input as it reads on a block's face.
enum InputText {
    static func summary(_ source: ValueSource?, port: Port) -> String {
        switch source ?? .literal(port.defaultValue) {
        case .literal(let value): return literal(value, port: port)
        case .output(_, let name): return name
        case .trigger(let name): return name
        case .variable(let name): return name
        case .template(let parts):
            return parts.map { part in
                switch part {
                case .text(let text): return text
                case .value(let inner): return "{\(summary(inner, port: Port("", nil, .text)))}"
                }
            }.joined()
        }
    }

    static func literal(_ value: Value, port: Port) -> String {
        switch port.control {
        case .folder, .file:
            let path = value.coerced(to: .text)?.text ?? ""
            return path.isEmpty ? port.label.lowercased() : (path as NSString).lastPathComponent
        case .app:
            let id = value.text ?? ""
            return id.isEmpty ? "an app" : Apps.name(id)
        case .gruppe, .workspace:
            let raw = value.text ?? ""
            return raw.isEmpty ? (port.control == .gruppe ? "a Gruppe" : "a workspace") : Pick.split(raw).1
        case .hotkey:
            return HotkeyValue.shortcut(value.text ?? "")?.display ?? "keys"
        case .time:
            return Schedule.time(Int(value.number ?? 0))
        case .weekdays:
            return Schedule.summary(Schedule.days(value.text ?? ""))
        case .code:
            let lines = (value.text ?? "").split(whereSeparator: \.isNewline).count
            return lines == 1 ? "1 line" : "\(lines) lines"
        case .secret:
            return value.text.map { $0.isEmpty ? "a secret" : "🔒 \($0)" } ?? "a secret"
        case .toggle:
            return value.flag == true ? "yes" : "no"
        default:
            let text = value.coerced(to: .text)?.text ?? ""
            if text.isEmpty { return port.label.lowercased() }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.count > 28 ? String(line.prefix(27)) + "…" : line
        }
    }
}
