import Foundation

/// Owns every telemetry module's lifetime.
///
/// Nothing else starts or stops a module. The manager is told three things —
/// which modules the user has armed at all, where each one is wanted, and
/// whether the dropdown is open — and derives everything from those.
///
/// A module runs when its telemetry is enabled **and** something is looking at
/// it. That gives three switches per module, which is what the Guardrails page
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

    /// Modules with their own menu bar item, left to right.
    var pinnedOrder: [WidgetKind] {
        guard monitorEnabled else { return [] }
        return WidgetKind.configurable.filter {
            $0.isPinnable && telemetryEnabled.contains($0) && menuBarPinned.contains($0)
        }
    }

    // MARK: Demand

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

    /// Calls back whenever a live module publishes, with the one-liner and the
    /// figure a menu bar item shows. Replaces any previous observer.
    func observe(_ kind: WidgetKind, _ handler: @escaping (String, Double?) -> Void) {
        guard let module = modules[kind] else { return }
        module.onPublish = { [weak module] in
            guard let module, let summary = module.pinnedSummary else { return }
            handler(summary, module.pinnedValue)
        }
    }

    /// The current one-liner, for an item that has just been created and has no
    /// reason to sit on a dash until the next tick.
    func currentSummary(_ kind: WidgetKind) -> (String, Double?)? {
        guard let module = modules[kind], let summary = module.pinnedSummary else { return nil }
        return (summary, module.pinnedValue)
    }

    /// Whether a module is alive right now. Exists for the test harness, which
    /// asserts that closing the dropdown really does tear everything down.
    func isRunning(_ kind: WidgetKind) -> Bool { modules[kind] != nil }

    var runningCount: Int { modules.count }

    // MARK: Lifecycle

    private func reconcile() {
        let pinned = pinnedOrder
        let inPanel = panelOrder

        for kind in WidgetKind.allCases {
            let panelActive = isPanelOpen && (kind == .footprint ? monitorEnabled : inPanel.contains(kind))
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
            module.startFetching(rate: panelActive ? Telemetry.panelRate : Telemetry.pinnedRate)
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
        case .processes: return ProcessTelemetryWidget()
        case .footprint: return FootprintTelemetryWidget()
        }
    }

    /// Tears everything down. Called when the app is quitting, and by the test
    /// harness between cases.
    func shutdown() {
        isPanelOpen = false
        for (_, module) in modules { module.stopFetching() }
        modules.removeAll()
        onModulesChanged?()
    }
}
