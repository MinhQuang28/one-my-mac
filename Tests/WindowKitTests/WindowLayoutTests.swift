@testable import WindowKit
import XCTest

final class WindowLayoutTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 30, width: 1921, height: 1050)
    private let current = CGRect(x: 300, y: 200, width: 800, height: 600)

    func testHalvesAndCornersTileTheVisibleAreaWithoutGaps() {
        let left = WindowLayout.frame(for: .leftHalf, in: visible, current: current)
        let right = WindowLayout.frame(for: .rightHalf, in: visible, current: current)
        XCTAssertEqual(left, CGRect(x: 0, y: 30, width: 960, height: 1050))
        XCTAssertEqual(right.maxX, visible.maxX) // odd widths: the right half hugs the right edge
        XCTAssertEqual(right.width, 960)
        let bottomRight = WindowLayout.frame(for: .bottomRight, in: visible, current: current)
        XCTAssertEqual(bottomRight, CGRect(x: 961, y: 555, width: 960, height: 525))
        XCTAssertEqual(WindowLayout.frame(for: .maximize, in: visible, current: current), visible)
    }

    func testCenterKeepsSizeAndShrinksOnlyWhenTooLarge() {
        let centered = WindowLayout.frame(for: .center, in: visible, current: current)
        XCTAssertEqual(centered.size, current.size)
        XCTAssertEqual(centered.midX, visible.midX)
        let huge = CGRect(x: 0, y: 0, width: 5000, height: 4000)
        XCTAssertEqual(WindowLayout.frame(for: .center, in: visible, current: huge), visible)
    }

    func testTransferKeepsSizeAndRelativeCentreAndRoundTrips() {
        let source = CGRect(x: 0, y: 30, width: 1920, height: 1080)
        let wide = CGRect(x: 1920, y: -200, width: 3440, height: 1440)
        let window = CGRect(x: 460, y: 220, width: 1000, height: 700)
        let moved = WindowLayout.transfer(window: window, from: source, to: wide)
        XCTAssertEqual(moved, CGRect(x: 3140, y: 170, width: 1000, height: 700))
        XCTAssertEqual(WindowLayout.transfer(window: moved, from: wide, to: source), window)
    }

    func testTransferKeepsALeftHalfFullHeightAndFitsOversizedWindows() {
        let source = CGRect(x: 0, y: 30, width: 1920, height: 1080)
        let wide = CGRect(x: 1920, y: -200, width: 3440, height: 1440)
        let half = CGRect(x: 0, y: 30, width: 960, height: 1080)
        XCTAssertEqual(WindowLayout.transfer(window: half, from: source, to: wide),
                       CGRect(x: 1920, y: -200, width: 1720, height: 1440)) // still a left half
        let big = CGRect(x: 2000, y: 0, width: 3000, height: 1300)
        let fitted = WindowLayout.transfer(window: big, from: wide, to: source)
        XCTAssertTrue(source.contains(fitted))
        XCTAssertEqual(WindowLayout.transfer(window: .null, from: source, to: wide), .null)
    }

    func testDisplayIsTheOneHoldingMostOfTheWindowElseTheNearest() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(WindowLayout.displayIndex(containing: CGRect(x: 700, y: 100, width: 500, height: 300), displays: displays), 0)
        XCTAssertEqual(WindowLayout.displayIndex(containing: CGRect(x: 900, y: 100, width: 500, height: 300), displays: displays), 1)
        XCTAssertEqual(WindowLayout.displayIndex(containing: CGRect(x: 2500, y: 100, width: 100, height: 100), displays: displays), 1)
        XCTAssertNil(WindowLayout.displayIndex(containing: .zero, displays: []))
    }
}

final class WindowRestoreMemoryTests: XCTestCase {
    private let original = CGRect(x: 10, y: 10, width: 500, height: 400)
    private let left = CGRect(x: 0, y: 0, width: 960, height: 1000)

    func testFrameBeforeTheFirstActionSurvivesLaterActionsAndIsTakenOnce() {
        var memory = WindowRestoreMemory<String>()
        memory.willArrange("w", from: original)
        memory.didArrange("w", at: left)
        memory.willArrange("w", from: left) // a second snap, from where OneMac left it
        memory.didArrange("w", at: CGRect(x: 960, y: 0, width: 960, height: 1000))
        XCTAssertEqual(memory.takeSavedFrame(for: "w"), original)
        XCTAssertNil(memory.takeSavedFrame(for: "w"))
    }

    func testAManualMoveBecomesTheNewFrameToRestore() {
        var memory = WindowRestoreMemory<String>()
        memory.willArrange("w", from: original)
        memory.didArrange("w", at: left)
        let dragged = CGRect(x: 200, y: 150, width: 700, height: 500)
        memory.willArrange("w", from: dragged)
        XCTAssertEqual(memory.savedFrame(for: "w"), dragged)
    }

    func testTheLeastRecentlyUsedWindowIsForgottenWhenFull() {
        var memory = WindowRestoreMemory<Int>(limit: 2)
        for key in 1...3 { memory.willArrange(key, from: original) }
        XCTAssertNil(memory.savedFrame(for: 1))
        XCTAssertNotNil(memory.savedFrame(for: 3))
    }

    func testFitPullsAFrameBackOntoADisplay() {
        let screen = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let gone = CGRect(x: 2500, y: 100, width: 800, height: 600) // its display was unplugged
        let fitted = WindowLayout.fit(gone, into: screen)
        XCTAssertTrue(screen.contains(fitted))
        XCTAssertEqual(fitted.size, gone.size)
        XCTAssertEqual(WindowLayout.fit(CGRect(x: 0, y: 0, width: 5000, height: 50), into: screen).width, 1920)
    }
}

final class WindowShortcutTests: XCTestCase {
    func testDefaultsAreUniqueAndPrintLikeMacOS() {
        let shortcuts = WindowAction.allCases.map(WindowShortcut.default(for:))
        for (i, a) in shortcuts.enumerated() {
            for b in shortcuts[(i + 1)...] { XCTAssertNotEqual(a, b) }
            XCTAssertFalse(a.keyCaps.contains("?"))
        }
        XCTAssertEqual(WindowShortcut.default(for: .nextDisplay).keyCaps, ["⌃", "⌥", "⌘", "→"])
    }
}
