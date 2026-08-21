import AppKit
import SwiftUI

/// The Metrics page: pick an event, capture one to see what it carries, throw
/// away the fields you don't want, write a condition, and watch the table fill.
struct MetricsView: View {
    @EnvironmentObject private var library: MetricLibrary

    @State private var selection: UUID?

    private var selected: MetricDefinition? {
        guard let id = selection ?? library.metrics.first?.id else { return nil }
        return library.metrics.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
            Divider().overlay(Theme.machinedBorder)
            if let metric = selected {
                MetricDetail(metric: metric).id(metric.id)
            } else {
                empty
            }
        }
        .background(Theme.panel)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(library.metrics) { metric in
                        MetricRow(metric: metric,
                                  isSelected: (selection ?? library.metrics.first?.id) == metric.id)
                            .onTapGesture { selection = metric.id }
                            .contextMenu {
                                Button("Delete") {
                                    library.remove(metric)
                                    if selection == metric.id { selection = nil }
                                }
                            }
                    }
                }
                .padding(10)
            }
            Divider().overlay(Theme.machinedBorder)
            Button {
                selection = library.add().id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("New metric").font(Theme.sans(12, .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.root)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text("No metrics yet")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MetricRow: View {
    let metric: MetricDefinition
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            LED(color: Theme.ambient, lit: metric.isArmable, size: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.name)
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(metric.source.kind.label)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(fill: isSelected ? Color(hex: 0x17171A) : Theme.machined,
                  border: isSelected ? Theme.ambient : Theme.machinedBorder)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

private struct MetricDetail: View {
    @EnvironmentObject private var library: MetricLibrary
    @EnvironmentObject private var collector: MetricsCollector
    @EnvironmentObject private var store: MetricStoreBox
    @EnvironmentObject private var settings: AppSettings

    let metric: MetricDefinition
    @State private var draft: MetricDefinition
    @State private var records: [MetricRecord] = []
    @State private var note: String?
    @State private var noteFailed = false

    init(metric: MetricDefinition) {
        self.metric = metric
        _draft = State(initialValue: metric)
    }

    private var isSniffing: Bool { collector.sniffing == draft.id }

    var body: some View {
        SettingsScroll {
            identity
            eventSelection
            schema
            logic
            data
        }
        .task { await reload() }
        .onDisappear { collector.cancelSniff() }
    }

    // MARK: 1 — Identity and recording

    private var identity: some View {
        LabeledSection(label: "Metric") {
            MachinedField(text: binding(\.name), placeholder: "Metric name")
                .panelRow()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(draft.isRecording ? "Recording" : "Paused")
                        .font(Theme.sans(13, .medium))
                        .foregroundStyle(draft.isRecording ? Theme.textPrimary : Theme.textSecondary)
                    Text(draft.isRecording
                         ? "Every matching event is written to the database."
                         : "Events are ignored until this is switched on.")
                        .font(Theme.mono(10))
                        .foregroundStyle(draft.isRecording ? Theme.green : Theme.textMuted)
                }
                Spacer()
                Toggle("", isOn: binding(\.isRecording))
                    .labelsHidden()
                    .toggleStyle(.industrial)
            }
            .panelRow()
        }
    }

    // MARK: 2 — Event selection and sniffing

    private var eventSelection: some View {
        LabeledSection(label: "Event Source") {
            FootNote("Choose the system event to capture. Every one of these is a notification macOS already posts — nothing is polled.")
            MachinedMenu(label: draft.source.kind.label, detail: draft.source.kind.detail) {
                ForEach(MetricSource.Kind.allCases) { kind in
                    Button(kind.label) { update { $0.source.kind = kind } }
                }
            }
            if draft.source.kind == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notification name").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    MachinedField(text: binding(\.source.customName),
                                  placeholder: "com.example.somethingHappened")
                }
                .panelRow()
            }

            HStack(spacing: 8) {
                Button(isSniffing ? "Listening…" : "Sniff Data Fields") { sniff() }
                    .industrialButton(isSniffing ? .danger : .primary)
                if isSniffing {
                    Button("Cancel") { collector.cancelSniff() }
                        .industrialButton(.ghost)
                }
                Spacer()
            }
            .panelRow()
            FootNote(isSniffing
                     ? "Waiting for one \(draft.source.kind.label.lowercased()) — trigger it now and the fields it carries will appear below."
                     : "Captures a single event and shows every field it carries, so the schema comes from the data rather than a guess.")
        }
    }

    // MARK: 3 — Schema pruning

    @ViewBuilder
    private var schema: some View {
        if !draft.sniffedKeys.isEmpty {
            LabeledSection(label: "Captured Fields") {
                FootNote("Remove any field you do not want. Removed fields are dropped before the condition runs and are never written to the database.")
                SchemaTable(keys: draft.sniffedKeys,
                            pruned: draft.prunedKeys,
                            sample: draft.sample) { key in
                    update { definition in
                        if definition.prunedKeys.contains(key) {
                            definition.prunedKeys.remove(key)
                        } else {
                            definition.prunedKeys.insert(key)
                        }
                    }
                }
                if !draft.prunedKeys.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(draft.prunedKeys.count) removed")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                        Button("Restore all") { update { $0.prunedKeys.removeAll() } }
                            .industrialButton(.ghost)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: 4 — The condition

    private var logic: some View {
        LabeledSection(label: "Logging Condition") {
            FootNote("JavaScript, evaluated for every event. Return true to keep it. The kept fields arrive as `payload`; numeric-looking values arrive as numbers. Leave empty to keep everything.")
            CodeEditor(text: binding(\.condition),
                       placeholder: "return payload[\"Total Time\"] > 30000;")
            if !draft.condition.isEmpty, !draft.sample.isEmpty {
                let passes = MetricsCollector.passes(condition: draft.condition,
                                                     payload: keptSample)
                HStack(spacing: 6) {
                    LED(color: passes ? Theme.green : Theme.red, lit: true, size: 6)
                    Text(passes
                         ? "The captured sample would be logged."
                         : "The captured sample would be skipped.")
                        .font(Theme.mono(10))
                        .foregroundStyle(passes ? Theme.green : Theme.red)
                    Spacer()
                }
            }
        }
    }

    private var keptSample: [String: String] {
        let kept = draft.keptKeys
        return draft.sample.filter { kept.contains($0.key) }
    }

    // MARK: 5 — The data

    private var data: some View {
        LabeledSection(label: "Captured Data") {
            HStack(spacing: 8) {
                Text("\(records.count) row\(records.count == 1 ? "" : "s")")
                    .font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button("Refresh") { Task { await reload() } }.industrialButton(.ghost)
                Button("Export to CSV") { export(.csv) }.industrialButton(.secondary)
                Button("Export to Excel") { export(.xlsx) }.industrialButton(.secondary)
                Button("Clear") {
                    Task {
                        await store.value.deleteAll(for: draft.id)
                        await reload()
                    }
                }
                .industrialButton(.danger)
            }
            .panelRow()

            if let note {
                Text(note)
                    .font(Theme.mono(10))
                    .foregroundStyle(noteFailed ? Theme.red : Theme.green)
                    .lineLimit(2)
            }

            if records.isEmpty {
                FootNote("Nothing captured yet. Switch recording on and trigger the event.")
            } else {
                RecordTable(columns: MetricExporter.columns(for: draft, records: records),
                            records: records)
            }
        }
    }

    // MARK: Actions

    private enum Format { case csv, xlsx }

    private func export(_ format: Format) {
        let metric = draft
        let rows = records
        let destination = settings.exportDirectory
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { () -> URL in
                    switch format {
                    case .csv: return try MetricExporter.exportCSV(metric, records: rows, to: destination)
                    case .xlsx: return try MetricExporter.exportXLSX(metric, records: rows, to: destination)
                    }
                }.value
                await MainActor.run {
                    noteFailed = false
                    note = "Saved \(url.lastPathComponent) to \(destination.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    noteFailed = true
                    note = "! \(error.localizedDescription)"
                }
            }
        }
    }

    private func sniff() {
        collector.sniff(draft) { fields in
            update { definition in
                // Fields already known keep their order and their pruning; new
                // ones are appended, so sniffing twice does not undo the work.
                var keys = definition.sniffedKeys
                for key in fields.keys.sorted() where !keys.contains(key) { keys.append(key) }
                definition.sniffedKeys = keys
                definition.sample = fields
            }
        }
    }

    private func reload() async {
        records = await store.value.records(for: draft.id)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MetricDefinition, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    private func update(_ change: (inout MetricDefinition) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        draft = next
        library.update(next)
    }
}

// MARK: - Tables

/// Keys across the top, one sample row underneath, and a minus on every column.
private struct SchemaTable: View {
    let keys: [String]
    let pruned: Set<String>
    let sample: [String: String]
    let onToggle: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    let isPruned = pruned.contains(key)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(key)
                                .font(Theme.mono(10, .semibold))
                                .foregroundStyle(isPruned ? Theme.textMuted : Theme.textPrimary)
                                .strikethrough(isPruned, color: Theme.textMuted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button { onToggle(key) } label: {
                                Image(systemName: isPruned ? "plus" : "minus")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .hardwareKey(size: 16)
                            .help(isPruned ? "Put \(key) back" : "Drop \(key) from the schema")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)

                        Divider().overlay(Theme.machinedBorder)

                        Text(sample[key] ?? "—")
                            .font(Theme.mono(10))
                            .foregroundStyle(isPruned ? Theme.textMuted.opacity(0.5) : Theme.textSecondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 170, alignment: .leading)
                    .opacity(isPruned ? 0.45 : 1)
                    .overlay(Rectangle().frame(width: 1).foregroundStyle(Theme.machinedBorder),
                             alignment: .trailing)
                }
            }
        }
        .frame(height: 78)
        .machined(cornerRadius: Theme.radiusMd)
    }
}

