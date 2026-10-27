import AppKit
import DesignSystem

/// `PullRequestDiffUnavailableState` (PullRequestDiffUnavailableState.tsx:11-60): the Code tab when the
/// first slice of the diff failed. A warning mark, the title and description from
/// `describePullRequestDiffError`, "Try again" and "Open on <Provider>", then the raw error folded
/// under "Technical details".
final class PullRequestDiffUnavailableView: DSView {
    private let empty: EmptyView
    private let actions = DSView()
    private let retry = ButtonView("Try again", icon: .refreshCw, variant: .default, size: .sm)
    private let open: ButtonView
    private let detailsToggle = LinkLabel()
    private let pre = DSView()
    private let errorText = TextBlockView()
    private let content = Content()
    private var detailsOpen = false { didSet { content.invalidateIntrinsicContentSize(); needsLayout = true; empty.needsLayout = true } }
    var onRetry: (() -> Void)?
    var onOpen: (() -> Void)?
    let error: String

    init(error: String, provider: String) {
        self.error = error
        let name = PullRequestListLogic.providerName(provider)
        let copy = PullRequestDetailLogic.describeDiffError(error, providerName: name, provider: provider)
        empty = EmptyView(title: copy.title, message: copy.description, size: .compact)
        open = ButtonView("Open on \(name)", icon: .externalLink, variant: .outline, size: .sm)
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        empty.illustration = WarningMark()
        content.owner = self
        [retry, open].forEach(actions.addSubview)
        [actions, detailsToggle, pre].forEach(content.addSubview)
        pre.addSubview(errorText)
        empty.content = content
        addSubview(empty)
        detailsToggle.text = "Technical details"
        detailsToggle.font = DSFont.ui(12)
        detailsToggle.underlines = false
        detailsToggle.onClick = { [weak self] in self?.detailsOpen.toggle() }
        errorText.text = error
        errorText.font = DSFont.mono(12)
        errorText.lineHeight = 16
        pre.layer?.cornerRadius = 8
        pre.layer?.borderWidth = 1
        pre.layer?.masksToBounds = true
        retry.action = { [weak self] in self?.onRetry?() }
        open.action = { [weak self] in self?.onOpen?() }
    }

    override func layout() {
        super.layout()
        empty.frame = bounds
    }

    override func updateLayer() {
        detailsToggle.color = Themed.color(\.mutedForeground)
        errorText.color = Themed.color(\.mutedForeground)
        pre.layer?.backgroundColor = Themed.color(\.muted, 0.4).cgColor(in: self)
        pre.layer?.borderColor = Themed.color(\.border).cgColor(in: self)
    }

    /// The buttons row (`gap-2`, centered) and the details block under it (`gap` of the compact Empty).
    // ponytail: the error block clips at `max-h-40` instead of scrolling, add a scroll view if errors run long
    fileprivate final class Content: DSView {
        weak var owner: PullRequestDiffUnavailableView?
        private var preHeight: CGFloat {
            guard let o = owner, o.detailsOpen else { return 0 }
            return min(160, o.errorText.height(forWidth: max(0, bounds.width - 24)) + 24)
        }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 28 + 16 + 16 + (preHeight > 0 ? 12 + preHeight : 0))
        }
        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = newSize.width != frame.width
            super.setFrameSize(newSize)
            if widthChanged { invalidateIntrinsicContentSize() }
        }
        override func layout() {
            super.layout()
            guard let o = owner else { return }
            let w = bounds.width
            let rw = ceil(o.retry.intrinsicContentSize.width), ow = ceil(o.open.intrinsicContentSize.width)
            let x = ((w - rw - 8 - ow) / 2).rounded()
            o.actions.frame = NSRect(x: 0, y: 0, width: w, height: 28)
            o.retry.frame = NSRect(x: x, y: 0, width: rw, height: 28)
            o.open.frame = NSRect(x: x + rw + 8, y: 0, width: ow, height: 28)
            let tw = ceil(o.detailsToggle.textWidth) + 1
            o.detailsToggle.frame = NSRect(x: ((w - tw) / 2).rounded(), y: 28 + 16, width: tw, height: 16)
            let ph = preHeight
            o.pre.isHidden = ph == 0
            o.pre.frame = NSRect(x: 0, y: 28 + 16 + 16 + 12, width: w, height: ph)
            o.errorText.frame = NSRect(x: 12, y: 12, width: max(0, w - 24), height: o.errorText.height(forWidth: max(0, w - 24)))
        }
    }

    /// `size-11 rounded-full bg-warning-surface text-warning` around a 20px `TriangleAlertIcon`.
    private final class WarningMark: DSView {
        private let icon = IconView(name: .triangleAlert, size: 20)
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(icon)
            layer?.cornerRadius = 22
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }
        override func layout() { super.layout(); icon.frame = NSRect(x: 12, y: 12, width: 20, height: 20) }
        override func updateLayer() {
            layer?.backgroundColor = Themed.color(\.warningSurface).cgColor(in: self)
            icon.strokeColor = Themed.color(\.warning)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
