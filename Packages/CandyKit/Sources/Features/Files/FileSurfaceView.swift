import AppKit
import AVKit
import DesignSystem
import PDFKit
import WebKit

/// One file tab (FilePreviewPanel.tsx): the subheader with breadcrumbs and icon actions, the body
/// for the file's preview mode, and the explorer aside on the right (`w-[min(22rem,46%)] min-w-64
/// border-l border-border/60`, shown by default, remembered in `t3code.fileExplorerOpen`).
///
/// The owner sets `path` and then `content` once the read or the asset URL arrives, and answers
/// `onEdit` (autosave), `onOpenFile` (breadcrumb picks) and `browseDirectory` (breadcrumb menus).
public final class FileSurfaceView: DSView {
    public enum Content {
        case loading
        /// The read file. `editable` is false for truncated reads and host files.
        case text(String, truncated: Bool, byteLength: Int, editable: Bool)
        /// A signed asset URL for media, PDFs and rendered HTML.
        case asset(URL)
        /// The read failed (`filePreviewReadErrorMessage`) with the attempted path.
        case failure(String, attemptedPath: String?, cwd: String?)
        /// A folder reached through a link: crumbs only, the tree fills the surface.
        case directory
    }

    public private(set) var path = ""
    public var projectName = "" { didSet { rebuildCrumbs() } }
    public var cwd: String?
    public private(set) var kind = FilePreviewKind.text
    public private(set) var content = Content.loading
    /// The explorer shown beside the file, owned by the right panel.
    public weak var explorer: FilesPanelView? { didSet { needsLayout = true } }

    public var onEdit: (@MainActor (String) -> Void)?
    public var onOpenFile: (@MainActor (String) -> Void)?
    /// Lists a folder for a breadcrumb menu.
    public var browseDirectory: ((String) async -> [ProjectEntry]?)?
    public var onExplorerChange: (@MainActor (Bool) -> Void)?
    /// Opens a file through a local fetch (images and PDFs are decoded here).
    public var fetchData: ((URL) async -> Data?)?

    // Chrome
    private let crumbs = FileBreadcrumbsView()
    private let renderToggle = ToggleView(nil, icon: .eye, variant: .ghost, size: .sm)
    private let wrapToggle = ToggleView(nil, icon: .textWrap, variant: .ghost, size: .sm, pressed: true)
    private let explorerToggle = ToggleView(nil, icon: .folderTree, variant: .ghost, size: .sm, pressed: true)
    private let notice = LabelView("", font: DSFont.ui(11))
    private let noticeBar = CALayer()
    private let asideBorder = CALayer()

    // Bodies, made on demand and dropped when the mode changes.
    private var body: NSView?
    private var code: CodeFileView?
    private var pendingReveal: Int?
    private var loadTask: Task<Void, Never>?

    static let explorerKey = "t3code.fileExplorerOpen"
    static let renderMarkdownKey = "t3code.renderMarkdown"
    static let renderTableKey = "t3code.renderTable"
    static let renderBrowserKey = "t3code.renderBrowserFile"

    public var explorerOpen: Bool {
        get { UserDefaults.standard.object(forKey: Self.explorerKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.explorerKey); explorerToggle.isPressed = newValue; needsLayout = true }
    }

    /// `wordWrap`, default on.
    public var wrap = true { didSet { wrapToggle.isPressed = wrap; code?.wrap = wrap } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for t in [renderToggle, wrapToggle, explorerToggle] { t.iconSize = 14 }
        renderToggle.onPressedChange = { [weak self] on in self?.setRendered(on) }
        wrapToggle.onPressedChange = { [weak self] on in self?.wrap = on }
        wrapToggle.setAccessibilityLabel("Disable word wrap")
        explorerToggle.onPressedChange = { [weak self] on in
            self?.explorerOpen = on
            self?.updateActions()
            self?.onExplorerChange?(on)
        }
        crumbs.onOpenFile = { [weak self] path in self?.onOpenFile?(path) }
        crumbs.browse = { [weak self] dir in await self?.browseDirectory?(dir) }
        notice.lineHeight = 15
        notice.isHidden = true
        noticeBar.isHidden = true
        for l in [noticeBar, asideBorder] { l.actions = ["frame": NSNull(), "hidden": NSNull()]; layer?.addSublayer(l) }
        [crumbs, renderToggle, wrapToggle, explorerToggle, notice].forEach(addSubview)
        explorerToggle.isPressed = explorerOpen
        clipsToBounds = true
    }

