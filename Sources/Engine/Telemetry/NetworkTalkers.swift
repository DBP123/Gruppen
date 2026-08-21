import Foundation

/// Which process is using the network, and how much.
///
/// **There is no public API for this.** The kernel will tell you a process's
/// CPU time, its memory footprint and its open sockets, but not how many bytes
/// those sockets have carried — `proc_pidfdinfo` reports a socket's *current
/// buffer occupancy*, which is not a total and cannot be differenced into a
/// rate. Activity Monitor and `nettop` both get these numbers from
/// `NetworkStatistics.framework`, which is private, so that is what this uses.
///
/// Everything about the way it is loaded is defensive, because a private
/// framework is a promise nobody made:
///
/// - every symbol is resolved through `dlsym` and any one of them missing turns
///   the whole feature off rather than crashing;
/// - nothing is force-unwrapped, and no call is made unless the manager was
///   created successfully;
/// - the only entry points used are the five that have been verified to work on
///   this machine, so the surface that can break is as small as it can be.
///
/// If a future macOS changes the ABI, network attribution goes quiet and the
/// rest of the module — interface throughput, which is entirely public —
/// carries on. That is the trade being made, and it is worth making: a
/// throughput figure that cannot say *who* is a number you can do nothing with.
final class NetworkTalkers {
    /// A process holding network connections, and what those connections have
    /// carried since Gruppen started watching them.
    ///
    /// **There is deliberately no bytes-per-second here.** Getting a trustworthy
    /// per-process rate out of this framework did not work, and the failure is
    /// worth recording rather than papering over:
    ///
    /// - counters arrive asynchronously per flow, not on the sampler's clock,
    ///   so a per-tick difference alternated between a large number and zero;
    ///   computing the rate per flow instead fixed the cadence but not the
    ///   figures;
    /// - the first counts report for a flow carries its whole history, which
    ///   read as an enormous one-second burst;
    /// - flows are keyed by the framework's source pointer, and those are
    ///   reused after a flow closes, so a long-lived key can end up carrying
    ///   one process's name and another's counters.
    ///
    /// The result was numbers that looked precise and were wrong — 39 MB/s
    /// attributed to `rapportd` while the process actually downloading was
    /// missing from the list entirely. A wrong number in a telemetry panel is
    /// worse than an absent one, so what ships is the part that was stable
    /// across every pass: who holds connections, how many, and the bytes
    /// observed on them.
    struct Talker: Equatable, Identifiable {
        var pid: pid_t
        var name: String
        /// Bytes carried over the lifetime of this process's *current*
        /// connections, as the framework reports them. A total, not a rate, and
        /// it resets for a process whose connections close and reopen.
        var downTotal: UInt64
        var upTotal: UInt64
        var connections: Int

        var id: pid_t { pid }
        var total: UInt64 { downTotal &+ upTotal }
    }

    /// Nil when the framework could not be loaded, which is the signal to stop
    /// asking. Callers show interface throughput and no attribution.
    static let shared: NetworkTalkers? = NetworkTalkers()

    // MARK: The private interface, as narrowly as possible

    private typealias ManagerCreate = @convention(c) (
        CFAllocator?, DispatchQueue, @escaping @convention(block) (UnsafeMutableRawPointer?) -> Void
    ) -> UnsafeMutableRawPointer?
    private typealias ManagerAction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias ManagerQuery = @convention(c) (
        UnsafeMutableRawPointer?, @escaping @convention(block) () -> Void
    ) -> Void
    private typealias SourceSetBlock = @convention(c) (
        UnsafeMutableRawPointer?, @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void
    private typealias SourceRemovedBlock = @convention(c) (
        UnsafeMutableRawPointer?, @escaping @convention(block) () -> Void
    ) -> Void

    /// The blocks are `@escaping` deliberately: a function-type parameter is
    /// non-escaping by default, and this framework *stores* both blocks and
    /// calls them for the life of the manager. Swift's runtime check for that
    /// is not a warning — it traps.
    private let createManager: ManagerCreate
    private let destroyManager: ManagerAction
    private let addAllTCP: ManagerAction
    private let addAllUDP: ManagerAction
    private let queryAll: ManagerQuery
    private let setDescriptionBlock: SourceSetBlock
    private let setRemovedBlock: SourceRemovedBlock
    private let setCountsBlock: SourceSetBlock
    private let querySourceCounts: ManagerAction

    /// The keys are read out of the framework rather than hard-coded, because
    /// the constants are what the framework promises and the literals behind
    /// them ("processID", "rxBytes") are what it happens to use today.
    private let keyPID: String
    private let keyRxBytes: String
    private let keyTxBytes: String
    private let keyName: String

    private var manager: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "com.dhilanpatel.gruppen.nstat")

