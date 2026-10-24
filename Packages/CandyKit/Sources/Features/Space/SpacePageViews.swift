import AppKit
import DesignSystem
import SpaceModel

/// A Space page's tab until the editor lands (piece 12): the breadcrumb and the title, large with room around it.
/// "No pages yet" shows with a New page button when there is no page to open.
public final class SpacePagePlaceholderView: DSView {
    public let store: SpacePageStore
    public private(set) var page: PageID?
    public var onNewPage: () -> Void = {}
    private let crumb = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let title = LabelView("", font: DSFont.ui(32, weight: .semibold), color: Themed.color(\.foreground))
    private let newPage = ButtonView("New page", icon: .plus, variant: .secondary, size: .sm)
    private var token: Int?

    public init(store: SpacePageStore) {
        self.store = store
        super.init(frame: .zero)
        crumb.lineHeight = 16
        title.lineHeight = 40
        [crumb, title, newPage].forEach(addSubview)
        newPage.action = { [weak self] in self?.onNewPage() }
        token = store.observe { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { if let token { store.removeObserver(token) } }

    public func show(_ id: PageID?) {
        page = id
        refresh()
    }

    private func refresh() {
        let pages = store.pages
        if let page, let r = pages[page] {
            let names = SpaceTree.ancestors(of: page, in: pages).map { pages[$0].map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Untitled" }
            crumb.text = (["Space"] + names).joined(separator: "  ›  ")
            title.text = r.title.isEmpty ? "Untitled" : r.title
            title.color = Themed.color(\.foreground, r.title.isEmpty ? 0.4 : 1)
            newPage.isHidden = true
        } else {
            crumb.text = "Space"
            title.text = "No pages yet"
            title.color = Themed.color(\.mutedForeground)
            newPage.isHidden = false
        }
        setAccessibilityLabel(title.text)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        // Mockup B: a 720pt column, the title well down from the top.
        let col = min(720, bounds.width - 64)
        let x = ((bounds.width - col) / 2).rounded()
        crumb.frame = NSRect(x: x, y: 72, width: col, height: 16)
        title.frame = NSRect(x: x, y: 96, width: col, height: 40)
        let s = newPage.intrinsicContentSize
        newPage.frame = NSRect(x: x, y: 156, width: s.width, height: s.height)
    }
}

/// The Trash tab: trashed pages newest first, each with Restore and Delete forever.
public final class SpaceTrashView: DSView {
    public let store: SpacePageStore
    private let heading = LabelView("Trash", font: DSFont.ui(32, weight: .semibold), color: Themed.color(\.foreground))
    private let note = LabelView("", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private var rows: [SpaceTrashRowView] = []
    private var token: Int?

    public init(store: SpacePageStore) {
        self.store = store
        super.init(frame: .zero)
        heading.lineHeight = 40
        note.lineHeight = 20
        [heading, note].forEach(addSubview)
        token = store.observe { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { if let token { store.removeObserver(token) } }

    private func refresh() {
        let ids = store.trashed
        note.text = ids.isEmpty ? "Trash is empty." : ids.count == 1 ? "1 page" : "\(ids.count) pages"
        for (i, id) in ids.enumerated() {
            let row = i < rows.count ? rows[i] : {
                let r = SpaceTrashRowView()
                addSubview(r)
                rows.append(r)
                return r
            }()
            row.id = id
            row.title.text = store.pages[id].map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Untitled"
            row.restore.action = { [weak self] in self?.store.restore(id) }
            row.delete.action = { [weak self] in self?.store.remove(id) }
        }
        while rows.count > ids.count { rows.removeLast().removeFromSuperview() }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let col = min(720, bounds.width - 64)
        let x = ((bounds.width - col) / 2).rounded()
        heading.frame = NSRect(x: x, y: 96, width: col, height: 40)
        note.frame = NSRect(x: x, y: 140, width: col, height: 20)
        var y: CGFloat = 180
        for r in rows {
            r.frame = NSRect(x: x, y: y, width: col, height: 40)
            y += 40
        }
    }
}

final class SpaceTrashRowView: DSView {
    var id: PageID?
    let title = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground))
    let restore = ButtonView("Restore", variant: .ghost, size: .sm)
    let delete = ButtonView("Delete forever", variant: .ghostDestructive, size: .sm)
    private let rule = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineHeight = 20
        [title, restore, delete].forEach(addSubview)
        layer?.addSublayer(rule)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { rule.backgroundColor = Themed.color(\.border).cgColor(in: self) }

    override func layout() {
        super.layout()
        let d = delete.intrinsicContentSize, r = restore.intrinsicContentSize
        delete.frame = NSRect(x: bounds.width - d.width, y: (bounds.height - d.height) / 2, width: d.width, height: d.height)
        restore.frame = NSRect(x: delete.frame.minX - 4 - r.width, y: (bounds.height - r.height) / 2, width: r.width, height: r.height)
        title.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: max(0, restore.frame.minX - 12), height: 20)
        rule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}
