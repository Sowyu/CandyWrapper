import AppKit
import DesignSystem
import SpaceModel

/// The Trash tab: trashed pages newest first, each with Restore and Delete forever.
public final class SpaceTrashView: DSView {
    public let store: SpacePageStore
    private let heading = LabelView("Trash", font: DSFont.ui(32, weight: .semibold), color: Themed.color(\.foreground))
    private let note = LabelView("", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private(set) var rows: [SpaceTrashRowView] = []
    private var token: Int?
    /// Asks before Delete forever and calls `done` only on confirm. Tests replace it.
    var confirmDelete: (_ title: String, _ done: @escaping @MainActor () -> Void) -> Void = { _, _ in }

    public init(store: SpacePageStore) {
        self.store = store
        super.init(frame: .zero)
        heading.lineHeight = 40
        note.lineHeight = 20
        [heading, note].forEach(addSubview)
        token = store.observe { [weak self] in self?.refresh() }
        confirmDelete = { [weak self] title, done in
            guard let window = self?.window else { return }
            Self.presentConfirm(title: title, in: window, done: done)
        }
        refresh()
    }

    /// The design system's dialog: Cancel, or the destructive Delete forever.
    static func presentConfirm(title: String, in window: NSWindow, done: @escaping @MainActor () -> Void) {
        let dialog = DialogView(title: "Delete “\(title)” forever?",
                                message: "It can't be restored, and neither can the pages inside it. Its images and files leave this Mac.")
        dialog.maxWidth = 420
        let cancel = ButtonView("Cancel", variant: .outline)
        let delete = ButtonView("Delete forever", variant: .destructive)
        dialog.footerButtons = [cancel, delete]
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host] in host?.close() }
        dialog.onClose = { [weak host] in host?.close() }
        delete.action = { [weak host] in host?.close(); done() }
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
            let title = store.pages[id].map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Untitled"
            row.title.text = title
            row.when.text = store.pages[id]?.trashedAt.map { "Trashed " + SpacePageHistoryView.when($0).lowercasedFirst } ?? ""
            row.restore.action = { [weak self] in self?.store.restore(id) }
            row.delete.action = { [weak self] in
                self?.confirmDelete(title) { [weak self] in self?.store.remove(id) }
            }
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
    let when = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let restore = ButtonView("Restore", variant: .ghost, size: .sm)
    let delete = ButtonView("Delete forever", variant: .ghostDestructive, size: .sm)
    private let rule = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineHeight = 20
        when.lineHeight = 16
        when.alignment = .right
        [title, when, restore, delete].forEach(addSubview)
        layer?.addSublayer(rule)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { rule.backgroundColor = Themed.color(\.border).cgColor(in: self) }

    override func layout() {
        super.layout()
        let d = delete.intrinsicContentSize, r = restore.intrinsicContentSize
        delete.frame = NSRect(x: bounds.width - d.width, y: (bounds.height - d.height) / 2, width: d.width, height: d.height)
        restore.frame = NSRect(x: delete.frame.minX - 4 - r.width, y: (bounds.height - r.height) / 2, width: r.width, height: r.height)
        let w = min(180, when.textWidth.rounded(.up))
        when.frame = NSRect(x: restore.frame.minX - 12 - w, y: (bounds.height - 16) / 2, width: w, height: 16)
        title.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: max(0, when.frame.minX - 12), height: 20)
        rule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}
