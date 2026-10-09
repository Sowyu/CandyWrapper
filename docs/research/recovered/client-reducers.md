# T3 Code shared client runtime: shell stream, thread stream, history paging, streaming text, command dispatch

Source studied: /Users/mrm/CandyWrapper-research/t3code at tag v0.0.46-nightly.20261009.2861 (HEAD 3b6af0bd1). Read-only research. All paths are repo-relative. "CR" means `packages/client-runtime/src`. Line numbers refer to that checkout. Anything not confirmed by reading code or tests is marked UNVERIFIED. Server files are cited only as context for what the client receives.

---

## 0. Wiring and file map

- Web and mobile provide the same loaders: `BoundedThreadSnapshotLoader.layer`, `ShellSnapshotLoader.layer`, `ThreadHistoryController.layer` (apps/web/src/connection/runtime.ts:17-22, apps/mobile/src/connection/runtime.ts:21-25). Both provide an `HttpClient` (apps/web/src/lib/runtime.ts:20, apps/mobile/src/lib/runtime.ts:20). Consequence: `canLoadHistory` (CR/state/threads.ts:220) is true in both official clients, so every thread subscription sends `acceptBoundedSnapshot: true` and `acceptCompactTurnItems: true`.
- Shell pipeline: `makeEnvironmentShellState` (CR/state/shell.ts:70-428), atoms in `createEnvironmentShellAtoms` (shell.ts:542-567). `createEnvironmentSnapshotAtom` (CR/state/snapshots.ts:7-20) exposes `state.snapshot` or null. `createThreadEnvironmentAtoms` wraps that snapshot with an optimistic lifecycle overlay (CR/state/threadCommands.ts:407-410) and the thread list atoms read the overlay (apps/web/src/state/threads.ts:20-31; CR/state/threadShell.ts:32-229).
- Thread pipeline: `makeEnvironmentThreadState` (CR/state/threads.ts:170-905), atom families in `createEnvironmentThreadStateAtoms` (threads.ts:920-964), derived atoms in `createEnvironmentThreadDetailAtoms` (CR/state/threadDetail.ts:24-199).
- The raw `v2.shell`, `v2.thread`, `v2.dispatchCommand`, `v2.threadProjection` atoms (CR/state/orchestration.ts:15-35) are not used by web or mobile (no `orchestrationEnvironment.v2` usage found). Apps use `threadFind`, `threadFindProgressive`, `threadSearch`, `turnItem`, `turnDiff`, `fullThreadDiff`, `archivedShellSnapshot`.
- Both streams run inside `followStreamInEnvironment` (CR/state/environmentStreams.ts:22-35 -> CR/connection/registry.ts:446-475). It re-acquires the environment supervisor whenever the catalog entry object changes and yields nothing while the environment is not registered.
- Keys: `threadKey = ${environmentId}\u0000${threadId}` (CR/state/entities.ts:52-54).

---

## 1. Shell stream

### 1.1 Wire types

- `OrchestrationV2ShellSnapshot` = `{schemaVersion, snapshotSequence, threads: ThreadShell[], archivedThreads: ThreadShell[], projects: ProjectShell[]}` (packages/contracts/src/orchestrationV2.ts:1931-1943). Thread shell row fields at 1836-1928 (id, projectId, title, providerInstanceId, modelSelection, runtimeMode, interactionMode, branch, worktreePath, linkedPullRequest?, pullRequests?, branchPullRequest?, lineage, forkedFrom, activeProviderThreadId, latestRunId, activeRunId, status, pendingRuntimeRequest, latestVisibleMessage, latestUserMessageAt, hasActionableProposedPlan, pendingBackgroundTasks (default []), providerInstanceHistory (default []), itemCount, visibleItemCount, createdAt, updatedAt, archivedAt, settledOverride, settledAt, unsettledAt?, snoozedUntil?, snoozedAt?, pinnedAt?, autoSettleDisabledAt?, pinOrderKey?, activeOrderKey?, lastVisitedAt?, titleRegeneration?, deletedAt, plus others).
- Stream items `OrchestrationV2ShellStreamItem` (orchestrationV2.ts:1945-1982):
  - `{kind: "synchronized"}`
  - `{kind: "snapshot", snapshot, resolvedRepositoryIdentityRoots?: string[]}`
  - `{kind: "project.updated", sequence, project}`
  - `{kind: "project.removed", sequence, projectId}`
  - `{kind: "thread.updated", sequence, location: "active" | "archive", thread}`
  - `{kind: "thread.removed", sequence, location: "active" | "archive", threadId}`
- There is no forward-compatible "unknown" arm for shell items (unlike the thread stream). The reducer `default` branch returns the snapshot unchanged (CR/state/shellReducer.ts:197-198), but an unknown kind should fail decoding first. How that failure surfaces is UNVERIFIED.

### 1.2 RPC and input

- RPC `orchestration.subscribeShell` (orchestrationV2.ts:3151). Input `OrchestrationV2SubscribeShellInput` = `{afterSequence?: NonNegativeInt, requestCompletionMarker?: boolean}`, both optionalKey (orchestrationV2.ts:3223-3235). Declared errors `OrchestrationV2GetShellSnapshotError | EnvironmentAuthorizationError` (packages/contracts/src/rpc.ts:1651-1656).
- The client sends exactly one of: `{}`, `{requestCompletionMarker: true}`, `{afterSequence: N}`, `{afterSequence: N, requestCompletionMarker: true}` (shell.ts:387-404).
- `requestCompletionMarker` is sent iff `session.initialConfig.shellResumeCompletionMarker === true` (shell.ts:337-340; flag declared at packages/contracts/src/server.ts:671; server advertises it at apps/server/src/ws.ts:1728). Config read errors count as false.

Pseudo-code, `makeSubscribeInput` (shell.ts:335-405):

```
makeSubscribeInput(session):
  activeSubscriptionSession := session                                         // 336
  supportsMarker := initialConfig(session).shellResumeCompletionMarker == true // 337-340
  awaitingCompletion := supportsMarker                                         // 341
  setSynchronizing()  // status "synchronizing", error none                    // 342, 149-153
  hasAuthoritative := (lastAuthoritativeSession === session)                    // 347
  canResume := hasAuthoritative
  current := state
  if !hasAuthoritative or current.snapshot is None:                             // 350
     prepared := supervisor.prepared, waiting until it is Some                  // 351-364
     http := ShellSnapshotLoader.load(prepared)   // Option<DeferredShellSnapshot>  // 365
     if http is Some:
        cancelActiveFill()                                                      // 367
        snapshot := reuseUnchangedThreadShells(previous snapshot or null,
                                               withoutDeferredPullRequests(http)) // 368-372
        pendingLinkIds := http.loadPullRequests defined ? ids of http.threads : {} // 373-377
        applyItems([{kind: "snapshot", snapshot}], pendingLinkIds)  // authoritative (no roots)  // 378
        canResume := true                                                       // 379
        current := state
        if current.snapshot is Some: fillDeferredPullRequests(http, current.snapshot)  // 381-383
  if !canResume or current.snapshot is None:
     return supportsMarker ? {requestCompletionMarker: true} : {}              // 389-391
  if !supportsMarker: status := "live", error := none                          // 392-400
  return {afterSequence: current.snapshot.snapshotSequence,
          ...(supportsMarker ? {requestCompletionMarker: true} : {})}           // 401-404
```

Consequences:
- On every new RpcSession the client reloads the HTTP shell snapshot first and resumes the socket from that HTTP snapshot's sequence. Test: shell-sync.test.ts:251-335 (disk cache had sequence 5, HTTP returned 9, socket afterSequence was 9).
- The disk cache is never used as a resume cursor. It renders immediately with status "cached" until the HTTP or socket snapshot lands.
- If HTTP fails on a new session, the cached cursor is deliberately omitted so the server sends a full snapshot frame (comment shell.ts:387-388).
- A same-session foreground resubscribe skips HTTP and resumes from the in-memory cursor. Test shell-sync.test.ts:337-454: afterSequences `[10, 40, 40]` with one loader call; replacing the session triggers another HTTP load and afterSequence 20.
- `lastAuthoritativeSession` becomes `activeSubscriptionSession` whenever `applyItems` received any item of kind "snapshot" (shell.ts:222, 240-245). By code reading this includes enrichment-only snapshots (not separately tested).

### 1.3 HTTP shell snapshot (CR/state/shellSnapshotHttp.ts)

- `GET /api/orchestration/shell` (line 51), header `x-t3-orchestration-protocol: 2` via `withOrchestrationProtocolHeader` (CR/state/environmentHttpAuth.ts:27-36; constants packages/contracts/src/environment.ts:13-16), timeout 20_000 ms (line 29), `responseMode: "response-only"` with manual decode (58-62, 70-90).
- Success is a `DeferredShellSnapshot`: thread rows are decoded with `pullRequests` detached; `loadPullRequests` decodes them later in batches of 400 links with a 1 ms host yield (CR/state/shellPullRequests.ts:16-20, 24, 30, 36-46, 52-84, 91-97). A thread whose links fail to decode gets no links (71-78).
- Any failure (timeout, HTTP status, decode) logs a warning and returns `Option.none()` (shellSnapshotHttp.ts:117-130). "Fallback" therefore means: HTTP is primary for every new session, and the socket-embedded snapshot is the fallback whenever HTTP returns none.
- Auth for all orchestration HTTP calls (environmentHttpAuth.ts:46-96, 107-231): no credential -> fetch with `credentials: "include"` (cookie); Bearer -> `authorization: Bearer <token>`; DPoP -> `authorization: DPoP <accessToken>` plus `dpop: <proof bound to method and url>`. A DPoP request rejected with `EnvironmentAuthInvalidError` reason `invalid_credential` is retried once with a refreshed token (196-205). The timeout covers the whole loop (224-230). For relay targets the refreshed `httpBaseUrl` is used (175-178).

### 1.4 `applyItems` reducer (shell.ts:186-249)

Runs under `snapshotWriteLock` (Semaphore 1; shell.ts:181, 249). Called once per array chunk received from the RPC stream (`Stream.runForEachArray`, shell.ts:411). One state write per call.

```
applyItems(items, pendingLinkIds?):
  initial := state; waiting := awaitingCompletion; next := initial; receivedSnapshot := false
  for item in items:
    if item.kind == "synchronized":                                           // 196-202
       waiting := false
       if next.snapshot is Some: next := {...next, status: "live", error: none}
       continue
    if item.kind == "snapshot":                                               // 204-213
       nextSnapshot := mergeShellSnapshotProjects(next.snapshot or null, item.snapshot,
            item.resolvedRepositoryIdentityRoots === undefined ? undefined
            : {resolvedRepositoryIdentityRoots: item.resolvedRepositoryIdentityRoots})
    else:                                                                     // 214-220
       nextSnapshot := next.snapshot is None ? null
            : item.sequence > next.snapshot.snapshotSequence ? applyShellStreamEvent(next.snapshot, item)
            : next.snapshot
    if nextSnapshot == null: continue       // deltas before any snapshot are dropped  // 221
    receivedSnapshot ||= item.kind == "snapshot"                               // 222
    next := {snapshot: Some(nextSnapshot), status: waiting ? "synchronizing" : "live", error: none}  // 223-227
  awaitingCompletion := waiting                                               // 229
  if next === initial: return                                                 // 230
  if pendingLinkIds given and next.snapshot is Some:
     pendingLinkRows := rows of next.snapshot.threads whose id is in pendingLinkIds   // 231-235
  if next.snapshot is Some: latestLiveSnapshot := next.snapshot               // 236-238
  state := next                                                               // 239
  if receivedSnapshot and activeSubscriptionSession != null:
     lastAuthoritativeSession := activeSubscriptionSession                    // 240-245
  if next.snapshot !== initial.snapshot and is Some: persistence.offer(next.snapshot.value)  // 246-248
```

