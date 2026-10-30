import AppKit
import Darwin
import Foundation
import IOKit.ps

/// Arms the hats of every flow that is switched on, and starts runs when they
/// fire.
///
/// **Every trigger here is something the system already tells us about:**
///
/// | Hat | Source |
/// | --- | --- |
/// | File lands in a folder | `FSEventStream` — the kernel reports the change |
/// | Key combination | Carbon `RegisterEventHotKey` |
/// | App launches or quits | `NSWorkspace` notifications; kqueue for a raw process's exit |
/// | Mac's state | `NSWorkspace` sleep/wake, `IOPSNotification` for power |
/// | Display, Wi-Fi, audio | CoreGraphics, CoreWLAN, CoreAudio callbacks |
/// | At a time | one wall-clock wake-up at the next due time |
///
/// There is no polling. Nothing armed holds nothing; an armed hat costs a
/// callback registration. The one exception is "Every few minutes", which is
/// a timer because that is what it asks for.
///
/// **Rearming is cheap to ask for.** Editing a flow asks on every keystroke;
/// the hats actually armed are compared with what should be, and nothing is
/// torn down unless they differ.
@MainActor
final class FlowTriggers {
    private let library: FlowLibrary
    /// Unowned: the engine owns this object.
    private unowned let engine: FlowEngine

    /// What is armed: each enabled, runnable flow's hats. Compared on every
    /// change, so typing in a code block does not re-register a hotkey.
    private var armed: [ArmedHat] = []
    private struct ArmedHat: Equatable {
        let flow: UUID
        let hat: Block
        var kind: TriggerKind
    }

    private var watchers: [UUID: FolderWatcher] = [:]
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var lastPower: PowerSource?
    private struct ExitKey: Hashable { let pid: pid_t; let hat: UUID }
    private var exitSources: [ExitKey: DispatchSourceProcess] = [:]
    private lazy var processMonitor = ProcessMonitor { [weak self] name, pid in
        Task { @MainActor in self?.processLaunched(name: name, pid: pid) }
    }
    private var darwinNames: [String] = []
    private var displayWatcher: DisplayWatcher?
    private var wifiWatcher: WiFiWatcher?
    private var audioWatcher: AudioOutputWatcher?
    private var timers: [UUID: DispatchSourceTimer] = [:]
    private let hotkeys = HotkeyBindings(owner: "flows")
    /// Darwin callbacks are C function pointers with no usable context object,
    /// so the live instance is reachable through this.
    fileprivate static weak var active: FlowTriggers?

    init(library: FlowLibrary, engine: FlowEngine) {
        self.library = library
        self.engine = engine
    }

    // MARK: Arming

    /// Arms what should be armed, if that changed.
    func rearm() {
        let registry = library.registry
        let wanted = library.flows.filter { $0.isEnabled && $0.isRunnable(registry: registry) }.flatMap { flow in
            flow.triggers.compactMap { hat -> ArmedHat? in
                guard case .trigger(let kind) = registry.definition(hat.definition).implementation,
                      kind != .manual, kind != .stash, kind != .external else { return nil }
                return ArmedHat(flow: flow.id, hat: hat, kind: kind)
            }
        }
        guard wanted != armed else { return }
        disarm()
        armed = wanted
        guard !wanted.isEmpty else { return }
        Self.active = self

        for entry in wanted {
            switch entry.kind {
            case .folder: armFolder(entry)
            case .schedule: schedule(entry)
            case .interval: repeatEvery(entry)
            case .notification: armNotification(entry)
            case .app:
                if case .process(let name) = AppTarget(entry.hat.text("app")), entry.hat.text("event") == "quits" {
                    for pid in ProcessMonitor.pids(named: name) { watchExit(pid: pid, hat: entry.hat.id) }
                }
            default: break
            }
        }

        syncHotkeys()

        let kinds = Set(wanted.map(\.kind))
        if kinds.contains(.display) {
            displayWatcher = DisplayWatcher { [weak self] added in
                self?.fire(.display) { $0.text("event") == (added ? "connected" : "disconnected") }
            }
        }
        if kinds.contains(.wifi) {
            wifiWatcher = WiFiWatcher { [weak self] network in
                self?.fire(.wifi, outputs: ["network": .text(network)]) {
                    network.caseInsensitiveCompare($0.text("network").trimmingCharacters(in: .whitespaces)) == .orderedSame
                }
            }
        }
        if kinds.contains(.audio) {
            audioWatcher = AudioOutputWatcher { [weak self] device in
                Task { @MainActor in
                    self?.fire(.audio, outputs: ["device": .text(device)]) {
                        let wanted = $0.text("device").trimmingCharacters(in: .whitespaces)
                        return !wanted.isEmpty && device.localizedCaseInsensitiveContains(wanted)
                    }
                }
            }
        }
        if kinds.contains(.gruppe) { armGruppe() }
        if kinds.contains(.app) { armApps() }
        if kinds.contains(.system) || kinds.contains(.battery) { armSystem() }

        // The process monitor exists only while a hat waits for a raw
        // process to *launch* — the one case no notification covers.
        processMonitor.watch(Set(wanted.compactMap { entry -> String? in
            guard entry.kind == .app, entry.hat.text("event") != "quits",
                  case .process(let name) = AppTarget(entry.hat.text("app")) else { return nil }
            return name
        }))
    }

