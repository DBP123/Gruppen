import Foundation
import IOKit
import IOKit.ps

/// Where the machine's power is going, in watts.
///
/// Three figures, and they reconcile: what comes in from the adapter is what the
/// system is consuming plus what is going into the battery. On this Mac, with a
/// 15 W adapter attached, `SystemPowerIn 10817 = SystemLoad 6314 + BatteryPower
/// 4503` — exactly, to the milliwatt. That is worth knowing because it means
/// these are measurements rather than an estimate assembled from percentages.
///
/// ## Which instrument answers which question
///
/// There are two sources here and they are **not** interchangeable, which is the
/// single most important thing about this file:
///
/// - **`PSTR`, from the SMC** — the live system rail. Re-reads on demand and
///   changes on every read.
/// - **`AppleSmartBattery`'s `PowerTelemetryData`** — the pack controller's own
///   accounting. It reconciles beautifully (`SystemPowerIn 10817 = SystemLoad
///   6314 + BatteryPower 4503`, to the milliwatt) but it is republished **once
///   every 60 seconds**, measured.
///
/// That cadence was the cause of a real bug. `SystemLoad` was driving the
/// "system draw" readout, so after any burst of work the panel latched the high
/// figure and held it — 19.2 W, or 74 W after something heavier — while the
/// machine sat idle underneath. Watched side by side for 30 s, `PSTR` fell
/// 19.3 W → 5.8 W and changed on all 31 reads; `SystemLoad` did not move once.
/// The number was never wrong, it was just up to a minute old and presented as
/// if it were live.
///
/// So: anything instantaneous comes from `PSTR`. The pack's own state — charge,
/// percentage, cycle count, health, and the charge rate into the cell — comes
/// from the controller, where a minute's lag is invisible because those things
/// genuinely move slowly. And because that node only changes once a minute,
/// reading it at the panel's 2 Hz was 120 reads per change; it is cached instead.
struct PowerFlow: Equatable {
    /// What the machine itself is consuming.
    var systemLoad: Double
    /// Into the battery when positive, out of it when negative.
    var batteryPower: Double
    /// Coming in from the adapter. Zero on battery.
    var adapterInput: Double
    /// What the attached adapter is rated for, when it says.
    var adapterRating: Double?

    var isCharging: Bool
    var isPluggedIn: Bool
    var isFull: Bool
    var percent: Int

    /// Watt-hours in the pack right now, and what it would hold at full.
    ///
    /// Both are computed from the *instantaneous* pack voltage, which is correct
    /// for `remainingEnergy` — it is the energy actually available this second,
    /// and it is what the runtime estimate divides. It is misleading for
    /// `fullEnergy`: a cell's terminal voltage rises as it charges, so the same
    /// pack's "full capacity" appears to grow from about 71 Wh to 80 Wh purely
    /// as it fills. Anything shown to a reader as a fixed property of the
    /// hardware uses `chargemAh` below instead, which does not move.
    var remainingEnergy: Double
    var fullEnergy: Double

    /// Charge in milliamp-hours: what the pack holds now, and what it holds when
    /// full. Stable regardless of voltage, so this is the pair the UI shows.
    var chargemAh: Double = 0
    var capacitymAh: Double = 0

    /// Whether the pack is present and healthy at all.
    var isPresent: Bool = true
    var hasFault: Bool = false
    /// Low Power Mode, from the power source rather than `ProcessInfo` — same
    /// answer, but it arrives with everything else in one read.
    var isLowPower: Bool = false

    /// Every state the battery can actually be in, in the order they take
    /// precedence. A machine can be several of these at once — plugged in *and*
    /// in Low Power Mode — so the order is what decides which one the UI leads
    /// with, and it runs most-urgent first.
    enum Condition: Equatable {
        case fault              // no cell, or the pack is reporting a problem
        case charging           // current flowing into the pack
        case adapterAssist      // plugged in, but demand exceeds what the charger gives
        case acPassthrough      // full, running from the adapter
        case optimizedHold      // plugged in, resting, deliberately below full
        case lowPowerMode       // throttled
        case discharging        // on the cell

