import CoreGraphics
import XCTest
@testable import HiDisplayKit

/// The pure halves of the SkyLight mode list, the off-main mode switch, and the soft reconnect.
final class HiddenModeAndReconnectTests: XCTestCase {

    private func mode(_ w: Int, _ h: Int, scale: Int = 1, hz: Double = 60) -> DisplayMode {
        DisplayMode(width: w, height: h, pixelWidth: w * scale, pixelHeight: h * scale, refreshRate: hz)
    }

    // MARK: - Merging hidden modes

    func testHiddenHiDPIModeIsAddedWhenCoreGraphicsDoesNotListIt() {
        let listed = [mode(2560, 1440), mode(1920, 1080, scale: 2)]
        let merged = DisplayModeService.merged(listed: listed, hidden: [mode(2560, 1440, scale: 2)])

        XCTAssertTrue(DisplayModeService.hasHiDPIMode(width: 2560, height: 1440, in: merged))
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first?.pixelWidth, 5120, "HiDPI sorts ahead of the 1× twin")
    }

    func testHiddenModeAlreadyListedIsNotDuplicated() {
        // SkyLight reports whole Hz; CoreGraphics reports 59.94 for the same mode.
        let listed = [mode(1920, 1080, scale: 2, hz: 59.94)]
        let merged = DisplayModeService.merged(listed: listed, hidden: [mode(1920, 1080, scale: 2, hz: 60)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].refreshRate, 59.94, "the listed mode wins over its hidden twin")
    }

    func testHiddenModeWithTruncatedRefreshIsNotDuplicated() {
        // Measured on a built-in panel: SkyLight reports 59 and 47 for 59.94 and 47.95 Hz.
        let listed = [mode(1024, 640, scale: 2, hz: 59.94), mode(1024, 640, scale: 2, hz: 47.95)]
        let hidden = [mode(1024, 640, scale: 2, hz: 59), mode(1024, 640, scale: 2, hz: 47)]
        XCTAssertEqual(DisplayModeService.merged(listed: listed, hidden: hidden).count, 2)
    }

    func testHiddenTwinOfAZeroHertzListedModeIsDropped() {
        let listed = [mode(1512, 982, scale: 2, hz: 0)]
        let merged = DisplayModeService.merged(listed: listed, hidden: [mode(1512, 982, scale: 2, hz: 60)])
        XCTAssertEqual(merged, listed)
    }

    func testHiddenOneXModesAreIgnored() {
        let merged = DisplayModeService.merged(listed: [mode(2560, 1440)], hidden: [mode(1234, 777)])
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - Mode description decoding

    private func description(
        number: UInt32, flags: UInt32 = 0, width: UInt32, height: UInt32, hz: UInt16, density: Float
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 212)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: number, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: flags, toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: width, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: height, toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: hz, toByteOffset: 190, as: UInt16.self)
            raw.storeBytes(of: density, toByteOffset: 208, as: Float.self)
        }
        return bytes
    }

    func testDecodesAHiDPIModeDescription() throws {
        let decoded = try XCTUnwrap(SkyLightDisplayShim.decode(
            description(number: 42, width: 2560, height: 1440, hz: 144, density: 2)))
        XCTAssertEqual(decoded.modeNumber, 42)
        XCTAssertEqual(decoded.mode.width, 2560)
        XCTAssertEqual(decoded.mode.pixelWidth, 5120)
        XCTAssertEqual(decoded.mode.pixelHeight, 2880)
        XCTAssertEqual(decoded.mode.refreshRate, 144)
        XCTAssertTrue(decoded.mode.isHiDPI)
    }

    func testRejectsUnusableZeroSizedAndGarbageDescriptions() {
        XCTAssertNil(SkyLightDisplayShim.decode(
            description(number: 1, flags: 0x4000_0000, width: 1920, height: 1080, hz: 60, density: 2)))
        XCTAssertNil(SkyLightDisplayShim.decode(
            description(number: 1, width: 0, height: 1080, hz: 60, density: 2)))
        XCTAssertNil(SkyLightDisplayShim.decode(
            description(number: 1, width: 1920, height: 1080, hz: 60, density: 0)))
        // A layout change would show up as absurd values, not a crash.
        XCTAssertNil(SkyLightDisplayShim.decode(
            description(number: 1, width: 4_000_000, height: 1080, hz: 60, density: 2)))
        XCTAssertNil(SkyLightDisplayShim.decode([UInt8](repeating: 0, count: 100)))
    }

    /// Read-only against whatever is plugged in: every mode the live list yields must be sane.
    func testLiveHiddenModesAreSane() {
        for hidden in SkyLightDisplayShim.shared.modes(for: CGMainDisplayID()) {
            XCTAssertGreaterThanOrEqual(hidden.mode.pixelWidth, hidden.mode.width)
            XCTAssertLessThanOrEqual(hidden.mode.refreshRate, 1000)
        }
    }

    // MARK: - Shape matching

    func testSameShapeToleratesFractionalRefreshButNotScale() {
        XCTAssertTrue(DisplayModeSwitcher.sameShape(
            mode(1920, 1080, scale: 2, hz: 59.94), mode(1920, 1080, scale: 2, hz: 60)))
        XCTAssertFalse(DisplayModeSwitcher.sameShape(mode(1920, 1080, scale: 2), mode(1920, 1080)))
        XCTAssertFalse(DisplayModeSwitcher.sameShape(mode(1920, 1080, hz: 120), mode(1920, 1080, hz: 60)))
        XCTAssertFalse(DisplayModeSwitcher.sameShape(mode(1920, 1080, hz: 59.94), mode(1920, 1080, hz: 59)))
        XCTAssertTrue(DisplayModeSwitcher.sameShape(
            mode(1920, 1080, hz: 59.94), mode(1920, 1080, hz: 59), tolerance: 1))
    }

    // MARK: - Reconnect bookkeeping

    func testPendingReconnectMarkerRoundTripsAndClears() throws {
        let suite = "hidisplay.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(DisplayReconnector.load(defaults).isEmpty)
        let pending = DisplayReconnector.Pending(displayID: 7, vendorID: 0x10AC, productID: 0xA0C4)
        DisplayReconnector.store([pending], defaults)
        XCTAssertEqual(DisplayReconnector.load(defaults), [pending])
        DisplayReconnector.store([], defaults)
        XCTAssertNil(defaults.object(forKey: DisplayReconnector.defaultsKey))
    }

    func testOnlyRealPanelsCountAsViewable() {
        XCTAssertTrue(DisplayReconnector.isViewable(vendor: 0x10AC))
        XCTAssertFalse(DisplayReconnector.isViewable(vendor: 0))
        XCTAssertFalse(DisplayReconnector.isViewable(vendor: 0x756E_6B6E), "'unkn' placeholder display")
    }

    func testWaitUntilReturnsFalseAfterTheTimeout() async {
        let held = await DisplayConfigurator.waitUntil(timeout: .milliseconds(150)) { false }
        XCTAssertFalse(held)
        let immediate = await DisplayConfigurator.waitUntil(timeout: .seconds(5)) { true }
        XCTAssertTrue(immediate)
    }
}
