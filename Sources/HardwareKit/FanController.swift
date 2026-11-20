import AppKit
import Combine
import OneMacUI

/// Fan modes offered in the panel. `custom` holds a percentage of the fan's maximum speed.
public enum FanMode: Equatable, Sendable {
    case system
    case medium            // 50 % of max
    case high              // 80 % of max
    case custom(Double)    // 0...1 of max

    var fraction: Double? {
        switch self {
        case .system: return nil
        case .medium: return 0.5
        case .high: return 0.8
        case .custom(let f): return f
        }
    }
}

/// Reads fan speeds and applies the chosen mode through the root helper. A manual speed is guarded
/// four ways: back to System on quit and before sleep; the helper's own watchdog when the app dies;
/// `FanGuard` whenever the CPU is hot or its temperature cannot be read; and a return to System that
/// failed stays owed and is retried on every sample.
@MainActor
public final class FanController: ObservableObject {
    public static let shared = FanController()

    private static let manualFlagKey = "fan_manual_active"

    @Published public internal(set) var fans: [FanInfo] = [] { didSet { updateGuardNeed() } }
    /// What the fans were last asked to do. It only says System once the helper confirmed it.
    @Published public private(set) var mode: FanMode = .system { didSet { updateGuardNeed() } }
    @Published public internal(set) var helperStatus: FanHelper.Status = .missing
    @Published public internal(set) var message: String?
    @Published public internal(set) var isBusy = false
    /// True while the CPU is hot: slow manual speeds are refused and undone, cooling ones stay.
    @Published public private(set) var thermalLockout = false

    let queue = DispatchQueue(label: "com.onemac.fan", qos: .userInitiated)
    private var sleepObserver: NSObjectProtocol?
    /// False for a preview render or a second copy of the app: it shows readings and touches nothing.
    private var started = false
    /// A return to System was asked for and the helper has not confirmed it yet.
    private var restorePending = false { didSet { updateGuardNeed() } }
    /// Helper calls still running, and a stamp so a superseded call does not report back.
    private var inFlight = 0
    private var generation = 0
    private var blindSamples = 0
    private var idleSamples = 0

    private init() {}

    public var hasFans: Bool { !fans.isEmpty }

    /// Survives a crash: set while this app holds a fan at a manual speed.
    private var manualFlag: Bool {
        get { UserDefaults.standard.bool(forKey: Self.manualFlagKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.manualFlagKey) }
    }

    public func start(readOnly: Bool = false) {
        fans = FanInfo.readAll()
        guard hasFans else { return }
        refreshHelperStatus()
        HardwareMonitor.shared.onSample = { [weak self] thermal, fans in self?.didSample(thermal, fans) }
        guard !readOnly, !Self.anotherInstanceIsRunning else { return }
        started = true
        // After a crash the helper's watchdog normally hands the fans back. If our flag is still up
        // and a fan is still pinned, undo it; fans another tool put in manual are left alone.
        if manualFlag {
            if fans.contains(where: \.isManual) { restoreSystem() } else { manualFlag = false }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // Synchronous on purpose: macOS waits for this block, not for work it schedules.
            MainActor.assumeIsolated {
                guard let self, self.mode != .system else { return }
                self.restoreSystemSync()
                if self.mode == .system {
                    self.message = tr("Fans were returned to System for sleep.", "Đã trả quạt về Hệ thống khi máy ngủ.")
                }
            }
        }
        updateGuardNeed()
    }

    public func setMode(_ newMode: FanMode) {
        guard started, hasFans else { return }
        guard let fraction = newMode.fraction else {
            guard mode != .system || manualFlag || restorePending else { return }
            message = nil
            restoreSystem()
            return
        }
        guard helperStatus == .ready else {
            message = tr("Install the helper to control the fans.", "Cần cài helper để điều khiển quạt.")
            return
        }
        guard HardwareMonitor.shared.thermal.cpuHottest != nil else {
            message = tr("No CPU temperature reading — fans stay on System.",
                         "Không đọc được nhiệt độ CPU — quạt giữ ở chế độ Hệ thống.")
            return
        }
        guard FanGuard.allows(fraction: fraction, hot: thermalLockout) else {
            let floor = Int(FanGuard.coolingFloor * 100), resume = Int(FanGuard.resume)
            message = tr("The Mac is hot — only speeds of \(floor)% or more until below \(resume)°C.",
                         "Máy đang nóng — chỉ cho tốc độ từ \(floor)% trở lên tới khi dưới \(resume)°C.")
            return
        }
        mode = newMode
        message = nil
        restorePending = false
        manualFlag = true
        let pid = ProcessInfo.processInfo.processIdentifier
        let targets = fans.map { fan in
            (fan.id, Int(max(fan.minRPM, min(fan.maxRPM, fan.maxRPM * fraction)).rounded()))
        }
        runHelper({
            for (id, rpm) in targets {
                if let error = FanHelper.invoke(["set", "\(id)", "\(rpm)", "\(pid)"]) { return error }
            }
            return nil
        }, then: { [weak self] error, _ in
            guard let self, let error else { return }
            self.restoreSystem(note: tr("Couldn't set the fan speed: \(error)", "Không đặt được tốc độ quạt: \(error)"))
        })
    }

