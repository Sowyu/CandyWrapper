import AppKit
import DesignSystem

/// The paged plain viewer for a file past `FULL_TEXT_MAX_BYTES` (64 MB), which T3 5258 shows instead of the 1 MB
/// preview (LargeFilePreview.tsx:38-41, LargeTextViewer.tsx, VirtualTablePreview.tsx in `source` mode).
///
/// The owner downloads the file to a temporary file the view then owns and deletes. A background task indexes its
/// line starts; until then the 1 MB preview's first lines show. Only the rows on screen are read, 32 at a time
/// (`PREVIEW_PAGE_ROWS`), and at most 12 pages stay in memory.
///
/// The status bar (`min-h-10 border-b px-3 py-2 text-xs text-muted-foreground`) says "N lines · size" once indexing
/// ends; a muted spinner sits at the bottom right until then. Rows are `min-h-[29px] font-mono text-xs`: a 56pt
/// gutter (`border-r px-2 py-1.5 text-right text-muted-foreground`), then the line at `px-3 py-1`.
// ponytail: no word wrap and no horizontal scroll, lines clip at the pane's edge; add both when someone reads >64 MB files with long lines
public final class LargeTextFileView: DSView {
    public static let rowHeight: CGFloat = 29
    public static let gutterWidth: CGFloat = 56
    static let pageRows = 32

    private let file: URL?
    private let sizeBytes: Int
    private let status = LabelView("", font: DSFont.ui(12))
    private let statusBorder = CALayer()
    private let scroll = NSScrollView()
    private let rows = Rows()
    private var spinner: SpinnerView?
    private var failure: LabelView?
    private var indexTask: Task<Void, Never>?
    private var handle: FileHandle?
    private var index: LargeTextIndex?
    /// The preview's first lines, shown while the index builds.
    private let previewLines: [String]
    private var pages: [Int: [String]] = [:]
    private var pageOrder: [Int] = []

    /// A nil `file` is one past `LargeTextIndex.maxBytes`, which shows T3's limit instead of downloading.
    public init(file: URL?, sizeBytes: Int, preview: String) {
        self.file = file
        self.sizeBytes = sizeBytes
        var lines = preview.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        // The 1 MB read ends inside a line.
        if lines.count > 1 { lines.removeLast() }
        previewLines = Array(lines.prefix(Self.pageRows * 2))
        super.init(frame: .zero)
        status.lineHeight = 16
        status.setAccessibilityRole(.staticText)
        layer?.addSublayer(statusBorder)
        addSubview(status)
        rows.owner = self
        scroll.documentView = rows
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.useT3Scrollbars(.native, vertical: true, horizontal: false)
        addSubview(scroll)
        let s = SpinnerView(size: .md, tone: .muted)
        addSubview(s)
        spinner = s
        rows.count = previewLines.count
        if file == nil { indexed(.failure(LargeTextIndex.Failure.tooLarge)) } else { startIndexing() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        indexTask?.cancel()
        try? handle?.close()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func startIndexing() {
        guard let file else { return }
        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try LargeTextIndex.build(file) }
            await MainActor.run { [weak self] in self?.indexed(result) }
        }
    }

    private func indexed(_ result: Result<LargeTextIndex, Error>) {
        spinner?.removeFromSuperview()
        spinner = nil
        switch result {
        case .success(let index):
            self.index = index
            handle = file.flatMap { try? FileHandle(forReadingFrom: $0) }
            pages = [:]
            pageOrder = []
            rows.count = index.count
            if index.count == 0 { showFailure("This file is empty.", muted: true) }
            let lines = index.count == 1 ? "1 line" : "\(index.count.formatted()) lines"
            status.text = "\(lines) · \(index.size == 0 ? "0 bytes" : ComposerFileRow.formatSize(index.size))"
        case .failure(let error):
            if error is CancellationError { return }
            showFailure((error as? LargeTextIndex.Failure ?? .unreadable).message, muted: false)
        }
        rows.needsDisplay = true
        needsLayout = true
    }

    private func showFailure(_ text: String, muted: Bool) {
        let l = LabelView(text, font: DSFont.ui(12), color: muted ? Themed.color(\.mutedForeground) : Themed.color(\.destructive))
        l.alignment = .center
        addSubview(l)
        failure = l
        if !muted { scroll.isHidden = true }
    }

