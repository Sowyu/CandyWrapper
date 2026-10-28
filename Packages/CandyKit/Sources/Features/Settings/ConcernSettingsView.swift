import AppKit
import DesignSystem

/// The 3814 page split, without its floating panel. SettingsPanels.tsx:735-2028,
/// WorktreesSettings.tsx:54-71 and IntegrationsSettings.tsx:1602-1648.
/// Slices retain the existing pages and their bindings, subscriptions and search anchors.
public final class ConcernSettingsView: SettingsPageBase {
    public let section: SettingsSection
    private let sources: [SettingsPageBase]
    public static let sections: Set<SettingsSection> = [.general, .chat, .diffs, .threads, .browser, .devices,
                                                       .worktrees, .maintenance, .about, .providers, .sourceControl]

    public init(context: SettingsPageContext, section: SettingsSection) {
        self.section = section
        let slices = Self.slices(section)
        sources = slices.map { slice in
            let groups = slice.groups.map { Set($0.map(\.key)) }
            return switch slice.page {
            case .appearance: AppearanceSettingsView(context: context, groups: groups)
            case .integrations: IntegrationsSettingsView(context: context, groups: groups)
            case .storage: StorageSettingsView(context: context)
            case .sourceControl: SourceControlSettingsView(context: context, discoveryEnabled: section == .sourceControl)
            case .providers: ProvidersSettingsView(context: context)
            default: GeneralSettingsView(context: context, groups: groups)
            }
        }
        super.init(context: context)
        let clientOnly = [.general, .chat, .diffs, .about].contains(section)
        for (slice, source) in zip(slices, sources) {
            (source as? GeneralSettingsView)?.usesBoundary = !clientOnly
            (source as? ScopedSettingsPage)?.usesBoundary = !clientOnly
            if section == .general { (source as? GeneralSettingsView)?.addWorkingShelfRow() }
            if let storage = source as? StorageSettingsView { storage.reportsEnabled = section == .maintenance }
            DitherSettingsSectionView.apply(slice, to: source)
            Self.orderRows(slice, source: source)
            source.onHeightChange = { [weak self] in self?.onHeightChange?() }
        }
        items = sources
    }

    public override func refresh() {
        sources.forEach { $0.refresh() }
        super.refresh()
    }
    public override func didShow() { sources.forEach { $0.didShow() } }
    public override func anchor(_ id: String) -> NSView? {
        for source in sources {
            if let target = source.anchor(id), DitherSettingsSectionView.isShown(target, in: source) { return target }
        }
        return super.anchor(id)
    }

