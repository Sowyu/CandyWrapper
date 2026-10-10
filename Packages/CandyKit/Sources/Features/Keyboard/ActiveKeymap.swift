import AppKit
import T3Protocol

/// The keybindings in effect: T3's defaults merged with the primary environment's resolved rules
/// (`primaryServerKeybindingsAtom`, web state/server.ts:109-111). The app sets `serverRules` from
/// `server.getConfig` and `subscribeServerConfig` `keybindingsUpdated`; until then the defaults apply.
@MainActor
public enum ActiveKeymap {
    public private(set) static var keymap = Keymap.default
    private static var observers: [UUID: @MainActor () -> Void] = [:]

    public static func setServerRules(_ rules: [ResolvedKeybindingRule]) {
        let next = Keymap.merged(withServer: rules)
        guard next != keymap else { return }
        keymap = next
        for observer in observers.values { observer() }
    }

    /// Calls `change` after every keymap change. Returns a token for `removeObserver`.
    @discardableResult
    public static func observe(_ change: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = change
        return id
    }

    public static func removeObserver(_ id: UUID) { observers[id] = nil }

    public static func resolve(_ event: NSEvent, context: KeybindingContext) -> String? {
        guard let stroke = KeyStroke(event) else { return nil }
        return keymap.resolve(stroke, context: context)
    }

    public static func label(for command: String, context: KeybindingContext = KeybindingContext()) -> String? {
        keymap.label(for: command, context: context)
    }
}

extension KeyStroke {
    /// An AppKit key-down as the browser's `KeyboardEvent` would report it: `key` from the typed
    /// character (Shift applies, Option and Command don't), `code` from the ANSI key position.
    public init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        if let special = Self.specialKeys[event.keyCode] {
            key = special
        } else if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            key = chars
        } else {
            return nil
        }
        self.init(key: key, physicalKey: Self.physicalKeys[event.keyCode], meta: flags.contains(.command), ctrl: flags.contains(.control),
                  shift: flags.contains(.shift), alt: flags.contains(.option), isRepeat: event.isARepeat)
    }

    /// Named keys (`KeyboardEvent.key`, lowercased by `normalizeEventKey`).
    static let specialKeys: [UInt16: String] = [
        36: "enter", 76: "enter", 53: "escape", 48: "tab", 49: " ", 51: "backspace", 117: "delete",
        123: "arrowleft", 124: "arrowright", 125: "arrowdown", 126: "arrowup",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    ]

    /// `EVENT_CODE_SHORTCUT_KEYS` (shared keybindings.ts:32-54) plus `KeyA`-`KeyZ`, by ANSI key code.
    static let physicalKeys: [UInt16: String] = [
        50: "`", 42: "\\", 33: "[", 30: "]", 43: ",", 24: "=", 27: "-", 47: ".", 39: "'", 41: ";", 44: "/",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]
}
