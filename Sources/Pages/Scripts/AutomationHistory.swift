import SwiftUI

// The record of an automation's runs, shown when its LAST readout is opened.

/// The runs behind the LAST readout: the figures, how long runs have taken,
/// and each run with a lamp per step.
struct ScriptHistory: View {
    let runs: [ScriptRunRecord]
    let onClear: () -> Void

    private var succeeded: Int { runs.filter(\.succeeded).count }
    private var median: TimeInterval {
        let sorted = runs.map(\.duration).sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("HISTORY")
                    .font(Theme.mono(8.5, .semibold)).tracking(0.9)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Button("Clear", action: onClear).industrialButton(.ghost, compact: true)
            }
            HStack(spacing: 10) {
                figure("RUNS", "\(runs.count)")
                figure("SUCCESS", "\(Int((Double(succeeded) / Double(max(runs.count, 1)) * 100).rounded()))%")
                figure("MEDIAN", Self.duration(median))
                RunBars(runs: Array(runs.suffix(30)))
                    .frame(maxWidth: .infinity)
                    .padding(9)
                    .machined(cornerRadius: Theme.radiusMd, fill: Theme.well)
            }
            Well {
                ForEach(runs.reversed().prefix(12)) { run in
                    HStack(spacing: 8) {
                        Text(Self.time(run.date))
                            .font(Theme.mono(9).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                        Text(run.source.uppercased())
                            .font(Theme.mono(8, .semibold)).tracking(0.6)
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 78, alignment: .leading)
                        HStack(spacing: 3) {
                            ForEach(Array(run.steps.enumerated()), id: \.offset) { _, outcome in
                                Circle().fill(outcome.ok ? Theme.green : Theme.red).frame(width: 5, height: 5)
                            }
                        }
                        .frame(width: 44, alignment: .leading)
                        Text(run.summary)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(run.succeeded ? Theme.textSecondary : Theme.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                        Spacer(minLength: 6)
                        Text(Self.duration(run.duration))
                            .font(Theme.mono(9).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                    .help(run.steps.map { "\($0.ok ? "✓" : "✗") \($0.label): \($0.message)" }.joined(separator: "\n"))
                }
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.mono(8, .semibold)).tracking(0.9).foregroundStyle(Theme.textMuted)
            Text(value).font(Theme.mono(15, .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
        .frame(width: 74, alignment: .leading)
        .padding(9)
        .machined(cornerRadius: Theme.radiusMd, fill: Theme.well)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.2fs", seconds) : String(format: "%.0fs", seconds)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }
}

/// One bar per run, oldest on the left: its height is how long the run took,
/// its colour whether it worked. A slow run and a failed one both stand out
/// without reading a number.
private struct RunBars: View {
    let runs: [ScriptRunRecord]

    var body: some View {
        let longest = max(runs.map(\.duration).max() ?? 0, 0.001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(runs) { run in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(run.succeeded ? Theme.green.opacity(0.75) : Theme.red)
                    .frame(width: 6, height: max(3, 34 * run.duration / longest))
                    .help("\(ScriptHistory.time(run.date)) · \(ScriptHistory.duration(run.duration))")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 34, alignment: .bottom)
    }
}
