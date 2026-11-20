import CoreGraphics
import Foundation

/// Applies display modes, and curates the raw mode list into something a human can choose from.
///
/// Changing resolution is the one runtime operation in this app that can leave a display showing
/// nothing — a mode the panel advertises but cannot actually sync to is not rare, especially over
/// adapters. So the apply path is built around being undoable: it always reports the mode it replaced,
/// and the caller is expected to arm a revert timer before the user has a chance to be stuck.
public enum DisplayModeSwitcher {

    public enum SwitchError: Error, Equatable, CustomStringConvertible {
        case modeNotFound
        case configurationFailed(CGError)
        case sameMode
        /// The display mirrors another one; its mode is driven by the display it mirrors.
        case mirrored
        /// The transaction completed but the display never reported the requested mode.
        case notApplied(CGError)

        public var description: String {
            switch self {
            case .modeNotFound: return "that mode is no longer offered by the display"
            case .configurationFailed(let error): return "CoreGraphics rejected the change (error \(error.rawValue))"
            case .sameMode: return "the display is already using that mode"
            case .mirrored: return "the display is mirroring another one; change the resolution there"
            case .notApplied(let error): return "the display did not switch to that mode (result \(error.rawValue))"
            }
        }
    }

    /// How long to wait for the display to report the new mode after the transaction completes.
    static let confirmTimeout: Duration = .seconds(5)

