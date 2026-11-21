import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

@MainActor
struct SettingsConcernTests {
    /// A search jump to a page whose nav row sits below the nav's fold scrolls that row into view, so the highlighted
    /// row is the page shown and not off screen (1.17.0 fixes, item 7).
    @Test func navScrollsToTheSelectedRow() {
        let nav = SettingsSidebarView(frame: NSRect(x: 0, y: 0, width: 256, height: 360))
        let window = NSWindow(contentRect: nav.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = nav
        defer { window.contentView = nil; window.close() }
        nav.layoutSubtreeIfNeeded()
        let last = SettingsSection.navSections.last { $0.isAvailable }!
        let row = nav.items[last]!
        #expect(!nav.bounds.contains(nav.convert(row.bounds, from: row)), "the last row starts below the fold in a 360pt nav")
        nav.selected = last
        nav.layoutSubtreeIfNeeded()
        #expect(!nav.bounds.contains(nav.convert(row.bounds, from: row)), "picking a page leaves the nav where it is")
        nav.revealSelected()
        nav.layoutSubtreeIfNeeded()
        #expect(nav.bounds.contains(nav.convert(row.bounds, from: row)))
    }

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
        // Release check 1.16.0, m1: the image cache row had no id, so "image cache" found nothing.
        for query in ["image cache", "clear image cache"] { #expect(SettingsSearch.search(query).first?.id == "image-cache", "\(query)") }
        #expect(ConcernSettingsView(context: context, section: .maintenance).anchor("image-cache") != nil)
        for (id, section) in [("image-cache", SettingsSection.maintenance), ("screen-reader-window-title", SettingsSection.chat), ("boring-sidebar-multiline", .beta), ("snooze-options", SettingsSection.threads), ("git-fetch-interval", .maintenance), ("network-access", .access), ("tool-call-visibility", .chat)] {
            #expect(SettingsSearch.items.first { $0.id == id }?.to == section)
        }
    }

    /// Release check 1.16.0, M1: Tooltips and Trackpad haptics live in General's Input group in Redesign and in
    /// About's CandyWrapper group in the default themes, once each, and search opens the page that holds them.
    @Test func candyWrapperRowsShowOnceAndSearchLandsOnThem() {
        let context = SettingsPagesFidelityTests.context()
        for dither in [false, true] {
            let general = ConcernSettingsView(context: context, section: .general, dither: dither)
            let about = ConcernSettingsView(context: context, section: .about, dither: dither)
            general.refresh(); about.refresh()
            for id in ConcernSettingsView.candyWrapperRows {
                #expect((general.anchor(id) != nil) == dither, "\(id) in General, dither \(dither)")
                #expect((about.anchor(id) != nil) == !dither, "\(id) in About, dither \(dither)")
                let item = try! #require(SettingsSearch.items.first { $0.id == id })
                #expect(ConcernSettingsView.located(item, dither: dither).to == (dither ? .general : .about))
                var group = (dither ? general : about).anchor(id)
                while let v = group, !(v is SettingsSectionView) { group = v.superview }
                #expect((group as? SettingsSectionView)?.title == (dither ? "Input" : "CandyWrapper"), "\(id)")
            }
            #expect(about.anchor("app-version") != nil)
            #expect(general.anchor("quit-confirmation") != nil)
        }
        let other = try! #require(SettingsSearch.items.first { $0.id == "send-shortcut" })
        #expect(ConcernSettingsView.located(other, dither: true) == other)
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
