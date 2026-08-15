import AppKit
import SwiftUI

/// Every Gruppen item in the menu bar.
///
/// This replaced SwiftUI's `MenuBarExtra`, which can own exactly one status
/// item. Wanting three — `[CPU ▁▃▆] [MEM 34 GB] [48°C]` — means owning the
/// `NSStatusItem`s directly, so that is what this does: one dictionary of live
/// items, created when a module is pinned and removed when it is not.
///
/// All of them, and the app's own item, open the same dropdown. There is one
/// panel; the items are just different handles on it.
@MainActor
final class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    private var master: NSStatusItem?
    private var items: [WidgetKind: NSStatusItem] = [:]
    private var readouts: [WidgetKind: MenuBarReadout] = [:]
    /// One popover per module item. Created on first use and kept, because
    /// rebuilding a hosting controller on every click is visible.
    private var popovers: [WidgetKind: NSPopover] = [:]
    private let panel = MonitorPanelController()
    /// When each popover last closed, so the click that dismissed one cannot
    /// also reopen it.
    private var dismissedAt: [WidgetKind: Date] = [:]
    private static let reopenGuard: TimeInterval = 0.35
    private var outsideClick: Any?
    private var insideClick: Any?

    private override init() { super.init() }

    /// Handed the objects the panel's content needs, since a status item lives
    /// outside the scene graph and can inherit nothing from it.
    func attach(store: GroupStore, navigation: NavigationModel, settings: AppSettings) {
        panel.attach(store: store, navigation: navigation, settings: settings)
        WidgetManager.shared.onModulesChanged = { [weak self] in self?.reconcile() }
        // `start()` builds the modules and calls back into `reconcile()` here,
        // so the items and the samplers behind them come up together.
        WidgetManager.shared.start()
    }

    /// How many standalone metric items are in the menu bar, and whether the
    /// app's own item is there. Exists for the test harness, which cannot see
    /// pixels but can check that pinning a module really does produce an item.
    var itemCount: Int { items.count }
    var hasMasterItem: Bool { master != nil }
    var itemKinds: [WidgetKind] { items.keys.sorted { $0.rawValue < $1.rawValue } }
    /// The width one item is currently claiming. Also for the harness, which
    /// checks that a reading never changes it and that picking a different form
    /// does.
    func itemLength(_ kind: WidgetKind) -> CGFloat? { items[kind]?.length }

    func shutdown() {
        panel.close()
        closeAllDetails()
        popovers.removeAll()
        for (_, item) in items { NSStatusBar.system.removeStatusItem(item) }
        items.removeAll()
        readouts.removeAll()
        if let master { NSStatusBar.system.removeStatusItem(master) }
        master = nil
    }

    // MARK: Items

    /// Brings the menu bar in line with what the user has asked for. Called
    /// whenever the module set changes; adds and removes only what differs, so
    /// items that are staying do not flicker.
    func reconcile() {
        let widgets = WidgetManager.shared

        if AppSettings.shared.showMenuBar {
            if master == nil { master = makeMasterItem() }
        } else if let existing = master {
            NSStatusBar.system.removeStatusItem(existing)
            master = nil
        }

        let wanted = widgets.pinnedOrder
        for kind in items.keys where !wanted.contains(kind) {
            if let item = items.removeValue(forKey: kind) { NSStatusBar.system.removeStatusItem(item) }
            readouts.removeValue(forKey: kind)
            popovers.removeValue(forKey: kind)?.performClose(nil)
            WidgetManager.shared.detailDidClose(kind)
        }
        for kind in wanted where items[kind] == nil {
            let readout = MenuBarReadout(kind: kind, mode: widgets.mode(for: kind))
            readouts[kind] = readout
            items[kind] = makeItem(for: kind, readout: readout)
        }
        // The one thing that legitimately resizes an item: the user picking a
        // different form for it in Guardrails.
        for (kind, readout) in readouts where readout.mode != widgets.mode(for: kind) {
            readout.setMode(widgets.mode(for: kind))
            items[kind]?.length = MenuBarMetrics.itemLength(kind, readout.mode)
        }

        wireModules()
        refreshAll()
    }

    private func makeMasterItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "gruppen.master"
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Gruppen")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        return item
    }

    private func makeItem(for kind: WidgetKind, readout: MenuBarReadout) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A stable per-module name, so macOS remembers where the user dragged
        // this particular item rather than treating every item this app creates
        // as the same one.
        //
        // Worth knowing, because it looks like a bug in here and is not: when
        // the menu bar runs out of room — which on a notched display happens
        // sooner than the empty space suggests, since nothing may be placed
        // under the notch — the system simply does not show the items that do
        // not fit. They exist, they have buttons, they are sampling; they are
        // just not on screen. Measured on this machine: the master item plus
        // roughly 130 points of readouts.
        item.autosaveName = "gruppen.\(kind.rawValue)"
        guard let button = item.button else { return item }

        let host = PassThroughHostingView(rootView: MenuBarWidgetView(readout: readout))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        // A status item is sized by a number rather than by autolayout, and that
        // number is set exactly once here. It is derived from the module and the
        // form the user picked — never from the reading — so no figure can
        // resize this item, and nothing to the left of it, including other
        // applications' items, is ever asked to move.
        item.length = MenuBarMetrics.itemLength(kind, readout.mode)

        button.target = self
        button.action = #selector(togglePanel(_:))
        button.toolTip = kind.title
        return item
    }

    /// Points every live pinned module at its readout.
    ///
    /// A module publishes on the main actor whenever it samples; this is the one
    /// hook that turns that into a menu bar update, and it is the only thing
    /// driving these views. No timer of their own, no polling.
    private func wireModules() {
        let widgets = WidgetManager.shared
        for kind in items.keys {
            guard let readout = readouts[kind] else { continue }
            widgets.observe(kind) { [weak readout] sample in
                readout?.update(sample)
            }
        }
    }

    private func refreshAll() {
        let widgets = WidgetManager.shared
        for (kind, readout) in readouts {
            guard let sample = widgets.currentSample(kind) else { continue }
            readout.update(sample)
        }
    }

    // MARK: The panel

    /// Routes a click to the right thing.
    ///
    /// The app's own item opens the full panel — Gruppen's groups, the actions,
    /// everything. A module's item opens *that module's* popover and nothing
    /// else. Three pinned modules means three items, three popovers, three
    /// independent things to look at.
    @objc private func togglePanel(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { panel.toggle(from: nil); return }
        if let kind = items.first(where: { $0.value.button === button })?.key {
            toggleDetail(kind, from: button)
        } else {
            closeAllDetails()
            panel.toggle(from: button)
        }
    }

    private func toggleDetail(_ kind: WidgetKind, from button: NSStatusBarButton) {
        // Only one popover at a time: they anchor to adjacent items and two open
        // at once overlap.
        panel.close()
        if let existing = popovers[kind], existing.isShown {
            existing.performClose(nil)
            return
        }
        // The click that dismissed a popover must not also reopen it.
        //
        // `.transient` closes on mouse *down*; a button's action fires on mouse
        // *up*. So clicking an open item ran: popover dismisses itself, then the
        // action asks "is it shown?", finds it is not, and opens it again — the
        // "closes then immediately reopens" that looks like a double click. The
        // fix is to remember when each popover closed and treat a click landing
        // inside that window as the second half of the dismissal it already was.
        if let closed = dismissedAt[kind], Date().timeIntervalSince(closed) < Self.reopenGuard {
            dismissedAt[kind] = nil
            return
        }
        closeAllDetails()

        let popover = popovers[kind] ?? makePopover(for: kind)
        popovers[kind] = popover
        // Raise the module to the interactive rate *before* showing, so the
        // first frame is a live reading rather than the last one from 2 s ago.
        WidgetManager.shared.detailDidOpen(kind)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        installOutsideClickMonitor()
    }

    /// Closes the popover when you click into another application.
    ///
    /// `.transient` is documented as dismissing on "interaction outside the
    /// popover", but that means interaction *this application receives*. Gruppen
    /// is an accessory app and is usually not frontmost, so clicks in Safari or
    /// the Finder never reach it and the popover just sat there — which is not
    /// how anything else in the menu bar behaves. A global monitor sees those
    /// clicks; clicks on a status item are deliberately ignored so the button's
    /// own action still decides toggle-versus-move.
    private func installOutsideClickMonitor() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closeAllDetails() }
        }
        insideClick = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let isStatusItem = event.window?.className.contains("NSStatusBarWindow") ?? false
            let isPopover = self.popovers.values.contains { $0.isShown && $0.contentViewController?.view.window === event.window }
            if !isStatusItem, !isPopover { self.closeAllDetails() }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let insideClick { NSEvent.removeMonitor(insideClick) }
        outsideClick = nil
        insideClick = nil
    }

    private func makePopover(for kind: WidgetKind) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: ModuleDetail(kind: kind))
        popover.delegate = self
        return popover
    }

    private func closeAllDetails() {
        for (_, popover) in popovers where popover.isShown { popover.performClose(nil) }
        removeOutsideClickMonitor()
    }

    /// Closes the dropdown from inside it — an action row that has done its job.
    func dismissPanel() { panel.close() }

    // MARK: The main window

    /// Set from inside the scene, which is the only place `openWindow` exists.
    /// A status item lives outside it and cannot reach the environment, so the
    /// action is handed out rather than looked up.
    var openMainWindow: (() -> Void)?

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.title == WindowID.mainWindowTitle }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

