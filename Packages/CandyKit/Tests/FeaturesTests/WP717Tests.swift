import AppKit
import Testing
import T3Protocol
import T3Store
import DesignSystem
@testable import Features

@MainActor
struct WP717Tests {
    @Test func selectionNormalizesOffsetsButKeepsQuoteWhitespace() throws {
        let text = "First  line\n\nNext 🌿 end"
        let source = text as NSString
        let range = source.range(of: " line\n\nNext 🌿")
        let selected = try #require(AssistantSelectionText.capture(text, range: range))
        #expect(selected.text == " line\n\nNext 🌿")
        #expect(selected.start == 5)
        #expect(selected.prefix == "First")
        #expect(selected.suffix == " end")
        let citation = ThreadAssistantCitation.selection(environmentId: "e", threadId: "t", messageId: "m", selection: selected)
        #expect(ThreadAssistantCitation.parse(citation.href) == citation)
        #expect(AssistantSelectionText.capture("  ", range: NSRange(location: 0, length: 2)) == nil)
        #expect(AssistantSelectionText.capture("🌿", range: NSRange(location: 0, length: 1)) == nil)
    }
    @Test func selectorContextDoesNotSplitEmoji() throws {
        let selected = try #require(AssistantSelectionText.capture("🌿" + String(repeating: "a", count: 31) + "Q" + String(repeating: "b", count: 31) + "🌿", range: NSRange(location: 33, length: 1)))
        #expect(selected.prefix == String(repeating: "a", count: 31))
        #expect(selected.suffix == String(repeating: "b", count: 31))
    }
    @Test func inlineSkillsRequireKnownNameAndSkipCodeLinksAndCurrency() {
        let skill = ServerProviderSkill(name: "audit", path: "/skills/audit", displayName: "Audit")
        let runs = MarkdownInlineSkills.runs([InlineRun(text: "$audit $20 £audit $unknown $audit,"), InlineRun(text: "$audit", code: true), InlineRun(text: "$audit", link: URL(string: "https://example.com"))], skills: [skill])
        #expect(runs.filter { $0.skillLabel == "Audit" }.count == 2)
        #expect(runs.last?.link != nil)
        #expect(MarkdownShellCommand.visible("\u{001b}[31m\tfoo\nbar\u{007f}") == "␛[31m\tfoo\nbar␡")
    }
    @Test func fileCommentUsesSelectedLinesAndSharedRecord() throws {
        let record = try #require(FileCommentContext.record(path: "src/main.swift", contents: "one\ntwo\nthree", selection: NSRange(location: 4, length: 4), text: " fix this ", id: "selection"))
        #expect(record["rangeLabel"]?.stringValue == "L2")
        #expect(record["diff"]?.stringValue == "two")
        #expect(record["text"]?.stringValue == "fix this")
        #expect(record["sectionId"]?.stringValue == "file:src/main.swift")
        #expect(record["fenceLanguage"]?.stringValue == "swift")
    }
    @Test func dropVerbsAndWireCommands() {
        #expect(SidebarReorderDropBadge.verb(from: .snoozed, to: .active) == "Wake")
        #expect(SidebarReorderDropBadge.verb(from: .settled, to: .active) == "Un-settle")
        #expect(SidebarReorderDropBadge.verb(from: .pinned, to: .pinned) == nil)
        #expect(SidebarReorderDropBadge.verb(from: .active, to: .working) == nil)
        #expect(ThreadCommands.reorder(ThreadId("t"), pinned: true, orderKey: "n", commandId: "c")["type"]?.stringValue == "thread.pin.reorder")
        #expect(ThreadCommands.reorder(ThreadId("t"), pinned: false, orderKey: "n", commandId: "c")["orderKey"]?.stringValue == "n")
    }
    @Test func reorderRepairsKeylessSectionsAndAvoidsHiddenKeys() {
        let a = ThreadId("a"), b = ThreadId("b"), hidden = ThreadId("hidden")
        let repaired = PinOrderKey.assignments(order: [b, a], keys: [:], moved: b)
        #expect(repaired.map(\.id) == [b, a])
        #expect(repaired.allSatisfy { PinOrderKey.between(nil, $0.key) != nil })
        #expect(repaired[0].key < repaired[1].key)
        let midpoint = PinOrderKey.between(nil, "z")!
        let inserted = PinOrderKey.assignments(order: [b, a], keys: [a: "z", hidden: midpoint], moved: b)
        #expect(inserted.count == 1)
        #expect(inserted[0].key != midpoint)
        #expect(inserted[0].key < "z")
    }
    @Test func publishedThemesAreTransient() throws {
        let defaults = UserDefaults(suiteName: "cw.wp717.tests.\(UUID().uuidString)")!
        let library = ThemeLibrary(defaults: defaults)
        let seeded: JSONValue = .object(["id": .string("published-test"), "name": .string("Published"), "appearance": .string("dark"), "canvas": .string("#101010"), "accent": .string("#3578ab")])
        library.setEnvironmentThemes([seeded])
        #expect(library.environmentThemes.count == 1)
        #expect(library.definition("published-test")?.managed == true)
        #expect(library.customThemes.isEmpty)
        let restored = ThemeLibrary(defaults: defaults)
        #expect(restored.environmentThemes.isEmpty)
        library.setEnvironmentThemes([])
        #expect(library.definition("published-test") == nil)
        let event = try JSONDecoder().decode(ServerConfigEvent.self, from: Data(#"{"version":1,"type":"environmentThemesUpdated","payload":{"themes":[]}}"#.utf8))
        guard case .environmentThemesUpdated(let themes) = event else { Issue.record("Wrong theme stream event"); return }
        #expect(themes.isEmpty)
    }
    @Test func vsCodeThemeImportCompositesAndSolvesTextContrast() throws {
        let value: [String: Any] = ["name": "sample-theme", "type": "dark", "colors": ["editor.background": "#101010", "editor.foreground": "#111111", "sideBar.background": "#ffffff", "button.background": "#5599dd", "editor.findMatchBackground": "#ffffff80"]]
        #expect(ThemeVSCodeImport.isTheme(value))
        let theme = try ThemeVSCodeImport.parse(value)
        #expect(theme.label == "Sample Theme")
        #expect(theme.appearance == .dark)
        #expect(ThemePalette.hex(theme.colors[.canvas]!) == "#101010")
        #expect(ThemePalette.hex(theme.colors[.searchMatchActiveBackground]!) == "#888888")
        #expect(ThemePalette.hex(theme.colors[.sidebar]!) == "#ffffff")
        #expect(ThemePalette.hex(theme.colors[.text]!) != "#111111")
        #expect(throws: (any Error).self) { try ThemeVSCodeImport.parse(["tokenColors": []]) }
    }
}