    /// Switches `displayID` to `mode`, returning the mode that was replaced so the caller can revert.
    ///
    /// Runs on `DisplayConfigurator`'s queue, not the caller's thread: completing the transaction
    /// blocks for seconds. The whole change goes through one begin/complete transaction — a
    /// partially-applied configuration is how a multi-display setup ends up with overlapping frames.
    ///
    /// `.permanently` rather than `.forSession`: a session-scoped change still leaves the user stuck
    /// until they log out, which is not meaningfully safer. Recoverability comes from the caller's
    /// revert timer, not from the scope.
    @discardableResult
    public static func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID) async throws -> DisplayMode {
        guard let previous = DisplayModeService.currentMode(for: displayID) else {
            throw SwitchError.modeNotFound
        }
        guard previous.id != mode.id else { throw SwitchError.sameMode }
        // Setting a mode on a mirror target hangs or fails; its source owns the mode.
        guard CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay else { throw SwitchError.mirrored }

        guard findCGMode(matching: mode, on: displayID) != nil
            || findHiddenMode(matching: mode, on: displayID) != nil
        else { throw SwitchError.modeNotFound }

        // Resolved again inside the transaction, by shape: mode IDs and SkyLight mode numbers are both
        // renumbered whenever macOS rebuilds the list (reconnect, override change, sleep).
        let result = await DisplayConfigurator.shared.perform { config in
            if let cgMode = findCGMode(matching: mode, on: displayID) {
                return CGConfigureDisplayWithDisplayMode(config, displayID, cgMode, nil)
            }
            guard let hidden = findHiddenMode(matching: mode, on: displayID) else { return .illegalArgument }
            return SkyLightDisplayShim.shared.configureMode(config, displayID, modeNumber: hidden.modeNumber)
        }

        // WindowServer's result can be wrong in both directions, so the display's own report of its
        // current mode decides — a success code with the old mode still showing is a failure.
        let applied = await DisplayConfigurator.waitUntil(timeout: confirmTimeout) {
            DisplayModeService.currentMode(for: displayID).map { sameShape($0, mode, tolerance: 1) } ?? false
        }
        guard applied else {
            throw result == .success ? SwitchError.notApplied(result) : SwitchError.configurationFailed(result)
        }

        Log.modes.notice("switched display to \(mode.id, privacy: .public) from \(previous.id, privacy: .public)")
        return previous
    }

    /// Same logical and backing size, whatever the refresh rate.
    static func sameGeometry(_ lhs: DisplayMode, _ rhs: DisplayMode) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
    }

    /// Same geometry and refresh rate, whichever list the mode came from.
    ///
    /// `tolerance` is 0.5 Hz between two CoreGraphics modes, which keeps 59.94 and 60 apart. Pass 1
    /// when either side came from SkyLight, which truncates to whole hertz (59.94 reads as 59).
    static func sameShape(_ lhs: DisplayMode, _ rhs: DisplayMode, tolerance: Double = 0.5) -> Bool {
        sameGeometry(lhs, rhs) && abs(lhs.refreshRate - rhs.refreshRate) < tolerance
    }

    /// Re-finds the live `CGDisplayMode` for a value-type `DisplayMode`.
    ///
    /// Matching on `ioDisplayModeID` alone is not enough: several `CGDisplayMode` objects can share one
    /// ID across pixel encodings, and the IDs are not stable across reconnects. Geometry plus refresh
    /// rate is what actually identifies the mode the user picked.
    static func findCGMode(matching mode: DisplayMode, on displayID: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }
        return all.first { candidate in
            candidate.width == mode.width
                && candidate.height == mode.height
                && candidate.pixelWidth == mode.pixelWidth
                && candidate.pixelHeight == mode.pixelHeight
                && abs(candidate.refreshRate - mode.refreshRate) < 0.5
                && candidate.isUsableForDesktopGUI()
        }
    }

    /// The SkyLight-only mode of this shape, for modes CoreGraphics does not list.
    static func findHiddenMode(
        matching mode: DisplayMode, on displayID: CGDirectDisplayID
    ) -> SkyLightDisplayShim.HiddenMode? {
        SkyLightDisplayShim.shared.modes(for: displayID).first { sameShape($0.mode, mode) }
    }

    // MARK: - Curation

    /// The short list a person actually wants to choose from.
    ///
    /// The raw list from CoreGraphics runs to dozens of entries for a 4K panel — the same logical size
    /// repeated at several refresh rates and both scale factors. This collapses it to one entry per
    /// logical size, preferring the HiDPI variant (sharper at the same size) and then the highest
    /// refresh rate, which is what the macOS Displays panel effectively shows.
    public static func curated(from modes: [DisplayMode]) -> [DisplayMode] {
        var best: [String: DisplayMode] = [:]
        for mode in modes where mode.isUsableForDesktop {
            let key = mode.sizeKey
            guard let existing = best[key] else {
                best[key] = mode
                continue
            }
            if isPreferred(mode, over: existing) { best[key] = mode }
        }
        return best.values.sorted { lhs, rhs in
            lhs.width * lhs.height > rhs.width * rhs.height
        }
    }

    static func isPreferred(_ candidate: DisplayMode, over existing: DisplayMode) -> Bool {
        // Sharpness first: a HiDPI mode at a given logical size is strictly better looking than the 1×
        // one, and is the reason the HiDPI half of this app exists.
        if candidate.isHiDPI != existing.isHiDPI { return candidate.isHiDPI }
        return candidate.refreshRate > existing.refreshRate
    }

    /// Refresh rates available at one logical size and scale, highest first.
    ///
    /// Split from resolution selection because they are independent choices: picking 1440p should not
    /// silently drop the display from 120 Hz to 60 Hz.
    public static func refreshRates(
        forWidth width: Int, height: Int, hiDPI: Bool, in modes: [DisplayMode]
    ) -> [DisplayMode] {
        modes
            .filter { $0.width == width && $0.height == height && $0.isHiDPI == hiDPI && $0.isUsableForDesktop }
            // A reported rate of 0 means "not applicable" (common on internal panels), not 0 Hz, so it
            // must not be offered as a choice alongside real rates.
            .filter { $0.refreshRate > 0 }
            .sorted { $0.refreshRate > $1.refreshRate }
    }

    /// `target`'s size, kept at `rate` if that size offers it.
    ///
    /// Resolution rows come from `curated`, which picks the *highest* rate at each size. Switching to
    /// such a row directly is what silently pushed a display the user had set to 120 Hz back up to
    /// 170 Hz on every resolution change.
    ///
    /// Falls back to `target` rather than to the numerically nearest rate: if the requested rate is
    /// gone, the curated pick (highest available) is a better answer than, say, dropping 120 Hz to
    /// 60 Hz because 60 happens to be closer than 170.
    public static func mode(
        matchingSizeOf target: DisplayMode, preservingRate rate: Double, in modes: [DisplayMode]
    ) -> DisplayMode {
        guard rate > 0 else { return target }
        let wanted = Int(rate.rounded())
        let candidates = refreshRates(
            forWidth: target.width, height: target.height, hiDPI: target.isHiDPI, in: modes)
        return candidates.first { Int($0.refreshRate.rounded()) == wanted } ?? target
    }
}
