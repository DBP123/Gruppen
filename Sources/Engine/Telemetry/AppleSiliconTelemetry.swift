import Darwin
import Foundation
import IOKit

/// Deep hardware telemetry: the IORegistry and the SMC.
///
/// Everything here is reached through published IOKit entry points —
/// `IOServiceGetMatchingService`, `IORegistryEntryCreateCFProperty`,
/// `IOConnectCallStructMethod`. No subprocess, no `powermetrics`, and nothing
/// linked out of a private framework.
///
/// **What this can and cannot see.** Utilisation figures for the GPU are
/// published by the accelerator itself and are exact. The Neural Engine and the
/// media engines publish a *power state*, not a load percentage — the load
/// figures `powermetrics` prints come from IOReport, which has no public header
/// and no stable ABI, so this reports the power state and says so rather than
/// inventing a percentage.
///
/// **On cost.** Two different things are expensive here and neither happens in
/// the sampling loop. Finding a service is a matching-dictionary lookup against
/// the whole registry; reading a property off an entry you already hold is
/// 33 µs. Discovering which SMC keys a machine has means walking all ~3500 of
/// them at ~0.15 ms each — 630 ms, once. So the handles and the key list are
/// found on the first sample and cached, the key list is remembered across
/// launches, and every tick after that is a handful of reads.
///
/// The object is shared and reference counted: two modules can want the SMC at
/// once, and neither should pay the discovery cost twice, but the last one to
/// let go must still close the connection. Every method is called on
/// `Telemetry.queue`, which is serial — that is what makes the counting safe
/// without a lock.
final class AppleSiliconTelemetry {
    static let shared = AppleSiliconTelemetry()

    private init() {}

    // MARK: Lifetime

    private var users = 0
    private var opened = false

    private var accelerator: io_registry_entry_t = 0
    private var neuralEngine: io_registry_entry_t = 0
    private var videoDecoder: io_registry_entry_t = 0
    private var imageCodec: io_registry_entry_t = 0
    private var smc: io_connect_t = 0
    private var sensors = SensorSet()

    /// Claims the hardware. The first caller pays for discovery.
    func acquire() {
        users += 1
        guard !opened else { return }
        opened = true

        accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        // The Neural Engine's driver class is generation-specific; the service
        // it publishes is not.
        neuralEngine = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"))
        videoDecoder = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleAVD"))
        imageCodec = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleJPEGDriver"))
        openSMC()
    }

    /// Releases it. When the last module lets go, every handle is closed — that
    /// is what "unchecked means destroyed" has to mean for something holding
    /// kernel objects.
    func release() {
        users = max(users - 1, 0)
        guard users == 0, opened else { return }
        opened = false

        for entry in [accelerator, neuralEngine, videoDecoder, imageCodec] where entry != 0 {
            IOObjectRelease(entry)
        }
        accelerator = 0; neuralEngine = 0; videoDecoder = 0; imageCodec = 0
        if smc != 0 { IOServiceClose(smc); smc = 0 }
        sensors = SensorSet()
    }

    // MARK: GPU and the fixed-function blocks

    struct GraphicsReading: Equatable {
        /// 0…1. The accelerator's own figure — 0 at rest, 0.97 under a compute
        /// load, verified against a Metal kernel.
        var utilization: Double
        var rendererUtilization: Double
        var tilerUtilization: Double
        var memoryInUse: UInt64
        var memoryAllocated: UInt64
    }

