import Foundation
import IOKit
import SMCBridge

/// Summary of the chip and battery temperatures.
public struct ThermalSnapshot: Equatable, Sendable {
    public var cpuAverage: Double?
    public var cpuHottest: Double?
    public var battery: Double?
    public var sensorCount: Int

    public static let empty = ThermalSnapshot(cpuAverage: nil, cpuHottest: nil, battery: nil, sensorCount: 0)

    /// Builds the summary from named sensor readings. Die sensors (`tdie`) describe the CPU; when a
    /// chip exposes none, every non-battery sensor is used instead.
    public init(sensors: [(name: String, celsius: Double)], smcBattery: Double?) {
        let lower = sensors.map { (name: $0.name.lowercased(), celsius: $0.celsius) }
        let batterySensors = lower.filter { $0.name.contains("battery") }.map(\.celsius)
        var cpu = lower.filter { $0.name.contains("tdie") }.map(\.celsius)
        if cpu.isEmpty { cpu = lower.filter { !$0.name.contains("battery") }.map(\.celsius) }
        cpuAverage = cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count)
        cpuHottest = cpu.max()
        battery = smcBattery ?? batterySensors.max()
        sensorCount = sensors.count
    }

    init(cpuAverage: Double?, cpuHottest: Double?, battery: Double?, sensorCount: Int) {
        self.cpuAverage = cpuAverage; self.cpuHottest = cpuHottest
        self.battery = battery; self.sensorCount = sensorCount
    }
}

/// Blocking readers; call off the main thread.
enum HardwareReaders {
    static func thermal() -> ThermalSnapshot {
        var buffer = [OMTemperature](repeating: OMTemperature(), count: 96)
        let count = Int(om_hid_read_temperatures(&buffer, Int32(buffer.count)))
        let sensors: [(name: String, celsius: Double)] = buffer.prefix(count).map { item in
            var copy = item
            let name = withUnsafeBytes(of: &copy.name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return (name, item.celsius)
        }
        // TB0T..TB2T are the battery pack sensors on every Apple Silicon laptop seen so far.
        let smcBattery = ["TB0T", "TB1T", "TB2T"].compactMap(SMC.number).filter { $0 > 0 && $0 < 100 }.max()
        return ThermalSnapshot(sensors: sensors, smcBattery: smcBattery)
    }

    static func battery(fallbackTemperature: Double?) -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatterySnapshot(registry: dict, fallbackTemperature: fallbackTemperature)
    }
}
