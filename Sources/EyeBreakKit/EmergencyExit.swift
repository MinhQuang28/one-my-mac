import Carbon.HIToolbox
import Foundation

/// The way out of the full-screen curtain that never depends on its buttons: Esc pressed three
/// times in a row. Esc is held as a system hot key only while the curtain is up, which needs no
/// permission and works although the curtain never becomes the key window.
@MainActor
final class EmergencyExit {
    static let presses = 3
    private static let window: TimeInterval = 2
    private static let signature: OSType = 0x4F4D_4542 // "OMEB"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var recent: [Date] = []
    private let onExit: () -> Void

    init(onExit: @escaping () -> Void) { self.onExit = onExit }

    func arm() {
        guard hotKey == nil else { return }
        recent = []
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Other hot keys of the app (window shortcuts) go on to their own handler.
            guard status == noErr, let context, id.signature == EmergencyExit.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon delivers hot keys on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<EmergencyExit>.fromOpaque(context).takeUnretainedValue().pressed()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    func disarm() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        recent = []
    }

    private func pressed() {
        let now = Date()
        recent = recent.filter { abs(now.timeIntervalSince($0)) <= Self.window } + [now]
        guard recent.count >= Self.presses else { return }
        recent = []
        onExit()
    }
}
