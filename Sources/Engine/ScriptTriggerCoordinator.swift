import AppKit
import Darwin
import Foundation
import IOKit.ps

/// Arms the library's triggers, and runs what they fire.
///
/// **Every trigger here is something the system already tells us about:**
///
/// | Trigger | Source |
/// | --- | --- |
/// | File drop | `FSEventStream` — the kernel reports the change |
/// | Global hotkey | Carbon `RegisterEventHotKey` |
/// | App lifecycle (bundled apps) | `NSWorkspace` launch/terminate notifications |
/// | App lifecycle (raw processes) | kqueue for exit; `ProcessMonitor` for launch |
/// | System state | `NSWorkspace` sleep/wake, `IOPSNotification` for power |
///
/// There is no timer and no scan. When nothing is armed this object holds no
/// resources at all, and an armed one costs a callback registration.
///
/// **On CPU thresholds:** there is no notification for "CPU went above 80%", so
/// offering one would mean sampling on a timer. That is the one thing this app
/// does not do, so it is not offered. Battery level *is* event-driven, via
/// `IOPSNotificationCreateRunLoopSource`, so that is what the threshold trigger
/// uses.
@MainActor
final class ScriptTriggerCoordinator: ObservableObject {
    private let library: ScriptLibrary
    /// Live folder watchers, one per armed folder-watch script.
    private var watchers: [UUID: FolderWatcher] = [:]
    /// Workspace and power observers, torn down with the arming.
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    /// Last battery reading, so "below 20%" fires on the way down and not on
    /// every notification while it sits there.
    private var lastBatteryPercent: Int?
    private var isArmed = false

    /// Exit watchers, keyed by the pid and the script that wanted it.
    private struct ProcessKey: Hashable { let pid: pid_t; let scriptID: UUID }
    private var exitSources: [ProcessKey: DispatchSourceProcess] = [:]
    private var distributedObservers: [NSObjectProtocol] = []
    /// Only exists while a script watches for a raw process *launch*.
    private lazy var processMonitor = ProcessMonitor { [weak self] name, pid in
        Task { @MainActor in self?.handleProcessLaunch(name: name, pid: pid) }
    }
    private var darwinNames: [String] = []
    private var displayWatcher: DisplayWatcher?
    private var wifiWatcher: WiFiWatcher?
    private var audioWatcher: AudioOutputWatcher?
    private var schedules: [UUID: DispatchSourceTimer] = [:]
    /// Files a run has just written into a watched folder. A rule that renames
    /// in place would otherwise see its own result arrive and run again on it,
    /// for ever.
    private var produced: Set<String> = []
    /// Darwin callbacks are C function pointers with no usable context object,
    /// so the live coordinator is reachable through this.
    fileprivate static weak var activeDarwinCoordinator: ScriptTriggerCoordinator?

    init(library: ScriptLibrary) {
        self.library = library
        library.onChange = { [weak self] in self?.rearm() }
    }

    // MARK: Arming

    func rearm() {
        disarm()
        let armable = library.scripts.filter(\.isArmable)
        guard !armable.isEmpty else { return }
        isArmed = true

        for script in armable {
            switch script.trigger.kind {
            case .folderWatch:
                armFolderWatch(script)
            case .hotkey:
                armHotkey(script)
            case .customNotification:
                armCustomNotification(script)
            case .appLifecycle:
                // Bundle matches ride the shared workspace observers. A process
                // name needs more: an exit watcher per running match, and — for
                // launches — the process monitor, since no notification exists.
                if script.trigger.appMatch == .processName, script.trigger.appEvent == .quit {
                    armProcessExit(script)
                }
            case .schedule:
                schedule(script)
            case .systemState, .display, .wifi, .audioDevice, .gruppe, .manual:
                break
            }
        }

        let kinds = Set(armable.map(\.trigger.kind))
        if kinds.contains(.display) {
            displayWatcher = DisplayWatcher { [weak self] added in self?.fireEdge(.display, added ? .on : .off) }
        }
        if kinds.contains(.wifi) {
            wifiWatcher = WiFiWatcher { [weak self] network in
                Task { @MainActor in self?.fireMatching(.wifi, name: network, exact: true) }
            }
        }
        if kinds.contains(.audioDevice) {
            audioWatcher = AudioOutputWatcher { [weak self] device in
                Task { @MainActor in self?.fireMatching(.audioDevice, name: device, exact: false) }
            }
        }
        if kinds.contains(.gruppe) { armGruppe() }

        if armable.contains(where: { $0.trigger.kind == .appLifecycle }) { armAppLifecycle() }
        // Sweeping rules need the wake notification too: an age is reached
        // while the lid is shut.
        if armable.contains(where: { $0.trigger.kind == .systemState
                                     || ($0.trigger.kind == .folderWatch && $0.trigger.sweepsExisting) }) {
            armSystemState()
        }

        // The monitor is armed with exactly the names that need it, and with
        // nothing at all when none do — which is when it costs nothing.
        processMonitor.watch(Set(armable.compactMap { script -> String? in
            guard script.trigger.kind == .appLifecycle,
                  script.trigger.appMatch == .processName,
                  script.trigger.appEvent == .launched else { return nil }
            return script.trigger.processName
        }))
    }

