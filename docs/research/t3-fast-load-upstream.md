# Upstream fast-load audit

Audited 2026-10-25. Research used Git only, without servers or user data. The implementation that follows this audit owns lazy shells; the parent owns HTTP-first thread loading and another worker owns thread ID/body codecs.

## Pinned sources

- Comparison base: `8f026485df097cca71f80218a514f4d2e13bbf43`.
- Fetched main: `5b35402623d7d1d88eaa472807272a6c2e78012a`.
- Supported runtime `v0.1.2-nightly.20261021.3473`: `1688f965682d331da16a8c39f049592361f69c8d`.
- Published version verified for these changes after integration: `v0.1.3-nightly.20261025.3669`, tag `5f64c5eb299a23d278ef043c416bd4dc801bc53c`. Every introducing commit in the registry below is an ancestor of that tag. It contains the required fast-load protocol changes; it is not the measured main commit and was not substituted in the matrix.
- Read-only original checkout: `~/CandyWrapper-research/t3code`, still checked out at the runtime SHA. Only `git fetch origin main` changed its refs.
- Pinned sparse research checkout: `~/CandyWrapper-research/t3code-fast-load-5b35402623`.
- CandyWrapper inspected at `8c8e6d3026128894bd48b6d410320fdf0ab4c16b`, before this task's changes.

Every upstream `file:line` below refers to fetched main unless a different revision is explicit. Commit prefixes in the matrices resolve to the full SHAs in the registry. Runtime membership was checked with `git merge-base --is-ancestor` against the runtime tag, not inferred from dates or version names.

Upstream has **no `docs/protocol.md`** at the base or fetched main. CandyWrapper's local `docs/protocol.md` is its own research, notably lines 93, 1128-1230. It documents the existing protocol, but not the new shell omissions, body deduplication or ID table. Authoritative new sources are contracts and handlers, plus `docs/internals/connection-runtime.md:62-89` and `docs/internals/performance-regressions.md:15-69`.

## Stable APIs and compatibility

| Surface | Stable shape and source | 3473 and fallback |
| --- | --- | --- |
| Active shell | `GET /api/orchestration/shell`, then `orchestration.subscribeShell {afterSequence?,requestCompletionMarker?}`. `packages/contracts/src/environmentHttp.ts:695-702`, `orchestrationV2.ts:3402-3415`. | Both exist. A cold HTTP snapshot's cursor starts the socket tail. A new connection must get an authoritative snapshot, or explicitly validate cached omission policy before resuming. |
| Thread cold load | `GET /api/orchestration/threads/:threadId/bounded?compactTurnItems=1`; metadata is `snapshotSequence`, `historyCursor`, `hasMoreHistory`, `latestLocalTurnOrdinal`. `environmentHttp.ts:720-727`, `orchestrationV2.ts:3528-3546`. | Exists. Keep cursor opaque. `payloadBudgetExceeded` exists in 3473 but was removed by `553203c57b`; it must stay optional. |
| Thread socket | `orchestration.subscribeThread {threadId,afterSequence?,requestCompletionMarker?,acceptBoundedSnapshot?,acceptCompactTurnItems?}`. `orchestrationV2.ts:3500-3509`; runtime's same file at `1688f965:3202-3209`. | Existing CandyWrapper already requests bounded and compact local turn items. Marker and pagination flags live at top-level config, not `environment.capabilities`. |
| Older history | `GET /api/orchestration/threads/:threadId/history?cursor=...&throughEntryId=...&view=conversation\|activity`. `environmentHttp.ts:681-685,729-736`. | Exists. Keep pages oldest-first, merge by identity, reject stale request cursors and retain the local ordinal watermark. CandyWrapper does this in `T3Store/ThreadReducer.swift:389-399`. |
| Negotiation | `server.getConfig` / config stream top-level `shellResumeCompletionMarker`, `threadResumeCompletionMarker`, `threadSnapshotPagination`. New `shellThreadFamilies`, `shellOlderSettled`. `packages/contracts/src/server.ts:596-611`. | Missing means false. Runtime config has the first three, no shell omissions. Never infer omission support from semver alone. |
| Protocol envelope | Existing HTTP orchestration protocol header/auth and RPC group remain. New recovery RPCs actually join `WsRpcGroup`, `packages/contracts/src/rpc.ts:1679-1700,2100-2104`. | Do not discover methods by sending speculative destructive calls. New read RPCs must be gated. |

