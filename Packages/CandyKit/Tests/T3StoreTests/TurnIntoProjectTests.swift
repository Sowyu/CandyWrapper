import Testing
import T3Protocol
@testable import T3Store

/// 4928 #26767: a No project thread with its own folder can become a project.
@Suite struct TurnIntoProjectTests {
    @Test func offeredOnlyForScratchThreadsWithAFolderOnServersThatCanPromote() {
        let caps: Set<String> = ["threadProjectFromScratch"]
        #expect(ProjectCommands.canTurnIntoProject(worktreePath: "/s/t1", projectRoot: "/s/", scratchRoot: "/s", capabilities: caps))
        // No folder of its own, a real project, or a 3824 server without the capability.
        #expect(!ProjectCommands.canTurnIntoProject(worktreePath: nil, projectRoot: "/s", scratchRoot: "/s", capabilities: caps))
        #expect(!ProjectCommands.canTurnIntoProject(worktreePath: "/w", projectRoot: "/repo", scratchRoot: "/s", capabilities: caps))
        #expect(!ProjectCommands.canTurnIntoProject(worktreePath: "/s/t1", projectRoot: "/s", scratchRoot: "/s", capabilities: []))
        #expect(!ProjectCommands.canTurnIntoProject(worktreePath: "/s/t1", projectRoot: "/s", scratchRoot: nil, capabilities: caps))
    }

    @Test func menuItemFollowsFilterAndWaitsForTheRun() {
        var state = ThreadActionMenu.State()
        state.projectFilter = (label: "demo", isActive: false)
        #expect(!ThreadActionMenu.items(state).contains { $0.id == "turn-into-project" })
        state.canTurnIntoProject = true
        let ids = ThreadActionMenu.items(state).map(\.id)
        let i = try! #require(ids.firstIndex(of: "turn-into-project"))
        #expect(ids[i - 1] == "filter-by-project" && ids[i + 1] == "auto-settle")
        state.isRunning = true
        #expect(ThreadActionMenu.items(state).first { $0.id == "turn-into-project" }?.disabled == true)
        // Read-only connections can't promote.
        state.isRunning = false
        state.canOperate = false
        #expect(ThreadActionMenu.items(state).first { $0.id == "turn-into-project" }?.disabled == true)
    }

    @Test func requestCarriesTheLocalThreadId() {
        #expect(ProjectCommands.createFromThreadMethod == "projects.createFromThread")
        #expect(ProjectCommands.createFromThread("t-1") == .object(["threadId": .string("t-1")]))
    }
}
