import AppKit
import Testing
@testable import Features

/// A streaming answer parses and lays out only what follows its last finished block; both must
/// give exactly what a full pass gives, at every length the stream can stop at.
@MainActor
struct MarkdownIncrementalTests {
    static let answer = """
    ## Plan

    The first paragraph has **bold**, `src/App.swift`, a [link](https://example.com) and _italics_.
    A soft break continues it.

    **Bold heading:**
    Text under the bold line.

    - first item
    - second item with `code`

    - a loose item after a blank line
      continued with an indent

      a second paragraph inside the item

    1. one
    2. two

    3. three after a gap
    10. ten

    Text right after the list.

    ```swift
    func step(_ values: [Int]) -> Int {

        // a blank line inside the fence
        return values.reduce(0, +)
    }
    ```

    ~~~
    tilde fence
    ```
    still inside
    ~~~

    - a list item holding a fence:

      ```text
      inside the item

      still inside
      ```

    after the item

    | Case | Before | After |
    |---|:---:|--:|
    | one | 3 ms | 1 ms |
    | two | 5 ms | 2 ms |

    > A quote
    > on two lines

    > A second quote after a gap

    > [!NOTE]
    > An alert.

    ---

    Setext heading
    ==============

    ***

        indented code

        more indented code

    #hashtag line and `Sources/File.swift:12` again.

    __Underscored bold__ opens this one.

    * star item
    * another

    Final words without a newline
    """

    static let mathAnswer = """
    ## Energy

    Inline $E = mc^2$ and \\(a^2 + b^2\\) in a sentence, display $$x$$ mid-line.

    $$
    \\sum_i x_i

    = y
    $$

    Text after the block.

    \\[
    a

    b
    \\]

    > $$
    > q
    > $$

    - item \\(z\\)
      $$
      w
      $$

    | A | B |
    | - | - |
    | $|x|$ | 1 |

    ```math
    x^2

    y^2
    ```

    Costs $5 and $10.

    $$
    a+\\$$

    never closed

    More text.
    """

    /// A `$$` or `\\[` block runs over blank lines: with math on, every streamed length still equals the full parse.
    @Test func mathIncrementalParseEqualsFullParse() {
        let text = Self.mathAnswer
        var previous: MarkdownDocument.Incremental?
        var reusedSome = false
        var index = text.startIndex
        while true {
            let prefix = String(text[..<index])
            let parse = MarkdownDocument.parse(prefix, math: true, extending: previous)
            let full = MarkdownDocument(parsing: prefix, math: true)
            #expect(parse.document == full, "prefix \(prefix.debugDescription)")
            if parse.document != full { return }
            if !parse.stable.isEmpty { reusedSome = true }
            previous = parse
            if index == text.endIndex { break }
            index = text.index(after: index)
        }
        #expect(reusedSome)
    }

