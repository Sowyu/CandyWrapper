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

    /// Since 3315 a webhook run frames request values in `<webhook-data-ID>` tags. T3 renders raw HTML as text
    /// (ChatMarkdown.tsx:3372 `skipHtml={false}`), so the tags stay visible.
    @Test func webhookDataTagsStayText() {
        let tag = "webhook-data-0123456789ab"
        let doc = MarkdownDocument(parsing: "Review this PR: <\(tag)>https://e.com/pull/45</\(tag)>", preservesLineBreaks: true)
        guard case .paragraph(let runs) = doc.blocks.first else { Issue.record("paragraph"); return }
        #expect(runs.map(\.text).joined() == "Review this PR: <\(tag)>https://e.com/pull/45</\(tag)>")
    }

    /// A raw HTML block has no paragraph, so its text used to vanish: a subagent prompt that opened with `<task>`
    /// drew an empty bubble. T3 shows raw HTML as text, its whitespace collapsed like any HTML text.
    @Test func rawHTMLBlocksStayVisible() {
        func paragraph(_ text: String) -> MarkdownBlock { .paragraph([InlineRun(text: text)]) }
        #expect(MarkdownDocument(parsing: "<task>\nInvestigate the update regressions.\n</task>", preservesLineBreaks: true).blocks
                == [paragraph("<task> Investigate the update regressions. </task>")])
        #expect(MarkdownDocument(parsing: "<context>\nsome context\n</context>\n\nPlease fix it.").blocks
                == [paragraph("<context> some context </context>"), paragraph("Please fix it.")])
        #expect(MarkdownDocument(parsing: "> <task>\n> do it\n> </task>").blocks == [.blockquote([paragraph("<task> do it </task>")])])
        guard case .list(let list)? = MarkdownDocument(parsing: "- <task>\n  do it\n  </task>").blocks.first else { Issue.record("list"); return }
        #expect(list.items.first?.blocks == [paragraph("<task> do it </task>")])
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

    /// A blank line between items makes the list loose: each item's `<p>` margin (0.65rem) replaces `li + li`'s 0.25rem.
    @Test func looseListsSpaceItemsLikeParagraphs() {
        func list(_ text: String) -> MarkdownList? {
            if case .list(let l)? = MarkdownDocument(parsing: text).blocks.first { return l }
            return nil
        }
        #expect(list("1. a\n2. b")?.loose == false)
        #expect(list("1. a\n\n2. b")?.loose == true)
        #expect(list("- a\n\n  more\n- b")?.loose == true)
        #expect(list("- a\n  - x\n\n  - y\n- b")?.loose == false)
        #expect(list("- a\n  ```\n  x\n  ```\n- b")?.loose == false)
        #expect(list("- a\nlazy\n\n- b")?.loose == true)
        #expect(list("10) a\n\t\n11) b")?.loose == true)
        // Only text that may hold a loose list pays for source positions.
        for text in ["- a\n\n- b", "1. a\n\n  more", "* a\n\n\tcode", "- a\r\n\r\n- b", "> - a\n>\n> - b"] {
            #expect(MarkdownDocument.mayHaveLooseList(Substring(text)), "\(text)")
        }
        for text in ["one\ntwo\n\nthree", "Intro\n\n- a\n- b\n\nOutro", "- a\n- b\n\nText\n\n- c", "-a\n\n-b", "1.5\n\n2.5", ""] {
            #expect(!MarkdownDocument.mayHaveLooseList(Substring(text)), "\(text)")
        }
        let tight = MarkdownLayout(document: MarkdownDocument(parsing: "1. a\n2. b\n3. c"), width: 400).height
        let loose = MarkdownLayout(document: MarkdownDocument(parsing: "1. a\n\n2. b\n\n3. c"), width: 400).height
        // The gaps grow, and the first and last `<p>` margins stay although the root zeroes the list's own.
        let m = MarkdownStyle.blockMargin
        #expect(abs(loose - tight - 2 * (m - MarkdownStyle.itemGap) - 2 * m) < 0.01)
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

    /// A clipped draw paints the same pixels inside the clip as a full draw, and nothing far outside it.
    @Test func clippedTextBoxDrawMatchesFullDraw() {
        let text = (1...300).map { "let value\($0) = compute(\($0)) // line \($0)" }.joined(separator: "\n")
        let box = MarkdownTextBox(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]),
                                  width: 400, lineHeight: 20, strut: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), wraps: false)
        #expect(box.lineCount == 300)
        func render(_ clip: CGRect?) -> [UInt8] {
            let w = 400, h = 6000
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            pixels.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
                box.draw(in: ctx, at: .zero, clip: clip)
            }
            return pixels
        }
        let full = render(nil), clipped = render(CGRect(x: 0, y: 2000, width: 400, height: 300))
        func rows(_ p: [UInt8], _ ys: Range<Int>) -> ArraySlice<UInt8> { p[(ys.lowerBound * 1600)..<(ys.upperBound * 1600)] }
        #expect(rows(full, 2000..<2300) == rows(clipped, 2000..<2300))
        #expect(rows(clipped, 0..<1900).allSatisfy { $0 == 0 })
        #expect(rows(clipped, 2400..<6000).allSatisfy { $0 == 0 })
        #expect(rows(full, 0..<1900).contains { $0 != 0 })
    }

    /// A code block's attributed string as `MarkdownLayout.codeBlock` builds it, with some italic runs.
    private func codeString(_ code: String) -> NSAttributedString {
        let font = DSFont.mono(MarkdownStyle.codeFontSize)
        let string = NSMutableAttributedString(string: code, attributes: [.font: font])
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        var at = 0
        while at + 7 < string.length { string.addAttribute(.font, value: italic, range: NSRange(location: at, length: 5)); at += 97 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = []
        paragraph.defaultTabInterval = 8 * TextLine(NSAttributedString(string: " ", attributes: [.font: font])).width
        paragraph.tabStops = []
        string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Lazy layout breaks, places and measures every line as the full layout does.
    @Test func lazyTextBoxMatchesFullLayout() {
        let samples = ["let value = compute(1) // plain", "", "\tfunc a() {", "\t\tif x {\treturn 1 }", "abc\tdef\tg", "trailing spaces   ",
                       String(repeating: "word ", count: 40), String(repeating: "x", count: 150), "café ünïcode", "emoji 🍬 here", "中文代码行",
                       String(repeating: "ab ", count: 30) + "    ", "}"]
        let code = (0..<260).map { samples[$0 % samples.count] + ($0 % 3 == 0 ? " // \($0)" : "") }.joined(separator: "\n")
        let string = codeString(code), font = DSFont.mono(MarkdownStyle.codeFontSize)
        for wraps in [true, false] {
            for width in [301.0, 512.5, 700] as [CGFloat] {
                let full = MarkdownTextBox(string, width: width, lineHeight: 18, strut: font, wraps: wraps, lazy: false)
                let lazy = MarkdownTextBox(string, width: width, lineHeight: 18, strut: font, wraps: wraps, lazy: true)
                #expect(lazy.laidOutCount < 260)
                #expect(lazy.lineCount == full.lineCount && lazy.height == full.height && lazy.firstBaseline == full.firstBaseline)
                #expect(abs(lazy.usedWidth - full.usedWidth) < 0.001)
                let all = NSRange(location: 0, length: (code as NSString).length)
                let a = lazy.spans(all), b = full.spans(all)
                #expect(a.count == b.count)
                #expect(zip(a, b).allSatisfy { $0.x0 == $1.x0 && $0.x1 == $1.x1 && $0.baseline == $1.baseline })
                for y in stride(from: 3.0, to: full.height, by: 97) {
                    #expect(lazy.character(at: CGPoint(x: 60, y: y)) == full.character(at: CGPoint(x: 60, y: y)))
                }
            }
        }
    }

    /// An 18,000 line block opens without laying out its lines, then lays out the ones that draw, however far down.
    @Test func lazyTextBoxLaysOutLinesFarBelowTheFold() {
        let code = (0..<18_000).map { "let value\($0) = compute(\($0)) // line \($0) of the huge block" }.joined(separator: "\n")
        let font = DSFont.mono(MarkdownStyle.codeFontSize)
        let box = MarkdownTextBox(codeString(code), width: 700, lineHeight: 18, strut: font)
        #expect(box.lineCount == 18_000 && box.height == 18_000 * 18)
        #expect(box.laidOutCount == 0)
        func paint(_ top: CGFloat) -> Bool {
            let w = 700, h = 400
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            pixels.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
                box.draw(in: ctx, at: CGPoint(x: 0, y: -top), clip: CGRect(x: 0, y: 0, width: 700, height: 400))
            }
            return pixels.contains { $0 != 0 }
        }
        #expect(paint(0))
        #expect(box.laidOutCount < 40)
        #expect(paint(box.height - 400))
        #expect(box.laidOutCount < 80)
        let last = box.spans(NSRange(location: (code as NSString).length - 5, length: 5))
        #expect(last.count == 1 && (last.first?.baseline ?? 0) > box.height - 18)
        #expect(box.laidOutCount < 80)
    }
}

