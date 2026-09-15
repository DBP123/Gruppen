import AppKit
import CoreGraphics
import Foundation

/// Profiles the host Mac once, then keeps the answer.
///
/// ## What is re-read and what is not
///
/// | | Source | When |
/// |---|---|---|
/// | Serial, chip, RAM, storage, GPU cores | IOKit / `sysctl` | once, ever |
/// | OS version and build | `sysctl` | every launch |
/// | Display count, built-in display | `NSScreen` | every launch |
///
/// The first row is soldered to the logic board. Re-deriving it on every launch
/// was work with a guaranteed answer, so it is captured once into
/// `hardware-profile.json` and read back from there.
///
/// ## Where the cache lives, and why not where the spec said
///
/// Application Support, beside `groups.json`, `scripts.json` and
/// `profiles.json` — **not** the Stash folder. Stash's scratch directory is
/// wiped by `IngestionManager.purgeScratch()` on every launch by design, because
/// shelves are not meant to survive a relaunch. A cache written there would be
/// deleted before it was ever read, and the "query once" policy would silently
/// become "query every launch".
///
/// ## The probe never blocks the UI
///
/// `refresh()` returns immediately. The IOKit and `sysctl` work happens on a
/// `.userInitiated` background queue and the result is published back on the
/// main actor. Nothing here runs on a timer: a profile is captured at launch and
/// when the user asks, and at no other time.
@MainActor
final class HardwareProfileStore: ObservableObject {
    static let shared = HardwareProfileStore()

    /// The current best answer. Populated synchronously from cache — or the
    /// safe fallback — so the first frame has something real to draw, then
    /// replaced when the background pass lands.
    @Published private(set) var profile: MacHardwareProfile

    /// Set while a probe is in flight, for the settings pane's spinner.
    @Published private(set) var isProbing = false

    /// Whether the last pass actually reached the hardware, as opposed to
    /// reading the cache because detection is switched off.
    @Published private(set) var lastProbeWasLive = false

    private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Gruppen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("hardware-profile.json")
    }

    init(fileURL: URL = HardwareProfileStore.defaultFileURL) {
        self.fileURL = fileURL
        profile = Self.load(from: fileURL) ?? .fallback
    }

    // MARK: Launch pass

    /// The startup hook. Cheap, asynchronous, and safe to call more than once.
    ///
    /// With detection off this does nothing at all — not a reduced probe, no
    /// probe. The cached profile loaded in `init` is what the app runs on, and
    /// no IOKit or `sysctl` call is made on the user's behalf.
    func refreshOnLaunch() {
        guard AppSettings.shared.hardwareAutoDetection else {
            lastProbeWasLive = false
            return
        }
        refresh()
    }

    /// Probes the hardware and publishes the result.
    ///
    /// The immutable half is reused from the cache when there is one, so a
    /// normal launch costs three `sysctl` reads and one display enumeration.
    /// Only a machine with no cache — or one whose serial no longer matches the
    /// cache, which means the file was copied from another Mac — pays for the
    /// full capture.
    func refresh(forceFullCapture: Bool = false) {
        guard !isProbing else { return }
        isProbing = true

        let cached = forceFullCapture ? nil : Self.load(from: fileURL)
        let url = fileURL
        // Read here, on the main actor, and carried into the probe.
        //
        // `CGGetActiveDisplayList` looked like the right call and is not: off
        // the main thread it reports **zero displays** on a machine that plainly
        // has one — measured, with `CGMainDisplayID()` returning a valid id at
        // the same moment. It needs a window server connection that a background
        // queue does not reliably hold. `NSScreen` is the API that answers this
        // honestly, and it is main-actor only, so the answer travels rather than
        // the question.
        let screens = Self.attachedDisplays()

        // `.userInitiated` rather than `.utility`: the banner and the settings
        // pane are both waiting on this, so it is latency that matters, not
        // throughput. It is also over in a few milliseconds.
        // `[weak self]` on the outer closure too: a weak capture only on the
        // inner `Task` leaves the dispatch block holding `self` strongly, which
        // is two different answers about the same object.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let probed = Self.probe(reusing: cached, displays: screens)
            Self.save(probed, to: url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.profile = probed
                self.isProbing = false
                self.lastProbeWasLive = true
            }
        }
    }

    /// Throws the cache away and re-reads everything, including the parts that
    /// cannot change. The escape hatch for a profile captured wrong.
    func resetAndRecapture() {
        try? FileManager.default.removeItem(at: fileURL)
        refresh(forceFullCapture: true)
    }

    // MARK: Probing

    /// The attached screens, as a count and whether one of them is the laptop's
    /// own. Main-actor, because `NSScreen` is.
    static func attachedDisplays() -> (count: Int, hasBuiltIn: Bool) {
        let screens = NSScreen.screens
        let builtIn = screens.contains { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
        return (screens.count, builtIn)
    }

    /// Builds a profile, reusing the immutable half of `cached` when it belongs
    /// to this machine.
    private nonisolated static func probe(reusing cached: MacHardwareProfile?,
                                          displays: (count: Int, hasBuiltIn: Bool)) -> MacHardwareProfile {
        let identifier = ModelNameResolver.modelIdentifier()
        let chip = ModelNameResolver.chipName()
        let family = ModelNameResolver.family(identifier: identifier, chipName: chip)

        // A cache whose serial does not match this machine came from somewhere
        // else — a migrated home directory, a restored backup — and none of its
        // immutable half is true here.
        let serial = ModelNameResolver.serialNumber()
        let reusable = cached.flatMap { $0.buildInfo.hardwareSerialNumber == serial ? $0 : nil }
        let build = SystemBuildInfo(
            hardwareSerialNumber: serial,
            chipArchitecture: chip,
            totalMemoryGB: reusable?.buildInfo.totalMemoryGB ?? memoryGB(),
            totalStorageGB: reusable?.buildInfo.totalStorageGB ?? storageGB(),
            gpuCoreCount: reusable?.buildInfo.gpuCoreCount ?? AppleSiliconTelemetry.graphicsCoreCount,
            osVersion: ModelNameResolver.sysctlString("kern.osproductversion") ?? "—",
            osBuildNumber: ModelNameResolver.sysctlString("kern.osversion") ?? "—",
            displayCount: displays.count,
            hasBuiltInDisplay: displays.hasBuiltIn)

        return MacHardwareProfile(
            rawModelIdentifier: identifier,
            marketingModelName: ModelNameResolver.marketingName(family: family, chipName: chip),
            family: family,
            chassis: family.chassis,
            buildInfo: build,
            capturedAt: reusable?.capturedAt ?? Date())
    }

    private nonisolated static func memoryGB() -> Int {
        guard let bytes = ModelNameResolver.sysctlInteger("hw.memsize") else { return 0 }
        return Int((Double(bytes) / 1_073_741_824).rounded())
    }

    /// Reported in the same base the drive is sold in, so a 1 TB SSD reads as
    /// 1000 and not 931.
    private nonisolated static func storageGB() -> Int {
        guard let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeTotalCapacityKey]),
            let total = values.volumeTotalCapacity else { return 0 }
        return Int((Double(max(total, 0)) / 1_000_000_000).rounded())
    }

    // MARK: Persistence

    private nonisolated static func load(from url: URL) -> MacHardwareProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        // Must match the encoder below. Left at the default it silently failed
        // to decode every profile this app had ever written, which reads as
        // "no cache" — the probe would have run in full on every launch and the
        // whole caching policy would have been decorative.
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MacHardwareProfile.self, from: data)
    }

    private nonisolated static func save(_ profile: MacHardwareProfile, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profile) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
