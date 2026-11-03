import AppKit
import Foundation

/// Power edges, and the order a Gruppe closes in.
func sectionSequencing() async {
    T.begin("C. Power — edges, not notifications")

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
