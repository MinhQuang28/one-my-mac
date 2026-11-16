import AppKit
import Combine

/// Publishes CPU / RAM / GPU load and owns the "show on the menu bar" switches.
/// Samples only while the panel is open or a menu-bar switch is on — otherwise no timer runs.
@MainActor
public final class SystemUsageMonitor: ObservableObject {
    public static let shared = SystemUsageMonitor()
    private static let interval: TimeInterval = 2.5

    private enum Key {
        static let temperature = "menubar_show_temperature"
        static let cpuRAM = "menubar_show_cpu_ram"
        static let gpu = "menubar_show_gpu"
    }

    @Published public var showTemperature: Bool {
        didSet {
            UserDefaults.standard.set(showTemperature, forKey: Key.temperature)
            HardwareMonitor.shared.setBackgroundNeed(.menuBarTemperature, showTemperature)
        }
    }
    @Published public var showCPURAM: Bool {
        didSet { UserDefaults.standard.set(showCPURAM, forKey: Key.cpuRAM); syncPolling() }
    }
    @Published public var showGPU: Bool {
        didSet { UserDefaults.standard.set(showGPU, forKey: Key.gpu); syncPolling() }
    }
    @Published public private(set) var usage: SystemUsage = .empty
    /// Becomes true the first time an accelerator reports utilisation.
    @Published public private(set) var hasGPU = false

    private let queue = DispatchQueue(label: "com.onemac.system-usage", qos: .utility)
    private let sampler = SystemUsageSampler() // touched on `queue` only
    private var timer: Timer?
    private var isVisible = false
    private var started = false
    private var sampling = false
    private var wakeObserver: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults.standard
        showTemperature = defaults.bool(forKey: Key.temperature)
        showCPURAM = defaults.bool(forKey: Key.cpuRAM)
        showGPU = defaults.bool(forKey: Key.gpu)
    }

    public func start() {
        guard !started else { return }
        started = true
        HardwareMonitor.shared.setBackgroundNeed(.menuBarTemperature, showTemperature)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartBaseline() }
        }
        syncPolling()
    }

    /// The panel shows live values even when nothing is on the menu bar.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        syncPolling()
    }

    /// Text next to the menu-bar icon, or nil when every switch is off.
    public func menuBarText(temperature: Double?) -> String? {
        var parts: [String] = []
        if showTemperature, let temperature { parts.append(String(format: "%.0f°", temperature)) }
        if showCPURAM {
            parts.append("CPU \(Self.percent(usage.cpu)) · RAM \(Self.percent(usage.ram))")
        }
        if showGPU, hasGPU { parts.append("GPU \(Self.percent(usage.gpu))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0))%" } ?? "—"
    }

    private var shouldPoll: Bool { started && (isVisible || showCPURAM || showGPU) }

    private func syncPolling() {
        guard shouldPoll else {
            timer?.invalidate()
            timer = nil
            queue.async { [sampler] in sampler.reset() }
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = Self.interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        primeBaseline()
    }

    /// CPU load is a delta: take a baseline now and a first real value shortly after.
    private func primeBaseline() {
        sample()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sample() }
    }

    private func restartBaseline() {
        guard shouldPoll else { return }
        queue.async { [sampler] in sampler.reset() }
        primeBaseline()
    }

    private func sample() {
        guard shouldPoll, !sampling else { return }
        sampling = true
        // The GPU lookup walks the IORegistry; skip it unless someone is looking at the number.
        let includeGPU = isVisible || showGPU
        queue.async { [weak self, sampler] in
            let reading = sampler.sample(includeGPU: includeGPU)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                // Whole percents only: the menu bar must not redraw for a change nobody can see.
                // A baseline reading has no CPU value and a skipped GPU lookup none either: keep the last.
                let usage = SystemUsage(cpu: reading.cpu?.rounded() ?? self.usage.cpu,
                                        ram: reading.ram?.rounded() ?? self.usage.ram,
                                        gpu: includeGPU ? reading.gpu?.rounded() : self.usage.gpu)
                if usage.gpu != nil, !self.hasGPU { self.hasGPU = true }
                if self.usage != usage { self.usage = usage }
            }
        }
    }
}
