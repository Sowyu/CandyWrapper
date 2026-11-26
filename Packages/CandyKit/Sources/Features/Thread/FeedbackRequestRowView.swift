import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `FeedbackRequestCard` (5258 chat/FeedbackRequestCard.tsx, T3 fe9c98c98f #35871): while pending here, a card asking
/// "Send this report to the T3 team?" with exactly what leaves the machine, an "Include the conversation" switch when
/// the server offers it, and Don't send and Send. Settled, one work log line, "Feedback for the T3 team · {outcome}" with
/// a check, a minus or a lock, that opens the report under it. Redesign draws the card as its card on the ground
/// (`RedesignTokens.Card`), like the secret card. 8pt under it (`pb-2`).
final class FeedbackRequestRowView: TimelineRowView {
    private let card = FillView()
    private let headIcon = IconView(name: .messageSquare, size: 14)
    private let heading = LabelView("Send this report to the T3 team?", font: TL.font(14, .medium))
    private let intro = TextBlockView("This is everything that leaves your machine. Nothing is sent unless you press Send.",
                                      font: TL.font(12), lineHeight: 16, color: TL.c(\.mutedForeground))
    private let includeLabel = LabelView("Include the conversation", font: TL.font(14))
    private let includeHint = TextBlockView("", font: TL.font(12), lineHeight: 16, color: TL.c(\.mutedForeground))
    private let includeSwitch = SwitchView(isOn: false, size: .sm)
    private let preview = FeedbackPreviewView()
    private let note = TextBlockView("", font: TL.font(12), lineHeight: 16, color: TL.c(\.mutedForeground))
    private let decline = ButtonView("Don't send", variant: .ghostMuted, size: .sm)
    private let send = ButtonView("Send", variant: .default, size: .sm)
    /// The settled line and its disclosure.
    private var lineIcon = IconView(name: .check, size: 14)
    private var lineIconName = IconName.check
    private let lineLabel = LabelView("", font: TL.font(14))
    private let chevron = IconView(name: .chevronDown, size: 14)

    private var request: AgentFeedbackRequest?
    private var turnItem: TurnItem?
    private var rowId = ""
    private var display = FeedbackRequests.Display.pending
    private var includeConversation = false
    private var submitting = false
    private var error: String?
    private var canAnswer = true
    private var expanded: Bool { context?.feedbackExpanded.contains(rowId) == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.radius = 12
        addSubview(card)
        heading.lineHeight = 20
        includeLabel.lineHeight = 20
        lineLabel.lineHeight = 24
        for v in [headIcon, heading, intro, includeLabel, includeHint, includeSwitch, preview, note, decline, send, lineIcon, lineLabel, chevron] as [NSView] {
            addSubview(v)
        }
        includeSwitch.onChange = { [weak self] on in
            guard let self else { return }
            self.includeConversation = on
            self.applyPreview()
            self.context?.onMarkdownHeightChange?(self.rowId)
        }
        preview.onToggleTrace = { [weak self] in
            guard let self else { return }
            self.context?.disclosure(self.rowId)
            self.context?.onMarkdownHeightChange?(self.rowId)
        }
        decline.action = { [weak self] in self?.answer(send: false) }
        send.action = { [weak self] in self?.answer(send: true) }
        restyle()
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .event(let p, _, _) = item.row.kind else { return }
        if turnItem?.id != p.item.id { includeConversation = false; includeSwitch.isOn = false; preview.traceOpen = false }
        turnItem = p.item
        rowId = item.id
        request = try? p.item.raw.decode(as: AgentFeedbackRequest.self)
        display = FeedbackRequests.display(status: request?.feedbackStatus ?? "pending", visibility: p.visibility)
        submitting = item.ui.secretSubmitting
        error = item.ui.secretError
        canAnswer = context?.model?.canAnswerFeedback?() ?? true
        let pending = display == .pending
        for v in [card, headIcon, heading, intro, decline, send] as [NSView] { v.isHidden = !pending }
        let trace = request?.conversationTrace
        includeHint.text = trace.map(FeedbackRequests.conversationHint) ?? ""
        for v in [includeLabel, includeHint, includeSwitch] as [NSView] { v.isHidden = !pending || trace == nil }
        // `role="alert"` error, else who may answer.
        note.text = error ?? (canAnswer ? "" : "Only someone who can run agents on this machine can send or decline it.")
        note.color = error != nil ? TL.c(\.destructive) : TL.c(\.mutedForeground)
        note.isHidden = !pending || note.text.isEmpty
        let disabled = submitting || !canAnswer
        decline.isEnabled = !disabled
        send.isEnabled = !disabled
        includeSwitch.isEnabled = !disabled
        lineLabel.isHidden = pending
        chevron.isHidden = pending
        let (icon, label): (IconName, String) = switch display {
        case .pendingElsewhere(let l): (.lock, l)
        case .answered(let sent, let l): (sent ? .check : .minus, l)
        case .pending: (.check, "")
        }
        if icon != lineIconName {
            lineIcon.removeFromSuperview()
            lineIcon = IconView(name: icon, size: 14)
            lineIconName = icon
            addSubview(lineIcon)
        }
        lineIcon.isHidden = pending
        lineLabel.text = "\(FeedbackRequests.title) · \(label)"
        applyPreview()
        restyle()
        needsLayout = true
    }

    private func applyPreview() {
        guard let request else { preview.isHidden = true; return }
        preview.preview = display == .pending ? FeedbackRequests.preview(request, includeConversation: includeConversation) : request.preview
        preview.isHidden = display != .pending && !expanded
    }

    private func answer(send isSend: Bool) {
        guard let item = turnItem, !submitting, canAnswer else { return }
        context?.model?.answerFeedbackRequest(rowId, AgentFeedbackRPC.answerInput(
            threadId: item.threadId, turnItemId: item.id, send: isSend, includeConversation: includeConversation))
    }

    /// The settled line opens the report under it (`Collapsible`).
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard display != .pending, p.y < 28 else { return super.mouseDown(with: event) }
        context?.disclosure(rowId)
        if expanded { context?.feedbackExpanded.remove(rowId) } else { context?.feedbackExpanded.insert(rowId) }
        applyPreview()
        context?.onMarkdownHeightChange?(rowId)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
        card.fill = redesign ? RedesignTokens.Card.fill : TL.c(\.card)
        card.border = redesign ? RedesignTokens.Card.border : TL.c(\.border, 0.6)
        heading.color = TL.c(\.foreground)
        includeLabel.color = TL.c(\.foreground)
        headIcon.strokeColor = TL.c(\.iconMuted)
        lineIcon.strokeColor = TL.c(\.iconMuted)
        chevron.strokeColor = TL.c(\.iconMuted)
        lineLabel.color = TL.c(\.secondaryLabel)
    }

    // MARK: Layout

    private var hasSwitch: Bool { !includeLabel.isHidden }

    private func switchHeight(_ inner: CGFloat) -> CGFloat {
        let sw = includeSwitch.intrinsicContentSize.width
        return max(includeSwitch.intrinsicContentSize.height, 20 + includeHint.height(forWidth: max(1, inner - sw - 12)))
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        guard display == .pending else {
            // `WorkLogRow`, then the panel's `pt-2 pb-1 pl-5`.
            return 2 + 24 + 2 + (expanded ? 8 + preview.height(forWidth: max(1, width - 20)) + 4 : 0) + 8
        }
        let inner = max(1, width - 2 - 32)
        var h: CGFloat = 1 + 16 + 20 + 4 + intro.height(forWidth: inner)
        if hasSwitch { h += 12 + switchHeight(inner) }
        h += 12 + preview.height(forWidth: inner)
        if !note.isHidden { h += 12 + note.height(forWidth: inner) }
        return h + 12 + 28 + 16 + 1 + 8
    }

    override func layout() {
        super.layout()
        guard display == .pending else {
            lineIcon.frame = NSRect(x: 2 + 5, y: 2 + 5, width: 14, height: 14)
            let w = min(lineLabel.textWidth, max(0, bounds.width - 34 - 20))
            lineLabel.frame = NSRect(x: 2 + 24 + 6, y: 2, width: w, height: 24)
            chevron.frame = NSRect(x: lineLabel.frame.maxX + 6, y: 2 + 5, width: 14, height: 14)
            if expanded { preview.frame = NSRect(x: 20, y: 28 + 8, width: max(1, bounds.width - 20), height: preview.height(forWidth: max(1, bounds.width - 20))) }
            return
        }
        let inner = max(1, bounds.width - 2 - 32)
        card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 8)
        let x: CGFloat = 17
        var y: CGFloat = 17
        headIcon.frame = NSRect(x: x, y: y + 3, width: 14, height: 14)
        heading.frame = NSRect(x: x + 14 + 6, y: y, width: max(0, inner - 20), height: 20)
        y += 20 + 4
        let ih = intro.height(forWidth: inner)
        intro.frame = NSRect(x: x, y: y, width: inner, height: ih)
        y += ih
        if hasSwitch {
            y += 12
            let size = includeSwitch.intrinsicContentSize, h = switchHeight(inner)
            includeLabel.frame = NSRect(x: x, y: y + (h - 20 - includeHint.height(forWidth: max(1, inner - size.width - 12))) / 2, width: max(0, inner - size.width - 12), height: 20)
            includeHint.frame = NSRect(x: x, y: includeLabel.frame.maxY, width: max(0, inner - size.width - 12), height: includeHint.height(forWidth: max(1, inner - size.width - 12)))
            includeSwitch.frame = NSRect(x: x + inner - size.width, y: y + (h - size.height) / 2, width: size.width, height: size.height)
            y += h
        }
        y += 12
        let ph = preview.height(forWidth: inner)
        preview.frame = NSRect(x: x, y: y, width: inner, height: ph)
        y += ph
        if !note.isHidden {
            let nh = note.height(forWidth: inner)
            note.frame = NSRect(x: x, y: y + 12, width: inner, height: nh)
            y += 12 + nh
        }
        y += 12
        let sw = send.intrinsicContentSize.width, dw = decline.intrinsicContentSize.width
        send.frame = NSRect(x: x + inner - sw, y: y, width: sw, height: 28)
        decline.frame = NSRect(x: x + inner - sw - 8 - dw, y: y, width: dw, height: 28)
    }
}

