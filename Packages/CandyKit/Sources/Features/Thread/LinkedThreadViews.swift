import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `ReadOnlyComposerBar` as `LinkedThreadComposer` fills it (5258 LinkedThreadPane.tsx:33-66, ReadOnlyComposerBar.tsx:7-37):
/// stands in the composer's surface for a linked thread, which takes no messages from here. An eye, "Read-only",
/// then "On {label} via {via}" with "· Working" while work runs, and an optional action at the trailing edge.
/// `min-h-12 gap-3 py-2 ps-5 pe-2 text-sm`; below 560 of composer width the status drops under the lead in `text-xs`.
/// Redesign keeps the layout in its own type: 13 for the lead and 12 for the status.
public final class LinkedThreadBarView: DSView {
    public var status = "" { didSet { if status != oldValue { statusLabel.text = status; setAccessibilityLabel("Read-only, \(status)"); needsLayout = true } } }
    /// The trailing button ("Connect to interact"), hidden while nil.
    public var action: ButtonView? {
        didSet {
            guard action !== oldValue else { return }
            oldValue?.removeFromSuperview()
            action.map(addSubview)
            needsLayout = true
        }
    }

    private let eye = IconView(name: .eye, size: 16)
    private let lead = LabelView("Read-only", font: DSFont.ui(14, weight: .medium))
    private let statusLabel = LabelView("", font: SB.tabular(14))

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [lead, statusLabel] { l.lineHeight = 20; addSubview(l) }
        addSubview(eye)
        setAccessibilityRole(.group)
        restyle()
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 48) }

    private var redesign: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restyle() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        lead.color = Themed.color(\.foreground)
        statusLabel.color = Themed.color(\.mutedForeground)
        eye.strokeColor = Themed.color(\.mutedForeground)
        lead.font = DSFont.ui(redesign ? 13 : 14, weight: .medium)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let width = bounds.width, midY = bounds.height / 2
        var right = width - 8
        if let action {
            // `@max-[320px]/composer-surface:sr-only`: the glyph alone below 320.
            let title: String? = width < 320 ? nil : "Connect to interact"
            if action.title != title { action.title = title; action.setAccessibilityLabel("Connect to interact") }
            let s = action.intrinsicContentSize
            action.frame = NSRect(x: right - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
            right -= s.width + 12
        }
        let stacked = width < 560
        statusLabel.font = SB.tabular(stacked || redesign ? 12 : 14)
        statusLabel.lineHeight = stacked ? 16 : 20
        let leadY = stacked ? midY - (20 + 2 + 16) / 2 : midY - 10
        let x: CGFloat = 20
        eye.frame = NSRect(x: x, y: leadY + 2, width: 16, height: 16)
        let room = max(0, right - x - 24)
        let lw = min(ceil(lead.textWidth), room)
        lead.frame = NSRect(x: x + 24, y: leadY, width: lw, height: 20)
        let sw = ceil(statusLabel.textWidth)
        if stacked {
            statusLabel.frame = NSRect(x: x, y: leadY + 22, width: max(0, min(sw, right - x)), height: 16)
        } else {
            let sx = x + 24 + lw + 12
            statusLabel.frame = NSRect(x: sx, y: midY - 10, width: max(0, min(sw, right - sx)), height: 20)
        }
    }
}

/// A linked thread as a right panel tab (5258 LinkedThreadPane.tsx:75-258): the timeline every thread uses, read only,
/// with `LinkedThreadBarView` in the composer's place. Before the first page it says "Reading from {label}…" or why
/// the read failed; after it, a failure shows above the bar over what was read before.
public final class LinkedThreadPaneView: DSView {
    public let chat = ThreadPanelView()
    public let bar = LinkedThreadBarView()

    public enum Notice: Equatable {
        case none
        case reading(label: String)
        /// Before the first page (`Alert variant="error"`) or over a thread already read (`variant="warning"`).
        case failure(LinkedThreads.Failure, overThread: Bool)
    }
    public var notice: Notice = .none { didSet { if notice != oldValue { applyNotice() } } }
    public var onRetry: (() -> Void)?

