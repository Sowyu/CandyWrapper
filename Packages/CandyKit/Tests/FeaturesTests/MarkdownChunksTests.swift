import AppKit
import Testing
@testable import Features

/// markdownChunks.test.ts at 5258.
struct MarkdownChunksTests {
    func starts(_ text: String) -> [String] {
        MarkdownChunks.split(text, targetChars: 1).chunks.map { $0.text.components(separatedBy: "\n")[0] }
    }

    @Test func cutsOnlyAtNewTopLevelBlocksAndKeepsEveryByte() {
        let text = ["# Title", "Intro paragraph", "", "- item one", "", "  continued item", "- item two", "", "2. ordered", "",
                    "```md", "# not a heading", "", "Not a paragraph", "```", "", "> quote", "", "Closing paragraph", "## Next", "---", "",
                    "| a | b |"].joined(separator: "\n")
        let chunks = MarkdownChunks.split(text, targetChars: 1).chunks
        #expect(chunks.map(\.text).joined(separator: "\n") == text)
        #expect(chunks.reduce(0) { $0 + $1.lines } == text.components(separatedBy: "\n").count)
        #expect(starts(text) == ["# Title", "```md", "> quote", "Closing paragraph", "## Next", "| a | b |"])
    }

    @Test func blocksStayOpenUntilTheirCloser() {
        #expect(starts(["````", "```", "", "# inside", "````", "", "after"].joined(separator: "\n")) == ["````", "after"])
        #expect(starts(["<https://example.com>", "```md", "", "# literal", "```", "", "after"].joined(separator: "\n")) == ["<https://example.com>", "after"])
        #expect(starts(["---", "title: x", "", "# not a heading", "---", "", "# Heading"].joined(separator: "\n")) == ["---", "# Heading"])
        #expect(starts(["$$", "", "# math", "$$", "", "after"].joined(separator: "\n")) == ["$$", "after"])
        #expect(starts(["<details>", "", "# hidden", "", "</details>", "", "after"].joined(separator: "\n")) == ["<details>", "after"])
    }

    @Test func waitsForTheTargetSize() {
        #expect(MarkdownChunks.split(["# a", "", "b", "", "# c", "", "d"].joined(separator: "\n"), targetChars: 6).chunks.map(\.text)
            == ["# a\n\nb\n", "# c\n\nd"])
    }

    @Test func crlfLinesSplitLikeJavaScript() {
        #expect(starts("# a\r\n\r\nb\r\n\r\n# c") == ["# a\r", "b\r", "# c"])
    }

    @Test func collectsLinkDefinitionsOutsideCode() {
        let text = ["[![badge][b]][site]", "", "```md", "[fake]: /not-a-definition", "```", "", "Paragraph", "[inline]: /continues-the-paragraph", "",
                    "[site]: https://example.com", "[b]: https://example.com/badge.svg 'Badge'", "[^note]: a footnote", "",
                    "[x]: /url \"title\" is paragraph text", "", "# Heading", "[h]: /after-heading", "", "---", "[t]: /after-break", "",
                    "===", "[p]: /paragraph-text", "", "```sh", "npm install", "```", "[fence]: /after-fence", "~~~", "~~~",
                    "Text after a fence", "[q]: /continues-the-paragraph", "", "$$", "x", "$$ trailing", "[math]: /inside-math", "",
                    "<!-->", "```", "-->", "```", "[comment]: /after-a-closed-comment", "```", "[code]: /inside-a-fence-after-a-comment", "```", "",
                    "- ```md", "  ~~~", "  ~~~", "  [list]: /inside-a-list-fence", "  ```"].joined(separator: "\n")
        #expect(MarkdownChunks.split(text).definitions
            == "[site]: https://example.com\n[b]: https://example.com/badge.svg 'Badge'\n[h]: /after-heading\n[t]: /after-break\n[fence]: /after-fence\n[comment]: /after-a-closed-comment")
    }
}

/// Markdown past the 1 MB read renders only the pieces near the viewport (ChunkedMarkdown.tsx at 5258).
@MainActor
struct ChunkedMarkdownFileViewTests {
    @Test func largeMarkdownHoldsOnlyNearbyPieces() async throws {
        let parts = (0..<10000).map { "## Section \($0)\n\nSome *text* with `code` and a [link][site]. More words to fill the paragraph out.\n\n- item one\n- item two\n" }
        let text = "[site]: https://example.com\n\n" + parts.joined(separator: "\n")
        #expect(text.utf8.count > 1_000_000)
        let view = ChunkedMarkdownFileView(markdown: text, cwd: "/repo")
        let ready = AsyncStream<Void> { continuation in view.onReady = { continuation.yield(); continuation.finish() } }
        for await _ in ready { break }
        #expect(view.chunks.count > 100)
        let start = Date()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(Date().timeIntervalSince(start) < 1, "first screen took \(Date().timeIntervalSince(start)) s")
        #expect(!view.live.isEmpty && view.live.count < 12)
        let clip = view.scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 200_000))
        view.tile()
        #expect(view.live.count < 12)
        #expect(view.live.keys.allSatisfy { $0 > 10 })
    }
}
