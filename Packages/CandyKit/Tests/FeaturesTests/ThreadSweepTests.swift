import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct ThreadSweepTests {
    @Test func detailsKeepsReadableLaneAndRestoresCenteredLayout() throws {
        #expect(ThreadDetailsPlacement.inlineCard(width: 1011, height: 700) == nil)
        let card = try #require(ThreadDetailsPlacement.inlineCard(width: 1012, height: 700))
        #expect(card.width == 280)
        let lane = ThreadDetailsPlacement.lane(width: 1012, maximum: 736, padding: 48, cardLeft: card.minX)
        #expect(lane.x == 48 && lane.width == 640)
        #expect(lane.x + lane.width + 32 == card.minX)
        #expect(ThreadDetailsPlacement.lane(width: 1200, maximum: 736, padding: 48, cardLeft: nil).x == 232)
        #expect(ThreadDetailsPlacement.inlineCard(width: 1200, height: 175) == nil)
    }
    @Test func taskDetailsWrapAndReleaseWhenCollapsed() {
        let row = ThreadTaskStepView(step: .init(text: String(repeating: "A long task label ", count: 8), status: "running"))
        #expect(row.height(forWidth: 220) > row.height(forWidth: 600))
    }
    @Test func imageBlocksRemainGalleryTargets() {
        let markdown = MarkdownView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        markdown.setMarkdown("![First](https://example.org/one.png)\n\n![Second](https://example.org/two.png)")
        let images = markdown.layout(forWidth: 600).items.compactMap { item -> URL? in
            if case .remoteImage(let url, _, _) = item { return url }; return nil
        }
        #expect(images.count == 2)
        #expect(images[1].lastPathComponent == "two.png")
    }
    @Test func goalUsesSharedDurationIncludingHoursAndSeconds() throws {
        let goal = try JSONValue.object(["objective": .string("Finish"), "status": .string("complete"), "timeUsedSeconds": .number(3661)]).decode(as: ProviderGoal.self)
        #expect(ThreadGoalPresentation.title(goal, working: false).contains("1h 1m 1s"))
    }
    @Test func longToolOutputGetsScrollableDocument() {
        var detail = WorkDetail(); detail.blocks = [(String(repeating: "Output line\n", count: 60), .output)]
        let view = WorkDetailView(frame: NSRect(x: 0, y: 0, width: 400, height: 320)); view.detail = detail
        view.layoutSubtreeIfNeeded()
        let scroller = view.subviews.compactMap { $0 as? NSScrollView }.first
        #expect(scroller?.isHidden == false)
        #expect((scroller?.documentView?.frame.height ?? 0) > 320)
    }
    @Test func appDownloadRejectsMalformedBlocksAndSanitizesNames() {
        let input: JSONValue = .array([.object(["type": .string("resource"), "resource": .object(["name": .string("../bad:name.txt"), "text": .string("hello")])])])
        let files = ThreadMcpAppDownload.read(input)
        #expect(files?.first?.name == "..-bad-name.txt")
        #expect(files?.first?.bytes == Data("hello".utf8))
        #expect(ThreadMcpAppDownload.read(.array([])) == nil)
        #expect(ThreadMcpAppDownload.read(.array([.object(["type": .string("text"), "text": .string("wrong")])])) == nil)
    }
}