extension MenuBarManager: NSPopoverDelegate {
    /// A popover dismissed by clicking away never runs through `toggleDetail`,
    /// so this is the only place that reliably hears about it — and without it
    /// the module would keep sampling at 2 Hz behind a closed popover, which is
    /// exactly the leak the demand-driven rule exists to prevent.
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              let kind = popovers.first(where: { $0.value === popover })?.key else { return }
        dismissedAt[kind] = Date()
        WidgetManager.shared.detailDidClose(kind)
        if !popovers.values.contains(where: \.isShown) { removeOutsideClickMonitor() }
    }
}

/// A hosting view that is decoration only.
///
/// A status item's button is the thing that gets clicked. Left to itself the
/// hosting view would swallow the mouse and the item would look alive but do
/// nothing, which is the same class of bug as the notch panel's dead close
/// button — so this one refuses every hit and lets the button underneath have
/// it.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    required init(rootView: Content) { super.init(rootView: rootView) }
}

// MARK: - Readout

/// What one standalone menu bar item is showing.
///
/// **This is where the redraw gating lives.** A pinned module publishes twice a
/// second whether or not anything about it looks different, and every publish
/// that reaches the hosting view is a trip through the window server for a view
/// that sits permanently on screen, on top of every other application. So an
/// update only propagates when it would change a pixel, and "a pixel" is meant
/// literally:
///
/// - a figure changes when its *rendered string* changes, so 14.1% and 14.9%
///   are the same reading and 14.4% to 14.6% is not;
/// - a plot changes when the line moves by at least one device pixel, which is
///   checked by quantising the whole series to integer pixel rows and comparing
///   it with the one already on screen.
///
/// The gate is applied to whichever of the three forms is *currently visible*.
/// The other two are kept current in `latest` without being published, so
/// switching mode shows the newest reading immediately and no reading before
/// then cost anything.
///
/// A machine sitting at "CPU 9%" redraws its menu bar item zero times.
@MainActor
final class MenuBarReadout: ObservableObject {
    /// Everything an item draws, in one value, so a change is exactly one
    /// `objectWillChange` rather than one per field.
    struct Frame: Equatable {
        var text = "—"
        var top = "—"
        var bottom = ""
        /// Already quantised to pixel rows, 0…`MenuBarMetrics.plotLevels`.
        var plot: [Int] = []
        /// The raw figure the badge colour is gated on — a temperature for the
        /// thermal item, unused elsewhere. Not part of what is drawn, so it is
        /// deliberately excluded from the redraw comparison below.
        var gauge: Double?
        /// Charge percentage and power state, for the battery item's glyph.
        var badgeLevel: Int?
        var powerState: PowerFlow.State?
        var condition: PowerFlow.Condition?
    }

