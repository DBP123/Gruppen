import SwiftUI

/// What one menu bar item's popover shows.
///
/// Each standalone item owns its own popover and its own module: the processor
/// item opens processor data and nothing else. That is the whole point of
/// having separate items — a single shared dropdown makes the items decorative,
/// because whichever one you click you get the same thing.
///
/// These are denser than the shared panel's wells on purpose. A popover opened
/// deliberately, about one subsystem, is where the diagnostics go.
struct ModuleDetail: View {
    let kind: WidgetKind
    @ObservedObject private var manager = WidgetManager.shared

    init(kind: WidgetKind) { self.kind = kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DetailHeader(kind: kind)
            content
        }
        .padding(12)
        .frame(width: 292, alignment: .leading)
        .background(Theme.housing.grain(0.2))
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.housingEdge, Theme.housingEdge.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .cpu:
            if let widget = manager.module(CPUTelemetryWidget.self, .cpu) { CPUDetail(widget: widget) }
            else { Waiting() }
        case .memory:
            if let widget = manager.module(MemoryTelemetryWidget.self, .memory) { MemoryDetail(widget: widget) }
            else { Waiting() }
        case .network:
            if let widget = manager.module(NetworkTelemetryWidget.self, .network) { NetworkDetail(widget: widget) }
            else { Waiting() }
        case .thermal:
            if let widget = manager.module(ThermalTelemetryWidget.self, .thermal) { ThermalDetail(widget: widget) }
            else { Waiting() }
        case .power:
            if let widget = manager.module(PowerTelemetryWidget.self, .power) { PowerDetail(widget: widget) }
            else { Waiting() }
        case .storage:
            if let widget = manager.module(StorageTelemetryWidget.self, .storage) { StorageDetail(widget: widget) }
            else { Waiting() }
        case .silicon:
            if let widget = manager.module(SiliconTelemetryWidget.self, .silicon) { SiliconDetail(widget: widget) }
            else { Waiting() }
        case .processes, .footprint:
            Waiting()
        }
    }
}

// MARK: - Chrome

private struct DetailHeader: View {
    let kind: WidgetKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: kind.glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                Text(kind.header)
                    .font(Theme.mono(10, .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            DashedRule()
        }
    }
}

private struct Waiting: View {
    var body: some View {
        Text("Waiting for the first reading…")
            .font(Theme.mono(10))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

/// A label and a figure on one line, mono throughout and monospaced-digit, so a
/// column of these never shifts as the numbers change.
private struct StatRow: View {
    let label: String
    let value: String
    var tint: Color = Theme.textPrimary
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Theme.mono(9.5))
                .tracking(0.5)
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 6)
            if let detail {
                Text(detail)
                    .font(Theme.mono(9.5).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            Text(value)
                .font(Theme.mono(11, .medium).monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}

/// The one big number at the top of a popover.
private struct Headline: View {
    let value: String
    let unit: String
    var tint: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 26, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(tint)
            Text(unit)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
        }
    }
}

private struct Well<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .machined(cornerRadius: Theme.radiusMd, fill: Theme.well)
    }
}

// MARK: - Processor

private struct CPUDetail: View {
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

/// A label and a figure side by side. `leading` puts the label first — right for
/// a percentage — and false puts the figure first, which is how a count reads.
private struct Legend: View {
    let label: String
    let value: String
    var tint: Color = Theme.textPrimary
    var leading = true

