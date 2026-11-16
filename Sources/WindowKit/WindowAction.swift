import OneMacUI

/// What can be done to the focused window. Raw values are persisted (mouse-button mappings).
public enum WindowAction: String, Codable, CaseIterable, Hashable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, restore
    case nextDisplay, previousDisplay

    public var title: String {
        switch self {
        case .leftHalf: return tr("Left Half", "Nửa trái")
        case .rightHalf: return tr("Right Half", "Nửa phải")
        case .topHalf: return tr("Top Half", "Nửa trên")
        case .bottomHalf: return tr("Bottom Half", "Nửa dưới")
        case .topLeft: return tr("Top Left", "Góc trên trái")
        case .topRight: return tr("Top Right", "Góc trên phải")
        case .bottomLeft: return tr("Bottom Left", "Góc dưới trái")
        case .bottomRight: return tr("Bottom Right", "Góc dưới phải")
        case .maximize: return tr("Maximize", "Phóng to")
        case .center: return tr("Center", "Ra giữa")
        case .restore: return tr("Restore", "Về kích thước cũ")
        case .nextDisplay: return tr("Next Display", "Sang màn hình kế")
        case .previousDisplay: return tr("Previous Display", "Sang màn hình trước")
        }
    }

    public var systemImage: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .maximize: return "rectangle.fill"
        case .center: return "rectangle.center.inset.filled"
        case .restore: return "arrow.uturn.backward"
        case .nextDisplay: return "rectangle.righthalf.inset.filled.arrow.right"
        case .previousDisplay: return "rectangle.lefthalf.inset.filled.arrow.left"
        }
    }
}
