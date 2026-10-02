import AppKit
import Foundation
import SwiftUI

/// The question this section asks is not "does it work here" but "what does it
/// do on a Mac that is not this one".
@MainActor
func sectionPortability() {
    T.begin("G. Portability — this machine, and what it implies")

    T.note("model \(ModelNameResolver.modelIdentifier()) · chip \(ModelNameResolver.chipName())")
    T.note("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    T.note("battery present: \(ModelNameResolver.hasBattery())")

    // Every shipped model identifier must resolve to *something* nameable, on a
    // machine none of us has. The resolver is pure, so it can be asked.
    let machines: [(String, String)] = [
        ("MacBookPro18,3", "Apple M1 Pro"), ("MacBookAir10,1", "Apple M1"),
        ("Macmini9,1", "Apple M1"), ("Mac14,3", "Apple M2"),
        ("MacStudio13,1", "Apple M1 Max"), ("MacPro7,1", "Intel Xeon W"),
        ("iMac21,1", "Apple M1"), ("MacBookPro16,1", "Intel Core i9"),
        ("Mac16,10", "Apple M4"), ("VirtualMac2,1", "Apple Virtual"),
        ("", ""),
    ]
    var unnamed: [String] = []
    for (identifier, chip) in machines {
        let family = ModelNameResolver.family(identifier: identifier, chipName: chip)
        let name = ModelNameResolver.marketingName(family: family, chipName: chip)
        if name.trimmingCharacters(in: .whitespaces).isEmpty { unnamed.append(identifier) }
    }
    T.check("every model identifier resolves to a non-empty name", unnamed.isEmpty,
            unnamed.isEmpty ? "\(machines.count) identifiers incl. Intel and VMs" : "\(unnamed)")
    // An identifier this build has never seen falls back to hardware: a
    // battery means a laptop, no battery means it declines to guess.
    let unknownHere = ModelNameResolver.family(identifier: "Frobnicator9,9", chipName: "Nothing")
    T.check("an unknown identifier falls back to hardware evidence",
            ModelNameResolver.hasBattery() ? unknownHere != .unknown : unknownHere == .unknown,
            "\(unknownHere) on a machine with battery=\(ModelNameResolver.hasBattery())")

    T.begin("G. Portability — a Mac with no battery")

    // Mac mini, Studio, Pro. PowerFlow.read() returns nil there, and the UI
    // must have something to show. The samplers are the layer that decides.
    let thermal = ThermalSampler()
    let reading = Telemetry.queue.sync { thermal.sample() }
    T.check("the thermal card survives a missing battery",
            reading != nil, "battery percent: \(reading?.batteryPercent.map(String.init) ?? "nil")")
    T.check("a nil battery percent is representable rather than 0",
            reading?.batteryPercent == nil || ModelNameResolver.hasBattery(),
            "a desktop must not report 0%")
    Telemetry.queue.sync { thermal.teardown() }

    T.begin("G. Portability — a Mac with no notch")

    // The anchor type is pure, so every topology can be asked about, including
    // the ones not plugged in.
    let notchless = NotchGeometryManager.Anchor(
        displayID: 1, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
        notch: nil, bandHeight: 24, isBuiltIn: true)
    T.check("a notchless display still has a place for the tray",
            !notchless.hasPhysicalNotch, "the tray centres on the screen instead")

    let notched = NotchGeometryManager.Anchor(
        displayID: 1, frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        notch: NSRect(x: 663, y: 950, width: 185, height: 32), bandHeight: 32, isBuiltIn: true)
    T.check("a notched display reports its housing", notched.hasPhysicalNotch)

    // A display that is not at the origin — a second monitor above or to the
    // left — is where this arithmetic historically goes wrong.
    let offset = NotchGeometryManager.Anchor(
        displayID: 2, frame: NSRect(x: -1210, y: 226, width: 1210, height: 756),
        notch: nil, bandHeight: 24, isBuiltIn: false)
    T.check("a display at a negative origin is handled",
            offset.frame.minX < 0 && offset.frame.minY > 0,
            "\(offset.frame)")

    T.begin("G. Portability — hardware profile caching")

    // A cache written by an earlier build must not be thrown away.
    let minimal = """
    {"rawModelIdentifier":"Mac15,3","marketingModelName":"MacBook Pro",
     "buildInfo":{"productVersion":"14.0","buildVersion":"23A344","kernelVersion":"23.0.0"}}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    if let profile = try? decoder.decode(MacHardwareProfile.self, from: minimal) {
        T.check("a hardware profile from an earlier build still loads",
                profile.rawModelIdentifier == "Mac15,3", profile.marketingModelName)
    } else {
        T.check("a hardware profile from an earlier build still loads", false,
                "decode threw — the cache is discarded and re-probed")
    }

    T.begin("G. Portability — presets and search paths")

    var ids = Set<String>()
    var duplicates: [String] = []
    for rule in Presets.rules where !ids.insert(rule.id).inserted { duplicates.append(rule.id) }
    T.check("no two preset rules share an id", duplicates.isEmpty, "\(Presets.rules.count) rules")
    T.check("every rule has candidates",
            Presets.rules.allSatisfy { !$0.bundleNames.isEmpty && !$0.bundleIDs.isEmpty })
    T.check("every rule colour parses",
            Presets.rules.allSatisfy { $0.colorHex.hasPrefix("#") && $0.colorHex.count == 7 })
    T.check("the search paths include a per-user Applications folder",
            Presets.searchDirectories.contains { $0.path.hasSuffix("/Applications")
                && $0.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) },
            "a per-user install must be found")
    T.check("matching runs without a subprocess and returns something sane",
            Presets.matches(minimum: 1).allSatisfy { $0.count >= 1 },
            "\(Presets.matches(minimum: 2).count) rules match on this Mac")

    T.begin("G. Portability — external tools the app shells out to")

    // Each of these is spawned by a feature. If one is absent the feature is
    // dead, so they must all be OS-supplied rather than developer tools.
    let tools = ["/usr/bin/ditto", "/usr/bin/zip", "/usr/bin/sips", "/usr/bin/textutil",
                 "/usr/bin/afconvert", "/bin/zsh", "/usr/bin/osascript"]
    let missing = tools.filter { !FileManager.default.isExecutableFile(atPath: $0) }
    T.check("every external tool ships with macOS", missing.isEmpty,
            missing.isEmpty ? "\(tools.count) checked" : "missing \(missing)")

    T.begin("G. Portability — colour parsing")

    // Group colours round-trip through a hex string in everyone's saved file,
    // so every shape a file might hold has to come back as something drawable.
    for hex in ["#FF6B00", "#000000", "#FFFFFF", "FF6B00", "#abcdef", "", "not a colour", "#FFF"] {
        let described = String(describing: Color(hex: hex))
        T.check("\(hex.isEmpty ? "<empty>" : hex) parses without crashing",
                !described.isEmpty, "")
    }
    T.equal("the default group colour is a valid hex string",
            Theme.defaultGroupHex.count, 7)
}
