import OneMacUI

/// How a break looks on screen.
public enum BreakStyle: String, CaseIterable, Identifiable, Sendable {
    /// The screen blurs and dims to a warm dusk; a ring counts down.
    case dusk
    /// The screen blurs and dims; an orb swells and shrinks at breathing pace.
    case breath
    /// A dark pill under the menu bar; the screen stays usable.
    case island
    /// A glass card in the bottom-right corner; the screen stays usable.
    case corner

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dusk: return tr("Dusk", "Hoàng hôn")
        case .breath: return tr("Breath", "Nhịp thở")
        case .island: return tr("Island", "Đảo nổi")
        case .corner: return tr("Corner card", "Thẻ góc")
        }
    }

    var coversScreen: Bool { self == .dusk || self == .breath }

    /// The look to use when a break must not cover the screen (it gave up waiting for a call).
    var gentle: BreakStyle {
        switch self {
        case .dusk: return .island
        case .breath: return .corner
        case .island, .corner: return self
        }
    }
}

/// The user's choice: one look every time, or a different one each break.
public enum BreakStyleChoice: Hashable, Sendable {
    case rotate
    case fixed(BreakStyle)

    private static let rotateKey = "rotate"

    /// Anything unknown, including nothing stored yet, means rotate.
    init(stored: String?) {
        self = stored.flatMap(BreakStyle.init(rawValue:)).map(BreakStyleChoice.fixed) ?? .rotate
    }

    var stored: String {
        if case let .fixed(style) = self { return style.rawValue }
        return Self.rotateKey
    }

    /// The look of break number `number`. Rotation goes through the styles in order.
    func style(forBreak number: Int, gentle: Bool) -> BreakStyle {
        let style: BreakStyle
        switch self {
        case .rotate: style = BreakStyle.allCases[abs(number) % BreakStyle.allCases.count]
        case let .fixed(fixed): style = fixed
        }
        return gentle ? style.gentle : style
    }
}

#if DEBUG
import SwiftUI

/// Development aid for the PNG preview renderer: one break look frozen mid-break, without a schedule.
@MainActor
public enum BreakStylePreview {
    public static let names = BreakStyle.allCases.map(\.rawValue) + ["notice"]

    public static func size(_ name: String) -> NSSize {
        switch name {
        case "island", "notice": return BreakCardMetrics.island
        case "corner": return BreakCardMetrics.corner
        default: return NSSize(width: 1280, height: 800)
        }
    }

    @ViewBuilder public static func view(_ name: String) -> some View {
        let _ = EyeBreaks.shared.freezeForPreview(notice: name == "notice")
        switch name {
        case "island": BreakIslandView()
        case "corner": BreakCornerView()
        case "notice": BreakNoticeView()
        default: BreakCurtainView(style: BreakStyle(rawValue: name) ?? .dusk)
        }
    }
}
#endif
