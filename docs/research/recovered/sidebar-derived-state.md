# T3 Code thread sidebar: derived UI state

Source: `/Users/mrm/CandyWrapper-research/t3code` at tag `v0.0.46-nightly.20261009.2861` (HEAD `3b6af0bd1`). All paths below are repo-relative to that checkout. Research was read-only: nothing was built, run, or tested. Line numbers were read directly from the files. Anything inferred but not confirmed in code is marked UNVERIFIED.

Goal: give a native macOS (Swift + AppKit) client the exact rules the official clients use to turn server thread shells into sidebar rows: status, unread, timestamps, sections, ordering, grouping, subagents, and row content.

---

## 0. Which surfaces are "the official sidebar"

- Web and desktop render one of two sidebars. `apps/web/src/components/AppSidebarLayout.tsx:339-341` renders `LegacyThreadSidebar` (from `LegacySidebar.tsx`) when `useLegacySidebarEnabled()` is true, else `ThreadSidebar` (from `Sidebar.tsx`). `useLegacySidebarEnabled` (`apps/web/src/hooks/useSettings.ts:388-392`) returns `settingsHydrated && legacySidebarEnabled`, and `legacySidebarEnabled` defaults to `false` (`packages/contracts/src/settings.ts:467`, comment at 463-466 says everyone was reset to the new default sidebar).
  - Default and canonical: `apps/web/src/components/Sidebar.tsx` ("sidebar v2") with pure logic in `apps/web/src/components/Sidebar.logic.ts`.
  - Opt-in legacy: per-project tree in `apps/web/src/components/LegacySidebar.tsx` (Settings, General, Legacy features).
- Mobile renders "Thread List v2": model in `apps/mobile/src/features/threads/threadListV2.ts`, rows in `apps/mobile/src/features/threads/thread-list-v2-items.tsx`. Used by the compact Home list (`apps/mobile/src/features/home/HomeScreen.tsx`) and the iPad split-view sidebar (`apps/mobile/src/features/threads/ThreadNavigationSidebar.tsx:60-70, 370, 440, 692`).
- Shared logic: `packages/client-runtime/src/state/*` and `packages/shared/src/*`. Many functions are explicitly documented as "shared by web and mobile so both render the same order".

Recommendation: mirror web sidebar v2 plus the shared client-runtime functions. Mobile differences are listed where they exist.

Thread identity in every client is the scoped key `${environmentId}:${threadId}` (`packages/client-runtime/src/environment/scoped.ts:25-28`). Thread ids are only unique per environment.

---

## 1. The server-provided shell row

### 1.1 Schema (`packages/contracts/src/orchestrationV2.ts`)

`OrchestrationV2ShellThreadStatus` (1813-1817) is `"idle"` or any `OrchestrationV2RunStatus`. `OrchestrationV2RunStatus` (453-465) literals: `"preparing" | "queued" | "starting" | "running" | "waiting" | "completed" | "interrupted" | "failed" | "cancelled" | "rolled_back"`.

`OrchestrationV2PendingRuntimeRequestSummary` (1819-1825): `{ id: RuntimeRequestId, kind, createdAt }`. `kind` is `OrchestrationV2RuntimeRequest.fields.kind` (1030-1033): `ProviderRequestKind` (`packages/contracts/src/providerPolicy.ts:38-44`: `"command" | "file-read" | "file-change" | "mcp-elicitation" | "permission"`) or `"dynamic_tool_call" | "user_input" | "auth_refresh"`.

`OrchestrationV2LatestVisibleMessageSummary` (1827-1834): `{ id, role ("user"|"assistant"|"system", from 1123), text, updatedAt }`. The server always sends `null` for this field (see 1.2).

`OrchestrationV2ThreadShell` (1836-1929), field by field with line:
- `createdBy` (`"user"|"agent"|"system"`, 76-77) and `creationSource` (`"web"|"mobile"|"mcp"|"provider"|"server"`, 79-86) via `OrchestrationV2CreationFields` (91-94)
- `id`, `projectId`, `title: Schema.String` (1840), `providerInstanceId`, `modelSelection`, `runtimeMode`, `interactionMode` (`"default"|"plan"`, providerPolicy.ts:34)
- `branch: NullOr<TrimmedNonEmptyString>` (1845), `worktreePath` (1846)
- `linkedPullRequest?` (1848, legacy single link), `pullRequests?: ThreadPullRequestLink[]` (1849), `branchPullRequest?` (1851)
- `lineage` (1852): `{ parentThreadId: ThreadId|null, relationshipToParent: "fork"|"subagent"|null, rootThreadId }` (`OrchestrationV2AppThreadLineage`, 108-112)
- `forkedFrom` (1853), `activeProviderThreadId` (1854), `historyOrigin?` (`"native"|"v1_import"`, 88, 1855)
- `latestRunId` (1856), `latestRunRequestedAt?` (1857), `latestRunStartedAt?` (1858), `latestRunCompletedAt?` (1859), `activeRunId` (1860)
- `activityRunStartedAt?` (1865), `activityRunStatus?: "preparing"|"starting"|"running"|"waiting"|null` (1866-1868)
- `status: OrchestrationV2ShellThreadStatus` (1869)
- `lastError?` (1870), `lastErrorClass?` (1871; `OrchestrationV2ProviderFailureClass` 1261-1268: `"usage_limit"|"provider_error"|"transport_error"|"permission_error"|"validation_error"|"unknown"`), `usageLimitResetAt?` (1872)
- `pendingRuntimeRequest` (1873), `latestVisibleMessage` (1874)
- `latestUserMessageAt` (1875), `latestUserAuthoredMessageAt?` (1880)
- `hasActionableProposedPlan: boolean` (1881)
- `pendingBackgroundTasks` (1884-1886, decodes to `[]` when absent). Each task: `{ taskId, description?, kind }` where kind is `"subagent"` (with optional `childThreadId`), `"command"`, `"monitor"`, `"background_task"`; unknown kinds decode as `"background_task"` (810-828)
- `providerInstanceHistory` (1890-1892, decodes to `[]`)
- `goal?` (1894; `OrchestrationV2ProviderGoal` 858-868, status 843-850: `"active"|"paused"|"blocked"|"usage_limited"|"budget_limited"|"complete"`)
- `itemCount`, `visibleItemCount` (1895-1896)
- `createdAt`, `updatedAt`, `archivedAt` (1897-1899)
- `settledOverride: "settled"|"active"|null` (1900), `settledAt` (1901), `unsettledAt?` (1902)
- `snoozedUntil?`, `snoozedAt?` (1903-1904), `limitRecovery?` (1905; schema 339-346)
- `pinnedAt?` (1907), `autoSettleDisabledAt?` (1908), `pinOrderKey?` (1910), `activeOrderKey?` (1912)
- `lastVisitedAt?` (1917). Comment 1913-1916: omitted by servers without visited tracking; clients fall back to local visited state when absent
- `titleRegeneration?: { requestId, startedAt } | null` (1919-1926)
- `deletedAt` (1927)

JSON variant `OrchestrationV2ThreadShellJson` (2410-2440) maps every timestamp to `DateTimeUtcFromString` (ISO strings). `usageLimitResetAt` and `limitRecovery.resetAt` are already `IsoDateTime` strings. Which encoding the WebSocket stream uses was not checked (UNVERIFIED); the HTTP snapshot path decodes JSON (`packages/client-runtime/src/state/shellSnapshotHttp.ts:62-77`).

Snapshot and stream: `OrchestrationV2ThreadShellSnapshot` (1931-1936: `schemaVersion`, `snapshotSequence`, `threads`, `archivedThreads`), `OrchestrationV2ShellSnapshot` adds `projects` (1939-1942). `OrchestrationV2ShellStreamItem` (1945-1981): `synchronized`, `snapshot` (with optional `resolvedRepositoryIdentityRoots`), `project.updated`, `project.removed`, `thread.updated {sequence, location: "active"|"archive", thread}`, `thread.removed {sequence, location, threadId}`. Archived threads have their own stream (`OrchestrationV2ArchivedShellSnapshot` 3155-3161, `OrchestrationV2ArchivedShellStreamItem` 3163-3180; WS methods `orchestration.subscribeArchivedShell`, `orchestration.subscribeShell` at 3150-3151).

### 1.2 How the server computes the fields

There are two builders with the same intent:
- In-memory `threadShellFromProjection` (`apps/server/src/orchestration-v2/ProjectionStore.ts:1372-1519`).
- SQL path used for both the shell snapshot and per-thread live deltas: `selectShellThreadRows` (5111-5301) -> `shellThreadStateFromRow` (5566-5706) -> `shellFromState` (1697-1774). Snapshot: `decodeShellSnapshot` (5770-5815). Live delta per thread: `getThreadShell` (5831-5896), called from `apps/server/src/ws.ts:1025-1026` through `threadManagement.getThreadShell` and turned into a stream item by `shellStreamItemFromThreadShell` (`ShellStream.ts:292-319`). The Orchestrator's `getThreadShell` appears to delegate to the projection store (`Orchestrator.ts:10902-10904`, delegation chain not fully read, UNVERIFIED).

