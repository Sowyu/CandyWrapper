# I. Composer flow (send, stop, approvals, queue, model)

Port spec for milestone 5. Source: `/Users/mrm/CandyWrapper-research/t3code` (paths below are relative to it). Wire details already in `docs/protocol.md` are cited, not repeated.

## 1. Sending

Paths: `W` = `apps/web/src`, `CR` = `packages/client-runtime/src`, `C` = `packages/contracts/src`, `S` = `apps/server/src`.

### 1.1 Two send paths

The web client has two ways to start a turn. `startThreadTurn` (`CR/operations/commands.ts:626-778`) picks between them.

1. **Existing thread** (server thread with at least one message): one `orchestration.dispatchCommand` request carrying a `message.dispatch` command. Wire format and a recorded example are in `docs/protocol.md` section 7.3 (the `message.dispatch` row) and section 7.6.
2. **First send of a new thread** (a local draft, or a server thread that needs a worktree): one `orchestration.launchThread` request. The web client does NOT send `thread.create` then `message.dispatch` for this case. The server does both inside the RPC (see 1.5). The recorder in `scripts/record-transcript.swift` used the two-command form, which still works but is not what the official client does.

`thread.create` as a separate client command (`CR/operations/commands.ts:393-411`, `createThread`) is used by the "implement plan in new thread" flow (`W/components/ChatView.tsx:10563-10600`), the only caller I found in `ChatView`. A native client can skip it.

### 1.2 The send function, in order

`onSend` is `W/components/ChatView.tsx:8733-10112`. The steps a port needs, in order:

1. **Guards** (`:8770-8781`). Return silently when any of these hold: no `orchestration:operate` scope, no active thread, a local dispatch is pending (`isSendBusy`), connecting, reverting a checkpoint, settings not hydrated, thread detail still loading, an environment switch pending, `sendInFlightRef` set, or a feedback upload running.
2. **Environment disconnected** (`:8797-8809`): toast "Not connected: message not sent" and return. The text stays in the composer.
3. **Pending question open** (`:8811-8818`): `onSend` does not send a message. It advances the active question (`onAdvanceActivePendingUserInput`, `:10343`). See section 3.
4. **Queued-edit mode** (`:8903-9027`): Enter saves the edit with `queued-run.edit` instead of sending. See section 4.
5. **Content check** (`:9029-9040`, `W/components/ChatView.logic.ts:859-890`): `hasSendableContent` is true when the trimmed prompt (inline context references stripped) is non-empty, or there is at least one attachment, non-expired terminal context or element context. Otherwise return (no toast).
6. **Project check** (`:9206-9215`): draft with no project gives a warning toast "Choose a project first".
7. **Worktree rule** (`:9217-9235`): the first message in "New worktree" env mode needs a base branch, else the thread error "Select a base branch before sending in New worktree mode." (M5 can skip worktree mode and always send `workspaceStrategy: root`.)
8. **Build message text** (`:9265-9283`):
   - `messageIdForSend = newMessageId()`, a random UUID v4 (`W/lib/utils.ts:50`).
   - `text = formatOutgoingPrompt(...)` (`:806-815`). For Claude with the `ultrathink` effort selected and a model whose descriptor lists `ultrathink` in `promptInjectedValues`, the text becomes `"Ultrathink:\n" + text`, unless the text starts with a slash command token or already starts with `Ultrathink:` (`packages/shared/src/model.ts:495-529`). Otherwise the trimmed text is sent unchanged.
   - An attachment-only message sends the fixed string `[User attached one or more files without additional text. Respond using the conversation context and the attached files.]` (`W/components/chat/composerPromptHistory.ts:19-20`, used at `:9282`). M5 has no attachments, so this never fires.
9. **Length validation** (`:9284-9286` and `W/components/chat/composerSubmission.ts:12-50`). Detailed in section 7.
10. **Local dispatch flag** (`:9425`): `beginLocalDispatch()` sets the "send busy" state that disables the send button and shows a spinner. It clears when the server acknowledges (see 1.6) or the send fails.
11. **Optimistic echo** (`:9763-9784`). Push a `ChatMessage` into local state with `id = messageIdForSend`, `role: "user"`, `text` (the formatted text), `runId: null`, `createdAt = updatedAt = now`, `streaming: false`, and `inputIntent`: `"queued_turn"` when the send queues behind a running turn, `"steer"` when it steers, absent otherwise. The timeline renders optimistic messages next to server turn items (`:3923-3930`). A queued optimistic message is not scrolled into view (`:9746-9762`).
12. **Clear the composer immediately** (`:9790-9793`): prompt, attachments and contexts are cleared before the command returns. The failure path restores them (1.7).
13. **Compute titleSeed** (`:9807-9823`): `trimmed` text with inline context references stripped; if empty, `Image: <name>`, `File: <name>`, a terminal label, `Review: ...`, an annotation label, else `"New thread"`. Then `title = truncate(titleSeed)`, which trims and cuts at 50 characters, appending `...` when cut (`packages/shared/src/String.ts:1-8`). The truncated `title` is what goes on the wire as `titleSeed` (`:9949`).
14. **Persist thread settings for an existing thread** (`:9833-9848`, `persistThreadSettingsForNextTurn` at `:6267-6340`). Before the dispatch, if the composer's runtime mode differs from the thread's, send `thread.runtime-mode.set`; if the interaction mode differs, send `thread.interaction-mode.set`; if the local branch differs, send `thread.metadata.update`. These are separate `dispatchCommand` calls made in sequence, each aborting the send on failure. The model selection is NOT persisted here. It rides on the message (1.3).
15. **Dispatch** (`:9912-9955`): `startThreadTurn` with `{threadId, message:{messageId, role:"user", text, attachments, context?}, modelSelection, titleSeed: title, runtimeMode, interactionMode, dispatchMode, bootstrap?, createdAt}`.
16. **On success** (`:9981-10027`): clear keep-full-history, usage limits, acknowledge wake. On failure see 1.7.

### 1.3 `message.dispatch` fields on the wire

Schema: `C/orchestrationV2.ts:2836-2882` (cited by `docs/protocol.md` line 1003). What the web client actually puts in it (`CR/operations/commands.ts:756-773`):

| Field | Value |
|---|---|
| `type` | `"message.dispatch"` |
| `commandId` | random UUID v4 (`allocateCommandId`, `:259-266`) |
| `createdBy` | `"user"` |
| `creationSource` | `"web"` |
| `threadId`, `messageId` | thread id, the client message id from step 8 |
| `text` | formatted prompt |
| `attachments` | `[]` or persisted attachments, see 1.4 |
| `context` | only when non-empty (inline chips). Omit the key otherwise |
| `titleSeed` | present only on the first message: `shouldSendTitleSeed` is true when the server resolves command context and `titleSeed` was passed (`:751-753`). The server only honours it while the thread has zero messages (`S/orchestration-v2/Orchestrator.ts:4604-4609`); it then sets the temporary title to the seed and starts title generation. The web client passes it on every send; the server ignores it after the first message. |
| `modelSelection` | the composer's current selection, always sent (`:765`). The server compares it with the thread and emits `thread.model-selection-updated` or `thread.provider-switched` before creating the run (`S/orchestration-v2/Orchestrator.ts:5142-5165`). So a model change applies at the next send, with no separate command. |
| `sourcePlanRef` | only when sending a plan follow-up |
| `deliveryIntent` | The requested UI mode (`"auto"`, `"steer"` or `"restart"`) whenever it is not `queue` and the server declares `capabilities.serverResolvedCommandContext` (`:767-769`). Omitted for queue. See 1.3.1. |
| `dispatchMode` | see 1.3.1 |

`serverResolvedCommandContext` is `true` in the server environment capabilities (`S/environment/ServerEnvironment.ts:250`, contract `C/environment.ts:174`). A native client targeting this server version can assume it and never read the projection before sending. The older path (capability absent) fetched the thread projection and computed the mode client-side (`CR/operations/commands.ts:710-751`). Skip it.

#### 1.3.1 dispatchMode and deliveryIntent

The UI-level mode is `ComposerDispatchMode = "auto" | "queue" | "steer" | "restart"` (`CR/state/composerDispatch.ts:7-8`). With `serverResolvedCommandContext` the client maps it as follows (`CR/operations/commands.ts:733-737`, `:767-769`):

| UI mode | `dispatchMode` on the wire | `deliveryIntent` |
|---|---|---|
| `queue` | `{"type":"queue_after_active"}` | omitted |
| `auto`, `steer`, `restart` | `{"type":"start_immediately"}` | the same word: `"auto"`, `"steer"` or `"restart"` |
| `start` (internal, used for retrying a continuation) | `{"type":"start_immediately"}`, no `deliveryIntent` | none |

Careful: the code sets `deliveryIntent: requestedMode` whenever `requestedMode !== "queue"` (`:767-769`), so an ordinary idle send has `dispatchMode: start_immediately` plus `deliveryIntent: "auto"`. The server then re-resolves under the thread lock (`S/orchestration-v2/CommandPolicy.ts:119-170`):

1. `deliveryIntent` absent: use `dispatchMode` as sent.
2. No active run (`preparing`, `starting`, `running`, `waiting`): `start_immediately`.
3. `steer`: `steer_active` with `targetRunId` = the active run. `restart`: `restart_active`.
4. `auto` with an active run in `preparing` or `starting`: `queue_after_active`.
5. `auto` otherwise: provider capability `turns.supportsActiveSteering` gives `steer_active`; else `supportsQueuedMessages` gives `queue_after_active`; else `supportsSteeringByInterruptRestart` gives `restart_active`; else `queue_after_active`.
6. A `steer_active` whose target already finished (completed, or running/waiting with a completed provider turn) falls back to `start_immediately` so the text is never dropped (`S/orchestration-v2/Orchestrator.ts:4651-4668`).

Provider refusals come back as a typed `OrchestrationV2DispatchCommandError` with texts listed in `docs/protocol.md` line 956 ("cannot queue messages behind an active run", "cannot redirect an active run. Stop it first, then send the message.").

`restart` is never produced by the stock composer: `resolveComposerDispatchMode` returns only `auto`, `queue` or `steer` (`CR/state/composerDispatch.ts:13-23`). `restart_active` exists for providers that can only steer by restarting.

### 1.4 Attachments

Out of scope for M5, shape for reference. The `attachments` array holds `ChatAttachment` (`C/chatAttachment.ts:213-217`):

- image: `{type:"image", id, name, mimeType (image/*), sizeBytes, source?}` (`:149-157`)
- file: `{type:"file", id, name, mimeType, sizeBytes >= 1, source?: {_tag:"pasted-text"}}` (`:162-176`)
- unknown types decode as `{type, id, name, mimeType, sizeBytes}` (`:195-199`)

Upload flow: the client uploads bytes first, then lists `{type, id: uploadId, name, mimeType, sizeBytes}` in the command; the server claims the pending upload (`S/orchestration-v2/ThreadMessageIntake.ts:53-165`, `docs/protocol.md` line 603). Legacy servers without upload support get `dataUrl` images persisted with `assets.persistChatAttachments` first (`CR/operations/commands.ts:282-310`). Limits: 100 attachments, 120,000 characters of text (`C/chatAttachment.ts:13-14`).

### 1.5 `orchestration.launchThread` (first send of a new thread)

The client builds this request in `startThreadTurn` when `input.bootstrap` is set (`CR/operations/commands.ts:640-696`). Payload (`C/orchestrationV2.ts:3182-3203`):

| Field | Value sent by web |
|---|---|
| `commandId` | UUID v4. The server derives `<id>` for `thread.create` and `<id>:initial-message` for `message.dispatch` |
| `creationSource` | `"web"` |
| `threadId` | the draft's thread id (client-generated UUID, `newThreadId` at `W/lib/utils.ts:46`) |
| `reuseExistingThread` | `true` only when the thread already exists on the server but has no messages (worktree-prep path); omitted for a brand-new draft |
| `projectId` | the draft's project |
| `title` | `titleSeed` (truncated to 50 chars), else the thread title |
| `generateTitle` | `true` when a `titleSeed` was given. Server then sets `titleSeed: title` on the inner `message.dispatch` |
| `modelSelection` | composer selection |
| `runtimeMode`, `interactionMode` | composer values |
| `workspaceStrategy` | `{type:"worktree", baseRef, branch?, startFromOrigin?}` when preparing a worktree, `{type:"existing_worktree", worktreePath, branch?}` if the draft has a worktree path, else `{type:"root", branch?}` |
| `initialMessage` | `{messageId, text, context?, attachments}` |

Server behaviour (`S/orchestration-v2/ThreadLaunchService.ts:696-872`):

1. Reads a receipt for `commandId` so a retry is idempotent. A retried launch with no `threadId` reuses the thread id its accepted `thread.create` was recorded under (`:709-727`).
2. Dispatches `thread.create` (`:776-790`) with `branch` and `worktreePath` from the strategy (`null` when absent), or `thread.metadata.update` with `expectedEmpty: true` when `reuseExistingThread` (`:768-775`).
3. Dispatches `message.dispatch` with `commandId = <id>:initial-message`, the same `modelSelection`, `titleSeed` (if `generateTitle`) and `dispatchMode: {"type":"defer_start","workspaceStrategy": ...}` (`:811-838`). `defer_start` creates a run in `preparing` while the server prepares the workspace; a root strategy for a Scratch project can bind a managed folder (`:737-760`).
4. Result: `{threadId, projection, resumed}` (`C/orchestrationV2.ts:3205-3211`). Errors are `OrchestrationV2ThreadLaunchError {commandId, projectId, message, cause?}` (`C/orchestrationV2.ts:3423-3431`) with `operation` values like `resolve-project`, `create-thread`, `dispatch-message`, `read-receipt`.

M5 decision: use `orchestration.launchThread` for the first send with `workspaceStrategy: {"type":"root"}`. It needs fewer round trips and gets server-side idempotency. Fall back to `thread.create` then `message.dispatch` only if `launchThread` is unavailable.

