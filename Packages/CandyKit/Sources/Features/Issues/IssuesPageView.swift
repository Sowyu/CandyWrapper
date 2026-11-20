import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The Issues page (4928 apps/web/src/components/issue/IssuesPage.tsx): the 52pt header with the
/// title and the right panel toggle, then a `max-w-6xl` page whose first row is the search, Sort,
/// Filters, Views, the tracker menu and refresh, and under it one section per tracker account. It
/// is the Pull Requests page's column in T3, so it reuses that page's controls, ghost, banner and
/// empty states. `IssuesPageContainer` puts the page's own right panel beside it.
public final class IssuesPageView: DSView {
    /// What the list body shows (`listBody`, IssuesPage.tsx:475-603).
    public enum Body: Equatable, Sendable {
        /// No environment has the `issues` capability.
        case unsupported
        case ghost
        /// Every read failed: the message, and whether a retry is running.
        case unavailable(message: String, retrying: Bool)
        /// "No trackers to read".
        case noTrackers
        case list
    }

    public struct Model: Equatable, Sendable {
        public var body: Body = .ghost
        public var groups: [IssueListLogic.Group] = []
        /// The debounced search, which says "Nothing matches that." in an empty group.
        public var query = ""
        public var searchBusy = false
        public var refreshing = false
        public var errorBanner: String?
        /// `environmentId \u{0} entryKey` of the issue the panel shows.
        public var selectedKey: String?
        /// "environmentId host" while that group's next page loads.
        public var loadingMore: String?
        public var moreFailures: [String: String] = [:]
        /// Server names per environment, when the list spans more than one.
        public var environmentLabels: [String: String] = [:]
        // Controls.
        public var state = "open"
        public var involvement = "all"
        public var sort = "updated"
        public var host: String?
        public var hostOptions: [IssueListLogic.HostOption] = []
        public var projectKey: String?
        public var projects: [ProjectOption] = []
        public var labels: [String] = []
        public var assignee: String?
        /// The scopes' labels and people for the filter menu, read when it opens.
        public var labelCandidates: [IssueCandidates.Label] = []
        public var assigneeCandidates: [PullRequestActor] = []
        public var candidatesLoading = false
        public var candidatesFailed = false
        public var candidatesTruncated = false
        public var panelOpen = false
        public var panelAvailable = false
        public var nowMs: Int64 = 0
        public init() {}

        /// The Filters count (IssueListFilterPickers.tsx:58-64).
        public var filterCount: Int {
            [state != "open", involvement != "all", projectKey != nil, assignee != nil].filter { $0 }.count + labels.count
        }
    }

    public struct ProjectOption: Equatable, Sendable {
        public var key: String
        public var title: String
        public var icon: ProjectIconSource?
        public init(key: String, title: String, icon: ProjectIconSource? = nil) { self.key = key; self.title = title; self.icon = icon }
    }

    public var model = Model() { didSet { if model != oldValue { apply(old: oldValue) } } }

    public var onQuery: ((String) -> Void)?
    public var onQuerySubmit: ((String) -> Void)?
    public var onSort: ((String) -> Void)?
    public var onState: ((String) -> Void)?
    public var onInvolvement: ((String) -> Void)?
    public var onHost: ((String?) -> Void)?
    public var onProject: ((String?) -> Void)?
    public var onLabels: (([String]) -> Void)?
    public var onAssignee: ((String?) -> Void)?
    /// The Filters menu is opening: read the scopes' candidates.
    public var onFiltersOpen: (() -> Void)?
    public var onRefresh: (() -> Void)?
    public var onRetry: (() -> Void)?
    public var onLoadMore: ((_ environmentId: String, _ host: String) -> Void)?
    public var onSelect: ((IssueListLogic.Row) -> Void)?
    public var onTogglePanel: (() -> Void)?

    public let header = SettingsHeaderView()
    public let search = InputGroupView(placeholder: "Search issues", leading: .icon(.search))
    let sortButton = ButtonView("Sort", icon: .arrowDownUp, variant: .outline).menuTrigger()
    let filtersButton = ButtonView("Filters", icon: .listFilter, variant: .outline).menuTrigger()
    let filterCount = CountPill()
    public let views = SavedViewsMenuController(kind: .issues)
    let trackerButton = ButtonView("All", icon: .plug2, variant: .outline).menuTrigger()
    let refreshButton = ButtonView(nil, icon: .refreshCw, variant: .outline, size: .icon)
    /// `PanelLayoutControls`' right panel toggle; "Select an issue first" until one is picked.
    let panelToggle = ButtonView(nil, icon: .panelRight, variant: .ghost, size: .iconSm)
    private let document = PullRequestsPageView.Document()
    private let scroll: ScrollAreaView
    private var bodyView: NSView?
    private let banner = BannerView()
    private var sections: [String: IssueGroupView] = [:]
    private var sectionOrder: [String] = []
    public var contentInsetRight: CGFloat = 0 { didSet { needsLayout = true } }

