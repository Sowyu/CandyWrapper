import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The Pull Requests page (routes/_chat.pull-requests.tsx `PullRequestsRouteView` and
/// `PullRequestsColumn`): the 52pt header with the title, then a `max-w-6xl` page whose first row
/// is the search, Sort, Filters, provider and refresh controls, and under it the list: grouped
/// rows, the ghost while loading, the empty and unavailable states. The right panel with the
/// selected pull requests sits beside the column; `PullRequestsController` owns both.
public final class PullRequestsPageView: DSView {
    /// What the list body shows (`listBody`, _chat.pull-requests.tsx:1888-1984).
    public enum Body: Equatable, Sendable {
        case ghost(caption: String?)
        case unavailable(title: String, message: String, retry: Bool)
        case noProjects
        case searchEmpty(query: String)
        case empty(filtered: Bool, canLoadMore: Bool)
        case list
    }

    public struct HostOption: Equatable, Sendable {
        public var value: String
        public var label: String
        public var kind: String?
        public var unavailable: String?
        public init(value: String, label: String, kind: String?, unavailable: String? = nil) {
            self.value = value; self.label = label; self.kind = kind; self.unavailable = unavailable
        }
    }

    public struct ProjectOption: Equatable, Sendable {
        public var key: String
        public var title: String
        public var unavailable: String?
        public init(key: String, title: String, unavailable: String? = nil) { self.key = key; self.title = title; self.unavailable = unavailable }
    }

    /// Everything the page draws. The controller rebuilds it on every change.
    public struct Model: Equatable, Sendable {
        public var body: Body = .ghost(caption: nil)
        public var groups: [PullRequestListLogic.Group] = []
        /// Search text for `matched in the description` (rows scoring 10 or less).
        public var searchText = ""
        public var showProvider = false
        public var selectedKey: String?
        /// The list's footer: truncated, loading more, nothing more to load.
        public var truncated = false
        public var loadingMore = false
        public var canLoadMore = false
        /// The warning above a list that failed to refresh (`listQuery.error && shownCount > 0`).
        public var errorBanner: String?
        public var refreshing = false
        public var searchBusy = false
        public var speedMode = false
        // Controls.
        public var sort = "ready"
        public var state = "open"
        public var involvement = "all"
        public var host: String?
        public var menuFilters = PullRequestListFilters()
        public var hostOptions: [HostOption] = []
        public var projects: [ProjectOption] = []
        public var projectKey: String?
        public var authors: [PullRequestListLogic.AuthorFacet] = []
        public var labels: [PullRequestListLogic.LabelFacet] = []
        public var nowMs: Int64 = 0
        public init() {}

        /// `filterCount` (PullRequestListFilters.tsx:425-436).
        public var filterCount: Int {
            [state != "open", involvement != "all", host != nil, projectKey != nil].filter { $0 }.count
                + [menuFilters.draft, menuFilters.review, menuFilters.checks, menuFilters.author].compactMap { $0 }.count
                + (menuFilters.labels ?? []).flatMap { $0 }.count
        }
    }

    public var model = Model() { didSet { if model != oldValue { apply(old: oldValue) } } }

    // Callbacks.
    public var onQuery: ((String) -> Void)?
    public var onSort: ((String) -> Void)?
    public var onState: ((String) -> Void)?
    public var onInvolvement: ((String) -> Void)?
    public var onHost: ((String?) -> Void)?
    public var onProject: ((String?) -> Void)?
    public var onFilters: ((PullRequestListFilters) -> Void)?
    public var onRefresh: (() -> Void)?
    public var onRetry: (() -> Void)?
    public var onLoadMore: (() -> Void)?
    public var onAddProject: (() -> Void)?
    public var onSelect: ((PullRequestListEntry) -> Void)?
    public var onSpeedAction: ((PullRequestListEntry, String) -> Void)?
    public var onCopyLink: ((String) -> Void)?
    public var onOpenURL: ((String) -> Void)?

    public let header = SettingsHeaderView()
    public let search = InputGroupView(placeholder: "Search pull requests, or label:bug", leading: .icon(.search))
    let sortButton = ButtonView("Sort", icon: .arrowDownUp, variant: .outline)
    let filtersButton = ButtonView("Filters", icon: .listFilter, variant: .outline)
    let filterCount = CountPill()
    let providerButton = ButtonView("All", icon: .plug2, variant: .outline)
    let refreshButton = ButtonView(nil, icon: .refreshCw, variant: .outline, size: .icon)
    private let document = Document()
    private let scroll: ScrollAreaView
    private var groupViews: [GroupHeaderView] = []
    private var rowViews: [String: PullRequestRowView] = [:]
    private var bodyView: NSView?
    private let footerLabel = LabelView("", font: DSFont.ui(12))
    private let loadMoreButton = ButtonView("Load more pull requests", variant: .outline, size: .sm)
    private let banner = BannerView()
    /// Lays out the page's content, the right panel's region excluded.
    public var contentInsetRight: CGFloat = 0 { didSet { needsLayout = true } }

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document)
        super.init(frame: frameRect)
        header.plainTitle = "Pull Requests"
        addSubview(scroll)
        addSubview(header)
        search.input.setAccessibilityLabel("Search pull requests")
        search.input.onChange = { [weak self] text in self?.onQuery?(text) }
        filtersButton.accessory = filterCount
        sortButton.setAccessibilityLabel("Sort pull requests")
        providerButton.setAccessibilityLabel("Filter by provider")
        refreshButton.setAccessibilityLabel("Refresh pull requests")
        for v in [search, sortButton, filtersButton, providerButton, refreshButton, footerLabel, loadMoreButton, banner] as [NSView] { document.addSubview(v) }
        footerLabel.lineHeight = 16
        footerLabel.alignment = .center
        sortButton.action = { [weak self] in self?.showSortMenu() }
        filtersButton.action = { [weak self] in self?.showFiltersMenu() }
        providerButton.action = { [weak self] in self?.showProviderMenu() }
        refreshButton.action = { [weak self] in self?.onRefresh?() }
        loadMoreButton.action = { [weak self] in self?.onLoadMore?() }
        banner.retry.action = { [weak self] in self?.onRetry?() }
        apply(old: nil)
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Mod+F focuses the search (`PullRequestsColumn`'s window listener).
    public func focusSearch() {
        window?.makeFirstResponder(search.input)
    }

    // MARK: Model

    private func apply(old: Model?) {
        let m = model
        search.leading = m.searchBusy ? .icon(.loaderCircle) : .icon(.search)
        filterCount.count = m.filterCount
        filtersButton.accessory = m.filterCount > 0 ? filterCount : nil
        let hostOption = m.hostOptions.first { $0.value == (m.host ?? "") }
        if let host = m.host, let hostOption {
            providerButton.title = nil
            providerButton.size = .icon
            providerButton.icon = hostOption.kind.map(PullRequestStyle.providerIcon) ?? .plug2
            providerButton.toolTip = "Filter by provider: \(hostOption.label)"
            _ = host
        } else {
            providerButton.size = .default
            providerButton.title = "All"
            providerButton.icon = .plug2
            providerButton.toolTip = nil
        }
        refreshButton.isEnabled = !m.refreshing
        refreshButton.setAccessibilityLabel(m.refreshing ? "Refreshing pull requests" : "Refresh pull requests")
        rebuildBody(old: old)
        needsLayout = true
    }

    private func rebuildBody(old: Model?) {
        let m = model
        if old?.body != m.body || bodyView == nil || (m.body == .list) != (old?.body == .list) {
            bodyView?.removeFromSuperview()
            bodyView = nil
            switch m.body {
            case .ghost(let caption):
                bodyView = PullRequestListGhostView(rows: caption == nil ? 7 : 5, caption: caption)
            case .unavailable(let title, let message, let retry):
                let empty = EmptyView(title: title, message: message, icon: .gitPullRequestArrow)
                if retry {
                    let b = ButtonView("Retry", icon: .refreshCw, variant: .outline, size: .sm)
                    b.action = { [weak self] in self?.onRetry?() }
                    empty.content = ButtonRow([b])
                }
                bodyView = empty
            case .noProjects:
                let empty = EmptyView(title: "No projects in this workspace", message: "Add a project, and the pull requests from its repository appear here.")
                empty.illustration = BranchMarkView(joined: false)
                let b = ButtonView("Add project", icon: .plus, variant: .default, size: .sm)
                b.action = { [weak self] in self?.onAddProject?() }
                empty.content = ButtonRow([b])
                bodyView = empty
            case .searchEmpty(let query):
                let shown = query.count > 48 ? String(query.prefix(48)) + "…" : query
                let empty = EmptyView(title: "Nothing matches “\(shown)”",
                                      message: "The hosts were searched for it. Try fewer words, or search by number, author or branch.")
                empty.illustration = BranchMarkView(joined: false)
                let clear = ButtonView("Clear search", icon: .search, variant: .outline, size: .sm)
                clear.action = { [weak self] in self?.search.input.text = ""; self?.onQuery?("") }
                empty.content = ButtonRow([clear, checkAgainButton()])
                bodyView = empty
            case .empty(let filtered, let canLoadMore):
                let empty = EmptyView(title: filtered ? "Nothing under these filters" : "No pull requests",
                                      message: filtered ? "Widen the state, involvement or project filter to see more."
                                          : "Pull requests from every project in this workspace appear here.")
                empty.illustration = BranchMarkView(joined: false)
                var buttons: [ButtonView] = []
                if canLoadMore {
                    let more = ButtonView(m.loadingMore ? "Loading..." : "Load more pull requests", variant: .outline, size: .sm)
                    more.isEnabled = !m.loadingMore
                    more.action = { [weak self] in self?.onLoadMore?() }
                    buttons.append(more)
                }
                buttons.append(checkAgainButton())
                empty.content = ButtonRow(buttons)
                bodyView = empty
            case .list:
                bodyView = nil
            }
            if let bodyView { document.addSubview(bodyView) }
        }
        // Rows and group headers, reused by key.
        guard m.body == .list else {
            groupViews.forEach { $0.removeFromSuperview() }; groupViews = []
            rowViews.values.forEach { $0.removeFromSuperview() }; rowViews = [:]
            return
        }
        while groupViews.count < m.groups.count { let g = GroupHeaderView(); document.addSubview(g); groupViews.append(g) }
        while groupViews.count > m.groups.count { groupViews.removeLast().removeFromSuperview() }
        var keep = Set<String>()
        for (i, group) in m.groups.enumerated() {
            groupViews[i].set(group, visible: !group.label.isEmpty && m.involvement == "all")
            for entry in group.entries {
                let key = PullRequestListLogic.key(entry)
                keep.insert(key)
                let row = rowViews[key] ?? {
                    let r = PullRequestRowView()
                    r.onSelect = { [weak self] e in self?.onSelect?(e) }
                    r.onSpeedAction = { [weak self] e, a in self?.onSpeedAction?(e, a) }
                    r.onNumberMenu = { [weak self, weak r] e, event in
                        guard let self, let r else { return }
                        self.showLinkMenu(url: e.url, provider: e.provider, in: r, event: event)
                    }
                    document.addSubview(r)
                    rowViews[key] = r
                    return r
                }()
                let elsewhere = !m.searchText.isEmpty && PullRequestListLogic.score(entry, m.searchText) <= PullRequestListLogic.matchedElsewhereScore
                row.configure(entry, selected: m.selectedKey == key, showProvider: m.showProvider, matchedElsewhere: elsewhere,
                              speedMode: m.speedMode, nowMs: m.nowMs)
            }
        }
        for (key, row) in rowViews where !keep.contains(key) { row.removeFromSuperview(); rowViews[key] = nil }
    }

    private func checkAgainButton() -> ButtonView {
        let b = ButtonView(model.refreshing ? "Checking..." : "Check again", icon: .refreshCw, variant: .outline, size: .sm)
        b.isEnabled = !model.refreshing
        b.action = { [weak self] in self?.onRefresh?() }
        return b
    }

    // MARK: Menus

    private func showSortMenu() {
        let items = PullRequestListLogic.sortOptions.map { o -> MenuItem in
            var item = MenuItem.radio(o.label, checked: o.value == model.sort) { [weak self] _ in self?.onSort?(o.value) }
            item.icon = PullRequestStyle.optionIcon(o.icon)
            item.closesOnClick = true
            return item
        }
        MenuPopupView.show(items, from: sortButton, placement: .dropdown)
    }

    private func showProviderMenu() {
        let items = model.hostOptions.map { o -> MenuItem in
            var item = MenuItem.radio(o.label, checked: o.value == (model.host ?? "")) { [weak self] _ in self?.onHost?(o.value.isEmpty ? nil : o.value) }
            item.icon = o.kind.map(PullRequestStyle.providerIcon) ?? .plug2
            item.closesOnClick = true
            item.isDisabled = o.unavailable != nil
            item.tooltip = o.unavailable
            return item
        }
        MenuPopupView.show(items, from: providerButton, placement: .dropdown)
    }

    /// `PullRequestFiltersMenu`: State, Involvement, then Author, Labels, Draft, Review, Checks, then
    /// Host (two or more), then Project, each a radio submenu with its current value.
    private func showFiltersMenu() {
        let m = model
        func radios(_ label: String, _ options: [PullRequestListLogic.Option], _ value: String, _ pick: @escaping (String) -> Void) -> MenuItem {
            let current = options.first { $0.value == value } ?? options[0]
            var sub = [MenuItem.label(label)]
            sub += options.map { o in
                var item = MenuItem.radio(o.label, checked: o.value == value) { _ in pick(o.value) }
                item.icon = PullRequestStyle.optionIcon(o.icon)
                item.closesOnClick = true
                return item
            }
            var item = MenuItem.submenu("\(label)  ·  \(current.label)", icon: PullRequestStyle.optionIcon(current.icon), sub)
            item.title = label
            item.subtitle = nil
            item.shortcut = current.label
            return item
        }
        var f = m.menuFilters
        let update: (PullRequestListFilters) -> Void = { [weak self] next in self?.onFilters?(next) }
        var items: [MenuItem] = [
            radios("State", PullRequestListLogic.stateOptions, m.state) { [weak self] in self?.onState?($0) },
            radios("Involvement", PullRequestListLogic.involvementOptions, m.involvement) { [weak self] in self?.onInvolvement?($0) },
            .separator,
        ]
        // Author.
        var authorItems = [MenuItem.radio("Anyone", checked: f.author == nil) { _ in var n = f; n.author = nil; update(n) }]
        authorItems[0].icon = .layers
        authorItems[0].closesOnClick = true
        for a in m.authors.prefix(10) {
            var item = MenuItem.radio(a.actor.login, checked: f.author?.lowercased() == a.actor.login.lowercased()) { _ in var n = f; n.author = a.actor.login; update(n) }
            item.shortcut = "\(a.mergedCount) merges loaded"
            item.closesOnClick = true
            authorItems.append(item)
        }
        if m.authors.isEmpty { authorItems.append(MenuItem("No authors found", disabled: true)) }
        var author = MenuItem.submenu("Author", icon: .userRound, authorItems)
        author.shortcut = f.author ?? "Anyone"
        items.append(author)
        // Labels.
        let selected = (f.labels ?? []).flatMap { $0 }
        var labelItems: [MenuItem] = m.labels.map { l in
            let on = selected.contains { $0.lowercased() == l.name.lowercased() }
            var item = MenuItem.checkbox(l.name, checked: on) { next in
                var names = selected.filter { $0.lowercased() != l.name.lowercased() }
                if next { names.append(l.name) }
                f.labels = names.isEmpty ? nil : names.prefix(10).map { [$0] }
                update(f)
            }
            item.shortcut = "\(l.count)"
            return item
        }
        if labelItems.isEmpty { labelItems = [MenuItem("No labels in this view", disabled: true)] }
        var labels = MenuItem.submenu("Labels", icon: .tag, labelItems)
        labels.shortcut = selected.isEmpty ? "Any" : "\(selected.count) selected"
        items.append(labels)
        items.append(radios("Draft", PullRequestListLogic.draftOptions, f.draft ?? "all") { v in var n = f; n.draft = v == "all" ? nil : v; update(n) })
        items.append(radios("Review", PullRequestListLogic.reviewOptions, f.review ?? "all") { v in var n = f; n.review = v == "all" ? nil : v; update(n) })
        items.append(radios("Checks", PullRequestListLogic.checksOptions, f.checks ?? "all") { v in var n = f; n.checks = v == "all" ? nil : v; update(n) })
        if m.hostOptions.count > 2 {
            items.append(.separator)
            let current = m.hostOptions.first { $0.value == (m.host ?? "") }
            var sub = [MenuItem.label("Host")]
            sub += m.hostOptions.map { o in
                var item = MenuItem.radio(o.label, checked: o.value == (m.host ?? "")) { [weak self] _ in self?.onHost?(o.value.isEmpty ? nil : o.value) }
                item.closesOnClick = true
                item.isDisabled = o.unavailable != nil
                return item
            }
            var host = MenuItem.submenu("Host", icon: .plug2, sub)
            host.shortcut = current?.label
            items.append(host)
        }
        items.append(.separator)
        var projectItems = [MenuItem.label("Project")]
        var all = MenuItem.radio("All projects", checked: m.projectKey == nil) { [weak self] _ in self?.onProject?(nil) }
        all.icon = .layers
        all.closesOnClick = true
        projectItems.append(all)
        for p in m.projects.sorted(by: { ($0.unavailable != nil ? 1 : 0) < ($1.unavailable != nil ? 1 : 0) }) {
            var item = MenuItem.radio(p.unavailable == nil ? p.title : "\(p.title) · Unavailable", checked: m.projectKey == p.key) { [weak self] _ in self?.onProject?(p.key) }
            item.icon = .folderGit2
            item.closesOnClick = true
            item.isDisabled = p.unavailable != nil
            item.tooltip = p.unavailable
            projectItems.append(item)
        }
        var project = MenuItem.submenu("Project", icon: .folderGit2, projectItems)
        project.shortcut = m.projects.first { $0.key == m.projectKey }?.title ?? "All projects"
        items.append(project)
        MenuPopupView.show(items, from: filtersButton, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    /// `showPullRequestLinkContextMenu`: Copy link, then Open on the host.
    func showLinkMenu(url: String, provider: String, in view: NSView, event: NSEvent) {
        var copy = MenuItem("Copy link", icon: .copy)
        copy.action = { [weak self] in self?.onCopyLink?(url) }
        var open = MenuItem(PullRequestDetailLogic.openOnHostLabel(provider))
        open.action = { [weak self] in self?.onOpenURL?(url) }
        MenuPopupView.showContextMenu([copy, open], in: view, at: view.convert(event.locationInWindow, from: nil))
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let width = max(0, bounds.width - contentInsetRight)
        header.frame = NSRect(x: 0, y: 0, width: width, height: 52)
        scroll.frame = NSRect(x: 0, y: 52, width: width, height: max(0, bounds.height - 52))
        layoutDocument(width: scroll.bounds.width)
    }

    private func layoutDocument(width: CGFloat) {
        // `scrollbar-gutter-both` 6px, `max-w-6xl`, `px-6 pt-6 pb-12`.
        let inner = max(0, width - 12)
        let container = min(1152, inner)
        let x0 = 6 + (inner - container) / 2 + 24
        let w = max(0, container - 48)
        var y: CGFloat = 24
        // Controls: `flex flex-wrap gap-2`; the search takes its own line under `@lg` (512).
        let buttons: [ButtonView] = [sortButton, filtersButton, providerButton, refreshButton]
        let widths = buttons.map { ceil($0.intrinsicContentSize.width) }
        let buttonsWidth = widths.reduce(0, +) + CGFloat(buttons.count - 1) * 8
        if w >= 512 {
            let sw = max(0, w - buttonsWidth - 8)
            search.frame = NSRect(x: x0, y: y, width: sw, height: 32)
            var bx = x0 + sw + 8
            for (b, bw) in zip(buttons, widths) { b.frame = NSRect(x: bx, y: y, width: bw, height: 32); bx += bw + 8 }
            y += 32
        } else {
            search.frame = NSRect(x: x0, y: y, width: w, height: 32)
            y += 40
            var bx = x0
            for (b, bw) in zip(buttons, widths) {
                if bx > x0, bx + bw > x0 + w { bx = x0; y += 40 }
                b.frame = NSRect(x: bx, y: y, width: bw, height: 32); bx += bw + 8
            }
            y += 32
        }
        // The marker (`-mt-3 h-px`) then `gap-4`.
        y += 1 + 16
        let viewportHeight = scroll.bounds.height
        if model.body == .list {
            var gi = 0
            for group in model.groups {
                guard gi < groupViews.count else { break }
                let g = groupViews[gi]
                if g.isVisibleHeader {
                    g.frame = NSRect(x: x0, y: y, width: w, height: 20)
                    g.isHidden = false
                    y += 20 + 2
                } else {
                    g.isHidden = true
                }
                for entry in group.entries {
                    guard let row = rowViews[PullRequestListLogic.key(entry)] else { continue }
                    row.frame = NSRect(x: x0, y: y, width: w, height: PullRequestRowView.height)
                    y += PullRequestRowView.height + 2
                }
                y += 12 - 2
                gi += 1
            }
            y -= 12
            if let error = model.errorBanner {
                y += 16
                banner.isHidden = false
                banner.text = error
                banner.frame = NSRect(x: x0, y: y, width: w, height: banner.height(forWidth: w))
                y += banner.frame.height
            } else {
                banner.isHidden = true
            }
            // The footer (`py-3 text-xs`).
            if model.truncated && !model.groups.isEmpty {
                y += 16
                if model.loadingMore || !model.canLoadMore {
                    loadMoreButton.isHidden = true
                    footerLabel.isHidden = false
                    footerLabel.text = model.loadingMore ? "Loading more" : "Narrow your search to find more pull requests."
                    footerLabel.frame = NSRect(x: x0, y: y + 12, width: w, height: 16)
                    y += 40
                } else {
                    footerLabel.isHidden = true
                    loadMoreButton.isHidden = false
                    let bw = ceil(loadMoreButton.intrinsicContentSize.width)
                    loadMoreButton.frame = NSRect(x: x0 + (w - bw) / 2, y: y + 12, width: bw, height: 28)
                    y += 52
                }
            } else {
                footerLabel.isHidden = true
                loadMoreButton.isHidden = true
            }
        } else {
            banner.isHidden = true
            footerLabel.isHidden = true
            loadMoreButton.isHidden = true
            if let ghost = bodyView as? PullRequestListGhostView {
                ghost.frame = NSRect(x: x0, y: y, width: w, height: ghost.height)
                y += ghost.height
            } else if let empty = bodyView as? EmptyView {
                // `Empty` is `flex-1 justify-center`: it fills what the page leaves.
                let h = max(empty.height(forWidth: w), viewportHeight - y - 48)
                empty.frame = NSRect(x: x0, y: y, width: w, height: h)
                y += h
            }
        }
        y += 48
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(viewportHeight, y))
    }

    final class Document: DSView {}
}

/// `PullRequestGroupHeader`: glyph, name, count and a rule to the edge
/// (`flex items-center gap-2 px-3 pb-1 text-xs font-medium text-muted-foreground/70`).
final class GroupHeaderView: DSView {
    private var icon = IconView(name: .layers, size: 14)
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let count = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let rule = CALayer()
    private(set) var isVisibleHeader = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(rule)
        label.lineHeight = 16
        count.lineHeight = 16
        [icon, label, count].forEach(addSubview)
    }

    func set(_ group: PullRequestListLogic.Group, visible: Bool) {
        isVisibleHeader = visible
        icon.removeFromSuperview()
        icon = IconView(name: group.key == .authored ? .penLine : group.key == .reviewRequested ? .eye : .users, size: 14,
                        strokeColor: Themed.color(\.mutedForeground, 0.7))
        addSubview(icon)
        label.text = group.label
        count.text = "\(group.entries.count)"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 12
        icon.frame = NSRect(x: x, y: 1, width: 14, height: 14); x += 14 + 8
        let lw = ceil(label.textWidth)
        label.frame = NSRect(x: x, y: 0, width: lw + 1, height: 16); x += lw + 8
        let cw = ceil(count.textWidth)
        count.frame = NSRect(x: x, y: 0, width: cw + 1, height: 16); x += cw + 8
        rule.frame = CGRect(x: x, y: 7.5, width: max(8, bounds.width - 12 - x), height: 1)
    }

    override func updateLayer() {
        label.color = Themed.color(\.mutedForeground, 0.7)
        count.color = Themed.color(\.mutedForeground, 0.5)
        rule.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }
}

/// One list row (PullRequestRow.tsx with PullRequestListRow.tsx's lines): the state glyph, then
/// `#n title` with the checks and verdict glyphs and the diff counts on the right, and under it the
/// author, repository and labels with the time on the right. `px-3 py-2.5`, `rounded-md`,
/// `bg-accent` selected, `hover:bg-accent/60`. Shift shows the quick actions.
final class PullRequestRowView: DSView {
    static let height: CGFloat = 56
    /// The linked pull requests panel's row (`PULL_REQUEST_ROW_CLASS`, `py-1 pr-1`,
    /// stepping in `1.25rem` per stack layer): 44pt.
    static let panelHeight: CGFloat = 44
    /// Nil on the page; the stack depth in the thread's panel.
    var panelDepth: Int? { didSet { needsLayout = true } }
    /// `head → base` in the panel's meta line.
    private let branches = LabelView("", font: DSFont.mono(11))
    private let connector = CALayer()
    private let glyph = PullRequestStateGlyphView()
    private let number = LabelView("", font: DSFont.mono(12))
    private let title = LabelView("", font: DSFont.ui(14))
    private let checks = CheckStatusGlyph()
    private let review = CheckStatusGlyph()
    private let stack = LabelView("", font: DSFont.ui(12))
    private let stackIcon = IconView(name: .layers, size: 12)
    private let diffStat = PullRequestDiffStatView()
    private let elsewhere = MatchedElsewhereView()
    private let provider = IconView(name: .brandGitHub, size: 12)
    private let avatar = PullRequestAvatarView()
    private let login = LabelView("", font: DSFont.ui(11))
    private let repository = LabelView("", font: DSFont.ui(11))
    private var labelChips: [BadgeView] = []
    private let time = LabelView("", font: DSFont.ui(11))
    private var speedButtons: [ButtonView] = []
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private(set) var entry: PullRequestListEntry?
    private var selected = false
    private var showProvider = false
    private var speedMode = false
    /// No author to show: a linked pull request the host has not been read for.
    private var authorless = false
    var onSelect: ((PullRequestListEntry) -> Void)?
    var onSpeedAction: ((PullRequestListEntry, String) -> Void)?
    var onNumberMenu: ((PullRequestListEntry, NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 8
        number.lineHeight = 20
        title.lineHeight = 20
        for l in [stack, login, repository, time] { l.lineHeight = 16 }
        diffStat.lineHeight = 16
        [glyph, number, title, checks, review, stackIcon, stack, diffStat, elsewhere, provider, avatar, login, repository, time, branches].forEach(addSubview)
        branches.lineHeight = 16
        branches.truncation = .middle
        connector.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(connector)
        setAccessibilityRole(.button)
    }

    /// A linked pull request's row (ThreadPullRequestsPanel.tsx `LinkRow`): the snapshot, or the
    /// link alone while the host has not been read.
    func configure(link line: ThreadPullRequests.Line, nowMs: Int64) {
        let link = line.link
        let snap = link.snapshot
        var e = PullRequestListEntry(provider: "github", host: link.host, projectId: "", repository: link.repository, number: link.number,
                                     title: snap?.title ?? link.repository, url: link.url, author: nil,
                                     headBranch: snap?.headBranch ?? "", baseBranch: snap?.baseBranch ?? "", state: snap?.state.rawValue ?? "open",
                                     isDraft: snap?.isDraft ?? false, mergeability: snap?.mergeability ?? "unknown",
                                     additions: snap?.additions ?? 0, deletions: snap?.deletions ?? 0,
                                     updatedAt: snap?.updatedAt?.raw ?? "", reviewDecision: snap?.reviewDecision, checksState: snap?.checksState)
        if case .object(let o)? = snap?.author, let loginValue = o["login"]?.stringValue {
            e.author = PullRequestActor(login: loginValue, name: o["name"]?.stringValue, avatarUrl: o["avatarUrl"]?.stringValue)
        }
        panelDepth = line.depth
        configure(e, selected: false, showProvider: false, matchedElsewhere: false, speedMode: false, nowMs: nowMs)
        // Not synced yet: the muted glyph ("Waiting for host state") and `host/repository` in mono.
        authorless = snap == nil || e.author == nil
        repository.font = snap == nil ? DSFont.mono(11) : DSFont.ui(11)
        if snap == nil {
            checks.isHidden = true; review.isHidden = true
            repository.text = "\(link.host)/\(link.repository)"
            glyph.setWaiting()
        }
        branches.text = snap.map { "\($0.headBranch) → \($0.baseBranch)" } ?? ""
        stack.isHidden = line.stackSize == nil
        stackIcon.isHidden = line.stackSize == nil
        if let size = line.stackSize { stack.text = "\(size)" }
        time.text = snap?.updatedAt.map { TimestampFormat.formatRelativeTimeLabel($0.raw, nowMs: nowMs) } ?? ""
        let sources: [String: String] = ["manual": "Linked by you", "created": "Created from this thread", "agent": "Linked by the agent",
                                         "stack": "Found in the stack", "stack-dismissed": "Dismissed"]
        number.toolTip = "\(sources[link.source.rawValue] ?? link.source.rawValue) · \(TimestampFormat.formatRelativeTimeLabel(link.linkedAt.raw, nowMs: nowMs))"
        needsLayout = true
    }

    func configure(_ e: PullRequestListEntry, selected: Bool, showProvider: Bool, matchedElsewhere: Bool, speedMode: Bool, nowMs: Int64) {
        branches.text = ""
        authorless = false
        repository.font = DSFont.ui(11)
        entry = e
        self.selected = selected
        self.showProvider = showProvider
        self.speedMode = speedMode
        glyph.set(state: e.state, isDraft: e.isDraft, mergeability: e.mergeability, baseBranch: e.baseBranch)
        number.text = "#\(e.number)"
        title.text = e.title
        if let s = e.checksState {
            let p = PullRequestStyle.checksState(s)
            checks.set(icon: p.icon, color: p.color)
            checks.isHidden = false
            checks.toolTip = PullRequestDetailLogic.checksStateLabel(s)
        } else { checks.isHidden = true }
        if let d = e.reviewDecision, let p = PullRequestStyle.reviewDecision(d) {
            review.set(icon: p.icon, color: p.color)
            review.isHidden = false
            review.toolTip = p.label
        } else { review.isHidden = true }
        stack.isHidden = e.stack == nil
        stackIcon.isHidden = e.stack == nil
        if let s = e.stack { stack.text = "\(s.position)/\(s.size)" }
        diffStat.additions = e.additions
        diffStat.deletions = e.deletions
        elsewhere.isHidden = !matchedElsewhere
        provider.isHidden = !showProvider
        avatar.actor = e.author
        login.text = e.author?.login ?? "ghost"
        avatar.toolTip = e.author.map { a in a.name.map { n in n != a.login ? "\(n) (@\(a.login))" : a.login } ?? a.login } ?? "ghost"
        repository.text = e.repository
        labelChips.forEach { $0.removeFromSuperview() }
        // Three slots, each shown once the meta line is wide enough; the last visible one carries "+N".
        labelChips = e.labels.prefix(3).enumerated().map { i, label in PullRequestLabelChip.make(label, overflow: 0) }
        labelChips.forEach(addSubview)
        time.text = TimestampFormat.formatRelativeTimeLabel(e.updatedAt, nowMs: nowMs)
        // Shift's quick actions (PullRequestSpeedActions.tsx), GitHub rows that are not merged.
        speedButtons.forEach { $0.removeFromSuperview() }
        speedButtons = []
        if speedMode && e.state != "merged" && e.provider == "github" {
            let actions: [(String, String, IconName)] = e.state == "closed" ? [("reopen", "Reopen", .gitPullRequestArrow)]
                : e.isDraft ? [("close", "Close", .gitPullRequestClosed), ("ready", "Ready for review", .gitPullRequestArrow)]
                : [("close", "Close", .gitPullRequestClosed), ("merge", "Merge", .gitMerge)]
            speedButtons = actions.map { action, label, icon in
                let b = ButtonView(label, icon: icon, variant: action == "close" ? .destructiveOutline : .outline, size: .xs)
                b.iconSize = 12
                b.isEnabled = !(action == "merge" && e.stack != nil)
                b.toolTip = action == "merge" && e.stack != nil ? "Open this pull request to merge its stack" : "\(label) immediately"
                b.setAccessibilityLabel("\(label) #\(e.number)")
                b.action = { [weak self] in if let entry = self?.entry { self?.onSpeedAction?(entry, action) } }
                addSubview(b)
                return b
            }
        }
        setAccessibilityLabel("#\(e.number) \(e.title)")
        restyle()
        needsLayout = true
        needsDisplay = true
    }

    private func restyle() {
        number.color = Themed.color(\.mutedForeground)
        title.color = Themed.color(\.foreground)
        for l in [login, repository, time, stack] { l.color = Themed.color(\.mutedForeground) }
        stackIcon.strokeColor = Themed.color(\.mutedForeground)
        branches.color = Themed.color(\.mutedForeground)
        connector.backgroundColor = Themed.color(\.border, 0.7).cgColor(in: self)
        provider.strokeColor = Themed.color(\.mutedForeground)
    }

    override func layout() {
        super.layout()
        var right = bounds.width
        // Speed actions sit outside the row's button, `gap-1 pr-3`.
        if !speedButtons.isEmpty {
            right -= 12
            for b in speedButtons.reversed() {
                let bw = ceil(b.intrinsicContentSize.width)
                b.frame = NSRect(x: right - bw, y: (bounds.height - 24) / 2, width: bw, height: 24)
                right -= bw + 4
            }
            right += 4
        }
        let panel = panelDepth != nil
        let x0: CGFloat = panel ? 8 + CGFloat(min(panelDepth ?? 0, 3)) * 20 : 12, top: CGFloat = panel ? 4 : 10
        connector.isHidden = (panelDepth ?? 0) == 0
        connector.frame = CGRect(x: x0 - 8, y: (bounds.height - 24) / 2, width: 1, height: 24)
        glyph.frame = NSRect(x: x0, y: top + 3, width: 16, height: 16)
        let lx = x0 + 16 + 8
        let lr = right - (panel ? 4 : 12)
        // Line 1.
        var r = lr
        let dw = diffStat.width
        if dw > 0 { diffStat.frame = NSRect(x: r - dw, y: top + 2, width: dw, height: 16); r -= dw + 6 }
        if !stack.isHidden {
            let sw = ceil(stack.textWidth)
            stack.frame = NSRect(x: r - sw, y: top + 2, width: sw + 1, height: 16)
            stackIcon.frame = NSRect(x: r - sw - 4 - 12, y: top + 4, width: 12, height: 12)
            r -= sw + 16 + 6
        }
        let nw = ceil(number.textWidth)
        number.frame = NSRect(x: lx, y: top, width: nw + 1, height: 20)
        var x = lx + nw - 1 + 6
        let signals = [checks, review].filter { !$0.isHidden }
        let signalsWidth = signals.isEmpty ? 0 : CGFloat(signals.count) * 14 + CGFloat(signals.count - 1) * 4 + 6
        let tw = min(ceil(title.textWidth) + 1, max(0, r - x - signalsWidth))
        title.frame = NSRect(x: x, y: top, width: tw, height: 20)
        x += tw + 6
        for s in signals { s.frame = NSRect(x: x, y: top + 3, width: 14, height: 14); x += 18 }
        // Line 2 (`text-2xs`, 16pt).
        let y2 = top + 20
        let tmw = ceil(time.textWidth)
        time.frame = NSRect(x: lr - tmw, y: y2, width: tmw + 1, height: 16)
        var mx = lx
        let metaRight = lr - tmw - 6
        if !elsewhere.isHidden {
            let ew = min(elsewhere.preferredWidth(metaWidth: metaRight - lx), max(0, metaRight - mx))
            elsewhere.frame = NSRect(x: mx, y: y2 + 0.25, width: ew, height: 16)
            mx += ew + 6
        }
        if !provider.isHidden { provider.frame = NSRect(x: mx, y: y2 + 2.25, width: 12, height: 12); mx += 12 + 6 }
        // `@xs/pr-row-meta` (320): narrower rows show the avatar alone.
        let metaWidth = lr - lx // the `@container/pr-row-meta` line, time included
        avatar.isHidden = authorless
        login.isHidden = authorless || (!panel && metaWidth < 320)
        if !avatar.isHidden {
            avatar.frame = NSRect(x: mx, y: y2 + 1.25, width: 14, height: 14)
            mx += 14 + 4
            if !login.isHidden {
                let w = min(ceil(login.textWidth) + 1, (panel ? 112 : 160) - 18)
                login.frame = NSRect(x: mx, y: y2, width: w, height: 16)
                mx += w + 6
            } else { mx += 2 }
        }
        let rw = min(ceil(repository.textWidth) + 1, max(0, metaRight - mx), panel && !authorless ? 128 : .greatestFiniteMagnitude)
        repository.frame = NSRect(x: mx, y: y2, width: rw, height: 16)
        mx += rw + 6
        branches.isHidden = branches.text.isEmpty
        if !branches.isHidden {
            branches.frame = NSRect(x: mx, y: y2, width: min(ceil(branches.textWidth) + 1, max(0, metaRight - mx)), height: 16)
            mx = branches.frame.maxX + 6
        }
        // Label slots at `@xl` (576) and `@3xl` (768).
        let slots = metaWidth >= 768 ? 3 : metaWidth >= 576 ? 2 : 1
        let shown = min(slots, labelChips.count)
        for (i, chip) in labelChips.enumerated() {
            guard i < shown, let entry else { chip.isHidden = true; continue }
            chip.isHidden = false
            let remaining = entry.labels.count - i - 1
            if i == shown - 1, remaining > 0 {
                let replacement = PullRequestLabelChip.make(entry.labels[i], overflow: remaining)
                chip.title = replacement.title
            } else {
                chip.title = entry.labels[i].name
            }
            let cw = min(160, ceil(chip.intrinsicContentSize.width), max(0, metaRight - mx))
            chip.frame = NSRect(x: mx, y: y2 + 0.25, width: cw, height: 16)
            mx += cw + 4
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let fill: NSColor? = selected ? Themed.color(\.accent) : hovered ? Themed.color(\.accent, 0.6) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        guard let entry, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(entry)
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let entry, number.frame.insetBy(dx: -2, dy: -2).contains(convert(event.locationInWindow, from: nil)) else { return }
        onNumberMenu?(entry, event)
    }
    override func accessibilityPerformPress() -> Bool { if let entry { onSelect?(entry) }; return true }
}

/// "matched in the description" (PullRequestRow.tsx:189-202): a search glyph in a rounded border,
/// the words from `@xs/pr-row-meta`.
final class MatchedElsewhereView: DSView {
    private let icon = IconView(name: .search, size: 12)
    private let label = LabelView("matched in the description", font: DSFont.ui(10))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        label.lineHeight = 14
        addSubview(icon); addSubview(label)
        toolTip = "Matched in the description"
    }
    func preferredWidth(metaWidth: CGFloat) -> CGFloat { metaWidth >= 320 ? 4 + 12 + 4 + ceil(label.textWidth) + 4 + 2 : 24 }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 5, y: 2, width: 12, height: 12)
        label.isHidden = bounds.width < 30
        label.frame = NSRect(x: 21, y: 1, width: max(0, bounds.width - 25), height: 14)
    }
    override func updateLayer() {
        layer?.borderColor = Themed.color(\.border, 0.6).cgColor(in: self)
        icon.strokeColor = Themed.color(\.mutedForeground)
        label.color = Themed.color(\.mutedForeground)
    }
}

