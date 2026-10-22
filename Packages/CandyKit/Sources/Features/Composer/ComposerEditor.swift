import AppKit
import DesignSystem
import T3Protocol

/// The prompt editor (`ComposerPromptEditorTiptap`): plain text in a TextKit 2 view, 14px system
/// font on a 22.75px line (`leading-relaxed`), foreground caret, no focus ring. Return goes
/// through `ComposerLogic.submitIntent`; anything that isn't a send edits as usual.
///
/// Inline tokens (file mentions, `$skills`, context links) show as chips: each is one attachment
/// character carrying its source text, so it deletes and selects as a unit. `string` is the
/// display text (chips as U+FFFC); `expandedText` is the prompt T3 would hold. A token becomes a
/// chip once whitespace follows it, as in T3 (composerInlineTokens.ts).
final class ComposerEditor: NSTextView, NSTextViewDelegate, FontRuntimeConsumer {
    var richTextEnabled = false {
        didSet {
            guard richTextEnabled != oldValue else { return }
            setText(expandedText)
        }
    }
    private var lastEditKind = ""
    private var lastEditAt = -Double.infinity
    /// Chromium's caret; AppKit's indicator stays hidden (`didAddSubview`).
    private let caretView = ComposerCaretView()
    private var isFocused = false
    private var keyObservers: [NSObjectProtocol] = []
    /// Chromium's selection bands, under the text.
    private let selectionView = ComposerSelectionView()
    private var codeHighlightTask: Task<Void, Never>?
    var clipboardEdit = false
    var applyingListEdit = false

    static var font: NSFont { FontRuntime.font(.prompt, size: 14) }
    static var lineHeight: CGFloat { FontRuntime.promptSize * 1.625 }

    func applyFontRuntime() {
        applyStyle()
        styleRichText(registerUndo: false)
        needsDisplay = true
        onTextChange?()
    }

    /// Asked on Return; true when it handled the key as a send.
    var onSubmitKey: ((ComposerLogic.Key) -> Bool)?
    var onOpenChip: ((String) -> Bool)?
    var onInteract: (() -> Void)?
    var onTextChange: (() -> Void)?
    /// Plain ArrowUp (true) or ArrowDown (false); true when it handled the key (prompt history).
    var onHistoryKey: ((Bool) -> Bool)?
    /// The Cmd/Ctrl modifier went down or up (the queue and steer icons swap while it is held).
    var onModifierChange: ((Bool) -> Void)?
    /// Asked first for ArrowUp, ArrowDown, Return, Tab and Escape; true when the menu took the key.
    var onMenuKey: ((MenuKey) -> Bool)?
    /// The caret or selection moved (the menu trigger follows it).
    var onSelectionChange: (() -> Void)?
    /// The look for a token's chip; nil keeps tokens as plain text.
    var chipLook: ((ComposerInlineToken) -> ComposerChipLook)?
    /// Copy: the records behind the copied context ids, and the environment they come from.
    var recordsForCopy: (([String]) -> (records: [JSONValue], environmentId: String)?)?
    /// Paste: records from the clipboard fragment for the pasted links.
    var onPasteRecords: (([String: JSONValue]) -> Void)?

    /// Double-clicking a citation chip opens its comment editor (AssistantCitationCommentEditor). Checks the
    /// character at the insertion point and the one before it, since a click on a chip's right half lands after it.
    private func editCitation(near insertion: Int) -> Bool {
        guard let window, let storage = textStorage else { return false }
        let candidates = [insertion, insertion - 1].filter { $0 >= 0 && $0 < storage.length }
        guard let index = candidates.first(where: { storage.attribute(.attachment, at: $0, effectiveRange: nil) is ComposerChipAttachment }),
              let chip = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerChipAttachment,
              let token = ComposerInlineTokens.collect(chip.source).first, case .citation(let citation) = token.kind else { return false }
        let source = chip.source
        let sourceOffset = expanded(NSRange(location: 0, length: index)).utf16.count
        ThreadAssistantCitationEditor.present(citation, in: window) { [weak self] edited in
            guard let self else { return }
            let full = NSMutableString(string: self.expandedText)
            let range = NSRange(location: sourceOffset, length: source.utf16.count)
            guard NSMaxRange(range) <= full.length, full.substring(with: range) == source else { return }
            full.replaceCharacters(in: range, with: edited.markdown)
            self.setText(full as String)
        }
        return true
    }

    enum MenuKey { case up, down, select, tab, escape }

    init() {
        let tlm = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        tlm.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(tlm)
        super.init(frame: .zero, textContainer: container)
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        focusRingType = .none
        delegate = self
        tlm.delegate = self
        applyStyle()
        addSubview(selectionView, positioned: .below, relativeTo: nil)
        addSubview(caretView)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Top inset of the first line box, so the text's first baseline sits where Blink puts it.
    private(set) var lineTop: CGFloat = 0

    func applyStyle() {
        let metrics = textKitLineMetrics(font: Self.font, lineHeight: Self.lineHeight)
        lineTop = metrics.top
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = metrics.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: Themed.color(\.foreground), .paragraphStyle: paragraph,
        ]
        bodyParagraph = paragraph
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        // AppKit resets its indicator's display mode as the caret moves; a clear color keeps it out of sight under ComposerCaretView.
        insertionPointColor = .clear
        // `drawBackground` paints the selection over whole CSS line boxes; TextKit's own band covers only the glyphs.
        selectedTextAttributes = [.backgroundColor: NSColor.clear]
        updateCaret(restart: false)
    }

    /// The editor has no `::selection` rule (ComposerPromptEditorTiptap.tsx:999), so Chromium paints the
    /// system selection color at 80% over the composer (#355272 on #101010 in dark mode) and keeps the text color.
    static var selectionColor: NSColor { NSColor.selectedTextBackgroundColor.withAlphaComponent(0.8) }

    /// Replaces the text with the editor's style (programmatic sets skip the typing attributes).
    /// `text` is the expanded prompt; its tokens come back as chips. One editor serves every thread, so a draft set in
    /// code starts a fresh undo history: the old one holds offsets into the text it replaces, and Cmd+Z would replay
    /// another draft's typing onto this one.
    func setText(_ text: String) {
        breakUndoCoalescing()
        undoManager?.removeAllActions()
        isChipifying = true
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
        applyStyle()
        styleRichText(registerUndo: false)
        chipify(registerUndo: false)
        isChipifying = false
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        highlightCodeBlocks()
        onTextChange?()
    }

    /// The prompt with every chip as its source text.
    var expandedText: String { expanded(NSRange(location: 0, length: textStorage?.length ?? 0)) }

    func expanded(_ range: NSRange) -> String {
        guard let storage = textStorage, range.length > 0 else { return "" }
        return ComposerRichTextStyler.serialize(storage.attributedSubstring(from: range))
    }

    /// The caret as a UTF-16 offset into `expandedText` (T3's `expandedCursor`). It maps through the whole
    /// document, because a prefix serializes its last block as if it ended the draft (a rule drops its newline).
    var expandedCaret: Int {
        get { markdownOffset(selectedRange().location) }
        set { setCaret(markdown: newValue) }
    }

