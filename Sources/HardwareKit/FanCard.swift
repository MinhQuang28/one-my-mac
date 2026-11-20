import OneMacUI
import SwiftUI

/// CPU temperatures plus fan control (System / Medium / High / slider). Fan part hides on fanless Macs.
public struct ThermalFanCard: View {
    @ObservedObject private var monitor = HardwareMonitor.shared
    @ObservedObject private var fans = FanController.shared
    @State private var sliderValue: Double = 0
    @State private var dragging = false
    public init() {}

    public var body: some View {
        Card {
            CardHeader(icon: "thermometer.medium", tint: tempColor(monitor.thermal.cpuHottest),
                       title: tr("Temperature", "Nhiệt độ"), subtitle: statusText) {
                Text(monitor.thermal.cpuAverage.map { String(format: "%.0f°C", $0) } ?? "—")
                    .font(.system(size: FS.value, weight: .bold)).monospacedDigit()
                    .foregroundStyle(tempColor(monitor.thermal.cpuAverage))
            }
            HStack(spacing: Gap.sm - 2) {
                StatTile(tr("CPU average", "CPU trung bình"), value: format(monitor.thermal.cpuAverage),
                         valueColor: tempColor(monitor.thermal.cpuAverage))
                StatTile(tr("CPU hottest", "CPU nóng nhất"), value: format(monitor.thermal.cpuHottest),
                         valueColor: tempColor(monitor.thermal.cpuHottest))
                StatTile(tr("Battery", "Pin"), value: format(monitor.thermal.battery))
            }
            if fans.hasFans {
                Divider().padding(.vertical, 2)
                fanSection
            }
        }
    }

    @ViewBuilder
    private var fanSection: some View {
        HStack {
            Label(tr("Fans", "Quạt"), systemImage: "fanblades.fill")
                .font(.system(size: FS.title, weight: .semibold))
            Spacer()
            Text(rpmText).font(.system(size: FS.title, weight: .semibold)).monospacedDigit()
        }
        ChipPicker([(0, tr("System", "Hệ thống")), (1, tr("Medium", "Trung bình")), (2, tr("High", "Cao"))],
                   selection: Binding(
            get: { modeIndex },
            set: { fans.setMode([FanMode.system, .medium, .high][$0]) }))
            .disabled(fans.isBusy)
        if let fan = fans.fans.first {
            VStack(alignment: .leading, spacing: 2) {
                CapsuleSlider(value: Binding(get: { dragging ? sliderValue : currentFraction(fan) },
                                             set: { sliderValue = $0 }),
                              in: min(max(fan.minRPM / fan.maxRPM, 0), 0.99)...1,
                              icon: "fan.fill", label: tr("Fan speed", "Tốc độ quạt"),
                              onEditingChanged: { editing in
                                  if editing { sliderValue = currentFraction(fan) }
                                  dragging = editing
                                  if !editing { fans.setMode(.custom(sliderValue)) }
                              })
                    .disabled(fans.helperStatus != .ready || fans.isBusy)
                HStack {
                    Text("\(Int(fan.minRPM)) RPM")
                    Spacer()
                    Text(sliderCaption(fan))
                    Spacer()
                    Text("\(Int(fan.maxRPM)) RPM")
                }
                .font(.system(size: FS.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        if fans.helperStatus != .ready {
            NoticeRow(fans.helperStatus == .outdated
                        ? tr("The fan helper is out of date.", "Helper quạt đã cũ.")
                        : tr("Helper required (asks for your password once).", "Cần cài helper (hỏi mật khẩu 1 lần)."),
                      actionTitle: fans.isBusy ? tr("Installing…", "Đang cài…")
                                               : tr("Install helper", "Cài helper")) { fans.installHelper() }
        }
        if let message = fans.message {
            Text(message).font(.system(size: FS.label)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if fans.helperStatus == .ready || FanHelper.isInstalled {
            Button(tr("Remove helper", "Gỡ helper")) { fans.removeHelper() }
                .buttonStyle(.borderless).font(.system(size: FS.caption)).foregroundStyle(.secondary)
                .disabled(fans.isBusy)
                .help(tr("Returns the fans to System and removes the helper and its sudo rule.",
                         "Trả quạt về Hệ thống rồi gỡ helper và quy tắc sudo của nó."))
        }
    }

    private var modeIndex: Int {
        switch fans.mode {
        case .system: return 0
        case .medium: return 1
        case .high: return 2
        case .custom: return -1
        }
    }

    private var rpmText: String {
        let rpm = fans.fans.map(\.currentRPM).max() ?? 0
        return rpm < 1 ? tr("Off · 0 RPM", "Tắt · 0 RPM") : "\(Int(rpm)) RPM"
    }

    private func currentFraction(_ fan: FanInfo) -> Double {
        if let f = fans.mode.fraction { return f }
        return min(1, max(fan.minRPM, fan.currentRPM) / fan.maxRPM)
    }

    private func sliderCaption(_ fan: FanInfo) -> String {
        let f = dragging ? sliderValue : currentFraction(fan)
        // The fan's real state, so a speed still pinned (or pinned by another tool) never reads Auto.
        let prefix = fans.mode == .system && !fan.isManual && !dragging ? tr("Auto", "Tự động") : tr("Manual", "Đặt tay")
        return "\(prefix) · \(Int(fan.maxRPM * f)) RPM (\(Int(f * 100))%)"
    }

    private var statusText: String {
        guard let t = monitor.thermal.cpuHottest else { return tr("Reading sensors…", "Đang đọc cảm biến…") }
        if fans.thermalLockout { return tr("Hot — slow fan speeds are blocked", "Nóng — chặn các tốc độ quạt thấp") }
        return t < 60 ? tr("Cool", "Mát mẻ") : (t < 80 ? tr("Warm", "Ấm") : tr("Hot", "Nóng"))
    }

    private func format(_ t: Double?) -> String { t.map { String(format: "%.1f°C", $0) } ?? "—" }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        return t < 60 ? .green : (t < 80 ? .orange : .red)
    }
}
