import SwiftUI

// MARK: - Power and battery
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

// MARK: - Power and battery

/// The battery, and where its power is going.
///
/// Split from thermals so the two draw figures can be named for what they are.
/// They were side by side and unlabelled, which made them look like two attempts
/// at the same measurement: **system draw** is what the hardware is burning,
/// **battery flow** is what is moving into or out of the cell. On a charging
/// machine they are not even the same sign.
struct PowerDetail: View {
    @ObservedObject var widget: PowerTelemetryWidget
    /// Persisted rather than `@State`: the popover is torn down every time it
    /// closes, and a section that forgets it was open is worse than one that
    /// never folded.
    @AppStorage("powerHistoryExpanded") private var showingHistory = false
    @AppStorage("powerEnergyExpanded") private var showingEnergy = false

    var body: some View {
        if let reading = widget.reading {
            let flow = reading.flow
            Well {
                HStack(alignment: .center, spacing: 12) {
                    BatteryGlyph(percent: flow.percent, state: flow.state,
                                 condition: flow.condition,
                                 mode: PowerMode.current(lowPower: reading.isLowPower),
                                 width: 64, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        // The state in words first — a percentage alone does not
                        // distinguish a machine that is charging from one that
                        // is being held short of full on purpose.
                        Text(flow.condition == .discharging
                             ? "\(flow.percent)% Remaining" : flow.condition.title)
                            .font(Theme.sans(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(flow.conditionDetail)
                            .font(Theme.mono(9)).tracking(1)
                            .foregroundStyle(flow.condition == .fault
                                             || (flow.condition == .discharging && flow.percent < 20)
                                             ? Theme.cellLow : Theme.textMuted)
                            .lineLimit(1).fixedSize()
                        if let clock = timing(flow) {
                            Text(clock)
                                .font(Theme.mono(9).monospacedDigit())
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    Spacer()
                }
                Sparkline(values: widget.history, floor: WidgetKind.power.plotFloor,
                          tint: Theme.trace, height: 26).equatable()
            }

            // Where the power is coming from and where it is going, as a tree
            // rather than a list. On the adapter there is one source and two
            // destinations, and the indentation says so: the two children add up
            // to the parent by construction.
            PowerRailTelemetryView(reading: reading)

            Well {
                PowerModeSegmentControl(mode: PowerMode.current(lowPower: reading.isLowPower))
            }

            Well {
                // mAh, not Wh: watt-hours are derived through a voltage that
                // rises as the pack fills, so a "full capacity" in Wh grows by
                // about 13% between empty and full. Milliamp-hours are what the
                // controller actually counts and they do not move.
                StatRow(label: "CHARGE",
                        value: String(format: "%@ / %@ mAh",
                                      Format.count(Int(flow.chargemAh)),
                                      Format.count(Int(flow.capacitymAh))))
                if let cycles = reading.cycleCount {
                    StatRow(label: "CYCLE COUNT", value: "\(cycles)")
                }
                if let health = reading.health {
                    StatRow(label: "BATTERY HEALTH",
                            value: Format.percent(health, decimals: 0),
                            tint: health < 0.8 ? Theme.amber : Theme.trace)
                }
                if let celsius = reading.temperature {
                    StatRow(label: "CELL TEMPERATURE", value: String(format: "%.1f °C", celsius),
                            tint: ThermalDetailTint.heat(celsius))
                }
            }

            // Folded away by default. It is history rather than telemetry —
            // useful when you are asking why the machine woke at 3am, and noise
            // the rest of the time.
            Fold(title: "ENERGY IMPACT", expanded: $showingEnergy) {
                EnergyImpactRows()
            }

            Fold(title: "POWER HISTORY", expanded: $showingHistory) {
                UptimeRows()
            }
        } else {
            Waiting()
        }
    }

    /// Time to full or empty, when there is one worth showing.
    private func timing(_ flow: PowerFlow) -> String? {
        if let minutes = flow.minutesToFull {
            return minutes >= 60 ? "~\(minutes / 60)h \(minutes % 60)m to full" : "~\(minutes)m to full"
        }
        if let minutes = flow.minutesToEmpty {
            return "~\(minutes / 60)h \(minutes % 60)m left"
        }
        return nil
    }

}

/// A battery, drawn rather than borrowed from SF Symbols, so the fill is a real
/// measurement and the colour is a state rather than a tint.
struct BatteryGlyph: View {
    let percent: Int
    let state: PowerFlow.State
    /// The full condition, which is what actually decides the shell, the fill
    /// and the glyph. Defaulted so the menu bar can pass just a percentage.
    var condition: PowerFlow.Condition = .discharging
    /// The power mode still tints the shell in High Power, which is a setting
    /// rather than a battery state.
    var mode: PowerMode = .auto
    var width: CGFloat = 42
    var height: CGFloat = 18

    /// Draw it flat and still: no glow, no fill animation, no charging pulse.
    ///
    /// For the menu bar, where this is 21pt wide, permanently on screen, and
    /// wrapped in a `drawingGroup()` that renders the whole item off-screen
    /// through Metal on every frame. Inside that, the decorations are not
    /// decoration — they are a full offscreen pass plus a gaussian blur, and the
    /// 0.4 s fill animation ran that pass at the display's 120 Hz for 0.4 s
    /// after *every* reading. Measured on a 100 ms trace of the app's own CPU:
    /// mean 3.04% with spikes to 62%, against 0.47% for a plain text item on the
    /// same 2 s tick. Still, it is 0.06%.
    ///
    /// The panel keeps all of it. There the glyph is 64pt, it is on screen only
    /// while you are looking at it, and the glow is what makes it read as a
    /// piece of hardware rather than a progress bar.
    var still: Bool = false

    /// Fill colour.
    ///
    /// One rule, applied in one place, because the colour *is* the reading: a
    /// glance has to answer "how full" and "which way is it flowing" without
    /// anyone parsing a number.
    ///
    /// Cyan means wall power and nothing else. It is never a charge level, so a
    /// cyan cell always means the machine is running off the adapter, whether it
    /// is topping the pack up, holding it at a limit, or sitting full. Every
    /// other state is on battery, and steps down a five-band scale.
    static func tint(_ percent: Int, _ condition: PowerFlow.Condition) -> Color {
        // A pack in trouble is the one thing that outranks the flow direction.
        if condition == .fault { return Theme.cellEmpty }
        // `adapterAssist` is plugged in but *draining* — the charger cannot keep
        // up — so it is deliberately not cyan. It is a battery level, and it
        // should look like one.
        switch condition {
        case .charging, .acPassthrough, .optimizedHold: return Theme.cellWall
        default: return level(percent)
        }
    }

    /// The discharge scale, in the five bands the spec names.
    static func level(_ percent: Int) -> Color {
        switch percent {
        case 51...: return Theme.cellFull      // 100–51
        case 26...50: return Theme.cellHalf     // 50–26
        case 16...25: return Theme.cellWarn     // 25–16
        case 6...15: return Theme.cellCritical  // 15–6
        default: return Theme.cellEmpty         // 5–0
        }
    }

    /// Shell colour. Neutral slate normally; it takes the warning colour when
    /// the state is one you should notice without looking closely.
    private var shell: Color {
        if condition == .fault { return Theme.cellLow }
        if condition == .discharging, percent < 20 { return Theme.cellLow }
        if mode == .high { return Theme.crimson }
        if mode == .low { return Theme.amber }
        return Theme.cellShell
    }

    /// The centre cut-out, matching what macOS shows for the same state.
    private var symbol: String? {
        switch condition {
        case .charging: return "bolt.fill"
        case .adapterAssist: return "powerplug.fill"
        case .acPassthrough: return "powerplug.fill"
        case .optimizedHold: return "pause.fill"
        case .lowPowerMode: return "arrow.down"
        case .fault: return "xmark"
        case .discharging: return mode == .high ? "bolt.fill" : nil
        }
    }

    private var level: CGFloat {
        // A fault has nothing to report, so it draws empty.
        condition == .fault ? 0 : CGFloat(min(max(percent, 0), 100)) / 100
    }

    @State private var pulse = false

    var body: some View {
        let fill = mode == .high ? Theme.crimson : Self.tint(percent, condition)
        let radius = height * 0.27
        HStack(spacing: max(1, width * 0.04)) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.05))

                // 1:1 with the percentage, measured rather than approximated.
                //
                // The track is the shell inset by its wall thickness on each
                // side, so the fill's width is exactly `usable × level` — 50%
                // covers half the track, to the pixel. Two things used to break
                // that: a `max(…, height * 0.3)` floor that drew 2% and 10% the
                // same size, and a `.padding` applied before the `.frame`, which
                // made the frame width include the inset and left the bar short
                // of the end at 100%.
                GeometryReader { geometry in
                    let inset = height * 0.1
                    let usable = max(geometry.size.width - inset * 2, 0)
                    RoundedRectangle(cornerRadius: radius * 0.6, style: .continuous)
                        .fill(fill)
                        .overlay { if mode == .high { HazardStripes() } }
                        .clipShape(RoundedRectangle(cornerRadius: radius * 0.6, style: .continuous))
                        .frame(width: usable * level, height: geometry.size.height - inset * 2)
                        .offset(x: inset, y: inset)
                        .animation(still ? nil : .easeOut(duration: 0.4), value: level)
                }

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(shell, lineWidth: max(1, height * 0.1))

                if let symbol {
                    Image(systemName: symbol)
                        // The glyph is a cut-out: it reads as a hole punched in
                        // the fill, so it takes the housing colour rather than
                        // a colour of its own — except on a fault, where there
                        // is no fill to punch through.
                        .font(.system(size: height * 0.52, weight: .bold))
                        .foregroundStyle(condition == .fault ? Theme.cellLow : Theme.housing)
                        .opacity(condition == .charging && pulse ? 0.5 : 1)
                        .frame(width: width)
                }
            }
            .frame(width: width, height: height)
            .shadow(color: still ? .clear : aura, radius: still ? 0 : (mode == .high ? 12 : 9))

            // Terminal nub, in the shell's colour.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(shell)
                .frame(width: max(1.5, width * 0.06), height: height * 0.36)
        }
        .onAppear { ignite() }
        .onChange(of: condition) { _ in ignite() }
        // A repeating animation in a menu bar item is a repeating offscreen
        // render for as long as the machine is charging.
        .animation(nil, value: still)
    }

