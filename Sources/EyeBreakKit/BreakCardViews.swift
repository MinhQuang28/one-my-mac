import OneMacUI
import SwiftUI

/// The small card at the top centre of the screen: a clock, a countdown, one line of text and a row
/// of buttons. Used for the heads-up before a break and, in the compact style, for the break itself.
private struct BreakCard<Buttons: View>: View {
    let remaining: TimeInterval
    let text: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        let seconds = Int(remaining.rounded(.up))
        VStack(alignment: .leading, spacing: Gap.md) {
            HStack(spacing: Gap.md) {
                CountdownClock(remaining: remaining).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(text).font(.system(size: FS.body)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            HStack(spacing: Gap.sm) { buttons }
        }
        .padding(Gap.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Rad.lg + 4, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: Rad.lg + 4, style: .continuous).stroke(Color.hairline))
        .padding(6)
    }
}

enum BreakCardMetrics {
    static let size = NSSize(width: 440, height: 132)
}

/// Shown shortly before a break: start early or push it back.
struct BreakNoticeView: View {
    @ObservedObject private var breaks = EyeBreaks.shared

    var body: some View {
        var remaining: TimeInterval = 0
        if case let .headsUp(left) = breaks.phase { remaining = left }
        return BreakCard(remaining: remaining,
                         text: tr("Eye break coming up. Wrap up what you're doing.",
                                  "Sắp tới giờ nghỉ mắt. Tạm khép lại việc đang dở nhé.")) {
            CardChip(tr("Start break now", "Nghỉ ngay"), prominent: true, action: breaks.takeBreakNow)
            if breaks.allowSkip {
                ForEach(EyeBreaks.postponeChoices, id: \.self) { minutes in
                    CardChip(tr("+\(minutes) min", "+\(minutes) phút")) { breaks.postpone(minutes: minutes) }
                }
            }
        }
    }
}

/// The break itself in the compact style: the screen stays usable, the card counts the rest down.
struct BreakCompactView: View {
    @ObservedObject private var breaks = EyeBreaks.shared

    var body: some View {
        var remaining: TimeInterval = 0
        if case let .onBreak(left) = breaks.phase { remaining = left }
        let tip = BreakTip.forBreak(breaks.breakCount)
        return BreakCard(remaining: remaining, text: tr("Rest your eyes: \(tip.title.lowercased())", "Nghỉ mắt: \(tip.title.lowercased())")) {
            if breaks.allowSkip {
                CardChip(tr("5 more minutes", "Hoãn 5 phút")) { breaks.postpone(minutes: 5) }
                CardChip(tr("Skip", "Bỏ qua"), action: breaks.skip)
            } else {
                Label(tr("Look away until the clock runs out", "Rời mắt khỏi màn hình tới khi hết giờ"),
                      systemImage: "eye.slash").font(.system(size: FS.body)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CardChip: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: FS.title, weight: .medium))
                .padding(.horizontal, Gap.lg).padding(.vertical, 8)
                .background(Capsule().fill(Color.primary.opacity(prominent ? 0.14 : 0)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.2)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled() // the panel takes key focus on click; no blue ring around the pills
    }
}

/// A small clock face whose hand sweeps like a second hand and reaches twelve when time is up.
private struct CountdownClock: View {
    let remaining: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                // A soft highlight from the top-left, so the face reads as a dome rather than a flat disc.
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.35), .clear], center: .init(x: 0.3, y: 0.22),
                                             startRadius: 0, endRadius: side * 0.6))
                Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: side * 0.03)
                ForEach(0..<12, id: \.self) { hour in
                    Capsule().fill(Color.white.opacity(hour % 3 == 0 ? 0.9 : 0.45))
                        .frame(width: side * 0.045, height: side * (hour % 3 == 0 ? 0.11 : 0.07))
                        .offset(y: -side * 0.33)
                        .rotationEffect(.degrees(Double(hour) * 30))
                }
                Capsule().fill(Color.white)
                    .frame(width: side * 0.07, height: side * 0.3)
                    .offset(y: -side * 0.13)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .rotationEffect(.degrees(-remaining * 6))
                    .animation(.linear(duration: 1), value: remaining)
                Circle().fill(Color.white).frame(width: side * 0.12, height: side * 0.12)
            }
            .frame(width: side, height: side)
        }
    }
}
