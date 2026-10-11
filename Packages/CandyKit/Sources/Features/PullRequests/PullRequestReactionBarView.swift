import AppKit
import DesignSystem
import T3Protocol

/// `PullRequestReactionBar` (PullRequestReactions.tsx:38-169): a pill per reaction (emoji and
/// count, `h-6 rounded-full border px-2 text-xs`, primary tinted when the reader reacted) and the
/// always-visible picker. A press shows at once (`applyPendingPullRequestReactions`) and is
/// forgotten once the host's counts move; the caller sends `pullRequests.setReaction`.
public final class PullRequestReactionBarView: DSView {
    public var reactions: [PullRequestReaction] = [] { didSet { rebuild() } }
    public var canReact = false { didSet { rebuild() } }
    /// Presses in flight, cleared when `reactions` moves on.
    private var pending: (signature: String, values: [String: Bool]) = ("", [:])
    /// (content, reacted): the caller sends the press and calls `pressFailed` when the host refuses.
    public var onToggle: ((String, Bool) -> Void)?
    private var pills: [PullRequestReactionPill] = []
    private let add = PullRequestReactionPill(addButton: ())

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(add)
        add.action = { [weak self] in self?.showPicker() }
        add.setAccessibilityLabel("Add a reaction")
        rebuild()
    }

    private var shown: [PullRequestReaction] {
        let values = pending.signature == PullRequestReactions.signature(reactions) ? pending.values : [:]
        return PullRequestReactions.applyPending(reactions, values)
    }

    private func toggle(_ content: String, _ reacted: Bool) {
        let sig = PullRequestReactions.signature(reactions)
        var values = pending.signature == sig ? pending.values : [:]
        values[content] = reacted
        pending = (sig, values)
        rebuild()
        onToggle?(content, reacted)
    }

    /// The host refused: the pill goes back (lines 80-87).
    public func pressFailed(_ content: String) {
        pending.values[content] = nil
        rebuild()
    }

    private func rebuild() {
        pills.forEach { $0.removeFromSuperview() }
        pills = shown.map { r in
            let p = PullRequestReactionPill(reaction: r, enabled: canReact)
            p.action = { [weak self] in self?.toggle(r.content, !r.viewerHasReacted) }
            p.toolTip = PullRequestReactions.tooltip(r)
            addSubview(p)
            return p
        }
        add.isHidden = !canReact
        isHidden = pills.isEmpty && !canReact
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func showPicker() {
        let row = PullRequestReactionPickerView(reacted: Set(shown.filter(\.viewerHasReacted).map(\.content)))
        let popover = PopoverView(content: row, padding: .compact)
        let open = popover.show(from: add, placement: PopupPlacement(side: .top, align: .start, sideOffset: 4, fallbackAxisSide: .end))
        row.onPick = { [weak self] content, reacted in
            if let open { self?.add.popupHost?.close(open) }
            self?.toggle(content, reacted)
        }
    }

    /// `gap-1` between pills.
    public var width: CGFloat {
        let all = pills.map(\.preferredWidth) + (add.isHidden ? [] : [add.preferredWidth])
        return all.reduce(0, +) + CGFloat(max(0, all.count - 1)) * 4
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: width, height: 24) }

    /// Right aligned (`ml-auto justify-end`).
    public override func layout() {
        super.layout()
        var x = bounds.width - width
        for p in pills + (add.isHidden ? [] : [add]) {
            p.frame = NSRect(x: x, y: (bounds.height - 24) / 2, width: p.preferredWidth, height: 24)
            x += p.preferredWidth + 4
        }
    }
}

/// One pill, or the picker trigger (`px-1.5`, smile-plus).
final class PullRequestReactionPill: DSView {
    private let emoji = LabelView("", font: DSFont.ui(12))
    private let count = LabelView("", font: DSFont.ui(12))
    private let icon: IconView?
    private let reacted: Bool
    private let enabled: Bool
    private var hovered = false { didSet { needsDisplay = true } }
    var action: (() -> Void)?

