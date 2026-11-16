import AppKit
import ApplicationServices

/// Moves and resizes the focused window of the frontmost app through the Accessibility API.
@MainActor
final class WindowMover {
    /// AXUIElement as a dictionary key: two references to the same window compare equal.
    private struct WindowKey: Hashable {
        let element: AXUIElement
        static func == (a: Self, b: Self) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// One display: its full frame (to find which display a window is on) and its usable area.
    private struct Display {
        let frame: CGRect
        let visible: CGRect
    }

    private var memory = WindowRestoreMemory<WindowKey>()
    /// Bumped by every action, so a pending check from an older action can tell it was superseded.
    private var generation: UInt64 = 0

    func perform(_ action: WindowAction) {
        guard AXIsProcessTrusted(), let window = focusedWindow(), let current = frame(of: window) else { return }
        let displays = Self.displays()
        guard let index = WindowLayout.displayIndex(containing: current, displays: displays.map(\.frame)) else { return }
        let visible = displays[index].visible
        let key = WindowKey(element: window)

        let target: CGRect
        switch action {
        case .restore:
            guard let saved = memory.takeSavedFrame(for: key) else { return }
            // Its old display may be gone: land on whichever usable area it overlaps most.
            let areas = displays.map(\.visible)
            let home = WindowLayout.displayIndex(containing: saved, displays: areas).map { areas[$0] } ?? visible
            move(window, to: WindowLayout.fit(saved, into: home), key: key, remember: false)
            return
        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else { return }
            let offset = action == .nextDisplay ? 1 : -1
            let destination = displays[(index + offset + displays.count) % displays.count].visible
            target = WindowLayout.transfer(window: current, from: visible, to: destination)
        default:
            target = WindowLayout.frame(for: action, in: visible, current: current)
        }
        memory.willArrange(key, from: current)
        move(window, to: target, key: key, remember: true)
    }

    // MARK: Displays

    /// Displays left to right (top to bottom for ties), in Accessibility coordinates.
    private static func displays() -> [Display] {
        // screens[0] is the display with the menu bar; AX measures y down from its top edge.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens
            .sorted { ($0.frame.minX, -$0.frame.minY) < ($1.frame.minX, -$1.frame.minY) }
            .map { Display(frame: flipped($0.frame), visible: flipped($0.visibleFrame)) }
    }

    // MARK: Accessibility

    private func focusedWindow() -> AXUIElement? {
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

    private func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
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
    private func write(_ rect: CGRect, to window: AXUIElement) {
        var origin = rect.origin, extent = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let size = AXValueCreate(.cgSize, &extent) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
    }

    /// Moves the window, then looks once more after the app had time to react (some animate or
    /// apply the frame late) and writes it again if it did not stick.
    private func move(_ window: AXUIElement, to rect: CGRect, key: WindowKey, remember: Bool) {
        generation &+= 1
        let mine = generation
        write(rect, to: window)
        // Record where it really landed (an app may clamp the size), so a quick follow-up action
        // does not mistake the difference for a manual move.
        if remember { memory.didArrange(key, at: frame(of: window) ?? rect) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.generation == mine, let actual = self.frame(of: window) else { return }
            let off = abs(actual.minX - rect.minX) > 2 || abs(actual.minY - rect.minY) > 2
                || abs(actual.width - rect.width) > 2 || abs(actual.height - rect.height) > 2
            if off { self.write(rect, to: window) }
            if remember, let settled = self.frame(of: window) { self.memory.didArrange(key, at: settled) }
        }
    }
}
