import AppKit
import SwiftUI

@main
struct GruppenApp: App {
    @StateObject private var store: GroupStore
    @StateObject private var stash: StashCoordinator
        @StateObject private var settings = AppSettings.shared
    @StateObject private var navigation = NavigationModel()
    @StateObject private var monitor = PerformanceMonitor()
    @StateObject private var scripts: ScriptLibrary
    @StateObject private var triggers: ScriptTriggerCoordinator

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Also used to find the window again when the app is reopened from the
    /// Dock after its window was closed.
    static let mainWindowTitle = "Gruppen"

    init() {
        // The panels need the engine and the store, so they are built here and
        // handed to a coordinator that owns their lifetime.
        let store = GroupStore()
        _store = StateObject(wrappedValue: store)
        let stash = StashCoordinator(store: store)
        _stash = StateObject(wrappedValue: stash)

        // The script library is global: it belongs to the app, not to a Gruppe.
        let scripts = ScriptLibrary()
        let triggers = ScriptTriggerCoordinator(library: scripts)
        _scripts = StateObject(wrappedValue: scripts)
        _triggers = StateObject(wrappedValue: triggers)
    }

    private func applyStashSetting() {
        settings.stashEnabled ? stash.enable() : stash.disable()
    }

    var body: some Scene {
        Window(Self.mainWindowTitle, id: WindowID.main) {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(navigation)
                .environmentObject(stash)
                .environmentObject(monitor)
                .environmentObject(scripts)
                .environmentObject(triggers)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    settings.applyActivationPolicy()
                    applyStashSetting()
                    MemoryRelief.install()
                    // Arms whatever the library already had active. Nothing runs
                    // until one of those events actually fires.
                    triggers.rearm()
                    AppDelegate.willTerminate = {
                        stash.disable()
                        triggers.disarm()
                    }
                }
                .onChange(of: settings.stashEnabled) { _ in applyStashSetting() }
        }
        .defaultSize(width: 1040, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Gruppe") { _ = store.addGroup() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Konfiguration…") { navigation.select(.settings) }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .sidebar) {
                Button(navigation.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") {
                    navigation.toggleSidebar()
                }
                .keyboardShortcut("\\")

            }
        }

        MenuBarExtra(isInserted: Binding(
            get: { settings.showMenuBar },
            set: { if $0 != settings.showMenuBar { settings.showMenuBar = $0 } }
        )) {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(navigation)
                .environmentObject(stash)
                .environmentObject(settings)
                .environmentObject(monitor)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
    }
}

// MARK: - Menu bar

private struct MenuBarContent: View {
    @EnvironmentObject private var store: GroupStore
    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var stash: StashCoordinator
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var monitor: PerformanceMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if settings.showPerformanceMonitor {
            // A bare Text in a menu still highlights on hover even though it
            // does nothing. A Section header is inert by construction.
            Section { EmptyView() } header: { PerformanceReadout() }
            Divider()
        }

        if store.groups.isEmpty {
            Text("No Gruppen yet")
        } else {
            ForEach(store.groups) { group in
                Button {
                    store.toggle(group)
                } label: {
                    Text("\(store.primaryAction(for: group).label) \(group.name)")
                }
                .disabled(group.apps.isEmpty)
            }
        }

        Divider()
        Button("Open Gruppen") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
        }
        Button("Konfiguration…") {
            navigation.select(.settings)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.main)
        }
        Divider()
        Button("Quit Gruppen") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

}

/// The CPU/RAM line in the menu bar dropdown.
///
/// The figure is read *as this line is built*, which is the only way it is ever
/// current: while an `NSMenu` is tracking the mouse, SwiftUI does not reliably
/// run an update pass, so a readout waiting on a `@Published` sample showed its
/// placeholder and nothing else, forever. Building the string from a live
/// reading means the menu always opens on a real number. `onAppear` still leases
/// the timer, so the line also ticks over if an update does get through.
private struct PerformanceReadout: View {
    @EnvironmentObject private var monitor: PerformanceMonitor

    var body: some View {
        Text(text)
            .onAppear { monitor.begin() }
            .onDisappear { monitor.end() }
    }

    private var text: String {
        let sample = monitor.reading()
        return "CPU \(sample.cpuDescription)   RAM \(sample.memoryDescription)   \(sample.threadCount) threads"
    }
}