/// The Filters button's count (`rounded-full bg-muted px-1.5 text-xs text-muted-foreground`).
final class CountPill: DSView {
    private let label = LabelView("", font: DSFont.ui(12))
    var count = 0 { didSet { label.text = "\(count)"; invalidateIntrinsicContentSize(); needsLayout = true } }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); label.lineHeight = 16; addSubview(label) }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 12, height: 16) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2; label.frame = NSRect(x: 6, y: 0, width: bounds.width - 12 + 1, height: 16) }
    override func updateLayer() { layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self); label.color = Themed.color(\.mutedForeground) }
}

/// A centered `flex flex-wrap justify-center gap-2` of buttons, as an `EmptyContent`.
final class ButtonRow: DSView {
    let buttons: [ButtonView]
    init(_ buttons: [ButtonView]) {
        self.buttons = buttons
        super.init(frame: .zero)
        buttons.forEach(addSubview)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: buttons.map { ceil($0.intrinsicContentSize.width) }.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * 8,
               height: buttons.map(\.intrinsicContentSize.height).max() ?? 0)
    }
    override func layout() {
        super.layout()
        var x = (bounds.width - intrinsicContentSize.width) / 2
        for b in buttons {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: 0, width: ceil(s.width), height: s.height)
            x += ceil(s.width) + 8
        }
    }
}

