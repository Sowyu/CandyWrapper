import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The open question above the composer (chat/ComposerPendingUserInputPanel.tsx): a neutral
/// banner whose header (the question's `header`, the `i/N` counter, a collapse chevron and, for
/// message-mode questions, a dismiss X) toggles a body with the question and its options.
/// Spec: J-composer-visuals 6.3, behavior I-composer-flow 3.4.
///
/// The panel owns the answer drafts (`session`). The composer's editor is the custom-answer
/// field: it shows `customAnswer` with `placeholder`, sends edits to `setCustomAnswer`, and Return
/// calls `advance()`. The footer pill shows `session.primaryLabel` and calls `advance()`;
/// Previous calls `previous()`. `onChange` fires after every state change so the composer can
/// re-read those and the height.
public final class QuestionPanelView: ComposerBannerView {
    /// `runtime-request.respond` with `answers`, ready for `orchestration.dispatchCommand`.
    public var onSubmit: ((JSONValue) -> Void)?
    /// `thread.user-input.dismiss`, message-mode questions only.
    public var onDismiss: ((JSONValue) -> Void)?
    /// Typed custom text an option pick replaced. T3 moves it into the thread's draft:
    /// `UserInputAnswers.carryDisplaced(draftPrompt, text)`.
    public var onDisplacedAnswer: ((String) -> Void)?
    public var onChange: (() -> Void)?

    public private(set) var session: UserInputSession?
    /// A respond call is in flight.
    public var isResponding = false { didSet { if isResponding != oldValue { cancelAutoAdvance(); refresh() } } }
    /// `max-h-[min(24rem,40dvh)]` for the body; the composer sets it from the window height.
    public var maxBodyHeight: CGFloat = 312 { didSet { if maxBodyHeight != oldValue { needsLayout = true } } }

    // MARK: What the composer reads

    /// The editor's text while this question is active.
    public var customAnswer: String { session?.progress.customAnswer ?? "" }
    /// Choice-only questions lock the editor (ChatComposer.tsx:7500-7506).
    public var editorEnabled: Bool { session?.progress.activeQuestion?.allowsCustomAnswer ?? true }
    public var placeholder: String {
        editorEnabled ? "Type your own answer, or leave this blank to use the selected option" : "Choose an option above"
    }

    // MARK: Views

    /// Default density: `px-1 py-1`; the classic question header adds `px-4 pt-1.5`.
    /// Redesign keeps its existing spacing.
    static let pad: CGFloat = 4
    private var isDither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private var headerHeight: CGFloat { isDither ? 24 : 30 }
    /// Nightly 3754 ComposerPendingUserInputPanel.tsx:237-245: `sm:ps-5.5 pe-4 pb-1`.
    private var bodyStart: CGFloat { isDither ? 28 : 22 }
    /// Redesign matches `bodyStart`, so the choices sit as far from the right rim as from the left (the user, 2026-11-27:
    /// 4 left the rows 31pt in on the left and 7pt on the right).
    private var bodyEnd: CGFloat { isDither ? 28 : 16 }
    static let bodyBottom: CGFloat = 4

    private var threadId: ThreadId = ""
    private var collapsedQuestionId: String?
    private var autoAdvance: DispatchWorkItem?

