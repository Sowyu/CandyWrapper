# C. Environment auth, pairing, local discovery and T3 Connect

Research notes for the native macOS (Swift 6 + AppKit) client. Source: the official repo at
`/Users/mrm/CandyWrapper-research/t3code`, tag `v0.0.46-nightly.20261009.2861`, which is the server
version running on this machine. Every claim cites `path:line` relative to the repo root. Anything
not confirmed by reading the code is marked **UNVERIFIED**. Nothing here was run against a live
server or relay.

Conventions used below:

- "Environment" means one T3 server (one `environmentId`). "Relay" means the T3 Connect Cloudflare
  Worker (`infra/relay`). "Clerk" is the identity provider that T3 Connect uses.
- `httpBaseUrl` / `wsBaseUrl` are origins with path `/` (for example `http://192.168.1.5:3773/` and
  `ws://192.168.1.5:3773/`).
- JSON shapes are given as they appear on the wire. Effect `Schema.TaggedError` bodies include a
  `_tag` field (see 1.11).
- Effect library internals are cited from the vendored reference copy in `.repos/effect-smol`,
  which is the same version the app uses (`effect` 4.0.1: `pnpm-workspace.yaml:49`,
  `.repos/effect-smol/packages/effect/package.json:4`). The app patches Effect only in MCP,
  `HttpClientResponse` and `RpcClient` (`patches/effect@4.0.1.patch:1-139`), none of which are the
  pieces relied on here.

---

## 0. Quick reference

### 0.1 Environment endpoints a native client uses

| Method and path | Auth | Request | Success |
| --- | --- | --- | --- |
| `GET /.well-known/t3/environment` | none | | `ExecutionEnvironmentDescriptor` (1.2) |
| `GET /api/auth/session` | optional | | `AuthSessionState`; never 401 (1.2) |
| `POST /oauth/token` | bootstrap credential in body; `DPoP` header for T3 Connect | form-urlencoded token exchange (1.7) | `{access_token, issued_token_type, token_type, expires_in, scope}` |
| `POST /api/auth/websocket-ticket` | Bearer or DPoP | none | `{ticket, expiresAt}` (1.8) |
| `GET /ws?orchestrationProtocol=2&wsTicket=…` | ticket | WebSocket upgrade | Effect RPC JSON socket (see `B-orchestration.md`) |
| `GET /api/auth/clients`, `POST /api/auth/clients/revoke`, `…/revoke-others`, `POST /api/auth/pairing-token`, `GET /api/auth/pairing-links`, `POST /api/auth/pairing-links/revoke` | Bearer or DPoP plus `access:*` | JSON | 1.10 |
| `GET /api/connect/link-state`; `POST /api/connect/{link-proof,relay-config,unlink,preferences}` | Bearer or DPoP plus `relay:read` or `relay:write` | JSON | 4.10 |
| `GET /api/orchestration/*` | Bearer or DPoP plus header `x-t3-orchestration-protocol: 2` | | see `B-orchestration.md` |

### 0.2 Relay endpoints a native client uses (`https://relay.t3.codes`)

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `POST /v1/client/dpop-token` | `DPoP` proof header; Clerk JWT in the form body | Clerk token to DPoP relay access token (4.5) |
| `GET /v1/environments` | `Authorization: Bearer <Clerk JWT>` | list linked environments (4.6) |
| `POST /v1/environments/:id/status` | `Authorization: DPoP <relay AT>` + `DPoP` | online/offline (4.6) |
| `POST /v1/environments/:id/connect` | `Authorization: DPoP <relay AT>` + `DPoP` | mint a one-time environment credential bound to the client key (4.7) |
| `DELETE /v1/client/environment-links/:id` | Bearer Clerk JWT | deregister (4.10) |

### 0.3 Constants

| Thing | Value | Source |
| --- | --- | --- |
| DPoP alg / curve | ES256 / P-256; `typ: dpop+jwt` | `packages/shared/src/dpop.ts:12-13` |
| DPoP `iat` window | -300 s … +5 s | `packages/shared/src/dpop.ts:14,178-188` |
| DPoP nonce | not used | 1.6 |
| Pairing code | 12 chars from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, 5 min, single use | `apps/server/src/auth/PairingGrantStore.ts:254,273-276` |
| T3 Connect minted credential | 2 min, single use, bound to `jkt`, 13 standard scopes | `apps/server/src/cloud/CloudLink.ts:1622-1628` |
| Bearer session | 30 days | `apps/server/src/auth/SessionStore.ts:432` |
| DPoP session | 1 hour; the server closes the socket at expiry | `apps/server/src/auth/EnvironmentAuth.ts:916`, 1.8 |
| WebSocket ticket | 5 min, reusable within its lifetime | `apps/server/src/auth/SessionStore.ts:433` |
| Client HTTP timeouts | 10 s environment and relay requests; 30 s DPoP authorization; 15 s connection establishment | `packages/client-runtime/src/authorization/remote.ts:25`, `packages/client-runtime/src/relay/managedRelay.ts:225`, `packages/client-runtime/src/authorization/service.ts:89`, `packages/client-runtime/src/connection/supervisor.ts:37` |
| Reconnect backoff | delay uniform in `[c/2, c]`, `c = min(300 s, 1 s·2^(n+1))`; reset after 30 s connected | `packages/client-runtime/src/connection/supervisor.ts:35-49,128-141` |
| Orchestration protocol | 2 (query `orchestrationProtocol`, header `x-t3-orchestration-protocol`) | `packages/contracts/src/environment.ts:13-16` |

### 0.4 Production public identifiers found in source

| Identifier | Value | Source |
| --- | --- | --- |
| Clerk publishable key | `pk_live_Y2xlcmsudDMuY29kZXMk` (base64 of `clerk.t3.codes$`) | `.env.example:9` |
| Clerk Frontend API | `https://clerk.t3.codes` (derived from the key) | `packages/shared/src/relayAuth.ts:32-78` |
| Clerk JWT template | `t3-relay` (claims `{"aud":"t3-code-relay"}`) | `.env.example:10`, `docs/operations/connect-setup.md:50-61` |
| Clerk CLI OAuth client id (public, PKCE) | `hzxSgY2cH10sDU2r` | `.env.example:11` |
| CLI OAuth redirect URI | `http://127.0.0.1:34338/callback` | `apps/server/src/cloud/publicConfig.ts:21`, `packages/shared/src/connectAuth.ts:82-84`, `docs/operations/connect-setup.md:42` |
| Clerk OAuth endpoints | `https://clerk.t3.codes/oauth/token`, `https://clerk.t3.codes/oauth/device_authorization` (authorize: see 4.2) | `apps/server/src/cloud/publicConfig.ts:196-206` |
| OAuth scopes (CLI) | `openid profile email offline_access` | `packages/shared/src/connectAuth.ts:22` |
| Relay URL | `https://relay.t3.codes` | `.env.example:22` |
| Hosted app | `https://app.t3.codes` (nightly `https://nightly.app.t3.codes` mentioned) | `packages/shared/src/connectAuth.ts:15`, `.env.example:26` |
| Relay public client ids | `t3-web` (web and desktop), `t3-mobile` | `packages/contracts/src/relay.ts:747-750`, `apps/web/src/cloud/managedRelayLayer.ts:80`, `apps/mobile/src/features/cloud/managedRelayLayer.ts:70` |
| Desktop Clerk redirects | `t3code://app/`, `t3code-dev://app/` | `docs/operations/connect-setup.md:63-76` |
| Android Clerk callbacks | `clerk://com.t3tools.t3code[.dev\|.preview].callback` | `docs/operations/connect-setup.md:78-88` |
| macOS bundle id (official) | `com.t3tools.t3code` | `docs/operations/connect-setup.md:92` |
| Managed tunnel hostnames | `prod-<digest>.<RELAY_TUNNEL_ZONE_NAME>`; the production zone value is **not in source** | `infra/relay/README.md:103-110`, `infra/relay/.env.example` |

---

## 1. Environment auth

### 1.1 Trust boundaries

- The environment issues and enforces its own sessions. Cloud identity (Clerk) and relay
  credentials are a separate trust boundary: "A relay token is never an environment login"
  (`docs/internals/environment-auth.md:3-5`).
- Pairing delegates a set of scopes. Exchanging a bootstrap credential can narrow that grant but
  never widen it. Client labels and device metadata have no authorization role
  (`docs/internals/environment-auth.md:9-14`).
- Cookie, bearer and DPoP are three adapters over one scoped session model. "An invalid proof must
  fail rather than fall back to bearer authentication" (`docs/internals/environment-auth.md:21-24`).
- A WebSocket handshake grants no extra authority. Every RPC declares a required scope that is
  checked before the handler runs (`docs/internals/environment-auth.md:57-62`,
  `apps/server/src/auth/RpcAuthorization.ts:266-272`).

### 1.2 Auth policy and the public descriptors

Two unauthenticated GETs tell a client what it is talking to:

1. `GET /.well-known/t3/environment` returns `ExecutionEnvironmentDescriptor`, with no auth
   middleware (`packages/contracts/src/environmentHttp.ts:449-453`). Shape
   (`packages/contracts/src/environment.ts:218-227`):

   ```json
   {
     "environmentId": "…",
     "label": "Mike's MacBook Pro",
     "platform": { "os": "darwin", "arch": "arm64", "machine": "laptop" },
     "serverVersion": "0.0.46-nightly.20261009.2861",
     "orchestrationProtocolVersion": 2,
     "capabilities": { "repositoryIdentity": true, "connectionProbe": true, "…": "…" }
   }
   ```

   `platform.os` is one of `darwin|linux|windows|unknown`, `arch` one of `arm64|x64|other`
   (`packages/contracts/src/environment.ts:18-27`). `orchestrationProtocolVersion` is absent on
   old hosts, which clients treat as 1 (`packages/client-runtime/src/connection/compatibility.ts:12-13`).
   The current protocol is 2 (`packages/contracts/src/environment.ts:13-16`). The full capability
   list is at `packages/contracts/src/environment.ts:98-215`.

2. `GET /api/auth/session` returns `AuthSessionState`
   (`packages/contracts/src/auth.ts:461-468`, endpoint `packages/contracts/src/environmentHttp.ts:457-461`).
   It never answers 401: a missing or invalid credential yields `{"authenticated": false, "auth": …}`
   (`apps/server/src/auth/EnvironmentAuth.ts:770-789`). With a valid credential:

   ```json
   {
     "authenticated": true,
     "auth": {
       "policy": "loopback-browser",
       "bootstrapMethods": ["one-time-token"],
       "sessionMethods": ["browser-session-cookie", "bearer-access-token", "dpop-access-token"],
       "sessionCookieName": "t3_session_3773_a1b2c3d4e5f6",
       "serverUpdateScope": "environment:maintain"
     },
     "scopes": ["orchestration:read", "orchestration:operate", "terminal:operate", "relay:read"],
     "permissions": ["orchestration:read", "orchestration:operate", "settings:write", "…"],
     "sessionMethod": "bearer-access-token",
     "expiresAt": "2026-11-08T10:00:00.000Z"
   }
   ```

Policy selection (`apps/server/src/auth/EnvironmentAuthPolicy.ts:23-37`):

