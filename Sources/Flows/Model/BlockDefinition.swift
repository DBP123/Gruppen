import Foundation

/// What a kind of block is: its face, its ports, and what running it means.
///
/// Built-in blocks are defined in Swift (`Catalog`). Blocks you make are
/// `CustomBlock`s, turned into definitions of exactly the same shape, so the
/// palette, the canvas and the runner never ask which kind they are holding.
struct BlockDefinition: Identifiable, Sendable {
    let id: String
    var title: String
    var category: BlockCategory
    var glyph: String
    var help: String
    /// How the block reads on the canvas, with `{port}` where an input sits:
    /// "Move {files} to {folder}". Inputs left out of it are set in the
    /// inspector.
    var phrase: String
    var shape: BlockShape
    var inputs: [Port]
    var outputs: [Port]
    var permissions: [Permission]
    var implementation: Implementation
    /// Shown in the palette's first section, before anything is searched.
    var isEssential: Bool

    init(_ id: String, _ title: String, category: BlockCategory, glyph: String,
         phrase: String? = nil, help: String = "", shape: BlockShape = .statement,
         inputs: [Port] = [], outputs: [Port] = [], permissions: [Permission] = [],
         essential: Bool = false, _ implementation: Implementation) {
        self.id = id
        self.title = title
        self.category = category
        self.glyph = glyph
        self.help = help
        self.phrase = phrase ?? title
        self.shape = shape
        self.inputs = inputs
        self.outputs = outputs
        self.permissions = permissions
        self.implementation = implementation
        self.isEssential = essential
    }

    func input(_ name: String) -> Port? { inputs.first { $0.name == name } }
    func output(_ name: String) -> Port? { outputs.first { $0.name == name } }

    var isHat: Bool { shape == .hat }

    /// The phrase split into words and input slots, in order.
    var phraseParts: [PhrasePart] { PhrasePart.parse(phrase, inputs: inputs) }
}

enum PhrasePart: Hashable, Sendable {
    case words(String)
    case input(String)

    static func parse(_ phrase: String, inputs: [Port]) -> [PhrasePart] {
        var parts: [PhrasePart] = []
        var rest = Substring(phrase)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let before = rest[..<open].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { parts.append(.words(before)) }
            let name = String(rest[rest.index(after: open)..<close])
            // A typo in a phrase shows as words rather than a slot to nowhere.
            parts.append(inputs.contains { $0.name == name } ? .input(name) : .words(name))
            rest = rest[rest.index(after: close)...]
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(.words(tail)) }
        return parts
    }
}

enum BlockShape: Hashable, Sendable {
    /// Starts a flow; sits on top, takes no blocks above it.
    case hat
    /// One step.
    case statement
    /// Holds a stack per slot, labelled: If's "then" and "else".
    case container([String])
}

enum BlockCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case triggers, files, text, logic, apps, system, gruppen, clipboard, web, code, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .triggers: return "When"
        case .files: return "Files"
        case .text: return "Text & data"
        case .logic: return "Logic"
        case .apps: return "Apps"
        case .system: return "System"
        case .gruppen: return "Gruppen"
        case .clipboard: return "Clipboard"
        case .web: return "Web"
        case .code: return "Code"
        case .custom: return "My blocks"
        }
    }

    var glyph: String {
        switch self {
        case .triggers: return "bolt"
        case .files: return "doc"
        case .text: return "textformat"
        case .logic: return "arrow.triangle.branch"
        case .apps: return "macwindow"
        case .system: return "gearshape"
        case .gruppen: return "square.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
        case .web: return "network"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .custom: return "cube"
        }
    }
}

/// One input or output.
struct Port: Codable, Hashable, Sendable, Identifiable {
    /// The key bindings and code use: `folder`, `quality`.
    var name: String
    var label: String
    var type: ValueType
    var control: PortControl
    var defaultValue: Value
    /// For `.choice`: the options, as shown.
    var choices: [String]
    var help: String
    /// An empty optional input is fine; an empty required one stops the flow
    /// from being switched on.
    var isOptional: Bool

    var id: String { name }

    /// Whether the input can read another block's value. Settings — a
    /// choice, a key combination, a block's packages — are typed, never
    /// wired.
    var takesValues: Bool {
        switch control {
        case .choice, .hotkey, .time, .weekdays, .secret, .code, .gruppe, .workspace: return false
        default: return !["packages", "interpreter"].contains(name)
        }
    }

