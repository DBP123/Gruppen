import AppKit
import ApplicationServices
import CoreLocation
import Foundation

/// What macOS has allowed Gruppen to do, and what to say when it has not.
///
/// Scripts are Gruppen's children, so they inherit its permissions: granting
/// Gruppen Full Disk Access covers every flow at once. That is said plainly
/// wherever a permission is asked for, because the usual guess — grant it to
/// python3, or to Terminal — does nothing.
enum Permissions {
    enum State: Equatable, Sendable {
        case granted
        case denied
        /// Not asked yet, or the app it concerns is not running to be asked
        /// about.
        case unknown
    }

    // MARK: State

    /// May block briefly for Automation — call it off the main thread.
    static func state(of permission: Permission) -> State {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .fullDiskAccess:
            return fullDiskAccess()
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways: return .granted
            case .denied, .restricted: return .denied
            default: return .unknown
            }
        case .automation(let bundleID):
            return automation(bundleID)
        }
    }

    /// Reading the user's own privacy database is allowed only with Full
    /// Disk Access — a probe that changes nothing and asks nothing.
    private static func fullDiskAccess() -> State {
        let probe = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: probe) else { return .unknown }
        let descriptor = open(probe, O_RDONLY)
        if descriptor >= 0 { close(descriptor); return .granted }
        return errno == EPERM || errno == EACCES ? .denied : .unknown
    }

    private static func automation(_ bundleID: String) -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard var descriptor = target.aeDesc?.pointee else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(&descriptor, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }

    // MARK: Explaining

    /// A tool's error, recognised as macOS refusing something, put in words a
    /// person can act on — or nil when it is some other failure.
    static func explain(_ message: String) -> String? {
        diagnose(message).map { "\($0.permission.label) is needed. \($0.permission.advice)" }
    }

    static func diagnose(_ message: String) -> (permission: Permission, original: String)? {
        let lower = message.lowercased()
        if lower.contains("-1743") || lower.contains("not authorized to send apple events") {
            let app = firstMatch(#"(?:to|application) “?\"?([^”\"]+?)”?\"?(?: |\.|$)"#, in: message)
            return (.automation(app.flatMap(bundleID(named:)) ?? app ?? "another app"), message)
        }
        if lower.contains("-25211") || lower.contains("assistive access") || lower.contains("not allowed assistive") {
            return (.accessibility, message)
        }
        if lower.contains("operation not permitted"), protectedPathMentioned(message) {
            return (.fullDiskAccess, message)
        }
        return nil
    }

    // MARK: Inferring

    /// What a code block will probably need, read from its source: an app it
    /// tells to do something, a protected folder it names, keystrokes it
    /// sends. A guess, shown as one — the checklist says "probably needs".
    static func inferred(from spec: CodeSpec) -> [Permission] {
        var found: [Permission] = []
        let source = spec.source
        let apps = allMatches(#"tell application \"([^\"]+)\""#, in: source)
            + allMatches(#"Application\(\s*[\"']([^\"']+)[\"']\s*\)"#, in: source)
        found += apps.compactMap(bundleID(named:)).map(Permission.automation)
        if source.contains("keystroke") || source.contains("key code") || source.contains("click ") {
            found.append(.accessibility)
            found.append(.automation("com.apple.systemevents"))
        }
        if protectedPathMentioned(source) { found.append(.fullDiskAccess) }
        if source.contains("screencapture") { found.append(.screenRecording) }
        var seen = Set<Permission>()
        return found.filter { seen.insert($0).inserted }
    }

    /// Folders macOS guards behind Full Disk Access.
    static let protectedFolders = ["Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies",
                                   "Library/Containers", "Library/Group Containers", "Library/HomeKit",
                                   "Library/Application Support/com.apple.TCC", "Library/Metadata/CoreSpotlight",
                                   "Library/Calendars", "Library/Reminders", "Library/Suggestions"]

    private static func protectedPathMentioned(_ text: String) -> Bool {
        protectedFolders.contains { text.contains($0) }
    }

    // MARK: Apps by name

    /// The bundle identifier of an app named as a script names it: "Finder",
    /// "Music", "Google Chrome".
    static func bundleID(named name: String) -> String? {
        let wellKnown = ["Finder": "com.apple.finder", "System Events": "com.apple.systemevents",
                         "Safari": "com.apple.Safari", "Mail": "com.apple.mail", "Music": "com.apple.Music",
                         "Notes": "com.apple.Notes", "Reminders": "com.apple.reminders",
                         "Calendar": "com.apple.iCal", "Messages": "com.apple.MobileSMS",
                         "Terminal": "com.apple.Terminal", "Photos": "com.apple.Photos"]
        if let id = wellKnown[name] { return id }
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
                     "/System/Library/CoreServices"]
        for root in roots {
            let url = URL(fileURLWithPath: root).appendingPathComponent("\(name).app")
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

extension Permission {
    var label: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .fullDiskAccess: return "Full Disk Access"
        case .screenRecording: return "Screen Recording"
        case .location: return "Location Services"
        case .automation(let id): return "Permission to control \(Apps.name(id))"
        }
    }

    var glyph: String {
        switch self {
        case .accessibility: return "accessibility"
        case .fullDiskAccess: return "externaldrive.badge.checkmark"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .location: return "location"
        case .automation: return "applescript"
        }
    }

    /// What to do, in one sentence.
    var advice: String {
        switch self {
        case .automation(let id):
            return "Allow Gruppen to control \(Apps.name(id)) in System Settings › Privacy & Security › Automation. Scripts run as part of Gruppen, so that one switch covers them."
        case .location:
            return "Allow Gruppen in System Settings › Privacy & Security › Location Services; macOS only shares the Wi-Fi name with apps that have it."
        default:
            return "Turn Gruppen on in System Settings › Privacy & Security › \(label). Scripts run as part of Gruppen, so that one switch covers them."
        }
    }

    /// The exact pane in System Settings.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .location: anchor = "Privacy_LocationServices"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}
