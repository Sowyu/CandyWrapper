# D. Server-backed feature surfaces (non-core)

Research notes for the native macOS client (Swift 6 + AppKit). Scope: every server-backed feature surface except the core RPC transport, orchestration (threads, turns, messages) and auth/T3 Connect, which another researcher covers.

- Source: `/Users/mrm/CandyWrapper-research/t3code` at tag `v0.0.46-nightly.20261009.2861` (commit `3b6af0bd1`). This is the exact server version running on this machine.
- Citations are repo-relative `path:line` or `path:start-end`.
- **UNVERIFIED** marks anything I could not confirm in source.
- "Web" means `apps/web`, "mobile" means `apps/mobile` (React Native), "desktop" means `apps/desktop` (Electron), "client-runtime" means `packages/client-runtime` (logic shared by web and mobile).
- Method of work: read-only. Subagents were unavailable (concurrency limit), so one researcher read everything. Depth varies by area; see each section's open questions.

## 0. Cross-cutting facts used by every section

### 0.1 Wire encoding of schema types

RPC payloads use Effect RPC with `RpcSerialization.layerJson` on both sides (`apps/server/src/ws.ts:3190`, `packages/client-runtime/src/rpc/session.ts:211`). JSON serialization encodes every payload through `Schema.toCodecJson` (`.repos/effect-smol/packages/effect/src/rpc/RpcSerialization.ts:29-41`, `RpcServer.ts:1504`). Consequences for the Swift codecs:

| Effect schema | JSON on the wire | Source |
|---|---|---|
| `Schema.Option(X)` | `{"_tag":"Some","value":X}` or `{"_tag":"None"}` | `.repos/effect-smol/packages/effect/src/Schema.ts:13812-13823` |
| `Schema.DateTimeUtc` | UTC ISO-8601 string | `.repos/effect-smol/packages/effect/src/Schema.ts:11158-11186` |
| `IsoDateTime` (contracts) | plain string, no validation | `packages/contracts/src/baseSchemas.ts:47` |
| `TrimmedNonEmptyString` | string, trimmed on decode and encode, must be non-blank | `packages/contracts/src/baseSchemas.ts:7-27` |
| `NonNegativeInt` / `PositiveInt` | integer >= 0 / >= 1 | `packages/contracts/src/baseSchemas.ts:29-30` |
| `Schema.optional(X)` | key may be absent or `undefined` (absent in JSON) | Effect semantics |
| `Schema.optionalKey(X)` | key may be absent; if present must decode as X | Effect semantics |
| `Schema.NullOr(X)` | value may be `null` | Effect semantics |
| `Schema.TaggedError` / `TaggedStruct` | object with a `_tag` discriminator | Effect semantics |
| `ForwardCompatibleArray(X)` | plain JSON array; on decode, elements that fail X are dropped instead of failing the payload | `packages/contracts/src/baseSchemas.ts:114-170` |
| `ForwardCompatibleOptional(X)` | optional key; an unknown literal decodes as absent | `packages/contracts/src/baseSchemas.ts:50-69` |
| `ForwardCompatibleNullable(X)` | unknown literal or missing key decodes as `null` | `packages/contracts/src/baseSchemas.ts:71-87` |
| `OmittedWhenNull(X)` | `null` is never sent; encodes as a missing key | `packages/contracts/src/baseSchemas.ts:89-112` |
| `ForwardCompatibleUnion` | unknown `tag` values decode to an "unknown member" instead of failing | `packages/contracts/src/baseSchemas.ts:178-200` |

The Swift client should copy these tolerance rules: drop unknown array elements, treat unknown optional literals as absent, and never fail a whole config or snapshot decode over one unknown member.

### 0.2 RPC catalog and required scopes

All WebSocket RPC names live in `WS_METHODS` (`packages/contracts/src/rpc.ts:360-568`). The served group is `WsRpcGroup` (`packages/contracts/src/rpc.ts:1811-1997`), wrapped with `RpcScopeAuthorization` middleware. The server registers handlers with `ServerWsRpcGroup.of({...})` (`apps/server/src/ws.ts:545`, `apps/server/src/ws.ts:1817`).

`projects.list`, `projects.add`, `projects.remove` exist only as constants (`packages/contracts/src/rpc.ts:362-364`). No `Rpc.make` and no handler exist for them. Do not call them.

Each RPC declares one required scope in `RPC_REQUIRED_SCOPES` (`apps/server/src/auth/RpcAuthorization.ts:43-209`). Special cases in `requiredScopesForRpcCall` (`apps/server/src/auth/RpcAuthorization.ts:243-265`):

- `server.retryResourceTelemetry` needs both `environment:maintain` and `diagnostics:read`.
- `assets.createUrl` needs `filesystem:read` when `resource._tag` is `workspace-file`, `media-file` or `draft-workspace-file`, otherwise `orchestration:read`.
- `server.updateSettings` needs the scopes returned by `requiredScopesForServerSettingsPatch(patch)` (`packages/contracts/src/settings.ts:1596`). With a `providerInstanceMutation` it also needs `providers:manage`; with an empty patch plus a mutation, only `providers:manage` (`apps/server/src/auth/RpcAuthorization.ts:228-241`).
- `git.preparePullRequestThread` with `mode: "worktree"` and a `threadId` needs `source-control:write` and `orchestration:operate` (`packages/contracts/src/clientRpcPermissions.ts:47-55`).
- `device.list` escalates to `orchestration:operate` when `retryHostId` or `updateTool` is set (`apps/server/src/auth/RpcAuthorization.ts`, `requiredScopeForDeviceList` at the end of the file).

Scope strings (`packages/contracts/src/auth.ts:82-99`): `orchestration:read`, `orchestration:operate`, `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `diagnostics:read`, `terminal:read`, `terminal:operate`, `source-control:write`, `filesystem:read`, `filesystem:write`, `review:write` (not grantable), `access:read`, `access:write`, `relay:read`, `relay:write`. Legacy broad grants imply children: `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `source-control:write` all fall under `orchestration:operate` for old sessions (`packages/contracts/src/auth.ts:157-161`, `:183-192`).

The client mirrors a subset in `CLIENT_GUARDED_RPC_SCOPES` (`packages/contracts/src/clientRpcPermissions.ts:11-42`) to hide or disable controls before calling. A permission failure is `EnvironmentAuthorizationError` with message `The authenticated token is missing required scope: <scope>.` (`apps/server/src/auth/RpcAuthorization.ts:221-225`).

### 0.3 Capability flags advertised by this server

The descriptor (`GET /.well-known/t3/environment`, also `ServerConfig.environment`) carries `capabilities` (`packages/contracts/src/environment.ts:98-215`). This server version sets (`apps/server/src/environment/ServerEnvironment.ts:217-262`):

