# Orchestration v2: thread-management commands, project commands, launchThread and worktree setup (server semantics)

Source: `/Users/mrm/CandyWrapper-research/t3code`, tag `v0.0.46-nightly.20261009.2861` (read-only research).
All paths are relative to that checkout. Abbreviations used in citations:

- `C` = `packages/contracts/src/orchestrationV2.ts`
- `O` = `apps/server/src/orchestration-v2/Orchestrator.ts`
- `TLS` = `apps/server/src/orchestration-v2/ThreadLaunchService.ts`
- `TMS` = `apps/server/src/orchestration-v2/ThreadManagementService.ts`

Anything marked UNVERIFIED was not confirmed in code or tests. Quoted strings are exact literals from the code (template placeholders shown as `${...}`).

---

## 1. Wire conventions that apply to every command

- Transport: WebSocket RPC with JSON serialization (`RpcSerialization.layerJson`, `apps/server/src/ws.ts:3190`, `packages/client-runtime/src/rpc/session.ts:211`).
- Method names (`C:3138-3153`): `orchestration.dispatchCommand`, `orchestration.launchThread`, `orchestration.subscribeShell`, `orchestration.subscribeThread`, `orchestration.subscribeArchivedShell`, `orchestration.getArchivedShellSnapshot`, `orchestration.getThreadProjection`, `orchestration.getTurnDiff`, `orchestration.getFullThreadDiff`, `orchestration.searchThreads`, `orchestration.searchThread`, `orchestration.searchThreadStream`, `orchestration.getWorkflowScript`, `orchestration.getTurnItem`.
- Ids: `ThreadId`, `ProjectId`, `CommandId`, `MessageId`, `RunId` etc. are branded `TrimmedNonEmptyString` (`packages/contracts/src/baseSchemas.ts:310-330`). `TrimmedNonEmptyString` trims and rejects blank (`baseSchemas.ts:7-27`). So `title: "  x "` decodes to `"x"`.
- `IsoDateTime` is plain `Schema.String` with no format check (`baseSchemas.ts:47`). Fields typed `IsoDateTime` (`snoozedUntil`, `visitedAt`, `startedAt` of PR watch sync, `resetAt`) are parsed by the decider at dispatch time and rejected there if unparseable.
- Fields typed `Schema.DateTimeUtc` (`settledAt` on settle, `snapshotAt`, fork `createdAt`, every AppThread timestamp) are expected to be ISO-8601 strings on the JSON wire. The encoding is done by the effect library, which is not installed in this checkout: UNVERIFIED.
- Excess properties on command structs: effect Schema default behavior, UNVERIFIED (the official client-runtime spreads extra metadata fields into some PR commands, `packages/client-runtime/src/operations/commands.ts:1058-1089`, and they work, which suggests excess keys are ignored).
- Auth scopes: `orchestration.dispatchCommand`, `orchestration.launchThread`, `projects.mutate`, `projects.ensureScratch`, `projects.createNew`, `secrets.answerRequest`, `worktreeSetup.cancel` need `orchestration:operate`; `subscribeShell`, `subscribeThread`, `subscribeWorktreeSetup`, `getArchivedShellSnapshot` need `orchestration:read`; `projectClone.start` needs `source-control:write`; `server.updateSettings` needs `settings:write` (`apps/server/src/auth/RpcAuthorization.ts:45,55,59,85,114,149-150,166-167`; `packages/contracts/src/clientRpcPermissions.ts:25`; `packages/contracts/src/auth.ts:82-91`).

---

## 2. The `orchestration.dispatchCommand` pipeline

RPC definition: payload `OrchestrationV2Command`, success `{ sequence: NonNegativeInt }`, error `OrchestrationV2DispatchCommandError | EnvironmentAuthorizationError` (`packages/contracts/src/rpc.ts:1559-1563`; `C:3212-3214`, `C:3566-3569`).

Step by step:

1. Startup gate. Every call is wrapped in `startup.enqueueCommand(...)` (`ws.ts:1836-1838`). Commands queue until the server reaches command readiness; if startup failed they fail with `ServerRuntimeStartupError` whose message is `"Server runtime startup failed before command readiness."` (`apps/server/src/serverRuntimeStartup.ts:57-69,123-135`).
2. Special case: `prepared-run.retry` goes to `ThreadLaunchService.retryPreparation` (`ws.ts:1839-1841`). Every other command goes to `ThreadMessageIntake.dispatchCommand(ThreadManagementService.withCreationProvenance(command, { createdBy: "user", creationSource: "creationSource" in command ? command.creationSource : "web" }))` (`ws.ts:1842-1848`).
3. Provenance stamping (`TMS:52-66`): only for `thread.create`, `message.dispatch`, `thread.fork`, `thread.merge_back`, `delegated_task.request`, the command's `createdBy`/`creationSource` are replaced. Because `creationSource` is copied from the command itself, the net effect is: `createdBy` is always forced to `"user"`, `creationSource` is whatever the client sent. Other command types pass through unchanged (test `apps/server/src/orchestration-v2/ThreadManagementService.test.ts:28-72`).
4. `ThreadMessageIntake.dispatchCommand` only does attachment claiming for `message.dispatch`, `queued-run.edit` with attachments, and `runtime-request.respond` with `attachmentsByQuestionId`; all thread-management commands go straight to `threads.dispatch` (`apps/server/src/orchestration-v2/ThreadMessageIntake.ts:53-131`).
5. `ThreadManagementService.dispatch` first hydrates imported v1 transcripts of the threads the command touches (`existingThreadIdsForCommand`: none for `thread.create`, `thread.visit`, `thread.mark-unread`; source for `thread.fork`; parent and target for `thread.created.record`; otherwise `threadId`), then calls the orchestrator (`TMS:68-99,471-488,512-513`). A hydration failure becomes `OrchestratorDispatchError`.
6. Per-thread serialization: `dispatchWithReceipt` runs under a keyed lock on `commandThreadId(command)` (`O:10627-10628`; `apps/server/src/orchestration-v2/ThreadCommandExecutor.ts:6-12`). `commandThreadId` is `threadId` for most commands, `parentThreadId` for `delegated_task.*` and `thread.created.record`, `targetThreadId` for `thread.fork` and `thread.merge_back` (`O:427-489`). Project deletion takes the same thread locks (`apps/server/src/project/ProjectService.ts:474-486`).
7. Command receipts / idempotency (`O:10430-10481`):
   - A receipt with status `rejected` replays as `OrchestratorCommandPreviouslyRejectedError`, message `` `Command ${commandId} was previously rejected: ${detail}` `` (`O:215-226`).
   - An accepted receipt recorded for a different thread fails `OrchestratorCommandIdConflictError`, message `` `Command ${commandId} was already handled for thread ${receiptThreadId} and cannot be replayed for ${commandThreadId}.` `` (`O:228-253`).
   - An accepted receipt for the same thread returns the original `resultSequence` and stored events without running anything. Command type and payload are NOT compared, so a `commandId` is a strict one-shot idempotency key. Retried `thread.create` returns the same sequence and one stored event (`apps/server/src/orchestration-v2/runtimeLayer.test.ts:1708-1711`).
8. Mode limit (`O:10483-10494`, `apps/server/src/orchestration-v2/DispatchModeLimit.ts:16-33`): only for MCP-limited senders; user commands have no limit. Not relevant to a native client.
9. Routing (`dispatchOnce`, `O:10150-10413`). Unsupported type: `OrchestratorDispatchError` with no cause (`O:10115-10121`).
10. Zero-event rule: a plan with no domain events fails with cause `"Command produced no domain events."`, except `thread.background-work.settle` and `thread.stop` (`O:10496-10512`). All thread-state mutations always emit exactly one thread event even when nothing changed (`O:3230-3239`), so they never hit this rule ("idempotent by re-emission").
11. Rejection persistence: any failure except `OrchestratorThreadAboveModeLimitError` is stored as a rejected receipt with `error = cause.message` (`O:10513-10536`). For `OrchestratorDispatchError` that stored message is the generic `` `Failed to dispatch orchestration command ${commandType} (${commandId}).` `` (`O:140-142`), so a client retrying a rejected `commandId` gets `Command <id> was previously rejected: Failed to dispatch orchestration command <type> (<id>).` (derived from code, not covered by a test I found: UNVERIFIED wording on the wire).
12. Commit (`apps/server/src/orchestration-v2/EventSink.ts:527-576`): events appended, projections applied, effects enqueued, receipt upserted with `resultSequence` = sequence of the last appended event. The RPC returns `{ sequence: resultSequence }` (`ws.ts:1853`, `O:10621-10624`). For zero-event commands the receipt records the thread's latest sequence (`O:10553-10579`).
13. One sequence space: project events and thread events share one global application sequence (`runtimeLayer.test.ts:4676-4747`) and one receipt table `orchestration_command_receipts` keyed by command id with `aggregate_kind` (`runtimeLayer.test.ts:4727-4738`; `apps/server/src/orchestration-v2/CommandReceiptStore.ts:170-205`). A project command reusing a thread command's id fails with `` `Command ${commandId} was already used by a thread command.` `` (`EventSink.ts:620-629`). Use globally unique command ids (official clients use random UUIDv4, `commands.ts:261-267`).

### 2.1 Error shape on the wire

`OrchestrationV2DispatchCommandError` (`C:3395-3404`): `{ _tag: "OrchestrationV2DispatchCommandError", commandId, commandType: string, message: string, detail?: string, cause?: Defect }`.

Mapping (`ws.ts:1854-1863`): `message = userFacingDispatchErrorMessage(cause) ?? "Failed to dispatch orchestration V2 command"`, and `detail` is set (same string) only when a user-facing message was found.

`userFacingDispatchErrorMessage` (`apps/server/src/orchestration-v2/UserFacingErrors.ts:59-110`) walks `cause`, `error`, `errors` recursively, collects messages (a string cause is itself a message), drops ones starting with `"Failed to dispatch orchestration V2 command"`, `"Failed to dispatch orchestration command "`, `"Provider adapter failed while dispatching orchestration command "` (`UserFacingErrors.ts:4-8`), and returns the deepest remaining one. Capability rejections are rewritten into provider-named prose (`UserFacingErrors.ts:15-53`).

Practical result: decider rejections are `OrchestratorDispatchError({ cause: "<string>" })`, so the client receives `message === detail === "<string>"`, for example `"Thread <id> is archived."`. For an unknown thread id the chain is `OrchestratorProjectionError` (`` `Failed to load orchestration projection for thread ${threadId}.` ``, `O:154-164`) wrapping `ProjectionStoreThreadNotFoundError` (`` `No orchestration projection exists for thread ${threadId}.` ``, `apps/server/src/orchestration-v2/ProjectionStore.ts:116-125,4226-4242`); expected wire message is the inner one (derived from the chain logic: UNVERIFIED by test). JSON encoding of `cause` (Schema.Defect): UNVERIFIED.

---

## 3. Client-dispatchable vs server-internal commands

Enforcement is purely by schema membership plus actor stamping:

- `OrchestrationV2Command` (`C:2611-3054`) is the `dispatchCommand` payload schema. Anything in it can be decoded from a client.
- `OrchestrationV2InternalCommand` (`C:3057-3133`) is a non-exported schema value whose doc says: "Commands only the server dispatches. They stay out of `OrchestrationV2Command`, the `dispatchCommand` payload, so no client can send them." `OrchestrationV2ServerCommand` is the TS union of both (`C:3136`); server code calls `orchestrator.dispatch` directly with internal commands.
- `CommandPolicy.ts` is NOT an access gate. It is provider-capability policy (message dispatch modes, steering, fork, rollback) (`apps/server/src/orchestration-v2/CommandPolicy.ts:51-165`).
- Actor stamping (section 2 step 3) plus decider checks: `message.dispatch` with `notification` requires `createdBy === "agent"`, `creationSource` `"server"` or `"provider"` and `queue_after_active` (`"Notifications must be server- or provider-created queued messages."`), and `delegatedCompletion` requires `createdBy "agent"`, `creationSource "server"` (`O:4668-4695`). Since WS forces `createdBy: "user"`, clients cannot inject wakes.

