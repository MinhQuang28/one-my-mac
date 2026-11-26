import AppKit
import OneMacUI
import SwiftUI

/// What to do with the eyes during a break; a different one each time.
enum BreakTip: CaseIterable {
    case lookFar, blink, shoulders, water

    /// Shifts by one every full round, so a tip does not always land on the same break style.
    static func forBreak(_ number: Int) -> BreakTip {
        let count = allCases.count, n = abs(number)
        return allCases[(n + n / count) % count]
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

extension EyeBreaks {
    var breakRemaining: TimeInterval {
        if case let .onBreak(remaining) = phase { return remaining }
        return 0
    }

    /// 1 at the start of the break, 0 when it is over.
    var breakProgress: Double { min(1, max(0, breakRemaining / Double(max(breakSeconds, 1)))) }

    var tip: BreakTip { BreakTip.forBreak(breakCount) }
}

enum BreakPalette {
    static let amber = Color(red: 0.96, green: 0.71, blue: 0.41)
    static let teal = Color(red: 0.37, green: 0.83, blue: 0.77)
}

/// Seconds left, or m:ss from a minute up.
func breakClock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)"
}

/// A thin ring that empties as the time runs out.
struct BreakRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle().trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
    }
}

/// A capsule button on a dark surface. `quiet` drops the fill, for the secondary choice.
struct BreakButton: View {
    let title: String
    var quiet = false
    var size: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: size, weight: .medium)).lineLimit(1)
                .padding(.horizontal, size * 1.2).padding(.vertical, size * 0.55)
                .background(Capsule().fill(Color.white.opacity(quiet ? 0 : 0.16)))
                .opacity(quiet ? 0.7 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled() // the panel takes key focus on click; no blue ring around the pills
    }
}

/// Blurs whatever is behind the window, always in its dark form.
struct BreakBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
