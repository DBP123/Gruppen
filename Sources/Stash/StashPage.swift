import AppKit
import SwiftUI

/// The Stash page: what the notch shelf is holding, how many shelves are open,
/// and the ways to summon one.
struct StashPage: View {
    @EnvironmentObject private var stash: StashCoordinator
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        if navigation.showingSettingsPane {
            StashSettingsPane()
        } else {
            SettingsScroll {
                LabeledSection(label: "NOTCH SHELF") {
                    NotchShelfSummary()
                        .environmentObject(stash.notchShelf)
                }

                LabeledSection(label: "HOW TO OPEN A SHELF") {
                    TriggerRow(systemImage: "macbook",
                               title: "Drag to the notch",
                               detail: "Opens the notch shelf at the top of the screen")
                    TriggerRow(systemImage: "arrow.left.and.right",
                               title: "Shake while dragging",
                               detail: "Spawns a new shelf beside the pointer — shake again for another")
                    TriggerRow(systemImage: "rectangle.lefthalf.inset.filled",
                               title: "Drag to a screen edge",
                               detail: "Either side edge spawns a shelf too")
                }
            }
        }
    }
}

/// Contents of the notch shelf, plus a live count of floating shelves.
private struct NotchShelfSummary: View {
    @EnvironmentObject private var stash: StashCoordinator
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var shelf: ShelfState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LED(color: Theme.orange, lit: !shelf.isEmpty, size: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shelf.isEmpty ? "Nothing on the notch shelf" : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(stash.openShelfCount) shelf/shelves open")
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
                .onDrag {
                    let provider = item.itemProvider
                    Task { @MainActor in shelf.remove(item) }
                    return provider
                }
            }
        }
    }
}

private struct TriggerRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.sans(13)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .panelRow()
    }
}

/// Picks where "Export as Zip" writes.
private struct ExportPathRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Download folder")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textPrimary)
                Text(settings.exportDirectory.path)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: choose)
                .industrialButton(.secondary)
        }
        .panelRow()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a download folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.exportPath = url.path
    }
}

/// Isolated settings for the Stash tool.
struct StashSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        SettingsScroll {
            LabeledSection(label: "SHELF") {
                SettingToggle(title: "Enable the stash shelf",
                              detail: "Notch, screen-edge and shake triggers",
                              isOn: $settings.stashEnabled)
            }
            LabeledSection(label: "EXPORT") {
                ExportPathRow()
                FootNote("The zip button on a shelf writes every file it holds, plus any text as .txt, into this folder.")
            }

            LabeledSection(label: "IDLE COST") {
                FootNote("The triggers are invisible drop targets that the window server hit-tests for free, and the shake monitor only exists between mouse-down and mouse-up. Nothing polls, and the pasteboard is read once per confirmed shake.")
            }
        }
    }
}
