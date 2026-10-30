import AppKit
import Foundation

/// A run as it happens, for the canvas and the console: which block is
/// running, what each one produced, every line printed.
@MainActor
final class RunTrace: ObservableObject, Identifiable {
    let id = UUID()
    let flowID: UUID
    let source: String
    let started = Date()

    @Published private(set) var states: [UUID: BlockTrace.State] = [:]
    @Published private(set) var outputs: [UUID: [String: Value]] = [:]
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var lines: [ConsoleLine] = []
    /// The block a breakpoint or a step is holding the run at.
    @Published private(set) var pausedAt: UUID?
    @Published private(set) var outcome: RunOutcome?
    @Published private(set) var finalMessage = ""

    let debugger: RunDebugger?
    private var traces: [UUID: BlockTrace] = [:]
    private var order: [UUID] = []
    private let titles: (String) -> String
    private let masked: [String]

    init(flowID: UUID, source: String, debugger: RunDebugger?, masked: [String], titles: @escaping (String) -> String) {
        self.flowID = flowID
        self.source = source
        self.debugger = debugger
        self.masked = masked
        self.titles = titles
    }

    var isRunning: Bool { outcome == nil }

    /// One block's definition, for naming it in the trace.
    var definitions: [UUID: String] = [:]

    func apply(_ event: RunEvent) {
        switch event {
        case .started(let id):
            states[id] = .running
            traces[id] = BlockTrace(block: id, title: titles(definitions[id] ?? ""), state: .running, started: Date())
            if !order.contains(id) { order.append(id) }
        case .finished(let id, let values, let message):
            states[id] = .finished
            outputs[id] = values
            messages[id] = Secrets.mask(message, masked)
            traces[id]?.state = .finished
            traces[id]?.outputs = values.mapValues(mask)
            traces[id]?.message = Secrets.mask(message, masked)
            let started = traces[id]?.started ?? Date()
            traces[id]?.duration = Date().timeIntervalSince(started)
        case .failed(let id, let message):
            states[id] = .failed
            messages[id] = Secrets.mask(message, masked)
            traces[id]?.state = .failed
            traces[id]?.message = Secrets.mask(message, masked)
            let started = traces[id]?.started ?? Date()
            traces[id]?.duration = Date().timeIntervalSince(started)
            lines.append(ConsoleLine(block: id, text: Secrets.mask(message, masked), isError: true))
        case .skipped(let id):
            states[id] = .skipped
        case .log(let id, let line, let isError):
            let line = ConsoleLine(block: id, text: Secrets.mask(line, masked), isError: isError)
            lines.append(line)
            if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
            traces[id]?.log.append(line)
        case .paused(let id):
            pausedAt = id
        case .resumed:
            pausedAt = nil
        }
    }

    func finish(_ outcome: RunOutcome, message: String) {
        self.outcome = outcome
        finalMessage = Secrets.mask(message, masked)
        pausedAt = nil
    }

    func record(id: UUID) -> FlowRunRecord {
        FlowRunRecord(id: id, date: started, source: source, duration: Date().timeIntervalSince(started),
                      outcome: outcome ?? .interrupted, message: finalMessage,
                      blocks: order.compactMap { traces[$0] })
    }

    private func mask(_ value: Value) -> Value {
        guard !masked.isEmpty else { return value }
        if case .text(let text) = value { return .text(Secrets.mask(text, masked)) }
        return value
    }
}

/// Runs flows: from their triggers, by hand, from the palette, from outside.
///
/// Holds what is running and nothing else. A run is a task; its trace lives
/// for the editor to read until the next run of that flow replaces it.
@MainActor
final class FlowEngine: ObservableObject {
    let library: FlowLibrary
    /// The latest run of each flow, running or finished.
    @Published private(set) var traces: [UUID: RunTrace] = [:]
    /// What the Gruppe and workspace blocks call. Set by the app, which owns
    /// the store and the workspace engine.
    var hooks = FlowHooks()
    /// Files a run has just written: a folder trigger must not see a flow's
    /// own output arrive and run it again, for ever.
    private(set) var produced: Set<String> = []

    private var tasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    /// Per flow, a run waiting for the one in progress to finish. One at most:
    /// a folder filling faster than its flow empties it queues one more run,
    /// which then sees everything that arrived meanwhile.
    private var waiting: [UUID: (trigger: [String: Value], source: String)] = [:]

    /// Arms the hats of the flows that are switched on.
    private(set) lazy var triggers = FlowTriggers(library: library, engine: self)

    /// The app's engine, for the stash's Run key, which lives in windows
    /// built outside the scene graph.
    static weak var current: FlowEngine?

