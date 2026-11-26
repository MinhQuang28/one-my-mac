import HiDisplayKit
import OneMacUI
import SwiftUI

/// The monitor's own volume, contrast and input source, for displays that answer over DDC.
/// Each control appears only if the monitor reported that feature. `DisplayPage` triggers the read:
/// this view is empty until there is something to show, and SwiftUI runs no task for an empty view.
struct DisplayExtrasSection: View {

    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel
    /// The input waiting for the user's confirmation.
    @State private var pendingInput: UInt16?

    private var extras: DisplayExtras? { model.extras[display.id] }

    var body: some View {
        Group {
            if let extras, extras.volume != nil || extras.contrast != nil || extras.inputSource != nil {
                SettingsSection(
                    tr("Monitor", "Màn hình"),
                    footer: tr("Sent to the monitor over DDC; the values live in the monitor itself.",
                               "Gửi tới màn hình qua DDC; giá trị được lưu trong chính màn hình.")
                ) {
                    if let volume = extras.volume {
                        slider(tr("Volume", "Âm lượng"), icon: "speaker.wave.2.fill", value: volume.value) {
                            model.setVolume($0, for: display)
                        }
                    }
                    if let contrast = extras.contrast {
                        slider(tr("Contrast", "Tương phản"), icon: "circle.lefthalf.filled", value: contrast.value) {
                            model.setContrast($0, for: display)
                        }
                    }
                    if let input = extras.inputSource {
                        inputRow(current: input)
                    }
                }
            }
        }
        .alert(
            tr("Switch this monitor to \(DisplayInput.label(for: pendingInput ?? 0))?",
               "Chuyển màn hình này sang \(DisplayInput.label(for: pendingInput ?? 0))?"),
            isPresented: Binding(get: { pendingInput != nil }, set: { if !$0 { pendingInput = nil } })
        ) {
            Button(tr("Switch", "Chuyển")) {
                if let pendingInput { model.setInputSource(pendingInput, for: display) }
                pendingInput = nil
            }
            Button(tr("Cancel", "Hủy"), role: .cancel) { pendingInput = nil }
        } message: {
            Text(tr("The monitor stops showing this Mac. If nothing is connected to that input, use "
                        + "the monitor's own buttons to come back.",
                    "Màn hình sẽ ngừng hiển thị máy Mac này. Nếu cổng đó không cắm gì, hãy dùng nút "
                        + "trên màn hình để quay lại."))
        }
    }

    private func slider(
        _ title: String, icon: String, value: Float, set: @escaping (Float) -> Void
    ) -> some View {
        SettingsStack(title, value: "\(Int((value * 100).rounded()))%") {
            CapsuleSlider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }),
                          icon: icon, label: title)
        }
    }

    private func inputRow(current: UInt16) -> some View {
        // The current input is listed even when it is not a standard value, so the picker is never
        // blank on a monitor that numbers its inputs its own way.
        let options = DisplayInput.standard.contains(current)
            ? DisplayInput.standard : [current] + DisplayInput.standard
        return SettingsRow(
            tr("Input source", "Cổng tín hiệu"),
            detail: tr("Not every monitor has every input listed.",
                       "Không phải màn hình nào cũng có đủ các cổng trong danh sách.")
        ) {
            Picker("", selection: Binding(
                get: { current },
                set: { if $0 != current { pendingInput = $0 } })
            ) {
                ForEach(options, id: \.self) { Text(DisplayInput.label(for: $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }
}
