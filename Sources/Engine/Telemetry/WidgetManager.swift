import Foundation

/// Owns every telemetry module's lifetime.
///
/// Nothing else starts or stops a module. The manager is told three things —
/// which modules the user has armed at all, where each one is wanted, and
/// whether the dropdown is open — and derives everything from those.
///
/// A module runs when its telemetry is enabled **and** something is looking at
/// it. That gives three switches per module, which is what the telemetry settings
/// puts in front of the user:
///
/// | telemetry | in dropdown | pinned | dropdown open | module           |
/// |-----------|-------------|--------|---------------|------------------|
/// | off       | –           | –      | –             | does not exist   |
/// | on        | yes         | –      | yes           | alive at 2 Hz    |
/// | on        | –           | yes    | no            | alive at 0.5 Hz  |
/// | on        | no          | no     | –             | does not exist   |
///
/// "Does not exist" is meant literally: the timer is cancelled, the sampler is
/// told to close whatever kernel objects it holds, and the object is released.
@MainActor
final class WidgetManager: ObservableObject {
    /// The menu bar items and the panel both live outside the scene graph's
    /// reach, so both find the manager here.
    static let shared = WidgetManager()

    /// Modules whose sampling is armed at all. The outer switch.
    @Published private(set) var telemetryEnabled: Set<WidgetKind>
    /// Modules stacked in the dropdown.
    @Published private(set) var panelVisible: Set<WidgetKind>
    /// Modules carrying their own standalone item in the menu bar.
    @Published private(set) var menuBarPinned: Set<WidgetKind>
    /// How each pinned module draws its item. Only holds the ones the user has
    /// actually chosen; everything else falls back to the module's default.
    @Published private(set) var menuBarModes: [WidgetKind: MenuBarDisplayMode]
    @Published private(set) var isPanelOpen = false

    /// Instantiated modules — and *only* the instantiated ones. A kind missing
    /// from here is a kind costing nothing.
    private var modules: [WidgetKind: any GruppenWidget] = [:]
    private var settingsObserver: NSObjectProtocol?

    /// Called after every reconcile so the menu bar can add or drop items.
    var onModulesChanged: (() -> Void)?

    private enum Keys {
        static let telemetry = "monitorArmedWidgets"
        static let panel = "monitorEnabledWidgets"
        static let pinned = "monitorPinnedWidgets"
        static let modes = "monitorMenuBarModes"
    }

    private let defaults = UserDefaults.standard

