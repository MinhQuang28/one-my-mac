import OneMacUI
import SwiftUI

/// Keep-awake switch, duration chips and the display option.
public struct KeepAwakeCard: View {
    @ObservedObject private var keepAwake = KeepAwake.shared
    public init() {}

    public var body: some View {
        Card {
            CardHeader(icon: "cup.and.saucer.fill", tint: .brown, title: tr("Keep awake", "Chống sleep"),
                       subtitle: subtitle) {
                CompactToggle(isOn: Binding(get: { keepAwake.isActive }, set: { keepAwake.setActive($0) }))
            }
            ChipPicker(KeepAwake.presets.map { ($0, label($0)) }, selection: Binding(
                get: { keepAwake.selectedMinutes },
                set: { minutes in
                    keepAwake.selectedMinutes = minutes
                    if keepAwake.isActive { keepAwake.activate(minutes: minutes) }
                }))
            ToggleRow(tr("Keep the display on too", "Giữ cả màn hình luôn sáng"), icon: "sun.max", isOn: $keepAwake.keepDisplayOn)
        }
    }

    private var subtitle: String {
        guard keepAwake.isActive else {
            return tr("Mac and display sleep per macOS settings", "Máy và màn hình ngủ theo cài đặt macOS")
        }
        if let end = keepAwake.endsAt {
            let time = end.formatted(date: .omitted, time: .shortened)
            return tr("On until \(time)", "Đang bật tới \(time)")
        }
        return tr("On until turned off", "Đang bật cho tới khi tắt")
    }

    private func label(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "∞"
        case let m where m < 60: return tr("\(m) min", "\(m) phút")
        default: return tr("\(minutes / 60) hr", "\(minutes / 60) giờ")
        }
    }
}
