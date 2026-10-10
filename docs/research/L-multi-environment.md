# L. Multi-environment behavior of the official client

Research for milestone 6. Source: `/Users/mrm/CandyWrapper-research/t3code`. Citations use these shorthands:

- `CR/` is `packages/client-runtime/src/`
- `WEB/` is `apps/web/src/`
- `DESK/` is `apps/desktop/src/`

Wire details (descriptor, pairing, T3 Connect, DPoP) are in `C-auth-connect.md` and `protocol.md` and are not repeated. This file covers how the client holds many environments at once.

## 1. Environment model

### 1.1 Identity

An environment is identified by the `environmentId` in its descriptor. A route (a way to reach it) is not an identity. One saved environment can hold several routes: T3 Connect, direct URLs (loopback, LAN, tailnet, public) and SSH (`CR/connection/routes.ts:1-40`, `CR/connection/catalog.ts:56-71`). The client connects over the first route in preference order that answers as the expected environment id, and moves back to a better route later (`CR/connection/routes.ts:23-28`).

Default route order by kind: loopback, LAN, tailnet, public, SSH, relay (`CR/connection/routes.ts:106-113`). Users can reorder routes (`CR/connection/registry.ts:970`).

Pairing the same machine again over another address adds a route to the existing environment. The connection id is `bearer:<environmentId>:<origin>` (`CR/connection/onboarding.ts:100-102`). Pairing refuses an address whose descriptor id differs from the expected one, before it spends the one-time code (`CR/connection/onboarding.ts:112-123`).

### 1.2 Three sources of environments

1. **Primary (local).** Not persisted. A platform source rebuilds it on a 3 s poll (`WEB/connection/platform.ts:426,738`). The poll reads the desktop bridge or window origin, then fetches `GET /.well-known/t3/environment` only when the signature changed or the cached entry expired (`WEB/connection/platform.ts:344-359,603-625`, `CR/environment/descriptor.ts:6-17`). The registration takes its environment id from that descriptor. The string `"primary"` (`PRIMARY_LOCAL_ENVIRONMENT_ID`, `packages/contracts/src/ipc.ts:362`) is only the platform cache key, not the environment id. Target resolution order is configured URL (`VITE_HTTP_URL`), desktop bootstrap, window origin (`WEB/environments/primary/target.ts:19-24,96-100`). Desktop can disable the local server (`WEB/connection/platform.ts:570-573`).
2. **Paired remote.** A `BearerConnectionRegistration` holds a target, a profile and a bearer credential (`CR/connection/catalog.ts:97-104`). Persisted.
3. **T3 Connect.** A `RelayConnectionRegistration` has a target only. Credentials are minted per connection (`CR/connection/catalog.ts:90-95`). A T3 Connect environment is just another route on the same catalog entry, with at most one relay route (`CR/connection/routes.ts:34-35`).

Desktop-local secondary backends (WSL) are platform-managed bearer registrations with connection id prefix `local:` (`WEB/connection/desktopLocal.ts:5-25`). 

### 1.3 Persistence

One JSON document, `ConnectionCatalogDocument`, holds everything (`CR/platform/storageDocument.ts:20-34`):

- `targets`, `profiles`, `credentials` (bearer tokens), `remoteDpopTokens`
- `githubRoutingPermissions`
- `disabledEnvironmentIds`, environments the user switched off

Where it lives:

- **Desktop app:** `window.desktopBridge.getConnectionCatalog` and `setConnectionCatalog` (`WEB/connection/storage.ts:396-419`). The main process encrypts the whole document with Electron `safeStorage`, base64 encodes it and writes `<stateDir>/connection-catalog.json` (`DESK/app/DesktopConnectionCatalogStore.ts:387,399-415`). If encryption is unavailable the write fails and the UI gets an error (`WEB/connection/storage.ts:408-418`).
- **Browser:** IndexedDB database `t3code:connection-runtime`, version 4, store `catalog`, key `document` (`WEB/connection/storage.ts:41-48,420-430`). A corrupt document is copied to `document:corrupt:<timestamp>` (`:426-428`).
- **GitHub routing grants:** separate `localStorage` keys `t3code:github-routing:<environmentId>` (`WEB/connection/storage.ts:511-545`).

