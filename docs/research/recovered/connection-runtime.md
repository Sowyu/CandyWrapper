# T3 Code client connection runtime (research notes for a native macOS client)

Source: `/Users/mrm/CandyWrapper-research/t3code`, tag `v0.0.46-nightly.20261009.2861` (commit `3b6af0bd1`). Read-only research. All paths below are relative to the repo root. Every claim carries a `file:line` citation. Anything not confirmed in source is marked UNVERIFIED.

Effect version: the workspace pins `effect: 4.0.1` (`pnpm-workspace.yaml:49`) with a local patch (`patches/effect@4.0.1.patch`). `node_modules` is not installed in the checkout, so Effect internals (RPC wire protocol, sockets) were read from the vendored reference copy `.repos/effect-smol` whose `packages/effect/package.json` reports version `4.0.1`. The patch's context lines match that copy (`patches/effect@4.0.1.patch:82-125` vs `.repos/effect-smol/packages/effect/src/rpc/RpcClient.ts:1133-1227`). Treat Effect internals as "reference copy, high confidence" rather than "installed build".

---

## 0. Architecture in one paragraph

Web, desktop renderer and mobile share one connection owner per environment in `packages/client-runtime` (`docs/internals/connection-runtime.md:3-7`). The supervisor owns transport retry; resolving an endpoint and opening an RPC session are single attempts (`docs/internals/connection-runtime.md:11-17`). The driver walks a saved environment's ordered routes and connects over the first that works (`docs/internals/remote.md:31-45`, `packages/client-runtime/src/connection/driver.ts:68-81`). The registry scopes one supervisor per environment (`docs/internals/connection-runtime.md:28-32`). RPC sessions authenticate at socket upgrade with a short-lived ticket; HTTP requests get current credentials from the authorization service (`docs/internals/connection-runtime.md:34-41`, `docs/internals/environment-auth.md:57-62`). Shell and thread data synchronize independently from transport health (`docs/internals/connection-runtime.md:48-60`).

Layer wiring: `ConnectionDriver.layer` <- (`ConnectionResolver.layer`, `RpcSession.layer(options)`); registry, onboarding, relay discovery, startup (`registry.start`, platform reconcile, discovered-compatibility watcher) (`packages/client-runtime/src/connection/layer.ts:75-106`).

---

## 1. Saved environment model

### 1.1 Targets (route identity)

`packages/client-runtime/src/connection/model.ts`:

| Class (`_tag`) | Fields | Lines |
|---|---|---|
| base | `environmentId: EnvironmentId`, `label: string` | 4-7 |
| `PrimaryConnectionTarget` | base + `httpBaseUrl`, `wsBaseUrl` | 9-16 |
| `BearerConnectionTarget` | base + `connectionId` | 18-24 |
| `RelayConnectionTarget` | base only | 26-31 |
| `SshConnectionTarget` | base + `connectionId` | 33-39 |

`ConnectionTarget` = union of all four (`model.ts:41-47`). `PersistedConnectionTarget` = Bearer | Relay | Ssh; Primary is never persisted (`model.ts:49-54`).

### 1.2 Profiles (per-route address data)

`packages/client-runtime/src/connection/catalog.ts`:
- Base fields `connectionId`, `environmentId`, `label` (`catalog.ts:13-17`).
- `BearerConnectionProfile`: `httpBaseUrl`, `wsBaseUrl`, optional `learned: true` (route the server reported), optional `authorization: "t3-connect"` (route authenticates with the T3 Connect DPoP credential instead of a stored bearer) (`catalog.ts:19-37`).
- `SshConnectionProfile`: `target: DesktopSshEnvironmentTargetSchema` (alias, hostname, username, port) (`catalog.ts:39-45`).
- `ConnectionRoute = { target, profile: Option<ConnectionProfile> }` (`catalog.ts:50-54`).

### 1.3 Credentials and tokens

- `BearerConnectionCredential { token }`; `ConnectionCredential` union contains only this (`catalog.ts:73-81`).
- `RemoteDpopAccessToken { environmentId, accountId?, label, endpoint: RelayManagedEndpoint, accessToken, expiresAtEpochMs, dpopThumbprint }` (`packages/client-runtime/src/authorization/tokenStore.ts:11-21`). `RelayManagedEndpoint { httpBaseUrl, wsBaseUrl, providerKind }` (`packages/contracts/src/relay.ts:165-170`).
- `StoredGitHubRoutingPermission { environmentId, connectionKey, permission: "off" | "read" | "read-write" }` (`packages/client-runtime/src/connection/githubRoutingPermissions.ts:13-20`).

### 1.4 Catalog entry (in-memory view of a saved environment)

`ConnectionCatalogEntry { target, profile, alternateRoutes?, enabled, unsupportedReason?, serverUpdateRequired? }`; `target`/`profile` is the preferred route, `alternateRoutes` the rest in preference order; `enabled: false` means saved but never connects (`catalog.ts:56-71`). Registrations: `PrimaryConnectionRegistration {target}`, `RelayConnectionRegistration {target}`, `BearerConnectionRegistration {target, profile, credential}`, `SshConnectionRegistration {target, profile}` (`catalog.ts:83-118`). Platform-managed registrations are Primary or Bearer (desktop-local secondary backends such as WSL) (`catalog.ts:121-134`).

Note: `unsupportedReason` and `serverUpdateRequired` are not part of the persisted document (see 1.6), so they live only in memory; only the disabled flag persists (`registry.ts:1126-1141`, `storageDocument.ts:20-33`).

### 1.5 Route ids and kinds

Route id (`packages/client-runtime/src/connection/routes.ts:28-38`): `"primary"` for Primary, `"relay"` (`RELAY_ROUTE_ID`, one relay route per environment, `routes.ts:25-26`) for Relay, otherwise `connectionId`.

`connectionId` formats:
- Paired bearer: `` `bearer:${environmentId}:${new URL(httpBaseUrl).origin}` `` (one route per address) (`packages/client-runtime/src/connection/onboarding.ts:95-102`).
- SSH: `` `ssh:${environmentId}:${sshTargetKey(target)}` `` (`onboarding.ts:262-264`), `sshTargetKey = JSON.stringify([alias, hostname, username, port])` (`routes.ts:371-374`).
- Learned: `` `learned:${environmentId}:${origin}` `` (T3 Connect auth) or `` `learned:${environmentId}:${origin}@${sharedCredential}` `` (borrows a paired bearer) (`routes.ts:311-323`). `credentialConnectionId` returns the part after the first `@` for ids starting with `learned:` (`routes.ts:325-333`).
- Desktop-local secondary backend: `` `local:${backendId}` `` (`apps/web/src/connection/desktopLocal.ts:20-24`).
- Legacy migrated ids: desktop `bearer:${environmentId}` / `ssh:${environmentId}` (`apps/desktop/src/app/DesktopConnectionCatalogStore.ts:284-286`); mobile `bearer:${environmentId}` (`apps/mobile/src/connection/migration.ts:67`).

Route kind `ConnectionRouteKind = "relay" | "loopback" | "lan" | "tailnet" | "public" | "ssh"` (`routes.ts:23`), classified by hostname of the route's http base URL (`routes.ts:88-103`): loopback first (`localhost`, `::1`, `127.0.0.0/8`, `packages/shared/src/hostClassification.ts:78-82`), then tailnet (`*.ts.net`, `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `hostClassification.ts:84-95`), then lan via `isPrivateNetworkHost` (10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, 198.18/15, 0/8, `*.local`, `*.localhost`, `home.arpa`, single-label names, fc00::/7, fe80::/10, `hostClassification.ts:56-64, 97-120`), else public. Tailscale is not a separate target type; it is a bearer route with a tailnet address (`docs/internals/remote.md:73-76`).

### 1.6 Persisted document

`ConnectionCatalogDocument` (`packages/client-runtime/src/platform/storageDocument.ts:20-33`):
- `schemaVersion: 1` (literal)
- `targets: PersistedConnectionTarget[]`
- `profiles: ConnectionProfile[]`
- `credentials: { connectionId, credential }[]` (`StoredConnectionCredential`, `storageDocument.ts:14-18`)
- `remoteDpopTokens: RemoteDpopAccessToken[]`
- `githubRoutingPermissions?: StoredGitHubRoutingPermission[]` (optional key)
- `disabledEnvironmentIds: EnvironmentId[]` (decoding default `[]` for older documents)

Empty document: `storageDocument.ts:36-43`. Encoded with `Schema.fromJsonString` (web `apps/web/src/connection/storage.ts:66-68`, mobile `apps/mobile/src/connection/catalog-store.ts:26-28`). Tagged classes carry a `_tag` field (Schema.TaggedClass); exact JSON key ordering is UNVERIFIED.

### 1.7 Ordering rules

- An environment's routes are its `targets` entries in array order, preferred first; pre-routes documents read as one route (`storageDocument.ts:95-105`).
- `setRoutesInCatalog` replaces the environment's routes in place (keeps the environment's position), drops profiles/credentials of dropped routes, and drops the env's DPoP token if the relay route was dropped (`storageDocument.ts:77-93, 107-133`).
- `registerConnectionInCatalog` sets routes and upserts profile (+ credential for bearer); keeps the disabled flag (`storageDocument.ts:135-171`).
- `removeConnectionFromCatalog` removes routes, DPoP token, disabled flag and GitHub routing permissions for the environment (`storageDocument.ts:173-199`).
- `putRemoteDpopTokenInCatalog` stores a token only if the env has a relay target (`storageDocument.ts:219-238`).
- On registry startup targets are grouped by `environmentId` in order, profiles loaded, duplicate route ids dropped, learned routes without a profile dropped, first route kept if none usable; `enabled = !disabledEnvironmentIds.has(id)` (`packages/client-runtime/src/connection/registry.ts:220-268`).

### 1.8 Platform storage

Web (browser):
- IndexedDB database `"t3code:connection-runtime"`, version `4`, stores `"catalog"`, `"shell"`, `"thread"`, `"server-config"`, `"vcs-refs"`; catalog key `"document"` holding the JSON string (`apps/web/src/connection/storage.ts:41-48, 422-431`). Stores are created on `upgradeneeded` if missing (`storage.ts:122-139`).
- Corrupt catalog: quarantined under `` `document:corrupt:${Date.now()}` `` then reset to empty (`storage.ts:428-430, 453-479`).
- Cache keys: shell by `environmentId`; thread `` `${environmentId}:${threadId}` ``; vcs refs `` `${environmentId}:${cwd}` `` (`storage.ts:368-374, 711-910`).
- GitHub routing permissions: localStorage `` `t3code:github-routing:${environmentId}` ``, change event `"t3code:github-routing-changed"` (`storage.ts:502-601`).
- Tokens are stored in IndexedDB as plain JSON (no encryption layer in `storage.ts`; inference from `storage.ts:396-431`).
- DPoP private key: IndexedDB `"t3code:cloud-auth"` v1, store `"keys"`, key `"relay-dpop-proof-key"`, ECDSA P-256 (`apps/web/src/cloud/dpop.ts:24-27, 113, 135`).

