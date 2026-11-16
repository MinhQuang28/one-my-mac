import HiDisplayKit
import OneMacUI
import SwiftUI

/// The support report, and whether the private-API shims resolved on this macOS.
struct DiagnosticsPage: View {

    @EnvironmentObject private var model: AppModel

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

    /// `reason` comes from HiDisplayKit and is English only.
    private func shimStatus(available: Bool, reason: String?) -> some View {
        SettingsStatus(
            ok: available,
            text: available
                ? tr("Available", "Khả dụng") : (reason ?? tr("Unavailable", "Không khả dụng")))
    }
}
