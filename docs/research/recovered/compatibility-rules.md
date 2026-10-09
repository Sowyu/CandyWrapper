# Compatibility rules for orchestration v2 clients

Source: `/Users/mrm/CandyWrapper-research/t3code`, tag `v0.0.46-nightly.20261009.2861` (HEAD `3b6af0bd1`). All paths below are repo-relative. Line numbers were read directly from the files. Effect is `effect@4.0.1` with a local patch (`pnpm-lock.yaml:145`, `patches/effect@4.0.1.patch`). `node_modules` is not installed, so anything that depends on Effect library internals (RpcServer decode options, RPC frame format, HttpApi error status codes) is marked UNVERIFIED.

Goal of this document: the rules a third-party native client must follow so that threads, projects and settings it creates or edits look right in the official web, desktop and mobile clients, and vice versa.

---

## 1. Provider capability flags

### 1.1 Exact shape

`packages/contracts/src/orchestrationV2.ts`:

- `OrchestrationV2SessionCapabilities` (193-199): `supportsMultipleProviderThreadsPerSession`, `supportsModelSwitchInSession`, `supportsProviderSwitchingViaHandoff`, `supportsRuntimeModeSwitchInSession`, `pendingRequestsSurviveRestart` (all boolean).
- `OrchestrationV2ThreadCapabilities` (202-210): `canCreateEmptyThread`, `canReadThreadSnapshot`, `canRollbackThread`, `canForkThread`, `canForkFromTurn`, `canForkFromSubagentThread`, `exposesNativeThreadId`.
- `OrchestrationV2TurnCapabilities` (213-224): `exposesNativeTurnId`, `emitsTurnStarted`, `emitsTurnCompleted`, `supportsInterrupt`, `supportsActiveSteering`, `activeSteeringInterruptsTools` (OPTIONAL, 219-220, "Some native steering mechanisms cancel pending tools before consuming the message"), `supportsSteeringByInterruptRestart`, `supportsQueuedMessages`, `terminalStatusQuality: "strong" | "weak" | "none"`.
- `OrchestrationV2StreamingCapabilities` (227-233): `streamsAssistantText`, `streamsReasoning`, `streamsToolOutput`, `streamsPlanText`, `emitsMessageCompleted`.
- `OrchestrationV2ToolCapabilities` (236-243): `exposesToolItemIds`, `emitsToolStarted`, `emitsToolCompleted`, `emitsToolOutput`, `supportsMcpTools`, `supportsDynamicToolCallbacks`.
- `OrchestrationV2ApprovalCapabilities` (246-254): `supportsCommandApproval`, `supportsFileReadApproval`, `supportsFileChangeApproval`, `supportsApplyPatchApproval`, `approvalsHaveNativeRequestIds`, `approvalCallbacksAreLiveOnly`, `approvalsCanOriginateFromSubagents`.
- `OrchestrationV2PlanningCapabilities` (257-263): `emitsPlanUpdated`, `emitsTodoList`, `emitsProposedPlan`, `supportsStructuredQuestions`, `planDeltasHaveItemIds`.
- `OrchestrationV2SubagentCapabilities` (266-273): `supportsSubagents`, `exposesSubagentThreadIds`, `emitsSubagentLifecycle`, `canWaitForSubagents`, `canCloseSubagents`, `canForkSubagentThread`.
- `OrchestrationV2ContextCapabilities` (276-285): `acceptsSystemContext`, `acceptsDeveloperContext`, `acceptsSyntheticUserContext`, `canGenerateSummaries`, `canConsumeHandoffSummaries`, `supportsDeltaHandoff`, `supportsFullThreadHandoff`, `maxRecommendedHandoffChars: PositiveInt | null`.
- `OrchestrationV2CheckpointCapabilities` (288-294): `appCanCheckpointFilesystem`, `supportsNestedCheckpointScopes`, `providerCanRollbackConversation`, `providerRollbackReturnsSnapshot`, `providerCanReadConversationSnapshot`.
- `OrchestrationV2RuntimePolicyCapabilities` (298-307): `enforcement: "native" | "client-boundary"`. Doc comment: "native" providers confine their own execution; "client-boundary" providers only have policy applied where T3 mediates the work, so sandbox guarantees are reduced.
- `OrchestrationV2IdentityCapabilities` (311-316): `nativeThreadIds`, `nativeTurnIds`, `nativeItemIds`, `nativeRequestIds`, each `"strong" | "weak" | "none"`.
- `OrchestrationV2ProviderCapabilities` (319-336) groups the above as `sessions, threads, turns, streaming, tools, approvals, planning, subagents, context, checkpointing, identity, runtimePolicy`. `runtimePolicy` has a decoding default:

```ts
runtimePolicy: OrchestrationV2RuntimePolicyCapabilities.pipe(
  Schema.withDecodingDefault(Effect.succeed({ enforcement: "client-boundary" as const })),
),
```

Persisted capability snapshots without `runtimePolicy` decode to `client-boundary` (test `packages/contracts/src/orchestrationV2.test.ts:412`, assertion near 507).

The design doc `docs/orchestration-v2/provider-capability-system.md:7-21` lists the same groups but predates `runtimePolicy` and `activeSteeringInterruptsTools`. It states "Capabilities should be versioned and emitted by each adapter at session start" (line 23). It also defines degradation policies (216-246) and capability-driven UI intent (274-284). The doc's "versioned" statement is not implemented as a version field anywhere in the schema.

### 1.2 Where a client gets capabilities

- The full capability object exists only on `OrchestrationV2ProviderSession.capabilities` (`orchestrationV2.ts:726-737`, field at 733).
- A client sees it in the thread projection array `providerSessions` (`OrchestrationV2ThreadProjection`, `orchestrationV2.ts:1785-1810`, field 1791) and in the domain events `provider-session.attached` and `provider-session.updated` (1712-1716). `provider-session.detached` (1717-1721) carries only `providerSessionId`, and the official client removes the session from its projection (`packages/client-runtime/src/state/orchestrationV2Projection.ts:220-226`). After a detach the capability evidence for that thread is gone.
- `OrchestrationV2ProviderThread` (871-907) carries no capabilities.
- The server provider list (`ServerConfig.providers`, `packages/contracts/src/server.ts:240-313`) carries NO `OrchestrationV2ProviderCapabilities`. It carries coarse presentation flags instead: `showInteractionModeToggle`, `reportsContextWindow`, `supportedRuntimeModes` (ForwardCompatibleArray), `requiresNewThreadForModelChange`, `supportsConversationRollback`, `supportsTextGeneration`, `nativeSessions {canList, canLoad, canResume, canDelete?}`, `continuation.groupKey`, `availability`, `enabled`, `installed`, `status`, `auth`, and per model `capabilities.optionDescriptors` (`ServerProviderModel`, 75-87; `ModelCapabilities`, `packages/contracts/src/model.ts:125-128`).
- Consequence: before the first turn of a thread (no provider session yet) a client has no capability data for it. Official helpers fall back to permissive defaults in that case (see 1.3).
- Server side, the adapter exposes `getCapabilities()` and `planSelectionTransition()` (`packages/provider-core/src/server/ProviderAdapter.ts:628-641`). The switch planner prefers the "negotiated" capabilities of the newest session record for the current instance, even a stopped one (`apps/server/src/orchestration-v2/ProviderSwitchService.ts:99-103`).

### 1.3 Which official client code gates which UI on which flag

Provider capability reads (all in `packages/client-runtime/src/state/threadWorkflows.ts` unless noted):

