import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `GuestShareIndicator` (GuestShareControls.tsx:187-214): at the end of the header's breadcrumb row while the thread
/// has a share, a user icon (`size-3.5`), the status in `text-xs text-muted-foreground` and a ghost "Stop sharing",
/// `gap-1`. The status turns to "Guest link expired" on its own at the expiry minute, from one timer.
final class GuestShareIndicatorView: DSView {
    /// lucide `user` (UserIcon), outside the generated set.
    static let userIcon = IconDefinition(viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24), elements: [
        IconElement(.path(d: "M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2")),
        IconElement(.circle(cx: 12, cy: 7, r: 4)),
    ])
    private let icon = IconView(definition: GuestShareIndicatorView.userIcon, size: 14, color: TL.c(\.mutedForeground))
    private let label = LabelView("", font: TL.font(12), color: TL.c(\.mutedForeground))
    let stop = ButtonView("Stop sharing", variant: .ghostMuted, size: .xs)
    private var expiry: DispatchWorkItem?
    private(set) var share: ThreadGuestShare?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        for v in [icon, label, stop] as [NSView] { addSubview(v) }
        setAccessibilityElement(false)
    }

    var stopping = false { didSet { stop.isEnabled = !stopping } }

    func configure(_ share: ThreadGuestShare?) {
        self.share = share
        refreshStatus()
    }

    private func refreshStatus() {
        expiry?.cancel()
        expiry = nil
        guard let share else { label.text = ""; return }
        let now = Date()
        label.text = share.statusText(now: now)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        guard let at = share.expiryDate(after: now) else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshStatus() } }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSince(now)) + 0.05, execute: work)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 14 + 4 + ceil(label.textWidth) + 1 + 4 + stop.intrinsicContentSize.width, height: 24)
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        icon.frame = NSRect(x: 0, y: midY - 7, width: 14, height: 14)
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 18, y: midY - 8, width: lw, height: 16)
        let s = stop.intrinsicContentSize
        stop.frame = NSRect(x: label.frame.maxX + 4, y: midY - s.height / 2, width: s.width, height: s.height)
    }
}

/// `GuestPendingMessages` (GuestShareControls.tsx:229-326): the guest's waiting messages in the timeline footer, each
/// right-aligned (`flex-col items-end gap-1`): the name (`text-2xs text-guest-foreground me-1`), a `rounded-2xl p-3`
/// bubble at most 80% wide with a dashed `border-guest/50` edge and no fill (`guestBubbleClassName(true)`), the files
/// then the text (`text-sm leading-relaxed whitespace-pre-wrap`), then Dismiss and Send (`xs`, `gap-1 pe-1`) for a
/// connection that may operate. The list is `gap-4 pb-4`. Redesign frosts the bubble like its user bubbles.
final class GuestPendingMessagesView: DSView {
    static let padding: CGFloat = 12
    static let textLineHeight: CGFloat = 22.75

    final class Row: DSView {
        let name = LabelView("", font: TL.font(11), color: GuestColors.foreground)
        let bubble = FillView()
        let rim = CAShapeLayer()
        let text = TextBlockView("", font: TL.font(14), lineHeight: GuestPendingMessagesView.textLineHeight, color: TL.c(\.foreground))
        let attachments = UserMessageAttachmentsView()
        let dismiss = ButtonView("Dismiss", variant: .ghostMuted, size: .xs)
        let send = ButtonView("Send", variant: .default, size: .xs)
        var messageId = ""
        var showsActions = true

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            name.lineHeight = 16
            bubble.radius = 18
            rim.fillColor = nil
            rim.lineWidth = 1
            rim.lineDashPattern = [3, 3]
            bubble.layer?.addSublayer(rim)
            for v in [name, bubble, dismiss, send] as [NSView] { addSubview(v) }
            bubble.addSubview(text)
            // Over the bubble, not in it, as in the user row: the bubble takes no clicks, the images do.
            addSubview(attachments)
        }

        func restyle() {
            let dither = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
            bubble.pane = dither
            bubble.fill = dither ? TL.c(\.messageSurface) : nil
            rim.strokeColor = Themed.base("fuchsia-500", 0.5).cgColor(in: self)
        }

        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

        /// The bubble's width in a lane `width` wide: the text's longest line when it fits, else 80%.
        func bubbleWidth(_ width: CGFloat) -> CGFloat {
            let maxBubble = width * 0.8, inner = maxBubble - GuestPendingMessagesView.padding * 2
            let longest = text.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { TextLine(NSAttributedString(string: String($0), attributes: [.font: text.font])).width }.max() ?? 0
            let natural = max(longest, attachments.naturalWidth)
            return natural > inner ? maxBubble : min(maxBubble, ceil(natural * 64) / 64 + GuestPendingMessagesView.padding * 2)
        }