    func disarm() {
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        exitSources.values.forEach { $0.cancel() }
        exitSources.removeAll()
        processMonitor.stop()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
        if !darwinNames.isEmpty {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            CFNotificationCenterRemoveEveryObserver(center, observer)
            darwinNames.removeAll()
        }
        if Self.activeDarwinCoordinator === self { Self.activeDarwinCoordinator = nil }
        HotkeyCenter.shared.unregisterAll(owner: "scripts")
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
        lastBatteryPercent = nil
        displayWatcher?.stop(); displayWatcher = nil
        wifiWatcher?.stop(); wifiWatcher = nil
        audioWatcher?.stop(); audioWatcher = nil
        schedules.values.forEach { $0.cancel() }
        schedules.removeAll()
        isArmed = false
    }

    // MARK: Individual triggers

    private func armFolderWatch(_ script: Script) {
        let folder = script.trigger.watchedFolder
        guard !folder.isEmpty else { return }
        let id = script.id
        let watcher = FolderWatcher(path: folder) { [weak self] newFiles in
            self?.fireRule(id, arrivals: newFiles)
        }
        watcher.start()
        watchers[script.id] = watcher
        if script.trigger.sweepsExisting { sweep(id) }
    }

    /// New files in a rule's folder: the ones the rule admits, minus any a run
    /// just put there itself.
    private func fireRule(_ id: UUID, arrivals: [URL]) {
        guard let script = library.scripts.first(where: { $0.id == id }) else { return }
        let fresh = arrivals.filter { produced.remove($0.path) == nil }
        if script.trigger.sweepsExisting { sweep(id); return }
        let admitted = fresh.filter { script.trigger.admits($0) }
        guard !admitted.isEmpty else { return }
        run(script, paths: admitted, source: "Rule")
    }

