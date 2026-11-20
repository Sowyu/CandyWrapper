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
}
