import Foundation
import IOKit

/// When the machine last booted, slept and woke — and what caused the last two.
///
/// Deliberately **not** a telemetry module. Everything else in this folder is
/// sampled on a timer because its figures move continuously; these five do not.
/// Boot time is fixed for the life of the boot, and the sleep and wake records
/// change exactly twice per sleep cycle — which cannot happen while you are
/// looking at them, because the machine is awake. So there is no sampler, no
/// `DispatchSourceTimer` and no published object here: the view reads a snapshot
/// when it is opened and formats the elapsed strings as it draws.
struct UptimeSnapshot {
    var bootedAt: Date?
    var sleptAt: Date?
    var wokeAt: Date?
    /// Already sanitised — see `UptimeService.humanise(_:)`.
    var sleepReason: String?
    var wakeReason: String?

    static let empty = UptimeSnapshot()
}

/// Reads the machine's power-cycle history.
///
/// A namespace rather than a class: it owns no state worth keeping between
/// calls, and a stateful "manager" here would only invite a timer onto data
/// that does not move.
enum UptimeService {

    // MARK: Reading

    /// One pass over the kernel clocks and the power-management registry.
    ///
    /// Measured at 0.11 ms, almost all of it the single IORegistry property
    /// fetch. Called when the section is opened, and on no clock at all.
    static func read() -> UptimeSnapshot {
        let reasons = powerReasons()
        return UptimeSnapshot(
            bootedAt: timestamp("kern.boottime"),
            sleptAt: timestamp("kern.sleeptime"),
            wokeAt: timestamp("kern.waketime"),
            sleepReason: reasons.sleep.flatMap(humanise),
            wakeReason: reasons.wake.flatMap(humanise))
    }

