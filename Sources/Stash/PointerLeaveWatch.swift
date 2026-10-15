import AppKit

/// Calls back once, the first time the pointer is further than `margin` from a
/// region: for something that should go when you leave it, but not the
/// instant the pointer slips a few points past its edge.
///
/// Distance, not time. A delay closes the tray while you are still hovering
/// beside it, or keeps it after you have plainly gone; a margin answers the
/// real question — has the pointer left the neighbourhood? — the moment it
/// has.
///
/// The pointer monitors exist only while a watch does, and the caller holds a
/// watch only while it is waiting, so nothing listens the rest of the time.
@MainActor
final class PointerLeaveWatch {
    private let region: () -> NSRect?
    private let margin: CGFloat
    private var onLeave: (() -> Void)?
    private var monitors: [Any] = []

    /// `region` is read on every move, so a region that moves — a tray
    /// re-anchored to another display — is followed. Nil ends the watch.
    init(region: @escaping () -> NSRect?, margin: CGFloat, onLeave: @escaping () -> Void) {
        self.region = region
        self.margin = margin
        self.onLeave = onLeave
    }

    /// Whether `point` is outside `region` grown by `margin` on every side.
    nonisolated static func hasLeft(_ point: NSPoint, region: NSRect, margin: CGFloat) -> Bool {
        !region.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    /// Starts watching — and calls back at once if the pointer is already gone.
    func start() {
        guard monitors.isEmpty, onLeave != nil else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        // Beyond the region the pointer is over other apps, whose events reach
        // a global monitor; over Gruppen's own windows, only a local one sees it.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.check() }
            return event
        }) { monitors.append(local) }
        check()
    }

    func cancel() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        onLeave = nil
    }

    private func check() {
        guard let region = region() else { cancel(); return }
        guard Self.hasLeft(NSEvent.mouseLocation, region: region, margin: margin) else { return }
        let leave = onLeave
        cancel()
        leave?()
    }
}
