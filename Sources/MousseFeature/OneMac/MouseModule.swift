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

    /// Ends any gesture still in flight (scroll, pinch, Space drag, pinned pointer) and flushes
    /// the debounced config write, so a change made in the last half second survives the quit.
    public static func stop() {
        EventTapEngine.shared.shutdown()
        ConfigStore.shared.flushPendingSave()
    }
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
            // Re-read every 2 s while the panel is open, so the notice clears once the grant lands
            // and a tap that is failing shows up here, not only on the settings page.
            TimelineView(.periodic(from: .now, by: 2)) { context in
                tapNotice(EventTapEngine.shared.tapStatus(now: context.date).health)
            }
            if let issue = store.persistenceIssue {
                NoticeRow(issue.message, actionTitle: tr("Fix…", "Xử lý…")) { Navigator.shared.open(.mouseGeneral) }
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
                        Text(tr("Speed", "Tốc độ")).font(.system(size: FS.body))
                        CapsuleSlider(value: $store.config.scrollSettings.scrollSpeed, in: 0.05...1.5,
                                      icon: "speedometer", label: tr("Scroll speed", "Tốc độ cuộn"))
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

    @ViewBuilder
    private func tapNotice(_ health: EventTapHealth) -> some View {
        switch health {
        case .waitingForPermission:
            NoticeRow(tr("Accessibility permission is needed to enhance the mouse", "Cần quyền Trợ năng để điều khiển chuột"),
                      actionTitle: tr("Grant", "Cấp quyền")) {
                AccessibilityPermission.openSettings()
            }
        case .failed:
            NoticeRow(tr("The mouse engine could not start and keeps retrying.", "Bộ xử lý chuột chưa khởi động được, đang thử lại."),
                      actionTitle: tr("Details", "Chi tiết")) { Navigator.shared.open(.mouseGeneral) }
        case .recovering:
            NoticeRow(tr("The mouse engine is recovering…", "Bộ xử lý chuột đang khôi phục…"))
        case .initializing, .healthy:
            EmptyView()
        }
    }

    private var spacesText: String {
        store.config.spaceDragButton == 0
            ? tr("Space drag off", "kéo Spaces tắt")
            : tr("Space drag on button \(store.config.spaceDragButton)", "kéo Spaces bằng nút \(store.config.spaceDragButton)")
    }
}
