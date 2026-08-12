import Darwin
import Foundation
import IOKit.ps

// Every sampler below follows `CPUSampler`: pure C and Mach entry points, no
// subprocess anywhere, and any counter a rate needs is held by the sampler and
// touched only on `Telemetry.queue`.

// MARK: - Memory

/// Physical memory, the way Activity Monitor breaks it down.
///
/// `host_statistics64` reports pages, not bytes, so everything is multiplied by
/// the host page size (16 KB on Apple Silicon, not the 4 KB people assume).
final class MemorySampler: TelemetrySampler {
    struct Reading: Equatable {
        var total: UInt64
        /// Kernel memory that can never be paged out.
        var wired: UInt64
        /// What applications are actually holding.
        var app: UInt64
        var compressed: UInt64
        /// File-backed pages the kernel is keeping around; reclaimable.
        var cached: UInt64
        var swapUsed: UInt64

        var used: UInt64 { wired &+ app &+ compressed }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
        /// Apple's own approximation of memory pressure: the part of RAM that
        /// cannot simply be handed back.
        var pressure: Double { total > 0 ? Double(wired &+ compressed) / Double(total) : 0 }
    }

    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS else { return 4096 }
        return UInt64(size)
    }()

    static let installed: UInt64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }()

    func sample() -> Reading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Self.pageSize
        // Anonymous pages minus the ones marked throwaway: this is the figure
        // Activity Monitor calls "App Memory".
        let anonymous = UInt64(stats.internal_page_count) &- min(UInt64(stats.purgeable_count),
                                                                UInt64(stats.internal_page_count))
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        return Reading(total: Self.installed,
                       wired: UInt64(stats.wire_count) &* page,
                       app: anonymous &* page,
                       compressed: UInt64(stats.compressor_page_count) &* page,
                       cached: (UInt64(stats.external_page_count) &+ UInt64(stats.purgeable_count)) &* page,
                       swapUsed: swapUsed)
    }
}

@MainActor
final class MemoryTelemetryWidget: TelemetryModule<MemorySampler> {
    init() { super.init(kind: .memory, sampler: MemorySampler()) }

    override func historyValue(for reading: MemorySampler.Reading) -> Double? { reading.usedFraction }

    override var pinnedSummary: String? {
        reading.map { "MEM \(Format.bytes($0.used))" }
    }
}

// MARK: - Network

/// Throughput across the machine's interfaces.
///
/// The counters come from the routing table (`NET_RT_IFLIST2`) rather than
/// `getifaddrs`, because that is the only one of the two that carries 64-bit
/// byte counts — the `getifaddrs` version wraps every 4 GB and would report
/// nonsense on any machine that has been up a while.
final class NetworkSampler: TelemetrySampler {
    struct Reading: Equatable {
        /// Bytes per second.
        var down: Double
        var up: Double
        var downTotal: UInt64
        var upTotal: UInt64
        var interfaces: Int
    }

    /// `IFT_ETHER`. Wired and wireless links both report as this; tunnels,
    /// bridges and loopback do not, which is exactly what should be left out —
    /// a VPN's bytes are already counted on the interface carrying them.
    private static let ethernet: UInt8 = 0x06

    private var previous: (down: UInt64, up: UInt64, at: Date)?

    func sample() -> Reading? {
        guard let (down, up, interfaces) = Self.counters() else { return nil }
        let now = Date()
        defer { previous = (down, up, now) }
        guard let previous else { return nil }

        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0.05 else { return nil }
        // An interface disappearing takes its counters with it, so a total can
        // legitimately go backwards. Report nothing rather than a negative rate.
        let downDelta = down >= previous.down ? down - previous.down : 0
        let upDelta = up >= previous.up ? up - previous.up : 0

        return Reading(down: Double(downDelta) / elapsed,
                       up: Double(upDelta) / elapsed,
                       downTotal: down,
                       upTotal: up,
                       interfaces: interfaces)
    }

    private static func counters() -> (UInt64, UInt64, Int)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var down: UInt64 = 0, up: UInt64 = 0, interfaces = 0
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            // The buffer is a run of variable-length messages. Each one starts
            // with the same header, so read that first to find the length and
            // the type, and only widen to `if_msghdr2` for the ones that are it.
            while offset + MemoryLayout<if_msghdr>.size <= length {
                var head = if_msghdr()
                memcpy(&head, base + offset, MemoryLayout<if_msghdr>.size)
                let messageLength = Int(head.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }

                if Int32(head.ifm_type) == RTM_IFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    var message = if_msghdr2()
                    memcpy(&message, base + offset, MemoryLayout<if_msghdr2>.size)
                    let data = message.ifm_data
                    // Up, physical, and has actually carried something. A Mac
                    // reports a dozen `en*` and `anpi*` links that exist for
                    // internal plumbing and have never moved a byte; counting
                    // those makes the interface figure meaningless.
                    if data.ifi_type == ethernet, message.ifm_flags & Int32(IFF_UP) != 0,
                       data.ifi_ibytes > 0 || data.ifi_obytes > 0 {
                        down &+= data.ifi_ibytes
                        up &+= data.ifi_obytes
                        interfaces += 1
                    }
                }
                offset += messageLength
            }
        }
        return (down, up, interfaces)
    }
}

