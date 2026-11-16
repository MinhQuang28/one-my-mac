@testable import HardwareKit
import XCTest

final class BatterySnapshotTests: XCTestCase {
    /// Shape seen on macOS 26: capacities only inside BatteryData, no top-level Temperature,
    /// amperage as an unsigned 64-bit pattern.
    func testNestedCapacitiesAndFallbackTemperature() {
        let dict: [String: Any] = [
            "CurrentCapacity": 85, "MaxCapacity": 100, "CycleCount": 127,
            "IsCharging": false, "ExternalConnected": false, "FullyCharged": false,
            "AvgTimeToEmpty": 243, "Voltage": 12_000,
            "Amperage": NSNumber(value: UInt64(bitPattern: -500)),
            "BatteryData": ["DesignCapacity": 6075, "AppleRawMaxCapacity": 5670] as [String: Any],
        ]
        let b = BatterySnapshot(registry: dict, fallbackTemperature: 30.2)
        XCTAssertEqual(b.percent, 85)
        XCTAssertEqual(b.designCapacity, 6075)
        XCTAssertEqual(b.maxCapacity, 5670)
        XCTAssertEqual(b.healthPercent!, 93.33, accuracy: 0.01)
        XCTAssertEqual(b.temperature, 30.2)
        XCTAssertEqual(b.watts!, -6.0, accuracy: 0.001)
        XCTAssertEqual(b.minutesRemaining, 243)
    }

    func testTopLevelTemperatureWinsAndEstimatingTimeIsNil() {
        let dict: [String: Any] = ["CurrentCapacity": 50, "Temperature": 3125, "TimeRemaining": 65535]
        let b = BatterySnapshot(registry: dict, fallbackTemperature: 20)
        XCTAssertEqual(b.temperature, 31.25)
        XCTAssertNil(b.minutesRemaining)
        XCTAssertNil(b.healthPercent)
    }
}

final class ThermalSnapshotTests: XCTestCase {
    func testDieSensorsDriveCPUAndBatterySensorIsSeparate() {
        let t = ThermalSnapshot(sensors: [("PMU tdie1", 50), ("PMU tdie2", 60), ("PMU tdev1", 90),
                                          ("gas gauge battery", 31)], smcBattery: nil)
        XCTAssertEqual(t.cpuAverage, 55)
        XCTAssertEqual(t.cpuHottest, 60)
        XCTAssertEqual(t.battery, 31)
    }

    func testFallsBackToAllNonBatterySensors() {
        let t = ThermalSnapshot(sensors: [("SOC MTR Temp", 40), ("battery", 30)], smcBattery: 29)
        XCTAssertEqual(t.cpuHottest, 40)
        XCTAssertEqual(t.battery, 29)
    }
}

final class ChargeLimitClientTests: XCTestCase {
    func testLimitCountsOnlyWhenEnabledAndBelowFull() {
        XCTAssertEqual(ChargeLimitClient.activeLimit(enabled: 1, limit: 85), 85)
        XCTAssertNil(ChargeLimitClient.activeLimit(enabled: 0, limit: 85))
        XCTAssertNil(ChargeLimitClient.activeLimit(enabled: 1, limit: 100))
        XCTAssertNil(ChargeLimitClient.activeLimit(enabled: 1, limit: 0))
    }
}

final class SystemUsageSamplerTests: XCTestCase {
    func testCPUPercentIsBusyShareAcrossCores() {
        let old = [CoreTicks(user: 100, system: 50, idle: 800, nice: 0), CoreTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let new = [CoreTicks(user: 130, system: 60, idle: 860, nice: 0), CoreTicks(user: 0, system: 0, idle: 100, nice: 0)]
        XCTAssertEqual(SystemUsageSampler.cpuPercent(from: old, to: new)!, 20, accuracy: 0.001)
    }

    func testCPUPercentSurvivesCounterWrapAndRejectsMismatch() {
        let old = [CoreTicks(user: .max - 9, system: 0, idle: .max - 29, nice: 0)]
        let new = [CoreTicks(user: 10, system: 0, idle: 50, nice: 0)]
        XCTAssertEqual(SystemUsageSampler.cpuPercent(from: old, to: new)!, 20, accuracy: 0.001)
        XCTAssertNil(SystemUsageSampler.cpuPercent(from: old, to: new + new))
        XCTAssertNil(SystemUsageSampler.cpuPercent(from: new, to: new))
    }

    func testRAMPercentCountsAppWiredAndCompressed() {
        let percent = SystemUsageSampler.ramPercent(internalPages: 500, purgeablePages: 100, wiredPages: 200,
                                                    compressedPages: 100, pageSize: 16_384,
                                                    physicalBytes: 1000 * 16_384)
        XCTAssertEqual(percent!, 70, accuracy: 0.001)
        XCTAssertNil(SystemUsageSampler.ramPercent(internalPages: 1, purgeablePages: 0, wiredPages: 0,
                                                   compressedPages: 0, pageSize: 16_384, physicalBytes: 0))
    }

    func testLiveSampleNeedsTwoReadingsForCPU() {
        let sampler = SystemUsageSampler()
        XCTAssertNil(sampler.sample(includeGPU: false).cpu)
        Thread.sleep(forTimeInterval: 0.2)
        let second = sampler.sample(includeGPU: false)
        XCTAssertNotNil(second.cpu)
        XCTAssertNotNil(second.ram)
        XCTAssertNil(second.gpu)
    }
}
