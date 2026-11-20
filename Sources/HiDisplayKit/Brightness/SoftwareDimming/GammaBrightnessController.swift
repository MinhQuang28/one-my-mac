import CoreGraphics
import Foundation

/// Software dimming by shrinking the display's gamma ramp.
///
/// Cheap, needs no DDC, and works on displays that have no controllable backlight at all. The costs
/// are real and are why this is a fallback rather than a default: it changes colour output, it is
/// wrong under HDR, and a display left with a shrunk ramp looks broken.
///
/// **Crash safety.** CoreGraphics reverts gamma tables set by a process when that process dies, so a
/// crash cannot permanently leave a display dim. `resetAll()` still exists for clean quit and for the
/// emergency reset command, because relying on the crash path for normal shutdown would leave the
/// display dim for the moment between quit and cleanup.
public final class GammaBrightnessController: BrightnessController, @unchecked Sendable {

    public let kind: BrightnessControllerKind = .gamma

    /// Never dim all the way to black — a display at 0 with no visible UI is indistinguishable from
    /// broken hardware, and the user may not be able to find the menu bar to fix it.
    public static let minimumFactor: Float = 0.10

    private var appliedFactors: [CGDirectDisplayID: Float] = [:]
    /// Which monitor each dimmed `CGDirectDisplayID` was when it was dimmed. See `reapplyAll`.
    private var appliedTo: [CGDirectDisplayID: Fingerprint] = [:]
    /// The ramp each display had before this controller first touched it, so undoing the dim puts
    /// back a calibrated profile's ramp instead of a flat one.
    private var originalRamps: [CGDirectDisplayID: Ramp] = [:]
    private let lock = NSLock()

    /// What CoreGraphics reports about the monitor behind a display ID. Cheap to read, so it can be
    /// re-checked from the reconfiguration callback.
    struct Fingerprint: Equatable {
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32

        init(_ displayID: CGDirectDisplayID) {
            vendor = CGDisplayVendorNumber(displayID)
            model = CGDisplayModelNumber(displayID)
            serial = CGDisplaySerialNumber(displayID)
        }
    }

    struct Ramp {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    public init() {}

    public func probe(display: DisplayDevice) async -> BrightnessProbeResult {
        // Gamma is available whenever CoreGraphics gives us a real display with a gamma table.
        let capacity = CGDisplayGammaTableCapacity(display.cgDisplayID)
        guard capacity > 0 else {
            return BrightnessProbeResult(
                isSupported: false, kind: .gamma,
                detail: "display reports no gamma table capacity")
        }
        return BrightnessProbeResult(
            isSupported: true, kind: .gamma,
            currentValue: lock.withLock { appliedFactors[display.cgDisplayID] } ?? 1.0,
            detail: "gamma table capacity \(capacity)")
    }

    public func getBrightness(display: DisplayDevice) async throws -> Float {
        // There is no way to ask the display what its gamma-dimmed brightness is, so the app's own
        // last applied value is the source of truth. Defaulting to 1.0 (undimmed) is the safe answer
        // for a display we have not touched.
        lock.withLock { appliedFactors[display.cgDisplayID] } ?? 1.0
    }

    public func setBrightness(_ value: Float, display: DisplayDevice) async throws {
        let factor = max(Self.minimumFactor, min(value, 1.0))
        captureOriginalRampIfNeeded(display.cgDisplayID)
        // Formula rather than a table: it needs no allocation and no per-display capacity handling,
        // and scaling the maximum is exactly the "reduce output" operation wanted here.
        let error = CGSetDisplayTransferByFormula(
            display.cgDisplayID,
            0, factor, 1.0,
            0, factor, 1.0,
            0, factor, 1.0)
        guard error == .success else {
            throw DDCError.ioError(code: Int32(error.rawValue))
        }
        lock.withLock {
            appliedFactors[display.cgDisplayID] = factor
            appliedTo[display.cgDisplayID] = Fingerprint(display.cgDisplayID)
        }
    }

