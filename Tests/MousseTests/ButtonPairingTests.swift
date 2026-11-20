import XCTest
@testable import MousseFeature

/// Down/up pairing: an up is swallowed exactly when its down was, whatever changed in between.
final class ButtonPairingTests: XCTestCase {

    func testUpIsSwallowedWhenItsDownWas() {
        var pairing = ButtonPairing()
        pairing.swallowDown(4)
        XCTAssertTrue(pairing.shouldSwallowUp(4, gestureConsumed: false))
        XCTAssertFalse(pairing.shouldSwallowUp(4, gestureConsumed: false), "the pair is used up")
    }

    func testUpPassesWhenItsDownPassed() {
        // A mapping added mid-press must not swallow an up whose down the app already saw.
        var pairing = ButtonPairing()
        XCTAssertFalse(pairing.shouldSwallowUp(5, gestureConsumed: false))
    }

    func testGestureUpIsAlwaysSwallowed() {
        var pairing = ButtonPairing()
        pairing.swallowDown(3)
        XCTAssertTrue(pairing.shouldSwallowUp(3, gestureConsumed: true))
        XCTAssertTrue(pairing.swallowedDowns.isEmpty)
    }

    func testButtonsArePairedIndependently() {
        var pairing = ButtonPairing()
        pairing.swallowDown(4)
        XCTAssertFalse(pairing.shouldSwallowUp(5, gestureConsumed: false))
        XCTAssertTrue(pairing.shouldSwallowUp(4, gestureConsumed: false))
    }

    /// The tap was disabled (or rebuilt) while button 4 was held and its up went unseen. Without
    /// the reset, the stale entry swallows the up of the NEXT click — whose down passed through
    /// because the mapping is gone — and the app is left holding the button.
    func testResetAfterMissedUpLetsTheNextClickThrough() {
        var pairing = ButtonPairing()
        pairing.swallowDown(4)
        pairing.reset() // tap disabled by timeout / rebuilt
        XCTAssertFalse(pairing.shouldSwallowUp(4, gestureConsumed: false))
    }

    func testResetDoesNotAffectLaterPresses() {
        var pairing = ButtonPairing()
        pairing.swallowDown(4)
        pairing.reset()
        pairing.swallowDown(4)
        XCTAssertTrue(pairing.shouldSwallowUp(4, gestureConsumed: false))
    }
}
