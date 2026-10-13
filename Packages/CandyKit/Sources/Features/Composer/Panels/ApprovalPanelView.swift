import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The pending approval above the composer (chat/ComposerPendingApprovalPanel.tsx,
/// ComposerPendingApprovalActions.tsx): a warning banner with the shield, the kind label, the
/// command or path, and Decline, Approve and an ellipsis menu with the other decisions.
/// Spec: J-composer-visuals 6.2, behavior I-composer-flow 3.2 and 3.3.
///
/// `configure` with the active approval (`PendingRequests.activeApproval`) and the pending count;
/// `onRespond` gets the decision and the exact `orchestration.dispatchCommand` payload. The app
/// sets `isResponding` while the call runs; the stream removing the request is what hides the
/// panel. T3 has no keyboard shortcuts for approvals.
public final class ApprovalPanelView: ComposerBannerView {
    public var onRespond: ((ApprovalDecision, JSONValue) -> Void)?
    /// A respond call is in flight: every action is disabled.
    public var isResponding = false { didSet { if isResponding != oldValue { updateEnabled() } } }

    public private(set) var approval: PendingApproval?
    private var threadId: ThreadId = ""

    /// `density="spacious"`: 12px padding; row `gap-x-2 gap-y-3`; the icon column is 24.
    static let pad: CGFloat = 12, column: CGFloat = 24, gap: CGFloat = 8
    /// Below this banner width the actions drop to a second row (`@max-[560px]`).
    static let narrow: CGFloat = 560
    static let detailMaxHeight: CGFloat = 80

    private let icon = IconView(name: .shield, size: 16, strokeColor: Themed.color(\.warning))
    private let kindLabel = glassLabel(font: DSFont.ui(11, weight: .medium), color: Themed.color(\.warning), lineHeight: 16)
    private let appLabel = glassLabel(font: DSFont.ui(11), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let countLabel = glassLabel(font: SB.tabular(11), color: Themed.color(\.mutedForeground), lineHeight: 16)
    /// One line: mono `whitespace-pre`. Several lines or app access prose: a wrapped block.
    private let detailLine = glassLabel(font: DSFont.mono(12), color: Themed.color(\.foreground), lineHeight: 16)
    private let detailBlock = glassBlock(font: DSFont.mono(12), color: Themed.color(\.foreground), lineHeight: 16)
    private var buttons: [(ApprovalOption, ButtonView)] = []
    private let more = ButtonView(nil, icon: .ellipsis, variant: .outline, size: .iconXs).menuTrigger()

    public init() {
        super.init(variant: .warning)
        [icon, kindLabel, appLabel, countLabel, detailLine, detailBlock].forEach(addSubview)
        detailBlock.maxLines = Int(Self.detailMaxHeight / 16)
        more.smoothsFont = false
        more.setAccessibilityLabel("More approval options")
        more.action = { [weak self] in self?.openMenu() }
        addSubview(more)
    }

    public func configure(_ approval: PendingApproval, pendingCount: Int, threadId: ThreadId) {
        self.approval = approval
        self.threadId = threadId
        kindLabel.text = approval.label
        setAccessibilityLabel(approval.label)
        appLabel.text = approval.appName ?? ""
        appLabel.isHidden = approval.appName == nil
        countLabel.text = "1/\(pendingCount)"
        countLabel.isHidden = pendingCount <= 1

        let text = approval.detailText
        let prose = approval.requestKind == .mcpElicitation
        let multiline = prose || text.contains("\n")
        detailLine.isHidden = multiline
        detailBlock.isHidden = !multiline
        detailLine.text = multiline ? "" : text
        detailBlock.text = multiline ? text : ""
        detailBlock.font = prose ? DSFont.ui(12) : DSFont.mono(12)
        // ponytail: the detail truncates (one line) or clamps at 80px where T3 scrolls; add scrolling when long commands show up

        buttons.forEach { $0.1.removeFromSuperview() }
        buttons = approval.buttonOptions.map { option in
            let button = ButtonView(option.label, icon: option.warning == nil ? nil : .triangleAlert,
                                    variant: option.decision == .accept ? .default : .outline, size: .xs)
            button.smoothsFont = false
            if option.warning != nil { button.iconSize = 12 }
            if let warning = option.warning { TooltipController.attach(to: button, text: warning) }
            button.action = { [weak self] in self?.respond(option.decision) }
            addSubview(button)
            return (option, button)
        }
        more.isHidden = approval.menuOptions.isEmpty
        if nativeCard { buildNativeButtons() }
        updateEnabled()
        needsLayout = true
    }

    private func updateEnabled() {
        let canRespond = approval?.canRespond ?? false
        buttons.forEach { $0.1.isEnabled = !isResponding && canRespond }
        nativeButtons.forEach { $0.1.isEnabled = !isResponding && canRespond }
        more.isEnabled = !isResponding
    }

    // MARK: Glass Native

    /// T3 Mobile's actions (PendingApprovalCard.tsx:23-76) as AppKit push buttons: Decline, Allow session and a
    /// prominent Allow once, right to left as macOS orders a default button. Other decisions stay in the menu.
    private var nativeButtons: [(ApprovalDecision, NSButton)] = []
    /// The kind in capitals over the detail, made the first time a native card shows.
    private var eyebrowLabel: LabelView?
    private var eyebrow: LabelView {
        if let eyebrowLabel { return eyebrowLabel }
        let label = LabelView("", font: DSFont.ui(12, weight: .bold), color: Themed.color(\.warning))
        label.lineHeight = 16
        addSubview(label)
        eyebrowLabel = label
        return label
    }
    static let nativePad: CGFloat = 16, nativeGap: CGFloat = 10, nativeButton: CGFloat = 28

    override func nativeCardDidChange() {
        if nativeCard {
            buildNativeButtons()
        } else {
            nativeButtons.forEach { $0.1.removeFromSuperview() }
            nativeButtons = []
            eyebrowLabel?.isHidden = true
            icon.isHidden = false
            kindLabel.isHidden = false
            appLabel.isHidden = approval?.appName == nil
            buttons.forEach { $0.1.isHidden = false }
            more.isHidden = approval?.menuOptions.isEmpty ?? true
        }
        updateEnabled()
    }

    private func buildNativeButtons() {
        nativeButtons.forEach { $0.1.removeFromSuperview() }
        nativeButtons = []
        guard let approval else { return }
        let offered = approval.effectiveOptions.map(\.decision)
        let order: [(ApprovalDecision, String)] = [(.decline, "Decline"), (.acceptForSession, "Allow session"), (.accept, "Allow once")]
        for (decision, title) in order where offered.contains(decision) {
            let button = NSButton(title: title, target: self, action: #selector(pressNative(_:)))
            button.bezelStyle = .push
            button.controlSize = .large
            if decision == .accept {
                button.keyEquivalent = "\r"
                if #available(macOS 26, *) { button.tintProminence = .primary }
            }
            button.tag = nativeButtons.count
            addSubview(button)
            nativeButtons.append((decision, button))
        }
        // Allow session moved out of the menu; the rest stays there.
        more.isHidden = !approval.menuOptions.contains { $0.decision != .acceptForSession }
        eyebrow.text = approval.label.uppercased()
        eyebrow.isHidden = false
    }

    @objc private func pressNative(_ sender: NSButton) {
        guard nativeButtons.indices.contains(sender.tag) else { return }
        respond(nativeButtons[sender.tag].0)
    }

    private func nativeDetailHeight(width: CGFloat) -> CGFloat {
        detailBlock.isHidden ? 16 : min(Self.detailMaxHeight, max(16, detailBlock.height(forWidth: width)))
    }

    /// The card: eyebrow, detail, then the button row, `p-4 gap-2.5`.
    private func nativeHeight(width: CGFloat) -> CGFloat {
        let p = Self.nativePad
        return p + 16 + Self.nativeGap + nativeDetailHeight(width: max(0, width - 2 * p)) + Self.nativeGap + Self.nativeButton + p
    }

    private func layoutNative() {
        let w = bounds.width, p = Self.nativePad, cw = max(0, w - 2 * p)
        icon.isHidden = true
        kindLabel.isHidden = true
        appLabel.isHidden = true
        buttons.forEach { $0.1.isHidden = true }
        let countWidth = countLabel.isHidden ? 0 : ceil(countLabel.textWidth)
        countLabel.frame = NSRect(x: w - p - countWidth, y: p, width: countWidth, height: 16)
        eyebrow.frame = NSRect(x: p, y: p, width: max(0, cw - countWidth - 8), height: 16)
        let dh = nativeDetailHeight(width: cw)
        let dy = p + 16 + Self.nativeGap
        detailLine.frame = NSRect(x: p, y: dy, width: cw, height: 16)
        detailBlock.frame = NSRect(x: p, y: dy, width: cw, height: dh)
        let by = dy + dh + Self.nativeGap
        var x = w - p
        for (_, button) in nativeButtons.reversed() {
            let bw = button.intrinsicContentSize.width
            x -= bw
            button.frame = NSRect(x: x, y: by + (Self.nativeButton - button.intrinsicContentSize.height) / 2, width: bw, height: button.intrinsicContentSize.height)
            x -= 8
        }
        if !more.isHidden {
            let size = more.intrinsicContentSize
            more.frame = NSRect(x: p, y: by + (Self.nativeButton - 24) / 2, width: size.width, height: 24)
        }
    }

    private func respond(_ decision: ApprovalDecision) {
        // Only live requests can be answered (ChatView.tsx:10114-10146).
        guard let approval, approval.canRespond, !isResponding else { return }
        onRespond?(decision, RuntimeRequestCommands.respond(threadId: threadId, requestId: approval.requestId, decision: decision))
    }

    private func openMenu() {
        guard let approval else { return }
        let items = approval.menuOptions.map { option in
            var item = MenuItem(option.label, icon: option.warning == nil ? nil : .triangleAlert)
            item.isDisabled = isResponding
            item.closesOnClick = true
            item.action = { [weak self] in self?.respond(option.decision) }
            return item
        }
        // ponytail: warning options show the triangle but no tooltip inside the menu; add with menu row tooltips
        MenuPopupView.show(items, from: more, placement: PopupPlacement(side: .top, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    // MARK: Layout

    private var actionViews: [NSView] { buttons.map(\.1) + (more.isHidden ? [] : [more]) }

    private var actionsWidth: CGFloat {
        let views = actionViews
        return views.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(max(0, views.count - 1)) * 6
    }

    private func detailHeight(width: CGFloat) -> CGFloat {
        detailBlock.isHidden ? 16 : min(Self.detailMaxHeight, max(16, detailBlock.height(forWidth: width)))
    }

    private func contentWidth(_ width: CGFloat) -> CGFloat {
        let x = Self.pad + Self.column + Self.gap
        return width < Self.narrow ? width - Self.pad - x : width - Self.pad - x - actionsWidth - Self.gap
    }

    /// The banner's full height at `width`, the 17px under the composer included.
    public func preferredHeight(width: CGFloat) -> CGFloat {
        // The native card has no overlap; the 17 keeps the caller's arithmetic the same in both styles.
        if nativeCard { return nativeHeight(width: width) + Self.overlap }
        let content = 16 + 4 + detailHeight(width: max(0, contentWidth(width)))
        let actionsRow: CGFloat = width < Self.narrow ? 12 + 24 : 0
        return Self.pad + content + actionsRow + Self.pad + Self.overlap
    }

    public override func layout() {
        super.layout()
        if nativeCard { return layoutNative() }
        let w = bounds.width, pad = Self.pad
        let x = pad + Self.column + Self.gap
        let cw = max(0, contentWidth(w))
        icon.frame = NSRect(x: pad + 4, y: pad + 2, width: 16, height: 16)

        var lx = x
        let kindWidth = ceil(kindLabel.textWidth)
        kindLabel.frame = NSRect(x: lx, y: pad, width: min(kindWidth, cw), height: 16)
        lx += kindWidth + 8
        let countWidth = countLabel.isHidden ? 0 : ceil(countLabel.textWidth)
        countLabel.frame = NSRect(x: x + cw - countWidth, y: pad, width: countWidth, height: 16)
        appLabel.frame = NSRect(x: lx, y: pad, width: max(0, x + cw - lx - (countWidth > 0 ? countWidth + 8 : 0)), height: 16)

        let dh = detailHeight(width: cw)
        detailLine.frame = NSRect(x: x, y: pad + 20, width: cw, height: 16)
        detailBlock.frame = NSRect(x: x, y: pad + 20, width: cw, height: dh)

        // Actions: right aligned, centered on the content row, or on their own row when narrow.
        let content = 20 + dh
        let ay = w < Self.narrow ? pad + content + 12 : pad + (content - 24) / 2
        var ax = w - pad - actionsWidth
        for view in actionViews {
            let size = view.intrinsicContentSize
            view.frame = NSRect(x: ax, y: ay, width: size.width, height: 24)
            ax += size.width + 6
        }
    }
}
