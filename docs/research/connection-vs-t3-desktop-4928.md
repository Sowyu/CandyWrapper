# CandyWrapper's connection against T3 desktop at Nightly 4928

The user said the connection "just isn't as good as T3 desktop". This compares every part of the connection with T3's client at tag `v0.1.11-nightly.20261119.4928`, measures both against the sandboxes, and lists what the connection task fixed (branch `connection`, 2026-11-19).

T3 paths are under `~/CandyWrapper-research/t3code`. `client-runtime/` means `packages/client-runtime/src/`. CandyWrapper paths are under `Packages/CandyKit/Sources/` unless they start with `App/`. Line numbers are after this task's changes.

## Summary

On loopback, a cold connect, a thread open and streaming were already as fast as T3's. CandyWrapper fell behind when a socket died without a close: on a network change, after sleep, or when a remote host stopped answering. It then took 16 to 28 s to come back, or never came back while idle. T3 comes back in about 1 to 15 s. Two reasons were measured:

1. A probe waited out its whole deadline, 3 s or 15 s, because CandyWrapper had no way to tell a dead socket from a slow one. T3 reads the host's descriptor over a fresh request after 500 ms and replaces a silent socket at once.
2. The reconnect then sent its descriptor and ticket requests on pooled HTTP connections that had died with the socket, and waited out the 10 s HTTP timeout before backing off.

On T3 Connect, a relay socket dropped every hour, because CandyWrapper renewed its one-hour token only when an HTTP call needed one. All three are fixed.

Gaps ranked by how much the user would feel them:

| Rank | Gap | Before | T3 4928 | Now |
|---|---|---|---|---|
| 1 | A socket dies silently (Wi-Fi change, VPN drop, remote host asleep) and a signal arrives | 16 to 28 s to reconnect | about 1 to 3 s on LAN, 15 s worst case | 0.56 s for wake, path change and Reconnect, 2.6 s for app activation |
| 2 | The same while a turn streams | over 30 s | at most 15 s | 15.1 s |
| 3 | The same while idle with no signal | never noticed | at most 15 s (5 s pings) | never noticed, by design |
| 4 | T3 Connect socket at the token's hour | drops and reconnects every hour | renewed in place | renewed in place |
| 5 | A message the host never answers | spins forever | fails after 60 s | fails after 60 s |
| 6 | A big frame on a slow link trips the 15 s liveness check and loops | yes | fixed with frame parts | fixed with frame parts |
| 7 | Cold connect: the shell loads after the socket and the config | 27 ms loopback | 21 ms | 20 ms with the early load |
| 8 | A busy host misses one foreground probe | drops a live session | asks again | asks again |
| 9 | Thread history of finished runs (`deferWork`) | full work rows | folded, loaded on demand | not ported |
| 10 | Shell and thread resubscribe on app activation | no | yes | not ported |
| 11 | T3 Connect rechecks for a better route every 60 s while on a fallback | no | yes | not ported |

## How this was measured

`scripts/connection-timing/run` drives `ConnectionTimingTests` (in `Tests/T3ClientTests`) with no window. It uses CandyWrapper's own `EnvironmentHTTP`, `URLSessionRPCSocket`, `RPCConnection` and `ConnectionSupervisor`. ShellSession and ThreadSession live in the app target, which tests can't import, so the harness repeats their request order: ShellSession.prepareShell for the shell and ThreadSession's subscription (App/Sources/ThreadSession.swift:130) for a thread. `freeze-proxy.py` sits between the client and a private 4928 server. Writing `freeze` stops forwarding on every open TCP connection without closing it, which is what a dead Wi-Fi or a sleeping host does. New connections still pass.

T3's own client-runtime needs its Effect workspace installed, and this Mac has none, so I didn't run it. `scripts/connection-timing/t3-wire.mjs` replays T3's desktop sequence on the wire with node's fetch and WebSocket, step by step from the source it cites. It measures T3's request order and bytes. It doesn't measure T3's reconnect logic, so those rows come from the source.

