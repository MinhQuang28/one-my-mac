import CoreGraphics
import Foundation

/// Soft-reconnects a display — off, then on again — so macOS re-reads its override file and rebuilds
/// its mode list, the way pulling the cable does but without the cable (or a logout).
///
/// A display disabled this way stays off after the process dies, so a marker is persisted before the
/// display goes dark and cleared once it is back; `recoverStranded` turns on anything a previous run
/// left off mid-reconnect.
public enum DisplayReconnector {

    public enum ReconnectError: Error, Equatable, CustomStringConvertible {
        /// This macOS release does not have the SkyLight entry points.
        case unsupported
        /// Turning off the only viewable display would leave nothing to see the recovery on.
        case needsAnotherDisplay
        case didNotTurnOff(CGError)
        case didNotComeBack(CGError)

        public var description: String {
            switch self {
            case .unsupported: return "this macOS version cannot reconnect a display in software"
            case .needsAnotherDisplay: return "another display must be on while this one reconnects"
            case .didNotTurnOff(let error): return "the display did not turn off (result \(error.rawValue))"
            case .didNotComeBack(let error): return "the display did not come back on (result \(error.rawValue))"
            }
        }
    }

    /// A display that was turned off and has not yet been seen back on.
    struct Pending: Codable, Equatable {
        var displayID: UInt32
        var vendorID: UInt32
        var productID: UInt32
    }

    static let defaultsKey = "hidisplay.pendingReconnects"

    /// A real panel someone can look at. Empty display pipes and the placeholder macOS creates once
    /// the last display is gone report vendor 0 or a four-character code EDID's 16 bits cannot hold.
    static func isViewable(vendor: UInt32) -> Bool {
        vendor != 0 && vendor <= 0xFFFF
    }

    /// Whether `displayID` can be reconnected now: the SPI exists and another viewable display
    /// would stay on.
    public static func canReconnect(_ displayID: CGDirectDisplayID) -> Bool {
        SkyLightDisplayShim.shared.canToggleDisplays
            && onlineIDs().contains { $0 != displayID && isViewable(vendor: CGDisplayVendorNumber($0)) }
    }

    /// Turns `displayID` off and on again. Returns the display's ID once it is back, which is
    /// normally — but not contractually — the one it had.
    @discardableResult
    public static func reconnect(
        _ displayID: CGDirectDisplayID, defaults: UserDefaults = .standard
    ) async throws -> CGDirectDisplayID {
        guard SkyLightDisplayShim.shared.canToggleDisplays else { throw ReconnectError.unsupported }
        guard canReconnect(displayID) else { throw ReconnectError.needsAnotherDisplay }

        let pending = Pending(
            displayID: displayID,
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID))
        // Written before the display goes dark: if the app dies mid-blink, the next launch still
        // knows there is a display to turn back on.
        store(load(defaults).filter { $0 != pending } + [pending], defaults)
        Log.modes.notice("soft-reconnecting display \(displayID)")

        let off = await DisplayConfigurator.shared.setEnabled(false, display: displayID)
        let gone = await DisplayConfigurator.waitUntil(timeout: .seconds(5)) {
            !onlineIDs().contains(displayID)
        }
        guard gone else {
            store(load(defaults).filter { $0 != pending }, defaults)
            throw ReconnectError.didNotTurnOff(off)
        }

        // Issued exactly once: enabling again during the 2–4 s link handshake restarts the handshake.
        let target = resolveID(for: pending)
        let on = await DisplayConfigurator.shared.setEnabled(true, display: target)
        let back = await DisplayConfigurator.waitUntil(timeout: .seconds(8)) {
            onlineID(matching: pending) != nil
        }
        // The marker stays when the display did not return, so the next launch tries again.
        guard back, let restored = onlineID(matching: pending) else {
            throw ReconnectError.didNotComeBack(on)
        }
        store(load(defaults).filter { $0 != pending }, defaults)
        return restored
    }

    /// Turns on displays a previous run left dark in the middle of a reconnect. Call once at launch.
    public static func recoverStranded(defaults: UserDefaults = .standard) async {
        let stranded = load(defaults)
        guard !stranded.isEmpty else { return }
        for pending in stranded where onlineID(matching: pending) == nil {
            Log.modes.notice("display \(pending.displayID) was left off mid-reconnect; turning it back on")
            _ = await DisplayConfigurator.shared.setEnabled(true, display: resolveID(for: pending))
            _ = await DisplayConfigurator.waitUntil(timeout: .seconds(8)) {
                onlineID(matching: pending) != nil
            }
        }
        store([], defaults)
    }

    // MARK: - Helpers

    static func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The online display this marker describes: its last ID, else the same vendor and model.
    private static func onlineID(matching pending: Pending) -> CGDirectDisplayID? {
        let online = onlineIDs()
        if online.contains(pending.displayID) { return pending.displayID }
        return online.first {
            CGDisplayVendorNumber($0) == pending.vendorID && CGDisplayModelNumber($0) == pending.productID
        }
    }

    /// Finds a disabled display in SkyLight's list: by last known ID, then by vendor and model
    /// among the displays that are not online.
    private static func resolveID(for pending: Pending) -> CGDirectDisplayID {
        let all = SkyLightDisplayShim.shared.allDisplayIDs()
        if all.contains(pending.displayID) { return pending.displayID }
        let online = Set(onlineIDs())
        return all.first {
            !online.contains($0) && CGDisplayVendorNumber($0) == pending.vendorID
                && CGDisplayModelNumber($0) == pending.productID
        } ?? pending.displayID
    }

    static func load(_ defaults: UserDefaults) -> [Pending] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    static func store(_ pending: [Pending], _ defaults: UserDefaults) {
        if pending.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
