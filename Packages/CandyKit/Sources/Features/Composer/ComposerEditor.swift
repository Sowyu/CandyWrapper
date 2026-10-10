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
// ponytail: plain text only; Tiptap's inline code, rich text and list continuation come later
final class ComposerEditor: NSTextView, NSTextViewDelegate {
    static let font = DSFont.ui(14)
    static let lineHeight: CGFloat = 14 * 1.625

    /// Asked on Return; true when it handled the key as a send.
    var onSubmitKey: ((ComposerLogic.Key) -> Bool)?
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
        string = text
        applyStyle()
        chipify(registerUndo: false)
        isChipifying = false
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        onTextChange?()
    }

    /// The prompt with every chip as its source text.
    var expandedText: String { expanded(NSRange(location: 0, length: textStorage?.length ?? 0)) }

    func expanded(_ range: NSRange) -> String {
        guard let storage = textStorage, range.length > 0 else { return "" }
        var out = ""
        storage.enumerateAttribute(.attachment, in: range) { value, sub, _ in
            if let chip = value as? ComposerChipAttachment {
                out += String(repeating: chip.source, count: sub.length)
            } else {
                out += storage.attributedSubstring(from: sub).string
            }
        }
        return out
    }

    private var isChipifying = false

    func textDidChange(_ notification: Notification) {
        if !isChipifying, !hasMarkedText() { chipify(registerUndo: true) }
        onTextChange?()
    }

    func textViewDidChangeSelection(_ notification: Notification) { onSelectionChange?() }

    /// Turns finished tokens in the plain text into chips, keeping the caret where it was.
    private func chipify(registerUndo: Bool) {
        guard let storage = textStorage, let chipLook else { return }
        let display = string as NSString
        // A token that already holds a chip character is left alone.
        let tokens = ComposerInlineTokens.collect(string).filter { !display.substring(with: $0.range).contains("\u{FFFC}") }
        guard !tokens.isEmpty else { return }
        let wasChipifying = isChipifying
        isChipifying = true
        defer { isChipifying = wasChipifying }
        var selection = selectedRange()
        for token in tokens.reversed() {
            let chip = makeChip(token, look: chipLook(token))
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
        string = expandedText
        applyStyle()
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
        attributes[.font] = Self.font
        attributes[.foregroundColor] = Themed.color(\.foreground)
        return attributes
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChips()
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
        guard let text = pboard.string(forType: .string) else { return pasteAsPlainText(sender) }
        if let html = pboard.string(forType: .html) {
            let records = ComposerContext.pastedRecords(html: html, pastedText: text)
            if !records.isEmpty { onPasteRecords?(records) }
        }
        insertText(text, replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
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
        let returnKeys: Set<UInt16> = [36, 76]
        if returnKeys.contains(event.keyCode) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = ComposerLogic.Key(isReturn: true, shift: flags.contains(.shift), option: flags.contains(.option),
                                        mod: flags.contains(.command), control: flags.contains(.control),
                                        isRepeat: event.isARepeat, composing: hasMarkedText())
            if onSubmitKey?(key) == true { return }
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
        return super.performKeyEquivalent(with: event)
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
