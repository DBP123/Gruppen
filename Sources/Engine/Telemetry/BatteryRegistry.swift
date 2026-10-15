import Foundation
import IOKit

/// The battery's IORegistry node, read in one round trip, with every quantity
/// looked up by each name it has gone by.
///
/// **Why the indirection.** These keys are not API, and Apple moves them.
/// macOS 27 took `AppleRawCurrentCapacity` and `AppleRawMaxCapacity` off the
/// node and put the same figures inside `BatteryData` as `RemainingCapacity`
/// and `FullChargeCapacity`; it dropped `Temperature` outright. The reader
/// asked for the old names by exact spelling and returned nothing when one
/// was missing, so the whole Power module sat on "waiting" for ever over two
/// fields the panel could have done without.
///
/// So each quantity here is a list of places it has lived, newest last, and
/// the first that answers wins. And only the charge level is required: a
/// missing current, capacity or temperature makes *that* figure unknown, not
/// the battery absent. When a quantity cannot be found under any name, that is
/// logged once per launch by name, so the next rename shows up as a line in
/// the log rather than as an empty card.
struct BatteryRegistry {
    let fields: [String: Any]
    /// Only the live node reports names it could not find; a fixture built
    /// in a test is missing things on purpose.
    var reportsMissing = false

    /// The node, or nil on a Mac with no battery.
    static func read() -> BatteryRegistry? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let fields = raw?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return BatteryRegistry(fields: fields, reportsMissing: true)
    }

    // MARK: Lookup

    /// The number at the first of `paths` that has one. A path is a key, or
    /// keys into nested dictionaries joined by dots — `BatteryData.RemainingCapacity`.
    func number(_ paths: String...) -> Double? { number(paths) }

    func number(_ paths: [String]) -> Double? {
        for path in paths {
            if let value = value(at: path) as? NSNumber { return value.doubleValue }
        }
        return nil
    }

    func dictionary(_ key: String) -> [String: Any] { fields[key] as? [String: Any] ?? [:] }
    func string(_ key: String) -> String? { fields[key] as? String }
    func flag(_ paths: String...) -> Bool? { number(paths).map { $0 != 0 } }

    private func value(at path: String) -> Any? {
        var node: Any? = fields
        for key in path.split(separator: ".") {
            node = (node as? [String: Any])?[String(key)]
        }
        return node
    }

    /// A quantity the panel would like but can live without: the value, or nil
    /// and one log line naming what was looked for.
    private func optional(_ name: String, _ paths: String...) -> Double? {
        if let found = number(paths) { return found }
        if reportsMissing { Self.reportMissing(name, paths) }
        return nil
    }

    // MARK: Quantities

    var millivolts: Double? { optional("voltage", "Voltage", "AppleRawBatteryVoltage", "BatteryData.Voltage") }
    var milliamps: Double? { optional("current", "Amperage", "InstantAmperage", "BatteryData.InstantAmperage") }

    /// Charge and capacity in mAh — macOS 26 names first, then macOS 27's.
    var chargemAh: Double? {
        optional("charge in mAh", "AppleRawCurrentCapacity", "BatteryData.RemainingCapacity")
    }
    var capacitymAh: Double? {
        optional("capacity in mAh", "AppleRawMaxCapacity", "BatteryData.FullChargeCapacity",
                 "BatteryData.NominalChargeCapacity")
    }
    var designmAh: Double? { optional("design capacity", "DesignCapacity", "BatteryData.DesignCapacity") }

    /// The percentage macOS itself shows.
    ///
    /// `CurrentCapacity` *is* that calibrated figure whenever `MaxCapacity`
    /// is 100. Computing it from raw mAh instead gave 72% against the menu
    /// bar's 76% on this machine, because Apple calibrates on top of the
    /// coulomb count — so the ratio is only the fallback, for Macs that report
    /// the pair in mAh.
    var percent: Int? {
        for prefix in ["", "BatteryData."] {
            if let current = number(prefix + "CurrentCapacity"), number(prefix + "MaxCapacity") == 100 {
                return Int(current.rounded())
            }
        }
        if let charge = chargemAh, let capacity = capacitymAh, capacity > 0 {
            return Int((charge / capacity * 100).rounded())
        }
        if reportsMissing {
            Self.reportMissing("charge level", ["CurrentCapacity", "BatteryData.CurrentCapacity", "mAh ratio"])
        }
        return nil
    }

    var cycles: Int? { optional("cycle count", "CycleCount", "BatteryData.CycleCount").map(Int.init) }

    /// Reported in hundredths of a degree, when it is reported at all.
    var celsius: Double? {
        optional("temperature", "Temperature", "BatteryData.Temperature", "VirtualTemperature").map { $0 / 100 }
    }

    // MARK: Missing names

    private static let missingLock = NSLock()
    nonisolated(unsafe) private static var reported: Set<String> = []

    private static func reportMissing(_ name: String, _ paths: [String]) {
        missingLock.lock()
        let first = reported.insert(name).inserted
        missingLock.unlock()
        guard first else { return }
        GroupStore.log("BATTERY: no \(name) on this macOS (looked for \(paths.joined(separator: ", "))) — shown as unknown")
    }
}
