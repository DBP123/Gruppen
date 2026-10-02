import AppKit
import Darwin
import Foundation

/// One application and the share of the machine's power it is responsible for.
struct AppPowerRow: Identifiable, Equatable {
    /// The application's own process. Identity, not just a label — two copies of
    /// the same app from different bundles are two rows.
    var pid: pid_t
    var bundleID: String?
    var name: String
    /// Core-fractions: 1.0 is one core saturated. A threaded app exceeds 1.
    var cpu: Double
    /// The attributed wattage. See `AppPowerSampler` for what that means.
    var watts: Double
    /// How many processes were folded into this row, the app's own included.
    var processCount: Int

    var id: pid_t { pid }
}

/// Estimates what each running application is costing in watts.
///
/// ## The honest description of this number
///
/// **It is an attribution, not a measurement.** There is no public API on macOS
/// that reports per-process power, because the hardware does not measure it:
/// the SMC meters the *package*, one number for the whole machine. So the only
/// thing available is to measure the package and divide it by something. This
/// divides it by CPU time, which means the figure is right in the way a
/// proportion is right and wrong in the ways CPU time is not the whole story —
/// a process hammering the GPU, keeping the SSD busy, or holding the radio awake
/// costs power that lands on somebody else's row.
///
/// That is a real limitation, and it is stated in the UI rather than only here.
///
/// ## The arithmetic
///
/// ```
///   busy_i   = (cpu_i(t) − cpu_i(t−1)) / Δt        core-fractions, per pid
///   total    = Σ busy_i  over every pid on the machine
///   app_j    = Σ busy_i  over the pids belonging to app j
///   watts_j  = packageWatts × app_j / total
/// ```
///
/// **The denominator is the whole machine, not the sum of the apps.** That is the
/// one decision here that keeps the number from being a lie. Normalising across
/// applications alone would divide the entire package between whatever apps
/// happen to be listed — so on a machine where `kernel_task`, `WindowServer` and
/// forty daemons are doing most of the work, a text editor at 0.3% CPU would be
/// billed for a large slice of a 20 W draw. With every pid in the denominator the
/// listed rows sum to *less* than the package, and the difference is shown as its
/// own line. The arithmetic is visible on screen, so it can be checked.
///
/// Δt is measured rather than assumed to be the polling period, for the reason
/// `EnergyImpactSampler` documents: a background tick carries leeway and does not
/// land on 1.500 s, and dividing by the nominal figure quietly scales every
/// number on screen by the drift.
///
/// ## Which processes belong to which app
///
/// `NSWorkspace.runningApplications` names the *applications*; the kernel counts
/// *processes*, and a modern app is many. So each pid is walked up its parent
/// chain until it reaches a pid that is an application, and it is billed there.
/// That catches helpers an app forked itself.
///
/// **It does not catch every helper, and the gap is worth knowing.** XPC services
/// and Safari's `com.apple.WebKit.WebContent` processes are started by `launchd`
/// on the app's behalf, so their parent is pid 1 and the chain reaches nothing.
/// Activity Monitor groups those correctly because it uses the *responsible* pid,
/// which has no public API — only a symbol in `libsystem` behind a private
/// header. Reaching for it would put the app in exactly the position the
/// `NetworkStatistics` `dlopen` already puts it in, and for cosmetics rather than
/// for a capability. So a browser's content processes land in the remainder line
/// instead, and the remainder line says what it is.
///
/// ## Cost
///
/// One `proc_listallpids`, then two cheap per-pid calls: the rusage read the rest
/// of the app already uses, and `PROC_PIDTBSDINFO` for the parent — which, like
/// `PROC_PIDTASKINFO`, does not touch the process's memory maps. It runs at
/// 1.5 s and only while the fold is open, the same rule as every other module.
///
/// `@unchecked Sendable` for the same reason `EnergyImpactSampler` is: the
/// mutable baselines are confined to `Telemetry.queue` by convention, and nothing
/// but this sentence enforces it.
final class AppPowerSampler: TelemetrySampler, @unchecked Sendable {
    /// Where the package figure came from. Shown, because "measured off the
    /// system rail" and "modelled from a TDP" do not deserve equal confidence.
    enum Basis: Equatable {
        /// The SMC's live system rail. What the hardware is burning, now.
        case systemRail
        /// The battery controller's own coulomb counter — `Amperage` × `Voltage`.
        /// Slower (the node republishes about once a minute) but measured.
        case packMeter
        /// No power instrument on this machine. A TDP scaled by how busy the
        /// cores actually are. An estimate, labelled as one.
        case model

        var label: String {
            switch self {
            case .systemRail: return "SYSTEM RAIL"
            case .packMeter: return "BATTERY METER"
            case .model: return "MODELLED"
            }
        }

