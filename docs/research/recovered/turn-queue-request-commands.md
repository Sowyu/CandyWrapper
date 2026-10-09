# Orchestration v2: server semantics of turn, run, queue, runtime-request and checkpoint commands

Source studied (read only): `/Users/mrm/CandyWrapper-research/t3code` at tag `v0.0.46-nightly.20261009.2861` (HEAD `3b6af0bd1`). Every claim below cites `path:line` relative to that repo root.

Shorthand used in citations:

- `contracts` = `packages/contracts/src/orchestrationV2.ts`
- `Orchestrator` = `apps/server/src/orchestration-v2/Orchestrator.ts`
- `o2/X` = `apps/server/src/orchestration-v2/X`

Library caveat: the server is built on Effect 4.0.1 (`pnpm-workspace.yaml:49`). `node_modules` is not installed in the checkout, so anything that lives inside the Effect library itself (JSON encoding of `Schema.Defect`, RpcServer default request concurrency, whether `Schema.TaggedError` instances are `instanceof Error`, the response shape of payload decode failures and of defects) is UNVERIFIED.

---

## 1. Transport: the `orchestration.dispatchCommand` RPC

### 1.1 Method, schemas, auth

- Method name: `dispatchCommand: "orchestration.dispatchCommand"` (contracts:3138-3139).
- Payload schema: `OrchestrationV2Command` (contracts:3566-3569; union body contracts:2611-3054).
- Success schema: `OrchestrationV2DispatchCommandResult = Schema.Struct({ sequence: NonNegativeInt })` (contracts:3212-3214).
- Error schema: `Schema.Union([OrchestrationV2DispatchCommandError, EnvironmentAuthorizationError])` (`packages/contracts/src/rpc.ts:1559-1563`).
- Required auth scope: `AuthOrchestrationOperateScope` = `"orchestration:operate"` (`apps/server/src/auth/RpcAuthorization.ts:43-45`, `packages/contracts/src/auth.ts:83`). A missing scope yields `EnvironmentAuthorizationError { message, requiredScope, requiredPermission? }` (`packages/contracts/src/auth.ts:409-416`) with message `The authenticated token is missing required scope: ${requiredScope}.` (`RpcAuthorization.ts:223-226`).
- Effect RPC framing, as modeled by the official client's fake-server tests: request `{ "_tag": "Request", "id", "tag": "<method>", "payload" }`; success `{ "_tag": "Exit", "requestId", "exit": { "_tag": "Success", "value": {...} } }`; typed failure `{ "_tag": "Exit", "requestId", "exit": { "_tag": "Failure", "cause": [ { "_tag": "Fail", "error": { "_tag": "...", ... } } ] } }` (`packages/client-runtime/src/rpc/session.test.ts:157-161`, `:316-325`, `:879-895`). The server-side encoder is Effect RPC, so exact encoding details beyond this test model are UNVERIFIED.

### 1.2 Handler pipeline (apps/server/src/ws.ts:1818-1866)

```ts
startup
  .enqueueCommand(
    // A retry also restarts the preparation work the launch owns.
    (command.type === "prepared-run.retry"
      ? threadLaunch.retryPreparation(command)
      : ThreadMessageIntake.dispatchCommand(
          ThreadManagementService.withCreationProvenance(command, {
            createdBy: "user",
            creationSource:
              "creationSource" in command ? command.creationSource : "web",
          }),
        )
    ).pipe(Effect.provide(intakeContext)),
  )
  .pipe(
    Effect.tap(() => recordClientCommandAnalytics(command)),
    Effect.map((result) => ({ sequence: result.sequence })),
    Effect.mapError((cause) => {
      const detail = userFacingDispatchErrorMessage(cause);
      return new OrchestrationV2DispatchCommandError({
        commandId: command.commandId,
        commandType: command.type,
        message: detail ?? "Failed to dispatch orchestration V2 command",
        ...(detail === undefined ? {} : { detail }),
        cause,
      });
    }),
  )
```

Step by step:

1. Startup gate (`apps/server/src/serverRuntimeStartup.ts:102-144`). Before the server signals command readiness, every command (all threads) is queued into one global FIFO worker and awaited. After readiness the effect runs directly in the request fiber. If startup failed, every command fails with `ServerRuntimeStartupError` whose message is `Server runtime startup failed before command readiness.` (`serverRuntimeStartup.ts:57-69`, `:123-131`).
2. `prepared-run.retry` is routed to `ThreadLaunchService.retryPreparation` (ws.ts:1840-1841), which dispatches the command and then reschedules workspace preparation (section 15). All other commands go through `ThreadMessageIntake.dispatchCommand` (section 1.4).
3. Success returns only `{ sequence }`; the stored events are dropped (ws.ts:1853). For `message.dispatch`, an analytics event `client.turn.requested` is recorded after success (ws.ts:1217-1224, 1852).
4. Failure always becomes `OrchestrationV2DispatchCommandError` (section 5).

### 1.3 Provenance override

`withCreationProvenance` (`o2/ThreadManagementService.ts:52-66`) replaces `createdBy` and `creationSource` only for `thread.create`, `message.dispatch`, `thread.fork`, `thread.merge_back`, `delegated_task.request`; all other commands pass through unchanged. Because ws.ts passes `creationSource: command.creationSource` for those types, the effective result is: `createdBy` is forced to `"user"`, and `creationSource` keeps the client's value from the enum `"web" | "mobile" | "mcp" | "provider" | "server"` (contracts:79-85; actor enum contracts:76). The official client sends `creationSource: input.creationSource ?? "web"` (`packages/client-runtime/src/operations/commands.ts:695`, `:759`).

### 1.4 Intake: attachment claims (o2/ThreadMessageIntake.ts:53-165)

- `runtime-request.respond` with `attachmentsByQuestionId`: validate limits over all questions together, claim each question's pending uploads, rewrite `answers` to append readable attachment paths, then dispatch with the rewritten `answers` and claimed attachments (ThreadMessageIntake.ts:57-126). Path rewriting appends lines `Attached <type> "<name>": "<path>"` to the answer string, or adds an array element for array answers; missing files fail with `Attachment '<name>' is no longer available. Attach it again.` (`apps/server/src/provider/userInputAttachments.ts:18-66`).
- `message.dispatch` (always) and `queued-run.edit` (only when `attachments` is present): claim pending uploads and remap composer context attachment ids (`remapComposerContextAttachments`, `packages/shared/src/composerContextReferences.ts:301-323`), dispatch, then release copies the committed events do not reference (ThreadMessageIntake.ts:127-164).
- Everything else: `threads.dispatch(command)` unchanged (ThreadMessageIntake.ts:127-131).
- Error tags treated as "certainly not accepted" (claimed copies are deleted): `OrchestratorCommandRejectedError`, `OrchestratorProjectionError`, `OrchestratorProviderAdapterError`, `OrchestratorCommandPreviouslyRejectedError`, `OrchestratorCommandIdConflictError`, `OrchestratorSubagentThreadReadOnlyError`, `OrchestratorThreadAboveModeLimitError` (ThreadMessageIntake.ts:14-31). A plain `OrchestratorDispatchError` is treated as uncertain and copies are kept.
- Claim rules (`o2/AttachmentClaims.ts`):
  - Limits from `getProviderAttachmentLimitError`: more than 100 attachments fails with `You can attach up to 100 files per message or question response.`; image bytes over 80 MiB fail with `Images can total up to 80 MiB per message or question response. Use smaller images or send fewer at once.` (`packages/contracts/src/chatAttachment.ts:13-17`, `:220-237`; AttachmentClaims.ts:26-31).
  - Duplicate ids fail with `Duplicate attachment ids are not allowed.` (AttachmentClaims.ts:68-75).
  - Only attachments whose id has thread segment `pending` (`pending-<uuid>[-ext]`) are claimed; anything else passes through untouched (AttachmentClaims.ts:38-40, 76-78, 86-88; `apps/server/src/attachmentStore.ts:25`, `:64-66`).
  - A claim copies the pending file to a new random thread-scoped id `<threadSegment>-<uuid>[-ext]` and lowercases `mimeType` (AttachmentClaims.ts:89-143; attachmentStore.ts:84-90, 207-250). Failure messages: `Attachment '<name>' cannot be sent: <reason>.` with reasons such as `invalid attachment id`, `attachment must be a pending upload`, `attachment not found (removed or expired)`; plus `... cannot be sent: attachment not found.`, `... cannot be sent: stored size does not match.`, `... cannot be sent: attachment type does not match the upload.`, `Failed to claim attachment '<name>' for this thread.` (AttachmentClaims.ts:94-137; attachmentStore.ts:212-243).
  - These failures happen before the orchestrator, so no command receipt is written; the same commandId can be retried.
- After intake, `ThreadManagementService.dispatch` hydrates legacy v1 transcripts for every thread id the command touches (`existingThreadIdsForCommand`), mapping failures to `OrchestratorDispatchError` (no receipt), then calls `orchestrator.dispatch` (`o2/ThreadManagementService.ts:68-99`, `:471-488`, `:512-513`).

### 1.5 Public versus internal commands

- Public (`OrchestrationV2Command`, contracts:2611-3054): thread.create, thread.archive, thread.unarchive, thread.delete, thread.settle, thread.auto-settle, thread.unsettle, thread.snooze, thread.unsnooze, thread.auto-settle.set, thread.pin, thread.unpin, thread.pin.reorder, thread.active.reorder, thread.visit, thread.mark-unread, thread.metadata.update, thread.pull-request.link, thread.pull-request.unlink, thread.pull-request-link.sync, thread.pull-request.watch, thread.pull-request.sync, thread.title.regeneration.complete, thread.runtime-mode.set, thread.interaction-mode.set, thread.model-selection.set, provider-session.detach, message.dispatch, prepared-run.release, notification.delivery.accept, prepared-run.progress, prepared-run.fail, prepared-run.retry, run.interrupt, queued-message.promote-to-steer, queue.resume, queued-run.reorder, queued-run.cancel, queued-run.edit, runtime-request.respond, thread.user-input.dismiss, checkpoint.rollback, thread.fork, thread.merge_back, delegated_task.request, delegated_task.wake-policy, delegated_task.completion-delivery.acknowledge, delegated_task.completion-delivery.dispose, thread.created.record, provider.switch.
- Internal only (`OrchestrationV2InternalCommand`, contracts:3057-3133): `thread.pull-request-watch.sync`, `checkpoint.rollback.fail`, `thread.background-work.settle`, `thread.stop`, `secret_request.record`. The contract comment: "Commands only the server dispatches. They stay out of `OrchestrationV2Command`, the `dispatchCommand` payload, so no client can send them." (contracts:3057-3061). Test: `checkpoint.rollback.fail` fails payload decode on `dispatchCommand` while `checkpoint.rollback` decodes (`packages/contracts/src/rpc.test.ts:42-69`).
- Public but server-originated in practice. There is no actor check on these; a client could send them, but the official clients never do (grep of `apps/web/src`, `apps/mobile`, `packages/client-runtime/src` found only `thread.merge_back` among them, `commands.ts:956`):
  - `prepared-run.release/progress/fail`: sent by ThreadLaunchService (`o2/ThreadLaunchService.ts:325`, `:474`, `:553`, `:627`).
  - `notification.delivery.accept`: sent by the effect worker (`o2/EffectWorker.ts:226-231`).
  - `delegated_task.*`, `thread.created.record`: sent by the MCP service (`apps/server/src/mcp/OrchestratorMcpService.ts:1342`, `:1850`, `:1904`, `:1984`, `:2203`).
  - `thread.auto-settle`: contract comment says "dispatched by the settlement sweep, never by clients" (contracts:2656-2661) but it is in the public union.
  - `provider.switch`: no server or official-client dispatch site found; official clients send `thread.model-selection.set` when the server advertises `serverResolvedCommandContext` (section 14).

---

## 2. Idempotency, command receipts and the result sequence

### 2.1 Receipt model

- `CommandReceiptV2 { commandId, threadId, commandType: string, acceptedAt, resultSequence: NonNegativeInt, status: "accepted" | "rejected", error: string | null }` (`o2/CommandReceiptStore.ts:46-58`).
- Table `orchestration_command_receipts`, primary key `command_id`, column `aggregate_kind` `"project" | "thread"` (`apps/server/src/persistence/OrchestrationCommandReceipts.ts:23-32`, `:74-108`). Thread lookups return none when the row belongs to a project command (`CommandReceiptStore.ts:170-188`).
- `insertIfAbsent` is `INSERT ... ON CONFLICT(command_id) DO NOTHING RETURNING command_id` (`OrchestrationCommandReceipts.ts:134-165`).

### 2.2 Dispatch algorithm (Orchestrator:10421-10625), executed inside the per-thread lock (Orchestrator:10627-10628)

1. Read the receipt for `commandId` (Orchestrator:10430-10439).
2. If a receipt exists:
   - `status === "rejected"`: fail `OrchestratorCommandPreviouslyRejectedError { commandId, commandType, detail: receipt.error ?? "Previously rejected." }` (Orchestrator:10443-10449). Message: `Command ${commandId} was previously rejected: ${detail}` (Orchestrator:215-226).
   - `receipt.threadId !== commandThreadId(command)`: fail `OrchestratorCommandIdConflictError { commandId, commandType, receiptThreadId, commandThreadId }` (Orchestrator:10453-10461). Message: `Command ${commandId} was already handled for thread ${receiptThreadId} and cannot be replayed for ${commandThreadId}.` (Orchestrator:228-240, 248-253).
   - Otherwise replay: read stored events by commandId; for `queue.resume` additionally run `startNextQueuedRun` again; return `{ sequence: receipt.resultSequence, storedEvents }` (Orchestrator:10462-10480). The command type and payload are not compared with what was recorded.