    /// Highlight whole code bodies off the main actor. Only the current document may receive tokens.
    private func highlightCodeBlocks() {
        codeHighlightTask?.cancel()
        guard richTextEnabled, let storage = textStorage else { return }
        var blocks: [(range: NSRange, text: String, language: String)] = []
        var start: Int?, language = ""
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let block = value as? ComposerBlockAttachment else { return }
            switch block.kind {
            case .codeHeader(_, let info):
                start = min(storage.length, NSMaxRange(range) + 1)
                let raw = ComposerCodeLanguages.language(info).lowercased()
                language = ComposerCodeLanguages.aliases[raw] ?? raw
            case .codeEnd:
                if let a = start, range.location > a {
                    let r = NSRange(location: a, length: range.location - a)
                    blocks.append((r, storage.attributedSubstring(from: r).string, language))
                }
                start = nil
            default: break
            }
        }
        if let start, start < storage.length {
            let range = NSRange(location: start, length: storage.length - start)
            blocks.append((range, storage.attributedSubstring(from: range).string, language))
        }
        guard !blocks.isEmpty else { return }
        let snapshot = expandedText
        let requests = blocks
        codeHighlightTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                var result: [CodeToken] = []
                for block in requests {
                    guard !Task.isCancelled else { return [CodeToken]() }
                    result += CodeHighlighter.tokens(block.text, language: block.language).map { token in
                        CodeToken(range: NSRange(location: block.range.location + token.range.location, length: token.range.length), kind: token.kind)
                    }
                }
                return result
            }
            let tokens = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, self.expandedText == snapshot, let storage = self.textStorage else { return }
            storage.beginEditing()
            for token in tokens where NSMaxRange(token.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            }
            storage.endEditing()
        }
    }

    private var isChipifying = false
    /// Counts outside edits, so an input rule can be undone only by the very next key.
    private(set) var editStamp = 0
    /// Text the keyboard typed (`insertText`), the only edits T3's input rules look at.
    private var typedInsert = false
    /// Display range a paste inserted whose lines are read as Markdown blocks.
    var parseRange: NSRange?
    /// The input rule the last keystroke applied, for Backspace to undo (`undoInputRule`).
    var inputRuleUndo: (range: NSRange, literal: NSAttributedString, caret: Int, stamp: Int)?
    /// The last render's block layout: first-line shift, bottom margin, last line box.
    private var blockInfo = ComposerRichTextStyler.Info()

    override func insertText(_ string: Any, replacementRange: NSRange) {
        typedInsert = !clipboardEdit
        defer { typedInsert = false }
        let range = replacementRange.location == NSNotFound ? (hasMarkedText() ? markedRange() : selectedRange()) : replacementRange
        let opensPair = richTextEnabled && !hasMarkedText() && range.length == 0 && ((string as? String) ?? (string as? NSAttributedString)?.string) == "`"
            && codePair(at: range.location - 1) == nil && typedPairCanOpen(before: range.location)
        // Text typed inside a typed pair joins it; anywhere else it stays out.
        if let id = codePair(at: range.location - 1), codePair(at: NSMaxRange(range)) == id { typingAttributes[.composerCodePair] = id }
        else { typingAttributes[.composerCodePair] = nil }
        super.insertText(string, replacementRange: replacementRange)
        if opensPair, let storage = textStorage {
            let caret = selectedRange().location
            guard caret >= 2, (storage.string as NSString).substring(with: NSRange(location: caret - 2, length: 2)) == "``" else { return }
            nextCodePair += 1
            storage.addAttribute(.composerCodePair, value: nextCodePair, range: NSRange(location: caret - 2, length: 2))
        }
    }

    // MARK: Typed code pairs (`codePairCaretPlugin`, composer-rich-text-doc.ts:50-113, 7259e4f594)

    private var nextCodePair = 0
    /// Between a text change's start and its `textDidChange`: caret moves then are the edit's, not the user's.
    private var textChanging = false

    private func codePair(at index: Int) -> Int? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return storage.attribute(.composerCodePair, at: index, effectiveRange: nil) as? Int
    }

    /// A second backtick right after a lone first one, in plain text outside code, records a pair.
    private func typedPairCanOpen(before caret: Int) -> Bool {
        guard let storage = textStorage, caret >= 1, caret <= storage.length else { return false }
        let start = lineStart(caret)
        let before = (storage.string as NSString).substring(with: NSRange(location: start, length: caret - start))
        guard before.range(of: "(^|[^`])`$", options: .regularExpression) != nil else { return false }
        let tick = caret - 1
        return storage.attribute(.composerCodeBlock, at: tick, effectiveRange: nil) == nil
            && ComposerRichTextStyler.marks(storage.attribute(.composerMarks, at: tick, effectiveRange: nil)).isEmpty
    }

    /// The caret moved, with no edit, to just after a typed pair's closing backtick: a filled, plain pair becomes
    /// inline code and the caret types plain text after it. Doubled backticks on either side keep it literal.
    private func formatCodePair(endingAt caret: Int) -> Bool {
        guard let storage = textStorage, !textChanging, !isChipifying, undoManager?.isUndoing != true, undoManager?.isRedoing != true,
              let id = codePair(at: caret - 1), codePair(at: caret) != id else { return false }
        var pair = NSRange()
        _ = storage.attribute(.composerCodePair, at: caret - 1, longestEffectiveRange: &pair, in: NSRange(location: 0, length: storage.length))
        let text = storage.string as NSString
        guard NSMaxRange(pair) == caret, pair.length >= 3, pair.location == 0 || text.character(at: pair.location - 1) != 96,
              caret == text.length || text.character(at: caret) != 96,
              text.substring(with: pair).range(of: "^`[^`\n]+`$", options: .regularExpression) != nil,
              !storage.containsAttachments(in: pair), ComposerRichTextStyler.plain(storage, pair),
              storage.attribute(.composerCodeBlock, at: pair.location, effectiveRange: nil) == nil else { return false }
        let inner = NSRange(location: pair.location + 1, length: pair.length - 2)
        let code = NSAttributedString(string: text.substring(with: inner), attributes: ComposerRichTextStyler.attributes([.code], base: baseAttributes))
        replaceAttributed(pair, with: code, caret: pair.location + inner.length)
        typingAttributes = caretAttributes([])
        return true
    }

    func textDidChange(_ notification: Notification) {
        textChanging = false
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true { lastEditKind = "other" }
        if !isChipifying { editStamp += 1 }
        if !isChipifying, !hasMarkedText(), undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            styleRichText(registerUndo: true)
            chipify(registerUndo: true)
        } else if !isChipifying, richTextEnabled {
            // Undo and IME composition skip the styler; the layout still follows the text.
            refreshBlockInfo()
        }
        highlightCodeBlocks()
        onTextChange?()
        updateCaret(restart: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) { onSelectionChange?() }

    /// Turns finished tokens in the plain text into chips, keeping the caret where it was.
    private func styleRichText(registerUndo: Bool) {
        guard richTextEnabled, let storage = textStorage else { return }
        let typing = registerUndo && !applyingListEdit
        let selection = selectedRange()
        let ruleCaret = typing && typedInsert && selection.length == 0 ? selection.location : nil
        let (rendered, info) = ComposerRichTextStyler.renderInfo(storage, base: baseAttributes, width: bounds.width, typing: typing,
                                                                 caret: ruleCaret, parse: parseRange)
        applyBlockInfo(info)
        guard !storage.isEqual(to: rendered) else { return }
        let prefix = storage.attributedSubstring(from: NSRange(location: 0, length: min(selection.location, storage.length)))
        let caret = ComposerRichTextStyler.render(prefix, base: baseAttributes, typing: typing, caret: ruleCaret.map { _ in prefix.length },
                                                  parse: parseRange.map { NSIntersectionRange($0, NSRange(location: 0, length: prefix.length)) }).length
        let was = isChipifying
        isChipifying = true
        defer { isChipifying = was }
        let range = NSRange(location: 0, length: storage.length)
        if registerUndo, !shouldChangeText(in: range, replacementString: rendered.string) { return }
        storage.setAttributedString(rendered)
        if registerUndo { didChangeText() }
        setSelectedRange(NSRange(location: min(caret, storage.length), length: min(selection.length, max(0, storage.length - caret))))
        if let rule = info.rule { inputRuleUndo = (rule.range, rule.literal, selectedRange().location, editStamp) }
        typingAttributes = caretAttributes([])
    }

    /// Reads the block layout of the text as it stands, without restyling it (after undo).
    private func refreshBlockInfo() {
        guard richTextEnabled, let storage = textStorage else { return }
        applyBlockInfo(ComposerRichTextStyler.renderInfo(storage, base: baseAttributes, width: bounds.width, typing: true).info)
    }

    private func applyBlockInfo(_ info: ComposerRichTextStyler.Info) {
        let shift = blockInfo.topShift
        blockInfo = info
        blockInfo.rule = nil
        if shift != info.topShift { invalidateTextContainerOrigin() }
    }

    /// TextKit sizes the view to its own line heights; blocks add margins and taller line boxes,
    /// so the view grows to the CSS height and a scrolled composer reaches its last line.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if richTextEnabled, blockInfo.structured, isVerticallyResizable {
            size.height = max(size.height, contentHeight + 2 * (textContainerInset.height - lineTop))
        }
        let width = frame.width
        super.setFrameSize(size)
        if size.width != width { updateCaret(restart: false) }
    }

    /// The first line moves down by its block's top margin and line box (`ComposerBlockLayout`).
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y + (richTextEnabled ? blockInfo.topShift : 0))
    }

    /// Typing attributes for the caret's line: its paragraph style, and a heading's font and color.
    private func caretAttributes(_ marks: [ComposerRichText.Mark]) -> [NSAttributedString.Key: Any] {
        var base = baseAttributes
        if richTextEnabled, let storage = textStorage, storage.length > 0 {
            let caret = min(selectedRange().location, storage.length)
            let start = lineStart(caret)
            if start < storage.length, (storage.string as NSString).character(at: start) != 10 {
                let attrs = storage.attributes(at: start, effectiveRange: nil)
                base[.paragraphStyle] = attrs[.paragraphStyle] ?? base[.paragraphStyle]
                base[.composerQuote] = attrs[.composerQuote]
                if let b = attrs[.attachment] as? ComposerBlockAttachment, case .heading = b.kind {
                    base[.font] = attrs[.font] ?? base[.font]
                    base[.foregroundColor] = attrs[.foregroundColor] ?? base[.foregroundColor]
                }
            }
        }
        return ComposerRichTextStyler.attributes(marks, base: base)
    }

    private func chipify(registerUndo: Bool) {
        guard let storage = textStorage, let chipLook else { return }
        let display = string as NSString
        // A token that already holds a chip character is left alone.
        let tokens = ComposerInlineTokens.collect(string).filter { !display.substring(with: $0.range).contains("\u{FFFC}") && storage.attribute(.composerCodeBlock, at: $0.range.location, effectiveRange: nil) == nil && !ComposerRichTextStyler.marks(storage.attribute(.composerMarks, at: $0.range.location, effectiveRange: nil)).contains(.code) }
        guard !tokens.isEmpty else { return }
        let wasChipifying = isChipifying
        isChipifying = true
        defer { isChipifying = wasChipifying }
        var selection = selectedRange()
        for token in tokens.reversed() {
            let chip = NSMutableAttributedString(attributedString: makeChip(token, look: chipLook(token)))
            if let marks = storage.attribute(.composerMarks, at: token.range.location, effectiveRange: nil) {
                chip.addAttribute(.composerMarks, value: marks, range: NSRange(location: 0, length: chip.length))
            }
            if registerUndo, !shouldChangeText(in: token.range, replacementString: "\u{FFFC}") { continue }
            storage.replaceCharacters(in: token.range, with: chip)
            if registerUndo { didChangeText() }
            let shift = token.range.length - 1
            if selection.location >= NSMaxRange(token.range) { selection.location -= shift }
            else if selection.location > token.range.location { selection = NSRange(location: token.range.location + 1, length: 0) }
        }
        setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        typingAttributes = baseAttributes
    }

    private func makeChip(_ token: ComposerInlineToken, look: ComposerChipLook) -> NSAttributedString {
        // A skill chip writes `$name` whatever currency sigil was typed (`readAtomSource`).
        var source = token.source
        if case .skill(let name) = token.kind { source = "$" + name }
        let attachment = ComposerChipAttachment(look: look, source: source, maxWidth: max(40, bounds.width - 8))
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttributes(baseAttributes, range: NSRange(location: 0, length: out.length))
        out.addAttribute(.composerChipSource, value: source, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Rebuilds every chip (an appearance change, or new skill and record data for their labels).
    func refreshChips() {
        guard !hasMarkedText(), let storage = textStorage, storage.containsAttachments else { return }
        let caret = expanded(NSRange(location: 0, length: min(selectedRange().location, storage.length)))
        isChipifying = true
        textStorage?.setAttributedString(NSAttributedString(string: expandedText, attributes: baseAttributes))
        applyStyle()
        styleRichText(registerUndo: false)
        chipify(registerUndo: false)
        isChipifying = false
        // The caret goes back to the same place in the expanded text.
        let target = (caret as NSString).length
        var display = 0, consumed = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, sub, stop in
            let chip = value as? ComposerChipAttachment
            let units = chip.map { ($0.source as NSString).length } ?? sub.length
            if consumed + units > target {
                if chip == nil { display += target - consumed }
                stop.pointee = true
                return
            }
            consumed += units
            display += sub.length
        }
        setSelectedRange(NSRange(location: display, length: 0))
    }

    /// Replaces display `range` with expanded text (a menu pick); its tokens become chips.
    func replace(_ range: NSRange, with text: String) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: baseAttributes))
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        didChangeText()
    }

    /// The plain line's paragraph style; typing attributes carry the caret line's own.
    private var bodyParagraph: NSParagraphStyle = .default

    private var baseAttributes: [NSAttributedString.Key: Any] {
        var attributes = typingAttributes
        attributes[.paragraphStyle] = bodyParagraph
        attributes[.composerQuote] = nil
        attributes[.attachment] = nil
        attributes[.composerChipSource] = nil
        attributes[.composerMarks] = nil
        attributes[.composerCodeBlock] = nil
        attributes[.composerCodePair] = nil
        attributes[.backgroundColor] = nil
        attributes[.strikethroughStyle] = nil
        attributes[.font] = Self.font
        attributes[.foregroundColor] = Themed.color(\.foreground)
        return attributes
    }

    // MARK: Blocks and caret stops (composer-rich-text-doc.ts, composer-code-block.ts)

    func lineStart(_ location: Int) -> Int {
        let text = string as NSString
        let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: min(location, text.length)))
        return newline.location == NSNotFound ? 0 : newline.location + 1
    }

    func lineEnd(_ location: Int) -> Int {
        let text = string as NSString
        let newline = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
        return newline.location == NSNotFound ? text.length : newline.location
    }

    func block(at location: Int) -> ComposerBlockAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? ComposerBlockAttachment
    }

    private func blockAttachment(_ source: String, _ kind: ComposerBlockAttachment.Kind) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(attachment: ComposerBlockAttachment(source: source, kind: kind, width: bounds.width))
        out.addAttributes(baseAttributes, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// One undoable edit that inserts atoms as they are; `replace` takes text the renderer reads.
    func replaceAttributed(_ range: NSRange, with text: NSAttributedString, caret: Int) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
    }

    /// `convertCodeFenceOnEnter`: Return at the end of a top-level line that is only an opening
    /// fence opens a closed, empty block with the caret inside.
    private func convertCodeFenceOnEnter() -> Bool {
        let selection = selectedRange()
        let start = lineStart(selection.location)
        guard selection.length == 0, selection.location == lineEnd(selection.location), selection.location > start,
              block(at: start) == nil,
              let open = ComposerBlockAttachment.openingFence(expanded(NSRange(location: start, length: selection.location - start)))
        else { return false }
        breakUndoCoalescing()
        replace(NSRange(location: selection.location, length: 0), with: "\n\n" + open.fence)
        // The fence line is now one atom: the empty code line follows it.
        setSelectedRange(NSRange(location: start + 2, length: 0))
        breakUndoCoalescing()
        return true
    }

    /// Return inside a fence: after a typed closing fence it ends the block there
    /// (`exitCodeBlockOnClosingFence`); on the second blank line at the end of the code it leaves
    /// the block (`exitCodeBlockOnTrailingBlankLines`).
    private func exitCodeBlock(fence: String) -> Bool {
        let selection = selectedRange(), text = string as NSString
        let caret = selection.location, start = lineStart(caret)
        guard selection.length == 0, caret == lineEnd(caret), block(at: start) == nil else { return false }
        let line = text.substring(with: NSRange(location: start, length: caret - start))
        func blank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }
        if ComposerBlockAttachment.isClosingFence(line, fence) {
            // The block's old closing fence goes; the lines between stay, as paragraphs.
            var next = caret
            var oldClose: Int?
            while next < text.length {
                if let b = block(at: next + 1) {
                    if case .codeEnd = b.kind { oldClose = next + 1 }
                    if case .codeEnd = b.kind { break }
                    if case .codeHeader = b.kind { break }
                }
                next = lineEnd(next + 1)
            }
            breakUndoCoalescing()
            if let oldClose { replaceAttributed(NSRange(location: oldClose - 1, length: 2), with: NSAttributedString(), caret: caret) }
            let close = blockAttachment(line, .codeEnd(fence))
            close.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            replaceAttributed(NSRange(location: start, length: caret - start), with: close, caret: start + 2)
            breakUndoCoalescing()
            return true
        }
        let closed: Bool
        if caret == text.length { closed = false }
        else if let b = block(at: caret + 1), case .codeEnd = b.kind { closed = true }
        else { return false }
        guard blank(line), start >= 1 else { return false }
        let previous = lineStart(start - 1)
        guard previous >= 1, block(at: previous) == nil,
              blank(text.substring(with: NSRange(location: previous, length: start - 1 - previous))) else { return false }
        // The code must keep a line before the two blank ones: the header line does not count.
        if let b = block(at: lineStart(previous - 1)), case .codeHeader = b.kind { return false }
        breakUndoCoalescing()
        let end = previous - 1
        replaceAttributed(NSRange(location: end, length: caret - end), with: NSAttributedString(), caret: end)
        let after = NSMutableAttributedString()
        if !closed {
            // An unclosed fence would read the prose after it as code: leaving writes the close.
            after.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            after.append(blockAttachment(fence, .codeEnd(fence)))
        }
        after.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        replaceAttributed(NSRange(location: closed ? end + 2 : end, length: 0), with: after, caret: end + 3)
        breakUndoCoalescing()
        return true
    }

    /// `unwrapCodeBlockAtStart`: Backspace at the start of the code keeps its lines as paragraphs
    /// and drops both fences.
    private func unwrapCodeBlockAtStart() -> Bool {
        guard richTextEnabled, selectedRange().length == 0 else { return false }
        let caret = selectedRange().location
        guard caret >= 2, caret == lineStart(caret) else { return false }
        let header = lineStart(caret - 1)
        guard let b = block(at: header), case .codeHeader = b.kind else { return false }
        let text = string as NSString
        var next = lineEnd(caret)
        while next < text.length {
            if let b = block(at: next + 1) {
                if case .codeEnd = b.kind {
                    breakUndoCoalescing()
                    replaceAttributed(NSRange(location: next, length: 2), with: NSAttributedString(), caret: caret)
                    break
                }
                if case .codeHeader = b.kind { break }
            }
            next = lineEnd(next + 1)
        }
        replaceAttributed(NSRange(location: header, length: caret - header), with: NSAttributedString(), caret: header)
        breakUndoCoalescing()
        return true
    }

    /// The marks on each side of a collapsed caret, when they differ (`styledEdge`). A line's
    /// edges and block markers carry none.
    private func styledEdge() -> (before: Set<ComposerRichText.Mark>, after: Set<ComposerRichText.Mark>, current: Set<ComposerRichText.Mark>)? {
        guard richTextEnabled, let storage = textStorage, selectedRange().length == 0 else { return nil }
        let caret = selectedRange().location, text = storage.string as NSString
        func marks(_ i: Int) -> Set<ComposerRichText.Mark> {
            guard i >= 0, i < text.length, text.character(at: i) != 10, block(at: i) == nil else { return [] }
            return Set(ComposerRichTextStyler.marks(storage.attribute(.composerMarks, at: i, effectiveRange: nil)))
        }
        let before = marks(caret - 1), after = marks(caret)
        guard before != after else { return nil }
        return (before, after, Set(ComposerRichTextStyler.marks(typingAttributes[.composerMarks])))
    }

    /// True when the caret sits on a styled edge and types with the marks before it.
    var caretTakesMarksBefore: Bool {
        guard let edge = styledEdge() else { return false }
        return edge.current == edge.before
    }

    /// Moves the caret to the other stop of the styled edge it sits on, toward `direction`
    /// (-1 left, 1 right). False when there is no stop to take, so the arrow moves as usual.
    func stepCaretAcrossStyledEdge(_ direction: Int) -> Bool {
        guard let edge = styledEdge(), edge.current == edge.before || edge.current == edge.after else { return false }
        let target = direction < 0 ? edge.before : edge.after
        guard edge.current != target else { return false }
        typingAttributes = ComposerRichTextStyler.attributes(ComposerRichText.Mark.allCases.filter(target.contains), base: baseAttributes)
        return true
    }

    /// ProseMirror's caret marks (`ResolvedPos.marks`): the text before the caret, or at the
    /// start of a line the text after it. A rule holds no caret: one landing after it moves on.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        let old = selectedRange().location
        if richTextEnabled, ranges.count == 1, ranges[0].rangeValue.length == 0, let storage = textStorage {
            let caret = ranges[0].rangeValue.location
            if caret > 0, caret < storage.length, let b = block(at: caret - 1), case .rule = b.kind,
               (storage.string as NSString).character(at: caret) == 10 {
                ranges = [NSValue(range: NSRange(location: caret < old ? caret - 1 : caret + 1, length: 0))]
            } else if let b = block(at: caret), b.isLineMarker, caret == lineStart(caret) {
                // A marker owns no caret position: the line's first stop is its text
                // (`runOwnsOffset`). Moving left from there goes to the line before.
                ranges = [NSValue(range: NSRange(location: caret < old && old == caret + 1 && caret > 0 ? caret - 1 : caret + 1, length: 0))]
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        defer { selectionMoved() }
        guard richTextEnabled, !stillSelecting, !hasMarkedText(), ranges.count == 1, ranges[0].rangeValue.length == 0,
              let storage = textStorage else { return }
        let caret = ranges[0].rangeValue.location, text = storage.string as NSString
        if caret != old, formatCodePair(endingAt: caret) { return }
        let atLineStart = caret == 0 || text.character(at: caret - 1) == 10 || block(at: caret - 1) != nil
        let source = atLineStart ? caret : caret - 1
        // An empty line or item types plain text in the line's own style.
        guard source < text.length, text.character(at: source) != 10, block(at: source) == nil else { typingAttributes = caretAttributes([]); return }
        guard storage.attribute(.composerCodeBlock, at: source, effectiveRange: nil) == nil else { return }
        let marks = ComposerRichTextStyler.marks(storage.attribute(.composerMarks, at: source, effectiveRange: nil))
        typingAttributes = caretAttributes(marks)
    }

    /// The Markdown copy writes (`serializeSelection`): across lines, the first line keeps its
    /// list, quote or heading marker.
    func clipboardText(_ range: NSRange) -> String {
        let start = lineStart(range.location)
        guard richTextEnabled, start < range.location, (string as NSString).substring(with: range).contains("\n"),
              let b = block(at: start) else { return expanded(range) }
        switch b.kind {
        case .codeHeader, .codeEnd, .rule: return expanded(range)
        default: return expanded(NSRange(location: start, length: NSMaxRange(range) - start))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if richTextEnabled { setText(expandedText) } else { refreshChips() }
    }

    // MARK: Clipboard

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string, .html] }

    /// Copy writes the expanded text, and an HTML flavor carrying the context records behind any
    /// copied links (T3's `data-t3-context-fragment`), so a paste in another draft keeps them.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let text = clipboardText(selectedRange())
        guard !text.isEmpty else { return false }
        pboard.declareTypes([.string, .html], owner: nil)
        pboard.setString(text, forType: .string)
        let ids = ComposerContext.referencedIds(text)
        if !ids.isEmpty, let copy = recordsForCopy?(ids),
           let html = ComposerContext.clipboardHTML(text: text, records: copy.records, environmentId: copy.environmentId) {
            pboard.setString(html, forType: .html)
        }
        return true
    }

    /// Pasted rich text arrives as plain text with our style; its tokens become chips, and a T3
    /// fragment in the HTML flavor brings the records behind its links.
    override func paste(_ sender: Any?) {
        let pboard = NSPasteboard.general
        let bypass = pasteAsTextPending
        pasteAsTextPending = false
        // Images, and files without text, become attachments (`shouldHandleComposerAttachmentPaste`).
        if onPasteAttachments?(pboard) == true { return }
        // Large text becomes a text file unless Cmd+Shift+V asked for it inline (`foldPastedText`).
        if let text = pboard.string(forType: .string), onPasteText?(text, bypass) == true { return }
        guard let text = pboard.string(forType: .string) else { return super.pasteAsPlainText(sender) }
        if let html = pboard.string(forType: .html) {
            let records = ComposerContext.pastedRecords(html: html, pastedText: text)
            if !records.isEmpty { onPasteRecords?(records) }
        }
        // T3 reads only the plain text flavor (handlePaste): a page's HTML arrives as the text the
        // browser wrote beside it, and Markdown in it becomes blocks and marks.
        breakUndoCoalescing()
        clipboardEdit = true
        if pasteBlocks(text) { scrollRangeToVisible(selectedRange()) } else { insertText(text, replacementRange: selectedRange()) }
        clipboardEdit = false
        breakUndoCoalescing()
    }

    // MARK: File drops

    /// A paste the composer takes as attachments; true when it did.
    var onPasteAttachments: ((NSPasteboard) -> Bool)?
    /// Pasted text and whether Cmd+Shift+V asked to keep it inline; true when the composer took it.
    var onPasteText: ((String, Bool) -> Bool)?
    /// Cmd+Shift+V (`isPasteAsTextShortcut`): the next paste stays text.
    private var pasteAsTextPending = false
    private var enclosingComposer: ComposerView? {
        var v = superview
        while let view = v { if let c = view as? ComposerView { return c }; v = view.superview }
        return nil
    }
    /// Files dragged over the editor go to the composer, never into the text as paths.
    var fileDrop: ComposerFileDrop?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if PullRequestDrag.read(sender.draggingPasteboard) != nil { return .copy }
        if ComposerView.mention(in: sender) != nil { return .copy }
        if let fileDrop, ComposerFileDrop.hasFiles(sender) { return fileDrop.entered(sender) }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if PullRequestDrag.read(sender.draggingPasteboard) != nil { return .copy }
        if ComposerView.mention(in: sender) != nil { return .copy }
        if let fileDrop, ComposerFileDrop.hasFiles(sender) { return fileDrop.entered(sender) }
        return super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fileDrop?.exited()
        super.draggingExited(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let pr = PullRequestDrag.read(sender.draggingPasteboard) { return enclosingComposer?.onPullRequestDropped?(pr) ?? false }
        if let mention = ComposerView.mention(in: sender), let composer = enclosingComposer {
            return composer.insertMentionAtEnd(mention)
        }
        if let fileDrop, ComposerFileDrop.hasFiles(sender) { return fileDrop.perform(sender) }
        return super.performDragOperation(sender)
    }

    /// A plain-text view disables Paste when the pasteboard holds only an image or files; the
    /// composer takes those as attachments.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)), onPasteAttachments != nil, isEditable {
            let pboard = NSPasteboard.general
            if pboard.availableType(from: [.png, .tiff, .fileURL]) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Cmd+Shift+V (`isPasteAsTextShortcut`, the Edit menu's Paste as Text): a large paste stays text.
    override func pasteAsPlainText(_ sender: Any?) {
        pasteAsTextPending = true
        paste(sender)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !isChipifying {
            let kind = clipboardEdit ? "other" : hasMarkedText() ? "insert" : affectedCharRange.length == 0 ? "insert" : replacementString?.isEmpty == true ? "delete" : "other"
            let now = ProcessInfo.processInfo.systemUptime
            if kind != lastEditKind || kind == "other" || now - lastEditAt > 1 { breakUndoCoalescing() }
            lastEditKind = kind; lastEditAt = now
        }
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed { textChanging = true }
        return allowed
    }

    private func listEdit(indent: Bool) -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        guard let storage = textStorage else { return false }
        let mapping = ComposerRichTextStyler.mapping(storage)
        let cursor = mapping.offsets[min(selection.location, mapping.offsets.count - 1)]
        guard let edit = ComposerListContinuation.edit(mapping.value, selection: NSRange(location: cursor, length: 0), indent: indent) else { return false }
        func storageRange(_ range: NSRange) -> NSRange {
            let start = mapping.offsets.lastIndex(where: { $0 <= range.location }) ?? 0
            let end = mapping.offsets.lastIndex(where: { $0 <= NSMaxRange(range) }) ?? start
            return NSRange(location: start, length: max(0, end - start))
        }
        breakUndoCoalescing()
        applyingListEdit = true
        undoManager?.beginUndoGrouping()
        // The renumbered items sit after the caret: change them last to first so earlier offsets hold.
        for r in edit.renumber.reversed() { replace(storageRange(r.range), with: r.number) }
        replace(storageRange(edit.range), with: edit.replacement)
        undoManager?.endUndoGrouping()
        applyingListEdit = false
        if indent { setCaret(markdown: cursor + 2) }
        breakUndoCoalescing()
        return true
    }

    var codeFenceAtCaret: String? {
        guard richTextEnabled, let storage = textStorage else { return nil }
        var fence: String?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: min(selectedRange().location, storage.length))) { value, _, _ in
            guard let block = value as? ComposerBlockAttachment else { return }
            switch block.kind {
            case .codeHeader(let delimiter, _): fence = delimiter
            case .codeEnd: fence = nil
            default: break
            }
        }
        return fence
    }

    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), blockBackspace() { scrollRangeToVisible(selectedRange()); return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if !hasMarkedText(), blockDeleteForward() { scrollRangeToVisible(selectedRange()); return }
        super.deleteForward(sender)
    }

    override func keyDown(with event: NSEvent) {
        onInteract?()
        if let onMenuKey, !hasMarkedText() {
            let flags = event.modifierFlags.intersection([.shift, .option, .command, .control])
            let key: MenuKey? = switch event.keyCode {
            case 126 where flags.isEmpty: .up
            case 125 where flags.isEmpty: .down
            case 36 where flags.isEmpty, 76 where flags.isEmpty: .select
            case 48 where flags.isEmpty: .tab
            case 53: .escape
            default: nil
            }
            if let key, onMenuKey(key) { return }
        }
        if event.keyCode == 48, codeFenceAtCaret != nil, !hasMarkedText(),
           event.modifierFlags.intersection([.option, .command, .control]).isEmpty {
            if event.modifierFlags.contains(.shift) {
                let text = string as NSString, caret = selectedRange().location
                let line = text.lineRange(for: NSRange(location: caret, length: 0))
                let prefix = text.substring(with: NSRange(location: line.location, length: caret - line.location))
                let count = prefix.hasPrefix("  ") ? 2 : prefix.hasPrefix(" ") || prefix.hasPrefix("\t") ? 1 : 0
                if count > 0 { replace(NSRange(location: line.location, length: count), with: "") }
            } else { insertText("  ", replacementRange: selectedRange()) }
            return
        }
        if event.keyCode == 48, event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
           !hasMarkedText(), blockIndent() || listEdit(indent: true) { return }
        let returnKeys: Set<UInt16> = [36, 76]
        if returnKeys.contains(event.keyCode) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = ComposerLogic.Key(isReturn: true, shift: flags.contains(.shift), option: flags.contains(.option),
                                        mod: flags.contains(.command), control: flags.contains(.control),
                                        isRepeat: event.isARepeat, composing: hasMarkedText())
            let linePrefix = (expanded(NSRange(location: 0, length: selectedRange().location))).components(separatedBy: "\n").last ?? ""
            if richTextEnabled, !key.mod, !key.control, !key.composing, let storage = textStorage {
                let prior = selectedRange().location > 0 ? storage.attribute(.attachment, at: selectedRange().location - 1, effectiveRange: nil) as? ComposerBlockAttachment : nil
                var justClosed = false
                if let prior, case .codeEnd = prior.kind { justClosed = true }
                if let fence = codeFenceAtCaret, exitCodeBlock(fence: fence) { return }
                if codeFenceAtCaret == nil, !justClosed, convertCodeFenceOnEnter() { return }
                if codeFenceAtCaret != nil || justClosed {
                    let indent = justClosed ? "" : String(linePrefix.prefix { $0 == " " || $0 == "\t" })
                    insertText("\n" + indent, replacementRange: selectedRange()); return
                }
            }
            if onSubmitKey?(key) == true { return }
            // A list item splits or leaves its list, a quote or heading continues (Shift+Enter in T3).
            if !key.composing, blockReturn() { scrollRangeToVisible(selectedRange()); return }
            if !key.composing, listEdit(indent: false) { return }
        }
        let plainKey = event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty && !hasMarkedText()
        // ArrowLeft 123, ArrowRight 124: a styled edge is two caret stops (`stepCaretAcrossStyledEdge`).
        if plainKey, event.keyCode == 123 || event.keyCode == 124, stepCaretAcrossStyledEdge(event.keyCode == 123 ? -1 : 1) { return }
        // Backspace 51 at the start of a fence's code removes the fence (`unwrapCodeBlockAtStart`).
        if plainKey, event.keyCode == 51, unwrapCodeBlockAtStart() { return }
        // ArrowUp 126, ArrowDown 125, without modifiers or an IME composition (ChatComposer.tsx:4393-4400).
        if event.keyCode == 126 || event.keyCode == 125,
           event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty, !hasMarkedText(),
           onHistoryKey?(event.keyCode == 126) == true {
            return
        }
        super.keyDown(with: event)
    }

    // Cmd+Return never reaches keyDown when a menu item could claim it; route it here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.type == .keyDown, [36, 76].contains(event.keyCode),
           !event.modifierFlags.intersection([.command, .control]).isEmpty {
            keyDown(with: event)
            return true
        }
        if handleFormattingKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    func handleFormattingKey(_ event: NSEvent) -> Bool {
        if window?.firstResponder === self, richTextEnabled, event.type == .keyDown {
            let flags = event.modifierFlags.intersection([.shift, .option, .command, .control])
            let mark: ComposerRichText.Mark? = switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
            case ("b", .command): .bold
            case ("i", .command): .italic
            case ("e", .command): .code
            case ("s", [.command, .shift]): .strike
            default: nil
            }
            if let mark { toggleMark(mark); return true }
        }
        return false
    }

    func toggleMark(_ mark: ComposerRichText.Mark) {
        let range = selectedRange()
        guard let storage = textStorage else { return }
        if range.length == 0 {
            var marks = ComposerRichTextStyler.marks(typingAttributes[.composerMarks])
            if marks.contains(mark) { marks.removeAll { $0 == mark } } else { marks.append(mark) }
            typingAttributes = ComposerRichTextStyler.attributes(marks, base: baseAttributes)
            return
        }
        let old = storage.attributedSubstring(from: range)
        let updated = NSMutableAttributedString(attributedString: old)
        var remove = true
        old.enumerateAttribute(.composerMarks, in: NSRange(location: 0, length: old.length)) { value, _, _ in
            if !ComposerRichTextStyler.marks(value).contains(mark) { remove = false }
        }
        old.enumerateAttributes(in: NSRange(location: 0, length: old.length)) { attrs, sub, _ in
            guard attrs[.composerCodeBlock] == nil else { return }
            var marks = ComposerRichTextStyler.marks(attrs[.composerMarks]).filter { $0 != mark }
            if !remove { marks.append(mark) }
            // Unmarked text has no mark keys at all, so the old ones go first.
            for key in [NSAttributedString.Key.composerMarks, .strikethroughStyle, .backgroundColor] { updated.removeAttribute(key, range: sub) }
            updated.addAttributes(ComposerRichTextStyler.attributes(marks, base: baseAttributes), range: sub)
        }
        breakUndoCoalescing()
        isChipifying = true
        if shouldChangeText(in: range, replacementString: updated.string) {
            storage.replaceCharacters(in: range, with: updated)
            didChangeText()
        }
        isChipifying = false
        setSelectedRange(range)
        breakUndoCoalescing()
    }

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if event.clickCount == 2, editCitation(near: index) { return }
        if let storage = textStorage, index < storage.length {
            if let chip = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerChipAttachment,
               onOpenChip?(chip.source) == true { return }
            if let block = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerBlockAttachment,
               case .codeHeader(let fence, let info) = block.kind {
                guard let host = popupHost else { return }
                let picker = ComposerCodeLanguagePickerView(info: info)
                let popup = host.open(PickerPopupView(picker), trigger: self, placement: .dropdown, swallowsOutsideClick: true)
                picker.onPick = { [weak self, weak host, weak popup] language in
                    if let popup { host?.close(popup) }
                    guard let self, index < (self.textStorage?.length ?? 0),
                          self.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerBlockAttachment === block else { return }
                    self.replace(NSRange(location: index, length: 1), with: fence + ComposerCodeLanguages.replacing(info, with: language))
                }
                window?.makeFirstResponder(picker.search)
                return
            }
        }
        if let storage = textStorage, index < storage.length,
           let block = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerBlockAttachment,
           case .task(let checked) = block.kind {
            replace(NSRange(location: index, length: 1), with: block.source.replacingOccurrences(of: checked ? "[x]" : "[ ]", with: checked ? "[ ]" : "[x]"))
            return
        }
        super.mouseDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        onModifierChange?(!event.modifierFlags.intersection([.command, .control]).isEmpty)
    }

    override func resignFirstResponder() -> Bool {
        onModifierChange?(false)
        guard super.resignFirstResponder() else { return false }
        isFocused = false
        focusChanged()
        return true
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isFocused = true
        focusChanged()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers = []
        if let window {
            keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.focusChanged() }
                }
            }
        }
        updateCaret(restart: true)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? NSTextInsertionIndicator)?.displayMode = .hidden
    }

    // MARK: Caret and selection band

    private func focusChanged() { updateCaret(restart: true) }
    override var isEditable: Bool { didSet { if isEditable != oldValue { updateCaret(restart: true) } } }
    private func selectionMoved() { updateCaret(restart: true) }

    /// Shows Chromium's caret while the editor has focus in the key window and nothing is selected,
    /// and the selection bands while it has focus.
    private func updateCaret(restart: Bool) {
        // AppKit turns its indicator back on as focus and selection change.
        for case let indicator as NSTextInsertionIndicator in subviews where indicator.displayMode != .hidden { indicator.displayMode = .hidden }
        let bands = window == nil ? [] : selectionBands()
        if !bands.isEmpty, selectionView.frame != bounds { selectionView.frame = bounds }
        selectionView.bands = bands
        guard isFocused, isEditable, window?.isKeyWindow == true, let rect = caretRect() else { caretView.hide(); return }
        caretView.show(rect, color: Themed.color(\.foreground).cgColor(in: self), restart: restart)
    }

    /// Chromium's caret box: 1px at the caret's x, from the font's ascent above the baseline to its
    /// descent below, both rounded to device pixels.
    func caretRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText(), let tlm = textLayoutManager, let content = tlm.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: selection.location) else { return nil }
        let font = typingAttributes[.font] as? NSFont ?? Self.font
        let options: NSTextLayoutManager.SegmentOptions = selectionAffinity == .upstream ? [.rangeNotRequired, .upstreamAffinity] : [.rangeNotRequired]
        var found: (frame: CGRect, baseline: CGFloat)?
        tlm.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: options) { _, frame, baseline, _ in
            found = (frame, baseline)
            return false
        }
        let origin = textContainerOrigin
        let scale = window?.backingScaleFactor ?? 2
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        // An empty draft has no line: TextKit would put the first baseline one ascent down.
        let x = found.map { $0.frame.minX } ?? 0
        let baseline = found.map { $0.frame.minY + $0.baseline } ?? font.ascender
        let ascent = px(font.ascender), descent = px(-font.descender)
        return NSRect(x: px(origin.x + x), y: px(origin.y + baseline) - ascent, width: 1, height: ascent + descent)
    }

    /// `isCaretOnVisualEdge` (ComposerPromptEditorTiptap.tsx:1673-1705): an empty editor, or a
    /// collapsed caret on the first visual line (start) or the last (end), no newline between.
    func isCaretOnVisualEdge(start: Bool) -> Bool {
        let text = string as NSString
        if text.length == 0 { return true }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let caret = sel.location
        let newline = start ? text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
                            : text.range(of: "\n", range: NSRange(location: caret, length: text.length - caret))
        if newline.location != NSNotFound { return false }
        guard let tlm = textLayoutManager, let storage = tlm.textContentManager,
              let location = storage.location(storage.documentRange.location, offsetBy: caret) else { return false }
        tlm.ensureLayout(for: storage.documentRange)
        // The caret's paragraph starts after the last newline before it (0 for the start edge).
        let paragraphStart = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret)).location
        let offset = caret - (paragraphStart == NSNotFound ? 0 : paragraphStart + 1)
        guard let fragment = tlm.textLayoutFragment(for: location) ?? (caret == text.length
                ? tlm.textLayoutFragment(for: storage.location(location, offsetBy: -1) ?? location) : nil) else { return true }
        let lines = fragment.textLineFragments
        guard lines.count > 1 else { return true }
        // A caret on a soft wrap shows at the start of the next line.
        return start ? offset < NSMaxRange(lines[0].characterRange) : offset >= lines[lines.count - 1].characterRange.location
    }

    // MARK: Block decorations

    /// The CSS line box of a text line, in the content's coordinates (the editor's inset padding
    /// left out): TextKit's line top less how much lower CSS draws the glyphs.
    private func cssLineTop(_ fragment: NSTextLayoutFragment, _ line: NSTextLineFragment, top: CGFloat) -> CGFloat {
        lineTop + blockInfo.topShift + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY - top
    }

    private func lastLine(_ tlm: NSTextLayoutManager) -> (fragment: NSTextLayoutFragment, line: NSTextLineFragment)? {
        var last: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { last = $0; return true }
        guard let last, let line = last.textLineFragments.last else { return nil }
        return (last, line)
    }

    private func layoutLine(at index: Int, last: Bool) -> (fragment: NSTextLayoutFragment, line: NSTextLineFragment)? {
        guard let tlm = textLayoutManager, let content = tlm.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: index),
              let fragment = tlm.textLayoutFragment(for: location),
              let line = last ? fragment.textLineFragments.last : fragment.textLineFragments.first else { return nil }
        return (fragment, line)
    }

    /// Ordered markers in tabular figures (`ol > li::marker`).
    private static var markerFont: NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if richTextEnabled, blockInfo.decorated { drawBlockDecorations(in: rect) }
    }

    /// Chromium paints a selected line's whole line box (22.75px for body text), where TextKit covers
    /// only the glyphs (17px). TextKit gives each selected line's horizontal extent; the band takes the
    /// line's CSS box, snapped to device pixels as Blink snaps it.
    func selectionBands() -> [NSRect] {
        let selection = selectedRange()
        guard isFocused, selection.length > 0, let tlm = textLayoutManager, let content = tlm.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: selection.location),
              let end = content.location(start, offsetBy: selection.length),
              let range = NSTextRange(location: start, end: end) else { return [] }
        let origin = textContainerOrigin, scale = window?.backingScaleFactor ?? 2
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        var bands: [NSRect] = []
        tlm.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            var band = frame.offsetBy(dx: origin.x, dy: origin.y)
            if let top = cssBandTop(tlm, frame), top.box.height + 0.5 >= frame.height {
                band.origin.y = px(origin.y + top.y)
                band.size.height = px(origin.y + top.y + top.box.height) - band.origin.y
            }
            bands.append(band)
            return true
        }
        return bands
    }

    /// The CSS line box of the line holding a selection segment, in container coordinates: a heading's
    /// own box, else the body's. A line taller than its box (a code block's header) keeps TextKit's.
    private func cssBandTop(_ tlm: NSTextLayoutManager, _ segment: CGRect) -> (y: CGFloat, box: ComposerRichTextStyler.LineBox)? {
        guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: segment.midX, y: segment.midY)),
              let content = tlm.textContentManager else { return nil }
        let frame = fragment.layoutFragmentFrame
        guard let line = fragment.textLineFragments.first(where: {
            segment.midY >= frame.minY + $0.typographicBounds.minY && segment.midY < frame.minY + $0.typographicBounds.maxY
        }) ?? fragment.textLineFragments.last else { return nil }
        var box = ComposerRichTextStyler.bodyBox
        let paragraph = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        if richTextEnabled, let b = block(at: paragraph), case .heading(let level) = b.kind { box = ComposerRichTextStyler.headingBox(level) }
        return (frame.minY + line.typographicBounds.minY - box.top, box)
    }

    /// What Chromium paints outside a line's text: an ordered item's `::marker`, which ends where
    /// the item's text starts and may overhang the list's padding, and a quote's 2px left border
    /// down all of its lines.
    private func drawBlockDecorations(in rect: NSRect) {
        guard let storage = textStorage else { return }
        let origin = textContainerOrigin, pad = origin.y - lineTop - blockInfo.topShift
        let body = ComposerRichTextStyler.bodyBox
        let all = NSRange(location: 0, length: storage.length)
        Themed.color(\.contrastBorder).setFill()
        storage.enumerateAttribute(.composerQuote, in: all) { value, range, _ in
            guard value != nil, let first = layoutLine(at: range.location, last: false),
                  let last = layoutLine(at: NSMaxRange(range) - 1, last: true) else { return }
            let top = pad + cssLineTop(first.fragment, first.line, top: body.top)
            let bottom = pad + cssLineTop(last.fragment, last.line, top: body.top) + body.height
            let rail = NSRect(x: origin.x, y: top, width: ComposerBlockLayout.quoteRail, height: bottom - top)
            if rail.intersects(rect) { rail.fill() }
        }
        storage.enumerateAttribute(.attachment, in: all) { value, range, _ in
            guard let block = value as? ComposerBlockAttachment, case .ordered = block.kind, let parts = block.listParts,
                  let line = layoutLine(at: range.location, last: false) else { return }
            let baseline = origin.y + line.fragment.layoutFragmentFrame.minY + line.line.typographicBounds.minY + line.line.glyphOrigin.y
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let marker = NSAttributedString(string: parts.marker + " ", attributes: [.font: Self.markerFont, .foregroundColor: Themed.color(\.foreground)])
            let width = marker.size().width
            let box = NSRect(x: origin.x + (style?.headIndent ?? ComposerBlockLayout.listPadding) - width, y: baseline, width: width, height: 0)
            if box.insetBy(dx: 0, dy: -20).intersects(rect) { marker.draw(with: box, options: []) }
        }
    }

    /// The laid-out text height (one line box when empty).
    var contentHeight: CGFloat {
        guard let tlm = textLayoutManager else { return Self.lineHeight }
        tlm.ensureLayout(for: tlm.documentRange)
        if richTextEnabled, blockInfo.structured, let last = lastLine(tlm) {
            // CSS: the last line box and the margin under it. TextKit lays the empty line after a
            // final newline out as the last line, already at its CSS place (the spacing after).
            let extra = last.line.characterRange.length == 0
            let box = extra ? ComposerRichTextStyler.bodyBox : blockInfo.lastBox
            let trailing = extra ? 0 : blockInfo.trailingGap.map { $0 + Self.lineHeight } ?? 0
            return cssLineTop(last.fragment, last.line, top: box.top) + box.height + trailing + blockInfo.bottom
        }
        var bottom: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            bottom = max(bottom, f.layoutFragmentFrame.maxY)
            return true
        }
        // TextKit gives the last line no trailing line spacing, and an empty trailing line no fragment.
        let lines = max(1, (bottom / Self.lineHeight).rounded())
        let trailingEmpty = string.hasSuffix("\n") ? 1 : 0
        return (lines + CGFloat(trailingEmpty)) * Self.lineHeight
    }
}

extension ComposerEditor: NSTextLayoutManagerDelegate {
    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        GrayscaleTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// T3 draws the prompt with grayscale antialiasing (the composer sits on a composited
/// `backdrop-blur` layer, and T3's default `fontSmoothing` setting is `-webkit-font-smoothing:
/// antialiased`, appearanceFonts.ts:129-130). Core Text's smoothing (stem darkening) made typed text
/// visibly bolder than T3's, so the prompt draws without it, like the composer's own labels.
final class GrayscaleTextLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setShouldSmoothFonts(false)
        super.draw(at: point, in: context)
        context.restoreGState()
    }
}