        /// Whether the package figure under these rows was measured at all.
        var isMeasured: Bool { self != .model }
    }

    struct Reading: Equatable {
        var rows: [AppPowerRow]
        /// What the whole machine is drawing.
        var packageWatts: Double
        /// What the rows above add up to. Always ≤ `packageWatts`.
        var attributedWatts: Double
        var basis: Basis

        /// Everything not attributable to a running application: the kernel,
        /// the window server, daemons, and the helpers whose parent is `launchd`.
        var systemWatts: Double { max(packageWatts - attributedWatts, 0) }
    }

    /// Rows the fold shows. Eight, because a ninth is always a rounding error.
    static let rowCount = 8

    /// Below this a row is noise. A list of applications at 0.0 W is not a
    /// finding, and at this scale the attribution cannot support another digit.
    static let floorWatts = 0.05

    /// Which pids are applications, snapshotted on the main actor.
    ///
    /// `NSWorkspace` is AppKit, and this sampler runs on a background queue, so
    /// the roster is built where AppKit lives and handed over. It is refreshed
    /// after every tick, which means it can be one interval stale — an app
    /// launched half a second ago gets its row on the next pass. That is the same
    /// latency a new pid already has for its rate, so it costs nothing anyone can
    /// see.
    struct Roster: Sendable, Equatable {
        struct Entry: Sendable, Equatable {
            var pid: pid_t
            var name: String
            var bundleID: String?
        }

        var apps: [Entry] = []
        /// Application pid → index into `apps`.
        var index: [pid_t: Int] = [:]

        /// Read on the main actor, where AppKit is.
        @MainActor
        static func current() -> Roster {
            var roster = Roster()
            for app in NSWorkspace.shared.runningApplications {
                let pid = app.processIdentifier
                // A terminated app reports -1, and pid 0 is the kernel.
                guard pid > 0 else { continue }
                // Two NSRunningApplications can share a pid in no sane case, but
                // the first one wins rather than the roster growing a duplicate
                // row for the same process.
                guard roster.index[pid] == nil else { continue }
                roster.index[pid] = roster.apps.count
                roster.apps.append(Entry(pid: pid,
                                         name: app.localizedName
                                            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                                            ?? "pid \(pid)",
                                         bundleID: app.bundleIdentifier))
            }
            return roster
        }
    }

    private var roster = Roster()
    /// Cumulative CPU seconds from the previous pass, per pid.
    private var previous: [pid_t: Double] = [:]
    private var previousAt: Date?

    /// Whether this sampler holds the SMC connection.
    ///
    /// **It has to hold its own.** `PowerFlow.liveSystemDraw()` goes through
    /// `AppleSiliconTelemetry`, whose every accessor opens with `guard smc != 0`,
    /// and that connection exists only while some sampler has called `acquire()`.
    /// `PowerSampler` learned this the hard way — it never acquired, so the row
    /// labelled "(live)" was the controller's once-a-minute figure the whole time
    /// whenever the power card ran on its own. This fold can be opened with
    /// nothing else alive beside it, so it acquires too.
    private var hardware = false

    /// Cached pack reading for the `packMeter` path, on the same TTL
    /// `PowerSampler` uses: the controller node republishes about once a minute,
    /// so re-reading it at 1.5 s would be forty fetches per change.
    private var cachedFlow: PowerFlow?
    private var cachedAt: Date?

    /// Replaces the roster. Dispatched onto the sampling queue, which is what
    /// makes writing it from the main actor safe without a lock.
    func updateRoster(_ new: Roster) {
        Telemetry.queue.async { [self] in roster = new }
    }

