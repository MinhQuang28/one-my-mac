@testable import EyeBreakKit
import XCTest

final class BreakScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    private func schedule(headsUp: TimeInterval = 15) -> BreakSchedule {
        BreakSchedule(interval: 1200, breakLength: 20, headsUpLead: headsUp, now: start)
    }

    /// Ticks once a second with the user active, as the app does, and returns the phase at `second`.
    private func run(_ schedule: inout BreakSchedule, from: Int = 1, to second: Int) -> BreakSchedule.Phase {
        var phase = BreakSchedule.Phase.deferred
        for t in from...second { phase = schedule.advance(now: at(TimeInterval(t)), idle: 0, busy: false) }
        return phase
    }

    func testWorkThenHeadsUpThenBreakThenWorkAgain() {
        var s = schedule()
        XCTAssertEqual(run(&s, to: 600), .working(remaining: 600))
        XCTAssertEqual(run(&s, from: 601, to: 1190), .headsUp(remaining: 10))
        XCTAssertEqual(run(&s, from: 1191, to: 1200), .onBreak(remaining: 20))
        XCTAssertEqual(run(&s, from: 1201, to: 1210), .onBreak(remaining: 10))
        XCTAssertEqual(run(&s, from: 1211, to: 1220), .working(remaining: 1200)) // counted from the break's end
    }

    func testNoHeadsUpWhenTurnedOff() {
        var s = schedule(headsUp: 0)
        XCTAssertEqual(run(&s, to: 1199), .working(remaining: 1))
    }

    func testBeingAwayCountsAsRest() {
        var s = schedule()
        _ = run(&s, to: 900)
        // No input for three minutes: the countdown starts over.
        XCTAssertEqual(s.advance(now: at(901), idle: 180, busy: false), .working(remaining: 1200))
        // So does a gap between ticks (the Mac was asleep), even if input just resumed.
        var slept = schedule()
        _ = run(&slept, to: 900)
        XCTAssertEqual(slept.advance(now: at(5000), idle: 0, busy: false), .working(remaining: 1200))
    }

    func testBreakWaitsWhileBusyAndStartsWhenFree() {
        var s = schedule()
        _ = run(&s, to: 1199)
        XCTAssertEqual(s.advance(now: at(1200), idle: 0, busy: true), .deferred)
        XCTAssertEqual(s.advance(now: at(1201), idle: 0, busy: true), .deferred)
        // Free again: the usual warning first, then the break.
        XCTAssertEqual(s.advance(now: at(1202), idle: 0, busy: false), .headsUp(remaining: 15))
        XCTAssertEqual(run(&s, from: 1203, to: 1216), .headsUp(remaining: 1))
        XCTAssertEqual(s.advance(now: at(1217), idle: 0, busy: false), .onBreak(remaining: 20))
        XCTAssertFalse(s.breakIsGentle)
    }

    func testDeferredBreakStartsAtOnceWhenHeadsUpIsOff() {
        var s = schedule(headsUp: 0)
        _ = run(&s, to: 1199)
        XCTAssertEqual(s.advance(now: at(1200), idle: 0, busy: true), .deferred)
        XCTAssertEqual(s.advance(now: at(1201), idle: 0, busy: false), .onBreak(remaining: 20))
    }

    func testNoHeadsUpWhileBusy() {
        var s = schedule()
        _ = run(&s, to: 1184)
        XCTAssertEqual(s.advance(now: at(1190), idle: 0, busy: true), .working(remaining: 10))
        XCTAssertEqual(s.advance(now: at(1191), idle: 0, busy: false), .headsUp(remaining: 9))
    }

    func testDeferralIsCappedAndFallsBackToAGentleBreak() {
        var s = schedule()
        _ = run(&s, to: 1199)
        var phase = BreakSchedule.Phase.deferred
        for t in 1200..<(1200 + Int(BreakSchedule.deferralCap)) {
            phase = s.advance(now: at(TimeInterval(t)), idle: 0, busy: true)
        }
        XCTAssertEqual(phase, .deferred)
        XCTAssertEqual(s.advance(now: at(1200 + BreakSchedule.deferralCap), idle: 0, busy: true), .onBreak(remaining: 20))
        XCTAssertTrue(s.breakIsGentle)
        // The next break is an ordinary one again.
        XCTAssertEqual(s.advance(now: at(1221 + BreakSchedule.deferralCap), idle: 0, busy: true), .working(remaining: 1200))
        XCTAssertFalse(s.breakIsGentle)
    }

    func testIdleIsNotRestWhileSomethingIsBeingWatched() {
        var s = schedule()
        _ = run(&s, to: 900)
        XCTAssertEqual(s.advance(now: at(901), idle: 600, busy: false, watching: true), .working(remaining: 299))
        XCTAssertEqual(s.advance(now: at(902), idle: 600, busy: false, watching: false), .working(remaining: 1200))
    }

    func testClockMovingBackDoesNotStretchTheBreakOrTheCountdown() {
        var s = schedule()
        s.startBreak(now: at(100))
        XCTAssertEqual(s.advance(now: at(105), idle: 0, busy: false), .onBreak(remaining: 15))
        // The clock is set back an hour in the middle of the break.
        XCTAssertEqual(s.advance(now: at(105 - 3600), idle: 0, busy: false), .onBreak(remaining: 15))
        XCTAssertEqual(s.advance(now: at(115 - 3600), idle: 0, busy: false), .onBreak(remaining: 5))
        XCTAssertEqual(s.advance(now: at(120 - 3600), idle: 0, busy: false), .working(remaining: 1200))

        var working = schedule()
        _ = run(&working, to: 600)
        XCTAssertEqual(working.advance(now: at(600 - 7200), idle: 0, busy: false), .working(remaining: 600))
    }

    func testBreakNeverShowsMoreThanItsLength() {
        var s = schedule()
        s.startBreak(now: at(100))
        s.breakLength = 10 // shortened in settings while the break runs
        XCTAssertEqual(s.advance(now: at(101), idle: 0, busy: false), .onBreak(remaining: 10))
    }

    func testPauseHoldsBreaksUntilItEndsOrIsResumed() {
        var s = schedule()
        _ = run(&s, to: 1100)
        s.pause(until: at(4700), now: at(1100))
        XCTAssertEqual(s.advance(now: at(1101), idle: 0, busy: false), .paused(until: at(4700)))
        // Long gaps and idleness change nothing while paused.
        XCTAssertEqual(s.advance(now: at(4699), idle: 900, busy: false), .paused(until: at(4700)))
        XCTAssertEqual(s.advance(now: at(4700), idle: 0, busy: false), .working(remaining: 1200))
        XCTAssertNil(s.pausedUntil)

        s.pause(until: at(9000), now: at(4701))
        s.resume(now: at(4710))
        XCTAssertEqual(s.advance(now: at(4711), idle: 0, busy: false), .working(remaining: 1199))
    }

    func testBusyIsNotAskedBeforeTheBreakIsDue() {
        var s = schedule()
        var asked = false
        func busy() -> Bool { asked = true; return true }
        _ = s.advance(now: at(1), idle: 0, busy: busy())
        XCTAssertFalse(asked)
    }

    func testSkipPostponeAndBreakNow() {
        var s = schedule()
        s.startBreak(now: at(10))
        XCTAssertEqual(s.advance(now: at(11), idle: 0, busy: false), .onBreak(remaining: 19))
        s.postpone(now: at(12), by: 300)
        XCTAssertEqual(s.advance(now: at(13), idle: 0, busy: false), .working(remaining: 299))
        s.restart(now: at(14)) // skip
        XCTAssertEqual(s.advance(now: at(15), idle: 0, busy: false), .working(remaining: 1199))
    }
}
