import Foundation

/// The temperature rules for fans held at a manual speed. Pure, so they are tested without hardware.
enum FanGuard {
    /// From this CPU temperature up the Mac counts as hot, until it is back below `resume`.
    static let cutoff = 90.0
    static let resume = 80.0
    /// A manual speed at or above this share of the fan's maximum is cooling: heat never cuts it off.
    static let coolingFloor = 0.8
    /// Samples in a row without a CPU temperature before manual speeds are given up.
    static let blindLimit = 3

    enum Verdict: Equatable {
        case keep
        /// Hot while a fan is held slow: hand the fans back to macOS.
        case releaseHot
        /// No temperature to watch: manual speeds cannot be guarded.
        case releaseBlind
    }

    /// Hot with hysteresis; a missing reading keeps the previous answer.
    static func isHot(wasHot: Bool, hottest: Double?) -> Bool {
        guard let hottest else { return wasHot }
        return hottest >= (wasHot ? resume : cutoff)
    }

    /// Whether a manual speed (share of the fan's maximum) may be held. The small slack absorbs the
    /// rounding of an RPM target back into a share.
    static func allows(fraction: Double, hot: Bool) -> Bool { !hot || fraction >= coolingFloor - 0.005 }

    /// What to do about the fans that are manual right now, given their targets as shares of max.
    static func verdict(manualFractions: [Double], hot: Bool, blindSamples: Int) -> Verdict {
        guard !manualFractions.isEmpty else { return .keep }
        if blindSamples >= blindLimit { return .releaseBlind }
        return manualFractions.allSatisfy { allows(fraction: $0, hot: hot) } ? .keep : .releaseHot
    }
}
