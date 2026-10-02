import AppKit
import Combine
import Foundation

/// Owns the workspace profiles, persists them, and activates them.
///
/// ## The shape of an activation
///
/// Six stages, run in a fixed order, each independent of the others:
///
/// 1. **Telemetry** — swap the monitor's layout.
/// 2. **Dock** — rewrite the pinned apps and restart the Dock.
/// 3. **Terminate** — close what this context does not want.
/// 4. **Launch** — open what it does, skipping anything already up.
/// 5. **Open** — links in the browser, folders in Finder.
/// 6. **Script** — one library script, last.
///
/// The order is not arbitrary. Telemetry first because it is instant and pure
/// preference. The Dock next, because restarting it is the most visually
/// disruptive thing here and it should happen while the screen is already
/// changing. Terminating before launching so a context switch frees memory
/// before it asks for more. The script last, because it is the only stage that
/// can reasonably expect the rest of the world to be in place.
///
/// ## Nothing here throws
///
/// A profile is a list of independent intentions. A folder that has been moved
/// must not stop the apps from launching, and an app that has been deleted must
/// not stop the script. Every stage returns an outcome, the outcomes are
/// collected into a `WorkspaceActivationReport`, and the UI shows it. Failure is
/// reported, never silent and never fatal.
///
/// ## Nothing here blocks
///
/// `activate` returns immediately. The work runs in one `Task` on the main
/// actor, which is where every API it touches — `NSWorkspace`, `CFPreferences`,
/// `WidgetManager` — has to be called from anyway; the parts that are genuinely
/// slow (`openApplication`, script execution) are already asynchronous, so the
/// runloop is never held. There is no timer and nothing polls: an activation
/// happens because someone pressed something.
@MainActor
final class WorkspaceEngine: ObservableObject {
    @Published var profiles: [WorkspaceProfile] = [] {
        didSet {
            guard !isLoading, profiles != oldValue else { return }
            save()
            syncHotkeys()
        }
    }

    /// The profile most recently activated, if it is still one we know about.
    /// Purely a label — nothing is "deactivated", because a context switch
    /// replaces a context rather than toggling one.
    @Published private(set) var activeProfileID: UUID?

    /// The last activation's record, for the UI to show.
    @Published private(set) var lastReport: WorkspaceActivationReport?

    /// True while an activation is in flight, so the UI can disable the button
    /// rather than letting two runs interleave.
    @Published private(set) var isActivating = false

    /// Profiles whose shortcut macOS refused to hand over.
    @Published private(set) var unavailableShortcuts: Set<UUID> = []

    /// Set by the app so the script stage can run through the same path as every
    /// other script — same transcript, same feedback, same argv safety.
    var scriptRunner: ((UUID) -> Bool)?

    private var isLoading = false
    private var hotkeySignature: [UUID: Shortcut] = [:]
    private var hotkeysSuspended = false
    private var activation: Task<Void, Never>?

