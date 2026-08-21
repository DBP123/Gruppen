import SwiftUI

/// The parts every telemetry well is built from.
///
/// All of it is drawn with `Path`, `Capsule` and `Rectangle` — no charting
/// framework, nothing that allocates per frame, and nothing that animates on a
/// clock of its own. A well redraws when its module publishes, and at no other
/// time.

// MARK: - Housing

/// A recessed instrument well: a header, a hairline dashed rule, and whatever
/// the module wants to show under it.
struct WidgetWell<Content: View>: View {
    let kind: WidgetKind
    /// Right-hand side of the header — the headline figure.
    var readout: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: kind.glyph)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                Text(kind.header)
                    .font(Theme.mono(9, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 8)
                if let readout {
                    Text(readout)
                        .font(Theme.mono(9, .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            DashedRule()
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(cornerRadius: 6, fill: Theme.well, border: Theme.machinedBorder)
    }
}

/// 1px dashed separator. `Divider` cannot dash, and a dotted rule is most of
/// what makes a readout look like an instrument rather than a table.
struct DashedRule: View {
    var color: Color = .white.opacity(0.09)

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0.5))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0.5))
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            )
    }
}

// MARK: - Readouts

/// The big number on a well: mono, tabular, and sized so it never reflows the
/// row it sits in as digits come and go.
struct Readout: View {
    let value: String
    var unit: String?
    var tint: Color = Theme.textPrimary
    var size: CGFloat = 19

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(Theme.mono(size, .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
            if let unit {
                Text(unit)
                    .font(Theme.mono(size * 0.5, .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}

/// `LABEL  value` in one small mono line.
struct MicroStat: View {
    let label: String
    let value: String
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.mono(8.5, .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(Theme.mono(9.5))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        // A figure that has been truncated to "3.87…" is worse than no figure.
        // These are sized to fit; the row that holds them gives way instead.
        .fixedSize()
    }
}

// MARK: - Data visualisation

/// A filled line chart over a fixed window of samples.
///
/// The series is drawn right-aligned, so a module that has only just started
/// grows in from the right edge rather than stretching two points across the
/// whole well.
/// A trace, normalised across its own window.
///
/// The scale is `(value − min) / (max − min)` over the trailing sixty samples
/// rather than a fixed 0–100. A processor idling between 5% and 8% used to draw
/// a dead flat line along the bottom of a percentage scale; normalised, those
/// three points fill the frame and you can see the shape of what the machine is
/// doing. `plotFloor` stops that turning a motionless quantity into a
/// full-height sawtooth of noise.
///
/// `Equatable` and rendered through `.equatable()`: the values are the whole of
/// its state, so SwiftUI can skip the body entirely when they have not changed.
struct Sparkline: View, Equatable {
    var values: [Double]
    /// Smallest range the vertical scale will collapse to.
    var floor: Double = 0.03
    var tint: Color = Theme.trace
    var height: CGFloat = 26

    static func == (a: Sparkline, b: Sparkline) -> Bool {
        a.values == b.values && a.floor == b.floor && a.height == b.height
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scaled = PlotScale.normalise(values, floor: floor)
            let slots = max(PlotScale.window - 1, 1)
            let step = size.width / CGFloat(slots)
            // Right-aligned: a half-filled history occupies the right-hand part
            // of the frame rather than being stretched across all of it.
            let points = scaled.enumerated().map { index, fraction -> CGPoint in
                let slot = CGFloat(slots - (scaled.count - 1 - index))
                // Half the stroke inset top and bottom, so a trace pinned to
                // either edge is not sliced in half by the frame.
                let usable = size.height - 1.5
                return CGPoint(x: slot * step, y: 0.75 + usable * (1 - CGFloat(fraction)))
            }

            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
        .background(GridRules())
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// Faint horizontal rules behind a plot, at quarters. Static, so it costs one
/// draw and never invalidates.
private struct GridRules: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for step in 1...3 {
                    let y = geometry.size.height * CGFloat(step) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.045), lineWidth: 0.5)
        }
    }
}

/// A proportional bar split into labelled parts — wired, app, compressed.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        var fraction: Double
        var tint: Color
    }

    var segments: [Segment]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.tint)
                        .frame(width: max(geometry.size.width * CGFloat(min(max(segment.fraction, 0), 1)), 0))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(.black.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

/// A row of discrete lamps that fill up to a level — the thermal gauge.
struct SegmentGauge: View {
    var level: Double
    var count: Int = 4
    var tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                let lit = Double(index + 1) / Double(count) <= level + 0.001
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(lit ? tint : Color.white.opacity(0.07))
                    .frame(height: 6)
                    .shadow(color: lit ? tint.opacity(0.6) : .clear, radius: 3)
            }
        }
    }
}

/// One vertical bar per core.
///
/// Each core keeps a full-height slot whether it is busy or not. Without the
/// slot, an idle machine draws eighteen 1-pixel stubs, which reads as a broken
/// graphic rather than as eighteen quiet cores.
struct CoreBars: View {
    var cores: [Double]
    var tint: Color = Theme.orange
    var height: CGFloat = 20

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, value in
                let fraction = CGFloat(min(max(value, 0), 1))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(height: height)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(
                                LinearGradient(colors: [tint, tint.mixed(with: .black, amount: 0.45)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                            .frame(height: max(height * fraction, fraction > 0.005 ? 1.5 : 0))
                    }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
