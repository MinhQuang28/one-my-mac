import Foundation

/// One reading of the AppleSmartBattery registry entry, normalised.
///
/// Recent macOS releases moved `DesignCapacity`, `NominalChargeCapacity` and the raw capacities into
/// the nested `BatteryData` dictionary and dropped the top-level `Temperature`; every field here is
/// looked up in both places, and temperature falls back to the SMC / HID battery sensor.
public struct BatterySnapshot: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    public var cycleCount: Int
    /// Minutes to empty / full; nil while macOS is still estimating.
    public var minutesRemaining: Int?
    /// Battery power in watts: negative while discharging.
    public var watts: Double?
    public var designCapacity: Int?
    public var maxCapacity: Int?
    public var temperature: Double?
    public var adapterWatts: Int?
    public var adapterName: String?

    /// Real wear: raw full-charge capacity over design capacity, in percent.
    public var healthPercent: Double? {
        guard let design = designCapacity, design > 0, let max = maxCapacity, max > 0 else { return nil }
        return min(100, Double(max) / Double(design) * 100)
    }

    /// Charge in percent. `CurrentCapacity` is a percentage on Apple Silicon (`MaxCapacity` is 100
    /// there) but mAh on Intel, so it is always read as a share of `MaxCapacity`; without that key a
    /// value above 100 can only be mAh and is measured against the raw full-charge capacity.
    static func percent(current: Int?, max: Int?, rawMax: Int?) -> Int {
        guard let current else { return 0 }
        let full = max.flatMap { $0 > 0 ? $0 : nil } ?? (current > 100 ? rawMax : nil)
        guard let full, full > 0 else { return Swift.min(Swift.max(current, 0), 100) }
        return Swift.min(Swift.max(Int((Double(current) / Double(full) * 100).rounded()), 0), 100)
    }

    public init(registry dict: [String: Any], fallbackTemperature: Double?) {
        let nested = dict["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            if let n = dict[key] as? NSNumber { return n.intValue }
            if let n = nested[key] as? NSNumber { return n.intValue }
            return nil
        }
        /// Amperage is reported as an unsigned 64-bit pattern of a signed value.
        func signed(_ key: String) -> Int64? {
            guard let n = (dict[key] ?? nested[key]) as? NSNumber else { return nil }
            return Int64(bitPattern: n.uint64Value)
        }

        let rawMax = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("FullChargeCapacity")
        percent = Self.percent(current: int("CurrentCapacity"), max: int("MaxCapacity"), rawMax: rawMax)
        isCharging = dict["IsCharging"] as? Bool ?? false
        isPluggedIn = dict["ExternalConnected"] as? Bool ?? false
        isFullyCharged = dict["FullyCharged"] as? Bool ?? false
        cycleCount = int("CycleCount") ?? 0

        let remaining = isCharging ? int("AvgTimeToFull") : int("AvgTimeToEmpty")
        let fallback = int("TimeRemaining")
        let minutes = remaining ?? fallback
        minutesRemaining = (minutes.map { $0 > 0 && $0 < 65535 } ?? false) ? minutes : nil

        if let mV = int("Voltage"), let mA = signed("InstantAmperage") ?? signed("Amperage") {
            let w = Double(mV) * Double(mA) / 1_000_000
            watts = abs(w) < 0.05 ? 0 : w
        } else {
            watts = nil
        }

        designCapacity = int("DesignCapacity")
        maxCapacity = rawMax

        if let raw = int("Temperature") ?? int("VirtualTemperature"), raw > 0 {
            temperature = Double(raw) / 100
        } else {
            temperature = fallbackTemperature
        }

        let adapter = dict["AdapterDetails"] as? [String: Any]
        adapterWatts = (adapter?["Watts"] as? NSNumber)?.intValue
        adapterName = adapter?["Name"] as? String
    }
}
