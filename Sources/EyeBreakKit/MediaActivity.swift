import Foundation
import IOKit.pwr_mgt

/// Tells whether something on screen should not be covered: video players, calls and presentations
/// ask macOS to keep the display on, and that request is visible to every process.
enum MediaActivity {
    private static let displayAssertions: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// True while another app holds a keep-the-display-on assertion. OneMac's own keep-awake is ignored.
    static func isAnotherAppKeepingDisplayOn() -> Bool {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
              let byProcess = copied?.takeRetainedValue() as NSDictionary? else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for (pid, held) in byProcess {
            guard (pid as? NSNumber)?.int32Value != ownPID, let assertions = held as? [[String: Any]] else { continue }
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey] as? String, displayAssertions.contains(type),
                      (assertion[kIOPMAssertionLevelKey] as? Int ?? 0) != 0 else { continue }
                return true
            }
        }
        return false
    }
}
