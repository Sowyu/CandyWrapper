import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Nightly 4928 thread pieces handed over by the composer, settings and markdown ports (thread-2).
@MainActor
struct ThreadCatchUp4928Tests {
    private func cards(_ layout: MarkdownLayout) -> [CGRect] {
        layout.items.compactMap { if case .citationCard(let r, _) = $0 { r } else { nil } }
    }

    /// `ResponseReplyCard` (AssistantCitationChip.tsx:156-179): a reply's `response` reference draws as the quote card,
    /// with a title line when the response reported on subagents.
    @Test func replyReferenceDrawsAsACard() throws {
        func layout(subagents: [ComposerReply.Subagent]) throws -> MarkdownLayout {
            let record = try #require(ComposerReply.record(environmentId: "e", threadId: "t", messageId: "m", text: "The fix is in.",
                                                           itemId: "i", subagents: subagents))
            let reference = try #require(ComposerReply.reference(record))
            let doc = MarkdownDocument(parsing: ComposerContext.reference(reference) + " thanks", preservesLineBreaks: true)
            let contexts = MarkdownContextChips(records: [reference.contextId: record])
            return ThreadDesign.layout(in: NSAppearance(named: .aqua)!, design: true) {
                MarkdownLayout(document: doc, width: 400, contexts: contexts)
            }
        }
        let plain = try layout(subagents: [])
        #expect(cards(plain).map(\.height) == [32])
        #expect(plain.contextChips.isEmpty)
        let titled = try layout(subagents: [.init(threadId: "c1", title: "Reviewer"), .init(threadId: "c2", title: "Tester")])
        #expect(cards(titled).map(\.height) == [48])
        // An unknown record keeps the unavailable chip.
        let doc = MarkdownDocument(parsing: "[x](t3-context://v1/response/response%3Am) hi", preservesLineBreaks: true)
        let missing = ThreadDesign.layout(in: NSAppearance(named: .aqua)!, design: true) {
            MarkdownLayout(document: doc, width: 400, contexts: MarkdownContextChips())
        }
        #expect(cards(missing).isEmpty)
    }

    /// `ModelMentionChip` in sent messages (SkillInlineText.tsx:37-50): known references chip, unknown ones stay text.
    @Test func modelReferencesChipInSentMessages() {
        var contexts = MarkdownContextChips()
        contexts.models = ["model:claude/opus": .init(label: "Opus", provider: "Claude", driver: "claudeAgent")]
        let doc = MarkdownContextChips.modelDocument(
            MarkdownDocument(parsing: "Ask model:claude/opus, not model:claude/unknown or `model:claude/opus`.", preservesLineBreaks: true),
            models: contexts.models)
        let layout = ThreadDesign.layout(in: NSAppearance(named: .aqua)!, design: true) {
            MarkdownLayout(document: doc, width: 400, contexts: contexts)
        }
        #expect(layout.contextChips.map(\.look.label) == ["Opus"])
        #expect(layout.contextChips.first?.look.kind == .model(driver: "claudeAgent"))
    }

    /// #24833, #24898: a subagent's glyph wears its instance's account badge once two instances share a driver,
    /// and status dots move to the top corner.
    @Test func subagentAccountBadges() {
        let model = ThreadViewModel()
        model.providers = [ServerProvider(instanceId: .init("codex"), driver: "codex"), ServerProvider(instanceId: .init("claudeAgent"), driver: "claudeAgent")]
        #expect(!model.anyInstanceBadge)
        #expect(model.providerBadge(instanceId: "codex", ring: .white) == nil)
        model.providers.append(ServerProvider(instanceId: .init("codex_work"), driver: "codex"))
        #expect(model.anyInstanceBadge)
        #expect(model.providerBadge(instanceId: "codex_work", ring: .white)?.size == .small)
        #expect(model.providerBadge(instanceId: "claudeAgent", ring: .white) == nil)
    }

    /// #33820: a sent message keeps the numbers written on its list items, in digits at every level; replies count
    /// from the first marker.
    @Test func sentListsKeepWrittenNumbers() {
        func numbers(_ text: String, user: Bool) -> [Int?] {
            guard case .list(let list)? = MarkdownDocument(parsing: text, preservesLineBreaks: user).blocks.first else { return [] }
            return list.items.map(\.number)
        }
        #expect(numbers("3. a\n5. b\n9. c", user: true) == [3, 5, 9])
        #expect(numbers("3. a\n5. b\n9. c", user: false) == [3, 4, 5])
        guard case .list(let outer)? = MarkdownDocument(parsing: "1. Outer\n   1. Nested\n   7. Skipped", preservesLineBreaks: true).blocks.first,
              case .list(let inner)? = outer.items.first?.blocks.last else { Issue.record("no nested list"); return }
        #expect(outer.decimal && inner.decimal)
        #expect(inner.items.map(\.number) == [1, 7])
    }

    /// #27794: bare URLs keep trailing underscores and tildes.
    @Test func bareLinksKeepTrailingUnderscores() {
        func links(_ text: String) -> [String] {
            guard case .paragraph(let runs)? = MarkdownDocument(parsing: text).blocks.first else { return [] }
            return runs.compactMap { $0.link?.absoluteString }
        }
        #expect(links("see https://x.com/dimasike_ now") == ["https://x.com/dimasike_"])
        #expect(links("http://example.com/name__.") == ["http://example.com/name__"])
        #expect(links("https://example.com/a~") == ["https://example.com/a~"])
        #expect(links("[x](https://a.com/b)_c") == ["https://a.com/b"])
    }

    /// #29759: find in thread matches a word typed with a straight apostrophe against a curly one.
    @Test func findFoldsCurlyApostrophes() {
        #expect(ThreadFindText.count("It’s done, isn‘t it", "it's") == 1)
        #expect(ThreadFindText.count("It’s done", "it’s") == 1)
        #expect(ThreadFindText.count("plain text", "it's") == 0)
    }

    /// #29511: TeX that fails only because of an unescaped percent typesets after escaping it (MathTypeset.logic.test.ts).
    @Test func literalPercentsEscape() {
        let cases: [(String, String)] = [
            (#"\text{3.18% yield}"#, #"\text{3.18\% yield}"#),
            (#"\text{100%% yield}"#, #"\text{100\%\% yield}"#),
            (#"6\% + 2\%"#, #"6\% + 2\%"#),
            (#"x\\%"#, #"x\\\%"#),
            ("x % note\n+ 1", "x % note\n+ 1"),
            ("% note\n\\text{2%}", "% note\n\\text{2\\%}"),
            ("x &= 1 % +9%\n\\text{2%}", "x &= 1 % +9%\n\\text{2\\%}"),
            (#"\verb|50%|+\text{2%}"#, #"\verb|50%|+\text{2\%}"#),
            (#"\verb*%a%b%+c%"#, #"\verb*%a%b\%+c\%"#),
            (#"\verb|50%+\text{2%}"#, #"\verb|50%+\text{2%}"#),
        ]
        for (tex, expected) in cases { #expect(escapeLiteralPercents(tex) == expected, "\(tex)") }
    }

    /// #22875: "Copy as Markdown" for a table escapes a cell's pipes but keeps a formula's.
    @Test func copiedTablesKeepFormulaPipes() throws {
        let doc = MarkdownDocument(parsing: "| a | b |\n| --- | --- |\n| x\\|y | $|v|$ |", math: true)
        guard case .table(let table)? = doc.blocks.first else { Issue.record("no table"); return }
        let copied = MarkdownLayout.tableMarkdown(table)
        #expect(copied.contains(#"x\|y"#))
        // CandyWrapper copies a formula as `\(...\)`, its own pipes left alone.
        #expect(copied.contains(#"\(|v|\)"#) && !copied.contains(#"\|v\|"#))
    }
}

