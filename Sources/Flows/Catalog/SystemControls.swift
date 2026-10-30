import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt

/// Holds the Mac awake for a while: one power assertion, released when its
/// time is up or when it is toggled off. One scheduled release, not a timer
/// that ticks.
@MainActor
enum KeepAwake {
    private static var assertion: IOPMAssertionID?
    private static var release: DispatchWorkItem?

    /// Returns whether the Mac is now being kept awake.
    static func toggle(hours: Int) -> Bool {
        if let current = assertion {
            IOPMAssertionRelease(current)
            assertion = nil
            release?.cancel()
            return false
        }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Gruppen keep awake" as CFString, &id) == kIOReturnSuccess
        else { return false }
        assertion = id
        let work = DispatchWorkItem { _ = toggle(hours: 0) }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(hours * 3600), execute: work)
        return true
    }
}

/// ⌘V into whatever app is in front — only with Accessibility granted, since
/// posting keystrokes needs it. Without it the text is simply on the
/// clipboard, which is said in the run's message.
@MainActor
enum Paste {
    static func intoFrontmostApp() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        return true
    }
}
