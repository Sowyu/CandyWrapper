import AppKit
import DesignSystem

/// Markdown past the 1 MB read (ChunkedMarkdown.tsx at 5258, fb4558d77d #40631). One `MarkdownView` over a 1.25 MB
/// file held the main thread for about 8 s, so the file is cut into pieces (`MarkdownChunks`) off the main thread and
/// only the pieces within 800pt of the viewport (`drawDistance`) hold a view. A piece starts at an estimated height and
/// takes its real one once laid out; pieces above the viewport that change height move the scroll with them, so the
/// text in view stays put.
// ponytail: Select All and copy reach only the pieces that hold a view; T3 copies the whole file from the list. Add a
// copy handler that joins `chunks` when someone copies a whole large file from here.
final class ChunkedMarkdownFileView: NSView {
    /// Rendered Markdown measured about 22 px per source line (largeTextProtocol.ts:6-8).
    static let estimatedLine: CGFloat = 22
    static let drawDistance: CGFloat = 800
    /// `py-5` around the list and `pb-5` under each piece.
    static let gap: CGFloat = 20

    let scroll = NSScrollView()
    private let document = FlippedFileView()
    private let cwd: String?
    private let imageBase: String?
    private(set) var chunks: [MarkdownChunks.Chunk] = []
    private var definitions = ""
    private var heights: [CGFloat] = []
    /// The width each height was measured at; 0 while it is an estimate.
    private var measuredWidth: [CGFloat] = []
    private(set) var live: [Int: NSView] = [:]
    private var tiling = false
    private let spinner = SpinnerView(size: .lg, tone: .muted)
    /// Set once the pieces are in, for tests.
    var onReady: (() -> Void)?

    init(markdown text: String, cwd: String?, imageBase: String? = nil) {
        self.cwd = cwd
        self.imageBase = imageBase
        super.init(frame: .zero)
        scroll.documentView = document
        scroll.useT3Scrollbars(.overlay)
        scroll.drawsBackground = false
        addSubview(scroll)
        addSubview(spinner)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        Task { [weak self] in
            let split = await Task.detached(priority: .userInitiated) { MarkdownChunks.split(text) }.value
            guard let self else { return }
            self.chunks = split.chunks
            self.definitions = split.definitions
            self.heights = split.chunks.map { CGFloat(max(1, $0.lines)) * Self.estimatedLine }
            self.measuredWidth = Array(repeating: 0, count: split.chunks.count)
            self.spinner.isHidden = true
            self.needsLayout = true
            self.onReady?()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clipMoved() { tile() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        spinner.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        tile()
    }

    /// `mx-auto max-w-4xl px-6`, as `MarkdownFileView` lays out a whole file.
    private var column: (x: CGFloat, width: CGFloat) {
        let width = min(896, bounds.width)
        return ((bounds.width - width) / 2 + 24, max(0, width - 48))
    }

    func tile() {
        guard !tiling, !chunks.isEmpty, bounds.width > 0 else { return }
        tiling = true
        defer { tiling = false }
        let (x, width) = column
        let clip = scroll.contentView
        var top = clip.bounds.minY
        let low = top - Self.drawDistance, high = clip.bounds.maxY + Self.drawDistance
        var wanted = Set<Int>()
        var changed = false
        var y = Self.gap
        for i in chunks.indices {
            if y + heights[i] + Self.gap >= low, y <= high {
                wanted.insert(i)
                let view = live[i] ?? makeView(i)
                if measuredWidth[i] != width {
                    let real = measure(view, i, width: width)
                    // A piece wholly above the viewport that grows or shrinks moves the scroll with it.
                    if y + heights[i] <= top { top += real - heights[i] }
                    if real != heights[i] { changed = true }
                    heights[i] = real
                    measuredWidth[i] = width
                }
                view.frame = NSRect(x: x, y: y, width: width, height: heights[i])
            }
            y += heights[i] + Self.gap
        }
        for (i, view) in live where !wanted.contains(i) { view.removeFromSuperview(); live[i] = nil }
        let size = NSSize(width: bounds.width, height: max(bounds.height, y))
        if document.frame.size != size { document.frame = NSRect(origin: .zero, size: size) }
        if top != clip.bounds.minY {
            clip.scroll(to: NSPoint(x: 0, y: max(0, min(top, size.height - clip.bounds.height))))
            scroll.reflectScrolledClipView(clip)
        }
        // Heights that changed move the pieces below; one more pass places them.
        if changed { DispatchQueue.main.async { [weak self] in self?.tile() } }
    }

    private func makeView(_ i: Int) -> NSView {
        let chunk = chunks[i]
        let view: NSView
        if chunk.text.utf16.count > MarkdownChunks.largeChunkMaxChars {
            // One block this long (a huge fence or HTML block) is too slow to parse: its source, unwrapped.
            let pre = NSTextField(labelWithString: chunk.text)
            pre.font = DSFont.mono(12)
            pre.textColor = Themed.color(\.foreground)
            pre.lineBreakMode = .byClipping
            pre.maximumNumberOfLines = 0
            view = pre
        } else {
            let markdown = MarkdownView()
            markdown.cwd = cwd
            markdown.imageBaseDir = imageBase
            let text = i == 0 ? MarkdownFrontmatter.mask(chunk.text) : chunk.text
            markdown.setMarkdown(MarkdownChunks.withDefinitions(text, definitions))
            view = markdown
        }
        document.addSubview(view)
        live[i] = view
        return view
    }

    private func measure(_ view: NSView, _ i: Int, width: CGFloat) -> CGFloat {
        if let markdown = view as? MarkdownView { return markdown.height(forWidth: width) }
        return CGFloat(chunks[i].lines) * 16
    }
}
