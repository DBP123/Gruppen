import AppKit

/// Whether anyone can see the screen, and the switch that stops telemetry when
/// nobody can.
///
/// A module pinned to the menu bar is the one thing in Gruppen that runs on a
/// schedule while the app is idle, and it kept running with the displays asleep,
/// the screen locked, or another user's session in front — sampling for a menu
/// bar no one could see. Each of those posts a notification, so this is three
/// flags and no polling. Any one of them pauses `TelemetryClock`; all three
/// clear resumes it, with every module due at once so the first readout back is
/// current.
///
/// System sleep needs nothing here: the clock's timer does not advance while the
/// machine is asleep.
@MainActor
final class ScreenPresence {
    static let shared = ScreenPresence()

    private var displaysAsleep = false
    private var sessionInactive = false
    private var locked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {}

    /// Idempotent. Called when telemetry starts.
    func install() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        watch(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        watch(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        // Fast user switching: our session is still running, behind someone else's.
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        // No public constant, but these names are what the loginwindow has
        // posted for every macOS release Gruppen supports.
        watch(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
    }

    var isAway: Bool { displaysAsleep || sessionInactive || locked }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name,
                       _ change: @escaping @MainActor (ScreenPresence) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasAway = self.isAway
                change(self)
                guard self.isAway != wasAway else { return }
                GroupStore.log("TELEMETRY \(self.isAway ? "paused: nobody can see the screen" : "resumed")")
                TelemetryClock.shared.setSuspended(self.isAway)
            }
        }
        observers.append((center, token))
    }
}