Notes:
- A stale or duplicate delta still produces a new state object (status recomputed, error cleared) whose snapshot value is the same object.
- With the marker requested, status stays "synchronizing" through catch-up until `synchronized` arrives.

### 1.5 `mergeShellSnapshotProjects` (shellReducer.ts:90-133)

```
mergeShellSnapshotProjects(previous, next, options?):
  if previous is null or undefined: return next                              // 95-97
  if options defined:   // enrichment frame (resolvedRepositoryIdentityRoots present)   // 102-120
     nextById := next.projects by id
     return {...previous, projects: previous.projects.map(p =>
        c := nextById[p.id]
        if c undefined or c.workspaceRoot != p.workspaceRoot: return p
        if p.workspaceRoot in options.resolvedRepositoryIdentityRoots:
           return {...p, repositoryIdentity: c.repositoryIdentity}           // exact, including null
        if p.repositoryIdentity == null and c.repositoryIdentity != null:
           return {...p, repositoryIdentity: c.repositoryIdentity}
        return p)}
     // threads, archivedThreads, snapshotSequence, schemaVersion all stay from previous
  // authoritative frame
  previousById := previous.projects by id
  return {...next, projects: next.projects.map(p => retainRepositoryIdentity(previousById[p.id], p))}  // 122-132
```

- `retainRepositoryIdentity(prev, next)` (56-68): if `next.repositoryIdentity == null` and `prev?.repositoryIdentity != null` and `prev.workspaceRoot === next.workspaceRoot`, keep the previous identity; else next.
- The `resolvedRootSet` check inside the authoritative branch (127-129) has no effect because `resolvedRootSet` is null when options is undefined.
- Authoritative snapshots replace structure and sequence even when their sequence is lower than the client's (shellReducer.test.ts:151-169; shell-sync.test.ts:897-957). Enrichment snapshots never change structure or sequence, whatever their sequence (shellReducer.test.ts:171-300).

### 1.6 `applyShellStreamEvent` delta reducer (shellReducer.ts:136-200)

```
applyShellStreamEvent(snapshot, event):
  if event.sequence <= snapshot.snapshotSequence: return snapshot              // 143
  switch event.kind:
   "project.updated":                                                          // 146-158
      prev := snapshot.projects.find(id == event.project.id)
      return {...snapshot, projects: upsertById(snapshot.projects, retainRepositoryIdentity(prev, event.project)),
              snapshotSequence: event.sequence}
   "project.removed":                                                          // 159-164
      return {...snapshot, projects: filter(id != event.projectId), snapshotSequence: event.sequence}
   "thread.updated":                                                           // 165-189
      existing := event.location == "active" ? snapshot.threads.find(id == event.thread.id) : undefined
      if existing and sameThreadShell(existing, event.thread):
         return {...snapshot, snapshotSequence: event.sequence}      // keep list and row objects
      return {...snapshot,
              threads: event.location == "active" ? upsertById(snapshot.threads, event.thread)
                                                  : snapshot.threads without event.thread.id,
              archivedThreads: snapshot.archivedThreads without event.thread.id,
              snapshotSequence: event.sequence}
   "thread.removed":   // location ignored                                    // 190-196
      return {...snapshot, threads: without threadId, archivedThreads: without threadId,
              snapshotSequence: event.sequence}
   default: return snapshot                                                    // 197-198
```

- `upsertById` (47-54): replace in place at the existing index; append at the end when new.
- `sameThreadShell` = `Schema.toEquivalence(OrchestrationV2ThreadShell)` (line 10): deep structural equality of the full row, including `updatedAt`.
- Archive-located `thread.updated` removes the row from both lists; the archive is a separate query (comment 183-185; test shellReducer.test.ts:430-448).
- Reducer order = snapshot order plus append order. It never sorts. Tests: in-place update keeps siblings (shellReducer.test.ts:30-46), unchanged update keeps the list object (48-61), stale project updates ignored (63-81), unknown kinds unchanged (461-468).

### 1.7 Sequence handling

- Dedupe: deltas with `sequence <= snapshot.snapshotSequence` are skipped (shell.ts:217; shellReducer.ts:143). The cursor is `snapshot.snapshotSequence`, moved to `event.sequence` by every applied delta.
- No gap detection. Shell sequences are global event-store sequences: server `latestApplicationSequence` = MAX(sequence) over project events and v2 thread events (apps/server/src/persistence/OrchestrationEventStore.ts:617-628). The server coalesces per aggregate in windows of 512 events or 50 ms and suppresses unchanged rows (apps/server/src/ws.ts:1032-1038; apps/server/src/orchestration-v2/ShellStream.ts:86-100, 227-273). Gaps are normal.
- An authoritative snapshot can move the cursor backwards (server reset). An enrichment snapshot never moves it.

### 1.8 Statuses and connection phases

- `EnvironmentShellStatus` = "empty" | "cached" | "synchronizing" | "live" (shell.ts:42). State `{snapshot: Option, status, error: Option<string>}` (44-48).
- Init: cached snapshot -> "cached", else "empty" (88-92); then immediately `setSynchronizing` (331).
- Supervisor phase mapping via `connectionProjectionPhase` (CR/connection/model.ts:153-167; shell.ts:413-425): connecting -> `setSynchronizing` (status "synchronizing", error none, 149-153); connected -> `setReady` (if not live: "synchronizing", error none, 154-162); available/offline/backoff/blocked -> `setDisconnected` (awaitingCompletion false, status "cached"/"empty", forked cache flush, 139-148).
- Expected stream failure -> `setStreamError`: awaitingCompletion false, status "cached"/"empty", error "Could not synchronize environment data." (68, 163-177).

### 1.9 Reconnect, resume, retry (CR/rpc/client.ts `subscribeDynamicMapped`, 254-396)

- Session source: `SubscriptionRef.changes(supervisor.session)` merged with the `resubscribe` stream (271-280). `switchMap`: a None session yields an empty stream (the previous subscription is interrupted, including any in-flight makeInput work); a Some session runs `makeInput` then the RPC.
- Foreground resubscribe triggers: ConnectionWakeups "application-active" and "application-active-probe" only (CR/connection/wakeups.ts:28-30; shell.ts:325-329). "application-active-reconnect" does not resubscribe because the session is replaced.
- Transport failure (every cause reason is a Fail with `RpcClientError`): log "Durable RPC subscription lost its transport; waiting for the next session." and stop (331-351).
- Other expected failures (Fail, not RpcClientError): `onExpectedFailure`, then retry on the same session after `min(250 ms * 2^n, 30_000 ms)` (106, 352-380); n resets to 0 on the first value of a resubscribed stream (298, 309-315). `EnvironmentAuthorizationError` is not retried (356-365).
- Defects (Die) fail the stream (381). The shell has no `onDefect` hook.
- Connection-level reconnect: backoff ceiling `min(300_000, 1_000 * 2^(failureCount + 1))`, delay uniform in the upper half of the ceiling (CR/connection/supervisor.ts:35-36, 137-140). Session set None on disconnect (385), Some on connect (767).
- The WebSocket RPC protocol never retries: `retryTransientErrors: false`, `retryPolicy: Schedule.recurs(0)` (CR/rpc/session.ts:203-206); socket open timeout 15 s (45).

### 1.10 Deferred pull request links and row reuse

- `reuseUnchangedThreadShells(previous, next)` (shellReducer.ts:26-45): for each incoming row with a prior row of the same id, build `candidate` that borrows `prior.pullRequests` when the incoming row has none; if `sameThreadShell(prior, candidate)`, keep the prior object. Only used on the HTTP path (shell.ts:369-372). Identity-preserving, except that a deferred row temporarily keeps its prior links.
- `fillDeferredPullRequests` (shell.ts:265-280) and `writeFilledLinks` (281-320): once links decode, write them only into rows that are still the same objects that arrived with that snapshot (`arrivedRows.has(thread)`) and whose id was in it. Rows replaced by later deltas keep their own links (shell-sync.test.ts:959-1054). A missing map entry removes `pullRequests` from the row (299-302). Each new snapshot cancels the previous fill (269, 367).
- While links are pending, cache saves are skipped if the latest snapshot contains a pending row (106-113; shell-sync.test.ts:1139-1204).

### 1.11 Shell persistence

- `Queue.sliding(1)` plus `runCachePersistence` (shell.ts:99, 137; CR/state/cachePersistence.ts:7-19): wait for the first value, sleep 500 ms, take the newest, then loop {persist; sleep 10 s; take}. Only the newest pending snapshot is written.
- `persistLatest(flush)` (shell.ts:106-131): writes `latestLiveSnapshot` if it is not the object last persisted and has no pending-link rows. Disconnect and scope close flush and chase newer values (135, 146).
- Disk record (CR/platform/orchestrationCache.ts:12-18): `{schemaVersion: 3, environmentId, snapshot: OrchestrationV2ShellSnapshotJson}`. Undecodable caches are discarded (31-36).
- Throttle evidence: shell-sync.test.ts:456-538 (saved sequences `[1, 10, 11]`).

### 1.12 Server behavior the shell client depends on (context)

From apps/server/src/ws.ts:943-1184 and apps/server/src/orchestration-v2/ShellStream.ts:
- No afterSequence: authoritative snapshot (no roots field), then optionally a same-sequence enrichment snapshot (threads [], archivedThreads [], only resolved projects, `resolvedRepositoryIdentityRoots` set) (ShellStream.ts:186-212), then `synchronized` if requested, then live deltas.
- With afterSequence: if the gap exceeds `SHELL_RESUME_MAX_GAP = 1_000`, the replay payload exceeds 8 MiB, or the cursor is invalid, the full snapshot path runs (ws.ts:551, 555, 686-713, 1141-1149). Otherwise: an enrichment-only snapshot (omitted when no roots resolved, ShellStream.ts:215-222), replayed deltas, `synchronized`, live (ws.ts:1151-1162).
- Enrichment refreshes can arrive at any time as snapshots with threads [] and archivedThreads [] and the roots field. A native client must never treat a snapshot carrying `resolvedRepositoryIdentityRoots` as authoritative. Repeated identical enrichment frames are dropped server-side (ShellStream.ts:118-158).
- Archiving emits `thread.removed` (location "active") in the active shell; deleted or unknown threads also emit `thread.removed` (ShellStream.ts:292-319).
- `thread.updated` deltas that differ only in `updatedAt` are suppressed for up to 5_000 ms (ShellStream.ts:227-273). Client `updatedAt` can lag by that much.

### 1.13 Display ordering (presentation only, CR/state/threadSort.ts)

- `sortThreads`: descending `getThreadSortTimestamp` (latestUserMessageAt, else newest user message createdAt, else updatedAt/createdAt; "created_at" order uses createdAt), id tiebreak descending (109-152).
- Settled rows: `resolveSettledThreadTimestamp` = settledAt, else max of latestUserMessageAt and latestRun requested/started/completed, else updatedAt; newest first, id ascending tiebreak (30-69).
- Pinned block: keyed rows by `pinOrderKey` string compare, then id, then environmentId; keyless rows by createdAt descending (306-339).
- Active list: keyless rows first by anchor `max(createdAt, unsettledAt)` descending, then keyed rows by `activeOrderKey` (129-137, 343-376).
- Navigation lists exclude archived rows and `lineage.relationshipToParent === "subagent"` (CR/state/threadShell.ts:202-215).

### 1.14 Archived threads (CR/state/archivedThreads.ts)