    var body: some View {
        HStack(spacing: 3) {
            if leading { name }
            Text(value)
                .font(Theme.mono(9.5, .medium).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
            if !leading { name }
        }
    }

    private var name: some View {
        Text(label)
            .font(Theme.mono(8)).tracking(0.4)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct Dot: View {
    var body: some View {
        Text("•")
            .font(Theme.mono(8))
            .foregroundStyle(Theme.textMuted.opacity(0.6))
            .padding(.horizontal, 4)
            .fixedSize()
    }
}

// MARK: - Memory

private struct MemoryDetail: View {
    @ObservedObject var widget: MemoryTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            // No line graph. Memory is a pool that is divided up, not a quantity
            // that rises and falls — a trace of "used" says nothing about
            // whether the machine is under pressure, and the same 60% can be
            // comfortable or desperate depending on what it is made of.
            Well {
                HStack(alignment: .firstTextBaseline) {
                    Headline(value: Format.bytes(reading.used)
                        .replacingOccurrences(of: " GB", with: ""), unit: "GB IN USE",
                             tint: Theme.cyan)
                    Spacer()
                    Text("OF \(Format.bytes(reading.total))")
                        .font(Theme.mono(9, .semibold)).tracking(0.8)
                        .foregroundStyle(Theme.textMuted)
                }
                SegmentedBar(segments: [
                    .init(fraction: share(reading.app, reading), tint: Theme.cyan),
                    .init(fraction: share(reading.wired, reading), tint: Theme.purple),
                    .init(fraction: share(reading.compressed, reading), tint: Theme.amber),
                    .init(fraction: share(reading.cached, reading), tint: Color(hex: 0x2A3038)),
                ], height: 12)
                HStack(spacing: 0) {
                    Key("APP", Theme.cyan); Key("WIRED", Theme.purple)
                    Key("COMPRESSED", Theme.amber); Key("CACHED", Color(hex: 0x2A3038))
                    Spacer(minLength: 0)
                }
            }

            Well {
                StatRow(label: "APP", value: Format.bytes(reading.app), tint: Theme.cyan)
                StatRow(label: "WIRED", value: Format.bytes(reading.wired), tint: Theme.purple)
                StatRow(label: "COMPRESSED", value: Format.bytes(reading.compressed), tint: Theme.amber)
                StatRow(label: "CACHED", value: Format.bytes(reading.cached))
                StatRow(label: "SWAP",
                        value: reading.swapTotal > 0
                            ? "\(Format.bytes(reading.swapUsed)) / \(Format.bytes(reading.swapTotal))"
                            : "NONE",
                        tint: reading.swapUsed > 0 ? Theme.crimson : Theme.textPrimary)
                StatRow(label: "PAGE IN / OUT",
                        value: String(format: "%.0f / %.0f per s", reading.pageInRate, reading.pageOutRate),
                        tint: reading.pageOutRate > 0 ? Theme.crimson : Theme.textPrimary)
                StatRow(label: "COMPRESS / DECOMPRESS",
                        value: String(format: "%.0f / %.0f per s",
                                      reading.compressRate, reading.decompressRate))
            }

            if !reading.consumers.isEmpty {
                Well {
                    TableHeader(columns: [("PROCESS NAME", .leading, nil),
                                          ("MEMORY", .trailing, 74)])
                    ForEach(reading.consumers) { consumer in
                        HStack(spacing: 8) {
                            Text(consumer.name)
                                .font(Theme.mono(10)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Format.bytes(consumer.footprint))
                                .font(Theme.mono(10, .medium).monospacedDigit())
                                .foregroundStyle(Theme.cyan)
                                .frame(width: 74, alignment: .trailing)
                        }
                    }
                }
            }
        } else {
            Waiting()
        }
    }

    /// Each pool as a share of installed memory.
    private func share(_ part: UInt64, _ reading: MemorySampler.Reading) -> Double {
        reading.total > 0 ? Double(part) / Double(reading.total) : 0
    }
}

/// A colour chip and its name, for a stacked bar's legend.
private struct Key: View {
    let label: String
    let tint: Color

    init(_ label: String, _ tint: Color) { self.label = label; self.tint = tint }

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(Theme.mono(8)).tracking(0.3)
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
        }
        .padding(.trailing, 7)
    }
}