@MainActor
final class NetworkTelemetryWidget: TelemetryModule<NetworkSampler> {
    /// The upload series. The base class keeps one history; this module plots
    /// two, so it carries the second itself.
    @Published private(set) var upHistory: [Double] = []

    init() { super.init(kind: .network, sampler: NetworkSampler()) }

    override func historyValue(for reading: NetworkSampler.Reading) -> Double? { reading.down }

    override func didAccept(_ reading: NetworkSampler.Reading) {
        upHistory.append(reading.up)
        if upHistory.count > Telemetry.historyLength {
            upHistory.removeFirst(upHistory.count - Telemetry.historyLength)
        }
    }

    override var pinnedSummary: String? {
        reading.map { "↓\(Format.rate($0.down)) ↑\(Format.rate($0.up))" }
    }
}

// MARK: - Thermal and power

/// Thermal pressure and the power source.
///
/// macOS publishes no die temperature or fan speed through any public
/// interface — every app that shows those talks to the SMC through a private
/// one. What the system does tell you is its *thermal pressure*: whether it is
/// currently throttling to keep cool. That is the number that actually predicts
/// whether your machine is about to slow down, so it is the one shown here.
final class ThermalSampler: TelemetrySampler {
    struct Reading: Equatable {
        var state: ProcessInfo.ThermalState
        var isLowPower: Bool
        /// Nil on a machine with no battery.
        var batteryPercent: Int?
        var isCharging: Bool
        var onExternalPower: Bool
        var minutesRemaining: Int?
        /// Degrees Celsius off the SMC, hottest sensor in each cluster.
        var performanceCores: Double?
        var efficiencyCores: Double?
        var graphics: Double?
        /// Watts drawn by the whole machine.
        var systemPower: Double?
        var fans: [Double] = []

        var stateLabel: String {
            switch state {
            case .nominal: return "NOMINAL"
            case .fair: return "FAIR"
            case .serious: return "SERIOUS"
            case .critical: return "CRITICAL"
            @unknown default: return "UNKNOWN"
            }
        }

        /// The figure a reader actually wants: the hottest cluster on the die.
        var hottest: Double? {
            [performanceCores, efficiencyCores, graphics].compactMap { $0 }.max()
        }

        /// 0…1, for the segmented gauge.
        var severity: Double {
            switch state {
            case .nominal: return 0.25
            case .fair: return 0.5
            case .serious: return 0.75
            case .critical: return 1
            @unknown default: return 0
            }
        }
    }

    /// The SMC is opened on the first sample rather than at init, so a module
    /// that is created and never started never touches the hardware.
    private var hardware = false

    func teardown() {
        guard hardware else { return }
        hardware = false
        AppleSiliconTelemetry.shared.release()
    }

    /// A safety net. `stopFetching` always tears a sampler down, but one that is
    /// dropped without it would hold the SMC connection open for the life of
    /// the process. The release goes back to the sampling queue, because that
    /// serial queue is what makes the reference count safe.
    deinit {
        guard hardware else { return }
        Telemetry.queue.async { AppleSiliconTelemetry.shared.release() }
    }

    func sample() -> Reading? {
        let process = ProcessInfo.processInfo
        var reading = Reading(state: process.thermalState,
                              isLowPower: process.isLowPowerModeEnabled,
                              batteryPercent: nil,
                              isCharging: false,
                              onExternalPower: true,
                              minutesRemaining: nil)

        if !hardware {
            hardware = true
            AppleSiliconTelemetry.shared.acquire()
        }
        if let zones = AppleSiliconTelemetry.shared.thermal() {
            reading.performanceCores = zones.performanceCores
            reading.efficiencyCores = zones.efficiencyCores
            reading.graphics = zones.graphics
            reading.systemPower = zones.systemPower
            reading.fans = zones.fans
        }

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return reading }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            reading.batteryPercent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : nil
            reading.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            reading.onExternalPower = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            // -1 means "still working it out", which is not worth showing.
            let key = reading.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let minutes = description[key] as? Int, minutes > 0 { reading.minutesRemaining = minutes }
            break
        }
        return reading
    }
}

@MainActor
final class ThermalTelemetryWidget: TelemetryModule<ThermalSampler> {
    init() { super.init(kind: .thermal, sampler: ThermalSampler()) }