- Not streamed. Query `orchestration.getArchivedShellSnapshot` with input `{}` (CR/state/orchestration.ts:76-79), default SWR stale 30_000 ms and idle TTL 300_000 ms (CR/state/runtime.ts:541, 591).
- Aggregated per key of sorted environment ids joined by "\u001f" (archivedThreads.ts:19-38) into `{snapshots, error: "Failed to load archived threads." or null, isLoading}` (40-69). `orchestration.subscribeArchivedShell` exists in contracts but web and mobile do not use it.

---

## 2. Thread detail

### 2.1 Wire types

- Subscribe input `OrchestrationV2SubscribeThreadInput` (orchestrationV2.ts:3238-3257): `threadId`, `afterSequence?`, `requestCompletionMarker?`, `acceptBoundedSnapshot?`, `acceptCompactTurnItems?`. There is no window parameter; the server picks the window.
- Stream items `OrchestrationV2ThreadStreamItem` (3366-3392):
  - `{kind: "synchronized"}`
  - `{kind: "snapshot", snapshotSequence, projection, historyCursor?: string | null, hasMoreHistory?: boolean, latestLocalTurnOrdinal?: number | null, payloadBudgetExceeded?: boolean, turnItemsOmitLocalVisible?: true}`
  - `{kind: "event", sequence, event: OrchestrationV2DomainEvent}`
  - decode-only `{kind: "unknown-event", sequence, eventType}` for an unknown event type, or a `turn-item.updated` whose turn item type is unknown (3320-3364). A known type whose payload does not decode still fails.
- Event base `{id, threadId, runId?, nodeId?, driver?, providerInstanceId?, rawEventId?, occurredAt}` (1634-1643); union 1645-1783.
- Projection fields (1785-1811): thread, runs, attempts, nodes, subagents, providerSessions, providerThreads, providerTurns, runtimeRequests, messages, plans, turnItems, checkpointScopes, checkpoints, contextHandoffs, contextTransfers, visibleTurnItems, updatedAt.
- Projected row (1610-1617): `{position, visibility: "local" | "inherited" | "synthetic", sourceThreadId, sourceItemId, item}`.
- Forward compatibility: arrays of turn items and projected rows drop unknown item types during decode (orchestrationV2.ts:1586-1608; packages/contracts/src/baseSchemas.ts:265-286). Positions are not renumbered by decode (code reading; UNVERIFIED by tests).
- Declared errors `OrchestrationV2GetThreadProjectionError | EnvironmentAuthorizationError` (rpc.ts:1658-1663).

### 2.2 Local state

- `EnvironmentThreadState = {data: Option<projection>, status: "empty" | "cached" | "synchronizing" | "live" | "deleted", error: Option<string>, history: ThreadHistoryMeta}` (CR/state/threadState.ts:6-18). EMPTY = `{none, "empty", none, EMPTY_THREAD_HISTORY_META}` (20-25).
- `ThreadHistoryMeta = {historyCursor: string | null, hasMoreHistory: boolean, loading: boolean, error: string | null, expanded: boolean, latestLocalTurnOrdinal: number | null}` (CR/state/threadHistoryMerge.ts:7-19). EMPTY = `{null, false, false, null, false, null}` (21-28). History errors are thread-local and never become the stream error (threadState.ts:12-16).
- Per-instance refs (threads.ts): `lastSequence` (227), `awaitingCompletion` (235), `acceptsBoundedSocketSnapshots` (221, initialised to canLoadHistory and never set false), `applyLock` Semaphore(1) (236), `committed` resume snapshot (228-234), persistence `Queue.sliding(1)` (252).

### 2.3 Lifetime, retention, ownership

- Live atom family keyed by threadKey with idle TTL 0: the subscription closes when the last consumer unmounts (threads.ts:940-958; threads-atoms.test.ts:265-280).
- Resume cache family with idle TTL `THREAD_SNAPSHOT_IDLE_TTL_MS = 5 * 60_000` (CR/state/threadRetention.ts:3; threads.ts:931-939). It holds `{snapshot: {state, sequence, persisted, acceptsBoundedSnapshots}, owner}`. On remount within 5 minutes the retained state is emitted first through `cachedThreadState`, and the new subscription resumes from the retained sequence with no disk read and no HTTP (threads.ts:186-204, 949-951; threads-atoms.test.ts:282-311, 313-344). After 5 idle minutes it is gone (362-378). It is local to each atom registry (346-360).
- `owner` token: each instance claims `resumeCache.owner` (188-189). Only the current owner writes the resume cache, persists, or removes the disk cache (234, 250, 257, 283, 425). Tests threads-sync.test.ts:547-579, 581-616, 618-640.
- `remember` (239-251) commits `{state, sequence, acceptsBoundedSnapshots, persisted}` together after a whole `applyItems` batch, so a cancelled scope never caches a cursor whose data was not applied (threads-sync.test.ts:493-545).
- `cachedThreadState(value)` (158-168): keeps "deleted"; keeps "live" only when data is present; otherwise "cached"/"empty"; error cleared; `history.loading = false`, `history.error = null`.

### 2.4 Initial load order

1. Retained in-memory resume snapshot (5 minutes).
2. Else disk `cache.loadThread(environmentId, threadId)`; read errors log a warning and count as none (190-204). History meta via `historyMetaFromCachedSnapshot` (74-88): `historyCursor ?? null`, `hasMoreHistory ?? false`, `expanded: false`, `latestLocalTurnOrdinal ?? null`.
3. If there is still no data when the subscription starts: HTTP snapshot through `ThreadSnapshotLoader` (816-873).
4. Socket subscription: resume with `afterSequence` when data exists, else receive a snapshot frame.

`ThreadSnapshotLoader` bounded layer used by web and mobile (CR/state/boundedThreadSnapshotHttp.ts:68-174):

```
load(prepared, threadId):
  GET /api/orchestration/threads/{id}/bounded?compactTurnItems=1     // timeout 6_000 ms   // 20, 27-58
     projection := boundedSnapshotProjection({...snapshot, turnItemsOmitLocalVisible})  // marker dropped  // 53-56
  success -> {_tag: "present",
              snapshot: {snapshotSequence, projection, latestLocalTurnOrdinal},
              history: {historyCursor, hasMoreHistory, latestLocalTurnOrdinal}}           // 122-134
  EnvironmentResourceNotFoundError -> {_tag: "missing"}                                   // 137-145
  RemoteEnvironmentAuthInvalidJsonError -> fullFallback                                   // 146-152
  RemoteEnvironmentAuthUndeclaredStatusError with status 404 -> fullFallback (older server) // 153-158
  anything else -> {_tag: "unavailable"}                                                  // 160-169

fullFallback: GET /api/orchestration/threads/{id}   // timeout 20_000 ms (threadSnapshotHttp.ts:22, 53-77)
  success -> {_tag: "present", snapshot}   // no history -> complete timeline                  // 82-92
  EnvironmentResourceNotFoundError -> missing; anything else -> unavailable               // 93-113
```

Tests: CR/state/boundedThreadSnapshotHttp.test.ts:123-290 (compact restore, plain route 404 fallback, structured 404 missing, transient 503 unavailable without full fallback).

### 2.5 `makeSubscribeInput` (threads.ts:799-894)

```
makeSubscribeInput(session):
  current := state
  if current.status == "deleted": park forever (Effect.never); never open the socket   // 804-806
  supportsMarker := initialConfig.threadResumeCompletionMarker == true (errors -> false) // 808-811
  awaitingCompletion := supportsMarker                                                  // 812
  markSynchronizing()   // unless resumingLive: status "synchronizing", error none (deleted kept) // 784-793, 813
  resumingLive := false                                                                 // 814
  if current.data is None:                                                              // 816
     prepared := supervisor.prepared, waiting until Some                                // 817-830
     r := snapshotLoader.load(prepared, threadId)                                       // 831-832
     present:                                                                           // 834-861
        if canLoadHistory and r.history defined: acceptsBoundedSocketSnapshots := true
        under applyLock:
           lastSequence := r.snapshot.snapshotSequence
           history := r.history defined
              ? {historyCursor: r.history.historyCursor, hasMoreHistory: r.history.hasMoreHistory,
                 loading: false, error: null, expanded: false,
                 latestLocalTurnOrdinal: r.history.latestLocalTurnOrdinal ?? null}
              : EMPTY_THREAD_HISTORY_META
           setThread(r.snapshot.projection, {history})
           remember()
        current := state
     missing: setDeleted(); park forever (no socket, no retry)                         // 862-867
     unavailable: fall through to the socket                                            // 868-871
  sequence := lastSequence; canResume := current.data is Some                          // 875-876
  acceptBounded := acceptsBoundedSocketSnapshots                                        // 877
  if !supportsMarker and canResume: status := "live" (unless deleted), error := none    // 878-884
  return {threadId,
          ...(canResume ? {afterSequence: sequence} : {}),
          ...(supportsMarker ? {requestCompletionMarker: true} : {}),
          ...(acceptBounded ? {acceptBoundedSnapshot: true, acceptCompactTurnItems: true} : {})}  // 886-893
```

- `resumingLive` (783) is true only when the retained state was "live" with data. It suppresses the "synchronizing" flash for the first subscription after a warm return.
- Subscription options (895-900): `onDefect` -> `setStreamError("Could not synchronize the thread.")`; `onExpectedFailure` -> `setStreamError(formatThreadError(cause))` (message of the squashed error, else "Could not synchronize the thread.", 60-65); `retryExpectedFailureAfter: "250 millis"`; `resubscribe` = foreground wakeups (774-778).
- Tests: HTTP seed then resume from its sequence (threads-sync.test.ts:1091-1122), bounded meta install (1124-1163), definitive 404 never subscribes or retries even after a session replacement or wakeup (1782-1814), transient HTTP failure falls back to the socket (1816-1843), warm cache resumes without HTTP (677-697).

### 2.6 Stream application

`applyItems` (threads.ts:613-635), under `applyLock`, once per received array chunk (901):

```
applyItems(items):
  events := []
  for item in items:
    if item.kind == "unknown-event" or (item.kind == "event" and item.event.type != "thread.deleted"):
       events.push(item); continue
    applyEventsLocked(events); events := []
    applyItemLocked(item)          // snapshot, synchronized, or a thread.deleted event
  applyEventsLocked(events)
  remember()
```

Snapshots, completion markers and deletions are ordering boundaries inside a batch (threads-atoms.test.ts:558-600: `[title 8, bounded snapshot 20, title 21, title 19, synchronized]` ends with the title from 21, cursor 21, history from the snapshot).

`applyItemLocked` (571-611):

```
synchronized:                                                                 // 574-582
   awaitingCompletion := false
   if data is Some and status != "deleted" and error is None: status := "live"
snapshot:                                                                     // 584-608
   lastSequence := item.snapshotSequence          // unconditional, may move backwards
   projection := boundedSnapshotProjection(item)  // restores compact turnItems
   if historyCursor, hasMoreHistory or latestLocalTurnOrdinal is present (not undefined):
      setThread(projection, {history: {historyCursor: item.historyCursor ?? null,
                hasMoreHistory: item.hasMoreHistory ?? false, loading: false, error: null,
                expanded: false, latestLocalTurnOrdinal: item.latestLocalTurnOrdinal ?? null}})
   else:
      setThread(projection, {resetHistory: true})   // legacy full snapshot clears progressive meta
thread.deleted event:
   applyEventsLocked([item])                                                  // 610
```

`applyEventsLocked` (444-569):

```
applied := lastSequence; seq := applied; fresh := []
for item in items:
  if item.sequence <= seq: continue                     // dedupe            // 451
  seq := item.sequence                                  // unknown events advance the cursor too  // 452-453
  if item.kind == "event": fresh.push(item)
  else debug log "Skipped a thread event type this client does not know." (eventType sliced to 64 chars)  // 458-466
if seq == applied: return                                                     // 468
lastSequence := seq                                     // before the state write  // 469
if fresh is empty: return                                                     // 470
waiting := awaitingCompletion
result := atomically modify state, folding applyEvent over fresh; stop after the first "delete"  // 539-551
if result is delete: setDeleted(); return                                     // 553-556
if result is applied and shouldPersistThread(result.projection, result.history):
   persistence.offer(snapshotToPersist(lastSequence, result.projection, result.history,
                                       acceptsBoundedSocketSnapshots))         // 557-568
```

