import AppKit
import SwiftUI

/// One script as a rack module: the plate along the top, the slots on their
/// signal bus, and the run keys along the bottom.
///
/// The bus is the point of the shape. Each slot has a lamp on it, and a run
/// lights them in turn — orange on the step running, green behind it, red
/// where it stopped — so what a script did is something you watch rather than
/// read. When nothing is running the lamps hold the last run's result.
struct ScriptModule: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var triggers: ScriptTriggerCoordinator

    let script: Script
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    @State private var draft: Script
    @State private var open: SlotID?
    @State private var showingHistory = false

    private enum SlotID: Hashable { case input, step(UUID), output }

    init(script: Script, onDelete: @escaping () -> Void, onDuplicate: @escaping () -> Void) {
        self.script = script
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        _draft = State(initialValue: script)
    }

    private var runs: [ScriptRunRecord] { library.runs[draft.id] ?? [] }
    private var progress: ScriptTriggerCoordinator.Progress? { triggers.progress[draft.id] }
    private var isLive: Bool { draft.isArmable && draft.trigger.kind != .manual }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                module
                if showingHistory && !runs.isEmpty {
                    ScriptHistory(runs: runs) { library.clearRuns(for: draft.id) }
                        .transition(.opacity)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        // Picks up runs fired by a trigger, the menu bar or a workspace while
        // this page is open, and edits made to the same script elsewhere.
        .onChange(of: script) { newValue in if newValue != draft { draft = newValue } }
    }

    private var module: some View {
        VStack(alignment: .leading, spacing: 10) {
            plate
            DashedRule()
            bus
            DashedRule()
            footer
        }
        .padding(14)
        .raisedPanel(rail: isLive || progress != nil ? Theme.ambient : nil)
    }

    // MARK: Plate

    private var plate: some View {
        HStack(spacing: 9) {
            ScriptLamp(script: draft, size: 8)
            TextField("Script name", text: binding(\.name))
                .textFieldStyle(.plain)
                .font(Theme.mono(12, .semibold))
                .tracking(1)
                .foregroundStyle(Theme.textPrimary)
            if let status { Chip(text: status.text, tint: status.tint, size: 9) }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                CardButton(glyph: draft.pinnedToMenuBar ? "pin.fill" : "pin",
                           tint: draft.pinnedToMenuBar ? Theme.orange : Theme.textSecondary,
                           help: draft.pinnedToMenuBar ? "Unpin from the menu bar" : "Pin to the menu bar") {
                    update { $0.pinnedToMenuBar.toggle() }
                }
                CardButton(glyph: "square.and.arrow.up", help: "Export as a .gruppenscript file", action: export)
                CardButton(glyph: "plus.square.on.square", help: "Duplicate", action: onDuplicate)
                CardButton(glyph: "trash", help: "Delete", action: onDelete)
            }
            if draft.trigger.kind != .manual {
                Text("ARMED")
                    .font(Theme.mono(8, .semibold)).tracking(1)
                    .foregroundStyle(draft.isActive ? Theme.textSecondary : Theme.textMuted)
                Toggle("", isOn: binding(\.isActive))
                    .labelsHidden()
                    .toggleStyle(.industrial)
            }
        }
    }

    /// The one-word state beside the name: running, armed, or switched on
    /// with something not set up. Nothing when it is simply off.
    private var status: (text: String, tint: Color)? {
        if let progress {
            return ("LÄUFT \(progress.current + 1)/\(draft.steps.count)", Theme.orange)
        }
        if draft.isActive && draft.trigger.kind != .manual {
            return draft.isArmable ? ("BEREIT", Theme.green) : ("UNVOLLSTÄNDIG", Theme.amber)
        }
        return nil
    }

    // MARK: Bus

    private var bus: some View {
        let rows = slotRows
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                BusRow(lamp: row.lamp, lineLit: isLive || progress != nil,
                       isFirst: index == 0, isLast: index == rows.count - 1) {
                    row.view
                }
            }
        }
    }

    private struct Row: Identifiable {
        let id: SlotID
        let lamp: Lamp
        let view: AnyView
    }

    private var slotRows: [Row] {
        var rows: [Row] = [Row(id: .input, lamp: isLive || progress != nil ? .armed : .off, view: AnyView(inputSlot))]
        for (index, step) in draft.steps.enumerated() {
            rows.append(Row(id: .step(step.id), lamp: lamp(for: step, at: index),
                            view: AnyView(stepSlot(step, at: index))))
        }
        rows.append(Row(id: .step(Self.addID), lamp: .none, view: AnyView(addStep)))
        let outLamp: Lamp = progress != nil ? .off : (runs.last.map { $0.succeeded ? .ok : .failed } ?? .off)
        rows.append(Row(id: .output, lamp: outLamp, view: AnyView(outputSlot)))
        return rows
    }

    private static let addID = UUID()

    private func lamp(for step: ScriptStep, at index: Int) -> Lamp {
        if let progress {
            if index < progress.finished.count { return progress.finished[index] ? .ok : .failed }
            return index == progress.current ? .running : .off
        }
        guard let outcome = runs.last?.steps.first(where: { $0.stepID == step.id }) else { return .off }
        return outcome.ok ? .ok : .failed
    }

    private var inputSlot: some View {
        ScriptSlot(tag: "IN", glyph: draft.trigger.kind.glyph,
                   title: draft.trigger.kind.shortLabel, summary: draft.trigger.summary,
                   needsSetup: !draft.trigger.isConfigured,
                   isOpen: open == .input, onToggle: { toggle(.input) }) {
            TriggerEditor(trigger: binding(\.trigger))
        }
    }

    private func stepSlot(_ step: ScriptStep, at index: Int) -> some View {
        ScriptSlot(tag: String(format: "%02d", index + 1), glyph: step.kind.glyph,
                   title: step.kind.label, summary: step.summary,
                   needsSetup: !step.isConfigured,
                   isOpen: open == .step(step.id), canOpen: step.kind.hasSettings,
                   onToggle: { toggle(.step(step.id)) },
                   onMoveUp: index > 0 ? { move(step, by: -1) } : nil,
                   onMoveDown: index < draft.steps.count - 1 ? { move(step, by: 1) } : nil,
                   onRemove: { remove(step) }) {
            StepEditor(step: stepBinding(step))
        }
    }

    /// The empty slot at the foot of the steps: a menu of everything a step
    /// can be, grouped.
    private var addStep: some View {
        Menu {
            StepKindItems { kind in
                let step = ScriptStep.make(kind)
                update { $0.steps.append(step) }
                if kind.hasSettings { open = .step(step.id) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("ADD STEP").font(Theme.mono(9, .semibold)).tracking(1.2)
                Spacer()
            }
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var outputSlot: some View {
        ScriptSlot(tag: "OUT", glyph: "bell", title: "Report", summary: draft.output.summary,
                   isOpen: open == .output, onToggle: { toggle(.output) }) {
            OutputEditor(output: binding(\.output))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { triggers.run(draft, paths: []) } label: {
                Label("RUN", systemImage: "play.fill")
            }
            .industrialButton(.primary, compact: true)
            .disabled(progress != nil || draft.steps.isEmpty)
            Button("RUN ON FILES…") {
                let files = Pickers.files(title: "Run \(draft.name) on…")
                if !files.isEmpty { triggers.run(draft, paths: files, source: "Files") }
            }
            .industrialButton(.secondary, compact: true)
            .disabled(progress != nil || draft.steps.isEmpty)
            .help("The files come down the bus to step 01")
            Spacer(minLength: 8)
            readout
        }
    }

    @ViewBuilder private var readout: some View {
        if progress != nil {
            EmptyView()     // the plate's LÄUFT chip says it
        } else if let last = runs.last {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showingHistory.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("LAST").font(Theme.mono(8, .semibold)).tracking(1).foregroundStyle(Theme.textMuted)
                    Circle().fill(last.succeeded ? Theme.green : Theme.red).frame(width: 6, height: 6)
                    Text("\(last.succeeded ? "OK" : "FAILED") \(ScriptHistory.duration(last.duration)) · \(ScriptHistory.time(last.date))")
                        .font(Theme.mono(9.5).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(showingHistory ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(last.summary)
        } else {
            Text("NEVER RUN")
                .font(Theme.mono(8.5, .semibold)).tracking(1)
                .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: Editing

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export \(draft.name)"
        panel.nameFieldStringValue = "\(draft.name).gruppenscript"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? ScriptLibrary.exportData(draft) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func toggle(_ slot: SlotID) {
        open = open == slot ? nil : slot
    }

    private func move(_ step: ScriptStep, by offset: Int) {
        update { script in
            guard let index = script.steps.firstIndex(where: { $0.id == step.id }) else { return }
            script.steps.swapAt(index, index + offset)
        }
    }

    private func remove(_ step: ScriptStep) {
        update { $0.steps.removeAll { $0.id == step.id } }
        if open == .step(step.id) { open = nil }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Script, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    private func stepBinding(_ step: ScriptStep) -> Binding<ScriptStep> {
        Binding(get: { draft.steps.first { $0.id == step.id } ?? step },
                set: { newValue in
                    update { script in
                        guard let index = script.steps.firstIndex(where: { $0.id == step.id }) else { return }
                        script.steps[index] = newValue
                    }
                })
    }

    /// One place a change is applied and persisted, so the editor cannot drift
    /// from what is armed.
    private func update(_ change: (inout Script) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        draft = next
        library.update(next)
    }
}

// MARK: - Bus

private enum Lamp { case none, off, armed, running, ok, failed }

/// A slot on the bus: the line running down the left, the slot's lamp on it,
/// and the slot itself.
private struct BusRow<Content: View>: View {
    let lamp: Lamp
    let lineLit: Bool
    let isFirst: Bool
    let isLast: Bool
    @ViewBuilder let content: Content

    /// Level with the middle of a slot's 34pt header.
    private let lampY: CGFloat = 17

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    line.frame(height: lampY).opacity(isFirst ? 0 : 1)
                    line.frame(maxHeight: .infinity).opacity(isLast ? 0 : 1)
                }
                if lamp != .none {
                    lampView.offset(y: lampY - 4)
                }
            }
            .frame(width: 12)
            content
                .padding(.bottom, isLast ? 0 : 7)
        }
    }

    private var line: some View {
        Rectangle()
            .fill(lineLit ? Theme.ambient.opacity(0.35) : Color.white.opacity(0.08))
            .frame(width: 2)
    }

    @ViewBuilder private var lampView: some View {
        switch lamp {
        case .none, .off: LED(color: Theme.ambient, lit: false, size: 8)
        case .armed: LED(color: Theme.ambient, lit: true, size: 8)
        case .running: LED(color: Theme.orange, lit: true, size: 8)
        case .ok: LED(color: Theme.green, lit: true, size: 8)
        case .failed: LED(color: Theme.red, lit: true, size: 8)
        }
    }
}

// MARK: - History

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
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.orange)
                Text("HISTORY")
                    .font(Theme.mono(9, .semibold)).tracking(1.4)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Clear", action: onClear).industrialButton(.ghost, compact: true)
            }
            DashedRule()
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
        .padding(14)
        .raisedPanel()
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
