import AppKit
import SwiftUI

/// A floating shelf: what you are carrying, what you can do with it, and
/// somewhere to put more.
struct StashTrayView: View {
    @EnvironmentObject private var state: ShelfState
    @EnvironmentObject private var settings: AppSettings

    var onMinimize: () -> Void
    /// Nil only if a shelf is somehow opened before the store exists; the
    /// routing chips are simply absent in that case.
    var store: GroupStore?

    @State private var exportNote: String?
    @State private var hovering = false

    /// Set by the hosting view, which is the only thing that sees the drag.
    private var isTargeted: Bool { state.isTargeted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            if let store, !state.isEmpty {
                TargetRoutingRow(store: store).environmentObject(state)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shelfBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isTargeted ? Theme.ambient : Theme.borderStrong,
                              lineWidth: isTargeted ? 2 : 1)
        )
        // Only the border and the glow react. Scaling the whole shelf meant
        // re-rasterising it every frame, which is what made it feel heavy.
        .ambientGlow(isTargeted || hovering)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }

    private var shelfBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.panel.opacity(0.98))
    }

    private var header: some View {
        HStack(spacing: 8) {
            LED(color: Theme.orange, lit: !state.isEmpty, size: 7)
            Text("STASH")
                .font(Theme.mono(10, .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if !state.isEmpty {
                Text(state.selection.isEmpty
                     ? "\(state.items.count)"
                     : "\(state.selection.count)/\(state.items.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(state.selection.isEmpty ? Theme.textMuted : Theme.ambient)
                Button(action: exportZip) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 10, weight: .bold))
                }
                .hardwareKey()
                .help(state.selection.isEmpty
                      ? "Compress the shelf into \(settings.exportDirectory.lastPathComponent)"
                      : "Compress the \(state.selection.count) selected into \(settings.exportDirectory.lastPathComponent)")
                Button { state.clear() } label: {
                    Image(systemName: "trash").font(.system(size: 10, weight: .bold))
                }
                .hardwareKey()
                .help("Clear the shelf")
            }
            Button(action: onMinimize) {
                Image(systemName: "minus").font(.system(size: 10, weight: .bold))
            }
            .hardwareKey()
            .help("Minimise the shelf")
        }
        // The whole strip drags the window, handled by AppKit so it tracks the
        // cursor exactly. Sits behind the buttons so they still receive clicks.
        .background(WindowDragHandle())
    }

    /// Zips the selection — or the whole shelf when nothing is picked out — off
    /// the main actor, then reports where it landed.
    private func exportZip() {
        let payload = state.actionable.map { (name: $0.title, url: $0.fileURL, text: $0.text) }
        let destination = settings.exportDirectory
        exportNote = "Zipping…"
        Task {
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try StashExporter.export(items: payload, to: destination)
                }.value
                await MainActor.run { exportNote = "Saved \(archive.lastPathComponent)" }
            } catch {
                await MainActor.run { exportNote = "! \(error.localizedDescription)" }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let exportNote {
            Text(exportNote)
                .font(Theme.mono(9))
                .foregroundStyle(exportNote.hasPrefix("!") ? Theme.red : Theme.green)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if state.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isTargeted ? Theme.orange : Theme.textMuted)
                Text("Drop to stash")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(state.items) { item in
                        StashRow(item: item)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: state.items.count)
            ConvertBar()
        }
    }
}

/// Appears when what is selected can become something else.
///
/// Only offers conversions that make sense for the selection: the targets come
/// from the files' own family, and a mixed selection offers nothing, because
/// there is no single sensible answer for "convert a png and a wav".
private struct ConvertBar: View {
    @EnvironmentObject private var state: ShelfState
    @State private var note: String?
    @State private var working = false

    private var subjects: [StashItem] {
        state.actionable.filter { $0.fileURL != nil }
    }

    private var targets: [FileConverter.Target] {
        FileConverter.targets(for: subjects.compactMap(\.fileURL))
    }

