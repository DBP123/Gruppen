import Foundation

/// Demand-driven telemetry.
///
/// The rule the whole module hangs off: **a widget nobody is looking at does
/// not exist.** Not paused, not throttled — its timer is cancelled, its object
/// is released, and the kernel is not asked anything. A widget comes into being
/// when the dropdown opens or when it is pinned to the menu bar, and it is torn
/// down the moment neither is true.
///
/// That is why the protocol carries `isPanelActive` and `isMenuBarPinned` rather
/// than a single `isEnabled`: those two are the only reasons a reading is ever
/// wanted, and they demand different cadences.
enum Telemetry {
    /// Every module samples on this one queue. Serial on purpose — the samplers
    /// hold the previous counters a rate is computed against, and a serial queue
    /// is what makes that safe without a lock in each of them.
    ///
    /// `.utility` because none of this is interactive: a monitor that competes
    /// with the app it is monitoring reports its own interference.
    static let queue = DispatchQueue(label: "com.dhilanpatel.gruppen.telemetry", qos: .utility)

    /// Points kept for a sparkline: sixty, which is the window the plots
    /// normalise across and thirty seconds at the panel's 2 Hz.
    static let historyLength = 60

    /// The dropdown is open: 2 Hz. It holds a handful of compact wells and it is
    /// open for seconds at a time.
    static let panelRate: TimeInterval = 0.5
    /// The dashboard is open: 1 Hz.
    ///
    /// Half the dropdown's rate, because it is a page of eight dense cards you
    /// leave open rather than a glance you dismiss — every tick redraws all of
    /// them, and rendering, not sampling, is what this page costs. At 1 Hz the
    /// figures still read as live and the draw work halves.
    static let dashboardRate: TimeInterval = 1.0
    /// Closed, but pinned to the menu bar: 0.5 Hz.
    static let pinnedRate: TimeInterval = 2.0
}

/// One telemetry module.
enum WidgetKind: String, CaseIterable, Identifiable, Codable {
    case cpu
    case silicon
    case memory
    case network
    case thermal
    case power
    case storage
    case processes
    /// Gruppen's own footprint. Part of the panel's chrome rather than a module
    /// the user arranges, so it is neither hideable nor pinnable.
    case footprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "Processor"
        case .silicon: return "Graphics & Engines"
        case .memory: return "Memory"
        case .network: return "Network"
        case .thermal: return "Thermal"
        case .power: return "Power & Battery"
        case .storage: return "Storage"
        case .processes: return "Processes"
        case .footprint: return "Gruppen"
        }
    }

    /// Terminal-style header printed on the well.
    var header: String {
        switch self {
        case .cpu: return "CPU"
        case .silicon: return "GPU / ENGINES"
        case .memory: return "MEMORY"
        case .network: return "NETWORK"
        case .thermal: return "THERMAL"
        case .power: return "POWER / BATTERY"
        case .storage: return "STORAGE / NVME"
        case .processes: return "PROCESSES"
        case .footprint: return "GRUPPEN"
        }
    }

    var glyph: String {
        switch self {
        case .cpu: return "cpu"
        case .silicon: return "cpu.fill"
        case .memory: return "memorychip"
        case .network: return "network"
        case .thermal: return "thermometer.medium"
        case .power: return "bolt.fill"
        case .storage: return "internaldrive"
        case .processes: return "list.bullet.rectangle"
        case .footprint: return "square.stack.3d.up.fill"
        }
    }

    var blurb: String {
        switch self {
        case .cpu: return "System-wide load, performance and efficiency clusters, every core"
        case .silicon: return "GPU utilisation, and whether the Neural and media engines are awake"
        case .memory: return "Wired, app, compressed and swap against installed RAM"
        case .network: return "Throughput across every active interface"
        case .thermal: return "Die temperatures across every sensor group, and fan speeds"
        case .power: return "System draw, battery flow, charge state and cell health"
        case .storage: return "APFS capacity, live read and write throughput, and drive identity"
        case .processes: return "The five processes using the most CPU right now"
        case .footprint: return "What Gruppen itself is costing you"
        }
    }

    /// Whether the user gets to show, hide and pin it.
    var isConfigurable: Bool { self != .footprint }

    /// Process rows are a table; there is no sensible one-line form for the
    /// menu bar, so this one cannot be pinned.
    var isPinnable: Bool { isConfigurable && self != .processes }

    /// The smallest range a plot will scale itself to.
    ///
    /// Plots here are normalised across the window — `(value − min) / (max −
    /// min)` — so a processor moving between 5% and 8% uses the full height of
    /// the graph instead of hugging the bottom of a 0–100 scale. That is the
    /// whole point, and it is also the whole danger: applied literally, a
    /// machine sitting at 0.2% turns a tenth of a percent of noise into a
    /// full-height sawtooth, which is a graph that looks alarming and says
    /// nothing.
    ///
    /// So the denominator has a floor. Below it the trace flattens out, which
    /// is the honest picture of a quantity that is not moving; above it the
    /// normalisation takes over completely. Three points of CPU is deliberately
    /// small enough that the 5%-to-8% case still fills the frame.
    var plotFloor: Double {
        switch self {
        case .cpu, .silicon, .memory: return 0.03     // 3 percentage points
        case .thermal: return 2                       // 2 °C
        case .power: return 2                         // 2 W
        case .storage: return 1_000_000               // 1 MB/s
        case .network: return 50_000                  // 50 KB/s
        case .processes, .footprint: return 0.03
        }
    }

    /// The three-letter tag a menu bar item wears, so a number in the menu bar
    /// is never a mystery. Three characters exactly: the badge is a fixed width
    /// and a four-letter one would either clip or resize the item.
    var badge: String {
        switch self {
        case .cpu: return "CPU"
        case .silicon: return "GPU"
        case .memory: return "MEM"
        case .network: return "NET"
        case .thermal: return "TMP"
        case .power: return "PWR"
        case .storage: return "SSD"
        case .processes: return "PRC"
        case .footprint: return "APP"
        }
    }

    /// Which domain colour this module wears, as an index rather than a `Color`:
    /// `WidgetKind` lives in the engine and must not reach into the design
    /// layer. `Theme.domain(_:)` turns it back into a colour.
    ///
    /// Thermal is deliberately absent — its colour is a function of the
    /// temperature, not of the module.
    var domainIndex: Int {
        switch self {
        case .cpu: return 0            // cyan
        case .silicon: return 1        // electric purple
        case .memory: return 2         // emerald
        case .network: return 3        // bright blue
        case .thermal: return 4        // dynamic
        case .power: return 2          // emerald
        case .storage: return 0        // cyan
        case .processes, .footprint: return 2
        }
    }

    static var configurable: [WidgetKind] { allCases.filter(\.isConfigurable) }
}

