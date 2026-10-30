import SwiftUI

/// The bottom of the editor: what the run is printing, and every run before
/// it. Picking a past run lights the canvas the way that run went.
struct Console: View {
    @EnvironmentObject private var model: EditorModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SegmentedChoice(options: ["Output", "Runs"], selection: $tab).frame(width: 180)
                if let viewing = model.viewing {
                    Chip(text: "SHOWING \(Stamp.moment(viewing.date).uppercased())", tint: Theme.amber, size: 9)
                    Button("Back to live") { model.viewing = nil }.industrialButton(.ghost, compact: true)
                }
                Spacer()
                if let trace = model.trace {
                    TraceStatus(trace: trace)
                }
                Button { model.showConsole = false } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                    .industrialButton(.ghost, compact: true).help("Hide the console")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            DashedRule()
            if tab == 0 {
                if let trace = model.trace { OutputLines(trace: trace) } else { empty("Run the flow to see what it does") }
            } else {
                RunList()
            }
        }
        .frame(height: 210)
        .background(Theme.machined)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Theme.sans(12)).foregroundStyle(Theme.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// RUNNING, PAUSED, or how the last run ended.
private struct TraceStatus: View {
    @ObservedObject var trace: RunTrace
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            if trace.pausedAt != nil {
                Chip(text: "PAUSED", tint: Theme.amber, size: 9)
                Button("Continue") { model.resume() }.industrialButton(.primary, compact: true).keyboardShortcut("y", modifiers: .command)
                Button("Step") { model.step() }.industrialButton(.secondary, compact: true).help("Run one block, then pause again")
            } else if trace.isRunning {
                Chip(text: "RUNNING", tint: Theme.orange, size: 9)
            } else if let outcome = trace.outcome {
                Chip(text: outcome.rawValue.uppercased(), tint: outcome == .succeeded ? Theme.green : Theme.red, size: 9)
                Text(Format.seconds(Date().timeIntervalSince(trace.started))).font(Theme.mono(9.5)).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

/// Every printed line, under the block that printed it.
private struct OutputLines: View {
    @ObservedObject var trace: RunTrace
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(trace.lines.enumerated()), id: \.element.id) { index, line in
                        let first = index == 0 || trace.lines[index - 1].block != line.block
                        if first, let block = line.block {
                            Button { model.selection = [block] } label: {
                                Text(title(block)).font(Theme.mono(9, .semibold)).tracking(0.6)
                                    .foregroundStyle(Theme.textMuted).padding(.top, index == 0 ? 0 : 6)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(line.text)
                            .font(Theme.mono(11))
                            .foregroundStyle(line.isError ? Theme.red : Theme.textPrimary)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    if !trace.isRunning {
                        Text(trace.finalMessage).font(Theme.mono(11, .semibold))
                            .foregroundStyle(trace.outcome == .succeeded ? Theme.green : Theme.red)
                            .padding(.top, 6).id("end")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: trace.lines.count) { _ in proxy.scrollTo(trace.lines.last?.id, anchor: .bottom) }
            .onChange(of: trace.outcome) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func title(_ block: UUID) -> String {
        guard let found = model.flow.block(block) else { return "BLOCK" }
        return model.definition(found).title.uppercased()
    }
}

/// The flow's history: each run, and on picking one, its trace on the canvas.
private struct RunList: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        let runs = (model.library.runs[model.document.id] ?? []).reversed()
        if runs.isEmpty {
            Text("No runs yet").font(Theme.sans(12)).foregroundStyle(Theme.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(runs)) { run in
                        Button { model.viewing = model.viewing?.id == run.id ? nil : run } label: { row(run) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                Button("Clear") { model.library.clearRuns(for: model.document.id); model.viewing = nil }
                    .industrialButton(.ghost, compact: true).padding(8)
            }
        }
    }

    private func row(_ run: FlowRunRecord) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color(run.outcome)).frame(width: 6, height: 6)
            Text(Stamp.moment(run.date)).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
            Text(run.source.uppercased()).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.textMuted).frame(width: 110, alignment: .leading)
            Text(run.message).font(Theme.sans(11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer()
            Text(Format.seconds(run.duration)).font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.viewing?.id == run.id ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
    }

    private func color(_ outcome: RunOutcome) -> Color {
        switch outcome {
        case .succeeded: return Theme.green
        case .failed: return Theme.red
        case .stopped, .interrupted: return Theme.amber
        }
    }
}

extension Format {
    /// "0.4s", "12s", "2m 5s".
    static func seconds(_ interval: TimeInterval) -> String {
        if interval < 10 { return String(format: "%.1fs", interval) }
        if interval < 60 { return "\(Int(interval))s" }
        return "\(Int(interval) / 60)m \(Int(interval) % 60)s"
    }
}