    init(_ name: String, _ label: String? = nil, _ type: ValueType, _ control: PortControl? = nil,
         default defaultValue: Value = .nothing, choices: [String] = [], help: String = "", optional: Bool = false) {
        self.name = name
        self.label = label ?? name.prefix(1).uppercased() + name.dropFirst()
        self.type = type
        self.control = control ?? PortControl.natural(for: type)
        self.defaultValue = defaultValue
        self.choices = choices
        self.help = help
        self.isOptional = optional
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = try box.decode(String.self, forKey: .name)
        label = try box.decodeIfPresent(String.self, forKey: .label) ?? name
        type = (try? box.decodeIfPresent(ValueType.self, forKey: .type)) ?? .any
        control = (try? box.decodeIfPresent(PortControl.self, forKey: .control)) ?? PortControl.natural(for: type)
        defaultValue = (try? box.decodeIfPresent(Value.self, forKey: .defaultValue)) ?? .nothing
        choices = try box.decodeIfPresent([String].self, forKey: .choices) ?? []
        help = try box.decodeIfPresent(String.self, forKey: .help) ?? ""
        isOptional = try box.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case name, label, type, control, defaultValue, choices, help, isOptional
    }
}

/// How an input is edited.
enum PortControl: String, Codable, CaseIterable, Sendable, Identifiable {
    case text, multiline, number, toggle, folder, file, choice
    case app, gruppe, workspace, hotkey, time, weekdays, secret, code
    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Text field"
        case .multiline: return "Text box"
        case .number: return "Number"
        case .toggle: return "Switch"
        case .folder: return "Folder"
        case .file: return "File"
        case .choice: return "Choice"
        case .app: return "App"
        case .gruppe: return "Gruppe"
        case .workspace: return "Workspace"
        case .hotkey: return "Key combination"
        case .time: return "Time of day"
        case .weekdays: return "Weekdays"
        case .secret: return "Secret"
        case .code: return "Code"
        }
    }

    static func natural(for type: ValueType) -> PortControl {
        switch type {
        case .files: return .file
        case .number: return .number
        case .bool: return .toggle
        default: return .text
        }
    }

    /// The controls offered when you design a block of your own.
    static let forCustomBlocks: [PortControl] = [.text, .multiline, .number, .toggle, .folder, .file, .choice, .secret]
}

/// Something macOS has to allow before a block can work.
enum Permission: Hashable, Codable, Sendable, Identifiable {
    case accessibility
    case fullDiskAccess
    case screenRecording
    case location
    /// Sending Apple events to one app, by bundle identifier.
    case automation(String)

    var id: String {
        if case .automation(let app) = self { return "automation.\(app)" }
        return String(describing: self)
    }
}

/// What running a block means.
enum Implementation: Sendable {
    /// A hat. Its inputs are the trigger's settings; `FlowTriggers` arms it,
    /// and its outputs are what the event handed over.
    case trigger(TriggerKind)
    /// If, loops, Run together, variables, Stop: handled by the runner
    /// itself, because they decide what runs rather than doing anything.
    case control(ControlKind)
    case builtIn(BuiltIn)
    case code(CodeSpec)
    /// A code block on the canvas: its source, packages and input are the
    /// block's own inputs, so each one placed is a program of its own.
    case inlineCode(CodeLanguage)
    /// A block made by packaging other blocks: their stack, with the block's
    /// inputs read as `.trigger(port:)` inside it, and each output read from
    /// the binding `results` names.
    case blocks([Block], results: [String: ValueSource])
    /// The definition this block names is gone — a custom block deleted, or a
    /// built-in this build does not have.
    case missing
}

typealias BuiltIn = @Sendable (BlockContext) async throws -> [String: Value]

enum TriggerKind: String, Codable, CaseIterable, Sendable {
    case manual, hotkey, schedule, interval, folder, app, system, battery, display, wifi, audio, gruppe
    case notification, stash, external
}

enum ControlKind: String, Sendable {
    case ifElse, forEach, repeatTimes, parallel, setVariable, stop
}

/// A code block's program.
struct CodeSpec: Codable, Hashable, Sendable {
    var language: CodeLanguage
    var source: String
    /// Python or npm packages, installed once into an environment kept for
    /// this exact list.
    var packages: [String]
    /// An interpreter other than the one picked in Setup.
    var interpreter: String?

    init(_ language: CodeLanguage, source: String = "", packages: [String] = [], interpreter: String? = nil) {
        self.language = language
        self.source = source
        self.packages = packages
        self.interpreter = interpreter
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? box.decodeIfPresent(CodeLanguage.self, forKey: .language)) ?? .zsh
        source = try box.decodeIfPresent(String.self, forKey: .source) ?? ""
        packages = try box.decodeIfPresent([String].self, forKey: .packages) ?? []
        interpreter = try box.decodeIfPresent(String.self, forKey: .interpreter)
    }

    private enum CodingKeys: String, CodingKey { case language, source, packages, interpreter }
}

