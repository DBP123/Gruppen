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
                // The caption is centred on the figure, not hung off its
                // baseline, so it reads as the corner label of the box.
                HStack(alignment: .center) {
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

            // The clusters, kept apart. A P-core at 40% and an E-core at 40%
            // mean very different things about a machine, so each cluster has
            // its own colour, name and average — but they share one row, so
            // between them the cores fill the card. See `ClusterRow`.
            if !reading.performanceCores.isEmpty || !reading.efficiencyCores.isEmpty {
                Well {
                    ClusterRow(clusters: [
                        CoreCluster(title: "P-CORES", prefix: "P", loads: reading.performanceCores,
                                    mean: reading.performance, tint: Theme.cyan),
                        CoreCluster(title: "E-CORES", prefix: "E", loads: reading.efficiencyCores,
                                    mean: reading.efficiency, tint: Theme.trace),
                    ].filter { !$0.loads.isEmpty })
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
            Waiting(unavailable: widget.isUnavailable)
        }
    }
}

/// One core cluster: what it is called, its live mean, and a load per core.
struct CoreCluster: Identifiable {
    let title: String
    let prefix: String
    let loads: [Double]
    let mean: Double?
    let tint: Color
    var id: String { prefix }
}

/// Every cluster on one row that fills the card's width.
///
/// **Every core is the same width, across clusters.** The bars used to be a
/// fixed 11pt each, one cluster per row, which left most of a card's width
/// empty — six P-cores took 80pt of a 380pt card. Letting each row stretch on
/// its own would have filled it but drawn six P-cores twice as wide as twelve
/// E-cores, so the same load would look like a different amount. Here the row's
/// width is divided by the total core count, each cluster gets a span in
/// proportion to its cores, and a wider gap between clusters keeps them apart.
struct ClusterRow: View {
    let clusters: [CoreCluster]

    private let spacing: CGFloat = 3
    private let gap: CGFloat = 12
    private let barHeight: CGFloat = 48
    /// Narrower than this and "P12" no longer fits under its bar, so the
    /// per-core labels go — on a 32-core Ultra in a narrow card, say. The
    /// cluster headers still say which is which.
    private let labelledWidth: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let cores = clusters.reduce(0) { $0 + $1.loads.count }
            let fixed = CGFloat(clusters.count - 1) * gap + CGFloat(cores - clusters.count) * spacing
            let bar = max((geometry.size.width - fixed) / CGFloat(max(cores, 1)), 2)
            HStack(alignment: .top, spacing: gap) {
                ForEach(clusters) { cluster in
                    column(cluster, bar: bar)
                }
            }
        }
        // A `GeometryReader` takes whatever height it is offered, so the row
        // states its own: header, gap, bar, label.
        .frame(height: 14 + 4 + barHeight + 2 + 9)
    }

    private func column(_ cluster: CoreCluster, bar: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Steps down rather than squashing: "E-CORES 18.7%", then
            // "E 18.7%", then the figure alone. A header shrunk to fit read as
            // "E-CO…", and being shorter it dropped that cluster's bars below
            // the others'. The fixed height keeps every cluster's bars level
            // whichever form fits.
            ViewThatFits(in: .horizontal) {
                header(cluster.title, cluster)
                header(cluster.prefix, cluster)
                header(nil, cluster)
            }
            .frame(height: 14, alignment: .leading)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(cluster.loads.enumerated()), id: \.offset) { index, load in
                    VStack(spacing: 2) {
                        CoreBar(load: load, tint: cluster.tint)
                            .frame(width: bar, height: barHeight)
                        Text(bar >= labelledWidth ? "\(cluster.prefix)\(index + 1)" : " ")
                            .font(Theme.mono(7))
                            .foregroundStyle(Theme.textMuted.opacity(0.7))
                            .lineLimit(1)
                            .frame(width: bar)
                    }
                }
            }
        }
        .frame(width: bar * CGFloat(cluster.loads.count)
                   + spacing * CGFloat(cluster.loads.count - 1),
               alignment: .leading)
    }

    private func header(_ name: String?, _ cluster: CoreCluster) -> some View {
        HStack(spacing: 6) {
            if let name {
                Text(name)
                    .font(Theme.mono(9, .semibold)).tracking(0.9)
                    .foregroundStyle(Theme.textMuted)
            }
            Text(cluster.mean.map { Format.percent($0, decimals: 1) } ?? "—")
                .font(Theme.mono(10, .medium).monospacedDigit())
                .foregroundStyle(cluster.tint)
        }
        .fixedSize()
    }
}

/// A single core's load, filling whatever frame it is given, with a full-height
/// track behind it so an idle cluster reads as a row of empty slots rather than
/// a row of stubs.
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