    /// Every prefix, extended from the previous prefix as a stream would, equals the full parse.
    @Test func incrementalParseEqualsFullParse() {
        let text = Self.answer
        var previous: MarkdownDocument.Incremental?
        var reusedSome = false
        var index = text.startIndex
        while true {
            let prefix = String(text[..<index])
            let parse = MarkdownDocument.parse(prefix, extending: previous)
            let full = MarkdownDocument(parsing: prefix)
            #expect(parse.document == full, "prefix of \(prefix.count) characters")
            if parse.document != full { return }
            if !parse.stable.isEmpty { reusedSome = true }
            previous = parse
            if index == text.endIndex { break }
            index = text.index(index, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
        }
        #expect(reusedSome)
    }

    /// CommonMark fences: a closer indented 4 or more is content, and so is an opener (indented code).
    @Test func fenceIndentsMatchTheFullParse() {
        for text in ["Intro\n\n  ```\nfoo\n     ```\n\nText\n```\n", "Intro\n\n    ```\n\nText\n\n```\nfoo\n\nbar\n```\n"] {
            var previous: MarkdownDocument.Incremental?
            var index = text.startIndex
            while true {
                let prefix = String(text[..<index])
                previous = MarkdownDocument.parse(prefix, extending: previous)
                #expect(previous?.document == MarkdownDocument(parsing: prefix), "\(prefix.debugDescription)")
                if index == text.endIndex { break }
                index = text.index(after: index)
            }
        }
    }

    /// The settled message parses whole even when its text equals the last streamed text.
    @Test func settledTextParsesWhole() {
        let text = "Intro\n\n  ```\nfoo\n     ```\n\nText\n```\n"
        let context = TimelineContext()
        var streamed = ""
        for character in text { streamed.append(character); _ = context.document("m", streamed, lineBreaks: false, streaming: true) }
        #expect(context.document("m", text, lineBreaks: false) == MarkdownDocument(parsing: text))
    }

    @Test func splitsOnlyAtSafeLines() {
        // A list marker, a digit, a quote or an indent after a blank line can continue the block above.
        for unsafe in ["- a\n\n- b", "1. a\n\n2. b", "> a\n\n> b", "- a\n\n  b", "x\n\n* y"] {
            #expect(MarkdownDocument.stableCut(Substring(unsafe)) == nil, "\(unsafe)")
        }
        #expect(MarkdownDocument.stableCut(Substring("```\na\n\nb\n```\n\nc")) != nil)
        #expect(MarkdownDocument.stableCut(Substring("```\na\n\nb")) == nil)
        // Reference definitions and HTML blocks that span blank lines always parse whole.
        #expect(!MarkdownDocument.canSplit("[a]\n\n[a]: https://example.com"))
        #expect(!MarkdownDocument.canSplit("<!--\n\n-->"))
        #expect(MarkdownDocument.canSplit("Plain text.\n\nMore."))
        // With math on, no cut falls inside an open display block, which runs over blank lines.
        #expect(MarkdownDocument.stableCut(Substring("$$\na\n\nb")) != nil)
        for open in ["$$\na\n\nb", "\\[\na\n\nb", "$$\na+\\$$\n\nb", "$$x\n\nb"] {
            #expect(MarkdownDocument.stableCut(Substring(open), math: true) == nil, "\(open)")
        }
        for closed in ["$$\na\n$$\n\nb", "\\[\na\n\\]\n\nb", "$$x$$\n\nb", "$$a$$ text\n\nb"] {
            #expect(MarkdownDocument.stableCut(Substring(closed), math: true) != nil, "\(closed)")
        }
    }

    /// A layout that reuses the previous one draws the same thing as one made from scratch.
    @Test func reusedLayoutEqualsFreshLayout() throws {
        let words = Self.answer.split(separator: " ", omittingEmptySubsequences: false)
        var previous: MarkdownLayout?
        var reused = 0
        for count in stride(from: 1, through: words.count, by: 4) {
            let text = words.prefix(count).joined(separator: " ")
            let document = MarkdownDocument(parsing: text)
            let fresh = MarkdownLayout(document: document, width: 640, cwd: "/repo")
            let incremental = MarkdownLayout(document: document, width: 640, cwd: "/repo", reusing: previous)
            reused += incremental.reusedBlocks
            #expect(incremental.height == fresh.height)
            #expect(incremental.blockTops == fresh.blockTops)
            #expect(Self.describe(incremental) == Self.describe(fresh), "\(count) words")
            previous = incremental
        }
        #expect(reused > 0)
        // Other inputs change every block, so nothing is reused.
        let document = MarkdownDocument(parsing: Self.answer)
        let base = MarkdownLayout(document: document, width: 640)
        #expect(MarkdownLayout(document: document, width: 500, reusing: base).reusedBlocks == 0)
        #expect(MarkdownLayout(document: document, width: 640, unwrappedCode: [0], reusing: base).reusedBlocks == 0)
        #expect(MarkdownLayout(document: document, width: 640, reusing: base).reusedBlocks == document.blocks.count)
    }

    /// A table that grows a row at a time lays out only the new cells; the rest come from the last
    /// layout's text boxes, and the result matches a fresh layout.
    @Test func growingTableReusesItsCells() {
        var text = "| Case | Before | After |\n|---|---:|:---:|\n"
        var previous: MarkdownLayout?
        for row in 0..<6 {
            text += "| row \(row) | \(row * 3) ms | `\(row)` ms |\n"
            let document = MarkdownDocument(parsing: text)
            let incremental = MarkdownLayout(document: document, width: 640, reusing: previous)
            let fresh = MarkdownLayout(document: document, width: 640)
            #expect(Self.describe(incremental) == Self.describe(fresh), "\(row + 1) rows")
            #expect(incremental.height == fresh.height)
            // From the third layout on (the first has nothing to reuse, so it keeps no boxes): at
            // least every earlier row's three measured widths, and the placed cells while the column
            // widths hold.
            if row > 1 { #expect(incremental.reusedTextBoxes >= row * 3, "\(row + 1) rows") }
            previous = incremental
        }
        // A layout made without an earlier one keeps no boxes.
        #expect(MarkdownLayout(document: MarkdownDocument(parsing: text), width: 640).reusedTextBoxes == 0)
    }

    /// The streaming row keeps the view's layout across tokens and ends where a fresh view ends.
    @Test func viewReusesLayoutWhileTheDocumentGrows() {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 640, height: 10))
        var parse: MarkdownDocument.Incremental?
        let words = Self.answer.split(separator: " ", omittingEmptySubsequences: false)
        for count in stride(from: 1, through: words.count, by: 7) {
            parse = MarkdownDocument.parse(words.prefix(count).joined(separator: " "), extending: parse)
            view.document = parse!.document
            view.setFrameSize(NSSize(width: 640, height: view.height(forWidth: 640)))
        }
        view.document = MarkdownDocument(parsing: Self.answer)
        let fresh = MarkdownView(frame: NSRect(x: 0, y: 0, width: 640, height: 10))
        fresh.document = MarkdownDocument(parsing: Self.answer)
        #expect(Self.describe(view.layout(forWidth: 640)) == Self.describe(fresh.layout(forWidth: 640)))
        #expect(view.layout(forWidth: 640).reusedBlocks > 0)
    }

