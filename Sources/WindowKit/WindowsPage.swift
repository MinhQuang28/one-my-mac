import OneMacUI
import SwiftUI

/// Settings page: the shortcut switch, what the feature needs, and the list of actions.
public struct WindowsPage: View {
    @ObservedObject private var snapping = WindowSnapping.shared
    public init() {}

    private static let groups: [(title: () -> String, actions: [WindowAction])] = [
        ({ tr("Halves", "Nửa màn hình") }, [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ({ tr("Corners", "Góc phần tư") }, [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ({ tr("Size", "Kích thước") }, [.maximize, .center, .restore]),
        ({ tr("Displays", "Màn hình") }, [.nextDisplay, .previousDisplay]),
    ]

    public var body: some View {
        SettingsPage(icon: SettingsPane.windows.systemImage, tint: SettingsPane.windows.tint,
                     title: SettingsPane.windows.title, subtitle: SettingsPane.windows.subtitle) {
            SettingsSection(footer: tr("Any of these can also be put on a mouse button in Mouse › Buttons — that works even with the shortcuts off.",
                                       "Mỗi thao tác cũng gán được cho nút chuột trong Chuột › Nút chuột — vẫn chạy khi tắt phím tắt.")) {
                SettingsRow(tr("Keyboard shortcuts", "Phím tắt"),
                            detail: tr("Move and resize the focused window from the keyboard.",
                                       "Di chuyển và đổi cỡ cửa sổ đang dùng bằng bàn phím."),
                            icon: "keyboard", isOn: $snapping.shortcutsEnabled)
                // Re-read every 2 s so a grant made in System Settings shows up without a relaunch.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    SettingsRow(tr("Accessibility", "Trợ năng"),
                                detail: tr("Required to move other apps' windows.", "Bắt buộc để di chuyển cửa sổ của ứng dụng khác."),
                                icon: "accessibility") {
                        SettingsStatus(ok: snapping.isAccessibilityTrusted,
                                       text: snapping.isAccessibilityTrusted ? tr("Granted", "Đã cấp") : tr("Missing", "Chưa cấp"),
                                       actionTitle: tr("Grant…", "Cấp quyền…"), action: Self.openAccessibilitySettings)
                    }
                }
            }
            if !snapping.unavailable.isEmpty {
                NoticeRow(tr("\(snapping.unavailable.count) shortcuts are already used by another app and were skipped.",
                             "\(snapping.unavailable.count) phím tắt đang bị ứng dụng khác dùng nên được bỏ qua."))
            }
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                SettingsSection(group.title()) {
                    ForEach(group.actions, id: \.self, content: actionRow)
                }
            }
        }
    }

    private func actionRow(_ action: WindowAction) -> some View {
        let active = snapping.shortcutsEnabled && !snapping.unavailable.contains(action)
        return SettingsRow(action.title, icon: action.systemImage) {
            HStack(spacing: 3) {
                ForEach(Array(snapping.keyCaps(for: action).enumerated()), id: \.offset) { _, cap in
                    Text(cap).font(.system(size: FS.body, weight: .medium, design: .rounded))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: Rad.sm, style: .continuous).fill(Color.tileFill))
                }
            }
            .opacity(active ? 1 : 0.4)
            .help(snapping.unavailable.contains(action) ? tr("Used by another app", "Ứng dụng khác đang dùng") : "")
        }
    }

    private static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Panel card: the shortcut switch and a link to the full page.
public struct WindowSnapCard: View {
    @ObservedObject private var snapping = WindowSnapping.shared
    public init() {}

    public var body: some View {
        Card {
            CardHeader(icon: "rectangle.split.2x1", tint: .mint, title: tr("Window snapping", "Chia cửa sổ"),
                       subtitle: snapping.shortcutsEnabled
                           ? tr("⌃⌥ + arrows · ⌃⌥⌘ + arrows to change display", "⌃⌥ + mũi tên · ⌃⌥⌘ + mũi tên để đổi màn hình")
                           : tr("Keyboard shortcuts are off", "Phím tắt đang tắt")) {
                CompactToggle(isOn: $snapping.shortcutsEnabled)
            }
            HStack {
                LinkButton(tr("All shortcuts", "Tất cả phím tắt")) { Navigator.shared.open(.windows) }
                Spacer()
            }
        }
    }
}