    /// Every file already in a rule's folder that the rule admits. For rules
    /// with an age condition, run when armed, when the folder changes and on
    /// wake — "older than 30 days" becomes true while nothing is happening.
    private func sweep(_ id: UUID) {
        guard let script = library.scripts.first(where: { $0.id == id }) else { return }
        let folder = URL(fileURLWithPath: script.trigger.watchedFolder, isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { script.trigger.admits($0) }
        guard !files.isEmpty else { return }
        run(script, paths: files, source: "Rule")
    }

    /// Re-checks every sweeping rule. Called on wake.
    func sweepAll() {
        for script in library.scripts where script.isArmable
            && script.trigger.kind == .folderWatch && script.trigger.sweepsExisting {
            sweep(script.id)
        }
    }

    // MARK: Context

    private func fireEdge(_ kind: ScriptTrigger.Kind, _ edge: ScriptTrigger.Edge) {
        for script in library.scripts where script.isArmable
            && script.trigger.kind == kind && script.trigger.edge == edge {
            fire(script.id, paths: [])
        }
    }

    /// A network joined or a sound output connected: scripts whose `match` is
    /// that network's exact name, or part of that device's.
    private func fireMatching(_ kind: ScriptTrigger.Kind, name: String, exact: Bool) {
        for script in library.scripts where script.isArmable && script.trigger.kind == kind {
            let wanted = script.trigger.match.trimmingCharacters(in: .whitespaces)
            let hit = exact ? name.caseInsensitiveCompare(wanted) == .orderedSame
                            : name.localizedCaseInsensitiveContains(wanted)
            if hit { fire(script.id, paths: []) }
        }
    }

    private func armGruppe() {
        for (name, edge) in [(GroupStore.didLaunch, ScriptTrigger.Edge.on), (GroupStore.didClose, .off)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
                guard let id = note.object as? UUID else { return }
                Task { @MainActor in
                    guard let self else { return }
                    for script in self.library.scripts where script.isArmable
                        && script.trigger.kind == .gruppe && script.trigger.edge == edge
                        && script.trigger.gruppeID == id {
                        self.fire(script.id, paths: [])
                    }
                }
            })
        }
    }

    /// One wake-up, at the next time the schedule is due — then it runs and
    /// books the one after. A wall-clock deadline, so a Mac asleep through
    /// the time runs it on waking rather than never.
    private func schedule(_ script: Script) {
        schedules[script.id]?.cancel()
        guard let next = script.trigger.nextOccurrence(after: Date()) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + next.timeIntervalSinceNow)
        let id = script.id
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, let current = self.library.scripts.first(where: { $0.id == id }),
                      current.isArmable else { return }
                self.fire(id, paths: [])
                self.schedule(current)
            }
        }
        timer.resume()
        schedules[script.id] = timer
    }

    private func armHotkey(_ script: Script) {
        guard let shortcut = script.trigger.shortcut else { return }
        HotkeyCenter.shared.register(shortcut, owner: "scripts") { [weak self] in
            self?.fire(script.id, paths: [])
        }
    }

    private func armAppLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.didLaunchApplicationNotification, ScriptTrigger.AppEvent.launched),
                              (NSWorkspace.didTerminateApplicationNotification, .quit)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                let bundleID = app.bundleIdentifier ?? ""
                let executable = app.executableURL?.lastPathComponent ?? ""
                Task { @MainActor in
                    self?.fireAppLifecycle(bundleID: bundleID, processName: executable, event: event)
                }
            })
        }
    }

    private func fireAppLifecycle(bundleID: String, processName: String, event: ScriptTrigger.AppEvent) {
        for script in library.scripts where script.isArmable
            && script.trigger.kind == .appLifecycle
            && script.trigger.appEvent == event {
            let trigger = script.trigger
            let matches = trigger.appMatch == .bundleIdentifier
                ? trigger.bundleIdentifier == bundleID
                : trigger.processName.caseInsensitiveCompare(processName) == .orderedSame
            if matches { fire(script.id, paths: []) }
        }
        // A process-name script that just saw its target launch should also be
        // watching that new pid for its exit.
        if event == .launched { rearmProcessExitWatchers() }
    }

    /// A raw process appeared. Applications arrive through `NSWorkspace`
    /// instead, so this is only reached for unbundled binaries.
    private func handleProcessLaunch(name: String, pid: pid_t) {
        for script in library.scripts where script.isArmable
            && script.trigger.kind == .appLifecycle
            && script.trigger.appMatch == .processName
            && script.trigger.appEvent == .launched
            && script.trigger.processName.caseInsensitiveCompare(name) == .orderedSame {
            fire(script.id, paths: [])
        }
        // Anything watching this name for its *exit* now has a pid to watch.
        for script in library.scripts where script.isArmable
            && script.trigger.kind == .appLifecycle
            && script.trigger.appMatch == .processName
            && script.trigger.appEvent == .quit
            && script.trigger.processName.caseInsensitiveCompare(name) == .orderedSame {
            watchExit(pid: pid, scriptID: script.id)
        }
    }

    /// Watches processes that are *already running* and match by name, using a
    /// kqueue exit source per pid.
    ///
    /// **The honest limitation:** macOS posts no notification when an arbitrary
    /// Unix process *starts*. Catching a bare `node` launch would mean scanning
    /// the process table on a timer, which this app does not do. So a
    /// process-name trigger fires on **quit** for any matching process — app or
    /// not — that was running when it was armed or that later appeared as an
    /// application, and on **launch** only for real application bundles. Said
    /// plainly in the UI rather than papered over.
    private func armProcessExit(_ script: Script) {
        let name = script.trigger.processName
        guard !name.isEmpty else { return }
        for pid in ProcessMonitor.pids(named: name) {
            watchExit(pid: pid, scriptID: script.id)
        }
    }


    private func rearmProcessExitWatchers() {
        let wanted = library.scripts.filter {
            $0.isArmable && $0.trigger.kind == .appLifecycle
                && $0.trigger.appMatch == .processName && $0.trigger.appEvent == .quit
        }
        for script in wanted { armProcessExit(script) }
    }

    private func watchExit(pid: pid_t, scriptID: UUID) {
        let key = ProcessKey(pid: pid, scriptID: scriptID)
        guard exitSources[key] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                     queue: DispatchQueue.main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.exitSources[key]?.cancel()
            self.exitSources.removeValue(forKey: key)
            self.fire(scriptID, paths: [])
        }
        source.resume()
        exitSources[key] = source
    }

    /// A named Darwin or distributed notification.
    private func armCustomNotification(_ script: Script) {
        let name = script.trigger.notificationName
        guard !name.isEmpty else { return }

        switch script.trigger.notificationScope {
        case .distributed:
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.fire(script.id, paths: []) }
            }
            distributedObservers.append(observer)
        case .darwin:
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            // Darwin notifications carry no payload and no object; the name is
            // the whole message, which is why the callback re-reads the library.
            CFNotificationCenterAddObserver(center, observer, { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                Task { @MainActor in
                    ScriptTriggerCoordinator.activeDarwinCoordinator?.fireDarwin(named: name)
                }
            }, name as CFString, nil, .deliverImmediately)
            darwinNames.append(name)
            Self.activeDarwinCoordinator = self
        }
    }

    fileprivate func fireDarwin(named name: String) {
        for script in library.scripts where script.isArmable
            && script.trigger.kind == .customNotification
            && script.trigger.notificationScope == .darwin
            && script.trigger.notificationName == name {
            fire(script.id, paths: [])
        }
    }

    private func armSystemState() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fireSystem(.willSleep) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.fireSystem(.didWake)
                self?.sweepAll()
            }
        })

        // Power: a run-loop source the system signals, not a poll.
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let coordinator = Unmanaged<ScriptTriggerCoordinator>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in coordinator.handlePowerChange() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        lastBatteryPercent = Self.batteryPercent()
    }

    private func fireSystem(_ event: ScriptTrigger.SystemEvent) {
        for script in library.scripts where script.isArmable
            && script.trigger.kind == .systemState
            && script.trigger.systemEvent == event {
            fire(script.id, paths: [])
        }
    }

    private func handlePowerChange() {
        let onAC = Self.isOnAC()
        if onAC { fireSystem(.powerConnected) } else { fireSystem(.powerDisconnected) }

        guard let percent = Self.batteryPercent() else { return }
        let previous = lastBatteryPercent
        lastBatteryPercent = percent
        // Edge-triggered: only on the way down past the threshold, so a machine
        // sitting at 19% does not fire on every power notification.
        for script in library.scripts where script.isArmable
            && script.trigger.kind == .systemState
            && script.trigger.systemEvent == .batteryBelow {
            let threshold = script.trigger.threshold
            if percent < threshold, (previous ?? threshold + 1) >= threshold {
                fire(script.id, paths: [])
            }
        }
    }

    // MARK: Running

    /// A run in flight: which step it is on, and how the ones before it went.
    /// The page lights its slots from this.
    struct Progress: Equatable {
        var current: Int
        var finished: [Bool] = []
    }

    @Published private(set) var progress: [UUID: Progress] = [:]

    /// What the Gruppe and workspace steps call. Set by the app, which owns the
    /// store and the workspace engine.
    var hooks = ScriptRunner.Hooks()

    /// Runs a script because its trigger fired.
    func fire(_ id: UUID, paths: [URL]) {
        guard let script = library.scripts.first(where: { $0.id == id }) else { return }
        run(script, paths: paths, source: script.trigger.kind.shortLabel)
    }

    /// Runs `script`'s steps in order, handing each the files the last one
    /// produced, and stops at the first that fails.
    ///
    /// A script already running is not started a second time — a folder that
    /// fills faster than its script empties it would otherwise stack runs, and
    /// a workspace whose script activates that workspace would never end.
    @discardableResult
    func run(_ script: Script, paths: [URL], source: String = "Manual") -> Bool {
        let id = script.id
        guard progress[id] == nil, !script.steps.isEmpty else { return false }
        progress[id] = Progress(current: 0)
        let hooks = hooks
        let started = Date()

        Task { @MainActor [weak self] in
            var files = paths
            var outcomes: [ScriptRunRecord.StepOutcome] = []
            for (index, step) in script.steps.enumerated() {
                self?.progress[id]?.current = index
                do {
                    let outcome = try await ScriptRunner.perform(step, files: files, hooks: hooks)
                    files = outcome.files
                    self?.produced.formUnion(outcome.files.map(\.path))
                    outcomes.append(.init(stepID: step.id, label: step.kind.label, ok: true,
                                          message: outcome.message))
                    self?.progress[id]?.finished.append(true)
                } catch {
                    outcomes.append(.init(stepID: step.id, label: step.kind.label, ok: false,
                                          message: error.localizedDescription))
                    self?.progress[id]?.finished.append(false)
                    break
                }
            }
            let record = ScriptRunRecord(date: started, source: source,
                                         duration: Date().timeIntervalSince(started), steps: outcomes)
            self?.finish(record, of: script)
        }
        return true
    }

    private func finish(_ record: ScriptRunRecord, of script: Script) {
        progress[script.id] = nil
        library.record(record, for: script.id)
        GroupStore.log("SCRIPT \"\(script.name)\" \(record.succeeded ? "ok" : "failed")"
                       + String(format: " %.2fs — ", record.duration) + record.summary)

        switch record.succeeded ? script.output.onSuccess : script.output.onFailure {
        case .none:
            break
        case .sound:
            NSSound(named: record.succeeded ? "Glass" : "Basso")?.play()
        case .notification:
            let body = record.summary.split(separator: "\n").first.map(String.init) ?? "Done"
            Notifier.post(title: record.succeeded ? script.name : "\(script.name) failed", body: body) { failure in
                guard let failure else { return }
                GroupStore.log("SCRIPT notification failed — \(failure)")
            }
        }
    }

    // MARK: Power helpers

    private nonisolated static func batteryPercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Int((Double(current) / Double(max)) * 100)
        }
        return nil
    }

    /// Read from the power source's own state rather than
    /// `IOPSGetProvidingPowerType`, which has no Swift overlay in this SDK.
    private nonisolated static func isOnAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return state == kIOPSACPowerValue
        }
        return false
    }
}