/// `FeedbackPreview` (FeedbackRequestCard.tsx:180-222): the report's fields in a `grid-cols-[auto_1fr] gap-x-3 gap-y-1
/// text-sm` list, then, with an outline, a `text-xs text-muted-foreground` toggle that opens its lines in a
/// `max-h-80` mono list.
final class FeedbackPreviewView: DSView {
    var preview: AgentFeedbackPreview? { didSet { if preview != oldValue { needsDisplay = true; needsLayout = true; traceList.lines = preview?.trace.map(FeedbackRequests.traceLines) ?? [] } } }
    var traceOpen = false {
        didSet { if traceOpen != oldValue { scroll.isHidden = !traceOpen; down.isHidden = traceOpen; up.isHidden = !traceOpen; needsLayout = true } }
    }
    private let down = IconView(name: .chevronDown, size: 14, strokeColor: TL.c(\.mutedForeground))
    private let up = IconView(name: .chevronUp, size: 14, strokeColor: TL.c(\.mutedForeground))
    var onToggleTrace: (() -> Void)?
    private let traceList = FeedbackTraceListView()
    private let scroll = NSScrollView()
    private static let traceMax: CGFloat = 320

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = traceList
        scroll.isHidden = true
        addSubview(scroll)
        up.isHidden = true
        addSubview(down)
        addSubview(up)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var fields: [(label: String, value: String)] { preview.map(FeedbackRequests.fields) ?? [] }

