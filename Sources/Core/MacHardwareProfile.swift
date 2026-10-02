import AppKit
import Foundation
import IOKit

// What machine this is, worked out once and remembered.
//
// Everything here used to be recomputed from scratch on every launch inside
// `MacIdentity`. Most of it cannot change: a serial number, a chip, the amount
// of soldered memory. This splits the fixed half from the half that genuinely
// moves — the OS build, the displays you have plugged in — so a launch pays for
// the second and reads the first out of a file.

/// The shape of the machine. Drives which telemetry is even applicable: a Mac
/// with no battery has no power rail worth drawing.
enum MacChassis: String, Codable, CaseIterable {
    case laptop, desktop, allInOne

    var label: String {
        switch self {
        case .laptop: return "Laptop"
        case .desktop: return "Desktop"
        case .allInOne: return "All-in-one"
        }
    }
}

/// Which Mac this is, as a product line rather than a board revision.
enum MacFamily: String, Codable, CaseIterable {
    case macBookPro, macBookAir, iMac, macMini, macStudio, macPro, unknown

    /// The name Apple puts on the box.
    var marketingName: String {
        switch self {
        case .macBookPro: return "MacBook Pro"
        case .macBookAir: return "MacBook Air"
        case .iMac: return "iMac"
        case .macMini: return "Mac mini"
        case .macStudio: return "Mac Studio"
        case .macPro: return "Mac Pro"
        case .unknown: return "Mac"
        }
    }

    var chassis: MacChassis {
        switch self {
        case .macBookPro, .macBookAir: return .laptop
        case .iMac: return .allInOne
        case .macMini, .macStudio, .macPro: return .desktop
        case .unknown: return .desktop
        }
    }

    /// Whether this machine has a battery worth reporting on. Used to drop the
    /// power rail entirely on a machine that is always on wall power.
    var hasBattery: Bool { chassis == .laptop }
}

/// The half of the profile that can change under you.
struct SystemBuildInfo: Codable, Hashable {
    // Immutable — physically fixed to the logic board.
    var hardwareSerialNumber: String
    var chipArchitecture: String
    var totalMemoryGB: Int
    var totalStorageGB: Int
    var gpuCoreCount: Int

    // Mutable — re-probed on launch when auto-detection is on.
    var osVersion: String
    var osBuildNumber: String
    var displayCount: Int
    var hasBuiltInDisplay: Bool

    init(hardwareSerialNumber: String, chipArchitecture: String, totalMemoryGB: Int,
         totalStorageGB: Int, gpuCoreCount: Int, osVersion: String, osBuildNumber: String,
         displayCount: Int, hasBuiltInDisplay: Bool) {
        self.hardwareSerialNumber = hardwareSerialNumber
        self.chipArchitecture = chipArchitecture
        self.totalMemoryGB = totalMemoryGB
        self.totalStorageGB = totalStorageGB
        self.gpuCoreCount = gpuCoreCount
        self.osVersion = osVersion
        self.osBuildNumber = osBuildNumber
        self.displayCount = displayCount
        self.hasBuiltInDisplay = hasBuiltInDisplay
    }

    /// Lenient, which `MacHardwareProfile` around it already was and this was
    /// not — so the leniency up there never actually held: `buildInfo` is the
    /// one key it decodes strictly, and this type required all nine of its own.
    /// A cache written before any field here existed was thrown away whole.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        hardwareSerialNumber = try box.decodeIfPresent(String.self, forKey: .hardwareSerialNumber) ?? "—"
        chipArchitecture = try box.decodeIfPresent(String.self, forKey: .chipArchitecture) ?? "—"
        totalMemoryGB = try box.decodeIfPresent(Int.self, forKey: .totalMemoryGB) ?? 0
        totalStorageGB = try box.decodeIfPresent(Int.self, forKey: .totalStorageGB) ?? 0
        gpuCoreCount = try box.decodeIfPresent(Int.self, forKey: .gpuCoreCount) ?? 0
        osVersion = try box.decodeIfPresent(String.self, forKey: .osVersion) ?? "—"
        osBuildNumber = try box.decodeIfPresent(String.self, forKey: .osBuildNumber) ?? "—"
        displayCount = try box.decodeIfPresent(Int.self, forKey: .displayCount) ?? 0
        hasBuiltInDisplay = try box.decodeIfPresent(Bool.self, forKey: .hasBuiltInDisplay) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case hardwareSerialNumber, chipArchitecture, totalMemoryGB, totalStorageGB
        case gpuCoreCount, osVersion, osBuildNumber, displayCount, hasBuiltInDisplay
    }
}

