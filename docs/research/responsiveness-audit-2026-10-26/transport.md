# Transport responsiveness audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

Reviewed 2026-10-26 at `0ced803c3ec141b3a58ab31e5bc401d6f61a06e3`. Product code and visual design are unchanged. Two source-traced findings need centralized reproduction. Neither is an executed app reproduction or a measured regression.

No builds, tests, servers, app launches, account access, credentials, or shared-screen actions ran in this worktree. The test additions below have not been compiled or executed. The only validation performed here is source review and `git diff --check`.

## Findings

### T1. T3 Connect HTTP and signed assets retain an obsolete tunnel origin

Severity: P1 for a relay-only environment whose endpoint changed. Evidence: source-traced, not executed. Trigger: save a relay environment at endpoint A, then have relay connect or token renewal return endpoint B while A no longer serves that environment. This also applies on the first launch after a remote tunnel changes, without an in-session reconnect.

Reachability and ownership:

- `Packages/CandyKit/Sources/T3Client/EnvironmentCatalog.swift:194-212` persists the listing's endpoint as the relay route.
- `App/Sources/Environments.swift:246-260` passes that saved route to the relay `ShellSession` constructor.
- `App/Sources/ShellSession.swift:75-82` creates an `EnvironmentHTTP` with that fixed base URL, alongside a connector that independently authorizes its socket.
- `Packages/CandyKit/Sources/T3Client/Connect/T3ConnectAuthorizer.swift:147-167` obtains the fresh relay endpoint. Its socket uses this endpoint at `:230-240`; `connector` discards the returned HTTP base at `:270-273`.
- The HTTP authorization closure returns headers only (`:224-227`). It can renew the token, but cannot replace the request origin. `Packages/CandyKit/Sources/T3Transport/EnvironmentHTTP.swift:47` makes `baseURL` immutable and `:212-217` builds every typed request from it.

User effect: the socket reconnects and live messages can work, but HTTP bootstrap, history, and signed content still go to A. Shell bootstrap incurs its failing HTTP attempt before falling back to the socket (`App/Sources/ShellSession.swift:192-204`). Thread history uses HTTP without a socket replacement (`App/Sources/ThreadSession.swift:203-224`). HTML reply URLs are also resolved against A even after a successful `assets.createUrl` RPC on B (`App/Sources/ThreadSession.swift:515-524`); file assets do the same (`App/Sources/FilesController.swift:490-501`). Project-icon downloads retain A (`App/Sources/ShellSession.swift:410-426`). Retrying the same HTTP action does not repair the origin.

T3 behavior checked locally at the pinned `v0.1.2-nightly.20261021.3473`: `packages/client-runtime/src/state/environmentHttpAuth.ts:155-177` obtains current DPoP HTTP authorization and explicitly replaces a relay target's `httpBaseUrl` with `current.httpBaseUrl` before building and signing the request. Learned direct routes intentionally keep their own origin. This is the behavior CandyWrapper's relay session lacks.

Central reproduction: use two fake HTTP endpoints for one synthetic environment. Persist A, return B from relay connect, retire A, and assert that both the authorized socket and HTTP history/asset requests target B. Include a fresh session and an in-session token renewal, plus the control case where a learned direct route keeps its origin. Existing `EnvironmentHTTPRetryTests.a401RetriesOnceWithAFreshToken` covers header replacement on one origin, not this ownership gap. App-level wiring needs coverage in addition to an authorizer unit test.

### T2. A Pong disables loading recovery before the initial config snapshot arrives

Severity: P2. Evidence: source-traced, with an unexecuted deterministic fault-injection test. Trigger: direct connection, no active turn, server accepts `subscribeServerConfig` but delays its initial snapshot; answer its liveness Ping, then silently drop the network without a socket close or platform path event. A stalled config handler with a healthy socket also leaves the initial load without a deadline.

`Packages/CandyKit/Sources/T3Transport/RPCConnection.swift:324-327` marks every stream answered on any Pong. This removes all initial-stream obligations from `owesReply` (`:339-341`), and `handle` cancels the watchdog (`:298`). A pending stream snapshot is not distinguished from an intentionally silent terminal subscription. There is then no direct-route keepalive to discover the subsequent silent failure (`Packages/CandyKit/Sources/T3Client/ConnectionSupervisor.swift:222`, default `.none`).

This is reachable from cold app loading: `App/Sources/ShellSession.swift:133-138` runs `prepareShell` before sending the shell subscription. `prepareShell` waits at `:178` for `ServerConfigFeed.initialConfig`; the feed installs a continuation with no deadline (`Packages/CandyKit/Sources/T3Client/ServerConfigFeed.swift:71-86`). Its cancellation, interruption and stop paths work, but none fires in this scenario. Projects can remain unloaded, or a disk shell can remain paint-only. The supervisor still reports connected. A subsequent user action, application activation, network signal, or manual reconnect can recover; this is not an assertion that all recovery paths fail. Relay keepalive eventually probes and is a mitigating difference.

