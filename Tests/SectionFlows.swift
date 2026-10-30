import AppKit

/// A runner with every event collected, and no code interpreter unless one is
/// given.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [RunEvent] = []
    func add(_ event: RunEvent) { lock.lock(); all.append(event); lock.unlock() }
    var events: [RunEvent] { lock.lock(); defer { lock.unlock() }; return all }

    var finished: [UUID] {
        events.compactMap { if case .finished(let id, _, _) = $0 { return id }; return nil }
    }
    var failed: [UUID] {
        events.compactMap { if case .failed(let id, _) = $0 { return id }; return nil }
    }
    func outputs(_ id: UUID) -> [String: Value] {
        for event in events { if case .finished(id, let outputs, _) = event { return outputs } }
        return [:]
    }
}

private struct NoCode: CodeExecuting {
    func run(_ spec: CodeSpec, inputs: [String: Value], definition: BlockDefinition, context: RunContext,
             log: @escaping @Sendable (String, Bool) -> Void) async throws -> [String: Value] {
        ["output": .text("ran \(spec.language.rawValue)")]
    }
}

private func runner(_ log: EventLog, registry: BlockRegistry = BlockRegistry(), code: CodeExecuting = NoCode(),
                    debugger: RunDebugger? = nil) -> FlowRunner {
    FlowRunner(registry: registry, hooks: FlowHooks(), code: code, events: { log.add($0) }, debugger: debugger)
}

private func context(timeout: TimeInterval? = nil) -> RunContext {
    RunContext(flowID: UUID(), flowName: "Test", environment: [:],
               deadline: timeout.map { Date().addingTimeInterval($0) })
}

private func text(_ value: String) -> ValueSource { .literal(.text(value)) }
private func number(_ value: Double) -> ValueSource { .literal(.number(value)) }

