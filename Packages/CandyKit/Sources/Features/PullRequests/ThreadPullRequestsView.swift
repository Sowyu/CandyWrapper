import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The thread's "Pull requests" tab (ThreadPullRequestsPanel.tsx): one row per linked pull request,
/// stacks stepped in under the layer they target, newest chain first, and a footer with the counts
/// and Link; with none, the empty state that offers Link pull request.
public final class ThreadPullRequestsListView: DSView {
    private let document = PullRequestsPageView.Document()
    private let scroll: ScrollAreaView
    private var rows: [PullRequestRowView] = []
    private let footerRule = CALayer()
    private let footerLabel = LabelView("", font: DSFont.ui(11))
    private let linkButton = ButtonView("Link", icon: .plus, variant: .ghost, size: .xs)
    private let emptyIcon = IconView(name: .link2, size: 24)
    private let emptyTitle = LabelView("No linked pull requests", font: DSFont.ui(14, weight: .medium))
    private let emptyText = TextBlockView()
    private let emptyButton = ButtonView("Link pull request", icon: .plus, variant: .outline, size: .sm)
    private var lines: [ThreadPullRequests.Line] = []
    public var onOpen: ((ThreadPullRequestLink) -> Void)?
    public var onLink: (() -> Void)?
    public var onUnlink: ((ThreadPullRequestLink) -> Void)?
    public var onCopy: ((String) -> Void)?
    public var onOpenExternal: ((String) -> Void)?
    /// Watching (`thread.pull-request.watch`); nil where the server has no watch.
    public var onWatch: ((ThreadPullRequestLink, Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document)
        super.init(frame: frameRect)
        footerRule.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(footerRule)
        footerLabel.lineHeight = 16
        emptyTitle.lineHeight = 20
        emptyTitle.alignment = .center
        emptyText.font = DSFont.ui(12)
        emptyText.lineHeight = 16
        emptyText.alignment = .center
        emptyText.text = "Pull requests the agent opens from this thread land here. Link one yourself from a URL or a number."
        linkButton.iconSize = 14
        emptyButton.iconSize = 14
        [scroll, footerLabel, linkButton, emptyIcon, emptyTitle, emptyText, emptyButton].forEach(addSubview)
        linkButton.action = { [weak self] in self?.onLink?() }
        emptyButton.action = { [weak self] in self?.onLink?() }
    }

    public func set(_ links: [ThreadPullRequestLink], nowMs: Int64) {
        let shown = ThreadPullRequests.visible(links)
        lines = ThreadPullRequests.lines(shown)
        rows.forEach { $0.removeFromSuperview() }
        rows = lines.map { line in
            let row = PullRequestRowView()
            row.configure(link: line, nowMs: nowMs)
            row.onSelect = { [weak self] _ in self?.onOpen?(line.link) }
            row.onNumberMenu = { [weak self, weak row] _, event in if let row { self?.showMenu(line.link, in: row, event: event) } }
            document.addSubview(row)
            return row
        }
        let open = shown.filter { $0.snapshot == nil || $0.snapshot?.state == .open }.count
        let synced = shown.compactMap { $0.snapshot?.syncedAt }.max { ($0.epochMs ?? 0) < ($1.epochMs ?? 0) }
        footerLabel.text = "\(open) open · \(shown.count) linked" + (synced.map { " · synced \(TimestampFormat.formatRelativeTimeLabel($0.raw, nowMs: nowMs))" } ?? "")
        let empty = shown.isEmpty
        [scroll, footerLabel, linkButton].forEach { $0.isHidden = empty }
        [emptyIcon, emptyTitle, emptyText, emptyButton].forEach { $0.isHidden = !empty }
        needsLayout = true
    }

    /// The row's menu: Copy link, Open, watch, Unlink (or Dismiss for a stack member).
    private func showMenu(_ link: ThreadPullRequestLink, in view: NSView, event: NSEvent) {
        var copy = MenuItem("Copy link", icon: .link)
        copy.action = { [weak self] in self?.onCopy?(link.url) }
        var open = MenuItem("Open", icon: .arrowUpRight)
        open.action = { [weak self] in self?.onOpen?(link) }
        var items = [copy, open]
        let isOpen = link.snapshot == nil || link.snapshot?.state == .open
        if let onWatch, isOpen {
            let watching = link.watch != nil
            var w = MenuItem(watching ? "Stop watching" : "Watch for changes", icon: watching ? .eyeOff : .eye)
            w.action = { onWatch(link, !watching) }
            items.append(w)
        }
        var unlink = MenuItem(link.source == .stack ? "Dismiss from thread" : "Unlink from thread", icon: .unlink2)
        unlink.action = { [weak self] in self?.onUnlink?(link) }
        items.append(unlink)
        MenuPopupView.showContextMenu(items, in: view, at: view.convert(event.locationInWindow, from: nil))
    }

