import AppKit
import IOKit.pwr_mgt
import OneMacUI

/// Keeps the Mac (and optionally the display) awake with an IOKit power assertion, like `caffeinate`.
@MainActor
public final class KeepAwake: ObservableObject {
    public static let shared = KeepAwake()

    /// Duration presets in minutes; 0 means until turned off.
    public static let presets: [Int] = [0, 30, 60, 120]

    @Published public private(set) var isActive = false
    @Published public private(set) var endsAt: Date?
    /// Why keep-awake could not be turned on, when macOS refused the assertion.
    @Published public private(set) var message: String?
    @Published public var keepDisplayOn: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplayOn, forKey: "keepawake_display")
            // Swap the assertion type only: the countdown keeps its end time.
            if isActive { hold(until: endsAt) }
        }
    }
    @Published public var selectedMinutes: Int {
        didSet { UserDefaults.standard.set(selectedMinutes, forKey: "keepawake_minutes") }
    }

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        keepDisplayOn = defaults.object(forKey: "keepawake_display") as? Bool ?? true
        selectedMinutes = defaults.integer(forKey: "keepawake_minutes")
        // A timer does not count the time spent asleep (lid closed, forced sleep): on wake, measure
        // against the clock again.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, let end = self.endsAt else { return }
                self.schedule(end: end)
            }
        }
    }

    public func setActive(_ on: Bool) {
        on ? activate(minutes: selectedMinutes) : deactivate()
    }

    public func activate(minutes: Int) {
        hold(until: minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil)
    }

    /// Takes the assertion and ends it at `end`; nil means until turned off.
    private func hold(until end: Date?) {
        releaseAssertion()
        timer?.invalidate()
        timer = nil
        let type = (keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                  : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "OneMac: keep awake" as CFString, &assertion)
        guard result == kIOReturnSuccess else {
            assertion = 0
            isActive = false
            endsAt = nil
            message = tr("macOS refused to keep the Mac awake (error \(result)).",
                         "macOS từ chối giữ máy thức (lỗi \(result)).")
            return
        }
        message = nil
        isActive = true
        endsAt = end
        if let end { schedule(end: end) }
    }

    private func schedule(end: Date) {
        timer?.invalidate()
        timer = nil
        guard end > Date() else { return deactivate() }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.deactivate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