| Flag | Value here | Gates |
|---|---|---|
| `repositoryIdentity` | `true` | repository identity on projects (git remote based) |
| `connectionProbe` | `true` | `server.probe` |
| `attachmentUploads` | `true` | HTTP upload flow instead of inline base64 images |
| `questionAttachments` | `true` | files on question answers |
| `fileAttachments.maxUploadBytes` | `52428800` (50 MiB, `PROVIDER_SEND_TURN_MAX_FILE_BYTES`, `packages/contracts/src/chatAttachment.ts:17`) | non-image attachments |
| `pullRequests` | `true` | `pullRequests.*` |
| `pullRequestChecks` | `true` | `pullRequests.checks` |
| `inlineMessageContext` | `true` | canonical inline context links in messages |
| `requiredWorktreeBootstrap` | `true` | server rejects required worktrees instead of falling back |
| `threadSettlement`, `threadAutoSettlement`, `threadSnooze`, `threadPinning`, `threadPinReorder`, `threadActiveReorder`, `threadAutoSettleOptOut`, `threadTitleRegeneration`, `threadVisitedTracking`, `threadRestartContinuation`, `serverResolvedCommandContext` | `true` | orchestration commands (other researcher) |
| `storageCleanup` | `true` | storage cleanup |
| `projectWorktreeCleanup` | `true` | worktree cleanup UI |
| `worktreesDirectory` | `true` | `worktreesDirectory` setting honored |
| `projectSettingsOverrides` | `true` | per-project settings overrides |
| `environmentThemes` | `true` | `environmentThemesUpdated` config events |
| `usageLimitSources` | `true` | `usageLimitSourcesUpdated` config events |
| `usagePriceOverrides`, `usageModelAliases` | `true` | usage pricing settings |
| `threadPullRequests`, `threadPullRequestWatch`, `threadPullRequestLinking`, `pullRequestStackActions` | `true` | PR features |
| `environmentIcon` | `true` | `environmentIcon` setting persists |
| `projectCloneTracking` | `true` | `projectClone.*` + `subscribeProjectClones` |
| `serverBrowser` | `true` | server-hosted headless Chromium preview tabs over `/api/preview-stream` |
| `serverSelfUpdate` | depends on launch mode (`boot-service`, `respawn`, `desktop-managed`, or absent) | update UI |
| `serverInstallation` | only when `serverSelfUpdate` is absent and ownership is proven | manual update command text |
| `serverSelfUpdateProgress` | `true` when `serverSelfUpdate` is `boot-service` or desktop app update is available | `server.updateServerWithProgress` |
| `desktopAppUpdate` | `true` only for desktop-managed servers with a control fd | remote desktop update |
| `agentActivityPublishing` | read per descriptor request from secrets | Live Activities / push |
| `serverUpdateThreadContinuation` | never set by this server | |

`ServerConfig` adds feature flags that are not in `capabilities` (`packages/contracts/src/server.ts:644-714`, values set in `apps/server/src/ws.ts:1700-1740`): `shellResumeCompletionMarker: true`, `threadResumeCompletionMarker: true`, `threadSnapshotPagination: true`, `threadFind: true`, `threadFindProgressive: true`, `shellRevealInFileManager` + `shellRevealInFileManagerKind` (only when the `file-manager` editor is detected), `scratchWorkspaceRoot` (only when the managed scratch root resolves), `newProjectsRoot` (always). `reasoningMessages` is not set by this server.

### 0.4 Server config stream (`subscribeServerConfig`)

`subscribeServerConfig` (`packages/contracts/src/rpc.ts:1679-1701`, scope `orchestration:read`) is the main live channel for settings, keybindings, provider status, themes and usage-limit sources. Payload opt-ins, all optional booleans:

- `environmentThemes`: client understands `environmentThemesUpdated`.
- `usageLimitSources`: client understands `usageLimitSourcesUpdated`.
- `usageLimitsCommand`: client answers the `/usage-limits` slash command itself; only then does the server inject it into provider catalogs.

Events (`packages/contracts/src/server.ts:784-853`), all with `version: 1`:

| `type` | payload | client action |
|---|---|---|
| `snapshot` | `config: ServerConfig` | replace the whole config |
| `keybindingsUpdated` | `{ keybindings: ResolvedKeybindingsConfig, issues: ServerConfigIssue[] }` | replace keybindings + issues |
| `providerStatuses` | `{ providers: ServerProvider[] }` | replace providers |
| `settingsUpdated` | `{ settings: ServerSettings }` | replace settings |
| `environmentThemesUpdated` | `{ themes: EnvironmentTheme[] }` (full set) | replace published themes |
| `usageLimitSourcesUpdated` | `{ sources: UsageLimitSourceSnapshots }` (full set) | replace sources |

The server can send a second `snapshot` after the first one when editor discovery finishes late (`withLateEditorConfig`, `apps/server/src/ws.ts:298-360`). Clients must replace their config on every `snapshot` and keep projected themes and usage-limit sources across snapshots, because those two never ride in a snapshot (`apps/server/src/ws.ts:352-356`).

`ServerConfigIssue` (`packages/contracts/src/server.ts:32-51`): `{kind:"keybindings.malformed-config", message}` or `{kind:"keybindings.invalid-entry", message, index:number}`, inside a `ForwardCompatibleArray`.

### 0.5 HTTP endpoints outside the RPC socket (index)

| Method + path | Purpose | Defined in |
|---|---|---|
| `GET /ws` | RPC WebSocket (other researcher) | `apps/server/src/ws.ts:3136` |
| `GET /.well-known/t3/environment` | descriptor incl. capabilities | `packages/contracts/src/environmentHttp.ts:450` |
| `GET /api/assets/<kind>/<rest>` | signed asset bytes (attachments, workspace files, media, GitHub media proxy) | `apps/server/src/http.ts:396-447`, prefix `apps/server/src/assets/AssetAccess.ts:62` |
| `POST /api/attachments/upload/<token>` | attachment upload | `apps/server/src/http.ts:449`, prefix `apps/server/src/assets/AttachmentUpload.ts:35` |
| `GET /api/projects`, `POST /api/projects/mutate` | project snapshot and mutation over HTTP | `packages/contracts/src/environmentHttp.ts:645-660` |
| `POST /api/pull-requests/diff` | PR diff | `packages/contracts/src/environmentHttp.ts:662` |
| `POST|PUT|PATCH|GET /api/hooks/:hookId/:token` | scheduled-task webhooks | `packages/contracts/src/environmentHttp.ts:753-759`, `apps/server/src/scheduledTasks/ScheduledTaskService.ts:58` |
| `GET /api/preview-stream/ws`, `GET /api/preview-stream/download`, `POST /api/preview-stream/upload` | server-hosted browser tabs | `apps/server/src/preview/ServerBrowserStream.ts:28-286` |
| `* /api/device-hub/*` (incl. WS `/api/devices/ws` upstream) | device streaming proxy | `apps/server/src/device/DeviceHubProxy.ts:197`, `apps/server/src/device/DeviceService.ts:73` |
| `POST /mcp` (+ OAuth endpoints, `/connect-agent`) | T3's MCP server for agents | `apps/server/src/mcp/McpHttpServer.ts:849`, `apps/server/src/auth/mcpOAuthHttp.ts:18` |
| `POST /api/observability/v1/traces` | browser OTLP trace proxy | `apps/server/src/http.ts:52`, `:325-375` |
| `GET *` | static web app | `apps/server/src/http.ts:679` |

Additional encoding note: `Schema.Defect()` fields (the `cause` on many errors) carry arbitrary JSON. JS `Error` values encode as `{name, message, cause?}` (`.repos/effect-smol/packages/effect/src/Schema.ts:8973-9028`). Treat `cause` as opaque JSON in Swift.

### 0.6 T3 home layout (server side, for reference)

`deriveServerPaths` (`apps/server/src/config.ts:132-167`): base dir (default `~/.t3`) contains `userdata/` (or `dev/` for dev servers) with `statev2.sqlite`, `attachments/`, `logs/` (`server.trace.ndjson`, `provider/events.log`, `terminals/`), `keybindings.json`, `keybindings-migrations`, `settings.json`, `themes/`, `browser-artifacts/`, `anonymous-id`, `environment-id`, `server-runtime.json`, `secrets/`. Outside `userdata`: `caches/` (provider status cache, managed ACP binaries) and `worktrees/`. A remote native client never touches these paths; they matter only for explaining server behavior.

---

## 1. Terminal

### 1.1 What it does, where it appears

The environment server owns PTYs, their lifetime and retained output; every client, including the desktop renderer, attaches over the RPC connection, so clients can reconnect or share a running shell (`docs/internals/terminal-runtime.md:3-6`). Terminals belong to a thread. A thread can have several terminals, grouped into split groups of up to 4 (`MAX_TERMINALS_PER_GROUP = 4`, `apps/web/src/types.ts:36`).