Servers: the shared 3824 sandbox (47391, empty), the shared 4928 sandbox (47392, one thread), and my own 4928 server on 47411. That one was copied from the stopped reference sandbox and has 13 threads. I gave one thread 4 more haiku turns (4 of the 8 allowed), which made it the "long" thread: 71 KB bounded snapshot, 19.8 KB gzipped. The short thread is 1.3 KB. Medians of 5 runs on loopback, in milliseconds from the start of the connect.

### Cold connect, 4928 sandbox on 47411 (25 KB shell)

| Step | CandyWrapper before | CandyWrapper with early shell | T3 sequence (node) |
|---|---|---|---|
| Descriptor | 2.1 | 1.9 | 2.2 |
| Ticket | 3.9 | 2.8 | 3.5 |
| Socket open | 6.3 | 5.1 | 7.3 |
| Config snapshot | 15.8 | 15.0 | 18.0 |
| HTTP shell done | 22.0 | 15.0 | 14.4 |
| Shell synchronized | 27.3 | 19.1 | 21.5 |

On 47392: CandyWrapper 21.6 before and 16.1 with the early load, T3 21.3. On 3824 (47391): 18.1 and 20.0, where the descriptor names no shell flags and the early load does nothing. Each connect makes 3 HTTP requests (descriptor, ticket, shell) and 2 RPC subscriptions (config, shell) before the sidebar is live, in both clients. Bytes are the same too: about 98 KB of config over the socket, which Chromium and URLSession both compress (the server enables permessage-deflate, apps/server/src/server.ts:388-392, and URLSession offers it, checked with a header dump). The shell is 25 KB, or 2.7 KB gzipped, over HTTP, plus 0.7 to 1 KB of shell stream. The early load saves one HTTP round trip after the config. On loopback that is 5 to 8 ms. Over a relay at 100 ms RTT it should save about 100 ms plus the shell's transfer time, but I didn't measure that.

The 4928 config flags `providerCatalogsOnDemand`, `providerCatalogDigests` and `providerStatusDeltas` halve the config snapshot (98 KB to 49 KB, 8.2 to 6.2 ms). Only T3 mobile sends them (apps/mobile/src/connection/runtime.ts:39-45). The desktop and web runtime sends `environmentThemes`, `usageLimitSources` and `usageLimitsCommand` (apps/web/src/connection/runtime.ts:35-41), which is exactly what CandyWrapper sends (T3Client/ServerConfigFeed.swift:38-55). So on config bandwidth CandyWrapper is equal to the desktop app.

### Thread open, 47411

| Thread | CandyWrapper HTTP + subscribe | CandyWrapper socket only | T3 sequence (node) |
|---|---|---|---|
| Short, 1.3 KB | 6.3 | 4.7 | 6.9 |
| Long, 71 KB (19.8 KB on the wire) | 16.4 | 9.1 | 11.4 |

`deferWork=1` made no difference on these threads, because none has a work group over 150 rows (`THREAD_HISTORY_INLINE_WORK_ITEM_LIMIT`, apps/server/src/orchestration-v2/threadHistoryPaging.ts:23). It matters for threads with long tool runs. Loopback can't show the gain of HTTP's gzip. On a relay the long thread is 19.8 KB over HTTP against 71 KB over the socket without compression. With permessage-deflate on the socket the two are close.

### Reconnect after the server is killed and restarted

The harness stays connected 31 s, so the ladder resets, then sends SIGTERM to my 47411 server and starts it again. It times from the moment the descriptor answers to the shell stream's next `synchronized`. The server took about 1.2 s to come back.

| | Close noticed | Ready to synchronized |
|---|---|---|
| CandyWrapper before | 5 to 14 ms | 300, 885 and 6,254 ms (runs less than 30 s apart, so the ladder climbed) |
| CandyWrapper now, 5 runs 31 s apart | 6 to 13 ms | 131, 144, 526, 662 and 798 ms; median 526, always the third attempt |
| T3 (from the source) | immediate | first retry at 125 to 250 ms fails, the next waits 2 to 4 s |

