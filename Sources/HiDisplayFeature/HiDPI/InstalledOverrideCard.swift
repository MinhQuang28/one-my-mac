import HiDisplayKit
import OneMacUI
import SwiftUI

/// Undo for the override this app installed for a display.
///
/// Shown only when there is something the app can vouch for: an override file on disk that is
/// byte-for-byte what OneMac wrote, with its predecessor (or the fact that there was none) on
/// record. A file from another tool, or one edited since, is never offered up for removal.
struct InstalledOverrideCard: View {

    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel

    @State private var undo: OverrideUndo?
    @State private var confirming = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Group {
            if undo != nil || message != nil || error != nil {
                card
            }
        }
        .task(id: display.id) {
            message = nil
            error = nil
            refresh()
        }
        .alert(title, isPresented: $confirming) {
            Button(actionTitle, role: .destructive) { perform() }
            Button(tr("Cancel", "Hủy"), role: .cancel) {}
        } message: {
            Text(confirmation)
        }
    }

    private var restoresPrevious: Bool {
        if case .restorePrevious = undo?.kind { return true }
        return false
    }

    private var title: String {
        restoresPrevious
            ? tr("Restore the previous override?", "Khôi phục override trước đó?")
            : tr("Remove this override?", "Gỡ override này?")
    }

    private var actionTitle: String {
        restoresPrevious ? tr("Restore Previous…", "Khôi phục bản trước…") : tr("Remove Override…", "Gỡ override…")
    }

    private var confirmation: String {
        let path = undo.map { "\(AppModel.overrideRoot.path)/\($0.relativePath)" } ?? ""
        let what = restoresPrevious
            ? tr("Puts back the file that was there before OneMac's last install:",
                 "Đưa trở lại tệp có sẵn trước lần cài gần nhất của OneMac:")
            : tr("Deletes the override OneMac added. Nothing was there before it:",
                 "Xóa override OneMac đã thêm. Trước đó không có tệp nào:")
        return what + "\n\n" + path + "\n\n" + tr(
            "Asks for your password once. OneMac then reconnects the display to apply it — the "
            + "screen goes dark for a few seconds.",
            "Hỏi mật khẩu một lần. Sau đó OneMac kết nối lại màn hình để áp dụng — màn hình sẽ tối vài giây.")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let undo {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Installed by OneMac", "Do OneMac cài đặt")).font(.headline)
                        Text(tr("An override from \(Self.dateText(undo.manifest.createdAt)) is installed "
                                    + "for this display.",
                                "Màn hình này đang dùng override cài ngày \(Self.dateText(undo.manifest.createdAt))."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if isWorking { ProgressView().controlSize(.small) }
                    Button(actionTitle) { confirming = true }
                        .disabled(isWorking)
                }
            }
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refresh() {
        undo = model.availableUndo(for: display)
    }

    private func perform() {
        guard let undo, !isWorking else { return }
        isWorking = true
        message = nil
        error = nil
        Task {
            let outcome = await model.performUndo(undo)
            switch outcome {
            case .undone(let restoredPrevious):
                // Same as after an install: reconnect in software when possible, else say how.
                var applied = false
                if model.canReloadOverride(for: display) {
                    applied = await model.reloadOverride(for: display) == nil
                }
                message = (restoredPrevious
                    ? tr("The previous override is back in place.", "Đã đưa override trước đó trở lại.")
                    : tr("The override was removed.", "Đã gỡ override."))
                    + " " + (applied
                        ? tr("The display was reconnected, so it applies now.",
                             "Màn hình đã được kết nối lại nên thay đổi có hiệu lực ngay.")
                        : tr("Reconnect the display, or log out and back in, to apply.",
                             "Cắm lại màn hình, hoặc đăng xuất rồi đăng nhập lại, để áp dụng."))
            case .cancelled:
                message = tr("Cancelled — nothing was changed.", "Đã hủy — chưa thay đổi gì.")
            case .failed(let reason):
                error = reason
            }
            isWorking = false
            refresh()
        }
    }
}