`applyEvent` (485-537):

```
if status == "deleted": noop
if data is None: event.type == "thread.deleted" ? delete : noop   // dropped, but the cursor already moved
if event.type == "thread.deleted": delete
partial := (history.hasMoreHistory or history.historyCursor != null)
           ? {partialTimeline: true, latestLocalTurnOrdinal: history.latestLocalTurnOrdinal}
           : undefined                                   // expanded is not consulted (502-511)
next := applyOrchestrationV2ProjectionEvent(data, event, partial)
if next == null or next === data: noop                   // true no-op: no status/error change, no persistence (516-518)
history2 := history
if partial and event.type == "turn-item.updated" and
   (history.latestLocalTurnOrdinal == null or payload.ordinal > history.latestLocalTurnOrdinal):
   history2 := {...history, latestLocalTurnOrdinal: payload.ordinal}                 // 521-527
return applied, state {...current, data: Some(next), status: waiting ? "synchronizing" : "live",
                       error: none, history: history2}                              // 529-536
```

Applying any event clears a stream error (533).

`setThread` (357-408):

```
waiting := awaitingCompletion
state := update(prev => {...prev, data: Some(thread),
   status: prev.error is Some ? "cached" : waiting ? "synchronizing" : "live",
   error: prev.error,                      // values buffered from a failed attempt keep the error
   history: options.history ?? (options.resetHistory ? EMPTY_THREAD_HISTORY_META : prev.history)})
if shouldPersistThread(thread, next.history):
   persistence.offer(snapshotToPersist(lastSequence, thread, next.history, acceptsBoundedSocketSnapshots))
```

`setDeleted` (416-437): awaitingCompletion false; state `{data: none, status: "deleted", error: none, history: EMPTY}`; remember; if owner, `cache.removeThread`.

### 2.7 Projection event reducer (CR/state/orchestrationV2Projection.ts:153-286)

```
applyOrchestrationV2ProjectionEvent(projection, event, options?):
  if projection == null or event.threadId != projection.thread.id: return projection    // 158
  partial := options.partialTimeline == true; W := options.latestLocalTurnOrdinal
  base := {...projection, updatedAt: event.occurredAt}                                  // 162
  switch event.type (table below)
```

| Event type | Effect | Lines |
|---|---|---|
| thread.created, thread.archived, thread.unarchived, thread.deleted, thread.settled, thread.unsettled, thread.snoozed, thread.unsnoozed, thread.auto-settle-set, thread.pinned, thread.unpinned, thread.pin-reordered, thread.active-reordered, thread.metadata-updated, thread.pull-request-synced, thread.runtime-mode-updated, thread.interaction-mode-updated, thread.model-selection-updated, thread.provider-switched | `{...base, thread: payload}`: whole AppThread replaced, updatedAt bumped | 164-183 |
| thread.visited, thread.marked-unread | `{...projection, thread: payload}`: no updatedAt bump | 185-187 |
| run.created, run.updated | runs = upsertEntity(runs, payload); then visibleTurnItems = activeVisibleTurnItems(next) | 188-192 |
| run.background-work-cancelled | the run with id == payload.runId gets restartCancelledBackgroundWork = payload.restartCancelledBackgroundWork (single-field merge) | 193-204 |
| run-attempt.created, run-attempt.updated | attempts upsert; visibleTurnItems = activeVisibleTurnItems | 205-209 |
| node.updated | nodes upsert | 210-211 |
| subagent.updated | subagents upsert | 212-213 |
| provider-session.attached, provider-session.updated | providerSessions upsert | 214-219 |
| provider-session.detached | providerSessions filter id != payload.providerSessionId | 220-226 |
| provider-thread.updated | providerThreads upsert | 227-228 |
| provider-turn.updated | providerTurns upsert of payload, with tokenUsage = payload.tokenUsage ?? previous tokenUsage (key omitted when both undefined) | 229-244 |
| runtime-request.updated | runtimeRequests upsert | 245-246 |
| message.updated | messages upsert | 247-248 |
| plan.updated | plans upsert | 249-250 |
| turn-item.updated | see below | 251-273 |
| checkpoint-scope.created | checkpointScopes upsert | 274-275 |
| checkpoint.captured | checkpoints upsert | 276-277 |
| checkpoint.rollback-requested | base only (updatedAt bump) | 278-279 |
| context-handoff.updated | contextHandoffs upsert | 280-281 |
| context-transfer.created, context-transfer.updated | contextTransfers upsert | 282-284 |

- `upsertEntity` (16-25): find by `candidate.id === item.id`; replace the whole entity at that index, else append at the end. Whole-entity replacement everywhere except run.background-work-cancelled (one field) and provider-turn tokenUsage carry-over (test orchestrationV2Projection.test.ts:108-145).
- thread.deleted never reaches the reducer from threads.ts because applyEvent short-circuits it.

`turn-item.updated` (251-273):

```
if partial and payload.id not in projection.turnItems and shouldDropMissingPartialTurnItem(projection, payload, W):
   return projection                       // same reference -> true no-op upstream
next := {...base, turnItems: upsertEntity(base.turnItems, payload)}
prev := projection.turnItems.find(id == payload.id)
visible := (payload.type == "run_interrupt_request" or prev?.type == "run_interrupt_request")
           ? {...next, visibleTurnItems: activeVisibleTurnItems(next)}
           : next          // streaming text or tool updates do not recheck every row
return {...next, visibleTurnItems:
          isVisible(payload, next.runs, next.attempts, next.turnItems)
            ? upsertVisibleTurnItem(visible, payload, partial, W)
            : removeVisibleItem(visible.visibleTurnItems, payload.id)}
```

`upsertVisibleTurnItem` (108-150):

```
rows := projection.visibleTurnItems
index := rows.findIndex(row.sourceItemId == item.id)          // matches on sourceItemId only
newRow := {position: 0, visibility: "local", sourceThreadId: item.threadId, sourceItemId: item.id, item}
if index found and prev row has same visibility, sourceThreadId, sourceItemId and prev.item === item: return rows
if index not found and partial and shouldDropMissingPartialTurnItem(projection, item, W): return rows
updated := rows without index (if found)
ins := first index in updated where row.visibility == "local" and
       (row.item.ordinal > item.ordinal or
        (row.item.ordinal == item.ordinal and String(row.item.id).localeCompare(String(item.id)) > 0))
insert newRow at ins, or at the end when none
return renumber positions 0..n-1 (rows whose position already matches keep their object)
```

- An updated visible row is removed and re-inserted by (ordinal, id). Inherited and synthetic rows are skipped by the insertion predicate. Code observation (not tested): matching by `sourceItemId` alone could collide with an inherited row that has the same item id from another thread.
- `removeVisibleItem` (27-34): remove the first row with `sourceItemId == id`, renumber.

`shouldDropMissingPartialTurnItem` (89-106):

```
if some visible row has sourceItemId == item.id: false
if W != null and W != undefined and item.ordinal <= W: true
oldest := min ordinal over visible rows with visibility "local"
return oldest != null and item.ordinal < oldest
```

`activeVisibleTurnItems` (54-74): keep rows where `visibility != "local"` or the item is visible; remove the rest; renumber only when something was removed. It never adds rows back.

Visibility predicate (packages/shared/src/orchestrationV2Timeline.ts:42-73, indexed variant 76-112):
- hidden if `item.runId` refers to a run with status "rolled_back";
- hidden if `item.type == "user_message"`, `item.inputIntent == "queued_turn"` and its run status is "cancelled";
- hidden if `item.type == "run_interrupt_result"` with runId and nodeId, an attempt of that run with `rootNodeId == item.nodeId` has status "superseded", and no "run_interrupt_request" item exists for that run (14-40);
- otherwise visible.

Ordering summary:
- runs, attempts, nodes, subagents, providerSessions, providerThreads, providerTurns, runtimeRequests, messages, plans, turnItems, checkpointScopes, checkpoints, contextHandoffs, contextTransfers: snapshot order, new entities appended, updates in place. The client never sorts them.
- visibleTurnItems is the ordered timeline: snapshot order; live local inserts by (item.ordinal, String(item.id)) relative to local rows; older pages prepended in page order; positions renumbered 0..n-1 after every mutation (orchestrationV2Projection.test.ts:205-243, 245-276, 278-313).
- Derived queue order: `(run.queuePosition ?? run.ordinal)` ascending, then `run.ordinal` (CR/state/threadWorkflows.ts:137-142).

More reducer tests: lifecycle payload replaces thread and bumps updatedAt (orchestrationV2Projection.test.ts:147-160); another thread's event returns the same reference (162-172); run update keeps row identity (174-203); a streaming update does not scan every row (316-351).

### 2.8 Compact bounded snapshots (packages/shared/src/orchestrationV2BoundedSnapshot.ts)

- `isLocalTimelineRow(projection, row)` = `row.visibility == "local" || row.sourceThreadId == projection.thread.id` (7-12).
- `restoreLocalVisibleTurnItems` (40-48): `turnItems := [items of local rows in visibleTurnItems order] ++ projection.turnItems`.
- `boundedSnapshotProjection(snapshot)` (51-58): restore only when `turnItemsOmitLocalVisible === true`.
- Server half `omitLocalVisibleTurnItems` (21-34) only omits when turnItems starts with exactly the local rows' items.
- The client restores before reducing and before caching; the cached snapshot carries no marker (threads-sync.test.ts:984-1089).

### 2.9 Dedupe, gaps, resets, unknown events, deletion

- Dedupe: `sequence <= lastSequence` per item, within and across batches (threads.ts:451; threads-sync.test.ts:1845-1862).
- No gap detection. Thread sequences are global event-store sequences filtered to the thread (`latestAgentSequence`, OrchestrationEventStore.ts:597-614). The server live coalescer drops intermediate running tool updates (apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts:18-19, 24-37, 48-86: 50 ms window, 512 max pending, keeps the latest per (threadId, runId, item id) for running command_execution, file_change, file_search, web_search, dynamic_tool; terminal updates kept; order preserved; any non-tool event flushes the window).
- Reset: any `snapshot` item replaces the projection wholesale and sets `lastSequence = snapshotSequence`, which may go down. The server sends a snapshot instead of a replay when afterSequence exceeds the thread high water, the replay exceeds 128 events, raw payload exceeds 1 MiB, encoded replay exceeds 1 MiB, or the replay range contains a create event for a thread that exists (apps/server/src/ws.ts:869-937; apps/server/src/orchestration-v2/ThreadStream.ts:15-25, 106-124). With acceptBoundedSnapshot that snapshot is bounded (row limit 77, 10 user turns; ws.ts:826-860; threadHistoryPaging.ts:13-28).
- Unknown events advance the cursor with no state change (threads.ts:452-466; threads-sync.test.ts:2040-2100, cursor ends at the trailing unknown sequence).
- Deletion: a fresh `thread.deleted` event or an HTTP 404 calls setDeleted. Deleted is sticky in the resume cache for 5 minutes and is not replaced by the disk snapshot (threads-sync.test.ts:642-665). Queued saves and finalizers never recreate the disk cache (persist checks the committed status, threads.ts:259; test 1864-1892).
- `thread.archived` does not delete the detail; only the thread payload changes.

### 2.10 Status transitions and errors

