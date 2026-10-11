import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// What a sidebar row's pull request badge shows (`resolveThreadPullRequestBadgePresentation`,
/// ThreadStatusIndicators.tsx:169-210): a stack's layer count, `+n` for several unrelated links,
/// or the one pull request's number in its state's tone.
public struct SidebarPullRequestBadge: Equatable, Sendable {
    public enum Glyph: Equatable, Sendable { case state(PullRequestStateTone), stack, unknown }
    public var glyph: Glyph
    /// The tone; nil is `text-muted-foreground` (no host state yet).
    public var tone: PullRequestStateTone?
    public var text: String
    public var label: String
    /// A stack or several links open the thread's pull requests tab; one link opens it.
    public var opensList: Bool
    /// The hover's mini list (`ThreadPullRequestsMiniList`): the panel's lines, or the one legacy link.
    public var lines: [ThreadPullRequests.Line] = []
    public var legacy: (number: Int, url: String)? { get { legacyNumber.map { ($0, legacyURL) } } set { legacyNumber = newValue?.number; legacyURL = newValue?.url ?? "" } }
    private var legacyNumber: Int?
    private var legacyURL = ""

    public init?(_ thread: ThreadShell) {
        let links = ThreadPullRequests.visible(thread.pullRequests ?? [])
        if let badge = ThreadPullRequests.badge(links) {
            let aggregate = PullRequestStateTone(rawValue: badge.state) ?? .open
            switch badge.kind {
            case .stack(let layers):
                self.init(glyph: .stack, tone: aggregate, text: "\(layers)",
                          label: "Stack of \(layers) pull requests, \(aggregate.label.lowercased())", opensList: true)
            case .pullRequest(let others):
                guard let current = ThreadPullRequests.current(links) else { return nil }
                let tone = current.snapshot.map { PullRequestStateTone(state: $0.state.rawValue, isDraft: $0.isDraft) }
                let lead = tone.map { "PR #\(current.number) - \($0.label)" + (current.snapshot.map { ": \($0.title)" } ?? "") }
                    ?? "PR #\(current.number), status pending"
                if others > 0 {
                    self.init(glyph: .state(aggregate), tone: aggregate, text: "+\(others + 1)",
                              label: "\(lead), and \(others) more linked; overall \(aggregate.label.lowercased())", opensList: true)
                } else {
                    self.init(glyph: tone.map { .state($0) } ?? .unknown, tone: tone, text: "\(current.number)", label: lead, opensList: false)
                }
            }
            lines = ThreadPullRequests.lines(links)
            return
        }
        guard let legacy = thread.linkedPullRequest else { return nil }
        self.init(glyph: .unknown, tone: nil, text: "\(legacy.number)", label: "PR #\(legacy.number), status pending", opensList: false)
        self.legacy = (legacy.number, legacy.url)
    }

    public init(glyph: Glyph, tone: PullRequestStateTone?, text: String, label: String, opensList: Bool) {
        self.glyph = glyph; self.tone = tone; self.text = text; self.label = label; self.opensList = opensList
    }
}

/// The badge itself: a 12pt glyph and `text-xs tabular-nums` in the tone, an inline button.
public final class PullRequestBadgeView: DSView {
    private var icon: IconView?
    private let label = LabelView("", font: DSFont.ui(12))
    public var onClick: (() -> Void)?
    public var badge: SidebarPullRequestBadge? {
        didSet {
            guard badge != oldValue else { return }
            isHidden = badge == nil
            icon?.removeFromSuperview()
            guard let badge else { return }
            let color = badge.tone.map(PullRequestStyle.color) ?? Themed.color(\.mutedForeground)
            let name: IconName = switch badge.glyph {
            case .stack: .layers
            case .state(let t): PullRequestStyle.icon(t)
            case .unknown: .gitPullRequestArrow
            }
            let v = IconView(name: name, size: 12, strokeColor: color)
            addSubview(v)
            icon = v
            label.text = badge.text
            label.color = color
            setAccessibilityLabel(badge.label)
            needsLayout = true
        }
    }

