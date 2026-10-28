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
    static var lineHeight: CGFloat { 20 * FontRuntime.codeScale }

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
        // `file-preview-virtualizer overflow-auto` (FilePreviewPanel.tsx:911, ReadOnlySourcePreview.tsx:28).
        scrollView.useT3Scrollbars(.native, vertical: true, horizontal: true)
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
    public override func fontRuntimeDidChange() {
        super.fontRuntimeDidChange()
        textView.font = Self.font
        textView.typingAttributes = Self.baseAttributes
        if let storage = textView.textStorage {
            storage.addAttributes(Self.baseAttributes, range: NSRange(location: 0, length: storage.length))
        }
        if !comments.isEmpty { applyComments() }
        gutter.needsDisplay = true
        scheduleHighlight(delay: 0)
    }

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
                storage.addAttribute(.foregroundColor, value: DiffStyle.syntaxColor(token.kind), range: token.range)
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
        let lineCount = lineStarts.count
        updateLineStarts()
        gutter.revealedLine = nil
        if !comments.isEmpty { remapComments(lineCountChanged: lineStarts.count != lineCount) }
        onChange?(textView.string)
        scheduleHighlight(delay: 0.25)
    }

    @objc private func clipScrolled() {
        gutter.needsDisplay = true
        if !comments.isEmpty { placeCommentViews() }
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        if !comments.isEmpty, commentWidth != laidOutWidth { applyComments() }
    }

    // MARK: Line comments

    /// One inline comment under a line range (`FileCommentAnnotationEntry`, fileCommentAnnotations.ts:3-9):
    /// an open draft or a sent comment. Lines are 1-based.
    public struct LineComment: Equatable, Sendable {
        public var id: String
        public var startLine: Int
        public var endLine: Int
        public var text: String
        public var isDraft: Bool
        /// `formatFileCommentRange`.
        public var rangeLabel: String { startLine == endLine ? "L\(startLine)" : "L\(startLine) to L\(endLine)" }
    }

    /// Drag over the line numbers to pick lines, then comment on them inline (FilePreviewPanel.tsx:826-960).
    public var commentsEnabled = false
    public private(set) var comments: [LineComment] = []
    /// A draft was sent: the entry is now a comment.
    public var onSubmitComment: (@MainActor (LineComment) -> Void)?
    public var onDeleteComment: (@MainActor (LineComment) -> Void)?
    /// An edit moved sent comments (`remapFileCommentAnnotations`).
    public var onCommentsMoved: (@MainActor ([LineComment]) -> Void)?
    /// The lines picked in the gutter (`selectedLines`), shown until the draft is sent or cancelled.
    fileprivate(set) var selectedLines: ClosedRange<Int>? {
        didSet { if selectedLines != oldValue { showSelectedLines(); gutter.needsDisplay = true } }
    }
    private var commentViews: [String: NSView] = [:]
    private var laidOutWidth: CGFloat = -1
    /// Comments span the visible code width, also when lines scroll sideways.
    private var commentWidth: CGFloat { min(textView.bounds.width, scrollView.contentSize.width) }
    private static let anchorKey = NSAttributedString.Key("CandyFileCommentAnchor")
    /// `py-1` around each line's group of entries.
    private static let groupPadding: CGFloat = 4

    /// No new selection while a draft is open (`enableLineSelection: !hasOpenCommentForm`).
    var canPickLines: Bool { commentsEnabled && !comments.contains(where: \.isDraft) }

    /// Puts back comments kept from an earlier body of the same file, clamped to its lines.
    public func restoreComments(_ kept: [LineComment]) {
        let last = max(1, lineStarts.count)
        comments = kept.filter { !$0.isDraft }.map { c in
            var c = c
            let span = c.endLine - c.startLine
            c.endLine = min(c.endLine, last); c.startLine = max(1, c.endLine - span)
            return c
        }
        applyComments()
    }

    /// `beginComment`: a draft under the last picked line, replacing any open draft.
    func beginComment(_ lines: ClosedRange<Int>) {
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        window?.makeFirstResponder(nil)
        comments.removeAll(where: \.isDraft)
        let id = "file-comment-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        comments.append(LineComment(id: id, startLine: lines.lowerBound + 1, endLine: lines.upperBound + 1, text: "", isDraft: true))
        applyComments()
        if let draft = commentViews[id] as? DiffReviewAnnotationView { window?.makeFirstResponder(draft.editor) }
    }

    private func submitComment(_ id: String, text: String) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[i].text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16000))
        comments[i].isDraft = false
        selectedLines = nil
        commentViews[id]?.removeFromSuperview(); commentViews[id] = nil
        applyComments()
        onSubmitComment?(comments[i])
    }

    /// `removeAnnotationEntry`: Cancel on a draft, Delete on a comment.
    private func removeComment(_ id: String) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        let removed = comments.remove(at: i)
        selectedLines = nil
        commentViews[id]?.removeFromSuperview(); commentViews[id] = nil
        applyComments()
        if removed.isDraft { window?.makeFirstResponder(textView) } else { onDeleteComment?(removed) }
    }

    /// Each line's group gets its height as paragraph spacing under the line, tagged so edits carry it
    /// along, then the views go into the space.
    private func applyComments() {
        guard let storage = textView.textStorage else { return }
        laidOutWidth = commentWidth
        let width = max(1, commentWidth)
        var groups: [Int: [LineComment]] = [:]
        for c in comments { groups[c.endLine, default: []].append(c) }
        settingText = true
        storage.beginEditing()
        let all = NSRange(location: 0, length: storage.length)
        let base = Self.baseAttributes[.paragraphStyle]
        storage.enumerateAttribute(Self.anchorKey, in: all) { value, range, _ in
            guard value != nil else { return }
            storage.removeAttribute(Self.anchorKey, range: range)
            if let base { storage.addAttribute(.paragraphStyle, value: base, range: range) }
        }
        for (line, entries) in groups {
            let range = paragraphRange(line)
            guard range.length > 0, let style = (base as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { continue }
            style.paragraphSpacing = entries.reduce(2 * Self.groupPadding) { $0 + commentView(for: $1).height(forWidth: width) }
            storage.addAttributes([.paragraphStyle: style, Self.anchorKey: entries.map(\.id).joined(separator: "\n")], range: range)
        }
        storage.endEditing()
        settingText = false
        let live = Set(comments.map(\.id))
        for (id, view) in commentViews where !live.contains(id) { view.removeFromSuperview(); commentViews[id] = nil }
        placeCommentViews()
    }

    /// The characters of 1-based `line`, newline included.
    private func paragraphRange(_ line: Int) -> NSRange {
        let index = max(0, min(line, lineStarts.count) - 1)
        let start = lineStarts[index]
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : (textView.string as NSString).length
        return NSRange(location: start, length: max(0, end - start))
    }

    private func commentView(for comment: LineComment) -> DiffAnnotationContent {
        if let view = commentViews[comment.id] as? DiffAnnotationContent { return view }
        let view: DiffAnnotationContent
        if comment.isDraft {
            let draft = DiffReviewAnnotationView()
            draft.editor.setAccessibilityLabel("Comment on lines \(comment.rangeLabel)")
            draft.onCancel = { [weak self] in self?.removeComment(comment.id) }
            draft.onSubmit = { [weak self] text in self?.submitComment(comment.id, text: text) }
            view = draft
        } else {
            let card = DiffReviewCommentCardView(text: comment.text)
            card.onDelete = { [weak self] in self?.removeComment(comment.id) }
            view = card
        }
        commentViews[comment.id] = view
        textView.addSubview(view)
        return view
    }

    /// Stacks each group's views in the space under its line.
    private func placeCommentViews() {
        guard let tlm = textView.textLayoutManager, let content = tlm.textContentManager else { return }
        let width = commentWidth
        var groups: [Int: [LineComment]] = [:]
        for c in comments { groups[c.endLine, default: []].append(c) }
        for (line, entries) in groups {
            let range = paragraphRange(line)
            guard let location = content.location(content.documentRange.location, offsetBy: range.location) else { continue }
            var bottom: CGFloat?
            tlm.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                bottom = fragment.layoutFragmentFrame.minY + (fragment.textLineFragments.last?.typographicBounds.maxY ?? Self.lineHeight)
                return false
            }
            guard var y = bottom.map({ $0 + Self.groupPadding }) else { continue }
            for entry in entries {
                let view = commentView(for: entry)
                let h = view.height(forWidth: width)
                let frame = NSRect(x: 0, y: y, width: width, height: h)
                if view.frame != frame { view.frame = frame }
                y += h
            }
        }
    }

    /// After an edit, each tag's last line is where its comments now end; their spans stay
    /// (`remapFileCommentAnnotations`). Sent comments that moved are reported.
    private func remapComments(lineCountChanged: Bool) {
        guard let storage = textView.textStorage else { return }
        var ends: [String: Int] = [:]
        storage.enumerateAttribute(Self.anchorKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let ids = value as? String, range.length > 0 else { return }
            let line = lineIndex(at: range.location + range.length - 1) + 1
            for id in ids.split(separator: "\n") { ends[String(id)] = line }
        }
        var moved: [LineComment] = []
        let last = max(1, lineStarts.count)
        for i in comments.indices {
            let end = min(ends[comments[i].id] ?? comments[i].endLine, last)
            guard end != comments[i].endLine else { continue }
            let span = comments[i].endLine - comments[i].startLine
            comments[i].endLine = end; comments[i].startLine = max(1, end - span)
            if !comments[i].isDraft { moved.append(comments[i]) }
        }
        if lineCountChanged || !moved.isEmpty { applyComments() } else { placeCommentViews() }
        if !moved.isEmpty { onCommentsMoved?(moved) }
    }

    /// The picked lines' rows get the selection fill (rendering attributes leave the text alone).
    private func showSelectedLines() {
        guard let tlm = textView.textLayoutManager, let content = tlm.textContentManager else { return }
        tlm.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        guard let lines = selectedLines else { return }
        let start = paragraphRange(lines.lowerBound + 1), end = paragraphRange(lines.upperBound + 1)
        guard let from = content.location(content.documentRange.location, offsetBy: start.location),
              let to = content.location(content.documentRange.location, offsetBy: end.location + end.length),
              let range = NSTextRange(location: from, end: to) else { return }
        tlm.addRenderingAttribute(.backgroundColor, value: Themed.color(\.accent), for: range)
    }

    /// The 0-based line under a point in the text view.
    fileprivate func line(atDocumentY y: CGFloat) -> Int? {
        guard let tlm = textView.textLayoutManager, let content = tlm.textContentManager else { return nil }
        let point = CGPoint(x: 1, y: max(0, y))
        guard let fragment = tlm.textLayoutFragment(for: point) else {
            return lineStarts.isEmpty ? nil : lineStarts.count - 1
        }
        // The comment space at a fragment's top belongs to no line.
        if point.y < fragment.layoutFragmentFrame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0) { return nil }
        return lineIndex(at: content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location))
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

    // Line picking (`enableLineSelection`): press on a number, drag over more, release to comment.
    private var pickStart: Int?
    private func line(for event: NSEvent) -> Int? {
        guard let owner else { return nil }
        let y = convert(event.locationInWindow, from: nil).y + owner.scrollView.contentView.bounds.minY
        return owner.line(atDocumentY: y)
    }
    override func mouseDown(with event: NSEvent) {
        guard let owner, owner.canPickLines, let line = line(for: event) else { return super.mouseDown(with: event) }
        pickStart = line
        owner.selectedLines = line...line
    }
    override func mouseDragged(with event: NSEvent) {
        guard let owner, let start = pickStart, let line = line(for: event) else { return }
        owner.selectedLines = min(start, line)...max(start, line)
        owner.textView.autoscroll(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        guard let owner, pickStart != nil, let lines = owner.selectedLines else { return }
        pickStart = nil
        owner.beginComment(lines)
    }

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
                // A comment's space above (the previous line's paragraph spacing) sits inside this fragment.
                let y = frame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0) - visible.minY
                if line == revealedLine || owner.selectedLines?.contains(line) == true {
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
