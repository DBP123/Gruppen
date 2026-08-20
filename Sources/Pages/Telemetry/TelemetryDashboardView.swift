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

/// Whether the window this view is actually in is on screen.
///
/// `scenePhase` is the SwiftUI answer and it is the wrong one here: on macOS it
/// reports the *scene's* activation, which stays `.active` for a window that has
/// been minimised into the Dock or completely covered by another app.
///
/// The first version of this scanned `NSApp.windows` for any visible window, and
/// it did not work: Gruppen owns one `NSStatusBarWindow` per menu bar item, and
/// those are always visible, so minimising the main window changed nothing and
/// the dashboard kept sampling — measured at 2.6% of a core against 0.7% for the
/// same app on another page. Binding to the host view's own window is both
/// correct and simpler, since AppKit already reports miniaturisation and
/// occlusion per window.
@MainActor
final class WindowVisibility: ObservableObject {
    @Published private(set) var isVisible = true

    func update(_ visible: Bool) {
        if isVisible != visible { isVisible = visible }
    }
}

/// A zero-size view whose only job is to find the window it was put in and
/// report when that window comes and goes.
struct WindowVisibilityProbe: NSViewRepresentable {
    let report: (Bool) -> Void
    let reportFocus: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.report = report
        probe.reportFocus = reportFocus
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.report = report
        probe.reportFocus = reportFocus
    }

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        var reportFocus: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        /// Occlusion, as last *reported*. Deliberately not read straight off the
        /// window at publish time.
        ///
        /// AppKit guarantees it will tell you when occlusion changes; it does not
        /// guarantee the property is settled the moment a view is added. A
        /// hosting view attaches while the window server is still bringing the
        /// window up, so reading `occlusionState` there returns "not visible" for
        /// a window that is about to be on screen — and because no *change*
        /// follows, nothing ever corrects it. That cost the dashboard its
        /// modules on first appearance until the test caught it. So the initial
        /// assumption is "on screen", and only an actual notification moves it.
        private var occluded = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            unhook()
            guard let window else { report?(false); return }

            let center = NotificationCenter.default
            // Per-window, so another window's state cannot answer for this one.
            tokens.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                             object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let window = note.object as? NSWindow
                    self.occluded = !(window?.occlusionState.contains(.visible) ?? false)
                    self.publish()
                }
            })
            tokens.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification,
                                             object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
            // Coming back from the Dock or from ⌘H invalidates the last
            // occlusion reading rather than confirming it: the window was
            // occluded *because* it was away. Clearing the flag lets a genuine
            // occlusion — the window really is behind something — report itself
            // again, instead of a stale `true` keeping the dashboard dark after
            // it is plainly back on screen.
            tokens.append(center.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                                             object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restored() }
            })
            // ⌘H hides the app without touching any window's occlusion state.
            tokens.append(center.addObserver(forName: NSApplication.didHideNotification,
                                             object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
            tokens.append(center.addObserver(forName: NSApplication.didUnhideNotification,
                                             object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restored() }
            })
            // Whether Gruppen is the app in use. Not a visibility signal — it
            // only ever changes the rate — so it is reported on its own channel.
            for name in [NSApplication.didBecomeActiveNotification,
                         NSApplication.didResignActiveNotification] {
                tokens.append(center.addObserver(forName: name, object: nil,
                                                 queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportFocus?(NSApp.isActive) }
                })
            }
            reportFocus?(NSApp.isActive)
            occluded = false
            publish()
        }

        deinit { unhook() }

        private func unhook() {
            let center = NotificationCenter.default
            for token in tokens { center.removeObserver(token) }
            tokens.removeAll()
        }

        @MainActor
        private func restored() {
            occluded = false
            publish()
        }

        @MainActor
        private func publish() {
            guard let window else { report?(false); return }
            report?(window.isVisible && !window.isMiniaturized && !NSApp.isHidden && !occluded)
        }
    }
}

/// One module, as a card you can move, resize, lock and freeze.
///
/// The readout is the same view the module's menu bar popover shows — extracted
/// so there is exactly one description of what a processor readout looks like,
/// and the card and the popover cannot drift apart.
private struct TelemetryCard: View {
    let kind: WidgetKind
    let slot: Slot
    @ObservedObject var layout: DashboardLayout
    let order: [WidgetKind]
    let canvasWidth: CGFloat