3. If a `DispatchModeLimit` is in context (MCP callers only), check the thread shell's modes (Orchestrator:10483-10494).
4. Plan with `dispatchOnce` (Orchestrator:10496, body 10123-10419). If the plan has zero events and the type is neither `thread.background-work.settle` nor `thread.stop`, fail `OrchestratorDispatchError` with cause `"Command produced no domain events."` (Orchestrator:10497-10512).
5. Any planning failure except `OrchestratorThreadAboveModeLimitError` writes a rejected receipt via `eventSink.commitRejectedCommand` with `error: cause instanceof Error ? cause.message : String(cause)` and rethrows (Orchestrator:10513-10536, 10548). Special case: for `queued-run.edit`, an `OrchestratorDispatchError` with a stored rejected receipt is re-tagged `OrchestratorCommandRejectedError` (same cause) so intake releases attachment copies (Orchestrator:10537-10547).
6. Zero-event commands that are allowed (`thread.stop`, `thread.background-work.settle`): insert an accepted receipt whose `resultSequence` is the latest event sequence of the thread, return `{ sequence, storedEvents: [] }` (Orchestrator:10553-10579).
7. Otherwise `eventSink.commitCommand` (Orchestrator:10580-10602). If the commit reports a rejected receipt, fail PreviouslyRejected (Orchestrator:10604-10610).
8. Post-commit work, still inside the lock: `queue.resume` runs `startNextQueuedRun`; `notification.delivery.accept` runs `offerDelegatedCompletionDeliveries(threadId)`; `delegated_task.wake-policy` runs `offerDelegatedCompletionDeliveries(parentThreadId)` (Orchestrator:10611-10619). A failure here is returned as an error even though the command is committed.
9. Return `{ sequence: committed.receipt.resultSequence, storedEvents }` (Orchestrator:10621-10624).

### 2.3 The commit transaction (o2/EventSink.ts:527-593)

Inside one SQL transaction: reserve the receipt (`insertIfAbsent`, `resultSequence: 0`); if the reservation fails, return the existing receipt and events with `committed: false` (EventSink.ts:532-544); normalize events (turn item positions, section 6.5); append; apply to projections; enqueue effects; upsert the receipt with `resultSequence` = sequence of the last appended event; cancel unsettled effects if the plan asked for it. After commit: signal effect cancellations, wake the effect worker, publish events (EventSink.ts:578-586). Publication goes through a single "publish lane" so subscribers always see commits in sequence order (EventSink.ts:232-262).

`commitRejectedCommand` (EventSink.ts:595-618): transaction; `resultSequence` = latest sequence of the thread; `insertIfAbsent`; if a receipt already exists, return that one instead.

### 2.4 Outcome table

| Situation | Outcome |
|---|---|
| First dispatch, accepted | success `{ sequence }` = sequence of the last event this command wrote |
| First dispatch, rejected during planning | error; a rejected receipt is stored |
| Same commandId again on the same thread after acceptance | success with the original `sequence`; nothing re-executes; a different payload or even a different command type is ignored |
| Same commandId again after rejection | error `OrchestratorCommandPreviouslyRejectedError`, message `Command <id> was previously rejected: <stored error>` |
| Same commandId used for a different thread | error `OrchestratorCommandIdConflictError` |
| Same commandId as an earlier project command | thread receipt lookup returns none, planning proceeds, commit cannot reserve, `existingCommandResult` dies with `Command receipt <id> disappeared during its transaction.` (EventSink.ts:512-525). This is a defect; its wire shape is UNVERIFIED |
| Concurrent duplicates on the same thread | serialized by the thread lock; the second one replays |
| Concurrent duplicates aimed at two different threads | both may plan; only one reservation succeeds; the loser gets the winner's accepted receipt back as success, because the thread check only runs before planning (EventSink.ts:541-544; Orchestrator:10604-10624) |
| Failure before the orchestrator (attachment claim, startup gate, transcript hydration, receipt read error) | error, no receipt; retrying the same commandId re-executes |
| Commit transaction failure | transaction rolls back including the reservation; error, no receipt |
| Post-commit hook failure (queue.resume, notification accept, wake-policy offers) | error, but the command is committed; retrying the same commandId replays success |
| MCP mode-limit refusal | error, no receipt (Orchestrator:10517) |

Stored rejection text: the receipt stores the top-level error's `message`. For `OrchestratorDispatchError` that is the generic `Failed to dispatch orchestration command ${commandType} (${commandId}).` (Orchestrator:140-142), so the specific cause is lost on retry. A retry therefore reads like `Command c1 was previously rejected: Failed to dispatch orchestration command queue.resume (c1).` This relies on TaggedErrors being `Error` instances (UNVERIFIED Effect internal; UserFacingErrors.ts:67 makes the same assumption).

Test evidence: dispatching `thread.archive` to a missing thread fails with `OrchestratorProjectionError`, and the same command retried fails with `OrchestratorCommandPreviouslyRejectedError` (`o2/runtimeLayer.test.ts:3133-3148`). Dispatching the same `queue.resume` twice does not duplicate messages or runs (`o2/runtimeLayer.test.ts:4244-4259`).

### 2.5 Retention

- V2 thread receipts never expire. Compaction removes only receipts with `command_type = 'legacy'` for threads whose v1 import finished (`o2/ProjectionMaintenance.ts:323-359`). No receipt cleanup was found in thread deletion code (grep of ThreadDeletion.ts, ResourceCleanupService.ts, ProjectionStore.ts found no receipt references).
- Event compaction deletes superseded thread-state, `message.updated` and `node.updated` events (`o2/ProjectionMaintenance.ts:205-321`). That can shrink the `storedEvents` of a replay (server internal) but never the receipt's `resultSequence`.
- Effect outbox rows: effect ids are deterministic and `enqueue` ignores existing ids (`o2/EffectOutbox.ts:374-412`); succeeded and cancelled rows are kept 7 days (`o2/EffectOutbox.ts:150-162`).

### 2.6 What `sequence` means and how clients use it

- Event sequence is one global AUTOINCREMENT column for every thread and project (`apps/server/src/persistence/Migrations/001_OrchestrationEvents.ts:8-9`; `o2/EventStore.ts:68-72`).
- Accepted command: the sequence of the last event that command appended. Allowed zero-event command: the thread's latest sequence at that time. Replay: the stored `resultSequence`.
- The last event of a command can belong to a different thread than `threadId` (for example `delegated_task.request` ends with a `context-transfer.created` on the child thread, Orchestrator:6728-6735).
- Work that happens after the command (queue start events, provider turn start, rollback execution, steering delivery) lands in later commits with later sequences and is never covered by the returned value.
- Official client usage: an optimistic shell update is kept until a shell snapshot with `snapshotSequence >= result.sequence` arrives (`packages/client-runtime/src/state/threadLifecycle.ts:79-92`). The client uses `{ sequence: 0 }` locally as "nothing dispatched" (`commands.ts:600`, `:808`, `:824`).

### 2.7 Practical rules derived from the code

- Allocate a fresh, globally unique commandId for each logical action (official client: `crypto.randomUUIDv4`, `commands.ts:261-267`).
- Retry transport failures with the same commandId; if the first attempt committed, the replay returns its result.
- After `OrchestratorCommandPreviouslyRejectedError`, mint a new commandId to try again.
- Message ids are client allocated and upserted globally by id (`o2/ProjectionStore.ts:806-810`; SQL `ON CONFLICT(message_id)` at `o2/ProjectionStore.ts:2331-2367`). Reusing a messageId in a new command overwrites the existing message row, even across threads. The web client uses `MessageId.make(randomUUID())` (`apps/web/src/lib/utils.ts:50`).

---

## 3. Serialization and ordering

- Before startup readiness: one global FIFO worker for all commands (`serverRuntimeStartup.ts:104-141`).
- After readiness: mutual exclusion per thread with `KeyedLock` (FIFO for waiters, not reentrant) (`packages/shared/src/KeyedLock.ts:5-62`; `o2/ThreadCommandExecutor.ts:6-12`). The key is `commandThreadId(command)` (Orchestrator:427-489): `threadId` for most commands, `parentThreadId` for `delegated_task.*` and `thread.created.record`, `targetThreadId` for `thread.fork` and `thread.merge_back`. The fork or merge-back source thread is read without its lock and re-checked (Orchestrator:3521-3523, 3612-3614).
- Commands for different threads run concurrently; commits are serialized by the database transaction and publication by the publish lane (EventSink.ts:232-262).
- RPC request concurrency: the WS server is created with `{ disableTracing: true, disableFatalDefects: true }` and no concurrency option (ws.ts:3124-3127, 3172). The Effect RPC default is UNVERIFIED, so a client must not assume two dispatches sent without awaiting are applied in send order. Await each result when order matters.
- Other writers that take the same thread lock: the terminal-run reactor (queue start and delegated finalization, Orchestrator:10630-10674), `resumeQueuedRuns` (Orchestrator:1872-1902), the rollback executor's final write (`o2/CheckpointRollbackService.ts:280-353`).
- Effects run in a per-thread FIFO lane: a pending effect is claimable only if no earlier pending or running effect exists for the same thread (title generation has its own lane) (`o2/EffectOutbox.ts:319-358`, `:523-557`). Retries: at most 5 attempts, backoff `min(30000, 100 * 2^(attempt-1))` ms, lease 30 s (`o2/EffectWorker.ts:550-551`, `:731-742`).

---

## 4. Policy layers

### 4.1 Actor restrictions (not in CommandPolicy)

CommandPolicy contains no actor rules. Actor restrictions come from:

1. The public/internal schema split (section 1.5).
2. `createdBy` forced to `"user"` over WS (section 1.3).
3. `message.dispatch` guards: a `notification` requires `createdBy === "agent"`, `creationSource` `"server"` or `"provider"`, and resolved mode `queue_after_active`, else `Notifications must be server- or provider-created queued messages.` (Orchestrator:4668-4679). A `delegatedCompletion` requires `createdBy === "agent"`, `creationSource === "server"`, mode `queue_after_active`, else `Delegated completion delivery must be a server-created queued message.` (Orchestrator:4683-4695). WS clients therefore cannot send either.
4. Provider-native subagent threads are read only for `message.dispatch`: `OrchestratorSubagentThreadReadOnlyError` with message `This subagent is run by its provider and cannot take messages. Message the parent thread instead.` (Orchestrator:190-197, 10249-10265). Such a thread has `lineage.relationshipToParent === "subagent"` and `creationSource === "provider"` (contracts:447-451).
5. `DispatchModeLimit` for MCP callers (4.3).
6. RPC scope `orchestration:operate` (1.1).

### 4.2 CommandPolicy: provider capability checks (o2/CommandPolicy.ts)

- Capability literals: `queued_messages`, `active_steering`, `interrupt`, `interrupt_restart_steering`, `native_fork`, `fork_from_turn`, `rollback`, `rollback_snapshot`, `context_handoff`, `strong_terminal_status` (CommandPolicy.ts:51-62).
- Errors: `CommandPolicyMessageDispatchError` message `Failed to choose message dispatch policy for command ${commandId}.` (65-76); `CommandPolicyUnsupportedError` message `${providerInstanceId} cannot satisfy message dispatch mode ${requestedMode} for command ${commandId}.` (78-90); `CommandPolicyCapabilityUnsupportedError { commandId, threadId, providerInstanceId, capability, detail }` message `${providerInstanceId} cannot satisfy ${capability} for command ${commandId}: ${detail}` (92-105). Note: the `detail` strings literally contain the word "providerInstanceId".
- `ensureQueuedMessages`: needs `turns.supportsQueuedMessages`; detail `providerInstanceId does not support app-owned queued turns` (238-247).
- `decideSteeringExecution`: returns `"active_steering"` when not `forceRestart` and `supportsActiveSteering`; else `"interrupt_restart"` when `supportsInterrupt && supportsSteeringByInterruptRestart`; else fails with capability `interrupt_restart_steering` (when `forceRestart` or `supportsInterrupt`) or `active_steering`, detail `providerInstanceId cannot satisfy a required interrupt-and-restart` (when forced) or `providerInstanceId cannot steer active turns directly or by interrupt-and-restart` (249-270).
- `ensureInterrupt`: needs `supportsInterrupt`; detail `providerInstanceId does not support turn interrupts` (272-277).
- `ensureRollback`: needs `threads.canRollbackThread && checkpointing.providerCanRollbackConversation` (else `rollback`, `providerInstanceId conversation rollback is unavailable`) and `checkpointing.providerRollbackReturnsSnapshot` (else `rollback_snapshot`, `rollback must return a providerInstanceId thread snapshot`) (306-325).
- `ensureContextHandoff`, `decideForkExecution`, `ensureNativeFork`: 279-304, 327-387.
- `resolveMessageDispatchIntent` (119-165) is used by the Orchestrator (section 7.4).
- `decideMessageDispatch` (389-480) is defined but has no call site (grep found it only in CommandPolicy.ts). Do not model it.