/// Explicit column headers. Every table in here gets them — a column of numbers
/// with no heading is a column you have to guess at, which is what "connections
/// · bytes carried on them" was really admitting.
private struct TableHeader: View {
    let columns: [(String, HorizontalAlignment, CGFloat?)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                if column.1 == .leading {
                    Text(column.0)
                        .font(Theme.mono(8, .semibold)).tracking(0.7)
                        .foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 6)
                } else {
                    Text(column.0)
                        .font(Theme.mono(8, .semibold)).tracking(0.7)
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: column.2, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Network

private struct NetworkDetail: View {
    @ObservedObject var widget: NetworkTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            Well {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DOWN").font(Theme.mono(9, .semibold)).tracking(0.8)
                            .foregroundStyle(Theme.textMuted)
                        Text(Format.rate(reading.down))
                            .font(Theme.mono(15, .medium).monospacedDigit())
                            .foregroundStyle(Theme.trace)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("UP").font(Theme.mono(9, .semibold)).tracking(0.8)
                            .foregroundStyle(Theme.textMuted)
                        Text(Format.rate(reading.up))
                            .font(Theme.mono(15, .medium).monospacedDigit())
                            .foregroundStyle(Theme.orange)
                    }
                }
                ZStack {
                    Sparkline(values: widget.history, floor: WidgetKind.network.plotFloor,
                              height: 30).equatable()
                    Sparkline(values: widget.upHistory, floor: WidgetKind.network.plotFloor,
                              tint: Theme.orange, height: 30).equatable()
                }
                StatRow(label: "INTERFACES", value: "\(reading.interfaces)",
                        detail: "↓\(Format.bytes(reading.downTotal)) ↑\(Format.bytes(reading.upTotal))")
            }

            // Two halves, each sorted strictly by its own direction, so the
            // busiest downloader and the busiest uploader are both visible —
            // one combined list ranked by total hides whichever is smaller.
            TrafficTable(title: "INBOUND PROCESSES", glyph: "↓", tint: Theme.trace,
                         rows: reading.talkers.sorted { $0.downTotal > $1.downTotal },
                         value: \.downTotal)
            TrafficTable(title: "OUTBOUND PROCESSES", glyph: "↑", tint: Theme.orange,
                         rows: reading.talkers.sorted { $0.upTotal > $1.upTotal },
                         value: \.upTotal)
        } else {
            Waiting()
        }
    }
}

/// One direction's table: the same processes, ranked by that direction alone,
/// with the columns named.
private struct TrafficTable: View {
    let title: String
    let glyph: String
    let tint: Color
    let rows: [NetworkTalkers.Talker]
    let value: KeyPath<NetworkTalkers.Talker, UInt64>

    /// Both halves show the same number of rows, so neither direction looks
    /// more important than the other.
    private static let limit = 4

    var body: some View {
        Well {
            HStack(spacing: 5) {
                Text(glyph).font(Theme.mono(10, .semibold)).foregroundStyle(tint)
                Text(title)
                    .font(Theme.mono(9, .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            }
            TableHeader(columns: [("PROCESS NAME", .leading, nil),
                                  ("CONNS", .trailing, 40),
                                  ("TRAFFIC", .trailing, 68)])
            if rows.isEmpty {
                Text("No attributed connections")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.textMuted)
            } else {
                ForEach(rows.prefix(Self.limit)) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(Theme.mono(10)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(row.connections)")
                            .font(Theme.mono(10).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 40, alignment: .trailing)
                        Text(Format.bytes(row[keyPath: value]))
                            .font(Theme.mono(10, .medium).monospacedDigit())
                            .foregroundStyle(tint)
                            .frame(width: 68, alignment: .trailing)
                    }
                }
            }
        }
    }
}

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
                if let power = reading.systemPower {
                    StatRow(label: "SYSTEM DRAW", value: String(format: "%.2f W", power),
                            tint: Self.powerTint(power))
                }
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

    static func powerTint(_ watts: Double) -> Color {
        if watts > 40 { return Theme.crimson }
        if watts >= 15 { return Theme.amber }
        return Theme.trace
    }
}

// MARK: - Graphics

