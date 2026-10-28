import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Nightly 3824 TimelinePendingApprovalRow.tsx:43-120 and ComposerPendingApprovalActions.tsx:49-141.
/// The default timeline uses a plain work row; classic themes keep ApprovalPanelView.
final class PendingApprovalInlineView: DSView {
    var onRespond: ((JSONValue) -> Void)?
    private var icon = IconView(name: .squarePen, size: 16, strokeColor: Themed.color(\.iconMuted))
    private let detail = NSTextView()
    private let scroll = NSScrollView()
    private let note = TextBlockView()
    private let shield = IconView(name: .shield, size: 12, strokeColor: Themed.color(\.warning))
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.warning))
    private let separator = LabelView("·", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let more = ThreadStatusLineAction()
    private let why = ThreadStatusLineAction()
    private var actions: [ThreadStatusLineAction] = []
    private var approval: PendingApproval?
    private var threadId: ThreadId = ""
    private var enabled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = false
        detail.drawsBackground = false
        detail.textContainerInset = .zero
        detail.textContainer?.lineFragmentPadding = 0
        detail.textContainer?.widthTracksTextView = true
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = detail
        status.lineHeight = 16
        separator.lineHeight = 16
        note.font = DSFont.ui(12)
        note.lineHeight = 16
        note.color = Themed.color(\.mutedForeground)
        more.label.text = "More"
        more.setAccessibilityLabel("More approval options")
        more.action = { [weak self] in self?.openMenu() }
        why.label.text = PendingApproval.fullAccessOverrideQuestion
        let tip = TooltipController.attach(to: why, text: "", delay: 0.3)
        tip.content = { [weak self] in
            NoticeDetailsPopupView(text: self?.approval?.fullAccessOverrideExplanation ?? "", maxWidth: 352,
                                   label: PendingApproval.fullAccessOverrideQuestion)
        }
        why.action = { [weak tip] in tip?.show(instant: true) }
        [icon, scroll, note, shield, status, separator, more, why].forEach(addSubview)
    }

    func configure(_ approval: PendingApproval, threadId: ThreadId, enabled: Bool) {
        self.approval = approval
        self.threadId = threadId
        self.enabled = enabled && approval.canRespond
        icon.removeFromSuperview()
        icon = IconView(name: approval.requestKind == .command ? .terminal : approval.requestKind == .fileRead ? .eye : approval.requestKind == .fileChange ? .squarePen : .wrench, size: 16, strokeColor: Themed.color(\.iconMuted))
        addSubview(icon)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        paragraph.lineBreakMode = .byCharWrapping
        detail.textStorage?.setAttributedString(NSAttributedString(string: approval.detailText, attributes: [
            .font: DSFont.mono(12), .foregroundColor: Themed.color(\.foreground), .paragraphStyle: paragraph]))
        detail.setAccessibilityLabel(approval.label)
        note.text = [approval.appName, approval.reason].compactMap { $0 }.joined(separator: "\n")
        note.isHidden = note.text.isEmpty
        status.text = approval.canRespond ? "Waiting for approval" : "Provider process is gone. Interrupt or restart the run to respond."
        shield.isHidden = !approval.canRespond
        actions.forEach { $0.removeFromSuperview() }
        actions = approval.canRespond ? approval.buttonOptions.map { option in
            let action = ThreadStatusLineAction()
            action.label.text = option.label
            action.tone = option.decision == .accept ? .foreground : .muted
            action.isEnabled = self.enabled
            action.action = { [weak self] in self?.respond(option.decision) }
            if let warning = option.warning { TooltipController.attach(to: action, text: warning) }
            addSubview(action)
            return action
        } : []
        more.isHidden = !approval.canRespond || approval.menuOptions.isEmpty
        more.isEnabled = self.enabled
        separator.isHidden = actions.isEmpty
        why.isHidden = approval.fullAccessOverrideExplanation == nil
        needsLayout = true
    }

    private func respond(_ decision: ApprovalDecision) {
        guard enabled, let approval else { return }
        onRespond?(RuntimeRequestCommands.respond(threadId: threadId, requestId: approval.requestId, decision: decision))
    }

    private func openMenu() {
        guard let approval else { return }
        let items = approval.menuOptions.map { option in
            MenuItem(option.label, icon: option.warning == nil ? nil : .triangleAlert, disabled: !enabled) { [weak self] in self?.respond(option.decision) }
        }
        MenuPopupView.show(items, from: more, placement: PopupPlacement(side: .top, align: .end), fitsContent: true)
    }

    private func detailHeight(_ width: CGFloat) -> CGFloat {
        min(160, max(22, ceil(detail.attributedString().boundingRect(with: NSSize(width: max(1, width - 32), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)))
    }
    private func noteHeight(_ width: CGFloat) -> CGFloat { note.isHidden ? 0 : note.height(forWidth: max(1, width - 32)) + 4 }
    private var actionViews: [NSView] { [shield, status, separator].filter { !$0.isHidden } + actions + [more, why].filter { !$0.isHidden } }
    private func width(_ view: NSView) -> CGFloat {
        if view === shield { return 12 }
        if let label = view as? LabelView { return label.textWidth }
        return (view as? ThreadStatusLineAction)?.label.textWidth ?? 0
    }
    private func actionHeight(_ width: CGFloat) -> CGFloat {
        var x: CGFloat = 32, y: CGFloat = 16
        for view in actionViews {
            let w = self.width(view)
            if x + w > width && x > 32 { x = 32; y += 20 }
            x += w + (view === shield ? 4 : 8)
        }
        return y
    }
    func height(forWidth width: CGFloat) -> CGFloat { detailHeight(width) + noteHeight(width) + actionHeight(width) + 4 }

    override func layout() {
        super.layout()
        let dh = detailHeight(bounds.width), nh = noteHeight(bounds.width)
        icon.frame = NSRect(x: 6, y: 2, width: 16, height: 16)
        scroll.frame = NSRect(x: 32, y: -1.5, width: max(0, bounds.width - 32), height: dh)
        let fullHeight = ceil(detail.attributedString().boundingRect(with: NSSize(width: max(1, scroll.bounds.width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        detail.setFrameSize(NSSize(width: scroll.bounds.width, height: max(dh, fullHeight)))
        note.frame = NSRect(x: 32, y: dh, width: max(0, bounds.width - 32), height: max(0, nh - 4))
        var x: CGFloat = 32, y = dh + nh
        for view in actionViews {
            let w = width(view)
            if x + w > bounds.width && x > 32 { x = 32; y += 20 }
            view.frame = NSRect(x: x, y: y + (view === shield ? 2 : 0), width: w, height: view === shield ? 12 : 16)
            x += w + (view === shield ? 4 : 8)
        }
    }
}
