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
    @StateObject private var workspaces = WorkspaceEngine()
    @StateObject private var hardware = HardwareProfileStore.shared

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
                .environmentObject(workspaces)
                .environmentObject(hardware)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    settings.applyActivationPolicy()
                    applyStashSetting()
                    // Profiles the Mac on a background queue. Returns straight
                    // away: the cached profile was already loaded synchronously
                    // in the store's `init`, so the first frame has real numbers
                    // and this only replaces them.
                    hardware.refreshOnLaunch()
                    MemoryRelief.install()
                    // Arms whatever the library already had active. Nothing runs
                    // until one of those events actually fires.
                    triggers.rearm()
                    // A profile's script stage runs through the script
                    // coordinator rather than a runner of its own, so it gets
                    // the same transcript, feedback and argv handling as a
                    // script fired by any other trigger.
                    // Captured by name first: `scripts` and `triggers` are
                    // wrapper properties of this struct, and a `[weak]` list
                    // on a struct property captures the struct strongly and
                    // the object weakly — which the compiler rightly flags as
                    // two different answers about the same value.
                    let library = scripts
                    let coordinator = triggers
                    let groups = store
                    let engine = workspaces
                    workspaces.scriptRunner = { [weak library, weak coordinator] id in
                        guard let script = library?.scripts.first(where: { $0.id == id }) else { return false }
                        coordinator?.run(script, paths: [], source: "Workspace")
                        return true
                    }
                    QuickPalette.shared.attach(library: scripts, triggers: triggers)
                    // The Gruppe and workspace steps reach the two objects
                    // that own those, through here rather than a singleton.
                    triggers.hooks = ScriptRunner.Hooks(
                        launchGroup: { [weak groups] id in
                            guard let groups, let group = groups.groups.first(where: { $0.id == id }) else { return false }
                            groups.launchGroup(group)
                            return true
                        },
                        activateWorkspace: { [weak engine] id in
                            guard let engine, let profile = engine.profiles.first(where: { $0.id == id }) else { return false }
                            engine.activate(profile)
                            return true
                        }
                    )
                    // The menu bar is `NSStatusItem`s rather than a
                    // `MenuBarExtra`, because that scene type owns exactly one
                    // item and the point is to have several. It lives outside
                    // the scene graph, so it is handed what its panel needs.
                    MenuBarManager.shared.attach(store: store,
                                                 navigation: navigation,
                                                 settings: settings,
                                                 scripts: scripts,
                                                 triggers: triggers)
                    AppDelegate.willTerminate = {
                        stash.disable()
                        triggers.disarm()
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