The server answered its descriptor 1.1 to 1.8 s after the kill. A restarting server refuses connections, and the close is seen at once in every client. Before, the first retry came 1 to 2 s after the loss. T3 retries after 125 to 250 ms but counts that try, so when the server is still down its next try comes 2 to 4 s later (client-runtime/connection/supervisor.ts:1286-1298). CandyWrapper now makes the quick retry and doesn't count it, so the next try is on the first rung, 1 to 2 s. That lands within 0.8 s of the server being ready. Before, a first retry that came too early fell to the 2 to 4 s rung about one time in six; T3 lands there whenever the server needs more than 250 ms.

### Half-open socket

The harness freezes the proxy, sends one signal, and records when the supervisor drops the socket and when a new session is up. The limit is 30 s.

| Signal | Before: noticed, reconnected | Now: noticed, reconnected | T3 (from the source) |
|---|---|---|---|
| None, idle | never | never | 5 s pings, dropped within 15 s |
| A turn running (`setExpectingTraffic`) | 14.9 s, not within 30 s | 14.9 s, 15.1 s | within 15 s |
| App activation | 15.0 s, 28.0 s | 2.5 s, 2.6 s | 15 s probe, one miss tolerated; pings already caught it |
| System wake | 3.0 s, 16.9 s | 0.54 s, 0.57 s | no wake signal on desktop |
| Network path change | 3.0 s, 15.8 s | 0.54 s, 0.56 s | silent socket check: about 0.5 to 1 s on LAN, 2.5 s remote |
| Reconnect button | 3.0 s, 16.5 s | 0.54 s, 0.54 s | the same |

## Behavior by behavior

### Cold start and the local server

T3 desktop spawns its own backend, polls `/.well-known/t3/environment` every 100 ms with a 1 s request timeout and four staggered pollers, and restarts a crashed backend after 500 ms, doubling to 10 s (apps/desktop/src/backend/DesktopBackendManager.ts:37-56, 347-351, 602-615). CandyWrapper finds a running server first (T3Client/LocalServer/LocalServerDiscovery.swift:65-79), or launches one and polls every 150 ms for 10 s, then every 1 s (T3Client/LocalServer/LocalServerLauncher.swift:291-305). ServerController retries a failed start from 1 s doubling to 30 s, only while the window shows (App/Sources/ServerController.swift:127-137). Equal. CandyWrapper also paints the cached sidebar before the socket opens (App/Sources/ServerController.swift:72-99), and T3 desktop does the same from its orchestration cache.

Connect: T3 checks the descriptor with a 2.5 s timeout, prepares the connection (ticket), opens the socket with `frameParts=1`, and becomes ready on the first config snapshot (client-runtime/connection/driver.ts:61, 229-270; client-runtime/rpc/session.ts:250-262, 300-470). CandyWrapper checks the descriptor, gets a ticket, opens the socket (T3Client/ConnectionSupervisor.swift:297-317) and waits for the config snapshot in ServerConfigFeed. Equal, now including `frameParts`.