    /// A streaming answer's open fence shows plain and stays out of the colored-code cache on every token; once it
    /// settles it draws exactly what a fresh view of the full text draws.
    @Test func openFenceSkipsColoringUntilItSettles() throws {
        let code = (1...120).map { "let value\($0) = compute(\($0)) // line \($0)" }.joined(separator: "\n")
        let answer = "Intro.\n\n```swift\n" + code + "\n```\n\nAfter."
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 640, height: 10))
        view.streaming = true
        let context = TimelineContext()
        let before = MarkdownLayout.coloredCodeKeys
        for end in stride(from: 20, to: answer.utf8.count, by: 150) {
            let text = String(answer.prefix(end))
            view.document = context.document("m", text, lineBreaks: false, streaming: true)
            _ = view.layout(forWidth: 640)
            if !text.hasSuffix("\n```") && !text.contains("\n```\n") {
                #expect(MarkdownLayout.coloredCodeKeys == before, "\(end) characters")
            }
        }
        view.streaming = false
        view.document = context.document("m", answer, lineBreaks: false)
        let fresh = MarkdownView(frame: NSRect(x: 0, y: 0, width: 640, height: 10))
        fresh.document = MarkdownDocument(parsing: answer)
        #expect(Self.describe(view.layout(forWidth: 640)) == Self.describe(fresh.layout(forWidth: 640)))
        // The settled block is colored once, and the fresh view reads it from the cache.
        #expect(Set(MarkdownLayout.coloredCodeKeys).subtracting(before).count == 1)
        func pixels(_ v: MarkdownView) throws -> Data? {
            v.setFrameSize(NSSize(width: 640, height: v.height(forWidth: 640)))
            let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep.tiffRepresentation
        }
        #expect(try pixels(view) == pixels(fresh))
    }

    static func describe(_ layout: MarkdownLayout) -> [String] {
        layout.items.map { item -> String in
            switch item {
            case .text(let box, let p): "text \(p) \(box.height) \(box.text)"
            case .box(let r, _, _, let radius): "box \(r) \(radius)"
            case .glyphs(let s, let p): "glyphs \(s.string) \(p)"
            case .symbol(let k, let r, _): "symbol \(k) \(r)"
            case .checkbox(let r, let c): "checkbox \(r) \(c)"
            case .icon(let i, let r, _): "icon \(i) \(r)"
            case .fileIcon(let path, let r): "fileIcon \(path) \(r)"
            case .fileChip(let c): "file \(c.frame) \(c.meta.filePath)"
            case .contextChip(let c): "context \(c.frame)"
            case .link(let r, let u): "link \(r) \(u)"
            case .clip(let r): "clip \(r)"
            case .scroll(let i, let r, let w): "scroll \(i) \(r) \(w)"
            case .endClip: "endClip"
            case .image(_, let r): "image \(r)"
            case .remoteImage(let u, _, let r): "remote \(u) \(r)"
            case .favicon(let host, let r): "favicon \(host) \(r)"
            case .math(let l, let p, _, let clip): "math \(l.width) \(p) \(String(describing: clip))"
            case .hiddenText(let code, let index): "hidden \(index) \(code)"
            }
        } + layout.controls.map { "control \($0.frame) \($0.action)" }
    }
}
