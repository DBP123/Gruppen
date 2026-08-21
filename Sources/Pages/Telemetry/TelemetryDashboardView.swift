import AppKit
import Combine
import SwiftUI

/// The landing page: every armed hardware module, live, as a grid of cards.
///
/// ## What makes this cheap
///
/// Nothing here polls. The cards read `@Published` readings from modules that
/// `WidgetManager` owns, and this view's only job in that arrangement is to say
/// when it is being looked at. It says so through two signals, and both of them
/// matter:
///
/// - `onAppear` / `onDisappear` — navigating to Stash removes this view from the
///   hierarchy, which tears every dashboard module down.
/// - Window visibility — minimising the window, hiding the app, or burying it
///   behind a full-screen window does *not* fire `onDisappear`. AppKit's
///   occlusion state does, and it is the signal that stops a monitor from
///   sampling a machine nobody is watching.
///
/// Neither one throttles anything. A module with no reason to exist is
/// destroyed: its timer is cancelled, its SMC connection closed and its
/// IORegistry handles released. Returning to the page builds it again. That is
/// the difference between 0 Hz and a slow timer, and it is the whole argument
/// for this app existing next to iStat Menus.
struct TelemetryDashboardView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: NavigationModel
    @ObservedObject private var manager = WidgetManager.shared
    @StateObject private var window = WindowVisibility()
    @StateObject private var layout = DashboardLayout()
    var body: some View {
        // One `GeometryReader` around both halves, and the measured width passed
        // down as a plain argument.
        //
        // It used to be measured here and written into `@State` so the toolbar
        // could read it, which was a feedback loop: writing the state
        // re-laid-out the page, the new layout re-measured, and a one-point
        // difference — a scroll bar appearing, say — was enough to keep it
        // ping-ponging. The page redrew continuously at display rate and burned
        // ~20% of a core doing it, with the telemetry master switch *off* and
        // nothing on screen to draw. Nothing here needs mutable state.
        GeometryReader { geometry in
            let order = manager.dashboardOrder
            let available = max(Slot.defaultSize.width, geometry.size.width - 36)
            VStack(spacing: 0) {
                toolbar(order: order, available: available)
                board(order: order, available: available)
            }
        }
        .background(Theme.panel.grain(0.26))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay { if !settings.showPerformanceMonitor { MonitorOffNotice() } }
        .background(WindowVisibilityProbe(report: { window.update($0) },
                                          reportFocus: { WidgetManager.shared.dashboardDidChangeFocus($0) })
            .frame(width: 0, height: 0))
        // The two halves of the lifecycle rule.
        .onAppear { refreshDemand() }
        .onDisappear {
            WidgetManager.shared.dashboardDidDisappear()
            // Freezes are per-session. Leaving them set would mean coming back
            // to a board of numbers from whenever you last looked.
            WidgetManager.shared.thawAll()
        }
        .onChange(of: window.isVisible) { _ in refreshDemand() }
    }

    private func toolbar(order: [WidgetKind], available: CGFloat) -> some View {
        let arranged = layout.isCustomised(order: order, width: available)
        return HStack(spacing: 10) {
            Text("BOARD")
                .font(Theme.mono(9, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textMuted)
            Text(arranged ? "ARRANGED" : "DEFAULT LAYOUT")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textMuted.opacity(0.8))
            Spacer()
            if !manager.frozen.isEmpty {
                Button("Thaw \(manager.frozen.count)") { manager.thawAll() }
                    .industrialButton(.secondary)
                    .help("Resume every frozen widget")
            }
            Button("Reset Layout") { layout.reset() }
                .industrialButton(.secondary)
                .disabled(!arranged)
                .help("Put every widget back to the same size, in order")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.45)).frame(height: 1) }
    }

    /// The window's width decides how many columns the *default* board has:
    /// widen the app and the untouched layout fills the space with more cards per
    /// row rather than leaving a margin. Once you have arranged a card yourself
    /// its stored slot wins, because a layout you set by hand should not
    /// rearrange itself when you resize the window.
    private func board(order: [WidgetKind], available: CGFloat) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 14) {
                // Above the board rather than on it: the machine's identity is
                // the context every card is read against, and it is the one
                // thing here that never moves.
                SystemHeroBanner()
                    .frame(width: min(available, 920))

                if order.isEmpty {
                    NoModulesNotice().frame(width: min(available, 920))
                } else {
                    canvas(order, available: available)
                }
            }
            .padding(18)
        }
        .scrollContentBackground(.hidden)
    }

    /// The free-placement surface. A `ZStack` with each card at its own offset,
    /// sized to contain them all so the scroll view knows how far it can go.
    private func canvas(_ order: [WidgetKind], available: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(order) { kind in
                let slot = layout.slot(for: kind, order: order, width: available)
                TelemetryCard(kind: kind, slot: slot, layout: layout,
                              order: order, canvasWidth: available)
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: slot.x, y: slot.y)
            }
        }
        .frame(width: boardWidth(order, available),
               height: layout.canvasHeight(for: order, width: available),
               alignment: .topLeading)
    }

    private func boardWidth(_ order: [WidgetKind], _ available: CGFloat) -> CGFloat {
        order.reduce(CGFloat.zero) { widest, kind in
            let slot = layout.slot(for: kind, order: order, width: available)
            return max(widest, slot.x + slot.width)
        }
    }

    /// One place decides, so the two signals cannot disagree about the answer.
    private func refreshDemand() {
        if window.isVisible {
            WidgetManager.shared.dashboardDidAppear()
        } else {
            WidgetManager.shared.dashboardDidDisappear()
        }
    }
}

/// Every module is armed off. Distinct from the master switch being off, and
/// worth saying differently — the fix is in the same place either way.
private struct NoModulesNotice: View {
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No hardware modules are armed")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Telemetry is on, but every module is switched off, so nothing is "
                 + "sampling. Arm the ones you want in telemetry settings.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Telemetry Settings") { navigation.showingSettingsPane = true }
                .industrialButton(.secondary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(cornerRadius: Theme.radiusMd, fill: Theme.well)
    }
}

/// Shown when the master switch is off, instead of an empty grid that looks
/// broken.
private struct MonitorOffNotice: View {
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.open.with.lines.needle.33percent")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(Theme.textMuted)
            Text("Telemetry is switched off")
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("No module is sampling and nothing is running in the background.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
            Button("Open Telemetry Settings") { navigation.showingSettingsPane = true }
                .industrialButton(.primary)
                .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel.opacity(0.96))
    }
}