Field derivation (SQL line refs first, in-memory second):
- `status`, `latestRunId`, `latestRunRequestedAt/StartedAt/CompletedAt`: the "presented" run. SQL picks the newest run by ordinal that is not a held queued run (`NOT (status = 'queued' AND queueHeld IS 1)`, 5263-5274; matches `latestUnheldRun`, `packages/shared/src/orchestrationV2ThreadError.ts:115-124`). If the latest executed run failed with class `usage_limit`, that blocking run replaces it and status becomes `"failed"` (5275-5288, 5614-5640; in-memory `usageLimitRunPresentedAsLatest(...) ?? latestUnheldRun(...)`, 1382-1387; shared 101-108). No run gives `"idle"` (1469). `shellStatusFromStoredRunStatus` maps stored null to `"idle"` and any unknown stored string to `"failed"` (1596-1614).
- `activeRunId`: newest run in `preparing|starting|running` (5130-5137; `isInterruptibleRunForShell` 1555-1557).
- `activityRunStatus`, `activityRunStartedAt`: newest run in `preparing|starting|running|waiting` (5138-5158; `isActivityRunForShell` 1561-1567). Start time is `COALESCE(workStartedAt, startedAt, requested_at)`, mirroring `orchestrationV2RunWorkStartedAt` (contracts 591-595: `run.workStartedAt ?? run.startedAt ?? run.requestedAt`; a wake keeps the start of the work it continues).
- `lastError`, `lastErrorClass`, `usageLimitResetAt`: `threadErrorSummary(failure, sessionError)` (shared `orchestrationV2ThreadError.ts:36-49`). `failure` is the newest failed `error` turn item on the root node of the presented failed run (`latestRootProviderFailure`, 9-33; SQL 5169-5181). `sessionError` is the newest provider session `lastError` for the thread's provider instance (5159-5168). Rule: if a session error exists and differs from the failure message, `lastErrorClass` and `usageLimitResetAt` become null and `lastError` is the session error; otherwise `lastError = sessionError ?? failure.message`, `lastErrorClass = failure.class`, `usageLimitResetAt = failure.resetAt` only for `usage_limit`.
- `pendingRuntimeRequest`: the single newest pending runtime request (`ORDER BY created_at DESC, runtime_request_id DESC`, 5197-5204), else a waiting `secret_request` turn item inside a live run presented as `kind: "user_input"` (5205-5217, 5588-5595; `secretRequestAsPendingInput` 1349-1370). Only one request is summarized, ever.
- `latestVisibleMessage`: always `null` (1482-1484 and 1748; comment: thread detail owns message bodies). No client reads it (grep of web, mobile, client-runtime found only fixtures).
- `latestUserMessageAt`: newest message with role `user` by `updated_at` regardless of author (5218-5225; 1418-1424, 1485). Wakes, PR-watch notes, and agent messages use the user role, so they move this.
- `latestUserAuthoredMessageAt`: same but `createdBy = 'user'` (5226-5234; 1486-1487).
- `hasActionableProposedPlan`: any plan with `kind = 'proposed_plan' AND status = 'active'` (5235-5241; 1488-1490).
- `pendingBackgroundTasks`: `derivePendingBackgroundWork` (`packages/shared/src/orchestrationV2PendingBackgroundWork.ts:223-287`). Empty while any `preparing|starting|running` run exists. If there is no latest run, only PR watches count. Otherwise requires the latest run status in `cancelled|completed|failed|interrupted|waiting` (40-46). Merges: provider-thread roster (filtered to `activeProviderThreadId`), active `command_execution|dynamic_tool|subagent` turn items (excluding persistent dynamic tools and rolled-back runs, 186-203), and PR watches as monitors with `taskId: "pull-request-watch:<host>/<repo>#<n>"`, `description: "Watching pull request #<n>"` (289-303).
- `providerInstanceHistory`: distinct provider instances of root provider threads (no owner node), oldest first (1521-1545).
- `goal`: goal on the provider thread whose id is `activeProviderThreadId` (1547-1553).
- `updatedAt`: SQL path uses the thread payload `updatedAt` (5702, 1758). In-memory path uses `projection.updatedAt` (1503). See 1.3 for when it moves.
- Lifecycle fields (`settledOverride`, `settledAt`, `unsettledAt`, `snoozedUntil`, `snoozedAt`, `pinnedAt`, `pinOrderKey`, `activeOrderKey`, `autoSettleDisabledAt`, `lastVisitedAt`, `titleRegeneration`, `limitRecovery`) are copied from the thread payload (1757-1772).

### 1.3 When `updatedAt` moves (matters for unread and labels)

- SQL projection: after writing any event, if the event type is NOT in the list at `ProjectionStore.ts:2630-2648`, the thread row gets `updatedAt = event.occurredAt` (2649-2668). The excluded (no automatic bump) types are: `thread.created`, `thread.archived`, `thread.unarchived`, `thread.deleted`, `thread.settled`, `thread.unsettled`, `thread.snoozed`, `thread.unsnoozed`, `thread.auto-settle-set`, `thread.pinned`, `thread.unpinned`, `thread.pin-reordered`, `thread.visited`, `thread.marked-unread`, `thread.metadata-updated`, `thread.runtime-mode-updated`, `thread.interaction-mode-updated`, `thread.model-selection-updated`, `thread.provider-switched`. Those carry their own `updatedAt` in the payload (the Orchestrator sets it per mutation, see 6.6).
- So any run, message, turn-item, or request event bumps `updatedAt` (this is the "activity" clock).
- `thread.visited` and `thread.marked-unread` never bump `updatedAt` (in-memory reducer 716-723, SQL exclusion list). Internal doc confirms: "A visit advances `lastVisitedAt` monotonically without changing `updatedAt`" (`docs/internals/performance-regressions.md:80-81`).
- Observation (code-read, UNVERIFIED at runtime): `thread.active-reordered` and `thread.pull-request-synced` are not in the exclusion list, so the SQL row's `updatedAt` is bumped to `occurredAt` for them, even though the Orchestrator comment says "Arranging the active list is not thread activity" and keeps the payload `updatedAt` (`Orchestrator.ts:2890-2896`).

### 1.4 Stream delivery details that affect derived state

- Active snapshot omits archived threads (`buildActiveShellSnapshot`, `ShellStream.ts:22-34`; split at `ProjectionStore.ts:5812-5813`). An archived thread arrives on the active stream as `thread.removed` (`ShellStream.ts:296-304`).
- `skipUnchangedThreadShells` (`ShellStream.ts:224-273`, `UNCHANGED_THREAD_SHELL_RESEND_MS = 5_000` at 227): a `thread.updated` whose shell equals the last one sent on this subscription, ignoring `updatedAt`, is dropped if the last send is under 5 s old. Consequence: the client's `updatedAt` can lag real activity by up to about 5 s, and indefinitely if no further event arrives.
- Client reducer `applyShellStreamEvent` (`packages/client-runtime/src/state/shellReducer.ts:136-200`): ignores events with `sequence <= snapshotSequence`; `thread.updated` replaces the whole row (upsert by id); identical rows keep object identity.
- Optimistic overlay: `createOptimisticThreadLifecycle` (`packages/client-runtime/src/state/threadLifecycle.ts:18-102`) applies pending per-thread patches over the snapshot until a snapshot with `snapshotSequence >= commandResult.sequence` arrives. Patches are defined in `packages/client-runtime/src/state/threadCommands.ts:407-488` (settle, unsettle, snooze, unsnooze, setAutoSettle, pin, unpin, reorderPin, reorderActive). `visit` and `markUnread` are not optimistic (230-241). Web wires this at `apps/web/src/state/threads.ts:20-30`.

---

## 2. Client presentation: `presentThreadShell`

`packages/client-runtime/src/state/models.ts:208-292` turns a raw shell into `EnvironmentThreadShell` (interface 89-148). All timestamps become ISO strings (`DateTime.formatIso`). Every sidebar rule below reads this shape.

- `latestRun` (213-228): null when `latestRunId === null`. Otherwise `{ runId, status: status === "idle" ? "completed" : status, requestedAt, startedAt, completedAt }`. If the server omitted `latestRunCompletedAt` (old server), `completedAt` is synthesized as `updatedAt` when status is `idle` or terminal (`completed|interrupted|failed|cancelled|rolled_back`, 158-166), else null.
- `runtime` from `shellRuntime` (168-199):

```ts
const parkAtIdle =
  backgroundWorkHoldsCompletion(thread.pendingBackgroundTasks ?? []) &&
  thread.status !== "failed";
if (thread.latestRunId === null && thread.activeProviderThreadId === null && !parkAtIdle) {
  return null;
}
const status = parkAtIdle ? "idle" : (thread.activityRunStatus ?? thread.status);
```

  plus `activeRunId`, `activityStartedAt` (from `activityRunStartedAt`, undefined when the field is absent), `providerInstanceId`, `providerName: null`, `lastError`, `lastErrorClass`, `usageLimitResetAt`, `updatedAt` (= shell `updatedAt`).
  `backgroundWorkHoldsCompletion` (`packages/shared/src/orchestrationV2PendingBackgroundWork.ts:73-88`): true if any task kind is `subagent`, `monitor`, or `background_task`; `command` alone does not hold (a dev server left running reads as done). Tests: `packages/client-runtime/src/state/entities.test.ts:138-198`.
- `title` (233-236): if `lineage.relationshipToParent === "subagent"`, `formatSubagentDisplayTitle(title)` (`subagentDisplay.ts:47-54`: strips a leading `Subagent:` case-insensitively and turns `/root/.../name` paths into Title Case words).
- `hasPendingApprovals` (255-258): `pendingRuntimeRequest !== null && kind !== "user_input" && kind !== "auth_refresh"`. Note: this counts `dynamic_tool_call` as an approval; a grep of `apps/server/src` found no code creating `dynamic_tool_call` or `auth_refresh` requests at this tag, so in practice approvals are the five `ProviderRequestKind` kinds.
- `hasPendingUserInput` (259): `pendingRuntimeRequest?.kind === "user_input"` (includes waiting secret requests).
- `pullRequests: threadPullRequestsOf(thread)` (`packages/shared/src/threadPullRequests.ts:329-347`): uses `pullRequests` when present; otherwise synthesizes one link from `linkedPullRequest` (`source: "manual"`, `linkedAt: "1970-01-01T00:00:00.000Z"`, `snapshot: null`).
- `lastVisitedAt` (279-281): copied only when the field exists on the shell. `undefined` means "server predates visited tracking".
- `titleRegeneration`, `pinOrderKey ?? null`, `activeOrderKey ?? null`, other lifecycle fields copied.

Two helpers used by rows:
- `resolveThreadProviderStack` (301-314): `THREAD_PROVIDER_STACK_LIMIT = 3`; `current = runtime?.providerInstanceId ?? modelSelection.instanceId`; `previous = providerInstanceHistory` without `current`; result `[...previous.slice(-2), current]`.
- `resolveThreadWorkingStartedAt` (320-336): if `runtime.activityStartedAt !== undefined`, return it (validated, may be null); else (old server) if `latestRun.completedAt === null && latestRun.runId === runtime.activeRunId`, return `startedAt ?? requestedAt`; else null.

`threadRuntimeCanArchive` (70-77): archive is blocked while runtime status is `preparing|starting|running`, or `queued` with a non-null `activeRunId`.

---

## 3. Q1: thread status derivation

### 3.1 Web sidebar v2 (canonical)

`resolveSidebarThreadStatus` (`apps/web/src/components/Sidebar.logic.ts:983-1003`), output type `SidebarThreadStatus` (954-961): `"approval" | "input" | "working" | "waiting" | "failed" | "limited" | "ready"`.

```ts
if (thread.hasPendingApprovals) return "approval";
if (thread.hasPendingUserInput) return "input";
if (thread.runtime !== null &&
    ["preparing", "queued", "starting", "running", "waiting"].includes(thread.runtime.status))
  return "working";
if (thread.runtime?.status === "idle") return "waiting";
if (thread.runtime?.status === "failed")
  return thread.runtime.lastErrorClass === "usage_limit" ? "limited" : "failed";
return "ready";
```

Priority: approval > input > working > waiting > failed/limited > ready.

Unread and Woke are computed separately (see section 4) and only surface when status is `ready`.

Row label (`SidebarThreadRow`, `apps/web/src/components/Sidebar.tsx:1293-1347`; same precedence as the test-only `resolveSidebarV2TopStatus`, Sidebar.logic.ts:1015-1039):

| status / condition | label | icon (lucide) | class |
|---|---|---|---|
| working, `goal?.status === "active"` | `Goal` | CircleDashedIcon | `text-info` |
| working | `Working` + live duration | CircleDashedIcon | `text-info` |
| waiting | `Waiting` | none | `text-muted-foreground` |
| approval | `Approval` | ShieldQuestionIcon | `text-warning-foreground` |
| input | `Input` | MessageCircleQuestionIcon | `text-indigo-600 dark:text-indigo-300` |
| limited | `Limited` | CircleAlertIcon | `text-warning` |
| failed | `Failed` | CircleAlertIcon | `text-error` |
| ready and `isWoke` | `Woke` (a button, AlarmClockIcon) | AlarmClockIcon | `text-warning` |
| ready and `isUnread` | `Done` | CircleCheckIcon | `text-success` |
| ready otherwise | no label: relative time is shown instead | | |