Shell: T3 asks for the HTTP shell as soon as the connection is prepared, when the descriptor names `shellThreadFamilies` or `shellOlderSettled`. The subscription waits for that answer, and the live config must confirm the omissions (client-runtime/state/shell.ts:562-611, 640-710; contracts/src/environment.ts, #35071). CandyWrapper asked only after the config (App/Sources/ShellSession.swift:196-250). It was worse and is now equal: `startEarlyShellLoad` (App/Sources/ShellSession.swift:157) reads the descriptor and loads the shell while the socket opens. prepareShell uses that load only when the config confirms the omissions and the server build. T3 also sends `knownProjectIdentities` and `httpSnapshotFallback` on the resume. CandyWrapper doesn't, so a 4928 resume may resend repository identities, which costs a few hundred bytes.

### Opening a thread

T3 reads the bounded snapshot over HTTP with `compactTurnItems`, `dedupeBodies`, `compactIds` and `deferWork`, then subscribes from its sequence with `acceptBoundedSnapshot`, `acceptDeferredWork`, `acceptCompactTurnItems`, `acceptCompactIds` and `acceptDedupedBodies` (client-runtime/state/boundedThreadSnapshotHttp.ts:31-38, client-runtime/state/threads.ts:1111-1128). CandyWrapper does the same without `deferWork` and `acceptDeferredWork` (T3Protocol/Domain/ThreadStream.swift:158-168, T3Store/ThreadStore.swift:85-97, App/Sources/ThreadSession.swift:128-137). The round trips are equal: one HTTP request and one subscription, behind the live socket, in both. "Threads load while the socket connects" (#35071) is the shell, not the thread.

Deferred work is worse in CandyWrapper. With `deferWork`, a finished run's work group of more than 150 rows arrives as one anchor row with a `deferredWork` cursor, and the client loads the rest when the user expands it (apps/server/src/orchestration-v2/threadHistoryPaging.ts:224-260). Porting it needs the timeline to show folded groups and page them in, which is Features/Thread (T3Store/TimelineRows.swift:424 has the marker). Compact checkpoints (#27110) are server-side: a 4928 server sends at most 200 `files` and `filesTotal`, and CandyWrapper already reads `filesTotal` (protocol.md, Nightly 4928 changes). Equal.

Keep-alive: T3 desktop keeps every running thread subscribed, so opening one needs no replay (apps/web/src/state/threads.ts). CandyWrapper has `RunningThreadKeepAlive` (App/Sources/AppDelegate.swift:366-370). Equal.

### Config bandwidth and frame parts

Covered above: CandyWrapper sends the same config flags as the desktop app. Frame parts (#23758): T3 asks for `frameParts=1`, and a 4928 server then splits frames over 48 KiB into parts that start with U+001E (packages/shared/src/socketFrameParts.ts:7-81, apps/server/src/ws.ts). Each part counts as traffic for the 15 s liveness timeout, so a multi-megabyte snapshot on a slow link no longer reads as a dead socket. CandyWrapper's watchdog has the same 15 s rule while a reply is owed (T3Transport/RPCConnection.swift:56-70, 394-410), and an 8 MB thread snapshot at 500 KB/s takes 16 s, so a slow relay could drop the socket mid-frame and loop. That was worse and is now equal: both socket URLs ask for `frameParts=1` (T3Transport/EnvironmentHTTP.swift:275, T3Client/Connect/T3ConnectAuthorizer.swift:276), and the receive loop joins parts and counts each one (T3Transport/RPCConnection.swift:109-125, 318-324). A 3824 server ignores the parameter. On 4928 the 98 KB config now arrives as 3 frames.

### Reconnect

| Behavior | T3 | CandyWrapper | Verdict |
|---|---|---|---|
| Ladder | `min(300 s, 2^(n+1) s)`, delay in the upper half, reset after 30 s up (client-runtime/connection/supervisor.ts:35-49, 128-141) | the same (T3Client/ConnectionSupervisor.swift:4-22) | equal |
| First loss of a live session | 125 to 250 ms, counted on the ladder (supervisor.ts:1286-1298) | was the 1 to 2 s rung; now 125 to 250 ms, not counted (ConnectionSupervisor.swift:574-610) | was worse, now better on a restart |
| A failed probe | reconnect at once, ladder reset (supervisor.ts:1281-1285) | reconnect at once (ConnectionSupervisor.swift:710-718) | equal |
| Pooled HTTP after a silent death | browser pool; long resume uses a 1.5 s probe (supervisor.ts:60-62) | was reused, 10 s hang; now a fresh session for that environment (T3Transport/EnvironmentHTTP.swift:78-96, 121-128) | was worse, now better |
| Wakeups | visibility change (`application-active`), focus, network type change, offline and online (apps/web/src/connection/platform.ts:97-160) | app activation, system wake, NWPathMonitor path and reachability (T3Client/PlatformSignals.swift:8-40) | equal |
| Server ready after an app-driven update (#35327) | reconnect as soon as it answers | ServerUpdater reconnects on its own schedule; left to settings-4928 | worse, not in scope |
| Subscriptions | follow every session; resubscribe on the same session after a stream failure; shell and thread resubscribe on app activation (client-runtime/rpc/client.ts:295-470, wakeups.ts:25-27) | follow every session, retry after 250 ms doubling to 30 s on the same session (ConnectionSupervisor.swift:807-855) | equal, except the activation resubscribe |
| State after reconnect | resume from the cursor: replayed events or a bounded snapshot | the same (App/Sources/ShellSession.swift:196-250, T3Store/ThreadReducer.swift:455-466) | equal |
| Mutations | not replayed; a message retried after socket loss keeps its command id (#24761) | not replayed; the composer offers the text back | equal for safety. CandyWrapper doesn't resend on its own |

### Liveness

T3's Effect client pings every 5 s and drops a socket after 15 s without any frame (client-runtime/rpc/protocol.ts:10-12). CandyWrapper sends no idle pings on direct routes, to keep idle wakeups at zero (T3Client/ConnectionSupervisor.swift:173-186). It checks a quiet socket only while a reply is owed or a turn runs with the app active (T3Transport/RPCConnection.swift:56-70). On relay routes it pings every 80 s while the app is active. So an idle half-open socket stays "connected" in CandyWrapper until a signal arrives: app activation, wake, a path change or Reconnect. That is worse by design, and the user decided it. Each signal now finds a dead socket quickly:

- The silent socket check (client-runtime/connection/supervisor.ts:745-790): a probe still unanswered after 500 ms asks the host for its descriptor on a session of its own, once a second. If the host answers while the socket delivered no frame, the socket is dead. It is replaced at once on loopback and LAN, and 2.5 s after the check started elsewhere (T3Client/ConnectionSupervisor.swift:663-718). T3 skips this check for its foreground probe because its pings already watch the socket. CandyWrapper runs it there with the 2.5 s wait on every route, since the foreground probe is its main check.
- Probe deadlines follow T3's: 15 s with one tolerated miss for app activation (#24309), and 3 s for Reconnect, wake and going offline. A path change gets 3 s on loopback and LAN, 15 s elsewhere (supervisor.ts:710-743; ConnectionSupervisor.swift:627-660). Before, a path change used 3 s on every route, which could drop a live tailnet socket.
- A thread whose subscription dies on a defect resubscribes (#25919, #24400): CandyWrapper's durable subscription already retries server failures on the same session (ConnectionSupervisor.swift:834-850). Equal.
- A message the host never answers (#35076): T3 fails the send after 60 s (client-runtime/operations/commands.ts, `MESSAGE_DISPATCH_TIMEOUT`). CandyWrapper waited forever on a live socket. It now fails with "<host> did not confirm the message within 60 seconds." and interrupts the request (`ConnectionSupervisor.dispatchMessage`, App/Sources/ComposerController.swift:2151). That was worse and is now equal for thread messages. New-thread launches and queued sends still use plain `request`.
- Token renewal: T3 Connect sockets. The environment closes a socket when its one-hour session ends, unless the same DPoP key renewed it, and a 4928 server then moves the socket to the new session (#27998, apps/server/src/auth/SessionStore.ts). T3 renews in the last minute and retries every 5 s until expiry (client-runtime/connection/driver.ts:250-266, client-runtime/authorization/service.ts:784-812). CandyWrapper renewed only when an HTTP call needed a token, so the socket dropped hourly. `T3ConnectAuthorizer.keepSessionAlive` (T3Client/Connect/T3ConnectAuthorizer.swift:310) now does what T3 does. A 3824 server still closes at the hour, and the supervisor reconnects as before.
- Token renewal: pairing links (`accessTokenRenewal`, #37980, #37990). T3 4928 pairs direct links with the device's DPoP key and renews them for up to 30 days. CandyWrapper pairs with a bearer token that lasts 30 days and then needs pairing again. That is worse, once a month, and not ported: it needs DPoP pairing for direct routes, which is auth work for its own task. It was left to settings-4928.

### Streaming

T3's RPC client acks each chunk as its stream pulls it, and the stores batch updates per animation frame. CandyWrapper acks a chunk once its last value has gone through the handler (T3Transport/RPCConnection.swift:301-315), reduces off the main thread, and renders at most once per screen frame (DesignSystem/Base/FramePacer.swift:69-90; App/Sources/ShellSession.swift:99). The server sees the same backpressure from both. I found nothing that delays or bunches replies in CandyWrapper on a healthy socket. The one case that did is a live socket that silently died mid-turn: replies stopped and the thread looked live for 15 s, then took 10 s more to reconnect. It now reconnects 0.2 s after the 15 s check.

### T3 Connect and remote machines

Routes: both rank learned direct routes as LAN, tailnet, public, then relay, and check a direct route's descriptor before sending a credential (T3Client/Connect/ConnectRoutes.swift:1-60; client-runtime/connection/routes.ts:110-299). T3 checks every 60 s for a better route while on a fallback, and skips a route that failed for 5 minutes (supervisor.ts:44-49, 810-815). CandyWrapper picks a route once per connect (App/Sources/Environments.swift:294), so a laptop that comes home stays on the tunnel until the next reconnect. That is worse and not ported. It needs a 60 s tick while on a fallback route, which T3 runs but is an idle timer.

Relay keepalive: CandyWrapper pings every 80 s while the app is active, because tunnels drop idle sockets after about 100 s. T3 pings every 5 s. Equal in effect.

What the user sees while routes are tried: both show "Connecting" on the first attempt and "Reconnecting" after a failure (`ConnectionState`, T3Client/ConnectionSupervisor.swift:113-152; client-runtime/connection/presentation.ts:29-68). Both show the approval-pending message and its code (#36419). Equal.

### What the user sees

The offline banner and its diagnosis use T3's failure kinds and hops (T3Client/ConnectionSupervisor.swift:36-98; client-runtime/connection/errors.ts:115-277, diagnosis.ts). Equal. Stale data: both keep cached rows readable while offline and resume them from their cursor (connection-runtime.md). Optimistic updates: both show sidebar moves at once and take them back on failure (App/Sources/Environments.swift:623-645). Equal. Before this task, the visible difference was the time a dead connection kept showing "Connected" with stale rows after the user came back to the app: 15 s, then 13 s of "Reconnecting". It is now about 2.5 s.

## Timers while connected

After this change, these run while a session is connected:

- On a direct route, idle, nothing.
- While a turn runs and the app is active, or while a unary call or a stream's first answer is owed: the RPCConnection watchdog, one wakeup per 5 s (T3Transport/RPCConnection.swift:376-410). This existed before.
- On a relay route while the app is active: one ping per 80 s (T3Client/ConnectionSupervisor.swift:720-736). This existed before.
- On a relay route, always: one sleep until the token's last minute, about one wakeup per hour per relay connection (T3Client/Connect/T3ConnectAuthorizer.swift:310-338). This is new. T3's protocol needs it: without it the server closes the socket. After a failed renewal it retries every 5 s until the token expires.
- While a message send waits for its answer: one 60 s deadline, cancelled when the answer arrives (`dispatchMessage`). This is new.
- During a probe, which only a signal starts: the probe deadline, and the silent socket check's 500 ms and 1 s waits. These end with the probe.

## Not ported

- `deferWork` folding. It needs the Features/Thread timeline to show and page folded work groups.
- Shell and thread resubscribe on app activation. It costs one small round trip per activation. Add it if a stream that stops without an error turns up in practice.
- The 60 s better-route check on T3 Connect fallbacks. It is an idle timer while on a fallback.
- DPoP pairing and `accessTokenRenewal` for direct pairing links.
- `knownProjectIdentities` and `httpSnapshotFallback` on the shell resume.
- 5 s idle pings. The user's zero-idle rule wins; signals and the silent socket check cover the common cases.
