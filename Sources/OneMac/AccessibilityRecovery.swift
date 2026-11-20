import ApplicationServices
import CoreGraphics
import Foundation

/// Repairs stale privacy grants (Accessibility, Input Monitoring).
///
/// When the app's code signature changes (an ad-hoc build, a new signing identity) macOS silently
/// stops honouring the old grant, yet System Settings still shows OneMac switched on — the user has
/// to remove and re-add the app by hand. If this Mac granted a permission before and it is gone
/// now, the dead entry is reset so the normal prompt works again.
/// The reset happens once per loss: a user who revoked the permission on purpose is not nagged.
@MainActor
enum AccessibilityRecovery {
    /// A TCC service, how to tell whether it is granted, and where "it was granted" is remembered.
    private struct Service {
        let name: String
        let key: String
        let isGranted: () -> Bool
    }

    private static let services = [
        Service(name: "Accessibility", key: "accessibility_was_granted") { AXIsProcessTrusted() },
        Service(name: "ListenEvent", key: "input_monitoring_was_granted") { CGPreflightListenEventAccess() },
    ]

    /// Call before anything asks for a permission. `then` runs on the main thread once the stale
    /// entries are reset — at once when there are none. The reset must finish before the prompt
    /// (macOS swallows the prompt otherwise), but `tccutil` runs off the main thread.
    static func clearStaleGrants(then: @escaping @MainActor () -> Void) {
        let stale = staleServiceNames()
        guard !stale.isEmpty, let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            then()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            stale.forEach { reset($0, bundleID: bundleID) }
            Task { @MainActor in then() }
        }
    }

    /// Call at quit: catches a grant given while the app was running.
    static func rememberGrant() {
        for service in services where service.isGranted() {
            UserDefaults.standard.set(true, forKey: service.key)
        }
    }

    /// Services granted on an earlier run and missing now; each is reported once per loss.
    private static func staleServiceNames() -> [String] {
        services.compactMap { service in
            if service.isGranted() {
                UserDefaults.standard.set(true, forKey: service.key)
                return nil
            }
            guard UserDefaults.standard.bool(forKey: service.key) else { return nil }
            UserDefaults.standard.set(false, forKey: service.key)
            return service.name
        }
    }

    private nonisolated static func reset(_ service: String, bundleID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("OneMac: could not reset the \(service) privacy entry: \(error.localizedDescription)")
        }
    }
}
