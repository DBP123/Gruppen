import Foundation

/// Runs code blocks — shell, Python, JavaScript, AppleScript, JXA — the same
/// way for every language.
///
/// **In.** The inputs as JSON: on standard input, in a file named by
/// `GRUPPEN_INPUT_FILE`, and inline in `GRUPPEN_INPUT`. Each scalar input also
/// as `GRUPPEN_IN_<NAME>`, and every file input's paths as the arguments
/// (`"$@"`, `sys.argv[1:]`, `argv`) — as argv, never spliced into the source,
/// so a file named `; rm -rf ~` is a file name.
///
/// **Out.** A JSON object written to `$GRUPPEN_OUTPUT`, which the helpers do
/// for you: `out name value` in shell, `gruppen.out(name=value)` in Python,
/// `gruppen.out({name: value})` in JavaScript. Each output port reads its
/// key, converted to the port's type. What the code prints is Output; the
/// whole object is Result.
///
/// **The helpers are not pasted into your source.** Python and JavaScript
/// run through a small bootstrap that defines `gruppen` and then runs your
/// file, so an error says "line 3" and means line 3.
struct CodeRunner: CodeExecuting {
    func run(_ spec: CodeSpec, inputs: [String: Value], definition: BlockDefinition,
             context: RunContext, log: @escaping @Sendable (String, Bool) -> Void) async throws -> [String: Value] {
        guard !spec.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlowError.notSetUp("There's no code to run")
        }
        let shell = await UserEnvironment.shared.current()
        var environment = shell.variables
        for (key, value) in context.environment { environment[key] = value }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gruppen-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let inputJSON = Value.record(inputs).jsonText()
        let inputFile = scratch.appendingPathComponent("input.json")
        let outputFile = scratch.appendingPathComponent("output.json")
        let linesFile = scratch.appendingPathComponent("output.lines")
        try inputJSON.write(to: inputFile, atomically: true, encoding: .utf8)
        environment["GRUPPEN_INPUT"] = inputJSON
        environment["GRUPPEN_INPUT_FILE"] = inputFile.path
        environment["GRUPPEN_OUTPUT"] = outputFile.path
        environment["GRUPPEN_OUTPUT_LINES"] = linesFile.path
        environment["GRUPPEN_FLOW"] = context.flowName
        for (name, value) in inputs {
            environment["GRUPPEN_IN_\(Secrets.variable(for: name))"] = Self.environmentText(value)
        }
        let files = inputs.values.flatMap { $0.urls ?? [] }.map(\.path)

        let script = scratch.appendingPathComponent("script.\(spec.language.fileExtension)")
        try spec.source.write(to: script, atomically: true, encoding: .utf8)

        let launch = try await command(for: spec, script: script, scratch: scratch,
                                       environment: &environment, log: log)
        let result = try await Tool.run(launch.path, launch.arguments + files,
                                        in: FileManager.default.homeDirectoryForCurrentUser,
                                        environment: environment, input: Data(inputJSON.utf8),
                                        timeout: context.remaining,
                                        onLine: { line, isError in
                                            guard !line.hasPrefix("gruppen:") else { return }
                                            // "script.py", not a temporary folder's path to it.
                                            let shown = line.replacingOccurrences(of: scratch.path + "/", with: "")
                                            log(Secrets.mask(shown, context.masked), isError)
                                        })
        if Task.isCancelled { throw FlowError.cancelled }
        if result.timedOut { throw FlowError.timedOut(Int(context.remaining ?? 0)) }
        guard result.status == 0 else { throw CodeFailure(result, script: script, masked: context.masked) }

