import AppKit
import SwiftUI

/// The Stash page: what the notch stash is holding, and every stash setting.
///
/// One page rather than a page and a settings pane: the page itself was a
/// single row, and sending you somewhere else for eight switches made the
/// settings the harder thing to find.
struct StashPage: View {
    @EnvironmentObject private var stash: StashCoordinator

    var body: some View {
        SettingsScroll {
            LabeledSection(label: "NOTCH STASH") {
                NotchStashSummary()
                    .environmentObject(stash.notchShelf)
            }
            LabeledSection(label: "SETTINGS") {
                StashSettings()
            }
        }
    }
}

/// Contents of the notch stash, and whether its tray is out.
private struct NotchStashSummary: View {
    @EnvironmentObject private var stash: StashCoordinator
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var shelf: ShelfState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LED(color: Theme.orange, lit: !shelf.isEmpty, size: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shelf.isEmpty ? "Nothing on the notch stash" : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                    // There is one notch, so one notch stash: open or not.
                    Text(stash.isNotchOpen ? "Notch stash open" : "No stashes open")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if !shelf.isEmpty {
                    Button("Clear") { shelf.clear() }
                        .industrialButton(.secondary)
                }
            }
            .panelRow()

            ForEach(shelf.items) { item in
                HStack(spacing: 10) {
                    Image(nsImage: item.icon)
                        .resizable().interpolation(.high)
                        .frame(width: 20, height: 20)
                    Text(item.title)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { shelf.remove(item) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .industrialButton(.ghost)
                }
                .panelRow()
                .stashDraggable(item, from: shelf)
            }
        }
    }
}

/// Every stash setting, in two cards.
///
/// The first is the master switch and the three ways of opening a stash,
/// drawn as options *of* that switch — pills inside its card — rather than as
/// three more switches that look like settings in their own right. They fold
/// away when stashes are off, since an option of nothing does nothing.
///
/// The second is how stashes behave. No line of grey under any title: each
/// title says what the control does, and the control shows its state.
private struct StashSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                SwitchRow(title: "Enable stashes", isOn: $settings.stashEnabled)
                if settings.stashEnabled {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { triggers }
                        VStack(spacing: 6) { triggers }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: settings.stashEnabled)

            SettingsCard {
                SwitchRow(title: "Move files when dragging out", isOn: $settings.stashMovesOnDragOut)
                CardDivider()
                SwitchRow(title: "Clear the notch stash on close", isOn: $settings.notchCloseClearsStash)
                CardDivider()
                StashShortcutRow()
                CardDivider()
                ExportFolderRow()
            }
        }
    }

    @ViewBuilder private var triggers: some View {
        OptionPill(title: "Drag to the notch", isOn: $settings.stashNotchEnabled)
        OptionPill(title: "Drag to a screen edge", isOn: $settings.stashEdgeEnabled)
        OptionPill(title: "Shake while dragging", isOn: $settings.stashShakeEnabled)
    }
}

/// Records the global shortcut that opens a stash. The modifier rule lives in
/// the tooltip and the recording state in the key itself, so the row needs no
/// second line.
private struct StashShortcutRow: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var stash: StashCoordinator
    @StateObject private var recorder = KeyRecorder()

    var body: some View {
        HStack(spacing: 8) {
            Text("Shortcut to open a stash").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            if let shortcut = settings.stashShortcut, !recorder.isRecording {
                KeyBadge(text: shortcut.display)
                Button("Clear") {
                    settings.stashShortcut = nil
                    stash.applySummonShortcut()
                }
                .industrialButton(.ghost)
            }
            Button(recorder.isRecording ? "Press keys…" : (settings.stashShortcut == nil ? "Record" : "Change")) {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start { recorded in
                        settings.stashShortcut = recorded
                        stash.applySummonShortcut()
                    }
                }
            }
            .industrialButton(recorder.isRecording ? .danger : .secondary)
            .help(recorder.isRecording ? "Click to cancel" : "Use ⌘, ⌥ or ⌃ with a key")
        }
        .cardRow()
        .onDisappear { recorder.stop() }
    }
}

/// Where zips and extractions are written. The folder's name is the button;
/// its full path is the tooltip.
private struct ExportFolderRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Text("Save zips and extractions to").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            Button(action: choose) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.system(size: 11))
                    Text(settings.exportDirectory.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .industrialButton(.secondary)
            .help(settings.exportDirectory.path)
        }
        .cardRow()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose where zips and extractions go"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.exportPath = url.path
    }
}
