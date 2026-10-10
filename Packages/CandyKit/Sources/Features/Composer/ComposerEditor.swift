import AppKit
import DesignSystem

/// The prompt editor (`ComposerPromptEditorTiptap`): plain text in a TextKit 2 view, 14px system
/// font on a 22.75px line (`leading-relaxed`), foreground caret, no focus ring. Return goes
/// through `ComposerLogic.submitIntent`; anything that isn't a send edits as usual.
// ponytail: plain text only; Tiptap's inline code, mention chips and list continuation come with M5 stretch
final class ComposerEditor: NSTextView, NSTextViewDelegate {
    static let font = DSFont.ui(14)
    static let lineHeight: CGFloat = 14 * 1.625

    /// Asked on Return; true when it handled the key as a send.
    var onSubmitKey: ((ComposerLogic.Key) -> Bool)?
    var onTextChange: (() -> Void)?
    /// The Cmd/Ctrl modifier went down or up (the queue and steer icons swap while it is held).
    var onModifierChange: ((Bool) -> Void)?

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
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        insertionPointColor = Themed.color(\.foreground)
    }

    /// Replaces the text with the editor's style (programmatic sets skip the typing attributes).
    func setText(_ text: String) {
        string = text
        applyStyle()
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        onTextChange?()
    }

    func textDidChange(_ notification: Notification) { onTextChange?() }

    // Pasted rich text arrives as plain text with our style.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func keyDown(with event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76]
        if returnKeys.contains(event.keyCode) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = ComposerLogic.Key(isReturn: true, shift: flags.contains(.shift), option: flags.contains(.option),
                                        mod: flags.contains(.command) || flags.contains(.control),
                                        isRepeat: event.isARepeat, composing: hasMarkedText())
            if onSubmitKey?(key) == true { return }
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
