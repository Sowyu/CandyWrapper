# B. Orchestration protocol (T3 Code orchestration v2)

Research notes for the native macOS client. Source: `/Users/mrm/CandyWrapper-research/t3code` at tag
`v0.0.46-nightly.20261009.2861` (commit `3b6af0bd1`), the server version running on this machine.

Conventions used in this file:

- Citations are `repo-relative/path.ts:line` (or `:start-end`). All paths are relative to the t3code repo root.
- **UNVERIFIED** marks anything I could not confirm in source. Everything else is backed by a citation.
- "Contract" = `packages/contracts/src/orchestrationV2.ts` unless another file is named.
- Schema optionality vocabulary (Effect Schema v4, used throughout the contracts):
  - `Schema.optional(X)`: the JSON key may be absent; when present it must decode as `X` (the decoded Type allows `undefined`).
  - `Schema.optionalKey(X)`: the key may be absent; when present it must be `X` (exact-optional, no explicit `undefined`).
  - `Schema.NullOr(X)`: key required, value may be `null`.
  - `Schema.optional(Schema.NullOr(X))`: key may be absent, or `null`, or `X`.
  - `X.pipe(Schema.withDecodingDefault(...))`: key may be absent on decode; the default is filled in. Servers always send it.
  - So a Swift model must decode "absent" and "null" as distinct-but-tolerated cases exactly where the contract says so, and must *encode* commands without keys the schema does not know (see section 6 for strictness).

---

## 0. Orientation

### 0.1 Mental model

```text
Project (environment-local workspace record)
  AppThread (user-visible conversation)            ThreadId
    Run (counted user-visible turn)                RunId     run.status drives "working"
      RunAttempt (one provider execution try)      RunAttemptId
        root ExecutionNode (kind root_turn)        NodeId
          child nodes: tool_call / approval_request / user_input_request / subagent / ...
      ProviderTurn (normalized native turn)        ProviderTurnId
    ProviderThread (native conversation handle)    ProviderThreadId
    ProviderSession (live provider runtime)        ProviderSessionId
    RuntimeRequest (approval / question)           RuntimeRequestId
    ConversationMessage                            MessageId
    TurnItem (ordered render rows)                 TurnItemId
    PlanArtifact (proposed_plan | todo_list)       PlanId
    CheckpointScope / Checkpoint                   CheckpointScopeId / CheckpointId
    ContextTransfer / ContextHandoff               (forks, provider switches, merge-back, subagents)
```

Source: `docs/orchestration-v2/README.md:62-81`, `docs/orchestration-v2/core-graph-and-data-model.md:5-25`.
Key invariants: app ids are primary and provider ids are refs; only the root node of a run can complete the
run; child (subagent) completion never closes the parent run (`docs/orchestration-v2/README.md:31-42`).

### 0.2 Request/response surface (orchestration only)

All orchestration traffic is Effect RPC over the environment WebSocket (`/ws`), except snapshot/paging
helpers that also exist over HTTP. RPC method names (`packages/contracts/src/orchestrationV2.ts:3138-3153`):

| Method (wire name)                      | Kind     | Input                                   | Output                                      |
| --------------------------------------- | -------- | --------------------------------------- | ------------------------------------------- |
| `orchestration.dispatchCommand`         | unary    | `OrchestrationV2Command`                | `{ sequence: NonNegativeInt }`              |
| `orchestration.subscribeShell`          | stream   | `{ afterSequence?, requestCompletionMarker? }` | `OrchestrationV2ShellStreamItem`     |
| `orchestration.subscribeArchivedShell`  | stream   | `{}`                                    | `OrchestrationV2ArchivedShellStreamItem`    |
| `orchestration.getArchivedShellSnapshot`| unary    | `{}`                                    | `OrchestrationV2ArchivedShellSnapshot`      |
| `orchestration.subscribeThread`         | stream   | `OrchestrationV2SubscribeThreadInput`   | `OrchestrationV2ThreadStreamItem`           |
| `orchestration.getThreadProjection`     | unary    | `{ threadId }`                          | `OrchestrationV2ThreadProjection`           |
| `orchestration.getTurnItem`             | unary    | `{ threadId, itemId, revision? }`       | `{ item: TurnItem \| null }`                |
| `orchestration.getTurnDiff`             | unary    | `OrchestrationGetTurnDiffInput`         | `OrchestrationGetTurnDiffResult`            |
| `orchestration.getFullThreadDiff`       | unary    | `OrchestrationGetFullThreadDiffInput`   | `OrchestrationGetFullThreadDiffResult`      |
| `orchestration.launchThread`            | unary    | `OrchestrationV2ThreadLaunchInput`      | `{ threadId, projection, resumed }`         |
| `orchestration.searchThreads`           | unary    | `OrchestrationSearchThreadsInput`       | `OrchestrationSearchThreadsResult`          |
| `orchestration.searchThread`            | unary    | `OrchestrationV2SearchThreadInput`      | `OrchestrationV2SearchThreadResult`         |
| `orchestration.searchThreadStream`      | stream   | `OrchestrationV2SearchThreadInput`      | `OrchestrationV2SearchThreadResult`         |
| `orchestration.getWorkflowScript`       | unary    | `{ threadId, scriptPath }`              | `{ scriptPath, contents, truncated }`       |

Schemas per method: `packages/contracts/src/orchestrationV2.ts:3561-3610`; RPC definitions (including the
error unions, each of which also includes `EnvironmentAuthorizationError`):
`packages/contracts/src/rpc.ts:1559-1661`; registration in the RPC group: `packages/contracts/src/rpc.ts:1983-1996`.

Protocol gate: every client must speak orchestration protocol **2**.
`ORCHESTRATION_PROTOCOL_VERSION = 2`, query param `orchestrationProtocol`, HTTP header
`x-t3-orchestration-protocol: 2` (`packages/contracts/src/environment.ts:13-16`). The `/ws` route returns
HTTP **426** with JSON `{ "code": "orchestration_protocol_incompatible", "message": "...", "orchestrationProtocolVersion": 2 }`
when `?orchestrationProtocol=2` is missing or different, before any auth (`apps/server/src/ws.ts:607-612`,
`apps/server/src/ws.ts:3141-3151`). The official client appends the param in
`packages/client-runtime/src/connection/compatibility.ts:38-42` and blocks the connection when the
environment descriptor's `orchestrationProtocolVersion` (absent = 1) differs
(`packages/client-runtime/src/connection/compatibility.ts:9-27`). Orchestration HTTP endpoints require the
`x-t3-orchestration-protocol: "2"` header literal (`packages/contracts/src/environmentHttp.ts:81-85`).

---

## 1. Domain model

### 1.1 Identifiers

Every id is a branded `TrimmedNonEmptyString` (trimmed on decode and encode; must be non-blank) with no
pattern or length limit at the schema level (`packages/contracts/src/baseSchemas.ts:7-27`,
`packages/contracts/src/baseSchemas.ts:308-312`). Brands are compile-time only, so **ids are opaque strings on
the wire**. The id families used by orchestration (`packages/contracts/src/baseSchemas.ts:314-407`):
`ThreadId`, `ProjectId`, `EnvironmentId`, `CommandId`, `EventId`, `MessageId`, `RunId`, `RunAttemptId`, `NodeId`,
`ProviderSessionId`, `ProviderThreadId`, `ProviderTurnId`, `TurnItemId`, `RuntimeRequestId`, `ScheduledTaskId`,
`CheckpointRef`, `CheckpointId`, `CheckpointScopeId`, `ContextHandoffId`, `ContextTransferId`, `RawEventId`, `PlanId`.
Provider slugs are stricter: `ProviderDriverKind` and `ProviderInstanceId` are 1-64 chars matching
`^[a-zA-Z][a-zA-Z0-9_-]*$` (`packages/contracts/src/providerInstance.ts:40-83`). `ProviderDriverKind` is an
open slug (unknown drivers must still decode; `packages/contracts/src/providerInstance.ts:16-28`). The legacy
default instance id for a built-in driver is the driver kind itself (`packages/contracts/src/providerInstance.ts:160-168`).

**Who allocates which id**

| Id | Allocated by | Format observed in source |
| --- | --- | --- |
| `CommandId` | client | UUID v4 string (`packages/client-runtime/src/operations/commands.ts:261-267`); some follow-up commands derive `"<commandId>:model-selection"` (`packages/client-runtime/src/operations/commands.ts:595`) and `"<commandId>:detach:<sessionId>"` (`packages/client-runtime/src/operations/commands.ts:928`) |
| `ThreadId`, `MessageId`, `ProjectId` | client (web) | plain UUID v4 via `randomUUID()` (`apps/web/src/lib/utils.ts:36-50`) |
| `RunId` | server, derived | `run:thread:<threadId>:ordinal:<n>` (`packages/provider-core/src/server/IdAllocator.ts:404`) |
| `RunAttemptId` | server, derived | `run-attempt:run:<runId>:attempt:<n>` (`packages/provider-core/src/server/IdAllocator.ts:406-407`) |
| root `NodeId` | server, derived | `node:run:<runId>:root`, or `node:run:<runId>:attempt:<n>:root` (`packages/provider-core/src/server/IdAllocator.ts:409-411`) |
| user-message `TurnItemId` | server, derived | `turn-item:message:<messageId>` (`packages/provider-core/src/server/IdAllocator.ts:412`) |
| run-signal `TurnItemId` | server, derived | `turn-item:run:<runId>:signal:<signal>` (`packages/provider-core/src/server/IdAllocator.ts:413-414`) |
| provider-derived ids | server, derived | `provider-turn:provider:<driver>:native-turn:<id>`, `node:provider:<driver>:native-item:<id>`, `message:provider:<driver>:native-item:<id>`, `turn-item:provider:<driver>:native-item:<id>` (`packages/provider-core/src/server/IdAllocator.ts:416-428`) |
| approval node / item | server, derived | `node:runtime-request:<requestId>`, `turn-item:runtime-request:<requestId>` (`packages/provider-core/src/server/IdAllocator.ts:430-432`) |
| `RuntimeRequestId` | server, random | `runtime-request:provider:<driver>[:provider-turn:<id>][:native-request:<id>]:<uuid>` (`packages/provider-core/src/server/IdAllocator.ts:321-335`) |
| `EventId` | server, random | `event[:thread:<id>][:command:<id>][:provider-session:<id>]:<uuid>` (`packages/provider-core/src/server/IdAllocator.ts:266-279`) |
| `CheckpointScopeId` / `CheckpointId` | server, deterministic | `checkpoint-scope:thread:<threadId>:name:<name>` / `checkpoint:scope:<scopeId>:name:<name>` (`packages/provider-core/src/server/IdAllocator.ts:336-347`) |
| `PlanId`, `ContextHandoffId`, `ContextTransferId`, `ProviderSessionId` | server | prefixed + uuid (`packages/provider-core/src/server/IdAllocator.ts:315-388`); shared session `provider-session:provider-instance:<id>:shared` (`packages/provider-core/src/server/IdAllocator.ts:390-393`) |
| delegated-task ids | server, derived from the command id | `thread:delegated-task:<commandId>`, `node:delegated-task:<commandId>`, ... (`packages/provider-core/src/server/IdAllocator.ts:394-402`) |
| thread from a provider-native thread | server, derived | `thread:provider:<driver>[:provider-instance:<id>]:native-thread:<nativeId>` (`packages/provider-core/src/server/IdAllocator.ts:197-213`) |

Each id part is `encodeURIComponent`-escaped and joined by `:` (`packages/provider-core/src/server/IdAllocator.ts:192-195`).
Some special server message ids: `async-answer:<requestId>` (`apps/server/src/orchestration-v2/Orchestrator.ts:7261`),
`message:restart-continuation:<runId>` (`apps/server/src/orchestration-v2/RestartContinuation.ts:96`),
`limit-resume:<identity>` (`apps/server/src/orchestration-v2/UsageLimitRecoveryWorker.ts:60`),
`message:pr-watch:<uuid>` (`apps/server/src/orchestration-v2/PullRequestWatchReactor.ts:322`), and the fork marker item
`turn-item:fork:<targetThreadId>` (`apps/server/src/orchestration-v2/ProjectionStore.ts:1237`).
**Client rule:** never parse ids; treat them as opaque. (The derived formats are useful only for debugging.)

### 1.2 Shared literal vocabularies

