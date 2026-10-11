import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `PullRequestLinkPreview`'s card (PullRequestLinkPreview.tsx:117-149) on `PreviewCardPopup`
/// (`rounded-lg border bg-popover shadow-lg`, `w-80`, `p-3`): `repository #n · State` in `text-2xs`,
/// the title (`text-sm font-medium leading-snug`), then the author's avatar and name and "opened …".
public final class PullRequestLinkPreviewView: DSView, PopupContent {
    static let width: CGFloat = 320
    private let decoration = BoxDecorationLayer()
    private let repository = LabelView("", font: DSFont.ui(10))
    private let number = LabelView("", font: DSFont.ui(10))
    private let dot1 = LabelView("·", font: DSFont.ui(10))
    private let stateIcon: IconView
    private let stateLabel = LabelView("", font: DSFont.ui(10))
    private let title = TextBlockView()
    private let avatar = PullRequestAvatarView()
    private let author = LabelView("", font: DSFont.ui(12))
    private let dot2 = LabelView("·", font: DSFont.ui(12))
    private let opened = LabelView("", font: DSFont.ui(12))

    public init(detail d: PullRequestDetail, nowMs: Int64) {
        let tone = PullRequestStateTone(state: d.state, isDraft: d.isDraft)
        stateIcon = IconView(name: PullRequestStyle.icon(tone), size: 12, strokeColor: PullRequestStyle.color(tone))
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        var box = BoxStyle()
        box.radius = 8
        box.fill = Themed.color(\.popover)
        box.border = Themed.color(\.border)
        box.shadows = [BoxShadow(y: 10, blur: 15, spread: -3, color: Themed.black(0.1)), BoxShadow(y: 4, blur: 6, spread: -4, color: Themed.black(0.1))]
        decoration.boxStyle = box
        decoration.outset = 24
        repository.text = d.repository
        number.text = "#\(d.number)"
        stateLabel.text = tone.label
        for l in [repository, number, dot1, stateLabel] { l.lineHeight = 16 }
        title.font = DSFont.ui(14, weight: .medium)
        title.lineHeight = 19.25
        title.text = d.title
        avatar.actor = d.author
        author.text = PullRequestWriteLogic.previewAuthor(d.author)
        opened.text = "opened " + TimestampFormat.formatRelativeTimeLabel(d.createdAt, nowMs: nowMs)
        for l in [author, dot2, opened] { l.lineHeight = 16 }
        [repository, number, dot1, stateIcon, stateLabel, title, avatar, author, dot2, opened].forEach(addSubview)
        setAccessibilityLabel("Pull request #\(d.number): \(d.title)")
    }

    private var inner: CGFloat { Self.width - 2 - 24 }

    public var popupSize: CGSize { CGSize(width: Self.width, height: 1 + 12 + 16 + 4 + title.height(forWidth: inner) + 8 + 16 + 12 + 1) }
    public override var intrinsicContentSize: NSSize { popupSize }

    public override func layout() {
        super.layout()
        decoration.frame = bounds
        decoration.layout(boxSize: bounds.size)
        let x0: CGFloat = 13, w = inner
        var y: CGFloat = 13
        // `flex gap-1.5`: the repository truncates, the rest keeps its width.
        let nw = ceil(number.textWidth), dw = ceil(dot1.textWidth), sw = ceil(stateLabel.textWidth) + 1
        let tail = 6 + nw + 6 + dw + 6 + 12 + 4 + sw
        let rw = min(ceil(repository.textWidth), max(0, w - tail))
        var x = x0
        repository.frame = NSRect(x: x, y: y, width: rw, height: 16); x += rw + 6
        number.frame = NSRect(x: x, y: y, width: nw, height: 16); x += nw + 6
        dot1.frame = NSRect(x: x, y: y, width: dw, height: 16); x += dw + 6
        stateIcon.frame = NSRect(x: x, y: y + 2, width: 12, height: 12); x += 12 + 4
        stateLabel.frame = NSRect(x: x, y: y, width: sw, height: 16)
        y += 16 + 4
        let th = title.height(forWidth: w)
        title.frame = NSRect(x: x0, y: y, width: w, height: th)
        y += th + 8
        avatar.frame = NSRect(x: x0, y: y, width: 16, height: 16)
        let ow = ceil(opened.textWidth) + 1, d2 = ceil(dot2.textWidth) + 1
        let aw = min(ceil(author.textWidth) + 1, max(0, w - 16 - 6 - 6 - d2 - 6 - ow))
        x = x0 + 16 + 6
        author.frame = NSRect(x: x, y: y, width: aw, height: 16); x += aw + 6
        dot2.frame = NSRect(x: x, y: y, width: d2, height: 16); x += d2 + 6
        opened.frame = NSRect(x: x, y: y, width: ow, height: 16)
    }

    public override func updateLayer() {
        decoration.setNeedsDisplay()
        for l in [repository, number, dot1, stateLabel, author, dot2, opened] { l.color = Themed.color(\.mutedForeground) }
        title.color = Themed.color(\.foreground)
    }

    /// Opens over `anchor` (`side="top" align="center" sideOffset={6}`), passive like a tooltip.
    @discardableResult
    public func present(over anchor: NSView) -> OpenPopup? {
        anchor.popupHost?.open(self, trigger: anchor, placement: PopupPlacement(side: .top, align: .center, sideOffset: 6, fallbackAxisSide: .end),
                               motion: .tooltip, pressesTrigger: false, returnsFocus: false, passive: true)
    }
}
