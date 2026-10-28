import AppKit
import AVKit
import DesignSystem
import PDFKit
import T3Protocol
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

    public var attachmentMode = false { didSet { updateActions() } }

    /// `AttachmentFilePreview`'s own header (AttachmentFilePreview.tsx:284-349): `origin › name size` crumbs,
    /// then Copy, Save, Remove and Close beside the render and wrap toggles. `inline` is the right panel's
    /// `h-7 mb-3` row; otherwise the dialog's `h-10 border-b border-border/60`.
    public struct AttachmentChrome {
        public var origin: String
        public var name: String
        public var sizeBytes: Int
        public var inline: Bool
        public var onSave: (@MainActor () -> Void)?
        public var onRemove: (@MainActor () -> Void)?
        public var onClose: (@MainActor () -> Void)?
        public init(origin: String = "Attachment", name: String, sizeBytes: Int, inline: Bool,
                    onSave: (@MainActor () -> Void)? = nil, onRemove: (@MainActor () -> Void)? = nil, onClose: (@MainActor () -> Void)? = nil) {
            self.origin = origin; self.name = name; self.sizeBytes = sizeBytes; self.inline = inline
            self.onSave = onSave; self.onRemove = onRemove; self.onClose = onClose
        }
    }
    public var attachment: AttachmentChrome? {
        didSet {
            if attachment?.name != oldValue?.name { attachmentRendered = true }
            attachmentMode = attachment != nil
            attachmentCrumbs.set(attachment)
            crumbs.isHidden = attachment != nil
            attachmentCrumbs.isHidden = attachment == nil
            updateActions()
        }
    }
    public private(set) var path = ""
    public var projectName = "" { didSet { rebuildCrumbs() } }
    public var cwd: String?
    public private(set) var kind = FilePreviewKind.text
    public private(set) var content = Content.loading
    /// The explorer shown beside the file, owned by the right panel.
    public weak var explorer: FilesPanelView? { didSet { needsLayout = true } }

    public var onReviewComment: ((JSONValue) -> Void)?
    /// A file comment's Delete, by context id.
    public var onDeleteReviewComment: ((String) -> Void)?
    /// An edit moved a file comment: its record with the new lines.
    public var onUpdateReviewComment: ((JSONValue) -> Void)?
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
    private let attachmentCrumbs = AttachmentCrumbsView()
    private let copyButton = ButtonView(nil, icon: .copy, variant: .ghost, size: .iconSm)
    private let saveButton = ButtonView(nil, icon: .download, variant: .ghost, size: .iconSm)
    private let removeButton = ButtonView(nil, icon: .trash2, variant: .ghost, size: .iconSm)
    private let closeButton = ButtonView(nil, icon: .x, variant: .ghost, size: .iconSm)
    private let headerBorder = CALayer()
    private var copiedUntil: Date?
    private let noticeBar = CALayer()
    private let asideBorder = CALayer()

    // Bodies, made on demand and dropped when the mode changes.
    private var body: NSView?
    private var code: CodeFileView?
    /// The file the current code body's comments belong to.
    private var commentsPath: String?
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

    /// The `wordWrap` setting seeds the toggle when the surface opens.
    private func seedWrap() { wrap = ClientSettingsStore.shared.current.bool("wordWrap") }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for t in [renderToggle, wrapToggle, explorerToggle] { t.iconSize = 14 }
        renderToggle.onPressedChange = { [weak self] on in self?.setRendered(on) }
        wrapToggle.onPressedChange = { [weak self] on in self?.wrap = on }
        wrapToggle.setAccessibilityLabel("Disable word wrap")
        seedWrap()
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
        attachmentCrumbs.isHidden = true
        addSubview(attachmentCrumbs)
        for (b, label) in [(copyButton, "Copy contents"), (saveButton, "Save file"), (removeButton, "Remove from draft"), (closeButton, "Close")] {
            b.iconSize = 14
            b.isHidden = true
            b.setAccessibilityLabel(label)
            b.toolTip = label
            addSubview(b)
        }
        copyButton.action = { [weak self] in self?.copyContents() }
        saveButton.action = { [weak self] in self?.attachment?.onSave?() }
        removeButton.action = { [weak self] in self?.attachment?.onRemove?() }
        closeButton.action = { [weak self] in self?.attachment?.onClose?() }
        headerBorder.isHidden = true
        headerBorder.actions = ["frame": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(headerBorder)
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

    /// An attachment keeps its own toggle, rendered at first (`useState(true)`, AttachmentFilePreview.tsx:98).
    private var attachmentRendered = true

    private var rendered: Bool {
        // A reveal wins over the preference: the line only exists in the source.
        guard pendingReveal == nil else { return kind == .pdf }
        if attachment != nil {
            switch kind {
            case .markdown, .table, .html: return attachmentRendered
            case .pdf: return true
            default: return false
            }
        }
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
        if attachment != nil {
            attachmentRendered = on
            if kind == .html { onNeedsReload?() } else { rebuildBody() }
            return
        }
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
        // Sent comments stay on their lines when the same file reloads (T3 keeps `lineAnnotations` across an
        // external change, FilePreviewPanel.tsx:710-718).
        let keptComments = commentsPath == path ? code?.comments ?? [] : []
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
                if let attachment {
                    // AttachmentFilePreview.tsx:342-348.
                    notice.text = "Preview limited to the first 1 MB"
                        + (attachment.sizeBytes > 0 ? " of a \(attachment.sizeBytes.formatted()) byte file" : "") + ". Save the file to read it in full."
                } else {
                    notice.text = "Preview limited to the first 1 MB of a \(bytes.formatted()) byte file."
                }
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
                wireComments(code, editable: editable && !truncated)
                if !keptComments.isEmpty { code.restoreComments(keptComments) }
                commentsPath = path
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
                let data = await self?.fetchData?(url)
                // A cancelled or superseded load belongs to a file that is no longer shown (audit IMG-1).
                guard !Task.isCancelled, let self, self.body === host else { return }
                // Bytes that don't decode get T3's error, not a blank view (FilePreviewPanel.tsx:186-205, audit IMG-3).
                guard let data, let decoded = NSImage(data: data), decoded.isValid else {
                    self.replaceBody(host, with: FileFailureView(message: "Unable to load workspace image.", attemptedPath: nil, cwd: nil))
                    return
                }
                image.image = decoded
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
                let data = await self?.fetchData?(url)
                guard !Task.isCancelled, let self, self.body === pdf else { return }
                guard let data, let document = PDFDocument(data: data) else {
                    self.replaceBody(pdf, with: FileFailureView(message: "Unable to load file preview.", attemptedPath: nil, cwd: nil))
                    return
                }
                pdf.document = document
            }
            return pdf
        case .html:
            return HTMLFileView(url: url)
        default:
            return NativeFilePreviewView(source: url, name: path)
        }
    }

    private func replaceBody(_ expected: NSView, with view: NSView) {
        guard body === expected else { return }
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
        explorerToggle.isHidden = attachmentMode || path.hasPrefix("/") || isDirectory
        // Copy once text loaded, Save once there is a file, Remove and Close when the owner offers them.
        if case .text = content, attachment != nil { copyButton.isHidden = false } else { copyButton.isHidden = true }
        let copied = (copiedUntil ?? .distantPast) > Date()
        copyButton.icon = copied ? .check : .copy
        let copyLabel: String = {
            if copied { return "Copied" }
            if case .text(_, true, _, _) = content { return "Copy preview" }
            return "Copy contents"
        }()
        copyButton.setAccessibilityLabel(copyLabel)
        copyButton.toolTip = copyLabel
        saveButton.isHidden = attachment?.onSave == nil
        removeButton.isHidden = attachment?.onRemove == nil
        closeButton.isHidden = attachment?.onClose == nil
        let explorerLabel = explorerOpen ? "Hide file explorer" : "Show file explorer"
        explorerToggle.setAccessibilityLabel(explorerLabel)
        explorerToggle.toolTip = explorerLabel
        needsLayout = true
    }

    /// Inline comments on an editable file (`EditableFileSurface`, FilePreviewPanel.tsx:677-960): a sent comment
    /// becomes a review-comment record, Delete takes it out of the composer, and an edit that moves it rewrites
    /// its record (`handleEditChange`).
    private func wireComments(_ code: CodeFileView, editable: Bool) {
        code.commentsEnabled = editable && onReviewComment != nil && !attachmentMode
        let path = self.path
        code.onSubmitComment = { [weak self, weak code] c in
            guard let code else { return }
            self?.onReviewComment?(FileCommentContext.record(path: path, contents: code.text, startLine: c.startLine, endLine: c.endLine, text: c.text, id: c.id))
        }
        code.onDeleteComment = { [weak self] c in self?.onDeleteReviewComment?(ComposerContext.kindScopedId("review-comment", c.id)) }
        code.onCommentsMoved = { [weak self, weak code] moved in
            guard let code else { return }
            for c in moved {
                self?.onUpdateReviewComment?(FileCommentContext.record(path: path, contents: code.text, startLine: c.startLine, endLine: c.endLine, text: c.text, id: c.id))
            }
        }
    }

    private var isDirectory: Bool { if case .directory = content { true } else { false } }

    /// `useCopyToClipboard`: the button shows a check while "Copied".
    private func copyContents() {
        guard case .text(let text, _, _, _) = content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedUntil = Date().addingTimeInterval(2)
        updateActions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updateActions() }
    }

    /// Whether the explorer aside shows (`shouldShowFileExplorer`); a folder lets it fill the surface.
    public var showsExplorer: Bool { !attachmentMode && !path.hasPrefix("/") && (explorerOpen || isDirectory) }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let w = bounds.width
        // `FILE_SURFACE_SUBHEADER_CLASS` in the inline panel: h-7, px-3, gap-2, mb-3, no border; a dialog's
        // attachment header is h-10 with a bottom border and no margin.
        let dialogHeader = attachment.map { !$0.inline } ?? false
        let h: CGFloat = dialogHeader ? 40 : 28
        let buttonY = (h - 28) / 2
        var right = w - 12
        for t in [closeButton, removeButton, saveButton, copyButton, explorerToggle, wrapToggle, renderToggle] as [NSView] where !t.isHidden {
            t.frame = NSRect(x: right - 28, y: buttonY, width: 28, height: 28)
            right -= 28 + 8
        }
        crumbs.frame = NSRect(x: 12, y: 0, width: max(0, right - 12 + 8 - 8), height: h)
        attachmentCrumbs.frame = NSRect(x: 12, y: 0, width: max(0, right - 12), height: h)
        var top = h + (dialogHeader ? 0 : 12)
        headerBorder.isHidden = !dialogHeader
        headerBorder.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
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
        layer?.backgroundColor = WindowGlass.ground.cgColor(in: self)
        noticeBar.backgroundColor = Themed.color(\.warningSurface).cgColor(in: self)
        noticeBar.borderColor = Themed.color(\.warning, 0.2).cgColor(in: self)
        notice.color = Themed.color(\.warningForeground)
        asideBorder.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        headerBorder.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
    }

    public override func viewDidHide() {
        super.viewDidHide()
        // Media stops while the tab is hidden; HTMLFileView drops its web view itself.
        ((body as? Centered)?.child as? AVPlayerView)?.player?.pause()
    }
}

