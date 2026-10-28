import AppKit
import DesignSystem
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SidebarFoldersTests {
    let now = TimestampFormat.nowMs(SidebarPreview.referenceNow)

    @Test func foldersIncludeEmptyProjectsAndKeepTheOpenRowWhenClosed() throws {
        let snapshot = SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "Demo"), SidebarPreview.project("empty", "Empty")], threads: [
            SidebarPreview.thread("pin", "Pinned", project: "p", kind: .read, minutesAgo: 1, extra: ["pinnedAt": "2026-10-01T12:00:00Z"]),
            SidebarPreview.thread("open", "Open", project: "p", kind: .read, minutesAgo: 2),
            SidebarPreview.thread("run", "Working", project: "p", kind: .working, minutesAgo: 3),
        ])
        var state = SidebarListState(activeThreadId: ThreadId(rawValue: "open"))
        state.boringSidebarEnabled = true
        state.workingShelfEnabled = true
        let groups = SidebarModel.buildProjectGroups(snapshot.projects)
        state.collapsedProjects = Set(groups.map(\.key))
        let cache = SidebarListCache()
        let items = SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: now, cache: cache)
        let headers = items.compactMap { if case .projectHeader(let h) = $0 { h } else { nil } }
        #expect(headers.count == 2)
        #expect(headers.first(where: { $0.label == "Empty" })?.count == 0)
        let demo = try #require(headers.first(where: { $0.label == "Demo" }))
        #expect(demo.count == 1 && demo.dot == .working && demo.folder)
        #expect(items.first?.key == "thread:pin")
        let open = try #require(items.compactMap { if case .row(let r) = $0, r.id.rawValue == "open" { r } else { nil } }.first)
        #expect(open.variant == .slim && open.inProjectSection)
        #expect(!items.contains { if case .shelfHeader(.working, _, _) = $0 { true } else { false } })
        // A hidden status change must rebuild the folder's dot, even though it has no visible row.
        #expect(cache.patch(snapshot: snapshot, state: state, nowMs: now) == nil)
    }

    @Test func legacyOptInEnablesFoldersAndTheSwitchClearsIt() {
        let context = SettingsPageContext()
        context.client.apply(["legacySidebarEnabled": .bool(true)])
        let page = BetaSettingsView(context: context)
        let row = page.anchors["boring-sidebar"] as? SettingsRowView
        let toggle = row?.control as? SwitchView
        #expect(toggle?.isOn == true)
        var patch: [String: JSONValue] = [:]
        context.writeClient = { patch = $0 }
        toggle?.onChange?(false)
        #expect(patch == ["boringSidebarEnabled": .bool(false), "legacySidebarEnabled": .bool(false)])
    }
}
