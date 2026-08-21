import Foundation
import SQLite3

/// The metrics database.
///
/// **Why a JSON column and not generated ones.** The whole point of the schema
/// pruning table is that a metric's shape is the user's to change, at any time,
/// after rows already exist. Generated columns would mean an `ALTER TABLE` on
/// every edit and a migration for every existing row, and a metric whose fields
/// changed twice would have columns that mean different things in different
/// rows. One JSON blob per occurrence plus a timestamp keeps every row
/// self-describing; the export widens them back out into columns by taking the
/// union of the keys actually present.
///
/// **Threading.** One serial queue owns the connection, so SQLite never sees two
/// callers, and every entry point hops onto it. Writes are wrapped in an
/// autorelease pool.
final class MetricStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.dhilanpatel.gruppen.metricstore", qos: .utility)

    /// SQLite needs to be told a bound string outlives the call; this is the
    /// documented sentinel for "copy it".
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Gruppen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("metrics.sqlite")
    }

    init(url: URL = MetricStore.defaultURL) {
        queue.sync {
            guard sqlite3_open(url.path, &db) == SQLITE_OK else {
                NSLog("Gruppen: could not open the metrics database at %@", url.path)
                db = nil
                return
            }
            // WAL keeps a reader from blocking the writer, and the writes here
            // are small and frequent.
            exec("PRAGMA journal_mode=WAL;")
            exec("""
                 CREATE TABLE IF NOT EXISTS occurrences (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   metric TEXT NOT NULL,
                   captured_at REAL NOT NULL,
                   payload TEXT NOT NULL
                 );
                 """)
            exec("CREATE INDEX IF NOT EXISTS occurrences_metric ON occurrences(metric, captured_at);")
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Writing

    /// Records one occurrence. Returns immediately; the write happens on the
    /// store's own queue.
    func insert(metric: UUID, values: [String: String], at date: Date = Date()) {
        queue.async { [self] in
            autoreleasepool {
                guard let db,
                      let json = try? JSONSerialization.data(withJSONObject: values),
                      let text = String(data: json, encoding: .utf8)
                else { return }

                var statement: OpaquePointer?
                let sql = "INSERT INTO occurrences (metric, captured_at, payload) VALUES (?, ?, ?);"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(statement) }

                sqlite3_bind_text(statement, 1, metric.uuidString, -1, Self.transient)
                sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
                sqlite3_bind_text(statement, 3, text, -1, Self.transient)
                sqlite3_step(statement)
            }
        }
    }

    // MARK: Reading

    /// Most recent first.
    func records(for metric: UUID, limit: Int = 200) async -> [MetricRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: autoreleasepool { readRecords(metric: metric, limit: limit) })
            }
        }
    }

    func count(for metric: UUID) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let db else { continuation.resume(returning: 0); return }
                var statement: OpaquePointer?
                let sql = "SELECT COUNT(*) FROM occurrences WHERE metric = ?;"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    continuation.resume(returning: 0); return
                }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement, 1, metric.uuidString, -1, Self.transient)
                let value = sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
                continuation.resume(returning: value)
            }
        }
    }

    func deleteAll(for metric: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let db else { continuation.resume(); return }
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM occurrences WHERE metric = ?;",
                                         -1, &statement, nil) == SQLITE_OK else {
                    continuation.resume(); return
                }
                sqlite3_bind_text(statement, 1, metric.uuidString, -1, Self.transient)
                sqlite3_step(statement)
                sqlite3_finalize(statement)
                continuation.resume()
            }
        }
    }

    // MARK: - Private, all on `queue`

    private func readRecords(metric: UUID, limit: Int) -> [MetricRecord] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        let sql = """
                  SELECT id, captured_at, payload FROM occurrences
                  WHERE metric = ? ORDER BY captured_at DESC LIMIT ?;
                  """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, metric.uuidString, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var rows: [MetricRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let captured = sqlite3_column_double(statement, 1)
            guard let raw = sqlite3_column_text(statement, 2) else { continue }
            let json = String(cString: raw)
            let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: String] ?? [:]
            rows.append(MetricRecord(id: id,
                                     capturedAt: Date(timeIntervalSince1970: captured),
                                     values: values))
        }
        return rows
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK
        if let error {
            NSLog("Gruppen: sqlite — %@", String(cString: error))
            sqlite3_free(error)
        }
        return ok
    }
}
