import Foundation
import Security

/// The environment a script expects: the one Terminal gives it.
///
/// Gruppen is started by launchd, whose PATH is `/usr/bin:/bin:/usr/sbin:/sbin`
/// — no Homebrew, no pyenv, no nvm, none of your exports. The single most
/// common reason a script that works in Terminal fails elsewhere. So the
/// login shell is asked once, interactively, for the environment it builds,
/// and that is what every code block gets. If asking fails — a shell that
/// hangs on a prompt, a broken rc file — the fixed PATH every Mac has is the
/// fallback, and Setup says so.
actor UserEnvironment {
    static let shared = UserEnvironment()

    struct Snapshot: Sendable {
        var variables: [String: String]
        var capturedAt: Date
        /// Nil when the shell answered; otherwise why the fallback is in use.
        var problem: String?
    }

    private var snapshot: Snapshot?
    private var capturing: Task<Snapshot, Never>?

    /// The captured environment, captured now if it never has been.
    func current() async -> Snapshot {
        if let snapshot { return snapshot }
        if let capturing { return await capturing.value }
        let task = Task { await Self.capture() }
        capturing = task
        let result = await task.value
        snapshot = result
        capturing = nil
        return result
    }

    /// Asks the shell again — after installing something, or editing an rc
    /// file.
    @discardableResult
    func refresh() async -> Snapshot {
        snapshot = nil
        return await current()
    }

    static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private static let begin = "__GRUPPEN_ENV_BEGIN__"
    private static let end = "__GRUPPEN_ENV_END__"

    static func capture() async -> Snapshot {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // A login shell, with the interactive rc file sourced by hand: nvm and
        // pyenv live in .zshrc. Not `-i` — an interactive shell started
        // without a terminal, as Gruppen starts it, waits on one that never
        // comes. The markers fence off whatever the rc file prints.
        let rc = shell.hasSuffix("bash") ? "~/.bashrc" : (shell.hasSuffix("zsh") ? "${ZDOTDIR:-$HOME}/.zshrc" : "")
        let source = rc.isEmpty ? "" : "[ -f \(rc) ] && . \(rc) >/dev/null 2>&1 </dev/null; "
        let command = source + "printf '\(begin)\\0'; /usr/bin/env -0; printf '\(end)'"
        let base = baseEnvironment()
        do {
            let result = try await Tool.run(shell, ["-lc", command], environment: base, timeout: 6)
            guard result.succeeded || result.output.contains(end),
                  let parsed = parse(result.output) else {
                return Snapshot(variables: fallback(), capturedAt: Date(),
                                problem: result.timedOut ? "Your shell took too long to start" : "Your shell didn't answer")
            }
            return Snapshot(variables: tidy(parsed, base: base), capturedAt: Date(), problem: nil)
        } catch {
            return Snapshot(variables: fallback(), capturedAt: Date(), problem: error.localizedDescription)
        }
    }

    /// The `env -0` block between the markers, as a dictionary.
    static func parse(_ output: String) -> [String: String]? {
        guard let start = output.range(of: begin + "\0"), let stop = output.range(of: end, range: start.upperBound..<output.endIndex)
        else { return nil }
        var variables: [String: String] = [:]
        for entry in output[start.upperBound..<stop.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            variables[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return variables.isEmpty ? nil : variables
    }

    /// What a shell session adds that means nothing to a script run from
    /// Gruppen — its working directory, its depth, its terminal.
    private static let sessionOnly: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM_SESSION_ID", "TERM_PROGRAM",
                                                   "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID", "COLORTERM",
                                                   "SECURITYSESSIONID", "Apple_PubSub_Socket_Render", "PS1", "PROMPT"]

    static func tidy(_ variables: [String: String], base: [String: String]) -> [String: String] {
        var result = base
        for (key, value) in variables where !sessionOnly.contains(key) { result[key] = value }
        return result
    }

    static func baseEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": inherited["SHELL"] ?? "/bin/zsh",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": inherited["PATH"] ?? fallbackPath,
            "TERM": "dumb",
        ]
    }

    static func fallback() -> [String: String] {
        var variables = baseEnvironment()
        variables["PATH"] = fallbackPath
        return variables
    }
}

// MARK: - Interpreters

