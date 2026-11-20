import CoreGraphics
import Foundation

/// Runtime binding for the SkyLight / CoreGraphics SPI behind two features public CoreGraphics cannot
/// provide:
///
/// * **Hidden display modes.** `CGDisplayCopyAllDisplayModes` leaves out HiDPI modes WindowServer
///   does offer — looks-like 2560 × 1440 on a 1440p panel is the usual example. The SkyLight mode
///   list has them, and `CGSConfigureDisplayMode` selects one by mode number.
/// * **Soft reconnect.** `SLSConfigureDisplayEnabled` takes a display out of the layout and puts it
///   back, which makes macOS re-read its override file without a cable pull or a logout.
///
/// **Evidence level: experimental observation** — names, signatures and the mode-description layout
/// come from open-source implementations (Crisp, MIT) and were ported from S-Display, not from Apple
/// documentation. See docs/hidisplay/private-apis.md.
///
/// Every symbol is optional: a macOS release that drops one hides the matching feature instead of
/// crashing. Immutable after `init`, so the shared instance is safe from any isolation domain.
public final class SkyLightDisplayShim: @unchecked Sendable {

    public static let shared = SkyLightDisplayShim()

    /// A mode from SkyLight's list, with the number `configureMode` needs to select it.
    public struct HiddenMode: Sendable {
        public var mode: DisplayMode
        public var modeNumber: Int32
    }

    private typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> Int32
    private typealias DisplayListFn =
        @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias ModeCountFn = @convention(c) (UInt32, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias ModeDescriptionFn =
        @convention(c) (UInt32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias ConfigureModeFn = @convention(c) (CGDisplayConfigRef?, UInt32, Int32) -> Int32

    private let configureEnabledFn: ConfigureEnabledFn?
    private let displayListFn: DisplayListFn?
    private let modeCountFn: ModeCountFn?
    private let modeDescriptionFn: ModeDescriptionFn?
    private let configureModeFn: ConfigureModeFn?

    /// Size of `CGSDisplayModeDescription`, and the "not usable for the desktop" flag bit.
    private static let descriptionLength = 212
    private static let unusableFlag: UInt32 = 0x4000_0000

    private init() {
        let handles = [
            dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
        ]

        // The same entry points exist under an `SLS` and a `CGS` prefix depending on the release.
        func symbol<T>(_ names: [String], as type: T.Type) -> T? {
            for name in names {
                for handle in handles {
                    if let found = resolveSymbol(handle, name, as: type) { return found }
                }
            }
            return nil
        }

        configureEnabledFn = symbol(
            ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"], as: ConfigureEnabledFn.self)
        displayListFn = symbol(["SLSGetDisplayList", "CGSGetDisplayList"], as: DisplayListFn.self)
        modeCountFn = symbol(
            ["CGSGetNumberOfDisplayModes", "SLSGetNumberOfDisplayModes"], as: ModeCountFn.self)
        modeDescriptionFn = symbol(
            ["CGSGetDisplayModeDescriptionOfLength", "SLSGetDisplayModeDescriptionOfLength"],
            as: ModeDescriptionFn.self)
        configureModeFn = symbol(
            ["CGSConfigureDisplayMode", "SLSConfigureDisplayMode"], as: ConfigureModeFn.self)

        Log.shims.debug(
            "SkyLight display symbols: toggle \(self.canToggleDisplays), modes \(self.canListModes)")
    }

    /// Turning a display off and on needs both the toggle and the list that still shows it while off.
    public var canToggleDisplays: Bool { configureEnabledFn != nil && displayListFn != nil }

    /// Listing hidden modes is only useful when one of them can also be selected.
    public var canListModes: Bool {
        modeCountFn != nil && modeDescriptionFn != nil && configureModeFn != nil
    }

    /// Adds "enable/disable this display" to an open configuration transaction.
    func configureEnabled(
        _ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, enabled: Bool
    ) -> CGError {
        guard let configureEnabledFn else { return .notImplemented }
        return CGError(rawValue: configureEnabledFn(config, display, enabled)) ?? .failure
    }

    /// Adds "switch to SkyLight mode `modeNumber`" to an open configuration transaction.
    /// The first argument must be the transaction token: passing a connection id crashes on macOS 26+.
    func configureMode(
        _ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, modeNumber: Int32
    ) -> CGError {
        guard let configureModeFn else { return .notImplemented }
        return CGError(rawValue: configureModeFn(config, display, modeNumber)) ?? .failure
    }

    /// Every display WindowServer knows about, including ones disabled with `configureEnabled`,
    /// which `CGGetOnlineDisplayList` leaves out.
    public func allDisplayIDs() -> [CGDirectDisplayID] {
        guard let displayListFn else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard displayListFn(UInt32(ids.count), &ids, &count) == 0 else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The desktop-usable modes in SkyLight's list for `display`.
    ///
    /// Reads `CGSDisplayModeDescription` by offset: mode number @0, flags @4, width @8, height @12,
    /// refresh Hz @190 (UInt16), backing scale @208 (Float).
    public func modes(for display: CGDirectDisplayID) -> [HiddenMode] {
        guard canListModes, let modeCountFn, let modeDescriptionFn else { return [] }
        var count: Int32 = 0
        guard modeCountFn(display, &count) == 0, count > 0 else { return [] }

        let length = Self.descriptionLength
        var buffer = [UInt8](repeating: 0, count: length)
        var result: [HiddenMode] = []
        for index in 0 ..< count {
            let status = buffer.withUnsafeMutableBytes {
                modeDescriptionFn(display, index, $0.baseAddress, Int32(length))
            }
            guard status == 0 else { continue }
            if let mode = Self.decode(buffer) { result.append(mode) }
        }
        return result
    }

    /// Decodes one mode description; `nil` for a short buffer, a mode flagged unusable, or one with
    /// a zero dimension or a scale below 1.
    static func decode(_ bytes: [UInt8]) -> HiddenMode? {
        guard bytes.count >= descriptionLength else { return nil }
        return bytes.withUnsafeBytes { raw in
            let number = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let flags = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let width = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let height = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            let refresh = Double(raw.loadUnaligned(fromByteOffset: 190, as: UInt16.self))
            let density = Double(raw.loadUnaligned(fromByteOffset: 208, as: Float.self))
            guard flags & unusableFlag == 0, width > 0, height > 0,
                  width <= 16384, height <= 16384, density >= 1, density <= 4
            else { return nil }
            return HiddenMode(
                mode: DisplayMode(
                    width: width,
                    height: height,
                    pixelWidth: Int((Double(width) * density).rounded()),
                    pixelHeight: Int((Double(height) * density).rounded()),
                    refreshRate: refresh,
                    ioDisplayModeID: nil,
                    isUsableForDesktop: true),
                modeNumber: Int32(bitPattern: number))
        }
    }
}