    private var aura: Color {
        switch mode {
        case .low: return Theme.amber.opacity(0.15)
        case .high: return Theme.crimson.opacity(0.25)
        case .auto: return condition == .fault ? Theme.cellLow.opacity(0.2) : .clear
        }
    }

    private func ignite() {
        guard !still, condition == .charging else { pulse = false; return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// Diagonal racing stripes for the High Power fill. A `Canvas` rather than a
/// stack of rotated rectangles: one draw pass, no view tree, and it clips to
/// whatever the fill's current width happens to be.
private struct HazardStripes: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 5
            var x = -size.height
            while x < size.width + size.height {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(stripe, with: .color(.black.opacity(0.28)), lineWidth: 2)
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Power mode

/// The three modes macOS offers.
enum PowerMode: String, CaseIterable, Identifiable {
    case low, auto, high

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    var tint: Color {
        switch self {
        case .low: return Theme.amber
        case .auto: return Theme.trace
        case .high: return Theme.crimson
        }
    }

    /// What the system is doing right now.
    ///
    /// Low Power is published by `ProcessInfo`. High Power is not published at
    /// all — no public API reports it — so a machine that is not in Low Power
    /// reads as Automatic, which is right for every Mac except one that has been
    /// put into High Power by hand.
    static func current(lowPower: Bool) -> PowerMode { lowPower ? .low : .auto }
}

/// The mode selector.
///
/// It reports; it does not set. Changing the mode needs root, and a control that
/// looked live while doing nothing would be worse than none — so the segments
/// show which of the three the machine is on, and the row underneath opens the
/// place the setting actually lives.
///
/// Low Power is read from `ProcessInfo`, which is exact and updates when the
/// setting is changed in System Settings. High Power is published nowhere, so it
/// is drawn as unknown rather than asserted to be off.
struct PowerModeSegmentControl: View {
    let mode: PowerMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("POWER MODE")
                    .font(Theme.mono(9, .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(mode == .auto ? "AUTOMATIC" : mode.label)
                    .font(Theme.mono(10, .medium)).tracking(0.5)
                    .foregroundStyle(mode.tint)
            }
            HStack(spacing: 2) {
                ForEach(PowerMode.allCases) { candidate in
                    Segment(mode: candidate,
                            active: candidate == mode,
                            // High Power has no readable state, so it is never
                            // asserted as "off" — it is drawn as unknown.
                            unknown: candidate == .high)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: 0x0F0F13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                    NSWorkspace.shared.open(url)
                }
                MenuBarManager.shared.dismissPanel()
            } label: {
                Text("CHANGE IN SYSTEM SETTINGS  →")
                    .font(Theme.mono(8.5, .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private struct Segment: View {
        let mode: PowerMode
        let active: Bool
        let unknown: Bool

        var body: some View {
            Text(mode.label)
                .font(Theme.mono(9, .semibold)).tracking(0.7)
                .foregroundStyle(active ? mode.tint
                                        : (unknown ? Theme.textMuted.opacity(0.4) : Theme.textMuted))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active ? mode.tint.opacity(0.15) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(active ? mode.tint.opacity(0.45) : .clear, lineWidth: 1)
                )
                .help(unknown ? "macOS publishes no state for High Power Mode" : mode.label)
        }
    }
}

/// The ten processes costing the most energy.
///
/// The monitor is started in `onAppear` and destroyed in `onDisappear`, both of
/// which only fire while the fold is open, so a collapsed section runs no timer
/// and sweeps no processes.
private struct EnergyImpactRows: View {
    @StateObject private var monitor = EnergyImpactMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TableHeader(columns: [("PROCESS", .leading, nil), ("IMPACT", .trailing, 52)])
            if monitor.rows.isEmpty {
                // The first tick has counters but no interval to divide by, so
                // there is genuinely nothing to show for one second.
                Text("Measuring…")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 3)
            } else {
                ForEach(monitor.rows) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(String(format: "%.1f", row.score))
                            .font(Theme.mono(10.5, .medium).monospacedDigit())
                            .foregroundStyle(EnergyTint.of(row.score))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

/// Same gating idea as the thermal and power readouts: the number carries its
/// own verdict, so you do not have to know what counts as a lot.
private enum EnergyTint {
    static func of(_ score: Double) -> Color {
        if score >= 50 { return Theme.cellLow }
        if score >= 15 { return Theme.amber }
        return Theme.textPrimary
    }
}

/// When the machine last booted, slept and woke, and why.
///
/// The snapshot is read in `onAppear`, which only fires when the fold is open,
/// so a collapsed section costs nothing at all. It is never re-read while it is
/// visible and does not need to be: the machine cannot sleep while you are
/// looking at the popover, and the elapsed strings are recomputed against
/// `Date()` on every draw, so the minutes still tick up.
private struct UptimeRows: View {
    @State private var snapshot = UptimeSnapshot.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Since(label: "LAST BOOT", date: snapshot.bootedAt)
            Since(label: "LAST SLEEP", date: snapshot.sleptAt)
            Since(label: "LAST WAKE", date: snapshot.wokeAt)
            StatRow(label: "SLEEP REASON", value: snapshot.sleepReason ?? "—",
                    tint: Theme.textSecondary)
            StatRow(label: "WAKE REASON", value: snapshot.wakeReason ?? "—",
                    tint: Theme.textSecondary)
        }
        .onAppear { snapshot = UptimeService.read() }
    }
}

/// One "how long ago" row. A missing date is a real answer — a Mac that has not
/// slept since it booted has no last sleep — so it shows a dash rather than a
/// zero that would read as "just now".
private struct Since: View {
    let label: String
    let date: Date?

    var body: some View {
        StatRow(label: label,
                value: date.map { UptimeService.elapsed(since: $0) } ?? "—")
    }
}