    public override init(frame frameRect: NSRect) {
        scroll = ScrollAreaView(documentView: document, scrollbars: .native)
        super.init(frame: frameRect)
        header.plainTitle = "Issues"
        addSubview(scroll)
        addSubview(header)
        addSubview(panelToggle)
        search.input.setAccessibilityLabel("Search issues")
        search.input.onChange = { [weak self] text in self?.onQuery?(text) }
        search.input.onSubmit = { [weak self] in guard let self else { return }; onQuerySubmit?(search.input.text) }
        sortButton.setAccessibilityLabel("Sort issues")
        trackerButton.setAccessibilityLabel("Filter by tracker")
        refreshButton.setAccessibilityLabel("Refresh issues")
        refreshButton.toolTip = "Refresh issues"
        panelToggle.iconSize = 16
        banner.suffix = " Showing the issues that loaded."
        for v in [search, sortButton, filtersButton, views.button, trackerButton, refreshButton, banner] as [NSView] { document.addSubview(v) }
        sortButton.action = { [weak self] in self?.showSortMenu() }
        filtersButton.action = { [weak self] in self?.onFiltersOpen?(); self?.showFiltersMenu() }
        trackerButton.action = { [weak self] in self?.showTrackerMenu() }
        refreshButton.action = { [weak self] in self?.onRefresh?() }
        banner.retry.action = { [weak self] in self?.onRetry?() }
        panelToggle.action = { [weak self] in self?.onTogglePanel?() }
        views.onResize = { [weak self] in self?.needsLayout = true }
        apply(old: nil)
    }

    public override var acceptsFirstResponder: Bool { true }

    public func focusSearch() { window?.makeFirstResponder(search.input) }

    // MARK: Model

    private func apply(old: Model?) {
        let m = model
        search.leading = m.searchBusy ? .icon(.loaderCircle) : .icon(.search)
        filterCount.count = m.filterCount
        filtersButton.accessory = m.filterCount > 0 ? filterCount : nil
        let hostOption = m.hostOptions.first { $0.value == (m.host ?? "") } ?? m.hostOptions.first
        trackerButton.title = hostOption?.label ?? "All"
        trackerButton.icon = hostOption?.tracker.map(IssueListLogic.trackerIcon) ?? .plug2
        trackerButton.setAccessibilityLabel("Filter by tracker: \(hostOption?.label ?? "All")")
        trackerButton.isHidden = m.hostOptions.count <= 1
        refreshButton.isEnabled = !m.refreshing
        panelToggle.isEnabled = m.panelAvailable
        panelToggle.toolTip = m.panelAvailable ? (m.panelOpen ? "Close right panel" : "Open right panel") : "Select an issue first"
        panelToggle.setAccessibilityLabel(panelToggle.toolTip)
        views.preferences = preferences
        rebuildBody(old: old)
        needsLayout = true
    }

    /// The list controls a saved view keeps (`issueListPreferences`, issueListPreferences.ts:55-77).
    public var preferences: [String: JSONValue] {
        var p: [String: JSONValue] = ["who": .string(model.involvement), "status": .string(model.state)]
        if let k = model.projectKey { p["project"] = .string(k) }
        if let h = model.host { p["host"] = .string(h) }
        let q = search.input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { p["q"] = .string(q) }
        if !model.labels.isEmpty { p["label"] = .array(model.labels.map { .string($0) }) }
        if let a = model.assignee { p["assignee"] = .string(a) }
        if model.sort == "created" { p["order"] = .string("created") }
        return p
    }