    func sample() -> Reading? {
        if !hardware {
            hardware = true
            AppleSiliconTelemetry.shared.acquire()
        }

        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        let now = Date()
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        var current: [pid_t: Double] = [:]
        current.reserveCapacity(count)
        var parents: [pid_t: pid_t] = [:]
        parents.reserveCapacity(count)
        var busy: [pid_t: Double] = [:]
        busy.reserveCapacity(count)
        var total = 0.0

        for slot in 0..<count {
            let pid = pids[slot]
            // Anything owned by another user refuses; there are always a few.
            guard pid > 0, let usage = processUsage(of: pid) else { continue }
            let cpuTime = processCPUSeconds(usage)
            current[pid] = cpuTime
            if let parent = Self.parent(of: pid) { parents[pid] = parent }

            // No baseline means this pid is new to us. The monotonicity check
            // catches the other case: pids are recycled, and a reused number
            // whose counters reset backwards would give an enormous negative
            // difference.
            guard elapsed > 0.05, let before = previous[pid], cpuTime >= before else { continue }
            let fraction = (cpuTime - before) / elapsed
            guard fraction > 0 else { continue }
            busy[pid] = fraction
            total += fraction
        }

        previous = current
        previousAt = now

        // No interval yet, or a machine so idle that nothing moved. Dividing by
        // this would attribute the whole package to whatever rounded up first.
        guard total > 0, let package = packageWatts(busyCores: total) else { return nil }

        // Fold every pid onto the application that owns it.
        var appBusy = [Double](repeating: 0, count: roster.apps.count)
        var appProcesses = [Int](repeating: 0, count: roster.apps.count)
        for (pid, fraction) in busy {
            guard let owner = Self.owner(of: pid, roster: roster, parents: parents) else { continue }
            appBusy[owner] += fraction
            appProcesses[owner] += 1
        }

        var rows: [AppPowerRow] = []
        var attributed = 0.0
        for (slot, entry) in roster.apps.enumerated() where appBusy[slot] > 0 {
            let watts = package.watts * appBusy[slot] / total
            // Counted towards the total before the display floor is applied, so
            // the remainder line stays truthful: a hundred apps at 0.02 W are
            // still 2 W, and they belong to the apps rather than to the system.
            attributed += watts
            guard watts >= Self.floorWatts else { continue }
            rows.append(AppPowerRow(pid: entry.pid,
                                    bundleID: entry.bundleID,
                                    name: entry.name,
                                    cpu: appBusy[slot],
                                    watts: watts,
                                    processCount: appProcesses[slot]))
        }
        rows.sort { $0.watts > $1.watts }

        return Reading(rows: Array(rows.prefix(Self.rowCount)),
                       packageWatts: package.watts,
                       attributedWatts: min(attributed, package.watts),
                       basis: package.basis)
    }

    /// Drops the baselines and lets go of the hardware.
    ///
    /// Keeping the baselines would mean the first row shown after reopening was a
    /// rate averaged over however long the fold was shut, presented as the last
    /// second and a half. One blank tick is the honest price of a true reading.
    func teardown() {
        previous.removeAll(keepingCapacity: false)
        previousAt = nil
        cachedFlow = nil
        cachedAt = nil
        guard hardware else { return }
        hardware = false
        AppleSiliconTelemetry.shared.release()
    }

    /// The safety net every SMC-holding sampler in this app carries: a sampler
    /// dropped without `teardown()` would hold the connection open for the life
    /// of the process. The release goes back to the serial queue, because that is
    /// what makes the reference count safe without a lock.
    deinit {
        guard hardware else { return }
        Telemetry.queue.async { AppleSiliconTelemetry.shared.release() }
    }

    // MARK: - The package figure

    /// What the whole machine is drawing, and how well that is known.
    ///
    /// In order of trust, which is the order this file's siblings established:
    /// the SMC's live rail, then the pack's own coulomb counter, then a model.
    /// See `PowerFlow` for why the controller's `SystemLoad` is *not* on this
    /// list as its own entry — on battery it is identically `−BatteryPower`, a
    /// derived figure measured crossing zero by 9.6 W, which is how a laptop came
    /// to report −17.4 W of draw.
    /// `busyCores` is the machine-wide load this pass already measured, in
    /// core-fractions. Only the model needs it, and it is the one figure the
    /// model has that is not an assumption.
    private func packageWatts(busyCores: Double) -> (watts: Double, basis: Basis)? {
        if let rail = PowerFlow.liveSystemDraw(), rail > 0 {
            return (rail, .systemRail)
        }
        if let flow = cachedPackFlow(), flow.systemLoad > 0 {
            return (flow.systemLoad, .packMeter)
        }
        return (Self.modelledPackage(busyCores: busyCores), .model)
    }

    /// The pack controller, re-read no more often than it republishes.
    ///
    /// `liveDraw: nil` on purpose: it forces `PowerFlow.read` down its own
    /// fallback, which on battery is the coulomb counter and on mains is the
    /// controller's clamped `SystemLoad`. Asking it for the live rail again would
    /// just repeat the call that already returned nil above.
    private func cachedPackFlow() -> PowerFlow? {
        let stale = cachedAt.map { Date().timeIntervalSince($0) >= PowerFlow.controllerTTL } ?? true
        if stale || cachedFlow == nil {
            // A Mac with no battery has no such node, and that is not an error —
            // it is a desktop. The model below covers it.
            guard let flow = PowerFlow.read(liveDraw: nil) else { return nil }
            cachedFlow = flow
            cachedAt = Date()
        }
        return cachedFlow
    }

