import AppKit
import DesignSystem
import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

/// Long answers parse and lay out off the main thread: the result must be the layout the main thread would make.
@Suite(.serialized)
@MainActor
struct MarkdownBackgroundLayoutTests {
    /// How long a test waits for a background layout. Alone one lands in 0.08 s, but in the full parallel suite the
    /// shared background queues kept one waiting past 20 s (1.14.9 suite, 2026-10-28), so the wait is generous and the
    /// checks after it stay strict.
    static let backgroundWait: TimeInterval = 120

    /// Every block kind that takes a counter (code, tables, display math), nested ones too, plus links and chips.
    static let unit = """
    ## Finding

    A **bold** paragraph with [a link](https://example.com) and `Sources/App/main.swift`.

    - first
    - second with code:

      ```sh
      echo nested
      ```

    > quoted $$x^2 + 1$$ text

    ```swift
    let answer = 42
    ```

    | Key | Value |
    | --- | --- |
    | x | 42 |

    $$
    \\frac{a}{b}
    $$


    """

    static func signature(_ layout: MarkdownLayout) -> [String] {
        func r(_ rect: CGRect) -> String { "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)" }
        var out = ["h \(layout.height)", "tops \(layout.blockTops)"]
        for item in layout.items {
            switch item {
            case .text(let box, let p): out.append("text \(p) \(box.height) \(box.text)")
            case .box(let rect, _, _, let radius): out.append("box \(r(rect)) \(radius)")
            case .scroll(let index, let viewport, let width): out.append("scroll \(index) \(r(viewport)) \(width)")
            case .math(_, let p, _, let clip): out.append("math \(p) \(clip.map(r) ?? "-")")
            case .link(let rect, let url): out.append("link \(r(rect)) \(url)")
            case .fileChip(let chip): out.append("file \(r(chip.frame)) \(chip.label)")
            case .hiddenText(let text, let index): out.append("hidden \(index) \(text)")
            default: out.append("\(item)".components(separatedBy: "(").first ?? "")
            }
        }
        for control in layout.controls { out.append("control \(r(control.frame)) \(control.action)") }
        return out
    }

    @Test func parallelLayoutMatchesSerial() async throws {
        let document = MarkdownDocument(parsing: String(repeating: Self.unit, count: 40), math: true)
        #expect(document.blocks.count >= MarkdownLayout.parallelBlocksForTests)
        let serial = MarkdownLayout(document: document, width: 680, unwrappedCode: [3, 7], cwd: "/tmp", expandedTables: [2], runsShell: true)
        let parallel = await Task.detached {
            MarkdownLayout(document: document, width: 680, unwrappedCode: [3, 7], cwd: "/tmp", expandedTables: [2], runsShell: true, parallel: true)
        }.value
        let a = Self.signature(serial), b = Self.signature(parallel)
        #expect(a.count == b.count)
        #expect(a == b, "first difference: \(zip(a, b).first { $0 != $1 }.map { "\($0.0) | \($0.1)" } ?? "lengths")")
    }