- Phase mapping (760-772): synchronizing -> `setConnecting` (if not deleted and no error: "synchronizing", error none; 320-328); ready -> `setReady` (if not live, deleted or errored: "synchronizing"; 329-337); disconnected -> `setDisconnected` (awaitingCompletion false; "cached"/"empty" unless deleted; 338-344).
- `setStreamError` (345-355): awaitingCompletion false; "cached"/"empty" unless deleted; error set; data preserved (threads-sync.test.ts:1894-1933).
- Retry policy as in section 1.9 plus `onDefect`. A domain failure such as "thread not found yet" retries on the same session after 250 ms (threads-sync.test.ts:1935-1973).
- With the marker, replayed events keep "synchronizing" until `synchronized` (2009-2038). Without the marker, "live" is set when resuming (threads.ts:878-884).
- Replacement sessions and foreground wakeups resume from the latest applied sequence and show "synchronizing" until the marker (2102-2128, 2130-2182).

### 2.11 Thread persistence

- `shouldPersistThread` (110-122): false if `history.expanded`; false if any run status is "preparing", "starting" or "running"; otherwise true ("queued" and "waiting" do not block).
- `snapshotToPersist` (90-108): when acceptsBoundedSnapshots, hasMoreHistory, or historyCursor != null: `{snapshotSequence, projection, historyCursor, hasMoreHistory, latestLocalTurnOrdinal}`; otherwise `{snapshotSequence, projection}`. In web and mobile acceptsBoundedSnapshots is always true, so the progressive fields are always written, possibly null/false (threads-sync.test.ts:383-413, 1421-1427).
- Writer: sliding queue plus `runCachePersistence` (500 ms first write, then at most every 10 s, newest wins; threads.ts:318). Scope close persists the committed state (298-316). `persist` skips when not owner, when deleted, or when the same projection reference, sequence and history were already persisted (254-296). A failed write is retried by the finalizer (threads-sync.test.ts:415-445). Coalescing evidence 699-733.
- Disk record `{schemaVersion: 3, environmentId, threadId, snapshot}` with projection JSON (CR/platform/orchestrationCache.ts:20-28).
- A legacy cache without history fields is complete and shows no load-earlier control (threads-sync.test.ts:1269-1281). A complete bounded cache still negotiates bounded fallbacks (1283-1343). Without HttpClient or controller the bounded flags are omitted (1345-1377).

### 2.12 Derived atoms (CR/state/threadDetail.ts)

- `threadAtom`: `{environmentId, projection}` memoized on the projection reference (40-51).
- `visibleTurnItemsAtom` = `createQuestionHistoryProjector()(projection)` (53-59). The projector (CR/state/threadRequests.ts:118-173): for each visible row whose item is `user_input_request` without `questionAnswer`, if `runtimeRequests[item.requestId]` has status "resolved" and `answers` defined, the row is replaced with `item.questionAnswer = {requestId, answers, attachmentsByQuestionId: {}, questionTextById: {question.id: question.question}}`. Other rows unchanged; memoized.
- `pendingRequestsAtom` (132-165) -> `derivePendingThreadRequests` (threadRequests.ts:66-115): iterate runtimeRequests with status "pending" in array order. Kind "user_input": use the last `user_input_request` turn item with that requestId (skip if none) -> `{requestId, createdAt (ISO), questions (multiSelect default false), responseCapability (type), dismissible: item.responseMode == "message" or capability == "message", responseMode: "message" when so}`. Kinds "auth_refresh" and "dynamic_tool_call" are skipped. Other kinds -> approval `{requestId, requestKind, createdAt, detail: item.prompt, appName, options, responseCapability: "live" or "not_resumable"}` from the last `approval_request` item (may be absent).
- `queueWorkflowAtom` -> `deriveThreadQueueWorkflowState` (threadWorkflows.ts:127-163); `queuedCountAtom` -> `getUserQueuedThreadRuns` (111-125: runs with status "queued" excluding runs whose userMessageId belongs to a message with `delegatedCompletion` or `notification`); `turnSubagentsAtom`; `worktreePathAtom`; `statusAtom`; `errorAtom`; `historyAtom`. These recompute only when their input arrays change identity (tests threadDetail.test.ts:111-328).

---

## 3. History paging

### 3.1 Trigger

- Explicit user action, not scroll. Web button "Load earlier turns" (apps/web/src/components/chat/MessagesTimeline.tsx:1648-1674); mobile "Load earlier activity" (apps/mobile/src/features/threads/ThreadFeed.tsx:3259-3285). Both are disabled while loading and shown iff `hasMoreHistory || error != null` (`shouldShowLoadEarlierControl`, CR/state/threadHistoryMerge.ts:152-154; apps/web/src/components/ChatView.tsx:1732-1750; apps/mobile/src/features/threads/ThreadRouteScreen.tsx:256-275).
- Web in-thread find: when the match entry is not among loaded rows, it calls `onLoadEarlier(match.entryId)` once per (match, first loaded row id) (apps/web/src/components/chat/useThreadFindNavigation.ts:88-105). This is the only caller passing `throughEntryId`.
- Command `threadEnvironment.loadEarlierHistory` with `{threadId, throughEntryId?}` (CR/state/threadCommands.ts:375-399) -> `ThreadHistoryController.loadEarlier` -> the handler registered by the mounted thread state (threads.ts:751-758). No handler -> `{_tag: "noop"}` (CR/state/threadHistoryController.ts:82-91). Results: loaded, noop, busy, error {message} (9-13). Unregister only removes the handler if it still owns the key (67-81).
- It runs in the same serial lane as every other command for that thread (key `JSON.stringify([environmentId, threadId])`, shared scheduler; threadCommands.ts:145-150, 395-398).

### 3.2 Request

- `GET /api/orchestration/threads/{threadId}/history` (CR/state/threadHistoryHttp.ts:33). Query: `cursor` (required), `view` ("conversation" only in the first stage of a search load), `throughEntryId` (optional) (36-44; packages/contracts/src/environmentHttp.ts:595-599). Header `x-t3-orchestration-protocol: 2`. Timeout 6_000 ms (14). Same auth as section 1.3.
- Response `OrchestrationV2ThreadHistoryPage = {snapshotSequence, items (projected rows, chronological), nextCursor: string | null, hasMoreHistory}` (orchestrationV2.ts:3306-3318). The client ignores `page.snapshotSequence`.
- Server context: the cursor is opaque (clients must not parse it, orchestrationV2.ts:3279-3281; internally base64 JSON `{v: 1, seq, st, si, p}`, max 4_096 chars, threadHistoryPaging.ts:31, 39-45). Older pages default to 20 user turns, 75 items, 1 MiB; `throughEntryId` (matched against `item.messageId ?? item.id`) can widen a page up to 40 turns and 150 items (threadHistoryPaging.ts:13-19, 281-324). `view=conversation` drops command_execution, reasoning, file_change and dynamic_tool rows when the range has user turns (22-24; apps/server/src/orchestration-v2/ProjectionStore.ts:4924-4931, 4985-4987).

### 3.3 `loadEarlier` (threads.ts:637-749)

```
loadEarlier(throughEntryId?):
  cur := state
  if cur.status == "deleted" or data is None or !history.hasMoreHistory or history.historyCursor == null:
     return noop                                                              // 641-648
  if history.loading: return busy                                             // 649-651
  requestCursor := history.historyCursor                                      // 655
  if history.historyCursor == requestCursor: history.loading := true, history.error := null   // 656-660
  failLoad(msg): if history.historyCursor == requestCursor: loading false, error msg -> {error, msg}
                 else noop                                                    // 662-680
  if supervisor.prepared is None or no HttpClient: failLoad("Environment is not connected.")  // 683-685
  views := throughEntryId undefined ? [undefined] : ["conversation", undefined]             // 687-688
  for view in views:
     page := fetch(cursor: requestCursor, view, throughEntryId)
             or failLoad(error message, else "Could not load earlier activity.")           // 690-700, 67-72
     complete := (view == undefined); waiting := awaitingCompletion
     under applyLock, atomically:                                             // 706-732
        if history.historyCursor != requestCursor: noop (state untouched)
        if data is None or deleted: noop, history := EMPTY
        data := mergeOlderHistoryIntoProjection(data, page.items)
        status := (complete and waiting) ? "synchronizing" : status
        history := complete ? applyHistoryPageMeta(history, page) : {...history, expanded: true}
     if result != loaded: return result
     if complete: remember()
  return loaded
on interrupt: history := clearActiveHistoryLoading(requestCursor, history)    // 741-748, 42-50
```

- The registered handler forks the load into the thread state scope, so unmounting cancels in-flight page loads; a warm return retries with the same cursor (threads.ts:754-755; threads-atoms.test.ts:380-410).
- Two-stage search load: the conversation page merges first (expanded true, cursor unchanged, still loading), then the full page with the same cursor merges and advances the cursor (threads-sync.test.ts:851-982).

### 3.4 `mergeOlderHistoryIntoProjection` (threadHistoryMerge.ts:67-131)

```
merge(projection, olderItems):
  if olderItems is empty: return projection
  key(row) := `${row.sourceThreadId}:${row.sourceItemId}`
  currentByKey := visibleTurnItems by key
  turnItemById := Map(String(item.id) -> item) over projection.turnItems (insertion order)
  pageKeys := {}; page := []
  for pageRow in olderItems:
     k := key(pageRow); if k in pageKeys: continue                  // dedupe inside the page
     row := currentByKey[k] ?? pageRow                              // live row object wins
     if k not in currentByKey and (row.visibility == "local" or row.sourceThreadId == projection.thread.id):
        live := turnItemById[String(row.sourceItemId)]
        if live defined:                                             // item known but hidden now
           if live.type != "run_interrupt_request" or !isVisible(live, runs, attempts, turnItems): continue
           row := {...row, item: live}                               // live value wins
     pageKeys.add(k); page.push(row)
     if row is local-like and String(row.sourceItemId) not in turnItemById:
        turnItemById.set(String(row.sourceItemId), row.item)        // appended to turnItems
  if page is empty: return projection
  visible := page ++ [rows of projection.visibleTurnItems whose key is not in pageKeys]
  if visible is element-wise identical to projection.visibleTurnItems: return projection
  return {...projection, turnItems: values(turnItemById), visibleTurnItems: renumberVisible(visible)}
```

- Precedence: an entity present both live and in the page keeps the live object and live item value, at the page's position. Hidden live items stay hidden. Inherited rows never enter turnItems. Rows not in the page keep their relative order after the page.
- Tests: threadHistoryMerge.test.ts:48-91 (fills gaps, keeps live edits, keeps hidden rows hidden), 93-115 (prepend, dedupe, turnItems order `[item-2, item-3, item-0, item-1]`), 117-141 (same item id from different source threads), 143-178, 263-289, 291-486 (interrupt request retained at cold open becomes visible through a page).
- `applyHistoryPageMeta` (133-149): `{historyCursor: page.nextCursor, hasMoreHistory: page.hasMoreHistory, loading: false, error: null, expanded: true, latestLocalTurnOrdinal: unchanged}`.
- End of history: `page.hasMoreHistory == false` (with `nextCursor` null). The control disappears unless an error is set.

### 3.5 Interplay and retry

- Any snapshot (socket full, socket bounded, HTTP install) replaces history meta; an in-flight page for the old cursor resolves noop (threads-sync.test.ts:851-982 "replacement snapshot" mode).
- The partial-timeline rule (section 2.7) applies only while `hasMoreHistory` or `historyCursor != null`. The watermark `latestLocalTurnOrdinal` advances on each applied `turn-item.updated` and is preserved across pages (threads-sync.test.ts:1555-1668, 1670-1749).
- `expanded: true` blocks disk persistence for that instance; the in-memory resume cache keeps the expanded data for 5 minutes.
- No automatic retry. The next click retries with the same cursor (threads-sync.test.ts:965-969).