| server `mode` | host is remote-reachable? | `policy` | `bootstrapMethods` |
| --- | --- | --- | --- |
| `desktop` | no | `desktop-managed-local` | `["desktop-bootstrap"]` |
| `desktop` | yes | `remote-reachable` | `["desktop-bootstrap", "one-time-token"]` |
| `web` (`t3 serve`) | no | `loopback-browser` | `["one-time-token"]` |
| `web` | yes | `remote-reachable` | `["one-time-token"]` |

"Remote-reachable" means the bind host is `0.0.0.0`, `::`, `[::]`, or any host that is not
`localhost`, `127.*`, `::1` or `[::1]` (`apps/server/src/auth/utils.ts:67-81`). The contract also
defines `unsafe-no-auth` (`packages/contracts/src/auth.ts:35-40`), but `EnvironmentAuthPolicy` never
produces it in this version. `sessionMethods` always lists all three methods and `serverUpdateScope`
is always `environment:maintain` (`apps/server/src/auth/EnvironmentAuthPolicy.ts:39-52`).

### 1.3 Session model

A session is a database row plus a signed token.

- **Fields**: `sessionId` (random UUIDv4), `subject`, `scopes`, `method`, client metadata
  (`label`, `ipAddress`, `userAgent`, `deviceType`, `os`, `browser`), `issuedAt`, `expiresAt`,
  `lastConnectedAt`, `revokedAt` (`apps/server/src/auth/SessionStore.ts:660-715`). The server also
  stores `client_surface` and `client_app_version` from the `/ws` URL
  (`apps/server/src/persistence/AuthSessions.ts:97-98,338-342`). These two are not exposed in
  listings.
- **Methods** (`packages/contracts/src/auth.ts:75-79`): `browser-session-cookie`,
  `bearer-access-token`, `dpop-access-token`.
- **Subjects** seen in code:

  | subject | Issued by | Source |
  | --- | --- | --- |
  | `one-time-token` | Pairing link redeemed (default) | `apps/server/src/auth/EnvironmentAuth.ts:987,1082` |
  | `administrative-bootstrap` | Startup pairing URL printed by the server | `apps/server/src/auth/EnvironmentAuth.ts:48,1088-1092` |
  | `desktop-bootstrap` | Desktop app bootstrap credential | `apps/server/src/auth/PairingGrantStore.ts:338-340,460-462` |
  | `cloud-connect` | T3 Connect mint (relay) | `apps/server/src/cloud/CloudLink.ts:1622-1628` |
  | `cli-issued-session` | `t3 auth session issue` (default) | `apps/server/src/auth/EnvironmentAuth.ts:47,1032` |
  | `mcp-client` | MCP OAuth (only accepted on `/mcp`) | `apps/server/src/auth/EnvironmentAuth.ts:79,612-619` |
  | `reusable-dev-token`, `reusable-dev-token-child` | Dev-only reusable token | `apps/server/src/auth/SessionStore.ts:512-535`, `apps/server/src/auth/EnvironmentAuth.ts:880-889` |

- **Token format** (opaque to clients; do not parse): `base64url(JSON claims) + "." +
  base64url(HMAC-SHA256(payload, server-signing-key))` (`apps/server/src/auth/SessionStore.ts:684-698,756`,
  `apps/server/src/auth/utils.ts:93-95`). Claims are
  `{v:1, kind:"session", sid, sub, scopes, method, jkt?, rtc?, iat, exp}` with `iat`/`exp` in epoch
  **milliseconds** (`apps/server/src/auth/SessionStore.ts:435-446,671-682`). The signing key is a
  32-byte random secret named `server-signing-key` in the server secret store
  (`apps/server/src/auth/SessionStore.ts:431,498`).
- **Verification**: split on `.`, constant-time HMAC compare, decode claims, check `exp`, load the
  row, reject unknown or revoked sessions (`apps/server/src/auth/SessionStore.ts:766-863`). A token
  therefore dies immediately on revocation even before its `exp`.
- **Replacement rules**:
  - A desktop-bootstrap exchange revokes earlier active sessions with the same subject and method,
    in the same transaction (`replaceActiveForSubjectAndMethod`,
    `apps/server/src/auth/EnvironmentAuth.ts:919-921`, `docs/internals/environment-auth.md:77-82`).
  - A browser-session exchange replaces only the browser session that sent its cookie
    (`apps/server/src/auth/EnvironmentAuth.ts:818-835`).
  - Ordinary pairing and T3 Connect sessions are never replaced. Each successful exchange adds a
    new session row.
- **Listing**: `GET /api/auth/clients` returns unrevoked sessions that are unexpired **or currently
  connected** (`apps/server/src/auth/SessionStore.ts:549-561,972-996`, `apps/server/src/persistence/AuthSessions.ts:317-318`,
  `docs/internals/connection-runtime.md:43-46`). Sorted with `access:write` holders first, then
  connected, then newest (`apps/server/src/auth/EnvironmentAuth.ts:588-598`).

### 1.4 Scopes and permissions

Full vocabulary (`packages/contracts/src/auth.ts:82-118`). Titles and descriptions are the ones the
CLI and UI show (`packages/shared/src/authScopeOptions.ts:21-106`).

| Scope | Title | What it gates (examples) | Standard | Admin |
| --- | --- | --- | --- | --- |
| `orchestration:read` | View environment | `server.getConfig`, `server.probe`, `orchestration.subscribeShell/subscribeThread`, all PR reads, `subscribeServerConfig` | yes | yes |
| `orchestration:operate` | Operate tasks | `orchestration.dispatchCommand`, `orchestration.launchThread`, `projects.mutate`, scheduled tasks | yes | yes |
| `settings:write` | Change environment settings | `server.updateSettings` (depends on patch), keybindings, device config | yes | yes |
| `providers:manage` | Manage providers | provider auth/install/update RPCs | yes | yes |
| `environment:maintain` | Maintain environment | `server.updateServer*`, `server.signalProcess`, `server.reportHostPowerState` | yes | yes |
| `preview:operate` | Control previews | `preview.*` mutations | yes | yes |
| `diagnostics:read` | View diagnostics and usage | trace/process diagnostics, usage, `subscribeResourceTelemetry` | yes | yes |
| `terminal:read` | View terminals | `terminal.observe`, `subscribeTerminalEvents/Metadata` | yes | yes |
| `terminal:operate` | Use terminals | `terminal.open/attach/write/resize/...` | yes | yes |
| `source-control:write` | Change source control | push, branch, clone, worktree, PR mutations | yes | yes |
| `filesystem:read` | Read files | `projects.readFile/listEntries/search*`, `filesystem.browse`, diff previews | yes | yes |
| `filesystem:write` | Write files | `projects.writeFile` | yes | yes |
| `relay:read` | View relay | `cloud.getRelayClientStatus`, `GET /api/connect/link-state` | yes | yes |
| `access:read` | View access | `GET /api/auth/pairing-links`, `GET /api/auth/clients`, `subscribeAuthAccess` | no | yes |
| `access:write` | Manage access | create/revoke pairing links, revoke sessions | no | yes |
| `relay:write` | Manage relay | `cloud.installRelayClient`, `/api/connect/link-proof`, `relay-config`, `unlink`, `preferences` | no | yes |
| `review:write` | (retired) | Kept only to decode old credentials; grants nothing (`packages/contracts/src/auth.ts:94-95`) | no | no |

- `AuthStandardClientScopes` is the 13-scope "Standard" set (`packages/contracts/src/auth.ts:205-219`).
  `AuthAdministrativeScopes` adds `access:read`, `access:write`, `relay:write`
  (`packages/contracts/src/auth.ts:220-225`). `AuthGrantScope` is everything except `review:write`
  (`packages/contracts/src/auth.ts:123-128`).
- The RPC to scope map is `apps/server/src/auth/RpcAuthorization.ts:43-209`, with payload-dependent
  overrides at `apps/server/src/auth/RpcAuthorization.ts:243-264`. HTTP routes call
  `requireEnvironmentScope` (`apps/server/src/auth/http.ts:219-227`,
  `apps/server/src/cloud/http.ts:114-142`). The client-side guard list is
  `packages/contracts/src/clientRpcPermissions.ts:11-59` (advisory only; the server still decides).
- **`scopes` vs `permissions` on the wire.** Every auth response carries `scopes` filtered to the
  frozen legacy vocabulary (`orchestration:read`, `orchestration:operate`, `terminal:operate`,
  `review:write`, `access:read`, `access:write`, `relay:read`, `relay:write`), plus `permissions`
  holding the exact grant (`packages/contracts/src/auth.ts:130-145`). New clients must use
  `permissions` when it is present, even if empty. When `permissions` is absent (older server),
  check the legacy parent mapping
  (`packages/contracts/src/auth.ts:152-192`, `docs/internals/environment-auth.md:69-75`):

  | Permission | Legacy parent |
  | --- | --- |
  | `filesystem:read`, `diagnostics:read` | `orchestration:read` |
  | `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `source-control:write`, `filesystem:write` | `orchestration:operate` |
  | `terminal:read` | `terminal:operate` |

  The exact client algorithm is `sessionGrantsScope` (`packages/contracts/src/auth.ts:181-192`). If
  `auth.serverUpdateScope` is present (first granular release), the parent fallback is not applied.
  Unknown permission strings in responses are ignored (`ForwardCompatibleArray`,
  `packages/contracts/src/auth.ts:147-150`). Grant inputs stay strict.

### 1.5 Credential transports

| Transport | Request form | Who uses it |
| --- | --- | --- |
| Cookie | Cookie named `auth.sessionCookieName` | Web app served by the environment, desktop renderer for its own local server |
| Bearer | `Authorization: Bearer <token>` | Paired remote environments (web, desktop, mobile), desktop main process, CLI-issued sessions |
| DPoP | `Authorization: DPoP <token>` plus `DPoP: <proof JWT>` | T3 Connect sessions (relay-minted), including learned direct routes |

Rules (all in `apps/server/src/auth/EnvironmentAuth.ts`):

- **Precedence**: cookie, then `Bearer`, then `DPoP`, then the legacy cookie, then the dev cookie
  (`:650-676`, `:717-735`). **A cookie wins over an `Authorization` header.** A native client must
  not let `URLSession` store and replay cookies from this host (see section 6).
- If the session row carries a proof-key thumbprint (`jkt`), the request must use the `DPoP` scheme
  with the same token, and a valid proof whose `ath` matches. Sending a DPoP-bound token as
  `Bearer` fails with `dpopFailureReason: "invalid_proof"` (`:736-756`).
- Sending a non-bound token with the `DPoP` scheme also fails, again `invalid_proof` (`:757-764`).
- A credential whose session subject is `mcp-client` is rejected everywhere except `/mcp`
  (`:612-619`, `:706`).
- `WWW-Authenticate: DPoP` is added to 401 responses in two cases:
  - Authenticated routes, when the request used `Authorization: DPoP …`
    (`apps/server/src/auth/http.ts:50-64,258`).
  - `/oauth/token`, only when the `DPoP` proof itself fails verification
    (`apps/server/src/auth/http.ts:366-376`). A rejected credential with a valid proof gets no
    challenge header (`:401-405`).

Cookie attributes when the server sets one: `HttpOnly; Path=/; SameSite=Lax; Expires=<session expiry>`
and no `Secure` flag (`apps/server/src/auth/http.ts:202-217,318-325`). Cookie naming
(`apps/server/src/auth/utils.ts:26-55`):

- desktop mode: `t3_session_<port>`
- web mode on a remote-reachable host (not dev): `t3_session_<sha256(environmentId)[0:12]>`
- otherwise: `t3_session_<port>_<sha256(stateDir)[0:12]>`
- legacy name `t3_session` is still read for remote-reachable web servers (`:57-65`).

### 1.6 DPoP proofs (exact format)

The environment and the relay share one verifier, `verifyDpopProof`
(`packages/shared/src/dpop.ts:113-199`); the environment adds a replay store
(`apps/server/src/auth/dpop.ts:56-126`). The relay side is covered in section 4.

**Key.** ECDSA P-256, used with ES256 only (`packages/shared/src/dpop.ts:12-13`). The public JWK in
the header must be exactly `{kty:"EC", crv:"P-256", x, y}`, where `x` and `y` are 32-byte
coordinates in base64url, and must not contain `d` (`packages/shared/src/dpopCommon.ts:3-8`,
`packages/shared/src/dpop.ts:33-36,100-111`).

**Header** (`packages/shared/src/dpop.ts:38-44`):

```json
{ "typ": "dpop+jwt", "alg": "ES256", "jwk": { "kty": "EC", "crv": "P-256", "x": "<b64url>", "y": "<b64url>" } }
```

**Claims** (`packages/shared/src/dpop.ts:47-55`):

```json
{ "htm": "POST", "htu": "https://host.example/api/auth/websocket-ticket", "jti": "<uuid v4>", "iat": 1760000000, "ath": "<b64url(sha256(access_token))>" }
```

- `htm`: HTTP method; compared case-insensitively (`packages/shared/src/dpop.ts:145-147`). Clients
  send it upper-case (`apps/web/src/cloud/dpop.ts:169`, `apps/mobile/src/features/cloud/dpop.ts:280`).
- `htu`: the request URL with query and fragment removed, serialized by the WHATWG URL algorithm
  (`packages/shared/src/dpopCommon.ts:11-20`). Compared by **exact string equality**
  (`packages/shared/src/dpop.ts:148-151`). The environment rebuilds the URL it compares against as
  `${x-forwarded-proto == "https" ? "https" : "http"}://${Host header}${request path}`
  (`apps/server/src/auth/dpop.ts:63-74`,
  `.repos/effect-smol/packages/effect/src/http/HttpServerRequest.ts:1050-1058`). So `htu` must use
  the scheme and authority the client actually connected to. Default ports are omitted and the
  host is lower-case, as WHATWG normalization does. Behind the T3 Connect tunnel this is the
  `https://<tunnel host>/…` URL.
