import Carbon.HIToolbox
import WindowKit

/// The shortcut that opens the history when the user has not recorded one, and the reading of what
/// earlier versions stored.
enum ClipboardShortcutDefaults {
    static let standard = WindowShortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)

    /// Earlier versions offered three fixed combinations and stored their names.
    private static let legacy: [String: WindowShortcut] = [
        "commandShiftV": standard,
        "optionCommandV": WindowShortcut(keyCode: kVK_ANSI_V, modifiers: optionKey | cmdKey),
        "controlOptionV": WindowShortcut(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey),
    ]

    static func shortcut(stored: String?) -> WindowShortcut {
        guard let stored else { return standard }
        return WindowShortcut(stored: stored) ?? legacy[stored] ?? standard
    }
}

/// Registers the one shortcut with the system hot-key service — no event tap, no permission.
@MainActor
final class ClipboardHotkey {
    private static let signature: OSType = 0x4F4D_4342 // "OMCB"
    private var registered: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) { self.onPress = onPress }

    /// - Returns: false when the system refused the combination.
    @discardableResult
    func register(_ shortcut: WindowShortcut) -> Bool {
        unregister()
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr ? ref : nil
        return registered != nil
    }

    func unregister() {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Not ours: the window shortcuts share the same event target.
            guard status == noErr, let context, id.signature == ClipboardHotkey.signature
            else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers hot keys on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<ClipboardHotkey>.fromOpaque(context).takeUnretainedValue().onPress()
            }
            return noErr
        }, 1, &spec, context, &handler)
    }
}