### 4.3 DispatchModeLimit (o2/DispatchModeLimit.ts)

- A `Context.Reference` with default `undefined` (DispatchModeLimit.ts:30-33). It is provided only by MCP tool access (`apps/server/src/mcp/McpToolAccess.ts:166-197`; `OrchestratorMcpService.ts:2039`). WS client commands have no limit.
- Ranks: runtime `approval-required` 0 < `auto-accept-edits` 1 < `auto` 2 < `full-access` 3; interaction `plan` 0 < `default` 1 (DispatchModeLimit.ts:35-52).
- Checked inside the thread lock against the command thread's shell (Orchestrator:10483-10494) and against fork or merge-back sources (Orchestrator:3523, 3614). Error `OrchestratorThreadAboveModeLimitError { commandId, threadId, mode: "runtime" | "interaction", runtimeMode, interactionMode }`, message `Thread ${threadId} now runs in ${runtimeMode}/${interactionMode} mode, above what this caller may change.` (Orchestrator:199-213). No receipt is written (Orchestrator:10517).

---

## 5. Error shape returned to clients

### 5.1 Wire error

```ts
class OrchestrationV2DispatchCommandError extends Schema.TaggedError(...)(
  "OrchestrationV2DispatchCommandError",
  {
    commandId: CommandId,
    commandType: Schema.String,
    message: Schema.String,
    detail: Schema.optional(Schema.String),
    cause: Schema.optional(Schema.Defect()),
  },
)
```
(contracts:3395-3404)

- `message`: the extracted user-facing text (5.2), or the fallback `Failed to dispatch orchestration V2 command`.
- `detail`: present only when a user-facing text was extracted; then it equals `message` (ws.ts:1855-1861).
- `cause`: the raw server error tree. Its JSON form comes from `Schema.Defect()` (UNVERIFIED).
- The other possible typed error is `EnvironmentAuthorizationError` (1.1). Payload decode failures happen in the RPC layer before the handler, and defects bypass `mapError`; both shapes are UNVERIFIED.
- `OrchestrationDispatchCommandError` (`packages/contracts/src/orchestrationDispatch.ts:9-16`, with `bootstrapThreadDisposition`) is not used by `orchestration.dispatchCommand`; it belongs to project RPCs (`packages/contracts/src/rpc.ts:1122-1129`, `:1194-1205`; ws.ts:2563-2592). No server code sets `bootstrapThreadDisposition` (grep found only contracts and client-runtime).

### 5.2 How the message is chosen (o2/UserFacingErrors.ts:4-110)

- Walk the error tree in pre-order: the value itself, then `.cause`, `.error`, `.errors` recursively (UserFacingErrors.ts:80-102).
- For each node: a string is used as is; a CommandPolicy rejection is translated to friendly prose; an `Error` contributes `.message`; another object contributes `.detail ?? .message` (UserFacingErrors.ts:59-74).
- Drop messages starting with `Failed to dispatch orchestration V2 command`, `Failed to dispatch orchestration command `, `Provider adapter failed while dispatching orchestration command `; dedupe; return the last (deepest) one (UserFacingErrors.ts:4-8, 104-110).
- Friendly translations, where `p` is the provider display name (UserFacingErrors.ts:15-31, 41-53):
  - `queued_messages`: `${p} cannot queue messages behind an active run.`
  - `active_steering` and `interrupt_restart_steering`: `${p} cannot redirect an active run. Stop it first, then send the message.`
  - `interrupt`: `${p} cannot stop a run once it has started.`
  - `native_fork`: `${p} cannot fork this thread natively.`
  - `fork_from_turn`: `${p} cannot fork from an earlier point in this thread.`
  - `rollback`: `${p} cannot rewind its conversation, so this checkpoint cannot be restored on this thread.`
  - `rollback_snapshot`: `${p} did not report its rewound conversation state, so the checkpoint was not restored.`
  - `context_handoff`: `${p} cannot receive the context handoff needed for this switch.`
  - `strong_terminal_status`: `${p} cannot confirm when its runs finish reliably enough for this.`
  - `CommandPolicyUnsupportedError`: `${p} cannot deliver a message that way right now.`
- Display name: `PROVIDER_DISPLAY_NAMES[providerInstanceId]` (antigravity Antigravity, codex Codex, claudeAgent Claude, cursor Cursor, grok Grok, muse Muse Code, ACP registry ACP Registry, pi Pi, opencode OpenCode; `packages/contracts/src/model.ts:228-238`), otherwise the instance id with a trailing `Agent` removed and the first letter upper-cased (UserFacingErrors.ts:33-39).
- Tests: UserFacingErrors.test.ts:6-67.

### 5.3 Server error classes (Orchestrator:132-266)

| `_tag` | Fields | `message` |
|---|---|---|
| OrchestratorDispatchError | commandId, commandType, cause? | `Failed to dispatch orchestration command ${commandType} (${commandId}).` |
| OrchestratorCommandRejectedError | commandId, commandType, cause? | `Orchestration command ${commandType} (${commandId}) was rejected before commit.` |
| OrchestratorProjectionError | threadId, cause? | `Failed to load orchestration projection for thread ${threadId}.` |
| OrchestratorDomainEventStreamError | cause? | `Failed while streaming orchestration domain events.` |
| OrchestratorProviderAdapterError | commandId, providerInstanceId, cause? | `Provider adapter failed while dispatching orchestration command ${commandId}.` |
| OrchestratorSubagentThreadReadOnlyError | commandId, threadId | `This subagent is run by its provider and cannot take messages. Message the parent thread instead.` |
| OrchestratorThreadAboveModeLimitError | commandId, threadId, mode, runtimeMode, interactionMode | `Thread ${threadId} now runs in ${runtimeMode}/${interactionMode} mode, above what this caller may change.` |
| OrchestratorCommandPreviouslyRejectedError | commandId, commandType, detail | `Command ${commandId} was previously rejected: ${detail}` |
| OrchestratorCommandIdConflictError | commandId, commandType, receiptThreadId, commandThreadId | `Command ${commandId} was already handled for thread ${receiptThreadId} and cannot be replayed for ${commandThreadId}.` |

Common nested causes: `ProjectionStoreThreadNotFoundError` `No orchestration projection exists for thread ${threadId}.` (o2/ProjectionStore.ts:116-125); `ProjectionStoreReadError` `Failed to read orchestration projection for thread ${threadId}.` (127-137); `ProviderAdapterRegistryLookupError` `No orchestration provider adapter is registered for ${instanceId}.` (o2/ProviderAdapterRegistry.ts:25-33).

Most validation rejections are `OrchestratorDispatchError` with a string `cause`; the client sees that string.

### 5.4 Realistic examples (derived from the code paths)

- Restart-steer on a Claude thread (`supportsSteeringByInterruptRestart: false`): `{ "_tag": "OrchestrationV2DispatchCommandError", "commandId": "<id>", "commandType": "message.dispatch", "message": "Claude cannot redirect an active run. Stop it first, then send the message.", "detail": "Claude cannot redirect an active run. Stop it first, then send the message.", "cause": <defect> }`.
- Cancel a run that is no longer queued: message `Run <runId> is not queued.`
- Resume the queue of a usage-limited thread: `Continue the limited thread before resuming its queue.`
- File-restoring rollback on a shared workspace: `File restore requires an isolated worktree. This workspace may contain changes from another thread. Rewind the conversation without restoring files instead.` (o2/CheckpointRestoreSafety.ts:9-10).
- Unknown thread on `message.dispatch`: `No orchestration projection exists for thread <threadId>.` (the dispatch reads the thread with its cause kept, Orchestrator:10253-10259). Commands whose projection read drops the cause (queued-run.*, promote, runtime-request.respond, dismiss) report `Failed to load orchestration projection for thread <threadId>.`
- Unknown provider instance in `modelSelection`: `No orchestration provider adapter is registered for <instanceId>.`
- A reorder that changes nothing: `Command produced no domain events.`
- Retrying a rejected commandId: `Command <id> was previously rejected: Failed to dispatch orchestration command <type> (<id>).`

---

## 6. Data model needed to interpret the commands

### 6.1 Run (contracts:541-585)

Fields: `id`, `threadId`, `ordinal` (PositiveInt), `providerInstanceId`, `modelSelection`, `providerThreadId | null`, `userMessageId`, `rootNodeId | null`, `activeAttemptId | null`, `status`, `queuePosition?: PositiveInt | null`, `queueHeld?: boolean`, `requestedAt`, `startedAt | null`, `completedAt | null`, `checkpointId | null`, `contextHandoffId | null`, `restartContinuationOfRunId?`, `workStartedAt?`, `restartCancelledBackgroundWork?`, `sourcePlanRef?`, `delegatedCompletion?`, `workspacePreparation?`.

Status literals: `preparing`, `queued`, `starting`, `running`, `waiting`, `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back` (contracts:453-464).

- Active ("blocking") statuses: `preparing`, `starting`, `running`, `waiting` (Orchestrator:516-523).
- Normal lifecycle: `starting` -> `running` -> `waiting` when the provider turn completes, with `completedAt: null` (o2/RunExecutionService.ts:642-653) -> `completed` once checkpoint capture runs (o2/CheckpointCaptureService.ts:201-237).
- `preparing` exists only for `defer_start` launches waiting on workspace preparation (section 15).
- `queued` runs are pending messages (section 11).
- Terminal statuses: `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back`.

### 6.2 RunAttempt (contracts:597-620)

`reason`: `initial` | `steering_restart` | `retry` | `provider_recovery`. `status`: `pending` | `running` | `completed` | `interrupted` | `failed` | `cancelled` | `superseded`.

### 6.3 Message, user turn item, input intent

- `OrchestrationV2ConversationMessage` (contracts:1113-1138): `notification?`, `createdBy`, `creationSource`, `scheduledTaskId?`, `senderThreadId?`, `id`, `threadId`, `runId | null`, `nodeId | null`, `role` (`user` | `assistant` | `system`), `text`, `context?`, `attachments`, `streaming`, `createdAt`, `updatedAt`, `delegatedCompletion?`.
- `user_message` turn item (contracts:1378-1389): base fields plus `createdBy`, `creationSource`, `messageId`, `scheduledTaskId?`, `senderThreadId?`, `inputIntent`, `text`, `context?`, `attachments`.
- `OrchestrationV2UserMessageInputIntent` = `"turn_start" | "queued_turn" | "steer" | "promoted_queued_to_steer"` (contracts:1307-1312). Set to `turn_start` when a message starts a new run (Orchestrator:5403, 6092); `queued_turn` when a queued run starts (Orchestrator:1646) or when an existing item is re-pointed at a queued run (Orchestrator:5119); `steer` for a steered `message.dispatch`, including restart-steers; `promoted_queued_to_steer` for `queued-message.promote-to-steer` (Orchestrator:3947-3950).
- A message carrying `notification` or `delegatedCompletion` produces a `notification` turn item instead of `user_message` (`packages/provider-core/src/server/notification.ts:212-235`).

### 6.4 Identifier allocation

- `joinId(prefix, ...parts)` joins with `:` after `encodeURIComponent` on each part (`packages/provider-core/src/server/IdAllocator.ts:192-195`). Nested ids are therefore percent-encoded inside other ids.
- Client supplied: `commandId`, `messageId`, `threadId` for new threads.
- Server derived (IdAllocator.ts:394-432):
  - run: `run:thread:<threadId>:ordinal:<n>`, where `n = runs.length + 1` over all runs of the thread including cancelled ones (Orchestrator:370-372).
  - attempt: `run-attempt:run:<runId>:attempt:<k>`.
  - root node: `node:run:<runId>:root` (attempt 1) and `node:run:<runId>:attempt:<k>:root` (restart attempts).
  - user turn item: `turn-item:message:<messageId>`.
  - run signal item: `turn-item:run:<runId>:signal:<signal>` with signals `interrupt-request`, `interrupt-result`, `context-handoff:<handoffId>`.
  - provider thread placeholders: derived from native id `pending:<runId>` (or `pending:<runId>:attempt:<k>` for restart handoffs) (Orchestrator:4901-4904, 5223-5226, 4141-4144). Format starts `provider-thread:provider:<driver>:...native-thread:...` (IdAllocator.ts:216-230); the exact tail was not fully read, UNVERIFIED.
  - delegated task: `node:delegated-task:<commandId>`, `thread:delegated-task:<commandId>`, `message:delegated-task:<commandId>`, `turn-item:delegated-task:<commandId>`; created-thread item `turn-item:created-thread:<commandId>`.
  - Random ids: events `event:thread:<threadId>:command:<commandId>:<uuid>` (IdAllocator.ts:266-278); messages allocated by the server `message:thread:<threadId>:ordinal:<n>:<uuid>` (IdAllocator.ts:307-313).

### 6.5 Turn item ordinals are rewritten at commit

