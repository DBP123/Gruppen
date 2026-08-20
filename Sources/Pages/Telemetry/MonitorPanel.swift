import AppKit
import SwiftUI

/// The dropdown every menu bar item opens.
///
/// A real window rather than an `NSMenu`, which is the difference between a live
/// instrument and a frozen one: while an `NSMenu` tracks the mouse it does not
/// let SwiftUI run an update pass, so anything inside it shows whatever it was
/// built with and nothing after. A window keeps a normal view hierarchy, which
/// is what lets the plots move at 2 Hz while you are looking at them.
///
/// `MonitorPanelController` owns the window and gives `WidgetManager` the open
/// and close signals the whole demand-driven rule hangs off — not this view,
/// which is created and destroyed with each showing.
struct MonitorPanel: View {
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: NavigationModel
    @ObservedObject private var manager = WidgetManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            gruppen
            if !manager.panelOrder.isEmpty {
                VStack(spacing: 7) {
                    ForEach(manager.panelOrder) { kind in
                        well(for: kind)
                    }
                }
            }
            footprint
            DashedRule()
            actions
        }
        .padding(12)
        .frame(width: 306)
        .background(Theme.housing.grain(0.2))
        // Milled aluminium: the light catches the top lip of the housing.
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.housingEdge, Theme.housingEdge.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text("GRUPPEN")
                .font(Theme.mono(10, .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(Bundle.shortVersion)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder
    private var gruppen: some View {
        if store.groups.isEmpty {
            Text("No Gruppen yet")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 3) {
                ForEach(store.groups) { group in
                    GruppeRow(group: group)
                }
            }
        }
    }

    @ViewBuilder
    private func well(for kind: WidgetKind) -> some View {
        switch kind {
        case .cpu:
            if let widget = manager.module(CPUTelemetryWidget.self, .cpu) { CPUWell(widget: widget) }
        case .silicon:
            if let widget = manager.module(SiliconTelemetryWidget.self, .silicon) { SiliconWell(widget: widget) }
        case .memory:
            if let widget = manager.module(MemoryTelemetryWidget.self, .memory) { MemoryWell(widget: widget) }
        case .network:
            if let widget = manager.module(NetworkTelemetryWidget.self, .network) { NetworkWell(widget: widget) }
        case .thermal:
            if let widget = manager.module(ThermalTelemetryWidget.self, .thermal) { ThermalWell(widget: widget) }
        case .power:
            if let widget = manager.module(PowerTelemetryWidget.self, .power) { PowerWell(widget: widget) }
        case .storage:
            if let widget = manager.module(StorageTelemetryWidget.self, .storage) { StorageWell(widget: widget) }
        case .processes:
            if let widget = manager.module(ProcessTelemetryWidget.self, .processes) { ProcessWell(widget: widget) }
        case .footprint:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footprint: some View {
        if settings.showPerformanceMonitor,
           let widget = manager.module(FootprintTelemetryWidget.self, .footprint) {
            FootprintLine(widget: widget)
        }
    }

    private var actions: some View {
        VStack(spacing: 2) {
            PanelAction(title: "Open Gruppen", glyph: "macwindow") {
                MenuBarManager.shared.showMainWindow()
            }
            PanelAction(title: "Telemetry Settings", glyph: "slider.horizontal.3") {
                navigation.openGuardrails()
                MenuBarManager.shared.showMainWindow()
            }
            PanelAction(title: "Quit Gruppen", glyph: "power", tint: Theme.red) {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Rows

private struct GruppeRow: View {
    let group: AppGroup
    @EnvironmentObject private var store: GroupStore
    @State private var hovering = false

    private var action: GroupStore.PrimaryAction { store.primaryAction(for: group) }
    private var enabled: Bool { !group.apps.isEmpty }

    var body: some View {
        Button {
            store.toggle(group)
            MenuBarManager.shared.dismissPanel()
        } label: {
            HStack(spacing: 8) {
                LED(color: group.color, lit: group.isActive, size: 7)
                Text(group.name)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(action.label.uppercased())
                    .font(Theme.mono(8.5, .semibold))
                    .tracking(0.7)
                    .foregroundStyle(hovering && enabled ? Theme.orange : Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering && enabled ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

private struct PanelAction: View {
    let title: String
    let glyph: String
    var tint: Color = Theme.textSecondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            action()
            MenuBarManager.shared.dismissPanel()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 13)
                Text(title)
                    .font(Theme.sans(12, .medium))
                Spacer()
            }
            .foregroundStyle(hovering ? (tint == Theme.red ? Theme.red : Theme.textPrimary) : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Wells

/// Capacity and the two rates, compactly.
private struct StorageWell: View {
    @ObservedObject var widget: StorageTelemetryWidget

    var body: some View {
        WidgetWell(kind: .storage,
                   readout: widget.reading.map { Format.bytes($0.effectiveFree) + " FREE" } ?? "—") {
            if let reading = widget.reading {
                SegmentedBar(segments: [
                    .init(fraction: reading.total > 0
                          ? Double(reading.used &- min(reading.purgeable, reading.used)) / Double(reading.total) : 0,
                          tint: .white),
                    .init(fraction: reading.total > 0
                          ? Double(reading.purgeable) / Double(reading.total) : 0,
                          tint: Theme.amber.opacity(0.75)),
                ], height: 8)
                HStack(spacing: 0) {
                    MicroStat(label: "READ", value: Format.rate(reading.readRate), tint: Theme.cyan)
                    Spacer(minLength: 4)
                    MicroStat(label: "WRITE", value: Format.rate(reading.writeRate), tint: Theme.amber)
                    Spacer(minLength: 4)
                    MicroStat(label: "IOPS",
                              value: Format.count(Int((reading.readOps + reading.writeOps).rounded())))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The compact power line for the shared panel: charge, and the two draw
/// figures kept distinct.
private struct PowerWell: View {
    @ObservedObject var widget: PowerTelemetryWidget

    var body: some View {
        WidgetWell(kind: .power, readout: widget.reading.map { "\($0.flow.percent)%" } ?? "—") {
            if let flow = widget.reading?.flow {
                HStack(spacing: 0) {
                    BatteryGlyph(percent: flow.percent, state: flow.state)
                    Spacer(minLength: 8)
                    MicroStat(label: "SYS", value: String(format: "%.1f W", flow.systemLoad))
                    Spacer(minLength: 4)
                    MicroStat(label: flow.batteryPower >= 0 ? "INTO CELL" : "FROM CELL",
                              value: String(format: "%.1f W", abs(flow.batteryPower)),
                              tint: flow.batteryPower >= 0 ? Theme.trace : Theme.amber)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CPUWell: View {
    @ObservedObject var widget: CPUTelemetryWidget

    var body: some View {
        WidgetWell(kind: .cpu, readout: "\(widget.reading?.coreCount ?? 0) CORES") {
            if let reading = widget.reading {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Readout(value: Format.percent(reading.busy), tint: tint(reading.busy))
                        // The cluster split when the device tree gives us one,
                        // the user/system split when it does not.
                        if let performance = reading.performance {
                            MicroStat(label: "P", value: Format.percent(performance), tint: Theme.orange)
                            MicroStat(label: "E", value: Format.percent(reading.efficiency ?? 0))
                        } else {
                            MicroStat(label: "USR", value: Format.percent(reading.user, decimals: 1))
                            MicroStat(label: "SYS", value: Format.percent(reading.system, decimals: 1))
                        }
                    }
                    .frame(width: 78, alignment: .leading)

                    VStack(spacing: 4) {
                        Sparkline(values: widget.history, floor: WidgetKind.cpu.plotFloor, height: 24).equatable()
                        CoreBars(cores: reading.cores, height: 16)
                    }
                }
            } else {
                Placeholder()
            }
        }
    }

    private func tint(_ busy: Double) -> Color {
        busy > 0.85 ? Theme.red : (busy > 0.5 ? Theme.orange : Theme.textPrimary)
    }
}

/// GPU load, and whether the fixed-function blocks are awake.
private struct SiliconWell: View {
    @ObservedObject var widget: SiliconTelemetryWidget

    var body: some View {
        WidgetWell(kind: .silicon, readout: widget.reading.map { Format.bytes($0.gpuMemory) }) {
            if let reading = widget.reading {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Readout(value: Format.percent(reading.gpu),
                                    tint: reading.gpu > 0.85 ? Theme.red : Theme.textPrimary)
                            MicroStat(label: "REND", value: Format.percent(reading.renderer))
                            MicroStat(label: "TILE", value: Format.percent(reading.tiler))
                        }
                        .frame(width: 78, alignment: .leading)
                        Sparkline(values: widget.history, floor: WidgetKind.silicon.plotFloor, height: 44).equatable()
                    }
                    // These publish a power state, not a load. An honest lamp
                    // beats an invented percentage.
                    HStack(spacing: 12) {
                        EngineLamp(name: "ANE", state: reading.neuralEngine)
                        EngineLamp(name: "VIDEO", state: reading.videoEngine)
                        EngineLamp(name: "IMAGE", state: reading.imageEngine)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Placeholder()
            }
        }
    }
}

/// One fixed-function block: lit when it is powered up.
private struct EngineLamp: View {
    let name: String
    let state: AppleSiliconTelemetry.EngineState?

    var body: some View {
        HStack(spacing: 5) {
            LED(color: state?.isAwake == true ? Theme.green : Theme.textMuted,
                lit: state?.isAwake == true,
                size: 6)
            Text(name)
                .font(Theme.mono(8.5, .semibold))
                .tracking(0.6)
                .foregroundStyle(state == nil ? Theme.textMuted.opacity(0.5) : Theme.textSecondary)
        }
        .help(state == nil ? "\(name) is not present on this machine"
                           : "\(name) power state \(state!.current) of \(state!.maximum)")
    }
}

private struct MemoryWell: View {
    @ObservedObject var widget: MemoryTelemetryWidget

    var body: some View {
        WidgetWell(kind: .memory, readout: widget.reading.map { Format.bytes($0.total) }) {
            if let reading = widget.reading {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 10) {
                        Readout(value: Format.bytes(reading.used),
                                tint: reading.pressure > 0.8 ? Theme.red : Theme.textPrimary)
                        Spacer(minLength: 4)
                        Sparkline(values: widget.history, floor: WidgetKind.memory.plotFloor, height: 22).equatable()
                            .frame(width: 118)
                    }
                    SegmentedBar(segments: [
                        .init(fraction: fraction(reading.wired, reading.total), tint: Theme.red.opacity(0.85)),
                        .init(fraction: fraction(reading.app, reading.total), tint: Theme.orange),
                        .init(fraction: fraction(reading.compressed, reading.total), tint: Theme.green),
                    ])
                    HStack(spacing: 0) {
                        MicroStat(label: "WIRED", value: Format.bytes(reading.wired))
                        Spacer(minLength: 4)
                        MicroStat(label: "APP", value: Format.bytes(reading.app))
                        Spacer(minLength: 4)
                        MicroStat(label: "COMP", value: Format.bytes(reading.compressed))
                        Spacer(minLength: 4)
                        MicroStat(label: "SWAP", value: Format.bytes(reading.swapUsed),
                                  tint: reading.swapUsed > 0 ? Theme.orange : Theme.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Placeholder()
            }
        }
    }

    private func fraction(_ part: UInt64, _ total: UInt64) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}

private struct NetworkWell: View {
    @ObservedObject var widget: NetworkTelemetryWidget

    var body: some View {
        WidgetWell(kind: .network, readout: widget.reading.map { "\($0.interfaces) IF" }) {
            if let reading = widget.reading {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.green)
                                Readout(value: Format.rate(reading.down), size: 13)
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.orange)
                                Readout(value: Format.rate(reading.up), size: 13)
                            }
                        }
                        .frame(width: 100, alignment: .leading)

                        ZStack {
                            Sparkline(values: widget.history, floor: WidgetKind.network.plotFloor, height: 30).equatable()
                            Sparkline(values: widget.upHistory, floor: WidgetKind.network.plotFloor,
                                      tint: Theme.orange, height: 30).equatable()
                        }
                    }
                    HStack(spacing: 10) {
                        MicroStat(label: "IN", value: Format.bytes(reading.downTotal))
                        MicroStat(label: "OUT", value: Format.bytes(reading.upTotal))
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Placeholder()
            }
        }
    }

    /// Both plots share a scale, or the smaller of the two would look like the
    /// larger. A floor of 64 KB/s stops idle noise filling the well.
    private var ceiling: Double {
        max((widget.history + widget.upHistory).max() ?? 0, 64_000)
    }
}

private struct ThermalWell: View {
    @ObservedObject var widget: ThermalTelemetryWidget

    var body: some View {
        WidgetWell(kind: .thermal, readout: widget.reading?.isLowPower == true ? "LOW POWER" : nil) {
            if let reading = widget.reading {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            // The die reading when the SMC gives us one; the
                            // pressure state is what a machine without readable
                            // sensors has to fall back on.
                            if let hottest = reading.hottest {
                                Readout(value: String(format: "%.0f", hottest), unit: "°C",
                                        tint: heatTint(hottest))
                            } else {
                                Readout(value: reading.stateLabel, tint: tint(reading), size: 13)
                            }
                            SegmentGauge(level: reading.severity, tint: tint(reading))
                                .frame(width: 74)
                        }
                        Spacer(minLength: 0)
                        if let percent = reading.batteryPercent {
                            VStack(alignment: .trailing, spacing: 3) {
                                HStack(spacing: 4) {
                                    Image(systemName: batteryGlyph(reading, percent))
                                        .font(.system(size: 10))
                                        .foregroundStyle(reading.isCharging ? Theme.green : Theme.textSecondary)
                                    Readout(value: "\(percent)", unit: "%", size: 13)
                                }
                                if let minutes = reading.minutesRemaining {
                                    MicroStat(label: reading.isCharging ? "TO FULL" : "LEFT",
                                              value: Format.duration(minutes: minutes))
                                } else {
                                    MicroStat(label: "SOURCE",
                                              value: reading.onExternalPower ? "AC" : "BATTERY")
                                }
                            }
                        }
                    }

                    if reading.hottest != nil || reading.systemPower != nil {
                        HStack(spacing: 0) {
                            if let cpu = reading.cpuDie {
                                MicroStat(label: "CPU", value: String(format: "%.0f°", cpu.celsius))
                                Spacer(minLength: 4)
                            }
                            if let gpu = reading.gpuDie {
                                MicroStat(label: "GPU", value: String(format: "%.0f°", gpu.celsius))
                                Spacer(minLength: 4)
                            }
                            if let battery = reading.batteryDie {
                                MicroStat(label: "BATT", value: String(format: "%.0f°", battery.celsius))
                                Spacer(minLength: 4)
                            }
                            if let power = reading.systemPower {
                                MicroStat(label: "DRAW", value: String(format: "%.1f W", power),
                                          tint: ThermalDetailTint.power(power))
                                Spacer(minLength: 4)
                            }
                            if let fan = reading.fans.max(by: { $0.actual < $1.actual }) {
                                MicroStat(label: "FAN",
                                          value: fan.actual > 0 ? String(format: "%.0f", fan.actual) : "OFF")
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Placeholder()
            }
        }
    }

    /// Apple Silicon runs warm by design; nothing under 80 °C is worth
    /// colouring, and the throttle point is nearer 100.
    private func heatTint(_ celsius: Double) -> Color {
        celsius >= 95 ? Theme.red : (celsius >= 80 ? Theme.orange : Theme.textPrimary)
    }

    private func tint(_ reading: ThermalSampler.Reading) -> Color {
        switch reading.state {
        case .nominal: return Theme.green
        case .fair: return Theme.orange
        default: return Theme.red
        }
    }

    private func batteryGlyph(_ reading: ThermalSampler.Reading, _ percent: Int) -> String {
        if reading.isCharging { return "battery.100.bolt" }
        if percent <= 20 { return "battery.25" }
        if percent <= 60 { return "battery.50" }
        return "battery.100"
    }
}

private struct ProcessWell: View {
    @ObservedObject var widget: ProcessTelemetryWidget

    var body: some View {
        WidgetWell(kind: .processes, readout: widget.reading.map { "\($0.total) LIVE" }) {
            if let reading = widget.reading {
                VStack(spacing: 3) {
                    ForEach(reading.top) { row in
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(Format.bytes(row.footprint))
                                .font(Theme.mono(9))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textMuted)
                            Text(Format.percent(row.cpu, decimals: 1))
                                .font(Theme.mono(9.5, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(row.cpu > 0.5 ? Theme.orange : Theme.textSecondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
            } else {
                Placeholder()
            }
        }
    }
}

/// Gruppen's own line. Deliberately the last thing in the stack: a monitor
/// should be accountable for what it costs.
private struct FootprintLine: View {
    @ObservedObject var widget: FootprintTelemetryWidget

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.textMuted)
            Text("GRUPPEN")
                .font(Theme.mono(8.5, .semibold))
                .tracking(0.9)
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 6)
            if let reading = widget.reading {
                MicroStat(label: "CPU", value: Format.percent(reading.cpu, decimals: 1))
                MicroStat(label: "MEM", value: Format.bytes(reading.resident))
                MicroStat(label: "THR", value: "\(reading.threads)")
            }
        }
        .padding(.horizontal, 2)
    }
}

/// What a well shows in the frame before its first reading lands. Sized like
/// the real thing so nothing jumps when the number arrives.
private struct Placeholder: View {
    var body: some View {
        Text("———")
            .font(Theme.mono(19, .medium))
            .foregroundStyle(Theme.textMuted.opacity(0.4))
            .frame(height: 46, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
