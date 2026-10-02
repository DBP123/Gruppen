import AppKit
import SwiftUI

/// What each running application is costing, in watts.
///
/// ## Lifecycle
///
/// The monitor is created by the view and started in `onAppear`, destroyed in
/// `onDisappear`. Both only fire while this fold is open, so a collapsed section
/// runs no timer, sweeps no processes and holds no SMC connection. That is the
/// same contract `EnergyImpactRows` beside it keeps, and the reason the fold is
/// session-only rather than `@AppStorage`: persisting "open" would start the
/// heaviest sweep in the app on every launch, on every surface that draws this
/// card, whether or not anyone was reading it.
///
/// ## Why the last row is not an application
///
/// The rows are shares of a package figure, and applications do not account for
/// all of it — the kernel, the window server, every daemon, and the helpers whose
/// parent is `launchd` rather than the app that asked for them. That remainder is
/// shown rather than hidden, because the alternative is dividing the whole
/// machine's power between the listed apps and quietly overstating every one of
/// them. See `AppPowerSampler` for the arithmetic and for what it cannot see.
struct AppPowerBreakdownView: View {
    @StateObject private var monitor = AppPowerMonitor()

    var body: some View {
        AppPowerTable(reading: monitor.reading)
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
    }
}

/// The table itself, given a reading rather than fetching one.
///
/// Split from the view above so the layout is a pure function of a `Reading`:
/// every state it can be in — measuring, nothing drawing, a full list, a modelled
/// package — can be rendered and looked at without waiting for a machine to
/// happen to be in that state.
struct AppPowerTable: View {
    let reading: AppPowerSampler.Reading?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TableHeader(columns: [("APPLICATION", .leading, nil),
                                  ("CPU", .trailing, 44),
                                  ("WATTS", .trailing, 52)])

            if let reading {
                if reading.rows.isEmpty {
                    // A real state, not a failure: every application is idle and
                    // the machine's power is going to the system.
                    Text("No application is drawing measurably.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.vertical, 3)
                } else {
                    ForEach(reading.rows) { row in
                        AppPowerRowView(row: row, peak: reading.rows[0].watts)
                    }
                }

                DashedRule()
                SystemRemainderRow(reading: reading)
                BasisFootnote(basis: reading.basis, package: reading.packageWatts)
            } else {
                // A rate needs two samples. There is genuinely nothing true to
                // show for one interval, so it says so rather than printing zeros.
                Text("Measuring…")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 3)
            }
        }
    }
}

/// One application: its icon, its name, its CPU, its watts, and a bar.
///
/// The bar is scaled to the heaviest row rather than to the package, because at
/// 2 W out of 18 every bar would otherwise be a stub and the ranking — which is
/// the thing this list is actually for — would be unreadable.
private struct AppPowerRowView: View {
    let row: AppPowerRow
    let peak: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                icon.frame(width: 13, height: 13)
                Text(row.name)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Says when a row is more than one process, which is what makes
                // a browser's number larger than its window count suggests.
                if row.processCount > 1 {
                    Text("×\(row.processCount)")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.textMuted.opacity(0.7))
                        .fixedSize()
                }
                Spacer(minLength: 6)
                Text(Format.percent(row.cpu, decimals: 0))
                    .font(Theme.mono(10).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 44, alignment: .trailing)
                Text(String(format: "%.2f", row.watts))
                    .font(Theme.mono(10.5, .medium).monospacedDigit())
                    .foregroundStyle(AppPowerTint.of(row.watts))
                    .frame(width: 52, alignment: .trailing)
            }
            ShareBar(fraction: peak > 0 ? row.watts / peak : 0,
                     tint: AppPowerTint.of(row.watts))
        }
    }

    /// The app's real icon, from the cache the rest of the app shares, so a list
    /// of eight does not hit IconServices eight times per redraw.
    ///
    /// Resolved from the running process rather than from a bundle identifier
    /// lookup: `NSRunningApplication` already has the icon, and asking
    /// `NSWorkspace` to find the bundle by identifier would touch the Launch
    /// Services database once per row per frame.
    ///
    /// The fallback — an app that quit between the sample and this draw — is a
    /// symbol tinted explicitly. Handed over as an `NSImage` it is a template
    /// image with no colour of its own, and it rendered black on the black well:
    /// an invisible icon and a gap before the name that looked like a bug.
    @ViewBuilder
    private var icon: some View {
        if let url = NSRunningApplication(processIdentifier: row.pid)?.bundleURL {
            Image(nsImage: IconCache.shared.icon(for: url))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
    }
}

/// Everything the applications do not account for.
///
/// The detail is its *share*, not the package total. It used to read
/// `of 3.10 W  3.10 W` — the total before the value, which is backwards, and on
/// a quiet machine the same figure printed twice side by side. The package total
/// is stated once, in the footnote, where it is explained.
private struct SystemRemainderRow: View {
    let reading: AppPowerSampler.Reading

    var body: some View {
        StatRow(label: "SYSTEM & BACKGROUND",
                value: String(format: "%.2f W", reading.systemWatts),
                tint: Theme.textSecondary,
                detail: share)
    }

    private var share: String? {
        guard reading.packageWatts > 0 else { return nil }
        return Format.percent(reading.systemWatts / reading.packageWatts, decimals: 0)
    }
}

/// What the numbers above rest on.
///
/// Present on every reading, not only the modelled one. A measured figure that
/// says which instrument measured it is worth more than one that does not, and it
/// is the difference between the live rail and the once-a-minute battery meter
/// that explains why the column sometimes stops moving.
private struct BasisFootnote: View {
    let basis: AppPowerSampler.Basis
    let package: Double

    var body: some View {
        Text(text)
            .font(Theme.mono(8))
            .foregroundStyle(basis.isMeasured ? Theme.textMuted : Theme.amber)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
            .help(help)
    }

    /// The package total lives here and nowhere else in the fold: it is the one
    /// figure every row is a share of, so it belongs beside the sentence saying
    /// what the rows are shares of.
    private var text: String {
        let total = String(format: "%.2f W", package)
        switch basis {
        case .systemRail:
            return "\(basis.label) · \(total) live, shared by CPU time"
        case .packMeter:
            return "\(basis.label) · \(total), republished about once a minute"
        case .model:
            return "\(basis.label) · \(total) estimated — this Mac reports no power rail"
        }
    }

    private var help: String {
        "There is no per-process power sensor on any Mac — the hardware meters the "
        + "whole package. These are that one figure divided by CPU time, so work "
        + "done on the GPU, the disk or the network lands on another row."
    }
}

/// A thin proportional bar under each row.
private struct ShareBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.05))
                Capsule()
                    .fill(tint.opacity(0.65))
                    .frame(width: geometry.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 2)
    }
}

/// The number carries its own verdict, the same way the thermal, power and energy
/// readouts do, so nobody has to know what counts as a lot.
///
/// The bands are for a laptop package: a single application past 5 W is most of a
/// quiet machine's entire draw, and past 12 W it is the reason the fans are on.
private enum AppPowerTint {
    static func of(_ watts: Double) -> Color {
        if watts >= 12 { return Theme.cellLow }
        if watts >= 5 { return Theme.amber }
        return Theme.textPrimary
    }
}
