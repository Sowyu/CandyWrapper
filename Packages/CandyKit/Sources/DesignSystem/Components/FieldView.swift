import AppKit

/// Shared base of Input, Textarea and InputGroup: T3's `input-control` / `textarea-control` /
/// `input-group` frame around a TextKit 2 editor, plus the placeholder we draw ourselves.
/// Spec: docs/research/recovered/ui-components-a.md sections 3 to 5.
public class FieldView: DSView {
    /// What the frame's `:has(...)` selectors see. Text fields match `:focus-visible` on any focus.
    public struct State: Equatable, Sendable {
        public var focused = false
        public var invalid = false   // `aria-invalid="true"`
        public var enabled = true
        public var hovered = false   // only InputGroup's ghost variant reacts
        public init(focused: Bool = false, invalid: Bool = false, enabled: Bool = true, hovered: Bool = false) {
            self.focused = focused; self.invalid = invalid; self.enabled = enabled; self.hovered = hovered
        }
    }

    public internal(set) var state = State() {
        didSet { if state != oldValue { stateDidChange(from: oldValue) } }
    }

    /// Forces a state for the gallery and visual tests.
    public func previewState(_ state: State) { self.state = state }

    public var isInvalid: Bool {
        get { state.invalid }
        set { state.invalid = newValue }
    }

    public var isEnabled: Bool {
        get { state.enabled }
        set { state.enabled = newValue }
    }

    public var text: String {
        get { editor.string }
        set { editor.string = newValue; applyTypingStyle(); textChanged() }
    }

    public var placeholder: String = "" { didSet { placeholderLabel.text = placeholder } }

    /// Called on every edit.
    public final var onChange: (@MainActor (String) -> Void)?
    /// Called after every state change (InputGroup mirrors its input this way).
    public final var onStateChange: (@MainActor (State) -> Void)?
    /// Return in a single-line field, which then keeps focus. Without it Return ends editing.
    public final var onSubmit: (@MainActor () -> Void)?
    /// An input method is composing (`isComposing`): Enter belongs to it.
    public var hasMarkedText: Bool { editor.hasMarkedText() }
    /// Sees every editing command first (`moveUp:`, `insertNewline:`, `deleteBackward:`, `cancelOperation:`);
    /// true means handled. Lets a field drive a list the way an autocomplete input does.
    public final var onCommand: (@MainActor (Selector) -> Bool)?
    /// Sees a paste first, from Cmd-V or Edit > Paste; true means it took the pasteboard (an image, say) and the
    /// text paste does not happen.
    public final var onPaste: (@MainActor (NSPasteboard) -> Bool)?
    /// False when a parent (InputGroup) applies `opacity-64` instead.
    var dimsWhenDisabled = true

    let decoration = BoxDecorationLayer()
    let editor: FieldEditor
    let scroll = NSScrollView()
    let placeholderLabel = LabelView()
    private var trackingArea: NSTrackingArea?

    /// Font, CSS line-height and text color the editor uses.
    var font: NSFont = DSFont.ui(14) { didSet { applyTypingStyle() } }
    var lineHeight: CGFloat = 20 { didSet { applyTypingStyle() } }

    init(multiline: Bool) {
        editor = FieldEditor(multiline: multiline)
        super.init(frame: .zero)
        decoration.host = self
        decoration.transition = [.shadow, .border] // transition-shadow (input.tsx:68, textarea.tsx:20); the border swaps with the ring
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // A textarea gets Chromium's styled scrollbar (index.css:1744-1760); an input never shows one.
        if multiline { scroll.useT3Scrollbars(.native, reservesLane: false) } else { scroll.hasVerticalScroller = false }
        scroll.hasHorizontalScroller = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = editor
        addSubview(scroll)

        placeholderLabel.truncates = true
        addSubview(placeholderLabel, positioned: .below, relativeTo: scroll)

        editor.field = self
        editor.delegate = editor
        applyTypingStyle()
    }

    // MARK: Text style