/// The warning row over a list that failed to refresh (`rounded-lg border border-warning/30
/// bg-warning-surface px-3 py-2 text-xs`) with Retry.
final class BannerView: DSView {
    private let label = TextBlockView()
    let retry = ButtonView("Retry", variant: .outline, size: .xs)
    var text = "" { didSet { label.text = text + " Showing the last pull requests loaded."; needsLayout = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        label.font = DSFont.ui(12)
        label.lineHeight = 16
        addSubview(label)
        addSubview(retry)
    }
    func height(forWidth w: CGFloat) -> CGFloat { max(24, label.height(forWidth: w - 24 - 12 - ceil(retry.intrinsicContentSize.width))) + 16 }
    override func layout() {
        super.layout()
        let rw = ceil(retry.intrinsicContentSize.width)
        retry.frame = NSRect(x: bounds.width - 12 - rw, y: (bounds.height - 24) / 2, width: rw, height: 24)
        let lw = bounds.width - 24 - 12 - rw
        label.frame = NSRect(x: 12, y: 8, width: lw, height: label.height(forWidth: lw))
    }
    override func updateLayer() {
        layer?.borderColor = Themed.color(\.warning, 0.3).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.warningSurface).cgColor(in: self)
        label.color = Themed.color(\.foreground)
    }
}

