import Foundation
import HiDisplayKit
import OneMacUI

// `HiDisplayKit` sits below `OneMacUI` and so cannot call `tr`; its `label`/`explanation` strings are
// English only. These are the bilingual versions for the short, fixed sets the views show.

extension BrightnessControllerKind {
    var localizedLabel: String {
        switch self {
        case .native: return tr("Native", "Gốc")
        case .ddc: return "DDC"
        case .gamma: return tr("Gamma (software)", "Gamma (phần mềm)")
        case .shade: return tr("Shade (software)", "Lớp phủ (phần mềm)")
        }
    }
}

extension BrightnessKeyTarget {
    var localizedLabel: String {
        switch self {
        case .displayUnderMouse: return tr("Display under the pointer", "Màn hình dưới con trỏ")
        case .mainDisplay: return tr("Main display", "Màn hình chính")
        case .allExternal: return tr("All external displays", "Mọi màn hình ngoài")
        case .allDisplays: return tr("All displays", "Mọi màn hình")
        }
    }
}

extension DisplayKeyTier {
    var localizedExplanation: String {
        switch self {
        case .strong:
            return tr("Identified by serial number or EDID — stable across reboots and port changes.",
                      "Nhận diện bằng số sê-ri hoặc EDID — ổn định qua khởi động lại và đổi cổng.")
        case .weak:
            return tr("Identified by vendor and product only — this monitor reports no serial number.",
                      "Chỉ nhận diện bằng hãng và sản phẩm — màn hình này không báo số sê-ri.")
        case .location:
            return tr("Identified by its port, because two identical monitors without serial numbers are "
                        + "attached. Moving it to another port will look like a new display.",
                      "Nhận diện theo cổng cắm, vì có hai màn hình giống hệt nhau không có số sê-ri. "
                        + "Đổi sang cổng khác sẽ bị coi là màn hình mới.")
        }
    }
}

extension HiDPISharpness {
    var localizedLabel: String {
        switch self {
        case .pixelPerfect:
            return tr("pixel-perfect", "khớp từng điểm ảnh")
        case .supersampled(let ratio):
            return String(format: tr("%.2f× supersampled", "siêu lấy mẫu %.2f×"), ratio)
        case .upscaled(let ratio):
            return String(format: tr("%.2f× upscaled — soft", "phóng to %.2f× — mờ"), ratio)
        }
    }

    var localizedExplanation: String {
        switch self {
        case .pixelPerfect:
            return tr("Matches the panel exactly — nothing is resampled. Sharpest, but the interface is "
                        + "at its largest.",
                      "Khớp chính xác với tấm nền — không lấy mẫu lại. Nét nhất, nhưng giao diện to nhất.")
        case .supersampled(let ratio):
            return String(
                format: tr("Rendered at %.2f× the panel's pixels and scaled down. Sharp, with more "
                            + "desktop space; costs some GPU bandwidth.",
                           "Dựng ở %.2f× số điểm ảnh của tấm nền rồi thu nhỏ. Nét, thêm không gian làm "
                            + "việc; tốn thêm tài nguyên GPU."), ratio)
        case .upscaled(let ratio):
            return String(
                format: tr("Rendered at only %.2f× the panel's pixels and scaled up. Looks softer than "
                            + "the native resolution.",
                           "Chỉ dựng ở %.2f× số điểm ảnh của tấm nền rồi phóng to. Trông mờ hơn độ phân "
                            + "giải gốc."), ratio)
        }
    }
}