    private let header = HeaderButton()
    private let headerLabel = glassLabel(font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let collapsedQuestion = glassLabel(font: DSFont.ui(12), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    private let counter = glassLabel(font: SB.tabular(12, .medium), color: Themed.color(\.mutedForeground), lineHeight: 16)
    /// `ComposerBanner.ToggleIcon`: a ghost icon-xs button drawn `pointer-events-none`, so only
    /// its chevron (ghost icon color) shows and the header row takes the click.
    private let chevronDown = IconView(name: .chevronDown, size: 14, strokeColor: Themed.color(\.contrastMutedForeground))
    private let chevronUp = IconView(name: .chevronUp, size: 14, strokeColor: Themed.color(\.contrastMutedForeground))
    private let dismiss = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)

    private let body = DSView()
    private lazy var scroll = ScrollAreaView(documentView: body, scrollFade: true)
    /// The question as chat Markdown, links clickable (`ChatMarkdown` with `text-foreground/85`, T3 3105 85272eeea).
    private let questionText: MarkdownView = { let m = MarkdownView(frame: .zero); m.bodyColor = Themed.color(\.foreground, 0.85); return m }()
    /// Resolves file links in the question (`gitCwd`).
    public var markdownCwd: String? { didSet { questionText.cwd = markdownCwd; previews.forEach { $0.cwd = markdownCwd } } }
    private var questionSource = ""
    private let multiHint = glassLabel("Select one or more options.", font: DSFont.ui(12), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    private var rows: [OptionRow] = []
    /// Each option's `preview` under its button, outside it so a click there never picks the option (#34784,
    /// ComposerPendingUserInputPanel.tsx at 4928: `ps-9 pe-2 pb-1.5 text-xs text-foreground/70 sm:ps-8`).
    /// ChatMarkdown with `lineBreaks` at `text-xs text-foreground/70` (ComposerPendingUserInputPanel.tsx:334-340 at 4928).
    private var previews: [MarkdownView] = []
    private var previewSources: [String] = []

    /// Redesign puts the composer footer's Previous and Next in the card, under the choices they act on, and the
    /// composer leaves them out. The same labels, states and actions as the footer (`ComposerView.QuestionFooter`).
    public var actions: ComposerView.QuestionFooter? {
        didSet { if actions != oldValue { refreshActions(); needsLayout = true } }
    }
    let nextPill = MessageActionPill()
    let previousButton = ButtonView("Previous", variant: .outline, size: .sm)
    /// Redesign's header icon, in the approval card's shield's place, so the two prompts read as one kind of card.
    private let questionIcon = IconView(name: .messageCircleQuestion, size: 16, strokeColor: Themed.color(\.mutedForeground))
    private var showsActions: Bool { isDither && actions != nil && session != nil }
    static let actionsGap: CGFloat = RedesignTokens.Space.s

    public init() {
        super.init(variant: .neutral)
        nextPill.compact = false
        nextPill.action = { [weak self] in self?.advance() }
        previousButton.action = { [weak self] in self?.previous() }
        [questionIcon, previousButton, nextPill].forEach { $0.isHidden = true; addSubview($0) }
        header.action = { [weak self] in self?.toggleCollapsed() }
        addSubview(header)
        [headerLabel, collapsedQuestion, counter].forEach(addSubview)
        header.scalesWhenPressed = false
        chevronUp.isHidden = true
        addSubview(chevronDown)
        addSubview(chevronUp)
        dismiss.iconSize = 14
        dismiss.setAccessibilityLabel("Dismiss question without answering")
        TooltipController.attach(to: dismiss, text: "Dismiss question without answering")
        dismiss.action = { [weak self] in self?.dismissPressed() }
        addSubview(dismiss)
        body.addSubview(questionText)
        body.addSubview(multiHint)
        addSubview(scroll)
    }

    /// Shows `input` (`PendingRequests.activeUserInput`). The same request keeps its drafts and
    /// position; a new one starts at its first question, expanded.
    public func configure(_ input: PendingUserInput, threadId: ThreadId) {
        self.threadId = threadId
        if session?.request.requestId != input.requestId || session?.request != input {
            if session?.request.requestId != input.requestId { collapsedQuestionId = nil }
            cancelAutoAdvance()
            session = UserInputSession(input)
        }
        refresh()
    }

    public func clearResolvedSession(pendingRequestIds: Set<String>) {
        guard let session, !pendingRequestIds.contains(session.request.requestId) else { return }
        cancelAutoAdvance()
        self.session = nil
        collapsedQuestionId = nil
    }

    /// Each question's files (count, still uploading or failed), from the composer's question drafts.
    public func setAttachments(_ states: [String: UserInputSession.AttachmentState]) {
        guard session != nil, session!.attachments != states else { return }
        session!.attachments = states
        refresh()
        onChange?()
    }

    /// The editor's text changed.
    public func setCustomAnswer(_ text: String) {
        guard session != nil, editorEnabled else { return }
        session!.setCustomAnswer(text)
        refresh()
    }

    /// Next question, or on the last one submit when every answer resolves (Return in the
    /// editor, the footer pill, and 200ms after a single-select pick).
    public func advance() {
        cancelAutoAdvance()
        guard session != nil, !isResponding else { return }
        switch session!.advance() {
        case .moved: refresh()
        case .submit(let answers):
            onSubmit?(RuntimeRequestCommands.respond(threadId: threadId, requestId: session!.request.requestId, answers: answers))
        case .blocked: break
        }
    }

    public func previous() {
        cancelAutoAdvance()
        session?.previous()
        refresh()
    }

    /// Digits 1 to 9 pick an option (ComposerPendingUserInputPanel.tsx:157-182). Call it for key
    /// presses outside the editor; the panel calls it itself while it has focus.
    @discardableResult
    public func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let question = session?.progress.activeQuestion, keysActive,
              let chars = event.charactersIgnoringModifiers, chars.count == 1, let digit = Int(chars), (1...9).contains(digit),
              digit <= question.options.count
        else { return false }
        select(question.options[digit - 1].identity)
        return true
    }

    private var responseDisabled: Bool { isResponding || !(session?.request.canRespond ?? false) }
    private var isCollapsed: Bool { collapsedQuestionId != nil && collapsedQuestionId == session?.progress.activeQuestion?.id }
    private var keysActive: Bool { !responseDisabled && !isCollapsed }

    /// The whole header row is one button: its labels and chevron pass clicks to it; only the
    /// dismiss X keeps its own.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit !== header, hit !== dismiss, !hit.isDescendant(of: dismiss), !hit.isDescendant(of: scroll),
              header.frame.contains(convert(point, from: superview)) else { return hit }
        return header
    }

