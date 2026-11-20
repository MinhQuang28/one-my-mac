import AppKit
import ApplicationServices

/// AXUIElement as a dictionary key: two references to the same window compare equal.
struct WindowKey: Hashable {
    let element: AXUIElement
    static func == (a: Self, b: Self) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Reading and writing other apps' windows through the Accessibility API, and the displays they
/// live on. Every rectangle is in Accessibility coordinates (top-left origin, y growing downwards).
@MainActor
enum WindowAccess {
    /// One display: its full frame (to find which display a window is on) and its usable area.
    struct Display {
        let frame: CGRect
        let visible: CGRect
    }

    /// screens[0] is the display with the menu bar; AX measures y down from its top edge.
    private static var primaryHeight: CGFloat? { NSScreen.screens.first?.frame.height }

    /// Displays left to right (top to bottom for ties).
    static func displays() -> [Display] {
        guard let primaryHeight else { return [] }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens
            .sorted { ($0.frame.minX, -$0.frame.minY) < ($1.frame.minX, -$1.frame.minY) }
            .map { Display(frame: flipped($0.frame), visible: flipped($0.visibleFrame)) }
    }

    /// The pointer, in Accessibility coordinates.
    static func pointer() -> CGPoint? {
        guard let primaryHeight else { return nil }
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }

    /// An Accessibility rectangle in AppKit's bottom-left screen coordinates.
    static func appKitRect(_ rect: CGRect) -> CGRect? {
        guard let primaryHeight else { return nil }
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The focused window of the frontmost app; nil when there is none, the app does not answer in
    /// time, or the window is in native full screen.
    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1) // a hung app must not freeze the hotkey
        guard let window = copy(element, kAXFocusedWindowAttribute) ?? (copy(element, kAXWindowsAttribute) as? [AXUIElement])?.first,
              CFGetTypeID(window as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        let axWindow = window as! AXUIElement
        // A native full-screen window owns its Space; moving it only breaks the layout.
        if (copy(axWindow, "AXFullScreen") as? Bool) == true { return nil }
        return axWindow
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = copy(window, kAXPositionAttribute), let size = copy(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        let rect = CGRect(origin: origin, size: extent)
        return WindowLayout.isValid(rect) ? rect : nil
    }

    /// Writes size, then position, then size again: an app limits a new size to the display the
    /// window is on at that moment, so the second size write is what takes once it has moved.
    static func write(_ rect: CGRect, to window: AXUIElement) {
        var extent = rect.size
        guard let size = AXValueCreate(.cgSize, &extent) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
        setPosition(rect.origin, of: window)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
    }

    static func setPosition(_ origin: CGPoint, of window: AXUIElement) {
        var origin = origin
        guard let position = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }
}