    /// A `timeval` out of `sysctl`, as a date.
    ///
    /// `kern.sleeptime` and `kern.waketime` are zeroed on a machine that has not
    /// slept since boot, which is a real state and not a failure — hence the
    /// `tv_sec > 0` guard rather than trusting the call's return code alone.
    private static func timestamp(_ name: String) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec)
                    + Double(value.tv_usec) / 1_000_000)
    }

    /// Why the machine last slept and last woke, from `IOPMrootDomain`.
    ///
    /// The key names are not stable across macOS versions or architectures, so
    /// each is a list of candidates tried in order. On this Apple Silicon Mac the
    /// live keys are `Wake Reason` and `Last Sleep Reason` — spaced, not camel
    /// case — with the camel-cased spellings kept for the machines that use them.
    /// All of them come out of one property fetch; three separate
    /// `IORegistryEntryCreateCFProperty` calls would cost three times as much for
    /// the same dictionary.
    private static func powerReasons() -> (sleep: String?, wake: String?) {
        let root = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return (nil, nil) }
        defer { IOObjectRelease(root) }

        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(root, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let fields = raw?.takeRetainedValue() as? [String: Any]
        else { return (nil, nil) }

        func first(_ keys: [String]) -> String? {
            for key in keys {
                if let text = fields[key] as? String, !text.isEmpty { return text }
            }
            return nil
        }

        // The nested form: macOS records the reason for a wake-back-to-sleep in
        // a dictionary rather than at the top level.
        let nestedSleep = (fields["Last Sleep Options"] as? [String: Any])
            .flatMap { $0["Sleep Reason"] as? String }

        return (sleep: first(["Last Sleep Reason", "LastSleepReason", "SleepReason"]) ?? nestedSleep,
                wake: first(["Wake Reason", "WakeReason", "Wake Type"]))
    }

    // MARK: Sanitising

    /// Hardware tokens, as something a person would say.
    ///
    /// Keys are lowercased; look-ups fold case so the table does not have to
    /// carry every capitalisation macOS has used.
    private static let vocabulary: [String: String] = [
        // Lid
        "ec.lidopen": "Lid Open",
        "lid": "Lid Open",
        "ec.lidclose": "Lid Closed",
        "clamshell sleep": "Lid Closed",
        "clamshell": "Lid Closed",
        // Buttons and power
        "ec.powerbutton": "Power Button",
        "powerbutton": "Power Button",
        "pwrb": "Power Button",
        "ec.acattach": "Power Adapter Attached",
        "acins": "Power Adapter Attached",
        "ec.acdetach": "Power Adapter Removed",
        "batc": "Battery",
        "low battery sleep": "Low Battery",
        "lowbatterysleep": "Low Battery",
        // Software-initiated
        "maintenance sleep": "Maintenance",
        "maintenancesleep": "Maintenance",
        "idle sleep": "Idle",
        "idlesleep": "Idle",
        "software sleep": "Software Request",
        "softwaresleep": "Software Request",
        "notification wake back to sleep": "Notification",
        "thermal emergency sleep": "Thermal Emergency",
        "thermalemergencysleep": "Thermal Emergency",
        // Input
        "hid activity": "Keyboard or Trackpad",
        "hidactivity": "Keyboard or Trackpad",
        "rtp.multi-touch": "Trackpad",
        "multi-touch": "Trackpad",
        "useractivity": "User Activity",
        "user activity": "User Activity",
        // Peripherals and timers
        "rtc": "Scheduled Wake",
        "rtcalarm": "Scheduled Wake",
        "xhc": "USB Device", "xhc1": "USB Device",
        "ehc1": "USB Device", "ohc1": "USB Device", "usb": "USB Device",
        "arpt": "Network", "wifi": "Network",
        "gige": "Network", "ethernet": "Network",
    ]

    /// Turn a raw power-management reason into a readable one.
    ///
    /// Sleep reasons arrive as a single phrase — "Maintenance Sleep". Wake
    /// reasons on Apple Silicon do not: this machine reports
    /// `smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch`,
    /// which is several tokens, most of them internal plumbing. So the whole
    /// string is matched first, and only then is it broken into tokens and the
    /// first one that means something to a reader taken — "lid" here, which is
    /// the true cause; the rest describe how the wake was delivered.
    ///
    /// A string that matches nothing is tidied rather than replaced with
    /// "Unknown". A reader is better served by an odd-looking true value than by
    /// a confident-looking empty one.
    static func humanise(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let known = vocabulary[trimmed.lowercased()] { return known }

        for token in trimmed.split(separator: " ") {
            if let known = vocabulary[strip(String(token))] { return known }
        }
        return tidy(trimmed)
    }

    /// Drop the hex payload macOS appends to SMC tokens — `EC.LidOpen(0x1234)`
    /// is the same reason as `EC.LidOpen`.
    private static func strip(_ token: String) -> String {
        guard let paren = token.firstIndex(of: "(") else { return token.lowercased() }
        return String(token[token.startIndex..<paren]).lowercased()
    }

    /// Last resort for an unrecognised token: make it readable without
    /// pretending to know what it means.
    private static func tidy(_ raw: String) -> String {
        let cleaned = raw.split(separator: " ")
            .map(String.init)
            .map { $0.contains("(") ? String($0[$0.startIndex..<$0.firstIndex(of: "(")!]) : $0 }
            .joined(separator: " ")
        return cleaned.isEmpty ? raw : cleaned
    }

    // MARK: Formatting

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        // Without this a machine up for seven days flat reads
        // "7 days, 0 hours, 0 minutes".
        formatter.zeroFormattingBehavior = .dropAll
        formatter.maximumUnitCount = 3
        return formatter
    }()

    /// How long ago, in words: "7 days, 7 hours, 41 minutes", "1 minute".
    ///
    /// Anything under a minute is "0 minutes" rather than the empty string
    /// `DateComponentsFormatter` returns when every allowed unit is zero. A
    /// negative interval — a clock that has been set backwards — lands in the
    /// same branch, which is the only sane thing to say about a date in the
    /// future.
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "0 minutes" }
        return elapsedFormatter.string(from: seconds) ?? "0 minutes"
    }
}