Classification of the commands in scope:

| Group | Commands |
|---|---|
| Public, normally client-sent | `thread.create`, `thread.archive`, `thread.unarchive`, `thread.delete`, `thread.settle`, `thread.unsettle`, `thread.snooze`, `thread.unsnooze`, `thread.auto-settle.set`, `thread.pin`, `thread.unpin`, `thread.pin.reorder`, `thread.active.reorder`, `thread.visit`, `thread.mark-unread`, `thread.metadata.update`, `thread.pull-request.link`, `thread.pull-request.unlink`, `thread.pull-request.watch`, `thread.runtime-mode.set`, `thread.interaction-mode.set`, `thread.model-selection.set`, `thread.fork`; also `provider-session.detach` (web "stop session", `commands.ts:919-935`) and `prepared-run.retry` (`commands.ts:1011-1020`) |
| Public schema, but server-originated in practice (nothing on the server prevents a client from sending them) | `thread.auto-settle` (doc: "dispatched by the settlement sweep, never by clients", `C:2656-2668`; sender `apps/server/src/orchestration-v2/ThreadSettlementService.ts:343-349`), `thread.created.record` (`apps/server/src/mcp/OrchestratorMcpService.ts:2201-2215`), `thread.pull-request-link.sync` and stack-sourced `thread.pull-request.link` (`apps/server/src/orchestration-v2/PullRequestSyncReactor.ts:251-272`), `thread.pull-request.sync` (`apps/server/src/orchestration-v2/ThreadPullRequestService.ts:309-324`), `thread.title.regeneration.complete` (`apps/server/src/orchestration-v2/ThreadTitleRegenerationService.ts:47-60`), `prepared-run.progress/release/fail` (`TLS:323-331,472-480,551-558,625-637`), `provider.switch` |
| Internal only (not decodable from clients) | `thread.pull-request-watch.sync`, `checkpoint.rollback.fail`, `thread.background-work.settle`, `thread.stop`, `secret_request.record` (`C:3062-3132`) |

A client sending an internal type fails RPC payload decoding; the exact client-visible error for a decode failure: UNVERIFIED.

---

## 4. Actor and creationSource literals

- `OrchestrationV2Actor = "user" | "agent" | "system"` (`C:76-77`).
- `OrchestrationV2CreationSource = "web" | "mobile" | "mcp" | "provider" | "server"` (`C:79-86`). Closed set: any other value fails decoding.
- `OrchestrationV2CreationFields = { createdBy, creationSource }`, both required where spread (`C:91-94`): `thread.create` (`C:2614`), `message.dispatch` (`C:2840`), `thread.fork` (`C:2984`), `thread.merge_back` (`C:2994`), `delegated_task.request` (`C:3003`). Persisted on `AppThread` (`C:365`), `ThreadShell` (`C:1837`), `user_message` turn items (`C:1380`). `OrchestrationV2ContextTransfer` carries `createdBy` only (`C:185`).
- `launchThread` input has optional `creationSource` only (`C:3184`); server uses `createdBy: "user"`, `creationSource: input.creationSource ?? "web"` (`ws.ts:1986-1987`).

Where each value is used:

- `createdBy "user"`: every WS `dispatchCommand`/`launchThread` creation command (forced, `ws.ts:1844,1986`); agent-session import launch (`ws.ts:1503-1504`, with `"web"`); usage-limit auto resume message (`apps/server/src/orchestration-v2/UsageLimitRecoveryWorker.ts:69-70`, with `"server"`); async question answers turned into messages (`O:7264-7265`, with `"server"`); legacy v1 importer and agent session importer user messages.
- `createdBy "agent"`: MCP tools (with `"mcp"`, e.g. `OrchestratorMcpService.ts:1528,2141,2170`, `apps/server/src/mcp/toolkits/thread/handlers.ts:130,150`); provider-native subagents (with `"provider"`, `ClaudeAdapterV2.ts:2623`, `CodexAdapterV2.ts:2837`, `packages/provider-core/src/server/subagentProjection.ts:105`); server wakes such as PR watch wakes (`O:2358-2359`, with `"server"`), provider continuations (`ProviderContinuationService.ts:137-138`), restart continuations (`RestartContinuation.ts:170-171`).
- `createdBy "system"`: server bootstrap "New thread" launch (`serverRuntimeStartup.ts:299-300`, with `"server"`), legacy importer and agent-session importer thread creation, context transfers (`O:9759`, `ProviderTurnStartService.ts:771`).
- `"mobile"`: the mobile app (`apps/mobile/src/state/pending-thread-creation.ts:162`, etc.). `"web"`: web client default (`commands.ts:400,670`).
- `isProviderNativeSubagentThread(thread) = lineage.relationshipToParent === "subagent" && creationSource === "provider"` (`C:447-451`). Such threads reject `message.dispatch` and `thread.pull-request.watch` with `watching: true` using `OrchestratorSubagentThreadReadOnlyError`, message `"This subagent is run by its provider and cannot take messages. Message the parent thread instead."` (`O:190-197,2417-2426,10253-10265`).

---

## 5. Thread record, event model and projection rules (background)

- `OrchestrationV2AppThread` (`C:364-439`): `createdBy, creationSource, id, projectId, title, providerInstanceId, modelSelection, runtimeMode, interactionMode, branch: string|null, worktreePath: string|null, linkedPullRequest?: (legacy single PR)|null, pullRequests?: ThreadPullRequestLink[], branchPullRequest?: |null, activeProviderThreadId: |null, historyOrigin?: "native"|"v1_import", lineage {parentThreadId|null, relationshipToParent: "fork"|"subagent"|null, rootThreadId}, forkedFrom: {type:"run",threadId,runId}|{type:"node",nodeId}|{type:"provider_thread",providerThreadId,providerTurnId?}|null, createdAt, updatedAt, archivedAt|null, settledOverride: "settled"|"active"|null (decode default null), settledAt|null (decode default null), unsettledAt?, snoozedUntil?, snoozedAt?, limitRecovery?, pinnedAt?, autoSettleDisabledAt?, pinOrderKey?, activeOrderKey?, lastVisitedAt|null (decode default null), titleRegeneration?: {requestId, startedAt}|null, rollbackRequestId?, rollbackFailure?, deletedAt|null`.
- Shell (`C:1836-1928`) carries the same lifecycle fields plus run-derived status fields; `lastVisitedAt`, `pinOrderKey`, `activeOrderKey`, `pinnedAt` are optional so older servers decode.
- Domain events (`C:1645-1676`): `thread.created` and the thread-state group `thread.archived, thread.unarchived, thread.deleted, thread.settled, thread.unsettled, thread.snoozed, thread.unsnoozed, thread.pinned, thread.auto-settle-set, thread.unpinned, thread.pin-reordered, thread.active-reordered, thread.visited, thread.marked-unread, thread.metadata-updated, thread.pull-request-synced, thread.runtime-mode-updated, thread.interaction-mode-updated, thread.model-selection-updated, thread.provider-switched`. Every one carries the COMPLETE updated `AppThread` as payload (replace semantics, not a diff). Event base fields: `id, threadId, runId?, nodeId?, driver?, providerInstanceId?, rawEventId?, occurredAt` (`C:1634-1643`).
- In-memory projection: thread-state events replace `thread` with the payload; `thread.visited` and `thread.marked-unread` additionally do not bump `projection.updatedAt` (`ProjectionStore.ts:692-723`).
- SQL projection: thread-state events upsert the row from the payload (`ProjectionStore.ts:1795-1868`); every other event bumps the stored thread `updatedAt` to `event.occurredAt` (`ProjectionStore.ts:2650-2668`). The exclusion list (`ProjectionStore.ts:2629-2649`) omits `thread.active-reordered` and `thread.pull-request-synced`, so for those two the stored `updatedAt` is bumped to the event time even though the decider kept `updatedAt` unchanged in the payload (`O:2890-2896,3067,3123,3157`). `ProjectionMaintenance.ts:209-230` treats both as full-thread events, so this looks like an oversight. Consequence: shell snapshots and shell deltas (read from SQL) can show a newer `updatedAt` than the event payload. Not covered by a test I found: UNVERIFIED impact.

### 5.1 Common guards of the "thread mutation" group

`dispatchThreadMutation` (`O:2367-2400`) handles: archive, unarchive, settle, unsettle, snooze, unsnooze, auto-settle.set, pin, unpin, pin.reorder, active.reorder, mark-unread, metadata.update, pull-request.link, pull-request.unlink, pull-request-link.sync, pull-request.watch, pull-request-watch.sync, pull-request.sync, title.regeneration.complete, runtime-mode.set, interaction-mode.set, model-selection.set, provider.switch.

- Thread must exist (else `OrchestratorProjectionError`).
- `deletedAt !== null` rejects: `` `Thread ${threadId} is deleted.` `` (`O:2410-2416`).
- Archived guard (`O:2511-2529`), message `` `Thread ${threadId} is archived.` ``, applies to: `thread.settle`, `thread.unsettle`, `thread.snooze`, `thread.unsnooze`, `thread.auto-settle.set`, `thread.pin`, `thread.unpin`, `thread.pin.reorder`, `thread.active.reorder`, `thread.pull-request.sync`.
- NOT archived-guarded: `thread.unarchive` (needs archived), `thread.mark-unread`, `thread.metadata.update`, `thread.pull-request.link/unlink/link-sync`, `thread.pull-request.watch` with `watching: false`, `thread.title.regeneration.complete`, `thread.runtime-mode.set`, `thread.interaction-mode.set`, `thread.model-selection.set`. `thread.visit` has its own handler and also allows archived threads.
- One thread event is always emitted, with event type per `O:3182-3229`.

### 5.2 `updatedAt` behavior per command (decider payload)

Bumped to now: archive, unarchive, settle (unless already settled and not pinned), unsettle (unless already `"active"`), snooze (unless same wake time), unsnooze (unless already awake), auto-settle.set (only if changed), pin (unless already pinned and nothing promoted), unpin (only if was pinned), pin.reorder (only if key changed), metadata.update (always, even with no field changes), PR link/unlink (when changed), PR watch (when changed), title.regeneration.complete (when it matches), runtime-mode.set, interaction-mode.set, model-selection.set (always).
Not bumped: visit, mark-unread, active.reorder, PR link-sync, PR watch-sync, PR sync (but see the SQL caveat in section 5 for active.reorder and all `thread.pull-request-synced` events).

---

## 6. Command-by-command semantics

### 6.1 `thread.create`

Payload (`C:2612-2634`):
```
{ type: "thread.create",
  createdBy: "user"|"agent"|"system",          // required by schema; forced to "user" over WS
  creationSource: "web"|"mobile"|"mcp"|"provider"|"server",
  commandId: CommandId,
  threadId: ThreadId,                          // client allocated, required
  projectId: ProjectId,
  title: TrimmedNonEmptyString,
  modelSelection: { instanceId, model, options? },   // legacy {provider, model} also decodes (packages/contracts/src/modelSelection.ts:16-60)
  runtimeMode: "approval-required"|"auto-accept-edits"|"auto"|"full-access",   (packages/contracts/src/providerPolicy.ts:25-32)
  interactionMode: "default"|"plan",           (providerPolicy.ts:34-36)
  branch: TrimmedNonEmptyString | null,
  worktreePath: TrimmedNonEmptyString | null,
  importedNativeThread?: { ref: { driver, nativeId, strength: "strong" },
                           metadata?: { modelSelection?, title?: string|null, updatedAt?: string|null, itemIdentityVersion?: 2 } }  (C:832-839)
}
```

