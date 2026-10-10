import Foundation
import T3Protocol
import Testing
@testable import T3Store

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

private func object(_ json: JSONValue) -> [String: JSONValue] {
    if case .object(let o) = json { return o }
    Issue.record("not an object: \(json)")
    return [:]
}

private let id = ThreadId("thread-1")
private let now: T3Timestamp = "2026-10-10T12:00:00.000Z"

@Suite("Thread command payloads")
struct ThreadCommandPayloadTests {
    @Test func simpleCommandsCarryTypeCommandIdAndThread() {
        let cases: [(JSONValue, String)] = [
            (ThreadCommands.settle(id, commandId: "c"), "thread.settle"),
            (ThreadCommands.unpin(id, commandId: "c"), "thread.unpin"),
            (ThreadCommands.markUnread(id, commandId: "c"), "thread.mark-unread"),
            (ThreadCommands.archive(id, commandId: "c"), "thread.archive"),
            (ThreadCommands.unarchive(id, commandId: "c"), "thread.unarchive"),
        ]
        for (payload, type) in cases {
            #expect(object(payload) == ["type": .string(type), "commandId": .string("c"), "threadId": .string("thread-1")])
        }
    }

    @Test func unsettleAndUnsnoozeSayTheUserAsked() {
        #expect(object(ThreadCommands.unsettle(id, commandId: "c")) ==
                ["type": "thread.unsettle", "commandId": "c", "threadId": "thread-1", "reason": "user"])
        #expect(object(ThreadCommands.unsnooze(id, commandId: "c")) ==
                ["type": "thread.unsnooze", "commandId": "c", "threadId": "thread-1", "reason": "user"])
    }

    @Test func snoozeSendsTheWakeTime() {
        #expect(object(ThreadCommands.snooze(id, until: "2026-10-10T18:00:00.000Z", commandId: "c")) ==
                ["type": "thread.snooze", "commandId": "c", "threadId": "thread-1", "snoozedUntil": "2026-10-10T18:00:00.000Z"])
    }

    @Test func pinSendsAnOrderKeyOnlyWhenThereIsOne() {
        #expect(object(ThreadCommands.pin(id, orderKey: "n", commandId: "c")) ==
                ["type": "thread.pin", "commandId": "c", "threadId": "thread-1", "orderKey": "n"])
        #expect(object(ThreadCommands.pin(id, orderKey: nil, commandId: "c")) ==
                ["type": "thread.pin", "commandId": "c", "threadId": "thread-1"])
    }

    @Test func autoSettleAndTitleRegeneration() {
        #expect(object(ThreadCommands.setAutoSettle(id, enabled: false, commandId: "c")) ==
                ["type": "thread.auto-settle.set", "commandId": "c", "threadId": "thread-1", "enabled": .bool(false)])
        #expect(object(ThreadCommands.regenerateTitle(id, commandId: "c")) ==
                ["type": "thread.metadata.update", "commandId": "c", "threadId": "thread-1", "regenerateTitle": .bool(true)])
    }

    @Test func commandIdsAreFreshLowercaseUUIDs() {
        guard case .string(let a)? = ThreadCommands.settle(id)["commandId"], case .string(let b)? = ThreadCommands.settle(id)["commandId"] else {
            Issue.record("no command id"); return
        }
        #expect(a != b)
        #expect(a == a.lowercased() && UUID(uuidString: a) != nil)
    }

    @Test func sequenceComesFromTheDispatchResult() {
        #expect(ThreadCommands.sequence(.object(["sequence": .number(42)])) == 42)
        #expect(ThreadCommands.sequence(.object([:])) == nil)
    }

    @Test func projectCreateMatchesTheAddProjectFlow() {
        let payload = object(ProjectCommands.create(projectId: ProjectId("p-1"), workspaceRoot: "/Users/me/code/demo-repo/", commandId: "c"))
        #expect(payload == [
            "type": "project.create", "commandId": "c", "projectId": "p-1", "title": "demo-repo",
            "workspaceRoot": "/Users/me/code/demo-repo/", "createWorkspaceRootIfMissing": .bool(true), "defaultModelSelection": .null,
        ])
        #expect(ProjectCommands.inferTitle(fromPath: "/") == "/")
    }

    @Test func existingProjectMatchesIgnoringTrailingSlash() {
        let p = project("p") { $0.workspaceRoot = "/workspace/demo" }
        #expect(ProjectCommands.existing([p], workspaceRoot: "/workspace/demo/")?.id == p.id)
        #expect(ProjectCommands.existing([p], workspaceRoot: "/workspace/other") == nil)
    }
}

