# Thread responsiveness and correctness audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

Reviewed 2026-10-26 at `0ced803c3ec141b3a58ab31e5bc401d6f61a06e3`. Scope: thread selection and loading, `ThreadSession`, thread store/reduction/cache, incremental timeline derivation, virtualization, and Markdown loading. Product code and visual design are unchanged. No compiler, tests, app, server, shared screen, live data, or account was used. Findings below are source-traced, with unexecuted opt-in reproductions for the parent to validate.

Local upstream source is `~/CandyWrapper-research/t3code`, at `v0.1.2-nightly.20261021.3473`, matching `T3_VERSION`. Upstream citations below are relative to that checkout. Some older native comments cite a different upstream revision; I checked current upstream code rather than treating those comments as proof.

## New findings

### T1. P2: one failed history request disables further automatic paging

Reachable during ordinary scrolling through a bounded thread. `TimelineView.requestEarlierIfNearTop` consumes its demand before invoking the loader, remembering only the first row ID (`Packages/CandyKit/Sources/Features/Thread/TimelineView.swift:657-662`). It rearms when the history cursor changes (`:65-66`) or another thread's rows apply (`:355-357`). Leaving the top and returning does not clear this latch.

Trigger: scroll upward to request an older page, then let HTTP time out, fail, or be cancelled during a shell replacement. `ThreadSession.loadEarlier` resets the task and records failure/cancellation (`App/Sources/ThreadSession.swift:202-235`). The reducer clears loading and keeps the same cursor (`Packages/CandyKit/Sources/T3Store/ThreadReducer.swift:407-422`). `ThreadSession.render` passes only `historyCursor` to the timeline, and never displays `history.error` or a retry control (`App/Sources/ThreadSession.swift:168-178`). The unchanged cursor therefore leaves demand consumed. More wheel gestures, including moving away and back, cannot request the page while the first row stays unchanged. Ordinary automatic paging silently stops. A thread switch/reopen can recover; a search reveal also has a separate direct loader path (`ThreadPanelView.swift:333-339`).

Upstream explicitly keeps Load earlier available while history remains, disables it only while loading, and displays errors (`apps/web/src/components/chat/MessagesTimeline.tsx:1144-1169`). Its cursor equality helper also retains the cursor on failure (`packages/client-runtime/src/state/threadHistoryMerge.ts:25-39`), so a native retry must come from the UI demand lifecycle.

Reproduction: `ThreadResponsivenessAuditRegressions.failedHistoryDemandCanRetryTheSameCursor`. It uses a real reducer failure and the upward-wheel callback, mirroring the history field that the session forwards. Expected current failure: request count stays 1 instead of reaching 2. No network or window is needed. Not executed.

### T2. P2: large thread replacement enables the previous thread's rows before replacement

Reachable when switching between threads in one environment and the incoming projection contains at least 1,500 visible items, usually after retained history expansion or a legacy full snapshot. The switch intentionally holds the old rows inert (`App/Sources/ThreadSession.swift:960-982`; `Packages/CandyKit/Sources/Features/Thread/ThreadPanelView.swift:1371-1379`).

On the new projection, `ThreadPanelView.setProjection` clears both `switchingThread` and `timeline.isInert` immediately (`:1397-1398`), updates the header and workspace, then calls `model.setProjection` (`:1401-1427`). The model replaces its projection and worker generation (`Packages/CandyKit/Sources/Features/Thread/ThreadViewModel.swift:285-304`), but derives the large replacement on a detached task (`:397-405`). Its old `items`, and the timeline's old row views, remain until `finishRows` applies the result (`:408-418`, `:427-442`). The main actor can process input during that interval. `TimelineView.hitTest` blocks held-row input only while `isInert` is true (`TimelineView.swift:28-31`).

User effect: the new thread title and model coexist with clickable old messages and actions. For example, the old user row sends its message to the current model's edit callback (`TimelineMessageRows.swift:166-168`), which enters the current composer's rewind path (`App/Sources/ComposerController.swift:4566-4578`). File chips and other row actions also remain exposed. A wrong-thread destructive action is not established: downstream checkpoint/provider guards can reject it. The confirmed source-level defect is the loss of input isolation while the rows still belong to another thread. Duration depends on derivation and main-thread scheduling and was not measured here.

Upstream determines whether entries belong to the active thread (`apps/web/src/components/ChatView.tsx:2142-2152`) and passes `paintOnly` and guarded actions into its timeline (`:6654-6692`). The native implementation needs to hold input isolation through its additional asynchronous derivation stage.

Reproduction: `ThreadResponsivenessAuditRegressions.oldRowsStayInertUntilNewRowsAreApplied`. It forces the existing background branch with threshold 0 to make the intermediate state deterministic using small recorded projections. Before yielding the main actor, it verifies the replacement task exists and old rows remain, then expects inertness. Expected current failure: inertness is already false. It also checks replacement settles consistently. Not executed.

## Existing findings revalidated

