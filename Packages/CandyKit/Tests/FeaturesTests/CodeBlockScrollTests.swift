import AppKit
import DesignSystem
import Testing
@testable import Features

/// Code blocks with wrapping off scroll sideways (`.chat-markdown pre { overflow-x: auto }`, index.css:1961-1985),
/// and only sideways gestures stay with them.
@MainActor
struct CodeBlockScrollTests {
    static let markdown = "```swift\nlet value = \"" + String(repeating: "x", count: 200) + "\"\n```\n\nAfter."

    private final class Recorder: NSResponder {
        var events = 0
        override func scrollWheel(with event: NSEvent) { events += 1 }
    }

    /// A view with its one code block unwrapped through the header's wrap button.
    private func unwrappedView() -> MarkdownView {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        view.setMarkdown(Self.markdown)
        view.layoutSubtreeIfNeeded()
        let wrap = view.subviews.compactMap { $0 as? ButtonView }.first { $0.accessibilityLabel() == "Disable line wrap" }
        wrap?.action?()
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func scroller(_ view: MarkdownView) -> (index: Int, viewport: CGRect, contentWidth: CGFloat)? {
        view.layout(forWidth: 400).items.lazy.compactMap {
            if case .scroll(let i, let r, let w) = $0 { (i, r, w) } else { nil }
        }.first
    }

    private func wheel(_ view: MarkdownView, dx: Int32, dy: Int32, at point: CGPoint) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // A window-less event's location is in the view's base space, y up; the view is flipped.
        let screen = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: point.x, y: screen - (view.bounds.height - point.y))
        return NSEvent(cgEvent: cg)!
    }

    @Test func wrappedBlockHasNoScroller() {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        view.setMarkdown(Self.markdown)
        #expect(scroller(view) == nil)
        // With the `wordWrap` setting off blocks start unwrapped, and the toggle wraps them.
        let unwrapped = MarkdownLayout(document: view.document, width: 400, wrapsCode: false)
        #expect(unwrapped.items.contains { if case .scroll = $0 { true } else { false } })
        let toggled = MarkdownLayout(document: view.document, width: 400, wrapsCode: false, unwrappedCode: [0])
        #expect(!toggled.items.contains { if case .scroll = $0 { true } else { false } })
    }

    @Test func overflowingBlockGrowsByTheScrollbarLane() throws {
        let wrapped = MarkdownView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        wrapped.setMarkdown("```swift\nlet a = 1\n```")
        let short = MarkdownLayout(document: wrapped.document, width: 400, unwrappedCode: [0])
        let fits = MarkdownLayout(document: wrapped.document, width: 400)
        #expect(short.height == fits.height)

        let view = unwrappedView()
        let s = try #require(scroller(view))
        #expect(s.contentWidth > s.viewport.width)
        let oneLine = MarkdownLayout(document: MarkdownDocument(parsing: "```swift\nlet value = 1\n```\n\nAfter."), width: 400, unwrappedCode: [0])
        #expect(view.layout(forWidth: 400).height == oneLine.height + MarkdownStyle.codeScrollbar)
        let thumb = try #require(MarkdownView.codeThumb(s.viewport, s.contentWidth, 0))
        #expect(thumb.minX == s.viewport.minX && thumb.maxY == s.viewport.maxY && thumb.height == 7)
        let end = try #require(MarkdownView.codeThumb(s.viewport, s.contentWidth, s.contentWidth - s.viewport.width))
        #expect(abs(end.maxX - s.viewport.maxX) < 0.001)
    }

    @Test func findRevealsAMatchPastTheRightEdge() throws {
        let view = unwrappedView()
        let s = try #require(scroller(view))
        view.threadFindQuery = "xxxx\""
        view.threadFindOccurrence = 0
        let rect = try #require(view.activeFindRect())
        #expect((view.codeOffsets[s.index] ?? 0) > 0)
        #expect(rect.maxX <= s.viewport.maxX && rect.minX >= s.viewport.minX)
    }

    @Test func sidewaysScrollsTheBlockAndVerticalPassesUp() throws {
        let view = unwrappedView()
        view.frame.size.height = view.layout(forWidth: 400).height
        let recorder = Recorder()
        view.nextResponder = recorder
        let s = try #require(scroller(view))
        let inside = CGPoint(x: s.viewport.midX, y: s.viewport.midY)

        view.scrollWheel(with: wheel(view, dx: -30, dy: 0, at: inside))
        #expect(view.codeOffsets[s.index] == 30)
        #expect(recorder.events == 0)

        view.scrollWheel(with: wheel(view, dx: -2, dy: -20, at: inside))
        #expect(view.codeOffsets[s.index] == 30)
        #expect(recorder.events == 1)

        // Outside the block a sideways wheel goes up as well.
        view.scrollWheel(with: wheel(view, dx: -30, dy: 0, at: CGPoint(x: 10, y: view.bounds.maxY - 4)))
        #expect(recorder.events == 2)

        // Clamped at both ends.
        view.scrollWheel(with: wheel(view, dx: 10_000, dy: 0, at: inside))
        #expect(view.codeOffsets[s.index] == 0)
        view.scrollWheel(with: wheel(view, dx: -10_000, dy: 0, at: inside))
        #expect(view.codeOffsets[s.index] == s.contentWidth - s.viewport.width)
    }
}
