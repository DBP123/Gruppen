import Foundation

/// Every metric definition, persisted beside the Gruppen and the scripts.
///
/// The captured rows live in SQLite; this file holds only the definitions,
/// which are small and change rarely.
@MainActor
final class MetricLibrary: ObservableObject {
    @Published var metrics: [MetricDefinition] = [] {
        didSet {
            guard metrics != oldValue else { return }
            save()
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Gruppen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("metrics.json")
    }

    init(fileURL: URL = MetricLibrary.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MetricDefinition].self, from: data) {
            metrics = decoded
        }
    }

    @discardableResult
    func add() -> MetricDefinition {
        var metric = MetricDefinition()
        var name = "New metric"
        var counter = 2
        while metrics.contains(where: { $0.name == name }) {
            name = "New metric \(counter)"
            counter += 1
        }
        metric.name = name
        metrics.append(metric)
        return metric
    }

    func update(_ metric: MetricDefinition) {
        guard let index = metrics.firstIndex(where: { $0.id == metric.id }) else { return }
        guard metrics[index] != metric else { return }
        metrics[index] = metric
    }

    func remove(_ metric: MetricDefinition) {
        metrics.removeAll { $0.id == metric.id }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metrics) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
