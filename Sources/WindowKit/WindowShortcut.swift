import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: virtual key code plus Carbon modifier flags.
struct WindowShortcut: Hashable {
    let keyCode: Int
    let modifiers: Int

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press being recorded. Nil without ⌃, ⌥ or ⌘: a bare key (or ⇧ + key) as a global
    /// shortcut would take ordinary typing away from every app.
    init?(keyCode: Int, flags: NSEvent.ModifierFlags) {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    /// Key caps in the order macOS prints them: ⌃⌥⇧⌘ then the key.
    var keyCaps: [String] {
        var caps: [String] = []
        if modifiers & controlKey != 0 { caps.append("⌃") }
        if modifiers & optionKey != 0 { caps.append("⌥") }
        if modifiers & shiftKey != 0 { caps.append("⇧") }
        if modifiers & cmdKey != 0 { caps.append("⌘") }
        return caps + [KeyCapName.name(for: keyCode)]
    }

    // MARK: Persistence ("keyCode:modifiers")

    var stored: String { "\(keyCode):\(modifiers)" }

    init?(stored: String) {
        let parts = stored.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...0xFFFF).contains(parts[0]), parts[1] > 0 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    /// The defaults follow Rectangle, so muscle memory carries over. Actions added later start
    /// without a shortcut, so an update never takes more keys away from other apps.
    static func `default`(for action: WindowAction) -> WindowShortcut? {
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
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds, .almostMaximize: return nil
        }
    }
}

/// What to print on a key cap for a virtual key code.
enum KeyCapName {
    private static let special: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Tab: "⇥", kVK_Space: "␣", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// US-layout names for the default shortcuts, used only if the keyboard layout cannot be read.
    private static let fallback: [Int: String] = [
        kVK_ANSI_U: "U", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_C: "C",
    ]

    static func name(for keyCode: Int) -> String {
        special[keyCode] ?? layoutName(for: keyCode) ?? fallback[keyCode] ?? "?"
    }

    /// The character the key types on the current keyboard layout, without modifiers.
    private static func layoutName(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: characters, count: length).uppercased()
        let printable = name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) }
        return printable ? name : nil
    }
}

/// Which shortcut each action has. Only what differs from the defaults is stored: an action that is
/// absent uses its default, one stored as "" has had its shortcut removed.
struct WindowShortcutBindings: Equatable {
    private(set) var stored: [String: String]

    init(stored: [String: String] = [:]) { self.stored = stored }

    var isCustomized: Bool { !stored.isEmpty }

    func shortcut(for action: WindowAction) -> WindowShortcut? {
        guard let value = stored[action.rawValue] else { return WindowShortcut.default(for: action) }
        return WindowShortcut(stored: value)
    }

    /// The other action already using `shortcut`, if any.
    func owner(of shortcut: WindowShortcut, except action: WindowAction) -> WindowAction? {
        WindowAction.allCases.first { $0 != action && self.shortcut(for: $0) == shortcut }
    }

    /// Gives `action` a shortcut (nil removes it). Refused — returning the action that holds it —
    /// when another action already uses the same keys.
    @discardableResult
    mutating func assign(_ shortcut: WindowShortcut?, to action: WindowAction) -> WindowAction? {
        if let shortcut, let other = owner(of: shortcut, except: action) { return other }
        if shortcut == WindowShortcut.default(for: action) {
            stored[action.rawValue] = nil
        } else {
            stored[action.rawValue] = shortcut?.stored ?? ""
        }
        return nil
    }
}