The transport comment's claim that a Pong proves prior streams are being served is stronger than the protocol. T3's vendored `.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:806-807` answers Ping directly, independently of a handler producing its first chunk. T3's `apps/server/src/ws.ts:2960-2965` awaits `loadServerConfig` before yielding initial config, so a Pong is not its snapshot completion marker. The existing `RPCConnectionTests.aQuietSubscriptionNeedsOnePongThenNothing` (`Packages/CandyKit/Tests/T3ClientTests/RPCConnectionTests.swift:299-312`) intentionally verifies silence for a terminal; it does not cover this startup dependency.

Central reproduction: run the opt-in test below. It uses `ServerConfigFeed`, a fake socket and manual time: no config snapshot is delivered; a Pong arrives at 5 seconds; virtual time then advances 60 seconds. The assertion that loading still has transport recovery intentionally fails on the reviewed source. Stop and cancellation clean up the pending reader. A repair could instead put a bounded fallback at the config owner; it need not impose deadlines on intentionally silent subscriptions or long-running unary operations. Extend validation to delayed config, failed config, and cancelled startup so a fallback cannot revive a stopped session.

## Test additions and commands

`Packages/CandyKit/Tests/T3ClientTests/TransportResponsivenessAuditTests.swift` adds:

- `concurrentCancellationAndReversedRepliesKeepRequestIdentity`: 64 concurrent calls, 22 cancellations, reversed responses including late cancelled responses, and 16 two-value stream chunks. Checks request identity, cancellation results, stream ordering, one Ack per chunk, and clean completion. This is an ordinary regression test expected to pass, not an observed pass.
- `pongBeforeInitialConfigMustNotRemoveLoadingRecovery`: the T2 reproducer, disabled unless explicitly enabled. It intentionally asserts the missing recovery behavior. Both tests have a one-minute suite time limit and use only in-memory transport.

Parent-run commands, from the repo root with the normal preflight/central execution discipline:

```sh
scripts/test --filter TransportResponsivenessAuditTests
CANDY_TRANSPORT_AUDIT_FAILURES=1 scripts/test --filter pongBeforeInitialConfigMustNotRemoveLoadingRecovery
scripts/test --filter 'RPCConnectionTests|RPCLivenessTests|SupervisorTests|ServerConfigFeedTests|ThreadSnapshotLoaderTests|EnvironmentHTTPRetryTests|EnvironmentHTTPAssetLimitTests|T3ConnectTests|T3ConnectAccountTests|ServerLifecycleTests'
```

The intentional failure command is separate so the ordinary lane stays usable. Test source has not been compiled; parent must inspect compilation and results before treating it as evidence.

## Revalidated prior findings and inspected safeguards

The 2026-10-18 codebase audit's asset-size finding 8 is fixed in current source: `Packages/CandyKit/Sources/T3Transport/EnvironmentHTTP.swift:160-168` checks declared length and accumulated bytes during receipt, cancelling at the limit. Existing `EnvironmentHTTPAssetLimitTests` covers both declared and undeclared oversized bodies. This is a revalidation, not a new finding; those tests were not rerun here.

Source review also checked ordered writes, per-request continuations, cancellation/Interrupt, Ack boundaries, socket failure propagation, generation guards, reconnect backoff, resubscription payload refresh, shared DPoP exchange cancellation, account-reset generation checks, and local-server start/stop ownership. No additional concrete defect is claimed from those paths. The prior audit's scheduled-task/device session-replacement findings concern app subscription owners and were left to the other audit areas, rather than relabeled as transport defects.

## Limits and useful stress follow-ups

No runtime loading timings, runtime fault reproduction, or network/account integration result is available from this review. T3 source checked here is the local 3473 pin, not the pending 3669 source port. Inspection sampled transport, protocol framing, config/thread bootstrap, Connect authorization/account and local lifecycle paths; it did not exhaustively read all domain decoders, Clerk endpoints, SSH scripts, process tooling, or runtime updater/rollback code.

Useful centralized scenarios: 100 repeated disconnect/resubscribe cycles with monotonic cursors; interleaved shell/thread/config traffic while cancelling half the requests; a delayed first config followed by Pong and network blackhole; tunnel-origin rotation; slow-drip HTTP snapshots/history to distinguish inactivity from total deadlines; sign-out/reset during shared token renewal; concurrent ensure/start, idle stop and action restart with fake owned servers; malformed/unknown frames alongside cancelled responses. Do not interpret general unary absence of a deadline as a standalone defect without establishing the particular action's completion contract: some server operations legitimately run a long time.