Desktop (Electron renderer = web app):
- Catalog goes through `window.desktopBridge.getConnectionCatalog` / `setConnectionCatalog` when present (`apps/web/src/connection/storage.ts:396-421`, `apps/desktop/src/preload.ts:139-142`).
- Main process `DesktopConnectionCatalogStore`: file `path.join(stateDir, "connection-catalog.json")` containing `{ version: 1, encryptedCatalog: Base64(safeStorage.encryptString(json)) }` (`apps/desktop/src/app/DesktopConnectionCatalogStore.ts:29-33, 387, 399-431`). If Electron safeStorage encryption is unavailable, get returns none and set returns false (`DesktopConnectionCatalogStore.ts:474-505`); the renderer then fails with "Desktop secure storage is unavailable in this system context." (`apps/web/src/connection/storage.ts:409-418`).
- `stateDir = baseDir/("dev" | "userdata")`, `baseDir` defaults to `~/.t3` (`apps/desktop/src/app/DesktopStatePaths.ts:13-32`).
- Shell/thread/config caches stay in renderer IndexedDB (`apps/web/src/connection/storage.ts:711-910`). GitHub routing permissions in renderer localStorage (`storage.ts:610`).

Mobile:
- expo-secure-store key `"t3code.connection-catalog.v1"` holding the whole JSON document including secrets (`apps/mobile/src/connection/catalog-store.ts:16, 51-121`, `apps/mobile/src/persistence/mobile-secure-storage.ts:31-50`).
- GitHub routing permissions inside the document (`apps/mobile/src/connection/storage.ts:45-49`).
- Caches in SQLite via `MobileDatabase` (`apps/mobile/src/connection/environment-cache-store.ts:12`).
- DPoP private key in SecureStore `"t3code.cloud.dpop-proof-key"` (`apps/mobile/src/features/cloud/dpop.ts:89, 201, 232`).

### 1.9 Secret inventory

| Secret | Lifetime | Where |
|---|---|---|
| `BearerConnectionCredential.token` (paired session token) | server default session TTL 30 days (`apps/server/src/auth/SessionStore.ts:432`) | catalog `credentials` |
| `RemoteDpopAccessToken.accessToken` (T3 Connect env session, proof-bound) | 1 hour (`apps/server/src/auth/EnvironmentAuth.ts:913-917`) | catalog `remoteDpopTokens` |
| DPoP private key | device lifetime | web IndexedDB / mobile SecureStore (above) |
| Platform bearer for desktop-local backends | written into credential store | `registry.ts:662-681` |

Targets/profiles/labels are not secret but share the same blob.

### 1.10 Versioning and migrations

- Catalog `schemaVersion: 1` with additive decoding defaults (`storageDocument.ts:20-33`).
- Desktop legacy migration from the saved-environment registry: `relayManaged` -> Relay target; `desktopSsh` -> SSH target+profile; otherwise Bearer target+profile with the secret from `savedEnvironments.getSecret` (`DesktopConnectionCatalogStore.ts:288-377, 433-472`).
- Mobile legacy key `"t3code.connections"` (`LegacySavedRemoteConnection`): relayManaged or `authenticationMethod: "dpop"` -> Relay registration; non-empty `bearerToken` -> Bearer registration; migrated then deleted; corrupt v1 catalog deleted and legacy retried (`apps/mobile/src/connection/migration.ts:18-110`, `catalog-store.ts:62-104`).
- Orchestration caches: `ORCHESTRATION_CACHE_SCHEMA_VERSION = 3`; undecodable caches are discarded, never blocking sync (`packages/client-runtime/src/platform/orchestrationCache.ts:12-36`). Server-config cache `schemaVersion: 1` (`apps/web/src/connection/storage.ts:53-57`).

---

## 2. Routes

### 2.1 Ordered list

`connectionRoutes(entry) = [{target, profile}, ...alternateRoutes]` (`routes.ts:40-43`); `entryWithRoutes` rebuilds an entry and throws on an empty list (`routes.ts:45-61`); `routeEntry(entry, route)` builds a single-route entry used per attempt (`routes.ts:63-69`).

Labels (`connectionRouteLabel`, `routes.ts:169-189`): relay "T3 Connect", loopback "This device", lan "LAN", tailnet "Tailscale", ssh "SSH user@host" (or "SSH"), public = hostname or "Remote link". Address under a route (`connectionRouteAddress`): SSH alias, else http base URL, null for relay (`routes.ts:191-198`).

### 2.2 Insertion "by speed"

`ROUTE_KIND_RANK`: loopback 0, lan 1, tailnet 2, public 3, ssh 4, relay 5 (`routes.ts:105-112`). `insertRoute` places a new route before the first existing route with a strictly greater rank, else appends ("after every saved route of the same or a faster kind") (`routes.ts:114-130`). `upsertRoute` replaces a route with the same id in place, keeping the user's order (`routes.ts:132-141`; test `routes.test.ts:66-78`). `findRouteToSameAddress` keys `bearer:<httpBaseUrl without trailing slashes>` or `ssh:<sshTargetKey>` (`routes.ts:143-167`).

`registry.register`: platform envs ignored; for an existing env, a same-address route with a different id is removed, then `upsertRoute`; GitHub routing trust is forgotten if the address set changed; registration + full route list persisted; entry installed (this closes and recreates the supervisor, i.e. reconnects) (`registry.ts:555-593, 540-553, 497-521`).

User doc: "A new route is placed by speed, in that order, and you can reorder routes at any time." (`docs/user/remote-access.md:65-71`).

"Add route" UI (web): dialog title "Add a route to <label>" and description "Pair this machine again over another address, such as its Tailscale name. It joins the existing routes instead of adding a second machine." (`apps/web/src/components/settings/ConnectionsSettings.tsx:4102-4106`); pairing passes `expectedEnvironmentId` (`ConnectionsSettings.tsx:2622-2625`) and onboarding checks the descriptor before redeeming the one-time code, failing with "That address reaches <label>, a different machine. Add it as its own environment instead." (`packages/client-runtime/src/connection/onboarding.ts:104-125`). Success toast "Route added" / "<label> now has another way to connect." (`ConnectionsSettings.tsx:2650-2655`); SSH variant "<label> can now be reached over SSH <alias>." (`ConnectionsSettings.tsx:2574`). T3 Connect offer when discovery sees the machine: "This machine is on your T3 Connect account. Use it as a fallback route." registering a `RelayConnectionRegistration`, toast "<label> falls back to T3 Connect when its other routes are unreachable." (`ConnectionsSettings.tsx:2955-2993`). Mobile: "Add route" row (`apps/mobile/src/features/settings/EnvironmentRoutesSection.tsx:227`).

### 2.3 Learned routes

Server source:
- `ServerConfig.directEndpoints?: ForwardCompatibleArray(ServerDirectEndpoint)` with `ServerDirectEndpoint { kind: "lan" | "tailnet", httpBaseUrl }` (`packages/contracts/src/server.ts:635-642, 661-667`).
- Computed inside `loadServerConfig`, shared by `server.getConfig` and `subscribeServerConfig` (`apps/server/src/ws.ts:1680-1740` with `directEndpoints` at `1712`, `2077`, `2950-2954`), wrapped by `CONFIG_DISCOVERY_TIMEOUT = 5 s` that returns `[]` on timeout (`ws.ts:253-267`).
- `DirectEndpoints.resolve` (`apps/server/src/environment/DirectEndpoints.ts`): nothing when bound to loopback (`79`); wildcard host enumerates non-internal IPv4 interfaces, skipping virtual interfaces matching `/^(docker|br-|veth|virbr|vmnet|vboxnet|vEthernet|podman|cni|flannel|cali|lxcbr|lxdbr|bridge1\d\d)/` (`66-67, 80-87`); advertisable = IPv4, not `127.*`, not `169.254.*`, tailnet or private (`54-58`); URL `` `http://${address}:${port}/` ``, kind tailnet if Tailscale IPv4 else lan (`89-92`); Tailscale Serve HTTPS MagicDNS URL added as tailnet when enabled and the probe answers within `TAILSCALE_ENDPOINT_TIMEOUT = 3 s` (`39, 109-136`). Comment: an empty list would make clients forget learned routes (`34-38`).

Client:
- After a session is ready, the supervisor forks `learnRoutesFrom`, which reads `lease.session.initialConfig.directEndpoints` once per established session (undefined means older server, no learning) (`packages/client-runtime/src/connection/supervisor.ts:314-332, 768-770`).
- `registry.learnRoutes`: skips platform envs; `mergeLearnedRoutes(... allowInsecure)`; persists new learned profiles and the route list; updates the live lease entry in place (no reconnect); on error logs "Could not save routes learned from the environment." (`registry.ts:885-944`). `allowInsecure = typeof location === "undefined" || location.protocol !== "https:"` (`registry.ts:881-883`).
- Supervisor then sets the current entry and requests a better-route check (`supervisor.ts:326-330`).

`mergeLearnedRoutes` (`routes.ts:209-309`):
- Only when the active route is Relay or Bearer; Primary and SSH have no reusable credential (`228-231`).
- Credential: `authorization: "t3-connect"` when active is Relay or a t3-connect bearer profile; otherwise the learned id borrows `credentialConnectionId(active.connectionId)` (`232-244`).
- Reported URLs kept only if parseable, `http:`/`https:`, not `http:` when `!allowInsecure`, not loopback; keyed by origin (`246-260`).
- `known` = normalized (trailing `/` stripped) URLs of user-saved routes; a learned route survives only while still reported and not duplicating a saved address, keeping its position (`261-274`).
- New learned route: `BearerConnectionTarget {environmentId, label, connectionId}` + `BearerConnectionProfile {httpBaseUrl: origin + "/", wsBaseUrl: ws(s)://host/, learned: true, authorization?}` inserted by rank (`276-302`).
- Returns null if ids and addresses are unchanged (`303-308`).
- Resolver: t3-connect profile -> `authorizeDpop` with `directEndpoint`; otherwise stored credential of `credentialConnectionId` (`packages/client-runtime/src/connection/resolver.ts:143-158`).
- Removal: removing relay removes t3-connect learned routes; removing a paired route removes learned routes borrowing it (`routes.ts:340-361`). UI never offers removal for learned routes and labels them " · found automatically" (`apps/web/src/components/settings/EnvironmentRoutesList.tsx:121-124, 185-190`; mobile `EnvironmentRoutesSection.tsx:219-223, 318-322`). Learned routes do not affect GitHub routing trust (`githubRoutingPermissions.ts:28-36`).

