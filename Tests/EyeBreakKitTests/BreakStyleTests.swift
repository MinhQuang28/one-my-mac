@testable import EyeBreakKit
import XCTest

final class BreakStyleTests: XCTestCase {
    func testRotationGoesThroughEveryStyleInOrder() {
        let styles = (1...8).map { BreakStyleChoice.rotate.style(forBreak: $0, gentle: false) }
        XCTAssertEqual(Array(styles.prefix(4)).sorted { $0.rawValue < $1.rawValue },
                       BreakStyle.allCases.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(Array(styles.prefix(4)), Array(styles.suffix(4)))
    }

    func testAGentleBreakNeverCoversTheScreen() {
        for number in 0..<8 {
            XCTAssertFalse(BreakStyleChoice.rotate.style(forBreak: number, gentle: true).coversScreen)
        }
        XCTAssertEqual(BreakStyleChoice.fixed(.dusk).style(forBreak: 3, gentle: true), .island)
        XCTAssertEqual(BreakStyleChoice.fixed(.breath).style(forBreak: 3, gentle: false), .breath)
    }

    func testStoredChoiceRoundTripsAndUnknownMeansRotate() {
        XCTAssertEqual(BreakStyleChoice(stored: nil), .rotate)
        XCTAssertEqual(BreakStyleChoice(stored: "nonsense"), .rotate)
        for choice in [BreakStyleChoice.rotate] + BreakStyle.allCases.map(BreakStyleChoice.fixed) {
            XCTAssertEqual(BreakStyleChoice(stored: choice.stored), choice)
        }
    }

    func testTheTipShiftsAgainstTheStyleEveryRound() {
        // Same style every four breaks; the tip must not be the same one each time.
        XCTAssertNotEqual(BreakTip.forBreak(1), BreakTip.forBreak(5))
        XCTAssertEqual(Set((0..<16).map { BreakTip.forBreak($0) }).count, BreakTip.allCases.count)
    }
}
