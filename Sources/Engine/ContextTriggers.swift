import AppKit
import CoreAudio
import CoreLocation
import CoreWLAN
import Foundation

// The context a trigger can wait on — displays, Wi-Fi, the sound output — each
// as one small watcher that exists only while a trigger needs it. Every one of
// them is a callback the system makes; none of them looks at anything on a
// schedule.

/// External displays coming and going.
@MainActor
final class DisplayWatcher {
    private var observer: NSObjectProtocol?
    private var count = NSScreen.screens.count

    /// `true` when a display was added, `false` when one went away.
    init(onChange: @escaping @MainActor (Bool) -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = NSScreen.screens.count
                defer { self.count = now }
                // Resolution and arrangement changes post this too; only a
                // change in how many screens there are is a display event.
                if now != self.count { onChange(now > self.count) }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// The Wi-Fi network changing. CoreWLAN reports the change; the network's name
/// is only shared with apps that have Location Services, so the first watcher
/// asks for it once.
final class WiFiWatcher: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    private let onJoin: (String) -> Void
    private let location = CLLocationManager()
    private var last: String?

    init(onJoin: @escaping (String) -> Void) {
        self.onJoin = onJoin
        super.init()
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        last = client.interface()?.ssid()
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
    }

    func stop() {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        let name = client.interface(withName: interfaceName)?.ssid()
        defer { last = name }
        guard let name, name != last else { return }
        DispatchQueue.main.async { self.onJoin(name) }
    }
}

/// The default sound output changing device — headphones plugged in, AirPods
/// connecting, a display's speakers taking over.
final class AudioOutputWatcher {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var block: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping (String) -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            if let name = Self.currentOutputName() { onChange(name) }
        }
        block = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    func stop() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        self.block = nil
    }

    static func currentOutputName() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
