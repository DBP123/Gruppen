import AppKit

// The two ways a stash is summoned without anything polling: invisible drop
// targets parked at the screen edges, and a drag monitor that only exists
// between mouse-down and mouse-up.

/// Invisible drag targets parked at the screen edges.
///
/// This is the Passive Sentinel pattern: rather than asking where the cursor is
/// many times a second, we hand the window server a few tiny transparent
/// windows and let it do the spatial hit-testing it is already doing anyway.
/// A sentinel costs nothing until a drag actually crosses it, at which point
/// AppKit calls `draggingEntered` for us. There is no polling and no timer.

/// A view that exists only to receive drags.
final class SentinelView: NSView {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    /// When set, the sentinel accepts the drop itself rather than only
    /// revealing the tray. This is what gives the notch a target far larger
    /// than the tray you can see.
    var onItems: (([StashItem]) -> Void)?
    var onDropAccepted: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff, .rtf]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { onItems != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let onItems else { return false }
        onDropAccepted?()
        IngestionManager.ingest(sender) { items in onItems(items) }
        return true
    }
}

/// Shared configuration for every sentinel window.
class SentinelPanel: NSPanel {
    init(frame: NSRect, onDragEntered: @escaping () -> Void) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        // Order matters: `isFloatingPanel` rewrites `level`, so setting the
        // level first left these sitting at .floating (3) instead of
        // .statusBar (25) — below the menu bar, where a drag never reached
        // them.
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isMovable = false
        hidesOnDeactivate = false

        let view = SentinelView(frame: NSRect(origin: .zero, size: frame.size))
        view.onDragEntered = onDragEntered
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Sits across the notch, or across the top centre on machines without one.
final class NotchSentinelPanel: SentinelPanel {
    /// A band across the top centre.
    ///
    /// **Not** the gap between the auxiliary areas: that gap *is* the camera
    /// housing, so a sentinel placed there covers a part of the display that
    /// physically does not exist and can never be dragged onto. This spans the
    /// notch plus the menu bar either side of it, and reaches far enough down
    /// that a drag heading upward crosses it well before the bezel.
    ///
    /// It is also the drop target, not just the trigger. The visible tray is
    /// exactly notch-width because that is what sells the illusion, but 185pt is
    /// a small thing to hit while dragging — aiming at it meant overshooting
    /// into the bezel and having to come back down. This band is wider than the
    /// tray on both sides and deeper than it below, and a drop anywhere in it
    /// lands on the notch shelf. You aim at the notch; you do not have to hit
    /// it.
    static let height: CGFloat = 190
    /// How far past the notch, on each side, still counts as the notch.
    static let sideReach: CGFloat = 190

    static func frame(for screen: NSScreen) -> NSRect {
        let full = screen.frame

        var width: CGFloat = 420
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = max((right.minX - left.maxX) + sideReach * 2, 380)
        }

        return NSRect(x: full.midX - width / 2,
                      y: full.maxY - height,
                      width: width,
                      height: height)
    }

    convenience init(screen: NSScreen, onDragEntered: @escaping () -> Void) {
        self.init(frame: Self.frame(for: screen), onDragEntered: onDragEntered)
    }
}

/// A 4pt strip down the left or right edge of the screen.
final class EdgeSentinelPanel: SentinelPanel {
    enum Side { case left, right }

    /// 4pt (as originally specified) is far too thin to hit reliably during a
    /// drag, and the Dock sits on top of it. 16pt is still invisible but is
    /// actually reachable.
    static let thickness: CGFloat = 16

    static func frame(for side: Side, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let x = side == .left ? visible.minX : visible.maxX - thickness
        // Keep clear of the corners so it can't fight Hot Corners or the
        // notch band above.
        let inset: CGFloat = 80
        return NSRect(x: x,
                      y: visible.minY + inset,
                      width: thickness,
                      height: max(visible.height - inset * 2, 100))
    }

    convenience init(side: Side, screen: NSScreen, onDragEntered: @escaping () -> Void) {
        self.init(frame: Self.frame(for: side, on: screen), onDragEntered: onDragEntered)
    }
}

/// Owns the sentinel windows and puts them up or takes them down.
///
/// They are only on screen **while a drag is in progress**. Invisible windows
/// at `.statusBar` level covering the menu bar and the screen edges would
/// otherwise swallow ordinary clicks — including clicks on the menu bar itself.
/// Mouse-down puts them up, mouse-up takes them down, so they exist exactly
/// when a drag could reach them and never otherwise.
@MainActor
final class SentinelCoordinator {
    private var panels: [SentinelPanel] = []
    private var edgePanels: [SentinelPanel] = []
    private let onNotch: () -> Void
    private let onNotchExited: () -> Void
    private let onNotchItems: ([StashItem]) -> Void
    private let onNotchDropAccepted: () -> Void
    private let onEdge: (NSPoint) -> Void

    init(onNotch: @escaping () -> Void,
         onNotchExited: @escaping () -> Void,
         onNotchItems: @escaping ([StashItem]) -> Void,
         onNotchDropAccepted: @escaping () -> Void,
         onEdge: @escaping (NSPoint) -> Void) {
        self.onNotch = onNotch
        self.onNotchExited = onNotchExited
        self.onNotchItems = onNotchItems
        self.onNotchDropAccepted = onNotchDropAccepted
        self.onEdge = onEdge
    }