Handler `dispatchThreadCreate` (`O:2183-2265`):
- Builds the thread (`O:2196-2224`): `providerInstanceId = modelSelection.instanceId`; `lineage = { parentThreadId: null, relationshipToParent: null, rootThreadId: threadId }`; `forkedFrom: null`; `activeProviderThreadId: null`; `createdAt = updatedAt = server now`; `archivedAt, settledOverride, settledAt, snoozedUntil, snoozedAt, lastVisitedAt, deletedAt` all null. Not set (absent): `pinnedAt, pinOrderKey, activeOrderKey, pullRequests, linkedPullRequest, branchPullRequest, limitRecovery, autoSettleDisabledAt, titleRegeneration, historyOrigin, unsettledAt`. Clients cannot set lineage or parent with this command.
- Events: `thread.created` (event `providerInstanceId = modelSelection.instanceId`). If `importedNativeThread`, also `provider-thread.updated` with id derived from `(driver, instance, nativeId)`, `status: "not_loaded"`, `nativeThreadRef = ref`, `nativeMetadata = metadata ?? null`, `appThreadId = threadId` (`O:2233-2264`).
- Effects: none. No provider session or provider thread is created.
- Validation: schema only. No project existence check (a test creates a thread under an unseeded project, `runtimeLayer.test.ts:3577-3590`), no provider instance or model check (an unknown instance only fails later at `message.dispatch` with `OrchestratorProviderAdapterError`, `O:5202-5211`), no clone-in-progress check (that guard is only in `launchThread`, `TLS:686-689`).
- Duplicate `threadId` with a NEW `commandId`: no guard found in the decider; the SQL projection upserts the thread row (`ProjectionStore.ts:1821-1866`), so it would overwrite the existing thread record. UNVERIFIED end-to-end (no test).
- Reactions: PR discovery is enqueued for the thread on `thread.created` (`ThreadPullRequestService.ts:366-371`). Shell stream emits `thread.updated` with `location: "active"`.
- Official web usage: `threadId = randomUUID()` (`apps/web/src/lib/utils.ts:46`), `commandId = randomUUIDv4` (`commands.ts:261-267`), `createdBy: "user"`, `creationSource` default `"web"` (`commands.ts:393-410`). When the first message is sent together with creation, clients use `launchThread` instead (section 7).

### 6.2 `thread.created.record`

Payload (`C:3038-3046`): `{ type, commandId, parentThreadId, parentRunId, parentNodeId, targetThreadId, targetRunId: RunId | null }`. Public schema; sent by the MCP `create_threads` tool after creating threads (`OrchestratorMcpService.ts:2201-2215`). Lock and receipt thread = `parentThreadId`.

Handler `O:6858-6966`. Rejections:
- parent run or node missing, node not in run, or not the run's root node: `` `Parent node ${parentNodeId} is not the root of run ${parentRunId}.` ``
- `` `Target thread ${targetThreadId} belongs to another project.` ``
- `` `Target run ${targetRunId} does not belong to thread ${targetThreadId}.` ``
- missing parent or target thread: `OrchestratorProjectionError`.

Event: one `turn-item.updated` on the PARENT thread with a `thread_created` item (`C:1543-1550`): id derived from the command id, `runId/nodeId` of the parent, `status: "completed"`, `title` = target thread title, `targetThreadId`, `targetRunId`, `targetProviderInstanceId = target.modelSelection.instanceId`, `targetModel = target.modelSelection.model`. No thread-state change.

### 6.3 `thread.archive`

Payload `{ type: "thread.archive", commandId, threadId }` (`C:2635-2639`).

Rejections: deleted; `` `Thread ${threadId} is already archived.` `` (`O:2497-2503`). The server has NO active-run guard. The web client refuses to archive while the runtime status is preparing/starting/running (or queued with an active run) (`packages/client-runtime/src/state/models.ts:70-77`, `apps/web/src/hooks/useThreadActions.ts:376-390`).

Thread change (`O:2775-2783`): `archivedAt = now`, `titleRegeneration = null`, every PR link's `watch` removed, `updatedAt = now`.

Events in order: `thread.archived`; for each QUEUED run `run.updated` with `status: "cancelled", queuePosition: null, completedAt: now`; `run-attempt.updated` cancelled for pending/running attempts of those runs; `node.updated` cancelled for pending/running/waiting nodes of those runs (`O:3250-3302`); delegated completion cohorts disposed (`O:3303-3309`); `provider-session.detached` (reason `"Thread archived."`) for every live session (status not stopped/error) (`O:3319-3368`).

Effects: `provider-session.detach` per live session with `detail: "Thread archived."` and `revokeMcpCredential: true` (`O:3369-3392`); `terminal.cleanup` (`O:3398-3408`) which closes every terminal of the thread and deletes history (`apps/server/src/orchestration-v2/ResourceCleanupService.ts:46-53`). Running runs are not cancelled by the decider; what happens to an in-flight turn after its session is detached: UNVERIFIED. No worktree removal (there is no worktree effect type, `apps/server/src/orchestration-v2/EffectOutbox.ts:30-118`).

Shell: active stream emits `thread.removed` (`location: "active"`) (`apps/server/src/orchestration-v2/ShellStream.ts:296-304`; `runtimeLayer.test.ts:1890-1927`); archived stream emits `thread.updated` (`ShellStream.ts:322-332`). Tested: queued run, attempt and node become cancelled (`runtimeLayer.test.ts:3572-3651`).

### 6.4 `thread.unarchive`

Payload `{ type: "thread.unarchive", commandId, threadId }` (`C:2640-2644`). Rejections: deleted; `` `Thread ${threadId} is not archived.` `` (`O:2504-2510`). Change: `archivedAt = null`, `updatedAt = now` (`O:2784-2785`); nothing else is restored (watches, sessions, cancelled runs stay). Event `thread.unarchived`. Shell: active stream `thread.updated`; archived stream `thread.removed` (`ShellStream.ts:333-341`). PR discovery re-enqueued (`ThreadPullRequestService.ts:368-371`).

### 6.5 `thread.delete`

Payload `{ type: "thread.delete", commandId, threadId }` (`C:2645-2649`). Handled outside the mutation group (`O:10191-10217`) by `planThreadDeletion` (`apps/server/src/orchestration-v2/ThreadDeletion.ts:18-234`), the same planner project deletion uses.

Preconditions: only that the thread record exists. No deleted, archived, or active-run guard. Deleting an already deleted thread with a new command id is accepted, re-emits `thread.deleted` and preserves the original `deletedAt` (`ThreadDeletion.ts:63-64`; test `ThreadDeletion.test.ts:228-299`). Archived threads can be deleted (`runtimeLayer.test.ts:1929-1964`).

Events in order (`ThreadDeletion.ts:57-199`):
1. `thread.deleted`: payload = thread with `deletedAt = existing ?? now`, `titleRegeneration: null`, `updatedAt: now`.
2. `run.updated` with `status: "cancelled", queuePosition: null, completedAt: now` for every run in preparing/queued/starting/running/waiting.
3. `run-attempt.updated` cancelled for pending/running attempts of those runs.
4. `node.updated` cancelled for pending/running/waiting nodes of those runs.
5. `runtime-request.updated` for every pending request: `status: "cancelled"`, `responseCapability: { type: "not_resumable", reason: "The thread was deleted." }`, `resolvedAt: now`.
6. Delegated completion cohorts: `run.updated` with `delegatedCompletion: { disposition: "disposed", nextGeneration, delivery: null }`, and `subagent.updated` with `completionDelivery: { state: "disposed", observedByRunId: null }` for undelivered tasks.
7. `provider-session.detached` (reason `"Thread deleted."`) per live session.

Effects (`ThreadDeletion.ts:200-232`): `provider-session.detach` (`detail: "Thread deleted."`, `revokeMcpCredential: true`) per live session; `terminal.cleanup`; `preview.cleanup`; `attachment.cleanup` with the distinct attachment ids of the thread (if any).

Cascade: none to other threads (fork children and delegated child threads remain). Consumers of `thread.deleted` found: `storageCleanup.ts:542`, `ProjectionMaintenance.ts:212`, `TMS:720`, `ShellStream.ts:335`, `ProjectionStore.ts:696,1801`, `relay/AgentAwarenessRelay.ts:98`; none deletes other threads (UNVERIFIED beyond these).

Worktree cleanup is NOT part of the command. Two separate mechanisms:
- Client-driven (web): if the thread is the only one using its worktree and the user confirms (prompt skipped when automatic cleanup is on), the web first detaches all provider sessions via `provider-session.detach` (`reason: "client-requested"`), dispatches `thread.delete`, then calls the git remove-worktree RPC with `force: true` on the project root (`apps/web/src/hooks/useThreadActions.ts:440-641`; `commands.ts:919-935`).
- Server policy (`apps/server/src/storageCleanup.ts:206-438,500-551`): runs hourly and on `thread.deleted` / `provider-session.updated` events. A deleted thread's worktree is removed only if the resolved `worktreeCleanup` rules have `worktreeOnDelete: true`, the path is inside a managed worktrees directory, is a linked worktree (`.git` file), no surviving thread uses the path, no live provider session cwd or live terminal is inside it, the checkout is clean on the recorded branch with no ignored files other than `node_modules/`, HEAD did not move, and every outbox effect of the thread is `succeeded` or `cancelled`. Removal uses `git worktree remove` without force. Rules type `WorktreeCleanupRules { worktreeAfterDays, worktreeOnMerge, worktreeOnDelete, worktreeUnchanged }` (`packages/contracts/src/settings.ts:1011-1025`).

Shell: `getThreadShell` returns null for deleted threads (`ProjectionStore.ts:5289`), so the active stream emits `thread.removed`; the archived stream emits `thread.removed` if the deleted thread was archived (`ShellStream.ts:333-341`). The full projection stays readable with `deletedAt` set (`runtimeLayer.test.ts:1956-1964`).

### 6.6 `thread.settle`

Payload `{ type: "thread.settle", commandId, threadId, settledAt?: DateTimeUtc }` (`C:2650-2655`).

Rejections: deleted; archived; `` `Thread ${threadId} has active or blocked work and cannot be settled.` `` when any run is preparing/queued/starting/running/waiting (queued automatic runs, i.e. notification or delegated-completion messages, excepted) or any pending runtime request other than a `user_input` request whose `responseCapability.type === "message"` (`O:2585-2622`). A run parked in `waiting` blocks settle.

Same-transaction side work: every pending message-capable `user_input` request is answered with `decision: "cancel"` (runtime-request.respond semantics) (`O:2624-2639`); every queued automatic run is cancelled via queued-run.cancel (`O:2640-2650`).

Thread change (`O:2786-2803`): `settledOverride: "settled"`; `settledAt` kept if already settled and not pinned, else `command.settledAt ?? now`; all PR watches removed; `unsettledAt: null`; `pinnedAt: null`; `pinOrderKey: null`; `activeOrderKey: null`; `updatedAt` kept if already settled, else now.

Events: (side-work events first), `thread.settled`, then `provider-session.detached` (reason `"Thread settled."`) per live session (`O:3319-3368`). Effects: `provider-session.detach` with `detail: "Thread settled."` (no MCP credential revocation).

After commit (`ThreadSettlementService.ts:553-597`): on `thread.settled` the server closes the thread's idle terminals and, if the thread has its own existing `worktreePath`, runs the project's `runOnSettle` script there, once per `settledAt` value.

Agent path (MCP): `settleThread` with `byOwnAgent` while the run is active waits up to 24 h for the run, and if it completed dispatches `thread.settle` with command id `` `server:settle-after-run:${runId}` `` (`TMS:440,765-796`).

### 6.7 `thread.auto-settle`

Payload `{ type: "thread.auto-settle", commandId, threadId, snapshotAt: DateTimeUtc, settledAt?: DateTimeUtc }` (`C:2656-2668`). Public schema, server-originated.

Rejection: `` `Thread ${threadId} changed before automatic settlement.` `` when `settledOverride !== null` or `thread.updatedAt > snapshotAt` (`O:10157-10178`). Otherwise runs the `thread.settle` mutation with the same guards and events (`O:10179-10188`).

Sender: `ThreadSettlementService` sweep (every 1 minute, and on `thread.pull-request-synced`, `provider-session.detached`, `provider-session.updated` not starting/running, terminal `run.updated`), command id `` `server:auto-settle:${threadId}:${uuid}` ``, `snapshotAt = candidate.updatedAt` (`ThreadSettlementService.ts:327-349,599-653`). Only active when `sidebarAutoSettleOnMerge` or `sidebarAutoSettleAfterDays` is configured globally or per project (`ThreadSettlementService.ts:253-262`).