Per-environment data caches also sit in IndexedDB, stores `shell`, `thread`, `server-config`, `vcs-refs` (`WEB/connection/storage.ts:43-47`). The shell and thread caches are what the UI shows while offline (`docs/internals/connection-runtime.md:57-60`).

Platform-managed environments (primary) are never written to the catalog (`CR/connection/registry.ts:1038-1041`). Learned routes with no stored profile are dropped on load and learned again (`:240-251`).

### 1.4 Restore at launch

`registry.start` creates a supervisor for every persisted environment (`CR/connection/registry.ts:480-493`). `createServiceScope` calls `supervisor.connect` for each entry with `enabled` true (`:376-378`). So every enabled environment connects at launch, whether or not any view is open. `layerConnectionStartup` then runs `registry.start` and subscribes the platform source (`CR/connection/layer.ts:88-98`).

The client also keeps a disabled flag per environment. A disabled environment stays registered with credentials and cache but never connects. Its projects and threads are excluded from the workspace (`CR/state/connections.ts:25-35`, `CR/connection/catalog.ts:65`).

## 2. Connections

### 2.1 One socket per environment

Each environment has one supervisor and one RPC session. That session holds one WebSocket and multiplexes every subscription and request over it (`CR/rpc/session.ts:38-65`, `CR/connection/registry.ts:360-402`). The registry maps environment id to a lease `{entry, supervisor, scope}` (`:200-206`). Nothing is shared between environments.

A session counts as ready only after `server.getConfig` returns (`docs/internals/connection-runtime.md:48-55`). Socket open timeout is 15 s (`CR/rpc/session.ts:44`).

### 2.2 Subscriptions per environment

Streams are started by `followStreamInEnvironment(environmentId, stream)`. It watches the registry entry map, acquires that environment's supervisor, and re-runs the stream whenever the supervisor is replaced. It ends quietly if the environment is removed (`CR/connection/registry.ts:446-472`, `CR/state/environmentStreams.ts:22-35`).

Streams opened per environment:

- Server config on session open (`CR/rpc/session.ts:229`) and `subscribeServerConfig` (`CR/state/server.ts:437`).
- Server lifecycle (`CR/state/server.ts:551`).
- Shell: one atom per environment id (`CR/state/shell.ts:334,431-436`). It first loads the authoritative HTTP shell snapshot for a new session, then subscribes with `afterSequence` and `requestCompletionMarker` (`CR/state/shell.ts:337-376`).
- Thread detail: one atom per `(environmentId, threadId)` (`CR/state/threads.ts:798,912-917`).

### 2.3 Reconnect and resume

The supervisor owns all transport retry (`docs/internals/connection-runtime.md:9-17`).

- Backoff: ceiling `min(300 s, 1 s * 2^(failures+1))`, the delay is a random point in the upper half of the ceiling (`CR/connection/supervisor.ts:35-36,137-140`). It resets only after the connection stayed up 30 s (`:43`).
- Offline and auth failures wait for a wakeup and spend no attempts (`docs/internals/connection-runtime.md:16-17`).
- Setup timeout is 15 s per route, multiplied by the route count (`:37,699`).
- Foreground, explicit retry and offline reports probe the live session and reconnect only if the probe fails. The probe timeout is 15 s for foregrounding and 3 s for retry, offline and network change (`:38-41,565-580`). `network-changed` and application-active wakeups reset the backoff (`CR/connection/wakeups.ts:22-25`).
- Route check: ROUTE_CHECK_TIMEOUT_MS is 2.5 s (`CR/connection/driver.ts:42`). While connected on a fallback route, the supervisor looks for a better route every 60 s. A better route that answered but failed to connect is skipped for 5 min (`:46-49`).
- Data resume: the shell stream sends the cached cursor. A new session reloads the HTTP snapshot first, so a stale cursor cannot keep incomplete data (`CR/state/shell.ts:352-376`). Failed streams retry after 250 ms on the same healthy session (`:376-380`, `CR/state/threads.ts:897-899`). Mutations are never replayed (`docs/internals/connection-runtime.md:85-87`).
- The web wakeups are `visibilitychange` to visible, `credentials-changed` from the cloud account, and a network type change (`WEB/connection/platform.ts:103-155`).

### 2.4 State exposed to the UI

