import AppKit
import SwiftUI

/// The banner at the top of the telemetry dashboard.
///
/// Not a telemetry card: nothing in it moves, so it carries no gauges and no
/// colour beyond the machine's own drawing. It says what this Mac *is*, which is
/// the context every number below it is read against.
///
/// ## The layout, and why it changed
///
/// It used to be two columns — two rows on the left, four on the right — which
/// left a hand's width of dead space under `SERIAL` and made the right-hand
/// column read as the only real content. The specs now sit in **three columns of
/// two**, grouped by what they answer: what the chip is, what it holds, and what
/// the machine is on paper. Even columns, no orphan rows, and the eye gets three
/// short lists instead of one long one beside one short one.
struct SystemHeroBanner: View {
    @EnvironmentObject private var hardware: HardwareProfileStore

    var body: some View {
        SystemHeroCard(profile: hardware.profile)
    }
}

/// The banner itself, over a plain value.
///
/// Split from the environment wrapper above so it can be rendered without an
/// app around it — by `ImageRenderer` for a design review, or by a test. A view
/// that can only be seen by launching the whole app is a view nobody checks.
struct SystemHeroCard: View {
    let profile: MacHardwareProfile

    /// The name the owner gave the machine, from System Settings. Not part of
    /// the hardware profile — it is neither hardware nor immutable, and a person
    /// can rename their Mac at any time.
    var computerName: String = Host.current().localizedName ?? "Mac"

    private var build: SystemBuildInfo { profile.buildInfo }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            MacGlyph(family: profile.family, size: 52)
                .frame(width: 62, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 14) {
                identity
                specs
            }
            Spacer(minLength: 0)
        }
        .padding(14)
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

    /// Name, then what the machine actually is, then what it is running.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(computerName)
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            // The marketing name, never the `Mac17,9` identifier. That is a spec
            // row below, where a reader who wants it can find it.
            Text(profile.marketingModelName)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            Text("macOS \(build.osVersion)  ·  Build \(build.osBuildNumber)")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
    }

    /// Three columns of two. Each column is one question.
    private var specs: some View {
        HStack(alignment: .top, spacing: 18) {
            SpecColumn(rows: [("CHIP", build.chipArchitecture),
                              ("GRAPHICS", graphics)])
            SpecColumn(rows: [("MEMORY", capacity(build.totalMemoryGB, suffix: "unified")),
                              ("STORAGE", capacity(build.totalStorageGB, suffix: nil))])
            SpecColumn(rows: [("MODEL", profile.rawModelIdentifier),
                              ("SERIAL", build.hardwareSerialNumber)])
        }
    }

    private var graphics: String {
        build.gpuCoreCount > 0 ? "\(build.gpuCoreCount)-core GPU" : "Integrated"
    }

    /// An em dash rather than "0 GB" while the first probe is still in flight —
    /// a zero is a measurement, and this is the absence of one.
    private func capacity(_ gigabytes: Int, suffix: String?) -> String {
        guard gigabytes > 0 else { return "—" }
        let value = gigabytes >= 1000
            ? String(format: "%.1f TB", Double(gigabytes) / 1000).replacingOccurrences(of: ".0 TB", with: " TB")
            : "\(gigabytes) GB"
        return suffix.map { "\(value) \($0)" } ?? value
    }
}

/// One column of key/value rows, keys aligned within the column.
///
/// The key column is sized to the widest label this app actually uses
/// (`GRAPHICS`) rather than to its own contents, so all three columns line up
/// with each other instead of each finding its own width.
private struct SpecColumn: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.0) { key, value in
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