    init(library: FlowLibrary) {
        self.library = library
        Self.current = self
        hooks.ask = { prompt, choices, placeholder in await FlowDialogs.ask(prompt, choices: choices, placeholder: placeholder) }
        library.onChange = { [weak self] in self?.triggers.rearm() }
    }

    func isRunning(_ id: UUID) -> Bool { !(tasks[id]?.isEmpty ?? true) }

    /// Starts `id`. `debug` honours breakpoints — only for runs started from
    /// the editor, where someone is there to press Continue.
    @discardableResult
    func run(_ id: UUID, trigger: [String: Value] = [:], source: String, debug: Bool = false) -> RunTrace? {
        guard let flow = library.flow(id) else { return nil }
        if isRunning(id) {
            switch flow.policy.concurrency {
            case .skip:
                return traces[id]
            case .queue:
                waiting[id] = (trigger, source)
                return traces[id]
            case .restart:
                stop(id)
            case .parallel:
                break
            }
        }
        return start(flow, trigger: trigger, source: source, debug: debug)
    }

    func stop(_ id: UUID) {
        waiting[id] = nil
        tasks[id]?.values.forEach { $0.cancel() }
        if let debugger = traces[id]?.debugger { Task { await debugger.stop() } }
    }

    private func start(_ flow: Flow, trigger: [String: Value], source: String, debug: Bool) -> RunTrace {
        let registry = library.registry
        let secrets = flow.secrets.compactMap { name in Secrets.value(name).map { (name, $0) } }
        var environment = flow.environment
        for (name, value) in secrets { environment[Secrets.variable(for: name)] = value }
        // Secrets picked into a block's own input are blanked out too.
        let picked = flow.allBlocks.flatMap { block -> [String] in
            let definition = registry.definition(block.definition)
            return definition.inputs.filter { $0.control == .secret }
                .compactMap { block.inputs[$0.name]?.literal?.text }.compactMap(Secrets.value)
        }
        let context = RunContext(flowID: flow.id, flowName: flow.name, environment: environment,
                                 deadline: flow.policy.timeout > 0 ? Date().addingTimeInterval(TimeInterval(flow.policy.timeout)) : nil,
                                 masked: secrets.map(\.1) + picked)
        let debugger = debug ? RunDebugger() : nil
        let trace = RunTrace(flowID: flow.id, source: source, debugger: debugger, masked: context.masked) {
            registry.definition($0).title
        }
        for block in Block.flatten(flow.body) { trace.definitions[block.id] = block.definition }
        traces[flow.id] = trace

        let recordID = UUID()
        library.record(trace.record(id: recordID), for: flow.id)

        let (events, sink) = AsyncStream.makeStream(of: RunEvent.self)
        let runner = FlowRunner(registry: registry, hooks: hooks, code: CodeRunner(),
                                events: { sink.yield($0) }, debugger: debugger)
        let runID = UUID()
        let task = Task { [weak self] in
            // Applied in order, on the main actor, as they come.
            let applying = Task { @MainActor in
                for await event in events {
                    trace.apply(event)
                    if case .finished(_, let outputs, _) = event { self?.remember(outputs) }
                }
            }
            var outcome = RunOutcome.succeeded
            var message = ""
            do {
                message = try await runner.run(flow, trigger: trigger, context: context) ?? ""
            } catch FlowError.cancelled {
                outcome = .stopped
                message = FlowError.cancelled.localizedDescription
            } catch {
                outcome = Task.isCancelled ? .stopped : .failed
                message = error.localizedDescription
            }
            sink.finish()
            await applying.value
            self?.finish(flow, trace: trace, recordID: recordID, runID: runID, outcome: outcome, message: message)
        }
        tasks[flow.id, default: [:]][runID] = task
        return trace
    }

    private func finish(_ flow: Flow, trace: RunTrace, recordID: UUID, runID: UUID, outcome: RunOutcome, message: String) {
        let summary = message.isEmpty ? (outcome == .succeeded ? "Done" : outcome.rawValue.capitalized) : message
        trace.finish(outcome, message: summary)
        library.record(trace.record(id: recordID), for: flow.id)
        tasks[flow.id]?[runID] = nil
        GroupStore.log("FLOW \"\(flow.name)\" \(outcome.rawValue) "
                       + String(format: "%.2fs — ", Date().timeIntervalSince(trace.started)) + summary)

        let notify: Bool
        switch flow.policy.notify {
        case .never: notify = false
        case .onFailure: notify = outcome == .failed
        case .always: notify = outcome != .stopped
        }
        if notify {
            Notifier.post(title: outcome == .failed ? "\(flow.name) failed" : flow.name,
                          body: summary.split(separator: "\n").first.map(String.init) ?? "") { failure in
                if let failure { GroupStore.log("FLOW notification failed — \(failure)") }
            }
        }

        if let next = waiting.removeValue(forKey: flow.id), !isRunning(flow.id) {
            run(flow.id, trigger: next.trigger, source: next.source)
        }
    }

