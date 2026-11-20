import OneMacUI
import SwiftUI

/// Global scroll settings, the modifier-key cheat sheet and the per-app lists.
struct MouseScrollPage: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        SettingsPage(pane: .mouseScroll) {
            if !store.config.deviceProfiles.isEmpty {
                NoticeRow(tr("Mice with their own profile (Devices page) ignore these settings.",
                             "Chuột có cấu hình riêng (trang Thiết bị) không dùng các cài đặt này."))
            }
            ScrollSettingsEditor(settings: $store.config.scrollSettings)
            // Native ignores modifiers and per-app rules — only show them when some mouse can use them.
            if store.config.scrollMode != .native || !store.config.deviceProfiles.isEmpty {
                SettingsSection(tr("Hold a key while scrolling", "Giữ phím khi cuộn")) {
                    modifier("⇧ Shift", tr("Scroll horizontally", "Cuộn ngang"))
                    modifier("⌥ Option", tr("Precise — a few pixels per notch", "Chính xác — vài pixel mỗi nấc"))
                    if !store.config.passControlScroll {
                        modifier("⌃ Control", tr("Quick — about half a window per notch", "Nhanh — khoảng nửa cửa sổ mỗi nấc"))
                    }
                    if store.config.zoomWithCommand {
                        modifier("⌘ Command", MagnifySynthesizer.pinchSupported
                            ? tr("Zoom — a real trackpad pinch", "Thu phóng — như chụm ngón trên trackpad")
                            : tr("Zoom — sends ⌘+ / ⌘− to the active app", "Thu phóng — gửi ⌘+ / ⌘− tới ứng dụng đang dùng"))
                    }
                    SettingsRow(tr("Zoom with ⌘ + wheel", "Thu phóng bằng ⌘ + bánh xe"),
                                detail: tr("Off = apps get their own ⌘ + wheel. Excluded apps always do.",
                                           "Tắt = ứng dụng tự xử lý ⌘ + bánh xe. Ứng dụng loại trừ luôn tự xử lý."),
                                isOn: $store.config.zoomWithCommand)
                    SettingsRow(tr("Leave ⌃ + wheel to macOS", "Để ⌃ + bánh xe cho macOS"),
                                detail: tr("Keeps the Accessibility zoom (scroll with a modifier key) working. Turns off quick scroll.",
                                           "Giữ tính năng phóng to của Trợ năng (cuộn kèm phím bổ trợ). Tắt cuộn nhanh."),
                                isOn: $store.config.passControlScroll)
                }
                ExcludedAppsView()
                TransposedAppsView()
            }
        }
    }

    private func modifier(_ key: String, _ effect: String) -> some View {
        HStack {
            Text(key).font(.system(size: FS.body, weight: .medium, design: .rounded))
                .padding(.horizontal, Gap.sm).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Rad.sm, style: .continuous).fill(Color.tileFill))
            Spacer(minLength: Gap.md)
            Text(effect).font(.system(size: FS.body)).foregroundStyle(.secondary)
        }
    }
}
