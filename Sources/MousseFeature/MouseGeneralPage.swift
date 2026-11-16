import OneMacUI
import SwiftUI

/// Mouse on/off, the permissions it needs and the health of its event tap.
struct MouseGeneralPage: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        SettingsPage(pane: .mouseGeneral) {
            SettingsSection {
                SettingsRow(tr("Enhance the mouse", "Nâng cấp chuột"),
                            detail: tr("Smooth scrolling, button remapping and gestures. Off = the mouse behaves as macOS ships it.",
                                       "Cuộn mượt, gán nút và cử chỉ. Tắt = chuột chạy như mặc định của macOS."),
                            icon: "computermouse", isOn: $store.config.enabled)
            }
            if let issue = store.persistenceIssue { persistenceIssueBanner(issue) }
            // Re-read every 2 s while the page is open: a grant made in System Settings and the tap
            // state show up without anything else having to publish them.
            TimelineView(.periodic(from: .now, by: 2)) { context in
                VStack(alignment: .leading, spacing: Gap.lg) {
                    permissions
                    tapStatus(EventTapEngine.shared.tapStatus(now: context.date))
                }
            }
        }
    }

    private var permissions: some View {
        SettingsSection(tr("Permissions", "Quyền")) {
            SettingsRow(tr("Accessibility", "Trợ năng"),
                        detail: tr("Required to read and reshape mouse events.", "Bắt buộc để đọc và xử lý sự kiện chuột."),
                        icon: "accessibility") {
                SettingsStatus(ok: AccessibilityPermission.isTrusted,
                               text: AccessibilityPermission.isTrusted ? tr("Granted", "Đã cấp") : tr("Missing", "Chưa cấp"),
                               actionTitle: tr("Grant…", "Cấp quyền…")) { AccessibilityPermission.openSettings() }
            }
            // Not required for the mouse tap — shown because a missing grant can look exactly
            // like a dead tap on some macOS releases, and it's the first thing to check then.
            SettingsRow(tr("Input Monitoring", "Giám sát đầu vào"),
                        detail: tr("Optional. Grant it only if scrolling or buttons stay dead with Accessibility on, or for per-device settings.",
                                   "Không bắt buộc. Chỉ cấp nếu cuộn hay nút vẫn không chạy khi đã có Trợ năng, hoặc để cài riêng từng chuột."),
                        icon: "keyboard") {
                SettingsStatus(ok: InputMonitoringPermission.isTrusted,
                               text: InputMonitoringPermission.isTrusted ? tr("Granted", "Đã cấp") : tr("Not granted", "Chưa cấp"),
                               actionTitle: tr("Grant…", "Cấp quyền…")) { InputMonitoringPermission.request() }
            }
        }
    }

    private func tapStatus(_ status: EventTapStatus) -> some View {
        SettingsSection(tr("Event tap", "Bộ bắt sự kiện")) {
            SettingsRow(tr("Status", "Trạng thái"), icon: "waveform.path.ecg") {
                SettingsStatus(ok: status.health == .healthy, text: status.health.label)
            }
            SettingsRow(tr("Recoveries since launch", "Số lần tự khôi phục từ lúc mở"),
                        value: "\(status.recoveryCount)", icon: "arrow.clockwise")
        }
    }

    private func persistenceIssueBanner(_ issue: ConfigPersistenceIssue) -> some View {
        VStack(alignment: .leading, spacing: Gap.sm) {
            NoticeRow(issue.message)
            HStack {
                Button(store.saveIsBlocked ? tr("Overwrite with current settings", "Ghi đè bằng cài đặt hiện tại")
                                           : tr("Retry Save", "Lưu lại")) { store.retrySave() }
                if !store.saveIsBlocked {
                    Button(tr("Dismiss", "Bỏ qua")) { store.dismissPersistenceIssue() }
                }
            }
            .controlSize(.small)
        }
    }
}