/// The programs that run each language, found on this Mac.
enum Interpreters {
    struct Found: Hashable, Sendable, Identifiable {
        var path: String
        /// "Homebrew", "pyenv", "System"…
        var origin: String
        var id: String { path }
    }

    /// Candidates for `language`, best first: what the shell's PATH finds,
    /// then the usual places.
    static func available(for language: CodeLanguage, path: String) -> [Found] {
        let names: [String]
        let fixed: [String]
        switch language {
        case .zsh: return [Found(path: "/bin/zsh", origin: "System")]
        case .bash:
            names = ["bash"]; fixed = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"]
        case .python:
            names = ["python3"]
            fixed = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                     (NSHomeDirectory() as NSString).appendingPathComponent(".pyenv/shims/python3"),
                     "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"]
        case .javascript:
            names = ["node"]; fixed = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        case .applescript, .jxa: return [Found(path: "/usr/bin/osascript", origin: "System")]
        }
        var seen: Set<String> = []
        var found: [Found] = []
        let onPath = path.split(separator: ":").flatMap { directory in names.map { "\(directory)/\($0)" } }
        for candidate in onPath + fixed where seen.insert(candidate).inserted {
            guard FileManager.default.isExecutableFile(atPath: candidate), usable(candidate) else { continue }
            found.append(Found(path: candidate, origin: origin(of: candidate)))
        }
        if language == .javascript, let helper = javaScriptHelper {
            found.append(Found(path: helper, origin: "Built in (no packages)"))
        }
        return found
    }

    /// `/usr/bin/python3` is a stub that offers to install the developer
    /// tools when they are missing — a dialog out of nowhere, mid-flow. It is
    /// only offered when the tools are there to answer it.
    private static func usable(_ path: String) -> Bool {
        guard path == "/usr/bin/python3" else { return true }
        return FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3")
    }

    private static func origin(of path: String) -> String {
        if path.hasPrefix("/opt/homebrew") || path.hasPrefix("/usr/local") { return "Homebrew" }
        if path.contains(".pyenv") { return "pyenv" }
        if path.contains(".nvm") { return "nvm" }
        if path.contains("Python.framework") { return "python.org" }
        if path.hasPrefix("/usr/bin") || path.hasPrefix("/bin") { return "System" }
        return (path as NSString).deletingLastPathComponent
    }

    /// The JavaScriptCore runner inside the app, for JavaScript with nothing
    /// installed.
    static var javaScriptHelper: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gruppen-js").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The interpreter chosen in Setup for `language`, if any.
    static func chosen(for language: CodeLanguage) -> String? {
        UserDefaults.standard.string(forKey: "flows.interpreter.\(language.rawValue)").flatMap { $0.isEmpty ? nil : $0 }
    }

    static func choose(_ path: String?, for language: CodeLanguage) {
        UserDefaults.standard.set(path, forKey: "flows.interpreter.\(language.rawValue)")
    }

    /// What runs `spec`: the block's own choice, Setup's, then the best found.
    static func resolve(_ spec: CodeSpec, path: String) -> String? {
        if let own = spec.interpreter, FileManager.default.isExecutableFile(atPath: own) { return own }
        if let chosen = chosen(for: spec.language), FileManager.default.isExecutableFile(atPath: chosen) { return chosen }
        return available(for: spec.language, path: path).first?.path
    }
}

// MARK: - Secrets

/// API keys and passwords flows use, in the Keychain. A flow names the
/// secrets it wants; their values are read at run time, handed to code as
/// environment variables, and blanked out of the console and saved runs.
/// Never written to the library file.
enum Secrets {
    private static let service = "Gruppen flow secret"

    static func names() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func value(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ name: String, _ value: String) -> Bool {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        let data = Data(value.utf8)
        if SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var add = match
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        SecItemDelete(match as CFDictionary)
    }

    /// A name as an environment variable: `openai key` → `OPENAI_KEY`.
    static func variable(for name: String) -> String {
        let cleaned = name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let joined = String(cleaned)
        return joined.first?.isNumber == true ? "_" + joined : joined
    }

    /// `text` with every secret value in `values` blanked.
    static func mask(_ text: String, _ values: [String]) -> String {
        values.filter { $0.count >= 3 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "••••") }
    }
}
