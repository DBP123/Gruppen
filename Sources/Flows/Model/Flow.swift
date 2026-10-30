import CoreGraphics
import Foundation

/// A flow: a small program of blocks. Hat blocks say when it runs; the body
/// does things, top to bottom; containers hold stacks of their own.
///
/// The block view and the graph view both draw this one value. A wire in the
/// graph *is* a `ValueSource` on a block, so the two can never disagree.
struct Flow: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var glyph: String
    var isEnabled: Bool
    /// Any one of these starts the flow. Empty means it runs only by hand.
    var triggers: [Block]
    var body: [Block]
    /// Stacks left on the canvas unattached — dimmed, never run. Room to try
    /// something without breaking what works.
    var loose: [LooseStack]
    var policy: FlowPolicy
    /// Listed in the menu bar dropdown with a run key.
    var pinned: Bool
    /// Extra environment for this flow's code blocks. Secrets are not here:
    /// they are named in `secrets` and read from the Keychain at run time.
    var environment: [String: String]
    var secrets: [String]

    init(id: UUID = UUID(), name: String = "New flow", glyph: String = "point.3.connected.trianglepath.dotted",
         isEnabled: Bool = false, triggers: [Block] = [], body: [Block] = [], loose: [LooseStack] = [],
         policy: FlowPolicy = FlowPolicy(), pinned: Bool = false,
         environment: [String: String] = [:], secrets: [String] = []) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.isEnabled = isEnabled
        self.triggers = triggers
        self.body = body
        self.loose = loose
        self.policy = policy
        self.pinned = pinned
        self.environment = environment
        self.secrets = secrets
    }

    /// Field by field: a key this build has never seen, or one an older build
    /// never wrote, costs that field and not the flow.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? "Untitled flow"
        glyph = try box.decodeIfPresent(String.self, forKey: .glyph) ?? "point.3.connected.trianglepath.dotted"
        isEnabled = try box.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        triggers = try box.decodeIfPresent([Block].self, forKey: .triggers) ?? []
        body = try box.decodeIfPresent([Block].self, forKey: .body) ?? []
        loose = try box.decodeIfPresent([LooseStack].self, forKey: .loose) ?? []
        policy = (try? box.decodeIfPresent(FlowPolicy.self, forKey: .policy)) ?? FlowPolicy()
        pinned = try box.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        environment = try box.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        secrets = try box.decodeIfPresent([String].self, forKey: .secrets) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, glyph, isEnabled, triggers, body, loose, policy, pinned, environment, secrets
    }

    /// Every block in the body, depth first, with containers before their
    /// contents. Triggers and loose stacks are not part of the program.
    var allBodyBlocks: [Block] { Block.flatten(body) }

    /// The block with `id`, wherever it sits — trigger, body or loose.
    func block(_ id: UUID) -> Block? {
        Block.flatten(triggers + body + loose.flatMap(\.blocks)).first { $0.id == id }
    }
}

/// A stack sitting on its own on the canvas.
struct LooseStack: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var position: CGPoint
    var blocks: [Block]
}

/// How a flow behaves as a whole.
struct FlowPolicy: Codable, Hashable, Sendable {
    /// What a trigger firing while a run is still going does.
    enum Concurrency: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Waits its turn — nothing is dropped.
        case queue
        /// Ignored; the run in progress carries on alone.
        case skip
        /// Runs alongside.
        case parallel
        /// Stops the run in progress and starts again.
        case restart
        var id: String { rawValue }
        var label: String {
            switch self {
            case .queue: return "Wait its turn"
            case .skip: return "Skip if running"
            case .parallel: return "Run alongside"
            case .restart: return "Restart"
            }
        }
    }

    enum Notify: String, Codable, CaseIterable, Sendable, Identifiable {
        case never, onFailure, always
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: return "Never"
            case .onFailure: return "When it fails"
            case .always: return "Every run"
            }
        }
    }

    var concurrency: Concurrency = .queue
    /// Seconds a run may take before it is stopped. Zero means no limit.
    var timeout: Int = 60
    var notify: Notify = .onFailure

    init() {}

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        concurrency = (try? box.decodeIfPresent(Concurrency.self, forKey: .concurrency)) ?? .queue
        timeout = try box.decodeIfPresent(Int.self, forKey: .timeout) ?? 60
        notify = (try? box.decodeIfPresent(Notify.self, forKey: .notify)) ?? .onFailure
    }

    private enum CodingKeys: String, CodingKey { case concurrency, timeout, notify }
}

