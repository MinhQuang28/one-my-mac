import Foundation

/// macOS's own charge limit (System Settings › Battery, macOS 15+), driven through the private
/// `PowerUISmartChargeClient`. The limit is stored by the system: it needs no root helper and keeps
/// working while the Mac sleeps or after OneMac quits.
///
/// Verified on macOS 26 (Mac15,3): `setMCLLimit:` also enables the limit, accepts only
/// 80/85/90/95/100 (anything lower fails with PowerUISmartChargingErrorDomain 4), and `disableMCL:`
/// puts the limit back to 100. Every call is a blocking XPC round trip — keep it off the main thread.
final class ChargeLimitClient {
    /// Limits the system accepts, besides "off".
    static let levels = [80, 85, 90, 95]

    private typealias ErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?
    private let client: NSObject

    init?() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/PowerUI.framework"), bundle.load(),
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { return nil }
        let allocSel = NSSelectorFromString("alloc"), initSel = NSSelectorFromString("initWithClientName:")
        guard cls.responds(to: allocSel), cls.instancesRespond(to: initSel) else { return nil }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (Unmanaged<AnyObject>, Selector, NSString) -> Unmanaged<AnyObject>?
        let raw = unsafeBitCast(cls.method(for: allocSel), to: AllocFn.self)(cls, allocSel)
        let made = unsafeBitCast(cls.instanceMethod(for: initSel), to: InitFn.self)(raw, initSel, "OneMac")
        guard let client = made?.takeRetainedValue() as? NSObject else { return nil }

        let needed = ["isMCLSupported", "isMCLCurrentlyEnabled:", "getMCLLimitWithError:",
                      "setMCLLimit:error:", "disableMCL:"]
        guard needed.allSatisfy({ client.responds(to: NSSelectorFromString($0)) }) else { return nil }
        typealias BoolFn = @convention(c) (AnyObject, Selector) -> Bool
        let supported = NSSelectorFromString("isMCLSupported")
        guard unsafeBitCast(client.method(for: supported), to: BoolFn.self)(client, supported) else { return nil }
        self.client = client
    }

    /// The active limit in percent, or nil when charging runs to 100 %.
    func currentLimit() -> Int? {
        typealias EnabledFn = @convention(c) (AnyObject, Selector, ErrorPointer) -> UInt64
        typealias LimitFn = @convention(c) (AnyObject, Selector, ErrorPointer) -> UInt8
        let enabledSel = NSSelectorFromString("isMCLCurrentlyEnabled:")
        let limitSel = NSSelectorFromString("getMCLLimitWithError:")
        let enabled = unsafeBitCast(client.method(for: enabledSel), to: EnabledFn.self)(client, enabledSel, nil)
        let limit = unsafeBitCast(client.method(for: limitSel), to: LimitFn.self)(client, limitSel, nil)
        return Self.activeLimit(enabled: enabled, limit: limit)
    }

    func setLimit(_ percent: Int) -> Bool {
        guard Self.levels.contains(percent) else { return false }
        typealias SetFn = @convention(c) (AnyObject, Selector, UInt8, ErrorPointer) -> Bool
        let sel = NSSelectorFromString("setMCLLimit:error:")
        return unsafeBitCast(client.method(for: sel), to: SetFn.self)(client, sel, UInt8(percent), nil)
    }

    func disable() -> Bool {
        typealias DisableFn = @convention(c) (AnyObject, Selector, ErrorPointer) -> Bool
        let sel = NSSelectorFromString("disableMCL:")
        return unsafeBitCast(client.method(for: sel), to: DisableFn.self)(client, sel, nil)
    }

    /// Maps the two raw answers to one value: a limit only counts when enabled and below 100.
    static func activeLimit(enabled: UInt64, limit: UInt8) -> Int? {
        guard enabled != 0, limit >= 50, limit < 100 else { return nil }
        return Int(limit)
    }
}
