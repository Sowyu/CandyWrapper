import Foundation
import Testing
@testable import T3Protocol

/// Ported from packages/shared/src/keybindings.test.ts and apps/web/src/keybindings.test.ts.
@Suite struct KeybindingsTests {
    let keymap = Keymap.default

    func cmd(_ key: String, shift: Bool = false, alt: Bool = false, physical: String? = nil) -> KeyStroke {
        KeyStroke(key: key, physicalKey: physical, meta: true, shift: shift, alt: alt)
    }

    @Test func parsesShortcuts() {
        #expect(KeybindingShortcut.parse("mod+shift+d") == KeybindingShortcut(key: "d", shiftKey: true, modKey: true))
        #expect(KeybindingShortcut.parse("mod++") == KeybindingShortcut(key: "+", modKey: true))
        #expect(KeybindingShortcut.parse("ctrl+space") == KeybindingShortcut(key: " ", ctrlKey: true))
        #expect(KeybindingShortcut.parse("cmd+option+esc") == KeybindingShortcut(key: "escape", metaKey: true, altKey: true))
        #expect(KeybindingShortcut.parse("mod+a+b") == nil)
        #expect(KeybindingShortcut.parse("mod+shift") == nil)
        #expect(KeybindingShortcut.parse("mod++x") == nil)
    }

    @Test func parsesWhenExpressions() {
        #expect(KeybindingWhenNode.parse("!terminalFocus") == .not(.identifier("terminalFocus")))
        #expect(KeybindingWhenNode.parse("a && b || c") == .or(.and(.identifier("a"), .identifier("b")), .identifier("c")))
        #expect(KeybindingWhenNode.parse("a && (b || !c)") == .and(.identifier("a"), .or(.identifier("b"), .not(.identifier("c")))))
        #expect(KeybindingWhenNode.parse("a &&") == nil)
        #expect(KeybindingWhenNode.parse("(a") == nil)
        #expect(KeybindingWhenNode.parse("a $ b") == nil)
        #expect(KeybindingWhenNode.parse("") == nil)
    }

    @Test func evaluatesUnknownKeysAsFalse() {
        let ctx = KeybindingContext(["terminalFocus": false])
        #expect(KeybindingWhenNode.parse("unknownKey")?.evaluate(ctx) == false)
        #expect(KeybindingWhenNode.parse("isDesktop && !isWeb")?.evaluate(ctx) == true)
        #expect(KeybindingWhenNode.parse("true")?.evaluate(ctx) == true)
    }

    @Test func resolvesDefaults() {
        let ctx = KeybindingContext()
        #expect(keymap.resolve(cmd("k"), context: ctx) == "commandPalette.toggle")
        #expect(keymap.resolve(cmd("d"), context: ctx) == "diff.toggle")
        #expect(keymap.resolve(cmd("d"), context: KeybindingContext(["terminalFocus": true])) == "terminal.split")
        #expect(keymap.resolve(cmd("n"), context: ctx) == "chat.new")
        #expect(keymap.resolve(cmd("1"), context: ctx) == "thread.jump.1")
        #expect(keymap.resolve(cmd("1"), context: KeybindingContext(["modelPickerOpen": true])) == "modelPicker.jump.1")
        #expect(keymap.resolve(cmd("z"), context: KeybindingContext(["editableFocus": true])) == nil)
        #expect(keymap.resolve(KeyStroke(key: "k"), context: ctx) == nil)
        // Extra modifiers never match a shorter chord.
        #expect(keymap.resolve(cmd("k", alt: true), context: ctx) == nil)
    }

    @Test func shiftedPunctuationUsesThePhysicalKey() {
        // Shift+[ types "{" on a US layout; `event.code` BracketLeft maps back to "[".
        #expect(keymap.resolve(cmd("{", shift: true, physical: "["), context: KeybindingContext()) == "thread.previous")
        #expect(keymap.resolve(cmd("}", shift: true, physical: "]"), context: KeybindingContext()) == "thread.next")
        #expect(keymap.resolve(cmd("[", physical: "["), context: KeybindingContext()) == "navigation.back")
    }

    @Test func optionLettersUseTheLetterKey() {
        // Option+A types "å"; the letter code still matches `mod+alt+a`.
        #expect(keymap.resolve(cmd("å", alt: true, physical: "a"), context: KeybindingContext()) == "theme.select")
    }

    @Test func lastMatchingRuleWins() {
        var rules = Keymap.defaultRules
        rules.append(ResolvedKeybindingRule(key: "mod+k", command: "chat.new")!)
        let map = Keymap(rules: rules)
        #expect(map.resolve(cmd("k"), context: KeybindingContext()) == "chat.new")
        #expect(map.label(for: "commandPalette.toggle") == nil)
        #expect(map.label(for: "chat.new") == "⌘K")
    }

    @Test func serverRulesReplaceDefaultsPerCommand() {
        let custom = [ResolvedKeybindingRule(key: "mod+g", command: "terminal.toggle")!]
        let map = Keymap.merged(withServer: custom)
        #expect(map.resolve(cmd("j"), context: KeybindingContext()) == nil)
        #expect(map.resolve(cmd("g"), context: KeybindingContext()) == "terminal.toggle")
        #expect(map.resolve(cmd("k"), context: KeybindingContext()) == "commandPalette.toggle")
        #expect(Keymap.merged(withServer: []) == Keymap.default)
    }

    @Test func labels() {
        #expect(keymap.label(for: "chat.new") == "⇧⌘O")
        #expect(keymap.label(for: "appearance.cycle") == "⌥⇧⌘A")
        #expect(keymap.label(for: "chat.newWithoutProject") == "⌥⌘N")
        #expect(keymap.label(for: "modelPicker.previousProvider", context: KeybindingContext(["modelPickerOpen": true])) == "⇧⌘Up")
        #expect(keymap.label(for: "thread.stop") == nil)
    }

    @Test func decodesTheServersResolvedConfig() throws {
        let json = try JSONValue(parsing: Data("""
        [{"command":"navigation.back","shortcut":{"altKey":false,"ctrlKey":false,"key":"[","metaKey":false,"modKey":true,"shiftKey":false},
          "whenAst":{"node":{"name":"terminalFocus","type":"identifier"},"type":"not"}},
         {"command":"future.command","shortcut":{"key":"x"},"whenAst":{"type":"xor"}},
         {"command":"chat.new","shortcut":{"altKey":false,"ctrlKey":false,"key":"n","metaKey":false,"modKey":true,"shiftKey":false}}]
        """.utf8))
        let rules = Keymap.decodeRules(json)
        #expect(rules.map(\.command) == ["navigation.back", "chat.new"])
        #expect(rules[0].whenAst == .not(.identifier("terminalFocus")))
    }

    @Test func recordedConfigMatchesOurDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("fixtures/transcripts/01-basic.jsonl"), encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"whenAst\"") }) else { Issue.record("no config"); return }
        let record = try JSONValue(parsing: Data(line.utf8))
        func find(_ v: JSONValue) -> JSONValue? {
            switch v {
            case .object(let o): if let k = o["keybindings"] { return k }; return o.values.lazy.compactMap(find).first
            case .array(let a): return a.lazy.compactMap(find).first
            default: return nil
            }
        }
        let rules = Keymap.decodeRules(find(record))
        #expect(!rules.isEmpty)
        // Every rule the recorded server sends (its version's defaults) is one of ours.
        let ours = Set(Keymap.defaultRules)
        let missing = rules.filter { !ours.contains($0) }.map(\.command)
        #expect(missing.isEmpty, "server rules not in DEFAULT_KEYBINDINGS: \(missing)")
    }
}
