import HiDisplayKit
import OneMacUI
import SwiftUI

/// Everything about one monitor: what it is, its resolution, how its brightness is driven, and the
/// identity its settings are saved under.
///
/// One page per display rather than a list-and-detail split inside the page, because the sidebar
/// *is* the list now. The built-in panel gets the same header and then a note, since macOS owns both
/// its resolution and its brightness — see `BrightnessCoordinator.builtInExplanation`.
struct DisplayPage: View {

    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel
    @State private var showAllResolutions = false
    @State private var confirmingForget = false

    var body: some View {
        SettingsPage(
            icon: display.isBuiltIn ? "laptopcomputer" : "display", tint: .blue,
            title: display.name,
            subtitle: display.isBuiltIn
                ? tr("What macOS reports about the built-in display.",
                     "Thông tin macOS báo về màn hình tích hợp.")
                : tr("Resolution, brightness and identity of this display.",
                     "Độ phân giải, độ sáng và danh tính của màn hình này.")
        ) {
            overviewSection
            if display.isBuiltIn {
                builtInSection
            } else {
                resolutionSection
                DisplayBrightnessSection(display: display)
                DisplayExtrasSection(display: display)
            }
            identitySection
        }
        // Forced: the monitor's own buttons may have changed volume, contrast or input since the
        // last read. Keyed on DDC so it runs once the probe has found it.
        .task(id: model.brightness.hasDDC(display.id)) { await model.loadExtras(for: display, force: true) }
    }

    // MARK: Overview

    private var overviewSection: some View {
        SettingsSection(tr("Overview", "Tổng quan")) {
            SettingsRow(tr("Type", "Loại"), value: display.isBuiltIn
                ? tr("Built-in display", "Màn hình tích hợp") : tr("External display", "Màn hình ngoài"))
            if display.isMain {
                SettingsRow(tr("Role", "Vai trò"), value: tr("Main display", "Màn hình chính"),
                            detail: tr("Holds the menu bar", "Chứa thanh menu"))
            }
            if let native = display.nativePixelSize {
                // A plain `String`, not a `LocalizedStringKey`: an Int interpolated into the latter is
                // number-formatted, which turns 5088 into "5.088" wherever the locale groups
                // thousands with a period.
                SettingsRow(tr("Native resolution", "Độ phân giải gốc"),
                            value: "\(native.width) × \(native.height)")
            }
            if let mode = display.currentMode {
                SettingsRow(tr("Current mode", "Chế độ hiện tại"),
                            value: "\(mode.displayLabel) @ \(Int(mode.refreshRate.rounded())) Hz")
            }
            SettingsRow(tr("Modes", "Chế độ"), value: tr(
                "\(display.availableModes.count) total, \(display.hiDPIModeCount) HiDPI",
                "\(display.availableModes.count) chế độ, \(display.hiDPIModeCount) HiDPI"))
        }
    }

    /// Phrased as a boundary rather than a limitation, because it is one: macOS already owns the
    /// built-in panel's brightness through the keys, Control Center and ambient-light adaptation,
    /// and a second owner could only fight them — on the one screen the user cannot unplug.
    private var builtInSection: some View {
        SettingsSection(tr("Managed by macOS", "Do macOS quản lý")) {
            SettingsRow(
                tr("Resolution and brightness", "Độ phân giải và độ sáng"),
                detail: tr("Use System Settings → Displays, Control Center or the brightness keys. "
                            + "OneMac only adjusts external monitors.",
                           "Dùng Cài đặt hệ thống → Màn hình, Trung tâm điều khiển hoặc phím độ sáng. "
                            + "OneMac chỉ điều chỉnh màn hình ngoài."))
        }
    }

    // MARK: Resolution