/// 834f0e3a1b: Windows paths keep their backslashes (shared/src/markdownPipeline.test.ts, the prose case).
struct MarkdownWindowsPathTests {
    private func text(_ markdown: String) -> String {
        MarkdownDocument(parsing: markdown).blocks.map { block -> String in
            guard case .paragraph(let runs) = block else { return "" }
            return runs.map { $0.code ? "<code>\($0.text)</code>" : $0.text }.joined()
        }.joined()
    }

    @Test func drivePathsInProseRenderAsWritten() {
        #expect(text(#"Saved to C:\Users\me\.t3\_build and (C:\.scratch) and C:/work\.config."#)
            == #"Saved to C:\Users\me\.t3\_build and (C:\.scratch) and C:/work\.config."#)
        #expect(text(#"Escaped C:\\Users\\me"#) == #"Escaped C:\\Users\\me"#)
        #expect(text(#"See C:\x and \*this\* and Note:\*that\*."#) == #"See C:\x and *this* and Note:*that*."#)
        #expect(text(#"`C:\me\.t3` and C:\me\.t3"#) == #"<code>C:\me\.t3</code> and C:\me\.t3"#)
        #expect(MarkdownDocument(parsing: "```\nC:\\me\\.t3\n```").blocks == [.code(language: "text", title: nil, code: #"C:\me\.t3"#)])
    }
}

/// e27a03e94d: an image alone on its source line keeps that line (shared/src/markdownPipeline.test.ts).
struct MarkdownImageLineTests {
    private func shape(_ markdown: String) -> String {
        MarkdownDocument(parsing: markdown).blocks.map { block -> String in
            guard case .paragraph(let runs) = block else { return "?" }
            return runs.map { $0.image != nil ? "<img>" : $0.isBreak && $0.text == "\n" ? "<br>" : $0.text }.joined()
        }.joined()
    }

    @Test func imagesOnTheirOwnLineBreakAroundThem() {
        #expect(shape("**Palette**\n![Palette](/tmp/palette.png)\n**Hero** (dark)\n![Hero](/tmp/hero.png)")
            == "Palette<br><img><br>Hero (dark)<br><img>")
        #expect(shape("Built ![CI](/ci.svg)\nand wrapped") == "Built <img> and wrapped")
        #expect(shape("Hard-wrapped\nprose") == "Hard-wrapped prose")
    }
}