Candidate rules (`ThreadSettlementService.ts:139-164`): not archived; `settledOverride === null`; not pinned; `autoSettleDisabledAt == null`; no pending runtime request; no `activityRunStatus`; no background work holding completion; no queued turn start (2 minute grace, lines 39, 86-108); and not snoozed, or snooze elapsed, or woke by a failure or completion after `snoozedAt`.

`settledAt` resolution (`ThreadSettlementService.ts:199-243`): if visible PR links exist they must all be terminal and the latest terminal one is used; a merged PR (with auto-settle-on-merge) or closed PR whose terminal time is at or after `max(createdAt, latestUserAuthoredMessageAt)` settles at the last activity time; otherwise settle when the last activity is older than `autoSettleAfterDays`.

### 6.8 `thread.unsettle`

Payload `{ type: "thread.unsettle", commandId, threadId, reason: "user" }` (`C:2669-2674`).
Rejections: deleted, archived.
Change (`O:2804-2813`): `settledOverride: "active"`, `settledAt: null`, `unsettledAt` = now (kept if already `"active"`), `updatedAt` = now (kept if already `"active"`). Event `thread.unsettled`.
Notes: works on a thread that was never settled, turning it into an explicit `"active"` override, which excludes it from auto-settlement (`ThreadSettlementService.ts:143`). The override is reset to `null` by the next `message.dispatch`, which emits `thread.unsettled` itself (`O:4562-4585`). An explicit unsettle outranks a later auto-settle even with a fresh snapshot (`runtimeLayer.test.ts:1848-1864`). PR discovery reruns with refresh on `thread.unsettled` (`ThreadPullRequestService.ts:372-374`).

### 6.9 `thread.auto-settle.set`

Payload `{ type: "thread.auto-settle.set", commandId, threadId, enabled: boolean }` (`C:2687-2692`). Rejections: deleted, archived. Change: `autoSettleDisabledAt = enabled ? null : (existing ?? now)`; `updatedAt` only bumped when the state changes (`O:2837-2844`). Event `thread.auto-settle-set`. Allowed on settled threads.

### 6.10 `thread.snooze` and `thread.unsnooze`

`thread.snooze` payload `{ type, commandId, threadId, snoozedUntil: IsoDateTime }` (`C:2675-2680`).
Rejections (`O:2728-2759`): deleted; archived; `` `Thread ${threadId} snooze wake time ${snoozedUntil} is not in the future.` `` (unparseable or not after now); `` `Thread ${threadId} has a pending approval or user-input request and cannot be snoozed.` ``; `` `Thread ${threadId} has a queued run and cannot be snoozed.` ``. A running run does not block snooze; settled and pinned states are not checked.
Change (`O:2814-2827`): `snoozedUntil` = parsed time; `snoozedAt` kept if the wake time is identical, else now; `limitRecovery` = existing with `snooze: false`, or `null` if none; `updatedAt` now unless same wake time. Pin and settle state untouched. Event `thread.snoozed`.

`thread.unsnooze` payload `{ type, commandId, threadId, reason: "user" }` (`C:2681-2686`). Rejections: deleted, archived. Change: `snoozedUntil: null`, `snoozedAt: null`, `updatedAt` kept if already awake (`O:2828-2836`). Event `thread.unsnoozed`.

Snooze-until semantics:
- No server timer and no event when `snoozedUntil` passes; the fields stay stored (client doc: "Timer wakes are derived - no server event fires when snoozedUntil passes", `packages/client-runtime/src/state/threadSettled.ts:155-172`).
- "Snoozed" is derived: `snoozedUntil > now` and not "raised hand". Server twin `isSnoozed` (`ThreadSettlementService.ts:166-197`): not snoozed if a runtime request is pending, or the thread status is failed with no `snoozedAt` or a completion after `snoozedAt`, or status completed with `latestRunCompletedAt > snoozedAt`. Client twin `effectiveSnoozed` / `threadRaisedHandWhileSnoozed` (`threadSettled.ts:95-172`).
- Snooze fields are cleared by `thread.unsnooze`, `thread.pin` (`O:2860-2864`), and any `message.dispatch` (emits `thread.unsnoozed`, `O:4586-4605`). A limit-recovery update with `snooze: true` sets `snoozedUntil = resetAt` (section 6.15).

### 6.11 `thread.background-work.settle` (internal)

Payload `{ type, commandId, threadId, providerThreadId, providerTurnId }` (`C:3092-3104`). Sent by the effect worker after a `provider-turn.interrupt` effect completes, command id `` `${effectId}:background-work-settled` `` (`apps/server/src/orchestration-v2/EffectWorker.ts:182-195`).

Handler (`O:8549-8635`): finds the stopped run through the provider turn's attempt; returns with no events if the run is unknown or is preparing/starting/running with a different active attempt; if the stopped run is still `running`, settles it as interrupted; returns if any other run is preparing/starting/running; else (`settleBackgroundWork`, `O:8107-8209`) marks pending background turn items (`command_execution, dynamic_tool, subagent, assistant_message, reasoning` in pending/running/waiting) of runs up to the stopped run's ordinal as `interrupted`, unless their provider thread still has a live session other than the stopped one, and clears `pendingBackgroundTasks` on provider threads without a live session (status `active` becomes `idle` when `lastRunOrdinal <= stopped ordinal`). Zero events is allowed and still records an accepted receipt (`O:10496-10504,10553-10579`).

### 6.12 Pinning and ordering

`thread.pin` payload `{ type, commandId, threadId, orderKey?: TrimmedNonEmptyString }` (`C:2693-2701`). Rejections: deleted, archived. Change (`O:2845-2867`): `pinnedAt` = existing or now; `pinOrderKey = orderKey` only on a fresh pin when provided (a re-pin keeps the existing key); a settled thread becomes `settledOverride: "active"` with `settledAt: null` (unsettledAt untouched); `snoozedUntil` and `snoozedAt` cleared; `updatedAt` now unless already pinned and nothing was promoted. Event `thread.pinned`.

`thread.unpin` payload `{ type, commandId, threadId }` (`C:2702-2706`). Rejections: deleted, archived. Change: `pinnedAt: null`, `pinOrderKey: null`, `updatedAt` kept if already unpinned (`O:2868-2878`). Event `thread.unpinned`.

`thread.pin.reorder` payload `{ type, commandId, threadId, orderKey: TrimmedNonEmptyString }` (`C:2707-2716`). Rejections: deleted, archived, `` `Thread ${threadId} is not pinned and cannot be reordered.` `` (`O:2530-2539`). Change: `pinOrderKey = orderKey`, `updatedAt` kept if unchanged (`O:2879-2889`). Event `thread.pin-reordered`.

`thread.active.reorder` payload `{ type, commandId, threadId, orderKey: TrimmedNonEmptyString }` (`C:2717-2722`). Rejections: deleted, archived, `` `Thread ${threadId} is not active and cannot be reordered.` `` when pinned or `settledOverride === "settled"` (`O:2540-2549`). Change: `activeOrderKey = orderKey`, payload `updatedAt` unchanged (`O:2890-2897`; SQL caveat in section 5). Event `thread.active-reordered`. `thread.settle` clears `activeOrderKey` (`O:2800`; `runtimeLayer.test.ts:1845-1847`).

Order key format:
- Server: only `TrimmedNonEmptyString`, no format validation (a server test uses `"a0"`, `runtimeLayer.test.ts:1817-1823`). Contract comment: keys are fractional-index strings compared lexicographically; a drag writes one key on one thread (`C:2711-2715`).
- Official clients (`packages/client-runtime/src/state/threadSort.ts:178-298`): base-26 digit strings over `"abcdefghijklmnopqrstuvwxyz"`, never ending in `"a"`; `pinOrderKeyBetween(before, after)` computes a midpoint (`null` bounds mean open ends); when a neighbor is keyless the whole section is rewritten with evenly spaced keys of width at least 2 (`generateSpreadPinOrderKeys`). Active reordering uses the same planner with `activeOrderKey`.
- Client sort: pinned block = keyed threads by plain string comparison, tiebreak `id` then `environmentId`, then keyless threads newest-created first (`threadSort.ts:306-339`); active list = keyless threads first (newest anchor timestamp first), then keyed threads by key (`threadSort.ts:343-376`).

### 6.13 `thread.visit` and `thread.mark-unread`

`thread.visit` payload `{ type, commandId, threadId, visitedAt: IsoDateTime }` (`C:2723-2733`). Own handler (`O:2267-2308`).
- Rejections: `` `Thread ${threadId} is deleted.` ``; `` `Thread ${threadId} visit time ${visitedAt} is not a valid timestamp.` ``. Archived threads are allowed.
- Change: `lastVisitedAt = max(stored, visitedAt)`; it only moves forward. `thread.visited` is ALWAYS emitted (with an unchanged payload when the watermark does not move), `occurredAt` = server now. No `updatedAt` bump in payload, in-memory projection (`ProjectionStore.ts:716-723`) or SQL (`ProjectionStore.ts:2642`). No transcript hydration (`TMS:74-80`).
- Contract guidance: send the shell `updatedAt` the viewer has seen (`C:2727-2731`).

`thread.mark-unread` payload `{ type, commandId, threadId }` (`C:2734-2738`).
- Rejections: deleted; `` `Thread ${threadId} has no completed run to mark unread.` `` when the highest-ordinal run (runs are ordered by ordinal ascending, `ProjectionStore.ts:2946`) has `completedAt === null` (`O:2760-2772`). Archived threads allowed.
- Change: `lastVisitedAt = latestRun.completedAt - 1 ms` (`O:2771,2898-2899`), no `updatedAt` bump. Event `thread.marked-unread`.

Storage and projection: `AppThread.lastVisitedAt` (`C:415-417`, decode default null); shell `lastVisitedAt` optional (`C:1913-1917`). Unread is NOT a server field; it is derived by clients. Web: a thread has an unseen completion iff `latestRun.completedAt > lastVisitedAt`, and is NOT unread when `lastVisitedAt` is null (`apps/web/src/components/Sidebar.logic.ts:773-782`); the server value is authoritative whenever the field is present (`Sidebar.logic.ts:755-771`).

### 6.14 `thread.metadata.update`

Payload (`C:2739-2754`):
```
{ type: "thread.metadata.update", commandId, threadId,
  title?: TrimmedNonEmptyString,
  regenerateTitle?: boolean,                  // true arms async regeneration, false abandons it
  branch?: TrimmedNonEmptyString | null,      // null clears
  worktreePath?: TrimmedNonEmptyString | null,
  expectedWorktreePath?: TrimmedNonEmptyString | null,   // precondition
  expectedEmpty?: boolean,                    // precondition
  limitRecovery?: { runId, resetAt: IsoDateTime, autoResume?: boolean, snooze?: boolean } | null,  // at least one of autoResume/snooze (C:349-361)
  linkedPullRequest?: { projectId, repository, number: PositiveInt, url } | null }   // legacy link (packages/contracts/src/threadPullRequest.ts:24-30)
```
Patch semantics: absent = unchanged; `null` clears for nullable fields.

Rejections:
- deleted (archived is allowed).
- `` `Thread ${threadId} worktree changed before the metadata update could be applied.` `` when `expectedWorktreePath` is provided and differs from the current `worktreePath` (strict equality, null compares as null) (`O:2472-2482`).
- `` `Thread ${threadId} is no longer empty.` `` when `expectedEmpty: true` and the thread has any message or any run (`O:2483-2496`).
- `limitRecovery` non-null: `"The reset time has passed. Retry the thread manually."` when `snooze: true` and `resetAt <= now` (`O:2703-2710`); `"The provider limit changed before recovery could be configured."` when `resetAt` is unparseable, the thread is archived or `settledOverride === "settled"`, the usage-limited run id differs, the latest root failure is not `usage_limit` or has a different `resetAt`, `resetAt` is not after the run's completion/request time, or a runtime request is pending (`O:2711-2726`).

