import OneMacUI
import SwiftUI

/// Window sizes of the small break looks. Larger than what is drawn, to leave room for the shadow
/// and the entrance; the transparent rest lets clicks through.
enum BreakCardMetrics {
    static let island = NSSize(width: 720, height: 84)
    static let corner = NSSize(width: 384, height: 200)
}

/// The dark pill under the menu bar. Drops in from the top with a small bounce.
private struct BreakIsland<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        HStack(spacing: 12) { content }
            .foregroundStyle(.white)
            .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 9)
            .background(Capsule().fill(Color(white: 0.04)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            .fixedSize()
            .scaleEffect(shown ? 1 : 0.5, anchor: .top)
            .offset(y: shown ? 0 : -24)
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6)
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) { shown = true } }
    }
}

/// A small ring with the seconds left inside, then a title over one quiet line.
private struct IslandLead: View {
    let remaining: TimeInterval
    let progress: Double
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            BreakRing(progress: progress, lineWidth: 3, tint: BreakPalette.teal)
            Text(breakClock(remaining)).font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
        }
        .frame(width: 34, height: 34)
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 11.5)).opacity(0.6)
        }
        .lineLimit(1)
        .padding(.trailing, 4)
    }
}

/// Shown shortly before a break: start early or push it back.
struct BreakNoticeView: View {
    @ObservedObject private var breaks = EyeBreaks.shared

    var body: some View {
        var remaining: TimeInterval = 0
        if case let .headsUp(left) = breaks.phase { remaining = left }
        return BreakIsland {
            IslandLead(remaining: remaining, progress: min(1, remaining / EyeBreaks.headsUpSeconds),
                       title: tr("Eye break coming up", "Sắp tới giờ nghỉ mắt"),
                       subtitle: tr("Wrap up what you're doing", "Tạm khép lại việc đang dở"))
            BreakButton(title: tr("Start now", "Nghỉ ngay"), size: 12, action: breaks.takeBreakNow)
            if breaks.allowSkip {
                ForEach(EyeBreaks.postponeChoices, id: \.self) { minutes in
                    BreakButton(title: tr("+\(minutes) min", "+\(minutes) phút"), quiet: true, size: 12) {
                        breaks.postpone(minutes: minutes)
                    }
                }
            }
        }
    }
}

/// The break as an island: the screen stays usable, the pill counts the rest down.
struct BreakIslandView: View {
    @ObservedObject private var breaks = EyeBreaks.shared

    var body: some View {
        BreakIsland {
            IslandLead(remaining: breaks.breakRemaining, progress: breaks.breakProgress,
                       title: tr("Rest your eyes", "Nghỉ mắt"), subtitle: breaks.tip.title)
            if breaks.allowSkip {
                BreakButton(title: tr("+5 min", "+5 phút"), size: 12) { breaks.postpone(minutes: 5) }
                BreakButton(title: tr("Skip", "Bỏ qua"), quiet: true, size: 12, action: breaks.skip)
            }
        }
    }
}

/// The break as a glass card in the bottom-right corner, sliding up like a notification.
struct BreakCornerView: View {
    @ObservedObject private var breaks = EyeBreaks.shared
    @State private var shown = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Rest your eyes a moment", "Nghỉ mắt một chút")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(breakClock(breaks.breakRemaining)).font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.numericText()).foregroundStyle(BreakPalette.teal)
            }
            Text(breaks.tip.detail).font(.system(size: 12.5)).opacity(0.78)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(BreakPalette.teal).frame(width: proxy.size.width * breaks.breakProgress)
                        .animation(.linear(duration: 1), value: breaks.breakProgress)
                }
            }
            .frame(height: 4)
            if breaks.allowSkip {
                HStack(spacing: 6) {
                    BreakButton(title: tr("+5 min", "+5 phút"), size: 12) { breaks.postpone(minutes: 5) }
                    BreakButton(title: tr("Skip", "Bỏ qua"), quiet: true, size: 12, action: breaks.skip)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 340)
        .background(ZStack { BreakBackdrop(material: .hudWindow); Color.black.opacity(0.25) }.clipShape(shape))
        .overlay(shape.strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .offset(y: shown ? 0 : 40)
        .opacity(shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(18)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.15)) { shown = true } }
    }
}