    /// A package figure for a Mac that meters nothing.
    ///
    /// **This is a model and it is labelled as one on screen.** Two stated
    /// assumptions, neither measured on the host:
    ///
    /// 1. A package TDP scaled by core count, held inside 15–30 W: 15 W at eight
    ///    cores or fewer, rising to 30 W at sixteen. That is the envelope for the
    ///    Apple silicon parts this app runs on, and it is deliberately a floor of
    ///    an estimate rather than a Mac Pro's ceiling — overstating the package
    ///    overstates every row under it.
    /// 2. An idle floor of a fifth of that, because a machine doing nothing still
    ///    burns watts, and attributing the whole envelope to whatever process
    ///    ticked first is the failure mode this guards against.
    ///
    /// Between the two it interpolates on how busy the cores actually are. With
    /// `busyCores` unknown it returns the floor, which understates rather than
    /// invents.
    static func modelledPackage(busyCores: Double?) -> Double {
        let cores = Double(max(ProcessInfo.processInfo.processorCount, 1))
        let envelope = 15 + 15 * min(max(cores - 8, 0) / 8, 1)
        let floor = envelope * 0.2
        guard let busyCores else { return floor }
        let load = min(max(busyCores / cores, 0), 1)
        return floor + (envelope - floor) * load
    }

    // MARK: - Ancestry

    /// A process's parent, or nil when the kernel will not say.
    ///
    /// `PROC_PIDTBSDINFO` is the cheap half of `proc_pidinfo` for this purpose —
    /// like `PROC_PIDTASKINFO` it does not walk the process's memory maps, which
    /// is what makes ~190 of them affordable at this rate. A short read is
    /// treated as no answer rather than as a zero parent: `proc_pidinfo` returns
    /// the bytes it wrote, and anything less than the whole struct means the
    /// fields were not all filled in.
    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(bitPattern: info.pbi_ppid)
        return parent > 0 ? parent : nil
    }

    /// Which application a process belongs to, by walking up its parents.
    ///
    /// Stops at `launchd` — pid 1 is the ancestor of everything, so treating it
    /// as an owner would bill the whole machine to whatever application happened
    /// to be pid 1's child. The depth cap is not decoration: the pid table is
    /// sampled process by process rather than atomically, so a pid recycled
    /// mid-sweep can leave a parent chain that points back into itself.
    static func owner(of pid: pid_t, roster: Roster, parents: [pid_t: pid_t]) -> Int? {
        var current = pid
        for _ in 0..<32 {
            if let index = roster.index[current] { return index }
            guard let parent = parents[current], parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }
}

/// Drives `AppPowerSampler` while — and only while — the breakdown is on screen.
///
/// `ObservableObject` rather than the `@Observable` macro: the app ships to
/// macOS 13 and that macro needs 14. It is also what every other monitor here
/// uses, and one object in a different observation model would be the odd one
/// out for no gain.
///
/// Not a `TelemetryModule`: this is a section inside the power panel rather than
/// a module of its own, so it has no `WidgetKind`, never appears in telemetry
/// settings and cannot be pinned to the menu bar. What it does share is the rule
/// the rest of the app is built on — the timer exists only while the view is on
/// screen, and closing the fold destroys it rather than pausing it.
@MainActor
final class AppPowerMonitor: ObservableObject {
    @Published private(set) var reading: AppPowerSampler.Reading?

    /// 1.5 s, which is the window the attribution is averaged over. Slower than
    /// the panel's 2 Hz on purpose: this is the heaviest sweep in the app, and a
    /// per-app wattage resampled twice a second is mostly noise.
    static let interval: TimeInterval = 1.5

    private let sampler = AppPowerSampler()
    private var running = false

    deinit { TelemetryClock.shared.unregister(ObjectIdentifier(self)) }

    /// Snapshots the application roster and starts the poll.
    ///
    /// The first tick lands immediately and establishes the CPU baseline, so the
    /// first reading arrives one interval later. That is not a delay that can be
    /// engineered away: a rate needs two samples, and there is no honest figure
    /// to show in between.
    func start() {
        guard !running else { return }
        running = true
        sampler.updateRoster(AppPowerSampler.Roster.current())
        let sampler = self.sampler
        TelemetryClock.shared.register(ObjectIdentifier(self), period: Self.interval) { [weak self] in
            guard let reading = sampler.sample() else { return nil }
            return { self?.accept(reading) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        TelemetryClock.shared.unregister(ObjectIdentifier(self))
        reading = nil
        // On the sampling queue: a cancelled timer can still have a tick in
        // flight behind us, and the sampler's contract is one thread only.
        let sampler = self.sampler
        Telemetry.queue.async { sampler.teardown() }
    }

    private func accept(_ new: AppPowerSampler.Reading) {
        if reading != new { reading = new }
        // Re-read the roster for the next pass, here on the main actor where
        // AppKit lives. Doing it after the tick rather than before means the
        // roster is at most one interval old; doing it on the main actor means
        // `NSWorkspace` is never touched from the sampling queue.
        sampler.updateRoster(AppPowerSampler.Roster.current())
    }
}