// MARK: - Block

/// One placed block: which definition it is, what its inputs are bound to,
/// and, for containers, the stacks inside it.
struct Block: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// A built-in id such as `files.move`, or `custom.<uuid>` for a block you
    /// made.
    var definition: String
    var inputs: [String: ValueSource]
    /// One stack per slot: If's then and else, a loop's body, the lanes of
    /// Run together.
    var children: [[Block]]
    var isDisabled: Bool
    var hasBreakpoint: Bool
    var onFailure: FailurePolicy
    var note: String
    /// Where it sits in the graph view. Nil is laid out automatically.
    var position: CGPoint?
    /// Hats only: what a test run pretends the trigger handed over.
    var sample: [String: Value]

    init(id: UUID = UUID(), _ definition: String, inputs: [String: ValueSource] = [:], children: [[Block]] = [],
         isDisabled: Bool = false, hasBreakpoint: Bool = false, onFailure: FailurePolicy = .stop,
         note: String = "", position: CGPoint? = nil, sample: [String: Value] = [:]) {
        self.id = id
        self.definition = definition
        self.inputs = inputs
        self.children = children
        self.isDisabled = isDisabled
        self.hasBreakpoint = hasBreakpoint
        self.onFailure = onFailure
        self.note = note
        self.position = position
        self.sample = sample
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        definition = try box.decodeIfPresent(String.self, forKey: .definition) ?? "missing"
        // A binding this build cannot read is dropped, not the block: the input
        // falls back to its default and the flow says it needs a look.
        inputs = (try? box.decodeIfPresent([String: ValueSource].self, forKey: .inputs)) ?? [:]
        children = try box.decodeIfPresent([[Block]].self, forKey: .children) ?? []
        isDisabled = try box.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        hasBreakpoint = try box.decodeIfPresent(Bool.self, forKey: .hasBreakpoint) ?? false
        onFailure = (try? box.decodeIfPresent(FailurePolicy.self, forKey: .onFailure)) ?? .stop
        note = try box.decodeIfPresent(String.self, forKey: .note) ?? ""
        position = try box.decodeIfPresent(CGPoint.self, forKey: .position)
        sample = (try? box.decodeIfPresent([String: Value].self, forKey: .sample)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id, definition, inputs, children, isDisabled, hasBreakpoint, onFailure, note, position, sample
    }

    static func flatten(_ stack: [Block]) -> [Block] {
        stack.flatMap { [$0] + $0.children.flatMap(flatten) }
    }

    /// A copy with fresh ids throughout, and every binding between the copied
    /// blocks pointed at the copies — what paste and duplicate need.
    static func copies(of stack: [Block]) -> [Block] {
        var renamed: [UUID: UUID] = [:]
        for block in flatten(stack) { renamed[block.id] = UUID() }
        func copy(_ block: Block) -> Block {
            var next = block
            next.id = renamed[block.id] ?? UUID()
            next.inputs = block.inputs.mapValues { $0.repointed(renamed) }
            next.children = block.children.map { $0.map(copy) }
            next.position = block.position.map { CGPoint(x: $0.x + 24, y: $0.y + 24) }
            return next
        }
        return stack.map(copy)
    }
}

/// What a failing block does to the run.
enum FailurePolicy: Codable, Hashable, Sendable {
    case stop
    /// Carry on; the block's outputs are nothing.
    case `continue`
    /// Try again up to this many more times, waiting 1, 2, 4… seconds.
    case retry(Int)

    var label: String {
        switch self {
        case .stop: return "Stop the flow"
        case .continue: return "Carry on"
        case .retry(let times): return "Retry \(times)×"
        }
    }