    func graphics() -> GraphicsReading? {
        guard accelerator != 0,
              let stats = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
        else { return nil }

        func percent(_ key: String) -> Double {
            min(max((stats[key] as? NSNumber)?.doubleValue ?? 0, 0), 100) / 100
        }
        return GraphicsReading(
            utilization: percent("Device Utilization %"),
            rendererUtilization: percent("Renderer Utilization %"),
            tilerUtilization: percent("Tiler Utilization %"),
            memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0,
            memoryAllocated: (stats["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0)
    }

    /// A fixed-function block's power state: `nil` when the machine has no such
    /// block, otherwise the current state and the highest it has.
    struct EngineState: Equatable {
        var current: Int
        var maximum: Int
        var isAwake: Bool { current > 0 }
    }

    func neuralEngineState() -> EngineState? { powerState(of: neuralEngine) }
    func videoEngineState() -> EngineState? { powerState(of: videoDecoder) }
    func imageEngineState() -> EngineState? { powerState(of: imageCodec) }

    private func powerState(of entry: io_registry_entry_t) -> EngineState? {
        guard entry != 0,
              let management = IORegistryEntryCreateCFProperty(entry, "IOPowerManagement" as CFString,
                                                               kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let current = (management["CurrentPowerState"] as? NSNumber)?.intValue
        else { return nil }
        return EngineState(current: current,
                           maximum: (management["MaxPowerState"] as? NSNumber)?.intValue ?? current)
    }

    // MARK: Core layout

    enum CoreKind: String, Equatable {
        case performance = "P"
        case efficiency = "E"

        var label: String { self == .performance ? "P" : "E" }
    }

    /// Which cluster each logical CPU belongs to, indexed by the same number
    /// `host_processor_info` uses.
    ///
    /// Read once from the device tree and kept: the layout of a Mac does not
    /// change while it is running. Apple labels the cluster "P" for performance
    /// and either "E" or "M" for the efficiency cluster depending on the
    /// generation — this machine says "M" — so anything that is not "P" is the
    /// efficiency side.
    /// GPU cores, from the accelerator's own device-tree node. Read once.
    static let graphicsCoreCount: Int = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        for key in ["gpu-core-count", "GPUConfigurationVariable"] {
            guard let value = property(of: service, key) else { continue }
            if let count = asInt(value) { return count }
            if let table = value as? [String: Any],
               let count = (table["num_cores"] as? NSNumber)?.intValue { return count }
        }
        return 0
    }()

    static let coreLayout: [CoreKind] = {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [(index: Int, kind: CoreKind)] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            guard let type = property(of: entry, "cluster-type").flatMap(asString),
                  let index = property(of: entry, "logical-cpu-id").flatMap(asInt)
            else { continue }
            found.append((index, type.uppercased().hasPrefix("P") ? .performance : .efficiency))
        }

        guard !found.isEmpty else { return [] }
        var layout = [CoreKind](repeating: .efficiency, count: found.map(\.index).max()! + 1)
        for core in found { layout[core.index] = core.kind }
        return layout
    }()

    private static func property(of entry: io_registry_entry_t, _ name: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Device-tree properties arrive as raw bytes as often as they do as typed
    /// values, so both are unpacked here.
    private static func asString(_ value: CFTypeRef) -> String? {
        if let text = value as? String { return text }
        guard let data = value as? Data else { return nil }
        return String(bytes: data.prefix { $0 != 0 }, encoding: .utf8)
    }

    private static func asInt(_ value: CFTypeRef) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let data = value as? Data, !data.isEmpty else { return nil }
        var result = 0
        for (offset, byte) in data.prefix(8).enumerated() { result |= Int(byte) << (8 * offset) }
        return result
    }

    // MARK: SMC

    /// One fan, as the SMC describes it: what it is doing and what it has been
    /// told to do. The gap between the two is the interesting part — a target
    /// above the actual speed means the machine has just decided it is getting
    /// hot and the fan has not caught up yet.
    struct Fan: Equatable {
        var actual: Double
        var target: Double
        var minimum: Double
        var maximum: Double

        /// 0…1 across the fan's own usable range, for a gauge.
        var load: Double {
            let span = maximum - minimum
            return span > 0 ? min(max((actual - minimum) / span, 0), 1) : 0
        }
    }

    /// A named thermal zone, carrying the SMC key it came from.
    ///
    /// The key travels with the value on purpose. "CPU die 38°C" is a claim
    /// about a sensor, and which sensor it was is the difference between a
    /// diagnostic and a decoration.
    struct Zone: Equatable {
        var key: String
        var celsius: Double
    }

    struct ThermalReading: Equatable {
        /// Hottest sensor on the performance cluster — the Apple Silicon
        /// equivalent of the `TC0P` these machines do not have.
        var cpuDie: Zone?
        var efficiencyCores: Zone?
        var gpuDie: Zone?
        /// `TB0T`. Present on every Mac with a battery, Intel or Apple Silicon.
        var battery: Zone?
        /// Watts drawn by the whole machine, when the machine reports it.
        var systemPower: Double?
        /// Empty on a fanless Mac.
        var fans: [Fan]

        var hottest: Double? {
            [cpuDie, efficiencyCores, gpuDie].compactMap { $0?.celsius }.max()
        }
    }

    func thermal() -> ThermalReading? {
        guard smc != 0 else { return nil }
        func hottest(_ keys: [SMCKey]) -> Zone? {
            keys.compactMap { key -> Zone? in
                guard let value = read(key), value > 5, value < 130 else { return nil }
                return Zone(key: Self.name(of: key.code), celsius: value)
            }
            .max { $0.celsius < $1.celsius }
        }
        let fans = zip(sensors.fansActual, sensors.fansTarget).compactMap { actual, target -> Fan? in
            guard let speed = read(actual) else { return nil }
            return Fan(actual: max(speed, 0),
                       target: read(target).map { max($0, 0) } ?? 0,
                       minimum: sensors.fanMinimum,
                       maximum: sensors.fanMaximum)
        }
        let reading = ThermalReading(
            cpuDie: hottest(sensors.performance),
            efficiencyCores: hottest(sensors.efficiency),
            gpuDie: hottest(sensors.graphics),
            battery: sensors.battery.flatMap { key in
                read(key).flatMap { $0 > 5 && $0 < 130 ? Zone(key: Self.name(of: key.code), celsius: $0) : nil }
            },
            systemPower: sensors.power.flatMap(read).map { max($0, 0) },
            fans: fans)
        // A machine that answered nothing at all is worth reporting as nothing,
        // rather than as a well full of dashes.
        guard reading.cpuDie != nil || reading.systemPower != nil else { return nil }
        return reading
    }

    // MARK: SMC plumbing

    /// A key whose type and size have already been looked up, so reading it is
    /// one call instead of two.
    private struct SMCKey {
        var code: UInt32
        var info: SMCKeyInfoData
    }

    private struct SensorSet {
        var performance: [SMCKey] = []
        var efficiency: [SMCKey] = []
        var graphics: [SMCKey] = []
        /// Paired by index: fan *n*'s actual speed and its commanded target.
        var fansActual: [SMCKey] = []
        var fansTarget: [SMCKey] = []
        /// The fan envelope is fixed for a given machine, so it is read once at
        /// discovery and carried as a number rather than costing two SMC round
        /// trips on every tick.
        var fanMinimum: Double = 0
        var fanMaximum: Double = 0
        var battery: SMCKey?
        var power: SMCKey?
    }

    /// How many sensors to keep per cluster.
    ///
    /// A read is 0.15 ms, so this is the whole cost knob. Nine keys is about
    /// 1.4 ms a tick — 0.28% of one core at the panel's 2 Hz. Keeping *all* 157
    /// candidates this machine offers would be 24 ms a tick, which is a monitor
    /// you can feel.
    private static let sensorsPerCluster = 2

    /// Names of the keys worth keeping, remembered so a machine only ever pays
    /// the 630 ms discovery walk once.
    /// Versioned: the set grew fan targets and the battery zone, and a cache
    /// written before that would resolve into a half-populated sensor set.
    private static let cacheKey = "smcSensorKeys2"

    private func openSMC() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return }
        smc = connection

        if let remembered = UserDefaults.standard.stringArray(forKey: Self.cacheKey),
           let restored = resolve(names: remembered) {
            sensors = restored
        } else {
            sensors = discoverSensors()
            UserDefaults.standard.set(sensorNames(sensors), forKey: Self.cacheKey)
        }
    }

