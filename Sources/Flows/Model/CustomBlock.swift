import Foundation

/// A block you made: your code, or a stack of blocks packaged as one, with
/// named inputs and outputs. Once saved it sits in the palette under My
/// blocks and is dragged in like any built-in.
struct CustomBlock: Identifiable, Codable, Hashable, Sendable {
    enum Body: Hashable, Sendable {
        case code(CodeSpec)
        case blocks([Block])
    }

    var id: UUID
    /// Bumped on every save that changes the ports, so a flow written against
    /// an older shape can say what moved.
    var version: Int
    var title: String
    var glyph: String
    var help: String
    var phrase: String
    var inputs: [Port]
    var outputs: [Port]
    var body: Body
    /// Packaged blocks only: which value inside the stack each output is.
    var results: [String: ValueSource]
    var permissions: [Permission]

    init(id: UUID = UUID(), title: String = "My block", glyph: String = "cube", help: String = "",
         phrase: String = "", inputs: [Port] = [], outputs: [Port] = [],
         body: Body = .code(CodeSpec(.python)), results: [String: ValueSource] = [:],
         permissions: [Permission] = []) {
        self.id = id
        self.version = 1
        self.title = title
        self.glyph = glyph
        self.help = help
        self.phrase = phrase
        self.inputs = inputs
        self.outputs = outputs
        self.body = body
        self.results = results
        self.permissions = permissions
    }

    var definitionID: String { Self.definitionID(id) }
    static func definitionID(_ id: UUID) -> String { "custom.\(id.uuidString)" }

    var definition: BlockDefinition {
        let implementation: Implementation
        switch body {
        case .code(let spec): implementation = .code(spec)
        case .blocks(let stack): implementation = .blocks(stack, results: results)
        }
        return BlockDefinition(definitionID, title, category: .custom, glyph: glyph,
                               phrase: phrase.isEmpty ? title : phrase, help: help,
                               inputs: inputs, outputs: outputs, permissions: permissions,
                               implementation)
    }

