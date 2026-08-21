import SwiftUI

/// Sidebar plus the active tool.
///
/// A plain `HStack` rather than `NavigationSplitView`. The split view brought
/// its own sidebar toggle (so there were two), its own safe-area handling that
/// pushed the tool header under the title bar's drag region and swallowed
/// clicks on the header buttons, and it collapsed the sidebar whenever a detail
/// view asked for an unbounded width. This owns all three.
struct RootView: View {
    @EnvironmentObject private var navigation: NavigationModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
            ToolHost()
        }
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        // `openWindow` only exists inside a scene, and the menu bar items are
        // not in one. This is where it is handed over.
        .onAppear {
            MenuBarManager.shared.openMainWindow = { openWindow(id: WindowID.main) }
        }
    }
}

/// Renders the selected tool, or that tool's own settings pane.
///
/// This switch is the only place that knows which view belongs to which page,
/// which is what makes adding a tool a one-line change here.
struct ToolHost: View {
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader()
            // Pin to the top and fill: without this the header + content stack
            // centres itself, leaving a band of dead space above.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.page {
        case .telemetry:
            // Telemetry settings is the dashboard's own pane rather than a rail
            // entry of its own: it is the list of what the dashboard is allowed
            // to show and what each one costs, which belongs behind the thing it
            // configures.
            if navigation.showingSettingsPane { TelemetrySettingsView() } else { TelemetryDashboardView() }
        case .stash:
            StashPage()
        case .scripts:
            ScriptBuilderView()
        case .workspaces:
            if navigation.showingSettingsPane { WorkspacesSettingsPane() } else { WorkspacesView() }
        case .metrics:
            // Unreachable in a release build — `Page.isInThisBuild` keeps it out
            // of the rail — but still compiled, so the tool does not rot while
            // it is switched off.
            MetricsView()
        case .settings:
            GeneralSettingsPane()
        }
    }
}

/// Title plate above every tool. Carries the tool's identity and the way in
/// and out of its isolated settings pane.
private struct ToolHeader: View {
    @EnvironmentObject private var navigation: NavigationModel

    private var page: Page { navigation.page }
    private var inSettings: Bool { navigation.showingSettingsPane }

    var body: some View {
        HStack(spacing: 10) {
            if inSettings {
                Button { navigation.showingSettingsPane = false } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("Back")
                    }
                }
                .industrialButton(.ghost)
            }

            Text(inSettings ? page.shortTitle.uppercased() : page.rawValue.uppercased())
                .font(Theme.mono(11, .medium))
                .tracking(1.3)
                .foregroundStyle(Theme.textSecondary)

            Chip(text: inSettings ? page.settingsPaneBadge : page.badge,
                 tint: page.isImplemented ? Theme.orange : Theme.textMuted,
                 size: 9)

            Spacer()

            if page.hasSettingsPane, !inSettings {
                Button { navigation.showingSettingsPane = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
                .industrialButton(.secondary)
                .help("\(page.shortTitle) settings")
            }
        }
        // With the rail collapsed the traffic lights sit over this bar, so the
        // content has to start clear of them.
        .padding(.leading, navigation.sidebarCollapsed ? 82 : 20)
        .padding(.trailing, 20)
        .frame(height: 52)
        .background(
            LinearGradient(colors: [Theme.surfaceTop, Theme.panel],
                           startPoint: .top, endPoint: .bottom)
                .grain(0.34)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.55)).frame(height: 1) }
        .animation(.easeOut(duration: 0.18), value: navigation.sidebarCollapsed)
    }
}