    /// Resolution and refresh rate as two independent choices.
    ///
    /// Kept separate on purpose: picking a different resolution should not silently drop a 120 Hz
    /// panel to 60 Hz, which is what a single combined list would do whenever the highest rate is not
    /// available at the newly chosen size.
    @ViewBuilder
    private var resolutionSection: some View {
        let curated = display.curatedModes
        let rates = display.currentMode.map {
            DisplayModeSwitcher.refreshRates(
                forWidth: $0.width, height: $0.height, hiDPI: $0.isHiDPI, in: display.availableModes)
        } ?? []

        SettingsSection(
            tr("Resolution", "Độ phân giải"),
            footer: tr("A change asks you to confirm and reverts by itself after "
                        + "\(ModeChangeCoordinator.revertAfter) seconds if the display cannot show it.",
                       "Mỗi lần đổi sẽ hỏi xác nhận và tự hoàn tác sau "
                        + "\(ModeChangeCoordinator.revertAfter) giây nếu màn hình không hiển thị được.")
        ) {
            if showAllResolutions {
                // The unfiltered list, for the case where the curated one hides a mode someone needs.
                SettingsRow(tr("Resolution", "Độ phân giải")) {
                    Picker("", selection: modeBinding) {
                        ForEach(display.availableModes.filter(\.isUsableForDesktop)) { mode in
                            Text(verbatim: "\(mode.displayLabel) @ \(Int(mode.refreshRate.rounded())) Hz")
                                .tag(mode.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            } else {
                SettingsRow(tr("Resolution", "Độ phân giải")) {
                    Picker("", selection: sizeBinding) {
                        ForEach(curated) { mode in Text(mode.displayLabel).tag(mode.sizeKey) }
                    }
                    .labelsHidden().fixedSize()
                }
                if rates.count > 1 {
                    SettingsRow(tr("Refresh rate", "Tần số quét")) {
                        Picker("", selection: modeBinding) {
                            ForEach(rates) { mode in
                                Text(verbatim: "\(Int(mode.refreshRate.rounded())) Hz").tag(mode.id)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            SettingsRow(
                tr("Show all resolutions", "Hiện mọi độ phân giải"),
                detail: tr("Every mode the display offers, at every refresh rate.",
                           "Mọi chế độ màn hình hỗ trợ, ở mọi tần số quét."),
                isOn: $showAllResolutions)

            if let error = model.modeChangeError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: FS.body))
            }
        }
    }

    /// Selection is by `DisplayMode.id`, which encodes geometry and refresh rate — the runtime
    /// `ioDisplayModeID` is not stable across reconnects and cannot be used as a tag.
    ///
    /// Correct for the refresh-rate picker, whose rows are all one size and differ only in rate. The
    /// resolution picker must use `sizeBinding` instead.
    private var modeBinding: Binding<String> {
        Binding(
            get: { display.currentMode?.id ?? "" },
            set: { id in
                guard let mode = display.availableModes.first(where: { $0.id == id }) else { return }
                model.setMode(mode, for: display)
            })
    }

    /// Resolution selection, by size only.
    ///
    /// Both halves matter. The getter tags by size so a 120 Hz current mode still matches the curated
    /// 170 Hz row instead of leaving the picker blank; the setter re-resolves the rate so switching
    /// size keeps 120 Hz whenever the new size offers it.
    private var sizeBinding: Binding<String> {
        Binding(
            get: { display.currentMode?.sizeKey ?? "" },
            set: { key in
                guard let target = display.curatedModes.first(where: { $0.sizeKey == key }) else { return }
                let mode = DisplayModeSwitcher.mode(
                    matchingSizeOf: target,
                    preservingRate: display.currentMode?.refreshRate ?? 0,
                    in: display.availableModes)
                model.setMode(mode, for: display)
            })
    }

    // MARK: Identity

    /// The tier explanation is shown, not hidden: a `.location` key silently breaking on a port swap
    /// is confusing unless the user was told that is how it works.
    private var identitySection: some View {
        SettingsSection(tr("Identity", "Danh tính"), footer: display.identity.keyTier.localizedExplanation) {
            SettingsRow(tr("Vendor / Product", "Hãng / Sản phẩm")) {
                monospacedValue(
                    String(format: "0x%04X / 0x%04X", display.identity.vendorID, display.identity.productID))
            }
            SettingsRow(tr("Profile key", "Khóa hồ sơ")) {
                monospacedValue(display.id).textSelection(.enabled)
            }
            if model.ambiguousKeys.contains(display.id) {
                // Surfaced here as well as in the panel: an unconfirmed identity means brightness
                // and HiDPI settings may be attached to the wrong monitor.
                NoticeRow(tr("Identity unconfirmed", "Chưa xác nhận danh tính màn hình"),
                          actionTitle: tr("This is a separate display", "Là màn riêng")) {
                    model.pinIdentity(for: display)
                }
            }
            if !display.isBuiltIn {
                SettingsRow(
                    tr("Saved settings", "Thiết lập đã lưu"),
                    detail: tr("Brightness, controller choice and identity confirmation kept for "
                                + "this display.",
                               "Độ sáng, lựa chọn bộ điều khiển và xác nhận danh tính được lưu cho "
                                + "màn hình này.")
                ) {
                    Button(tr("Forget…", "Quên…")) { confirmingForget = true }
                }
            }
        }
        .alert(tr("Forget this display's saved settings?", "Quên thiết lập đã lưu của màn hình này?"),
               isPresented: $confirmingForget) {
            Button(tr("Forget", "Quên"), role: .destructive) { model.forgetProfile(key: display.id) }
            Button(tr("Cancel", "Hủy"), role: .cancel) {}
        } message: {
            Text(tr("Its brightness and controller go back to the defaults. Nothing on the monitor "
                        + "itself or in /Library/Displays is changed.",
                    "Độ sáng và bộ điều khiển trở về mặc định. Không thay đổi gì trên màn hình hay "
                        + "trong /Library/Displays."))
        }
    }

    private func monospacedValue(_ text: String) -> some View {
        Text(text).font(.system(size: FS.body, design: .monospaced)).foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
    }
}
