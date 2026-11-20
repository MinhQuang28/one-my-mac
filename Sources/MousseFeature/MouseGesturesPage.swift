import OneMacUI
import SwiftUI

/// Hold-a-button-and-drag gesture for switching Spaces.
struct MouseGesturesPage: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        SettingsPage(pane: .mouseGestures) {
            // Following the pointer needs the dock-swipe synthesis that macOS 27 no longer honours.
            let canFollow = DockSwipeSynthesizer.isSupported
            SettingsSection(footer: canFollow
                ? tr("Drag left or right to switch Spaces, up for Mission Control, down for App Exposé.",
                     "Kéo trái/phải để đổi Space, kéo lên mở Mission Control, kéo xuống mở App Exposé.")
                : tr("Drag left or right to switch Spaces, up for Mission Control, down for App Exposé. On this macOS version the Space jumps once per drag distance; it cannot slide with the pointer.",
                     "Kéo trái/phải để đổi Space, kéo lên mở Mission Control, kéo xuống mở App Exposé. Trên phiên bản macOS này Space nhảy theo từng quãng kéo, không trượt theo con trỏ được.")) {
                SettingsRow(tr("Drag to switch Spaces", "Kéo để đổi Space"),
                            detail: tr("Hold this mouse button and drag.", "Giữ nút chuột này rồi kéo."),
                            icon: "hand.draw") {
                    Picker("", selection: $store.config.spaceDragButton) {
                        Text(tr("Off", "Tắt")).tag(0)
                        ForEach(3...9, id: \.self) { Text(tr("Button \($0)", "Nút \($0)")).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if store.config.spaceDragButton != 0 {
                    if canFollow {
                        SettingsRow(tr("Follow the pointer", "Trượt theo con trỏ"),
                                    detail: tr("Drives the real macOS slide, like a three-finger swipe. Off = one jump per distance.",
                                               "Trượt thật như vuốt ba ngón. Tắt = nhảy từng Space theo quãng kéo."),
                                    isOn: $store.config.spaceDragFollowFinger)
                    }
                    if !canFollow || !store.config.spaceDragFollowFinger {
                        SettingsSlider(title: tr("Drag distance per Space", "Quãng kéo cho mỗi Space"),
                                       value: $store.config.spaceDragThreshold, range: 100...400, step: 10,
                                       format: { "\(Int($0)) px" })
                    }
                    SettingsRow(tr("Reverse drag direction", "Đảo chiều kéo"), isOn: $store.config.spaceDragReverse)
                    SettingsRow(tr("Keep pointer in place while dragging", "Giữ con trỏ đứng yên khi kéo"),
                                isOn: $store.config.spaceDragLockPointer)
                }
            }
        }
    }
}
