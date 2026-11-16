import HiDisplayKit
import OneMacUI
import SwiftUI

/// The brightness section of `DisplayPage`: slider, which controller drives it, and why.
struct DisplayBrightnessSection: View {

    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel

    private var brightness: Float { model.brightness.brightness(for: display.id) }
    private var phase: BrightnessPhase { model.brightness.phase(for: display.id) }

    var body: some View {
        let availability = model.brightness.availability[display.id] ?? ControllerAvailability()
        let userOverride = model.brightness.userOverride(for: display.id)
        let details = model.brightness.probeDetails[display.id] ?? [:]

        SettingsSection(tr("Brightness", "Độ sáng")) {
            // The same slider as the panel's, so brightness can be set from here while comparing
            // controllers, without closing the window to reach the panel.
            SettingsStack(tr("Brightness", "Độ sáng"), value: "\(Int((brightness * 100).rounded()))%") {
                Slider(
                    value: Binding(
                        get: { Double(brightness) },
                        set: { model.setBrightness(Float($0), for: display) }),
                    in: 0...1
                ) {
                    Text(tr("Brightness", "Độ sáng"))
                }
                .labelsHidden()
                .disabled(model.brightness.controller(for: display.id) == nil)
            }

            SettingsRow(
                tr("Controller", "Bộ điều khiển"),
                detail: tr("How brightness is driven. Automatic picks the best one available.",
                           "Cách điều khiển độ sáng. Tự động chọn cách tốt nhất hiện có.")
            ) {
                Picker("", selection: Binding(
                    get: { userOverride },
                    set: { model.setController($0, for: display) })
                ) {
                    Text(tr("Automatic", "Tự động")).tag(BrightnessControllerKind?.none)
                    ForEach(BrightnessControllerKind.allCases) { kind in
                        Text(kind.localizedLabel + (availability.isAvailable(kind)
                            ? "" : tr(" (unavailable)", " (không khả dụng)")))
                            .tag(BrightnessControllerKind?.some(kind))
                    }
                }
                .labelsHidden().fixedSize()
            }

            SettingsRow(
                tr("Status", "Trạng thái"),
                detail: phase == .heldForDDC
                    ? tr("DDC has worked before; the brightness you set is kept in the meantime.",
                         "DDC từng hoạt động; độ sáng bạn đặt được giữ lại trong lúc chờ.")
                    : nil
            ) {
                phaseLabel.font(.system(size: FS.body))
            }

            if let warning = model.brightness.warnings[display.id] {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: FS.body))
            }

            // The probe details explain the status above; worth having, not worth the space by
            // default.
            if !details.isEmpty {
                DisclosureGroup(tr("Probe results", "Kết quả dò")) {
                    VStack(spacing: Gap.xs) {
                        ForEach(BrightnessControllerKind.allCases) { kind in
                            if let detail = details[kind] {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(kind.localizedLabel)
                                    Spacer(minLength: Gap.md)
                                    Text(detail)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                    .font(.system(size: FS.body))
                    .padding(.top, Gap.xs)
                }
                .font(.system(size: FS.title))
            }
        }
    }

    /// The probe cycle, in words. "Checking" and "waiting for DDC" are the app doing the right
    /// thing, and used to be indistinguishable from "nothing works".
    @ViewBuilder
    private var phaseLabel: some View {
        switch phase {
        case .probing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Checking controllers…", "Đang dò bộ điều khiển…"))
            }
            .foregroundStyle(.secondary)
        case .heldForDDC:
            Label(tr("Waiting for DDC…", "Đang chờ DDC…"), systemImage: "clock")
                .foregroundStyle(.secondary)
        case .ready(let kind):
            Label(tr("Using \(kind.localizedLabel)", "Đang dùng \(kind.localizedLabel)"),
                  systemImage: kind.isHardware ? "bolt.fill" : "circle.lefthalf.filled")
        case .unavailable:
            Label(tr("No brightness control available", "Không có cách chỉnh độ sáng"),
                  systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}
