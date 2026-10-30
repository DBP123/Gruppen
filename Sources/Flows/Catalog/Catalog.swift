import Foundation

/// Every built-in block, by category.
///
/// The implementations are the app's existing tools — `FileManager`,
/// `StashExporter`, `FileConverter`, `StashFileMerger`, `TextTools` — moved
/// here from the old step runner, not rewritten. Nothing here owns a timer or
/// a thread: file work runs on the run's own task, and blocks that touch
/// AppKit hop to the main actor for that moment only.
enum Catalog {
    static let all: [BlockDefinition] =
        triggers + logic + files + text + apps + system + gruppen + clipboard + web + code

    static func definition(_ id: String) -> BlockDefinition? { all.first { $0.id == id } }

    // Ids other code names directly.
    static let manual = "when.manual"
    static let folder = "when.folder"
    static let hotkey = "when.hotkey"
    static let stash = "when.stash"
    static let battery = "when.battery"
    static let external = "when.external"
    static let ifElse = "logic.if"
    static let forEach = "logic.forEach"
    static let parallel = "logic.parallel"
    static let setVariable = "logic.setVariable"
    static let stopAsFailure = "a failure"

    /// The code blocks, one per language, in palette order.
    static func codeBlockID(_ language: CodeLanguage) -> String { "code.\(language.rawValue)" }

    // MARK: Triggers

