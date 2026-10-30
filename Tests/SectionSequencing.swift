import AppKit
import Foundation

/// What sets a flow off, and the order a Gruppe closes in — the two decisions
/// the triggers and the Gruppe store make on their own.
func sectionSequencing() async {
    T.begin("C. Flows — what sets a trigger off")

    T.equal("an app input with a dot is a bundle", AppTarget("com.apple.Safari"), .bundle("com.apple.Safari"))
    T.equal("one without is a process name", AppTarget(" node "), .process("node"))
    T.check("a process name matches its executable, ignoring case",
            AppTarget("Python3").matches(bundleID: "", executable: "python3"))
    T.check("a bundle never matches by executable", !AppTarget("com.x.y").matches(bundleID: "", executable: "com.x.y"))

    let weekdays = Schedule(minute: 8 * 60 + 30, weekdays: [2, 3, 4, 5, 6])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
    let next = weekdays.next(after: friday, calendar: calendar)
    T.equal("after Friday's run, a weekday schedule is next due on Monday",
            next.map { calendar.component(.weekday, from: $0) }, 2)
    T.equal("at its minute", next.map { calendar.component(.minute, from: $0) }, 30)
    T.check("a schedule with no days is never due", Schedule(minute: 0, weekdays: []).next(after: friday) == nil)
    T.equal("days are kept as text", Schedule.days(" 2,3 ,9,x"), [2, 3])
    T.equal("a key combination survives being kept as text",
            HotkeyValue.shortcut(HotkeyValue.text(Shortcut(keyCode: 2, modifiers: 256, label: "D"))),
            Shortcut(keyCode: 2, modifiers: 256, label: "D"))

    // End to end: the Gruppe notification, through the armed triggers, to a
    // recorded run.
    let dev = UUID()
    await withTempDirAsync { dir -> Void in
        let (library, engine) = await MainActor.run { () -> (FlowLibrary, FlowEngine) in
            let library = FlowLibrary(folder: dir)
            return (library, FlowEngine(library: library))
        }
        let hat = Block("when.gruppe", inputs: ["gruppe": .literal(.text(Pick.join(dev, "Dev"))),
                                               "event": .literal(.text("launches"))])
        let flow = Flow(name: "On launch", isEnabled: true, triggers: [hat],
                        body: [Block("text.make", inputs: ["text": .literal(.text("ok"))])])
        let id = flow.id
        await MainActor.run {
            library.flows = [flow]
            NotificationCenter.default.post(name: GroupStore.didClose, object: dev)
            NotificationCenter.default.post(name: GroupStore.didLaunch, object: dev)
        }
        for _ in 0..<50 {
            if await MainActor.run(body: { library.runs[id]?.last?.outcome == .succeeded }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let runs = await MainActor.run { library.runs[id] ?? [] }
        T.equal("a Gruppe launching runs its armed flow once", runs.count, 1)
        T.equal("and the run worked", runs.first?.outcome, .succeeded)
        T.equal("its trace names the block that ran", runs.first?.blocks.map(\.title), ["Text"])
        await MainActor.run { engine.triggers.disarm() }
    }

    T.begin("C. Automations — power edges")

    // macOS posts a power-source change every time the charge moves, so the
    // adapter triggers must fire on the edge, not on the notification.
    let charging = PowerSource(percent: 60, isCharging: true, onExternalPower: true)
    let higher = PowerSource(percent: 61, isCharging: true, onExternalPower: true)
    let unplugged = PowerSource(percent: 61, isCharging: false, onExternalPower: false)
    T.check("the charge moving is not the power being connected", higher.adapterEvent(since: charging) == nil)
    T.equal("unplugging is a disconnection", unplugged.adapterEvent(since: higher), .disconnected)
    T.equal("plugging back in is a connection", higher.adapterEvent(since: unplugged), .connected)
    T.check("nothing on the first reading", charging.adapterEvent(since: nil) == nil)

    let at20 = PowerSource(percent: 20, onExternalPower: false)
    let at19 = PowerSource(percent: 19, onExternalPower: false)
    let at18 = PowerSource(percent: 18, onExternalPower: false)
    T.check("falling past the threshold fires", at19.fell(below: 20, since: at20))
    T.check("sitting under it does not fire again", !at18.fell(below: 20, since: at19))
    T.check("a Mac without a battery never falls below anything",
            !PowerSource().fell(below: 20, since: at20))

    T.begin("B. Gruppen — closing order")

    let apps = ["Calculator", "TextEdit", "Notes"].compactMap {
        AppEntry(url: URL(fileURLWithPath: "/System/Applications/\($0).app"))
    }
    guard apps.count == 3 else {
        T.check("three system apps to test with", false, "found \(apps.map(\.name))")
        return
    }
    var work = AppGroup(name: "Work", apps: apps)
    T.equal("a Gruppe closes its apps in its own order",
            GroupStore.closingOrder(for: work, among: [work]).map(\.name), apps.map(\.name))
    work.isSequenced = true
    T.equal("a sequenced one closes last-launched first",
            GroupStore.closingOrder(for: work, among: [work]).map(\.name), apps.reversed().map(\.name))

    var notes = AppGroup(name: "Notes", apps: [apps[2]])
    notes.isActive = true
    T.equal("an app another active Gruppe needs is spared",
            GroupStore.closingOrder(for: work, among: [work, notes]).map(\.name), [apps[1].name, apps[0].name])
    notes.isActive = false
    T.equal("but not once that Gruppe is closed too",
            GroupStore.closingOrder(for: work, among: [work, notes]).count, 3)
}
