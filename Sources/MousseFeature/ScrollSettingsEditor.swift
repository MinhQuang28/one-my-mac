import OneMacUI
import SwiftUI

/// The scroll knobs as one reusable block of sections — the global Scroll page and every per-device
/// profile (Devices page) edit the same `ScrollDeviceSettings`, so they can never drift apart.
struct ScrollSettingsEditor: View {
    @Binding var settings: ScrollDeviceSettings

    var body: some View {
        // Native leaves the OS event alone, so only the reverse toggles apply there.
        let native = settings.scrollMode == .native
        SettingsSection(tr("Scroll feel", "Cảm giác cuộn"),
                        footer: tr("Applies to a physical mouse wheel only — trackpad scrolling is left untouched.",
                                   "Chỉ áp dụng cho bánh xe chuột — cuộn bằng trackpad được giữ nguyên.")) {
            SettingsStack(tr("Scroll style", "Kiểu cuộn"), detail: settings.scrollMode.summary) {
                ChipPicker(ScrollMode.allCases.map { ($0, $0.label) }, selection: $settings.scrollMode)
            }
            if settings.scrollMode == .smooth {
                SettingsStack(tr("Smoothness", "Độ mượt"), detail: settings.scrollSmoothness.summary) {
                    ChipPicker(ScrollSmoothness.allCases.map { ($0, $0.label) }, selection: $settings.scrollSmoothness)
                }
            }
            // Shown in Smooth and Windows alike: it scales high-resolution ("continuous") mice in
            // both, so hiding it in Windows would leave a gain set in Smooth applied with no control.
            if !native {
                // Floor of 0.05 (not 0.2): high-res "continuous" mice natively scroll fast, and
                // their gain is speed/0.5 — a 0.2 floor still meant 40% of native, too fast for
                // slow scrollers. 0.05 → 10% of native. Finer step for control at the low end.
                SettingsSlider(title: tr("Scroll speed", "Tốc độ cuộn"),
                               detail: settings.scrollMode == .smooth
                                   ? tr("Distance per notch; also scales high-resolution mice.",
                                        "Quãng cuộn mỗi nấc; cũng áp dụng cho chuột độ phân giải cao.")
                                   : tr("Scales high-resolution mice only — a notched wheel moves by lines per notch.",
                                        "Chỉ áp dụng cho chuột độ phân giải cao — bánh xe có nấc cuộn theo số dòng."),
                               value: $settings.scrollSpeed, range: 0.05...1.5, step: 0.05,
                               format: { String(format: "%.2f×", $0) },
                               minLabel: tr("Slow", "Chậm"), maxLabel: tr("Fast", "Nhanh"))
            }
            if settings.scrollMode == .smooth {
                SettingsRow(tr("Scroll acceleration", "Tăng tốc khi cuộn nhanh"),
                            detail: tr("Faster flicks travel further.", "Vuốt càng nhanh, cuộn càng xa."),
                            isOn: $settings.scrollAcceleration)
            }
            if settings.scrollMode == .smoothStep {
                SettingsRow(tr("Lines per notch", "Số dòng mỗi nấc")) {
                    Stepper("\(settings.scrollLines)", value: $settings.scrollLines, in: 1...10)
                        .monospacedDigit()
                }
            }
        }
        SettingsSection(tr("Direction", "Chiều cuộn")) {
            SettingsRow(tr("Reverse vertical scroll", "Đảo chiều cuộn dọc"), icon: "arrow.up.arrow.down",
                        isOn: $settings.reverseScroll)
            SettingsRow(tr("Reverse horizontal scroll", "Đảo chiều cuộn ngang"), icon: "arrow.left.arrow.right",
                        isOn: $settings.reverseScrollHorizontal)
        }
        if !native {
            SettingsSection(tr("Zoom and high-resolution mice", "Thu phóng và chuột độ phân giải cao")) {
                SettingsSlider(title: tr("Zoom speed (⌘ + wheel)", "Tốc độ thu phóng (⌘ + bánh xe)"),
                               detail: MagnifySynthesizer.pinchSupported
                                   ? tr("Pinch-zoom per notch. Lower it if Figma or Sketch zoom too far per click.",
                                        "Mức thu phóng mỗi nấc. Giảm xuống nếu Figma hay Sketch phóng quá tay.")
                                   : tr("How readily the wheel sends a ⌘+ / ⌘− zoom step.",
                                        "Mức nhạy khi bánh xe gửi một bước thu phóng ⌘+ / ⌘−."),
                               value: $settings.zoomSpeed, range: 0.2...6.0, step: 0.1,
                               format: { String(format: "%.1f×", $0) },
                               minLabel: tr("Fine", "Mịn"), maxLabel: tr("Coarse", "Thô"))
                SettingsRow(tr("Smooth high-resolution mice", "Làm mượt chuột độ phân giải cao"),
                            detail: tr("For mice that scroll choppily (e.g. Keychron M6). Leave off for free-spin wheels like the MX Master 3.",
                                       "Dành cho chuột cuộn bị giật (vd. Keychron M6). Để tắt với bánh xe quay tự do như MX Master 3."),
                            isOn: $settings.smoothHighRes)
            }
        }
    }
}
