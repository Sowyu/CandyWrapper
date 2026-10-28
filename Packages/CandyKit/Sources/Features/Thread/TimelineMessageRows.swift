import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Copies text and briefly swaps the icon to a check, like `MessageCopyButton` (1.2s).
@MainActor
func copyButton() -> ButtonView {
    let button = ButtonView(icon: .copy, variant: .ghostMuted, size: .xs)
    button.iconSize = 12
    button.setAccessibilityLabel("Copy message")
    button.toolTip = "Copy message"
    return button
}

@MainActor
func copy(_ text: String, from button: ButtonView) {
    NSPasteboard.general.clearContents()
    let copied = NSPasteboard.general.setString(text, forType: .string)
    AnchoredCopyToast.show(from: button, success: copied)
    button.icon = .check
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button] in button?.icon = .copy }
}

extension MarkdownLayout {
    /// The widest thing the layout drew, for shrink-to-fit boxes such as the user bubble.
    var contentWidth: CGFloat {
        items.reduce(0) { w, item in
            switch item {
            case .text(let box, let p): max(w, p.x + box.usedWidth)
            case .box(let r, _, _, _), .checkbox(let r, _), .icon(_, let r, _), .clip(let r): max(w, r.maxX)
            default: w
            }
        }
    }
}

/// `UserMessageIntentMarker` (MessagesTimeline.tsx:2562-2603): the line above a bubble that did
/// steered the active turn: a redo arrow and "Steer". Queued turns show none since 5cda25e72b
/// (TimelineUserMessageRow.tsx:290-293).
/// `me-1 flex items-center justify-end gap-1 text-xs leading-none text-muted-foreground`, icon `size-3`.
final class UserIntentMarkerView: DSView {
    static let height: CGFloat = 12
    private let icon = IconView(name: .redo2, size: 12, strokeColor: TL.c(\.mutedForeground))
    private let label = LabelView("", font: TL.font(12), color: TL.c(\.mutedForeground))

    /// Label, icon and tooltip for a steer, or nil for any other intent (TimelineUserMessageRow.tsx:463-483).
    static func presentation(_ intent: InputIntent?) -> (label: String, icon: Bool, tooltip: String)? {
        if intent == .steer { return ("Steer", true, "Steered the active turn") }
        if intent == .promotedQueuedToSteer { return ("Steer", true, "Originally queued, then promoted to steer the active turn") }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = Self.height
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ p: (label: String, icon: Bool, tooltip: String)) {
        label.text = p.label
        icon.isHidden = !p.icon
        toolTip = p.tooltip
        needsLayout = true
    }

    var fittingWidth: CGFloat { ceil(label.textWidth) + (icon.isHidden ? 0 : 12 + 4) }

    override func layout() {
        super.layout()
        let w = ceil(label.textWidth)
        label.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: Self.height)
        icon.frame = NSRect(x: label.frame.minX - 4 - 12, y: 0, width: 12, height: 12)
    }
}

/// The link at the start of a folded message's action row (TimelineUserMessageRow.tsx:197-205, 595-600), `text-xs`.
/// "Open automation" is a muted link underlined on hover; "Open thread" is an `InlineButton tone="muted"`
/// (medium, muted, foreground and underlined on hover).
final class FoldedMessageLinkView: ControlView {
    static let height: CGFloat = 16
    let label = LabelView("", font: TL.font(12), color: TL.c(\.mutedForeground))
    private var automation = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = Self.height
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(automation: Bool) {
        self.automation = automation
        label.text = automation ? "Open automation" : "Open thread"
        setAccessibilityLabel(label.text)
        restyle()
    }

    var fittingWidth: CGFloat { ceil(label.textWidth) + 1 }

    override func layout() { super.layout(); label.frame = bounds }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }

    private func restyle() {
        let hovered = state.hovered
        label.font = automation ? TL.font(12) : TL.font(12, .medium)
        label.color = hovered && !automation ? TL.c(\.foreground) : TL.c(\.mutedForeground)
        label.isUnderlined = hovered
    }
}

/// `FoldedMessageHeader` (TimelineUserMessageRow.tsx:227-262): the one-line button of a folded agent or
/// automation message. `flex items-center gap-1.5 px-3 py-2 text-sm`: a 16px muted icon, the muted label
/// (at most half the button), the summary taking the rest, and a 14px chevron that turns over when open.
final class FoldedMessageHeaderView: ControlView {
    static let height: CGFloat = 36
    private let agentIcon = IconView(name: .messagesSquare, size: 16, strokeColor: TL.c(\.mutedForeground))
    private let automationIcon = IconView(name: .calendarClock, size: 16, strokeColor: TL.c(\.mutedForeground))
    private let label = LabelView("", font: TL.font(14), color: TL.c(\.mutedForeground))
    private let summary = LabelView("", font: TL.font(14), color: TL.c(\.foreground))
    private let chevron = IconView(name: .chevronDown, size: 14, strokeColor: TL.c(\.mutedForeground))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 20
        summary.lineHeight = 20
        for v in [agentIcon, automationIcon, label, summary, chevron] as [NSView] { addSubview(v) }
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(automation: Bool, label: String, summary: String, expanded: Bool) {
        agentIcon.isHidden = automation
        automationIcon.isHidden = !automation
        self.label.text = label
        self.summary.text = summary
        chevron.setRotation(expanded ? 180 : 0)
        setAccessibilityLabel("\(label): \(summary)")
        setAccessibilityExpanded(expanded)
        needsLayout = true
    }

    /// The button's max-content width.
    var naturalWidth: CGFloat { 12 + 16 + 6 + ceil(label.textWidth) + 6 + ceil(summary.textWidth) + 6 + 14 + 12 }

    override func layout() {
        super.layout()
        let h = bounds.height
        agentIcon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        automationIcon.frame = agentIcon.frame
        chevron.frame = NSRect(x: bounds.width - 12 - 14, y: (h - 14) / 2, width: 14, height: 14)
        // `max-w-1/2 shrink-0` on the label, `min-w-0 flex-1` on the summary.
        let labelWidth = min(ceil(label.textWidth), bounds.width / 2)
        label.frame = NSRect(x: 12 + 16 + 6, y: (h - 20) / 2, width: labelWidth, height: 20)
        let summaryX = label.frame.maxX + 6
        summary.frame = NSRect(x: summaryX, y: label.frame.minY, width: max(0, chevron.frame.minX - 6 - summaryX), height: 20)
    }
}

/// `UserTimelineRow` (MessagesTimeline.tsx:2198-2560): a right-aligned bubble at most 80% of the
/// lane, then a hover row with the time and a copy button that always keeps its 24px. A steered or
/// queued message gets its intent marker above the bubble (`flex-col gap-1`).
// ponytail: no chatLaneInset, so an expanded table in a user bubble keeps scrolling in wide lanes; set it from the
// bubble width if tables in user messages turn up
final class UserMessageRowView: TimelineRowView {
    static let padding: CGFloat = 12
    static let collapsedHeight: CGFloat = 176
    static let fade: CGFloat = 28