    private var hoverWork: DispatchWorkItem?
    private var hoverPopup: OpenPopup?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
        isHidden = true
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// The tooltip (`TooltipPopup side="top" sideOffset={0} variant="glass" w-80`) holding the mini list,
    /// after the tooltip delay.
    public override func mouseEntered(with event: NSEvent) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showMiniList() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    public override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        if let hoverPopup, let window { PopupHost.host(for: window).close(hoverPopup, returnFocus: false) }
        hoverPopup = nil
    }

    private func showMiniList() {
        guard let badge, let host = popupHost else { return }
        let list = ThreadPullRequestsMiniListView(badge: badge)
        guard !list.isEmpty else { return }
        hoverPopup = host.open(list, trigger: self, placement: PopupPlacement(side: .top, align: .center, sideOffset: 0, fallbackAxisSide: .end),
                               motion: .tooltip, pressesTrigger: false, returnsFocus: false, passive: true)
    }

    public var preferredWidth: CGFloat { 12 + 4 + ceil(label.textWidth) + 1 }

    public override func layout() {
        super.layout()
        icon?.frame = NSRect(x: 0, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 16), height: 16)
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    public override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// `ThreadPullRequestsMiniList` (ThreadStatusIndicators.tsx:342-430) on the glass tooltip surface:
/// one row per pull request (`gap-2`, the state glyph at `size-3`, `#n` in mono, the title at 75%
/// foreground), stepped `0.75rem` per stack depth, "stack · n" or "chain · n" on a chain's first row.
// ponytail: rows are not links here; T3's badge tooltip opens a row's pull request on click. Add it with the hover card
public final class ThreadPullRequestsMiniListView: DSView, PopupContent {
    private struct Row { let icon: IconView; let number: LabelView; let title: LabelView; let stack: LabelView?; let depth: Int }
    private var rows: [Row] = []
    private let decoration = BoxDecorationLayer()
    var isEmpty: Bool { rows.isEmpty }

    /// `drawsSurface: false` leaves out the glass box, for a footer inside another card (the thread hover card).
    public init(badge: SidebarPullRequestBadge, drawsSurface: Bool = true) {
        super.init(frame: .zero)
        decoration.host = self
        if drawsSurface { layer?.addSublayer(decoration) }
        layer?.masksToBounds = false
        var box = BoxStyle()
        box.radius = 8
        box.fill = PopupSurface.glassFill
        box.border = Themed.color(\.contrastForeground, 0.1)
        box.shadows = [BoxShadow(y: 20, blur: 25, spread: -5, color: Themed.black(0.25)), BoxShadow(y: 8, blur: 10, spread: -6, color: Themed.black(0.25))]
        decoration.boxStyle = box
        decoration.outset = 32
        func make(number: Int, title: String, tone: PullRequestStateTone?, depth: Int, stack: String?) -> Row {
            let icon = IconView(name: tone.map(PullRequestStyle.icon) ?? .gitPullRequestArrow, size: 12,
                                strokeColor: tone.map(PullRequestStyle.color) ?? Themed.color(\.mutedForeground))
            let n = LabelView("#\(number)", font: DSFont.mono(12))
            let t = LabelView(title, font: DSFont.ui(12))
            let s = stack.map { LabelView($0, font: DSFont.ui(9)) }
            for l in [n, t] { l.lineHeight = 16 }
            s?.lineHeight = 12
            [icon, n, t].forEach(addSubview)
            s.map(addSubview)
            return Row(icon: icon, number: n, title: t, stack: s, depth: depth)
        }
        if !badge.lines.isEmpty {
            rows = badge.lines.map { line in
                let snap = line.link.snapshot
                return make(number: line.link.number, title: snap?.title ?? line.link.repository,
                            tone: snap.map { PullRequestStateTone(state: $0.state.rawValue, isDraft: $0.isDraft) }, depth: line.depth,
                            stack: line.stackSize.map { "\(line.native ? "stack" : "chain") · \($0)" })
            }
        } else if let legacy = badge.legacy {
            rows = [make(number: legacy.number, title: badge.label, tone: badge.tone, depth: 0, stack: nil)]
        }
    }

    /// `w-80`, `px-2 py-1` tooltip padding, rows `py-1` with `gap-1`.
    public var popupSize: CGSize {
        let n = CGFloat(rows.count)
        let gaps = CGFloat(max(0, rows.count - 1)) * 4
        return CGSize(width: 320, height: 16 + n * 24 + gaps)
    }
    public override var intrinsicContentSize: NSSize { popupSize }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        var y: CGFloat = 8
        for r in rows {
            var x: CGFloat = 12 + 4 + CGFloat(min(r.depth, 3)) * 12
            r.icon.frame = NSRect(x: x, y: y + 6, width: 12, height: 12); x += 12 + 8
            let nw = ceil(r.number.textWidth) + 1
            r.number.frame = NSRect(x: x, y: y + 4, width: nw, height: 16); x += nw + 8
            var right = bounds.width - 12 - 4
            if let s = r.stack {
                let sw = ceil(s.textWidth) + 1
                s.frame = NSRect(x: right - sw, y: y + 6, width: sw, height: 12); right -= sw + 4
            }
            r.title.frame = NSRect(x: x, y: y + 4, width: max(0, right - x), height: 16)
            y += 28
        }
    }

    public override func updateLayer() {
        decoration.setNeedsDisplay()
        for r in rows {
            r.number.color = Themed.color(\.mutedForeground)
            r.title.color = Themed.color(\.foreground, 0.75)
            r.stack?.color = Themed.color(\.mutedForeground)
        }
    }
}
