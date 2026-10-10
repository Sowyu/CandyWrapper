import AppKit
import DesignSystem

/// A workspace file's source (pierre `File` in FilePreviewPanel.tsx `EditableFileSurface` and
/// ReadOnlySourcePreview.tsx): the diff view's code look (13px mono, 20px lines, the line number
/// gutter, pierre token colors) in an editable TextKit 2 text view. TextKit 2 lays out only what
/// is near the viewport, so a 1 MB file stays cheap. Tokens are computed off the main thread.
public final class CodeFileView: DSView, NSTextViewDelegate {
    public let scrollView = NSScrollView()
    public let textView: NSTextView
    private let gutter: CodeGutterView
    private var language = ""
    private var highlightTask: Task<Void, Never>?
    private var settingText = false
    /// Line start offsets (UTF-16) for the gutter.
    fileprivate var lineStarts: [Int] = [0]

    /// Every edit, with the whole text.
    public var onChange: (@MainActor (String) -> Void)?
    public var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }
    /// T3's `wordWrap` client setting, default on.
    public var wrap = true { didSet { if wrap != oldValue { applyWrap() } } }

    static var font: NSFont { DSFont.mono(13) }
    static let lineHeight: CGFloat = 20

    public override init(frame frameRect: NSRect) {
        textView = NSTextView(usingTextLayoutManager: true)
        gutter = CodeGutterView(scrollView: scrollView, orientation: .verticalRuler)
        super.init(frame: frameRect)
        gutter.owner = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: DiffStyle.ch, height: 0)
        textView.delegate = self
        textView.font = Self.font
        textView.typingAttributes = Self.baseAttributes
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        gutter.clientView = textView
        // Views don't clip their drawing since macOS 14; numbers above the top would paint over the notice.
        gutter.clipsToBounds = true
        clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Selector observers go away with the view; a block observer per opened file would pile up.
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        applyWrap()
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        let f = font
        return [.font: f, .foregroundColor: DiffStyle.codeText, .paragraphStyle: style,
                .baselineOffset: ((lineHeight - (f.ascender - f.descender)) / 2).rounded() / 2]
    }

    /// Shows `text` for `path` (the path picks the highlighting).
    public func setText(_ text: String, path: String) {
        language = UnifiedDiff.language(forPath: path)
        settingText = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.baseAttributes))
        settingText = false
        textView.undoManager?.removeAllActions()
        updateLineStarts()
        scheduleHighlight(delay: 0)
    }

    public var text: String { textView.string }

    private func applyWrap() {
        guard let container = textView.textContainer else { return }
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            textView.autoresizingMask = [.width]
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.autoresizingMask = []
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.needsLayout = true
    }

    // MARK: Highlighting

    private func scheduleHighlight(delay: TimeInterval) {
        highlightTask?.cancel()
        guard CodeHighlighter.supports(language) else { return }
        let text = textView.string, language = language
        highlightTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let tokens = await Task.detached(priority: .userInitiated) { CodeHighlighter.tokens(text, language: language) }.value
            guard !Task.isCancelled, let self, self.textView.string == text, let storage = self.textView.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: DiffStyle.codeText, range: all)
            for token in tokens where NSMaxRange(token.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            }
            storage.endEditing()
        }
    }

    // MARK: Lines

    private func updateLineStarts() {
        var starts = [0]
        let units = textView.string.utf16
        var i = 0, previousCR = false
        for c in units {
            i += 1
            if c == 0x0A { if previousCR { starts[starts.count - 1] = i } else { starts.append(i) }; previousCR = false }
            else if c == 0x0D { starts.append(i); previousCR = true }
            else { previousCR = false }
        }
        lineStarts = starts
        let digits = String(starts.count).count
        let width = DiffStyle.gutterWidth(digits: digits, ch: DiffStyle.ch)
        if gutter.ruleThickness != width { gutter.ruleThickness = width }
        gutter.needsDisplay = true
    }

    fileprivate func lineIndex(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Scrolls `line` (1-based, clamped) to the middle and selects it (`useFileLineReveal`).
    public func reveal(line: Int) {
        let index = max(0, min(line, lineStarts.count) - 1)
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : (textView.string as NSString).length
        let range = NSRange(location: start, length: max(0, end - start))
        textView.setSelectedRange(range)
        guard let tlm = textView.textLayoutManager, let content = tlm.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: start) else { return }
        tlm.ensureLayout(for: NSTextRange(location: location))
        var y: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            y = fragment.layoutFragmentFrame.minY
            return false
        }
        let clip = scrollView.contentView
        let target = max(0, y - (clip.bounds.height - Self.lineHeight) / 2)
        clip.scroll(to: NSPoint(x: 0, y: min(target, max(0, textView.frame.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
        gutter.revealedLine = index
    }

    // MARK: NSTextViewDelegate

    public func textDidChange(_ notification: Notification) {
        guard !settingText else { return }
        updateLineStarts()
        gutter.revealedLine = nil
        onChange?(textView.string)
        scheduleHighlight(delay: 0.25)
    }

    @objc private func clipScrolled() { gutter.needsDisplay = true }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    public override func updateLayer() {
        layer?.backgroundColor = DiffStyle.surface.cgColor(in: self)
    }
}

/// The line number column (pierre's `[data-column-number]`): numbers right-aligned 1ch before the
/// 2px border, in the diff's number color.
final class CodeGutterView: NSRulerView {
    weak var owner: CodeFileView?
    var revealedLine: Int? { didSet { needsDisplay = true } }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = DiffStyle.gutterWidth(digits: 2, ch: DiffStyle.ch)
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    override func draw(_ dirtyRect: NSRect) {
        DiffStyle.surface.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let owner, let textView = owner.textView as NSTextView?, let tlm = textView.textLayoutManager,
              let content = tlm.textContentManager else { return }
        let visible = owner.scrollView.contentView.bounds
        let font = CodeFileView.font
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: DiffStyle.number]
        let right = ruleThickness - DiffStyle.gutterBorder - DiffStyle.ch
        let viewportStart = tlm.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        var lastLine = -1
        tlm.enumerateTextLayoutFragments(from: viewportStart, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = owner.lineIndex(at: offset)
            if line != lastLine, frame.maxY >= visible.minY {
                lastLine = line
                let y = frame.minY - visible.minY
                if line == revealedLine {
                    Themed.color(\.accent).setFill()
                    NSRect(x: 0, y: y, width: ruleThickness - DiffStyle.gutterBorder, height: CodeFileView.lineHeight).fill()
                }
                let s = NSAttributedString(string: String(line + 1), attributes: attrs)
                let w = s.size().width
                s.draw(at: NSPoint(x: right - w, y: y + (CodeFileView.lineHeight - (font.ascender - font.descender)) / 2))
            }
            return true
        }
    }
}