Icons render in the card status slot (2060-2070). The duration only renders when `status === "working"` (2075-2079). Accessibility label is `[title, statusLabel, projectDisplayName].filter(Boolean).join(", ")` (`resolveSidebarRowAccessibility`, Sidebar.logic.ts:49-61).

Emphasis ("recede") `shouldRecedeSidebarThread` (Sidebar.logic.ts:963-976):

```ts
if (input.isActive || input.isSelected || input.status === "input") return false;
if (input.status === "working" || input.status === "waiting") return true;
if (input.status === "ready" || input.status === "approval") {
  return !input.isUnread && !input.isWoke;
}
return false;
```

Receded rows get muted text and normal weight; receded working rows also get `opacity-70` (Sidebar.tsx:1582-1598). Title classes (1665-1690): card receded `text-secondary-label`; unread, woke or input `text-foreground`; failed `text-foreground/95`; else `text-foreground/90`. Slim receded `text-secondary-label/70`; active, woke or input `text-foreground`; unread `text-muted-foreground`; else `text-secondary-label/70`.

### 3.2 Mapping of every requested status to fields (web v2)

| UI state | Driving fields | Rule / literal values | Where |
|---|---|---|---|
| Working | `activityRunStatus`, `status`, `pendingBackgroundTasks` | `runtime.status` in `preparing, queued, starting, running, waiting` (note: run `waiting` means "turn finished, checkpoint capture pending": a completed turn is persisted as `waiting` with `completedAt: null` until capture flips it to `completed`, `apps/server/src/orchestration-v2/RunExecutionService.ts:642-653`) | Sidebar.logic.ts:990-995 |
| Goal (variant of Working) | `goal.status` | `"active"` while working | Sidebar.tsx:1297 |
| Waiting (background) | `pendingBackgroundTasks`, `status` | runtime parked at `"idle"`: some task kind in `subagent, monitor, background_task` and `status !== "failed"`. Includes PR watches (monitor) even on a thread that never ran | models.ts:176-199 |
| Awaiting approval | `pendingRuntimeRequest.kind` | not `user_input`, not `auth_refresh` | models.ts:255-258 |
| Awaiting input / question | `pendingRuntimeRequest.kind` | `"user_input"` (including secret requests) | models.ts:259 |
| Plan ready | not shown in v2 | v2 has no plan-ready state; only the legacy pill shows "Plan Ready" (3.4) | |
| Failed | `status`, `lastErrorClass` | `runtime.status === "failed"` and class not `usage_limit` | Sidebar.logic.ts:999-1001 |
| Limited (usage limit) | `status`, `lastErrorClass` | `runtime.status === "failed"` and `lastErrorClass === "usage_limit"` | same |
| Interrupted / cancelled / rolled_back | `status` | fall through to `ready`; shows `Done` if unseen (see 4.2: Done does not check that the run completed successfully) | |
| Queued | `status` | unheld queued run gives `runtime.status === "queued"` -> Working. Held queues (`queueHeld: true`) are skipped by `latestUnheldRun`, so they never make a row look busy | shared/orchestrationV2ThreadError.ts:115-124 |
| Completed-unread (Done) | `latestRunCompletedAt`, `lastVisitedAt` | `hasUnseenCompletion` | Sidebar.logic.ts:773-782 |
| Woke | `snoozedUntil`, `snoozedAt`, `latestRun`, runtime, `lastVisitedAt`, `settledOverride` | see 4.7 | Sidebar.tsx:1274-1279 |
| Idle / ready | none of the above | runtime null, or terminal status | |
| Settled | `settledOverride` | `=== "settled"` and env capability `threadSettlement === true` -> Settled shelf (slim row) | Sidebar.tsx:2802, 2831 |
| Snoozed | `snoozedUntil`, `snoozedAt`, request/failure/completion fields | `effectiveSnoozed(thread, now)` and capability `threadSnooze === true` -> Snoozed shelf | Sidebar.tsx:2803, 2830 |
| Archived | `archivedAt` | `!== null` -> excluded from the sidebar entirely | Sidebar.logic.ts:570-583 |
| Pinned | `pinnedAt` | `!= null` -> pinned block (no capability gate for classification) and pin glyph | Sidebar.tsx:2832 |
| Worktree setup | `activityRunStatus` | no distinct row state; a `preparing` run is Working (legacy pill: "Connecting") | |
| Regenerating title | `titleRegeneration` | `!= null` -> title at `opacity-55`, `aria-busy`, sr-only "Regenerating title" | Sidebar.tsx:1212, 1691, 1838-1842, 2153-2157 |
| Unsent draft | client-local composer draft store | pen icon, tinted row; not shown on the open thread | Sidebar.tsx:1225, 1737-1753 |

Edge (code consequence, UNVERIFIED in practice): if `latestRunId === null` but `activeProviderThreadId !== null`, `shellRuntime` returns `status: thread.activityRunStatus ?? "idle"`, so such a row would read as `Waiting`.

### 3.3 Mobile Thread List v2

`resolveThreadListV2Status` (`apps/mobile/src/features/threads/threadListV2.ts:185-207`) is identical to the web function, same literals (type at 79-86).

Labels (`thread-list-v2-items.tsx:74-111`, SF Symbol names usable directly on macOS):
- approval: `Approval`, `exclamationmark.shield`, `text-warning-foreground`
- input: `Input`, `questionmark.bubble`, `text-adaptive-indigo-600-300`
- working: `Working`, `circle.dashed`, `text-adaptive-sky-600-400` (label becomes `Goal` when `goal.status === "active"`, 629-633)
- failed: `Failed`, `exclamationmark.circle`, `text-danger-foreground`
- limited: `Limited`, `exclamationmark.circle`, `text-warning-foreground`
- Done: `checkmark.circle`, `text-adaptive-emerald-700-300`, only when `status === "ready" && threadHasUnseenCompletion(thread)` (627)

Differences from web:
- No label for `waiting` (it is absent from `STATUS_LABEL_BY_STATUS`), and the precomputed time label is blank for any non-ready card (`resolveThreadListV2ItemTimeLabel`, threadListV2.ts:460-476), so a Waiting card shows neither label nor time.
- No mobile Woke indicator (grep for `Woke`/`threadWokeAt` in `apps/mobile/src` found nothing).
- Recede rule is narrower: `shouldRecedeThreadRow` (`thread-row-emphasis.ts:8-13`) recedes only working/waiting rows that are not selected; receded content uses opacity 0.55 (thread-list-v2-items.tsx:1180-1184) and regular title weight (1036).
- Failed/limited cards show `runtime.lastError` text on the third line instead of branch (1056-1069).
- No working duration on list rows.

### 3.4 Legacy web pill (opt-in sidebar and command palette)

`resolveThreadStatusPill` (Sidebar.logic.ts:1164-1242), labels from `ThreadStatusPill` (626-638), in priority order:
1. `Pending Approval` (amber) when `hasPendingApprovals`
2. `Awaiting Input` (indigo) when `hasPendingUserInput`
3. `Working` (sky, pulse) when `runtime.status` is `running` or `waiting`
4. `Connecting` (sky, pulse) when `preparing`, `starting`, or `queued`
5. `Waiting` (muted) when `backgroundWorkHoldsCompletion(pendingBackgroundTasks)`
6. `Plan Ready` (violet) when `!hasPendingUserInput && interactionMode === "plan" && isLatestRunSettled(latestRun, runtime) && hasActionableProposedPlan` (`isLatestRunSettled`, `apps/web/src/session-logic.ts:220-234`: latest run not in `preparing|queued|starting|running|waiting` and `runtime.activeRunId !== latestRun.runId`)
7. `Completed` (emerald) when `hasUnseenCompletion`
8. otherwise null

The pill never shows failures. Project-level aggregate `resolveProjectStatusIndicator` (1244-1260) picks the max by `THREAD_STATUS_PRIORITY` (640-648): Pending Approval 5, Awaiting Input 4, Working 3, Connecting 3, Waiting 2.5, Plan Ready 2, Completed 1. Used by `LegacySidebar.tsx:1359-1465` and by `ThreadRowLeadingStatus` in the command palette (`ThreadStatusIndicators.tsx:875-977`, used at `CommandPalette.tsx:1429`).

### 3.5 Working section (beta) classification

Setting `sidebarWorkingShelfEnabled` (settings.ts:471-473, default false, per device; mobile pref `workingShelfEnabled`). `isThreadWorking` (`packages/client-runtime/src/state/threadInbox.ts:20-34`):

```ts
if (thread.hasPendingApprovals || thread.hasPendingUserInput) return false;
if (!threadRuntimeIsActive(thread.runtime) && thread.runtime?.status !== "idle") return false;
const run = thread.latestRun;
const runSettled = run !== null && run.status not in [preparing, queued, starting, running, waiting]
  && thread.runtime?.activeRunId !== run.runId;
return !(thread.interactionMode === "plan" && thread.hasActionableProposedPlan && runSettled);
```

So Working shelf = working or parked-idle threads, except a settled plan-mode run with an actionable plan. Only inbox (active) threads fold; pinned, snoozed and settled keep their sections.

### 3.6 Desktop/web notifications (for reference)

`ThreadNotificationCoordinator.tsx:119-200` reuses `resolveSidebarThreadStatus`, skips subagent threads (126), upgrades `ready` with `latestRun.status === "failed"` to `failed` (134-135), notifies "Approval needed", "Input needed", "Thread failed", "Usage limit reached", or "Thread completed" (completion only for `latestRun.status === "completed"`).

---

## 4. Q2: unread, read receipts, `thread.visit`, `thread.mark-unread`

### 4.1 What the data is

- One watermark per thread on its environment's server: `lastVisitedAt` in the thread payload, projected onto the shell (`ProjectionStore.ts:1514, 1769`). New threads start with `lastVisitedAt: null` (`Orchestrator.ts:2222`; forks too, `ThreadForkService.ts:112`). The internal doc calls this the read receipt (`docs/internals/performance-regressions.md:80-81`).
- It is not per message, not per device, and not per user. Every device connected to that environment sees the same value.
- Capability `threadVisitedTracking` (`packages/contracts/src/environment.ts:164-168`): server understands `thread.visit` and `thread.mark-unread` and projects `lastVisitedAt`. Without it, web keeps a browser-local watermark; mobile shows no unread at all.

### 4.2 Unread computation

Effective watermark on web: `resolveThreadLastVisitedAt(serverLastVisitedAt, localLastVisitedAt)` (Sidebar.logic.ts:762-771):

```ts
if (serverLastVisitedAt === undefined) return localLastVisitedAt;
return serverLastVisitedAt ?? undefined;
```