    /// Remembers the display's own ramp the first time it is about to be dimmed.
    ///
    /// Must run before the first write: afterwards the table holds this controller's ramp, not the
    /// display's. A display with an entry already is left alone for the same reason.
    private func captureOriginalRampIfNeeded(_ displayID: CGDirectDisplayID) {
        guard lock.withLock({ appliedFactors[displayID] == nil && originalRamps[displayID] == nil })
        else { return }
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else { return }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count) == .success,
              count > 0 else { return }
        let ramp = Ramp(
            red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))),
            blue: Array(blue.prefix(Int(count))))
        lock.withLock { originalRamps[displayID] = ramp }
    }

    /// Re-writes every gamma ramp this controller has applied.
    ///
    /// macOS resets a display's gamma table on reconfiguration — changing resolution is enough. The
    /// dimming vanishes, the screen jumps to full brightness, and it stays there until something puts
    /// the ramp back. That used to be the settle handler, two seconds later, which read as the screen
    /// flashing bright and then dimming again on every resolution change.
    ///
    /// Synchronous and allocation-free on purpose: this runs straight off the reconfiguration
    /// callback, where the whole point is to close the gap before it is visible. One
    /// `CGSetDisplayTransferByFormula` per dimmed display, and there is normally one.
    ///
    /// Safe to call at any time: it only rewrites values already applied, so a display that was never
    /// dimmed is not touched, and a redundant call is a no-op the user cannot see.
    ///
    /// Only for the monitor that was dimmed. CoreGraphics reuses `CGDirectDisplayID`s, and this runs
    /// before discovery has had a chance to prune: an ID that now names a different monitor — or
    /// none — is dropped instead of dimming whatever inherited it.
    public func reapplyAll() {
        let factors: [CGDirectDisplayID: Float] = lock.withLock {
            let stale = appliedFactors.keys.filter { displayID in
                CGDisplayIsOnline(displayID) == 0 || appliedTo[displayID] != Fingerprint(displayID)
            }
            for displayID in stale { forget(displayID) }
            return appliedFactors
        }
        for (displayID, factor) in factors {
            CGSetDisplayTransferByFormula(
                displayID,
                0, factor, 1.0,
                0, factor, 1.0,
                0, factor, 1.0)
        }
    }

    /// Forgets displays that are no longer attached.
    ///
    /// Their ramps died with the connection, and CoreGraphics reuses `CGDirectDisplayID`s: without
    /// this, `reapplyAll` would dim whatever monitor next inherits the ID, and a replug of the same
    /// monitor that then binds DDC would keep the stale ramp underneath the hardware value.
    public func prune(keeping live: Set<CGDirectDisplayID>) {
        lock.withLock {
            for displayID in appliedFactors.keys where !live.contains(displayID) { forget(displayID) }
            originalRamps = originalRamps.filter { live.contains($0.key) }
        }
    }

    /// Drops the bookkeeping for one display ID. Call with `lock` held.
    private func forget(_ displayID: CGDirectDisplayID) {
        appliedFactors.removeValue(forKey: displayID)
        appliedTo.removeValue(forKey: displayID)
        originalRamps.removeValue(forKey: displayID)
    }

    public func reset(display: DisplayDevice) async {
        let displayID = display.cgDisplayID
        let (hadFactor, original): (Bool, Ramp?) = lock.withLock {
            let had = appliedFactors[displayID] != nil
            let ramp = originalRamps[displayID]
            forget(displayID)
            return (had, ramp)
        }
        guard hadFactor else { return }
        // This display only, so resetting one does not clobber a colour profile active on another
        // (the only ColorSync restore CoreGraphics offers is global). The ramp captured before the
        // first dim goes back when there is one — that is the calibrated profile's own table — and
        // a flat ramp is the fallback when it could not be read.
        if let original,
           CGSetDisplayTransferByTable(
               displayID, UInt32(original.red.count), original.red, original.green, original.blue)
               == .success {
            return
        }
        CGSetDisplayTransferByFormula(
            displayID,
            0, 1.0, 1.0,
            0, 1.0, 1.0,
            0, 1.0, 1.0)
    }

    /// Emergency reset: hands every display back to ColorSync.
    ///
    /// Uses the global restore rather than per-display formulas because the point of the emergency
    /// path is to work even when the app's own bookkeeping is wrong — including for displays it does
    /// not know it dimmed.
    public func resetAll() {
        lock.withLock {
            appliedFactors.removeAll()
            appliedTo.removeAll()
            originalRamps.removeAll()
        }
        CGDisplayRestoreColorSyncSettings()
        Log.gamma.notice("restored ColorSync gamma for all displays")
    }
}
