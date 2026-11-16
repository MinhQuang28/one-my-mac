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

/// Reads fan speeds and applies the chosen mode through the root helper, with three guards:
/// back to System on quit, before sleep and at launch, and whenever the CPU reaches 90 °C.
@MainActor
public final class FanController: ObservableObject {
    public static let shared = FanController()

    static let cutoff = 90.0
    static let resume = 80.0
    private static let manualFlagKey = "fan_manual_active"

    @Published public private(set) var fans: [FanInfo] = []
    @Published public private(set) var mode: FanMode = .system {
        // The temperature guard only matters while a fan is held at a manual speed.
        didSet { HardwareMonitor.shared.setBackgroundNeed(.fanGuard, mode != .system) }
    }
    @Published public private(set) var helperStatus: FanHelper.Status = .missing
    @Published public private(set) var message: String?
    @Published public private(set) var isBusy = false
    /// True while the temperature guard holds the fans on System.
    @Published public private(set) var thermalLockout = false

    private let queue = DispatchQueue(label: "com.onemac.fan", qos: .userInitiated)
    private var sleepObserver: NSObjectProtocol?

    private init() {}

    public var hasFans: Bool { !fans.isEmpty }

    public func start() {
        fans = FanInfo.readAll()
        guard hasFans else { return }
        refreshHelperStatus()
        // A crash or force-quit in manual mode leaves the fan pinned: undo that first.
        if UserDefaults.standard.bool(forKey: Self.manualFlagKey) || fans.contains(where: \.isManual) {
            queue.async { FanHelper.invoke(["auto-all"]) }
            UserDefaults.standard.set(false, forKey: Self.manualFlagKey)
        }
        HardwareMonitor.shared.onSample = { [weak self] thermal in self?.didSample(thermal) }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restoreSystemSync() }
        }
    }

    public func refreshHelperStatus() {
        queue.async { [weak self] in
            let status = FanHelper.status()
            DispatchQueue.main.async { self?.helperStatus = status }
        }
    }

    public func installHelper() {
        isBusy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = FanHelper.install()
            let status = FanHelper.status()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.helperStatus = status
                self.message = error
            }
        }
    }

    public func setMode(_ newMode: FanMode) {
        guard hasFans else { return }
        if newMode != .system, thermalLockout {
            message = tr(
                "The Mac is hot (≥ \(Int(Self.cutoff))°C) — staying on System until below \(Int(Self.resume))°C.",
                "Máy đang nóng (≥ \(Int(Self.cutoff))°C) — giữ chế độ Hệ thống tới khi dưới \(Int(Self.resume))°C.")
            return
        }
        guard newMode == .system || helperStatus == .ready else {
            message = tr("Install the helper to control the fans.", "Cần cài helper để điều khiển quạt.")
            return
        }
        mode = newMode
        message = nil
        UserDefaults.standard.set(newMode != .system, forKey: Self.manualFlagKey)
        let targets: [(Int, Int)] = fans.map { fan in
            guard let fraction = newMode.fraction else { return (fan.id, -1) }
            let rpm = max(fan.minRPM, min(fan.maxRPM, fan.maxRPM * fraction))
            return (fan.id, Int(rpm.rounded()))
        }
        queue.async { [weak self] in
            var error: String?
            for (id, rpm) in targets {
                let args = rpm < 0 ? ["auto", "\(id)"] : ["set", "\(id)", "\(rpm)"]
                if let e = FanHelper.invoke(args) { error = e }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.message = tr("Couldn't set the fan speed: \(error)", "Không đặt được tốc độ quạt: \(error)")
                    if newMode != .system { self.setMode(.system) }
                }
            }
        }
    }

    /// Synchronous restore for quit and sleep, where the process may not get another chance.
    public func restoreSystemSync() {
        guard hasFans, mode != .system || UserDefaults.standard.bool(forKey: Self.manualFlagKey) else { return }
        mode = .system
        UserDefaults.standard.set(false, forKey: Self.manualFlagKey)
        queue.sync { _ = FanHelper.invoke(["auto-all"]) }
    }

    private func didSample(_ thermal: ThermalSnapshot) {
        let updated = FanInfo.readAll()
        if updated != fans { fans = updated }
        guard let hottest = thermal.cpuHottest else { return }
        if hottest >= Self.cutoff, !thermalLockout {
            thermalLockout = true
            if mode != .system {
                setMode(.system)
                message = tr("CPU ≥ \(Int(Self.cutoff))°C — fans returned to System.",
                             "CPU ≥ \(Int(Self.cutoff))°C — đã trả quạt về Hệ thống.")
            }
        } else if thermalLockout, hottest < Self.resume {
            thermalLockout = false
        }
    }
}