`normalizeEvents` passes every `turn-item.updated` through `TurnItemPositionStore.normalize` (o2/EventSink.ts:309-330). The first write of a (thread, turnItemId) pair gets position `runOrdinal * 1_000_000 + n` (n increments within the run's bucket); later writes keep the stored position (`ON CONFLICT DO NOTHING`) (o2/TurnItemPositionStore.ts:42-105). Ordinals computed by the decider are therefore not what clients receive.

### 6.6 Projection reducer rules that matter for these commands

- `run.created` / `run.updated` upsert by id but keep the previous `delegatedCompletion` and `restartCancelledBackgroundWork` when the new payload omits them (o2/ProjectionStore.ts:617-632, 724-735).
- `provider-thread.updated` sets `thread.activeProviderThreadId` to the payload id, unless the payload is a queued placeholder (`status "not_loaded"`, `firstRunOrdinal null`, `nativeThreadRef null`, `providerSessionId null`) (o2/ProjectionStore.ts:670-677, 783-795).
- `message.updated` and `turn-item.updated` upsert by id (o2/ProjectionStore.ts:806-815).
- `provider-session.detached` removes the session from the thread's `providerSessions` (o2/ProjectionStore.ts:776-782).

---

## 7. `message.dispatch`

### 7.1 Payload (contracts:2837-2876)

```ts
{
  type: "message.dispatch",
  notification?: OrchestrationV2Notification,
  createdBy: "user" | "agent" | "system",
  creationSource: "web" | "mobile" | "mcp" | "provider" | "server",
  scheduledTaskId?: ScheduledTaskId,
  senderThreadId?: ThreadId,
  commandId: CommandId,
  threadId: ThreadId,
  messageId: MessageId,
  text: string,
  context?: OrchestrationMessageContext,
  attachments: ChatAttachment[],
  titleSeed?: TrimmedNonEmptyString,
  modelSelection?: ModelSelection,
  sourcePlanRef?: { threadId: ThreadId, planId: PlanId },
  restartContinuationOfRunId?: RunId,
  usageLimitContinuationOfRunId?: RunId,
  manualContinuationOfRunId?: RunId,
  usageLimitRecoveryRequestId?: CommandId,
  deliveryIntent?: "auto" | "steer" | "restart",
  delegatedCompletion?: { parentRunId: RunId, generation: PositiveInt, taskIds: NodeId[] },
  dispatchMode:
    | { type: "defer_start", workspaceStrategy?: ThreadLaunchWorkspaceStrategy }
    | { type: "steer_active", targetRunId: RunId }
    | { type: "restart_active", targetRunId: RunId }
    | { type: "queue_after_active" }
    | { type: "start_immediately" }
}
```

Referenced types:

- Branded ids are trimmed, non-blank strings (`packages/contracts/src/baseSchemas.ts:7-27`, `:310-312`).
- `ChatAttachment` = image `{ type: "image", id, name (max 255), mimeType (image/*), sizeBytes <= 10 MiB, source? }` | file `{ type: "file", id, name, mimeType, sizeBytes 1..50 MiB, source?: { _tag: "pasted-text" } }` | unknown type (forward compatible) (`chatAttachment.ts:149-218`); attachment id pattern `^[a-z0-9_-]+$`i, max 128 chars (`chatAttachment.ts:33-38`).
- `OrchestrationMessageContext` = `{ version: 1, records: unknown[] }`, at most 200 records, serialized size at most 16,000,000 chars, unique `contextId`s, undecodable records dropped (`packages/contracts/src/composerContext.ts:283-307`).
- `ModelSelection` = `{ instanceId, model, options? }` (`packages/contracts/src/modelSelection.ts:16-20`).
- `ThreadLaunchWorkspaceStrategy` = `{ type: "root", branch? }` | `{ type: "existing_worktree", worktreePath, branch? }` | `{ type: "worktree", baseRef, branch?, startFromOrigin? }` (contracts:518-536).
- `OrchestrationV2Notification` = `{ source, outcome: "completed"|"failed"|"cancelled"|"updated"|"unknown", summary, detail? }` (contracts:1104-1110).

There is no `interactionMode` or `runtimeMode` field. Both are read from the thread when the provider turn starts (`o2/ProviderTurnStartService.ts:525-528`; `o2/RuntimePolicy.ts:65-72`, `:100-136`). The web client sends `thread.runtime-mode.set` and `thread.interaction-mode.set` before the message when they differ (`apps/web/src/components/ChatView.tsx:6301-6330`). No text length or emptiness check on `message.dispatch` was found in the orchestrator; a later provider-side limit (`ProviderSendTurnInput.input` max 120,000 chars, `packages/contracts/src/provider.ts:71-86`) exists, but whether the v2 turn start applies it is UNVERIFIED.

### 7.2 Field semantics

| Field | Server behaviour |
|---|---|
| messageId | Becomes `message.id`; user turn item id is `turn-item:message:<messageId>`; upserted globally |
| text | Stored verbatim; replaced by server text for delegated-completion deliveries (Orchestrator:4757-4760, 565-570) |
| context | Stored on message and turn item; attachment ids remapped when uploads are claimed |
| attachments | Claimed at intake (1.4); stored on message and turn item |
| createdBy / creationSource | Stored; `createdBy` forced `"user"` over WS |
| notification, delegatedCompletion | Rejected for WS clients (4.1) |
| scheduledTaskId, senderThreadId | Stored only; no validation found |
| titleSeed | On the thread's first message sets the title and starts title generation (7.3 step 7) |
| modelSelection | Default `thread.modelSelection`; see paths A to D for when the thread's saved selection changes |
| sourcePlanRef | Implements a proposed plan; plan marked completed in the same commit |
| manualContinuationOfRunId | User "continue" after an interrupted or usage-limited run |
| restartContinuationOfRunId, usageLimitContinuationOfRunId, usageLimitRecoveryRequestId | Server-originated continuations; stale ones become accepted no-ops |
| deliveryIntent | When present, replaces `dispatchMode` entirely (7.4) |
| dispatchMode | Routing (7.5) |

### 7.3 Decision pipeline, in execution order

0. Read the thread; provider-native subagent threads are rejected (Orchestrator:10249-10265).
1. Load control records only: runs, attempts, nodes, subagents, provider sessions/threads/turns, runtime requests, user messages, `user_message` and `error` turn items, checkpoint scopes, context transfers (Orchestrator:921-951, 965-996).
2. `manualContinuationOfRunId`: the source run must exist with status `interrupted` (or `failed` with a usage-limit root failure), be the latest executed run, the thread must not be archived or deleted, no runtime request may be pending, and `dispatchMode.type` must be `start_immediately`; otherwise `This thread can no longer be resumed from that run.` (Orchestrator:4468-4487).
3. `usageLimitContinuationOfRunId`: many staleness checks; if stale, emit only `thread.metadata-updated` (possibly re-keying `limitRecovery.requestId`) and stop; accepted, no run (Orchestrator:4488-4530).
4. `restartContinuationOfRunId`: if the source is not `cancelled`, is a restart-note source, a newer run ran, the provider instance changed, the thread is archived or deleted, or Stop reached the source, emit only `thread.metadata-updated` with the unchanged thread and stop (Orchestrator:4532-4560).
5. Settled thread (`settledOverride !== null`): emit `thread.unsettled` with `settledOverride: null`, `settledAt: null`, `unsettledAt` = now (or the previous value when the override was `"active"`) (Orchestrator:4562-4585).
6. Snoozed thread: emit `thread.unsnoozed` with `snoozedUntil: null`, `snoozedAt: null` (Orchestrator:4586-4605).
7. Title: if the message is not `/compact` or `/logout`, and either (`titleSeed` is set and the thread has 0 messages) or (`createdBy === "user"` and every earlier user message was `/compact` or `/logout`), emit `thread.metadata-updated` with `title: titleSeed ?? title` and `titleRegeneration: { requestId: commandId, startedAt }`, and add effect `thread-title.generate { kind: { type: "initial", messageId } }` with id `effect:<commandId>:thread-title.generate` (Orchestrator:4606-4642, 491-504, 406-415).
8. `modelSelection = command.modelSelection ?? thread.modelSelection` (Orchestrator:4643).
9. Resolve delivery: `resolveMessageDispatchIntent(projection, dispatchMode, deliveryIntent)` (Orchestrator:4644-4648; 7.4).
10. Too-late steer downgrade: if the result is `steer_active` and the target run is `completed`, or is `running`/`waiting` while its latest provider turn (for its root node and active attempt) is `completed`, switch to `start_immediately` (Orchestrator:4649-4667). Restart is never downgraded.
11. Notification and delegated-completion guards (4.1; Orchestrator:4668-4720). Delegated completions also require an open cohort with matching generation and messageId, otherwise `Delegated completion delivery is no longer dispatchable.` (Orchestrator:4700-4714). Deliveries whose tasks all have `completionWake: "always"` are steered into a running turn when the live session supports active steering without `activeSteeringInterruptsTools` (Orchestrator:4721-4756).
12. `sourcePlanRef`: the plan must exist and be `proposed_plan` (`Proposed plan ${planId} does not exist on thread ${threadId}.`), be in the same project (`Proposed plan ${planId} belongs to a different project.`) and have status `active` (`Proposed plan ${planId} is not active.`); the run emits `plan.updated` with `status: "completed"` (Orchestrator:4761-4810).
13. Route: `steer_active`/`restart_active` go to path D (Orchestrator:4812-4840). Otherwise, if any active run exists and the mode is `defer_start`, `start_immediately` or `queue_after_active`, go to path A (queue) (Orchestrator:4842-4851). Otherwise path B or C (start a run).

### 7.4 `deliveryIntent` resolution (o2/CommandPolicy.ts:119-165)

The "active run" here is the last run (by array order) with status `preparing`, `starting`, `running` or `waiting`.

| deliveryIntent | No active run | Active run preparing/starting | Active run running/waiting |
|---|---|---|---|
| absent | the sent `dispatchMode` | the sent `dispatchMode` | the sent `dispatchMode` |
| `steer` | `start_immediately` | `steer_active(active)` | `steer_active(active)` |
| `restart` | `start_immediately` | `restart_active(active)` | `restart_active(active)` |
| `auto` | `start_immediately` | `queue_after_active` | using the capabilities of the provider session bound to the active run's provider thread: `supportsActiveSteering` -> `steer_active`; else `supportsQueuedMessages` -> `queue_after_active`; else `supportsSteeringByInterruptRestart` -> `restart_active`; else `queue_after_active` |

Tests: `o2/CommandPolicy.test.ts:50-142`. A steer resolved against a `preparing` or `starting` run is later rejected (`Target run ... is starting and cannot be steered.`) because the downgrade in 7.3 step 10 does not apply to those statuses.

Official client (`packages/client-runtime/src/operations/commands.ts:689-772`): requested mode `start` sends `start_immediately` without `deliveryIntent`; when the server advertises `serverResolvedCommandContext` (it does: `apps/server/src/environment/ServerEnvironment.ts:250`; meaning documented at `packages/contracts/src/environment.ts:171-174`), `queue` sends `queue_after_active` without `deliveryIntent`, and `auto` (default), `steer`, `restart` send `dispatchMode: { type: "start_immediately" }` plus `deliveryIntent`. Without that capability the client computes the mode from its own projection with the same capability order.

### 7.5 Routing matrix (after 7.3 steps 9 and 10)

| Resolved mode | No active run | Active run exists |
|---|---|---|
| `defer_start` | new run, status `preparing` (path B) | queued (path A); `workspaceStrategy` is dropped |
| `start_immediately` | new run, status `starting` (B or C) | queued (A) |
| `queue_after_active` | new run, status `starting` (B or C) | queued (A) |
| `steer_active` | path D (rejected unless target is `running`) | path D |
| `restart_active` | path D with forced restart | path D with forced restart |

Notes:
- Queued runs are not "active". A new `start_immediately` or `queue_after_active` message starts at once even when held queued runs exist, ahead of them.
- `defer_start` is only honored in path B. In path C (fork, merge-back, provider switch) the run always starts as `starting` with a `provider-turn.start` effect (Orchestrator:6000, 6460-6466).
- `/compact`, `/logout` and `/goal` can never be steered (path D errors); send them with queue semantics.

### 7.6 Path A: queue behind the active run (Orchestrator:4852-5124)

Preconditions and rejections:
- Pending merge-back transfer: `Thread ${threadId} has a pending merge-back transfer; queued merge-back consumption is not implemented yet.` (4853-4859).
- No provider thread to queue against: `Active run ${activeRun.id} has no provider thread for queued dispatch.` (4860-4871).
- Adapter lookup for `modelSelection.instanceId` must succeed (4879-4881).
- `ensureQueuedMessages` against the target provider session's capabilities, else the adapter's static capabilities (4882-4899).

Created records:
- Run: derived id; `ordinal = runs.length + 1`; `providerInstanceId = modelSelection.instanceId`; `modelSelection`; `providerThreadId` = the thread's active provider thread when the instance matches, else the newest root provider thread of that instance, else a new placeholder (`status "not_loaded"`, `providerSessionId: null`); `userMessageId = messageId`; derived `rootNodeId` and `activeAttemptId`; `status: "queued"`; `queueHeld: true` only if some queued run is already held; `queuePosition = max(queuePosition ?? ordinal over queued runs) + 1`; `requestedAt` now; `startedAt`, `completedAt`, `checkpointId`, `contextHandoffId` null; `sourcePlanRef` and `restartContinuationOfRunId` copied (4949-4981).
- Attempt: ordinal 1, `reason "initial"`, `status "pending"` (4982-4994).
- Root node: `kind "root_turn"`, `status "pending"`, `countsForRun: true` (4995-5011).
- Checkpoint scope prepared now unless the active run is `preparing` (then created when the queued run starts) (4922-4948).
- Message: `role "user"`, `runId` = queued run, `nodeId` = its root node, `streaming: false` (5012-5034).

Events, in order: [`provider-thread.updated` with the placeholder, only when a new one was created] (5036-5044), `run.created` (5045-5053), [`plan.updated` completed] (5054), `run-attempt.created` (5055-5063), `node.updated` (5064-5072), [`checkpoint-scope.created`] (5073-5092), `message.updated` (5093-5101), [`turn-item.updated` only when a `user_message` item for this messageId already exists, re-pointed at the queued run with `inputIntent "queued_turn"`] (5102-5123).

No `user_message` turn item is created while queued; it appears when the queued run starts (`o2/ThreadManagementService.ts:652-659`; test `o2/runtimeLayer.test.ts:4324-4327`). The thread's saved model selection is not changed at queue time; the queued run's selection is applied when it starts (section 11). No provider effect is enqueued (only the optional title effect).

### 7.7 Path B: start a run without handoff (Orchestrator:5141-5529)

Taken when there is no pending fork transfer, no pending merge-back, and no provider switch (the active provider thread, if any, has the same instance) (5197-5201).

- Selection event first: if `modelSelection` differs from the thread's, emit `thread.model-selection-updated` (same instance) or `thread.provider-switched` with the thread payload updated (`providerInstanceId`, `modelSelection`, `updatedAt`) (5142-5164). The override therefore becomes the thread's saved selection.
- Adapter lookup failure: `OrchestratorProviderAdapterError` (5202-5211).
- Provider session id: the active provider thread's session, else a shared derived id when `supportsMultipleProviderThreadsPerSession`, else a newly allocated id (5212-5220, 859-877).
- Provider thread: the active one updated (`providerSessionId`, `lastRunOrdinal`, `handoffIds`) or a new one (`status "not_loaded"`, `firstRunOrdinal = lastRunOrdinal = ordinal`) (5243-5271). v1-imported threads may get a legacy import context handoff (5227-5242).
- Checkpoint scope: none for `defer_start`; else prepared with cwd = runtime policy cwd, else thread worktree, else server cwd (5274-5298).
- Run: `status "preparing"` for `defer_start`, else `"starting"`; `queuePosition: null`; `workspacePreparation` = `workspaceStrategy` when given with `defer_start`; `workStartedAt` only for wake runs (5299-5324, 381-403).
- Attempt (initial, pending) and root node (pending) as in path A.
- User turn item: id `turn-item:message:<messageId>`, `status "completed"`, `inputIntent "turn_start"`, `providerTurnId: null`, text, context, attachments, provenance (5378-5407).
- `defer_start` adds a `command_execution` item with `input` and `title` `"Preparing workspace"`, `status "running"` (5408-5431).

Events, in order: [`thread.unsettled`], [`thread.unsnoozed`], [`thread.metadata-updated` title], [selection event], `provider-thread.updated`, [`context-handoff.updated`], `run.created`, [`plan.updated`], `run-attempt.created`, `node.updated`, [`checkpoint-scope.created`], `message.updated`, `turn-item.updated` (user message or notification), [`turn-item.updated` preparation item] (5433-5518).

Effects: [`thread-title.generate`], and `provider-turn.start { runId }` with id `effect:<commandId>:provider-turn.start:<runId>`, except for `defer_start` (5519-5527).

### 7.8 Path C: start a run with context handoff (Orchestrator:5530-6467)

Taken when a pending fork transfer exists (thread created by `thread.fork`, not yet consumed), a pending merge-back transfer exists, or the active provider thread belongs to another provider instance.

- Rejections: `Thread ${threadId} has pending merge-back transfers from multiple forks.` (5130-5136); `Pending fork transfer ${id} has no resolvable source provider thread.` (5569-5575); `Pending fork transfer ${id} has no source provider.` (5576-5582); `Pending merge-back transfer ${id} has no resolvable source run.` (5896-5902); `Pending merge-back transfer ${id} has no resolvable source provider thread.` (5907-5913); CommandPolicy `decideForkExecution`, `ensureNativeFork`, and `ensureContextHandoff` with strategies `full_thread_summary`, `delta_context` or `fork_delta_context` (5634-5663, 5783-5796, 5914-5924).
- Run: always `status "starting"`, `contextHandoffId` set to the handoff used (5990-6017).
- Handoff turn item: type `handoff`, title `"Fork context"`, `"Provider handoff"` or `"Merge-back context"`, strategy and summary (6116-6154).
- Events include, as applicable: `context-transfer.updated` (fork pending, resolved_portable, consumed; merge-back superseded/consumed), `provider-thread.updated` (status `active`), `context-handoff.updated`, `context-transfer.created` (provider handoff, status `consumed`), `run.created`, `plan.updated`, `run-attempt.created`, `node.updated`, `checkpoint-scope.created`, handoff `turn-item.updated`, `message.updated`, user `turn-item.updated` (`turn_start`) (6177-6430).
- When the native thread can be resumed across instances: `provider-session.detached` with reason `Provider account changed; continuing the native thread.` and effect `provider-session.detach` with id `effect:<commandId>:provider-session.detach:<sessionId>` (6432-6459).
- Effect: `provider-turn.start` with id `effect:<commandId>:provider-turn.start:<runId>` (6460-6466).

### 7.9 Path D: steer or restart the active run (Orchestrator:3728-4459)

Preconditions, each failing with `OrchestratorDispatchError` and this cause string:

| Check | Cause |
|---|---|
| target run exists | `Target run ${targetRunId} was not found.` (3765-3771) |
| message is not `/compact` or `/logout` (no attachments, case-insensitive) | `Context compaction must run as a separate turn. Queue it or wait for the active turn to finish.` or `Signing out must run as a separate turn. Queue it or wait for the active turn to finish.` (3772-3781) |
| message is not `/goal` | `Goal commands must run as a separate turn. Queue it or wait for the active turn to finish.` (3782-3789) |
| target run's own message is not `/compact` or `/logout` | `Wait for context compaction to finish before steering the thread.` or `Wait for sign-out to finish before steering the thread.` (3790-3802) |
| target has a root node | `Target run ${id} has no root node.` (3803-3810) |
| target status is `running` | `Target run ${id} is ${status} and cannot be steered.` (3811-3817) |
| provider thread has a session | `Provider thread ${providerThreadId} has no active provider session for steering.` (3818-3827) |
| a provider turn of the active attempt is `running` | `No running provider turn found for active run ${id}.` (3829-3839) |
| the session is live in this process | `Provider session ${id} is not active.` (3840-3856) |
| adapter accepts the selection change | the adapter's `selectionTransition.reason` (3861-3893) |
| restart only: run has an active attempt | `Active run ${id} has no attempt to interrupt.` (4432-4439) |

Steering decision (3975-3995): `selectionChanged` compares the target run's selection with the effective one. `selectionMustApplyNow` = selection changed and (instance changed or the adapter's transition is not `apply_on_next_turn`). `forceRestart` = `restart_active` or `selectionMustApplyNow` or (selection changed and the session supports interrupt plus interrupt-restart). Then `decideSteeringExecution` with the live session's capabilities (`session.providerSession.capabilities`).