    let kind: WidgetKind

    @Published private(set) var mode: MenuBarDisplayMode
    @Published private(set) var frame = Frame()

    /// The newest reading, published or not.
    private var latest = Frame()
    private var pending: [Double] = []

    init(kind: WidgetKind, mode: MenuBarDisplayMode) {
        self.kind = kind
        self.mode = mode
    }

    /// The user picked a different form. Whatever is newest becomes visible.
    func setMode(_ next: MenuBarDisplayMode) {
        guard next != mode else { return }
        mode = next
        if latest != frame { frame = latest }
    }

    func update(_ sample: MenuBarSample) {
        if let value = sample.value {
            pending.append(value)
            if pending.count > MenuBarMetrics.plotPoints {
                pending.removeFirst(pending.count - MenuBarMetrics.plotPoints)
            }
        }

        latest = Frame(text: sample.summary,
                       top: sample.top ?? sample.summary,
                       bottom: sample.bottom ?? "",
                       plot: quantised(pending),
                       gauge: sample.value,
                       badgeLevel: sample.batteryPercent,
                       powerState: sample.powerState,
                       condition: sample.condition)

        // Only what is on screen decides. A module in numeric mode can change
        // its second figure and its plot all day without the window server
        // hearing about it.
        let visible: Bool
        switch mode {
        case .numeric: visible = latest.text != frame.text
        case .stacked: visible = latest.top != frame.top || latest.bottom != frame.bottom
        case .sparkline where kind == .power:
            visible = latest.badgeLevel != frame.badgeLevel
                || latest.powerState != frame.powerState
                || latest.condition != frame.condition
        case .sparkline: visible = latest.plot != frame.plot
        }
        guard visible else { return }
        frame = latest
    }