    // MARK: Data

    /// Shows `path`; `revealLine` scrolls to and marks that line once the text arrives.
    public func show(path: String, revealLine: Int?) {
        let changed = path != self.path
        self.path = path
        kind = FilePreviewKind.of(path)
        pendingReveal = revealLine
        rebuildCrumbs()
        if changed { setContent(.loading) } else if let line = revealLine { reveal(line) }
    }

    public func setContent(_ content: Content) {
        self.content = content
        rebuildBody()
    }

    /// The text the editor holds now (unsaved edits included).
    public var currentText: String? { code?.text }

    private var rendered: Bool {
        // A reveal wins over the preference: the line only exists in the source.
        guard pendingReveal == nil else { return kind == .pdf }
        switch kind {
        case .markdown: return UserDefaults.standard.object(forKey: Self.renderMarkdownKey) as? Bool ?? false
        case .table: return UserDefaults.standard.object(forKey: Self.renderTableKey) as? Bool ?? true
        case .html: return UserDefaults.standard.object(forKey: Self.renderBrowserKey) as? Bool ?? true
        case .pdf: return true
        default: return false
        }
    }

    /// Whether the current mode needs the asset URL rather than the text (the owner asks).
    public var wantsAsset: Bool { kind.isAsset || (kind == .html && rendered) }
    /// Called when the render toggle changes what the body needs.
    public var onNeedsReload: (@MainActor () -> Void)?

    private func setRendered(_ on: Bool) {
        let key: String? = switch kind {
        case .markdown: Self.renderMarkdownKey
        case .table: Self.renderTableKey
        case .html: Self.renderBrowserKey
        default: nil
        }
        guard let key else { return }
        UserDefaults.standard.set(on, forKey: key)
        pendingReveal = nil
        if kind == .html { onNeedsReload?() } else { rebuildBody() }
    }

    private func rebuildCrumbs() {
        crumbs.set(projectName: projectName, path: path)
        needsLayout = true
    }

    private func reveal(_ line: Int) {
        guard let code, case .text(let text, _, _, _) = content else { pendingReveal = line; rebuildBody(); return }
        code.reveal(line: clampFileLine(text, line))
        pendingReveal = nil
    }

    // MARK: Bodies

    private func rebuildBody() {
        loadTask?.cancel()
        body?.removeFromSuperview()
        body = nil
        code = nil
        notice.isHidden = true
        let view: NSView?
        switch content {
        case .loading:
            let spinner = SpinnerView(size: .lg, tone: .muted)
            view = Centered(spinner, size: NSSize(width: 20, height: 20))
        case .directory:
            view = nil
        case .failure(let message, let attempted, let cwd):
            view = FileFailureView(message: message, attemptedPath: attempted, cwd: cwd)
        case .text(let text, let truncated, let bytes, let editable):
            if truncated {
                notice.text = "Preview limited to the first 1 MB of a \(bytes.formatted()) byte file."
                notice.isHidden = false
            }
            if kind == .markdown, rendered {
                view = MarkdownFileView(markdown: text, cwd: cwd)
            } else if case .table(let d) = kind, rendered {
                let table = DelimitedTableView(text: text, delimiter: d)
                if table.truncated, notice.isHidden {
                    notice.text = "Table limited to the first 100 rows and 30 columns. Switch to source for the rest."
                    notice.isHidden = false
                }
                view = table
            } else {
                let code = CodeFileView()
                code.wrap = wrap
                code.setText(text, path: path)
                code.isEditable = editable
                code.onChange = { [weak self] text in self?.onEdit?(text) }
                self.code = code
                view = code
            }
        case .asset(let url):
            view = assetView(url)
        }
        if let view { addSubview(view); body = view }
        updateActions()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let line = pendingReveal, let code, case .text(let text, _, _, _) = content {
            code.reveal(line: clampFileLine(text, line))
            pendingReveal = nil
        }
    }