    private let bubble = FillView()
    private let markdown = MarkdownView(frame: .zero)
    private let toggle = ButtonView("Show full message", variant: .ghostMuted, size: .xs)
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private let copyButton = Features.copyButton()
    private let editButton = ButtonView(icon: .pencil, variant: .ghostMuted, size: .xs)
    private let fadeMask = CAGradientLayer()
    private let marker = UserIntentMarkerView(frame: .zero)
    /// "Sent by T3 Code" over a message T3 Code sent itself (TimelineUserMessageRow.tsx:429-436), `me-1 text-2xs text-muted-foreground/70`.
    private let attribution = LabelView("Sent by T3 Code", font: TL.font(11), color: TL.c(\.mutedForeground, 0.7))
    /// Messages from other agents and automations fold to one line (TimelineUserMessageRow.tsx:128-225, 298-302).
    private let foldHeader = FoldedMessageHeaderView()
    private let openLink = FoldedMessageLinkView()
    private var fold: UserMessagePresentation.Attribution?
    private var text = ""
    private var collapsible = false
    /// The image grid and file rows above the text (MessagesTimeline.tsx:2402-2490).
    private let attachments = UserMessageAttachmentsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.fill = TL.c(\.messageSurface)
        bubble.radius = 18
        bubble.pane = true
        attribution.lineHeight = 16
        addSubview(attribution)
        addSubview(marker)
        addSubview(bubble)
        // `text-foreground` on the bubble, where assistant markdown sits at 80%.
        markdown.bodyColor = TL.c(\.foreground)
        bubble.addSubview(markdown)
        // Over the bubble, not in it: the bubble takes no clicks (`FillView`), the images do.
        addSubview(attachments)
        bubble.addSubview(toggle)
        addSubview(foldHeader)
        addSubview(openLink)
        foldHeader.action = { [weak self] in
            guard let self, case .message(let m, _, _, _, _, _)? = self.item?.row.kind else { return }
            self.context.model?.toggleMessage(m.id.rawValue)
        }
        time.lineHeight = 16
        addSubview(time)
        addSubview(copyButton)
        addSubview(editButton)
        editButton.setAccessibilityLabel("Edit from here")
        editButton.toolTip = "Edit from here"
        editButton.action = { [weak self] in
            guard let self, let m = self.item?.row.message else { return }
            self.context.model?.onEditPrompt?(m)
        }
        fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        toggle.action = { [weak self] in
            guard let self, case .message(let m, _, _, _, _, _)? = self.item?.row.kind else { return }
            self.context.model?.toggleMessage(m.id.rawValue)
        }
        copyButton.action = { [weak self] in
            guard let self else { return }
            Features.copy(self.text, from: self.copyButton)
        }
        openLink.action = { [weak self] in
            guard let self, case .message(let m, _, _, _, _, _)? = self.item?.row.kind else { return }
            let p = UserMessagePresentation.resolve(m)
            if p.isAutomation { if let task = p.scheduledTaskId { self.context.model?.onOpenScheduledTask?(task) } }
            else if let sender = m.senderThreadId { self.context.model?.onOpenThread?(ThreadId(sender)) }
        }
        hoverChanged()
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .message(let m, _, _, _, _, _) = item.row.kind else { return }
        let presentation = UserMessagePresentation.resolve(m)
        text = presentation.text
        // "Sent by T3 Code", or in its place a guest's name (`GuestMessageName`, guestMessageStyle.tsx at 3669),
        // which VoiceOver skips because the row's heading names the guest (TimelineUserMessageRow.tsx:433-438).
        attribution.text = presentation.guestName ?? "Sent by T3 Code"
        attribution.color = presentation.guestName == nil ? TL.c(\.mutedForeground, 0.7) : GuestColors.foreground
        attribution.setAccessibilityElement(presentation.guestName == nil)
        attribution.isHidden = presentation.attribution != .t3code && presentation.guestName == nil
        // A guest's message sits on `bg-guest-surface` (TimelineUserMessageRow.tsx:443-447 at 3669).
        let fill = presentation.guestName == nil ? TL.c(\.messageSurface) : GuestColors.surface
        if bubble.fill !== fill { bubble.fill = fill }
        fold = presentation.attribution == .agent || presentation.isAutomation ? presentation.attribution : nil
        foldHeader.isHidden = fold == nil
        if let fold {
            let automation = fold == .automation
            let label = automation ? "Automation" : item.ui.foldTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent"
            // Automation: the task's title, else the prompt's first line. Agent: the first non-blank line, context links as their labels.
            let summary = automation
                ? item.ui.foldTitle ?? Self.firstLine(text.trimmingCharacters(in: .whitespacesAndNewlines))
                : Self.foldSummary(ComposerInlineTokens.contextLabels(text))
            foldHeader.configure(automation: automation, label: label, summary: summary, expanded: item.ui.messageExpanded)
            openLink.configure(automation: automation)
        }
        openLink.isHidden = fold == nil || !item.ui.messageExpanded || (fold == .automation ? presentation.scheduledTaskId == nil : m.senderThreadId == nil)
        let open = fold == nil || item.ui.messageExpanded
        markdown.isHidden = !open
        attachments.isHidden = !open
        for v in [time, copyButton] as [NSView] { v.isHidden = !open }
        editButton.isHidden = (m.inputIntent != .turnStart && m.inputIntent != .queuedTurn) || (fold != nil && !item.ui.messageExpanded)
        markdown.inlineSkills = context.model?.inlineSkills ?? []
        markdown.cwd = context.markdownCwd
        markdown.onOpenFile = context.model?.openFile
        // `renderContextReference` (MessagesTimeline.tsx:2305-2345): context links draw as chips.
        let model = context.model
        let document = context.document(item.id, text, lineBreaks: true)
        markdown.contextChips = MarkdownContextChips.message(context: m.context, attachments: m.attachments, document: document,
                                                             thread: { model?.linkedThread?(ThreadId($0)) })
        if let load = model?.attachmentImage {
            markdown.contextImageLoader = { id, side in await load(id, side, true) }
        } else {
            markdown.contextImageLoader = nil
        }
        markdown.onContextChip = { [weak self] action, _ in self?.openContextChip(action, message: m) }
        markdown.document = document
        attachments.configure(m, model: context.model)
        // A folded message is never collapsible (`collapsible={!folded}`).
        collapsible = fold == nil && shouldCollapseUserMessage(text)
        toggle.title = item.ui.messageExpanded ? "Show less" : "Show full message"
        toggle.isHidden = !collapsible
        time.text = TL.dayAwareTimestamp(m.createdAt, now: context.now())
        time.toolTip = nil
        let intent = UserIntentMarkerView.presentation(m.inputIntent)
        marker.isHidden = intent == nil
        if let intent { marker.configure(intent) }
        needsLayout = true
    }

    /// A match below a collapsed message's fold opens it (`data-thread-find-fold`, MessagesTimeline.tsx:4737-4740).
    override func activeFindRect() -> CGRect? {
        // A match inside a folded message opens it, as T3's `beforematch` does (TimelineUserMessageRow.tsx:449-458).
        if fold != nil, item?.ui.messageExpanded != true, case .message(let m, _, _, _, _, _)? = item?.row.kind {
            context.model?.toggleMessage(m.id.rawValue)
            return nil
        }
        guard let rect = markdown.activeFindRect() else { return nil }
        if collapsible, item?.ui.messageExpanded != true, rect.maxY > Self.collapsedHeight - Self.fade,
           case .message(let m, _, _, _, _, _)? = item?.row.kind {
            context.model?.toggleMessage(m.id.rawValue)
            return nil
        }
        return markdown.convert(rect, to: self)
    }

    override func setContentVisible(_ visible: Bool) { attachments.setMediaVisible(visible) }
    override func prepareForReuse() { attachments.setMediaVisible(false); super.prepareForReuse() }

    /// `text.split(/\r?\n/, 1)[0]`.
    static func firstLine(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// `foldSummary` (TimelineUserMessageRow.tsx:329-333): the first non-blank line, trimmed.
    static func foldSummary(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// A context chip click (MessagesTimeline.tsx:4243-4709): a mention previews its file, a thread
    /// opens, an image opens the media viewer over the message's images, a file opens, a pull
    /// request opens through the link handler.
    private func openContextChip(_ action: MarkdownContextChip.Action, message m: ChatMessage) {
        guard let model = context.model else { return }
        switch action {
        case .openFile(let path):
            let base = (path as NSString).lastPathComponent
            model.openFile?(FileLinkMeta(filePath: path, targetPath: path, workspaceRelativePath: path, basename: base, line: nil, column: nil), false)
        case .openThread(let id):
            model.onOpenThread?(ThreadId(id))
        case .expandImage(let id):
            guard let loader = model.attachmentImage else { return }
            let images = m.attachments.filter { $0["type"]?.stringValue == "image" && !($0["name"]?.stringValue ?? "").hasPrefix("preview-annotation-") }
            let items = images.map { image in
                let imageId = image["id"]?.stringValue ?? ""
                let source = image["source"].flatMap { $0["kind"]?.stringValue == "snap-shot" ? $0 : nil }
                return ExpandedImagePreviewView.Item(key: imageId, name: image["name"]?.stringValue ?? "image", source: source, cacheable: true) { side in await loader(imageId, side, false) }
            }
            guard let index = items.firstIndex(where: { $0.key == id }) else { return }
            model.onExpandImage?(items, index)
        case .openAttachment(let id):
            guard let file = m.attachments.first(where: { $0["id"]?.stringValue == id }) else { return }
            model.onOpenAttachment?(file, false)
        case .openURL(let url):
            guard let u = URL(string: url) else { return }
            if let handler = MarkdownView.linkHandler { handler.openLink(u, from: markdown) } else if SafeExternalURL.isSafe(u) { NSWorkspace.shared.open(u) }
        case .terminal, .skill, .none:
            break
        }
    }

    /// The attribution and marker lines, each with the 4px gap under it (`flex-col gap-1`).
    private var attributionSpace: CGFloat { attribution.isHidden ? 0 : 16 + 4 }
    private var markerSpace: CGFloat { attributionSpace + (marker.isHidden ? 0 : UserIntentMarkerView.height + 4) }

    private func metrics(_ width: CGFloat) -> (bubble: CGFloat, attachments: CGFloat, body: CGFloat, full: CGFloat) {
        let maxBubble = width * 0.8
        if fold != nil {
            // Folded: the header's max-content width. Open: `w-full`, the body under the header in `px-3 pb-3`.
            // ponytail: no `max-h-96 overflow-auto` on the open body, so a long folded prompt shows in full; add an inner scroll view if that bothers
            guard item?.ui.messageExpanded == true else { return (min(maxBubble, foldHeader.naturalWidth), 0, 0, 0) }
            let inner = maxBubble - Self.padding * 2
            let full = markdown.height(forWidth: inner)
            return (maxBubble, attachments.height(forWidth: inner), full, full)
        }
        let inner = maxBubble - Self.padding * 2
        // `fit-content`: the max-content width (unwrapped) if it fits, else the full 80%.
        let natural = max(markdown.layout(forWidth: 100_000).contentWidth, attachments.naturalWidth)
        var bubbleWidth = natural > inner ? maxBubble : min(maxBubble, ceil(natural * 64) / 64 + Self.padding * 2)
        if collapsible { bubbleWidth = max(bubbleWidth, min(maxBubble, toggle.intrinsicContentSize.width - 4 + Self.padding * 2)) }
        // MessagesTimeline.tsx:2420-2528 puts attachments before CollapsibleUserMessageBody.
        // Only the prompt text uses its 176pt fold; images always keep their full height.
        let attachmentsHeight = attachments.height(forWidth: bubbleWidth - Self.padding * 2)
        let full = markdown.height(forWidth: bubbleWidth - Self.padding * 2)
        let expanded = item?.ui.messageExpanded ?? false
        let body = collapsible && !expanded ? min(full, Self.collapsedHeight) : full
        return (bubbleWidth, attachmentsHeight, body, full)
    }

    /// The bubble's hairline, for tests.
    var bubbleBorder: NSColor? { bubble.border }

    /// The bubble's width in a lane `width` wide, for tests.
    func bubbleWidth(forWidth width: CGFloat) -> CGFloat { metrics(width).bubble }

    override func height(forWidth width: CGFloat) -> CGFloat {
        let m = metrics(width)
        if fold != nil {
            let header = markerSpace + FoldedMessageHeaderView.height
            return item?.ui.messageExpanded == true ? header + m.attachments + m.body + Self.padding + 4 + 24 + 16 : header + 16
        }
        let footer: CGFloat = collapsible ? 6 + 24 : 0
        return markerSpace + m.attachments + m.body + footer + Self.padding * 2 + 4 + 24 + 16
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let m = metrics(width)
        let footer: CGFloat = collapsible ? 6 + 24 : 0
        // A folded message's body sits under its 36px header with `px-3 pb-3`.
        let bodyTop = fold == nil ? Self.padding : FoldedMessageHeaderView.height
        let open = fold == nil || item?.ui.messageExpanded == true
        let bubbleHeight = fold == nil ? m.attachments + m.body + footer + Self.padding * 2
            : bodyTop + (open ? m.attachments + m.body + Self.padding : 0)
        let top = markerSpace
        let attributionWidth = ceil(attribution.textWidth) + 1
        attribution.frame = NSRect(x: width - 4 - attributionWidth, y: 0, width: attributionWidth, height: 16)
        let markerWidth = marker.fittingWidth
        marker.frame = NSRect(x: width - 4 - markerWidth, y: attributionSpace, width: markerWidth, height: UserIntentMarkerView.height)
        bubble.frame = NSRect(x: width - m.bubble, y: top, width: m.bubble, height: bubbleHeight)
        foldHeader.frame = NSRect(x: width - m.bubble, y: top, width: m.bubble, height: FoldedMessageHeaderView.height)
        let attachmentsHeight = m.attachments
        attachments.frame = NSRect(x: width - m.bubble + Self.padding, y: top + bodyTop, width: m.bubble - Self.padding * 2, height: attachmentsHeight)
        markdown.frame = NSRect(x: Self.padding, y: bodyTop + attachmentsHeight, width: m.bubble - Self.padding * 2, height: m.full)
        let clipped = collapsible && m.body < m.full
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if clipped {
            // `linear-gradient(to bottom, black calc(100% - 1.75rem), transparent)` over the clamped body.
            fadeMask.frame = CGRect(x: 0, y: 0, width: markdown.bounds.width, height: m.full)
            fadeMask.locations = [0, NSNumber(value: Double((m.body - Self.fade) / m.full)), NSNumber(value: Double(m.body / m.full))]
            markdown.layer?.mask = fadeMask
        } else {
            markdown.layer?.mask = nil
        }
        CATransaction.commit()
        bubble.layer?.masksToBounds = true
        let size = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: Self.padding - 4, y: Self.padding + attachmentsHeight + m.body + 6, width: size.width, height: size.height)
        // Hover row: `max-w-[80%] justify-end pe-1 gap-2`, 24px tall under a 4px gap.
        let rowTop = top + bubbleHeight + 4
        let copySize = copyButton.intrinsicContentSize
        copyButton.frame = NSRect(x: width - 4 - copySize.width, y: rowTop, width: copySize.width, height: 24)
        editButton.frame = NSRect(x: copyButton.frame.minX - 28, y: rowTop, width: 24, height: 24)
        let timeWidth = ceil(time.textWidth)
        time.frame = NSRect(x: (editButton.isHidden ? copyButton.frame.minX : editButton.frame.minX) - 8 - timeWidth, y: rowTop + 4, width: timeWidth, height: 16)
        let linkWidth = openLink.fittingWidth
        openLink.frame = NSRect(x: time.frame.minX - 8 - linkWidth, y: rowTop + 4, width: linkWidth, height: FoldedMessageLinkView.height)
    }

    /// T3 puts `group` on the bubble column (MessagesTimeline.tsx:2359), not on the row, so the
    /// row's `pb-4` under the hover line does not reveal it.
    override var tracksPointerMoves: Bool { true }
    override func hoverChanged() {
        let inGroup = pointer.map { $0.y < bounds.height - 16 } ?? false
        Self.reveal([time, copyButton, editButton, openLink], inGroup || focusWithin)
    }
}

