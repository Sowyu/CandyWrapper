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
            return
        }
        guard let legacy = thread.linkedPullRequest else { return nil }
        self.init(glyph: .unknown, tone: nil, text: "\(legacy.number)", label: "PR #\(legacy.number), status pending", opensList: false)
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
            toolTip = badge.label
            setAccessibilityLabel(badge.label)
            needsLayout = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
        isHidden = true
        setAccessibilityRole(.button)
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