---

## 4. Streaming assistant text

### 4.1 What arrives

- There are no append deltas. Text arrives as full entity snapshots:
  - `message.updated`, payload `OrchestrationV2ConversationMessage` `{id, threadId, runId, nodeId, role: "user" | "assistant" | "system", text, context?, attachments, streaming, createdAt, updatedAt, notification?, delegatedCompletion?, ...}` (orchestrationV2.ts:1113-1137);
  - `turn-item.updated`, payload `assistant_message` `{messageId, text, attachments?, streaming}`, `reasoning` `{text, streaming}`, or `proposed_plan` `{planId, markdown, streaming}` (1390-1410), each with base fields `{id, threadId, runId, nodeId, providerThreadId, providerTurnId, nativeItemRef, parentItemId, ordinal, status, title, startedAt, completedAt, updatedAt, ...}` (1316-1335).
- The client replaces the whole entity by id in `messages` or `turnItems` and replaces or re-inserts the visible row. Render `text` (or `markdown` for proposed_plan). `streaming: true` means more will come; the final update has `streaming: false`. Test threads-atoms.test.ts:496-556 sends the full text each time and expects the last full text.

### 4.2 Server cadence (context)

apps/server/src/orchestration-v2/assistantStreaming.ts:92-128, per `${event type}:${message id}`:
- "turn" mode: all intermediate streaming updates are suppressed.
- "paragraph" mode (default; ResponseStreamingMode literals at packages/contracts/src/settings.ts:998, default "paragraph" at 1133-1135): at most one update per 400 ms (line 116), and only when the text up to the last safe markdown boundary changed. `splitBufferedAssistantText` (35-89) cuts at the last blank line, closing code fence, list item start, or top-level heading outside an open fence; a section title waits for content. The delivered `text` is that prefix, not the raw buffer.
- Non-streaming final events pass through with the full text. Running `assistant_message` node.updated events are dropped. The filtered text is what lands in the read model (comment line 91).

### 4.3 Client coalescing

- One state write per received RPC chunk: both pipelines use `Stream.runForEachArray` and fold the events between boundaries into one SubscriptionRef update (threads.ts:539-551, 613-635; shell.ts:183-249). Test: N updates in batches of B publish ceil(N/B) times (threads-atoms.test.ts:496-556). The RPC client can split server chunks into 16-item buffers (comment shell-sync.test.ts:163; UNVERIFIED in the RPC library source).
- Derived atoms are memoized on array identity, so streaming text does not recompute queue, subagent, pending request or worktree atoms (threadDetail.ts:61-165).
- No disk writes while a run is preparing, starting or running (threads.ts:110-122).
- No timer-based render throttle exists in client-runtime. App UI components were not exhaustively audited for one (UNVERIFIED).

### 4.4 Tool output on the wire (context)

The server wire projection omits `command_execution.output` (sets `outputOmitted: true` when non-empty and keeps `outputIndicatesFailure`), drops file_change diff text unless the edit failed, truncates subagent text, and summarizes large dynamic_tool values (apps/server/src/orchestration-v2/WireProjection.ts, `projectTurnItemForWire`; exact line numbers UNVERIFIED). Full items come from `orchestration.getTurnItem` `{threadId, itemId, revision?}` keyed by the item's updatedAt (orchestrationV2.ts:3458-3470; CR/state/orchestration.ts:47-53).

---

## 5. Command dispatch

### 5.1 Transport

- RPC `orchestration.dispatchCommand`: payload `OrchestrationV2Command` (union orchestrationV2.ts:2611-3054), success `{sequence: NonNegativeInt}` (3212-3215), errors `OrchestrationV2DispatchCommandError {commandId, commandType, message, detail?}` or `EnvironmentAuthorizationError` (rpc.ts:1559-1563).
- First message of a new thread, or a worktree launch: `orchestration.launchThread` with `OrchestrationV2ThreadLaunchInput`, success `{threadId, projection, resumed}` (orchestrationV2.ts:3182-3210). The returned projection does not seed client thread state.
- Projects: `projects.mutate` with `ProjectMutation` (packages/contracts/src/project.ts:220-239; CR/operations/commands.ts:310-339).
- Attachment upload: `assets.persistChatAttachments` `{threadId, messageId, attachments: entries that carry dataUrl}`, returning `{attachments}` mapped back by index; stored attachments pass through (commands.ts:282-308).
- All calls go through `request` -> `requestGuarded` (CR/rpc/client.ts:188-207, 441-444). No session -> `EnvironmentRpcUnavailableError` "<label> is not connected." (130-146).

### 5.2 commandId

- `allocateCommandId(input)` (commands.ts:261-267): a caller-provided `input.commandId` is used as is; otherwise `CommandId.make(crypto.randomUUIDv4)`.
- Format: RFC 4122 v4, lowercase hex, 8-4-4-4-12, no prefix (vendored effect: .repos/effect-smol/packages/effect/src/internal/uuid.ts:1-30, Crypto.ts:291). Zero-byte test crypto yields "00000000-0000-4000-8000-000000000000" (commands.test.ts:151-174).
- Derived ids: `${commandId}:model-selection` (commands.ts:595), `${commandId}:detach:${providerSessionId}` (928); mobile outbox `${commandId}:runtime-mode` and `${commandId}:interaction-mode` (apps/mobile/src/state/use-thread-outbox-drain.ts:205, 827, 844).
- Web message, thread, project and draft ids use its own v4 generator (apps/web/src/lib/utils.ts:36-50). Mobile uses `Crypto.randomUUID()` (apps/mobile/src/lib/uuid.ts:3).

### 5.3 Execution pipeline

- `createThreadEnvironmentAtoms` (threadCommands.ts:141-489) builds AtomCommands with `createEnvironmentCommand` (CR/state/runtime.ts:640-659) -> `createRuntimeCommand` (393-416) -> scheduler.
- Scheduler (runtime.ts:156-276): modes parallel, serial, singleFlight, latest; lanes per AtomRegistry. Thread commands are serial with key `JSON.stringify([environmentId, input.threadId])` (threadCommands.ts:146-150). Serial is FIFO and the next starts after the previous settles, success or failure (runtime.ts:210-227). forkFromRun key `[environmentId, sourceThreadId]` (threadCommands.ts:320-328); mergeBack key `[environmentId, sourceThreadId, targetThreadId]` (329-338).
- Results are AsyncResult Success or Failure; callers never see exceptions.

### 5.4 Optimistic state

(a) Lifecycle overlay (CR/state/threadLifecycle.ts; wiring threadCommands.ts:407-488). Only settle, unsettle, snooze, unsnooze, setAutoSettle, pin, unpin, reorderPin, reorderActive. It changes shell thread rows only, never the thread detail.

```
pending[env] := []          // keepAlive atom per environment                        // 23-25
overlay(env) := source shell snapshot where, per thread, pending updates are applied in insertion
                order, excluding updates whose sequence is defined and <= snapshot.snapshotSequence  // 26-49
wrap(command, apply).run(registry, {environmentId, input}):                          // 51-99
   now := DateTime.nowUnsafe()
   update := {threadId: input.threadId,
              apply: t => apply(t, input, now, accepted = (update.sequence !== undefined))}
   pending.push(update)      // visible at once, even while waiting in the serial lane
   result := await command.run(...)
   if Success:
      update.sequence := result.value.sequence; force recompute
      subscribe to the source shell snapshot: when snapshot == null or
         snapshot.snapshotSequence >= result.value.sequence -> remove update, unsubscribe (also checked immediately)
   finally, if not Success: remove update          // rollback on failure, defect or interrupt
```

Apply functions (threadCommands.ts:411-487):
- settle: unchanged if not accepted and (`pendingRuntimeRequest != null` or status in preparing, queued, starting, running, waiting); else `{pendingRuntimeRequest: null, settledOverride: "settled", settledAt: (already settled ? settledAt ?? now : now), unsettledAt: null, activeOrderKey: null, pinnedAt: null, pinOrderKey: null, snoozedAt: null, snoozedUntil: null}`.
- unsettle: `{settledOverride: reason == "user" ? "active" : null, settledAt: null, unsettledAt: settledOverride == "active" ? (unsettledAt ?? null) : now}`.
- snooze: unchanged if (not accepted and (`pendingRuntimeRequest != null` or status in preparing, queued, starting)) or `snoozedUntil` is not after now; else `{pendingRuntimeRequest: null, snoozedUntil: DateTime(input.snoozedUntil), snoozedAt: same snoozedUntil as before ? (snoozedAt ?? now) : now}`.
- unsnooze: `{snoozedUntil: null, snoozedAt: null}`.
- setAutoSettle: `autoSettleDisabledAt = enabled ? null : (autoSettleDisabledAt ?? now)`.
- pin: `{pinnedAt: pinnedAt ?? now, pinOrderKey: was unpinned ? (input.orderKey ?? null) : pinOrderKey, snoozedUntil: null, snoozedAt: null}` and, when settled, `settledOverride: "active", settledAt: null, unsettledAt: now`.
- unpin: `{pinnedAt: null, pinOrderKey: null}`. reorderPin: `pinOrderKey = orderKey`. reorderActive: `activeOrderKey = orderKey`.
- Tests CR/state/threadCommands.test.ts:140-376: rejection rollback, preview kept after acknowledgement until the shell reaches the acknowledged sequence, queued reverse action shown immediately, removed thread not restored, pending approval keeps the row unchanged, failed undo restores the confirmed state, newer approval preserved, accepted settle clears a stale input request in the overlay.

(b) Optimistic user messages are app-level, not in client-runtime. Web inserts an optimistic ChatMessage keyed by the client messageId before dispatch, removes it on failure, and retires it when the server holds that id: a `user_message` turn item's `messageId` in visibleTurnItems, or a projection message with role "user" (apps/web/src/components/ChatView.tsx:1751-1766, 6876-6909, 7421-7478; apps/web/src/components/ChatView.logic.ts:1213-1221). Mobile uses a persistent outbox (5.6).

(c) Queue entries are not optimistic in client-runtime. Queued items are projection runs with status "queued" (threadWorkflows.ts:111-125).

### 5.5 Use of the dispatch sequence

Only the lifecycle overlay uses it (threadLifecycle.ts:81-91). Thread detail never waits on a sequence. Web rollback waits on projection predicates instead (run rolled_back, or `thread.rollbackFailure.requestId == commandId`) with a 120_000 ms timeout (ChatView.logic.ts:1112-1152; ChatView.tsx:8466-8473).

### 5.6 Retry and idempotency

- client-runtime never retries a dispatch, and the RPC protocol has retries disabled (rpc/session.ts:203-206). Failures go back to the caller. Web does not retry either.
- Server idempotency by commandId (apps/server/src/orchestration-v2/Orchestrator.ts:10430-10481): an accepted receipt returns the original `resultSequence` (queue.resume also reruns `startNextQueuedRun`); a rejected receipt fails with `OrchestratorCommandPreviouslyRejectedError`; a receipt for another thread fails with `OrchestratorCommandIdConflictError`. Resending with the same commandId is safe.
- Callers wanting idempotent resends pass commandId (commands.test.ts:220-234). Mobile's outbox persists commandId and messageId and resends them (use-thread-outbox-drain.ts:911, 1056) with delay `min(1000 * 2^(attempt - 1), 16_000)` ms (apps/mobile/src/state/thread-outbox-model.ts:34, 172-174). It retries ConnectionTransientError, RpcClientError, EnvironmentRpcUnavailableError, EnvironmentNotRegisteredError; not OrchestrationDispatchCommandError or EnvironmentAuthorizationError (276-289).

### 5.7 Helper catalog (CR/operations/commands.ts unless noted)