| Name | Values | Source |
| --- | --- | --- |
| `OrchestrationV2Actor` (`createdBy`) | `user`, `agent`, `system` | `packages/contracts/src/orchestrationV2.ts:76` |
| `OrchestrationV2CreationSource` | `web`, `mobile`, `mcp`, `provider`, `server` | `packages/contracts/src/orchestrationV2.ts:79-85` |
| `OrchestrationV2ThreadHistoryOrigin` | `native`, `v1_import` | `packages/contracts/src/orchestrationV2.ts:88` |
| `RuntimeMode` | `approval-required`, `auto-accept-edits`, `auto`, `full-access` (default `full-access`) | `packages/contracts/src/providerPolicy.ts:25-32` |
| `ProviderInteractionMode` | `default`, `plan` (default `default`) | `packages/contracts/src/providerPolicy.ts:34-36` |
| `ProviderRequestKind` | `command`, `file-read`, `file-change`, `mcp-elicitation`, `permission` | `packages/contracts/src/providerPolicy.ts:38-44` |
| `ProviderApprovalDecision` | `accept`, `acceptForSession`, `acceptAlways`, `decline`, `cancel` | `packages/contracts/src/providerPolicy.ts:50-56` |
| `OrchestrationV2NativeRefStrength` | `strong`, `weak`, `none` | `packages/contracts/src/orchestrationV2.ts:96` |
| `OrchestrationV2RunStatus` | `preparing`, `queued`, `starting`, `running`, `waiting`, `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back` | `packages/contracts/src/orchestrationV2.ts:453-464` |
| `OrchestrationV2ShellThreadStatus` | `idle` or any `RunStatus` | `packages/contracts/src/orchestrationV2.ts:1813-1816` |
| `OrchestrationV2TurnItemStatus` | `idle`, `pending`, `running`, `waiting`, `completed`, `failed`, `cancelled`, `interrupted` | `packages/contracts/src/orchestrationV2.ts:1238-1247` |
| `OrchestrationV2UserMessageInputIntent` | `turn_start`, `queued_turn`, `steer`, `promoted_queued_to_steer` | `packages/contracts/src/orchestrationV2.ts:1307-1312` |
| `OrchestrationV2ProviderFailureClass` | `usage_limit`, `provider_error`, `transport_error`, `permission_error`, `validation_error`, `unknown` | `packages/contracts/src/orchestrationV2.ts:1261-1268` |
| `OrchestrationV2ContextTransferType` | `fork`, `provider_handoff`, `merge_back`, `subagent_spawn`, `subagent_result` | `packages/contracts/src/orchestrationV2.ts:115-121` |
| `OrchestrationV2SecretRequestStatus` | `pending`, `saved`, `declined`, `cancelled` | `packages/contracts/src/orchestrationV2.ts:1352-1357` |
| `OrchestrationV2ProviderGoalStatus` | `active`, `paused`, `blocked`, `usage_limited`, `budget_limited`, `complete` | `packages/contracts/src/orchestrationV2.ts:843-850` |

`ProviderApprovalPolicy` (`untrusted`, `on-failure`, `on-request`, `never`) and `ProviderSandboxMode`
(`read-only`, `workspace-write`, `danger-full-access`) exist in `packages/contracts/src/providerPolicy.ts:10-23`
but are provider-facing, not part of the orchestration wire entities.

### 1.3 Timestamps on the wire

Entity schemas use `Schema.DateTimeUtc` for time fields; parallel `*Json` schemas map the same fields to
`Schema.DateTimeUtcFromString` (ISO-8601 string), for example `OrchestrationV2AppThreadJson`
(`packages/contracts/src/orchestrationV2.ts:1991-2016`), `OrchestrationV2ThreadShellJson`
(`packages/contracts/src/orchestrationV2.ts:2410-2439`), `OrchestrationV2StoredEventJson`
(`packages/contracts/src/orchestrationV2.ts:2604-2608`). Some fields are plain strings by design: `IsoDateTime`
is just `Schema.String` (`packages/contracts/src/baseSchemas.ts:47`) and is used for `snoozedUntil` in commands,
`visitedAt`, `resetAt`, project `createdAt/updatedAt`, `OrchestrationV2PlanStep.durationAnchorAt`, and
`OrchestrationV2ProviderTurnTokenUsage.updatedAt` ("string so wire encoding is stable",
`packages/contracts/src/orchestrationV2.ts:978-979`). How `DateTimeUtc` is serialized by the RPC layer is covered in
section 3.1.

### 1.4 Project (sidebar/project shell)

`OrchestrationProjectShell` (`packages/contracts/src/orchestrationProject.ts:9-27`), sent in shell snapshots and
`project.updated` shell items:

| Field | Type | Optionality | Notes |
| --- | --- | --- | --- |
| `id` | `ProjectId` | required | |
| `title` | trimmed non-empty | required | |
| `workspaceRoot` | trimmed non-empty | required | absolute path on the environment |
| `repositoryIdentity` | `RepositoryIdentity` | `optional(NullOr)` | `{ canonicalKey, locator:{source:"git-remote",remoteName,remoteUrl}, webUrl?, rootPath?, displayName?, provider?, owner?, name?, origin?:{canonicalKey, displayName?} }` (`packages/contracts/src/environment.ts:229-258`) |
| `defaultModelSelection` | `ModelSelection` | `NullOr` (key required) | |
| `defaultThreadEnvMode` | `"local" \| "worktree"` | `optional(NullOr)` | null/absent = no override (`packages/contracts/src/orchestrationProject.ts:15-17`, `packages/contracts/src/environment.ts:61`) |
| `autoPull` | boolean | optional | |
| `faviconPath` | trimmed non-empty | `optional(NullOr)` | |
| `projectIcon` | `ReceivedProjectIcon` | `optional(NullOr)` | see satellite section 1.17 |
| `scripts` | `ProjectScript[]` | required | see 1.17 |
| `createdAt`, `updatedAt` | ISO string (`IsoDateTime`) | required | |

Grouping helpers: `repositoryGroupingKeyOf` = `identity.origin?.canonicalKey ?? identity.canonicalKey`
(`packages/contracts/src/environment.ts:261-264`) and `repositoryGroupingDisplayNameOf`
(`packages/contracts/src/environment.ts:266-271`).

### 1.5 Thread: `OrchestrationV2AppThread` (detail) and `OrchestrationV2ThreadShell` (sidebar row)

`OrchestrationV2AppThread` (`packages/contracts/src/orchestrationV2.ts:364-439`) is the payload of `thread.created`
and every `thread.*` event, and `projection.thread` in a thread snapshot:

| Field | Type | Optionality / default | Notes |
| --- | --- | --- | --- |
| `createdBy` | Actor | required | |
| `creationSource` | CreationSource | required | |
| `id` | ThreadId | required | |
| `projectId` | ProjectId | required | |
| `title` | trimmed non-empty | required | (shell `title` is a plain String, `:1840`) |
| `providerInstanceId` | ProviderInstanceId | required | instance of the *current* selection |
| `modelSelection` | ModelSelection | required | default for future runs |
| `runtimeMode` | RuntimeMode | required | |
| `interactionMode` | `default`/`plan` | required | |
| `branch` | trimmed non-empty | `NullOr` | |
| `worktreePath` | trimmed non-empty | `NullOr` | null = project checkout |
| `linkedPullRequest` | `ThreadLinkedPullRequest` | `optional(NullOr)` | legacy single-link field, still emitted (`:375-377`) |
| `pullRequests` | `ThreadPullRequestLink[]` | optional | multi-link model |
| `branchPullRequest` | `ThreadLinkedPullRequest` | `optional(NullOr)` | PR discovered from branch |
| `activeProviderThreadId` | ProviderThreadId | `NullOr` | |
| `historyOrigin` | `native`/`v1_import` | optional | |
| `lineage` | `{ parentThreadId: ThreadId\|null, relationshipToParent: "fork"\|"subagent"\|null, rootThreadId }` | required | `:108-112` |
| `forkedFrom` | union, see below | `NullOr` | `{type:"run",threadId,runId}` \| `{type:"node",nodeId}` \| `{type:"provider_thread",providerThreadId,providerTurnId?}` (`:384-394`) |
| `createdAt`, `updatedAt` | DateTimeUtc | required | |
| `archivedAt` | DateTimeUtc | `NullOr` | |
| `settledOverride` | `"settled" \| "active"` | `NullOr`, decode default `null` | explicit user override |
| `settledAt` | DateTimeUtc | `NullOr`, decode default `null` | |
| `unsettledAt`, `snoozedUntil`, `snoozedAt`, `pinnedAt`, `autoSettleDisabledAt` | DateTimeUtc | `optional(NullOr)` | |
| `limitRecovery` | `{ requestId?: CommandId, runId, resetAt: IsoDateTime, autoResume: bool, snooze?: bool }` | `optional(NullOr)` | `:339-345` |
| `pinOrderKey`, `activeOrderKey` | trimmed non-empty (fractional index) | `optional(NullOr)` | lexicographic order keys (`:410-414`, `:2711-2715`) |
| `lastVisitedAt` | DateTimeUtc | `NullOr`, decode default `null` | server-side read receipt |
| `titleRegeneration` | `{ requestId: CommandId, startedAt }` | `optional(NullOr)` | in-flight title regeneration |
| `rollbackRequestId` | CommandId | optional | latest accepted rollback |
| `rollbackFailure` | `{ requestId: CommandId, message }` | `optional(NullOr)` | cleared when next rollback starts |
| `deletedAt` | DateTimeUtc | `NullOr` | |

`isProviderNativeSubagentThread(thread)` = `lineage.relationshipToParent === "subagent" && creationSource === "provider"`;
such threads cannot take messages (`packages/contracts/src/orchestrationV2.ts:442-451`).

`OrchestrationV2ThreadShell` (`packages/contracts/src/orchestrationV2.ts:1836-1928`) is the sidebar row. It
repeats most `AppThread` fields (note `title` is `Schema.String`, not trimmed-non-empty; `settledOverride` and
`settledAt` are plain `NullOr` with no decode default; `lastVisitedAt` is `optional(NullOr)` and "omitted by servers
that predate server-side visited tracking; clients fall back to their local visited state",
`packages/contracts/src/orchestrationV2.ts:1913-1917`), and adds server-derived summary fields:

| Field | Type | Optionality | Meaning |
| --- | --- | --- | --- |
| `latestRunId` | RunId | `NullOr` | |
| `latestRunRequestedAt`, `latestRunStartedAt`, `latestRunCompletedAt` | DateTimeUtc | `optional(NullOr)` | |
| `activeRunId` | RunId | `NullOr` | |
| `activityRunStartedAt` | DateTimeUtc | `optional(NullOr)` | `orchestrationV2RunWorkStartedAt` of the activity-owning run (`:1861-1865`) |
| `activityRunStatus` | `preparing`/`starting`/`running`/`waiting` | `optional(NullOr)` | |
| `status` | `idle` or RunStatus | required | |
| `lastError` | string | `optional(NullOr)` | |
| `lastErrorClass` | ProviderFailureClass | `optional(NullOr)` | |
| `usageLimitResetAt` | IsoDateTime | `optional(NullOr)` | |
| `pendingRuntimeRequest` | `{ id, kind, createdAt }` | `NullOr` | `kind` = RuntimeRequest kind union (`:1819-1823`) |
| `latestVisibleMessage` | `{ id: MessageId, role: user/assistant/system, text, updatedAt }` | `NullOr` | `:1827-1832` |
| `latestUserMessageAt` | DateTimeUtc | `NullOr` | moved by wakes and agent messages too |
| `latestUserAuthoredMessageAt` | DateTimeUtc | `optional(NullOr)` | only messages the user wrote (`:1876-1880`) |
| `hasActionableProposedPlan` | boolean | required | |
| `pendingBackgroundTasks` | `PendingBackgroundTask[]` | optional, decode default `[]` | "post-settlement background work for sidebar Waiting pills" (`:1882-1886`) |
| `providerInstanceHistory` | ProviderInstanceId[] | optional, decode default `[]` | first-use order (`:1887-1892`) |
| `goal` | `OrchestrationV2ProviderGoal` | `optional(NullOr)` | `/goal` state (`:853-868`) |
| `itemCount`, `visibleItemCount` | NonNegativeInt | required | |

Derivation of these fields on the server, and how the clients turn them into a status pill, is in section 4.

`OrchestrationV2PendingBackgroundTask` (`packages/contracts/src/orchestrationV2.ts:797-828`) is a forward-compatible
`kind` union: `{ taskId, description?, kind: "subagent", childThreadId? }`, `{ ..., kind: "command" }`,
`{ ..., kind: "monitor" }`, `{ ..., kind: "background_task" }`; an unknown or missing `kind` decodes to
`background_task` (`packages/contracts/src/orchestrationV2.ts:760-795`).

`OrchestrationV2ProviderGoal`: `{ objective, status: GoalStatus, tokensUsed?, tokenBudget?: number|null, timeUsedSeconds?, checks?, lastCheck? }`
(`packages/contracts/src/orchestrationV2.ts:858-868`).

### 1.6 Run, RunAttempt, ExecutionNode, Subagent

`OrchestrationV2Run` (`packages/contracts/src/orchestrationV2.ts:541-584`):

| Field | Type | Optionality | Notes |
| --- | --- | --- | --- |
| `id` | RunId | req | |
| `threadId` | ThreadId | req | |
| `ordinal` | PositiveInt | req | 1-based counted turn number |
| `providerInstanceId` | ProviderInstanceId | req | |
| `modelSelection` | ModelSelection | req | selection used for this run |
| `providerThreadId` | ProviderThreadId | `NullOr` | |
| `userMessageId` | MessageId | req | the message that started the run |
| `rootNodeId` | NodeId | `NullOr` | |
| `activeAttemptId` | RunAttemptId | `NullOr` | |
| `status` | RunStatus | req | |
| `queuePosition` | PositiveInt | `optional(NullOr)` | queue slot for `queued` runs |
| `queueHeld` | boolean | optional | restart recovery holds the queue until `queue.resume` (`:553-554`) |
| `requestedAt` | DateTimeUtc | req | |
| `startedAt`, `completedAt` | DateTimeUtc | `NullOr` | |
| `checkpointId` | CheckpointId | `NullOr` | run checkpoint |
| `contextHandoffId` | ContextHandoffId | `NullOr` | |
| `restartContinuationOfRunId` | RunId | optional | server-generated restart continuation |
| `workStartedAt` | DateTimeUtc | optional | wake runs; read via `orchestrationV2RunWorkStartedAt` = `workStartedAt ?? startedAt ?? requestedAt` (`:587-595`) |
| `restartCancelledBackgroundWork` | `{ kind: subagent/shell/monitor/task, label, id? }[]` | optional | `:500-506` |
| `sourcePlanRef` | `{ threadId, planId }` | optional | run implements a proposed plan |
| `delegatedCompletion` | `{ disposition: open/stopped/disposed, nextGeneration, delivery: {generation, messageId, taskIds[]}\|null }` | optional | `:484-497` |
| `workspacePreparation` | `ThreadLaunchWorkspaceStrategy` | optional | how a launch prepares the workspace; `prepared-run.retry` repeats it (`:582-583`) |