    /// The series as pixel rows.
    ///
    /// Normalised across the window and then rounded to pixel rows, so the
    /// series compared to decide whether to redraw is the same series that gets
    /// drawn.
    private func quantised(_ values: [Double]) -> [Int] {
        guard !values.isEmpty else { return [] }
        let levels = Double(MenuBarMetrics.plotLevels)
        return PlotScale.normalise(values, floor: kind.plotFloor).map {
            Int(($0 * levels).rounded())
        }
    }
}

/// One standalone item's contents.
///
/// Three constraints, all of them about the window server rather than about how
/// this looks:
///
/// - **One fixed frame.** The width comes from the module and the mode, never
///   from the reading, so no figure can make this item — or any item to its
///   left, including other applications' — move.
/// - **Rasterised.** `drawingGroup()` renders the whole thing off-screen through
///   Metal into one flat texture, so a redraw composites a single layer instead
///   of walking a view tree of text and vector paths.
/// - **Monospaced digits.** With `SF Mono` this is already true by
///   construction; it is stated anyway so that a later change of face cannot
///   silently reintroduce text that jitters as the numbers change.
struct MenuBarWidgetView: View {
    @ObservedObject var readout: MenuBarReadout

    /// Whether this item draws a battery instead of a figure or a trace.
    private var showsBattery: Bool {
        readout.kind == .power && readout.mode == .sparkline
    }

    /// The domain colour, except for thermal, which is gated on the reading.
    private var tint: Color {
        readout.kind == .thermal
            ? ThermalDetailTint.heat(readout.frame.gauge)
            : Theme.domain(readout.kind.domainIndex)
    }

