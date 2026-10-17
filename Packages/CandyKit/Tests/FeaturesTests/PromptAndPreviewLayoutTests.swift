import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct PromptAndPreviewLayoutTests {
    static func item(images: Int, text: String) -> TimelineItem {
        let attachments: [JSONValue] = (0..<images).map { .object([
            "id": .string("image-\($0)"), "type": .string("image"),
            "name": .string("sample-\($0).png"), "mimeType": .string("image/png")
        ]) }
        let message = ChatMessage(id: MessageId("prompt"), role: .user, text: text,
            createdAt: T3Timestamp("2026-10-17T12:00:00Z"), attachments: attachments)
        return TimelineItem(row: TimelineRow(id: "prompt", createdAt: message.createdAt,
            kind: .message(message, projectedItem: nil, showAssistantMeta: false,
                           showAssistantCopyButton: false, assistantCopyStreaming: false, turnDiffSummary: nil)))
    }

    @Test func imagesNeverConsumeThePromptsCollapsedHeight() throws {
        let text = (1...16).map { "Prompt line \($0): keep this text below the attached images." }.joined(separator: "\n")
        for width: CGFloat in [320, 736] {
            for count in [1, 2, 5, 10] {
                var plain = Self.item(images: 0, text: text)
                var attached = Self.item(images: count, text: text)
                let row = UserMessageRowView()
                row.context = TimelineContext()
                row.configure(plain)
                let plainCollapsed = row.height(forWidth: width)
                row.configure(attached)
                let attachedCollapsed = row.height(forWidth: width)
                row.frame = CGRect(x: 0, y: 0, width: width, height: attachedCollapsed)
                row.layoutSubtreeIfNeeded()
                let grid = try #require(row.subviews.compactMap { $0 as? UserMessageAttachmentsView }.first)
                let bubble = try #require(row.subviews.first { $0.subviews.contains { $0 is MarkdownView } })
                let markdown = try #require(bubble.subviews.compactMap { $0 as? MarkdownView }.first)
                let toggle = try #require(bubble.subviews.compactMap { $0 as? ButtonView }.first)
                #expect(grid.frame.maxY <= bubble.frame.maxY)
                #expect(markdown.convert(markdown.bounds, to: row).minY == grid.frame.maxY)
                #expect(toggle.frame.minY >= markdown.frame.minY + 176)
                #expect(abs(attachedCollapsed - plainCollapsed - grid.frame.height) < 0.01)
                plain.ui.messageExpanded = true
                attached.ui.messageExpanded = true
                row.configure(plain)
                let plainExpanded = row.height(forWidth: width)
                row.configure(attached)
                let attachedExpanded = row.height(forWidth: width)
                #expect(abs((attachedExpanded - attachedCollapsed) - (plainExpanded - plainCollapsed)) < 0.01)
            }
        }
    }

    @Test func shortPromptsAndImagesOnlyKeepTheirFullHeight() throws {
        for text in ["", "Please check these five screenshots."] {
            let row = UserMessageRowView()
            row.context = TimelineContext()
            var item = Self.item(images: 5, text: text)
            row.configure(item)
            let collapsed = row.height(forWidth: 736)
            item.ui.messageExpanded = true
            row.configure(item)
            #expect(row.height(forWidth: 736) == collapsed)
        }
    }

    @Test func floatingPreviewAvoidsDetailsAndComposer() {
        let canvas = CGRect(x: 0, y: 52, width: 868, height: 728)
        let details = CGRect(x: 576, y: 64, width: 280, height: 285)
        let composer = CGRect(x: 48, y: 616, width: 736, height: 144)
        for origin in [nil, CGPoint(x: 540, y: 90), CGPoint(x: 400, y: 640)] {
            let frame = BrowserMiniPlayerView.frame(size: CGSize(width: 320, height: 233), origin: origin,
                container: canvas, composer: composer, details: details)
            #expect(!frame.intersects(details))
            #expect(!frame.intersects(composer))
            #expect(canvas.contains(frame))
        }
    }


    @Test func floatingPreviewAndControlBarStayOpaqueInGlass() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var glass = ThemeRuntimeInput(glassOpacity: 10)
        glass.glassLight = true; glass.glassDark = true
        ThemeRuntime.apply(glass)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let preview = BrowserMiniPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 233))
            preview.appearance = NSAppearance(named: appearance)
            preview.layoutSubtreeIfNeeded()
            preview.updateLayer()
            preview.viewer.updateLayer()
            let card = try #require(preview.subviews.first)
            #expect(card.layer?.backgroundColor?.alpha == 1)
            #expect(preview.viewer.bar.layer?.backgroundColor?.alpha == 1)
        }
    }

    @Test func floatingPreviewFitsSmallCanvases() {
        let canvas = CGRect(x: 0, y: 52, width: 280, height: 400)
        let composer = CGRect(x: 12, y: 300, width: 256, height: 130)
        let frame = BrowserMiniPlayerView.frame(size: CGSize(width: 320, height: 233), origin: nil,
            container: canvas, composer: composer)
        #expect(canvas.contains(frame))
        #expect(!frame.intersects(composer))
        // When no space exists beside or below a tall card, T3 keeps the fallback in the canvas.
        let crowded = BrowserMiniPlayerView.frame(size: CGSize(width: 320, height: 233), origin: nil,
            container: canvas, composer: composer, details: CGRect(x: 0, y: 64, width: 280, height: 340))
        #expect(canvas.contains(crowded))
    }
}