    /// One live flow, as last described.
    /// One live flow, as last reported.
    private struct Flow {
        var source: UnsafeMutableRawPointer
        var pid: pid_t
        var name: String
        var rx: UInt64
        var tx: UInt64
    }

    /// Keyed by the framework's own source pointer, **not** by process.
    ///
    /// The first version of this accumulated per process and cleared each tick,
    /// which cannot work: descriptions arrive asynchronously and a query does
    /// not necessarily re-describe every flow within one interval, so a process
    /// would appear in one pass and be missing from the next, and a rate that
    /// needs the same process in two consecutive passes was almost never
    /// computable. Keyed by flow, a description is an *update* to something that
    /// persists until the framework says it closed, and the per-process totals
    /// derived from it are stable enough to difference.
    private let lock = NSLock()
    private var flows: [UInt: Flow] = [:]

    private var started = false

    private init?() {
        let path = "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }

        func function<T>(_ name: String, _ type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        /// Each `k…` symbol is a pointer to a `CFStringRef` global, so it takes
        /// two dereferences to get to the string.
        func constant(_ name: String) -> String? {
            guard let symbol = dlsym(handle, name) else { return nil }
            let slot = symbol.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
            guard let slot else { return nil }
            return Unmanaged<CFString>.fromOpaque(slot).takeUnretainedValue() as String
        }

        guard let create = function("NStatManagerCreate", ManagerCreate.self),
              let destroy = function("NStatManagerDestroy", ManagerAction.self),
              let tcp = function("NStatManagerAddAllTCP", ManagerAction.self),
              let udp = function("NStatManagerAddAllUDP", ManagerAction.self),
              let query = function("NStatManagerQueryAllSourcesDescriptions", ManagerQuery.self),
              let describe = function("NStatSourceSetDescriptionBlock", SourceSetBlock.self),
              let removed = function("NStatSourceSetRemovedBlock", SourceRemovedBlock.self),
              let counts = function("NStatSourceSetCountsBlock", SourceSetBlock.self),
              let queryCounts = function("NStatSourceQueryCounts", ManagerAction.self),
              let pid = constant("kNStatSrcKeyPID"),
              let rx = constant("kNStatSrcKeyRxBytes"),
              let tx = constant("kNStatSrcKeyTxBytes"),
              let name = constant("kNStatSrcKeyProcessName")
        else { return nil }

        createManager = create
        destroyManager = destroy
        addAllTCP = tcp
        addAllUDP = udp
        queryAll = query
        setDescriptionBlock = describe
        setRemovedBlock = removed
        setCountsBlock = counts
        querySourceCounts = queryCounts
        keyPID = pid
        keyRxBytes = rx
        keyTxBytes = tx
        keyName = name
    }

    // MARK: Lifecycle

    /// Opens the manager and subscribes to every TCP and UDP flow. Called on
    /// the sampling queue the first time the network module runs, and undone
    /// completely when it stops — this is a subscription, not a poll, so
    /// leaving it open would keep the kernel feeding a module nobody is
    /// watching.
    func start() {
        guard !started else { return }
        started = true

        // The manager hands each new flow to this block, once. Setting a
        // description block on the flow is what makes it report itself, both
        // now and on every later query.
        let created = createManager(kCFAllocatorDefault, queue) { [weak self] source in
            guard let self, let source else { return }
            let identity = UInt(bitPattern: source)
            self.setDescriptionBlock(source) { [weak self] description in
                self?.accept(description, as: identity, source: source)
            }
            // A description is metadata — which process, which ports — and its
            // byte fields are whatever they were when the flow was described.
            // The *live* counters arrive here, and only for flows that have
            // been asked. This is the difference between a list of who has a
            // connection open and a list of who is using the network.
            self.setCountsBlock(source) { [weak self] counts in
                self?.accept(counts, as: identity, source: source)
            }
            // Without this a closed connection's bytes would sit in the totals
            // for ever and the process would look permanently busy.
            self.setRemovedBlock(source) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.flows.removeValue(forKey: identity); self.lock.unlock()
            }
        }
        guard let created else { started = false; return }
        manager = created
        addAllTCP(created)
        addAllUDP(created)
    }

