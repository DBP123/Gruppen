import AppKit
import Foundation

func sectionAppPower() async {
    T.begin("I. Power by application — the model")

    let cores = ProcessInfo.processInfo.processorCount
    let idle = AppPowerSampler.modelledPackage(busyCores: 0)
    let flat = AppPowerSampler.modelledPackage(busyCores: Double(cores))
    let unknown = AppPowerSampler.modelledPackage(busyCores: nil)

    T.note("this Mac reports \(cores) logical cores")
    T.check("an idle machine is modelled at a floor, not at zero", idle > 0,
            String(format: "%.2f W", idle))
    T.check("a saturated machine is modelled inside the stated 15–30 W envelope",
            flat >= 15 && flat <= 30, String(format: "%.2f W", flat))
    T.check("busier is never cheaper", flat > idle,
            String(format: "%.2f W → %.2f W", idle, flat))
    T.equal("an unknown load returns the floor rather than inventing one",
            unknown, idle)
    T.check("over-saturation is clamped rather than extrapolated",
            AppPowerSampler.modelledPackage(busyCores: Double(cores) * 10) == flat)
    T.check("a negative load cannot drag the model below its floor",
            AppPowerSampler.modelledPackage(busyCores: -5) == idle)

    T.begin("I. Power by application — whose process is it")

    // A roster of two apps, and a parent table that hangs helpers off them.
    let roster = AppPowerSampler.Roster(
        apps: [.init(pid: 100, name: "Editor", bundleID: "com.x.editor"),
               .init(pid: 200, name: "Browser", bundleID: "com.x.browser")],
        index: [100: 0, 200: 1])
    // 101 is a child of the editor; 301 is a grandchild of the browser;
    // 400 hangs off launchd, the way an XPC service does; 500 points at itself.
    let parents: [pid_t: pid_t] = [101: 100, 300: 200, 301: 300, 400: 1, 500: 500]

    func owner(_ pid: pid_t) -> Int? {
        AppPowerSampler.owner(of: pid, roster: roster, parents: parents)
    }

    T.equal("an application owns itself", owner(100), 0)
    T.equal("a forked helper is billed to its app", owner(101), 0)
    T.equal("so is a grandchild", owner(301), 1)
    T.check("a process under launchd belongs to nobody — this is the "
            + "WebContent case, and it lands in the remainder line",
            owner(400) == nil)
    T.check("a pid that is its own parent terminates instead of looping",
            owner(500) == nil)
    T.check("an unknown pid with no parent belongs to nobody", owner(999) == nil)
    T.check("launchd itself is never an owner", owner(1) == nil)

    T.begin("I. Power by application — the kernel answers")

    let mine = getpid()
    let myParent = AppPowerSampler.parent(of: mine)
    T.check("this process has a parent the kernel will name", myParent != nil,
            myParent.map { "ppid \($0)" } ?? "refused")
    T.check("and it is not itself", myParent != mine)
    T.check("pid 1 is its own ancestor, which is why the walk stops there",
            AppPowerSampler.parent(of: 1) == 1 || AppPowerSampler.parent(of: 1) == nil,
            AppPowerSampler.parent(of: 1).map(String.init) ?? "refused")
    T.check("a pid that cannot exist is refused rather than guessed",
            AppPowerSampler.parent(of: 0x7FFF_FFFE) == nil)

    T.begin("I. Power by application — a live sweep on this machine")

    // The real thing, on the real machine, through the real sampler. Two passes
    // with an interval between them, because the first only lays a baseline.
    let sampler = AppPowerSampler()
    let roster2 = await MainActor.run { AppPowerSampler.Roster.current() }
    T.check("the application roster is not empty", !roster2.apps.isEmpty,
            "\(roster2.apps.count) running applications")
    T.check("every rostered pid is positive", roster2.apps.allSatisfy { $0.pid > 0 })
    T.equal("the index agrees with the roster", roster2.index.count, roster2.apps.count)

    sampler.updateRoster(roster2)
    // updateRoster hops onto the telemetry queue; sync on the same queue so the
    // roster has certainly landed before the first sample reads it.
    Telemetry.queue.sync {}

    let first = sampler.sample()
    T.check("the first pass reports nothing — a rate needs two samples",
            first == nil)

    try? await Task.sleep(nanoseconds: 1_600_000_000)
    guard let reading = sampler.sample() else {
        T.check("the second pass produces a reading", false,
                "nil — no package figure, or a machine that did nothing at all")
        sampler.teardown()
        return
    }
    T.check("the second pass produces a reading", true,
            String(format: "%d rows, %.2f W package, basis %@",
                   reading.rows.count, reading.packageWatts, reading.basis.label))

    T.check("the package draw is positive", reading.packageWatts > 0,
            String(format: "%.2f W", reading.packageWatts))
    T.check("no application is reported drawing negative power",
            reading.rows.allSatisfy { $0.watts >= 0 })
    T.check("no application is reported drawing negative CPU",
            reading.rows.allSatisfy { $0.cpu >= 0 })

    // The load-bearing invariant. Attributing the whole package across the
    // listed applications is the mistake this arithmetic exists to avoid, so the
    // shares must come to less than the whole — with a cent of slack for the
    // floating-point sum.
    T.check("the applications never add up to more than the machine",
            reading.attributedWatts <= reading.packageWatts + 0.01,
            String(format: "%.2f W attributed of %.2f W",
                   reading.attributedWatts, reading.packageWatts))
    T.check("and the remainder is never negative",
            reading.systemWatts >= 0, String(format: "%.2f W", reading.systemWatts))
    T.check("the rows sum to no more than the attributed total",
            reading.rows.reduce(0) { $0 + $1.watts } <= reading.attributedWatts + 0.01)
    T.check("rows come back heaviest first",
            zip(reading.rows, reading.rows.dropFirst()).allSatisfy { $0.watts >= $1.watts })
    T.check("no more rows than the fold shows",
            reading.rows.count <= AppPowerSampler.rowCount)
    T.check("every row is above the display floor",
            reading.rows.allSatisfy { $0.watts >= AppPowerSampler.floorWatts })
    T.check("every row accounts for at least one process",
            reading.rows.allSatisfy { $0.processCount >= 1 })
    T.check("every row names something", reading.rows.allSatisfy { !$0.name.isEmpty })

    for row in reading.rows.prefix(4) {
        T.note(String(format: "%@ — %.2f W, %.0f%% CPU, %d process(es)",
                      row.name, row.watts, row.cpu * 100, row.processCount))
    }

    // The SMC reference count: this sampler has to hold its own connection or
    // the package figure silently falls back to the slow one. That was the
    // `PowerSampler` bug, and it is checked here rather than assumed.
    T.check("a live sweep reads the package off a measured instrument on this Mac",
            reading.basis.isMeasured,
            "basis \(reading.basis.label)")

    sampler.teardown()
    Telemetry.queue.sync {}
    let afterTeardown = sampler.sample()
    T.check("teardown drops the baselines, so the next pass measures afresh "
            + "rather than averaging over however long the fold was shut",
            afterTeardown == nil)
    sampler.teardown()
}
