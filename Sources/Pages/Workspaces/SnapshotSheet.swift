import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Workspace snapshot

/// Turns what is on screen right now into a Gruppe.
struct SnapshotSheet: View {
    @EnvironmentObject private var store: GroupStore
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, [AppEntry]) -> Void

    @State private var candidates: [AppEntry] = []
    @State private var selected: Set<AppEntry.ID> = []
    @State private var name = "Workspace"

    private var chosen: [AppEntry] { candidates.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "WORKSPACE", badge: "SNAPSHOT")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsCard {
                        TextField("Gruppe name", text: $name)
                            .textFieldStyle(.plain)
                            .font(Theme.sans(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .cardRow()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SectionLabel("OPEN NOW")
                            Chip(text: "\(selected.count)/\(candidates.count)", tint: Theme.textSecondary, size: 9)
                            Spacer()
                            if !candidates.isEmpty {
                                Button(selected.count == candidates.count ? "None" : "All") {
                                    selected = selected.count == candidates.count ? [] : Set(candidates.map(\.id))
                                }
                                .industrialButton(.ghost)
                            }
                        }
                        SettingsCard {
                            if candidates.isEmpty {
                                Text("Nothing running that looks like a workspace app")
                                    .font(Theme.sans(12))
                                    .foregroundStyle(Theme.textMuted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 30)
                            }
                            ForEach(candidates) { app in
                                SnapshotRow(app: app, checked: selected.contains(app.id)) {
                                    if selected.contains(app.id) { selected.remove(app.id) } else { selected.insert(app.id) }
                                }
                                if app.id != candidates.last?.id { CardDivider() }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            SheetFooter {
                Button { addOffline() } label: { Label("Add Applikation…", systemImage: "plus") }
                    .industrialButton(.secondary)
                    .help("Include an app that isn't running")
                Spacer()
                Button("Cancel") { dismiss() }.industrialButton(.ghost)
                Button("Create Gruppe") {
                    onCreate(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Workspace" : name, chosen)
                    dismiss()
                }
                .industrialButton(.primary)
                .disabled(chosen.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560, height: 600)
        .background(Theme.panel.grain(0.26))
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func load() {
        candidates = store.snapshotCandidates()
        selected = Set(candidates.map(\.id))   // pre-checked
    }

    private func addOffline() {
        for entry in Pickers.apps().compactMap(AppEntry.init(url:)) {
            if !candidates.contains(where: { $0.id == entry.id }) { candidates.append(entry) }
            selected.insert(entry.id)
        }
        candidates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct SnapshotRow: View {
    let app: AppEntry
    let checked: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(checked ? Theme.orange : Theme.textMuted)
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                Text(app.name)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary)
                    .help(app.bundleID.isEmpty ? app.path : app.bundleID)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovering ? Color.white.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
    }
}
