import AppKit
import OneMacUI

/// Eye breaks: after a stretch of screen time, cover the displays for a short rest (the 20-20-20
/// habit: every 20 minutes, look 20 feet away for 20 seconds). Runs a one-second timer only while on.
@MainActor
public final class EyeBreaks: ObservableObject {
    public static let shared = EyeBreaks()

    public static let intervalChoices = [15, 20, 30, 45, 60]   // minutes
    public static let breakChoices = [20, 30, 60, 120]         // seconds
    static let headsUpSeconds: TimeInterval = 30
    /// Delays offered on the heads-up card, in minutes.
    static let postponeChoices = [1, 5, 15]

    @Published public var enabled: Bool { didSet { save(enabled, "enabled"); enabled ? resume() : halt() } }
    @Published public var intervalMinutes: Int { didSet { save(intervalMinutes, "interval"); rebuild() } }
    @Published public var breakSeconds: Int { didSet { save(breakSeconds, "length"); schedule.breakLength = TimeInterval(breakSeconds) } }
    @Published public var headsUp: Bool { didSet { save(headsUp, "headsup"); schedule.headsUpLead = headsUp ? Self.headsUpSeconds : 0 } }
    /// Hold the break back while a video, call or presentation keeps the display on.
    @Published public var deferForMedia: Bool { didSet { save(deferForMedia, "defer_media") } }
    @Published public var allowSkip: Bool { didSet { save(allowSkip, "allow_skip") } }
    /// Small card at the top centre instead of a curtain over every display.
    @Published public var compact: Bool { didSet { save(compact, "compact"); overlay.hide() } }
    @Published public var chime: Bool { didSet { save(chime, "chime") } }

    /// Where the schedule stands; nil while eye breaks are off.
    @Published private(set) var phase: BreakSchedule.Phase?
    /// Counts breaks, so each one shows a different tip.
    @Published private(set) var breakCount = 0

    private var schedule: BreakSchedule
    private var timer: Timer?
    private var started = false
    /// Screen locked or displays asleep: nobody is looking, so it counts as rest.
    private var screenUnavailable = false
    private let overlay = BreakOverlay()

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: Self.prefix + key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int, in choices: [Int]) -> Int {
            let value = d.integer(forKey: Self.prefix + key)
            return choices.contains(value) ? value : fallback
        }
        enabled = bool("enabled", false)
        intervalMinutes = int("interval", 20, in: Self.intervalChoices)
        breakSeconds = int("length", 20, in: Self.breakChoices)
        headsUp = bool("headsup", true)
        deferForMedia = bool("defer_media", true)
        allowSkip = bool("allow_skip", true)
        chime = bool("chime", true)
        compact = bool("compact", false)
        schedule = BreakSchedule(interval: 0, breakLength: 0, headsUpLead: 0, now: Date())
        rebuild()
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter, distributed = DistributedNotificationCenter.default()
        for (center, name, away) in [
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ] as [(NotificationCenter, Notification.Name, Bool)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenUnavailable = away }
            }
        }
        if enabled { resume() }
    }

    public func stop() { halt() }

    // MARK: Actions

    public func takeBreakNow() {
        guard enabled else { return }
        schedule.startBreak(now: Date())
        tick()
    }

    /// Ends the break (or cancels the upcoming one) and counts a full interval again.
    public func skip() { reschedule(after: schedule.interval) }

    public func postpone(minutes: Int) { reschedule(after: TimeInterval(minutes * 60)) }

    private func reschedule(after delay: TimeInterval) {
        guard enabled else { return }
        schedule.postpone(now: Date(), by: delay)
        show(schedule.advance(now: Date(), idle: 0, busy: false))
    }

    // MARK: Timer

    private func resume() {
        guard started, timer == nil else { return }
        rebuild()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func halt() {
        timer?.invalidate()
        timer = nil
        phase = nil
        overlay.hide()
    }

    private func rebuild() {
        schedule = BreakSchedule(interval: TimeInterval(intervalMinutes * 60), breakLength: TimeInterval(breakSeconds),
                                 headsUpLead: headsUp ? Self.headsUpSeconds : 0, now: Date())
    }

    private func tick() {
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = screenUnavailable ? .infinity
            : CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let wasOnBreak = isOnBreak
        show(schedule.advance(now: Date(), idle: idle,
                              busy: deferForMedia && MediaActivity.isAnotherAppKeepingDisplayOn()))
        // The break ran its full length: eyes are off the screen, so say it is over out loud.
        if wasOnBreak, !isOnBreak, chime { NSSound(named: "Glass")?.play() }
    }

    private var isOnBreak: Bool { if case .onBreak = phase { return true } else { return false } }

    private func show(_ next: BreakSchedule.Phase) {
        if case .onBreak = next, !isOnBreak { breakCount += 1 }
        phase = next
        switch next {
        case .onBreak: overlay.showBreak(compact: compact)
        case .headsUp: overlay.showNotice()
        case .working, .deferred: overlay.hide()
        }
    }

    // MARK: Persistence

    private static let prefix = "eyebreak_"
    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: Self.prefix + key) }
}
