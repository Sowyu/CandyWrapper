# Orchestration v2 turn lifecycle: wire-level contract research

Source: T3 Code checked out at tag v0.0.46-nightly.20261009.2861 (HEAD 3b6af0bd1), read only. All citations are repo-relative `path:line` (or a path alias from the table below). Anything not confirmed in code is marked UNVERIFIED.

The design docs describe target behavior, not the implementation ("These flows describe target behavior, not current implementation constraints", docs/orchestration-v2/feature-lifecycles.md:3). Where docs and code differ, this report follows the code. Deviations are listed in section 12.

## Path aliases

| Alias | Path |
|---|---|
| CONTRACT | packages/contracts/src/orchestrationV2.ts |
| POLICY | packages/contracts/src/providerPolicy.ts |
| SETTINGS | packages/contracts/src/settings.ts |
| IDS | packages/provider-core/src/server/IdAllocator.ts |
| FAIL | packages/provider-core/src/server/failure.ts |
| PADAPTER | packages/provider-core/src/server/ProviderAdapter.ts |
| NOTIF | packages/provider-core/src/server/notification.ts |
| ORCH | apps/server/src/orchestration-v2/Orchestrator.ts |
| CMDPOL | apps/server/src/orchestration-v2/CommandPolicy.ts |
| OUTBOX | apps/server/src/orchestration-v2/EffectOutbox.ts |
| WORKER | apps/server/src/orchestration-v2/EffectWorker.ts |
| START | apps/server/src/orchestration-v2/ProviderTurnStartService.ts |
| EXEC | apps/server/src/orchestration-v2/RunExecutionService.ts |
| INGEST | apps/server/src/orchestration-v2/ProviderEventIngestor.ts |
| CONTROL | apps/server/src/orchestration-v2/ProviderTurnControlService.ts |
| RRS | apps/server/src/orchestration-v2/RuntimeRequestService.ts |
| CAPTURE | apps/server/src/orchestration-v2/CheckpointCaptureService.ts |
| CKPT | apps/server/src/orchestration-v2/CheckpointService.ts |
| FINAL | apps/server/src/orchestration-v2/RunFinalizationService.ts |
| ROLLBACK | apps/server/src/orchestration-v2/CheckpointRollbackService.ts |
| SETTLE | apps/server/src/orchestration-v2/ThreadSettlementService.ts |
| STREAMF | apps/server/src/orchestration-v2/assistantStreaming.ts |
| LIVE | apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts |
| PSTORE | apps/server/src/orchestration-v2/ProjectionStore.ts |
| SINK | apps/server/src/orchestration-v2/EventSink.ts |
| POS | apps/server/src/orchestration-v2/TurnItemPositionStore.ts |
| WIRE | apps/server/src/orchestration-v2/WireProjection.ts |
| SHELLS | apps/server/src/orchestration-v2/ShellStream.ts |
| TSTREAM | apps/server/src/orchestration-v2/ThreadStream.ts |
| SESS | apps/server/src/orchestration-v2/ProviderSessionManager.ts |
| RECOVER | apps/server/src/orchestration-v2/ProviderRuntimeRecoveryService.ts |
| QORDER | apps/server/src/orchestration-v2/QueuedRunOrder.ts |
| UFE | apps/server/src/orchestration-v2/UserFacingErrors.ts |
| INTAKE | apps/server/src/orchestration-v2/ThreadMessageIntake.ts |
| LAUNCH | apps/server/src/orchestration-v2/ThreadLaunchService.ts |
| WS | apps/server/src/ws.ts |
| CODEX | apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts |
| CLAUDE | apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts |
| COALESCER | apps/server/src/orchestration-v2/Adapters/ProviderTextDeltaCoalescer.ts |
| TIMELINE | packages/shared/src/orchestrationV2Timeline.ts |
| THREADERR | packages/shared/src/orchestrationV2ThreadError.ts |
| CREDUCER | packages/client-runtime/src/state/orchestrationV2Projection.ts |
| CTHREADS | packages/client-runtime/src/state/threads.ts |
| CCMDS | packages/client-runtime/src/operations/commands.ts |
| WEBCHAT | apps/web/src/components/ChatView.tsx |
| WEBLOGIC | apps/web/src/components/ChatView.logic.ts |
| MIG001 | apps/server/src/persistence/Migrations/001_OrchestrationEvents.ts |
| FIX | apps/server/src/orchestration-v2/testkit/fixtures |

Notation: "TX" means one committed write. All events of one TX get consecutive store sequences and are applied atomically. Event lines are written as `event-type {key fields}`. "->" means "then".

---

## 1. Wire mechanics a client must implement

### 1.1 Domain event envelope

Every domain event has: `id, type, threadId, runId?, nodeId?, driver?, providerInstanceId?, rawEventId?, occurredAt, payload` (CONTRACT:1634-1643). Every payload is a complete entity snapshot, never a patch:

- `thread.created` and all `thread.*` mutation events carry the full AppThread (CONTRACT:1646-1676). The mutation types are: thread.archived, thread.unarchived, thread.deleted, thread.settled, thread.unsettled, thread.snoozed, thread.unsnoozed, thread.pinned, thread.auto-settle-set, thread.unpinned, thread.pin-reordered, thread.active-reordered, thread.visited, thread.marked-unread, thread.metadata-updated, thread.pull-request-synced, thread.runtime-mode-updated, thread.interaction-mode-updated, thread.model-selection-updated, thread.provider-switched (CONTRACT:1653-1674).
- `run.created`, `run.updated`: full Run (CONTRACT:1677-1686). `run.background-work-cancelled`: `{runId, restartCancelledBackgroundWork}` (CONTRACT:1687-1691, 511-514).
- `run-attempt.created`, `run-attempt.updated`: full RunAttempt (CONTRACT:1692-1701).
- `node.updated` (ExecutionNode), `subagent.updated`, `provider-session.attached` / `provider-session.updated` (ProviderSession), `provider-session.detached` (`{providerSessionId, detachedAt, reason?}`), `provider-thread.updated`, `provider-turn.updated`, `runtime-request.updated`, `message.updated`, `turn-item.updated`, `plan.updated`, `checkpoint-scope.created`, `checkpoint.captured`, `checkpoint.rollback-requested` (`{scopeId, checkpointId, requestedAt}`), `context-handoff.updated`, `context-transfer.created`, `context-transfer.updated` (CONTRACT:1702-1781).

`turn.terminal` is an adapter-internal event (PADAPTER:131-153). It is never stored and never reaches clients. Its effects arrive as `provider-turn.updated`, error items, and run/attempt/node updates.

### 1.2 Thread detail stream

- RPC `orchestration.subscribeThread` (CONTRACT:3152) with `{threadId, afterSequence?, requestCompletionMarker?, acceptBoundedSnapshot?, acceptCompactTurnItems?}` (CONTRACT:3238-3257).
- Stream items (CONTRACT:3366-3392): `{kind:"snapshot", snapshotSequence, projection, historyCursor?, hasMoreHistory?, latestLocalTurnOrdinal?, payloadBudgetExceeded?, turnItemsOmitLocalVisible?}`, `{kind:"synchronized"}` (only when requested), `{kind:"event", sequence, event}`. A decode-only `unknown-event` arm lets old clients skip unknown event types and unknown turn item types while still advancing their cursor (CONTRACT:3327-3364).
- Server behavior: snapshot, then the marker, then live events after `snapshotSequence` (WS:826-860). With `afterSequence`, the server replays the gap if it is at most 128 events and at most 1 MiB; otherwise it sends a fresh snapshot (WS:869-937; TSTREAM:15-25, 106-124).
- Only events whose `event.threadId` equals the subscribed thread are streamed (SINK:716-725; WS:772-777). Subagent child threads are separate threads with their own streams.

### 1.3 Sequences and cursors

- `sequence` is a global SQLite `INTEGER PRIMARY KEY AUTOINCREMENT` shared by all threads and projects (MIG001:9). A single thread stream therefore sees increasing but gapped sequences.
- `snapshotSequence` is `MAX(sequence)` over that thread's v2 events (PSTORE:5089-5095).
- Client rule used by the official client: ignore any item with `sequence <= lastApplied`; unknown event types still move the cursor (CTHREADS:444-469).
- Writers publish in commit order through a publish lane, so live delivery cannot reorder commits (SINK:232-262).

### 1.4 Reducer semantics

The server projection and the official client both upsert entities by `id` (PSTORE:679-845; CREDUCER:153-286). Special cases:

- `provider-thread.updated` also sets `thread.activeProviderThreadId` on the server projection when `payload.appThreadId == thread.id` and the row is not a queued placeholder (placeholder = status not_loaded, firstRunOrdinal null, nativeThreadRef null, providerSessionId null) (PSTORE:783-795, 670-677). The client reducer only upserts the provider thread row (CREDUCER:227-228).
- `provider-session.detached` removes the session row (PSTORE:776-782; CREDUCER:220-226).
- `provider-turn.updated` keeps the previous `tokenUsage` when the new payload omits it (PSTORE:603-614; CREDUCER:229-244).
- `run.created`/`run.updated`: the server keeps `delegatedCompletion` and `restartCancelledBackgroundWork` when a new run payload omits them (PSTORE:617-632, 724-735). Several server writers deliberately omit `delegatedCompletion` (EXEC:644-653; CAPTURE:131-135; ORCH:8368). The official client reducer replaces the run whole (CREDUCER:188-192). A native client that wants to match server snapshots should preserve those two fields when absent.
- `checkpoint.rollback-requested` only bumps `updatedAt` (PSTORE:831-832).
- `thread.visited` and `thread.marked-unread` do not bump `updatedAt` (PSTORE:716-723).
- Visible timeline rules (TIMELINE:42-112): hide items whose run is `rolled_back`; hide a `user_message` with `inputIntent:"queued_turn"` whose run is `cancelled`; hide a `run_interrupt_result` on a superseded attempt's root node unless the run also has a `run_interrupt_request` item. The client inserts visible rows ordered by `ordinal`, then `id` (CREDUCER:108-150).

### 1.5 Turn item ordinals are server-assigned

