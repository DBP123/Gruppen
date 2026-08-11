import AppKit
import Combine
import Foundation

/// Owns the groups, persists them to disk, and drives activation.
@MainActor
final class GroupStore: ObservableObject {
    @Published var groups: [AppGroup] = [] {
        didSet {
            guard !isLoading else { return }
            save()
            syncHotkeys()
            updateSuggestions()
            updateCounters()
        }
    }

    /// Ids of the apps we currently believe are running.
    ///
    /// Kept fresh by a poll rather than by workspace notifications alone:
    /// `NSWorkspace` does not post launch/terminate notifications for
    /// `LSUIElement` menu-bar apps, which is most of what ends up in a group,
    /// so notifications on their own leave the indicators stale.
    @Published private(set) var runningIDs: Set<AppEntry.ID> = []

    /// Aggregates the status bar reads. Maintained when the data changes
    /// rather than recomputed inside a view body on every render.
    @Published private(set) var activeCount = 0
    @Published private(set) var runningTotal = 0

    /// Give apps this long to quit on their own before we kill them.
    @Published var gracePeriod: TimeInterval = GroupStore.storedGracePeriod {
        didSet {
            guard gracePeriod != oldValue else { return }
            UserDefaults.standard.set(gracePeriod, forKey: "gracePeriod")
        }
    }

    /// Groups whose shortcut the system refused to hand over (already claimed
    /// by macOS or another app). The badge renders these as unavailable.
    @Published private(set) var unavailableShortcuts: Set<UUID> = []

    /// Preset rules that match what is installed. Computed once at launch and
    /// again only when the user asks for a rescan — never polled.
    @Published private(set) var suggestions: [Presets.Match] = []

    /// Result of the last application index pass, shown in Konfiguration.
    @Published private(set) var indexReport: IndexReport?

    struct IndexReport: Equatable {
        var appCount: Int
        var repairedPaths: Int
        var scannedAt: Date

