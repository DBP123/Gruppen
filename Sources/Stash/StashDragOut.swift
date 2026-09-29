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
/// Finder, handed a drag that permits `move` and nothing else, performs the move
/// itself — the same code path as dragging between two Finder windows, with
/// its progress, its conflict dialog, and its undo. The tempting alternative,
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
    /// - **Outside, `move` alone when moving.** Not `move` *and* `copy`: with
    ///   both on offer the choice goes back to the receiver, and Finder's
    ///   default for a drag between disks is to copy — so the setting would
    ///   hold on one volume and not another. Offering one operation makes the
    ///   setting mean what it says on every destination.
    /// - **Only files can move.** Text and links have nothing on disk to
    ///   relocate, so they are always offered as copies — a receiver that
    ///   refuses a move of a string is refusing for no reason.
    nonisolated static func operations(for context: NSDraggingContext,
                                       moving: Bool) -> NSDragOperation {
        guard context == .outsideApplication, moving else { return .copy }
        return .move
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
    /// `onAccepted` runs once the drop has landed. Not at the start, the way
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
        GroupStore.log("STASH drag-out \(drag.title) — \(Self.describe(operation)) "
                       + "(offered \(drag.moving ? "move" : "copy"))")
        // An empty operation is a drop nobody accepted.
        guard !operation.isEmpty else { return }
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