    private func assetView(_ url: URL) -> NSView {
        switch kind {
        case .image:
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityLabel(path)
            let host = Centered(image, size: nil, padding: 16)
            loadTask = Task { [weak self] in
                guard let data = await self?.fetchData?(url) else {
                    self?.replaceBody(with: FileFailureView(message: "Unable to load workspace image.", attemptedPath: nil, cwd: nil))
                    return
                }
                image.image = NSImage(data: data)
            }
            return host
        case .audio, .video:
            let player = AVPlayerView()
            player.player = AVPlayer(url: url)
            player.controlsStyle = kind == .audio ? .inline : .floating
            player.setAccessibilityLabel(path)
            return Centered(player, size: kind == .audio ? NSSize(width: 576, height: 54) : nil, padding: kind == .audio ? 24 : 16)
        case .pdf:
            let pdf = PDFView()
            pdf.autoScales = true
            pdf.displayMode = .singlePageContinuous
            pdf.backgroundColor = .white
            loadTask = Task { [weak self] in
                guard let data = await self?.fetchData?(url), let document = PDFDocument(data: data) else {
                    self?.replaceBody(with: FileFailureView(message: "Unable to load file preview.", attemptedPath: nil, cwd: nil))
                    return
                }
                pdf.document = document
            }
            return pdf
        default:
            return HTMLFileView(url: url)
        }
    }

    private func replaceBody(with view: NSView) {
        body?.removeFromSuperview()
        body = view
        addSubview(view)
        needsLayout = true
    }

    private func updateActions() {
        if let labels = kind.renderedToggle, !isDirectory {
            renderToggle.isHidden = false
            let on = rendered
            renderToggle.isPressed = on
            renderToggle.icon = on ? .code2 : (kind == .table(delimiter: ",") || kind == .table(delimiter: "\t")) ? .table2 : .eye
            renderToggle.iconSize = 14
            let label = on ? labels.rendered : labels.source
            renderToggle.setAccessibilityLabel(label)
            renderToggle.toolTip = label
        } else {
            renderToggle.isHidden = true
        }
        // Word wrap reaches only the text bodies.
        wrapToggle.isHidden = code == nil
        let wrapLabel = wrap ? "Disable word wrap" : "Enable word wrap"
        wrapToggle.setAccessibilityLabel(wrapLabel)
        wrapToggle.toolTip = wrapLabel
        explorerToggle.isHidden = path.hasPrefix("/") || isDirectory
        let explorerLabel = explorerOpen ? "Hide file explorer" : "Show file explorer"
        explorerToggle.setAccessibilityLabel(explorerLabel)
        explorerToggle.toolTip = explorerLabel
        needsLayout = true
    }

    private var isDirectory: Bool { if case .directory = content { true } else { false } }

    /// Whether the explorer aside shows (`shouldShowFileExplorer`); a folder lets it fill the surface.
    public var showsExplorer: Bool { !path.hasPrefix("/") && (explorerOpen || isDirectory) }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let w = bounds.width
        // `FILE_SURFACE_SUBHEADER_CLASS` in the inline panel: h-7, px-3, gap-2, mb-3, no border.
        let h: CGFloat = 28
        var right = w - 12
        for t in [explorerToggle, wrapToggle, renderToggle] where !t.isHidden {
            t.frame = NSRect(x: right - 28, y: 0, width: 28, height: 28)
            right -= 28 + 8
        }
        crumbs.frame = NSRect(x: 12, y: 0, width: max(0, right - 12 + 8 - 8), height: h)
        var top = h + 12
        noticeBar.isHidden = notice.isHidden
        if !notice.isHidden {
            noticeBar.frame = CGRect(x: 0, y: top, width: w, height: 15 + 12 + 1)
            notice.frame = NSRect(x: 12, y: top + 6, width: max(0, w - 24), height: 15)
            top += 28
        }
        let explorerVisible = showsExplorer && explorer != nil
        let asideWidth: CGFloat = isDirectory ? w : explorerVisible ? max(256, min(352, (w * 0.46).rounded(.down))) : 0
        let bodyWidth = max(0, w - asideWidth)
        body?.frame = NSRect(x: 0, y: top, width: bodyWidth, height: max(0, bounds.height - top))
        asideBorder.isHidden = !explorerVisible || isDirectory
        asideBorder.frame = CGRect(x: bodyWidth, y: top, width: 1, height: max(0, bounds.height - top))
        if explorerVisible, let explorer {
            if explorer.superview !== self { addSubview(explorer) }
            let x = isDirectory ? 0 : bodyWidth + 1
            explorer.frame = NSRect(x: x, y: top, width: max(0, w - x), height: max(0, bounds.height - top))
        } else if let explorer, explorer.superview === self {
            explorer.removeFromSuperview()
        }
    }

    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        noticeBar.backgroundColor = Themed.color(\.warningSurface).cgColor(in: self)
        noticeBar.borderColor = Themed.color(\.warning, 0.2).cgColor(in: self)
        notice.color = Themed.color(\.warningForeground)
        asideBorder.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
    }

    public override func viewDidHide() {
        super.viewDidHide()
        // Media stops while the tab is hidden; HTMLFileView drops its web view itself.
        ((body as? Centered)?.child as? AVPlayerView)?.player?.pause()
    }
}

