import SwiftUI

// MARK: - Storage
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

// MARK: - Storage

/// The drive: how it is carved up, and what is moving through it.
///
/// No pie chart and no line graph. A container's allocation is a set of shares
/// of one fixed thing, which is what a stacked bar is for; and the two rates get
/// segmented tachometers, which show a single burst that a smooth trace loses.
struct StorageDetail: View {
    @ObservedObject var widget: StorageTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            Well {
                if let identity = reading.identity {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(identity.model)
                            .font(Theme.mono(11, .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(identity.protocolName)  ·  FW \(identity.firmware)")
                            .font(Theme.mono(8.5)).tracking(0.4)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                APFSCapacityBar(reading: reading)
            }

            Well {
                IOTelemetryMeter(label: "READ", glyph: "↓", tint: Theme.cyan,
                                 rate: reading.readRate, ops: reading.readOps)
                DashedRule().padding(.vertical, 2)
                IOTelemetryMeter(label: "WRITE", glyph: "↑", tint: Theme.amber,
                                 rate: reading.writeRate, ops: reading.writeOps)
            }

            Well {
                HStack(alignment: .top, spacing: 0) {
                    HealthCell(title: "S.M.A.R.T.",
                               value: reading.identity?.smartCapable == true ? "VERIFIED" : "N/A",
                               tint: reading.identity?.smartCapable == true ? Theme.trace : Theme.textMuted)
                    HealthCell(title: "I/O ERRORS",
                               value: "\(reading.errors)",
                               tint: reading.errors == 0 ? Theme.trace : Theme.crimson)
                    HealthCell(title: "WRITTEN (BOOT)",
                               value: Format.bytes(reading.writeTotal),
                               tint: Theme.textPrimary)
                }
            }
        } else {
            Waiting()
        }
    }
}

/// The APFS container as one stacked bar: what is genuinely occupied, what is
/// purgeable — cache and snapshots macOS gives back under pressure, which Finder
/// counts as used — and what is free, hatched rather than filled so an empty
/// drive reads as space rather than as another allocation.
struct APFSCapacityBar: View {
    let reading: StorageSampler.Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                HStack(spacing: 1) {
                    Rectangle().fill(Color.white)
                        .frame(width: width * CGFloat(share(occupied)))
                    Rectangle().fill(Theme.amber.opacity(0.75))
                        .frame(width: width * CGFloat(share(reading.purgeable)))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)
            .background(HatchedFree())
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )

            HStack(spacing: 0) {
                Key("OCCUPIED", .white)
                Key("PURGEABLE", Theme.amber.opacity(0.75))
                Key("FREE", Color(hex: 0x2A3038))
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                Legend(label: "USED", value: Format.bytes(reading.used))
                Dot()
                Legend(label: "FREE", value: Format.bytes(reading.effectiveFree), tint: Theme.cyan)
                Dot()
                Legend(label: "CAPACITY", value: Format.bytes(reading.total))
                Spacer(minLength: 0)
            }
        }
    }

    /// Occupied is what is used *less* the part that is only nominally used.
    private var occupied: UInt64 {
        reading.used > reading.purgeable ? reading.used - reading.purgeable : 0
    }

    private func share(_ part: UInt64) -> Double {
        reading.total > 0 ? Double(part) / Double(reading.total) : 0
    }
}

private struct HatchedFree: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Path { path in
                var x = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 6
                }
            }
            .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
        .background(Color(hex: 0x14181E))
    }
}

/// One direction of drive traffic: the rate, and the operation count behind it.
struct IOTelemetryMeter: View {
    let label: String
    let glyph: String
    let tint: Color
    let rate: Double
    let ops: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(glyph).font(Theme.mono(11, .semibold)).foregroundStyle(tint)
                Text(label)
                    .font(Theme.mono(9, .semibold)).tracking(0.9)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 6)
                Text(Format.rate(rate))
                    .font(Theme.mono(13, .medium).monospacedDigit())
                    .foregroundStyle(tint)
                    .fixedSize()
            }
            HStack(spacing: 0) {
                SegmentGauge(level: level, count: 20, tint: tint)
                Spacer(minLength: 8)
                Legend(label: "IOPS", value: Format.count(Int(ops.rounded())), leading: false)
            }
        }
    }

    /// Log scale: a drive idles at a few KB/s and peaks in the GB/s, and a
    /// linear meter spends all its time either empty or full.
    private var level: Double {
        guard rate > 1 else { return 0 }
        return min(log10(rate) / 9, 1)
    }
}

private struct HealthCell: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.mono(8, .semibold)).tracking(0.6)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Text(value)
                .font(Theme.mono(11, .medium).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