`SupervisorConnectionState` has `phase`, `stage`, `attempt`, `generation`, `lastFailure` and `retryAt` (`CR/connection/model.ts:131-152`).

- Phases: `available`, `offline`, `connecting`, `backoff`, `connected`, `blocked`. Stages while connecting: `preparing`, `opening`, `synchronizing`.
- The data layer reduces this to three values: `disconnected` (available, offline, backoff, blocked), `synchronizing` (connecting) and `ready` (connected) (`CR/connection/model.ts:154-170`).
- Display strings: Available, Offline, "Connecting...", "Failed to connect. Reconnecting...", Connected, "Client not supported" (`CR/connection/presentation.ts:60-87`).
- Transport health and data freshness are separate. The shell state has its own `status` of `synchronizing`, `cached`, `live` and an `error`. A failed shell stream can sit next to a healthy socket and must not read "reconnecting" (`docs/internals/connection-runtime.md:48-56`, `CR/state/shell.ts:355-377`).
- Aggregates: a shell summary over enabled environments (`hasSnapshot`, `hasSynchronizingShell`, `hasCachedShell`, `hasLiveShell`, `firstError`) (`CR/state/shell.ts:457-519`). The landing waits for every enabled environment to be live, or settled after its first retries (`WEB/state/shell.ts:26-77`).
- A server that rejects the protocol version sets the catalog entry `unsupportedReason`, disables the environment, and the switch cannot be turned on again until that clears (`CR/connection/registry.ts:383-398,1029-1034`).

## 3. Scoping and merging

### 3.1 Refs and keys

Every project and thread reference carries its environment (`CR/environment/scoped.ts:11-36`).

- `scopeProjectRef(env, projectId)` and `scopeThreadRef(env, threadId)` return `{environmentId, projectId|threadId}`.
- String key for stores: `"<environmentId>:<localId>"`. Parsing splits at the first colon (`:25-47`). Environment ids contain no colon, thread ids may.
- Atom-internal key: `"<environmentId>\0<localId>"` (`CR/state/entities.ts:51-57`).
- Routes: `_chat.$environmentId.$threadId` for server threads, `_chat.draft.$draftId` for unsent drafts (`WEB/routes/`, `WEB/threadRoutes.ts:41-80`). Thread ids are never used alone.
- Project route: `projects.$projectKey`.

### 3.2 Merging projects across environments

Projects are not merged by id. `buildProjectGroups` (`CR/state/projectGrouping.ts:219-268`) works in three steps:

1. Physical key is `<environmentId>:<normalized workspaceRoot>`. Two projects with the same physical key (same env, same path) collapse to the newest by `updatedAt` (`:66-78,244-250`).
2. Logical key comes from the repository identity (`repositoryGroupingKeyOf`), so the same repo in two environments forms one sidebar group. In `repository_path` mode, a subpath is appended. In `separate` mode the logical key is the physical key (`:104-141`). The mode comes from client settings `sidebarProjectGroupingMode` plus per-project overrides (`:85-100`).
3. The group representative is the member in the primary environment if there is one, else the first (`:288-292`).

A group exposes `memberProjectRefs`. The sidebar derives `environmentPresence` (`local-only`, `remote-only`, `mixed`) and the list of remote environment labels (`WEB/sidebarProjectGrouping.ts:5-27,98-131`). Creating a thread in a mixed group needs a choice of target project, so there is a picker (`:136+`).

### 3.3 Ordering

- Threads from all environments are sorted by timestamp only: `updatedAt`, `createdAt` or latest user message, per the sort setting. Environment is not a sort key (`CR/state/threadSort.ts:98-139`). Settled threads sort by when the work ended, tie-broken by id (`:56-72`).
- Pinned and active manual order uses fractional order keys stored on the thread shell, so they are server data per environment (`CR/state/threadSort.ts:223-343`).
- Projects sort by the newest thread timestamp over all member projects, or manually. Manual order is a client list `projectOrder` keyed by physical key (`environmentId:path`) in `localStorage` (`WEB/uiStateStore.ts:24-42,143-150`, `CR/state/projectGrouping.ts:76-78`, `WEB/components/Sidebar.logic.ts:1288-1370`).
- `sidebarProjectScopeKey` persists the "scope to project" filter (`WEB/uiStateStore.ts:30,157`).