/// The contract every module honours.
///
/// Deliberately small: the manager sets the two demand flags and drives the
/// lifecycle, and knows nothing else about any particular module.
@MainActor
protocol GruppenWidget: AnyObject {
    var kind: WidgetKind { get }
    /// The dropdown is open and this module is one of the visible ones.
    var isPanelActive: Bool { get set }
    /// This module keeps a live readout in the menu bar itself.
    var isMenuBarPinned: Bool { get set }
    /// The menu bar one-liner, or nil while nothing has been read yet.
    var pinnedSummary: String? { get }
    /// The two figures a stacked menu bar item shows, top over bottom.
    var pinnedStack: (String, String)? { get }
    /// Charge and power state, when the module has a battery to draw.
    var pinnedBattery: (percent: Int, state: PowerFlow.State, condition: PowerFlow.Condition)? { get }
    /// The number a menu bar micro-graph plots, if this module has a shape.
    var pinnedValue: Double? { get }
    /// Everything a menu bar item can draw, in one value. Nil until the module
    /// has read something.
    var menuBarSample: MenuBarSample? { get }
    /// Run after every published reading. This is what lets a standalone menu
    /// bar item update without a clock of its own.
    var onPublish: (() -> Void)? { get set }
    /// Idempotent: calling it again with the rate already in force does nothing.
    func startFetching(rate: TimeInterval)
    /// Cancels and releases the timer. Not a pause.
    func stopFetching()
}

/// The background half of a module.
///
/// A sampler is a plain object with no actor isolation, touched only on
/// `Telemetry.queue`. It owns whatever previous counters a rate needs, which is
/// the whole reason the split exists: those counters must not be main-actor
/// state, and the published reading must not be anything else.
protocol TelemetrySampler: AnyObject {
    associatedtype Reading: Equatable
    /// Called on `Telemetry.queue`. Returns nil when there is nothing to report
    /// yet — typically the first tick of a rate-based module, which has a
    /// baseline but no interval to divide by.
    func sample() -> Reading?

    /// Called on `Telemetry.queue` when the module is destroyed. A sampler
    /// holding kernel objects — an SMC connection, an IORegistry entry — closes
    /// them here. Without this, "unchecked means destroyed" would be a claim
    /// about a Swift object and not about the hardware.
    func teardown()
}