/// `WorkflowOpeningBlock` (WorkflowOpeningBlock.tsx:39-104, 202-236): a workflow coordinator's thread opens
/// with "Workflow started" in place of its script: the workflow's name and description with its agent counts,
/// each phase that has members with its members, the members outside phases, then the script as a fenced block
/// folded like a long message. `flex-col gap-3 px-1 py-0.5`, then the row's `pb-4`. The plan comes from the
/// parent thread's coordinator row (`item.ui.workflowCoordinator`), so until that loads only the script shows.
final class WorkflowOpeningRowView: TimelineRowView {
    private let icon = IconView(name: .workflow, size: 14, strokeColor: TL.c(\.mutedForeground))
    private let eyebrow = LabelView("Workflow started", font: TL.font(11, .medium), color: TL.c(\.mutedForeground))
    private let title = LabelView("Workflow", font: TL.font(14, .medium), color: TL.c(\.foreground))
    /// `text-xs text-muted-foreground`, wrapping.
    private let summary = TextBlockView("", font: TL.font(12), lineHeight: 16, color: TL.c(\.mutedForeground))
    /// `text-2xs tabular-nums text-muted-foreground`, at the header's right.
    private let agents = LabelView("", font: SB.tabular(11), color: TL.c(\.mutedForeground))
    private let markdown = MarkdownView(frame: .zero)
    private let toggle = ButtonView("Show full script", variant: .ghostMuted, size: .xs)
    private let fadeMask = CAGradientLayer()
    private var collapsible = false
    /// One phase heading (`px-2 pb-0.5 text-2xs font-medium`) with its "settled/total", then its member rows.
    private struct Section { let heading: LabelView?; let count: LabelView?; let members: [SubagentCardLinkView] }
    private var sections: [Section] = []
    private var plan = WorkflowOpening.Plan()