Each `turn-item.updated` is normalized at write time: the first time an item id is written, it gets `max(existing ordinal in band) + 1` where the band is `[runOrdinal * 1,000,000, runOrdinal * 1,000,000 + 999,999]` (band `[0, 999,999]` for items without a run). The allocation is `ON CONFLICT DO NOTHING`, so an item keeps its first position forever (POS:42-104; SINK:309-330). Adapter ordinal hints (`providerTurnOrdinal * 100 + k`, `run.ordinal * 100 + 98/99`, `run.ordinal * 100`) are overwritten. Test evidence: all ordinals of a run are above 1,000,000 and strictly increasing in write order (apps/server/src/orchestration-v2/FoundationPersistence.test.ts:3341-3347).

### 1.6 Wire projection of payloads

Applied to stream events and snapshots (WS:782, 807, 854; WIRE:210-241):

- `command_execution`: `output` removed; `outputOmitted: true` when output had text; `outputIndicatesFailure: true` when exitCode is non-zero, the provider flagged it, or the output looks like a failure (WIRE:82-96).
- `file_change`: `diffStr`, `oldStr`, `newStr` removed, except a failed item keeps a truncated `diffStr` (WIRE:97-105).
- `dynamic_tool`: large input summarized, output compacted, `outputOmitted` set (WIRE:113-122).
- `subagent`: prompt/progress/result truncated at 32 KiB (WIRE:14, 106-112).
- `handoff`: `summary` removed (WIRE:78-80). `context-handoff.updated`: `history` and `delivery` removed and `summaryText: ""` (WIRE:203-208).
- Full item: RPC `orchestration.getTurnItem {threadId, itemId, revision?}` -> `{item}` (CONTRACT:3458-3469; WS:1869-1879), bounded at 256 KiB (WIRE:16, 173-201).

### 1.7 Live coalescing of running tool updates

`turn-item.updated` events with `status:"running"` and type `command_execution | file_change | file_search | web_search | dynamic_tool` are buffered for 50 ms (max 512). Within a window only the newest update per item id survives. Any other event flushes the buffer immediately, and terminal updates are never dropped (LIVE:18-37, 48-86, 148-191; WS:784). A client can therefore miss intermediate running states and must tolerate sequence gaps inside one thread.

### 1.8 Shell stream

- RPC `orchestration.subscribeShell` (CONTRACT:3151, 3223-3235). Items: `snapshot`, `synchronized`, `project.updated`, `project.removed`, `thread.updated {sequence, location, thread: full ThreadShell}`, `thread.removed` (CONTRACT:1945-1981).
- Every committed thread event triggers a re-read of that thread's shell. Events are grouped in 50 ms windows (max 512) and coalesced per thread (WS:1032-1038; SHELLS:86-100). A shell identical to the last one sent (ignoring `updatedAt`) is suppressed unless 5 s passed (SHELLS:226-273). Archived threads produce `thread.removed` on the active shell (SHELLS:292-319).

Shell field derivation (in-memory PSTORE:1372-1519; SQL PSTORE:5111-5301, 5586-5700):

| Field | Rule | Citation |
|---|---|---|
| status | status of the "presented" run: newest run by ordinal that is not a held queued run; `"idle"` if none. A usage-limited failed run is presented instead when newer runs are queued or cancelled before start. Consequence: while a run runs with an unheld queued follow-up, `status` is `"queued"`. | THREADERR:96-124; PSTORE:1382-1387, 1469, 5263-5274, 5614-5640; PSTORE test apps/server/src/orchestration-v2/ProjectionStore.test.ts:2251-2302 |
| latestRunId / latestRunRequestedAt / latestRunStartedAt / latestRunCompletedAt | from the presented run | PSTORE:1461-1464 |
| activeRunId | newest run in preparing, starting, running | PSTORE:1388-1391, 1555-1557, 5130-5137 |
| activityRunStatus / activityRunStartedAt | newest run in preparing, starting, running, waiting; start = workStartedAt ?? startedAt ?? requestedAt | PSTORE:1392-1395, 1466-1468, 1561-1567; CONTRACT:591-595 |
| pendingRuntimeRequest | newest pending runtime request `{id, kind, createdAt}`, else a waiting secret_request of an active run (kind user_input) | PSTORE:1355-1370, 1397-1417, 1474-1481 |
| lastError / lastErrorClass / usageLimitResetAt | root error item of the presented run when it failed; a different provider session lastError wins and clears the class | THREADERR:9-49; PSTORE:1470-1473 |
| latestUserMessageAt / latestUserAuthoredMessageAt | newest user-role message / newest with createdBy user | PSTORE:1418-1424, 1485-1487 |
| hasActionableProposedPlan | any `proposed_plan` plan with status active | PSTORE:1488-1490 |
| latestVisibleMessage | always null | PSTORE:1482-1484 |
| itemCount | excludes items of rolled_back runs | PSTORE:5244-5255 |

### 1.9 Command dispatch, receipts and errors

- RPC `orchestration.dispatchCommand` (CONTRACT:3139) with an `OrchestrationV2Command` (CONTRACT:2611-3054). Result `{sequence}`: the last committed sequence of that command (CONTRACT:3212-3214; ORCH:10621-10624; WS:1853).
- The server forces `createdBy: "user"` and `creationSource` (from the command, else `"web"`) for client dispatches (WS:1842-1848). Attachments are claimed in `ThreadMessageIntake` (INTAKE:53-165).
- Each command runs under its thread lock (ORCH:10627-10628) and commits its events plus effects in one transaction.
- Same `commandId` again: the stored receipt is replayed; a previously rejected id fails with `OrchestratorCommandPreviouslyRejectedError` (ORCH:10430-10481).
- A command that yields no events is rejected ("Command produced no domain events."), except `thread.background-work.settle` and `thread.stop` (ORCH:10496-10512).
- Rejections reach clients as `OrchestrationV2DispatchCommandError {commandId, commandType, message, detail?}` where `message` is the innermost user-facing cause or "Failed to dispatch orchestration V2 command" (WS:1854-1863; UFE:104-110; CONTRACT:3395-3404). Capability rejections are rewritten, for example "<Provider> cannot redirect an active run. Stop it first, then send the message." and "<Provider> cannot queue messages behind an active run." (UFE:15-31).
- Events written by background services carry no client command id (ingested provider events) or an internal one such as `command:effect:checkpoint.capture:<runId>` (CAPTURE:136-138). The thread stream does not expose command ids (CONTRACT:3385-3389).
- Effects (server-internal, not on the wire) run one at a time per thread in enqueue order (OUTBOX:313-316), up to 5 attempts with backoff `min(30 s, 100 ms * 2^(n-1))` (WORKER:551, 727-742).

---

## 2. Entity IDs and relationships

### 2.1 ID formats

`joinId(prefix, ...parts)` joins with ":" after `encodeURIComponent` on each part; random ids append a UUID v4 part (IDS:192-195, 235-253). The official web client mints plain UUIDs for thread, message and command ids (apps/web/src/lib/utils.ts:36-50; CCMDS:261-267), so those stay unchanged, while server ids nested inside other ids get percent-encoded (":" -> "%3A", "%" -> "%25"). Below, T is a UUID thread id, N a run ordinal, R the RunId string.

| Entity | Format | Citation |
|---|---|---|
| RunId | `run:thread:T:ordinal:N`, N = runs.length + 1 | IDS:404; ORCH:370-372 |
| RunAttemptId | `run-attempt:run:<enc R>:attempt:<k>` (example `run-attempt:run:run%3Athread%3AT%3Aordinal%3A1:attempt:1`) | IDS:405-408 |
| Root NodeId, attempt 1 | `node:run:<enc R>:root` | IDS:409; ORCH:5273 |
| Root NodeId, steering restart attempt k | `node:run:<enc R>:attempt:<k>:root` | IDS:410-411; ORCH:4064-4067 |
| User message turn item | `turn-item:message:<messageId>` | IDS:412 |
| Run signal turn item | `turn-item:run:<enc R>:signal:<signal>`; signals seen: `interrupt-request`, `interrupt-result`, `context-handoff:<id>`, `provider-session-open-failure`, `provider-thread-load-failure`, `empty-compaction`, `provider-sign-out` | IDS:413-414; ORCH:8736-8739; EXEC:1481-1494; START:315, 433, 588, 605 |
| Placeholder ProviderThreadId | `provider-thread:provider:<driver>:native-thread:pending%3A<enc R>` | IDS:216-233, 415; ORCH:5221-5226 |
| ProviderThreadId minted from a native id | `provider-thread:provider:<driver>:native-thread:<native id>` (Claude thread-start rollback does this) | IDS:216-233; CLAUDE:1111-1141, 8012-8035 |
| ProviderSessionId, shared (multi-thread sessions, Codex) | `provider-session:provider-instance:<instance>:shared` | IDS:390-393; ORCH:859-877; CODEX:252 |
| ProviderSessionId, per thread (Claude) | `provider-session:provider-instance:<instance>:thread:T:<uuid>` | IDS:314-320; CLAUDE:184 |
| ProviderTurnId Codex | `provider-turn:provider:codex:native-turn:<codex turn id>` | IDS:416-419; CODEX:1973-1976 |
| ProviderTurnId Claude | `provider-turn:provider:claudeAgent:native-turn:<enc "turn:" + attemptId>` | CLAUDE:7465, 7483-7486 |
| Item NodeId / MessageId / TurnItemId | `node:provider:<driver>:native-item:<enc itemId>`, `message:provider:...`, `turn-item:provider:...` | IDS:420-429 |
| RuntimeRequestId | `runtime-request:provider:<driver>:provider-turn:<enc providerTurnId>:native-request:<enc nativeRequestId>:<uuid>` | IDS:321-334 |
| Approval NodeId | `node:runtime-request:<enc requestId>` | IDS:430 |
| Approval turn item (and Claude user-input item) | `turn-item:runtime-request:<enc requestId>` | IDS:431-432; CLAUDE:4844 |
| CheckpointScopeId (one root scope per thread) | `checkpoint-scope:thread:T:name:root` | IDS:335-340; CKPT:27, 187-215 |
| CheckpointId | `checkpoint:scope:<enc scopeId>:name:<ordinalWithinScope>` | IDS:341-346; CKPT:174-185 |
| Checkpoint ref | `refs/t3/orchestration-v2/checkpoints/<base64url(first 32 hex of sha256(scopeId))>/ordinal/<n>` | CKPT:26, 161-172 |
| Checkpoint turn item | `turn-item:provider:<driver>:native-item:checkpoint%3A<enc checkpointId>` | CAPTURE:262-266 |
| Provider failure / retry item | `turn-item:provider:<driver>:native-item:terminal-failure%3A<enc providerTurnId>` | FAIL:189-192, 240-243 |
| PlanId | `plan:thread:T:provider:<driver>:run:<enc R>:<uuid>` | IDS:375-387 |
| EventId | command events `event:thread:T:command:<commandId>:<uuid>`; ingested `event:thread:T:provider-session:<enc>:<uuid>`; system `event:thread:T:<uuid>` | IDS:266-278; ORCH:893-908; INGEST:282-285 |
| Async question answer message | `async-answer:<requestId>` | ORCH:7261 |

