# G. Timeline data: thread to rows

Source: /Users/mrm/CandyWrapper-research/t3code (paths below relative to it).

## 1. Loading a thread

Abbreviations: `RT` = `packages/client-runtime/src/state`, `CV` = `apps/web/src/components/ChatView.tsx`. Wire shapes, resume rules, the stream-item reducer, visibility rules and the older-page merge are already in `docs/protocol.md` section 7.7 (`subscribeThread`, bounded snapshots, history paging, merge rule) and `docs/research/B-orchestration.md` sections 3.4 to 3.9. This section adds only what those do not say: the order of calls, the cache and teardown lifecycle, and which selectors feed the row derivation.

### 1.1 Cold open sequence

`makeEnvironmentThreadState` (`RT/threads.ts:170-905`), one per `(environmentId, threadId)`, runs this on first subscription with an empty cache:

1. State starts `{data: none, status: "empty", history: EMPTY}`; status becomes `synchronizing` (`RT/threads.ts:780-796`).
2. If there is no data yet, load the bounded snapshot over HTTP first: `GET /api/orchestration/threads/:id/bounded?compactTurnItems=1` (`RT/boundedThreadSnapshotHttp.ts:21-52`, timeout 6 s). Older servers without the route fall back to the full snapshot `GET /api/orchestration/threads/:id` (20 s timeout, `RT/threadSnapshotHttp.ts:18,68`). Compact turnItems are restored with `boundedSnapshotProjection` (protocol.md 7.7). Outcomes: `present` (seed projection, `lastSequence = snapshotSequence`, history meta from `historyCursor/hasMoreHistory/latestLocalTurnOrdinal`, `RT/threads.ts:832-860`), `missing` on a structured 404 (mark deleted, never open the socket, `:862-867`), `unavailable` on timeout or 5xx (fall through to the socket, `:868-871`).
3. Then open `orchestration.subscribeThread`. Input (`RT/threads.ts:873-893`):
   - `threadId`, always.
   - `afterSequence: lastSequence`, only when data already exists (`canResume`). After step 2 that is the HTTP snapshot's `snapshotSequence`, so the socket replays only newer events.
   - `requestCompletionMarker: true`, when the server's initial config has `threadResumeCompletionMarker === true`. The thread status stays `synchronizing` until the `synchronized` item arrives (`:574-580`); without the capability the status flips to `live` right away (`:882-886`).
   - `acceptBoundedSnapshot: true` and `acceptCompactTurnItems: true`, when the client can page history (HTTP client plus history controller exist, or the HTTP snapshot carried history meta). Without them the server sends a legacy full snapshot.
4. Stream items are applied one batch at a time under a lock (`Stream.runForEachArray(applyItems)`, `:900`): `event`, `unknown-event`, `snapshot`, `synchronized` as in B-orchestration 3.9. A `snapshot` item resets the projection and history meta.
5. Failure handling: expected stream failure retries after 250 ms (`:898`); a foreground resubscribe (app returns from background) restarts with the current `lastSequence` (`:899`); a defect sets error text `Could not synchronize the thread.` (`:894`).

For CandyWrapper the minimum is steps 2 and 3. HTTP first is an optimization of the official client (keeps the multi-KB snapshot off the socket); a native client may send `subscribeThread` with `acceptBoundedSnapshot` and `acceptCompactTurnItems` and no `afterSequence` and take the snapshot from the first frame. The shape is identical.

### 1.2 Warm open, cache, unsubscribe

- The live subscription belongs to an atom with `Atom.setIdleTTL(0)` (`RT/threads.ts:957`): it ends the moment the last component reading the thread unmounts. There is no explicit unsubscribe call in the web client, only scope teardown, which closes the RPC stream.
- A separate per-thread resume atom keeps the last committed `{state, sequence, persisted, acceptsBoundedSnapshots}` for `THREAD_SNAPSHOT_IDLE_TTL_MS = 5 min` (`RT/threadRetention.ts:1-3`, `RT/threads.ts:924-940`). Reopening a thread inside that window starts from the retained state, shows it immediately (`status: "cached"`) and resubscribes with `afterSequence = retained sequence`. After 5 minutes idle the cache entry is dropped and the next open is cold.
- A disk cache (`Persistence.EnvironmentCacheStore`) also seeds `initialState` and `initialSequence` (`RT/threads.ts:190-230`). It never stores an expanded history (`history.expanded == true` after load-earlier), so a persisted entry is always a recent window (`:84-116`).
- Port suggestion: keep a Swift `ThreadStore` keyed by thread id with `projection`, `lastSequence`, `history`, `status` (`empty, cached, synchronizing, live, deleted`, `RT/threadState.ts:6`); drop it 5 minutes after the last view closes; close the stream when the view closes.

### 1.3 Load earlier (paging)

UI: `TimelineHistoryControl` (`T:1648-1674`) shows only when `hasMoreHistory || error != nil` (`RT/threadHistoryMerge.ts:152-154`). It renders a button `Load earlier turns` (while loading: `Loading earlier turns…`, disabled), and under it the error text in muted small type if there is one. It sits at the top of the list (`T:1433`).

Logic `loadEarlier(throughEntryId?)` (`RT/threads.ts:637-749`):

1. No-op unless status is not deleted, data exists, `hasMoreHistory` and `historyCursor != nil`. Returns `busy` if already loading.
2. Remember the request cursor, set `loading=true, error=nil`.
3. Fetch `GET /api/orchestration/threads/:id/history?cursor=<cursor>[&throughEntryId=...][&view=...]` (`RT/threadHistoryHttp.ts:11-46`, 6 s timeout). Plain load-earlier makes one request with no `view`. When `throughEntryId` is given (jump to an entry from search or a link) it makes two: first `view=conversation` (cheap, messages only) merged without advancing the cursor and marking `expanded`, then the full page which advances the cursor (`:687-737`).
4. Merge per protocol.md 7.7. Ignore the response when the stored cursor no longer equals the request cursor (`:723-724`). On failure set `error` text and `loading=false`.
5. The web UI passes `throughEntryId` only for jump navigation. The control's own click passes nothing (`CV:1741-1749`).

### 1.4 Which projection fields feed the timeline

The timeline reads `visibleTurnItems` only, never `turnItems` (`CV:1730`, `RT/threadDetail.ts:53-60`). The selector `useThreadVisibleTurnItems` passes the rows through `createQuestionHistoryProjector` (`RT/threadRequests.ts:118-176`): for a `user_input_request` row without `questionAnswer` whose runtime request is `resolved` with `answers`, it synthesizes `questionAnswer = {requestId, answers, attachmentsByQuestionId: {}, questionTextById: {questionId: question text}}`. Port this, otherwise old answered questions look unanswered.