    public override var acceptsFirstResponder: Bool { true }
    /// A click on the card's text moves focus out of the editor, like a browser blurring the
    /// contenteditable, so the number keys work next.
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    public override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    // MARK: Actions

    private func select(_ value: String) {
        guard session != nil, !isResponding, let question = session!.progress.activeQuestion else { return }
        // A clicked option takes focus like a button, so digits work next.
        window?.makeFirstResponder(self)
        if let displaced = session!.select(value) { onDisplacedAnswer?(displaced) }
        refresh()
        guard !question.multiSelect else { return }
        cancelAutoAdvance()
        let work = DispatchWorkItem { [weak self] in
            self?.autoAdvance = nil
            self?.advance()
        }
        autoAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func cancelAutoAdvance() {
        autoAdvance?.cancel()
        autoAdvance = nil
    }

    private func toggleCollapsed() {
        guard let id = session?.progress.activeQuestion?.id else { return }
        collapsedQuestionId = isCollapsed ? nil : id
        refresh()
    }

    private func dismissPressed() {
        guard let session, session.request.dismissible, !isResponding else { return }
        onDismiss?(RuntimeRequestCommands.dismiss(threadId: threadId, requestId: session.request.requestId))
    }

    // MARK: State to views

    private func refresh() {
        guard let session, let question = session.progress.activeQuestion else { return }
        let progress = session.progress
        let collapsed = isCollapsed
        headerLabel.text = question.header
        collapsedQuestion.text = question.question
        collapsedQuestion.isHidden = !collapsed
        let count = session.request.questions.count
        counter.text = "\(progress.questionIndex + 1)/\(count)"
        counter.isHidden = count <= 1
        // `rotate-180` when collapsed: the up chevron.
        chevronDown.isHidden = collapsed
        chevronUp.isHidden = !collapsed
        header.setTooltip(collapsed ? "Show the question and its options" : "Hide the question and its options")
        dismiss.isHidden = !session.request.dismissible
        dismiss.isEnabled = !isResponding
        scroll.isHidden = collapsed

        if question.question != questionSource { questionSource = question.question; questionText.document = MarkdownDocument(parsing: question.question) }
        multiHint.isHidden = !question.multiSelect
        while rows.count < question.options.count {
            let row = OptionRow()
            row.onClick = { [weak self, weak row] in
                guard let self, let row else { return }
                self.select(row.value)
            }
            body.addSubview(row)
            rows.append(row)
        }
        while rows.count > question.options.count { rows.removeLast().removeFromSuperview() }
        while previews.count < question.options.count {
            let preview = MarkdownView(frame: .zero)
            preview.body = .xs
            preview.bodyColor = Themed.color(\.foreground, 0.7)
            preview.cwd = markdownCwd
            body.addSubview(preview)
            previews.append(preview)
            previewSources.append("")
        }
        while previews.count > question.options.count { previews.removeLast().removeFromSuperview(); previewSources.removeLast() }
        for (i, option) in question.options.enumerated() {
            let text = option.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text != previewSources[i] { previewSources[i] = text; previews[i].setMarkdown(text, preservesLineBreaks: true) }
            previews[i].isHidden = text.isEmpty
        }
        let customActive = !progress.customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for (i, option) in question.options.enumerated() {
            rows[i].configure(option, shortcut: i < 9 ? i + 1 : nil,
                              selected: !customActive && progress.selectedOptionValues.contains(option.identity),
                              disabled: isResponding, multiSelect: question.multiSelect)
        }
        needsLayout = true
        onChange?()
    }

    private func refreshActions() {
        guard let actions else { return }
        nextPill.title = actions.label
        nextPill.isEnabled = actions.enabled
        previousButton.isEnabled = !actions.responding
    }

    // MARK: Layout

    /// Redesign leaves the same gap under Submit as above it; with only `pad` under it the pill sat 3pt off the composer.
    private var actionsHeight: CGFloat {
        showsActions ? Self.actionsGap + MessageActionPill.height + (isDither ? Self.actionsGap : 0) : 0
    }

    private func bodyHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - 2 * Self.pad - bodyStart - bodyEnd)
        var h = (isDither ? 0 : 8) + questionText.height(forWidth: textWidth)
        if !multiHint.isHidden { h += 4 + 16 }
        h += isDither ? 8 : 6
        for (i, row) in rows.enumerated() {
            h += (isDither && i > 0 ? 2 : 0) + row.height(forWidth: textWidth + (isDither ? 0 : 6))
            if i < previews.count, !previews[i].isHidden { h += previews[i].height(forWidth: previewWidth(textWidth + (isDither ? 0 : 6))) + 6 }
        }
        return h + Self.bodyBottom
    }

    /// The banner's full height at `width`, the 17px under the composer included.
    public func preferredHeight(width: CGFloat) -> CGFloat {
        let body = isCollapsed || session == nil ? 0 : min(maxBodyHeight, bodyHeight(width: width))
        return Self.pad + headerHeight + body + actionsHeight + Self.pad + Self.overlap
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, pad = Self.pad
        header.frame = NSRect(x: pad, y: pad, width: w - 2 * pad, height: headerHeight)
        // Nightly 3754 ComposerPendingUserInputPanel.tsx:187-212: `px-4 pt-1.5`, 24px action slots.
        var right = w - pad - (isDither ? 0 : 16)
        let headerInset: CGFloat = isDither ? 0 : 6
        counter.font = SB.tabular(isDither ? 10 : 12, .medium)
        counter.lineHeight = isDither ? 14 : 16
        if !dismiss.isHidden {
            dismiss.frame = NSRect(x: right - 24, y: pad + headerInset, width: 24, height: 24)
            right -= isDither ? 28 : 24
        }
        for chevron in [chevronDown, chevronUp] { chevron.frame = NSRect(x: right - 19, y: pad + headerInset + 5, width: 14, height: 14) }
        right -= 24
        if !counter.isHidden {
            let cw: CGFloat = isDither ? ceil(counter.textWidth) : 24
            counter.frame = NSRect(x: right - (isDither ? 4 : 0) - cw, y: pad + (isDither ? 5 : 10), width: cw, height: isDither ? 14 : 16)
            counter.alignment = isDither ? .left : .center
            right -= cw + (isDither ? 4 : 0)
        }
        let x = pad + (isDither ? 28 : 16)
        let hw = min(ceil(headerLabel.textWidth), max(0, right - 4 - x))
        headerLabel.frame = NSRect(x: x, y: pad + (isDither ? 4 : 10), width: hw, height: 16)
        collapsedQuestion.frame = NSRect(x: x + hw + 4, y: pad + (isDither ? 4 : 10), width: max(0, right - 4 - x - hw - 4), height: 16)

        questionIcon.isHidden = !isDither
        questionIcon.frame = NSRect(x: pad + 6, y: pad + 4, width: 16, height: 16)
        let full = bodyHeight(width: w)
        let visible = isCollapsed ? 0 : min(maxBodyHeight, full)
        scroll.frame = NSRect(x: pad, y: pad + headerHeight, width: w - 2 * pad, height: visible)
        // Next under the choices, its right edge on the number keys' right edge; Previous before it.
        nextPill.isHidden = !showsActions
        previousButton.isHidden = !showsActions || actions?.showsPrevious != true
        if showsActions {
            let y = pad + headerHeight + visible + Self.actionsGap
            let nw = nextPill.intrinsicContentSize.width
            let right = w - pad - bodyEnd - 10
            nextPill.frame = NSRect(x: right - nw, y: y, width: nw, height: MessageActionPill.height)
            let pw = previousButton.intrinsicContentSize.width
            previousButton.frame = NSRect(x: nextPill.frame.minX - Self.actionsGap - pw, y: y, width: pw, height: MessageActionPill.height)
        }
        // `pe-2` clears the overlay scrollbar once there is something to scroll.
        let scrollGutter: CGFloat = full > visible ? 8 : 0
        body.frame = NSRect(x: 0, y: 0, width: w - 2 * pad, height: full)
        let tx = bodyStart, tw = max(0, w - 2 * pad - bodyStart - bodyEnd - scrollGutter)
        var y = questionText.height(forWidth: tw)
        questionText.frame = NSRect(x: tx, y: isDither ? 0 : 8, width: tw, height: y)
        y += isDither ? 0 : 8
        if !multiHint.isHidden {
            multiHint.frame = NSRect(x: tx, y: y + 4, width: tw, height: 16)
            y += 20
        }
        y += isDither ? 8 : 6
        for (i, row) in rows.enumerated() {
            let outset: CGFloat = isDither ? 0 : 6
            let h = row.height(forWidth: tw + outset)
            row.frame = NSRect(x: tx - outset, y: y, width: tw + outset, height: h)
            y += h
            if i < previews.count, !previews[i].isHidden {
                let pw = previewWidth(tw + outset)
                let ph = previews[i].height(forWidth: pw)
                previews[i].frame = NSRect(x: tx - outset + previewInset, y: y, width: pw, height: ph)
                y += ph + 6
            }
            y += isDither ? 2 : 0
        }
    }

    /// `sm:ps-8 pe-2`; Dither lines the preview up with its wider label inset.
    private var previewInset: CGFloat { isDither ? 36 : 32 }
    private func previewWidth(_ rowWidth: CGFloat) -> CGFloat { max(0, rowWidth - previewInset - 8) }
}