    private var reading: (row: DSView, spinner: SpinnerView, label: LabelView)?
    /// T3's `Alert` in the default themes, `LinkedThreadNoticeCard` in Redesign.
    private var alert: NSView?
    private var redesign: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The notice swaps between T3's alert and Redesign's card with the look.
        if case .failure = notice, (alert is LinkedThreadNoticeCard) != redesign { applyNotice() }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chat.isEmbedded = true
        chat.showsComposerWithoutThread = true
        chat.model.canOperateThread = false
        chat.composer.replacement = bar
        addSubview(chat)
    }

    public override var isFlipped: Bool { true }

    private func applyNotice() {
        reading?.row.removeFromSuperview(); reading = nil
        alert?.removeFromSuperview(); alert = nil
        switch notice {
        case .none: break
        case .reading(let label):
            let row = DSView()
            let spinner = SpinnerView(size: .sm)
            // `<T>Reading from <Var>{label}</Var>…</T>` in `text-sm text-muted-foreground`.
            let text = LabelView("Reading from \(label)…", font: DSFont.ui(ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? 13 : 14))
            text.lineHeight = 20
            text.color = Themed.color(\.mutedForeground)
            row.addSubview(spinner); row.addSubview(text)
            addSubview(row)
            reading = (row, spinner, text)
        case .failure(let failure, let overThread):
            let message = failure.detail + (overThread ? (failure.detail.isEmpty ? "" : " ") + "Showing what was read before." : "")
            var retry: ButtonView?
            if failure.retryable {
                let button = ButtonView("Try again", variant: .outline, size: .sm)
                button.action = { [weak self] in self?.onRetry?() }
                retry = button
            }
            if redesign {
                let card = LinkedThreadNoticeCard(title: failure.title, message: message, warning: overThread, action: retry)
                addSubview(card)
                alert = card
            } else {
                let view = AlertView(failure.title, message: message, icon: nil, variant: overThread ? .warning : .error)
                view.actions = retry.map { [$0] } ?? []
                addSubview(view)
                alert = view
            }
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        chat.frame = bounds
        chat.layoutSubtreeIfNeeded()
        // `chat-content-lane`: the notice keeps to the column the composer uses.
        let lane = chat.composer.frame
        let x = lane.width > 0 ? lane.minX : 16, width = lane.width > 0 ? lane.width : max(0, bounds.width - 32)
        if let reading {
            let w = ceil(reading.label.textWidth)
            reading.row.frame = NSRect(x: x, y: 12, width: width, height: 20)
            reading.spinner.frame = NSRect(x: 0, y: 3, width: 14, height: 14)
            reading.label.frame = NSRect(x: 22, y: 0, width: min(w, max(0, width - 22)), height: 20)
        }
        if let alert {
            let h = (alert as? AlertView)?.height(forWidth: width) ?? (alert as? LinkedThreadNoticeCard)?.height(forWidth: width) ?? 0
            if case .failure(_, true) = notice, lane.height > 0 {
                // `pb-2` above the bar.
                alert.frame = NSRect(x: x, y: lane.minY - 8 - h, width: width, height: h)
            } else {
                alert.frame = NSRect(x: x, y: 12, width: width, height: h)
            }
        }
    }
}

/// Redesign's linked-thread notice: the solid resting surface with card corners and the resting shadow, a rim in the
/// notice's tone as Redesign's thread error banner draws it, the title at 13 and 500 and the detail at 12.
final class LinkedThreadNoticeCard: DSView {
    private let title = TextBlockView("", font: DSFont.ui(13, weight: .medium), lineHeight: 18)
    private let message = TextBlockView("", font: DSFont.ui(12), lineHeight: 16)
    private let action: ButtonView?
    private let warning: Bool
    private static let pad = RedesignTokens.Space.m

