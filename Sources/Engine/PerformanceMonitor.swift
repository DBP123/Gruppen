import AppKit
import Darwin
import Foundation

/// Gruppen's own CPU and memory use.
///
/// Reading these costs a `task_info` call and a walk of the thread list, which
/// is cheap but not free — so sampling only runs while the menu bar dropdown is
/// actually on screen. `begin()` when the menu opens, `end()` when it closes;
/// the rest of the time this object does nothing at all, which is what keeps
/// the idle figure at zero.
@MainActor
final class PerformanceMonitor: ObservableObject {
    struct Sample: Equatable {
        var cpuPercent: Double
        var residentBytes: UInt64
        var threadCount: Int

        var cpuDescription: String { String(format: "%.1f%%", cpuPercent) }

        var memoryDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(residentBytes), countStyle: .memory)
        }

        static let zero = Sample(cpuPercent: 0, residentBytes: 0, threadCount: 0)
    }

    @Published private(set) var sample: Sample = .zero

    /// Refresh cadence *while the menu is open only*.
    static let interval: TimeInterval = 1.0
    /// Two readings closer together than this share a result. Diffing cumulative
    /// CPU time over a few milliseconds turns rounding into wild percentages.
    private static let minimumWindow: TimeInterval = 0.2

    private var timer: Timer?
    /// CPU time is cumulative, so a rate needs the previous reading. These
    /// survive `end()`: the baseline is what makes the *first* reading of the
    /// next menu open a real number instead of a placeholder.
    private var lastCPUTime: Double?
    private var lastSampledAt: Date?
    /// Sampling stops itself after this long without a fresh `begin()`.
    ///
    /// SwiftUI builds `MenuBarExtra` content eagerly and does not reliably call
    /// `onDisappear` when the menu closes, so relying on that alone left the
    /// timer running forever. The readout re-arms this while it is visible.
    private static let leaseDuration: TimeInterval = 5
    private var leaseExpiry = Date.distantPast

    private var trackingObserver: NSObjectProtocol?

    /// Seeded at launch so the first thing anyone reads is an average over the
    /// app's whole life, not a placeholder.
    init() {
        lastCPUTime = Self.processCPUSeconds()
        lastSampledAt = Date()

        // A menu opening is an event, not something to watch for. This exists so
        // the sample is refreshed even if SwiftUI never rebuilds the readout —
        // belt and braces alongside the synchronous `reading()`. It fires only
        // when a menu actually opens, so it costs nothing at rest.
        trackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.begin() }
        }
    }

    deinit {
        timer?.invalidate()
        if let trackingObserver { NotificationCenter.default.removeObserver(trackingObserver) }
    }

    /// Starts sampling, or extends the lease if it is already running.
    func begin() {
        leaseExpiry = Date().addingTimeInterval(Self.leaseDuration)
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard Date() < self.leaseExpiry else { self.end(); return }
                self.refresh()
            }
        }
        // .common so it keeps updating while the menu is tracking the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
        leaseExpiry = .distantPast
        // The CPU baseline is deliberately kept. Clearing it meant every reopen
        // started from nothing and had to wait a whole second for a second data
        // point — which never arrived, so the readout sat on its placeholder
        // forever.
    }

    /// A reading taken right now, without publishing anything.
    ///
    /// Safe to call while a view is being built, which matters: a `MenuBarExtra`
    /// menu is a real `NSMenu`, and while it is tracking the mouse SwiftUI does
    /// not reliably run an update pass — so a value that only ever arrives via
    /// `@Published` is a value the open menu never shows. Reading synchronously
    /// as the menu is built means the number on screen is always real, and the
    /// timer below is then a bonus rather than the only source.
    @discardableResult
    func reading() -> Sample {
        let now = Date()
        guard let lastSampledAt, let lastCPUTime,
              now.timeIntervalSince(lastSampledAt) >= Self.minimumWindow
        else {
            // Too soon to measure a rate again: keep the last CPU figure, but
            // memory and threads are instantaneous and always worth refreshing.
            return Sample(cpuPercent: sample.cpuPercent,
                          residentBytes: Self.residentBytes(),
                          threadCount: Self.threadCount())
        }

        let cpuSeconds = Self.processCPUSeconds()
        let elapsed = now.timeIntervalSince(lastSampledAt)
        let percent = max((cpuSeconds - lastCPUTime) / elapsed * 100, 0)

        self.lastCPUTime = cpuSeconds
        self.lastSampledAt = now

        return Sample(cpuPercent: percent,
                      residentBytes: Self.residentBytes(),
                      threadCount: Self.threadCount())
    }

    private func refresh() {
        let next = reading()
        if next != sample { sample = next }
    }

    // MARK: - Mach plumbing

    /// Total CPU seconds burned by this process across all threads.
    private static func processCPUSeconds() -> Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    private static func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // phys_footprint is what Activity Monitor reports as Memory.
        return UInt64(info.phys_footprint)
    }

    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        }
        return Int(count)
    }
}
