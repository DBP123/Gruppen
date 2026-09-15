import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Switches to a numbered desktop.
///
/// ## Read this before trusting it
///
/// macOS has no public API for "go to desktop 3". The window server knows, and
/// `CGSSetWorkspace` in the private CoreGraphics SPI would do it, but that is
/// unavailable to a signed app that intends to keep working across releases. The
/// only supported route is the one a person uses: press the **Switch to Desktop
/// N** keyboard shortcut. So this synthesises that keystroke.
///
/// That means two preconditions, neither of which Gruppen can satisfy on the
/// user's behalf, and both of which are false on a stock Mac:
///
/// 1. **The shortcut has to exist.** "Switch to Desktop N" ships *disabled* in
///    System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control. If it
///    is off, there is no keystroke to send and the synthetic event lands on
///    nothing.
/// 2. **Gruppen has to be trusted for Accessibility.** Since Mojave the window
///    server drops synthetic events from untrusted processes. Without it,
///    `CGEvent.post` returns successfully and nothing happens.
///
/// Both are checked before anything is sent, so a profile that cannot switch
/// desktops says *why* instead of appearing to work. This is also the one part
/// of Gruppen that wants Accessibility at all: the global hotkeys go through
/// Carbon precisely to avoid it (see `HotkeyCenter`), and a profile with no
/// `spaceIndex` never touches any of this.
@MainActor
enum SpaceManager {
    /// macOS defines "Switch to Desktop 1…10" as symbolic hotkeys 118…127.
    private static let firstSymbolicID = 118
    static let maximumDesktop = 10

    enum Readiness: Equatable {
        case ready
        case needsAccessibility
        case shortcutDisabled(desktop: Int)

        var explanation: String {
            switch self {
            case .ready:
                return "Ready"
            case .needsAccessibility:
                return "Gruppen is not trusted for Accessibility, so macOS ignores the keystroke"
            case .shortcutDisabled(let desktop):
                return "\"Switch to Desktop \(desktop)\" is off in System Settings ▸ Keyboard ▸ Shortcuts ▸ Mission Control"
            }
        }
    }

    /// Whether this process may post synthetic keyboard events.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Opens the Accessibility permission prompt. Only ever called from a button
    /// the user pressed — a permission dialog nobody asked for is a permission
    /// dialog they deny.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Whether the machine could actually honour a switch to `desktop`.
    static func readiness(for desktop: Int) -> Readiness {
        guard isShortcutEnabled(for: desktop) else { return .shortcutDisabled(desktop: desktop) }
        guard isTrusted else { return .needsAccessibility }
        return .ready
    }

    /// Reads System Settings' own record of whether the shortcut is on.
    ///
    /// An absent entry means the shortcut is at its macOS default, and the
    /// default for desktop switching is *off* — so a missing key is a negative
    /// answer, not an unknown one.
    static func isShortcutEnabled(for desktop: Int) -> Bool {
        guard let index = symbolicID(for: desktop) else { return false }
        guard let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                      "com.apple.symbolichotkeys" as CFString)
                as? [String: Any],
              let entry = hotkeys[String(index)] as? [String: Any],
              let enabled = entry["enabled"] as? Bool
        else { return false }
        return enabled
    }

    private static func symbolicID(for desktop: Int) -> Int? {
        guard (1...maximumDesktop).contains(desktop) else { return nil }
        return firstSymbolicID + (desktop - 1)
    }

    /// Sends the keystroke. Reports rather than throwing, like every other stage.
    static func switchTo(desktop: Int) -> WorkspaceActivationReport.Outcome {
        guard (1...maximumDesktop).contains(desktop) else {
            return .failed("desktop \(desktop) is out of range (1–\(maximumDesktop))")
        }
        switch readiness(for: desktop) {
        case .needsAccessibility:
            return .failed(Readiness.needsAccessibility.explanation)
        case .shortcutDisabled:
            return .failed(Readiness.shortcutDisabled(desktop: desktop).explanation)
        case .ready:
            break
        }
        guard let key = keyCode(forDigit: desktop) else {
            return .failed("no key for desktop \(desktop)")
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return .failed("could not build the keystroke") }

        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return .done("switched to desktop \(desktop)")
    }

    /// Desktop 10 is reached with the `0` key, which is why this is a lookup and
    /// not arithmetic on a base key code.
    private static func keyCode(forDigit desktop: Int) -> CGKeyCode? {
        let codes: [Int: Int] = [
            1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5,
            6: kVK_ANSI_6, 7: kVK_ANSI_7, 8: kVK_ANSI_8, 9: kVK_ANSI_9, 10: kVK_ANSI_0,
        ]
        return codes[desktop].map { CGKeyCode($0) }
    }
}
