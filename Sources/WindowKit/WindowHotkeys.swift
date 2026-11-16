import Carbon.HIToolbox

/// A global keyboard shortcut: virtual key code plus Carbon modifier flags.
struct WindowShortcut: Equatable {
    let keyCode: Int
    let modifiers: Int

    private static let keyNames: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_Delete: "⌫", kVK_ANSI_U: "U", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_C: "C",
    ]

    /// Key caps in the order macOS prints them: ⌃⌥⇧⌘ then the key.
    var keyCaps: [String] {
        var caps: [String] = []
        if modifiers & controlKey != 0 { caps.append("⌃") }
        if modifiers & optionKey != 0 { caps.append("⌥") }
        if modifiers & shiftKey != 0 { caps.append("⇧") }
        if modifiers & cmdKey != 0 { caps.append("⌘") }
        return caps + [Self.keyNames[keyCode] ?? "?"]
    }

    /// The defaults follow Rectangle, so muscle memory carries over.
    static func `default`(for action: WindowAction) -> WindowShortcut {
        let base = controlKey | optionKey
        switch action {
        case .leftHalf: return .init(keyCode: kVK_LeftArrow, modifiers: base)
        case .rightHalf: return .init(keyCode: kVK_RightArrow, modifiers: base)
        case .topHalf: return .init(keyCode: kVK_UpArrow, modifiers: base)
        case .bottomHalf: return .init(keyCode: kVK_DownArrow, modifiers: base)
        case .topLeft: return .init(keyCode: kVK_ANSI_U, modifiers: base)
        case .topRight: return .init(keyCode: kVK_ANSI_I, modifiers: base)
        case .bottomLeft: return .init(keyCode: kVK_ANSI_J, modifiers: base)
        case .bottomRight: return .init(keyCode: kVK_ANSI_K, modifiers: base)
        case .maximize: return .init(keyCode: kVK_Return, modifiers: base)
        case .center: return .init(keyCode: kVK_ANSI_C, modifiers: base)
        case .restore: return .init(keyCode: kVK_Delete, modifiers: base)
        case .nextDisplay: return .init(keyCode: kVK_RightArrow, modifiers: base | cmdKey)
        case .previousDisplay: return .init(keyCode: kVK_LeftArrow, modifiers: base | cmdKey)
        }
    }
}

/// Registers the shortcuts with the system hot-key service: no event tap and no key-by-key
/// filtering in this process — the system calls back only when one of them is pressed.
@MainActor
final class WindowHotkeys {
    private static let signature: OSType = 0x4F4D_574E // "OMWN"
    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let onPress: (WindowAction) -> Void

    init(onPress: @escaping (WindowAction) -> Void) { self.onPress = onPress }

    /// Registers every shortcut; returns the actions whose shortcut another app already holds.
    func register() -> Set<WindowAction> {
        unregister()
        installHandler()
        var taken: Set<WindowAction> = []
        for (index, action) in WindowAction.allCases.enumerated() {
            let shortcut = WindowShortcut.default(for: action)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers),
                                             EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered.append(ref) } else { taken.insert(action) }
        }
        return taken
    }

    func unregister() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
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
            guard status == noErr, let context, id.signature == WindowHotkeys.signature,
                  Int(id.id) < WindowAction.allCases.count else { return OSStatus(eventNotHandledErr) }
            let action = WindowAction.allCases[Int(id.id)]
            // Carbon delivers hot keys on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<WindowHotkeys>.fromOpaque(context).takeUnretainedValue().onPress(action)
            }
            return noErr
        }, 1, &spec, context, &handler)
    }
}