Active steering (3997-4044):
- If not a delegated completion and the thread selection differs, emit `thread.provider-switched` or `thread.model-selection-updated` (the steer's selection becomes the saved next-turn choice).
- `message.updated`: `runId` = target run, `nodeId` = target root node, `role "user"`.
- `turn-item.updated`: `user_message`, `inputIntent "steer"` (or `"promoted_queued_to_steer"`), `providerTurnId` = the running provider turn.
- Effect `provider-turn.steer { providerSessionId, providerThreadId, providerTurnId, messageId }` with id `effect:<commandId>:provider-turn.steer:<providerTurnId>`.
- The run, attempt and `run.userMessageId` do not change. Clients must associate steer messages by `message.runId`, not `run.userMessageId`.

Interrupt and restart (4047-4458):
- New attempt ordinal = max existing + 1; new attempt id and new root node id `node:run:<runId>:attempt:<k>:root`.
- Instance change without native resume, or adapter transition `create_with_handoff`: `ensureContextHandoff` (`full_thread_summary`), new or reused provider thread, `context-handoff.updated`, `context-transfer.created` (type `provider_handoff`, status `consumed`), session transition `detach` (4095-4216). Native resume across instances or transition `restart_session`: new provider session id, session transition `replace` (4217-4235).
- Events, in order: `run-attempt.updated` (old attempt `superseded`), `node.updated` (old root `interrupted`), [selection event], [`provider-thread.updated`], [`context-handoff.updated`], [`context-transfer.created`], `run.updated` (same run id, `status "starting"`, new `rootNodeId` and `activeAttemptId`, `userMessageId` = the steer messageId, new `providerInstanceId`/`modelSelection`, `contextHandoffId`), `run-attempt.created` (`reason "steering_restart"`, `status "pending"`), `node.updated` (new root pending), `checkpoint-scope.created`, `message.updated`, `turn-item.updated` (`inputIntent "steer"` or `"promoted_queued_to_steer"`, `providerTurnId: null`) (4321-4431).
- Effect `provider-turn.restart { providerSessionId, providerThreadId, providerTurnId, interruptedAttemptId, runId, sessionTransition? }` with id `effect:<commandId>:provider-turn.restart:<providerTurnId>` (4440-4458). The worker interrupts and waits for the turn to terminalize, detaches the old session if needed, then starts the provider turn (`o2/EffectWorker.ts:300-346`; `o2/ProviderTurnControlService.ts:221-286`).
- `inputIntent` is `steer` for both active steering and restart. A client can tell them apart by the new attempt with `reason "steering_restart"`.

Static turn capabilities per adapter (the server uses the live session's negotiated copy):

| Adapter | supportsInterrupt | supportsActiveSteering | supportsSteeringByInterruptRestart | supportsQueuedMessages | Source |
|---|---|---|---|---|---|
| Claude | true | true (activeSteeringInterruptsTools true) | false | true | apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:203-207 |
| Codex | true | true | true | true | apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts:271-274 |
| ACP | true | false | true | true | packages/provider-acp/src/server/adapter.ts:556-559 |
| Cursor | true | false | true | true | packages/provider-cursor/src/server/adapter.ts:104-107 |
| Muse | true | true | false | true | packages/provider-muse/src/server/adapter.ts:110-113 |
| OpenCode (v2) | true | true | true | true | packages/provider-opencode/src/server/v2/adapter.ts:126-131 |
| Pi | true | true | false | true | packages/provider-pi/src/server/adapter.ts:141-144 |

Grok spreads the ACP capabilities (`packages/provider-grok/src/server/adapter.ts:81-82`); whether it overrides `turns` later in that object is UNVERIFIED. Consequences: on ACP or Cursor, `steer_active` becomes an interrupt-and-restart; on Claude, Muse or Pi, `restart_active` (or a selection change that must apply now) is rejected with the `interrupt_restart_steering` capability error.

Delivery after commit (`o2/ProviderTurnControlService.ts:287-368`; `o2/EffectWorker.ts:205-299`):
- The steer effect sends the persisted message (text projected with composer context) to the adapter's `steerTurn`.
- If the provider turn already ended, the effect fails with `turnCompleted` (ProviderTurnControlService.ts:121-130, 340-355). The worker then dispatches a follow-up `message.dispatch` with commandId `command:steer-follow-up:<effectId>`, the same messageId, text, context and attachments, `dispatchMode start_immediately` (or `queue_after_active` for delegated completions) (EffectWorker.ts:234-289). That re-points the message to a new run; the user turn item with the same id is overwritten with `turn_start` (or `queued_turn` when queued). Test: exactly one message and one `user_message` item remain, owned by the new run (`o2/SteeringCompletion.integration.test.ts:370-397`).
- A delivered delegated-completion steer is followed by `notification.delivery.accept` with commandId `command:mailbox-accepted:<effectId>` (EffectWorker.ts:215-233).

### 7.10 Complete list of `message.dispatch` rejection causes

All are `OrchestratorDispatchError` with the quoted string as cause, unless noted.

- Subagent thread: `OrchestratorSubagentThreadReadOnlyError` (Orchestrator:10260-10265).
- Unknown thread: `OrchestratorProjectionError` wrapping `No orchestration projection exists for thread ${threadId}.` (Orchestrator:10253-10259).
- `This thread can no longer be resumed from that run.` (4484).
- `Notifications must be server- or provider-created queued messages.` (4677).
- `Delegated completion delivery must be a server-created queued message.` (4693).
- `Delegated completion delivery is no longer dispatchable.` (4712).
- `Proposed plan ${planId} does not exist on thread ${threadId}.` (4777), `Proposed plan ${planId} belongs to a different project.` (4787), `Proposed plan ${planId} is not active.` (4794).
- Path A: `Thread ${threadId} has a pending merge-back transfer; queued merge-back consumption is not implemented yet.` (4857); `Active run ${activeRunId} has no provider thread for queued dispatch.` (4869); queued-messages capability error.
- Path C: messages in 7.8; context handoff and fork capability errors.
- Path D: messages in 7.9; steering capability errors.
- Adapter lookup: `OrchestratorProviderAdapterError` (path B/C) or `OrchestratorDispatchError` (path A), both surfacing `No orchestration provider adapter is registered for ${instanceId}.`
- Not found: no archived or deleted check exists on the normal paths (only in the three continuation checks, Orchestrator:4477-4478, 4502-4503, 4538-4539); a message to an archived thread is accepted.

---

## 8. `run.interrupt`

Payload (contracts:2911-2922): `{ type: "run.interrupt", commandId, threadId, runId, reason?: string, holdQueue?: boolean }`. The contract comment: `holdQueue` "Set by the Stop button. Stop also holds the queue, ends the thread's pull request watches, and stops every delegated task under the thread."

Handler (Orchestrator:8637-9025):

1. Load runs, nodes, provider threads and turns, messages, attempts, subagents, runtime requests, and pending/running/waiting background-capable turn items thread-wide (8643-8668).
2. `hasBackgroundWork`: the target is the latest non-queued run and has pending background work (8678-8686).
3. Provider turn to interrupt: the latest turn of the active attempt when the run is `running`, or the turn is `running`, or background work exists; otherwise, with background work, the latest turn of the run's provider thread (8689-8699).
4. Run, root node or provider thread missing: `Run ${runId} is not interruptible.` (8700-8706). Queued runs also end here (no provider turn and status not preparing/starting/running: 8936-8942); use `queued-run.cancel` instead.

Three outcomes:

- No provider turn and run `preparing`/`starting`/`running` (interrupt before provider start, 8815-8934). Requires the active attempt (`Run ${runId} has no active attempt to interrupt.`). Events: `turn-item.updated` `run_interrupt_request` (`status "completed"`, title `Interrupt requested`, `message: reason ?? "Interrupt requested"`), `turn-item.updated` `run_interrupt_result` (`status "interrupted"`, title `Interrupted`, message `Run interrupted before provider start`, `parentItemId` = request item), the running `"Preparing workspace"` item set `interrupted` with title `Workspace preparation interrupted` and output `reason ?? "Interrupted before provider start"`, `run-attempt.updated` interrupted, `node.updated` interrupted, `run.updated` with `status "interrupted"` and `completedAt`. Then the Stop or cohort work below, other-provider interrupts, and cancellation of unsettled `provider-turn.start` and `provider-turn.restart` effects for the thread with reason `Run ${runId} was interrupted before its provider turn started.` (8927-8933; `o2/EffectOutbox.ts:444-467`).
- Provider turn found but its session is not live (8958-8980): emit the request item, Stop or cohort work, then settle locally: `provider-turn.updated` interrupted, `run-attempt.updated` interrupted, `provider-thread.updated` idle, streaming messages finalized, run-owned subagents cascaded, pending runtime requests of the run `cancelled` with `responseCapability: { type: "not_resumable", reason: "The run was interrupted." }`, a `run_interrupt_result` item with message `Run interrupted by user`, `run.updated` interrupted (with `delegatedCompletion` omitted), effect `checkpoint.capture` (id `effect:checkpoint.capture:<runId>`) (8213-8394); and end orphaned background work items as `interrupted` (8115-8209).
- Provider turn found with a live session (8981-9024): `ensureInterrupt` capability check, then the request item, Stop or cohort work, and effect `provider-turn.interrupt { providerSessionId, providerThreadId, providerTurnId }` with id `effect:<commandId>:provider-turn.interrupt:<providerTurnId>`, plus one such effect for each other live provider thread with pending background work (8757-8813). The command does not change the run status; the run turns `interrupted` when the provider reports the terminal turn, with a `run_interrupt_result` item `Run interrupted by user` (`o2/RunExecutionService.ts:642-729`, `:1473-1503`). After the interrupt effect, the worker dispatches internal `thread.background-work.settle` with commandId `<effectId>:background-work-settled` (`o2/EffectWorker.ts:165-204`).

`holdQueue`:
- `true` (Stop): `holdStoppedThread` (8475-8547): every queued run not yet held gets `run.updated` with `queueHeld: true`; if any pull request watch exists, `thread.pull-request-synced` removes all watches; every delegated completion cohort with an owed delivery is disposed with disposition `"stopped"`; cancelled runs awaiting a restart continuation get interrupt-request markers. The dispatcher also adds effect `delegated-tasks.stop { reason? }` with id `effect:<commandId>:delegated-tasks.stop` (Orchestrator:10293-10306), which dispatches `thread.stop` to each app-owned delegated child with commandId `<commandId>:stop:<childThreadId>`, recursively (`o2/ThreadManagementService.ts:845-869`).
- absent or `false`: only the delegated cohort of this run (or of the run that woke it) is disposed with `"stopped"` (8711-8732). The queue is not held, so the next queued run starts automatically after the interrupted run terminalizes (section 11).

Official client Stop (`commands.ts:780-832`): targets the latest active run, else the latest run with pending background work, and always sends `holdQueue: true`; with no run to stop, it turns off pull request watches with `thread.pull-request.watch { watching: false }` instead.

Tests: `o2/ThreadStop.test.ts:149-213` (run statuses `["completed", "interrupted"]`, watches cleared, delegated delivery `disposed`, effect `delegated-tasks.stop`); `o2/runtimeLayer.test.ts:4110-4160` (queued run stays `queued` with `queueHeld: true`; no turn item for it).

User-facing rejections: `Run <runId> is not interruptible.`, `Run <runId> has no active attempt to interrupt.`, `Provider thread <id> has no active provider session.` (8981-8987), `<Provider> cannot stop a run once it has started.`

## 9. `thread.stop` (internal only)

Payload (contracts:3105-3115): `{ type: "thread.stop", commandId, threadId, reason? }`. Comment: "Stop for one thread, whatever it is doing: interrupts its running turn, holds its queue, ends its pull request watches, and drops pending delegated-task wakes. Nothing to stop is an accepted no-op."

Handler (Orchestrator:9033-9110):
- Deleted thread: no events, accepted (zero-event commands allowed, Orchestrator:10501-10504).
- Target: the latest `preparing`/`starting`/`running` run, else the latest non-queued run if it has pending background work.
- With a target, run the `run.interrupt` logic with `holdQueue: true` in an isolated buffer; on success adopt its events and effects (no `delegated-tasks.stop` effect is added here; the caller stops children).
- Otherwise (no target or the interrupt failed): add `run_interrupt_request` markers for the target and the latest executed non-live run, then `holdStoppedThread` (queue held, watches ended, cohorts stopped).
- Senders: the `delegated-tasks.stop` effect (ThreadManagementService.ts:845-869) and MCP task cancellation (`OrchestratorMcpService.ts:2005-2025`). Test: an idle thread accepts `thread.stop`, and a second stop commits zero events (`o2/ThreadStop.test.ts:216-238`).

---

## 10. Queue commands

### 10.1 `queued-message.promote-to-steer`

Payload (contracts:2923-2929): `{ type, commandId, threadId, queuedRunId: RunId, targetRunId: RunId }`.

Handler (Orchestrator:7328-7466):
- Thread archived or deleted: `Thread ${threadId} is not active.`
- Run missing or not `queued`: `Queued run ${queuedRunId} is not queued.`
- Missing root node, attempt or message: `Queued run ${id} is missing message or execution state.`
- Message is a notification or delegated completion: `Automatic completion deliveries cannot be promoted to Steer.`
- Events: `run.updated` (queued run `status "cancelled"`, `queuePosition: null`, `completedAt`), `run-attempt.updated` cancelled, `node.updated` cancelled; then path D (7.9) with the queued message's text, attachments, context and provenance, `modelSelection = thread.modelSelection` (not the queued run's), `forceRestart: false`.
- The new turn item has `inputIntent "promoted_queued_to_steer"`; `message.updated` re-points the message from the cancelled queued run to the target run.
- There is no too-late downgrade here. If the target is not `running` or has no running provider turn, the whole command is rejected and nothing is committed.
- A held queue does not block promotion. The cancellation is a terminal `run.updated`, so the terminal-run reactor tries to start the next queued run, which does nothing while the target is active.

### 10.2 `queue.resume`

Payload (contracts:2930-2934): `{ type, commandId, threadId }`.

Handler (Orchestrator:10314-10370):
- Thread archived or deleted: `Thread ${threadId} is not active.`
- The thread is usage-limit blocked (latest executed run failed with a `usage_limit` root failure, or the newest session error says so): `Continue the limited thread before resuming its queue.` (`packages/shared/src/orchestrationV2ThreadError.ts:51-94`).
- Events: one `run.updated` per queued run with `queueHeld: false` (written even when the flag was already false); if there are no queued runs, a single `thread.metadata-updated` with the unchanged thread, so the command never has zero events.
- After commit, and also on every replay of the same commandId: `startNextQueuedRun(threadId)` (Orchestrator:10474-10476, 10611-10613). The start is a separate system write (section 11); the returned `sequence` does not include it.
- Tests: resume twice with one commandId starts the reordered head (`starting`), keeps the other `queued`, clears all holds, and creates no duplicates (`o2/runtimeLayer.test.ts:4244-4259`).
- Official "resume" UI: with a resumable interrupted or usage-limited run, send a `message.dispatch` with `manualContinuationOfRunId`, text `Continue where you left off.` and `start_immediately`, then `queue.resume` if held runs exist; otherwise only `queue.resume` (`apps/web/src/components/ChatView.tsx:8675-8708`).

### 10.3 `queued-run.reorder`

Payload (contracts:2935-2941): `{ type, commandId, threadId, runId: RunId, beforeRunId: RunId | null }`; `null` means move to the end.

Handler (Orchestrator:7468-7557):
- Order is computed with `queuedRunsInDeliveryOrder` (section 11).
- Not queued: `Run ${runId} is not queued.`
- Moving a notification or delegated-completion run: `Automatic completion deliveries cannot be reordered.`
- `beforeRunId` is an automatic completion run: `Queued messages cannot be reordered ahead of automatic completion delivery.`
- `beforeRunId` not among reorderable queued runs: `Queue target ${beforeRunId} is not queued.`
- New order: automatic completion runs first, then the reorderable runs with the moving run inserted before `beforeRunId`. Positions are renumbered `1..N` across all queued runs; a `run.updated` (`queuePosition` changed only) is emitted for each run whose position changes.
- If nothing changes, zero events, so the command is rejected with `Command produced no domain events.` (Orchestrator:10497-10512).
- Allowed while the queue is held; does not release the hold (`o2/runtimeLayer.test.ts:4226-4243`).

### 10.4 `queued-run.cancel`

Payload (contracts:2942-2947): `{ type, commandId, threadId, runId }`.

Handler (Orchestrator:7559-7651):
- Not queued: `Run ${runId} is not queued.` (a second cancel fails this way; `o2/runtimeLayer.test.ts:4405-4413`).
- Delegated-completion delivery run: dispose the whole cohort with disposition `"disposed"` (2070-2151). If the parent run is not found this yields zero events and is rejected with `Command produced no domain events.`
- Otherwise: `run.updated` (`status "cancelled"`, `queuePosition: null`, `completedAt`), `run-attempt.updated` cancelled, `node.updated` cancelled. Other runs keep their positions, so gaps can appear.
- The removed message keeps its row but never surfaces as a transcript row (`o2/runtimeLayer.test.ts:4387-4402`).
- `cancelled` is terminal, so the terminal-run reactor runs `startNextQueuedRun` (it only starts something if nothing is active and nothing is held).

### 10.5 `queued-run.edit`

Payload (contracts:2948-2958): `{ type, context?: OrchestrationMessageContext, commandId, threadId, runId, text: string, attachments?: ChatAttachment[] }`. Comment: `attachments` is the full replacement list; absent leaves attachments as they are.

Handler (Orchestrator:7653-7742):
- Blank text: `Queued run ${runId} cannot be edited to an empty message.`
- Not queued: `Run ${runId} is not queued.`
- No message: `Queued run ${id} has no user message.`
- Notification or delegated completion: `Automatic completion deliveries cannot be edited.`
- Events: `message.updated` with new `text`, `attachments` (if given), `context` (if given; omitting it keeps the old context), `updatedAt`; plus `turn-item.updated` only when a legacy `user_message` item exists (normally none, `o2/runtimeLayer.test.ts:4324-4327`).
- Any `OrchestratorDispatchError` rejection is reported as `OrchestratorCommandRejectedError` (Orchestrator:10537-10547; test `o2/runtimeLayer.test.ts:4369-4378`). The user-facing message is still the cause string.
- Intake claims attachments only when `attachments` is present (ThreadMessageIntake.ts:127-130).
- The model selection of a queued run cannot be edited.
- Allowed while the queue is held.

---

## 11. Queue model and auto-advance

Representation:
- No separate queue entity. A queue entry is a run with `status "queued"`, `queuePosition` (positive int, `null` once it leaves the queue) and optional `queueHeld` (contracts:551-554). Its attempt is `pending`, its root node `pending`, and its message already exists with `runId` = the queued run.
- Run ordinals follow submission order, not execution order.

Delivery order (`o2/QueuedRunOrder.ts:12-31`): queued runs whose message has `delegatedCompletion` come first; then ascending `queuePosition ?? ordinal`; then ascending `ordinal`. Test: `o2/QueuedRunOrder.test.ts:6-50`.

Hold ("paused queue"):
- Stop (`run.interrupt` with `holdQueue: true`, or `thread.stop`) holds every queued run (Orchestrator:8497-8506).
- Restart recovery holds every queued run (`o2/ProviderRuntimeRecoveryService.ts:287-300`; test `o2/runtimeLayer.test.ts:4162-4225`, which also shows the active run left `cancelled`).
- A failed run whose root failure class is not `validation_error`, on the same provider instance as the next queued run, holds all queued runs ("A provider that just failed will likely fail the next message too.") (Orchestrator:1297-1325).
- New queued runs inherit `queueHeld: true` while any queued run is held (Orchestrator:4960-4964).
- Only `queue.resume` releases the hold. `resumeQueuedRuns` exists on the service but has no production caller (only tests).

Auto-advance:
- Trigger: a detached subscription on `run.updated` events with status `completed`, `interrupted`, `failed`, `cancelled` or `rolled_back`, skipping commandIds starting with `command:runtime-reconcile:` (Orchestrator:10679-10697). Under the thread lock it finalizes delegated completion deliveries, then calls `startNextQueuedRun(threadId, { failedRunId })` (Orchestrator:10630-10674).
- Because a finished turn first parks the run in `waiting` (still active) and only checkpoint capture sets `completed`, the next queued message starts after `completed` (RunExecutionService.ts:642-653; CheckpointCaptureService.ts:201-237).

`startNextQueuedRun` gates (Orchestrator:1266-1325): there must be a queued run, no active run, no held queued run, the thread not archived or deleted (SQL fast path `canStartQueuedRun`, `o2/ProjectionStore.ts:4636-4653`), and the thread not usage-limit blocked; then the failed-run hold rule above.

Start events. These are system events written with no commandId; the effects carry commandId `command:system:start-queued:<runId>` (Orchestrator:1370-1869):
- [`thread.model-selection-updated` or `thread.provider-switched` when the run's selection differs from the thread's]
- [`context-transfer.created` and `context-handoff.updated` for a provider handoff]
- [`context-handoff.updated` legacy import]
- [handoff `turn-item.updated`, title `Provider handoff` or `Imported context`]
- [`provider-session.detached` for released sessions, reason `Provider or model selection changed.`]
- [`checkpoint-scope.created` plus `node.updated` when the scope was deferred]
- `provider-thread.updated` (`status "not_loaded"`, session id, `lastRunOrdinal`)
- `turn-item.updated` `user_message` with `inputIntent "queued_turn"` (or a notification item)
- `run.updated` (`status "starting"`, `queuePosition: null`, `contextHandoffId`, `workStartedAt` for wakes)

Start effects: `provider-session.detach` per released session, and `provider-turn.start` with id `effect:command:system:start-queued:<runId>:provider-turn.start:<runId>`.

Failure to start (`failQueuedRunStart`, Orchestrator:1161-1264): `run-attempt.updated` failed, `node.updated` failed, an `error` turn item titled `Queued provider could not start` with failure code `context_handoff_unsupported` (class `validation_error`) when the handoff capability was missing, else `queued_start_failed` (class `unknown`), and `run.updated` `failed` with `queuePosition: null`. That terminal update triggers the next start attempt.

Interplay with other commands:
- `thread.archive` cancels all queued runs (Orchestrator:3250-3302).
- `thread.settle` is rejected while user queued runs exist (`Thread ${threadId} has active or blocked work and cannot be settled.`) but cancels automatic queued runs (Orchestrator:2585-2651).
- `thread.snooze` is rejected while any run is queued (`Thread ${threadId} has a queued run and cannot be snoozed.`, Orchestrator:2751-2757).

---

## 12. `runtime-request.respond` and `thread.user-input.dismiss`

### 12.1 Payload and allowed values

`runtime-request.respond` (contracts:2959-2967):
```ts
{
  type: "runtime-request.respond",
  commandId: CommandId,
  threadId: ThreadId,
  requestId: RuntimeRequestId,
  decision?: "accept" | "acceptForSession" | "acceptAlways" | "decline" | "cancel",
  answers?: Record<string, unknown>,
  attachmentsByQuestionId?: Record<string, Array<ChatImageAttachment | ChatFileAttachment>> // at most 100 per question
}
```
(`packages/contracts/src/providerPolicy.ts:50-57`, `:67-76`)

- Everything is optional. The orchestrator does not cross-check `decision` or `answers` against the request kind.
- Request kinds: `command`, `file-read`, `file-change`, `mcp-elicitation`, `permission` (providerPolicy.ts:38-44) plus `dynamic_tool_call`, `user_input`, `auth_refresh` (contracts:1030-1033).
- Request status: `pending` | `resolved` | `expired` | `cancelled`. `responseCapability`: `{ type: "live", providerSessionId }` | `{ type: "message" }` | `{ type: "not_resumable", reason }` (contracts:1025-1045).
- Approval items may list provider choices `options: { decision, label, warning? }[]` and `appName` for MCP elicitations (contracts:1459-1469; providerPolicy.ts:59-65).
- Question items: `questions: { id, header, question, options: { label, description, value? }[], multiSelect?, allowCustomAnswer?, initialAnswer?, required? }[]`, `responseMode?: "message"` (contracts:1151-1167, 1418-1425). Answers are keyed by question id.

Mapping of the "approve once / for session / always / deny / cancel" vocabulary: approve once = `accept`, approve for session = `acceptForSession`, always = `acceptAlways`, deny = `decline`, cancel = `cancel`. Example adapter mapping (Codex): `accept` -> `approved`, `acceptForSession` and `acceptAlways` -> `approved_for_session`, `decline` -> denied with `User declined the request.`, `cancel` -> `abort`; permission requests are granted (scope turn or session) only for `accept`/`acceptForSession` (`apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts:561-601`). MCP elicitation options and responses: `apps/server/src/provider/CodexMcpElicitation.ts:132-214`. Other adapters: UNVERIFIED.

Not covered by this command:
- Plan approval is not a runtime request. The web client sets interaction mode `default` and sends `message.dispatch` with `sourcePlanRef` (`ChatView.tsx:10454-10497`); the server marks the plan completed (7.3 step 12).
- Secret requests use the separate RPC `secrets.answerRequest` with payload `{ threadId, turnItemId, answer: { type: "save", secret } | { type: "decline" } }` (`packages/contracts/src/secretRequest.ts:9-16`; `rpc.ts:506`, `:1757-1760`; ws.ts:2064-2067). The card is recorded by internal `secret_request.record` (Orchestrator:6973-7058).

### 12.2 Handler (Orchestrator:7061-7288)

Validation:
- `Runtime request ${requestId} was not found.`
- `Runtime request ${requestId} is ${status}.` (when not pending)
- `not_resumable`: its `reason` string
- `Provider session ${id} was not found.` (live request whose session record is gone)

Events (7107-7192):
- `runtime-request.updated`: `status "resolved"`, `resolvedAt`, plus `decision` and/or `answers` as sent.
- `node.updated` for the request node: `status "cancelled"` when `decision` is `decline` or `cancel`, else `"completed"`.
- `turn-item.updated` for the `approval_request` or `user_input_request` item with the same status. For a `user_input_request` answered with `answers`, it also gets `questionAnswer { requestId, answers, attachmentsByQuestionId, questionTextById }`.

Live requests: effect `runtime-request.respond { providerSessionId, requestId, decision?, answers? }` with id `effect:<commandId>:runtime-request.respond:<requestId>` (7272-7287). The worker calls the live session; failures (`request-missing`, `request-not-ready`, `request-not-resumable`, `provider-session-not-active`, `unexpected-failure`) affect only the effect, not the already committed command (`o2/RuntimeRequestService.ts:17-47`, `:76-135`).

Message-capable questions (`responseCapability.type === "message"`, async questions) (7193-7271):
- `decline`/`cancel`: stop after the resolution events.
- The item must be a `user_input_request`, else `The question for this request was not found.`
- Each question needs a non-blank string answer unless `required === false`, else `Answer each question before sending.`
- At least one answer, else `Enter an answer before sending.`
- In the same transaction a `message.dispatch` is planned with `messageId: "async-answer:<requestId>"`, text = `"<question>\n<answer>"` blocks joined by blank lines, no attachments, `createdBy "user"`, `creationSource "server"`, and `dispatchMode` `steer_active` at the running turn when its live session supports active steering, else `queue_after_active` (which starts immediately when nothing is active).

Attachments in answers: see 1.4 (paths are appended into the answer text before the command reaches the orchestrator).

### 12.3 `thread.user-input.dismiss`

Payload (contracts:2968-2973): `{ type, commandId, threadId, requestId }`.

Handler (Orchestrator:7290-7326):
- Request missing or not pending: `This question has already been answered.`
- Not a message-capable `user_input` request: `This question needs an answer. Answer it or stop the turn.`
- Otherwise identical to `runtime-request.respond` with `decision: "cancel"`: `runtime-request.updated` (`resolved`, `decision "cancel"`), `node.updated` cancelled, item `cancelled`. No message, no effect.
- Settling a thread auto-dismisses such questions in the same transaction (Orchestrator:2624-2639). Test: `o2/runtimeLayer.test.ts:1166`.

---

## 13. `checkpoint.rollback` and `checkpoint.rollback.fail`

### 13.1 `checkpoint.rollback`

Payload (contracts:2974-2981): `{ type, restoreFiles?: boolean, commandId, threadId, scopeId: CheckpointScopeId, checkpointId: CheckpointId }`. Omitted `restoreFiles` means files are restored (`restoreFiles !== false`).

Handler (Orchestrator:9112-9287), checks in order:
- `No active provider thread exists for rollback.`
- `Provider thread ${id} has no provider session.`
- Capabilities of the thread's selected instance (adapter static capabilities, not the session's): `ensureRollback` (capabilities `rollback` / `rollback_snapshot`).
- `Checkpoint ${checkpointId} was not found.`
- `Checkpoint ${checkpointId} is ${status} and cannot be restored.` (status must be `ready`; checkpoint statuses `ready` | `missing` | `error` | `stale`, contracts:1212)
- `Checkpoint scope ${scopeId} was not found.`
- `Checkpoint ${checkpointId} belongs to scope ${actual}, not ${requested}.`
- When restoring files, the workspace must be isolated, else `File restore requires an isolated worktree. This workspace may contain changes from another thread. Rewind the conversation without restoring files instead.` Isolation requires the thread to have a worktree equal to the scope cwd and no other thread's worktree, scope cwd, live non-shared session cwd or project root nested with it (`o2/CheckpointRestoreSafety.ts:9-87`).
- For a checkpoint after run N (`appRunOrdinal > 0`): `Cannot roll back to checkpoint ${id}: its provider turn is unavailable.` and `Cannot roll back provider thread ${pt} to checkpoint ${cp}: target provider turn ${turn} belongs to provider thread ${other}.`
- No check for an active run was found at dispatch.