private struct SiliconDetail: View {
    @ObservedObject var widget: SiliconTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            Well {
                HStack(alignment: .firstTextBaseline) {
                    Headline(value: String(format: "%.1f", reading.gpu * 100), unit: "%",
                             tint: Theme.purple)
                    Spacer()
                    Text("\(reading.coreCount) CORES")
                        .font(Theme.mono(9, .semibold)).tracking(0.8)
                        .foregroundStyle(Theme.textMuted)
                }
                Sparkline(values: widget.history, floor: WidgetKind.silicon.plotFloor,
                          tint: Theme.purple, height: 34).equatable()
            }

            // The VRAM pool, once. It used to appear twice — beside the headline
            // and again as "IN USE" — with no indication of what it was a share
            // of, which is the number that makes it mean anything.
            Well {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.bytes(reading.gpuMemory))
                        .font(Theme.mono(15, .medium).monospacedDigit())
                        .foregroundStyle(Theme.purple)
                    Text("/ \(Format.bytes(SiliconSampler.memoryPool)) UNIFIED")
                        .font(Theme.mono(9, .semibold)).tracking(0.6)
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                }
                SegmentedBar(segments: [
                    .init(fraction: poolFraction(reading.gpuMemory), tint: Theme.purple),
                ], height: 8)
                StatRow(label: "RENDERER", value: Format.percent(reading.renderer, decimals: 1))
                StatRow(label: "TILER", value: Format.percent(reading.tiler, decimals: 1))
            }

            Well {
                Text("FIXED-FUNCTION ENGINES")
                    .font(Theme.mono(9, .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textMuted)
                engine("NEURAL", reading.neuralEngine)
                engine("VIDEO", reading.videoEngine)
                engine("IMAGE", reading.imageEngine)
                Text("power state, not utilisation — see the panel note")
                    .font(Theme.mono(8.5))
                    .foregroundStyle(Theme.textMuted.opacity(0.8))
            }
        } else {
            Waiting()
        }
    }

    /// Apple Silicon has no dedicated VRAM: the GPU allocates out of the same
    /// unified memory the CPU uses, so the pool it is drawn from is the whole
    /// installed RAM. Saying "4.2 GB" without that is a number with no scale.
    private func poolFraction(_ used: UInt64) -> Double {
        let pool = SiliconSampler.memoryPool
        return pool > 0 ? Double(used) / Double(pool) : 0
    }

    @ViewBuilder
    private func engine(_ label: String, _ state: AppleSiliconTelemetry.EngineState?) -> some View {
        if let state {
            HStack(spacing: 8) {
                LED(color: state.isAwake ? Theme.trace : Theme.textMuted, lit: state.isAwake, size: 7)
                Text(label)
                    .font(Theme.mono(9.5)).tracking(0.5)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(state.isAwake ? "AWAKE \(state.current)/\(state.maximum)" : "ASLEEP")
                    .font(Theme.mono(10).monospacedDigit())
                    .foregroundStyle(state.isAwake ? Theme.trace : Theme.textMuted)
            }
        }
    }
}

/// The threshold gating, reachable from the shared panel's compact well too, so
/// one temperature cannot be amber in one place and cyan in another.
enum ThermalDetailTint {
    static func heat(_ celsius: Double?) -> Color { ThermalDetail.heatTint(celsius) }
    static func power(_ watts: Double) -> Color { ThermalDetail.powerTint(watts) }
}

// MARK: - Power and battery

/// The battery, and where its power is going.
///
/// Split from thermals so the two draw figures can be named for what they are.
/// They were side by side and unlabelled, which made them look like two attempts
/// at the same measurement: **system draw** is what the hardware is burning,
/// **battery flow** is what is moving into or out of the cell. On a charging
/// machine they are not even the same sign.
private struct PowerDetail: View {
    @ObservedObject var widget: PowerTelemetryWidget

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

