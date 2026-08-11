import Foundation

/// What a run produced.
struct ScriptRun: Equatable {
    var output: String
    var errorOutput: String
    var exitCode: Int32
    var duration: TimeInterval

    var succeeded: Bool { exitCode == 0 }

    /// Everything worth showing in the console, in the order it happened as
    /// closely as two separate pipes allow.
    var transcript: String {
        [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum ScriptError: LocalizedError, Equatable {
    case noSource
    case interpreterMissing(String, [String])
    case launchFailed(String)
    case timedOut(TimeInterval)
    case exited(Int32, String)

    var errorDescription: String? {
        switch self {
        case .noSource:
            return "This script is empty."
        case .interpreterMissing(let name, let paths):
            return "\(name) was not found. Looked in \(paths.joined(separator: ", "))."
        case .launchFailed(let message):
            return "The script could not be started — \(message)"
        case .timedOut(let seconds):
            return "The script was still running after \(Int(seconds))s and was stopped."
        case .exited(let code, let message):
            return message.isEmpty ? "The script exited with code \(code)." : message
        }
    }
}

/// Runs a `ScriptConfig` against a set of files.
///
/// **Dormant by construction.** There is no timer, no queue drain and no
/// watcher: `run` is called from a drop and does nothing before or after. The
/// only clock involved is the watchdog that stops a runaway script, and it
/// exists only for the duration of a run.
///
/// **Never on the main thread.** Everything below is `nonisolated`; the process
/// is spawned and its pipes are drained on background queues, and only the
/// finished `ScriptRun` crosses back.
enum ScriptExecutionEngine {
    /// A script gets this long before it is killed. Long enough for real work,
    /// short enough that a stuck process cannot sit there forever.
    static let timeout: TimeInterval = 60

    /// Where the interpreter actually is, or nil if it is not installed.
    nonisolated static func resolveInterpreter(_ interpreter: ScriptConfig.Interpreter) -> String? {
        interpreter.candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the script with `paths` as its arguments.
    ///
    /// Paths are passed as **argv**, never spliced into the source: the shell
    /// sees `"$1"`, `"$2"`, `"$@"`, and a file called `; rm -rf ~` is a file
    /// called `; rm -rf ~`. The preset's own parameters travel as environment
    /// variables for the same reason.
    nonisolated static func run(_ config: ScriptConfig,
                                paths: [URL],
                                timeout: TimeInterval = timeout) async throws -> ScriptRun {
        let source = config.effectiveSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw ScriptError.noSource }

        guard let interpreterPath = resolveInterpreter(config.interpreter) else {
            throw ScriptError.interpreterMissing(config.interpreter.label,
                                                 config.interpreter.candidatePaths)
        }

        let scriptURL = try write(source, extension: config.interpreter.fileExtension)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreterPath)
        process.arguments = config.interpreter.leadingArguments + [scriptURL.path] + paths.map(\.path)
        process.environment = environment(for: config)

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Drained as it arrives. Waiting first and reading after deadlocks the
        // moment a script writes more than a pipe buffer holds.
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            collector.appendOutput(handle.availableData)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            collector.appendError(handle.availableData)
        }

        let started = Date()
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            collector.markTimedOut()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let finished: Int32 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            process.terminationHandler = { process in
                guard resumed.claim() else { return }
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                if resumed.claim() {
                    continuation.resume(throwing: ScriptError.launchFailed(error.localizedDescription))
                }
            }
        }

        watchdog.cancel()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Whatever landed between the last readability callback and exit.
        collector.appendOutput(out.fileHandleForReading.availableData)
        collector.appendError(err.fileHandleForReading.availableData)

        if collector.didTimeOut { throw ScriptError.timedOut(timeout) }

        let result = ScriptRun(output: collector.output,
                               errorOutput: collector.errorOutput,
                               exitCode: finished,
                               duration: Date().timeIntervalSince(started))
        guard result.succeeded else {
            throw ScriptError.exited(finished, result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    // MARK: - Plumbing

    /// A deliberately small environment. Inheriting the app's own would hand a
    /// script whatever launchd happened to give Gruppen, which is neither
    /// predictable nor the user's shell.
    private nonisolated static func environment(for config: ScriptConfig) -> [String: String] {
        var environment = [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory()
        ]
        for (key, value) in config.environment where !value.isEmpty {
            environment[key] = value
        }
        return environment
    }

    private nonisolated static func write(_ source: String, extension ext: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gruppen-script-\(UUID().uuidString).\(ext)")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            // Owner-only: the script is about to be executed, and /tmp is shared.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw ScriptError.launchFailed(error.localizedDescription)
        }
        return url
    }
}

/// Thread-safe accumulation of two pipes being drained from arbitrary queues.
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

    func markTimedOut() {
        lock.lock(); timedOut = true; lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    var output: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    var errorOutput: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: errorData, encoding: .utf8) ?? ""
    }
}

/// Guarantees a continuation is resumed exactly once, whichever of the launch
/// failure and the termination handler gets there first.
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
