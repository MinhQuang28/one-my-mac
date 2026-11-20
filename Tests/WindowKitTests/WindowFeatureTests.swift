import Carbon.HIToolbox
@testable import WindowKit
import XCTest

final class WindowThirdsAndCycleTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 30, width: 1921, height: 1050)
    private let current = CGRect(x: 300, y: 200, width: 800, height: 600)

    private func frame(_ action: WindowAction) -> CGRect { WindowLayout.frame(for: action, in: visible, current: current) }

    func testThirdsTileTheVisibleAreaWithoutGaps() {
        let left = frame(.leftThird), centre = frame(.centerThird), right = frame(.rightThird)
        XCTAssertEqual(left.minX, visible.minX)
        XCTAssertEqual(left.maxX, centre.minX)
        XCTAssertEqual(centre.maxX, right.minX)
        XCTAssertEqual(right.maxX, visible.maxX)
        XCTAssertEqual(left.height, visible.height)
        XCTAssertEqual(frame(.leftTwoThirds).maxX, right.minX)   // two thirds + the other third = everything
        XCTAssertEqual(frame(.rightTwoThirds).minX, left.maxX)
        XCTAssertEqual(frame(.rightTwoThirds).maxX, visible.maxX)
    }

    func testAlmostMaximizeIsCentredAndLeavesAMargin() {
        let almost = frame(.almostMaximize)
        XCTAssertTrue(visible.contains(almost))
        XCTAssertEqual(almost.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(almost.midY, visible.midY, accuracy: 1)
        XCTAssertEqual(almost.width, floor(visible.width * 0.9))
    }

    func testRepeatingAHalfCyclesHalfTwoThirdsThird() {
        func next(_ action: WindowAction, from frame: CGRect) -> CGRect {
            WindowLayout.cycledFrame(for: action, in: visible, current: frame)
        }
        let half = next(.leftHalf, from: current)
        XCTAssertEqual(half, frame(.leftHalf)) // from anywhere else: the plain half
        let twoThirds = next(.leftHalf, from: half)
        XCTAssertEqual(twoThirds, frame(.leftTwoThirds))
        let third = next(.leftHalf, from: twoThirds)
        XCTAssertEqual(third, frame(.leftThird))
        XCTAssertEqual(next(.leftHalf, from: third), half)
        // A few points off (an app rounding its size) still counts as being there.
        XCTAssertEqual(next(.rightHalf, from: frame(.rightHalf).offsetBy(dx: -3, dy: 0)), frame(.rightTwoThirds))
        // The other side's frames, and actions without a cycle, do not cycle.
        XCTAssertEqual(next(.rightHalf, from: half), frame(.rightHalf))
        XCTAssertEqual(next(.maximize, from: visible), visible)
    }
}

final class WindowOverflowTests: XCTestCase {
    private let area = CGRect(x: 0, y: 30, width: 1440, height: 870)

    func testAWindowThatRefusedToShrinkIsSlidBackOntoTheDisplay() {
        // Right half asked for 720 wide at x 720; the app kept 1000.
        let stubborn = CGRect(x: 720, y: 30, width: 1000, height: 870)
        XCTAssertEqual(WindowLayout.originKeepingOnDisplay(stubborn, in: area), CGPoint(x: 440, y: 30))
        // Bottom half with a minimum height.
        let tall = CGRect(x: 0, y: 465, width: 1440, height: 600)
        XCTAssertEqual(WindowLayout.originKeepingOnDisplay(tall, in: area), CGPoint(x: 0, y: 300))
    }

    func testAWindowThatFitsIsLeftAloneAndAnOversizedOneKeepsItsTopLeftCorner() {
        XCTAssertNil(WindowLayout.originKeepingOnDisplay(CGRect(x: 720, y: 30, width: 720, height: 870), in: area))
        XCTAssertNil(WindowLayout.originKeepingOnDisplay(.null, in: area))
        let huge = CGRect(x: 300, y: 200, width: 2000, height: 1200)
        XCTAssertEqual(WindowLayout.originKeepingOnDisplay(huge, in: area), CGPoint(x: 0, y: 30))
    }

    func testOnADisplayLeftOfAndAboveThePrimary() {
        let other = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let stubborn = CGRect(x: -960, y: -1080, width: 1200, height: 1080)
        XCTAssertEqual(WindowLayout.originKeepingOnDisplay(stubborn, in: other), CGPoint(x: -1200, y: -1080))
    }
}

final class WindowRestoreStalenessTests: XCTestCase {
    private let original = CGRect(x: 10, y: 10, width: 500, height: 400)
    private let left = CGRect(x: 0, y: 0, width: 960, height: 1000)

    func testRestoreDoesNothingOnceTheWindowWasMovedByHand() {
        var memory = WindowRestoreMemory<String>()
        memory.willArrange("w", from: original)
        memory.didArrange("w", target: left, at: left)
        let dragged = CGRect(x: 200, y: 150, width: 960, height: 1000)
        XCTAssertNil(memory.takeSavedFrame(for: "w", current: dragged))
        XCTAssertNil(memory.savedFrame(for: "w")) // and the stale frame is forgotten
    }

    func testAnAppStillAnimatingWhenSampledDoesNotLoseTheFrameToRestore() {
        var memory = WindowRestoreMemory<String>()
        memory.willArrange("w", from: original)
        let midFlight = CGRect(x: 5, y: 5, width: 700, height: 650)
        memory.didArrange("w", target: left, at: midFlight)
        // The window finished at the frame asked for: a second action still sees it as OneMac's.
        memory.willArrange("w", from: left)
        XCTAssertEqual(memory.savedFrame(for: "w"), original)
        XCTAssertEqual(memory.takeSavedFrame(for: "w", current: left), original)
    }

