import HiDisplayKit
import OneMacUI
import SwiftUI

/// The "Displays" tab of the panel: one card per display, then HiDPI and recovery shortcuts.
public struct DisplayCards: View {
    @ObservedObject private var model = AppModel.shared
    public init() {}

    public var body: some View {
        VStack(spacing: Gap.sm + 2) {
            if model.displays.isEmpty {
                Card { CardHeader(icon: "display", tint: .secondary, title: tr("No display found", "Không thấy màn hình")) }
            }
            ForEach(model.displays) { display in
                DisplayCard(display: display)
            }
            Card {
                CardHeader(icon: "rectangle.expand.vertical", tint: .purple, title: tr("HiDPI for external displays", "HiDPI cho màn ngoài"),
                           subtitle: tr("Add Retina resolutions to 1080p / 1440p monitors",
                                        "Thêm độ phân giải Retina cho màn 1080p / 1440p")) {
                    Button(tr("Open…", "Mở…")) { Navigator.shared.open(.hiDPI) }.controlSize(.small)
                }
                HStack {
                    if model.brightnessManagedDisplays.count > 1 {
                        LinkButton(tr("Sync brightness", "Đồng bộ độ sáng"), icon: "arrow.triangle.2.circlepath") {
                            model.syncAllDisplays()
                        }
                    }
                    Spacer()
                    LinkButton(tr("Reset dimming", "Reset làm tối"), icon: "sun.max") { model.resetDimming() }
                }
            }
        }
        .environmentObject(model)
    }
}

/// One display: name, brightness slider with controller label, resolution picker, warnings.
struct DisplayCard: View {
    let display: DisplayDevice
    @EnvironmentObject private var model: AppModel

    private var brightness: Float { model.brightness.brightness(for: display.id) }
    private var controller: BrightnessControllerKind? { model.brightness.controller(for: display.id) }
    private var phase: BrightnessPhase { model.brightness.phase(for: display.id) }

    var body: some View {
        Card {
            CardHeader(icon: display.isBuiltIn ? "laptopcomputer" : "display",
                       tint: display.isBuiltIn ? .accentColor : .teal,
                       title: display.name, subtitle: subtitle) {
                if !display.isBuiltIn, controller != nil {
                    Text("\(Int((brightness * 100).rounded()))%")
                        .font(.system(size: FS.value, weight: .bold)).monospacedDigit()
                }
            }
            if display.isBuiltIn {
                Text(tr("macOS controls the built-in display's brightness (F1/F2 keys).",
                        "Độ sáng màn tích hợp do macOS điều khiển (phím F1/F2)."))
                    .font(.system(size: FS.label)).foregroundStyle(.secondary)
            } else if controller != nil {
                CapsuleSlider(
                    value: Binding(get: { Double(brightness) },
                                   set: { model.setBrightness(Float($0), for: display) }),
                    icon: "sun.max.fill",
                    label: tr("\(display.name) brightness", "Độ sáng \(display.name)"))
            } else if phase == .probing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Checking brightness control…", "Đang dò điều khiển độ sáng…"))
                        .font(.system(size: FS.label)).foregroundStyle(.secondary)
                }
            } else {
                Text(tr("This display has no brightness control.", "Màn này không hỗ trợ chỉnh độ sáng."))
                    .font(.system(size: FS.label)).foregroundStyle(.secondary)
            }
            HStack(spacing: Gap.sm) {
                resolutionPicker
                Spacer()
                LinkButton(tr("Details", "Chi tiết")) { Navigator.shared.open(.display(display.id)) }
            }
            if let warning = model.brightness.warnings[display.id] {
                Text(warning).font(.system(size: FS.label)).foregroundStyle(.orange)
            }
            if model.ambiguousKeys.contains(display.id) {
                NoticeRow(tr("Identity unconfirmed", "Chưa xác nhận danh tính màn hình"),
                          actionTitle: tr("This is a separate display", "Là màn riêng")) {
                    model.pinIdentity(for: display)
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let mode = display.currentMode { parts.append(mode.displayLabel) }
        if display.isMain { parts.append(tr("Main display", "Màn chính")) }
        if phase == .heldForDDC {
            parts.append(tr("waiting for DDC…", "chờ DDC…"))
        } else if !display.isBuiltIn, let controller {
            parts.append(controller.localizedLabel)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var resolutionPicker: some View {
        let modes = display.curatedModes
        if !display.isBuiltIn, modes.count > 1 {
            Picker(tr("Resolution", "Độ phân giải"), selection: Binding(
                get: { display.currentMode?.sizeKey ?? "" },
                set: { key in
                    guard let target = modes.first(where: { $0.sizeKey == key }) else { return }
                    model.setMode(DisplayModeSwitcher.mode(matchingSizeOf: target,
                                                           preservingRate: display.currentMode?.refreshRate ?? 0,
                                                           in: display.availableModes), for: display)
                })
            ) {
                ForEach(modes) { Text($0.displayLabel).tag($0.sizeKey) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
        }
    }
}
