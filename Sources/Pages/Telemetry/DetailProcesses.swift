import SwiftUI

// MARK: - Processes
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

/// The heaviest processes, as a card.
///
/// The dropdown renders this through `ProcessWell`, which brings its own
/// titled housing; on the dashboard the card supplies that, so this is the
/// table on its own.
struct ProcessDetail: View {
    @ObservedObject var widget: ProcessTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            VStack(alignment: .leading, spacing: 5) {
                TableHeader(columns: [("PROCESS", .leading, nil),
                                      ("MEMORY", .trailing, 62),
                                      ("CPU", .trailing, 46)])
                ForEach(reading.top) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Format.bytes(row.footprint))
                            .font(Theme.mono(9.5).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 62, alignment: .trailing)
                        Text(Format.percent(row.cpu, decimals: 1))
                            .font(Theme.mono(10, .medium).monospacedDigit())
                            .foregroundStyle(row.cpu > 0.5 ? Theme.orange : Theme.textSecondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                StatRow(label: "PROCESSES LIVE", value: "\(reading.total)")
                    .padding(.top, 2)
            }
        } else {
            Waiting()
        }
    }
}