Events: `thread.metadata-updated` with `rollbackRequestId: commandId`, `rollbackFailure: null`, then `checkpoint.rollback-requested { scopeId, checkpointId, requestedAt }` (9241-9271; contracts:427-437, 1218-1222). Effect `provider-thread.rollback { restoreFiles?, providerThreadId, checkpointId, scopeId }` with id `effect:<commandId>:provider-thread.rollback:<providerThreadId>:<checkpointId>` (9272-9286). Test asserting exactly `["thread.metadata-updated", "checkpoint.rollback-requested"]` plus that effect: `o2/runtimeLayer.test.ts:752-760`.

Execution (`o2/CheckpointRollbackService.ts:110-354`):
- Re-checks (reasons `rollback-target-invalid`, `active-provider-changed`, `provider-turn-unavailable`, `shared-workspace`, `unexpected-failure`; 31-64).
- Runs to roll back: ordinal greater than the checkpoint's run ordinal and status `completed`, `interrupted`, `failed` or `cancelled`. The provider conversation is rolled back only when such runs exist.
- Files restored unless `restoreFiles` is `false`; newer ready checkpoints in the scope are dropped.
- Under the thread lock it writes system events: `provider-thread.updated` (`lastRunOrdinal` = target or `null`), `checkpoint.captured` with `status "stale"` for dropped checkpoints, `run.updated` `rolled_back` and `node.updated` `rolled_back` for each rolled-back run.
- There is no explicit "rollback succeeded" event. Clients observe the `rolled_back` runs or a `rollbackFailure`.