### 3.4 Per-thread client stores

All use the scoped thread key `env:thread` unless noted. All persist in `localStorage`.

- Composer drafts, `t3code:composer-drafts:v1`, version 9 (`WEB/composerDraftStore.ts:89-90`). `draftsByThreadKey` is keyed by `composerTargetKey`: the `DraftId` string for unsent drafts, `scopedThreadKey` for real threads (`:1459-1464`). `draftThreadsByThreadKey` stores `environmentId` and `projectId` for each draft. `logicalProjectDraftThreadKeyByLogicalProjectKey` maps a logical project to its draft (`:308-311,494-496`). Writes are debounced 300 ms (`:98`).
- Right panel, `t3code:right-panel-state:v2`, keyed `byThreadKey`. Pull request tabs embed the environment id in the surface id (`WEB/rightPanelStore.ts:90,123-127,264-270`).
- Terminal UI, `t3code:terminal-state:v1` (`WEB/terminalUiStateStore.ts:30,46-54`). On load, entries whose key does not parse as a scoped key are dropped.
- Also keyed per thread: `t3code:diff-panel-state:v1`, `t3code:closed-views:v2`, `t3code:prompt-stash:v2`.

### 3.5 What happens on removal

`registry.remove` (`CR/connection/registry.ts:820-864`), in order:

1. Refuses platform environments (`:822-826`).
2. Forgets the GitHub routing grant, deletes the registration (credentials, profiles, targets) (`:830-831`).
3. Closes the supervisor scope, so sockets and streams stop (`:837`).
4. Deletes the registry entry (`:838-841`).
5. In parallel: clears the IndexedDB caches for that environment (shell, thread, config, vcs refs), and runs `EnvironmentOwnedDataCleanup` (`:843-856`).
6. Tears down SSH tunnels (`:858-864`).

On the web, `EnvironmentOwnedDataCleanup` only calls `clearComposerDraftsEnvironment` (`WEB/connection/platform.ts:745-754`). It drops draft threads for that environment, composer drafts with that environment's key prefix, and logical-project mappings (`WEB/composerDraftStore.ts:4419-4450`). The right panel, terminal UI, closed-view, project order and prompt stash entries for that environment stay in `localStorage` as orphans. The official client does not clean them.

Removing a route is different. `removeRoute` drops one route and keeps the environment unless it was the last one. Removing T3 Connect also removes routes learned through it, and removing a paired address removes learned routes that borrow its token (`CR/connection/registry.ts:946-968`, `CR/connection/routes.ts:332-349`). Signing out of the cloud account removes only relay-only environments (`CR/connection/registry.ts:993-1015`, `docs/internals/connection-runtime.md:31-32`). Directly paired environments survive.

Switching an environment off (`setEnabled`) keeps the supervisor, calls `disconnect`, and persists the flag in `disabledEnvironmentIds` (`CR/connection/registry.ts:1021-1070`). Its projects and threads vanish from the workspace (`CR/state/connections.ts:25-35`). Cached data stays.

## 4. Commands

### 4.1 Environment selection

Every command takes `{environmentId, input}`. `createEnvironmentCommand` runs the effect inside that environment's supervisor via `runInEnvironment` (`CR/state/runtime.ts:640-659`). RPC commands go through `createEnvironmentRpcCommand` the same way (`:744-790`). The caller always passes the environment of the thread or project it acts on. Commands never fall back to a "current" environment. If the environment is not registered the command fails with `EnvironmentNotRegisteredError`.

Examples: orchestration `dispatchCommand`, `subscribeShell`, `subscribeThread` (`CR/state/orchestration.ts:15-35`). Thread commands key their serialization by `[environmentId, threadId]` (`CR/state/threadCommands.ts:148,326,335,397`). VCS actions serialize per `[environmentId, cwd]` (`CR/state/vcsCommandScheduler.ts`). Project commands (`CR/state/projectCommands.ts`) take an environment id and a project id.

New thread: the target is a project ref, so the thread is created in that project's environment. For a grouped project the user picks the member (`WEB/sidebarProjectGrouping.ts:136+`).

### 4.2 Cross-environment operations