Queued messages are not a separate entity: **a queued message is a Run with `status: "queued"`** whose
`userMessageId` points at the queued user message, ordered by `queuePosition` (details in section 2 and 5).

`OrchestrationV2RunAttempt` (`packages/contracts/src/orchestrationV2.ts:597-619`): `id`, `nativeThreadId?: string`, `runId`,
`attemptOrdinal: PositiveInt`, `rootNodeId`, `providerInstanceId`, `providerThreadId`, `providerTurnId: NullOr`,
`reason: initial | steering_restart | retry | provider_recovery`, `status: pending | running | completed | interrupted | failed | cancelled | superseded`,
`startedAt: NullOr`, `completedAt: NullOr`.

`OrchestrationV2ExecutionNode` (`packages/contracts/src/orchestrationV2.ts:622-660`): `id`, `threadId`, `runId: NullOr`,
`parentNodeId: NullOr`, `rootNodeId`, `kind: root_turn | assistant_message | reasoning | plan | todo_list | tool_call | approval_request | user_input_request | subagent | hook | system`,
`status: idle | pending | running | waiting | completed | interrupted | failed | cancelled | rolled_back`, `countsForRun: boolean`,
`providerThreadId: NullOr`, `providerTurnId: NullOr`, `nativeItemRef: NullOr<ProviderRef>`, `runtimeRequestId: NullOr`,
`checkpointScopeId: NullOr`, `startedAt: NullOr`, `completedAt: NullOr`. `isOrchestrationV2WorkActive(status)` is true for
`pending | running | waiting` (`packages/contracts/src/orchestrationV2.ts:704-709`).

`OrchestrationV2ProviderRef` (`packages/contracts/src/orchestrationV2.ts:99-105`): `{ driver, nativeId: string|null, strength, fingerprint?, ordinal? }`.

`OrchestrationV2Subagent` (`packages/contracts/src/orchestrationV2.ts:663-701`): `id: NodeId`, `threadId`, `runId: NullOr`, `parentNodeId`,
`origin: provider_native | app_owned`, `createdBy`, `driver`, `providerInstanceId`, `providerThreadId: NullOr`,
`childThreadId: NullOr<ThreadId>`, `nativeTaskRef: NullOr<ProviderRef>`, `prompt`, `title: NullOr`, `model: NullOr`,
`modelSelection?`, `completionWake?: always | settled_only` (absent = `settled_only`), `completionDelivery?: { state: pending|claimed|acknowledged|delivered|disposed, observedByRunId: NullOr }`,
`status: idle | pending | running | waiting | completed | failed | cancelled | interrupted`, `progress?`, `result: NullOr`,
`startedAt: NullOr`, `completedAt: NullOr`, `updatedAt`.

### 1.7 Provider session, provider thread, provider turn, capabilities

`OrchestrationV2ProviderSession` (`packages/contracts/src/orchestrationV2.ts:726-737`): `id`, `driver`, `providerInstanceId`,
`status: starting | ready | running | waiting | stopped | error`, `cwd`, `model: NullOr`, `capabilities: ProviderCapabilities`,
`createdAt`, `updatedAt`, `lastError: NullOr<string>`. Detach payload: `{ providerSessionId, detachedAt, reason? }` (`:740-744`).

`OrchestrationV2ProviderThread` (`packages/contracts/src/orchestrationV2.ts:871-907`): `id`, `driver`, `providerInstanceId`,
`providerSessionId: NullOr`, `appThreadId: NullOr`, `ownerNodeId: NullOr`, `nativeThreadRef: NullOr<ProviderRef>`,
`nativeConversationHeadRef: NullOr<ProviderRef>`, `status: not_loaded | idle | active | archived | closed | error`,
`firstRunOrdinal: NullOr`, `lastRunOrdinal: NullOr`, `handoffIds: ContextHandoffId[]`,
`forkedFrom: NullOr<{ providerThreadId, providerTurnId?, checkpointId? }>`,
`pendingBackgroundTasks` (optional, default `[]`), `contextUsage: ThreadTokenUsageSnapshot|null` (optional, default `null`),
`nativeMetadata: { modelSelection?, title?: string|null, updatedAt?: string|null, itemIdentityVersion?: 2 }|null` (optional, default `null`; `:831-839`),
`goal` (optional, default `null`), `createdAt`, `updatedAt`.

`OrchestrationV2ProviderTurn` (`packages/contracts/src/orchestrationV2.ts:984-1003`): `id`, `providerThreadId`, `nodeId`,
`runAttemptId: NullOr`, `nativeTurnRef: NullOr<ProviderRef>`, `ordinal: PositiveInt`,
`status: pending | running | completed | interrupted | failed | cancelled`, `startedAt: NullOr`, `completedAt: NullOr`,
`tokenUsage?: { usedTokens, maxTokens?: number|null, inputTokens?, cachedInputTokens?, outputTokens?, reasoningOutputTokens?, updatedAt: string }` (`:970-980`),
`turnTokenUsage?: TurnTokenUsage` (from `providerRuntime.ts`). `latestProviderTurnForAttempt(turns, attemptId)` picks the
highest-ordinal turn of an attempt; a Codex goal can keep one run open across several native turns (`:1006-1023`).

`OrchestrationV2ProviderCapabilities` (`packages/contracts/src/orchestrationV2.ts:193-336`), carried on each
`ProviderSession.capabilities`:

| Group | Boolean/literal fields |
| --- | --- |
| `sessions` | `supportsMultipleProviderThreadsPerSession`, `supportsModelSwitchInSession`, `supportsProviderSwitchingViaHandoff`, `supportsRuntimeModeSwitchInSession`, `pendingRequestsSurviveRestart` |
| `threads` | `canCreateEmptyThread`, `canReadThreadSnapshot`, `canRollbackThread`, `canForkThread`, `canForkFromTurn`, `canForkFromSubagentThread`, `exposesNativeThreadId` |
| `turns` | `exposesNativeTurnId`, `emitsTurnStarted`, `emitsTurnCompleted`, `supportsInterrupt`, `supportsActiveSteering`, `activeSteeringInterruptsTools?` (optional), `supportsSteeringByInterruptRestart`, `supportsQueuedMessages`, `terminalStatusQuality: strong/weak/none` |
| `streaming` | `streamsAssistantText`, `streamsReasoning`, `streamsToolOutput`, `streamsPlanText`, `emitsMessageCompleted` |
| `tools` | `exposesToolItemIds`, `emitsToolStarted`, `emitsToolCompleted`, `emitsToolOutput`, `supportsMcpTools`, `supportsDynamicToolCallbacks` |
| `approvals` | `supportsCommandApproval`, `supportsFileReadApproval`, `supportsFileChangeApproval`, `supportsApplyPatchApproval`, `approvalsHaveNativeRequestIds`, `approvalCallbacksAreLiveOnly`, `approvalsCanOriginateFromSubagents` |
| `planning` | `emitsPlanUpdated`, `emitsTodoList`, `emitsProposedPlan`, `supportsStructuredQuestions`, `planDeltasHaveItemIds` |
| `subagents` | `supportsSubagents`, `exposesSubagentThreadIds`, `emitsSubagentLifecycle`, `canWaitForSubagents`, `canCloseSubagents`, `canForkSubagentThread` |
| `context` | `acceptsSystemContext`, `acceptsDeveloperContext`, `acceptsSyntheticUserContext`, `canGenerateSummaries`, `canConsumeHandoffSummaries`, `supportsDeltaHandoff`, `supportsFullThreadHandoff`, `maxRecommendedHandoffChars: PositiveInt\|null` |
| `checkpointing` | `appCanCheckpointFilesystem`, `supportsNestedCheckpointScopes`, `providerCanRollbackConversation`, `providerRollbackReturnsSnapshot`, `providerCanReadConversationSnapshot` |
| `identity` | `nativeThreadIds`, `nativeTurnIds`, `nativeItemIds`, `nativeRequestIds` (each `strong/weak/none`) |
| `runtimePolicy` | `{ enforcement: "native" \| "client-boundary" }`, decode default `client-boundary` (`:298-335`) |

### 1.8 Runtime requests (approvals, questions)

`OrchestrationV2RuntimeRequest` (`packages/contracts/src/orchestrationV2.ts:1025-1044`):

| Field | Type | Notes |
| --- | --- | --- |
| `id` | RuntimeRequestId | |
| `nodeId` | NodeId | the `approval_request`/`user_input_request` node |
| `providerTurnId` | `NullOr` | |
| `nativeRequestRef` | `NullOr<ProviderRef>` | |
| `kind` | `ProviderRequestKind` (`command`, `file-read`, `file-change`, `mcp-elicitation`, `permission`) or `dynamic_tool_call`, `user_input`, `auth_refresh` | `:1030-1033` |
| `status` | `pending`, `resolved`, `expired`, `cancelled` | |
| `responseCapability` | `{type:"live", providerSessionId}` \| `{type:"message"}` \| `{type:"not_resumable", reason}` | only `live` (and `message`, see 2.x) is respondable |
| `createdAt` | DateTimeUtc | |
| `resolvedAt` | `NullOr` | |
| `decision` | ProviderApprovalDecision | optional; recorded answer |
| `answers` | `Record<string, unknown>` | optional; recorded user-input answers (`packages/contracts/src/providerPolicy.ts:67`) |

The renderable rows are turn items `approval_request` (with `requestId`, `requestKind`, `prompt?`, `appName?`,
`options?: { decision, label, warning? }[]`) and `user_input_request` (with `requestId`, `questions[]`,
`questionAnswer?`, `responseMode?: "message"`), see 1.10. `ProviderApprovalOption` =
`{ decision, label, warning? }` (`packages/contracts/src/providerPolicy.ts:59-64`).

`OrchestrationV2UserInputQuestion` (`packages/contracts/src/orchestrationV2.ts:1151-1167`): `id`, `header`, `question`
(all trimmed non-empty), `options: { label, description, value?: string }[]`, `multiSelect?`, `allowCustomAnswer?`,
`initialAnswer?: string` ("answers preserve whitespace and allow an empty string when present"), `required?`.
`UserInputAttachmentAnswerPayload` = `{ requestId, questionTextById?: Record<string,string>, answers: Record<string,unknown>, attachmentsByQuestionId: Record<string, (ChatImageAttachment|ChatFileAttachment)[]> }`
(`packages/contracts/src/providerPolicy.ts:70-83`; per-question array max `PROVIDER_SEND_TURN_MAX_ATTACHMENTS`).

### 1.9 Messages and notifications

