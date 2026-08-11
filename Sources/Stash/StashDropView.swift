import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The callbacks a stash surface wants when a drag arrives.
///
/// A plain class on purpose: the hosting view reads it when a drag is released,
/// and nothing here should be able to invalidate a view.
@MainActor
final class DropZoneRegistry {
    var onTargetChanged: ((Bool) -> Void)?
    /// Fired synchronously on drop, before any bytes are read.
    var onDropAccepted: (() -> Void)?
    var onItems: (([StashItem]) -> Void)?
}

/// A hosting view that is itself the dragging destination.
///
/// Two reasons it has to be here rather than in a child view or a SwiftUI
/// `.onDrop`:
///
/// 1. **Promises.** A file dragged out of Safari or Photos arrives as an
///    `NSFilePromiseReceiver` on the dragging pasteboard — an IOU, not an item
///    provider. SwiftUI's `.onDrop` is built entirely on `NSItemProvider` and
///    never sees one, so those drags silently did nothing.
/// 2. **Coverage.** A drop view installed *behind* the SwiftUI content only
///    receives drags where nothing interactive sits on top. Measured: hit-testing
///    the notch panel returned the background drop view over empty space but the
///    hosting view over the close button, the header, and every item chip — so a
///    drop onto a file already on the shelf would have been refused. The hosting
///    view is the root of the content, so registering it catches everything.
final class StashHostingView<Content: View>: NSHostingView<Content> {
    let registry: DropZoneRegistry
    /// Called when the pointer leaves the panel entirely. Event-driven via
    /// `NSTrackingArea` — nothing is polled, and nothing runs until the cursor
    /// actually crosses the boundary.
    ///
    /// "The panel" means the whole window including its invisible buffer, which
    /// is the point: the tracking rect is deliberately larger than anything
    /// drawn, so leaving the tray by two points is not leaving.
    var onMouseExited: (() -> Void)?
    /// The other half of the pair. Coming back cancels whatever leaving started.
    var onMouseEntered: (() -> Void)?

    init(rootView: Content, registry: DropZoneRegistry) {
        self.registry = registry
        super.init(rootView: rootView)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff, .rtf]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    /// **Why every button on these panels was dead.**
    ///
    /// A stash panel is `.nonactivatingPanel` and returns `false` from
    /// `canBecomeKey`, on purpose — it must never steal focus from the app you
    /// are dragging out of. But that also means it is never the key window, so
    /// *every* click on it is a "first mouse" click, and AppKit throws those
    /// away unless the view under the cursor opts in. Measured before the fix:
    /// `canBecomeKey: false`, `isKeyWindow: false`, `acceptsFirstMouse: false`.
    /// That is the whole reason the notch's close button had never worked once.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    @available(*, unavailable)
    required init(rootView: Content) { fatalError("init(rootView:) is not used") }

    @available(*, unavailable)
    @objc required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        registry.onTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        registry.onTargetChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        registry.onTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        registry.onDropAccepted?()
        IngestionManager.ingest(sender) { [weak self] items in
            self?.registry.onItems?(items)
        }
        return true
    }

}
