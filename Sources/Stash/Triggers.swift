import AppKit

// The two ways a stash is summoned without anything polling: invisible
// tripwires parked at the screen edges, and a drag monitor that only exists
// between mouse-down and mouse-up.

/// Invisible tripwires parked at the screen edges.
///
/// This is the Passive Sentinel pattern: rather than asking where the cursor is
/// many times a second, we hand the window server a few tiny transparent
/// windows and let it do the spatial hit-testing it is already doing anyway.
/// A sentinel costs nothing until a drag actually crosses it, at which point
/// AppKit calls `draggingEntered` for us. There is no polling and no timer.

/// A view that notices a drag passing over it, and never takes it.
///
/// **A sentinel is a tripwire, not a target.** It reports the crossing and
/// declines the drag — `draggingEntered` returns no operation, so the pointer
/// keeps the "this will not drop here" cursor and the sentinel never claims a
/// drop meant for the window underneath it. The coordinator then retires the
/// panel outright, which is the only way to be certain: an invisible window
/// covering part of the screen is an obstacle to every drag that crosses it,
/// whatever it answers, so the one that has done its job stops existing.
final class SentinelView: NSView {
    var onDragEntered: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff, .rtf]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Notices, then declines. Returning an empty operation is the difference
    /// between "come close and the tray appears" and "come close and the tray
    /// takes it": with `.copy` the cursor promises a drop this window has no
    /// business accepting.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
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
    /// **It reveals the tray and nothing else.** It used to be the drop target
    /// as well, on the theory that a 185pt tray is a small thing to hit while
    /// dragging — so a drop anywhere in this band landed on the notch shelf.
    /// That trade is not available: the band is invisible and covers the top
    /// centre of the screen, which is where toolbars, tab bars and the tops of
    /// windows live. Dropping a file onto any of them meant releasing inside the
    /// band, and the shelf swallowed it. A target you cannot see must never take
    /// anything, however generous the intent.
    ///
    /// So the band is a tripwire. Crossing it slides the tray out — early, and
    /// from a long way off, which is the part worth keeping — and the band then
    /// retires for the rest of the drag. From that moment the only thing that
    /// can accept the drop is the tray you can see, sitting on the notch.
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
    private var notchPanel: SentinelPanel?
    private var edgePanels: [SentinelPanel] = []
    private let onNotch: () -> Void
    private let onEdge: (NSPoint) -> Void
    /// Asked at install time, once per drag. A trigger the user has switched
    /// off never gets a window, so it costs nothing and cannot fire.
    private let notchWanted: () -> Bool
    private let edgesWanted: () -> Bool

    init(onNotch: @escaping () -> Void,
         onEdge: @escaping (NSPoint) -> Void,
         notchWanted: @escaping () -> Bool = { true },
         edgesWanted: @escaping () -> Bool = { true }) {
        self.onNotch = onNotch
        self.onEdge = onEdge
        self.notchWanted = notchWanted
        self.edgesWanted = edgesWanted
    }

    /// Puts up whatever is missing, rather than all or nothing.
    ///
    /// Every sentinel retires itself once it has fired, so by the time the notch
    /// tray withdraws and asks for its tripwire back, the edges may still be up
    /// or may have been spent. An all-or-nothing guard read the surviving edges
    /// as "already installed" and quietly declined to replace the one panel that
    /// was actually gone.
    func install() {
        // Two different screens, deliberately.
        //
        // The notch band belongs to the display that physically has the camera
        // housing — `NSScreen.main` follows keyboard focus, so one click on a
        // Sidecar iPad used to put the band over a screen with no notch on it.
        // The edge sentinels are the opposite case: "drag to a screen edge"
        // means *the screen you are working on*, which is exactly what
        // `NSScreen.main` reports.
        let notchScreen = NotchGeometryManager.shared.screen
        guard let edgeScreen = NSScreen.main ?? notchScreen else { return }

        if notchPanel == nil, notchWanted(), let screen = notchScreen {
            let panel = NotchSentinelPanel(screen: screen) { [weak self] in
                Task { @MainActor in self?.triggerNotch() }
            }
            notchPanel = panel
            panel.orderFrontRegardless()
        }

        if edgePanels.isEmpty, edgesWanted() {
            for side in [EdgeSentinelPanel.Side.left, .right] {
                let panel = EdgeSentinelPanel(side: side, screen: edgeScreen) { [weak self] in
                    Task { @MainActor in self?.triggerEdge() }
                }
                edgePanels.append(panel)
                panel.orderFrontRegardless()
            }
        }
    }

    func remove() {
        notchPanel?.orderOut(nil)
        notchPanel = nil
        edgePanels.forEach { $0.orderOut(nil) }
        edgePanels.removeAll()
    }

    /// Slides the tray out, and stands down.
    ///
    /// The band is taken off screen *before* the tray is asked for, so there is
    /// no moment where an invisible window sits above the visible one. From here
    /// to the end of the drag the only drop target near the notch is the tray
    /// itself.
    private func triggerNotch() {
        guard let panel = notchPanel else { return }
        notchPanel = nil
        panel.orderOut(nil)
        onNotch()
    }

    /// An edge fires once, then steps aside, so sliding along the side of the
    /// screen cannot breed a row of shelves.
    private func triggerEdge() {
        guard !edgePanels.isEmpty else { return }
        let spent = edgePanels
        edgePanels.removeAll()
        spent.forEach { $0.orderOut(nil) }
        onEdge(NSEvent.mouseLocation)
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
    /// Whether `onDragBegan` has run for the gesture in progress.
    ///
    /// Separate from `isDragging`, which is true from the mouse going *down*.
    /// The sentinels are only wanted once the pointer actually moves.
    private var begun = false

    private let onShake: (NSPoint) -> Void
    private let onDragBegan: () -> Void
    private let onDragEnded: () -> Void
    /// Checked once per confirmed shake, after the maths — never per event.
    private let shakeWanted: () -> Bool

    init(onShake: @escaping @MainActor (NSPoint) -> Void,
         onDragBegan: @escaping @MainActor () -> Void,
         onDragEnded: @escaping @MainActor () -> Void,
         shakeWanted: @escaping () -> Bool = { true }) {
        self.onShake = onShake
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
        self.shakeWanted = shakeWanted
    }

    /// True between mouse-down and mouse-up. The armed drag monitor *is* the
    /// flag — there is no separate bookkeeping to fall out of step with it.
    var isDragging: Bool { dragMonitor != nil }

    func start() {
        guard downMonitor == nil else { return }

        // Mouse-down only arms the drag watcher. It deliberately does **not**
        // announce a drag: `onDragBegan` puts three sentinel panels on screen,
        // and doing that on every click anywhere in the system — every button
        // press, every text selection, in any application — was Gruppen's
        // largest background cost by a wide margin. Measured on the telemetry
        // page while fully occluded: 5.07% of a core with Stash on against
        // 0.36% with it off. Clicks outnumber drags by orders of magnitude, and
        // a click that never moves needs no drop targets.
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.arm() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let announced = self.begun
                self.disarm()
                // Only balance a `began` that actually happened. A plain click
                // installed nothing, so there is nothing to tear down.
                if announced { self.onDragEnded() }
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
            Task { @MainActor in
                guard let self else { return }
                // First movement of this gesture: now it is a drag, so the drop
                // targets go up. Once per gesture, not once per event.
                if !self.begun {
                    self.begun = true
                    self.onDragBegan()
                }
                self.evaluate(event)
            }
        }
    }

    private func disarm() {
        guard let dragMonitor else { return }
        NSEvent.removeMonitor(dragMonitor)
        self.dragMonitor = nil
        resetShakeState()
    }

    private func resetShakeState() {
        begun = false
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
        guard shakeWanted(), Self.dragPasteboardHasContent() else { return }
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
