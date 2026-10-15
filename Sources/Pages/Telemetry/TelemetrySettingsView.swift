import SwiftUI

/// What telemetry reads, and where each reading shows up.
///
/// One switch per module, and two options of it:
///
/// - **The switch** is whether the module exists at all. Off means no timer,
///   no IORegistry handle, no SMC connection.
/// - **Panel** puts it in the dropdown, which refreshes at 2 Hz only while it
///   is open.
/// - **Menu bar** gives it an item of its own — the one choice that costs
///   anything while the dropdown is shut — with its style key beside it.
///
/// The options are pills that appear only while the module is on, the same
/// way the stash's triggers sit under "Enable stashes": an option of a module
/// that is not running is a control that does nothing. What each module reads
/// is the title's tooltip rather than a line of grey under it.
struct TelemetrySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var widgets = WidgetManager.shared

    private var armedCount: Int { WidgetKind.configurable.filter(widgets.isArmed).count }

    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(rail: settings.showPerformanceMonitor ? Theme.orange : nil) {
                    SwitchRow(title: "Enable telemetry",
                              badge: "\(armedCount)/\(WidgetKind.configurable.count) AKTIV",
                              isOn: $settings.showPerformanceMonitor)
                }
                if settings.showPerformanceMonitor {
                    SettingsCard {
                        ForEach(WidgetKind.configurable) { kind in
                            if kind != WidgetKind.configurable.first { CardDivider() }
                            ModuleRow(kind: kind)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: settings.showPerformanceMonitor)
        }
    }
}

/// One module: its switch, and while it is on, where it appears.
///
/// Every slot has a fixed width, so the pills line up in columns down the card
/// whatever each row is showing. The menu bar style key sits at the left of
/// the group, where an empty slot is just more of the gap after the title.
private struct ModuleRow: View {
    let kind: WidgetKind
    @ObservedObject private var widgets = WidgetManager.shared

    private var armed: Bool { widgets.isArmed(kind) }
    private var pinned: Bool { kind.isPinnable && widgets.isPinned(kind) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.glyph)
                .font(.system(size: 13))
                .foregroundStyle(armed ? Theme.orange : Theme.textMuted)
                .frame(width: 20)
            Text(kind.title)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textPrimary)
                .help(kind.blurb)
            Spacer(minLength: 12)

            Group {
                if armed && pinned && kind.hasMenuBarStyles { styleKey }
            }
            .frame(width: 96, alignment: .trailing)

            Group {
                if armed {
                    OptionPill(title: "Panel", isOn: binding(widgets.isInPanel, widgets.setInPanel))
                        .help("Show in the menu bar dropdown")
                }
            }
            .frame(width: 78)

            Group {
                if armed && kind.isPinnable {
                    OptionPill(title: "Menu bar", isOn: binding(widgets.isPinned, widgets.setPinned))
                        .help("Give it a menu bar item of its own")
                }
            }
            .frame(width: 100)

            Toggle("", isOn: binding(widgets.isArmed, widgets.setArmed))
                .labelsHidden()
                .toggleStyle(.industrial)
                .padding(.leading, 6)
        }
        .cardRow()
        .animation(.easeOut(duration: 0.15), value: armed)
    }

    /// How the menu bar item draws itself.
    private var styleKey: some View {
        Menu {
            ForEach(MenuBarDisplayMode.allCases) { mode in
                Button(mode.label) { widgets.setMode(mode, for: kind) }
            }
        } label: {
            MenuKeyLabel(title: widgets.mode(for: kind).label)
        }
        .menuKey(compact: true)
        .help("Menu bar style")
    }

    private func binding(_ get: @escaping (WidgetKind) -> Bool,
                         _ set: @escaping (WidgetKind, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { get(kind) }, set: { set(kind, $0) })
    }
}