Failure after the last attempt (5): the worker dispatches internal `checkpoint.rollback.fail` with commandId `<rollbackCommandId>:rollback-failed`, `requestId` = the rollback commandId, message `The provider could not roll back this conversation. Try again; if it keeps failing, check the provider and server logs.` (`o2/EffectWorker.ts:370-413`; CheckpointRollbackService.ts:31-32).

Official client: sends `checkpointId` and `scopeId` directly when the server advertises `serverResolvedCommandContext`; otherwise it resolves the checkpoint from its projection and fails locally with `OrchestrationV2CheckpointUnavailableError` (`commands.ts:872-917`; contracts:1226-1236).

### 13.2 `checkpoint.rollback.fail` (internal only)

Payload (contracts:3084-3091): `{ type, commandId, threadId, requestId: CommandId, message: TrimmedNonEmptyString }`.

Handler (Orchestrator:9294-9325):
- Deleted thread: zero events, so it is rejected with `Command produced no domain events.`
- `thread.rollbackRequestId !== requestId`: `Rollback ${requestId} is no longer the thread's current rollback.`
- Else `thread.metadata-updated` with `rollbackFailure { requestId, message }`.
- A newer rollback clears it. Tests: `o2/runtimeLayer.test.ts:611-678`.

---

## 14. `provider.switch` and `provider-session.detach`

