import AppKit
import SwiftUI

/// The Workspaces page: the Gruppen, and the profiles they run in. Its
/// settings are a pane of their own (`WorkspacesSettingsPane`) — this page is
/// busy enough without them.
struct WorkspacesView: View {
    @EnvironmentObject private var store: GroupStore

    @State private var query = ""
    @State private var editing: AppGroup?
    @State private var snapshotting = false

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Filtering allocates only when there is actually a query.
    private var filtered: [AppGroup] {
        guard searching else { return store.groups }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return store.groups.filter { group in
            group.name.localizedCaseInsensitiveContains(trimmed)
                || group.apps.contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                toolbar
                gruppen
                // A search is a question about Gruppen, so the rest steps aside
                // while one is typed.
                if !searching {
                    WorkspaceProfileDeck()
                }
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel.grain(0.26))
        .sheet(item: $editing) { group in
            GroupEditorView(groupID: group.id).environmentObject(store)
        }
        .sheet(isPresented: $snapshotting) {
            SnapshotSheet { name, apps in
                editing = store.createGroup(named: name, apps: apps)
            }
            .environmentObject(store)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            SearchField(text: $query)
            Spacer()
            Button { snapshotting = true } label: { Label("Snapshot", systemImage: "camera.viewfinder") }
                .industrialButton(.secondary)
                .help("Build a Gruppe from the apps you have open right now")
            Button { editing = store.addGroup() } label: { Label("New Gruppe", systemImage: "plus") }
                .industrialButton(.primary)
                .keyboardShortcut("n")
        }
    }

    @ViewBuilder private var gruppen: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("GRUPPEN")
                if store.activeCount > 0 {
                    Chip(text: "\(store.activeCount) AKTIV", tint: Theme.green, size: 9)
                }
            }
            if store.groups.isEmpty {
                EmptyState { editing = store.addGroup() }
            } else if filtered.isEmpty {
                NoResults(query: query)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16)], spacing: 16) {
                    ForEach(filtered) { group in
                        GruppeCard(group: group, onEdit: { editing = group })
                    }
                }
            }
        }
    }
}

/// The mono caption over a block — the same as `LabeledSection`'s, for places
/// where something sits beside it.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(10, .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.textMuted)
    }
}
