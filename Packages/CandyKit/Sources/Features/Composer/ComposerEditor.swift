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
final class ComposerEditor: NSTextView, NSTextViewDelegate {
    var richTextEnabled = false {
        didSet {
            guard richTextEnabled != oldValue else { return }
            let source = expandedText
            setText(source)
            undoManager?.removeAllActions()
        }
    }
    private var lastEditKind = ""
    private var lastEditAt = -Double.infinity
    private var clipboardEdit = false
    private var applyingListEdit = false

    static let font = DSFont.ui(14)
    static let lineHeight: CGFloat = 14 * 1.625

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
        applyStyle()
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
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        insertionPointColor = Themed.color(\.foreground)
    }

    /// Replaces the text with the editor's style (programmatic sets skip the typing attributes).
    /// `text` is the expanded prompt; its tokens come back as chips.
    func setText(_ text: String) {
        isChipifying = true
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
        applyStyle()
        styleRichText(registerUndo: false)
        chipify(registerUndo: false)
        isChipifying = false
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        onTextChange?()
    }

    /// The prompt with every chip as its source text.
    var expandedText: String { expanded(NSRange(location: 0, length: textStorage?.length ?? 0)) }

    func expanded(_ range: NSRange) -> String {
        guard let storage = textStorage, range.length > 0 else { return "" }
        return ComposerRichTextStyler.serialize(storage.attributedSubstring(from: range))
    }

    private var isChipifying = false

    func textDidChange(_ notification: Notification) {
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true { lastEditKind = "other" }
        if !isChipifying, !hasMarkedText(), undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            styleRichText(registerUndo: true)
            chipify(registerUndo: true)
        }
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) { onSelectionChange?() }

    /// Turns finished tokens in the plain text into chips, keeping the caret where it was.
    private func styleRichText(registerUndo: Bool) {
        guard richTextEnabled, let storage = textStorage else { return }
        let rendered = ComposerRichTextStyler.render(storage, base: baseAttributes, width: bounds.width, typing: registerUndo && !applyingListEdit)
        guard !storage.isEqual(to: rendered) else { return }
        let selection = selectedRange()
        let prefix = storage.attributedSubstring(from: NSRange(location: 0, length: min(selection.location, storage.length)))
        let caret = ComposerRichTextStyler.render(prefix, base: baseAttributes, typing: registerUndo && !applyingListEdit).length
        let was = isChipifying
        isChipifying = true
        defer { isChipifying = was }
        let range = NSRange(location: 0, length: storage.length)
        if registerUndo, !shouldChangeText(in: range, replacementString: rendered.string) { return }
        storage.setAttributedString(rendered)
        if registerUndo { didChangeText() }
        setSelectedRange(NSRange(location: min(caret, storage.length), length: min(selection.length, max(0, storage.length - caret))))
        typingAttributes = baseAttributes
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
        let attachment = ComposerChipAttachment(look: look, source: token.source, maxWidth: max(40, bounds.width - 8))
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttributes(baseAttributes, range: NSRange(location: 0, length: out.length))
        out.addAttribute(.composerChipSource, value: token.source, range: NSRange(location: 0, length: out.length))
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

    private var baseAttributes: [NSAttributedString.Key: Any] {
        var attributes = typingAttributes
        attributes[.attachment] = nil
        attributes[.composerChipSource] = nil
        attributes[.composerMarks] = nil
        attributes[.composerCodeBlock] = nil
        attributes[.backgroundColor] = nil
        attributes[.strikethroughStyle] = nil
        attributes[.font] = Self.font
        attributes[.foregroundColor] = Themed.color(\.foreground)
        return attributes
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
        let text = expanded(selectedRange())
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
        breakUndoCoalescing()
        clipboardEdit = true
        insertText(text, replacementRange: selectedRange())
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
        if ComposerView.mention(in: sender) != nil { return .copy }
        if let fileDrop, ComposerFileDrop.hasFiles(sender) { return fileDrop.entered(sender) }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if ComposerView.mention(in: sender) != nil { return .copy }
        if let fileDrop, ComposerFileDrop.hasFiles(sender) { return fileDrop.entered(sender) }
        return super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        fileDrop?.exited()
        super.draggingExited(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
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
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    private func listEdit(indent: Bool) -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        guard let storage = textStorage else { return false }
        let mapping = ComposerRichTextStyler.mapping(storage)
        let cursor = mapping.offsets[min(selection.location, mapping.offsets.count - 1)]
        guard let edit = ComposerListContinuation.edit(mapping.value, selection: NSRange(location: cursor, length: 0), indent: indent) else { return false }
        let start = mapping.offsets.lastIndex(where: { $0 <= edit.range.location }) ?? 0
        let end = mapping.offsets.lastIndex(where: { $0 <= NSMaxRange(edit.range) }) ?? start
        breakUndoCoalescing()
        applyingListEdit = true
        replace(NSRange(location: start, length: max(0, end - start)), with: edit.replacement)
        applyingListEdit = false
        if indent { setSelectedRange(NSRange(location: min(selection.location + 2, textStorage?.length ?? 0), length: 0)) }
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
           !hasMarkedText(), listEdit(indent: true) { return }
        let returnKeys: Set<UInt16> = [36, 76]
        if returnKeys.contains(event.keyCode) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = ComposerLogic.Key(isReturn: true, shift: flags.contains(.shift), option: flags.contains(.option),
                                        mod: flags.contains(.command), control: flags.contains(.control),
                                        isRepeat: event.isARepeat, composing: hasMarkedText())
            let linePrefix = (expanded(NSRange(location: 0, length: selectedRange().location))).components(separatedBy: "\n").last ?? ""
            if richTextEnabled, !key.mod, !key.control, !key.composing,
               linePrefix.range(of: #"^(`{3,}|~{3,})[^\n]*$"#, options: .regularExpression) != nil {
                insertNewline(nil); return
            }
            if richTextEnabled, !key.mod, !key.control, !key.composing, let storage = textStorage {
                let prior = selectedRange().location > 0 ? storage.attribute(.attachment, at: selectedRange().location - 1, effectiveRange: nil) as? ComposerBlockAttachment : nil
                var justClosed = false
                if let prior, case .codeEnd = prior.kind { justClosed = true }
                if codeFenceAtCaret != nil || justClosed {
                    let indent = justClosed ? "" : String(linePrefix.prefix { $0 == " " || $0 == "\t" })
                    insertText("\n" + indent, replacementRange: selectedRange()); return
                }
            }
            if onSubmitKey?(key) == true { return }
            if !key.composing, listEdit(indent: false) { return }
        }
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
        if let storage = textStorage, index < storage.length {
            if let chip = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerChipAttachment,
               onOpenChip?(chip.source) == true { return }
            if let block = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ComposerBlockAttachment,
               case .codeHeader(let fence, let info) = block.kind {
                let items = ComposerCodeLanguages.entries.map { entry in
                    var item = MenuItem.radio(entry.label, checked: ComposerCodeLanguages.label(info) == entry.label)
                    item.closesOnClick = true
                    item.action = { [weak self] in
                        self?.replace(NSRange(location: index, length: 1), with: fence + ComposerCodeLanguages.replacing(info, with: entry.id))
                    }
                    return item
                }
                MenuPopupView.show(items, from: self, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none), minimumWidth: 224, anchorRect: NSRect(x: point.x, y: point.y, width: 1, height: 1))
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
        return super.resignFirstResponder()
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

    /// The laid-out text height (one line box when empty).
    var contentHeight: CGFloat {
        guard let tlm = textLayoutManager else { return Self.lineHeight }
        tlm.ensureLayout(for: tlm.documentRange)
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
