import OneMacUI
import SwiftUI

extension EyeBreaks {
    /// One line saying where the schedule stands, for the card and the settings page.
    var statusText: String {
        switch phase {
        case nil:
            return tr("Reminds you to rest your eyes every \(intervalMinutes) minutes",
                      "Nhắc nghỉ mắt sau mỗi \(intervalMinutes) phút dùng máy")
        case let .working(remaining):
            let minutes = Int((remaining / 60).rounded(.up))
            return minutes <= 1 ? tr("Next break in under a minute", "Lần nghỉ kế trong chưa đầy 1 phút")
                                : tr("Next break in \(minutes) min", "Lần nghỉ kế sau \(minutes) phút")
        case .headsUp: return tr("Break starting…", "Sắp tới giờ nghỉ…")
        case .deferred: return tr("Waiting — a video or call is on screen", "Đang chờ — có video hoặc cuộc gọi")
        case .onBreak: return tr("On a break", "Đang nghỉ mắt")
        }
    }
}

/// Panel card: the switch, the countdown and a shortcut to a break right now.
public struct EyeBreakCard: View {
    @ObservedObject private var breaks = EyeBreaks.shared
    public init() {}

    public var body: some View {
        Card {
            CardHeader(icon: "eye.fill", tint: .teal, title: tr("Eye breaks", "Nghỉ mắt"), subtitle: breaks.statusText) {
                CompactToggle(isOn: $breaks.enabled)
            }
            HStack {
                LinkButton(tr("Options", "Tuỳ chỉnh")) { Navigator.shared.open(.eyeBreaks) }
                Spacer()
                if breaks.enabled {
                    Button(tr("Break now", "Nghỉ ngay"), action: breaks.takeBreakNow).controlSize(.small)
                }
            }
        }
    }
}

/// Settings page: the rhythm of the breaks and how they announce themselves.
public struct EyeBreakPage: View {
    @ObservedObject private var breaks = EyeBreaks.shared
    public init() {}

    public var body: some View {
        SettingsPage(icon: SettingsPane.eyeBreaks.systemImage, tint: SettingsPane.eyeBreaks.tint,
                     title: SettingsPane.eyeBreaks.title, subtitle: SettingsPane.eyeBreaks.subtitle) {
            SettingsSection {
                SettingsRow(tr("Eye breaks", "Nghỉ mắt"), detail: breaks.statusText, icon: "eye", isOn: $breaks.enabled)
                SettingsRow(tr("Try it", "Xem thử"),
                            detail: tr("Starts a break right away.", "Bắt đầu một lần nghỉ ngay bây giờ."), icon: "play.circle") {
                    Button(tr("Break now", "Nghỉ ngay"), action: breaks.takeBreakNow)
                        .controlSize(.small).disabled(!breaks.enabled)
                }
            }
            SettingsSection(tr("Rhythm", "Nhịp nghỉ"),
                            footer: tr("Time away from the keyboard and mouse for 3 minutes or more counts as a break, and the countdown starts over.",
                                       "Rời bàn phím và chuột từ 3 phút trở lên được tính là đã nghỉ, và bộ đếm bắt đầu lại.")) {
                SettingsStack(tr("Screen time between breaks", "Thời gian dùng máy giữa hai lần nghỉ")) {
                    ChipPicker(EyeBreaks.intervalChoices.map { ($0, tr("\($0) min", "\($0) phút")) },
                               selection: $breaks.intervalMinutes)
                }
                SettingsStack(tr("Break length", "Độ dài mỗi lần nghỉ")) {
                    ChipPicker(EyeBreaks.breakChoices.map { ($0, Self.length($0)) }, selection: $breaks.breakSeconds)
                }
            }
            SettingsSection(tr("Behaviour", "Cách nhắc")) {
                SettingsStack(tr("Break style", "Kiểu nghỉ"),
                              detail: tr("Full screen covers every display. Small card sits at the top centre and leaves the screen usable.",
                                         "Toàn màn hình che mọi màn hình. Thẻ nhỏ nằm giữa phía trên và vẫn để bạn dùng máy.")) {
                    ChipPicker([(false, tr("Full screen", "Toàn màn hình")), (true, tr("Small card", "Thẻ nhỏ"))],
                               selection: $breaks.compact)
                }
                SettingsRow(tr("Heads-up before a break", "Báo trước khi nghỉ"),
                            detail: tr("A small card with a countdown 30 seconds ahead; start early or push the break back from it.",
                                       "Một thẻ nhỏ đếm ngược trước 30 giây; có thể nghỉ luôn hoặc lùi giờ nghỉ ngay trên thẻ."),
                            icon: "bell", isOn: $breaks.headsUp)
                SettingsRow(tr("Wait for videos and calls", "Chờ khi đang xem video hoặc họp"),
                            detail: tr("Holds the break while an app keeps the display on, then starts it when that ends.",
                                       "Tạm hoãn khi có ứng dụng đang giữ màn hình luôn sáng, xong thì mới nghỉ."),
                            icon: "play.rectangle", isOn: $breaks.deferForMedia)
                SettingsRow(tr("Allow skipping", "Cho phép bỏ qua"),
                            detail: tr("Turn off to make every break run to the end.",
                                       "Tắt đi để mỗi lần nghỉ luôn chạy hết giờ."),
                            icon: "forward.end", isOn: $breaks.allowSkip)
                SettingsRow(tr("Sound when the break ends", "Âm báo khi hết giờ nghỉ"),
                            detail: tr("So you know without looking back at the screen.",
                                       "Để biết hết giờ mà không cần nhìn lại màn hình."),
                            icon: "speaker.wave.2", isOn: $breaks.chime)
            }
        }
    }

    private static func length(_ seconds: Int) -> String {
        seconds < 60 ? tr("\(seconds) s", "\(seconds) giây") : tr("\(seconds / 60) min", "\(seconds / 60) phút")
    }
}
