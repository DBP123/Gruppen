import Foundation

extension Catalog {
    // MARK: Web

    static let web: [BlockDefinition] = [
        BlockDefinition("web.request", "Web request", category: .web, glyph: "network",
                        phrase: "{method} {url}",
                        help: "The reply as text, and as a record when it is JSON. Headers one “Name: value” per line",
                        inputs: [Port("method", "Method", .text, .choice, default: .text("GET"),
                                      choices: ["GET", "POST", "PUT", "PATCH", "DELETE"]),
                                 Port("url", "Address", .text, default: .text("https://")),
                                 Port("headers", "Headers", .text, .multiline, optional: true),
                                 Port("body", "Body", .any, .multiline,
                                      help: "Text is sent as it is; a record or list as JSON", optional: true)],
                        outputs: [Port("status", "Status", .number), Port("text", "Reply", .text),
                                  Port("json", "Reply as data", .any)],
                        essential: true,
                        .builtIn { context in
                            var request = URLRequest(url: try Web.url(context.text("url")),
                                                     timeoutInterval: min(context.run.remaining ?? 60, 60))
                            request.httpMethod = context.text("method").isEmpty ? "GET" : context.text("method")
                            for (name, value) in Web.headers(context.text("headers")) {
                                request.setValue(value, forHTTPHeaderField: name)
                            }
                            switch context.value("body") {
                            case .nothing: break
                            case .text(let text) where !text.isEmpty: request.httpBody = Data(text.utf8)
                            case .text: break
                            case let other:
                                request.httpBody = Data(other.jsonText().utf8)
                                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                }
                            }
                            let (data, response) = try await URLSession.shared.data(for: request)
                            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            let text = String(data: data, encoding: .utf8) ?? ""
                            let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
                                .map(Value.init(json:)) ?? .nothing
                            guard (200..<400).contains(status) else {
                                throw FlowError.failed("The server answered \(status)\(text.isEmpty ? "" : ": " + text.prefix(200))")
                            }
                            return ["status": .number(Double(status)), "text": .text(text), "json": json]
                        }),
        BlockDefinition("web.download", "Download", category: .web, glyph: "arrow.down.circle",
                        phrase: "Download {url} to {folder}",
                        inputs: [Port("url", "Address", .text, default: .text("https://")),
                                 Port("folder", "Folder", .text, .folder, help: "Empty: the stash export folder", optional: true)],
                        outputs: [Port("file", "File", .files)],
                        .builtIn { context in
                            let url = try Web.url(context.text("url"))
                            let folder = try await FileOps.outputFolder(context)
                            let (temporary, response) = try await URLSession.shared.download(from: url)
                            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<400).contains(status) {
                                throw FlowError.failed("The server answered \(status)")
                            }
                            let name = response.suggestedFilename ?? url.lastPathComponent
                            let file = FileName.unique(name.isEmpty ? "Download" : name, in: folder)
                            try FileManager.default.moveItem(at: temporary, to: file)
                            return ["file": .files([file])]
                        }),
    ]

    // MARK: Code

    static let code: [BlockDefinition] = CodeLanguage.allCases.map { language in
        BlockDefinition(codeBlockID(language), language.label, category: .code, glyph: CodeTemplates.glyph(language),
                        phrase: "Run \(language.shortLabel) with {input}",
                        help: "Gets Input as JSON, as GRUPPEN_IN_INPUT, and its files as arguments. What it prints is Output; what it hands to out is Result",
                        inputs: [Port("code", "Code", .text, .code, default: .text(CodeTemplates.starter(language))),
                                 Port("input", "Input", .any, .text, optional: true),
                                 Port("packages", "Packages", .text, .multiline,
                                      help: language.supportsPackages ? "One per line; installed once, kept for this list" : "",
                                      optional: true),
                                 Port("interpreter", "Interpreter", .text, .file,
                                      help: "Empty: the one chosen in Setup", optional: true)],
                        outputs: [Port("output", "Output", .text), Port("result", "Result", .any),
                                  Port("files", "Files", .files)],
                        essential: language == .zsh || language == .python,
                        .inlineCode(language))
    }
}

/// What a new code block starts with: one line that shows how values come in
/// and go out, so nobody has to read a manual first.
enum CodeTemplates {
    static func glyph(_ language: CodeLanguage) -> String {
        switch language {
        case .zsh, .bash: return "terminal"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .javascript, .jxa: return "curlybraces"
        case .applescript: return "applescript"
        }
    }

    static func starter(_ language: CodeLanguage) -> String {
        switch language {
        case .zsh, .bash:
            return """
            # Files come in as "$@"; Input as $GRUPPEN_IN_INPUT.
            for file in "$@"; do
              echo "Got $file"
            done
            out count "$#"
            """
        case .python:
            return """
            # gruppen.inputs holds what came in; gruppen.out() hands values on.
            items = gruppen.files("input")
            print(f"Got {len(items)} file(s)")
            gruppen.out(count=len(items))
            """
        case .javascript:
            return """
            // gruppen.inputs holds what came in; gruppen.out() hands values on.
            const input = gruppen.inputs.input;
            console.log("Got", input);
            gruppen.out({ echo: input });
            """
        case .applescript:
            return """
            -- argv holds the files. The last line's value is the Output.
            on run argv
              display notification "Got " & (count of argv) & " file(s)" with title "Gruppen"
              return count of argv
            end run
            """
        case .jxa:
            return """
            // argv holds the files. What run returns is the Output.
            function run(argv) {
              const app = Application.currentApplication();
              app.includeStandardAdditions = true;
              app.displayNotification(`Got ${argv.length} file(s)`, { withTitle: "Gruppen" });
              return argv.length;
            }
            """
        }
    }
}

enum Web {
    static func url(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            throw FlowError.failed(trimmed.isEmpty || trimmed == "https://" ? "No address given" : "“\(trimmed)” isn't a web address")
        }
        return url
    }

    static func headers(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }
}
