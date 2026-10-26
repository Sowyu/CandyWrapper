# Thread payload restoration

Source: upstream `origin/main` at `5b35402623` (2026-10-25). Read from the separate source tree, without changing the pinned checkout. This change covers thread payloads only.

## Contract

- `packages/contracts/src/orchestrationV2.ts:3500-3508` adds `acceptDedupedBodies` and `acceptCompactIds` to thread subscription input. The ID table wraps bounded snapshots at `:3527-3545`, history pages at `:3549-3563`, and stream snapshots at `:3611-3640`. Stream events do not use an ID table.
- `packages/contracts/src/orchestrationV2IdTable.ts:5-8`, `:60-90`, `:114-132` defines exactly which slots expand: each object or array record immediately inside the selected container, and recursively only its `item` member. Expand numeric values under `id` and keys ending in `Id`, and numeric entries under keys ending in `Ids`. Leave nested lineage, model options, provider values, tool inputs and outputs unchanged. A table can restore a numeric ID as well as a string. Consume `ids` so a second decode cannot interpret a restored numeric ID as an index.
- `packages/shared/src/orchestrationV2DedupedBodies.ts:20-119` restores message text, checkpoint files, and subagent prompt/result fields using explicit omitted markers. `:124-183` uses snapshot records for local rows and turn items; inherited rows have no source records in that projection.
- `apps/server/src/orchestration-v2/WireProjection.ts:251-309` remembers the last 32 message, checkpoint and subagent bodies independently. The source follows transport arrival order, including records that the reducer later ignores as stale. Subagent record updates can omit bodies too. The turn item itself never becomes a source record.
- `apps/server/src/ws.ts:794-797`, `:889-910` shares one deduper across snapshot/replay/live delivery within each subscription, after event coalescing.
- `packages/client-runtime/src/state/boundedThreadSnapshotHttp.ts:31-34` requests `compactTurnItems=1&dedupeBodies=1&compactIds=1`. `state/threadHistoryHttp.ts:27-34` requests only `compactIds=1` for history. `state/threads.ts:959-970` advertises the socket flags.

## CandyWrapper behavior

`ThreadDetailSnapshot` restores IDs and omitted bodies before exposing a projection. `ThreadHistoryPage` restores IDs before compatible-row decoding. Neither decoder retains transport markers. Requests use the upstream opt-ins only for these supported payloads; older servers can ignore unknown flags and continue returning their existing representation.

`ThreadStore.applyWire` uses `ThreadWireRestorer` before typed event decoding, reduction and persistence. It retains at most 32 records per body kind and follows delivery order independently of event sequence filtering or partial-window row filtering. Snapshot resets and HTTP/cache seeds replace its body sources. Reopening a retained store preserves them. Snapshot restoration uses all snapshot records before retaining only the last 32 for live events.

Invalid indices, missing source bodies and unrestored markers throw `DecodingError`; they never enter a reducer as blank content. Restoration commits its source changes only after typed decoding succeeds. This intentionally rejects missing-body markers where upstream's pure helper would leave the marker in place (`orchestrationV2DedupedBodies.ts:57-60`). `resetForResynchronization` clears the sources and resume sequence, retaining the visible projection until a fresh snapshot arrives. Callers must propagate a wire error to the supervisor and reset before retrying.

Only `ThreadStore.subscribeInput` enables the new flags; standalone reducer input and manually constructed protocol inputs leave them absent by default. Every app subscription using those flags must feed raw values through `applyWire`. The parent task owns those app changes and stream retry handling.

## Validation boundary

Protocol tests exercise exact ID slot expansion, numeric IDs, invalid optional references, combined compact snapshot decoding, history pages, every omitted body kind and marker removal. Store tests cover stale records, reconnect payloads, cache/HTTP seeding, partial windows and snapshot recovery. Existing recorded legacy streams remain covered. This implementation does not change shell payloads, HTTP bootstrap selection, app session wiring or server versions. End-to-end two-server measurements and whole-app checks belong to the parent task.

Focused validation passed: `scripts/test --filter 'ThreadPayloadRestorationTests|ThreadWireStoreTests|ThreadStreamDecodingTests|ThreadReducerTests|ThreadCacheTests'`, 40 tests across five suites. The run used the repository wrapper in the background with a 30-minute limit. Existing unrelated compiler warnings remain. `ThreadStore.applyWire` includes the existing `typed decode` timing span for comparisons with the parent task's measurements.

The first implementation commit (`75bcafdb`) also passed `scripts/test --fast`: 1,863 Swift Testing tests and 18 XCTest tests.

## Subscription ownership

The keep-alive handoff cancels its subscription task without awaiting completion (`App/Sources/RunningThreadKeepAlive.swift:103-107`). The supervisor awaits each handler, but cancellation cannot revoke an already queued actor call (`Packages/CandyKit/Sources/T3Client/ConnectionSupervisor.swift:632-635` before the parent task's retry changes). Actor serialization alone allows an old subscription's source record to land between a successor's record and its omitted item. The reducer can skip the old sequence while the transport restorer has already replaced the source body.

Each durable subscription can now supply one captured UUID to `subscribeInput`, `applyWire`, `applySnapshot` and `resetForResynchronization`. `subscribeInput` claims ownership before any HTTP bootstrap and reseeds the body sources from retained data when the owner changes. Subsequent callbacks and resets with a stale nonnil UUID return before restoration or state changes. A cancelled payload task cannot reclaim ownership after a delayed HTTP bootstrap. Keep the same UUID across retries; a reset clears sources and cursor without changing ownership, so rebuilding the retry input cannot accidentally reseed invalidated sources. Legacy nil callers keep their existing behavior. The parent task owns passing the UUID through every app caller, including typed HTTP snapshot application.

Ownership validation passed: `scripts/test --filter 'ThreadWireStoreTests|ThreadReducerTests|ThreadCacheTests'`, 27 tests across three suites. The new cases exercise late source events, malformed and valid old stream snapshots, typed old HTTP snapshots, stale recovery resets and a cancelled delayed payload claiming an old UUID. No second broad run was started; the parent task owns integrated fast/full validation.
