import AppKit
import SwiftUI

/// Drags items off a stash, as a copy or as a move.
///
/// ## Why this is not `.onDrag`
///
/// Every stash used to hand out its items with SwiftUI's `.onDrag`, and that is
/// the whole reason a file dragged into Finder was always copied. In AppKit the
/// *source* of a drag says which operations it allows and the *destination*
/// picks one of them. SwiftUI's hosting view is the source for `.onDrag`, and
/// asked directly, it allows exactly one:
///
/// ```
///   NSHostingView.draggingSession(_:sourceOperationMaskFor:)
///     outside the app  ->  [copy]
///     inside the app   ->  [copy]
/// ```
///
/// With only `copy` on offer, Finder has nothing else it is allowed to do. The
/// method is `public` but not `open`, so it cannot be overridden either —
/// SwiftUI closes it to subclasses on purpose. So a stash drag is started here,
/// as a native AppKit dragging session with a source this app owns.
///
/// ## Who moves the file
///
/// **The receiver, never Gruppen.** This object only states what is allowed.
/// Finder, handed a drag that permits `move`, performs the move itself — the
/// same code path as dragging between two Finder windows, with its progress,
/// its conflict dialog, and its undo. The tempting alternative,
/// letting the receiver copy and then deleting the original here, is how
/// people lose files: a drop is *accepted* the moment it lands, but a large
/// copy is still running long after `endedAt` fires, and a source deleted
/// underneath it is gone.
@MainActor
final class StashDragOut: NSObject, NSDraggingSource {
    static let shared = StashDragOut()

    /// What the receiver is allowed to do with a dragged item.
    ///
    /// - **Inside the app, always `copy`.** Another stash is the only thing
    ///   in-app that takes a drop, and it takes a *reference* — it performs no
    ///   file operation at all, and its drop zone answers `copy`. Offering
    ///   only `move` there would have it refuse the drop.
    /// - **Outside, `move` *and* `copy` when moving — and the `copy` is what
    ///   makes browsers work.** This used to offer `move` alone, and that broke
    ///   every web drop target. A browser turns the source's mask into the
    ///   page's `effectAllowed`, and a page taking a file asks for
    ///   `dropEffect = "copy"` — an upload reads the file, it cannot relocate
    ///   it. With `move` the only thing allowed, the HTML drag-and-drop rules
    ///   make that a mismatch, and Chrome, Safari and Firefox all refuse the
    ///   drop: Google Drive, Gmail, Canvas, any `<input type=file>` zone. The
    ///   same goes for the many native and Electron apps that only ever accept
    ///   a copy.
    ///
    ///   With both on offer, each receiver takes the one that means something
    ///   to it: Finder moves, a browser copies. The price is paid in one place,
    ///   and it is Finder's own rule rather than anything Gruppen chose — given
    ///   the choice, Finder moves within a disk and **copies between disks**,
    ///   exactly as it does for a drag between two of its own windows, with ⌘
    ///   to force the move. `endedAt` reports which one happened, and the item
    ///   only leaves the stash when it was a move — see `consumes`.
    /// - **Only files can move.** Text and links have nothing on disk to
    ///   relocate, so they are always offered as copies.
    nonisolated static func operations(for context: NSDraggingContext,
                                       moving: Bool) -> NSDragOperation {
        guard context == .outsideApplication, moving else { return .copy }
        return [.move, .copy]
    }

    /// Whether a finished drag takes the item off the stash.
    ///
    /// **In move mode, the stash follows the file.** It leaves when the file
    /// left — the receiver reported `move` — and stays when the receiver only
    /// copied it. A browser upload, a Slack attachment, a Finder drop onto
    /// another disk: in all of those the file is still exactly where it was, so
    /// the stash keeps holding it, and you can still take it to the folder you
    /// meant to move it to. Dropping it from the stash because *some* app read
    /// it would leave a file that was never moved, no longer on the stash that
    /// was carrying it.
    ///
    /// **In copy mode every drop is a copy**, and a copy consumes the item, as
    /// dragging out always has.
    ///
    /// A drop nobody took consumes nothing, in either mode.
    nonisolated static func consumes(_ operation: NSDragOperation, moving: Bool) -> Bool {
        guard !operation.isEmpty else { return false }
        return moving ? operation.contains(.move) : true
    }

