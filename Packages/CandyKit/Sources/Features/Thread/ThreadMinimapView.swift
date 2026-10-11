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
        if hovered == index { showPreview() }
    }
    public var currentIndex: Int? { didSet { if currentIndex != oldValue { needsDisplay = true; updateNavigation() } } }
    public var persistentGutter = true { didSet { if persistentGutter != oldValue { needsDisplay = true } } }
    private let previous = ButtonView(icon: .chevronUp, variant: .ghost, size: .iconXs)
    private let next = ButtonView(icon: .chevronDown, variant: .ghost, size: .iconXs)
    private weak var previewPopup: OpenPopup?
    public override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(previous); addSubview(next)
        previous.toolTip = "Previous turn"; next.toolTip = "Next turn"
        previous.setAccessibilityLabel("Previous turn"); next.setAccessibilityLabel("Next turn")
        previous.action = { [weak self] in self?.navigate(-1) }
        next.action = { [weak self] in self?.navigate(1) }
        updateNavigation()
    }
    private func navigate(_ delta: Int) {
        let index = (currentIndex ?? 0) + delta
        guard items.indices.contains(index) else { return }
        onSelect?(items[index].id)
    }
    private func updateNavigation() {
        previous.isEnabled = (currentIndex ?? 0) > 0
        next.isEnabled = (currentIndex ?? 0) < items.count - 1
        previous.alphaValue = hovered == nil ? 0 : 1; next.alphaValue = previous.alphaValue
    }
    public override func layout() {
        super.layout()
        previous.frame = NSRect(x: -8, y: -26, width: 24, height: 24)
        next.frame = NSRect(x: -8, y: bounds.height + 2, width: 24, height: 24)
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [previous, next] where button.alphaValue > 0 && button.frame.contains(local) { return button }
        return super.hitTest(point)
    }
    private func showPreview() {
        if let previewPopup { popupHost?.close(previewPopup, returnFocus: false) }
        guard let hovered, items.indices.contains(hovered), let host = popupHost else { return }
        let content = ThreadMinimapPreviewView(item: items[hovered])
        let popover = PopoverView(content: content, padding: .compact, width: .md)
        let y = CGFloat(hovered) / CGFloat(max(1, items.count - 1)) * bounds.height
        previewPopup = host.open(popover, trigger: self, anchorRect: NSRect(x: 24, y: y, width: 1, height: 2),
            placement: PopupPlacement(side: .right, align: .center, sideOffset: 8), pressesTrigger: false, returnsFocus: false, passive: true)
    }
    public override func viewDidMoveToWindow() {
        if window == nil, let previewPopup { previewPopup.content.popupHost?.close(previewPopup, returnFocus: false) }
        super.viewDidMoveToWindow()
    }
    public var onSelect: ((String) -> Void)?
    private var hovered: Int? { didSet {
        guard hovered != oldValue else { return }
        toolTip = nil; needsDisplay = true; updateNavigation(); showPreview()
    } }
    private var tracking: NSTrackingArea?
    public override var wantsUpdateLayer: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -8, dy: -28), options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        tracking = area; addTrackingArea(area)
    }
    private func index(_ event: NSEvent) -> Int? {
        guard !items.isEmpty else { return nil }
        let y = convert(event.locationInWindow, from: nil).y
        return max(0, min(items.count - 1, Int((y / max(1, bounds.height) * CGFloat(items.count - 1)).rounded())))
    }
    public override func mouseEntered(with event: NSEvent) { hovered = index(event) }
    public override func mouseMoved(with event: NSEvent) { hovered = index(event) }
    public override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !bounds.insetBy(dx: -8, dy: -28).contains(point) { hovered = nil }
    }
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
        guard persistentGutter || hovered != nil else { return }
        for i in items.indices {
            let distance = hovered.map { abs(i - $0) }
            let width: CGFloat = distance == 0 ? 24 : distance == 1 ? 16 : distance == 2 ? 10 : 8
            Themed.color(i == currentIndex ? \.foreground : \.mutedForeground, i == currentIndex ? 0.9 : distance == 0 ? 0.75 : 0.35).setFill()
            let y = CGFloat(i) / CGFloat(max(1, items.count - 1)) * max(0, bounds.height - 2)
            NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// MessagesTimeline.tsx:1907-1931. The preview is built only while a strip is hovered.
private final class ThreadMinimapPreviewView: DSView {
    private let user: LabelView
    private let assistant: TextBlockView
    init(item: ThreadMinimapItem) {
        user = LabelView(item.userText, font: DSFont.ui(14, weight: .medium))
        user.lineHeight = 20
        assistant = TextBlockView(item.assistantText ?? "", font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.mutedForeground))
        assistant.maxLines = 3
        super.init(frame: .zero)
        addSubview(user); addSubview(assistant)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 294, height: 20 + (assistant.text.isEmpty ? 0 : 4 + assistant.height(forWidth: 294))) }
    override func layout() {
        super.layout(); user.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        assistant.frame = NSRect(x: 0, y: 24, width: bounds.width, height: max(0, bounds.height - 24))
    }
}