    var body: some View {
        if !targets.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("CONVERT")
                        .font(Theme.mono(8, .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.textMuted)
                    Text(state.selection.isEmpty ? "all \(subjects.count)" : "\(subjects.count) selected")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.textMuted.opacity(0.7))
                    Spacer(minLength: 0)
                    if let note {
                        Text(note)
                            .font(Theme.mono(8))
                            .foregroundStyle(note.hasPrefix("!") ? Theme.red : Theme.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(targets) { target in
                        Button(target.label) { convert(to: target) }
                            .industrialButton(.secondary)
                            .disabled(working)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func convert(to target: FileConverter.Target) {
        let urls = subjects.compactMap(\.fileURL)
        guard !urls.isEmpty else { return }
        working = true
        note = "Converting…"
        Task {
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try FileConverter.convert(urls, to: target)
                }.value
                await MainActor.run {
                    // The results join the shelf, so they can be dragged
                    // straight out without going looking for them.
                    state.add(results.map { .file($0) })
                    note = "\(results.count) → \(target.label)"
                    working = false
                }
            } catch {
                await MainActor.run {
                    note = "! \(error.localizedDescription)"
                    working = false
                }
            }
        }
    }
}

/// One shelved thing. Draggable straight back out into any app, with its quick
/// actions revealed on hover rather than parked on screen permanently.
private struct StashRow: View {
    @EnvironmentObject private var state: ShelfState
    let item: StashItem

    @State private var hovering = false
    @State private var copied = false

    private var selected: Bool { state.selection.contains(item.id) }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(item.title)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // The slot is always here and always this wide; only its contents
            // fade. Revealing the buttons used to re-truncate the file name and
            // shove the row's contents left as the pointer arrived.
            actions
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .frame(width: item.fileURL != nil ? 84 : 30, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .machined(fill: hovering ? Color(hex: 0x17171A) : Theme.machined,
                  border: selected ? Theme.ambient : Theme.machinedBorder)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Click picks a file out; shift-click builds a set. Zip and convert
        // then act on that set instead of the whole shelf.
        .simultaneousGesture(
            TapGesture().modifiers(.shift).onEnded { state.select(item, extending: true) }
        )
        .simultaneousGesture(
            TapGesture().onEnded { state.select(item, extending: false) }
        )
        .onDrag {
            // Dragging out consumes the item; emptying the shelf closes it.
            let provider = item.itemProvider
            Task { @MainActor in state.remove(item) }
            return provider
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if item.fileURL != nil {
                Button { QuickLook.preview(item.fileURL!) } label: {
                    Image(systemName: "eye").font(.system(size: 9, weight: .bold))
                }
                .hardwareKey(size: 20)
                .help("Quick Look")

                Button(action: copyPath) {
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 9, weight: .bold))
                }
                .hardwareKey(size: 20)
                .help("Copy the POSIX path")
            }
            Button { state.remove(item) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .hardwareKey(size: 20)
            .help("Take it off the shelf")
        }
    }

    private func copyPath() {
        guard let path = item.fileURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

/// Gruppe chips along the bottom of the tray. Drop a file on one and it opens in
/// that workspace's apps.
///
/// Same contract as the Stash page: a Gruppe that is not running is not started
/// by dropping on it — the chip's lamp just goes red and clears itself.
private struct TargetRoutingRow: View {
    @ObservedObject var store: GroupStore
    @EnvironmentObject private var state: ShelfState
    @Environment(\.dropZones) private var registry

    @State private var failures: [UUID: WorkspaceRouter.Outcome] = [:]

    var body: some View {
        if store.groups.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("DROP ON A GRUPPE")
                    .font(Theme.mono(8, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.textMuted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.groups) { group in
                            chip(for: group)
                        }
                    }
                }
            }
            // Drops routed to a chip come back here rather than being handled by
            // the window controller, so a refusal lights the chip that refused.
            .onAppear {
                registry?.onZoneItems = { groupID, items in
                    guard let group = store.groups.first(where: { $0.id == groupID }) else { return }
                    send(items, to: group)
                }
            }
        }
    }

    private func chip(for group: AppGroup) -> some View {
        HStack(spacing: 5) {
            LED(color: failures[group.id] == nil ? group.color : Theme.red,
                lit: failures[group.id] != nil || group.isActive,
                size: 5)
            Text(group.name)
                .font(Theme.sans(10, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .recessed(cornerRadius: 4, fill: Theme.surface)
        // Claims this rectangle for itself: a drop released here routes to this
        // Gruppe instead of landing on the shelf.
        .dropZone(group.id)
        .onTapGesture { send(state.items, to: group) }
        .help("Open on \(group.name)")
    }

    private func send(_ items: [StashItem], to group: AppGroup) {
        let urls = items.compactMap(\.fileURL)
        failures[group.id] = nil
        Task { @MainActor in
            let outcome: WorkspaceRouter.Outcome =
                urls.isEmpty ? .refused : await WorkspaceRouter.send(urls, to: group)
            guard outcome != .sent else { return }
            failures[group.id] = outcome
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if failures[group.id] == outcome { failures[group.id] = nil }
        }
    }
}
