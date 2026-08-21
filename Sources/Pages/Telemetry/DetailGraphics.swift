import SwiftUI

// MARK: - Graphics
//
// Split out of `ModuleDetail.swift`, which had grown to 1,600 lines and forty
// types. The router and the shared chrome stay there; each module's readout
// lives beside the others that only it uses.

// MARK: - Graphics

struct SiliconDetail: View {
    @ObservedObject var widget: SiliconTelemetryWidget

    var body: some View {
        if let reading = widget.reading {
            Well {
                HStack(alignment: .firstTextBaseline) {
                    Headline(value: String(format: "%.1f", reading.gpu * 100), unit: "%",
                             tint: Theme.purple)
                    Spacer()
                    Text("\(reading.coreCount) CORES")
                        .font(Theme.mono(9, .semibold)).tracking(0.8)
                        .foregroundStyle(Theme.textMuted)
                }
                Sparkline(values: widget.history, floor: WidgetKind.silicon.plotFloor,
                          tint: Theme.purple, height: 34).equatable()
            }

            // The VRAM pool, once. It used to appear twice — beside the headline
            // and again as "IN USE" — with no indication of what it was a share
            // of, which is the number that makes it mean anything.
            Well {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.bytes(reading.gpuMemory))
                        .font(Theme.mono(15, .medium).monospacedDigit())
                        .foregroundStyle(Theme.purple)
                    Text("/ \(Format.bytes(SiliconSampler.memoryPool)) UNIFIED")
                        .font(Theme.mono(9, .semibold)).tracking(0.6)
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                }
                SegmentedBar(segments: [
                    .init(fraction: poolFraction(reading.gpuMemory), tint: Theme.purple),
                ], height: 8)
                StatRow(label: "RENDERER", value: Format.percent(reading.renderer, decimals: 1))
                StatRow(label: "TILER", value: Format.percent(reading.tiler, decimals: 1))
            }

            Well {
                Text("FIXED-FUNCTION ENGINES")
                    .font(Theme.mono(9, .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textMuted)
                engine("NEURAL", reading.neuralEngine)
                engine("VIDEO", reading.videoEngine)
                engine("IMAGE", reading.imageEngine)
                Text("power state, not utilisation — see the panel note")
                    .font(Theme.mono(8.5))
                    .foregroundStyle(Theme.textMuted.opacity(0.8))
            }
        } else {
            Waiting()
        }
    }

    /// Apple Silicon has no dedicated VRAM: the GPU allocates out of the same
    /// unified memory the CPU uses, so the pool it is drawn from is the whole
    /// installed RAM. Saying "4.2 GB" without that is a number with no scale.
    private func poolFraction(_ used: UInt64) -> Double {
        let pool = SiliconSampler.memoryPool
        return pool > 0 ? Double(used) / Double(pool) : 0
    }

    @ViewBuilder
    private func engine(_ label: String, _ state: AppleSiliconTelemetry.EngineState?) -> some View {
        if let state {
            HStack(spacing: 8) {
                LED(color: state.isAwake ? Theme.trace : Theme.textMuted, lit: state.isAwake, size: 7)
                Text(label)
                    .font(Theme.mono(9.5)).tracking(0.5)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(state.isAwake ? "AWAKE \(state.current)/\(state.maximum)" : "ASLEEP")
                    .font(Theme.mono(10).monospacedDigit())
                    .foregroundStyle(state.isAwake ? Theme.trace : Theme.textMuted)
            }
        }
    }
}