@Suite("Optimistic thread updates")
struct OptimisticThreadUpdateTests {
    @Test func settleClearsPinSnoozeAndOrder() {
        let t = thread { $0.pinnedAt = "2026-10-01T00:00:00.000Z"; $0.pinOrderKey = "n"; $0.activeOrderKey = "m"
            $0.snoozedUntil = "2026-10-11T00:00:00.000Z"; $0.snoozedAt = "2026-10-09T00:00:00.000Z" }
        let out = OptimisticThreadUpdate.settle.apply(t, now: now, accepted: false)
        #expect(out.settledOverride == .settled && out.settledAt == now && out.unsettledAt == nil)
        #expect(out.pinnedAt == nil && out.pinOrderKey == nil && out.activeOrderKey == nil)
        #expect(out.snoozedUntil == nil && out.snoozedAt == nil)
    }

    @Test func settleWaitsForTheServerOnBusyThreads() {
        let running = thread { $0.status = .running }
        #expect(OptimisticThreadUpdate.settle.apply(running, now: now, accepted: false) == running)
        #expect(OptimisticThreadUpdate.settle.apply(running, now: now, accepted: true).settledOverride == .settled)
    }

    @Test func settleKeepsAnEarlierSettledTime() {
        let t = thread { $0.settledOverride = .settled; $0.settledAt = "2026-10-01T00:00:00.000Z" }
        #expect(OptimisticThreadUpdate.settle.apply(t, now: now, accepted: false).settledAt == "2026-10-01T00:00:00.000Z")
    }

    @Test func unsettleMarksTheThreadActive() {
        let t = thread { $0.settledOverride = .settled; $0.settledAt = "2026-10-01T00:00:00.000Z" }
        let out = OptimisticThreadUpdate.unsettle.apply(t, now: now, accepted: false)
        #expect(out.settledOverride == .active && out.settledAt == nil && out.unsettledAt == now)
    }

    @Test func snoozeOnlyIntoTheFuture() {
        let t = thread()
        let later: T3Timestamp = "2026-10-10T18:00:00.000Z"
        let out = OptimisticThreadUpdate.snooze(until: later).apply(t, now: now, accepted: false)
        #expect(out.snoozedUntil == later && out.snoozedAt == now)
        #expect(OptimisticThreadUpdate.snooze(until: "2026-10-10T11:00:00.000Z").apply(t, now: now, accepted: true) == t)
        let starting = thread { $0.status = .starting }
        #expect(OptimisticThreadUpdate.snooze(until: later).apply(starting, now: now, accepted: false) == starting)
    }

    @Test func pinUnsettlesAndWakes() {
        let t = thread { $0.settledOverride = .settled; $0.snoozedUntil = "2026-10-11T00:00:00.000Z" }
        let out = OptimisticThreadUpdate.pin(orderKey: "h").apply(t, now: now, accepted: false)
        #expect(out.pinnedAt == now && out.pinOrderKey == "h")
        #expect(out.settledOverride == .active && out.unsettledAt == now && out.snoozedUntil == nil)
        let pinned = thread { $0.pinnedAt = "2026-10-01T00:00:00.000Z"; $0.pinOrderKey = "c" }
        #expect(OptimisticThreadUpdate.pin(orderKey: "h").apply(pinned, now: now, accepted: false).pinOrderKey == "c")
    }

    @Test func unpinUnsnoozeAndAutoSettle() {
        let t = thread { $0.pinnedAt = now; $0.pinOrderKey = "n"; $0.snoozedUntil = now; $0.snoozedAt = now }
        let unpinned = OptimisticThreadUpdate.unpin.apply(t, now: now, accepted: false)
        #expect(unpinned.pinnedAt == nil && unpinned.pinOrderKey == nil)
        let woke = OptimisticThreadUpdate.unsnooze.apply(t, now: now, accepted: false)
        #expect(woke.snoozedUntil == nil && woke.snoozedAt == nil)
        #expect(OptimisticThreadUpdate.setAutoSettle(false).apply(t, now: now, accepted: false).autoSettleDisabledAt == now)
    }