    /// Synchronous restore for quit and sleep, where the process may not get another chance. If it
    /// fails the flag stays up for the next launch, and the helper's watchdog covers the quit.
    public func restoreSystemSync() {
        guard started, hasFans, mode != .system || manualFlag || restorePending else { return }
        generation += 1
        if queue.sync(execute: { FanHelper.invoke(["auto-all"]) }) == nil {
            finishRestore()
        } else {
            restorePending = true
        }
    }

    /// Hands every fan back to macOS. `mode` keeps the manual choice until the helper confirms, so
    /// the panel never claims System over a fan that is still pinned.
    func restoreSystem(note: String? = nil) {
        restorePending = true
        runHelper({ FanHelper.invoke(["auto-all"]) }, then: { [weak self] error, fans in
            guard let self else { return }
            if error == nil || !fans.contains(where: \.isManual) {
                self.finishRestore()
                if let note { self.message = note }
            } else {
                self.message = tr("Couldn't return the fans to System — trying again. (\(error ?? ""))",
                                  "Chưa trả được quạt về Hệ thống — đang thử lại. (\(error ?? ""))")
            }
        })
    }

    func finishRestore() {
        mode = .system
        restorePending = false
        manualFlag = false
        idleSamples = 0
    }

    /// Runs helper calls off the main thread, then reports with a fresh fan reading — unless a newer
    /// call has replaced this one meanwhile.
    func runHelper(_ work: @escaping @Sendable () -> String?, then done: @escaping @MainActor (String?, [FanInfo]) -> Void) {
        generation += 1
        let mine = generation
        inFlight += 1
        queue.async { [weak self] in
            let error = work()
            let fans = FanInfo.readAll()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight -= 1
                guard mine == self.generation else { return }
                if fans != self.fans { self.fans = fans }
                done(error, fans)
            }
        }
    }

    private func didSample(_ thermal: ThermalSnapshot, _ updated: [FanInfo]) {
        if updated != fans { fans = updated }
        guard started else { return }
        let hot = FanGuard.isHot(wasHot: thermalLockout, hottest: thermal.cpuHottest)
        if hot != thermalLockout { thermalLockout = hot }
        blindSamples = thermal.cpuHottest == nil ? blindSamples + 1 : 0
        guard inFlight == 0 else { return }

        let manual = fans.filter(\.isManual)
        if manual.isEmpty {
            // The fans are on automatic. If that was not our doing (the helper's watchdog, another
            // tool), follow — after two samples, since one may predate our own last change.
            idleSamples = mode == .system ? 0 : idleSamples + 1
            if restorePending || idleSamples >= 2 { finishRestore() }
            return
        }
        idleSamples = 0
        if restorePending { return restoreSystem() }
        // The guard watches the real state, so it also covers a fan this app did not pin.
        guard helperStatus == .ready else { return }
        switch FanGuard.verdict(manualFractions: manual.map { $0.targetRPM / $0.maxRPM }, hot: hot,
                                blindSamples: blindSamples) {
        case .keep: break
        case .releaseHot:
            restoreSystem(note: tr("CPU ≥ \(Int(FanGuard.cutoff))°C — fans returned to System.",
                                   "CPU ≥ \(Int(FanGuard.cutoff))°C — đã trả quạt về Hệ thống."))
        case .releaseBlind:
            restoreSystem(note: tr("No CPU temperature reading — fans returned to System.",
                                   "Không đọc được nhiệt độ CPU — đã trả quạt về Hệ thống."))
        }
    }

    /// Keeps the sensors sampled with the panel closed for as long as any fan is, or may be, manual.
    private func updateGuardNeed() {
        HardwareMonitor.shared.setBackgroundNeed(
            .fanGuard, started && (mode != .system || restorePending || fans.contains(where: \.isManual)))
    }

    private static var anotherInstanceIsRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }
}