/// Everything Gruppen knows about the host Mac.
struct MacHardwareProfile: Codable, Hashable {
    /// `Mac17,9`. Kept for logs and the spec sheet, never used as a title.
    var rawModelIdentifier: String
    /// `MacBook Pro (Apple M5 Pro)`. What the UI shows.
    var marketingModelName: String
    var family: MacFamily
    var chassis: MacChassis
    var buildInfo: SystemBuildInfo
    /// When the immutable half was captured. A cache older than the machine is
    /// the one case where a full re-probe is warranted.
    var capturedAt: Date

    /// Decoded by hand so a profile written by an earlier build still loads —
    /// the same reason `AppGroup` and `WorkspaceProfile` do it. A missing key
    /// must never be an error, or every field added later invalidates every
    /// cache in the field.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        rawModelIdentifier = try box.decodeIfPresent(String.self, forKey: .rawModelIdentifier) ?? "Mac"
        marketingModelName = try box.decodeIfPresent(String.self, forKey: .marketingModelName) ?? "Mac"
        family = try box.decodeIfPresent(MacFamily.self, forKey: .family) ?? .unknown
        chassis = try box.decodeIfPresent(MacChassis.self, forKey: .chassis) ?? family.chassis
        buildInfo = try box.decodeIfPresent(SystemBuildInfo.self, forKey: .buildInfo)
            ?? SystemBuildInfo(hardwareSerialNumber: "—", chipArchitecture: "—",
                               totalMemoryGB: 0, totalStorageGB: 0, gpuCoreCount: 0,
                               osVersion: "—", osBuildNumber: "—",
                               displayCount: 0, hasBuiltInDisplay: false)
        capturedAt = try box.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case rawModelIdentifier, marketingModelName, family, chassis, buildInfo, capturedAt
    }

    init(rawModelIdentifier: String,
         marketingModelName: String,
         family: MacFamily,
         chassis: MacChassis,
         buildInfo: SystemBuildInfo,
         capturedAt: Date = Date()) {
        self.rawModelIdentifier = rawModelIdentifier
        self.marketingModelName = marketingModelName
        self.family = family
        self.chassis = chassis
        self.buildInfo = buildInfo
        self.capturedAt = capturedAt
    }

    /// The safe answer when there is no cache and probing is switched off.
    ///
    /// A laptop rather than a desktop on purpose: assuming a battery exists and
    /// finding none hides one panel, while assuming none and being wrong hides
    /// the power rail on a machine that runs on one.
    static var fallback: MacHardwareProfile {
        MacHardwareProfile(
            rawModelIdentifier: "Mac",
            marketingModelName: "Mac",
            family: .unknown,
            chassis: .laptop,
            buildInfo: SystemBuildInfo(hardwareSerialNumber: "—",
                                       chipArchitecture: "Apple silicon",
                                       totalMemoryGB: 0,
                                       totalStorageGB: 0,
                                       gpuCoreCount: 0,
                                       osVersion: "—",
                                       osBuildNumber: "—",
                                       displayCount: 1,
                                       hasBuiltInDisplay: true))
    }
}

/// How the CPU's cores are arranged.
///
/// Read from `sysctl` on demand rather than kept in the cached profile: it is
/// four integer reads, it cannot change while the machine is on, and a cached
/// copy would only be one more field for an old profile file to be missing.
struct CoreLayout: Equatable {
    /// Performance and efficiency cores, or nil on a Mac with one kind of core.
    ///
    /// Decided by `hw.nperflevels`, not by whether `hw.perflevel0` exists: an
    /// Intel Mac on a recent macOS reports a single performance level holding
    /// every core, which read naively would call an i9 "8 performance cores,
    /// no efficiency cores".
    var performance: Int?
    var efficiency: Int?
    var physical: Int
    /// Hardware threads. Equal to `physical` on Apple silicon, which has no
    /// simultaneous multithreading; double it on a hyper-threaded Intel part.
    var logical: Int

    static func current() -> CoreLayout {
        func count(_ name: String) -> Int? { ModelNameResolver.sysctlInteger(name).map(Int.init) }
        let fallback = ProcessInfo.processInfo.processorCount
        let split = (count("hw.nperflevels") ?? 1) >= 2
        return CoreLayout(performance: split ? count("hw.perflevel0.physicalcpu") : nil,
                          efficiency: split ? count("hw.perflevel1.physicalcpu") : nil,
                          physical: count("hw.physicalcpu") ?? fallback,
                          logical: count("hw.logicalcpu") ?? fallback)
    }
}
