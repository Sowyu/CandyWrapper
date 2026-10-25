# Fast-load implementation review

The review follows upstream `5b35402623` and the compatibility matrix in [the upstream audit](t3-fast-load-upstream.md). Measurements belong in the [final benchmark report](../perf/2026-10-25-fast-load.md); the [first diagnostic](../perf/2026-10-25-fast-load-initial.md) exposed the extra config RPC and remains available with its original raw records.

## Wire and state

- ID expansion follows the contract's record boundaries. Tool input/output, lineage and provider payloads remain opaque. Bad table references fail before typed reduction.
- Snapshot bodies restore from complete message, checkpoint and subagent records. Stream bodies follow transport arrival order, including replay records that the reducer skips. Their memory is bounded to the server's 32-record limit per body kind.
- All five app thread subscriptions use restoration: the visible thread, Orchestrator, background keepalive, lineage observer and prompt-rewind observer. Subscription ownership prevents cancelled predecessors from altering body sources, snapshots or cursors. Invalid restoration clears the cursor and requests a new snapshot while retaining the visible state.
- HTTP and disk snapshots seed the same body sources. Paging preserves opaque cursors, local ordinal watermarks and stale-request checks. Restored bodies, rather than omission markers, reach caches and views.

## Shell and lifetime

- Shell omissions require advertised config flags, with family support also required for older settled omissions. HTTP and socket snapshots use the same policy. Disk shells are paint-only until authoritative synchronization; matching in-memory shells retain replay cursors.
- Supplemental family, page and search reads have separate lifetimes and never advance the shell cursor or enter its disk cache. Snapshot generations and live update/removal sequences reject stale reads. Count-only changes can invalidate sidebar rows without changing thread arrays.
- Settled counts subtract retained exceptions once. Paging counts unique current settled rows, handles tied cursors and replenishes the visible prefix after live changes. Sidebar/palette search and composer title search recover omitted matches. Deep links do not mistake a partial shell for deletion.
- Worktree cleanup checks the server's complete owner list when shells are partial and keeps a worktree when the read fails.
- The shell shares the composer's supervised config stream. Descriptor-version reuse avoids another negotiation round trip on matching retained connections; fresh config still catches policy changes, including development builds with unchanged version strings. A failed initial config stream permits full-shell fallback.
- Startup cancellation, generation changes and stop release initial-config waiters and listeners. No new idle timer, ping loop, browser view or retained hidden view was added. Empty demand reads return without scanning a legacy full shell.

## History demand after the smaller window

The first on-screen check exposed a native paging guard that keyed demand only by the first rendered row. Main can start inside a long agent turn (`apps/server/src/orchestration-v2/threadHistoryPaging.ts:15`), and later pages can add tools beneath that same folded turn header. The guard now rearms when the history cursor advances. An upward wheel also asks for history when the collapsed window fits without moving its clip bounds. Unchanged cursors keep one outstanding demand; the session/store still enforce loading and completion guards. The Orchestrator's separate earlier-history control already follows its history metadata and needs no UI change.

Upstream keeps its Load earlier control available while history remains (`apps/web/src/components/chat/MessagesTimeline.tsx:1179-1192`) and keys repeated citation paging by cursor before entry identity (`useAssistantCitationTarget.ts:98-107`), all at `5b35402623`. The regression exercises real AppKit wheel events on a collapsed, non-scrolling window, unchanged cursor updates and a second page under the same fold.

## Validation record

The initial protocol focused run passed 40 tests, the subscription-ownership follow-up passed 27, and shell-focused runs passed 58. Integration corrected the new sidebar fixture's missing clock argument and its mistaken assumption that a pin outranks settlement; the fixture now uses a future snooze, matching upstream shelf precedence.

The fast lane on the measured core `341775ef` passed 1,892 Swift Testing tests and 18 XCTest tests. After the on-screen paging fix, all five timeline tiling tests passed and the fast lane passed again with 1,893 Swift Testing tests and 18 XCTest tests. The full serial run completed 2,071 Swift Testing tests and 18 XCTest tests, with one issue in the pre-existing `FrameDecoderTests.deliversNewestFrame` coalescing assertion. All 1,068 Features and 141 DesignSystem tests passed, including fidelity suites. The same FrameDecoder timing issue is recorded in `PROGRESS.md`. Both FrameDecoder tests passed in an isolated recheck, and the final fast lane also passed after the startup-cancellation guards and empty-demand fast paths. The full suite preceded those small final changes.

No fidelity reference, ceiling, app version or installed T3 runtime changed. The final Debug app build passed, and its isolated test bundle passed signature verification. The rebuilt app passed the on-screen paging check: fourteen history requests reached the first synthetic messages and the last response reported no more history. Dark and light windows rendered nonblank bodies. The Settled shelf showed 1,000 threads, Show more revealed another page, sidebar search recovered an omitted settled thread, and composer `@082` offered and inserted its thread chip without sending a turn. The 3473 app run loaded the big thread with its older initial window. Captures and logs remain outside Git under `~/CandyWrapper-research/notes/t3-fast-load` and `/tmp/cw-fast-load-ui-*.log`.

The accepted matrix passed all twelve runs with matching full-history hashes. The report preserves both cold readiness regressions and the byte savings. The performance review remains before completion. The UI test bundles, disposable Node source archive and all four owned sandbox server/proxy processes were removed or stopped after validation; source pins, synthetic homes and committed raw measurements remain.