        private func bubbleParts(_ width: CGFloat) -> (bubble: CGFloat, attachments: CGFloat, text: CGFloat) {
            let b = bubbleWidth(width), inner = b - GuestPendingMessagesView.padding * 2
            let a = attachments.height(forWidth: inner)
            let t = text.text.isEmpty ? 0 : text.height(forWidth: inner)
            return (b, a, t)
        }

        func height(forWidth width: CGFloat) -> CGFloat {
            let p = bubbleParts(width)
            let gap: CGFloat = p.attachments > 0 && p.text > 0 ? 8 : 0
            return 16 + 4 + p.attachments + gap + p.text + GuestPendingMessagesView.padding * 2 + (showsActions ? 4 + 24 : 0)
        }

        override func layout() {
            super.layout()
            let width = bounds.width, p = bubbleParts(width)
            let nw = ceil(name.textWidth) + 1
            name.frame = NSRect(x: width - 4 - nw, y: 0, width: nw, height: 16)
            let gap: CGFloat = p.attachments > 0 && p.text > 0 ? 8 : 0
            let bh = p.attachments + gap + p.text + GuestPendingMessagesView.padding * 2
            bubble.frame = NSRect(x: width - p.bubble, y: 20, width: p.bubble, height: bh)
            let pad = GuestPendingMessagesView.padding
            attachments.frame = NSRect(x: bubble.frame.minX + pad, y: 20 + pad, width: p.bubble - pad * 2, height: p.attachments)
            text.frame = NSRect(x: pad, y: pad + p.attachments + gap, width: p.bubble - pad * 2, height: p.text)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rim.frame = bubble.bounds
            rim.path = CGPath(roundedRect: bubble.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 17.5, cornerHeight: 17.5, transform: nil)
            CATransaction.commit()
            let ss = send.intrinsicContentSize, ds = dismiss.intrinsicContentSize
            let y = bubble.frame.maxY + 4
            send.frame = NSRect(x: width - 4 - ss.width, y: y, width: ss.width, height: 24)
            dismiss.frame = NSRect(x: send.frame.minX - 4 - ds.width, y: y, width: ds.width, height: 24)
            send.isHidden = !showsActions
            dismiss.isHidden = !showsActions
        }
    }

    private var rows: [Row] = []
    var onResolve: ((_ guestMessageId: String, _ send: Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    var isEmpty: Bool { rows.isEmpty }

    /// `messages` are the share's pending ones in order; `busy` holds those with a Send or Dismiss in flight.
    func configure(_ messages: [ThreadGuestMessage], guestName: String?, canOperate: Bool, busy: Set<String>, model: ThreadViewModel?) {
        while rows.count > messages.count { rows.removeLast().removeFromSuperview() }
        while rows.count < messages.count {
            let row = Row()
            row.restyle()
            row.dismiss.action = { [weak self, weak row] in if let row { self?.onResolve?(row.messageId, false) } }
            row.send.action = { [weak self, weak row] in if let row { self?.onResolve?(row.messageId, true) } }
            addSubview(row)
            rows.append(row)
        }
        let name = guestName ?? "Guest"
        for (row, message) in zip(rows, messages) {
            row.messageId = message.id
            row.name.text = name
            row.name.setAccessibilityLabel("\(name) (guest)")
            row.text.text = message.text
            row.text.isHidden = message.text.isEmpty
            row.attachments.configure(ChatMessage(id: MessageId(message.id), role: .user, text: "", createdAt: message.submittedAt,
                                                  attachments: message.attachments ?? []), model: model)
            row.showsActions = canOperate
            row.dismiss.isEnabled = !busy.contains(message.id)
            row.send.isEnabled = !busy.contains(message.id)
            row.dismiss.setAccessibilityLabel("Dismiss message from \(name)")
            row.send.setAccessibilityLabel("Send message from \(name)")
            row.needsLayout = true
        }
        setAccessibilityLabel("\(messages.count) guest message\(messages.count == 1 ? "" : "s") waiting")
        setMediaVisible(window != nil)
        needsLayout = true
    }

    func setMediaVisible(_ visible: Bool) { rows.forEach { $0.attachments.setMediaVisible(visible) } }

    // ponytail: media counts as visible while the list is in a window, wherever the timeline is scrolled; feed it the
    // footer's scroll visibility if a played guest video should stop once scrolled away
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setMediaVisible(window != nil)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !rows.isEmpty, width > 0 else { return 0 }
        return rows.reduce(0) { $0 + $1.height(forWidth: width) } + CGFloat(rows.count - 1) * 16 + 16
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows {
            let h = row.height(forWidth: bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 16
        }
    }
}
