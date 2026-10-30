import AppKit
import SwiftUI

@main
struct GruppenApp: App {
    @StateObject private var store: GroupStore
    @StateObject private var stash: StashCoordinator
    @StateObject private var settings = AppSettings.shared
    @StateObject private var navigation = NavigationModel()
    @StateObject private var widgets = WidgetManager.shared
    @StateObject private var flows: FlowLibrary
    @StateObject private var engine: FlowEngine
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

        // Flows are global: they belong to the app, not to a Gruppe.
        let flows = FlowLibrary()
        let engine = FlowEngine(library: flows)
        _flows = StateObject(wrappedValue: flows)
        _engine = StateObject(wrappedValue: engine)
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
                .environmentObject(flows)
                .environmentObject(engine)
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
                    // Arms whatever flows are already switched on. Nothing runs
                    // until one of those events actually fires.
                    engine.triggers.rearm()
                    // Captured by name first: these are wrapper properties of
                    // this struct, and a `[weak]` list on a struct property
                    // captures the struct strongly and the object weakly —
                    // which the compiler rightly flags as two different
                    // answers about the same value.
                    let flowEngine = engine
                    let groups = store
                    let spaces = workspaces
                    // A profile's last stage runs a flow through the engine,
                    // so it gets the same history and policies as any run.
                    workspaces.flowRunner = { [weak flowEngine] id in
                        flowEngine?.run(id, source: "Workspace") != nil
                    }
                    QuickPalette.shared.attach(engine: engine)
                    FlowEditorWindows.shared.attach(library: flows, engine: engine, store: store,
                                                    workspaces: workspaces, settings: settings)
                    // The Gruppe and workspace blocks reach the two objects
                    // that own those, through here rather than a singleton.
                    engine.hooks.launchGroup = { [weak groups] id in
                        guard let groups, let group = groups.groups.first(where: { $0.id == id }) else { return false }
                        groups.launchGroup(group)
                        return true
                    }
                    engine.hooks.closeGroup = { [weak groups] id in
                        guard let groups, let group = groups.groups.first(where: { $0.id == id }) else { return false }
                        groups.terminateGroup(group)
                        return true
                    }
                    engine.hooks.activateWorkspace = { [weak spaces] id in
                        guard let spaces, let profile = spaces.profiles.first(where: { $0.id == id }) else { return false }
                        spaces.activate(profile)
                        return true
                    }
                    AppDelegate.openURL = { [weak flowEngine] url in flowEngine?.open(url) }
                    // The menu bar is `NSStatusItem`s rather than a
                    // `MenuBarExtra`, because that scene type owns exactly one
                    // item and the point is to have several. It lives outside
                    // the scene graph, so it is handed what its panel needs.
                    MenuBarManager.shared.attach(store: store,
                                                 navigation: navigation,
                                                 settings: settings,
                                                 flows: flows,
                                                 engine: engine)
                    AppDelegate.willTerminate = {
                        stash.disable()
                        flows.saveNow()
                        engine.triggers.disarm()
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