    func install() {
        guard panels.isEmpty, let screen = NSScreen.main else { return }

        let notch = NotchSentinelPanel(screen: screen) { [weak self] in
            Task { @MainActor in self?.onNotch() }
        }
        if let view = notch.contentView as? SentinelView {
            view.onDragExited = { [weak self] in
                Task { @MainActor in self?.onNotchExited() }
            }
            view.onDropAccepted = { [weak self] in
                Task { @MainActor in self?.onNotchDropAccepted() }
            }
            view.onItems = { [weak self] items in
                Task { @MainActor in self?.onNotchItems(items) }
            }
        }
        panels.append(notch)

        for side in [EdgeSentinelPanel.Side.left, .right] {
            let panel = EdgeSentinelPanel(side: side, screen: screen) { [weak self] in
                Task { @MainActor in self?.triggerEdge() }
            }
            edgePanels.append(panel)
            panels.append(panel)
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    func remove() {
        guard !panels.isEmpty else { return }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        edgePanels.removeAll()
    }

    /// The notch band stays up for the whole drag — it *is* the drop target now.
    /// An edge only fires once, then steps aside, so sliding along the side of
    /// the screen cannot breed a row of shelves.
    private func triggerEdge() {
        guard !edgePanels.isEmpty else { return }
        onEdge(NSEvent.mouseLocation)
        edgePanels.forEach { panel in
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
        edgePanels.removeAll()
    }
}

/// Shake-to-shelf, with a monitor that only exists while the mouse is down.
///
/// The lifecycle is the whole point. A permanently installed
/// `.leftMouseDragged` monitor fires for every drag anywhere on the system; an
/// always-on `.mouseMoved` monitor is worse still. Here:
///
/// * `.leftMouseDown` **arms** the drag monitor,
/// * `.leftMouseUp` **disarms** it immediately.
///
/// So the only monitor alive while you are not holding the button is a
/// mouse-down watcher, which fires once per click. Inside the armed monitor the
/// work is throttled to ~60Hz and done in integer arithmetic, and the pasteboard
/// — the expensive, cross-process part — is not touched until the shake has
/// already been confirmed mathematically.
@MainActor
final class DragMonitor {
    /// One frame at 60Hz.
    private static let throttle: TimeInterval = 0.016
    /// Movement below this is jitter, not a shake.
    private static let minimumTravel = 5
    /// Direction flips needed to call it a shake.
    private static let requiredReversals = 3
    /// Reversals must land inside this window to count together.
    private static let window: TimeInterval = 0.5

    private var downMonitor: Any?
    private var upMonitor: Any?
    private var dragMonitor: Any?

    private var lastTimestamp: TimeInterval = 0
    private var lastDirection = 0
    private var reversals = 0
    private var windowStart: TimeInterval = 0
    private var firedThisDrag = false

    private let onShake: (NSPoint) -> Void
    private let onDragBegan: () -> Void
    private let onDragEnded: () -> Void

    init(onShake: @escaping @MainActor (NSPoint) -> Void,
         onDragBegan: @escaping @MainActor () -> Void,
         onDragEnded: @escaping @MainActor () -> Void) {
        self.onShake = onShake
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
    }

    var isRunning: Bool { downMonitor != nil }

    /// True between mouse-down and mouse-up. The armed drag monitor *is* the
    /// flag — there is no separate bookkeeping to fall out of step with it.
    var isDragging: Bool { dragMonitor != nil }

    func start() {
        guard downMonitor == nil else { return }

        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.arm()
                self?.onDragBegan()
            }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                self?.disarm()
                self?.onDragEnded()
            }
        }
    }

    func stop() {
        disarm()
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        downMonitor = nil
        upMonitor = nil
    }

    // MARK: Armed lifecycle

    private func arm() {
        guard dragMonitor == nil else { return }
        resetShakeState()
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            Task { @MainActor in self?.evaluate(event) }
        }
    }

    private func disarm() {
        guard let dragMonitor else { return }
        NSEvent.removeMonitor(dragMonitor)
        self.dragMonitor = nil
        resetShakeState()
    }

    private func resetShakeState() {
        lastTimestamp = 0
        lastDirection = 0
        reversals = 0
        windowStart = 0
        firedThisDrag = false
    }

    // MARK: Detection

    private func evaluate(_ event: NSEvent) {
        guard !firedThisDrag else { return }

        // Throttle: at most one evaluation per frame.
        let now = event.timestamp
        guard now - lastTimestamp >= Self.throttle else { return }
        lastTimestamp = now

        // Integer maths, and ignore micro-jitter outright.
        let deltaX = Int(event.deltaX)
        guard abs(deltaX) >= Self.minimumTravel else { return }

        let direction = deltaX > 0 ? 1 : -1
        if now - windowStart > Self.window {
            windowStart = now
            reversals = 0
        }
        if lastDirection != 0, direction != lastDirection {
            reversals += 1
        }
        lastDirection = direction

        guard reversals >= Self.requiredReversals else { return }

        // Only now is it worth paying for cross-process pasteboard access.
        firedThisDrag = true
        guard Self.dragPasteboardHasContent() else { return }
        onShake(NSEvent.mouseLocation)
    }

    /// Whether the current drag carries anything worth shelving. One read,
    /// after the shake maths has already passed — never speculative.
    static func dragPasteboardHasContent() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        return pasteboard.availableType(from: [.fileURL, .URL, .string]) != nil
    }

    deinit {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
    }
}
