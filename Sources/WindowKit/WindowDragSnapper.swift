import AppKit
import ApplicationServices

/// Drag-to-edge snapping: while a window is dragged with the left button, pushing the pointer
/// against a screen edge previews a zone, and letting go there snaps the window to it.
///
/// Costs a few Accessibility calls once per drag (to learn which window, and where it started) and
/// plain arithmetic per drag event. OneMac's own windows are not covered: global monitors do not
/// see this app's events.
@MainActor
final class WindowDragSnapper {
    /// One press-drag-release of the left button.
    private struct Drag {
        let start: CGPoint
        var displays: [WindowAccess.Display] = []
        var window: AXUIElement?
        var startFrame: CGRect?
        /// The window under the drag was looked up (once the pointer moved far enough).
        var captured = false
        /// The window was seen to follow the pointer at its original size: a move, not a resize.
        var confirmed = false
        /// Esc was pressed, or there is nothing to snap: ignore the rest of this drag.
        var cancelled = false
        /// How many times the window was read to see whether it follows the pointer.
        var checks = 0
        /// The zone being previewed.
        var zone: WindowSnapZone?
    }

    /// Reads of the window allowed per drag while it has not been seen moving — so dragging a scroll
    /// bar or a selection along a screen edge does not turn into a stream of Accessibility calls.
    private static let maxChecks = 6

    /// Pointer travel before a press counts as a drag.
    private static let threshold: CGFloat = 4

    private let onDrop: (AXUIElement, WindowAction, CGRect, CGRect) -> Void
    private var monitor: Any?
    private var escapeMonitor: Any?
    private var drag: Drag?
    private let preview = WindowSnapPreview()

    /// `onDrop(window, action, usable area of the display, frame before the drag)`.
    init(onDrop: @escaping (AXUIElement, WindowAction, CGRect, CGRect) -> Void) { self.onDrop = onDrop }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Global monitors call back on the main thread.
            MainActor.assumeIsolated { self?.handle(event.type) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endDrag()
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            endDrag()
            if let pointer = WindowAccess.pointer() { drag = Drag(start: pointer) }
        case .leftMouseDragged:
            dragged()
        case .leftMouseUp:
            drop()
        default:
            break
        }
    }

    private func dragged() {
        guard var drag, !drag.cancelled, let pointer = WindowAccess.pointer() else { return }
        defer { self.drag = drag }
        if !drag.captured {
            guard hypot(pointer.x - drag.start.x, pointer.y - drag.start.y) > Self.threshold else { return }
            drag.captured = true
            drag.displays = WindowAccess.displays()
            if AXIsProcessTrusted(), let window = WindowAccess.focusedWindow() {
                drag.window = window
                drag.startFrame = WindowAccess.frame(of: window)
            }
            if drag.startFrame == nil { drag.cancelled = true; return }
        }
        let zone = WindowSnapZones.zone(at: pointer, displays: drag.displays.map(\.frame))
        guard zone != drag.zone else { return }
        guard let zone, isMovingWindow(&drag) else {
            drag.zone = nil
            hidePreview()
            return
        }
        drag.zone = zone
        let area = drag.displays[zone.display].visible
        showPreview(WindowLayout.frame(for: zone.action, in: area, current: drag.startFrame ?? area))
    }

    /// True once the window was seen away from where the drag began at the same size — so the drag
    /// is moving it, not resizing it or selecting text inside it.
    private func isMovingWindow(_ drag: inout Drag) -> Bool {
        if drag.confirmed { return true }
        guard drag.checks < Self.maxChecks else { return false }
        drag.checks += 1
        guard let window = drag.window, let start = drag.startFrame, let now = WindowAccess.frame(of: window) else { return false }
        let moved = abs(now.minX - start.minX) > 2 || abs(now.minY - start.minY) > 2
        let sameSize = abs(now.width - start.width) <= 2 && abs(now.height - start.height) <= 2
        drag.confirmed = moved && sameSize
        return drag.confirmed
    }

    private func drop() {
        defer { endDrag() }
        guard let drag, !drag.cancelled, drag.confirmed, let zone = drag.zone,
              let window = drag.window, let original = drag.startFrame else { return }
        let area = drag.displays[zone.display].visible
        // Let the app finish its own drag first, or its last move lands on top of ours.
        DispatchQueue.main.async { [onDrop] in onDrop(window, zone.action, area, original) }
    }

    private func endDrag() {
        drag = nil
        hidePreview()
    }

    // MARK: Preview

    private func showPreview(_ frame: CGRect) {
        guard let rect = WindowAccess.appKitRect(frame) else { return }
        preview.show(rect)
        guard escapeMonitor == nil else { return }
        // Only while a preview is up: a global key monitor would otherwise run on every keystroke.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                self?.drag?.cancelled = true
                self?.hidePreview()
            }
        }
    }

    private func hidePreview() {
        preview.hide()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

/// The translucent outline showing where the dragged window would land. Never takes clicks or focus.
@MainActor
private final class WindowSnapPreview {
    private var panel: NSPanel?

    func show(_ rect: CGRect) {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrame(rect.insetBy(dx: 6, dy: 6), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 2
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        panel.contentView = view
        return panel
    }
}
