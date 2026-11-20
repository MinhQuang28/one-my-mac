import Carbon.HIToolbox

/// Registers the shortcuts with the system hot-key service: no event tap and no key-by-key
/// filtering in this process — the system calls back only when one of them is pressed.
@MainActor
final class WindowHotkeys {
    private static let signature: OSType = 0x4F4D_574E // "OMWN"
    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let onPress: (WindowAction) -> Void

    init(onPress: @escaping (WindowAction) -> Void) { self.onPress = onPress }

    /// Registers every bound shortcut; returns the actions whose shortcut the system refused.
    /// (macOS accepts a combination another app has also registered, so this does not detect
    /// every clash with other apps.)
    func register(_ bindings: WindowShortcutBindings) -> Set<WindowAction> {
        unregister()
        installHandler()
        var taken: Set<WindowAction> = []
        for (index, action) in WindowAction.allCases.enumerated() {
            guard let shortcut = bindings.shortcut(for: action) else { continue }
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