### 2.4 Route check and preflight

- `checkRoute` (`driver.ts:144-162`): relay/SSH -> `"unchecked"`; direct -> `GET /.well-known/t3/environment` with `ROUTE_CHECK_TIMEOUT_MS = 2_500` (`driver.ts:41-42`); `"answered"` iff `descriptor.environmentId === entry.target.environmentId`; mismatch or any error -> `"silent"`. No credential is sent (`driver.ts:147-148`). Endpoint is the public `metadata` group (`packages/contracts/src/environmentHttp.ts:449-453`, server handler `apps/server/src/http.ts:302-314`).
- `preflight` (`driver.ts:189-200`): `checkRoute == "answered"` and `resolver.prepare(routeEntry(entry, route))` succeeds. Prepare includes authorization, i.e. it mints a WebSocket ticket via `POST /api/auth/websocket-ticket` (bearer: `authorization/service.ts:184-216`, `authorization/remote.ts:161-224`; DPoP: `service.ts:490-544`), re-fetches the descriptor and checks protocol compatibility (`resolver.ts:291-318`). It does not call `GET /api/auth/session`. Relay and SSH routes never pass preflight, so they are fallbacks, not switch destinations (`supervisor.ts:343-347`).
- Descriptor verification inside `authorizeBearer`/`authorizeDpop(directEndpoint)` is cached per environment for `BEARER_DESCRIPTOR_CACHE_TTL_MS = 10_000` keyed by matching `httpBaseUrl` (`service.ts:89-91, 142-182`).
- Cooldown: `BETTER_ROUTE_COOLDOWN_MS = 300_000` set on the preferred route id when a switch toward it lands on another route; cooled routes are excluded from checks (`supervisor.ts:47-49, 354-358, 745-754`). No cooldown applies to the normal walk.

### 2.5 Periodic and triggered re-check of earlier routes

- `BETTER_ROUTE_CHECK_INTERVAL = "60 seconds"`; `Stream.tick(...)` with `Stream.drop(1)` while connected, so first check 60 s after connect (`supervisor.ts:44-46, 603-609`; test `supervisor.test.ts:1826-1857`).
- Triggers while connected: tick; `NetworkChanged` to a non-offline status; a `Wakeup` whose reason `resetsRetryBackoff` (application-active, application-active-probe, application-active-reconnect, network-changed) (`supervisor.ts:616-622`, `wakeups.ts:22-25`); after learning routes (`supervisor.ts:329-330`).
- Only when the active route is not first (`supervisor.ts:377-382`). `Queue.dropping(1)`: one check at a time, triggers during a check are dropped (`supervisor.ts:375-376`).
- `checkBetterRoutes`: routes ranked above the active one and not cooling down, `driver.preflight` on all concurrently, best passing one wins, then confirm the session is still the same, then signal `BetterRouteAvailable` (`supervisor.ts:348-373`).
- Switch: `connectedLeaseEnd` stores `preferredRouteId` and returns `"reset"` (`supervisor.ts:540-545`); the live session is released first (break before make, `clearLease` `supervisor.ts:384-387, 829`); the ladder resets and `replacing = true` (`supervisor.ts:917-922`); `attemptEntry` moves the preferred route to the front for a full walk (`supervisor.ts:301-312`).
- User doc: "checks the earlier ones when your network changes, when you return to the app, and every minute" (`docs/user/remote-access.md:82-86`).

### 2.6 Remove and reorder

`removeRoute` uses `routesAfterRemoving`; last route -> full environment removal; SSH routes also tear down the managed tunnel (`registry.ts:946-968`). `reorderRoutes` requires an exact permutation, else `ConnectionBlockedError` configuration "The route order must list every saved route once." (`registry.ts:970-991`). Both go through `replaceRoutesLocked` -> `installEntryLocked`, which restarts the connection (`registry.ts:595-607, 497-521`). GitHub trust revoked when addresses change, kept on reorder (`registry.ts:540-553`, `docs/internals/remote.md:55-56`).

---

## 3. Driver

### 3.1 Walk algorithm (`connectOverRoutes`, `driver.ts:82-136`)

```
routes = connectionRoutes(entry)
checks = routes.length == 1 ? [] : fork checkRoute(route) for every route (concurrently)
silent = []
for route in routes (in order):
    check = (no checks) ? "unchecked" : await its own check only
    if check == "silent": silent.push(route); continue
    result = attempt(route)             # own child scope; half-open session closed on failure
    if success: return lease
    if failure.reason == "unsupported": stop, return failure   # same server on every route
for route in silent: same attempt logic
fail with first transient error, else first blocked error,
     else ConnectionTransientError{reason: "endpoint-unavailable",
          detail: "<label> did not answer on any saved route."}
```

Sources: per-route scope (`driver.ts:96-110`), silent-last (`111-127`), final error (`128-135`). Any non-`unsupported` failure (transient, authentication, configuration, permission) moves on (`driver.ts:73-80`, `docs/internals/remote.md:36-40`). There is no per-route timer in the walk; the supervisor bounds the whole walk at `15 s x route count` (`supervisor.ts:697-700`).

`connect` (`driver.ts:164-187`): report `"preparing"` -> `resolver.prepare(routeEntry)` -> report `"opening"` (with prepared) -> `sessions.connect(prepared)` -> report `"synchronizing"` -> `await session.ready`.

### 3.2 Prepare per target (`resolver.ts`)

- Primary: platform bearer (desktop) or cookie; socket `/ws` plus client params with `connectionMethod: "direct"` (`resolver.ts:74-118`).
- Bearer: profile must be a bearer profile ("Connection profile <id> is not a bearer connection.") with matching environmentId; t3-connect -> `authorizeDpop({directEndpoint})`; else stored credential (missing -> blocked authentication "Connection credential <id> is unavailable.", `errors.ts:20-25`) -> `authorizeBearer(... connectionMethod: "direct")` (`resolver.ts:120-178`).
- Relay: `authorizeDpop({expectedEnvironmentId})` (`resolver.ts:180-200`).
- SSH: desktop gateway prepare, profile rewrite, `authorizeBearer(... connectionMethod: "ssh")` (`resolver.ts:202-261`).
- Then (all kinds): `GET /.well-known/t3/environment` at `prepared.httpBaseUrl`; mismatch -> blocked configuration "Connected environment <actual> does not match <expected>." (`resolver.ts:291-302`, `errors.ts:27-35`); compatibility check; `socketUrl = appendOrchestrationProtocol(socketUrl)` (`resolver.ts:306-318`).

Compatibility (`packages/client-runtime/src/connection/compatibility.ts:9-36`): server version = `descriptor.orchestrationProtocolVersion ?? 1`; client `ORCHESTRATION_PROTOCOL_VERSION = 2` (`packages/contracts/src/environment.ts:13-16`). Newer server -> blocked unsupported "This client is not supported by this server. Update your app or use a compatible release to connect to <label>."; older server -> blocked unsupported "This client requires a newer server. Update T3 Code on <label> to connect." with `serverUpdateRequired: true` when self-update is possible.

### 3.3 HTTP calls during one bearer route attempt (in order)

1. `GET /.well-known/t3/environment` (route check, 2.5 s; only when the env has more than one route) (`driver.ts:89-93, 144-162`).
2. `GET /.well-known/t3/environment` (`verifyDirectEndpoint`, 10 s default, cached 10 s) (`service.ts:147-182`, `environment/descriptor.ts:6-16`).
3. `POST /api/auth/websocket-ticket`, header `authorization: Bearer <token>`, no body, 10 s -> `{ ticket, expiresAt }` (`authorization/remote.ts:25, 161-178`, contract `environmentHttp.ts:478-484`, `packages/contracts/src/auth.ts:319-323`).
4. `GET /.well-known/t3/environment` again (resolver) (`resolver.ts:291-296`).
5. WebSocket `GET /ws?...` (3.4).

Relay route: Clerk token -> relay `POST /v1/client/dpop-token` (cached) -> relay `POST /v1/environments/:environmentId/connect` -> descriptor at the tunnel URL -> env `POST /oauth/token` (DPoP) -> env `POST /api/auth/websocket-ticket` (DPoP; 3 s timeout when the token came from cache, else 10 s) -> descriptor -> WebSocket (`service.ts:278-361, 490-544`; section 6.3).

### 3.4 WebSocket URL

Built by `resolveRemoteWebSocketConnectionUrl` / `resolveRemoteDpopWebSocketConnectionUrl` (`authorization/remote.ts:201-250`):
- Start from `wsBaseUrl`; if path is `""` or `"/"` set path `/ws` (a non-root path is kept as is).
- `wsTicket=<ticket>` set first, then `appendClientConnectionParams` (`remote.ts:40-84`) in this order: `clientSurface`, `clientAppVersion`, `clientDeviceType` (metadata `mobile` -> `phone`, `desktop`/`tablet` kept, else `unknown`), `clientOs`; web only `clientWebDeployment`, `clientBrowser`; mobile only `clientOsMajorVersion`, `clientDeviceModel`; then `connectionMethod`.
- Resolver appends `orchestrationProtocol=2` (`compatibility.ts:38-42`, `ORCHESTRATION_PROTOCOL_QUERY_PARAM = "orchestrationProtocol"` `environment.ts:15`).
- DPoP sockets always pass `connectionMethod: "relay"`, including learned t3-connect LAN routes (`service.ts:239-246`).

Example (paired LAN route from desktop):
`ws://192.168.1.10:3773/ws?wsTicket=<ticket>&clientSurface=desktop&clientAppVersion=<ver>&clientDeviceType=desktop&clientOs=macOS&connectionMethod=direct&orchestrationProtocol=2`