    @Test func overlayShowsAtOnceAndLeavesOnFailure() {
        var overlay = OptimisticThreadOverlay()
        let snapshot = ShellSnapshot(schemaVersion: 2, snapshotSequence: 10, threads: [thread("t")])
        let token = overlay.begin(.settle, threadId: ThreadId("t"), environmentId: "env")
        #expect(overlay.apply(snapshot, environmentId: "env").threads[0].settledOverride == .settled)
        #expect(overlay.apply(snapshot, environmentId: "other").threads[0].settledOverride == nil)
        overlay.cancel(token)
        #expect(overlay.apply(snapshot, environmentId: "env").threads[0].settledOverride == nil)
        #expect(overlay.isEmpty)
    }

    @Test func confirmedUpdateStaysUntilTheShellCatchesUp() {
        var overlay = OptimisticThreadOverlay()
        let token = overlay.begin(.unpin, threadId: ThreadId("t"), environmentId: "env")
        overlay.confirm(token, sequence: 12)
        let pinned = thread("t") { $0.pinnedAt = now }
        overlay.reconcile(environmentId: "env", snapshotSequence: 11)
        #expect(overlay.apply(ShellSnapshot(schemaVersion: 2, snapshotSequence: 11, threads: [pinned]), environmentId: "env").threads[0].pinnedAt == nil)
        overlay.reconcile(environmentId: "env", snapshotSequence: 12)
        #expect(overlay.isEmpty)
    }

    @Test func removingAnEnvironmentDropsOnlyItsUpdates() {
        var overlay = OptimisticThreadOverlay()
        _ = overlay.begin(.settle, threadId: ThreadId("t"), environmentId: "gone")
        _ = overlay.begin(.settle, threadId: ThreadId("t"), environmentId: "kept")
        overlay.remove(environmentId: "gone")
        let snapshot = ShellSnapshot(schemaVersion: 2, snapshotSequence: 10, threads: [thread("t")])
        #expect(overlay.apply(snapshot, environmentId: "gone").threads[0].settledOverride == nil)
        #expect(overlay.apply(snapshot, environmentId: "kept").threads[0].settledOverride == .settled)
    }
}

@Suite("Pin order keys")
struct PinOrderKeyTests {
    @Test func midpoints() {
        #expect(PinOrderKey.between(nil, nil) == "n")
        #expect(PinOrderKey.between("f", "t") == "m")
        #expect(PinOrderKey.between(nil, "n") == "h")
        #expect(PinOrderKey.between("n", nil) == "u")
        #expect(PinOrderKey.between("b", "c") == "bn")
        #expect(PinOrderKey.between(nil, "b") == "an")
        #expect(PinOrderKey.between("m", "mb") == "man")
    }

    @Test func rejectsCorruptOrOutOfOrderKeys() {
        #expect(PinOrderKey.between("t", "f") == nil)
        #expect(PinOrderKey.between("A", nil) == nil)
        #expect(PinOrderKey.between(nil, "ba") == nil)
    }

    @Test func alwaysStrictlyBetween() {
        let keys = ["b", "bn", "c", "h", "hz", "n", "na", "nb", "y", "yz", "z"].filter { PinOrderKey.isValid($0) }
        for (i, a) in keys.enumerated() {
            for b in keys[(i + 1)...] {
                let k = PinOrderKey.between(a, b)
                #expect(k.map { $0 > a && $0 < b && PinOrderKey.isValid($0) } == true, "\(a) \(b) -> \(k ?? "nil")")
            }
        }
    }

    @Test func topOfPinnedRunGoesBeforeEveryKeyedPin() {
        let threads = [thread("a") { $0.pinnedAt = now; $0.pinOrderKey = "n" },
                       thread("b") { $0.pinnedAt = now; $0.pinOrderKey = "h" },
                       thread("c") { $0.pinOrderKey = "b" }] // not pinned: ignored
        #expect(PinOrderKey.topOfPinnedRun(threads) == "e")
        #expect(PinOrderKey.topOfPinnedRun([]) == "n")
    }
}

