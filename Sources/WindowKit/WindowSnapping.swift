import AppKit
import OneMacUI

/// Window snapping: the switches, the shortcut bindings and the entry point every trigger (shortcut,
/// mouse button, drag to an edge) goes through. Costs nothing while idle — nothing polls; drag
/// snapping, when on, only listens to left-button drags.
@MainActor
public final class WindowSnapping: ObservableObject {
    public static let shared = WindowSnapping()
    private static let enabledKey = "window_shortcuts_enabled"
    private static let bindingsKey = "window_shortcut_bindings"
    private static let dragSnapKey = "window_drag_snap_enabled"
    private static let cycleKey = "window_cycle_sizes"

    /// Keyboard shortcuts on/off. Mouse-button mappings work either way.
    @Published public var shortcutsEnabled: Bool {
        didSet {
            guard shortcutsEnabled != oldValue else { return }
            UserDefaults.standard.set(shortcutsEnabled, forKey: Self.enabledKey)
            if shortcutsEnabled { requestAccessibilityIfNeeded() }
            applyShortcuts()
        }
    }
    /// Dragging a window to a screen edge snaps it. Off unless the user turns it on.
    @Published public var dragSnapEnabled: Bool {
        didSet {
            guard dragSnapEnabled != oldValue else { return }
            UserDefaults.standard.set(dragSnapEnabled, forKey: Self.dragSnapKey)
            if dragSnapEnabled { requestAccessibilityIfNeeded() }
            applyDragSnap()
        }
    }
    /// Pressing Left Half / Right Half again walks through 1/2 → 2/3 → 1/3.
    @Published public var cycleSizes: Bool {
        didSet { UserDefaults.standard.set(cycleSizes, forKey: Self.cycleKey) }
    }
    /// Actions whose shortcut the system refused to register.
    @Published public private(set) var unavailable: Set<WindowAction> = []
    @Published private(set) var bindings: WindowShortcutBindings

    private let mover = WindowMover()
    private lazy var hotkeys = WindowHotkeys { [weak self] action in self?.perform(action) }
    private lazy var dragSnapper = WindowDragSnapper { [weak self] window, action, area, original in
        self?.mover.place(window, action: action, in: area, original: original)
    }
    private var started = false
    /// While a shortcut is being recorded the hot keys are released, so pressing one records it
    /// instead of moving a window.
    private var recording = false
    private var promptedForAccessibility = false

    private init() {
        let defaults = UserDefaults.standard
        shortcutsEnabled = defaults.bool(forKey: Self.enabledKey)
        dragSnapEnabled = defaults.bool(forKey: Self.dragSnapKey)
        cycleSizes = defaults.object(forKey: Self.cycleKey) as? Bool ?? true
        bindings = WindowShortcutBindings(stored: defaults.dictionary(forKey: Self.bindingsKey) as? [String: String] ?? [:])
    }

    public func start() {
        started = true
        applyShortcuts()
        applyDragSnap()
    }

    public func stop() {
        guard started else { return }
        hotkeys.unregister()
        dragSnapper.stop()
    }

    /// Applies `action` to the focused window; beeps when it cannot (no permission, no window, a
    /// full-screen window, an app that does not answer, nothing to restore).
    public func perform(_ action: WindowAction) {
        guard AXIsProcessTrusted() else {
            requestAccessibilityIfNeeded()
            NSSound.beep()
            return
        }
        if !mover.perform(action, cycle: cycleSizes) { NSSound.beep() }
    }

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// True when something that is switched on cannot work until Accessibility is granted.
    public var needsAccessibility: Bool { (shortcutsEnabled || dragSnapEnabled) && !AXIsProcessTrusted() }

    /// Number of actions that currently have a working shortcut.
    public var activeShortcutCount: Int {
        guard shortcutsEnabled else { return 0 }
        return WindowAction.allCases.filter { bindings.shortcut(for: $0) != nil && !unavailable.contains($0) }.count
    }

    /// Shows the system's Accessibility prompt, once per launch (macOS itself shows it only once).
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted(), !promptedForAccessibility else { return }
        promptedForAccessibility = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Shortcuts

    /// Key caps for the action's shortcut; empty when it has none.
    public func keyCaps(for action: WindowAction) -> [String] { bindings.shortcut(for: action)?.keyCaps ?? [] }

    func isDefaultShortcut(_ action: WindowAction) -> Bool {
        bindings.shortcut(for: action) == WindowShortcut.default(for: action)
    }

    var shortcutsAreCustomized: Bool { bindings.isCustomized }

    /// Gives `action` a shortcut (nil removes it). Returns the action already using those keys when
    /// the change was refused.
    func assign(_ shortcut: WindowShortcut?, to action: WindowAction) -> WindowAction? {
        var updated = bindings
        if let other = updated.assign(shortcut, to: action) { return other }
        setBindings(updated)
        return nil
    }

    func resetShortcut(_ action: WindowAction) -> WindowAction? {
        assign(WindowShortcut.default(for: action), to: action)
    }

    func resetAllShortcuts() { setBindings(WindowShortcutBindings()) }

    func setRecording(_ recording: Bool) {
        guard self.recording != recording else { return }
        self.recording = recording
        applyShortcuts()
    }

    private func setBindings(_ updated: WindowShortcutBindings) {
        bindings = updated
        if updated.isCustomized {
            UserDefaults.standard.set(updated.stored, forKey: Self.bindingsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bindingsKey)
        }
        applyShortcuts()
    }

    private func applyShortcuts() {
        guard started else { return }
        if shortcutsEnabled, !recording {
            unavailable = hotkeys.register(bindings)
        } else {
            hotkeys.unregister()
            if !shortcutsEnabled { unavailable = [] }
        }
    }

    private func applyDragSnap() {
        guard started else { return }
        if dragSnapEnabled { dragSnapper.start() } else { dragSnapper.stop() }
    }
}
