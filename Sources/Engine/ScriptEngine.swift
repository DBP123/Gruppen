import Foundation

/// What a run produced.
struct ScriptRun: Equatable {
    var output: String
    var errorOutput: String
    var exitCode: Int32
    var duration: TimeInterval

    var succeeded: Bool { exitCode == 0 }

    var transcript: String {
        [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

}

enum ScriptError: LocalizedError, Equatable {
    case noSource
    case interpreterMissing(String, String)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case exited(Int32, String)
    case badWebhookURL(String)

    var errorDescription: String? {
        switch self {
        case .noSource:
            return "This script is empty."
        case .interpreterMissing(let name, let path):
            return "\(name) was not found at \(path)."
        case .launchFailed(let message):
            return "The script could not be started — \(message)"
        case .timedOut(let seconds):
            return "Still running after \(Int(seconds))s. Stopped."
        case .exited(let code, let message):
            return message.isEmpty ? "Exited with code \(code)." : message
        case .badWebhookURL(let raw):
            return raw.isEmpty ? "No webhook URL set." : "\(raw) is not a valid http(s) URL."
        }
    }
}

/// Spawns scripts. Nothing else.
///
/// **Dormant by construction.** There is no timer, no queue drain and no
/// watcher here: `run` is called from an event and does nothing before or after.
/// The only clock involved is the watchdog that stops a runaway script, and it
/// exists for the duration of that run alone.
///
/// **Never on the main thread.** Everything is `nonisolated`; the process is
/// spawned and both pipes are drained on background queues, and only the
/// finished `ScriptRun` crosses back.
enum ScriptExecutionEngine {
    /// How long a script gets before it is killed.
    static let timeout: TimeInterval = 60

    /// Whether the interpreter this action needs is actually installed.
    nonisolated static func interpreterExists(_ interpreter: ScriptAction.Interpreter) -> Bool {
        FileManager.default.isExecutableFile(atPath: interpreter.path)
    }

    /// Runs `action` with `paths` as its arguments.
    ///
    /// Paths are passed as **argv**, never spliced into the source: the shell
    /// sees `"$1"`, `"$2"`, `"$@"`, so a file named `; echo hi` is a file name
    /// and not a command. Preset parameters travel as environment variables for
    /// the same reason.
    nonisolated static func run(_ action: ScriptAction,
                                paths: [URL] = [],
                                timeout: TimeInterval = timeout) async throws -> ScriptRun {
        if action.kind == .webhook { return try await callWebhook(action, paths: paths, timeout: timeout) }
        let source = action.effectiveSource
        guard !source.isEmpty else { throw ScriptError.noSource }
        let interpreter = action.effectiveInterpreter
        guard interpreterExists(interpreter) else {
            throw ScriptError.interpreterMissing(interpreter.label, interpreter.path)
        }

        let scriptURL = try write(source, extension: interpreter.fileExtension)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter.path)
        process.arguments = interpreter.leadingArguments + [scriptURL.path] + paths.map(\.path)
        process.environment = environment(for: action)

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Drained as it arrives. Waiting first and reading after deadlocks the
        // moment a script writes more than one pipe buffer holds — measured at
        // roughly 64KB, and a chatty script passes that in a heartbeat.
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { collector.appendOutput($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { collector.appendError($0.availableData) }

        let started = Date()
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            collector.markTimedOut()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
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
        // Whatever landed between the last callback and exit.
        collector.appendOutput(out.fileHandleForReading.availableData)
        collector.appendError(err.fileHandleForReading.availableData)

        if collector.didTimeOut { throw ScriptError.timedOut(timeout) }

        let run = ScriptRun(output: collector.output,
                            errorOutput: collector.errorOutput,
                            exitCode: status,
                            duration: Date().timeIntervalSince(started))
        guard run.succeeded else {
            throw ScriptError.exited(status, run.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return run
    }

    // MARK: - Plumbing

    /// A deliberately small environment. Inheriting the app's own would hand a
    /// script whatever launchd happened to give Gruppen, which is neither
    /// predictable nor the user's shell.
    private nonisolated static func environment(for action: ScriptAction) -> [String: String] {
        [
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory()
        ]
    }

    /// The webhook action. No subprocess: `URLSession` already does this, and
    /// shelling out to curl would mean a second thing to go wrong.
    ///
    /// A POST carries the incoming paths as JSON so the receiver knows what
    /// triggered it; a GET carries nothing but the request itself.
    private nonisolated static func callWebhook(_ action: ScriptAction,
                                                paths: [URL],
                                                timeout: TimeInterval) async throws -> ScriptRun {
        guard let url = URL(string: action.webhookURL), url.scheme?.hasPrefix("http") == true else {
            throw ScriptError.badWebhookURL(action.webhookURL)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = action.httpMethod.label
        if action.httpMethod == .post {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = ["paths": paths.map(\.path)]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            let duration = Date().timeIntervalSince(started)
            guard (200..<300).contains(status) else {
                throw ScriptError.exited(Int32(status),
                                         "HTTP \(status)\n" + body.prefix(500))
            }
            return ScriptRun(output: "HTTP \(status)" + (body.isEmpty ? "" : "\n" + body),
                             errorOutput: "",
                             exitCode: 0,
                             duration: duration)
        } catch let error as ScriptError {
            throw error
        } catch {
            throw ScriptError.launchFailed(error.localizedDescription)
        }
    }

    private nonisolated static func write(_ source: String, extension ext: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gruppen-script-\(UUID().uuidString).\(ext)")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            // Owner-only: this is about to be executed, and /tmp is shared.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw ScriptError.launchFailed(error.localizedDescription)
        }
        return url
    }
}

/// Thread-safe accumulation of two pipes drained from arbitrary queues.
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

/// Guarantees a continuation resumes exactly once, whichever of the launch
/// failure and the termination handler reaches it first.
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