Recorded in `fixtures/transcripts/05-composer.jsonl` (2026-10-10, t=1031 to 2989):

- The reply is `{threadId, projection, resumed:false}` about 70 ms after the request. Its projection already holds the thread (title = the `title` sent, `branch` and `worktreePath` null), the user message with the client's `messageId`, run 1 in `preparing` with `startedAt` null, a `user_message` turn item (`inputIntent: "turn_start"`) and a running `command_execution` item titled "Preparing workspace" (the workspace-preparation row the timeline skips).
- `orchestration.subscribeThread` for the new thread fails until the launch has returned: `OrchestrationV2GetThreadProjectionError` "Failed to load orchestration V2 thread <id>" (cause `ProjectionStoreThreadNotFoundError`). Subscribe after the reply, not alongside the request.
- The shell's `thread.updated` arrives right after the reply with status `running` and `activeRunId` run 1; the `preparing` phase was already over by then for a root strategy.
- `generateTitle:true` with the sandbox's settings logged "Thread title generation failed" on the server; the thread kept the sent `title`.

### 1.6 Confirmation by the stream

There is no ack on the command result; the result is only `{sequence}`. The UI confirms through the subscribed thread state:

- **Optimistic row removal.** An optimistic message is dropped when its id appears in `serverAcknowledgedUserMessageIds` (`W/components/ChatView.tsx:1760-1766`, effect at `:6877-6911`). That set is the union of (a) `user_message` turn items in the visible projection (`deriveCommittedServerUserMessageIds`, `W/components/ChatView.logic.ts:1213-1221`) and (b) every `role:"user"` message in `projection.messages`. Part (b) exists because a queued message gets a `message.updated` but no turn item until its run starts (`docs/protocol.md` lines 1380 and 1387). The removal runs in a zero-delay timeout, and image preview URLs are handed to the committed row.
- **Send-busy flag.** `hasServerAcknowledgedLocalDispatch` (`W/components/ChatView.logic.ts:1223-1281`) turns `isSendBusy` off when any of these happen: a pending approval or question appeared, a thread error was set, the latest user message changed while the phase is `running`, the latest run changed (id, `requestedAt`, `startedAt`, `completedAt`) once it has `startedAt` and matches `runtime.activeRunId`, or, when not running, the run or runtime status/`updatedAt` changed. While the phase is `connecting` it never acknowledges. The snapshot for comparison is taken at `beginLocalDispatch` (`createLocalDispatchSnapshot`, `:1183-1205`).
- **Thread switch** drops every optimistic message and the dispatch flag (`W/components/ChatView.tsx:6915-6923`).

For the Swift port: keep an `optimisticMessages` array per thread keyed by message id, drop an entry the moment `projection.messages` (or a `user_message` turn item) contains that id, and drop all on a thread switch.

### 1.7 Errors and retry

- I found no automatic retry in `onSend` or in `CR/operations/commands.ts`, and no retry button. The user presses send again and gets fresh ids. If you add a retry, reuse the original `commandId` (`docs/protocol.md` line 1404).
- On failure (`W/components/ChatView.tsx:10029-10112`):
  1. If the composer is still empty (no prompt, attachments or contexts typed since), remove the optimistic message and put the text, attachments and contexts back into the composer (`:10043-10084`). If the user already typed something new, the failed text is dropped (no restore).
  2. Unless the failure is an interrupt (`isAtomCommandInterrupted`), set the thread error to the error message, or `"Failed to send message."`, via `setThreadError` (`:10086-10090`). Transport errors (SocketCloseError, "is not connected", ping timeout, `RpcClientError`, `ClientProtocolError`) are replaced by `null` so no banner shows (`CR/errors/transport.ts:5-46`). The user sees the connection state instead.
  3. `sendInFlightRef` clears and the local dispatch flag resets (`:10105-10112`).
- Server errors seen here are `OrchestrationV2DispatchCommandError` (`message`, `detail`, `cause`) or `OrchestrationV2ThreadLaunchError`. Show `message`. A payload that fails schema decoding comes back as a `Die` (`docs/protocol.md` line 956).
- Commands are idempotent per `commandId` on the server (receipts, `S/orchestration-v2/ThreadLaunchService.ts:706`), which is why the launch path derives child ids from the parent `commandId`.
- A user message sent while the shell shows an archived thread fails with `Thread <id> is archived.` (`docs/protocol.md` line 956).

## 2. Stop

### 2.1 The command

Stop sends exactly one command: `run.interrupt` (`CR/operations/commands.ts:780-832`):

```json
{"type":"run.interrupt","commandId":"<uuid>","threadId":"<thread>","runId":"<run id>","holdQueue":true}
```

- `runId` is chosen as follows (`:785-806`). The web composer calls `interruptThreadTurn({threadId})` with no run id (`W/components/ChatView.tsx:4579-4596`), so the helper fetches the thread projection (`orchestration.getThreadProjection`) and takes the LAST run whose status is `preparing`, `starting`, `running` or `waiting`. In a native client the shell already carries `activeRunId`; send that instead and skip the fetch. The shell field is the newest run in `preparing`, `starting` or `running` (`INTERRUPTIBLE_RUN_STATUSES`, `CR/state/threadExecution.ts:36`, `activeRunId` at `:257-258`). `waiting` is deliberately not interruptible from the shell, but the helper's projection lookup does include it.
- If no active run exists but the latest run still has pending background work (`derivePendingBackgroundWork`), the helper targets that latest run. This is how the "Stop" button on the background-work banner works (`W/components/ChatView.tsx:7388-7408`, 7585-7595).
- If neither exists, the helper sends `thread.pull-request.watch` with `watching:false` for each watched PR link, and returns. M5 can skip it.
- `holdQueue: true` is always set by Stop (`:830`). Effects on the server (`S/orchestration-v2/Orchestrator.ts:8475-8535`, `:10291-10307`): queued runs not already held get `queueHeld: true`; PR watches end; delegated tasks under the thread are stopped (`delegated-tasks.stop` effect). Queued items stay in the queue, shown as held; the user resumes with `queue.resume` (section 4.8).
- `reason` is optional and the web client never sends it. The server uses `reason ?? "Interrupt requested"` as the request item's `message` (`S/orchestration-v2/Orchestrator.ts:8706-8725`).
- `thread.stop` also exists but is an internal command (`C/orchestrationV2.ts:3105-3115`, `OrchestrationV2InternalCommand`). Clients cannot send it. Use `run.interrupt`.

Errors: `Run <id> is not interruptible.` when the run is missing, has no root node, or has no provider thread (`Orchestrator.ts:8697-8703`). Recorded in `docs/protocol.md` lines 228-236. The web composer shows it as a thread error (`ChatView.tsx:4585-4595`, fallback text "Failed to interrupt the current turn."). Only offer Stop while it can succeed.

### 2.2 When the Stop button shows

`deriveCanInterruptRunningThread(hasActiveThread, runtime)` (`W/session-logic.ts:1087-1095`) is true when `derivePhase(runtime) === "running"` or `threadRuntimeHasInterruptibleRun(runtime)` (`CR/state/threadExecution.ts:280-288`: runtime status active AND `activeRunId != null`). `derivePhase` (`W/session-logic.ts:1069-1079`): `null` runtime is `disconnected`; `preparing`, `starting`, `queued` are `connecting`; `running`, `waiting` are `running`; anything else is `ready`. The comment at `:1081-1086` states why: the server settles a preparing/starting run on `run.interrupt`, so Stop must not wait for `running`. A thread whose latest run is `queued` offers Stop only while an earlier run is still interruptible.

`ChatView` passes `canInterruptRunningThread = canOperateThread && deriveCanInterruptRunningThread(...)` (`ChatView.tsx:4577-4578`) as `canInterrupt`.

`ComposerPrimaryActions` renders the red circular Stop button (`aria-label "Stop generation"`, tooltip "Interrupt", 12x12 filled rounded square, `W/components/chat/ComposerPrimaryActions.tsx:134-159`) when `canInterrupt && !hasSendableContent && !isEditingQueuedMessage` (`:267-269`). As soon as the draft has text or attachments the Stop button is replaced by the send button, which then reads "Steer message" or "Queue message" (`:279-289`). While a question panel is open, Stop sits next to the Submit button (`:161-165`). The button is disabled when `!canOperateThread` (`:140`).

Keyboard: the command `thread.stop` interrupts the focused thread (`ChatView.tsx:8243-8252`). It has no default binding (`docs/user/keybindings.md:140`; absent from `packages/shared/src/keybindings.ts`). It ignores key repeat and does nothing when Stop is unavailable, so Escape still closes dialogs. No Escape-to-stop default exists.

### 2.3 What the UI shows while stopping

The web client adds no local "stopping" state for the composer Stop button. Pressing it fires the command and waits for the stream. The Stop button stays until the run leaves the interruptible statuses. The only local spinner is on the background-work banner button, which shows "Stopping..." until the command returns (`ChatView.tsx:7384-7398`, `:7591-7594`). A port can add an optimistic "Stopping..." state without conflicting with the web behavior.

### 2.4 How the stream reports it

Sequence recorded in `docs/protocol.md` lines 1359-1366 (`02-turn` t=128602 to 129136):

1. `turn-item.updated` `type:"run_interrupt_request"`, `title:"Interrupt requested"`, `status:"completed"`, `message` = `reason` or `"Interrupt requested"`. Id `turn-item:run:<runId>:signal:interrupt-request` (built at `Orchestrator.ts:8706-8725`).
2. `provider-turn.updated` `interrupted`, `provider-thread.updated` idle.
3. `run-attempt.updated` `interrupted`, `turn-item.updated` `type:"run_interrupt_result"` (`title:"Interrupted"`, `message:"Run interrupted by user"`, `status:"interrupted"`), `run.updated` `interrupted`, `node.updated` `interrupted`.
4. `checkpoint.captured`, final `run.updated`.

Rendering (`W/components/chat/MessagesTimeline.logic.ts:1528-1537`, `V2LifecycleRow.tsx:77-105`): the `run_interrupt_request` row is dropped from the timeline once a result exists ("transient bookkeeping and duplicates that marker"); the `run_interrupt_result` row renders as a divider labelled "Run interrupted" with the item's `message` as detail, danger tone, X icon. A run that has either item is treated as interrupted when folding turns (`:970-980`).

Shell status after stop: the thread status maps `interrupted` and `cancelled` to ready (`docs/protocol.md` line 1245). With `holdQueue` the shell can show `queued` items held; see section 4.

## 3. Approvals and questions

Both approvals and questions are `runtimeRequests` on the thread projection. Both are answered with `runtime-request.respond`. A third command, `thread.user-input.dismiss`, closes a question without an answer.

### 3.1 Where pending requests come from

`derivePendingThreadRequests(projection)` (`CR/state/threadRequests.ts:66-115`):

1. Iterate `projection.runtimeRequests` and keep `status === "pending"` (`:73`). Statuses: `pending`, `resolved`, `expired`, `cancelled` (`C/orchestrationV2.ts:1025-1045`).
2. `kind === "user_input"` becomes a question. It needs the matching turn item: the LAST `turnItems` entry with `type === "user_input_request"` and the same `requestId`; no item means the request is skipped (`:75-80`).
3. `kind` of `auth_refresh` or `dynamic_tool_call` is skipped. These are not approvals the user can answer in the composer (`:97`).
4. Every other kind is an approval. Request kinds (`ProviderRequestKind`, `C/providerPolicy.ts:38-44`): `command`, `file-read`, `file-change`, `mcp-elicitation`, `permission`. Display data comes from the LAST `approval_request` turn item with the same `requestId` (`:98-111`): `prompt` (the command line, file path or description), `appName` (MCP elicitation only), `options` (provider-advertised choices).
5. `responseCapability.type`: `live` means answerable now; `message` means the answer is sent back as a new user message (questions only); `not_resumable` means the provider process is gone. Approvals map anything not `live` to `"not_resumable"` (`:110`).
6. Sort both lists oldest first by `createdAt` (`W/session-logic.ts:249-259`). The composer shows only element 0 (`ChatView.tsx:3310`, `:3474`). A count badge `1/N` shows when more are pending (`ComposerPendingApprovalPanel.tsx:56-58`).

The shell also exposes `hasPendingApprovals`, `hasPendingUserInput` (`CR/state/models.ts:108-109`) and `pendingRuntimeRequest:{createdAt,id,kind}` for the sidebar (`docs/protocol.md` line 1245). A recorded approval: `docs/protocol.md` lines 1307-1325 and `fixtures/transcripts/03-turn2.jsonl`.

Recorded `runtime-request.updated` payload (fixture line 63): `{id, nodeId, providerTurnId, nativeRequestRef:{driver,nativeId,strength}, kind:"file-change", status:"pending", responseCapability:{type:"live", providerSessionId}, createdAt, resolvedAt:null}` and the matching `turn-item.updated` `{type:"approval_request", requestKind:"file-change", prompt:"hello.py", status:"waiting"}`. Claude sent no `options`, so the client used the defaults below.

### 3.2 Approval decisions

`ProviderApprovalDecision` (`C/providerPolicy.ts:50-56`): `accept`, `acceptForSession`, `acceptAlways`, `decline`, `cancel`.

The web client's defaults when the item has no `options` (`ComposerPendingApprovalActions.tsx:25-30`):

| decision | label |
|---|---|
| `cancel` | Cancel |
| `decline` | Decline |
| `acceptForSession` | Always allow this session |
| `accept` | Approve |

Layout (`:33-115`): `decline` and `accept` are the two visible buttons (accept is the filled one, decline is outlined, order follows the options array). Every other option goes into an ellipsis menu ("More approval options"), so by default `cancel` and `acceptForSession` live in the menu. A provider can supply its own `options: [{decision, label, warning?}]`; use the labels as given. `warning` shows a warning triangle and tooltip, and is the accessibility description. `acceptAlways` appears only when a provider advertises it (Codex MCP elicitation, `S/provider/CodexMcpElicitation.ts:60-142`). All buttons are disabled when `disabled`, `isResponding` or `!canRespond` (`responseCapability !== "live"`).

