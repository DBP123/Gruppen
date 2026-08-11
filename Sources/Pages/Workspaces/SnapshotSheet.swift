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
            header
            content
            footer
        }
        .frame(width: 560, height: 600)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Text("WORKSPACE")
                    .font(Theme.mono(11, .medium))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textSecondary)
                Chip(text: "SNAPSHOT", tint: Theme.orange, size: 9)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .industrialButton(.ghost)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NAME")
                        .font(Theme.mono(10, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Theme.textMuted)
                    TextField("Gruppe name", text: $name)
                        .textFieldStyle(.plain)
                        .font(Theme.sans(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .recessed()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CURRENTLY OPEN — \(selected.count)/\(candidates.count)")
                            .font(Theme.mono(10, .semibold))
                            .tracking(1.1)
                            .foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button(selected.count == candidates.count ? "None" : "All") {
                            selected = selected.count == candidates.count ? [] : Set(candidates.map(\.id))
                        }
                        .industrialButton(.ghost)
                    }

                    if candidates.isEmpty {
                        Text("Nothing running that looks like a workspace app.")
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(candidates) { app in
                                SnapshotRow(app: app, checked: selected.contains(app.id)) {
                                    if selected.contains(app.id) {
                                        selected.remove(app.id)
                                    } else {
                                        selected.insert(app.id)
                                    }
                                }
                                if app.id != candidates.last?.id {
                                    Rectangle().fill(Theme.borderSubtle).frame(height: 1)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 1))
                    }
                }
            }
            .padding(20)
        }
    }

    private var footer: some View {
        HStack {
            Button("+ Add Offline App") { addOffline() }
                .industrialButton(.secondary)
                .help("Include an app from /Applications that isn't running")
            Spacer()
            Button("Create Gruppe from Snapshot") {
                onCreate(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Workspace" : name, chosen)
                dismiss()
            }
            .industrialButton(.primary)
            .disabled(chosen.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSubtle).frame(height: 1) }
    }

    private func load() {
        candidates = store.snapshotCandidates()
        selected = Set(candidates.map(\.id))   // pre-checked
    }

    private func addOffline() {
        let panel = NSOpenPanel()
        panel.title = "Add Applikationen"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }

        for entry in panel.urls.compactMap(AppEntry.init(url:)) {
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                    Text(app.bundleID.isEmpty ? app.path : app.bundleID)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovering ? Theme.surfaceHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
    }
}
