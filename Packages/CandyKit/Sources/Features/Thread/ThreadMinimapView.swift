import AppKit
import DesignSystem
import T3Store

/// timelineMinimapItems.ts:15-77. Keep the source text until a preview is requested.
public struct ThreadMinimapItem: Equatable, Sendable {
    public var id: String
    public var rowIndex: Int
    public var userText: String
    public var assistantText: String?
    var assistantRowIndex: Int?
    public static func derive(_ rows: [TimelineRow]) -> [Self] {
        var result: [Self] = []
        for (index, row) in rows.enumerated() {
            guard case .message(let message, _, _, _, _, _) = row.kind else { continue }
            if message.role == .user {
                result.append(Self(id: row.id, rowIndex: index, userText: message.text))
            } else if message.role == .assistant, !result.isEmpty {
                result[result.count - 1].assistantText = message.text
                result[result.count - 1].assistantRowIndex = index
            }
        }
        return result
    }
    public var preview: String {
        ([userText, assistantText].compactMap { $0 }).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: "\n\n")
    }
}

/// MessagesTimeline.tsx:1785-1934. The strip redraws only after a scroll, content or hover change.
// ponytail: native tooltip and wide gutter only, add rich preview and narrow-gutter affordances when the source popover is ported.
public final class ThreadMinimapView: DSView {
    public var items: [ThreadMinimapItem] = [] { didSet {
        guard !updatingPreview else { return }
        if let hovered, !items.indices.contains(hovered) { self.hovered = nil }
        if items != oldValue { needsDisplay = true }
    } }
    private var updatingPreview = false
    /// Text does not affect the strip geometry. Avoid comparing every item on each streamed token.
    func updatePreview(at index: Int, text: String, assistant: Bool) {
        guard items.indices.contains(index) else { return }
        updatingPreview = true
        if assistant { items[index].assistantText = text } else { items[index].userText = text }
        updatingPreview = false
        if hovered == index { toolTip = items[index].preview }
    }
    public var currentIndex: Int? { didSet { if currentIndex != oldValue { needsDisplay = true } } }
    public var onSelect: ((String) -> Void)?
    private var hovered: Int? { didSet {
        guard hovered != oldValue else { return }
        toolTip = hovered.map { items[$0].preview }; needsDisplay = true
    } }
    private var tracking: NSTrackingArea?
    public override var wantsUpdateLayer: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area)
    }
    private func index(_ event: NSEvent) -> Int? {
        guard !items.isEmpty else { return nil }
        let y = convert(event.locationInWindow, from: nil).y
        return max(0, min(items.count - 1, Int((y / max(1, bounds.height) * CGFloat(items.count - 1)).rounded())))
    }
    public override func mouseMoved(with event: NSEvent) { hovered = index(event) }
    public override func mouseExited(with event: NSEvent) { hovered = nil }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let i = index(event) { hovered = i; onSelect?(items[i].id) }
    }
    public override func keyDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        switch event.keyCode {
        case 125: hovered = min(items.count - 1, (hovered ?? currentIndex ?? -1) + 1)
        case 126: hovered = max(0, (hovered ?? currentIndex ?? 1) - 1)
        case 115: hovered = 0
        case 119: hovered = items.count - 1
        case 36, 49: onSelect?(items[min(items.count - 1, max(0, hovered ?? currentIndex ?? 0))].id)
        default: super.keyDown(with: event)
        }
    }
    public override func draw(_ dirtyRect: NSRect) {
        for i in items.indices {
            let distance = hovered.map { abs(i - $0) }
            let width: CGFloat = distance == 0 ? 24 : distance == 1 ? 16 : distance == 2 ? 10 : 8
            Themed.color(i == currentIndex ? \.foreground : \.mutedForeground, i == currentIndex ? 0.9 : distance == 0 ? 0.75 : 0.35).setFill()
            let y = CGFloat(i) / CGFloat(max(1, items.count - 1)) * max(0, bounds.height - 2)
            NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}
