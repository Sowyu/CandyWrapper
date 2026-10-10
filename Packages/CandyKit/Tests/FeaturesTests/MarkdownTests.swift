import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct MarkdownTests {
    @Test func parsesBlocks() {
        let doc = MarkdownDocument(parsing: """
        # Title
        Text with `code`
        and a soft break.

        - [ ] open
        - [x] done
          - nested

        > [!WARNING]
        > Careful.

        > [!NOTE] not an alert

        | A | B |
        |:--|--:|
        | 1 | 2 |

        ```python title="x.py"
        print(1)
        ```

        ![alt](https://e.com/a.png)
        """)
        guard doc.blocks.count == 8 else { Issue.record("blocks: \(doc.blocks)"); return }
        #expect(doc.blocks[0] == .heading(level: 1, [InlineRun(text: "Title")]))
        if case .paragraph(let runs) = doc.blocks[1] {
            #expect(runs.map(\.text).joined() == "Text with code and a soft break.")
            #expect(runs.contains { $0.code && $0.text == "code" })
        } else { Issue.record("paragraph") }
        if case .list(let list) = doc.blocks[2] {
            #expect(list.items.map(\.task) == [false, true])
            if case .list(let nested)? = list.items[1].blocks.last { #expect(nested.items.count == 1) } else { Issue.record("nested list") }
        } else { Issue.record("list") }
        #expect(doc.blocks[3] == .alert(.warning, [.paragraph([InlineRun(text: "Careful.")])]))
        if case .blockquote = doc.blocks[4] {} else { Issue.record("a marker sharing its line stays a quote") }
        if case .table(let t) = doc.blocks[5] {
            #expect(t.alignments == [.left, .right])
            #expect(t.rows.count == 1)
        } else { Issue.record("table") }
        #expect(doc.blocks[6] == .code(language: "python", title: "x.py", code: "print(1)"))
        #expect(doc.blocks[7] == .image(alt: "alt", url: URL(string: "https://e.com/a.png")!))
    }

    @Test func userMessagesKeepLineBreaks() {
        let doc = MarkdownDocument(parsing: "one\ntwo", preservesLineBreaks: true)
        guard case .paragraph(let runs) = doc.blocks.first else { Issue.record("paragraph"); return }
        #expect(runs.map(\.text).joined() == "one\ntwo")
    }

    /// Token classes Shiki gives these snippets with pierre-light (dumped from T3's bundled highlighter).
    @Test func highlightsLikeShiki() {
        func kinds(_ code: String, _ language: String) -> [String: CodeTokenKind] {
            let u = Array(code.utf16)
            var out: [String: CodeTokenKind] = [:]
            for t in CodeHighlighter.tokens(code, language: language) {
                out[String(decoding: u[t.range.location..<t.range.upperBound], as: UTF16.self)] = t.kind
            }
            return out
        }
        let py = kinds("def greet(name: str) -> str:\n    return f\"hi {name}\"  # done", "python")
        #expect(py["def"] == .storage)
        #expect(py["greet"] == .function)
        #expect(py["name"] == .parameter)
        #expect(py["str"] == .operator)
        #expect(py["return"] == .keyword)
        #expect(py["# done"] == .comment)
        let ts = kinds("const text: Promise<Config> = await load(`${a}`);", "ts")
        #expect(ts["const"] == .storage)
        #expect(ts["text"] == .constantName)
        #expect(ts["Promise"] == .storage)
        #expect(ts["<"] == .punctuation)
        #expect(ts["await"] == .keyword)
        #expect(ts["load"] == .function)
        #expect(ts["${"] == .keyword)
        let json = kinds("{\"k\": \"v\", \"n\": null}", "json")
        #expect(json["\"k\""] == .tag)
        #expect(json["\"v\""] == .string)
        #expect(json["null"] == .operator)
        #expect(CodeHighlighter.tokens("anything", language: "brainfuck").isEmpty)
    }

    @Test func heightIsCachedPerWidth() {
        let view = MarkdownView(frame: .zero)
        view.setMarkdown(MarkdownGallery.sample)
        let start = Date()
        let h = view.height(forWidth: 600)
        let first = Date().timeIntervalSince(start)
        let again = Date()
        #expect(view.height(forWidth: 600) == h)
        let cached = Date().timeIntervalSince(again)
        print(String(format: "MARKDOWN layout of the gallery sample: %.1f ms, cached %.3f ms", first * 1000, cached * 1000))
        #expect(view.layout(forWidth: 600) === view.layout(forWidth: 600))
        view.setMarkdown("Short.")
        #expect(view.height(forWidth: 600) < h)
    }

    @Test func gallerySection() throws {
        for dark in [false, true] {
            let rep = ComponentGallery.render(MarkdownGallery.section, width: 550, dark: dark)
            try Snapshot.writePNG(rep, to: URL(fileURLWithPath: "/tmp/candywrapper-fidelity/gallery-markdown-\(dark ? "dark" : "light").png"))
            #expect(rep.pixelsHigh > 1000)
        }
    }
}
