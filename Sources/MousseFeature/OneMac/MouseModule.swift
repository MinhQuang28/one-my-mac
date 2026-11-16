import OneMacUI
import SwiftUI

/// What OneMac needs from the Mousse feature: lifecycle, the panel cards and the settings pages.
@MainActor
public enum MouseModule {
    /// Prompts for Accessibility once if needed and brings up the event-tap engine.
    public static func start() {
        if !AccessibilityPermission.isTrusted { AccessibilityPermission.request() }
        EventTapEngine.shared.start(config: ConfigStore.shared.config)
    }

    /// The config write is debounced; flush a change made in the last half second.
    public static func stop() { ConfigStore.shared.flushPendingSave() }
}

/// One settings page from the Mousse feature.
public struct MousePaneView: View {
    let pane: SettingsPane
    @ObservedObject private var store = ConfigStore.shared
    public init(pane: SettingsPane) { self.pane = pane }

    public var body: some View {
        Group {
            if let page {
                SettingsView(page: page)
            } else {
                EmptyView()
            }
        }
        .environmentObject(store)
    }

    private var page: SettingsView.Page? {
        switch pane {
        case .mouseGeneral: return .general
        case .mouseButtons: return .buttons
        case .mouseScroll: return .scroll
        case .mouseDevices: return .devices
        case .mouseGestures: return .gestures
        default: return nil
        }
    }
}

/// The Mouse tab of the panel: on/off, scroll direction and feel, shortcuts to the full settings.
public struct MouseCards: View {
    @ObservedObject private var store = ConfigStore.shared
    public init() {}

    public var body: some View {
        VStack(spacing: Gap.sm + 2) {
            if !AccessibilityPermission.isTrusted {
                NoticeRow(tr("Accessibility permission is needed to enhance the mouse", "Cần quyền Trợ năng để điều khiển chuột"),
                          actionTitle: tr("Grant", "Cấp quyền")) {
                    AccessibilityPermission.openSettings()
                }
            }
            Card {
                CardHeader(icon: "computermouse.fill", tint: .indigo, title: tr("Mouse", "Chuột"),
                           subtitle: store.config.enabled
                               ? tr("Handling scrolling and buttons", "Đang xử lý cuộn và nút chuột")
                               : tr("Off — the mouse behaves as default", "Đã tắt — chuột chạy như mặc định")) {
                    CompactToggle(isOn: $store.config.enabled)
                }
            }
            Card {
                CardHeader(icon: "scroll", tint: .teal, title: tr("Scrolling", "Cuộn"))
                ChipPicker(ScrollMode.allCases.map { ($0, $0.label) }, selection: $store.config.scrollSettings.scrollMode)
                ToggleRow(tr("Reverse vertical scroll", "Đảo chiều cuộn dọc"), icon: "arrow.up.arrow.down", isOn: $store.config.scrollSettings.reverseScroll)
                ToggleRow(tr("Reverse horizontal scroll", "Đảo chiều cuộn ngang"), icon: "arrow.left.arrow.right",
                          isOn: $store.config.scrollSettings.reverseScrollHorizontal)
                if store.config.scrollMode != .native {
                    HStack(spacing: Gap.sm) {
                        Image(systemName: "speedometer").font(.system(size: FS.body)).foregroundStyle(.secondary).frame(width: 16)
                        Text(tr("Speed", "Tốc độ")).font(.system(size: FS.body))
                        Slider(value: $store.config.scrollSettings.scrollSpeed, in: 0.05...1.5).controlSize(.small)
                    }
                }
                HStack {
                    LinkButton(tr("Advanced scrolling", "Cuộn nâng cao")) { Navigator.shared.open(.mouseScroll) }
                    Spacer()
                }
            }
            Card {
                CardHeader(icon: "button.programmable", tint: .orange, title: tr("Buttons & gestures", "Nút & cử chỉ"),
                           subtitle: tr("\(store.config.mappings.count) buttons mapped", "\(store.config.mappings.count) nút đã gán")
                               + " · \(spacesText)")
                HStack {
                    LinkButton(tr("Map buttons", "Gán nút")) { Navigator.shared.open(.mouseButtons) }
                    Spacer()
                    LinkButton(tr("Gestures", "Cử chỉ")) { Navigator.shared.open(.mouseGestures) }
                    Spacer()
                    LinkButton(tr("Devices", "Thiết bị")) { Navigator.shared.open(.mouseDevices) }
                }
            }
        }
    }

    private var spacesText: String {
        store.config.spaceDragButton == 0
            ? tr("Space drag off", "kéo Spaces tắt")
            : tr("Space drag on button \(store.config.spaceDragButton)", "kéo Spaces bằng nút \(store.config.spaceDragButton)")
    }
}