Web UI: `apps/web/src/components/ThreadTerminalDrawer.tsx` (drawer with tabs, horizontal/vertical splits, context menu, "add selection to chat"), UI state in `apps/web/src/terminalUiStateStore.ts`, link detection `apps/web/src/terminal-links.ts`, renderer `apps/web/src/terminal/ghostty/*`. Mobile: `apps/mobile/src/features/terminal/*` with the native module `apps/mobile/modules/t3-terminal`.

### 1.2 RPC methods

| Method | Kind | Payload | Success | Errors | Scope |
|---|---|---|---|---|---|
| `terminal.open` | unary | `TerminalOpenInput` | `TerminalSessionSnapshot` | `TerminalError` | `terminal:operate` |
| `terminal.attach` | stream | `TerminalAttachInput` | `TerminalAttachStreamEvent` | `TerminalError` | `terminal:operate` |
| `terminal.observe` | stream | `TerminalObserveInput` | `TerminalAttachStreamEvent` | `TerminalError` | `terminal:read` |
| `terminal.write` | unary | `TerminalWriteInput` | void | `TerminalError` | `terminal:operate` |
| `terminal.resize` | unary | `TerminalResizeInput` | void | `TerminalError` | `terminal:operate` |
| `terminal.clear` | unary | `TerminalClearInput` | void | `TerminalError` | `terminal:operate` |
| `terminal.restart` | unary | `TerminalRestartInput` | `TerminalSessionSnapshot` | `TerminalError` | `terminal:operate` |
| `terminal.close` | unary | `TerminalCloseInput` | void | `TerminalError` | `terminal:operate` |
| `subscribeTerminalEvents` | stream | `{}` | `TerminalEvent` (all terminals, all threads) | none declared | `terminal:read` |
| `subscribeTerminalMetadata` | stream | `{}` | `TerminalMetadataStreamEvent` | none declared | `terminal:read` |

Definitions: `packages/contracts/src/rpc.ts:1389-1433`, `:1665-1677`. Scopes: `apps/server/src/auth/RpcAuthorization.ts:182-191`. Every method can also fail with `EnvironmentAuthorizationError`. Handlers: `apps/server/src/ws.ts:2860-2893`.

### 1.3 Schemas (`packages/contracts/src/terminal.ts`)

Constraints (`terminal.ts:13-26`): `cols` int 1..1000; `rows` int 1..500; `terminalId` trimmed non-empty, max 128; env keys match `^[A-Za-z_][A-Za-z0-9_]*$`, max 128 chars; env values max 8192 chars; env record max 128 entries.

Identity: `terminalId` is always chosen by the client; the server never allocates (`terminal.ts:33`). Convention is `term-N` with `DEFAULT_TERMINAL_ID = "term-1"` (`terminal.ts:5-10`). The shared allocator picks the lowest unused `term-N`, and appends `-<uuid>` when terminal metadata is unavailable so an unseen host session is not reused by accident (`packages/shared/src/terminalLabels.ts:31-49`). Labels: `term-N` or `terminal-N` (optionally with a uuid suffix) display as `Terminal N` (`packages/shared/src/terminalLabels.ts:3-17`).