The server value is authoritative whenever the field exists (including explicit rewinds from mark-unread). Local values come from `useUiStateStore().threadLastVisitedAtById[scopedThreadKey]` (Sidebar.tsx:1213-1214).

`hasUnseenCompletion` (Sidebar.logic.ts:773-782):

```ts
if (!thread.latestRun?.completedAt) return false;
const completedAt = Date.parse(thread.latestRun.completedAt);
if (Number.isNaN(completedAt)) return false;
if (!thread.lastVisitedAt) return false;
const lastVisitedAt = Date.parse(thread.lastVisitedAt);
if (Number.isNaN(lastVisitedAt)) return true;
return completedAt > lastVisitedAt;
```

Rules that follow:
- Never-visited (`null`) counts as read (comment Sidebar.tsx:1261-1262). Agent-created threads the user never opened never show Done.
- It compares the presented latest run's `completedAt`, so Done appears for any terminal run that has `completedAt` (completed, interrupted, cancelled, rolled_back), not only successful completion. Failed/limited outrank it in the label.
- When a newer run is queued or started, `latestRun` becomes that run (`completedAt` null) and Done disappears.
- Mobile `threadHasUnseenCompletion` (threadListV2.ts:172-183) is the same function body but only ever reads `thread.lastVisitedAt` (no local fallback), so servers without tracking never show unread on mobile.

### 4.3 When `thread.visit` is dispatched

Command shape (contracts 2723-2733): `{ type: "thread.visit", commandId, threadId, visitedAt: IsoDateTime }`. Client builder `visitThread` (`packages/client-runtime/src/operations/commands.ts:539-548`).

Web, in `ChatView` for the route thread (`apps/web/src/components/ChatView.tsx:2938-3000`, constant `VISIT_DISPATCH_THROTTLE_MS = 10_000` at 622):

```ts
const threadUpdatedAt = Date.parse(serverThread.updatedAt);
const effectiveLastVisitedAt = resolveThreadLastVisitedAt(serverThread.lastVisitedAt, activeThreadLocalLastVisitedAt);
const lastVisitedAt = effectiveLastVisitedAt ? Date.parse(effectiveLastVisitedAt) : NaN;
if (!Number.isNaN(lastVisitedAt) && lastVisitedAt >= threadUpdatedAt) return;
if (serverThread.lastVisitedAt !== undefined) {
  const dispatchKey = `${routeThreadKey}:${serverThread.updatedAt}`;
  if (lastDispatchedVisitRef.current === dispatchKey) return;
  // dispatch() sends visitThreadMutation({ threadId, visitedAt: serverThread.updatedAt })
  const hasUnseenCompletion = !Number.isNaN(latestRunCompletedAtMs) &&
    (Number.isNaN(lastVisitedAt) || latestRunCompletedAtMs > lastVisitedAt);
  const elapsed = Date.now() - lastVisitDispatchAtRef.current;
  if (hasUnseenCompletion || elapsed >= VISIT_DISPATCH_THROTTLE_MS) { dispatch(); return; }
  const timer = setTimeout(dispatch, VISIT_DISPATCH_THROTTLE_MS - elapsed);
  return () => clearTimeout(timer);
}
markThreadVisited(scopedThreadKey(...), serverThread.updatedAt); // local fallback
```

Effect deps: `updatedAt`, `lastVisitedAt`, `latestRun.completedAt`, route key, local watermark (2990-3000). Behaviour:
- Fires on open and on every shell change while the thread is the route thread. No window focus or visibility gating in this effect.
- `visitedAt` is the shell's `updatedAt` (the activity clock), not "now".
- Skips when the watermark already covers `updatedAt`.
- Dedupes per `routeKey:updatedAt`; this also keeps a mark-unread sticky on the open thread until new activity lands or the thread is reopened (comment 2952-2955).
- Unseen completion publishes immediately; other changes ride a trailing 10 s throttle that always carries the newest watermark.
- Web subtlety (code-read): `ChatView` is not keyed per server thread (`ThreadRouteView.tsx:85-97, 182-189`: key is undefined unless a promoted draft), so `lastVisitDispatchAtRef` is shared across thread switches. Opening thread B within 10 s of a visit for thread A delays B's visit by the remainder unless B has an unseen completion. UNVERIFIED at runtime.
- Local fallback `markThreadVisited` (`apps/web/src/uiStateStore.ts:250-271`) keeps the max of stored and supplied, persisted to localStorage key `t3code:ui-state:v1` (6) with a 500 ms debounced write (248).

Mobile, in `ThreadDetailScreen` (`apps/mobile/src/features/threads/ThreadDetailScreen.tsx:849-901`): same logic with three differences: it requires `showContent` (defaults true, 806; no caller passes it) and `lastVisitedAt !== undefined` (no local fallback); the throttle resets per thread (`previous.threadKey !== selectedThreadKey` dispatches immediately, 886); throttle literal `10_000`.

Other visit dispatches:
- Woke acknowledgement: `useAcknowledgeThreadWoke` (`apps/web/src/hooks/useThreadActions.ts:234-256`) sends `thread.visit` with `visitedAt = wokeAt` when `threadVisitedTracking` is supported, else writes the local watermark. Triggered by clicking the Woke pill (Sidebar.tsx:1401-1409) or the open-thread Woke banner (ChatView.tsx:7149-7153).
- One-way migration `useThreadVisitedMigration` (`apps/web/src/hooks/useThreadVisitedMigration.ts:22-45`, imported by `AppSidebarLayout.tsx:35`): once per thread per page load, if the shell has the field and the browser-local watermark is newer than the server value, sends `thread.visit` with the local value.

### 4.4 When `thread.mark-unread` is dispatched

Command (contracts 2734-2738): `{ type: "thread.mark-unread", commandId, threadId }`. Builder at `operations/commands.ts:550-558`.

- Web only: sidebar context menu item "Mark unread" (`threadActionMenu.logic.ts:182`, handler Sidebar.tsx:4748-4750) and multi-select "Mark unread (N)" (Sidebar.logic.ts:551-564, Sidebar.tsx:4338, 4445). `useMarkThreadUnread` (useThreadActions.ts:208-232) dispatches the command when `readEnvironmentSupportsVisitedTracking` (`apps/web/src/state/entities.ts:285-290`), else rewinds the local watermark to `latestRun.completedAt - 1 ms` (`uiStateStore.ts:273-296`).
- The web menu treats mark-unread as not requiring the operate scope (`threadActionRequiresOperate`, threadActionMenu.logic.ts:105-115), but the server RPC `dispatchCommand` requires `AuthOrchestrationOperateScope` (`apps/server/src/auth/RpcAuthorization.ts:45`), so a read-only connection's server-tracked mark-unread would be rejected. No per-command exception was found (UNVERIFIED beyond that map).
- Mobile has no mark-unread action (grep found none).

### 4.5 Server semantics

- `dispatchThreadVisit` (`Orchestrator.ts:2267-2308`): rejects deleted threads and unparseable timestamps. `movesForward = stored === null || supplied > stored`. Always emits `thread.visited`; payload carries the new watermark only when it moves forward. Never touches `updatedAt`. Visit and mark-unread skip v1 transcript hydration (`ThreadManagementService.ts:74-80`).
- Mark-unread (`Orchestrator.ts:2760-2772`, mutation 2898-2899): loads runs, takes `projection.runs.at(-1)?.completedAt`; if null, fails with "has no completed run to mark unread"; else sets `lastVisitedAt = completedAt - 1 ms`. This is the only operation that moves the watermark backwards. Note it reads the last element of `runs` (assumed ordinal order, UNVERIFIED), which can differ from the shell's presented latest run (for example a held queued run at the end makes it fail).

### 4.6 Multi-device behaviour

- Any device viewing a thread advances the shared watermark, so Done clears on every device of that environment.
- Mark-unread on one device makes the thread unread everywhere. Devices that already dispatched a visit for the current `updatedAt` will not re-visit until new activity (dedupe key), so the unread survives on them even while open; a device that opens the thread fresh visits immediately and clears it.
- Threads on different environments keep separate watermarks on their own servers.
- Pre-tracking servers: web uses per-browser localStorage only (not synced); mobile shows nothing.

### 4.7 Woke indicator (snooze wake signal)

`threadWokeAt` (`packages/client-runtime/src/state/threadSettled.ts:185-211`):
- `snoozedUntil` null or unparseable -> null.
- If `threadRaisedHandWhileSnoozed`: return `latestRun.completedAt` when `snoozedAt` is set and latest run status is `completed` with `completedAt > snoozedAt`; otherwise `runtime.updatedAt ?? snoozedAt`.
- Else return `snoozedUntil` if it is `<= now`, else null.

`threadRaisedHandWhileSnoozed` (103-127): true for pending approval or input; true for runtime `failed` (or v1 `error`) when `snoozedAt` is null or `runtime.updatedAt > snoozedAt`; true when `snoozedAt` is set and the latest run is `completed` with `completedAt > snoozedAt`. Note `runtime.updatedAt` is the shell `updatedAt`, so any later activity (even a rename) counts as a fresh failure on the client; the server's twin `isSnoozed` uses run completion instead (`ThreadSettlementService.ts:166-197`, comment 170-173).

Web `isWoke` (Sidebar.tsx:1274-1279): `wokeAt !== null && (lastVisited === null || lastVisited < wokeAt) && settledOverride !== "settled"`. Computed for every section (5313-5317). Consequences: completion and failure wakes are cleared by an ordinary visit (watermark `updatedAt` reaches the wake time); a pure timer wake usually is not, because `updatedAt` is older than `snoozedUntil` (comment 1267-1273: "Timer wakes survive a mere visit"). It clears on clicking the pill (visit at `wokeAt`), sending a message (server clears snooze), settling, archiving, or waking/unsnoozing.

---

## 5. Q3: relative timestamps

### 5.1 Which timestamp each row shows

Web sidebar v2 (Sidebar.tsx):
- Card rows (active, pinned, working) show the time only when there is no top label (status `ready`, not unread, not woke) (2032-2084). Value: `threadTimeLabel` (332-335) = `thread.latestUserMessageAt ?? thread.updatedAt`, compacted.
- Settled slim rows: `settledTimeLabel` (340-343) using `resolveSettledThreadTimestamp` (the same key the shelf sorts by).
- Snoozed slim rows: the wake countdown `snoozeWakeLabel(snoozedUntil, now)` instead of a time (1862-1867, computed at 5306-5312).
- Slim rows with `isWoke` show the Woke button instead of a time (1868-1886).
- Search result rows: `threadTimeLabel` (2349-2351).
- Working cards: live elapsed duration instead of a time (see 5.4).

`resolveSettledThreadTimestamp` (`packages/client-runtime/src/state/threadSort.ts:30-51`):

```ts
if (thread.settledAt != null && toSortableTimestamp(thread.settledAt) !== null) return thread.settledAt;
// else the latest valid of:
[thread.latestUserMessageAt, thread.latestRun?.requestedAt, thread.latestRun?.startedAt, thread.latestRun?.completedAt]
// else thread.updatedAt if valid, else null
```

