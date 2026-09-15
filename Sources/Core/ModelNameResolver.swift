import AppKit
import Foundation
import IOKit

/// Turns `Mac17,9` into `MacBook Pro (Apple M5 Pro)`.
///
/// ## Why this is a table and not a lookup
///
/// The obvious approach — ask `IOPlatformExpertDevice` for its `product-name` —
/// does not work on Apple silicon, and this was checked rather than assumed.
/// The full property list on this machine carries `model` (`Mac17,9`),
/// `target-type` (`J714s`), `regulatory-model-number` (`A3426`) and a dozen
/// other internal codes. There is no marketing name anywhere in it. macOS does
/// not ship a local database mapping one to the other either: the icons in
/// `CoreTypes.bundle` are keyed by marketing slug, not by model identifier, so
/// they cannot be searched backwards.
///
/// The only processes that know are `system_profiler` and About This Mac, and
/// spawning a subprocess to read a string is precisely what the rest of this app
/// refuses to do.
///
/// So: a small table of identifiers, and — for anything not in it, including
/// every Mac released after this build — a fallback derived from hardware that
/// is actually readable. The fallback is the important half. A table alone would
/// print "Mac" for every machine newer than the app.
enum ModelNameResolver {
    /// Identifiers this build knows by name.
    ///
    /// Deliberately short. It exists for the machines the hardware fallback
    /// below genuinely cannot tell apart — an M2 MacBook Air from a base M2
    /// MacBook Pro, a Mac mini from a Mac Studio — and not as a catalogue.
    private static let known: [String: MacFamily] = [
        // Laptops whose chip name alone does not identify them.
        "MacBookAir10,1": .macBookAir,
        "Mac14,2": .macBookAir, "Mac14,15": .macBookAir,
        "Mac15,12": .macBookAir, "Mac15,13": .macBookAir,
        "Mac16,12": .macBookAir, "Mac16,13": .macBookAir,
        "MacBookPro17,1": .macBookPro,
        "Mac14,7": .macBookPro,

        // Desktops. No battery, and nothing else in the device tree separates
        // a mini from a Studio, so these have to be named.
        "Macmini9,1": .macMini, "Mac14,3": .macMini, "Mac14,12": .macMini,
        "Mac16,10": .macMini, "Mac16,11": .macMini,
        "Mac13,1": .macStudio, "Mac13,2": .macStudio,
        "Mac14,13": .macStudio, "Mac14,14": .macStudio,
        "Mac15,14": .macStudio, "Mac16,9": .macStudio,
        "MacPro7,1": .macPro, "Mac14,8": .macPro,
        "iMac21,1": .iMac, "iMac21,2": .iMac,
        "Mac15,4": .iMac, "Mac15,5": .iMac,
        "Mac16,2": .iMac, "Mac16,3": .iMac,
    ]

    /// Works out the family, preferring evidence over the table where evidence
    /// exists.
    ///
    /// Order matters. The Intel-era prefixes are definitive when present, so
    /// they go first. The table is next. Everything after that is inference from
    /// hardware, which is what carries a Mac this build has never heard of.
    static func family(identifier: String, chipName: String) -> MacFamily {
        // Intel and early Apple silicon put the family in the identifier.
        if identifier.hasPrefix("MacBookPro") { return .macBookPro }
        if identifier.hasPrefix("MacBookAir") { return .macBookAir }
        if identifier.hasPrefix("MacPro") { return .macPro }
        if identifier.hasPrefix("Macmini") { return .macMini }
        if identifier.hasPrefix("iMacPro") || identifier.hasPrefix("iMac") { return .iMac }

        if let known = known[identifier] { return known }

        // Nothing named it, so ask the hardware. A battery is the one reliable
        // laptop tell — no desktop Mac has an `AppleSmartBattery` node.
        guard hasBattery() else { return .unknown }

        // A laptop, then. The Air has never shipped with a Pro, Max or Ultra
        // part, so a chip that carries one of those names is a MacBook Pro. A
        // plain chip is genuinely ambiguous between an Air and a base Pro — but
        // every plain-chip Air that has actually shipped is in the table above,
        // so reaching here on one means a machine newer than this build, and
        // "MacBook Pro" is the likelier of the two for an unrecognised laptop.
        return .macBookPro
    }

    /// Whether this Mac has a battery. One IOKit lookup, released immediately.
    static func hasBattery() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// `MacBook Pro (Apple M5 Pro)`, or just the family when the chip is
    /// unreadable. Never the raw identifier — that is what the spec sheet row is
    /// for.
    static func marketingName(family: MacFamily, chipName: String) -> String {
        let chip = chipName.trimmingCharacters(in: .whitespaces)
        guard !chip.isEmpty else { return family.marketingName }
        return "\(family.marketingName) (\(chip))"
    }

    // MARK: Probes

    /// `Apple M5 Pro`. Verified present on Apple silicon — this is not an
    /// Intel-only sysctl, despite the `machdep.cpu` prefix.
    static func chipName() -> String {
        sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
    }

    static func modelIdentifier() -> String {
        sysctlString("hw.model") ?? "Mac"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    static func sysctlInteger(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// The serial, from the same IOKit node the rest of the app uses.
    static func serialNumber() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "—" }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service,
                                                    kIOPlatformSerialNumberKey as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? String) ?? "—"
    }
}
