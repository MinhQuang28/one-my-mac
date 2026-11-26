import HiDisplayKit
import OneMacUI

/// A monitor's settings beyond brightness, as read over DDC. A `nil` field means the monitor did
/// not answer for that feature, and its control is hidden.
struct DisplayExtras: Equatable {
    struct Level: Equatable {
        /// 0…1.
        var value: Float
        /// The monitor's own raw maximum, for scaling writes.
        var maximum: UInt16
    }

    var volume: Level?
    var contrast: Level?
    /// Raw MCCS input-source value (VCP 0x60), low byte only.
    var inputSource: UInt16?
}

/// The input sources offered in the picker. MCCS values; `0x1B` is not in the standard but is what
/// monitors with a USB-C input use in practice.
enum DisplayInput {
    static let standard: [UInt16] = [0x0F, 0x10, 0x11, 0x12, 0x1B]

    static func label(for raw: UInt16) -> String {
        switch raw {
        case 0x0F: return "DisplayPort 1"
        case 0x10: return "DisplayPort 2"
        case 0x11: return "HDMI 1"
        case 0x12: return "HDMI 2"
        case 0x1B: return "USB-C"
        default: return tr("Input", "Cổng") + String(format: " 0x%02X", raw)
        }
    }
}

enum VolumeKey: Sendable {
    case up, down, mute
}
