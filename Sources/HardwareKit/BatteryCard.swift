import OneMacUI
import SwiftUI

/// Battery level, power flow, health, cycles, temperature and adapter.
public struct BatteryCard: View {
    @ObservedObject private var monitor = HardwareMonitor.shared
    @ObservedObject private var chargeLimit = ChargeLimit.shared
    public init() {}

    public var body: some View {
        Card {
            if let b = monitor.battery {
                header(b)
                levelBar(b)
                HStack(spacing: Gap.sm - 2) {
                    StatTile(tr("Battery health", "Độ khoẻ pin"),
                             value: b.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                             note: capacityNote(b), valueColor: healthColor(b.healthPercent))
                    StatTile(tr("Charge cycles", "Chu kỳ sạc"), value: "\(b.cycleCount)", note: tr("cycles", "lần"))
                    StatTile(tr("Battery temperature", "Nhiệt độ pin"),
                             value: b.temperature.map { String(format: "%.1f°C", $0) } ?? "—",
                             note: tempNote(b.temperature), valueColor: tempColor(b.temperature))
                }
                if chargeLimit.isSupported {
                    Divider().padding(.vertical, 2)
                    ChargeLimitSection(chargeLimit: chargeLimit)
                }
            } else {
                CardHeader(icon: "battery.0", tint: .secondary, title: tr("Battery", "Pin"),
                           subtitle: tr("This Mac has no battery (desktop Mac).",
                                        "Máy này không có pin (Mac để bàn)."))
            }
        }
        .onAppear { chargeLimit.refresh() }
    }

    private func header(_ b: BatterySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(b.percent)").font(.system(size: FS.display, weight: .bold)).monospacedDigit()
            + Text(" %").font(.system(size: FS.subhead, weight: .semibold)).foregroundColor(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(stateText(b)).font(.system(size: FS.body, weight: .semibold))
                Text(detailText(b)).font(.system(size: FS.label)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func levelBar(_ b: BatterySnapshot) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tileFill).frame(height: 8)
                    // Red → green over the whole track, revealed up to the level, so the colour at
                    // the tip says how full the battery is.
                    Capsule().fill(LinearGradient(colors: [.red, .orange, .yellow, .green],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                        .mask(alignment: .leading) {
                            Capsule().frame(width: geo.size.width * CGFloat(min(max(b.percent, 0), 100)) / 100,
                                            height: 8)
                        }
                    if let limit = chargeLimit.limit {
                        // Notch marking where charging stops.
                        Rectangle().fill(Color.orange).frame(width: 2.5, height: 12)
                            .offset(x: max(0, geo.size.width * CGFloat(limit) / 100 - 1.25))
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            if let limit = chargeLimit.limit {
                Text(tr("Charge limit: \(limit)%", "Ngưỡng khóa: \(limit)%")).font(.system(size: FS.caption, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func stateText(_ b: BatterySnapshot) -> String {
        if b.isFullyCharged { return tr("Fully charged", "Đã sạc đầy") }
        if b.isCharging { return tr("Charging", "Đang sạc") }
        if b.isPluggedIn, let limit = chargeLimit.limit, b.percent >= limit {
            return tr("Holding at \(limit)%", "Giữ ở ngưỡng \(limit)%")
        }
        if b.isPluggedIn { return tr("Plugged in · not charging", "Đã cắm sạc · không sạc") }
        return tr("On battery", "Đang dùng pin")
    }

    private func detailText(_ b: BatterySnapshot) -> String {
        var parts: [String] = []
        if let w = b.watts { parts.append(w == 0 ? "0 W" : String(format: "%+.1f W", w)) }
        if let m = b.minutesRemaining {
            let h = m / 60, mm = String(format: "%02d", m % 60)
            parts.append(b.isCharging ? tr("full in \(h)h\(mm)m", "đầy sau \(h)g\(mm)p")
                                      : tr("\(h)h\(mm)m left", "còn \(h)g\(mm)p"))
        }
        if b.isPluggedIn, let a = b.adapterWatts, a > 0 { parts.append(tr("\(a)W adapter", "sạc \(a)W")) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func capacityNote(_ b: BatterySnapshot) -> String? {
        guard let max = b.maxCapacity, let design = b.designCapacity else { return nil }
        return "\(max)/\(design) mAh"
    }

    private func healthColor(_ h: Double?) -> Color {
        guard let h else { return .primary }
        return h >= 80 ? .green : (h >= 70 ? .orange : .red)
    }

    private func tempNote(_ t: Double?) -> String? {
        guard let t else { return tr("unavailable", "không đọc được") }
        return t < 35 ? tr("cool", "mát") : (t < 40 ? tr("warm", "ấm") : tr("hot", "nóng"))
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return .secondary }
        return t < 35 ? .green : (t < 40 ? .orange : .red)
    }
}