Server side (`apps/server/src/ws.ts`): route `GET /ws` (`3136-3138`); `orchestrationProtocol` must equal `"2"` else HTTP 426 JSON `{ code: "orchestration_protocol_incompatible", message: "Update this client to one that supports orchestration protocol 2.", orchestrationProtocolVersion: 2 }` (`607-612, 3142-3151`). Client params parsed leniently: `clientSurface` in `web|desktop|mobile|cli`, `clientAppVersion` max 64 chars, `clientBrowser` max 64, `clientDeviceModel` max 80 (mobile only), `clientOsMajorVersion` mobile only, `clientOs` in `macOS|Windows|Linux|iOS|Android|ChromeOS|other|unknown`, `clientDeviceType` in `desktop|phone|tablet|unknown`, `connectionMethod` in `direct|ssh|relay|unknown` (`ws.ts:598-605, 620-684`; enums `packages/contracts/src/baseSchemas.ts:345-367`). There is no `clientId` query parameter.

Upgrade auth: `wsTicket` query param if present (`apps/server/src/auth/EnvironmentAuth.ts:586, 1173-1194`), otherwise normal request auth with precedence cookie > `Authorization: Bearer` > `Authorization: DPoP` > legacy cookie (`EnvironmentAuth.ts:650-675, 717-768`). Official clients always use the ticket because browser WebSockets cannot set headers (`docs/internals/environment-auth.md:57-59`). No subprotocols: `Socket.layerWebSocket(socketUrl, { openTimeout })` passes none (`packages/client-runtime/src/rpc/session.ts:198-200`; `.repos/effect-smol/packages/effect/src/socket/Socket.ts:852-867`). Web and mobile use the global WebSocket constructor (`apps/web/src/lib/runtime.ts:57-61`, `apps/mobile/src/lib/runtime.ts:30-33`).

Ticket: `` `${base64url(JSON {v:1, kind:"websocket", sid, iat, exp})}.${signature}` ``, TTL `DEFAULT_WEBSOCKET_TOKEN_TTL = 5 minutes` (`apps/server/src/auth/SessionStore.ts:433, 866-899`). Verification checks signature, expiry, session existence/expiry/revocation; no single-use record was found (`SessionStore.ts:901-970`).

Client metadata sources: desktop `{label "T3 Code Desktop", deviceType "desktop", os, surface "desktop", appVersion}`, web `{label "T3 Code Web", deviceType, os, surface "web", webDeployment "hosted"|"server", browser, appVersion}` (`apps/web/src/connection/clientMetadata.ts:72-97`); mobile `{label "T3 Code Mobile", deviceType "tablet"|"mobile"|"unknown", os "iOS"|"Android", osMajorVersion, deviceModel, surface "mobile", appVersion}` (`apps/mobile/src/lib/authClientMetadata.ts:5-23`). Server stores surface/appVersion per session and records `client.connected` analytics (`ws.ts:3166-3169`).

### 3.5 Session open and readiness (`packages/client-runtime/src/rpc/session.ts`)

- `SOCKET_OPEN_TIMEOUT = "15 seconds"` (`45`).
- `RpcClient.makeProtocolSocket({ retryTransientErrors: false, retryPolicy: Schedule.recurs(0) })` with JSON serialization: no transport auto-retry; the supervisor owns reconnects (`201-215`).
- Hooks: `onConnect` resolves `connected`; `onPingTimeout` marks ping timeout; `onDisconnect` fails `disconnected` with transient transport detail "<label> could not establish a WebSocket connection." (never opened), "<label> stopped responding." (ping timeout), or "<label> disconnected." (`171-197`).
- Immediately subscribes `subscribeServerConfig` with the session options (`156-160, 229-292`). Web/desktop options `{ environmentThemes: true, usageLimitSources: true, usageLimitsCommand: true }` (`apps/web/src/connection/runtime.ts:34-38`); mobile `{ usageLimitSources: true, usageLimitsCommand: true }` (`apps/mobile/src/connection/runtime.ts:36-38`). Flags gate event types older clients cannot decode (`packages/contracts/src/rpc.ts:1679-1701`).
- `initialConfig` = first event with `type: "snapshot"`; its `config.environment.environmentId` must match else blocked configuration mismatch (`session.ts:293-309`; test `session.test.ts:1057-1086`).
- `ready = connected then initialConfig`, raced with `disconnected` (`session.ts:388-392`).
- `closed = disconnected` or config subscription ended ("<label> config subscription ended.") or failed (`session.ts:225-228, 276-290, 394-397`).
- Config stream errors map: `EnvironmentAuthorizationError` -> blocked permission; `KeybindingsConfigParseError`/`ServerSettingsError` -> transient remote-unavailable; `RpcClientError` -> transient transport (`session.ts:127-149`).
- The supervisor publishes `session`/`prepared` and sets phase `connected` only after `ready` (`supervisor.ts:765-780`).
- Attempt stages `"preparing" | "opening" | "synchronizing"` (`model.ts:138`) are state only; no UI consumer was found (negative search, UNVERIFIED as exhaustive).

### 3.6 Timeouts

| What | Value | Source |
|---|---|---|
| Route check (descriptor) | 2_500 ms | `driver.ts:42` |
| Descriptor default | 10_000 ms | `environment/descriptor.ts:6` |
| Auth HTTP default (ticket, token exchange, session) | 10_000 ms | `authorization/remote.ts:25` |
| Cached-token DPoP ticket | 3_000 ms | `authorization/service.ts:89` |
| DPoP authorization overall (relay mint) | 30_000 ms | `service.ts:91, 441-450` |
| Relay request | 10_000 ms | `relay/managedRelay.ts:225` |
| WebSocket open | 15 s | `rpc/session.ts:45` |
| Whole attempt | 15 s x route count | `supervisor.ts:37-38, 697-700` |
| Shell snapshot HTTP | 20_000 ms | `state/shellSnapshotHttp.ts:29` |
| Thread snapshot HTTP (full) | 20_000 ms | `state/threadSnapshotHttp.ts:22` |
| Thread bounded snapshot HTTP | 6_000 ms | `state/boundedThreadSnapshotHttp.ts:20` |
| `/api/auth/session` (permissions) | 6_000 ms | `state/session.ts:39-41` |

---

## 4. Supervisor (`packages/client-runtime/src/connection/supervisor.ts`)

### 4.1 Constants (`supervisor.ts:35-49`)

| Constant | Value |
|---|---|
| `RETRY_BASE_DELAY_MS` | `1_000` |
| `RETRY_MAX_DELAY_MS` | `300_000` (5 min) |
| `CONNECTION_ESTABLISHMENT_TIMEOUT` | `"15 seconds"` (multiplied by route count) |
| `CONNECTION_PROBE_TIMEOUT` | `"15 seconds"` |
| `QUICK_CONNECTION_PROBE_TIMEOUT` | `"3 seconds"` |
| `BACKOFF_RESET_AFTER_MS` | `30_000` |
| `BETTER_ROUTE_CHECK_INTERVAL` | `"60 seconds"` |
| `BETTER_ROUTE_COOLDOWN_MS` | `300_000` |

### 4.2 Backoff

```ts
export function retryDelayMs(failureCount: number, random: number): number {
  const ceiling = Math.min(RETRY_MAX_DELAY_MS, RETRY_BASE_DELAY_MS * 2 ** (failureCount + 1));
  return Math.round(ceiling / 2 + (ceiling / 2) * random);
}
```
(`supervisor.ts:127-140`). Called as `retryDelayMs(failureCount - 1, yield* Random.next)` after incrementing `failureCount` (`supervisor.ts:958-959`). Jitter is "equal jitter": uniform in the upper half of the ceiling. Ceilings 2 s, 4 s, 8 s, 16 s, 32 s, 64 s, 128 s, 256 s, then 300 s forever; delay range is [ceiling/2, ceiling] (tests pin jitter at max: `supervisor.test.ts:236-241, 286-295, 425-455`). Retries forever. `state.retryAt = now + delayMs` (`supervisor.ts:966-976`).

Reset rules:
- A session that stayed up at least `BACKOFF_RESET_AFTER_MS` (30 s) is "stable"; when it ends the ladder resets and `lastFailure` clears (`supervisor.ts:796-803, 910-916`). Shorter sessions keep escalating (test "keeps escalating backoff when a newly opened session flaps", `supervisor.test.ts:972`).
- Wakeups for which `resetsRetryBackoff` is true (`application-active`, `application-active-probe`, `application-active-reconnect`, `network-changed`) reset the ladder in backoff, offline and blocked waits (`wakeups.ts:22-25`; `supervisor.ts:840, 858, 894-897, 940-943, 977-980`).
- `retryNow` sets `resetRetryState`, consumed at loop top (`supervisor.ts:877-881, 1023-1026`).
- Failed probe: the next reconnect runs immediately (skips the first rung once), then normal backoff (`supervisor.ts:277-281, 909, 947-956`).

### 4.3 Error classes

- `ConnectionTransientError { reason, detail, traceId? }`, reasons `"network" | "timeout" | "transport" | "endpoint-unavailable" | "relay-unavailable" | "remote-unavailable"` -> phase `backoff` (`model.ts:60-89`; `supervisor.ts:958-980`).
- `ConnectionBlockedError { reason, detail, traceId?, serverUpdateRequired? }`, reasons `"authentication" | "configuration" | "permission" | "unsupported"` -> phase `blocked`, wait for a signal (`model.ts:70-104`; `supervisor.ts:928-945`). `"unsupported"` additionally makes the registry disable the environment, persist the disabled flag and disconnect (`registry.ts:384-398, 1107-1154`; test `registry.test.ts:1012-1035`).
- Offline is not an error: when the platform reports `offline`, no attempt is made (`supervisor.ts:891-899`).

Supervisor-generated errors: setup timeout transient timeout "<label> did not respond during connection setup." plus `NETWORK_BLOCKING_HINT` when any route is relay (`supervisor.ts:257-264, 711-724`); probe timeout transient timeout "<label> did not respond to a connection health check." (`supervisor.ts:642-647`); unexpected defect transient transport "<label> connection failed unexpectedly." (`supervisor.ts:218-229`). `NETWORK_BLOCKING_HINT = "Your DNS or firewall may be blocking T3 Connect. Try another network, such as a phone hotspot."` (`packages/client-runtime/src/errors/network.ts:3-4`).