        let produced = Self.read(output: outputFile, lines: linesFile)
        return Self.outputs(for: definition, produced: produced, printed: result.output)
    }

    /// A value as one environment variable: files a path per line, lists
    /// and records as JSON, the rest as text.
    static func environmentText(_ value: Value) -> String {
        switch value {
        case .files(let urls): return urls.map(\.path).joined(separator: "\n")
        case .list, .record: return value.jsonText()
        default: return value.coerced(to: .text)?.text ?? ""
        }
    }

    // MARK: Launching

    private struct Launch { var path: String; var arguments: [String] }

    private func command(for spec: CodeSpec, script: URL, scratch: URL,
                         environment: inout [String: String],
                         log: @escaping @Sendable (String, Bool) -> Void) async throws -> Launch {
        let path = environment["PATH"] ?? UserEnvironment.fallbackPath
        guard var interpreter = Interpreters.resolve(spec, path: path) else {
            throw FlowError.failed(Self.missing(spec.language))
        }
        switch spec.language {
        case .zsh, .bash:
            let prelude = scratch.appendingPathComponent("prelude.sh")
            try Bootstrap.shell.write(to: prelude, atomically: true, encoding: .utf8)
            environment["BASH_ENV"] = prelude.path
            // zsh reads ZDOTDIR/.zshenv for non-interactive shells.
            if spec.language == .zsh {
                let dot = scratch.appendingPathComponent("zdot", isDirectory: true)
                try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
                try "source \"\(prelude.path)\"\n".write(to: dot.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
                environment["ZDOTDIR"] = dot.path
            }
            return Launch(path: interpreter, arguments: [script.path])

        case .python:
            if !spec.packages.isEmpty {
                interpreter = try await PackageEnvironments.shared.python(interpreter, packages: spec.packages,
                                                                          environment: environment, log: log)
            }
            let bootstrap = scratch.appendingPathComponent("gruppen_bootstrap.py")
            try Bootstrap.python.write(to: bootstrap, atomically: true, encoding: .utf8)
            environment["PYTHONUNBUFFERED"] = "1"
            return Launch(path: interpreter, arguments: [bootstrap.path, script.path])

        case .javascript:
            if interpreter == Interpreters.javaScriptHelper {
                guard spec.packages.isEmpty else {
                    throw FlowError.failed("Packages need Node.js. Install it (brew install node), then pick it in Setup.")
                }
                return Launch(path: interpreter, arguments: [script.path])
            }
            if !spec.packages.isEmpty {
                let modules = try await PackageEnvironments.shared.node(interpreter, packages: spec.packages,
                                                                        environment: environment, log: log)
                environment["NODE_PATH"] = modules
            }
            let bootstrap = scratch.appendingPathComponent("gruppen_bootstrap.js")
            try Bootstrap.javaScript.write(to: bootstrap, atomically: true, encoding: .utf8)
            return Launch(path: interpreter, arguments: [bootstrap.path, script.path])

        case .applescript:
            return Launch(path: interpreter, arguments: [script.path])
        case .jxa:
            return Launch(path: interpreter, arguments: ["-l", "JavaScript", script.path])
        }
    }

    static func missing(_ language: CodeLanguage) -> String {
        switch language {
        case .python: return "Python 3 isn't installed. Install it (brew install python, or from python.org), then pick it in Setup."
        case .javascript: return "No JavaScript runner was found."
        case .bash: return "bash wasn't found."
        default: return "\(language.label) isn't available on this Mac."
        }
    }

    // MARK: Results

    /// The JSON object the code handed on, and any `out name value` lines.
    static func read(output: URL, lines: URL) -> [String: Any] {
        var produced: [String: Any] = [:]
        if let data = try? Data(contentsOf: output),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            produced = object
        }
        if let text = try? String(contentsOf: lines, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = parts.first, !key.isEmpty else { continue }
                let value = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "\\n", with: "\n") : ""
                produced[String(key)] = value
            }
        }
        return produced
    }

    /// Each output port from what the code produced: its key, converted to
    /// the port's type. `output` falls back to what was printed and `result`
    /// to the whole object.
    static func outputs(for definition: BlockDefinition, produced: [String: Any], printed: String) -> [String: Value] {
        var outputs: [String: Value] = [:]
        for port in definition.outputs {
            if let raw = produced[port.name] {
                outputs[port.name] = Value(json: raw, as: port.type) ?? Value(json: raw)
            } else if port.name == "output" {
                outputs["output"] = .text(printed.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if port.name == "result" {
                outputs["result"] = produced.isEmpty ? .nothing : Value(json: produced)
            }
        }
        return outputs
    }
}

/// A script that exited with an error: its last words, which line, and —
/// when macOS refused it something — what to do about that.
struct CodeFailure: LocalizedError, Sendable {
    let message: String
    let line: Int?

    init(_ result: Tool.Result, script: URL, masked: [String]) {
        let said = Secrets.mask(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines), masked)
        line = Self.line(in: said, script: script.lastPathComponent)
        // The last thing it said is the error itself — Python's "ValueError:
        // nope" after its traceback, the shell's "command not found". The
        // whole of it is in the console.
        let last = said.split(separator: "\n").last.map(String.init) ?? ""
        if let explained = Permissions.explain(said) {
            message = explained
        } else if last.isEmpty {
            message = "Exited with code \(result.status)"
        } else {
            message = last.replacingOccurrences(of: script.path, with: script.lastPathComponent)
        }
    }

    var errorDescription: String? { line.map { "Line \($0): \(message)" } ?? message }

    /// The line an interpreter blamed: Python's `File "…script.py", line 3`,
    /// zsh's `script.sh:3:`, Node's `script.js:3`, osascript's `script.applescript:12:20:`.
    static func line(in text: String, script: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: script)
        let patterns = ["\(escaped)\", line (\\d+)", "\(escaped):(\\d+)", "\(escaped) line (\\d+)"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if let match = matches.last, let range = Range(match.range(at: 1), in: text) { return Int(text[range]) }
        }
        return nil
    }
}

