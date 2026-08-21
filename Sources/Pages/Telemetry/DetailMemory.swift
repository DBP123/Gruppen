import SwiftUI

// MARK: - Memory
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

// MARK: - Memory

struct MemoryDetail: View {
    @ObservedObject var widget: MemoryTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            // No line graph. Memory is a pool that is divided up, not a quantity
            // that rises and falls — a trace of "used" says nothing about
            // whether the machine is under pressure, and the same 60% can be
            // comfortable or desperate depending on what it is made of.
            Well {
                HStack(alignment: .firstTextBaseline) {
                    Headline(value: Format.bytes(reading.used)
                        .replacingOccurrences(of: " GB", with: ""), unit: "GB IN USE",
                             tint: Theme.cyan)
                    Spacer()
                    Text("OF \(Format.bytes(reading.total))")
                        .font(Theme.mono(9, .semibold)).tracking(0.8)
                        .foregroundStyle(Theme.textMuted)
                }
                SegmentedBar(segments: [
                    .init(fraction: share(reading.app, reading), tint: Theme.cyan),
                    .init(fraction: share(reading.wired, reading), tint: Theme.purple),
                    .init(fraction: share(reading.compressed, reading), tint: Theme.amber),
                    .init(fraction: share(reading.cached, reading), tint: Color(hex: 0x2A3038)),
                ], height: 12)
                HStack(spacing: 0) {
                    Key("APP", Theme.cyan); Key("WIRED", Theme.purple)
                    Key("COMPRESSED", Theme.amber); Key("CACHED", Color(hex: 0x2A3038))
                    Spacer(minLength: 0)
                }
            }

            Well {
                StatRow(label: "APP", value: Format.bytes(reading.app), tint: Theme.cyan)
                StatRow(label: "WIRED", value: Format.bytes(reading.wired), tint: Theme.purple)
                StatRow(label: "COMPRESSED", value: Format.bytes(reading.compressed), tint: Theme.amber)
                StatRow(label: "CACHED", value: Format.bytes(reading.cached))
                StatRow(label: "SWAP",
                        value: reading.swapTotal > 0
                            ? "\(Format.bytes(reading.swapUsed)) / \(Format.bytes(reading.swapTotal))"
                            : "NONE",
                        tint: reading.swapUsed > 0 ? Theme.crimson : Theme.textPrimary)
                StatRow(label: "PAGE IN / OUT",
                        value: String(format: "%.0f / %.0f per s", reading.pageInRate, reading.pageOutRate),
                        tint: reading.pageOutRate > 0 ? Theme.crimson : Theme.textPrimary)
                StatRow(label: "COMPRESS / DECOMPRESS",
                        value: String(format: "%.0f / %.0f per s",
                                      reading.compressRate, reading.decompressRate))
            }

            if !reading.consumers.isEmpty {
                Well {
                    TableHeader(columns: [("PROCESS NAME", .leading, nil),
                                          ("MEMORY", .trailing, 74)])
                    ForEach(reading.consumers) { consumer in
                        HStack(spacing: 8) {
                            Text(consumer.name)
                                .font(Theme.mono(10)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Format.bytes(consumer.footprint))
                                .font(Theme.mono(10, .medium).monospacedDigit())
                                .foregroundStyle(Theme.cyan)
                                .frame(width: 74, alignment: .trailing)
                        }
                    }
                }
            }
        } else {
            Waiting()
        }
    }

    /// Each pool as a share of installed memory.
    private func share(_ part: UInt64, _ reading: MemorySampler.Reading) -> Double {
        reading.total > 0 ? Double(part) / Double(reading.total) : 0
    }
}