Environment HTTP error mapping (`packages/client-runtime/src/connection/errors.ts:115-172`): `EnvironmentAuthInvalidError` -> blocked authentication "The environment credential is invalid."; `EnvironmentScopeRequiredError`/`EnvironmentOperationForbiddenError` -> blocked permission "The environment credential does not grant the required access."; `EnvironmentRequestInvalidError` -> blocked configuration "The environment rejected the authentication request."; `EnvironmentResourceNotFoundError` -> blocked configuration "The environment endpoint could not be found."; timeout -> transient timeout; fetch error -> transient network; `EnvironmentInternalError` -> transient remote-unavailable "The environment could not authorize the connection."; invalid JSON / undeclared status -> transient remote-unavailable. DPoP variant appends a hint for `invalid_credential` (`errors.ts:174-192`). Relay errors (`errors.ts:37-113`): auth-invalid and proof-expired -> blocked authentication; not-authorized, link-proof-invalid, link-limit -> blocked permission; endpoint timeout -> transient timeout; endpoint/link unavailable -> transient endpoint-unavailable; link failed / relay internal -> transient relay-unavailable; relay URL invalid -> blocked configuration; scope mismatch -> blocked permission; key/proof creation -> blocked authentication. Cloud session: signed out -> blocked authentication "Sign in to T3 Connect to connect this environment."; no token -> blocked authentication "The T3 Connect session is unavailable."; token read failure -> transient network (`apps/web/src/connection/platform.ts:232-260`, `apps/mobile/src/connection/platform.ts:161-190`); account changed mid-mint -> blocked authentication "Your cloud sign-in changed. Sign in again to authorize the environment." (`authorization/service.ts:251-264`).

### 4.4 Signals and per-phase handling

Signals: `ConnectRequested`, `DisconnectRequested`, `RetryRequested`, `NetworkChanged{network}` (only when the status actually changes), `Wakeup{reason}`, `BetterRouteAvailable{routeId}` (`supervisor.ts:56-62, 984-999`). Wakeup reasons: `"application-active" | "application-active-probe" | "application-active-reconnect" | "credentials-changed" | "network-changed"` (`wakeups.ts:5-12`).

| Phase | Waits in | Reaction |
|---|---|---|
| `available` (not desired) | `waitForSignal` | any signal but BetterRouteAvailable re-evaluates (`supervisor.ts:855-860, 883-890`) |
| `offline` | `waitForSignal` | any signal re-evaluates; resetting wakeups reset ladder; still offline -> stays offline (no attempt even on `retryNow`) (`891-899`; test `supervisor.test.ts:393-423`) |
| `connecting` | `waitForEstablishmentInterrupt` | Disconnect/Retry -> cancel attempt (retry restarts at once with reset ladder); NetworkChanged offline -> cancel; `application-active-reconnect` -> cancel, reset, replacing; `credentials-changed` with any relay route -> cancel; other wakeups ignored, so foregrounding leaves an in-flight attempt alone (`500-526`) |
| `connected` | `monitorConnectedLease` | see 4.5; Disconnect -> end; BetterRouteAvailable -> reset; `application-active-reconnect` -> reset (replace now); `credentials-changed` ends only relay leases (`533-561, 593-671`) |
| `backoff` | `waitForRetrySignal(delay)` | timer, or any Wakeup (reset ladder if resetting reason), Connect/Disconnect/Retry/NetworkChanged -> run loop immediately; BetterRouteAvailable ignored (`831-852`) |
| `blocked` | `waitForSignal` | any signal but BetterRouteAvailable triggers a new attempt (`940-944`; test `supervisor.test.ts:666-716, 886-902`) |

The `replacing` flag (set after a reset outcome) lets the next attempt run even if the network reports offline; an established attempt is otherwise discarded if desired becomes false or the network went offline (`supervisor.ts:755-763, 871-874, 891, 906, 917-921`; test `supervisor.test.ts:751-786`).

### 4.5 Probes

- `session.probe` = `initialConfig` then `server.probe` (`{}` -> `{}`) when `config.environment.capabilities.connectionProbe === true`, else `server.getConfig` (`{}`) (`rpc/session.ts:373-382`; test `session.test.ts:1196`). Server: `server.probe` returns `{}` (`apps/server/src/ws.ts:2076`), scope `orchestration:read` (`apps/server/src/auth/RpcAuthorization.ts:60-61`), descriptor advertises `connectionProbe: true` (`apps/server/src/environment/ServerEnvironment.ts:220`). Method names `"server.probe"`, `"server.getConfig"` (`packages/contracts/src/rpc.ts:462-463, 582-592`).
- `probeTimeoutFor` (`supervisor.ts:563-584`): `RetryRequested` 3 s; `NetworkChanged` to offline 3 s; `application-active` 15 s; `application-active-probe` 3 s; `network-changed` 3 s; others no probe. A shorter timeout from a later signal shortens a running probe (`supervisor.ts:661-668`; tests `supervisor.test.ts:1280-1350`).
- Deadline uses monotonic time (`supervisor.ts:629-641`). Timeout or failure ends the lease with transient timeout and reconnects immediately (`supervisor.ts:642-655, 947-956`; test `supervisor.test.ts:1212`).
- A probe answering an explicit retry does not reset the ladder for a later unrelated failure (`supervisor.ts:596-602`; test `supervisor.test.ts:841-884`).

### 4.6 Foreground, background, offline, retry, credentials

Web and desktop renderer (`apps/web/src/connection/platform.ts`):
- Connectivity: `navigator.onLine` plus window `online`/`offline` events (`65-90`).
- Wakeups: `visibilitychange` to visible -> `"application-active"` (`131-147`); managed relay account change -> `"credentials-changed"` (`148-150`); `navigator.connection.type` change -> `"network-changed"` (`96-126`). Web never emits `application-active-probe` or `application-active-reconnect`.

Mobile (`apps/mobile/src/connection/platform.ts`, `app-state-wakeups.ts`):
- Connectivity: expo-network `isConnected` true/false/other -> online/offline/unknown; re-read on AppState `active` (`platform.ts:33-83`).
- `MOBILE_BACKGROUND_RECONNECT_AFTER_MS = 10_000`; on AppState `active`, if the app was in `background` for at least 10 s -> `"application-active-reconnect"` else `"application-active-probe"` (`app-state-wakeups.ts:3-18`; `platform.ts:127-147`). `inactive` does not set the background timestamp (`platform.ts:131-143`).
- Account change -> `"credentials-changed"`; network type change while connected -> `"network-changed"` (`platform.ts:85-122, 148-151`).

Behaviors:
- Long mobile background: replace the session at once, without a probe, even if offline is reported (`supervisor.ts:549-554`; `docs/internals/connection-runtime.md:19-26`).
- Offline report while connected: quick probe; healthy session kept (loopback case); unanswered -> release, go to `offline` (`supervisor.test.ts:718-749, 787-816`).
- Explicit retry: `registry.retryNow` -> `supervisor.retryNow` (`registry.ts:1015-1020`; `supervisor.ts:1023-1026`). UI: web chat banner "Reconnect" uses `environmentCatalog.retryNow` (`apps/web/src/components/ChatView.tsx:1665, 2704-2719`); mobile "Retry now" (`apps/mobile/src/features/connection/EnvironmentConnectionNotice.tsx:88-96`).
- `credentials-changed` only disturbs relay (T3 Connect) leases and attempts; LAN sessions survive account changes (`supervisor.ts:516-522, 555-559`; tests `supervisor.test.ts:1372-1408, 1968`).
- During a server self-update the client nudges `retryNow` every 1 s while in backoff (or blocked on authentication) so a ~15 s restart is not observed as ~30 s (`packages/client-runtime/src/state/server.ts:177-219`).

### 4.7 Desktop sleep and wake

No connection-runtime hook for system sleep/wake exists. Electron `powerMonitor` `suspend`/`resume`/`lock-screen` events feed telemetry only (`apps/desktop/src/telemetry/DesktopTelemetryPublisher.ts:188-191`). Desktop relies on `visibilitychange` (15 s probe), online/offline events, the RPC ping timeout (~20 s, section 9) and server-side closes. Whether Electron emits `visibilitychange` on wake is UNVERIFIED.

### 4.8 State machine

```
                 connect()/enabled
 [available] ------------------------> loop
     ^  disconnect()                     |
     |                                   v
     |                       network == offline && !replacing ?
     |                          | yes                    | no
     |                          v                        v
     |                     [offline] --signal--> loop  [connecting stage=preparing|opening|synchronizing]
     |                                                   |  success (ready = socket open + config snapshot)
     |                                                   v
     |                                              [connected] --probe ok--> [connected]
     |                                                   | closed / probe failed / timeout
     |                                                   |        (probe failure: immediate retry)
     |                                                   v
     |   blocked error (auth/config/permission/unsupported)       transient error
     |          v                                                       v
     |     [blocked] --any signal--> loop                    [backoff retryAt] --delay or signal--> loop
     |          (unsupported: registry disables env -> desired=false -> [available])
     +-- disconnect() from any phase
```
Phases: `"available" | "offline" | "connecting" | "backoff" | "connected" | "blocked"` (`model.ts:130-136`). State: `{ desired, network, phase, stage, attempt, generation, lastFailure, retryAt }` (`model.ts:140-149`); `generation` increments per established session (`supervisor.ts:902, 910-911`); `attempt` shows the current or next attempt number (`supervisor.ts:893, 901`). Initial value when created: available, connecting(attempt 1) or offline (`supervisor.ts:282-288`); `AVAILABLE_CONNECTION_STATE` default (`model.ts:169-178`).

---

## 5. Connection status states and labels

### 5.1 Presentation mapping (`packages/client-runtime/src/connection/presentation.ts`)

`EnvironmentConnectionPhase = "available" | "offline" | "connecting" | "reconnecting" | "connected" | "error" | "unsupported"`; presentation `{ phase, error, traceId }` (`8-21`). `presentConnectionState` (`29-58`):
- available -> available; offline -> offline; connected -> connected
- connecting -> `connecting` if `attempt <= 1 && lastFailure === null`, else `reconnecting` (error = last failure)
- backoff -> `reconnecting`
- blocked -> `unsupported` if reason unsupported, else `error`

A catalog entry with `unsupportedReason` always presents as `unsupported` with that reason (`packages/client-runtime/src/state/presentation.ts:50-56`). Data-layer projection: connecting -> `"synchronizing"`, connected -> `"ready"`, else `"disconnected"` (`model.ts:151-167`). Shell status `"empty" | "cached" | "synchronizing" | "live"` (`state/shell.ts:42`); thread status adds `"deleted"` (`state/threadState.ts:6`).

