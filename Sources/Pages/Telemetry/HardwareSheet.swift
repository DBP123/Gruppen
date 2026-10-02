import AppKit
import SwiftUI

/// The dashboard's Hardware tab: what this Mac is, as opposed to what it is
/// doing.
///
/// The banner, then the rest of the spec sheet. Nothing here samples: every
/// value is read once when the tab appears. They are fixed for as long as the
/// machine is on — displays aside, and a display plugged in while you are
/// reading this page is not worth a timer; switching tabs re-reads it.
struct HardwareSheet: View {
    @State private var details: HardwareDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SystemHeroBanner()
            if let details {
                HardwareDetailsCard(details: details)
            }
        }
        .onAppear { details = .current() }
    }
}

/// The facts the banner has no room for, read in one go.
struct HardwareDetails {
    var cores: CoreLayout
    var drive: StorageIdentity?
    var displays: (count: Int, hasBuiltIn: Bool)

    /// Main-actor because displays come from `NSScreen`.
    @MainActor
    static func current() -> HardwareDetails {
        HardwareDetails(cores: .current(),
                        drive: StorageIdentity.shared,
                        displays: HardwareProfileStore.attachedDisplays())
    }
}

/// Three columns of two, in the banner's own construction, so the two plates
/// read as one sheet: the processor, the drive, the displays.
struct HardwareDetailsCard: View {
    let details: HardwareDetails

    var body: some View {
        // Built the way the banner's row is — a glyph-wide slot, the columns,
        // a trailing spacer, all 18pt apart — so the two plates' columns line
        // up by construction rather than by a padding someone has to keep in
        // step with the banner.
        HStack(alignment: .top, spacing: 18) {
            Color.clear.frame(width: 62, height: 1)
            HStack(alignment: .top, spacing: 18) {
                SpecColumn(rows: processor)
                SpecColumn(rows: [("DRIVE", details.drive?.model ?? "—"),
                                  ("PROTOCOL", details.drive?.revision ?? "—")])
                SpecColumn(rows: [("DISPLAYS", "\(details.displays.count)"),
                                  ("BUILT-IN", details.displays.hasBuiltIn ? "Yes" : "No")])
            }
            Spacer(minLength: 0)
        }
        .specPlate()
    }

    /// Performance and efficiency cores where the chip has both kinds; cores
    /// and threads where it has one kind, which is every Intel Mac.
    private var processor: [(String, String)] {
        let cores = details.cores
        if let performance = cores.performance, let efficiency = cores.efficiency {
            return [("P-CORES", "\(performance)"), ("E-CORES", "\(efficiency)")]
        }
        return [("CORES", "\(cores.physical)"), ("THREADS", "\(cores.logical)")]
    }
}
