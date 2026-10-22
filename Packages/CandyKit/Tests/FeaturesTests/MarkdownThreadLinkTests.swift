import AppKit
import Testing
@testable import Features

/// `t3-thread://` links in chat Markdown draw as thread chips (MarkdownThreadLink.tsx, 15dc7b0130).
@MainActor
struct MarkdownThreadLinkTests {
    let project = ProjectIconSource(title: "Candy", workspaceRoot: "/tmp/candy")

    func lookup(_ id: String) -> MarkdownContextChips.LinkedThread? {
        switch id {
        case "t1": .init(title: " Fix login ", project: project)
        case "a b": .init(title: "Spaced id")
        default: nil
        }
    }

    @Test func linksFindWrittenAndDecodedIds() {
        #expect(MarkdownContextChips.links(in: MarkdownDocument(parsing: "no links here"), thread: lookup) == nil)
        let found = MarkdownContextChips.links(in: MarkdownDocument(parsing: "See [x](t3-thread://v1/t1) and [y](t3-thread://v1/a%20b) and [z](t3-thread://v1/gone)"), thread: lookup)
        #expect(found?.threads.keys.sorted() == ["a b", "t1"])
        // A link with a title or in reference style resolves from its parsed destination, also inside lists and quotes.
        let titled = "- [Review](t3-thread://v1/t1 \"Open review\")\n\n> [ref][r]\n\n[r]: t3-thread://v1/a%20b"
        let resolved = MarkdownContextChips.links(in: MarkdownDocument(parsing: titled), thread: lookup)
        #expect(resolved?.threads.keys.sorted() == ["a b", "t1"])
        let chips = MarkdownLayout(document: MarkdownDocument(parsing: titled), width: 680, contexts: resolved).contextChips
        #expect(chips.map(\.look.label) == ["Fix login", "Spaced id"] && chips.allSatisfy { $0.tooltip == "Open thread" })
    }

    @Test func repeatedLinksResolveEachIdOnceIncludingMisses() {
        let source = Array(repeating: "[known](t3-thread://v1/t1) [encoded](t3-thread://v1/a%20b) [missing](t3-thread://v1/gone)", count: 200).joined(separator: " ")
        let document = MarkdownDocument(parsing: source)
        var calls: [String: Int] = [:]
        let contexts = MarkdownContextChips.links(in: document) { id in
            calls[id, default: 0] += 1
            return lookup(id)
        }
        #expect(calls == ["t1": 1, "a%20b": 1, "a b": 1, "gone": 1])
        #expect(contexts?.threads.keys.sorted() == ["a b", "t1"])
        // A miss is not cached beyond this pass: a later shell snapshot can find it.
        let refreshed = MarkdownContextChips.links(in: document) { id in
            id == "gone" ? .init(title: "Now available", project: project) : lookup(id)
        }
        #expect(refreshed?.threads["gone"]?.title == "Now available")
    }

    @Test func linkDrawsAsChip() {
        let text = "See [old title](t3-thread://v1/t1), [y](t3-thread://v1/a%20b), [gone](t3-thread://v1/gone) and `[c](t3-thread://v1/t1)`."
        let contexts = MarkdownContextChips.links(in: MarkdownDocument(parsing: text), thread: lookup)
        let chips = MarkdownLayout(document: MarkdownDocument(parsing: text), width: 680, contexts: contexts).contextChips
        #expect(chips.map(\.look.label) == ["Fix login", "Spaced id", "gone"])
        guard chips.count == 3 else { return }
        // The live title, trimmed, with the project's icon.
        #expect(chips[0].look.kind == .thread && chips[0].look.label == "Fix login" && chips[0].look.project == project)
        #expect(chips[0].action == .openThread("t1") && chips[0].tooltip == "Open thread")
        // A percent-escaped id falls back to its decoded form.
        #expect(chips[1].action == .openThread("a b") && chips[1].look.label == "Spaced id" && chips[1].look.project == nil)
        // An unknown thread keeps the link text.
        #expect(chips[2].look.label == "gone" && chips[2].tooltip == "Thread no longer available")
        // The chip keeps its own colors inside markdown (index.css:1958-1979).
        #expect(chips.allSatisfy { $0.look.foregroundOverride == nil })
    }
}