    var body: some View {
        HStack(spacing: MenuBarMetrics.badgeGap) {
            // Every style gets the badge — except the battery, which *is* the
            // label. "PWR" in front of a picture of a battery is the caption on
            // a photograph of a cat.
            if !showsBattery {
                // Every style gets the badge. An unlabelled number in a menu bar is
            // a number you have to remember the meaning of, and a bare line
            // graph is worse — two of them side by side are indistinguishable.
                Text(readout.kind.badge)
                    .font(.system(size: MenuBarMetrics.badgeSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                    .fixedSize()
            }
            content
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(width: showsBattery ? MenuBarMetrics.batteryWidth + 4
                                           : MenuBarMetrics.contentWidth(readout.kind, readout.mode),
                       height: MenuBarMetrics.height)
        }
        .padding(.horizontal, MenuBarMetrics.padding)
        .frame(maxHeight: .infinity)
        .drawingGroup()
    }

    @ViewBuilder private var content: some View {
        switch readout.mode {
        case .numeric:
            Text(readout.frame.text)
                .font(.system(size: MenuBarMetrics.numericSize, design: .monospaced).monospacedDigit())
                .lineLimit(1)
        case .sparkline where readout.kind == .power:
            // The battery is its own picture. A line of watts in the menu bar
            // says much less at a glance than a cell with a level in it.
            BatteryGlyph(percent: readout.frame.badgeLevel ?? 0,
                         state: readout.frame.powerState ?? .wall,
                         condition: readout.frame.condition ?? .discharging,
                         width: MenuBarMetrics.batteryWidth,
                         height: MenuBarMetrics.batteryHeight)
                .frame(width: MenuBarMetrics.batteryWidth + 4, height: MenuBarMetrics.height)
        case .sparkline:
            MenuBarSparkline(plot: readout.frame.plot, tint: tint)
                .frame(width: MenuBarMetrics.graph.width, height: MenuBarMetrics.graph.height)
        case .stacked:
            VStack(alignment: .trailing, spacing: 0) {
                Text(readout.frame.top)
                Text(readout.frame.bottom)
            }
            .font(.system(size: MenuBarMetrics.stackedSize, design: .monospaced).monospacedDigit())
            .lineLimit(1)
        }
    }
}

/// The micro-graph: a line, and a gradient under it.
///
/// It plots integers, not measurements. By the time the series reaches here it
/// has already been quantised to pixel rows by the readout — which means the
/// thing compared to decide whether to redraw and the thing actually drawn are
/// the same numbers, rather than two calculations that have to be kept in
/// agreement.
private struct MenuBarSparkline: View {
    let plot: [Int]
    var tint: Color = Theme.trace

    var body: some View {
        GeometryReader { geometry in
            let plotted = points(in: geometry.size)
            area(plotted, in: geometry.size)
                .fill(LinearGradient(colors: [tint.opacity(0.2), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    line(plotted)
                        .stroke(tint,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                )
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let levels = CGFloat(MenuBarMetrics.plotLevels)
        let slots = CGFloat(max(MenuBarMetrics.plotPoints - 1, 1))
        // Right-aligned: the newest point is at the right edge, and a partly
        // filled history occupies the right-hand part of the graph rather than
        // being stretched across all of it.
        let offset = CGFloat(max(MenuBarMetrics.plotPoints - plot.count, 0))
        // Half a point in from each edge, so a flat line at the top or the
        // bottom is not sliced in half by the frame.
        let usable = size.height - 1
        return plot.enumerated().map { index, level in
            CGPoint(x: size.width * (CGFloat(index) + offset) / slots,
                    y: 0.5 + usable * (1 - min(max(CGFloat(level) / levels, 0), 1)))
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard points.count > 1 else { return }
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    private func area(_ points: [CGPoint], in size: CGSize) -> Path {
        Path { path in
            guard points.count > 1, let last = points.last else { return }
            path.move(to: CGPoint(x: points[0].x, y: size.height))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}

// MARK: - The dropdown window

/// The one panel every menu bar item opens.
///
/// `MenuBarExtra` used to provide this. Owning it means owning the parts it did
/// quietly: where the window goes, how it dismisses, and — the one that has bitten
/// this app before — making sure a click on a panel that never becomes key is not
/// thrown away as a "first mouse" event.
@MainActor
private final class MonitorPanelController {
    private var window: DropdownPanel?
    private var store: GroupStore?
    private var navigation: NavigationModel?
    private var settings: AppSettings?

    /// Installed only while the panel is open.
    private var outsideClick: Any?
    private var insideClick: Any?

    func attach(store: GroupStore, navigation: NavigationModel, settings: AppSettings) {
        self.store = store
        self.navigation = navigation
        self.settings = settings
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Clicking an item that is already showing the panel closes it; clicking
    /// any other item moves the panel to that item.
    ///
    /// This works because the monitors below deliberately do *not* dismiss on a
    /// click that landed on a status item — so by the time the button's action
    /// runs, the panel is still open and this reads as a toggle rather than as
    /// a close followed immediately by an open.
    func toggle(from button: NSStatusBarButton?) {
        guard isOpen else { open(from: button); return }
        let sameItem = button == nil || window?.anchorButton === button
        sameItem ? close() : open(from: button)
    }

    func open(from button: NSStatusBarButton?) {
        guard let store, let navigation, let settings else { return }
        let content = MonitorPanel()
            .environmentObject(store)
            .environmentObject(navigation)
            .environmentObject(settings)
            .environmentObject(WidgetManager.shared)

        let host = FirstMouseHostingView(rootView: AnyView(content))
        host.setFrameSize(host.fittingSize)

        let panel = window ?? DropdownPanel()
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.anchorButton = button
        panel.setFrameOrigin(origin(for: panel.frame.size, under: button))
        window = panel

        WidgetManager.shared.panelDidOpen()
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func close() {
        removeMonitors()
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        // Ordering a window out does not run SwiftUI's `onDisappear`, so the
        // close signal is given by hand — otherwise every module would keep
        // sampling behind a window nobody can see.
        WidgetManager.shared.panelDidClose()
    }

    /// Dismissal, in two halves.
    ///
    /// A global monitor sees clicks that went to *another* application; a local
    /// one sees clicks that stayed inside Gruppen. Neither fires for a click on
    /// a status item, which is what lets the button's own action decide whether
    /// that click was a toggle or a move — and neither fires for a click inside
    /// the panel, which SwiftUI wants.
    private func installMonitors() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        insideClick = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let target = event.window
            let isStatusItem = target?.className.contains("NSStatusBarWindow") ?? false
            if target !== window, !isStatusItem { self.close() }
            return event
        }
    }

    private func removeMonitors() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let insideClick { NSEvent.removeMonitor(insideClick) }
        outsideClick = nil
        insideClick = nil
    }

    /// Centred under the item that was clicked, and kept on the screen.
    private func origin(for size: NSSize, under button: NSStatusBarButton?) -> NSPoint {
        guard let button, let buttonWindow = button.window else { return .zero }
        let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let margin: CGFloat = 8

        var x = frame.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        }
        return NSPoint(x: x, y: frame.minY - size.height - 4)
    }
}

/// The dropdown's window.
///
/// Key but not activating: it has to take clicks like a normal window — a panel
/// that cannot become key discards every click as "first mouse" — while leaving
/// whatever app you were using in front.
private final class DropdownPanel: NSPanel {
    /// Which status item the panel is currently hanging from.
    weak var anchorButton: NSStatusBarButton?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 306, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape shuts it, the way a menu does.
    override func cancelOperation(_ sender: Any?) {
        MenuBarManager.shared.dismissPanel()
    }
}

/// The panel's content. `acceptsFirstMouse` is not optional here: the app is
/// usually not frontmost when the dropdown opens, and without it the first
/// click on any button in the panel is eaten activating the window.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    required init(rootView: AnyView) { super.init(rootView: rootView) }
}
