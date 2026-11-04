import AppKit
import SwiftUI

/// A code editor for code blocks: syntax colours, line numbers, indentation
/// that follows you, ⌘/ to comment, and the line an error named marked red.
///
/// An `NSTextView` rather than SwiftUI's `TextEditor`: colouring text, a ruler
/// and key handling are what TextKit is for. Colouring is a handful of
/// regular expressions per language, rerun on each edit — scripts here are
/// tens of lines, where that costs well under a millisecond.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    var errorLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CodeTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = CodeHighlighter.font
        textView.textColor = NSColor(Theme.textPrimary)
        textView.backgroundColor = NSColor(Theme.input)
        textView.drawsBackground = true
        textView.insertionPointColor = NSColor(Theme.orange)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection
        }
        context.coordinator.highlight()
        (scroll.verticalRulerView as? LineNumberRuler)?.errorLine = errorLine
        scroll.verticalRulerView?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        private var highlighted: (String, CodeLanguage, Int?)?

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let key = (textView.string, parent.language, parent.errorLine)
            if let highlighted, highlighted == key { return }
            highlighted = key
            CodeHighlighter.apply(to: storage, language: parent.language, errorLine: parent.errorLine)
        }

        /// Return keeps the line's indent, and adds a level after a line that
        /// opens a block. Tab is spaces; ⌘/ comments the selected lines.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let text = textView.string as NSString
                let caret = textView.selectedRange().location
                let line = text.substring(with: text.lineRange(for: NSRange(location: caret, length: 0)))
                var indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let last = trimmed.last, ":{([".contains(last) || trimmed.hasSuffix(" do") || trimmed.hasSuffix(" then") {
                    indent += parent.language.indentUnit
                }
                textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText(parent.language.indentUnit, replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }
    }
}

extension CodeLanguage {
    var indentUnit: String { self == .zsh || self == .bash ? "  " : "    " }
}

/// The text view itself, for ⌘/.
final class CodeTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "/", window?.firstResponder === self {
            toggleComment()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Comments the selected lines, or uncomments them when every one
    /// already is.
    private func toggleComment() {
        guard let coordinator = delegate as? CodeEditor.Coordinator else { return }
        let prefix = coordinator.parent.language.commentPrefix
        let text = string as NSString
        let range = text.lineRange(for: selectedRange())
        let lines = text.substring(with: range).components(separatedBy: "\n")
        let body = lines.last == "" ? Array(lines.dropLast()) : lines
        let commented = body.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty
            || $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix.trimmingCharacters(in: .whitespaces)) }
        let changed = body.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if commented {
                if let found = line.range(of: prefix) { return line.replacingCharacters(in: found, with: "") }
                if let found = line.range(of: prefix.trimmingCharacters(in: .whitespaces)) {
                    return line.replacingCharacters(in: found, with: "")
                }
                return line
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return indent + prefix + line.dropFirst(indent.count)
        }.joined(separator: "\n") + (lines.last == "" ? "\n" : "")
        if shouldChangeText(in: range, replacementString: changed) {
            replaceCharacters(in: range, with: changed)
            didChangeText()
            setSelectedRange(NSRange(location: range.location, length: (changed as NSString).length))
        }
    }

    override class func scrollableTextView() -> NSScrollView {
        let scroll = NSScrollView()
        let view = CodeTextView(frame: .zero)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        scroll.hasHorizontalScroller = true
        return scroll
    }
}

// MARK: - Colours

