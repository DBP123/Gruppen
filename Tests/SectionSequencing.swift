import AppKit
import Foundation

/// What sets an automation off, and the order a Gruppe closes in — the two
/// decisions the trigger coordinator and the Gruppe store make on their own.
func sectionSequencing() async {
    T.begin("C. Automations — what sets a trigger off")

    func trigger(_ kind: ScriptTrigger.Kind, _ configure: (inout ScriptTrigger) -> Void = { _ in }) -> ScriptTrigger {
        var trigger = ScriptTrigger()
        trigger.kind = kind
        configure(&trigger)
        return trigger
    }

    let connect = trigger(.display) { $0.edge = .on }
    T.check("a display connecting fires an on-connect trigger", connect.isSetOff(by: .display(.on)))
    T.check("but not a disconnect", !connect.isSetOff(by: .display(.off)))

    let home = trigger(.wifi) { $0.match = " Home " }
    T.check("a network matches by its whole name, ignoring case and spaces", home.isSetOff(by: .wifi("home")))
    T.check("a longer name is a different network", !home.isSetOff(by: .wifi("Home-Guest")))

    let pods = trigger(.audioDevice) { $0.match = "airpods" }
    T.check("a sound output matches by part of its name", pods.isSetOff(by: .audioDevice("Sam's AirPods Pro")))
    T.check("an empty match fires for nothing", !trigger(.audioDevice).isSetOff(by: .audioDevice("Speakers")))

    let dev = UUID()
    let gruppe = trigger(.gruppe) { $0.gruppeID = dev; $0.edge = .off }
    T.check("a Gruppe closing fires an on-close trigger", gruppe.isSetOff(by: .gruppe(dev, .off)))
    T.check("not when it launches", !gruppe.isSetOff(by: .gruppe(dev, .on)))
    T.check("and not for another Gruppe", !gruppe.isSetOff(by: .gruppe(UUID(), .off)))
    T.check("an event of one kind never sets off another", !connect.isSetOff(by: .gruppe(dev, .on)))

    // End to end: the Gruppe notification, through the armed coordinator, to
    // a recorded run.
    await withTempDirAsync { dir -> Void in
        let (library, coordinator) = await MainActor.run { () -> (ScriptLibrary, ScriptTriggerCoordinator) in
            let library = ScriptLibrary(fileURL: dir.appendingPathComponent("scripts.json"))
            return (library, ScriptTriggerCoordinator(library: library))
        }
        var script = Script(name: "On launch", isActive: true)
        script.trigger = trigger(.gruppe) { $0.gruppeID = dev; $0.edge = .on }
        script.steps[0].code.command = "true"
        let id = script.id
        let armed = script
        await MainActor.run {
            library.scripts = [armed]
            coordinator.rearm()
            NotificationCenter.default.post(name: GroupStore.didClose, object: dev)
            NotificationCenter.default.post(name: GroupStore.didLaunch, object: dev)
        }
        for _ in 0..<50 {
            if await MainActor.run(body: { library.runs[id]?.isEmpty == false }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let runs = await MainActor.run { library.runs[id] ?? [] }
        T.equal("a Gruppe launching runs its armed trigger once", runs.count, 1)
        T.check("and the run worked", runs.first?.succeeded == true, runs.first?.summary ?? "no run")
        await MainActor.run { coordinator.disarm() }
    }

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
