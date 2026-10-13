import AppKit
import SwiftUI

/// Configuration sheet for a single Gruppe: who it is, how it runs, and its
/// apps — three cards, in that order.
struct GroupEditorView: View {
    @EnvironmentObject private var store: GroupStore
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID

    @State private var name = ""

    private var group: AppGroup? { store.groups.first { $0.id == groupID } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "GRUPPE", badge: "KONFIGURATION", tint: group?.color ?? Theme.orange)
            if let group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identity(group)
                        LabeledSection(label: "AUSFÜHRUNG") { execution(group) }
                        LabeledSection(label: "APPLIKATIONEN — \(group.apps.count)") { apps(group) }
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
                footer(group)
            }
        }
        .frame(width: 580, height: 640)
        .background(Theme.panel.grain(0.26))
        .onAppear { name = group?.name ?? "" }
    }

    // MARK: Identity

    private func identity(_ group: AppGroup) -> some View {
        SettingsCard(rail: group.color) {
            TextField("Gruppe name", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit(commit)
                .cardRow()
            CardDivider()
            HStack(spacing: 12) {
                Text("Colour").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 12)
                SwatchRow(hex: group.colorHex) { store.setColor($0, for: group) }
            }
            .cardRow()
            CardDivider()
            HStack(spacing: 8) {
                Text("Shortcut").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    .help("Toggles this Gruppe from anywhere")
                Spacer(minLength: 12)
                ShortcutKeys(shortcut: group.shortcut,
                             unavailable: store.unavailableShortcuts.contains(group.id),
                             onRecordingChange: { $0 ? store.suspendHotkeys() : store.resumeHotkeys() },
                             onRecord: { store.setShortcut($0, for: group) })
            }
            .cardRow()
        }
    }

    // MARK: Execution

    private func execution(_ group: AppGroup) -> some View {
        SettingsCard {
            SwitchRow(title: "Launch in order", isOn: Binding(
                get: { group.isSequenced },
                set: { store.setSequenced($0, for: group) }
            ))
            .help("Launches top to bottom and quits bottom to top. Drag the apps below to set the order")
            if group.isSequenced {
                HStack(spacing: 12) {
                    Text("Pause between apps").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                        .help("Some apps refuse to come up cleanly while the one before them is still starting")
                    Spacer(minLength: 12)
                    IndustrialSlider(value: Binding(get: { group.sequenceDelay },
                                                    set: { store.setSequenceDelay($0, for: group) }),
                                     range: 0...3, step: 0.1)
                        .frame(width: 160)
                    Text(String(format: "%.1fs", group.sequenceDelay))
                        .font(Theme.mono(11).monospacedDigit())
                        .foregroundStyle(Theme.orange)
                        .frame(width: 34, alignment: .trailing)
                }
                .cardRow()
            }
            CardDivider()
            VStack(alignment: .leading, spacing: 9) {
                Text("When only some apps are running")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary)
                ChoiceSwitch(left: "Launch the rest", right: "Quit what's running",
                             isRight: Binding(get: { !group.fillsWhenPartial },
                                              set: { store.setFillsWhenPartial(!$0, for: group) }))
            }
            .cardRow()
        }
    }

    // MARK: Apps

    private func apps(_ group: AppGroup) -> some View {
        SettingsCard {
            if group.isSequenced {
                // A List is what gives `.onMove` real drag-reordering on macOS.
                List {
                    ForEach(Array(group.apps.enumerated()), id: \.element.id) { position, app in
                        AppRow(app: app, running: store.isRunning(app), step: position + 1, accent: group.color) {
                            store.remove([app.id], from: group)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .onMove { store.moveApps(in: group, from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(group.apps.count) * 42 + 4)
            } else {
                ForEach(group.apps) { app in
                    AppRow(app: app, running: store.isRunning(app)) {
                        store.remove([app.id], from: group)
                    }
                }
            }
            if !group.apps.isEmpty { CardDivider() }
            HStack {
                Button { addApps(group) } label: { Label("Add Applikationen…", systemImage: "plus") }
                    .industrialButton(.ghost)
                Spacer()
            }
            .padding(8)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls: urls, to: group)
            return true
        }
        .help(group.apps.isEmpty ? "Drop applications here" : "")
    }

    // MARK: Footer

    private func footer(_ group: AppGroup) -> some View {
        SheetFooter {
            Button("Delete Gruppe") {
                dismiss()
                store.delete(group)
            }
            .industrialButton(.danger)
            Spacer()
            Button("Done") { commit(); dismiss() }
                .industrialButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func commit() {
        guard let group else { return }
        store.rename(group, to: name)
    }

    private func addApps(_ group: AppGroup) {
        let panel = NSOpenPanel()
        panel.title = "Add Applikationen"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        store.add(urls: panel.urls, to: group)
    }
}

/// One app in a Gruppe: its step when the Gruppe runs in order, its icon and
/// name, whether it is up, and a remove key on hover.
private struct AppRow: View {
    let app: AppEntry
    let running: Bool
    var step: Int? = nil
    var accent: Color = Theme.orange
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let step {
                StepBadge(number: step, accent: accent, lit: running)
            }
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Text(app.name)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textPrimary)
                .help(app.bundleID.isEmpty ? app.path : app.bundleID)
            Spacer()
            if running {
                Chip(text: "LÄUFT", tint: Theme.green, size: 8.5)
            }
            Button(action: onRemove) {
                Image(systemName: "minus").font(.system(size: 10, weight: .bold))
            }
            .industrialButton(.ghost)
            .opacity(hovering ? 1 : 0)
            .help("Remove from the Gruppe")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(hovering ? Color.white.opacity(0.03) : Color.clear)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Illuminated position marker for a sequenced Gruppe. Lights in the Gruppe's
/// own colour once that step's app is up.
private struct StepBadge: View {
    let number: Int
    let accent: Color
    let lit: Bool

    var body: some View {
        Text("\(number)")
            .font(Theme.mono(10, .bold))
            .foregroundStyle(lit ? accent.litCore : Theme.textMuted)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(lit ? accent.opacity(0.16) : Color.black.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(lit ? accent.opacity(0.55) : Theme.borderSubtle, lineWidth: 1)
            )
            .shadow(color: lit ? accent.opacity(0.45) : .clear, radius: 4)
    }
}