        var summary: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            var text = "Indexed \(appCount) apps • Last scanned \(formatter.string(from: scannedAt))"
            if repairedPaths > 0 { text += " • \(repairedPaths) path(s) repaired" }
            return text
        }
    }

    /// Reads the saved grace period, pulling it across from the app's former
    /// bundle identifier the first time.
    static var storedGracePeriod: TimeInterval {
        if let current = UserDefaults.standard.object(forKey: "gracePeriod") as? TimeInterval {
            return current
        }
        if let legacy = UserDefaults(suiteName: "com.dhilanpatel.autolaunch")?
            .object(forKey: "gracePeriod") as? TimeInterval {
            UserDefaults.standard.set(legacy, forKey: "gracePeriod")
            return legacy
        }
        return 0
    }

    private var isLoading = false
    private var hotkeySignature: [UUID: Shortcut] = [:]
    private var settleTask: Task<Void, Never>?
    private var hotkeysSuspended = false
    /// Group id -> token for a force quit that is waiting out its grace
    /// period. Reactivating a group clears its token, which cancels the kill.
    private var pendingKills: [UUID: Set<UUID>] = [:]
    /// In-flight sequenced launch/termination, one per Gruppe. Cancelled when
    /// the opposite action is requested so the two can never interleave.
    private var sequenceTasks: [UUID: Task<Void, Never>] = [:]
    /// Preset rules resolved against the disk. Refreshed at launch and on an
    /// explicit rescan only.
    private var cachedMatches: [Presets.Match] = []
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    /// Running state comes from here now — no timer, no process-list walk on a
    /// schedule. See `RunningAppTracker` for why and for the one caveat.
    let tracker = RunningAppTracker()

    private let fileURL: URL

    /// The real store location. Note that this does *not* follow `$HOME` —
    /// tests must pass an explicit `fileURL` to stay off the live data.
    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Gruppen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("groups.json")

        // Carry over data written under the app's former name.
        let legacy = support.appendingPathComponent("AutoLaunch/groups.json")
        if !FileManager.default.fileExists(atPath: url.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: url)
            log("migrated groups from AutoLaunch -> Gruppen")
        }
        return url
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
        Self.log("STORE INIT — \(groups.count) group(s), active: \(groups.filter(\.isActive).map(\.name))")
        refreshRunning()
        syncHotkeys()
        cachedMatches = Presets.matches()
        updateSuggestions()

        // The tracker publishes on system events; mirror it into runningIDs.
        observers.append(NotificationCenter.default.addObserver(
            forName: RunningAppTracker.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver(_:))
    }

    /// Appends a line to `~/Library/Logs/Gruppen.log`. Every launch and
    /// every kill goes through here, so the log is the record of who closed
    /// what and when.
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] pid \(ProcessInfo.processInfo.processIdentifier) \(message)\n"
        NSLog("Gruppen: %@", message)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Gruppen.log")
        guard let data = line.data(using: .utf8) else { return }
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Re-reads the system after *we* launched or closed something.
    ///
    /// Two reasons a single immediate refresh is not enough. Apps take a moment
    /// to appear or disappear, so reading straight away sees the old world; and
    /// `LSUIElement` menu-bar apps send no launch/terminate notifications at
    /// all, so nothing else will tell us later. This fires a short, bounded
    /// burst — five reads tapering out over three seconds — and then stops. It
    /// is started by an action, so an idle Gruppen still runs nothing.
    func settle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            for gap in [0.15, 0.25, 0.5, 0.9, 1.2] {
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.tracker.refresh()
                self.refreshRunning()
            }
            self?.settleTask = nil
        }
    }

    /// Recomputes which apps are running from the tracker's snapshot.
    ///
    /// No process-list walk and no allocation per app: the tracker already
    /// holds the sets, so this is a membership test per entry.
    func refreshRunning() {
        var ids: Set<AppEntry.ID> = []
        for group in groups {
            for app in group.apps where !ids.contains(app.id) {
                if tracker.isRunning(app) { ids.insert(app.id) }
            }
        }
        if ids != runningIDs { runningIDs = ids }
        updateCounters()
    }

    /// `runningIDs` is already deduplicated across Gruppen, so its count is the
    /// process total — no second pass needed.
    private func updateCounters() {
        let active = groups.reduce(into: 0) { $0 += $1.isActive ? 1 : 0 }
        if active != activeCount { activeCount = active }
        if runningIDs.count != runningTotal { runningTotal = runningIDs.count }
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AppGroup].self, from: data) else { return }
        groups = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(groups) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Editing

    func addGroup(named name: String = "New Group") -> AppGroup {
        let group = AppGroup(name: uniqueName(from: name))
        groups.append(group)
        return group
    }

    func delete(_ group: AppGroup) {
        groups.removeAll { $0.id == group.id }
    }

    func duplicate(_ group: AppGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var copy = group
        copy.id = UUID()
        copy.name = uniqueName(from: group.name + " Copy")
        copy.isActive = false
        groups.insert(copy, at: index + 1)
    }

    func rename(_ group: AppGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: group) else { return }
        groups[index].name = trimmed
    }

    /// Adds apps to a group, skipping anything already in it.
    func add(urls: [URL], to group: AppGroup) {
        guard let index = index(of: group) else { return }
        let existing = Set(groups[index].apps.map(\.id))
        let new = urls.compactMap(AppEntry.init(url:)).filter { !existing.contains($0.id) }
        guard !new.isEmpty else { return }
        groups[index].apps.append(contentsOf: new)
        if !groups[index].isSequenced {
            groups[index].apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        refreshRunning()
    }

    func setColor(_ hex: String, for group: AppGroup) {
        guard let index = index(of: group) else { return }
        guard groups[index].colorHex != hex else { return }
        groups[index].colorHex = hex
    }

    func setSequenced(_ sequenced: Bool, for group: AppGroup) {
        guard let index = index(of: group) else { return }
        groups[index].isSequenced = sequenced
    }

    func setSequenceDelay(_ delay: TimeInterval, for group: AppGroup) {
        guard let index = index(of: group) else { return }
        let clamped = min(max(delay, 0), 3)
        guard groups[index].sequenceDelay != clamped else { return }
        groups[index].sequenceDelay = clamped
    }


    /// Reorders the execution sequence.
    func moveApps(in group: AppGroup, from source: IndexSet, to destination: Int) {
        guard let index = index(of: group) else { return }
        groups[index].apps.move(fromOffsets: source, toOffset: destination)
    }

    /// Binds a recorded combination to this group. A combination can only
    /// drive one Gruppe, so it is taken off any group already holding it.
    func setShortcut(_ shortcut: Shortcut?, for group: AppGroup) {
        guard let index = index(of: group) else { return }
        if let shortcut {
            for other in groups.indices where other != index && groups[other].shortcut == shortcut {
                groups[other].shortcut = nil
            }
        }
        groups[index].shortcut = shortcut
    }

    /// Releases every hotkey while the recorder is listening, so pressing a
    /// combination that is already bound records it instead of firing it.
    func suspendHotkeys() {
        hotkeysSuspended = true
        HotkeyCenter.shared.unregisterAll(owner: "gruppen")
        hotkeySignature = [:]
    }

    func resumeHotkeys() {
        hotkeysSuspended = false
        syncHotkeys()
    }

    /// Re-registers global hotkeys, but only when the bindings actually
    /// changed — `groups` publishes on every keystroke of a rename.
    func syncHotkeys() {
        guard !hotkeysSuspended else { return }
        let signature = Dictionary(uniqueKeysWithValues: groups.compactMap { group in
            group.shortcut.map { (group.id, $0) }
        })
        guard signature != hotkeySignature else { return }
        hotkeySignature = signature

        HotkeyCenter.shared.unregisterAll(owner: "gruppen")
        var unavailable: Set<UUID> = []
        for group in groups {
            guard let shortcut = group.shortcut else { continue }
            let groupID = group.id
            let claimed = HotkeyCenter.shared.register(shortcut, owner: "gruppen") { [weak self] in
                Task { @MainActor in
                    guard let self, let live = self.groups.first(where: { $0.id == groupID }) else { return }
                    Self.log("HOTKEY \(shortcut.display) -> \"\(live.name)\"")
                    self.toggle(live)
                }
            }
            if !claimed {
                unavailable.insert(groupID)
                Self.log("shortcut \(shortcut.display) unavailable for \"\(group.name)\"")
            }
        }
        unavailableShortcuts = unavailable
    }

    func remove(_ apps: Set<AppEntry.ID>, from group: AppGroup) {
        guard let index = index(of: group) else { return }
        groups[index].apps.removeAll { apps.contains($0.id) }
    }

    private func index(of group: AppGroup) -> Int? {
        groups.firstIndex { $0.id == group.id }
    }

    private func uniqueName(from name: String) -> String {
        var candidate = name
        var counter = 2
        while groups.contains(where: { $0.name == candidate }) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Activation

    /// What the one big button does right now.
    enum PrimaryAction {
        case launch          // nothing is up
        case terminate       // everything (or the running remainder) comes down
        case fillRemaining   // partly up, and this Gruppe prefers to finish

        var label: String {
            switch self {
            case .launch: return "Launch"
            case .terminate: return "Terminate"
            case .fillRemaining: return "Launch Rest"
            }
        }
    }

    /// A Gruppe that is partly running is genuinely ambiguous — the group's own
    /// `fillsWhenPartial` decides, rather than guessing from `isActive`.
    func primaryAction(for group: AppGroup) -> PrimaryAction {
        let running = runningCount(in: group)
        if running == 0 { return .launch }
        if running >= group.apps.count { return .terminate }
        return group.fillsWhenPartial ? .fillRemaining : .terminate
    }

    func toggle(_ group: AppGroup) {
        switch primaryAction(for: group) {
        case .launch, .fillRemaining: launchGroup(group)
        case .terminate: terminateGroup(group)
        }
    }

    func setFillsWhenPartial(_ fills: Bool, for group: AppGroup) {
        guard let index = index(of: group) else { return }
        groups[index].fillsWhenPartial = fills
    }

    /// Launches the Gruppe. Apps already running are left alone rather than
    /// being brought forward, so launching never steals focus from whatever
    /// you are doing.
    ///
    /// When the Gruppe is sequenced, apps start in list order with the
    /// configured pause between them; otherwise they all go at once.
    func launchGroup(_ group: AppGroup) {
        guard let index = index(of: group) else { return }
        groups[index].isActive = true
        cancelSequence(for: group.id)
        if pendingKills.removeValue(forKey: group.id) != nil {
            Self.log("cancelled pending force quit for \"\(groups[index].name)\"")
        }

        let live = groups[index]
        Self.log("LAUNCH \"\(live.name)\"" + (live.isSequenced ? " [sequenced \(live.sequenceDelay)s]" : ""))

        let running = NSWorkspace.shared.runningApplications
        let pending = live.apps.filter { $0.instances(among: running).isEmpty }
        guard !pending.isEmpty else { settle(); return }

        guard live.isSequenced else {
            pending.forEach(open(_:))
            return
        }

        let delay = live.sequenceDelay
        let groupID = live.id
        sequenceTasks[groupID] = Task { @MainActor [weak self] in
            guard let self else { return }
            for (step, app) in pending.enumerated() {
                if Task.isCancelled { return }
                Self.log("  [\(step + 1)/\(pending.count)] open \(app.name)")
                self.open(app)
                if step < pending.count - 1, delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            self.sequenceTasks[groupID] = nil
            self.settle()
        }
    }

    private func open(_ app: AppEntry) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = UserDefaults.standard.bool(forKey: "activateOnLaunch")
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                if let error { Self.log("  could not open \(app.name) — \(error.localizedDescription)") }
                self?.tracker.refresh()
                self?.settle()
            }
        }
    }

    /// Closes the Gruppe's apps. Apps that also belong to another Gruppe that
    /// is still active are spared, and Gruppen never kills itself.
    ///
    /// A sequenced Gruppe closes in reverse — last launched, first closed —
    /// which is what you want when later apps depend on earlier ones.
    func terminateGroup(_ group: AppGroup) {
        guard let index = index(of: group) else { return }
        groups[index].isActive = false
        cancelSequence(for: group.id)

        let live = groups[index]
        Self.log("TERMINATE \"\(live.name)\"" + (live.isSequenced ? " [LIFO \(live.sequenceDelay)s]" : ""))

        let spared = protectedBundleIDs(excluding: live.id)
        let doomed = live.apps.filter { !spared.contains($0.id) }
        guard !doomed.isEmpty else { return }

        let ordered = live.isSequenced ? Array(doomed.reversed()) : doomed
        let ownBundleID = Bundle.main.bundleIdentifier
        // Resolve the exact processes once, up front. Re-resolving later would
        // target whatever happens to be running at that moment.
        let steps = ordered.map { app in
            app.runningInstances.filter { $0.bundleIdentifier != ownBundleID }
        }
        guard steps.contains(where: { !$0.isEmpty }) else { settle(); return }

        guard live.isSequenced, live.sequenceDelay > 0 else {
            close(steps.flatMap { $0 }, groupID: live.id)
            settle()
            return
        }

        let delay = live.sequenceDelay
        let groupID = live.id
        sequenceTasks[groupID] = Task { @MainActor [weak self] in
            guard let self else { return }
            for (step, instances) in steps.enumerated() {
                if Task.isCancelled { return }
                if !instances.isEmpty {
                    Self.log("  [\(step + 1)/\(steps.count)] close \(ordered[step].name)")
                    self.close(instances, groupID: groupID)
                }
                if step < steps.count - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            self.sequenceTasks[groupID] = nil
            self.settle()
        }
    }

    /// Closes specific processes, honouring the grace period.
    ///
    /// Tokens are held in a set per Gruppe rather than a single slot, so a
    /// sequenced termination can have several graceful quits in flight without
    /// each step cancelling the one before it.
    private func close(_ targets: [NSRunningApplication], groupID: UUID) {
        guard !targets.isEmpty else { return }

        guard gracePeriod > 0 else {
            for target in targets {
                Self.log("  FORCE QUIT \(target.bundleIdentifier ?? "?") pid \(target.processIdentifier)")
                target.forceTerminate()
            }
            settle()
            return
        }

        targets.forEach { $0.terminate() }
        let token = UUID()
        pendingKills[groupID, default: []].insert(token)
        DispatchQueue.main.asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
            guard let self, self.pendingKills[groupID]?.contains(token) == true else { return }
            self.pendingKills[groupID]?.remove(token)
            for target in targets where !target.isTerminated {
                Self.log("  FORCE QUIT (grace expired) \(target.bundleIdentifier ?? "?") pid \(target.processIdentifier)")
                target.forceTerminate()
            }
            self.settle()
        }
    }

    private func cancelSequence(for groupID: UUID) {
        guard let task = sequenceTasks.removeValue(forKey: groupID) else { return }
        task.cancel()
        Self.log("cancelled in-flight sequence")
    }

    /// Ids of apps kept alive by some *other* active group.
    private func protectedBundleIDs(excluding groupID: UUID) -> Set<AppEntry.ID> {
        var protected: Set<AppEntry.ID> = []
        for group in groups where group.id != groupID && group.isActive {
            protected.formUnion(group.apps.map(\.id))
        }
        return protected
    }

    // MARK: - Snapshot

    /// Apps a person would call "my current workspace": ordinary windowed
    /// applications. `LSUIElement` menu-bar agents report `.accessory` and are
    /// excluded as background tooling, as are Finder and Gruppen itself.
    func snapshotCandidates() -> [AppEntry] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownPID = NSRunningApplication.current.processIdentifier
        let excluded: Set<String> = ["com.apple.finder"]
        var seen: Set<AppEntry.ID> = []

        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            // By pid as well as identifier: the identifier is nil when running
            // outside an app bundle, and we must never suggest ourselves.
            .filter { $0.processIdentifier != ownPID }
            .filter { ownBundleID == nil || $0.bundleIdentifier != ownBundleID }
            .filter { !excluded.contains($0.bundleIdentifier ?? "") }
            .compactMap(\.bundleURL)
            .compactMap(AppEntry.init(url:))
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func createGroup(named name: String,
                     apps: [AppEntry],
                     colorHex: String = Theme.defaultGroupHex) -> AppGroup {
        var group = AppGroup(name: uniqueName(from: name), apps: apps, colorHex: colorHex)
        group.isActive = false
        groups.append(group)
        refreshRunning()
        Self.log("CREATE \"\(group.name)\" with \(apps.count) app(s)")
        return group
    }

    @discardableResult
    func createGroup(from match: Presets.Match) -> AppGroup {
        createGroup(named: match.name,
                    apps: match.urls.compactMap(AppEntry.init(url:)),
                    colorHex: match.colorHex)
    }

    // MARK: - Application index

    /// Filters the cached preset matches against the Gruppen that already
    /// exist. Pure in-memory work — safe to run on every `groups` change.
    private func updateSuggestions() {
        let taken = Set(groups.map { $0.name.lowercased() })
        let filtered = cachedMatches.filter { !taken.contains($0.name.lowercased()) }
        if filtered.map(\.id) != suggestions.map(\.id) {
            suggestions = filtered
        }
    }

    /// Re-reads the disk. The directory walk runs off the main actor; the
    /// LaunchServices lookups that repair moved bundles stay on it.
    func rescanApplications() async {
        let scanned: (matches: [Presets.Match], count: Int) = await Task.detached(priority: .utility) {
            (Presets.matchesOnDisk(), Presets.indexedApplicationCount())
        }.value

        IconCache.shared.clear()
        let repaired = repairAppPaths()
        cachedMatches = scanned.matches
        updateSuggestions()
        refreshRunning()
        indexReport = IndexReport(appCount: scanned.count,
                                  repairedPaths: repaired,
                                  scannedAt: Date())
        Self.log("RESCAN — \(scanned.count) apps, \(scanned.matches.count) preset match(es), \(repaired) path(s) repaired")
    }

    /// Points entries whose bundle has moved at wherever LaunchServices says
    /// that bundle identifier lives now.
    private func repairAppPaths() -> Int {
        var updated = groups
        var repaired = 0

        for groupIndex in updated.indices {
            for appIndex in updated[groupIndex].apps.indices {
                let app = updated[groupIndex].apps[appIndex]
                guard !FileManager.default.fileExists(atPath: app.path),
                      !app.bundleID.isEmpty,
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID),
                      let resolved = AppEntry(url: url)
                else { continue }
                Self.log("  repaired \(app.name): \(app.path) -> \(resolved.path)")
                updated[groupIndex].apps[appIndex] = resolved
                repaired += 1
            }
        }

        if repaired > 0 { groups = updated }
        return repaired
    }

    // MARK: - Status

    func isRunning(_ app: AppEntry) -> Bool {
        runningIDs.contains(app.id)
    }

    func runningCount(in group: AppGroup) -> Int {
        group.apps.reduce(0) { $0 + (runningIDs.contains($1.id) ? 1 : 0) }
    }
}
