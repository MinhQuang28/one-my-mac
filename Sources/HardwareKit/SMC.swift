import Foundation
import SMCBridge

/// Read-only Swift view of the SMC. Reading needs no privileges; writing goes through `onemac-fan`.
public enum SMC {
    /// Numeric value of a key, or nil when the key is missing or not numeric.
    public static func number(_ key: String) -> Double? {
        var value = OMSMCValue()
        guard om_smc_read(key, &value) == 0 else { return nil }
        let number = om_smc_value_as_double(&value)
        return number.isFinite ? number : nil
    }

    public static func exists(_ key: String) -> Bool {
        var value = OMSMCValue()
        return om_smc_read(key, &value) == 0
    }
}

/// Static facts and live speed of one fan.
public struct FanInfo: Equatable, Identifiable, Sendable {
    public let id: Int
    public var minRPM: Double
    public var maxRPM: Double
    public var currentRPM: Double
    public var targetRPM: Double
    public var isManual: Bool

    /// Reads fan `index` from the SMC; nil when the machine has no such fan.
    public static func read(_ index: Int) -> FanInfo? {
        guard let maxRPM = SMC.number("F\(index)Mx"), maxRPM > 0 else { return nil }
        return FanInfo(
            id: index,
            minRPM: SMC.number("F\(index)Mn") ?? 0,
            maxRPM: maxRPM,
            currentRPM: max(0, SMC.number("F\(index)Ac") ?? 0),
            targetRPM: SMC.number("F\(index)Tg") ?? 0,
            isManual: (SMC.number("F\(index)Md") ?? 0) == 1)
    }

    /// All fans the SMC reports (`FNum`), at most four.
    public static func readAll() -> [FanInfo] {
        let count = Int(SMC.number("FNum") ?? 0)
        return (0..<min(max(count, 0), 4)).compactMap(read)
    }
}
