import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Shortcuts a focused HTML render passes back, and its modified links, against BrowserDocumentFrame.tsx and
/// htmlRender.ts in the 3105 tree.
@MainActor
struct HtmlRenderShortcutsTests {
    static func json(_ text: String) -> JSONValue { try! JSONValue(parsing: Data(text.utf8)) }
    static func key(_ key: String, _ code: String, meta: Bool = true, shift: Bool = false) -> JSONValue {
        json(#"{"jsonrpc":"2.0","method":"t3/notifications/keydown","params":{"key":"\#(key)","code":"\#(code)","metaKey":\#(meta),"ctrlKey":false,"shiftKey":\#(shift),"altKey":false,"repeat":false}}"#)
    }

    @Test func onlyViewCommandsWithCommandPassBack() {
        let keymap = Keymap(rules: [
            ResolvedKeybindingRule(key: "mod+k", command: "commandPalette.toggle")!,
            ResolvedKeybindingRule(key: "mod+b", command: "sidebar.toggle")!,
            ResolvedKeybindingRule(key: "mod+n", command: "chat.new")!,
            ResolvedKeybindingRule(key: "k", command: "sidebar.toggle")!,
            // Another command on an allowed chord keeps it with the page.
            ResolvedKeybindingRule(key: "mod+b", command: "thread.archive", when: "terminalFocus")!,
            ResolvedKeybindingRule(key: "mod+1", command: "thread.jump.1")!,
        ])
        #expect(HtmlRenderShortcuts.keyDown(Self.key("k", "KeyK"), keymap: keymap) == KeyStroke(key: "k", meta: true))
        #expect(HtmlRenderShortcuts.keyDown(Self.key("n", "KeyN"), keymap: keymap) == nil)
        #expect(HtmlRenderShortcuts.keyDown(Self.key("k", "KeyK", meta: false), keymap: keymap) == nil)
        #expect(HtmlRenderShortcuts.keyDown(Self.key("b", "KeyB"), keymap: keymap) == nil)
        // A digit matches by its code too (Shift+1 types "!").
        #expect(HtmlRenderShortcuts.keyDown(Self.key("1", "Digit1"), keymap: keymap) != nil)
        // A named key must be the shortcut's own.
        #expect(HtmlRenderShortcuts.keyDown(Self.key("Enter", "KeyK"), keymap: keymap) == nil)
        let message = HtmlRenderShortcuts.message(keymap)
        #expect(message["params"]?["shortcuts"]?.arrayValue?.count == 3)
        #expect(message["params"]?["blocked"]?.arrayValue?.count == 2)
    }

    @Test func modifiedLinkClicksLeaveForTheBrowser() {
        let plain = HtmlRenderTheme.linkRequest(Self.json(#"{"jsonrpc":"2.0","id":1,"method":"ui/open-link","params":{"url":"https://t3.codes"}}"#))
        let meta = HtmlRenderTheme.linkRequest(Self.json(#"{"jsonrpc":"2.0","id":1,"method":"ui/open-link","params":{"url":"https://t3.codes","metaKey":true}}"#))
        #expect(plain?.modified == false)
        #expect(meta?.modified == true)
    }
}