- `jti`: unique per proof; clients use a random UUID v4 (`apps/web/src/cloud/dpop.ts:162-165`,
  `apps/mobile/src/features/cloud/dpop.ts:263-266`).
- `iat`: integer epoch **seconds**. Accepted if `iat <= now + 5` and `now - iat <= 300`
  (`packages/shared/src/dpop.ts:14,178-188`).
- `ath`: required whenever an access token is presented. It is
  `base64url(SHA-256(ASCII access token))` (`packages/shared/src/dpop.ts:96-98,152-161`). Omit it on
  the `/oauth/token` exchange, where no access token exists yet
  (`packages/client-runtime/src/authorization/service.ts:306-311`).
- `nonce`: **not supported.** The claims schema has no `nonce`, and no `DPoP-Nonce` header or
  `use_dpop_nonce` error exists anywhere in the server, shared code or relay (a search of
  `apps`, `packages` and `infra` returns nothing).

**Signature.** ES256 over `ASCII(b64url(header) + "." + b64url(payload))`: SHA-256 of the signing
input, then the raw 64-byte `r||s` signature (IEEE P1363 form, not DER), base64url-encoded
(`packages/shared/src/dpop.ts:163-176`, `apps/mobile/src/features/cloud/dpop.ts:289-299`). CryptoKit's
`P256.Signing.PrivateKey.signature(for:)` returns DER via `derRepresentation` and raw via
`rawRepresentation`; use `rawRepresentation`.

**Base64url** everywhere is unpadded RFC 4648 section 5
(`.repos/effect-smol/packages/effect/src/encoding/Base64Url.ts:40-41`; the tests use Node's
`base64url`, `packages/shared/src/dpop.test.ts:22-42`).

**JWK thumbprint (RFC 7638)**:
`base64url(SHA-256(UTF8('{"crv":"P-256","kty":"EC","x":"<x>","y":"<y>"}')))`. The members are in
lexicographic order with no whitespace (`packages/shared/src/dpop.ts:83-94`,
`packages/shared/src/relaySigning.ts:5-17`; the mobile client builds the same string literally,
`apps/mobile/src/features/cloud/dpop.ts:112-119`).

**Server validation order** (`packages/shared/src/dpop.ts:113-199`, then
`apps/server/src/auth/dpop.ts:56-126`):

1. A proof must be present, then it must be a 3-part compact JWS, and the header and payload must
   decode.