    /// A long document lays out in the background: the view reserves the pending height, then takes the same layout.
    @Test func viewLaysOutInBackground() async throws {
        let document = MarkdownDocument(parsing: String(repeating: Self.unit, count: 40))
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 680, height: 100))
        view.laysOutInBackground = true
        view.pendingHeight = { _ in 1234 }
        var changes = 0
        view.onHeightChange = { changes += 1 }
        view.document = document
        #expect(view.height(forWidth: 680) == 1234)
        #expect(view.isPending(forWidth: 680))
        let deadline = Date().addingTimeInterval(Self.backgroundWait)
        while view.isPending(forWidth: 680), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isPending(forWidth: 680))
        #expect(changes == 1)
        let expected = MarkdownLayout(document: document, width: 680)
        #expect(Self.signature(view.layout(forWidth: 680)) == Self.signature(expected))
    }

    /// A view recycled for another message while the last one's layout runs never shows that layout.
    @Test func recycledViewDropsTheLastMessagesLayout() async throws {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 680, height: 100))
        view.laysOutInBackground = true
        view.messageID = "a"
        view.document = MarkdownDocument(parsing: String(repeating: Self.unit, count: 40) + "Only in answer alpha.")
        _ = view.height(forWidth: 680)
        view.messageID = "b"
        let b = MarkdownDocument(parsing: String(repeating: Self.unit, count: 30) + "Only in answer beta.")
        view.document = b
        func shown() -> [String] { view.layout(forWidth: 680).items.compactMap { if case .text(let box, _) = $0 { box.text } else { nil } } }
        let deadline = Date().addingTimeInterval(Self.backgroundWait)
        while Date() < deadline {
            #expect(!shown().contains { $0.contains("alpha") })
            if !view.isPending(forWidth: 680), !shown().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Self.signature(view.layout(forWidth: 680)) == Self.signature(MarkdownLayout(document: b, width: 680)))
    }

    /// Long settled text parses off the main thread; the timeline's context hands the key back when it lands.
    @Test func settledTextParsesInBackground() async throws {
        let context = TimelineContext()
        let text = String(repeating: Self.unit, count: 120) + UUID().uuidString
        #expect(text.utf8.count >= TimelineContext.backgroundBytes)
        var ready: [String] = []
        context.onDocumentReady = { ready.append($0) }
        #expect(context.document("a", text, lineBreaks: false, background: true).blocks.isEmpty)
        #expect(context.isParsing("a"))
        let deadline = Date().addingTimeInterval(Self.backgroundWait)
        while ready.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ready == ["a"])
        let math = ClientSettingsStore.shared.current.bool("mathRenderingEnabled")
        #expect(context.document("a", text, lineBreaks: false, background: true) == MarkdownDocument(parsing: text, math: math))
        // A streamed answer that settles with the same text keeps its incremental parse, which equals the full one.
        let streamed = context.document("b", text + "!", lineBreaks: false, streaming: true, background: true)
        #expect(context.document("b", text + "!", lineBreaks: false, background: true) == streamed)
        #expect(!context.isParsing("b"))
    }

    /// A message with thousands of buttons and link areas keeps views only near what is visible.
    @Test func hitViewsStayNearTheViewport() throws {
        let document = MarkdownDocument(parsing: String(repeating: Self.unit, count: 120))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let view = MarkdownView(frame: .zero)
        view.document = document
        let height = view.height(forWidth: 680)
        view.frame = NSRect(x: 0, y: 0, width: 680, height: height)
        scroll.documentView = view
        view.layoutSubtreeIfNeeded()
        let controls = view.layout(forWidth: 680).controls
        #expect(controls.count > MarkdownView.hitViewsAll)
        func shown() -> [ButtonView] { view.subviews.compactMap { $0 as? ButtonView }.filter { !$0.isHidden } }
        #expect(shown().count < controls.count / 2)
        #expect(shown().allSatisfy { $0.frame.minY < 600 + MarkdownView.hitViewMargin })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: height - 600))
        RunLoop.main.run(mode: .default, before: Date())
        view.layoutSubtreeIfNeeded()
        #expect(!shown().isEmpty)
        #expect(shown().allSatisfy { $0.frame.maxY > height - 600 - MarkdownView.hitViewMargin })
    }

    /// A draw pass walks only the top-level blocks its rect touches. A find query walks every item (find counts matches
    /// from the start); with one that matches nothing, both passes must paint the same pixels.
    @Test func drawingAStripMatchesWalkingEveryItem() throws {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 680, height: 100))
        view.document = MarkdownDocument(parsing: "Intro with `Sources/App/main.swift`.\n\n" + String(repeating: Self.unit, count: 6))
        let height = view.height(forWidth: 680).rounded(.up)
        view.frame = NSRect(x: 0, y: 0, width: 680, height: height)
        view.layoutSubtreeIfNeeded()
        for fraction in [0.0, 0.15, 0.5, 0.85] {
            let rect = NSRect(x: 0, y: (height * fraction).rounded(), width: 680, height: 160)
            let ranged = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: ranged)
            view.threadFindQuery = "qqzzqqzz"
            let walked = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: walked)
            view.threadFindQuery = ""
            var differing = 0, inked = 0
            for y in 0..<ranged.pixelsHigh {
                for x in stride(from: 0, to: ranged.pixelsWide, by: 2) {
                    let pixel = ranged.colorAt(x: x, y: y)
                    if pixel != walked.colorAt(x: x, y: y) { differing += 1 }
                    if (pixel?.alphaComponent ?? 0) > 0 { inked += 1 }
                }
            }
            #expect(inked > 0, "strip at \(fraction) drew nothing")
            #expect(differing == 0, "strip at \(fraction): \(differing) pixels differ")
        }
    }

    /// The byte scan for open fences answers as the Character split does, line endings and indents included.
    @Test func openFenceScanMatchesTheSplit() {
        let pieces = ["```", "````", "~~~", "``` js", "```x`", "  ```", "\t~~~~", "text", "", " ", "`", "~~", "\r", "\n", "\r\n", "é", "```  "]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3_000 {
            var text = ""
            for _ in 0..<Int.random(in: 0...12, using: &generator) {
                text += pieces.randomElement(using: &generator)!
                if Bool.random(using: &generator) { text += ["\n", "\r", "\r\n"].randomElement(using: &generator)! }
            }
            #expect(MarkdownLayout.endsInOpenFence(text) == MarkdownLayout.endsInOpenFence(characters: text), "\(text.debugDescription)")
        }
    }
}
