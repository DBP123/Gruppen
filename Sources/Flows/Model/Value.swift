import Foundation

/// What flows along a binding: the output of one block, read as the input of
/// another.
///
/// Seven kinds and no more. Every built-in block and every line of user code
/// speaks in these, so a beginner's "Rename" and an expert's Python script can
/// be wired together without either knowing about the other.
indirect enum Value: Hashable, Sendable {
    case nothing
    case files([URL])
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([Value])
    case record([String: Value])

    var type: ValueType {
        switch self {
        case .nothing: return .any
        case .files: return .files
        case .text: return .text
        case .number: return .number
        case .bool: return .bool
        case .list: return .list
        case .record: return .record
        }
    }

    var isNothing: Bool { self == .nothing }

    /// One line, for a badge on the canvas or a row in the console.
    var summary: String {
        switch self {
        case .nothing: return "nothing"
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        case .text(let text):
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let cut = line.count > 40 ? String(line.prefix(39)) + "…" : line
            return text.isEmpty ? "empty text" : "“\(cut)”"
        case .number(let number): return Value.format(number)
        case .bool(let flag): return flag ? "yes" : "no"
        case .list(let items): return items.count == 1 ? "1 item" : "\(items.count) items"
        case .record(let fields): return fields.count == 1 ? "1 field" : "\(fields.count) fields"
        }
    }

    /// Whole numbers without a decimal point: "3", not "3.0".
    static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }
}

/// The kind of value a port carries. Each has a colour on the canvas, so a
/// mismatch is visible before anything runs.
enum ValueType: String, Codable, CaseIterable, Sendable, Identifiable {
    case files, text, number, bool, list, record
    /// Accepts anything; used by inputs such as If's "value".
    case any

    var id: String { rawValue }

    var label: String {
        switch self {
        case .files: return "Files"
        case .text: return "Text"
        case .number: return "Number"
        case .bool: return "Yes/No"
        case .list: return "List"
        case .record: return "Record"
        case .any: return "Anything"
        }
    }
}

// MARK: - Conversion

/// Whether a value of one type can feed an input of another, judged while
/// building. Every rule lives in `Value.coerced(to:)`; this only names its
/// outcome, so the canvas and the runner can never disagree.
enum Conversion: Equatable, Sendable {
    /// The same type, or an input that takes anything.
    case exact
    /// Converted on the way, and it may fail at run time — text that is not a
    /// number, a path that does not exist. Shown amber.
    case converts
    /// Never works. Shown red, and the flow cannot be switched on.
    case impossible

    static func from(_ source: ValueType, to target: ValueType) -> Conversion {
        if source == target || target == .any || source == .any { return .exact }
        switch (source, target) {
        case (.files, .number), (.list, .number), (.record, .number),
             (.record, .files), (.record, .list), (.bool, .files), (.number, .files),
             (.bool, .record), (.number, .record), (.files, .record), (.list, .record):
            return .impossible
        default:
            return .converts
        }
    }
}

extension Value {
    /// This value as `type`, or nil when it cannot be one. The single table
    /// of conversions; `Conversion.from` mirrors it.
    func coerced(to type: ValueType) -> Value? {
        if type == .any || self.type == type { return self }
        switch (self, type) {
        case (.nothing, .text): return .text("")
        case (.nothing, .files): return .files([])
        case (.nothing, .list): return .list([])
        case (.nothing, .bool): return .bool(false)
        case (.nothing, _): return nil

        case (.files(let urls), .text): return .text(urls.map(\.path).joined(separator: "\n"))
        case (.files(let urls), .list): return .list(urls.map { .files([$0]) })
        case (.files(let urls), .bool): return .bool(!urls.isEmpty)

        case (.text(let text), .number):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed).map(Value.number)
        case (.text(let text), .bool):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1", "on": return .bool(true)
            case "no", "false", "0", "off", "": return .bool(false)
            default: return nil
            }
        case (.text(let text), .files):
            let paths = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            return .files(paths)
        case (.text(let text), .list):
            return .list(text.split(whereSeparator: \.isNewline).map { .text(String($0)) })
        case (.text(let text), .record):
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  case .record(let fields) = Value(json: object) else { return nil }
            return .record(fields)

        case (.number(let number), .text): return .text(Value.format(number))
        case (.number(let number), .bool): return .bool(number != 0)
        case (.number, .list): return .list([self])

        case (.bool(let flag), .text): return .text(flag ? "yes" : "no")
        case (.bool(let flag), .number): return .number(flag ? 1 : 0)
        case (.bool, .list): return .list([self])

        case (.list(let items), .text):
            return .text(items.compactMap { $0.coerced(to: .text)?.text }.joined(separator: "\n"))
        case (.list(let items), .files):
            var urls: [URL] = []
            for item in items {
                guard case .files(let more)? = item.coerced(to: .files) else { return nil }
                urls += more
            }
            return .files(urls)
        case (.list(let items), .bool): return .bool(!items.isEmpty)

