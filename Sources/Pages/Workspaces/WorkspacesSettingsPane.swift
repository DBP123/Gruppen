import AppKit
import SwiftUI

/// The Workspaces tool's settings pane: how Gruppen come up and go down, and
/// the way back to the Dock you had. Behind the header's settings key, like
/// Telemetry's, because the Workspaces page itself is already full.
struct WorkspacesSettingsPane: View {
    var body: some View {
        SettingsScroll {
            WorkspacesSettings()
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