@Suite("Snooze")
struct SnoozeTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let locale = Locale(identifier: "en_US_POSIX")

    @Test func weekdayMorningOffersEveryPreset() {
        // Wednesday 10:00.
        let presets = SnoozePresets.resolve(now: Date(timeIntervalSince1970: 1_791_367_200), calendar: calendar, locale: locale)
        #expect(presets.map(\.id) == ["hour", "three-hours", "evening", "tomorrow", "next-week"])
        #expect(presets.map(\.label) == ["In 1 hour", "In 3 hours", "This evening", "Tomorrow", "Next week"])
        #expect(presets.map(\.iso) == ["2026-10-07T11:00:00.000Z", "2026-10-07T13:00:00.000Z", "2026-10-07T18:00:00.000Z",
                                       "2026-10-08T09:00:00.000Z", "2026-10-12T09:00:00.000Z"])
        // ICU puts a narrow no-break space before AM and PM, as Chromium's Intl does.
        #expect(presets.map { $0.whenLabel.replacingOccurrences(of: "\u{202F}", with: " ") } == ["11:00 AM", "1:00 PM", "6:00 PM", "9:00 AM", "Mon 9:00 AM"])
    }

    @Test func lateAfternoonDropsThisEvening() {
        // Wednesday 17:30: 18:00 is less than an hour away.
        let presets = SnoozePresets.resolve(now: Date(timeIntervalSince1970: 1_791_394_200), calendar: calendar, locale: locale)
        #expect(!presets.contains { $0.id == "evening" })
    }

    @Test func sundayHasNoSeparateNextWeek() {
        // Sunday 10:00: tomorrow and next week are both Monday 9:00.
        let presets = SnoozePresets.resolve(now: Date(timeIntervalSince1970: 1_791_712_800), calendar: calendar, locale: locale)
        #expect(presets.map(\.id) == ["hour", "three-hours", "evening", "tomorrow"])
    }

    @Test func blockedOrQueuedThreadsCannotSnooze() {
        let nowMs = ms("2026-10-10T12:00:00.000Z")
        #expect(SidebarModel.canSnooze(sidebarThread(), nowMs: nowMs))
        let approval = sidebarThread {
            $0.pendingRuntimeRequest = PendingRuntimeRequestSummary(id: RuntimeRequestId("r"), kind: .command, createdAt: "2026-10-10T11:59:00.000Z")
        }
        #expect(approval.hasPendingApprovals)
        #expect(!SidebarModel.canSnooze(approval, nowMs: nowMs))
        // A user message no run picked up within two minutes is a queued turn.
        let queued = sidebarThread { $0.latestUserMessageAt = "2026-10-10T11:59:30.000Z" }
        #expect(!SidebarModel.canSnooze(queued, nowMs: nowMs))
        let stale = sidebarThread { $0.latestUserMessageAt = "2026-10-10T11:50:00.000Z" }
        #expect(SidebarModel.canSnooze(stale, nowMs: nowMs))
    }

    @Test func archiveRefusesARunningProvider() {
        #expect(SidebarModel.runtimeCanArchive(nil))
        #expect(!SidebarModel.runtimeCanArchive(ThreadRuntimeSummary(status: .running)))
        #expect(SidebarModel.runtimeCanArchive(ThreadRuntimeSummary(status: .queued)))
        #expect(!SidebarModel.runtimeCanArchive(ThreadRuntimeSummary(status: .queued, activeRunId: RunId("r"))))
    }
}