### 2.2 Relationships

- `Run.rootNodeId` -> ExecutionNode `kind:"root_turn", countsForRun:true, parentNodeId:null, rootNodeId:self` (ORCH:5338-5354).
- `Run.activeAttemptId` -> RunAttempt whose `rootNodeId` is that attempt's root node. A steering restart creates attempt k with a new root node and switches the run's `rootNodeId` and `activeAttemptId` (ORCH:4280-4320).
- Root ProviderTurn: `runAttemptId = attempt.id`, `nodeId = run.rootNodeId`, `providerThreadId` (CODEX:2009-2028; CLAUDE:3805-3823). Use `latestProviderTurnForAttempt` because a Codex goal run can hold several provider turns in one attempt (CONTRACT:1006-1023). Subagent turns have `runAttemptId: null` (CODEX:2618, 5781-5782).
- `RunAttempt.providerTurnId` and the root node's `providerTurnId` are created null (ORCH:4989, 5005, 5332, 5348) and no writer that I read sets them (START:848-860; EXEC:582-586, 654-659). UNVERIFIED as a universal statement.
- Child nodes (assistant_message, reasoning, tool_call, plan, todo_list, user_input_request) hang under the root (or item parent) with `providerTurnId` set (CODEX:3195-3211, 3483-3499; CLAUDE:3860-3876). Approval nodes have `parentNodeId` = the tool item's node and `runtimeRequestId` (CODEX:4016-4054; CLAUDE:4805-4824).
- RuntimeRequest `nodeId` -> approval or user-input node; `providerTurnId` -> provider turn.
- TurnItem carries `runId, nodeId, providerThreadId, providerTurnId, nativeItemRef, parentItemId` (CONTRACT:1316-1335). Assistant items carry `messageId` -> ConversationMessage on the assistant node (CODEX:3212-3245).
- Checkpoint `scopeId` -> the single root scope row, upserted (runId, nodeId, cwd overwritten) on every run (ORCH:5274-5298, 5479-5489; PSTORE:2450-2492). `Run.checkpointId` set at capture.
- `Run.providerThreadId` -> ProviderThread -> `providerSessionId` -> ProviderSession.

---

## 3. Status vocabularies and transitions

| Entity | Values | Citation |
|---|---|---|
| Run | preparing, queued, starting, running, waiting, completed, interrupted, failed, cancelled, rolled_back | CONTRACT:453-464 |
| RunAttempt | pending, running, completed, interrupted, failed, cancelled, superseded; reason initial, steering_restart, retry, provider_recovery | CONTRACT:597-619 |
| ExecutionNode | idle, pending, running, waiting, completed, interrupted, failed, cancelled, rolled_back | CONTRACT:641-651 |
| ProviderTurn | pending, running, completed, interrupted, failed, cancelled | CONTRACT:991-998 |
| ProviderThread | not_loaded, idle, active, archived, closed, error | CONTRACT:880 |
| ProviderSession | starting, ready, running, waiting, stopped, error | CONTRACT:730 |
| RuntimeRequest | pending, resolved, expired, cancelled; responseCapability live, message, not_resumable | CONTRACT:1034-1039 |
| TurnItem | idle, pending, running, waiting, completed, failed, cancelled, interrupted | CONTRACT:1238-1247 |
| Checkpoint | ready, missing, error, stale | CONTRACT:1212 |
| Plan | draft, active, completed, superseded | CONTRACT:1175 |
| Shell status | "idle" or any run status | CONTRACT:1813-1816 |

Run transitions found in code:

- `starting` (created on an idle thread, ORCH:5309) -> `running` (START:843-847) -> `waiting` (provider turn completed, EXEC:642-653) -> `completed` (checkpoint capture, CAPTURE:211-216).
- `preparing` (launch with `defer_start`, ORCH:5309; LAUNCH:836) -> `starting` (prepared-run.release, ORCH:7905-7913) or `failed` (prepared-run.fail, ORCH:8012-8020); `failed` -> `preparing` (prepared-run.retry, ORCH:8100-8104).
- `queued` (ORCH:4959) -> `starting` (ORCH:1607-1618) or `cancelled` (ORCH:7607-7620, 7404-7417, 3260-3269, 1115-1128) or `failed` (failed queued start, ORCH:1254-1262).
- `running` -> `starting` on steering restart, same RunId (ORCH:4280-4290).
- `running` -> `interrupted` / `failed` / `cancelled` from the provider terminal (EXEC:642-653) or local Stop settlement (ORCH:8368-8377).
- `preparing`/`starting` -> `interrupted` when interrupted before the provider turn exists (ORCH:8815-8934).
- `starting` -> `failed` (session open or thread load failure, START:556-610) or `completed` (/logout success, START:378-463).
- `completed`, `interrupted`, `failed`, `cancelled` -> `rolled_back` (ROLLBACK:205-212, 324-336).
- any nonterminal -> `cancelled` on server restart recovery (RECOVER:319-328). `waiting` runs with a pending capture effect are left alone (RECOVER:196-217).
- A run in `waiting` never goes back to running. No code sets a run to `waiting` because of a pending approval or question: the only writer of run status `waiting` is EXEC:642-653.

---

## 4. Scenario A: normal turn on an idle thread

### A.1 Client command

```json
{ "type": "message.dispatch", "commandId": "<uuid>", "threadId": "T", "messageId": "<uuid>",
  "text": "...", "attachments": [], "createdBy": "user", "creationSource": "web",
  "dispatchMode": { "type": "start_immediately" } }
```

Optional fields: `modelSelection`, `titleSeed`, `context`, `sourcePlanRef`, `deliveryIntent: "auto" | "steer" | "restart"` (CONTRACT:2837-2876). The official client sends `deliveryIntent: "auto"` with `start_immediately` when the server advertises `serverResolvedCommandContext` (CCMDS:712-772); the server resolves it under the thread lock: no active run -> `start_immediately` (CMDPOL:120-134).

### A.2 TX1, the command transaction (ORCH:4461-5527)

1. Only if `thread.settledOverride != null`: `thread.unsettled {settledOverride null, settledAt null, unsettledAt}` (ORCH:4562-4585).
2. Only if snoozed: `thread.unsnoozed {snoozedUntil null, snoozedAt null}` (ORCH:4586-4605).
3. Only for the first message with `titleSeed` (or a user message after maintenance-only history): `thread.metadata-updated {title: titleSeed, titleRegeneration {requestId: commandId, startedAt}}` plus effect `thread-title.generate` (ORCH:4606-4642).
4. Only if `command.modelSelection` differs from the thread: `thread.model-selection-updated` (same instance) or `thread.provider-switched` (ORCH:5142-5164). A switch with an existing provider thread takes the handoff path (ORCH:5530-6466) instead of steps 5-13.
5. `provider-thread.updated`. First run: placeholder row `{status not_loaded, providerSessionId, firstRunOrdinal N, lastRunOrdinal N, nativeThreadRef null}`. Later runs: existing row with `lastRunOrdinal N` (ORCH:5243-5271, 5433-5440). On the server this sets `thread.activeProviderThreadId` (PSTORE:783-795).
6. Only for v1-imported history: `context-handoff.updated` (ORCH:5441-5450).
7. `run.created {id R, ordinal N, status "starting", queuePosition null, rootNodeId, activeAttemptId, providerThreadId, providerInstanceId, modelSelection, userMessageId, requestedAt now, startedAt null, completedAt null, checkpointId null, contextHandoffId}` (ORCH:5299-5324, 5451-5459).
8. Only with `sourcePlanRef`: `plan.updated {source proposed plan, status "completed"}` (ORCH:4797-4810, 5460).
9. `run-attempt.created {attemptOrdinal 1, reason "initial", status "pending", providerTurnId null}` (ORCH:5325-5337, 5461-5469).
10. `node.updated {root, kind root_turn, status "pending", countsForRun true, checkpointScopeId}` (ORCH:5338-5354, 5470-5478).
11. `checkpoint-scope.created {id checkpoint-scope:thread:T:name:root, kind root_run, runId R, nodeId root, parentScopeId null, ordinalWithinParent 0, advancesAppRunCount true, cwd}` (ORCH:5274-5298, 5479-5489; CKPT:187-215). Skipped for `defer_start`.
12. `message.updated {role "user", text, attachments, context?, streaming false, runId R, nodeId root, createdBy, creationSource}` (ORCH:5355-5377, 5490-5498).
13. `turn-item.updated {type user_message, id turn-item:message:<messageId>, status "completed", inputIntent "turn_start", providerTurnId null, text, attachments}`; ordinal becomes N*1,000,000+1 (ORCH:5378-5407, 5499-5507; POS:58-72). Notifications and delegated completions are projected as `type: notification` instead (NOTIF:212-235).
14. `defer_start` only: `turn-item.updated {type command_execution, title "Preparing workspace", input "Preparing workspace", status running}` (ORCH:5408-5431, 5508-5518).

Effect enqueued: `provider-turn.start {runId}` (ORCH:5519-5527), not for `defer_start`. RPC returns `{sequence}` of the last event.

Shell after TX1: status "starting", latestRunId R, activeRunId R, activityRunStatus "starting", activityRunStartedAt = requestedAt, latestUserMessageAt and latestUserAuthoredMessageAt set.

### A.3 Provider start (effect worker, START:223-1281)

The effect is idempotent: it returns when the run is no longer "starting" (START:234-237).

15. When the thread newly attaches to the provider session: `provider-session.attached {full ProviderSession incl. capabilities}` (SESS:1327-1338). Later adapter-reported session status changes are written as `provider-session.updated` to every attached thread (SESS:619-646, 1853-1877).
16. The provider thread is loaded: `ensureThread` for a new one (adapter adopts the existing row id, START:651-665), else `resumeThread`. A failed resume falls back to a fresh native thread plus `context-handoff.updated` and `context-transfer.updated {status resolved_portable}` (START:666-780).
17. TX2, committed only if the run is still "starting" with the same attempt (START:940-949), in order (START:826-939):
    - `provider-session.updated {session}`
    - `provider-thread.updated {status "active", nativeThreadRef, lastRunOrdinal N, contextUsage}`
    - native fork only: `context-transfer.updated {status consumed, resolution native_fork}`
    - `run.updated {status "running", startedAt}`
    - `run-attempt.updated {status "running", startedAt, nativeThreadId}`
    - `node.updated {root, status "running", startedAt}`
