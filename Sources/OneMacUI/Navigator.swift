import SwiftUI

/// Every page of the OneMac settings window. Feature modules ask for a page through `Navigator`
/// without knowing how the window is built.
public enum SettingsPane: Hashable, Sendable {
    case display(String)        // HiDisplay profile key
    case hiDPI
    case brightnessKeys
    case displayDiagnostics
    case mouseGeneral
    case mouseButtons
    case mouseScroll
    case mouseDevices
    case mouseGestures
    case windows
    case eyeBreaks
    case general

    public var title: String {
        switch self {
        case .display: return tr("Display", "Màn hình")
        case .hiDPI: return "HiDPI"
        case .brightnessKeys: return tr("Brightness Keys", "Phím độ sáng")
        case .displayDiagnostics: return tr("Diagnostics", "Chẩn đoán")
        case .mouseGeneral: return tr("General", "Chung")
        case .mouseButtons: return tr("Buttons", "Nút chuột")
        case .mouseScroll: return tr("Scrolling", "Cuộn")
        case .mouseDevices: return tr("Devices", "Thiết bị")
        case .mouseGestures: return tr("Gestures", "Cử chỉ")
        case .windows: return tr("Windows", "Cửa sổ")
        case .eyeBreaks: return tr("Eye Breaks", "Nghỉ mắt")
        case .general: return tr("General", "Chung")
        }
    }

    /// One line under the page title saying what the page is for.
    public var subtitle: String {
        switch self {
        case .display: return tr("Resolution, brightness and identity of this display.",
                                 "Độ phân giải, độ sáng và định danh của màn hình này.")
        case .hiDPI: return tr("Sharp scaled resolutions for external displays.",
                               "Độ phân giải HiDPI sắc nét cho màn hình ngoài.")
        case .brightnessKeys: return tr("Let F1 and F2 dim external displays too.",
                                        "Để F1 và F2 chỉnh sáng cả màn hình ngoài.")
        case .displayDiagnostics: return tr("What OneMac sees of your displays, for troubleshooting.",
                                            "Những gì OneMac đọc được từ màn hình, dùng khi gặp sự cố.")
        case .mouseGeneral: return tr("Turn mouse enhancements on, and check what they need to run.",
                                      "Bật nâng cấp chuột và kiểm tra các điều kiện để chạy.")
        case .mouseButtons: return tr("Give the extra mouse buttons something to do.",
                                      "Giao việc cho các nút phụ của chuột.")
        case .mouseScroll: return tr("How the mouse wheel feels, and where it behaves differently.",
                                     "Cảm giác của bánh xe chuột và những nơi nó chạy khác đi.")
        case .mouseDevices: return tr("Separate scroll settings for each mouse.",
                                      "Cài đặt cuộn riêng cho từng con chuột.")
        case .mouseGestures: return tr("Switch Spaces by holding a button and dragging.",
                                       "Đổi Space bằng cách giữ một nút rồi kéo.")
        case .windows: return tr("Snap windows to halves and corners, and send them to another display.",
                                 "Chia cửa sổ theo nửa, góc phần tư và chuyển sang màn hình khác.")
        case .eyeBreaks: return tr("Short, regular breaks from the screen to rest your eyes.",
                                   "Những quãng nghỉ ngắn, đều đặn để mắt rời khỏi màn hình.")
        case .general: return tr("Language, startup and everyday utilities.",
                                 "Ngôn ngữ, khởi động và các tiện ích thường dùng.")
        }
    }

    /// Colour of the page's icon in the sidebar and the page header.
    public var tint: Color {
        switch self {
        case .display: return .blue
        case .hiDPI: return .purple
        case .brightnessKeys: return .orange
        case .displayDiagnostics: return .teal
        case .mouseGeneral: return .indigo
        case .mouseButtons: return .pink
        case .mouseScroll: return .green
        case .mouseDevices: return .brown
        case .mouseGestures: return .cyan
        case .windows: return .mint
        case .eyeBreaks: return .teal
        case .general: return .gray
        }
    }

    public var systemImage: String {
        switch self {
        case .display: return "display"
        case .hiDPI: return "rectangle.expand.vertical"
        case .brightnessKeys: return "sun.max"
        case .displayDiagnostics: return "stethoscope"
        case .mouseGeneral: return "computermouse"
        case .mouseButtons: return "button.programmable"
        case .mouseScroll: return "scroll"
        case .mouseDevices: return "cable.connector"
        case .mouseGestures: return "hand.draw"
        case .windows: return "rectangle.split.2x1"
        case .eyeBreaks: return "eye"
        case .general: return "gearshape"
        }
    }
}

/// Opens the settings window on a page. The app installs `openWindow` at launch.
@MainActor
public final class Navigator: ObservableObject {
    public static let shared = Navigator()
    @Published public var pane: SettingsPane = .general
    /// Set by the app: brings the settings window forward.
    public var showWindow: (() -> Void)?

    public func open(_ pane: SettingsPane) {
        self.pane = pane
        NSApp.activate()
        showWindow?()
    }
}
