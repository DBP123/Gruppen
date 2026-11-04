import AppKit
import Foundation

/// One run, as kept in a flow's history: when, what started it, how it ended,
/// and every block's part in it — its outputs and what it printed — so a run
/// can be read back like a debugger's trace.
struct FlowRunRecord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var source: String
    var duration: TimeInterval
    var outcome: RunOutcome
    var message: String
    var blocks: [BlockTrace]

    var failedBlock: UUID? { blocks.last { $0.state == .failed }?.block }
}

struct BlockTrace: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable { case running, finished, failed, skipped }

    var block: UUID
    var title: String
    var state: State
    var message: String = ""
    var outputs: [String: Value] = [:]
    var log: [ConsoleLine] = []
    var started: Date
    var duration: TimeInterval = 0
}

struct ConsoleLine: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var block: UUID?
    var text: String
    var isError: Bool
}

/// Every flow and every block you made, and what the flows have done.
///
/// Flows live in `flows.json`; each custom block in a file of its own under
/// `Blocks/`, so one can be shared by dropping the file into a friend's
/// folder. History lives beside them, the last fifty runs per flow.
///
/// **Saving waits for a pause.** The code editor edits a flow on every
/// keystroke; writing the whole library each time would be a disk write per
/// key. A save is booked half a second after the last change instead, and
/// made at once when the app quits.
@MainActor
final class FlowLibrary: ObservableObject {
    @Published var flows: [Flow] = [] {
        didSet {
            guard flows != oldValue else { return }
            scheduleSave()
            onChange?()
        }
    }

    @Published private(set) var blocks: [CustomBlock] = []
    @Published private(set) var runs: [UUID: [FlowRunRecord]] = [:]
    @Published private(set) var registry = BlockRegistry()

    /// Called after any change that could affect what is armed.
    var onChange: (() -> Void)?

    let folder: URL
    private var flowsURL: URL { folder.appendingPathComponent("flows.json") }
    private var runsURL: URL { folder.appendingPathComponent("flow-runs.json") }
    var blocksFolder: URL { folder.appendingPathComponent("Blocks", isDirectory: true) }
    private var pendingSave: DispatchWorkItem?

    nonisolated static let runLimit = 50
    /// Each saved output value is cut to this many characters.
    nonisolated static let traceLimit = 4096

    nonisolated static var defaultFolder: URL { AppPaths.support }

    init(folder: URL = FlowLibrary.defaultFolder) {
        self.folder = folder
        load()
    }

    // MARK: Flows

    func flow(_ id: UUID) -> Flow? { flows.first { $0.id == id } }

    @discardableResult
    func add(_ flow: Flow) -> Flow {
        var flow = flow
        flow.name = uniqueName(flow.name)
        flows.append(flow)
        return flow
    }

    func update(_ flow: Flow) {
        guard let index = flows.firstIndex(where: { $0.id == flow.id }), flows[index] != flow else { return }
        flows[index] = flow
    }

    func remove(_ id: UUID) {
        flows.removeAll { $0.id == id }
        runs[id] = nil
        saveRuns()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Flow? {
        guard let original = flow(id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.isEnabled = false
        copy.triggers = Block.copies(of: original.triggers)
        copy.body = Block.copies(of: original.body)
        copy.name = original.name + " copy"
        return add(copy)
    }

    func uniqueName(_ base: String) -> String {
        var candidate = base
        var counter = 2
        while flows.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: Custom blocks

    func saveBlock(_ block: CustomBlock) {
        var block = block
        if let old = blocks.first(where: { $0.id == block.id }), old.inputs != block.inputs || old.outputs != block.outputs {
            block.version = old.version + 1
        }
        if let index = blocks.firstIndex(where: { $0.id == block.id }) {
            blocks[index] = block
        } else {
            blocks.append(block)
        }
        try? FileManager.default.createDirectory(at: blocksFolder, withIntermediateDirectories: true)
        LenientLibrary.save(BlockFile(block: block), to: blockURL(block.id), label: "BLOCK \(block.title)")
        rebuildRegistry()
    }

    func deleteBlock(_ id: UUID) {
        blocks.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: blockURL(id))
        rebuildRegistry()
    }

    /// Flows that use the block, by name.
    func flows(using id: UUID) -> [Flow] {
        let definition = CustomBlock.definitionID(id)
        return flows.filter { flow in
            Block.flatten(flow.body + flow.loose.flatMap(\.blocks)).contains { $0.definition == definition }
        }
    }

    private func blockURL(_ id: UUID) -> URL { blocksFolder.appendingPathComponent("\(id.uuidString).gruppenblock") }

    private func rebuildRegistry() {
        blocks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        registry = BlockRegistry(custom: blocks)
        onChange?()
    }

    // MARK: History

    /// Adds `run`, or replaces the record with its id. A run is recorded as
    /// interrupted when it starts and replaced when it ends, so one cut off
    /// by a quit or a crash still says so.
    func record(_ run: FlowRunRecord, for id: UUID) {
        var trimmed = run
        trimmed.blocks = run.blocks.map { trace in
            var trace = trace
            trace.outputs = trace.outputs.mapValues { $0.truncated(to: Self.traceLimit) }
            trace.log = Array(trace.log.suffix(200))
            return trace
        }
        var list = runs[id] ?? []
        if let index = list.firstIndex(where: { $0.id == run.id }) {
            list[index] = trimmed
        } else {
            list.append(trimmed)
        }
        if list.count > Self.runLimit { list.removeFirst(list.count - Self.runLimit) }
        runs[id] = list
        saveRuns()
    }

    func clearRuns(for id: UUID) {
        runs[id] = nil
        saveRuns()
    }

    func lastRun(_ id: UUID) -> FlowRunRecord? { runs[id]?.last }

    // MARK: Files

    /// What a `.gruppenflow` file holds: a flow, and every block of yours it
    /// uses, so it works on a Mac that has never seen them.
    struct FlowFile: Codable {
        var format = "gruppen-flow"
        var version = 1
        var flow: Flow
        var blocks: [CustomBlock]
    }

    struct BlockFile: Codable {
        var format = "gruppen-block"
        var version = 1
        var block: CustomBlock
    }

    func export(_ id: UUID, to url: URL) -> Bool {
        guard let flow = flow(id) else { return false }
        var shared = flow
        shared.isEnabled = false
        let file = FlowFile(flow: shared, blocks: registry.customBlocks(usedBy: flow.body + flow.loose.flatMap(\.blocks)))
        return LenientLibrary.save(file, to: url, label: "EXPORT \(flow.name)")
    }

    func exportBlock(_ id: UUID, to url: URL) -> Bool {
        guard let block = blocks.first(where: { $0.id == id }) else { return false }
        return LenientLibrary.save(BlockFile(block: block), to: url, label: "EXPORT \(block.title)")
    }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "This isn't a Gruppen flow or block." }
    }

