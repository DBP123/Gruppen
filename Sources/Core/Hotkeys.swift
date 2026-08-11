import AppKit
import Carbon.HIToolbox

/// Human-readable names for keys that have no sensible printable character.
enum KeyLabels {
    private static let special: [Int: String] = [
        kVK_Space: "␣", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let letters: [String: Int] = {
        let codes = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
            "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
            "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
            "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
            "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
            "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
            "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
        ]
        return codes
    }()

    static func keyCode(forLetter letter: String) -> UInt32? {
        letters[letter.uppercased()].map(UInt32.init)
    }

    /// Label for a recorded key press. Prefers the character the key produces
    /// without modifiers, so non-US layouts read correctly.
    static func label(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        if let name = special[Int(keyCode)] { return name }
        if let characters = charactersIgnoringModifiers?.uppercased(),
           let first = characters.first,
           !first.isWhitespace,
           first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol {
            return String(first)
        }
        return "Key \(keyCode)"
    }
}

/// Registers system-wide hotkeys through Carbon.
///
/// Carbon is still the supported route for a global hotkey that works without
/// Accessibility permission — `NSEvent.addGlobalMonitorForEvents` would demand
/// one, which is a heavy ask for a launcher.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    /// Which subsystem claimed each binding. Gruppen and scripts both hold
    /// hotkeys, and re-syncing one must not silently drop the other's.
    private var owners: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    /// Drops every binding. Call before re-registering the current set, and
    /// while recording so an existing hotkey cannot fire mid-capture.
    func unregisterAll(owner: String) {
        for (id, ref) in refs where owners[id] == owner {
            UnregisterEventHotKey(ref)
            refs.removeValue(forKey: id)
            handlers.removeValue(forKey: id)
            owners.removeValue(forKey: id)
        }
    }

    /// Claims a combination. Returns false when it is already spoken for by
    /// macOS or another app, so the UI can show it as unavailable.
    @discardableResult
    func register(_ shortcut: Shortcut, owner: String, handler: @escaping () -> Void) -> Bool {
        guard shortcut.isValid else { return false }
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x47525050), id: id) // 'GRPP'
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         shortcut.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return false }

        refs[id] = ref
        handlers[id] = handler
        owners[id] = owner
        return true
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, nil, nil)
    }
}

private let hotkeyEventHandler: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &id)
    guard status == noErr else { return status }
    let hotKeyNumber = id.id
    DispatchQueue.main.async { HotkeyCenter.shared.fire(id: hotKeyNumber) }
    return noErr
}

/// Captures the next key press for the shortcut recorder.
///
/// A *local* monitor is enough — the recorder only runs while our own window
/// is focused — and unlike a global monitor it needs no Accessibility grant.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    private var monitor: Any?
    private var onCapture: ((Shortcut?) -> Void)?

    func start(_ completion: @escaping (Shortcut?) -> Void) {
        stop()
        isRecording = true
        onCapture = completion

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            // Escape abandons, delete clears the binding.
            if event.keyCode == UInt16(kVK_Escape) {
                self.finish(nil, cleared: false)
                return nil
            }
            if event.keyCode == UInt16(kVK_Delete) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self.finish(nil, cleared: true)
                return nil
            }

            var carbon: UInt32 = 0
            let flags = event.modifierFlags
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

            let shortcut = Shortcut(keyCode: UInt32(event.keyCode),
                                    modifiers: carbon,
                                    label: KeyLabels.label(keyCode: event.keyCode,
                                                           charactersIgnoringModifiers: event.charactersIgnoringModifiers))
            guard shortcut.isValid else { return nil } // keep listening
            self.finish(shortcut, cleared: false)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func finish(_ shortcut: Shortcut?, cleared: Bool) {
        let completion = onCapture
        onCapture = nil
        stop()
        if shortcut != nil || cleared { completion?(shortcut) }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
