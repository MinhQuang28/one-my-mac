import OneMacUI
import SwiftUI

/// Live CPU / RAM / GPU load plus the switches that put those numbers next to the menu-bar icon.
public struct MenuBarStatsCard: View {
    @ObservedObject private var usage = SystemUsageMonitor.shared
    @ObservedObject private var monitor = HardwareMonitor.shared
    public init() {}

    public var body: some View {
        Card {
            CardHeader(icon: "menubar.rectangle", tint: .blue, title: tr("Menu bar", "Thanh menu"),
                       subtitle: tr("Choose the stats shown next to the OneMac icon",
                                    "Chọn số liệu hiện cạnh biểu tượng OneMac"))
            row(icon: "thermometer.medium", title: tr("Show CPU temperature", "Hiện nhiệt độ CPU"),
                preview: monitor.thermal.cpuAverage.map { String(format: "%.0f°C", $0) } ?? "—",
                isOn: $usage.showTemperature)
            Divider().opacity(0.45)
            row(icon: "cpu", title: tr("Show CPU & RAM %", "Hiện % CPU & RAM"),
                preview: "CPU \(SystemUsageMonitor.percent(usage.usage.cpu)) · RAM \(SystemUsageMonitor.percent(usage.usage.ram))",
                isOn: $usage.showCPURAM)
            Divider().opacity(0.45)
            row(icon: "square.3.layers.3d", title: tr("Show GPU %", "Hiện % GPU"),
                preview: usage.hasGPU ? "GPU \(SystemUsageMonitor.percent(usage.usage.gpu))"
                                      : tr("Not supported", "Không hỗ trợ"),
                isOn: Binding(get: { usage.showGPU && usage.hasGPU }, set: { usage.showGPU = $0 }),
                disabled: !usage.hasGPU)
        }
    }

    /// Icon, label, live value (accent while it is on the menu bar) and a mini switch.
    private func row(icon: String, title: String, preview: String, isOn: Binding<Bool>,
                     disabled: Bool = false) -> some View {
        HStack(spacing: Gap.sm) {
            Image(systemName: icon).font(.system(size: FS.label))
                .foregroundStyle(disabled ? Color.secondary : Color.accentColor).frame(width: 16)
            Text(title).font(.system(size: FS.label)).foregroundStyle(disabled ? .tertiary : .primary).lineLimit(1)
            Spacer(minLength: Gap.xs)
            Text(preview)
                .font(.system(size: FS.caption, weight: isOn.wrappedValue ? .semibold : .regular, design: .rounded))
                .monospacedDigit().lineLimit(1)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(disabled)
        }
    }
}
