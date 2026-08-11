import Foundation
import UserNotifications

/// The `UserNotifications` call, kept behind its own type.
///
/// Authorisation is requested once, lazily, the first time a script actually
/// asks for a banner — never at launch, because an app that asks for
/// notification permission before it has anything to say is an app people say
/// no to. If permission is refused or the process cannot use the framework at
/// all, this quietly does nothing: a script's job is the work, not the toast.
enum NotifierBridge {
    private static var requested = false

    /// `report` receives nil on success and a reason on failure, so a banner
    /// that never appears leaves a trace in the script's own log instead of
    /// being silently swallowed.
    static func post(title: String, body: String, report: @escaping (String?) -> Void) {
        let center = UNUserNotificationCenter.current()

        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            center.add(request) { error in
                if let error {
                    NSLog("Gruppen: notification not delivered — %@", error.localizedDescription)
                    report("notification not delivered — \(error.localizedDescription)")
                } else {
                    report(nil)
                }
            }
        }

        guard !requested else { deliver(); return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Gruppen: notification permission failed — %@", error.localizedDescription)
                report("notifications unavailable — \(error.localizedDescription)")
                return
            }
            guard granted else {
                report("notifications are turned off for Gruppen in System Settings")
                return
            }
            deliver()
        }
    }
}
