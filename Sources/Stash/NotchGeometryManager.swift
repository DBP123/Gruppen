import AppKit
import CoreGraphics

/// Where the notch is, on the display that actually has one.
///
/// ## The problem this exists to solve
///
/// Every notch surface in Stash used to start from `NSScreen.main`. That
/// property does not mean "the built-in display" — it means *the screen holding
/// the window with keyboard focus*. Connect an iPad over Sidecar, click once on
/// it, and `NSScreen.main` is the iPad. The notch tray then computes its width
/// from a display with no notch (falling back to a 200pt guess), anchors itself
/// to `iPadFrame.maxY`, and the invisible sentinels go up over a screen the
/// camera housing is not on. Universal Control does the same thing without even
/// needing a click.
///
/// So the anchor is resolved from the hardware instead, and re-resolved whenever
/// the display topology changes.
///
/// ## Why `CGDisplayIsBuiltin` and not `safeAreaInsets.top > 0`
///
/// The insets test answers "does this display have a notch", which is *not* the
/// question. The requirement is "never anchor to the iPad", and the property
/// that answers that directly is whether the display is the physical built-in
/// panel. A Sidecar iPad is a virtual display — `CGDisplayIsBuiltin` is false
/// for it by construction, whatever safe-area insets it happens to report, and
/// iPads do report safe areas. The insets are still used, second, to locate the
/// housing once the right panel has been picked.
///
/// ## On coordinate spaces, since this is where the bug usually is
///
/// `NSScreen.frame`, `NSWindow.frame` and `NSWindow.setFrame(_:display:)` are
/// all in **one** space: global AppKit coordinates, origin bottom-left of the
/// primary display, Y increasing upward. Nothing in `rectForNotchPanel` needs
/// flipping, and adding a flip "to be safe" is itself the classic cause of a
/// panel that lands correctly on a single screen and hundreds of points off once
/// a second display sits above or below the first. The flip helpers at the
/// bottom of this file exist only for Core Graphics interop — `CGDisplayBounds`
/// and `CGEvent` are top-left-origin — and are deliberately not used here.
///
/// ## Measured on this machine
///
/// ```
/// screen[0] frame=(0, 0, 1512, 982)        safeTop=32  builtin=true
///           auxL=(0, 950, 663, 32)  auxR=(848, 950, 664, 32)   → notch x 663…848
/// screen[1] frame=(-1210, 226, 1210, 756)  safeTop=0   builtin=false
/// ```
///
/// Note screen[1]: negative origin X *and* non-zero origin Y. Any arithmetic
/// that assumes a screen starts at `(0, 0)`, or that global height equals the
/// main screen's height, is already wrong on this desk.
@MainActor
final class NotchGeometryManager: ObservableObject {
    /// The panels and sentinels live outside the SwiftUI scene graph, so they
    /// read the same instance from here rather than inheriting one.
    static let shared = NotchGeometryManager()

    /// Everything the notch surfaces need, as plain values.
    ///
    /// Deliberately **not** holding the `NSScreen`. AppKit hands out fresh
    /// `NSScreen` objects when the display configuration changes, so an
    /// instance captured before a Sidecar connect is a stale object describing
    /// a topology that no longer exists — it answers `frame` with the old
    /// geometry and compares unequal to its own replacement. Storing the
    /// derived numbers and re-looking-up the screen on demand removes that
    /// whole class of bug.
    struct Anchor: Equatable {
        /// Stable across reconfiguration; this is what identifies the display.
        let displayID: CGDirectDisplayID
        /// Global AppKit frame of the anchor display.
        let frame: NSRect
        /// The camera housing, in global AppKit coordinates. Nil on a Mac with
        /// no physical notch — the tray still has somewhere to go, it is just
        /// the top centre of the screen rather than a specific cutout.
        let notch: NSRect?
        /// Height of the menu bar band: the housing's own height where there is
        /// one, the safe-area inset otherwise, and the status bar's thickness
        /// as a last resort.
        let bandHeight: CGFloat
        let isBuiltIn: Bool

        var hasPhysicalNotch: Bool { notch != nil }

        /// The X the tray centres on. The notch's own midpoint rather than the
        /// screen's: on this Mac the housing spans 663…848, whose centre is
        /// 755.5, while the screen's centre is 756.0. Half a point is half a
        /// physical pixel at 2x, and it is the difference between the tray's
        /// sides continuing the bezel and a sliver of desktop showing down one
        /// edge.
        var centreX: CGFloat { notch?.midX ?? frame.midX }
    }

    /// The current anchor. Recomputed on every display change, never stale.
    ///
    /// `@Published` so the tray's own SwiftUI body re-evaluates when the notch
    /// moves. Repositioning the window alone would leave a tray still drawn to
    /// the *previous* display's notch width — the right frame with the wrong
    /// contents in it.
    @Published private(set) var anchor: Anchor