    static let triggers: [BlockDefinition] = [
        BlockDefinition(manual, "Run by hand", category: .triggers, glyph: "hand.tap",
                        phrase: "When I run it",
                        help: "Its Run key, the quick palette, the menu bar, or `gruppen run`",
                        shape: .hat, essential: true, .trigger(.manual)),
        BlockDefinition(hotkey, "Key combination", category: .triggers, glyph: "command",
                        phrase: "When I press {keys}", help: "From anywhere on the Mac",
                        shape: .hat, inputs: [Port("keys", "Keys", .text, .hotkey)],
                        essential: true, .trigger(.hotkey)),
        BlockDefinition("when.schedule", "At a time", category: .triggers, glyph: "clock",
                        phrase: "At {time} on {days}",
                        help: "One wake-up at the next matching time — nothing runs in between. A time missed while the Mac slept runs on waking",
                        shape: .hat,
                        inputs: [Port("time", "Time", .number, .time, default: .number(8 * 60 + 30)),
                                 Port("days", "Days", .text, .weekdays, default: .text("2,3,4,5,6"))],
                        essential: true, .trigger(.schedule)),
        BlockDefinition("when.interval", "Every few minutes", category: .triggers, glyph: "repeat",
                        phrase: "Every {minutes} minutes", shape: .hat,
                        inputs: [Port("minutes", "Minutes", .number, default: .number(30))],
                        .trigger(.interval)),
        BlockDefinition(folder, "File lands in a folder", category: .triggers, glyph: "folder",
                        phrase: "When a file lands in {folder}",
                        help: "Each new file is handed over as it arrives — files already there are left alone",
                        shape: .hat, inputs: [Port("folder", "Folder", .text, .folder)],
                        outputs: [Port("files", "New files", .files)], essential: true, .trigger(.folder)),
        BlockDefinition("when.app", "App launches or quits", category: .triggers, glyph: "app.badge",
                        phrase: "When {app} {event}",
                        help: "An app by its bundle, or a command-line process by name — java, node, python3",
                        shape: .hat,
                        inputs: [Port("app", "App", .text, .app),
                                 Port("event", "Event", .text, .choice, default: .text("launches"),
                                      choices: ["launches", "quits"])],
                        outputs: [Port("app", "App", .text)], .trigger(.app)),
        BlockDefinition("when.system", "Mac's state changes", category: .triggers, glyph: "bolt",
                        phrase: "When {event}", shape: .hat,
                        inputs: [Port("event", "Event", .text, .choice, default: .text(SystemTrigger.wake.rawValue),
                                      choices: SystemTrigger.allCases.map(\.rawValue))],
                        outputs: [Port("battery", "Battery %", .number)], .trigger(.system)),
        BlockDefinition(battery, "Battery runs low", category: .triggers, glyph: "battery.25percent",
                        phrase: "When the battery drops below {below} %",
                        help: "Once, as it falls past the line — not again while it stays under",
                        shape: .hat, inputs: [Port("below", "Below %", .number, default: .number(20))],
                        outputs: [Port("battery", "Battery %", .number)], .trigger(.battery)),
        BlockDefinition("when.display", "Display plugged in", category: .triggers, glyph: "display",
                        phrase: "When a display is {event}", shape: .hat,
                        inputs: [Port("event", "Event", .text, .choice, default: .text("connected"),
                                      choices: ["connected", "disconnected"])],
                        .trigger(.display)),
        BlockDefinition("when.wifi", "Join a Wi-Fi network", category: .triggers, glyph: "wifi",
                        phrase: "When I join {network}",
                        help: "Matched on the whole name. macOS only tells apps the name with Location Services on",
                        shape: .hat, inputs: [Port("network", "Network", .text)],
                        outputs: [Port("network", "Network", .text)], permissions: [.location], .trigger(.wifi)),
        BlockDefinition("when.audio", "Headphones connect", category: .triggers, glyph: "headphones",
                        phrase: "When sound switches to {device}",
                        help: "Any device whose name contains what you type — “AirPods” matches “Sam's AirPods Pro”",
                        shape: .hat, inputs: [Port("device", "Device", .text)],
                        outputs: [Port("device", "Device", .text)], .trigger(.audio)),
        BlockDefinition("when.gruppe", "Gruppe launches or closes", category: .triggers, glyph: "square.grid.2x2",
                        phrase: "When {gruppe} {event}", shape: .hat,
                        inputs: [Port("gruppe", "Gruppe", .text, .gruppe),
                                 Port("event", "Event", .text, .choice, default: .text("launches"),
                                      choices: ["launches", "closes"])],
                        .trigger(.gruppe)),
        BlockDefinition("when.notification", "Named notification", category: .triggers, glyph: "bell",
                        phrase: "When {name} is posted",
                        help: "A Darwin notification (notifyutil -p name) or a distributed one other apps post",
                        shape: .hat,
                        inputs: [Port("name", "Name", .text),
                                 Port("scope", "Kind", .text, .choice, default: .text("Darwin"),
                                      choices: ["Darwin", "Distributed"])],
                        outputs: [Port("name", "Name", .text)], .trigger(.notification)),
        BlockDefinition(stash, "From a stash", category: .triggers, glyph: "tray",
                        phrase: "When I run it on a stash",
                        help: "Listed under Run in every stash's action bar; gets the stash's files, or the ones picked out",
                        shape: .hat, outputs: [Port("files", "Stash files", .files)], .trigger(.stash)),
        BlockDefinition(external, "Called from outside", category: .triggers, glyph: "terminal",
                        phrase: "When called from outside",
                        help: "`gruppen run \"Name\" --key value` in Terminal, or gruppen://run/Name?key=value",
                        shape: .hat,
                        outputs: [Port("params", "Parameters", .record), Port("input", "Input", .text),
                                  Port("files", "Files", .files)],
                        .trigger(.external)),
    ]

    /// The system events a trigger can wait for.
    enum SystemTrigger: String, CaseIterable, Sendable {
        case sleep = "the Mac goes to sleep"
        case wake = "the Mac wakes"
        case powerOn = "power is connected"
        case powerOff = "power is disconnected"
    }

    // MARK: Logic

