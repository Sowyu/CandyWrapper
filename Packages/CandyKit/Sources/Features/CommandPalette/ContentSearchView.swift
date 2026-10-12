import AppKit
import DesignSystem
import T3Protocol

/// Search project contents (`ProjectContentSearchDialog`, apps/web/src/components/search/): the
/// palette's "content" mode. The match options sit in the input (`Aa`, `ab`, `.*`), a status line
/// counts results, and matches group by file with their line number and the line, syntax colored,
/// the match marked. Rows render in windows of 100 that grow as the list scrolls.
public final class ContentSearchView: DSView {
    public struct Options: Equatable, Sendable {
        public var caseSensitive = false
        public var wholeWord = false
        public var useRegex = false
        public init() {}
    }

    public enum Status: Equatable {
        case idle
        case pending
        case error(String)
        case invalidRegex
        case results(count: Int, truncated: Bool, files: Int)
    }

    /// The input accessory: the three option toggles in a `rounded-md border bg-muted/30 p-0.5` box.
    public let accessory = OptionsBox()
    public var options = Options() { didSet { accessory.options = options } }
    /// The options changed (the query comes from the palette's input).
    public var onOptionsChange: (@MainActor (Options) -> Void)?
    public var onOpen: (@MainActor (ProjectContentMatch) -> Void)?

    public private(set) var matches: [ProjectContentMatch] = []
    public private(set) var status: Status = .idle
    /// The empty list's message: "Type to search across your project.", "No results found." and so on.
    public private(set) var emptyMessage = "Type to search across your project."
    /// Matches can open only once the visible results belong to the current query.
    public var canOpen = true
    public private(set) var selectedIndex = 0

