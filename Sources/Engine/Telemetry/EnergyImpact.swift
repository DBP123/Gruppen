import Foundation
import Darwin

/// One process and what it is costing.
struct EnergyImpactRow: Equatable, Identifiable {
    var pid: pid_t
    var name: String
    /// Percent of *one* core. A threaded process can exceed 100.
    var cpu: Double
    /// Package idle exits per second attributed to this process.
    var wakeups: Double
    /// The heuristic below. Unitless — it ranks, it does not measure.
    var score: Double
    var id: pid_t { pid }
}

/// The heaviest processes by energy, straight out of the kernel.
///
/// No `Process()`, no `/usr/bin/top`. Spawning a shell-out every second would
/// cost a `fork`, an `exec`, a dynamic-link pass and a page-in of a whole binary
/// per sample — far more energy than the thing being measured, which is a
/// ridiculous way to run a battery monitor. This reads the same kernel counters
/// `top` reads, in-process: measured at 0.6 ms over ~190 processes on a quiet
/// machine and 2.0 ms with three browsers working, once per second, and only
/// while the panel is open.
///
/// ## The arithmetic
///
/// `proc_pid_rusage` reports **cumulative** counters — total CPU time and total
/// idle wakeups since the process started — so neither is a rate until it is
/// differenced. Each pass stores what it saw; the next pass subtracts and
/// divides by the interval that actually elapsed:
///
/// ```
/// cpu%      = (cpu_now − cpu_before) / elapsed × 100
/// wakeups/s = (wkups_now − wkups_before) / elapsed
/// impact    = cpu% + wakeups/s × 0.5
/// ```
///
/// The elapsed time is measured rather than assumed to be the polling interval.
/// A background queue tick with a quarter-second of leeway on it does not land
/// exactly on 1.000 s, and dividing by the nominal figure quietly scales every
/// number on screen by whatever the timer drifted.
///
/// ## What the score is and is not
///
/// It is a ranking heuristic in the shape of Activity Monitor's, not Activity
/// Monitor's number. Apple's is closed, and folds in GPU time, disk and network
/// I/O, display wake and QoS class on top of these two terms. Expect the same
/// *order* here, not the same values.
///
/// One measured caveat worth knowing on Apple Silicon: `ri_pkg_idle_wkups`
/// counts wakeups that pulled the whole package out of its deepest idle state,
/// and those are genuinely rare — on this machine 7 processes out of 189
/// reported any at all, totalling 32/s. So the wakeup term is usually small and
/// the ranking mostly follows CPU. That is the platform being efficient, not the
/// counter being broken. `ri_interrupt_wkups` is far busier (~1,500/s) but
/// counts ordinary interrupt deliveries, and weighting *those* at 0.5 each puts
/// a 1%-CPU daemon above a browser at 60% — which is why the idle counter is the
/// right one despite reading as mostly zero.
///
/// `@unchecked Sendable` is the accurate description of what this is: mutable
/// state that is safe because it is confined to one queue, not because the type
/// is immutable. `sample()` runs on `Telemetry.queue` from the timer and
/// `teardown()` is dispatched onto the same queue, so the two baseline
/// dictionaries are never touched from two places at once. Nothing but the
/// convention enforces that, which is why it is stated here.
final class EnergyImpactSampler: TelemetrySampler, @unchecked Sendable {
    struct Reading: Equatable {
        var top: [EnergyImpactRow]
    }

    /// Rows the panel shows.
    static let rowCount = 10
    /// Apple's published rule of thumb: one idle wakeup per second costs about
    /// as much as half a percent of a core.
    static let wakeupWeight = 0.5

    /// Cumulative counters from the previous pass, per pid.
    private struct Baseline {
        var cpu: Double
        var wakeups: UInt64
    }

    private var previous: [pid_t: Baseline] = [:]
    private var previousAt: Date?

