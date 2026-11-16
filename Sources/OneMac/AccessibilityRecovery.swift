import ApplicationServices
import Foundation

/// Repairs a stale Accessibility grant.
///
/// When the app's code signature changes (an ad-hoc build, a new signing identity) macOS silently
/// stops honouring the old grant, yet System Settings still shows OneMac switched on — the user has
/// to remove and re-add the app by hand. If this Mac granted the permission before and it is gone
/// now, the dead entry is reset so the normal prompt (raised by the mouse module) works again.
/// The reset happens once per loss: a user who revoked the permission on purpose is not nagged.
@MainActor
enum AccessibilityRecovery {
    private static let grantedKey = "accessibility_was_granted"

    /// Call before anything asks for Accessibility.
    static func clearStaleGrantIfNeeded() {
        if AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: grantedKey)
            return
        }
        guard UserDefaults.standard.bool(forKey: grantedKey),
              let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }
        UserDefaults.standard.set(false, forKey: grantedKey)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit() // must finish before the prompt, or macOS swallows it
        } catch {
            NSLog("OneMac: could not reset the Accessibility entry: \(error.localizedDescription)")
        }
    }

    /// Call at quit: catches a grant given while the app was running.
    static func rememberGrant() {
        if AXIsProcessTrusted() { UserDefaults.standard.set(true, forKey: grantedKey) }
    }
}