    func applyTypingStyle() {
        let metrics = FieldEditor.lineMetrics(font: font, lineHeight: lineHeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = metrics.lineSpacing
        // ponytail: never wraps a single-line field; long values scroll inside the clip view
        paragraph.lineBreakMode = editor.isMultiline ? .byWordWrapping : .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Themed.color(\.contrastForeground),
            .paragraphStyle: paragraph,
        ]
        editor.typingAttributes = attributes
        editor.textContainerInset = NSSize(width: 0, height: metrics.top)
        if let storage = editor.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        // `caret-color: var(--contrast-foreground)`; selection keeps Chromium's default, the system highlight.
        editor.insertionPointColor = Themed.color(\.contrastForeground)
        placeholderLabel.font = font
        placeholderLabel.lineHeight = lineHeight
        needsLayout = true
    }

    func textChanged() {
        placeholderLabel.isHidden = !editor.string.isEmpty
        onChange?(editor.string)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: State

    func stateDidChange(from old: State) {
        if old.enabled != state.enabled {
            alphaValue = state.enabled || !dimsWhenDisabled ? 1 : 0.64  // `has-disabled:opacity-64`
            editor.isEditable = state.enabled
            editor.isSelectable = state.enabled
        }
        restyle()
        onStateChange?(state)
    }

    /// Subclasses set the decoration and placeholder color here.
    func restyle() {}

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
    }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
    }

    // MARK: Focus and pointer

    public override var acceptsFirstResponder: Bool { state.enabled }
    public override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(editor) ?? false }

    public override func mouseDown(with event: NSEvent) {
        // Clicks on padding or addons focus the editor, like InputGroupAddon's onMouseDown.
        guard state.enabled else { return }
        window?.makeFirstResponder(editor)
    }

    public override func resetCursorRects() {
        if state.enabled { addCursorRect(bounds, cursor: .iBeam) }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { state.hovered = true }
    public override func mouseExited(with event: NSEvent) { state.hovered = false }

    /// Places the editor's line box at `rect` (CSS content box, top-left origin). `trailingPadding` lets the clip view
    /// reach the padding box's trailing edge, where Chromium draws a textarea's scrollbar; the text keeps its width.
    func placeEditor(in rect: NSRect, trailingPadding: CGFloat = 0) {
        // ponytail: the text keeps its width while the bar shows, Chromium's narrows by 6px; move the padding into the clip view if wraps must match
        scroll.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width + trailingPadding, height: rect.height)
        let width = editor.isMultiline ? rect.width : max(rect.width, editor.usedWidth + 2)
        editor.minSize = NSSize(width: rect.width, height: rect.height)
        editor.frame = NSRect(x: 0, y: 0, width: width, height: max(rect.height, editor.usedHeight))
        placeholderLabel.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: lineHeight)
    }
}

/// Frame styles shared by Input, Textarea and InputGroup's default variant (input.tsx:68).
@MainActor
public enum FieldStyles {
    public static func frame(state: FieldView.State, radius: CGFloat) -> BoxStyle {
        var box = BoxStyle()
        box.radius = radius
        box.border = Themed.color(\.contrastInput)
        box.fill = Themed.color(light: \.background, 1, dark: \.contrastInput, 0.32)
        box.backgroundClip = .paddingInLight
        let quiet = !state.enabled || state.focused || state.invalid
        if !quiet {
            box.shadows.append(BoxShadow(y: 1, blur: 2, color: Themed.black(0.05)))
            box.beforeShadows.append(BoxShadow(y: 1, color: Themed.pick(light: Themed.black(0.04), dark: .clear)))
            box.beforeShadows.append(BoxShadow(y: -1, color: Themed.pick(light: .clear, dark: Themed.white(0.06))))
        }
        if state.invalid {
            box.border = Themed.color(\.destructive, state.focused ? 0.64 : 0.36)
        } else if state.focused {
            box.border = Themed.color(\.ring)
        }
        if state.focused {
            let ring = state.invalid
                ? Themed.color(light: \.destructive, 0.16, dark: \.destructive, 0.24)
                : Themed.color(\.ring, 0.24)
            box.shadows.insert(BoxShadow(spread: 3, color: ring), at: 0)
        }
        return box
    }
}