    func disarm() {
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        exitSources.values.forEach { $0.cancel() }
        exitSources.removeAll()
        processMonitor.stop()
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        distributedObservers.removeAll()
        if !darwinNames.isEmpty {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                    UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            darwinNames.removeAll()
        }
        _ = hotkeys.sync([:]) { _ in }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
        lastPower = nil
        displayWatcher?.stop(); displayWatcher = nil
        wifiWatcher?.stop(); wifiWatcher = nil
        audioWatcher?.stop(); audioWatcher = nil
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        armed = []
    }

    /// While a shortcut is being recorded, pressing a combination that is
    /// bound must record it rather than run a flow.
    func suspendHotkeys() { hotkeys.suspend() }
    func resumeHotkeys() {
        hotkeys.resume()
        syncHotkeys()
    }

    private func syncHotkeys() {
        let bindings = Dictionary(armed.filter { $0.kind == .hotkey }.compactMap { entry in
            HotkeyValue.shortcut(entry.hat.text("keys")).map { (entry.hat.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        _ = hotkeys.sync(bindings) { [weak self] hat in self?.fire(hat: hat) }
    }

    // MARK: Firing

    /// Runs the flow that owns `hat`.
    private func fire(hat: UUID, outputs: [String: Value] = [:]) {
        guard let entry = armed.first(where: { $0.hat.id == hat }) else { return }
        let title = library.registry.definition(entry.hat.definition).title
        engine.run(entry.flow, trigger: outputs, source: title)
    }

    /// Runs every armed hat of `kind` that `matches` the event.
    private func fire(_ kind: TriggerKind, outputs: [String: Value] = [:], where matches: (Block) -> Bool) {
        for entry in armed where entry.kind == kind && matches(entry.hat) {
            fire(hat: entry.hat.id, outputs: outputs)
        }
    }

    // MARK: Folders

    private func armFolder(_ entry: ArmedHat) {
        let path = (entry.hat.text("folder") as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        let hat = entry.hat.id
        let watcher = FolderWatcher(path: path) { [weak self] arrivals in
            guard let self else { return }
            // A flow's own output landing in its folder is not an arrival.
            let fresh = arrivals.filter { !self.engine.consumeProduced($0.path) }
            guard !fresh.isEmpty else { return }
            self.fire(hat: hat, outputs: ["files": .files(fresh)])
        }
        watcher.start()
        watchers[hat] = watcher
    }

    // MARK: Time

    /// One wake-up, at the next time it is due — then it runs and books the
    /// one after. A wall-clock deadline, so a Mac asleep through the time runs
    /// it on waking rather than never.
    private func schedule(_ entry: ArmedHat) {
        timers[entry.hat.id]?.cancel()
        guard let next = Schedule(entry.hat).next(after: Date()) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + next.timeIntervalSinceNow)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.armed.contains(entry) else { return }
                self.fire(hat: entry.hat.id)
                self.schedule(entry)
            }
        }
        timer.resume()
        timers[entry.hat.id] = timer
    }

    private func repeatEvery(_ entry: ArmedHat) {
        let minutes = max(1, entry.hat.number("minutes"))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Leeway lets macOS fold the wake-up into others: an "every 30
        // minutes" flow does not need to be on the second.
        timer.schedule(deadline: .now() + minutes * 60, repeating: minutes * 60, leeway: .seconds(Int(min(60, minutes * 6))))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fire(hat: entry.hat.id) }
        }
        timer.resume()
        timers[entry.hat.id] = timer
    }

    // MARK: Apps

