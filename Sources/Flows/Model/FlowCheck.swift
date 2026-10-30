import Foundation

/// A value a block can be bound to at its place in the flow, as the pill
/// picker offers it.
struct AvailableValue: Hashable, Sendable, Identifiable {
    var binding: ValueSource
    /// "Files · A file lands in a folder", "zip · Zip".
    var label: String
    var source: String
    var type: ValueType
    var id: ValueSource { binding }
}

/// Something about a flow that needs a look.
struct FlowIssue: Hashable, Sendable, Identifiable {
    enum Severity: Int, Comparable, Sendable {
        /// Converted on the way and may fail — amber.
        case warning
        /// Cannot work — red, and the flow cannot be switched on.
        case error
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var block: UUID
    var port: String?
    var severity: Severity
    var message: String
    var id: String { "\(block)-\(port ?? "")-\(message)" }
}

/// What can be read where, and what is wrong — one walk over the program, so
/// the pill picker and the checks agree with the runner about scope.
///
/// **Scope.** A block may read the trigger, variables, and the outputs of
/// blocks that have certainly run before it: earlier blocks in its own stack
/// and in every stack around it. Inside a loop, the loop's item and index.
/// After Run together, the outputs of each lane's blocks, since every lane
/// runs. Never into If's branches or a loop's body from outside — those may
/// not have run.
enum FlowCheck {
    struct Context {
        let registry: BlockRegistry
        /// What `.trigger(port:)` offers: the hats' outputs, or a packaged
        /// block's own inputs.
        let triggerPorts: [Port]
        let triggerSource: String
        let variables: Set<String>
    }

    static func context(for flow: Flow, registry: BlockRegistry) -> Context {
        var ports: [Port] = []
        for hat in flow.triggers {
            for port in registry.definition(hat.definition).outputs where !ports.contains(where: { $0.name == port.name }) {
                ports.append(port)
            }
        }
        let names = flow.triggers.map { registry.definition($0.definition).title }
        return Context(registry: registry, triggerPorts: ports,
                       triggerSource: names.count == 1 ? names[0] : "Trigger",
                       variables: variables(in: flow.body))
    }

    static func context(forPackaged block: CustomBlock, registry: BlockRegistry) -> Context {
        guard case .blocks(let stack) = block.body else {
            return Context(registry: registry, triggerPorts: block.inputs, triggerSource: block.title, variables: [])
        }
        return Context(registry: registry, triggerPorts: block.inputs, triggerSource: block.title,
                       variables: variables(in: stack))
    }