    init(title: String, message: String, warning: Bool, action: ButtonView?) {
        self.warning = warning
        self.action = action
        super.init(frame: .zero)
        self.title.text = title
        self.message.text = message
        addSubview(self.title); addSubview(self.message)
        action.map(addSubview)
        layer?.cornerRadius = RedesignTokens.Radius.card
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("alert")
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var actionWidth: CGFloat { action.map { $0.intrinsicContentSize.width + RedesignTokens.Space.m } ?? 0 }

    func height(forWidth width: CGFloat) -> CGFloat {
        let text = max(0, width - 2 * Self.pad - actionWidth)
        let body = title.height(forWidth: text) + (message.text.isEmpty ? 0 : 2 + message.height(forWidth: text))
        return 2 * Self.pad + max(body, action?.intrinsicContentSize.height ?? 0)
    }

    override func updateLayer() {
        super.updateLayer()
        let dark = effectiveAppearance.isDark
        let tone: KeyPath<Palette, TokenColor> = warning ? \.warning : \.error
        layer?.backgroundColor = RedesignTokens.Surface.fill(in: self)
        layer?.borderColor = Themed.color(tone, 0.32).cgColor(in: self)
        RedesignTokens.Shadow.resting.apply(to: layer!, path: CGPath(roundedRect: bounds, cornerWidth: RedesignTokens.Radius.card,
                                                                     cornerHeight: RedesignTokens.Radius.card, transform: nil), dark: dark)
        title.color = Themed.color(warning ? \.warningForeground : \.errorForeground)
        message.color = Themed.color(\.mutedForeground)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        let text = max(0, bounds.width - 2 * Self.pad - actionWidth)
        let th = title.height(forWidth: text)
        title.frame = NSRect(x: Self.pad, y: Self.pad, width: text, height: th)
        message.frame = NSRect(x: Self.pad, y: Self.pad + th + 2, width: text, height: message.height(forWidth: text))
        if let action {
            let s = action.intrinsicContentSize
            action.frame = NSRect(x: bounds.width - Self.pad - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        }
    }
}

/// `LinkedThreadPage` (5258 components/chat/LinkedThreadPage.tsx:19-66): a linked thread on the main screen, for the
/// "Main view" side-thread setting or a Cmd-click. `WorkspacePageHeader` holds a one-item "Thread breadcrumb" with the
/// title in `text-sm font-medium text-foreground`, over the same read-only pane the panel tab uses. Redesign draws the
/// title as its title pill (`DitherThreadTitleView`) at the header's start.
public final class LinkedThreadPageView: DSView {
    public let pane = LinkedThreadPaneView()
    private let header = NoActiveThreadHeaderView()
    private let pill = DitherThreadTitleView()
    public var title = "" {
        didSet {
            guard title != oldValue else { return }
            header.label.text = title
            pill.set(project: "", title: title)
            header.setAccessibilityLabel("Thread breadcrumb")
            needsLayout = true
        }
    }
    private var redesign: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.label.font = DSFont.ui(14, weight: .medium)
        header.label.color = Themed.color(\.foreground)
        header.label.lineHeight = 20
        header.label.truncation = .end
        pane.chat.isEmbedded = true
        addSubview(pane)
        addSubview(header)
        header.addSubview(pill)
        setAccessibilityLabel("Linked thread")
    }

    public override var isFlipped: Bool { true }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    public override func layout() {
        super.layout()
        let h = NoActiveThreadStateView.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        header.layoutSubtreeIfNeeded()
        header.label.isHidden = redesign
        pill.isHidden = !redesign || title.isEmpty
        let start = header.contentStart
        if redesign {
            let w = min(pill.intrinsicContentSize.width, max(0, bounds.width - start - 16))
            pill.frame = NSRect(x: start, y: ((h - DitherThreadTitleView.height) / 2).rounded(), width: w, height: DitherThreadTitleView.height)
        }
        // The header stacks over the pane in both looks: an embedded pane has no top fade to run under the pill.
        let top = h
        pane.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    public override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
}

extension LinkedThreadPaneView {
    /// "Connect to interact"'s notice above the bar (`ComposerBannerStack detached`, LinkedThreadPane.tsx:109-145):
    /// a spinner while it connects, `PlugIcon` otherwise, a warning when the machine can't be reached.
    public func showConnectNotice(_ notice: LinkedThreadConnect.Notice?) {
        guard let notice else { chat.showsNoticeBanner = false; return }
        chat.noticeBanner.apply(.init(variant: notice.kind == .unreachable ? .warning : .neutral, icon: .plug, title: notice.title,
                                      description: notice.detail, actions: notice.action.map { [$0] } ?? [],
                                      spinner: notice.kind == .connecting))
        chat.showsNoticeBanner = true
    }
}