Changes (`O:2900-2976`):
- `title` replaced if given.
- `limitRecovery`: null clears; otherwise stored `{ runId, resetAt, autoResume: given ?? previous(same run and reset) ?? false, snooze: same rule, requestId: commandId }`. With `snooze: true` and a future reset, `snoozedUntil = resetAt`, `snoozedAt = now`; a recovery change clears a snooze that the previous recovery had set.
- `branch`, `worktreePath` replaced if given.
- `linkedPullRequest`: sets the legacy field and rebuilds `pullRequests`: removes entries matching the old or new legacy key, appends a `"manual"` link built from the new one (keeping any existing watch for that key) (`O:545-563`; test `runtimeLayer.test.ts:2253-2260`).
- `regenerateTitle: true` sets `titleRegeneration = { requestId: commandId, startedAt: now }`; `regenerateTitle: false` or a provided `title` sets it to null.
- `updatedAt = now` ALWAYS, even if nothing changed (for example the `expectedEmpty` claim used by launch).

Event: `thread.metadata-updated`. Effects: with `regenerateTitle: true`, `thread-title.generate { kind: { type: "regenerate" } }` with id `` `effect:${commandId}:thread-title.generate` `` (`O:491-504,3241-3248`). If `worktreePath` changed, every live provider session gets `provider-session.detached` plus a detach effect with `"Workspace changed."` (`O:2653-2661,3319-3325`). Branch-only changes do not detach. PR discovery reruns (`ThreadPullRequestService.ts:368-371`).

Internal users: launch uses command ids `` `${launchCommandId}:workspace` ``, `` `:branch-rename` ``, `` `:cancel-workspace` `` and the `expectedEmpty` claim (`TLS:415-423,449-456,588-595,767-774`). The official client sends only defined fields and sends a model change as a separate command with id `` `${commandId}:model-selection` `` (`commands.ts:560-602`).

### 6.15 `thread.title.regeneration.complete`

Payload `{ type, commandId, threadId, requestId: CommandId, title?: TrimmedNonEmptyString }` (`C:2805-2811`). Rejections: deleted. If `thread.titleRegeneration?.requestId === requestId`: `title` set if provided, `titleRegeneration: null`, `updatedAt: now`; otherwise the payload is unchanged (a no-op event) (`O:3159-3167`). Event `thread.metadata-updated` (`O:3208-3210`).

Pipeline: `thread-title.generate` effect handled by the effect worker (`EffectWorker.ts:464-470`) calls `ThreadTitleRegenerationService.execute` (`ThreadTitleRegenerationService.ts:62-145`): stale if the marker's requestId differs; project missing, empty context, generated `"New thread"`, or (regenerate) unchanged title all complete without a title; failures retry 2 times for initial titles (exponential from 2 s) and 0 times for regeneration, then complete without a title. Completion command id `` `${requestId}:title-complete` `` (`ThreadTitleRegenerationService.ts:47-60`).
Initial title: `message.dispatch` with `titleSeed` on a thread with zero messages emits `thread.metadata-updated` with `title = titleSeed` and `titleRegeneration = { requestId: messageCommandId, startedAt }` and enqueues `thread-title.generate { kind: { type: "initial", messageId } }` (`O:4606-4642`); skipped for `/compact` and `/logout` (`O:405-415`). Archive and delete clear `titleRegeneration`, making a late completion a no-op.

### 6.16 Pull request commands

Shared types (`packages/contracts/src/threadPullRequest.ts`): key `{ host, repository, number: PositiveInt }` (89-94); link `{ ...key, url, source, linkedAt: IsoDateTime, snapshot: ThreadPullRequestSnapshot|null, stack: ThreadPullRequestStack|null, watch?: ThreadPullRequestWatch }` (127-135); sources `"manual" | "created" | "agent" | "stack" | "stack-dismissed"` (35-41; `stack-dismissed` is a tombstone clients hide); watch (102-124); snapshot (49-66); stack (77-84). Keys are normalized (lowercase, canonical host/repository, Forgejo port recovered from the URL, Azure canonicalization) for comparison AND storage (`packages/shared/src/threadPullRequests.ts:19-37,66-77`). When `pullRequests` is absent a legacy `linkedPullRequest` is read as one manual link (`threadPullRequests.ts:329-347`).

`thread.pull-request.link` payload `{ type, commandId, threadId, host, repository, number, url: TrimmedNonEmptyString, source }` (`C:2755-2762`).
- Rejections: deleted only (archived and settled allowed).
- If a link with the same key exists and this is not an un-dismiss (existing `stack-dismissed` and new source not `stack`/`stack-dismissed`): no change, unchanged payload, no `updatedAt` bump.
- Otherwise (`O:2977-3022`): an existing link gets the new `source` and `url`; a new link is `{ ...normalizedKey, url, source, linkedAt: now ISO, snapshot: null, stack: null }` appended at the end. If `source === "manual"`, the thread has a `branchPullRequest`, there are no visible links yet, and the branch PR is a different, not yet linked PR, the branch PR is first materialized as a manual link. Legacy `linkedPullRequest` is kept only if still visible, else null (`O:3052-3066`). `updatedAt = now`. Event `thread.pull-request-synced`. Tested: duplicate links are no-ops and order is preserved (`runtimeLayer.test.ts:2029-2116`).

