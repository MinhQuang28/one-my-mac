import OneMacUI
import SwiftUI

/// Settings page: the switch, the shortcut, what it needs and what it keeps.
public struct ClipboardPage: View {
    @ObservedObject private var history = ClipboardHistory.shared
    @State private var confirmingClear = false
    public init() {}

    public var body: some View {
        SettingsPage(icon: SettingsPane.clipboard.systemImage, tint: SettingsPane.clipboard.tint,
                     title: SettingsPane.clipboard.title, subtitle: SettingsPane.clipboard.subtitle) {
            SettingsSection(footer: tr("Keeps text, links, e-mail addresses, images and copied files. Copies that a password manager marks as private are never recorded. The history stays in files on this Mac that only your account can read.",
                                       "Lưu văn bản, liên kết, địa chỉ email, ảnh và tệp đã sao chép. Nội dung mà trình quản lý mật khẩu đánh dấu riêng tư không bao giờ được ghi lại. Lịch sử nằm trong các tệp trên máy này, chỉ tài khoản của bạn đọc được.")) {
                SettingsRow(tr("Keep a clipboard history", "Lưu lịch sử clipboard"),
                            detail: tr("Remembers the last \(ClipboardStore.limit) things you copied, plus everything you pin.",
                                       "Nhớ \(ClipboardStore.limit) nội dung sao chép gần nhất, cùng mọi mục bạn ghim."),
                            icon: "doc.on.clipboard", isOn: $history.isEnabled)
                SettingsRow(tr("Shortcut", "Phím tắt"),
                            detail: history.shortcutRegistered || !history.isEnabled
                                ? tr("Opens the history over the app you are in. Click the keys, then press the combination you want. ⇧⌘V is Paste and Match Style in some apps.",
                                     "Mở lịch sử ngay trên ứng dụng đang dùng. Bấm vào ô phím rồi nhấn tổ hợp bạn muốn. ⇧⌘V là Dán và khớp kiểu ở một số ứng dụng.")
                                : tr("This shortcut is already taken, by the system or by a window shortcut. Record another.",
                                     "Phím tắt này đã có nơi khác dùng (hệ thống hoặc phím tắt cửa sổ). Hãy ghi tổ hợp khác."),
                            icon: "keyboard") {
                    ClipboardShortcutRecorder()
                }
                // Re-read every 2 s so a grant made in System Settings shows up without a relaunch.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    SettingsRow(tr("Accessibility", "Trợ năng"),
                                detail: tr("Lets the chosen item be pasted straight into the app. Without it, the item is put on the clipboard and you press ⌘V.",
                                           "Cho phép dán thẳng mục đã chọn vào ứng dụng. Nếu không cấp, mục đó được đưa vào clipboard và bạn nhấn ⌘V."),
                                icon: "accessibility") {
                        SettingsStatus(ok: history.canPasteDirectly,
                                       text: history.canPasteDirectly ? tr("Granted", "Đã cấp") : tr("Optional", "Tuỳ chọn"))
                    }
                }
            }
            SettingsSection(tr("History", "Lịch sử")) {
                SettingsRow(tr("Saved items", "Số mục đã lưu"), value: "\(history.itemCount)", icon: "tray.full")
                SettingsRow(tr("Clear history", "Xoá lịch sử"),
                            detail: tr("Pinned items are kept.", "Các mục đã ghim được giữ lại."), icon: "trash") {
                    Button(tr("Clear…", "Xoá…")) { confirmingClear = true }.disabled(history.itemCount == 0)
                }
            }
            SettingsSection(tr("In the history window", "Trong cửa sổ lịch sử")) {
                SettingsRow("↑ ↓", value: tr("Choose an item", "Chọn mục"))
                SettingsRow("↩", value: tr("Paste into the app in front", "Dán vào ứng dụng đang dùng"))
                SettingsRow("⌘↩", value: tr("Copy only", "Chỉ sao chép"))
                SettingsRow("⇥", value: tr("Switch type: all, text, images, files, links, e-mails",
                                           "Đổi loại: tất cả, văn bản, ảnh, tệp, liên kết, email"))
                SettingsRow("⌘K", value: tr("All actions", "Mọi thao tác"))
                SettingsRow("⌘O", value: tr("Open the link, or show the file in Finder", "Mở liên kết hoặc hiện tệp trong Finder"))
                SettingsRow("⌘P", value: tr("Pin or unpin", "Ghim hoặc bỏ ghim"))
                SettingsRow("⌘⌫", value: tr("Delete", "Xoá"))
            }
        }
        .alert(tr("Clear the clipboard history?", "Xoá lịch sử clipboard?"), isPresented: $confirmingClear) {
            Button(tr("Clear", "Xoá"), role: .destructive) { history.clear() }
            Button(tr("Cancel", "Hủy"), role: .cancel) {}
        } message: {
            Text(tr("Everything except pinned items is removed. This cannot be undone.",
                    "Mọi mục trừ mục đã ghim sẽ bị xoá. Không thể hoàn tác."))
        }
    }
}

/// Panel card: the switch, how to open the history, and a link to the page.
public struct ClipboardCard: View {
    @ObservedObject private var history = ClipboardHistory.shared
    public init() {}

    public var body: some View {
        Card {
            CardHeader(icon: "doc.on.clipboard", tint: .orange, title: tr("Clipboard history", "Lịch sử clipboard"),
                       subtitle: history.isEnabled
                           ? tr("\(history.shortcutKeyCaps) opens it · \(history.itemCount) items",
                                "\(history.shortcutKeyCaps) để mở · \(history.itemCount) mục")
                           : tr("Paste anything you copied earlier", "Dán lại những gì đã sao chép trước đó")) {
                CompactToggle(isOn: $history.isEnabled)
            }
            HStack {
                LinkButton(tr("Settings", "Cài đặt")) { Navigator.shared.open(.clipboard) }
                Spacer()
                if history.isEnabled {
                    LinkButton(tr("Open history", "Mở lịch sử"), icon: "list.bullet") { history.showPanel() }
                }
            }
        }
    }
}