`connectionStatusText` (`presentation.ts:60-81`): "Available", "Offline", "Connecting...", "Reconnecting..." or "Failed to connect. Reconnecting... Reason: <error>", "Connected", "Client not supported", "Connection failed" or "Connection failed. Reason: <error>". `connectionStatusTitle`: "Failed to connect. Reconnecting..." when reconnecting with an error, else the text without reason (`presentation.ts:83-88`). Used by CommandPalette (`apps/web/src/components/CommandPalette.tsx:1016`), provider settings (`ProviderSettingsPanel.tsx:260, 393`), settings tooltips, mobile rows.

### 5.2 Web and desktop labels

- Settings row status word `savedBackendStatus` (`apps/web/src/components/settings/ConnectionsSettings.tsx:1447-1482`): disabled -> "Off"; connected "Connected"; connecting "Connecting"; reconnecting "Reconnecting" or "Reconnecting: <error>" (error tone); unsupported "Client not supported"; error "Connection failed" or "Connection failed: <error>" (error tone); offline "Offline"; available "Not connected". During a server update resume the word is "Restarting" (`1550-1551, 1591`). Tooltip: `connectionStatusText`, unsupported reason, or "Switched off" (`1605-1615`).
- Subtitle prefix `environmentTransportLabel`: "This machine" (primary), multi-route "via <route label>" when connected else first route label, "T3 Connect", "WSL", "SSH user@host:port", display URL or "Remote link" (`apps/web/src/components/settings/EnvironmentRow.tsx:21-54`). Links "Routes" / "<n> routes" and "Permissions" (`ConnectionsSettings.tsx:1650-1683`). Switch tooltip "Client not supported" / "Switch off" / "Switch on" (`1752-1754`). Menu "Routes"/"Hide routes", "Copy MCP URL", "Copy trace ID", "Remove from this device…" (`1775-1788`).
- T3 Connect list buttons: "Connected", "Connecting…", "Reconnecting…", "Client not supported", "Connection failed", "Offline", "Not connected" (`apps/web/src/components/cloud/cloudEnvironmentConnectionPresentation.ts:17-65`).
- Chat composer banner after `ENVIRONMENT_RECONNECT_WARNING_GRACE_MS = 2_000` for connecting/reconnecting: "<label> is reconnecting" or "<label> is offline", actions "Reconnect" (not while reconnecting) and "Disconnect server" (`apps/web/src/components/ChatView.logic.ts:73`, `ChatView.tsx:2674-2700, 3109-3150`). Send while disconnected: toast "Not connected: message not sent" / "Reconnecting to the environment. Try again once it is connected." (`ChatView.tsx:8804-8805`).
- No "Resuming" connection label exists in UI code; the word appears only in comments (`supervisor.ts:551`, `state/server.ts:183`) and in `docs/internals/connection-runtime.md:23`. A UI "Resuming" label is UNVERIFIED (not found).

### 5.3 Mobile labels

- `connectionTone` pill labels: "Connected", "Reconnecting", "Connecting", "Client not supported", "Connection failed", "Offline", "Available" (`apps/mobile/src/features/connection/connectionTone.ts:4-49`).
- Environment row: "Off" when disabled, else `connectionStatusText` (`apps/mobile/src/features/connection/ConnectionEnvironmentRow.tsx:24-33`).
- Notice titles: "You are offline", "Connecting to <label>...", "Reconnecting to <label>...", "Client not supported", "<label> is unavailable" (error), "<label> is disconnected" (available); details e.g. "The app will keep retrying automatically. <error>", "Cached data remains available. The <resource> will load when your connection returns."; button "Retry now" except offline/unsupported (`EnvironmentConnectionNotice.tsx:11-53, 88-96`).
- Workspace header: "You are offline", "Reconnecting to <label>", "Reconnecting <n> environments", the error text, "Syncing threads..." / "Loading threads...", "Not connected" (`apps/mobile/src/features/home/workspace-connection-status.ts:9-46`); connecting set = connecting or reconnecting (`apps/mobile/src/state/workspaceModel.ts:70-74`).

### 5.4 "In use" marker, routes list, permissions

- Web: active route id = prepared target route id only when phase is `connected` (`apps/web/src/components/settings/EnvironmentRoutesList.tsx:65-69`); badge "In use" (`179-183`); learned suffix " · found automatically" (`185-190`); "Add route" button (`131-136`); remove confirm "Remove <label> route?" plus address (`79-90`); tooltip "Remove route" (`217`); drag reorder (`92-103`).
- Mobile: section "Routes", "Edit"/"Done", "Your permissions", "In use" pill, "found automatically", "Add route", alert "Remove <label>?" Cancel/Remove, accessibility "Route <n> of <count>" (`apps/mobile/src/features/settings/EnvironmentRoutesSection.tsx:119-132, 138-229, 286-294, 314-322`); icons per kind (`35-42`).
- Permissions come from `GET /api/auth/session` using the active connection's auth, stale time 30_000 ms, idle TTL 5 min, re-fetched when the prepared connection changes (`packages/client-runtime/src/state/session.ts:43-68, 131-160`). Web text: "These permissions apply to your active route. Other routes may have different permissions." (route context) or "These permissions apply to this client’s current connection.", rows "<title>" "Allowed"/"Not granted", fallback "Permissions not checked. Connect to this environment to view this session’s permissions." (`apps/web/src/components/settings/SessionPermissions.tsx:14-37`). Mobile: "Applies to the route marked In use. Other routes may have different permissions and have not been checked." (`EnvironmentRoutesSection.tsx:160-181`). Scope titles (`packages/shared/src/authScopeOptions.ts:21-110`): "View environment", "Operate tasks", "Change environment settings", "Manage providers", "Maintain environment", "Control previews", "View diagnostics and usage", "View terminals", "Use terminals", "Change source control", "Read files", "Write files", "View access", "Manage access", "View relay", "Manage relay". Grant check uses `permissions` when present, else legacy `scopes` (`packages/contracts/src/auth.ts:181-192`).

---

## 6. HTTP authorization

### 6.1 Request headers (`packages/client-runtime/src/state/environmentHttpAuth.ts`)

- Primary (cookie): no auth header, fetch `credentials: "include"` (`46-52`).
- Bearer: `authorization: Bearer <token>` (`75-77`).
- DPoP: `authorization: DPoP <accessToken>` and `dpop: <proof>` bound to method and URL (`78-95`).
- Orchestration endpoints add `x-t3-orchestration-protocol: 2` (`27-36`; header name `packages/contracts/src/environment.ts:16`; required literal `environmentHttp.ts:80-84`). Status for a missing header is UNVERIFIED (schema decode failure).

### 6.2 Bearer (paired)

No refresh. `/oauth/token` only exchanges bootstrap (pairing) credentials (`subject_token_type = "urn:t3:params:oauth:token-type:environment-bootstrap"`, `packages/contracts/src/auth.ts:227-231, 298-308`). Pairing: `POST /oauth/token` form-urlencoded `{grant_type "urn:ietf:params:oauth:grant-type:token-exchange", subject_token, subject_token_type, requested_token_type "urn:ietf:params:oauth:token-type:access_token", scope?, client_label?, client_device_type?, client_os?}` -> `{access_token, issued_token_type, token_type "Bearer"|"DPoP", expires_in, scope}` (`authorization/remote.ts:115-140`, `auth.ts:298-317`). Server bearer sessions use the default 30-day TTL (`SessionStore.ts:432, 669`). After expiry, the ticket request returns 401, mapped to blocked authentication; the user re-pairs (same address replaces the route in place, 2.2).

### 6.3 DPoP (T3 Connect) renewal

`getDpopToken` (`authorization/service.ts:363-474`): requires a cloud session identity; reuses the stored token only if env, account and DPoP thumbprint match, `expiresAtEpochMs > now + DPOP_ACCESS_TOKEN_REFRESH_SKEW_MS` (`60_000`, `model.ts:108`) and it is not the rejected token (`389-403`); otherwise removes a rejected token, joins a pending mint, or forks a new mint into the service scope with a 30 s timeout ("Timed out renewing the environment credential.") so one caller's timeout does not cancel others (`404-466`). Mint chain (`exchangeDpopToken`, `service.ts:278-361`):
1. Clerk token + device id; relay DPoP access token from `POST {relay}/v1/client/dpop-token` (cached until 5 s before expiry, refreshed once if the relay rejects it) (`relay/managedRelay.ts:485-605, 655-692`; contract `packages/contracts/src/relay.ts:1111-1124`).
2. `POST {relay}/v1/environments/:environmentId/connect` with `authorization: DPoP <relayToken>`, `dpop: <proof>`, body `{deviceId?, clientKeyThumbprint}`, scope `"environment:connect"` -> `{environmentId, endpoint{httpBaseUrl, wsBaseUrl, providerKind}, credential, expiresAt}` (`managedRelay.ts:399-404, 812-841`; `relay.ts:714-737, 815-821, 1131-1143`).
3. Descriptor check at `endpoint.httpBaseUrl` (env id must match).
4. `POST <endpoint>/oauth/token` with `dpop` proof (htu = that URL) -> DPoP access token, `expiresAtEpochMs = now + expires_in * 1000` (`service.ts:325-360`). Server issues DPoP sessions with TTL 1 hour (`apps/server/src/auth/EnvironmentAuth.ts:908-947`).

`authorizeDpop` (`service.ts:490-544`): with a cached token it first tries the ticket with a 3 s timeout; on the tunnel any non-blocked failure re-mints with the old token marked rejected; on a direct (learned) endpoint only `EnvironmentAuthInvalidError` re-mints, other failures are reported without discarding the token; final failure removes the token (relay, or blocked errors).

HTTP data requests (`environmentHttpAuth.ts:124-231`): for DPoP, `authorizeDpopHttp` runs per request (cached token or renewal); relay targets follow the token's current endpoint while learned direct routes keep their origin (`175-178`).

### 6.4 401 handling

`EnvironmentAuthInvalidError { code: "auth_invalid", reason: "missing_credential" | "invalid_credential", dpopFailureReason?, traceId }`, HTTP 401 (`packages/contracts/src/environmentHttp.ts:98-102, 148-166`). `DpopFailureReason`: `time_window`, `key_mismatch`, `request_mismatch`, `token_mismatch`, `replay`, `invalid_proof` (`packages/contracts/src/baseSchemas.ts:37-45`). Server adds `www-authenticate: DPoP` on DPoP 401s (`apps/server/src/auth/http.ts:50-61`).
- Data requests: DPoP + `invalid_credential` -> one retry with a renewed token; second failure surfaces; bearer and cookie never retry (`environmentHttpAuth.ts:196-207`). `/api/auth/session` returning `authenticated: false` counts as unauthorized for DPoP and also gets one retry (`environmentHttpAuth.ts:209-221`, `state/session.ts:65-66`).
- Connection: mapped to blocked authentication; DPoP `invalid_credential` detail gets a hint: time_window -> "Hint: Check that automatic date and time is enabled on both devices, then try again."; missing reason -> "Hint: Try again. If it still fails, clock skew may be the cause; check that automatic date and time is enabled on both devices."; other -> "Hint: Try again. If the problem continues, copy the trace ID." (`errors.ts:174-192`, `packages/client-runtime/src/relay/errorPresentation.ts:4-22`).