## New formats and lazy shells

| Change / introducing commit | Exact API and implementation citations | Required client work / opt-in / fallback | CandyWrapper at audit start |
| --- | --- | --- | --- |
| Skip idle subagents, `67c3afbd58` | Config `shellThreadFamilies`; HTTP `omitIdleSubagents=1`; WS `omitIdleSubagents:true`. `server.ts:597-601`, `orchestrationV2.ts:3405-3409`, `apps/server/src/orchestration-v2/ShellStream.ts:74-114`. | Gate on flag. Keep live/queued/pending-request/background-work children and intermediate parents. Both HTTP and WS must use matching omissions. With no flag omit the key and retain full shell. | Absent. `App/Sources/ShellSession.swift:84-91` sends only marker/cursor. |
| Family recovery, `67c3afbd58` | `orchestration.getThreadFamily {threadId}` -> `{snapshotSequence,threads}`; every active thread sharing `lineage.rootThreadId`, including forks and complete subagent trees. Unknown thread returns empty. `orchestrationV2.ts:3418-3432`; client `state/threadFamilies.ts:69-112`. | Read on thread open, deep link, relationships and queued-reference consumers. Scope by environment and authoritative shell generation. Merge behind newer shell rows/tombstones; never persist ephemeral family rows. Failure is not deletion. Do not eagerly fetch every family. | Absent. Consumers currently look in merged shell. |
| Worktree safety recovery, `67c3afbd58` | `orchestration.getWorktreeThreadIds {worktreePath}` -> `{threadIds}` includes omitted active children. `orchestrationV2.ts:3434-3438,3494-3498`; `rpc.ts:1685-1692`. | Gate on families. Use for destructive worktree/orphan decisions. Missing local rows do not prove the worktree is unused. On read failure, stop cleanup or retain worktree. | Absent. Audit delete flow in `App/Sources/SidebarCommands.swift:710-734`. |
| Skip older settled threads, `e57c093cdd` | `shellOlderSettled` **and** families; HTTP `omitOlderSettled=1`, WS `omitOlderSettled:true`. Keeps 25 newest settled top-level threads and ties, pinned, future snoozed, live and needed ancestors. `ShellStream.ts:117-201`; config `server.ts:602-606`; client `state/shell.ts:364-405`. | Capability gate both. Snapshot `olderSettled {before,asOfSequence,counts:[{projectId,count}]}` counts all rows below cutoff, including retained exceptions. No flag means full shell. | Absent; existing ShellSnapshot silently ignores metadata. |
| Settled shelf paging/counts, `e57c093cdd` | `orchestration.getOlderSettledThreads {before:{settledAt,threadId?},projectIds?,limit:0...50}` -> `{snapshotSequence,threads,counts}`. `orchestrationV2.ts:3464-3492`. | `limit:0` refreshes counts, positive reads pages, sorted settled time descending then id ascending. Cursor without id is strict; with id handles ties. Count = local settled above cutoff + server below-cutoff counts; avoid retained-exception double count. Invalidate reads on generation, honor removal/update sequences, refresh counts when old rows arrive/change/remove. Lazy on shelf reveal/scroll, not cold bulk fill. `state/olderSettledThreads.ts:205-305,333-345`. | Absent. Needs count-only invalidation that can publish with unchanged rows. |
| Search recovery, `e57c093cdd` | `orchestration.searchThreads` adds `olderSettledBefore`, `projectIds`, `environmentLabel`, `titlesOnly`; result adds `snapshotSequence`, `threads`. `orchestrationV2.ts:3440-3462`. | Gate extra keys on older-settled support. Mount returned rows so title/branch/project/PR matches and message hits can render and open. Discard stale query/generation responses. Empty search should not eagerly load omitted shelves. | `Environments.swift:602-617` asks only `query` and decodes only matches. |
| Snapshot body dedupe, `e19fe0837b` | HTTP bounded `dedupeBodies=1`; WS `acceptDedupedBodies:true`. No independent server capability flag. `environmentHttp.ts:675-679`, `orchestrationV2.ts:3506-3507`, `shared/src/orchestrationV2DedupedBodies.ts:13-119,143-183`. | Restore local item `textOmitted` from messages by messageId; `filesOmitted` from checkpoints; subagent prompt/result markers from subagent records. Restore before reducers and caches. Inherited rows without source records remain full. Legacy unmarked response remains valid. Official client sends opt-in unconditionally, `state/threads.ts:959-970`; conservative request-schema failure fallback can retry once without opt-ins per connection. | Absent. Retaining unknown JSON markers does not restore bodies. |
| Live/replay body dedupe, same commit | Subscription-local memory (32 records each), applied **after coalescing**, shared across snapshot/replay/tail; same opt-in. `apps/server/src/orchestration-v2/WireProjection.ts:251-310`; `ws.ts:794-797,905-909,976-980`. | Restore before each event reduction from current state, including repeated `subagent.updated`; preserve event order. Missing reference remains marked, not silently treated as an intentional empty body. Do not fetch every omitted body using getTurnItem. `state/orchestrationV2Projection.ts:324-334,368-373`. | Absent. Existing 16ms paired rendering workaround remains useful on 3473. |
| Compact ID tables, `80455376f0` | HTTP bounded/history `compactIds=1`; WS `acceptCompactIds:true` for bounded snapshots. Response top-level `ids` table; `idTable:true` is server-internal and is removed on encode. `contracts/src/orchestrationV2IdTable.ts:4-81,95-124`; `orchestrationV2.ts:3528-3563`; handlers `http.ts:234-238,263-265`. | Before typed decoding expand numeric `id` / suffix `Id` and array suffix `Ids` in records; inspect top-level container records/array elements and nested `item` only. Do not recursively rewrite arbitrary tool input JSON. Both strings and numbers can be table values. Snapshot container is projection; history container is root. Legacy without ids stays unchanged; no separate capability bit; old-server rejection fallback as above. | Absent. Swift string id decoding would reject compact IDs. |

