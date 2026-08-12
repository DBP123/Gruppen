import AppKit
import SwiftUI

@main
struct GruppenApp: App {
    @StateObject private var store: GroupStore
    @StateObject private var stash: StashCoordinator
        @StateObject private var settings = AppSettings.shared
    @StateObject private var navigation = NavigationModel()
    @StateObject private var widgets = WidgetManager.shared
    @StateObject private var scripts: ScriptLibrary
    @StateObject private var triggers: ScriptTriggerCoordinator
    @StateObject private var metrics: MetricLibrary
    @StateObject private var collector: MetricsCollector
    @StateObject private var metricStore: MetricStoreBox

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

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

        // Metrics: definitions in JSON, captured rows in SQLite.
        let metrics = MetricLibrary()
        let metricStore = MetricStore()
        _metrics = StateObject(wrappedValue: metrics)
        _metricStore = StateObject(wrappedValue: MetricStoreBox(metricStore))
        _collector = StateObject(wrappedValue: MetricsCollector(library: metrics, store: metricStore))
    }

    private func applyStashSetting() {
        settings.stashEnabled ? stash.enable() : stash.disable()
    }

    var body: some Scene {
        Window(WindowID.mainWindowTitle, id: WindowID.main) {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(navigation)
                .environmentObject(stash)
                .environmentObject(widgets)
                .environmentObject(scripts)
                .environmentObject(triggers)
                .environmentObject(metrics)
                .environmentObject(collector)
                .environmentObject(metricStore)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    settings.applyActivationPolicy()
                    applyStashSetting()
                    MemoryRelief.install()
                    // Arms whatever the library already had active. Nothing runs
                    // until one of those events actually fires.
                    triggers.rearm()
                    collector.rearm()
                    // The menu bar is `NSStatusItem`s rather than a
                    // `MenuBarExtra`, because that scene type owns exactly one
                    // item and the point is to have several. It lives outside
                    // the scene graph, so it is handed what its panel needs.
                    MenuBarManager.shared.attach(store: store,
                                                 navigation: navigation,
                                                 settings: settings)
                    AppDelegate.willTerminate = {
                        stash.disable()
                        triggers.disarm()
                        collector.disarm()
                        widgets.shutdown()
                        MenuBarManager.shared.shutdown()
                    }
                }
                .onChange(of: settings.stashEnabled) { _ in applyStashSetting() }
                .onChange(of: settings.showMenuBar) { _ in MenuBarManager.shared.reconcile() }
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

    }
}

// The menu bar dropdown lives in `Sources/Pages/Telemetry/MonitorPanel.swift`.
// It replaced an `NSMenu` full of `Section` headers, and with it the old
// `PerformanceMonitor` — its three figures are now the `.footprint` module,
// on the same demand-driven footing as everything else in the panel.