    private func labelWidth() -> CGFloat {
        fields.map { ceil(TextLine(NSAttributedString(string: $0.label, attributes: [.font: TL.font(14)])).width) }.max() ?? 0
    }

    private func valueLayouts(_ width: CGFloat) -> [TextBlockLayout] {
        let w = max(1, width - labelWidth() - 12)
        return fields.map { TextBlockLayout(NSAttributedString(string: $0.value, attributes: [.font: TL.font(14), .foregroundColor: TL.c(\.foreground)]), width: w, lineHeight: 20) }
    }

    private func fieldsHeight(_ width: CGFloat) -> CGFloat {
        let layouts = valueLayouts(width)
        return layouts.map { max(20, $0.height) }.reduce(0, +) + CGFloat(max(0, layouts.count - 1)) * 4
    }

    private var hasTrace: Bool { preview?.trace != nil }

    func height(forWidth width: CGFloat) -> CGFloat {
        var h = fieldsHeight(width)
        if hasTrace { h += 8 + 16 }
        if hasTrace, traceOpen { h += 8 + min(Self.traceMax, traceList.height(forWidth: width)) }
        return h
    }

    private var toggleRect: CGRect {
        guard let trace = preview?.trace else { return .zero }
        let w = 14 + 4 + ceil(TextLine(NSAttributedString(string: FeedbackRequests.traceSummary(trace), attributes: [.font: TL.font(12)])).width)
        return CGRect(x: 0, y: fieldsHeight(bounds.width) + 8, width: w, height: 16)
    }

