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

    /// Default density: `px-1 py-1`, the 24px icon column, `gap-x-1`.
    static let pad: CGFloat = 4, column: CGFloat = 24, headerHeight: CGFloat = 24
    /// `ComposerBanner.Body`: `ps-7 pe-1 pb-1`.
    static let bodyStart: CGFloat = 28, bodyEnd: CGFloat = 4, bodyBottom: CGFloat = 4

    private var threadId: ThreadId = ""
    private var collapsedQuestionId: String?
    private var autoAdvance: DispatchWorkItem?

    private let header = HeaderButton()
    private let headerLabel = glassLabel(font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let collapsedQuestion = glassLabel(font: DSFont.ui(12), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    private let counter = glassLabel(font: SB.tabular(10, .medium), color: Themed.color(\.mutedForeground), lineHeight: 14)
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
    public var markdownCwd: String? { didSet { questionText.cwd = markdownCwd } }
    private var questionSource = ""
    private let multiHint = glassLabel("Select one or more options.", font: DSFont.ui(12), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    private var rows: [OptionRow] = []

    public init() {
        super.init(variant: .neutral)
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
        header.toolTip = collapsed ? "Show the question and its options" : "Hide the question and its options"
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
        let customActive = !progress.customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for (i, option) in question.options.enumerated() {
            rows[i].configure(option, shortcut: i < 9 ? i + 1 : nil,
                              selected: !customActive && progress.selectedOptionValues.contains(option.identity),
                              disabled: isResponding)
        }
        needsLayout = true
        onChange?()
    }

    // MARK: Layout

    private func bodyHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - 2 * Self.pad - Self.bodyStart - Self.bodyEnd)
        var h = questionText.height(forWidth: textWidth)
        if !multiHint.isHidden { h += 4 + 16 }
        h += 8
        for (i, row) in rows.enumerated() { h += (i > 0 ? 2 : 0) + row.height(forWidth: textWidth) }
        return h + Self.bodyBottom
    }

    /// The banner's full height at `width`, the 17px under the composer included.
    public func preferredHeight(width: CGFloat) -> CGFloat {
        let body = isCollapsed || session == nil ? 0 : min(maxBodyHeight, bodyHeight(width: width))
        return Self.pad + Self.headerHeight + body + Self.pad + Self.overlap
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, pad = Self.pad
        header.frame = NSRect(x: pad, y: pad, width: w - 2 * pad, height: Self.headerHeight)
        // Header actions, right to left: dismiss, chevron, counter (`gap-1`).
        var right = w - pad
        if !dismiss.isHidden {
            dismiss.frame = NSRect(x: right - 24, y: pad, width: 24, height: 24)
            right -= 24 + 4
        }
        for chevron in [chevronDown, chevronUp] { chevron.frame = NSRect(x: right - 19, y: pad + 5, width: 14, height: 14) }
        right -= 24
        if !counter.isHidden {
            let cw = ceil(counter.textWidth)
            counter.frame = NSRect(x: right - 4 - cw, y: pad + 5, width: cw, height: 14)
            right -= 4 + cw
        }
        let x = pad + Self.column + 4
        let hw = min(ceil(headerLabel.textWidth), max(0, right - 4 - x))
        headerLabel.frame = NSRect(x: x, y: pad + 4, width: hw, height: 16)
        collapsedQuestion.frame = NSRect(x: x + hw + 4, y: pad + 4, width: max(0, right - 4 - x - hw - 4), height: 16)

        let full = bodyHeight(width: w)
        let visible = min(maxBodyHeight, full)
        scroll.frame = NSRect(x: pad, y: pad + Self.headerHeight, width: w - 2 * pad, height: visible)
        // `pe-2` clears the overlay scrollbar once there is something to scroll.
        let scrollGutter: CGFloat = full > visible ? 8 : 0
        body.frame = NSRect(x: 0, y: 0, width: w - 2 * pad, height: full)
        let tx = Self.bodyStart, tw = max(0, w - 2 * pad - Self.bodyStart - Self.bodyEnd - scrollGutter)
        var y = questionText.height(forWidth: tw)
        questionText.frame = NSRect(x: tx, y: 0, width: tw, height: y)
        if !multiHint.isHidden {
            multiHint.frame = NSRect(x: tx, y: y + 4, width: tw, height: 16)
            y += 20
        }
        y += 8
        for row in rows {
            let h = row.height(forWidth: tw)
            row.frame = NSRect(x: tx, y: y, width: tw, height: h)
            y += h + 2
        }
    }
}

/// The header row: one big button (`ComposerBanner.Row render={<button>}`), no fill of its own.
private final class HeaderButton: ControlView {
    override var wantsUpdateLayer: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One option button: `px-2.5 py-2 rounded-md gap-2`, label 14 medium, an optional 11px
/// description, then the check or the number key in a bare 20px `kbd`.
private final class OptionRow: DSView {
    var onClick: (() -> Void)?
    private(set) var value = ""
    private var selected = false, hovered = false, disabled = false

    private let label = glassLabel(font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground, 0.85), lineHeight: 20)
    private let detail = glassBlock(font: DSFont.ui(11), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    private let key = glassLabel(font: SB.tabular(10, .medium), color: Themed.color(\.mutedForeground), lineHeight: 14)
    private let check = IconView(name: .check, size: 14, strokeColor: Themed.color(\.primary))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 8
        key.alignment = .center
        [label, detail, key, check].forEach(addSubview)
    }

    func configure(_ option: UserInputQuestion.Option, shortcut: Int?, selected: Bool, disabled: Bool) {
        value = option.identity
        label.text = option.label
        detail.text = option.description
        detail.isHidden = option.description == option.label || option.description.isEmpty
        key.text = shortcut.map(String.init) ?? ""
        key.isHidden = selected || shortcut == nil
        check.isHidden = !selected
        alphaValue = disabled ? 0.5 : 1
        setAccessibilityRole(.button)
        setAccessibilityLabel(option.label)
        if selected != self.selected || disabled != self.disabled {
            self.selected = selected
            self.disabled = disabled
            needsDisplay = true
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - 20 - 8 - 20)
        return 8 + 20 + (detail.isHidden ? 0 : 2 + detail.height(forWidth: textWidth)) + 8
    }

    override func updateLayer() {
        // idle transparent, hover `muted/30`, selected `muted/55`; labels `fg/85`, selected `fg`.
        let fill: NSColor? = selected ? Themed.color(\.muted, 0.55) : (hovered && !disabled ? Themed.color(\.muted, 0.3) : nil)
        let cg = fill?.cgColor(in: self)
        if layer?.backgroundColor != cg {
            if window != nil, !Motion.reduced {
                Motion.animate(layer!, keyPath: "backgroundColor", to: cg ?? NSColor.clear.cgColor, duration: Motion.Durations.default)
            }
            layer?.backgroundColor = cg
        }
        label.color = Themed.color(\.foreground, selected ? 1 : 0.85)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let textWidth = max(0, w - 20 - 8 - 20)
        label.frame = NSRect(x: 10, y: 8, width: textWidth, height: 20)
        detail.frame = NSRect(x: 10, y: 30, width: textWidth, height: max(0, h - 38))
        key.frame = NSRect(x: w - 10 - 20, y: (h - 14) / 2, width: 20, height: 14)
        check.frame = NSRect(x: w - 10 - 14, y: (h - 14) / 2, width: 14, height: 14)
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
