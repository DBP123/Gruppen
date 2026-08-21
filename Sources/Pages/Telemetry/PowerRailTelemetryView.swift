import SwiftUI

/// Where the power is coming from and where it is going.
///
/// A source with its destinations indented under it, one value column, and a
/// per-row control for *which* reading of that quantity you want.
///
/// ## Why the columns are fixed rather than pushed apart by a `Spacer`
///
/// Every value is right-aligned inside a fixed-width column, so `0.5 W` and
/// `101.9 W` end on the same pixel and the decimal points line up down the
/// block. A spacer-pushed layout re-aligns on every tick as digits come and go,
/// which on a 1 Hz readout reads as the whole panel twitching.
///
/// ## Why the rows do not add up exactly on the adapter
///
/// Two clocks. `SYSTEM POWER DRAW` is live off the SMC's `PSTR`; `ADAPTER INPUT`
/// and `PACK CHARGE RATE` are the charger controller's own measurements, which
/// it republishes once a minute. Those two agree with each other, and neither
/// agrees instantly with the live draw. The alternative — deriving the adapter
/// from `draw + pack` so it always balanced — was tried and is worse: it netted
/// a live number against a stale one and printed `ADAPTER INPUT 0.0 W` on a
/// machine plugged into a 94 W charger.
struct PowerRailTelemetryView: View {
    let reading: PowerSampler.Reading

    /// Persisted per row. Which reading is useful depends on what you are doing,
    /// and it is not the same answer for both rows.
    @AppStorage("powerRailDrawReadout") private var drawReadout: RailReadout = .live
    @AppStorage("powerRailPackReadout") private var packReadout: RailReadout = .live

    private var flow: PowerFlow { reading.flow }

    var body: some View {
        Well {
            header
            DashedRule()
            if flow.isPluggedIn {
                onAdapter
            } else {
                onBattery
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("POWER RAIL TELEMETRY")
                .font(Theme.mono(9, .semibold)).tracking(0.9)
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(badgeTint).frame(width: 5, height: 5)
                Text(badge)
                    .font(Theme.mono(8.5, .semibold)).tracking(0.7)
                    .foregroundStyle(badgeTint)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(badgeTint.opacity(0.12))
            )
        }
    }

    private var badge: String {
        switch flow.condition {
        case .charging: return "CHARGING"
        case .adapterAssist: return "ASSIST"
        case .acPassthrough: return "AC"
        case .optimizedHold: return "HOLD"
        case .lowPowerMode: return "LOW POWER"
        // "ON BATTERY" rather than "DISCHARGING": it is the state of the
        // machine, and it reads as the counterpart to being on the adapter.
        case .discharging: return "ON BATTERY"
        case .fault: return "FAULT"
        }
    }

    /// The same rule as the cell: wall power is cyan, anything running off the
    /// pack is not.
    private var badgeTint: Color {
        switch flow.condition {
        case .charging, .acPassthrough, .optimizedHold: return Theme.cellWall
        case .adapterAssist, .lowPowerMode, .discharging: return Theme.cellWarn
        case .fault: return Theme.cellEmpty
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var onAdapter: some View {
        // The rating goes in the title rather than trailing the value, so the
        // one column on the right holds nothing but watts.
        RailRow(title: adapterTitle,
                value: flow.adapterInput,
                tint: Theme.cellWall,
                signed: false)

        RailRow(title: "├── SYSTEM POWER DRAW",
                readout: drawReadout,
                modes: RailReadout.drawModes,
                value: reading.draw.value(drawReadout),
                tint: Theme.textPrimary,
                signed: false) { drawReadout = drawReadout.next(in: RailReadout.drawModes) }

        RailRow(title: "└── PACK CHARGE RATE",
                readout: packReadout,
                modes: RailReadout.packModes,
                value: reading.pack.value(packReadout),
                tint: packTint,
                signed: true) { packReadout = packReadout.next(in: RailReadout.packModes) }
    }

    /// On battery there is one number worth showing. The system draw and the
    /// pack's discharge are the same measurement — everything the machine burns
    /// comes out of the cell — so a second row would be the same figure twice
    /// with a minus sign on it.
    @ViewBuilder
    private var onBattery: some View {
        RailRow(title: "NET SYSTEM DRAW",
                readout: drawReadout,
                modes: RailReadout.drawModes,
                value: reading.draw.value(drawReadout),
                tint: Theme.textPrimary,
                signed: false) { drawReadout = drawReadout.next(in: RailReadout.drawModes) }
    }

    private var adapterTitle: String {
        guard let rating = flow.adapterRating else { return "ADAPTER INPUT" }
        return String(format: "ADAPTER INPUT (%.0fW)", rating)
    }

    /// Three states, not two: a pack neither taking nor giving current is doing
    /// nothing, and painting that green read as "charging".
    private var packTint: Color {
        let watts = reading.pack.value(packReadout)
        if abs(watts) < 0.5 { return Theme.textPrimary }
        return watts > 0 ? Theme.cellWall : Theme.cellWarn
    }
}

/// One row of the rail: title, optional mode chip, and a right-aligned value in
/// a fixed column.
private struct RailRow: View {
    let title: String
    var readout: RailReadout?
    var modes: [RailReadout] = []
    let value: Double
    var tint: Color = Theme.textPrimary
    /// Whether to force a `+` on positives. Only the pack rate wants it — the
    /// sign is the whole story there, and a bare magnitude hides which way the
    /// current is going.
    var signed: Bool = false
    var cycle: (() -> Void)?

    /// Wide enough for `-101.9 W`, so nothing in this column ever reflows.
    private static let valueWidth: CGFloat = 68

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(Theme.mono(9.5))
                .tracking(0.5)
                .foregroundStyle(Theme.textMuted)
                .fixedSize()

            if let readout, let cycle {
                Button(action: cycle) {
                    Text("(\(readout.label))")
                        .font(Theme.mono(8.5))
                        .foregroundStyle(Theme.textMuted.opacity(0.75))
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to cycle: " + modes.map(\.label).joined(separator: " → "))
            }

            Spacer(minLength: 6)

            Text(formatted)
                .font(Theme.mono(11, .medium).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
    }

    private var formatted: String {
        // A pack resting at a few milliwatts is resting. Printing "-0.0 W"
        // because the sensor is a hair below zero says the opposite.
        if signed, abs(value) < 0.05 { return "+0.0 W" }
        if signed {
            return String(format: "%@%.1f W", value > 0 ? "+" : "−", abs(value))
        }
        return String(format: "%.1f W", value)
    }
}