    static let logic: [BlockDefinition] = [
        BlockDefinition(ifElse, "If", category: .logic, glyph: "arrow.triangle.branch",
                        phrase: "If {value} {test} {other}",
                        help: "Runs the first stack when the test holds, the second when it does not",
                        shape: .container(["then", "otherwise"]),
                        inputs: [Port("value", "Value", .any, .text),
                                 Port("test", "Test", .text, .choice, default: .text(Condition.Test.equals.rawValue),
                                      choices: Condition.Test.allCases.map(\.rawValue)),
                                 Port("other", "Other", .any, .text, optional: true)],
                        essential: true, .control(.ifElse)),
        BlockDefinition(forEach, "For each", category: .logic, glyph: "arrow.3.trianglepath",
                        phrase: "For each in {items}",
                        help: "Runs the stack once per item — each file, each line, each list entry",
                        shape: .container(["do"]),
                        inputs: [Port("items", "Items", .any, .text)],
                        outputs: [Port("item", "Item", .any), Port("index", "Index", .number)],
                        essential: true, .control(.forEach)),
        BlockDefinition("logic.repeat", "Repeat", category: .logic, glyph: "repeat",
                        phrase: "Repeat {times} times", shape: .container(["do"]),
                        inputs: [Port("times", "Times", .number, default: .number(3))],
                        outputs: [Port("index", "Index", .number)], .control(.repeatTimes)),
        BlockDefinition(parallel, "Run together", category: .logic, glyph: "arrow.triangle.split",
                        help: "Every lane runs at the same time; the flow carries on once all have finished",
                        shape: .container(["lane 1", "lane 2"]), .control(.parallel)),
        BlockDefinition(setVariable, "Set variable", category: .logic, glyph: "character.textbox",
                        phrase: "Set {name} to {value}",
                        help: "Any later block can read it as a pill",
                        inputs: [Port("name", "Name", .text, default: .text("result")),
                                 Port("value", "Value", .any, .text, optional: true)],
                        .control(.setVariable)),
        BlockDefinition("logic.stop", "Stop", category: .logic, glyph: "stop.circle",
                        phrase: "Stop as {outcome}",
                        inputs: [Port("outcome", "Outcome", .text, .choice, default: .text("a success"),
                                      choices: ["a success", stopAsFailure]),
                                 Port("message", "Message", .text, optional: true)],
                        .control(.stop)),
        BlockDefinition("logic.wait", "Wait", category: .logic, glyph: "hourglass",
                        phrase: "Wait {seconds} seconds",
                        inputs: [Port("seconds", "Seconds", .number, default: .number(2))],
                        .builtIn { context in
                            let seconds = max(0, context.number("seconds"))
                            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                            return ["message": .text("Waited \(Value.format(seconds))s")]
                        }),
        BlockDefinition("logic.ask", "Ask", category: .logic, glyph: "questionmark.bubble",
                        phrase: "Ask {prompt}",
                        help: "Shows a dialog and waits. With choices, a menu; without, a text field. Cancelling stops the flow",
                        inputs: [Port("prompt", "Question", .text, default: .text("What should it be called?")),
                                 Port("choices", "Choices", .list, .multiline,
                                      help: "One per line; leave empty for a text field", optional: true),
                                 Port("placeholder", "Placeholder", .text, optional: true)],
                        outputs: [Port("answer", "Answer", .text)],
                        .builtIn { context in
                            let choices = (context.value("choices").items ?? []).compactMap(\.text).filter { !$0.isEmpty }
                            guard let answer = await context.hooks.ask(context.text("prompt"), choices,
                                                                       context.text("placeholder"))
                            else { throw FlowError.stopped("Cancelled") }
                            return ["answer": .text(answer)]
                        }),
        BlockDefinition("logic.notify", "Notification", category: .logic, glyph: "bell.badge",
                        phrase: "Notify {title}",
                        inputs: [Port("title", "Title", .text, default: .text("Done")),
                                 Port("body", "Body", .text, optional: true)],
                        essential: true,
                        .builtIn { context in
                            let title = context.text("title"), body = context.text("body")
                            await MainActor.run {
                                Notifier.post(title: title, body: body) { failure in
                                    if let failure { context.log(failure) }
                                }
                            }
                            return ["message": .text(title)]
                        }),
    ]
}
