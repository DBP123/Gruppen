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
/// | App lifecycle | `NSWorkspace` launch/terminate notifications |
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
    private var darwinNames: [String] = []
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
                // Bundle matches ride the shared workspace observers; a process
                // name needs its own exit watcher for anything already running.
                if script.trigger.appMatch == .processName, script.trigger.appEvent == .quit {
                    armProcessExit(script)
                }
            case .systemState, .manual:
                break
            }
        }

        if armable.contains(where: { $0.trigger.kind == .appLifecycle }) { armAppLifecycle() }
        if armable.contains(where: { $0.trigger.kind == .systemState }) { armSystemState() }
    }

    func disarm() {
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        exitSources.values.forEach { $0.cancel() }
        exitSources.removeAll()
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
        isArmed = false
    }

    // MARK: Individual triggers

    private func armFolderWatch(_ script: Script) {
        let folder = script.trigger.watchedFolder
        guard !folder.isEmpty else { return }
        let watcher = FolderWatcher(path: folder) { [weak self] newFiles in
            guard !newFiles.isEmpty else { return }
            self?.fire(script.id, paths: newFiles)
        }
        watcher.start()
        watchers[script.id] = watcher
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
        for pid in Self.pids(named: name) {
            watchExit(pid: pid, scriptID: script.id)
        }
    }

    /// Every process currently running under this executable name.
    ///
    /// `NSWorkspace.runningApplications` only knows about *applications*, so it
    /// cannot see a `java` or `node` started from a terminal — which is exactly
    /// the case this trigger exists for. `proc_listallpids` can. This is a
    /// single pass, performed once when the trigger is armed, and never again:
    /// the watching itself is done by kqueue exit sources, which cost nothing
    /// until the process dies.
    private nonisolated static func pids(named name: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        var matches: [pid_t] = []
        var path = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        for pid in buffer.prefix(Int(filled)) where pid > 0 {
            path.withUnsafeMutableBufferPointer { pointer in
                _ = proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
            }
            let executable = String(cString: path)
            guard !executable.isEmpty else { continue }
            let last = (executable as NSString).lastPathComponent
            if last.caseInsensitiveCompare(name) == .orderedSame { matches.append(pid) }
        }
        return matches
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
            Task { @MainActor in self?.fireSystem(.didWake) }
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

    /// Runs a script and applies its feedback. Called only from an event.
    func fire(_ id: UUID, paths: [URL]) {
        guard let script = library.scripts.first(where: { $0.id == id }) else { return }
        run(script, paths: paths)
    }

    func run(_ script: Script, paths: [URL]) {
        let action = script.action
        let feedback = script.feedback
        let id = script.id
        let name = script.name

        Task { [weak self] in
            do {
                let run = try await ScriptExecutionEngine.run(action, paths: paths)
                await MainActor.run { self?.report(run, feedback: feedback, id: id, name: name) }
            } catch {
                await MainActor.run {
                    self?.library.record(error.localizedDescription, failed: true, for: id)
                    if feedback == .audio { NSSound(named: "Basso")?.play() }
                    if feedback == .banner {
                        Notifier.post(title: "\(name) failed", body: error.localizedDescription) { failure in
                            guard let failure else { return }
                            Task { @MainActor in self?.library.record("! \(failure)", failed: true, for: id) }
                        }
                    }
                    GroupStore.log("SCRIPT \"\(name)\" failed — \(error.localizedDescription)")
                }
            }
        }
    }

    private func report(_ run: ScriptRun, feedback: ScriptFeedback, id: UUID, name: String) {
        // The transcript is always kept: the log drawer is a view of it, not the
        // only reason to have it.
        library.record(run.transcript.isEmpty
                       ? String(format: "exit 0 · %.2fs", run.duration)
                       : run.transcript,
                       failed: false, for: id)
        GroupStore.log("SCRIPT \"\(name)\" — " + String(format: "%.2fs", run.duration))

        switch feedback {
        case .silent, .log:
            break
        case .audio:
            NSSound(named: "Glass")?.play()
        case .banner:
            let body = run.transcript.split(separator: "\n").first.map(String.init) ?? "Done"
            Notifier.post(title: name, body: body) { [weak self] failure in
                guard let failure else { return }
                Task { @MainActor in self?.library.record("! \(failure)", failed: true, for: id) }
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
