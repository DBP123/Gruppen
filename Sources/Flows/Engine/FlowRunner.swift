import Foundation

/// Something that happened during a run, in order. The canvas lights blocks
/// from these, the console prints them, and the saved run is built from them.
enum RunEvent: Sendable {
    case started(UUID)
    case finished(UUID, outputs: [String: Value], message: String)
    case failed(UUID, message: String)
    /// Disabled, so passed over.
    case skipped(UUID)
    case log(UUID, line: String, isError: Bool)
    /// Held at a breakpoint, or stepping.
    case paused(UUID)
    case resumed
}

/// How a run ended.
enum RunOutcome: String, Codable, Sendable {
    case succeeded, failed, stopped, interrupted
}

/// What runs code blocks. A protocol so the runner can be tested without
/// spawning interpreters.
protocol CodeExecuting: Sendable {
    func run(_ spec: CodeSpec, inputs: [String: Value], definition: BlockDefinition,
             context: RunContext, log: @escaping @Sendable (String, Bool) -> Void) async throws -> [String: Value]
}

/// Interprets a flow's blocks, top to bottom.
///
/// Holds no state between runs and owns no thread: each run is the caller's
/// task, and everything it remembers lives in a `RunMemory` that dies with
/// it. Cancelling the task stops the run at the next block, and a code block
/// in flight is killed by its own cancellation handler.
struct FlowRunner: Sendable {
    let registry: BlockRegistry
    let hooks: FlowHooks
    let code: CodeExecuting
    let events: @Sendable (RunEvent) -> Void
    /// Breakpoints and stepping; nil when nobody is watching the run.
    let debugger: RunDebugger?

    /// Runs `flow`'s body with `trigger` as what started it. Throws the
    /// failure that stopped it; returns what Stop said, if it stopped early.
    @discardableResult
    func run(_ flow: Flow, trigger: [String: Value], context: RunContext) async throws -> String? {
        let memory = RunMemory(trigger: trigger)
        let work = { () async throws -> String? in
            do {
                try await self.execute(flow.body, memory: memory, context: context)
                return nil
            } catch let stop as StopSignal {
                if stop.failed { throw FlowError.stopped(stop.message) }
                return stop.message
            }
        }
        guard let deadline = context.deadline else { return try await work() }
        let limit = max(0, deadline.timeIntervalSinceNow)
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                throw FlowError.timedOut(Int(limit.rounded()))
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    // MARK: Stacks and blocks

    func execute(_ stack: [Block], memory: RunMemory, context: RunContext) async throws {
        for block in stack { try await execute(block, memory: memory, context: context) }
    }

    private func execute(_ block: Block, memory: RunMemory, context: RunContext) async throws {
        if Task.isCancelled { throw FlowError.cancelled }
        guard !block.isDisabled else { events(.skipped(block.id)); return }
        if let debugger, await debugger.shouldPause(at: block) {
            events(.paused(block.id))
            try await debugger.wait()
            events(.resumed)
        }
        let definition = registry.definition(block.definition)
        events(.started(block.id))

        if case .control(let kind) = definition.implementation {
            do {
                let message = try await control(kind, block, definition, memory: memory, context: context)
                events(.finished(block.id, outputs: [:], message: message))
            } catch let error as StopSignal {
                events(.finished(block.id, outputs: [:], message: error.message.isEmpty ? "Stopped" : error.message))
                throw error
            } catch {
                events(.failed(block.id, message: error.localizedDescription))
                throw error
            }
            return
        }

        var attempt = 0
        while true {
            do {
                let outputs = try await perform(block, definition, memory: memory, context: context)
                memory.set(outputs, for: block.id)
                events(.finished(block.id, outputs: outputs, message: Self.message(for: outputs)))
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw FlowError.cancelled }
                if case .retry(let times) = block.onFailure, attempt < times {
                    events(.log(block.id, line: "Failed: \(error.localizedDescription). Trying again…", isError: true))
                    try await Task.sleep(nanoseconds: UInt64(1 << min(attempt, 5)) * 1_000_000_000)
                    attempt += 1
                    continue
                }
                events(.failed(block.id, message: error.localizedDescription))
                if case .continue = block.onFailure { return }
                throw BlockFailure(block: block.id, underlying: error)
            }
        }
    }

