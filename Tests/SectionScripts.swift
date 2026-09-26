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
        T.equal("an unknown action kind falls back to shell", script.action.kind, .shellCommand)
        T.equal("an unknown interpreter falls back to zsh", script.action.interpreter, .zsh)
        T.equal("an unknown feedback falls back to silent", script.feedback, .silent)
        T.check("the command survives the migration", script.action.command == "echo hi")
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
    script.action.command = "echo hi"
    T.check("a manual script is complete but arms nothing", script.isArmable,
            "isArmable means complete; the coordinator installs no observer for .manual")
    script.trigger.kind = .hotkey
    T.equal("a hotkey trigger with no shortcut is not configured",
            script.trigger.isConfigured, false)
}