    func sample() -> Reading? {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        let now = Date()
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        var current: [pid_t: Baseline] = [:]
        current.reserveCapacity(count)
        var scored: [(pid: pid_t, cpu: Double, wakeups: Double, score: Double)] = []
        scored.reserveCapacity(count)

        for index in 0..<count {
            let pid = pids[index]
            // Processes owned by another user refuse; there are always a few.
            guard pid > 0, let usage = processUsage(of: pid) else { continue }
            let cpuTime = processCPUSeconds(usage)
            let wakeups = usage.ri_pkg_idle_wkups
            current[pid] = Baseline(cpu: cpuTime, wakeups: wakeups)

            // No baseline means this pid is new to us — either the sampler just
            // started or the process just launched. It gets a rate next tick.
            // The monotonicity checks catch the other case: pids are recycled,
            // and a reused number whose counters have reset backwards would
            // otherwise produce an enormous negative difference.
            guard elapsed > 0.05, let before = previous[pid],
                  cpuTime >= before.cpu, wakeups >= before.wakeups else { continue }

            let percent = (cpuTime - before.cpu) / elapsed * 100
            let rate = Double(wakeups - before.wakeups) / elapsed
            let score = percent + rate * Self.wakeupWeight
            // A list of one hundred sleeping daemons scoring 0.00 is not a
            // finding. Only processes that did something get a row.
            guard score > 0.005 else { continue }
            scored.append((pid, percent, rate, score))
        }

        previous = current
        previousAt = now
        guard !scored.isEmpty else { return nil }

        scored.sort { $0.score > $1.score }

        // Naming happens *after* the sort, for ten pids instead of all ~190.
        // `proc_name` is the single most expensive call in the sweep — 0.18 ms
        // across every pid, against 0.56 ms for the rusage walk itself — and
        // nine out of ten of those names would be sorted straight off the end
        // of the list. (`proc_pidpath` gives untruncated names but costs
        // 1.62 ms, nine times more, for a string this panel is too narrow to
        // show in full anyway.)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        var rows: [EnergyImpactRow] = []
        rows.reserveCapacity(Self.rowCount)
        for entry in scored.prefix(Self.rowCount) {
            guard proc_name(entry.pid, &nameBuffer, 256) > 0 else { continue }
            rows.append(EnergyImpactRow(pid: entry.pid,
                                        name: String(cString: nameBuffer),
                                        cpu: entry.cpu,
                                        wakeups: entry.wakeups,
                                        score: entry.score))
        }
        return rows.isEmpty ? nil : Reading(top: rows)
    }

    /// Drop the baselines when the panel closes.
    ///
    /// Keeping them would mean the first row shown after reopening was a rate
    /// averaged over however long the panel was shut — a minute, an hour —
    /// presented as if it were the last second. One blank tick is the honest
    /// price of a true reading.
    func teardown() {
        previous.removeAll(keepingCapacity: false)
        previousAt = nil
    }
}

/// Drives `EnergyImpactSampler` while — and only while — something is watching.
///
/// Not a `TelemetryModule`: this is a section inside the battery panel rather
/// than a module of its own, so it has no `WidgetKind`, never appears in
/// telemetry settings and can never be pinned to the menu bar. What it shares is the
/// rule the rest of the app is built on — the timer exists only while the view
/// is on screen, and closing the fold destroys it rather than pausing it.
@MainActor
final class EnergyImpactMonitor: ObservableObject {
    @Published private(set) var rows: [EnergyImpactRow] = []

    /// 1 Hz. The panel itself runs at 2 Hz, but a per-second rate resampled
    /// twice a second is mostly noise, and this sweep is the heavier one.
    static let interval: TimeInterval = 1

    private let sampler = EnergyImpactSampler()
    private var timer: DispatchSourceTimer?

    deinit { timer?.cancel() }

    func start() {
        guard timer == nil else { return }
        let sampler = self.sampler
        let timer = DispatchSource.makeTimerSource(queue: Telemetry.queue)
        timer.schedule(deadline: .now(), repeating: Self.interval,
                       leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            autoreleasepool {
                guard let reading = sampler.sample() else { return }
                DispatchQueue.main.async { self?.accept(reading) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        rows = []
        // On the sampling queue: a cancelled timer can still have a tick in
        // flight behind us, and the sampler's contract is one thread only.
        let sampler = self.sampler
        Telemetry.queue.async { sampler.teardown() }
    }

    private func accept(_ reading: EnergyImpactSampler.Reading) {
        if rows != reading.top { rows = reading.top }
    }
}