- Session resolution for a thread: `resolveThreadProviderSession` (66-88): active run's provider thread, else `thread.activeProviderThreadId`, else any provider thread of this app thread with a session, else the last session that is not `stopped`/`error`.
- Provider switching (model picker lock): `threadSupportsProviderHandoff` (90-108) returns `session.capabilities.sessions.supportsProviderSwitchingViaHandoff` when a session exists. With no session: false if a run is active; true if `historyOrigin === "v1_import"` or there are no runs (97); otherwise true only if the active provider thread for the thread's current instance has a `nativeThreadRef`. Used by web `apps/web/src/components/ChatView.tsx:2136-2139` and 3019 (`modelPickerLockedProvider`) and by mobile `apps/mobile/src/state/thread-provider-switching.ts:28`.
- Web model change block reasons: `getStartedThreadModelChangeBlockReason` (`apps/web/src/components/ChatView.logic.ts:1046-1092`): instance change allowed only when `supportsProviderSwitchingViaHandoff === true` ("Start a new chat to switch providers"); same-instance model change blocked when either `ServerProvider.requiresNewThreadForModelChange === true`. Web also refuses a cross-instance pick when both instances advertise different `continuation.groupKey` and handoff is unsupported (`ChatView.tsx:10724-10727`).
- Queue reorder and promote-to-steer: `deriveThreadQueueWorkflowState` (127-163): `canReorder = turns.supportsQueuedMessages === true` (157); `canPromoteToSteer` requires the active run `running` with a running provider turn on its active attempt, and `supportsActiveSteering || supportsSteeringByInterruptRestart` (158-161). Used by `apps/web/src/components/chat/QueuedRunsControl.tsx:86`.
- Fork from an assistant message: `canForkProjectedAssistantItem` (165-185): requires a completed `assistant_message` with a `runId`. If capabilities are undefined it returns true (173-178, "Keep the portable server-side fallback available when capability evidence is absent"). Otherwise native fork needs `threads.canForkThread && threads.canForkFromTurn && identity.nativeThreadIds === "strong"`, else `context.supportsFullThreadHandoff`. Used by web `MessagesTimeline.tsx:2807` and mobile `ThreadFeed.tsx:332-335`.
- Detach session: `canDetachThreadProviderSession` (187-190) uses session status only.
- Default dispatch mode when the server lacks `serverResolvedCommandContext` (`packages/client-runtime/src/operations/commands.ts:712-751`): active run plus "auto" picks `steer_active` if `supportsActiveSteering`, else `queue_after_active` if `supportsQueuedMessages`, else `restart_active` if `supportsSteeringByInterruptRestart`, else `queue_after_active`.

Things official clients do NOT gate on provider capabilities:

- Interrupt/Stop: no client reads `supportsInterrupt` (grep across `packages/client-runtime/src`, `apps/web/src`, `apps/mobile/src`). The server enforces it (`apps/server/src/orchestration-v2/Orchestrator.ts:8989-8996`, `CommandPolicy.ts:272-277`).
- Rollback: web gates the revert UI on the provider presentation flag `ServerProvider.supportsConversationRollback !== false` (`ChatView.tsx:3290-3293`), not on session capabilities. Drivers that set it false: `apps/server/src/provider/AntigravityProvider.ts:156`, `packages/provider-cursor/src/server/status.ts:28`, `packages/provider-grok/src/server/status.ts:50`. The server enforces with adapter capabilities: `threads.canRollbackThread && checkpointing.providerCanRollbackConversation` and `checkpointing.providerRollbackReturnsSnapshot` (`CommandPolicy.ts:306-325`, called at `Orchestrator.ts:9141-9160`).
- Plan mode: gated on `ServerProvider.showInteractionModeToggle !== false` plus a client setting (`ChatView.logic.ts:626-639`; mobile `apps/mobile/src/state/legacy-plan-mode.ts:7-33`, `use-composer-command-menu.ts:77`). No client reads `capabilities.planning`.
- Approvals: no client reads `capabilities.approvals`. Pending approvals come from `runtimeRequests` with `status === "pending"` joined to `approval_request` turn items (`packages/client-runtime/src/state/threadRequests.ts:66-115`). `responseCapability.type` maps to `"live"` or `"not_resumable"` (110); user-input requests with `responseCapability.type === "message"` or item `responseMode === "message"` are dismissible (89-92). Web skips responding when `not_resumable` (`ChatView.tsx:10148-10153`).
- Images and files: there is no per-provider image capability anywhere (grep found no such field). Uploads are gated on environment capabilities `attachmentUploads`, `fileAttachments.maxUploadBytes`, `questionAttachments` (`ChatView.tsx:3025-3029`, 8945-8947, 9291-9299; mobile `apps/mobile/src/lib/attachmentUpload.ts:67-70`).
- Runtime modes: filtered by `ServerProvider.supportedRuntimeModes` when non-empty (`apps/web/src/components/chat/ChatComposer.tsx:2161-2164`; mobile `thread-settings-options.ts:40-43`).
- Context meter: `ServerProvider.reportsContextWindow` (`ChatComposer.tsx:2390`).

### 1.4 Server-side enforcement (what a client may send anyway)

`apps/server/src/orchestration-v2/CommandPolicy.ts`:

- Capability codes (51-62): `queued_messages, active_steering, interrupt, interrupt_restart_steering, native_fork, fork_from_turn, rollback, rollback_snapshot, context_handoff, strong_terminal_status`.
- `resolveMessageDispatchIntent` (120-165): when `deliveryIntent` is present the server resolves the mode against serialized state: no active run -> `start_immediately`; `steer` -> `steer_active`; `restart` -> `restart_active`; run `preparing`/`starting` -> queue; otherwise the same capability ladder as the client (155-164).
- `ensureQueuedMessages` (238-247), `decideSteeringExecution` (249-270, interrupt-restart needs both `supportsInterrupt` and `supportsSteeringByInterruptRestart`), `ensureInterrupt` (272-277), `ensureNativeFork` (279-304), `ensureRollback` (306-325), `ensureContextHandoff` (327-363: needs `canConsumeHandoffSummaries` and `acceptsSyntheticUserContext`, plus delta or full support), `decideForkExecution` (365-387), `decideMessageDispatch` (389-480: `start_immediately` with an active run becomes queue, which requires `supportsQueuedMessages`).
- User-facing rejection prose per capability: `apps/server/src/orchestration-v2/UserFacingErrors.ts:15-31`.
- Mailbox (delegated completion) deliveries steer only when `supportsActiveSteering && activeSteeringInterruptsTools !== true` (`Orchestrator.ts:4748-4755`).

### 1.5 Provider instance, model and ModelSelection contracts

- `ProviderDriverKind` and `ProviderInstanceId` (`packages/contracts/src/providerInstance.ts:40-83`): trimmed non-empty slug, max 64 chars, pattern `^[a-zA-Z][a-zA-Z0-9_-]*$`. Both are OPEN slugs, not closed enums (16-28): "parsing any of those payloads must always succeed, and the runtime is responsible for marking the unknown driver/instance as unavailable". Built-in default instance id equals the driver kind (`defaultInstanceIdForDriver`, 160-168). Examples of driver kinds: `codex`, `claudeAgent`, `cursor`, `grok`, `muse`, `pi`, `acpRegistry`, `opencode`, `antigravity` (`packages/contracts/src/model.ts:146-153`, 175-187).
- `ProviderInstanceConfig` (`providerInstance.ts:124-131`): `driver`, `displayName?`, `accentColor?`, `environment?`, `enabled?`, `config?: Unknown`. Doc: envelopes for unknown drivers "are preserved verbatim so they round-trip" (115-123).
- `ModelSelection` (`packages/contracts/src/modelSelection.ts`):

```ts
const ModelSelectionWire = Schema.Struct({
  instanceId: ProviderInstanceId,
  model: TrimmedNonEmptyString,
  options: Schema.optionalKey(ProviderOptionSelections),
});
```

  Decoding also accepts the historical `{ provider, model }` shape and prefers `instanceId` over `provider` (22-50). Decode and encode copy ONLY `instanceId`, `model`, `options` (38-59), so any other key in a model selection is dropped. Tests: `packages/contracts/src/modelSelection.test.ts:25-120`.
- `ProviderOptionSelections` (`model.ts:46-53`, 90-93): canonical `Array<{ id: TrimmedNonEmptyString, value: TrimmedNonEmptyString | boolean }>`; legacy object form `{ effort: "max", fastMode: true }` is accepted on decode and normalized to the array; numbers, null and nested values are dropped (96-113). The wire form is always the array.
- Option ids and choices come from `ServerProviderModel.capabilities.optionDescriptors` (`model.ts:7-44`: `select` with `options[]`, `currentValue?`, `promptInjectedValues?`; `boolean` with `currentValue?`). Example ids used by the Claude driver: `effort`, `fastMode`, `thinking` (`apps/server/src/claudeModelOptions.ts:36-44`).
- Equality used by server and clients: `modelSelectionsEqual` (`packages/shared/src/model.ts:110-122`): same instance, same model, same options regardless of order; an omitted options list equals an empty one (86-104).
- Runtime and interaction modes (`packages/contracts/src/providerPolicy.ts:25-36`): `RuntimeMode = "approval-required" | "auto-accept-edits" | "auto" | "full-access"` (default `full-access`), `ProviderInteractionMode = "default" | "plan"`.

### 1.6 How the server validates a model selection in commands

