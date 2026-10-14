import AppKit
import T3Protocol

/// App shortcuts that still work while a focused HTML render holds the keyboard (T3 3105 573cec016,
/// files/BrowserDocumentFrame.tsx `HTML_RENDER_SHORTCUT_COMMANDS` and its replay, packages/shared/src/htmlRender.ts
/// `t3/notifications/shortcuts` and `t3/notifications/keydown`). The page reports keys and a page script can report
/// anything, so only commands that change what the reader sees are here, never one that changes a thread.
@MainActor
public enum HtmlRenderShortcuts {
    static let commands: Set<String> = Set([
        "commandPalette.toggle", "filePicker.toggle", "projectSearch.toggle", "chat.find", "sidebar.toggle",
        "rightPanel.toggle", "rightPanel.toggleMaximized", "threadPanel.toggle", "terminal.toggle", "preview.toggle",
        "navigation.back", "navigation.forward", "thread.previous", "thread.next",
    ] + (1...9).map { "thread.jump.\($0)" } + (1...9).map { "modelPicker.jump.\($0)" })

    struct Chord: Hashable {
        var key: String, meta: Bool, ctrl: Bool, shift: Bool, alt: Bool
        init(_ s: KeybindingShortcut) { key = s.key; meta = s.meta; ctrl = s.ctrlKey; shift = s.shiftKey; alt = s.altKey }
        var json: JSONValue {
            .object(["key": .string(key), "metaKey": .bool(meta), "ctrlKey": .bool(ctrl), "shiftKey": .bool(shift), "altKey": .bool(alt)])
        }
        func matches(_ stroke: KeyStroke) -> Bool {
            stroke.meta == meta && stroke.ctrl == ctrl && stroke.shift == shift && stroke.alt == alt && stroke.candidateKeys.contains(key)
        }
    }

    /// The chords the page may pass on (allowed commands bound with Cmd or Ctrl, one per conflict key) and the chords
    /// of every other command, which the page keeps even when one also matches an allowed chord. Every rule counts
    /// whatever its `when`, since the app resolves the replayed key in its live context.
    static func chords(_ keymap: Keymap) -> (shortcuts: [Chord], blocked: [Chord]) {
        let blocked = keymap.rules.filter { !commands.contains($0.command) }.map { Chord($0.shortcut) }
        var seen = Set<String>(), shortcuts: [Chord] = []
        for rule in keymap.rules where commands.contains(rule.command) && (rule.shortcut.meta || rule.shortcut.ctrlKey) {
            if seen.insert(rule.shortcut.conflictKey).inserted { shortcuts.append(Chord(rule.shortcut)) }
        }
        return (shortcuts, blocked)
    }

    /// `htmlRenderShortcutsMessage`: posted into a render once it loads and whenever the keymap changes.
    public static func message(_ keymap: Keymap = ActiveKeymap.keymap) -> JSONValue {
        let (shortcuts, blocked) = chords(keymap)
        return .object(["jsonrpc": .string("2.0"), "method": .string("t3/notifications/shortcuts"),
                        "params": .object(["shortcuts": .array(shortcuts.map(\.json)), "blocked": .array(blocked.map(\.json))])])
    }

    /// `readHtmlRenderKeyDown` and `isShortcut`: the key a render passed on, when it is one of the chords posted to it
    /// and no other command's. A named key (Backspace, Enter) must be the shortcut's own; a dead key matches by code.
    public static func keyDown(_ data: JSONValue, keymap: Keymap = ActiveKeymap.keymap) -> KeyStroke? {
        guard data["jsonrpc"]?.stringValue == "2.0", data["method"]?.stringValue == "t3/notifications/keydown",
              let p = data["params"], let rawKey = p["key"]?.stringValue, let code = p["code"]?.stringValue else { return nil }
        let key = rawKey.lowercased() == "esc" ? "escape" : rawKey.lowercased()
        let letter = code.wholeMatch(of: /Key([A-Z])/).map { String($0.1).lowercased() }
        let physical = key.wholeMatch(of: /[a-z]/) != nil ? nil : (letter ?? codeKeys[code])
        let stroke = KeyStroke(key: key, physicalKey: physical, meta: p["metaKey"]?.boolValue == true, ctrl: p["ctrlKey"]?.boolValue == true,
                               shift: p["shiftKey"]?.boolValue == true, alt: p["altKey"]?.boolValue == true, isRepeat: p["repeat"]?.boolValue == true)
        let (shortcuts, blocked) = chords(keymap)
        let allowed = shortcuts.filter { $0.matches(stroke) }
        guard !allowed.isEmpty, !blocked.contains(where: { $0.matches(stroke) }),
              rawKey.count == 1 || rawKey == "Dead" || allowed.contains(where: { $0.key == key }) else { return nil }
        return stroke
    }

    /// `EVENT_CODE_SHORTCUT_KEYS` (packages/shared/src/keybindings.ts:32-54).
    static let codeKeys: [String: String] = [
        "Backquote": "`", "Backslash": "\\", "BracketLeft": "[", "BracketRight": "]", "Comma": ",", "Equal": "=", "Minus": "-",
        "Period": ".", "Quote": "'", "Semicolon": ";", "Slash": "/",
    ].merging((0...9).map { ("Digit\($0)", "\($0)") }) { a, _ in a }
}
