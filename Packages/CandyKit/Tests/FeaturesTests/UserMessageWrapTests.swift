import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Long text in a user bubble wraps inside it, and a code block's wrap toggle resizes the row.
@MainActor
struct UserMessageWrapTests {
    static func row(_ text: String) -> (UserMessageRowView, TimelineItem) {
        let message = ChatMessage(id: MessageId("prompt"), role: .user, text: text, createdAt: T3Timestamp("2026-10-29T12:00:00Z"))
        let item = TimelineItem(row: TimelineRow(id: "prompt", createdAt: message.createdAt,
            kind: .message(message, projectedItem: nil, showAssistantMeta: false,
                           showAssistantCopyButton: false, assistantCopyStreaming: false, turnDiffSummary: nil)))
        let row = UserMessageRowView()
        row.context = TimelineContext()
        row.configure(item)
        return (row, item)
    }

    static func markdown(in view: NSView) -> MarkdownView? {
        (view as? MarkdownView) ?? view.subviews.lazy.compactMap { markdown(in: $0) }.first
    }

    @Test func longBulletsWrapInsideTheBubble() throws {
        let previous = ThemeRuntime.input, previousFont = FontRuntime.input
        defer { ThemeRuntime.apply(previous); FontRuntime.apply(previousFont) }
        let text = "My hardware:\n\n" + (1...4).map { "- Item \($0) runs on a long line of words that cannot fit in one line of the bubble" }.joined(separator: "\n")
        for redesign in [false, true] {
            var theme = ThemeRuntimeInput(); theme.ditherLight = redesign; theme.ditherDark = redesign
            ThemeRuntime.apply(theme)
            for mono in [false, true] {
                var font = FontRuntimeInput(); if mono { font.interfaceFamily = "Menlo" }
                FontRuntime.apply(font)
                let (row, _) = Self.row(text)
                let width: CGFloat = 480
                row.frame = CGRect(x: 0, y: 0, width: width, height: row.height(forWidth: width))
                row.layoutSubtreeIfNeeded()
                let markdown = try #require(Self.markdown(in: row))
                var lines = 0
                for case .text(let box, let origin) in markdown.layout(forWidth: markdown.bounds.width).items {
                    #expect(origin.x + box.usedWidth <= markdown.bounds.width + 0.5, "redesign \(redesign), mono \(mono): \(box.text)")
                    lines += box.lineCount
                }
                // Each item wraps to at least two lines.
                #expect(lines >= 1 + 4 * 2)
            }
        }
    }

    @Test func codeWrapToggleRemeasuresTheRow() throws {
        let code = "```\n" + (1...3).map { "line \($0) of a code block long enough to wrap twice inside a narrow user message bubble" }.joined(separator: "\n") + "\n```"
        let (row, item) = Self.row(code)
        var remeasured: [String] = []
        row.context.onMarkdownHeightChange = { remeasured.append($0) }
        let width: CGFloat = 480
        let wrapped = row.height(forWidth: width)
        row.frame = CGRect(x: 0, y: 0, width: width, height: wrapped)
        row.layoutSubtreeIfNeeded()
        let markdown = try #require(Self.markdown(in: row))
        markdown.toggleWrap(0)
        #expect(remeasured == [item.id])
        #expect(row.height(forWidth: width) < wrapped)
        // A recycled row takes the choice back.
        let (other, _) = Self.row("Another prompt")
        other.context = row.context
        other.configure(item)
        #expect(other.height(forWidth: width) == row.height(forWidth: width))
    }
}