    private static func orderRows(_ slice: DitherSettingsSlice, source: SettingsPageBase) {
        let ids = Dictionary(source.anchors.map { (ObjectIdentifier($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })
        for item in source.items {
            guard let group = item as? SettingsSectionView,
                  let rows = slice.groups?.first(where: { $0.title == group.title || source.anchors[$0.key] === group })?.rows else { continue }
            var preceding: String?
            let indexed = group.group.rows.enumerated().map { index, row -> (Int, Int, any SettingsGroupRow) in
                if let id = ids[ObjectIdentifier(row)] { preceding = id }
                return (preceding.flatMap { rows.firstIndex(of: $0) } ?? rows.count, index, row)
            }
            group.group.rows = indexed.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
        }
    }

    private static func slices(_ page: SettingsSection) -> [DitherSettingsSlice] {
        typealias G = DitherSettingsSlice.Group
        switch page {
        case .general: return [
            .init(.general, [G("behavior", "Notifications", rows: ["thread-notifications", "in-app-notifications", "menu-bar"])]),
            .init(.general, [G("organization", "Sidebar", rows: ["project-grouping", "project-order", "working-shelf"])]),
            .init(.general, [G("confirmations", nil)]),
            .init(.general, [G("behavior", "Display", rows: ["time-format"])])
        ]
        case .chat: return [
            .init(.general, [G("behavior", "Composer", rows: ["composer-rich-text", "send-shortcut", "composer-collapse", "skills-in-slash-menu"])]),
            .init(.general, [G("behavior", "Follow-ups", rows: ["follow-up-behavior"])])
        ]
        case .diffs: return [
            .init(.general, [G("behavior", "Diffs", rows: ["diff-layout", "hide-whitespace-changes", "default-diff-file-state"])]),
            .init(.appearance, [G("appearance-interface", "Colors", rows: ["diff-color-scheme"])]),
            .init(.general, [G("behavior", "Pull requests", rows: ["proactive-panels"])]),
            .init(.integrations, [G("browser", "Links", rows: ["pull-request-links-open-in-app"])])
        ]
        case .threads: return [
            .init(.general, scope: true, [G("projects-and-threads", "New projects", rows: ["add-project-starts-in"])]),
            .init(.general, [G("project-defaults", "New threads", rows: ["default-model", "default-permissions", "new-threads"])]),
            .init(.general, [G("organization", "Snooze", rows: ["snooze-options"])]),
            .init(.general, [G("organization", "Usage limits", rows: ["auto-resume-limited-threads", "snooze-limited-threads"])]),
            .init(.general, [G("organization", "Auto-settle", rows: ["auto-settle-merged-threads", "auto-settle-inactive-threads", "days-before-auto-settle", "auto-settle-keep-pull-requests"])]),
            .init(.general, [G("text-generation", nil)]),
            .init(.general, [G("behavior", "Advanced", rows: ["response-streaming"])])
        ]
        case .browser: return [
            .init(.integrations, scope: true, [G("browser", "Agent access", rows: ["agent-browser-access"])]),
            .init(.integrations, [G("browser", "Browsing", rows: ["browser-profiles", "browser-default-profile", "browser-manage-profiles", "browser-link-target", "browser-auto-show-floating-preview", "browser-search-engine", "browser-default-viewport", "browser-default-zoom", "browser-default-appearance"])]),
            .init(.integrations, [G("browser", "Recordings", rows: ["browser-recording-frame-rate", "browser-recording-key-presses", "browser-recording-mouse-presses"])])
        ]
        case .devices: return [.init(.integrations, scope: true, [G("devices", nil)])]
        case .worktrees: return [
            .init(.storage, scope: true, [G("storage-notice", nil), G("storage-worktrees", "Creation", rows: ["storage-worktrees-location"])]),
            .init(.general, [G("projects-and-threads", "Defaults", rows: ["start-from-origin"]), G("project-defaults", "Submodules", rows: ["worktree-submodules"])]),
            .init(.sourceControl, [G("source-control-text-generation", "Branches", rows: ["worktree-branch-naming"])]),
            .init(.storage, [G("storage-notice", nil), G("storage-worktrees", "Cleanup", rows: ["storage-worktree-mode", "storage-worktree-after-days", "storage-worktree-settled-after-days", "storage-worktree-on-merge", "storage-worktree-on-delete", "storage-worktree-unchanged", "storage-worktree-keep-when"])])
        ]
        case .maintenance: return [
            .init(.general, scope: true, [G("behavior", "Updates", rows: ["provider-update-checks", "continue-threads-after-server-update"])]),
            .init(.general, [G("behavior", "Background activity", rows: ["background-activity"])]),
            .init(.storage, [G("storage-notice", nil), G("storage-artifacts", nil), G("storage-cleanup", nil), G("storage-database", nil)]),
            .init(.general, [G("Diagnostics", nil, rows: ["diagnostics"])])
        ]
        case .about: return [
            .init(.general, [G("about", "App", rows: ["app-version", "update-track"])]),
            .init(.general, [G("about", "Legal", rows: ["privacy-policy"]), G("Diagnostics", "Licenses", rows: ["open-source-licenses"])])
        ]
        case .providers: return [
            .init(.providers, scope: true),
            .init(.general, [G("organization", "Advanced", rows: ["compact-idle-threads"])])
        ]
        case .sourceControl: return [.init(.sourceControl, scope: true, [G("source-control-defaults", nil), G("source-control", nil),
            G("Version Control", nil), G("Source Control Providers", nil), G("Server environment", nil),
            G("source-control-text-generation", "Writing", rows: ["source-control-writer-model", "source-control-writing-style"])])]
        default: return []
        }
    }
}
