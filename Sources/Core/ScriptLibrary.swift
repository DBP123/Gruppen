import Foundation

/// Every script in the app, and the record of what they have done.
///
/// Global and standalone: nothing here knows about Gruppen or shelves. Saving is
/// debounced the same way the Gruppe store's is — typing a name should not write
/// the file on every keystroke.
@MainActor
final class ScriptLibrary: ObservableObject {
    @Published var scripts: [Script] = [] {
        didSet {
            guard scripts != oldValue else { return }
            save()
            onChange?()
        }
    }

    /// Per-script transcripts, newest last. Memory only — a log that survives a
    /// relaunch is a log that grows forever.
    @Published private(set) var logs: [UUID: [LogEntry]] = [:]

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let text: String
        let failed: Bool
    }

    /// Called after any change that could affect what is armed.
    var onChange: (() -> Void)?

    private let fileURL: URL
    private static let logLimit = 40

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
        var script = Script()
        script.name = uniqueName("New script")
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
        logs.removeValue(forKey: script.id)
    }

    func duplicate(_ script: Script) {
        var copy = script
        copy = Script(name: uniqueName(script.name + " copy"),
                      isActive: false,
                      trigger: script.trigger,
                      action: script.action,
                      feedback: script.feedback)
        scripts.append(copy)
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

    // MARK: Logging

    func record(_ text: String, failed: Bool, for id: UUID) {
        var entries = logs[id] ?? []
        entries.append(LogEntry(date: Date(), text: text, failed: failed))
        if entries.count > Self.logLimit { entries.removeFirst(entries.count - Self.logLimit) }
        logs[id] = entries
    }

    func clearLog(for id: UUID) { logs[id] = [] }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Script].self, from: data)
        else { return }
        scripts = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