    /// One block that does something, its inputs read and converted.
    private func perform(_ block: Block, _ definition: BlockDefinition,
                         memory: RunMemory, context: RunContext) async throws -> [String: Value] {
        let inputs = try readInputs(block, definition, memory: memory)
        let log: @Sendable (String, Bool) -> Void = { [events] line, isError in
            events(.log(block.id, line: line, isError: isError))
        }
        switch definition.implementation {
        case .builtIn(let body):
            return try await body(BlockContext(block: block.id, inputs: inputs, hooks: hooks, run: context,
                                               log: { log($0, false) }))
        case .code(let spec):
            return try await code.run(spec, inputs: inputs, definition: definition, context: context, log: log)
        case .inlineCode(let language):
            let packages = (inputs["packages"]?.text ?? "").split(whereSeparator: { $0.isNewline || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let spec = CodeSpec(language, source: inputs["code"]?.text ?? "", packages: packages,
                                interpreter: (inputs["interpreter"]?.text).flatMap { $0.isEmpty ? nil : $0 })
            return try await code.run(spec, inputs: ["input": inputs["input"] ?? .nothing],
                                      definition: definition, context: context, log: log)
        case .blocks(let stack, let results):
            // Its own memory: the same packaged block used twice, or in two
            // lanes at once, must not read the other's values.
            let inner = RunMemory(trigger: inputs)
            try await execute(stack, memory: inner, context: context)
            return results.reduce(into: [:]) { outputs, entry in
                let value = inner.resolve(entry.value)
                if let type = definition.output(entry.key)?.type, let typed = value.coerced(to: type) {
                    outputs[entry.key] = typed
                } else {
                    outputs[entry.key] = value
                }
            }
        case .trigger:
            // A hat dropped into the body does nothing; it is not an error to
            // have left it there.
            return [:]
        case .missing:
            throw FlowError.missingBlock(definition.id)
        case .control:
            preconditionFailure("handled by execute")
        }
    }

    /// Each input bound or defaulted, then converted to its port's type.
    func readInputs(_ block: Block, _ definition: BlockDefinition, memory: RunMemory) throws -> [String: Value] {
        var inputs: [String: Value] = [:]
        for port in definition.inputs {
            var value = block.inputs[port.name].map(memory.resolve) ?? port.defaultValue
            if value.isNothing { value = port.defaultValue }
            // A secret input names a Keychain item; the block gets its value.
            if port.control == .secret, let name = value.text, !name.isEmpty {
                value = .text(Secrets.value(name) ?? "")
            }
            guard let typed = value.coerced(to: port.type) else {
                throw FlowError.wrongType(port: port.label, expected: port.type, got: value.summary)
            }
            inputs[port.name] = typed
        }
        return inputs
    }

    private static func message(for outputs: [String: Value]) -> String {
        if let said = outputs["message"]?.text { return said }
        guard let first = outputs.sorted(by: { $0.key < $1.key }).first else { return "Done" }
        return first.value.summary
    }

    // MARK: Control

    private func control(_ kind: ControlKind, _ block: Block, _ definition: BlockDefinition,
                         memory: RunMemory, context: RunContext) async throws -> String {
        let inputs = try readInputs(block, definition, memory: memory)
        func slot(_ index: Int) -> [Block] { index < block.children.count ? block.children[index] : [] }

        switch kind {
        case .ifElse:
            let holds = Condition.holds(inputs["value"] ?? .nothing,
                                        Condition.Test(label: inputs["test"]?.text ?? ""),
                                        inputs["other"] ?? .nothing)
            try await execute(slot(holds ? 0 : 1), memory: memory, context: context)
            return holds ? "Yes" : "No"

        case .forEach:
            let items = Self.items(of: inputs["items"] ?? .nothing)
            for (index, item) in items.enumerated() {
                if Task.isCancelled { throw FlowError.cancelled }
                memory.set(["item": item, "index": .number(Double(index + 1))], for: block.id)
                try await execute(slot(0), memory: memory, context: context)
            }
            return items.count == 1 ? "1 time" : "\(items.count) times"

        case .repeatTimes:
            let times = max(0, Int(inputs["times"]?.number ?? 0))
            for index in 0..<times {
                if Task.isCancelled { throw FlowError.cancelled }
                memory.set(["index": .number(Double(index + 1))], for: block.id)
                try await execute(slot(0), memory: memory, context: context)
            }
            return times == 1 ? "1 time" : "\(times) times"

        case .parallel:
            try await withThrowingTaskGroup(of: Void.self) { group in
                for lane in block.children {
                    group.addTask { try await self.execute(lane, memory: memory, context: context) }
                }
                // The first lane to fail stops the others.
                defer { group.cancelAll() }
                try await group.waitForAll()
            }
            return "\(block.children.count) lanes"

        case .setVariable:
            let name = (inputs["name"]?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw FlowError.notSetUp("The variable has no name") }
            let value = inputs["value"] ?? .nothing
            memory.setVariable(name, value)
            return "\(name) = \(value.summary)"

        case .stop:
            throw StopSignal(failed: inputs["outcome"]?.text == Catalog.stopAsFailure,
                             message: inputs["message"]?.text ?? "")
        }
    }

    /// What For each walks: a list's items, each file on its own, each line
    /// of text.
    static func items(of value: Value) -> [Value] {
        switch value {
        case .nothing: return []
        case .list(let items): return items
        case .files(let urls): return urls.map { .files([$0]) }
        case .text(let text): return text.split(whereSeparator: \.isNewline).map { .text(String($0)) }
        case .record(let fields): return fields.keys.sorted().map { .record(["key": .text($0), "value": fields[$0]!]) }
        default: return [value]
        }
    }
}

/// Thrown by Stop.
struct StopSignal: Error, Sendable {
    let failed: Bool
    let message: String
}

/// A block failed and its policy was to stop: which one, and why.
struct BlockFailure: LocalizedError, Sendable {
    let block: UUID
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

// MARK: - Memory

/// Everything one run remembers: each block's outputs, the variables, and
/// what started it. Lanes of Run together write to it at once, so every
/// access is behind the lock.
final class RunMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [UUID: [String: Value]] = [:]
    private var variables: [String: Value] = [:]
    let trigger: [String: Value]

    init(trigger: [String: Value]) { self.trigger = trigger }

    func set(_ values: [String: Value], for block: UUID) {
        lock.lock(); outputs[block] = values; lock.unlock()
    }

    func setVariable(_ name: String, _ value: Value) {
        lock.lock(); variables[name] = value; lock.unlock()
    }

    func output(_ block: UUID, _ port: String) -> Value {
        lock.lock(); defer { lock.unlock() }
        return outputs[block]?[port] ?? .nothing
    }

    func variable(_ name: String) -> Value {
        lock.lock(); defer { lock.unlock() }
        return variables[name] ?? .nothing
    }

    func resolve(_ binding: ValueSource) -> Value {
        switch binding {
        case .literal(let value): return value
        case .output(let block, let port): return output(block, port)
        case .trigger(let port): return trigger[port] ?? .nothing
        case .variable(let name): return variable(name)
        case .template(let parts):
            return .text(parts.map { part -> String in
                switch part {
                case .text(let text): return text
                case .value(let inner): return Self.inline(resolve(inner))
                }
            }.joined())
        }
    }

    /// A value as it reads inside text: a file by its name, a list joined
    /// with commas — "Report 2026-10-30 Lab.pdf", not a path.
    static func inline(_ value: Value) -> String {
        switch value {
        case .files(let urls): return urls.map(\.lastPathComponent).joined(separator: ", ")
        case .list(let items): return items.map(inline).joined(separator: ", ")
        case .record: return value.jsonText()
        default: return value.coerced(to: .text)?.text ?? ""
        }
    }
}

// MARK: - Conditions

/// What If tests.
enum Condition {
    enum Test: String, CaseIterable, Sendable {
        case equals = "is"
        case differs = "is not"
        case contains = "contains"
        case startsWith = "starts with"
        case endsWith = "ends with"
        case matches = "matches pattern"
        case isEmpty = "is empty"
        case isNotEmpty = "is not empty"
        case greater = "is more than"
        case less = "is less than"
        case exists = "exists"
        case isYes = "is yes"

        init(label: String) { self = Test(rawValue: label) ?? .isYes }

        /// Whether the test compares against a second value.
        var takesOther: Bool { ![.isEmpty, .isNotEmpty, .exists, .isYes].contains(self) }
    }

    static func holds(_ value: Value, _ test: Test, _ other: Value) -> Bool {
        let text = MemoryText.of(value)
        let otherText = MemoryText.of(other)
        switch test {
        case .equals: return text.caseInsensitiveCompare(otherText) == .orderedSame
        case .differs: return text.caseInsensitiveCompare(otherText) != .orderedSame
        case .contains: return text.localizedCaseInsensitiveContains(otherText)
        case .startsWith: return text.lowercased().hasPrefix(otherText.lowercased())
        case .endsWith: return text.lowercased().hasSuffix(otherText.lowercased())
        case .matches:
            return (try? NSRegularExpression(pattern: otherText, options: [.caseInsensitive]))
                .map { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil } ?? false
        case .isEmpty: return isEmpty(value)
        case .isNotEmpty: return !isEmpty(value)
        case .greater, .less:
            guard let a = value.coerced(to: .number)?.number, let b = other.coerced(to: .number)?.number else { return false }
            return test == .greater ? a > b : a < b
        case .exists:
            let paths = value.urls ?? (value.text.map { [URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)] } ?? [])
            return !paths.isEmpty && paths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        case .isYes: return value.coerced(to: .bool)?.flag ?? false
        }
    }

    private static func isEmpty(_ value: Value) -> Bool {
        switch value {
        case .nothing: return true
        case .text(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .files(let urls): return urls.isEmpty
        case .list(let items): return items.isEmpty
        case .record(let fields): return fields.isEmpty
        default: return false
        }
    }
}

/// A value as If compares it: files by name, so "name ends with .pdf" reads
/// the way it is written.
private enum MemoryText {
    static func of(_ value: Value) -> String {
        if case .files(let urls) = value, urls.count == 1 { return urls[0].lastPathComponent }
        return RunMemory.inline(value)
    }
}

// MARK: - Debugging

/// Breakpoints and stepping for one run.
actor RunDebugger {
    private var stepping = false
    private var waiting: CheckedContinuation<Void, Error>?
    private var stopped = false

    func shouldPause(at block: Block) -> Bool { block.hasBreakpoint || stepping }

    func wait() async throws {
        if stopped { throw FlowError.cancelled }
        try await withCheckedThrowingContinuation { waiting = $0 }
    }

    /// Carries on to the next breakpoint.
    func resume() { stepping = false; release() }

    /// Runs one block and pauses again.
    func step() { stepping = true; release() }

    func stop() {
        stopped = true
        waiting?.resume(throwing: FlowError.cancelled)
        waiting = nil
    }

    private func release() {
        waiting?.resume()
        waiting = nil
    }
}