func sectionFlows() async {
    T.begin("Flows — values and conversions")

    T.equal("a file reads as its path", Value.files([URL(fileURLWithPath: "/tmp/a.pdf")]).coerced(to: .text), .text("/tmp/a.pdf"))
    T.equal("text reads as a number", Value.text(" 42 ").coerced(to: .number), .number(42))
    T.check("words do not read as a number", Value.text("forty").coerced(to: .number) == nil)
    T.equal("yes reads as yes", Value.text("Yes").coerced(to: .bool), .bool(true))
    T.equal("a number reads as text without .0", Value.number(3).coerced(to: .text), .text("3"))
    T.equal("files become a list of single files",
            Value.files([URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]).coerced(to: .list)?.items?.count, 2)
    T.equal("lines become a list", Value.text("a\nb\nc").coerced(to: .list)?.items?.count, 3)
    T.check("text naming a missing file is not files", Value.text("/no/such/file").coerced(to: .files) == nil)
    T.equal("JSON text reads as a record", Value.text(#"{"a": 1}"#).coerced(to: .record), .record(["a": .number(1)]))

    // The two tables must agree: whatever Conversion calls impossible never
    // converts, and whatever it calls possible does for some value.
    let samples: [ValueType: Value] = [
        .files: .files([URL(fileURLWithPath: "/tmp")]), .text: .text("1"), .number: .number(1),
        .bool: .bool(true), .list: .list([.text("/tmp")]), .record: .record(["a": .number(1)]),
    ]
    var disagreements: [String] = []
    for (source, sample) in samples {
        for target in ValueType.allCases where target != .any {
            // "Converts" may still fail for a given value — text that names
            // no file — but "impossible" must never succeed.
            if Conversion.from(source, to: target) == .impossible, sample.coerced(to: target) != nil {
                disagreements.append("\(source)→\(target)")
            }
        }
    }
    T.check("nothing called impossible ever converts", disagreements.isEmpty, disagreements.joined(separator: ", "))

    let nested = Value.record(["files": .files([URL(fileURLWithPath: "/x y")]), "n": .number(2.5),
                               "list": .list([.bool(false), .nothing]), "t": .text("é")])
    let encoded = try? JSONEncoder().encode(nested)
    T.equal("a value survives saving", encoded.flatMap { try? JSONDecoder().decode(Value.self, from: $0) }, nested)
    T.equal("files go to code as paths", Value.files([URL(fileURLWithPath: "/a")]).jsonText(), #"["/a"]"#)
    T.equal("a JSON list of paths declared as files is files",
            Value(json: ["/a", "/b"], as: .files), .files([URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]))
    T.equal("JSON booleans stay booleans", Value(json: NSNumber(value: true)), .bool(true))
    T.equal("NaN is written as null, not a crash", Value.number(.nan).jsonText(), "null")
    T.equal("long text is cut for saved runs", Value.text(String(repeating: "x", count: 100)).truncated(to: 10).text?.count, 11)

    T.begin("Flows — saved form, leniently")

    let source = Block(Catalog.ifElse, inputs: ["value": .template([.text("a "), .value(.trigger(port: "files"))]),
                                                "other": .variable("v")],
                       children: [[Block("files.move")], []], onFailure: .retry(2))
    let flow = Flow(name: "Saved", triggers: [Block(Catalog.folder, inputs: ["folder": text("~/Downloads")])], body: [source])
    let saved = try? JSONEncoder().encode(flow)
    let back = saved.flatMap { try? JSONDecoder().decode(Flow.self, from: $0) }
    T.equal("a flow survives saving", back, flow)
    let sparse = #"{"name": "Old", "body": [{"definition": "files.move", "inputs": {"folder": {"nonsense": 1}}, "onFailure": {"policy": "sideways"}}]}"#
    let lenient = try? JSONDecoder().decode(Flow.self, from: Data(sparse.utf8))
    T.check("a flow with unreadable parts keeps its blocks", lenient?.body.count == 1)
    T.check("an unreadable binding is dropped, not the block", lenient?.body.first?.inputs.isEmpty == true)
    T.equal("an unknown failure policy means stop", lenient?.body.first?.onFailure, .stop)

    let registry = BlockRegistry()
    let missing = registry.definition("custom.\(UUID().uuidString)")
    T.check("a deleted block reads as Missing, not nil", { if case .missing = missing.implementation { return true }; return false }())

    let copied = Block.copies(of: [Block(id: UUID(), "text.make"), source])
    T.check("copies get fresh ids", copied[0].id != source.id && copied[1].id != source.id)

    let a = Block("text.make", inputs: ["text": text("hi")])
    let b = Block("text.case", inputs: ["text": .output(block: a.id, port: "text")])
    let pair = Block.copies(of: [a, b])
    T.equal("a copied pair reads from its own copy", pair[1].inputs["text"], .output(block: pair[0].id, port: "text"))

    T.begin("Flows — phrases")
    let move = Catalog.definition("files.move")!
    T.equal("a phrase splits into words and inputs", move.phraseParts,
            [.words("Move"), .input("files"), .words("to"), .input("folder")])

    T.begin("Flows — what can be read where")

    let first = Block("text.make", inputs: ["text": text("x")])
    let inner = Block("text.make", inputs: ["text": .output(block: UUID(), port: "item")])
    let loop = Block(Catalog.forEach, inputs: ["items": .trigger(port: "files")], children: [[inner]])
    let after = Block("text.case", inputs: ["text": .output(block: inner.id, port: "text")])
    let scoped = Flow(triggers: [Block(Catalog.folder, inputs: ["folder": text("/tmp")])], body: [first, loop, after])
    let context0 = FlowCheck.context(for: scoped, registry: registry)
    let atInner = FlowCheck.available(at: inner.id, in: scoped.body, context: context0).map(\.binding)
    T.check("inside a loop: the trigger, earlier blocks and the item",
            atInner.contains(.trigger(port: "files")) && atInner.contains(.output(block: first.id, port: "text"))
            && atInner.contains(.output(block: loop.id, port: "item")))
    let atAfter = FlowCheck.available(at: after.id, in: scoped.body, context: context0).map(\.binding)
    T.check("after a loop: nothing from inside it", !atAfter.contains(.output(block: inner.id, port: "text")))
    T.check("after a loop: not its item", !atAfter.contains(.output(block: loop.id, port: "item")))
    let problems = FlowCheck.issues(in: scoped, registry: registry)
    T.check("reading from inside a loop afterwards is an error",
            problems.contains { $0.block == after.id && $0.severity == .error })
    T.check("so is an item from a block that isn't there",
            problems.contains { $0.block == inner.id && $0.severity == .error })

    let lane1 = Block("text.make", inputs: ["text": text("one")])
    let together = Block(Catalog.parallel, children: [[lane1], [Block("text.make", inputs: ["text": text("two")])]])
    let joined = Block("text.case", inputs: ["text": .output(block: lane1.id, port: "text")])
    let parallelFlow = Flow(body: [together, joined])
    T.check("after Run together, every lane's outputs can be read",
            !FlowCheck.issues(in: parallelFlow, registry: registry).contains { $0.block == joined.id })

    let numberFromFiles = Block("text.math", inputs: ["expression": .trigger(port: "files")])
    let typed = Flow(triggers: [Block(Catalog.folder, inputs: ["folder": text("/tmp")])], body: [numberFromFiles])
    T.check("files into text is converted, so only a warning",
            FlowCheck.issues(in: typed, registry: registry).allSatisfy { $0.severity == .warning })
    let impossible = Block("logic.repeat", inputs: ["times": .trigger(port: "files")])
    T.check("files into a number is an error",
            FlowCheck.issues(in: Flow(triggers: typed.triggers, body: [impossible]), registry: registry)
                .contains { $0.severity == .error })
    T.check("an empty required input stops the flow being switched on",
            !Flow(body: [Block("files.move")]).isRunnable(registry: registry))

    T.begin("Flows — running")

    do {
        let log = EventLog()
        let make = Block("text.make", inputs: ["text": .template([.text("Hello "), .value(.trigger(port: "name"))])])
        let upper = Block("text.case", inputs: ["text": .output(block: make.id, port: "text"), "style": text("UPPERCASE")])
        try await runner(log).run(Flow(body: [make, upper]), trigger: ["name": .text("Ada")], context: context())
        T.equal("blocks run top to bottom", log.finished, [make.id, upper.id])
        T.equal("a template drops values in", log.outputs(make.id)["text"], .text("Hello Ada"))
        T.equal("an output feeds the next block", log.outputs(upper.id)["text"], .text("HELLO ADA"))
    } catch { T.check("a simple flow runs", false, "\(error)") }

    do {
        let log = EventLog()
        let yes = Block("text.make", inputs: ["text": text("yes")])
        let no = Block("text.make", inputs: ["text": text("no")])
        let branch = Block(Catalog.ifElse, inputs: ["value": text("report.pdf"), "test": text("ends with"),
                                                    "other": text(".PDF")], children: [[yes], [no]])
        try await runner(log).run(Flow(body: [branch]), trigger: [:], context: context())
        T.check("If runs the branch the test picks, ignoring case", log.finished.contains(yes.id) && !log.finished.contains(no.id))
    } catch { T.check("If runs", false, "\(error)") }

    do {
        let log = EventLog()
        let set = Block(Catalog.setVariable, inputs: ["name": text("total"), "value": number(0)])
        let item = Block("text.math", inputs: ["expression": .template([.value(.variable("total")), .text(" + 1")])])
        let loop = Block(Catalog.forEach, inputs: ["items": text("a\nb\nc")],
                         children: [[item, Block(Catalog.setVariable, inputs: ["name": text("total"),
                                                                                  "value": .output(block: item.id, port: "result")])]])
        let report = Block("text.make", inputs: ["text": .template([.text("n="), .value(.variable("total"))])])
        try await runner(log).run(Flow(body: [set, loop, report]), trigger: [:], context: context())
        T.equal("For each runs once per line, and variables carry across", log.outputs(report.id)["text"], .text("n=3"))
    } catch { T.check("For each runs", false, "\(error)") }

    do {
        let log = EventLog()
        let slow = Block("logic.wait", inputs: ["seconds": number(0.3)])
        let together = Block(Catalog.parallel, children: [[slow], [Block("logic.wait", inputs: ["seconds": number(0.3)])]])
        let started = Date()
        try await runner(log).run(Flow(body: [together]), trigger: [:], context: context())
        T.check("lanes run at the same time", Date().timeIntervalSince(started) < 0.55,
                String(format: "%.2fs", Date().timeIntervalSince(started)))
    } catch { T.check("Run together runs", false, "\(error)") }

    do {
        let log = EventLog()
        let skipped = Block("text.make", inputs: ["text": text("never")])
        let stop = Block("logic.stop", inputs: ["outcome": text("a success"), "message": text("nothing to do")])
        let said = try await runner(log).run(Flow(body: [stop, skipped]), trigger: [:], context: context())
        T.equal("Stop as a success ends the run quietly", said, "nothing to do")
        T.check("and nothing after it runs", !log.finished.contains(skipped.id))
        _ = try? await runner(log).run(Flow(body: [Block("logic.stop", inputs: ["outcome": text(Catalog.stopAsFailure)])]),
                                       trigger: [:], context: context())
    } catch { T.check("Stop runs", false, "\(error)") }
    do {
        try await runner(EventLog()).run(Flow(body: [Block("logic.stop", inputs: ["outcome": text(Catalog.stopAsFailure),
                                                                               "message": text("bad")])]),
                                         trigger: [:], context: context())
        T.check("Stop as a failure fails the run", false)
    } catch { T.equal("Stop as a failure fails the run, with its message", error.localizedDescription, "bad") }

    do {
        let log = EventLog()
        let broken = Block("files.read", inputs: ["file": .literal(.files([URL(fileURLWithPath: "/no/such")]))], onFailure: .continue)
        let next = Block("text.make", inputs: ["text": text("still here")])
        try await runner(log).run(Flow(body: [broken, next]), trigger: [:], context: context())
        T.check("Carry on: a failing block doesn't stop the flow", log.failed == [broken.id] && log.finished.contains(next.id))
    } catch { T.check("Carry on works", false, "\(error)") }

    do {
        let log = EventLog()
        let broken = Block("files.read", inputs: ["file": .literal(.files([URL(fileURLWithPath: "/no/such")]))], onFailure: .retry(1))
        let started = Date()
        _ = try? await runner(log).run(Flow(body: [broken]), trigger: [:], context: context())
        T.check("Retry tries again after a second, then fails",
                log.failed == [broken.id] && Date().timeIntervalSince(started) >= 0.9)
    }

    do {
        try await runner(EventLog()).run(Flow(body: [Block("logic.wait", inputs: ["seconds": number(5)])]),
                                         trigger: [:], context: context(timeout: 0.3))
        T.check("a run past its time limit is stopped", false)
    } catch { T.equal("a run past its time limit is stopped", error as? FlowError, .timedOut(0)) }

    do {
        let task = Task { try await runner(EventLog()).run(Flow(body: [Block("logic.wait", inputs: ["seconds": number(5)])]),
                                                          trigger: [:], context: context()) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let started = Date()
        _ = try? await task.value
        T.check("Stop ends a run straight away", Date().timeIntervalSince(started) < 1)
    }

    do {
        let log = EventLog()
        let debugger = RunDebugger()
        var held = Block("text.make", inputs: ["text": text("held")])
        held.hasBreakpoint = true
        let task = Task { try await runner(log, debugger: debugger).run(Flow(body: [held]), trigger: [:], context: context()) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        T.check("a breakpoint holds the run before its block", !log.finished.contains(held.id)
                && log.events.contains { if case .paused(held.id) = $0 { return true }; return false })
        await debugger.resume()
        _ = try? await task.value
        T.check("and Continue lets it go on", log.finished.contains(held.id))
    }

    do {
        let log = EventLog()
        let code = Block(Catalog.codeBlockID(.python), inputs: ["code": text("print(1)")])
        try await runner(log).run(Flow(body: [code]), trigger: [:], context: context())
        T.equal("a code block goes to the code runner", log.outputs(code.id)["output"], .text("ran python"))
    } catch { T.check("code blocks run", false, "\(error)") }

    T.begin("Flows — blocks made from blocks")

    do {
        let make = Block("text.make", inputs: ["text": .template([.text("Hi "), .value(.trigger(port: "name"))])])
        let shout = Block("text.case", inputs: ["text": .output(block: make.id, port: "text"), "style": text("UPPERCASE")])
        let reader = Block("text.make", inputs: ["text": .output(block: shout.id, port: "text")])
        let packaged = CustomBlock.package([make, shout], title: "Greet", readBy: [reader], registry: registry)
        T.equal("what the selection read from outside becomes an input", packaged.block.inputs.map(\.name), ["name"])
        T.equal("and the call is bound to it", packaged.call.inputs["name"], .trigger(port: "name"))
        T.equal("what is read afterwards becomes an output", packaged.block.outputs.map(\.name), ["text"])
        let rewired = reader.inputs["text"]!.replacing(packaged.readers)
        T.equal("and the reader now reads the new block", rewired, .output(block: packaged.call.id, port: "text"))
        T.equal("the call names the new block", packaged.call.definition, packaged.block.definitionID)

        let withBlock = BlockRegistry(custom: [packaged.block])
        var after = reader
        after.inputs["text"] = rewired
        let log = EventLog()
        try await runner(log, registry: withBlock).run(Flow(body: [packaged.call, after]),
                                                         trigger: ["name": .text("Ada")], context: context())
        T.equal("a packaged block runs as one", log.outputs(after.id)["text"], .text("HI ADA"))
        T.check("an exported flow carries the blocks it uses",
                withBlock.customBlocks(usedBy: [packaged.call]).map(\.id) == [packaged.block.id])
    } catch { T.check("a packaged block runs", false, "\(error)") }

    T.begin("Flows — built-in blocks")

    await withTempDirAsync { dir in
        let log = EventLog()
        let target = dir.appendingPathComponent("Sorted", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let files = ["Lab report (1).pdf", "photo.png", "notes.txt"].map { dir.appendingPathComponent($0) }
        for file in files { try? Data("x".utf8).write(to: file) }
        let list = Block("files.list", inputs: ["folder": text(dir.path)])
        let filter = Block("files.filter", inputs: ["files": .output(block: list.id, port: "files"),
                                                    "test": text("extension is"), "value": text("pdf")])
        let rename = Block("files.rename", inputs: ["files": .output(block: filter.id, port: "files"),
                                                    "pattern": text("{n} {name}"), "tidy": .literal(.bool(true))])
        let move = Block("files.move", inputs: ["files": .output(block: rename.id, port: "files"), "folder": text(target.path)])
        let count = Block("text.count", inputs: ["items": .output(block: filter.id, port: "rest")])
        do {
            try await runner(log).run(Flow(body: [list, filter, rename, move, count]), trigger: [:], context: context())
            T.equal("listing, filtering, renaming and moving chain", (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? [],
                    ["1 Lab report.pdf"])
            T.equal("what a filter leaves out comes out as Rest", log.outputs(count.id)["count"], .number(2))
        } catch { T.check("file blocks chain", false, "\(error)") }
    }

    T.equal("a rename pattern keeps the extension",
            FileOps.name(for: URL(fileURLWithPath: "/a/Doc.pdf"), pattern: "{folder}-{name}", index: 1), "a-Doc.pdf")
    T.equal("unless it names it",
            FileOps.name(for: URL(fileURLWithPath: "/a/Doc.pdf"), pattern: "{name}.backup.{ext}", index: 1), "Doc.backup.pdf")
    T.equal("Calculate follows precedence", try? Arithmetic.evaluate("2 + 3 × (4 − 1) / 3"), 5)
    T.check("Calculate refuses nonsense", (try? Arithmetic.evaluate("2 +")) == nil)
    T.equal("Get field walks a dotted path", Catalog.field("user.tags.1", of: .text(#"{"user": {"tags": ["a", "b"]}}"#)), .text("b"))
    T.equal("For each walks files one at a time", FlowRunner.items(of: .files([URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])).count, 2)
    T.check("If compares files by name", Condition.holds(.files([URL(fileURLWithPath: "/x/Report.PDF")]), .endsWith, .text(".pdf")))
    T.check("If compares numbers as numbers", Condition.holds(.text("10"), .greater, .number(9)))

    T.begin("Flows — code")

    T.equal("the shell's environment is read between its markers",
            UserEnvironment.parse("noise\n__GRUPPEN_ENV_BEGIN__\0PATH=/a:/b\0EMPTY=\0X=1=2\0__GRUPPEN_ENV_END__"),
            ["PATH": "/a:/b", "EMPTY": "", "X": "1=2"])
    T.check("a shell that printed nothing usable reads as nothing", UserEnvironment.parse("oops") == nil)
    T.equal("session-only variables are dropped",
            UserEnvironment.tidy(["PWD": "/x", "FOO": "bar"], base: [:]), ["FOO": "bar"])
    T.equal("a secret's name as a variable", Secrets.variable(for: "openai key"), "OPENAI_KEY")
    T.equal("secrets are blanked out", Secrets.mask("token=abc123 ok", ["abc123"]), "token=•••• ok")
    T.equal("the same packages make the same environment",
            PackageEnvironments.key("/py", ["Requests", "rich"]), PackageEnvironments.key("/py", ["rich", "requests"]))
    T.check("a different interpreter makes another",
            PackageEnvironments.key("/py", ["rich"]) != PackageEnvironments.key("/py2", ["rich"]))
    T.equal("a Python error names its line",
            CodeFailure.line(in: "Traceback\n  File \"/tmp/x/script.py\", line 3, in <module>", script: "script.py"), 3)
    T.equal("a zsh error names its line", CodeFailure.line(in: "/tmp/script.sh:7: command not found: nope", script: "script.sh"), 7)
    T.check("refused Apple events are explained",
            Permissions.explain("execution error: Not authorized to send Apple events to Finder. (-1743)")?.contains("Automation") == true)
    T.check("Accessibility refusals are explained",
            Permissions.diagnose("osascript is not allowed assistive access. (-25211)")?.permission == .accessibility)
    T.check("other failures are left alone", Permissions.explain("No such file or directory") == nil)
    T.check("a script that tells Finder probably needs Automation for it",
            Permissions.inferred(from: CodeSpec(.applescript, source: "tell application \"Finder\" to beep"))
                .contains(.automation("com.apple.finder")))

    let started = Date()
    let shell = await UserEnvironment.capture()
    T.check("your shell's environment is read, not the fallback", shell.problem == nil, shell.problem ?? "")
    T.check("and quickly — a shell waiting on a terminal would take seconds",
            Date().timeIntervalSince(started) < 3, String(format: "%.2fs", Date().timeIntervalSince(started)))

    let realCode = CodeRunner()
    let shellDefinition = Catalog.definition(Catalog.codeBlockID(.zsh))!
    do {
        let outputs = try await realCode.run(
            CodeSpec(.zsh, source: "echo \"hi $GRUPPEN_IN_INPUT\"\nfor f in \"$@\"; do echo \"$f\"; done\nout count 2\nout note \"two\nlines\""),
            inputs: ["input": .files([URL(fileURLWithPath: "/tmp/a b.txt")])], definition: shellDefinition,
            context: context(timeout: 20), log: { _, _ in })
        T.equal("shell: printed lines are Output, files are arguments", outputs["output"], .text("hi /tmp/a b.txt\n/tmp/a b.txt"))
        T.equal("shell: out hands values on", outputs["result"]?.fields?["count"], .text("2"))
        T.equal("shell: out keeps line breaks", outputs["result"]?.fields?["note"], .text("two\nlines"))
    } catch { T.check("shell code runs", false, "\(error)") }

    do {
        _ = try await realCode.run(CodeSpec(.zsh, source: "echo fine\nfalse_command_xyz\nexit 3"), inputs: [:],
                                   definition: shellDefinition, context: context(timeout: 20), log: { _, _ in })
        T.check("a failing script fails the block", false)
    } catch { T.check("a failing script says why, with its line", error.localizedDescription.contains("false_command_xyz"),
                      error.localizedDescription) }

    let lines = LineLog()
    _ = try? await realCode.run(CodeSpec(.zsh, source: "echo one\necho two >&2"), inputs: [:], definition: shellDefinition,
                                context: context(timeout: 20), log: { lines.add($0, $1) })
    T.equal("output streams to the console line by line", lines.all.map(\.0).sorted(), ["one", "two"])

    let python = Interpreters.available(for: .python, path: UserEnvironment.fallbackPath).first
    if python != nil {
        do {
            let outputs = try await realCode.run(
                CodeSpec(.python, source: "import sys\nprint(len(sys.argv) - 1)\ngruppen.out(n=len(gruppen.files('input')), name=gruppen.inputs['name'])"),
                inputs: ["input": .files([URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]), "name": .text("x")],
                definition: Catalog.definition(Catalog.codeBlockID(.python))!, context: context(timeout: 30), log: { _, _ in })
            T.equal("python: files are argv", outputs["output"], .text("2"))
            T.equal("python: gruppen.out hands values on", outputs["result"], .record(["n": .number(2), "name": .text("x")]))
        } catch { T.check("python code runs", false, "\(error)") }
        do {
            _ = try await realCode.run(CodeSpec(.python, source: "x = 1\nraise ValueError('nope')"), inputs: [:],
                                       definition: Catalog.definition(Catalog.codeBlockID(.python))!,
                                       context: context(timeout: 30), log: { _, _ in })
        } catch { T.equal("python: an error names the line in your code, and the error itself",
                          error.localizedDescription, "Line 2: ValueError: nope") }
    } else {
        T.note("Python 3 not installed — its checks skipped")
    }

    do {
        let outputs = try await realCode.run(CodeSpec(.applescript, source: "on run argv\nreturn (count of argv) as text\nend run"),
                                             inputs: ["input": .files([URL(fileURLWithPath: "/a")])],
                                             definition: Catalog.definition(Catalog.codeBlockID(.applescript))!,
                                             context: context(timeout: 20), log: { _, _ in })
        T.equal("AppleScript: argv holds the files, the result is Output", outputs["output"], .text("1"))
    } catch { T.check("AppleScript runs", false, "\(error)") }
}

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(String, Bool)] = []
    func add(_ line: String, _ isError: Bool) { lock.lock(); lines.append((line, isError)); lock.unlock() }
    var all: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return lines }
}

@MainActor
func sectionFlowEditing() {
    let registry = BlockRegistry()
    func text(_ value: String) -> ValueSource { .literal(.text(value)) }

    T.begin("Flows — editing on the canvas")

    let a = Block("text.make"), b = Block("text.make"), c = Block("text.make")
    var flow = Flow(body: [a, b, c])
    flow.move([a.id], to: .body, at: 3, registry: registry)
    T.equal("moving a block down lands where the line was", flow.body.map(\.id), [b.id, c.id, a.id])
    flow.move([a.id], to: .body, at: 0, registry: registry)
    T.equal("and back up", flow.body.map(\.id), [a.id, b.id, c.id])

    let branch = Block(Catalog.ifElse, children: [[], []])
    flow.insert([branch], into: .body, at: 3, registry: registry)
    flow.move([b.id, c.id], to: .slot(block: branch.id, index: 1), at: 0, registry: registry)
    T.equal("blocks move into a container's slot", flow.block(branch.id)?.children[1].map(\.id), [b.id, c.id])
    T.equal("and leave where they were", flow.body.map(\.id), [a.id, branch.id])
    flow.move([branch.id], to: .slot(block: branch.id, index: 0), at: 0, registry: registry)
    T.equal("a container can't go inside itself", flow.body.map(\.id), [a.id, branch.id])
    T.equal("a block is found inside a container", flow.location(of: c.id)?.stack, .slot(block: branch.id, index: 1))

    flow.insert([Block(Catalog.folder)], into: .body, at: 0, registry: registry)
    T.equal("a hat is kept out of the body", flow.body.count, 2)
    flow.insert([Block("text.make")], into: .triggers, at: 0, registry: registry)
    T.check("and a plain block out of the triggers", flow.triggers.isEmpty)

    flow.addLoose([Block("text.make")], at: CGPoint(x: 400, y: 300), registry: registry)
    T.equal("a block dropped on empty canvas starts a loose stack", flow.loose.count, 1)
    let looseID = flow.loose[0].blocks[0].id
    flow.remove([looseID])
    T.check("a loose stack left empty goes", flow.loose.isEmpty)

    T.equal("⇧-drag picks up the block and those under it",
            Flow(body: [a, b, c]).blockAndFollowing(b.id), [b.id, c.id])

    let reader = Block("text.case", inputs: ["text": .output(block: a.id, port: "text")])
    var wired = Flow(body: [a, reader])
    let removed = wired.remove([a.id])
    wired.dropBindings(to: Set(removed.map(\.id)))
    T.check("deleting a block clears what read from it", wired.body[0].inputs["text"] == nil)

    var natural = Flow(triggers: [Block(Catalog.folder, inputs: ["folder": text("/tmp")])], body: [])
    let zip = Block("files.zip")
    natural.insert([zip], into: .body, at: 0, registry: registry)
    natural.bindNaturally(zip.id, registry: registry)
    T.equal("a new block's files input reads the latest files before it",
            natural.block(zip.id)?.inputs["files"], .trigger(port: "files"))
    let reveal = Block("files.reveal")
    natural.insert([reveal], into: .body, at: 1, registry: registry)
    natural.bindNaturally(reveal.id, registry: registry)
    T.equal("the latest, not the first", natural.block(reveal.id)?.inputs["files"], .output(block: zip.id, port: "zip"))

    T.begin("Flows — how flows read")

    let folderFlow = Flow(triggers: [Block(Catalog.folder, inputs: ["folder": text("/Users/x/Downloads")])])
    T.equal("a trigger reads as a sentence", FlowCheck.sentence(for: folderFlow, registry: registry),
            "When a file lands in Downloads")
    T.equal("no trigger reads as by hand", FlowCheck.sentence(for: Flow(), registry: registry), "When I run it")
    let schedule = Flow(triggers: [Block("when.schedule")])
    T.equal("a schedule reads its time and days", FlowCheck.sentence(for: schedule, registry: registry),
            "At 08:30 on weekdays")
    T.equal("a battery trigger reads its level", FlowCheck.sentence(for: Flow(triggers: [Block(Catalog.battery)]), registry: registry),
            "When the battery drops below 20 %")

    T.begin("Flows — templates")

    for template in FlowTemplate.all {
        let made = template.make()
        let errors = FlowCheck.issues(in: made, registry: registry).filter { $0.severity == .error }
            // The webhook template leaves its address for you to fill in.
            .filter { !(template.id == "webhook" && $0.port == "url") }
        T.check("\(template.name) is a working flow", errors.isEmpty, errors.map(\.message).joined(separator: "; "))
    }

    T.begin("Flows — sharing")

    withTempDir { dir in
        let library = FlowLibrary(folder: dir)
        var custom = CustomBlock(title: "Shout", inputs: [Port("text", nil, .text)], outputs: [Port("result", nil, .text)],
                                 body: .code(CodeSpec(.python, source: "print('hi')")))
        library.saveBlock(custom)
        let flow = library.add(Flow(name: "Shares", isEnabled: true, body: [Block(custom.definitionID)]))
        let file = dir.appendingPathComponent("x.gruppenflow")
        T.check("a flow exports", library.export(flow.id, to: file))
        guard let incoming = try? library.read(file) else { T.check("and reads back", false); return }
        T.equal("an exported flow carries the blocks it uses", incoming.blocks.map(\.id), [custom.id])
        T.check("and its code is there to be shown before importing", incoming.code.contains { $0.spec.source == "print('hi')" })
        let imported = library.add(incoming)
        T.check("an imported flow arrives switched off", imported?.isEnabled == false)
        T.check("under a new id", imported?.id != flow.id)

        custom.inputs.append(Port("more", nil, .text))
        library.saveBlock(custom)
        T.equal("changing a block's inputs bumps its version", library.blocks.first?.version, 2)
        T.equal("the block is saved as a file of its own",
                (try? FileManager.default.contentsOfDirectory(atPath: library.blocksFolder.path))?.count, 1)
        T.equal("the flows that use a block are known", library.flows(using: custom.id).count, 2)
        // Flows are saved half a second after the last change; quitting saves at once.
        library.saveNow()
        let reloaded = FlowLibrary(folder: dir)
        T.equal("blocks and flows load back", reloaded.blocks.count * 10 + reloaded.flows.count, 12)
    }
}
