import Foundation
import Testing
import T3Protocol
import T3Store
@testable import Features

@MainActor
struct SidebarMultiProjectTests {
    @Test func filtersUseTheUnionAndCacheReadsEveryKey() throws {
        let snapshot = SidebarPreview.snapshot(projects: [SidebarPreview.project("a", "A"), SidebarPreview.project("b", "B"), SidebarPreview.project("c", "C")], threads: [
            SidebarPreview.thread("ta", "A", project: "a", kind: .read, minutesAgo: 1),
            SidebarPreview.thread("tb", "B", project: "b", kind: .read, minutesAgo: 2),
            SidebarPreview.thread("tc", "C", project: "c", kind: .read, minutesAgo: 3),
        ])
        let groups = SidebarModel.buildProjectGroups(snapshot.projects)
        let a = try #require(groups.first { $0.label == "A" }?.key)
        let b = try #require(groups.first { $0.label == "B" }?.key)
        let now = TimestampFormat.nowMs(SidebarPreview.referenceNow)
        var state = SidebarListState()
        let cache = SidebarListCache()
        func rows() -> [String] {
            SidebarListBuilder.items(snapshot: snapshot, state: state, nowMs: now, cache: cache).compactMap {
                if case .row(let r) = $0 { r.id.rawValue } else { nil }
            }
        }
        state.projectScopeKeys = [a]
        #expect(rows() == ["ta"])
        state.projectScopeKeys = [a, b]
        #expect(rows() == ["ta", "tb"])
        state.projectScopeKeys = ["gone"]
        #expect(rows().count == 3)
    }

    @Test func migratesTheSingleKeyAndPersistsToggles() throws {
        let suite = "SidebarMultiProjectTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("a", forKey: "sidebar.projectScopeKey")
        let sidebar = SidebarContentView()
        sidebar.scopeDefaults = defaults
        #expect(sidebar.state.projectScopeKeys == ["a"])
        sidebar.toggleProjectScope("b")
        #expect(defaults.stringArray(forKey: "sidebar.projectScopeKeys") == ["a", "b"])
        #expect(defaults.object(forKey: "sidebar.projectScopeKey") == nil)
        sidebar.toggleProjectScope("a")
        #expect(sidebar.state.projectScopeKeys == ["b"])
        sidebar.setProjectScopes(["b", "b", "", "c"])
        #expect(sidebar.state.projectScopeKeys == ["b", "c"])
        sidebar.setProjectScopes([])
        #expect(sidebar.state.projectScopeKeys.isEmpty)
    }
}