    init() {
        let store = defaults
        func stored(_ key: String) -> Set<WidgetKind>? {
            store.stringArray(forKey: key).map { Set($0.compactMap(WidgetKind.init(rawValue:))) }
        }
        // First run: everything armed and in the dropdown except the process
        // table, which is the one module that makes the dropdown tall. Nothing
        // is pinned — a standalone menu bar item is a deliberate choice.
        let initial = Set(WidgetKind.configurable.filter { $0 != .processes })
        telemetryEnabled = stored(Keys.telemetry) ?? Set(WidgetKind.configurable)
        panelVisible = stored(Keys.panel) ?? initial
        menuBarPinned = stored(Keys.pinned) ?? []

        let rawModes = store.dictionary(forKey: Keys.modes) as? [String: String] ?? [:]
        menuBarModes = Dictionary(uniqueKeysWithValues: rawModes.compactMap {
            (key, value) -> (WidgetKind, MenuBarDisplayMode)? in
            guard let kind = WidgetKind(rawValue: key),
                  let mode = MenuBarDisplayMode(rawValue: value) else { return nil }
            return (kind, mode)
        })

        // The master switch lives in `AppSettings` with the rest of the
        // preferences. It posts on change, so this needs no polling and no
        // Combine sink.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// The one switch that turns the whole monitor off.
    private var monitorEnabled: Bool { AppSettings.shared.showPerformanceMonitor }

    /// Modules to stack in the panel, in a fixed order so the dropdown never
    /// rearranges itself between openings.
    var panelOrder: [WidgetKind] {
        guard monitorEnabled else { return [] }
        return WidgetKind.configurable.filter { telemetryEnabled.contains($0) && panelVisible.contains($0) }
    }

    /// Modules to lay out on the dashboard, in a fixed order.
    ///
    /// Every *armed* module, not the dropdown's subset. The two surfaces answer
    /// different questions: the dropdown is a glance and has to stay short, so it
    /// carries a chosen few; the dashboard is the page you open to look at the
    /// machine, so it carries everything you have switched on. Tying it to the
    /// dropdown's set instead would have left the new landing page blank for
    /// anyone who had trimmed that list.
    ///
    /// Gruppen's own footprint is excluded: it already has a line at the foot of
    /// the dropdown, and it is not a hardware module.
    var dashboardOrder: [WidgetKind] {
        guard monitorEnabled else { return [] }
        return WidgetKind.configurable.filter { telemetryEnabled.contains($0) }
    }

    /// Modules with their own menu bar item, left to right.
    var pinnedOrder: [WidgetKind] {
        guard monitorEnabled else { return [] }
        return WidgetKind.configurable.filter {
            $0.isPinnable && telemetryEnabled.contains($0) && menuBarPinned.contains($0)
        }
    }

    // MARK: Demand

    /// Modules whose own popover is open right now.
    ///
    /// Separate from `isPanelOpen`, because each standalone menu bar item has
    /// its own popover showing only its own module. Opening one raises exactly
    /// that module to the interactive rate and leaves every other module where
    /// it was.
    @Published private(set) var openDetails: Set<WidgetKind> = []

    func detailDidOpen(_ kind: WidgetKind) {
        guard !openDetails.contains(kind) else { return }
        openDetails.insert(kind)
        reconcile()
    }

    func detailDidClose(_ kind: WidgetKind) {
        guard openDetails.contains(kind) else { return }
        openDetails.remove(kind)
        reconcile()
    }

    /// Brings the modules in line with the stored preferences.
    ///
    /// Called once at launch. Without it a module pinned to the menu bar has an
    /// item but no sampler behind it until something else — opening the panel,
    /// touching a switch — happens to reconcile, and until then the item sits on
    /// a dash for however long the app is left alone.
    func start() { reconcile() }

    func panelDidOpen() {
        guard !isPanelOpen else { return }
        isPanelOpen = true
        reconcile()
    }

    func panelDidClose() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        reconcile()
    }

    /// Whether the dashboard page is on screen *and* the window showing it is
    /// actually visible.
    ///
    /// The third demand source, alongside the dropdown and the menu bar pins,
    /// and it obeys the same rule as both: it does not throttle the modules, it
    /// decides whether they exist. Navigating to Stash or minimising the window
    /// tears every dashboard module down — timer cancelled, SMC connection
    /// closed, IORegistry handles released — and coming back builds them again.
    /// A suspended timer would still be a timer.
    @Published private(set) var isDashboardVisible = false

    /// Dashboard cards the user has frozen.
    ///
    /// A frozen card holds the figures it had when you froze it and stops being
    /// a reason for its module to run. Deliberately not persisted: a snapshot of
    /// what the machine was doing before the app last quit is not information,
    /// it is a stale number that looks live.
    ///
    /// Freezing removes *this surface's* demand, not everyone's. A module that
    /// is also pinned to the menu bar keeps sampling for the item you asked for,
    /// which is why the card renders a captured image rather than trusting the
    /// module to stand still.
    @Published private(set) var frozen: Set<WidgetKind> = []

    func isFrozen(_ kind: WidgetKind) -> Bool { frozen.contains(kind) }

    func setFrozen(_ kind: WidgetKind, _ on: Bool) {
        guard frozen.contains(kind) != on else { return }
        if on { frozen.insert(kind) } else { frozen.remove(kind) }
        reconcile()
    }

