import Foundation

/// The one way Gruppen runs a command-line tool.
///
/// Both pipes are drained while the tool runs. Waiting first and reading after
/// deadlocks the moment a tool writes more than a pipe buffer holds — measured
/// at roughly 64KB — because it blocks on the write while we wait on its exit.
///
/// The wait is the termination handler resumed through a continuation, never
/// `waitUntilExit()`: that blocks whichever thread calls it, and inside a task
/// that is one of the cooperative pool's few threads, held for as long as the
/// tool takes.
enum Tool {
    struct Result: Sendable {
        let tool: String
        let status: Int32
        let output: String
        let errorOutput: String
        let timedOut: Bool

        var succeeded: Bool { status == 0 && !timedOut }

        /// What went wrong in the tool's own words, or its exit status when it
        /// said nothing.
        var failure: String {
            let said = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if timedOut { return "\(tool) was stopped after running too long" }
            return said.isEmpty ? "\(tool) failed (exit \(status))" : said
        }
    }

    /// Runs `path` with `arguments` and returns once it has exited. Throws only
    /// when the tool could not be started at all; a non-zero exit is in the
    /// result, for the caller to word.
    static func run(_ path: String, _ arguments: [String],
                    in directory: URL? = nil,
                    environment: [String: String]? = nil,
                    timeout: TimeInterval? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { collector.appendOutput($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collector.appendError($0.availableData) }

        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            collector.markTimedOut()
            process.terminate()
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }
        defer {
            watchdog.cancel()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            // Set before `run()`: a tool that exits at once can call back before
            // `run()` returns.
            process.terminationHandler = { process in
                guard resumed.claim() else { return }
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // Nothing launched, so the handler never fires.
                if resumed.claim() { continuation.resume(throwing: error) }
            }
        }

        // Whatever landed between the last callback and the exit.
        collector.appendOutput(out.fileHandleForReading.availableData)
        collector.appendError(err.fileHandleForReading.availableData)
        return Result(tool: (path as NSString).lastPathComponent,
                      status: status,
                      output: collector.output,
                      errorOutput: collector.errorOutput,
                      timedOut: collector.didTimeOut)
    }
}

/// Two pipes drained from arbitrary queues. Every field is behind `lock`.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()
    private var timedOut = false

    func appendOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); outputData.append(data); lock.unlock()
    }

    func appendError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); errorData.append(data); lock.unlock()
    }

    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }

    var output: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    var errorOutput: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: errorData, encoding: .utf8) ?? ""
    }
}

/// Resumes a continuation exactly once, whichever of the launch failure and the
/// termination handler gets there first. `done` is behind `lock`.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
