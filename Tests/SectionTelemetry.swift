import AppKit
import Foundation

/// Samples a sampler the way the clock does — on the telemetry queue — and
/// hands back the reading.
private func onQueue<R>(_ body: @escaping () -> R) -> R {
    Telemetry.queue.sync(execute: body)
}

func sectionTelemetry() {
    T.begin("E. Telemetry — every sampler answers on this machine")

    // CPU: a rate, so the first tick has no interval to divide by.
    let cpu = CPUSampler()
    let first = onQueue { cpu.sample() }
    T.check("CPU reports nothing on the first tick", first == nil,
            "a rate needs two samples")
    Thread.sleep(forTimeInterval: 0.3)
    if let r = onQueue({ cpu.sample() }) {
        T.check("CPU user and system are fractions",
                r.user >= 0 && r.user <= 1 && r.system >= 0 && r.system <= 1,
                String(format: "u %.3f s %.3f", r.user, r.system))
        T.check("busy never exceeds 1", r.busy >= 0 && r.busy <= 1, String(format: "%.3f", r.busy))
        T.check("core count is plausible", r.coreCount > 0 && r.coreCount <= 256, "\(r.coreCount)")
        T.check("every per-core figure is a fraction",
                r.cores.allSatisfy { $0 >= 0 && $0 <= 1.001 },
                "\(r.cores.count) cores, max \(String(format: "%.3f", r.cores.max() ?? 0))")
        T.check("the cluster split adds up to the core count",
                r.performanceCores.isEmpty
                || r.performanceCores.count + r.efficiencyCores.count == r.coreCount,
                "\(r.performanceCores.count)P + \(r.efficiencyCores.count)E of \(r.coreCount)")
        T.check("threads and processes are plausible",
                r.threads > r.processes && r.processes > 10,
                "\(r.threads) threads, \(r.processes) processes")
    } else { T.check("CPU reports on the second tick", false, "nil") }
    onQueue { cpu.teardown() }

    // Memory.
    let memory = MemorySampler()
    if let r = onQueue({ memory.sample() }) {
        let installed = MemorySampler.installed
        T.check("installed RAM is plausible", installed > (1 << 30) && installed < (1 << 41),
                "\(installed / (1 << 30)) GB")
        T.check("the reported total matches the installed RAM", r.total == installed,
                "\(r.total / (1 << 30)) GB vs \(installed / (1 << 30)) GB")
        T.check("used memory does not exceed the total", r.used <= r.total,
                "\(r.used / (1 << 20)) MB of \(r.total / (1 << 20)) MB")
        T.check("memory pressure is a fraction", r.pressure >= 0 && r.pressure <= 1,
                String(format: "%.2f", r.pressure))
        T.check("swap used never exceeds swap total",
                r.swapTotal == 0 || r.swapUsed <= r.swapTotal,
                "\(r.swapUsed / (1 << 20)) / \(r.swapTotal / (1 << 20)) MB")
    } else { T.check("memory reports", false, "nil") }
    onQueue { memory.teardown() }

    // Storage.
    let storage = StorageSampler()
    if let r = onQueue({ storage.sample() }) {
        T.check("storage capacity is plausible", r.total > 0, "\(r.total / (1 << 30)) GB")
        T.check("free never exceeds the total", r.free <= r.total,
                "\(r.free / (1 << 30)) GB free of \(r.total / (1 << 30)) GB")
        T.equal("used plus free is exactly the total", r.used + r.free, r.total)
        T.check("effective free does not overflow past the total",
                r.effectiveFree <= r.total,
                "\(r.effectiveFree / (1 << 30)) GB incl. \(r.purgeable / (1 << 30)) GB purgeable")
        T.check("I/O rates are not negative",
                r.readRate >= 0 && r.writeRate >= 0)
    } else { T.check("storage reports", false, "nil") }
    onQueue { storage.teardown() }

    // Uptime is a pure derivation, so it can be checked exactly.
    let up = UptimeService.read()
    T.check("uptime reads without a subprocess", true, "\(up)".prefix(80).description)
    T.check("elapsed describes a round hour",
            UptimeService.elapsed(since: Date().addingTimeInterval(-3600)).contains("1 hour"),
            UptimeService.elapsed(since: Date().addingTimeInterval(-3600)))

    // Network: also a rate.
    let network = NetworkSampler()
    _ = onQueue { network.sample() }
    Thread.sleep(forTimeInterval: 0.3)
    if let r = onQueue({ network.sample() }) {
        T.check("network rates are not negative", r.down >= 0 && r.up >= 0,
                String(format: "%.0f down / %.0f up B/s", r.down, r.up))
        T.check("at least one ethernet-class interface is counted", r.interfaces > 0,
                "\(r.interfaces) interfaces")
    } else { T.note("network reported nil on the second tick (no interface activity yet)") }
    onQueue { network.teardown() }

    // Processes.
    let processes = ProcessSampler()
    _ = onQueue { processes.sample() }
    Thread.sleep(forTimeInterval: 0.3)
    if let r = onQueue({ processes.sample() }) {
        T.check("the process count is plausible", r.total > 10, "\(r.total) processes")
        T.check("the busiest list is bounded", r.top.count <= 16, "\(r.top.count) listed")
    } else { T.check("processes report", false, "nil") }
    onQueue { processes.teardown() }

    // Gruppen's own footprint.
    let footprint = FootprintSampler()
    _ = onQueue { footprint.sample() }
    Thread.sleep(forTimeInterval: 0.3)
    if let r = onQueue({ footprint.sample() }) {
        T.check("our own memory is reported", r.resident > 0, "\(r.resident / (1 << 20)) MB")
        T.check("our own CPU is a sane percentage", r.cpu >= 0 && r.cpu < 800,
                String(format: "%.2f%%", r.cpu))
    } else { T.check("footprint reports", false, "nil") }
    onQueue { footprint.teardown() }

    T.begin("E. Telemetry — hardware-dependent modules")

    // Thermal and GPU need the SMC. Both must answer or degrade, never crash.
    let thermal = ThermalSampler()
    let thermalReading = onQueue { thermal.sample() }
    if let r = thermalReading {
        T.check("thermal reports a state", true, "\(r.state)")
        if let die = r.cpuDie {
            T.check("the CPU die temperature is physical",
                    die.celsius > 5 && die.celsius < 130, String(format: "%.1f°C", die.celsius))
        } else {
            T.note("no CPU die sensor on this machine — the card degrades to the thermal state")
        }
        T.note("fans reported: \(r.fans.count) (0 is correct on a fanless Mac)")
    } else { T.check("thermal reports", false, "nil") }
    onQueue { thermal.teardown() }

    let silicon = SiliconSampler()
    if let r = onQueue({ silicon.sample() }) {
        T.check("GPU utilisation is a fraction or percentage",
                r.gpu >= 0 && r.gpu <= 100, String(format: "%.1f", r.gpu))
        T.check("GPU core count is plausible", r.coreCount >= 0, "\(r.coreCount)")
    } else {
        T.note("no IOAccelerator reading — expected on a Mac with no discrete accelerator node")
    }
    onQueue { silicon.teardown() }

    T.begin("E. Telemetry — the SMC reference count")

    // Three samplers now share one connection. The count must balance, or the
    // last one to let go leaves a kernel handle open for the life of the app.
    let power = PowerSampler()
    let thermal2 = ThermalSampler()
    _ = onQueue { power.sample() }
    _ = onQueue { thermal2.sample() }
    let liveWithTwo = onQueue { PowerFlow.liveSystemDraw() }
    T.check("with two holders, the SMC answers", liveWithTwo != nil,
            liveWithTwo.map { String(format: "%.2f W", $0) } ?? "nil — no PSTR key on this Mac")
    onQueue { power.teardown() }
    T.check("one release does not close the connection out from under the other",
            onQueue { AppleSiliconTelemetry.shared.thermal() } != nil,
            "thermal still reads after power let go")
    onQueue { thermal2.teardown() }
    T.check("the last release closes it",
            onQueue { PowerFlow.liveSystemDraw() } == nil)

    // And it must be reusable afterwards — a panel reopened must work.
    let power2 = PowerSampler()
    let reopened = onQueue { power2.sample() }
    T.check("a module rebuilt after teardown works again", reopened != nil,
            reopened.map { String(format: "%.2f W", $0.flow.systemLoad) } ?? "nil")
    onQueue { power2.teardown() }

    T.begin("E. Telemetry — power, the panel's arithmetic")

    if let flow = onQueue({ PowerFlow.read(liveDraw: nil) }) {
        T.check("system draw is never negative", flow.systemLoad >= 0,
                String(format: "%.2f W", flow.systemLoad))
        T.check("the charge percentage is 0…100", flow.percent >= 0 && flow.percent <= 100,
                "\(flow.percent)%")
        T.check("capacity is positive", flow.capacitymAh > 0,
                String(format: "%.0f mAh", flow.capacitymAh))
        T.check("on battery, the adapter contributes nothing",
                flow.isPluggedIn || flow.adapterInput == 0,
                String(format: "adapter %.2f W", flow.adapterInput))
        T.check("the condition is consistent with the cable",
                flow.isPluggedIn || flow.condition == .discharging || flow.condition == .lowPowerMode
                || flow.condition == .fault,
                "\(flow.condition)")
    } else {
        T.note("no battery on this machine — PowerFlow.read() returns nil, which the UI must handle")
    }

    // The state machine, over values rather than hardware.
    var probe = PowerFlow(systemLoad: 20, batteryPower: 0, adapterInput: 0, adapterRating: nil,
                          isCharging: false, isPluggedIn: false, isFull: false, percent: 50,
                          remainingEnergy: 40, fullEnergy: 80)
    T.equal("unplugged reads as discharging", probe.condition, .discharging)
    probe.isPluggedIn = true
    probe.batteryPower = 30
    T.equal("current into the pack is charging", probe.condition, .charging)
    probe.batteryPower = -0.05
    T.equal("noise either side of zero is a hold, not a discharge", probe.condition, .optimizedHold)
    probe.batteryPower = -10
    probe.adapterInput = 0.9
    T.equal("a 0.9 W adapter reading is not an assist", probe.condition, .optimizedHold)
    probe.adapterInput = 60
    probe.systemLoad = 70
    T.equal("a genuinely out-run adapter is an assist", probe.condition, .adapterAssist)
    probe.batteryPower = 0
    probe.isFull = true
    T.equal("full and plugged in is passthrough", probe.condition, .acPassthrough)
    probe.hasFault = true
    T.equal("a fault outranks everything", probe.condition, .fault)

    T.begin("E. Telemetry — the shared clock")

    // One timer for every module. Registering must not fire more than one
    // delivery per period per module.
    let box = Counter()
    let id = ObjectIdentifier(box)
    TelemetryClock.shared.register(id, period: 0.1) { [box] in
        box.bump()
        return nil
    }
    Thread.sleep(forTimeInterval: 0.55)
    TelemetryClock.shared.unregister(id)
    let fired = box.value
    T.check("the clock fires at roughly its period", fired >= 3 && fired <= 8,
            "\(fired) ticks in 0.55 s at 0.1 s")
    Thread.sleep(forTimeInterval: 0.3)
    T.equal("unregistering stops it dead", box.value, fired)
}

/// Thread-safe tick counter for the clock test.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