- `TerminalOpenInput` (`terminal.ts:40-48`): `threadId` (string, required), `terminalId` (required), `cwd` (required), `worktreePath?: string|null`, `cols?`, `rows?`, `env?: Record<string,string>`, `providerInstanceId?: string`.
- `TerminalAttachInput` (`terminal.ts:51-60`): same as open but `cwd` optional, plus `restartIfNotRunning?: boolean`.
- `TerminalObserveInput` = `{threadId, terminalId}` (`terminal.ts:63`).
- `TerminalWriteInput` (`terminal.ts:66-69`): `{threadId, terminalId, data}`; `data` non-empty, max 65,536 chars.
- `TerminalResizeInput` (`terminal.ts:72-76`): `{threadId, terminalId, cols, rows}` (both required).
- `TerminalClearInput` = `{threadId, terminalId}`.
- `TerminalRestartInput` (`terminal.ts:82-90`): `threadId`, `terminalId`, `cwd` (required), `worktreePath?: string|null`, `cols` and `rows` (required), `env?`, `providerInstanceId?`.
- `TerminalCloseInput` (`terminal.ts:93-97`): `threadId`, `terminalId?` (omit to close all of the thread's terminals), `deleteHistory?: boolean`.
- `TerminalSessionStatus`: `"starting" | "running" | "exited" | "error"` (`terminal.ts:100`).
- `TerminalSessionSnapshot` (`terminal.ts:103-117`): `threadId`, `terminalId`, `cwd` (non-empty strings), `worktreePath: string|null`, `status`, `pid: int>0 | null`, `history: string` (the retained, sanitized scrollback), `exitCode: int|null`, `exitSignal: int|null`, `label: string` (max 128, server-computed: running subprocess name or `Terminal N`), `updatedAt: string` (ISO), `sequence?: int>=0`.
- `TerminalSummary` (`terminal.ts:120-133`): same as the snapshot minus `history` and `sequence`, plus `hasRunningSubprocess: boolean`.
- `TerminalMetadataStreamEvent` (`terminal.ts:136-156`): `{type:"snapshot", terminals: TerminalSummary[]}` | `{type:"upsert", terminal: TerminalSummary}` | `{type:"remove", threadId, terminalId}`.
- `TerminalEvent` (`terminal.ts:159-222`), each with `threadId`, `terminalId`, `sequence?`: `started{snapshot}`, `output{data: string}`, `exited{exitCode: int|null, exitSignal: int|null}`, `closed`, `error{message}`, `cleared`, `restarted{snapshot}`, `activity{hasRunningSubprocess: boolean, label: string<=128}`.
- `TerminalAttachStreamEvent` (`terminal.ts:225-239`): `{type:"snapshot", snapshot}` plus the `TerminalEvent` members except `started`. The attach-stream `output`/`exited`/etc. members still carry `threadId`, `terminalId`, `sequence?`.
- Errors (`terminal.ts:242-383`, all `TaggedError` with `_tag`): `TerminalCwdNotFoundError{cwd}`, `TerminalCwdNotDirectoryError{cwd}`, `TerminalCwdStatError{cwd, cause}`, `TerminalHistoryError{operation: "read"|"truncate"|"migrate", threadId, terminalId, cause?}`, `TerminalSessionLookupError{threadId, terminalId}`, `TerminalProviderInstanceNotFoundError{providerInstanceId}`, `TerminalProviderEnvironmentError{providerInstanceId, cause}`, `TerminalNotRunningError{threadId, terminalId}`, `TerminalWriteError{threadId, terminalId, terminalPid: number, cause}`, `TerminalResizeError{threadId, terminalId, terminalPid, cols, rows, cause}`.

### 1.4 HTTP endpoints

N/A. All terminal traffic rides the RPC WebSocket.

### 1.5 Streaming and event model

- **Keying.** Sessions are keyed by `(threadId, terminalId)` (`apps/server/src/terminal/Manager.ts:1245-1247`). `cwd` and `worktreePath` are launch parameters, not keys. The project and environment are implied by the thread.
- **Attach** (`Manager.ts:2715-2765`, `:2797-2859`). The server subscribes to terminal events first, buffers them, computes the initial snapshot, sends `{type:"snapshot"}`, then flushes buffered events whose `sequence` is greater than the snapshot's `sequence`, then goes live. If no session exists and `cwd` is absent, the stream fails with `TerminalSessionLookupError`; with `cwd`, it opens the session (same as `terminal.open`). If the session exists but has no process and `restartIfNotRunning: true` and `cwd` are given, it reopens. If running and `cols`/`rows` differ, it resizes. A `started` event during attach is translated into a `snapshot` event (`Manager.ts:427-443`).
- **Observe** (`Manager.ts:2861-2869`). Same stream shape, but requires an existing session (`TerminalSessionLookupError` otherwise) and never starts, resizes or restarts anything. This is the read-only path for viewers with only `terminal:read`.
- **Output encoding.** `output.data` is the raw PTY output as a JS string (node-pty delivers decoded UTF-8, `apps/server/src/terminal/PtyAdapter.ts:37-44`). It is not base64 and carries no byte offsets. The snapshot's `history` is a sanitized copy: the server strips terminal query and reply sequences (CSI `n`, cursor position reports `R`, device attributes `c`, DECRQM `$p`/`$y`, XTVERSION `>q`, kitty keyboard `?u`, DCS DECRQSS/XTGETTCAP, OSC 10/11/12 color queries) so replay does not provoke fresh replies (`Manager.ts:1031-1230`, `docs/internals/terminal-runtime.md:40-44`). Live `output` is not sanitized.
- **Sequence.** Each session has a monotonically increasing `eventSequence` bumped on output, clear, exit, and similar events (`Manager.ts:457-465`). A replacement session (after eviction or server restart) starts again at 0, so compare sequences only within one attach stream.
- **Flow control.** `terminal.attach` and `subscribeTerminalEvents` run under `withTerminalOutputWindow` (`apps/server/src/terminal/OutputProtocol.ts:5-66`, installed at `apps/server/src/ws.ts:3173`). Effect RPC streams normally wait for a client `Ack` after every `Chunk` (`.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:402-430`, `:199-202`). For these two methods the server self-acks until 8 chunks or 64 KiB are outstanding, then waits for the client's real `{"_tag":"Ack","requestId":...}` messages. A Swift client that never acks will stall terminal output after about 64 KiB. Each `Chunk` carries a `values` array, so one frame may hold several events.
- **Resize.** Any operator can resize; the last resize wins (`Manager.ts:2977-2994`). Resizes for a missing or non-running session are silently ignored. The web client debounces resizes per `(environment, thread, terminal)` with a "latest wins" scheduler (`packages/client-runtime/src/state/terminal.ts:79-84`). Viewers using `terminal.observe` cannot resize.
- **Clear.** Empties history, persists, and emits `cleared` (`Manager.ts:2996-3016`). It does not send anything to the shell. On web, Ctrl+L (all platforms) and Cmd+K (macOS) trigger clear (`apps/web/src/keybindings.ts:375-398`).
- **Restart.** Stops the process, clears history, spawns a new shell, emits `restarted{snapshot}` (`Manager.ts:3018-3107`). Clients treat `restarted` like a fresh snapshot (`packages/client-runtime/src/state/terminalSession.ts:148-152`).
- **Open on an existing session** (`Manager.ts:2641-2701`). If `cwd`, `worktreePath` or `env` changed, the server kills the process, clears history and starts a new shell in place. If the session has exited or errored, it clears history and starts a new shell. Otherwise it only resizes when `cols`/`rows` differ and returns the snapshot. `env` comparison uses the sorted entries.
- **Exit.** Process exit emits `exited{exitCode, exitSignal}`; status becomes `exited`. `terminal.write` to an exited session is a silent no-op; to a starting/error session it fails with `TerminalNotRunningError` (`Manager.ts:2953-2974`).
- **Close.** `close` with `terminalId` closes one session (optionally deleting its history file). Without `terminalId`, it closes all sessions of the thread and, with `deleteHistory`, deletes all their history files (`Manager.ts:3109-3129`). Closing emits `closed` and a metadata `remove`.
- **Idle close (server-initiated).** `closeIdle` closes terminals that sit at an idle prompt when a thread settles or a setup script finishes, re-checking the process table first (`Manager.ts:207-219`, `:3131-3176`). A client must expect terminals to disappear without its request.
- **Metadata stream** (`Manager.ts:2871-2951`). First event is a full `snapshot` of all sessions in the environment (all threads), sorted by `updatedAt` desc. Then `upsert` for `started`, `restarted`, `exited`, `error`, `activity`, and `remove` for `closed`. `output` and `cleared` do not produce metadata events (`Manager.ts:412-425`).
- **Activity.** The server polls the process table (default every 1 s, backing off to 60 s) to detect a foreground subprocess; changes emit `activity{hasRunningSubprocess, label}` (`Manager.ts:101-102`, `:671-750`). The label becomes the child command basename (e.g. `vim`) while it runs.
- **Retention.** History cap 5,000 lines and 8 MiB UTF-8 per terminal, oldest output evicted, never splitting code points (`Manager.ts:97-99`, `docs/internals/terminal-runtime.md:18-23`). History persists to `logs/terminals/terminal_<base64url(threadId)>.log` for `term-1`, or `..._<base64url(terminalId)>.log` for other ids, with a 40 ms coalesced write (`Manager.ts:100`, `:1591-1597`). On first open after a server restart the server restores the bounded tail of that file. Running processes do not survive a server restart: a reconnecting client's attach (with `cwd`) creates a new shell seeded with the restored history.
- **In-memory session cap.** At most 128 inactive (non-running) sessions stay in memory; the oldest are evicted (`Manager.ts:104`, `:1979-2006`).

### 1.6 Capability flags

None specific. Terminal methods exist on every server version this client targets. Scope gating matters: a token with only `terminal:read` can `observe` and receive metadata, but cannot `attach`, `open`, `write` or `resize`.

### 1.7 Server behavior a client must know

- **Shell.** On macOS/Linux: `$SHELL`, then `/bin/zsh`, `/bin/bash`, `/bin/sh`, `zsh`, `bash`, `sh`; zsh gets `-o nopromptsp` (`Manager.ts:492-618`, `:535-548`). Windows: `pwsh.exe`, Windows PowerShell, `powershell.exe`, `%ComSpec%`, `cmd.exe`. The client cannot choose the shell.
- **Defaults.** `cols=120`, `rows=30` when omitted (`Manager.ts:105-106`).
- **Environment.** Server process env minus keys starting `T3CODE_` or `VITE_` and minus `PORT`, `ELECTRON_RENDERER_PORT`, `ELECTRON_RUN_AS_NODE`; AppImage runtime variables scrubbed; then the client's `env` merged on top; `COLORTERM=truecolor` unless overridden (`Manager.ts:1249-1343`). Directories of managed ACP-registry agent binaries are appended to `PATH` (`Manager.ts:2248-2280`). With `providerInstanceId`, the provider instance's configured environment is merged, plus `CODEX_HOME` for Codex instances and the Claude config env for Claude instances (`Manager.ts:1394-1434`).
- **Client env convention.** The web sends `T3CODE_PROJECT_ROOT=<project workspace root>` and, for worktree threads, `T3CODE_WORKTREE_PATH=<worktree>` (`packages/shared/src/projectScripts.ts:58-71`). Client-supplied keys bypass the `T3CODE_` filter because the filter applies only to the server's own env.
- **Locks.** All lifecycle operations for a thread are serialized by a per-thread lock and a workspace lease on the resolved cwd (`Manager.ts:2703-2713`, `:3096-3107`).
- **PTY implementation.** `node-pty` via `NodePtyAdapter` (`apps/server/src/terminal/NodePtyAdapter.ts:27-36`).

### 1.8 How web and mobile use it

- **client-runtime atoms** (`packages/client-runtime/src/state/terminal.ts:19-104`): `attach` and `observe` streams folded by `applyTerminalAttachStreamEvent`; `metadata` folded by `applyTerminalMetadataStreamEvent`; `open`, `clear`, `restart`, `close` serialized per `(environmentId, threadId)`; `resize` "latest wins" per session.
- **Client buffer.** Clients keep at most 512 KiB of output (`DEFAULT_MAX_TERMINAL_BUFFER_BYTES`) in at most 1,024 chunks (`packages/client-runtime/src/state/terminalOutput.ts:45-47`). A new attach stream gets a new output "generation" so a reattached renderer never reuses an old cursor (`terminalSession.ts:86-97`).
- **Drawer attach input.** The drawer calls attach with `threadId`, `terminalId`, `cwd`, `worktreePath`, `env` (project runtime env) and `providerInstanceId` (`apps/web/src/components/ThreadTerminalDrawer.tsx:441-452`).
- **Project scripts.** The client runs a script by `terminal.open` (new terminal if the base terminal is busy or the user asked for one), then `terminal.write` of `"<command>\r"`, then optionally opening the preview URL (`apps/web/src/components/ChatView.tsx:4955-5060`). The server does not run scripts except worktree setup scripts (see section 2).
- **Labels.** Tab labels come from the metadata `label` when present, else `Terminal N` (`packages/shared/src/terminalLabels.ts:19-29`).
- **Links.** URLs (`https?://...`) and file paths (absolute, `~/`, `./`, `../`, Windows drive, UNC, or `a/b/c` with optional `:line:col`) are detected client-side; trailing punctuation and unbalanced brackets are trimmed (`apps/web/src/terminal-links.ts:29-60`). Paths open in the preferred editor through `shell.openInEditor`; URLs can open in the preview.
- **Selection to chat.** A terminal selection can be added to the composer as context (`ThreadTerminalDrawer.tsx:423-426`, `:636-700`). The context format belongs to section 8.
- **Keyboard (web).** Shift+PageUp/PageDown scroll scrollback; Ctrl/Cmd+Shift+Home/End jump; Cmd+A (mac) or Ctrl+Shift+A select all (`docs/user/terminal.md:10-18`). On macOS, Option+Left/Right send `ESC b`/`ESC f`, Cmd+Left/Right send `^A`/`^E`, Cmd+Backspace sends `^U` (`apps/web/src/keybindings.ts:400-470`). Server keybinding commands: `terminal.toggle`, `terminal.split`, `terminal.splitVertical`, `terminal.new`, `terminal.close` (section 5).
- **Fonts.** Terminal font family and size come from client settings `fontFamilyTerminal`/`fontSizeTerminal`, falling back to the code font (`ThreadTerminalDrawer.tsx:427-440`).
- **Mobile.** Mobile drives a native libghostty surface. Remote output is fed with `ghostty_surface_feed_data`; user input and measured `{cols, rows}` come back to JS, which calls `terminal.write` and `terminal.resize` (`apps/mobile/modules/t3-terminal/README.md:1-23`). iOS uses `GhosttyKit.xcframework` from a Ghostty fork with a custom-I/O branch (`README.md:25-33`), `T3TerminalView.swift` (760 lines).

### 1.9 Browser engine or JS runtime dependency

**No for the protocol, yes for the web renderer.** Web renders with official `libghostty-vt` compiled to WebAssembly (`apps/web/src/terminal/ghostty/vendor/ghostty-vt.wasm`) drawn on Canvas 2D (`apps/web/src/terminal/ghostty/README.md:1-20`). That WASM build needs a JS engine. The native client does not need it: the wire protocol is plain strings, and the server already does all PTY work. Native alternatives, best first:

1. libghostty native, as mobile iOS already does with `GhosttyKit.xcframework` (Metal renderer, custom I/O feed). The pinned upstream revision is `native/libghostty-vt/VERSION` (`9f62873bf195e4d8a762d768a1405a5f2f7b1697`); mobile iOS uses fork revision `cf8edc23f3a6a87a96e41a90013e89e987d34980`.
2. SwiftTerm (pure Swift VT emulator with an AppKit `TerminalView`). Easier to integrate; less exact parity with Ghostty rendering.

Whichever renderer is used must, like the web adapter, detach its PTY-reply writer while replaying `snapshot.history` so historic device queries do not produce junk input (`docs/internals/terminal-runtime.md:40-44`).

### 1.10 Unverified and open questions

- Whether the server flushes or truncates partially written UTF-8 sequences across `output` events. node-pty decodes UTF-8 itself, so JSON strings should always be valid; UNVERIFIED for split surrogate pairs.
- The exact debounce intervals the web uses for resize; only "latest wins" scheduling is confirmed.
- Whether any MCP tool lets agents drive terminals. None appears among terminal code paths; UNVERIFIED across all toolkits.

---

## 2. Git, VCS, worktrees, source control hosting, diffs

### 2.1 What it does, where it appears

- **Git actions** on a thread: commit, push, commit+push, create PR, commit+push+PR, optional "feature branch" checkout before committing, pull (fast-forward only), branch list/create/switch, init repository, publish a local repo to a host. Web: `apps/web/src/components/GitActionsControl.tsx` (+ `GitActionsControl.logic.ts`, 2,213 + 494 lines), branch toolbar `BranchToolbar*.tsx`, `BranchPicker.tsx`, `WorktreeBaseBranchPicker.tsx`, `PreviousWorktreeItemContent.tsx`.
- **Worktrees**: threads can run in the project checkout (`local`) or a fresh git worktree (`worktree`) (`ThreadEnvMode`, `packages/contracts/src/environment.ts:56-62`). Worktree creation for a new thread happens inside orchestration thread launch; its progress is exposed through `subscribeWorktreeSetup`.
- **Diffs**: "Changes" view (working tree vs `HEAD`, and merge-base vs the base branch) through `review.getDiffPreview`; per-turn and whole-thread diffs from checkpoints through `orchestration.getTurnDiff` / `orchestration.getFullThreadDiff`. Web: `apps/web/src/components/DiffPanel.tsx` (1,274 lines), `apps/web/src/components/diffs/*`, `apps/web/src/lib/diffRendering.ts`, `apps/web/src/lib/diffFileContents.ts`.
- **Hosting providers**: GitHub (API with token, `gh` fallback), GitLab (`glab`), Forgejo/Gitea (`fj` then `tea`), Bitbucket (REST API with tokens), Azure DevOps (`az` + devops extension) (`docs/user/source-control.md:1-90`; executables in `apps/server/src/sourceControl/GitHubSourceControlProvider.ts:169-170`, `GitLabSourceControlProvider.ts:102-103`, `ForgejoSourceControlProvider.ts:22-23`, `AzureDevOpsSourceControlProvider.ts:43-44`, `BitbucketSourceControlProvider.ts:194`). Settings page: Settings > Source Control.
- **VCS kinds**: `VcsDriverKind = "git" | "jj" | "unknown"` (`packages/contracts/src/vcs.ts:4`). Discovery reports Jujutsu with `implemented: false` (`apps/server/src/sourceControl/SourceControlDiscovery.ts:41-58`). Only git is implemented.

### 2.2 RPC methods

| Method | Kind | Payload | Success | Errors | Scope |
|---|---|---|---|---|---|
| `subscribeVcsStatus` | stream | `VcsStatusSubscriptionInput` | `VcsStatusStreamEvent` | `GitManagerServiceError` | `orchestration:read` |
| `vcs.refreshStatus` | unary | `VcsStatusInput` | `VcsStatusResult` | `GitManagerServiceError` | `orchestration:read` |
| `vcs.pull` | unary | `VcsPullInput` | `VcsPullResult` | `GitCommandError` | `source-control:write` |
| `vcs.listRefs` | unary | `VcsListRefsInput` | `VcsListRefsResult` | `GitCommandError` | `orchestration:read` |
| `vcs.createRef` | unary | `VcsCreateRefInput` | `VcsCreateRefResult` | `GitCommandError` | `source-control:write` |
| `vcs.switchRef` | unary | `VcsSwitchRefInput` | `VcsSwitchRefResult` | `GitCommandError` | `source-control:write` |
| `vcs.createWorktree` | unary | `VcsCreateWorktreeInput` | `VcsCreateWorktreeResult` | `GitCommandError` | `source-control:write` |
| `vcs.removeWorktree` | unary | `VcsRemoveWorktreeInput` | void | `GitCommandError` | `source-control:write` |
| `vcs.init` | unary | `VcsInitInput` | void | `VcsError` | `source-control:write` |
| `git.runStackedAction` | stream | `GitRunStackedActionInput` | `GitActionProgressEvent` | `GitManagerServiceError` | `source-control:write` |
| `git.resolvePullRequest` | unary | `GitPullRequestRefInput` | `GitResolvePullRequestResult` | `GitManagerServiceError` | `orchestration:read` |
| `git.preparePullRequestThread` | unary | `GitPreparePullRequestThreadInput` | `GitPreparePullRequestThreadResult` | `GitManagerServiceError` | `source-control:write` (+ `orchestration:operate` in worktree mode with `threadId`) |
| `subscribeWorktreeSetup` | stream | `{threadId}` | `WorktreeSetupSnapshot \| null` | none declared | `orchestration:read` |
| `worktreeSetup.cancel` | unary | `{threadId}` | `{cancelled: boolean}` | none declared | `orchestration:operate` |
| `review.getDiffPreview` | unary | `ReviewDiffPreviewInput` | `ReviewDiffPreviewResult` | `ReviewDiffPreviewError` | `filesystem:read` |
| `review.getDiffFileContents` | unary | `ReviewDiffFileContentsInput` | `ReviewDiffFileContentsResult` | `ReviewDiffPreviewError` | `filesystem:read` |
| `server.discoverSourceControl` | unary | `{}` | `SourceControlDiscoveryResult` | none declared | `orchestration:read` |
| `sourceControl.lookupRepository` | unary | `SourceControlRepositoryLookupInput` | `SourceControlRepositoryInfo` | `SourceControlRepositoryError` | `orchestration:read` |
| `sourceControl.cloneRepository` | unary | `SourceControlCloneRepositoryInput` | `SourceControlCloneRepositoryResult` | `SourceControlRepositoryError` | `source-control:write` |
| `sourceControl.publishRepository` | unary | `SourceControlPublishRepositoryInput` | `SourceControlPublishRepositoryResult` | `SourceControlRepositoryError` | `source-control:write` |
| `orchestration.getTurnDiff` | unary | `OrchestrationGetTurnDiffInput` | `ThreadTurnDiff` | `OrchestrationGetTurnDiffError` | `orchestration:read` |
| `orchestration.getFullThreadDiff` | unary | `OrchestrationGetFullThreadDiffInput` | `ThreadTurnDiff` | `OrchestrationGetFullThreadDiffError` | `orchestration:read` |

Definitions: `packages/contracts/src/rpc.ts:748-752`, `:1108-1118`, `:1151-1155`, `:1287-1387`, `:1565-1578`. All also fail with `EnvironmentAuthorizationError`. Handlers: `apps/server/src/ws.ts:2783-2859`. Every mutating VCS handler triggers a status refresh for `cwd` afterwards (`apps/server/src/ws.ts:2793-2857`, `refreshGitStatus` at `:1741-1745`).

### 2.3 Schemas

`packages/contracts/src/git.ts` unless noted. "string" means `TrimmedNonEmptyString` unless stated.

- `GitStackedAction`: `"commit" | "push" | "create_pr" | "commit_push" | "commit_push_pr"` (`git.ts:18-24`).
- `GitActionProgressPhase`: `"branch" | "commit" | "push" | "pr"` (`git.ts:26`).
- `VcsRef` (`git.ts:83-90`): `name`, `isRemote?: boolean`, `remoteName?: string`, `current: boolean`, `isDefault: boolean`, `worktreePath: string|null` (the worktree that has this branch checked out).
- `VcsStatusInput` = `{cwd}`; `VcsStatusSubscriptionInput` = `{cwd, includeRemote?: boolean}` (`git.ts:109-118`). `includeRemote: false` makes the subscriber a passive observer: it gets cached remote status but does not keep the remote poller alive.
- `VcsPullInput` = `{cwd}`.
- `GitRunStackedActionInput` (`git.ts:126-138`): `actionId` (client-generated id echoed in every progress event), `cwd`, `action`, `commitMessage?` (max 10,000), `featureBranch?: boolean`, `filePaths?: string[]` (min 1; commit only these paths), `threadId?` (a PR it creates is linked to this thread), `projectId?` (selects per-project settings for text generation).
- `VcsListRefsInput` (`git.ts:141-151`): `cwd`, `query?` (max 256), `cursor?: int>=0`, `includeMatchingRemoteRefs?: boolean`, `refKind?: "all"|"local"|"remote"`, `refresh?: boolean`, `limit?: 1..200`.
- `VcsCreateWorktreeInput` (`git.ts:154-160`): `cwd`, `refName`, `newRefName?`, `baseRefName?`, `path: string|null` (null lets the server choose under the worktrees directory).
- `GitPullRequestRefInput` = `{cwd, reference}`; `reference` is a free string (URL, `#123`, number) (`git.ts:53`, `:163-166`).
- `GitPreparePullRequestThreadInput` (`git.ts:169-174`): `cwd`, `reference`, `mode: "local"|"worktree"`, `threadId?`.
- `VcsRemoveWorktreeInput` (`git.ts:177-181`): `cwd`, `path`, `force?: boolean`.
- `VcsCreateRefInput` (`git.ts:184-188`): `cwd`, `refName`, `switchRef?: boolean`. Result `{refName}`.
- `VcsSwitchRefInput` = `{cwd, refName}`; result `{refName: string|null}` (`git.ts:196-200`, `:324-326`).
- `VcsInitInput` (`git.ts:202-205`): `cwd`, `kind?: "git"|"jj"|"unknown"`.
- `VcsStatusLocalResult` (`git.ts:227-256`, `:266`): `isRepo: boolean`, `sourceControlProvider?: {kind, name, baseUrl}`, `hasPrimaryRemote`, `isDefaultRef`, `refName: string|null`, `hasWorkingTreeChanges`, `workingTree: {files: [{path, insertions:int, deletions:int}], insertions, deletions}`, `branchChanges?: {baseRef: string|null, insertions, deletions}`.
- `VcsStatusRemoteResult` (`git.ts:258-264`, `:269`): `hasUpstream`, `aheadCount`, `behindCount`, `aheadOfDefaultCount?`, `pr: VcsStatusChangeRequest|null` where `VcsStatusChangeRequest` = `{number:int>=1, title, url: string, baseRef, headRef, state: "open"|"closed"|"merged", isDraft?: boolean, updatedAt?: string|null}` (`git.ts:210-225`).
- `VcsStatusResult` = local fields + remote fields flattened (`git.ts:272-275`).
- `VcsStatusStreamEvent` (`git.ts:278-289`), tagged with `_tag`: `{_tag:"snapshot", local, remote: Remote|null}`, `{_tag:"localUpdated", local}`, `{_tag:"remoteUpdated", remote: Remote|null}`.
- `VcsListRefsResult` (`git.ts:292-298`): `refs: VcsRef[]`, `isRepo`, `hasPrimaryRemote`, `nextCursor: int|null`, `totalCount: int`.
- `VcsCreateWorktreeResult` = `{worktree: {path, refName}}` (`git.ts:93-96`, `:301-303`).
- `GitResolvedPullRequest` (`git.ts:97-104`): `number`, `title`, `url`, `baseBranch`, `headBranch`, `state: "open"|"closed"|"merged"`. `GitResolvePullRequestResult = {pullRequest}`.
- `GitPreparePullRequestThreadResult` (`git.ts:311-321`): `pullRequest`, `branch`, `worktreePath: string|null`, `isOnPullRequestHead: boolean` (decoding default `true` when the key is missing; false when a reused worktree kept local commits or changes).
- `GitRunStackedActionResult` (`git.ts:329-355`): `action`; `branch: {status: "created"|"skipped_not_requested", name?}`; `commit: {status: "created"|"skipped_no_changes"|"skipped_not_requested", commitSha?, subject?}`; `push: {status: "pushed"|"skipped_not_requested"|"skipped_up_to_date", branch?, upstreamBranch?, setUpstream?: boolean}`; `pr: {status: "created"|"opened_existing"|"skipped_not_requested", url?, number?, baseBranch?, headBranch?, title?}`; `toast: {title, description?, cta}` with `cta` one of `{kind:"none"}`, `{kind:"open_pr", label, url}`, `{kind:"run_action", label, action:{kind: GitStackedAction}}` (`git.ts:56-81`).
- `VcsPullResult` (`git.ts:358-362`): `status: "pulled"|"skipped_up_to_date"`, `refName`, `upstreamRef: string|null`.
- `GitActionProgressEvent` (`git.ts:451-507`), each with `actionId`, `cwd`, `action`, discriminated by `kind`: `action_started{phases: Phase[]}`, `phase_started{phase, label}`, `hook_started{hookName}`, `hook_output{hookName: string|null, stream: "stdout"|"stderr", text}`, `hook_finished{hookName, exitCode: int|null, durationMs: int|null}`, `action_finished{result: GitRunStackedActionResult}`, `action_failed{phase: Phase|null, message}`.
- Errors: `GitCommandError{operation, command, cwd, argumentCount?, exitCode?, stdoutLength?, stderrLength?, outputLength?, reason?, detail, cause?}` with `reason` in `authentication_failed`, `branch_already_exists`, `branch_checked_out_in_worktree`, `host_key_unverified`, `not_a_repository`, `path_already_exists`, `remote_unreachable`, `tag_would_be_clobbered` (`git.ts:371-400`). Git stderr is deliberately not included. `TextGenerationError{operation, detail, cause?}`, `GitManagerError{operation, cwd, detail, cause?}`, `GitPullRequestMaterializationError{cwd, pullRequestNumber, headRepository: string|null, headBranch, localBranch, cause}`. `GitManagerServiceError` = union of these plus `SourceControlProviderError` (`git.ts:402-449`).
- `VcsError` (`packages/contracts/src/vcs.ts:276-286`): `VcsProcessSpawnError`, `VcsProcessExitError{..., exitCode, detail, failureKind?: "authentication"|"not-found"|"rate-limited"|"command-failed", retryable?, stderrLength?, stderrTruncated?}`, `VcsProcessTimeoutError{..., timeoutMs}`, `VcsProcessStdinWriteError`, `VcsProcessOutputReadError{stream}`, `VcsProcessOutputLimitError{stream, maxBytes, observedBytes}`, `VcsProcessMissingExitCodeError`, `VcsRepositoryDetectionError{operation, cwd, detail, cause?}`, `VcsUnsupportedOperationError{operation, kind, detail}`.
- `WorktreeSetupSnapshot` (`packages/contracts/src/worktreeSetup.ts:51-71`): `threadId`, `phase: "running"|"done"|"failed"|"cancelled"`, `startedAt` (ISO string), `endedAt: string|null`, `branch: string|null`, `baseRef: string|null`, `worktreePath: string|null`, `setupScript: {name, command, terminalId}|null`, `stages: WorktreeSetupStage[]`, `error: string(<=1000)|null`, `sequence: int>=0`. `WorktreeSetupStage` (`worktreeSetup.ts:34-45`): `id: "fetch"|"checkout"|"submodules"|"setup-script"|"agent"`, `status: "pending"|"running"|"done"|"skipped"|"warning"|"failed"`, `startedAt`, `endedAt` (string|null), `percent: 0..100|null` (checkout only), `detail: string(<=200)|null`, `tail: string(<=400)[]` (last lines of setup-script output, ANSI stripped). Stage labels and order: `worktreeSetup.ts:103-124`.
- `ReviewDiffPreviewInput` (`packages/contracts/src/review.ts:6-17`): `cwd`, `baseRef?`, `ignoreWhitespace?`, `file?: {path, previousPath: string|null, sourceKind: "working-tree"|"branch-range"}`.
- `ReviewDiffPreviewResult` (`review.ts:62-66`): `cwd`, `generatedAt` (ISO string, DateTimeUtc), `sources: ReviewDiffPreviewSource[]` where each source (`review.ts:31-42`) is `{id, kind, title, baseRef: string|null, headRef: string|null, diff: string (unified patch), diffHash, truncated: boolean, files?: [{path, previousPath: string|null, additions: number, deletions: number}]}`.
- `ReviewDiffFileContentsInput` (`review.ts:45-53`): `cwd`, `sourceKind`, `changeType: "change"|"rename-pure"|"rename-changed"|"new"|"deleted"`, `baseRef: string|null`, `headRef: string|null`, `oldPath`, `newPath`. Result `{oldContents: string, newContents: string}`.
- Checkpoint diffs (`packages/contracts/src/checkpointDiff.ts`): `OrchestrationGetTurnDiffInput = {threadId, fromTurnCount:int>=0, toTurnCount:int>=0, ignoreWhitespace?}` with `from <= to`; `OrchestrationGetFullThreadDiffInput = {threadId, toTurnCount, ignoreWhitespace?}`; both return `ThreadTurnDiff = {threadId, fromTurnCount, toTurnCount, diff: string}`. Errors carry `message` and optional `cause`.
- Source control (`packages/contracts/src/sourceControl.ts`): `SourceControlProviderKind = "github"|"gitlab"|"forgejo"|"azure-devops"|"bitbucket"|"unknown"` (`:5-12`); `SourceControlProviderInfo = {kind, name, baseUrl: string}`; `SourceControlRepositoryInfo = {provider, nameWithOwner, url, sshUrl}` (`:59-64`); `SourceControlRepositoryLookupInput = {provider, repository, cwd?}`; `SourceControlCloneRepositoryInput = {provider?, repository?, remoteUrl?, destinationPath, protocol?: "auto"|"ssh"|"https"}`; result `{cwd, remoteUrl, repository: Info|null}`; `SourceControlPublishRepositoryInput = {cwd, provider, repository, visibility: "private"|"public", remoteName?, protocol?}`; result `{repository, remoteName, remoteUrl, branch, upstreamBranch?, status: "pushed"|"remote_added"}` (`:74-111`).
- `SourceControlDiscoveryResult` (`sourceControl.ts:113-172`): `versionControlSystems: [{kind: VcsDriverKind, implemented: boolean, label, executable?, status: "available"|"missing", version: Option<string>, installHint, detail: Option<string>}]`, `sourceControlProviders: [{kind: ProviderKind, label, executable?, status, version: Option, installHint, detail: Option, auth}]` with `auth = {status: "authenticated"|"unauthenticated"|"unknown", account: Option, host: Option, detail: Option, accounts?: [{host, account, active, authenticated, error?, environmentVariable?}]}`. `Option` fields use the `{_tag:"Some",value}` / `{_tag:"None"}` encoding (section 0.1).
- `ChangeRequest` (`sourceControl.ts:25-43`) is used by the PR area; its `updatedAt` is `Option<DateTimeUtc>`.
- Errors: `SourceControlProviderError{provider, operation, cwd, command?, repository?, reference?, detail, cause?}`, `SourceControlRepositoryError{provider, operation, detail, cause?}` (`sourceControl.ts:174-204`).

### 2.4 HTTP endpoints

None for this area. PR diffs have an HTTP endpoint, covered in section 3.

### 2.5 Streaming and event model

- **`subscribeVcsStatus`** (`apps/server/src/vcs/VcsStatusBroadcaster.ts:704-738`). Keyed by the realpath of `cwd`. First event is always `snapshot` with fresh local status and the cached remote status (possibly `null`). Later events are `localUpdated`, `remoteUpdated` or `snapshot`, published only when a part's JSON fingerprint changed (`:249-345`). No filesystem watcher: local status refreshes after each turn finishes (`apps/server/src/orchestration-v2/RunFinalizationService.ts:102`), after every VCS mutation RPC, on `vcs.refreshStatus`, and when the worktree MCP service changes things (`apps/server/src/mcp/WorktreeMcpService.ts:395`). A native client that wants live dirty-state while the user edits files outside agents must call `vcs.refreshStatus` itself (for example on window focus).
- **Remote poller.** Unless `includeRemote: false`, the subscription keeps a per-cwd remote poller alive. Interval is the `automaticGitFetchInterval` server setting; zero means "no automatic fetch" but still a 30 s default cadence for PR lookups; failures back off from 30 s up to 15 min (`VcsStatusBroadcaster.ts:33-35`, `:532-611`). Polls also respect the background policy (section 11).
- **`git.runStackedAction`** (`apps/server/src/git/GitManager.ts:2719-2933`). Order: `action_started{phases}`; then for each phase `phase_started` (labels "Preparing feature branch...", commit label, "Pushing...", "Preparing PR..." with provider terminology such as "MR" for GitLab); hook events around git hooks (`pre-commit` etc.); finally exactly one `action_finished{result}` or `action_failed{phase, message}`. The stream then completes; on failure it also fails with the error. `push` runs for `create_pr` only when there is no upstream or the branch is ahead. `create_pr` refuses a dirty tree ("Commit local changes before creating a PR."). `featureBranch` is only valid for commit actions. Push or PR from detached HEAD fails. When `threadId` is given, a created PR is linked to the thread (`apps/server/src/git/linkCreatedPullRequest.ts`, `apps/server/src/ws.ts:2812-2822`).
- **`subscribeWorktreeSetup`** (`apps/server/src/project/WorktreeSetupTracker.ts:327-357`). First emits the current snapshot or `null`, then a new full snapshot after every change. Sequences increase across setups of the same thread; stale ones are filtered. State is memory-only; a reconnect gets a fresh snapshot. The same snapshot is also persisted as a thread activity of kind `worktree-setup` (`packages/contracts/src/worktreeSetup.ts:74-82`), so a client renders finished setups from the thread projection and attaches the live stream only while it says `running`.
- **`worktreeSetup.cancel`** returns `cancelled: false` when nothing runs or the setup already handed off to the agent (`WorktreeSetupTracker.ts:73-82`, `:299-326`).

### 2.6 Capability flags

- `repositoryIdentity` (projects carry `RepositoryIdentity`, `packages/contracts/src/environment.ts:229-271`).
- `requiredWorktreeBootstrap`: server fails a required worktree instead of falling back to the project checkout.
- `worktreesDirectory`: server honors the `worktreesDirectory` setting.
- `projectWorktreeCleanup`: worktree cleanup UI is supported.
- `projectCloneTracking`: use `projectClone.*` instead of the blocking `sourceControl.cloneRepository` (section 4).
- `pullRequests`, `threadPullRequestLinking`: see section 3.
- `branchChanges` in local status and `files` in review sources are absent on older servers (`git.ts:245-255`, `review.ts:40-41`).

### 2.7 Server behavior a client must know

- **Pull** is `git pull --ff-only`; it fails on detached HEAD or without an upstream (`apps/server/src/vcs/GitVcsDriverCore.ts:2484-2525`).
- **Not available over RPC**: stash, amend, rebase, cherry-pick, discard or restore individual files, stage hunks, fetch on demand, delete branch, merge. The web shows "Commit or stash local changes before pushing." but offers no stash action (`apps/web/src/components/GitActionsControl.tsx:324`). Checkpoint revert is an orchestration command (other researcher).
- **Text generation.** Commit messages, branch names and PR title/body are generated server-side when not supplied, by the model in `sourceControlWriterModelSelection` (or `textGenerationModelSelection` when that is null), in the style `sourceControlWritingStyle` (`GitManager.ts:2780-2808`). PR templates are detected (`apps/server/src/sourceControl/PrTemplateDetection.ts`). Failures surface as `TextGenerationError`.
- **Review diff preview limits** (`apps/server/src/vcs/GitVcsDriverCore.ts:56-81`): patch output max 120,000 bytes (then `truncated: true`), per-file expansion max 1 MiB, untracked file counting stops after 5,000 files. Patches use `--find-renames --no-color --no-ext-diff --no-textconv --minimal --src-prefix=a/ --dst-prefix=b/`. Binary files cannot be expanded. Two sources are always returned: `working-tree` ("Uncommitted", base `HEAD`) and `branch-range` ("Changes vs <base>") (`GitVcsDriverCore.ts:2921-2946`).
- **Review cwd guard.** `review.*` refuses a `cwd` outside the server's own launch cwd or the managed worktree directories with `VcsRepositoryDetectionError` (`apps/server/src/review/ReviewService.ts:64-106`). UNVERIFIED how this interacts with projects outside the server cwd; the web may rely on this only for compact/mobile surfaces (the RPC comment calls it an "ephemeral live diff preview for compact/mobile surfaces", `packages/contracts/src/rpc.ts:1372-1376`).
- **Checkpoint diff limit** 10,000,000 bytes of git output (`apps/server/src/vcs/GitVcsDriver.ts:427`).
- **Hosting auth** lives on the server: GitHub token in Settings > Source Control (secret store) or `GH_TOKEN`/`GH_ENTERPRISE_TOKEN`, or `gh` >= 2.81.0; GitLab `glab auth login`; Forgejo/Gitea `fj`/`tea` logins; Bitbucket access token or API token + email in settings, else `T3CODE_BITBUCKET_*` env vars; Azure `az login` (`docs/user/source-control.md:9-90`). Settings fields `github.hosts`, `github.tokens`, `bitbucket` are in section 5.

### 2.8 How web and mobile use it

- client-runtime wraps every method as an atom command or subscription; mutating calls are guarded client-side by `source-control:write` (`packages/contracts/src/clientRpcPermissions.ts:11-35`).
- The diff panel requests `review.getDiffPreview` (Changes view) and checkpoint diffs (per turn), honoring a client-side "ignore whitespace" toggle (`apps/web/src/components/DiffPanel.tsx:330-370`), and expands full files lazily with `review.getDiffFileContents` (`DiffPanel.tsx:250`, `:393-404`, `apps/web/src/lib/diffFileContents.ts:80-100`).
- Publish wizard: provider choice gated on discovery readiness (installed + authenticated), repository prefilled from the account, remote name default `origin`, protocol default `ssh` (`GitActionsControl.tsx:523-670`).
- Diff line comments (`apps/web/src/components/diffs/DiffCommentAnnotation.tsx`) become composer context, not server review comments (section 8).
- Mobile renders diffs with a native Swift view (`apps/mobile/modules/t3-review-diff/ios/T3ReviewDiffView.swift`, 2,749 lines) but computes syntax tokens in JS with shiki (`apps/mobile/src/features/review/shikiReviewHighlighter.ts`) and passes them as JSON props (`apps/mobile/modules/t3-review-diff/ios/T3ReviewDiffModule.swift:1-60`).

### 2.9 Browser engine or JS runtime dependency

**No browser engine needed.** All data is JSON plus unified-diff text. Two client-side JS libraries are involved on web and must be replaced natively:

- Diff rendering: `@pierre/diffs` with a Web Worker pool (`apps/web/package.json` dependencies; `apps/web/src/components/DiffWorkerPoolProvider.tsx`). Native alternative: parse unified diffs in Swift and render with TextKit 2 or a custom `NSView`, as mobile iOS does with its own Swift view.
- Syntax highlighting: shiki (TextMate grammars, Oniguruma in WASM) on web and in mobile JS. Native alternatives: tree-sitter via SwiftTreeSitter, or a TextMate grammar engine compiled natively (for example syntect via a Rust static library). Avoid JavaScriptCore-based highlighters if the "no JS runtime" rule is strict.

### 2.10 Unverified and open questions

- Exact shape of the worktree path the server picks when `vcs.createWorktree.path` is `null` (depends on `worktreesDirectory`; see section 5). UNVERIFIED.
- Whether `vcs.listRefs.refresh: true` fetches from remotes. UNVERIFIED.
- How the review cwd guard behaves for projects outside the server's launch cwd (see 2.7).

