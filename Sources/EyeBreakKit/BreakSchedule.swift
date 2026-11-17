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
    }

    /// No input for this long counts as having rested already: the countdown starts over.
    static let restThreshold: TimeInterval = 180

    var interval: TimeInterval
    var breakLength: TimeInterval
    /// How long before the break the heads-up shows; 0 turns it off.
    var headsUpLead: TimeInterval

    private(set) var nextBreak: Date
    private(set) var breakEnd: Date?
    private var lastTick: Date

    init(interval: TimeInterval, breakLength: TimeInterval, headsUpLead: TimeInterval, now: Date) {
        self.interval = interval
        self.breakLength = breakLength
        self.headsUpLead = headsUpLead
        nextBreak = now.addingTimeInterval(interval)
        lastTick = now
    }

    /// Moves the schedule to `now`. `idle` is the time since the last keyboard or mouse input;
    /// `busy` is only asked when a break is due.
    mutating func advance(now: Date, idle: TimeInterval, busy: @autoclosure () -> Bool) -> Phase {
        defer { lastTick = now }
        if let end = breakEnd {
            if now < end { return .onBreak(remaining: end.timeIntervalSince(now)) }
            restart(now: now)
            return .working(remaining: interval)
        }
        // Away from the keyboard, or the Mac slept between two ticks: the eyes have rested.
        if idle >= Self.restThreshold || now.timeIntervalSince(lastTick) >= Self.restThreshold {
            nextBreak = now.addingTimeInterval(interval)
        }
        let remaining = nextBreak.timeIntervalSince(now)
        if remaining <= 0 {
            if busy() { return .deferred }
            breakEnd = now.addingTimeInterval(breakLength)
            return .onBreak(remaining: breakLength)
        }
        return remaining <= headsUpLead ? .headsUp(remaining: remaining) : .working(remaining: remaining)
    }

    /// Ends any break and counts a full interval from `now`.
    mutating func restart(now: Date) { postpone(now: now, by: interval) }

    /// Ends any break and schedules the next one `delay` seconds from `now`.
    mutating func postpone(now: Date, by delay: TimeInterval) {
        breakEnd = nil
        nextBreak = now.addingTimeInterval(delay)
    }

    mutating func startBreak(now: Date) { breakEnd = now.addingTimeInterval(breakLength) }
}
