import AppKit
import SwiftUI

/// The Automations page: rules that file what lands in a folder, actions you
/// run from a hotkey or the palette, and triggers that run on their own.
///
/// Each automation is one raised card that reads as a sentence — where, which
/// files, then what happens — and folds open in place to edit. New ones start
/// from a template rather than a blank editor.
struct AutomationsView: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var settings: AppSettings
    @State private var open: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                palette
                ForEach(AutomationSection.allCases) { section($0) }
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel.grain(0.26))
    }

    /// The hotkey for the palette — your actions and the built-in tools, from
    /// anywhere.
    private var palette: some View {
        SettingsCard(rail: settings.paletteShortcut == nil ? nil : Theme.ambient) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.rays").foregroundStyle(Theme.orange)
                Text("Quick palette").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.textPrimary)
                    .help("Opens from anywhere: your actions, most recent first, then clipboard and system tools")
                Spacer(minLength: 12)
                if settings.paletteShortcut != nil {
                    Button("Open") { QuickPalette.shared.show() }.industrialButton(.quiet)
                }
                ShortcutKeys(shortcut: settings.paletteShortcut) { settings.paletteShortcut = $0 }
            }
            .cardRow()
        }
    }

    private func section(_ section: AutomationSection) -> some View {
        let scripts = library.scripts.filter { $0.section == section }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(section.title).help(section.help)
                if !scripts.isEmpty {
                    // Actions are not switched on or off — the count is of the
                    // ones that are set up and ready to run.
                    let ready = section == .actions ? scripts.filter(\.isComplete).count
                                                    : scripts.filter(\.isArmable).count
                    Chip(text: "\(ready)/\(scripts.count) \(section == .actions ? "READY" : "AKTIV")",
                         tint: Theme.green, size: 9)
                }
                Spacer()
                newMenu(section)
            }
            if scripts.isEmpty {
                Text(section.emptyText.uppercased())
                    .font(Theme.mono(10, .semibold)).tracking(1.1)
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .strokeBorder(Theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
                    .help(section.help)
            }
            ForEach(scripts) { script in
                AutomationCard(script: script, isOpen: open == script.id) {
                    withAnimation(.easeOut(duration: 0.16)) { open = open == script.id ? nil : script.id }
                } onRemove: {
                    library.remove(script)
                }
            }
        }
    }

    /// New, from a template or blank, and import.
    private func newMenu(_ section: AutomationSection) -> some View {
        Menu {
            Section("Templates") {
                ForEach(section.templates) { template in
                    Button { add(template.make()) } label: { Label(template.name, systemImage: template.glyph) }
                }
            }
            Divider()
            Button("Blank") { add(blank(section)) }
            if section == .actions {
                Button("Import a script…", action: importScript)
            }
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuKey()
    }

    private func blank(_ section: AutomationSection) -> Script {
        var script = Script(name: "New \(section.rawValue.dropLast())", isActive: section != .rules)
        script.trigger.kind = section.triggerKinds[0]
        return script
    }

    private func add(_ script: Script) {
        library.scripts.append(script)
        open = script.id
    }

    private func importScript() {
        let panel = NSOpenPanel()
        panel.title = "Import a script"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                open = try library.importScript(from: url).id
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't import \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

// MARK: - Card

/// One automation: its icon, its name, the sentence it reads as, and what you
/// do with it — a switch for rules and triggers, a run key for actions.
private struct AutomationCard: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var triggers: ScriptTriggerCoordinator

    let script: Script
    let isOpen: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    private var running: Bool { triggers.progress[script.id] != nil }
    private var isAction: Bool { script.section == .actions }
    private var lit: Bool { running || (!isAction && script.isArmable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                DashedRule().padding(.horizontal, 16)
                AutomationEditor(script: binding, onRemove: onRemove)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .raisedPanel(rail: lit ? Theme.ambient : nil)
    }

    private var binding: Binding<Script> {
        Binding(get: { library.scripts.first { $0.id == script.id } ?? script },
                set: { library.update($0) })
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(lit ? Theme.orange : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .recessed(cornerRadius: 8, fill: .black.opacity(0.38))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(script.name)
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if running {
                        Chip(text: "RUNNING", tint: Theme.orange, size: 8.5)
                    } else if script.isActive && !script.isArmable && !isAction {
                        Chip(text: "INCOMPLETE", tint: Theme.amber, size: 8.5)
                    }
                }
                SentenceChips(script: script)
            }

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                if let last = library.runs[script.id]?.last {
                    Circle().fill(last.succeeded ? Theme.green : Theme.red)
                        .frame(width: 6, height: 6)
                        .help(last.summary)
                }
                if isAction {
                    if let shortcut = script.trigger.shortcut { KeyBadge(text: shortcut.display) }
                    Button("Run") { triggers.run(script, paths: [], source: "Manual") }
                        .industrialButton(.secondary)
                        .disabled(running || !script.isComplete)
                } else {
                    Toggle("", isOn: Binding(get: { script.isActive },
                                             set: { var next = script; next.isActive = $0; library.update(next) }))
                        .labelsHidden()
                        .toggleStyle(.industrial)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .frame(height: 34)
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var icon: String {
        isAction ? (script.steps.first?.kind.glyph ?? "bolt") : script.trigger.kind.glyph
    }
}

/// The automation as a sentence of chips: where it watches or what sets it
/// off, the conditions, then each step. Anything not set up reads amber.
private struct SentenceChips: View {
    let script: Script

    var body: some View {
        FlowLayout(spacing: 5) {
            switch script.section {
            case .rules:
                SentenceChip(glyph: "folder",
                             text: script.trigger.watchedFolder.isEmpty ? "Choose a folder"
                                 : (script.trigger.watchedFolder as NSString).lastPathComponent,
                             warn: script.trigger.watchedFolder.isEmpty)
                ForEach(script.trigger.conditions) { condition in
                    SentenceChip(text: condition.summary)
                }
                arrow
            case .triggers:
                SentenceChip(glyph: script.trigger.kind.glyph, text: script.trigger.summary,
                             warn: !script.trigger.isConfigured)
                arrow
            case .actions:
                EmptyView()
            }
            // An action named after its only step would say it twice.
            ForEach(script.steps.filter { !(script.section == .actions && $0.isConfigured
                                            && $0.kind.label == script.name) }) { step in
                SentenceChip(glyph: step.kind.glyph,
                             text: step.kind.hasSettings && step.isConfigured ? "\(step.kind.label): \(step.summary)" : step.kind.label,
                             warn: !step.isConfigured)
            }
            if script.steps.isEmpty { SentenceChip(text: "No steps", warn: true) }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textMuted)
            .frame(height: 22)
    }
}

private struct SentenceChip: View {
    var glyph: String? = nil
    let text: String
    var warn = false

    var body: some View {
        HStack(spacing: 5) {
            if let glyph { Image(systemName: glyph).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.mono(10))
        .foregroundStyle(warn ? Theme.amber : Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .recessed(cornerRadius: 5, fill: .black.opacity(0.32))
        .frame(maxWidth: 280, alignment: .leading)
    }
}

// MARK: - Editor

/// The card opened up: name, what sets it off, its steps, how it reports, and
/// its keys — run, history, export, duplicate, delete.
private struct AutomationEditor: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var triggers: ScriptTriggerCoordinator
    @Binding var script: Script
    let onRemove: () -> Void
    @State private var showingHistory = false

    private var runs: [ScriptRunRecord] { library.runs[script.id] ?? [] }

    /// Files in the rule's folder today that pass its conditions — a preview
    /// before it is switched on. Read only while the card is open.
    private var matchesNow: Int {
        let folder = URL(fileURLWithPath: script.trigger.watchedFolder, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && script.trigger.admits($0)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            EditorRow(label: "NAME") { SlotField(text: $script.name, placeholder: "Name") }
            TriggerEditor(trigger: $script.trigger, kinds: script.section.triggerKinds)
            if script.section == .rules && !script.trigger.watchedFolder.isEmpty {
                EditorRow(label: "MATCHES NOW") {
                    let count = matchesNow
                    Text(count == 1 ? "1 file" : "\(count) files")
                        .font(Theme.mono(10.5).monospacedDigit())
                        .foregroundStyle(count > 0 ? Theme.orange : Theme.textSecondary)
                        .help(script.trigger.sweepsExisting
                              ? "What this rule acts on when it is switched on"
                              : "Files already in the folder that match. The rule acts on new arrivals only")
                }
            }
            if script.section == .actions {
                EditorRow(label: "MENU BAR") {
                    Toggle("", isOn: $script.pinnedToMenuBar).labelsHidden().toggleStyle(.industrial)
                        .help("A run key in the menu bar dropdown")
                }
            }

            DashedRule().padding(.vertical, 4)
            steps

            DashedRule().padding(.vertical, 4)
            OutputEditor(output: $script.output)

            DashedRule().padding(.vertical, 4)
            footer
            if showingHistory && !runs.isEmpty {
                ScriptHistory(runs: runs) { library.clearRuns(for: script.id) }
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var steps: some View {
        ForEach(Array(script.steps.enumerated()), id: \.element.id) { index, step in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1))
                        .font(Theme.mono(8.5, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 17)
                        .recessed(cornerRadius: 3)
                    Image(systemName: step.kind.glyph)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(step.isConfigured ? Theme.orange : Theme.amber)
                        .frame(width: 14)
                    Text(step.kind.label.uppercased())
                        .font(Theme.mono(9.5, .semibold)).tracking(0.9)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if index > 0 { stepKey("chevron.up", "Move up") { move(index, by: -1) } }
                    if index < script.steps.count - 1 { stepKey("chevron.down", "Move down") { move(index, by: 1) } }
                    stepKey("xmark", "Remove this step") { script.steps.remove(at: index) }
                }
                if step.kind.hasSettings {
                    StepEditor(step: $script.steps[index]).padding(.leading, 34)
                }
            }
        }
        EditorRow(label: script.steps.isEmpty ? "THEN" : "") {
            Menu {
                StepKindItems { kind in script.steps.append(.make(kind)) }
            } label: { MenuKeyLabel(title: "Add a step") }
            .menuKey(compact: true)
        }
    }

    private func stepKey(_ glyph: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: glyph).font(.system(size: 8, weight: .bold)) }
            .industrialButton(.ghost, compact: true)
            .help(help)
    }

    private func move(_ index: Int, by offset: Int) {
        script.steps.swapAt(index, index + offset)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { triggers.run(script, paths: [], source: "Manual") } label: {
                Label("Run now", systemImage: "play.fill")
            }
            .industrialButton(.primary, compact: true)
            .disabled(triggers.progress[script.id] != nil || !script.isComplete)
            if script.section == .rules {
                Button("Run on files…") {
                    let files = Pickers.files(title: "Run \(script.name) on…")
                    if !files.isEmpty { triggers.run(script, paths: files, source: "Files") }
                }
                .industrialButton(.secondary, compact: true)
            }
            if let last = runs.last {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showingHistory.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(last.succeeded ? Theme.green : Theme.red).frame(width: 6, height: 6)
                        Text("\(ScriptHistory.time(last.date)) · \(ScriptHistory.duration(last.duration))")
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(showingHistory ? 180 : 0))
                    }
                }
                .industrialButton(.ghost, compact: true)
                .help(last.summary)
            }
            Spacer()
            HStack(spacing: 0) {
                CardButton(glyph: "square.and.arrow.up", help: "Export as a .gruppenscript file", action: export)
                CardButton(glyph: "plus.square.on.square", help: "Duplicate") { library.duplicate(script) }
                CardButton(glyph: "trash", help: "Delete", action: onRemove)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export \(script.name)"
        panel.nameFieldStringValue = "\(script.name).gruppenscript"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? ScriptLibrary.exportData(script) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Shared

/// A script's state as one lamp: lit when it is armed and listening, amber
/// when it is switched on but something is not set up, dark otherwise.
struct ScriptLamp: View {
    let script: Script
    var size: CGFloat = 8

    var body: some View {
        LED(color: script.isArmable ? Theme.ambient : Theme.amber,
            lit: script.isActive && script.trigger.kind != .manual, size: size)
    }
}

/// Lays its children out left to right, wrapping onto new rows — the chips of
/// an automation's sentence.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