        var title: String {
            switch self {
            case .fault: return "Hardware Fault"
            case .charging: return "Active Charge"
            case .adapterAssist: return "Adapter Assist"
            case .acPassthrough: return "AC Passthrough"
            case .optimizedHold: return "Optimized Hold"
            case .lowPowerMode: return "Low Power Mode"
            case .discharging: return "On Battery"
            }
        }
    }

    /// Below this, current into or out of the pack is noise rather than flow.
    private static let flowThreshold = 0.5

    var condition: Condition {
        if hasFault || !isPresent { return .fault }

        // Current going *into* the pack is charging, full stop — whether or not
        // macOS has an 80% limit armed. The previous version also required the
        // `IsCharging` flag and a limit-capped charge could satisfy one without
        // the other, so a battery visibly filling was reported as "Optimized
        // Hold".
        if batteryPower > Self.flowThreshold { return .charging }

        guard isPluggedIn else {
            return isLowPower ? .lowPowerMode : .discharging
        }

        // Plugged in and the pack is *draining*: the machine wants more than the
        // charger can supply, so the battery is making up the difference. This
        // is a real and fairly common state under load, and it used to fall
        // through every branch — which is how a plugged-in Mac ended up
        // reporting "On Battery" and "Optimized Hold" while charging.
        if batteryPower < -Self.flowThreshold { return .adapterAssist }

        if isFull || percent >= 100 { return .acPassthrough }
        // Plugged in, resting, below full: macOS is holding the cell short of
        // full on purpose.
        return .optimizedHold
    }

    /// The one-line status under the headline.
    var conditionDetail: String {
        switch condition {
        case .fault: return "CELL NOT DETECTED"
        case .charging: return "CURRENT FLOWING"
        case .adapterAssist: return "PACK SUPPLEMENTING CHARGER"
        case .acPassthrough: return "FULLY CHARGED"
        case .optimizedHold: return "PAUSED AT \(percent)%"
        case .lowPowerMode: return "THROTTLE ACTIVE"
        case .discharging:
            if percent < 20 { return "ON BATTERY • CRITICAL" }
            if percent < 50 { return "ON BATTERY • DRAINING" }
            return "ON BATTERY • NOMINAL"
        }
    }

    /// How the panel should read the situation. Deliberately derived from the
    /// power flow rather than from `IsCharging` alone: a plugged-in machine that
    /// has finished charging draws from the wall and puts nothing in the pack,
    /// which is a different thing to say than "charging".
    enum State: Equatable { case discharging, charging, wall }

    var state: State {
        guard isPluggedIn else { return .discharging }
        return isCharging && batteryPower > 0.5 ? .charging : .wall
    }

    /// Minutes until the pack is empty at the current system load.
    var minutesToEmpty: Int? {
        guard state == .discharging, systemLoad > 0.5 else { return nil }
        return minutes(remainingEnergy / systemLoad)
    }

    /// Minutes until full at the rate power is actually going in.
    var minutesToFull: Int? {
        guard state == .charging, batteryPower > 0.5 else { return nil }
        return minutes((fullEnergy - remainingEnergy) / batteryPower)
    }

    private func minutes(_ hours: Double) -> Int? {
        guard hours > 0, hours < 48 else { return nil }
        return Int((hours * 60).rounded())
    }

    /// The charge percentage, taken from the figure macOS itself shows.
    ///
    /// Computing it from raw capacity — `AppleRawCurrentCapacity` over
    /// `AppleRawMaxCapacity` — looks like the obvious thing and is wrong: it
    /// gave 72% against the menu bar's 76% on this machine, because Apple
    /// applies its own calibration on top of the cell's raw coulomb count. Two
    /// battery readouts on the same screen disagreeing by four points is worse
    /// than either number alone, so this reads `CurrentCapacity`, which *is*
    /// that calibrated percentage whenever `MaxCapacity` is 100.
    ///
    /// On the older Macs where the pair is reported in mAh instead, the ratio is
    /// still the right answer, so that stays as the fallback.
    ///
    /// Note this is only about the percentage. Watt-hours still come from raw
    /// capacity times voltage, which is a physical quantity and has no
    /// calibrated equivalent.
    private static func chargePercent(_ fields: [String: Any],
                                      currentmAh: Double, maxmAh: Double) -> Int {
        func number(_ key: String) -> Double? { (fields[key] as? NSNumber)?.doubleValue }
        if let current = number("CurrentCapacity"), number("MaxCapacity") == 100 {
            return Int(current.rounded())
        }
        return Int((currentmAh / maxmAh * 100).rounded())
    }