    private func rebuildBody(old: Model?) {
        let m = model
        if old?.body != m.body || (bodyView == nil && m.body != .list) {
            bodyView?.removeFromSuperview()
            bodyView = nil
            switch m.body {
            case .unsupported:
                bodyView = EmptyView(title: "Issues unavailable", message: "Update this environment's T3 Code server to browse issues.", icon: .circleDot)
            case .ghost:
                bodyView = PullRequestListGhostView(rows: 7, caption: nil)
            case .unavailable(let message, let retrying):
                let empty = EmptyView(title: "Could not load issues", message: message, icon: .circleDot)
                let b = ButtonView(retrying ? "Retrying…" : "Retry", icon: .refreshCw, variant: .outline, size: .sm)
                b.isEnabled = !retrying
                b.action = { [weak self] in self?.onRetry?() }
                empty.content = ButtonRow([b])
                bodyView = empty
            case .noTrackers:
                let empty = EmptyView(title: "No trackers to read", message: "Add a project whose remote is on a supported tracker.", icon: .circleDot)
                empty.mediaOutsideHeader = true
                bodyView = empty
            case .list:
                bodyView = nil
            }
            if let bodyView { document.addSubview(bodyView) }
        }
        guard m.body == .list else {
            sections.values.forEach { $0.removeFromSuperview() }
            sections = [:]; sectionOrder = []
            return
        }
        let showTracker = m.groups.count > 1
        var keep = Set<String>()
        sectionOrder = m.groups.map(\.key)
        for group in m.groups {
            keep.insert(group.key)
            let view = sections[group.key] ?? {
                let v = IssueGroupView()
                v.onSelect = { [weak self] row in self?.onSelect?(row) }
                v.onLoadMore = { [weak self] env, host in self?.onLoadMore?(env, host) }
                document.addSubview(v)
                sections[group.key] = v
                return v
            }()
            view.set(group, query: m.query, selectedKey: m.selectedKey, showTracker: showTracker,
                     environmentLabels: m.environmentLabels, loadingMore: m.loadingMore, moreFailures: m.moreFailures, nowMs: m.nowMs)
        }
        for (key, v) in sections where !keep.contains(key) { v.removeFromSuperview(); sections[key] = nil }
    }

    // MARK: Menus

    private func showSortMenu() {
        let options: [(String, String, IconName)] = [("updated", "Recently updated", .clock), ("created", "Newest", .calendarArrowDown)]
        let items = options.map { value, label, icon -> MenuItem in
            var item = MenuItem.radio(label, checked: model.sort == value) { [weak self] _ in self?.onSort?(value) }
            item.icon = icon
            item.closesOnClick = true
            return item
        }
        MenuPopupView.show(items, from: sortButton, placement: .dropdown)
    }

    private func showTrackerMenu() {
        let items = model.hostOptions.map { o -> MenuItem in
            var item = MenuItem.radio(o.label, checked: o.value == (model.host ?? "")) { [weak self] _ in self?.onHost?(o.value.isEmpty ? nil : o.value) }
            item.icon = o.tracker.map(IssueListLogic.trackerIcon) ?? .plug2
            item.closesOnClick = true
            item.isDisabled = o.unavailable != nil
            item.tooltip = o.unavailable
            return item
        }
        MenuPopupView.show(items, from: trackerButton, placement: .dropdown)
    }