    func testAClampedWindowCountsAsStillWhereItWasLeft() {
        var memory = WindowRestoreMemory<String>()
        memory.willArrange("w", from: original)
        let clamped = CGRect(x: 0, y: 0, width: 1100, height: 1000) // the app kept a minimum width
        memory.didArrange("w", target: left, at: clamped)
        XCTAssertEqual(memory.takeSavedFrame(for: "w", current: clamped), original)
    }
}

final class WindowShortcutBindingsTests: XCTestCase {
    private let custom = WindowShortcut(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey)

    func testDefaultsApplyUntilChangedAndOnlyDifferencesAreStored() {
        var bindings = WindowShortcutBindings()
        XCTAssertEqual(bindings.shortcut(for: .leftHalf), WindowShortcut.default(for: .leftHalf))
        XCTAssertNil(bindings.shortcut(for: .leftThird))
        XCTAssertNil(bindings.assign(custom, to: .leftThird))
        XCTAssertEqual(bindings.stored, ["leftThird": custom.stored])
        // Round trip through what UserDefaults holds.
        XCTAssertEqual(WindowShortcutBindings(stored: bindings.stored).shortcut(for: .leftThird), custom)
        XCTAssertNil(bindings.assign(nil, to: .leftThird)) // back to its default (none): nothing stored
        XCTAssertFalse(bindings.isCustomized)
    }

    func testARemovedDefaultStaysRemovedAndCanBeReset() {
        var bindings = WindowShortcutBindings()
        bindings.assign(nil, to: .maximize)
        XCTAssertNil(bindings.shortcut(for: .maximize))
        XCTAssertNil(WindowShortcutBindings(stored: bindings.stored).shortcut(for: .maximize))
        bindings.assign(WindowShortcut.default(for: .maximize), to: .maximize)
        XCTAssertFalse(bindings.isCustomized)
    }

    func testTwoActionsCannotShareAShortcut() {
        var bindings = WindowShortcutBindings()
        let leftKeys = WindowShortcut.default(for: .leftHalf)!
        XCTAssertEqual(bindings.assign(leftKeys, to: .leftThird), .leftHalf)
        XCTAssertNil(bindings.shortcut(for: .leftThird))
        // Free the keys first, then they can move — and the default cannot come back on top of them.
        bindings.assign(nil, to: .leftHalf)
        XCTAssertNil(bindings.assign(leftKeys, to: .leftThird))
        XCTAssertEqual(bindings.assign(leftKeys, to: .leftHalf), .leftThird)
    }

    func testRecordingNeedsARealModifierAndRejectsGarbage() {
        XCTAssertNil(WindowShortcut(keyCode: kVK_ANSI_A, flags: []))
        XCTAssertNil(WindowShortcut(keyCode: kVK_ANSI_A, flags: .shift))
        XCTAssertEqual(WindowShortcut(keyCode: kVK_ANSI_A, flags: [.command, .shift])?.modifiers, cmdKey | shiftKey)
        XCTAssertNil(WindowShortcut(stored: "abc"))
        XCTAssertNil(WindowShortcut(stored: ""))
        XCTAssertNil(WindowShortcut(stored: "12:0"))
        XCTAssertEqual(WindowShortcut(stored: custom.stored), custom)
        XCTAssertEqual(WindowShortcut(keyCode: kVK_F5, modifiers: cmdKey).keyCaps, ["⌘", "F5"])
    }
}

final class WindowSnapZoneTests: XCTestCase {
    // A primary display with a second one to its right, set higher.
    private let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: -180, width: 1920, height: 1080)]

    private func action(_ x: CGFloat, _ y: CGFloat) -> WindowAction? {
        WindowSnapZones.zone(at: CGPoint(x: x, y: y), displays: displays)?.action
    }

    func testEdgesGiveHalvesAndMaximizeAndCornersGiveQuarters() {
        XCTAssertEqual(action(0, 450), .leftHalf)
        XCTAssertEqual(action(700, 0.5), .maximize)
        XCTAssertEqual(action(0, 40), .topLeft)
        XCTAssertEqual(action(60, 0), .topLeft)
        XCTAssertEqual(action(2, 860), .bottomLeft)
        XCTAssertEqual(action(80, 899.5), .bottomLeft)
    }

    func testTheMiddleOfTheBottomEdgeAndTheOpenScreenDoNothing() {
        XCTAssertNil(action(700, 899.5)) // the Dock
        XCTAssertNil(action(700, 450))
        XCTAssertNil(action(5000, 5000)) // off every display
        XCTAssertNil(WindowSnapZones.zone(at: .zero, displays: []))
    }

    func testEachDisplayHasItsOwnZones() {
        let far = WindowSnapZones.zone(at: CGPoint(x: 3359.5, y: 300), displays: displays)
        XCTAssertEqual(far, WindowSnapZone(display: 1, action: .rightHalf))
        XCTAssertEqual(WindowSnapZones.zone(at: CGPoint(x: 2400, y: -180), displays: displays),
                       WindowSnapZone(display: 1, action: .maximize))
        XCTAssertEqual(action(3359.5, 880), .bottomRight)
        // The primary's right edge, where the two displays meet, is still the primary's right half.
        XCTAssertEqual(WindowSnapZones.zone(at: CGPoint(x: 1438, y: 450), displays: displays),
                       WindowSnapZone(display: 0, action: .rightHalf))
    }
}