    /// Paths a run wrote, so the folder trigger can tell them from arrivals.
    private func remember(_ outputs: [String: Value]) {
        for value in outputs.values { produced.formUnion((value.urls ?? []).map(\.path)) }
        if produced.count > 5000 { produced.removeAll() }
    }

    /// True once for each path a run produced — the folder trigger asks, and
    /// the path is forgotten so a later real arrival of it counts.
    func consumeProduced(_ path: String) -> Bool { produced.remove(path) != nil }

    /// One block on its own, for the palette's tools: no history, and a
    /// notification only if it fails.
    func runOnce(_ block: Block, title: String) {
        let flow = Flow(name: title, body: [block])
        let runner = FlowRunner(registry: library.registry, hooks: hooks, code: CodeRunner(), events: { _ in }, debugger: nil)
        Task {
            do {
                try await runner.run(flow, trigger: [:], context: RunContext(flowID: flow.id, flowName: title, environment: [:],
                                                                             deadline: Date().addingTimeInterval(60)))
            } catch {
                Notifier.post(title: title, body: error.localizedDescription)
            }
        }
    }

    // MARK: Entry points

    /// The name distributed notifications about finished outside runs carry,
    /// for `gruppen run` waiting in Terminal.
    nonisolated static let finishedNotification = Notification.Name("com.dhilanpatel.gruppen.flowFinished")

    /// `gruppen://run/<name or id>?key=value&file=/path&reply=<token>`.
    func open(_ url: URL) {
        guard url.scheme == "gruppen", url.host == "run" else {
            GroupStore.log("FLOW link not understood: \(url.absoluteString)")
            return
        }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var parameters: [String: String] = [:]
        var files: [URL] = []
        var reply: String?
        for item in items {
            switch item.name {
            case "file": if let path = item.value { files.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
            case "reply": reply = item.value
            default: parameters[item.name] = item.value ?? ""
            }
        }
        let trace = runExternal(named: name, parameters: parameters, files: files)
        guard let reply else { return }
        // Answer Terminal when the run ends — or at once, when there was no
        // such flow to run.
        Task { @MainActor in
            var outcome = "failed", message = "No flow is called “\(name)”"
            if let trace {
                for await ended in trace.$outcome.values where ended != nil { break }
                outcome = (trace.outcome ?? .failed).rawValue
                message = trace.finalMessage
            }
            DistributedNotificationCenter.default().postNotificationName(
                Self.finishedNotification, object: reply,
                userInfo: ["outcome": outcome, "message": message], deliverImmediately: true)
        }
    }

    /// From outside: `gruppen run` or a gruppen:// link. The flow is found by
    /// name, ignoring case, or by id.
    @discardableResult
    func runExternal(named name: String, parameters: [String: String], files: [URL] = []) -> RunTrace? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard let flow = library.flows.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                                                      || $0.id.uuidString == wanted }) else {
            GroupStore.log("FLOW external run: no flow named \"\(wanted)\"")
            return nil
        }
        let input = parameters["input"] ?? ""
        return run(flow.id, trigger: ["params": .record(parameters.mapValues(Value.text)), "input": .text(input),
                                      "files": .files(files)], source: "Outside")
    }

    /// Flows the stash action bar offers: those started from a stash.
    var stashFlows: [Flow] {
        library.flows.filter { $0.triggers.contains { $0.definition == Catalog.stash } }
    }

    /// Flows that run by hand — the palette's and menu bar's list.
    var manualFlows: [Flow] {
        library.flows.filter { $0.triggers.isEmpty || $0.triggers.contains { $0.definition == Catalog.manual } }
    }
}

/// The dialog the Ask block shows.
@MainActor
enum FlowDialogs {
    static func ask(_ prompt: String, choices: [String], placeholder: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field: NSView
        if choices.isEmpty {
            let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            text.placeholderString = placeholder
            field = text
        } else {
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
            popup.addItems(withTitles: choices)
            field = popup
        }
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        if let popup = field as? NSPopUpButton { return popup.titleOfSelectedItem }
        return (field as? NSTextField)?.stringValue
    }
}
