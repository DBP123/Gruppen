import SwiftUI

/// Mission control for telemetry.
///
/// Every hardware module Gruppen can read, with the three switches that decide
/// what it costs you. They are deliberately separate rather than one "on":
///
/// - **Telemetry** is the outer one. Off means the module does not exist — no
///   timer, no IORegistry handle, no SMC connection. Nothing about the other
///   two switches can bring it back.
/// - **Panel** puts it in the dropdown, where it refreshes at 2 Hz while you
///   are looking at it and stops the moment you close it.
/// - **Menu bar** gives it its own item, which is the only setting that costs
///   anything while the dropdown is shut — 0.5 Hz, permanently.
///
/// The panel row and the menu bar row are both greyed out when telemetry is
/// off, because a preference that cannot take effect should not look live.
struct TelemetrySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var widgets = WidgetManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SystemHeroBanner()
                master
                modules
                legend
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel.grain(0.26))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sections

    private var master: some View {
        LabeledSection(label: "TELEMETRY") {
            SettingToggle(title: "System monitor",
                          detail: "The master switch — off stops every module below",
                          isOn: $settings.showPerformanceMonitor)
        }
    }

    private var modules: some View {
        LabeledSection(label: "HARDWARE MODULES") {
            HStack(spacing: 0) {
                Text("MODULE")
                    .font(Theme.mono(9, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                ColumnHeader("TELEMETRY")
                ColumnHeader("PANEL")
                ColumnHeader("MENU BAR")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)

            ForEach(WidgetKind.configurable) { kind in
                ModuleRow(kind: kind)
                    .opacity(settings.showPerformanceMonitor ? 1 : 0.4)
                    .disabled(!settings.showPerformanceMonitor)
            }
        }
    }

    private var legend: some View {
        LabeledSection(label: "WHAT THIS COSTS") {
            VStack(alignment: .leading, spacing: 7) {
                CostLine(mark: "2 Hz", detail: "Modules in the dropdown, only while the dropdown is open.")
                CostLine(mark: "0.5 Hz", detail: "Modules with their own menu bar item, whether or not it is open.")
                CostLine(mark: "0 Hz", detail: "Everything else. Not paused — the module and its kernel handles "
                         + "are destroyed, and rebuilt when you ask for them again.")
                CostLine(mark: "DRAW", detail: "A menu bar item redraws only when its figure changes or its "
                         + "line moves by a pixel, and it never changes width. A reading that looks "
                         + "the same costs nothing to show.")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .machined(cornerRadius: Theme.radiusMd, fill: Theme.well)

        }
    }
}

// MARK: - Rows

private struct ColumnHeader: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(9, .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textMuted)
            .frame(width: 78)
    }
}

/// One module and its three switches.
private struct ModuleRow: View {
    let kind: WidgetKind
    @ObservedObject private var widgets = WidgetManager.shared
    @State private var hovering = false

    init(kind: WidgetKind) { self.kind = kind }

    private var armed: Bool { widgets.isArmed(kind) }

    /// The appearance picker only exists while the module has an item to apply
    /// it to. A control for a thing that is not there is worse than no control.
    private var showsAppearance: Bool { armed && kind.isPinnable && widgets.isPinned(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switches
            if showsAppearance {
                DashedRule().padding(.top, 10)
                appearance.padding(.top, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.03) : .clear)
        )
        .machined(cornerRadius: Theme.radiusSm)
        .onHover { hovering = $0 }
    }

    private var switches: some View {
        HStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: kind.glyph)
                    .font(.system(size: 13))
                    .foregroundStyle(armed ? Theme.orange : Theme.textMuted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(Theme.sans(13, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(kind.blurb)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)

            Switch(on: armed) { widgets.setArmed(kind, $0) }
            Switch(on: widgets.isInPanel(kind), enabled: armed) { widgets.setInPanel(kind, $0) }
            if kind.isPinnable {
                Switch(on: widgets.isPinned(kind), enabled: armed) { widgets.setPinned(kind, $0) }
            } else {
                // A five-row table has no one-line form, so there is nothing to
                // put in the menu bar. Saying so beats a switch that does nothing.
                Text("—")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted.opacity(0.6))
                    .frame(width: 78)
                    .help("A table has no one-line form for the menu bar")
            }
        }
    }

    /// What the standalone item looks like.
    private var appearance: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("MENU BAR STYLE")
                    .font(Theme.mono(9, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textMuted)
                Text(widgets.mode(for: kind).detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { widgets.mode(for: kind) },
                                          set: { widgets.setMode($0, for: kind) })) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 214)
        }
    }
}

/// One column's switch, sized so the three columns line up whatever is in them.
private struct Switch: View {
    let on: Bool
    var enabled: Bool = true
    let change: (Bool) -> Void

    var body: some View {
        Toggle("", isOn: Binding(get: { on }, set: change))
            .labelsHidden()
            .toggleStyle(.industrial)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .frame(width: 78)
    }
}

private struct CostLine: View {
    let mark: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(mark)
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Theme.orange)
                .frame(width: 44, alignment: .leading)
            Text(detail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
