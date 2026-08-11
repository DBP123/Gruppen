import AppKit
import SwiftUI

// The windows a stash lives in, and the handle that moves one. All three are
// small, all three are about the same object — an NSPanel that must not steal
// focus — so they read better together than as three files.

/// The visible shelf. Non-activating and floating, so dragging into or out of
/// it never pulls focus away from the app you are working in.
final class StashPanel: NSPanel {
    /// Whether this panel is allowed to sit flush against the top of the screen.
    private let attachedToScreenTop: Bool

    init(size: NSSize, content: NSView, attachedToScreenTop: Bool = false) {
        self.attachedToScreenTop = attachedToScreenTop
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        // A panel welded to the bezel must not have a system shadow: AppKit
        // draws it around the whole frame, including the top edge, which puts a
        // dark rim across the join. The tray casts its own, downward only.
        hasShadow = !attachedToScreenTop
        hidesOnDeactivate = false
        isFloatingPanel = true
        // No implicit animation: it turns a live drag into a trailing ghost.
        animationBehavior = .none
        isMovable = true
        if attachedToScreenTop {
            // `isFloatingPanel` rewrites `level`, so this has to come after it.
            // Above `.mainMenu` is also what stops AppKit constraining the frame
            // at all; the override below is the belt to that pair of braces.
            level = .statusBar
        }
        content.frame = NSRect(origin: .zero, size: size)
        contentView = content
    }

    /// Measured: `visibleFrame` on this Mac tops out at y = 949 while the notch
    /// band runs 950…982, so the default constraint parks a "flush" panel one
    /// point clear of the bezel — a two-pixel lit seam at exactly the join that
    /// is supposed to be invisible. Panels that mean to touch the top edge opt
    /// out of being constrained at all.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        attachedToScreenTop ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A floating shelf's window: grabbable anywhere, and able to leave.
///
/// **On the dragging implementation.** The obvious reading of "handle
/// `mouseDown` and `mouseDragged`" is to track the delta yourself and call
/// `setFrameOrigin` on every event. That was the first version and it was
/// visibly wrong — the window trailed the cursor by a frame or two and left a
/// ghost, because each `setFrameOrigin` is a separate trip to the window server
/// while the drag events keep coming. `performDrag(with:)` hands the whole
/// gesture to the window server, which moves the window in its own compositor
/// pass; the window then tracks the pointer exactly, for free, and the event
/// loop is not involved at all. So `mouseDown` is overridden as asked, and what
/// it does is delegate.
final class FloatingShelfPanel: NSPanel {
    /// Set while the pointer is over something that is not a drag handle — a
    /// button, an item, the scrub track — so those still get their clicks.
    var isDragEnabled = true

    init(size: NSSize, content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        // No implicit animation: it turns a live drag into a trailing ghost.
        animationBehavior = .none
        isMovable = true
        // Deliberately *not* `isMovableByWindowBackground`. That flag lets
        // AppKit start moving the window from any drag it considers to be on the
        // background, and it cannot tell that dragging an item off the shelf is
        // meant to be a file drag — the shelf would slide across the screen
        // instead of handing over the file. The `mouseDown` override below gives
        // the same reach without that ambiguity: it is only ever called for
        // events no view underneath claimed.
        content.frame = NSRect(origin: .zero, size: size)
        contentView = content
    }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled else { super.mouseDown(with: event); return }
        performDrag(with: event)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A strip that drags its own window.
///
/// The previous version tracked a SwiftUI `DragGesture` and moved the panel by
/// hand on every change. That always trails the pointer: the gesture is
/// delivered asynchronously, each update is a separate `setFrameOrigin`, and the
/// window's own animation smooths the result into a ghost.
///
/// `performDrag(with:)` hands the whole interaction to the window server, which
/// moves the window in lockstep with the cursor — the same mechanism as dragging
/// any title bar. No per-frame work on our side and nothing to lag behind.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragHandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        /// Transparent to everything except the drag itself.
        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point)
        }
    }
}
