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
    /// The most of each stream a result keeps, in bytes. A caller that needs
    /// all of a tool's output treats a result this long as incomplete.
    static let outputLimit = 8 * 1024 * 1024

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

    /// Runs `path` with `arguments` and returns once it has exited.
    ///
    /// Every caller passes file paths as absolute paths, so a file named
    /// `-rf` arrives as `/…/-rf` and can never be read as an option. Keep it
    /// that way: build arguments from `URL.path`, never from a bare name. Throws only
    /// when the tool could not be started at all; a non-zero exit is in the
    /// result, for the caller to word.
    ///
    /// `input` is written to the tool's standard input. `onLine` hears each
    /// complete line as it is printed — `true` for standard error — so a
    /// console can show a long job's progress while it runs. Cancelling the
    /// calling task stops the tool.
    static func run(_ path: String, _ arguments: [String],
                    in directory: URL? = nil,
                    environment: [String: String]? = nil,
                    input: Data? = nil,
                    timeout: TimeInterval? = nil,
                    onLine: (@Sendable (String, Bool) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collector = OutputCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { collector.appendOutput($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collector.appendError($0.availableData) }

        let handle = ProcessHandle(process)
        let watchdog = DispatchWorkItem {
            guard handle.isRunning else { return }
            collector.markTimedOut()
            handle.terminate()
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }
        defer {
            watchdog.cancel()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
                    return
                }
                if let stdin, let input {
                    // Off this thread: a tool that reads slowly would block the
                    // write once the pipe buffer is full.
                    let writer = stdin.fileHandleForWriting
                    DispatchQueue.global(qos: .utility).async {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
            }
        } onCancel: {
            handle.terminate()
        }

        // Whatever landed between the last callback and the exit.
        collector.appendOutput(out.fileHandleForReading.availableData)
        collector.appendError(err.fileHandleForReading.availableData)
        collector.flushLines()
        return Result(tool: (path as NSString).lastPathComponent,
                      status: status,
                      output: collector.output,
                      errorOutput: collector.errorOutput,
                      timedOut: collector.didTimeOut)
    }
}

/// A process, stoppable from the watchdog's queue and the cancellation
/// handler's thread.
///
/// Stopping is a request first and an order second. SIGTERM lets a tool clean
/// up; one that ignores it, or is stuck, gets SIGKILL `killAfter` seconds later.
/// SIGTERM alone left the caller waiting for an exit that might never come — a
/// timeout that didn't end anything.
private final class ProcessHandle: @unchecked Sendable {
    static let killAfter: TimeInterval = 3

    private let process: Process
    init(_ process: Process) { self.process = process }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killAfter) { [self] in
            // `isRunning` is this child's own state, so a pid the system has
            // since handed to someone else is never signalled.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Two pipes drained from arbitrary queues. Every field is behind `lock`.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()
    private var timedOut = false
    private let onLine: (@Sendable (String, Bool) -> Void)?
    /// Per stream, the bytes after the last newline, waiting for the rest of
    /// their line.
    private var pending: [Bool: Data] = [:]

    init(onLine: (@Sendable (String, Bool) -> Void)?) { self.onLine = onLine }

    func appendOutput(_ data: Data) { append(data, isError: false) }
    func appendError(_ data: Data) { append(data, isError: true) }

    /// Kept per stream. A tool that prints without end — or is made to — would
    /// otherwise grow this until the app runs out of memory. Past the limit,
    /// output is still read (so the pipe never blocks the tool) and dropped.
    static let limit = Tool.outputLimit

    private func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isError {
            if errorData.count < Self.limit { errorData.append(data.prefix(Self.limit - errorData.count)) }
        } else {
            if outputData.count < Self.limit { outputData.append(data.prefix(Self.limit - outputData.count)) }
        }
        var lines: [String] = []
        if onLine != nil {
            var buffer = (pending[isError] ?? Data()) + data
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer = Data(buffer[buffer.index(after: newline)...])
            }
            pending[isError] = buffer
        }
        lock.unlock()
        lines.forEach { onLine?($0, isError) }
    }

    /// A last line with no newline after it.
    func flushLines() {
        lock.lock()
        let rest = pending.compactMap { entry -> (String, Bool)? in
            entry.value.isEmpty ? nil : (String(decoding: entry.value, as: UTF8.self), entry.key)
        }
        pending = [:]
        lock.unlock()
        rest.forEach { onLine?($0.0, $0.1) }
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
