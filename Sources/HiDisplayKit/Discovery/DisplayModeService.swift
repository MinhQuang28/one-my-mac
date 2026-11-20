import CoreGraphics
import Foundation

/// Reads display modes out of CoreGraphics.
public enum DisplayModeService {

    /// All desktop-usable modes for a display, deduplicated and sorted largest-logical-first.
    ///
    /// The options dictionary matters: without `kCGDisplayShowDuplicateLowResolutionModes`,
    /// CoreGraphics hides the 1x twin of every HiDPI mode, and the resulting list cannot be used to
    /// tell whether a HiDPI variant of a given logical size already exists — which is the exact
    /// question the HiDPI override UI has to answer before offering to generate one.
    public static func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }
        let listed = raw.compactMap(DisplayMode.init(cgMode:)).filter(\.isUsableForDesktop)
        return merged(listed: listed, hidden: SkyLightDisplayShim.shared.modes(for: displayID).map(\.mode))
    }

    /// CoreGraphics' modes plus the HiDPI ones only SkyLight lists, deduplicated and sorted.
    ///
    /// Only HiDPI modes are taken from the hidden list: those are what CoreGraphics is known to
    /// withhold (looks-like 2560 × 1440 on a 1440p panel), and admitting every 1× oddity SkyLight
    /// knows about would bury the picker. A listed mode always wins over its hidden twin, so the
    /// public API stays the route whenever it can do the job.
    static func merged(listed: [DisplayMode], hidden: [DisplayMode]) -> [DisplayMode] {
        var seen = Set<String>()
        var result: [DisplayMode] = []
        // Several CGDisplayMode objects can describe the same user-visible mode (different pixel
        // encodings). Keying on the logical/backing/refresh triple collapses them.
        for mode in listed where seen.insert(mode.id).inserted {
            result.append(mode)
        }
        for mode in hidden where mode.isHiDPI && mode.isUsableForDesktop {
            // SkyLight stores whole hertz, truncated: CoreGraphics' 59.94 Hz mode comes back as
            // 59, and a 0 Hz internal-panel mode as a real rate. Either is the same mode, and
            // admitting the twin would route a display through the private API for nothing.
            let hasListedTwin = listed.contains {
                $0.refreshRate == 0
                    ? DisplayModeSwitcher.sameGeometry($0, mode)
                    : DisplayModeSwitcher.sameShape($0, mode, tolerance: 1)
            }
            if !hasListedTwin, seen.insert(mode.id).inserted { result.append(mode) }
        }

        result.sort { lhs, rhs in
            if lhs.width * lhs.height != rhs.width * rhs.height {
                return lhs.width * lhs.height > rhs.width * rhs.height
            }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return lhs.refreshRate > rhs.refreshRate
        }
        return result
    }

    public static func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        guard let cgMode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return DisplayMode(cgMode: cgMode)
    }

    /// Whether a HiDPI mode of exactly this logical size is already offered by the system.
    /// Used to stop the override UI proposing something macOS already provides.
    public static func hasHiDPIMode(width: Int, height: Int, in modes: [DisplayMode]) -> Bool {
        modes.contains { $0.isHiDPI && $0.width == width && $0.height == height }
    }
}