/// A view centered in its box (`flex items-center justify-center`), optionally at a fixed size.
final class Centered: NSView {
    let child: NSView
    let size: NSSize?
    let padding: CGFloat
    init(_ child: NSView, size: NSSize?, padding: CGFloat = 0) {
        self.child = child; self.size = size; self.padding = padding
        super.init(frame: .zero)
        addSubview(child)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: padding, dy: padding)
        if let size {
            let s = NSSize(width: min(size.width, inner.width), height: min(size.height, inner.height))
            child.frame = NSRect(x: inner.midX - s.width / 2, y: inner.midY - s.height / 2, width: s.width, height: s.height)
        } else {
            child.frame = inner
        }
    }
}

/// The read failure (FilePreviewPanel.tsx:1390-1420): the message in red, the attempted path and
/// the workspace folder, centered.
final class FileFailureView: DSView {
    private let lines: [LabelView]
    init(message: String, attemptedPath: String?, cwd: String?) {
        var lines = [LabelView(message, font: DSFont.ui(12), color: Themed.color(\.destructive))]
        if let attemptedPath { lines.append(LabelView("Attempted path " + attemptedPath, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))) }
        if let cwd { lines.append(LabelView("Workspace folder: \(cwd). Check the link's path or locate the file in Files.", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))) }
        self.lines = lines
        super.init(frame: .zero)
        for l in lines { l.alignment = .center; l.lineHeight = 19.5; addSubview(l) }
        setAccessibilityRole(.staticText)
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let total = CGFloat(lines.count) * 19.5 + CGFloat(max(0, lines.count - 1)) * 12
        var y = (bounds.height - total) / 2
        for l in lines {
            l.frame = NSRect(x: 24, y: y, width: max(0, bounds.width - 48), height: 19.5)
            y += 19.5 + 12
        }
    }
}

/// Rendered Markdown (FileMarkdownPreview.tsx): ChatMarkdown in `mx-auto max-w-4xl px-6 py-5`.
final class MarkdownFileView: NSView {
    let scroll = NSScrollView()
    let markdown = MarkdownView()
    let document = FlippedFileView()
    init(markdown text: String, cwd: String?) {
        super.init(frame: .zero)
        markdown.cwd = cwd
        markdown.setMarkdown(text)
        document.addSubview(markdown)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = min(896, bounds.width)
        let inner = max(0, width - 48)
        let h = markdown.height(forWidth: inner)
        markdown.frame = NSRect(x: (bounds.width - width) / 2 + 24, y: 20, width: inner, height: h)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, h + 40))
    }
}


/// A sandboxed page for a workspace HTML file (BrowserDocumentFrame.tsx). The web view exists only
/// while this view is in a window; leaving it tears the view and its web content process down.
final class HTMLFileView: NSView {
    let url: URL
    private(set) var web: WKWebView?
    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sync()
    }

    override func viewDidHide() { super.viewDidHide(); sync() }
    override func viewDidUnhide() { super.viewDidUnhide(); sync() }

    private func sync() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        if visible, web == nil {
            let config = WKWebViewConfiguration()
            // A non-persistent store: nothing from the page outlives the tab.
            config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: bounds, configuration: config)
            web.autoresizingMask = [.width, .height]
            addSubview(web)
            web.load(URLRequest(url: url))
            self.web = web
        } else if !visible, let web {
            web.stopLoading()
            web.removeFromSuperview()
            self.web = nil
        }
    }
}

final class FlippedFileView: NSView {
    override var isFlipped: Bool { true }
}