    override func historyValue(for reading: ThermalSampler.Reading) -> Double? {
        reading.performanceCores
    }

    /// A die temperature is the thing worth two centimetres of menu bar; the
    /// pressure state is the fallback on a machine with no readable sensors.
    override var pinnedSummary: String? {
        guard let reading else { return nil }
        if let hottest = reading.hottest { return String(format: "%.0f°C", hottest) }
        if let percent = reading.batteryPercent { return "\(reading.stateLabel) \(percent)%" }
        return reading.stateLabel
    }
}

// MARK: - Graphics and the fixed-function engines

/// The GPU, the Neural Engine and the media engines.
///
/// Utilisation for the GPU is exact — the accelerator publishes it. The Neural
/// Engine and the video and image codecs publish a *power state* instead, so
/// that is what this reports: awake or asleep, not a percentage. The load
/// figures other tools show for those come out of IOReport, which has no public
/// header, and a made-up percentage is worse than an honest binary.
final class SiliconSampler: TelemetrySampler {
    struct Reading: Equatable {
        var gpu: Double
        var renderer: Double
        var tiler: Double
        var gpuMemory: UInt64
        var neuralEngine: AppleSiliconTelemetry.EngineState?
        var videoEngine: AppleSiliconTelemetry.EngineState?
        var imageEngine: AppleSiliconTelemetry.EngineState?
    }

    private var hardware = false

    func teardown() {
        guard hardware else { return }
        hardware = false
        AppleSiliconTelemetry.shared.release()
    }

    /// A safety net. `stopFetching` always tears a sampler down, but one that is
    /// dropped without it would hold the SMC connection open for the life of
    /// the process. The release goes back to the sampling queue, because that
    /// serial queue is what makes the reference count safe.
    deinit {
        guard hardware else { return }
        Telemetry.queue.async { AppleSiliconTelemetry.shared.release() }
    }

    func sample() -> Reading? {
        if !hardware {
            hardware = true
            AppleSiliconTelemetry.shared.acquire()
        }
        let silicon = AppleSiliconTelemetry.shared
        guard let graphics = silicon.graphics() else { return nil }
        return Reading(gpu: graphics.utilization,
                       renderer: graphics.rendererUtilization,
                       tiler: graphics.tilerUtilization,
                       gpuMemory: graphics.memoryInUse,
                       neuralEngine: silicon.neuralEngineState(),
                       videoEngine: silicon.videoEngineState(),
                       imageEngine: silicon.imageEngineState())
    }
}

@MainActor
final class SiliconTelemetryWidget: TelemetryModule<SiliconSampler> {
    init() { super.init(kind: .silicon, sampler: SiliconSampler()) }

    override func historyValue(for reading: SiliconSampler.Reading) -> Double? { reading.gpu }

    override var pinnedSummary: String? {
        reading.map { String(format: "GPU %.0f%%", $0.gpu * 100) }
    }
}

// MARK: - Processes

/// The processes using the most CPU, without asking `ps` or `top`.
///
/// `proc_pid_rusage` gives cumulative CPU nanoseconds per process, so the rate
/// is a difference — the sampler holds the previous pass. A full sweep of ~190
/// processes measures at 0.6 ms, which at the panel's 2 Hz is around a tenth of
/// one percent of one core.
final class ProcessSampler: TelemetrySampler {
    struct Row: Equatable, Identifiable {
        var pid: pid_t
        var name: String
        /// Fraction of *one* core, so this can exceed 1 on a threaded process.
        var cpu: Double
        var footprint: UInt64
        var id: pid_t { pid }
    }

    struct Reading: Equatable {
        var top: [Row]
        var total: Int
    }

    /// How many rows the well shows.
    static let rowCount = 5

    private var previous: [pid_t: Double] = [:]
    private var previousAt: Date?

    func sample() -> Reading? {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        let now = Date()
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        var current: [pid_t: Double] = [:]
        current.reserveCapacity(count)
        var rows: [Row] = []
        rows.reserveCapacity(count)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        var live = 0

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0, let usage = processUsage(of: pid) else { continue }
            live += 1
            let cpuTime = processCPUSeconds(usage)
            current[pid] = cpuTime
            // A process that was not in the previous pass has no rate yet. It
            // will have one next tick; showing it at 0 for one frame beats
            // inventing a figure from its lifetime total.
            guard elapsed > 0.05, let before = previous[pid], cpuTime >= before else { continue }
            guard proc_name(pid, &nameBuffer, 256) > 0 else { continue }
            rows.append(Row(pid: pid,
                            name: String(cString: nameBuffer),
                            cpu: (cpuTime - before) / elapsed,
                            footprint: usage.ri_phys_footprint))
        }

        previous = current
        previousAt = now
        guard !rows.isEmpty else { return nil }

