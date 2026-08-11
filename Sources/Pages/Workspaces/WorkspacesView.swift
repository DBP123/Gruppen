import AppKit
import SwiftUI

/// The Workspaces tool: search, suggestions, the Gruppe grid, and a status bar.
///
/// The window chrome it used to own now belongs to `ToolHost`, so this is just
/// the tool's own content.
struct WorkspacesView: View {
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var settings: AppSettings

    @State private var query = ""
    @State private var editing: AppGroup?
    @State private var snapshotting = false

    /// Filtering allocates only when there is actually a query.
    private var filtered: [AppGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.groups }
        return store.groups.filter { group in
            group.name.localizedCaseInsensitiveContains(trimmed)
                || group.apps.contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            deck
            StatusBar()
        }
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

    private var deck: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                toolbar

                if settings.showSuggestions, !store.suggestions.isEmpty {
                    SuggestionStrip()
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
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel.grain(0.26))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            SearchField(text: $query)
            Spacer()
            Text(stats)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
            Button { snapshotting = true } label: { Text("Snapshot") }
                .industrialButton(.secondary)
                .help("Build a Gruppe from the apps you have open right now")
            Button { editing = store.addGroup() } label: { Text("+ New Gruppe") }
                .industrialButton(.primary)
                .keyboardShortcut("n")
        }
    }

    private var stats: String {
        "\(store.groups.count) GRUPPEN // \(store.activeCount) AKTIV"
    }
}

/// Footer plate. Reads only the two aggregate counters the store maintains, so
/// it re-renders when they change and not when any group is merely edited.
private struct StatusBar: View {
    @EnvironmentObject private var store: GroupStore

    private var tint: Color { store.activeCount > 0 ? Theme.orange : Theme.green }

    private var text: String {
        guard store.activeCount > 0 else { return "SYSTEM READY" }
        return "\(store.runningTotal) PROCESSES // \(store.activeCount) AKTIV"
    }

    var body: some View {
        HStack {
            HStack(spacing: 7) {
                LED(color: tint, lit: true, size: 7)
                Text("STATUS:").foregroundStyle(Theme.textMuted)
                Text(text).foregroundStyle(tint)
            }
            Spacer()
            HStack(spacing: 16) {
                hint("⌘N", "New")
                hint("⌘F", "Search")
                hint("⌘\\", "Sidebar")
                hint("⌥⌘·", "Toggle Gruppe")
            }
        }
        .font(Theme.mono(11))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(
            LinearGradient(colors: [Theme.panel, Theme.root], startPoint: .top, endPoint: .bottom)
                .grain(0.34)
        )
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(Theme.textSecondary)
            Text(label).foregroundStyle(Theme.textMuted)
        }
    }
}