    /// Every Set variable's name in `stack`.
    static func variables(in stack: [Block]) -> Set<String> {
        Set(Block.flatten(stack).filter { $0.definition == Catalog.setVariable }
            .compactMap { $0.inputs["name"]?.literal?.text?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    // MARK: Available values

    /// What the block `id` can be bound to.
    static func available(at id: UUID, in stack: [Block], context: Context) -> [AvailableValue] {
        var found: [AvailableValue]?
        walk(stack, inherited: base(context), context: context) { block, available in
            if block.id == id { found = available }
        }
        return found ?? base(context)
    }

    private static func base(_ context: Context) -> [AvailableValue] {
        context.triggerPorts.map {
            AvailableValue(binding: .trigger(port: $0.name), label: $0.label, source: context.triggerSource, type: $0.type)
        } + context.variables.sorted().map {
            AvailableValue(binding: .variable($0), label: $0, source: "Variable", type: .any)
        }
    }

    /// Visits each block in order with what it can read, and returns what
    /// the stack adds for blocks after it.
    @discardableResult
    private static func walk(_ stack: [Block], inherited: [AvailableValue], context: Context,
                             visit: (Block, [AvailableValue]) -> Void) -> [AvailableValue] {
        var available = inherited
        for block in stack {
            visit(block, available)
            let definition = context.registry.definition(block.definition)
            let own = definition.outputs.map {
                AvailableValue(binding: .output(block: block.id, port: $0.name), label: $0.label,
                               source: definition.title, type: $0.type)
            }
            switch definition.implementation {
            case .control(.forEach), .control(.repeatTimes):
                // The item and index exist only inside the loop.
                for child in block.children { walk(child, inherited: available + own, context: context, visit: visit) }
            case .control(.parallel):
                var added: [AvailableValue] = []
                for lane in block.children {
                    added += walk(lane, inherited: available, context: context, visit: visit).dropFirst(available.count)
                }
                available += added
            default:
                for child in block.children { walk(child, inherited: available, context: context, visit: visit) }
                if !block.isDisabled { available += own }
            }
        }
        return available
    }

    // MARK: Issues

    static func issues(in flow: Flow, registry: BlockRegistry) -> [FlowIssue] {
        let context = context(for: flow, registry: registry)
        var found: [FlowIssue] = []
        for hat in flow.triggers { found += inputIssues(hat, available: [], context: context) }
        found += issues(in: flow.body, context: context)
        if flow.isEnabled, flow.body.isEmpty {
            found.append(FlowIssue(block: flow.id, severity: .warning, message: "Nothing happens when it runs"))
        }
        return found
    }

    static func issues(in stack: [Block], context: Context) -> [FlowIssue] {
        var found: [FlowIssue] = []
        walk(stack, inherited: base(context), context: context) { block, available in
            guard !block.isDisabled else { return }
            found += inputIssues(block, available: available, context: context)
        }
        return found
    }

    private static func inputIssues(_ block: Block, available: [AvailableValue], context: Context) -> [FlowIssue] {
        let definition = context.registry.definition(block.definition)
        if case .missing = definition.implementation {
            return [FlowIssue(block: block.id, severity: .error, message: "This block is missing")]
        }
        var found: [FlowIssue] = []
        let offered = Dictionary(available.map { ($0.binding, $0.type) }, uniquingKeysWith: { first, _ in first })
        for port in definition.inputs {
            guard let binding = block.inputs[port.name] else {
                if !port.isOptional, port.defaultValue.isNothing || port.defaultValue == .text("") {
                    found.append(FlowIssue(block: block.id, port: port.name, severity: .error,
                                           message: "\(port.label) is not set"))
                }
                continue
            }
            found += bindingIssues(binding, port: port, block: block.id, offered: offered)
        }
        return found
    }

    private static func bindingIssues(_ binding: ValueSource, port: Port, block: UUID,
                                      offered: [ValueSource: ValueType]) -> [FlowIssue] {
        switch binding {
        case .literal(let value):
            let empty = value.isNothing || value == .text("") || value == .files([])
            if empty && !port.isOptional {
                return [FlowIssue(block: block, port: port.name, severity: .error, message: "\(port.label) is not set")]
            }
            return []
        case .template(let parts):
            return parts.flatMap { part -> [FlowIssue] in
                guard case .value(let inner) = part else { return [] }
                return bindingIssues(inner, port: Port(port.name, port.label, .text, optional: true),
                                     block: block, offered: offered)
            }
        default:
            guard let type = offered[binding] else {
                return [FlowIssue(block: block, port: port.name, severity: .error,
                                  message: "\(port.label) reads a value that isn't there")]
            }
            switch Conversion.from(type, to: port.type) {
            case .exact: return []
            case .converts:
                return [FlowIssue(block: block, port: port.name, severity: .warning,
                                  message: "\(port.label): \(type.label.lowercased()) is converted to \(port.type.label.lowercased())")]
            case .impossible:
                return [FlowIssue(block: block, port: port.name, severity: .error,
                                  message: "\(port.label) needs \(port.type.label.lowercased()), not \(type.label.lowercased())")]
            }
        }
    }
}

extension Flow {
    /// Whether nothing stops it from being switched on.
    func isRunnable(registry: BlockRegistry) -> Bool {
        !FlowCheck.issues(in: self, registry: registry).contains { $0.severity == .error }
    }
}
