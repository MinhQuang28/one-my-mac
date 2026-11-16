import AppKit
import OneMacUI

/// Window snapping: the on/off switch for the keyboard shortcuts and the entry point every trigger
/// (shortcut, mouse button) goes through. Costs nothing while idle — nothing polls or observes.
@MainActor
public final class WindowSnapping: ObservableObject {
    public static let shared = WindowSnapping()
    private static let enabledKey = "window_shortcuts_enabled"

    /// Keyboard shortcuts on/off. Mouse-button mappings work either way.
    @Published public var shortcutsEnabled: Bool {
        didSet {
            guard shortcutsEnabled != oldValue else { return }
            UserDefaults.standard.set(shortcutsEnabled, forKey: Self.enabledKey)
            applyShortcuts()
        }
    }
    /// Actions whose shortcut is already held by another app (e.g. Rectangle).
    @Published public private(set) var unavailable: Set<WindowAction> = []

    private let mover = WindowMover()
    private lazy var hotkeys = WindowHotkeys { [weak self] action in self?.perform(action) }
    private var started = false

    private init() { shortcutsEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey) }

    public func start() {
        started = true
        applyShortcuts()
    }

    public func stop() {
        guard started else { return }
        hotkeys.unregister()
    }

    public func perform(_ action: WindowAction) { mover.perform(action) }

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public func keyCaps(for action: WindowAction) -> [String] { WindowShortcut.default(for: action).keyCaps }

    private func applyShortcuts() {
        guard started else { return }
        if shortcutsEnabled {
            unavailable = hotkeys.register()
        } else {
            hotkeys.unregister()
            unavailable = []
        }
    }
}
