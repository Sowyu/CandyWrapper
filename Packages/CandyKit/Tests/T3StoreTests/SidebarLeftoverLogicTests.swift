import Foundation
import T3Protocol
import Testing
@testable import T3Store

/// WP7.9: thread menu leftovers, custom snooze, delete, the Working shelf and project grouping.
@Suite("Sidebar leftovers logic")
struct SidebarLeftoverLogicTests {
    // MARK: Commands

    @Test func renameDeleteAndDetachPayloads() {
        let id = ThreadId("t1")
        #expect(ThreadCommands.rename(id, title: "New", commandId: "c") ==
                .object(["type": "thread.metadata.update", "commandId": "c", "threadId": "t1", "title": "New"]))
        #expect(ThreadCommands.delete(id, commandId: "c") == .object(["type": "thread.delete", "commandId": "c", "threadId": "t1"]))
        // `stopThreadSession`: one detach per provider session, `<commandId>:detach:<session>`.
        #expect(ThreadCommands.detachSessions(id, sessionIds: ["s1", "s2"], commandId: "c") == [
            .object(["type": "provider-session.detach", "commandId": "c:detach:s1", "threadId": "t1", "providerSessionId": "s1", "reason": "client-requested"]),
            .object(["type": "provider-session.detach", "commandId": "c:detach:s2", "threadId": "t1", "providerSessionId": "s2", "reason": "client-requested"]),
        ])
    }

    // MARK: Multi-select menu (Sidebar.tsx:4242-4352)

    @Test func bulkMenuCountsOnlyWhatEachActionTouches() {
        let presets = SnoozePresets.resolve(now: Date(timeIntervalSince1970: 1_800_000_000))
        let items = ThreadActionMenu.bulkItems(count: 3, pinnedCount: 1, settlingCount: 2, canSnooze: true,
                                               titleSupportedCount: 3, titleActionableCount: 2, archivableCount: 2, snoozePresets: presets)
        #expect(items.map(\.label) == ["Unpin (1)", "Settle (3)", "Snooze (3)", "Rewrite titles (2)", "Mark unread (3)",
                                        "Archive (2)", "Delete (3)"])
        #expect(items.first { $0.id == "archive" }?.separatorBefore == true)
        #expect(items.first { $0.id == "snooze" }?.children.last?.id == "snooze:custom")
        #expect(items.last?.destructive == true)
        // Nothing pinned: no Unpin. All settled: Unsettle instead of a greyed Settle. Nothing regeneratable: the disabled
        // "Regenerating…" row. A blocked thread: no Snooze. Every thread running: Archive greys out.
        let none = ThreadActionMenu.bulkItems(count: 2, pinnedCount: 0, settlingCount: 0, canSnooze: false,
                                              titleSupportedCount: 2, titleActionableCount: 0, snoozePresets: presets)
        #expect(none.map(\.label) == ["Unsettle (2)", "Rewriting titles… (2)", "Mark unread (2)", "Archive (0)", "Delete (2)"])
        #expect(none[0].id == "unsettle" && !none[0].disabled && none[1].disabled && none[3].disabled)
    }

    // MARK: Custom snooze (`resolveCustomSnooze`)

    @Test func customSnoozeResolvesDurationsAndLocalDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 30))!
        #expect(CustomSnooze.duration(amount: "2", unit: .hours).resolve(now: now, calendar: cal) == now.addingTimeInterval(7200))
        #expect(CustomSnooze.duration(amount: "1.5", unit: .days).resolve(now: now, calendar: cal) == now.addingTimeInterval(129_600))
        #expect(CustomSnooze.duration(amount: "0", unit: .minutes).resolve(now: now, calendar: cal) == nil)
        #expect(CustomSnooze.duration(amount: "", unit: .minutes).resolve(now: now, calendar: cal) == nil)
        let tonight = CustomSnooze.date(day: "2026-10-11", time: "18:00").resolve(now: now, calendar: cal)
        #expect(tonight == cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 18)))
        // Past, rolled over, malformed, and the hour the October DST change skips.
        #expect(CustomSnooze.date(day: "2026-10-11", time: "08:00").resolve(now: now, calendar: cal) == nil)
        #expect(CustomSnooze.date(day: "2026-10-32", time: "08:00").resolve(now: now, calendar: cal) == nil)
        #expect(CustomSnooze.date(day: "2026-10-12", time: "8:00").resolve(now: now, calendar: cal) == nil)
        #expect(CustomSnooze.date(day: "2027-03-28", time: "02:30").resolve(now: now, calendar: cal) == nil)
        #expect(CustomSnooze.localDate(now, calendar: cal) == "2026-10-11")
        #expect(CustomSnooze.localTime(now, calendar: cal) == "09:30")
    }

    // MARK: Delete (useThreadActions.ts:440-640)

    @Test func orphanedWorktreeIsTheOneNoOtherThreadUses() {
        let a = thread("a") { $0.worktreePath = "/w/feature" }
        let b = thread("b") { $0.worktreePath = " /w/feature " }
        let c = thread("c") { $0.worktreePath = "/w/solo/" }
        #expect(SidebarModel.orphanedWorktreePath([a, b, c], threadId: ThreadId("a")) == nil)
        #expect(SidebarModel.orphanedWorktreePath([a, c], threadId: ThreadId("a")) == "/w/feature")
        #expect(SidebarModel.orphanedWorktreePath([a, c], threadId: ThreadId("missing")) == nil)
        #expect(SidebarModel.worktreeDisplayName("/w/solo/") == "solo")
        #expect(SidebarModel.worktreeDisplayName("C:\\w\\x") == "x")
    }

    @Test func fallbackAfterDeleteIsTheProjectsNewestOtherThread() {
        let old = thread("old") { $0.updatedAt = "2026-10-01T00:00:00.000Z" }
        let new = thread("new") { $0.updatedAt = "2026-10-05T00:00:00.000Z" }
        let gone = thread("gone") { $0.updatedAt = "2026-10-09T00:00:00.000Z" }
        let other = thread("other") { $0.projectId = ProjectId("p2"); $0.updatedAt = "2026-10-10T00:00:00.000Z" }
        let all = [old, new, gone, other]
        #expect(SidebarModel.fallbackThreadAfterDelete(all, deleted: ThreadId("old")) == ThreadId("gone"))
        #expect(SidebarModel.fallbackThreadAfterDelete(all, deleted: ThreadId("old"), deleting: [ThreadId("gone")]) == ThreadId("new"))
        #expect(SidebarModel.fallbackThreadAfterDelete([other], deleted: ThreadId("other")) == nil)
        // T3 4928 #29643: a settled or snoozed thread is never the one that opens.
        let settled = thread("settled") { $0.updatedAt = "2026-10-11T00:00:00.000Z"; $0.settledOverride = .settled }
        let snoozed = thread("snoozed") { $0.updatedAt = "2026-10-12T00:00:00.000Z"; $0.snoozedUntil = "2999-01-01T00:00:00.000Z" }
        #expect(SidebarModel.fallbackThreadAfterDelete(all + [settled, snoozed], deleted: ThreadId("old"), deleting: [ThreadId("gone")]) == ThreadId("new"))
    }

    // MARK: Working shelf (threadInbox.ts)

    @Test func workingFoldsBusyInboxThreadsOnly() {
        let running = sidebarThread("run") { $0.latestRunId = RunId("r1"); $0.activeRunId = RunId("r1"); $0.status = .running }
        let asking = sidebarThread("ask") {
            $0.latestRunId = RunId("r2"); $0.activeRunId = RunId("r2"); $0.status = .running
            $0.pendingRuntimeRequest = try! JSONDecoder().decode(PendingRuntimeRequestSummary.self,
                                                                 from: Data(#"{"id":"q","kind":"user_input","createdAt":"2026-10-10T00:00:00.000Z"}"#.utf8))
        }
        let idle = sidebarThread("idle")
        #expect(SidebarModel.isThreadWorking(running))
        #expect(!SidebarModel.isThreadWorking(asking))
        #expect(!SidebarModel.isThreadWorking(idle))
        let caps = SidebarModel.Capabilities(threadSettlement: true, threadSnooze: true)
        let on = SidebarModel.buildShelves([running, asking, idle], capabilities: caps, nowMs: 0, workingShelf: true)
        #expect(on.working.map(\.id) == [ThreadId("run")])
        #expect(Set(on.active.map(\.id)) == [ThreadId("ask"), ThreadId("idle")])
        let off = SidebarModel.buildShelves([running, asking, idle], capabilities: caps, nowMs: 0)
        #expect(off.working.isEmpty && off.active.count == 3)
    }

    @Test func workingSortsBySendAndInboxByReturn() {
        let a = sidebarThread("a") { $0.latestUserAuthoredMessageAt = "2026-10-10T10:00:00.000Z" }
        let b = sidebarThread("b") { $0.latestUserAuthoredMessageAt = "2026-10-10T11:00:00.000Z" }
        #expect(SidebarModel.sortWorkingThreadsBySend([a, b]).map(\.id) == [ThreadId("b"), ThreadId("a")])
        // A return this client saw lifts a thread to the top of the inbox.
        let ms = T3Timestamp("2026-10-10T12:00:00.000Z").epochMs!
        let sorted = SidebarModel.sortInboxThreadsByReturn([b, a]) { $0 == ThreadId("a") ? ms : nil }
        #expect(sorted.map(\.id) == [ThreadId("a"), ThreadId("b")])
    }

    @Test func inboxTrackerRecordsLeavingWorkingAfterItsBaseline() {
        let tracker = SidebarInboxReturnTracker()
        let busy = sidebarThread("t") { $0.latestRunId = RunId("r"); $0.activeRunId = RunId("r"); $0.status = .running }
        let done = sidebarThread("t")
        tracker.observe([busy], nowMs: 100)
        #expect(tracker.returnedAt(ThreadId("t")) == nil)
        // threadInbox.ts:138-162: it keeps its Working place for 2 s after it stops.
        tracker.observe([done], nowMs: 200)
        #expect(tracker.isWorking(done) && tracker.returnedAt(ThreadId("t")) == nil && tracker.nextDeadline == 2_200)
        tracker.observe([done], nowMs: 2_200)
        #expect(!tracker.isWorking(done) && tracker.returnedAt(ThreadId("t")) == 2_200 && tracker.nextDeadline == nil)
        tracker.observe(nil, nowMs: 300)
        #expect(tracker.returnedAt(ThreadId("t")) == nil)
    }

    @Test func inboxTrackerReleasesAThreadThatNeedsTheUserAtOnce() {
        let tracker = SidebarInboxReturnTracker()
        let busy = sidebarThread("t") { $0.latestRunId = RunId("r"); $0.activeRunId = RunId("r"); $0.status = .running }
        let failed = sidebarThread("t") { $0.latestRunId = RunId("r"); $0.status = .failed; $0.lastError = "boom" }
        let pinned = sidebarThread("t") { $0.pinnedAt = "2026-10-10T10:00:00.000Z" }
        tracker.observe([busy], nowMs: 100)
        tracker.observe([failed], nowMs: 200)
        #expect(!tracker.isWorking(failed) && tracker.returnedAt(ThreadId("t")) == 200)
        tracker.observe([busy], nowMs: 300)
        tracker.observe([pinned], nowMs: 400)
        #expect(!tracker.isWorking(pinned) && tracker.nextDeadline == nil)
    }

    /// T3 4928 Sidebar.logic.ts:960-968 (#28616): opening a failed thread clears its Failed badge; a failure from
    /// older data without a completion is dated by its start.
    @Test func anOpenedFailureSettlesToReady() {
        let failed = sidebarThread("t") {
            $0.latestRunId = RunId("r"); $0.status = .failed; $0.lastError = "boom"
            $0.latestRunCompletedAt = .value("2026-10-10T10:00:00.000Z")
        }
        #expect(SidebarModel.resolveSidebarRowStatus(failed, lastVisitedAt: nil) == .failed)
        #expect(SidebarModel.resolveSidebarRowStatus(failed, lastVisitedAt: "2026-10-10T09:00:00.000Z") == .failed)
        #expect(SidebarModel.resolveSidebarRowStatus(failed, lastVisitedAt: "2026-10-10T11:00:00.000Z") == .ready)
    }

    // MARK: Project grouping (projectGrouping.ts)

    private func repo(_ key: String, root: String?) -> RepositoryIdentity {
        let rootField = root.map { #","rootPath":"\#($0)""# } ?? ""
        return try! JSONDecoder().decode(RepositoryIdentity.self, from: Data("""
            {"canonicalKey":"\(key)","locator":{"source":"git-remote","remoteName":"origin","remoteUrl":"https://\(key).git"}\(rootField)}
            """.utf8))
    }

    @Test func repositoryPathGroupsByFolderInsideTheRepository() {
        let root = project("p1") { $0.workspaceRoot = "/r/mono"; $0.repositoryIdentity = repo("github.com/a/mono", root: "/r/mono") }
        let web = project("p2") { $0.workspaceRoot = "/r/mono/apps/web"; $0.repositoryIdentity = repo("github.com/a/mono", root: "/r/mono") }
        #expect(SidebarModel.deriveLogicalProjectKey(root, mode: .repositoryPath) == "github.com/a/mono")
        #expect(SidebarModel.deriveLogicalProjectKey(web, mode: .repositoryPath) == "github.com/a/mono::apps/web")
        #expect(SidebarModel.deriveLogicalProjectKey(web, mode: .repository) == "github.com/a/mono")
        let grouped = SidebarModel.buildProjectGroups([root, web], grouping: .init(mode: .repository))
        #expect(grouped.count == 1)
        // A per-project override splits one physical project out (`resolveProjectGroupingMode`).
        let override = SidebarModel.ProjectGrouping(mode: .repository, overrides: [SidebarModel.physicalProjectKey(web): .separate])
        #expect(SidebarModel.buildProjectGroups([root, web], grouping: override).count == 2)
    }
}

/// T3 4928 client-runtime/src/state/threadTagFilter.ts (#29053): tagged threads hide while their environment hides them.
@Suite struct ThreadTagFilterTests {
    @Test func aHiddenTagHidesTheThreadOnlyWhileTheFilterIsOn() {
        let tagged = thread("t") { $0.tags = LenientArray(["client", "demo"]) }
        let plain = thread("p")
        let env = tagged.id.environmentId ?? ""
        #expect(SidebarModel.hiddenThreadTags(settings: .object(["hiddenThreadTags": .array([.string("client")])])) == nil)
        let on = SidebarModel.hiddenThreadTags(settings: .object(["hideTaggedThreads": .bool(true),
                                                                  "hiddenThreadTags": .array([.string(" client "), .string("")])]))
        #expect(on == ["client"])
        #expect(SidebarModel.hidesForTags(tagged, hiddenTags: [env: on!]))
        #expect(!SidebarModel.hidesForTags(plain, hiddenTags: [env: on!]))
        #expect(!SidebarModel.hidesForTags(tagged, hiddenTags: [env: ["other"]]))
        #expect(!SidebarModel.hidesForTags(tagged, hiddenTags: [:]))
    }
}
