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
    /// One look for every break, or a different one each time.
    @Published public var style: BreakStyleChoice { didSet { save(style.stored, "style"); overlay.hide() } }
    @Published public var chime: Bool { didSet { save(chime, "chime") } }
    /// Minutes to the next break next to the menu-bar icon.
    @Published public var showInMenuBar: Bool { didSet { save(showInMenuBar, "menu_bar") } }

    /// Where the schedule stands; nil while eye breaks are off.
    @Published private(set) var phase: BreakSchedule.Phase?
    /// Counts breaks, so each one shows a different tip; kept across restarts.
    @Published private(set) var breakCount: Int { didSet { save(breakCount, "count") } }
    /// Breaks taken and skipped today.
    @Published private(set) var stats = BreakStats()

    private var schedule: BreakSchedule
    private var timer: Timer?
    private var started = false
    /// Screen locked or displays asleep: nobody is looking, so it counts as rest.
    private var screenUnavailable = false
    private var lastTick = Date()
    private lazy var overlay = BreakOverlay { [weak self] in self?.endBreakEarly() }

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
        showInMenuBar = bool("menu_bar", true)
        style = BreakStyleChoice(stored: d.string(forKey: Self.prefix + "style"))
        breakCount = max(0, d.integer(forKey: Self.prefix + "count"))
        schedule = BreakSchedule(interval: 0, breakLength: 0, headsUpLead: 0, now: Date())
        rebuild()
        let pausedUntil = Date(timeIntervalSince1970: d.double(forKey: Self.prefix + "paused_until"))
        if pausedUntil > Date() { schedule.pause(until: pausedUntil, now: Date()) }
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
        if isPaused { resumeFromPause() } // asking for a break ends the pause
        schedule.startBreak(now: Date())
        tick()
    }

    /// Ends the break (or cancels the upcoming one) and counts a full interval again.
    public func skip() { reschedule(after: schedule.interval) }

    public func postpone(minutes: Int) { reschedule(after: TimeInterval(minutes * 60)) }

    /// No breaks for the next `hours` hours.
    public func pause(hours: Int) { pause(until: Date().addingTimeInterval(TimeInterval(hours * 3600))) }

    /// No breaks for the rest of today.
    public func pauseUntilTomorrow() {
        let today = Calendar.current.startOfDay(for: Date())
        pause(until: Calendar.current.date(byAdding: .day, value: 1, to: today) ?? Date().addingTimeInterval(86400))
    }

    /// Ends a pause; a full interval is counted from now.
    public func resumeFromPause() {
        guard enabled else { return }
        schedule.resume(now: Date())
        save(0.0, "paused_until")
        refresh()
    }

    public var isPaused: Bool { if case .paused = phase { return true } else { return false } }

    private func pause(until: Date) {
        guard enabled else { return }
        if isOnBreak { stats.record(taken: false) }
        schedule.pause(until: until, now: Date())
        save(until.timeIntervalSince1970, "paused_until")
        refresh()
    }

    /// The curtain's emergency exit: works even when skipping is turned off.
    private func endBreakEarly() { reschedule(after: schedule.interval) }

    private func reschedule(after delay: TimeInterval) {
        guard enabled else { return }
        if isOnBreak { stats.record(taken: false) }
        schedule.postpone(now: Date(), by: delay)
        refresh()
    }

    /// Shows where the schedule stands right after an action, without waiting for the next tick.
    private func refresh() { show(schedule.advance(now: Date(), idle: 0, busy: false)) }

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
        let pausedUntil = schedule.pausedUntil
        schedule = BreakSchedule(interval: TimeInterval(intervalMinutes * 60), breakLength: TimeInterval(breakSeconds),
                                 headsUpLead: headsUp ? Self.headsUpSeconds : 0, now: Date())
        if let pausedUntil { schedule.pause(until: pausedUntil, now: Date()) }
    }

    private func tick() {
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = screenUnavailable ? .infinity
            : CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let wasOnBreak = isOnBreak, now = Date()
        // A late tick means the Mac slept: the break did not really run, so it ends without a word.
        let uninterrupted = !screenUnavailable && abs(now.timeIntervalSince(lastTick)) < 5
        lastTick = now
        if stats.day != Calendar.current.startOfDay(for: now) { stats.rollOver(now: now) }
        show(schedule.advance(now: now, idle: idle,
                              busy: deferForMedia && MediaActivity.isBusy(),
                              watching: !screenUnavailable && MediaActivity.isAnotherAppKeepingDisplayOn()))
        guard wasOnBreak, !isOnBreak, uninterrupted else { return }
        stats.record(taken: true, now: now)
        // The break ran its full length: eyes are off the screen, so say it is over out loud.
        if chime { NSSound(named: "Glass")?.play() }
    }

    private var isOnBreak: Bool { if case .onBreak = phase { return true } else { return false } }

    private func show(_ next: BreakSchedule.Phase) {
        if case .onBreak = next, !isOnBreak { breakCount += 1 }
        // While working only the minute is on show: publish when it changes, not every second.
        if !Self.looksTheSame(phase, next) { phase = next }
        switch next {
        // A break that gave up waiting for a call never covers the screen.
        case .onBreak: overlay.showBreak(style: style.style(forBreak: breakCount, gentle: schedule.breakIsGentle))
        case .headsUp: overlay.showNotice()
        case .working, .deferred, .paused: overlay.hide()
        }
    }

    private static func looksTheSame(_ old: BreakSchedule.Phase?, _ new: BreakSchedule.Phase) -> Bool {
        if case let .working(a)? = old, case let .working(b) = new { return (a / 60).rounded(.up) == (b / 60).rounded(.up) }
        return old == new
    }

    #if DEBUG
    /// For `BreakStylePreview`: a break (or the heads-up) frozen part-way, without a running schedule.
    func freezeForPreview(notice: Bool) {
        phase = notice ? .headsUp(remaining: 22) : .onBreak(remaining: Double(breakSeconds) * 0.6)
    }
    #endif

    // MARK: Persistence

    private static let prefix = "eyebreak_"
    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: Self.prefix + key) }
}
