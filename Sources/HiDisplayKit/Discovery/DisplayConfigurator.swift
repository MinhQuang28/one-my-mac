import CoreGraphics
import Foundation

/// Runs display-configuration transactions one at a time, off the main thread.
///
/// `CGCompleteDisplayConfiguration` blocks until WindowServer has rebuilt the display layout —
/// usually 1–3 s, up to ~10 s while a monitor renegotiates its link — so on the main thread the
/// whole UI hangs for that long. The serial queue also guarantees two changes never overlap.
public final class DisplayConfigurator: Sendable {

    public static let shared = DisplayConfigurator()

    private let queue = DispatchQueue(label: "com.onemac.app.display-configuration", qos: .userInitiated)

    /// Begins a transaction, lets `body` add changes, then completes it permanently (or cancels it
    /// if `body` fails). The result is WindowServer's own report, which can be wrong in both
    /// directions, so callers confirm the effect with `waitUntil`.
    public func perform(
        _ body: @escaping @Sendable (CGDisplayConfigRef) -> CGError
    ) async -> CGError {
        await withCheckedContinuation { continuation in
            queue.async {
                var config: CGDisplayConfigRef?
                let begin = CGBeginDisplayConfiguration(&config)
                guard begin == .success, let config else {
                    continuation.resume(returning: begin == .success ? .failure : begin)
                    return
                }
                let result = body(config)
                guard result == .success else {
                    CGCancelDisplayConfiguration(config)
                    continuation.resume(returning: result)
                    return
                }
                continuation.resume(returning: CGCompleteDisplayConfiguration(config, .permanently))
            }
        }
    }

    /// Takes `display` out of the layout, or puts it back.
    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) async -> CGError {
        await perform { config in
            SkyLightDisplayShim.shared.configureEnabled(config, display, enabled: enabled)
        }
    }

    /// Polls `condition` until it holds or `timeout` passes; returns whether it held.
    ///
    /// Polling rather than waiting on the reconfiguration callback because the kit's switcher and
    /// reconnector have no discovery service to hang a waiter on, and the questions asked here are
    /// single cheap CoreGraphics reads.
    public static func waitUntil(
        timeout: Duration, _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if condition() { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
