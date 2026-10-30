import Foundation

extension Catalog {
    static let text: [BlockDefinition] = [
        BlockDefinition("text.make", "Text", category: .text, glyph: "text.quote",
                        phrase: "Text {text}",
                        help: "Drop values into it to build a line: “Report {date} {name}”",
                        inputs: [Port("text", "Text", .text, .multiline)],
                        outputs: [Port("text", "Text", .text)], essential: true,
                        .builtIn { ["text": .text($0.text("text"))] }),
        BlockDefinition("text.join", "Join", category: .text, glyph: "link",
                        phrase: "Join {items} with {separator}",
                        inputs: [Port("items", "Items", .list), Port("separator", "Separator", .text, default: .text(", "))],
                        outputs: [Port("text", "Text", .text)],
                        .builtIn { context in
                            let parts = (context.value("items").items ?? []).map(RunMemory.inline)
                            return ["text": .text(parts.joined(separator: Self.unescape(context.text("separator"))))]
                        }),
        BlockDefinition("text.split", "Split", category: .text, glyph: "scissors",
                        phrase: "Split {text} at {separator}",
                        help: "\\n for each line, \\t for tabs",
                        inputs: [Port("text", "Text", .text), Port("separator", "Separator", .text, default: .text("\\n"))],
                        outputs: [Port("items", "Pieces", .list)],
                        .builtIn { context in
                            let separator = Self.unescape(context.text("separator"))
                            let pieces = separator.isEmpty ? context.text("text").map(String.init)
                                : context.text("text").components(separatedBy: separator)
                            return ["items": .list(pieces.map(Value.text))]
                        }),
        BlockDefinition("text.replace", "Replace", category: .text, glyph: "arrow.left.arrow.right",
                        phrase: "In {text} replace {find} with {with}",
                        inputs: [Port("text", "Text", .text), Port("find", "Find", .text),
                                 Port("with", "With", .text, optional: true),
                                 Port("pattern", "Find is a pattern", .bool, default: .bool(false),
                                      help: "A regular expression; $1 in With is its first group")],
                        outputs: [Port("text", "Text", .text)],
                        .builtIn { context in
                            let text = context.text("text"), find = context.text("find"), with = context.text("with")
                            guard !find.isEmpty else { return ["text": .text(text)] }
                            if context.flag("pattern") {
                                let pattern = try Self.regex(find)
                                return ["text": .text(pattern.stringByReplacingMatches(
                                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with))]
                            }
                            return ["text": .text(text.replacingOccurrences(of: find, with: with))]
                        }),
        BlockDefinition("text.extract", "Find in text", category: .text, glyph: "text.magnifyingglass",
                        phrase: "Find {pattern} in {text}",
                        help: "A regular expression. Its first group if it has one, otherwise the whole match",
                        inputs: [Port("text", "Text", .text), Port("pattern", "Pattern", .text, default: .text("\\d+"))],
                        outputs: [Port("first", "First match", .text), Port("all", "All matches", .list)],
                        .builtIn { context in
                            let text = context.text("text")
                            let pattern = try Self.regex(context.text("pattern"))
                            let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
                                let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                                return Range(range, in: text).map { String(text[$0]) }
                            }
                            return ["first": .text(matches.first ?? ""), "all": .list(matches.map(Value.text))]
                        }),
        BlockDefinition("text.case", "Change case", category: .text, glyph: "textformat",
                        phrase: "Make {text} {style}",
                        inputs: [Port("text", "Text", .text),
                                 Port("style", "Style", .text, .choice, default: .text("Sentence case"),
                                      choices: CaseStyle.allCases.map(\.label))],
                        outputs: [Port("text", "Text", .text)],
                        .builtIn { context in
                            let style = CaseStyle.allCases.first { $0.label == context.text("style") } ?? .sentence
                            return ["text": .text(TextTools.change(context.text("text"), to: style))]
                        }),
        BlockDefinition("text.count", "Count", category: .text, glyph: "number",
                        phrase: "Count {items}",
                        help: "Files, list items, lines of text, or a record's fields",
                        inputs: [Port("items", "Items", .any, .text)],
                        outputs: [Port("count", "Count", .number)],
                        .builtIn { context in
                            ["count": .number(Double(FlowRunner.items(of: context.value("items")).count))]
                        }),
        BlockDefinition("text.math", "Calculate", category: .text, glyph: "function",
                        phrase: "Calculate {expression}",
                        help: "+ − × ÷, brackets and decimals: “(price * 1.2) / 3” with values dropped in",
                        inputs: [Port("expression", "Expression", .text)],
                        outputs: [Port("result", "Result", .number)],
                        .builtIn { context in
                            ["result": .number(try Arithmetic.evaluate(context.text("expression")))]
                        }),
        BlockDefinition("text.parseJSON", "Read JSON", category: .text, glyph: "curlybraces.square",
                        phrase: "Read {text} as JSON",
                        inputs: [Port("text", "JSON", .text)],
                        outputs: [Port("value", "Value", .any)],
                        .builtIn { context in
                            guard let data = context.text("text").data(using: .utf8),
                                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                            else { throw FlowError.failed("That isn't valid JSON") }
                            return ["value": Value(json: object)]
                        }),
        BlockDefinition("text.makeJSON", "Write JSON", category: .text, glyph: "curlybraces",
                        phrase: "{value} as JSON",
                        inputs: [Port("value", "Value", .any, .text),
                                 Port("pretty", "Indented", .bool, default: .bool(true))],
                        outputs: [Port("text", "JSON", .text)],
                        .builtIn { ["text": .text($0.value("value").jsonText(pretty: $0.flag("pretty")))] }),
        BlockDefinition("text.field", "Get field", category: .text, glyph: "list.bullet.indent",
                        phrase: "{path} of {record}",
                        help: "A key, or a dotted path into nested records and lists: “user.name”, “items.0”",
                        inputs: [Port("record", "Record", .any, .text), Port("path", "Field", .text)],
                        outputs: [Port("value", "Value", .any)],
                        .builtIn { context in
                            ["value": Self.field(context.text("path"), of: context.value("record"))]
                        }),
        BlockDefinition("text.record", "Make record", category: .text, glyph: "rectangle.grid.1x2",
                        phrase: "Record {fields}",
                        help: "One “key: value” per line",
                        inputs: [Port("fields", "Fields", .text, .multiline)],
                        outputs: [Port("record", "Record", .record)],
                        .builtIn { context in
                            var fields: [String: Value] = [:]
                            for line in context.text("fields").split(whereSeparator: \.isNewline) {
                                guard let colon = line.firstIndex(of: ":") else { continue }
                                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                                if !key.isEmpty { fields[key] = Double(value).map(Value.number) ?? .text(value) }
                            }
                            return ["record": .record(fields)]
                        }),
        BlockDefinition("text.date", "Date", category: .text, glyph: "calendar",
                        phrase: "Today as {format}",
                        help: "yyyy-MM-dd, HH:mm, EEEE (weekday) — Unicode date patterns",
                        inputs: [Port("format", "Format", .text, default: .text("yyyy-MM-dd")),
                                 Port("days", "Days from now", .number, default: .number(0), optional: true)],
                        outputs: [Port("text", "Date", .text)],
                        .builtIn { context in
                            let formatter = DateFormatter()
                            formatter.locale = Locale(identifier: "en_US_POSIX")
                            formatter.dateFormat = context.text("format").isEmpty ? "yyyy-MM-dd" : context.text("format")
                            let date = Date().addingTimeInterval(context.number("days") * 86_400)
                            return ["text": .text(formatter.string(from: date))]
                        }),
    ]

    /// `\n` and `\t` as typed into a field.
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }

    static func regex(_ pattern: String) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) } catch {
            throw FlowError.failed("“\(pattern)” isn't a valid pattern")
        }
    }

    /// A dotted path into records and lists.
    static func field(_ path: String, of value: Value) -> Value {
        var current = value
        if case .text(let text) = current, let parsed = text.coercedRecord { current = parsed }
        for key in path.split(separator: ".").map(String.init) where !key.isEmpty {
            switch current {
            case .record(let fields): current = fields[key] ?? .nothing
            case .list(let items):
                guard let index = Int(key), items.indices.contains(index) else { return .nothing }
                current = items[index]
            default: return .nothing
            }
        }
        return current
    }
}