    private enum CodingKeys: String, CodingKey { case policy, times }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decodeIfPresent(String.self, forKey: .policy) {
        case "continue": self = .continue
        case "retry": self = .retry(max(1, try box.decodeIfPresent(Int.self, forKey: .times) ?? 1))
        default: self = .stop
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stop: try box.encode("stop", forKey: .policy)
        case .continue: try box.encode("continue", forKey: .policy)
        case .retry(let times):
            try box.encode("retry", forKey: .policy)
            try box.encode(times, forKey: .times)
        }
    }
}

// MARK: - ValueSource

/// Where an input's value comes from.
indirect enum ValueSource: Hashable, Sendable {
    /// Typed on the block.
    case literal(Value)
    /// An output of a block that ran earlier.
    case output(block: UUID, port: String)
    /// What the trigger that started this run handed over — whichever hat it
    /// was. Inside a block you made, the block's own inputs.
    case trigger(port: String)
    /// A variable set with Set variable.
    case variable(String)
    /// Text with values dropped into it: "Report {date} {file.name}".
    case template([TextPart])

    /// The blocks this binding reads from.
    var sources: [UUID] {
        switch self {
        case .output(let block, _): return [block]
        case .template(let parts): return parts.flatMap { part -> [UUID] in
            if case .value(let binding) = part { return binding.sources }
            return []
        }
        default: return []
        }
    }

    var literal: Value? { if case .literal(let value) = self { return value }; return nil }

    /// This binding and every binding inside a template, flattened: each
    /// value it reads.
    var allReads: [ValueSource] {
        guard case .template(let parts) = self else { return [self] }
        return parts.flatMap { part -> [ValueSource] in
            if case .value(let binding) = part { return binding.allReads }
            return []
        }
    }

    /// The same binding with every read in `map` replaced, templates
    /// included.
    func replacing(_ map: [ValueSource: ValueSource]) -> ValueSource {
        if let replacement = map[self] { return replacement }
        guard case .template(let parts) = self else { return self }
        return .template(parts.map { part in
            if case .value(let binding) = part { return .value(binding.replacing(map)) }
            return part
        })
    }

    /// The same binding, with references to blocks in `renamed` pointed at
    /// their new ids.
    func repointed(_ renamed: [UUID: UUID]) -> ValueSource {
        switch self {
        case .output(let block, let port): return .output(block: renamed[block] ?? block, port: port)
        case .template(let parts):
            return .template(parts.map { part in
                if case .value(let binding) = part { return .value(binding.repointed(renamed)) }
                return part
            })
        default: return self
        }
    }
}

/// A piece of a template: words, or a value dropped in.
indirect enum TextPart: Hashable, Sendable {
    case text(String)
    case value(ValueSource)
}

extension ValueSource: Codable {
    private enum CodingKeys: String, CodingKey { case literal, block, port, trigger, variable, template }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try box.decodeIfPresent(Value.self, forKey: .literal) {
            self = .literal(value)
        } else if let block = try box.decodeIfPresent(UUID.self, forKey: .block) {
            self = .output(block: block, port: try box.decode(String.self, forKey: .port))
        } else if let port = try box.decodeIfPresent(String.self, forKey: .trigger) {
            self = .trigger(port: port)
        } else if let name = try box.decodeIfPresent(String.self, forKey: .variable) {
            self = .variable(name)
        } else if let parts = try box.decodeIfPresent([TextPart].self, forKey: .template) {
            self = .template(parts)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not a binding"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value): try box.encode(value, forKey: .literal)
        case .output(let block, let port):
            try box.encode(block, forKey: .block)
            try box.encode(port, forKey: .port)
        case .trigger(let port): try box.encode(port, forKey: .trigger)
        case .variable(let name): try box.encode(name, forKey: .variable)
        case .template(let parts): try box.encode(parts, forKey: .template)
        }
    }
}

extension TextPart: Codable {
    private enum CodingKeys: String, CodingKey { case text, value }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try box.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else {
            self = .value(try box.decode(ValueSource.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try box.encode(text, forKey: .text)
        case .value(let binding): try box.encode(binding, forKey: .value)
        }
    }
}
