import Darwin
import Foundation

/// Watches for raw Unix processes starting.
///
/// **Why this exists.** `NSWorkspace.didLaunchApplicationNotification` fires
/// only for bundled `.app` applications. A `python3` started in Terminal, a
/// `java` started by a launcher, a background helper — none of them are
/// applications, so none of them produce a notification. That is not a bug in
/// the observation code; it is what the notification is for.
///
/// **Why this polls, and why that is not a contradiction.** macOS has exactly
/// one event-driven source for "any process just executed": the Endpoint
/// Security framework, and `ES_EVENT_TYPE_NOTIFY_EXEC` requires the
/// `com.apple.developer.endpoint-security.client` entitlement, which Apple
/// grants per-team and which needs the app to run with privileges. An app
/// distributed as an ad-hoc-signed download cannot have it. Everything else —
/// `libproc`, `sysctl(KERN_PROC)`, `NSWorkspace` — answers "what is running
/// *now*", which means a launch can only be found by comparing two answers.
///
/// So this is a diff, and the honesty is in when it runs:
///
/// * **Nothing armed → nothing exists.** No timer, no queue work, no memory.
///   This is the normal state and it costs exactly zero.
/// * **Armed → one `proc_listallpids` call every two seconds**, on a background
///   serial queue, inside an autorelease pool. The scan compares pid sets; a
///   path lookup happens only for pids that are *new*, which is almost always
///   none.
///
/// The alternative was to claim raw-process detection and not deliver it. This
/// delivers it, states its cost, and charges that cost only to the person who
/// asked for it by arming such a trigger.
final class ProcessMonitor: @unchecked Sendable {
    /// How often the process table is compared, while armed.
    private static let interval: DispatchTimeInterval = .seconds(2)
    private static let leeway: DispatchTimeInterval = .milliseconds(500)

    /// Called on the main queue with the executable name and pid of anything
    /// that appeared since the previous scan and matched a watched name.
    private let onLaunch: (String, pid_t) -> Void

    /// Lower-cased names being watched. A `Set` of small strings; the whole
    /// structure is a few hundred bytes.
    private var watched: Set<String> = []
    /// Pids seen by the previous scan. `pid_t` is an `Int32`; a machine with
    /// 600 processes costs about 5KB here and nothing else is retained.
    private var known: Set<pid_t> = []

    private let queue = DispatchQueue(label: "com.dhilanpatel.gruppen.processmonitor",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?

    init(onLaunch: @escaping (String, pid_t) -> Void) {
        self.onLaunch = onLaunch
    }

    deinit { timer?.cancel() }

    /// Arms the monitor for a set of executable names. An empty set disarms it
    /// completely — no timer, no state.
    func watch(_ names: Set<String>) {
        queue.async { [self] in
            let lowered = Set(names.map { $0.lowercased() }.filter { !$0.isEmpty })
            guard lowered != watched else { return }
            watched = lowered

            guard !lowered.isEmpty else { stopLocked(); return }
            // Everything running right now is the baseline, not an arrival.
            known = Self.currentPids()
            startLocked()
        }
    }

    func stop() {
        queue.async { [self] in
            watched.removeAll()
            stopLocked()
        }
    }

    // MARK: - Private, all on `queue`

    private func startLocked() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: the kernel is free to coalesce these with other
        // wake-ups rather than waking the CPU on our behalf, which is most of
        // the difference between a cheap periodic task and an expensive one.
        timer.schedule(deadline: .now() + Self.interval,
                       repeating: Self.interval,
                       leeway: Self.leeway)
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        self.timer = timer
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        known.removeAll()
    }

    /// One comparison. Everything here is value types and one syscall.
    private func scan() {
        autoreleasepool {
            let current = Self.currentPids()
            defer { known = current }
            guard !watched.isEmpty else { return }

            let arrived = current.subtracting(known)
            guard !arrived.isEmpty else { return }

            // Two cheap lookups per *new* pid only — typically zero, and
            // occasionally one or two.
            var matches: [(String, pid_t)] = []
            for pid in arrived {
                for name in watched where Self.matches(pid: pid, name: name) {
                    matches.append((name, pid))
                }
            }
            guard !matches.isEmpty else { return }

            let callback = onLaunch
            DispatchQueue.main.async {
                for (name, pid) in matches { callback(name, pid) }
            }
        }
    }

    /// Every pid on the system, as a set of `Int32`.
    static func currentPids() -> Set<pid_t> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let filled = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            proc_listallpids(pointer.baseAddress,
                             Int32(pointer.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        // Measured: the fill call reports a *count* on this platform, but the
        // header documents bytes. Clamping to the buffer makes both readings
        // safe, and the zero filter drops the slack either way.
        let usable = min(Int(filled), buffer.count)
        return Set(buffer.prefix(usable).filter { $0 > 0 })
    }

    /// Whether a process answers to `name`, by either of the two names it has.
    ///
    /// **The bug this exists for.** `/usr/bin/python3` is a stub that re-execs
    /// into the framework binary, so `proc_pidpath` reports the executable as
    /// `Python` — measured. Someone watching for `python3` would never match,
    /// which is exactly the failure that was reported. The name a person types
    /// is the name they *invoked*, which is `argv[0]`, so both are checked: the
    /// real executable (catches `java`, `node`) and the invoked name (catches
    /// `python3` and anything else reached through a shim or a symlink).
    static func matches(pid: pid_t, name: String) -> Bool {
        let wanted = name.lowercased()
        guard !wanted.isEmpty else { return false }

        if executableName(of: pid)?.lowercased() == wanted { return true }
        if invokedName(of: pid)?.lowercased() == wanted { return true }

        // Last resort, and the one that actually catches `python3`. Measured on
        // this machine: `/usr/bin/python3` re-execs into
        // `…/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python`
        // and rewrites argv[0] to that same path, so *neither* name contains the
        // word the user typed. The path does. Matching whole path components —
        // and `name.` prefixes, for `Python3.framework` — finds it without the
        // false positives a raw substring search would bring: watching `node`
        // will not match `/usr/local/nodejs/bin/foo`, because no component is
        // `node` or begins with `node.`.
        guard let path = executablePath(of: pid)?.lowercased() else { return false }
        return path.split(separator: "/").contains { component in
            component == wanted || component.hasPrefix(wanted + ".")
        }
    }

    /// `argv[0]`, as the process was actually invoked.
    ///
    /// `KERN_PROCARGS2` lays the block out as `[argc: Int32][executable path]
    /// [NUL padding][argv[0]][argv[1]]…`, so this walks the executable path,
    /// skips the padding, and takes the string that follows.
    static func invokedName(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        guard index < size else { return nil }

        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
        guard let argv0 = String(bytes: bytes, encoding: .utf8), !argv0.isEmpty else { return nil }
        return (argv0 as NSString).lastPathComponent
    }

    /// The last path component of a pid's executable, or nil if it has gone or
    /// is not readable.
    static func executableName(of pid: pid_t) -> String? {
        executablePath(of: pid).map { ($0 as NSString).lastPathComponent }
    }

    /// The full path of a pid's executable.
    static func executablePath(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        let length = path.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        let full = String(cString: path)
        return full.isEmpty ? nil : full
    }

    /// Pids currently running under a given executable name. One pass, used
    /// when arming an exit watcher.
    static func pids(named name: String) -> [pid_t] {
        currentPids().filter { matches(pid: $0, name: name) }
    }
}