private extension String {
    var coercedRecord: Value? {
        guard let data = data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return Value(json: object)
    }
}

/// + − × ÷ and brackets over decimals. Small on purpose: Calculate is for
/// the sums people actually do in a flow, not a language.
enum Arithmetic {
    static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(Array(expression.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")))
        let value = try parser.sum()
        parser.skipSpace()
        guard parser.index == parser.characters.count else { throw FlowError.failed("Can't read “\(expression)”") }
        return value
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        init(_ characters: [Character]) { self.characters = characters }

        mutating func skipSpace() { while index < characters.count, characters[index].isWhitespace { index += 1 } }

        mutating func peek() -> Character? { skipSpace(); return index < characters.count ? characters[index] : nil }

        mutating func sum() throws -> Double {
            var value = try product()
            while let next = peek(), next == "+" || next == "-" {
                index += 1
                value = next == "+" ? value + (try product()) : value - (try product())
            }
            return value
        }

        mutating func product() throws -> Double {
            var value = try factor()
            while let next = peek(), next == "*" || next == "/" || next == "%" {
                index += 1
                let right = try factor()
                switch next {
                case "*": value *= right
                case "/":
                    guard right != 0 else { throw FlowError.failed("Division by zero") }
                    value /= right
                default: value = value.truncatingRemainder(dividingBy: right)
                }
            }
            return value
        }

        mutating func factor() throws -> Double {
            guard let next = peek() else { throw FlowError.failed("The sum ends too soon") }
            if next == "-" { index += 1; return -(try factor()) }
            if next == "(" {
                index += 1
                let value = try sum()
                guard peek() == ")" else { throw FlowError.failed("A bracket is not closed") }
                index += 1
                return value
            }
            let start = index
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            guard let value = Double(String(characters[start..<index])) else {
                throw FlowError.failed("“\(String(characters[start...]))” is not a number")
            }
            return value
        }
    }
}
