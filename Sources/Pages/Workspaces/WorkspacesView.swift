import AppKit
import SwiftUI

/// The Workspaces page: the Gruppen, the profiles they run in, and the two
/// settings that decide how a Gruppe comes up and goes down.
///
/// The settings live here rather than behind a settings pane: there are two of
/// them, and sending you to another page for two controls made them the hardest
/// thing on it to find.
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
                    LabeledSection(label: "SETTINGS") { WorkspacesSettings() }
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

/// How Gruppen come up and go down, and the way back to the Dock you had.
private struct WorkspacesSettings: View {
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var settings: AppSettings

    /// Seconds a quitting app gets before it is killed; 0 kills at once.
    private static let grace: [TimeInterval] = [0, 3, 10]

    var body: some View {
        SettingsCard {
            SwitchRow(title: "Bring apps forward when launching", isOn: $settings.activateOnLaunch)
            CardDivider()
            VStack(alignment: .leading, spacing: 9) {
                Text("When a Gruppe closes")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary)
                SegmentedChoice(
                    options: ["Force quit now", "Quit, force after 3s", "Quit, force after 10s"],
                    selection: Binding(
                        get: { Self.grace.firstIndex(of: store.gracePeriod) ?? 1 },
                        set: { store.gracePeriod = Self.grace[$0] }
                    ),
                    help: ["Instant, but unsaved work in those apps is lost",
                           "Asks each app to quit, and kills what is still open after 3 seconds",
                           "Asks each app to quit, and kills what is still open after 10 seconds"])
            }
            .cardRow()
            if DockManager.hasBackup {
                CardDivider()
                HStack(spacing: 12) {
                    Text("Original Dock").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 12)
                    Button("Restore") { _ = DockManager.restoreOriginal() }
                        .industrialButton(.secondary)
                        .help("Puts the Dock back to how it was before any profile changed it")
                }
                .cardRow()
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
