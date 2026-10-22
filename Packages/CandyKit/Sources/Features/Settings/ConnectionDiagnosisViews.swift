import AppKit
import DesignSystem

/// `ConnectionDiagnosisSummary` (ConnectionDiagnosisDetails.tsx:75-126): the full headline in `text-destructive`, then
/// "retrying in Ns · attempt N · Details" in muted `text-xs`.
final class ConnectionDiagnosisSummaryView: DSView {
    private let headline = TextBlockView()
    private let retry = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let attemptLabel = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let dots = [LabelView("·", font: DSFont.ui(12), color: Themed.color(\.mutedForeground)),
                        LabelView("·", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))]
    let details = InlineDisclosureButton()
    private var retryAt: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headline.font = DSFont.ui(12)
        headline.lineHeight = 16
        headline.color = Themed.color(\.destructive)
        for l in [retry, attemptLabel] + dots { l.lineHeight = 16 }
        details.title = "Details"
        for v in [headline, retry, attemptLabel, details] + dots as [NSView] { addSubview(v) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ diagnosis: ConnectionDiagnosis, retryAt: Date?, attempt: Int, expanded: Bool) {
        headline.text = diagnosis.headline
        self.retryAt = retryAt
        attemptLabel.text = attempt > 0 ? "attempt \(attempt)" : ""
        attemptLabel.isHidden = attempt == 0
        details.isOpen = expanded
        updateRetry()
        needsLayout = true
    }

    /// `RetryCountdown`: ticks once a second, and only while a retry is scheduled and the row can be seen. `LabelClock`
    /// holds the tick while the window is covered, minimized or hidden; a row scrolled out of view stops and the
    /// scroll that brings it back starts it again.
    // ponytail: one wakeup a second through a backoff of up to 5 min while Connections shows, round to 5 s if wakeup measurements object
    private func updateRetry() {
        let remaining = retryAt?.timeIntervalSinceNow
        let seconds = remaining.map { Int(ceil($0)) }
        retry.isHidden = seconds == nil
        retry.text = seconds.map { $0 > 0 ? "retrying in \($0)s" : "retrying" } ?? ""
        waitsForScroll = false
        guard let remaining, let seconds, seconds > 0, window != nil else { LabelClock.shared.cancel(self); return }
        guard inScrolledView else { LabelClock.shared.cancel(self); waitsForScroll = true; return }
        // The text changes when the remaining time drops below the next whole second.
        LabelClock.shared.schedule(self, in: remaining - Double(seconds - 1)) { [weak self] in self?.tick() }
    }

    private func tick() {
        updateRetry()
        needsLayout = true
    }

    /// Whether any of the row lies in its scroll view's visible part, and false while it has no size yet.
    private var inScrolledView: Bool {
        guard !bounds.isEmpty else { return false }
        guard let clip = enclosingScrollView?.contentView else { return true }
        return !convert(clip.bounds, from: clip).intersection(bounds).isEmpty
    }

    /// Set while a countdown is due but the row is scrolled out of view.
    private var waitsForScroll = false
    private var scrollObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.waitsForScroll, self.inScrolledView { self.tick() } }
            }
        }
        updateRetry()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        LabelClock.shared.visibilityChanged()
    }

    func height(forWidth width: CGFloat) -> CGFloat { headline.height(forWidth: width) + 16 }

    override func layout() {
        super.layout()
        // A row laid out for the first time, or moved into view, starts its countdown.
        if waitsForScroll, inScrolledView { updateRetry() }
        let w = bounds.width
        let hh = headline.height(forWidth: w)
        headline.frame = NSRect(x: 0, y: 0, width: w, height: hh)
        // `flex flex-wrap items-center gap-1`: the parts that show, with a dot between the retry state and the toggle.
        var x: CGFloat = 0
        func place(_ v: NSView, _ width: CGFloat) {
            v.frame = NSRect(x: x, y: hh, width: width, height: 16)
            x += width + 4
        }
        let showsRetry = !retry.isHidden, showsAttempt = !attemptLabel.isHidden
        if showsRetry { place(retry, ceil(retry.textWidth) + 1) }
        dots[0].isHidden = !(showsRetry && showsAttempt)
        if !dots[0].isHidden { place(dots[0], ceil(dots[0].textWidth)) }
        if showsAttempt { place(attemptLabel, ceil(attemptLabel.textWidth) + 1) }
        dots[1].isHidden = !(showsRetry || showsAttempt)
        if !dots[1].isHidden { place(dots[1], ceil(dots[1].textWidth)) }
        place(details, details.intrinsicContentSize.width)
    }
}