/// The TextKit 2 editing engine inside a field. Draws no background, no focus ring.
final class FieldEditor: NSTextView, NSTextViewDelegate {
    weak var field: FieldView?
    let isMultiline: Bool

    init(multiline: Bool) {
        isMultiline = multiline
        let tlm = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: multiline ? 0 : CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = multiline
        container.lineFragmentPadding = 0
        tlm.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(tlm)
        super.init(frame: .zero, textContainer: container)
        drawsBackground = false
        textContainerInset = .zero
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = !multiline
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        focusRingType = .none
        if !multiline { textContainer?.maximumNumberOfLines = 1 }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        isMultiline = true
        super.init(frame: frameRect, textContainer: container)
    }

    override func paste(_ sender: Any?) {
        if field?.onPaste?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }

    /// A plain-text view disables Paste when the pasteboard holds only an image or files; a field that takes those
    /// (`onPaste`) keeps it on, as the thread composer's editor does.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), field?.onPaste != nil, isEditable,
           NSPasteboard.general.availableType(from: [.png, .tiff, .fileURL]) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { field?.state.focused = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { field?.state.focused = false }
        return ok
    }

    /// Single-line fields end editing on Return, like `<input>` (DraftInput commits on Enter).
    override func insertNewline(_ sender: Any?) {
        if isMultiline { super.insertNewline(sender) } else if let submit = field?.onSubmit { submit() } else { window?.makeFirstResponder(nil) }
    }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    func textDidChange(_ notification: Notification) { field?.textChanged() }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        field?.onCommand?(commandSelector) ?? false
    }

    /// Laid-out size of the text.
    var usedWidth: CGFloat { layoutExtent.width }
    var usedHeight: CGFloat { layoutExtent.height }

    private var layoutExtent: CGSize {
        guard let tlm = textLayoutManager else { return .zero }
        tlm.ensureLayout(for: tlm.documentRange)
        var rect = CGRect.zero
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            rect = rect.union(f.layoutFragmentFrame)
            return true
        }
        return rect.size
    }

    /// CSS line boxes: each line is `lineHeight` tall and the baseline sits where Blink puts it
    /// (rounded ascent + descent centered, half-leading floored). TextKit 2 shrinks lines when
    /// `baselineOffset` is set and puts min/max line-height slack above the glyphs, so instead the
    /// natural line gets `lineSpacing` up to the CSS height and the text starts `top` lower.
    /// Measured once per font and line height.
    @MainActor static func lineMetrics(font: NSFont, lineHeight: CGFloat) -> (lineSpacing: CGFloat, top: CGFloat) {
        let key = "\(font.fontName)-\(font.pointSize)-\(lineHeight)"
        if let cached = shiftCache[key] { return cached }
        let storage = NSTextContentStorage()
        let tlm = NSTextLayoutManager()
        storage.addTextLayoutManager(tlm)
        tlm.textContainer = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        storage.attributedString = NSAttributedString(string: "Hg", attributes: [.font: font])
        var natural = ceil(font.ascender - font.descender), baseline = ceil(font.ascender)
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            if let line = f.textLineFragments.first {
                natural = line.typographicBounds.height
                baseline = line.glyphOrigin.y
            }
            return false
        }
        let css = TextLine(NSAttributedString(string: "Hg", attributes: [.font: font])).baseline(top: 0, lineHeight: lineHeight)
        let result = (lineSpacing: lineHeight - natural, top: css - baseline)
        shiftCache[key] = result
        return result
    }

    @MainActor private static var shiftCache: [String: (lineSpacing: CGFloat, top: CGFloat)] = [:]
}

/// CSS line boxes for a TextKit 2 view outside the fields (the composer's editor): the line spacing
/// that makes each line `lineHeight` tall and how far the first baseline moves down.
@MainActor public func textKitLineMetrics(font: NSFont, lineHeight: CGFloat) -> (lineSpacing: CGFloat, top: CGFloat) {
    FieldEditor.lineMetrics(font: font, lineHeight: lineHeight)
}