    /// Reads the pack. Nil on a machine with no battery.
    ///
    /// One `IORegistryEntryCreateCFProperties` rather than a property at a time:
    /// the whole node comes back in a single round trip, and picking eight keys
    /// out of it individually costs eight.
    /// What the wall is actually supplying.
    ///
    /// `SystemPowerIn` is metered by the battery controller, and it stops
    /// reporting once the pack is full: a plugged-in Mac that has finished
    /// charging reads 0 while the adapter is quite happily carrying the whole
    /// machine. Taken literally that printed "+0.0 W" next to a running laptop,
    /// which is the one figure on this panel that was plainly wrong.
    ///
    /// So on mains, when the reported number is absent or zero, the input is
    /// reconstructed from what it must be: everything the system is burning,
    /// plus anything going into the cell.
    /// What the adapter is supplying.
    ///
    /// **Measured, not derived — and that is a correction of a mistake.**
    ///
    /// Deriving it as `systemDraw + packFlow` looks obviously right: source
    /// equals the sum of its destinations, so the tree in the panel adds up by
    /// construction. It is wrong here because the two terms are on different
    /// clocks. The draw is live off `PSTR`; the pack's flow comes from the
    /// controller and is up to a minute old. Subtracting a stale number from a
    /// fresh one does not give you a fresh answer, it gives you the difference
    /// between two moments — and on a machine that had been busy and went quiet
    /// it produced `ADAPTER INPUT 0.0 W` while plugged into a 94 W charger,
    /// because a live 7.1 W draw was being netted against a stale −16.2 W of
    /// pack assist.
    ///
    /// `SystemPowerIn` is the controller's own measurement of the adapter, taken
    /// on the same clock as `BatteryPower`, so those two agree with each other.
    /// The tree therefore shows one live row and two slow ones, which is honest
    /// about what each instrument knows; a sum that always balanced would only
    /// have been hiding the seam.
    private static func adapterInput(reported: Double?, system: Double,
                                     battery: Double, plugged: Bool) -> Double {
        guard plugged else { return 0 }
        if let reported, reported > 0.05 { return reported }
        // No adapter figure at all: fall back to the sum, which at least shares
        // the sign convention. Signed, so a pack that is assisting correctly
        // means the adapter is carrying *less* than the system is burning.
        return max(system + battery, 0)
    }

    /// How long a read of the pack controller stays good for.
    ///
    /// The node republishes once a minute, so anything under that is free
    /// accuracy; five seconds keeps the panel responsive to a cable being
    /// plugged in — `ExternalConnected` lives on the same node — while cutting
    /// the reads from 120 per change to 12.
    static let controllerTTL: TimeInterval = 5

    /// Live system draw, in watts, from the SMC's `PSTR`.
    ///
    /// Nil on a Mac that has no such key, in which case the caller falls back to
    /// the controller's slow figure — stale beats absent.
    static func liveSystemDraw() -> Double? {
        AppleSiliconTelemetry.shared.thermal()?.systemPower
    }

    /// Exposes the adapter arithmetic to the tests. The identity it encodes —
    /// source equals the sum of its two destinations — is the whole claim the
    /// power tree makes on screen, so it is worth asserting directly.
    static func probeAdapter(reported: Double? = nil, system: Double,
                             battery: Double, plugged: Bool) -> Double {
        adapterInput(reported: reported, system: system, battery: battery, plugged: plugged)
    }

    static func read(liveDraw: Double? = liveSystemDraw()) -> PowerFlow? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let fields = raw?.takeRetainedValue() as? [String: Any]
        else { return nil }

