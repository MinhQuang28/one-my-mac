import AppKit
import SwiftUI

/// The windows of an eye break: a curtain over every display or a small card, and a heads-up before it.
/// They never activate OneMac, so the app being used keeps its focus and comes back untouched.
@MainActor
final class BreakOverlay {
    private var curtains: [NSPanel] = []
    private var notice: NSPanel?

    /// Shows the break: a small card at the top centre when `compact`, else a curtain on every display.
    func showBreak(compact: Bool) {
        guard curtains.isEmpty else { return }
        closeNotice()
        if compact {
            guard let panel = Self.cardPanel(BreakCompactView()) else { return }
            panel.orderFrontRegardless()
            curtains = [panel]
            return
        }
        curtains = NSScreen.screens.map { screen in
            let panel = Self.panel(frame: screen.frame, content: BreakCurtainView())
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.animator().alphaValue = 1
            return panel
        }
    }

    func showNotice() {
        guard notice == nil, curtains.isEmpty, let panel = Self.cardPanel(BreakNoticeView()) else { return }
        panel.orderFrontRegardless()
        notice = panel
    }

    /// A card-sized panel just under the menu bar, centred on the screen being used.
    private static func cardPanel(_ content: some View) -> NSPanel? {
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return nil }
        let size = BreakCardMetrics.size
        return panel(frame: NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 12,
                                   width: size.width, height: size.height), content: content)
    }

    func hide() {
        closeNotice()
        curtains.forEach { $0.close() }
        curtains = []
    }

    private func closeNotice() {
        notice?.close()
        notice = nil
    }

    private static func panel(frame: NSRect, content: some View) -> NSPanel {
        let panel = ClickablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = FirstClickHostingView(rootView: content)
        panel.setFrame(frame, display: false)
        return panel
    }
}

/// A borderless panel refuses key status by default, which would make its buttons ignore clicks.
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets a button react to the very first click, without one extra click to focus the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