            // The two figures that used to be confused with each other.
            Well {
                // Plain words, because these three are the panel's most
                // misread rows: two of them are watts and look interchangeable.
                StatRow(label: "CURRENT POWER CONSUMPTION",
                        value: String(format: "%.1f W", flow.systemLoad),
                        tint: ThermalDetailTint.power(flow.systemLoad))
                StatRow(label: flow.batteryPower >= 0 ? "BATTERY CHARGE RATE" : "BATTERY DISCHARGE LOAD",
                        value: String(format: "%.1f W", abs(flow.batteryPower)),
                        tint: flow.batteryPower >= 0 ? Theme.trace : Theme.amber)
                if flow.isPluggedIn {
                    StatRow(label: "ADAPTER INPUT",
                            value: String(format: "%.1f W", flow.adapterInput),
                            tint: Theme.cyan,
                            detail: flow.adapterRating.map { String(format: "%.0f W rated", $0) })
                }
            }

            Well {
                PowerModeSegmentControl(mode: PowerMode.current(lowPower: reading.isLowPower))
            }

            Well {
                StatRow(label: "CHARGE",
                        value: String(format: "%.1f / %.1f Wh", flow.remainingEnergy, flow.fullEnergy))
                if let cycles = reading.cycleCount {
                    StatRow(label: "CYCLE COUNT", value: "\(cycles)")
                }
                if let health = reading.health {
                    StatRow(label: "STATE OF HEALTH",
                            value: Format.percent(health, decimals: 0),
                            tint: health < 0.8 ? Theme.amber : Theme.trace)
                }
                if let celsius = reading.temperature {
                    StatRow(label: "CELL TEMPERATURE", value: String(format: "%.1f °C", celsius),
                            tint: ThermalDetailTint.heat(celsius))
                }
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

    /// Fill colour.
    ///
    /// Discharging is the case that matters: a static white bar tells you
    /// nothing you did not already know, so it steps green → yellow → red as the
    /// charge falls, and you can read the state without reading the number.
    static func tint(_ percent: Int, _ condition: PowerFlow.Condition) -> Color {
        switch condition {
        case .fault: return Theme.cellLow
        case .charging, .acPassthrough: return Theme.cellHigh
        case .optimizedHold: return Theme.cellHold
        case .lowPowerMode: return Theme.cellMedium
        case .discharging:
            if percent < 20 { return Theme.cellLow }
            if percent < 50 { return Theme.cellMedium }
            return Theme.cellHigh
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

                RoundedRectangle(cornerRadius: radius * 0.6, style: .continuous)
                    .fill(fill)
                    .overlay { if mode == .high { HazardStripes() } }
                    .clipShape(RoundedRectangle(cornerRadius: radius * 0.6, style: .continuous))
                    .padding(height * 0.1)
                    .frame(width: max(level > 0 ? height * 0.3 : 0,
                                      (width - height * 0.2) * level),
                           alignment: .leading)
                    .animation(.easeOut(duration: 0.4), value: level)

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
            .shadow(color: aura, radius: mode == .high ? 12 : 9)

            // Terminal nub, in the shell's colour.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(shell)
                .frame(width: max(1.5, width * 0.06), height: height * 0.36)
        }
        .onAppear { ignite() }
        .onChange(of: condition) { _ in ignite() }
    }

    private var aura: Color {
        switch mode {
        case .low: return Theme.amber.opacity(0.15)
        case .high: return Theme.crimson.opacity(0.25)
        case .auto: return condition == .fault ? Theme.cellLow.opacity(0.2) : .clear
        }
    }

    private func ignite() {
        guard condition == .charging else { pulse = false; return }
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

// MARK: - Storage

/// The drive: how it is carved up, and what is moving through it.
///
/// No pie chart and no line graph. A container's allocation is a set of shares
/// of one fixed thing, which is what a stacked bar is for; and the two rates get
/// segmented tachometers, which show a single burst that a smooth trace loses.
private struct StorageDetail: View {
    @ObservedObject var widget: StorageTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            Well {
                if let identity = reading.identity {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(identity.model)
                            .font(Theme.mono(11, .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(identity.protocolName)  ·  FW \(identity.firmware)")
                            .font(Theme.mono(8.5)).tracking(0.4)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                APFSCapacityBar(reading: reading)
            }

            Well {
                IOTelemetryMeter(label: "READ", glyph: "↓", tint: Theme.cyan,
                                 rate: reading.readRate, ops: reading.readOps)
                DashedRule().padding(.vertical, 2)
                IOTelemetryMeter(label: "WRITE", glyph: "↑", tint: Theme.amber,
                                 rate: reading.writeRate, ops: reading.writeOps)
            }

            Well {
                HStack(alignment: .top, spacing: 0) {
                    HealthCell(title: "S.M.A.R.T.",
                               value: reading.identity?.smartCapable == true ? "VERIFIED" : "N/A",
                               tint: reading.identity?.smartCapable == true ? Theme.trace : Theme.textMuted)
                    HealthCell(title: "I/O ERRORS",
                               value: "\(reading.errors)",
                               tint: reading.errors == 0 ? Theme.trace : Theme.crimson)
                    HealthCell(title: "WRITTEN (BOOT)",
                               value: Format.bytes(reading.writeTotal),
                               tint: Theme.textPrimary)
                }
            }
        } else {
            Waiting()
        }
    }
}

/// The APFS container as one stacked bar: what is genuinely occupied, what is
/// purgeable — cache and snapshots macOS gives back under pressure, which Finder
/// counts as used — and what is free, hatched rather than filled so an empty
/// drive reads as space rather than as another allocation.
struct APFSCapacityBar: View {
    let reading: StorageSampler.Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                HStack(spacing: 1) {
                    Rectangle().fill(Color.white)
                        .frame(width: width * CGFloat(share(occupied)))
                    Rectangle().fill(Theme.amber.opacity(0.75))
                        .frame(width: width * CGFloat(share(reading.purgeable)))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)
            .background(HatchedFree())
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )

            HStack(spacing: 0) {
                Key("OCCUPIED", .white)
                Key("PURGEABLE", Theme.amber.opacity(0.75))
                Key("FREE", Color(hex: 0x2A3038))
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                Legend(label: "USED", value: Format.bytes(reading.used))
                Dot()
                Legend(label: "FREE", value: Format.bytes(reading.effectiveFree), tint: Theme.cyan)
                Dot()
                Legend(label: "CAPACITY", value: Format.bytes(reading.total))
                Spacer(minLength: 0)
            }
        }
    }

    /// Occupied is what is used *less* the part that is only nominally used.
    private var occupied: UInt64 {
        reading.used > reading.purgeable ? reading.used - reading.purgeable : 0
    }

    private func share(_ part: UInt64) -> Double {
        reading.total > 0 ? Double(part) / Double(reading.total) : 0
    }
}

private struct HatchedFree: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Path { path in
                var x = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 6
                }
            }
            .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
        .background(Color(hex: 0x14181E))
    }
}

/// One direction of drive traffic: the rate, and the operation count behind it.
struct IOTelemetryMeter: View {
    let label: String
    let glyph: String
    let tint: Color
    let rate: Double
    let ops: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(glyph).font(Theme.mono(11, .semibold)).foregroundStyle(tint)
                Text(label)
                    .font(Theme.mono(9, .semibold)).tracking(0.9)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 6)
                Text(Format.rate(rate))
                    .font(Theme.mono(13, .medium).monospacedDigit())
                    .foregroundStyle(tint)
                    .fixedSize()
            }
            HStack(spacing: 0) {
                SegmentGauge(level: level, count: 20, tint: tint)
                Spacer(minLength: 8)
                Legend(label: "IOPS", value: Format.count(Int(ops.rounded())), leading: false)
            }
        }
    }

    /// Log scale: a drive idles at a few KB/s and peaks in the GB/s, and a
    /// linear meter spends all its time either empty or full.
    private var level: Double {
        guard rate > 1 else { return 0 }
        return min(log10(rate) / 9, 1)
    }
}

private struct HealthCell: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.mono(8, .semibold)).tracking(0.6)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Text(value)
                .font(Theme.mono(11, .medium).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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
