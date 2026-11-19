import AppKit
import DesignSystem
import T3Protocol

/// The linked issue badge beside a row's pull request (T3 4928 SidebarThreadRow.tsx:1135-1201, #38282): an
/// `InlineButton tone="muted"` with a `size-3` circle-dot glyph and the issue's key, or the count of several.
public struct SidebarIssueBadge: Equatable, Sendable {
    public var text: String
    public var label: String

    public init?(_ issues: [ThreadIssueLink]) {
        guard let first = issues.first else { return nil }
        if issues.count == 1 {
            text = first.displayKey
            label = "Issue \(first.displayKey): \(first.title)"
        } else {
            text = "\(issues.count)"
            label = "\(issues.count) linked issues"
        }
    }
}

// ponytail: draws the generic issue glyph; T3 tints it by the issue's live state from the issues RPC. Add the state
// tint, and the hover's issue rows, once CW has the Issues panel.
final class SidebarIssueBadgeView: ControlView {
    private let icon = IconView(name: .circleDot, size: 12)
    private let label = LabelView("", font: DSFont.ui(12))
    private var tooltip: TooltipController?

    var badge: SidebarIssueBadge? {
        didSet {
            guard badge != oldValue else { return }
            isHidden = badge == nil
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
        // `tone="muted"`: the glyph is muted and turns foreground on hover; the key stays `text-secondary-label`.
        icon.strokeColor = Themed.color(state.hovered ? \.foreground : \.mutedForeground, sidebar: true)
        label.color = Themed.color(\.secondaryLabel, sidebar: true)
        label.isUnderlined = state.hovered
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
