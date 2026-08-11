import AppKit
import Foundation

/// Gives memory back when the app stops being looked at.
///
/// Measured before this existed: a 65MB footprint of which only 0.6MB was
/// images — the rest was malloc heap, including **11.8MB of MALLOC_LARGE and
/// 20.9MB of MALLOC_SMALL already marked empty**. That is memory the app had
/// finished with and libmalloc was holding onto, which is normal and free until
/// someone is measuring idle footprint, which is exactly what we do here.
///
/// Both triggers are events: the app resigning active, and the kernel reporting
/// memory pressure. Nothing runs on a schedule, and nothing runs while the app
/// is in use — reclaiming pages under the user's fingers would trade the thing
/// they can feel for a number they cannot.
@MainActor
enum MemoryRelief {
    private static var observers: [NSObjectProtocol] = []
    private static var pressureSource: DispatchSourceMemoryPressure?

    static func install() {
        guard observers.isEmpty else { return }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in relieve(clearingCaches: true) }
        })

        // Windows closing is the other moment a lot becomes garbage at once.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in relieve(clearingCaches: true) }
        })

        // Kernel-signalled, dormant otherwise.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .main)
        source.setEventHandler { Task { @MainActor in relieve(clearingCaches: true) } }
        source.resume()
        pressureSource = source
    }

    static func relieve(clearingCaches: Bool) {
        if clearingCaches { IconCache.shared.clear() }
        // Hands whole free pages back to the OS. Without this they stay on
        // libmalloc's free lists and keep counting against the footprint.
        malloc_zone_pressure_relief(nil, 0)
    }
}