    var isCode: Bool { if case .code = body { return true }; return false }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? "My block"
        glyph = try box.decodeIfPresent(String.self, forKey: .glyph) ?? "cube"
        help = try box.decodeIfPresent(String.self, forKey: .help) ?? ""
        phrase = try box.decodeIfPresent(String.self, forKey: .phrase) ?? ""
        inputs = try box.decodeIfPresent([Port].self, forKey: .inputs) ?? []
        outputs = try box.decodeIfPresent([Port].self, forKey: .outputs) ?? []
        permissions = (try? box.decodeIfPresent([Permission].self, forKey: .permissions)) ?? []
        results = (try? box.decodeIfPresent([String: ValueSource].self, forKey: .results)) ?? [:]
        if let stack = try box.decodeIfPresent([Block].self, forKey: .blocks) {
            body = .blocks(stack)
        } else {
            body = .code(try box.decodeIfPresent(CodeSpec.self, forKey: .code) ?? CodeSpec(.python))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(version, forKey: .version)
        try box.encode(title, forKey: .title)
        try box.encode(glyph, forKey: .glyph)
        try box.encode(help, forKey: .help)
        try box.encode(phrase, forKey: .phrase)
        try box.encode(inputs, forKey: .inputs)
        try box.encode(outputs, forKey: .outputs)
        try box.encode(permissions, forKey: .permissions)
        try box.encode(results, forKey: .results)
        switch body {
        case .code(let spec): try box.encode(spec, forKey: .code)
        case .blocks(let stack): try box.encode(stack, forKey: .blocks)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, title, glyph, help, phrase, inputs, outputs, permissions, results, code, blocks
    }
}

// MARK: - Packaging

extension CustomBlock {
    /// Turns `selection` — consecutive blocks of one stack — into a block of
    /// its own, and says how to call it from where the selection was.
    ///
    /// Every binding that reaches outside the selection becomes an input:
    /// the trigger's files, an earlier block's output, a variable. Inside the
    /// new block those read the block's own inputs; at the call site the new
    /// block is bound to exactly what the selection used to read. Outputs of
    /// the selection that later blocks read become its outputs, and
    /// `readers` says what those later bindings must now read instead.
    static func package(_ selection: [Block], title: String, readBy later: [Block],
                        registry: BlockRegistry) -> (block: CustomBlock, call: Block, readers: [ValueSource: ValueSource]) {
        let inside = Set(Block.flatten(selection).map(\.id))
        var inputs: [Port] = []
        var callInputs: [String: ValueSource] = [:]
        var renamedInputs: [ValueSource: String] = [:]

        func portName(for binding: ValueSource, type: ValueType) -> String {
            if let name = renamedInputs[binding] { return name }
            let base: String
            switch binding {
            case .trigger(let port): base = port
            case .variable(let name): base = name
            case .output(_, let port): base = port
            default: base = "input"
            }
            var name = base
            var counter = 2
            while inputs.contains(where: { $0.name == name }) { name = "\(base)\(counter)"; counter += 1 }
            inputs.append(Port(name, nil, type))
            callInputs[name] = binding
            renamedInputs[binding] = name
            return name
        }

        func reaches(_ binding: ValueSource) -> Bool {
            switch binding {
            case .output(let block, _): return !inside.contains(block)
            case .trigger, .variable: return true
            default: return false
            }
        }

        func rewrite(_ binding: ValueSource, type: ValueType) -> ValueSource {
            switch binding {
            case .template(let parts):
                return .template(parts.map { part in
                    if case .value(let inner) = part { return .value(rewrite(inner, type: .text)) }
                    return part
                })
            default:
                return reaches(binding) ? .trigger(port: portName(for: binding, type: type)) : binding
            }
        }

        func rewrite(_ block: Block) -> Block {
            var next = block
            let definition = registry.definition(block.definition)
            next.inputs = block.inputs.reduce(into: [:]) { result, entry in
                result[entry.key] = rewrite(entry.value, type: definition.input(entry.key)?.type ?? .any)
            }
            next.children = block.children.map { $0.map(rewrite) }
            return next
        }

        let stack = selection.map(rewrite)

        // Outputs: whatever after the selection still reads from inside it,
        // each under a name of its own — two inner "files" become "files"
        // and "files2".
        let call = Block(CustomBlock.definitionID(UUID()), inputs: callInputs)
        var outputs: [Port] = []
        var results: [String: ValueSource] = [:]
        var readers: [ValueSource: ValueSource] = [:]
        for reader in Block.flatten(later) {
            for binding in reader.inputs.values.flatMap(\.allReads) {
                guard case .output(let source, let port) = binding, inside.contains(source),
                      readers[binding] == nil else { continue }
                let type = Block.flatten(selection).first { $0.id == source }
                    .flatMap { registry.definition($0.definition).output(port)?.type } ?? .any
                var name = port
                var counter = 2
                while outputs.contains(where: { $0.name == name }) { name = "\(port)\(counter)"; counter += 1 }
                outputs.append(Port(name, nil, type))
                results[name] = binding
                readers[binding] = .output(block: call.id, port: name)
            }
        }

        var custom = CustomBlock(title: title, glyph: "shippingbox", inputs: inputs, outputs: outputs,
                                 body: .blocks(stack), results: results)
        custom.id = UUID(uuidString: String(call.definition.dropFirst("custom.".count))) ?? custom.id
        return (custom, call, readers)
    }
}

// MARK: - Registry

/// Every definition a flow can name: the built-ins and your blocks. Asked for
/// one it does not have, it answers with a placeholder rather than nil, so a
/// deleted block shows as "Missing" in place — inputs kept — instead of
/// vanishing from the flows that used it.
struct BlockRegistry: Sendable {
    private let byID: [String: BlockDefinition]
    let custom: [CustomBlock]

    init(custom: [CustomBlock] = []) {
        self.custom = custom
        var all: [String: BlockDefinition] = [:]
        for definition in Catalog.all { all[definition.id] = definition }
        for block in custom { all[block.definitionID] = block.definition }
        byID = all
    }

    func definition(_ id: String) -> BlockDefinition {
        byID[id] ?? BlockDefinition(id, "Missing block", category: .custom, glyph: "questionmark.square.dashed",
                                    help: "This block was deleted, or comes from a newer Gruppen", .missing)
    }

    func has(_ id: String) -> Bool { byID[id] != nil }

    /// Every custom block `stack` uses, packaged blocks' insides included —
    /// what an exported flow has to carry with it.
    func customBlocks(usedBy stack: [Block]) -> [CustomBlock] {
        var seen: Set<UUID> = []
        var found: [CustomBlock] = []
        func visit(_ blocks: [Block]) {
            for block in Block.flatten(blocks) {
                guard let custom = custom.first(where: { $0.definitionID == block.definition }),
                      seen.insert(custom.id).inserted else { continue }
                found.append(custom)
                if case .blocks(let inner) = custom.body { visit(inner) }
            }
        }
        visit(stack)
        return found
    }
}
