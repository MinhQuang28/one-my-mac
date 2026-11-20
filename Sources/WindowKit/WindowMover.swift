import AppKit
import ApplicationServices

/// Moves and resizes the focused window of the frontmost app through the Accessibility API.
@MainActor
final class WindowMover {
    /// When to look at the window again after writing its frame: some apps apply it late or animate.
    private static let settleDelays: [TimeInterval] = [0.1, 0.45]

    private var memory = WindowRestoreMemory<WindowKey>()
    /// Bumped by every action, so a pending check from an older action can tell it was superseded.
    private var generation: UInt64 = 0

    /// Applies `action` to the focused window. False when there was nothing to do it to (no window,
    /// full screen, the app did not answer, nothing to restore, a single display).
    func perform(_ action: WindowAction, cycle: Bool) -> Bool {
        guard AXIsProcessTrusted(), let window = WindowAccess.focusedWindow(),
              let current = WindowAccess.frame(of: window) else { return false }
        let displays = WindowAccess.displays()
        guard let index = WindowLayout.displayIndex(containing: current, displays: displays.map(\.frame)) else { return false }
        let visible = displays[index].visible
        let key = WindowKey(element: window)

        let target: CGRect
        var area = visible
        switch action {
        case .restore:
            guard let saved = memory.takeSavedFrame(for: key, current: current) else { return false }
            // Its old display may be gone: land on whichever usable area it overlaps most.
            let areas = displays.map(\.visible)
            let home = WindowLayout.displayIndex(containing: saved, displays: areas).map { areas[$0] } ?? visible
            move(window, to: WindowLayout.fit(saved, into: home), in: home, key: key, remember: false)
            return true
        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else { return false }
            let offset = action == .nextDisplay ? 1 : -1
            area = displays[(index + offset + displays.count) % displays.count].visible
            target = WindowLayout.transfer(window: current, from: visible, to: area)
        default:
            target = cycle ? WindowLayout.cycledFrame(for: action, in: visible, current: current)
                           : WindowLayout.frame(for: action, in: visible, current: current)
        }
        memory.willArrange(key, from: current)
        move(window, to: target, in: area, key: key, remember: true)
        return true
    }

    /// Snaps a window the user just dropped on a screen edge. `original` is the frame it had before
    /// the drag began — that, not the mid-drag position, is what Restore should bring back.
    func place(_ window: AXUIElement, action: WindowAction, in visible: CGRect, original: CGRect) {
        let key = WindowKey(element: window)
        memory.willArrange(key, from: original)
        move(window, to: WindowLayout.frame(for: action, in: visible, current: original), in: visible,
             key: key, remember: true)
    }

    /// Moves the window, then looks again after the app had time to react (some animate or apply the
    /// frame late): writes it once more if it did not stick, and slides a window that came out larger
    /// than asked back onto `area`.
    private func move(_ window: AXUIElement, to rect: CGRect, in area: CGRect, key: WindowKey, remember: Bool) {
        generation &+= 1
        let mine = generation
        WindowAccess.write(rect, to: window)
        // The app kept a larger size: asking for the same frame again would only undo the slide.
        let clamped = keepOnDisplay(window, area: area)
        // Record where it really landed, so a quick follow-up action does not mistake the
        // difference for a manual move.
        if remember { memory.didArrange(key, target: rect, at: WindowAccess.frame(of: window) ?? rect) }
        for (pass, delay) in Self.settleDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // A held button means the user is already dragging the window somewhere else.
                guard let self, self.generation == mine, NSEvent.pressedMouseButtons & 1 == 0,
                      let actual = WindowAccess.frame(of: window) else { return }
                if pass == 0, !clamped, !WindowLayout.matches(actual, rect, slack: 2) { WindowAccess.write(rect, to: window) }
                self.keepOnDisplay(window, area: area)
                if remember, let settled = WindowAccess.frame(of: window) {
                    self.memory.didArrange(key, target: rect, at: settled)
                }
            }
        }
    }

    /// True when the window overhung `area` and was slid back.
    @discardableResult
    private func keepOnDisplay(_ window: AXUIElement, area: CGRect) -> Bool {
        guard let actual = WindowAccess.frame(of: window),
              let origin = WindowLayout.originKeepingOnDisplay(actual, in: area) else { return false }
        WindowAccess.setPosition(origin, of: window)
        return true
    }
}
