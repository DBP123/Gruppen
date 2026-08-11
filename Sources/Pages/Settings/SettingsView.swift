import AppKit
import SwiftUI

/// Application-wide preferences: how Gruppen itself starts and presents.
///
/// Anything that belongs to a *tool* lives in that tool's own pane instead —
/// termination behaviour and the application index are Workspaces settings,
/// not app settings.
struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        SettingsScroll {
            LabeledSection(label: "STARTUP") {
                SettingToggle(title: "Launch at startup",
                              detail: "Open Gruppen automatically when you log in",
                              isOn: $settings.launchAtLogin)
                if let error = settings.loginItemError {
                    Text("COULD NOT SET LOGIN ITEM — \(error)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledSection(label: "PRESENCE") {
                SettingToggle(title: "Show in menu bar",
                              detail: "Toggle any Gruppe without opening the window",
                              isOn: $settings.showMenuBar)
                SettingToggle(title: "Show Dock icon",
                              detail: "Turn off for a menu-bar-only workspace manager",
                              isOn: $settings.showDockIcon)
                FootNote("One of these stays on so the app is always reachable.")
            }

            LabeledSection(label: "MONITORING") {
                SettingToggle(title: "Show performance monitor",
                              detail: "CPU and memory readout at the top of the menu bar dropdown",
                              isOn: $settings.showPerformanceMonitor)
                FootNote("Sampling runs only while that menu is open, so the readout costs nothing when it is closed.")
            }

            LabeledSection(label: "BUILD") {
                KeyValue("Version", Bundle.versionString)
                KeyValue("Bundle", Bundle.main.bundleIdentifier ?? "—")
                KeyValue("Architecture", Bundle.architecture)
                KeyValue("Gruppen", GroupStore.defaultFileURL.path)
                KeyValue("Log", Self.logURL.path)

                HStack(spacing: 8) {
                    Button("Reveal Data Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([GroupStore.defaultFileURL])
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
