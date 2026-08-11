import AppKit
import SwiftUI

/// Settings that belong to the Workspaces tool alone: what happens when a
/// Gruppe launches or terminates, and the application index behind suggestions.
struct WorkspacesSettingsPane: View {
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var settings: AppSettings

    private static let graceOptions: [(title: String, detail: String, value: TimeInterval)] = [
        ("Force quit immediately", "SIGKILL — instantaneous", 0),
        ("Quit, force after 3s", "Graceful, short leash", 3),
        ("Quit, force after 10s", "Graceful, generous leash", 10),
    ]

    var body: some View {
        SettingsScroll {
            LabeledSection(label: "LAUNCH") {
                SettingToggle(title: "Focus apps when launching",
                              detail: "Bring windows forward instead of opening them behind your work",
                              isOn: $settings.activateOnLaunch)
            }

            LabeledSection(label: "WHEN DEACTIVATING A GRUPPE") {
                ForEach(Self.graceOptions, id: \.value) { option in
                    RadioRow(title: option.title,
                             detail: option.detail,
                             selected: store.gracePeriod == option.value) {
                        store.gracePeriod = option.value
                    }
                }
                Text("Force quitting is instant, but unsaved work in those applications is lost. The delayed modes send a normal quit first and only kill what is still alive when the timer expires.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledSection(label: "APPLICATION INDEX") {
                ApplicationIndexRow()
                SettingToggle(title: "Show suggested Gruppen",
                              detail: "Preset chips on the overview when matching apps are installed",
                              isOn: $settings.showSuggestions)
            }
        }
    }
}

/// Rescans `/Applications` and friends: re-evaluates the preset rules, repairs
/// group entries whose bundle moved, and drops stale cached icons.
///
/// The directory walk runs off the main actor and only when asked — there is
/// no watcher and no timer behind this.
private struct ApplicationIndexRow: View {
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var settings: AppSettings
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rescan Applications")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Refresh presets, repair moved apps, clear icon cache")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button(action: rescan) {
                    HStack(spacing: 6) {
                        if scanning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        }
                        Text(scanning ? "Scanning…" : "Rescan")
                    }
                }
                .industrialButton(.secondary)
                .disabled(scanning)
            }
            .panelRow()

            HStack(spacing: 7) {
                LED(color: store.indexReport == nil ? Theme.textMuted : Theme.green,
                    lit: store.indexReport != nil,
                    size: 6)
                Text(store.indexReport?.summary ?? "Not scanned this session")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
            }

            if !store.suggestions.isEmpty {
                Text(settings.showSuggestions
                     ? "\(store.suggestions.count) suggested Gruppe(n) available on the overview"
                     : "\(store.suggestions.count) match(es) found — hidden by the setting below")
                    .font(Theme.mono(10))
                    .foregroundStyle(settings.showSuggestions ? Theme.orange : Theme.textMuted)
            }
        }
    }

    private func rescan() {
        scanning = true
        Task {
            await store.rescanApplications()
            scanning = false
        }
    }
}