    private var scrollObserver: NSObjectProtocol?
    private let statusLine = DSView()
    private let statusLabel = LabelView("", font: DSFont.ui(12))
    private let spinner = SpinnerView(size: .sm)
    private let statusBorder = CALayer()
    private let empty = LabelView("", font: DSFont.ui(14))
    private let document = DSView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollFade: true)
    private var headerViews: [GroupHeader] = []
    private var rowViews: [MatchRow] = []
    static let window = 100
    private var visibleCount = window

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        statusLabel.lineHeight = 16
        empty.lineHeight = 20
        empty.alignment = .center
        statusBorder.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
        statusLine.layer?.addSublayer(statusBorder)
        [spinner, statusLabel].forEach(statusLine.addSubview)
        [statusLine, empty, scroll].forEach(addSubview)
        accessory.onChange = { [weak self] options in
            guard let self else { return }
            self.options = options
            self.onOptionsChange?(options)
        }
        scroll.scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.growIfNeeded() }
        }
        apply(matches: [], status: .idle, empty: "Type to search across your project.")
    }

    isolated deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

    /// Shows a search state. Matches reset the selection to the first row (`setSelectedIndex(0)`).
    public func apply(matches: [ProjectContentMatch], status: Status, empty message: String) {
        let changed = matches != self.matches
        self.matches = matches
        self.status = status
        emptyMessage = message
        if changed {
            selectedIndex = 0
            visibleCount = Self.window
            rebuildRows()
        }
        updateStatus()
        needsLayout = true
    }

    /// `showSearchStatus`: the line shows for a query, a pending search, an error or a bad regex.
    private var showsStatus: Bool { status != .idle }

    private func updateStatus() {
        spinner.isHidden = status != .pending
        switch status {
        case .idle: statusLabel.text = ""
        case .pending: statusLabel.text = "Searching\u{2026}"
        case .error(let message): statusLabel.text = message
        case .invalidRegex: statusLabel.text = "Invalid regular expression"
        case .results(let count, let truncated, let files):
            let f = NumberFormatter()
            f.numberStyle = .decimal
            statusLabel.text = "\(f.string(from: count as NSNumber) ?? "\(count)")\(truncated ? "+" : "") results in \(f.string(from: files as NSNumber) ?? "\(files)") files"
        }
        statusLine.isHidden = !showsStatus
        empty.text = emptyMessage
        empty.isHidden = !matches.isEmpty
        scroll.isHidden = matches.isEmpty
        rowViews.forEach { $0.isEnabled = canOpen }
        needsDisplay = true
    }

    private func rebuildRows() {
        headerViews.forEach { $0.removeFromSuperview() }
        rowViews.forEach { $0.removeFromSuperview() }
        headerViews = []
        rowViews = []
        let visible = Array(matches.prefix(visibleCount).enumerated())
        var groups: [(String, [(Int, ProjectContentMatch)])] = []
        for (i, m) in visible {
            if let last = groups.last, last.0 == m.path { groups[groups.count - 1].1.append((i, m)) } else { groups.append((m.path, [(i, m)])) }
        }
        for (path, items) in groups {
            let header = GroupHeader(path: path, count: items.count)
            headerViews.append(header)
            document.addSubview(header)
            for (index, match) in items {
                let row = MatchRow(match: match, index: index)
                row.isSelected = index == selectedIndex
                row.onHover = { [weak self] in self?.select(index, scroll: false) }
                row.onClick = { [weak self] in self?.open(index) }
                rowViews.append(row)
                document.addSubview(row)
            }
        }
        needsLayout = true
    }

    private func growIfNeeded() {
        guard matches.count > visibleCount else { return }
        let visible = scroll.scrollView.contentView.bounds
        if visible.maxY >= document.frame.height - 32 {
            visibleCount += Self.window
            let offset = visible.origin
            rebuildRows()
            layoutSubtreeIfNeeded()
            scroll.scroll(to: offset)
        }
    }

    // MARK: Keys

    /// Arrows wrap through the matches, Return opens the selected one (`onKeyDown`).
    public func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !matches.isEmpty { select((selectedIndex + 1) % matches.count, scroll: true) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !matches.isEmpty { select((selectedIndex - 1 + matches.count) % matches.count, scroll: true) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if canOpen, selectedIndex < matches.count { open(selectedIndex) }
            return true
        default:
            return false
        }
    }

    private func select(_ index: Int, scroll scrollIntoView: Bool) {
        guard index != selectedIndex || scrollIntoView else { return }
        selectedIndex = index
        if index >= visibleCount {
            visibleCount = index + Self.window
            rebuildRows()
            layoutSubtreeIfNeeded()
        }
        rowViews.forEach { $0.isSelected = $0.index == index }
        guard scrollIntoView, let row = rowViews.first(where: { $0.index == index }) else { return }
        let visible = scroll.scrollView.contentView.bounds
        var y = visible.minY
        if row.frame.minY < visible.minY { y = row.frame.minY } else if row.frame.maxY > visible.maxY { y = row.frame.maxY - visible.height }
        if y != visible.minY { scroll.scroll(to: NSPoint(x: 0, y: max(0, y))) }
    }

    private func open(_ index: Int) {
        guard canOpen, index < matches.count else { return }
        onOpen?(matches[index])
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        var top: CGFloat = 0
        if showsStatus {
            statusLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 36)
            statusBorder.frame = CGRect(x: 0, y: 35, width: bounds.width, height: 1)
            var x: CGFloat = 12
            if !spinner.isHidden { spinner.frame = NSRect(x: x, y: 11, width: 14, height: 14); x += 14 + 8 }
            statusLabel.frame = NSRect(x: x, y: 10, width: max(0, bounds.width - x - 12), height: 16)
            top = 36
        }
        let area = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        empty.frame = NSRect(x: 24, y: area.midY - 10, width: max(0, bounds.width - 48), height: 20)
        scroll.frame = area
        var y: CGFloat = 8
        var rows = rowViews[...]
        for header in headerViews {
            header.frame = NSRect(x: 0, y: y, width: bounds.width, height: 32)
            y += 32
            for _ in 0..<header.count {
                guard let row = rows.popFirst() else { break }
                row.frame = NSRect(x: 0, y: y, width: bounds.width, height: 28)
                y += 28
            }
            y += 8
        }
        if matches.count > visibleCount { y += 32 }
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(area.height, y))
    }

    public override func updateLayer() {
        statusBorder.backgroundColor = Themed.color(\.border).cgColor(in: self)
        empty.color = Themed.color(\.mutedForeground)
        statusLabel.color = {
            switch status {
            case .error, .invalidRegex: return Themed.color(\.destructive)
            default: return Themed.color(\.mutedForeground)
            }
        }()
        spinner.color = Themed.color(\.mutedForeground)
    }

    /// The option toggles: segmented toggles with mono labels.
    public final class OptionsBox: DSView {
        let toggles: [ToggleView]
        var onChange: (@MainActor (Options) -> Void)?
        var options = Options() {
            didSet {
                toggles[0].isPressed = options.caseSensitive
                toggles[1].isPressed = options.wholeWord
                toggles[2].isPressed = options.useRegex
            }
        }
        public var isEnabled = true { didSet { toggles.forEach { $0.isEnabled = isEnabled } } }

        public override init(frame frameRect: NSRect) {
            toggles = ["Aa", "ab", ".*"].map { ToggleView($0, variant: .segmented, size: .segmented) }
            super.init(frame: frameRect)
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            for (i, (t, label)) in zip(toggles, ["Match case", "Match whole word", "Use regular expression"]).enumerated() {
                t.monospaced = true
                t.underlinesTitle = i == 1 // "Match whole word" (ProjectContentSearchDialog.tsx:191)
                t.toolTip = label
                t.setAccessibilityLabel(label)
                t.onPressedChange = { [weak self] on in
                    guard let self else { return }
                    var o = self.options
                    switch i { case 0: o.caseSensitive = on; case 1: o.wholeWord = on; default: o.useRegex = on }
                    self.options = o
                    self.onChange?(o)
                }
                addSubview(t)
            }
        }

        /// `p-0.5 gap-0.5` inside a 1px border.
        public override var intrinsicContentSize: NSSize {
            NSSize(width: 2 + 4 + toggles.reduce(0) { $0 + $1.intrinsicContentSize.width } + 2 * 2, height: 24 + 6)
        }

        public override func layout() {
            super.layout()
            var x: CGFloat = 3
            for t in toggles {
                let w = t.intrinsicContentSize.width
                t.frame = NSRect(x: x, y: 3, width: w, height: 24)
                x += w + 2
            }
        }

        public override func updateLayer() {
            layer?.backgroundColor = Themed.color(\.muted, 0.3).cgColor(in: self)
            layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        }
    }

    /// `sticky top-0 flex h-8 items-center gap-2 px-3 text-xs`: the file icon, name, folder and count.
    final class GroupHeader: DSView {
        let count: Int
        private let icon: IconView
        private let name: LabelView
        private let folder: LabelView
        private let badge: LabelView

        init(path: String, count: Int) {
            self.count = count
            let cut = path.lastIndex(of: "/")
            let fileName = cut.map { String(path[path.index(after: $0)...]) } ?? path
            let directory = cut.map { String(path[..<$0]) } ?? ""
            icon = FileTypeIcon.view(for: path, size: 14)
            name = LabelView(fileName, font: DSFont.ui(12, weight: .medium))
            folder = LabelView(directory, font: DSFont.ui(12))
            badge = LabelView("\(count)", font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular))
            super.init(frame: .zero)
            [name, folder].forEach { $0.lineHeight = 16 }
            badge.lineHeight = 14
            badge.alignment = .center
            badge.layer?.cornerRadius = 8
            [icon, name, folder, badge].forEach(addSubview)
        }

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 12, y: 9, width: 14, height: 14)
            let bw = ceil(badge.textWidth) + 12
            badge.frame = NSRect(x: bounds.width - 12 - bw, y: 8, width: bw, height: 16)
            let nw = min(ceil(name.textWidth), bounds.width - 34 - bw - 24)
            name.frame = NSRect(x: 34, y: 8, width: max(0, nw), height: 16)
            let fx = 34 + nw + 8
            folder.frame = NSRect(x: fx, y: 8, width: max(0, badge.frame.minX - 8 - fx), height: 16)
        }

        override func updateLayer() {
            layer?.backgroundColor = Themed.color(\.popover, 0.95).cgColor(in: self)
            name.color = Themed.color(\.foreground)
            folder.color = Themed.color(\.mutedForeground)
            badge.color = Themed.color(\.mutedForeground)
            badge.layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        }
    }

    /// `flex h-7 items-center gap-3 px-3 font-mono text-xs`: the line number (`w-10 text-right`,
    /// muted/70) and the line, `bg-accent` when selected.
    final class MatchRow: DSView {
        let index: Int
        private let number: LabelView
        private let line: CodeLineView
        var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
        var isEnabled = true
        var onHover: (@MainActor () -> Void)?
        var onClick: (@MainActor () -> Void)?
        private var tracking: NSTrackingArea?

        init(match: ProjectContentMatch, index: Int) {
            self.index = index
            number = LabelView("\(match.lineNumber)", font: DSFont.mono(12))
            line = CodeLineView(match: match)
            super.init(frame: .zero)
            number.lineHeight = 16
            number.alignment = .right
            [number, line].forEach(addSubview)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(match.path):\(match.lineNumber) \(match.lineContent)")
        }

        override func layout() {
            super.layout()
            number.frame = NSRect(x: 12, y: 6, width: 40, height: 16)
            line.frame = NSRect(x: 12 + 40 + 12, y: 6, width: max(0, bounds.width - 76), height: 16)
        }

        override func updateLayer() {
            layer?.backgroundColor = isSelected ? Themed.color(\.accent).cgColor(in: self) : nil
            number.color = Themed.color(\.mutedForeground, 0.7)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { onHover?() }
        override func mouseUp(with event: NSEvent) { if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    }

    /// `HighlightedSearchLine`: the line's tokens in the pierre colors, matches under a
    /// `rounded-xs bg-primary/25` mark, one line truncated at the end.
    final class CodeLineView: DSView {
        let match: ProjectContentMatch
        private let tokens: [CodeToken]
        override var wantsUpdateLayer: Bool { false }

        init(match: ProjectContentMatch) {
            self.match = match
            tokens = CodeHighlighter.tokens(match.lineContent, language: UnifiedDiff.language(forPath: match.path))
            super.init(frame: .zero)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let font = DSFont.mono(12)
            let text = match.lineContent
            let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: CodeTokenKind.plain.color])
            for t in tokens where t.range.location + t.range.length <= string.length {
                string.addAttribute(.foregroundColor, value: t.kind.color, range: t.range)
            }
            let resolved = NSMutableAttributedString(attributedString: string)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, range, _ in
                    if let c = value as? NSColor { resolved.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: c.cgColor, range: range) }
                }
            }
            let metrics = TextLine(resolved)
            var line = metrics.line
            if metrics.width > bounds.width {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [.font: font]))
                line = CTLineCreateTruncatedLine(line, Double(bounds.width), .end, ellipsis) ?? line
            }
            let baseline = metrics.baseline(top: 0, lineHeight: bounds.height)
            // The inline `<mark>` paints the font's content area, its metrics rounded to device pixels as Blink does.
            let ascent = (font.ascender * 2).rounded() / 2, descent = (-font.descender * 2).rounded() / 2
            ctx.saveGState()
            ctx.setFillColor(Themed.color(\.primary, 0.25).cgColor(in: self))
            for r in match.normalizedRanges {
                let x0 = CTLineGetOffsetForStringIndex(line, r.start, nil)
                let x1 = CTLineGetOffsetForStringIndex(line, r.end, nil)
                guard x1 > x0 else { continue }
                ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: baseline - ascent, width: x1 - x0, height: ascent + descent),
                                   cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.fillPath()
            }
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}