- First-open Markdown stalls remain a known issue, not a new finding. `docs/perf/README.md:164-171` records the old 0.13 s parse of a 1.1 MB reply. Current `TimelineContext` is main-actor isolated (`TimelineRowSupport.swift:94-96`); cache misses still parse synchronously (`:126-158`). The first eight large settled texts can be reused, but a cold body or a ninth distinct large body misses. Assistant row configuration invokes this directly (`TimelineMessageRows.swift:605`), and visible/overscan rows measure during `TimelineView.tile` (`:711-723`). Background row derivation does not move Markdown parsing or layout off main. The old timing is historical evidence, not a new measurement.
- The October 18 audit's protected timeline-worker ownership still holds. A thread change allocates a new `TimelinePipeline`, increments generation, and ignores old results (`ThreadViewModel.swift:290-295`, `:408-409`). I found no new simultaneous use of the same pipeline across thread generations. T2 concerns the visible interval before the new generation applies, not stale results overwriting it.
- The October 25 paging fix covers cursor advancement within one folded row (`TimelineView.swift:65-66`, `:232-235`; existing `TimelineTilingTests.swift:139-176`). T1 is its failure/retry gap, not a repeat of the successful-page issue.
- Subscription ownership guards still reject replaced streams before restoration and snapshot mutation (`ThreadStore.swift:82-101`, `:123-126`). History page merging retains current visible values rather than overwriting live updates with old page copies (`ThreadReducer.swift:227-240`), matching upstream `packages/client-runtime/src/state/threadHistoryMerge.ts:60-86`. This review established no new lost-live-update defect in that path.
- The October 24 benchmark drift remains unresolved. `docs/perf/2026-10-24-6f6f14b-w1.md:53-59` already establishes that unchanged measured sources and a binary without SpaceLocal retained flags in a new process. Its fresh recheck reported cache write 46.6 ms versus 34.0 ms and load 36.6 ms versus 27.7 ms (`:84-85`). This audit did not rerun or assign a new cause. The later fast-load report records changed metrics and no threshold flags against its own newer baseline (`docs/research/fast-load-review-2026-10-25.md:37`); that does not resolve the October 23 comparison.

## Added execution entry points

`Packages/CandyKit/Tests/FeaturesTests/ThreadResponsivenessAuditTests.swift` adds two separately gated suites. Both are off by default. The regression suite intentionally asserts desired behavior and is expected to fail on the audited source. The stress suite measures actual cold parser and layout calls with 64 KiB, 256 KiB, and 1 MiB generated bodies: mixed headings, code, tables, lists, reference links, and a single long paragraph with soft breaks. Each cell has 21 samples and emits raw values plus nearest-rank p50/p95/p99/max. At this sample count p99 equals the maximum; this is a bounded screening tool, not a tail-latency study. Fixtures and strings are built outside timing, caches are bypassed, and these are main-actor parse/layout durations, not end-to-end UI timings.

Parent commands, from its execution checkout after cherry-picking:

```sh
CW_THREAD_AUDIT_REGRESSIONS=1 scripts/test --filter ThreadResponsivenessAuditRegressions
CW_THREAD_AUDIT_STRESS=1 scripts/test -c release -Xswiftc -enable-testing --filter ThreadResponsivenessAuditStress
scripts/test --filter 'TimelinePipelineTests|TimelineTilingTests|ThreadWireStoreTests|ThreadCacheTests|IncrementalTimelineTests|MarkdownIncrementalTests'
CW_BENCH=1 scripts/test -c release -Xswiftc -enable-testing --filter PerfBenchmarks
```

Run serially with the parent's usual 30-minute process limit. These commands were not executed here. No passing test or fresh latency result is claimed. Source/diff review and `git diff --check` are the only local validation.

## Remaining coverage and useful stress scenarios

No sandbox, reconnect transport, GUI, disk cache corruption, or percentile measurements ran in this worktree. The opt-in tests require parent compilation and execution; App-target `ThreadSession` is source-traced because CandyKit tests do not exercise its lifecycle directly.

Useful centralized trials:

1. Fail precisely one history HTTP request in a proxy, then restore service and scroll away/back. Confirm the missing retry and absent error. Repeat with shell replacement while paging.
2. Retain two expanded 5,000-item threads and alternate them rapidly with CPU contention. Record time from new header to replacement rows, and whether hit testing or a file-chip action is enabled during that interval. Use sandbox-only file paths.
3. While paging, deliver a newer overlapping live row, duplicate event, and reconnect snapshot; verify newest content survives and the opaque history cursor advances only for the accepted request. Repeat after a compact body restoration error.
4. Open nine distinct 1 MiB answers, revisit the first, then resize while streaming a reference-link-heavy answer. Compare cold/revisit p50/p95/p99 with an ordinary bounded snapshot; 1,500-row background selection alone does not cover body size.
5. Repeat old and new Release benchmark binaries in interleaved fresh processes with identical fixture counts and bytes. `PerfBenchmarks.swift:64-70` pins its recording set; `:399-405` constructs bounded/full windows, and the helper at `:20-33` reports medians rather than tail percentiles. Preserve that workload for drift comparison and use the new stress suite as a separate series.

No product repair is included. The parent should execute the regressions before treating these source traces as reproduced bugs.
