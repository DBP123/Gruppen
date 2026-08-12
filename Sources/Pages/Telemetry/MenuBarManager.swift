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
    private let panel = MonitorPanelController()

    private override init() { super.init() }

    /// Handed the objects the panel's content needs, since a status item lives
    /// outside the scene graph and can inherit nothing from it.
    func attach(store: GroupStore, navigation: NavigationModel, settings: AppSettings) {
        panel.attach(store: store, navigation: navigation, settings: settings)
        WidgetManager.shared.onModulesChanged = { [weak self] in self?.reconcile() }
        reconcile()
    }

    /// How many standalone metric items are in the menu bar, and whether the
    /// app's own item is there. Exists for the test harness, which cannot see
    /// pixels but can check that pinning a module really does produce an item.
    var itemCount: Int { items.count }
    var hasMasterItem: Bool { master != nil }
    var itemKinds: [WidgetKind] { items.keys.sorted { $0.rawValue < $1.rawValue } }

    func shutdown() {
        panel.close()
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
        }
        for kind in wanted where items[kind] == nil {
            let readout = MenuBarReadout(kind: kind)
            readouts[kind] = readout
            items[kind] = makeItem(for: kind, readout: readout)
        }

        wireModules()
        refreshAll()
    }

    private func makeMasterItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Gruppen")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        return item
    }

    private func makeItem(for kind: WidgetKind, readout: MenuBarReadout) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return item }

        let host = PassThroughHostingView(rootView: MenuBarItemView(readout: readout))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        // Menu bar items are sized by a number, not by autolayout, so the width
        // has to be measured and pushed. Only when the string's *length*
        // changed, and a run loop turn later so SwiftUI has laid the new text
        // out — a figure ticking between two digits must never make the whole
        // menu bar shuffle sideways.
        readout.onWidthChange = { [weak item, weak host] in
            guard let item, let host else { return }
            DispatchQueue.main.async {
                host.layoutSubtreeIfNeeded()
                item.length = max(host.fittingSize.width, 24)
            }
        }
        item.length = max(host.fittingSize.width, 24)

        button.target = self
        button.action = #selector(togglePanel(_:))
        button.toolTip = "\(kind.title) — click for the full panel"
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
            widgets.observe(kind) { [weak readout] summary, value in
                readout?.update(text: summary, value: value)
            }
        }
    }

    private func refreshAll() {
        let widgets = WidgetManager.shared
        for (kind, readout) in readouts {
            guard let (summary, value) = widgets.currentSummary(kind) else { continue }
            readout.update(text: summary, value: value)
        }
    }

    // MARK: The panel

    @objc private func togglePanel(_ sender: Any?) {
        panel.toggle(from: sender as? NSStatusBarButton)
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
/// that sits permanently on screen. So an update only propagates when it would
/// change a pixel: the rendered text differs, or the plotted value has moved by
/// more than a hundredth. A machine sitting at "CPU 9%" redraws its menu bar
/// item zero times.
@MainActor
final class MenuBarReadout: ObservableObject {
    let kind: WidgetKind

    @Published private(set) var text: String = "—"
    @Published private(set) var samples: [Double] = []

    /// Called when the item may need to be wider or narrower.
    var onWidthChange: (() -> Void)?

    /// Smallest movement worth a redraw, as a fraction of the plot's height.
    private static let threshold = 0.01
    /// Points in the micro-graph.
    private static let historyLength = 24

    private var publishedValue: Double?
    private var pending: [Double] = []

    /// Only the modules with a shape worth drawing get a graph; a battery
    /// percentage as a line is noise.
    var showsGraph: Bool { kind == .cpu || kind == .silicon || kind == .network }

    init(kind: WidgetKind) { self.kind = kind }

    func update(text newText: String, value: Double?) {
        if let value {
            pending.append(value)
            if pending.count > Self.historyLength { pending.removeFirst(pending.count - Self.historyLength) }
        }

        let textChanged = newText != text
        let moved = value.map { candidate in
            publishedValue.map { abs(candidate - $0) >= Self.threshold } ?? true
        } ?? false
        guard textChanged || moved else { return }

        let widthChanged = newText.count != text.count
        text = newText
        samples = pending
        publishedValue = value
        if widthChanged { onWidthChange?() }
    }
}

/// One item's contents: an optional micro-graph, then the figure.
private struct MenuBarItemView: View {
    @ObservedObject var readout: MenuBarReadout

    var body: some View {
        HStack(spacing: 4) {
            if readout.showsGraph {
                MenuBarSparkline(values: readout.samples)
                    .frame(width: 26, height: 11)
            }
            Text(readout.text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A 26×11 plot. Deliberately plain: at this size a fill and a stroke are one
/// smudge, so it is a stroke and a baseline.
private struct MenuBarSparkline: View {
    var values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let ceiling = max(values.max() ?? 1, 0.08)
            let slots = max(values.count - 1, 1)
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(slots)
                    let y = size.height * (1 - CGFloat(min(max(value / ceiling, 0), 1)))
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color(nsColor: .labelColor), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
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