Every payload carries `commandId` from allocateCommandId. `creationSource` defaults to "web". Atom names are the keys of `createThreadEnvironmentAtoms` (threadCommands.ts:151-406).

| Action | Helper (atom) | Lines | RPC | Payload |
|---|---|---|---|---|
| create thread | createThread (create) | 393-410 | dispatchCommand | `{type: "thread.create", commandId, createdBy: "user", creationSource, threadId, projectId, title, modelSelection, runtimeMode, interactionMode, branch, worktreePath}` |
| delete | deleteThread (delete) | 412-431 | dispatchCommand | `{type: "thread.delete", commandId, threadId}` |
| archive | archiveThread (archive) | 433-437 | dispatchCommand | `{type: "thread.archive", commandId, threadId}` |
| unarchive | unarchiveThread (unarchive) | 439-443 | dispatchCommand | `{type: "thread.unarchive", commandId, threadId}` |
| settle | settleThread (settle, optimistic) | 445-449 | dispatchCommand | `{type: "thread.settle", commandId, threadId}` (no settledAt; test 890-919) |
| unsettle | unsettleThread (unsettle, optimistic) | 506-515 | dispatchCommand | `{type: "thread.unsettle", commandId, threadId, reason: "user"}` |
| snooze | snoozeThread (snooze, optimistic) | 517-526 | dispatchCommand | `{type: "thread.snooze", commandId, threadId, snoozedUntil}` (ISO string) |
| unsnooze | unsnoozeThread (unsnooze, optimistic) | 528-537 | dispatchCommand | `{type: "thread.unsnooze", commandId, threadId, reason: "user"}` |
| auto-settle toggle | setThreadAutoSettle (setAutoSettle, optimistic) | 466-475 | dispatchCommand | `{type: "thread.auto-settle.set", commandId, threadId, enabled}` |
| pin | pinThread (pin, optimistic) | 451-461 | dispatchCommand | `{type: "thread.pin", commandId, threadId, orderKey?}` |
| unpin | unpinThread (unpin, optimistic) | 500-504 | dispatchCommand | `{type: "thread.unpin", commandId, threadId}` |
| reorder pinned | reorderPinnedThread (reorderPin, optimistic) | 477-487 | dispatchCommand | `{type: "thread.pin.reorder", commandId, threadId, orderKey}` |
| reorder active | reorderActiveThread (reorderActive, optimistic) | 489-498 | dispatchCommand | `{type: "thread.active.reorder", commandId, threadId, orderKey}` (test 921-939) |
| visited | visitThread (visit) | 539-548 | dispatchCommand | `{type: "thread.visit", commandId, threadId, visitedAt}` (ISO) |
| mark unread | markThreadUnread (markUnread) | 550-558 | dispatchCommand | `{type: "thread.mark-unread", commandId, threadId}` |
| rename, branch, worktree, regenerate title, link PR field, limit recovery | updateThreadMetadata (updateMetadata) | 560-585 | dispatchCommand | sent only if one of these is defined: `{type: "thread.metadata.update", limitRecovery?, commandId, threadId, title?, branch?, worktreePath?, regenerateTitle?, linkedPullRequest?}` |
| model change | updateThreadMetadata with modelSelection | 586-600 | dispatchCommand | type "thread.model-selection.set" when serverResolvedCommandContext, else `modelSelectionCommandType(projection.thread.providerInstanceId, selection)` = "thread.model-selection.set" if same instance, else "provider.switch" (packages/shared/src/model.ts:18-25); payload `{type, commandId (or ${commandId}:model-selection when a metadata command was sent first), threadId, modelSelection}`; returns `{sequence: 0}` when nothing was sent (tests 723-795) |
| runtime mode | setThreadRuntimeMode (setRuntimeMode) | 604-613 | dispatchCommand | `{type: "thread.runtime-mode.set", commandId, threadId, runtimeMode}` |
| interaction mode | setThreadInteractionMode (setInteractionMode) | 615-624 | dispatchCommand | `{type: "thread.interaction-mode.set", commandId, threadId, interactionMode}` |
| send, steer, queue, restart, launch | startThreadTurn (startTurn) | 626-773 | dispatchCommand or launchThread | see 5.8 |
| interrupt / Stop | interruptThreadTurn (interruptTurn) | 780-832 | dispatchCommand | see 5.9 |
| approve / deny | respondToThreadApproval (respondToApproval) | 834-844 | dispatchCommand | `{type: "runtime-request.respond", commandId, threadId, requestId, decision}`; decision is one of accept, acceptForSession, acceptAlways, decline, cancel (packages/contracts/src/providerPolicy.ts:50-56) |
| answer user input | respondToThreadUserInput (respondToUserInput) | 846-859 | dispatchCommand | `{type: "runtime-request.respond", commandId, threadId, requestId, answers, attachmentsByQuestionId?}`; answers is a record string -> unknown (providerPolicy.ts:67, 70-75) |
| dismiss user input | dismissThreadUserInput (dismissUserInput) | 861-870 | dispatchCommand | `{type: "thread.user-input.dismiss", commandId, threadId, requestId}` (test 941-961) |
| rollback | revertThreadCheckpoint (revertCheckpoint) | 872-917 | dispatchCommand | `{type: "checkpoint.rollback", restoreFiles?, commandId, threadId, scopeId, checkpointId}`; see 5.10 |
| stop provider session | stopThreadSession (stopSession) | 919-935 | dispatchCommand | per providerSession: `{type: "provider-session.detach", commandId: ${commandId}:detach:${session.id}, threadId, providerSessionId, reason: "client-requested"}`; returns last result or `{sequence: 0}` |
| fork | forkThreadFromRun (forkFromRun) | 937-950 | dispatchCommand | `{type: "thread.fork", commandId, createdBy: "user", creationSource, sourceThreadId, targetThreadId, sourcePoint: {type: "run", runId}, title?}` |
| merge back | mergeThreadBack (mergeBack) | 952-964 | dispatchCommand | `{type: "thread.merge_back", commandId, createdBy: "user", creationSource, sourceThreadId, targetThreadId, sourcePoint: {type: "run", runId}}` |
| resume queue | resumeThreadQueue (resumeThreadQueue) | 966-974 | dispatchCommand | `{type: "queue.resume", commandId, threadId}` |
| queue reorder | reorderQueuedRun (reorderQueuedRun) | 976-986 | dispatchCommand | `{type: "queued-run.reorder", commandId, threadId, runId, beforeRunId}` (RunId or null) |
| queue promote to steer | promoteQueuedRun (promoteQueuedRun) | 988-998 | dispatchCommand | `{type: "queued-message.promote-to-steer", commandId, threadId, queuedRunId, targetRunId}` |
| queue cancel | cancelQueuedRun (cancelQueuedRun) | 1000-1009 | dispatchCommand | `{type: "queued-run.cancel", commandId, threadId, runId}` |
| retry workspace preparation | retryWorkspacePreparation | 1011-1020 | dispatchCommand | `{type: "prepared-run.retry", commandId, threadId, runId}` |
| queue edit | editQueuedRun (editQueuedRun) | 1022-1046 | dispatchCommand | `{type: "queued-run.edit", commandId, threadId, runId, text, attachments?, context?}`; attachments (full replacement list, persisted first against edit.messageId) only when `input.edit` is given; context only when `edit.context` and attachments exist; a text-only edit sends no attachments key (test 635-721) |
| link, unlink, watch PR | linkThreadPullRequest, unlinkThreadPullRequest, watchThreadPullRequest | 1058-1089 | dispatchCommand | `{...input, type: "thread.pull-request.link" or "thread.pull-request.unlink" or "thread.pull-request.watch", commandId}`; input carries host, repository, number (packages/contracts/src/threadPullRequest.ts:89-93) plus url and source (manual, created, agent, stack, stack-dismissed; 35-41) for link, watching and optional link for watch. The spread also forwards any CommandMetadata fields present on input; how the server treats such extra keys is UNVERIFIED |
| upload feedback | uploadFeedback (threadCommands.ts:400-405) | | provider.uploadFeedback | RPC input shape not reviewed (UNVERIFIED) |
| create project | createProject (CR/state/projectCommands.ts:104-109) | 341-358 | projects.mutate | `{type: "project.create", commandId, projectId, title, workspaceRoot, createWorkspaceRootIfMissing?, defaultModelSelection?, scripts?}` |
| update project | updateProject (projectCommands.ts:110-115) | 360-380 | projects.mutate | `{type: "project.update", commandId, projectId, title?, workspaceRoot?, defaultModelSelection?, autoPull?, projectIcon?, faviconPath?, defaultThreadEnvMode?, scripts?}` |
| delete project | deleteProject (projectCommands.ts:116-121) | 382-391 | projects.mutate | `{type: "project.delete", commandId, projectId, force?}` |

- Project commands are serial per `[environmentId, projectId]` (projectCommands.ts:79-83). `buildProjectCreateCommand` (CR/operations/projects.ts:353-367) builds `{type: "project.create", commandId, projectId, title: inferProjectTitleFromPath(workspaceRoot), workspaceRoot, createWorkspaceRootIfMissing: true, defaultModelSelection: null}`.
- Pin and active order keys come from `planPinnedReorder`, `pinOrderKeyBetween`, `planPinnedMove`, `generateSpreadPinOrderKeys` (CR/state/threadSort.ts:223-230, 234-255, 265-298, 384-400): base-26 fractional keys over "a".."z" (a trailing "a" is invalid); a move writes one key to the moved thread, or rewrites the section with spread keys when a neighbor is keyless or keys are corrupt.

### 5.8 `startThreadTurn` (commands.ts:626-773)

```
commandId := allocateCommandId(input)
attachments := persistAttachments(threadId, message.messageId, message.attachments)
context := remapComposerContextAttachments(message.context, message.attachments, attachments)
if bootstrap.createThread or bootstrap.prepareWorktree:                                  // 640-687
   thread := bootstrap.createThread ?? getThreadProjection(threadId).thread
   workspaceStrategy :=
      prepareWorktree ? {type: "worktree", baseRef: baseBranch, branch?, startFromOrigin?}
      : bootstrap.worktreePath ? {type: "existing_worktree", worktreePath, branch? (when not null)}
      : {type: "root", branch? (when not null or undefined)}
   return launchThread({commandId, creationSource, threadId,
        reuseExistingThread: true (only when there is no createThread),
        projectId: thread.projectId, title: titleSeed ?? thread.title,
        generateTitle: titleSeed !== undefined,
        modelSelection: input.modelSelection ?? thread.modelSelection, runtimeMode, interactionMode,
        workspaceStrategy, initialMessage: {messageId, text, context?, attachments}})
mode := input.dispatchMode ?? "auto"
if mode == "start":                                                                       // 689-710
   return dispatch({type: "message.dispatch", commandId, createdBy: "user", creationSource, threadId,
        messageId, manualContinuationOfRunId?, text, context?, attachments, modelSelection?,
        sourcePlanRef?, dispatchMode: {type: "start_immediately"}})     // no titleSeed, no deliveryIntent
serverResolves := initialConfig.environment.capabilities.serverResolvedCommandContext == true  // 275-280
projection := serverResolves ? null : getThreadProjection(threadId)                       // 713
activeRun := projection.runs.findLast(status in preparing, starting, running, waiting)
caps := providerSessions[providerThreads[activeRun.providerThreadId].providerSessionId].capabilities.turns
dispatchMode :=                                                                           // 733-751
   serverResolves: mode == "queue" ? {type: "queue_after_active"} : {type: "start_immediately"}
   no activeRun: {type: "start_immediately"}
   steer: {type: "steer_active", targetRunId: activeRun.id}
   restart: {type: "restart_active", targetRunId: activeRun.id}
   queue: {type: "queue_after_active"}
   auto: caps.supportsActiveSteering ? steer_active
         : caps.supportsQueuedMessages ? queue_after_active
         : caps.supportsSteeringByInterruptRestart ? restart_active
         : queue_after_active
titleSeed included iff input.titleSeed defined and (serverResolves or projection.messages.length == 0)  // 752-754
return dispatch({type: "message.dispatch", commandId, createdBy: "user", creationSource, threadId, messageId,
     text, context?, attachments, titleSeed?, modelSelection?, sourcePlanRef?,
     deliveryIntent: mode (only when serverResolves and mode != "queue"), dispatchMode})   // 755-772
```