    override func layout() {
        super.layout()
        let r = toggleRect
        down.frame = NSRect(x: r.minX, y: r.minY + 1, width: 14, height: 14)
        up.frame = down.frame
        down.isHidden = !hasTrace || traceOpen
        up.isHidden = !hasTrace || !traceOpen
        guard hasTrace, traceOpen else { return }
        let th = traceList.height(forWidth: bounds.width)
        scroll.frame = NSRect(x: 0, y: toggleRect.maxY + 8, width: bounds.width, height: min(Self.traceMax, th))
        traceList.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: th)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lw = labelWidth()
        var y: CGFloat = 0
        for (field, layout) in zip(fields, valueLayouts(bounds.width)) {
            TextBlockLayout(NSAttributedString(string: field.label, attributes: [.font: TL.font(14), .foregroundColor: TL.c(\.mutedForeground)]),
                            width: lw + 1, lineHeight: 20).draw(in: ctx, origin: CGPoint(x: 0, y: y), width: lw + 1, alignment: .left)
            layout.draw(in: ctx, origin: CGPoint(x: lw + 12, y: y), width: bounds.width - lw - 12, alignment: .left)
            y += max(20, layout.height) + 4
        }
        guard let trace = preview?.trace else { return }
        let r = toggleRect
        TextBlockLayout(NSAttributedString(string: FeedbackRequests.traceSummary(trace), attributes: [.font: TL.font(12), .foregroundColor: TL.c(\.mutedForeground)]),
                        width: r.width, lineHeight: 16).draw(in: ctx, origin: CGPoint(x: r.minX + 18, y: r.minY), width: r.width, alignment: .left)
    }

    override func mouseDown(with event: NSEvent) {
        guard toggleRect.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        traceOpen.toggle()
        onToggleTrace?()
    }

    override func resetCursorRects() { if hasTrace { addCursorRect(toggleRect, cursor: .pointingHand) } }
}

/// The outline's `ol`: `flex flex-col gap-1 font-mono text-xs`, each line in `text-muted-foreground` with its message
/// text under it in `mt-0.5 mb-1 whitespace-pre-wrap text-foreground`.
final class FeedbackTraceListView: DSView {
    var lines: [(line: String, text: String?)] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    private func layouts(_ width: CGFloat) -> [(TextBlockLayout, TextBlockLayout?)] {
        let font = DSFont.mono(12), w = max(1, width)
        return lines.map { entry in
            (TextBlockLayout(NSAttributedString(string: entry.line, attributes: [.font: font, .foregroundColor: TL.c(\.mutedForeground)]), width: w, lineHeight: 16),
             entry.text.map { TextBlockLayout(NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: TL.c(\.foreground)]), width: w, lineHeight: 16) })
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let laid = layouts(width)
        return laid.map { $0.0.height + ($0.1.map { 2 + $0.height + 4 } ?? 0) }.reduce(0, +) + CGFloat(max(0, laid.count - 1)) * 4
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var y: CGFloat = 0
        for (line, text) in layouts(bounds.width) {
            line.draw(in: ctx, origin: CGPoint(x: 0, y: y), width: bounds.width, alignment: .left)
            y += line.height
            if let text {
                text.draw(in: ctx, origin: CGPoint(x: 0, y: y + 2), width: bounds.width, alignment: .left)
                y += 2 + text.height + 4
            }
            y += 4
        }
    }
}
