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
        case let .paused(until):
            let time = until.formatted(date: .omitted, time: .shortened)
            return tr("Paused until \(time)", "Tạm dừng tới \(time)")
        }
    }

    /// A few characters for the menu bar: minutes to the next break, or a word for the other states.
    /// Nil while eye breaks are off. Changes at most once a minute while counting down.
    public var menuBarStatus: String? {
        guard showInMenuBar else { return nil }
        switch phase {
        case nil: return nil
        case let .working(remaining): return tr("\(Int((remaining / 60).rounded(.up)))m", "\(Int((remaining / 60).rounded(.up)))p")
        case .headsUp: return tr("Soon", "Sắp nghỉ")
        case .deferred: return tr("Waiting", "Chờ")
        case .onBreak: return tr("Break", "Nghỉ")
        case .paused: return tr("Paused", "Dừng")
        }
    }
}

/// Pause for a while, or resume when paused.
private struct PauseControl: View {
    @ObservedObject var breaks: EyeBreaks

    var body: some View {
        if breaks.isPaused {
            Button(tr("Resume", "Tiếp tục"), action: breaks.resumeFromPause).controlSize(.small)
        } else {
            Menu(tr("Pause", "Tạm dừng")) {
                Button(tr("For 1 hour", "Trong 1 giờ")) { breaks.pause(hours: 1) }
                Button(tr("Until tomorrow", "Tới ngày mai"), action: breaks.pauseUntilTomorrow)
            }
            .controlSize(.small).fixedSize()
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
                    PauseControl(breaks: breaks)
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
                SettingsRow(tr("Pause", "Tạm dừng"),
                            detail: tr("No breaks for an hour or for the rest of today.",
                                       "Không nhắc nghỉ trong một giờ hoặc tới hết hôm nay."), icon: "pause.circle") {
                    PauseControl(breaks: breaks).disabled(!breaks.enabled)
                }
                SettingsRow(tr("Today", "Hôm nay"),
                            detail: tr("Breaks that ran to the end, and breaks skipped or pushed back.",
                                       "Số lần nghỉ trọn vẹn và số lần bỏ qua hoặc lùi lại."), icon: "chart.bar") {
                    SettingsValue(tr("\(breaks.stats.taken) taken · \(breaks.stats.skipped) skipped",
                                     "\(breaks.stats.taken) đã nghỉ · \(breaks.stats.skipped) bỏ qua"))
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
                            detail: tr("Holds the break while an app keeps the display on or a camera or microphone is in use. After 15 minutes of waiting it shows as the small card instead.",
                                       "Tạm hoãn khi có ứng dụng giữ màn hình luôn sáng hoặc camera, micro đang được dùng. Chờ quá 15 phút thì hiện bằng thẻ nhỏ."),
                            icon: "play.rectangle", isOn: $breaks.deferForMedia)
                SettingsRow(tr("Allow skipping", "Cho phép bỏ qua"),
                            detail: tr("Turn off to make every break run to the end. Pressing Esc 3 times still closes a full-screen break.",
                                       "Tắt đi để mỗi lần nghỉ luôn chạy hết giờ. Nhấn Esc 3 lần vẫn đóng được màn che toàn màn hình."),
                            icon: "forward.end", isOn: $breaks.allowSkip)
                SettingsRow(tr("Sound when the break ends", "Âm báo khi hết giờ nghỉ"),
                            detail: tr("So you know without looking back at the screen.",
                                       "Để biết hết giờ mà không cần nhìn lại màn hình."),
                            icon: "speaker.wave.2", isOn: $breaks.chime)
                SettingsRow(tr("Countdown in the menu bar", "Đếm ngược trên thanh menu"),
                            detail: tr("Minutes to the next break next to the OneMac icon.",
                                       "Số phút tới lần nghỉ kế, cạnh biểu tượng OneMac."),
                            icon: "menubar.rectangle", isOn: $breaks.showInMenuBar)
            }
        }
    }

    private static func length(_ seconds: Int) -> String {
        seconds < 60 ? tr("\(seconds) s", "\(seconds) giây") : tr("\(seconds / 60) min", "\(seconds / 60) phút")
    }
}