extension TelemetrySampler {
    /// Most samplers hold nothing but numbers.
    func teardown() {}
}

/// Everything a module does that is not specific to what it measures: hold the
/// demand flags, own exactly one timer, publish on the main actor, and keep a
/// short history for the sparkline.
///
/// Subclasses supply a sampler and, optionally, override `historyValue(for:)`,
/// `pinnedSummary` and `didAccept(_:)`.
@MainActor
class TelemetryModule<S: TelemetrySampler>: ObservableObject, GruppenWidget {
    let kind: WidgetKind

    /// The latest reading. Kept across a stop so reopening the dropdown shows
    /// real numbers on the first frame rather than a row of dashes.
    @Published private(set) var reading: S.Reading?
    /// Newest last. Cleared on stop — a sparkline with a hole in it is a lie
    /// about the interval it appears to cover.
    @Published private(set) var history: [Double] = []

    var isPanelActive = false
    var isMenuBarPinned = false

    private let sampler: S
    private var timer: DispatchSourceTimer?
    private(set) var rate: TimeInterval?

    init(kind: WidgetKind, sampler: S) {
        self.kind = kind
        self.sampler = sampler
    }

    deinit { timer?.cancel() }

    final func startFetching(rate: TimeInterval) {
        guard self.rate != rate else { return }
        stopFetching()
        self.rate = rate

        let sampler = self.sampler
        let timer = DispatchSource.makeTimerSource(queue: Telemetry.queue)
        // A quarter-interval of leeway lets the kernel coalesce these ticks with
        // whatever else is waking the machine, which is most of the difference
        // between a monitor that costs nothing and one that keeps a core awake.
        timer.schedule(deadline: .now(), repeating: rate, leeway: .milliseconds(Int(rate * 250)))
        timer.setEventHandler { [weak self] in
            // Every sampler allocates — arrays of ticks, process names, CFTypes
            // out of IOKit. Without a pool around each tick those accumulate
            // until the queue drains, which on a background queue can be a long
            // time.
            autoreleasepool {
                guard let reading = sampler.sample() else { return }
                DispatchQueue.main.async { self?.accept(reading) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    final func stopFetching() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        rate = nil
        if !history.isEmpty { history = [] }
        // On the sampling queue, not here: the sampler's whole contract is that
        // it is touched from one place, and a cancelled timer may still have a
        // tick in flight behind us.
        let sampler = self.sampler
        Telemetry.queue.async { sampler.teardown() }
    }

    private func accept(_ next: S.Reading) {
        if reading != next { reading = next }
        if let value = historyValue(for: next) {
            history.append(value)
            if history.count > Telemetry.historyLength {
                history.removeFirst(history.count - Telemetry.historyLength)
            }
        }
        didAccept(next)
        onPublish?()
    }

    var onPublish: (() -> Void)?

    /// The number the sparkline plots, or nil for a module that has none.
    func historyValue(for reading: S.Reading) -> Double? { nil }

    /// Hook for a module keeping a second series of its own.
    func didAccept(_ reading: S.Reading) {}

    var pinnedSummary: String? { nil }

    var pinnedStack: (String, String)? { nil }

    /// Charge and state, for the one module that draws a battery.
    var pinnedBattery: (percent: Int, state: PowerFlow.State, condition: PowerFlow.Condition)? { nil }

    /// The newest plotted point, which is what a menu bar graph wants.
    var pinnedValue: Double? { history.last }

    /// Assembled once per reading rather than three times per redraw check.
    var menuBarSample: MenuBarSample? {
        guard let summary = pinnedSummary else { return nil }
        let stack = pinnedStack
        return MenuBarSample(summary: summary,
                             top: stack?.0,
                             bottom: stack?.1,
                             value: pinnedValue,
                             batteryPercent: pinnedBattery?.percent,
                             powerState: pinnedBattery?.state,
                             condition: pinnedBattery?.condition)
    }
}

/// A reading reduced to exactly what a menu bar item is able to draw.
///
/// The three forms travel together because the item can be switched between
/// them at any moment, and a form that was not on screen when it changed must
/// still be current the instant it becomes visible — without having published
/// anything in the meantime.
struct MenuBarSample: Equatable {
    /// The one-liner. What `.numeric` draws.
    var summary: String
    /// The two halves of `.stacked`, if the module has a second figure.
    var top: String?
    var bottom: String?
    /// The point `.sparkline` plots.
    var value: Double?
    /// Charge and power state, for the battery item, which draws a cell rather
    /// than a trace.
    var batteryPercent: Int?
    var powerState: PowerFlow.State?
    var condition: PowerFlow.Condition?
}
