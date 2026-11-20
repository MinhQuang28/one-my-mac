import OneMacUI
import SwiftUI

/// Settings page: the switches, what the feature needs, and each action with its shortcut.
public struct WindowsPage: View {
    @ObservedObject private var snapping = WindowSnapping.shared
    public init() {}

    private static let groups: [(title: () -> String, actions: [WindowAction])] = [
        ({ tr("Halves", "Nửa màn hình") }, [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ({ tr("Corners", "Góc phần tư") }, [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ({ tr("Thirds", "Phần ba") }, [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds]),
        ({ tr("Size", "Kích thước") }, [.maximize, .almostMaximize, .center, .restore]),
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
                SettingsRow(tr("Drag to screen edges", "Kéo vào cạnh màn hình"),
                            detail: tr("Drag a window to an edge or a corner to snap it: top maximizes, sides give halves, corners give quarters. Esc cancels. macOS has its own edge tiling (Desktop & Dock › Tile by dragging windows to screen edges) — turn that off so the two don't both act.",
                                       "Kéo cửa sổ vào cạnh hoặc góc để chia: cạnh trên là phóng to, hai bên là nửa, góc là phần tư. Esc để huỷ. macOS cũng có tính năng tương tự (Màn hình nền & Dock › Xếp cửa sổ khi kéo vào cạnh màn hình) — hãy tắt nó để hai bên không cùng tác động."),
                            icon: "rectangle.and.hand.point.up.left", isOn: $snapping.dragSnapEnabled)
                SettingsRow(tr("Repeat to change size", "Nhấn lại để đổi cỡ"),
                            detail: tr("Left Half or Right Half again cycles ½ → ⅔ → ⅓.",
                                       "Nhấn lại Nửa trái hoặc Nửa phải để xoay vòng ½ → ⅔ → ⅓."),
                            icon: "arrow.triangle.2.circlepath", isOn: $snapping.cycleSizes)
                // Re-read every 2 s so a grant made in System Settings shows up without a relaunch.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    SettingsRow(tr("Accessibility", "Trợ năng"),
                                detail: tr("Required to move other apps' windows.", "Bắt buộc để di chuyển cửa sổ của ứng dụng khác."),
                                icon: "accessibility") {
                        SettingsStatus(ok: snapping.isAccessibilityTrusted,
                                       text: snapping.isAccessibilityTrusted ? tr("Granted", "Đã cấp") : tr("Missing", "Chưa cấp"),
                                       actionTitle: tr("Grant…", "Cấp quyền…"), action: WindowSnapping.openAccessibilitySettings)
                    }
                }
            }
            WindowAccessibilityNotice()
            if !snapping.unavailable.isEmpty {
                NoticeRow(tr("\(snapping.unavailable.count) shortcuts could not be registered (the system or another app holds them) and were skipped.",
                             "\(snapping.unavailable.count) phím tắt không đăng ký được (hệ thống hoặc ứng dụng khác đang giữ) nên được bỏ qua."))
            }
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                SettingsSection(group.title()) {
                    ForEach(group.actions, id: \.self) { action in
                        SettingsRow(action.title, icon: action.systemImage) { WindowShortcutRecorder(action: action) }
                    }
                }
            }
            SettingsSection(footer: tr("Click a shortcut to record a new one. Two actions cannot share the same keys.",
                                       "Bấm vào phím tắt để ghi phím mới. Hai thao tác không thể dùng chung một tổ hợp phím.")) {
                SettingsRow(tr("Default shortcuts", "Phím tắt mặc định"), icon: "arrow.counterclockwise") {
                    Button(tr("Reset All", "Đặt lại tất cả")) { snapping.resetAllShortcuts() }
                        .disabled(!snapping.shortcutsAreCustomized)
                }
            }
        }
    }
}

/// Shown while something that is switched on cannot work without the Accessibility permission.
struct WindowAccessibilityNotice: View {
    @ObservedObject private var snapping = WindowSnapping.shared

    var body: some View {
        // Only while it shows: re-read every 2 s so it goes away once the permission is granted.
        if snapping.needsAccessibility {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                if snapping.needsAccessibility {
                    NoticeRow(tr("Window snapping can't move windows until OneMac is allowed under Accessibility.",
                             "Chia cửa sổ chưa di chuyển được cửa sổ cho tới khi OneMac được cấp quyền Trợ năng."),
                              actionTitle: tr("Grant…", "Cấp quyền…"), action: WindowSnapping.openAccessibilitySettings)
                }
            }
        }
    }
}

/// Panel card: the shortcut switch and a link to the full page.
public struct WindowSnapCard: View {
    @ObservedObject private var snapping = WindowSnapping.shared
    public init() {}

    public var body: some View {
        Card {
            CardHeader(icon: "rectangle.split.2x1", tint: .mint, title: tr("Window snapping", "Chia cửa sổ"),
                       subtitle: subtitle) {
                CompactToggle(isOn: $snapping.shortcutsEnabled)
            }
            WindowAccessibilityNotice()
            HStack {
                LinkButton(tr("All shortcuts", "Tất cả phím tắt")) { Navigator.shared.open(.windows) }
                Spacer()
            }
        }
    }

    private var subtitle: String {
        guard snapping.shortcutsEnabled else {
            return snapping.dragSnapEnabled ? tr("Drag to screen edges is on", "Đang bật kéo vào cạnh màn hình")
                                            : tr("Keyboard shortcuts are off", "Phím tắt đang tắt")
        }
        let count = snapping.activeShortcutCount
        return tr("\(count) keyboard shortcuts active", "\(count) phím tắt đang bật")
    }
}