18. Handoff bookkeeping when context is injected: `context-handoff.updated` (START:1152-1170).
19. RunExecutionService captures a git baseline ref for ordinal N-1 (no event), subscribes to adapter events, calls `adapter.startTurn` (EXEC:845-859, 1348-1414).

Shell: status "running", latestRunStartedAt set.

Start failure variants are in F.3.

### A.4 Provider turn running

Adapter events are ingested one adapter event per write (INGEST:552-593). Root provider-thread updates before the terminal are gated on the run still running (EXEC:1200-1239).

20. `provider-turn.updated {id, providerThreadId, nodeId = root node, runAttemptId = attempt, nativeTurnRef, ordinal, status "running", startedAt}`. Ordinal = max provider turn ordinal on that provider thread + 1 (START:1248-1254). Codex emits it after `turn/start` returns (CODEX:6204-6210, 1962-2031) with a strong native turn ref. Claude emits it at start (CLAUDE:7461-7486, 7568) with a weak ref whose native id is `turn:<attemptId>` or the latest assistant uuid (CLAUDE:3805-3823).
21. Repeated `provider-turn.updated {status "running", tokenUsage {usedTokens, maxTokens?, inputTokens?, cachedInputTokens?, outputTokens?, reasoningOutputTokens?, updatedAt}}` (CODEX:4320-4359; CLAUDE:6099-6127; CONTRACT:971-980).

### A.5 Assistant text streaming

How the text arrives: always as full-replacement snapshots of the accumulated text, never deltas.

Codex (CODEX:4197-4209, 3340-3405, 3174-3247):

22. Deltas accumulate in a coalescer flushed every 50 ms (CODEX:223; COALESCER:99-130). Each flush emits `node.updated {kind assistant_message, status running}` and `turn-item.updated {type assistant_message, id turn-item:provider:codex:native-item:<itemId>, messageId message:provider:codex:native-item:<itemId>, text = whole text so far, streaming true, status running}`.
23. On `item/completed` (or turn end flush): `node.updated {completed}`, `message.updated {role assistant, text full, streaming false, nodeId assistant node}`, `turn-item.updated {status completed, streaming false, text full}` (CODEX:4995-5038, 3375-3394). Code comment: "Clients render streaming text from the turn item, so the message only carries the final text" (CODEX:3380-3382). Commentary-phase and final-answer agent messages are both emitted; duplicate final answers are suppressed (CODEX:3348-3369, 4644-4654).

Server-side streaming filter per run (STREAMF:92-128; EXEC:1187-1199). Mode = project setting `responseStreamingMode`, `"turn" | "paragraph"`, default `"paragraph"` (SETTINGS:993-999, 1133-1135):

- Running `assistant_message` nodes are always dropped before persistence (STREAMF:95-100).
- `paragraph`: a streaming update of an assistant message or reasoning item passes only when at least 400 ms passed since the last passed update for that item and the prefix up to the last safe markdown boundary grew (blank line, closed fence, list item start, heading rules, STREAMF:35-89). The passed event carries only that prefix.
- `turn`: no streaming update passes.
- Final updates (`streaming: false`) always pass unchanged.
- Tests: apps/server/src/orchestration-v2/assistantStreaming.test.ts:54-105.

Claude: assistant text is not streamed. Each completed text block yields `node.updated {assistant_message, completed}` + `message.updated {streaming false}` + `turn-item.updated {status completed, streaming false}` (CLAUDE:5238-5279, 6558-6565, 2572-2657). Thinking streams as `turn-item.updated {type reasoning, title "Thinking", streaming true/false, status running/completed}` (CLAUDE:4886-4927, 5865-5910). A fallback assistant message is emitted at turn end when no text block was emitted (CLAUDE:5021-5059).

Codex reasoning streams per summary/content part as `turn-item.updated {type reasoning}` with node kind `reasoning` (CODEX:3251-3338).

Fixture: the simple scenario ends with node kinds `[root_turn, assistant_message]` and item types `[user_message, assistant_message]` for both providers (FIX/simple/codex_output.ts:22-32; FIX/simple/claude_output.ts:22-32).

### A.6 Tool, command and file change items

Codex:

24. Command `item/started` -> `node.updated {kind tool_call, status running}` + `turn-item.updated {type command_execution, input: command, status running}` (CODEX:4657-4683, 3462-3525).
25. Command `item/completed` -> `node.updated {completed | failed | cancelled}` + `turn-item.updated {status completed | failed | cancelled, output: aggregatedOutput, exitCode}` (CODEX:4770-4833). Status map: inProgress -> running, completed -> completed, failed -> failed, declined -> cancelled (CODEX:404-427). Codex output is not streamed (no outputDelta handler; only aggregatedOutput). On the wire output is replaced by `outputOmitted` and `outputIndicatesFailure` (WIRE:82-96).
26. File change: only at `item/completed`: node tool_call + `turn-item.updated {type file_change, fileName: first change path, diffStr: first change diff, status}` (CODEX:4859-4875, 3527-3589). Only the first change of the item is represented.
27. MCP and dynamic tools: `dynamic_tool` at start and completion (CODEX:4685-4701, 4835-4857). Web search: `web_search` (CODEX:4703-4722, 4877-4894). Context compaction: `compaction` running "Compacting context" -> completed "Context compacted" (CODEX:4560-4597).

Claude (CLAUDE:4685-4790, 3825-4004, 1655-1697):

- `tool_use` -> `node.updated {tool_call, running}` + turn item by classification: Bash -> `command_execution {input}`; Edit, Write, MultiEdit, NotebookEdit -> `file_change {fileName, diffStr = tool output text}`; WebSearch, WebFetch -> `web_search`; Read, Grep, Glob, LS, Task, TodoWrite and unknown tools -> `dynamic_tool {toolName, input, output}`.
- `tool_result` -> same ids with completed/failed and output.
- Open tool calls at turn end close as `failed` when the turn completed, else with the terminal status (CLAUDE:4930-4960, 5004-5016).

Running updates of these types are subject to the 50 ms live coalescing (section 1.7).

### A.7 Approval request and response

Approvals appear only when the provider asks under the thread's runtime mode (default runtime mode "full-access", POLICY:25-32). Claude asks only when its permission callback is installed for the runtime policy (CLAUDE:1602-1606). The mapping from each runtime mode to provider approval policies was not read (UNVERIFIED).