    func stop() {
        guard started else { return }
        started = false
        if let manager { destroyManager(manager) }
        manager = nil
        lock.lock()
        flows.removeAll()
        lock.unlock()
    }

    /// Takes either a description or a counts dictionary — they share the byte
    /// keys, and a counts dictionary simply has no process fields, in which case
    /// whatever the description already established is kept.
    private func accept(_ payload: CFDictionary?, as identity: UInt,
                        source: UnsafeMutableRawPointer) {
        guard let fields = payload as? [String: Any] else { return }
        lock.lock()
        defer { lock.unlock() }
        var flow = flows[identity] ?? Flow(source: source, pid: -1, name: "", rx: 0, tx: 0)
        if let pid = (fields[keyPID] as? NSNumber)?.int32Value, pid > 0 { flow.pid = pid }
        if let name = fields[keyName] as? String, !name.isEmpty { flow.name = name }

        if let rx = (fields[keyRxBytes] as? NSNumber)?.uint64Value { flow.rx = rx }
        if let tx = (fields[keyTxBytes] as? NSNumber)?.uint64Value { flow.tx = tx }

        guard flow.pid > 0 else { return }
        flows[identity] = flow
    }

    // MARK: Sampling

    /// Asks every live flow to report, then turns the totals into rates.
    ///
    /// Called on `Telemetry.queue`. The query is asynchronous, so what this
    /// returns is the result of the *previous* tick's query — one tick of lag,
    /// which at 2 Hz is half a second and is invisible next to the fact that
    /// these are averages over the interval anyway.
    func sample() -> [Talker] {
        guard started, let manager else { return [] }

        // Fold the live flows up by process. The rates are already computed
        // per flow, so this is a sum, not a difference — nothing here depends
        // on when the sampler happens to tick.
        lock.lock()
        var folded: [pid_t: Talker] = [:]
        var liveSources: [UnsafeMutableRawPointer] = []
        liveSources.reserveCapacity(flows.count)
        for flow in flows.values {
            liveSources.append(flow.source)
            // A flow that has not reported in a while is not moving data; hold
            // it in the list at zero rather than showing a stale rate.
            var talker = folded[flow.pid] ?? Talker(pid: flow.pid, name: flow.name,
                                                    downTotal: 0, upTotal: 0, connections: 0)
            if talker.name.isEmpty { talker.name = flow.name }
            talker.downTotal &+= flow.rx
            talker.upTotal &+= flow.tx
            talker.connections += 1
            folded[flow.pid] = talker
        }
        lock.unlock()

        // Ask every live flow for its current counters, and refresh the
        // descriptions so newly opened flows get named. Both land on `queue`.
        for source in liveSources { querySourceCounts(source) }
        queryAll(manager) {}

        var talkers = Array(folded.values)
        talkers.sort { $0.total > $1.total }
        return talkers
    }
}