// MARK: - Folder watching

/// One folder, watched by the kernel.
///
/// `FSEventStream` is the event-driven route: the kernel posts changes to a
/// dispatch queue and nothing runs in between. The latency argument is a
/// coalescing window for bursts, not a polling interval.
final class FolderWatcher {
    private let path: String
    private let onNewFiles: ([URL]) -> Void
    private var stream: FSEventStreamRef?
    private var known: Set<String> = []
    private let queue = DispatchQueue(label: "com.dhilanpatel.gruppen.folderwatch")

    init(path: String, onNewFiles: @escaping ([URL]) -> Void) {
        self.path = path
        self.onNewFiles = onNewFiles
    }

    func start() {
        guard stream == nil else { return }
        // Snapshot first, so existing contents are not treated as arrivals.
        known = Set(currentFiles().map(\.path))

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handleEvent()
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    /// Diffs the folder against what was there last time. The event tells us
    /// *something* changed; this works out what arrived.
    private func handleEvent() {
        let current = currentFiles()
        let currentPaths = Set(current.map(\.path))
        let arrived = current.filter { !known.contains($0.path) }
        known = currentPaths
        guard !arrived.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onNewFiles(arrived) }
    }

    private func currentFiles() -> [URL] {
        let url = URL(fileURLWithPath: path)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}

// MARK: - Notifications

/// System banners, without pulling in a framework that refuses to work outside a
/// signed bundle.
///
/// `UNUserNotificationCenter` throws if the process has no bundle identifier —
/// which is exactly the case in a test harness — so every call is guarded and
/// simply does nothing when notifications are unavailable.
enum Notifier {
    static func post(title: String, body: String, report: @escaping (String?) -> Void = { _ in }) {
        guard Bundle.main.bundleIdentifier != nil else {
            report("notifications need a bundled app")
            return
        }
        NotifierBridge.post(title: title, body: body, report: report)
    }
}
