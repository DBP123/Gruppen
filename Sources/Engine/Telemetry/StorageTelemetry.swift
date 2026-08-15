import Darwin
import Foundation
import IOKit
import IOKit.storage

/// The internal drive: how it is carved up, and what is moving through it.
///
/// Two entirely separate sources, because they answer different questions:
///
/// - **Capacity** comes from `URLResourceValues` on the boot volume. APFS does
///   not have fixed partition sizes — a container's volumes share free space —
///   so "how big is the Data volume" is not a meaningful question and the API
///   deliberately does not answer it. What it does answer is what matters: how
///   much is genuinely free, and how much of what looks used is *purgeable*.
/// - **Throughput** comes from `IOBlockStorageDriver`'s `Statistics`, which
///   carries cumulative bytes and operation counts. Both are differenced, so
///   bytes give MB/s and operations give IOPS off the same reading.
final class StorageSampler: TelemetrySampler {
    struct Reading: Equatable {
        // Capacity, in bytes.
        var total: UInt64
        var free: UInt64
        /// Space macOS could reclaim under pressure — caches, local snapshots,
        /// purgeable files. It reads as "used" in Finder and is not really.
        var purgeable: UInt64
        var used: UInt64 { total > free ? total - free : 0 }
        /// What is left once the purgeable part is given back.
        var effectiveFree: UInt64 { free &+ purgeable }

        // Live I/O.
        var readRate: Double
        var writeRate: Double
        var readOps: Double
        var writeOps: Double
        /// Cumulative since boot.
        var readTotal: UInt64
        var writeTotal: UInt64
        var errors: UInt64

        var identity: StorageIdentity?
    }

    /// The counters `Statistics` reports, summed across every block device.
    private struct Counters {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var opsRead: UInt64 = 0
        var opsWritten: UInt64 = 0
        var errors: UInt64 = 0
    }

    private var previous: (counters: Counters, at: Date)?
    /// The purgeable figure, and when it was taken.
    private var purgeableCache: (bytes: UInt64, at: Date)?

    /// How often the expensive capacity key is allowed to run.
    ///
    /// Purgeable space is caches and snapshots — it moves over minutes, not
    /// over half-seconds, so re-deriving it twice a second bought nothing and
    /// cost everything.
    private static let purgeableInterval: TimeInterval = 15

    func sample() -> Reading? {
        let now = Date()
        let counters = Self.counters()
        defer { previous = (counters, now) }

        var rates = (read: 0.0, write: 0.0, readOps: 0.0, writeOps: 0.0)
        if let previous {
            let elapsed = now.timeIntervalSince(previous.at)
            if elapsed > 0.05 {
                func rate(_ new: UInt64, _ old: UInt64) -> Double {
                    new >= old ? Double(new - old) / elapsed : 0
                }
                rates = (rate(counters.bytesRead, previous.counters.bytesRead),
                         rate(counters.bytesWritten, previous.counters.bytesWritten),
                         rate(counters.opsRead, previous.counters.opsRead),
                         rate(counters.opsWritten, previous.counters.opsWritten))
            }
        }

        let capacity = Self.capacity()
        // Only the purgeable half is throttled; total and free are free.
        if purgeableCache == nil
            || now.timeIntervalSince(purgeableCache!.at) >= Self.purgeableInterval {
            purgeableCache = (Self.purgeable(freeNow: capacity.free), now)
        }

        return Reading(total: capacity.total,
                       free: capacity.free,
                       purgeable: purgeableCache?.bytes ?? 0,
                       readRate: rates.read,
                       writeRate: rates.write,
                       readOps: rates.readOps,
                       writeOps: rates.writeOps,
                       readTotal: counters.bytesRead,
                       writeTotal: counters.bytesWritten,
                       errors: counters.errors,
                       identity: StorageIdentity.shared)
    }