    /// Turns remembered key names back into typed handles. One `keyInfo` call
    /// each — a couple of milliseconds — and any name that no longer resolves
    /// throws the whole cache away rather than leaving a half-populated set.
    private func resolve(names: [String]) -> SensorSet? {
        var set = SensorSet()
        for name in names {
            let parts = name.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let key = keyInfo(for: String(parts[1])) else { return nil }
            switch parts[0] {
            case "p": set.performance.append(key)
            case "e": set.efficiency.append(key)
            case "g": set.graphics.append(key)
            case "f": set.fansActual.append(key)
            case "t": set.fansTarget.append(key)
            case "b": set.battery = key
            case "w": set.power = key
            default: return nil
            }
        }
        set.fanMinimum = keyInfo(for: "F0Mn").flatMap(read) ?? 0
        set.fanMaximum = keyInfo(for: "F0Mx").flatMap(read) ?? 0
        return set.performance.isEmpty && set.power == nil ? nil : set
    }

    private func sensorNames(_ set: SensorSet) -> [String] {
        set.performance.map { "p:\(Self.name(of: $0.code))" }
            + set.efficiency.map { "e:\(Self.name(of: $0.code))" }
            + set.graphics.map { "g:\(Self.name(of: $0.code))" }
            + set.fansActual.map { "f:\(Self.name(of: $0.code))" }
            + set.fansTarget.map { "t:\(Self.name(of: $0.code))" }
            + (set.battery.map { ["b:\(Self.name(of: $0.code))"] } ?? [])
            + (set.power.map { ["w:\(Self.name(of: $0.code))"] } ?? [])
    }