    /// `IssueFiltersMenu` (IssueListFilterPickers.tsx:31-163): State, Involvement, Project (two or
    /// more), then Labels and Assignee from the scopes' candidates.
    // ponytail: the candidate submenus list the first 30 without their search field; add the
    // `MenuSearchInput` once MenuPopupView hosts a field
    func showFiltersMenu() {
        let m = model
        func radios(_ label: String, _ options: [(String, String, IconName)], _ value: String, _ pick: @escaping (String) -> Void) -> MenuItem {
            let current = options.first { $0.0 == value } ?? options[0]
            var sub = [MenuItem.label(label)]
            sub += options.map { o in
                var item = MenuItem.radio(o.1, checked: o.0 == value) { _ in pick(o.0) }
                item.icon = o.2
                item.closesOnClick = true
                return item
            }
            var item = MenuItem.submenu(label, icon: current.2, sub)
            item.trailingDetail = current.1
            return item
        }
        var items: [MenuItem] = [
            radios("State", [("open", "Open", .circleDot), ("closed", "Closed", .circleCheck), ("all", "All", .layers)], m.state) { [weak self] in self?.onState?($0) },
            radios("Involvement", [("all", "Everyone", .users), ("assigned", "Assigned to me", .userCheck), ("authored", "Opened by me", .penLine),
                                   ("mentioned", "Mentioning me", .atSign)], m.involvement) { [weak self] in self?.onInvolvement?($0) },
        ]
        if m.projects.count > 1 || m.projectKey != nil {
            var options: [(String, String, IconName)] = [("all", "All projects", .layers)]
            if let k = m.projectKey, !m.projects.contains(where: { $0.key == k }) { options.append((k, "Unavailable project", .folderGit2)) }
            options += m.projects.map { ($0.key, $0.title, IconName.folderGit2) }
            items.append(radios("Project", options, m.projectKey ?? "all") { [weak self] v in self?.onProject?(v == "all" ? nil : v) })
        }
        items.append(.separator)
        // Labels and Assignee filter as you type (4928 IssueListFilterPickers.tsx:170-294): chosen ones lead, so
        // one the first page lacks can still be cleared, and at most 30 show.
        let matches: @Sendable (String, [String?]) -> Bool = { needle, fields in needle.isEmpty || fields.contains { $0?.lowercased().contains(needle) == true } }
        let chosen = m.labels
        let labelItems: @MainActor (String) -> [MenuItem] = { [weak self] query in
            let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
            let found = m.labelCandidates.filter { matches(needle, [$0.name, $0.description]) }
            let names = chosen.filter { n in !found.contains { $0.name == n } } + found.map(\.name)
            var items: [MenuItem] = names.prefix(30).map { name in
                MenuItem.checkbox(name, checked: chosen.contains(name)) { [weak self] on in
                    let next = on ? Array((chosen + [name]).prefix(20)) : chosen.filter { $0 != name }
                    self?.onLabels?(next)
                }
            }
            if items.isEmpty, !m.candidatesLoading {
                items = [MenuItem(m.candidatesFailed ? "The labels could not be read" : "No labels found", disabled: true)]
            }
            if m.candidatesTruncated { items.append(MenuItem("More labels exist than are listed here.", disabled: true)) }
            _ = self
            return items
        }
        var labels = MenuItem.submenu("Labels", icon: .tag, labelItems(""))
        labels.submenuSearch = MenuSearch(placeholder: "Search labels", filter: labelItems)
        labels.trailingDetail = chosen.isEmpty ? "Any" : chosen.count == 1 ? chosen[0] : "\(chosen.count) labels"
        items.append(labels)
        let assigneeItems: @MainActor (String) -> [MenuItem] = { [weak self] query in
            let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
            var anyone = MenuItem.radio("Anyone", checked: m.assignee == nil) { [weak self] _ in self?.onAssignee?(nil) }
            anyone.icon = .layers
            anyone.closesOnClick = true
            let found = m.assigneeCandidates.filter { matches(needle, [$0.login, $0.name]) }
            var people = found.map { ($0.login, $0.name) }
            if let a = m.assignee, !found.contains(where: { $0.login == a }) { people.insert((a, nil), at: 0) }
            var items = [anyone] + people.prefix(30).map { login, name in
                var item = MenuItem.radio(login, checked: m.assignee == login) { [weak self] _ in self?.onAssignee?(login) }
                item.trailingDetail = name
                item.closesOnClick = true
                return item
            }
            if people.isEmpty, !m.candidatesLoading, m.candidatesFailed { items.append(MenuItem("The people could not be read", disabled: true)) }
            if m.candidatesTruncated { items.append(MenuItem("More people exist than are listed here.", disabled: true)) }
            _ = self
            return items
        }
        var assignee = MenuItem.submenu("Assignee", icon: .userRound, assigneeItems(""))
        assignee.submenuSearch = MenuSearch(placeholder: "Search people", filter: assigneeItems)
        assignee.trailingDetail = m.assignee ?? "Anyone"
        items.append(assignee)
        MenuPopupView.show(items, from: filtersButton, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let width = max(0, bounds.width - contentInsetRight)
        header.frame = NSRect(x: 0, y: 0, width: width, height: 52)
        panelToggle.frame = NSRect(x: width - 12 - 28, y: 12, width: 28, height: 28)
        scroll.frame = NSRect(x: 0, y: 52, width: width, height: max(0, bounds.height - 52))
        layoutDocument(width: scroll.bounds.width)
    }

    private func layoutDocument(width: CGFloat) {
        // `scrollbar-gutter-both` 6px, `max-w-6xl`, `px-6 pt-6 pb-12`, `gap-4`.
        let inner = max(0, width - 12)
        let container = min(1152, inner)
        let x0 = 6 + (inner - container) / 2 + 24
        let w = max(0, container - 48)
        var y: CGFloat = 24
        let buttons: [ButtonView] = [sortButton, filtersButton, views.button, trackerButton, refreshButton].filter { !$0.isHidden }
        let widths = buttons.map { ceil($0.intrinsicContentSize.width) }
        let buttonsWidth = widths.reduce(0, +) + CGFloat(buttons.count - 1) * 8
        // The search takes its own line under `@lg/issue-list` (512).
        if w >= 512 {
            let sw = max(192, w - buttonsWidth - 8)
            search.frame = NSRect(x: x0, y: y, width: sw, height: 32)
            var bx = x0 + sw + 8
            for (b, bw) in zip(buttons, widths) {
                if bx + bw > x0 + w + 0.5 { bx = x0; y += 40 }
                b.frame = NSRect(x: bx, y: y, width: bw, height: 32); bx += bw + 8
            }
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
        y += 16
        let viewportHeight = scroll.bounds.height
        if model.body == .list {
            if let error = model.errorBanner {
                banner.isHidden = false
                banner.text = error
                let bh = banner.height(forWidth: w)
                banner.frame = NSRect(x: x0, y: y, width: w, height: bh)
                y += bh + 24
            } else { banner.isHidden = true }
            for key in sectionOrder {
                guard let s = sections[key] else { continue }
                let h = s.height(forWidth: w)
                s.frame = NSRect(x: x0, y: y, width: w, height: h)
                y += h + 24
            }
            y -= 24
        } else {
            banner.isHidden = true
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
}

/// One tracker account's section (IssuesPage.tsx:519-600, `flex flex-col gap-1`): the heading, the
/// unconfigured detail, each project's error, the empty line, the rows and "Load more".
final class IssueGroupView: DSView {
    private let icon = IconView(name: .circleDot, size: 14)
    private var trackerIcon: IconName = .circleDot
    private let heading = LabelView("", font: DSFont.ui(12, weight: .medium))
    private let headingDetail = LabelView("", font: DSFont.ui(12))
    private var notes: [(TextBlockView, Bool)] = []
    private var rows: [String: IssueRowView] = [:]
    private var rowOrder: [String] = []
    private var moreButtons: [ButtonView] = []
    private var moreNotes: [LabelView] = []
    var onSelect: ((IssueListLogic.Row) -> Void)?
    var onLoadMore: ((String, String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.lineHeight = 16
        headingDetail.lineHeight = 16
        [icon, heading, headingDetail].forEach(addSubview)
    }

    func set(_ g: IssueListLogic.Group, query: String, selectedKey: String?, showTracker: Bool, environmentLabels: [String: String],
             loadingMore: String?, moreFailures: [String: String], nowMs: Int64) {
        let name = IssueListLogic.providerName(g.tracker.tracker)
        let next = IssueListLogic.trackerIcon(g.tracker.tracker)
        if next != trackerIcon {
            trackerIcon = next
            icon.removeFromSuperview()
            iconView?.removeFromSuperview()
            let v = IconView(name: next, size: 14, strokeColor: Themed.color(\.mutedForeground))
            addSubview(v)
            iconView = v
        }
        heading.text = name
        var detail = name.lowercased() != g.tracker.host ? " · \(g.tracker.host)" : ""
        detail += " · \(g.tracker.projectCount) \(g.tracker.projectCount == 1 ? "project" : "projects")"
        headingDetail.text = detail
        notes.forEach { $0.0.removeFromSuperview() }
        notes = []
        func note(_ text: String, error: Bool) {
            let t = TextBlockView()
            t.text = text
            t.font = DSFont.ui(error ? 12 : 14)
            t.lineHeight = error ? 16 : 20
            addSubview(t)
            notes.append((t, error))
        }
        if !g.tracker.configured { note(g.tracker.detail ?? "This tracker cannot be read right now.", error: false) }
        for e in g.errors { note("\(e.projectTitle): \(e.message)", error: true) }
        if g.tracker.configured && g.rows.isEmpty && g.errors.isEmpty { note(query.isEmpty ? "No issues under these filters." : "Nothing matches that.", error: false) }
        let showScope = Set(g.rows.map { $0.entry.scope.lowercased() }).count > 1
        var keep = Set<String>()
        rowOrder = []
        for row in g.rows {
            let key = "\(row.environmentId)\u{0}\(row.key)"
            keep.insert(key)
            rowOrder.append(key)
            let view = rows[key] ?? {
                let r = IssueRowView()
                r.onSelect = { [weak self] row in self?.onSelect?(row) }
                addSubview(r)
                rows[key] = r
                return r
            }()
            view.configure(row, selected: selectedKey == key, showScope: showScope, showTracker: showTracker,
                           environmentLabel: environmentLabels.count > 1 ? environmentLabels[row.environmentId] : nil, nowMs: nowMs)
        }
        for (key, r) in rows where !keep.contains(key) { r.removeFromSuperview(); rows[key] = nil }
        moreButtons.forEach { $0.removeFromSuperview() }
        moreNotes.forEach { $0.removeFromSuperview() }
        moreNotes = []
        moreButtons = g.more.map { env in
            if let failure = moreFailures[env] {
                let l = LabelView(failure, font: DSFont.ui(12), color: Themed.color(\.destructive))
                l.lineHeight = 16
                addSubview(l)
                moreNotes.append(l)
            }
            let loading = loadingMore == "\(env) \(g.tracker.host)"
            let b = ButtonView(loading ? "Loading…" : moreFailures[env] == nil ? "Load more" : "Retry", variant: .ghostMuted, size: .sm)
            b.isEnabled = loadingMore == nil
            b.action = { [weak self] in self?.onLoadMore?(env, g.tracker.host) }
            addSubview(b)
            return b
        }
        needsLayout = true
    }

    private var iconView: IconView?

    func height(forWidth width: CGFloat) -> CGFloat {
        var parts: [CGFloat] = [16]
        parts += notes.map { $0.0.height(forWidth: width - 24) }
        parts += rowOrder.map { _ in IssueRowView.height }
        parts += moreNotes.map { _ in 16 }
        parts += moreButtons.map { _ in 32 }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * 4
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let iv = iconView ?? icon
        iv.frame = NSRect(x: 12, y: 1, width: 14, height: 14)
        let hw = ceil(heading.textWidth) + 1
        heading.frame = NSRect(x: 12 + 14 + 6, y: 0, width: hw, height: 16)
        headingDetail.frame = NSRect(x: 12 + 14 + 6 + hw, y: 0, width: max(0, w - 32 - hw - 12), height: 16)
        var y: CGFloat = 16 + 4
        for (t, _) in notes {
            let h = t.height(forWidth: w - 24)
            t.frame = NSRect(x: 12, y: y, width: w - 24, height: h)
            y += h + 4
        }
        for key in rowOrder {
            rows[key]?.frame = NSRect(x: 0, y: y, width: w, height: IssueRowView.height)
            y += IssueRowView.height + 4
        }
        var ni = 0
        for b in moreButtons {
            if ni < moreNotes.count { moreNotes[ni].frame = NSRect(x: 12, y: y, width: w - 24, height: 16); y += 20; ni += 1 }
            b.frame = NSRect(x: 0, y: y, width: ceil(b.intrinsicContentSize.width), height: 32)
            y += 36
        }
    }

    override func updateLayer() {
        heading.color = Themed.color(\.mutedForeground)
        headingDetail.color = Themed.color(\.mutedForeground)
        for (t, error) in notes { t.color = error ? Themed.color(\.destructive) : Themed.color(\.mutedForeground) }
    }
}

/// `IssueRow` (IssueRow.tsx), in the pull request row's shape: the state glyph, then the key in
/// mono and the title with the assignees' faces and the comment count on the right, and under it
/// the author, tracker, scope, server and up to three labels with the time on the right.
final class IssueRowView: DSView {
    static let height: CGFloat = 56
    /// Linked items' issue row (ThreadDetailsIssueRows.tsx non-compact, the panel row's `py-1 pr-1`).
    static let panelHeight: CGFloat = 44
    private var panel = false
    private var glyph = IconView(name: .circleDot, size: 16)
    private let number = LabelView("", font: DSFont.mono(12))
    private let title = LabelView("", font: DSFont.ui(14))
    private var faces: [PullRequestAvatarView] = []
    private let commentIcon = IconView(name: .messageSquare, size: 12)
    private let comments = LabelView("", font: DSFont.ui(12))
    private let author = PullRequestAvatarView()
    private let login = LabelView("", font: DSFont.ui(11))
    private var tracker = IconView(name: .circleDot, size: 12)
    private let scope = LabelView("", font: DSFont.ui(11))
    private let server = LabelView("", font: DSFont.ui(11))
    private var chips: [BadgeView] = []
    private let time = LabelView("", font: DSFont.ui(11))
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var selected = false
    private(set) var row: IssueListLogic.Row?
    var onSelect: ((IssueListLogic.Row) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 8
        number.lineHeight = 20
        title.lineHeight = 20
        comments.lineHeight = 16
        for l in [login, scope, server, time] { l.lineHeight = 16 }
        [glyph, number, title, commentIcon, comments, author, login, tracker, scope, server, time].forEach(addSubview)
        setAccessibilityRole(.button)
    }

    /// A thread's linked issue: the state glyph once the detail was read, the key, the title, then
    /// the tracker and scope (ThreadDetailsIssueRows.tsx:25-82).
    func configure(link: ThreadIssueLink, state: IssueState?) {
        panel = true
        let e = IssueListEntry(tracker: link.tracker, host: link.host, scope: link.scope, key: link.key, displayKey: link.displayKey,
                               title: link.title, url: link.url, author: nil, state: state ?? IssueState(category: "open", name: "Open"),
                               createdAt: link.linkedAt.raw, updatedAt: link.linkedAt.raw, projectId: link.projectId.rawValue, projectTitle: "")
        configure(IssueListLogic.Row(entry: e, environmentId: ""), selected: false, showScope: true, showTracker: true, environmentLabel: nil, nowMs: 0)
        if state == nil { glyph.strokeColor = Themed.color(\.mutedForeground) }
        author.isHidden = true
        login.isHidden = true
        time.isHidden = true
        chips.forEach { $0.isHidden = true }
        setAccessibilityLabel("Issue \(link.displayKey): \(link.title)")
    }

    func configure(_ r: IssueListLogic.Row, selected: Bool, showScope: Bool, showTracker: Bool, environmentLabel: String?, nowMs: Int64) {
        row = r
        self.selected = selected
        let e = r.entry
        glyph.removeFromSuperview()
        glyph = IconView(name: IssueListLogic.icon(e.state), size: 16, strokeColor: IssueListLogic.color(e.state))
        glyph.toolTip = e.state.name
        glyph.setAccessibilityLabel(e.state.name)
        addSubview(glyph)
        number.text = e.displayKey
        title.text = e.title
        faces.forEach { $0.removeFromSuperview() }
        faces = e.assignees.prefix(3).map { a in
            let v = PullRequestAvatarView()
            v.actor = a
            v.ring = Themed.color(\.background)
            v.toolTip = a.login
            addSubview(v)
            return v
        }
        commentIcon.isHidden = e.commentCount == 0
        comments.isHidden = e.commentCount == 0
        comments.text = "\(e.commentCount)"
        author.actor = e.author
        login.text = e.author?.login ?? "ghost"
        tracker.removeFromSuperview()
        tracker = IconView(name: IssueListLogic.trackerIcon(e.tracker), size: 12, strokeColor: Themed.color(\.mutedForeground))
        tracker.isHidden = !showTracker
        tracker.setAccessibilityLabel(IssueListLogic.providerName(e.tracker))
        addSubview(tracker)
        scope.isHidden = !showScope
        scope.text = e.scope
        server.isHidden = environmentLabel == nil
        server.text = environmentLabel ?? ""
        chips.forEach { $0.removeFromSuperview() }
        chips = e.labels.prefix(3).enumerated().map { i, label in
            PullRequestLabelChip.make(label, overflow: i == 2 && e.labels.count > 3 ? e.labels.count - 3 : 0)
        }
        chips.forEach(addSubview)
        time.text = TimestampFormat.formatRelativeTimeLabel(e.updatedAt, nowMs: nowMs)
        setAccessibilityLabel("\(e.displayKey) \(e.title)")
        restyle()
        needsLayout = true
        needsDisplay = true
    }

    private func restyle() {
        number.color = Themed.color(\.mutedForeground)
        title.color = Themed.color(\.foreground)
        for l in [comments, login, scope, server, time] { l.color = Themed.color(\.mutedForeground) }
        commentIcon.strokeColor = Themed.color(\.mutedForeground)
    }

    override func layout() {
        super.layout()
        let x0: CGFloat = panel ? 8 : 12, top: CGFloat = panel ? 4 : 10
        glyph.frame = NSRect(x: x0, y: top + 2, width: 16, height: 16)
        let lx = x0 + 16 + 8
        let lr = bounds.width - 12
        // Line 1: key, title, then the status cluster on the right.
        var r = lr
        if !comments.isHidden {
            let cw = ceil(comments.textWidth) + 1
            comments.frame = NSRect(x: r - cw, y: top + 2, width: cw, height: 16)
            commentIcon.frame = NSRect(x: r - cw - 2 - 12, y: top + 4, width: 12, height: 12)
            r -= cw + 14 + 8
        }
        if !faces.isEmpty {
            // `-space-x-1`: 16px faces overlapping by 4.
            let fw = CGFloat(faces.count) * 12 + 4
            for (i, f) in faces.enumerated() { f.frame = NSRect(x: r - fw + CGFloat(i) * 12, y: top + 2, width: 16, height: 16) }
            r -= fw + 8
        }
        let nw = ceil(number.textWidth) + 1
        number.frame = NSRect(x: lx, y: top, width: nw, height: 20)
        let tx = lx + nw + 5
        title.frame = NSRect(x: tx, y: top, width: max(0, min(ceil(title.textWidth) + 1, r - tx)), height: 20)
        // Line 2 (`text-2xs`).
        let y2 = top + 20
        let tmw = ceil(time.textWidth) + 1
        time.frame = NSRect(x: lr - tmw, y: y2, width: tmw, height: 16)
        let metaRight = lr - tmw - 6
        let metaWidth = lr - lx
        var mx = lx
        if !panel {
        author.frame = NSRect(x: mx, y: y2 + 1, width: 14, height: 14); mx += 14 + 4
        login.isHidden = metaWidth < 320
        if !login.isHidden {
            let w = min(ceil(login.textWidth) + 1, 142)
            login.frame = NSRect(x: mx, y: y2, width: w, height: 16); mx += w + 6
        } else { mx += 2 }
        }
        if !tracker.isHidden { tracker.frame = NSRect(x: mx, y: y2 + 2, width: 12, height: 12); mx += 12 + 6 }
        for l in [scope, server] where !l.isHidden {
            let w = min(ceil(l.textWidth) + 1, max(0, metaRight - mx))
            l.frame = NSRect(x: mx, y: y2, width: w, height: 16); mx += w + 6
        }
        // Labels from `@xl/issue-row-meta` (576).
        for chip in chips {
            chip.isHidden = panel || metaWidth < 576
            guard !chip.isHidden else { continue }
            let cw = min(160, ceil(chip.intrinsicContentSize.width), max(0, metaRight - mx))
            chip.frame = NSRect(x: mx, y: y2 + 0.25, width: cw, height: 16)
            mx += cw + 4
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = DesignGeometry.radius(8, in: self)
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
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let row, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(row)
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let row, let url = SafeExternalURL.parse(row.entry.url) else { return }
        NSWorkspace.shared.open(url)
    }
    override func accessibilityPerformPress() -> Bool { if let row { onSelect?(row) }; return true }
}

/// The Issues route's main area: the list column and beside it the page's own right panel, whose
/// tabs are the issues and pull requests opened from it (IssuesPage.tsx:747-860, `ISSUES_PANEL_REF`).
public final class IssuesPageContainer: DSView {
    public let page = IssuesPageView()
    public let toasts = ToastViewport()
    let rightPanel = RightPanelView()
    public var lazyIssue: LazyView<IssueDetailView> { rightPanel.lazyIssue }
    public var lazyPullRequest: LazyView<PullRequestDetailView> { rightPanel.lazyPullRequest }
    public private(set) var panelState = RightPanelState()
    public var onPanelChange: ((RightPanelState) -> Void)?
    public var issueStatus: [String: IssueState] {
        get { rightPanel.issueStatus }
        set { rightPanel.issueStatus = newValue }
    }
    public var pullRequestStatus: [String: PullRequestStateTone] {
        get { rightPanel.pullRequestStatus }
        set { rightPanel.pullRequestStatus = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(page)
        addSubview(rightPanel)
        addSubview(toasts)
        toasts.layer?.zPosition = 3
        rightPanel.isHidden = true
        rightPanel.filesAvailable = false
        rightPanel.diffAvailable = false
        lazyPullRequest.set(\.context, .page)
        rightPanel.onActivate = { [weak self] id in self?.mutate { $0.activate(id) } }
        rightPanel.onClose = { [weak self] id in self?.mutate { _ = $0.close(id) } }
        rightPanel.onCloseOthers = { [weak self] id in self?.mutate { _ = $0.closeOthers(id) } }
        rightPanel.onCloseToRight = { [weak self] id in self?.mutate { _ = $0.closeToRight(id) } }
        rightPanel.onCloseAll = { [weak self] in self?.mutate { _ = $0.closeAll() } }
        rightPanel.onMove = { [weak self] id, index in self?.mutate { $0.move(id, to: index) } }
    }

    public func mutate(_ change: (inout RightPanelState) -> Void) {
        var next = panelState
        change(&next)
        setPanelState(next)
        onPanelChange?(next)
    }

    public func setPanelState(_ state: RightPanelState) {
        panelState = state
        rightPanel.isHidden = !state.isOpen
        rightPanel.apply(state)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let open = panelState.isOpen
        let pw = open ? PullRequestsPageContainer.panelWidth(window: window?.frame.width ?? bounds.width, container: bounds.width) : 0
        page.frame = NSRect(x: 0, y: 0, width: bounds.width - pw, height: bounds.height)
        rightPanel.frame = NSRect(x: bounds.width - pw, y: 0, width: pw, height: bounds.height)
        toasts.frame = ToastViewport.frame(in: bounds, dither: ThemeRuntime.isDither(dark: effectiveAppearance.isDark))
    }

    public override var acceptsFirstResponder: Bool { true }
    public var onEscape: (() -> Void)?
    public override func cancelOperation(_ sender: Any?) { onEscape?() }
}
