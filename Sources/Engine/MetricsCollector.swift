import AppKit
import Foundation
import JavaScriptCore

/// Listens for the events metrics are built on, and decides what to keep.
///
/// **Nothing is polled.** Every source is a notification the system already
/// posts — `DistributedNotificationCenter` for the media players and the screen
/// lock, `NSWorkspace` for applications. When no metric is recording, this
/// object holds no observers at all.
///
/// **Nothing heavy happens on the main thread.** A notification arrives on the
/// main queue with a dictionary; that dictionary is flattened, then the
/// condition is evaluated and the row written on a background serial queue
/// inside an autorelease pool.
@MainActor
final class MetricsCollector: ObservableObject {
    private let library: MetricLibrary
    private let store: MetricStore

    /// Observers for the metrics currently recording.
    private var distributed: [NSObjectProtocol] = []
    private var workspace: [NSObjectProtocol] = []
    /// One-shot observers installed by "sniff data fields".
    private var sniffers: [NSObjectProtocol] = []

    /// Rises while a sniff is waiting for its one event.
    @Published private(set) var sniffing: UUID?

    private let work = DispatchQueue(label: "com.dhilanpatel.gruppen.metrics", qos: .utility)

    init(library: MetricLibrary, store: MetricStore) {
        self.library = library
        self.store = store
        library.onChange = { [weak self] in self?.rearm() }
    }

    // MARK: Arming

    func rearm() {
        disarm()
        let recording = library.metrics.filter(\.isArmable)
        guard !recording.isEmpty else { return }
        for metric in recording { observe(metric) { [weak self] payload in
            self?.handle(payload, for: metric.id)
        } }
    }

    func disarm() {
        for observer in distributed { DistributedNotificationCenter.default().removeObserver(observer) }
        distributed.removeAll()
        for observer in workspace { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspace.removeAll()
    }

    /// Listens for exactly one occurrence and hands back its raw fields.
    ///
    /// This is what the "Sniff Data Fields" button runs. It installs the same
    /// observer a recording metric would, takes the first thing it sees, and
    /// removes itself.
    func sniff(_ metric: MetricDefinition, completion: @escaping ([String: String]) -> Void) {
        cancelSniff()
        sniffing = metric.id
        observe(metric, into: &sniffers) { [weak self] payload in
            guard let self, self.sniffing == metric.id else { return }
            self.cancelSniff()
            completion(payload)
        }
    }

    func cancelSniff() {
        for observer in sniffers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sniffers.removeAll()
        sniffing = nil
    }

    // MARK: Observation

    private func observe(_ metric: MetricDefinition,
                         into bucket: UnsafeMutablePointer<[NSObjectProtocol]>? = nil,
                         handler: @escaping ([String: String]) -> Void) {
        let kind = metric.source.kind

        if let workspaceName = kind.workspaceName {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: workspaceName, object: nil, queue: .main
            ) { note in
                handler(Self.flatten(note.userInfo, note: note))
            }
            if let bucket { bucket.pointee.append(observer) } else { workspace.append(observer) }
            return
        }

        let name = metric.source.kind == .custom
            ? metric.source.customName
            : (kind.distributedName ?? "")
        guard !name.isEmpty else { return }
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { note in
            handler(Self.flatten(note.userInfo, note: note))
        }
        if let bucket { bucket.pointee.append(observer) } else { distributed.append(observer) }
    }

    /// Turns a notification's `userInfo` into flat string fields.
    ///
    /// Everything is stringified on purpose: these dictionaries carry numbers,
    /// dates, booleans and occasionally whole objects, and a table, a CSV and a
    /// SQLite blob all want text in the end. The JavaScript side gets numbers
    /// back where the text looks like one, so `payload.duration > 30` behaves.
    nonisolated static func flatten(_ userInfo: [AnyHashable: Any]?, note: Notification) -> [String: String] {
        var fields: [String: String] = [:]

        if let app = userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            fields["Name"] = app.localizedName ?? ""
            fields["Bundle ID"] = app.bundleIdentifier ?? ""
            fields["Process ID"] = String(app.processIdentifier)
            fields["Path"] = app.bundleURL?.path ?? ""
            fields["Active"] = app.isActive ? "true" : "false"
        }

        for (key, value) in userInfo ?? [:] {
            let name = String(describing: key)
            guard name != NSWorkspace.applicationUserInfoKey else { continue }
            switch value {
            case let string as String: fields[name] = string
            case let number as NSNumber: fields[name] = number.stringValue
            case let date as Date: fields[name] = ISO8601DateFormatter().string(from: date)
            default: fields[name] = String(describing: value)
            }
        }

        if fields.isEmpty { fields["Event"] = note.name.rawValue }
        return fields
    }

    // MARK: Handling

    private func handle(_ raw: [String: String], for id: UUID) {
        guard let metric = library.metrics.first(where: { $0.id == id }) else { return }
        let kept = metric.keptKeys
        let condition = metric.condition
        // Pruned fields never reach the condition or the database.
        let pruned = kept.isEmpty
            ? raw
            : raw.filter { kept.contains($0.key) }

        let store = self.store
        work.async {
            autoreleasepool {
                guard Self.passes(condition: condition, payload: pruned) else { return }
                store.insert(metric: id, values: pruned)
            }
        }
    }

    /// Evaluates the user's condition. An empty condition keeps everything; a
    /// condition that throws keeps nothing and says why in the log.
    nonisolated static func passes(condition: String, payload: [String: String]) -> Bool {
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let context = JSContext() else { return false }

        // Numbers arrive as numbers so comparisons behave the way they read.
        var bridged: [String: Any] = [:]
        for (key, value) in payload {
            if let number = Double(value) { bridged[key] = number } else { bridged[key] = value }
        }
        context.setObject(bridged, forKeyedSubscript: "payload" as NSString)

        var failure: String?
        context.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? "unknown error"
        }
        let result = context.evaluateScript("(function(){ \(trimmed) })()")
        if let failure {
            NSLog("Gruppen: metric condition failed — %@", failure)
            return false
        }
        return result?.toBool() ?? false
    }
}