    /// The script as a fenced block one backtick longer than its longest run (`scriptMarkdown`, :31-36).
    static func scriptMarkdown(_ script: String) -> String {
        var longest = 2, run = 0
        for c in script { run = c == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: longest + 1)
        var body = script
        while body.last?.isWhitespace == true { body.removeLast() }
        return "\(fence)javascript\n\(body)\n\(fence)"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eyebrow.lineHeight = 16
        title.lineHeight = 20
        agents.lineHeight = 16
        markdown.chatLaneInset = 8
        for v in [icon, eyebrow, title, summary, agents, markdown, toggle] as [NSView] { addSubview(v) }
        fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        toggle.action = { [weak self] in
            guard let self, case .message(let m, _, _, _, _, _)? = self.item?.row.kind else { return }
            self.context.model?.toggleMessage(m.id.rawValue)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Workflow started: Workflow")
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .message(let m, _, _, _, _, _) = item.row.kind else { return }
        let next = WorkflowOpening.Plan(coordinator: item.ui.workflowCoordinator)
        if next != plan { plan = next; rebuildPlan() }
        let headline = plan.headline
        title.text = headline.title
        summary.text = headline.description ?? ""
        summary.isHidden = headline.description == nil
        agents.text = headline.agents ?? ""
        agents.isHidden = headline.agents == nil
        setAccessibilityLabel("Workflow started: \(headline.title)")
        markdown.cwd = nil
        markdown.document = context.document(item.id, Self.scriptMarkdown(m.text), lineBreaks: false)
        collapsible = shouldCollapseUserMessage(m.text)
        toggle.title = item.ui.messageExpanded ? "Show less" : "Show full script"
        toggle.isHidden = !collapsible
        toggle.setAccessibilityExpanded(item.ui.messageExpanded)
        needsLayout = true
    }

    /// Phases with members, then the members outside phases (:46-100). Members show only once the coordinator
    /// names its provider instance (`memberRow`, :48-59).
    private func rebuildPlan() {
        for section in sections {
            section.heading?.removeFromSuperview(); section.count?.removeFromSuperview()
            section.members.forEach { $0.stop(); $0.removeFromSuperview() }
        }
        sections = []
        guard let group = plan.group else { return }
        func rows(_ members: [SubagentWorkflowGroup.Member]) -> [SubagentCardLinkView] {
            guard plan.providerInstanceId != nil else { return [] }
            return members.map { member in
                let link = SubagentCardLinkView()
                link.configure(SubagentCardPresentation(member: member, driver: plan.driver))
                link.action = { [weak self] in if let child = member.childThreadId { self?.context.model?.onOpenThread?(child) } }
                addSubview(link)
                return link
            }
        }
        for phase in group.phases where !phase.members.isEmpty {
            let heading = LabelView(phase.title, font: TL.font(11, .medium), color: TL.c(\.mutedForeground))
            let count = LabelView("\(phase.settledCount)/\(phase.members.count)", font: SB.tabular(11), color: TL.c(\.mutedForeground))
            heading.lineHeight = 16; count.lineHeight = 16
            addSubview(heading); addSubview(count)
            sections.append(Section(heading: heading, count: count, members: rows(phase.members)))
        }
        if !group.unphased.isEmpty { sections.append(Section(heading: nil, count: nil, members: rows(group.unphased))) }
    }

    /// A match below the fold opens it (`findRevealRef`, :204).
    override func activeFindRect() -> CGRect? {
        guard let rect = markdown.activeFindRect() else { return nil }
        if collapsible, item?.ui.messageExpanded != true, rect.maxY > UserMessageRowView.collapsedHeight - UserMessageRowView.fade,
           case .message(let m, _, _, _, _, _)? = item?.row.kind {
            context.model?.toggleMessage(m.id.rawValue)
            return nil
        }
        return markdown.convert(rect, to: self)
    }

    override func setContentVisible(_ visible: Bool) { sections.forEach { $0.members.forEach { $0.contentVisible = visible } } }
    override func prepareForReuse() {
        super.prepareForReuse()
        plan = WorkflowOpening.Plan()
        rebuildPlan()
    }

    /// The header: eyebrow, title (`gap-0.5`) and the wrapping description under it.
    private func header(_ width: CGFloat) -> CGFloat {
        16 + 2 + 20 + (summary.isHidden ? 0 : 2 + summary.height(forWidth: textWidth(width)))
    }
    private func textWidth(_ width: CGFloat) -> CGFloat {
        max(0, width - 4 - 26 - (agents.isHidden ? 0 : 8 + ceil(agents.textWidth)))
    }
    private func sectionHeight(_ section: Section) -> CGFloat {
        (section.heading == nil ? 0 : 16 + 2) + section.members.reduce(0) { $0 + SubagentCardLinkView.height($1.presentation!) }
    }

    private func body(_ width: CGFloat) -> (shown: CGFloat, full: CGFloat) {
        let full = markdown.height(forWidth: max(0, width - 8))
        let folded = collapsible && item?.ui.messageExpanded != true
        return (folded ? min(full, UserMessageRowView.collapsedHeight) : full, full)
    }

    /// Where the script starts: the header, then each section after `gap-3`.
    private func scriptTop(_ width: CGFloat) -> CGFloat {
        2 + header(width) + sections.reduce(0) { $0 + 12 + sectionHeight($1) } + 12
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        scriptTop(width) + body(width).shown + (collapsible ? 24 : 0) + 2 + 16
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        icon.frame = NSRect(x: 4, y: 4, width: 14, height: 14)
        let aw = agents.isHidden ? 0 : ceil(agents.textWidth)
        agents.frame = NSRect(x: width - 4 - aw, y: 2, width: aw, height: 16)
        let tw = textWidth(width)
        eyebrow.frame = NSRect(x: 26, y: 2, width: tw, height: 16)
        title.frame = NSRect(x: 26, y: 20, width: tw, height: 20)
        summary.frame = NSRect(x: 26, y: 42, width: tw, height: summary.isHidden ? 0 : summary.height(forWidth: tw))
        var y = 2 + header(width)
        for section in sections {
            y += 12
            if let heading = section.heading, let count = section.count {
                // `flex items-baseline gap-2 px-2`: the title truncates before the count.
                let cw = ceil(count.textWidth)
                let hw = min(ceil(heading.textWidth), max(0, width - 8 - 16 - 8 - cw))
                heading.frame = NSRect(x: 4 + 8, y: y, width: hw, height: 16)
                count.frame = NSRect(x: heading.frame.maxX + 8, y: y, width: cw, height: 16)
                y += 16 + 2
            }
            for link in section.members {
                let h = SubagentCardLinkView.height(link.presentation!)
                link.frame = NSRect(x: 4, y: y, width: max(0, width - 8), height: h)
                y += h
            }
        }
        let b = body(width)
        let top = scriptTop(width)
        markdown.frame = NSRect(x: 4, y: top, width: max(0, width - 8), height: b.full)
        layer?.masksToBounds = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if b.shown < b.full {
            // `FOLDED_SCRIPT_MASK`: `linear-gradient(to bottom, black calc(100% - 1.75rem), transparent)`.
            let fade = UserMessageRowView.fade
            fadeMask.frame = CGRect(x: 0, y: 0, width: markdown.bounds.width, height: b.full)
            fadeMask.locations = [0, NSNumber(value: Double((b.shown - fade) / b.full)), NSNumber(value: Double(b.shown / b.full))]
            markdown.layer?.mask = fadeMask
        } else {
            markdown.layer?.mask = nil
        }
        CATransaction.commit()
        let size = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: 0, y: top + b.shown, width: size.width, height: size.height)
    }
}