28. Codex JSON-RPC server requests `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, `item/permissions/requestApproval` (CODEX:5042-5225) or Claude `canUseTool` (CLAUDE:7065-7116, after the tool item started at 6944-6951) emit three events, each its own write:
    - `node.updated {id node:runtime-request:<enc requestId>, kind approval_request, status waiting, parentNodeId = the tool item's node, runtimeRequestId, providerTurnId}`
    - `runtime-request.updated {kind command | file-read | file-change | permission | mcp-elicitation, status pending, responseCapability {type live, providerSessionId}, nativeRequestRef {strength strong}, createdAt, resolvedAt null}`
    - `turn-item.updated {id turn-item:runtime-request:<enc requestId>, type approval_request, status waiting, requestId, requestKind, prompt?, appName?, options?}`
    (CODEX:4002-4098, 5073-5088; CLAUDE:4774-4872). ProviderRequestKind values: POLICY:38-44. The ordering of the Codex command `item/started` relative to the approval request depends on Codex (UNVERIFIED); for Claude the tool item is always started first.
29. Run, attempt and root node stay "running". Shell `pendingRuntimeRequest {id, kind, createdAt}`.
30. Client: `runtime-request.respond {requestId, decision}` with decision accept, acceptForSession, acceptAlways, decline, cancel (CONTRACT:2959-2967; POLICY:50-56; CCMDS:834-844). Validation: request exists, is pending, is not not_resumable, session row exists (ORCH:7072-7105).
31. TX (ORCH:7108-7192):
    - `runtime-request.updated {status "resolved", resolvedAt, decision}`
    - `node.updated {approval node, status "completed" (or "cancelled" for decline/cancel), completedAt}` (ORCH:7117-7120)
    - `turn-item.updated {approval_request, status "completed" or "cancelled", completedAt}`
    Effect `runtime-request.respond` (ORCH:7272-7287).
32. The effect checks the request is resolved and live and the session is live, then calls the adapter (RRS:77-135). Codex replies `acceptAlways` as `acceptForSession` (CODEX:5099-5101, 5159-5161); Claude converts to an SDK permission result (CLAUDE:7131-7139). The adapters emit nothing more for the request.

The projection shows "resolved" before the provider receives the answer. If the effect exhausts its retries no compensating event was found (UNVERIFIED that any exists).

### A.8 Provider turn completes

33. Codex `turn/completed` -> `finalizeCodexTurn` (CODEX:5967-5996, 5707-5965): flush pending text and reasoning (final `message.updated` and turn items), `provider-turn.updated {status completed, completedAt, turnTokenUsage}`. Claude result -> `finalizeActiveTurn` (CLAUDE:4980-5236): close open tools, fallback text, `provider-turn.updated {completed, turnTokenUsage}`, `provider-thread.updated {status active, pendingBackgroundTasks, lastRunOrdinal}`, then the internal terminal.
34. On any terminal provider turn status the ingestor cancels pending native `user_input` requests of that provider turn (not message-mode ones): `runtime-request.updated {cancelled}`, `node.updated {cancelled}`, `turn-item.updated {cancelled}` (INGEST:303-346, 416-433, 509-512; test apps/server/src/orchestration-v2/ProviderEventIngestor.test.ts:737-923).
35. TX, committed only if the run is still running with this attempt (EXEC:563-801, 979-989):
    - `run-attempt.updated {status "completed", completedAt}`
    - `run.updated {status "waiting", completedAt null}` (EXEC:642-653)
    - `node.updated {root, status "waiting", completedAt null, checkpointScopeId}`
    - `provider-thread.updated {status "idle"}` ("error" when the terminal says threadDisposition broken, EXEC:324-328, 660-664)
    - effect `checkpoint.capture {runId, scopeId}` (EXEC:674-691)
    Test: a completed terminal persists `run:waiting` (apps/server/src/orchestration-v2/RunExecutionService.test.ts:3379-3393).

Shell: status "waiting", activeRunId null, activityRunStatus "waiting". Ingestion may continue after this for late background items (EXEC:1131-1186).

### A.9 Checkpoint capture and run completion

Effect -> RunFinalizationService (FINAL:56-84) -> CheckpointCaptureService (CAPTURE:63-239). One TX with commandId `command:effect:checkpoint.capture:<runId>` (CAPTURE:136-238):

36. Baselines, only when missing: a thread-start checkpoint at ordinal 0 and/or a baseline at ordinal N-1 (CAPTURE:107-122). For run 1 this is `checkpoint.captured {id ...:name:0, runId null, appRunOrdinal null, ordinalWithinScope 0, files [], status ready (missing outside git), capturedAt = scope.createdAt}` (CKPT:303-355).
37. `checkpoint.captured {id checkpoint:scope:<enc scopeId>:name:N, runId R, nodeId root, parentCheckpointId ...:name:N-1, ordinalWithinScope N, appRunOrdinal N, ref, status ready | missing | error, files [{path, kind "modified", additions, deletions}], capturedAt}`. Files come from git numstat between refs N-1 and N; `kind` is always "modified"; status is missing when the cwd is not a git repo and error when the capture failed (CKPT:357-494).
38. `turn-item.updated {type checkpoint, checkpointId, scopeId, files, status completed}` (CAPTURE:183-200, 254-285).
39. `run.updated {status "completed", completedAt = capturedAt, checkpointId}` (CAPTURE:201-217).
40. `node.updated {root, status "completed", completedAt}` (CAPTURE:218-236).

Shell: status "completed", latestRunCompletedAt set, activityRunStatus null. Full diffs: `orchestration.getTurnDiff` / `orchestration.getFullThreadDiff` (CONTRACT:3140-3141; packages/contracts/src/checkpointDiff.ts:29-49). Workspace and VCS refresh follow without domain events (FINAL:66-83, 97-119).

### A.10 Post-terminal reactions

- Every terminal `run.updated` (completed, interrupted, failed, cancelled, rolled_back) not written by restart reconciliation triggers `startNextQueuedRun` under the thread lock (ORCH:10630-10697). No queued run: nothing happens.
- Title: effect `thread-title.generate` -> internal `thread.title.regeneration.complete` -> `thread.metadata-updated {title, titleRegeneration null}` (ORCH:491-504, 3159-3166; WORKER:464-480).

### A.11 Auto-settle: when and why

- A sweep runs every minute and on terminal `run.updated`, `provider-session.detached`, `provider-session.updated` not starting/running, `thread.pull-request-synced`, settings changes and PR merge events (SETTLE:599-653).
- It runs only if auto-settlement is configured: `sidebarAutoSettleAfterDays` (default 3) or `sidebarAutoSettleOnMerge` (default true) (SETTLE:253-262; SETTINGS:93, 1204-1209).
- Candidate when: not archived, no settled override, not pinned, auto-settle not disabled, no pending runtime request, no activity run (preparing/starting/running/waiting), no background work holding completion, no recent unadopted user message (2 minutes), and snooze rules (SETTLE:39, 86-108, 139-164).
- It settles when the last activity (user message, run requested/started/completed) is older than the configured days, or when a linked or branch PR was merged (if enabled) or closed after the last user-authored message (SETTLE:110-136, 199-243).
- It dispatches internal `thread.auto-settle {snapshotAt: shell updatedAt, settledAt}`, rejected if the thread changed since or has an override (ORCH:10157-10189; SETTLE:342-349).
- Resulting events: `thread.settled {settledOverride "settled", settledAt, unsettledAt null, pinnedAt null, pin/active order keys null, PR watches removed}` (ORCH:2786-2803) plus `provider-session.detached {reason "Thread settled."}` for live sessions and detach effects (ORCH:3312-3396). Afterwards idle terminals close and the settle script runs (SETTLE:558-597), with no domain events found (UNVERIFIED for script side effects).
- A later message clears it with `thread.unsettled` (ORCH:4562-4585). Manual `thread.settle` is refused with "has active or blocked work" while any run is preparing/queued/starting/running/waiting (except automatic queued wakes) or a non-message request is pending (ORCH:2585-2622).

### A.12 Shell row timeline for scenario A

| After | status | activeRunId | activityRunStatus | pendingRuntimeRequest | latestRunStartedAt / CompletedAt |
|---|---|---|---|---|---|
| TX1 | starting | R | starting | null | null / null |
| TX2 | running | R | running | null | set / null |
| approval pending | running | R | running | {id, kind, createdAt} | set / null |
| respond TX | running | R | running | null | set / null |
| terminal TX | waiting | null | waiting | null | set / null |
| capture TX | completed | null | null | null | set / set |

---

## 5. Scenario B: user input (ask user) and plan mode

### B.1 Structured question, Codex

`item/tool/requestUserInput` (CODEX:5430-5471, 4100-4195):

- `node.updated {id node:provider:codex:native-item:<itemId>, kind user_input_request, status waiting, parentNodeId root}`
- `runtime-request.updated {kind "user_input", status pending, responseCapability live}`
- `turn-item.updated {id turn-item:provider:codex:native-item:<itemId>, type user_input_request, status waiting, requestId, questions [{id, header, question, options [{label, description}]}]}`

Question id defaults to `question-<n>` and header to "Question" (CODEX:4120-4129). Question schema: CONTRACT:1151-1167.

### B.2 Structured question, Claude

`AskUserQuestion` through `canUseTool`: the tool item starts first (AskUserQuestion is unclassified, so `dynamic_tool`, CLAUDE:1685-1691), then `node.updated {kind user_input_request, parentNodeId = tool node}`, `runtime-request.updated {kind user_input}`, `turn-item.updated {id turn-item:runtime-request:<enc requestId>, type user_input_request, questions}` (CLAUDE:6976-7014, 4774-4872). The final status of the AskUserQuestion tool item after the answer is UNVERIFIED.

The run stays "running"; the shell shows `pendingRuntimeRequest {kind "user_input"}`.

### B.3 Answer

- `runtime-request.respond {requestId, answers: {<questionId>: value}, attachmentsByQuestionId?}` (CONTRACT:2959-2967; CCMDS:846-859). Intake claims attachments and appends their paths into the answers (INTAKE:57-126).
- TX: `runtime-request.updated {status resolved, answers}`, `node.updated {completed}`, `turn-item.updated {status completed, questionAnswer {requestId, answers, attachmentsByQuestionId, questionTextById}}` (ORCH:7108-7192).
- Effect delivers: Codex returns `{answers}` (CODEX:5482-5487); Claude returns `allow` with `updatedInput {questions, answers}` (CLAUDE:7027-7039).
- Fixture: one user_input request resolved; items `[user_message, user_input_request, assistant_message]`; run completed (FIX/plan_questions/codex_output.ts:21-38).
- Not answered before the provider turn ends: cancelled by the ingestor (INGEST:303-346).

### B.4 Message-mode questions (Codex async questions)

- Codex `agentMessage` with `delivery: "async"` and questions becomes a request with `responseCapability {type "message"}`, native ref `async:<itemId>`, and turn item `responseMode: "message"` (CODEX:4953-4993, 4166-4170, 4192). These survive the turn end.
- Answer: every required question needs a non-empty answer. The respond TX also contains a complete message dispatch with message id `async-answer:<requestId>`, text built from "question\nanswer" blocks, and dispatch mode `steer_active` when a running turn supports active steering, else `queue_after_active` (ORCH:7193-7271).
- Dismiss: `thread.user-input.dismiss {requestId}` only for message-mode user_input; it responds with decision `cancel`, so the request is resolved and node/item cancelled (ORCH:7290-7326; CCMDS:861-870). `thread.settle` cancels them the same way (ORCH:2624-2639).

### B.5 Plan mode on and off

- `thread.interaction-mode.set {interactionMode: "plan" | "default"}` -> `thread.interaction-mode-updated {full thread}` (CONTRACT:2818-2823; ORCH:3170, 3220). It applies to the next provider turn through `runtimePolicy.interactionMode` (apps/server/src/orchestration-v2/RuntimePolicy.ts:69, 133). It does not detach sessions; only runtime mode changes do so for providers without in-session runtime mode switching (ORCH:3319-3333). How each provider applies plan mode natively was not read (UNVERIFIED).

### B.6 Proposed plan

Codex `item/plan/delta`, every delta, not throttled (CODEX:4218-4249, 3856-3926, 3104-3121):
- `node.updated {id node:provider:codex:native-item:<planItemId>, kind plan, status running}`
- `plan.updated {kind proposed_plan, id plan:..., status active, markdown = cumulative}`
- `turn-item.updated {type proposed_plan, planId, markdown = cumulative, streaming true, status running}`

Codex `item/completed` type plan: the same three with node completed, plan status active, item completed and `streaming false` (CODEX:4896-4926). Fixture: final plan status active, item streaming false (FIX/proposed_plan/codex_output.ts:31-42).

Claude `ExitPlanMode` (CLAUDE:7042-7063, 4529-4660): optional `plan.updated {previous proposed plan, status superseded}`, `node.updated {kind plan, completed}`, `plan.updated {proposed_plan, active, markdown}`, `turn-item.updated {proposed_plan, completed, streaming false}`. The tool call is denied with "The client captured your proposed plan. Stop here and wait for the user's feedback or implementation request in a later turn." The turn then completes normally. The final status of the ExitPlanMode tool item is UNVERIFIED.

Shell: `hasActionableProposedPlan` true while any proposed plan is active (PSTORE:1488-1490).

### B.7 Todo lists

- Codex `turn/plan/updated` -> `node.updated {kind todo_list, running}`, `plan.updated {kind todo_list, status active, steps [{id "step-<n>", text, status pending|running|completed}], explanation?}`, `turn-item.updated {type todo_list, running}` (CODEX:4251-4287, 3928-4000, 548-559). No code that completes the Codex todo node or item at turn end was found (UNVERIFIED that nothing does).
- The ingestor adds `durationAnchorAt` / `durationMs` per step (INGEST:136-198, 483-508).
- Claude `TodoWrite` -> todo_list node and item completed; plan status completed when every step is completed, else active (CLAUDE:6348-6355, 4564-4587).

### B.8 Approving (implementing) a plan

There is no approve command. The official client sends:
1. `thread.interaction-mode.set {interactionMode "default"}` (WEBCHAT:10454-10460, 6318-6329), then
2. `message.dispatch` with `sourcePlanRef {threadId, planId}` (WEBCHAT:10472-10497).

The server requires the plan to exist as `proposed_plan`, be in the same project, and have status active (ORCH:4761-4796). In the run's creation TX it emits `plan.updated {status "completed"}` right after `run.created` (ORCH:4797-4810, 5460) and stores `run.sourcePlanRef` (ORCH:5316). That `plan.updated` carries `threadId` = the plan's thread (ORCH:4804-4805), so "implement in a new thread" (WEBCHAT:10522-10610) writes a completion event into the source thread from the new thread's command. Refining a plan is just another message without `sourcePlanRef`: Codex leaves earlier plans active (no supersede logic in the Codex adapter), Claude supersedes the previous plan when it captures a new one.

---

## 6. Scenario C: interrupt during a running turn

### C.1 Command

Stop button: `run.interrupt {runId, holdQueue: true, reason?}` (CONTRACT:2911-2922; CCMDS:780-831). A plain interrupt omits `holdQueue`.

### C.2 Command transaction for a running turn with a live session (ORCH:8637-9025)

- `turn-item.updated {id turn-item:run:<enc R>:signal:interrupt-request, type run_interrupt_request, status completed, title "Interrupt requested", message reason or "Interrupt requested", providerTurnId}` (ORCH:8735-8755, 8999-9007).
- With `holdQueue` (ORCH:8475-8547): `run.updated {queueHeld true}` for every unheld queued run; `thread.pull-request-synced` with watches removed when any PR is watched; disposal of delegated completion cohorts (`run.updated` with `delegatedCompletion.disposition "stopped"`, `subagent.updated` with `completionDelivery.state "disposed"`, cancellation of a queued delivery run, ORCH:2070-2151).
- Without `holdQueue`: only this run's cohort is disposed (ORCH:8714-8732).
- The provider must support interrupts (CMDPOL:272-277; ORCH:8989-8996).
- Effects: `provider-turn.interrupt {providerSessionId, providerThreadId, providerTurnId}`, plus interrupts for other live provider threads that own pending background work (ORCH:8757-8813, 9009-9023), plus `delegated-tasks.stop` when `holdQueue` (ORCH:10290-10307).

### C.3 Provider side

The effect calls `adapter.interruptTurn` with `requestRuntimeRestart: true`, then waits up to 2 s for the terminal to be ingested (CONTROL:173-220).
- Codex: `turn/interrupt`; `turn/completed` arrives with status interrupted (a `completed` received while interrupting is mapped to interrupted, CODEX:5973-5978). `finalizeCodexTurn` flushes text (final `message.updated` and items), emits `provider-turn.updated {status interrupted}`, terminalizes running command items and dynamic tools as interrupted (CODEX:5854-5886, 6684-7071).
- Claude: `query.interrupt` + close; `finalizeActiveTurn` with status interrupted: open tool items interrupted, `provider-turn.updated {interrupted}`, `provider-thread.updated {status idle}` (CLAUDE:7657-7743, 4980-5236).
- Native user_input requests of that turn are cancelled by the ingestor (C.8).

### C.4 Run finalization TX (EXEC:563-801)

- cascade: open run-owned subagent rows, nodes and child items -> interrupted (EXEC:209-322, 632-641)
- `run-attempt.updated {status interrupted, completedAt}`
- `turn-item.updated {id ...:signal:interrupt-result, type run_interrupt_result, parentItemId = interrupt-request item id, status interrupted, title "Interrupted", message "Run interrupted by user"}` (EXEC:710-729, 1473-1504)
- `run.updated {status interrupted, completedAt}`
- `node.updated {root, status interrupted, completedAt}`
- `provider-thread.updated {status idle}`
- effect `checkpoint.capture` (stopped runs capture too, EXEC:671-691)

### C.5 Follow-up settle

After the interrupt effect, the worker dispatches internal `thread.background-work.settle` (command id `<effectId>:background-work-settled`) (WORKER:165-204; CONTRACT:3098-3104). If the run is still "running" (no terminal arrived) it runs the local settlement (ORCH:8213-8394, 8601-8616):
- `provider-turn.updated {interrupted}`, `run-attempt.updated {interrupted}`, `provider-thread.updated {idle}`
- `message.updated {streaming false}` for streaming messages
- cascade of subagent/assistant/reasoning items
- pending runtime requests of the run -> `runtime-request.updated {status cancelled, responseCapability {type not_resumable, reason "The run was interrupted."}}`
- interrupt-result item, `run.updated {interrupted}`, checkpoint.capture effect.
Then leftover background items become interrupted and dead process rosters are cleared (ORCH:8115-8209, 8617-8634). A settle with nothing to do records a receipt with no events (ORCH:10553-10579).

### C.6 Checkpoint for stopped runs

`checkpoint.captured` + checkpoint item + `run.updated` keeping status interrupted (or cancelled) with `checkpointId` set; no root `node.updated` (CAPTURE:70-82, 209-217, 218-236).

### C.7 Interrupt before the provider turn exists (run preparing or starting)

One TX (ORCH:8815-8934): interrupt-request item; `turn-item.updated {interrupt-result, status interrupted, message "Run interrupted before provider start"}`; preparation item -> interrupted "Workspace preparation interrupted" if present; `run-attempt.updated {interrupted}`; `node.updated {root interrupted}`; `run.updated {interrupted, completedAt}`. Unsettled `provider-turn.start` and `provider-turn.restart` effects of the thread are cancelled (ORCH:8927-8933). No checkpoint capture in this path.

### C.8 Pending approvals and questions at interrupt time

- Native `user_input` requests of the provider turn: cancelled on the terminal provider turn (INGEST:303-346, 416-433).
- Approval requests: adapters never emit cancellations (the only `runtime_request.updated` emitters create requests: CODEX:4972, 5079, 5139, 5200, 5285, 5344, 5404, 5462; CLAUDE:7003, 7105). They close only through local settlement (session dead or run still running at settle time, ORCH:8335-8354), session release (`expired`, or `cancelled` on manual/server shutdown, with not_resumable, SESS:261-271, 672-776), or restart recovery (`expired`, RECOVER:301-318). In the normal live-session path a still-pending approval may stay "pending" in the projection after the run is interrupted. UNVERIFIED: no closing path found. Claude internally resolves its pending decision as "cancel" on abort (CLAUDE:2307-2320); Codex interrupts its pending handlers without events.

### C.9 Queued messages

- With `holdQueue` they are held (`queueHeld: true`) and do not start; resume with `queue.resume` (E.6). Test: Stop leaves runs `["completed", "interrupted"]` and child queues `"queued:held"` (apps/server/src/orchestration-v2/ThreadStop.test.ts:149-214).
- Without `holdQueue` the next queued run starts on the interrupted `run.updated` (ORCH:10630-10660), subject to E.7 holds.

### C.10 Dead session

When the provider session is gone, the command TX itself contains the interrupt-request item, the local settlement of C.5 and the background settle (ORCH:8945-8980).

### C.11 Interrupted versus cancelled

- interrupted: user interrupt/Stop; provider-reported interrupted turns; interrupt before start; the old root node of a steering restart (ORCH:4332-4342).
- cancelled: queued run cancellation (cancel, promote-to-steer, archive, settle of automatic wakes, cohort disposal); provider-reported cancelled terminals (allowed by PADAPTER:131-140); restart recovery of nonterminal runs (RECOVER:319-328). Queue-command cancellations get no checkpoint.

### C.12 thread.stop

Internal command used for delegated tasks: interrupts the active run (or the latest run with pending background work) with `holdQueue` semantics; with nothing to stop it still holds the thread and marks stopped runs with an interrupt-request item (ORCH:9033-9110, 8417-8467).

---

## 7. Scenario D: steering

### D.1 Command

`message.dispatch` with `dispatchMode {type "steer_active", targetRunId}` (or `deliveryIntent "steer"`, or `"auto"` which picks steer when the active run's session supports active steering, else queue if supported, else restart if supported, else queue; a preparing or starting run is always queued) (CMDPOL:120-165; CCMDS:733-751).

Before steering (ORCH:4649-4667): if the target run is completed, or running/waiting with its latest provider turn already completed, the steer becomes `start_immediately` (a new run; queued if a blocking run such as a "waiting" one exists).

Rejections in `dispatchSteerIntoRun` (ORCH:3762-3856): target missing; `/compact` and `/logout` ("must run as a separate turn"); `/goal`; steering into a run started by /compact or /logout; target status not "running" ("is <status> and cannot be steered"); no live session; no running provider turn.

Policy (CMDPOL:249-270): active steering if supported and not forced; otherwise interrupt-restart if both interrupt and restart are supported; otherwise reject (capability `active_steering` or `interrupt_restart_steering`). A restart is forced for `restart_active`, for a selection change that must apply now, and for any selection change when the provider supports interrupt-restart (ORCH:3975-3995).

### D.2 Active steering (Codex, Claude, Pi, OpenCode, Muse)

TX (ORCH:3997-4045, 3894-3973):
- only when the steer's selection differs from the thread's saved selection: `thread.model-selection-updated` or `thread.provider-switched` (the running run keeps its selection; test apps/server/src/orchestration-v2/SteeringCompletion.integration.test.ts:568-641)
- `message.updated {role user, runId = target run, nodeId = root}`
- `turn-item.updated {type user_message, inputIntent "steer", providerTurnId = running provider turn, status completed}`
- effect `provider-turn.steer {providerSessionId, providerThreadId, providerTurnId, messageId}`

No run, attempt or node event. Delivery: Codex `turn/steer {expectedTurnId, input}` (CODEX:6630-6665); Claude offers a user message with priority "now" (CLAUDE:7745-7791), which cancels pending tool calls: those items become `cancelled` with `toolNonExecutionKind: "cancelled"` (apps/server/src/orchestration-v2/ClaudeAutomaticDelivery.integration.test.ts:386-399). Fixtures: 1 run, 1 provider turn, intents `["turn_start", "steer"]` for Codex and Claude (FIX/message_steering/codex_output.ts:19-43; FIX/message_steering/claude_output.ts:19-43).

### D.3 Steer that misses the turn

If the provider turn ended before delivery, the steer effect fails with `turnCompleted` and the worker dispatches `message.dispatch` with command id `command:steer-follow-up:<effectId>`, the same messageId and text, `start_immediately` (`queue_after_active` for delegated completions) (WORKER:234-289; CONTROL:121-130). The result is a new run, queued if the previous run is still "waiting", which then starts after capture. The message is re-pointed to the new run by `message.updated`. In the queue path the existing user_message item is updated to the new run with `inputIntent "queued_turn"` (ORCH:5102-5123). Test: apps/server/src/orchestration-v2/SteeringCompletion.integration.test.ts:643-709.

### D.4 Steering by interrupt-restart (Cursor, ACP registry; Codex and OpenCode when forced)

TX (ORCH:4047-4458):
- `run-attempt.updated {old attempt, status "superseded", completedAt}`
- `node.updated {old root, status "interrupted", completedAt}`
- selection events when changed; `provider-thread.updated`, `context-handoff.updated`, `context-transfer.created` when the provider thread or session must change
- `run.updated {same RunId, status "starting", rootNodeId node:run:<enc R>:attempt:<k>:root, activeAttemptId run-attempt:...:attempt:<k>, userMessageId = steer message}`
- `run-attempt.created {attemptOrdinal k, reason "steering_restart", status pending}`
- `node.updated {new root, status pending}`
- `checkpoint-scope.created`
- `message.updated` and `turn-item.updated {user_message, inputIntent "steer", nodeId new root, providerTurnId null}`
- effect `provider-turn.restart`

The restart effect interrupts the old provider turn and waits for its terminal (CONTROL:221-286). The old turn is ingested as `provider-turn.updated {interrupted}`. Its finalization is skipped because the attempt no longer owns the run; only an unpaired Stop request would add a `run_interrupt_result` (EXEC:587-624). Then a session detach or replace if needed, and `provider-turn.start` runs A.3 onward (WORKER:300-346). Fixture: one run, attempts `[["initial","superseded"], ["steering_restart","completed"]]`, provider turns `["interrupted","completed"]`, no run_interrupt items (FIX/message_steering/cursor_output.ts:36-55).

### D.5 Promote a queued message to steer

`queued-message.promote-to-steer {queuedRunId, targetRunId}` (CONTRACT:2923-2929). TX: queued run `run.updated {cancelled, queuePosition null, completedAt}`, `run-attempt.updated {cancelled}`, `node.updated {cancelled}`, then D.2 or D.4 with the queued message (same messageId), `inputIntent "promoted_queued_to_steer"`, and the thread's saved selection (ORCH:7328-7466, 3947-3950). Automatic deliveries cannot be promoted (ORCH:7391-7400).

### D.6 Capabilities

| Provider | supportsActiveSteering | supportsSteeringByInterruptRestart | supportsQueuedMessages | Citation |
|---|---|---|---|---|
| Codex | true | true | true | CODEX:267-276 |
| Claude | true (activeSteeringInterruptsTools true) | false | true | CLAUDE:199-209 |
| Cursor | false | true | true | packages/provider-cursor/src/server/adapter.ts:104-107 |
| ACP | false | true | true | packages/provider-acp/src/server/adapter.ts:556-559 |
| Pi | true | false | true | packages/provider-pi/src/server/adapter.ts:141-144 |
| OpenCode | true | true | true | packages/provider-opencode/src/server/adapter.ts:145-148; packages/provider-opencode/src/server/v2/adapter.ts:127-131 |
| Muse | true | false | true | packages/provider-muse/src/server/adapter.ts:110-113 |

Claude rejects `restart_active` (no interrupt-restart). Server-routed delegated completions avoid steering into providers whose steering interrupts tools (ORCH:4721-4756).

---

## 8. Scenario E: queue

### E.1 Queue a message while a run is active

`message.dispatch` with `queue_after_active`, or `start_immediately`/`defer_start` while a blocking run exists (preparing, starting, running, waiting, ORCH:516-523, 4842-4851). The target provider must support queued messages (ORCH:4889-4899). TX (ORCH:4852-5125):
- `provider-thread.updated` only for a not-yet-existing provider thread (placeholder with providerSessionId null, so it does not move activeProviderThreadId)
- `run.created {status "queued", queuePosition = max(queued positions or ordinals) + 1, queueHeld true if any queued run is held, rootNodeId, activeAttemptId, requestedAt, startedAt null}` (ORCH:4949-4981)
- `plan.updated` with sourcePlanRef
- `run-attempt.created {pending}`, `node.updated {root pending}`
- `checkpoint-scope.created` (skipped when the active run is preparing)
- `message.updated {runId = queued run}`
- No user_message turn item is created now (an existing item for the same messageId is only re-pointed, ORCH:5102-5123).

Shell: status "queued" (the queued run is presented), activeRunId and activityRunStatus still describe the running run.

### E.2 Edit, reorder, cancel

- `queued-run.edit {runId, text, attachments?, context?}`: `message.updated` (and `turn-item.updated` if an item exists). Empty text and automatic deliveries are rejected (ORCH:7653-7742; CONTRACT:2948-2958).
- `queued-run.reorder {runId, beforeRunId | null}`: `run.updated {queuePosition}` only for runs whose position changed; automatic deliveries stay first and nothing can be placed before them (ORCH:7468-7557). Delivery order: automatic completion deliveries first, then `queuePosition ?? ordinal`, then ordinal (QORDER:12-31).
- `queued-run.cancel {runId}`: `run.updated {cancelled, queuePosition null, completedAt}`, `run-attempt.updated {cancelled}`, `node.updated {cancelled}`; for a delegated-completion delivery the cohort is disposed instead (ORCH:7559-7651). The cancelled queued message is hidden from the timeline (TIMELINE:59-66). Test: runs `["completed","cancelled","completed"]` (apps/server/src/orchestration-v2/OpenCode2OrchestratorV2.integration.test.ts:677-759).

### E.3 Automatic start of the next queued run

The terminal `run.updated` of the active run (after capture for completed runs) triggers `startNextQueuedRun` (ORCH:10630-10660, 1266-1870). Guards: thread not archived or deleted, no blocking run, no held queued run, no usage-limit block (ORCH:1270-1292). Events are written as one system write (no command id, ORCH:1009-1018, 1721-1849):
- selection events when the queued run's selection differs from the thread
- `context-transfer.created` + `context-handoff.updated` + handoff turn item for a cross-provider handoff
- `provider-session.detached` for sessions released by a provider switch
- `checkpoint-scope.created` + `node.updated {checkpointScopeId}` when the queued run has no scope
- `provider-thread.updated {status "not_loaded", lastRunOrdinal = queued ordinal}`
- `turn-item.updated {type user_message, id turn-item:message:<messageId>, inputIntent "queued_turn", status completed}`
- `run.updated {status "starting", queuePosition null}`
- effect `provider-turn.start` (command id `command:system:start-queued:<runId>`), then A.3 onward.

On failure: `run-attempt.updated {failed}`, `node.updated {failed}`, error item "Queued provider could not start" with failure code `context_handoff_unsupported` (class validation_error) or `queued_start_failed` (class unknown), `run.updated {failed}` (ORCH:1161-1264).

### E.4 Paused (held) queue states

`queueHeld: true` is set by:
- Stop (`holdQueue`) (ORCH:8497-8506)
- a failed run whose failure class is not `validation_error` on the same provider instance as the next queued run (ORCH:1297-1325)
- server restart recovery (RECOVER:287-300)
- new queued runs inherit the hold when any queued run is held (ORCH:4960-4964)

A usage-limit failure blocks starting without setting `queueHeld` (ORCH:1281-1292; THREADERR:85-94). Held queued runs are not presented in the shell; if only held runs exist the shell is "idle" (ProjectionStore.test.ts:2251-2302). A new `start_immediately` message starts immediately past a held queue, because held queued runs are not blocking (ORCH:4845-4851; apps/server/src/orchestration-v2/ThreadStop.test.ts:406-416).

### E.5 Other queue interactions

- Archive cancels queued runs (ORCH:3250-3310).
- Settle cancels queued automatic wakes and refuses with user-queued runs (ORCH:2585-2651).
- Snooze is refused while a run is queued (ORCH:2751-2756).

### E.6 queue.resume

`queue.resume {threadId}` (CONTRACT:2930-2934). TX: `run.updated {queueHeld false}` for each queued run, or `thread.metadata-updated` (unchanged thread) when none exist, so the command is not rejected (ORCH:10314-10370). After commit, `startNextQueuedRun` runs in the same call (also on a replayed receipt) (ORCH:10474-10476, 10611-10613). Test: the queued run is "starting" right after resume (apps/server/src/orchestration-v2/ThreadStop.test.ts:429-439). Rejected for archived or deleted threads and while a usage limit blocks the thread ("Continue the limited thread before resuming its queue.", ORCH:10320-10342).

---

## 9. Scenario F: failures

### F.1 Failure shapes

- `OrchestrationV2ProviderFailure {class, message (max 4096), code (max 128) | null, retryable | null, resetAt?}`; classes usage_limit, provider_error, transport_error, permission_error, validation_error, unknown (CONTRACT:1261-1288).
- Messages are redacted (URLs stripped of credentials and queries, bearer tokens, key/value secrets, `sk-` keys) and bounded (FAIL:88-172). Known causes get curated text, for example "The provider could not start this turn. Retry the turn; if it keeps failing, check the provider setup and server logs." (FAIL:35-76).
- Error turn item: `{type error, status failed, title "Provider error" | "Usage limit reached", failure, retry?}` (CONTRACT:1492-1497; FAIL:174-210).

### F.2 Provider retry during a turn

- Codex `error` notification with `willRetry`: `turn-item.updated {id terminal-failure item, type error, status running, title "Provider retry", failure {class usage_limit | transport_error (codes starting with http or responseStream) | provider_error, retryable true}, retry {attempt, maxAttempts | null, retryDelayMs null}}` (CODEX:4477-4558; FAIL:212-260). Without `willRetry` the failure is remembered for the terminal (CODEX:4484-4497).
- Claude `api_retry`: the same item with `retry {attempt, maxAttempts, retryDelayMs}` (CLAUDE:6054-6097; CONTRACT:1291-1300).
- When model output resumes, the item becomes `status completed, title "Provider recovered"` (CODEX:1925-1960; CLAUDE:6099-6101). At a non-failed terminal it becomes completed, or "Provider retry stopped" for interrupted/cancelled (CODEX:5730-5753; CLAUDE:5061-5090; FAIL:230-238).

### F.3 Terminal failure from the provider

1. `provider-turn.updated {status failed}` (CODEX:5777-5808; CLAUDE:5127-5143).
2. The ingestor turns `turn.terminal(failed)` into `turn-item.updated {error item, id turn-item:provider:<driver>:native-item:terminal-failure%3A<enc providerTurnId>, nodeId root, status failed}`, reusing the retry item id so it replaces it (INGEST:509-536). Pending native user inputs are cancelled first.
3. Finalization TX (EXEC:563-801, `failureItemPersisted` true at 997): `run-attempt.updated {failed}`, `run.updated {status failed, completedAt}`, `node.updated {root failed}`, `provider-thread.updated {idle, or error when threadDisposition broken}`. No checkpoint capture for failed runs (EXEC:674-691).

Class sources: Codex `usageLimitExceeded` / `rateLimitExceeded` -> usage_limit with `resetAt` from rate-limit snapshots, later filled by `account/rateLimits/updated` re-emitting the error item (CODEX:5491-5602, 4289-4311); else provider_error. Claude defaults to provider_error (CLAUDE:5106); a query stream exit becomes transport_error (CLAUDE:5281-5302).

### F.4 Failures before or around the provider turn

- Session open fails on the last attempt: `turn-item.updated {error, id ...:signal:provider-session-open-failure, title "Provider session failed to open", class provider_error}`, `run.updated {failed, completedAt}`, `run-attempt.updated {failed}`, `node.updated {failed}`, written only while the run is still "starting" (START:291-377, 556-593). Provider thread load: signal `provider-thread-load-failure`, title "Provider turn failed to start" (START:597-610). Earlier attempts retry silently (WORKER:551, 693).
- Run preparation inside RunExecutionService: failure "Run preparation failed.", class unknown (EXEC:868-911).
- `startTurn` throws: failure class provider_error (unknown when the ownership read failed), provider turn id `attempt.providerTurnId` or derived `failed:<attemptId>` (EXEC:818-836, 1415-1467).
- Event ingestion crashes: class unknown (EXEC:1285-1341).
- Empty `/compact`: validation_error "Start a conversation before compacting this thread."; failed `/logout`: permission_error (START:378-463).
- Workspace preparation: `prepared-run.fail` -> preparation item failed plus error item with `code "workspace_preparation_failed"` and run failed; `prepared-run.retry` reverts to preparing (ORCH:7925-8105; CONTRACT:539).

### F.5 Session-level failure

A provider runtime error releases the session: `provider-session.updated {status "error", lastError}` to all attached threads, and pending live requests -> `runtime-request.updated {status expired, responseCapability not_resumable}`, `node.updated {failed}`, `turn-item.updated {failed}` (SESS:261-271, 648-776).

### F.6 How the thread shows the error

- Timeline: the error turn item on the run's root node.
- Shell: status "failed", `lastError = failure.message`, `lastErrorClass = failure.class`, `usageLimitResetAt` for usage_limit; a different session `lastError` overrides the message and clears the class (THREADERR:9-49; PSTORE:1470-1473).
- Queue: holds or blocks per E.4.
- Recovery options: `manualContinuationOfRunId` (interrupted or usage-limited latest run, no pending requests; ORCH:4468-4487; CCMDS:698-700), `usageLimitContinuationOfRunId` (ORCH:4488-4530).
- Rejected commands produce no events and only the RPC error of section 1.9.

---

## 10. Scenario G: checkpoint rollback

### G.1 Command

`checkpoint.rollback {scopeId, checkpointId, restoreFiles?}` (CONTRACT:2974-2981). The official client picks the checkpoint with `appRunOrdinal == turnCount`, or the ordinal-0 baseline for turnCount 0 (CCMDS:872-917). The web "rewind to message" flow uses turnCount = the message's run ordinal minus 1 and refuses while a turn runs ("Interrupt the current turn before reverting checkpoints.", WEBCHAT:8391-8434).

### G.2 Validation (ORCH:9112-9239)

- active provider thread with a session
- provider capability `canRollbackThread`, `providerCanRollbackConversation`, `providerRollbackReturnsSnapshot` (CMDPOL:306-325); true for Codex and Claude (CODEX:258-266, 326-332; CLAUDE:190-198, 259-265)
- checkpoint exists with status ready, scope matches
- isolated workspace when `restoreFiles != false`
- the target run's provider turn is on the active provider thread

No server-side guard against an active run was found in the command (UNVERIFIED); the Claude adapter refuses while a turn is active (CLAUDE:8000-8006).

### G.3 Command TX

- `thread.metadata-updated {rollbackRequestId: commandId, rollbackFailure: null}`
- `checkpoint.rollback-requested {scopeId, checkpointId, requestedAt}`
- effect `provider-thread.rollback` (ORCH:9241-9286)

### G.4 Effect (ROLLBACK:110-354)

- opens the session (may emit session events)
- runs to roll back: ordinal > target and status completed, interrupted, failed or cancelled (queued and running runs untouched) (ROLLBACK:202-212)
- provider rollback: Codex `thread/revert` by turn count on paginated history (CODEX:7177-7253); Claude closes its live query and either starts a new native session for a thread-start target (new provider thread id) or sets `nativeConversationHeadRef` to the resume point (CLAUDE:7998-8059)
- restores files from the git ref unless `restoreFiles` is false, deletes stale refs (ROLLBACK:268-278)

### G.5 Resulting events (one write)

- `provider-thread.updated {provider snapshot, lastRunOrdinal = target or null}`
- for each later ready checkpoint: `checkpoint.captured {status "stale"}`
- for each rolled-back run: `run.updated {status "rolled_back", completedAt now}` and `node.updated {root, status "rolled_back"}`
(ROLLBACK:283-353)

Attempts, provider turns, messages, turn items and plans are not modified.

### G.6 Visibility and completion

- Items of rolled_back runs drop out of `visibleTurnItems` (TIMELINE:49-54, 97). Messages stay in `projection.messages`; how the web client filters them was not traced (UNVERIFIED).
- Shell `itemCount` excludes them (PSTORE:5244-5255).
- Later rollbacks ignore provider turns of rolled_back runs (ROLLBACK:213-227).
- There is no explicit success event; the web client waits for the target message's run to become rolled_back or for `rollbackFailure` (WEBLOGIC:1112-1168).
- rolled_back is terminal for queue start and settlement (ORCH:10689-10693; SETTLE:610-615).

### G.7 Failure

After the last retry the worker dispatches internal `checkpoint.rollback.fail` -> `thread.metadata-updated {rollbackFailure {requestId, message "The provider could not roll back this conversation. Try again; if it keeps failing, check the provider and server logs."}}`. A failure from a superseded rollback request is rejected (WORKER:370-404; ORCH:9294-9325; ROLLBACK:31-32). A capture effect that runs after a rollback leaves a rolled_back run alone (CAPTURE:83-88).

---

## 11. Provider differences summary

| Behavior | Codex | Claude |
|---|---|---|
| Assistant text | streamed as cumulative turn item text, 50 ms coalescer; message.updated only final | per completed block, never streamed |
| Reasoning | streamed per summary/content part | thinking blocks streamed, title "Thinking" |
| Command output | final aggregatedOutput only | tool_result output |
| File change | completion only, first file only | Edit/Write/MultiEdit/NotebookEdit with output as diffStr |
| Approvals | JSON-RPC requests; acceptAlways sent as acceptForSession | canUseTool, only when the permission callback is installed |
| Questions | requestUserInput; async message-mode questions | AskUserQuestion via canUseTool |
| Proposed plan | streamed deltas then completed, stays active | ExitPlanMode capture (denied), supersedes the previous plan |
| Todo list | turn/plan/updated, items left running | TodoWrite, items completed |
| Provider turn id | native turn id, strong ref | `turn:<attemptId>`, weak ref |
| Session | shared per instance | per thread |
| Steering | turn/steer | priority "now" message, cancels pending tools |
| Rollback | thread/revert | resumeSessionAt or a new native session |
| Retry info | attempt from message text, retryDelayMs null | attempt, maxAttempts, retryDelayMs |

Other providers: only the capability flags (D.6) and fixture outcomes (Cursor steering restart) were verified. Their detailed event shapes are UNVERIFIED. ACP scopes provider item ids by instance (`itemIdentityVersion 2`, PADAPTER:384-385; CONTRACT:837-838).

---

## 12. Docs versus code

1. Sending on an idle thread creates a run with status "starting", not "queued" (docs/orchestration-v2/feature-lifecycles.md:31-37 vs ORCH:5309). "queued" only when a blocking run exists.
2. A completed provider turn puts the run in "waiting"; "completed" comes only after checkpoint capture (feature-lifecycles.md:48-57, 529-541 vs EXEC:642-653, CAPTURE:201-217).
3. Approvals and questions do not change run status to "waiting" (feature-lifecycles.md:432-437, 461-466 vs EXEC:642-653 being the only writer).
4. Interrupt: the provider terminal is authoritative as documented, but the server also settles locally when the session is dead or no terminal arrives (feature-lifecycles.md:236-247 vs ORCH:8945-8980, 8549-8635).
5. The completion barrier flushes assistant and reasoning text, but no todo or plan finalization was found for Codex (feature-lifecycles.md:531-541).
6. Steering restart keeps the same RunId with a new attempt, matching the doc's preferred default (feature-lifecycles.md:75-80).
7. `RunAttempt.providerTurnId` is documented but appears never populated (section 2.2).

## 13. UNVERIFIED items

1. Exact JSON encoding of DateTimeUtc fields on the WS wire (assumed ISO 8601 strings; persistence uses DateTimeUtcFromString, CONTRACT:1991-2602).
2. Whether a pending approval is ever closed after a normal live interrupt (C.8).
3. Ordering of the Codex command `item/started` relative to its approval request.
4. That nothing completes Codex todo-list nodes and items.
5. Final status of Claude AskUserQuestion and ExitPlanMode tool items.
6. How each provider applies plan interaction mode natively, and the runtime mode to approval policy mapping.
7. That RunAttempt.providerTurnId and root node providerTurnId are never set on any path.
8. That every adapter adopts the placeholder provider thread id in ensureThread (Claude thread-start rollback is known to mint a new id).
9. Absence of a server-side active-run guard for rollback.
10. Detailed event shapes for Cursor, ACP, Pi, OpenCode and Muse.
11. Side effects of the settle script and terminal cleanup after auto-settle.
12. Compensation when a runtime-request.respond effect exhausts its retries.
