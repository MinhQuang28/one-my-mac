import OneMacUI
import SwiftUI

/// Charge-limit switch and level chips at the bottom of the battery card.
struct ChargeLimitSection: View {
    @ObservedObject var chargeLimit: ChargeLimit

    var body: some View {
        HStack(spacing: Gap.sm) {
            Image(systemName: "lock.shield")
                .font(.system(size: FS.body))
                .foregroundStyle(chargeLimit.limit == nil ? Color.secondary : Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Limit charge to \(chargeLimit.limit ?? chargeLimit.preferred)%",
                        "Giới hạn sạc ở \(chargeLimit.limit ?? chargeLimit.preferred)%"))
                    .font(.system(size: FS.label, weight: .semibold))
                Text(tr("Less battery wear when plugged in all day",
                        "Cắm sạc liên tục ít chai pin · macOS giữ ngưỡng cả khi ngủ"))
                    .font(.system(size: FS.caption)).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: Gap.xs)
            Toggle("", isOn: Binding(get: { chargeLimit.limit != nil }, set: { chargeLimit.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(chargeLimit.isBusy)
        }
        if chargeLimit.limit != nil {
            HStack(spacing: 6) {
                Text(tr("Limit:", "Mức khóa:")).font(.system(size: FS.caption, weight: .medium)).foregroundStyle(.secondary)
                ForEach(ChargeLimit.levels, id: \.self) { level in
                    let selected = chargeLimit.limit == level
                    Button { chargeLimit.setLimit(level) } label: {
                        Text("\(level)%\(level == 80 ? tr(" (Standard)", " (Chuẩn)") : "")")
                            .font(.system(size: FS.label, weight: selected ? .semibold : .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(selected ? Color.accentColor : Color.tileFill))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(chargeLimit.isBusy)
                }
                Spacer()
            }
        }
        if let message = chargeLimit.message {
            Text(message).font(.system(size: FS.caption)).foregroundStyle(.orange)
        }
    }
}
