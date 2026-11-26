import OneMacUI
import SwiftUI

/// The full-screen break, shown on every display, in the look this break uses.
struct BreakCurtainView: View {
    let style: BreakStyle

    var body: some View {
        Group {
            if style == .breath { BreakBreathView() } else { BreakDuskView() }
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
    }
}

/// Everything on a curtain arrives late and softly: the window itself fades in first (see
/// `BreakOverlay`), then the content rises into place.
private struct LateArrival: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear { withAnimation(.easeOut(duration: 1.4).delay(1.0)) { shown = true } }
    }
}

/// Postpone and skip, and the way out that always works.
private struct CurtainControls: View {
    @ObservedObject var breaks: EyeBreaks

    var body: some View {
        VStack(spacing: 18) {
            if breaks.allowSkip {
                HStack(spacing: Gap.sm) {
                    BreakButton(title: tr("5 more minutes", "Hoãn 5 phút")) { breaks.postpone(minutes: 5) }
                    BreakButton(title: tr("Skip", "Bỏ qua"), quiet: true, action: breaks.skip)
                }
            }
            Text(tr("Need the screen right now? Press Esc \(EmergencyExit.presses) times.",
                    "Cần dùng máy gấp? Nhấn Esc \(EmergencyExit.presses) lần."))
                .font(.system(size: 12)).opacity(0.45)
        }
    }
}

/// Dusk: a blurred, warm-dark screen, a thin amber ring with the seconds, and one thing to do.
private struct BreakDuskView: View {
    @ObservedObject private var breaks = EyeBreaks.shared

    var body: some View {
        let tip = breaks.tip
        ZStack {
            BreakBackdrop()
            Color(red: 0.11, green: 0.08, blue: 0.13).opacity(0.62)
            // A glow from below the bottom edge, like the last light of the day.
            GeometryReader { proxy in
                RadialGradient(colors: [BreakPalette.amber.opacity(0.3), .clear],
                               center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: proxy.size.height * 0.75)
            }
            VStack(spacing: 26) {
                ZStack {
                    BreakRing(progress: breaks.breakProgress, lineWidth: 5, tint: BreakPalette.amber)
                    Text(breakClock(breaks.breakRemaining))
                        .font(.system(size: 54, weight: .semibold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                }
                .frame(width: 160, height: 160)
                VStack(spacing: 10) {
                    Text(tip.title).font(.system(size: 34, weight: .semibold))
                    Text(tip.detail).font(.system(size: 17)).opacity(0.78)
                        .multilineTextAlignment(.center).frame(maxWidth: 480)
                }
                CurtainControls(breaks: breaks)
            }
            .modifier(LateArrival())
        }
    }
}

/// Breath: an orb that swells for four seconds and shrinks for four, and almost no text.
private struct BreakBreathView: View {
    @ObservedObject private var breaks = EyeBreaks.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let cycle: TimeInterval = 8

    var body: some View {
        ZStack {
            BreakBackdrop()
            Color(red: 0.04, green: 0.12, blue: 0.13).opacity(0.7)
            VStack(spacing: 30) {
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
                    // 0 at the start of the in-breath, 1 at its top, back to 0 at the end of the out-breath.
                    let swell = reduceMotion ? 0.7 : 0.5 - 0.5 * cos(2 * .pi * time / Self.cycle)
                    VStack(spacing: 30) {
                        orb.scaleEffect(0.62 + 0.38 * swell).frame(width: 210, height: 210)
                        Text(reduceMotion ? tr("Breathe slowly", "Thở thật chậm")
                             : time < Self.cycle / 2 ? tr("Breathe in", "Hít vào") : tr("Breathe out", "Thở ra"))
                            .font(.system(size: 28, weight: .medium))
                    }
                }
                Text(tr("\(breakClock(breaks.breakRemaining)) s left · \(breaks.tip.title.lowercased())",
                        "còn \(breakClock(breaks.breakRemaining)) giây · \(breaks.tip.title.lowercased())"))
                    .font(.system(size: 15)).monospacedDigit().opacity(0.6)
                CurtainControls(breaks: breaks)
            }
            .modifier(LateArrival())
        }
    }

    private var orb: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 0.63, green: 0.94, blue: 0.89),
                                          BreakPalette.teal.opacity(0.55), BreakPalette.teal.opacity(0.12)],
                                 center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 120))
            .shadow(color: BreakPalette.teal.opacity(0.45), radius: 50)
    }
}