    private func armApps() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.didLaunchApplicationNotification, "launches"),
                              (NSWorkspace.didTerminateApplicationNotification, "quits")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let bundleID = app.bundleIdentifier ?? ""
                let executable = app.executableURL?.lastPathComponent ?? ""
                let name = app.localizedName ?? executable
                MainActor.assumeIsolated {
                    self?.appEvent(bundleID: bundleID, executable: executable, name: name, event: event)
                }
            })
        }
    }

    private func appEvent(bundleID: String, executable: String, name: String, event: String) {
        fire(.app, outputs: ["app": .text(name)]) { hat in
            (hat.text("event").isEmpty ? "launches" : hat.text("event")) == event
                && AppTarget(hat.text("app")).matches(bundleID: bundleID, executable: executable)
        }
        // A process-name hat waiting for a quit now has a new pid to watch.
        if event == "launches" {
            for entry in armed where entry.kind == .app && entry.hat.text("event") == "quits" {
                if case .process(let wanted) = AppTarget(entry.hat.text("app")),
                   wanted.caseInsensitiveCompare(executable) == .orderedSame {
                    for pid in ProcessMonitor.pids(named: wanted) { watchExit(pid: pid, hat: entry.hat.id) }
                }
            }
        }
    }

    /// A raw process appeared. Applications arrive through `NSWorkspace`
    /// instead, so this is reached only for unbundled binaries.
    private func processLaunched(name: String, pid: pid_t) {
        fire(.app, outputs: ["app": .text(name)]) { hat in
            hat.text("event") != "quits" && AppTarget(hat.text("app")).matches(bundleID: "", executable: name)
        }
        for entry in armed where entry.kind == .app && entry.hat.text("event") == "quits"
            && AppTarget(entry.hat.text("app")).matches(bundleID: "", executable: name) {
            watchExit(pid: pid, hat: entry.hat.id)
        }
    }

    private func watchExit(pid: pid_t, hat: UUID) {
        let key = ExitKey(pid: pid, hat: hat)
        guard exitSources[key] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.exitSources.removeValue(forKey: key)?.cancel()
                self.fire(hat: hat)
            }
        }
        source.resume()
        exitSources[key] = source
    }

    // MARK: Gruppen

    private func armGruppe() {
        for (name, event) in [(GroupStore.didLaunch, "launches"), (GroupStore.didClose, "closes")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let id = note.object as? UUID else { return }
                MainActor.assumeIsolated {
                    self?.fire(.gruppe) { hat in
                        Pick.split(hat.text("gruppe")).0 == id && (hat.text("event").isEmpty ? "launches" : hat.text("event")) == event
                    }
                }
            })
        }
    }

    // MARK: Notifications

    private func armNotification(_ entry: ArmedHat) {
        let name = entry.hat.text("name").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if entry.hat.text("scope") == "Distributed" {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire(hat: entry.hat.id, outputs: ["name": .text(name)]) }
                })
        } else if !darwinNames.contains(name) {
            // Darwin notifications carry no payload and no object; the name is
            // the whole message.
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                            { _, _, name, _, _ in
                                                guard let name = name?.rawValue as String? else { return }
                                                Task { @MainActor in FlowTriggers.active?.darwin(name) }
                                            }, name as CFString, nil, .deliverImmediately)
            darwinNames.append(name)
        }
    }

    fileprivate func darwin(_ name: String) {
        fire(.notification, outputs: ["name": .text(name)]) {
            $0.text("scope") != "Distributed" && $0.text("name").trimmingCharacters(in: .whitespaces) == name
        }
    }

    // MARK: System

    private func armSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.system(.sleep) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.system(.wake) }
        })
        // Power: a run-loop source the system signals, not a poll.
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let triggers = Unmanaged<FlowTriggers>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { triggers.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        lastPower = PowerSource.current()
    }

    private func system(_ event: Catalog.SystemTrigger, battery: Int? = nil) {
        let outputs: [String: Value] = battery.map { ["battery": .number(Double($0))] } ?? [:]
        fire(.system, outputs: outputs) { $0.text("event") == event.rawValue }
    }

    /// macOS posts a power notification each time the charge moves, so the
    /// hats fire on an edge — the cable going in or out, the level crossing
    /// the line — not on the notification.
    private func powerChanged() {
        let now = PowerSource.current()
        let before = lastPower
        lastPower = now
        switch now.adapterEvent(since: before) {
        case .connected?: system(.powerOn, battery: now.percent)
        case .disconnected?: system(.powerOff, battery: now.percent)
        case nil: break
        }
        fire(.battery, outputs: ["battery": now.percent.map { .number(Double($0)) } ?? .nothing]) { hat in
            now.fell(below: Int(hat.number("below")), since: before)
        }
    }
}