    /// Called after the anchor actually changes — not on every notification.
    /// A Sidecar connect emits several parameter changes in a burst and most of
    /// them describe the same final layout.
    var onChange: ((Anchor) -> Void)?

    /// The live `NSScreen` for the anchor, looked up fresh each time.
    ///
    /// Nil only if the anchor display has been unplugged and no replacement has
    /// been resolved yet, which is a single runloop turn at most.
    var screen: NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == anchor.displayID }
            ?? Self.resolveScreen()
    }

    private var observer: NSObjectProtocol?
    private var coalescing: Task<Void, Never>?

    /// How long to wait for a burst of parameter changes to settle.
    ///
    /// Connecting an iPad fires `didChangeScreenParameters` several times in
    /// quick succession — display added, then resolution settled, then arranged
    /// — and re-anchoring on each one moves the panel two or three times in
    /// front of the user. 150 ms is below the threshold where a person reads the
    /// delay as lag and comfortably above the burst.
    private static let settleDelay: TimeInterval = 0.15

    private init() {
        anchor = Self.resolveAnchor()

        // `NSApplication.didChangeScreenParametersNotification` is the whole
        // story here. There is no `NSScreen.didChangeScreenParametersNotification`
        // — `NSScreen` publishes `colorSpaceDidChangeNotification` and nothing
        // else relevant — so subscribing to "both" would not compile. Verified
        // against the macOS 26 SDK rather than assumed.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersDidChange() }
        }
    }

    /// The singleton never deinitialises, but the teardown is correct anyway:
    /// an observer token that outlives its owner is the most common leak in
    /// AppKit code, and a class that only behaves when it happens to be a
    /// singleton is a trap for whoever makes a second one.
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        coalescing?.cancel()
    }

    // MARK: Re-anchoring

    private func screenParametersDidChange() {
        coalescing?.cancel()
        coalescing = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.coalescing = nil
            self.reanchor()
        }
    }

    /// Recomputes, and reports only a real change.
    ///
    /// The equality test is on the *values* — display id, frame, notch, band —
    /// precisely because the `NSScreen` objects behind them are replaced on
    /// every reconfiguration and would compare unequal every single time.
    func reanchor() {
        let next = Self.resolveAnchor()
        guard next != anchor else { return }
        anchor = next
        onChange?(next)
    }

    // MARK: Resolution

    /// Which display the notch surfaces belong on.
    ///
    /// In order, and the order is the point:
    ///
    /// 1. **Built-in and notched** — unambiguous, and the answer on every Mac
    ///    this feature was designed for.
    /// 2. **Built-in** — a notchless MacBook. The tray goes to the top centre of
    ///    the laptop's own screen, which is still the right place for it.
    /// 3. **Notched but not built-in** — vanishingly rare (a mirrored or
    ///    captured built-in panel), but if a notch exists anywhere it beats a
    ///    guess.
    /// 4. **`screens[0]`** — the documented fallback. Note that this is *not*
    ///    reliably the built-in display: it is whichever screen the menu bar is
    ///    on, which the user can move in Display settings. It is last for that
    ///    reason.
    ///
    /// A Sidecar iPad is caught by none of 1–3, which is the requirement.
    private static func resolveScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        if let s = screens.first(where: { isBuiltIn($0) && notchBounds(of: $0) != nil }) { return s }
        if let s = screens.first(where: { isBuiltIn($0) }) { return s }
        if let s = screens.first(where: { notchBounds(of: $0) != nil }) { return s }
        return screens[0]
    }

    private static func resolveAnchor() -> Anchor {
        guard let screen = resolveScreen(), let id = displayID(of: screen) else {
            // No screens at all — the display is asleep or being reconfigured
            // mid-flight. A zero anchor is honest: `rectForNotchPanel` returns
            // zero too, and callers skip rather than placing a panel nowhere.
            return Anchor(displayID: 0, frame: .zero, notch: nil,
                          bandHeight: NSStatusBar.system.thickness, isBuiltIn: false)
        }
        return Anchor(displayID: id,
                      frame: screen.frame,
                      notch: notchBounds(of: screen),
                      bandHeight: bandHeight(of: screen),
                      isBuiltIn: isBuiltIn(screen))
    }

    /// The physical laptop panel. A Sidecar or AirPlay display is virtual and
    /// answers false.
    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = displayID(of: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The camera housing, in global AppKit coordinates.
    ///
    /// Derived from the two auxiliary areas rather than from `safeAreaInsets`,
    /// because the insets give a height and no horizontal extent — and the tray
    /// has to match the housing's *sides* to read as hardware. The gap between
    /// `auxiliaryTopLeftArea.maxX` and `auxiliaryTopRightArea.minX` is the
    /// housing, by definition, on any display that has one.
    static func notchBounds(of screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        // A non-positive gap means the two areas meet: no housing between them.
        guard width > 1 else { return nil }

        var rect = NSRect(x: left.maxX, y: left.minY, width: width, height: left.height)

        // Apple documents these as being in the screen's coordinate space, which
        // for `NSScreen` is the same global space `frame` lives in — confirmed
        // on this Mac, where `auxL.maxY` is 982 and `frame.maxY` is 982. That
        // cannot be *distinguished* from a screen-local reading while the
        // display sits at the origin, so rather than trust it blindly: if the
        // rect does not land on the screen it came from, read it as local and
        // offset it. Costs one intersection test and removes the only way this
        // could silently misplace the tray on a non-origin display.
        if !screen.frame.intersects(rect) {
            rect.origin.x += screen.frame.origin.x
            rect.origin.y += screen.frame.origin.y
        }
        return rect
    }

    /// The menu bar band's height on a given screen.
    static func bandHeight(of screen: NSScreen) -> CGFloat {
        if let aux = screen.auxiliaryTopLeftArea { return aux.height }
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return NSStatusBar.system.thickness
    }

    // MARK: The helper callers actually use

    /// The exact global frame for `panel.setFrame(_, display: true)`.
    ///
    /// Centred on the notch, flush against the top edge of the anchor display.
    /// No flipping: this is already the space `NSWindow` wants.
    ///
    /// The horizontal clamp keeps the panel on the anchor screen when the panel
    /// is wider than the space either side of the notch allows — without it a
    /// wide tray on a narrow display would hang off the edge and, on an extended
    /// desktop, spill onto whatever screen happens to be adjacent.
    func rectForNotchPanel(panelSize: CGSize) -> NSRect {
        Self.rectForNotchPanel(panelSize: panelSize, on: anchor)
    }

    /// The same calculation over an explicit anchor.
    ///
    /// Split out so the geometry can be exercised against topologies that are
    /// not plugged in — an iPad above the Mac, an iPad made primary so the
    /// built-in panel no longer starts at the origin — which is exactly the
    /// arithmetic that a single-display test can never cover.
    static func rectForNotchPanel(panelSize: CGSize, on anchor: Anchor) -> NSRect {
        let frame = anchor.frame
        guard frame.width > 0, frame.height > 0 else { return .zero }

        var x = anchor.centreX - panelSize.width / 2  // notch centre, not screen centre
        // Deliberately not rounded. The housing's centre can legitimately land
        // on a half point, and on a 2x display that half point is a real pixel;
        // rounding it is what puts a sliver of bezel down one side of the tray.
        if panelSize.width <= frame.width {
            x = min(max(x, frame.minX), frame.maxX - panelSize.width)
        }

        return NSRect(x: x,
                      y: frame.maxY - panelSize.height,
                      width: panelSize.width,
                      height: panelSize.height)
    }

    /// One line describing the current topology, for the log.
    var topologyDescription: String {
        let screens = NSScreen.screens.map { screen -> String in
            let id = Self.displayID(of: screen).map(String.init) ?? "?"
            let kind = Self.isBuiltIn(screen) ? "built-in" : "external"
            let notch = Self.notchBounds(of: screen).map { " notch \($0.minX)…\($0.maxX)" } ?? ""
            return "[\(id) \(kind) \(Int(screen.frame.width))×\(Int(screen.frame.height))"
                + " @\(Int(screen.frame.minX)),\(Int(screen.frame.minY))\(notch)]"
        }
        return "anchor=\(anchor.displayID) "
            + (anchor.hasPhysicalNotch ? "notched" : "no-notch")
            + " of \(screens.joined(separator: " "))"
    }
}

// MARK: - Core Graphics interop

extension NotchGeometryManager {
    /// The global flip reference: the top of the primary display.
    ///
    /// Core Graphics measures Y downward from here; AppKit measures it upward
    /// from the primary display's *bottom*. Both are anchored to the primary
    /// display — `screens[0]` — and not to the main or the largest one, which is
    /// the detail that makes multi-display flipping go wrong.
    static var globalFlipReference: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// AppKit (bottom-left origin) → Core Graphics (top-left origin).
    ///
    /// Needed for `CGDisplayBounds`, `CGWindowListCopyWindowInfo` and synthetic
    /// `CGEvent` positions. **Not** needed for `NSWindow.setFrame`, which is why
    /// `rectForNotchPanel` does not call it.
    static func flippedToCG(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX,
               y: globalFlipReference - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// Core Graphics → AppKit. The transform is its own inverse.
    static func flippedToAppKit(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX,
               y: globalFlipReference - rect.maxY,
               width: rect.width,
               height: rect.height)
    }
}
