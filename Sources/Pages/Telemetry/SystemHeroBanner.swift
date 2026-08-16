import AppKit
import IOKit
import SwiftUI

/// What machine this is.
///
/// Everything here is fixed for the life of the boot, so it is gathered once
/// into a `static let` and never sampled. None of it belongs in a telemetry
/// module: a serial number does not have a history and cannot be plotted.
struct MacIdentity {
    /// What the owner calls this machine — the name set in System Settings and
    /// shown on the network, e.g. "Dhilan's MacBook Pro".
    var computerName: String
    var modelIdentifier: String
    var serialNumber: String
    var chip: String
    var graphics: String
    var memory: String
    var storage: String
    var systemVersion: String
    var buildNumber: String
    /// SF Symbol standing in for the machine's silhouette.
    var glyph: String

    static let shared: MacIdentity = {
        let platform = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        defer { if platform != 0 { IOObjectRelease(platform) } }

        func property(_ key: String) -> Any? {
            guard platform != 0 else { return nil }
            return IORegistryEntryCreateCFProperty(platform, key as CFString,
                                                   kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        /// Device-tree strings arrive as `CFData` with a trailing NUL.
        func text(_ key: String) -> String? {
            if let value = property(key) as? String { return value }
            guard let data = property(key) as? Data else { return nil }
            return String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        // Apple Silicon does not publish a marketing name anywhere readable:
        // there is no `product-name` in the device tree, only the model
        // identifier "Mac17,9", which says nothing to a reader. The name the
        // owner gave the machine is both present on every Mac and the one they
        // actually recognise, so that is the headline; the identifier stays
        // below as a spec.
        let identifier = sysctlString("hw.model") ?? "Mac"
        let name = Host.current().localizedName ?? identifier

        let info = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion") ?? "—"

        return MacIdentity(
            computerName: name,
            modelIdentifier: identifier,
            serialNumber: text("IOPlatformSerialNumber") ?? "—",
            chip: CPUSampler.brand,
            graphics: graphicsDescription(),
            memory: "\(Format.bytes(MemorySampler.installed)) unified",
            storage: storageDescription(),
            systemVersion: "macOS \(info.majorVersion).\(info.minorVersion)"
                + (info.patchVersion > 0 ? ".\(info.patchVersion)" : ""),
            buildNumber: build,
            glyph: silhouette())
    }()

    /// Which machine to draw.
    ///
    /// Not from the model string: Apple Silicon reports `Mac17,9`, which says
    /// nothing about the form factor, and matching on "MacBook" quietly fails on
    /// every recent portable. A battery is the reliable tell — a Mac with one is
    /// a laptop, and no desktop has an `AppleSmartBattery` node. The remaining
    /// desktops are separated by their model identifiers, which *do* still carry
    /// a family name.
    private static func silhouette() -> String {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        if battery != 0 { IOObjectRelease(battery); return "laptopcomputer" }
        let identifier = sysctlString("hw.model") ?? ""
        if identifier.hasPrefix("Macmini") { return "macmini" }
        if identifier.hasPrefix("MacPro") { return "macpro.gen3" }
        if identifier.hasPrefix("Mac13") || identifier.contains("Studio") { return "macstudio" }
        return "desktopcomputer"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func graphicsDescription() -> String {
        let cores = SiliconSampler.cores
        // On Apple Silicon the GPU is part of the chip, so naming it separately
        // would just repeat the chip name; the core count is the real content.
        return cores > 0 ? "\(cores)-core GPU" : "Integrated"
    }

    private static func storageDescription() -> String {
        let drive = StorageIdentity.shared?.model
        guard let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeTotalCapacityKey]),
            let total = values.volumeTotalCapacity else { return drive ?? "—" }
        let size = Format.bytes(UInt64(max(total, 0)))
        return drive.map { "\(size) · \($0)" } ?? size
    }
}

/// The banner at the top of Guardrails.
///
/// Deliberately not a telemetry card: nothing in it moves, so it carries no
/// gauges and no colour beyond the accent on the machine's name. It is there to
/// say what this Mac *is*, which is the context every number below it is read
/// against.
struct SystemHeroBanner: View {
    private let mac = MacIdentity.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: mac.glyph)
                .font(.system(size: 42, weight: .thin))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 62, height: 52)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.computerName)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(mac.systemVersion)  ·  Build \(mac.buildNumber)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                }

                // Two columns: what the machine is on the left, what it is made
                // of on the right.
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        SpecLine("MODEL", mac.modelIdentifier)
                        SpecLine("SERIAL", mac.serialNumber)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        SpecLine("CHIP", mac.chip)
                        SpecLine("GRAPHICS", mac.graphics)
                        SpecLine("MEMORY", mac.memory)
                        SpecLine("STORAGE", mac.storage)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .fill(Theme.machined)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

/// A fixed-width key and its value, so both columns align down the banner.
private struct SpecLine: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) { self.key = key; self.value = value }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(Theme.mono(8.5, .semibold))
                .tracking(0.7)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
