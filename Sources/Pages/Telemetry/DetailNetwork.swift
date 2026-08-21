import SwiftUI

// MARK: - Network
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

// MARK: - Network

struct NetworkDetail: View {
    @ObservedObject var widget: NetworkTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            Well {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DOWN").font(Theme.mono(9, .semibold)).tracking(0.8)
                            .foregroundStyle(Theme.textMuted)
                        Text(Format.rate(reading.down))
                            .font(Theme.mono(15, .medium).monospacedDigit())
                            .foregroundStyle(Theme.trace)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("UP").font(Theme.mono(9, .semibold)).tracking(0.8)
                            .foregroundStyle(Theme.textMuted)
                        Text(Format.rate(reading.up))
                            .font(Theme.mono(15, .medium).monospacedDigit())
                            .foregroundStyle(Theme.orange)
                    }
                }
                ZStack {
                    Sparkline(values: widget.history, floor: WidgetKind.network.plotFloor,
                              height: 30).equatable()
                    Sparkline(values: widget.upHistory, floor: WidgetKind.network.plotFloor,
                              tint: Theme.orange, height: 30).equatable()
                }
                StatRow(label: "INTERFACES", value: "\(reading.interfaces)",
                        detail: "↓\(Format.bytes(reading.downTotal)) ↑\(Format.bytes(reading.upTotal))")
            }

            // Two halves, each sorted strictly by its own direction, so the
            // busiest downloader and the busiest uploader are both visible —
            // one combined list ranked by total hides whichever is smaller.
            TrafficTable(title: "INBOUND PROCESSES", glyph: "↓", tint: Theme.trace,
                         rows: reading.talkers.sorted { $0.downTotal > $1.downTotal },
                         value: \.downTotal)
            TrafficTable(title: "OUTBOUND PROCESSES", glyph: "↑", tint: Theme.orange,
                         rows: reading.talkers.sorted { $0.upTotal > $1.upTotal },
                         value: \.upTotal)
        } else {
            Waiting()
        }
    }
}

/// One direction's table: the same processes, ranked by that direction alone,
/// with the columns named.
private struct TrafficTable: View {
    let title: String
    let glyph: String
    let tint: Color
    let rows: [NetworkTalkers.Talker]
    let value: KeyPath<NetworkTalkers.Talker, UInt64>

    /// Both halves show the same number of rows, so neither direction looks
    /// more important than the other.
    private static let limit = 4

    var body: some View {
        Well {
            HStack(spacing: 5) {
                Text(glyph).font(Theme.mono(10, .semibold)).foregroundStyle(tint)
                Text(title)
                    .font(Theme.mono(9, .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
            }
            TableHeader(columns: [("PROCESS NAME", .leading, nil),
                                  ("CONNS", .trailing, 40),
                                  ("TRAFFIC", .trailing, 68)])
            if rows.isEmpty {
                Text("No attributed connections")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.textMuted)
            } else {
                ForEach(rows.prefix(Self.limit)) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(Theme.mono(10)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(row.connections)")
                            .font(Theme.mono(10).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 40, alignment: .trailing)
                        Text(Format.bytes(row[keyPath: value]))
                            .font(Theme.mono(10, .medium).monospacedDigit())
                            .foregroundStyle(tint)
                            .frame(width: 68, alignment: .trailing)
                    }
                }
            }
        }
    }
}
