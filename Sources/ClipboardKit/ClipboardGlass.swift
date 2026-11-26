import AppKit
import SwiftUI

/// Liquid Glass on macOS 26 and later, the dark HUD material before that. Used for the history
/// window itself and for the capsules and menu that float over it.
struct ClipboardGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    /// Darkens the glass so white text stays readable over a bright desktop.
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            content
                .background(ZStack { HUDMaterial(); tint ?? .clear }.clipShape(shape))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}

extension View {
    func clipboardGlass<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(ClipboardGlass(shape: shape, tint: tint))
    }
}

/// The system's HUD blur of whatever is behind the window, for macOS 15.
private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Sizes of the window. The window is larger than the glass by `margin` on every side, which is
/// where its shadow is drawn; the transparent margin lets clicks through.
enum ClipboardPanelMetrics {
    static let content = NSSize(width: 800, height: 520)
    static let margin: CGFloat = 36
    static let cornerRadius: CGFloat = 30
    /// The glass tint: black at 20%, enough to keep white text readable while the desktop shows through.
    static let tint = Color.black.opacity(0.2)
    static var window: NSSize { NSSize(width: content.width + margin * 2, height: content.height + margin * 2) }
}

#if DEBUG
/// Development aid for the PNG preview renderer: the history window filled with sample copies.
@MainActor
public enum ClipboardPanelPreview {
    public static var size: NSSize { ClipboardPanelMetrics.window }

    public static func view() -> some View {
        ClipboardHistory.shared.loadPreviewSamples()
        let model = ClipboardPanelModel()
        model.targetApp = "Safari"
        return ClipboardPanelView(history: .shared, model: model, perform: { _, _ in })
    }
}
#endif