        rows.sort { $0.cpu > $1.cpu }
        return Reading(top: Array(rows.prefix(Self.rowCount)), total: live)
    }
}

/// Cumulative CPU time and memory footprint for a process.
///
/// `proc_pid_rusage` takes the *address of your struct*, retyped — its
/// parameter is `rusage_info_t *`, and `rusage_info_t` is itself `void *`. The
/// obvious Swift spelling (handing it `&pointer` for some local pointer
/// variable) makes the kernel write 296 bytes of struct over an 8-byte stack
/// slot; it returns 0, appears to work, and takes the process down with a
/// stack-guard abort some frames later. Rebinding the memory is what actually
/// matches the C.
///
/// Its time fields are documented as nanoseconds and are not: on Apple Silicon
/// they are mach absolute time units, which here run at 24 MHz — a factor of
/// 125/3. Treating them as nanoseconds reports every process at 1/41.67 of its
/// real load, which looks entirely plausible on a quiet machine and is why this
/// is checked against a process burning a known number of threads.
private func processUsage(of pid: pid_t) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    // Anything owned by another user, or exiting as we look at it, simply
    // refuses; there are always a few.
    return result == 0 ? info : nil
}

/// Total CPU seconds a process has consumed, converted out of mach units.
private func processCPUSeconds(_ usage: rusage_info_v4) -> Double {
    Double(usage.ri_user_time &+ usage.ri_system_time) * machTickSeconds
}

private let machTickSeconds: Double = {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1e-9 }
    return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}()

@MainActor
final class ProcessTelemetryWidget: TelemetryModule<ProcessSampler> {
    init() { super.init(kind: .processes, sampler: ProcessSampler()) }
}

// MARK: - Gruppen's own footprint

/// What this app is costing you.
///
/// The same three figures the old menu bar readout carried, on the same
/// demand-driven footing as everything else. Not hideable: a monitor that will
/// not report on itself is not worth trusting.
final class FootprintSampler: TelemetrySampler {
    struct Reading: Equatable {
        var cpu: Double
        var resident: UInt64
        var threads: Int
    }

    private var previousCPU: Double?
    private var previousAt: Date?

    /// The same `proc_pid_rusage` the process table uses, pointed at ourselves.
    ///
    /// The obvious Mach call here — `TASK_THREAD_TIMES_INFO` — is wrong, and
    /// wrong in a way that looks plausible: it reports the time of *live*
    /// threads only. SwiftUI's dispatch workers come and go constantly, so the
    /// total jumps whenever a thread appears and drops whenever one exits, and
    /// differencing it produced a figure near 18% for an app the process table
    /// in the very same panel was listing at 0.5%. `ri_user_time` is monotonic
    /// and counts threads that have already finished.
    func sample() -> Reading? {
        guard let usage = processUsage(of: getpid()) else { return nil }
        let cpuTime = processCPUSeconds(usage)
        let now = Date()
        defer { previousCPU = cpuTime; previousAt = now }

        // Baseline first, like every other rate here. It also keeps the panel's
        // own construction cost out of the first figure it shows.
        guard let previousCPU, let previousAt, cpuTime >= previousCPU else { return nil }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed > 0.05 else { return nil }
        return Reading(cpu: (cpuTime - previousCPU) / elapsed,
                       resident: usage.ri_phys_footprint,
                       threads: Self.threads())
    }

    private static func threads() -> Int {
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

@MainActor
final class FootprintTelemetryWidget: TelemetryModule<FootprintSampler> {
    init() { super.init(kind: .footprint, sampler: FootprintSampler()) }
}

// MARK: - Formatting

/// One place for the units, so a figure reads the same in the well as it does
/// in the menu bar.
enum Format {
    /// Compact by design. `ByteCountFormatter` renders 3.87 GB in five
    /// characters more than there is room for on a menu bar panel, and calls
    /// zero "Zero KB".
    static func bytes(_ value: UInt64) -> String {
        let units: [(UInt64, String)] = [
            (1 << 40, "TB"), (1 << 30, "GB"), (1 << 20, "MB"), (1 << 10, "KB"),
        ]
        for (scale, suffix) in units where value >= scale {
            let scaled = Double(value) / Double(scale)
            return scaled >= 100
                ? String(format: "%.0f %@", scaled, suffix)
                : String(format: "%.1f %@", scaled, suffix)
        }
        return "\(value) B"
    }

    /// Throughput. Deliberately short — this has to fit in a menu bar.
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < 1_000 { return String(format: "%.0f B/s", value) }
        if value < 1_000_000 { return String(format: "%.0f KB/s", value / 1_000) }
        if value < 1_000_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        return String(format: "%.2f GB/s", value / 1_000_000_000)
    }

    static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", max(fraction, 0) * 100)
    }

    static func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