## Server speedups and existing runtime behavior

| Change / commit | Sources and behavior | In 3473? / client implications |
| --- | --- | --- |
| WebSocket permessage-deflate, `2b1d4fecb8` | Already at base `8f02648:apps/server/src/server.ts:291-297`; fetched main `apps/server/src/server.ts:316-320`. Context takeover enabled, no threshold. HTTP compression also already enabled, `apps/server/src/http.ts:249-252`. | **Yes, before comparison base.** Transport extension negotiation, no JSON flag. CandyWrapper uses URLSession (`T3Transport/RPCSocket.swift:58-75`); source alone does not establish negotiated compression. Measure actual upgrade headers/bytes before claiming savings; never send the extension header without transport support. No new decompressor should be added to JSON code. |
| Large-message encode shortcut, `b437ec1ab2` | Commit-local `apps/server/src/orchestration-v2/threadHistoryPaging.ts:82-103,583-589` proves overflow from text lengths before full encode. | **Yes.** Superseded by `553203c57b`, which removes the diagnostic full encode and `payloadBudgetExceeded` entirely. No app patch recovers server CPU on an older runtime. |
| Large checkpoint reserve floor, `d9eb2b61c3` | `threadHistoryPaging.ts:533-545` reserves no more than half the row budget for control state. | **Yes.** Already automatic on bounded reads. Budget is approximate, one oversized row is admitted to ensure progress; never advertise hard 1MiB total snapshot cap. |
| Fork snapshot ancestry fast path, `c7f8404d2e` | `ProjectionStore.ts:3791-3826` counts inherited rows when local turns fill first page instead of decoding parent ancestry; nested forks still recurse. | **Yes.** Requires bounded load, already requested. No new wire opt-in. |
| Long single/agent turn bounded paging, `553203c57b` | `threadHistoryPaging.ts:9-30,190-237`; `ProjectionStore.ts:2889-3052`; `ws.ts:870-895`. Row query uses bounded SQL, handles notification-started runs. 10 user turns / up to 500 rows when a user turn fits; otherwise 75, with ~1MiB row budget. | **No.** Existing bounded/history APIs gain it only on newer runtime. 3473 remains on its old window behavior. Preserve cursors and watermarks, allow split turns and smaller pages, no assumptions that all active-run rows are loaded. |
| Shell SQL/index optimization, `c7e3993fe9` | `ProjectionStore.ts:6443-6511` restricts shell reads and fork dependencies; `persistence/Migrations/068_ShellStopRequestIndex.ts:7-10` adds partial stop-request index. | **No.** Server automatic, no capability or client migration. Never modify runtime databases to imitate it. |
| Reader routing, `6ed47b538c` | `ProjectionStore.ts:6731-6747`; shared `nodeSqliteClient.ts:47-56,439-480,1083-1096`: read-only work routed away from writer contention, fallback to main connection if worker unavailable. | **No.** Entirely server-side. |
| Shell resume avoids full read, `d7a8d6f320` | `ws.ts:1176-1204` reads head sequence, subagent IDs and project enrichment; no full shell unless replay fails budgets. | **No.** CandyWrapper already retains afterSequence; newer runtime benefits automatically. |
| Subagent transcript shell suppression, `fd1063ba7c` | `ShellStream.ts:311-320`; `ws.ts:1001-1003,1095-1103,1186-1199`. | **No.** Server filters bodies before retaining shell events; still sends state-changing deltas. Gaps in global sequence are valid. |
| Slow-client shell coalescing, `94827737ea` | `ShellStream.ts:38-58` buffers latest complete entity state; `ws.ts:1087-1093`. | **Yes.** No opt-in; snapshot, marker and enrichment boundaries bypass coalescing. Keep delta cursor monotonic, accept gaps. |
| Streaming coalescing improvement, `27e0c684c5` | `ThreadLiveEventCoalescer.ts:18-76,138-175` coalesces paired assistant message/item updates across 50ms, preserving surviving event sequences and identity/barrier ordering. | **No.** Automatic on newer server. Client still needs exact replay handling; idle polling unnecessary. |
| Config startup race fix, `6518c8243d` | `apps/server/src/ws.ts:3092-3099,3124-3129` subscribes to config changes before loading the initial config and compares the paired initial values. | **Yes.** No changed API. |
| Thread replay budgets, existing | `ThreadStream.ts:15-32`; `ws.ts:914-974`: 128 events, 1MiB raw stored payload and 1MiB projected replay JSON; recreation/ahead cursor forces snapshot. | **Yes**, already documented in CandyWrapper `docs/protocol.md:1170-1208`. Not a new delta protocol. Restore body markers in replay on new opt-in. |
| Shell replay budgets, existing | `ws.ts:576-577,728-753,1176-1204`: max sequence gap 1000 and 8MiB raw payload. | **Yes.** Automatic snapshot fallback; enrichment carrying resolved roots is a patch, not an authoritative empty shell. |