    func thawAll() {
        guard !frozen.isEmpty else { return }
        frozen.removeAll()
        reconcile()
    }

    /// Whether Gruppen is the app you are actually using.
    ///
    /// A second tier below visibility, and it exists because occlusion is
    /// all-or-nothing: macOS only reports a window occluded when it is
    /// *entirely* covered, so a browser that leaves a strip of the dashboard
    /// showing keeps it at full rate. That is the usual shape of "hidden behind
    /// something", and it was most of the drain.
    ///
    /// Partly visible is not nothing — figures may still be on screen — so this
    /// slows the board to the menu bar's rate rather than stopping it. Fully
    /// hidden still stops it dead.
    @Published private(set) var isDashboardFocused = true

    func dashboardDidChangeFocus(_ focused: Bool) {
        guard isDashboardFocused != focused else { return }
        isDashboardFocused = focused
        guard isDashboardVisible else { return }
        reconcile()
    }

    func dashboardDidAppear() {
        guard !isDashboardVisible else { return }
        isDashboardVisible = true
        reconcile()
    }

    func dashboardDidDisappear() {
        guard isDashboardVisible else { return }
        isDashboardVisible = false
        reconcile()
    }

    func isArmed(_ kind: WidgetKind) -> Bool { telemetryEnabled.contains(kind) }
    func isInPanel(_ kind: WidgetKind) -> Bool { panelVisible.contains(kind) }
    func isPinned(_ kind: WidgetKind) -> Bool { menuBarPinned.contains(kind) }

    /// The outer switch. Turning telemetry off for a module leaves its other two
    /// preferences alone — turning it back on restores where it was showing,
    /// which is what someone toggling a module off for an afternoon expects.
    func setArmed(_ kind: WidgetKind, _ on: Bool) {
        guard kind.isConfigurable else { return }
        telemetryEnabled = updated(telemetryEnabled, kind, on, Keys.telemetry)
        reconcile()
    }

    func setInPanel(_ kind: WidgetKind, _ on: Bool) {
        guard kind.isConfigurable else { return }
        panelVisible = updated(panelVisible, kind, on, Keys.panel)
        reconcile()
    }

    func setPinned(_ kind: WidgetKind, _ on: Bool) {
        guard kind.isPinnable else { return }
        menuBarPinned = updated(menuBarPinned, kind, on, Keys.pinned)
        reconcile()
    }

    /// How a pinned module draws its menu bar item.
    func mode(for kind: WidgetKind) -> MenuBarDisplayMode {
        menuBarModes[kind] ?? kind.defaultMenuBarMode
    }

    /// Changing this rebuilds the item's contents and its fixed width, and
    /// nothing else — the module underneath is untouched, still sampling at the
    /// same rate it was.
    func setMode(_ newMode: MenuBarDisplayMode, for kind: WidgetKind) {
        guard kind.isPinnable, mode(for: kind) != newMode else { return }
        var result = menuBarModes
        result[kind] = newMode
        menuBarModes = result
        defaults.set(Dictionary(uniqueKeysWithValues: result.map { ($0.key.rawValue, $0.value.rawValue) }),
                     forKey: Keys.modes)
        onModulesChanged?()
    }

    /// Returns the new set and writes it out. Deliberately *not* an `inout`
    /// helper that also reconciles: `@Published` is a property wrapper, so an
    /// inout access is a get-modify-set around a temporary, and calling
    /// `reconcile()` from inside one had it read the value from before the
    /// change every single time. Every switch appeared to do nothing.
    private func updated(_ set: Set<WidgetKind>, _ kind: WidgetKind,
                         _ on: Bool, _ key: String) -> Set<WidgetKind> {
        var result = set
        if on { result.insert(kind) } else { result.remove(kind) }
        defaults.set(result.map(\.rawValue).sorted(), forKey: key)
        return result
    }