Note: auto-settlement stamps `settledAt` with the last activity time, not the sweep time (see section 10), so auto-settled rows read as "how long since activity".

Mobile (`resolveThreadListV2ItemTimeLabel`, threadListV2.ts:460-476):
- Blank when the snoozed countdown is shown, or for any card whose status is not `ready` or which is unread.
- Settled slim rows: `resolveSettledThreadTimestamp(thread)`; otherwise `latestUserMessageAt ?? updatedAt ?? createdAt`.
- Test: `apps/mobile/src/features/threads/threadListV2.test.ts:2016-2049` (ready card "5m", working card "", settled "3d", snoozed "" with countdown "2h").

Legacy web: full label with suffix, `formatRelativeTimeLabel(latestUserMessageAt ?? updatedAt ?? createdAt)` (`LegacySidebar.tsx:967-968`).

Archived (Settings, Archived threads): "Archived <rel> · Created <rel>" using `archivedAt ?? createdAt` and `createdAt` (`apps/web/src/components/settings/SettingsPanels.tsx:3580-3585`). Mobile archive uses `relativeTime(archivedAt ?? updatedAt)` (`apps/mobile/src/features/archive/ArchivedThreadsScreen.tsx:200`).

### 5.2 Formatting functions

Web `formatRelativeTime` (`apps/web/src/timestampFormat.ts:235-248`), English only, floor division, no weeks/months/years, not localized:
- diff < 0 -> `just now`
- < 60 s -> `just now`
- < 60 min -> `<m>m ago`
- < 24 h -> `<h>h ago`
- else -> `<d>d ago`

`formatRelativeTimeLabel` (250-254) joins value and suffix. The sidebar compacts it with `compactSidebarTimeLabel` (Sidebar.tsx:327-330): `"just now"` -> `"now"`, strip trailing `" ago"`. Result set: `now`, `5m`, `2h`, `3d`, `400d`. Invalid timestamp -> `""`.

Mobile `relativeTime` (`apps/mobile/src/lib/time.ts:1-20`): invalid -> `<1m`; under 60 s (and future) -> `<1m`; else `Nm`, `Nh`, `Nd` with floor.

The `timestampFormat` client setting (`"locale"|"12-hour"|"24-hour"`, default `"locale"`, settings.ts:49-51) does not affect relative labels; it affects wall-clock labels such as snooze preset times (`formatShortTimestamp`, timestampFormat.ts:153-157; locale from the desktop bridge when available, 31-54).

### 5.3 Refresh cadence

Web:
- `useNowMinute` (`apps/web/src/hooks/useNowMinute.ts:1-66`): one module-level timer, first fire aligned to the next UTC minute boundary (`60_000 - (Date.now() % 60_000)`), then `setInterval(60_000)`; value is `new Date().toISOString().slice(0, 16)`.
- In the sidebar the minute value is only a dependency of the section partition memo (Sidebar.tsx:2577, 2883-2891). Snooze classification inside it reads a precise clock (`preciseNow`, 2780).
- A one-shot timer fires at the earliest snooze wake (`delay = min(max(0, wakeAt - now) + 50, 2_147_483_647)`, 2942-2955) to re-partition exactly at the boundary.
- `WorkingDuration` re-renders itself every 1000 ms (363-373).
- Observation (code-read, UNVERIFIED at runtime): `SidebarThreadRow` is `memo`ized and receives no per-minute prop (callbacks have stable deps, e.g. `planForwardNavigation` deps at 3345), so an idle row's `5m` label refreshes only when the row re-renders for some other reason. A native client should refresh labels on a minute timer.

Mobile:
- Minute clock refreshed on screen focus and by `setInterval(60_000)` (not aligned) (`HomeScreen.tsx:499-511`).
- Time labels and countdowns are precomputed per list item at each tick (`buildThreadListV2ListItems`, threadListV2.ts:516-550; recycler equality 403-454 only re-renders rows whose text changed). Countdown uses the minute-quantized clock (`snoozeLabelNow: `${nowMinute}:00.000Z``, HomeScreen.tsx:656).
- Snooze boundary timer with the same clamp formula (HomeScreen.tsx:611-621).

### 5.4 Other time labels on rows

- Working duration: `formatWorkingDurationLabel` (Sidebar.logic.ts:1156-1162): `<s>s` under 60 s, `<m>m` under 60 min, else `<h>h <m>m`; counts from `resolveWorkingStartedAt(thread)` (1150-1154 -> models.ts:320-336), i.e. the activity-owning run's work start (wakes do not reset it). Renders nothing when the start is null.
- Snooze countdown `snoozeWakeLabel` (threadSettled.ts:310-319): invalid or `<= 0` -> `now`; under 1 h -> `ceil(minutes)` with minimum 1, `Nm`; under 24 h -> `ceil(hours)` `Nh`; else `ceil(days)` `Nd`.
- Snooze presets `resolveSnoozePresets` (threadSettled.ts:255-303): `In 1 hour` (+1 h), `In 3 hours` (+3 h), `This evening` (18:00 local, only if more than 1 h away), `Tomorrow` (09:00 next local day, calendar-day advance), `Next week` (09:00 next Monday; dropped when equal to Tomorrow, i.e. on Sundays). Web relabels times with `timestampFormat` (`apps/web/src/components/Sidebar.snooze.ts:18-34`). Custom snooze `resolveCustomSnooze` (330-346): local date `YYYY-MM-DD` + `HH:MM` (rejects rolled-over and nonexistent DST times) or a duration in minutes/hours/days (day = 24 h); must be in the future.

---

## 6. Q4: sections and sort order

### 6.1 Visible set

Web `filterSidebarV2VisibleThreads` (Sidebar.logic.ts:570-583): `archivedAt === null`, not `lineage.relationshipToParent === "subagent"`, and (if a project scope is selected) `${environmentId}:${projectId}` in the scope's member set. Input is `useThreadShells()` = `threadShellsAtom` over all enabled environments (`apps/web/src/state/entities.ts:90-94`; `packages/client-runtime/src/state/threadShell.ts:187-200`). Mobile uses `navigationThreadShellsAtom` (threadShell.ts:202-215: same archived and subagent exclusion; `apps/mobile/src/state/entities.ts:88`) plus environment, project and search filters in `buildThreadListV2Items` (threadListV2.ts:711-731).

### 6.2 Section classification

`resolveSidebarThreadSection` (Sidebar.logic.ts:138-147), sections `"pinned" | "active" | "working" | "snoozed" | "settled"` (134):

```ts
if (input.snoozed) return "snoozed";
if (input.settled) return "settled";
if (input.pinned) return "pinned";
return "active";
```

Inputs at Sidebar.tsx:2829-2833: `snoozed = capabilities.threadSnooze === true && effectiveSnoozed(thread, { now: preciseNow })`; `settled = capabilities.threadSettlement === true && thread.settledOverride === "settled"`; `pinned = thread.pinnedAt != null`. Active threads go to `working` instead when the beta is on and `isSidebarThreadWorking(thread)` (2790-2791).

`effectiveSnoozed` (threadSettled.ts:162-172): `snoozedUntil` set, parseable, strictly in the future, and no raised hand (4.7). Timer wakes are derived: the server sends nothing when `snoozedUntil` passes.

Precedence: snooze beats settled and pinned until it wakes; settled beats pinned (the server clears the pin on settle anyway). Settled classification uses only `settledOverride === "settled"`, never `settledAt`. `settledOverride === "active"` (explicit un-settle) is just active.

Mobile (threadListV2.ts:732-757): same order, plus a thread with a message waiting in the local outbox stays active even if the server settled it (`hasQueuedMessages`, 746-749).

### 6.3 Render order and structure

Web list items (`sidebarListItems`, Sidebar.tsx:3781-3829), preceded by the client-local draft block (5394-5404; drafts sorted by `session.createdAt` descending with a divider, 1026, 1059-1063):

1. marker `pinned-header` (label "Pinned", visible only while dragging)
2. pinned rows
3. marker `pinned-divider` (label "Active", visible only while dragging)
4. marker `active-placeholder`, then active rows
5. if any working threads: `working-header` ("Working (N)" collapsed, "Working" expanded) + visible working rows
6. if any snoozed threads: `snoozed-header` ("Snoozed (N)" / "Snoozed") + visible snoozed rows
7. always (when the list is non-empty): `settled-header` ("Settled (N)" / "Settled", so "Settled (0)" is possible) + `settled-placeholder` + rendered settled rows
8. "Show N more" button when the settled shelf is expanded and rows are hidden (5531-5542)

Labels at 5457-5499. The first shelf header gets `mt-auto` (shelves sit at the bottom of the sidebar). Empty state: "No projects yet", "No threads in <project> yet", or "No threads yet" (5548-5575).

Row variants (5258-5265): `card` for active, pinned, working; `slim` for snoozed and settled. Row primary action (`variantAction`, 5274-5280): snoozed -> `unsnooze` (Wake), settled -> `unsettle`, else `settle`.

Mobile (`buildThreadListV2ListItems`, threadListV2.ts:484-610): pinned cards, active cards, client-local pending new tasks (with a "PENDING" divider), then Working, Snoozed, Settled shelves, each header only when its count is above 0. Header text `${label} (${count})` when collapsed, bare when expanded (`thread-list-v2-items.tsx:232-252`). Show more row: "Show more (N settled hidden)" (272-296).

### 6.4 Comparators per section

Pinned: `sortPinnedThreadsByOrderKey` (threadSort.ts:306-339; web alias `sortPinnedThreadsForSidebar`, Sidebar.logic.ts:1070):

```ts
keyed   = threads with pinOrderKey != null, sorted by key with plain string < / > (code-unit order),
          tie: id.localeCompare, then (environmentId ?? "").localeCompare
keyless = rest, sorted by createdAt descending (invalid -> 0), same tiebreak
result  = [...keyed, ...keyless]
```

Keyless pins sort by `createdAt`, not `pinnedAt`. Capability only gates dragging, never the sort (comment Sidebar.tsx:2844-2848).

Active (default): `sortActiveThreadsByOrderKey` (threadSort.ts:343-376; web alias `sortThreadsForSidebar`, Sidebar.logic.ts:1059; mobile `sortThreadsForListV2`, threadListV2.ts:218-228):

```ts
keyless (activeOrderKey == null) come before keyed
keyless vs keyless: activeThreadAnchorTimestampMs descending
   = max(createdAt, unsettledAt) (invalid -> 0)            (threadSort.ts:129-137)
keyed vs keyed: activeOrderKey ascending, plain string comparison
tie: id.localeCompare, then environmentId.localeCompare
```

So new threads and freshly un-settled threads appear on top of the arranged run, and activity never moves a row. Test: `packages/client-runtime/src/state/threadSort.test.ts:402-433` (`["reopened", "new", "arranged-first", "arranged-last"]`).

