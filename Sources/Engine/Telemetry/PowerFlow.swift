import Foundation
import IOKit
import IOKit.ps

/// Where the machine's power is going, in watts.
///
/// ## Three instruments, and which one to believe
///
/// This file reads three sources and they do **not** agree. Knowing which is
/// authoritative for what is the whole content of this type:
///
/// | source | what it is | cadence | trust |
/// |---|---|---|---|
/// | SMC `PSTR` | the live system rail | every read | system draw |
/// | `Amperage` × `Voltage` | the gas gauge's own current | ~60 s | pack flow |
/// | `PowerTelemetryData` | `SystemLoad`, `BatteryPower`, `SystemPowerIn` | ~60 s | adapter only |
///
/// Both mistakes this file has made were about picking the wrong one.
///
/// **`SystemLoad` is not the live draw.** It republishes once a minute, so after
/// a burst of work the panel latched the high figure and held it — 19.2 W, or
/// 74 W after something heavier — while the machine sat idle underneath. Watched
/// beside `PSTR` for 30 s, `PSTR` fell 19.3 → 5.8 W and changed on all 31 reads;
/// `SystemLoad` did not move once.
///
/// **`BatteryPower` is not the pack flow.** The trio reconciles exactly on every
/// read — `SystemPowerIn == SystemLoad + BatteryPower`, to the milliwatt — which
/// looks like three measurements agreeing and is not: `BatteryPower` is
/// *derived* from `SystemLoad`, so it inherits that lag and can cross zero on
/// nothing. Measured against ground truth, with the pack's own capacity watched
/// for 150 s while it charged:
///
/// ```
///   capacity gained      +206 mAh in 150 s  ->  4,944 mA  ~=  62 W in
///   Amperage             4,995 -> 4,502 mA          matches, within 1%
///   BatteryPower         +0.90 -> -8.74 W           negative, while charging
/// ```
///
/// A negative pack flow on a plugged-in machine is what `ASSIST` is, so this is
/// exactly how a 94 W charger on an idle Mac reported `• ASSIST` at 0.9 W. The
/// coulomb counter is the measurement; the derived figure is arithmetic.
///
/// `SystemPowerIn` is kept for one job only — the adapter row — because it is
/// the only *independent* reading of what the wall is supplying, and the assist
/// guard needs a figure that is not itself built out of draw and pack.
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
    ///
    /// A pack resting on a charger sits at a few tens of milliwatts either way
    /// as the controller trims the cell. Without a deadband the sign of that
    /// noise decides the state, and the panel flips between HOLD and ASSIST on
    /// nothing.
    static let deadband = 0.1

    /// An adapter supplying less than this is not being out-run by anything.
    ///
    /// The guard exists for the case where the adapter figure itself is
    /// untrustworthy — a charger still negotiating, or a reading taken in the
    /// second after the cable went in. "The system is drawing more than the wall
    /// can give" is not a claim worth making about a 0.9 W adapter reading.
    static let assistFloor = 5.0

    /// Snaps near-zero pack flow to exactly zero, so a resting pack reads as
    /// resting rather than as a very small charge or discharge.
    static func deadbanded(_ watts: Double) -> Double {
        abs(watts) < deadband ? 0 : watts
    }

    /// The state machine.
    ///
    /// Ordered most-urgent first, and gated on `ExternalConnected` before
    /// anything else, because that flag is the one thing here that is both
    /// instantaneous and unambiguous. `IsCharging` is deliberately *not* used to
    /// decide: it stays true through an 80% hold and it lags the cable, so a
    /// machine visibly filling has been reported as "Optimized Hold" on the
    /// strength of it.
    ///
    /// ```
    ///   !plugged                     -> discharging  (or lowPowerMode)
    ///   plugged, pack > +deadband    -> charging
    ///   plugged, pack < -deadband    -> assist, but only if the adapter is
    ///                                   really being out-run (see below)
    ///   plugged, |pack| <= deadband  -> passthrough when full, else hold
    /// ```
    var condition: Condition {
        if hasFault || !isPresent { return .fault }

        guard isPluggedIn else {
            return isLowPower ? .lowPowerMode : .discharging
        }

        // Into the pack is charging, whether or not an 80% limit is armed.
        if batteryPower > Self.deadband { return .charging }

        // Out of the pack *while plugged in* is only assist if the wall really
        // cannot keep up. Three conditions, all required:
        //
        //   1. the pack is genuinely discharging, past the deadband;
        //   2. the adapter is supplying enough for "out-run" to mean anything —
        //      a 0.9 W reading is a charger negotiating, not one at its limit;
        //   3. the system is actually drawing more than the adapter gives.
        //
        // Without (2) and (3), plugging a 94 W charger into an idle machine
        // reported ASSIST at 0.9 W. The deeper cause was the register this used
        // to read — see `read()` — but the guard is worth keeping regardless:
        // assist is a claim about a deficit, so a deficit is what should be
        // required to make it.
        if batteryPower < -Self.deadband,
           adapterInput >= Self.assistFloor,
           systemLoad > adapterInput {
            return .adapterAssist
        }

        // Plugged in, and either resting or trickling below the deadband.
        if isFull || percent >= 100 { return .acPassthrough }
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
        return batteryPower > Self.deadband ? .charging : .wall
    }

    /// Minutes until the pack is empty at the current system load.
    var minutesToEmpty: Int? {
        guard state == .discharging, systemLoad > 0.5 else { return nil }
        return minutes(remainingEnergy / systemLoad)
    }

    /// Minutes until full at the rate power is actually going in.
    var minutesToFull: Int? {
        guard state == .charging, batteryPower > Self.deadband else { return nil }
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
        AppleSiliconTelemetry.shared.systemPower()
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

        // Pack power from the **coulomb counter**, not from `BatteryPower`.
        //
        // This is a correction, and the evidence is worth keeping. Watching the
        // pack's own capacity for 150 s while it charged, it gained 206 mAh —
        // a true current of 4,944 mA, about 62 W. Over the same window:
        //
        //   Amperage                     4,995 → 4,502 mA   (matches, ~1%)
        //   PowerTelemetryData.BatteryPower   +0.90 → −8.74 W   (does not)
        //
        // `BatteryPower` went *negative while the battery was charging at 62 W*,
        // and that is the whole false-`ASSIST` bug: the state machine read a
        // negative pack flow on a plugged-in machine and called it assist. The
        // reason is that the trio `SystemPowerIn == SystemLoad + BatteryPower`
        // reconciles exactly on every read — `BatteryPower` is *derived* from
        // `SystemLoad`, which lags, so as the load figure drifts the derived
        // pack flow swings and can cross zero. It is arithmetic, not a
        // measurement.
        //
        // `Amperage` is the gas gauge's own integrated current, and it agreed
        // with the capacity actually gained. It is the measurement.
        let measured = milliamps * millivolts / 1_000_000
        let batteryWatts = Self.deadbanded(measured)
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
    /// One quantity, four ways of reading it.
    ///
    /// The averages are over a *time* window rather than a sample count, because
    /// the module's rate changes with what is looking at it — 1 Hz on the
    /// dashboard, 2 Hz in a popover, 0.5 Hz pinned. "The last sixty samples"
    /// would mean sixty seconds, thirty seconds or two minutes depending on
    /// where you happened to be looking.
    ///
    /// Worth knowing before trusting the pack row's averages: the pack's flow
    /// comes from a controller that republishes once a minute, so averaging it
    /// smooths a staircase rather than a curve. The draw is live off the SMC and
    /// averages properly.
    struct Trend: Equatable {
        var live: Double = 0
        var avg10: Double = 0
        var avg60: Double = 0
        /// Highest seen since this module was built. Reset when it is torn down,
        /// so it means "this session" rather than "since some forgotten burst".
        var peak: Double = 0

        func value(_ readout: RailReadout) -> Double {
            switch readout {
            case .live: return live
            case .avg10: return avg10
            case .avg60: return avg60
            case .peak: return peak
            }
        }
    }

    struct Reading: Equatable {
        var flow: PowerFlow
        /// System draw and pack flow, each with its averages and peak.
        var draw = Trend()
        var pack = Trend()
        /// Charge cycles, and health as a percentage of the pack's design
        /// capacity — the two numbers that say how old a battery is.
        var cycleCount: Int?
        var health: Double?
        var temperature: Double?
        /// Low Power Mode, as macOS reports it.
        var isLowPower: Bool = false
    }

    /// The last read of the pack controller, and when it was taken.
    ///
    /// Two IORegistry property fetches — `read()` and `condition()` — against a
    /// node that republishes once a minute. At the panel's 2 Hz that was 240
    /// fetches per change. Held for `controllerTTL` instead.
    private var cachedFlow: PowerFlow?
    private var cachedExtras: (cycles: Int?, health: Double?, celsius: Double?)?
    private var cachedAt: Date?

    /// Rolling window for the averages. Sixty seconds of it, trimmed by age.
    private var history: [(at: Date, draw: Double, pack: Double)] = []
    private var peakDraw: Double = 0
    private var peakPack: Double = 0

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
        record(draw: flow.systemLoad, pack: flow.batteryPower)

        return Reading(flow: flow,
                       draw: trend(for: flow.systemLoad, keyPath: \.draw, peak: &peakDraw),
                       pack: trend(for: flow.batteryPower, keyPath: \.pack, peak: &peakPack),
                       cycleCount: extras.cycles,
                       health: extras.health,
                       temperature: extras.celsius,
                       isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Adds this tick to the window and returns the four readings.
    ///
    /// `record` is called once per sample before either trend is built, so both
    /// share one window and one timestamp.
    private func trend(for value: Double,
                       keyPath: KeyPath<(at: Date, draw: Double, pack: Double), Double>,
                       peak: inout Double) -> Trend {
        func mean(_ seconds: TimeInterval) -> Double {
            let cutoff = Date().addingTimeInterval(-seconds)
            let window = history.filter { $0.at >= cutoff }
            guard !window.isEmpty else { return value }
            return window.reduce(0) { $0 + $1[keyPath: keyPath] } / Double(window.count)
        }
        // Peak is by magnitude so a pack discharging at 40 W registers as a peak
        // the same way a 40 W charge would, but keeps its sign for display.
        if abs(value) > abs(peak) { peak = value }
        return Trend(live: value, avg10: mean(10), avg60: mean(60), peak: peak)
    }

    private func record(draw: Double, pack: Double) {
        let now = Date()
        history.append((now, draw, pack))
        let cutoff = now.addingTimeInterval(-60)
        if let first = history.first, first.at < cutoff {
            history.removeAll { $0.at < cutoff }
        }
    }

    /// Drops the cached pack state, so a module rebuilt after the panel was
    /// closed does not open on a reading from whenever it last ran. The window
    /// and the peaks go with it — a "session peak" that survived the module
    /// being destroyed would be a number from a session that has ended.
    func teardown() {
        cachedFlow = nil
        cachedExtras = nil
        cachedAt = nil
        history.removeAll(keepingCapacity: false)
        peakDraw = 0
        peakPack = 0
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

/// Which of a rail row's four readings to show.
///
/// Per-row and persisted, because the useful answer differs by row and by what
/// you are doing: `live` when you are watching a build spike, `60s avg` when you
/// want to know what the machine actually costs to run, `peak` when you are
/// hunting for what tripped the fans.
enum RailReadout: String, CaseIterable, Codable {
    case live
    case avg10
    case avg60
    case peak

    /// The parenthetical after the row title.
    var label: String {
        switch self {
        case .live: return "live"
        case .avg10: return "10s avg"
        case .avg60: return "60s avg"
        case .peak: return "peak"
        }
    }

    /// The pack row has no peak. A "highest charge rate this session" is the
    /// charger's rated current and tells you nothing about the machine, whereas
    /// a peak *draw* is a real diagnostic.
    static let drawModes: [RailReadout] = [.live, .avg10, .avg60, .peak]
    static let packModes: [RailReadout] = [.live, .avg10, .avg60]

    func next(in modes: [RailReadout]) -> RailReadout {
        guard let index = modes.firstIndex(of: self) else { return modes[0] }
        return modes[(index + 1) % modes.count]
    }
}
