import AppKit
import SwiftUI

/// A floating shelf: what you are carrying, what you can do with it, and
/// somewhere to put more.
struct StashTrayView: View {
    @EnvironmentObject private var state: ShelfState
    @EnvironmentObject private var settings: AppSettings

    var onClose: () -> Void

    @State private var zip: ZipStatus?
    @State private var hovering = false

    /// Set by the hosting view, which is the only thing that sees the drag.
    private var isTargeted: Bool { state.isTargeted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
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
        // Animates the action bar's keys coming and going with the selection.
        // A change is animated by whatever watches it from outside the view
        // being changed, which is why this sits out here.
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state.selection.count)
        .onHover { hovering = $0 }
        // A success note clears itself after five seconds. Keyed on the
        // status, so a second zip started in that window cancels the timer
        // rather than having it wipe the new zip's status. A failure stays
        // until the next zip: it is the one you need time to read.
        .task(id: zip) {
            guard case .saved = zip else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            withAnimation(.easeOut(duration: 0.3)) { zip = nil }
        }
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
                      ? "Compress the stash into \(settings.exportDirectory.lastPathComponent)"
                      : "Compress the \(state.selection.count) selected into \(settings.exportDirectory.lastPathComponent)")
            }
            // One key, not two. There used to be a trash beside a minus, and
            // they did the same thing: clearing a stash empties it, an emptied
            // stash closes itself, and "minimise" destroyed the window outright
            // — nothing was ever minimised anywhere to come back from. A stash
            // holds files by reference, so closing one puts nothing at risk.
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .hardwareKey(size: 18, glow: true)
            .help("Close the stash")
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
        zip = .working
        Task { @MainActor in
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    try StashExporter.export(items: payload, to: destination)
                }.value
                zip = .saved(archive.lastPathComponent)
                FinderUtility.revealAndFocus(url: archive)
            } catch {
                // The full error goes to the log; the shelf gets one short line.
                GroupStore.log("STASH zip failed — \(error)")
                zip = .failed((error as? StashExporter.ExportError)?.errorDescription
                              ?? "Couldn't create the zip")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let zip {
            Text(zip.message)
                .font(Theme.mono(9))
                .foregroundStyle(zip.tint)
                .lineLimit(1)
                .truncationMode(.middle)
                .transition(.opacity)
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
            StashActionBar()
        }
    }
}

/// The one line of feedback under a shelf's header after the zip key is pressed.
private enum ZipStatus: Equatable {
    case working
    case saved(String)
    case failed(String)

    var message: String {
        switch self {
        case .working: return "Zipping…"
        case .saved(let name): return "Saved \(name)"
        case .failed(let reason): return "Zip failed: \(reason)"
        }
    }

    var tint: Color {
        switch self {
        case .working: return Theme.textMuted
        case .saved: return Theme.green
        case .failed: return Theme.red
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
        // Click picks one out; ⇧- or ⌘-click adds or removes just this one.
        // Zip, convert, extract and dragging out then act on that set instead
        // of the whole stash.
        //
        // **One gesture, reading the flags itself.** A plain `TapGesture`
        // matches regardless of what is held, so pairing it with a
        // `.modifiers(.shift)` twin meant a shift-click fired both and they
        // raced. Reading the flags once means exactly one thing happens.
        .simultaneousGesture(
            TapGesture().onEnded {
                state.select(item, gesture: .init(modifiers: NSEvent.modifierFlags))
            }
        )
        .stashDraggable(item, from: state)
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
                .help("Copy path")
            }
            Button { state.remove(item) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .hardwareKey(size: 20)
            .help("Take it off the stash")
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