/// The header row: one big button (`ComposerBanner.Row render={<button>}`), no fill of its own.
private final class HeaderButton: ControlView {
    override var wantsUpdateLayer: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One option button: `sm:ps-1.5 py-1.5 rounded-md gap-2.5`, label 14 medium, an optional 11px
/// description, with a radio or checkbox at the left and a number key at the right.
final class OptionRow: DSView {
    var onClick: (() -> Void)?
    private(set) var value = ""
    private var selected = false, hovered = false, disabled = false
    private var isDither: Bool { ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    private var textInset: CGFloat { isDither ? 36 : 32 }
    private var paddingY: CGFloat { isDither ? 8 : 6 }
    private var trailingInset: CGFloat { isDither ? 38 : 34 }

    private let label = glassLabel(font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground, 0.7), lineHeight: 20)
    private let detail = glassBlock(font: DSFont.ui(11), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    let key = KbdView()
    let radio = RadioView()
    let checkbox = CheckboxView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 8
        key.smoothsFont = false
        radio.setAccessibilityElement(false)
        checkbox.setAccessibilityElement(false)
        [label, detail, key, radio, checkbox].forEach(addSubview)
    }

    func configure(_ option: UserInputQuestion.Option, shortcut: Int?, selected: Bool, disabled: Bool, multiSelect: Bool) {
        value = option.identity
        label.text = option.label
        detail.text = option.description
        detail.isHidden = option.description == option.label || option.description.isEmpty
        key.keys = shortcut.map(String.init) ?? ""
        key.isHidden = shortcut == nil
        radio.isHidden = multiSelect
        checkbox.isHidden = !multiSelect
        radio.isChecked = selected
        checkbox.value = selected ? .on : .off
        alphaValue = disabled ? 0.5 : 1
        setAccessibilityRole(.button)
        setAccessibilityLabel(option.label)
        setAccessibilityValue(selected ? 1 : 0)
        if selected != self.selected || disabled != self.disabled {
            self.selected = selected
            self.disabled = disabled
            needsDisplay = true
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - textInset - trailingInset)
        return paddingY + 20 + (detail.isHidden ? 0 : 2 + detail.height(forWidth: textWidth)) + paddingY
    }