        func number(_ key: String, in source: [String: Any]) -> Double? {
            (source[key] as? NSNumber)?.doubleValue
        }
        let telemetry = fields["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = fields["AdapterDetails"] as? [String: Any] ?? [:]

        // Millivolts and milliamps; the product is milliwatts.
        let millivolts = number("Voltage", in: fields) ?? 0
        let milliamps = number("Amperage", in: fields) ?? 0
        guard millivolts > 0 else { return nil }
        let volts = millivolts / 1000

        // `BatteryPower` is signed and already in milliwatts. Where it is
        // missing — and it is missing on some Macs — amperage times voltage is
        // the same quantity computed the long way; the two agree to within a
        // few milliwatts here.
        let batteryWatts = (number("BatteryPower", in: telemetry) ?? (milliamps * millivolts / 1000)) / 1000
        let systemWatts = (number("SystemLoad", in: telemetry)).map { $0 / 1000 }
        let inputWatts = (number("SystemPowerIn", in: telemetry)).map { $0 / 1000 }

        let plugged = (number("ExternalConnected", in: fields) ?? 0) != 0
        let charging = (number("IsCharging", in: fields) ?? 0) != 0

        guard let currentmAh = number("AppleRawCurrentCapacity", in: fields),
              let maxmAh = number("AppleRawMaxCapacity", in: fields),
              maxmAh > 0
        else { return nil }

        // The live rail first. The controller's `SystemLoad` is only reached for
        // on a machine with no `PSTR`, and its own difference only when that is
        // missing too.
        let load = liveDraw ?? systemWatts ?? max((inputWatts ?? 0) - batteryWatts, 0)

        return PowerFlow(
            systemLoad: load,
            batteryPower: batteryWatts,
            // Derived from the live draw rather than read, so the three rows of
            // the power tree add up on screen. `SystemPowerIn` is the controller's
            // own figure for the same thing and would disagree with the live one
            // by however much the machine's load has changed in the last minute.
            adapterInput: Self.adapterInput(reported: inputWatts, system: load,
                                            battery: batteryWatts, plugged: plugged),
            adapterRating: number("Watts", in: adapter),
            isCharging: charging,
            isPluggedIn: plugged,
            isFull: (number("FullyCharged", in: fields) ?? 0) != 0,
            percent: Self.chargePercent(fields, currentmAh: currentmAh, maxmAh: maxmAh),
            remainingEnergy: currentmAh / 1000 * volts,
            fullEnergy: maxmAh / 1000 * volts,
            chargemAh: currentmAh,
            capacitymAh: maxmAh,
            isPresent: (number("BatteryInstalled", in: fields) ?? 1) != 0,
            // A named health condition — "Service Battery", "Check Battery" —
            // is the pack telling you something is wrong. Empty means fine.
            hasFault: (number("PermanentFailureStatus", in: fields) ?? 0) != 0
                || !((fields["BatteryHealthCondition"] as? String) ?? "").isEmpty,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

// MARK: - The module

/// Power and battery, as a module of its own.
///
/// Split out of the thermal module deliberately. They were one because they both
/// came off the SMC, which is an implementation detail and not a reason: a
/// temperature and a wattage answer different questions, and merging them
/// produced the panel's worst bug — the system's draw and the battery's flow,
/// two genuinely different quantities, sitting next to each other as though one
/// of them were wrong.
///
/// It is also much cheaper alone. Thermal costs 2.5 ms a tick because it walks a
/// dozen SMC keys; this reads one IORegistry node at 0.23 ms, so pinning the
/// battery to the menu bar no longer drags the sensor sweep along with it.
final class PowerSampler: TelemetrySampler {
    struct Reading: Equatable {
        var flow: PowerFlow
        /// Charge cycles, and health as a percentage of the pack's design
        /// capacity — the two numbers that say how old a battery is.
        var cycleCount: Int?
        var health: Double?
        var temperature: Double?
        /// Low Power Mode, as macOS reports it.
        var isLowPower: Bool = false
        /// What is actually costing the battery: the processes burning the most
        /// CPU. Apple's "Energy Impact" is a weighted blend of CPU, wake-ups,
        /// GPU and disk that Apple has never published, so this reports the term
        /// that dominates it and labels itself as CPU rather than inventing a
        /// score and calling it energy.
        var consumers: [ProcessSampler.Row] = []
    }

    /// The process table is shared with the process module rather than swept
    /// twice — one sampler, whichever of the two modules is alive.
    private let processes = ProcessSampler()

    /// The last read of the pack controller, and when it was taken.
    ///
    /// Two IORegistry property fetches — `read()` and `condition()` — against a
    /// node that republishes once a minute. At the panel's 2 Hz that was 240
    /// fetches per change. Held for `controllerTTL` instead.
    private var cachedFlow: PowerFlow?
    private var cachedExtras: (cycles: Int?, health: Double?, celsius: Double?)?
    private var cachedAt: Date?

    func sample() -> Reading? {
        // The live half, every tick: this is the figure that actually moves.
        let draw = PowerFlow.liveSystemDraw()

        let stale = cachedAt.map { Date().timeIntervalSince($0) >= PowerFlow.controllerTTL } ?? true
        if stale || cachedFlow == nil {
            guard let flow = PowerFlow.read(liveDraw: draw) else { return nil }
            cachedFlow = flow
            cachedExtras = PowerFlow.condition()
            cachedAt = Date()
        }
        guard var flow = cachedFlow, let extras = cachedExtras else { return nil }

        // Re-derive the two figures that hang off the live draw, so a cached
        // pack state never drags a stale wattage back onto the screen.
        // Only the draw is re-derived. The adapter row is the controller's own
        // measurement and belongs to the cached snapshot with the pack flow it
        // agrees with; recomputing it against the live draw is exactly the
        // clock-mixing that produced a 0 W adapter.
        flow.systemLoad = draw ?? flow.systemLoad

        return Reading(flow: flow,
                       cycleCount: extras.cycles,
                       health: extras.health,
                       temperature: extras.celsius,
                       isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                       consumers: processes.sample()?.top ?? [])
    }

    /// Drops the cached pack state, so a module rebuilt after the panel was
    /// closed does not open on a reading from whenever it last ran.
    func teardown() {
        cachedFlow = nil
        cachedExtras = nil
        cachedAt = nil
    }
}

extension PowerFlow {
    /// Cycle count, state of health, and cell temperature.
    static func condition() -> (cycles: Int?, health: Double?, celsius: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.doubleValue
        }
        let design = number("DesignCapacity")
        let maximum = number("AppleRawMaxCapacity")
        // Health is what the pack can still hold against what it shipped with.
        let health = (design.flatMap { d in maximum.map { $0 / d } }).map { min($0, 1) }
        // Reported in hundredths of a degree.
        let celsius = number("Temperature").map { $0 / 100 }
        return (number("CycleCount").map(Int.init), health, celsius)
    }
}

@MainActor
final class PowerTelemetryWidget: TelemetryModule<PowerSampler> {
    init() { super.init(kind: .power, sampler: PowerSampler()) }

    /// The plot follows what the system is burning, which is the figure that
    /// actually moves; the battery's flow is mostly a step function.
    override func historyValue(for reading: PowerSampler.Reading) -> Double? {
        reading.flow.systemLoad
    }

    override var pinnedSummary: String? {
        guard let flow = reading?.flow else { return nil }
        switch flow.state {
        case .charging: return String(format: "+%.1f W", flow.batteryPower)
        case .discharging: return String(format: "−%.1f W", flow.systemLoad)
        case .wall: return String(format: "%.1f W", flow.systemLoad)
        }
    }

    override var pinnedBattery: (percent: Int, state: PowerFlow.State, condition: PowerFlow.Condition)? {
        reading.map { ($0.flow.percent, $0.flow.state, $0.flow.condition) }
    }

    /// Charge over flow: the two things worth two lines of menu bar.
    override var pinnedStack: (String, String)? {
        guard let flow = reading?.flow else { return nil }
        return ("\(flow.percent)%", pinnedSummary ?? "—")
    }
}
