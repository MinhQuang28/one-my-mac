import Foundation

/// When the next eye break is due. Pure: time and input idleness are passed in, so it can be tested
/// without a clock.
struct BreakSchedule {
    enum Phase: Equatable {
        /// Screen time is running; the break is `remaining` seconds away.
        case working(remaining: TimeInterval)
        /// The break is about to start.
        case headsUp(remaining: TimeInterval)
        /// The break is due but is held back (a video or a call is on screen).
        case deferred
        case onBreak(remaining: TimeInterval)
        /// Switched off for a while; breaks come back at `until`.
        case paused(until: Date)
    }

    /// No input for this long counts as having rested already: the countdown starts over.
    static let restThreshold: TimeInterval = 180
    /// A break held back for this long stops waiting and shows as the small card instead.
    static let deferralCap: TimeInterval = 15 * 60

    var interval: TimeInterval
    var breakLength: TimeInterval
    /// How long before the break the heads-up shows; 0 turns it off.
    var headsUpLead: TimeInterval

    private(set) var nextBreak: Date
    private(set) var breakEnd: Date?
    private(set) var pausedUntil: Date?
    /// The running break gave up waiting for a video or call: show it without covering the screen.
    private(set) var breakIsGentle = false
    /// When the break first had to wait; kept until a break starts so short gaps do not reset the cap.
    private var deferredSince: Date?
    /// The last phase was `.deferred`, so the user has had no warning yet.
    private var waiting = false
    private var lastTick: Date

    init(interval: TimeInterval, breakLength: TimeInterval, headsUpLead: TimeInterval, now: Date) {
        self.interval = interval
        self.breakLength = breakLength
        self.headsUpLead = headsUpLead
        nextBreak = now.addingTimeInterval(interval)
        lastTick = now
    }

    /// Moves the schedule to `now`. `idle` is the time since the last keyboard or mouse input.
    /// `busy` (a call or video should not be covered) is only asked once the heads-up is near;
    /// `watching` (something keeps the display on, so no input does not mean nobody is looking) only
    /// when the input has been idle long enough to count as rest.
    mutating func advance(now: Date, idle: TimeInterval, busy: @autoclosure () -> Bool,
                          watching: @autoclosure () -> Bool = false) -> Phase {
        defer { lastTick = now }
        // The wall clock was set back: carry every deadline with it, so nothing is stretched.
        // A pause is a wall-clock time on purpose ("until tomorrow") and stays put.
        let jump = now.timeIntervalSince(lastTick)
        if jump < 0 {
            nextBreak.addTimeInterval(jump)
            breakEnd?.addTimeInterval(jump)
            deferredSince?.addTimeInterval(jump)
        }
        if let until = pausedUntil {
            if now < until { return .paused(until: until) }
            pausedUntil = nil
            restart(now: now)
            return .working(remaining: interval)
        }
        if let end = breakEnd {
            let left = min(end.timeIntervalSince(now), breakLength)
            if left > 0 { return .onBreak(remaining: left) }
            restart(now: now)
            return .working(remaining: interval)
        }
        // Away from the keyboard, or the Mac slept between two ticks: the eyes have rested.
        if jump >= Self.restThreshold || (idle >= Self.restThreshold && !watching()) {
            restart(now: now)
        }
        let remaining = nextBreak.timeIntervalSince(now)
        if remaining > headsUpLead { return .working(remaining: remaining) }
        if busy() {
            // No card over a call; the countdown just keeps running until the break is due.
            guard remaining <= 0 else { return .working(remaining: remaining) }
            let since = deferredSince ?? now
            deferredSince = since
            if now.timeIntervalSince(since) >= Self.deferralCap {
                beginBreak(now: now, gentle: true)
                return .onBreak(remaining: breakLength)
            }
            waiting = true
            return .deferred
        }
        if waiting {
            // Just released: give the usual warning first instead of covering the screen at once.
            waiting = false
            if headsUpLead > 0 {
                nextBreak = now.addingTimeInterval(headsUpLead)
                return .headsUp(remaining: headsUpLead)
            }
        }
        if remaining <= 0 {
            beginBreak(now: now, gentle: false)
            return .onBreak(remaining: breakLength)
        }
        return .headsUp(remaining: remaining)
    }

    /// Ends any break and counts a full interval from `now`.
    mutating func restart(now: Date) { postpone(now: now, by: interval) }

    /// Ends any break and schedules the next one `delay` seconds from `now`.
    mutating func postpone(now: Date, by delay: TimeInterval) {
        breakEnd = nil
        breakIsGentle = false
        deferredSince = nil
        waiting = false
        nextBreak = now.addingTimeInterval(delay)
    }

    mutating func startBreak(now: Date) { beginBreak(now: now, gentle: false) }

    /// No breaks until `until`; a full interval is counted from then.
    mutating func pause(until: Date, now: Date) {
        restart(now: now)
        pausedUntil = until
    }

    /// Ends a pause early and counts a full interval from `now`.
    mutating func resume(now: Date) {
        pausedUntil = nil
        restart(now: now)
    }

    private mutating func beginBreak(now: Date, gentle: Bool) {
        breakEnd = now.addingTimeInterval(breakLength)
        breakIsGentle = gentle
        deferredSince = nil
        waiting = false
    }
}
