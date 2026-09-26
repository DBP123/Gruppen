import Foundation

/// Minimal test runner. Every assertion prints its evidence, because a test
/// that only prints PASS tells you nothing about what it actually saw.
final class Runner {
    static let shared = Runner()
    private(set) var passed = 0
    private(set) var failed = 0
    private var section = ""
    private var failures: [String] = []

    func begin(_ name: String) {
        section = name
        print("\n\u{001B}[1m── \(name)\u{001B}[0m")
    }

    func check(_ name: String, _ ok: Bool, _ evidence: @autoclosure () -> String = "") {
        let detail = evidence()
        if ok {
            passed += 1
            print("  PASS  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        } else {
            failed += 1
            failures.append("[\(section)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            print("  \u{001B}[31mFAIL\u{001B}[0m  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got), want \(want)")
    }

    /// For a fact about this machine that a test cannot force. Recorded, never
    /// counted as a pass — a skipped check is not a passing one.
    func note(_ text: String) { print("  ····  \(text)") }

    func summary() -> Int32 {
        print("\n\u{001B}[1m\(passed) passed, \(failed) failed\u{001B}[0m")
        for f in failures { print("  \u{001B}[31m✗\u{001B}[0m \(f)") }
        return failed == 0 ? 0 : 1
    }
}

let T = Runner.shared

/// A scratch directory that cleans itself up.
func withTempDir<R>(_ body: (URL) throws -> R) rethrows -> R {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gruppen-suite-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// Async twin of `withTempDir`, for tests that await a subprocess.
func withTempDirAsync<R>(_ body: (URL) async throws -> R) async rethrows -> R {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gruppen-suite-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}