## Lazy payload and client-only work

| Area | Source / change | Classification |
| --- | --- | --- |
| Existing omitted tool output and diffs | `WireProjection.ts:99-139,187-215,218-246`: command output stripped with `outputOmitted`, dynamic input/output summarized, file diffs omitted, handoff history stripped. On-demand `getTurnItem`, `subscribeCommandOutput`, turn/full diff RPCs remain. | Already supported: `App/Sources/ThreadSession.swift:108-125,244-255,285-303`. No new generic lazy-payload capability. Keep these demand-driven. Body dedupe is separate and must restore locally. |
| Deferred shell PR decoding | `state/shellPullRequests.ts:17-83`, `state/shellSnapshotHttp.ts:66-74`, `state/shell.ts:117-139,300-305`. No new RPC; the complete HTTP response already has links, decoded after first rows and merged only if still current. | Exists before comparison base. CandyWrapper uses off-main typed decoding, not this JS deferred decoder. No bandwidth benefit; do not confuse deferred decode with omitted wire fields. |
| Cache write suppression, `17dc1afa15` | `state/shell.ts:124-139` skips cursor-only writes when row/project arrays unchanged, including monotonic cursor; `state/server.ts:362-391,420-448` compares cacheable config excluding transient data. | Client-only, works on 3473. CandyWrapper reuses unchanged row encodings (`ShellCache.swift:145-150`) and retains project storage, but `ShellCache.noteChanged:93-98` still schedules writes; this is only partial adoption. Preserve lower-sequence authoritative resets. |
| Replacement scans, `7de9535a6c` | `state/orchestrationV2Projection.ts:37-50` records replaced index, consumers avoid full sort/ordering scans. | Client-only, works on 3473; not wire work. Existing native reducers need separate profiling, no automatic TS port. |
| Indexed thread search, `bb7783e295` | `packages/contracts/src/threadSearch.ts` and server `orchestration-v2/ThreadSearch.ts` in that commit. | New server optimizes existing search. Older-settled extension above is the portion required by lazy shells. |
| Task/workflow controls, `1ba3c781d0`, `3ff5b3c82a` | `threadHistoryPaging.ts:513-520` keeps active/latest task list and workflow control rows outside history selection. | Already in 3473. Do not trim control records merely because rows were omitted. |
| Frontend bundle/route/code highlighting and render memoization | Main contains web/mobile-only startup chunk warming, lazy routes, compiler changes, Pierre highlighting and row memoization. | No native wire action. Excludes HTML render attachment work, provider prompts, ordinary feature additions and unrelated Git/PR polling changes. |