        case (.record, .text): return .text(jsonText(pretty: true))
        case (.record(let fields), .bool): return .bool(!fields.isEmpty)

        default: return nil
        }
    }

    // Unwrapped readers, for block implementations that have already coerced.
    var text: String? { if case .text(let text) = self { return text }; return nil }
    var number: Double? { if case .number(let number) = self { return number }; return nil }
    var flag: Bool? { if case .bool(let flag) = self { return flag }; return nil }
    var urls: [URL]? { if case .files(let urls) = self { return urls }; return nil }
    var items: [Value]? { if case .list(let items) = self { return items }; return nil }
    var fields: [String: Value]? { if case .record(let fields) = self { return fields }; return nil }
}

// MARK: - JSON

extension Value {
    /// The value as plain JSON, for code blocks: files become their paths, so a
    /// script reads `inputs["files"]` as a list of strings.
    var json: Any {
        switch self {
        case .nothing: return NSNull()
        case .files(let urls): return urls.map(\.path)
        case .text(let text): return text
        // JSONSerialization raises an ObjC exception — uncatchable — on NaN
        // and infinity, so they are written as null.
        case .number(let number): return number.isFinite ? number : NSNull()
        case .bool(let flag): return flag
        case .list(let items): return items.map(\.json)
        case .record(let fields): return fields.mapValues(\.json)
        }
    }

    /// Plain JSON back into a value, with no type to aim for.
    init(json: Any) {
        switch json {
        case is NSNull: self = .nothing
        // Before the number cases: JSON booleans arrive as NSNumber too.
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let text as String: self = .text(text)
        case let array as [Any]: self = .list(array.map(Value.init(json:)))
        case let object as [String: Any]: self = .record(object.mapValues(Value.init(json:)))
        default: self = .text(String(describing: json))
        }
    }

    /// Plain JSON read as `type`: what a code block's declared output says it
    /// is. A list of paths declared as files becomes files.
    init?(json: Any, as type: ValueType) {
        let loose = Value(json: json)
        if type == .files, case .list(let items) = loose {
            let paths = items.compactMap(\.text)
            guard paths.count == items.count else { return nil }
            self = .files(paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
            return
        }
        if type == .files, case .text(let path) = loose {
            self = .files([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
            return
        }
        guard let value = loose.coerced(to: type) else { return nil }
        self = value
    }

    func jsonText(pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: options),
              let text = String(data: data, encoding: .utf8)
        else { return summary }
        return text
    }

    /// No more than `limit` characters of JSON, for saved run traces: a run
    /// over a thousand files must not write a megabyte of history.
    func truncated(to limit: Int) -> Value {
        switch self {
        case .text(let text) where text.count > limit:
            return .text(String(text.prefix(limit)) + "…")
        case .files(let urls) where urls.count > limit / 64:
            return .files(Array(urls.prefix(max(1, limit / 64))))
        case .list(let items) where items.count > limit / 64:
            return .list(items.prefix(max(1, limit / 64)).map { $0.truncated(to: limit / 4) })
        case .list(let items):
            return .list(items.map { $0.truncated(to: limit / 4) })
        case .record(let fields):
            return .record(fields.mapValues { $0.truncated(to: limit / 4) })
        default:
            return self
        }
    }
}

// MARK: - Codable

/// Tagged so a saved value reads back as the type it was — `{"files": [...]}`,
/// `{"text": "..."}` — rather than guessed from plain JSON.
extension Value: Codable {
    private enum Tag: String, CodingKey { case nothing, files, text, number, bool, list, record }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Tag.self)
        if let paths = try box.decodeIfPresent([String].self, forKey: .files) {
            self = .files(paths.map { URL(fileURLWithPath: $0) })
        } else if let text = try box.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let number = try box.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(number)
        } else if let flag = try box.decodeIfPresent(Bool.self, forKey: .bool) {
            self = .bool(flag)
        } else if let items = try box.decodeIfPresent([Value].self, forKey: .list) {
            self = .list(items)
        } else if let fields = try box.decodeIfPresent([String: Value].self, forKey: .record) {
            self = .record(fields)
        } else {
            self = .nothing
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Tag.self)
        switch self {
        case .nothing: try box.encode(true, forKey: .nothing)
        case .files(let urls): try box.encode(urls.map(\.path), forKey: .files)
        case .text(let text): try box.encode(text, forKey: .text)
        case .number(let number): try box.encode(number, forKey: .number)
        case .bool(let flag): try box.encode(flag, forKey: .bool)
        case .list(let items): try box.encode(items, forKey: .list)
        case .record(let fields): try box.encode(fields, forKey: .record)
        }
    }
}