@MainActor
enum CodeHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private struct Rule {
        let pattern: NSRegularExpression
        let color: NSColor
    }

    private static func rules(_ language: CodeLanguage) -> [Rule] {
        func rule(_ pattern: String, _ color: Color, _ options: NSRegularExpression.Options = []) -> Rule {
            Rule(pattern: try! NSRegularExpression(pattern: pattern, options: options), color: NSColor(color))
        }
        let keywords: [String]
        let comment: String
        switch language {
        case .zsh, .bash:
            keywords = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
                        "function", "return", "local", "export", "echo", "printf", "read", "exit", "set", "out"]
            comment = "#[^\\n]*"
        case .python:
            keywords = ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import",
                        "from", "as", "with", "try", "except", "finally", "raise", "lambda", "None", "True", "False",
                        "pass", "break", "continue", "yield", "async", "await", "gruppen", "print"]
            comment = "#[^\\n]*"
        case .javascript, .jxa:
            keywords = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "of", "in", "new",
                        "class", "async", "await", "try", "catch", "throw", "null", "undefined", "true", "false",
                        "import", "export", "require", "gruppen", "Application", "console"]
            comment = "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
        case .applescript:
            keywords = ["tell", "end", "on", "run", "set", "to", "return", "if", "then", "else", "repeat", "with",
                        "in", "of", "the", "every", "application", "display", "notification", "dialog", "activate",
                        "try", "error", "true", "false", "argv"]
            comment = "--[^\\n]*|\\(\\*[\\s\\S]*?\\*\\)"
        }
        return [
            rule("\\b(\(keywords.joined(separator: "|")))\\b", Theme.orange),
            rule("\\b\\d+(\\.\\d+)?\\b", Theme.cyan),
            rule("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?|\\$[@#?0-9]", Theme.amber),
            rule("\"(\\\\.|[^\"\\\\])*\"|'(\\\\.|[^'\\\\])*'|`(\\\\.|[^`\\\\])*`", Theme.green),
            rule(comment, Theme.textMuted),
        ]
    }

    private static var cache: [CodeLanguage: [Rule]] = [:]

    static func apply(to storage: NSTextStorage, language: CodeLanguage, errorLine: Int?) {
        let text = storage.string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let rules = cache[language] ?? rules(language)
        cache[language] = rules
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor(Theme.textPrimary)], range: whole)
        // Later rules win: strings over keywords, comments over everything.
        for rule in rules {
            rule.pattern.enumerateMatches(in: text, range: whole) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: rule.color, range: range) }
            }
        }
        if let errorLine, errorLine > 0 {
            var line = 1
            var location = 0
            let ns = text as NSString
            while line < errorLine, location < ns.length {
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
                line += 1
            }
            if location <= ns.length {
                let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
                storage.addAttribute(.backgroundColor, value: NSColor(Theme.red).withAlphaComponent(0.22), range: range)
            }
        }
        storage.endEditing()
    }
}

/// Line numbers down the left, with the error line's number in red.
final class LineNumberRuler: NSRulerView {
    var errorLine: Int?

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        NSColor(Theme.machined).setFill()
        bounds.fill()
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = text.substring(to: characters.location).filter { $0 == "\n" }.count + 1
        var index = characters.location
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor(Theme.textMuted),
        ]
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        while index <= NSMaxRange(characters) {
            let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
            let box = layout.lineFragmentRect(forGlyphAt: min(glyph.location, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
            var style = attributes
            if line == errorLine { style[.foregroundColor] = NSColor(Theme.red) }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: style)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: offset + box.minY + (box.height - size.height) / 2),
                       withAttributes: style)
            if NSMaxRange(lineRange) <= index || lineRange.length == 0 { break }
            index = NSMaxRange(lineRange)
            line += 1
        }
    }
}

// MARK: - Editing outside

/// Edits a block's code in the editor you use for everything else: the
/// source goes to a file, opens there, and every save comes back.
@MainActor
final class ExternalEdit {
    private static var sessions: [UUID: ExternalEdit] = [:]
    private let file: URL
    private var source: DispatchSourceFileSystemObject?
    private let onChange: (String) -> Void

    private init(file: URL, onChange: @escaping (String) -> Void) {
        self.file = file
        self.onChange = onChange
    }

    static func open(_ code: String, language: CodeLanguage, name: String, block: UUID, onChange: @escaping (String) -> Void) {
        sessions[block]?.stop()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppPaths.name) code", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let file = folder.appendingPathComponent("\(safe) \(block.uuidString.prefix(4)).\(language.fileExtension)")
        try? code.write(to: file, atomically: true, encoding: .utf8)
        let session = ExternalEdit(file: file, onChange: onChange)
        session.watch()
        sessions[block] = session
        NSWorkspace.shared.open(file)
    }

    /// Watches the file itself; editors that save by replacing it get the
    /// watch renewed on the new file.
    private func watch() {
        let descriptor = Darwin.open(file.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if let text = try? String(contentsOf: self.file, encoding: .utf8) { self.onChange(text) }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.stop()
                    self.watch()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
    }
}