/// `AssistantTimelineRow` (:2745-2793): markdown in `px-1 py-0.5`, then the meta row that shows on
/// hover when this is the turn's final answer. 16px under a final answer, 8px under commentary.
final class AssistantMessageRowView: TimelineRowView {
    private let markdown = MarkdownView(frame: .zero)
    private let empty = LabelView("(empty response)", font: TL.font(14), color: TL.c(\.foreground, 0.8))
    private let meta = AssistantMetaContent()
    private var showMeta = false
    /// `AssistantChangedFilesSection`: the card when the run changed files.
    private lazy var card = ChangedFilesCardView()
    private var cardFiles: (files: [CheckpointFile], expanded: Bool, overrides: [String: Bool])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(markdown)
        markdown.chatLaneInset = 8
        empty.lineHeight = TL.relaxed
        addSubview(empty)
        addSubview(meta)
        meta.alphaValue = 0
    }

    override func configure(_ item: TimelineItem) {
        let sameRow = self.item?.id == item.id
        super.configure(item)
        guard case .message(let m, let projected, let showMeta, let showCopy, let copyStreaming, let summary) = item.row.kind else { return }
        self.showMeta = showMeta
        // Blocks fade in only while the message streams. T3's `@starting-style` also fades the blocks a
        // streaming message mounts with, so a view that starts showing one fades from no blocks.
        if !sameRow {
            markdown.cancelBlockFades()
            if m.streaming { markdown.document = MarkdownDocument(blocks: []) }
        }
        markdown.onHeightChange = { [weak self] in
            guard let self, let id = self.item?.id else { return }
            self.context.onMarkdownHeightChange?(id)
        }
        markdown.messageID = m.id.rawValue
        // A long answer parses and lays out off the main thread; until then it holds the timeline's estimated height.
        let long = m.text.utf8.count >= TimelineContext.backgroundBytes
        markdown.laysOutInBackground = long
        markdown.pendingHeight = long ? { [text = m.text] width in TimelineView.estimatedLines(text, width: width) * 22.75 } : nil
        // The timeline caches this row's height with the reader's choices, so a recycled view takes them back.
        markdown.layoutChoices = context.markdownChoices[m.id.rawValue] ?? .init()
        markdown.onLayoutChoicesChange = { [weak context] in context?.markdownChoices[m.id.rawValue] = $0 }
        markdown.fadesNewBlocks = m.streaming
        if let summary, !summary.files.isEmpty {
            cardFiles = (summary.files, item.ui.filesExpanded, item.ui.folderOverrides)
            if card.superview == nil { addSubview(card) }
            card.model = context.model
            card.configure(summary, allExpanded: item.ui.filesExpanded, overrides: item.ui.folderOverrides)
            card.isHidden = false
        } else {
            cardFiles = nil
            if card.superview != nil { card.isHidden = true }
        }
        let isEmpty = !m.streaming && m.text.allSatisfy(\.isWhitespace)
        empty.isHidden = !isEmpty
        markdown.isHidden = isEmpty
        markdown.inlineSkills = context.model?.inlineSkills ?? []
        markdown.cwd = context.markdownCwd
        markdown.onOpenFile = context.model?.openFile
        // A closed fence draws its diagram while the message streams; only the fence still being written waits.
        // ponytail: a diagram that appears mid-stream skips T3's 600ms fade (`.chat-markdown-mermaid`, index.css:2047-2049);
        // give it a fade band if the switch from code reads as a jump.
        markdown.streamsInOpenFence = m.streaming && MarkdownLayout.endsInOpenFence(m.text)
        markdown.streaming = m.streaming
        // A streaming answer has no Run buttons (ChatMarkdown.tsx:3368-3372).
        markdown.onRunShellCommand = m.streaming ? nil : context.model?.runShellCommand
        markdown.citationSourceID = m.id.rawValue
        // `MarkdownThreadLink` (ChatMarkdown.tsx:1067-1074): `t3-thread://` links draw as thread chips.
        let model = context.model
        let document = isEmpty ? MarkdownDocument(blocks: []) : context.document(item.id, m.text, lineBreaks: TL.preservesAssistantLineBreaks(m.text), streaming: m.streaming,
                                                                                                         background: true)
        markdown.contextChips = MarkdownContextChips.links(in: document, thread: { model?.linkedThread?(ThreadId($0)) })
        markdown.onContextChip = { action, _ in if case .openThread(let id) = action { model?.onOpenThread?(ThreadId(id)) } }
        markdown.onCiteSelection = m.streaming ? nil : { [weak model = context.model] selection, anchor in
            model?.onCiteSelection?(m.id.rawValue, selection, anchor)
        }
        markdown.document = document
        meta.isHidden = !showMeta
        meta.configure(m, projected: projected, showCopy: showCopy, streaming: copyStreaming, now: context.now(), fork: context.forkAction(projected))
        needsLayout = true
    }

    private func bodyHeight(_ width: CGFloat) -> CGFloat {
        empty.isHidden ? markdown.height(forWidth: max(0, width - 8)) : TL.relaxed
    }

    /// The answer's trailing `<p>` margin collapses with the card's `mt-4` or the meta row's `mt-1.5` (CSS margin
    /// collapsing through the row's wrappers, MessagesTimeline.tsx:2751-2786).
    private func collapsedMargin(_ width: CGFloat) -> CGFloat {
        guard empty.isHidden else { return 0 }
        let m = markdown.layout(forWidth: max(0, width - 8)).trailingMargin
        return cardFiles != nil ? min(m, 16) : showMeta ? min(m, 6) : 0
    }

    /// The card's height plus its `mt-4`, or 0.
    private var cardSpace: CGFloat {
        guard let cardFiles else { return 0 }
        return 16 + ChangedFilesCardView.height(cardFiles.files, allExpanded: cardFiles.expanded, overrides: cardFiles.overrides)
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        2 + bodyHeight(width) - collapsedMargin(width) + cardSpace + (showMeta ? 6 + 24 : 0) + 2 + (showMeta ? 16 : 8)
    }

    override func layout() {
        super.layout()
        let body = bodyHeight(bounds.width)
        markdown.frame = NSRect(x: 4, y: 2, width: max(0, bounds.width - 8), height: body)
        empty.frame = NSRect(x: 4, y: 2, width: bounds.width - 8, height: TL.relaxed)
        let cardSpace = self.cardSpace, flow = body - collapsedMargin(bounds.width)
        if cardSpace > 0 {
            card.frame = NSRect(x: 4, y: 2 + flow + 16, width: max(0, bounds.width - 8), height: cardSpace - 16)
            card.updateVisibleRows()
        }
        meta.frame = NSRect(x: 4, y: 2 + flow + cardSpace + 6, width: bounds.width - 8, height: 24)
    }

    override func setContentVisible(_ visible: Bool) {
        if cardFiles != nil { card.updateVisibleRows() }
    }

    /// `group/assistant` sits on the whole row, padding included (MessagesTimeline.tsx:2032-2035).
    override func hoverChanged() { Self.reveal([meta], hovered || focusWithin) }
}