    /// The one drag in flight, if any. AppKit runs a single dragging session at
    /// a time, and this stops a gesture that reports its movement more than
    /// once from asking for a second.
    private var inFlight: InFlight?

    private struct InFlight {
        let title: String
        let moving: Bool
        let onAccepted: () -> Void
    }

    private override init() { super.init() }

    /// Starts dragging `item` from the mouse event now being handled.
    ///
    /// Called from inside a SwiftUI drag gesture, where `NSApp.currentEvent` is
    /// the `leftMouseDragged` that moved the gesture past its threshold —
    /// exactly the event `beginDraggingSession` wants. Anything else, and no
    /// drag begins: a session started from the wrong event would pick up a
    /// stale position, and doing nothing is the honest failure.
    ///
    /// `onAccepted` runs once the drop has landed, and only when that drop
    /// takes the item off the stash — see `consumes`. Not at the start, the way
    /// `.onDrag` forced it to be: a drag that is cancelled now leaves the item
    /// on the stash rather than losing it, and a stash emptied by its last
    /// item no longer closes its own window out from under a drag still in
    /// progress.
    func begin(_ item: StashItem, onAccepted: @escaping () -> Void) {
        guard inFlight == nil,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged,
              let view = event.window?.contentView
        else { return }

        // A file that has gone since it was stashed falls back to its URL or
        // text, like any other item — and there is then nothing to move.
        let hasFile = item.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let moving = hasFile && AppSettings.shared.stashMovesOnDragOut

        let dragged = NSDraggingItem(pasteboardWriter: item.pasteboardWriter)
        // The item's own icon, centred on the pointer. The frame is in the
        // coordinate space of the view the session starts from, and centring
        // on the converted point is right whether or not that view is flipped.
        let side: CGFloat = 32
        let point = view.convert(event.locationInWindow, from: nil)
        dragged.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2,
                                        width: side, height: side),
                                 contents: item.icon)

        inFlight = InFlight(title: item.title, moving: moving, onAccepted: onAccepted)
        let session = view.beginDraggingSession(with: [dragged], event: event, source: self)
        // A drop nobody takes slides back to where it started, so a cancelled
        // drag visibly returns the thing to the stash it never left.
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operations(for: context, moving: inFlight?.moving ?? false)
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let drag = inFlight else { return }
        inFlight = nil
        // Logged with what the receiver *did*, not what was offered — so a
        // drop that was meant to move and was not is visible in the log
        // rather than a mystery.
        let consumed = Self.consumes(operation, moving: drag.moving)
        GroupStore.log("STASH drag-out \(drag.title) — \(Self.describe(operation)) "
                       + "(offered \(drag.moving ? "move or copy" : "copy"); "
                       + "\(consumed ? "left the stash" : "kept on the stash"))")
        guard consumed else { return }
        drag.onAccepted()
    }

    nonisolated static func describe(_ operation: NSDragOperation) -> String {
        if operation.isEmpty { return "cancelled" }
        if operation.contains(.move) { return "moved" }
        if operation.contains(.copy) { return "copied" }
        if operation.contains(.link) { return "linked" }
        return "accepted"
    }
}

extension View {
    /// Lets `item` be dragged off a stash — moved or copied, per the setting.
    ///
    /// The replacement for `.onDrag` at every stash drag site. A drag gesture
    /// with a small threshold, so a click stays a click: selection, hover and
    /// the row's own buttons all behave exactly as they did. Once the pointer
    /// has travelled four points the gesture hands the rest of the drag to
    /// AppKit, which tracks it from there.
    func stashDraggable(_ item: StashItem, onAccepted: @escaping () -> Void) -> some View {
        gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in StashDragOut.shared.begin(item, onAccepted: onAccepted) }
        )
    }
}
