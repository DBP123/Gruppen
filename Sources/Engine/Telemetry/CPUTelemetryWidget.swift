import Darwin
import Foundation

/// System-wide processor load, read straight from the Mach kernel.
///
/// This is the reference module: everything else in `SystemWidgets.swift`
/// follows the same shape.
///
/// `host_processor_info` returns each core's *cumulative* tick counters, so a
/// load figure is a difference between two readings — which is why the sampler,
/// not the widget, owns the previous set, and why the first tick after a cold
/// start reports nothing. Ticks are `natural_t` and wrap, so every subtraction
/// here is the wrapping kind.
final class CPUSampler: TelemetrySampler {
    struct Reading: Equatable {
        /// Fractions of the interval, 0…1, across all cores.
        var user: Double
        var system: Double
        /// Busy fraction per core, in the kernel's own core order.
        var cores: [Double]
        /// Mean busy fraction of the performance cluster, and of the efficiency
        /// cluster. Nil on a machine whose device tree does not split them.
        var performance: Double?
        var efficiency: Double?

        var busy: Double { min(user + system, 1) }
        var coreCount: Int { cores.count }

        static let empty = Reading(user: 0, system: 0, cores: [])
    }

    /// user, system, idle, nice — the four states we read, per core.
    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previous: [Ticks] = []

    func sample() -> Reading? {
        guard let current = Self.read() else { return nil }
        defer { previous = current }
        // First tick after the module was created: a baseline, nothing to report.
        // Same if the machine's core count changed under us, which is not a
        // thing an Apple Silicon Mac does but is cheap to be right about.
        guard previous.count == current.count, !current.isEmpty else { return nil }

        var userTicks = 0.0, systemTicks = 0.0, allTicks = 0.0
        var cores: [Double] = []
        cores.reserveCapacity(current.count)

        for (old, new) in zip(previous, current) {
            let user = Double(new.user &- old.user)
            let system = Double(new.system &- old.system)
            let idle = Double(new.idle &- old.idle)
            let nice = Double(new.nice &- old.nice)
            let total = user + system + idle + nice
            // Nice time is user time that was politely scheduled; a load figure
            // that dropped it would under-report anything running at low
            // priority, which is most background work.
            userTicks += user + nice
            systemTicks += system
            allTicks += total
            cores.append(total > 0 ? (user + system + nice) / total : 0)
        }

        // No elapsed ticks at all means two reads landed inside the same tick.
        guard allTicks > 0 else { return nil }

        // The kernel numbers cores but does not say which cluster they are in.
        // The device tree does, and a Mac's layout does not change while it is
        // running, so the map is read once and used here for free.
        let layout = AppleSiliconTelemetry.coreLayout
        var performance: [Double] = [], efficiency: [Double] = []
        if layout.count == cores.count {
            for (index, load) in cores.enumerated() {
                layout[index] == .performance ? performance.append(load) : efficiency.append(load)
            }
        }
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        return Reading(user: userTicks / allTicks,
                       system: systemTicks / allTicks,
                       cores: cores,
                       performance: mean(performance),
                       efficiency: mean(efficiency))
    }

    private static func read() -> [Ticks]? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        // The kernel hands back a vm_allocate'd buffer that is ours to release.
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }

        var ticks: [Ticks] = []
        ticks.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let base = core * Int(CPU_STATE_MAX)
            ticks.append(Ticks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                               system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                               idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                               nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return ticks
    }

    /// Marketing name of the chip, read once. Pure `sysctlbyname` — the C
    /// function, not the shell tool.
    static let brand: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "Processor"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "Processor"
        }
        return String(cString: buffer)
    }()
}

@MainActor
final class CPUTelemetryWidget: TelemetryModule<CPUSampler> {
    init() { super.init(kind: .cpu, sampler: CPUSampler()) }

    override func historyValue(for reading: CPUSampler.Reading) -> Double? { reading.busy }

    override var pinnedSummary: String? {
        reading.map { String(format: "CPU %.0f%%", $0.busy * 100) }
    }
}
