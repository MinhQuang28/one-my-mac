import AppKit
import Carbon.HIToolbox
import OneMacUI
import SwiftUI

/// Something that can be done with the selected item, in the order the Actions menu lists them.
enum ClipboardAction: CaseIterable, Identifiable {
    case paste, copy, open, pin, delete

    var id: Self { self }

    var keys: String {
        switch self {
        case .paste: return "↩"
        case .copy: return "⌘↩"
        case .open: return "⌘O"
        case .pin: return "⌘P"
        case .delete: return "⌘⌫"
        }
    }

    var icon: String {
        switch self {
        case .paste: return "arrow.down.doc"
        case .copy: return "doc.on.doc"
        case .open: return "arrow.up.forward.square"
        case .pin: return "pin"
        case .delete: return "trash"
        }
    }

    func title(for item: ClipboardItem, target: String?) -> String {
        switch self {
        case .paste: return target.map { tr("Paste to \($0)", "Dán vào \($0)") } ?? tr("Paste", "Dán")
        case .copy: return tr("Copy to Clipboard", "Sao chép vào clipboard")
        case .open:
            switch item.kind {
            case .file: return tr("Show in Finder", "Hiện trong Finder")
            case .link: return tr("Open in Browser", "Mở trong trình duyệt")
            case .email: return tr("Write an E-mail", "Soạn email")
            case .image, .text: return tr("Open", "Mở")
            }
        case .pin: return item.isPinned ? tr("Unpin", "Bỏ ghim") : tr("Pin", "Ghim")
        case .delete: return tr("Delete", "Xoá")
        }
    }

    /// Plain text has nothing to open.
    static func available(for item: ClipboardItem) -> [ClipboardAction] {
        allCases.filter { $0 != .open || item.kind != .text }
    }
}

/// What the window shows: the search, the type filter, the selected row and the Actions menu.
@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    /// nil shows every kind.
    @Published var kind: ClipboardKind? {
        didSet { if kind != oldValue { selection = 0 } }
    }
    @Published var selection = 0
    @Published var actionsOpen = false
    @Published var actionSelection = 0
    /// Name of the app the chosen item will be pasted into.
    @Published var targetApp: String?
}

/// The floating history window.
///
/// A non-activating panel that can still become key: the search field takes typing while the app
/// the user was working in stays in front — which is what lets the chosen item be pasted into it.
@MainActor
final class ClipboardPanel: NSObject, NSWindowDelegate {
    private static let size = ClipboardPanelMetrics.window

    private unowned let history: ClipboardHistory
    private let model = ClipboardPanelModel()
    private var panel: KeyPanel?
    private var keyMonitor: Any?

    init(history: ClipboardHistory) { self.history = history }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.query = ""
        model.kind = nil
        model.selection = 0
        model.actionsOpen = false
        let front = NSWorkspace.shared.frontmostApplication
        model.targetApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front?.localizedName

        // On the screen the pointer is on, a little above centre like Spotlight.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                         y: frame.midY - Self.size.height / 2 + frame.height * 0.06))
        }
        panel.makeKeyAndOrderFront(nil)

        // Arrow keys, Return and Escape are handled here rather than in SwiftUI: the focused text
        // field would otherwise use the arrows itself.
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
    }

    /// Clicking anywhere else dismisses it, like a menu.
    func windowDidResignKey(_ notification: Notification) { close() }

    /// Runs an action on an item, from a key press or a click in the Actions menu.
    func perform(_ action: ClipboardAction, on item: ClipboardItem) {
        model.actionsOpen = false
        switch action {
        case .paste: history.paste(item)
        case .copy: history.copy(item)
        case .open: history.open(item)
        case .pin: history.togglePin(item)
        case .delete:
            history.remove(item)
            let count = history.store.matching(model.query, kind: model.kind).count
            model.selection = min(model.selection, max(count - 1, 0))
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let results = history.store.matching(model.query, kind: model.kind)
        let selected = results.indices.contains(model.selection) ? results[model.selection] : nil
        let command = event.modifierFlags.contains(.command)
        let key = Int(event.keyCode)

        if key == kVK_ANSI_K, command {
            model.actionSelection = 0
            model.actionsOpen = selected != nil && !model.actionsOpen
            return true
        }
        if model.actionsOpen, let selected {
            let actions = ClipboardAction.available(for: selected)
            switch key {
            case kVK_Escape: model.actionsOpen = false
            case kVK_DownArrow: model.actionSelection = min(model.actionSelection + 1, actions.count - 1)
            case kVK_UpArrow: model.actionSelection = max(model.actionSelection - 1, 0)
            case kVK_Return, kVK_ANSI_KeypadEnter: perform(actions[min(model.actionSelection, actions.count - 1)], on: selected)
            default: break
            }
            return true // the menu is modal: nothing reaches the search field behind it
        }

        switch key {
        case kVK_Escape:
            close()
        case kVK_DownArrow:
            model.selection = min(model.selection + 1, max(results.count - 1, 0))
        case kVK_UpArrow:
            model.selection = max(model.selection - 1, 0)
        case kVK_Tab:
            // Tab steps through the type filter; Shift-Tab goes back.
            let order: [ClipboardKind?] = [nil] + ClipboardKind.allCases.map { $0 }
            let index = order.firstIndex(of: model.kind) ?? 0
            let step = event.modifierFlags.contains(.shift) ? order.count - 1 : 1
            model.kind = order[(index + step) % order.count]
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selected { perform(command ? .copy : .paste, on: selected) }
        case kVK_ANSI_P where command:
            if let selected { perform(.pin, on: selected) }
        case kVK_ANSI_O where command:
            if let selected, selected.kind != .text { perform(.open, on: selected) }
        case kVK_Delete where command:
            if let selected { perform(.delete, on: selected) }
        default:
            return false
        }
        return true
    }

    private func makePanel() -> KeyPanel {
        // Borderless and clear: the glass, its large corner radius and its shadow are all drawn by
        // the SwiftUI content, which a titled window's own frame would fight.
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Dark for the AppKit-backed parts too: the search field's caret and the type menu.
        panel.appearance = NSAppearance(named: .darkAqua)
        // Not movable by its background: the window server then holds every click for a moment to
        // see whether it becomes a drag, which made the list feel slow.
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ClipboardPanelView(
            history: history, model: model, perform: { [weak self] in self?.perform($0, on: $1) }))
        return panel
    }
}

/// A borderless-style panel refuses key status by default; the search field needs it.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
