import Foundation
import IOKit

/// Joins a recorded conversation with what the registry says about the display's connection.
///
/// Kept apart from `DDCTracer` because this half reads the live IORegistry: the tracer stays pure
/// and testable, and everything here is facts looked up, not decisions made.
public extension DDCTrace {

    /// - Parameter conversation: `nil` when the app holds no DDC session for this display, which is
    ///   the bind-failure case; the reason is then read from a fresh bind attempt.
    static func capture(display: DisplayDevice, conversation: Conversation?) -> DDCTrace {
        // A second bind, for its description only — nothing is sent through it. The session's own
        // transport sits behind the `DDCTransport` protocol, which deliberately knows no addresses.
        let binding = AppleSiliconAVServiceTransport(identity: display.identity)
        return DDCTrace(
            stableKey: display.id,
            bindFailure: binding.bindFailureReason,
            chipAddress: binding.isUsable ? "0x\(String(binding.chipAddress, radix: 16))" : nil,
            behindMCDP29xxBridge: binding.isBehindMCDP29xxBridge,
            link: linkDescription(for: display.identity),
            steps: conversation?.steps ?? [],
            verdict: conversation?.verdict ?? .noTransport,
            answeredShape: conversation?.answeredShape)
    }

    /// How the registry describes the display's connection.
    ///
    /// The point is the Mac's port. `Transport` carries `Upstream`/`Downstream` (`DP`, `HDMI`, …),
    /// which is how a built-in HDMI port shows up — DisplayPort from the chip, HDMI out — and those
    /// ports are where DDC is known not to work on some Macs. The whole dictionary is copied rather
    /// than two named keys, because the layout has changed between macOS releases and a report
    /// missing the one field that mattered is worth nothing.
    static func linkDescription(for identity: DisplayIdentity) -> [String: String] {
        let tokens = Set(AppleSiliconAVServiceTransport.unitTokens(matching: identity))
        guard !tokens.isEmpty else { return [:] }

        var link: [String: String] = [:]
        for className in AppleSiliconDisplayMetadataBackend.candidateClasses {
            IORegistryAccess.forEachService(matchingClass: className) { service, _ in
                guard let token = IORegistryAccess.displayUnitToken(service), tokens.contains(token)
                else { return }
                for (key, value) in IORegistryAccess.property(service, "Transport") as? [String: Any] ?? [:] {
                    link["Transport.\(key)"] = "\(value)"
                }
                if let location = IORegistryAccess.stringProperty(service, "Location") {
                    link["Location"] = location
                }
                if let provider = IORegistryAccess.parentStringProperty(service, "EPICProviderClass") {
                    link["EPICProviderClass"] = provider
                }
            }
        }
        return link
    }
}