    public override func rightMouseDown(with event: NSEvent) {
        let p = document.convert(event.locationInWindow, from: nil)
        guard let i = rows.firstIndex(where: { $0.frame.contains(p) }) else { return }
        showMenu(lines[i].link, in: rows[i], event: event)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let footer: CGFloat = 36
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - footer))
        var y: CGFloat = 6
        for row in rows {
            row.frame = NSRect(x: 6, y: y, width: max(0, scroll.bounds.width - 12), height: PullRequestRowView.panelHeight)
            y += PullRequestRowView.panelHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: max(scroll.bounds.height, y + 6))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        footerRule.frame = CGRect(x: 0, y: h - footer, width: w, height: 1)
        footerRule.isHidden = rows.isEmpty
        CATransaction.commit()
        let lw = ceil(linkButton.intrinsicContentSize.width)
        linkButton.frame = NSRect(x: w - 8 - lw, y: h - footer + 6, width: lw, height: 24)
        footerLabel.frame = NSRect(x: 8, y: h - footer + 10, width: max(0, linkButton.frame.minX - 16), height: 16)
        // Empty (`gap-2 p-6`, `max-w-60` text).
        let tw = min(240, w - 48)
        let textH = emptyText.height(forWidth: tw)
        let total = 24 + 8 + 20 + 8 + textH + 8 + 28
        var ey = (h - total) / 2
        emptyIcon.frame = NSRect(x: (w - 24) / 2, y: ey, width: 24, height: 24); ey += 32
        emptyTitle.frame = NSRect(x: 24, y: ey, width: w - 48, height: 20); ey += 28
        emptyText.frame = NSRect(x: (w - tw) / 2, y: ey, width: tw, height: textH); ey += textH + 8
        let bw = ceil(emptyButton.intrinsicContentSize.width)
        emptyButton.frame = NSRect(x: (w - bw) / 2, y: ey, width: bw, height: 28)
    }

    public override func updateLayer() {
        footerRule.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self)
        footerLabel.color = Themed.color(\.mutedForeground)
        emptyIcon.strokeColor = Themed.color(\.mutedForeground, 0.6)
        emptyTitle.color = Themed.color(\.foreground)
        emptyText.color = Themed.color(\.mutedForeground)
    }
}

/// `resolveLinkPullRequestInput` (LinkPullRequestDialog.tsx:84-118): which pull request an input
/// names, or why it cannot.
public enum LinkPullRequestLogic {
    public struct Resolved: Equatable, Sendable {
        public var host: String
        public var repository: String
        public var number: Int
        public var url: String
        public init(host: String, repository: String, number: Int, url: String) {
            self.host = host; self.repository = repository; self.number = number; self.url = url
        }
    }

    public enum Outcome: Equatable, Sendable {
        case link(Resolved)
        case error(String)
    }

    /// The thread's own repository, for a bare number.
    public struct Project: Sendable {
        public var host: String
        public var repository: String
        public var kind: String?
        public init(host: String, repository: String, kind: String?) { self.host = host; self.repository = repository; self.kind = kind }
    }

    public static func resolve(_ input: String, project: Project?, canLink: (ChangeRequestURL.Link) -> Bool = { _ in true }) -> Outcome? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = ChangeRequestURL.parse(trimmed) != nil ? trimmed : ChangeRequestURL.reference(input)
        guard let parsed else { return nil }
        if let url = ChangeRequestURL.parse(parsed) {
            guard canLink(url) else { return .error("No project in this environment can read \(url.host)/\(url.repository).") }
            return .link(Resolved(host: url.host, repository: url.repository, number: url.number, url: parsed))
        }
        guard let number = Int(parsed), number >= 1 else { return nil }
        guard let project else { return .error("Paste the full pull request URL; this thread has no repository to resolve the number against.") }
        guard let web = ChangeRequestURL.url(kind: project.kind, host: project.host, repository: project.repository, number: number),
              let reference = ChangeRequestURL.parse(web) else {
            return .error("Paste a full URL; this project's host has no known pull request URL.")
        }
        return .link(Resolved(host: reference.host, repository: reference.repository, number: reference.number, url: web))
    }

    /// The line under the input once it has been touched.
    public static func validation(_ input: String, dirty: Bool, outcome: Outcome?) -> String? {
        guard dirty else { return nil }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste a pull request URL or enter 123 / #123." }
        guard let outcome else { return "Use a pull request URL, 123, or #123." }
        if case .error(let message) = outcome { return message }
        return nil
    }
}