Semantics seen on the server: `decline` and `cancel` mark the request node `cancelled`; every other decision marks it `completed` (`S/orchestration-v2/Orchestrator.ts:7117-7120`). `accept` maps to a one-time allow, `acceptForSession` to a session or permanent allow in the adapters (`S/orchestration-v2/Adapters/ClaudeAdapterV2.ts:2259-2266`, `CodexAdapterV2.ts:567-599`).

Panel text (`ComposerPendingApprovalPanel.tsx:15-31`): label by `requestKind`: `command` "Command approval", `file-read` "File read approval", `file-change` "File change approval", `permission` "App permission approval", `mcp-elicitation` "App access approval". The detail line shows `approval.detail || label`, in a monospace code block except for `mcp-elicitation` (prose). If `responseCapability === "not_resumable"` it shows "Provider process is gone — interrupt or restart the run to respond." The composer's editor is disabled with placeholder "Resolve this approval request to continue" (`ChatComposer.tsx:7482-7484`, `:7503-7508`).

There are no keyboard shortcuts for approvals in the web client (grep of `ComposerPendingApprovalActions.tsx` and the keybinding defaults finds none). A native client may add some; none would conflict.

### 3.3 Responding to an approval

Command (`CR/operations/commands.ts:834-844`):

```json
{"type":"runtime-request.respond","commandId":"<uuid>","threadId":"<thread>","requestId":"<runtime request id>","decision":"accept"}
```

Recorded: `docs/protocol.md` line 1317. Client rules (`ChatView.tsx:10114-10146`):

1. Return unless the approval's `responseCapability` is `live`.
2. Add the request id to `respondingRequestIds` (disables the buttons).
3. Send. On failure (not an interrupt) set the thread error to the message or "Failed to submit approval decision."
4. Remove the id from `respondingRequestIds` when the call returns, success or not. The approval row disappears because the stream flips the request to `resolved`, not because of the call result.

Server checks (`S/orchestration-v2/Orchestrator.ts:7061-7105`): request must exist ("Runtime request <id> was not found."), be `pending` ("Runtime request <id> is resolved."), not be `not_resumable` (error is the stored reason), and its provider session must exist.

What the stream sends back (recorded, `03-turn2` t=10938 to 13673): the command returns `{sequence}` first (t=10942), then `runtime-request.updated` (`status:"resolved"`, `decision:"accept"`, `resolvedAt`), `node.updated` (completed), and `turn-item.updated` for the `approval_request` item (`status:"completed"`). Then the run continues with its next `provider-turn`/`turn-item` events. A second approval in the same turn arrives as another pending `runtime-request.updated` (t=10953) and the client shows it next, with the count badge.

### 3.4 Questions

A question is a `user_input_request` turn item: `{requestId, questions: UserInputQuestion[], responseMode?: "message", questionAnswer?}` (`C/orchestrationV2.ts:1418-1425`). Each question (`:1151-1166`):

| Field | Meaning |
|---|---|
| `id` | key for the answer |
| `header` | short title for the banner row |
| `question` | the text |
| `options[]` | `{label, description, value?}`. The option's identity is `value ?? label` |
| `multiSelect?` | default false |
| `allowCustomAnswer?` | `false` means choice-only. Default true |
| `initialAnswer?` | editable pre-filled text; makes the answer "literal" |
| `required?` | the web UI ignores it; the server uses it only for `message` responses (below) |

`dismissible` is true when `responseMode === "message"` or `responseCapability.type === "message"` (`threadRequests.ts:89`). Only message-mode questions can be dismissed.

#### Answer model (`W/pendingUserInput.ts`)

Per-question draft: `{selectedOptionValues?: string[], customAnswer?: string, attachmentCount?, attachmentsBlocked?}`. The resolved answer for one question (`resolvePendingUserInputAnswer`, `:42-72`):

1. If `attachmentsBlocked`: no answer (null).
2. Custom answer: null when `allowCustomAnswer === false`. When the question has `initialAnswer`, the draft text is used exactly, whitespace and empty string included. Otherwise the draft is trimmed and an empty result is null.
3. If the custom answer is non-empty it WINS over selected options.
4. Else selected options, restricted to values that exist in `options`. Multi-select returns the string array (null when empty); single-select returns the first value.
5. Fallback: empty string `""` when custom answers are allowed and at least one file is attached; otherwise null.

The wire `answers` object is `{ [questionId]: string | string[] }`, built only when EVERY question resolves (`buildPendingUserInputAnswers`, `:137-152`; null otherwise). Schema is `Record<string, unknown>` (`C/providerPolicy.ts:67`). Draft helpers: toggling a multi-select option adds or removes the value and clears the custom text; selecting in single-select replaces the selection and clears custom text (`togglePendingUserInputOptionSelection`, `:112-135`). Typing custom text clears selected options unless the question has `initialAnswer` (`setPendingUserInputCustomAnswer`, `:74-88`). When an option is picked while custom text exists, the custom text is moved back into the normal thread draft separated by a blank line (`carryDisplacedCustomAnswerIntoPrompt`, `:98-110`, used at `ChatView.tsx:10253-10270`).

`seedUserInputDraftAnswers` pre-fills `customAnswer` from `initialAnswer` once per question when custom answers are allowed (`threadRequests.ts:45-63`, called at `ChatView.tsx:3318-3329`).

#### Progress and UI flow

`derivePendingUserInputProgress(questions, drafts, index)` (`:176-208`) gives `questionIndex` (clamped), `activeQuestion`, `resolvedAnswer`, `answeredQuestionCount`, `isLastQuestion`, `isComplete` (all questions resolve), `canAdvance` (active question resolves).

UI (`ComposerPendingUserInputPanel.tsx`):

- Banner row shows `header`, an `i/N` counter when N > 1, a collapse toggle, and a dismiss X if `dismissible`. Collapsing hides the options and number keys (`:89-90`, `:158`). The card is keyed by request id, so a new request starts expanded.
- Body shows the question text, "Select one or more options." for multi-select, and one button per option with its `description` (only when different from the label). The first 9 options show a numbered key hint (`:262`, `:282-288`).
- Single-select: clicking an option selects it, then 200 ms later calls `onAdvance` (`:140-148`). `onAdvance` moves to the next question, or, on the last question, SENDS the response if all answers resolve (`ChatView.tsx:10343-10358`). So picking an option on the last question submits immediately.
- Multi-select: clicking toggles in place; the user must press Submit or Next (`:136-139`).
- Footer button label (`ComposerPrimaryActions.tsx:60-73`): "Submitting..." while responding; "Next question" (compact "Next") when not last; "Submit answers" (index > 0) or "Submit answer" (compact "Submit") on the last. Disabled unless `canAdvance` (not last) or `isComplete` (last), and not responding. A "Previous" button (compact: chevron) shows when `questionIndex > 0`.
- The composer text field becomes the custom answer: value is `activePendingProgress.customAnswer`; placeholder "Type your own answer, or leave this blank to use the selected option", or "Choose an option above" with the editor disabled when `allowCustomAnswer === false` (`ChatComposer.tsx:7482-7509`). With `initialAnswer` the field is literal text (no rich text, no `@` or `/` menus, `isLiteralPendingAnswer`, `:1811`).
- Pressing Enter in the composer while a question is open does not send a message. `submitComposer` uses submission target `pending-user-input` (skips the length check) and `onSend` calls `onAdvanceActivePendingUserInput` (`ChatView.tsx:8811-8818`).

#### Number-key shortcuts (1 to 9)

A document-level `keydown` listener (`ComposerPendingUserInputPanel.tsx:157-182`):

1. Active only when a question is shown, the response is not disabled (not responding, thread operable, `responseCapability !== "not_resumable"`) and the card is not collapsed.
2. Ignored if Cmd, Ctrl or Alt is held.
3. Ignored when focus is in an `input`, `textarea` or a `contenteditable` element, so typing a custom answer is safe.
4. Key `1` to `9` selects option index `digit - 1` if it exists; `preventDefault`. Uses the same handler as a click (multi-select toggles, single-select selects and auto-advances).

#### Sending the answers

`onRespondToUserInput` (`ChatView.tsx:10148-10208`):

```json
{"type":"runtime-request.respond","commandId":"<uuid>","threadId":"<thread>","requestId":"<id>","answers":{"<questionId>":"<value>" or ["<v1>","<v2>"]},"attachmentsByQuestionId":{"<questionId>":[ChatAttachment...]}}
```

`decision` is absent and `attachmentsByQuestionId` is present only when files were attached (`CR/operations/commands.ts:846-859`). Guards: the request must exist and not be `not_resumable`; a per-request in-flight set prevents double submit (`:10157-10159`). Failure shows the thread error, default text "Failed to submit user input."

File answers (out of scope for M5): each question has its own attachment draft keyed by `questionAttachmentDraftId(env, thread, request, question)`. Files upload first; the command carries the uploaded `ChatImageAttachment`/`ChatFileAttachment` list per question, max 100 across one response (`C/providerPolicy.ts:70-76`, `docs/user/question-attachments.md`). Skip in M5; send `answers` only.

Server behavior (`S/orchestration-v2/Orchestrator.ts:7107-7287`):

1. Marks the request `resolved` with `answers`, the node `completed`, and the `user_input_request` item `completed` with `questionAnswer:{requestId, answers, attachmentsByQuestionId, questionTextById}` (`:7170-7190`). The timeline renders the answered state from `questionAnswer`.
2. For `live` requests the answer goes to the provider session and the paused turn continues.
3. For `message` capability requests (the provider cannot take a live answer) the server turns the answers into a normal user message and dispatches it in the same transaction (`:7191-7287`). Each answer must be a non-empty string, else the error "Answer each question before sending." (unless `required === false`), and at least one reply must exist ("Enter an answer before sending."). The reply text is `"<question>\n<answer>"` per question. Dispatch mode is `steer_active` if the running provider supports steering, else `queue_after_active`. Multi-select arrays are not valid here.

#### Dismiss

`thread.user-input.dismiss {commandId, threadId, requestId}` (`CR/operations/commands.ts:861-870`, `ChatView.tsx:10210-10230`). Server rule (`Orchestrator.ts:7290-7326`): allowed only for `kind === "user_input"` with `message` capability; it runs the respond path with `decision:"cancel"`. Errors: "This question has already been answered." and "This question needs an answer. Answer it or stop the turn."

### 3.5 What happens after answering

- Pending lists are derived, so the banner disappears when the request status leaves `pending`. Local draft answers stay in memory keyed by request until the thread view goes away.
- The local-dispatch flag is also cleared when a pending approval or question appears (`ChatView.logic.ts:1236-1238`), so a send that triggers an approval stops spinning.
- With an approval pending the composer is disabled, so the user cannot send a message past it. A running turn that waits for an approval keeps the thread in `running`/`waiting`, and the shell shows `pendingRuntimeRequest`.
- Stop stays available while an approval or question is pending. With a question open, the Stop button renders next to Submit (`ComposerPrimaryActions.tsx:161-165`). With an approval open, the footer passes `pendingAction: null` and the normal rule applies, so an empty draft shows Stop (`ChatComposer.tsx:7627-7631`, `ComposerPrimaryActions.tsx:267-269`). The recovery service marks leftover requests `expired` at startup and `cancelled` otherwise (`S/orchestration-v2/ProviderRuntimeRecoveryService.ts:310`). I did not trace what `run.interrupt` does to an open request.

## 4. Queue and steer

### 4.1 Vocabulary

- **Queue**: the message becomes a `Run` with `status:"queued"` and a `queuePosition`. It starts after the active run ends. Wire: `dispatchMode:{"type":"queue_after_active"}`.
- **Steer**: the message is injected into the running turn. Wire: `deliveryIntent:"steer"` (server resolves to `steer_active` with `targetRunId`).
- **Restart**: interrupt and restart the turn with the new message, for providers that cannot steer natively. The stock UI never asks for it (1.3.1).
- Provider capability flags decide what works (`C/orchestrationV2.ts:211-224`): `supportsActiveSteering`, `supportsSteeringByInterruptRestart`, `supportsQueuedMessages`. The recorded Claude session has `supportsActiveSteering: true`, `supportsQueuedMessages: true`, `supportsSteeringByInterruptRestart: false`, `activeSteeringInterruptsTools: true` (`fixtures/transcripts/03-turn2.jsonl` line 27, `projection.providerSessions[].capabilities.turns`). Read these from the projection's `providerSessions`.

### 4.2 Which action a send performs

Settings (`C/settings.ts:455-460`): `sendShortcut` (`enter` default) and `followUpBehavior`: `"queue"` or `"steer"`, decoding default `"queue"`. The setting is per client, stored in client settings (not on the thread). Settings UI: Settings, General, Follow-up behavior (`W/components/settings/SettingsPanels.tsx:2850-2875`).

`resolveComposerDispatchMode({running, alternateModifier, activeTurnDefault})` (`CR/state/composerDispatch.ts:13-23`):

1. `running` false: `"auto"` (a normal start; see 1.3.1).
2. `running` true and no modifier: the default action (`"steer"` if the parameter is missing, else the setting).
3. `running` true with the alternate modifier: the opposite (`queue` becomes `steer`, `steer` becomes `queue`; a `restart` default flips to `queue`).

`running` is `phase === "running"` (`ChatComposer.tsx:4261-4264`), meaning runtime status `running` or `waiting` (`W/session-logic.ts:1077`). While the run is `preparing`, `starting` or `queued` (`phase === "connecting"`) the mode is `auto`, and the server turns that into `queue_after_active` (`CommandPolicy.ts:141-143`).

Alternate modifier sources (web):