/// The attachment crumbs (`flex min-w-0 flex-1 items-center text-xs`): the origin (`px-0.5` muted), a 14pt
/// chevron (`mx-1` muted at 60%), the name (`font-medium` foreground, truncated) and the size (`ml-2` muted).
final class AttachmentCrumbsView: DSView {
    private let origin = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let chevron = IconView(name: .chevronRight, size: 14, strokeColor: Themed.color(\.mutedForeground, 0.6))
    private let name = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let size = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [origin, name, size] { l.lineHeight = 16 }
        name.truncates = true
        [origin, chevron, name, size].forEach(addSubview)
    }

    func set(_ chrome: FileSurfaceView.AttachmentChrome?) {
        origin.text = chrome?.origin ?? ""
        name.text = chrome?.name ?? ""
        size.text = chrome.map { $0.sizeBytes > 0 ? ComposerFileRow.formatSize($0.sizeBytes) : "" } ?? ""
        size.isHidden = size.text.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = ((bounds.height - 16) / 2).rounded()
        let ow = ceil(origin.textWidth)
        origin.frame = NSRect(x: 2, y: y, width: ow, height: 16)
        chevron.frame = NSRect(x: origin.frame.maxX + 2 + 4, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14)
        let sw = size.isHidden ? 0 : ceil(size.textWidth)
        let nameX = chevron.frame.maxX + 4 + 2
        let nameW = max(0, min(ceil(name.textWidth), bounds.width - nameX - 2 - (sw > 0 ? 8 + sw : 0)))
        name.frame = NSRect(x: nameX, y: y, width: nameW, height: 16)
        size.frame = NSRect(x: name.frame.maxX + 2 + 8, y: y, width: sw, height: 16)
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
        markdown.setMarkdown(MarkdownFrontmatter.mask(text))
        document.addSubview(markdown)
        scroll.documentView = document
        scroll.useT3Scrollbars(.overlay) // a ScrollArea (FilePreviewPanel.tsx:989)
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


/// A workspace HTML file in T3's sandboxed frame (BrowserDocumentFrame.tsx:53-59), hosted by `ThreadWebFrameView`
/// as `.workspaceFile`: opaque origin, no bridge, no navigation out of the frame, clicked http(s) links open in the
/// browser. The web view exists only while this view is visible; hiding or leaving tears it and its content process down.
// ponytail: `allow-downloads` is set but WKWebView downloads are not handled, so download links do nothing; add a WKDownloadDelegate when someone needs them.
final class HTMLFileView: NSView {
    let url: URL
    let frameView = ThreadWebFrameView()
    var web: WKWebView? { frameView.webView }
    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        frameView.autoresizingMask = [.width, .height]
        addSubview(frameView)
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
        frameView.frame = bounds
        if visible, !frameView.isLive {
            frameView.activate(.init(src: url, title: url.lastPathComponent, dark: effectiveAppearance.isDark, kind: .workspaceFile))
        } else if !visible {
            frameView.release()
        }
    }
}

final class FlippedFileView: NSView {
    override var isFlipped: Bool { true }
}
