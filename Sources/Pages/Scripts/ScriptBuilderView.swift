import AppKit
import SwiftUI

/// The Scripts page: the rack on the left — every script as a faceplate — and
/// the selected one as a module on the right.
struct ScriptBuilderView: View {
    @EnvironmentObject private var library: ScriptLibrary
    @State private var selection: UUID?

    private var selectedID: UUID? { selection ?? library.scripts.first?.id }
    private var selected: Script? { library.scripts.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            rack
            Rectangle().fill(Theme.machinedBorder).frame(width: 1)
            Group {
                if let script = selected {
                    ScriptModule(script: script, onDelete: { delete(script) },
                                 onDuplicate: { selection = library.duplicate(script).id })
                        .id(script.id)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel.grain(0.26))
        }
    }

    // MARK: Rack

    private var rack: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("RACK")
                    .font(Theme.mono(9, .semibold)).tracking(1.4)
                    .foregroundStyle(Theme.textSecondary)
                Text("\(library.scripts.count)")
                    .font(Theme.mono(9).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                HStack(spacing: 0) {
                    CardButton(glyph: "square.and.arrow.down", help: "Import a script…", action: importScript)
                    CardButton(glyph: "plus", help: "New script", action: newScript)
                }
            }
            DashedRule()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(library.scripts) { script in
                        Faceplate(script: script, isSelected: selectedID == script.id,
                                  lastRun: library.runs[script.id]?.last)
                            .onTapGesture { selection = script.id }
                            .contextMenu {
                                Button("Duplicate") { selection = library.duplicate(script).id }
                                Button("Delete") { delete(script) }
                            }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 228)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.root)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("NO MODULES IN THE RACK")
                .font(Theme.mono(10, .semibold)).tracking(1.4)
                .foregroundStyle(Theme.textMuted)
            Button("New script", action: newScript)
                .industrialButton(.primary)
        }
    }

    private func newScript() {
        selection = library.add().id
    }

    /// A `.gruppenscript`, or a plain shell, JavaScript or AppleScript file.
    private func importScript() {
        let panel = NSOpenPanel()
        panel.title = "Import a script"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                selection = try library.importScript(from: url).id
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't import \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func delete(_ script: Script) {
        library.remove(script)
        if selection == script.id { selection = nil }
    }
}

/// A script in the rack: its lamp, its engraved name, what sets it off, and
/// how the last run went.
private struct Faceplate: View {
    let script: Script
    let isSelected: Bool
    let lastRun: ScriptRunRecord?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ScriptLamp(script: script, size: 7)
            Text(script.name.uppercased())
                .font(Theme.mono(10, .semibold)).tracking(0.8)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let lastRun {
                Circle()
                    .fill(lastRun.succeeded ? Theme.green : Theme.red)
                    .frame(width: 5, height: 5)
                    .help(lastRun.succeeded ? "Last run worked" : "Last run failed")
            }
            Image(systemName: script.trigger.kind.glyph)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.orange : Theme.textMuted)
                .frame(width: 14)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(cornerRadius: 6,
                  fill: hovering || isSelected ? Theme.housing.mixed(with: .white, amount: 0.03) : Theme.housing,
                  border: isSelected ? Theme.ambient.opacity(0.7) : Theme.machinedBorder)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A script's state as one lamp: lit when it is armed and listening, amber
/// when it is switched on but something is not set up, dark otherwise. A
/// manual script has nothing to listen for, so it is never lit.
struct ScriptLamp: View {
    let script: Script
    var size: CGFloat = 8

    var body: some View {
        LED(color: color, lit: script.isActive && script.trigger.kind != .manual, size: size)
            .help(help)
    }

    private var color: Color { script.isArmable ? Theme.ambient : Theme.amber }

    private var help: String {
        if script.trigger.kind == .manual { return "Runs only from its Run key" }
        if !script.isActive { return "Off" }
        if !script.trigger.isConfigured { return "On, but the trigger is not set up" }
        if !script.isComplete { return "On, but a step is not set up" }
        return "Armed — listening for its trigger"
    }
}