/// `PullRequestListGhost` (PullRequestGhosts.tsx:58-93): skeleton rows, the caption where a group
/// header would speak.
final class PullRequestListGhostView: DSView {
    static let titleWidths: [CGFloat] = [0.72, 0.56, 0.64, 0.48, 0.68, 0.52, 0.6]
    static let metaWidths: [CGFloat] = [0.4, 0.32, 0.36, 0.28, 0.44, 0.3, 0.38]
    private let rows: Int
    private let caption: LabelView?
    private var bars: [SkeletonView] = []

    init(rows: Int, caption: String?) {
        self.rows = rows
        self.caption = caption.map { LabelView($0, font: DSFont.ui(12, weight: .medium)) }
        super.init(frame: .zero)
        if let c = self.caption { c.lineHeight = 16; addSubview(c) }
        for _ in 0..<(rows * 5) { let b = SkeletonView(shape: .pill); bars.append(b); addSubview(b) }
        setAccessibilityLabel(caption ?? "Loading pull requests")
    }

    var height: CGFloat { (caption == nil ? 0 : 20) + CGFloat(rows) * 56 + CGFloat(rows - 1) * 2 }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let caption { caption.frame = NSRect(x: 12, y: 0, width: bounds.width - 24, height: 16); y = 20 }
        let w = bounds.width
        for i in 0..<rows {
            let b = Array(bars[(i * 5)..<(i * 5 + 5)])
            let inner = w - 24 - 16 - 8 - 8 - 64
            b[0].frame = NSRect(x: 12, y: y + 20, width: 16, height: 16)
            b[0].layer?.cornerRadius = 8
            b[1].frame = NSRect(x: 36, y: y + 10, width: inner * Self.titleWidths[i % 7], height: 16)
            b[2].frame = NSRect(x: 36, y: y + 32, width: inner * Self.metaWidths[i % 7], height: 14)
            b[3].frame = NSRect(x: w - 12 - 48, y: y + 13, width: 48, height: 12)
            b[4].frame = NSRect(x: w - 12 - 64, y: y + 31, width: 64, height: 12)
            y += 58
        }
    }

    override func updateLayer() { caption?.color = Themed.color(\.mutedForeground, 0.7) }
}