/// "Link pull request" (LinkPullRequestDialog.tsx:194-254): a `max-w-xl` dialog with the input, the
/// resolved `host/repository #n` line and the validation line, Cancel and Link.
@MainActor
public final class LinkPullRequestDialog {
    public let dialog: DialogView
    public let input = InputView(placeholder: "Pull request URL or #42")
    public let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
    public let link = ButtonView("Link", variant: .default, size: .sm)
    private let preview = LabelView("", font: DSFont.ui(12))
    private let error = LabelView("", font: DSFont.ui(12))
    private let project: LinkPullRequestLogic.Project?
    private let canLink: (ChangeRequestURL.Link) -> Bool
    private var dirty = false
    public private(set) var outcome: LinkPullRequestLogic.Outcome?
    public var submitError: String? { didSet { update() } }
    public var pending = false { didSet { update() } }
    public var onSubmit: ((LinkPullRequestLogic.Resolved) -> Void)?

    public init(project: LinkPullRequestLogic.Project?, canLink: @escaping (ChangeRequestURL.Link) -> Bool = { _ in true }) {
        self.project = project
        self.canLink = canLink
        dialog = DialogView(kind: .dialog, title: "Link pull request",
                            message: "Attach a pull request to this thread by its URL, or by its number for this thread's repository.")
        dialog.maxWidth = 576
        preview.lineHeight = 16
        error.lineHeight = 16
        dialog.panelContent = [Fields(input: input, preview: preview, error: error)]
        dialog.footerButtons = [cancel, link]
        input.onChange = { [weak self] _ in self?.dirty = true; self?.update() }
        input.onSubmit = { [weak self] in self?.submit() }
        link.action = { [weak self] in self?.submit() }
        update()
    }

    private func submit() {
        dirty = true
        update()
        guard case .link(let resolved)? = outcome, !pending else { return }
        submitError = nil
        onSubmit?(resolved)
    }

    private func update() {
        outcome = LinkPullRequestLogic.resolve(input.text, project: project, canLink: canLink)
        if case .link(let r)? = outcome { preview.text = "\(r.host)/\(r.repository) #\(r.number)" } else { preview.text = "" }
        error.text = LinkPullRequestLogic.validation(input.text, dirty: dirty, outcome: outcome) ?? submitError ?? ""
        let resolvable: Bool = if case .link? = outcome { true } else { false }
        link.isEnabled = !pending && resolvable
        link.title = pending ? "Linking..." : "Link"
        cancel.isEnabled = !pending
        preview.color = Themed.color(\.mutedForeground)
        error.color = Themed.color(\.destructiveForeground)
        (dialog.panelContent.first as? Fields)?.invalidateIntrinsicContentSize()
        dialog.panelContent.first?.needsLayout = true
        // The panel grew or shrank by a line: the dialog and the modal host that sizes it lay out again.
        dialog.invalidateIntrinsicContentSize()
        dialog.needsLayout = true
        dialog.superview?.needsLayout = true
    }

    /// The input with the two lines under it (`DialogPanel` `space-y-4`).
    final class Fields: DSView {
        let input: InputView
        let preview: LabelView
        let error: LabelView
        init(input: InputView, preview: LabelView, error: LabelView) {
            self.input = input; self.preview = preview; self.error = error
            super.init(frame: .zero)
            [input, preview, error].forEach(addSubview)
        }
        private var lines: [LabelView] { [preview, error].filter { !$0.text.isEmpty } }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 32 + CGFloat(lines.count) * (16 + 16))
        }
        override func layout() {
            super.layout()
            input.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
            var y: CGFloat = 48
            for l in [preview, error] {
                l.isHidden = l.text.isEmpty
                guard !l.isHidden else { continue }
                l.frame = NSRect(x: 0, y: y, width: bounds.width, height: 16)
                y += 32
            }
        }
    }
}
