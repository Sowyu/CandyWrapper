import AppKit
import Testing
import T3Protocol
@testable import Features

@MainActor
struct Nightly3814LinksTests {
    @Test func scopedLinksResolveOnlyTheirNamedEnvironmentAndKeepDecodedIdsScoped() {
        let href = "t3-thread://v2/remote/a%20b"
        let doc = MarkdownDocument(parsing: "<\(href)>")
        var lookedUp: [String] = []
        let chips = MarkdownContextChips.links(in: doc, environmentId: "local") { key in
            lookedUp.append(key)
            return key == "t3-thread://v2/remote/a b" ? .init(title: "Current title", destination: key) : nil
        }
        #expect(lookedUp == [href, "t3-thread://v2/remote/a b"])
        let chip = chips?.threadLinkChip(threadId: href, label: href)
        #expect(chip?.action == .openThread("t3-thread://v2/remote/a b"))
        #expect(chip?.look.label == "Current title")
        let missing = MarkdownContextChips.links(in: doc, environmentId: "local") { _ in nil }
        #expect(missing?.threadLinkChip(threadId: href, label: href).action == MarkdownContextChip.Action.none)
        #expect(missing?.threadLinkChip(threadId: href, label: href).look.label == "Thread on another machine")
    }

    @Test func v1LinksAndMalformedV2Links() {
        #expect(ThreadLink(href: "t3-thread://v1/old")?.lookupKey == "old")
        #expect(ThreadLink(href: "t3-thread://v2/env/thread")?.environmentId == "env")
        #expect(ThreadLink(href: "t3-thread://v2/env/thread")?.threadId == "thread")
        for href in ["t3-thread://v2/env", "t3-thread://v2//thread", "t3-thread://v2/env/", "t3-thread://v3/env/thread"] {
            #expect(ThreadLink(href: href) == nil)
        }
        let live = MarkdownContextChips(threads: ["old": .init(title: "Live title")])
        #expect(live.threadLinkChip(threadId: "old", label: "Stale title").look.label == "Live title")
    }

    @Test func plainTextAndMinimapDoNotShowRawScopedUrls() {
        let href = "t3-thread://v2/env/thread"
        let document = MarkdownDocument(parsing: "See <\(href)>")
        #expect(document.blocks.map(\.plainText).joined() == "See Thread no longer available")
        let block = document.blocks[0]
        #expect(ThreadMinimapItem.text(block, threadTitle: { $0 == href ? "Renamed thread" : nil }) == "See Renamed thread")
        #expect(ThreadMinimapItem.text(block) == "See Thread no longer available")
    }
}