## Implementation requirements

1. Fetch config once per actual connection and gate omissions at top-level. Cold loads and changed omission policies fetch the compressed HTTP shell with exactly those flags, then subscribe after its sequence. Failure falls back to a socket snapshot with matching flags. Retain CandyWrapper's efficient delta reconnect when an authoritative in-memory shell has the same negotiated omission policy. Do not resume a disk-only cache into a new session. After a verified warm resume, invalidate supplemental read generations and refresh stale counts while retaining the base cursor. This uses the allowance in upstream `connection-runtime.md:86-89`; its current `state/shell.ts:381-405` instead reloads HTTP on a new RPC session.
2. Keep the authoritative base shell separate from on-demand family/page/search rows. New authoritative snapshots invalidate the read generation and tombstones. A supplemental read never advances the shell stream cursor. Newer live updates/removals beat older read rows; read failures remain retryable.
3. Enable idle omissions only with family recovery and destructive-worktree read protection. Enable older-settled omissions only with shelf counts, paging, search hydration, and deep-link recovery. Never cold-prefetch all omitted threads.
4. ID expansion must precede typed decode; compact turn-item restoration and body restoration precede reduction and caching. Keep unmarked/legacy wire inputs valid. The report does not claim new-server features exist on 3473.
5. Validate legacy full shell, each capability combination, HTTP failure, reconnect/downgrade, partial cache policy mismatch, stale reads racing update/remove/reset, count-only changes, tied cursors, search hydration, and worktree lookup failure. No real data or accounts required.

## Native implementation notes

The lazy-shell change in this worktree adds the negotiated HTTP bootstrap, warm delta resume with matching omission policy, generation-bound family/page/search reads, and scoped shelf counts. `ShellStore.snapshot` remains the authoritative cache input; `displaySnapshot` overlays demand reads without moving the replay cursor. Supplemental-only changes publish to the UI without scheduling base-cache writes. The optimized shell cache encoder persists omission/cut metadata, so an offline partial cache cannot be mistaken for a complete list.