    /// Line `i`, read with its page.
    func line(_ i: Int) -> String {
        guard let index, let handle else { return i < previewLines.count ? previewLines[i] : "" }
        let page = i / Self.pageRows
        if let cached = pages[page] { return cached[i - page * Self.pageRows] }
        let first = page * Self.pageRows, last = min(index.count, first + Self.pageRows) - 1
        let start = index.range(of: first).lowerBound, end = index.range(of: last).upperBound
        var lines: [String] = []
        if (try? handle.seek(toOffset: UInt64(start))) != nil, let data = try? handle.read(upToCount: end - start) {
            for j in first...last {
                let r = index.range(of: j)
                lines.append(LargeTextIndex.line(data.subdata(in: (r.lowerBound - start)..<min(data.count, r.upperBound - start))))
            }
        }
        while lines.count < last - first + 1 { lines.append("") }
        pages[page] = lines
        pageOrder.append(page)
        if pageOrder.count > 12 { pages[pageOrder.removeFirst()] = nil }
        return lines[i - first]
    }

    /// Copy contents: the whole file once indexed (`copy` in largeText.worker.ts).
    public func copyText() -> Result<String, LargeTextIndex.Failure> {
        guard index != nil, let file, let data = try? Data(contentsOf: file) else {
            return .failure(.unreadable)
        }
        return .success(String(decoding: data, as: UTF8.self))
    }
    public var isIndexed: Bool { index != nil }

    public override func layout() {
        super.layout()
        let w = bounds.width
        status.frame = NSRect(x: 12, y: 12, width: max(0, w - 24), height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        statusBorder.frame = CGRect(x: 0, y: 39, width: w, height: 1)
        CATransaction.commit()
        scroll.frame = NSRect(x: 0, y: 40, width: w, height: max(0, bounds.height - 40))
        rows.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(rows.count) * Self.rowHeight))
        // `absolute right-4 bottom-3`.
        spinner?.frame = NSRect(x: w - 16 - 16, y: bounds.height - 12 - 16, width: 16, height: 16)
        failure?.frame = NSRect(x: 24, y: 40 + 24, width: max(0, w - 48), height: 16)
    }

    public override func updateLayer() {
        statusBorder.backgroundColor = Themed.color(\.contrastBorder, 0.6).cgColor(in: self)
        status.color = Themed.color(\.mutedForeground)
    }

    /// The scrolled rows: draws only the dirty rect's rows.
    final class Rows: NSView {
        weak var owner: LargeTextFileView?
        var count = 0 { didSet { if count != oldValue { owner?.needsLayout = true; needsDisplay = true } } }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let owner, count > 0 else { return }
            let h = LargeTextFileView.rowHeight, gutter = LargeTextFileView.gutterWidth
            let first = max(0, Int(dirtyRect.minY / h)), last = min(count - 1, Int(dirtyRect.maxY / h))
            guard first <= last else { return }
            // Dynamic colors resolve against this view's appearance while it draws.
            let colors = (bg: Themed.color(\.background), border: Themed.color(\.contrastBorder),
                          muted: Themed.color(\.mutedForeground), fg: Themed.color(\.foreground))
            let font = DSFont.mono(12)
            let numberStyle = NSMutableParagraphStyle()
            numberStyle.alignment = .right
            let textStyle = NSMutableParagraphStyle()
            textStyle.lineBreakMode = .byClipping
            // Every pass paints over the last; text drawn on itself would thicken.
            colors.bg.setFill()
            dirtyRect.fill()
            colors.border.setFill()
            NSRect(x: gutter - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
            for i in first...last {
                let y = CGFloat(i) * h
                // `px-2 py-1.5` in the gutter, `px-3 py-1` for the text, 16pt lines.
                ("\(i + 1)" as NSString).draw(in: NSRect(x: 8, y: y + 6, width: gutter - 17, height: 16), withAttributes: [
                    .font: font, .foregroundColor: colors.muted, .paragraphStyle: numberStyle])
                let text = owner.line(i)
                (String(text.prefix(4096)) as NSString).draw(in: NSRect(x: gutter + 12, y: y + 4, width: max(0, bounds.width - gutter - 24), height: 16),
                                                            withAttributes: [.font: font, .foregroundColor: colors.fg, .paragraphStyle: textStyle])
            }
        }
    }
}
