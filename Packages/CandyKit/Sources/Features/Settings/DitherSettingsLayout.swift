import AppKit
import DesignSystem

/// Redesign's settings sections (docs/research/redesign-settings-ia.md). T3's pages stay as they are; each section
/// shows slices of them: whole pages, or some of a page's groups with some of their rows, retitled. Search ids,
/// stored settings and the wire stay T3's. Other themes keep T3's pages and nav.
public enum DitherSettingsSection: String, CaseIterable, Sendable {
    case project, general, appearance, notifications, keyboard
    case orchestrator, models, connectors, threads, scheduledTasks
    case projects, git, tools
    case machines, advanced, experimental, about

    public var label: String {
        switch self {
        case .project: "This project"
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .keyboard: "Keyboard"
        case .orchestrator: "Orchestrator"
        case .models: "Models and providers"
        case .connectors: "Connectors"
        case .threads: "Threads"
        case .scheduledTasks: "Scheduled tasks"
        case .projects: "Projects and worktrees"
        case .git: "Git and pull requests"
        case .tools: "Browser and devices"
        case .machines: "Machines and connections"
        case .advanced: "Advanced"
        case .experimental: "Experimental"
        case .about: "About"
        }
    }

    /// The line under the page title, after Capy's page descriptions.
    public var subtitle: String {
        switch self {
        case .project: "Name, icon, checkouts and overrides for the project picked in the scope."
        case .general: "How the composer, chat and diffs behave on this Mac."
        case .appearance: "Theme, colors, fonts and motion."
        case .notifications: "How you hear about threads that finish, fail or need you."
        case .keyboard: "Shortcuts for every command."
        case .orchestrator: "The thread that manages every thread on its machine, and the models it may pick."
        case .models: "The model new threads start with, and the agents that run them."
        case .connectors: "MCP servers and skills your Claude and Codex agents can use."
        case .threads: "How the sidebar sorts and settles threads, usage limits, and archived threads."
        case .scheduledTasks: "Prompts that run on a schedule."
        case .projects: "Where new threads start, and how worktrees are made and cleaned up."
        case .git: "Git, source control accounts, repository defaults and generated commit text."
        case .tools: "The built-in browser, simulators and window capture."
        case .machines: "This machine, your other machines, and the clients paired with them."
        case .advanced: "Background work, storage cleanup, diagnostics and legacy features."
        case .experimental: "Features still being built. They may change or go away."
        case .about: "Version, updates and licenses."
        }
    }

    var icon: IconName {
        switch self {
        case .project: .panelsTopLeft
        case .general: .settings2
        case .appearance: .palette
        case .notifications: .inbox
        case .keyboard: .keyboard
        case .orchestrator: .workflow
        case .models: .bot
        case .connectors: .plug2
        case .threads: .messagesSquare
        case .scheduledTasks: .calendarClock
        case .projects: .folder
        case .git: .gitBranch
        case .tools: .globe
        case .machines: .server
        case .advanced: .slidersHorizontal
        case .experimental: .flaskConical
        case .about: .info
        }
    }

    /// The nav, in labelled groups; the first has no label. "This project" shows only for a project scope.
    static let groups: [(label: String?, sections: [DitherSettingsSection])] = [
        (nil, [.general, .appearance, .notifications, .keyboard]),
        ("Agents", [.orchestrator, .models, .connectors, .threads, .scheduledTasks]),
        ("Workspace", [.project, .projects, .git, .tools]),
        ("System", [.machines, .advanced, .experimental, .about]),
    ]

    /// The content column: the two-pane pages keep T3's wide container.
    public var width: CGFloat { self == .models || self == .machines ? 1024 : 896 }