/// `BranchMark` (PullRequestListEmptyState.tsx:24-73): the base line and a branch stopped short of
/// rejoining it, 128 by 80 on a 120 by 72 view box.
final class BranchMarkView: DSView {
    private let joined: Bool
    private let base = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let branch = CAShapeLayer()
    private let dashed = CAShapeLayer()
    private let node = CAShapeLayer()

    init(joined: Bool) {
        self.joined = joined
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 80))
        for l in [base, dots, branch, dashed, node] {
            l.lineCap = .round; l.lineJoin = .round; l.fillColor = nil
            l.actions = ["path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull()]
            layer?.addSublayer(l)
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 80) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // `preserveAspectRatio` meet: 120x72 into 128x80 scales by 1.0667 (width bound), centered.
        let s = min(bounds.width / 120, bounds.height / 72)
        var t = CGAffineTransform(translationX: (bounds.width - 120 * s) / 2, y: (bounds.height - 72 * s) / 2).scaledBy(x: s, y: s)
        let basePath = CGMutablePath(); basePath.move(to: CGPoint(x: 10, y: 58)); basePath.addLine(to: CGPoint(x: 110, y: 58))
        base.path = basePath.copy(using: &t)
        let dotPath = CGMutablePath()
        dotPath.addEllipse(in: CGRect(x: 5, y: 53, width: 10, height: 10))
        dotPath.addEllipse(in: CGRect(x: 105, y: 53, width: 10, height: 10))
        dots.path = dotPath.copy(using: &t)
        let b = CGMutablePath()
        if joined {
            b.move(to: CGPoint(x: 30, y: 58)); b.addCurve(to: CGPoint(x: 54, y: 32), control1: CGPoint(x: 30, y: 40), control2: CGPoint(x: 38, y: 32))
            b.addLine(to: CGPoint(x: 66, y: 32)); b.addCurve(to: CGPoint(x: 90, y: 58), control1: CGPoint(x: 82, y: 32), control2: CGPoint(x: 90, y: 40))
        } else {
            b.move(to: CGPoint(x: 30, y: 58)); b.addCurve(to: CGPoint(x: 54, y: 32), control1: CGPoint(x: 30, y: 40), control2: CGPoint(x: 38, y: 32))
            b.addLine(to: CGPoint(x: 58, y: 32))
            let d = CGMutablePath()
            d.move(to: CGPoint(x: 90, y: 58)); d.addCurve(to: CGPoint(x: 66, y: 32), control1: CGPoint(x: 90, y: 40), control2: CGPoint(x: 82, y: 32))
            d.addLine(to: CGPoint(x: 62, y: 32))
            dashed.path = d.copy(using: &t)
        }
        branch.path = b.copy(using: &t)
        let r: CGFloat = joined ? 5 : 4
        node.path = CGPath(ellipseIn: CGRect(x: 60 - r, y: 32 - r, width: 2 * r, height: 2 * r), transform: &t)
        for l in [base, dots, branch, dashed, node] { l.lineWidth = 2 * s }
        dashed.lineDashPattern = [NSNumber(value: Double(2 * s)), NSNumber(value: Double(7 * s))]
        dashed.isHidden = joined
    }

    override func updateLayer() {
        // `text-muted-foreground/60`; the base `/30`; the dashed half `/50`; the open node `/45`.
        let c60 = Themed.color(\.mutedForeground, 0.6)
        base.strokeColor = Themed.color(\.mutedForeground, 0.3).cgColor(in: self)
        dots.strokeColor = c60.cgColor(in: self)
        dots.fillColor = Themed.color(\.mutedForeground, 0.6 * 0.25).cgColor(in: self)
        branch.strokeColor = c60.cgColor(in: self)
        dashed.strokeColor = Themed.color(\.mutedForeground, 0.5).cgColor(in: self)
        node.strokeColor = (joined ? c60 : Themed.color(\.mutedForeground, 0.45)).cgColor(in: self)
        node.fillColor = joined ? Themed.color(\.mutedForeground, 0.6 * 0.25).cgColor(in: self) : nil
    }
}
