import OneMacUI
import SwiftUI

/// What to do with the eyes during a break; a different one each time.
enum BreakTip: CaseIterable {
    case lookFar, blink, shoulders, water

    static func forBreak(_ number: Int) -> BreakTip { allCases[abs(number) % allCases.count] }

    var icon: String {
        switch self {
        case .lookFar: return "binoculars.fill"
        case .blink: return "eye.fill"
        case .shoulders: return "figure.cooldown"
        case .water: return "drop.fill"
        }
    }

    var title: String {
        switch self {
        case .lookFar: return tr("Look into the distance", "Nhìn ra xa")
        case .blink: return tr("Blink slowly", "Chớp mắt thật chậm")
        case .shoulders: return tr("Loosen your shoulders", "Thả lỏng vai gáy")
        case .water: return tr("Have some water", "Uống một ngụm nước")
        }
    }

    var detail: String {
        switch self {
        case .lookFar: return tr("Pick something at least 6 metres away and rest your eyes on it.",
                                 "Chọn một vật cách ít nhất 6 mét và để mắt nghỉ ở đó.")
        case .blink: return tr("Ten slow, full blinks bring moisture back to dry eyes.",
                               "Mười lần chớp chậm, khép kín mắt giúp mắt bớt khô.")
        case .shoulders: return tr("Roll your shoulders back and look away from the screen.",
                                   "Xoay vai ra sau vài vòng và rời mắt khỏi màn hình.")
        case .water: return tr("Take a sip while your eyes rest on something far away.",
                               "Uống một ngụm trong lúc mắt nhìn về phía xa.")
        }
    }
}

/// Full-screen curtain shown on every display during a break.
struct BreakCurtainView: View {
    @ObservedObject private var breaks = EyeBreaks.shared

    private var remaining: TimeInterval {
        if case let .onBreak(remaining) = breaks.phase { return remaining }
        return 0
    }

    var body: some View {
        let tip = BreakTip.forBreak(breaks.breakCount)
        ZStack {
            // 70 % see-through; a darker pool behind the text keeps it readable over bright windows.
            Color.black.opacity(0.3)
            RadialGradient(colors: [Color.black.opacity(0.6), .clear], center: .center, startRadius: 120, endRadius: 520)
            VStack(spacing: 28) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
                    Circle().trim(from: 0, to: min(1, remaining / Double(max(breaks.breakSeconds, 1))))
                        .stroke(Color.teal, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remaining)
                    VStack(spacing: 6) {
                        Image(systemName: tip.icon).font(.system(size: 30, weight: .medium)).foregroundStyle(.teal)
                        Text(clock(remaining)).font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit().contentTransition(.numericText())
                    }
                }
                .frame(width: 170, height: 170)
                VStack(spacing: 8) {
                    Text(tip.title).font(.system(size: 30, weight: .semibold))
                    Text(tip.detail).font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                if breaks.allowSkip {
                    HStack(spacing: Gap.md) {
                        curtainButton(tr("5 more minutes", "Hoãn 5 phút")) { breaks.postpone(minutes: 5) }
                        curtainButton(tr("Skip", "Bỏ qua"), action: breaks.skip)
                    }
                    .padding(.top, 4)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 6)
        }
        .ignoresSafeArea()
    }

    private func curtainButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)"
    }
}