    /// What the section shows, top to bottom.
    public var slices: [DitherSettingsSlice] {
        typealias G = DitherSettingsSlice.Group
        switch self {
        case .project: return [.init(.projects)]
        case .general: return [
            .init(.general, scope: true, [G("behavior", "Composer and chat", rows: ["time-format", "response-streaming", "skills-in-slash-menu",
                                                                               "composer-rich-text", "composer-collapse", "send-shortcut",
                                                                               "follow-up-behavior"])]),
            .init(.general, [G("behavior", "Diffs and panels", rows: ["hide-whitespace-changes", "default-diff-file-state", "diff-layout",
                                                                      "proactive-panels"]),
                             G("confirmations", nil, rows: ["unpin-confirmation", "archive-confirmation", "delete-confirmation",
                                                            "quit-confirmation"])]),
        ]
        case .appearance: return [.init(.appearance)]
        case .notifications: return [.init(.general, [G("behavior", "Alerts", rows: ["thread-notifications", "in-app-notifications", "menu-bar"])])]
        case .keyboard: return [.init(.keybindings)]
        case .models: return [
            .init(.general, scope: true, [G("project-defaults", "New threads", rows: ["default-model", "default-permissions"]),
                                          G("text-generation", nil, rows: ["text-generation-model"])]),
            .init(.providers),
        ]
        case .threads: return [
            .init(.general, scope: true, [G("organization", "Sidebar", rows: ["project-grouping", "project-order", "working-shelf",
                                                                              "auto-settle-merged-threads", "auto-settle-inactive-threads",
                                                                              "days-before-auto-settle", "auto-settle-keep-pull-requests"])]),
            .init(.general, [G("organization", "Usage limits", rows: ["auto-resume-limited-threads", "snooze-limited-threads",
                                                                      "compact-idle-threads"])]),
            .init(.archive),
        ]
        case .scheduledTasks: return [.init(.scheduledTasks, scope: true)]
        case .orchestrator: return [.init(.orchestrator)]
        case .connectors: return [.init(.connectors)]
        case .experimental: return [.init(.experimental)]
        case .projects: return [
            .init(.general, scope: true, [G("project-defaults", "New threads", rows: ["new-threads", "worktree-submodules"]),
                                          G("projects-and-threads", "Projects", rows: ["start-from-origin", "add-project-starts-in"])]),
            .init(.storage, [G("storage-notice", nil), G("storage-worktrees", nil, rows: ["storage-worktrees-location", "storage-worktree-keep-when"])]),
        ]
        case .git: return [.init(.sourceControl, scope: true)]
        case .tools: return [.init(.integrations, scope: true), .init(.snapShots)]
        case .machines: return [.init(.connections)]
        case .advanced: return [
            .init(.general, scope: true, [G("behavior", "Background work", rows: ["provider-update-checks", "continue-threads-after-server-update",
                                                                                  "background-activity"]),
                                          G("Diagnostics", nil, rows: ["diagnostics"], also: ["telemetry-export"]),
                                          G("legacy-features", nil, also: ["legacy-plan-mode", "legacy-context-window-indicator", "legacy-sidebar"])]),
            .init(.storage, [G("storage-notice", nil), G("storage-database", nil),
                             G("storage-cleanup", nil, also: ["storage-delete-now", "storage-cleanup-last-run"]), G("storage-artifacts", nil)]),
        ]
        case .about: return [
            .init(.general, [G("about", "Version and updates", also: ["app-version", "update-track", "privacy-policy", "nightly-mobile-beta", "cli-command"]),
                             G("Diagnostics", "Licenses", rows: ["open-source-licenses"])]),
        ]
        }
    }

    /// The section a T3 page opens in (deep links such as "Open provider setup"). Diagnostics and Open source
    /// licenses stay pages of their own, reached from Advanced and About.
    public static func home(of page: SettingsSection) -> DitherSettingsSection? {
        switch page {
        case .projects: .project
        case .general: .general
        case .appearance: .appearance
        case .keybindings: .keyboard
        case .snapShots, .integrations: .tools
        case .providers: .models
        case .scheduledTasks: .scheduledTasks
        case .sourceControl: .git
        case .storage: .advanced
        case .connections: .machines
        case .archive: .threads
        case .orchestrator: .orchestrator
        case .connectors: .connectors
        case .experimental: .experimental
        case .diagnostics, .licenses: nil
        }
    }

    /// The section that shows a search result: the slice that names its anchor, else the one with the whole page.
    public static func home(of page: SettingsSection, anchor: String) -> DitherSettingsSection? {
        for section in allCases {
            for slice in section.slices where slice.page == page {
                guard let groups = slice.groups else { return section }
                if groups.contains(where: { $0.key == anchor || $0.rows?.contains(anchor) == true || $0.also.contains(anchor) }) { return section }
            }
        }
        return home(of: page)
    }

    /// Where Escape goes from a page reached inside a section.
    public static func parent(of page: SettingsSection) -> DitherSettingsSection? {
        switch page {
        case .diagnostics: .advanced
        case .licenses: .about
        default: nil
        }
    }
}

/// Part of a T3 page shown in a Redesign section.
public struct DitherSettingsSlice: Sendable {
    /// A group of the page, by search anchor or title, with the rows to keep and an optional new title.
    public struct Group: Sendable {
        public let key: String
        public let title: String?
        /// The rows kept, by search anchor; a row without one goes with the row above it. Nil keeps them all.
        public let rows: [String]?
        /// Search anchors inside a group kept whole, so search knows where they land.
        public let also: [String]
        init(_ key: String, _ title: String?, rows: [String]? = nil, also: [String] = []) {
            self.key = key; self.title = title; self.rows = rows; self.also = also
        }
    }

