import AppKit
import DesignSystem

/// `ThreadLinkPicker` (4928 ThreadLinkPicker.tsx:13-87): a search over an environment's unarchived threads, to link
/// one to a pull request or an issue from their pages. It sits in `DialogPopup className="max-w-md"` with no close
/// button and a screen-reader title (PullRequestThreadLinks.tsx:205-224, IssueThreadLinks.tsx). `Command` keeps the
/// first enabled row highlighted; Up and Down move it, Return picks it, Escape closes the dialog.
public final class ThreadLinkPicker: DSView {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var title: String
        public var project: String?
        public var linked: Bool
        public init(id: String, title: String, project: String?, linked: Bool) {
            self.id = id; self.title = title; self.project = project; self.linked = linked
        }
    }

    /// The dialog around the picker, to hand to `ModalHost.present`.
    public let dialog: DialogView
    public let input = InputView(placeholder: "Search threads or projects...", size: .lg)
    private let searchIcon = IconView(name: .search)
    private let document = DSView()
    private let scroll: ScrollAreaView
    private let empty = LabelView("No active threads found.", font: DSFont.ui(14))
    private var rows: [Row] = []
    /// Candidates newest first (`updatedAt` descending); the picker filters them as the query changes.
    public var candidates: [Candidate] = [] { didSet { refilter() } }
    public var pending = false { didSet { input.isEnabled = !pending; rows.forEach { $0.pending = pending } } }
    public var onSelect: ((String) -> Void)?
    private(set) var shown: [Candidate] = []
    private var highlighted: Int?

    /// `title` is the dialog's screen-reader title, "Link pull request to a thread".
    public init(title: String) {
        dialog = DialogView(kind: .dialog, title: title)
        scroll = ScrollAreaView(documentView: document, scrollbars: .native)
        super.init(frame: .zero)
        dialog.showsCloseButton = false
        dialog.maxWidth = 448
        input.unstyled = true
        input.paddingOverride = (32, 11)
        searchIcon.alphaValue = 0.8
        empty.lineHeight = 20
        empty.alignment = .center
        [input, searchIcon, scroll, empty].forEach(addSubview)
        input.onChange = { [weak self] _ in self?.refilter() }
        input.onCommand = { [weak self] selector in self?.handle(selector) ?? false }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Choose a thread")
        dialog.fillContent = self
        refilter()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `${title} ${project}` holds the query, ignoring case in the user's locale or accents
    /// (`threadLinkMatcher`, ThreadLinkPicker.logic.ts at 5258, #39557): "cafe" finds "Café".
    static func filter(_ candidates: [Candidate], query: String, locale: Locale = .current) -> [Candidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: locale)
        guard !q.isEmpty else { return candidates }
        let folded = normalizeSearchText(query)
        return candidates.filter {
            let text = "\($0.title) \($0.project ?? "")"
            return text.lowercased(with: locale).contains(q) || normalizeSearchText(text).contains(folded)
        }
    }

    /// `normalizeSearchText` (lib/utils.ts:29-31): NFKD without combining marks, lowercased, spaces collapsed.
    static func normalizeSearchText(_ value: String) -> String {
        let stripped = String(String.UnicodeScalarView(value.decomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            ![.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory)
        }))
        return stripped.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func refilter() {
        shown = Self.filter(candidates, query: input.text)
        rows.forEach { $0.removeFromSuperview() }
        rows = shown.map { c in
            let r = Row(c)
            r.pending = pending
            r.onClick = { [weak self] in self?.pick(c) }
            r.onHover = { [weak self, weak r] in
                guard let self, let r, let i = self.rows.firstIndex(where: { $0 === r }), !c.linked else { return }
                self.setHighlight(i)
            }
            document.addSubview(r)
            return r
        }
        setHighlight(shown.firstIndex { !$0.linked })
        empty.isHidden = !shown.isEmpty
        dialog.fillHeight = contentHeight
        needsLayout = true
    }

    /// The input row (`py-1.5` around a 36pt input), then `p-2` around 48pt rows up to `max-h-80`, or the
    /// empty line in `py-6`.
    var contentHeight: CGFloat { 48 + (shown.isEmpty ? 68 : min(320, 16 + CGFloat(shown.count) * 48)) }

    private func setHighlight(_ i: Int?) {
        highlighted = i
        for (j, r) in rows.enumerated() { r.isHighlighted = j == i }
    }

    private func pick(_ c: Candidate) {
        guard !pending, !c.linked else { return }
        onSelect?(c.id)
    }

    private func handle(_ selector: Selector) -> Bool {
        let enabled = shown.indices.filter { !shown[$0].linked }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !enabled.isEmpty else { return true }
            let down = selector == #selector(NSResponder.moveDown(_:))
            let at = highlighted.flatMap { enabled.firstIndex(of: $0) }
            let next = at.map { down ? min($0 + 1, enabled.count - 1) : max($0 - 1, 0) } ?? (down ? 0 : enabled.count - 1)
            setHighlight(enabled[next])
            let r = rows[enabled[next]]
            document.scrollToVisible(r.frame.insetBy(dx: 0, dy: -8))
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let h = highlighted { pick(shown[h]) }
            return true
        default:
            return false
        }
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        // CommandInput: `--command-shell-inset` 8 inline, `py-1.5`; the input keeps its invisible 1pt border.
        input.frame = NSRect(x: 8 + 1, y: 6 + 1, width: w - 18, height: 34)
        searchIcon.frame = NSRect(x: 8 + 1 + 9, y: 6 + 10, width: 16, height: 16)
        scroll.frame = NSRect(x: 0, y: 48, width: w, height: max(0, bounds.height - 48))
        let docHeight = shown.isEmpty ? 0 : 16 + CGFloat(rows.count) * 48
        document.frame = NSRect(x: 0, y: 0, width: w, height: max(docHeight, scroll.frame.height))
        for (i, r) in rows.enumerated() { r.frame = NSRect(x: 8, y: 8 + CGFloat(i) * 48, width: w - 16, height: 48) }
        empty.frame = NSRect(x: 12, y: 48 + 24, width: max(0, w - 24), height: 20)
    }

    public override func updateLayer() {
        searchIcon.strokeColor = Themed.color(\.contrastIconMuted)
        empty.color = Themed.color(\.mutedForeground)
    }

    /// `CommandItem` with a 16pt message glyph, the title over the project, and "Linked" with a check.
    final class Row: DSView {
        let candidate: ThreadLinkPicker.Candidate
        private let icon = IconView(name: .messageSquare, size: 16)
        private let title = LabelView("", font: DSFont.ui(14))
        private let project = LabelView("", font: DSFont.ui(12))
        private let check = IconView(name: .check, size: 14)
        private let linkedLabel = LabelView("Linked", font: DSFont.ui(12))
        private var tracking: NSTrackingArea?
        var onClick: (() -> Void)?
        var onHover: (() -> Void)?
        var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true; restyleNow() } } }
        var pending = false { didSet { alphaValue = candidate.linked || pending ? 0.64 : 1 } }

        init(_ c: ThreadLinkPicker.Candidate) {
            candidate = c
            super.init(frame: .zero)
            title.text = c.title.isEmpty ? "Untitled thread" : c.title
            title.lineHeight = 20
            project.text = c.project ?? ""
            project.lineHeight = 16
            linkedLabel.lineHeight = 16
            [icon, title, project].forEach(addSubview)
            if c.linked { [check, linkedLabel].forEach(addSubview) }
            alphaValue = c.linked ? 0.64 : 1
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(title.text + (c.project.map { ", \($0)" } ?? "") + (c.linked ? ", Linked" : ""))
            setAccessibilityEnabled(!c.linked)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func accessibilityPerformPress() -> Bool { onClick?(); return true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            tracking.map(removeTrackingArea)
            let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        }
        override func mouseEntered(with event: NSEvent) { onHover?() }
        override func mouseMoved(with event: NSEvent) { onHover?() }

        override func layout() {
            super.layout()
            var right = bounds.width - 8
            if candidate.linked {
                let lw = ceil(linkedLabel.textWidth)
                linkedLabel.frame = NSRect(x: right - lw, y: (bounds.height - 16) / 2, width: lw, height: 16)
                right -= lw + 8
                check.frame = NSRect(x: right - 14, y: (bounds.height - 14) / 2, width: 14, height: 14)
                right -= 14 + 8
            }
            icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
            title.frame = NSRect(x: 32, y: 6, width: max(0, right - 32), height: 20)
            project.frame = NSRect(x: 32, y: 26, width: max(0, right - 32), height: 16)
        }

        private func restyleNow() { needsDisplay = true; updateLayer() }

        override func updateLayer() {
            layer?.cornerRadius = DesignGeometry.radius(6, in: self)
            layer?.backgroundColor = isHighlighted ? Themed.color(\.foreground, 0.09).cgColor(in: self) : nil
            icon.strokeColor = Themed.color(\.mutedForeground)
            title.color = Themed.color(isHighlighted ? \.foreground : \.popoverForeground)
            project.color = Themed.color(\.mutedForeground)
            check.strokeColor = Themed.color(\.mutedForeground)
            linkedLabel.color = Themed.color(\.mutedForeground)
        }
    }
}