2. The thumbprint must equal the expected one (the session's `jkt`) → else `key_mismatch`.
3. `htm` must match → else `method_mismatch`. `htu` must match → else `url_mismatch`.
4. `ath` must match when an access token is presented → else `access_token_hash_mismatch`.
5. The P-256 signature must verify → else `invalid_signature`. The `iat` window must hold → else
   `time_window`.
6. **Replay**: the environment atomically creates a secret-store entry named
   `dpop-proof-` + `base64url(sha256("<thumbprint>:<jti>"))`. If it already exists the request
   fails with `replay` (`apps/server/src/auth/dpop.ts:87-124`). Markers are pruned after 1 day,
   hourly (`apps/server/src/auth/replayMarkers.ts:17-25,67-77`). **Every proof must therefore
   carry a fresh `jti`. Never retry a request with the same proof.**

The internal failure codes map to the wire `dpopFailureReason` values
(`apps/server/src/auth/dpop.ts:24-41`, `packages/contracts/src/baseSchemas.ts:37-44`):

| Internal code | Wire `dpopFailureReason` |
| --- | --- |
| `time_window` | `time_window` |
| `key_mismatch` | `key_mismatch` |
| `method_mismatch`, `url_mismatch` | `request_mismatch` |
| `access_token_hash_mismatch` | `token_mismatch` |
| replay marker exists | `replay` |
| `missing_proof`, `malformed_proof`, `invalid_signature`, `invalid_proof` | `invalid_proof` |

**Reference implementations** to mirror:

- Mobile (closest to a native client): `apps/mobile/src/features/cloud/dpop.ts`. It generates a
  random 32-byte scalar (`:168-192`), keeps the private JWK as JSON in Expo SecureStore under the key
  `t3code.cloud.dpop-proof-key` (`:89,194-237`), and builds the header, payload and signature by
  hand (`:246-302`).
- Web and desktop renderer: `apps/web/src/cloud/dpop.ts`. It generates a WebCrypto ECDSA P-256 key,
  re-imports the private key as non-extractable (`:110-143`), stores it in IndexedDB database
  `t3code:cloud-auth`, store `keys`, id `relay-dpop-proof-key` (`:24-27`), and signs with `jose`
  (`:145-185`).
- One key per client install is shared by the relay and every environment. The connect request
  binds the minted credential to this key's thumbprint
  (`packages/client-runtime/src/relay/managedRelay.ts:611-639,823-827`). For a native client, a
  Secure Enclave P-256 key (`SecureEnclave.P256.Signing.PrivateKey`) satisfies every requirement
  here, because only the public JWK and signatures ever leave the device.

### 1.7 Token exchange: `POST /oauth/token`

Endpoint `packages/contracts/src/environmentHttp.ts:471-477`. Handler
`apps/server/src/auth/http.ts:353-414`. Logic `apps/server/src/auth/EnvironmentAuth.ts:859-955`.

Request: `Content-Type: application/x-www-form-urlencoded` (required). The payload is declared
`asFormUrlEncoded` (`packages/contracts/src/auth.ts:298-307`), and Effect's router answers any
other content type with `415 Unsupported content-type: <type>` as plain text. A missing
`Content-Type` is treated as JSON
(`.repos/effect-smol/packages/effect/src/http-api/HttpApiBuilder.ts:763-775`).

| Field | Required | Value |
| --- | --- | --- |
| `grant_type` | yes | `urn:ietf:params:oauth:grant-type:token-exchange` |
| `subject_token` | yes | the bootstrap credential (pairing code, desktop bootstrap token, or relay-minted credential) |
| `subject_token_type` | yes | `urn:t3:params:oauth:token-type:environment-bootstrap` |
| `requested_token_type` | yes | `urn:ietf:params:oauth:token-type:access_token` |
| `scope` | no | space-separated scopes to narrow to |
| `client_label` | no | free text, for example `T3 Code Desktop` |
| `client_device_type` | no | `desktop`, `mobile`, `tablet`, `bot`, `unknown` |
| `client_os` | no | free text; clients send `macOS`, `iOS`, … |
| header `DPoP` | only for proof-bound credentials | proof for `POST <httpBaseUrl>/oauth/token`, without `ath` |

Constants: `packages/contracts/src/auth.ts:227-231`.

Response `200` (`packages/contracts/src/auth.ts:310-316`,
`apps/server/src/auth/EnvironmentAuth.ts:934-950`), with `Cache-Control: no-store` and
`Pragma: no-cache` (`apps/server/src/auth/http.ts:41-48,383`):

```json
{
  "access_token": "eyJ2Ijox….<hmac>",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer",
  "expires_in": 2591999,
  "scope": "orchestration:read orchestration:operate settings:write providers:manage environment:maintain preview:operate diagnostics:read terminal:read terminal:operate source-control:write filesystem:read filesystem:write relay:read"
}
```

- `token_type` is `"DPoP"` and `expires_in` is about 3600 when a valid `DPoP` header was presented
  (`apps/server/src/auth/EnvironmentAuth.ts:908-918,941`). Otherwise it is `"Bearer"` with the
  30-day default (`apps/server/src/auth/SessionStore.ts:432`).
- `scope` is the full exact grant, space-separated, not legacy-filtered
  (`apps/server/src/auth/EnvironmentAuth.ts:948`).
- **Scope narrowing** (`apps/server/src/auth/http.ts:359-365`,
  `apps/server/src/auth/EnvironmentAuth.ts:901-907`, `apps/server/src/auth/PairingGrantStore.ts:507-519,559-572`):
  - The `scope` value is parsed as an RFC 6749 token list (`packages/shared/src/oauthScope.ts:22-33`).
    Unknown and retired names are silently dropped.
  - Invalid syntax, or nothing left after dropping, gives 400 `invalid_scope`, and the link is
    **not** consumed.
  - If none of the requested scopes is in the grant, the response is 400 `scope_not_granted` and
    the link is **not** consumed. The check sits in the SQL `UPDATE … WHERE`
    (`apps/server/src/auth/PairingGrantStore.ts:559-561`).
  - Otherwise the session gets the intersection. Omitting `scope` gives the whole grant. Official
    clients omit `scope` (`packages/client-runtime/src/connection/onboarding.ts:131-135`,
    `packages/client-runtime/src/authorization/service.ts:323-328`).
- **Label precedence**: if the pairing link itself has a label, that label overrides
  `client_label` (`apps/server/src/auth/EnvironmentAuth.ts:922-925`). T3 Connect sessions are
  therefore always labelled `T3 Connect connect` (`apps/server/src/cloud/CloudLink.ts:1622-1628`).
- **Device metadata** is derived by `deriveAuthClientMetadata`
  (`apps/server/src/auth/utils.ts:182-198`):
  - `deviceType` is `client_device_type`, else it is inferred from `User-Agent`
    (`bot|crawler|spider|slurp|curl|wget` → `bot`, `ipad|tablet` → `tablet`, mobile patterns →
    `mobile`, otherwise `desktop`, `:122-138`).
  - `os` is `client_os`, else it is inferred from `User-Agent`.
  - `browser` is inferred from `User-Agent`.
  - `ipAddress` is the socket peer, and `userAgent` is the raw header.
  - A default `CFNetwork/… Darwin/…` UA matches none of the mobile patterns, so it is classified
    `desktop`. Send `client_device_type=desktop` and `client_os=macOS` explicitly anyway.
- **Errors**: 400 `invalid_request` (`invalid_scope` | `scope_not_granted`), 401 `auth_invalid` /
  `invalid_credential` (unknown, used, expired, revoked, or proof-key mismatch; all are
  deliberately indistinguishable), 401 with `dpopFailureReason` when the DPoP header is bad, and
  500 `internal_error` / `access_token_issuance_failed`
  (`apps/server/src/auth/http.ts:366-412`, `apps/server/src/auth/EnvironmentAuth.ts:600-610`).

`POST /api/auth/browser-session` with JSON `{"credential": "<pairing code>"}` is the cookie
variant used by the web app served from the environment. It returns
`{authenticated, scopes, permissions, sessionMethod, expiresAt}` and sets the session cookie
(`packages/contracts/src/auth.ts:263-274`, `apps/server/src/auth/http.ts:298-352`,
`apps/web/src/environments/primary/auth.ts:228-251`). A native client should not use it.

### 1.8 WebSocket tickets and the `/ws` upgrade

Bearer and DPoP clients never put their access token in the socket URL. They mint a short-lived
ticket over authenticated HTTP (`docs/internals/environment-auth.md:57-59`).

**Ticket.** `POST /api/auth/websocket-ticket` takes no body and requires authentication
(`packages/contracts/src/environmentHttp.ts:478-484`, handler `apps/server/src/auth/http.ts:415-428`):

- Bearer: `Authorization: Bearer <token>`.
- DPoP: `Authorization: DPoP <token>` plus a proof for `POST <httpBaseUrl>/api/auth/websocket-ticket`
  with `ath` (`packages/client-runtime/src/authorization/remote.ts:180-199`,
  `packages/client-runtime/src/authorization/service.ts:217-245`).
- Response `200` with `Cache-Control: no-store` (`packages/contracts/src/auth.ts:319-323`):
  `{"ticket": "<b64url claims>.<hmac>", "expiresAt": "2026-10-09T10:05:00.000Z"}`.
- Lifetime is 5 minutes (`apps/server/src/auth/SessionStore.ts:433,866-899`). Ticket claims are
  `{v:1, kind:"websocket", sid, iat, exp}` in ms (`:449-456`).
- A ticket is **not single-use**. Verification checks signature, expiry, and that the session is
  unexpired and unrevoked, but consumes nothing (`apps/server/src/auth/SessionStore.ts:901-970`).
  Official clients still mint a fresh ticket for every connection attempt.

**Upgrade URL.** `GET <wsBaseUrl>/ws` (`apps/server/src/ws.ts:3136-3139`). Query parameters:

| Param | Required | Notes |
| --- | --- | --- |
| `orchestrationProtocol` | **yes**, must equal `2` | Otherwise HTTP **426** with `{"code":"orchestration_protocol_incompatible","message":"Update this client to one that supports orchestration protocol 2.","orchestrationProtocolVersion":2}` (`apps/server/src/ws.ts:3140-3149,607-612`; client helper `packages/client-runtime/src/connection/compatibility.ts:38-42`) |
| `wsTicket` | yes for bearer/DPoP | `apps/server/src/auth/EnvironmentAuth.ts:586,1173-1191` |
| `clientSurface` | no | `web`, `desktop`, `mobile`, `cli` (`packages/contracts/src/baseSchemas.ts:345`) |
| `clientAppVersion` | no | at most 64 characters |
| `clientDeviceType` | no | `desktop`, `phone`, `tablet`, `unknown` (`packages/contracts/src/baseSchemas.ts:360`) |
| `clientOs` | no | `macOS`, `Windows`, `Linux`, `iOS`, `Android`, `ChromeOS`, `other`, `unknown` |
| `clientWebDeployment`, `clientBrowser` | only when the surface is `web` | |
| `clientOsMajorVersion`, `clientDeviceModel` | only when the surface is `mobile` | |
| `connectionMethod` | no | `direct`, `ssh`, `relay`, `unknown` (`packages/contracts/src/baseSchemas.ts:366`) |

The client-identity parameters are lenient: malformed values are dropped and never fail the
connection (`apps/server/src/ws.ts:620-689`). The client builder is
`appendClientConnectionParams` (`packages/client-runtime/src/authorization/remote.ts:42-84`). The
path defaults to `/ws` when `wsBaseUrl` has no path (`:217-221`).

**Upgrade authentication** (`apps/server/src/auth/EnvironmentAuth.ts:1173-1194`):

- If `wsTicket` is present and non-blank, the ticket alone authenticates. There is no DPoP proof on
  the upgrade, and a bad ticket fails with 401; it does not fall back to headers.
- Otherwise headers and cookies are used as in 1.5. Browsers send the cookie.
- Upgrade failures return the same JSON error bodies as HTTP: 401 `auth_invalid` or 500
  `internal_error` (`apps/server/src/ws.ts:3155-3165,3240-3245`).

**While connected:**

- Every RPC is authorized against the session's scopes (`apps/server/src/ws.ts:3175`).
- The server counts the session as connected (`markConnected`) and races the socket against
  `awaitInvalidation` (`apps/server/src/ws.ts:3224-3238`). That race finishes when the session is
  revoked or replaced **or when its `expiresAt` passes**
  (`apps/server/src/auth/SessionStore.ts:1053-1080`; test "expires a connected session at its
  credential deadline", `apps/server/src/auth/SessionStore.test.ts:149-167`).
- **Consequence**: a T3 Connect (DPoP) socket is closed by the server about 1 hour after the
  `/oauth/token` exchange that created its session, and a bearer socket 30 days after pairing. The
  client must expect that disconnect, re-authorize, and reconnect (section 5). The docs' statement
  "Credential expiry does not close the socket" (`docs/internals/connection-runtime.md:40-41`)
  describes the client runtime not closing it proactively. The server does close it.

### 1.9 Lifetimes

There are **no refresh tokens**. Renewal means:

- Bearer: pair again.
- DPoP: run the relay connect and token exchange again, without user interaction (section 4).
- Desktop: re-exchange the bootstrap credential.

| Credential | Lifetime | Source |
| --- | --- | --- |
| One-time pairing token (links, `t3 pair`, Settings) | 5 min, single use | `apps/server/src/auth/PairingGrantStore.ts:254,398-453` |
| Startup pairing URL credential (subject `administrative-bootstrap`, admin scopes) | 5 min (24 h if a dev URL is configured) | `apps/server/src/auth/EnvironmentAuth.ts:1086-1113`, `apps/server/src/auth/PairingGrantStore.ts:264-272,407-410` |
| T3 Connect minted credential (proof-bound, standard scopes) | 2 min, single use | `apps/server/src/cloud/CloudLink.ts:1622-1628` |
| Desktop bootstrap (seeded token, legacy) | 24 h, unlimited uses | `apps/server/src/auth/PairingGrantStore.ts:255-263,335-351` |
| Desktop bootstrap (rotating HMAC token) | 12 h windows; previous, current and next accepted | `packages/shared/src/desktopBootstrapToken.ts:4-45` |
| Bearer access token / browser cookie session | 30 days | `apps/server/src/auth/SessionStore.ts:432` |
| DPoP access token | 1 hour | `apps/server/src/auth/EnvironmentAuth.ts:913-917` |
| WebSocket ticket | 5 min, reusable within its lifetime | `apps/server/src/auth/SessionStore.ts:433` |
| MCP client session | 30 days | `apps/server/src/auth/EnvironmentAuth.ts:80` |
| DPoP proof | `iat` within [now-300 s, now+5 s] | `packages/shared/src/dpop.ts:14,178-188` |
| Relay↔environment signed proofs | at most 5 min lifetime, `iat` skew at most 60 s | `apps/server/src/cloud/linkChecks.ts:14-15,129-139` |

The pairing-token alphabet is `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (no 0, 1, I or O), the length is
12, and it is generated by rejection sampling (`apps/server/src/auth/PairingGrantStore.ts:273-306`).
Codes are case-sensitive as stored. **UNVERIFIED** whether the UI or server upper-cases user
input; nothing in the server path normalizes case.

### 1.10 Revocation and session management (HTTP)

All require authentication. The scope each needs is listed
(`packages/contracts/src/environmentHttp.ts:485-529`, `apps/server/src/auth/http.ts:429-528`).

| Method and path | Scope | Body | Response |
| --- | --- | --- | --- |
| `POST /api/auth/pairing-token` | `access:write`, plus every delegated scope | `{"label"?: string, "scopes"?: AuthGrantScope[]}` | `{"id","credential","label"?,"expiresAt"}` |
| `GET /api/auth/pairing-links` | `access:read` | none | `AuthPairingLink[]` (metadata only, never the secret) |
| `POST /api/auth/pairing-links/revoke` | `access:write` | `{"id"}` | `{"revoked": boolean}` |
| `GET /api/auth/clients` | `access:read` | none | `AuthClientSession[]` |
| `POST /api/auth/clients/revoke` | `access:write` | `{"sessionId"}` | `{"revoked": boolean}`; revoking yourself gives 403 `operation_forbidden` / `current_session_revoke_not_allowed` |
| `POST /api/auth/clients/revoke-others` | `access:write` | none | `{"revokedCount": number}` |

- Pairing-token rules: `scopes` defaults to the 13 standard scopes. An empty or duplicated list is
  400 `invalid_scope`. Delegating a scope the caller lacks is 403 `insufficient_scope`
  (`apps/server/src/auth/http.ts:434-447`).
- `AuthClientSession` (`packages/contracts/src/auth.ts:344-366`):
  `{sessionId, subject, scopes, permissions, method, client:{label?, ipAddress?, userAgent?, deviceType, os?, browser?}, issuedAt, expiresAt, lastConnectedAt|null, connected, current}`.
- Live updates: the `subscribeAuthAccess` RPC (scope `access:read`) streams `snapshot`,
  `pairingLinkUpserted`, `pairingLinkRemoved`, `clientUpserted` and `clientRemoved` events, each
  `{version:1, revision, type, payload}` (`packages/contracts/src/auth.ts:374-443`,
  `apps/server/src/ws.ts:556-595,3072-3101`).
- Revocation takes effect at once. HTTP verification checks `revokedAt`, and connected sockets of
  that session close through `awaitInvalidation` (1.8).
- **No self-logout endpoint exists.** A client that forgets an environment just deletes its token.
  The session stays listed on the host until it expires or an admin revokes it.

### 1.11 Error bodies

HTTP errors are `Schema.TaggedError` instances encoded as JSON, including `_tag`
(`packages/contracts/src/environmentHttp.ts:130-242`; wire fixtures with `_tag` at
`apps/server/src/cloud/relayResponse.test.ts:44-70`).

| Status | `_tag` | Body fields |
| --- | --- | --- |
| 400 | `EnvironmentRequestInvalidError` | `code:"invalid_request"`, `reason`: `invalid_scope`, `scope_not_granted`, `invalid_command`, `invalid_history_cursor`; `traceId` |
| 401 | `EnvironmentAuthInvalidError` | `code:"auth_invalid"`, `reason`: `missing_credential` or `invalid_credential`; optional `dpopFailureReason`; `traceId` |
| 403 | `EnvironmentScopeRequiredError` | `code:"insufficient_scope"`, `requiredScope` (legacy parent), `requiredPermission` (exact); `traceId` |
| 403 | `EnvironmentOperationForbiddenError` | `code:"operation_forbidden"`, `reason:"current_session_revoke_not_allowed"`; `traceId` |
| 404 | `EnvironmentResourceNotFoundError` | `code:"not_found"`, `reason:"thread_not_found"`; `traceId` |
| 500 | `EnvironmentInternalError` | `code:"internal_error"`, `reason` (one of 17, `packages/contracts/src/environmentHttp.ts:109-127`); `traceId` |

Example 401:

```json
{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential","dpopFailureReason":"replay","traceId":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

- `traceId` is the server span's trace id, or `"unavailable"` (`apps/server/src/auth/http.ts:66-69`).
- The T3 Connect management routes (`/api/connect/*`) use a different, simpler family:
  `{_tag, message}` with 400, 401, 403, 409 or 500, and 503 `EnvironmentCloudEndpointUnavailableError`
  with `endpointRuntimeStatus` (`packages/contracts/src/environmentHttp.ts:259-332`,
  `apps/server/src/cloud/http.ts:33-106`).
- A request that fails schema decoding (bad params, headers or body) gets an **empty** 400
  (`.repos/effect-smol/packages/effect/src/http-api/HttpApiError.ts:470-505`). A wrong
  `Content-Type` gets 415 as plain text (1.7).
- Over the WebSocket, a missing scope fails that RPC with `EnvironmentAuthorizationError`
  `{_tag, message, requiredScope, requiredPermission?}`
  (`packages/contracts/src/auth.ts:409-416`, `packages/contracts/src/rpc.ts:1806-1809`,
  `apps/server/src/auth/RpcAuthorization.ts:222-226`). The socket stays open.

### 1.12 Other audiences (for completeness)

- **MCP OAuth** (agents not launched by T3) is a separate authorization-code + PKCE (S256) server
  for `/mcp` only:
  - Discovery and endpoints: `/.well-known/oauth-protected-resource[/mcp]`,
    `/.well-known/oauth-authorization-server`, `/oauth/mcp/register`, `/oauth/mcp/authorize`,
    `/oauth/mcp/approval`, `/oauth/mcp/decision`, `/oauth/mcp/token`
    (`packages/contracts/src/environmentHttp.ts:537-581`).
  - Codes live 60 s; redirect URIs are loopback or any https; issuer and resource come from the
    `Host` and `X-Forwarded-Proto` headers (`apps/server/src/auth/McpOAuth.ts:54-64`,
    `docs/internals/environment-auth.md:26-55`).
  - The resulting `mcp-client` sessions are rejected on every non-`/mcp` route. A native client
    has no use for this flow.
- **Reusable dev credential** (`T3CODE_DEV_AUTH_TOKEN`) applies only to `mode: web` with a dev URL
  (`apps/server/src/auth/ReusableDevAuth.ts:13-32`). Ignore it.

---

## 2. Pairing

Every pairing flow ends the same way. The client holds a **bootstrap credential** and exchanges it
at `POST /oauth/token` (1.7) for a session token, then uses that token for HTTP and for WebSocket
tickets. The flows differ only in how the credential and the base URL reach the client.

### 2.1 The one-time pairing credential

- It is a 12-character code (1.9) stored in `auth_pairing_links` with `method: "one-time-token"`,
  scopes, subject, optional label, optional proof-key thumbprint, and `expiresAt`
  (`apps/server/src/auth/PairingGrantStore.ts:398-453`).
- Redeeming it is an atomic `UPDATE … WHERE` over credential, thumbprint, scope overlap, and not
  expired, used or revoked (`apps/server/src/auth/PairingGrantStore.ts:559-586`).
- All rejection causes surface as one 401 `invalid_credential`. Server-side they are unknown,
  consumed, revoked, expired, or proof-key mismatch (`apps/server/src/auth/PairingGrantStore.ts:588-621`).
- Read models never include the secret. Only the creation response does
  (`docs/internals/environment-auth.md:16-19`, `packages/contracts/src/auth.ts:333-342`).

### 2.2 Accepted pairing input formats

The parser is `resolveRemotePairingTarget` (`packages/shared/src/remote.ts:188-245`). The token is
read from the **fragment** first and then from the query (`:144-152`).

| Input | Example | Resulting base URL |
| --- | --- | --- |
| Direct pairing URL (server and CLI output) | `http://192.168.1.5:3773/pair#token=ABCD2345EFGH` | origin of the URL (`ws:`/`wss:` mapped to `http:`/`https:`), path `/` |
| Legacy query form | `http://192.168.1.5:3773/pair?token=ABCD2345EFGH` | same (still accepted; never produced by current code) |
| Hosted pairing URL | `https://app.t3.codes/pair?host=https%3A%2F%2Fmac.tailnet.ts.net&label=Mac#token=ABCD2345EFGH` | `host` query param, normalized (`packages/shared/src/remote.ts:172-217`) |
| Manual host and code | host `mac.tailnet.ts.net`, code `ABCD2345EFGH` | `https://` is assumed when there is no scheme (`packages/shared/src/remote.ts:75-104,230-244`) |
| Mobile QR deep link | `t3code://…?pairingUrl=<url-encoded pairing URL>` | inner URL (`apps/mobile/src/features/connection/pairing.ts:73-92`); no producer of this form was found in the repo |

- The server's startup URL builder sets the path `/pair`, removes any `token` query, and puts
  `token=<credential>` in the fragment (`apps/server/src/auth/EnvironmentAuth.ts:1143-1153`). The
  same helper exists for clients (`packages/shared/src/remote.ts:165-170`).
- Mobile's manual-entry builder defaults to `http://` for IP literals and `https://` otherwise
  (`apps/mobile/src/features/connection/pairing.ts:6-43`). Web and the shared parser always default
  to `https://` (`packages/shared/src/remote.ts:85-87`).
- Supported schemes are `http:`, `https:`, `ws:` and `wss:` (`packages/shared/src/remote.ts:6,72-73`).
- Hosted pairing (`apps/web/src/hostedPairing.ts:53-87`):
  - The default hosted origin is `https://app.t3.codes` (`packages/shared/src/connectAuth.ts:15`; see
    section 4).
  - The fragment keeps the secret out of requests to the hosted origin. The hosted page exchanges
    it directly with the environment and strips it from history (`docs/internals/remote.md:65-69`).
  - The hosted web app can only reach HTTPS backends (`docs/user/remote-access.md:147-155`).
- **Native client handling**: accept all of the above. Strip the token before logging or
  persisting the URL (`stripPairingTokenFromUrl`, `packages/shared/src/remote.ts:154-163`). Register
  for no `t3code://` scheme (that scheme belongs to the official app; see section 6).

### 2.3 Flow: direct pairing (URL, QR or host plus code), the native client baseline

This is exactly what `preparePairingRegistration` does
(`packages/client-runtime/src/connection/onboarding.ts:107-155`).

```text
Native client                                         Environment (httpBaseUrl)
  | parse input -> {httpBaseUrl, wsBaseUrl, credential}       (packages/shared/src/remote.ts:188-245)
  |-- GET /.well-known/t3/environment ---------------------->|  (10 s timeout, client-runtime default)
  |<- 200 ExecutionEnvironmentDescriptor --------------------|
  |   if adding a route: descriptor.environmentId must equal the saved one, else stop
  |     WITHOUT redeeming the code (onboarding.ts:113-120)
  |   if orchestrationProtocolVersion (default 1) != 2: stop, unless the server is older and
  |     can self-update; then it is still saved so it can be updated (onboarding.ts:121-125,
  |     compatibility.ts:9-27)
  |-- POST /oauth/token  (form, no DPoP header) ------------->|
  |     grant_type=urn:ietf:params:oauth:grant-type:token-exchange
  |     subject_token=<code>
  |     subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap
  |     requested_token_type=urn:ietf:params:oauth:token-type:access_token
  |     client_label=<app name>&client_device_type=desktop&client_os=macOS
  |<- 200 {"access_token","token_type":"Bearer","expires_in":~2592000,"scope":"…"}
  |   persist route + token (2.10)
  |-- POST /api/auth/websocket-ticket  Authorization: Bearer <token> ->|
  |<- 200 {"ticket","expiresAt"} ----------------------------|
  |== GET <wsBaseUrl>/ws?wsTicket=…&orchestrationProtocol=2&clientSurface=desktop
  |      &clientAppVersion=…&clientDeviceType=desktop&clientOs=macOS&connectionMethod=direct ==>|
```

- Official client metadata (`client_label` / `clientSurface`):
  - Desktop: `T3 Code Desktop` / `desktop`.
  - Web: `T3 Code Web` / `web`.
  - Mobile: `T3 Code Mobile` / `mobile`.

  Sources: `apps/web/src/connection/clientMetadata.ts:72-97`, `apps/mobile/src/lib/authClientMetadata.ts:5-23`.
- Saved connection id is `bearer:<environmentId>:<httpBaseUrl origin>`. One bearer route per
  address, so pairing the same machine over another address adds a route instead of a second
  machine (`packages/client-runtime/src/connection/onboarding.ts:93-100`,
  `docs/user/remote-access.md:65-71`).
- Pairing the same environment again replaces the saved grant for that route. That is how a user
  changes permissions (`docs/user/remote-access.md:259-264`).

### 2.4 Flow: hosted pairing URL

Same as 2.3. The only extra step is to take `host` from the query, `label` (display hint) from the
query, and `token` from the fragment (`packages/shared/src/remote.ts:172-217`). The hosted page
itself never sees the token in a request.

### 2.5 Flow: desktop local bootstrap (desktop-managed local server)

The desktop main process generates the bootstrap secret, passes it to the server it spawns over a
private channel, and the renderer exchanges it. Details of spawning are in section 3.

- The server accepts a `desktopBootstrapToken`, seeded as an administrative grant with unlimited
  uses for 24 h, or a `desktopBootstrapSecret` (`apps/server/src/auth/PairingGrantStore.ts:327-351`).
- With a secret, valid tokens are `hex(HMAC-SHA256(secret, "t3-desktop-bootstrap:" + floor(nowMs / 43_200_000)))`
  for the previous, current or next 12 h window (`packages/shared/src/desktopBootstrapToken.ts:16-45`,
  `apps/server/src/auth/PairingGrantStore.ts:455-467`).
- The grant is administrative (all 16 grant scopes) with subject `desktop-bootstrap`.
- On exchange, earlier `desktop-bootstrap` sessions of the same method are revoked
  (`apps/server/src/auth/EnvironmentAuth.ts:919-921`). This matters to a third-party client: if it
  reused the official desktop's bootstrap channel it would log the desktop out. It cannot anyway,
  because the secret is never written where another process can read it (section 3).

### 2.6 Flow: `t3 pair`, `t3 auth pairing create`, startup URL

See section 3 for the CLI flags and output format.

- These mint the same one-time credential as 2.1 and print a direct pairing URL `…/pair#token=…`
  plus a QR code (`apps/server/src/cli/pair.ts:186`, `apps/server/src/startupAccess.ts:129`).
- `--scope` (repeatable) replaces the default standard scopes (`docs/user/remote-access.md:247-257`).
- At startup, a server that is not desktop-managed prints a pairing URL whose credential has
  subject `administrative-bootstrap` and the **administrative** scopes, valid 5 minutes
  (`apps/server/src/auth/EnvironmentAuth.ts:1086-1113,1143-1153`).

### 2.7 Flow: Tailscale

Tailscale only changes the address. The pairing URL uses `https://<machine>.<tailnet>.ts.net/`
(`docs/user/remote-access.md:119-145`). The server is reached through `tailscale serve`, which
terminates TLS and proxies to loopback. Section 3 has the flags. DPoP `htu` and MCP issuer URLs
depend on the proxy preserving `Host` and sending `X-Forwarded-Proto: https`
(`docs/internals/environment-auth.md:52-55`).

### 2.8 Flow: SSH (desktop-managed)

Desktop main launches or reuses a server over SSH, forwards a port, and pairs over the forward with
the same `/oauth/token` exchange (`apps/desktop/src/ipc/methods/sshEnvironment.ts:180-213`,
`docs/internals/remote.md:78-84`). Section 3 has the details.

### 2.9 Flow: T3 Connect

The relay asks the environment to mint a one-time credential bound to the client's DPoP key
thumbprint (2 min, standard scopes, subject `cloud-connect`). The client redeems it at `/oauth/token`
**with a DPoP proof** and receives a 1-hour `DPoP` token. Full sequence in section 4.

### 2.10 What a client must persist after pairing

The official runtime persists, per route (`packages/client-runtime/src/connection/onboarding.ts:139-154`):

- Profile (non-secret): `{connectionId, environmentId, label, httpBaseUrl, wsBaseUrl}`.
- Credential (secret): `{token}` (`BearerConnectionCredential`).

For T3 Connect it persists a `RemoteDpopAccessToken`
`{environmentId, accountId?, label, endpoint{httpBaseUrl, wsBaseUrl, providerKind}, accessToken, expiresAtEpochMs, dpopThumbprint}`
(`packages/client-runtime/src/authorization/tokenStore.ts:11-21`). It also caches relay DPoP access
tokens `{accountId, clientId, relayUrl, thumbprint, scopes, accessToken, expiresAtMillis}`
(`packages/client-runtime/src/relay/managedRelay.ts:227-241`).

Recommended Keychain mapping for the native client:

| Item | Keychain class | Notes |
| --- | --- | --- |
| Bearer session token per route | generic password; service `<app>.environment`, account `<connectionId>` | 30-day lifetime; delete on "forget environment" |
| DPoP environment access token | generic password, or memory only | 1 h lifetime; cheap to re-mint |
| DPoP private key | Secure Enclave key (`kSecAttrTokenIDSecureEnclave`), non-exporting | one per install; its thumbprint binds all T3 Connect credentials |
| Relay DPoP access token | memory or Keychain | re-exchangeable from the Clerk token |
| Clerk session / OAuth refresh token | generic password | see section 4 |

Never persist the pairing code. It is single-use and already spent.

<!-- SECTIONS 3-7 FOLLOW -->

## 4. T3 Connect end to end

<!-- 4.1-4.3 (identifiers, Clerk sign-in, native options) pending agent results -->

### 4.4 Relay HTTP API (contract)

Contract: `packages/contracts/src/relay.ts:956-1273` (`RelayApi`, OpenAPI title "T3 Code Relay
API" 1.0.0). Production base URL `https://relay.t3.codes` (`.env.example:22`). The client
normalizes the relay URL to its origin with no trailing slash
(`packages/shared/src/relayUrl.ts:1-18`). That origin is also the `resource` value in the token
exchange (`packages/client-runtime/src/relay/managedRelay.ts:436,508`).

| Method | Path | Auth | Request | Response | Used by clients? |
| --- | --- | --- | --- | --- | --- |
| GET | `/health` | none | | `{"ok":true,"service":"relay"}` | no |
| GET | `/.well-known/oauth-authorization-server` | none | | `{issuer, token_endpoint, grant_types_supported:[token-exchange], token_endpoint_auth_methods_supported:["none"], dpop_signing_alg_values_supported:["ES256"], scopes_supported}` | no |
| GET | `/.well-known/oauth-protected-resource` | none | | `{resource, authorization_servers, scopes_supported, dpop_bound_access_tokens_required, dpop_signing_alg_values_supported:["ES256"]}` | no |
| POST | `/v1/client/dpop-token` | `DPoP: <proof>` header; the Clerk token goes in the body | form (below) | `{access_token, issued_token_type, token_type:"DPoP", expires_in, scope}` | **yes** |
| GET | `/v1/environments` | `Authorization: Bearer <Clerk token>` | | `{"environments":[{environmentId,label,endpoint:{httpBaseUrl,wsBaseUrl,providerKind},linkedAt}]}` | **yes** |
| POST | `/v1/environments/:environmentId/status` | `Authorization: DPoP <relay AT>` + `DPoP` | no body | `RelayEnvironmentStatusResponse` | **yes** |
| POST | `/v1/environments/:environmentId/connect` | `Authorization: DPoP <relay AT>` + `DPoP` | `{"deviceId"?, "clientKeyThumbprint"?, "clientProofKeyThumbprint"?}` | `{environmentId, endpoint, credential, expiresAt}` | **yes** |
| POST | `/v1/client/environment-link-challenges` | Bearer Clerk | `{notificationsEnabled, liveActivitiesEnabled, managedTunnelsEnabled}` | `{challenge, expiresAt}` | when enabling T3 Connect on a host |
| POST | `/v1/client/environment-links` | Bearer Clerk | `{deviceId?, proof, notificationsEnabled, liveActivitiesEnabled, managedTunnelsEnabled}` | `{ok, cloudUserId, environmentId, endpoint, endpointRuntime\|null, relayIssuer, environmentCredential, cloudMintPublicKey}` | when enabling |
| DELETE | `/v1/client/environment-links/:environmentId` | Bearer Clerk | | `{ok}` | "Deregister" |
| DELETE | `/v1/client/environment-links/:environmentId/tunnel` | Bearer Clerk | | `{ok}` | environments on shutdown |
| GET | `/v1/client/devices` (legacy, iOS-only shape), `/v2/client/devices` | Bearer Clerk | | `{"devices":[RelayClientDeviceRecord]}` | device list UI |
| POST / GET / DELETE | `/v1/mobile/devices`, `/v1/mobile/live-activities`, `/v1/mobile/agent-activity`, `/v1/mobile/devices/:deviceId` | DPoP, scope `mobile:registration` | | | mobile push only |
| POST | `/v1/environments/:id/tunnel[/recovery]`, `/threads/:threadId/agent-activity`, `/link-preferences`, `/hooks/wake` | environment credential (Bearer) | | | environments only |
| any | `/v1/hooks/:endpointKey/:hookId/:token` | none (token in path) | raw | forwarded | webhooks only |

Relay DPoP access-token scopes are `environment:connect`, `environment:status` and
`mobile:registration` (`packages/contracts/src/relay.ts:733-741`). Public client ids are exactly
`t3-mobile` and `t3-web` (`packages/contracts/src/relay.ts:747-750`). Relay error bodies are listed
in 4.13.

`RelayEnvironmentStatusResponse` (`packages/contracts/src/relay.ts:823-844`):

```json
{
  "environmentId": "…",
  "endpoint": { "httpBaseUrl": "https://….", "wsBaseUrl": "wss://….", "providerKind": "cloudflare_tunnel" },
  "status": "online",
  "checkedAt": "2026-10-09T10:00:00.000Z",
  "descriptor": { "environmentId": "…", "label": "…", "…": "…" },
  "error": "only when offline",
  "offlineReason": "tunnel_released",
  "traceId": "…"
}
```

`status` is `online` or `offline`. `offlineReason` is either absent or `tunnel_released`.
`providerKind` is one of `manual`, `cloudflare_tunnel`, `t3_relay`
(`packages/contracts/src/relay.ts:158-170`).

<!-- 4.5 relay DPoP token exchange (client side verified; relay-side validation pending) -->

### 4.6 Listing environments and showing their state

The shared discovery service (`packages/client-runtime/src/relay/discovery.ts:103-347`) works as
follows:

1. Get the Clerk token. A signed-out session is an idle state, not an error (`:226-241`).
2. `GET /v1/environments` with `Authorization: Bearer <Clerk token>` (`:256-258`).
3. For each environment, concurrently, `POST /v1/environments/:id/status` with a relay DPoP token
   requested with scopes `environment:status environment:connect` (`:152-162`).
4. Validate each status: `environmentId`, `endpoint` (all three fields) and `descriptor.environmentId`
   must match the listing, otherwise it is an error (`:56-91`).
5. Per-environment `availability` is `checking`, then `online` or `offline` (from the relay), or
   `error` if the status request failed (`:25`, `:164-203`).
6. Re-run when the network comes back and when credentials change (sign-in, sign-out, account
   switch). An account change bumps a generation so stale results are dropped (`:307-344`).

A second query layer used by the account screens caches these queries for 15 s and drops idle
ones after 5 min. It caches the Clerk token until 5 s before its JWT `exp`
(`packages/client-runtime/src/relay/managedRelayState.ts:24-26,78-120,313-433`). The account id is
the Clerk JWT `sub` (`packages/client-runtime/src/relay/managedRelay.ts:385-393`).

User-facing strings (`packages/client-runtime/src/relay/errorPresentation.ts:24-84`):

- Offline with `offlineReason: "tunnel_released"`: "Offline for a while, so its T3 Connect tunnel
  was removed. Start T3 Code on that computer and update it to the latest version to reconnect."
- `RelayEnvironmentConnectNotAuthorizedError` with reason `environment_link_not_found`: "Relay has
  no active link for this environment. The environment server may not have re-established its link
  yet." Other reasons read "Relay rejected the environment connection request (<reason>)."
- `RelayAuthInvalidError` `missing_bearer` or `invalid_bearer`: "Relay rejected the cloud session
  token."
- `RelayAuthInvalidError` `invalid_dpop`: "Relay rejected the DPoP proof." plus a hint. For
  `time_window` the hint is "Hint: Check that automatic date and time is enabled on both devices,
  then try again."

<!-- 4.6b presentation details from web/mobile UI pending agent results -->

### 4.7 Connecting: relay connect, then environment token exchange, then socket

This is the exact sequence the shared runtime runs
(`packages/client-runtime/src/authorization/service.ts:248-337,425-511`,
`packages/client-runtime/src/relay/managedRelay.ts:484-639,812-843`):

```text
Client                         Relay (https://relay.t3.codes)        Environment (tunnel https://<host>)
  | clerkJwt = Clerk getToken({template:"t3-relay", skipCache:true})
  | key = per-install P-256 DPoP key; jkt = thumbprint(key)
  |
  |-- POST /v1/client/dpop-token ------------------------>|
  |   DPoP: proof{htm:POST, htu:https://relay.t3.codes/v1/client/dpop-token}   (no ath)
  |   Content-Type: application/x-www-form-urlencoded
  |   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
  |   subject_token=<clerkJwt>
  |   subject_token_type=urn:ietf:params:oauth:token-type:jwt
  |   requested_token_type=urn:ietf:params:oauth:token-type:access_token
  |   resource=https://relay.t3.codes
  |   scope=environment:connect            (status uses "environment:status environment:connect")
  |   client_id=t3-web | t3-mobile
  |<-- {access_token:RAT, token_type:"DPoP", expires_in, scope} -|
  |   (client rejects the response unless scope equals the requested set: managedRelay.ts:517-522)
  |
  |-- POST /v1/environments/{id}/connect ---------------->|
  |   Authorization: DPoP RAT
  |   DPoP: proof{htm:POST, htu:…/v1/environments/{id}/connect, ath:b64url(sha256(RAT))}
  |   {"deviceId":"<optional>","clientKeyThumbprint":"<jkt>"}
  |                                         |-- POST /api/t3-connect/mint-credential -->|
  |                                         |   {"proof":"<Ed25519 JWT typ t3-cloud-mint+jwt>"}
  |                                         |<-- {credential, expiresAt, proof(t3-env-mint+jwt)}
  |<-- {environmentId, endpoint{httpBaseUrl,wsBaseUrl,providerKind}, credential, expiresAt}
  |   check environmentId == id (service.ts:268-273)
  |
  |-- GET {httpBaseUrl}/.well-known/t3/environment ---------------------------------------->|
  |<-- descriptor; check descriptor.environmentId == id (service.ts:289-298) ----------------|
  |-- POST {httpBaseUrl}/oauth/token ------------------------------------------------------->|
  |   DPoP: proof{htm:POST, htu:{httpBaseUrl}oauth/token}   (no ath)
  |   form: grant_type=…token-exchange, subject_token=<credential>,
  |         subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap,
  |         requested_token_type=…access_token, client_label, client_device_type, client_os
  |<-- {access_token:EAT, token_type:"DPoP", expires_in:3600, scope:"<13 standard scopes>"} -|
  |
  |-- POST {httpBaseUrl}/api/auth/websocket-ticket ---------------------------------------->|
  |   Authorization: DPoP EAT;  DPoP: proof{POST, …/api/auth/websocket-ticket, ath(EAT)}
  |<-- {ticket, expiresAt} -----------------------------------------------------------------|
  |== {wsBaseUrl}ws?wsTicket=…&orchestrationProtocol=2&connectionMethod=relay&client… ======>|
  |
  |   every later HTTP call: Authorization: DPoP EAT + fresh proof (htu = that URL, ath(EAT))
```

Notes:

- The connect body uses the deprecated alias `clientKeyThumbprint`, not
  `clientProofKeyThumbprint` (`packages/client-runtime/src/relay/managedRelay.ts:824-827`,
  `packages/contracts/src/relay.ts:714-731`). The relay error `client_proof_key_thumbprint_missing`
  exists (`packages/contracts/src/relay.ts:454-463`). Send the thumbprint; relay-side handling is
  in 4.5.
- `deviceId` is optional. Mobile sends its agent-awareness device id
  (`packages/client-runtime/src/authorization/service.ts:255-267`).
- The minted credential is valid for 2 minutes and once. It is bound to `jkt`
  (`apps/server/src/cloud/CloudLink.ts:1622-1628`). Exchange it immediately with the **same key**.
- Relay requests time out after 10 s (`packages/client-runtime/src/relay/managedRelay.ts:225,336-362`).
  Environment requests also time out after 10 s (`packages/client-runtime/src/authorization/remote.ts:25`).
  The whole DPoP authorization times out after 30 s (`packages/client-runtime/src/authorization/service.ts:89`).
- The relay token cache is keyed by `{accountId, clientId, relayUrl, thumbprint}`. A cached token
  serves any request whose scopes are a subset, and is used until 5 s before expiry. On
  `RelayAuthInvalidError` `invalid_bearer` the client drops the token and retries **once** with a
  fresh exchange (`packages/client-runtime/src/relay/managedRelay.ts:364-383,527-692`).
- The environment DPoP token is cached per environment, keyed by account and thumbprint. It is
  renewed 60 s before expiry (`DPOP_ACCESS_TOKEN_REFRESH_SKEW_MS`,
  `packages/client-runtime/src/connection/model.ts:108`,
  `packages/client-runtime/src/authorization/service.ts:369-385`). Concurrent callers share one
  pending renewal (`:394-466`). A Clerk account change invalidates everything, with the error
  "Your cloud sign-in changed. Sign in again to authorize the environment." (`:225-238`).
- If a cached token fails to get a WebSocket ticket within 3 s, it is replaced by a fresh
  relay-minted one, unless the failure is a non-auth failure on a direct route
  (`packages/client-runtime/src/authorization/service.ts:479-501`).
- For HTTP calls, an `EnvironmentAuthInvalidError` with reason `invalid_credential` triggers exactly
  one renewal and retry with a new proof (`packages/client-runtime/src/state/environmentHttpAuth.ts:148-207`).

### 4.8 What the environment verifies on mint and health

Neither `POST /api/t3-connect/mint-credential` (or the legacy `POST /api/connect/mint-credential`)
nor `POST /api/t3-connect/health` uses session auth. Each takes a relay-signed JWT
(`packages/contracts/src/environmentHttp.ts:715-735`, `apps/server/src/cloud/http.ts:143-159`).
Verification (`apps/server/src/cloud/CloudLink.ts:1449-1660`):

- Signature: EdDSA (Ed25519) with the `cloudMintPublicKey` received at link time
  (`apps/server/src/cloud/CloudLink.ts:140`, `packages/shared/src/relayJwt.ts:62-86`).
- `typ`: `t3-cloud-mint+jwt` or `t3-cloud-health+jwt` (`packages/shared/src/relayJwt.ts:7-14`).
- `iss` is the relay issuer. `aud` is `t3-env:<environmentId>`. `sub` is the linked Clerk user id.
- The JWT lifetime must be at most 5 min, with 60 s skew (`apps/server/src/cloud/linkChecks.ts:129-139`).
- `scope` is exactly `["environment:connect"]` or `["environment:status"]`
  (`apps/server/src/cloud/linkChecks.ts:122-127`).
- For mint, `cnf.jkt` must equal `clientProofKeyThumbprint`.
- Replay guards: one-time secret-store markers per `jti` and per `nonce`
  (`apps/server/src/cloud/CloudLink.ts:123-134,1504-1511,1607-1616`).
- On mint, the environment issues the pairing credential (standard scopes, subject
  `cloud-connect`, TTL 2 min, label "T3 Connect connect", bound to the client thumbprint). It
  answers with an Ed25519-signed `t3-env-mint+jwt` that binds `requestNonce`,
  `clientProofKeyThumbprint` and `credential` (`apps/server/src/cloud/CloudLink.ts:1617-1655`).
- Health answers `status:"online"` with the descriptor, signed as `t3-env-health+jwt`
  (`apps/server/src/cloud/CloudLink.ts:1513-1547`).
- Rejections map to 401 (`CloudLinkProofRejectedError`) and 409 (`CloudLinkProofReplayedError`)
  (`apps/server/src/cloud/http.ts:60-72`).
- A T3 Connect session therefore holds **at most** the 13 standard scopes: no `access:*` and no
  `relay:write`. A T3 Connect client cannot manage pairing or link settings on that environment.

### 4.9 Renewal, expiry and learned routes

- The environment closes a DPoP socket when its 1-hour session expires (1.8). The runtime has to
  reconnect, which re-runs 4.7 (usually from the cached relay token) and needs no user action.
- HTTP requests renew the token without touching a healthy socket
  (`docs/internals/connection-runtime.md:34-41`, `docs/user/remote-access.md:28-31`).
- A learned direct route (LAN or tailnet address reported by the host) reuses the T3 Connect
  access token. The token is not origin-bound, and each proof names its own URL, so the client
  signs proofs for `http://<lan-ip>:<port>/…` with the same key (`docs/internals/remote.md:46-53`,
  `packages/client-runtime/src/authorization/service.ts:72-80,466-478`). Before any credential goes
  to a direct address, the client fetches the public descriptor there and requires the same
  `environmentId` (`packages/client-runtime/src/authorization/service.ts:142-181`).

### 4.10 Enabling T3 Connect on a host ("link")

Run from a client on the host itself. The link-proof request must arrive over loopback, without
forwarded authority headers, and its `origin.localHttpPort` must equal the request port
(`apps/server/src/cloud/CloudLink.ts:628-686`, `apps/server/src/cloud/linkChecks.ts:47-101`). It
requires `relay:write` on the environment (`apps/server/src/cloud/http.ts:114-142`). Standard
pairings lack it; administrative ones (desktop bootstrap, startup URL, `t3 auth session issue`)
have it.

```text
Client (on host)                        Relay                          Environment (http://127.0.0.1:<port>)
  |-- POST /v1/client/environment-link-challenges (Bearer Clerk) ->|
  |   {notificationsEnabled:true, liveActivitiesEnabled, managedTunnelsEnabled:true}
  |<-- {challenge, expiresAt} ------------------|
  |-- POST /api/connect/link-proof (relay:write) ------------------------------------------>|
  |   {challenge, relayIssuer:"https://relay.t3.codes",
  |    endpoint:{httpBaseUrl, wsBaseUrl, providerKind:"cloudflare_tunnel"},
  |    origin:{localHttpHost:"127.0.0.1", localHttpPort:<port>}}
  |<-- "<Ed25519 JWT typ t3-env-link+jwt>"  (5 min; claims in packages/contracts/src/relay.ts:290-300)
  |-- POST /v1/client/environment-links (Bearer Clerk) ->|
  |   {deviceId?, proof, notificationsEnabled, liveActivitiesEnabled, managedTunnelsEnabled}
  |<-- {ok, cloudUserId, environmentId, endpoint, endpointRuntime, relayIssuer,
  |     environmentCredential, cloudMintPublicKey} --|
  |   check environmentId and endpoint.providerKind
  |-- POST /api/connect/relay-config (relay:write) ----------------------------------------->|
  |   {relayUrl, relayIssuer, cloudUserId, environmentCredential, cloudMintPublicKey, endpointRuntime}
  |<-- {ok, endpointRuntimeStatus}  (503 EnvironmentCloudEndpointUnavailableError if the tunnel cannot start)
```

Sources: `apps/web/src/cloud/linkEnvironment.ts:258-349`,
`apps/mobile/src/features/cloud/linkEnvironment.ts:157-240`.

- `publish_only` mode uses `providerKind: "manual"` and `managedTunnelsEnabled: false`
  (`apps/web/src/cloud/linkEnvironment.ts:250-280`).
- Related environment routes:
  - `GET /api/connect/link-state` (`relay:read`) returns
    `{linked, cloudUserId, relayUrl, relayIssuer, managedTunnelActive?, publishAgentActivity, holdWebhooksWhileOffline?}`
    (`packages/contracts/src/environmentHttp.ts:410-425`).
  - `POST /api/connect/preferences` (`relay:write`).
  - `POST /api/connect/unlink` (`relay:write`).
- Unlink from a client is local `POST /api/connect/unlink` followed by a best-effort relay
  `DELETE /v1/client/environment-links/:id` (`apps/web/src/cloud/linkEnvironment.ts:218-248`).
- "Deregister" from the account page calls only the relay DELETE, so it works while the host is
  offline (`packages/client-runtime/src/relay/managedRelayState.ts:191-209`,
  `docs/user/remote-access.md:287-291`).

### 4.13 Relay errors as clients see them

Every relay error is a `Schema.TaggedError` JSON body with `_tag`, `code`, `traceId` and, where
applicable, a `reason` (`packages/contracts/src/relay.ts:392-608`).

| Status | `_tag` / `code` | `reason` values | Client classification (`packages/client-runtime/src/connection/errors.ts:37-113`) |
| --- | --- | --- | --- |
| 401 | `RelayAuthInvalidError` / `auth_invalid` | `missing_bearer`, `invalid_bearer`, `invalid_dpop` (+`dpopFailureReason`), `not_authorized` | blocked: authentication |
| 403 | `RelayEnvironmentConnectNotAuthorizedError` / `environment_connect_not_authorized` | `client_proof_key_thumbprint_missing`, `environment_link_not_found`, `endpoint_provider_not_managed`, `managed_endpoint_allocation_not_found`, `managed_endpoint_base_domain_not_configured`, `managed_endpoint_allocation_not_ready`, `managed_endpoint_hostname_invalid`, `managed_endpoint_mismatch` (optional) | blocked: permission |
| 502 | `RelayEnvironmentEndpointUnavailableError` / `environment_endpoint_unavailable` | `endpoint_request_failed`, `endpoint_response_invalid` | transient: endpoint-unavailable |
| 504 | `RelayEnvironmentEndpointTimedOutError` / `environment_endpoint_timed_out` | | transient: timeout |
| 401 | `RelayEnvironmentLinkProofExpiredError` / `environment_link_proof_expired` | | blocked: authentication |
| 400 | `RelayEnvironmentLinkProofInvalidError` / `environment_link_proof_invalid` | `invalid_signature_or_scope`, `descriptor_mismatch`, `replayed_nonce`, `challenge_invalid`, `origin_not_allowed`, `endpoint_not_secure` | blocked: permission |
| 403 | `RelayEnvironmentLinkLimitExceededError` / `environment_link_limit_exceeded` | `maxTunnels: number` | blocked: permission |
| 500 | `RelayEnvironmentLinkFailedError` / `environment_link_failed` | `link_persistence_failed`, `credential_persistence_failed`, `replay_persistence_failed`, `internal_error` | transient: relay-unavailable |
| 503 | `RelayEnvironmentLinkUnavailableError` / `environment_link_unavailable` | `managed_endpoint_not_configured`, `managed_endpoint_provisioning_failed` | transient: endpoint-unavailable |
| 500 | `RelayInternalError` / `internal_error` | `database_unavailable`, `persistence_failed`, `upstream_unavailable`, `internal_error` | transient: relay-unavailable |

Client-side failures map as follows (`packages/client-runtime/src/connection/errors.ts:79-113`):

- A relay request timeout (10 s) is transient: timeout.
- A transport failure is transient: relay-unavailable, with the hint "Your DNS or firewall may be
  blocking T3 Connect. Try another network, such as a phone hotspot."
  (`packages/client-runtime/src/errors/network.ts:3-4`).
- A granted relay scope that differs from the request is blocked: permission.
- A DPoP key or proof failure is blocked: authentication.
- Environment `EnvironmentAuthInvalidError` on the DPoP path is blocked: authentication, with the
  clock or retry hint (`packages/client-runtime/src/connection/errors.ts:181-192`).

<!-- SECTION 4 relay-internal and Clerk details to be merged; sections 3, 5, 6, 7 follow -->

## 6. Security constraints and client identification

### 6.1 Constraints from code or docs that a third-party client must respect

1. **Never put long-lived tokens in URLs.**
   - Sockets use a 5-minute `wsTicket` minted over authenticated HTTP
     (`docs/internals/environment-auth.md:57-59`).
   - Media and streaming routes accept the same `wsTicket` query parameter when a header cannot be
     set (`apps/server/src/auth/http.ts:158-186`):
     - `/api/preview-stream/*` (`apps/server/src/preview/ServerBrowserStream.ts:28,72,217,241`)
     - `/api/device-hub/*` (`apps/server/src/device/DeviceHubProxy.ts:171,197`,
       `apps/server/src/device/DeviceService.ts:73`)
   - Pairing secrets travel only in the URL **fragment** (`#token=`)
     (`apps/server/src/auth/EnvironmentAuth.ts:1143-1153`, `docs/internals/remote.md:65-69`).
   - Strip the token from any URL you display, store or log (`packages/shared/src/remote.ts:154-163`).
2. **Treat pairing URLs, codes and signed URLs as passwords.** Never put them in screenshots, logs
   or bug reports (`docs/user/remote-access.md:308-309`). Signed asset URLs
   (`/api/assets/*`, `apps/server/src/assets/AssetAccess.ts:62`) and attachment upload URLs
   (`/api/attachments/upload/*`, `apps/server/src/assets/AttachmentUpload.ts:35`) are bearer
   capabilities. They stay valid after the minting session is revoked, until they expire
   (`docs/internals/environment-auth.md:111-120`). Share the authored file reference, not the URL.
3. **Do not let cookies override `Authorization`.**
   - The server prefers a cookie over a bearer or DPoP header (1.5).
   - A `URLSession` with a shared `HTTPCookieStorage` would store the cookie set by
     `/api/auth/browser-session` or by the legacy-cookie path of `/api/auth/session`
     (`apps/server/src/auth/http.ts:270-297`), then silently authenticate as that cookie session.
   - Use an ephemeral configuration, or set `httpShouldSetCookies = false` and
     `httpCookieAcceptPolicy = .never`.
4. **Verify identity before sending a credential.** Before using a direct route, fetch
   `/.well-known/t3/environment` there and require the saved `environmentId`
   (`packages/client-runtime/src/authorization/service.ts:142-181`). Do this before redeeming a
   pairing code when adding a route (`packages/client-runtime/src/connection/onboarding.ts:113-120`).
   A LAN address can belong to another machine on another network (`docs/internals/remote.md:31-37`).
5. **Never fall back to loopback.** A host's loopback address means a different machine on another
   device. "Endpoint selection must not silently fall back to loopback when a shareable endpoint is
   unavailable" (`docs/internals/remote.md:26-29`).
6. **DPoP hygiene.**
   - Use one non-exportable P-256 key per install (Secure Enclave recommended).
   - Give every request a fresh `jti`, because replays are rejected (1.6).
   - Build `htu` from the exact scheme, host, port and path you request.
   - Include `ath` on every request that carries an access token.
   - Never retry with the same proof.
   - Keep the clock correct. Proofs are rejected when `iat` is more than 5 s in the future or more
     than 300 s old (`packages/shared/src/dpop.ts:178-188`). Official clients tell the user to check
     automatic date and time (`packages/client-runtime/src/relay/errorPresentation.ts:4-17`).
   - Use the T3 Connect token only with the DPoP scheme. The server does not fall back to bearer
     (`apps/server/src/auth/EnvironmentAuth.ts:736-764`).
7. **Bind and check results.** Reject a relay connect response whose `environmentId` differs from
   the one requested. Fetch the descriptor at the returned `httpBaseUrl` and check the id again
   before redeeming (`packages/client-runtime/src/authorization/service.ts:268-298`). When adding a
   route, never save a pairing that reached a different environment
   (`packages/client-runtime/src/connection/onboarding.ts:101-120`). Validate that status responses
   match the listing (4.6).
8. **Scope expectations.**
   - T3 Connect sessions never carry `access:*` or `relay:write` (4.8).
   - Paired sessions carry what the link granted. Read `permissions`, not `scopes` (1.4).
   - Do not offer actions the grant lacks. The server refuses them anyway, with
     `insufficient_scope` or `EnvironmentAuthorizationError`.
9. **Send the required protocol markers.**
   - `orchestrationProtocol=2` on `/ws`. Without it the server answers 426
     (`apps/server/src/ws.ts:3140-3149`).
   - Header `x-t3-orchestration-protocol: 2` on every `/api/orchestration/*` HTTP request. It is a
     required literal in the endpoint schema, so a missing or wrong header is a schema failure: an
     empty 400 (`packages/contracts/src/environmentHttp.ts:80-84,608-641`,
     `packages/client-runtime/src/state/environmentHttpAuth.ts:27-36`).
   - Other routes only take `authorization` and `dpop`.
10. **Respect the content types.** `/oauth/token` and the relay `/v1/client/dpop-token` are
    `application/x-www-form-urlencoded`. Everything else with a body is JSON. A wrong type gives 415
    (1.7).
11. **No refresh tokens, and no silent widening.**
    - Renew a DPoP token only through the relay flow. Re-pair to renew or change a bearer grant.
    - Never store more scope than was granted. "Stored credentials are never expanded when scopes
      split" (`docs/internals/environment-auth.md:64-67`).
12. **Forgetting is local.** There is no self-revocation endpoint (1.10). "Forget environment"
    should delete the Keychain items. If the app also holds `access:write` on that host, it may
    revoke its own session from another session; a session cannot revoke itself
    (`apps/server/src/auth/EnvironmentAuth.ts:1127-1134`).
13. **Relay-facing rules** (relay internals in 4.5): call only the documented client endpoints, use
    an allowed `client_id`, never follow redirects to arbitrary hosts, and treat
    `environment_link_not_found` as a host state, not a credential problem
    (`packages/client-runtime/src/relay/errorPresentation.ts:40-48`).

### 6.2 Client identification

What the official clients send. None of it is required for authorization except the protocol
markers above and the relay `client_id`.

| Where | Field | Desktop (official) | Suggested for the native app | Checked? |
| --- | --- | --- | --- | --- |
| `/oauth/token` form | `client_label` | `T3 Code Desktop` | your app name | display only; a link label overrides it (1.7) |
| `/oauth/token` form | `client_device_type` | `desktop` | `desktop` | display only (`apps/server/src/auth/utils.ts:182-198`) |
| `/oauth/token` form | `client_os` | `macOS` | `macOS` | display only |
| `/ws` query | `clientSurface` | `desktop` | `desktop` (allowed: `web`, `desktop`, `mobile`, `cli`) | recorded in the session row and analytics; invalid values dropped (`apps/server/src/ws.ts:620-637`) |
| `/ws` query | `clientAppVersion` | app version (omitted for `0.0.0`) | your version, at most 64 chars | recorded |
| `/ws` query | `clientDeviceType`, `clientOs` | `desktop`, `macOS` | same | analytics |
| `/ws` query | `connectionMethod` | `direct` / `ssh` / `relay` | per route | analytics |
| Relay token exchange | `client_id` | `t3-web` (desktop renderer is the web app: `apps/web/src/cloud/managedRelayLayer.ts:79-82`) | see 4.5 | **validated by the relay** |
| HTTP | `User-Agent` | Electron/Chrome UA | your own | parsed only to infer device, OS and browser when not presented (`apps/server/src/auth/utils.ts:122-165`) |
| HTTP | `traceparent` / `b3` | sent by Effect's HTTP client (assumed; **UNVERIFIED** that it is on by default) | optional | if present on T3 Connect requests, the server continues that trace and samples per its flag (`apps/server/src/cloud/traceRelayRequest.ts:25-63`) |
| HTTP | `Origin` | browser-set | omit | the server uses wildcard CORS outside dev and never checks `Origin` (`apps/server/src/http.ts:239-262`, `apps/server/src/httpCors.ts:3-11`) |

Allowed CORS request headers (relevant only to browsers): `authorization`, `b3`, `traceparent`,
`content-type`, `dpop`, `x-t3-orchestration-protocol`. Methods: `GET`, `POST`, `OPTIONS`
(`apps/server/src/httpCors.ts:3-11`).

<!-- 6.3 relay/Clerk-specific identification requirements pending -->