- Mouse: Cmd or Ctrl held while clicking the send button (`ChatComposer.tsx:4289-4299`).
- Keyboard: the command `composer.sendAlternate`, default binding `mod+enter` when `composerFocus && turnRunning` (`packages/shared/src/keybindings.ts:154`). `composerSubmissionIntentForKey` returns `"alternate"` only while a turn is running (`W/composer-logic.ts:60`). Then `submitComposer` calls the resolver with `alternateModifier: submissionIntent === "alternate"` (`ChatComposer.tsx:4491-4500`).
- On an idle thread `mod+enter` is not `sendAlternate`; on a draft route it is `composer.sendBackground` (`:155-159`). Skip background sends in M5.
- Plain Enter sends in `sendShortcut: "enter"` mode. With `mod-enter` or `mod-enter-multiline` plain Enter inserts a newline and Cmd/Ctrl+Enter sends (`composer-logic.ts:29-37`, `:65-70`; section 7).
- Send button label and icon (`ComposerPrimaryActions.tsx:121-128`, `:279-308`, `:336-343`): while running, the icon is a list-plus (queue) or a corner-up-right arrow (steer), updated live as Cmd/Ctrl is held (`useShortcutModifierState`). aria-label: "Queue message" or "Steer message". Tooltip: `Click to <default>, Ctrl/⌘-click or <shortcut> to <alternate>`.
- With an empty draft while running the button is Stop instead (section 2.2).

### 4.3 What the client sends

| Action | Command |
|---|---|
| Queue | `message.dispatch` with `dispatchMode:{"type":"queue_after_active"}`, no `deliveryIntent` |
| Steer | `message.dispatch` with `dispatchMode:{"type":"start_immediately"}` and `deliveryIntent:"steer"` |

Everything else in the command is the same as a normal send (section 1.3). The optimistic row gets `inputIntent:"queued_turn"` for a queue (and is shown in the queue strip, not the timeline) or `inputIntent:"steer"` for a steer (shown in the timeline at once) (`ChatView.tsx:9274-9276`, `:9777-9780`). The model selection and `titleSeed` fields apply as usual.

Note the web only treats a send as "queued" locally when `phase === "running" && dispatchMode === "queue"` (or when compacting first). A queue-mode send while `connecting` still dispatches `auto` (not `queue`) and renders as a normal send.

Errors you can get back (capability texts, `docs/protocol.md` line 956): "`<Provider>` cannot queue messages behind an active run.", "`<Provider>` cannot redirect an active run. Stop it first, then send the message." Other server refusals for steer (`S/orchestration-v2/Orchestrator.ts:3764-3837`): `/compact`, sign-out and `/goal` commands "must run as a separate turn. Queue it or wait for the active turn to finish."; "Target run <id> is <status> and cannot be steered."; "No running provider turn found for active run <id>."; "Wait for context compaction to finish before steering the thread."

### 4.4 What the stream sends back

Queue (recorded, `docs/protocol.md` lines 1374-1387, `02-turn` t=125820 to 125891):

1. `run.created` for the next ordinal with `status:"queued"`, `queuePosition:1`, `userMessageId`; plus the attempt (`pending`), root node (`pending`) and checkpoint scope.
2. `message.updated` for the queued message. No `user_message` turn item yet.
3. Shell `thread.updated`: `status:"queued"`, `activeRunId` = the running run.

The queued message appears in the timeline only when its run starts (visibility rules, `docs/protocol.md` line 1226). When the active run finishes and the queue is not held, the queued run goes `starting`, then `running`, and its `user_message` turn item appears with `inputIntent:"queued_turn"`. I did not find a recording of the drain; see `S/orchestration-v2/Orchestrator.ts` for the scheduler if needed.

Steer: the server immediately emits `message.updated` and a `turn-item.updated` of `type:"user_message"` with `inputIntent:"steer"`, `status:"completed"`, attached to the active run and node (`Orchestrator.ts:3930-3965`). Steer was never recorded on the wire by `scripts/record-transcript.swift`; record one against the sandbox (a long-running prompt plus a second send with `deliveryIntent:"steer"`) before relying on timing. If the target run already finished by the time the command lands, the server starts a new turn instead (`:4651-4668`). A steer with a different model selection saves that selection for the next turn; if the provider cannot apply it live and supports interrupt-restart, the server restarts the run (`:3978-4010`).

### 4.5 Queue state derivation (what the strip shows)

`deriveThreadQueueWorkflowState(projection)` (`CR/state/threadWorkflows.ts:127-163`):

- `activeRun`: last run with status `preparing`, `starting`, `running` or `waiting` (`:39-41`).
- `queuedRuns`: runs with `status === "queued"`, excluding runs whose user message has `delegatedCompletion` or `notification` (automatic deliveries, `:111-125`), sorted by `(queuePosition ?? ordinal)` then `ordinal` (`:137-141`). Text is the message with `id == run.userMessageId` (`"Queued message"` if missing); attachments and context come from the same message.
- `isHeld`: any queued run has `queueHeld === true` (`:156`).
- `canReorder`: provider `turns.supportsQueuedMessages` (`:157`).
- `canPromoteToSteer`: `activeRun.status === "running"` AND a provider turn of the active attempt has `status === "running"` AND (`supportsActiveSteering` OR `supportsSteeringByInterruptRestart`) (`:131-135`, `:158-161`).

Strip (`W/components/chat/QueuedRunsControl.tsx`): a collapsible "Queued" region with a count, hidden when there are no items (`QueuedRunsControl.tsx:232`). Rows come from server queued runs plus optimistic queued messages not yet in `projection.messages` (`:130-132`, shown with a clock icon "Saving queued message", all row actions disabled because `runId` is null). Row text is the message text with inline context references replaced by their labels (`:275-277`). The list scrolls at 8rem.

### 4.6 Queue actions

All are `orchestration.dispatchCommand` calls (`CR/operations/commands.ts:966-1013`) and need `orchestration:operate`. While one is in flight the whole strip is busy (`busyRunId`) and other actions are disabled (`QueuedRunsControl.tsx:75`, `:168-206`, `:234-244`).

| Action | Command | Notes |
|---|---|---|
| Cancel (X, "Remove from queue") | `queued-run.cancel {threadId, runId}` | Server (`Orchestrator.ts:7559-7650`) sets the run `cancelled`, `queuePosition:null`, `completedAt`, cancels attempt and root node. Errors: "Run <id> is not queued." Recorded `02-turn` t=127087 (`docs/protocol.md` line 1382-1384). Cancelling an automatic delegated-completion delivery disposes the whole cohort instead. |
| Reorder | `queued-run.reorder {threadId, runId, beforeRunId: RunId|null}` | `beforeRunId:null` moves to the end. The server rebuilds the order (automatic deliveries stay first), then emits `run.updated` with the new `queuePosition` for every run whose position changed (`Orchestrator.ts:7468-7558`). Errors: "Run <id> is not queued.", "Queue target <id> is not queued.", "Automatic completion deliveries cannot be reordered.", "Queued messages cannot be reordered ahead of automatic completion delivery." |
| Steer now (button "Steer") | `queued-message.promote-to-steer {threadId, queuedRunId, targetRunId}` | `targetRunId` is `activeRun.id`. Disabled unless `canPromoteToSteer`. Server (`Orchestrator.ts:7328-7466`) cancels the queued run (same three events as cancel), then steers the SAME message (same `messageId` and text, attachments, context) into the target run. The new `user_message` turn item has `inputIntent:"promoted_queued_to_steer"`. Errors: "Queued run <id> is not queued.", "Automatic completion deliveries cannot be promoted to Steer." |
| Edit text | `queued-run.edit {threadId, runId, text, attachments?, context?}` | Server (`Orchestrator.ts:7653-7770`) rejects empty text ("cannot be edited to an empty message."), non-queued runs, and automatic deliveries. It emits `message.updated` and, if a `user_message` turn item exists, `turn-item.updated`, with the new text. `attachments` is a full replacement list; omit to keep them. The web sends the attachment-only placeholder prompt when text is empty and attachments exist (`ChatView.tsx:8970`). |
| Resume queue | `queue.resume {threadId}` | Clears `queueHeld` on every queued run (`Orchestrator.ts:10314-10369`). Errors: "Thread <id> is not active.", "Continue the limited thread before resuming its queue." (usage limit). |

Reorder gestures (`QueuedRunsControl.tsx`):

- Drag a row by its grip. The insert position is the half of the row under the pointer; `beforeRunId = queued[insertIndex]?.run.id ?? null`. A drop at its own position or directly after itself is a no-op (`QueuedRunsControl.tsx:180-190`).
- With the grip focused: ArrowUp moves before the previous row (`queued[i-1]`); ArrowDown moves before the row two below (`queued[i+2]`, null when moving to the end) (`:350-359`).
- Grip shows only when `canReorder`.

Keyboard (defaults, `packages/shared/src/keybindings.ts:152-153`): `mod+shift+enter` is `thread.steerQueuedMessage`, active when `!terminalFocus`; it promotes the FIRST queued run (`steerNext`, `QueuedRunsControl.tsx:208-214`) and swallows the key even on repeat. Ignored on draft routes (`ChatView.tsx:8224-8231`). `alt+arrowup` is `thread.editQueuedMessage` when `composerFocus` and the caret is at the start; it opens the LAST queued run for editing and declines while an edit is open or a command is busy (`:216-231`, `ChatView.tsx:8232-8241`).

### 4.7 Editing a queued message in the composer

1. `beginEditingQueuedRun` (`ChatView.tsx:4673-4699`) clears a separate draft slot `queued-edit:<threadKey>:<runId>` (`:1685-1688`), puts the message text in it, and records `{threadId, runId, messageId, originalText, existingAttachments, context}`. The composer's draft target switches to that slot while editing (`:1691-1694`), so the normal draft is untouched.
2. The queue row is highlighted and shows "Cancel" instead of edit/steer/remove. Cancel clears the slot and restores the normal draft (`cancelEditingQueuedRun`, `:4703-4712`).
3. The send button becomes a check ("Update queued message", `ComposerPrimaryActions.tsx:121-122`, `:340`) and stays the check even while a run is active (`isQueuing` is false while editing).
4. Enter saves: `onSend` takes the edit branch, sends `queued-run.edit`, and on success clears the slot (`ChatView.tsx:8903-9027`). Failure sets the thread error "Could not save the edited queued message." and keeps the edit open. Saving needs non-empty text or at least one attachment.
5. If the run leaves `queued` (it started, or another client cancelled it), an effect ends the edit (`:4730-4770`): unsaved changes move to the normal draft when it is empty ("Queued message is no longer queued. Your unsaved edit was kept in the composer."), else they are dropped with a warning toast ("Your unsaved edit was discarded."). Logic in `W/components/chat/queuedMessageEdit.ts:10-24`.

### 4.8 Stop, hold and resume

Stop sends `holdQueue:true`, so every queued run gets `queueHeld:true` (section 2.1). Nothing is auto-cancelled and nothing drains. `ChatView` computes `hasHeldQueuedRuns` (`:2143-2146`) and shows a Resume button in an empty composer when `resumableRunId !== null || hasHeldQueuedRuns` (`ChatView.tsx:11616`, `ChatComposer.tsx:3016`, `ComposerPrimaryActions.tsx:271`; aria-label "Resume thread", play icon). `onResume` (`ChatView.tsx:8656-8730`):

1. `resumableRunId` is the latest executed run (not queued, skipping runs cancelled before they started, `packages/shared/src/orchestrationV2ThreadError.ts:51-61`) if its status is `interrupted`, or `failed` with a usage-limit error.
2. With a resumable run: persist runtime/interaction mode if changed, then `message.dispatch` with a fresh message id, text `"Continue where you left off."`, `manualContinuationOfRunId: <that run id>`, `dispatchMode: start_immediately` (the internal `"start"` mode, so no `deliveryIntent`), no `titleSeed`. If held queued runs exist, follow with `queue.resume`.
3. With only held queued runs: just `queue.resume`.
4. Guards match the send guards (busy, connecting, loading, `sendInFlightRef`).

A recorded Stop-with-queue case: `02-turn` t=127087 to 129136 (cancel one queued run, then interrupt).

## 5. Model, traits and access

### 5.1 Where providers and models come from

Providers: `server.getConfig` returns `ServerConfig.providers: ServerProvider[]`, one entry per configured provider instance, and `subscribeServerConfig` pushes `providerStatuses` updates (`docs/protocol.md` lines 1574-1576). Schema: `C/server.ts:75-86` (model) and `:213-300` (provider). The fields the composer reads:

| Field | Use |
|---|---|
| `instanceId` | routing key; goes into `ModelSelection.instanceId`. Opaque slug (`claudeAgent`, `codex`, or custom like `codex_personal`) |
| `driver` | driver kind slug (`claudeAgent`); decides icon and a few special cases. Not a routing key |
| `displayName`, `accentColor`, `iconUrl`, `badgeLabel` | picker presentation |
| `enabled`, `installed`, `status` (`ready`, `error`, `disabled`, ...), `availability` (`available`/`unavailable`, absent means available) | picker readiness. A provider is "ready" when `enabled && availability != unavailable && status == "ready"` (`W/providerInstances.ts:101-103`, `:138`). A provider is "selectable" when enabled and available (`:285-286`). Recorded: only `claudeAgent` was `ready`; `codex` had status `error` (`01-basic` line 23) |
| `models[]` | `{slug, name, shortName?, subProvider?, aliases?, badge? ("new"), isCustom, isDefault?, isLegacy?, capabilities: {optionDescriptors?}|null}` |
| `showInteractionModeToggle` | whether the plan/default toggle can show (also needs the legacy `planModeEnabled` client flag, 5.6) |
| `supportedRuntimeModes?` | subset of the four runtime modes; absent or empty means all (`ChatComposer.tsx:2161-2174`). Unknown future values are dropped by the decoder |
| `requiresNewThreadForModelChange?` | after the session started, changing model within this provider is blocked (5.5) |
| `continuation.groupKey` | providers sharing a key can continue each other's native thread |
| `reportsContextWindow` | the thread will have a context meter |
| `auth`, `version`, `usageLimits`, `skills`, `slashCommands`, `setup` | out of scope for M5 |

