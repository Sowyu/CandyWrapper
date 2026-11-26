import AppKit
import DesignSystem

/// `AddTrackedFolderDialog`'s browse rules (5258 ProjectRepositoriesSettings.tsx:252-290, trackedFolders.logic.ts:21-42),
/// on the add-project flow's path helpers.
enum TrackedFolderBrowse {
    /// `BROWSE_SUGGESTION_LIMIT`.
    static let limit = 100

    /// `getFilesystemBrowsePath` on a POSIX server.
    struct Path: Equatable {
        var isBrowsing: Bool
        var directoryPath: String
        var filterQuery: String
        var parentPath: String?
    }

    static func path(_ query: String, canBrowse: Bool = true) -> Path {
        typealias P = PaletteAddProjectPaths
        let browsing = canBrowse && P.isBrowseQuery(query)
        let directory = browsing ? P.directoryPath(query) : ""
        return Path(isBrowsing: browsing, directoryPath: directory,
                    filterQuery: browsing && !P.hasTrailingSeparator(query) ? P.leafSegment(query) : "",
                    parentPath: browsing && P.canNavigateUp(directory) ? P.parentPath(directory) : nil)
    }

    /// The listing starts at the project folder's parent, where repositories beside it live.
    static func initialQuery(workspaceRoot: String) -> String {
        PaletteAddProjectPaths.parentPath(workspaceRoot) ?? PaletteAddProjectPaths.ensureDirectoryPath(workspaceRoot)
    }

    /// `resolveTrackedFolderInput`: the exact listed folder, the listed directory for a query ending in a separator,
    /// or a typed absolute path. The name is the last component, at most 128 characters.
    static func resolve(query raw: String, listedDirectory: String?, exactEntry: String?) -> (path: String, name: String)? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let candidate = exactEntry
            ?? (PaletteAddProjectPaths.hasTrailingSeparator(query) && listedDirectory != nil ? listedDirectory
                : query.hasPrefix("/") ? query : nil)
        guard let candidate else { return nil }
        let path = PaletteAddProjectPaths.normalizeForDispatch(candidate)
        let base = (path as NSString).lastPathComponent.drop { $0 == " " }
        let name = String(base.prefix(128)).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !name.isEmpty, name != "/" else { return nil }
        return (path, name)
    }
}

/// The folder list under the path field (ProjectRepositoriesSettings.tsx:333-368): `..`, then up to 100 subfolders,
/// then one status line. `-mx-2 flex min-h-40 flex-col`; rows `gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-muted/50`.
final class TrackedFolderBrowserView: DSView {
    enum Status: Equatable {
        case none
        case error(String)
        case loading
        case more(Int)
        case cannotBrowse

        var text: String? {
            switch self {
            case .none: nil
            case .error(let message): message
            case .loading: "Loading folders…"
            case .more(let count): "\(count) more. Keep typing to narrow the list."
            case .cannotBrowse: "This connection cannot browse folders. Enter an absolute path."
            }
        }
    }

    private var rows: [FolderBrowseRowView] = []
    private let status = LabelView("", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    private(set) var titles: [String] = []
    var onPick: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        status.lineHeight = 20
        addSubview(status)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `titles` are the rows in order, `..` first when there is a parent; a click reports the row's index.
    func set(titles: [String], status next: Status) {
        self.titles = titles
        while rows.count > titles.count { rows.removeLast().removeFromSuperview() }
        while rows.count < titles.count {
            let row = FolderBrowseRowView()
            let index = rows.count
            row.action = { [weak self] in self?.onPick?(index) }
            rows.append(row)
            addSubview(row)
        }
        for (row, title) in zip(rows, titles) { row.title = title }
        status.text = next.text ?? ""
        // `.more` is `text-xs`; the others are `text-sm`.
        statusLine = { if case .more = next { 16 } else { 20 } }()
        status.font = DSFont.ui(statusLine == 16 ? 12 : 14)
        status.lineHeight = statusLine
        status.isHidden = next.text == nil
        if case .error = next { status.setAccessibilityRole(.staticText) }
        needsLayout = true
    }

    private var statusLine: CGFloat = 20
    /// `px-2 py-1.5` around the status line.
    private var statusHeight: CGFloat { status.isHidden ? 0 : 12 + statusLine }

    func height(forWidth width: CGFloat) -> CGFloat { max(160, CGFloat(rows.count) * 32 + statusHeight) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }

    override func layout() {
        super.layout()
        // `-mx-2`: rows reach 8pt into the panel's padding on each side.
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: -8, y: y, width: bounds.width + 16, height: 32)
            y += 32
        }
        status.frame = NSRect(x: 0, y: y + 6, width: bounds.width, height: statusLine)
    }
}

/// One folder row: a 16pt muted folder glyph and the name, truncated.
final class FolderBrowseRowView: ControlView {
    private let icon = IconView(name: .folder, size: 16, strokeColor: Themed.color(\.mutedForeground))
    private let label = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground))
    var title = "" { didSet { label.text = title; setAccessibilityLabel(title == ".." ? "Parent folder" : title) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scalesWhenPressed = false
        label.lineHeight = 20
        label.truncates = true
        addSubview(icon)
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard state.hovered || state.focusVisible else { return }
        // Redesign: its own state fill on the control radius, as its other list rows.
        let redesign = DesignGeometry.usesClassic(self)
        let r: CGFloat = redesign ? RedesignTokens.Radius.control : 6
        let path = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        let fill = redesign ? RedesignTokens.State.fill(state, dark: effectiveAppearance.isDark) : Themed.color(\.muted, 0.5)
        (fill ?? .clear).setFill()
        path.fill()
        if state.focusVisible {
            Themed.color(\.ring).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 32, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 40), height: 20)
    }
}