`thread.pull-request.unlink` payload `{ type, commandId, threadId, host, repository, number }` (`C:2763-2768`). Rejections: deleted. Missing link: no change. A link that belongs to a stack (source `stack`, has `stack` info, or is a layer of a sibling's native stack) becomes `source: "stack-dismissed"` with its watch removed; any other link is removed (`O:3023-3043`). `updatedAt = now`. Event `thread.pull-request-synced`.

`thread.pull-request-link.sync` payload `{ type, commandId, threadId, host, repository, number, snapshot: ThreadPullRequestSnapshot, stack: ThreadPullRequestStack|null }` (`C:2769-2776`). Server-sent by `PullRequestSyncReactor` (command id `` `server:pr-sync:${threadId}:${uuid}` ``), which also auto-links native stack layers with `thread.pull-request.link` `source: "stack"` (command id `` `server:pr-stack-link:${threadId}:${uuid}` ``) on unsettled threads (`PullRequestSyncReactor.ts:218-274`). Missing link: no change; else sets that link's `snapshot` and `stack`; payload `updatedAt` unchanged (`O:3044-3051,3067`). Event `thread.pull-request-synced`.

`thread.pull-request.watch` payload `{ type, commandId, threadId, host, repository, number, watching: boolean, link?: { url, source } }` (`C:2777-2788`).
- Rejections when `watching: true`: provider-native subagent (`OrchestratorSubagentThreadReadOnlyError`); `` `Thread ${threadId} is settled or archived and cannot watch pull requests.` `` (`settledOverride === "settled"`, `settledAt` set, or archived); `` `Thread ${threadId} is a subagent; its parent thread watches pull requests.` ``; when `link.source === "agent"` and the latest executed run has a `run_interrupt_request` turn item: `` `Thread ${threadId} was stopped.` `` (`O:2417-2471,8401-8414`). Deleted is rejected for both values.
- Change (`O:3070-3125`): with `watching: true` and `link` given and no visible link for the key, the link is created (or replaces a dismissed one) with `source = link.source`, `linkedAt = now`. No visible link: no change (NOT rejected). `watching: false` removes the watch. `watching: true` keeps an existing watch or creates `{ startedAt: now ISO, headSha: null, failedChecks: [], passed: false, passedChecks: [], remarksThrough: startedAt, remarkIds: [], conflicting: false, wakes: 0 }`. `updatedAt = now` when changed. Event `thread.pull-request-synced`.
- A watched link appears in the shell as a pending background task `{ taskId: "pull-request-watch:<host>/<repo>#<n>", description: "Watching pull request #<n>", kind: "monitor" }` (`ProjectionStore.test.ts:4789-4810`). Archive and settle remove all watches (`O:2781,2796`).

`thread.pull-request-watch.sync` (internal) payload `{ type, commandId, threadId, host, repository, number, startedAt: IsoDateTime, watch: ThreadPullRequestWatch|null, wake?: { messageId, text, notification } }` (`C:3063-3083`). Handler (`O:2310-2365`): rejected with `"The pull request watch ended or its thread settled while it was read."` if the visible link's `watch.startedAt !== startedAt`, or `wake` is present while the thread is archived, settled or a provider-native subagent. Records the watch (null ends it) with no `updatedAt` bump, then if `wake` dispatches `message.dispatch` with the notification, `createdBy: "agent"`, `creationSource: "server"`, `dispatchMode: { type: "queue_after_active" }`. Sender `PullRequestWatchReactor` (every 2 minutes; gives up after 8 consecutive failed reads with a wake; comment-only wake limit 10) (`PullRequestWatchReactor.ts:39-56,306-340`; `pullRequestWatch.ts:9-13`). Tested start/record/stop and stale late record (`runtimeLayer.test.ts:2210-2300`).

`thread.pull-request.sync` payload `{ type, commandId, threadId, projectId, snapshotSequence: NonNegativeInt, expected: { workspaceRoot, branch|null, worktreePath|null, linkedPullRequest|null, branchPullRequest|null }, branchPullRequest: ThreadLinkedPullRequest|null, linkedPullRequest?: ThreadLinkedPullRequest }` (`C:2789-2804`). Server-sent by `ThreadPullRequestService`, command id `` `server:thread-pull-request:${threadId}:${uuid}` `` (`ThreadPullRequestService.ts:297-324`). Rejections: deleted; archived; `` `Thread ${threadId} changed before pull request discovery.` `` when the project is missing/deleted, its `workspaceRoot` changed, the thread's latest event sequence exceeds `snapshotSequence`, or `projectId/branch/worktreePath/linkedPullRequest/branchPullRequest` differ from `expected` (`O:2550-2584`). Change: `branchPullRequest` replaced; optional legacy `linkedPullRequest` replacement with the same `pullRequests` rebuild as metadata.update; `updatedAt` unchanged (`O:3126-3158`). Event `thread.pull-request-synced`. Discovery triggers: `thread.created`, `thread.unarchived`, `thread.metadata-updated` (no refresh); `thread.unsettled`, `checkpoint.captured`, terminal `run.updated` (refresh); and every minute (`ThreadPullRequestService.ts:366-403`).

### 6.17 `thread.runtime-mode.set`, `thread.interaction-mode.set`, `thread.model-selection.set`

`thread.runtime-mode.set` payload `{ type, commandId, threadId, runtimeMode }` (`C:2812-2817`). Rejections: deleted only (no archived and no active-run guard). Change: `runtimeMode`, `updatedAt = now` (`O:3168-3169`). Event `thread.runtime-mode-updated`. Live sessions whose `capabilities.sessions.supportsRuntimeModeSwitchInSession` is false get `provider-session.detached` plus a detach effect with `"Runtime mode changed."` (`O:3326-3331`); Codex and Antigravity declare true, Claude false (`Adapters/CodexAdapterV2.ts:255`, `Adapters/AntigravityAdapterV2.ts:51`, `Adapters/ClaudeAdapterV2.ts:187`). Effect on an in-flight turn: UNVERIFIED.

`thread.interaction-mode.set` payload `{ type, commandId, threadId, interactionMode }` (`C:2818-2823`). Rejections: deleted only. Change: `interactionMode`, `updatedAt = now` (`O:3170-3171`). No session change; interaction mode is turn-scoped and applied when the next turn starts (`ProviderSessionTransitionPolicy.ts:94-95`). Event `thread.interaction-mode-updated`.

`thread.model-selection.set` payload `{ type, commandId, threadId, modelSelection: { instanceId, model, options? } }` (`C:2824-2829`).
- Rejections: deleted; no adapter for `modelSelection.instanceId`: `OrchestratorProviderAdapterError` (`` `Provider adapter failed while dispatching orchestration command ${commandId}.` ``, a generic prefix, so the wire message comes from its cause) (`O:177-188,2672-2684`); `ProviderSwitchService.plan` rejection: `OrchestratorDispatchError` wrapping `ProviderSwitchPlanError { threadId, targetProviderInstanceId, cause: reason }`, reasons `"The target provider instance is unavailable."`, `"The provider adapter did not classify the selection change."`, or adapter-specific (`apps/server/src/orchestration-v2/ProviderSwitchService.ts:123-174`; `ProviderSessionTransitionPolicy.ts:34-96`).
- No active-run guard; no validation of the model string beyond the adapter's `planSelectionTransition`.
- Change: `providerInstanceId` and `modelSelection` replaced, `updatedAt = now` (`O:3172-3179`). Event `thread.model-selection-updated` if the instance is unchanged, else `thread.provider-switched` (`O:3222-3225`; test `runtimeLayer.test.ts:483`).
- Sessions released by the plan (transition `restart_and_resume`: the current live session; `create_with_handoff`: live sessions of other instances; `reuse` and `switch_model_in_session`: none) get `provider-session.detached` plus a detach effect with `"Provider or model selection changed."` (`ProviderSwitchService.ts:186-199`; `O:3332`; test `SelectionRestart.integration.test.ts:656-704`).

### 6.18 `thread.fork`

Payload (`C:2982-2991`): `{ type: "thread.fork", createdBy, creationSource, commandId, sourceThreadId, targetThreadId, sourcePoint, title?: TrimmedNonEmptyString, createdAt?: DateTimeUtc }`. `sourcePoint` (`C:134-139`): `{ type: "latest_stable" } | { type: "run", runId } | { type: "checkpoint", checkpointId }`. Lock/receipt thread = `targetThreadId`; `createdBy` forced to `"user"` over WS. Official client uses `{ type: "run", runId }` (`commands.ts:937-950`).

Source run resolution (`O:607-638`): `latest_stable` = highest-ordinal run with `status: "completed"` and a non-null `checkpointId`; `run` = that run; `checkpoint` = the run owning that checkpoint.

Rejections (`O:3503-3540`; `ThreadForkService.ts:40-54`): source thread missing (`OrchestratorProjectionError`); `` `No stable source run was found for fork source ${sourcePoint.type}.` ``; source run status not in completed/waiting/failed/interrupted/cancelled: `` `Fork source run ${runId} is ${status}; in-progress and rolled-back runs cannot be forked.` ``. Not checked: source archived/deleted, or `targetThreadId` already existing (consequences UNVERIFIED).

Target thread (`ThreadForkService.ts:88-114`): a spread copy of the source thread with overrides `createdBy`, `creationSource`, `id = targetThreadId`, `title = title ?? \`${source.title} fork\``, `activeProviderThreadId: null`, `lineage: { parentThreadId: source.id, relationshipToParent: "fork", rootThreadId: source.lineage.rootThreadId }`, `forkedFrom: { type: "run", threadId: source.id, runId }`, `createdAt = updatedAt = command.createdAt ?? now`, and `archivedAt, settledOverride, settledAt, snoozedUntil, snoozedAt, lastVisitedAt, deletedAt` all null. Copied unchanged: `projectId, providerInstanceId, modelSelection, runtimeMode, interactionMode, branch, worktreePath` (the fork shares the source's worktree, `ThreadForkService.test.ts:142-169`) and every other field not overridden (for example `pinnedAt, pinOrderKey, activeOrderKey, autoSettleDisabledAt, pullRequests` including watches, `linkedPullRequest, branchPullRequest, limitRecovery, titleRegeneration, unsettledAt, historyOrigin`). Whether copying those is intended: UNVERIFIED.

Events (`O:3544-3579`; `ThreadForkService.ts:115-135`): `thread.created` for the target, then `context-transfer.created` `{ id (allocated), type: "fork", sourceThreadId, targetThreadId, sourcePoint: { threadId, runId, checkpointId?, providerThreadRef?, providerTurnRef? } (O:666-686), basePoint: null, sourceProviderInstanceId: sourceRun.providerInstanceId, targetProviderInstanceId: null, targetRunId: null, status: "pending", resolution: null, createdBy, error: null or "Source provider thread does not expose a strong native thread ref.", createdAt, updatedAt, consumedAt: null }`. No messages are copied. The fork's `visibleTurnItems` show the source's items through the source run ("inherited"), a synthetic fork marker, then local items (`ProjectionStore.ts:1312-1347`). The pending transfer is resolved on the fork's first `message.dispatch` as native fork or portable context per `CommandPolicy.decideForkExecution`, recorded with `context-transfer.updated` (`O:5126,5634-5660,6162-6212`).

### 6.19 `secret_request.record` (internal) and answering secrets

Payload (`C:3116-3131`): `{ type, commandId, threadId, runId, nodeId, turnItemId, label: TrimmedNonEmptyString, reason: string, placeholder?: string, secretStatus: "pending"|"saved"|"declined"|"cancelled" }` (`C:1352-1358`). Doc: internal "so no client can mark a request saved without the value being stored".

Handler (`O:6968-7059`). Rejections: `` `Node ${nodeId} is not the root of run ${runId}.` `` (run missing or node not its root); `` `Turn item ${turnItemId} is not a secret request.` ``; `` `Secret request ${turnItemId} belongs to another run.` ``. If the card exists and is already non-pending, or the new status is `pending`, the existing item is re-emitted unchanged. Otherwise a `secret_request` turn item (`C:1360-1370`) with `status` `waiting` (pending) / `completed` (saved) / `cancelled` (declined, cancelled), `title = label`, `completedAt` null only while pending. Event `turn-item.updated`. The secret value never passes through orchestration.

Client answer: WS `secrets.answerRequest` `{ threadId, turnItemId, answer: { type: "save", secret: TrimmedNonEmptyString } | { type: "decline" } }`, no success payload, error `SecretRequestError { reason, cause? }` (`packages/contracts/src/secretRequest.ts:9-52`; `rpc.ts:1757-1760`). Reasons and messages: `load_failed "Could not load the secret request."`, `not_found "This secret request no longer exists."`, `already_answered "This secret request was already answered."`, `agent_stopped "The agent that asked has stopped, so this secret can't be used."`, `store_failed "Could not store the secret."`, `record_failed "Saved the secret, but could not update the request."` (plus ref-consumption reasons). Server flow: validate card and run, store the value first, then dispatch `secret_request.record` with command id `` `secret-request:${itemId}:${"saved"|"declined"}` ``; if the card did not end up saved the stored value is deleted and `agent_stopped` returned (`apps/server/src/secrets/SecretRequests.ts:98-186`).

---

## 7. `orchestration.launchThread`

### 7.1 Schema

Input (`C:3182-3202`):
```
{ commandId: CommandId,
  creationSource?: "web"|"mobile"|"mcp"|"provider"|"server",   // default "web"
  threadId?: ThreadId,                 // optional: server allocates if absent
  reuseExistingThread?: boolean,       // claim an existing EMPTY thread instead of creating one
  projectId: ProjectId,
  title: TrimmedNonEmptyString,
  generateTitle?: boolean,             // with initialMessage: title is a temporary seed, real title generated
  modelSelection: ModelSelection,
  runtimeMode: RuntimeMode,
  interactionMode: ProviderInteractionMode,
  workspaceStrategy: WorkspaceStrategy,
  initialMessage?: { messageId?: MessageId, text: string, context?: OrchestrationMessageContext, attachments: ChatAttachment[] } }
```
Workspace strategy (`C:518-536`):
- `{ type: "root", branch?: TrimmedNonEmptyString }`
- `{ type: "existing_worktree", worktreePath: TrimmedNonEmptyString, branch?: TrimmedNonEmptyString }`
- `{ type: "worktree", baseRef: TrimmedNonEmptyString, branch?: TrimmedNonEmptyString, startFromOrigin?: boolean }`

Output `{ threadId, projection: OrchestrationV2ThreadProjection, resumed: boolean }` (`C:3205-3209`); the projection is wire-projected (`ws.ts:2003-2006`).
Error `OrchestrationV2ThreadLaunchError { commandId, projectId, message: string, cause?: Defect }` (`C:3423-3431`) or `EnvironmentAuthorizationError` (`rpc.ts:1635-1639`).
Constant: `ORCHESTRATION_V2_WORKSPACE_PREPARATION_FAILURE_CODE = "workspace_preparation_failed"` (`C:538-539`).

### 7.2 Handler and error mapping

`ws.ts:1949-2032`: enqueued behind startup; builds the launch input with `createdBy: "user"`, `creationSource: input.creationSource ?? "web"`; calls `ThreadMessageIntake.launchThread`. Errors: `AttachmentClaimError` maps to `message = cause.message`; `ThreadLaunchError` and `ServerRuntimeStartupError` map to `message: "Failed to launch thread"` with `cause` (`ws.ts:2007-2029`). So every non-attachment failure surfaces as `"Failed to launch thread"`; the reason is only inside `cause` (encoding UNVERIFIED). `ThreadLaunchError` (`TLS:124-148`) has `operation` in `resolve-project, read-receipt, generate-metadata, provision-worktree, run-setup-script, create-thread, update-thread, dispatch-message, release-run, fail-run`, message `` `Thread launch ${commandId} failed during ${operation}.` ``.

Pre-step (`ThreadMessageIntake.ts:182-240`): validates attachment limits; if any initial attachment is a pending upload and `threadId` is absent, fails `"Uploaded attachments need a thread id at launch."`; claims attachments into the thread; on failures known not to have been accepted, releases claims.

### 7.3 Launch steps (`TLS:684-907`)

1. Clone guard (`TLS:686-689`; `apps/server/src/project/ProjectCloneTracker.ts:443-463`): fails `"The repository is still being cloned."` or `"The repository was not cloned. Retry the clone first."` (operation resolve-project).
2. Project lookup: `"Project not found."` (`TLS:690-698`).
3. `reuseExistingThread` without `threadId`: `"Reusing an existing thread requires a thread id."` (update-thread) (`TLS:699-704`).
4. Reads the receipt of `commandId`. If `threadId` is absent and an accepted `thread.create` receipt exists for this command id, the thread id is recovered from it; else the server allocates `` `thread:project:${encodeURIComponent(projectId)}:${uuid}` `` (`TLS:706-724`; `packages/provider-core/src/server/IdAllocator.ts:192-195,297-306`). On a recovered receipt the shell must exist (`"Thread not found."`) and belong to the same project (`"Project identity changed."`) (`TLS:726-740`; tests `ThreadLaunchService.test.ts:1561-1680`). A command id previously used by an unrelated command fails with a create-thread error whose cause contains "cannot be replayed" (`ThreadLaunchService.test.ts:1682-1721`).
5. `reuseExistingThread` (first attempt only): the thread must be in the project, not archived, not deleted, with zero messages and zero runs, else `"Only an empty active thread in the target project can change workspace during launch."` (`TLS:208-230,742-744`).
6. Scratch: for `root` on the first attempt, if the project is the Scratch project, a fresh folder `<scratchRoot>/<YYYY-MM-DD>-<words>-<id tail>` is claimed and the strategy becomes `existing_worktree` with that folder (`TLS:746-763`; `apps/server/src/project/ManagedProjectFolders.ts:341-371`).
7. Claim (`TLS:764-806`): reuse path dispatches `thread.metadata.update { commandId: launchCommandId, threadId, expectedEmpty: true }`; otherwise `thread.create` with `commandId: launchCommandId`, `branch = strategy.branch ?? null`, `worktreePath = strategy.worktreePath` for `existing_worktree` else null, plus title, modes, model, provenance. In the reuse path `title`, `runtimeMode` and `interactionMode` from the input are NOT applied to the thread (only `thread.create` uses them); `title` is used only as `titleSeed` when `generateTitle` is true (`TLS:834`).
8. Initial message (`TLS:808-852`): `message.dispatch` with `commandId: \`${launchCommandId}:initial-message\``, `messageId = given ?? \`message:thread:${threadId}:ordinal:1:${uuid}\``, text/attachments/context, `titleSeed: title` if `generateTitle`, `modelSelection: input.modelSelection`, `dispatchMode: { type: "defer_start", workspaceStrategy }`. Must produce `run.created`, else `"Initial message was accepted without a durable run."`. If this step fails (for example unknown provider instance, `O:5202-5211`), the thread created in step 7 remains; retrying with the same `commandId` replays the create and retries the message.
9. Reads the projection; schedules workspace preparation once per command id in-process when there is a preparing run (or no message and no prior receipt) (`TLS:854-898`).
10. Returns `{ threadId, projection, resumed: launchReceiptExisted || messageReceiptExisted }` (`TLS:900-904`).

`defer_start` in `message.dispatch` (`O:5274-5324,5408-5431,5519-5527`): creates the run with `status: "preparing"`, `workspacePreparation = strategy` (`C:582-583`), no checkpoint scope yet, and a `command_execution` turn item with `status: "running"`, `title` and `input` `"Preparing workspace"` (id derived from `` `workspace-preparation:${runId}` ``), and does NOT enqueue `provider-turn.start`. If the thread already has a blocking run, the message is queued instead (`O:4847-4852`). A client that sends `message.dispatch` with `defer_start` directly (without launch) leaves the run preparing until something sends `prepared-run.release`.

### 7.4 Background workspace preparation (`TLS:232-611`)

- Setup tracker card is created only for `worktree` (stages fetch, checkout, setup-script, agent) or a reused worktree on retry (stages setup-script, agent) (`TLS:248-269`).
- Branch: explicit `branch`, otherwise for `worktree` a temporary `t3/<8 hex>`, flattened to `t3-<8 hex>` when a plain `t3` branch exists (`TLS:306-316,371-382`; `packages/shared/src/git.ts:14-26,119-145`).
- `worktree` strategy: `prepared-run.progress` phase `worktree` (`` `${commandId}:progress:worktree` ``, item title becomes `"Preparing worktree"`, `O:7799-7834`); with `startFromOrigin: true` and an `origin` remote, fetches `origin <baseRef>` and starts from the remote tracking commit when the remote branch exists, else from local `baseRef` (`TLS:333-370`); `git worktree add -b <branch> <path> <startRef>` with a server-chosen path `<worktreesDir>/<basename(projectRoot)>/<branch with "/" replaced by "-">`, where `worktreesDir` is `ServerSettings.worktreesDirectory` (absolute, `~` expanded) or `<T3 home>/worktrees` when empty (`apps/server/src/vcs/GitVcsDriverCore.ts:3395-3416`; `apps/server/src/worktreesDirectory.ts:12-22`; `apps/server/src/git/GitManager.ts:760-774`; `packages/contracts/src/settings.ts:1121-1125`). A non-absolute or root setting fails with `` `The worktree location "${...}" must be an absolute folder on this machine, not a drive root. Change it in Settings → Storage.` ``.
- Records the workspace with `thread.metadata.update { commandId: \`${commandId}:workspace\`, branch, worktreePath }` (skipped for a reused worktree) (`TLS:412-425`). For `root`, this records `worktreePath: null` and the requested branch (no checkout of that branch by the launch service was seen: UNVERIFIED whether anything checks it out). For `existing_worktree` no path existence check was seen (UNVERIFIED).
- Temporary branch rename in background (only with an initial message): generates a name with the project's branch naming settings and source-control writer model, `git branch` rename, then `thread.metadata.update` `` `${commandId}:branch-rename` ``; on failure the temporary name stays (`TLS:272-304,427-468`).
- `prepared-run.progress` phase `setup` (title `"Starting setup script"`), then runs the project setup script for EVERY strategy (root and existing_worktree too; tested with root at `ThreadLaunchService.test.ts:464-509` and default root in `launchInput`, lines 248-275) in `cwd = worktreePath ?? projectRoot` (`TLS:470-503`).
- Setup script selection: first script with `runOnWorktreeCreate: true` from the resolved project scripts (`packages/shared/src/projectScripts.ts:17-27,73-75`). Runs in terminal `` `setup-${script.id}` `` with env `T3CODE_PROJECT_ROOT`, `T3CODE_WORKTREE_PATH`, `COLORTERM=""`, `NO_COLOR=1`, `FORCE_COLOR=0`; completion detected by a per-run sentinel; `async = script.async !== false` (`apps/server/src/project/ProjectSetupScriptRunner.ts:312-480`). Non-async with a non-zero exit fails `` `Setup script exited with ${exitCode ?? "no exit code"}.` ``; async failures only mark the stage failed and the launch continues (`TLS:505-547`; test `ThreadLaunchService.test.ts:2216-2271`). A clean exit closes the idle setup shell.
- Marks the setup uncancellable, dispatches `prepared-run.release` (`` `${commandId}:release` ``) (`TLS:548-562`). Release handler (`O:7836-7923`): resolves runtime policy, creates the checkpoint scope in the final cwd, emits `checkpoint-scope.created`, `node.updated` (with `checkpointScopeId`), the preparation item `completed` with title `"Workspace ready"`, output `"Workspace preparation completed."`, exit code 0, `run.updated` with status `"starting"`; effect `provider-turn.start`. Release/progress/fail on a run not in preparing: `` `Run ${runId} is not awaiting workspace preparation.` `` (`O:7757-7816`).
- On failure (`TLS:563-610,613-647,664-682`): tracker finished `failed` (or `cancelled`); a created worktree is removed with force only if cancelled or not yet recorded on the thread, followed by `thread.metadata.update` `` `${commandId}:cancel-workspace` `` with `worktreePath: null, branch: null`; then `prepared-run.fail` (`` `${commandId}:fail` ``) with failure `{ class: "validation_error", message, code: null, retryable: false }` where the message is `` `Workspace preparation failed during ${operation with spaces}: ${detail}` `` for launch errors or `` `Workspace preparation failed: ${detail}` `` (`TLS:165-172`; `packages/provider-core/src/server/failure.ts:147-172`).
- `prepared-run.fail` events (`O:7925-8021`): attempt failed, root node failed, preparation item `failed` with title `"Workspace preparation failed"`, output = failure message, exit code 1; a new `error` turn item (id derived from `` `workspace-preparation-failure:${runId}` ``, title `"Workspace preparation failed"`, `failure: { ...failure, code: "workspace_preparation_failed" }`); `run.updated` status `"failed"`. These arrive on the thread stream after the RPC already returned.

### 7.5 Retry, cancel, progress stream

- Retry: client sends `prepared-run.retry { commandId, threadId, runId }` through `dispatchCommand` (`C:2904-2910`), routed to `retryPreparation` (`ws.ts:1840-1841`). Decider (`O:8028-8105`) rejects `` `Run ${runId} has no failed workspace preparation to retry.` `` (run not failed, no `workspacePreparation`, no failed error item with the code, thread archived or deleted, or missing attempt/node/provider thread/preparation item) and `"Another run is active on this thread."`. Events: failure item to `cancelled`, preparation item back to `running` (output and exit code dropped, title `"Preparing workspace"`), attempt `pending`, node `pending`, run `preparing`. Then preparation is scheduled again; a `worktree` strategy whose thread already recorded a worktree reuses it as `existing_worktree` without re-recording or renaming (`TLS:909-978`; tests `ThreadLaunchService.test.ts:1355-1487`). A second retry after release is rejected (`ThreadLaunchService.test.ts:1417-1421`). Client rule for offering Retry: run `status === "failed"`, `workspacePreparation !== undefined`, and a failed `error` item with the code for that run (`packages/client-runtime/src/state/turnItemPresentation.ts:22-49`).
- Cancel: WS `worktreeSetup.cancel { threadId }` returns `{ cancelled: boolean }`; interrupts the preparation fiber only while the phase is running and before it was marked uncancellable (`apps/server/src/project/WorktreeSetupTracker.ts:299-317`; `ws.ts:2789-2792`). Result: tracker phase `cancelled`, created worktree removed, thread `worktreePath` null, run failed with message `"Workspace preparation failed: Worktree setup cancelled."`, no release effect (test `ThreadLaunchService.test.ts:2186-2214`).
- Progress: WS `subscribeWorktreeSetup { threadId }` streams `WorktreeSetupSnapshot | null`: current value first, then every change; sliding buffer of 1; finished snapshots kept 30 s; `sequence` keeps increasing across setups of one thread (`WorktreeSetupTracker.ts:98-130,171-196,322-350`). Snapshot schema (`packages/contracts/src/worktreeSetup.ts:15-101`): `threadId, phase: "running"|"done"|"failed"|"cancelled", startedAt, endedAt, branch, baseRef, worktreePath, setupScript: {name, command, terminalId}|null, stages[] { id: "fetch"|"checkout"|"submodules"|"setup-script"|"agent", status: "pending"|"running"|"done"|"skipped"|"warning"|"failed", startedAt, endedAt, percent (checkout only), detail (max 200), tail (max 4 lines of 400) }, error (max 1000), sequence`. In-memory only, not persisted.

### 7.6 Official client usage

`startThreadTurn` (`commands.ts:626-687`): a draft with bootstrap uses `launchThread` with `threadId` (client UUID) and `workspaceStrategy` derived from the draft (`worktree` with `baseRef`, optional `branch`, `startFromOrigin`; else `existing_worktree`; else `root`), `generateTitle: titleSeed !== undefined`; an existing empty thread uses `reuseExistingThread: true`. Server bootstrap at startup launches `"New thread"` with `createdBy: "system"`, `creationSource: "server"`, root strategy (`serverRuntimeStartup.ts:290-301`).

---

## 8. Projects

### 8.1 RPCs

- WS `projects.mutate` (`rpc.ts:370,1187-1191`): payload `ProjectMutation`, success `Project`, error `ProjectMutationError { commandId, message, cause? }` (`packages/contracts/src/project.ts:242-249`) or `EnvironmentAuthorizationError`.
- HTTP `GET /api/projects` returns `ProjectSnapshot { projects: Project[], updatedAt }`; `POST /api/projects/mutate` takes `ProjectMutation` and returns `Project` (`packages/contracts/src/environmentHttp.ts:643-658`). HTTP errors: not-found, conflict and not-empty map to invalid request `invalid_command`; everything else to internal `project_mutation_failed` (`apps/server/src/project/http.ts:20-31`).
- `projects.list`, `projects.add`, `projects.remove` exist only as names in `WS_METHODS` (`rpc.ts:362-364`); no Rpc definition or handler was found (dead names).
- `projects.ensureScratch {}` returns `{ projectId }`: finds or creates the Scratch project titled `"No project"` at the scratch root, icon `{ kind: "lucide", name: "message-square-dashed", color: "gray" }`, command id `` `scratch-project:${uuid}` `` (`rpc.ts:1193-1198`; `ManagedProjectFolders.ts:282-329`); error `"Threads without a project are not available on this environment."` when unavailable.
- `projects.createNew { name: TrimmedNonEmptyString (max 200) }` returns `{ projectId, workspaceRoot, commitError? }`: folder `<baseDir>/projects/<slug>` (suffix `-2`, `-3`, ...), `git init`, `README.md`, `assets/icon.svg`, first commit (a commit failure is returned in `commitError`), command id `` `named-project:${uuid}` `` (`project.ts:527-539`; `ManagedProjectFolders.ts:373-499`).
- `projectClone.start/cancel/retry`, `subscribeProjectClones` (`rpc.ts:1120-1149`; `ws.ts:2548-2599`): creates the project with command id `` `project-clone-create:${projectId}` `` and `createWorkspaceRootIfMissing: true`; after cloning, an empty update `` `project-clone-done:${projectId}` `` refreshes it.
- Errors of ensureScratch/createNew/clone-create are `OrchestrationDispatchCommandError { message, cause?, bootstrapThreadDisposition? }` (`packages/contracts/src/orchestrationDispatch.ts:9-16`).

### 8.2 Payloads (`project.ts:199-240`)

```
{ type: "project.create", commandId, projectId,                 // projectId client-allocated
  title: TrimmedNonEmptyString, workspaceRoot: TrimmedNonEmptyString,
  createWorkspaceRootIfMissing?: boolean,
  defaultModelSelection?: ModelSelection | null,                // accepted but IGNORED
  scripts?: ProjectScript[] }
{ type: "project.update", commandId, projectId,
  title?, workspaceRoot?, defaultModelSelection?: |null, autoPull?: boolean,
  projectIcon?: ProjectIconOverride | null, faviconPath?: string | null,
  defaultThreadEnvMode?: "local"|"worktree"|null, scripts?: ProjectScript[] }
{ type: "project.delete", commandId, projectId, force?: boolean }
```
`ProjectScript` (`project.ts:33-45`): `{ id, name, command, icon: "play"|"test"|"lint"|"configure"|"build"|"debug", runOnWorktreeCreate: boolean, runOnSettle?, async?, previewUrl?, autoOpenPreview? }`. Icons (`project.ts:48-110`): `{kind:"lucide", name, color}`, `{kind:"emoji", emoji}`, `{kind:"monogram", text, color}`.

### 8.3 Server behavior

Mapping `apps/server/src/project/ProjectMutation.ts:8-53` to `ProjectService` (`apps/server/src/project/ProjectService.ts`). Commits run under a per-project lock and, for commands carrying a workspace root, a per-root lock (`ProjectService.ts:156-159,265-272`).

- Workspace root normalization (`apps/server/src/workspace/WorkspacePaths.ts:152-191`): trim, `~` expansion, `path.resolve` (no realpath); must exist and be a directory unless `createWorkspaceRootIfMissing`.
- create (`ProjectService.ts:337-355`; planner `apps/server/src/orchestration-v2/ProjectCommands.ts:156-181`): rejects if a row with the id exists, even soft-deleted (`` `Project '${projectId}' already exists and cannot be created twice.` ``) or the root is held by another active project. Event `project.created` with `defaultModelSelection: null` (client value dropped by design), `faviconPath: null`, `projectIcon: null`, `scripts ?? []`. Script ids are not validated at create. Returns the hydrated `Project` (repository identity and favicon from enrichment). Retrying the same command id returns the same project (`runtimeLayer.test.ts:4691-4693`).
- update (`ProjectService.ts:357-393`; planner `ProjectCommands.ts:183-229`): `ProjectNotFoundError` if missing or deleted; `workspaceRoot` omitted when unchanged after normalization; patch semantics, `null` clears nullable fields. Validation: monogram at most 2 graphemes (`"Project monograms must contain at most two characters."`); new script ids must match `^[a-z0-9][a-z0-9-]*$` with max 24 chars (existing ids grandfathered), message `` `Script IDs must be 1-24 lowercase letters, digits or hyphens, starting with a letter or digit (got ${n} characters).` `` (`packages/contracts/src/keybindings.ts:7,116-123`); root conflict. Event `project.meta-updated` with only the changed fields plus `updatedAt`.
- delete (`ProjectService.ts:404-506`): `ProjectNotFoundError` if no row; if active and any active or archived thread belongs to the project and `force !== true`: `ProjectNotEmptyError`; with force, each thread is deleted durably with `planThreadDeletion` and command id `` `${commandId}:delete-thread:${threadId}` `` sequentially under the thread lock, then `project.deleted` (soft delete). Same command id retried returns the deleted project; a new command id on a deleted project gives `ProjectNotFoundError` (`ProjectService.test.ts:406-456`). The clone tracker entry is discarded (`ws.ts:1810-1815`).
- Receipts (`ProjectService.ts:273-295`): a reused command id resolves to its first receipt; different type or project: `` `Command ${commandId} was already used by ${commandType} for ${projectId}.` ``; rejected receipts replay the stored typed rejection.
- Errors (`ProjectService.ts:54-110`): `ProjectNotFoundError` `` `Project ${projectId} was not found.` ``; `ProjectConflictError` `` `Workspace ${workspaceRoot} already belongs to project ${conflictingProjectId}.` ``; `ProjectNotEmptyError` `` `Project ${projectId} is not empty.` ``; `ProjectOperationError` `` `Project operation '${operation}' failed for ${projectId}.` ``. Planner errors (`ProjectCommands.ts:50-92`).
- WS error mapping (`ws.ts:2668-2681`): `message = cause.message` only for `ProjectNotEmptyError`, otherwise `"Failed to mutate project."`. Conflict and not-found are not distinguishable by `message` on WS (only through `cause`, encoding UNVERIFIED).

### 8.4 Project events and how clients see project changes

- Internal events (`packages/contracts/src/applicationEvent.ts:43-121`): `project.created`, `project.meta-updated`, `project.deleted` with base fields `sequence, eventId, aggregateKind: "project", aggregateId, occurredAt, commandId, causationEventId, correlationId, metadata`. Clients do not receive them raw.
- Row and shell (`apps/server/src/orchestration-v2/ProjectStore.ts:32-72`; `packages/contracts/src/orchestrationProject.ts:9-27`): `OrchestrationProjectShell { id, title, workspaceRoot, repositoryIdentity?, defaultModelSelection|null, defaultThreadEnvMode?, autoPull?, faviconPath?, projectIcon?, scripts, createdAt, updatedAt }` (no `deletedAt`). In the shell `faviconPath` is the stored override only and `repositoryIdentity` is enriched; the `Project` type falls back to the enriched favicon (`ProjectService.ts:161-178`; `ws.ts:715-745`).
- `subscribeShell` (`ws.ts:943-1185`): initial `snapshot` with active projects ordered `created_at ASC, project_id ASC` (`ProjectStore.ts:138`). Live items per project event: `{ kind: "project.updated", sequence, project }` or `{ kind: "project.removed", sequence, projectId }` for `project.deleted` or when the shell read finds nothing (`ws.ts:986-1009`). Events are batched (512 per 50 ms) and coalesced to the newest per project/thread (`ShellStream.ts:85-100`; `ws.ts:1032-1038`).
- Repository identity refreshes arrive as extra `{ kind: "snapshot", snapshot, resolvedRepositoryIdentityRoots }` frames containing only the projects whose identity resolved and empty `threads`/`archivedThreads`; they are partial metadata, not authoritative snapshots (`ShellStream.ts:160-222`; `C:1949-1958`). The authoritative initial snapshot omits `resolvedRepositoryIdentityRoots`.
- Resume with `afterSequence` replays when the gap is at most 1000 events (`ws.ts:551,686-694,1141-1162`), sending a metadata-only snapshot first; else a full snapshot. `requestCompletionMarker` adds `{ kind: "synchronized" }` between catch-up and live.

### 8.5 Project ordering and settings

- No server-side project order and no reorder command. The server lists projects by creation order. Sort mode `sidebarProjectSortOrder: "updated_at" | "created_at" | "manual"` is a client setting in `ClientSettingsSchema` (`settings.ts:57-59,300,481-483`) persisted client-side (no RPC); the web keeps the manual order in local UI state `projectOrder` (`apps/web/src/uiStateStore.ts:22-63`).
- Two layers of project settings:
  1. Project row fields via `projects.mutate`: title, workspaceRoot, defaultModelSelection, defaultThreadEnvMode (`"local"|"worktree"`, `packages/contracts/src/environment.ts:61-62`), autoPull, projectIcon, faviconPath, scripts.
  2. `ServerSettings.projectSettingsOverrides[projectId]` via `server.updateSettings { patch, providerInstanceMutation? }` (`rpc.ts:739-745`); in the patch each project entry replaces that project's whole override set and `null` removes it (`settings.ts:1499-1508`). Keys (`settings.ts:1027-1081`): `worktreeCleanup, defaultModelSelection, defaultRuntimeMode, defaultThreadEnvMode, newWorktreesStartFromOrigin, worktreeSubmodules, defaultAutoPull, defaultProjectScripts, enableAgentBrowserAccess, enableAgentDeviceAccess, textGenerationModelSelection, sourceControlWriterModelSelection, sourceControlWritingStyle, removeAgentCreditsOnMerge, branchNamingMode, branchNamePrefix, branchNameInstructions, pullRequestMergeMethod, sidebarAutoSettleOnMerge, sidebarAutoSettleAfterDays, continueThreadsAfterServerUpdate, responseStreamingMode`.
- After the one-time fold (`projectSettingsFolded: true`, `apps/server/src/serverSettings.ts:600-661`), `resolveProjectSettings` ignores the project row's `defaultModelSelection` and `defaultThreadEnvMode` (`packages/shared/src/projectSettings.ts:144-189`) and `resolveProjectScripts` ignores the row `scripts` (`projectScripts.ts:17-27`). The web edits project scripts through `server.updateSettings` overrides (`apps/web/src/components/settings/useProjectScriptSettings.ts:66-128`) and other metadata through `projects.mutate` (`apps/web/src/components/settings/ProjectSettingsPanel.tsx:262-283`).
- Worktree base directory: global only, `ServerSettings.worktreesDirectory` plus server-maintained `previousWorktreesDirectories` (`settings.ts:1121-1132`); no per-project override.
- `t3.json` (`packages/contracts/src/t3ProjectFile.ts:75-113`): `iconPath`, `defaultThreadEnvMode`, `worktreeSubmodules`, `scripts` (max 50). File-backed keys resolve project override, then environment, then t3.json, then built-in (`local`, `recursive`) (`t3ProjectFile.ts:125-139`; `projectSettings.ts:17-24,86-142`).

---

## 9. Shell stream deltas for thread changes

- Active stream items: `{ kind: "thread.updated", sequence, location: "active", thread }` and `{ kind: "thread.removed", sequence, location: "active", threadId }`. Archived or deleted threads produce `thread.removed` (`ShellStream.ts:288-319`). The contract also allows `location: "archive"` (`C:1969-1980`) but no emitter was found in this build.
- Archived list: `getArchivedShellSnapshot` / `subscribeArchivedShell` with `thread.updated` for archived threads and `thread.removed` on unarchive or deletion of an archived thread (`ws.ts:1746-1808`; `ShellStream.ts:321-344`).
- Live `thread.updated` items whose shell equals the last sent one apart from `updatedAt` are skipped for up to 5 s (`ShellStream.ts:226-273`).
- Initial snapshot threads are ordered `updated_at ASC, thread_id ASC` (`ProjectionStore.ts:5289-5300`).

---

## 10. Gotchas and UNVERIFIED items

1. A `commandId` replay with the same thread returns the earlier result even if the new command differs in type or payload (section 2 step 7). Use a fresh UUID per logical command.
2. `thread.create` performs no existence checks (project, provider, duplicate thread id). Duplicate thread id overwrite: UNVERIFIED end-to-end.
3. `thread.archive` does not stop running runs in the decider; it only cancels queued runs and detaches sessions. In-flight turn outcome: UNVERIFIED. Clients should interrupt first (the web refuses to archive active threads).
4. `thread.delete` has no guards, does not cascade to other threads, and does not remove worktrees; worktree removal is client-driven or policy-driven (section 6.5).
5. `thread.unsettle` on an unsettled thread creates an explicit `"active"` override that blocks auto-settlement until the next message.
6. Snooze wake is purely derived; no server event at `snoozedUntil`.
7. `thread.active.reorder` and every `thread.pull-request-synced` event bump the persisted `updatedAt` in SQL even though the event payload does not (section 5). UNVERIFIED impact.
8. `thread.fork` copies most source thread fields verbatim, including pin keys and PR watches. Intent UNVERIFIED.
9. `launchThread` errors surface as `"Failed to launch thread"` except attachment errors; the specific reason is only in `cause` (Defect JSON encoding UNVERIFIED). Preparation failures after the RPC returns show up as `prepared-run.fail` events with code `workspace_preparation_failed`.
10. In the launch reuse path, `title`, `runtimeMode` and `interactionMode` are not applied to the reused thread.
11. The setup script (`runOnWorktreeCreate`) also runs for `root` and `existing_worktree` launches; only `worktree` (or a reused worktree on retry) gets a setup tracker card.
12. `projects.create` ignores `defaultModelSelection`; WS `projects.mutate` errors other than not-empty all read `"Failed to mutate project."`.
13. Exact client-visible error for a payload that fails RPC decoding (for example an internal command type): UNVERIFIED.
14. JSON wire encoding of `Schema.DateTimeUtc` (ISO-8601 string assumed) and of `Schema.Defect` causes: UNVERIFIED (effect library not installed in the checkout).