- `sourceProposedPlan` maps to `sourcePlanRef: {threadId, planId}`. The `message.dispatch` schema (orchestrationV2.ts:2837-2876) also allows `defer_start` and other continuation fields that this helper never sends.
- Tests: commands.test.ts:280-318 (plan provenance, deliveryIntent "auto"), 320-402 (launch strategies), 404-438 (server-resolved: queue -> queue_after_active without deliveryIntent; auto, steer, restart -> start_immediately with deliveryIntent; no projection fetch), 440-503 (legacy shaping), 963-996 (explicit start).
- Composer mode selection (CR/state/composerDispatch.ts:11-21): not running -> "auto"; running -> `activeTurnDefault ?? "steer"`; the alternate modifier flips queue and steer, and from "restart" the alternate is "queue".
- `deriveThreadTitleSeed` (CR/operations/threadTitle.ts:14-33): normalized text truncated to 50 characters plus "..." (packages/shared/src/String.ts:1-8), else "Image: <first attachment name>", else first fallback label, else "New thread".

### 5.9 `interruptThreadTurn` (commands.ts:780-832)

```
runId := input.runId ?? input.turnId
if runId undefined:
   projection := getThreadProjection(threadId)
   runId := last run with status preparing, starting, running or waiting
   if none:
      latest := runs.at(-1)
      if derivePendingBackgroundWork({latestRun: latest, providerThreads, turnItems,
            activeProviderThreadId: thread.activeProviderThreadId, runs}).length > 0: runId := latest.id
   if still none:
      result := {sequence: 0}
      for link in visibleThreadPullRequests(thread.pullRequests ?? [])   // source != "stack-dismissed"
            where link.watch defined:
         result := dispatch({type: "thread.pull-request.watch",
                   commandId: (result.sequence == 0 ? caller id or fresh : fresh UUID),
                   threadId, host, repository, number, watching: false})
      return result
return dispatch({type: "run.interrupt", commandId, threadId, runId, holdQueue: true})
```

- packages/shared/src/threadPullRequests.ts:81-85 for visibleThreadPullRequests. derivePendingBackgroundWork internals UNVERIFIED (packages/shared/src/orchestrationV2PendingBackgroundWork.ts:223).
- Tests commands.test.ts:505-557 (only watched, non-dismissed link unwatched), 559-633 (Stop dispatched for waiting, completed, failed, interrupted, cancelled runs with a background command; nothing for rolled_back), 998-1025 (known run, no projection fetch).

### 5.10 `revertThreadCheckpoint` (commands.ts:872-917)

- With checkpointId and scopeId and serverResolvedCommandContext: dispatch directly, no projection fetch.
- Otherwise fetch the projection: checkpoint = match on id and scopeId, else findLast where `turnCount == 0 ? (ordinalWithinScope == 0 and appRunOrdinal == null) : appRunOrdinal == turnCount`. Missing, or status != "ready" -> fail `OrchestrationV2CheckpointUnavailableError {threadId, target}` without dispatching (target "run ordinal N" or "checkpoint <id>").
- Tests commands.test.ts:236-278, 797-888.

---

## 6. Client-side validation and gating

- Scope guard: only methods in `CLIENT_GUARDED_RPC_SCOPES` are checked client-side (packages/contracts/src/clientRpcPermissions.ts:11-42): source-control:write for pull request actions, clone, VCS writes and git actions; orchestration:operate for scheduledTasks*. `gitPreparePullRequestThread` in worktree mode with a threadId needs both (47-59). `orchestration.dispatchCommand`, `orchestration.launchThread` and `projects.mutate` are not guarded client-side.
- `createEnvironmentRpcCommand` authorizes through `createCommandPermissions` (CR/state/runtime.ts:782-799; CR/state/commandPermissions.ts:17-73, 81-95): it mounts the session state atom, waits up to 6_000 ms (line 56), and fails with `EnvironmentAuthorizationError` when a required scope is missing per `sessionGrantsScope` (packages/contracts/src/auth.ts:181-192; scopes "orchestration:read", "orchestration:operate" at 82-83, "source-control:write" at 91). The permission is rechecked after waiting in a serial lane (commandPermissions.test.ts:121-160). The default `RpcPermissionGuard` denies guarded methods outside a command (CR/rpc/client.ts:156-186). Thread and project commands use `createEnvironmentCommand` and skip this check.
- App-level gate: web `useOrchestrationCommand` refuses when the environment lacks "orchestration:operate", failing with "This connection cannot change threads or projects." (apps/web/src/state/use-orchestration-command.ts:18-43). Mobile's outbox checks access before sending (hasAccess in use-thread-outbox-drain.ts; implementation UNVERIFIED).
- Capability shaping: `serverResolvedCommandContext` (commands.ts:275-280; packages/contracts/src/environment.ts:174) decides delivery shaping, model command type, and local checkpoint validation. Provider session turn capabilities decide legacy "auto" delivery. Completion markers depend on `shellResumeCompletionMarker` and `threadResumeCompletionMarker` (server.ts:671, 678). `threadSnapshotPagination` (684) is not used by client-runtime.
- Projection-derived affordances (CR/state/threadWorkflows.ts): `resolveActiveThreadRun` = last run with status preparing, starting, running or waiting (14, 39-41); `canReorder = capabilities.turns.supportsQueuedMessages === true`; `canPromoteToSteer` = active run status "running" with `activeAttemptId` and a provider turn for that attempt with status "running", and supportsActiveSteering or supportsSteeringByInterruptRestart; `isHeld` = any queued run with `queueHeld === true` (127-163); provider session resolution (66-88); `canForkProjectedAssistantItem` (165-185); `canDetachThreadProviderSession` (187-190). Pending user input is `dismissible` per threadRequests.ts:89. `canCreateProjectInEnvironment` requires phase "connected" (CR/operations/projects.ts:34-38); `resolveAddProjectPath` validates input paths (321-338).
- Local short-circuits: interrupt with nothing to stop returns `{sequence: 0}` without dispatching; updateThreadMetadata with no fields returns `{sequence: 0}`; optimistic lifecycle previews are suppressed while a runtime request is pending or a run is active, until the server accepts (5.4).

---

## 7. Constants

| Constant | Value | Where |
|---|---|---|
| THREAD_SNAPSHOT_IDLE_TTL_MS (resume cache) | 300_000 ms | CR/state/threadRetention.ts:3 |
| live thread atom idle TTL | 0 | threads.ts:957 |
| shell HTTP snapshot timeout | 20_000 ms | shellSnapshotHttp.ts:29 |
| full thread HTTP snapshot timeout | 20_000 ms | threadSnapshotHttp.ts:22 |
| bounded thread HTTP snapshot timeout | 6_000 ms | boundedThreadSnapshotHttp.ts:20 |
| history page timeout | 6_000 ms | threadHistoryHttp.ts:14 |
| subscription retry | 250 ms doubling, cap 30_000 ms | threads.ts:898, shell.ts:408, rpc/client.ts:106 |
| cache writes | first after 500 ms, then at most every 10 s | cachePersistence.ts:12, 16 |
| permission wait | 6_000 ms | commandPermissions.ts:56 |
| socket open timeout | 15 s | rpc/session.ts:45 |
| reconnect backoff | base 1_000 ms, max 300_000 ms | supervisor.ts:35-36 |
| PR link decode batch | 400 links, 1 ms yield | shellPullRequests.ts:24, 30 |
| protocol header | x-t3-orchestration-protocol: "2" | contracts/environment.ts:13-16 |
| cache schema version | 3 | platform/orchestrationCache.ts:12 |
| title seed length | 50 | shared/String.ts:1 |
| mobile outbox max retry delay | 16_000 ms | thread-outbox-model.ts:34 |
| web rollback wait | 120_000 ms | ChatView.logic.ts:1118 |
| server live tool coalescing | 50 ms, 512 | ThreadLiveEventCoalescer.ts:18-19 |
| server assistant paragraph cadence | 400 ms | assistantStreaming.ts:116 |
| server thread replay limits | 128 events, 1 MiB raw, 1 MiB encoded | ThreadStream.ts:15-25 |
| server shell replay limits | gap 1_000, 8 MiB | ws.ts:551, 555 |
| server shell batching | 512 events or 50 ms | ws.ts:1034 |
| server unchanged shell resend | 5_000 ms | ShellStream.ts:227 |
| server history policy | snapshot 10 turns, 75 items, 1 MiB, 77 rows; older pages 20 turns | threadHistoryPaging.ts:13-28 |
| server history cursor max length | 4_096 | threadHistoryPaging.ts:31 |

---

## 8. Rules a native client must reproduce (summary)

1. Shell: on each new connection load HTTP `/api/orchestration/shell` first, apply it as authoritative, then subscribe with `afterSequence` = its sequence (plus `requestCompletionMarker` when advertised). If HTTP fails, subscribe without `afterSequence`. On same-connection foreground wakeups resubscribe from the in-memory cursor without HTTP.
2. Shell snapshots without `resolvedRepositoryIdentityRoots` replace everything (even at a lower sequence) while retaining known repository identities for the same workspace root. Snapshots with that field only patch project identities.
3. Shell deltas: skip `sequence <= snapshotSequence`; upsert in place or append; `thread.updated` with location "archive" and `thread.removed` remove from both lists; no gap detection.
4. Thread: keep `lastSequence`; apply events with `sequence > lastSequence`, advancing past unknown events; a snapshot item resets data and cursor; `synchronized` flips status to live.
5. Thread events replace whole entities by id (exceptions: run.background-work-cancelled field merge, provider-turn tokenUsage carry-over, provider-session.detached removal, thread.visited and thread.marked-unread without updatedAt bump).
6. visibleTurnItems: maintain by ordinal and id with the visibility rules, renumbered positions, and the partial-timeline drop rule plus watermark while older history remains.
7. History: page with the opaque cursor, merge with live precedence, and ignore stale responses whose cursor no longer matches.
8. Commands: lowercase UUID v4 commandIds; reuse a commandId for resends; FIFO per thread; optimistic lifecycle overlays held until the shell snapshotSequence reaches the returned sequence.

---

## 9. UNVERIFIED items and caveats

1. How decode failures surface for unknown shell item kinds or malformed thread events (likely an RpcClientError treated as a transport failure; not confirmed).
2. The 16-item RpcClient buffer (only a test comment, shell-sync.test.ts:163).
3. Whether server turn item ordinals are monotonic in creation order; this matters for the partial-timeline drop rule.
4. Whether row positions stay contiguous after decode-time filtering of unknown turn item types.
5. Server ordering of rows inside shell snapshot arrays.
6. Whether any app UI component throttles rendering of streaming text (none in client-runtime).
7. Internals of `derivePendingBackgroundWork`.
8. Mobile `hasAccess` details in the outbox.
9. Server handling of extra CommandMetadata keys spread into pull request link, unlink and watch payloads.
10. Exact line numbers in apps/server/src/orchestration-v2/WireProjection.ts.
11. The `provider.uploadFeedback` input shape.
12. Practical effect of an enrichment-only snapshot marking a shell session authoritative (code path observation only).
13. Collision risk in the live reducer matching visible rows by `sourceItemId` alone (code observation, untested).
