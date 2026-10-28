import AppKit
import DesignSystem
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SidebarFoldersTests {
    let now = TimestampFormat.nowMs(SidebarPreview.referenceNow)

    @Test func foldersKeepTheOpenRowWhenClosed() throws {
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
        // A project with no active threads gets no folder (T3 3824 #26387).
        #expect(headers.map(\.label) == ["Demo"])
        let demo = try #require(headers.first(where: { $0.label == "Demo" }))
        #expect(demo.count == 1 && demo.dot == .working && demo.folder)
        #expect(items.first?.key == "thread:pin")
        let open = try #require(items.compactMap { if case .row(let r) = $0, r.id.rawValue == "open" { r } else { nil } }.first)
        #expect(open.variant == .slim && open.inProjectSection)
        #expect(!items.contains { if case .shelfHeader(.working, _, _, _) = $0 { true } else { false } })
        // A hidden status change must rebuild the folder's dot, even though it has no visible row.
        #expect(cache.patch(snapshot: snapshot, state: state, nowMs: now) == nil)
    }

    /// T3 3824 #26387 (Sidebar.logic.ts:920-948, Sidebar.tsx:1283): an empty project keeps its folder only while
    /// you filter to it, so it can start a thread.
    @Test func anEmptyProjectKeepsItsFolderOnlyWhileFiltered() {
        let snapshot = SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "Demo"), SidebarPreview.project("empty", "Empty")], threads: [
            SidebarPreview.thread("open", "Open", project: "p", kind: .read, minutesAgo: 2),
        ])
        var state = SidebarListState()
        state.boringSidebarEnabled = true
        func labels() -> [String] {
            SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: now, cache: SidebarListCache())
                .compactMap { if case .projectHeader(let h) = $0 { h.label } else { nil } }
        }
        #expect(labels() == ["Demo"])
        state.projectScopeKeys = SidebarModel.buildProjectGroups(snapshot.projects).map(\.key)
        #expect(Set(labels()) == ["Demo", "Empty"])
    }

    /// T3 3824 #26391 (Sidebar.tsx:463, :657-661): folders list threads by your latest message, not their order keys.
    @Test func foldersListThreadsByYourLatestMessage() {
        let snapshot = SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "Demo")], threads: [
            SidebarPreview.thread("first", "First", project: "p", kind: .read, minutesAgo: 10,
                                  extra: ["activeOrderKey": "a0", "latestUserAuthoredMessageAt": "2026-10-09T11:55:00Z"]),
            SidebarPreview.thread("second", "Second", project: "p", kind: .read, minutesAgo: 10,
                                  extra: ["activeOrderKey": "a1", "latestUserAuthoredMessageAt": "2026-10-09T11:58:00Z"]),
        ])
        var state = SidebarListState()
        let cache = SidebarListCache()
        func rows(_ snapshot: ShellSnapshot) -> [String] {
            SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: now, cache: cache)
                .compactMap { if case .row(let r) = $0 { r.id.rawValue } else { nil } }
        }
        #expect(rows(snapshot) == ["first", "second"])
        state.boringSidebarEnabled = true
        #expect(rows(snapshot) == ["second", "first"])
        // A new message moves its thread up through the cache's in-place pass too.
        let sent = SidebarPreview.snapshot(projects: [SidebarPreview.project("p", "Demo")], threads: [
            SidebarPreview.thread("first", "First", project: "p", kind: .read, minutesAgo: 10,
                                  extra: ["activeOrderKey": "a0", "latestUserAuthoredMessageAt": "2026-10-09T11:59:00Z"]),
            SidebarPreview.thread("second", "Second", project: "p", kind: .read, minutesAgo: 10,
                                  extra: ["activeOrderKey": "a1", "latestUserAuthoredMessageAt": "2026-10-09T11:58:00Z"]),
        ])
        #expect(rows(sent) == ["first", "second"])
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