    public let page: SettingsSection
    /// Nil shows the whole page.
    public let groups: [Group]?
    /// Shows the page's scope picker; a section shows it once, above its server settings.
    public let showsScope: Bool

    init(_ page: SettingsSection, scope: Bool = false, _ groups: [Group]? = nil) {
        self.page = page; self.groups = groups; self.showsScope = scope
    }

    /// The pages a slice of a part of the page needs: its own instance, since a view has one parent.
    public var needsOwnPage: Bool { groups != nil }
}

/// A Redesign settings section: its slices' pages stacked like T3's sections, each filtered to its slice.
public final class DitherSettingsSectionView: DSView, SettingsGroupRow {
    public let section: DitherSettingsSection
    public let pages: [NSView & SettingsGroupRow]
    private let gap: CGFloat = 32

    /// `pages[i]` shows `section.slices[i]`; a partial slice's page must be its own instance.
    public init(section: DitherSettingsSection, pages: [NSView & SettingsGroupRow]) {
        precondition(pages.count == section.slices.count)
        self.section = section
        self.pages = pages
        super.init(frame: .zero)
        for (slice, page) in zip(section.slices, pages) {
            addSubview(page)
            if let stack = page as? SettingsStackView { Self.apply(slice, to: stack) }
        }
    }

    /// Filters a page to a slice: the scope picker only where the slice asks, the slice's groups, retitled, with their rows.
    static func apply(_ slice: DitherSettingsSlice, to page: SettingsStackView) {
        let scopeItems = (page as? SettingsPageBase)?.scopeItems ?? []
        let showsScope = slice.showsScope
        guard let groups = slice.groups else {
            page.itemFilter = { item in !scopeItems.contains { $0 === item } || showsScope }
            return
        }
        // Each item is keyed the first time the filter sees it, before any retitle, so a page that adds a
        // group later (Storage's database) still lands in its slice.
        var verdicts: [ObjectIdentifier: Bool] = [:]
        page.itemFilter = { [weak page] item in
            if scopeItems.contains(where: { $0 === item }) { return showsScope }
            if let known = verdicts[ObjectIdentifier(item)] { return known }
            guard let page else { return false }
            let ids = Dictionary(page.anchors.map { (ObjectIdentifier($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })
            let key = ids[ObjectIdentifier(item)] ?? (item as? SettingsSectionView)?.title ?? (item as? SettingsFoldedSectionView)?.title
            let group = key.flatMap { k in groups.first { $0.key == k } }
            verdicts[ObjectIdentifier(item)] = group != nil
            if let group, let s = item as? SettingsSectionView {
                if let title = group.title { s.title = title }
                if let rows = group.rows {
                    let keep = Set(rows)
                    s.group.rowFilter = { [weak g = s.group] row in
                        // A row without an anchor goes with the anchored row above it.
                        guard let all = g?.rows, let i = all.firstIndex(where: { $0 === row }) else { return false }
                        for r in all[...i].reversed() { if let id = ids[ObjectIdentifier(r)] { return keep.contains(id) } }
                        return false
                    }
                }
            }
            return group != nil
        }
        // Key the page's groups now, so titles and rows are set before the first layout.
        for item in page.items { _ = page.itemFilter?(item) }
    }

    public func refresh() { for p in pages { (p as? SettingsPageBase)?.refresh() } }
    public func didShow() { for p in pages { (p as? SettingsPageBase)?.didShow() } }

    /// The view a search result lands on: the anchor in the slice of `page` that shows it.
    public func anchor(_ id: String, page: SettingsSection) -> NSView? {
        for (slice, p) in zip(section.slices, pages) where slice.page == page {
            guard let stack = p as? SettingsStackView, let target = stack.anchor(id) else { continue }
            if Self.isShown(target, in: stack) { return target }
        }
        return nil
    }

    /// The view passes every filter between it and its page.
    static func isShown(_ view: NSView, in page: SettingsStackView) -> Bool {
        var v: NSView? = view
        while let child = v, child !== page {
            let parent = child.superview
            if let stack = parent as? SettingsStackView, let filter = stack.itemFilter, !filter(child) { return false }
            if let group = parent as? SettingsGroupView, let filter = group.rowFilter, !filter(child) { return false }
            v = parent
        }
        return v === page
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        let heights = pages.map { $0.height(forWidth: width) }.filter { $0 > 0 }
        return heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1))
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        for p in pages {
            let h = p.height(forWidth: bounds.width)
            p.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            p.needsLayout = true
            if h > 0 { y += h + gap }
        }
    }
}