    /// What a file would bring in, read but not yet added — so the code in it
    /// can be shown before anything from it can run.
    struct Incoming {
        var flow: Flow?
        var blocks: [CustomBlock]
        /// Every piece of code it carries, by where it sits.
        var code: [(place: String, spec: CodeSpec)]
    }

    func read(_ url: URL) throws -> Incoming {
        let data = try Data(contentsOf: url)
        if let file = try? JSONDecoder().decode(FlowFile.self, from: data), file.format == "gruppen-flow" {
            return Incoming(flow: file.flow, blocks: file.blocks, code: Self.code(in: file.flow.body, blocks: file.blocks))
        }
        if let file = try? JSONDecoder().decode(BlockFile.self, from: data), file.format == "gruppen-block" {
            return Incoming(flow: nil, blocks: [file.block], code: Self.code(in: [], blocks: [file.block]))
        }
        throw ImportError.unreadable
    }

    /// Adds what was read. A block that already exists is replaced only when
    /// the incoming one is newer; an imported flow arrives switched off.
    @discardableResult
    func add(_ incoming: Incoming) -> Flow? {
        for block in incoming.blocks {
            if let mine = blocks.first(where: { $0.id == block.id }), mine.version >= block.version { continue }
            saveBlock(block)
        }
        guard var flow = incoming.flow else { return nil }
        flow.id = UUID()
        flow.isEnabled = false
        return add(flow)
    }

    static func code(in stack: [Block], blocks: [CustomBlock]) -> [(place: String, spec: CodeSpec)] {
        var found: [(String, CodeSpec)] = []
        for block in Block.flatten(stack) where block.definition.hasPrefix("code.") {
            let language = CodeLanguage(rawValue: String(block.definition.dropFirst(5))) ?? .zsh
            found.append(("\(language.label) block", CodeSpec(language, source: block.inputs["code"]?.literal?.text ?? "")))
        }
        for block in blocks {
            switch block.body {
            case .code(let spec): found.append(("Block “\(block.title)”", spec))
            case .blocks(let inner): found += code(in: inner, blocks: []).map { ("\(block.title) › \($0.place)", $0.spec) }
            }
        }
        return found
    }

    // MARK: Persistence

    private func load() {
        flows = LenientLibrary.load(Flow.self, from: flowsURL, label: "FLOWS")
        if let data = try? Data(contentsOf: runsURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            runs = (try? decoder.decode([UUID: [FlowRunRecord]].self, from: data)) ?? [:]
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: blocksFolder, includingPropertiesForKeys: nil)) ?? []
        blocks = files.filter { $0.pathExtension == "gruppenblock" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONDecoder().decode(BlockFile.self, from: data))?.block
        }
        rebuildRegistry()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes now — on quit, and wherever a pending save must not be lost.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        LenientLibrary.save(flows, to: flowsURL, label: "FLOWS")
    }

    private func saveRuns() {
        let encoder = LenientLibrary.readableEncoder()
        encoder.dateEncodingStrategy = .iso8601
        LenientLibrary.save(runs, to: runsURL, encoder: encoder, label: "FLOW RUNS")
    }
}