    /// Walks every key the SMC has and keeps the few that matter.
    ///
    /// The key names are not documented anywhere, but their prefixes are
    /// consistent across Apple Silicon: `Tp` is the performance cluster, `Tm`
    /// and `Te` the efficiency one, `Tg` the GPU, `F…Ac` a fan's actual speed,
    /// `PSTR` the total system draw. Rather than hard-coding one machine's
    /// sensor names, this keeps whichever of them exist and picks the hottest
    /// few — the hottest sensor is the one that matters for thermals anyway.
    private func discoverSensors() -> SensorSet {
        var candidates: [(prefixGroup: Int, key: SMCKey)] = []
        var set = SensorSet()

        for index in 0..<keyCount() {
            guard let code = key(at: index) else { continue }
            let name = Self.name(of: code)
            let group: Int
            switch true {
            case name.hasPrefix("Tp"): group = 0
            case name.hasPrefix("Tm"), name.hasPrefix("Te"): group = 1
            case name.hasPrefix("Tg"), name.hasPrefix("TG"): group = 2
            case name.hasPrefix("F") && name.hasSuffix("Ac"): group = 3
            case name == "PSTR": group = 4
            // `TB0T` is the one key the brief named that these machines
            // actually have; `TC0P` and `TG0P` are Intel and answer nothing.
            case name == "TB0T": group = 5
            case name.hasPrefix("F") && name.hasSuffix("Tg"): group = 6
            default: continue
            }
            guard let resolved = keyInfo(for: name) else { continue }
            switch group {
            case 4: set.power = resolved
            case 5: set.battery = resolved
            default: candidates.append((group, resolved))
            }
        }

        // Read every candidate once, keep the hottest handful per cluster.
        for group in 0...2 {
            let ranked = candidates
                .filter { $0.prefixGroup == group }
                .compactMap { candidate -> (SMCKey, Double)? in
                    guard let value = read(candidate.key), value > 5, value < 130 else { return nil }
                    return (candidate.key, value)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.sensorsPerCluster)
                .map(\.0)
            switch group {
            case 0: set.performance = ranked
            case 1: set.efficiency = ranked
            default: set.graphics = ranked
            }
        }
        // Sorted by name so fan 0's actual speed lines up with fan 0's target.
        func ordered(_ group: Int) -> [SMCKey] {
            candidates.filter { $0.prefixGroup == group }
                .map(\.key)
                .sorted { Self.name(of: $0.code) < Self.name(of: $1.code) }
        }
        set.fansActual = ordered(3)
        set.fansTarget = ordered(6)
        set.fanMinimum = keyInfo(for: "F0Mn").flatMap(read) ?? 0
        set.fanMaximum = keyInfo(for: "F0Mx").flatMap(read) ?? 0
        return set
    }

    /// Clamped on principle. Every key costs a kernel round trip, so a figure
    /// that came back wrong must not be able to turn discovery into an
    /// afternoon's work — this machine reports 3,486.
    private static let keyCeiling: UInt32 = 8192

    private func keyCount() -> UInt32 {
        guard let info = keyInfo(for: "#KEY"), let value = read(info), value > 0 else { return 0 }
        return min(UInt32(min(value, Double(UInt32.max))), Self.keyCeiling)
    }

    private func key(at index: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        input.data8 = Self.commandKeyByIndex
        input.data32 = index
        return call(&input)?.key
    }

    private func keyInfo(for name: String) -> SMCKey? {
        var input = SMCParamStruct()
        input.key = Self.code(for: name)
        input.data8 = Self.commandReadKeyInfo
        guard let output = call(&input) else { return nil }
        return SMCKey(code: input.key, info: output.keyInfo)
    }

    /// Reads a key whose type is already known. This is the only SMC call that
    /// happens inside the sampling loop.
    private func read(_ key: SMCKey) -> Double? {
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo = key.info
        input.data8 = Self.commandReadBytes
        guard let output = call(&input) else { return nil }

        let size = Int(key.info.dataSize)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(min(size, 32))) }
        switch Self.name(of: key.info.dataType).trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            var pattern: UInt32 = 0
            for offset in (0..<4).reversed() { pattern = (pattern << 8) | UInt32(bytes[offset]) }
            return Double(Float(bitPattern: pattern))
        case "ioft":
            // 48.16 fixed point, little endian.
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for offset in (0..<8).reversed() { raw = (raw << 8) | UInt64(bytes[offset]) }
            return Double(raw) / 65536
        // The SMC's integers are big-endian while its floats are not, which is
        // the sort of thing that looks like it works: reading the key count the
        // wrong way round turned 3,486 into 2,651,750,400 and sent the
        // discovery walk off for the rest of the afternoon.
        case "ui8", "si8":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            var raw: UInt32 = 0
            for byte in bytes.prefix(4) { raw = (raw << 8) | UInt32(byte) }
            return Double(raw)
        default:
            return nil
        }
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard smc != 0 else { return nil }
        var output = SMCParamStruct()
        var size = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(smc, Self.selectorHandleEvent,
                                               &input, MemoryLayout<SMCParamStruct>.stride,
                                               &output, &size)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func code(for name: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in name.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    private static func name(of code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    // The SMC's user client takes one selector and distinguishes the operation
    // by a byte in the payload. None of this is documented; all of it is
    // reached through published IOKit calls.
    private static let selectorHandleEvent: UInt32 = 2
    private static let commandReadBytes: UInt8 = 5
    private static let commandKeyByIndex: UInt8 = 8
    private static let commandReadKeyInfo: UInt8 = 9
}

// MARK: - The SMC's wire format

// Laid out to match the kernel's own structure exactly; a field out of place
// here reads as garbage rather than as an error.

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
