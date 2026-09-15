import Foundation

/// One timer for every module, and one main-thread delivery per tick.
///
/// ## Why not a timer per module
///
/// Each module used to own a `DispatchSourceTimer`. Eight modules on the
/// dashboard meant eight timers at 1 Hz with a quarter-second of leeway each —
/// so their ticks landed at eight different moments in every second, and each
/// one delivered its reading to the main thread on its own. SwiftUI treats
/// every one of those deliveries as a separate transaction: a view-graph
/// update, a layout pass over the card, a CoreAnimation commit. Measured on the
/// dashboard, that per-transaction overhead — not the sampling, which is a few
/// milliseconds a second in total — was the majority of the app's CPU.
///
/// With one clock, every module that is due samples in the same pass on the
/// telemetry queue, and their readings go to the main thread in **one** block.
/// SwiftUI coalesces the resulting `@Published` writes into a single
/// transaction, so eight cards update in one render pass instead of eight.
///
/// ## What did not change
///
/// - Modules are still destroyed when nothing wants them: unregistering is the
///   same act as cancelling the old timer, and an empty clock cancels itself.
/// - Each module keeps its own rate. The clock runs at the fastest rate anyone
///   asked for and each entry samples when its own period has elapsed.
/// - Samplers are still touched from exactly one place, the telemetry queue.
///   Registration and removal are dispatched onto it, so the entry table and the
///   samplers share one thread and no lock.
final class TelemetryClock: @unchecked Sendable {
    static let shared = TelemetryClock()

    /// A closure run on the queue that does the sampling, returning the
    /// main-thread work to apply its result — or nil when there is nothing new.
    typealias Tick = () -> (@MainActor () -> Void)?

    private struct Entry {
        let period: TimeInterval
        var due: DispatchTime
        let tick: Tick
    }

    /// Touched only on `Telemetry.queue`.
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var timerPeriod: TimeInterval = 0

    private init() {}

    /// Adds or re-registers a module. Safe to call from any thread; takes
    /// effect on the queue. The first sample runs on the next tick, which is
    /// scheduled immediately if the clock was idle.
    func register(_ id: ObjectIdentifier, period: TimeInterval, tick: @escaping Tick) {
        Telemetry.queue.async { [self] in
            entries[id] = Entry(period: period, due: .now(), tick: tick)
            reschedule()
        }
    }

    func unregister(_ id: ObjectIdentifier) {
        Telemetry.queue.async { [self] in
            entries.removeValue(forKey: id)
            reschedule()
        }
    }

    /// Runs on the queue. Cancels when nothing is registered; otherwise makes
    /// sure the timer runs at the shortest period anyone needs.
    private func reschedule() {
        guard let shortest = entries.values.map(\.period).min() else {
            timer?.cancel()
            timer = nil
            timerPeriod = 0
            return
        }
        guard timer == nil || timerPeriod != shortest else { return }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: Telemetry.queue)
        // A quarter-period of leeway lets the kernel coalesce these ticks with
        // whatever else is waking the machine — most of the difference between
        // a monitor that costs nothing and one that keeps a core awake.
        timer.schedule(deadline: .now(), repeating: shortest,
                       leeway: .milliseconds(Int(shortest * 250)))
        timer.setEventHandler { [weak self] in self?.fire() }
        timer.resume()
        self.timer = timer
        timerPeriod = shortest
    }

    /// One pass: sample everything that is due, then one trip to the main thread.
    private func fire() {
        let now = DispatchTime.now()
        var applies: [@MainActor () -> Void] = []
        // Every sampler allocates — arrays of ticks, process names, CFTypes
        // out of IOKit. One pool around the whole pass drains them together.
        autoreleasepool {
            for (id, var entry) in entries where entry.due <= now {
                entry.due = now + entry.period
                entries[id] = entry
                if let apply = entry.tick() { applies.append(apply) }
            }
        }
        guard !applies.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for apply in applies { apply() }
            }
        }
    }
}