/// `AssistantMessageMeta` (:2860-2912): status pill, copy button, fork button, time; `gap-2`, `text-xs`.
final class AssistantMetaContent: DSView {
    private let pill = FillView()
    private let pillLabel = LabelView("", font: DSFont.mono(10), color: TL.c(\.mutedForeground))
    private let copyButton = Features.copyButton()
    /// `AssistantForkButton` (:2795-2838): `xs ghost`, a 12pt git-fork, "Fork from this response".
    private let forkButton = ButtonView(nil, icon: .gitFork, variant: .ghost, size: .xs)
    private var fork: (() -> Void)?
    private let time = LabelView("", font: TL.tabular(12), color: TL.c(\.mutedForeground))
    private var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pill.border = TL.c(\.border, 0.7)
        pill.radius = 999
        addSubview(pill)
        pillLabel.lineHeight = 14
        pill.addSubview(pillLabel)
        addSubview(copyButton)
        forkButton.iconSize = 12
        forkButton.setAccessibilityLabel("Fork from this response")
        _ = TooltipController.attach(to: forkButton, text: "Fork from this response", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        forkButton.action = { [weak self] in
            guard let self, let fork = self.fork else { return }
            // `disabled={busy}` until the fork settles; the row is rebuilt after it.
            self.forkButton.isEnabled = false
            fork()
        }
        forkButton.isHidden = true
        addSubview(forkButton)
        time.lineHeight = 16
        addSubview(time)
        copyButton.action = { [weak self] in
            guard let self else { return }
            Features.copy(self.text, from: self.copyButton)
        }
    }

    func configure(_ m: ChatMessage, projected: ProjectedTurnItem?, showCopy: Bool, streaming: Bool, now: Date, fork: (() -> Void)? = nil) {
        self.fork = fork
        forkButton.isHidden = fork == nil
        forkButton.isEnabled = true
        text = m.text
        let status = projected?.item.status.rawValue
        pill.isHidden = status == nil || status == "completed"
        pillLabel.text = status ?? ""
        copyButton.isHidden = !TimelineRows.copyState(text: m.text, showCopyButton: showCopy, streaming: streaming).visible
        time.isHidden = m.streaming
        time.text = TL.dayAwareTimestamp(m.updatedAt, now: now)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if !pill.isHidden {
            let w = ceil(pillLabel.textWidth) + 14
            pill.frame = NSRect(x: x, y: 4, width: w, height: 16)
            pillLabel.frame = NSRect(x: 7, y: 1, width: w - 14, height: 14)
            x += w + 8
        }
        if !copyButton.isHidden {
            let size = copyButton.intrinsicContentSize
            copyButton.frame = NSRect(x: x, y: 0, width: size.width, height: 24)
            x += size.width + 8
        }
        if !forkButton.isHidden {
            let size = forkButton.intrinsicContentSize
            forkButton.frame = NSRect(x: x, y: 0, width: size.width, height: 24)
            x += size.width + 8
        }
        time.frame = NSRect(x: x, y: 4, width: ceil(time.textWidth) + 1, height: 16)
    }
}

/// The standalone `assistant-meta` row (:2841-2858): `px-1`, `mt-0.5`, always visible.
final class AssistantMetaRowView: TimelineRowView {
    private let meta = AssistantMetaContent()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(meta)
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .assistantMeta(let m, let projected, let showCopy, let streaming) = item.row.kind else { return }
        meta.configure(m, projected: projected, showCopy: showCopy, streaming: streaming, now: context.now(), fork: context.forkAction(projected))
    }

    override func height(forWidth width: CGFloat) -> CGFloat { 2 + 24 + 16 }

    override func layout() {
        super.layout()
        meta.frame = NSRect(x: 4, y: 2, width: bounds.width - 8, height: 24)
    }
}

