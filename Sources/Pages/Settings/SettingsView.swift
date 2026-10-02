import AppKit
import SwiftUI

/// Application-wide preferences: how Gruppen itself starts and presents.
///
/// Anything that belongs to a *tool* lives in that tool's own pane instead —
/// termination behaviour and the application index are Workspaces settings,
/// not app settings.
struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        SettingsScroll {
            SettingToggle(title: "Launch at startup",
                          isOn: $settings.launchAtLogin)
            if let error = settings.loginItemError {
                Text("COULD NOT SET LOGIN ITEM — \(error)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingToggle(title: "Show in menu bar",
                          isOn: $settings.showMenuBar)
            SettingToggle(title: "Show Dock icon",
                          detail: "Turn off for a menu-bar-only workspace manager",
                          isOn: $settings.showDockIcon)
            FootNote("Only one can be disabled at a time.")

            SettingToggle(title: "Show system monitor",
                          isOn: $settings.showPerformanceMonitor)
            Button("Open Telemetry Settings") { navigation.openTelemetrySettings() }
                .industrialButton(.secondary)

            // Temporary, for developing the notchless stash on a notched Mac.
            // Remove before publishing — see `AppSettings.simulateNoNotch`.
            SettingToggle(title: "Simulate a Mac without a notch",
                          detail: "Temporary · the stash behaves as it would with no camera notch",
                          isOn: $settings.simulateNoNotch)

            LabeledSection(label: "BUILD") {
                KeyValue("Version", Bundle.versionString)
                KeyValue("Bundle", Bundle.main.bundleIdentifier ?? "—")
                KeyValue("Architecture", Bundle.architecture)
                KeyValue("Gruppen", GroupStore.defaultFileURL.path)
                KeyValue("Log", Self.logURL.path)

                HStack(spacing: 8) {
                    Button("Open Data Folder") {
                        FinderUtility.revealAndFocus(url: GroupStore.defaultFileURL)
                    }
                    .industrialButton(.secondary)
                    Button("Open Log") { NSWorkspace.shared.open(Self.logURL) }
                        .industrialButton(.secondary)
                }
            }
        }
        .onAppear { settings.refreshLoginItemStatus() }
    }

    private static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Gruppen.log")
    }
}

/// Shared scaffold for settings panes so every one scrolls and pads the same.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel.grain(0.26))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