None found. I searched contracts, client-runtime and web for cross-environment, source and target environment, and transfer. Fork-from-run uses `[environmentId, sourceThreadId]` and merge-back uses `[environmentId, sourceThreadId, targetThreadId]`, both inside one environment (`CR/state/threadCommands.ts:321-338`). The "handoff" in `CR/handoff.ts` is a provider/model switch inside a thread, not a move between environments. `docs/internals/providers.md:68` mentions transferring provider registrations, which is server-side and unrelated. The one cross-environment feature is the merged sidebar and the project picker that picks which environment gets a new thread.

## 5. Limits, timers and background work

Official client behavior CandyWrapper must decide on, since its rule is no background work without reason.

### 5.1 What stays open

- All enabled environments connect at launch and stay connected for the app's lifetime. No idle disconnect exists. I found no timer that closes a healthy socket (`CR/connection/registry.ts:376-378`).
- Each connected socket carries a server config stream and a server lifecycle stream (always), plus a shell stream while a shell consumer is mounted. The sidebar mounts shell state for every enabled environment (`WEB/state/shell.ts`, `WEB/state/threads.ts:131-135`).
- Thread detail streams live while any consumer is mounted. They stop when the last consumer leaves, but the resume cache keeps state and cursor for 5 min (`CR/state/threadRetention.ts:1-3`, `docs/internals/connection-runtime.md:62-67`).
- Sidebar prewarm: the first 3 visible thread rows hold live detail subscriptions, plus rows within 160 px of the viewport for live status (`WEB/components/Sidebar.logic.ts:62-70,866-870`).
- Desktop keep-alive: every thread whose session is preparing, starting or running stays mounted in each enabled environment. A stopped thread stays until its own stream is live and shows the stop, then closes (`WEB/state/threads.ts:53-127`). Web and mobile do not keep threads alive (`docs/internals/connection-runtime.md:68-75`).

### 5.2 Timers

| Timer | Value | Source |
|---|---|---|
| Platform source poll | 3 s (in-process; HTTP only on signature change or expiry) | `WEB/connection/platform.ts:426,738` |
| Reconnect backoff | 1 s base, 300 s cap, upper-half jitter, reset after 30 s up | `CR/connection/supervisor.ts:35-43,137-140` |
| Establishment timeout | 15 s per route | `:37` |
| Live-session probe | 15 s (foreground), 3 s (retry, offline, network change) | `:38-41` |
| Route health check | 2.5 s | `CR/connection/driver.ts:42` |
| Better-route recheck | every 60 s on a fallback route; 5 min cooldown | `CR/connection/supervisor.ts:46-49` |
| Socket open | 15 s | `CR/rpc/session.ts:44` |
| Stream retry after expected failure | 250 ms on the same session; ceiling 30 s in the RPC client | `CR/state/shell.ts:376-380`, `CR/rpc/client.ts:106` |
| Relay discovery query | stale 15 s, idle drop 5 min | `CR/relay/managedRelayState.ts:24-25` |

The RPC session reports a ping timeout through a connection hook ("stopped responding") (`CR/rpc/session.ts:175-188`). The ping interval itself is set in the Effect RPC layer, not here. See protocol section 2.5.

### 5.3 Concurrency

- Registry operations across environments run with `concurrency: "unbounded"` (`CR/connection/registry.ts:241,266,491`). Operations on one environment take a per-environment lock (`withLeaseLock`).
- Relay status checks for the T3 Connect list run concurrently, one per environment, 10 s request timeout (`C-auth-connect.md` 4.6).
- Command schedulers are per command, with modes `parallel`, `serial`, `singleFlight`, `latest`, keyed by `[environmentId, id]` (`CR/state/runtime.ts:111-117,156-215`). No global cap on in-flight requests across environments.
- I found no maximum on the number of saved environments.

## 6. Notes for CandyWrapper

1. Keep one catalog document. Put profiles and routes in a plain file and bearer and DPoP tokens in Keychain.
2. The official client connects every enabled environment at launch. CandyWrapper can connect on first use and close sockets with no visible consumer. The server cannot tell the difference.
3. Use `env:thread` keys in stored state, and clear all per-thread state on removal, which the official client does only for drafts.

## Could not determine

- The exact Effect RPC ping interval and pong timeout (outside `client-runtime`; likely in the `effect` package defaults).
- Whether the mobile app differs on keep-alive; only desktop and web were read.
