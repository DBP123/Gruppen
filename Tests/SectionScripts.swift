import AppKit
import Foundation

func sectionScripts() async {
    T.begin("C. Scripts — model")

    var action = ScriptAction()
    action.kind = .shellCommand
    action.interpreter = .jxa          // deliberately wrong for a shell command
    T.equal("a shell command is zsh whatever the stored interpreter says",
            action.effectiveInterpreter, .zsh)
    T.equal("zsh lives at a path every Mac has", ScriptAction.Interpreter.zsh.path, "/bin/zsh")
    T.equal("JXA runs through osascript", ScriptAction.Interpreter.jxa.path, "/usr/bin/osascript")
    T.check("both interpreters exist on this machine",
            ScriptExecutionEngine.interpreterExists(.zsh)
            && ScriptExecutionEngine.interpreterExists(.jxa),
            "neither is a developer tool, so this must hold on a clean install")

    action = ScriptAction()
    T.check("an empty shell command is not configured", !action.isConfigured)
    action.command = "echo hi"
    T.check("a shell command with text is configured", action.isConfigured)

    action = ScriptAction()
    action.kind = .webhook
    action.webhookURL = "not a url"
    T.check("a webhook needs a real http URL", !action.isConfigured)
    action.webhookURL = "ftp://example.com"
    T.check("a non-http scheme is refused", !action.isConfigured)
    action.webhookURL = "https://example.com/hook"
    T.check("an https URL is accepted", action.isConfigured)

    // A library written by an older build must not vanish because one enum
    // case was renamed.
    let legacy = """
    {"id":"11111111-1111-1111-1111-111111111111","name":"Old","isActive":true,
     "trigger":{"kind":"folderWatch"},
     "action":{"kind":"somethingRemoved","interpreter":"perl","command":"echo hi"},
     "feedback":"depositOnShelf"}
    """.data(using: .utf8)!
    if let script = try? JSONDecoder().decode(Script.self, from: legacy) {
        T.equal("an old action becomes step 01", script.steps.count, 1)
        T.equal("an unknown action kind falls back to shell", script.steps.first?.kind, .shell)
        T.equal("an unknown interpreter falls back to zsh", script.steps.first?.code.interpreter, .zsh)
        T.equal("an unknown feedback falls back to silent", script.output,
                ScriptOutput(onSuccess: .none, onFailure: .none))
        T.check("the command survives the migration", script.steps.first?.code.command == "echo hi")
    } else {
        T.check("a script from an older build still decodes", false, "decode threw")
    }

    T.begin("C. Scripts — execution")

    // Exit status and both streams.
    var ok = ScriptAction()
    ok.kind = .scriptCode
    ok.isCustomised = true
    ok.source = "echo out; echo err >&2; exit 0"
    do {
        let run = try await ScriptExecutionEngine.run(ok)
        T.check("stdout is captured", run.output.contains("out"), run.output.trimmingCharacters(in: .newlines))
        T.check("stderr is captured", run.errorOutput.contains("err"))
        T.equal("a clean exit reports 0", run.exitCode, 0)
    } catch { T.check("a simple script runs", false, "\(error)") }

    var fails = ScriptAction()
    fails.kind = .scriptCode
    fails.isCustomised = true
    fails.source = "exit 3"
    do {
        _ = try await ScriptExecutionEngine.run(fails)
        T.check("a non-zero exit throws", false, "no error raised")
    } catch {
        if case ScriptError.exited(let code, _) = error {
            T.equal("a non-zero exit throws with its code", code, 3)
        } else {
            T.check("a non-zero exit throws with its code", false, "\(error)")
        }
    }

    // THE security claim: paths are argv, never spliced into the source.
    await withTempDirAsync { dir -> Void in
        let canary = dir.appendingPathComponent("canary")
        let hostile = dir.appendingPathComponent("; touch \(canary.path); echo pwned")
        FileManager.default.createFile(atPath: hostile.path, contents: Data())

        var echo = ScriptAction()
        echo.kind = .scriptCode
        echo.isCustomised = true
        echo.source = #"for f in "$@"; do echo "$f"; done"#
        do {
            let run = try await ScriptExecutionEngine.run(echo, paths: [hostile])
            T.check("a hostile file name is not executed",
                    !FileManager.default.fileExists(atPath: canary.path),
                    "the injected `touch` never ran")
            T.check("a hostile file name arrives intact as an argument",
                    run.output.contains("; touch"),
                    "passed through as data")
        } catch { T.check("a hostile file name is not executed", false, "\(error)") }
    }

    // The documented pipe-buffer deadlock: more output than one buffer holds.
    var chatty = ScriptAction()
    chatty.kind = .scriptCode
    chatty.isCustomised = true
    chatty.source = "for i in $(seq 1 20000); do echo 'the quick brown fox jumps over the lazy dog'; done"
    do {
        let run = try await ScriptExecutionEngine.run(chatty, timeout: 30)
        T.check("output larger than a pipe buffer does not deadlock",
                run.output.count > 800_000, "\(run.output.count) bytes drained")
    } catch { T.check("output larger than a pipe buffer does not deadlock", false, "\(error)") }

    // The watchdog.
    var runaway = ScriptAction()
    runaway.kind = .scriptCode
    runaway.isCustomised = true
    runaway.source = "sleep 30"
    let started = Date()
    do {
        _ = try await ScriptExecutionEngine.run(runaway, timeout: 2)
        T.check("a runaway script is stopped", false, "it was allowed to finish")
    } catch {
        let elapsed = Date().timeIntervalSince(started)
        if case ScriptError.timedOut = error {
            T.check("a runaway script is stopped at its timeout", elapsed < 6,
                    String(format: "killed after %.1fs", elapsed))
        } else {
            T.check("a runaway script times out", false, "\(error)")
        }
    }

    // An empty action must not spawn anything.
    var empty = ScriptAction()
    empty.kind = .scriptCode
    empty.isCustomised = true
    empty.source = "   \n  "
    do {
        _ = try await ScriptExecutionEngine.run(empty)
        T.check("an empty script is refused before spawning", false, "it ran")
    } catch {
        T.check("an empty script is refused before spawning",
                (error as? ScriptError) == .noSource, "\(error)")
    }

    // JXA, since it is the other half of the matrix and uses a different path.
    var jxa = ScriptAction()
    jxa.kind = .scriptCode
    jxa.interpreter = .jxa
    do {
        let run = try await ScriptExecutionEngine.run(jxa, paths: [URL(fileURLWithPath: "/tmp/a")])
        T.check("the generated JXA template runs", run.succeeded, run.transcript.prefix(40).description)
    } catch { T.check("the generated JXA template runs", false, "\(error)") }

    // isArmable is what decides whether a trigger is installed at all.
    var script = Script()
    script.isActive = true
    script.trigger.kind = .manual
    script.steps[0].code.command = "echo hi"
    T.check("a manual script is complete but arms nothing", script.isArmable,
            "isArmable means complete; the coordinator installs no observer for .manual")
    script.trigger.kind = .hotkey
    T.equal("a hotkey trigger with no shortcut is not configured",
            script.trigger.isConfigured, false)
}

