# Nightly 3814 wire audit

Group B, 2026-10-28. Compared contracts at `v0.1.3-nightly.20261025.3669` and `v0.1.4-nightly.20261028.3814`. Source citations below refer to the 3814 tree. Peer links and `link_request` belong to the main session.

## Recorded decode proof

`fixtures/transcripts/24-nightly-3814.jsonl` comes from a read-only `nightly` session recorded with `scripts/record-transcript.swift` against the 3814 sandbox. It includes config, 129 shell threads and the same migrated thread used by the 3473 and 3669 recordings, with fork, compaction and subagent items. Bearer tokens and the WebSocket ticket are replaced, home paths use `/Users/user`, and provider addresses use the existing fixture's scrubbed address.

`NightlyCompatTests.recorded3814ConfigShellAndThreadDecode` checks the config capability, shell and thread stream items and projection. It passed alongside both older recordings without a decode fix. These are recorded responses, not proof that every optional feature was exercised. Contracts: `packages/contracts/src/server.ts:608`, `orchestrationV2.ts:2592` and `orchestrationV2.ts:4083`.

## Contract removals and dependencies

The audit read the diff in slices and searched App, T3Protocol, T3Client and T3Store. None of the 156 removed exported TypeScript symbol names occurs in those modules. The wire-name checks below also cover Swift types with different names.

| Removal or change | Native dependency and disposition |
| --- | --- |
| `scheduledTasks.list` | Four Orchestrator calls used it. Read the first `scheduledTasks.subscribe` snapshot and immediately interrupt the stream. This subscription exists on older supported servers too. Source: `packages/contracts/src/rpc.ts:1828`. |
| `projects.list`, `projects.add`, `projects.remove` | No production RPC calls. The recorder's older scenarios intentionally exercise unsupported methods and remain historical tools. |
| `server.getSettings` | No production call. Settings already follow the shared config stream. |
| `provider.codex.auth-callback.subscribe` | No production call. The native loopback receiver is independent of this removed server RPC. |
| `terminal.restart`, `subscribeTerminalEvents` | No production calls. Native terminals already attach and observe metadata. |
| `preview.navigate`, `preview.refresh` | No production calls. `PreviewRPC.navigate` is an unused legacy constant; preview shortcuts and browser navigation use stream commands or WKWebView. |
| `orchestration.subscribeArchivedShell` | No production call. Archived rows use shell snapshots and queries. |
| `server.reportHostPowerState`, `server.getBackgroundPolicy`, `subscribeBackgroundPolicy` | No production calls. |
| HTTP GET `/api/auth/pairing-links`, GET `/api/auth/clients`, POST `/api/connect/mint-credential` | Helper uninstall called GET `/api/auth/clients`. It now reads one `subscribeAuthAccess` snapshot before revoking helper sessions. No calls to the other removed routes; Connect uses the relay authorization sequence. Revoke routes remain supported. |
| Activity `batteryState`, `networkType` | Not sent or required by native activity reports. |
| Provider `requiresNewThreadForModelChange` | Kept optional for older servers. Its absence removes the legacy model-switch restriction. |
| Config `reasoningMessages` | Not required or sent. Native thread data already supports reasoning. |
| Shell `latestRunSilent` | Kept optional for older recordings and their notification suppression. No command requires it. |
| Update input `continueRunningThreads` | The existing caller sends it only with `serverUpdateThreadContinuation` and the user's continuation setting. The 3814 sandbox advertises no such capability, so no field is sent there. The removed field was unused upstream; continuation is controlled by server settings. |
| Background override `idleClientTtl` | Native override writes used to add it even when absent. They now preserve it only when the host already sends an explicit override; modern patches omit it. Other legacy preset values remain readable. Source: `packages/contracts/src/settings.ts:925`. |
| Client settings `sidebarThreadPreviewCount`, `dismissedProviderUpdateNotificationKeys` | The preview count remains a CandyWrapper local setting; it is not a server-settings patch. No dependency on the removed notification key. |
| Publish result `upstreamBranch` | No required result read. VCS branch tracking is a different response. |
| Thread metadata MCP `link_pull_request`, `unlink_pull_request` actions and `pullRequest` input | No native MCP invocation. Native PR writes use orchestration commands. Historic tool names stay recognized in recorded timelines. |
| Runtime event schemas, provider session/start/stop/respond schemas, raw provider events, stored events, provider-thread disposition, project changes, `AssistantDeliveryMode`, `ProviderInstanceRef`, `VcsOutputDecodeError`, `WORKTREE_SETUP_ACTIVITY_KIND`, runtime id aliases | These remove unused server/provider internals. Native wire decoders consume orchestration v2 projections and events, not these removed schemas. Retained runtime data uses open strings/raw JSON where appropriate. |
| Desktop IPC bridge and `issueSshWebSocketTicket`/preview recording listener | Electron bridge shapes do not govern the native client. Native SSH uses environment HTTP tickets; native browser recording owns its own stream. |