// MARK: - Reading hats

extension Block {
    /// A hat's setting as text: its typed value, or the definition's default.
    func text(_ port: String) -> String {
        if let value = inputs[port]?.literal { return value.coerced(to: .text)?.text ?? "" }
        return Catalog.definition(definition)?.input(port)?.defaultValue.coerced(to: .text)?.text ?? ""
    }

    func number(_ port: String) -> Double {
        if let value = inputs[port]?.literal?.coerced(to: .number)?.number { return value }
        return Catalog.definition(definition)?.input(port)?.defaultValue.number ?? 0
    }
}

/// What the app input of an App hat names: an app by bundle identifier, or a
/// command-line process by name. Bundle identifiers always have a dot.
enum AppTarget: Equatable {
    case bundle(String)
    case process(String)

    init(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        self = trimmed.contains(".") ? .bundle(trimmed) : .process(trimmed)
    }

    func matches(bundleID: String, executable: String) -> Bool {
        switch self {
        case .bundle(let id): return !id.isEmpty && id == bundleID
        case .process(let name): return !name.isEmpty && name.caseInsensitiveCompare(executable) == .orderedSame
        }
    }
}

/// A hat's key combination, kept as JSON text in its input.
enum HotkeyValue {
    static func shortcut(_ text: String) -> Shortcut? {
        guard let data = text.data(using: .utf8), let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data),
              shortcut.isValid else { return nil }
        return shortcut
    }

    static func text(_ shortcut: Shortcut?) -> String {
        guard let shortcut, let data = try? JSONEncoder().encode(shortcut) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// An At-a-time hat's days and minute.
struct Schedule: Equatable {
    /// Minutes after midnight.
    var minute: Int
    /// 1 Sunday … 7 Saturday, `Calendar`'s numbering.
    var weekdays: Set<Int>

    init(minute: Int, weekdays: Set<Int>) {
        self.minute = minute
        self.weekdays = weekdays
    }

    init(_ hat: Block) {
        minute = Int(hat.number("time"))
        weekdays = Schedule.days(hat.text("days"))
    }

    static func days(_ text: String) -> Set<Int> {
        Set(text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...7).contains($0) })
    }

    static func text(_ days: Set<Int>) -> String { days.sorted().map(String.init).joined(separator: ",") }

    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        return weekdays.compactMap { weekday -> Date? in
            var wanted = DateComponents()
            wanted.hour = minute / 60
            wanted.minute = minute % 60
            wanted.weekday = weekday
            return calendar.nextDate(after: date, matching: wanted, matchingPolicy: .nextTime)
        }.min()
    }

    static func summary(_ days: Set<Int>) -> String {
        if days == [2, 3, 4, 5, 6] { return "weekdays" }
        if days.count == 7 { return "every day" }
        if days == [1, 7] { return "weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return days.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
    }

    static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

// MARK: - Folder watching

/// One folder, watched by the kernel.
///
/// `FSEventStream` is the event-driven route: the kernel posts changes to a
/// dispatch queue and nothing runs in between. The latency argument is a
/// coalescing window for bursts, not a polling interval.
/// `@unchecked Sendable`: `known` is set in `start()` before the stream exists
/// and from then on touched only on `queue`; the stream is made and torn down
/// on the main thread.
final class FolderWatcher: @unchecked Sendable {
    private let path: String
    private let onNewFiles: @MainActor ([URL]) -> Void
    private var stream: FSEventStreamRef?
    private var known: Set<String> = []
    private let queue = DispatchQueue(label: "com.dhilanpatel.gruppen.folderwatch")

    init(path: String, onNewFiles: @escaping @MainActor ([URL]) -> Void) {
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
        Task { @MainActor [weak self] in self?.onNewFiles(arrived) }
    }

    private func currentFiles() -> [URL] { FileFacts.regularFiles(in: URL(fileURLWithPath: path)) }
}

// MARK: - Notifications

/// System banners, without pulling in a framework that refuses to work outside a
/// signed bundle.
///
/// `UNUserNotificationCenter` throws if the process has no bundle identifier —
/// which is exactly the case in a test harness — so every call is guarded and
/// simply does nothing when notifications are unavailable.
@MainActor
enum Notifier {
    static func post(title: String, body: String, report: @escaping @Sendable (String?) -> Void = { _ in }) {
        guard Bundle.main.bundleIdentifier != nil else {
            report("notifications need a bundled app")
            return
        }
        NotifierBridge.post(title: title, body: body, report: report)
    }
}