Default instance selection when nothing else decides (`W/providerInstances.ts:287-310`, `getDefaultProviderInstanceModel` at `:270-282`): the requested instance if selectable, else the first ready instance, else the first selectable one whose status is not `error`. Default model for an instance: first model with `isDefault && !isCustom`, else the first non-custom model, else the first model.

Per-model option descriptors (`C/model.ts:7-44`) drive the traits UI. Recorded Claude catalog (`01-basic` line 23):

| Model | Descriptors |
|---|---|
| `claude-opus-5-5` (badge new) | `effort` select: low, medium (default), high, xhigh, max, ultracode, ultrathink (`promptInjectedValues:["ultrathink"]`); `fastMode` boolean |
| `claude-sonnet-5-5` (new) | `effort` select: low, medium, high (default), xhigh, max, ultrathink |
| `claude-haiku-5-5` (new) | `effort` select: low, medium (default), high, xhigh, max, ultrathink |
| `claude-opus-4-6` | `effort` (low..max, ultrathink), `fastMode`, `contextWindow` select: `200k`, `1m` (default) |
| `claude-sonnet-4-6` | `effort`, `contextWindow` select: `200k` (default), `1m` |
| `claude-haiku-4-5` | `thinking` boolean only |
| others (`claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-5`, `claude-fable-5`, `claude-fable-5-1`, `claude-sonnet-5`) | `effort` and sometimes `fastMode` |

Descriptor shape: select `{id, label, type:"select", options:[{id,label,description?,isDefault?}], currentValue?, promptInjectedValues?}`; boolean `{id, label, type:"boolean", currentValue?}`. The ids the UI treats specially: `effort`/`reasoningEffort`/`reasoning`/`variant`/`thinking` (primary "Reasoning" control), `fastMode` ("Speed": Normal or Fast), `contextWindow` ("Context window"), `thinking` (Thinking on/off) (`TraitsPicker.tsx:50`, `:167-173`, `:545`).

Server settings that seed new threads (`server.getSettings`, `C/settings.ts:1116-1171`): `defaultModelSelection: ModelSelection|null` (recorded `null`) and `defaultRuntimeMode` (decoding default `full-access`, recorded `full-access`), both overridable per project (`resolveProjectSettings`, used at `W/hooks/useHandleNewThread.ts:114-121`). The project's `defaultModelSelection` wins over everything else for a new draft (`W/lib/chatThreadActions.ts:47-57`). `textGenerationModelSelection` (title generation, recorded `codex/gpt-6-luna`) is unrelated to what the composer sends.

### 5.2 `ModelSelection` on the wire

```json
{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"high"},{"id":"fastMode","value":false}]}
```

- `instanceId` and `model` are required (`C/modelSelection.ts:16-20`). `options` is optional; omit the key when empty. `createModelSelection` drops empty option lists (`packages/shared/src/model.ts:474-485`).
- `options` is `[{id, value: string | boolean}]` (`C/model.ts:46-53`). The decoder also accepts a legacy object form `{effort:"max", fastMode:true}` and re-encodes the array. Send the array.
- Option ids are the descriptor ids: `effort`, `fastMode`, `contextWindow`, `thinking`, plus provider-specific ones (Codex `reasoningEffort`, seen in the recorded `textGenerationModelSelection`). Effort = `effort`; speed = `fastMode`; thinking = `thinking`; context size = `contextWindow` (values `200k`/`1m`).
- The wire shape for a selection that sets nothing is just `{instanceId, model}`, as recorded in `02-turn`/`03-turn2` (`docs/protocol.md` line 821).

What the composer actually sends (`W/components/chat/composerProviderState.tsx:104-155`, `packages/shared/src/model.ts:269-300`):

1. Take the draft's explicit option picks for the selected instance.
2. Add an implicit `{"id":"fastMode","value":false}` when the model has a `fastMode` boolean descriptor and the draft has no explicit `fastMode` (`withImplicitFastModeDefault`, `composerProviderState.tsx:73-90`). Without it a prior Fast session would keep running Fast.
3. `buildExplicitProviderOptionSelectionsFromDescriptors` keeps only ids that were explicitly selected, resolved against the descriptors. Defaults the user never touched are omitted. So a fresh Opus 5.5 send carries `options:[{id:"fastMode",value:false}]` and a fresh Haiku 5.5 send carries no `options`.
4. The final selection is `createModelSelection(selectedInstanceId, selectedModel, optionsForDispatch)` (`ChatComposer.tsx:2344-2347`).

Ultrathink is special. It is an `effort` value with `promptInjectedValues:["ultrathink"]`. Choosing it does not set `options`. It rewrites the prompt to start with `Ultrathink:\n` (`TraitsPicker.tsx:93`, `:342-354`, and `applyClaudePromptEffortPrefix` at `packages/shared/src/model.ts:510-529`). Choosing another effort strips the prefix. If the body text itself contains the word "ultrathink" (`isClaudeUltrathinkPrompt`, `/\bultrathink\b/i`), the effort control is locked and shows "Ultrathink" (`TraitsPicker.tsx:176-187`, `:408-426`). The outgoing text also gets the prefix at send time if the effort resolves to ultrathink (`formatOutgoingPrompt`, section 1.2 step 8). M5 can omit `ultrathink` from the effort menu or implement the prefix rule above.

### 5.3 Which selection the composer shows and sends

Resolution (`W/components/chat/ChatComposer.tsx:2102-2180`, `W/composerDraftStore.ts:1248-1336`):

1. Instance: `resolveComposerProviderSelection` takes the first selectable of `[draft.activeProvider, thread.runtime.providerInstanceId, thread.modelSelection.instanceId, project default instanceId]`; if none is usable it falls back to the first ready instance. If a thread has started and cannot switch providers, only the locked instance is allowed.
2. Model: the draft's saved selection for that instance (`draft.modelSelectionByProvider[instanceId]`) if present; else the thread's model; else the project default's model; else the instance default model. Unavailable saved models are kept as "Unavailable" rows rather than replaced (`preserveUnavailableSelection`).
3. Options: the draft's `modelSelectionByProvider` options, else the thread's options, else the project default's options (`:1324-1330`).

The draft stores one selection per provider instance (`modelSelectionByProvider`) plus `activeProvider` and a `modelSelectionExplicit` flag set only when the user picked (seeded selections may be replaced later) (`:236-262`, `:402-415`).

### 5.4 Picker behavior

`ProviderModelPicker` (`W/components/chat/ProviderModelPicker.tsx`) is a popover trigger showing the provider icon and model name (`:136-160`, tooltip adds the `modelPicker.toggle` shortcut, default `mod+shift+m`, `packages/shared/src/keybindings.ts:175`). `ModelPickerContent` (`ModelPickerContent.tsx`) shows a provider sidebar with a "Favorites" pseudo-entry first, a search box (focused on open) and the model list.

- Sidebar entries: enabled instances (`isProviderInstancePickerVisible`). Initial sidebar choice: the active instance if the provider is locked or needs setup, else Favorites when any exist, else the active instance (`:254-266`). Left arrow in an empty search box moves between sidebar entries (`:937`).
- Search: tokenized fuzzy search across model name, short name, sub-provider, driver and provider display name (`scoreModelPickerSearch`, `:448-470`); results span all instances; favorites rank first on ties (`:500-515`).
- Favorites: client setting `favorites: [{provider: <instanceId>, model: <slug>}]` (`C/settings.ts:414-429`). The field name `provider` holds an instance id for storage stability. Toggling writes the whole array via `updateSettings({favorites})` (`ModelPickerContent.tsx:655-666`). Client settings persist in the browser's local storage under `t3code:client-settings:v1` (`W/clientPersistenceStorage.ts:5`, `:16-24`), so they are per client, not on the server. A native client keeps its own copy.
- Recents: I found no "recent models" feature in the picker. The closest thing is the sticky selection (5.7). Do not invent a recents list for parity.
- Hidden and ordered models: client setting `providerModelPreferences[instanceId] = {hiddenModels: string[], modelOrder: string[]}` filters and orders the list; custom models are never hidden (`C/settings.ts:430-438`, `W/modelSelection.ts:90-142`). Skip in M5.
- Selection: Enter on the highlighted row, or a click, calls `onInstanceModelChange(instanceId, slug)` and closes the popover (`ProviderModelPicker.tsx:113-117`). Keyboard jump shortcuts per row exist (`modelJump*`, `ModelPickerContent.tsx:669-830`); skip.
- Legacy models (`isLegacy`) are collapsed under an expander per instance.

`onProviderModelSelect` (`W/components/ChatView.tsx:10698-10776`) is what a pick does:

1. Ignore unknown instance ids.
2. If the provider cannot switch providers after start and the pick is another driver (or another `continuation.groupKey`), return silently.
3. Resolve the model slug for the instance (`resolveAppModelSelectionForInstance`); return if it does not resolve.
4. Restore the model's remembered options: `stickyOptionsByModelByProvider[instanceId][model]`. With none, the new model starts from its defaults (options are not carried over from the previous model).
5. `getStartedThreadModelChangeBlockReason` may block it with a toast (5.5).
6. Write `setModelSelection(target, nextSelection, {explicit:true, replaceOptions:true})` into the composer draft and `setStickyModelSelection(nextSelection)`.

### 5.5 How a change applies to the thread

A model or option change is draft state only. It does NOT send a command by itself. It reaches the server in the next send as `message.dispatch.modelSelection` (or `launchThread.modelSelection` for a new thread). On receipt the server emits `thread.model-selection-updated` (same instance) or `thread.provider-switched` (different instance), then creates the run with the new selection (`S/orchestration-v2/Orchestrator.ts:5142-5165`). The web client compares nothing client-side; it always sends the selection.

Other paths:
- `thread.model-selection.set {threadId, modelSelection}` and `provider.switch {threadId, modelSelection}` exist (`C/orchestrationV2.ts:2828-2833`; `docs/protocol.md` lines 981-982). The web client reaches them through `updateThreadMetadata({modelSelection})` (`CR/operations/commands.ts:586-601`): with `serverResolvedCommandContext` it always uses `thread.model-selection.set`, otherwise it picks between the two with `modelSelectionCommandType` (`packages/shared/src/model.ts:18-25`). It is used by the plan follow-up and implement-in-new-thread flows, not by the normal send (`ChatView.tsx:10454-10470`, `resolveThreadMetadataUpdateForNextTurn` at `ChatView.logic.ts:484-509`).
- While a run is active, a steer with a new selection saves it for the next turn, or restarts the run when the provider can (section 4.4).
- Blocking rules (`W/components/ChatView.logic.ts:1046-1092`), only after a session has started (`hasStartedSession = activeRuntime !== null`): changing instance is blocked unless the session `capabilities.sessions.supportsProviderSwitchingViaHandoff` (recorded `true` for Claude, `threadSupportsProviderHandoff` at `CR/state/threadWorkflows.ts:90-108`). Staying on the same instance but changing model is blocked only when either provider has `requiresNewThreadForModelChange === true`. Messages: "Start a new chat to switch providers" and "Start a new chat to change models". Same model and instance is always allowed (option changes are always allowed).

### 5.6 Runtime mode and interaction mode

`RuntimeMode` (`C/providerPolicy.ts:25-31`): `approval-required`, `auto-accept-edits`, `auto`, `full-access`. Default `full-access` (`:32`). Labels (`W/components/chat/runtimeModeConfig.ts:4-25`):

| Value | Label | Description |
|---|---|---|
| `approval-required` | Supervised | Ask before commands and file changes. |
| `auto-accept-edits` | Auto-accept edits | Auto-approve edits, ask before other actions. |
| `auto` | Auto | Supported providers approve routine actions; others still ask. |
| `full-access` | Full access | Allow commands and edits without prompts. |

The picker lists the modes in that order, filtered by the provider's `supportedRuntimeModes` (`ChatComposer.tsx:2161-2174`). If the thread's saved mode is not offered by the current provider, the first supported mode is shown but nothing is written until the user picks. Provider differences are in `docs/user/permission-modes.md` (Muse: Supervised and Full access only; Grok: no Auto-accept edits).