func sectionScriptSteps() async {
    T.begin("C. Scripts — steps and migration")

    func legacy(_ action: String, feedback: String = "silent") -> Script? {
        let json = #"{"name":"Old","trigger":{"kind":"manual"},"action":\#(action),"feedback":"\#(feedback)"}"#
        return try? JSONDecoder().decode(Script.self, from: Data(json.utf8))
    }
    let zsh = legacy(#"{"kind":"scriptCode","interpreter":"zsh","isCustomised":true,"source":"echo old"}"#)
    T.equal("old zsh code becomes a shell step", zsh?.steps.first?.kind, .shell)
    T.check("its source survives, hand-written", zsh?.steps.first?.code.isCustomised == true
            && zsh?.steps.first?.code.source == "echo old")
    T.equal("old JXA becomes a JavaScript step",
            legacy(#"{"kind":"scriptCode","interpreter":"jxa"}"#)?.steps.first?.kind, .javascript)
    T.equal("an old webhook stays a webhook",
            legacy(#"{"kind":"webhook","webhookURL":"https://example.com"}"#)?.steps.first?.kind, .webhook)
    T.equal("a banner becomes a notification either way",
            legacy(#"{"kind":"shellCommand"}"#, feedback: "banner")?.output,
            ScriptOutput(onSuccess: .notification, onFailure: .notification))

    var step = ScriptStep.make(.moveTo)
    T.check("a move with no folder is not set up", !step.isConfigured)
    step.folder = "/tmp"
    T.check("a move with a folder is", step.isConfigured)
    step.setKind(.copyTo)
    T.equal("switching kind keeps what was typed", step.folder, "/tmp")
    step.setKind(.javascript)
    T.equal("a JavaScript step runs through osascript as JXA", step.code.effectiveInterpreter, .jxa)
    step.setKind(.applescript)
    T.equal("an AppleScript step runs through osascript as AppleScript",
            step.code.effectiveInterpreter, .applescript)
    T.check("a zip needs nothing set", ScriptStep.make(.zip).isConfigured, "empty folder means the download folder")
    var link = ScriptStep.make(.openURL)
    link.url = "not a url"
    T.check("an open-URL step needs a URL with a scheme", !link.isConfigured)

    var script = Script()
    script.isActive = true
    script.steps = [ScriptStep.make(.moveTo)]
    T.check("one unfinished step keeps a script from arming", !script.isArmable)

    do {
        var applescript = ScriptAction()
        applescript.kind = .scriptCode
        applescript.interpreter = .applescript
        let run = try await ScriptExecutionEngine.run(applescript, paths: [URL(fileURLWithPath: "/tmp/a")])
        T.check("the AppleScript template runs", run.output.contains("1"), run.transcript)
    } catch { T.check("the AppleScript template runs", false, "\(error)") }

    T.begin("C. Scripts — files down the bus")

    await withTempDirAsync { dir -> Void in
        let source = dir.appendingPathComponent("in", isDirectory: true)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let a = source.appendingPathComponent("a.txt")
        let b = source.appendingPathComponent("b.txt")
        try? "alpha".write(to: a, atomically: true, encoding: .utf8)
        try? "beta".write(to: b, atomically: true, encoding: .utf8)

        var copy = ScriptStep.make(.copyTo)
        copy.folder = out.path
        var zip = ScriptStep.make(.zip)
        zip.folder = out.path
        var check = ScriptStep.make(.shell)
        check.code.isCustomised = true
        check.code.source = #"test "$#" -eq 1 && unzip -l "$1" | grep -q b.txt && echo zipped"#

        do {
            var files = [a, b]
            for step in [copy, zip, check] {
                files = try await ScriptRunner.perform(step, files: files, hooks: .init()).files
            }
            T.check("copy leaves the originals", FileManager.default.fileExists(atPath: a.path))
            T.check("copy puts the files in the folder",
                    FileManager.default.fileExists(atPath: out.appendingPathComponent("b.txt").path))
            T.equal("the zip hands on one file, the archive", files.count, 1)
            T.equal("and it is a zip", files.first?.pathExtension, "zip")
        } catch { T.check("copy → zip → shell runs end to end", false, "\(error)") }

        do {
            _ = try await ScriptRunner.perform(copy, files: [a], hooks: .init())
            T.check("a second copy never overwrites",
                    FileManager.default.fileExists(atPath: out.appendingPathComponent("a 2.txt").path))
        } catch { T.check("a second copy never overwrites", false, "\(error)") }

        var move = ScriptStep.make(.moveTo)
        move.folder = out.path
        do {
            let moved = try await ScriptRunner.perform(move, files: [b], hooks: .init()).files
            T.check("a move takes the file out of its folder", !FileManager.default.fileExists(atPath: b.path))
            T.check("and hands on where it went", moved.first?.deletingLastPathComponent().path == out.path)
        } catch { T.check("a move runs", false, "\(error)") }

        move.folder = dir.appendingPathComponent("nowhere").path
        do {
            _ = try await ScriptRunner.perform(move, files: [a], hooks: .init())
            T.check("a move to a missing folder fails", false, "it succeeded")
        } catch {
            T.check("a move to a missing folder fails, and says which",
                    error.localizedDescription.contains("nowhere"), error.localizedDescription)
        }
    }

    T.begin("C. Scripts — runs and history")

    await withTempDirAsync { dir -> Void in
        let file = dir.appendingPathComponent("scripts.json")
        let (library, coordinator) = await MainActor.run { () -> (ScriptLibrary, ScriptTriggerCoordinator) in
            let library = ScriptLibrary(fileURL: file)
            return (library, ScriptTriggerCoordinator(library: library))
        }

        let good: Script = {
            var script = Script(name: "Good")
            script.steps[0].code.command = "echo hello"
            return script
        }()
        let bad: Script = {
            var script = Script(name: "Bad")
            script.steps = [ScriptStep.make(.shell), ScriptStep.make(.wait)]
            script.steps[0].code.isCustomised = true
            script.steps[0].code.source = "exit 2"
            return script
        }()
        await MainActor.run { library.scripts = [good, bad] }

        let started = await MainActor.run { coordinator.run(good, paths: []) }
        let twice = await MainActor.run { coordinator.run(good, paths: []) }
        T.check("a run starts", started)
        T.check("a script already running is not started again", !twice)
        await MainActor.run { _ = coordinator.run(bad, paths: []) }

        for _ in 0..<50 {
            let done = await MainActor.run { library.runs[good.id]?.count == 1 && library.runs[bad.id]?.count == 1 }
            if done { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let goodRun = await MainActor.run { library.runs[good.id]?.last }
        let badRun = await MainActor.run { library.runs[bad.id]?.last }
        T.check("a good run is recorded as a success", goodRun?.succeeded == true, goodRun?.summary ?? "no record")
        T.check("its output is what the step said", goodRun?.summary.contains("hello") == true)
        T.check("a failed run is recorded as a failure", badRun?.succeeded == false)
        T.equal("a run stops at the step that failed", badRun?.steps.count, 1)

        let reloaded = await MainActor.run { ScriptLibrary(fileURL: file).runs[good.id]?.count }
        T.equal("history survives a relaunch", reloaded, 1)

        await MainActor.run {
            for _ in 0..<(ScriptLibrary.runLimit + 5) {
                library.record(ScriptRunRecord(date: Date(), source: "Test", duration: 0, steps: []), for: good.id)
            }
        }
        let capped = await MainActor.run { library.runs[good.id]?.count ?? 0 }
        T.equal("history is capped", capped, ScriptLibrary.runLimit)

        let copy = await MainActor.run { library.duplicate(good) }
        T.check("a duplicate gets steps of its own", copy.steps.first?.id != good.steps.first?.id)
        await MainActor.run { library.remove(good) }
        let afterRemove = await MainActor.run { ScriptLibrary(fileURL: file).runs[good.id] }
        T.check("deleting a script deletes its history", afterRemove == nil)
    }
}

func sectionScriptTransfer() async {
    T.begin("C. Scripts — import and export")

    await withTempDirAsync { dir -> Void in
        let library = await MainActor.run { ScriptLibrary(fileURL: dir.appendingPathComponent("scripts.json")) }

        var original = Script(name: "Tidy", isActive: true)
        original.trigger.kind = .folderWatch
        original.trigger.watchedFolder = "/tmp"
        var move = ScriptStep.make(.moveTo)
        move.folder = "/tmp/out"
        original.steps = [move]
        original.output = ScriptOutput(onSuccess: .sound, onFailure: .notification)

        let file = dir.appendingPathComponent("Tidy.gruppenscript")
        do { try ScriptLibrary.exportData(original).write(to: file) } catch {
            T.check("a script exports", false, "\(error)")
        }
        do {
            let imported = try await MainActor.run { try library.importScript(from: file) }
            T.equal("the trigger comes back", imported.trigger, original.trigger)
            T.equal("the step comes back", imported.steps.first?.folder, "/tmp/out")
            T.equal("the output comes back", imported.output, original.output)
            T.check("it arrives switched off", !imported.isActive)
            T.check("with identifiers of its own",
                    imported.id != original.id && imported.steps.first?.id != move.id)
        } catch { T.check("an exported script imports", false, "\(error)") }

        let shell = dir.appendingPathComponent("backup.sh")
        try? "rsync -a ~/Documents /Volumes/Backup".write(to: shell, atomically: true, encoding: .utf8)
        do {
            let imported = try await MainActor.run { try library.importScript(from: shell) }
            T.equal("a .sh file becomes a shell step", imported.steps.first?.kind, .shell)
            T.check("holding the file's text", imported.steps.first?.code.effectiveSource.contains("rsync") == true)
            T.equal("named after the file", imported.name, "backup")
            T.equal("and runs only by hand", imported.trigger.kind, .manual)
        } catch { T.check("a .sh file imports", false, "\(error)") }

        let junk = dir.appendingPathComponent("notes.txt")
        try? "hello".write(to: junk, atomically: true, encoding: .utf8)
        let refused = await MainActor.run { (try? library.importScript(from: junk)) == nil }
        T.check("a file that is not a script is refused", refused)
    }
}

func sectionAutomationEngine() async {
    T.begin("C. Automations — rule conditions")

    await withTempDirAsync { dir -> Void in
        let pdf = dir.appendingPathComponent("ENGR 133 Lab Report.pdf")
        try? Data(repeating: 1, count: 2_000_000).write(to: pdf)
        // What Safari and Chrome write as they save a download.
        let froms = try! PropertyListSerialization.data(
            fromPropertyList: ["https://purdue.instructure.com/files/1/download", "https://purdue.instructure.com/courses/1"],
            format: .binary, options: 0)
        _ = froms.withUnsafeBytes {
            setxattr(pdf.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, froms.count, 0, 0)
        }

        T.check("kind is PDF", RuleCondition(.family, family: .pdf).matches(pdf))
        T.check("kind is not image", !RuleCondition(.family, family: .image).matches(pdf))
        T.check("extension, with or without the dot", RuleCondition(.ext, text: ".PDF").matches(pdf))
        T.check("name contains, any case", RuleCondition(.nameContains, text: "engr 133").matches(pdf))
        T.check("name starts with", RuleCondition(.nameStartsWith, text: "ENGR").matches(pdf))
        T.check("downloaded from reads the browser's record",
                RuleCondition(.downloadedFrom, text: "instructure").matches(pdf),
                FileFacts.whereFroms(pdf).first ?? "none")
        T.check("an empty condition matches nothing", !RuleCondition(.nameContains, text: " ").matches(pdf))
        T.check("not older than 7 days today", !RuleCondition(.olderThan, number: 7).matches(pdf))
        T.check("older than 7 days a fortnight from now",
                RuleCondition(.olderThan, number: 7).matches(pdf, now: Date().addingTimeInterval(14 * 86_400)))
        T.check("larger than 1 MB", RuleCondition(.largerThan, number: 1).matches(pdf))

        var trigger = ScriptTrigger()
        trigger.kind = .folderWatch
        trigger.conditions = [RuleCondition(.family, family: .pdf), RuleCondition(.nameContains, text: "chem")]
        T.check("all conditions: one fails, no match", !trigger.admits(pdf))
        trigger.matchAll = false
        T.check("any condition: one passes, match", trigger.admits(pdf))
        T.check("an age condition makes a rule sweep its folder",
                { var t = trigger; t.conditions.append(RuleCondition(.olderThan)); return t.sweepsExisting }())
    }

    T.begin("C. Automations — text tools and renaming")

    T.equal("smart quotes and spacing come out plain",
            TextTools.clean("“Hello”  — it’s\u{00A0}done   \n\n\n\nnext"), "\"Hello\" - it's done\n\nnext")
    T.equal("tracking is stripped from links, real parameters kept",
            TextTools.cleanLinks("see https://example.com/page?id=7&utm_source=x&fbclid=abc now"),
            "see https://example.com/page?id=7 now")
    T.equal("a link left with no parameters loses its ?",
            TextTools.cleanLinks("https://example.com/a?utm_medium=email"), "https://example.com/a")
    T.equal("sentence case", TextTools.change("HELLO THERE. HOW ARE YOU?", to: .sentence), "Hello there. How are you?")
    T.equal("title case", TextTools.change("lab report two", to: .title), "Lab Report Two")

    var october = DateComponents()
    october.year = 2026; october.month = 10; october.day = 12
    let date = Calendar.current.date(from: october)!
    T.equal("date prefix", RenameStyle.datePrefix.apply(to: "Lab.pdf", date: date), "2026-10-12 Lab.pdf")
    T.equal("text prefix", RenameStyle.textPrefix.apply(to: "Lab.pdf", prefix: "ENGR133"), "ENGR133 Lab.pdf")
    T.equal("clean drops a browser's duplicate marker", RenameStyle.clean.apply(to: "Lab report (1).pdf"), "Lab report.pdf")
    T.equal("clean collapses underscores and spaces", RenameStyle.clean.apply(to: "my__file   name.txt"), "my file name.txt")

    var schedule = ScriptTrigger()
    schedule.kind = .schedule
    schedule.minuteOfDay = 8 * 60 + 30
    schedule.weekdays = [2]   // Monday
    var sunday = DateComponents()
    sunday.year = 2026; sunday.month = 10; sunday.day = 11; sunday.hour = 12
    let next = schedule.nextOccurrence(after: Calendar.current.date(from: sunday)!)
    let parts = next.map { Calendar.current.dateComponents([.weekday, .hour, .minute, .day], from: $0) }
    T.check("a Monday 8:30 schedule next falls on Monday the 12th at 8:30",
            parts?.weekday == 2 && parts?.hour == 8 && parts?.minute == 30 && parts?.day == 12,
            next.map { "\($0)" } ?? "none")

    T.begin("C. Automations — new file actions")

    await withTempDirAsync { dir -> Void in
        let file = dir.appendingPathComponent("Notes (1).txt")
        try? "notes".write(to: file, atomically: true, encoding: .utf8)

        var rename = ScriptStep.make(.rename)
        rename.renameStyle = .clean
        do {
            let out = try await ScriptRunner.perform(rename, files: [file], hooks: .init()).files
            T.equal("rename cleans the name on disk", out.first?.lastPathComponent, "Notes.txt")
        } catch { T.check("rename runs", false, "\(error)") }

        let cleaned = dir.appendingPathComponent("Notes.txt")
        var tag = ScriptStep.make(.tag)
        tag.text = "School"
        do {
            _ = try await ScriptRunner.perform(tag, files: [cleaned], hooks: .init())
            let tags = (try? cleaned.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            T.check("a tag is added", tags.contains("School"), tags.description)
        } catch { T.check("tag runs", false, "\(error)") }

        let out = dir.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var copy = ScriptStep.make(.copyTo)
        copy.folder = out.path
        copy.subfolder = .month
        do {
            let placed = try await ScriptRunner.perform(copy, files: [cleaned], hooks: .init()).files
            let month = placed.first?.deletingLastPathComponent().lastPathComponent ?? ""
            T.check("a copy by month lands in a yyyy-MM folder",
                    month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil, month)
        } catch { T.check("copy by month runs", false, "\(error)") }

        // A JPEG compresses in place, so nothing goes to the Trash.
        let jpeg = dir.appendingPathComponent("photo.jpg")
        if let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let image = { context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
                         context.fill(CGRect(x: 0, y: 0, width: 400, height: 300)); return context.makeImage() }(),
           let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        do {
            let result = try await ScriptRunner.perform(ScriptStep.make(.compress), files: [jpeg], hooks: .init()).files
            T.check("a JPEG is compressed in its place", result.first?.path == jpeg.path
                    && FileManager.default.fileExists(atPath: jpeg.path))
        } catch { T.check("compress runs", false, "\(error)") }
    }

    T.begin("C. Automations — a rule never loops on its own output")

    await withTempDirAsync { dir -> Void in
        let (library, coordinator) = await MainActor.run { () -> (ScriptLibrary, ScriptTriggerCoordinator) in
            let library = ScriptLibrary(fileURL: dir.appendingPathComponent("scripts.json"))
            return (library, ScriptTriggerCoordinator(library: library))
        }
        let inbox = dir.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let rule: Script = {
            var script = Script(name: "Date stamp", isActive: true)
            script.trigger.kind = .folderWatch
            script.trigger.watchedFolder = inbox.path
            var step = ScriptStep.make(.rename)
            step.renameStyle = .datePrefix
            script.steps = [step]
            return script
        }()
        await MainActor.run { library.scripts = [rule] }   // rearms through onChange
        try? await Task.sleep(nanoseconds: 500_000_000)
        try? "x".write(to: inbox.appendingPathComponent("arrival.txt"), atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        T.equal("one file, renamed once", names.count, 1)
        T.check("with exactly one date in front",
                names.first.map { $0.range(of: #"^\d{4}-\d{2}-\d{2} arrival\.txt$"#, options: .regularExpression) != nil } ?? false,
                names.first ?? "none")
        await MainActor.run { coordinator.disarm() }
    }
}