// MARK: - Packages

/// Python and npm packages, installed once per interpreter and package list
/// into a folder Gruppen keeps, and reused by every block that asks for the
/// same list.
actor PackageEnvironments {
    static let shared = PackageEnvironments()

    private var preparing: [String: Task<String, Error>] = [:]

    static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Gruppen/Environments", isDirectory: true)
    }

    static func key(_ interpreter: String, _ packages: [String]) -> String {
        // FNV-1a: stable across launches, unlike `hashValue`, and only ever a
        // folder name — not a security boundary.
        let canonical = ([interpreter] + packages.map { $0.lowercased() }.sorted()).joined(separator: "\n")
        let hash = canonical.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// The environment's own python3, built first if it has to be.
    func python(_ interpreter: String, packages: [String], environment: [String: String],
                log: @escaping @Sendable (String, Bool) -> Void) async throws -> String {
        let folder = Self.root.appendingPathComponent("python-\(Self.key(interpreter, packages))", isDirectory: true)
        let python = folder.appendingPathComponent("bin/python3").path
        try await prepare(folder, log: log) {
            log("Preparing a Python environment for \(packages.joined(separator: ", "))…", false)
            try await Self.step(interpreter, ["-m", "venv", folder.path], environment, log)
            try await Self.step(python, ["-m", "pip", "install", "--disable-pip-version-check", "--quiet"] + packages,
                                environment, log)
        }
        return python
    }

    /// The `node_modules` folder holding `packages`, installed first if it
    /// has to be.
    func node(_ interpreter: String, packages: [String], environment: [String: String],
              log: @escaping @Sendable (String, Bool) -> Void) async throws -> String {
        let folder = Self.root.appendingPathComponent("node-\(Self.key(interpreter, packages))", isDirectory: true)
        let npm = (interpreter as NSString).deletingLastPathComponent + "/npm"
        try await prepare(folder, log: log) {
            guard FileManager.default.isExecutableFile(atPath: npm) else {
                throw FlowError.failed("npm wasn't found beside \(interpreter)")
            }
            log("Installing \(packages.joined(separator: ", "))…", false)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await Self.step(npm, ["install", "--prefix", folder.path, "--no-audit", "--no-fund", "--silent"] + packages,
                                environment, log)
        }
        return folder.appendingPathComponent("node_modules").path
    }

    /// Runs `build` once per folder, however many runs ask at the same time;
    /// a marker file says it finished, so a half-built folder is rebuilt.
    private func prepare(_ folder: URL, log: @escaping @Sendable (String, Bool) -> Void,
                         build: @escaping @Sendable () async throws -> Void) async throws {
        let marker = folder.appendingPathComponent(".gruppen-ready")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        if let pending = preparing[folder.path] { _ = try await pending.value; return }
        let task = Task<String, Error> {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try await build()
            try Data().write(to: marker)
            return folder.path
        }
        preparing[folder.path] = task
        defer { preparing[folder.path] = nil }
        do {
            _ = try await task.value
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func step(_ tool: String, _ arguments: [String], _ environment: [String: String],
                             _ log: @escaping @Sendable (String, Bool) -> Void) async throws {
        let result = try await Tool.run(tool, arguments, environment: environment, timeout: 600,
                                        onLine: { line, isError in log(line, isError) })
        guard result.succeeded else { throw FlowError.failed(result.failure) }
    }

    /// Every environment, and how much room they take.
    static func list() -> [(name: String, bytes: Int64)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.map { folder in
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            var bytes: Int64 = 0
            while let file = walker?.nextObject() as? URL {
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return (folder.lastPathComponent, bytes)
        }
    }

    static func removeAll() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Bootstraps

/// The few lines that give each language its `gruppen` helpers.
enum Bootstrap {
    static let shell = #"""
    # Gruppen: hands a value on. `out name value…`
    out() {
      local key="$1"; shift
      local value="$*"
      printf '%s\t%s\n' "$key" "${value//$'\n'/\\n}" >> "$GRUPPEN_OUTPUT_LINES"
    }
    """#

    static let python = #"""
    import json, os, runpy, sys

    class _Gruppen:
        """What came in, and a way to hand values on."""
        def __init__(self):
            with open(os.environ["GRUPPEN_INPUT_FILE"]) as f:
                self.inputs = json.load(f)
            self._out = {}

        def files(self, name="input"):
            """An input's paths as a list, whether it held one file or many."""
            value = self.inputs.get(name)
            if value is None:
                return []
            return value if isinstance(value, list) else [value]

        def out(self, **values):
            """gruppen.out(zip=path, count=3) — each key becomes an output."""
            self._out.update(values)
            with open(os.environ["GRUPPEN_OUTPUT"], "w") as f:
                json.dump(self._out, f, default=str)

    import builtins
    builtins.gruppen = _Gruppen()
    script = sys.argv[1]
    sys.argv = [script] + sys.argv[2:]
    try:
        runpy.run_path(script, run_name="__main__")
    except SystemExit:
        raise
    except BaseException as error:
        # The traceback from your code down, without this file's frames.
        import traceback
        frames = error.__traceback__
        while frames is not None and frames.tb_frame.f_code.co_filename != script:
            frames = frames.tb_next
        traceback.print_exception(type(error), error, frames or error.__traceback__)
        sys.exit(1)
    """#

    static let javaScript = #"""
    const fs = require("fs");
    const path = require("path");
    const outputs = {};
    globalThis.gruppen = {
      inputs: JSON.parse(fs.readFileSync(process.env.GRUPPEN_INPUT_FILE, "utf8")),
      files(name = "input") {
        const value = this.inputs[name];
        return value == null ? [] : Array.isArray(value) ? value : [value];
      },
      out(values) {
        Object.assign(outputs, values);
        fs.writeFileSync(process.env.GRUPPEN_OUTPUT, JSON.stringify(outputs));
      },
    };
    const script = path.resolve(process.argv[2]);
    process.argv.splice(1, 2, script);
    require(script);
    """#
}