    override func updateLayer() {
        layer?.cornerRadius = ComposerDesign.uses3814(dark: effectiveAppearance.isDark) ? 6 : 8
        // Nightly 3754 :253-257: transparent at rest, `muted/30` only on unselected hover.
        let fill: NSColor? = isDither && selected ? Themed.color(\.muted, 0.55)
            : (hovered && (!selected || isDither) && !disabled ? Themed.color(\.muted, 0.3) : nil)
        let cg = fill?.cgColor(in: self)
        if layer?.backgroundColor != cg {
            if window != nil, !Motion.reduced {
                Motion.animate(layer!, keyPath: "backgroundColor", to: cg ?? NSColor.clear.cgColor, duration: Motion.Durations.default)
            }
            layer?.backgroundColor = cg
        }
        label.color = Themed.color(\.foreground, selected ? 1 : (isDither ? 0.85 : 0.7))
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let textWidth = max(0, w - textInset - trailingInset)
        label.frame = NSRect(x: textInset, y: paddingY, width: textWidth, height: 20)
        detail.frame = NSRect(x: textInset, y: paddingY + 22, width: textWidth, height: max(0, h - 2 * paddingY - 22))
        // T3 3814, ComposerPendingUserInputPanel.tsx:260-280: both controls align to the
        // label's first line. Selection never replaces the number key.
        key.frame = NSRect(x: w - (isDither ? 30 : 22), y: paddingY, width: 20, height: 20)
        radio.frame = NSRect(x: isDither ? 10 : 6, y: paddingY + 2, width: 16, height: 16)
        checkbox.frame = radio.frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Indicators are decoration; the row owns selection and single-choice auto-advance.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard !disabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func resetCursorRects() { if !disabled { addCursorRect(bounds, cursor: .pointingHand) } }
}