    private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Gruppen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profiles.json")
    }

    init(fileURL: URL = WorkspaceEngine.defaultFileURL) {
        self.fileURL = fileURL
        load()
        syncHotkeys()
    }

    // MARK: Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }
        profiles = LenientLibrary.load(WorkspaceProfile.self, from: fileURL, label: "WORKSPACES")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Editing

    @discardableResult
    func add(named name: String = "New profile") -> WorkspaceProfile {
        let profile = WorkspaceProfile(name: uniqueName(name))
        profiles.append(profile)
        return profile
    }

    func update(_ profile: WorkspaceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard profiles[index] != profile else { return }
        profiles[index] = profile
    }

    func remove(_ profile: WorkspaceProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
    }

    func duplicate(_ profile: WorkspaceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueName(profile.name + " Copy")
        // A duplicate must not inherit the original's hotkey — two profiles
        // answering one combination is a binding that silently belongs to
        // whichever registered last.
        copy.shortcut = nil
        profiles.insert(copy, at: index + 1)
    }

    func move(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
    }

    private func uniqueName(_ base: String) -> String {
        var candidate = base
        var counter = 2
        while profiles.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// Captures the telemetry monitor exactly as it is right now into a profile.
    /// Far and away the easiest way to configure this stage: arrange the monitor
    /// the way you want it, then press the button.
    func captureTelemetry(into profile: WorkspaceProfile) {
        var updated = profile
        updated.telemetry = WidgetManager.shared.currentLayout()
        update(updated)
    }

    // MARK: Hotkeys

    /// Same ownership convention as the Gruppe store and the script coordinator:
    /// a subsystem re-registering its own bindings must never drop anyone else's.
    private static let hotkeyOwner = "workspace"

    func suspendHotkeys() {
        hotkeysSuspended = true
        HotkeyCenter.shared.unregisterAll(owner: Self.hotkeyOwner)
        hotkeySignature = [:]
    }

    func resumeHotkeys() {
        hotkeysSuspended = false
        syncHotkeys()
    }

    /// Re-registers, but only when the bindings actually changed — `profiles`
    /// publishes on every keystroke of a rename.
    func syncHotkeys() {
        guard !hotkeysSuspended else { return }
        let signature = Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
            profile.shortcut.map { (profile.id, $0) }
        })
        guard signature != hotkeySignature else { return }
        hotkeySignature = signature

        HotkeyCenter.shared.unregisterAll(owner: Self.hotkeyOwner)
        var unavailable: Set<UUID> = []
        for profile in profiles {
            guard let shortcut = profile.shortcut else { continue }
            let id = profile.id
            let claimed = HotkeyCenter.shared.register(shortcut, owner: Self.hotkeyOwner) { [weak self] in
                Task { @MainActor in
                    guard let self, let live = self.profiles.first(where: { $0.id == id }) else { return }
                    GroupStore.log("HOTKEY \(shortcut.display) -> profile \"\(live.name)\"")
                    self.activate(live)
                }
            }
            if !claimed { unavailable.insert(id) }
        }
        unavailableShortcuts = unavailable
    }

    /// A combination drives one profile, so binding it here takes it off any
    /// profile already holding it. It can still collide with a *Gruppe's*
    /// shortcut, which Carbon resolves by refusing the second registration —
    /// that is what `unavailableShortcuts` reports.
    func setShortcut(_ shortcut: Shortcut?, for profile: WorkspaceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if let shortcut {
            for other in profiles.indices where other != index && profiles[other].shortcut == shortcut {
                profiles[other].shortcut = nil
            }
        }
        profiles[index].shortcut = shortcut
    }

    // MARK: Activation

    /// Runs a profile. Returns immediately; watch `isActivating` and
    /// `lastReport` for what happened.
    func activate(_ profile: WorkspaceProfile) {
        guard !isActivating else { return }
        // Cancelling rather than queueing: two context switches in flight would
        // race to set the Dock, and the second one is the one the user meant.
        activation?.cancel()
        isActivating = true

        activation = Task { @MainActor [weak self] in
            guard let self else { return }
            // `isActivating` gates every Activate button in the app, so it has
            // to be given back on every path out of here — including the
            // cancelled one. Clearing it only on success meant a single
            // cancelled activation disabled profile switching until relaunch,
            // with nothing on screen to explain why.
            defer { self.isActivating = false }
            let report = await self.run(profile)
            guard !Task.isCancelled else { return }
            self.lastReport = report
            self.activeProfileID = profile.id
            GroupStore.log(report.transcript)
        }
    }

    private func run(_ profile: WorkspaceProfile) async -> WorkspaceActivationReport {
        var report = WorkspaceActivationReport(profileName: profile.name)
        let started = Date()

        // 1 — Telemetry.
        if let layout = profile.telemetry {
            WidgetManager.shared.apply(layout)
            report.add("Telemetry", .done(layout.summary))
        } else {
            report.add("Telemetry", .skipped("left as it was"))
        }

        // 2 — Dock.
        if profile.replacesDock {
            report.add("Dock", DockManager.apply(profile.dockApps))
        } else {
            report.add("Dock", .skipped("left as it was"))
        }

        // 3 — Terminate, before launching, so a switch frees memory before it
        // asks for more.
        report.add("Quit", terminate(profile.terminates))

        // 4 — Launch.
        report.add("Launch", launch(profile.launches))

        // 5 — Links and folders.
        if !profile.links.isEmpty { report.add("Links", open(links: profile.links)) }
        if !profile.folders.isEmpty { report.add("Folders", open(folders: profile.folders)) }

        // 6 — Desktop. After the payload rather than before: switching first
        // means the apps open behind you on the desktop you just left.
        if let desktop = profile.spaceIndex {
            report.add("Desktop", SpaceManager.switchTo(desktop: desktop))
        }

        // 7 — Script.
        if let scriptID = profile.scriptID {
            if scriptRunner?(scriptID) == true {
                report.add("Script", .done("started"))
            } else {
                report.add("Script", .failed("script is no longer in the library"))
            }
        }

        report.duration = Date().timeIntervalSince(started)
        return report
    }

    // MARK: Stages

    /// Opens what is not already open.
    ///
    /// Anything already running is left strictly alone — not activated, not
    /// brought forward. Raising a window the user did not ask for is how a
    /// context switch turns into an interruption, and it is the same rule
    /// `GroupStore.launchGroup` follows.
    private func launch(_ apps: [AppEntry]) -> WorkspaceActivationReport.Outcome {
        guard !apps.isEmpty else { return .skipped("nothing to launch") }
        let running = NSWorkspace.shared.runningApplications
        let missing = apps.filter { !FileManager.default.fileExists(atPath: $0.path) }
        let pending = apps.filter {
            $0.instances(among: running).isEmpty && FileManager.default.fileExists(atPath: $0.path)
        }
        guard !pending.isEmpty else {
            return missing.isEmpty
                ? .skipped("all \(apps.count) already running")
                : .failed("\(missing.count) app(s) missing: \(missing.map(\.name).joined(separator: ", "))")
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = AppSettings.shared.activateOnLaunch
        config.addsToRecentItems = false
        for app in pending {
            NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
                guard let error else { return }
                Task { @MainActor in
                    GroupStore.log("  profile could not open \(app.name) — \(error.localizedDescription)")
                }
            }
        }

        let detail = missing.isEmpty ? "" : " (\(missing.count) missing)"
        return .done("opened \(pending.count) of \(apps.count)\(detail)")
    }

    /// Closes what this context does not want.
    ///
    /// Gruppen is filtered out by pid as well as bundle identifier: the
    /// identifier is nil when running outside a bundle, and an app that quits
    /// itself mid-activation leaves the rest of the profile unrun.
    private func terminate(_ apps: [AppEntry]) -> WorkspaceActivationReport.Outcome {
        guard !apps.isEmpty else { return .skipped("nothing to quit") }
        let ownPID = NSRunningApplication.current.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications

        let targets = apps.flatMap { app in
            app.instances(among: running).filter {
                $0.processIdentifier != ownPID && $0.bundleIdentifier != ownBundleID
            }
        }
        guard !targets.isEmpty else { return .skipped("none of the \(apps.count) were running") }

        // Asked, not killed. A profile switch is routine, and a routine action
        // must never cost someone unsaved work — an app that puts up a "save
        // changes?" sheet gets to put it up. The Gruppe store's force-quit path
        // exists because terminating a *group* is an explicit teardown; this is
        // not that.
        targets.forEach { $0.terminate() }
        return .done("asked \(targets.count) app(s) to quit")
    }

    private func open(links: [String]) -> WorkspaceActivationReport.Outcome {
        var opened = 0
        var bad: [String] = []
        for raw in links {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // A bare "example.com" is what people type; without a scheme `URL`
            // builds a relative path that opens nothing.
            let text = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let url = URL(string: text), url.host != nil else { bad.append(trimmed); continue }
            NSWorkspace.shared.open(url)
            opened += 1
        }
        if opened == 0 { return .failed("no valid links (\(bad.joined(separator: ", ")))") }
        return bad.isEmpty
            ? .done("opened \(opened)")
            : .done("opened \(opened), skipped \(bad.count) invalid")
    }

    private func open(folders: [String]) -> WorkspaceActivationReport.Outcome {
        var opened = 0
        var missing: [String] = []
        for raw in folders {
            let path = (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                missing.append((path as NSString).lastPathComponent)
                continue
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            opened += 1
        }
        if opened == 0 { return .failed("not found: \(missing.joined(separator: ", "))") }
        return missing.isEmpty
            ? .done("opened \(opened)")
            : .done("opened \(opened), \(missing.count) not found")
    }
}
