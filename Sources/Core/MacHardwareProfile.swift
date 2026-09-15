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
        buildInfo = try box.decode(SystemBuildInfo.self, forKey: .buildInfo)
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
