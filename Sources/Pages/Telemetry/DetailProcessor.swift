import SwiftUI

// MARK: - Processor
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

// MARK: - Processor

struct CPUDetail: View {
    @ObservedObject var widget: CPUTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            // Hero: the total, and the history of the total. Nothing else is
            // drawn in this frame — the timeline used to sit directly above the
            // per-core bars and the two read as one confused graph.
            Well {
                HStack(alignment: .firstTextBaseline) {
                    Headline(value: String(format: "%.1f", reading.busy * 100), unit: "%")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(reading.coreCount) CORES")
                            .font(Theme.mono(9, .semibold)).tracking(0.8)
                            .foregroundStyle(Theme.textMuted)
                        Text(CPUSampler.brand)
                            .font(Theme.mono(8.5))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Sparkline(values: widget.history, floor: WidgetKind.cpu.plotFloor,
                          tint: Theme.cyan, height: 36).equatable()
            }

            // The clusters, separately. A P-core at 40% and an E-core at 40%
            // mean very different things about a machine, and a single row of
            // eighteen identical bars says neither.
            if !reading.performanceCores.isEmpty || !reading.efficiencyCores.isEmpty {
                Well {
                    Cluster(title: "P-CORES", prefix: "P",
                            loads: reading.performanceCores,
                            mean: reading.performance, tint: Theme.cyan)
                    Cluster(title: "E-CORES", prefix: "E",
                            loads: reading.efficiencyCores,
                            mean: reading.efficiency, tint: Theme.trace)
                }
            } else {
                Well { CoreBars(cores: reading.cores, height: 18) }
            }

            // Where the time went, as one bar rather than two numbers to
            // subtract in your head.
            Well {
                ExecutionBar(user: reading.user, system: reading.system)
                // One line, and it must stay one line: every part is
                // `fixedSize`, because the default here is to wrap and
                // "THREADS" broke across two rows as "THRE / ADS".
                HStack(spacing: 0) {
                    Legend(label: "USER", value: Format.percent(reading.user, decimals: 1),
                           tint: Theme.cyan)
                    Dot()
                    Legend(label: "SYS", value: Format.percent(reading.system, decimals: 1),
                           tint: Theme.orange)
                    Dot()
                    Legend(label: "THR", value: Format.count(reading.threads), leading: false)
                    Dot()
                    Legend(label: "PROC", value: Format.count(reading.processes), leading: false)
                    Spacer(minLength: 0)
                }
            }
        } else {
            Waiting()
        }
    }
}

/// One labelled core cluster: its live mean, then a bar per core.
private struct Cluster: View {
    let title: String
    let prefix: String
    let loads: [Double]
    let mean: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.mono(9, .semibold)).tracking(0.9)
                    .foregroundStyle(Theme.textMuted)
                Text(mean.map { Format.percent($0, decimals: 1) } ?? "—")
                    .font(Theme.mono(10, .medium).monospacedDigit())
                    .foregroundStyle(tint)
                Spacer()
                Text("\(loads.count)×")
                    .font(Theme.mono(8.5).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(loads.enumerated()), id: \.offset) { index, load in
                    VStack(spacing: 2) {
                        CoreBar(load: load, tint: tint)
                        Text("\(prefix)\(index + 1)")
                            .font(Theme.mono(7))
                            .foregroundStyle(Theme.textMuted.opacity(0.7))
                    }
                }
            }
        }
    }
}

/// A single core's load. Fixed height with a full-height track behind it, so an
/// idle cluster reads as a row of empty slots rather than a row of stubs.
private struct CoreBar: View {
    let load: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let filled = max(height * CGFloat(min(max(load, 0), 1)), load > 0.01 ? 1.5 : 0)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(height: filled)
            }
        }
        .frame(width: 11, height: 26)
    }
}

/// User against system time, as one bar. The remainder is idle.
private struct ExecutionBar: View {
    let user: Double
    let system: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 1) {
                Rectangle().fill(Theme.cyan)
                    .frame(width: width * CGFloat(min(max(user, 0), 1)))
                Rectangle().fill(Theme.orange)
                    .frame(width: width * CGFloat(min(max(system, 0), 1)))
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}
