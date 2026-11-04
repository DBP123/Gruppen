import Foundation

/// One write for a burst of edits.
///
/// Every change to a library used to re-encode the whole file and rewrite it
/// atomically, there and then. Dragging a Gruppe's sequence-delay slider was
/// about thirty of those in one gesture, and the colour picker wrote for as long
/// as the pointer moved. Now a change schedules a write `delay` seconds out,
/// and each further change in that window pushes it back, so a gesture is one
/// write when it settles.
///
/// Nothing is lost on the way out: `flushAll()` runs from
/// `applicationWillTerminate`, and `flush()` writes at once for anything that
/// needs the file current now — a test reloading what it just edited.
@MainActor
final class CoalescedSave {
    static let delay: TimeInterval = 0.5

    private let write: () -> Void
    private var pending: DispatchWorkItem?

    private struct Entry { weak var saver: CoalescedSave? }
    private static var live: [Entry] = []

    init(_ write: @escaping () -> Void) {
        self.write = write
        Self.live.removeAll { $0.saver == nil }
        Self.live.append(Entry(saver: self))
    }

    /// True between a change and its write.
    var isPending: Bool { pending != nil }

    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: item)
    }

    /// Writes now if a write is waiting; otherwise does nothing.
    func flush() {
        guard let item = pending else { return }
        item.cancel()
        pending = nil
        write()
    }

    /// Every waiting write, now. Called as the app quits.
    static func flushAll() {
        for entry in live { entry.saver?.flush() }
        live.removeAll { $0.saver == nil }
    }
}