/// `ProposedPlanCard` (ProposedPlanCard.tsx:164-243) in `px-1 py-0.5`: a 24px-radius card with the
/// Plan badge and title, the markdown, and Expand plan for long plans (over 900 characters or 20 lines).
final class PlanRowView: TimelineRowView {
    private let card = FillView()
    private let badge = BadgeView("Plan", variant: .secondary)
    private let title = LabelView("", font: TL.font(14, .medium), color: TL.c(\.foreground))
    private let actionsButton = ButtonView(icon: .ellipsis, variant: .outline, size: .iconXs).menuTrigger()
    private let markdown = MarkdownView(frame: .zero)
    private let fade = CAGradientLayer()
    private let fadeView = DSView()
    private let toggle = ButtonView("Expand plan", variant: .outline, size: .sm)
    private var collapsible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        card.radius = 24
        card.fill = TL.c(\.card, 0.7)
        card.border = TL.c(\.border, 0.8)
        addSubview(card)
        title.lineHeight = 20
        actionsButton.iconSize = 16
        actionsButton.setAccessibilityLabel("Plan actions")
        actionsButton.action = { [weak self] in self?.showActions() }
        for view in [badge, title, actionsButton, markdown, fadeView, toggle] as [NSView] { card.addSubview(view) }
        markdown.bodyColor = TL.c(\.foreground)
        markdown.chatLaneInset = 8 + 42
        fadeView.layer?.addSublayer(fade)
        toggle.action = { [weak self] in
            guard let self, case .proposedPlan(let p)? = self.item?.row.kind else { return }
            self.context.model?.togglePlan(p.id.rawValue)
        }
    }

    /// `proposedPlanTitle` and `stripDisplayedPlanMarkdown` (packages/shared/src/proposedPlanText.ts).
    static func split(_ markdown: String) -> (title: String, body: String) {
        (ProposedPlanText.title(markdown) ?? "Proposed plan", ProposedPlanText.displayed(markdown))
    }

    /// The Plan actions menu (ProposedPlanCard.tsx:181-198): copy, download and save the export text
    /// (`normalizePlanMarkdownForExport`). Save needs the thread's workspace path.
    private func showActions() {
        guard case .proposedPlan(let plan)? = item?.row.kind else { return }
        let markdown = plan.planMarkdown
        let contents = ProposedPlanText.export(markdown)
        let filename = ProposedPlanText.filename(markdown)
        let copy = MenuItem("Copy to clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contents, forType: .string)
        }
        let download = MenuItem("Download as markdown") { [weak self] in self?.download(contents, filename: filename) }
        let model = context.model
        // ponytail: enabled whenever there is a workspace; T3 also needs the session's `filesystem:write` scope (the server refuses without it). Check the scope when sessions carry it to the thread
        var save = MenuItem("Save to workspace") { model?.onSavePlanToWorkspace?(contents, filename) }
        save.isDisabled = model?.onSavePlanToWorkspace == nil || model?.workspaceRoot == nil
        MenuPopupView.show([copy, download, save], from: actionsButton,
                           placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    /// `downloadPlanAsTextFile`: Electron's main window asks where to save a download.
    private func download(_ contents: String, filename: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .proposedPlan(let plan) = item.row.kind else { return }
        let parts = Self.split(plan.planMarkdown)
        title.text = parts.title
        collapsible = plan.planMarkdown.count > 900 || plan.planMarkdown.split(separator: "\n", omittingEmptySubsequences: false).count > 20
        let collapsed = collapsible && !item.ui.planExpanded
        let body = collapsed ? ProposedPlanText.collapsedPreview(plan.planMarkdown) : parts.body
        markdown.inlineSkills = context.model?.inlineSkills ?? []
        markdown.cwd = context.markdownCwd
        markdown.onOpenFile = context.model?.openFile
        markdown.document = context.document(item.id + (collapsed ? ":preview" : ""), body, lineBreaks: false)
        toggle.title = item.ui.planExpanded ? "Collapse plan" : "Expand plan"
        toggle.isHidden = !collapsible
        fadeView.isHidden = !collapsed
        needsLayout = true
    }

    private var collapsed: Bool { collapsible && !(item?.ui.planExpanded ?? false) }

    // MARK: Find (searchablePlanSegments: the title, then the body)

    private let titleFind = FindHighlightView()
    private var titleMatches = 0

    override func applyThreadFind(query: String, occurrence: Int?) {
        let ranges = query.isEmpty ? [] : ThreadFindText.occurrences(title.text, query)
        titleMatches = ranges.count
        if titleFind.superview == nil { card.addSubview(titleFind, positioned: .below, relativeTo: title) }
        let text = title.text as NSString
        func x(_ offset: Int) -> CGFloat {
            TextLine(NSAttributedString(string: text.substring(to: offset), attributes: [.font: title.font])).width
        }
        titleFind.rects = ranges.map { r in (CGRect(x: x(r.location), y: 0, width: x(r.upperBound) - x(r.location), height: 20), false) }
        if let occurrence, occurrence < ranges.count { titleFind.rects[occurrence].active = true }
        markdown.threadFindQuery = query
        markdown.threadFindOccurrence = occurrence.flatMap { $0 >= ranges.count ? $0 - ranges.count : nil }
    }

    /// A match past the collapsed preview opens the plan (T3 reveals what `data-thread-find-fold` hides).
    override func activeFindRect() -> CGRect? {
        if let active = titleFind.rects.first(where: \.active) { return titleFind.convert(active.rect, to: self) }
        guard let occurrence = markdown.threadFindOccurrence else { return nil }
        if collapsed, occurrence >= markdown.findMatchCount() || (markdown.activeFindRect().map { $0.maxY > 416 - 28 } ?? false),
           case .proposedPlan(let p)? = item?.row.kind {
            context.model?.togglePlan(p.id.rawValue)
            return nil
        }
        return markdown.activeFindRect().map { markdown.convert($0, to: self) }
    }

    private func bodyHeight(_ width: CGFloat) -> CGFloat {
        let h = markdown.height(forWidth: max(0, width - 8 - 42))
        return collapsed ? min(h, 416) : h
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        // card: 20 + header 24 + 16 + body (+ 16 + 28 button) + 20, border 1 each side; row py-0.5 and pb-4.
        2 + 1 + 20 + 24 + 16 + bodyHeight(width) + (collapsible ? 16 + 28 : 0) + 20 + 1 + 2 + 16
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 8
        let body = bodyHeight(bounds.width)
        let cardHeight = 1 + 20 + 24 + 16 + body + (collapsible ? 16 + 28 : 0) + 20 + 1
        card.frame = NSRect(x: 4, y: 2, width: width, height: cardHeight)
        let inner = width - 42
        let badgeSize = badge.intrinsicContentSize
        badge.frame = NSRect(x: 21, y: 21 + (24 - badgeSize.height) / 2, width: badgeSize.width, height: badgeSize.height)
        actionsButton.frame = NSRect(x: 21 + inner - 24, y: 21, width: 24, height: 24)
        title.frame = NSRect(x: badge.frame.maxX + 8, y: 23, width: max(0, actionsButton.frame.minX - 12 - badge.frame.maxX - 8), height: 20)
        titleFind.frame = title.frame
        markdown.frame = NSRect(x: 21, y: 61, width: inner, height: markdown.height(forWidth: inner))
        card.layer?.masksToBounds = true
        let bodyBox = NSRect(x: 21, y: 61, width: inner, height: body)
        fadeView.frame = NSRect(x: bodyBox.minX, y: bodyBox.maxY - 96, width: inner, height: 96)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = fadeView.bounds
        fade.colors = resolving { [NSColor.clear, TL.c(\.card, 0.8), TL.c(\.card, 0.95)].map(\.cgColor) }
        fade.locations = [0, 0.5, 1]
        CATransaction.commit()
        // Everything past the clamp is hidden under the card's clip by moving the button over it.
        markdown.layer?.mask = nil
        if collapsed {
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.frame = CGRect(x: 0, y: 0, width: inner, height: body)
            markdown.layer?.mask = mask
        }
        let size = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: 21 + (inner - size.width) / 2, y: bodyBox.maxY + 16, width: size.width, height: 28)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A user message's attachments (MessagesTimeline.tsx:2402-2490): images in a `grid max-w-[210px]
/// grid-cols-2 gap-2` of `aspect-[4/3] rounded-lg border border-border/80 bg-background/70` cells,
/// then files without a chip in the text as `py-1 text-sm` rows with the pierre icon, the name and
/// an eye, each block `mb-2`. Images decode at cell size through the model's loader.
final class UserMessageAttachmentsView: DSView {
    private struct Image { let attachmentId: String; let name: String; let source: JSONValue? }
    private var images: [Image] = []
    private var files: [JSONValue] = []
    private var media: [JSONValue] = []
    private var mediaViews: [ThreadMediaAttachmentView] = []
    private var cells: [AsyncImageView] = []
    private var rows: [ThreadSentFileRowView] = []
    private weak var model: ThreadViewModel?
    static let gridWidth: CGFloat = 210, gap: CGFloat = 8, rowHeight: CGFloat = 28

    func configure(_ m: ChatMessage, model: ThreadViewModel?) {
        self.model = model
        var images: [Image] = [], files: [JSONValue] = [], media: [JSONValue] = []
        // Files with a chip in the text need no row (`chippedAttachmentIds`).
        var chipped = Set<String>()
        if case .array(let records)? = m.context?["records"] {
            let referenced = Set(ComposerContext.referencedIds(m.text))
            for r in records where ["file", "image"].contains(r["kind"]?.stringValue ?? "") && referenced.contains(r["contextId"]?.stringValue ?? "") {
                if let id = r["attachmentId"]?.stringValue { chipped.insert(id) }
            }
        }
        for a in m.attachments {
            let type = a["type"]?.stringValue ?? "", id = a["id"]?.stringValue ?? "", name = a["name"]?.stringValue ?? ""
            let mime = a["mimeType"]?.stringValue ?? ""
            if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { media.append(a) }
            else if type == "image" {
                if !name.hasPrefix("preview-annotation-") { images.append(Image(attachmentId: id, name: name, source: a["source"])) }
            } else if !(type == "file" && chipped.contains(id)) {
                files.append(a)
            }
        }
        guard images.map(\.attachmentId) != self.images.map(\.attachmentId) || files != self.files || media != self.media else { return }
        self.images = images
        self.files = files
        self.media = media
        rebuild()
    }

    private func rebuild() {
        mediaViews.forEach { $0.releasePlayer(); $0.removeFromSuperview() }
        mediaViews = media.map { value in
            let view = ThreadMediaAttachmentView(id: value["id"]?.stringValue ?? "", name: value["name"]?.stringValue ?? "", audio: value["mimeType"]?.stringValue?.hasPrefix("audio/") == true, loader: model?.attachmentMediaURL)
            addSubview(view); return view
        }
        cells.forEach { $0.removeFromSuperview() }
        rows.forEach { $0.removeFromSuperview() }
        let loader = model?.attachmentImage
        cells = images.enumerated().map { i, image in
            let cell = AsyncImageView()
            cell.cacheable = true
            cell.layer?.cornerRadius = 10
            cell.layer?.borderWidth = 1
            cell.fallback.font = DSFont.ui(11)
            let id = image.attachmentId
            cell.set(key: id, fallbackText: image.name, loader: loader.map { load in { side in await load(id, side, true) } })
            if let loader {
                cell.onContextMenu = { event, view in
                    MediaAttachmentContextMenu.show(name: image.name, load: { side in await loader(id, side, false) }, event: event, view: view)
                }
            }
            let click = NSClickGestureRecognizer(target: self, action: #selector(expand(_:)))
            cell.addGestureRecognizer(click)
            cell.setAccessibilityLabel("Preview \(image.name)")
            if let source = image.source, source["kind"]?.stringValue == "snap-shot" {
                cell.addSubview(SnapShotAttachmentDetailsView(source: source))
            }
            addSubview(cell)
            return cell
        }
        rows = files.map { file in
            let row = ThreadSentFileRowView(file: file)
            row.onOpen = { [weak self] download in self?.model?.onOpenAttachment?(file, download) }
            addSubview(row); return row
        }
        needsLayout = true
        needsDisplay = true
    }

    @objc private func expand(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let index = cells.firstIndex(where: { $0 === view }), let loader = model?.attachmentImage else { return }
        let items = images.enumerated().map { i, image in
            ExpandedImagePreviewView.Item(key: image.attachmentId, name: image.name,
                                          source: image.source.flatMap { $0["kind"]?.stringValue == "snap-shot" ? $0 : nil }, cacheable: true,
                                          load: { side in await loader(image.attachmentId, side, false) })
                .withPreview(from: cells[i])
        }
        model?.onExpandImage?(items, index)
    }

    private func imageFrames(width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        return images.map { image in
            let snapshot = image.source?["kind"]?.stringValue == "snap-shot"
            let w = snapshot ? min(208, width) : (width - Self.gap) / 2
            let h = snapshot ? 112 : w * 3 / 4
            if x > 0 && x + w > width { x = 0; y += height + Self.gap; height = 0 }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            x += w + Self.gap; height = max(height, h)
            return rect
        }
    }
    /// The widest block: the 210pt grid, or the longest file row.
    var naturalWidth: CGFloat {
        let fileWidth = rows.map { $0.intrinsicContentSize.width }.max() ?? 0
        return max(images.isEmpty ? 0 : Self.gridWidth, fileWidth, media.isEmpty ? 0 : 320)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if !images.isEmpty {
            h += (imageFrames(width: min(Self.gridWidth, width)).map(\.maxY).max() ?? 0) + 8
        }
        if !files.isEmpty { h += CGFloat(files.count) * Self.rowHeight + CGFloat(files.count - 1) * 4 + 8 }
        h += mediaViews.reduce(0) { $0 + ($1.audio ? 84 : 208) }
        return h
    }

    func setMediaVisible(_ visible: Bool) { mediaViews.forEach { $0.setVisible(visible) } }

    override func updateLayer() {
        for cell in cells {
            cell.layer?.backgroundColor = TL.c(\.background).withAlphaComponent(0.7).cgColor(in: self)
            cell.layer?.borderColor = TL.c(\.border).withAlphaComponent(0.8).cgColor(in: self)
        }
    }

    override func layout() {
        super.layout()
        let frames = imageFrames(width: min(Self.gridWidth, bounds.width))
        for (cell, frame) in zip(cells, frames) {
            cell.frame = frame
            for view in cell.subviews where view is SnapShotAttachmentDetailsView {
                view.frame = NSRect(x: 0, y: frame.height - 60, width: frame.width, height: 60)
            }
        }
        var y: CGFloat = (frames.map(\.maxY).max().map { $0 + 8 }) ?? 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            y += Self.rowHeight + 4
        }
        for view in mediaViews {
            let height: CGFloat = view.audio ? 76 : 200
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 8
        }
    }
}