    init(reaction r: PullRequestReaction, enabled: Bool) {
        reacted = r.viewerHasReacted
        self.enabled = enabled
        icon = nil
        super.init(frame: .zero)
        emoji.text = PullRequestReactions.emoji(r.content)
        count.text = "\(r.count)"
        for l in [emoji, count] { l.lineHeight = 16; addSubview(l) }
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(PullRequestReactions.name(r.content)), \(r.count)")
        trackHover()
    }

    init(addButton: ()) {
        reacted = false
        enabled = true
        icon = IconView(name: .smilePlus, size: 14)
        super.init(frame: .zero)
        addSubview(icon!)
        setAccessibilityRole(.button)
        trackHover()
    }

    private func trackHover() {
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    var preferredWidth: CGFloat {
        if icon != nil { return 6 + 14 + 6 + 2 }
        return 8 + ceil(emoji.textWidth) + 4 + ceil(count.textWidth) + 8 + 2
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.borderWidth = 1
        if let icon { icon.frame = NSRect(x: 7, y: 5, width: 14, height: 14); return }
        let ew = ceil(emoji.textWidth) + 1
        emoji.frame = NSRect(x: 9, y: 4, width: ew, height: 16)
        count.frame = NSRect(x: 9 + ew + 3, y: 4, width: ceil(count.textWidth) + 1, height: 16)
    }

    override func updateLayer() {
        let primary = Themed.color(\.primary, 0.6)
        if reacted {
            layer?.borderColor = primary.cgColor(in: self)
            layer?.backgroundColor = Themed.color(\.primary, 0.1).cgColor(in: self)
            count.color = Themed.color(\.foreground)
        } else {
            layer?.borderColor = (hovered && enabled ? primary : Themed.color(\.border, 0.7)).cgColor(in: self)
            layer?.backgroundColor = icon == nil ? Themed.color(\.muted, 0.4).cgColor(in: self) : nil
            count.color = Themed.color(\.mutedForeground)
        }
        icon?.strokeColor = hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
    }

    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
    override func accessibilityPerformPress() -> Bool { if enabled { action?() }; return enabled }
}

/// The picker (`flex items-center gap-0.5`): eight `size-7 rounded-md text-base` buttons, the
/// reader's own tinted `bg-primary/10`.
final class PullRequestReactionPickerView: DSView {
    private var buttons: [(content: String, label: LabelView, fill: CALayer)] = []
    private let reacted: Set<String>
    private var hovered: Int? { didSet { needsDisplay = true } }
    var onPick: ((String, Bool) -> Void)?

    init(reacted: Set<String>) {
        self.reacted = reacted
        super.init(frame: NSRect(x: 0, y: 0, width: 8 * 28 + 7 * 2, height: 28))
        buttons = PullRequestReactions.order.map { content in
            let fill = CALayer()
            fill.cornerRadius = 6
            layer?.addSublayer(fill)
            let l = LabelView(PullRequestReactions.emoji(content), font: DSFont.ui(16))
            l.lineHeight = 24
            l.alignment = .center
            addSubview(l)
            return (content, l, fill)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.group)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8 * 28 + 7 * 2, height: 28) }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.x / 30)
        return p.y >= 0 && p.y <= 28 && buttons.indices.contains(i) && p.x - CGFloat(i) * 30 <= 28 ? i : nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, b) in buttons.enumerated() {
            let x = CGFloat(i) * 30
            b.fill.frame = CGRect(x: x, y: 0, width: 28, height: 28)
            b.label.frame = NSRect(x: x, y: 2, width: 28, height: 24)
        }
        CATransaction.commit()
    }

    override func updateLayer() {
        for (i, b) in buttons.enumerated() {
            b.fill.backgroundColor = hovered == i ? Themed.color(\.accent).cgColor(in: self)
                : reacted.contains(b.content) ? Themed.color(\.primary, 0.1).cgColor(in: self) : nil
        }
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        onPick?(buttons[i].content, !reacted.contains(buttons[i].content))
    }
}