    @ObservedObject private var manager = WidgetManager.shared
    @State private var hovering = false
    /// Live offsets while a gesture is in flight. Committed to the layout on
    /// release, so a drag is one write to disk rather than one per frame.
    @State private var dragOffset: CGSize = .zero
    @State private var sizeOffset: CGSize = .zero
    /// The captured picture of the readout, taken at the moment of freezing.
    @State private var frozenImage: NSImage?

    private var locked: Bool { slot.locked }
    private var frozen: Bool { manager.isFrozen(kind) }

    /// The drag handle. Deliberately the whole header strip, so "grab the top of
    /// the widget" is literally true.
    private static let headerHeight: CGFloat = 26
    /// How far in from an edge still counts as the edge.
    private static let edge: CGFloat = 7
    /// Space the three hover controls occupy. Reserved permanently so nothing
    /// shifts when they appear.
    private static let controlsWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            DashedRule()
            // A readout taller than the card scrolls inside it rather than being
            // cut off with no way to see the rest. The scroll view only takes
            // over the wheel when its content actually overflows, so on a card
            // big enough for its readout the page still scrolls normally.
            ScrollView(.vertical, showsIndicators: false) {
                readout.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: slot.width + sizeOffset.width,
               height: slot.height + sizeOffset.height,
               alignment: .topLeading)
        // The card is the size you set it to; nothing inside it pushes it open.
        .clipped()
        .machined(cornerRadius: Theme.radiusMd, fill: Theme.housing)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .strokeBorder(borderTint, lineWidth: 1)
        }
        .offset(dragOffset)
        .zIndex(dragOffset == .zero && sizeOffset == .zero ? 0 : 1)
        .onHover { hovering = $0 }
        // Order matters, and it is the reason the controls used to slip away as
        // you reached for them. The drag strip and the resize edges all carry
        // gestures, and a later overlay sits *on top* of an earlier one — so
        // with the controls added first, the strip covered them and the press
        // landed on the drag gesture instead of the button. The controls go
        // last, so nothing is ever in front of them.
        .overlay(alignment: .top) { dragStrip }
        .overlay(alignment: .trailing) { resizeEdge(.horizontal) }
        .overlay(alignment: .bottom) { resizeEdge(.vertical) }
        .overlay(alignment: .bottomTrailing) { resizeCorner }
        .overlay(alignment: .topTrailing) { controls }
    }

    private var borderTint: Color {
        if frozen { return Theme.cyan.opacity(0.45) }
        if locked { return Theme.textMuted.opacity(0.30) }
        return hovering ? Color.white.opacity(0.16) : Color.white.opacity(0.07)
    }

    // MARK: Contents

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.domain(kind.domainIndex))
            Text(kind.header)
                .font(Theme.mono(9, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            if frozen {
                Text("FROZEN")
                    .font(Theme.mono(8, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.cyan)
            }
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 6)
            // Faded rather than removed while hovering. Taking it out of the
            // layout reflowed the header under the cursor at the exact moment
            // you were reaching for the controls.
            Text(kind.badge)
                .font(Theme.mono(8, .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textMuted)
                .opacity(hovering ? 0 : 1)
        }
        // The controls sit over the trailing end of this row, so the row always
        // keeps that space clear whether they are showing or not — no geometry
        // moves when they fade in.
        .padding(.trailing, Self.controlsWidth)
        .frame(height: Self.headerHeight - 12, alignment: .center)
    }

    @ViewBuilder
    private var readout: some View {
        if frozen, let frozenImage {
            // A picture, not a paused view: the module behind this card may still
            // be running for a menu bar item, and a frozen card has to stay
            // frozen either way.
            Image(nsImage: frozenImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .saturation(0.85)
                .opacity(0.9)
        } else {
            ModuleDetailContent(kind: kind)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 4) {
            Group {
                CardButton(glyph: frozen ? "play.fill" : "snowflake",
                           tint: frozen ? Theme.cyan : Theme.textSecondary,
                           help: frozen ? "Resume sampling" : "Freeze this widget and stop sampling it") {
                    toggleFreeze()
                }
                CardButton(glyph: locked ? "lock.fill" : "lock.open",
                           tint: locked ? Theme.orange : Theme.textSecondary,
                           help: locked ? "Unlock — allow moving and resizing" : "Lock position and size") {
                    layout.toggleLock(kind, in: order, width: canvasWidth)
                }
                CardButton(glyph: "slider.horizontal.3",
                           tint: Theme.textMuted,
                           help: "Widget settings (not yet built)") {
                    // Deliberately inert. This is where the per-widget
                    // configuration page will hang; a button that silently does
                    // nothing is better than one that opens an empty sheet.
                }
                .disabled(true)
            }
            // Faded, never removed. A control that is only *built* while
            // hovering is a control that can vanish out from under the cursor
            // the instant a redraw disagrees about where the pointer is; one
            // that is always there and merely invisible cannot.
            .opacity(hovering ? 1 : 0)
        }
        .padding(8)
        .allowsHitTesting(hovering)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func toggleFreeze() {
        if frozen {
            frozenImage = nil
            manager.setFrozen(kind, false)
            return
        }
        // Capture first: only freeze if there is actually a picture to show,
        // otherwise the card would go blank and stop sampling at the same time.
        guard let image = CardSnapshot.capture(kind: kind, width: slot.width - 24) else { return }
        frozenImage = image
        manager.setFrozen(kind, true)
    }

    // MARK: Gestures

    /// The top strip moves the card.
    private var dragStrip: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: Self.headerHeight)
            // Stops short of the controls, always — a strip that only got out of
            // the way once `hovering` had propagated was still covering the
            // buttons at the moment you clicked them.
            .padding(.trailing, Self.controlsWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !locked else { return }
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard !locked else { return }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        guard !locked else { return }
                        dragOffset = .zero
                        layout.move(kind,
                                    to: CGPoint(x: slot.x + value.translation.width,
                                                y: slot.y + value.translation.height),
                                    in: order, width: canvasWidth)
                    }
            )
            .disabled(locked)
    }

    private enum Axis { case horizontal, vertical }

    private func resizeEdge(_ axis: Axis) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: axis == .horizontal ? Self.edge : nil,
                   height: axis == .vertical ? Self.edge : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !locked else { return }
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(resizeGesture(axis: axis))
            .disabled(locked)
    }

    private var resizeCorner: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !locked else { return }
                // AppKit has no public diagonal resize cursor, so the corner
                // borrows the crosshair rather than lying with a one-axis arrow.
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(resizeGesture(axis: nil))
            .disabled(locked)
    }

    /// `axis == nil` resizes both ways.
    private func resizeGesture(axis: Axis?) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !locked else { return }
                sizeOffset = CGSize(width: axis == .vertical ? 0 : value.translation.width,
                                    height: axis == .horizontal ? 0 : value.translation.height)
            }
            .onEnded { value in
                guard !locked else { return }
                sizeOffset = .zero
                layout.resize(kind,
                              to: CGSize(width: slot.width + (axis == .vertical ? 0 : value.translation.width),
                                         height: slot.height + (axis == .horizontal ? 0 : value.translation.height)),
                              in: order, width: canvasWidth)
            }
    }
}

/// One of the small round buttons that appear on a card when you hover it.
private struct CardButton: View {
    let glyph: String
    var tint: Color = Theme.textSecondary
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Renders a module's readout to a still image.
///
/// `ImageRenderer` runs the view once, off the live hierarchy, so what comes
/// back is genuinely a picture of the numbers at that instant — which is the
/// whole point. It cannot go stale and it cannot be revived by the module
/// underneath continuing to publish for some other surface.
enum CardSnapshot {
    @MainActor
    static func capture(kind: WidgetKind, width: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content:
            ModuleDetailContent(kind: kind)
                .frame(width: max(width, 200), alignment: .topLeading)
                .padding(0)
                .background(Theme.housing))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
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
                 + "sampling. Arm the ones you want in Guardrails.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Guardrails") { navigation.showingSettingsPane = true }
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
            Button("Open Guardrails") { navigation.showingSettingsPane = true }
                .industrialButton(.primary)
                .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel.opacity(0.96))
    }
}