Open threads and the lineage controller retain/release families using **local wire IDs**. A family only contains active threads, so an absent family row is not a definitive deletion of an archived thread. Explicit live removals can retire a route; HTTP thread loading remains responsible for definite missing-thread results. Partial shells skip image-cache pruning and keep missing tab routes/titles. Worktree deletion checks the server's complete worktree ID list before offering cleanup and again immediately before removing the worktree; a failed lookup keeps the worktree.

The Settled shelf asks only for its current visible demand, by project scope. Each page has its own sequence; rows from a stale page cannot overwrite current rows or tombstones. Demand counts unique currently rendered settled rows, including live changes, so retained exceptions cannot be counted twice. Failures reset the attempted demand and allow another request. Search mounts rows only for the current query and shell generation. Count reads follow relevant changes, coalesce for 150ms, and retry only if a relevant event overtook their sequence. They do not run while idle.

Validation belongs to the focused lazy-shell/reducer/cache/sidebar tests here. The parent owns integrated app compilation, on-screen validation, the full suite and performance runs; no live server or live user data was used by this task.

Focused run: `scripts/test --filter 'LazyShellTests|ShellReducerPortTests|ShellCacheEncodingTests|SidebarTests|SidebarSearchTests'` passed 58 tests (32 store/cache tests and 26 sidebar tests). That initial build captured the first nine lazy-shell tests; the two supplemental-publication/unique-page tests and the two new sidebar count tests were added afterward and remain for the parent's integrated run. All edited Swift files passed syntax parsing and `git diff --check`. App type checking and on-screen checks were left to the parent as requested. Preflight briefly passed at 40 GB, then returned to 39 GB after compilation; no further build was started below the limit.

## Full commit registry

| Prefix | Full upstream SHA |
| --- | --- |
| `2b1d4fecb8` | `2b1d4fecb859b9a68f4853b8c4c5857ffe9d448d` |
| `b437ec1ab2` | `b437ec1ab256b108ea0b373cfb35d50f10e0427b` |
| `d9eb2b61c3` | `d9eb2b61c3899f1ade376fd00f1ebb7fd11cf47e` |
| `c7f8404d2e` | `c7f8404d2eadf5315ba9f4f0abbf96cfce138be0` |
| `94827737ea` | `94827737ea018902dd2e932cddb51643365dc446` |
| `6518c8243d` | `6518c8243dfa7f54476eff902f1197fd1203ffe8` |
| `c7e3993fe9` | `c7e3993fe9fb8e75ccfb1ac64fb360c130d91689` |
| `6ed47b538c` | `6ed47b538c1ac1d94043d96d3b1faf79c024811d` |
| `fd1063ba7c` | `fd1063ba7c452e2a938484277235afebf0639119` |
| `d7a8d6f320` | `d7a8d6f32001444e013aa07c8a468ce3e987f9cf` |
| `27e0c684c5` | `27e0c684c585f955252d65f06206dd11a143bff5` |
| `553203c57b` | `553203c57b780cef9fb30ad835d759befe0dcb7c` |
| `67c3afbd58` | `67c3afbd58e72d088fec7af69d52dd255a00199e` |
| `e19fe0837b` | `e19fe0837b6eaba1c61a779dac335be281a93ded` |
| `80455376f0` | `80455376f01f19c10a06dc08b0629486c017bf79` |
| `e57c093cdd` | `e57c093cdd9032355c6251dd7192280b915b7a23` |
| `17dc1afa15` | `17dc1afa15980c72a790271034e3cb13ccf810c6` |
| `7de9535a6c` | `7de9535a6c7b8d9eaa5b692a749da4f332a070db` |
| `bb7783e295` | `bb7783e295506ad423f527ed28a019836e331e8c` |
| `3ff5b3c82a` | `3ff5b3c82a62baddc0c2b1b227e9d3a06190c426` |
| `1ba3c781d0` | `1ba3c781d04a0694ec1277ddf386b658b93d765f` |