/// `ConnectionDiagnosisPanel` (ConnectionDiagnosisDetails.tsx:128-211): the hops in order, what to try, the facts and
/// the actions, under `mt-2 border-t border-border/50 pt-2`, `grid gap-3 text-xs`.
final class ConnectionDiagnosisPanelView: DSView {
    private let rule = CALayer()
    private var hopRows: [(mark: LabelView, label: LabelView, note: LabelView)] = []
    private let tryTitle = LabelView("What to try", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private var steps: [(number: LabelView, text: TextBlockView)] = []
    private let moreInfo = DiagnosisLinkView("More info")
    private var facts: [(label: LabelView, value: TextBlockView)] = []
    private let retry = ButtonView("Retry now", variant: .outline, size: .xs)
    private let copy = ButtonView("Copy diagnostics", variant: .outline, size: .xs)
    private let addRoute = ButtonView("Add direct route", variant: .outline, size: .xs)
    private var moreInfoURL: URL?
    var onRetry: (() -> Void)? { didSet { retry.action = { [weak self] in self?.onRetry?() } } }
    var onCopy: (() -> Void)? { didSet { copy.action = { [weak self] in self?.onCopy?() } } }
    var onAddRoute: (() -> Void)? { didSet { addRoute.action = { [weak self] in self?.onAddRoute?() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(rule)
        tryTitle.lineHeight = 16
        moreInfo.action = { [weak self] in if let url = self?.moreInfoURL { NSWorkspace.shared.open(url) } }
        for v in [tryTitle, moreInfo, retry, copy, addRoute] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ d: ConnectionDiagnosis, canAddRoute: Bool) {
        hopRows.forEach { $0.mark.removeFromSuperview(); $0.label.removeFromSuperview(); $0.note.removeFromSuperview() }
        steps.forEach { $0.number.removeFromSuperview(); $0.text.removeFromSuperview() }
        facts.forEach { $0.label.removeFromSuperview(); $0.value.removeFromSuperview() }
        let muted = Themed.color(\.mutedForeground), destructive = Themed.color(\.destructive)
        hopRows = d.hops.map { hop in
            let tone = hop.result == .failed ? destructive : muted
            let mark = LabelView(["ok": "✓", "failed": "✕", "unchecked": "–"][hop.result.rawValue]!, font: DSFont.ui(12), color: tone)
            let label = LabelView(hop.label, font: DSFont.ui(12), color: hop.result == .ok ? Themed.color(\.foreground) : tone)
            let note = LabelView(["ok": "", "failed": "Failed", "unchecked": "Not checked"][hop.result.rawValue]!, font: DSFont.ui(12), color: tone)
            for l in [mark, label, note] { l.lineHeight = 16; addSubview(l) }
            mark.alignment = .center
            return (mark, label, note)
        }
        steps = d.steps.enumerated().map { i, step in
            let number = LabelView("\(i + 1).", font: DSFont.ui(12), color: muted)
            number.lineHeight = 16
            number.alignment = .right
            let text = TextBlockView()
            text.text = step; text.font = DSFont.ui(12); text.lineHeight = 16; text.color = muted
            addSubview(number); addSubview(text)
            return (number, text)
        }
        moreInfoURL = d.moreInfoURL.flatMap(URL.init(string:))
        moreInfo.isHidden = moreInfoURL == nil
        facts = d.facts.map { fact in
            let label = LabelView(fact.label, font: DSFont.mono(12), color: muted)
            label.lineHeight = 16
            let value = TextBlockView()
            value.text = fact.value; value.font = DSFont.mono(12); value.lineHeight = 16; value.color = Themed.color(\.foreground)
            addSubview(label); addSubview(value)
            return (label, value)
        }
        addRoute.isHidden = !canAddRoute
        needsLayout = true
    }

    private var factLabelWidth: CGFloat { ceil(facts.map(\.label.textWidth).max() ?? 0) + 1 }
    private func valueWidth(_ width: CGFloat) -> CGFloat { max(1, width - factLabelWidth - 12) }
    private func stepWidth(_ width: CGFloat) -> CGFloat { max(1, width - 16) }

    /// `mt-2`, the rule, `pt-2`, then the four blocks `gap-3` apart.
    func height(forWidth width: CGFloat) -> CGFloat {
        let hops = CGFloat(hopRows.count) * 16 + CGFloat(max(0, hopRows.count - 1)) * 2
        let tryBlock = 16 + steps.reduce(0) { $0 + $1.text.height(forWidth: stepWidth(width)) } + (moreInfo.isHidden ? 0 : 16)
        let factsBlock = facts.reduce(0) { $0 + $1.value.height(forWidth: valueWidth(width)) }
        return 8 + 1 + 8 + hops + 12 + tryBlock + 12 + factsBlock + 12 + 24
    }

    override func updateLayer() { rule.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self) }

    override func layout() {
        super.layout()
        let w = bounds.width
        rule.frame = CGRect(x: 0, y: 8, width: w, height: 1)
        var y: CGFloat = 17
        for (i, row) in hopRows.enumerated() {
            if i > 0 { y += 2 }
            // `flex gap-2`, the mark `w-3 text-center`.
            row.mark.frame = NSRect(x: 0, y: y, width: 12, height: 16)
            let lw = ceil(row.label.textWidth) + 1
            row.label.frame = NSRect(x: 20, y: y, width: lw, height: 16)
            row.note.frame = NSRect(x: 20 + lw + 8, y: y, width: max(0, w - lw - 28), height: 16)
            y += 16
        }
        y += 12
        tryTitle.frame = NSRect(x: 0, y: y, width: w, height: 16)
        y += 16
        // `list-decimal pl-4`: the marker hangs in the 16pt indent.
        for step in steps {
            let h = step.text.height(forWidth: stepWidth(w))
            step.number.frame = NSRect(x: 0, y: y, width: 12, height: 16)
            step.text.frame = NSRect(x: 16, y: y, width: stepWidth(w), height: h)
            y += h
        }
        if !moreInfo.isHidden {
            moreInfo.frame = NSRect(x: 0, y: y, width: moreInfo.intrinsicContentSize.width, height: 16)
            y += 16
        }
        y += 12
        // `grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 font-mono`.
        let labelW = factLabelWidth
        for fact in facts {
            let h = fact.value.height(forWidth: valueWidth(w))
            fact.label.frame = NSRect(x: 0, y: y, width: labelW, height: 16)
            fact.value.frame = NSRect(x: labelW + 12, y: y, width: valueWidth(w), height: h)
            y += h
        }
        y += 12
        // `flex flex-wrap gap-2`.
        var x: CGFloat = 0
        for b in [retry, copy, addRoute] where !b.isHidden {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: y, width: s.width, height: 24)
            x += s.width + 8
        }
    }
}

/// "More info": muted, underlined, foreground on hover (`text-muted-foreground underline underline-offset-2 hover:text-foreground`).
final class DiagnosisLinkView: ControlView {
    private let label: LabelView

    init(_ title: String) {
        label = LabelView(title, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        scalesWhenPressed = false
        label.lineHeight = 16
        label.isUnderlined = true
        addSubview(label)
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: 16) }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.color = Themed.color(state.hovered ? \.foreground : \.mutedForeground)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func layout() { super.layout(); label.frame = bounds }
}