Other hunks add optional fields, capabilities, methods, enum values or source-only schema helpers. New `environmentId` MCP targets and nullable remote task children are not native RPC inputs. The app does not call the removed MCP tools directly. Unknown provider drivers and settings remain readable. No orchestration protocol version changed.

## Native ports and gates

- MCP action tools resolve labels from `input.action`. Configure reads/writes and schedule creates/updates resolve their summary from `modelSelection` and `scheduledTaskId`. Legacy tool names remain recognized; the input shape is the gate. Source: `packages/shared/src/t3McpToolPresentation.ts:412-456` (ed44f251d8).
- Provider config and refresh opt into `workspaceSnapshotsOnDemand` only with `providerWorkspaceSnapshotsOnDemand` from the descriptor/config. Direct and Connect sockets retain their already-authorized descriptor metadata. A 32-entry cache per environment merges only matching provider bases, drops stale provider-wide command/skill/enabled bases and drops all providers' entries for a fresh cwd scan. A missing reply removes that cwd. Failed reads release the retry stamp; replies from replaced sessions are ignored. Removed environments release their cache and late replies cannot recreate its config. Source: `packages/client-runtime/src/state/server.ts:656-742,1335-1356` and `packages/client-runtime/src/rpc/session.ts:175-179` (abd9d9f970).
- `t3-thread://v2/environment/thread` stays scoped through chip lookup, opening and Orchestrator plans. Only v1 permits a unique match elsewhere; written then decoded ids in the message's environment take precedence. Missing targets render unresolved chips. Minimap titles resolve at hover, and plain text never exposes a raw autolink. These are client-local formats and need no server RPC gate. Source: `packages/shared/src/threadLinks.ts:16-73,110-150` and `apps/web/src/components/chat/MarkdownThreadLink.tsx:21-42` (c2fbf0a524).
- Terminal snapshot/activity `cols` and `rows` are optional. Their presence drives per-axis render clamping, while resize reports keep the viewer's measured size. Older snapshots clear the shared grid and restore local fitting. Source: `packages/contracts/src/terminal.ts:100-105,196-203` and `apps/web/src/terminal/ghostty/surface.ts:896-934` (49a9e80e0b).
- Untargeted pairing rejects an unfamiliar origin claiming a saved id before redeeming its code. The catalog repeats the check under its mutation lock before saving credentials. Explicit Add route and known origins remain allowed. Source: `packages/client-runtime/src/connection/onboarding.ts:130-139` and `registry.ts:544-577` (003ccd336d).
- Auth-session timeouts retry with doubled request deadlines, capped at 60 seconds; other failures do not retry. Settings icon permissions distinguish pending/failed reads from explicit denial. Source: `packages/client-runtime/src/state/session.ts:39-75` (024e593a63).
- Disconnected unary RPCs already fail immediately. Palette failures retain their answer, partial PR failures retain the failed environment's rows, and both retry on a new connected session. No new polling timer. Source: `packages/client-runtime/src/state/runtime.ts:607-650,724-752` (8e86eb2b4d).
- Reconnect descriptor reuse was already present in the direct connector, and history loads already run in separate HTTP tasks. The Connect metadata retained for workspace negotiation adds no descriptor fetch. Replay coalescing is server-side. No separate scheduler or reconnect change is needed for 9910c0e874. Source: `packages/client-runtime/src/connection/resolver.ts:298-307`, `state/threadCommands.ts:355`, native `ConnectionSupervisor.directConnector` and `ThreadSession.loadEarlier`.

## Validation

The initial recorded compatibility run passed all 11 cases, including 3473, 3669 and 3814. The subsequent focused run passed 114 tests: 52 store, 20 protocol, 20 client and 22 UI helper tests. It includes both first-snapshot subscription tags, paired-origin rejection, timeout retries, scoped links, terminal rendering and workspace caching.

A later preflight failed at 39 GB free. The fast lane was mistakenly started before handling the result, then its owned process group was stopped. No further builds or tests ran. Final cache-review refinements remove snapshots from already-decorated config after cache eviction, keep only the provider basis fields, prevent unnecessary composer refreshes, release failed-read retry stamps and reject late replies from replaced sessions. These last refinements have not been rerun. The final fast lane is still required before integration.

App-source syntax parsing passed before the last cache refinement; the final diff and secret scan pass. No app launch, live-server mutation, real turn, screen lock or screen capture was used. Additional read-only RPC recordings confirm scheduled-task snapshots on 3473, 3669 and 3814. All three recognize the access subscription but deny it because the sandbox token lacks `access:read`; the successful access-snapshot path is covered by the mock test.

The main session should verify shared terminals with two differently sized windows, cross-machine v2 chip navigation and Orchestrator plan navigation, reconnect search/PR refresh, and the pending/failed permission message. A full app build and visual check remain for the main session because this brief permits package tests and offscreen checks only.
