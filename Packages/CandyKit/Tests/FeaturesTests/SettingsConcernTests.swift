import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

@MainActor
struct SettingsConcernTests {
    @Test func routesReachTheNewPagesAndRetainOldAliases() {
        for section in [SettingsSection.chat, .diffs, .threads, .browser, .devices, .worktrees, .access, .maintenance, .about] {
            #expect(SettingsSection.fromPath("/settings/" + section.rawValue) == section)
        }
        #expect(SettingsSection.fromPath("/settings/labs") == .beta)
        #expect(SettingsSection.fromPath("/settings/beta") == .beta)
        #expect(SettingsSection.fromPath("/settings/experimental") == .beta)
        #expect(SettingsSection.fromPath("/settings/storage") == .maintenance)
        #expect(SettingsSection.fromPath("/settings/integrations") == .browser)
        #expect(SettingsSection.fromPath("/settings/open-source-licenses") == .licenses)
        #expect(SettingsSection.fromPath("/threads") == nil)
    }

    /// 4928 adds Voice and names source control "Source control & issues" (settingsSearch.ts:96-178). CandyWrapper's Redesign
    /// tab closes the list.
    @Test func pageNamesAndOrderFollow4928WithRedesignLast() {
        #expect(SettingsSection.navSections.map(\.label) == ["General", "Appearance", "Chat", "Diffs & pull requests", "Keybindings", "Voice", "SnapShots", "Providers", "Threads", "Browser", "Devices", "Scheduled tasks", "Projects", "Source control & issues", "Worktrees", "Environments", "Sharing & access", "Maintenance", "Labs", "About", "Archive", "Redesign"])
    }

    /// Round 3: Redesign's own order, every group labelled, About last, and the same pages as the default nav.
    @Test func redesignNavGroupsEveryPageWithLabels() {
        let groups = SettingsSection.navGroups(dither: true)
        #expect(groups.map(\.label) == ["App", "Agents", "Code", "Connections", "System"])
        #expect(SettingsSection.navSections(dither: true).map(\.label) == ["General", "Appearance", "Redesign", "Keybindings", "Chat", "Voice", "SnapShots", "Providers", "Threads", "Archive", "Scheduled tasks", "Browser", "Devices", "Projects", "Source control & issues", "Diffs & pull requests", "Worktrees", "Environments", "Sharing & access", "Maintenance", "Labs", "About"])
        #expect(Set(SettingsSection.navSections(dither: true)) == Set(SettingsSection.navSections(dither: false)))
    }

    @Test func movedRowsKeepTheirSearchAnchorsAndDestinations() {
        let context = SettingsPagesFidelityTests.context()
        let cases: [(SettingsSection, [String], [String])] = [
            // General matches T3's references, so CandyWrapper's own rows sit in About.
            (.general, ["thread-notifications", "project-grouping", "working-shelf", "quit-confirmation"], ["send-shortcut", "app-version", "tooltips", "trackpad-haptics"]),
            (.chat, ["composer-rich-text", "send-shortcut", "follow-up-behavior", "screen-reader-window-title"], ["thread-notifications", "diff-layout"]),
            (.diffs, ["diff-layout", "diff-color-scheme", "proactive-panels", "pull-request-links-open-in-app"], ["browser-link-target"]),
            (.threads, ["default-model", "new-threads", "response-streaming", "text-generation-model"], ["compact-idle-threads", "worktree-submodules"]),
            (.providers, ["compact-idle-threads"], ["default-model"]),
            (.browser, ["browser-profiles", "browser-search-engine", "browser-recording-frame-rate"], ["pull-request-links-open-in-app", "device-hosts"]),
            (.devices, ["device-hosts"], ["browser-profiles"]),
            (.worktrees, ["worktree-submodules", "start-from-origin", "worktree-branch-naming", "storage-worktree-keep-when"], ["source-control-writing-style"]),
            (.maintenance, ["provider-update-checks", "background-activity", "diagnostics"], ["app-version"]),
            (.about, ["app-version", "privacy-policy", "open-source-licenses", "tooltips", "trackpad-haptics"], ["diagnostics"]),
            // Screen pass 3, item 4: the routed page dropped the Issue trackers section.
            (.sourceControl, ["source-control", "issue-trackers"], ["default-model"]),
        ]
        for (section, present, absent) in cases {
            let page = ConcernSettingsView(context: context, section: section)
            page.refresh()
            for id in present { #expect(page.anchor(id) != nil, "\(id) in \(section)") }
            for id in absent { #expect(page.anchor(id) == nil, "\(id) outside \(section)") }
        }
        // Screen pass 3, items 7 and 8: both rows the app draws are searchable and land where they are.
        for (id, section) in [("screen-reader-window-title", SettingsSection.chat), ("boring-sidebar-multiline", .beta), ("snooze-options", SettingsSection.threads), ("git-fetch-interval", .maintenance), ("network-access", .access), ("tool-call-visibility", .chat)] {
            #expect(SettingsSearch.items.first { $0.id == id }?.to == section)
        }
    }

    @Test func devicePagesStayUsableWithAnOfflineEnvironmentSelected() {
        let context = SettingsPageContext()
        context.scope = SettingsScopeState(environments: [.init(id: "offline", label: "Offline", connected: false)], primaryId: "offline")
        context.scope.selection.machine = "offline"
        for section in [SettingsSection.general, .chat, .diffs, .about] {
            let page = ConcernSettingsView(context: context, section: section)
            page.refresh()
            #expect(page.height(forWidth: 720) > 100, "\(section) keeps device settings visible")
        }
    }

    /// #33131 removed Labs' Legacy features; Tool calls in chat sits in Chat's Activity group. CandyWrapper's own
    /// experiments follow T3's Beta group.
    @Test func labsHasBetaThenCandyExperimentsAndChatShowsToolCalls() {
        let page = BetaSettingsView(context: SettingsPageContext())
        #expect(page.items.compactMap { ($0 as? SettingsSectionView)?.title } == ["Beta", "CandyWrapper experiments"])
        #expect(page.anchor("thread-tabs") != nil)
        #expect(SettingsSearch.items.first { $0.id == "thread-tabs" }?.to == .beta)
        #expect(page.anchor("boring-sidebar") != nil)
        #expect(page.anchor("legacy-plan-mode") == nil)
        let chat = ConcernSettingsView(context: SettingsPageContext(), section: .chat)
        chat.refresh()
        #expect(chat.anchor("tool-call-visibility") != nil)
        #expect(SettingsSearch.title("tool-call-visibility") == "Tool calls in chat")
    }
}