### 6.5 Credential expiry and the socket

Client rule: credential expiry does not close the socket; HTTP renewal never replaces a healthy socket (`docs/internals/connection-runtime.md:36-41`; test `supervisor.test.ts:1410-1440` keeps a relay session for 2 hours of test clock).
Server reality: the `/ws` handler races the RPC socket against `sessions.awaitInvalidation(sessionId)`, which completes on revocation/replacement or when the session's `expiresAt` passes, ending the socket (`apps/server/src/ws.ts:3225-3239`, `apps/server/src/auth/SessionStore.ts:1053-1080`; test "expires a connected session at its credential deadline" `SessionStore.test.ts:147-166` with 1 hour DPoP TTL). So a T3 Connect socket is closed by the server about 1 hour after its token was minted, and a paired bearer socket at the 30-day expiry; the client reconnects as a transient failure. Close code UNVERIFIED. Session listings keep connected sessions after expiry (`docs/internals/connection-runtime.md:43-46`, `SessionStore.ts:559`).

### 6.6 DPoP proof format (server verification)

`packages/shared/src/dpop.ts`: header `typ: "dpop+jwt"`, `alg: "ES256"`, `jwk` (P-256) (`12-13, 38-44`); payload `htm`, `htu`, `jti`, `iat`, optional `ath` (`47-55`); method must match (`145-147`); `htu` compared after stripping query and fragment (`148-151`, `packages/shared/src/dpopCommon.ts:11-20`); `ath = base64url(sha256(accessToken))` (`96-98, 152-160`); thumbprint `base64url(sha256(...jwk))` (`92-94`); `iat` must satisfy `iat <= now + 5` and `now - iat <= 300` (`DEFAULT_MAX_AGE_SECONDS = 300`, `14, 178-188`). Replay: one-time marker keyed by `sha256(thumbprint:jti)` (`apps/server/src/auth/dpop.ts:85-123`). DPoP tokens require a DPoP header; a DPoP header with a non-proof-bound token fails (`EnvironmentAuth.ts:738-765`).

---

## 7. Event stream resumption

### 7.1 RPC methods and payloads

- `"orchestration.subscribeShell"` input `{ afterSequence?: NonNegativeInt, requestCompletionMarker?: boolean }`, output `OrchestrationV2ShellStreamItem` (`packages/contracts/src/orchestrationV2.ts:3151, 3223-3236, 3602-3605`).
- `"orchestration.subscribeThread"` input `{ threadId, afterSequence?, requestCompletionMarker?, acceptBoundedSnapshot?, acceptCompactTurnItems? }`, output `OrchestrationV2ThreadStreamItem` (`orchestrationV2.ts:3152, 3238-3258, 3606-3609`).
- Shell items (`orchestrationV2.ts:1945-1982`): `{kind: "synchronized"}`; `{kind: "snapshot", snapshot, resolvedRepositoryIdentityRoots?}`; `{kind: "project.updated", sequence, project}`; `{kind: "project.removed", sequence, projectId}`; `{kind: "thread.updated", sequence, location: "active"|"archive", thread}`; `{kind: "thread.removed", sequence, location, threadId}`. Snapshot `{schemaVersion, snapshotSequence, threads, archivedThreads, projects}` (`1931-1943`).
- Thread items (`orchestrationV2.ts:3366-3393`): `{kind: "synchronized"}`; `{kind: "snapshot", snapshotSequence, projection, historyCursor?, hasMoreHistory?, latestLocalTurnOrdinal?, payloadBudgetExceeded?, turnItemsOmitLocalVisible?}`; `{kind: "event", sequence, event}`; unknown event types decode to `{kind: "unknown-event", sequence, eventType}` and still advance the cursor (`3327-3364`).
- HTTP: `GET /api/orchestration/shell`, `GET /api/orchestration/threads/:threadId`, `GET /api/orchestration/threads/:threadId/bounded?compactTurnItems=1`, `GET /api/orchestration/threads/:threadId/history?cursor&throughEntryId&view` (`environmentHttp.ts:583-641`). Bounded snapshot: "Resume live events with `afterSequence = snapshotSequence`" (`orchestrationV2.ts:3278-3303`).
- Server advertises `shellResumeCompletionMarker: true`, `threadResumeCompletionMarker: true` in ServerConfig (`apps/server/src/ws.ts:1728-1729`; contract `server.ts:670-678`).

### 7.2 Durable subscription mechanics (`packages/client-runtime/src/rpc/client.ts`)

- Requests resolve the current session at execution time; no session -> `EnvironmentRpcUnavailableError` "<label> is not connected." (no queueing, no mutation replay) (`130-146`; `docs/internals/connection-runtime.md:82-87`).
- Subscriptions `switchMap` over `supervisor.session` changes, so they follow replacement sessions; `resubscribe` stream re-subscribes on the same session (`254-290`).
- Transport failure (`RpcClientError`) -> log "Durable RPC subscription lost its transport; waiting for the next session." and wait (`331-351`). Expected domain failure -> `onExpectedFailure`, then retry on the same session after `retryExpectedFailureAfter`, doubling to `MAX_EXPECTED_FAILURE_RETRY_DELAY_MS = 30_000`; reset by the first value; authorization failures are not retried (`105-106, 236-252, 352-380`).
- Shell and thread both use `retryExpectedFailureAfter: "250 millis"` and resubscribe on wakeups `application-active` / `application-active-probe` (`shouldResubscribeAfterWakeup`, `wakeups.ts:27-30`; `state/shell.ts:325-329, 406-410`; `state/threads.ts:774-778, 895-900`).

### 7.3 Shell (`packages/client-runtime/src/state/shell.ts`)

- Initial state from the cache (`76-92`).
- On each subscription (`makeSubscribeInput`, `335-405`): mark synchronizing; `supportsCompletionMarker = config.shellResumeCompletionMarker === true`. For a new session (no authoritative snapshot on this session) or no snapshot: wait for `supervisor.prepared`, load `GET /api/orchestration/shell` (20 s, `shellSnapshotHttp.ts:23-64`), apply as authoritative snapshot. If HTTP succeeded: input `{afterSequence: snapshot.snapshotSequence, requestCompletionMarker?}`; if it failed: `{requestCompletionMarker?}` only (server sends a full snapshot). Same-session foreground resubscribes resume from the in-memory cursor. Without marker support the status is set "live" immediately.
- Applying items (`186-249`): `synchronized` -> live; `snapshot` -> `mergeShellSnapshotProjects`; events applied only if `item.sequence > snapshot.snapshotSequence` (`214-220`; reducer also guards `shellReducer.ts:143`), each event advances `snapshotSequence` (`shellReducer.ts:136-200`).
- Snapshot merge (`shellReducer.ts:90-133`): a snapshot with `resolvedRepositoryIdentityRoots` is an enrichment (metadata only, merge repository identities into existing projects); without it, it is authoritative and replaces the snapshot.
- Supervisor phase drives shell status (`413-425`); stream error message "Could not synchronize environment data." (`68, 163-177`).
- Server (`apps/server/src/ws.ts:943-1184`): no `afterSequence` -> full snapshot (+ marker) then live; if `afterSequence > head` or gap > `SHELL_RESUME_MAX_GAP = 1_000` events or replay payload > `ORCHESTRATION_REPLAY_PAYLOAD_BUDGET_BYTES = 8 MiB` -> full snapshot (`546-555, 686-713, 1141-1149`); otherwise metadata-only enrichment snapshot, replay of events after the cursor, marker, then live (`1151-1162`; `apps/server/src/orchestration-v2/ShellStream.ts:186-222`). Live batching `groupedWithin(512, 50 ms)` (`ws.ts:1032-1038`). Unchanged thread shells are skipped but re-sent at least every `UNCHANGED_THREAD_SHELL_RESEND_MS = 5_000` (`ShellStream.ts:226-239`).

### 7.4 Thread (`packages/client-runtime/src/state/threads.ts`)

- Initial data: retained resume cache (5 min idle) or persisted cache; cursor `lastSequence` seeded from it, else 0 (`170-234`).
- `makeSubscribeInput` (`799-894`): deleted threads park forever; marker support from `config.threadResumeCompletionMarker`; only when there is no data: load HTTP bounded snapshot (`GET .../bounded?compactTurnItems=1`, 6 s) falling back to full (`GET .../threads/:id`, 20 s) on 404 route or invalid JSON; `missing` (structured 404) marks deleted; `unavailable` falls through to the socket (`boundedThreadSnapshotHttp.ts:60-174`, `threads.ts:816-873`). Input: `{threadId, afterSequence: lastSequence (if data), requestCompletionMarker?, acceptBoundedSnapshot: true, acceptCompactTurnItems: true (when history paging is supported)}` (`875-893`). Unlike the shell, a new session does not re-fetch HTTP when data exists; it resumes from the cached cursor.
- Applying (`444-635`): events with `sequence <= lastSequence` are dropped (`451`); unknown events advance the cursor (`452-466`); `thread.deleted` -> deleted and cache removed (`416-437`); `snapshot` sets `lastSequence = snapshotSequence` and replaces the projection (`584-607`); `synchronized` -> live (`574-582`). State and cursor are committed together only after an update finishes (`237-251`).
- Server (`apps/server/src/ws.ts:747-941`): with `afterSequence`: cursor above head -> snapshot; more than `THREAD_RESUME_MAX_REPLAY_EVENTS = 128` events or raw payload over `1_048_576` bytes -> snapshot; a create event in range with a live thread -> snapshot; encoded replay over `THREAD_RESUME_MAX_REPLAY_ENCODED_BYTES = 1_048_576` -> snapshot; else replay, marker, live from head (`870-936`; `apps/server/src/orchestration-v2/ThreadStream.ts:14-30, 106-120`). Snapshot path: bounded window when `acceptBoundedSnapshot` else full, then marker, then live from `snapshotSequence` (`826-860`).
- Older history pages via HTTP `/history` (`threads.ts:637-749`).

