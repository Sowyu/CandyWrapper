import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

extension WebFrameSuites {
    @MainActor
    struct McpFullscreenTests {
        private func fixture() throws -> (NSWindow, McpAppRowView, ThreadWebFrameView) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let row = McpAppRowView(frame: NSRect(x: 0, y: 0, width: 700, height: 328))
            row.context = TimelineContext()
            window.contentView?.addSubview(row)
            let app = try #require(McpAppReference(.object([
                "attachmentId": .string("capture"), "server": .string("Blender sandbox"),
                "tool": .string("capture"), "resourceUri": .string("ui://capture")
            ])))
            let entry = McpAppEntry(app: app, sourceThreadId: ThreadId("sandbox"), itemId: TurnItemId("capture"), revision: "1")
            row.configure(TimelineItem(row: TimelineRow(id: "capture", createdAt: nil, kind: .mcpApp(entry))))
            let frame = try #require(row.subviews.compactMap { $0 as? ThreadWebFrameView }.first)
            frame.activate(.init(src: URL(string: "http://capture.invalid/capture.html")!, title: "Capture", dark: true))
            return (window, row, frame)
        }

        @Test func backgroundRequestsStayInlineAndTheExpandButtonWorks() throws {
            let (window, row, frame) = try fixture()
            defer { row.prepareForReuse(); _ = window }
            #expect(row.setDisplayMode("fullscreen") == "inline")
            #expect(frame.superview === row)
            let button = try #require(row.subviews.compactMap { $0 as? ButtonView }
                .first { $0.accessibilityLabel() == "Open app full screen" })
            #expect(!button.isHidden)
            button.action?()
            #expect(frame.superview !== row)
            #expect(button.isHidden)
            #expect(row.setDisplayMode("inline") == "inline")
            #expect(frame.superview === row)
            #expect(!button.isHidden)
            // A delayed request after dismissal must not reopen the overlay.
            #expect(row.setDisplayMode("fullscreen") == "inline")
        }

        @Test func fullscreenSurvivesNewInlineResultsAndRestoresScrolling() throws {
            let (window, row, frame) = try fixture()
            let otherFrames = (0...ThreadWebFrameBudget.limit).map { _ in ThreadWebFrameView(frame: .zero) }
            defer { otherFrames.forEach { $0.release() }; row.prepareForReuse(); _ = window }
            let web = try #require(frame.webView)
            #expect(row.setDisplayMode("fullscreen", userInitiated: true) == "fullscreen")
            #expect(!web.forwardsScroll)
            for other in otherFrames {
                other.activate(.init(src: URL(string: "http://other.invalid/other.html")!, title: "Other", dark: true))
            }
            #expect(frame.webView === web)
            #expect(!frame.budgeted)
            frame.superview?.cancelOperation(nil)
            #expect(frame.superview === row)
            #expect(web.forwardsScroll && frame.budgeted)
            #expect(ThreadWebFrameBudget.count <= ThreadWebFrameBudget.limit)
            row.prepareForReuse()
            #expect(!frame.isLive)
            #expect(row.setDisplayMode("fullscreen", userInitiated: true) == "inline")
        }
    }
}