- `thread.create`: no adapter, model or project validation in `dispatchThreadCreate` (`Orchestrator.ts:2183-2265`). It stores `providerInstanceId = modelSelection.instanceId` and `modelSelection` as sent (2202-2203). An unknown instance is accepted here and fails later at turn start.
- `thread.model-selection.set` and `provider.switch`: `providerAdapters.get(instanceId)` must succeed (`Orchestrator.ts:2675-2684`), then `providerSwitchService.plan(...)` (2685-2690). Lookup failure is `ProviderAdapterRegistryLookupError` "No orchestration provider adapter is registered for X" (`ProviderAdapterRegistry.ts:25-34`, 83-87). The plan rejects when the target instance is missing or disabled (`ProviderSwitchService.ts:123-128`; `ProviderSessionTransitionPolicy.ts:39-41`). For a same-instance selection change with a live session or native thread, the adapter must classify it (`ProviderSessionTransitionPolicy.ts:59-74`): Claude and Codex return `apply_on_next_turn` (`ClaudeAdapterV2.ts:3053`, `CodexAdapterV2.ts:1693`); ACP drivers reject a model change unless `sessions.supportsModelSwitchInSession` (`packages/provider-core/src/server/selectionTransition.ts:24-37`).
- `message.dispatch` with `modelSelection`: the selection defaults to the thread's (`Orchestrator.ts:4643`). Starting a run requires `providerAdapters.get(modelSelection.instanceId)` (5202-5211). When steering, a same-instance selection change is classified by the adapter and can be rejected (3861-3893).
- Model id: no code was found that checks `model` against the provider's catalog (searched for "unknown model", "model is not", "invalid model" in `apps/server/src/orchestration-v2`, `apps/server/src/provider`, `packages/provider-core/src`). UNVERIFIED whether an unknown model id is rejected anywhere before the provider sees it.
- Client choice of command (only relevant to servers without `serverResolvedCommandContext`): `modelSelectionCommandType` (`packages/shared/src/model.ts:18-25`) sends `provider.switch` when the instance differs, else `thread.model-selection.set`. With the capability, the official client always sends `thread.model-selection.set` (`commands.ts:586-598`) and the server picks the event type (`thread.provider-switched` when the instance changed, `Orchestrator.ts:3222-3227`).

---

## 2. Version and protocol negotiation

### 2.1 Protocol version

`packages/contracts/src/environment.ts:12-16`:

```ts
export const ORCHESTRATION_PROTOCOL_VERSION = 2;
export const ORCHESTRATION_PROTOCOL_VERSION_TEXT = "2";
export const ORCHESTRATION_PROTOCOL_QUERY_PARAM = "orchestrationProtocol";
export const ORCHESTRATION_PROTOCOL_HEADER = "x-t3-orchestration-protocol";
```

- WebSocket: `GET /ws` must carry `?orchestrationProtocol=2` exactly (`apps/server/src/ws.ts:607-612`). Otherwise the server answers before any auth or RPC work (3142-3151):

```ts
HttpServerResponse.jsonUnsafe(
  { code: "orchestration_protocol_incompatible",
    message: `Update this client to one that supports orchestration protocol ${ORCHESTRATION_PROTOCOL_VERSION}.`,
    orchestrationProtocolVersion: ORCHESTRATION_PROTOCOL_VERSION },
  { status: 426 },
);
```

  Test: `apps/server/src/ws.test.ts:29-41` (missing and older values rejected).
- HTTP orchestration endpoints (`/api/orchestration/shell`, `/api/orchestration/threads/:threadId`, `/bounded`, `/history`) require the header `x-t3-orchestration-protocol: 2` through a required `Schema.Literal("2")` header schema (`packages/contracts/src/environmentHttp.ts:80-84`, 608-641). The status code and body returned for a missing header are UNVERIFIED (Effect HttpApi decode failure). Other HTTP groups (projects, auth, pull-request diff) do not require it (`environmentHttp.ts:449-529`, 643-674). The header is allowed by CORS (`apps/server/src/httpCors.ts:3-11`). The official client adds it in `withOrchestrationProtocolHeader` (`packages/client-runtime/src/state/environmentHttpAuth.ts:27-36`).
- Discovery: `GET /.well-known/t3/environment` returns `ExecutionEnvironmentDescriptor` without auth (`environmentHttp.ts:449-453`). Descriptor fields (`environment.ts:218-226`): `environmentId`, `label`, `platform {os, arch, machine?}`, `serverVersion`, `orchestrationProtocolVersion` (optionalKey; "Absent on hosts from before explicit orchestration protocol negotiation"), `capabilities`. The server sets `serverVersion: packageJson.version` and `orchestrationProtocolVersion: 2` (`apps/server/src/environment/ServerEnvironment.ts:216-217`).
- Official client check (`packages/client-runtime/src/connection/compatibility.ts:9-27`): a missing `orchestrationProtocolVersion` is treated as 1; any mismatch blocks the connection as `unsupported`, in both directions ("This client is not supported by this server" vs "This client requires a newer server"). Applied before connecting (`connection/resolver.ts:306-317`, which also appends the query param via `appendOrchestrationProtocol`, `compatibility.ts:38-42`) and on relay health results (`connection/layer.ts:57-62`). Doc: `docs/internals/legacy-orchestration-migration.md:33-42`.

### 2.2 No minimum client version

- No minimum-client-version or client-version check exists. Searching `apps/server/src`, `packages/contracts/src` and `packages/client-runtime/src` for `clientVersion`, `minimumClient`, `minClient`, `minimumVersion` found only the orchestration protocol fields above.
- `serverVersion` is advisory only: web shows a "Version mismatch" hint when the server is older than the client (`apps/web/src/versionSkew.ts:60-90`).
- Design rule (`docs/internals/overview.md:23-25`): "Negotiate linking through the environment descriptor, never through a client version or an assumed coordinated release". The RPC contract is "the boundary between independently versioned clients and servers" (16-19).

### 2.3 Feature flags

`ExecutionEnvironmentCapabilities` (`environment.ts:98-215`). Every flag except `repositoryIdentity` is an `optionalKey`; clients must treat absent as unsupported. Flags most relevant to orchestration:

| Flag | Lines | Meaning for a client |
| --- | --- | --- |
| `attachmentUploads` | 101-102 | Signed upload URL flow available. Absent: only inline data-URL images. |
| `questionAttachments` | 103-104 | Files may accompany question answers. |
| `fileAttachments.maxUploadBytes` | 105-110 | Non-image files allowed; per-file cap. |
| `inlineMessageContext` | 115-118 | Server keeps `context` records; absent servers drop them, so serialize context the legacy way. |
| `requiredWorktreeBootstrap` | 119-120 | Required worktrees fail instead of falling back to the checkout. |
| `threadSettlement`, `threadSnooze`, `threadPinning`, `threadPinReorder`, `threadActiveReorder`, `threadAutoSettleOptOut` | 121-160 | Never send the matching commands when absent. |
| `threadTitleRegeneration` | 161-163 | `regenerateTitle` on `thread.metadata.update`. |
| `threadVisitedTracking` | 164-168 | `thread.visit`, `thread.mark-unread`, `lastVisitedAt`. |
| `threadPullRequestLinking` | 169-170 | Legacy single `linkedPullRequest`. |
| `threadPullRequests`, `threadPullRequestWatch` | 175-177 | Multi-link pull request commands and watches. |
| `serverResolvedCommandContext` | 171-174 | Server resolves delivery (`deliveryIntent`) and model-selection command context and validates rollback readiness. |

This server advertises all of them as true, `fileAttachments.maxUploadBytes = PROVIDER_SEND_TURN_MAX_FILE_BYTES` (50 MiB), plus `serverBrowser`, `projectCloneTracking`, `environmentIcon` (`ServerEnvironment.ts:218-262`); `agentActivityPublishing` is computed per descriptor request (270-275).

`ServerConfig` adds top-level flags (`packages/contracts/src/server.ts:670-713`): `shellResumeCompletionMarker`, `shellRevealInFileManager`, `shellRevealInFileManagerKind`, `threadResumeCompletionMarker`, `threadSnapshotPagination`, `reasoningMessages`, `threadFind`, `threadFindProgressive`, `scratchWorkspaceRoot`, `newProjectsRoot`.

Opt-in inputs that protect older clients from new stream members (a third-party client should only opt in to what it handles):

- `subscribeServerConfig` payload (`packages/contracts/src/rpc.ts:1680-1700`): `environmentThemes`, `usageLimitSources`, `usageLimitsCommand`. The comment on `usageLimitsCommand`: the server injects `/usage-limits` into provider command catalogs only for clients that answer it locally, "an older client would send it to the provider as an ordinary prompt". Official client sends only enabled options (`packages/client-runtime/src/rpc/session.ts:156-160`). Config stream events are versioned `version: Literal(1)` (`server.ts:784-853`).
- `subscribeShell` and `subscribeThread` inputs (`orchestrationV2.ts:3223-3257`): `afterSequence`, `requestCompletionMarker`, `acceptBoundedSnapshot`, `acceptCompactTurnItems`. The `{kind: "synchronized"}` marker is only sent when requested (`ws.ts:822-823`, 1102-1103). HTTP bounded snapshot opt-in: `compactTurnItems=1` (`environmentHttp.ts:587-593`).