@Suite("Thread menu")
struct ThreadActionMenuTests {
    @Test func defaultOrderMatchesT3() {
        var s = ThreadActionMenu.State()
        s.branch = "main"
        s.projectFilter = (label: "demo", isActive: false)
        let items = ThreadActionMenu.items(s)
        #expect(items.map(\.id) == ["new-thread-on-branch", "pin", "settle", "snooze", "rename", "regenerate-title", "mark-unread",
                                    "filter-by-project", "auto-settle", "copy", "project-settings", "archive", "delete"])
        #expect(items.first { $0.id == "filter-by-project" }?.label == "Filter by demo")
        #expect(items.first { $0.id == "copy" }?.children.map(\.id) == ["copy-path", "copy-branch", "copy-thread-id"])
        #expect(items.filter(\.separatorBefore).map(\.id) == ["rename", "copy", "archive"])
    }

    @Test func stateFlipsLabels() {
        var s = ThreadActionMenu.State()
        s.isPinned = true; s.isSettled = true; s.isSnoozed = true; s.isRegeneratingTitle = true; s.autoSettleEnabled = false
        s.projectFilter = (label: "demo", isActive: true)
        let items = ThreadActionMenu.items(s)
        let labels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.label) })
        #expect(labels["unpin"] == "Unpin thread" && labels["unsettle"] == "Un-settle thread" && labels["unsnooze"] == "Wake thread")
        #expect(labels["regenerate-title"] == "Regenerating…" && labels["filter-by-project"] == "Show all projects")
        #expect(items.first { $0.id == "auto-settle" }?.children.map(\.checked) == [false, true])
    }

    @Test func snoozeSubmenuListsPresetsThenCustom() {
        var s = ThreadActionMenu.State()
        s.canSnoozeNow = false
        s.snoozePresets = [SnoozePreset(id: "hour", label: "In 1 hour", whenLabel: "1:00 PM", snoozedUntil: Date())]
        let snooze = ThreadActionMenu.items(s).first { $0.id == "snooze" }
        #expect(snooze?.disabled == true)
        #expect(snooze?.children.map(\.label) == ["In 1 hour (1:00 PM)", "Custom…"])
    }

    @Test func readOnlyConnectionsKeepLocalActions() {
        var s = ThreadActionMenu.State()
        s.canOperate = false
        let items = ThreadActionMenu.items(s)
        #expect(items.first { $0.id == "mark-unread" }?.disabled == false)
        #expect(items.first { $0.id == "settle" }?.disabled == true)
        #expect(items.first { $0.id == "copy" }?.children.allSatisfy { !$0.disabled } == true)
    }

    @Test func removingDropsItemsAtAnyDepth() {
        let items = ThreadActionMenu.removing(["snooze:custom", "delete"], from: ThreadActionMenu.items(ThreadActionMenu.State()))
        #expect(!items.contains { $0.id == "delete" })
        #expect(items.first { $0.id == "snooze" }?.children.contains { $0.id == "snooze:custom" } == false)
    }
}

@Suite("Undo notice")
@MainActor
struct ThreadUndoLedgerTests {
    @Test func consecutiveActionsOfOneKindGroup() {
        let ledger = ThreadUndoLedger()
        ledger.show(.settled, claim: ledger.begin("settle", "a")) {}
        ledger.show(.settled, claim: ledger.begin("settle", "b")) {}
        #expect(ledger.notice?.action == .settled && ledger.notice?.count == 2)
        #expect(ThreadUndoLedger.text(.settled, count: 2) == "Settled 2 threads,")
        ledger.show(.snoozed, claim: ledger.begin("snooze", "c")) {}
        #expect(ledger.notice?.action == .snoozed && ledger.notice?.count == 1)
        #expect(ThreadUndoLedger.text(.snoozed, count: 1) == "Snoozed 1 thread,")
    }

    @Test func aLaterClaimExpiresTheUndo() {
        let ledger = ThreadUndoLedger()
        ledger.show(.unpinned, claim: ledger.begin("pin", "a")) {}
        ledger.invalidate("pin", "a")
        #expect(ledger.notice == nil)
        let stale = ledger.begin("settle", "b")
        _ = ledger.begin("settle", "b")
        ledger.show(.settled, claim: stale) {}
        #expect(ledger.notice == nil)
    }

    @Test func undoRunsTheGroupOnce() async {
        let ledger = ThreadUndoLedger()
        var runs: [String] = []
        ledger.show(.settled, claim: ledger.begin("settle", "a")) { runs.append("a") }
        ledger.show(.settled, claim: ledger.begin("settle", "b")) { runs.append("b") }
        #expect(ledger.undoLatest())
        #expect(!ledger.undoLatest())
        #expect(ledger.notice == nil)
        for _ in 0..<10 where runs.count < 2 { await Task.yield() }
        #expect(runs.sorted() == ["a", "b"])
    }

    @Test func expiryEndsEverything() {
        let ledger = ThreadUndoLedger()
        ledger.show(.archived, claim: ledger.begin("archive", "a")) {}
        ledger.expireAll()
        #expect(ledger.notice == nil)
        #expect(!ledger.undoLatest())
    }
}