    /// Bytes and operations, summed over every block storage driver.
    ///
    /// Summed rather than picked, because a Mac publishes several — the internal
    /// drive, any disk image mounted, external volumes — and I/O is I/O. The
    /// idle ones report zeroes and cost nothing.
    private static func counters() -> Counters {
        var total = Counters()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return total }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }

            func value(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            total.bytesRead &+= value("Bytes (Read)")
            total.bytesWritten &+= value("Bytes (Write)")
            total.opsRead &+= value("Operations (Read)")
            total.opsWritten &+= value("Operations (Write)")
            total.errors &+= value("Errors (Read)") &+ value("Errors (Write)")
        }
        return total
    }

    /// Total and free. Both are cheap — 0.005 ms for the pair — because APFS
    /// already knows them.
    private static func capacity() -> (total: UInt64, free: UInt64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacity
        else { return (0, 0) }
        return (UInt64(max(total, 0)), UInt64(max(free, 0)))
    }

    /// Space macOS would reclaim under pressure.
    ///
    /// `…ForImportantUsage` is what would be free if everything purgeable were
    /// given back, so the pool is the difference against what is free now. It is
    /// also, on its own, **6.18 ms** — measured against 0.005 ms for the other
    /// two capacity keys together, because the system walks caches and snapshots
    /// to answer it rather than reading a number APFS already has. At 2 Hz that
    /// one key was costing more than the entire rest of the app's telemetry
    /// combined, which is why it is on a fifteen-second clock instead of the
    /// sampling tick.
    private static func purgeable(freeNow free: UInt64) -> UInt64 {
        guard let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let important = values.volumeAvailableCapacityForImportantUsage
        else { return 0 }
        let reclaimable = UInt64(max(important, 0))
        return reclaimable > free ? reclaimable - free : 0
    }
}

/// What the drive says it is. Read once — none of it changes while the machine
/// is running, and each read is a registry match.
struct StorageIdentity: Equatable {
    var model: String
    var protocolName: String
    var firmware: String
    /// Whether the drive publishes a SMART interface at all.
    var smartCapable: Bool

    static let shared: StorageIdentity? = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IONVMeController"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func string(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }
        // "Physical Interconnect" on Apple Silicon reads "Apple Fabric" rather
        // than "PCIe": the ANS controller hangs off the SoC fabric, not a PCIe
        // root port, so quoting a PCIe generation here would be made up.
        let link = string("Physical Interconnect") ?? "NVMe"
        let revision = string("NVMe Revision Supported").map { "NVMe \($0)" } ?? "NVMe"
        return StorageIdentity(model: string("Model Number") ?? "Internal drive",
                               protocolName: "\(link) · \(revision)",
                               firmware: string("Firmware Revision") ?? "—",
                               smartCapable: smartInterfacePresent())
    }()

    /// The drive advertises `NVMeSMARTLib.plugin`, which is how a SMART client
    /// reaches temperature, power-on hours and data-units-written.
    ///
    /// Gruppen reports whether that interface exists but does not yet read
    /// through it: it is a COM-style plug-in whose vtable has to be declared
    /// byte-exactly from a header Swift does not import, and a wrong layout is a
    /// crash rather than a bad number. Wear figures wait for that to be done
    /// properly.
    private static func smartInterfacePresent() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IONVMeBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let plugins = IORegistryEntryCreateCFProperty(service, "IOCFPlugInTypes" as CFString,
                                                      kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return plugins?.values.contains { "\($0)".contains("NVMeSMART") } ?? false
    }
}

@MainActor
final class StorageTelemetryWidget: TelemetryModule<StorageSampler> {
    init() { super.init(kind: .storage, sampler: StorageSampler()) }

    /// The plot follows total traffic, so one trace shows the drive working
    /// whichever direction it is working in.
    override func historyValue(for reading: StorageSampler.Reading) -> Double? {
        reading.readRate + reading.writeRate
    }

    override var pinnedSummary: String? {
        reading.map { Format.rate($0.readRate + $0.writeRate) }
    }

    override var pinnedStack: (String, String)? {
        reading.map { ("↓\(Format.rate($0.readRate))", "↑\(Format.rate($0.writeRate))") }
    }
}