### 7.5 Idle cache, persistence, keep-alive

- `THREAD_SNAPSHOT_IDLE_TTL_MS = 5 * 60_000` on the resume-cache atom; the live atom has idle TTL 0, so the stream stops when the last consumer unmounts (`packages/client-runtime/src/state/threadRetention.ts:1-3`, `threads.ts:920-958`).
- Thread cache persisted only when no run is preparing/starting/running and history not expanded (`threads.ts:110-122`); cache writes: first after 500 ms, then at most every 10 s (`state/cachePersistence.ts:5-19`).
- Desktop only: keep-alive mounts every thread whose shell status is preparing/starting/running until its own stream is live and settled (`apps/web/src/state/threads.ts:53-136`, mounted when Electron `apps/web/src/routes/__root.tsx:231`).

### 7.6 Server config stream

The session buffers the latest config projection and replays `snapshot` (+ themes / usage-source events) to each new subscriber; updates go through `PubSub.sliding(64)`; a skipped revision replays a fresh snapshot (`rpc/session.ts:97-123, 220-351`). `state/server.ts` caches the last full config per environment (`368-453`).

---

## 8. Registry (`packages/client-runtime/src/connection/registry.ts`)

- Scoping: one service scope (supervisor) per `EnvironmentId`; per-environment lease locks serialize mutations (`200-204, 279-332`). `acquireSupervisor` reuses the supervisor while the entry is equal, else recreates it (`404-421`). `run`/`runStream`/`followStream` provide the supervisor; `followStream` re-subscribes when the entry object changes (`423-478`). `start` acquires all persisted environments; enabled ones connect (`360-402, 480-495`).
- Involuntary disconnect keeps registration and cached data (test `registry.test.ts:674-722`).
- `remove` (user-saved only; platform envs fail with `PlatformEnvironmentRemovalError`): forget GitHub trust, delete persisted registration (all routes, credentials, DPoP token, disabled flag, GitHub permissions), close scope, drop entry, clear cache (shell, threads, server config, VCS refs, web favicons) and platform-owned data, disconnect managed SSH (`820-879`; web owned data = composer drafts `apps/web/src/connection/platform.ts:745-753`; mobile = thread outbox, drafts, composer errors `apps/mobile/src/connection/platform.ts:254-274`; web cache clear `apps/web/src/connection/storage.ts:891-909`).
- `setEnabled`: off disconnects, stops the ladder, persists; registration, credentials, cache untouched; refuses to enable an unsupported entry (`1021-1076`).
- `setCompatibility`: unsupported -> `enabled: false`, persisted disable, disconnect (`1107-1154`).
- Cloud account change: `removeRelayEnvironments()` removes only the `"relay"` route of each environment (and its learned t3-connect routes); environments with no remaining route are removed; directly paired environments stay (`993-1013`; `docs/internals/connection-runtime.md:31-32`). Called on sign-out or account switch together with a relay token cache reset (`apps/web/src/cloud/managedAuth.tsx:51-70`; mobile `apps/mobile/src/features/cloud/CloudAuthProvider.tsx:55, 96`).
- Platform registrations (desktop primary + local backends) are reconciled every `PLATFORM_POLL_INTERVAL = "3 seconds"`; secondary bearer refresh skew `5_000` ms; rejected bootstrap retry 60_000 ms doubling to 30 min (`apps/web/src/connection/platform.ts:423-445, 506-550, 567-743`; `registry.ts:618-817`).

---

## 9. What a native client must replicate

Transport (Effect RPC over WebSocket, JSON, reference copy):
- One JSON value per text frame; arrays are accepted and decoded as multiple messages (`.repos/effect-smol/packages/effect/src/rpc/RpcSerialization.ts:129-139`).
- Client to server: `{"_tag":"Request","id":<number>,"tag":"<method>","payload":{...},"headers":[[k,v],...]}` (optional `traceId`, `spanId`, `sampled`), `{"_tag":"Ack","requestId":<id>}`, `{"_tag":"Interrupt","requestId":<id>}`, `{"_tag":"Ping"}`, `{"_tag":"Eof"}` (`RpcMessage.ts:28-192`; `RpcClient.ts:674-725`). Request ids come from a numeric counter (`RpcClient.ts:217, 273`).
- Server to client: `{"_tag":"Chunk","requestId","values":[...]}`, `{"_tag":"Exit","requestId","exit":{"_tag":"Success","value"} | {"_tag":"Failure","cause":[{"_tag":"Fail","error"}|{"_tag":"Die","defect"}|{"_tag":"Interrupt","fiberId"}]}}`, `{"_tag":"Defect","defect"}`, `{"_tag":"Pong"}`, `{"_tag":"ClientProtocolError","error"}` (`RpcMessage.ts:201-358`). Test wire example: `session.test.ts:265-283`.
- Ack every Chunk: the server holds the next chunk of a stream until the client acks (`RpcServer.ts:199-202, 401-453`); terminal streams use an ack window (`apps/server/src/terminal/OutputProtocol.ts:11-40`).
- Ping: send `{"_tag":"Ping"}` every 5 s; with the patch the socket is dropped after 3 consecutive unanswered intervals, about 20 s (`patches/effect@4.0.1.patch:102-125`; test "tolerates two missed pong windows before closing the session" `packages/client-runtime/src/rpc/session.test.ts:1088-1116`). Server answers Ping with Pong (`RpcServer.ts:806-807`). No server-initiated ping or WebSocket idle timeout was found in `apps/server/src` (negative search).
- First request on each socket is `subscribeServerConfig`; ready = first `snapshot` with the right environmentId; only request event flags you can decode, and do not set `usageLimitsCommand` unless you implement `/usage-limits` (`rpc.ts:1679-1701`).
- Use `server.probe` for liveness on foreground/retry/network change, with 15 s (foreground) / 3 s (retry, offline, network change) timeouts.
- Interrupt subscriptions you stop consuming (server interrupts the handler, `RpcServer.ts:203-215`).
- Server enables permessage-deflate (`apps/server/src/server.ts:251-262`); it uses the `ws` WebSocketServer (`.repos/effect-smol/packages/platform/node/src/NodeHttpServer.ts:77-85, 145-146`). `ws` default `maxPayload` (100 MiB) is UNVERIFIED (library not in repo).
- Large payloads go over HTTP (shell/thread snapshots, PR diffs) (`environmentHttp.ts:660-674`; `shellSnapshotHttp.ts:31-36`).

Connection policy to mirror: descriptor check before sending credentials to a direct address; `orchestrationProtocol=2` plus descriptor version check; fresh ticket per attempt (5 min TTL); route walk with 2.5 s checks; backoff `[c/2, c]` with c = 2 s doubling to 300 s, reset after 30 s stable; offline means no attempts; blocked waits for a signal; better-route checks every 60 s with 5 min cooldown; learned routes only from `directEndpoints`, never loopback, never plain HTTP from an HTTPS origin; expect server-side closes at token expiry.

Background activity (both official clients): `server.reportClientActivity` every `REPORT_INTERVAL_MS = 25_000` with `ttlMs = LEASE_TTL_MS = 45_000`, debounced 250 ms on visibility/focus/online/interaction changes, baseline scope `{type: "provider-status"}` plus retained scopes (`apps/web/src/lib/backgroundActivityReporter.ts:24-28, 87-110, 175-255`; mobile `apps/mobile/src/connection/background-activity.ts:26-28, 46-118`). Payload `ClientActivityReportInput {environmentId?, clientId (max 128), clientKind "web"|"desktop-renderer"|"mobile"|"unknown", visible, focused, recentlyInteracted, appState?, lowPowerMode?, batteryState?, networkType?, scopes, ttlMs?, observedAt}` (`packages/contracts/src/background.ts:61-82`); scope `orchestration:read` (`RpcAuthorization.ts:109`). Web clientId in localStorage `"t3.backgroundActivity.clientId"` (`backgroundActivityReporter.ts:24, 64-74`); mobile `mobile-<deviceId>` (`background-activity.ts:50-53`).

Identity on the server: send `client_label`, `client_device_type`, `client_os` on token exchange and the `client*` WebSocket params so the session shows correctly in Connections (`authorization/remote.ts:27-38, 40-84`; `ConnectionsSettings.tsx:952-975`). Avoid sending stale cookies on bearer requests: cookies take precedence over `Authorization` (`EnvironmentAuth.ts:650-675`).

---

## 10. UNVERIFIED items and open questions

UNVERIFIED:
1. Effect RPC wire details and ping logic were read from `.repos/effect-smol` (reference copy, version 4.0.1) plus the repo patch, not from an installed `node_modules` build.
2. `ws` library default `maxPayload` (100 MiB) and server-side close code when a session expires.
3. HTTP status returned when `x-t3-orchestration-protocol` is missing (schema decode failure, likely 400).
4. Any "Resuming" connection label in UI (not found; only in comments and docs).
5. Whether Electron fires `visibilitychange` after system wake; how desktop detects wake beyond ping timeout.
6. Cloudflare tunnel idle timeouts for T3 Connect sockets (not in repo).
7. Exact JSON key layout of persisted TaggedClass values (`_tag` assumed from Schema.TaggedClass).
8. That no UI consumes `ConnectionAttemptStage` (negative search only).
9. WebSocket tickets appear reusable until expiry (no single-use check found in `SessionStore.ts:901-970`).

Open questions / observations:
- `ClientSurface` has no native value (`web|desktop|mobile|cli`); a native macOS client must pick one (likely `desktop`) or omit it.
- `unsupportedReason` is not persisted; after restart an incompatible direct environment shows as switched off, while relay-only ones get it back from discovery (`layer.ts:19-73`).
- The `unsupported` blocked reason is overloaded: SSH routes on non-desktop clients fail with reason `unsupported` (`apps/mobile/src/connection/platform.ts:220-239`), which stops the walk and would disable the environment via `setCompatibility`.
- A server answering `directEndpoints: []` (for example the 5 s config discovery timeout) makes clients drop all learned routes (`ws.ts:253-267`, `routes.ts:268-274`).
- Threads resume from a possibly old cached cursor on a new session and rely on the server's snapshot fallback; the shell always re-fetches HTTP on a new session.
- `docs/internals/connection-runtime.md:40` says credential expiry does not close the socket; that is client behavior only. The server closes sockets at session expiry (section 6.5).
- Desktop-local backend connection id stays `local:<id>`; edited bearer routes keep their original `bearer:<env>:<origin>` id even if the URL changes (`onboarding.ts:239`).
