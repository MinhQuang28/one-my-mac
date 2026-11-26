import AppKit
import SwiftUI

/// The windows of an eye break: a curtain over every display, a pill under the menu bar or a card in
/// the corner, and a heads-up pill before it.
/// They never activate OneMac, so the app being used keeps its focus and comes back untouched.
@MainActor
final class BreakOverlay {
    private var curtains: [NSPanel] = []
    private var notice: NSPanel?
    private var coversScreens = false
    private var curtainStyle = BreakStyle.dusk
    /// Slow enough that the screen dims rather than switches.
    private static let curtainFade: TimeInterval = 2.4
    /// Not fully opaque: a hint of the desktop stays visible through the blur, so the curtain
    /// reads as a veil over the work rather than a wall in front of it.
    private static let curtainOpacity: CGFloat = 0.94
    private var screenObserver: NSObjectProtocol?
    private let emergencyExit: EmergencyExit

    /// `onEmergencyExit` runs when the user forces the curtain away (Esc three times).
    init(onEmergencyExit: @escaping () -> Void) {
        emergencyExit = EmergencyExit(onExit: onEmergencyExit)
        // A display plugged in, removed or resized during a break: cover what is there now.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildCurtains() }
        }
    }

    /// Shows the break in `style`: a curtain on every display, or one small window on the screen in use.
    func showBreak(style: BreakStyle) {
        guard curtains.isEmpty else { return }
        closeNotice()
        switch style {
        case .dusk, .breath:
            coversScreens = true
            curtainStyle = style
            emergencyExit.arm()
            curtains = Self.curtainPanels(style: style, fadeIn: true)
        case .island:
            curtains = [Self.smallPanel(BreakIslandView(), size: BreakCardMetrics.island, corner: false)].compactMap { $0 }
        case .corner:
            curtains = [Self.smallPanel(BreakCornerView(), size: BreakCardMetrics.corner, corner: true)].compactMap { $0 }
        }
    }

    private func rebuildCurtains() {
        guard coversScreens else { return }
        curtains.forEach { $0.close() }
        curtains = Self.curtainPanels(style: curtainStyle, fadeIn: false)
    }

    private static func curtainPanels(style: BreakStyle, fadeIn: Bool) -> [NSPanel] {
        NSScreen.screens.map { screen in
            let panel = panel(frame: screen.frame, content: BreakCurtainView(style: style))
            panel.alphaValue = fadeIn ? 0 : curtainOpacity
            panel.orderFrontRegardless()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = curtainFade
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().alphaValue = curtainOpacity
                }
            }
            return panel
        }
    }

    func showNotice() {
        guard notice == nil, curtains.isEmpty,
              let panel = Self.smallPanel(BreakNoticeView(), size: BreakCardMetrics.island, corner: false) else { return }
        notice = panel
    }

    /// A small window on the screen being used: centred under the menu bar, or in the bottom-right
    /// corner. Its content animates itself in.
    private static func smallPanel(_ content: some View, size: NSSize, corner: Bool) -> NSPanel? {
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return nil }
        let origin = corner ? NSPoint(x: area.maxX - size.width, y: area.minY)
                            : NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height)
        let panel = panel(frame: NSRect(origin: origin, size: size), content: content)
        panel.orderFrontRegardless()
        return panel
    }

    func hide() {
        closeNotice()
        curtains.forEach { $0.close() }
        curtains = []
        coversScreens = false
        emergencyExit.disarm()
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
