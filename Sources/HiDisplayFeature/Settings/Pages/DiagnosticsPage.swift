import HiDisplayKit
import OneMacUI
import SwiftUI

/// The support report, and whether the private-API shims resolved on this macOS.
struct DiagnosticsPage: View {

    @EnvironmentObject private var model: AppModel
    @State private var confirmingReset = false

    var body: some View {
        SettingsPage(
            icon: "stethoscope", tint: .teal,
            title: tr("Display Diagnostics", "Chẩn đoán màn hình"),
            subtitle: tr("Export a support report and check what this macOS allows.",
                         "Xuất báo cáo hỗ trợ và kiểm tra những gì macOS này cho phép.")
        ) {
            SettingsSection(
                tr("Diagnostics", "Chẩn đoán"),
                footer: tr("No username, home-folder paths, serial numbers or raw EDID are included — "
                            + "serials appear only as a truncated hash.",
                           "Không chứa tên người dùng, đường dẫn thư mục cá nhân, số sê-ri hay EDID thô — "
                            + "số sê-ri chỉ xuất hiện dưới dạng mã băm rút gọn.")
            ) {
                SettingsRow(
                    tr("Support report", "Báo cáo hỗ trợ"),
                    detail: tr("A JSON file describing your displays and why each brightness probe "
                                + "succeeded or failed.",
                               "Tệp JSON mô tả các màn hình và lý do mỗi lần dò độ sáng thành công hay "
                                + "thất bại.")
                ) {
                    HStack {
                        if let path = model.lastExportPath {
                            Button(tr("Show in Finder", "Hiện trong Finder")) {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                        }
                        Button(tr("Export Diagnostics…", "Xuất chẩn đoán…")) { model.exportDiagnostics() }
                    }
                }
                if let path = model.lastExportPath {
                    SettingsRow(tr("Last export", "Lần xuất gần nhất"),
                                value: URL(fileURLWithPath: path).lastPathComponent)
                }
                if let error = model.diagnosticsError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: FS.body))
                }
            }

            savedSettingsSection

            SettingsSection(
                tr("Private API status", "Trạng thái API riêng"),
                footer: tr("Not part of the public macOS SDK, so they are looked up at runtime. If a "
                            + "future macOS removes them, the app falls back to software dimming.",
                           "Không thuộc SDK công khai của macOS nên được tra lúc chạy. Nếu macOS sau này "
                            + "gỡ bỏ, ứng dụng chuyển sang làm tối bằng phần mềm.")
            ) {
                SettingsRow("IOAVService", detail: tr("DDC on Apple Silicon", "DDC trên Apple Silicon")) {
                    shimStatus(
                        available: IOAVServiceShim.shared.isAvailable,
                        reason: IOAVServiceShim.shared.unavailableReason)
                }
                SettingsRow("DisplayServices",
                            detail: tr("Built-in brightness", "Độ sáng màn hình tích hợp")) {
                    shimStatus(
                        available: DisplayServicesShim.shared.isAvailable,
                        reason: DisplayServicesShim.shared.unavailableReason)
                }
            }
        }
    }

    /// What the app remembers per display, and the ways to move or clear it.
    private var savedSettingsSection: some View {
        SettingsSection(
            tr("Saved display settings", "Thiết lập màn hình đã lưu"),
            footer: tr("Brightness, controller choice and identity confirmations, per display. A "
                        + "display identified by its port gets a new entry when it changes port; the "
                        + "old ones collect here until forgotten.",
                       "Độ sáng, lựa chọn bộ điều khiển và xác nhận danh tính của từng màn hình. Màn "
                        + "hình nhận diện theo cổng sẽ có mục mới khi đổi cổng; các mục cũ nằm lại ở "
                        + "đây cho tới khi được quên.")
        ) {
            SettingsRow(
                tr("Backup", "Sao lưu"),
                detail: tr("Importing replaces everything currently saved.",
                           "Nhập sẽ thay thế toàn bộ thiết lập đang lưu.")
            ) {
                HStack {
                    Button(tr("Export…", "Xuất…")) { model.exportProfiles() }
                    Button(tr("Import…", "Nhập…")) { model.importProfiles() }
                }
            }
            ForEach(model.disconnectedProfiles) { profile in
                SettingsRow(
                    profile.displayName.isEmpty ? profile.displayKey : profile.displayName,
                    detail: tr("Not connected · \(profile.displayKey)",
                               "Chưa kết nối · \(profile.displayKey)")
                ) {
                    Button(tr("Forget", "Quên")) { model.forgetProfile(key: profile.displayKey) }
                }
            }
            SettingsRow(
                tr("Reset all", "Đặt lại tất cả"),
                detail: tr("Forgets every display, connected or not.",
                           "Quên mọi màn hình, dù đang kết nối hay không.")
            ) {
                Button(tr("Reset…", "Đặt lại…"), role: .destructive) { confirmingReset = true }
            }
            if let message = model.profileMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: FS.body))
            }
            if let error = model.profileError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: FS.body))
            }
        }
        .alert(tr("Reset all saved display settings?", "Đặt lại mọi thiết lập màn hình đã lưu?"),
               isPresented: $confirmingReset) {
            Button(tr("Reset", "Đặt lại"), role: .destructive) { model.resetAllProfiles() }
            Button(tr("Cancel", "Hủy"), role: .cancel) {}
        } message: {
            Text(tr("Every display goes back to default brightness and automatic controller, and "
                        + "identity confirmations are cleared. HiDPI overrides in /Library/Displays "
                        + "are not touched.",
                    "Mọi màn hình trở về độ sáng mặc định và bộ điều khiển tự động, các xác nhận danh "
                        + "tính bị xóa. Override HiDPI trong /Library/Displays không bị đụng tới."))
        }
    }

    /// `reason` comes from HiDisplayKit and is English only.
    private func shimStatus(available: Bool, reason: String?) -> some View {
        SettingsStatus(
            ok: available,
            text: available
                ? tr("Available", "Khả dụng") : (reason ?? tr("Unavailable", "Không khả dụng")))
    }
}