### 14.1 `provider.switch`

Payload (contracts:3048-3053): `{ type, commandId, threadId, modelSelection: ModelSelection }`.

Handled by `dispatchThreadMutation` (Orchestrator:10237-10242, 2367-3409):
- Deleted thread: `Thread ${threadId} is deleted.` (2410-2416).
- The target adapter must exist (`OrchestratorProviderAdapterError`).
- `ProviderSwitchService.plan` must not reject, e.g. `The target provider instance is unavailable.` (Orchestrator:2672-2692; `o2/ProviderSwitchService.ts:69-206`; `o2/ProviderSessionTransitionPolicy.ts:14-95`).
- No active-run check was found.
- Events: `thread.provider-switched` with the thread updated (`providerInstanceId`, `modelSelection`, `updatedAt`) (3172-3179, 3226-3227). For each live session (status not `stopped`/`error`) in the plan's `releaseProviderSessionIds`: `provider-session.detached` with reason `Provider or model selection changed.` and effect `provider-session.detach` (`detail` same text) with id `effect:<commandId>:provider-session.detach:<sessionId>` (3319-3396).
- `thread.model-selection.set` behaves the same except the event is `thread.model-selection-updated` when the instance is unchanged (3222-3225).
- Official clients send `thread.model-selection.set` for any change when `serverResolvedCommandContext` is true; otherwise they pick by instance (`commands.ts:586-598`; `packages/shared/src/model.ts:17-25`).
- Selection changes made through `message.dispatch` are described in 7.7 to 7.9 and section 11.

### 14.2 `provider-session.detach`

Payload (contracts:2830-2836): `{ type, commandId, threadId, providerSessionId, reason?: string }`.

Handler (Orchestrator:3411-3462):
- The session must be bound to the thread, else `Provider session ${providerSessionId} does not belong to thread ${threadId}.`
- Events: `provider-session.detached { providerSessionId, detachedAt, reason? }` (the projection drops the session).
- Effect `provider-session.detach { providerSessionId, detail: reason }` with id `effect:<commandId>:provider-session.detach:<providerSessionId>`.
- Official client "stop session" detaches every session with commandIds `<commandId>:detach:<sessionId>` and reason `client-requested` (`commands.ts:919-935`).

---

## 15. `prepared-run.*` and `notification.delivery.accept`

Payloads (contracts:2877-2910):
- `prepared-run.release { commandId, threadId, runId }`
- `prepared-run.progress { commandId, threadId, runId, phase: "worktree" | "setup" }`
- `prepared-run.fail { commandId, threadId, runId, failure: OrchestrationV2ProviderFailure }`, where failure is `{ class, message (max 4096), code (max 128) | null, retryable | null, resetAt? }` (contracts:1281-1288)
- `prepared-run.retry { commandId, threadId, runId }`

Shared precondition (`preparedRunState`, Orchestrator:7757-7797): run status `preparing` (`failed` for retry), with attempt, root node, provider thread and the `"Preparing workspace"` item; else `Run ${runId} is not awaiting workspace preparation.`

- progress (7799-7834): `turn-item.updated` on the preparation item with title `Preparing worktree` or `Starting setup script`.
- release (7836-7923): `checkpoint-scope.created`, `node.updated` (scope id), preparation item `completed` with title `Workspace ready`, output `Workspace preparation completed.`, `exitCode 0`, `run.updated` `starting`; effect `provider-turn.start` with id `effect:<commandId>:provider-turn.start:<runId>`.
- fail (7925-8021): attempt failed, node failed, preparation item failed (title `Workspace preparation failed`, output = failure message, `exitCode 1`), an `error` item with the failure and `code: "workspace_preparation_failed"` (contracts:538-539), `run.updated` `failed`.
- retry (8028-8105): needs a recorded `workspacePreparation`, a failed preparation error item, and the thread not archived or deleted, else `Run ${runId} has no failed workspace preparation to retry.`; no other active run, else `Another run is active on this thread.` Events: failure item `cancelled`, preparation item back to `running` (title `Preparing workspace`, output and exit code removed), attempt `pending`, node `pending`, run `preparing`. Over WS, `ThreadLaunchService.retryPreparation` dispatches it and then reschedules preparation once per commandId, reusing an already created worktree (`o2/ThreadLaunchService.ts:909-978`).
- Server senders use commandIds `<launchCommandId>:progress:worktree`, `:progress:setup`, `:release`, `:fail`; the failure is built with class `validation_error` and `retryable: false` (`o2/ThreadLaunchService.ts:322-332`, `:471-481`, `:550-559`, `:613-647`).

`notification.delivery.accept` (contracts:2883-2889: `{ commandId, threadId, messageId }`; handler Orchestrator:10017-10113):
- When the message is not the current open delivery of its cohort (generation or messageId mismatch, cohort closed): a no-op `thread.metadata-updated` (accepted).
- Otherwise: `subagent.updated` (pending terminal tasks become `claimed`; tasks of the accepted batch go from `claimed` to `delivered`) and `run.updated` on the parent run advancing `delegatedCompletion` (`nextGeneration`, next `delivery` or `null`).
- After commit, deliveries are offered again (Orchestrator:10614-10616).
- Sent by the worker after a successful mailbox steer (`o2/EffectWorker.ts:215-233`).

---

## 16. Delegated tasks and `thread.merge_back`

### 16.1 `delegated_task.request`

Payload (contracts:3001-3017): `{ createdBy, creationSource, commandId, parentThreadId, parentRunId, parentNodeId, task: TrimmedNonEmptyString, title?, modelSelection, runtimeMode, interactionMode, completionWake?: "always" | "settled_only", createdAt? }`. Omitted `completionWake` behaves as `settled_only`.

Handler (Orchestrator:6469-6737), locked on `parentThreadId`:
- `Parent run ${id} is not active.` (parent run must be in an active status)
- `Parent run ${id} is stopping.` (Stop already reached it)
- `Parent node ${id} is not part of active run ${runId}.`
- Target adapter lookup.
- Events: `thread.created` for the child `thread:delegated-task:<commandId>` (runtime and interaction mode from the command), parent `node.updated` (kind `subagent`, running), `subagent.updated` (`origin "app_owned"`, running), parent `turn-item.updated` (type `subagent`); then a nested `message.dispatch` on the child (messageId `message:delegated-task:<commandId>`, `senderThreadId` = parent, `start_immediately`), then `context-transfer.created` (type `subagent_spawn`, status `consumed`) on the child.
- Missing child run: `Delegated child thread ${childThreadId} did not create a run.`
- Over WS, `createdBy` becomes `"user"`.

### 16.2 `delegated_task.wake-policy`

Payload (contracts:3018-3024): `{ commandId, parentThreadId, taskId: NodeId, completionWake }`.

Handler (Orchestrator:6744-6856):
- `Delegated task ${taskId} is not an app-owned task of thread ${parentThreadId}.`
- `Delegated task ${taskId} already wakes the parent with completionWake ${value}.`
- Events: `subagent.updated`; when upgrading to `always` for an already terminal task while the spawning run is live, also plan a completion delivery (`run.updated`, `message.updated`).
- After commit, offers deliveries (Orchestrator:10617-10619).

### 16.3 `delegated_task.completion-delivery.acknowledge` and `.dispose`

Payloads (contracts:3025-3037): acknowledge `{ commandId, parentThreadId, taskId, observedByRunId: RunId | null }`; dispose `{ commandId, parentThreadId, taskId }`.

Handler (Orchestrator:1904-2068):
- Not an app-owned task: same message as 16.2.
- Already in the target state (or acknowledging a disposed task): re-emit the unchanged `subagent.updated` (idempotent success).
- Else `subagent.updated` with `completionDelivery { state: "acknowledged" | "disposed", observedByRunId }`; remove the task from the parent run's pending delivery (`run.updated`); if the delivery run is still queued, either cancel it (no tasks left) or rewrite its message text and task list.
- Delivery states: `pending`, `claimed`, `acknowledged`, `delivered`, `disposed` (contracts:467-473).

### 16.4 `thread.created.record`

Payload (contracts:3038-3046): `{ commandId, parentThreadId, parentRunId, parentNodeId, targetThreadId, targetRunId: RunId | null }`.

Handler (Orchestrator:6858-6966):
- `Parent node ${id} is not the root of run ${runId}.`
- `Target thread ${id} belongs to another project.`
- `Target run ${id} does not belong to thread ${id}.`
- Emits a parent `turn-item.updated` of type `thread_created` (id `turn-item:created-thread:<commandId>`).

### 16.5 `thread.merge_back`

Payload (contracts:2992-3000): `{ createdBy, creationSource, commandId, sourceThreadId, targetThreadId, sourcePoint: { type: "latest_stable" } | { type: "run", runId } | { type: "checkpoint", checkpointId }, createdAt? }` (source point union contracts:134-138). Locked on `targetThreadId`.

Handler (Orchestrator:3582-3726):
- `Thread ${sourceThreadId} is not a fork of ${targetThreadId}.`
- `No stable source run was found for merge-back source ${type}.`
- `Merge-back source run ${id} is ${status}; only provider-finished runs are supported.` (source must be `completed` or `waiting`)
- `No fork transfer exists between ${targetThreadId} and ${sourceThreadId}.`
- Events on the target thread: older pending merge-backs from the same source become `context-transfer.updated` `superseded` (`Superseded by merge-back transfer <id>.`); `context-transfer.created` (type `merge_back`, status `pending`, `targetRunId: null`, `basePoint` = the fork's source point).
- Nothing runs yet. The next `message.dispatch` on the target consumes it through path C (fork-delta handoff); while the target has an active run that message fails with the "queued merge-back consumption is not implemented yet" error (7.6).
- Official client: `sourcePoint: { type: "run", runId }`, `creationSource` default `"web"` (`commands.ts:952-964`).

---

## 17. Effect and follow-on command reference

Effect request types (`o2/EffectOutbox.ts:30-118`): `provider-runtime.continue`, `provider-session.detach`, `provider-turn.start`, `provider-turn.interrupt`, `provider-turn.steer`, `provider-turn.restart`, `runtime-request.respond`, `provider-thread.rollback`, `checkpoint.capture`, `terminal.cleanup`, `preview.cleanup`, `attachment.cleanup`, `thread-title.generate`, `delegated-tasks.stop`. Process-bound (not replayed after a process loss): turn start, interrupt, steer, restart, and runtime-request respond (`o2/EffectOutbox.ts:121-139`).

| Command | Effect id pattern | Follow-on |
|---|---|---|
| message.dispatch (start) | `effect:<cmd>:provider-turn.start:<runId>` | provider turn starts asynchronously |
| message.dispatch (title) | `effect:<cmd>:thread-title.generate` | title regeneration |
| message.dispatch (active steer) | `effect:<cmd>:provider-turn.steer:<providerTurnId>` | if the turn ended: `message.dispatch` `command:steer-follow-up:<effectId>`; mailbox success: `notification.delivery.accept` `command:mailbox-accepted:<effectId>` |
| message.dispatch (restart) | `effect:<cmd>:provider-turn.restart:<providerTurnId>` | interrupt, wait, detach, start |
| run.interrupt (live) | `effect:<cmd>:provider-turn.interrupt:<providerTurnId>` | `thread.background-work.settle` `<effectId>:background-work-settled` |
| run.interrupt holdQueue | `effect:<cmd>:delegated-tasks.stop` | `thread.stop` `<cmd>:stop:<childThreadId>` per child |
| interrupted run (local settle) | `effect:checkpoint.capture:<runId>` | checkpoint capture |
| runtime-request.respond (live) | `effect:<cmd>:runtime-request.respond:<requestId>` | adapter response |
| checkpoint.rollback | `effect:<cmd>:provider-thread.rollback:<providerThreadId>:<checkpointId>` | on final failure `checkpoint.rollback.fail` `<cmd>:rollback-failed` |
| provider-session.detach, provider.switch | `effect:<cmd>:provider-session.detach:<sessionId>` | session detach |
| prepared-run.release | `effect:<cmd>:provider-turn.start:<runId>` | provider turn starts |
| queued run start (system) | `effect:command:system:start-queued:<runId>:provider-turn.start:<runId>` | provider turn starts |

---

## 18. UNVERIFIED items and open questions

1. JSON encoding of `Schema.Defect()` in the `cause` field of `OrchestrationV2DispatchCommandError`, and the wire shape of defects (for example the receipt "disappeared during its transaction" die) and of payload decode failures.
2. Effect RPC default request concurrency per WebSocket connection, and therefore whether un-awaited dispatches can be reordered.
3. That `Schema.TaggedError` instances are `instanceof Error` (the server's rejected-receipt text relies on it).
4. Whether the v2 provider turn start enforces the 120,000-char input limit or rejects empty text for `message.dispatch`.
5. The exact tail of derived provider thread ids (IdAllocator.ts:216-230 was only partly read).
6. Grok turn capability overrides beyond `packages/provider-grok/src/server/adapter.ts:100`; Codex `activeSteeringInterruptsTools` value; decision mapping of adapters other than Codex.
7. Whether a missing thread can fail earlier inside legacy transcript hydration (`ensureLegacyTranscript`) instead of with the projection error described in 5.4.
8. Behaviour of `checkpoint.rollback` while a run is active (no dispatch-time guard was found; the executor only rolls back runs in completed, interrupted, failed or cancelled status).