Active with the Working beta on: `sortInboxThreadsByReturn(active, inboxReturns.returnedAt)` (threadInbox.ts:45-62): newest first by `max(createdAt, unsettledAt, latestRun.requestedAt, latestRun.completedAt, observedReturnAt)`, tie id then environmentId (`sortNewestFirst`, 91-101). `observedReturnAt` comes from `createInboxReturnTracker` (110-145), a device-local memory of when each thread left the Working state (first observation only sets a baseline). Saved active keys are kept but ignored while the beta is on.

Working shelf: `sortWorkingThreadsBySend` (threadInbox.ts:74-89): newest first by `max(createdAt, latestUserAuthoredMessageAt)`; if the server omits `latestUserAuthoredMessageAt` (undefined), uses `latestRun.requestedAt` instead. Same tiebreak.

Snoozed shelf: ascending by `snoozedUntil` (soonest wake first) via `firstValidTimestampMs` (invalid -> 0) (Sidebar.tsx:2875-2879; Sidebar.logic.ts:1048-1057). No explicit tiebreak (stable sort keeps input order). Mobile same (threadListV2.ts:766-769).

Settled shelf: `sortSettledThreads` (threadSort.ts:56-69): descending by `resolveSettledThreadTimestamp` (null -> 0), tie `id.localeCompare` ascending, no environment tiebreak.

Legacy web (per project): `sortThreads` (threadSort.ts:139-152) with `sidebarThreadSortOrder` (`"updated_at"` default or `"created_at"`, settings.ts:61-65): `updated_at` uses `latestUserMessageAt` (fallback newest user message in `messages`, then `updatedAt`, then `createdAt`) (82-107); `created_at` uses `createdAt` then `updatedAt` (109-119). Descending, tie by id descending.

Swift note: order keys must be compared by raw code units (JavaScript `<`), not locale-aware. Id tiebreaks use `localeCompare` (locale-aware); for ASCII ids a plain compare will almost always agree but this is not guaranteed (UNVERIFIED equivalence).

### 6.5 Order keys (`pinOrderKey`, `activeOrderKey`)

Fractional index over the alphabet `PIN_ORDER_DIGITS = "abcdefghijklmnopqrstuvwxyz"` (threadSort.ts:185):
- Valid key: non-empty, only those letters, last character not `"a"` (`isValidPinOrderKey`, 187-195).
- `pinOrderKeyBetween(before, after)` (223-230) returns a key strictly between neighbours (null bounds mean open ends), or null when keys are corrupt or out of order. Midpoint algorithm `pinOrderMidpoint` (199-217).
- `generateSpreadPinOrderKeys(count)` (234-255): width starts at 2 and grows while `26^width <= (count + 1) * 2`; evenly spaced values `round(step * (i+1))`, skipping values whose last digit would be `"a"`.
- `planPinnedReorder({ orderedIds, keysById, movedId })` (265-298): when both displayed neighbours of the moved row are keyed (or absent), one write to the moved thread only; keys belonging to hidden rows are reserved and skipped. If a neighbour is keyless (legacy) or keys are corrupt, the whole visible section is rewritten with spread keys (one-time materialization). Active reordering uses the same planner with `activeOrderKey`.
- `planPinnedMove` (384-400): mobile Move up / Move down, swap with displayed neighbour, same single-write semantics.
- Web reserves keys of every shell, including rows hidden by the project scope (`pinnedKeysById`/`activeKeysById` from all shells, Sidebar.tsx:3928-3946).
- New pins from any menu: `orderKey = pinOrderKeyBetween(null, smallest existing pinOrderKey across all shells of all environments)`, only when the environment has `threadPinReorder` (web `topOfPinnedRunOrderKey`, useThreadActions.ts:116-123, used at 715-723; mobile `useThreadListActions.ts:406-418`). Otherwise the pin is sent keyless.
- The server stores keys verbatim (`TrimmedNonEmptyString`, contracts 2700, 2715, 2721); it does not validate the alphabet (`Orchestrator.ts:2857-2859, 2883-2893`).

Commands: `thread.pin { orderKey? }` (contracts 2693-2701), `thread.pin.reorder { orderKey }` (2707-2716), `thread.active.reorder { orderKey }` (2717-2722). Capabilities: `threadPinning`, `threadPinReorder`, `threadActiveReorder` (environment.ts:150-157).

### 6.6 How lifecycle actions change ordering fields (server, `Orchestrator.ts`)

- Preconditions (2511-2549): settle/unsettle/snooze/unsnooze/auto-settle.set/pin/unpin/pin.reorder/active.reorder rejected on archived threads; `thread.pin.reorder` rejected when not pinned; `thread.active.reorder` rejected when pinned or `settledOverride === "settled"`.
- `thread.settle` (precheck 2585-2651, mutation 2786-2803): rejected if any run is `preparing|queued|starting|running|waiting` (automatic notification/delegated-completion queued runs excepted and cancelled) or any pending request other than message-capable `user_input` (those are cancelled). Sets `settledOverride: "settled"`, `settledAt` (kept if already settled and unpinned, else `command.settledAt ?? now`), clears PR watches, `unsettledAt: null`, `pinnedAt: null`, `pinOrderKey: null`, `activeOrderKey: null`, bumps `updatedAt` unless already settled. It does not touch `snoozedUntil`/`snoozedAt` (see section 11).
- `thread.unsettle` (2804-2813): `settledOverride: "active"`, `settledAt: null`, `unsettledAt = existing if already "active" else now`; this is what puts an un-settled thread back on top (keyless, anchored at `unsettledAt`).
- `thread.snooze` (2728-2759, 2814-2827): requires a future time, no pending runtime request, no queued run. `snoozedAt` kept when the wake time is unchanged, else now; `limitRecovery.snooze = false`.
- `thread.unsnooze` (2828-2836): clears both snooze fields.
- `thread.pin` (2845-2867): `pinnedAt` kept if already pinned; `pinOrderKey` set only on a fresh pin; promotes an explicit settle (`settledOverride "settled" -> "active"`, `settledAt: null`); clears snooze; `activeOrderKey` untouched. The server does not set `unsettledAt` here, while the client optimistic pin does (threadCommands.ts:465-471) (minor mismatch).
- `thread.unpin` (2868-2878): clears `pinnedAt` and `pinOrderKey`; `activeOrderKey` untouched, so an unpinned thread returns to its old active slot if it had one, else to the keyless top group.
- `thread.pin.reorder` (2879-2889), `thread.active.reorder` (2890-2897): set the key.
- `message.dispatch` (4562-4600): if `settledOverride !== null`, emits `thread.unsettled` with `settledOverride: null`, `settledAt: null`, `unsettledAt = (was "active" ? existing : now)`; if snoozed, emits `thread.unsnoozed`. Sending a message therefore wakes and un-settles.
- `thread.archive` / `thread.unarchive` (2775-2785): set/clear `archivedAt`.

User doc agrees for ordering: "New threads appear above the active threads you have arranged. Settling clears a thread's active position, so using Un-settle returns it to the top. Pinning and snoozing preserve its active position until you move it again. Thread activity does not change the order. The settled shelf continues to use settlement time." (`docs/user/thread-sidebar.md:97-100`).

### 6.7 Drag and drop (web) and arrangement (mobile)

- Rows and section markers form one sortable list. `resolveSidebarDropTarget` (Sidebar.logic.ts:202-230) derives the destination section from markers; working and snoozed are never destinations. `resolveSidebarDropVerb` (265-275) gives the badge: `pin`, `unpin`, `settle`, `unsettle`, `wake` ("Pin", "Unpin", "Settle", "Un-settle", "Wake", Sidebar.tsx:1071-1102).
- `planSidebarThreadDrop` (Sidebar.logic.ts:305-421) yields `none`, `reorder-pinned`, `pin`, `move-active` (flags `unpin`, `unsettle`, `unsnooze`), or `settle`. With the Working beta on, active drops only change lifecycle, never write keys (`activeTimeOrdered`, 359-372).
- Execution (Sidebar.tsx:3999-4172): settle -> `thread.settle`; move-active -> `thread.unpin`, `thread.unsettle {reason:"user"}`, `thread.unsnooze {reason:"user"}` as needed, then each `thread.active.reorder`; pin -> `thread.pin {orderKey}` then extra `thread.pin.reorder` writes; reorder-pinned -> `thread.pin.reorder` writes. Stops at the first failure. An `optimisticDrop` holds the row in place until canonical state shows every assigned key (2751-2764, 2811-2827).
- Rows are draggable only when their environment has `threadPinning && threadPinReorder` (2808-2810); active placement also needs `threadActiveReorder` (2805). Working-shelf rows are never draggable (5382-5387). Drag distance 6 px (745).
- Mobile: "Arrange threads..." sheet and Move up / Move down in the row menu (`thread-list-v2-items.tsx:715-750`), gated per environment by reorder capabilities; Move availability precomputed per section (`HomeScreen.tsx:531-565`), disabled for the active section while the Working beta is on.

### 6.8 Paging and collapse

- Web settled tail: `SETTLED_TAIL_INITIAL_COUNT = 10`, `SETTLED_TAIL_PAGE_COUNT = 25` (Sidebar.tsx:296-297); resets when the project scope changes (2961-2967); the open route thread is always appended if hidden (2968-2984).
- Web shelf expansion persisted per browser in localStorage: `t3code:sidebar:settled-expanded`, `t3code:sidebar:snoozed-expanded`, `t3code:sidebar:working-expanded` (299-301), all default `false` (collapsed). A collapsed shelf still renders the open route thread (3001-3006, 3027-3032, 3049-3054).
- Mobile: same 10/25 constants (threadListV2.ts:161-162); expansion persisted in mobile preferences `threadListSettledShelfExpanded`, `threadListSnoozedShelfExpanded`, `threadListWorkingShelfExpanded`, each default collapsed (`use-thread-list-v2-shelf-preferences.ts:12-60`); selected thread stays visible on a collapsed shelf (threadListV2.ts:770-800).

### 6.9 Archived

Not in the sidebar. Web: Settings, Archived threads (`ArchivedThreadsPanel`, SettingsPanels.tsx:3408-3600), grouped by project, sorted by `archivedAt ?? createdAt` descending (string compare), tie id descending (3455-3459). Mobile: `buildArchivedThreadGroups` (`apps/mobile/src/features/archive/archivedThreadList.ts:31-106`), newest/oldest by `archivedAt ?? updatedAt`, then title, then id. Data via the separate archived shell snapshot/stream (`packages/client-runtime/src/state/archivedThreads.ts:40-69`).

---

## 7. Q5: grouping by project

### 7.1 Shared grouping model (`packages/client-runtime/src/state/projectGrouping.ts`)

