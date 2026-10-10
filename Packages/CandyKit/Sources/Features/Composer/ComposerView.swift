import AppKit
import DesignSystem
import T3Protocol

/// The composer box (ChatComposer.tsx, ComposerSurface.tsx): a 22px-radius glass surface with
/// the prompt editor, the footer's left control slots, the attach button and the primary action.
/// Spec: J-composer-visuals sections 2 to 5, behavior I-composer-flow section 7.
///
/// The app sets `runState`, `isBusy`, `placeholderInput` and the handlers; the pickers go into
/// `footerControls`. Height follows the text between 144 and 274 (`preferredHeight`), then the
/// editor scrolls; `onHeightChange` tells the parent to re-layout.
public final class ComposerView: DSView {
    /// `rounded-3xl`: `calc(var(--radius) + 12px)`.
    public static let radius: CGFloat = 22
    /// Body `px-4 pt-4 pb-2`, footer `px-4 pb-4`, the 1px `p-px` of ComposerSurface.Main.
    static let inset: CGFloat = 1, pad: CGFloat = 16, footerHeight: CGFloat = 32
    /// `min-h-19.5` and `max-h-52` less the `p-1 -m-1` pair.
    static let editorMin: CGFloat = 70, editorMax: CGFloat = 200

    // MARK: Inputs

    /// The thread's runs as the primary action reads them.
    /// A draft (new thread) route: `draftThreadRoute` for the send keybindings.
    public var isDraftRoute = false
    public var runState = ComposerLogic.RunState() { didSet { if runState != oldValue { refresh() } } }
    /// A send or resume is in flight: the button shows a spinner and is disabled.
    public var isBusy = false { didSet { if isBusy != oldValue { refresh() } } }
    /// Sending is blocked (disconnected, no provider, no project); the reason is the tooltip.
    public var sendDisabledReason: String? { didSet { if sendDisabledReason != oldValue { refresh() } } }
    public var placeholderInput = ComposerLogic.PlaceholderInput() { didSet { if placeholderInput != oldValue { refresh() } } }
    public var sendShortcut = ComposerLogic.SendShortcut.enter
    /// The composer edits a queued message: the button is the check and a send saves the edit.
    public var editingQueued = false { didSet { if editingQueued != oldValue { refresh() } } }
    /// `followUpBehavior`: false queues follow-ups while a turn runs (T3's default), true steers.
    public var steerByDefault = false { didSet { refresh() } }
    /// Nightly and dev servers draw the stage art in the send button.
    public var stageArt = true { didSet { primary.stageArt = stageArt } }
    /// A context strip hangs under the composer: the outline leaves the seam between the strip's
    /// sides open, its bottom 2px from 22 to width - 22 (`contextSeamClasses`, ComposerSurface.tsx:51-53).
    public var joinsContextStrip = false { didSet { if joinsContextStrip != oldValue { needsLayout = true } } }

    /// A runtime request docked above (ChatComposer.tsx:6980, 7468, 7547-7553).
    public enum PendingState: Equatable, Sendable {
        case none
        /// The editor shrinks to 32 (`min-h-10`), the body gets `pb-4`, and there is no footer: 66 tall empty.
        case approval
        /// The footer gets `pt-2` and shows Stop (while a run can stop), Previous and the pill.
        case question(QuestionFooter)
    }

    /// The question footer (ComposerPrimaryActions.tsx:181-230).
    public struct QuestionFooter: Equatable, Sendable {
        public var label: String
        public var compactLabel: String
        public var enabled: Bool
        public var showsPrevious: Bool
        /// Submitting: Previous and the pill are disabled and the editor is read-only.
        public var responding: Bool
        /// Choice-only questions hide attach (`showComposerAttachAction`).
        public var showsAttach: Bool
        public init(label: String, compactLabel: String, enabled: Bool, showsPrevious: Bool, responding: Bool, showsAttach: Bool) {
            self.label = label; self.compactLabel = compactLabel; self.enabled = enabled
            self.showsPrevious = showsPrevious; self.responding = responding; self.showsAttach = showsAttach
        }
    }

    public var pending = PendingState.none { didSet { if pending != oldValue { refresh(); relayoutHeight(); needsLayout = true } } }