    /// The typed module, if it currently exists. Views ask for what they need
    /// and render nothing when the answer is nil, which is the honest thing to
    /// show in the frame before the first reading lands.
    func module<T: GruppenWidget>(_ type: T.Type, _ kind: WidgetKind) -> T? {
        modules[kind] as? T
    }

    /// Calls back whenever a live module publishes, with everything a menu bar
    /// item could draw. Replaces any previous observer.
    func observe(_ kind: WidgetKind, _ handler: @escaping (MenuBarSample) -> Void) {
        guard let module = modules[kind] else { return }
        module.onPublish = { [weak module] in
            guard let sample = module?.menuBarSample else { return }
            handler(sample)
        }
    }

    /// The current reading, for an item that has just been created and has no
    /// reason to sit on a dash until the next tick.
    func currentSample(_ kind: WidgetKind) -> MenuBarSample? {
        modules[kind]?.menuBarSample
    }

    /// Whether a module is alive right now. Exists for the test harness, which
    /// asserts that closing the dropdown really does tear everything down.
    func isRunning(_ kind: WidgetKind) -> Bool { modules[kind] != nil }

    var runningCount: Int { modules.count }

    // MARK: Lifecycle

    private func reconcile() {
        let pinned = pinnedOrder
        let inPanel = panelOrder
        let onDashboardList = dashboardOrder

        for kind in WidgetKind.allCases {
            let inSharedPanel = isPanelOpen && (kind == .footprint ? monitorEnabled : inPanel.contains(kind))
            // Must agree with `dashboardOrder` exactly: a module built here but
            // not laid out there is a sampler running with nothing drawing it.
            // A frozen card is showing a captured image, so it wants nothing
            // from the module behind it.
            let onDashboard = isDashboardVisible && onDashboardList.contains(kind)
                && !frozen.contains(kind)
            // A module's own popover is as good a reason to be live as the
            // shared panel, and it is the only reason for modules the user has
            // taken out of that panel entirely.
            let inOwnPopover = monitorEnabled && telemetryEnabled.contains(kind) && openDetails.contains(kind)
            let panelActive = inSharedPanel || inOwnPopover || onDashboard
            let barPinned = pinned.contains(kind)

            guard panelActive || barPinned else {
                modules.removeValue(forKey: kind)?.stopFetching()
                continue
            }

            let module = modules[kind] ?? make(kind)
            modules[kind] = module
            module.isPanelActive = panelActive
            module.isMenuBarPinned = barPinned
            // Open dropdown wins: a pinned module the user is looking at should
            // move at the speed they are looking at it.
            // Fastest live surface wins. The dropdown and a module's own popover
            // are glances, so they get 2 Hz; the dashboard is a page you leave
            // open, so on its own it gets 1 Hz.
            let rate: TimeInterval
            if inSharedPanel || inOwnPopover { rate = Telemetry.panelRate }
            else if onDashboard { rate = isDashboardFocused ? Telemetry.dashboardRate
                                                            : Telemetry.pinnedRate }
            else { rate = Telemetry.pinnedRate }
            module.startFetching(rate: rate)
        }
        objectWillChange.send()
        onModulesChanged?()
    }

    private func make(_ kind: WidgetKind) -> any GruppenWidget {
        switch kind {
        case .cpu: return CPUTelemetryWidget()
        case .silicon: return SiliconTelemetryWidget()
        case .memory: return MemoryTelemetryWidget()
        case .network: return NetworkTelemetryWidget()
        case .thermal: return ThermalTelemetryWidget()
        case .power: return PowerTelemetryWidget()
        case .storage: return StorageTelemetryWidget()
        case .processes: return ProcessTelemetryWidget()
        case .footprint: return FootprintTelemetryWidget()
        }
    }

    /// Tears everything down. Called when the app is quitting, and by the test
    /// harness between cases.
    func shutdown() {
        isPanelOpen = false
        isDashboardVisible = false
        openDetails.removeAll()
        for (_, module) in modules { module.stopFetching() }
        modules.removeAll()
        onModulesChanged?()
    }
}
