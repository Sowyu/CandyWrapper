import AppKit
import DesignSystem
import T3Protocol

/// The linked issue badge beside a row's pull request (T3 5258 SidebarThreadRow.tsx:1167-1211): a `ThreadLinkBadge`
/// with the state's glyph and the issue's key without its "#", or the count of several, both in the state's tone.
public struct SidebarIssueBadge: Equatable, Sendable {
    public var text: String
    public var label: String
    /// The linked issues' live state from `issues.detail`, which tints and names the glyph (`useSidebarLinkedIssueState`).
    public var state: IssueState?

    public init?(_ issues: [ThreadIssueLink], state: IssueState? = nil) {
        guard let first = issues.first else { return nil }
        self.state = state
        if issues.count == 1 {
            text = first.displayKey.hasPrefix("#") ? String(first.displayKey.dropFirst()) : first.displayKey
            label = state.map { "Issue \(first.displayKey): \(first.title), \($0.name)" } ?? "Issue \(first.displayKey): \(first.title)"
        } else {
            text = "\(issues.count)"
            label = "\(issues.count) linked issues"
        }
    }

    /// `useSidebarLinkedIssueState` (state/issues.ts at 5258, #39351): an open issue wins; with any state unread, none;
    /// else the first closed for another reason than completed, else the first.
    public static func aggregateState(_ states: [IssueState?]) -> IssueState? {
        if let open = states.first(where: { $0?.category == "open" }) { return open }
        if states.isEmpty || states.contains(where: { $0 == nil }) { return nil }
        return states.first { $0?.closeReason.map { $0 != "completed" } ?? false } ?? states[0]
    }

    /// The key `SidebarState.issueStates` holds a single issue's state under.
    public static func stateKey(environmentId: String?, _ link: ThreadIssueLink) -> String {
        [environmentId ?? "", link.projectId.rawValue, link.tracker, link.host, link.scope, link.key].joined(separator: "|")
    }
}

// ponytail: no hover rows of the issues; add them with the thread details' issue rows (#38160, Features/Thread)
/// `ThreadLinkBadge` (ThreadStatusIndicators.tsx:509-543 at 5258) in an `InlineButton`: glyph and text share the tone,
/// `gap-0.5`, the text at most `max-w-16`, underlined on hover.
final class SidebarIssueBadgeView: ControlView {
    private var icon = IconView(name: .circleDot, size: 12)
    private let label = LabelView("", font: DSFont.ui(12))
    private var tooltip: TooltipController?

    var badge: SidebarIssueBadge? {
        didSet {
            guard badge != oldValue else { return }
            isHidden = badge == nil
            // `issueStatePresentation` (issuePresentation.tsx:33-53): circle-dot, circle-check or circle-slash.
            let name = badge?.state.map(IssueListLogic.icon) ?? .circleDot
            if name != oldValue?.state.map(IssueListLogic.icon) ?? .circleDot {
                icon.removeFromSuperview()
                icon = IconView(name: name, size: 12)
                addSubview(icon)
                restyle()
            }
            label.text = badge?.text ?? ""
            setAccessibilityLabel(badge?.label)
            tooltip?.text = badge?.label ?? ""
            if tooltip == nil, let badge { tooltip = TooltipController.attach(to: self, text: badge.label) }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(icon)
        addSubview(label)
        isHidden = true
        setAccessibilityRole(.button)
        restyle()
    }

    /// `gap-0.5`, and the key at most `max-w-16`.
    var preferredWidth: CGFloat { 12 + 2 + min(64, ceil(label.textWidth) + 1) }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame = NSRect(x: 14, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 14), height: 16)
    }

    override var acceptsFirstResponder: Bool { false }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }
    override func updateLayer() { restyle() }

    private func restyle() {
        // The tone colors glyph and text: the state's, else `text-muted-foreground` (#42275).
        let tone = badge?.state.map(IssueListLogic.color) ?? Themed.color(\.mutedForeground, sidebar: true)
        icon.strokeColor = tone
        label.color = tone
        label.isUnderlined = state.hovered
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