`OrchestrationV2ConversationMessage` (`packages/contracts/src/orchestrationV2.ts:1113-1137`): `notification?`, `createdBy`,
`creationSource`, `scheduledTaskId?`, `senderThreadId?` (sending agent's thread), `id: MessageId`, `threadId`,
`runId: NullOr`, `nodeId: NullOr`, `role: user | assistant | system`, `text: string`, `context?: OrchestrationMessageContext`,
`attachments: ChatAttachment[]` (required, may be empty), `streaming: boolean`, `createdAt`, `updatedAt`,
`delegatedCompletion?: { parentRunId, generation, taskIds: NodeId[] }`.

`OrchestrationV2Notification` (`packages/contracts/src/orchestrationV2.ts:1102-1110`): `{ source, outcome: completed|failed|cancelled|updated|unknown, summary, detail? }`.
`source` is a forward-compatible kind union (`packages/contracts/src/orchestrationV2.ts:1054-1099`). **Wire shapes the
server encodes** (chosen so older clients decode them): `{kind:"delegated_task", taskIds, childThreadId?}`,
`{kind:"background_task", work:"subagent", childThreadId?}` (decodes to `{kind:"subagent"}`),
`{kind:"background_command"}` (decodes to `{kind:"command"}`), `{kind:"monitor"}`, `{kind:"background_task"}`;
unknown kinds decode to `background_task`.

Note: the thread detail renders from `turnItems`/`visibleTurnItems`, not `messages`; the official bounded snapshot
does not even retain the full message table (`docs/internals/performance-regressions.md:15-18`). See section 3.

### 1.10 Turn items (the timeline rows)

`OrchestrationV2TurnItem` is a union discriminated by **`type`** (`packages/contracts/src/orchestrationV2.ts:1372-1577`).
Base fields on every item (`packages/contracts/src/orchestrationV2.ts:1316-1335`):

`toolNonExecutionKind?: string`, `toolSurface?`, `toolIcon?`, `toolSource?` (from `providerRuntime.ts`), `id: TurnItemId`,
`threadId`, `runId: NullOr`, `nodeId: NullOr`, `providerThreadId: NullOr`, `providerTurnId: NullOr`,
`nativeItemRef: NullOr<ProviderRef>`, `parentItemId: NullOr<TurnItemId>`, `ordinal: NonNegativeInt`,
`status: TurnItemStatus`, `title: NullOr<string>`, `startedAt: NullOr`, `completedAt: NullOr`, `updatedAt`.

| `type` | Extra fields | Line |
| --- | --- | --- |
| `notification` | `source`, `outcome`, `summary`, `detail?` | 1373-1377 |
| `user_message` | `createdBy`, `creationSource`, `messageId`, `scheduledTaskId?`, `senderThreadId?`, `inputIntent`, `text`, `context?`, `attachments[]` | 1378-1389 |
| `assistant_message` | `messageId`, `text`, `attachments?`, `streaming: bool` | 1390-1397 |
| `reasoning` | `text`, `streaming` | 1398-1403 |
| `proposed_plan` | `planId`, `markdown`, `streaming` | 1404-1410 |
| `todo_list` | `planId`, `steps: PlanStep[]`, `explanation?` | 1411-1417 |
| `user_input_request` | `requestId`, `questions[]`, `questionAnswer?`, `responseMode?: "message"` | 1418-1425 |
| `file_change` | `fileName`, `additions?`, `deletions?`, `diffStr?`, `oldStr?`, `newStr?`, `changes?: {operation, path, oldPath?, fileType?, mimeType?}[]` | 1426-1436 |
| `command_execution` | `input`, `output?`, `outputOmitted?`, `outputIndicatesFailure?`, `exitCode?: Int` | 1437-1446 |
| `file_search` | `pattern?`, `results?: {fileName, line?, column?, preview?}[]` | 1447-1452 |
| `web_search` | `patterns?: string[]`, `results?: {title?, url?, snippet?}[]` | 1453-1458 |
| `approval_request` | `requestId`, `requestKind`, `prompt?`, `appName?`, `options?` | 1459-1469 |
| `checkpoint` | `checkpointId`, `scopeId`, `files: CheckpointFileSummary[]` | 1470-1476 |
| `run_interrupt_request` | `message` | 1477-1481 |
| `run_interrupt_result` | `message` | 1482-1486 |
| `system_notice` | `message` | 1487-1491 |
| `error` | `failure: ProviderFailure`, `retry?: {attempt, maxAttempts: NullOr, retryDelayMs: NullOr}` | 1492-1497 |
| `compaction` | `driver: NullOr`, `summary?`, `beforeTokenCount?`, `afterTokenCount?` | 1498-1505 |
| `handoff` | `contextHandoffId`, `fromProviderThreadIds[]`, `toProviderThreadId`, `fromProviderInstanceIds[]`, `toProviderInstanceId`, `fromModelSelections?`, `toModel?`, `strategy`, `summary?` | 1506-1527 |
| `fork` | `source: {type:"run",threadId,runId}\|{type:"node",nodeId}\|{type:"provider_thread",providerThreadId,providerTurnId?}`, `targetThreadId`, `providerThreadId?` | 1528-1542 |
| `thread_created` | `targetThreadId`, `targetRunId: NullOr`, `targetProviderInstanceId`, `targetModel` | 1543-1550 |
| `secret_request` | `label`, `reason`, `placeholder?`, `secretStatus` (value never on the wire) | 1360-1370, 1551-1554 |
| `subagent` | `subagentId: NodeId`, `origin`, `driver`, `providerInstanceId`, `childThreadId: NullOr`, `prompt`, `progress?`, `result: NullOr` | 1555-1566 |
| `dynamic_tool` | `toolName: NullOr`, `viewedImagePath?`, `input: unknown`, `output?: unknown`, `outputOmitted?` | 1567-1576 |

`OrchestrationV2ProviderFailure` (`packages/contracts/src/orchestrationV2.ts:1281-1288`):
`{ class, message (<= 4096 chars), code: string(<=128)|null, retryable: bool|null, resetAt?: IsoDateTime|null }`.
`ORCHESTRATION_V2_WORKSPACE_PREPARATION_FAILURE_CODE = "workspace_preparation_failed"` is the failure `code` on the
error item a failed workspace preparation leaves (`packages/contracts/src/orchestrationV2.ts:538-539`).

**Forward compatibility:** arrays of turn items (`projection.turnItems`) and projected rows (`visibleTurnItems`,
history page `items`) silently **drop** items whose `type` this build does not know; a known type that fails to decode
still fails (`packages/contracts/src/orchestrationV2.ts:1580-1608`, `packages/contracts/src/baseSchemas.ts:261-285`).
A Swift client must do the same: unknown `type` => skip the row; known `type` with bad payload => treat as a decode error.

`OrchestrationV2ProjectedTurnItem` (`packages/contracts/src/orchestrationV2.ts:1610-1616`) wraps an item for display:
`{ position: NonNegativeInt, visibility: "local" | "inherited" | "synthetic", sourceThreadId, sourceItemId, item }`.
`visibleTurnItems` is the user-visible ordered read model (inherited fork-source rows, synthetic markers, then local rows);
`turnItems` remains the canonical list of items emitted on the thread (`docs/orchestration-v2/core-graph-and-data-model.md:596-606`).

### 1.11 Plans and todo lists

`OrchestrationV2PlanArtifact` (`packages/contracts/src/orchestrationV2.ts:1170-1191`), payload of `plan.updated`, union on
`kind`: base `{ id: PlanId, threadId, runId: NullOr, nodeId, status: draft|active|completed|superseded, detailInTurnItem?: true }` plus
`{ kind: "proposed_plan", markdown }` or `{ kind: "todo_list", steps: PlanStep[], explanation? }`.
`OrchestrationV2PlanStep` (`packages/contracts/src/orchestrationV2.ts:1140-1148`): `{ id, text, status: pending|running|completed, durationAnchorAt?: IsoDateTime, durationMs?: NonNegativeInt }`.
A run that implements a plan carries `sourcePlanRef: { threadId, planId }` (`packages/contracts/src/orchestrationV2.ts:575-580`),
set from `message.dispatch.sourcePlanRef` (`packages/contracts/src/orchestrationV2.ts:2852`). The shell exposes
`hasActionableProposedPlan` (`packages/contracts/src/orchestrationV2.ts:1881`).

### 1.12 Checkpoints

`OrchestrationV2CheckpointScope` (`packages/contracts/src/orchestrationV2.ts:711-723`): `id`, `threadId`, `runId: NullOr`, `nodeId`,
`parentScopeId: NullOr`, `providerThreadId: NullOr`, `kind: root_run | subagent | tool | provider_thread | manual`,
`ordinalWithinParent`, `advancesAppRunCount`, `cwd`, `createdAt`.

`OrchestrationV2Checkpoint` (`packages/contracts/src/orchestrationV2.ts:1202-1215`): `id`, `threadId`, `scopeId`, `runId: NullOr`,
`nodeId`, `parentCheckpointId: NullOr`, `ordinalWithinScope`, `appRunOrdinal: NullOr<PositiveInt>`, `ref: CheckpointRef`
(hidden git ref), `status: ready | missing | error | stale`, `files: { path, kind: string, additions, deletions }[]`, `capturedAt`.

`checkpoint.rollback-requested` payload: `{ scopeId, checkpointId, requestedAt }` (`packages/contracts/src/orchestrationV2.ts:1218-1222`).
`OrchestrationV2CheckpointUnavailableError` message: `Rollback target <target> is unavailable for thread <threadId>.`
(`packages/contracts/src/orchestrationV2.ts:1226-1236`).

### 1.13 Lineage, forks, context transfer and handoff

- `lineage` on the thread (1.5). Fork source points for the `thread.fork` command:
  `{type:"latest_stable"}` | `{type:"run", runId}` | `{type:"checkpoint", checkpointId}` (`packages/contracts/src/orchestrationV2.ts:134-138`).
- `OrchestrationV2ContextTransfer` (`packages/contracts/src/orchestrationV2.ts:166-190`): `id`, `type`, `sourceThreadId`, `targetThreadId`,
  `sourcePoint: { threadId, runId?, checkpointId?, turnItemId?, providerThreadRef?, providerTurnRef? }`, `basePoint: NullOr<sourcePoint>`,
  `sourceProviderInstanceId: NullOr`, `targetProviderInstanceId: NullOr`, `targetRunId: NullOr`,
  `status: pending | resolved_native | resolved_portable | failed | consumed | superseded`,
  `resolution: NullOr<{strategy:"native_fork",providerThreadRef} | {strategy:"portable_context"|"delta_context"|"fork_delta_context"|"checkpoint_context", contextHandoffId}>`,
  `createdBy`, `error: NullOr<string>`, `createdAt`, `updatedAt`, `consumedAt: NullOr`.
- `OrchestrationV2ContextHandoff` (`packages/contracts/src/orchestrationV2.ts:923-967`): `id`, `transferId?: ContextTransferId|null`, `threadId`,
  `targetRunId`, `fromProviderThreadIds[]`, `toProviderThreadId`, `coveredRunOrdinals: {from, to}`,
  `strategy: delta_since_target_last_seen | fork_delta_summary | full_thread_summary | checkpoint_summary | manual_context`,
  `status: pending | ready | failed | superseded`, `summaryMessageId: NullOr`, `summaryText`, `history?`, `delivery?`,
  `detailInTurnItem?: true`, `createdByProviderInstanceId: NullOr`, `createdAt`, `updatedAt`.
- Design semantics (lazy resolution on first run of the fork; same-provider native fork when possible, portable
  handoff otherwise): `docs/orchestration-v2/thread-lineage-and-context-transfer.md:171-197`,
  `docs/orchestration-v2/thread-lineage-and-context-transfer.md:259-271`.

### 1.14 Thread detail projection (the full read model)

`OrchestrationV2ThreadProjection` (`packages/contracts/src/orchestrationV2.ts:1785-1810`):
`{ thread, runs[], attempts[], nodes[], subagents[], providerSessions[], providerThreads[], providerTurns[], runtimeRequests[], messages[], plans[], turnItems[], checkpointScopes[], checkpoints[], contextHandoffs[], contextTransfers[], visibleTurnItems[], updatedAt }`.
All arrays are required keys. This is what `getThreadProjection` returns and what a thread-stream `snapshot` item
carries (possibly bounded/compacted, see section 3).

### 1.15 Stored events and the domain event union

Every committed event has a store-assigned, monotonically increasing `sequence` (the cursor). Envelope:
`OrchestrationV2StoredEvent = { sequence: NonNegativeInt, commandId: CommandId|null, event: DomainEvent }`
(`packages/contracts/src/orchestrationV2.ts:1984-1988`; design: `docs/orchestration-v2/core-graph-and-data-model.md:31-38`).
Event base (`packages/contracts/src/orchestrationV2.ts:1634-1643`): `{ id: EventId, threadId, runId?, nodeId?, driver?, providerInstanceId?, rawEventId?, occurredAt }`.

Every domain event carries the **full current entity** as `payload` (snapshot semantics, not a patch):

| `type` | `payload` | Line |
| --- | --- | --- |
| `thread.created` | AppThread | 1646-1650 |
| `thread.archived`, `thread.unarchived`, `thread.deleted`, `thread.settled`, `thread.unsettled`, `thread.snoozed`, `thread.unsnoozed`, `thread.pinned`, `thread.auto-settle-set`, `thread.unpinned`, `thread.pin-reordered`, `thread.active-reordered`, `thread.visited`, `thread.marked-unread`, `thread.metadata-updated`, `thread.pull-request-synced`, `thread.runtime-mode-updated`, `thread.interaction-mode-updated`, `thread.model-selection-updated`, `thread.provider-switched` | AppThread | 1651-1676 |
| `run.created`, `run.updated` | Run | 1677-1686 |
| `run.background-work-cancelled` | `{ runId, restartCancelledBackgroundWork[] }` | 1687-1691 |
| `run-attempt.created`, `run-attempt.updated` | RunAttempt | 1692-1701 |
| `node.updated` | ExecutionNode | 1702-1706 |
| `subagent.updated` | Subagent | 1707-1711 |
| `provider-session.attached`, `provider-session.updated` | ProviderSession | 1712-1716 |
| `provider-session.detached` | `{ providerSessionId, detachedAt, reason? }` | 1717-1721 |
| `provider-thread.updated` | ProviderThread | 1722-1726 |
| `provider-turn.updated` | ProviderTurn | 1727-1731 |
| `runtime-request.updated` | RuntimeRequest | 1732-1736 |
| `message.updated` | ConversationMessage | 1737-1741 |
| `turn-item.updated` | TurnItem | 1742-1746 |
| `plan.updated` | PlanArtifact | 1747-1751 |
| `checkpoint-scope.created` | CheckpointScope | 1752-1756 |
| `checkpoint.captured` | Checkpoint | 1757-1761 |
| `checkpoint.rollback-requested` | `{ scopeId, checkpointId, requestedAt }` | 1762-1766 |
| `context-handoff.updated` | ContextHandoff | 1767-1771 |
| `context-transfer.created`, `context-transfer.updated` | ContextTransfer | 1772-1781 |

Project changes are *not* in this union; they reach clients as shell `project.updated` / `project.removed` items
(section 3). V2 owns its event schema; V1 command/event unions are gone, project events keep their own application
event shape (`docs/orchestration-v2/README.md:60`).

---

## 3. Events and streams

(Section 2, commands, follows after this section in reading order of importance for the client build; it is
placed below as section 2 for numbering parity with the brief. See "## 2. Commands".)

### 3.1 Transport framing (Effect RPC over WebSocket, JSON)

- The `/ws` route builds an Effect `RpcServer` over the WebSocket with **`RpcSerialization.layerJson`**
  (`apps/server/src/ws.ts:3171-3190`). Effect version 4.0.1 (`pnpm-workspace.yaml:49`; vendored source in
  `.repos/effect-smol`).
- JSON serialization: each WebSocket message is one `JSON.stringify`'d protocol message; on decode a frame may
  hold one message or a JSON array of messages (`.repos/effect-smol/packages/effect/src/rpc/RpcSerialization.ts:129-139`).
  Payloads and results are encoded with `Schema.toCodecJson` (`.repos/effect-smol/packages/effect/src/rpc/RpcSerialization.ts:41`).
- Client -> server messages (`.repos/effect-smol/packages/effect/src/rpc/RpcMessage.ts:71-174`):
  - `{"_tag":"Request","id":<number|string>,"tag":"orchestration.subscribeThread","payload":{...},"headers":[]}`
    (optional `traceId`, `spanId`, `sampled`). The official client numbers requests with an incrementing counter
    (`.repos/effect-smol/packages/effect/src/rpc/RpcClient.ts:217`, `:273`).
  - `{"_tag":"Ack","requestId":<id>}`: acknowledges one stream `Chunk`.
  - `{"_tag":"Interrupt","requestId":<id>}`: cancels a request/stream (unsubscribe).
  - `{"_tag":"Ping"}` -> server answers `{"_tag":"Pong"}` (`.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:806-808`).
    The Effect client pings every 5 s and treats a missing pong as a dead socket
    (`.repos/effect-smol/packages/effect/src/rpc/RpcClient.ts:1205-1227`).
  - `{"_tag":"Eof"}`.
- Server -> client messages (`.repos/effect-smol/packages/effect/src/rpc/RpcMessage.ts:257-358`):
  - `{"_tag":"Chunk","requestId":<id>,"values":[item, ...]}` for stream RPCs (non-empty array of stream items).
  - `{"_tag":"Exit","requestId":<id>,"exit":{"_tag":"Success","value":<result>}}` or
    `{"_tag":"Exit","requestId":<id>,"exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":<TaggedError JSON>} | {"_tag":"Die","defect":<...>} | {"_tag":"Interrupt","fiberId":...}]}}`.
    Unary RPCs answer with exactly one `Exit`; streams end with an `Exit` too.
  - `{"_tag":"Defect","defect":...}` (socket-level), `{"_tag":"Pong"}`, `{"_tag":"ClientProtocolError",...}`.
- **Backpressure / acks are mandatory for streams.** The WebSocket protocol reports `supportsAck: true`
  (`.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:1625`); after writing each `Chunk` the server closes a
  per-request latch and waits until the client sends `Ack` for that `requestId`
  (`.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:401-438`, Ack handling `:199-202`). The Effect client
  sends the Ack right after enqueuing the chunk values (`.repos/effect-smol/packages/effect/src/rpc/RpcClient.ts:570-585`).
  A Swift client that does not Ack will stall every subscription after the first chunk; meanwhile the server buffers
  live events per subscription up to 1,000 items / 8 MiB and then **fails the stream** with
  `LiveStreamBufferError("The live event buffer is full. Resume from the last received sequence.")`
  (`apps/server/src/orchestration-v2/LiveStreamBudget.ts:12-18`, `:66-75`; "including the batch waiting for an RPC ACK", `:39`).
- Failure modes of a request: unknown `tag` -> request-scoped defect `Unknown request tag: <tag>`
  (`.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:785-788`); payload that fails schema decode ->
  request-scoped defect carrying the formatted schema issue (`.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:789-803`).
  The server sets `disableFatalDefects: true`, so a handler defect fails only that request, not the socket
  (`apps/server/src/ws.ts:3120-3127`).
- Unknown JSON keys in payloads are **stripped, not rejected** (Effect Schema default `onExcessProperty: "ignore"`,
  `.repos/effect-smol/packages/effect/src/SchemaAST.ts:463`); unknown *literal values* in known fields are rejected
  by decode.
- `DateTimeUtc` fields encode as `Date.prototype.toISOString()` strings, e.g. `"2026-10-09T09:15:02.123Z"`
  (`.repos/effect-smol/packages/effect/src/Schema.ts:11158-11185`, `:11053-11068`;
  `.repos/effect-smol/packages/effect/src/internal/dateTime.ts:1258`). Decoding accepts any string `DateTime.make`
  parses. Swift: decode with fractional-seconds ISO-8601 and fall back to no fractional seconds.
- Socket connect metadata the server reads from the `/ws` URL (optional, attribution only):
  `clientSurface` (`web|desktop|mobile|cli`), `clientAppVersion` (<= 64 chars), `clientDeviceType`, `clientOs`,
  `clientWebDeployment`, `clientBrowser`, `connectionMethod`, `clientOsMajorVersion`, `clientDeviceModel`
  (`apps/server/src/ws.ts:620-684`; literals in `packages/contracts/src/baseSchemas.ts:345-367`).
  Malformed values are ignored, never fatal (`apps/server/src/ws.ts:620-622`).

### 3.2 Shell stream: `orchestration.subscribeShell`

Input `OrchestrationV2SubscribeShellInput` (`packages/contracts/src/orchestrationV2.ts:3223-3235`):
`{ afterSequence?: NonNegativeInt, requestCompletionMarker?: boolean }` (both `optionalKey`).

Stream item union `OrchestrationV2ShellStreamItem` (`packages/contracts/src/orchestrationV2.ts:1945-1981`):

```jsonc
{ "kind": "synchronized" }                                     // catch-up done marker (only if requested)
{ "kind": "snapshot", "snapshot": ShellSnapshot,
  "resolvedRepositoryIdentityRoots": ["/abs/root", ...] }      // key absent on authoritative snapshots
{ "kind": "project.updated", "sequence": 812, "project": OrchestrationProjectShell }
{ "kind": "project.removed", "sequence": 813, "projectId": "..." }
{ "kind": "thread.updated", "sequence": 815, "location": "active", "thread": ThreadShell }
{ "kind": "thread.removed", "sequence": 816, "location": "active", "threadId": "..." }
```

`ShellSnapshot` = `{ schemaVersion: PositiveInt, snapshotSequence: NonNegativeInt, threads: ThreadShell[], archivedThreads: ThreadShell[], projects: OrchestrationProjectShell[] }`
(`packages/contracts/src/orchestrationV2.ts:1931-1942`). The active shell snapshot always has
`archivedThreads: []` (`apps/server/src/orchestration-v2/ShellStream.ts:21-34`); the initial shell contains active
navigation rows only (`docs/internals/performance-regressions.md:34-35`).

Server behaviour (`apps/server/src/ws.ts:943-1177`):

1. **No `afterSequence`**: load the active shell snapshot (threads + projects + `latestApplicationSequence`, read in
   one transaction, `apps/server/src/orchestration-v2/ShellStream.ts:36-61`) and emit
   `snapshot` (authoritative, no `resolvedRepositoryIdentityRoots`), then optionally a second same-sequence
   `snapshot` that only carries projects whose repository identity already resolved, with `threads: []` and the
   `resolvedRepositoryIdentityRoots` key (`apps/server/src/orchestration-v2/ShellStream.ts:182-212`), then
   `synchronized` if requested, then live deltas after `snapshot.snapshotSequence` (`apps/server/src/ws.ts:1131-1138`).
2. **With `afterSequence`**: if the gap `head - afterSequence` is negative or > `SHELL_RESUME_MAX_GAP = 1000`, or the
   stored payload bytes in the range exceed 8 MiB, fall back to case 1 (full snapshot) (`apps/server/src/ws.ts:546-555`,
   `apps/server/src/ws.ts:686-713`, `apps/server/src/ws.ts:1140-1148`). Otherwise emit only the metadata-only
   enrichment snapshot(s) (never another full shell body, `apps/server/src/orchestration-v2/ShellStream.ts:214-222`),
   then replayed deltas for `(afterSequence, head]`, then `synchronized` if requested, then live deltas
   (`apps/server/src/ws.ts:1150-1159`).
3. Enrichment refreshes (repository identity resolved later) can arrive at any time after the initial frames as
   `snapshot` items with `threads: []`, `archivedThreads: []`, only the changed `projects`, and
   `resolvedRepositoryIdentityRoots` (`apps/server/src/ws.ts:1051-1083`, `apps/server/src/orchestration-v2/ShellStream.ts:160-180`).
   **A client must treat a snapshot that carries `resolvedRepositoryIdentityRoots` as a project-metadata patch, not
   as a replacement of the thread list.** Repeated identical refreshes are deduped server-side
   (`apps/server/src/orchestration-v2/ShellStream.ts:117-158`).

Delta derivation:

- Every stored application event (project events and v2 thread events) is mapped to its aggregate; within a
  50 ms / 512-event window only the newest event per project/thread is kept, sorted by sequence
  (`apps/server/src/ws.ts:1032-1038`, `apps/server/src/orchestration-v2/ShellStream.ts:85-100`).
- For a thread event, the server re-reads the current thread shell and emits `thread.updated` (or
  `thread.removed` when the shell is archived or gone) with the **sequence of the newest coalesced event**
  (`apps/server/src/orchestration-v2/ShellStream.ts:288-319`). Archiving therefore shows up on the active stream
  as `thread.removed` with `location: "active"`.
- For a project event, `project.deleted` (or a missing project) -> `project.removed`, otherwise `project.updated`
  with the current project shell (`apps/server/src/ws.ts:985-1009`).
- Unchanged shells are suppressed: a `thread.updated` identical to the last one sent on this subscription (ignoring
  `updatedAt`) is dropped unless the last send is >= 5 s old (`apps/server/src/orchestration-v2/ShellStream.ts:224-273`).
  Consequence: **the shell `sequence` the client holds can lag the head by up to ~5 s of skipped deltas**; a resume
  replays them (harmless).
- `sequence` values on the shell stream are **global application sequences**, strictly increasing within one
  subscription but with gaps (other threads' coalesced events, suppressed duplicates). Gaps are normal and do not
  indicate loss. Use `max(sequence seen)` as the resume cursor.
- Live delivery is buffered with the live-stream budget (`apps/server/src/ws.ts:1040-1048`); overflow fails the stream
  with `OrchestrationV2GetShellSnapshotError { message: "Failed while streaming the application shell" }`
  (`apps/server/src/ws.ts:1171-1180`). Resubscribe with `afterSequence`.

HTTP alternative for the first load: `GET /api/orchestration/shell` returns the same `OrchestrationV2ShellSnapshot`
(projects enriched with whatever identity is immediately available), requires scope `AuthOrchestrationReadScope`
and header `x-t3-orchestration-protocol: 2` (`packages/contracts/src/environmentHttp.ts:608-615`,
`apps/server/src/orchestration-v2/http.ts:78-89`, `apps/server/src/orchestration-v2/http.ts:151-164`). Then
subscribe with `afterSequence = snapshot.snapshotSequence`.

### 3.3 Archived shell: `orchestration.subscribeArchivedShell` / `getArchivedShellSnapshot`

Input `{}`. Items (`packages/contracts/src/orchestrationV2.ts:3155-3180`):
`{ kind: "snapshot", snapshot: { schemaVersion, snapshotSequence, projects[], threads[] } }`,
`{ kind: "thread.updated", sequence, thread }`, `{ kind: "thread.removed", sequence, threadId }` (no `location`).
Server: always starts with a full archived snapshot (no resume input), then live: thread events are coalesced per
thread (50 ms / 512) and mapped by `archivedShellStreamItemFromThreadShell`: archived shell -> `thread.updated`;
`thread.unarchived`, or `thread.deleted` of an archived thread -> `thread.removed`; everything else is dropped
(`apps/server/src/ws.ts:1774-1806`, `apps/server/src/orchestration-v2/ShellStream.ts:321-344`).

### 3.4 Thread detail stream: `orchestration.subscribeThread`

Input `OrchestrationV2SubscribeThreadInput` (`packages/contracts/src/orchestrationV2.ts:3238-3257`), all `optionalKey`
except `threadId`:

```jsonc
{
  "threadId": "a1b2...",
  "afterSequence": 1234,            // resume: replay events after this sequence instead of a snapshot
  "requestCompletionMarker": true,  // emit {"kind":"synchronized"} between catch-up and live
  "acceptBoundedSnapshot": true,    // snapshot fallbacks may be a bounded recent window with a history cursor
  "acceptCompactTurnItems": true    // bounded snapshots may omit turnItems that repeat local visible rows
}
```

Item union `OrchestrationV2ThreadStreamItem` (`packages/contracts/src/orchestrationV2.ts:3366-3392`):

```jsonc
{ "kind": "synchronized" }
{ "kind": "snapshot", "snapshotSequence": 1234, "projection": ThreadProjection,
  "historyCursor": "opaque" | null,        // optionalKey; present on bounded snapshots
  "hasMoreHistory": true,                   // optionalKey
  "latestLocalTurnOrdinal": 57 | null,      // optionalKey
  "payloadBudgetExceeded": false,           // optionalKey
  "turnItemsOmitLocalVisible": true }       // optionalKey, only for clients that sent acceptCompactTurnItems
{ "kind": "event", "sequence": 1240, "event": DomainEvent }
```

Decode-only forward-compat arm: an `event` whose `event.type` is unknown, or a `turn-item.updated` whose payload
`type` is unknown, decodes to `{ kind: "unknown-event", sequence, eventType }`; clients skip it **but still advance
their resume cursor** (`packages/contracts/src/orchestrationV2.ts:3320-3364`). A known type whose payload fails to
decode still fails the stream.

Server behaviour (`apps/server/src/ws.ts:747-940`):

1. Before anything, a V1-imported thread's transcript is hydrated (`ensureLegacyTranscript`, `apps/server/src/ws.ts:761-770`).
2. **No `afterSequence`** -> `snapshotThenLive` (`apps/server/src/ws.ts:826-857`):
   - with `acceptBoundedSnapshot: true`: a bounded window (`getThreadSnapshotWindow` with
     `rowLimit = THREAD_HISTORY_SNAPSHOT_ROW_LIMIT (= 75 + 2)` and `userTurnLimit = 10`), wire-projected, plus history
     metadata (`apps/server/src/orchestration-v2/ThreadStream.ts:70-88`, `apps/server/src/orchestration-v2/threadHistoryPaging.ts:13-28`);
   - otherwise a **legacy full snapshot** `{ kind:"snapshot", snapshotSequence, projection }` (full projection,
     wire-projected, no history keys);
   - then `synchronized` (if requested), then live events with `sequence > snapshotSequence`.
3. **With `afterSequence`** (`apps/server/src/ws.ts:869-937`):
   - `highWater = latestAgentSequence(threadId)`; if `afterSequence > highWater` -> snapshot path;
   - replay stats over `(afterSequence, highWater]`: if more than `THREAD_RESUME_MAX_REPLAY_EVENTS = 128` events or
     more than 1 MiB of stored payload -> snapshot path (`apps/server/src/orchestration-v2/ThreadStream.ts:14-30`);
   - if the range contains the thread's create event and the thread still exists (a deleted-then-recreated thread)
     -> snapshot path (`apps/server/src/ws.ts:908-919`);
   - load and wire-project the replay; if the projected replay exceeds 1 MiB of JSON -> snapshot path
     (`apps/server/src/orchestration-v2/ThreadStream.ts:98-124`);
   - otherwise emit the replayed `event` items, then `synchronized` (if requested), then live events after `highWater`.
   So **a resume may answer with a `snapshot` item instead of events**; the client must accept either and treat a
   snapshot as a full reset of thread state at `snapshotSequence`.
4. Live events: `streamStoredEventsFrom({ threadId, afterSequence })` mapped to `{kind:"event", sequence, event: projectDomainEventForWire(event)}`
   and passed through the live coalescer (`apps/server/src/ws.ts:772-791`).
5. Errors are `OrchestrationV2GetThreadProjectionError { threadId, message, cause? }` with messages such as
   `Failed to load orchestration V2 thread <id>`, `Failed while streaming orchestration V2 thread <id>`,
   `Failed while replaying orchestration V2 thread <id>`, `Failed to hydrate migrated thread <id>`
   (`apps/server/src/ws.ts:761-937`).

**Sequence semantics on the thread stream.** `sequence` is the store-wide event sequence (shared with other threads
and projects), so consecutive thread events have gaps by design. In addition the live coalescer drops intermediate
`turn-item.updated` events (see 3.6). Clients must therefore **never treat a gap as data loss**; dedupe by
`sequence <= lastApplied` and keep `lastApplied = max(sequence)` (including `unknown-event` sequences) as the resume cursor.

### 3.5 Bounded snapshots and history paging over HTTP

HTTP endpoints (all `GET`, header `x-t3-orchestration-protocol: 2`, authenticated, scope `AuthOrchestrationReadScope`;
`packages/contracts/src/environmentHttp.ts:583-641`, handlers `apps/server/src/orchestration-v2/http.ts:151-234`):

| Endpoint | Query | Response | Notes |
| --- | --- | --- | --- |
| `/api/orchestration/shell` | - | `OrchestrationV2ShellSnapshot` | 3.2 |
| `/api/orchestration/threads/:threadId` | - | `OrchestrationV2ThreadDetailSnapshot` `{snapshotSequence, projection}` | full, wire-projected projection |
| `/api/orchestration/threads/:threadId/bounded` | `compactTurnItems=1` (optional; other values ignored) | `OrchestrationV2ThreadBoundedSnapshot` | recent window, 3.5.1 |
| `/api/orchestration/threads/:threadId/history` | `cursor` (required), `throughEntryId?`, `view?=conversation\|activity` | `OrchestrationV2ThreadHistoryPage` | older rows, 3.5.2 |

Error reasons: `thread_not_found` (404 `EnvironmentResourceNotFoundError`), `invalid_history_cursor` (400
`EnvironmentRequestInvalidError { code: "invalid_request", reason, traceId }`), internal
`orchestration_snapshot_failed | orchestration_thread_snapshot_failed | orchestration_thread_bounded_snapshot_failed | orchestration_thread_history_failed`
(`packages/contracts/src/environmentHttp.ts:94-139`, `apps/server/src/orchestration-v2/http.ts:91-149`, `:201-233`).

#### 3.5.1 Bounded snapshot (recent window)

`OrchestrationV2ThreadBoundedSnapshot` (`packages/contracts/src/orchestrationV2.ts:3278-3302`):

```jsonc
{
  "snapshotSequence": 1234,
  "projection": { /* full control-plane arrays, recent timeline window only */ },
  "historyCursor": "eyJ2IjoxLC...",   // opaque, null when nothing older
  "hasMoreHistory": true,
  "latestLocalTurnOrdinal": 57,       // max local turn ordinal over the FULL projection, or null
  "payloadBudgetExceeded": false,     // optional: complete turns or live control state exceeded the byte budget
  "turnItemsOmitLocalVisible": true   // optionalKey: only when the client opted in (compactTurnItems=1 / acceptCompactTurnItems)
}
```

- Window policy: `THREAD_HISTORY_PAGE_POLICY = { maxUserTurns: 10, maxItems: 75, maxEncodedBytes: 1_048_576 }`,
  snapshot row limit `75 + 2` (`apps/server/src/orchestration-v2/threadHistoryPaging.ts:9-28`). "Client cold opens
  target 75 recent timeline rows and about 1 MiB of encoded data. Required control records and the
  at-least-one-row rule can exceed the byte target" (`docs/internals/performance-regressions.md:15-17`). The bounded
  snapshot does not retain the full duplicate conversation-message table (`docs/internals/performance-regressions.md:18`).
  Rows are selected backward through *complete user turns*; steering messages do not consume a turn slot
  (`apps/server/src/orchestration-v2/threadHistoryPaging.ts:165-200`).
- **Compact form**: with the marker, `projection.turnItems` omits the leading entries that duplicate local visible rows;
  restore before use: `turnItems = visibleTurnItems.filter(isLocal).map(row => row.item) + turnItems`, where
  `isLocal(row) = row.visibility === "local" || row.sourceThreadId === projection.thread.id`
  (`packages/shared/src/orchestrationV2BoundedSnapshot.ts:6-58`; server half `omitLocalVisibleTurnItems`,
  `packages/shared/src/orchestrationV2BoundedSnapshot.ts:14-34`).
- The same bounded representation is used for socket snapshot fallbacks when `acceptBoundedSnapshot: true`
  (`apps/server/src/orchestration-v2/ThreadStream.ts:47-88`). Resume the socket with `afterSequence = snapshotSequence`
  (`packages/contracts/src/orchestrationV2.ts:3278-3282`).
- The legacy `orchestration.getThreadProjection` RPC is also bounded now (75+2 rows, wire-projected) "so stale clients
  cannot materialize an unbounded transcript" (`apps/server/src/ws.ts:1920-1947`); do not use it for full history.

#### 3.5.2 History pages

`GET /api/orchestration/threads/:threadId/history?cursor=<historyCursor>[&throughEntryId=<id>][&view=conversation|activity]`
returns `OrchestrationV2ThreadHistoryPage` (`packages/contracts/src/orchestrationV2.ts:3305-3317`):

```jsonc
{
  "snapshotSequence": 1234,
  "items": [ /* ProjectedTurnItem rows, chronological (oldest first) */ ],
  "nextCursor": "eyJ2IjoxLC..." ,   // null at the start of history
  "hasMoreHistory": true
}
```

- The cursor is opaque to clients ("clients must not parse it", `packages/contracts/src/orchestrationV2.ts:3278-3282`);
  server-side it is base64url JSON `{ v: 1, seq, st, si, p }` (snapshot sequence, source thread id, source item id,
  position), max 4096 chars (`apps/server/src/orchestration-v2/threadHistoryPaging.ts:30-46`,
  `apps/server/src/orchestration-v2/threadHistoryPaging.ts:110-158`). Malformed -> HTTP 400 `invalid_history_cursor`.
- Older pages allow up to `OLDER_THREAD_USER_TURN_LIMIT = 20` user turns (`apps/server/src/orchestration-v2/threadHistoryPaging.ts:19`).
- `view=conversation` first loads conversation rows (excludes `command_execution`, `reasoning`, `file_change`,
  `dynamic_tool`, `apps/server/src/orchestration-v2/threadHistoryPaging.ts:22-25`); the official client uses it only
  when jumping to an entry (`throughEntryId`), then loads the complete page (`packages/client-runtime/src/state/threads.ts:687-725`).
- Unknown turn item types in `items` are dropped on decode (`packages/contracts/src/orchestrationV2.ts:3308-3314`).

### 3.6 Wire projection (what the server strips before sending)

Applied to every snapshot, replayed event and live event (`apps/server/src/orchestration-v2/WireProjection.ts:210-241`):

| Item / entity | On the wire | Source |
| --- | --- | --- |
| `command_execution` | `output` removed; `outputOmitted: true` if output was non-blank; `outputIndicatesFailure: true` if flagged, non-zero `exitCode`, or the output looked like a failure | `WireProjection.ts:82-96` |
| `file_change` | `diffStr`, `oldStr`, `newStr` removed (fetch diffs via `getTurnDiff`/`getFullThreadDiff`); a *failed* edit keeps `diffStr` truncated to 32 KiB (it holds the provider error) | `WireProjection.ts:97-105` |
| `dynamic_tool` | `input` replaced by itself if <= 16 KiB JSON, else `{ summary: <first line, <=160 chars>, truncated: true }`; `output` compacted (`compactDynamicToolOutput`); `outputOmitted: true` when there was output | `WireProjection.ts:37-74`, `:113-122` |
| `subagent` | `prompt`, `progress`, `result` truncated to 32 KiB with suffix `"\n… output truncated for transport"` | `WireProjection.ts:14-35`, `:106-112` |
| `handoff` | `summary` removed | `WireProjection.ts:78-81` |
| `ContextHandoff` entity | `history` and `delivery` removed; `summaryText: ""` | `WireProjection.ts:203-208` |
| everything else | unchanged | `WireProjection.ts:123-125` |

Full bodies: `orchestration.getTurnItem({ threadId, itemId, revision? })` returns `{ item: TurnItem | null }`
with input/output bounded to 256 KiB, tool-output image bytes left out (loaded as `tool-output-image` assets)
(`apps/server/src/orchestration-v2/WireProjection.ts:150-201`, `packages/contracts/src/orchestrationV2.ts:3458-3470`).
`revision` is "the item updatedAt the client last saw. Only keys the client cache" (`packages/contracts/src/orchestrationV2.ts:3461`).
Persisted events remain complete (`docs/internals/performance-regressions.md:30-33`).

### 3.7 Live coalescing and budgets on the thread stream

- `coalesceThreadLiveStream` (`apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts:238-255`): `turn-item.updated`
  events whose payload has `status: "running"` and `type` in {`command_execution`, `file_change`, `file_search`,
  `web_search`, `dynamic_tool`} are held for a 50 ms window (max 512 pending); within the window only the **latest
  update per item id** (keyed by thread, run, item id) survives, in sequence order
  (`apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts:18-86`). Any other event (including terminal tool
  updates, assistant text, run updates) flushes the window immediately and is never dropped
  (`apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts:146-191`). Replayed catch-up events are not coalesced.
- Per-subscription live buffer: 1,000 items / 8 MiB including the batch awaiting the RPC Ack; overflow fails the
  stream; resume from the last received sequence (`apps/server/src/orchestration-v2/LiveStreamBudget.ts:12-18`,
  `:39`, `:66-75`).

### 3.8 How streaming assistant text arrives

- There are **no text deltas on the wire**. Assistant and reasoning text arrive as repeated `turn-item.updated`
  events for the same item id (`assistant_message` / `reasoning`, `streaming: true`) whose `text` is the **full text so
  far**, followed by a final update with `streaming: false` (and `message.updated` events for the
  `ConversationMessage` with the same semantics). Clients replace the item by id (3.9).
- Server-side buffering (`apps/server/src/orchestration-v2/assistantStreaming.ts:91-129`, applied before events are
  stored, `apps/server/src/orchestration-v2/RunExecutionService.ts:1187-1196`):
  - `running` `node.updated` events for `assistant_message` nodes are dropped;
  - in `responseStreamingMode: "turn"` no streaming updates are stored at all, only the final message;
  - in `"paragraph"` mode (the default, `packages/contracts/src/settings.ts:992-999`, `:1133-1135`) a streaming update
    is stored at most every 400 ms per message, and its `text` is truncated to the last *stable markdown boundary*
    (blank line, closing code fence, list-item start, top-level heading; a section title waits for content) so
    unfinished markdown never reaches clients (`apps/server/src/orchestration-v2/assistantStreaming.ts:22-89`).
  - The final (`streaming: false`) update always passes through with the complete text
    (`apps/server/src/orchestration-v2/assistantStreaming.ts:110-113`).
- A client therefore never needs to concatenate; render `text` as-is, and treat `streaming: true` as "more may follow".

### 3.9 Client application semantics (official `packages/client-runtime`)

**Shell** (`packages/client-runtime/src/state/shellReducer.ts`):

- Authoritative `snapshot` (no `resolvedRepositoryIdentityRoots`): replaces projects, threads and
  `snapshotSequence` even if lower than the cached one, but keeps a previously resolved non-null
  `repositoryIdentity` for a project with the same `workspaceRoot` while the new one is still null
  (`packages/client-runtime/src/state/shellReducer.ts:79-133`). Unchanged rows keep object identity
  (`reuseUnchangedThreadShells`, `packages/client-runtime/src/state/shellReducer.ts:21-45`).
- Enrichment `snapshot` (with `resolvedRepositoryIdentityRoots`): patches only `repositoryIdentity` of existing projects
  with matching id and `workspaceRoot`; listed roots accept the identity exactly (including null); never touches
  threads, archives or sequence (`packages/client-runtime/src/state/shellReducer.ts:99-120`).
- Deltas (`applyShellStreamEvent`, `packages/client-runtime/src/state/shellReducer.ts:135-200`):
  - ignore if `event.sequence <= snapshot.snapshotSequence`;
  - `project.updated`: upsert by id (append if new), keep prior identity if the new one is null for the same root;
  - `project.removed`: remove by id;
  - `thread.updated` with `location: "active"`: upsert by id (append if new) and remove from `archivedThreads`; if
    the shell is deep-equal to the existing row only the cursor moves; with `location: "archive"` (older servers)
    remove it from the active list;
  - `thread.removed`: remove from both lists;
  - every applied delta sets `snapshotSequence = event.sequence`.
  Order within the array is insertion order; the sidebar sorts separately (section 4).

**Thread detail** (`packages/client-runtime/src/state/threads.ts:440-611`,
`packages/client-runtime/src/state/orchestrationV2Projection.ts:152-286`):

- Items are applied in arrival order under one lock. `event` and `unknown-event` items are deduped against
  `lastSequence` (`item.sequence <= lastSequence` is skipped) and advance it, including unknown ones
  (`packages/client-runtime/src/state/threads.ts:444-468`). A `thread.deleted` event marks the thread deleted and stops
  applying (`packages/client-runtime/src/state/threads.ts:486-497`, `:550-556`).
- `snapshot` item: `lastSequence = snapshotSequence`; projection replaced by `boundedSnapshotProjection(item)`;
  history metadata reset from the item when it has any progressive key, else cleared
  (`packages/client-runtime/src/state/threads.ts:584-611`).
- `synchronized` item: status becomes `live` (`packages/client-runtime/src/state/threads.ts:571-582`).
- Event reducer `applyOrchestrationV2ProjectionEvent` (ignores events for another thread id; `updatedAt :=
  event.occurredAt` for everything except `thread.visited` / `thread.marked-unread`):
  - all `thread.*` events (including `thread.created`): `projection.thread = payload` (full replace);
  - `run.created|updated`: upsert run by id, then recompute visibility of local rows;
  - `run.background-work-cancelled`: set that run's `restartCancelledBackgroundWork`;
  - `run-attempt.*`: upsert by id, recompute visibility;
  - `node.updated`, `subagent.updated`, `provider-thread.updated`, `runtime-request.updated`, `message.updated`,
    `plan.updated`, `checkpoint-scope.created`, `checkpoint.captured`, `context-handoff.updated`,
    `context-transfer.*`: upsert by `id` (append if new, replace whole object otherwise);
  - `provider-session.attached|updated`: upsert; `provider-session.detached`: remove the session by id;
  - `provider-turn.updated`: upsert, but keep the previous `tokenUsage` when the new payload omits it;
  - `checkpoint.rollback-requested`: no state change except `updatedAt`;
  - `turn-item.updated`: upsert into `turnItems`; then if the item is visible
    (`isOrchestrationV2TurnItemVisible`) upsert a **local** row `{ visibility: "local", sourceThreadId: item.threadId, sourceItemId: item.id, item }`
    into `visibleTurnItems` at the position ordered by `(item.ordinal, item.id)` among local rows (inherited rows
    are untouched), else remove its row; positions are renumbered 0..n-1. Only `run_interrupt_request` changes
    trigger a full visibility recheck (`packages/client-runtime/src/state/orchestrationV2Projection.ts:251-273`).
  - Partial (bounded) timelines: an update for an item not present in the window whose ordinal is `<=
    latestLocalTurnOrdinal` (or older than the oldest local row) is dropped, so old items do not appear out of place
    (`packages/client-runtime/src/state/orchestrationV2Projection.ts:89-106`); otherwise the watermark advances
    (`packages/client-runtime/src/state/threads.ts:518-527`).
- Visibility rules (`packages/shared/src/orchestrationV2Timeline.ts:42-112`): hide items of `rolled_back` runs; hide
  `user_message` with `inputIntent: "queued_turn"` whose run is `cancelled` (queued input never reached the provider);
  hide a `run_interrupt_result` on a superseded attempt root unless the run has a `run_interrupt_request`
  (paired stop-then-steer stays visible).
- Older pages merge with `mergeOlderHistoryIntoProjection` (`packages/client-runtime/src/state/threadHistoryMerge.ts:62-131`):
  dedupe by `sourceThreadId:sourceItemId`; rows already present keep their live values; local items already known
  in `turnItems` are not re-added unless they are `run_interrupt_request` items that are visible; page rows are
  prepended in server order; positions renumbered; history meta becomes `{ historyCursor: page.nextCursor, hasMoreHistory: page.hasMoreHistory, expanded: true }`
  keeping `latestLocalTurnOrdinal` (`packages/client-runtime/src/state/threadHistoryMerge.ts:133-149`). A page response is
  discarded if the history cursor changed while it was in flight (`packages/client-runtime/src/state/threadHistoryMerge.ts:30-36`).
  Show "load earlier" when `hasMoreHistory || error !== null` (`packages/client-runtime/src/state/threadHistoryMerge.ts:151-154`).

---

## 4. Derived UI state (how official clients present threads)

All derivations below run on the **thread shell** (`OrchestrationV2ThreadShell`) unless noted; the clients never
derive settlement from their own clocks or PR caches ("Clients render the persisted result",
`docs/internals/overview.md:87-96`).

### 4.1 Normalized row model (`presentThreadShell`)

`packages/client-runtime/src/state/models.ts:208-292` converts a shell into `EnvironmentThreadShell`:

- `latestRun` = `null` if `latestRunId === null`, else
  `{ runId: latestRunId, status: status === "idle" ? "completed" : status, requestedAt: latestRunRequestedAt, startedAt: latestRunStartedAt, completedAt }`
  where `completedAt` = `latestRunCompletedAt` when the key is present, otherwise `updatedAt` if status is `idle` or
  terminal (`completed|interrupted|failed|cancelled|rolled_back`), else null (`models.ts:212-229`, terminal set `models.ts:156-164`).
- `runtime` (`shellRuntime`, `models.ts:174-199`): `null` when `latestRunId === null && activeProviderThreadId === null`
  and no completion-holding background work; else `status = parkAtIdle ? "idle" : (activityRunStatus ?? status)` where
  `parkAtIdle = backgroundWorkHoldsCompletion(pendingBackgroundTasks) && status !== "failed"`; plus `activeRunId`,
  `activityStartedAt`, `lastError`, `lastErrorClass`, `usageLimitResetAt`.
  `backgroundWorkHoldsCompletion`: subagents, monitors and unknown/`background_task` kinds hold completion;
  `command` (e.g. a dev server left running) does not (`packages/shared/src/orchestrationV2PendingBackgroundWork.ts:62-80`).
- `hasPendingApprovals = pendingRuntimeRequest !== null && kind !== "user_input" && kind !== "auth_refresh"`;
  `hasPendingUserInput = pendingRuntimeRequest?.kind === "user_input"` (`models.ts:256-260`).
- Subagent threads get a display title via `formatSubagentDisplayTitle` (`models.ts:236-239`).
- Navigation lists exclude archived threads and `lineage.relationshipToParent === "subagent"` threads
  (`packages/client-runtime/src/state/threadShell.ts:202-215`, `apps/web/src/components/Sidebar.logic.ts:566-583`).

### 4.2 Thread status (sidebar row)

Web/desktop sidebar (current `Sidebar.tsx`), `resolveSidebarThreadStatus` (`apps/web/src/components/Sidebar.logic.ts:983-1013`),
evaluated in priority order:

1. `hasPendingApprovals` -> `approval`
2. `hasPendingUserInput` -> `input`
3. `runtime.status` in {`preparing`, `queued`, `starting`, `running`, `waiting`} -> `working`
4. `runtime.status === "idle"` (parked on background work) -> `waiting`
5. `runtime.status === "failed"` -> `limited` if `lastErrorClass === "usage_limit"`, else `failed`
6. otherwise -> `ready`

Top pill (`resolveSidebarV2TopStatus`, `apps/web/src/components/Sidebar.logic.ts:1015-1039`): `working` | `waiting` |
`approval` | `input` | `failed` | `limited`, else `woke` if woken from snooze, else `done` if unread, else no pill.
`working` is labelled "Goal" when `goal.status === "active"` (`apps/web/src/components/Sidebar.tsx:1291-1299`). A
working duration is shown only for `working` (`apps/web/src/components/Sidebar.logic.ts:1041-1046`), counted from
`resolveThreadWorkingStartedAt` (activity run's work start, `packages/client-runtime/src/state/models.ts:318-336`) and
formatted `Ns`, `Nm`, `Nh Mm` (`apps/web/src/components/Sidebar.logic.ts:1156-1162`).

Legacy sidebar pill (`resolveThreadStatusPill`, `apps/web/src/components/Sidebar.logic.ts:1164-1242`) for reference,
priority: Pending Approval > Awaiting Input > Working (`running|waiting`) > Connecting (`preparing|starting|queued`) >
Waiting (completion-holding background work) > Plan Ready (`interactionMode === "plan"`, latest run settled,
`hasActionableProposedPlan`) > Completed (unseen completion) > none. Project-level indicator takes the highest
priority among its threads: approval 5, input 4, working/connecting 3, waiting 2.5, plan ready 2, completed 1
(`apps/web/src/components/Sidebar.logic.ts:640-648`, `:1244-1260`).

Notes for parity:

- "working" includes run status `waiting`. In the run lifecycle `waiting` is also used after a successful turn while
  the checkpoint is captured ("a successful turn persists as waiting until checkpoint capture flips it to completed",
  `packages/shared/src/orchestrationV2PendingBackgroundWork.ts:31-37`), so threads look "working" until the checkpoint lands.
- Failure detail for the row comes from `lastError` / `lastErrorClass` / `usageLimitResetAt`, computed server-side
  with `threadErrorSummary` (`packages/shared/src/orchestrationV2ThreadError.ts:35-49`): a distinct session error
  supersedes the turn's failure class.

### 4.3 Unread, read receipts, "woke"

- Server-side read receipt: `lastVisitedAt` on the thread (and shell). `thread.visit { visitedAt }` advances it to
  `max(stored, visitedAt)` and does not change `updatedAt` (`packages/contracts/src/orchestrationV2.ts:2723-2733`,
  `docs/internals/performance-regressions.md:80-82`). `thread.mark-unread` rewinds it (section 2). Capability flag
  `threadVisitedTracking` (`packages/contracts/src/environment.ts:164-168`).
- Effective watermark (`resolveThreadLastVisitedAt`, `apps/web/src/components/Sidebar.logic.ts:756-771`): if the shell
  has the `lastVisitedAt` key, the server value is authoritative (null = never visited); if the key is absent (old
  server) use the client's locally persisted watermark.
- Unread (`hasUnseenCompletion`, `apps/web/src/components/Sidebar.logic.ts:773-782`):
  `latestRun.completedAt` exists and parses, **and** `lastVisitedAt` is non-null, and `completedAt > lastVisitedAt`
  (an unparseable `lastVisitedAt` counts as unread). A never-visited thread is **not** unread ("never-visited counts as
  read", `apps/web/src/components/Sidebar.tsx:1261-1263`).
- When to send `thread.visit` (web `ChatView`, `apps/web/src/components/ChatView.tsx:2938-2998`): while a thread is
  open, whenever `shell.updatedAt > effective lastVisitedAt`, dispatch `thread.visit` with
  `visitedAt = shell.updatedAt` (the ISO string from the shell), deduped per `threadKey:updatedAt`; immediately when
  there is an unseen completion, otherwise throttled to one dispatch per 10 s (`VISIT_DISPATCH_THROTTLE_MS = 10_000`,
  `apps/web/src/components/ChatView.tsx:622`). Mobile does the same on the thread screen with the selected thread's
  `updatedAt` (`apps/mobile/src/features/threads/ThreadDetailScreen.tsx:849-900`). Failures are not reported
  (`reportFailure: false`). A one-time migration pushes local watermarks to servers that gained tracking
  (`apps/web/src/hooks/useThreadVisitedMigration.ts:24-44`).
- "Woke" (snooze ended): `threadWokeAt` (`packages/client-runtime/src/state/threadSettled.ts:177-218`); the row is woke
  when `wokeAt` is after the effective `lastVisitedAt` and the thread is not settled
  (`apps/web/src/components/Sidebar.tsx:1265-1279`).

### 4.4 Sections and sort order (web/desktop `Sidebar.tsx`)

Section per thread (`resolveSidebarThreadSection`, `apps/web/src/components/Sidebar.logic.ts:138-147`;
classification `apps/web/src/components/Sidebar.tsx:2793-2848`), first match wins:

1. **Snoozed**: capability `threadSnooze` and `effectiveSnoozed(thread, now)`: `snoozedUntil` parses and is in the
   future and the thread has not "raised its hand" (pending approval/input, a session failure newer than `snoozedAt`,
   or a run completed after `snoozedAt`) (`packages/client-runtime/src/state/threadSettled.ts:80-176`).
2. **Settled**: capability `threadSettlement` and `settledOverride === "settled"`.
3. **Pinned**: `pinnedAt != null`.
4. **Active** (or **Working** when the per-device "Working section (beta)" is on and `isThreadWorking`,
   `packages/client-runtime/src/state/threadInbox.ts:17-34`).

Sorting:

| Section | Comparator | Source |
| --- | --- | --- |
| Pinned | threads with `pinOrderKey` first by plain string compare (id, then environmentId tiebreak); then keyless threads newest `createdAt` first | `packages/client-runtime/src/state/threadSort.ts:300-338` |
| Active | threads **without** `activeOrderKey` first, newest anchor first where anchor = `max(createdAt, unsettledAt)`; then keyed threads by string compare; tiebreak id, environmentId. Activity does not reorder. | `packages/client-runtime/src/state/threadSort.ts:120-138`, `:340-371` |
| Active with Working beta | newest "return" first: `max(createdAt, unsettledAt, latestRun.requestedAt, latestRun.completedAt, locally observed return)` | `packages/client-runtime/src/state/threadInbox.ts:41-62` |
| Working (beta) | newest of `max(createdAt, latestUserAuthoredMessageAt ?? latestRun.requestedAt)` | `packages/client-runtime/src/state/threadInbox.ts:64-89` |
| Snoozed | soonest `snoozedUntil` first | `apps/web/src/components/Sidebar.tsx:2874-2880` |
| Settled | newest `resolveSettledThreadTimestamp` first: `settledAt`, else latest of `latestUserMessageAt`/`latestRun.*`, else `updatedAt`; id tiebreak | `packages/client-runtime/src/state/threadSort.ts:23-69` |

Order keys are fractional-index strings over `a`-`z` (no trailing `a`), compared with plain `<`. Moving a row writes
one key to one thread (`pinOrderKeyBetween`); if a neighbour is keyless the whole section is re-keyed once with
`generateSpreadPinOrderKeys` (`packages/client-runtime/src/state/threadSort.ts:177-301`). Active reordering uses the
same planner with `activeOrderKey` values (`packages/client-runtime/src/state/threadSort.ts:254-263`). New threads appear
above arranged ones; settling clears the active key; un-settle returns a thread to the top (`docs/user/thread-sidebar.md:97-100`).

### 4.5 Relative timestamps

- Row time (`threadTimeLabel`, `apps/web/src/components/Sidebar.tsx:332-335`): `latestUserMessageAt ?? updatedAt`.
  Settled rows use `resolveSettledThreadTimestamp` (`apps/web/src/components/Sidebar.tsx:337-343`).
- Format (`formatRelativeTime`, `apps/web/src/timestampFormat.ts:235-248`): future or < 60 s -> "just now"; < 60 min ->
  `Nm ago`; < 24 h -> `Nh ago`; else `Nd ago` (floor). The sidebar compacts "just now" to "now" and strips " ago"
  (`apps/web/src/components/Sidebar.tsx:327-330`).
- Snoozed rows show a "wakes in" label: `Nm` (ceil, min 1), `Nh`, `Nd` (`packages/client-runtime/src/state/threadSettled.ts:305-319`).

### 4.6 Snooze presets and settle eligibility (client-side twins of server rules)

- `canSnooze`: not while a pending approval/input exists or a turn start is queued (`packages/client-runtime/src/state/threadSettled.ts:129-153`).
- Presets: In 1 hour, In 3 hours, This evening (18:00, only if > 1 h away), Tomorrow 09:00, Next week (Monday 09:00,
  omitted when equal to Tomorrow) (`packages/client-runtime/src/state/threadSettled.ts:229-299`). Custom date/time or
  duration via `resolveCustomSnooze` (`packages/client-runtime/src/state/threadSettled.ts:320-354`).
- `hasQueuedTurnStart`: runtime `preparing|queued|starting`, or a user message newer than every latest-run timestamp
  within a 2-minute grace window (`packages/client-runtime/src/state/threadSettled.ts:32-78`).

### 4.7 How the server derives the shell row fields

`threadShellFromProjection` (`apps/server/src/orchestration-v2/ProjectionStore.ts:1372-1508`; the SQL path builds the
same fields in `shellFromState`, `apps/server/src/orchestration-v2/ProjectionStore.ts:1697-1770`):

- `providerSession` = newest-updated session of the thread's current `providerInstanceId`.
- `latestRun` = the usage-limited run if newer runs were queued/cancelled before starting
  (`usageLimitRunPresentedAsLatest`), else `latestUnheldRun` = highest-ordinal run that is not a held queued run
  (`packages/shared/src/orchestrationV2ThreadError.ts:96-124`). `status = latestRun?.status ?? "idle"`;
  `latestRunId/RequestedAt/StartedAt/CompletedAt` come from it.
- `activeRunId` = highest-ordinal run with status `preparing|starting|running` ("interruptible");
  `activityRunStatus`/`activityRunStartedAt` = highest-ordinal run with status `preparing|starting|running|waiting`
  (`apps/server/src/orchestration-v2/ProjectionStore.ts:1555-1567`).
- `lastError`, `lastErrorClass`, `usageLimitResetAt` = `threadErrorSummary(latestRootProviderFailure(latestRun, turnItems), providerSession?.lastError)`:
  only a failed root turn of the latest run owns the failure (`packages/shared/src/orchestrationV2ThreadError.ts:8-49`).
- `pendingRuntimeRequest` = newest `pending` runtime request by `createdAt`; if none, a `secret_request` turn item in
  `waiting` status on a live run is reported as `{ kind: "user_input" }` (`apps/server/src/orchestration-v2/ProjectionStore.ts:1348-1366`, `:1396-1416`).
- **`latestVisibleMessage` is always `null`** in this build ("Thread detail owns message bodies",
  `apps/server/src/orchestration-v2/ProjectionStore.ts:1482-1484`, `:1748`). Do not build row previews on it.
- `latestUserMessageAt` = `updatedAt` of the newest user-role message (wakes and agent-sent messages count);
  `latestUserAuthoredMessageAt` = same restricted to `createdBy === "user"` (`apps/server/src/orchestration-v2/ProjectionStore.ts:1417-1423`, `:1485-1487`).
- `hasActionableProposedPlan` = some plan with `kind: "proposed_plan"` and `status: "active"` (`:1488-1490`).
- `itemCount` = active local turn items; `visibleItemCount` = `visibleTurnItems.length`; `updatedAt` = projection `updatedAt`.

---

## 2. Commands

### 2.1 Dispatch mechanics (all commands)

Request: `orchestration.dispatchCommand` with payload `OrchestrationV2Command` (the union at
`packages/contracts/src/orchestrationV2.ts:2611-3054`). Requires scope `orchestration:operate`
(`apps/server/src/auth/RpcAuthorization.ts:45`; scope literal `packages/contracts/src/auth.ts:82-83`). Success:
`{ "sequence": <NonNegativeInt> }` (`packages/contracts/src/orchestrationV2.ts:3212-3214`).

Server path (`apps/server/src/ws.ts:1818-1867`):

1. Provenance override: for `thread.create`, `message.dispatch`, `thread.fork`, `thread.merge_back`,
   `delegated_task.request` the server **forces** `createdBy: "user"` and keeps the command's `creationSource`
   (default `"web"`) (`apps/server/src/orchestration-v2/ThreadManagementService.ts:52-66`). The client still has to
   send both fields (they are required by the schema). Official values: web and desktop send `"web"`, mobile sends
   `"mobile"` (`packages/client-runtime/src/operations/commands.ts:400`, `apps/mobile/src/state/pending-thread-creation.ts:162`).
   There is no `"desktop"` literal; a native macOS client should send `"web"` (UNVERIFIED as a product decision; any
   value outside `web|mobile|mcp|provider|server` fails decode).
2. `prepared-run.retry` goes to `ThreadLaunchService.retryPreparation`; everything else to
   `ThreadMessageIntake.dispatchCommand` (`apps/server/src/ws.ts:1840-1850`), which first **claims pending attachment
   uploads** for `message.dispatch`, `queued-run.edit` (with attachments) and `runtime-request.respond` (with
   `attachmentsByQuestionId`): validates limits (<= 100 attachments, <= 80 MiB images), rejects duplicate attachment
   ids, copies each pending upload into the thread's attachment store and rewrites the attachment ids (and composer
   context bindings) before the command reaches the orchestrator
   (`apps/server/src/orchestration-v2/ThreadMessageIntake.ts:53-165`, `apps/server/src/orchestration-v2/AttachmentClaims.ts:26-80`).
3. The orchestrator runs each command under a **per-thread lock** keyed by the command's thread id
   (`threadDispatch.withLock(commandThreadId(command), …)`, `apps/server/src/orchestration-v2/Orchestrator.ts:10627-10628`).
   Commands for the same thread are strictly serialized; different threads run concurrently.
4. Decide (no I/O) -> events + outbox effects -> one transaction commits events, projections, the command receipt
   and effects (`docs/internals/overview.md:53-67`). The returned `sequence` is the receipt's `resultSequence`, the last
   committed stored-event sequence (`apps/server/src/orchestration-v2/Orchestrator.ts:10577-10625`).
   **Acceptance means the intent committed, not that provider work finished** (`docs/internals/overview.md:63-67`).

Idempotency (`dispatchWithReceiptEffect`, `apps/server/src/orchestration-v2/Orchestrator.ts:10421-10625`):

| Situation | Result |
| --- | --- |
| New `commandId` | decide and commit; receipt `accepted` with `resultSequence` |
| Same `commandId`, receipt `accepted`, same thread | **replay**: returns the original `{ sequence }` without re-running anything; the payload is *not* compared (`:10441-10483`) |
| Same `commandId`, receipt for a different thread | `OrchestratorCommandIdConflictError` (`:10451-10463`) |
| Same `commandId`, receipt `rejected` | `OrchestratorCommandPreviouslyRejectedError` with the stored reason (`:10443-10449`) |
| Decide fails | a **rejected receipt** is committed with the error text, then the error is returned (`:10512-10550`); retrying the same `commandId` keeps failing, so a client must mint a new `commandId` for a deliberate retry |
| Decide produces zero events | rejected with `Command produced no domain events.` except `thread.stop` / `thread.background-work.settle`, which commit an accepted receipt at the current sequence (`:10496-10511`, `:10553-10575`) |
| `OrchestratorThreadAboveModeLimitError` | refused **without** a receipt (`:10514-10516`) |

Practical client rules:

- Generate a fresh UUID `commandId` per user action and reuse it only to retry the *same* action after a transport
  failure (the official runtime does not auto-replay mutations on reconnect, `docs/internals/connection-runtime.md:82-87`).
- Use the returned `sequence` to know when your own result is visible: the official optimistic shell layer keeps a
  pending patch until the shell's `snapshotSequence >= sequence` (`packages/client-runtime/src/state/threadLifecycle.ts:51-98`).

Errors returned to the client: the RPC fails with `OrchestrationV2DispatchCommandError`
`{ _tag, commandId, commandType, message, detail?, cause? }` (`packages/contracts/src/orchestrationV2.ts:3395-3404`).
`message` is the innermost non-generic message found in the cause chain (for example
`Thread <id> is archived.`), or a friendly capability text such as `"<Provider> cannot queue messages behind an active run."`,
`"<Provider> cannot redirect an active run. Stop it first, then send the message."`,
`"<Provider> cannot stop a run once it has started."`,
`"<Provider> cannot rewind its conversation, so this checkpoint cannot be restored on this thread."`,
otherwise `"Failed to dispatch orchestration V2 command"`; `detail` repeats the friendly text when one was found
(`apps/server/src/orchestration-v2/UserFacingErrors.ts:4-110`, `apps/server/src/ws.ts:1854-1864`). Authorization
failures are `EnvironmentAuthorizationError` with message `The authenticated token is missing required scope: <scope>.`
(`apps/server/src/auth/RpcAuthorization.ts:228-232`). A payload that does not match the union (including any
server-internal command) never reaches the orchestrator: the RPC request fails with a decode defect (3.1).

Server-internal command types (`thread.pull-request-watch.sync`, `checkpoint.rollback.fail`,
`thread.background-work.settle`, `thread.stop`, `secret_request.record`) are not in the `dispatchCommand` schema, "so no
client can send them" (`packages/contracts/src/orchestrationV2.ts:3057-3132`).