- Physical key: `${environmentId}:${normalizeProjectPathForComparison(workspaceRoot)}` (`derivePhysicalProjectKeyFromPath`, 69-71). Duplicates of the same physical key collapse to the freshest project (`updatedAt`, then `createdAt`, tie larger id) (205-220, 271-274); identity is taken from the freshest member that has a `repositoryIdentity` (222-243).
- Mode per project: `settings.sidebarProjectGroupingOverrides[physicalKey] ?? settings.sidebarProjectGroupingMode` (`resolveProjectGroupingMode`, 91-99). Modes (`SidebarProjectGroupingMode`, settings.ts:67-73, default `"repository"`):
  - `"separate"`: logical key = physical key, so each path on each environment is its own project.
  - `"repository"`: logical key = `repositoryGroupingKeyOf(identity)` = `identity.origin?.canonicalKey ?? identity.canonicalKey` (`packages/contracts/src/environment.ts:262-264`), so all checkouts of one repository group together across environments and paths (a fork with its own origin stays separate).
  - `"repository_path"`: canonical key plus `::<repo-relative path>` when the project is a subfolder of the repo root (`deriveRepositoryScopedKey`, 101-124), so monorepo subprojects stay separate.
  - Projects without `repositoryIdentity` fall back to the physical key (`deriveLogicalProjectKey`, 126-145).
- Legacy UI descriptions: "Projects from the same repository share one sidebar row." / "Projects group only when both the repository and repo-relative path match." / "Every project path gets its own sidebar row." (`LegacySidebar.tsx:284-291`).
- Group label (`buildProjectGroups` 309-326, `deriveProjectGroupLabel` 159-190): one member -> its `title`; several members -> the shared title if all members share one title that differs from the repo display name and repo name; else the single shared `repositoryGroupingDisplayNameOf` (origin display name or canonical key for forks, else `identity.displayName`, environment.ts:267-271); else the single shared `identity.name`; else the representative's title. Representative = member in the preferred (primary) environment, else the first.
- Grouping is by repository/path, not by environment. Environment shows up only through physical keys and presence flags (`environmentPresence: "local-only"|"remote-only"|"mixed"`, `sidebarProjectGrouping.ts:67-134`).

### 7.2 Web sidebar v2

- No project headers in the thread list. Project groups (`buildSidebarProjectSnapshots`, Sidebar.tsx:2524-2540) feed: (a) the per-row project label `group.displayName` (2565-2575), (b) the project scope combobox ("All projects" plus groups, 2595-2604), (c) the scratch machine label rule (`projectGroupsSpanEnvironments`, 2608-2625).
- Project scope: selecting a group filters rows to its `memberProjectRefs` (2664-2674). Persisted locally as `sidebarProjectScopeKey` in `t3code:ui-state:v1` (`uiStateStore.ts:30, 42, 231, 332-341`); falls back to all projects when the group disappears, but only after every environment has a live project snapshot (Sidebar.tsx:2678-2683). Selection is cleared on scope change (2712-2714).
- Group order (scope menu): `sortSidebarV2ProjectGroups` (Sidebar.logic.ts:1392-1405) -> `sortLogicalProjectsForSidebar` (1354-1390) with `sidebarProjectSortOrder` (`"updated_at"` default, `"created_at"`, `"manual"`, settings.ts:57-59). Timestamp per group = max over its visible threads of `getThreadSortTimestamp` (latest user message, or createdAt); without threads, project `createdAt` or `updatedAt ?? createdAt` (1288-1304). Descending; tie title then projectKey. `"manual"` keeps the local drag order `projectOrder` (`orderItemsByPreferredIds`, Sidebar.tsx:2511-2523; stored in `t3code:ui-state:v1`).
- Grouping settings are client settings stored per device (`t3code:client-settings:v1` in browser localStorage, `apps/web/src/clientPersistenceStorage.ts:5`, or the desktop bridge, `localApi.ts:64-66`); not synced.

### 7.3 Legacy web sidebar

- One collapsible header per logical project group; rows inside sorted by `sortThreads` with `sidebarThreadSortOrder`; preview limited to `sidebarThreadPreviewCount` (1 to 15, settings.ts:74-80, 487-489) with expand; a collapsed project still shows the active route thread (`LegacySidebar.tsx:1359-1465`).
- Collapse persisted locally: `projectExpandedById` in `t3code:ui-state:v1`, keyed by `[projectKey, ...physicalProjectKeys, ...legacy cwd keys]` (276-282), default expanded (`resolveProjectExpanded`, uiStateStore.ts:349-360).
- Ignores pin, settle and snooze entirely (no matches for `pinnedAt`, `settled`, `snooz` in LegacySidebar.tsx) and filters archived threads only (1378).

### 7.4 Mobile

- Flat list, no project headers; each row shows the group title (`v2ProjectTitleByProjectKey`, HomeScreen.tsx:393-407).
- Project scopes via `buildHomeProjectScopes` (`apps/mobile/src/features/home/homeThreadList.ts:43-66`), built after the environment filter, with mode from mobile preferences (`projectGroupingMode`, fallback from legacy boolean `projectGroupingEnabled`) and no per-project overrides (`apps/mobile/src/state/project-grouping.logic.ts:11-20`).
- Scope order `sortHomeProjectScopes` (homeThreadList.ts:88-146): latest activity across threads (`getThreadSortTimestamp`) and pending tasks, descending; tie title, key. `"manual"` is not supported (mapped to `"updated_at"`, home-list-options.ts:26-34). Environment filter and sort order live in React state (not persisted, home-list-options.ts:45-57); the selected project key arrives as a prop (HomeScreen.tsx:388; persistence UNVERIFIED).

### 7.5 Multiple environments

All enabled environments' shells are merged into one list; ties are broken by id then environmentId. Capabilities are checked per thread's environment. A row on a non-primary environment shows that machine's glyph (web) or `branch · environmentLabel` (mobile, only when more than one saved connection exists, HomeScreen.tsx:761-765). Order keys from different servers interleave by plain string comparison.

---

## 8. Q6: subagent and child threads

- Subagent threads (`lineage.relationshipToParent === "subagent"`) are hidden from the sidebar on web v2 (`isSidebarSubagentThread`, Sidebar.logic.ts:566-583, applied at Sidebar.tsx:2783 and to project ordering at 1392-1405) and mobile (threadListV2.ts:711; `navigationThreadShellsAtom`, threadShell.ts:202-215). Notifications skip them too (ThreadNotificationCoordinator.tsx:126). This covers both kinds:
  - Provider-native subagents: `isProviderNativeSubagentThread` = `relationshipToParent === "subagent" && creationSource === "provider"` (contracts 447-451). The provider owns the conversation; they cannot take messages and cannot watch PRs (Orchestrator.ts:2417-2426). Their status comes from a runless root turn (`deriveProviderSubagentStatus`, `packages/client-runtime/src/state/threadExecution.ts:134-147`; labels `SUBAGENT_STATUS_LABELS` 188-198: Idle, Working, Waiting, Completed, Interrupted, Failed, Cancelled).
  - T3 `delegate_task` children: `creationSource: "mcp"` with relationship `"subagent"`; hidden by the same filter.
- Not nested in the list. They appear from the parent: the web thread details relationships control (`apps/web/src/components/chat/ThreadRelationshipsControl.tsx`, layout not read in detail, UNVERIFIED) built on `deriveThreadRelationshipGraph` (`packages/client-runtime/src/state/threadRelationships.ts:48-117`: edges parent -> child of kind `"subagent"` or `"fork"` with status `activityRunStatus ?? status`, plus `projection.subagents` and context transfers); mobile `ThreadAgentsSheet`.
- The parent row reflects subagents through `pendingBackgroundTasks` kind `"subagent"` (with `childThreadId`): it reads Waiting after its own run ends while subagents are pending (3.2).
- Forks (`relationshipToParent === "fork"`) are ordinary top-level rows; `getSidebarForkParentThreadId` (Sidebar.logic.ts:585-594) has no non-test caller.
- Legacy web sidebar does not filter subagent threads (its source `threadShellsForProjectRefsAtom`, threadShell.ts:141-172, has no lineage filter, and LegacySidebar.tsx has no `relationshipToParent` check); whether they appear there in practice is UNVERIFIED.
- Subagent titles are formatted by `formatSubagentDisplayTitle` wherever presented (models.ts:233-236).

---

## 9. Q7: everything else rendered on a row

### 9.1 Web card row (Sidebar.tsx:1955-2217; height 4.875rem plus padding)

Line 1 (1989-2150):
- Draft pen (`SquarePenIcon`, warning tint) when the thread has unsent composer content and is not the open thread (client-local, 1225, 1737-1753). Row also gets a warning tint (1589-1590).
- Project favicon (project from `${environmentId}:${projectId}`) and project display name (logical group label) (1991-2005).
- Pin glyph when `pinnedAt != null`; a clickable "Unpin thread" button when `threadPinning` is supported and the connection can operate; while dragging it shows only if still over the pinned section (1754-1789).
- Status slot: label per 3.1, or relative time when no label. On hover or keyboard focus the read-only label fades and actions appear (Woke stays visible): Discard draft (X), Snooze (clock, preset menu plus "Custom...") when `canOperate && threadSnooze && canSnooze(thread, now)`, Settle (check + "Settle") when `threadSettlement` is supported (2086-2143).
  - `canSnooze` (threadSettled.ts:137-153): false with a pending approval/input or a queued turn start. `hasQueuedTurnStart` (51-80): runtime `preparing|queued|starting`, or a `latestUserMessageAt` within `QUEUED_TURN_START_GRACE_MS = 2 * 60 * 1000` (39) of now (absolute value) that is newer than every latest-run timestamp.

Line 2: title, single line, truncated; dimmed during title regeneration (2151-2158). No fallback text: the sidebar renders `thread.title` as-is. The server guarantees a non-empty title (`OrchestrationV2AppThread.title: TrimmedNonEmptyString`, contracts 368) even though the shell schema says `Schema.String`. Clients seed titles with `deriveThreadTitleSeed` (`packages/client-runtime/src/operations/threadTitle.ts:14-33`: message text truncated to 50 chars plus `...` via `truncate`, `packages/shared/src/String.ts:1-8`; else `Image: <name>`; else fallback labels; else `New thread`). Other surfaces fall back to `"Untitled thread"` (`apps/web/src/components/CommandPalette.logic.ts:34`).

Line 3 (2159-2210):
- If `branch`: `ThreadWorktreeIndicator` (`FolderGit2Icon`, only when `worktreePath` is non-empty; tooltip `Worktree: <path> (<branch>)`, ThreadStatusIndicators.tsx:783-815) then the branch, middle-truncated.
- Else, for scratch (no-project) threads when projects span several environments: machine glyph plus environment label (`scratchMachineLabelFor`, 2612-2625; `isScratchProject`, `packages/client-runtime/src/state/projects.ts:139-146`).
- Terminal indicator (teal `TerminalIcon`, pulsing) when any terminal session for the thread has a running subprocess. Source is the environment terminal metadata query, not the shell (`useThreadRunningTerminalIds`, `apps/web/src/state/terminalSessions.ts:172-200`; `selectRunningSubprocessTerminalIds`, client-runtime `terminalSession.ts:58-64`).
- PR badge (9.3).
- Diff stats: never rendered. `latestRunDiff` returns null; shells carry no diff data (2220-2227).
- Remote machine glyph when `environmentId !== primaryEnvironmentId` and no scratch label (1374-1375, 2196-2204). With no primary environment (hosted app) every row is remote.
- Provider stack (9.4).

