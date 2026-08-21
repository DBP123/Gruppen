import SwiftUI

// MARK: - Thermal and fans
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

// MARK: - Thermal and power

struct ThermalDetail: View {
    @ObservedObject var widget: ThermalTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            Well {
                HStack(alignment: .firstTextBaseline) {
                    Headline(value: reading.hottest.map { String(format: "%.1f", $0) } ?? "—",
                             unit: "°C",
                             tint: Self.heatTint(reading.hottest))
                    Spacer()
                    Text(reading.stateLabel)
                        .font(Theme.mono(9, .semibold)).tracking(0.8)
                        .foregroundStyle(reading.state == .nominal ? Theme.textMuted : Theme.red)
                }
                Sparkline(values: widget.history, floor: WidgetKind.thermal.plotFloor,
                          tint: Self.heatTint(reading.hottest), height: 30).equatable()
            }

            // Human labels only. The SMC key each zone came from is still on the
            // reading and is genuinely useful when you are working out *which*
            // sensor a machine exposes — but `Tp00` on a panel is a debug print
            // that escaped, not a diagnostic.
            Well {
                zone("CPU DIE", reading.cpuDie)
                zone("E-CORE DIE", reading.efficiencyCores)
                zone("GPU DIE", reading.gpuDie)
                zone("BATTERY", reading.batteryDie)
                // System draw used to sit here too. It is the same `PSTR` the
                // power module now leads with, and a wattage on the thermal card
                // was the same figure in two places — worse, in two places that
                // could disagree while one of them was frozen. Temperatures
                // here, watts there.
            }

            Well { fans(reading.fans) }
        } else {
            Waiting()
        }
    }

    // MARK: Fans

    /// One row per fan, always. Merging them into `FANS: OFF` lost the fact
    /// that this machine has two of them and that they can run at different
    /// speeds — which is the whole reason to look. Stopped fans still get a
    /// line each; what they do not get is an empty gauge under every one.
    @ViewBuilder
    private func fans(_ fans: [AppleSiliconTelemetry.Fan]) -> some View {
        if fans.isEmpty {
            StatRow(label: "FANS", value: "NONE")
        } else if fans.allSatisfy({ $0.actual < 1 }) {
            // Stopped: the rotors are drawn, still, so the pair still reads as
            // two fans rather than as one line of text.
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(fans.enumerated()), id: \.offset) { index, fan in
                    FanGauge(name: Self.fanName(index, of: fans.count), fan: fan)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(fans.enumerated()), id: \.offset) { index, fan in
                    FanGauge(name: Self.fanName(index, of: fans.count), fan: fan)
                }
            }
        }
    }

    /// Two fans on a Mac are left and right. More than two and the position is
    /// anyone's guess, so they are numbered.
    private static func fanName(_ index: Int, of count: Int) -> String {
        guard count == 2 else { return "FAN \(index + 1)" }
        return index == 0 ? "LEFT" : "RIGHT"
    }

    // MARK: Gating

    @ViewBuilder
    private func zone(_ label: String, _ zone: AppleSiliconTelemetry.Zone?) -> some View {
        if let zone {
            StatRow(label: label, value: String(format: "%.1f °C", zone.celsius),
                    tint: Self.heatTint(zone.celsius))
        }
    }

    /// Cool is not a warning. The previous version painted anything under 80°C
    /// in the same colour as a machine about to throttle, which made the whole
    /// well read as amber on an idle laptop.
    static func heatTint(_ celsius: Double?) -> Color {
        guard let celsius else { return Theme.textPrimary }
        if celsius > 85 { return Theme.crimson }
        if celsius >= 65 { return Theme.amber }
        return Theme.cyan
    }

}

/// The threshold gating, reachable from the shared panel's compact well too, so
/// one temperature cannot be amber in one place and cyan in another.
enum ThermalDetailTint {
    static func heat(_ celsius: Double?) -> Color { ThermalDetail.heatTint(celsius) }
}

// MARK: - Fans

/// One fan: a rotor that turns at the speed the fan is actually turning.
///
/// RPM sets the animation's *duration*, so a fan at 4,000 rpm visibly outruns
/// one at 2,300. That is the whole cost — SwiftUI interpolates the angle on the
/// render thread, so a spinning rotor and a still one cost the view system the
/// same. The blade count is deliberately five, not the real seven: at this size
/// the real count aliases into a grey disc and strobes.
private struct FanGauge: View {
    let name: String
    let fan: AppleSiliconTelemetry.Fan

    private var spinning: Bool { fan.actual >= 1 }

    private var period: Double {
        guard spinning else { return 0 }
        return min(max(60 / max(fan.actual, 1) * 12, 0.35), 4)
    }

    var body: some View {
        VStack(spacing: 4) {
            Rotor(spinning: spinning, period: period,
                  tint: spinning ? Theme.trace : Theme.textMuted.opacity(0.55))
                .frame(width: 34, height: 34)
            Text(name)
                .font(Theme.mono(8, .semibold)).tracking(0.6)
                .foregroundStyle(Theme.textMuted)
            Text(spinning ? "\(Format.rpm(fan.actual)) RPM" : "0 RPM")
                .font(Theme.mono(9.5, .medium).monospacedDigit())
                .foregroundStyle(spinning ? Theme.trace : Theme.textMuted)
                .fixedSize()
            if spinning {
                Text(String(format: "%.0f%%", fan.load * 100))
                    .font(Theme.mono(8).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Rotor: View {
    let spinning: Bool
    let period: Double
    let tint: Color

    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            Blades()
                .fill(tint.opacity(spinning ? 0.85 : 0.5))
                .padding(4)
                .rotationEffect(.degrees(angle))
            Circle().fill(Theme.housing)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1))
        }
        .onAppear { restart() }
        .onChange(of: spinning) { _ in restart() }
        .onChange(of: period) { _ in restart() }
    }

    private func restart() {
        // Reset to a known angle first, or changing the animation mid-flight
        // makes the rotor jump backwards.
        withAnimation(.linear(duration: 0)) { angle = 0 }
        guard spinning, period > 0 else { return }
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) { angle = 360 }
    }
}

/// Five swept blades around a hub.
private struct Blades: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for blade in 0..<5 {
            let start = Double(blade) * 72
            path.move(to: centre)
            path.addArc(center: centre, radius: radius,
                        startAngle: .degrees(start), endAngle: .degrees(start + 38),
                        clockwise: false)
            path.closeSubpath()
        }
        return path
    }
}
