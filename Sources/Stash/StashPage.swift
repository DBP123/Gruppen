import AppKit
import SwiftUI

/// The Stash page: the stashes you have hidden, and every stash setting.
///
/// One page rather than a page and a settings pane: the page itself was a
/// single row, and sending you somewhere else for eight switches made the
/// settings the harder thing to find.
struct StashPage: View {
    var body: some View {
        SettingsScroll {
            HiddenStashes()
            LabeledSection(label: "SETTINGS") {
                StashSettings()
            }
        }
    }
}

/// Floating stashes put away with their hide key, each drawn as what it holds,
/// with a way back. Nothing at all when none are hidden — an empty section
/// would only say so.
private struct HiddenStashes: View {
    @ObservedObject private var manager = ShelfWindowManager.shared

    var body: some View {
        let hidden = manager.hiddenShelves
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("HIDDEN STASHES")
                        .font(Theme.mono(10, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    if hidden.count > 1 {
                        Button("Reopen all") { manager.reopenAll() }
                            .industrialButton(.secondary, compact: true)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(hidden) { shelf in
                        HiddenStashCard(shelf: shelf) { manager.reopen(shelf.id) }
                    }
                }
            }
            .transition(.opacity)
        }
    }
}

/// One hidden stash: its files as a row of icons, and the key that brings it
/// back where it was.
private struct HiddenStashCard: View {
    @ObservedObject var shelf: ShelfState
    let reopen: () -> Void

    private static let shown = 5

    private var summary: String {
        shelf.items.count == 1 ? shelf.items[0].title : "\(shelf.items.count) items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: -6) {
                ForEach(shelf.items.prefix(Self.shown)) { item in
                    Image(nsImage: item.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                }
                if shelf.items.count > Self.shown {
                    Text("+\(shelf.items.count - Self.shown)")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 12)
                }
            }
            HStack(spacing: 8) {
                Text(summary)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Reopen", action: reopen)
                    .industrialButton(.secondary, compact: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .machined(cornerRadius: 10)
        .help(shelf.items.map(\.title).joined(separator: "\n"))
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
                ChoiceSwitch(left: "Copy files with stash", right: "Move files with stash",
                             isRight: $settings.stashMovesOnDragOut)
                    .cardRow()
                CardDivider()
                SwitchRow(title: "Clear notch stash on close", isOn: $settings.notchCloseClearsStash)
                CardDivider()
                ShortcutRow(title: "Shortcut to open a stash", shortcut: $settings.stashShortcut)
                CardDivider()
                ShortcutRow(title: "Shortcut to toggle stash visibility", shortcut: $settings.stashToggleShortcut)
                CardDivider()
                ExportFolderRow()
            }
        }
    }

    @ViewBuilder private var triggers: some View {
        OptionPill(title: "Drag to notch", isOn: $settings.stashNotchEnabled)
        OptionPill(title: "Drag to edges", isOn: $settings.stashEdgeEnabled)
        OptionPill(title: "Shake to enable", isOn: $settings.stashShakeEnabled)
    }
}

/// One of the stash's global shortcuts, re-registered the moment it changes.
private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: Shortcut?
    @EnvironmentObject private var stash: StashCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            ShortcutKeys(shortcut: shortcut) { recorded in
                shortcut = recorded
                stash.applyShortcuts()
            }
        }
        .cardRow()
    }
}

/// Where zips and extractions are written. The folder's name is the button;
/// its full path is the tooltip.
private struct ExportFolderRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Text("Change zips").font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
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
