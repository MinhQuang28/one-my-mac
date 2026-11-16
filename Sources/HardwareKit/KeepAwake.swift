import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac (and optionally the display) awake with an IOKit power assertion, like `caffeinate`.
@MainActor
public final class KeepAwake: ObservableObject {
    public static let shared = KeepAwake()

    /// Duration presets in minutes; 0 means until turned off.
    public static let presets: [Int] = [0, 30, 60, 120]

    @Published public private(set) var isActive = false
    @Published public private(set) var endsAt: Date?
    @Published public var keepDisplayOn: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplayOn, forKey: "keepawake_display")
            if isActive { activate(minutes: selectedMinutes) }
        }
    }
    @Published public var selectedMinutes: Int {
        didSet { UserDefaults.standard.set(selectedMinutes, forKey: "keepawake_minutes") }
    }

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        keepDisplayOn = defaults.object(forKey: "keepawake_display") as? Bool ?? true
        selectedMinutes = defaults.integer(forKey: "keepawake_minutes")
    }

    public func setActive(_ on: Bool) {
        on ? activate(minutes: selectedMinutes) : deactivate()
    }

    public func activate(minutes: Int) {
        releaseAssertion()
        let type = (keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                  : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "OneMac: keep awake" as CFString, &assertion)
        guard result == kIOReturnSuccess else {
            assertion = 0
            isActive = false
            return
        }
        isActive = true
        timer?.invalidate()
        if minutes > 0 {
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            endsAt = end
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.deactivate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            endsAt = nil
        }
    }

    public func deactivate() {
        timer?.invalidate()
        timer = nil
        releaseAssertion()
        isActive = false
        endsAt = nil
    }

    private func releaseAssertion() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
