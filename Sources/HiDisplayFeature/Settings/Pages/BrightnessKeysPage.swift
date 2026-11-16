import HiDisplayKit
import OneMacUI
import SwiftUI

/// Brightness-key interception: on/off, which display the keys target, and the permission it needs.
struct BrightnessKeysPage: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPage(
            icon: "sun.max", tint: .orange,
            title: tr("Brightness Keys", "Phím độ sáng"),
            subtitle: tr("Let F1 and F2 change the brightness of external displays.",
                         "Dùng F1 và F2 để chỉnh độ sáng màn hình ngoài.")
        ) {
            SettingsSection(
                footer: tr("macOS sends F1 and F2 to the built-in display only. Presses meant for the "
                            + "built-in display pass through unchanged, so it keeps its native behaviour.",
                           "macOS chỉ gửi F1 và F2 tới màn hình tích hợp. Lần nhấn dành cho màn hình tích "
                            + "hợp được giữ nguyên, nên nó vẫn hoạt động như bình thường.")
            ) {
                SettingsRow(
                    tr("Use F1 and F2 for external displays", "Dùng F1 và F2 cho màn hình ngoài"),
                    isOn: Binding(
                        get: { model.brightnessKeysEnabled },
                        set: { model.setBrightnessKeysEnabled($0) }))

                SettingsRow(tr("Keys adjust", "Phím điều chỉnh")) {
                    Picker("", selection: Binding(
                        get: { model.brightnessKeyTarget },
                        set: { model.setBrightnessKeyTarget($0) })
                    ) {
                        ForEach(BrightnessKeyTarget.allCases) { Text($0.localizedLabel).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!model.brightnessKeysEnabled)
                }
            }

            SettingsSection(tr("Modifiers", "Phím bổ trợ")) {
                SettingsRow("⌥ Option", value: tr("Quarter-size steps", "Bước nhỏ bằng ¼"))
                SettingsRow("⌃ Control", value: tr("Every display at once", "Mọi màn hình cùng lúc"))
            }

            SettingsSection(
                tr("Permission", "Quyền"),
                footer: tr("Needed to read key presses; only the brightness keys are looked at. Without "
                            + "it, the menu-bar sliders still work.",
                           "Cần để đọc phím bấm; chỉ các phím độ sáng được xử lý. Không cấp thì thanh "
                            + "trượt trên thanh menu vẫn hoạt động.")
            ) {
                SettingsRow(tr("Accessibility", "Trợ năng")) {
                    SettingsStatus(
                        ok: model.isAccessibilityTrusted,
                        text: model.isAccessibilityTrusted
                            ? tr("Granted", "Đã cấp") : tr("Needed", "Chưa cấp"),
                        actionTitle: tr("Open Privacy & Security…", "Mở Quyền riêng tư & Bảo mật…"),
                        action: openAccessibilitySettings)
                }
            }
        }
    }

    private func openAccessibilitySettings() {
        BrightnessKeyTap.requestAccessibility()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