Inputs `ChatView` hands to the two derivation passes (all from `serverProjection`, which is the thread's `OrchestrationV2ThreadProjection`):

| Timeline input | Source | Cite |
| --- | --- | --- |
| `visibleTurnItems` | `useThreadVisibleTurnItems` | `CV:1730,3921` |
| `attempts`, `nodes`, `plans` | `projection.attempts/nodes/plans` | `CV:3926-3932` |
| `attachmentUrlById` | map from attachment id to asset URL | `CV:3900-3905` |
| `latestRun` | `deriveThreadActivityRun(projection)`: newest run in `preparing, starting, running, waiting`, else the presented latest run (`latestUnheldRun` skips `queued` runs with `queueHeld`; a usage-limit run can stand in). Fields `{runId, status, requestedAt, startedAt, completedAt, assistantMessageId}` | `CV:2141`, `RT/threadExecution.ts:35-120`, `packages/shared/src/orchestrationV2ThreadError.ts:115-124` |
| `runningRunId` | `deriveThreadRuntime(projection).activeRunId` = newest run with status `preparing, starting, running` | `CV:5712`, `RT/threadExecution.ts:224-290` |
| `isWorking` | `phase=="running"` or sending or connecting or compacting or `runlessWorkStartedAt != nil`. `phase = derivePhase(runtime)`: runtime status `preparing, starting, queued` gives `connecting`; `running, waiting` gives `running`; else `ready`; null runtime gives `disconnected` | `CV:3622-3628`, `apps/web/src/session-logic.ts:1069-1079` |
| `runlessWorkActive` | `deriveRunlessWorkStartedAt(projection) != nil`: only for provider-native subagent threads, whose root turn node has `kind=="root_turn"` and `runId==null` and is active | `CV:11389`, `RT/threadExecution.ts:116-123` |
| `activeTurnStartedAt` | `deriveActiveWorkStartedAt(latestRun, runtime, localDispatchStartedAt) ?? runlessWorkStartedAt`. For a read-only view: `latestRun.startedAt ?? latestRun.requestedAt` while the run is unsettled | `CV:3664`, `packages/shared/src/orchestrationTiming.ts:68-87` |
| `turnDiffSummaries` | `deriveThreadCheckpointSummaries(projection)`, section 5 | `CV:4095`, `apps/web/src/hooks/useTurnDiffSummaries.ts` |
| `workspaceRoot` | `thread.worktreePath ?? project.cwd` | `CV:4224` |
| `runs` (handoff labels) | `projection.runs` | `CV:11441` |
| `supportsConversationRollback` | provider capability; false for read-only | `CV:3292` |

Skipped in M4 because they need the composer or optimistic sends: `optimisticMessages`, `anchoredMessages` (Codex feedback), queued runs, pending approvals and user inputs (the live pass ignores them), worktree setup.

`ThreadRunSummary` (`RT/models.ts:39-50`) uses the run statuses `preparing, queued, starting, running, waiting, completed, interrupted, failed, cancelled, rolled_back` (`packages/contracts/src/orchestrationV2.ts:453-464`). The row pass only compares to `running, starting, waiting, failed, interrupted` (`L:808-826`, `L:1110-1135`).

### 1.5 Settled vs live at a glance

An M4 view of a thread with no active run passes `isWorking=false`, `runningRunId=nil`, `latestRun` = the last run. Then `unsettledRunId = nil` (completedAt set and status not running, starting or waiting), `activeVisualResponseRunIds = {}`, and every turn with a hidden-able body folds. A failed latest run is `failedRunIds`, which exempts it from folding (`L:941-956`), so a failed turn shows all its entries. If a run is active, pass real values and re-derive on every applied event; the output is a pure function of the inputs.

## 2. Row derivation

Abbreviations: `L` = `apps/web/src/components/chat/MessagesTimeline.logic.ts`, `S` = `apps/web/src/session-logic.ts`, `CR` = `packages/client-runtime/src`. Wire types are in `docs/protocol.md` section 8 and `docs/research/B-orchestration.md` 1.10 and are not repeated.

### 2.0 Pipeline


### 2.1 Pass 1: item to TimelineEntry

Entry kinds (`S:125-169`): `message`, `proposed-plan`, `html-render`, `mcp-app`, `work`, `event`. Each carries `id`, `createdAt` and an optional `attempt` (`{id, runId, attemptOrdinal, rootNodeId, status}`).

`createdAt` = `item.startedAt ?? item.updatedAt` (`S:350-352`). Messages use the same.

Per `row.item.type`, in this check order (`S:629-770`):

| Condition | Result | Cite |
| --- | --- | --- |
| `turnItemIsWorkspacePreparation(item)`: `command_execution` with `input == "Preparing workspace"`, or `error` that is `cancelled` with `failure.code == "workspace_preparation_failed"` | skipped | `S:629`, `CR/state/turnItemPresentation.ts:13-20` |
| `todo_list`, `checkpoint` | skipped (task progress lives in the composer; checkpoints become the diff summaries) | `S:631` |
| `user_message` whose `messageId` equals `async-answer:<requestId>` of some `user_input_request` that has `questionAnswer` | skipped (the answer folds into the request row) | `S:620-626,632` |
| `notification` | `work` entry, `label = item.summary`, `tone "info"`, `itemType "notification"` | `S:636-653` |
| `user_message`, `assistant_message` | `message` entry. `id = item.messageId` (not the item id). `ChatMessage` fields below | `S:655-695` |
| `proposed_plan` | `proposed-plan` entry, `id = item.id`. `status` from the matching `plans[planId]` if `kind=="proposed_plan"`, else `"active"` | `S:697-715` |
| `dynamic_tool`, `status=="completed"`, and `htmlRenderFromToolItem(item)` non-null | `html-render` entry (skip in M4) | `S:718-731`, `packages/shared/src/toolOutput.ts:186` |
| same for `mcpAppFromToolItem` | `mcp-app` entry (skip in M4) | `S:733-750`, `packages/shared/src/toolOutput.ts:202` |
| type in `fork, handoff, run_interrupt_request, run_interrupt_result, secret_request, subagent` | `event` entry | `S:329-336,752-761` |
| anything else | `work` entry built by `projectedWorkEntry` (section 3) | `S:763-769` |

`ChatMessage` fields (`S:656-690`): `id = messageId`, `role` user/assistant, `text`, `context` (user only), `attachments` (each plus `previewUrl` if the map has it), `runId = item.runId` (user messages usually null), `streaming = (assistant && item.streaming)`, user-only `createdBy`, `creationSource`, `senderThreadId?`, `scheduledTaskId?`, `inputIntent`, `createdAt`, `updatedAt = formatIso(item.updatedAt)`.

Attempt resolution (`S:603-617`): walk from `item.nodeId` up `parentNodeId`; return the first attempt whose `rootNodeId` is the node (or the node's `rootNodeId`) and whose `runId == item.runId`. Items without node or run get no attempt. Cycle guard by visited set.

Types that become generic `work` entries via `projectedWorkEntry` (`S:430-567`): `thread_created`, `compaction`, `reasoning`, `command_execution`, `file_change`, `file_search`, `web_search`, `checkpoint` (never reached, skipped above), `system_notice`, `error`, `dynamic_tool` (when not html/mcp-app), `approval_request`, `user_input_request`, and a default branch for any other type (label = `type.replaceAll("_"," ")`, `S:561-566`). `thread_created` is a `work` entry here, even though `PERSISTENT_RESOURCE_V2_ITEM_TYPES` (`S:338-344`) lists it. `attachCreatedThreadSummaries` (2.7) special-cases it through `projectedItem.item.type`.

`timelineEntryIsPersistentResourceCard(entry)` (`S:345-349`): `kind=="event"` and item type in `{fork, thread_created, secret_request}`. These never fold.

### 2.2 Pass 2 pre-processing (`timelineRowEntries`, `L:1297-1299`)

1. `settleSupersededReasoning` (`L:1275-1295`): every `work` entry that is `reasoning` with `toolLifecycleStatus=="inProgress"` and is not the last entry is treated as `completed`. A later entry ends thinking even if the provider never sent a completion.
2. `withoutSubagentDelegationRows` (`L:1246-1273`): collect `subagent` event items with `origin=="app_owned"` and a `runId`, grouped by run (set of `subagentId`). Drop a `work` entry when its item (`projectedItem.item` or `structuredPayload`) is a `dynamic_tool` with a `runId`, status `running` or `completed`, `resolveT3McpToolDefinition(toolName).summaryAction=="delegate"`, whose parsed output has a `taskId` that is in that run's set and is not `isError`. Failed entries (`workEntryDisplayIndicatesToolFailure`) always stay. The delegate tool names live in `packages/shared/src/t3McpToolPresentation.ts` (not read; M4 can skip unless tool names `t3_thread_launch`/`delegate_task` matter).

### 2.3 Per-row derivations used by several kinds

- `terminalAssistantMessageIds` (`L:712-736`): walk entries in order. A `user` message increments `nullTurnResponseIndex`. For each assistant message the key is `turn:<runId>` or `unkeyed:<index>`; the last assistant message id per key wins. The set of winners is "terminal". These get the meta row and are never folded.
- `unsettledRunId` (`L:808-826`): `runningRunId` if given; else null when `latestRun==null`; else the latest run's id unless `completedAt!=null && status not in {running, starting, waiting}`.
- `failedRunIds` (`L:941-956`): `latestRun.runId` if its status is `failed`, plus the `runId` of every `error` item (status `failed`, `parentItemId==null`) seen as an `event` entry or a `work` entry's `projectedItem`.
- `activeVisualResponseRunIds` (`L:900-927`): empty if no unsettled run. Else `{unsettledRunId}`; and if `isWorking`, also every run id found on entries after the last response boundary (`timelineEntryRunId`, `L:74-84`: assistant message runId, proposed plan runId, html/mcp runId, work entry runId). A response boundary is a user message whose `inputIntent` is not `steer` or `promoted_queued_to_steer`, or a `work` entry of `itemType=="notification"` (`L:880-898`). A promptless restart therefore stays inside one visual response.
- `computeMessageDurationStart` (`L:655-672`): over messages in order, `lastBoundary` = the `createdAt` of the latest user message; each message maps to `lastBoundary ?? createdAt`; after a non-streaming assistant message `lastBoundary = its updatedAt`. Feeds `durationStart` on message rows (the meta row computes "elapsed" from it).

### 2.4 Row kinds (output of `deriveMessagesTimelineRows`)

Row union: `L:514-648`. Every row has `id`, `createdAt`. After the main loop, any row for which `timelineRowIsWorkLog(row)` (`work`, `work-toggle`, `work-live`, `thinking`; `L:1947-1956`) is followed by another such row gets `continuesWorkLog: true` (`L:1938-1944`). That flag only removes the gap between two adjacent work rows.

| kind | Fields | Source and rules | Default state | id | Cite |
| --- | --- | --- | --- | --- | --- |
| `message` (user) | `message`, `projectedItem`, `durationStart`, `showAssistantMeta=false`, `revertTurnCount?` | one per user_message entry | always shown. Long text collapses (4.5) | entry id = `messageId` | `L:1795-1844` |
| `message` (assistant) | same plus `showAssistantMeta`, `showAssistantCopyButton`, `assistantCopyStreaming`, `assistantTurnDiffSummary?` | one per assistant_message entry. `showAssistantMeta = terminal && !stillInProgress` (see 2.3). `assistantCopyStreaming = message.streaming || stillInProgress`. `stillInProgress = runIdIsActiveResponse(message.runId)` | shown unless inside a collapsed turn fold | `messageId` | `L:1795-1844` |
| `assistant-meta` | `message`, `projectedItem?`, `showAssistantCopyButton`, `assistantCopyStreaming` | synthesized by `attachTrailingToolGroupsToAssistant` (2.7) | shown | `assistant-meta:<messageId>` | `L:1151-1244` |
| `work` | `groupedEntries: WorkLogEntry[]`, `isExpandedToolGroup`, `displayLabel?` | three origins, see 2.5 | single tool-like call renders as one line, expanded body shown on click | entry id (single) or `<groupId>:details` (expanded body); `groupId = "work-group:" + firstEntryId` | `L:681-692,1597-1738` |
| `work-toggle` | `runId`, `groupId`, `hiddenCount`, `expanded`, `summary`, `summaryKind`, `toolSurface?`, `toolIcon?`, `summaryToolIcon?`, `hasFailure` | group header for 2+ settled work entries (or a lone non-tool entry) | collapsed (`expandedWorkGroupIds` empty) | `work-toggle:<firstEntryId>` | `L:1689-1738` |
| `work-live` | `entry`, `groupedEntries`, `groupId`, `expanded`, `active`, `thought?` | the live activity line of a running turn (2.6) | collapsed | `live-activity-row` when `active`, else `work-live:<anchorEntryId>`; or `work-live:<firstEntryId>` for the non-tail case | `L:1470-1487,1635-1665` |
| `working` | `createdAt: string|null` | "Working" header with elapsed timer | n/a | `working-indicator-row` | `L:1493-1498` |
| `thinking` | `groupId?`, `expanded?` | placeholder while running with no visible activity; also stands in after the latest tool failed | collapsed | `live-activity-row` | `L:1896-1937` |
| `turn-fold` | `runId`, `label`, `expanded` | header inserted before the first entry of a settled turn; hides that turn's intermediate work | collapsed | `turn-fold:<runId>` | `L:1538-1550` |
| `attempt-fold` | `runId`, `attemptId`, `label="Superseded attempt"`, `expanded` | header for provider output owned by a superseded attempt | collapsed | `attempt-fold:<attemptId>` | `L:1554-1565` |
| `context-compaction` | `label`, `active` | `work` entry with `sourceActivityKind=="context-compaction"` | shown (folds only inside a turn that folds other work) | entry id | `L:1575-1590` |
| `event` | `projectedItem`, `subagents?`, `resourceSummary?` | `fork`, `handoff`, `run_interrupt_result`, `secret_request`, `subagent`. `run_interrupt_request` entries are dropped | shown | entry id; `summary:<entryId>` for the post-answer summary copies of `thread_created` | `L:1530-1537,1775-1800` |
| `proposed-plan` | `proposedPlan` | pass-through | shown | item id | `L:1738-1746` |
| `html-render`, `mcp-app` | references | pass-through (web content; M4 can skip rows or show a placeholder) | shown | item id | `L:1748-1768` |
| `worktree-setup` | `snapshot`, `embedded` | bootstrap progress card, inserted after the first user message | n/a, skip | `worktree-setup-row` | `L:1838-1895` (skip in M4) |

Rows named `thinking`, `working`, `work-live` only exist when `isWorking`. A settled thread never produces them.

### 2.5 Work-entry grouping (the `work` / `work-toggle` / `work-live` decision)

Loop body at `L:1596-1738`, for each `work` entry that is not active-tail, not hidden by a fold, and not a compaction:

1. Standalone `work` row (never grouped): entry in a failed run, or `itemType=="error"` and status `failed`, or `tone=="error"`, or `sourceActivityKind=="runtime.error"`, or `itemType` in `{system_notice, notification}`. `groupedEntries=[entry]`, `isExpandedToolGroup=false` (`L:1597-1608`).
2. Otherwise greedy-group the following entries while the next entry is also `work` and is none of: compaction, error tone, `runtime.error`, system_notice, notification, in the active tail, hidden by a fold, an anchor of a fold; and has the same `runId` (null equals null) and the same `attempt.id` (`L:1610-1633`).
3. Filter the group with `workEntryIsVisibleInGroup(entry, workEntryIsInActiveRun(entry))` (`L:274-286`): reasoning is visible only when its `detail.trim()` is non-empty; otherwise visible when (expanded-tool-group flag and the entry is `inProgress` or `task.progress`) or status is `stopped` or the entry is NOT "neutral". Neutral = tool-like and neither success nor failure (`S:212-218`), which hides entries that are `idle`, `inProgress` outside an active run, or empty. Empty visible list: nothing is pushed, cursor still advances.
4. If any visible entry is in an active run (`input.isWorking && status=="inProgress" && runId==unsettledRunId`, runless uses `runlessWorkActive`; `L:1405-1408`): push `work-live` (`entry` = the last active one, `active:true`, `id work-live:<firstId>`), plus the expanded `work` body if `expandedWorkGroupIds` has the group (`L:1637-1660`).
5. Else if exactly one visible entry and `workLogEntryIsToolLike(entry)` (`S:176-184`: `tone` in tool/thinking/error, or has `command`, or `requestKind`): push a `work` row with `displayLabel = toolGroupAction(entry)=="edit" ? summarizeToolGroup([entry]).summary : singleToolCallLabel(entry)` (`L:94-104`, `L:1672-1685`).
6. Else push a `work-toggle` (`L:1686-1738`). `hiddenCount=visible.length`. `summary`: if one tool-like non-edit entry, `singleToolCallLabel`; if one non-tool-like entry, its `label`; else `summarizeToolGroup(visible).summary` (section 3.4). `summaryKind = toolGroupSummaryKind(visible)`. `hasFailure = workEntryDisplayIndicatesToolFailure(last tool-like entry)`. Icon fields: `toolSource` of the first sourced entry picks surface and icon, otherwise the last entry that has them. `summaryToolIcon` is the T3 MCP icon of a lone tool. If `expandedWorkGroupIds` has `groupId`, push `<groupId>:details` with the visible entries.

### 2.6 Live tail (only while `isWorking`)

`L:1412-1523`.

- `activeTurnHeaderIndex = lastResponseBoundaryIndex + 1` (the entry after the last real user prompt or notification), else `entries.length` when not working. A `working` row is inserted just before that entry (`L:1520-1523`), or appended at the end if no row was placed (`L:1896-1898`). `createdAt = activeTurnStartedAt`.
- Active tail entries: walk backwards from the end to `activeTurnHeaderIndex`; take contiguous `work` entries until one is error-toned, `runtime.error`, system_notice, notification, compaction, not in an active response run, hidden by any fold, or a fold anchor. All tail entries must share the first-seen `attempt.id` (`L:1420-1447`).
- `visibleActiveToolEntries` = tail filtered by `workEntryIsVisibleInGroup(e, true)`. `latestVisibleToolEntry` = last. `latestRunningToolEntry` = last with `workEntryIsActiveTurnActivity` (`inProgress`, or no lifecycle and (`task.progress` or tool-like); `L:86-92`). `latestToolKeepsActivityLive = running exists || latest visible indicates success`. `latestToolFailed = no running && latest visible is failure && status != declined`.
- If tail exists and not `latestToolFailed`: one `work-live` row placed where the last visible tail entry sits (`activeWorkPlacementEntryId`), `id` is the constant `live-activity-row` when `latestToolKeepsActivityLive` (the row survives across tools without remounting, issue 8984 comment, `L:1416-1419`), else `work-live:<anchorId>`. `entry` = running tool or latest visible. `thought` = last tail reasoning with non-empty detail. `active = latestToolKeepsActivityLive`. All tail entries are skipped in the main loop (`activeWorkEntryIds`).
- A `thinking` row is appended at the end when `isWorking && !hasActiveCompaction && (!hasActivityRow || latestToolFailed)`. When the latest tool failed, the `thinking` row carries the tail's `groupId`/`expanded` so the group stays reachable (`L:1896-1937`).

### 2.7 Folds

**Turn fold** (`deriveTurnFolds`, `L:961-1138`). Produces "Worked for X" headers.

1. Group entries by fold run id (`timelineEntryFoldRunId`, `L:862-878`): assistant message runId, `work` runId (system_notice excluded), `event` that is a persistent resource card or a `subagent` (runId). Entries with no runId borrow a synthetic key `runless:<boundaryEntryId>` set by the most recent response boundary (`L:1013-1022`). User messages, plans and html/mcp rows are never members.
2. Each group records `startBoundary` (the `createdAt` of the user message/notification that preceded it, consumed once) and `anchorEntryId` (the entry right after that boundary, else the group's first entry) (`L:996-1036`).
3. Skip the group (no fold) when: run is in `unfoldedRunIds` (= active visual response runs plus failed runs), or the run has an interrupt request/result item, or runless group with a failed item, or `runlessWorkActive` for the current runless key, or any message in the group is still `streaming` (`L:1052-1062`).
4. `hiddenEntryIds`: every entry of the group except the terminal assistant message. Entries after the terminal message stay visible unless they are foldable trailing activity (`work`, not `inProgress`, not a display failure). Compactions always hide. Never hidden: persistent resource cards, live subagent cards (`liveSubagentCardEntryIds`, `L:832-860`: a run of adjacent `subagent` events from one run+providerTurn stays visible while any member `isLiveSubagentTurnItem`, i.e. status is active), and `notification` work entries (`L:1063-1090`).
5. No fold when nothing hides, or when everything hidden is a compaction (a lone compaction stays as its own row) (`L:1091-1108`).
6. Label (`L:1110-1135`): `elapsedMs` = `latestRun.completedAt - latestRun.startedAt` if the group is the latest run and both exist; else `end - (startBoundary ?? firstEntry.createdAt)` where `end = max(terminalMessage.updatedAt, lastEntryEnd)` and `lastEntryEnd = message.updatedAt` for messages, `createdAt` for others. Label is `You stopped after <dur>` / `You stopped this response` for the latest run with status `interrupted`, otherwise `Worked for <dur>` or `Worked` when timing is unknown. `<dur>` = `formatDuration` (4.1).
7. Fold row is emitted when the main loop reaches its anchor entry, before that entry (`L:1538-1550`). Hidden entries are skipped (`collapsedEntryIds`) unless `expandedRunIds` has the run. Default: collapsed. The fold row id is `turn-fold:<runId>`; for runless turns, `runId` is the synthetic `runless:<id>`.

**Attempt fold** (`deriveSupersededAttemptFolds`, `L:759-806`). Hides every entry whose `attempt.status=="superseded"` except: user messages, html/mcp rows, persistent resource cards, live subagent cards, and system_notice work entries; runs listed in `unfoldedRunIds` (failed runs) are exempt. One fold per attempt, anchored on its first hidden entry. Default collapsed; `expandedAttemptIds` opens it. Label constant `"Superseded attempt"`.

**Order in the loop** (`L:1518-1606`): working row, live row, drop `run_interrupt_request`, turn-fold row, skip if turn-collapsed, attempt-fold row, skip if attempt-collapsed, skip if active tail, then kind-specific emit.

**Post pass 1: `attachCreatedThreadSummaries`** (`L:1958-2004`). For each run with a terminal assistant row (the one with `showAssistantMeta`), its `thread_created` items are removed from where they sit when that run's fold is collapsed or they come after the terminal message, and re-emitted right after the terminal message as `event` rows with `id "summary:<id>"`, `resourceSummary:true`.

**Post pass 2: `attachTrailingToolGroupsToAssistant`** (`L:1151-1244`). For each assistant message row with `showAssistantMeta` and a runId, scan the following rows until the next `message` row. Rows that count as trailing tool groups: `work-toggle` of the same run, `event` with `resourceSummary` of the same run, `work` rows containing an entry of that run (counts only if the row is not an expanded body and some entry is tool-like or a failed error). If any exist, the message row gets `showAssistantMeta=false, showAssistantCopyButton=false` and an `assistant-meta` row (id `assistant-meta:<messageId>`, `createdAt` = last trailing row's) is inserted after the last trailing row. So the footer sits below the tool cards that trail the final prose.

### 2.8 Other helpers on message rows

- `turnDiffSummaryByAssistantMessageId`: map `assistantMessageId -> TurnDiffSummary` for the "Changed files" card under an assistant message (`L:1347-1353`, section 5).
- `revertTurnCount` for a user row: only when `supportsConversationRollback`. `deriveRevertTurnCountByUserMessageId` (`S:1045-1067`): for user messages with `inputIntent` in `turn_start` or `queued_turn` and a non-null runId whose run has a checkpoint summary with status `ready`: `max(0, checkpointTurnCount - 1)`. Skip for read-only.
- `shouldCollapseUserMessage(text)` (`L:2301-2311`): strip markdown link syntax to its label (`!?[label](url)` becomes `label`) and replace assistant citations by their label, then collapse when trimmed text is non-empty and (`length > 600` or `split("\n").length > 8`). Constants `L:2286-2288`.
- `resolveAssistantMessageCopyState` (`L:695-710`): `visible = showCopyButton && text.trim() non-empty && !streaming`; copied text is `renderCodexDirectivesForCopy(text)` when visible.
- Row stability (`computeStableMessagesTimelineRows`, `L:2147-2166`, `isRowUnchanged` `L:2168-2284`): rows are matched by `id`; a row keeps its previous object when shallow-equal. In Swift, diff by `id` and use `Equatable` rows. `replaceStreamingMessageRows` (`L:2056-2133`) is a fast path for text-only streaming updates: when only message texts changed, replace `message`/`projectedItem` in place instead of re-deriving. A Swift port can skip it and re-derive (fine below a few thousand entries, memoize on the entries array identity).

Two pure passes, both ordinary functions of immutable inputs. A Swift port is two functions.

1. `deriveTimelineEntriesFromVisibleTurnItems(input)` (`S:592-809`) turns `projection.visibleTurnItems` into `TimelineEntry[]`. Same order as the server's `visibleTurnItems`, no re-sorting (`S:581-586` comment).
2. `deriveMessagesTimelineRows(input)` (`L:1326-1996`) turns entries plus run state into `MessagesTimelineRow[]`. This is where folds, grouping and the live rows happen.

Inputs of pass 1 (`TimelineEntriesInput`, `S:577-585`): `visibleTurnItems`, `optimisticMessages` (composer, skip), `anchoredMessages` (client-owned, skip), `attachmentUrlById` (image previews), `attempts`, `nodes`, `plans` from the projection.

Inputs of pass 2 (`L:1326-1346`): `timelineEntries`, `latestRun` (`{runId,status,startedAt,completedAt}` from the shell's run summary, `L:507-510`), `runningRunId`, `expandedRunIds`, `expandedAttemptIds`, `expandedWorkGroupIds` (UI state, all default empty so everything starts collapsed), `isWorking`, `runlessWorkActive`, `activeTurnStartedAt`, `turnDiffSummaries`, `supportsConversationRollback`, `liveAgentTaskIds` (unused in the body I read), `worktreeSetup`. A read-only view of a settled thread passes `isWorking=false`, `runningRunId=null`, `runlessWorkActive=false`, `worktreeSetup=null`, `supportsConversationRollback=false`. Then every live branch below is dead and only message, work, work-toggle, turn-fold, attempt-fold, context-compaction, event, proposed-plan, assistant-meta remain. Keep the live branches if the thread can be open while a run is going (it can: the stream keeps applying events).

## 3. Work log entries

Abbreviations added: `P` = `packages/client-runtime/src/work-log/presentation.ts`, `D` = `packages/client-runtime/src/work-log/itemDetail.ts`, `C` = `packages/client-runtime/src/work-log/commandLabel.ts`, `T` = `apps/web/src/components/chat/MessagesTimeline.tsx`, `V` = `apps/web/src/components/chat/V2ItemInspector.tsx`, `LR` = `apps/web/src/components/chat/V2LifecycleRow.tsx`, `TA` = `packages/shared/src/toolActivity.ts`, `TO` = `packages/shared/src/toolOutput.ts`.

### 3.0 The WorkLogEntry record

`WorkLogEntry` (`S:68-95`) is the flat record every `work` row, group and live row works from. A Swift port should keep it as one struct and keep `structuredPayload` (the full `TurnItem`) next to it, because the label and icon code reads both.

Fields: `id`, `createdAt`, `runId?`, `label`, `detail?`, `command?`, `rawCommand?`, `changedFiles?`, `tone` (`thinking|tool|info|error`), `toolTitle?`, `toolCallId?`, `viewedImagePath?`, `toolSurface?` (`browser|computer`), `toolIcon?`, `toolSource?`, `sourceActivityKind?` (`context-compaction`, `runtime.warning`, `runtime.error`, `task.progress`), `taskId?`, `toolData?` (untyped), `requestKind?`, `itemType?` (the turn item `type`), `toolLifecycleStatus?`, `structuredPayload?`, `projectedItem?`, `questionAnswer?`.

`projectedWorkEntry` (`S:430-567`) fills it. Common fields for every item: `id=item.id`, `createdAt`, `runId`, `tone` (below), `itemType=item.type`, `toolLifecycleStatus`, `structuredPayload=item`, `projectedItem=row`, and `viewedImagePath/toolSurface/toolIcon/toolSource` copied from the item by `extractToolActivityPresentation` (`CR/work-log/toolPresentation.ts:110-131`; values are validated: surface only `browser|computer`, URLs only http(s)/data, `viewedImagePath` only a single-line workspace image path).

Status mapping `projectedWorkEntryStatus` (`S:355-373`): `pending|running|waiting` becomes `inProgress`; `completed` stays; `idle` stays; `failed` stays; `cancelled|interrupted` becomes `stopped`. (`declined` is never produced for projected items; it is only reachable if the type is widened.)

Tone `projectedWorkEntryTone` (`S:375-393`): `error` item gives `info`; `reasoning` gives `thinking`; `command_execution, file_change, file_search, web_search, dynamic_tool, subagent, thread_created, user_input_request, approval_request` give `tool`; everything else `info`.

### 3.1 Per item type: label, detail, flags

All labels use `title = item.title?.trim() || null` first. Cite is `S:` line range inside `projectedWorkEntry`.

| Item type | `label` | Other fields set | Cite |
| --- | --- | --- | --- |
| `thread_created` | `"Created thread"` | | `S:446-450` |
| `compaction` | `contextCompactionLabel(item)`; `sourceActivityKind="context-compaction"`; `detail=summary` | | `S:451-457`, `P:52-62` |
| `reasoning` | `title ?? "Thinking"`; `detail=item.text` if non-empty | | `S:458-463` |
| `command_execution` | `title ?? "Ran command"` | `command=rawCommand=item.input`, `toolTitle=title ?? "Command"`, `toolData=item` | `S:464-472` |
| `file_change` | `title ?? ("Changed N files" if changes.length>1 else "Changed <fileName>")` | `changedFiles = changes.map(path) ?? [fileName]`, `toolTitle=title ?? "File change"`, `toolData=item` | `S:473-485` |
| `file_search` | `title ?? formatSearchToolLabel(item) ?? "Searched files"`; `detail=pattern` | `toolTitle=title ?? "File search"` | `S:486-493` |
| `web_search` | `title ?? "Searched the web"`; `detail=patterns.join(", ")` | `toolTitle=title ?? "Web search"` | `S:494-501` |
| `checkpoint` | (not reached; skipped in pass 1) | | `S:502-508` |
| `system_notice` | `item.message`; `sourceActivityKind="runtime.warning"` | | `S:509-514` |
| `error` | `providerErrorPresentation` (below); `sourceActivityKind`: `runtime.warning` if `failure.class=="usage_limit"` and status != completed; `runtime.error` if no `retry`; none if retrying | `toolData=item` | `S:515-527`, `S:394-428` |
| `dynamic_tool` | `title ?? (read-class: formatReadToolLabel(firstPath) \| search-class: formatSearchToolLabel({input}) ?? toolName ?? "Tool call" \| toolName ?? "Tool call")` | `toolTitle=title ?? toolName ?? "Tool"`, `toolData={input, output}` | `S:528-546` |
| `approval_request` | `title ?? "Approval requested"`; `detail=prompt ?? requestKind` | `toolData=item` | `S:547-553` |
| `user_input_request` | `title ?? (questionAnswer ? "Answered questions" : "Input requested")` | `questionAnswer`, `toolData=item` | `S:554-560` |
| `notification` (built in pass 1) | `item.summary` | `tone=info`, no lifecycle status | `S:636-653` |
| default | `title ?? type.replaceAll("_"," ")` | `toolData=item` | `S:561-566` |

`providerErrorPresentation` (`S:394-428`): no `retry`: label `"Usage limit reached"` if `failure.class=="usage_limit"`, else `title.trim() || "Provider error"`; detail `failure.message`. With `retry`: `progress = maxAttempts==null ? "<attempt>" : "<attempt>/<max>"`. Label by status: `running` `"Retrying provider (<progress>)"`, `completed` `"Provider recovered (<progress> retries)"`, `failed` `"<Usage limit reached|Provider error> after <progress> retries"`, else `"Provider retry stopped (<progress>)"`. Detail is `failure.message` plus, only while `running` with `retryDelayMs>0`, `" Retrying in <n>ms."` (under 1000) or `" Retrying in <x.y>s."` (one decimal, trailing `.0` stripped).

`dynamic_tool` read-class and search-class come from `classifyToolActivity({itemType:"dynamic_tool_call", data:{toolName, input}})` (`TA:229-304`): first match wins in this order: itemType command_execution/image_view/file_change/web_search; `requestKind=="command"` or `kind=="execute"` gives command; `requestKind=="file-change"` or `kind` in edit/move/delete/write gives file_change; `kind=="search"` or toolName token in `find, grep, glob, rg, ls` gives search; `requestKind=="file-read"` or `kind=="read"` gives read; token `terminal|bash|shell` gives command; token `read|readfile` gives read; else other. `toolNameToken` lowercases, strips `_`, `-` and spaces, and returns nothing for names containing `__`, `.` or `/` (server-prefixed MCP names are never local tools) (`TA:220-227`).

`collectToolFilePaths` (`TA:121-165`): depth up to 4, max 8 paths, scans keys `path, filePath, file_path, relativePath, filename, fileName, newPath, oldPath` (trimmed non-empty, deduped), then recurses into `locations, item, input, result, rawInput, data, changes`, and arrays. `formatSearchToolLabel(data)` (`TA:340-364`): input record is the first of `data.rawInput, data.input, data.item.input` that has keys, else `data`; `query` = first of `pattern, query, searchTerm, regex, grep, needle`; `glob` = first of `glob, globPattern, glob_pattern, include, filePattern, file_pattern`; `target` = last non-empty, non-`.` path component of the first of `path, target_directory, targetDirectory, directory, cwd, root`. Result: `Searched <query> in <target>`, `Searched files <glob> in <target>`, `Searched files <glob>`, `Searched <query>`, `Searched in <target>`, else none. `formatReadToolLabel(path, extra)` (`TA:366-374`): `"Read <path>"` or `"Read file"` when empty, plus `" +<extra> more"`.

### 3.2 Row label: `workEntryDisplayLabel(entry, workspaceRoot)` (`L:131-180`)

First match wins:

1. `itemType=="system_notice"`: `entry.label`.
2. `itemType=="reasoning"` or `tone=="thinking"`: `detail` trimmed with whitespace runs collapsed to one space, else `label`.
3. T3 MCP tool (3.9): its `displayName` (status aware, e.g. `Read a T3 thread`).
4. `command` non-empty: `commandDisplayText(command)` (3.5).
5. `toolGroupAction(entry)` is `code-search` or `search`: for `file_search`, `entry.label`; else `formatSearchToolLabel(toolData)`; use it when non-empty.
6. action `read`: take `workEntryReadPaths` (changedFiles, else `collectToolFilePaths(dynamic_tool.input)`, else `collectToolFilePaths(toolData)`; each through `formatWorkspaceRelativePath`) and return `formatReadToolLabel(first, count-1)` when there is one (`L:106-129`).
7. `dynamicToolTitle(toolName, input)`: `cua_repl.js` gives `input.title`; Claude `Skill` gives `"Skill: <name>"` (`TA:32-39`).
8. `detail.trim()` when non-empty, not a provider retry error, action is not `read`, and not a multi-line search output.
9. `changedFiles`: first path relative to workspace root; `"<path> +<n-1> more"` when more than one.
10. action `read` with no `viewedImagePath`: `"Read file"`.
11. `normalizeCompactToolLabel(toolTitle || label)` (drops a trailing "complete"/"completed", `P:113-115`) with the first character uppercased.

`formatWorkspaceRelativePath(path, root)` (`apps/web/src/filePathDisplay.ts:19-55`): split off a `:line:col` suffix, normalize `\` to `/`, strip a `/C:/` style prefix. With a root: path equal to root gives the root's basename; path under root gives `<rootBasename>/<relative>`; a relative path gets `<rootBasename>/` prepended unless it already starts with it; other absolute paths stay absolute. Without a root the normalized path is returned. Where the web app gets `workspaceRoot` is in section 1.

`singleToolCallLabel(entry)` (`L:94-104`), used for a lone settled tool row and group toggles: reasoning gives collapsed `detail` or `"Thought"`; T3 tool presentation `displayName` (status forced to `completed`); `dynamicToolTitle`; `web_search` gives `toolTitle ?? "Web search"` (query stays in detail); else `workEntryDisplayLabel(entry, undefined)`.

`liveWorkEntryLabel(entry, root, active)` (`L:240-272`) for the live row: status = `liveActivityToolStatus(entry.status, active)` (`P:190-196`: failed/declined/stopped/idle stay, otherwise `inProgress` if `active` or already in progress, else `completed`). Reasoning: collapsed detail or `Thinking`/`Thought`. T3 tool: its present or past tense name. Commands: `<Running|Failed|Declined|Stopped|Ran> <programName or "command">` where programName is `commandProgramName(command)` (the first real program after wrappers, `C:1367`). Anything else: `workEntryDisplayLabel`.

### 3.3 Icons (lucide names)

`workEntryIconName(entry)` (`T:5267-5303`), first match wins, result is the lucide icon name:

1. `notification`: outcome `failed` gives `circle-alert`; `source.kind` `subagent` or `delegated_task` gives `bot`; `command` gives `terminal`; `monitor` gives `eye`; `background_task` gives `zap`.
2. `user_input_request`, `approval_request`: `message-circle`.
3. `toolSurface` (`browser` or `computer`): app-icon art for browser/computer-use (not lucide).
4. T3 MCP tool presentation: its `icon` (`t3-code` wordmark, `browser`, `device` = `smartphone`, `pull-request` glyph).
5. `toolGroupAction(entry)` other than `other`: `read` `eye`; `edit` `square-pen`; `command` `terminal`; `thread-create` `t3-code`; `browser`; `device` `smartphone`; `search` `globe`; `code-search` `search`; `update` `hammer`; any pr action `pull-request` (`T:4051-4092`).
6. `dynamic_tool`: `wrench`. `subagent`: `bot`.
7. Tone: `error` `circle-alert`, `thinking` `brain`, `info` `check`, `tool` `zap` (`T:5170-5196`).

Overrides in `WorkEntryLogRow` (`T:5384-5779`): `sourceActivityKind=="runtime.warning"` or (display failure and (`itemType=="error"` or entry is not tool-like)) forces `circle-alert` (warning colour or destructive colour). A `toolIcon`/`toolSource.icon` image (website favicon, native app, themed logo) replaces the lucide icon. A failed ordinary tool keeps its icon tinted at 40 percent and adds a trailing `x` icon (size 12) unless the icon is an image that takes a tint. A failed `error` item renders a separate row: `circle-alert`, text `Usage limit reached. Retry after <time>.` (class `usage_limit`, warning colour; `<time>` = `formatUpcomingTimestamp(resetAt)`) or `entry.label` in destructive colour, with `failure.message` underneath (`T:5413-5471`).

Group-header icons (`work-toggle`): `summaryToolIcon ?? toolSurface ?? toolGroupSummaryIconName(summaryKind)` with kind mapping in `T:4051-4092`: pull-request kinds `pull-request`; `read` `eye`; `edit` `square-pen`; `command` `terminal`; `thread-create` `t3-code`; `browser`, `device`; `search` `globe`; `code-search` `search`; `other` `wrench`; `dynamic-tool` `hammer`; `reasoning` `brain`; `agent-tool` `bot`; `tone-tool` `zap`; `update`, `mixed` `hammer`. Live `thinking` row: `brain`, label `Thinking`. Context compaction row: `minimize-2` (size 12) with the label between two hairlines (`T:2111-2144`). Event rows: error `circle-alert`; interrupt result `x`; handoff `arrow-right-left`; fork `git-fork`; compaction `minus`; created thread `t3-code` wordmark (inline) or `message-square` (summary card); subagent avatar (provider glyph). User steer marker `redo-2`.

### 3.4 Group summary text: `summarizeToolGroup` and `toolGroupAction`

`toolGroupAction(entry)` (`P:428-476`), first match wins: `thread_created` `thread-create`; T3 tool action (`link-pr, unlink-pr, list-prs, watch-pr, unwatch-pr`) ; T3 icon `browser` or `device`; `requestKind=="file-read"` or `viewedImagePath` `read`; approval/user input request: `other` if tool-like (presentation version, see 3.6) else `update`; then `classifyToolActivity` with `itemType` passed only for `command_execution, file_change, web_search` (`dynamic_tool` becomes `dynamic_tool_call`), `title = toolTitle ?? label`, `data = {...toolData, toolName}`; result `read` gives `read`; `file_change` or itemType `file_change` gives `edit`; `command` or itemType `command_execution` or has `command` gives `command`; `search` gives `search` for web search and `code-search` otherwise (local code search = itemType `file_search`, or `web_search` whose title matches `/\bgrep\b/i`); then `file_search` gives `code-search`; `web_search` gives `search`; `changedFiles` non-empty gives `edit`; else `other` if tool-like else `update`.

`summarizeToolGroup(entries)` (`P:645-729`):

1. Remove `reasoning` entries. If entries existed but only reasoning: `"Thought"` for one, `"Thought (×N)"` for several.
2. Bucket the rest by key `t3Action ?? toolGroupAction(entry)`. Entries with a `toolSource` and no T3 action go to a `sources` map instead (keyed by `source.key`).
3. Each bucket gets a label. Non-T3: `toolGroupActionLabel(action, count)` (`P:543-585`): `Linked N pull request(s)`, `Unlinked ...`, `Watching ...`, `Stopped watching ...`, `Checked linked pull requests` (or `... N times`), `Read N file(s)`, `Changed N file(s)`, `Ran N command(s)`, `Created N thread(s)`, `Used device controls N time(s)`, `Used browser N time(s)`, `Searched the web N time(s)`, `Searched code N time(s)`, `Used N tool(s)`, `Received N update(s)`. For `edit`, N counts distinct `changedFiles` plus edits with no file list. T3 buckets use `summarizeT3ToolCalls` (`packages/client-runtime/src/t3ToolSummary.ts`, not read; skip unless T3 tool threads matter).
4. Order buckets by priority then first appearance, keep two, restore appearance order. Priority 0 is `command, edit, delegate, thread/schedule/queue/project mutators` etc. (`P:603-643`); `other` and `update` are 2; the rest 1 (`P:603-643`).
5. If sources exist: prepend `Used <A>`, `Used <A and B>` or `Used <A, B, and C>`, with the suffix ` integration(s)` when all sources are integrations.
6. `remaining = entries - sourced - sum(selected counts)`; if above 0 append `Performed N other action(s)`.
7. Join: lowercase the first letter of every label after the first; two labels joined with ` and `, three or more as `a, b, and c` (`P:719-729`).

`toolGroupSummaryKind(entries)` (`P:731-761`): `reasoning` if all entries are reasoning; `pull-request` if all have T3 icon `pull-request`; `mixed` if the set of `toolGroupAction` values has more than one member; otherwise the single action unless it is `other`, where it falls back per entry (`dynamic_tool` `dynamic-tool`, `subagent` or tone thinking `agent-tool`, tone tool `tone-tool`, else `other`), `mixed` if those differ.

### 3.5 Shell command display

`commandDisplayText(command)` (`C:1381-1384`) = `withVisibleControlCharacters(withoutShellWrapper(command))`. Control characters in `U+0000-0008, 000B, 000C, 000E-001F, 007F` become U+2400+code (`U+007F` becomes `U+2421`); tab, LF, CR stay (`C:1375-1393`).

`withoutShellWrapper` (`C:1395-1409`): trim. If the command has more than one top-level statement (`splitFirstShellCommand(...).remainingCommand != null`) return it trimmed unchanged. Tokenize with `tokenizeShellCommand` (`C:225-378`, POSIX-ish quoting with `'`, `"`, backslash, `$()`, backticks; returns nil on unbalanced quotes). The first token's basename (split on `/` or `\`, strip `.exe`) must be in `{sh, bash, zsh, dash, ash, ksh, fish}`. `shellCommandArgumentIndex` (`C:202-213`) scans options after the program: stop (nil) at `--` or the first non-dash token; skip the value after `-o, -O, --rcfile, --init-file`; the option `--command` or any `-[a-zA-Z]*c[a-zA-Z]*` (for example `-c`, `-lc`) returns the next index. The script token must be the LAST token, otherwise (positional arguments) the original is kept. Result is the script token trimmed (the unquoted text), or the original if empty.

Pinned cases (`packages/client-runtime/src/work-log/commandLabel.test.ts:485-567`): `/bin/zsh -lc 'git diff --stat'` gives `git diff --stat`; `bash -c "printf \"%s\" hello; git status"` gives `printf "%s" hello; git status`; `/usr/bin/fish --command 'rg TODO src | head -20'` gives `rg TODO src | head -20`; `zsh -lc 'pwd\nls'` gives `pwd\nls`; `git status`, `zsh script.sh`, `zsh -lc 'echo $1' name value`, `zsh -lc 'pwd'; git status`, `zsh -lc 'unterminated` stay as they are; Codex `/bin/zsh -lc 'curl -H "Authorization: Bearer [REDACTED_SECRET]" https://example.com'` unwraps; a broken-quote redaction case stays wrapped; control chars: ESC becomes `␛`, BEL `␇`, DEL `␡`, tabs and CRLF unchanged. A Swift port can implement a small tokenizer for these cases and fall back to the raw command otherwise. The full `commandProgramName` (`C:1073-1373`, about 1300 lines of PowerShell, sudo, env, heredoc and alias handling) is only needed for the live row verb; skip it in M4 and show `Running command`.

### 3.6 Status and failure display

- `workLogEntryIsToolLike` has two versions. The one the timeline uses is `S:176-184`: tone is `tool`, `thinking` or `error`, or `command` is set, or `requestKind` is set. The one inside `P:356-362` (used by `toolGroupAction`, `workEntryIndicatesToolFailure`) additionally accepts `itemType` in the provider lifecycle set `command_execution, file_change, mcp_tool_call, dynamic_tool_call, collab_agent_tool_call, web_search, image_view` (`packages/contracts/src/providerRuntime.ts:106-121`). A turn item `dynamic_tool` never matches that set, which is harmless because its tone is already `tool`.
- `workEntryIndicatesToolFailureFromOutput(entry, includeCommand)` (`P:363-398`): true if tone `error`, or status `failed` or `declined`; false if not tool-like; true if a T3 tool whose output says failure (`t3ToolResultIndicatesFailure`); for `command_execution`: `outputIndicatesFailure`, or `exitCode != nil && exitCode != 0`, or `toolOutputIndicatesFailure` of the first 32768 characters of `output`; finally `toolOutputIndicatesFailure(detail [+ command])`. `workEntryDisplayIndicatesToolFailure` passes `includeCommand=false` (the command text never counts as an error).
- `toolOutputIndicatesFailure(text)` (`TO:211-224`) is a regex set: `file not found|no files found|enoent|no such file|commandnotfoundexception|command not found|is not recognized as the name of a cmdlet|a parameter cannot be found that matches parameter name`; `cannot find path` together with `because it does not exist`; `is not recognized` together with `the term '`; `<exited with exit code N>`, `exit(ed) with exit code N`, `exit code[: ]N` for N from 1 to 9 followed by digits. All case-insensitive.
- Success, neutral (`S:189-218`): success = tool-like, not failure, not (tone thinking and not reasoning), and status not in `failed, declined, inProgress, stopped, idle`. Neutral = tool-like and neither success nor failure. Neutral entries are hidden inside groups (2.5 step 3), except `stopped`.
- Row look: `showFailedIndicator` = display failure and not a warning. `showDestructiveRowStyle` = failed and (itemType `error`, or not tool-like). Ordinary tool failure: the icon tint at 40 percent plus a trailing `x`. Aria label `<text>, tool call failed`.

### 3.7 What expands, and what it shows

Rows are collapsed by default, one disclosure each (`T:5384-5779`). A row offers the chevron only if `canExpandProjectedItem` (`T:5512-5566`):

- reads and Claude `Skill` calls ("plain output"): text block. For a read, `workEntryReadOutput` (`L:212-238`) = the unique absolute paths, one per line (relative paths are joined to the workspace root). For a skill, its `args` string.
- projected items otherwise: `turnItemHasDetail(item)` (`D:227-268`): `reasoning` text non-empty; `command_execution` has a command, or `outputOmitted`, or output, or non-zero exit; `file_change`, `checkpoint`, `fork`, `handoff` always; `file_search` has results or pattern; `web_search` has results or patterns; `dynamic_tool` `outputOmitted` or input renders to lines; `approval_request` prompt; `user_input_request` has questions; `notification` detail; `system_notice` message; `error` failure message; `proposed_plan` markdown; `todo_list` steps; `subagent` has `childThreadId`.
- reasoning rows expand to the full markdown in an italic bordered box (`V:233-246`) and the collapsed label is the first sentence/heading via `remarkThoughtPreview` (`T:5307-5327`); expanded label is `Thinking`/`Thought`.
- an image viewed by a tool (`viewedImagePath`) expands to the image (max height 16rem).
- `user_input_request` with `questionAnswer`: the collapsed row is `<question text joined with " · "> <answer preview>` (`CR/work-log/userInput.ts:15-43`); expanding shows `QuestionAnswerHistory` (`T:5779`).

Item inspector body (`V:222-424`), by `item.type`:

- `command_execution`: the full command in a shell block (`toolCallLines({command})`: trimmed `input`), then the output text (below), then a red `exit <code>` line when `exitCode != 0` (`V:192-220`).
- `dynamic_tool`: the input as `key value` lines when it is a flat object (strings raw, everything else `JSON.stringify`; empty strings and null are kept), else formatted text or indented JSON; then output text. A summarized input (`{summary, truncated:true}`) is not shown as args.
- `file_change`: path (workspace relative), `+additions -deletions` if either exists, an "Open diff" button if `runId != nil` (diffs, section 5), the failed `diffStr` if status failed, then one line per change `<operation> <oldPath -> >path (<fileType, mimeType>)`.
- `file_search`: the pattern, then `fileName[:line[:column]]` with the preview text below.
- `web_search`: patterns joined by newline, then results as link (title or url) plus snippet. Only `http(s)` links are clickable.
- `approval_request` prompt; `user_input_request` question texts joined by a blank line; `notification` detail; `system_notice` message; `error` failure message; `proposed_plan` markdown; `todo_list` `"✓ text"` or `"○ text"` per step.
- `checkpoint`: `<status> · N files`. `fork`: Open fork button. `subagent`: Open subagent thread. `handoff`: `from -> to`, strategy with underscores replaced, status.

Output text (`D:152-209`): `turnItemOutputText(item)`: `command_execution` gives `output` unless it is the legacy JSON `{"stdout":..,"stderr":..,"interrupted":..}` (then stdout and stderr joined); `dynamic_tool` gives `formatToolValue(output)` (text blocks `{type:"text"}`, `resource_link`, `resource`, MCP `{content:[...]}`, joined by newline, minified JSON text pretty-printed; else indented JSON; `{}`/`[]` give none); `file_search` results as `file[:line]\npreview`; `web_search` results as `title\nurl\nsnippet`.

Fetch-on-expand: the bounded projection withholds big bodies. `turnItemNeedsDetailFetch` (`D:140-149`): `command_execution` with `outputOmitted==true`; `dynamic_tool` with `outputOmitted==true` or a summarized input. For those the client calls `orchestration.getTurnItem {threadId: projectedItem.sourceThreadId, itemId: projectedItem.sourceItemId, revision}` (`V:103-148`), uses the returned item when its `type` matches, and shows "Output is no longer available." when `item` is null (cache key `turnItemDetailRevision`, `D:135-137`: the literal `live` while status is idle/pending/running/waiting, otherwise the ISO `updatedAt`). Images come from `tool-output-image` assets by index.

### 3.8 Event rows (not `work`)

`V2EventTimelineRow` (`T:3079-3270`) and `V2LifecycleRow` (`LR:66-215`). Lifecycle types: run_interrupt_request/result, compaction, handoff, fork, subagent, thread_created (`LR:50-62`).

- `run_interrupt_result`: centered divider, `x`, label `Run interrupted`, detail `item.message`, danger tone. The request is dropped in the row pass.
- `compaction` (if rendered as an event): label `Context compaction failed|stopped|Compacting context|Context compacted`, detail `summary` or `<before ?? "?"> → <after ?? "?"> tokens`. As a `work` entry it renders as the `context-compaction` row with `contextCompactionLabel` instead: `Compacting context` while running, `Context compacted <formatTokens(before)> → <formatTokens(after)> tokens` when both counts exist, else `Context compacted` (`P:52-62`). `formatTokens` is in `packages/shared/src/usageFormat.ts` (not read).
- `handoff`: divider `Context handoff`, detail `<from endpoints> → <to endpoint>` (provider name and model).
- `fork`: divider `Forked from conversation` when `source.type=="run"` (action `Open source conversation`), else `Conversation fork` (action `Open fork`).
- `thread_created`: row `Created thread · <title>` with an `Open chat` button; the post-answer summary variant is a bordered card with `message-square`, title or `Created thread`, `Open chat`.
- `subagent`: card with avatar, title (`title ?? "Subagent"`), status label from the table `pending Queued, running Running, waiting Waiting, idle "Idle · resumable", completed Completed, failed Failed, cancelled/interrupted Stopped` (`LR:246-256`), one-line detail (result when settled else progress, falling back the other way; markdown links reduced to their text, backticks and bullets stripped, whitespace collapsed; hidden when it matches `/^Child task ended with status\b/i`), elapsed time via `deriveSubagentElapsedMs` (`packages/shared/src/orchestrationTiming.ts:4-20`). Adjacent subagent cards from one run and providerTurn are merged into one `V2SubagentGroup` (`row.subagents`, `L:1775-1800`). A `notification` whose source is a subagent or delegated task, and whose child thread exists in `projection.subagents`, renders as that subagent's card with the notification outcome label (`completed Finished, failed Failed, cancelled Stopped, updated Updated, unknown Finished`, `LR:346-352`), otherwise as a plain work row with an `Open subagent` link.
- `error` events and the fallback: `v2EventPresentation` (`T:2998-3077`): label/detail from `providerErrorPresentation`, tone `success` (completed), `warning` (running or usage limit) or `danger`; fallback label `title ?? type.replaceAll("_"," ")`, wrench icon. Rendered as a collapsible `<details>` with a status pill when status is not completed.
- `secret_request`: interactive card, skip in a read-only view (show a label).
- `proposed_plan`: card with the markdown (`ProposedPlanCard.tsx`, not read).

### 3.9 T3 MCP tools

`packages/shared/src/t3McpToolPresentation.ts` holds a table of about 80 T3 tools (`link_pull_request`, `delegate_task`, `t3_thread_read`, `preview_open`, ...) at lines 86-330. Each has `labels = [action, running, completed, detail]`, an icon, and a `summaryAction`. A tool name matches when it is the bare name, or `t3-code`/`t3_code`/`t3code` plus a separator and the tool, or `mcp__t3-code__<tool>`, or OpenCode's `t3-code-<thread>_<tool>` (`:331-369`). Label by status (`P:141-188`): inProgress `"<running> <detail>"`, completed `"<completed> <detail>"`, failed `"Failed to <action lowercased> <detail>"`, declined `"Declined to ..."`, stopped `"Stopped <running lowercased> <detail>"`, otherwise running form. For PR tools with `input.url` or `input.number` the detail becomes `PR #<n>`. Treat as data: generate a Swift table from that file; it is pure data.

## 4. Text helpers

Abbreviations added: `TS` = `apps/web/src/timestampFormat.ts`, `OT` = `packages/shared/src/orchestrationTiming.ts`.

### 4.1 `formatDuration(ms)` (turn fold label, elapsed timers)

`OT:36-52`. Used for `Worked for <x>`, `You stopped after <x>` (`L:1121-1134`) and the working timer over 60 s.

1. `ms` not finite or negative gives `"0ms"`.
2. Under 1000: `"<max(1, round(ms))>ms"`.
3. Under 10000: tenths = `round(ms/100)/10`; if tenths >= 10 then `"10s"` else `"<tenths with one decimal>s"` (so `1_500` gives `1.5s`, `9_950` gives `10s`; note `2000` gives `2.0s`).
4. Under 60000: `"<round(ms/1000)>s"`. Quirk: `59_600` gives `"60s"`, the code does not carry into minutes here.
5. Otherwise `totalSeconds = round(ms/1000)`, split into `h`, `m`, `s`, omit zero parts, join with a space: `"1m"`, `"1m 5s"`, `"1h 1m 1s"`, `"25h 1m 1s"` (hours do not roll into days).

Pinned values (`packages/shared/src/orchestrationTiming.test.ts:9-34`): 0 gives `1ms`, 250 `250ms`, 1500 `1.5s`, 9950 `10s`, 22000 `22s`, 60000 `1m`, 65000 `1m 5s`, 119500 `2m`, 3599499 `59m 59s`, 3599500 `1h`, 3601000 `1h 1s`, 3660000 `1h 1m`, 3661000 `1h 1m 1s`, 7199500 `2h`, 25190000 `6h 59m 50s`, 90061000 `25h 1m 1s`; -1, NaN, Infinity, -Infinity give `0ms`.

Elapsed inputs for the fold label: `computeElapsedMs(start, end) = max(0, parse(end) - parse(start))`, nil if either date does not parse (`L:482-488`); `maxIsoTimestamp(a, b)` returns the later one, ignoring nil or unparsable (`L:489-497`).

### 4.2 Working timer (live only)

`formatWorkingTimer(start, end)` (`T:3477-3490`): `elapsed = max(0, floor((end-start)/1000))` seconds; under 60 shows `"<n>s"`, otherwise `formatDuration(elapsed*1000)`. The `working` row text is `Working for <timer>` when it has `createdAt`, else `Working...`; the timer updates every second (`T:3496-3517`, `T:3705-3743`). Compacting shows `Compacting…` with a `minimize-2` icon, worktree setup shows `Setting up worktree…`.

### 4.3 Assistant meta row (the footer under the final answer)

`AssistantMessageMeta` (`T:2860-2912`). It contains, left to right, only:

1. A status pill with the raw status text (`running`, `failed`, ...) when the projected item status is not `completed`. Mono 10 px text, rounded border.
2. The copy button (ghost) when `resolveAssistantMessageCopyState(...).visible`. Copies the message text with Codex directives rendered (`renderCodexDirectivesForCopy`, `packages/shared/src/codexMarkdownDirectives.ts`, not read; for M4 copy the raw text).
3. A fork button for assistant items (interactive, skip in M4).
4. When the message is not streaming: `formatDayAwareTimestamp(message.updatedAt)` with the long tooltip `formatChatTimestampTooltip(message.updatedAt)`.

There is no model label, no duration, and no token count in this row. `durationStart` is computed on message rows (`L:655-672`) but nothing in `MessagesTimeline.tsx` reads it, so a port can skip `computeMessageDurationStart`. The visible duration lives only in the turn-fold label (4.1). The row fades in on hover of the message (`opacity-0` until `group-hover/assistant`, always visible for the `assistant-meta` variant and on touch). The author headings (`You`, `T3 Code`) are screen-reader-only (`T:2194-2196`).

Other message header text: automation attribution above a user bubble `Sent by automation` (user message with `scheduledTaskId`, or the legacy prefix `[Triggered by schedule task: ...]\n\n` which is stripped from the text when the message id matches `scheduled-task-message:<id>:<n>:(scheduled|manual)` or `createdBy=="agent"`; `packages/client-runtime/src/userMessage.ts:1-31`), `Sent by another agent` when `createdBy=="agent"`, and an intent marker for `inputIntent != "turn_start"`: `Queued` for `queued_turn`; `Steer` with a `redo-2` icon for `steer` and `promoted_queued_to_steer` (`T:2360-2398,2561-2604`). Tooltips: `Queued behind the active turn`, `Originally queued, then promoted to steer the active turn`, `Steered the active turn`. An empty completed assistant message shows `(empty response)` (`T:2747`).

### 4.4 Timestamps (`TS`)

All use the user setting `timestampFormat` (`locale`, `12-hour`, `24-hour`; default from settings) and the system locale. Map to `DateFormatter` / `Date.FormatStyle` in Swift.

- `formatShortTimestamp(iso)` (`TS:153-158`): hour numeric + minute 2-digit; `hour12` follows the setting (`TS:3-21`). Invalid input gives `""`.
- `formatDayAwareTimestamp(iso, now)` (`TS:175-197`): `dayDiff` = whole local calendar days between today and the message day (rounded, so DST days count as one). `<= 0` gives the time; `1` gives `yesterday at <time>`; older gives `<numeric month/day> <time>`, with the year (`month/day/year`) when the year differs. Pinned by `apps/web/src/timestampFormat.test.ts:160-221`.
- `formatChatTimestampTooltip(iso)` (`TS:140-151`): `<time>, <day><ordinal> <English month name> <year>`, for example `12:04, 4th June 2026`. Ordinals: 11 to 13 use `th`, else 1 `st`, 2 `nd`, 3 `rd`, others `th`. Month names stay English regardless of locale (`TS:106-110`). Pinned `timestampFormat.test.ts:85-102`.
- `formatUpcomingTimestamp(iso)` (`TS:202-222`): future counterpart: today the time, tomorrow `tomorrow at <time>`, later `<date> <time>`; a past instant falls back to day-aware. Used for `Usage limit reached. Retry after <time>.`
- Where timestamps show in the timeline: trailing on every work row, fold header and group header on hover/focus only (`T:2668-2697`: invisible and out of flow until `group-hover/timeline-row` or focus); always visible on failed error rows (`alwaysVisible`) and the assistant footer. Row timestamp value is the row's `createdAt` (`item.startedAt ?? item.updatedAt`).
- `formatRelativeTime(iso)` (`TS:235-247`) is not used inside the timeline. Sidebar-style rules are in B-orchestration 4.5: `<60 s` or future `just now`; then `Nm ago`, `Nh ago`, `Nd ago`.

### 4.5 User message collapsing and other text rules

- `shouldCollapseUserMessage(text)`: 2.8. A collapsed bubble clips to a fade mask (`T:4711-4712`: 1.75 rem fade) with expand control (`CollapsibleUserMessageBody`, `T:4714-4787`).
- Reasoning preview (`remarkThoughtPreview`, `T:5307-5327`) and `liveThoughtLine(markdown)` (`P:763-776`): a leading bold-only line `**Heading**` wins; otherwise strip markdown links to labels, list markers, heading hashes, backticks, bold, strikethrough, single emphasis, collapse whitespace; then cut after the first `.`, `?` or `!` (optionally followed by a closing quote or paren) that is followed by whitespace.
- `normalizeCompactToolLabel`: drop a trailing ` complete`/` completed` (case-insensitive) and trim (`P:113-115`, pinned `MessagesTimeline.logic.test.ts:586-594`).
- `formatTokens(n)` (`packages/shared/src/usageFormat.ts:32-45`): `>=1e12` `T`, `>=1e9` `B`, `>=1e6` `M`, `>=1e3` `K` with `value/scale` printed to 0 decimals when `>=100`, 1 when `>=10`, else 2, trailing `.0`/`.00` stripped; under 1000 the rounded integer with `en-US` grouping (`usageFormat.ts:18`).
- `formatCompactDiffCount(n)` for `+N -M` stats (`apps/web/src/components/chat/DiffStatLabel.tsx:6-17`): under 1000 plain; under 1e6 `k` with one decimal below 10 (`1.2k`, trailing `.0` stripped) else rounded (`12k`); then `m`, then `b` the same way. Additions green, deletions red, rendered `+N` and `-M` in mono.

## 5. Diffs

Abbreviations added: `DP` = `apps/web/src/components/DiffPanel.tsx`, `TD` = `apps/web/src/lib/turnDiffTree.ts`.

### 5.1 Per-turn data in the projection (no RPC needed for the file list)

The changed-files card under an assistant answer comes from the projection, not from `getTurnDiff`.

- `deriveThreadCheckpointSummaries(projection)` (`RT/threadCheckpoints.ts:20-52`) maps `projection.checkpoints` to `ThreadCheckpointSummary` (also exported as `TurnDiffSummary`, `apps/web/src/types.ts:118-119`). Skip checkpoints whose `appRunOrdinal` or `runId` is null. Fields: `checkpointId`, `scopeId`, `runId`, `checkpointTurnCount = appRunOrdinal`, `checkpointRef = ref`, `status` (`ready, missing, error, stale`), `files = checkpoint.files` (`{path, kind, additions, deletions}`), `assistantMessageId` = id of the last assistant message in `projection.messages` with that `runId`, `completedAt = capturedAt` as ISO.
- `checkpointTurnCount` is the app run ordinal (1 for the first run, 2 for the second ...), not an item index. A bounded projection may carry only some checkpoints; the server keeps control-plane arrays partial too (protocol.md 7.7 correction), so a missing summary just means no card.
- Row attachment: `turnDiffSummaryByAssistantMessageId` (`L:1347-1353`) sets `assistantTurnDiffSummary` on the assistant message row whose `message.id == summary.assistantMessageId`. With a final answer followed by trailing tool rows, the message row still carries it; the card renders inside the assistant message block above the meta row (`T:2767-2773`).
- `inferCheckpointTurnCountByRunId` (`S:1035-1043`): `runId -> checkpointTurnCount` for summaries with a runId. The DiffPanel uses it as a fallback when `checkpointTurnCount` is nil; with the V2 shape it is always set.
- Rendered only when `files.length > 0` (`T:4153-4167`).

### 5.2 ChangedFilesTree derivation (`TD:1-147`)

Input: `files: [{path, additions, deletions}]`. `readStat(file)` gives `{additions, deletions}` only when both are numbers, else nil.

`buildTurnDiffTree(files)`:

1. For each file, split `path` on `/` after replacing `\` with `/`, drop empty segments; skip files with no segments. `filePath` is the segments re-joined with `/`; `fileName` is the last segment.
2. Walk the directory segments from a synthetic root, creating directory nodes `{name: segment, path: joined prefix, stat: 0/0}` as needed. Push `{kind:"file", name, path: filePath, stat}` into the leaf directory.
3. If the file has a stat, add it to every ancestor directory including the root (the root's total is unused).
4. `toTreeNodes`: per directory, subdirectories first sorted by `name.localeCompare(other, undefined, {numeric: true, sensitivity: "base"})`, then files with the same sort. Each subdirectory is then compacted: while a directory has exactly one child and that child is a directory, merge into `name = "a/b"`, `path` = child's path, `stat` = child's, `children` = child's children (`TD:50-70,72-93`).

`summarizeTurnDiffStats(files)`: sum of additions and deletions over files that have a numeric stat (`TD:95-105`).

Card (`ChangedFilesTree.tsx:25-122`): header `<N> changed file(s)` (singular when 1), the `+A -D` label when either is non-zero (`hasNonZeroStat`), an expand/collapse-all-folders button when any path contains a separator (icons `chevrons-up-down` and `chevrons-down-up`, aria labels `Expand all folders` and `Collapse all folders`), and an `Open diff` button (icon `file-diff`; text hidden under 24 rem container width, tooltip `Open the full diff`). Clicking it calls `onOpenTurnDiff(runId, files[0].path)`. The header is sticky 8 px from the top. Body: tree rows (`ChangedFilesTree.tsx:124-260`), indent `8 + depth*14` px, folder rows with chevron, folder icon (`folder` / `folder-closed`), mono name and the folder's stat; file rows with a file-type icon, middle-truncated name and stat; clicking a file calls `onOpenTurnDiff(runId, node.path)`. All folders start collapsed (`allDirectoriesExpanded` defaults false, remembered per thread and run in the UI store `threadChangedFilesExpandedById[threadKey][runId]`), and per-folder toggles override until the key changes. Tests: `apps/web/src/lib/turnDiffTree.test.ts:5-170`, `apps/web/src/components/chat/ChangedFilesTree.test.tsx:7-180`.

### 5.3 What the diff panel requests

Clicking "Open diff" calls `onOpenTurnDiff(runId, filePath?)` (`CV:10907-10916`): select the turn and file in the diff panel store, open the right panel on `diff`. `DiffPanel` (`DP:258-345`):

1. `turnDiffSummaries` from the same projection; sort by `checkpointTurnCount` descending, then `completedAt` descending. The first entry is the latest turn (`DP:263-277`). The scope label is `Latest turn` for the latest, else `Turn <n>`.
2. `selectedTurn` = the summary with `runId == selection.turnId`, else the first.
3. Range: `fromTurnCount = max(0, N - 1)`, `toTurnCount = N` where `N = selectedTurn.checkpointTurnCount` (`DP:320-330`). So the panel shows exactly one run's delta.
4. `ignoreWhitespace` = user setting `diffIgnoreWhitespace` (default `true`, `packages/contracts/src/settings.ts:377`).
5. The request (`apps/web/src/state/queries.ts:343-383`): when `fromTurnCount == 0` (the first run) call `orchestration.getFullThreadDiff {threadId, toTurnCount, ignoreWhitespace}`; otherwise `orchestration.getTurnDiff {threadId, fromTurnCount, toTurnCount, ignoreWhitespace}`. Enabled only if the workspace is a git repo (`DP:331-340`). The cache key scope is `turn:<runId>`.
6. Both RPCs return `{threadId, fromTurnCount, toTurnCount, diff: string}` (`packages/contracts/src/checkpointDiff.ts:17-46`). The input requires `fromTurnCount <= toTurnCount`; `getFullThreadDiff` is the same with `from = 0`. Errors are tagged `OrchestrationGetTurnDiffError` / `OrchestrationGetFullThreadDiffError {message}` wrapping the server errors below.

Server behaviour (`apps/server/src/checkpointing/CheckpointDiffQuery.ts:78-200`): `ignoreWhitespace` defaults to `true` when omitted; `from == to` returns an empty diff string; the thread must have ready checkpoints for completed runs (`status == "ready"`, `appRunOrdinal != nil`, run `completed`); `toTurnCount` above the highest ready ordinal fails with `CheckpointTurnRangeUnavailableError` (requested and available counts); missing refs fail with `CheckpointRefUnavailableError`. For `from == 0` the base is the root scope's ordinal-0 ref. The diff is produced by `git diff --patch --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ [--ignore-all-space] <from>^{commit} <to>^{commit}` in the checkpoint scope's `cwd`, output capped at 10,000,000 bytes and truncated beyond (`apps/server/src/vcs/GitVcsDriver.ts:1158-1215`, `GitVcsDriverCore.ts:70`, `GitVcsDriver.ts:427`). Format: plain unified git patch text (`diff --git a/x b/x`, `index ...`, `--- a/x`, `+++ b/x`, `@@ ... @@`), as recorded in protocol.md 7.x (`03-turn2` t=41003). Renames are not detected (no `--find-renames`); a renamed file appears as a delete plus an add. No `--minimal`, so default hunk selection.

Client rendering (`apps/web/src/lib/diffRendering.ts:154-200`): trim the patch, parse with `@pierre/diffs` `parsePatchFiles`; no files parsed gives a raw-text fallback `Unsupported diff format. Showing raw patch.`; a throw gives `Failed to parse patch. Showing raw patch.` An empty patch string means "no net changes". A Swift port needs its own unified-diff parser: split on `diff --git`, parse headers, hunks `@@ -a,b +c,d @@`, lines by first character (` `, `+`, `-`, `\ No newline at end of file`). Per-file stats come from counting `+`/`-` lines, or from the summary's `files` array.

### 5.4 Per-item diffs and the whole-thread diff

- A `file_change` work row expands to path, `+A -D` and an `Open diff` button when `item.runId != nil`; it opens the same turn diff for that run and file (`V:256-300`, `onOpenTurnDiff(runId, fileName)`). `diffStr`, `oldStr`, `newStr` are stripped from the wire projection (protocol.md 7.7 wire projection table); only a failed edit keeps up to 32 KiB of `diffStr`, which the row shows as text (`V:276-282`). So the only path to real diff text for a succeeded edit is `getTurnDiff`.
- Whole-thread diff: `getFullThreadDiff {threadId, toTurnCount}` with `toTurnCount` the highest ready ordinal gives everything since the thread's baseline. The web panel never requests it for more than turn 1 (its range is always one turn), but the RPC is wired in the client (`RT/orchestration.ts:56`). Another source of "all changes" is the git review views (`reviewEnvironment.diffPreview`), which are cwd-based and out of scope for M4.
- `checkpoint` turn items are not rows (skipped in pass 1). Their inspector would show `<status> · N files` and a Roll back button (`V:370-390`); rollback is out of scope for M4.

## 6. Tests that pin this behavior

`LT` = `apps/web/src/components/chat/MessagesTimeline.logic.test.ts` (5227 lines, vitest, helpers at the top build entries and run `deriveMessagesTimelineRows`). Each group below is a Swift test target; the line numbers are the `describe`/`it` heads. Port the inputs as JSON fixtures where possible (the TypeScript tests build `WorkLogEntry` and `TimelineEntry` literals in-file).

### 6.1 Row derivation, `LT`

Folding and "Worked for" (`describe("deriveMessagesTimelineRows")`, `LT:667`):
- folds the first assistant message and settled work before the terminal response `:1300`; folds 1, 2, 3 completed activities that follow the terminal response `:1401`; folds all assistant messages before the terminal one `:1502`.
- duration for a steer-superseded turn with one instant commentary message `:1559`; latest-turn timings and the stopped label for an interrupted latest turn `:1668`.
- keeps the previous turn folded while a new message awaits its turn `:1825`; does not fold the active in-progress turn `:1895`; does not fold the session's running turn when `latestRun` regresses `:2894`.
- promptless restart stays in one active visual response `:1945`; working header stays under the initiating prompt across repeated steers `:1706`, and for `steer`/`promoted_queued_to_steer` `:1748`.
- imported V1 (runless) turns stay folded once the first V2 run starts `:2340`; provider-native subagent thread folds each run `:2178`; runless tools are live work only while the subagent works `:2437`; runless entries are not live on a thread with runs `:2492`.

Work grouping and the live row:
- single completed tool call renders directly `:2527`; separated in-progress tool runs stay visible `:2595`; stale in-progress tools are not revived before a fresh send has a turn id `:2662`; separated historical task progress not revived `:2705`; table-driven grouping cases `:2768`.
- one activity row reused for initial thinking and the latest tool `:2818`; live row carries the latest thought `:2050`; a running tool stays in the shared activity row `:2104`; stranded thinking stops after a steer `:668`.
- live compaction takes the activity slot and Thinking returns on completion `:1059`; compaction stays visible outside folded work `:1026`.
- CUA action title `:749`; project MCP calls and clone summaries `:780`; table cases for waiting/completed `:847` and for running/completed/superseded `:927`.
- summaries and icons: `:3042` (table), integration source dedupe and first source icon `:3123`, `:3201`, `:3250`, `:3283`.

Assistant meta and copy:
- copy only on the terminal assistant message `:1122`; streaming marks only the active turn `:1185`; meta only on the terminal message `:2955`; meta withheld while the active turn runs `:3002`; diff summaries and revert counts land on the right rows `:1238`.

### 6.2 Helper functions, `LT`

- `work entry labels` `:99`: live titles for thread reads `:100`, reasoning preview `:119`, thread-read labels `:152,:171,:193`, legacy lifecycle `:202`, tense of the live row `:212`, read label with path never body `:226`, Claude Grep from structured input `:261`, file search label `:281`, multi-line approval prompt `:297`, unrecognized tool keeps title `:307`, compact command `:315`, shell wrapper `:322`, tables `:333,:352`.
- `computeMessageDurationStart` `:397`: no preceding user `:398`, first response `:411`, subsequent response `:437`, streaming does not advance `:471`, resets on user `:505`, system messages `:547`, empty `:581`.
- `normalizeCompactToolLabel` `:586`; `resolveAssistantMessageCopyState` `:596` (completed `:597`, streaming `:610`, empty `:623`, non-terminal `:636`, Codex directives `:649`).
- `resolveTimelineToolPresentation` `:3576` (Claude and Cursor names `:3577`, Codex `:3584`, bare `:3591`, unknown `:3598`).
- `shouldCollapseUserMessage` `:5196` (quote chip by label `:5197`, file links and context chips `:5216`).
- skip (scroll or minimap UI): `expanded tool group scrolling` `:50`, `shouldPreserveAssistantLineBreaks` `:386`.

### 6.3 Run, attempt and subagent history, `LT`

- `v2 run and attempt history` `:3603`: settled-turn commentary and work fold behind a Worked-for row `:3604`; subagents hide in folded turns when they arrive before commentary `:3742`; only a superseded attempt's output collapses `:3812`; interrupt request hidden, work and result kept `:3960`.
- `linked timeline resources` `:4380`: thought preview and subagent cards `:4390`; adjacent subagents group but not across resource or run boundary `:4433`; table `:4456`; created-chat summaries after the final answer `:4559`.
- `failed turn transcript` `:4879`: `provider_error` and `usage_limit` cases `:4880`.
- `live subagents after their parent turn settles` `:5027`: `app_owned`/`provider_native` `:5128`; completed/failed child folds with its turn `:5142`; launch batch visible while any member runs `:5148`; running child visible when a steer supersedes its attempt `:5156`.
- `computeStableMessagesTimelineRows` `:3341` and `streaming v2 row projection` `:4070`: row identity reuse. A Swift port needs only: same rows in same order give equal output; changing a row changes only that row.

### 6.4 Rendering expectations, `apps/web/src/components/chat/MessagesTimeline.test.tsx` (2720 lines)

Useful as acceptance checks for visuals (jsdom render): dynamic tool input shown on expand without cached output `:485`; unanswered question row leads with the question text `:531`; progressive history control `:805`, empty bounded timeline still actionable `:825`; changed files header sticky `:860`; collapse controls for long user messages `:1325,:1346`; user messages from another agent `:1359`; steer intent visible `:1401`; spacing below a collapsed turn divider `:1421`; superseded attempt disclosure `:1464`; context compaction in the work log `:1654`; transient interrupt request not rendered `:1677`; handoff from-to endpoints `:1722`; created-thread rows `:1864`; collapsed summary icon neutral when group ends in failure `:1913`, mixed logs neutral after a later success `:1956`; provider retries `:2141`; T3 MCP logo and pretty name `:2293`; changed-file paths relative to workspace root `:2368`; settled tool runs collapse behind a summary toggle `:2484`; muted failure marker `:2527`; red treatment for severe failure `:2567`; expand/collapse a tool call through its header `:2675`.

### 6.5 Entry derivation, `apps/web/src/session-logic.test.ts` (1832 lines)

- `V2 session presentation` `:46`: provider retry labels `:112`; visible turn item order with provider errors in the work log `:304`; tool items keep tool tone `:545`; queued input absent until dispatch creates its turn item `:589`; anchored feedback ordering `:658`; plan status and file contents in entries `:761`; attempt identity through execution nodes `:838`; rollback targets the turn-start message `:242`.
- `native provider presentation in the v2 timeline` `:975`: async answers fold into the question row `:1001`; checkpoint-only work excluded `:1049`; Claude Read image previews `:1110`; read of a bare filename `:1128`; browser identity and source on a completed row `:1143`; idle provider task neutral `:1201`.
- `work-log failure policy` `:1374`: success rows whose output reports failure `:1384`; command text alone is not failure `:1397`; clean completed row `:1406`; recovered failure `:1412`.
- `incremental v2 timeline entries` `:1418`: canonical order even with backwards timestamps `:1493`.
- `HTML renders in the timeline` `:1214` (skip for M4).
- `image asset requests` `:1652` (skip).

### 6.6 Work-log presentation, `packages/client-runtime/src/work-log/`

- `presentation.test.ts` (1000 lines): `workEntryIndicatesToolFailure` `:50`, `summarizeToolGroup` `:197` (reasoning excluded `:209`, thread creation `:228`, sources `:241`, browser/computer `:256`), `resolveWorkEntryToolPresentation` `:272` (every T3 tool `:273`, project tools `:323`, foreign identity `:353`, MCP errors `:365`, device `:404`), `browser group summaries` `:523`, `command work-log details` `:617`, `workEntryViewedImagePath` `:700`, `toolGroupAction` `:741`, PR tools `:822`, device summaries `:906`.
- `commandLabel.test.ts` (603 lines): `commandProgramName` `:9`, `commandDisplayText` `:485-567` (the wrapper cases listed in 3.5), `commandHighlightLanguage` `:570`.
- `itemDetail.test.ts:34,50` (tool output images), `toolPresentation.test.ts:5-107`, `packages/client-runtime/src/state/turnItemPresentation.test.ts:73`.
- `packages/shared/src/toolActivity.test.ts:14-130`, `toolOutput.test.ts:150` (failure phrases) and `:183` (images).

### 6.7 Loading, history, diffs, time

- `packages/client-runtime/src/state/threadHistoryMerge.test.ts:47-300` (merge, dedupe, cursor guards, load-earlier visibility), `orchestrationV2Projection.test.ts` and `threads-sync.test.ts` (reducer; covered in B-orchestration 3.9).
- `apps/web/src/lib/turnDiffTree.test.ts:5-170`, `apps/web/src/components/chat/ChangedFilesTree.test.tsx:7-180`.
- `packages/shared/src/orchestrationTiming.test.ts:9-160`, `apps/web/src/timestampFormat.test.ts:38-245`.

## 7. Port checklist

Sizes are TypeScript lines of the named function or file range, rounded. "Skip" means a read-only M4 view can leave it out. Order is dependency order: later items use earlier ones.

| # | Port item | Source | Lines | M4 |
| --- | --- | --- | --- | --- |
| 1 | `ProjectedTurnItem`, `TurnItem` union with unknown-type drop | `docs/research/B-orchestration.md` 1.10, protocol.md | existing | needed |
| 2 | `ThreadHistoryMeta` and merge helpers | `RT/threadHistoryMerge.ts` | 155 | needed (load earlier) |
| 3 | Thread store: HTTP bounded load, subscribe input, status, 5 min retention | `RT/threads.ts:170-905`, section 1 | ~700 TS, ~250 Swift | needed |
| 4 | `createQuestionHistoryProjector` | `RT/threadRequests.ts:118-176` | 60 | needed |
| 5 | Run summaries: `deriveThreadActivityRun`, `deriveThreadRuntime` (status, activeRunId), `latestUnheldRun`, `derivePhase`; skip usage-limit and background-work branches first | `RT/threadExecution.ts:35-290` | ~150 | needed (live flag) |
| 6 | `formatDuration`, `computeElapsedMs`, `maxIsoTimestamp` | `OT:36-52`, `L:482-497` | 35 | needed |
| 7 | Timestamps: short, day-aware, tooltip, upcoming | `TS:3-222` | 100 | needed |
| 8 | `formatWorkspaceRelativePath` and path helpers (`splitFilePathPosition`, `fileBasename`, `formatFilePathPosition`, `stripSlashPrefixedWindowsDrive`; the last four are in `packages/shared/src/fileLinks.ts` and `path.ts`, not read) | `apps/web/src/filePathDisplay.ts:19-55` | 40 + helpers | needed |
| 9 | Tool activity helpers: `classifyToolActivity`, `toolNameToken`, `collectToolFilePaths`, `formatSearchToolLabel`, `formatReadToolLabel`, `dynamicToolTitle`, `claudeSkillInvocation` | `TA:18-39,110-165,220-374` | 230 | needed |
| 10 | `toolOutputIndicatesFailure` | `TO:211-224` | 14 | needed |
| 11 | `commandDisplayText` subset: tokenizer, `-c` wrapper strip, control-char pictures | `C:202-378,1375-1409` | ~200 | needed |
| 12 | `commandProgramName` (full) | `C:1073-1373` | 1100 | skip (live verb only) |
| 13 | `WorkLogEntry`, `projectedWorkEntry`, status and tone maps, `providerErrorPresentation`, `contextCompactionLabel`, `formatTokens` | `S:68-95,355-567`, `P:52-62`, `usageFormat.ts:32-45` | 260 | needed |
| 14 | `deriveTimelineEntriesFromVisibleTurnItems` (without optimistic and anchored branches), attempt resolution, workspace-preparation filter | `S:592-770`, `CR/state/turnItemPresentation.ts:13-20` | 190 | needed |
| 15 | T3 MCP tool table and `resolveT3McpToolName` | `packages/shared/src/t3McpToolPresentation.ts:86-394`; `P:141-188` | 310 (data) | needed for T3-heavy threads; generate from source |
| 16 | `toolGroupAction`, `workLogEntryIsToolLike` (both versions), failure/success/neutral predicates | `P:356-476`, `S:176-218` | 160 | needed |
| 17 | `summarizeToolGroup`, `toolGroupActionLabel`, `toolGroupActionCount`, `summaryActionPriority`, `toolGroupSummaryKind`; call `summarizeT3ToolCalls` only if you port item 15's actions | `P:526-761` | 240 | needed |
| 18 | `workEntryDisplayLabel`, `singleToolCallLabel`, `workEntryIsVisibleInGroup`, read-path helpers | `L:94-285` | 190 | needed |
| 19 | `liveWorkEntryLabel`, `liveActivityToolStatus`, `liveThoughtLine` | `L:240-272`, `P:190-196,763-776` | 60 | live only |
| 20 | Row model `MessagesTimelineRow` (kinds in 2.4) | `L:514-648` | 135 | needed |
| 21 | Run state helpers: `deriveTerminalAssistantMessageIds`, `deriveUnsettledRunId`, `failedTimelineRunIds`, `timelineEntryStartsResponse`, `lastResponseBoundaryIndex`, `deriveActiveVisualResponseRunIds`, `timelineEntryFoldRunId`, `liveSubagentCardEntryIds`, `isLiveSubagentTurnItem` | `L:712-736,808-958`, `CR/state/subagentRuntime.ts:99-101` | 220 | needed |
| 22 | `deriveTurnFolds` | `L:961-1138` | 180 | needed |
| 23 | `deriveSupersededAttemptFolds` | `L:759-806` | 50 | needed |
| 24 | Pre-passes `settleSupersededReasoning`, `withoutSubagentDelegationRows` (the latter needs `compactDynamicToolOutput`, `TO:112-185`) | `L:1246-1299` | 55 + 75 | settle: needed; delegation filter: skip until T3 delegate threads matter |
| 25 | `deriveMessagesTimelineRows` main loop, work grouping, live tail | `L:1326-1996` | 670 | needed (drop worktree setup branch, ~60) |
| 26 | `attachTrailingToolGroupsToAssistant`, `attachCreatedThreadSummaries`, `continuesWorkLog` | `L:1151-1244,1938-2004` | 150 | needed |
| 27 | Item inspector text: `toolCallLines`, `textFromBlocks`, `formatToolValue`, `turnItemOutputText`, `turnItemHasDetail`, `turnItemNeedsDetailFetch`, `turnItemDetailRevision`; `getTurnItem` fetch | `D:1-268` | 270 | needed (tool cards) |
| 28 | `resolveUserMessagePresentation`, `shouldCollapseUserMessage`, intent marker text | `CR/userMessage.ts:1-31`, `L:2286-2311`, `T:2561-2604` | 70 | needed |
| 29 | Checkpoint summaries and `turnDiffSummaryByAssistantMessageId` | `RT/threadCheckpoints.ts:20-52`, `L:1347-1353` | 40 | needed |
| 30 | `buildTurnDiffTree`, `summarizeTurnDiffStats`, `formatCompactDiffCount` | `TD:1-147`, `DiffStatLabel.tsx:6-17` | 160 | needed |
| 31 | `getTurnDiff` / `getFullThreadDiff` client calls and the range rule | section 5.3, `queries.ts:343-383` | 40 | needed |
| 32 | Unified-diff parser and line renderer | replaces `@pierre/diffs` | new, ~250 Swift | needed |
| 33 | `computeStableMessagesTimelineRows`, `replaceStreamingMessageRows`, `isRowUnchanged` | `L:2044-2284` | 240 | skip; use `Identifiable` rows and diff by id |
| 34 | `computeMessageDurationStart`, `durationStart` | `L:655-672` | 20 | skip (unused by the renderer) |
| 35 | Timeline minimap, scroll anchoring, follow-at-end, `WorkGroupScrollAnchor` | `L:288-480`, `timelineScrollAnchoring.ts`, `timelineMinimapItems.ts` | 500+ | skip |
| 36 | `html-render`, `mcp-app`, `worktree-setup`, `secret_request`, `proposed-plan` card, markdown renderer, citations, attachments, context chips, copy directives | various | large | skip or placeholder rows |

Minimum viable order of work: 1 to 11, 13 to 14, 16 to 18, 20 to 23, 25 to 26 give correct rows for settled threads (tool cards collapsed, fold headers, group summaries). Add 27 for expandable tool bodies, 29 to 32 for changed files and diffs, 19 and the live branches of 25 when a run can be active while the view is open.

Open questions (not answered by the source, check against the sandbox server):
- `projection.checkpoints` is partial in bounded snapshots. Whether a changed-files card disappears for older turns after the first window needs a recorded fixture; compare with `docs/protocol.md` 7.7 correction note.
- `summarizeT3ToolCalls` (`packages/client-runtime/src/t3ToolSummary.ts`) and `t3ToolResultIndicatesFailure` were not read. They only matter for groups containing `t3_*` tools.
- `renderCodexDirectivesForCopy`, `shouldPreserveAssistantLineBreaks`, `formatSubagentDisplayTitle`, the user-message context chip registry (`T:4469-4684`) and `ProposedPlanCard` were not read.
