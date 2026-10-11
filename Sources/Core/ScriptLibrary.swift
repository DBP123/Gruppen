import Foundation

/// One run of a script: when, what set it off, how long it took, and how each
/// step went. A run stops at the first step that fails, so the last outcome
/// of a failed run is the step that failed.
struct ScriptRunRecord: Identifiable, Codable, Hashable {
    struct StepOutcome: Codable, Hashable {
        let stepID: UUID
        let label: String
        let ok: Bool
        let message: String
    }

    var id = UUID()
    let date: Date
    /// What started it — "Manual", "Menu bar", "Folder"…
    let source: String
    let duration: TimeInterval
    let steps: [StepOutcome]

    var succeeded: Bool { steps.allSatisfy(\.ok) }

    /// The failing step's message, or the last thing a step said.
    var summary: String {
        if let failure = steps.first(where: { !$0.ok }) {
            return "\(failure.label.uppercased()) — \(failure.message)"
        }
        return steps.last(where: { !$0.message.isEmpty })?.message ?? "Done"
    }
}

/// Every script in the app, and the record of what they have done.
///
/// Global and standalone: nothing here knows about Gruppen or shelves. Runs
/// are kept on disk beside the library, the last fifty per script, so the
/// history and its stats survive a relaunch without growing forever.
@MainActor
final class ScriptLibrary: ObservableObject {
    @Published var scripts: [Script] = [] {
        didSet {
            guard scripts != oldValue else { return }
            save()
            onChange?()
        }
    }

    /// Newest last.
    @Published private(set) var runs: [UUID: [ScriptRunRecord]] = [:]

    /// Called after any change that could affect what is armed.
    var onChange: (() -> Void)?

    private let fileURL: URL
    private var runsURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("script-runs.json") }
    nonisolated static let runLimit = 50

    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Gruppen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("scripts.json")
    }

    init(fileURL: URL = ScriptLibrary.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Editing

    @discardableResult
    func add() -> Script {
        let script = Script(name: uniqueName("New script"))
        scripts.append(script)
        return script
    }

    func update(_ script: Script) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        guard scripts[index] != script else { return }
        scripts[index] = script
    }

    func remove(_ script: Script) {
        scripts.removeAll { $0.id == script.id }
        runs.removeValue(forKey: script.id)
        saveRuns()
    }

    @discardableResult
    func duplicate(_ script: Script) -> Script {
        let copy = Script(name: uniqueName(script.name + " copy"),
                          isActive: false,
                          trigger: script.trigger,
                          steps: script.steps.map { var step = $0; step.id = UUID(); return step },
                          output: script.output)
        scripts.append(copy)
        return copy
    }

    private func uniqueName(_ base: String) -> String {
        var candidate = base
        var counter = 2
        while scripts.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: Import / export

    /// What a `.gruppenscript` file holds: one script, labelled so a stray
    /// JSON file is refused rather than half-read.
    struct ScriptFile: Codable {
        var format = "gruppen-script"
        var version = 1
        var script: Script
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\(name) is not a script Gruppen can read."
            case .unsupported(let ext): return "A .\(ext) file is not a script."
            }
        }
    }

    nonisolated static let codeExtensions: [String: ScriptStep.Kind] = [
        "sh": .shell, "zsh": .shell, "bash": .shell, "command": .shell,
        "js": .javascript, "applescript": .applescript,
    ]

    nonisolated static func exportData(_ script: Script) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ScriptFile(script: script))
    }

    /// Adds the script in `url` to the library and returns it.
    ///
    /// A `.gruppenscript` comes in whole. A plain `.sh`, `.zsh`, `.js` or
    /// `.applescript` comes in as a manual script with one code step holding the
    /// file's text. Either way it arrives **switched off** with fresh
    /// identifiers: a script from somewhere else does nothing until you have
    /// looked at it and armed it yourself.
    @discardableResult
    func importScript(from url: URL) throws -> Script {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let imported: Script

        if ext == "gruppenscript" {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(ScriptFile.self, from: data),
                  file.format == "gruppen-script"
            else { throw ImportError.unreadable(url.lastPathComponent) }
            imported = file.script
        } else if let kind = Self.codeExtensions[ext] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ImportError.unreadable(url.lastPathComponent)
            }
            var step = ScriptStep.make(kind)
            step.code.source = text
            step.code.isCustomised = true
            imported = Script(name: name, steps: [step])
        } else {
            throw ImportError.unsupported(ext)
        }

        let script = Script(name: uniqueName(imported.name),
                            isActive: false,
                            trigger: imported.trigger,
                            steps: imported.steps.map { var step = $0; step.id = UUID(); return step },
                            output: imported.output)
        scripts.append(script)
        return script
    }

    // MARK: Runs

    func record(_ run: ScriptRunRecord, for id: UUID) {
        var entries = runs[id] ?? []
        entries.append(run)
        if entries.count > Self.runLimit { entries.removeFirst(entries.count - Self.runLimit) }
        runs[id] = entries
        saveRuns()
    }

    func clearRuns(for id: UUID) {
        runs[id] = nil
        saveRuns()
    }

    // MARK: Persistence

    private func load() {
        scripts = LenientLibrary.load(Script.self, from: fileURL, label: "SCRIPTS")
        if let data = try? Data(contentsOf: runsURL),
           let stored = try? JSONDecoder().decode([UUID: [ScriptRunRecord]].self, from: data) {
            // Runs for scripts that no longer exist are dropped on the way in.
            let live = Set(scripts.map(\.id))
            runs = stored.filter { live.contains($0.key) }
        }
    }

    private func save() {
        write(scripts, to: fileURL)
    }

    private func saveRuns() {
        write(runs, to: runsURL)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