Effective mode (`ChatView.tsx:2200-2208`): `composerDraft.runtimeMode ?? serverThread.runtimeMode ?? project defaultRuntimeMode`. A change calls `setComposerDraftRuntimeMode` (and updates the local draft thread's context if it is a draft) (`:5355-5372`). It is persisted at send: for an existing thread `persistThreadSettingsForNextTurn` sends `thread.runtime-mode.set {threadId, runtimeMode}` when it differs from the thread's (`ChatView.tsx:6301-6316`, command at `CR/operations/commands.ts:604-613`); for a new thread it rides in `launchThread.runtimeMode`/`thread.create.runtimeMode`. The new-thread default comes from server settings (project override, then environment default `full-access`), not from the thread you were viewing (`docs/user/permission-modes.md`, `useHandleNewThread.ts:114-121`).

`ProviderInteractionMode`: `default` or `plan` (`C/providerPolicy.ts:34-36`). The Build/Plan toggle is a legacy beta feature. It shows only when the client setting `planModeEnabled` is true (default false, `C/settings.ts:446`) AND the provider has `showInteractionModeToggle !== false` (`W/components/ChatView.logic.ts:626-639`). Otherwise the effective mode is always `default`. Toggle: Shift+Tab in the composer (`ChatComposer.tsx:4456-4461`) or the `/plan` and `/default` slash commands. Persisted at send exactly like runtime mode, via `thread.interaction-mode.set` (`CR/operations/commands.ts:615-624`). **M5 can send `interactionMode:"default"` always and skip the toggle.**

### 5.7 Defaults, sticky state, persistence

- Composer draft store, localStorage key `t3code:composer-drafts:v1`, version 9 (`W/composerDraftStore.ts:89-90`). Persisted: `draftsByThreadKey`, `draftThreadsByThreadKey`, `logicalProjectDraftThreadKeyByLogicalProjectKey`, `stickyModelSelectionByProvider`, `stickyOptionsByModelByProvider`, `stickyActiveProvider` (`:343-356`). Writes debounce 300 ms (`:97`).
- Sticky model state is global to the client: the last model picked per instance, the last options per instance and model, and the last active instance. It seeds every new draft (`applyStickyState`, `:3046-3078`), and a project default or carried selection overrides it (`W/hooks/useHandleNewThread.ts:296-307`).
- A trait change calls `setProviderModelOptions(target, driver, options, {instanceId, model, persistSticky:true})`, which updates the draft selection and the sticky maps (`:3235-3320`, `TraitsPicker.tsx:301-318`).
- `docs/user/composer.md` "Model defaults": T3 remembers the provider, model and options for new threads; a project's configured model wins; resetting the project setting returns to the remembered selection.
- Server-side: `server.getSettings` exposes `defaultModelSelection` and `defaultRuntimeMode`; a native client may write them with `server.updateSettings`, but the web composer never does.

## 6. Drafts and new threads

### 6.1 The draft store

`W/composerDraftStore.ts` is a zustand store persisted to the browser's local storage. A native port needs the same ideas, not the same file.

| Aspect | Value |
|---|---|
| Storage key, version | `t3code:composer-drafts:v1`, `COMPOSER_DRAFT_STORAGE_VERSION = 9` (`:89-90`). A stored blob with another version is ignored when reading attachment ids (`:2391-2408`) and migrated on hydrate |
| Write timing | Debounced 300 ms (`COMPOSER_PERSIST_DEBOUNCE_MS`, `:97`), flushed before attachment verification |
| Persisted state | `draftsByThreadKey`, `draftThreadsByThreadKey`, `logicalProjectDraftThreadKeyByLogicalProjectKey`, `stickyModelSelectionByProvider`, `stickyOptionsByModelByProvider`, `stickyActiveProvider` (`:343-356`) |
| Not persisted | `backgroundSubmissionThreadKeys`, `rewindingThreadKeys`, context insertion handlers |

Two kinds of keys (`composerTargetKey`, `:1459-1464`; `resolveComposerDraftKey`, `:1507-1532`):

1. **Draft session** (a thread that does not exist on the server yet): key is a `DraftId`, a random UUID (`newDraftId`, `W/lib/utils.ts:48`).
2. **Server thread**: key is `"<environmentId>:<threadId>"` (`CR/environment/scoped.ts:20-36`).

If a server thread ref matches a draft session (same environment and thread id), the draft's id is used as the key, so typed text survives the draft's promotion (`:1520-1527`).

Three maps:

- `draftsByThreadKey[key]: ComposerThreadDraftState` is the editable content: `prompt`, attachments, context records, `modelSelectionByProvider` (one `ModelSelection` per provider instance), `activeProvider`, `modelSelectionExplicit?`, `runtimeMode: RuntimeMode|null`, `interactionMode: ProviderInteractionMode|null` (`:387-420`). A draft is dropped from the map when it has no prompt, attachments, contexts, model selections, active provider, or modes (`shouldRemoveDraft`, `:972-987`). "Has user content" ignores model and mode choices (`composerDraftHasUserContent`, `:426-446`), so a model pick alone does not make a draft worth keeping.
- `draftThreadsByThreadKey[draftId]: DraftSessionState` is the pre-thread context: `threadId` (pre-allocated UUID), `environmentId`, `projectId`, `logicalProjectKey`, `createdAt`, `runtimeMode`, `interactionMode`, `branch`, `worktreePath`, `envMode` (`local` or `worktree`), `startFromOrigin`, `environmentSelection?`, `promotedTo?` (`:450-466`).
- `logicalProjectDraftThreadKeyByLogicalProjectKey[logicalProjectKey] = draftId` gives at most one active draft per project (`:496`, setter doc at `:527-530`: reassigning removes the previous mapping).

`logicalProjectKey` is the project key after the user's project grouping setting; for a single environment without grouping it is `"<environmentId>:<projectId>"` (`scopedProjectKey`, `useHandleNewThread.ts:158-160`).

Other pseudo-drafts reuse the same store: a queued-message edit slot `queued-edit:<threadKey>:<runId>` (`ChatView.tsx:1685-1688`) and per-question attachment slots (`questionAttachmentDraftId`). A native port can keep these as separate in-memory fields.

Per-thread resets: the send clears prompt and attachments before the command returns (section 1.2 step 12). Model and mode picks stay in the draft after a send.

### 6.2 Starting a new thread (draft page flow)

Entry points call `handleNewThread(projectRef, options?)` (`W/hooks/useHandleNewThread.ts:64-390`). They are the new-thread button, `chat.new` (`mod+n`, `mod+shift+o`), `chat.newLocal`, the command palette, and "new thread" on a project row (`packages/shared/src/keybindings.ts:171-173`). The project comes from context (`W/lib/chatThreadActions.ts:71-100`): the active server thread's project, else the active draft's project, else `defaultProjectRef` = the first project in the user's project order (`useHandleNewThread.ts:437-446`). Branch, worktree and env mode are never carried over from the viewed thread; they come from configured defaults.

Steps:

1. **Reuse an empty draft.** If this project already maps to a draft session that is not promoted, has no matching server thread, and `!composerDraftHasUserContent`, reuse it: reset its workspace context to defaults (unless the draft is already the open route), re-apply the sticky model, apply project default or carried model selection unless the user explicitly picked one, remap, navigate to `/draft/<draftId>` (`:228-326`).
2. **Reuse the open draft.** If the current route is an empty draft of the same project, keep it (`:330-352`).
3. **Mint a fresh draft** otherwise (a draft with typed content is never reused; it stays reachable from the sidebar) (`:354-405`): `draftId = newDraftId()`, `threadId = newThreadId()` (both random UUIDs), `createdAt = now`. Store a draft session with `runtimeMode` = project/server `defaultRuntimeMode` (default `full-access`), `interactionMode` carried from the viewed composer or thread if any, `envMode` from project defaults, `branch/worktreePath = null` unless passed. Then `applyStickyState(draftId)` (copy sticky model selections into the draft), then if the project has `defaultModelSelection`, or a model is carried from the viewed thread's composer, `setModelSelection(draftId, selection, {replaceOptions:true})` (project default wins, `chatThreadActions.ts:47-57`). Navigate to `/draft/$draftId` (`replace` optional).
4. Races: the minting path re-checks the route and the project mapping after its awaits, and bails or reuses the winner (`:355-390`). Tests: `useHandleNewThread.test.ts:185-289`.

Nothing is sent to the server in steps 1 to 4. **The thread exists only locally until the first send.** The sidebar lists draft rows for drafts that have user content.

### 6.3 When the thread is created

The first send of a draft calls `startThreadTurn` with a `bootstrap.createThread` block (section 1.5). That becomes one `orchestration.launchThread` request, and the server creates the thread (`thread.create`) and the first message together. Draft thread `threadId` becomes the server thread id. So:

- Before the first send: no server thread, no shell row, nothing to cancel. A failed first send leaves the draft intact and restores the text if the composer is still empty (section 1.7).
- `isFirstMessage = !isServerThread || activeMessageCount === 0` (`ChatView.tsx:9217`) selects the first-send path. A server thread with zero messages (for example created by `thread.create` elsewhere) uses `launchThread` with `reuseExistingThread: true` only when a worktree must be prepared; otherwise it takes the plain `message.dispatch` path.
- `activeMessageCount` is the larger of committed user message ids and `projection.messages.length` (`ChatView.tsx:2213-2215`).

### 6.4 Promotion of the draft to the server thread

1. When the client observes a server thread with the draft's `(environmentId, threadId)`, `markPromotedDraftThreadByRef` sets `promotedTo` on the draft session (`W/components/ThreadRouteView.tsx:107-115`). Tests: `composerDraftStore.test.ts:1528-1612`.
2. The route navigates from `/draft/<draftId>` to `/<environmentId>/<threadId>` with `replace`, after the hero transition finishes (`ThreadRouteView.tsx:117-135`). The same `ChatView` instance stays mounted through the swap (comment at `ThreadRouteView.tsx:27-31`) so the optimistic message, spinner and typed text survive.
3. The navigation gate is `resolveDraftPromotionNavigationTarget` (`W/components/ChatView.logic.ts:442-460`): navigate once the server thread's `latestRun.startedAt != null`, or the run failed/interrupted/cancelled, or `latestUserMessageAt != null`. A background submission suppresses navigation.
4. Once the server thread has started, the draft session is finalized and removed (`finalizePromotedDraftThreadByRef`, `ThreadRouteView.tsx:160-165`). Composer edits made during promotion move to the canonical thread key (test `:1659`).
5. If the draft record vanishes and no server thread exists, the draft route redirects to `/` (`ThreadRouteView.tsx:137-142`).

### 6.5 Project choice

The web draft is bound to one project when it is minted. The composer has no project picker for a normal draft. `projectSelectionRequired = isLocalDraftThread && activeProject === null` (`ChatView.tsx:11609-11611`): the project vanished, so the editor is disabled with "Choose a project above to start a thread" and send is blocked. A send with `activeProject === null` also shows the warning toast "Choose a project first" (`ChatView.tsx:9206-9215`).

For the Swift port: pick the project when the user starts a new thread (project row, or last-used project), create one in-memory or persisted draft per project, and show the project name above the composer. Environment selection (`composer.host`, `composer.cycleHost`), branch and worktree controls are out of scope for M5; send `workspaceStrategy:{"type":"root"}`.

## 7. Composer behavior

### 7.1 Send shortcut modes

Client setting `sendShortcut` (`C/settings.ts:455-457`), default `enter`. Settings labels (`W/components/settings/SettingsPanels.tsx:2177-2181`): "Enter", "Cmd + Enter for multiline prompts", "Cmd + Enter always".

`composerSubmissionIntentForKey` (`W/composer-logic.ts:39-72`) returns the submit intent for a keydown, or null for "not a send". In order:

1. Null on mobile viewports, during IME composition (`isComposing` or `keyCode === 229`), and on key repeat (`:52-53`).
2. Resolve the keybinding command with context `{composerFocus:true, draftThreadRoute, turnRunning}`. `composer.sendAlternate` and a running turn gives `"alternate"` (`:60`). Draft-route and "send and new thread" commands give `"background"` (skip in M5).
3. Any other bound command, or a key that is not Enter, or Shift or Alt held: null. So **Shift+Enter always inserts a newline** and Alt+Enter is never a send (`:63`).
4. If the mode requires a modifier and neither Cmd nor Ctrl is down: null (plain Enter inserts a newline). `composerRequiresModifier` is true for `mod-enter`, and for `mod-enter-multiline` when the prompt contains `\r` or `\n` (`:29-37`, `:64-69`).
5. Otherwise `"foreground"`.

Pinned by `composer-logic.test.ts:80-97`:

| Mode | One-line prompt, plain Enter | Multi-line prompt, plain Enter | With Cmd/Ctrl |
|---|---|---|---|
| `enter` | send | send | send |
| `mod-enter-multiline` | send | newline | send |
| `mod-enter` | newline | newline | send |

While a turn is running, Cmd/Ctrl+Enter is `alternate` in every mode (`composer-logic.test.ts:99-148`): queue if the default is steer, steer if the default is queue. The settings page text that mentions Cmd+Shift+Enter for the opposite action is out of date for the running-turn case: Mod+Shift+Enter is `thread.steerQueuedMessage` and is not a composer send (`composer-logic.test.ts:150-158`). Trust the tests.

Enter also: selects the highlighted slash or mention menu item when a menu is open (skip), continues Markdown lists (skip), and advances a pending question (section 3.4).

### 7.2 Placeholder rules

First match wins (`ChatComposer.tsx:7482-7499`, constant in `W/composerPlaceholder.ts:1-2`):

| Condition | Placeholder |
|---|---|
| Approval pending | `Resolve this approval request to continue` |
| Question pending, choice-only | `Choose an option above` |
| Question pending, custom answer allowed | `Type your own answer, or leave this blank to use the selected option` |
| Plan follow-up shown | `Add feedback to refine the plan, or leave this blank to implement it` |
| Draft with no project | `Choose a project above to start a thread` |
| No usable provider | `Enable a provider in Settings to send a message` |
| `phase === "disconnected"` (runtime is null) | `Ask for changes, send follow-ups, or attach images` |
| Otherwise | `Ask anything, @tag files/folders, $use skills, or / for commands` |

For M5 drop the plan follow-up row and change the last string if you do not support `@`, `$` and `/` (suggest `Ask anything`; no test pins it).

### 7.3 Length validation

- Limit: `PROVIDER_SEND_TURN_MAX_INPUT_CHARS = 120000` (`C/chatAttachment.ts:13`). It is a client check. The server schema for `text` is a plain string (`C/orchestrationV2.ts:2850`) and I found no server enforcement in the send path (only scheduled tasks check it, `S/scheduledTasks/ScheduledTaskService.ts:1574`). Keep the check client-side anyway.
- Rule (`W/components/chat/composerSubmission.ts:12-23`): length = `max(trimmed.length, expandAssistantCitationsForProvider(trimmed).length)`. Drop the citation part in M5 (no citations). If length minus the limit is above 0, return `Prompt is <N> character(s) over the 120,000-character limit. Shorten or split it before sending.` (singular `character` when N is 1; numbers use `toLocaleString("en-US")`). Whitespace around the text does not count (test `composerSubmission.test.ts:242`).
- When it runs: (1) at submit on the raw prompt (`submitComposerDraft`, `:33-50`); the send does not happen, the draft stays, the message shows under the editor in a `role="alert"` paragraph (`ComposerPromptLengthValidation.tsx`). (2) Again in `onSend` on the fully composed provider input, which includes the `Ultrathink:\n` prefix and context (`ChatView.tsx:9284-9286`; `validateProviderInput`, `ChatComposer.tsx:6564-6573`). (3) The message is recomputed on every prompt change and cleared when no longer over (`ChatComposer.tsx:3408-3415`).
- A question answer (`submissionTarget: "pending-user-input"`) skips the length check (`composerSubmission.ts:25-31`, tests `:259-294`).

### 7.4 Disabled and busy states

Send button (`ComposerPrimaryActions.tsx:321-327`) is disabled when any of:

- `isSendBusy` (a local dispatch is pending, a queued edit is saving, or a resume is running: `ChatView.tsx:11615`);
- `!canOperateThread` (no `orchestration:operate` scope) or `sendDisabledReason !== null`. The reason comes from the parent (`externalSendDisabledReason`), "Select at least one model." (multi-model only), an attachment problem, or a provider-specific block (Antigravity) (`ChatComposer.tsx:2186-2200`);
- `isConnecting` (a state variable in `ChatView` that nothing sets, `ChatView.tsx:1911`, so it is always false today);
- `isEnvironmentUnavailable` = environment not connected, or no provider usable, or project selection required (`ChatComposer.tsx:7651-7655`);
- nothing to send: `!hasSendableContent && !showResume`.

Tooltip/label text when disabled (`ComposerPrimaryActions.tsx:290-300`): "Environment disconnected", the `sendDisabledReason`, "Connecting", "Preparing worktree", "Submitting message", or "Updating queued message".

Editor disabled (`ChatComposer.tsx:7500-7506`): `isConnecting`, an approval is pending, project selection required, a choice-only question is open, or the pending answer is being submitted. Note the editor is NOT disabled while the run is `preparing` or `starting`; typing is allowed and a send then resolves to `queue_after_active` on the server.

`onSend` guard list: section 1.2 step 1. Also a send while an attachment is still compressing or a pasted chip is resolving shows an info toast and aborts (`ChatComposer.tsx:4225-4240`); skip in M5.

Running-turn states for the primary button (section 2.2 and 4.2): Stop (empty draft), Steer or Queue icon (with content), Resume (empty draft and a resumable or held queue), check (editing a queued message), Submit arrow (idle).

### 7.5 Focus rules

- On mount and whenever the active thread changes, the composer takes focus on the next animation frame, unless the terminal drawer is open (`ChatView.tsx:6837-6845`).
- On window focus (desktop only, not mobile), focus returns to the composer after two animation frames, except when focus is in an input, textarea, select, iframe, webview, contenteditable, `role="textbox"`, inside a dialog or popup, or in a terminal; BODY or null active element counts as "yield to composer" (`ChatView.tsx:6850-6872`, rule at `ChatView.logic.ts:1283-1306`). Skipped when an MCP app is full screen. Tests: `ChatView.logic.test.ts` (search `shouldRefocusComposerOnWindowFocus`).
- `scheduleComposerFocus()` (next frame, `ChatView.tsx:4598-4602`) runs after: a model pick (unless the pick asks not to), a runtime or interaction mode change, starting and cancelling a queue edit, and a successful queue-edit save (`:5355-5392`, `:4673-4712`, `:9016`).
- Pointer-down on the send and Stop buttons does not take focus from the editor when `preserveComposerFocusOnPointerDown` is set (mobile and the resting layout) (`ComposerPrimaryActions.tsx:101-103`).
- After a failed send with an empty composer, the text is restored and the cursor goes to the end of the restored text (`resetCursorState`, `ChatView.tsx:10070-10083`).
- Mobile: sending blurs the editor when the send will go through (`shouldBlurMobileComposerOnSubmit`, `ChatComposer.tsx:4177-4202`). Skip.

### 7.6 Other behaviors worth keeping

- Prompt history: ArrowUp in an empty composer recalls the previous sent prompt (`docs/user/composer.md` "Recall a sent prompt"). Out of scope for M5.
- The outgoing text is trimmed (`applyClaudePromptEffortPrefix` trims, `packages/shared/src/model.ts:510-517`). A send with only whitespace is a no-op.
- A standalone `/plan` or `/default` message switches interaction mode instead of sending, only when plan mode is enabled (`ChatView.tsx:9173-9186`). Skip.
- `/compact` is a normal message the server recognizes as a native maintenance command; it cannot be steered, only queued (section 4.3).

## 8. Tests that pin this behavior

Paths are relative to the T3 repo. Line numbers are where the `it(` or `describe(` starts. Port the logic tests (pure functions) first; skip render tests that need a DOM unless you draw the same control.

### 8.1 Sending, dispatch modes, acknowledgement

| File | Tests |
|---|---|
| `packages/client-runtime/src/state/composerDispatch.test.ts` | `:8` mode table: idle gives `auto`; running steers by default, Mod flips to queue (`:13`); restart default flips to queue (`:18`); queue or steer default per setting (`:34`); alternate label (`:67`) |
| `packages/client-runtime/src/operations/commands.test.ts` | `:220` caller command ids are kept for idempotent retries; `:320` first-message launch keeps an existing worktree and branch; `:364` origin-based worktree for an empty thread; `:404` server-resolved delivery intent, no projection fetch; `:440` projection-shaped delivery for servers without the capability; `:723` model selection goes to the server without a projection fetch; `:765` provider-switch shaping for old servers; `:963` explicit idle start; `:280` plan provenance on runs |
| `apps/web/src/components/chat/composerSubmission.test.ts` | `:29` oversized draft stays editable, corrected follow-up sends; `:63` draft exactly at the limit sends; `:80` appended context over the limit blocks; `:112` rejected composed input does not finish submission; `:126` composed input at the limit sends; `:173`, `:202` citation expansion rules; `:242` surrounding whitespace is trimmed; `:259`, `:276` question answers skip the limit |
| `apps/web/src/components/ChatView.logic.test.ts` | `:269` `deriveComposerSendState` (expired terminal pills, element contexts, empty); `:241` metadata update only when model or branch changed; `:586` `hasServerAcknowledgedLocalDispatch` (unchanged state, newer settled turn, first send while preparing, matching running turn, steer projected onto the running run, pending interaction and errors acknowledge at once); `:748` `deriveCommittedServerUserMessageIds` ignores assistant rows and projection-only messages; `:145` `resolveDraftPromotionNavigationTarget` |
| `apps/web/src/composer-logic.test.ts` | `:71` `composerSubmissionIntentForKey`: send-shortcut table (`:80`), alternate on all platforms (`:99`), Mod+Shift+Enter is not a send (`:150`), remapped keys (`:170`, `:189`) |
| `apps/web/src/session-logic.test.ts` | `:589` queued input is not added to the timeline until its turn item exists |
| `apps/server/src/orchestration-v2/CommandPolicy.test.ts` | `:50` automatic delivery from provider capabilities; `:105` an automatic message queues while the run is preparing or starting; `:120` explicit steer and restart target the latest active run; `:147-216` steering matrix; `:419` typed capability errors; `:608` queued turns need queued-message support |
| `apps/server/src/orchestration-v2/ThreadLaunchService.test.ts` | `:769` title generation armed after the first message; `:917` attachment-only first message; `:1561` replay of a server-allocated launch; `:1780` retried launches dedupe; `:866` rejected first message leaves a reused thread's title alone; `:634` `/compact` and `/logout` are maintenance commands |

### 8.2 Stop

| File | Tests |
|---|---|
| `packages/client-runtime/src/operations/commands.test.ts` | `:998` interrupts a known run without fetching the projection; `:559` Stop for waiting, completed, failed, interrupted, cancelled and rolled-back runs that have background commands (except rollback); `:505` Stop with no run ends PR watches |
| `packages/client-runtime/src/state/threadExecution.test.ts` | `:194` a held queue presents as the stopped run; `:220` a queued-only run is not interruptible; `:237` checkpoint wait offers no interrupt; `:254` stale active run after the runtime parks at idle; `:267` preparing and starting runs stay interruptible |
| `apps/web/src/session-logic.test.ts` | `:90-98` `deriveCanInterruptRunningThread` and `derivePhase("queued") === "connecting"` |
| `apps/web/src/components/chat/ComposerPrimaryActions.test.tsx` | `:85` Stop offered while a running turn waits for user input; `:89` not offered for a pending request without a running turn |
| `apps/server/src/orchestration-v2/ThreadStop.test.ts` | `:149` Stop ends watches, holds queues, stops delegated tasks; `:325` a restart continuation of the stopped run does not start; `:378` a successful `thread.stop` or `run.interrupt` blocks a newer restart continuation on timestamp ties; `:512`, `:540` late watches refused |

### 8.3 Approvals and questions

| File | Tests |
|---|---|
| `apps/web/src/components/chat/ComposerPendingApprovalActions.test.tsx` | `:8` main decisions visible, secondary in the menu; `:24` secondary labels stay out of the compact row; `:44` provider labels preserved |
| `apps/web/src/components/chat/ComposerPendingApprovalPanel.test.tsx` | `:8` full command readable; `:27` empty detail falls back to the kind; `:44`, `:63` MCP app name and message |
| `apps/web/src/components/chat/ComposerPendingUserInputPanel.test.tsx` | `:42` header is a disclosure; `:56` dismiss only for async questions; `:63` starts expanded |
| `apps/web/src/components/chat/ComposerPendingUserInputPanel.permissions.test.tsx` | `:17` revoked scope cancels a pending auto-submit and a new grant resumes |
| `apps/web/src/pendingUserInput.test.ts` | `:56` answer resolution (exact editor text, custom beats options, single-select fallback, multi-select arrays, unknown values ignored); `:141` toggling; `:184` answer map (null when any unanswered, exact option values); `:251` progress, counts, first unanswered, `canAdvance`; `:359` attachment-only answers; `:378` displaced custom answer moves into the prompt |
| `packages/client-runtime/src/state/threadRequests.test.ts` | `:27` seed initial answers; `:96` message responses stay available after the runtime exits; `:120` only async questions are dismissible; `:137` answered requests leave the composer |
| `packages/client-runtime/src/operations/commands.test.ts` | `:941` dismisses a pending user-input request |

### 8.4 Queue and steer

| File | Tests |
|---|---|
| `packages/client-runtime/src/state/threadWorkflows.test.ts` | `:69` queue sort and the reorder and promote gates; `:141` held messages stay visible and the hold clears when they leave; `:158` automatic deliveries hidden; `:215` only the promoted head leaves; `:251` waiting, preparing and starting runs; `:294` no promotion until the running provider turn is projected; `:328` unsupported queue actions hidden |
| `packages/client-runtime/src/operations/commands.test.ts` | `:635` V2-native relationship and queue commands dispatched without compatibility shaping |
| `apps/web/src/components/chat/QueuedRunsControl.test.tsx` | `:41` no control when only hidden deliveries remain; `:100` thumbnail row; `:122` optimistic pending row dropped once the projection holds the message; `:154` original row stays visible while editing |
| `apps/web/src/components/chat/queuedMessageEdit.test.ts` | `:45`, `:65` saved attachments kept; `:77` save fails if an upload is missing; `:89`, `:101`, `:114` an edit survives the run starting elsewhere and never overwrites a separate draft |
| `apps/server/src/orchestration-v2/QueuedRunOrder.test.ts` | `:6` automatic completion delivery stays ahead of visible queued messages |

### 8.5 Model, traits, access

| File | Tests |
|---|---|
| `apps/web/src/components/chat/composerProviderState.test.tsx` | `:83` descriptor defaults are display-only and not dispatched; `:104` explicit selections override; `:126` selections equal to the default are still sent; `:143` unknown descriptors dropped; `:159` prompt effort from the first select; `:234` no descriptors means no options; `:250`, `:286` explicit options kept when the model is absent from the catalog; `:339` ultrathink styling; `:388` fastMode defaults to false when the provider reports true; `:400`, `:412` explicit fastMode kept; `:425` `withImplicitFastModeDefault` |
| `apps/web/src/components/chat/TraitsPicker.test.ts` | `:68` trigger label rules (fast mode omitted when off, paired with reasoning, effort labels, thinking independent of Fast, Codex service tiers); `:245` ultrathink with Fast; `:257` unavailable-model descriptors show only saved values |
| `apps/web/src/components/chat/ProviderModelPicker.test.tsx` | `:55`, `:68`, `:83`, `:102`, `:117`, `:132`, `:147` trigger label and fallback rules |
| `apps/web/src/components/chat/ModelPickerContent.test.ts` | `:35` which options show for ready and error providers; `:111` selected model resolution; `:157` setup offers; `:218` adjacent-provider navigation through favorites and ready instances |
| `apps/web/src/modelSelection.test.ts` | `:70` instance-scoped selection, custom models, hidden and ordered models, unavailable-model rows, fallbacks |
| `apps/web/src/providerInstances.test.ts` | `:55` picker readiness; `:321` selectable instance resolution; `:431` default model per instance; `:485` default selection resolution |
| `apps/web/src/components/ChatView.logic.test.ts` | `:355` `getStartedThreadModelChangeBlockReason`; `:219` interaction mode forced to default when plan mode is off |
| `apps/web/src/lib/chatThreadActions.test.ts` | `:41` explicit model picks; `:79` project default beats a carried selection; `:105-158` project resolution for new threads |
| `apps/web/src/composerDraftStore.test.ts` | `:1907` draft model selection (explicit marker, trait edits explicit, options per provider); `:2307` per-model sticky options; `:2446` sticky composer settings; `:2568` seed migration; `:2851` runtime and interaction settings in the draft |
| `packages/client-runtime/src/operations/commands.test.ts` | `:723`, `:765` model selection command shaping |

### 8.6 Drafts and new threads

| File | Tests |
|---|---|
| `apps/web/src/hooks/useHandleNewThread.test.ts` | `:185` runtime mode default per mode, delayed open abandoned on navigation (`:219`), start-from-origin rules (`:236`, `:269`) |
| `apps/web/src/composerDraftStore.test.ts` | `:1528-1673` promotion marking, per-environment promotion, composer edits move to the canonical thread, finalize; `:1853` manual workspace choices; `:802` malformed storage is treated as empty; `:1041` malformed drafts sanitized on merge; `:2904` draft persistence |
| `apps/web/src/components/ChatView.logic.test.ts` | `:145` draft promotion navigation; `:970-1030` draft hero transition |

## 9. Port checklist

Order is dependency order: each step uses only the ones above it. "M5" means build it for milestone 5. "Skip" means out of scope or defer. Section references are to this file.

### 9.1 Wire and identity (M5)

1. **IDs.** `commandId`, `messageId`, `threadId`, `draftId` are random UUID v4 strings generated by the client. `CR/operations/commands.ts:259-266`, `W/lib/utils.ts:46-50`. Reuse the same `commandId` if you ever retry a command.
2. **Codable types.** `ModelSelection {instanceId, model, options?: [{id, value: String|Bool}]}` (`C/modelSelection.ts`, `C/model.ts:46-53`), `RuntimeMode` (4 values, `C/providerPolicy.ts:25-31`), `ProviderInteractionMode`, `ProviderApprovalDecision` (5 values, `:50-56`), the `message.dispatch`, `run.interrupt`, `runtime-request.respond`, `thread.user-input.dismiss`, `queued-run.cancel`, `queued-run.reorder`, `queued-run.edit`, `queued-message.promote-to-steer`, `queue.resume`, `thread.runtime-mode.set`, `thread.interaction-mode.set` command structs (`C/orchestrationV2.ts:2836-2882`, `:2905-2975`; field table in `docs/protocol.md` 7.3) and the `orchestration.launchThread` input and result (`C/orchestrationV2.ts:3182-3211`). Encode optional keys by omission (`docs/protocol.md` line 286).
3. **RPC call.** `orchestration.dispatchCommand` returns `{sequence}` or a typed `OrchestrationV2DispatchCommandError {commandId, commandType, message, detail?, cause?}`. Show `message`. `orchestration.launchThread` fails with `OrchestrationV2ThreadLaunchError {commandId, projectId, message}` (`C/orchestrationV2.ts:3423-3431`). Treat transport errors (socket closed, not connected, ping timeout) as silent: no banner (`CR/errors/transport.ts:5-46`).

### 9.2 Read-side derivations from the thread projection and shell (M5)

4. **Phase.** `derivePhase(runtime)`: null is disconnected; preparing, starting, queued are connecting; running, waiting are running; else ready (`W/session-logic.ts:1069-1079`).
5. **Can interrupt.** `phase == running || (runtime status active && activeRunId != null)` (`W/session-logic.ts:1087-1095`, `CR/state/threadExecution.ts:280-288`). `activeRunId` is the newest preparing, starting or running run (`:257-258`). For `waiting` runs the shell gives no `activeRunId`; use the projection if you want Stop there.
6. **Pending requests.** `derivePendingThreadRequests` (`CR/state/threadRequests.ts:66-115`), sorted by `createdAt`, first one is active (`W/session-logic.ts:249-259`).
7. **Queue state.** `deriveThreadQueueWorkflowState` (`CR/state/threadWorkflows.ts:127-163`) and `getUserQueuedThreadRuns` (`:111-125`).
8. **Local send state.** `hasServerAcknowledgedLocalDispatch` and `createLocalDispatchSnapshot` (`W/components/ChatView.logic.ts:1183-1281`), plus the optimistic-message eviction set (`ChatView.tsx:1760-1766`). Simplification: evict an optimistic message when `projection.messages` or a `user_message` turn item has its id; clear the busy flag when the new user message id appears, a pending request appears, or an error is set.

### 9.3 Send pipeline (M5)

9. **Dispatch mode.** `resolveComposerDispatchMode` (`CR/state/composerDispatch.ts:13-23`) plus the wire mapping in section 1.3.1 (`CR/operations/commands.ts:733-768`). Assume `serverResolvedCommandContext` (true on this server version): `queue` gives `queue_after_active`, everything else `start_immediately` plus `deliveryIntent`.
10. **Content check and text.** `deriveComposerSendState` (`W/components/ChatView.logic.ts:859-890`), trim, `getComposerPromptLengthValidationMessage` (`W/components/chat/composerSubmission.ts:12-23`).
11. **Outgoing text.** `applyClaudePromptEffortPrefix` only if you expose ultrathink (`packages/shared/src/model.ts:510-529`).
12. **Title seed.** `truncate(trimmed text, 50)` with `...` suffix (`packages/shared/src/String.ts:1-8`), fallback `"New thread"`; send on every message, the server honours it only for the first (`Orchestrator.ts:4604-4609`).
13. **Existing-thread send.** Optimistic echo, clear composer, persist runtime mode if it changed (`thread.runtime-mode.set`), then `message.dispatch` with `modelSelection` (`W/components/ChatView.tsx:9763-9955`, `:6301-6316`). On failure restore text if the composer is empty, show the error (`:10029-10112`).
14. **First send of a draft.** `orchestration.launchThread` with `workspaceStrategy:{"type":"root"}`, `generateTitle:true`, `initialMessage:{messageId,text,attachments:[]}` (section 1.5). Record it against the sandbox first (`docs/protocol.md` line 1042 says it was never recorded).
15. **Keyboard.** `composerSubmissionIntentForKey` for `foreground` and `alternate` only (`W/composer-logic.ts:39-72`), honoring the three send-shortcut modes and Shift+Enter, IME and repeat rules (section 7.1). Skip `background` and `sendAndNewThread`.
16. **Settings.** Local settings `sendShortcut` (default `enter`) and `followUpBehavior` (default `queue`) (`C/settings.ts:455-460`).

### 9.4 Stop and resume (M5)

17. **Stop.** `run.interrupt {threadId, runId: activeRunId, holdQueue: true}` (section 2.1). Button rule: shown when `canInterrupt && !hasSendableContent && !editingQueued` (`W/components/chat/ComposerPrimaryActions.tsx:267-269`). Skip the PR-watch and background-work branches of `interruptThreadTurn`.
18. **Resume.** Empty composer and (latest executed run `interrupted`, or held queued runs): `message.dispatch` "Continue where you left off." with `manualContinuationOfRunId` and `start_immediately`, then `queue.resume` if runs are held (`ChatView.tsx:8656-8730`, `ChatView.tsx:2143-2158`). `queue.resume` alone when only held runs exist.

### 9.5 Approvals and questions (M5)

19. **Approval row.** Label by `requestKind`, detail text from the `approval_request` item `prompt`, `decline` and `accept` buttons, the rest in a menu, default option list when the item has none (section 3.2). Respond with `runtime-request.respond {requestId, decision}`; disable while responding; only when `responseCapability == live` (`ChatView.tsx:10114-10146`).
20. **Question card.** Port `pendingUserInput.ts` whole: `resolvePendingUserInputAnswer`, `togglePendingUserInputOptionSelection`, `setPendingUserInputCustomAnswer`, `buildPendingUserInputAnswers`, `derivePendingUserInputProgress`, `carryDisplacedCustomAnswerIntoPrompt` (`W/pendingUserInput.ts:42-208`) and its tests (`W/pendingUserInput.test.ts`). Seed `initialAnswer` (`CR/state/threadRequests.ts:45-63`). Number keys 1 to 9 as in section 3.4. 200 ms single-select auto-advance (`ComposerPendingUserInputPanel.tsx:140-148`). Respond with `answers` only. Dismiss via `thread.user-input.dismiss` for message-mode questions.
21. Composer states while a request is open: editor disabled for approvals, editor becomes the custom-answer field for questions, placeholders from section 7.2, Enter advances the question instead of sending.

### 9.6 Queue and steer (M5)

22. **Queue strip** from step 7, with Cancel, Steer now, Edit, Reorder (section 4.6). Commands: `queued-run.cancel`, `queued-message.promote-to-steer {queuedRunId, targetRunId: activeRun.id}`, `queued-run.edit {runId, text}`, `queued-run.reorder {runId, beforeRunId}`.
23. **Edit mode** with a separate draft slot and the exit-on-leave rule (section 4.7, `W/components/chat/queuedMessageEdit.ts:10-24`).
24. **Shortcuts.** `mod+shift+enter` steer oldest queued; `alt+arrowup` edit newest queued (section 4.6). Optional for M5, cheap to add.
25. Send-button states (Queue/Steer icon swap while Cmd/Ctrl is down, tooltip text) from section 4.2.

### 9.7 Model, traits, access (M5)

26. **Provider list** from `server.getConfig`/`subscribeServerConfig`: readiness (`W/providerInstances.ts:101-103`), default instance and model resolution (`:270-310`).
27. **Selection resolution** for the composer (section 5.3): draft selection, then thread, then project default, then instance default. Store per-instance selections plus `activeProvider` plus `explicit` flag in the draft.
28. **Dispatch options.** `withImplicitFastModeDefault` and `buildExplicitProviderOptionSelectionsFromDescriptors` (`W/components/chat/composerProviderState.tsx:73-155`, `packages/shared/src/model.ts:221-300`), `createModelSelection` (`:474-485`). Tests: `composerProviderState.test.tsx`.
29. **Picker.** Provider sidebar plus search plus favorites. Favorites in a local `favorites` array of `{provider, model}` (`C/settings.ts:414-429`). Block rules from `getStartedThreadModelChangeBlockReason` (`W/components/ChatView.logic.ts:1046-1092`). Sticky state per instance and per model (`W/composerDraftStore.ts:3235-3320`).
30. **Traits menu**: `effort` select, `fastMode`, `thinking`, `contextWindow` controls from descriptors (`TraitsPicker.tsx`). Ultrathink handling optional.
31. **Runtime mode menu** with the four modes and labels (`W/components/chat/runtimeModeConfig.ts:4-25`), filtered by `supportedRuntimeModes`. Persist at next send via `thread.runtime-mode.set`. Send `interactionMode:"default"` and skip the plan toggle.

### 9.8 Drafts (M5)

32. **Draft store**: `draftsByKey[key] -> {prompt, modelSelectionByProvider, activeProvider, explicit, runtimeMode, interactionMode}`; key is `<envId>:<threadId>` for server threads and a draft UUID for new threads; one draft session per project; sticky model state global. Persist debounced (section 6.1). `shouldRemoveDraft` and `composerDraftHasUserContent` semantics (`W/composerDraftStore.ts:426-446`, `:972-987`).
33. **New-thread handler** per section 6.2 (reuse empty draft, else mint). Seed order: sticky, then project default or carried model, runtime mode from project/server default.
34. **Promotion**: navigate to the server thread when the shell shows it and `latestRun.startedAt` or `latestUserMessageAt` is set (`W/components/ChatView.logic.ts:442-460`); keep the same view so the optimistic row survives; delete the draft session after the thread started.

### 9.9 Skip for M5

Slash menus and `@`/`$` mentions, command palette bits, attachments and uploads (incl. question attachments and queued-edit attachments), rich text editing and list continuation, inline context chips (terminal, review comment, annotation, thread, PR), citations, prompt stash, prompt history, plan mode and plan follow-up banner, multi-model fan-out, background send (`composer.sendBackground`, `sendAndNewThread`), compact-before-send chip, `/goal`, usage limits panel, codex feedback command, worktree and branch controls, environment switching and load balancing, custom model settings UI, hidden and ordered models, mobile layouts, voice input.

### 9.10 Record these against the sandbox before relying on them

1. `orchestration.launchThread` reply and the event sequence it produces (`defer_start` run, `preparing` status).
2. A steer: `message.dispatch` with `deliveryIntent:"steer"` during a long reply; confirm the `user_message` item with `inputIntent:"steer"`.
3. A queue drain: queue a message, let the active run finish, record the `queued` to `starting` transition and the `user_message` item with `inputIntent:"queued_turn"`.
4. `queued-message.promote-to-steer`, `queued-run.edit`, `queued-run.reorder`, `queue.resume`.
5. A multi-select or free-text question (needs a prompt that makes the model ask) and the `runtime-request.respond` with `answers`.
6. `thread.user-input.dismiss` on a message-mode question.
7. Whether `deliveryIntent:"auto"` on an idle thread behaves the same as the recorded plain `start_immediately` (the recorder never sent `deliveryIntent`).

Recorded 2026-10-10 in `fixtures/transcripts/05-composer.jsonl` (scenario `composer` in `scripts/record-transcript.swift`): items 1 and 7, plus a queue, `run.interrupt` with `holdQueue`, and resume. What the wire showed:

- Item 1: see section 1.5 (reply shape, subscribe only after the reply).
- Item 7: `deliveryIntent:"auto"` with `start_immediately` on an idle thread behaves like the plain form: `run.created` `starting`, `message.updated`, `user_message` item with `inputIntent:"turn_start"`, then `run.updated` `running` within 3 ms.
- Queue (`queue_after_active`, no intent) behind a running run: `run.created` `queued`, `message.updated` for the user message and no turn item yet. The shell's thread status turned `queued` while run 2 was still running (`activeRunId` still run 2), and back to `running` after the interrupt request. So the shell status is not a reliable "is running" signal; use the runs.
- `run.interrupt` with `holdQueue:true` (t=5440): `run_interrupt_request` item and `run.updated` for the queued run with `queueHeld:true` in the same chunk, the `run_interrupt_result` item and run `interrupted` about 850 ms later, then the checkpoint. Shell status `interrupted`.
- Resume (t=9477): `message.dispatch` "Continue where you left off." with `manualContinuationOfRunId` and `start_immediately` creates run 4 with a normal visible `user_message` item (`inputIntent:"turn_start"`). `queue.resume` (t=10478) only flips the held run to `queueHeld:false`; it stays queued behind run 4 and starts after run 4 completes, when its `user_message` item appears with `inputIntent:"queued_turn"` (item 3 of this list).
- Runs pass through `waiting` for about 100 ms between the provider turn completing and the checkpoint. The shell reports `activeRunId: null` while waiting.