### 2.4 What a client sends on connect

- WebSocket URL: `<ws base>/ws?orchestrationProtocol=2&wsTicket=<ticket>` plus optional client metadata params. Official construction: `packages/client-runtime/src/authorization/remote.ts:201-221` (path `/ws`, `wsTicket`) and `appendClientConnectionParams` (40-84).
- Auth on the upgrade: `wsTicket` query param first (`apps/server/src/auth/EnvironmentAuth.ts:586`, 1173-1194), else cookie, `Authorization: Bearer`, or `Authorization: DPoP` via `selectRequestCredential` (650-676) and `authenticateRequest` (717-768). Tickets come from `POST /api/auth/websocket-ticket` (`environmentHttp.ts:478-484`) and live 5 minutes (`apps/server/src/auth/SessionStore.ts:433`). Default session TTL 30 days (432).
- Optional client identity params, all lenient ("absent or malformed values degrade to {}", `ws.ts:620-638`): `clientSurface` (`web|desktop|mobile|cli`, `packages/contracts/src/baseSchemas.ts:339-346`), `clientAppVersion` (max 64 chars), `clientDeviceType`, `clientOs`, `clientWebDeployment`, `clientBrowser` (web only), `clientOsMajorVersion` and `clientDeviceModel` (mobile only), `connectionMethod` (`ws.ts:598-684`). `surface` and `appVersion` are stored per session (`SessionStore.ts:612-631`) and used for analytics; they have no authorization role. Whether V2 events get stamped with `OrchestrationClientOrigin` (`packages/contracts/src/applicationEvent.ts:19-29` says "Stamped by the orchestration engine on client-dispatched commands") is UNVERIFIED for V2 thread events.
- `User-Agent` is only parsed into display metadata (`apps/server/src/auth/utils.ts:182-198`).
- RPC transport: Effect RPC with `RpcSerialization.layerJson` (`ws.ts:3190`; client `rpc/session.ts:211`), `RpcServer.make(ServerWsRpcGroup, { disableTracing: true, disableFatalDefects: true })` (`ws.ts:3121-3127`, 3171-3178). The patched client pinger writes a ping every 5 s and drops the socket after 3 missed pongs (`patches/effect@4.0.1.patch`, RpcClient makePinger hunk). Frame format details are UNVERIFIED in this research.
- Commands that arrive during server startup are queued until the server is ready (`apps/server/src/serverRuntimeStartup.ts:123-139`).

---

## 3. Permissions

### 3.1 Scopes

`packages/contracts/src/auth.ts`:

- Scope literals (82-121): `orchestration:read`, `orchestration:operate`, `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `diagnostics:read`, `terminal:read`, `terminal:operate`, `filesystem:read`, `filesystem:write`, `review:write` (retained for decoding only, grants nothing, 94-95), `source-control:write`, `access:read`, `access:write`, `relay:read`, `relay:write`.
- Grantable scopes exclude `review:write` (123-128). Standard client scopes (205-219) and administrative scopes (220-225).
- Auth responses send `scopes` filtered to the original wire vocabulary and `permissions` with the exact grant (`authScopeResponse`, 130-145). Use `permissions` when present, even if empty (`sessionGrantsScope`, 181-192). Legacy parent mapping for old servers only (154-164).
- `EnvironmentAuthorizationError` (409-416): `{ _tag, message, requiredScope, requiredPermission? }`. `requiredScope` stays in the legacy vocabulary and `requiredPermission` names the exact scope (`authScopeRequiredResponse`, 167-172).

### 3.2 Server enforcement per RPC

- Every RPC in `WsRpcGroup` carries the `RpcScopeAuthorization` middleware (`packages/contracts/src/rpc.ts:1806-1809`, applied at 1997). The server builds it from the socket's session scopes (`apps/server/src/auth/RpcAuthorization.ts:267-272`) and a total map `RPC_REQUIRED_SCOPES` (43-209, typed as a complete `Record<WsRpcMethod, AuthEnvironmentScope>`).
- Orchestration RPCs: `orchestration.dispatchCommand` and `orchestration.launchThread` need `orchestration:operate` (45, 55); `getTurnDiff`, `getFullThreadDiff`, `searchThreads`, `searchThread`, `searchThreadStream`, `getArchivedShellSnapshot`, `getThreadProjection`, `getTurnItem`, `getWorkflowScript`, `subscribeArchivedShell`, `subscribeShell`, `subscribeThread` need `orchestration:read` (46-58). `projects.mutate` needs operate (59). Attachments: `assetsPersistChatAttachments`, `attachmentsCreateUploadUrl`, `attachmentsDelete` need operate (156-158); `assetsCreateUrl` needs `filesystem:read` for workspace/media/draft files and `orchestration:read` otherwise (250-259). `serverUpdateSettings` scope depends on the patch (228-241, 260).
- There is one scope per RPC, so every orchestration command, including read-state commands like `thread.visit` and `thread.mark-unread`, requires `orchestration:operate` (dispatchCommand is not in `CLIENT_GUARDED_RPC_SCOPES`, so `requiredScopesForRpcCall` falls through to the method scope, 261-263).
- Denial error: `rpcAuthorizationError` (222-226) with message "The authenticated token is missing required scope: X."
- Client-side mirror (incremental only, "the server still authorizes every request"): `packages/contracts/src/clientRpcPermissions.ts:10-59` (source-control writes, VCS, clone and scheduled tasks; `gitPreparePullRequestThread` in worktree mode for a thread needs both `source-control:write` and `orchestration:operate`, 51-55). UI gating helper: `packages/client-runtime/src/state/commandPermissions.ts:17-73`.
- HTTP orchestration endpoints require `orchestration:read` (`apps/server/src/orchestration-v2/http.ts:156`, 169, 184, 205). HTTP errors are typed (`environmentHttp.ts:130-252`): 400 `EnvironmentRequestInvalidError` (`invalid_scope`, `scope_not_granted`, `invalid_command`, `invalid_history_cursor`), 401 `EnvironmentAuthInvalidError`, 403 `EnvironmentScopeRequiredError` (`requiredScope`, `requiredPermission`), 404 `thread_not_found`, 500 internal.
- Settings patches: `providers`, `providerInstances`, `usageLimitSources` need `providers:manage`, everything else `settings:write` (`packages/contracts/src/settings.ts:1596-1613`).
- Token exchange (`POST /oauth/token`): requested scopes are filtered to grantable scopes; an empty or unparsable request fails with `invalid_scope` (`apps/server/src/auth/http.ts:359-365`); the grant is intersected with the pairing grant and an empty intersection fails with `scope_not_granted` (`EnvironmentAuth.ts:901-907`). Unknown scope names are dropped rather than rejected (`docs/internals/environment-auth.md:64-67`).

### 3.3 What the server rejects from an unknown or non-official client

- Missing or wrong `orchestrationProtocol` on `/ws`: HTTP 426 (section 2.1).
- Missing or invalid credential: `EnvironmentAuthInvalidError` 401. DPoP-bound tokens require a valid proof, and a DPoP header with a non-bound token is rejected (`EnvironmentAuth.ts:736-767`).
- Sessions with subject `mcp-client` are rejected everywhere except `/mcp` (`EnvironmentAuth.ts:612-619`, 706; `docs/internals/environment-auth.md:42-48`).
- Missing scope per RPC: `EnvironmentAuthorizationError`.
- Not checked: Origin header for WS or RPC (Origin only appears in dev CORS config `apps/server/src/http.ts:242-253` and MCP code), client kind, client version, User-Agent, device registration. "Client labels and device metadata have no authorization role" (`environment-auth.md:13-14`). `docs/internals/devices.md` is about simulators and emulators, not client registration.
- Provenance is forced on the WebSocket path. For `thread.create`, `message.dispatch`, `thread.fork`, `thread.merge_back`, `delegated_task.request` the server overwrites `createdBy: "user"` and keeps the client's `creationSource` (`ws.ts:1842-1848`, `ThreadManagementService.ts:52-66`). `launchThread` also forces `createdBy: "user"` and defaults `creationSource` to `"web"` (`ws.ts:1986-1987`). Consequences: `message.dispatch` with `notification` is rejected ("Notifications must be server- or provider-created queued messages", `Orchestrator.ts:4668-4679`) and with `delegatedCompletion` is rejected (4683-4695).
- Server-internal commands are not in the client union (`OrchestrationV2InternalCommand`, `orchestrationV2.ts:3057-3133`: `thread.pull-request-watch.sync`, `checkpoint.rollback.fail`, `thread.background-work.settle`, `thread.stop`, `secret_request.record`). Several server-intended commands ARE accepted from clients and must not be sent by a third-party client: `thread.auto-settle` (2656-2668, "dispatched by the settlement sweep, never by clients"), `thread.title.regeneration.complete` (2805-2811), `thread.pull-request-link.sync` (2769-2776), `thread.pull-request.sync` (2789-2804), `prepared-run.release/progress/fail` (2877-2903), `notification.delivery.accept` (2883-2889), `delegated_task.*` (3001-3037), `thread.created.record` (3038-3046).
- Provider-native subagent threads (`lineage.relationshipToParent === "subagent" && creationSource === "provider"`, `orchestrationV2.ts:442-451`) are read-only: `message.dispatch` fails with `OrchestratorSubagentThreadReadOnlyError` (`Orchestrator.ts:10249-10265`), as does starting a PR watch (2417-2426).

---

## 4. Schema strictness and forward compatibility

### 4.1 Excess properties

- No custom parse options are set for RPC payloads or orchestration contracts. The only `onExcessProperty` uses in the repo are `packages/contracts/src/keybindings.ts:197-201` (explicit `"ignore"`), and JSON Schema generation in `packages/provider-core/src/server/textGenerationUtils.ts:16-18` and `packages/shared/src/t3ProjectFile.ts:35` (`"error"`, not decoding).
- Effect 4 default decoding ignores and strips unknown keys, shown by repo tests: `packages/contracts/src/t3ProjectFile.test.ts:35-38` (`decode({ futureField: true })` returns `{}`), `keybindings.test.ts:309-328` (unknown `key` field absent after decode), and `orchestrationV2.test.ts:371-384` with the explicit comment "Older servers strip the unknown opt-in, so they keep sending full turnItems" (legacy input schema at 97-103). Legacy shell decoders ignore `resolvedRepositoryIdentityRoots` (516-531). HTTP query: `?compactTurnItems=yes&unknown=1` returns the same body as no query (`apps/server/src/orchestration-v2/boundedSnapshotTransport.test.ts:285-296`).
- UNVERIFIED: that Effect `RpcServer` decodes payloads with default options (library source not installed). The repo's own compatibility design assumes it does.
- Practical rule: extra fields a client sends are silently dropped and never persisted. There is no extension channel in commands.

### 4.2 Wire encoding

- The wire codec is `Schema.toCodecJson(schema)` ("Through the wire codec, as a client receives it", `boundedSnapshotTransport.test.ts:52`, 269-270). Tests feed `DateTime.formatIso(now)` strings for `DateTimeUtc` fields through that codec (`orchestrationV2.test.ts:176-221`), so timestamps travel as ISO 8601 strings.
- `TrimmedNonEmptyString` trims on decode and encode and rejects blank values (`baseSchemas.ts:7-27`). All entity ids are branded trimmed non-empty strings (310-407); the only id with a pattern is `ChatAttachmentId` (`chatAttachment.ts:35-39`). `RpcClientId` is a non-negative int (336).

### 4.3 Unknown enum literals

- Client to server: every `Schema.Literal`/`Literals` is strict. An unknown command `type`, `creationSource`, `runtimeMode`, `interactionMode`, `dispatchMode.type`, `deliveryIntent`, approval `decision`, etc. fails decoding of the whole payload. The error shape the client receives for an RPC payload decode failure is UNVERIFIED (it is not `OrchestrationV2DispatchCommandError`, which is only produced after decode, `ws.ts:1854-1863`).
- Server to client: strict unless a forward-compatible wrapper is used. A KNOWN tag with a payload that does not decode always fails (tests `orchestrationV2.test.ts:216-219`, 337-348).

### 4.4 Forward-compatible constructs and what a client must do

Building blocks (`packages/contracts/src/baseSchemas.ts`): `ForwardCompatibleOptional` (55-69, unknown member decodes as absent), `ForwardCompatibleNullable` (76-87, unknown decodes as null), `OmittedWhenNull` (95-112), `ForwardCompatibleArray` (128-170, undecodable elements dropped), `UnknownUnionMember` (183-190), `ForwardCompatibleUnion` (201-227, unknown tag decodes to `UnknownUnionMember`, decode-only), `hasUnknownUnionTag` (243-253), `ForwardCompatibleUnionArray` (265-286, unknown tags dropped).

Applied in orchestration contracts:

- `kindUnionWithFallback` (`orchestrationV2.ts:760-795`): an object with an unknown or missing `kind` decodes to a known fallback member; known kinds must decode in full; encode-only for known members.
  - `OrchestrationV2PendingBackgroundTask` (803-829): kinds `subagent | command | monitor | background_task`; unknown or missing kind becomes `background_task`.
  - `OrchestrationV2NotificationSource` (1054-1100): on the wire a subagent source is sent as `{ kind: "background_task", work: "subagent", childThreadId? }` and a command source as `{ kind: "background_command" }`, so older clients still decode; unknown kinds become `background_task`. A client must accept both spellings and should send the old spellings if it ever encodes these (clients normally do not).
- Turn items: unknown `type` values are dropped from `projection.turnItems` (1797, 2377), from `visibleTurnItems` rows (1592-1608, 1802-1808) and from history pages (3306-3317). Tests: `orchestrationV2.test.ts:223-349`.
- Thread stream: an event with an unknown `type`, or a `turn-item.updated` with an unknown item type, decodes to `{ kind: "unknown-event", sequence, eventType }` (3320-3364, union arm 3366-3392). The official client advances its resume cursor past it and skips it (`packages/client-runtime/src/state/threads.ts:440-460`, "An event type from a newer server still moves the resume cursor past it", 452-453). A native client MUST do the same, or resume will replay forever.
- Attachments: `ChatUnknownAttachment` (`chatAttachment.ts:178-198`) keeps `type, id, name, mimeType, sizeBytes` for unknown types; consumers skip or render as unsupported.
- Composer context: `UnknownContextRecord` (`composerContext.ts:239-262`) preserves `version, contextId, label, kind, payload` (payload must be JSON, max 64,000 chars); `OrchestrationMessageContext` drops undecodable records (286-306).
- Project icons: `ReceivedProjectIcon` decodes unknown kinds as null (`project.ts:148-163`).
- Server config: `issues`, `providers`, `availableEditors`, `remoteOpenTargets`, `directEndpoints` are ForwardCompatibleArray (`server.ts:49-51`, 316-321, 652-667); `platform.machine` and `serverInstallation` are ForwardCompatibleOptional (`environment.ts:50-53`, 184); `ServerProvider.supportedRuntimeModes` (`server.ts:258`).
- Decoding defaults for fields older servers or rows omit: `settledOverride`, `settledAt`, `lastVisitedAt` default null on `OrchestrationV2AppThread` (398-417); `pendingBackgroundTasks` default `[]`, `contextUsage`, `nativeMetadata`, `goal` default null on provider threads (891-904); shell `pendingBackgroundTasks` and `providerInstanceHistory` default `[]` (1882-1892).

NOT forward compatible (a new member breaks older strict decoders, so the server gates such additions behind opt-ins): `OrchestrationV2ShellStreamItem` (1945-1981), `OrchestrationV2ArchivedShellStreamItem` (3163-3178), `OrchestrationV2GetTurnItemResult.item` (3467-3469, plain `NullOr(OrchestrationV2TurnItem)`), run/attempt/node/turn statuses (453-465, 607-616, 628-651), `OrchestrationV2RuntimeRequest.kind` (1030-1033), `responseCapability` (1035-1039), `ProviderRequestKind` (`providerPolicy.ts:38-45`). A native client should be at least as tolerant as the official decoders and preferably more tolerant (keep unknown values as opaque strings).

---

## 5. Legacy fields and V1-imported threads

### 5.1 Legacy wire fields still in play

- `ModelSelection.provider`: accepted on decode, never encoded (section 1.5).
- Legacy object-shaped model options: accepted on decode, normalized to the array (`model.ts:55-93`).
- `linkedPullRequest` (`orchestrationV2.ts:375-377`, shell 1847-1848; `ThreadLinkedPullRequest`, `packages/contracts/src/threadPullRequest.ts:19-30`): "Legacy single-PR link. Still emitted as the thread's derived current pull request ... so clients from before `pullRequests` keep working". `thread.metadata.update.linkedPullRequest` (2752-2753) is still accepted and also maintains `pullRequests` (`Orchestrator.ts:2940-2966`). `docs/internals/overview.md:21-38`: environments keep advertising `threadPullRequestLinking`, keep accepting legacy metadata commands and keep emitting the derived field; use multi-link commands when `threadPullRequests: true`.
- Project icon legacy monogram (lucide icon with `monogramText`/`monogram`) is read, never written (`project.ts:112-146`).
- `ProviderSession` in `provider.ts:37-53` is the V1-era runtime shape with `provider` plus optional `providerInstanceId`; it is not part of the V2 orchestration wire.
- `ProjectCreatePayload.defaultModelSelection` (`project.ts:199-205`) is still accepted but ignored: the server always creates projects with `defaultModelSelection: null`, `faviconPath: null`, `projectIcon: null` (`apps/server/src/orchestration-v2/ProjectCommands.ts:171-176`; `ProjectService.create` does not pass it, `apps/server/src/project/ProjectService.ts:337-355`). Set a default model with `project.update`.
- Optional fields that pre-feature servers omit (clients must tolerate absence): `pinnedAt`, `pinOrderKey`, `activeOrderKey`, `lastVisitedAt`, `titleRegeneration`, `goal`, `providerInstanceHistory` on shells (`orchestrationV2.ts:1893-1926`); `historyCursor`, `hasMoreHistory`, `latestLocalTurnOrdinal` on snapshots (3263-3274).

### 5.2 The V1 importer and how imported threads look on the wire

Process (`docs/internals/legacy-orchestration-migration.md:1-31`): on first V2 launch `state.sqlite` is copied to `statev2.sqlite`; thread shells are imported eagerly and transcripts lazily when a client reads or continues the thread.

Imported thread (`apps/server/src/orchestration-v2/legacy/LegacyV1ThreadImporter.ts:189-243`):

- `createdBy: "system"`, `creationSource: "server"`, `historyOrigin: "v1_import"`, `activeProviderThreadId: null`, root lineage, `forkedFrom: null`, `lastVisitedAt: null`.
- Title "Untitled thread" when blank (210). Model selection from the V1 row, falling back to `{ instanceId: "codex", model: DEFAULT_MODEL }` (138-147). Unknown runtime mode becomes `full-access` (164-171); interaction mode `plan` or `default` (173-175).
- Preserved: ids, title, selection, modes, branch, worktree path, timestamps, archive/delete, settlement, snooze, pin and order keys, pull request links (doc 12-16).

Imported messages and items (`messageEvents`, 245-337):

- Only user and assistant rows. Messages have `runId: null`, `nodeId: null`, `creationSource: "server"`, `createdBy` `"user"` or `"agent"`, `streaming: false`.
- Turn items have id `migration:v1:turn-item:<messageId>`, `runId: null`, status `interrupted` if the V1 row was streaming else `completed`, user items `inputIntent: "turn_start"`. Event ids `migration:v1:message:<id>` and `migration:v1:turn-item:<id>`; shell repair events `migration:v1:thread:<id>:metadata-repair:<uuid>` (531-546).
- Shell import writes `thread.created`, a preview of the latest user message and the latest message, then `thread.metadata-updated` (588-654). Full transcript hydration happens on demand (694-775) before reads and most commands (`ThreadManagementService.ts:68-99` skips it for `thread.visit` and `thread.mark-unread`).
- Not imported: provider sessions, native runs, checkpoints and diffs, activities and tool calls, approvals, proposed plans (doc 22-24). So an imported thread has `runs: []`, no `providerSessions` (no capability data), and runless turn items until its first new turn.
- First continuation: a fresh provider session receives a legacy handoff built from user and assistant messages within a 32,000-character budget (doc 26-31; `Orchestrator.ts:743-751`, 5169-5172, 5227-5242).

`historyOrigin: "v1_import"` is also used for native agent sessions imported from disk (`apps/server/src/project/AgentSessionImporter.ts:276-311`): `createdBy: "system"`, `creationSource: "server"`, `settledOverride: "settled"`, `activeProviderThreadId` set to a provider thread with a strong `nativeThreadRef`, model selection without options.

What a client must handle:

- Treat `historyOrigin` absent as native. The server never emits `"native"` (no producer found; shell copies the field only when defined, `ProjectionStore.ts:1458-1460`).
- Turn items with `runId: null` are part of the history of a v1 thread. Forks treat them as at or before any run (`ProjectionStore.ts:1256-1267`, fork prefix 1269-1310) and shell counts include them (1625).
- Provider switching is allowed for v1 threads without capability evidence (`threadWorkflows.ts:97`).
- Agent awareness push publishing skips `thread.created` for v1 imports (`apps/server/src/relay/AgentAwarenessRelay.ts:78-89`).

---

## 6. Round-trip preservation

### 6.1 Events are full snapshots

Every `thread.*` event carries the complete `OrchestrationV2AppThread` (`orchestrationV2.ts:1645-1676`). The server projection and the official client both replace the thread wholesale (`apps/server/src/orchestration-v2/ProjectionStore.ts:693-715`; `orchestrationV2Projection.ts:164-183`). Other entities are upserted by `id` (`orchestrationV2Projection.ts:16-25`), with one merge: `provider-turn.updated` keeps the previous `tokenUsage` when the update omits it (229-244). A native client should replace entities by id, never merge partial fields, except for that tokenUsage rule.

### 6.2 Patch versus replace, per command

- `thread.metadata.update` (contract `orchestrationV2.ts:2739-2754`, server `Orchestrator.ts:2900-2976`): PATCH. Only provided fields change. `null` clears `branch`, `worktreePath`, `linkedPullRequest`, `limitRecovery`. Setting `title` also clears the `titleRegeneration` marker; `regenerateTitle: true` arms it and enqueues generation (3241-3248); `false` clears it. Guards: `expectedWorktreePath` (2472-2482) and `expectedEmpty` (2483-2496). `limitRecovery` updates must include `autoResume` or `snooze` (contract 348-361) and preserve omitted choices for the same run and reset (2901-2917).
- `thread.model-selection.set` and `provider.switch`: FULL REPLACE of `modelSelection` and `providerInstanceId` (3172-3179). Omitting `options` wipes the stored options.
- `message.dispatch.modelSelection`: optional. Omitted means "use the thread's selection" (4643). If present and not equal to the thread's, the thread's selection is replaced in full and a `thread.model-selection-updated` or `thread.provider-switched` event is emitted (5142-5164; steering path 4002-4020).
- The official client sends the full current composer selection, including options, with every turn (`commands.ts:704`, 766; web `ChatView.tsx:9538`, 9948). Options are remembered per model client-side and restored when switching models (`ChatView.tsx:10744-10751`). `createModelSelection` omits `options` when empty (`packages/shared/src/model.ts:474-485`).
- `thread.runtime-mode.set` and `thread.interaction-mode.set`: single-field set. `message.dispatch` has no mode fields; web dispatches these before sending when they differ (`ChatView.tsx:6267-6325`).
- `thread.pin`: `orderKey` applies only to a fresh pin; a re-pin keeps the existing key (2845-2867). `thread.pin.reorder` is rejected for unpinned threads (2533-2539). `thread.active.reorder` is rejected for pinned or settled threads and does not bump `updatedAt` (2540-2549, 2890-2897).
- `thread.visit`: the server keeps the maximum of stored and supplied `visitedAt` and does not bump `updatedAt` (2267-2308). Official clients send the thread's `updatedAt` as the watermark (web `ChatView.tsx:2963`, mobile `ThreadDetailScreen.tsx:875`).
- `queued-run.edit` (contract 2948-2958, server 7708-7740): `text` replaces; `attachments` absent keeps the old list, present replaces it; `context` absent keeps the old context. The official client sends `context` only together with attachments (`commands.ts:1036-1044`).
- `project.update` (`apps/server/src/project/ProjectMutation.ts:28-44`; `ProjectService.ts:357-393`; `ProjectCommands.ts:183-229`): PATCH per field, but `scripts` replaces the whole array and `defaultModelSelection` replaces the whole selection (null clears). New script ids must be 1 to `MAX_SCRIPT_ID_LENGTH` lowercase letters, digits or hyphens; existing ids are grandfathered (192-204). To change one script, resend the full list with every field of every script (`ProjectScript`, `project.ts:33-46`).
- Server settings (`settings.ts`): `providerInstances` in a settings patch is a whole-map replacement (comment 1572-1575, field 1576); prefer `ProviderInstanceMutation` create/upsert/remove for one entry (`providerInstance.ts:134-150`), whose `instance` still replaces that entry, including the opaque `config` that must be echoed verbatim. `textGenerationModelSelection` takes a partial `ModelSelectionPatch` (1447-1451, 1533). `usageLimitSources`, `usagePriceOverrides`, `usageModelAliases` merge per entry with `null` removing (1577-1588). Secrets come back redacted as `"••••••"` and sending the marker back means keep the stored value (`apps/server/src/serverSettings.ts:150-154`); sensitive provider environment variables come back with `value: ""` and `valueRedacted: true` (173-185) and the server restores them when they are echoed with `valueRedacted` (879-890).

### 6.3 Fields that drop or cannot carry extra data

- `ModelSelection` keeps only `instanceId`, `model`, `options` (`modelSelection.ts:38-59`). Option values are only strings or booleans.
- Commands and entities strip unknown keys (section 4.1). There is no place to store client-private metadata on threads, messages or projects.
- `UnknownContextRecord` keeps only base fields plus `payload`; `ChatUnknownAttachment` keeps only five base fields.
- The `*Json` schemas (`orchestrationV2.ts:1991-2609`) only swap `DateTimeUtc` for `DateTimeUtcFromString` and keep every field (by inspection); they are persistence codecs, not a lossy mapping.
- The wire projection is lossy by design (`apps/server/src/orchestration-v2/WireProjection.ts`): `handoff.summary` removed; `command_execution.output` removed with `outputOmitted: true` and a preserved `outputIndicatesFailure`; `file_change` `diffStr`, `oldStr`, `newStr` removed except a truncated `diffStr` on failed edits; `subagent` prompt, progress and result truncated to 32 KiB; `dynamic_tool` input summarized above 16 KiB and output compacted with `outputOmitted` (76-126); context handoffs lose `history` and `delivery` and get `summaryText: ""` (203-208). This applies to snapshots and events (210-241). Full detail comes from `orchestration.getTurnItem`, bounded at 256 KiB without image bytes (173-201). Never write projected data back as if complete.
- `orchestration.getThreadProjection` over RPC returns a bounded window, not full history ("Pre-pagination clients still call this compatibility endpoint", `ws.ts:1920-1947`). The HTTP `threadSnapshot` returns the full wire projection (`orchestration-v2/http.ts:91-112`, 165-178).

### 6.4 Idempotency and command ids

- Same `commandId` replays the stored result sequence without re-running side effects; a previously rejected `commandId` fails again with `OrchestratorCommandPreviouslyRejectedError`; reusing a `commandId` for a different thread fails with `OrchestratorCommandIdConflictError` (`Orchestrator.ts:10421-10481`). Rejections are stored as receipts (10513-10536), so a retry after fixing input needs a new `commandId`. Commands that produce no events are rejected "Command produced no domain events." except settle and stop (10496-10512). Design statement: `docs/orchestration-v2/README.md:108`.
- `dispatchCommand` returns only `{ sequence }` (`orchestrationV2.ts:3212-3214`), the last committed stored-event sequence.
- Official clients use UUIDv4 command ids (`commands.ts:261-267`) and UUIDs for thread, message and project ids (`apps/web/src/lib/utils.ts:36-50`). Derived ids in use: `${commandId}:model-selection` (`commands.ts:595`), `${commandId}:detach:${sessionId}` (928); launch uses `${commandId}:initial-message`, `:workspace`, `:branch-rename`, `:progress:worktree`, `:progress:setup` (`ThreadLaunchService.ts:811`, 418, 452, 326, 475). The server mints `server:<tag>:<uuid>` (`ws.ts:1236-1240`) and `command:system:...` ids (`Orchestrator.ts:1370`). A third-party client should use plain UUIDv4 ids and never reuse a prefix the server uses.
- Hazard (inferred from code, not exercised): `dispatchThreadCreate` has no existence check (`Orchestrator.ts:2183-2232`) and the projection replaces the thread on any `thread.created` (`ProjectionStore.ts:693-715`). A second `thread.create` for an existing `threadId` with a NEW `commandId` would overwrite the thread record (pins, settlement, timestamps). Always retry `thread.create` with the same `commandId`. UNVERIFIED end to end.

---

## 7. Other things official clients rely on implicitly

### 7.1 creationSource and createdBy

- Values (`orchestrationV2.ts:79-86`): `web` (web and the desktop app, which reuses the web client; `commands.ts` defaults to `"web"` at 400, 670, 695, 759, 944, 959), `mobile` (mobile app, for example `apps/mobile/src/lib/projectThreadStartTurn.ts:49`), `mcp` (MCP tools and delegated tasks), `provider` (provider-created threads and messages), `server` (imports, wakes, continuations). There is no `desktop` or native-app value. A native macOS client should send `"web"` to look like the desktop app, or `"mobile"` if it wants mobile treatment; no code was found that treats either specially.
- The server trusts the client's `creationSource` over WebSocket (section 3.3), so a client could send `provider` or `server`. It must not: `provider` plus a subagent lineage makes a thread read-only (`orchestrationV2.ts:442-451`), and server-only flows check for `server`/`provider` (`Orchestrator.ts:4668-4695`).
- UI attribution: user messages with `scheduledTaskId` show "Sent by automation"; `createdBy === "agent"` shows "Sent by another agent" (`apps/web/src/components/chat/MessagesTimeline.tsx:2360-2393`; `packages/client-runtime/src/userMessage.ts:7-31`, including the legacy `[Triggered by schedule task: ...]` prefix, 3-4). `inputIntent` other than `turn_start` shows a marker (2395-2397). The server does not validate `scheduledTaskId` or `senderThreadId` from clients (`Orchestrator.ts:4831-4836`, 5015-5020); a client must not set them.
- Subagent threads (`relationshipToParent === "subagent"`) are hidden from sidebars and navigation (`apps/web/src/components/Sidebar.logic.ts:566-583`; `packages/client-runtime/src/state/threadShell.ts:207`; mobile `threadListV2.ts:243`, 711). Fork parents come from `forkedFrom.threadId` or `lineage.parentThreadId` (`Sidebar.logic.ts:585-594`).

### 7.2 Titles

- Server rule: `titleSeed` on `message.dispatch` is applied only when the thread has zero messages; it sets the title, sets `titleRegeneration`, and enqueues server title generation (`Orchestrator.ts:4606-4642`). A user message also triggers it when the only earlier user messages were `/compact` or `/logout` (405-415). `launchThread` with `generateTitle: true` passes the title as `titleSeed` (`ThreadLaunchService.ts:834`).
- Official seeds: web uses the message text without context links and citations, truncated to 50 chars plus `...` (`packages/shared/src/String.ts:1-8`; `ChatView.tsx:9807-9823`), falling back to `Image: <name>`, `File: <name>`, terminal or review labels, then `New thread`. Mobile compacts whitespace and truncates to 72 chars (`projectThreadStartTurn.ts:89-97`). Sending `titleSeed` on every turn is harmless with this server; the official client does so when the server has `serverResolvedCommandContext` (`commands.ts:752-754`).

### 7.3 Branches and worktree paths

- New worktrees: send `workspaceStrategy: { type: "worktree", baseRef, branch?, startFromOrigin? }` and let the server name things (`orchestrationV2.ts:518-536`; official mapping `commands.ts:646-667`). Without a branch the server provisions `t3/<8 hex>` (or `t3-<8 hex>` if a plain `t3` branch exists) and renames it in the background with text generation using the `branchNamingMode`, `branchNamePrefix`, `branchNameInstructions` settings (`ThreadLaunchService.ts:306-316`, 371-382, 427-468; `packages/shared/src/git.ts:14-26`, 119-145). Temporary names sent by clients are also renamed; legacy `t3code/<hex>` and `t3code/<uuid>` count as temporary. The final branch and path are recorded with `thread.metadata.update` (`ThreadLaunchService.ts:415-423`, 449-457).
- Worktree path: `<worktreesDir>/<basename(project root)>/<branch with "/" replaced by "-">` (`apps/server/src/vcs/GitVcsDriverCore.ts:3394-3416`), where `worktreesDir` is the `worktreesDirectory` setting or `<T3 home>/worktrees` (`apps/server/src/config.ts:155`; `apps/server/src/worktreesDirectory.ts:12-22`). Attachments live in `<T3 home>/userdata/attachments` (`config.ts:144`).
- Use `existing_worktree` for a known path and `root` for the project checkout. A `root` launch in the Scratch project gets its own managed folder (`ThreadLaunchService.ts:746-764`).

### 7.4 Attachments

Limits (`packages/contracts/src/chatAttachment.ts`): max 100 attachments per message or question response (14); images max 10 MiB each (15) and 80 MiB total per message (16, 220-237); files 1 byte to 50 MiB (17, 162-176); upload image MIME types `gif, jpeg, png, webp` (18-23); `ChatAttachmentId` max 128 chars matching `^[a-z0-9_-]+$/i` (35-39); data URL max 14,000,000 chars (32); provider input text max 120,000 chars (13).

Upload flow (needs `attachmentUploads`):

1. RPC `attachments.createUploadUrl` with `{ type?: "image" | "file", name, mimeType, sizeBytes }` (`packages/contracts/src/assets.ts:94-125`). Result `{ attachmentId, relativeUrl, expiresAt }`; the id has the form `pending-<uuid>[-<ext>]` (`apps/server/src/attachmentStore.ts:25`, 64-66) and the URL lives 10 minutes (`assets.ts:92`; `apps/server/src/assets/AttachmentUpload.ts:73-119`).
2. `POST` the raw bytes to `relativeUrl` resolved against the HTTP base. The signed token in the path is the credential. `Content-Length` must equal `sizeBytes`; success is 204, an invalid or expired token 404, a size mismatch 400 (`apps/server/src/http.ts:449-486`; `AttachmentUpload.ts:150-223`).
3. Reference it in `message.dispatch.attachments` (or `queued-run.edit`, `runtime-request.respond.attachmentsByQuestionId`, `launchThread.initialMessage`) as `{ type, id: attachmentId, name, mimeType, sizeBytes }`. The server claims pending uploads before dispatch: duplicate ids rejected, stored size must match, type and extension must match, the file is copied to a thread-scoped id `<thread segment>-<uuid>[-<ext>]` and the MIME type lowercased (`apps/server/src/orchestration-v2/AttachmentClaims.ts:26-31`, 62-149; `attachmentStore.ts:84-90`, 207-251). Context records bound to the pending id are remapped by array position (`ThreadMessageIntake.ts:127-164`; `packages/shared/src/composerContextReferences.ts:300-323`). `launchThread` with pending uploads requires an explicit `threadId` (`ThreadMessageIntake.ts:186-194`).
4. Unclaimed pending uploads are swept after 24 hours, partial uploads after 1 hour (`attachmentStore.ts:26-27`, 253-296). Delete abandoned uploads with `attachments.delete` (`packages/client-runtime/src/state/attachments.ts:112-125`).

Legacy path (servers without `attachmentUploads`): `assets.persistChatAttachments` with image data URLs; the server writes a deterministic id from thread, message and index and does not keep `source` metadata (`ws.ts:365-430`; client `commands.ts:282-308`).

Non-pending attachment ids pass through the claim untouched (`AttachmentClaims.ts:76-78`, 86-88). Download URLs: `assets.createUrl` with `{ _tag: "attachment", attachmentId, fileName?, mimeType?, disposition? }` (`assets.ts:32-43`). File attachments are a replay compatibility limit: image-only peers cannot decode file-bearing messages (`docs/internals/providers.md:140-143`).

Attachment-only sends: web sends the text `"[User attached one or more files without additional text. Respond using the conversation context and the attached files.]"` (`apps/web/src/components/chat/composerPromptHistory.ts:19-20`; `ChatView.tsx:9282`, 9331, 8970). Mirror it so threads look the same.

### 7.5 Composer context references

- Text carries position and identity as Markdown links: `[label](t3-context://v1/<kind>/<contextId>)`, images as `![label](...)` (`composerContextReferences.ts:10-28`). Parser rules: scheme `t3-context:`, host `v1`, kind `^[a-z][a-z0-9-]{0,39}$`, id `^[a-z0-9_-]{1,128}$/i`, no query or fragment (30-40). Labels have no brackets or line breaks, max 200 chars, never empty (43-50).
- Payloads live in `message.context = { version: 1, records: [...] }` (`packages/contracts/src/composerContext.ts:283-306`: max 200 records, max 16,000,000 serialized chars, unique `contextId`). Known kinds: `image, file, terminal, element, preview-annotation, review-comment, mention, skill, thread` (21-31); record fields and bounds 92-235. Image and file records bind to a `ChatAttachment` by `attachmentId` (98-117).
- The server keeps text and records as sent and builds provider text at turn start with markers and a trailing `<t3_context version="1">` envelope (`composerContextReferences.ts:265-298`; doc `docs/internals/composer-context-references.md:58-71`, 121-127).
- Servers without `inlineMessageContext` drop records and forward links as literal text; then send the legacy serialization (`packages/shared/src/composerContextLegacySend.ts:5-53`; web gating `ChatView.tsx:9517-9535`, 9934-9945).
- Other inline tokens in text: file mentions `[basename](path)` (label must equal the basename) or `@path` / `@"quoted path"`, skills `$name` (`packages/shared/src/composerInlineTokens.ts:28-60`).

### 7.6 Other conventions

- Claude "ultrathink" effort is a prompt-injected value: web prefixes the text with `Ultrathink:\n` (`packages/shared/src/model.ts:510-529`; `ChatView.tsx:806-816`), and the Claude adapter applies the same idempotent prefix from the model selection's `effort` option (`apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:7553-7556`; `apps/server/src/claudeModelOptions.ts:36`, 51). Mobile hides prompt-injected choices (`apps/mobile/src/features/threads/thread-settings-options.ts:56-63`).
- Stop button: `run.interrupt` with `holdQueue: true`, which also holds the queue, ends pull request watches and stops delegated tasks (`commands.ts:780-832`; contract `orchestrationV2.ts:2911-2922`; `Orchestrator.ts:10290-10300`). With no active run it targets the latest run if background work is pending, else turns off PR watches.
- "Stop session" detaches every provider session with `reason: "client-requested"` (`commands.ts:919-935`).
- Pin and active order keys are base-26 lowercase strings `[a-z]+` that never end in `a`; official clients treat anything else as corrupt and rewrite the whole section with fresh spread keys (`packages/client-runtime/src/state/threadSort.ts:178-195`, 223-298). Sorting is plain string comparison with id then environment id as tiebreak; keyless pinned threads sort after keyed ones by newest creation (306-330). A native client must generate keys with the same alphabet or it will trigger rewrites in official clients.
- Snapshot plus cursor: apply only events with a sequence greater than the snapshot's (`docs/orchestration-v2/core-graph-and-data-model.md:38`, 594).
- Approval and question answers: native option ids must survive; a display label is not necessarily a valid reply (`docs/internals/providers.md:127-130`). Repeating `runtime-request.respond` returns the receipt without answering twice (112-117).
- `docs/internals/consistency-action-names.md:1-39` (proposed invariant): a command's visible label, tooltip, menu wording and accessible name describe the same action on the same object; copying a message is not copying a link.
- `docs/internals/glossary.md:1-64`: Turn equals a V2 run; Command acceptance does not mean side effects finished; Command receipt makes retries idempotent; Provider instance is one configured provider; Context record, Context reference, Attachment binding and Attachment inventory are defined for composer context.

---

## 8. Rules for a third-party client (summary)

1. Connect with `/ws?orchestrationProtocol=2` and send `x-t3-orchestration-protocol: 2` on `/api/orchestration/*`. Check `descriptor.orchestrationProtocolVersion === 2` first; absent means 1.
2. Gate every optional command or field on `descriptor.capabilities` flags, treating absent as unsupported. Never use `serverVersion` for feature decisions.
3. Request only the scopes you need; read `permissions` when present. Expect `EnvironmentAuthorizationError` per RPC. All commands need `orchestration:operate`.
4. Use UUIDv4 for command, thread, message and project ids. Retry with the same `commandId`; use a new one after a rejection.
5. Send `creationSource: "web"` (or `"mobile"`), never `mcp`, `provider` or `server`. Do not set `scheduledTaskId`, `senderThreadId`, `notification` or `delegatedCompletion`.
6. Send complete `ModelSelection` objects with options whenever you send one; omit `modelSelection` on `message.dispatch` unless the user changed it.
7. Treat `project.update.scripts` and settings `providerInstances` as whole replacements; echo opaque `config` and redaction markers unchanged.
8. Decode tolerantly: ignore unknown keys, skip `unknown-event` items while advancing the cursor, drop unknown turn item types, accept both notification source spellings, keep unknown enum values as opaque strings.
9. Handle `historyOrigin: "v1_import"` threads: no runs, no sessions, runless turn items.
10. Use the upload URL flow for attachments, mirror the attachment-only prompt, and write context as `t3-context://v1/` links plus `context.records`.
11. Generate pin and active order keys in the `[a-z]` base-26 scheme.
12. Never resend `thread.create` for an existing thread with a new `commandId`.

## 9. UNVERIFIED items

- Effect `RpcServer` payload decode options (assumed default strip of unknown keys; repo tests and comments rely on this).
- HTTP status and body when `x-t3-orchestration-protocol` is missing or wrong.
- Error shape a client receives when an RPC payload fails to decode (unknown command type or literal).
- Effect RPC frame format and ping/pong wire details.
- Whether V2 thread events carry `OrchestrationClientOrigin` metadata.
- Whether the server rejects an unknown `model` id anywhere before the provider.
- Whether raw `thread.create` via `dispatchCommand` is blocked during a project clone: only `ThreadLaunchService.ts:686` calls `rejectCommandsDuringClone`, although its comment says every transport does (`apps/server/src/project/ProjectCloneTracker.ts:437-463`).
- Whether raw `thread.create` checks that `projectId` exists (no check found in `Orchestrator.ts:2183-2265`).
- The overwrite effect of a duplicate `thread.create` with a new `commandId` (inferred from code).