Hover card tooltip (`SidebarThreadTooltip`, 428-566): title; project; environment label and machine; branch; "You're currently checked out on another branch." when a local (non-worktree) thread's branch differs from the live git status of the project cwd (`resolveLocalCheckoutBranchMismatch`, uses a live VCS query, 1243-1254, 1350-1355); provider icon and model label (`<model> · <instance>` when the instance badge applies); "Handed off from <names>" from `providerInstanceHistory`; "<n> terminal process(es) running"; "Usage limit reached" (warning) or "Error occurred" (error) whenever `runtime.lastError` is set, even if status is not failed; PR mini list when the multi-PR capability is on.

Live data leases: PR summary and git status queries run only for rows near the viewport (`useSidebarRowSubscriptionLease`, Sidebar.logic.ts:74-108, 160 px overscan at 72), with last values retained (`useRetainedValue`, 113-120).

### 9.2 Web slim row (settled and snoozed; Sidebar.tsx:1791-1953; 36 px)

Favicon (40% opacity and grayscale unless hovered or active), draft pen, title, pin glyph, terminal icon, PR badge, right slot: snoozed countdown (`text-info-foreground`), or Woke button, or time (`settledTimeLabel` for settled). Hover action: Wake (`AlarmClockOffIcon`) for snoozed, Un-settle (`Undo2Icon`) for settled. Settled rows dim all text when not hovered (1584).

### 9.3 PR badge rules

Web (1255-1259, 1702-1721; `ThreadStatusIndicators.tsx:83-125, 169-210, 434-452`; `packages/shared/src/threadPullRequests.ts`):
- With capability `threadPullRequests` (`useSupportsMultiplePullRequests`, `apps/web/src/hooks/useSupportsMultiplePullRequests.ts:4-10`): uses persisted `pullRequests` snapshots, no network. Links with `source: "stack-dismissed"` are hidden (`visibleThreadPullRequests`, 81-85). Current link (`resolveThreadCurrentPullRequest`, 113-142): the single open link; else for several open links the highest open layer of the most recently linked chain (stack); else the top of a single chain; else the most recently updated terminal link. Unsynced links (`snapshot: null`) count as open.
- Badge (`resolveThreadPullRequestBadge`, 291-309): state `draft` if every visible link is open and draft, `open` if any open (unsynced counts as open), `merged` if all merged, else `closed`. Kind `stack` (text = number of layers) when more than one visible link forms one chain; else `pull-request` with text = PR number, or `+N` (N = others + 1) when unrelated links exist. Stacks and multi-link badges open the thread's pull requests panel; a single link opens the PR.
- Without the capability: legacy `linkedPullRequest` or `branchPullRequest` resolved by a live summary query while the row is leased (83-125).
- Tooltip `<shortName> #<n> - <state>: <title>` (`prStatusIndicator`, 434-452).

Mobile (`apps/mobile/src/state/thread-pr-presentation.ts:38-124`; row 1129-1152): glyph `square.3.layers.3d` for stacks, else `arrow.triangle.pull`; colors open emerald, closed rose (multi) or muted (single), merged violet, draft or unknown muted; label PR number, `+N`, or layer count; monospace.

### 9.4 Provider stack and instance badge

Web `SidebarProviderStack` (379-426): `resolveThreadProviderStack` (up to 3); earlier owners drawn small, grayscale, 35% opacity; current one at 60% opacity with an instance badge when `shouldShowInstanceBadge` (`packages/client-runtime/src/state/providerInstanceDisplay.ts:79-102`: instance has an accent color, or more than one configured instance shares its driver, with ACP registry instances compared by agent id). Provider entries resolve per environment (2550-2558). Mobile: earlier drivers at 30% opacity, current `ProviderInstanceIcon` with badge (`thread-list-v2-items.tsx:1153-1173`; drivers via `resolveThreadListV2ProviderDrivers`, threadListV2.ts:52-66).

### 9.5 Mobile rows

Card (`thread-list-v2-items.tsx:966-1176`): line 1 favicon, project title, outbox icon (client-local queued messages), pin glyph (pinned block only), status label or time; line 2 title up to 2 lines; optional search excerpt; line 3 `lastError` for failed/limited, else `branch` (monospace) and `· environmentLabel` with machine symbol, then PR badge and provider stack. Slim (1220-1296): dimmed favicon, one-line title, outbox icon, countdown or time (monospace).

### 9.6 Fields not used by rows

`latestVisibleMessage` (always null), `itemCount`/`visibleItemCount` (used only to decide whether a thread has started, `ChatView.logic.ts:994`), `historyOrigin`, `forkedFrom`, `usageLimitResetAt`, `limitRecovery`, `autoSettleDisabledAt` (menu state only), `settledOverride === "active"` (not visually distinct). No queued-run count exists in the shell; web shows none.

---

## 10. Server rules that move rows without user action

Auto-settlement (`apps/server/src/orchestration-v2/ThreadSettlementService.ts`):
- Candidates from `ProjectionStore.getSettlementCandidates` (5425-5538): not deleted, not archived, `settledOverride` null, `pinnedAt` null, `autoSettleDisabledAt` null, no run in `preparing|starting|running|waiting`, no pending runtime request.
- `isAutoSettlementCandidate` (139-164) re-checks those, plus no `activityRunStatus`, no background work that holds completion, no queued turn start (`threadHasQueuedTurnStart`, 86-108, two-minute grace), and not still parked on a snooze (a snoozed thread that woke on error or completion can settle).
- `resolveAutoSettlementAt` (199-243): any open or unsynced visible PR link blocks. A merged (if `sidebarAutoSettleOnMerge`) or closed PR settles when its terminal time is at or after the later of `createdAt` and `latestUserAuthoredMessageAt` (`pullRequestSettles`, 115-136). Otherwise inactivity: last activity = max(`latestUserMessageAt`, latest run requested/started/completed) older than `sidebarAutoSettleAfterDays` days. Returned `settledAt` is the activity time (or `createdAt`).
- Dispatched as `thread.auto-settle { snapshotAt: thread.updatedAt, settledAt }` (contracts 2662-2668); the Orchestrator rejects it if any override exists or `updatedAt` moved past the snapshot (Orchestrator.ts:10157-10190), then applies the normal settle mutation.
- These settings are shared server settings (`packages/client-runtime/src/state/sharedSettings.ts:24-33`).

Other automatic moves: a new message (including agent wakes and PR-watch notes queued via `message.dispatch`) un-settles and wakes the thread (Orchestrator.ts:4562-4600); limit recovery may set or clear `snoozedUntil` (2900-2937).

---

## 11. Discrepancies, gotchas, and UNVERIFIED items

1. Docs vs code on pinning and auto-settlement: `docs/user/thread-sidebar.md:65` says "Pinning does not prevent automatic settlement." Code excludes pinned threads (`ThreadSettlementService.ts:144`, `ProjectionStore.ts:5464`), tests assert it (`ThreadSettlementService.test.ts:106-124`), and the internal doc says the worker reads "active, unpinned threads" (`docs/internals/performance-regressions.md:74`). Trust the code: pinned threads never auto-settle.
2. Server `thread.settle` keeps `snoozedUntil`/`snoozedAt` (`Orchestrator.ts:2786-2803`), while the client optimistic settle clears them (`threadCommands.ts:411-428`) and the web Undo comment assumes the server drops the snooze (`useThreadActions.ts:788-789`). Because snoozed outranks settled, settling a still-snoozed thread (context menu, or dragging it onto the Settled header) may show it in Settled until the server echo and then back in Snoozed until it wakes. UNVERIFIED at runtime.
3. `thread.active-reordered` and `thread.pull-request-synced` bump the SQL row `updatedAt` (section 1.3). UNVERIFIED at runtime. Effect: `updatedAt`-based fallbacks (time label when `latestUserMessageAt` is null, visit watermark) move.
4. Only the newest pending request is summarized; if an older approval and a newer question are both pending, the row says Input.
5. Done ignores run outcome (interrupted or cancelled runs also produce Done if unseen).
6. Web visit throttle is shared across thread switches (4.3). UNVERIFIED at runtime.
7. Web memoized rows may show stale relative times (5.3). UNVERIFIED at runtime.
8. Mobile shows no label and no time on Waiting cards, has no Woke indicator, no mark-unread, and no local unread fallback.
9. Mark-unread is offered to read-only web connections but the RPC requires operate scope (4.4).
10. Server mark-unread uses `runs.at(-1)` rather than the presented latest run (4.5). Ordering of `runs` UNVERIFIED.
11. `runtime` becomes `"idle"` (Waiting) for a thread with `activeProviderThreadId` but no runs (3.2 edge). UNVERIFIED in practice.
12. The WebSocket wire encoding of `DateTimeUtc` fields was not checked (1.1). UNVERIFIED.
13. Client-side `threadRaisedHandWhileSnoozed` treats any `updatedAt` newer than `snoozedAt` on a failed thread as a fresh failure (even a rename); the server twin does not (4.7).
14. `latestUserMessageAt` includes non-user-authored user-role messages (wakes, notifications), so the card time can move without the user sending anything.

---

## 12. Native implementation checklist (derived from the above)

1. Store shells per environment keyed by `${environmentId}:${threadId}`; apply `thread.updated` as full replacement; drop events with `sequence <= snapshotSequence`; remove on `thread.removed` (active stream).
2. Build `runtime` exactly like `shellRuntime`; derive `hasPendingApprovals`/`hasPendingUserInput` from `pendingRuntimeRequest.kind`; synthesize `latestRun` like `presentThreadShell`.
3. Status via `resolveSidebarThreadStatus`; label precedence per 3.1; Woke and Done only when `ready`; recede per `shouldRecedeSidebarThread`.
4. Unread via `hasUnseenCompletion` with the server `lastVisitedAt` (field present) or a local watermark (field absent; capability `threadVisitedTracking`).
5. Send `thread.visit { visitedAt: shell.updatedAt }` while a thread is open: skip if watermark >= `updatedAt`, dedupe per `updatedAt`, immediate on unseen completion, else 10 s trailing throttle. Send `thread.visit { visitedAt: wokeAt }` to dismiss Woke. Offer Mark unread -> `thread.mark-unread` (needs operate scope).
6. Sections per `resolveSidebarThreadSection` gated by `threadSnooze`/`threadSettlement`; hide archived and `relationshipToParent === "subagent"`.
7. Sort: pinned by `sortPinnedThreadsByOrderKey`, active by `sortActiveThreadsByOrderKey`, snoozed by `snoozedUntil` ascending, settled by `resolveSettledThreadTimestamp` descending; use code-unit comparison for keys.
8. Write order with the fractional-key planner (`planPinnedReorder`), reserving keys of hidden rows; pin new threads at `pinOrderKeyBetween(null, minKey)` when `threadPinReorder` is supported.
9. Relative time per 5.1/5.2 (`now`, `Nm`, `Nh`, `Nd`), refreshed every minute; snooze countdown per `snoozeWakeLabel`; re-partition at the earliest snooze wake.
10. Keep shelf expansion, project scope, grouping mode, and the Working beta toggle local to the device.