/// The historical rows.
private struct RecordTable: View {
    let columns: [String]
    let records: [MetricRecord]

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(spacing: 0) {
                header
                ForEach(records) { record in
                    HStack(spacing: 0) {
                        cell(Self.stamp.string(from: record.capturedAt), width: 130, muted: true)
                        ForEach(columns, id: \.self) { column in
                            cell(record.values[column] ?? "", width: 170, muted: false)
                        }
                    }
                    Divider().overlay(Theme.machinedBorder.opacity(0.6))
                }
            }
        }
        .frame(maxHeight: 260)
        .machined(cornerRadius: Theme.radiusMd)
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerCell("Captured At", width: 130)
            ForEach(columns, id: \.self) { headerCell($0, width: 170) }
        }
        .background(Color.black.opacity(0.35))
    }

    private func headerCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(Theme.mono(9, .semibold))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    private func cell(_ text: String, width: CGFloat, muted: Bool) -> some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(muted ? Theme.textMuted : Theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

// MARK: - Shared controls

private struct MachinedMenu<Content: View>: View {
    let label: String
    var detail: String?
    @State private var hovering = false
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? Theme.ambient : Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .machined(fill: hovering ? Color(hex: 0x17171A) : Theme.machined)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct MachinedField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .machined()
    }
}

private struct CodeEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted.opacity(0.6))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 110, maxHeight: 180)
        .machined(cornerRadius: Theme.radiusMd)
    }
}

/// `MetricStore` is not an `ObservableObject` — it has no published state — but
/// the views still need to reach the one instance the app owns.
@MainActor
final class MetricStoreBox: ObservableObject {
    let value: MetricStore
    init(_ value: MetricStore) { self.value = value }
}
