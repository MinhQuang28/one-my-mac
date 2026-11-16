import AppKit
import Combine

/// Publishes battery and temperature readings. Polls every few seconds while the panel is open.
/// With the panel closed it polls slowly, and only while something still needs the numbers (see
/// `BackgroundNeed`) — otherwise no timer runs and the sensors are left alone.
@MainActor
public final class HardwareMonitor: ObservableObject {
    public static let shared = HardwareMonitor()

    @Published public private(set) var battery: BatterySnapshot?
    @Published public private(set) var thermal: ThermalSnapshot = .empty

    /// Called after every sample; the fan controller hooks its temperature guard here.
    var onSample: ((ThermalSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "com.onemac.hardware", qos: .utility)
    private var timer: Timer?
    private var isVisible = false
    private var sampling = false
    private var started = false
    private var backgroundNeeds: Set<BackgroundNeed> = []

    /// Why readings are wanted while the panel is closed.
    enum BackgroundNeed {
        /// A fan is on a manual speed: the temperature guard must keep watching.
        case fanGuard
        /// The CPU temperature is shown next to the menu-bar icon.
        case menuBarTemperature
    }

    private init() {}

    public func start() {
        started = true
        sample()
        reschedule()
    }

    /// Registers or withdraws a reason to keep sampling in the background. Turning one on samples
    /// right away, so a guard never acts on a stale temperature.
    func setBackgroundNeed(_ need: BackgroundNeed, _ needed: Bool) {
        guard needed != backgroundNeeds.contains(need) else { return }
        if needed { backgroundNeeds.insert(need) } else { backgroundNeeds.remove(need) }
        guard started else { return }
        if needed { sample() }
        reschedule()
    }

    /// Faster refresh while the menu-bar panel is open.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        SystemUsageMonitor.shared.setVisible(visible)
        if visible { sample() }
        reschedule()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isVisible || !backgroundNeeds.isEmpty else { return }
        let interval: TimeInterval = isVisible ? 2.5 : 15
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func sample() {
        guard !sampling else { return }
        sampling = true
        queue.async { [weak self] in
            let thermal = HardwareReaders.thermal()
            let battery = HardwareReaders.battery(fallbackTemperature: thermal.battery)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                if self.thermal != thermal { self.thermal = thermal }
                if self.battery != battery { self.battery = battery }
                self.onSample?(thermal)
            }
        }
    }
}
