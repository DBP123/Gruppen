import Foundation
import IOKit.ps

/// The Mac's power source as `IOPowerSources` reports it — the charge, whether
/// it is going up, whether the adapter is in — in one read.
///
/// One reader, because there were three: the thermal sampler's and two in the
/// trigger coordinator, which disagreed on rounding (19.6% was 20% in the panel
/// and 19% to a "battery below 20%" trigger).
struct PowerSource: Equatable {
    /// Nil on a Mac without an internal battery.
    var percent: Int?
    var isCharging = false
    /// True without a battery: a desktop Mac is always on the wall.
    var onExternalPower = true
    /// To full when charging, to empty when not; nil while macOS is still
    /// working it out.
    var minutesRemaining: Int?

    static func current() -> PowerSource {
        var source = PowerSource()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return source }
        for entry in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, entry)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            source.percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : nil
            source.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            source.onExternalPower = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            // -1 means "still working it out", which is not worth showing.
            let key = source.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let minutes = description[key] as? Int, minutes > 0 { source.minutesRemaining = minutes }
            break
        }
        return source
    }

    /// The adapter going in or coming out since `before` — and nothing when it
    /// did not. macOS posts a power-source change whenever the charge moves,
    /// so "the power changed" is not the same as "the power was connected".
    func adapterEvent(since before: PowerSource?) -> AdapterChange? {
        guard let before, before.onExternalPower != onExternalPower else { return nil }
        return onExternalPower ? .connected : .disconnected
    }

    enum AdapterChange: Equatable, Sendable { case connected, disconnected }

    /// The charge falling past `threshold` since `before`: on the way down
    /// only, so a Mac sitting at 19% does not fire on every notification.
    func fell(below threshold: Int, since before: PowerSource?) -> Bool {
        guard let percent, percent < threshold else { return false }
        return (before?.percent ?? threshold) >= threshold
    }
}