enum CodeLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case zsh, bash, python, javascript, applescript, jxa
    var id: String { rawValue }

    var label: String {
        switch self {
        case .zsh: return "Shell (zsh)"
        case .bash: return "Shell (bash)"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .applescript: return "AppleScript"
        case .jxa: return "JavaScript for Automation"
        }
    }

    var shortLabel: String {
        switch self {
        case .zsh: return "zsh"
        case .bash: return "bash"
        case .python: return "Python"
        case .javascript: return "JS"
        case .applescript: return "AppleScript"
        case .jxa: return "JXA"
        }
    }

    var fileExtension: String {
        switch self {
        case .zsh, .bash: return "sh"
        case .python: return "py"
        case .javascript, .jxa: return "js"
        case .applescript: return "applescript"
        }
    }

    var supportsPackages: Bool { self == .python || self == .javascript }

    /// The line that comments out a line, for ⌘/.
    var commentPrefix: String {
        switch self {
        case .zsh, .bash, .python: return "# "
        case .javascript, .jxa: return "// "
        case .applescript: return "-- "
        }
    }
}

// MARK: - Running

/// What a built-in block is handed: its inputs, already read and converted to
/// the types its ports declare, and the parts of the app it may reach.
struct BlockContext: Sendable {
    let block: UUID
    let inputs: [String: Value]
    let hooks: FlowHooks
    let run: RunContext
    /// A line for the console, under this block.
    let log: @Sendable (String) -> Void

    func value(_ name: String) -> Value { inputs[name] ?? .nothing }
    func text(_ name: String) -> String { value(name).text ?? "" }
    func number(_ name: String) -> Double { value(name).number ?? 0 }
    func flag(_ name: String) -> Bool { value(name).flag ?? false }
    func files(_ name: String) -> [URL] { value(name).urls ?? [] }

    /// The files in `name`, or the error a block with nothing to work on
    /// gives.
    func requireFiles(_ name: String = "files") throws -> [URL] {
        let files = files(name)
        guard !files.isEmpty else { throw FlowError.noFiles }
        return files
    }

    func requireText(_ name: String, _ what: String) throws -> String {
        let text = text(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FlowError.notSetUp(what) }
        return text
    }

    /// A folder input as a URL that exists.
    func folder(_ name: String = "folder") throws -> URL {
        let path = (try requireText(name, "No folder chosen") as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FlowError.missingFolder(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// Facts about the run a block is part of.
struct RunContext: Sendable {
    let flowID: UUID
    let flowName: String
    /// The flow's environment variables and its secrets' values, for code.
    let environment: [String: String]
    /// When the run must be finished by; nil for no limit.
    let deadline: Date?
    /// The flow's secret values, blanked out of anything shown or saved.
    var masked: [String] = []

    var remaining: TimeInterval? { deadline.map { max(1, $0.timeIntervalSinceNow) } }
}

/// The parts of the app a block can reach that are not singletons.
struct FlowHooks: Sendable {
    var launchGroup: @MainActor @Sendable (UUID) -> Bool = { _ in false }
    var closeGroup: @MainActor @Sendable (UUID) -> Bool = { _ in false }
    var activateWorkspace: @MainActor @Sendable (UUID) -> Bool = { _ in false }
    /// Shows a dialog and returns the answer, or nil when it was cancelled.
    var ask: @MainActor @Sendable (_ prompt: String, _ choices: [String], _ placeholder: String) async -> String? = { _, _, _ in nil }
}

enum FlowError: LocalizedError, Equatable {
    case notSetUp(String)
    case noFiles
    case failed(String)
    case missingFolder(String)
    case appNotFound(String)
    case targetGone(String)
    case wrongType(port: String, expected: ValueType, got: String)
    case missingBlock(String)
    /// Stop as failure, with what it said.
    case stopped(String)
    case cancelled
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .notSetUp(let what): return what
        case .noFiles: return "No files to work on"
        case .failed(let message): return message
        case .missingFolder(let path): return "\((path as NSString).lastPathComponent) does not exist"
        case .appNotFound(let app): return "\(app) is not installed"
        case .targetGone(let name): return "\(name.isEmpty ? "It" : name) is no longer there"
        case .wrongType(let port, let expected, let got):
            return "\(port) needs \(expected.label.lowercased()), and got \(got)"
        case .missingBlock(let id): return "The block \(id) is missing"
        case .stopped(let message): return message.isEmpty ? "Stopped" : message
        case .cancelled: return "Stopped by hand"
        case .timedOut(let seconds): return "Still running after \(seconds)s. Stopped."
        }
    }
}