    /// The footer's left cluster (model, traits, access). Separators go between them.
    public var footerControls: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            separators.forEach { $0.removeFromSuperview() }
            separators = footerControls.dropFirst().map { _ in SeparatorView(.vertical) }
            separators.forEach(addSubview)
            footerControls.forEach(addSubview)
            needsLayout = true
        }
    }

    // MARK: Outputs

    /// Return or the button with content: the text (untrimmed) and how to deliver it. While
    /// `editingQueued`, the send saves the edit; the mode doesn't matter.
    public var onSend: ((String, ComposerLogic.SendMode) -> Void)?
    public var onStop: (() -> Void)?
    public var onResume: (() -> Void)?
    /// Every edit, for the per-thread draft.
    public var onTextChange: ((String) -> Void)?
    public var onHeightChange: (() -> Void)?
    /// A question is open: Return or the pill moves to the next question or submits.
    public var onQuestionAdvance: (() -> Void)?
    public var onQuestionPrevious: (() -> Void)?
    /// The attach button (`Attach files`); nil leaves it inert.
    public var onAttach: (() -> Void)?
    /// Files above the editor: a question's answer files, and draft files without a chip.
    public let fileList = ComposerFileListView()
    /// The draft's images above the files (`expandedComposerImages`).
    public let imageShelf = ComposerImageShelfView()
    public var imageTiles: [ComposerImageShelfView.Tile] {
        get { imageShelf.tiles }
        set {
            let before = shelfHeight
            imageShelf.tiles = newValue
            imageShelf.isHidden = newValue.isEmpty
            if shelfHeight != before { needsLayout = true; onHeightChange?() }
        }
    }
    /// Draft attachments: a prompt with only attachments can still send (`hasSendableContent`).
    public var attachmentCount = 0 { didSet { if attachmentCount != oldValue { refresh() } } }
    /// Files dropped on the composer or pasted into it (images always, other files when the paste
    /// has no text). The app classifies and uploads them.
    public var onFiles: (([ComposerIncomingFile]) -> Void)?
    /// Pasted text and whether Cmd+Shift+V kept it inline; true when the app folded it into a file.
    public var onPasteText: ((String, Bool) -> Bool)? {
        get { editor.onPasteText }
        set { editor.onPasteText = newValue }
    }
    /// The selection's length in prompt characters, for the paste limit check.
    public var selectedPromptLength: Int { editor.expanded(editor.selectedRange()).utf16.count }
    /// Where pasted image data is written before it uploads.
    public var pasteDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CandyWrapperPaste", isDirectory: true)
    private let fileDrop = ComposerFileDrop()
    /// `bg-accent/45 ring-1 ring-primary/70` while files hover over the composer.
    private let dropHighlight = CALayer()
    private var laidOutShelfHeight: CGFloat = 0
    private var shelfHeight: CGFloat { imageShelf.preferredHeight(width: max(0, bounds.width - 2 * (Self.inset + Self.pad))) }
    public var fileRows: [ComposerFileRow] {
        get { fileList.rows }
        set {
            let before = fileList.preferredHeight
            fileList.rows = newValue
            fileList.isHidden = newValue.isEmpty
            if fileList.preferredHeight != before { needsLayout = true; onHeightChange?() }
        }
    }
    /// The open thread's timeline messages, read on ArrowUp or ArrowDown for prompt history.
    public var historyMessages: (() -> [PromptHistory.Message])?
    /// The active prompt-history recall (`promptHistoryPositionRef`).
    private var historyPosition: PromptHistory.Position?

    public var text: String {
        get { editor.expandedText }
        set { editor.setText(newValue) }
    }

    /// Composer box height for the current text: 144 to 274, 66 up with an approval, +8 with a question.
    public var preferredHeight: CGFloat {
        switch pending {
        case .approval: Self.inset * 2 + Self.pad + editorHeight + Self.pad
        // Without the 32px send button the footer row is the 28px controls (`h-7`): 148 empty (reference 06).
        case .question: Self.inset * 2 + Self.pad + shelfHeight + fileList.preferredHeight + editorHeight + 8 + 8 + 28 + Self.pad
        case .none: Self.inset * 2 + Self.pad + shelfHeight + fileList.preferredHeight + editorHeight + 8 + Self.footerHeight + Self.pad
        }
    }

    /// `ComposerPrimaryActions` compact labels below a 780 form width when the footer holds wide actions.
    private var compactActions: Bool { bounds.width < ComposerFooterLayout.wideActionsCompactBreakpoint }
    /// `data-chat-composer-footer-compact`: the footer gap drops from 0 (`gap-2 sm:gap-0`) to `gap-1.5`.
    // ponytail: no plan follow-up, so only a question counts as wide actions; add it with plan mode
    private var compactFooter: Bool { ComposerFooterLayout.isCompact(width: bounds.width, hasWideActions: questionFooter != nil) }
    private var questionFooter: QuestionFooter? {
        if case .question(let footer) = pending { return footer }
        return nil
    }

    // MARK: Views

    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    let glass = DSView()
    /// A view, not a layer: `layer.render(in:)` ignores zPosition, and the outline must sit over the glass.
    private let outline = OutlineView()
    let editor = ComposerEditor()
    private let scroll = NSScrollView()
    let placeholder = LabelView()
    private let validation = LabelView()
    let attach = ButtonView(nil, icon: .paperclip, variant: .ghost, size: .iconSm)
    let primary = ComposerPrimaryButton()
    let questionPill = MessageActionPill()
    /// "Previous" (`Button outline sm`), or the chevron (`outline icon-sm`) when compact.
    let previousFull = ButtonView("Previous", variant: .outline, size: .sm)
    let previousCompact = ButtonView(nil, icon: .chevronLeft, variant: .outline, size: .iconSm)
    /// The backdrop blur under the glass fill.
    private let blur = BackdropBlurView()
    private var separators: [SeparatorView] = []
    private var alternateHeld = false
    private var editorHeight = ComposerView.editorMin

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = false
        // `shadow-composer`: 0 12px 28px -18px black/40%, light only, and only outside the box.
        shadowLayer.shadowColor = .black
        shadowLayer.shadowRadius = 14
        // The view is flipped, so its layers are too: +12 is 12px down. (-12 drew the shadow above
        // the box on screen; offscreen snapshots don't render shadows, so only the screen shows it.)
        shadowLayer.shadowOffset = CGSize(width: 0, height: 12)
        shadowLayer.mask = shadowMask
        shadowMask.fillRule = .evenOdd
        layer?.addSublayer(shadowLayer)

        // Glass: `card` / `surface-raised` at 80% over a 12px backdrop blur, saturate 1.14.
        blur.cornerRadius = Self.radius
        addSubview(blur)
        glass.layer?.cornerRadius = Self.radius
        glass.layer?.masksToBounds = true
        addSubview(glass)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false
        scroll.documentView = editor
        addSubview(scroll)
        // `text-placeholder/75`, first line, leading-relaxed.
        placeholder.font = ComposerEditor.font
        placeholder.lineHeight = ComposerEditor.lineHeight
        placeholder.color = Themed.color(\.placeholder, 0.75)
        addSubview(placeholder, positioned: .below, relativeTo: scroll)
        validation.font = DSFont.ui(12)
        validation.lineHeight = 16
        validation.color = Themed.color(\.destructive)
        validation.isHidden = true
        addSubview(validation)

        attach.iconColor = Themed.color(\.mutedForeground)
        attach.action = { [weak self] in self?.onAttach?() }
        fileList.isHidden = true
        addSubview(fileList)
        imageShelf.isHidden = true
        addSubview(imageShelf)
        dropHighlight.cornerRadius = Self.radius
        dropHighlight.borderWidth = 1
        dropHighlight.isHidden = true
        dropHighlight.actions = ["hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        glass.layer?.addSublayer(dropHighlight)
        fileDrop.onHighlight = { [weak self] on in self?.dropHighlight.isHidden = !on }
        fileDrop.onFiles = { [weak self] urls in self?.onFiles?(urls.map { ComposerIncomingFile(url: $0) }) }
        editor.fileDrop = fileDrop
        registerForDraggedTypes([.fileURL, .composerMention])
        editor.onPasteAttachments = { [weak self] pboard in
            guard let self, let onFiles = self.onFiles else { return false }
            let files = ComposerPasteboard.files(pboard, tempDir: self.pasteDirectory)
            let text = pboard.string(forType: .string) ?? ""
            guard ComposerAttachmentRules.shouldHandlePaste(files: files.map { ($0.name, $0.mimeType) }, plainText: text) else { return false }
            onFiles(files)
            return true
        }
        TooltipController.attach(to: attach, text: "Attach files")
        attach.setAccessibilityLabel("Attach files")
        addSubview(attach)
        primary.action = { [weak self] in self?.primaryPressed() }
        addSubview(primary)
        questionPill.action = { [weak self] in self?.onQuestionAdvance?() }
        previousCompact.iconSize = 14
        previousCompact.setAccessibilityLabel("Previous question")
        for button in [previousFull, previousCompact] {
            button.smoothsFont = false
            button.action = { [weak self] in self?.onQuestionPrevious?() }
        }
        [questionPill, previousFull, previousCompact].forEach { $0.isHidden = true; addSubview($0) }

        // The outline sits over everything (Host::after).
        outline.layer?.cornerRadius = Self.radius
        outline.layer?.borderWidth = 1
        addSubview(outline)

        editor.onTextChange = { [weak self] in self?.textChanged() }
        editor.onSelectionChange = { [weak self] in self?.onCaretChange?() }
        editor.chipLook = chipLook
        editor.onSubmitKey = { [weak self] key in self?.submitKey(key) ?? false }
        editor.onHistoryKey = { [weak self] backward in self?.navigateHistory(backward: backward) ?? false }
        editor.onModifierChange = { [weak self] held in
            guard let self, held != alternateHeld else { return }
            alternateHeld = held
            refresh()
        }
        refresh()
    }

    // MARK: Focus

    public func focus() { window?.makeFirstResponder(editor) }
    public var isEditorFocused: Bool { window?.firstResponder === editor }
    /// `isCaretAtStart`: a collapsed selection at offset 0.
    public var isCaretAtStart: Bool { editor.selectedRange() == NSRange(location: 0, length: 0) }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(editor) ?? false }

    /// Clicks on padding focus the editor.
    public override func mouseDown(with event: NSEvent) {
        if editor.isEditable { focus() }
    }

    // MARK: State

    /// The prompt with chips as their source text.
    private var prompt: String { editor.expandedText }
    /// The editor's text with each chip as one U+FFFC: what menu triggers and their ranges read.
    public var displayText: String { editor.string }

    /// `hasSendableContent`: prose besides context links, or a context chip (ChatView.logic.ts:866-890).
    private var hasContent: Bool {
        let text = prompt
        return !ComposerContext.stripReferences(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !ComposerContext.referencedIds(text).isEmpty || attachmentCount > 0
    }

    /// The look of each chip; the default knows mentions and skills, and shows context links as
    /// unavailable. The app passes one that reads its skills and context records.
    public var chipLook: (ComposerInlineToken) -> ComposerChipLook = ComposerChipLook.basic {
        didSet { editor.chipLook = chipLook; editor.refreshChips() }
    }
    /// Rebuilds the chips after their data changed (skills, records, thread titles).
    public func refreshChips() { editor.refreshChips() }
    /// Copy: the records behind context ids and their environment; paste: records from the clipboard.
    public var recordsForCopy: (([String]) -> (records: [JSONValue], environmentId: String)?)? {
        get { editor.recordsForCopy }
        set { editor.recordsForCopy = newValue }
    }
    public var onPasteRecords: (([String: JSONValue]) -> Void)? {
        get { editor.onPasteRecords }
        set { editor.onPasteRecords = newValue }
    }
    /// An edit or a caret move (the menu controller follows the trigger).
    var onCaretChange: (() -> Void)?

    private var sendMode: ComposerLogic.SendMode {
        ComposerLogic.sendMode(running: runState.canInterrupt, alternate: alternateHeld, steerByDefault: steerByDefault)
    }

    /// Editor disabled for approvals, choice-only questions and a missing project (ChatComposer.tsx:7500-7506).
    private var editorDisabled: Bool {
        placeholderInput.approvalPending || placeholderInput.questionChoiceOnly == true || placeholderInput.projectRequired
            || questionFooter?.responding == true
    }

    func refresh() {
        placeholder.text = ComposerLogic.placeholder(placeholderInput)
        editor.isEditable = !editorDisabled
        if let footer = questionFooter {
            questionPill.title = compactActions ? footer.compactLabel : footer.label
            questionPill.compact = compactActions
            questionPill.isEnabled = footer.enabled
            previousFull.isEnabled = !footer.responding
            previousCompact.isEnabled = !footer.responding
        }
        // Project selection required dims the whole surface (`opacity-75`).
        alphaValue = placeholderInput.projectRequired ? 0.75 : 1
        // With a question open the round button is only Stop (`renderStopGenerationButton(true)`).
        let face = questionFooter != nil ? .stop
            : ComposerLogic.primaryAction(run: runState, hasContent: hasContent, busy: isBusy, mode: sendMode, editingQueued: editingQueued)
        primary.face = face
        let validationMessage = ComposerLogic.lengthValidationMessage(prompt)
        switch face {
        case .stop:
            primary.isEnabled = true
            primary.tooltip = "Interrupt"
        case .resume:
            primary.isEnabled = sendDisabledReason == nil
            primary.tooltip = sendDisabledReason ?? "Resume thread"
        case .busy:
            primary.isEnabled = false
            primary.tooltip = "Submitting message"
        case .update:
            primary.isEnabled = hasContent && sendDisabledReason == nil && validationMessage == nil
            primary.tooltip = sendDisabledReason ?? "Update queued message"
        case .send, .queue, .steer:
            primary.isEnabled = hasContent && sendDisabledReason == nil && validationMessage == nil
            if let reason = sendDisabledReason {
                primary.tooltip = reason
            } else if face == .send {
                primary.tooltip = "Submit message"
            } else {
                // ponytail: no shortcut label after "Ctrl/⌘-click"; add it with the keybindings settings
                let action = steerByDefault ? "steer" : "queue", other = steerByDefault ? "queue" : "steer"
                primary.tooltip = "Click to \(action), Ctrl/⌘-click to \(other)"
            }
        }
        if validation.text != (validationMessage ?? "") || validation.isHidden != (validationMessage == nil) {
            validation.text = validationMessage ?? ""
            validation.isHidden = validationMessage == nil
            relayoutHeight()
        }
    }

    /// Inserts prompt text at the caret, with a space before it unless the caret follows whitespace
    /// (`insertComposerText(..., { ensureLeadingBoundary: true })`). Its tokens become chips.
    public func insertAtCaret(_ text: String) {
        let range = editor.selectedRange()
        let ns = editor.string as NSString
        var insert = text
        if range.location > 0, range.location <= ns.length,
           let scalar = Unicode.Scalar(ns.character(at: range.location - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            insert = " " + insert
        }
        editor.insertText(insert, replacementRange: range)
    }

    /// The composer's target changed (thread, draft, queued edit): a recall from the old one is not active here.
    public func resetPromptHistory() { historyPosition = nil }

    /// `navigatePromptHistory` (ChatComposer.tsx:4393-4436).
    private func navigateHistory(backward: Bool) -> Bool {
        if pending != .none { return false }
        if historyPosition == nil, !editor.string.isEmpty { return false }
        guard editor.isCaretOnVisualEdge(start: backward), let messages = historyMessages?() else { return false }
        guard let step = PromptHistory.step(backward ? .backward : .forward, entries: PromptHistory.entries(messages),
                                            position: historyPosition, currentPrompt: prompt) else { return false }
        historyPosition = step.position
        editor.setText(step.prompt)
        editor.scrollRangeToVisible(editor.selectedRange())
        return true
    }

    private func textChanged() {
        // Any edit ends browsing, even one later undone by hand.
        if historyPosition?.recalled != prompt { historyPosition = nil }
        placeholder.isHidden = !editor.string.isEmpty
        refresh()
        relayoutHeight()
        onTextChange?(prompt)
        onCaretChange?()
    }

    private func relayoutHeight() {
        let minimum = pending == .approval ? 32 : Self.editorMin
        let height = min(Self.editorMax, max(minimum, editor.contentHeight))
        needsLayout = true
        guard height != editorHeight else { return }
        editorHeight = height
        onHeightChange?()
    }

    // MARK: Actions

    private func submitKey(_ key: ComposerLogic.Key) -> Bool {
        guard let intent = ComposerLogic.submitIntent(key, prompt: prompt, mode: sendShortcut, turnRunning: runState.canInterrupt,
                                                      isDraft: isDraftRoute, keymap: ActiveKeymap.keymap) else {
            return false
        }
        // An open question: the send key answers it (`submissionTarget: "pending-user-input"`, no length check).
        if questionFooter != nil {
            // T3 moves past an unanswered middle question on Return; only the pill stays disabled.
            onQuestionAdvance?()
            return true
        }
        if pending == .approval { return true }
        // ponytail: `.background` sends in the foreground; starting in the background and opening a fresh composer waits for its own package
        let mode = ComposerLogic.sendMode(running: runState.canInterrupt, alternate: intent == .alternate, steerByDefault: steerByDefault)
        send(mode)
        // A send key never inserts a newline, even when nothing was sent.
        return true
    }

    private func primaryPressed() {
        switch primary.face {
        case .stop: onStop?()
        case .resume: onResume?()
        case .busy: break
        case .update: send(.queue)
        case .send, .queue, .steer:
            let held = NSApp.currentEvent.map { !$0.modifierFlags.intersection([.command, .control]).isEmpty } ?? false
            send(ComposerLogic.sendMode(running: runState.canInterrupt, alternate: held, steerByDefault: steerByDefault))
        }
    }

    private func send(_ mode: ComposerLogic.SendMode) {
        guard !isBusy, sendDisabledReason == nil, !editorDisabled, hasContent,
              ComposerLogic.lengthValidationMessage(prompt) == nil else { return }
        onSend?(prompt, mode)
    }

    // MARK: Drops on the padding

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if Self.mention(in: sender) != nil { return .copy }
        return ComposerFileDrop.hasFiles(sender) && onFiles != nil ? fileDrop.entered(sender) : []
    }
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) { fileDrop.exited() }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let mention = Self.mention(in: sender) { return insertMentionAtEnd(mention) }
        return ComposerFileDrop.hasFiles(sender) && onFiles != nil ? fileDrop.perform(sender) : false
    }

    /// A file tree row's mention (`COMPOSER_MENTION_DRAG_TYPE`, composerMentionDrag.ts).
    static func mention(in sender: any NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: .composerMention).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `insertMentionAtEnd("<mention> ")`: appended with a leading boundary, caret after it.
    @discardableResult
    public func insertMentionAtEnd(_ mention: String) -> Bool {
        guard !editorDisabled else { return false }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        insertAtCaret(mention + " ")
        window?.makeFirstResponder(editor)
        return true
    }

    // MARK: Drawing and layout

    public override func updateLayer() {
        let dark = effectiveAppearance.isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.layer?.backgroundColor = Themed.color(light: \.card, 0.8, dark: \.surfaceRaised, 0.8).cgColor(in: self)
        outline.layer?.borderColor = (dark ? Themed.white(0.05) : Themed.black(0.08)).cgColor
        dropHighlight.backgroundColor = Themed.color(\.accent, 0.45).cgColor(in: self)
        dropHighlight.borderColor = Themed.color(\.primary, 0.7).cgColor(in: self)
        shadowLayer.shadowOpacity = dark ? 0 : 0.4
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadowLayer.frame = box
        // Spread -18: the shadow shape is the box inset by 18.
        shadowLayer.shadowPath = CGPath(roundedRect: box.insetBy(dx: 18, dy: 18), cornerWidth: max(0, Self.radius - 18),
                                   cornerHeight: max(0, Self.radius - 18), transform: nil)
        let maskPath = CGMutablePath()
        maskPath.addRect(box.insetBy(dx: -60, dy: -60))
        maskPath.addRoundedRect(in: box, cornerWidth: Self.radius, cornerHeight: Self.radius)
        shadowMask.frame = box
        shadowMask.path = maskPath
        CATransaction.commit()
        blur.frame = box
        glass.frame = box
        outline.frame = box
        if joinsContextStrip {
            let mask = outline.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
            let path = CGMutablePath()
            path.addRect(box)
            path.addRect(CGRect(x: ComposerContextStripView.inset, y: h - 2, width: max(0, w - 2 * ComposerContextStripView.inset), height: 2))
            mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            mask.fillRule = .evenOdd
            mask.path = path
            mask.frame = box
            outline.layer?.mask = mask
        } else {
            outline.layer?.mask = nil
        }

        // Editor: text box at x 17, the scroller in the 4px `p-1` padding outside it.
        let textWidth = max(0, w - 2 * (Self.inset + Self.pad))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dropHighlight.frame = box
        CATransaction.commit()
        let shelf = shelfHeight
        // The shelf wraps by width: a new width can change the box height the parent planned with.
        if shelf != laidOutShelfHeight { laidOutShelfHeight = shelf; DispatchQueue.main.async { [weak self] in self?.onHeightChange?() } }
        imageShelf.frame = NSRect(x: Self.inset + Self.pad, y: Self.inset + Self.pad, width: textWidth,
                                  height: max(0, shelf - ComposerImageShelfView.marginBottom))
        fileList.frame = NSRect(x: Self.inset + Self.pad, y: Self.inset + Self.pad + shelf, width: textWidth,
                                height: max(0, fileList.preferredHeight - ComposerFileListView.marginBottom))
        let textTop = Self.inset + Self.pad + shelf + fileList.preferredHeight
        scroll.frame = NSRect(x: Self.inset + Self.pad - 4, y: textTop - 4, width: textWidth + 8, height: editorHeight + 8)
        editor.textContainerInset = NSSize(width: 4, height: 4 + editor.lineTop)
        editor.minSize = NSSize(width: textWidth + 8, height: editorHeight + 8)
        editor.frame.size.width = textWidth + 8
        placeholder.frame = NSRect(x: Self.inset + Self.pad, y: textTop, width: textWidth, height: ComposerEditor.lineHeight)
        placeholder.isHidden = !editor.string.isEmpty

        // ponytail: the length message overlaps the footer's top edge; T3 grows the box for it (ComposerPromptLengthValidation)
        validation.frame = NSRect(x: Self.inset + Self.pad, y: textTop + editorHeight - 16, width: textWidth, height: 16)

        // Footer row: 32 tall, 16 from the bottom.
        let rowHeight: CGFloat = questionFooter == nil ? Self.footerHeight : 28
        let rowY = h - Self.inset - Self.pad - rowHeight
        let midY = rowY + rowHeight / 2
        let right = w - Self.inset - Self.pad
        // No footer with an approval open.
        let footerShown = pending != .approval
        footerControls.forEach { $0.isHidden = !footerShown }
        separators.forEach { $0.isHidden = !footerShown }
        var actionsLeft: CGFloat
        if let footer = questionFooter {
            // Right to left: the pill, Previous, Stop (28, only while a run can stop); `gap-1.5` compact, else `gap-2`.
            let gap: CGFloat = compactActions ? 6 : 8
            questionPill.compact = compactActions
            questionPill.title = compactActions ? footer.compactLabel : footer.label
            let pillWidth = questionPill.intrinsicContentSize.width
            questionPill.frame = NSRect(x: right - pillWidth, y: midY - 14, width: pillWidth, height: 28)
            questionPill.isHidden = false
            actionsLeft = questionPill.frame.minX
            let previous = compactActions ? previousCompact : previousFull
            previousFull.isHidden = true
            previousCompact.isHidden = true
            if footer.showsPrevious {
                let pw = previous.intrinsicContentSize.width
                previous.frame = NSRect(x: actionsLeft - gap - pw, y: midY - 14, width: pw, height: 28)
                previous.isHidden = false
                actionsLeft = previous.frame.minX
            }
            primary.isHidden = !runState.canInterrupt
            if runState.canInterrupt {
                primary.frame = NSRect(x: actionsLeft - gap - 28, y: midY - 14, width: 28, height: 28)
                actionsLeft = primary.frame.minX
            }
            attach.isHidden = !footer.showsAttach
        } else {
            [questionPill, previousFull, previousCompact].forEach { $0.isHidden = true }
            primary.isHidden = !footerShown
            attach.isHidden = !footerShown
            primary.frame = NSRect(x: right - 32, y: rowY, width: 32, height: 32)
            actionsLeft = primary.frame.minX
        }
        attach.frame = NSRect(x: actionsLeft - 8 - 28, y: midY - 14, width: 28, height: 28)
        // Left cluster: the first control's own 10px padding puts its icon at x 17 (`-ms-2.5`); gap 4,
        // separators 1x16 with 2px margins.
        var x = Self.inset + Self.pad - 10
        // The left cluster is `flex-1` up to the right cluster, less the footer gap.
        let limit = (attach.isHidden ? actionsLeft : attach.frame.minX) - (compactFooter ? 6 : 0)
        for (i, control) in footerControls.enumerated() {
            if i > 0 {
                let sep = separators[i - 1]
                x += 4 + 2
                sep.frame = NSRect(x: x, y: midY - 8, width: 1, height: 16)
                x += 1 + 2 + 4
            }
            let size = control.intrinsicContentSize
            // The last control (the picker cluster) takes the rest and fits itself into it.
            let width = i == footerControls.count - 1 ? max(0, limit - x) : max(0, min(size.width, limit - x))
            control.frame = NSRect(x: x, y: midY - size.height / 2, width: width, height: size.height)
            x += width
        }
    }
}

/// The composer's 1px outline (Host::after): drawn over the content, never takes clicks.
private final class OutlineView: DSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
