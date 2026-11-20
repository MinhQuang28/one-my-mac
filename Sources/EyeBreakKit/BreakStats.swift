import Foundation

/// How many breaks ran to the end and how many were cut short today. Starts over each day.
struct BreakStats: Equatable {
    private(set) var day: Date
    private(set) var taken = 0
    private(set) var skipped = 0

    private static let dayKey = "eyebreak_stats_day", takenKey = "eyebreak_stats_taken", skippedKey = "eyebreak_stats_skipped"

    init(now: Date = Date(), defaults: UserDefaults = .standard) {
        day = Calendar.current.startOfDay(for: now)
        guard let saved = defaults.object(forKey: Self.dayKey) as? Date, saved == day else { return }
        taken = max(0, defaults.integer(forKey: Self.takenKey))
        skipped = max(0, defaults.integer(forKey: Self.skippedKey))
    }

    /// Counts one break. Yesterday's numbers are dropped first.
    mutating func record(taken wasTaken: Bool, now: Date = Date(), defaults: UserDefaults = .standard) {
        rollOver(now: now)
        if wasTaken { taken += 1 } else { skipped += 1 }
        defaults.set(day, forKey: Self.dayKey)
        defaults.set(taken, forKey: Self.takenKey)
        defaults.set(skipped, forKey: Self.skippedKey)
    }

    /// Clears the numbers once the day has changed.
    mutating func rollOver(now: Date = Date()) {
        let today = Calendar.current.startOfDay(for: now)
        guard today != day else { return }
        day = today
        taken = 0
        skipped = 0
    }
}
