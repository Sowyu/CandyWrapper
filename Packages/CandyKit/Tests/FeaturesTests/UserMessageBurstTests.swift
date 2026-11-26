import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// A burst of your messages (TimelineUserMessageRow.tsx:839, 917-920, 1104-1122 and MessagesTimeline.tsx:1644 at 4928):
/// joined corners, `pb-1` between them, and the actions beside the bubble on a wide lane.
@MainActor
struct UserMessageBurstTests {
    static func item(next: Bool, previous: Bool) -> TimelineItem {
        let message = ChatMessage(id: MessageId("prompt"), role: .user, text: "Hello there", createdAt: T3Timestamp("2026-10-29T12:00:00Z"))
        var row = TimelineRow(id: "prompt", createdAt: message.createdAt,
            kind: .message(message, projectedItem: nil, showAssistantMeta: false,
                           showAssistantCopyButton: false, assistantCopyStreaming: false))
        row.groupedWithNext = next
        row.groupedWithPrevious = previous
        return TimelineItem(row: row)
    }

    @Test func burstRowsSitCloserAndFloatTheirActionsOnWideLanes() {
        let view = UserMessageRowView()
        view.context = TimelineContext()
        view.configure(Self.item(next: false, previous: false))
        let narrowAlone = view.height(forWidth: 480), wideAlone = view.height(forWidth: 700)
        view.configure(Self.item(next: true, previous: false))
        // `pb-1` replaces `pb-4`; from `@min-[37rem]` the hover line moves beside the bubble.
        #expect(view.height(forWidth: 480) == narrowAlone - 12)
        #expect(view.height(forWidth: 700) == wideAlone - 12 - 28)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: view.height(forWidth: 700))
        view.layoutSubtreeIfNeeded()
        let bubble = view.subviews.compactMap { $0 as? FillView }.first { $0.frame.width > 0 && $0.frame.height > 40 }
        let copy = view.subviews.compactMap { $0 as? ButtonView }.first { !$0.isHidden && $0.frame.maxX > 0 && $0.frame.maxX < (bubble?.frame.minX ?? 0) }
        #expect(copy != nil, "the copy button sits left of the bubble")
        if let copy, let bubble { #expect(copy.frame.maxX == bubble.frame.minX - 8) }
    }

    @Test func joinedCornersTighten() {
        func render(top: Bool, bottom: Bool) -> NSBitmapImageRep {
            let fill = FillView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
            fill.fill = .systemRed
            fill.radius = 16
            fill.joinedTop = top
            fill.joinedBottom = bottom
            let rep = PickersFidelityTests.render(fill, size: CGSize(width: 100, height: 60), backdrop: .white, dark: false)
            return rep
        }
        func red(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> Bool {
            let c = PickersFidelityTests.color(rep, x, y)
            return c.redComponent > 0.8 && c.greenComponent < 0.5
        }
        let plain = render(top: false, bottom: false)
        #expect(!red(plain, 97, 3) && !red(plain, 97, 57) && red(plain, 50, 30))
        let top = render(top: true, bottom: false)
        #expect(red(top, 97, 3))
        #expect(!red(top, 97, 57))
        #expect(!red(top, 3, 3))
        #expect(red(top, 50, 30))
        let bottom = render(top: false, bottom: true)
        #expect(!red(bottom, 97, 3))
        #expect(red(bottom, 97, 57))
        #expect(!red(bottom, 3, 57))
    }
}
