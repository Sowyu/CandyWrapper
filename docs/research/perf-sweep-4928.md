# Perf sweep of Nightly 4928 (thread-3, 2026-11-19)

Every `perf(` commit in [the 4928 commit list](nightly-diff-4928-commits.md), plus the fix commits whose subject is about speed, freezes, leaks or wasted requests. For each I read what T3 changed and looked for the same cause in CandyWrapper. T3's fixes are mostly for React re-renders, and CandyWrapper has no React, so most do not apply.

Counts: 116 commits read, 115 from the 4928 range plus #26240 from 3824, which the task named. In the 4928 range 13 have the same cause in CandyWrapper: 11 are ported and 2 are left with what they need. 17 were already fixed in CandyWrapper or have an equivalent, 3 were not checked, and 82 do not apply.

## How it was measured

Micro-benchmarks run with `CW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PerfBenchmarks` in `Packages/CandyKit`, base (`catchup-4928`) and branch alternately, three rounds each, from frozen worktrees so no edit landed between rounds. The benchmark file is the branch's in both. The tables give the median of the three round medians, the range of the round medians, and the 1-minute load average at the start of each round. A change counts as real only when the two ranges do not overlap. Numbers are in [Measurements](#measurements).

## Ported

| Commit | What T3 fixed | Same cause in CandyWrapper | What I did | Number |
|---|---|---|---|---|
| 3f105e00e3 #21277 | Subagent previews squashed the whole result before cutting it to 280 characters | `SubagentCardRowView.swift:95-96` ran a whitespace regex over the whole result for the hover detail | `hoverPreview` reads only as far as the cut | Correctness and bounded work; not benchmarked |
| 24467d671d #38368 | A subagent prompt that opens with `////` divider lines froze the thread | `TimelineEntries.swift:139` had the same backtracking pattern in ICU; 24 slashes took 58 ms, 28 took 773 ms | T3's one-way comment pattern | `workflow_script_dividers` 57.6 to 0.001 ms |
| 3d12c90ea8 #34340 | File link labels compared every same-named path with every other | `FileLinks.parentSuffixes` (FileLinks.swift:161-185) scanned all paths per path and depth | One count of every suffix | `file_link_labels_800` 106.7 to 3.3 ms |
| 2dc07510e2 #30038 | Long reasoning previews formatted in quadratic time | Not the same code: `liveThoughtLine` (WorkLogText.swift:105) ran five Swift Regex passes over the whole thought on every update of the live row | It reads the first 1,024 characters, cut at a space | `thought_line_64k` 38.3 to 0.85 ms |
| d61058debf #29008 | Inline `$skill` lookups searched the skill list per token | `MarkdownInlineSkills.runs` (MarkdownInlineSkills.swift:15) did `skills.first(where:)` per token | One name table per document, first name wins | `inline_skills_500` 1.31 to 0.83 ms |
| a6a921c763 #29105 | Streamed updates rescanned question history | `projectingQuestionHistory` (TimelineEntries.swift:240-262) rebuilt every answered question item and copied the rows on every derive, streamed words included | Answered items kept per row while item and request stay the same | `huge_update_stream_answered_entries` 4.05 to 3.80 ms, ranges overlap: not counted |
| 0a86e157a0 #28965 | Visibility built its tables on every status update | `ThreadReduction.isVisible` (ThreadReducer.swift:93) built a map of every run and scanned every item on every streamed turn item | T3's fast path for `visibility`, and a one-item lookup for `isVisible` | `huge_reduce_stream` 2.64 to 1.03 ms per streamed word; `thread_reducer` 0.42 to 0.32 ms |
| 05020d6fa9 #34002 | Reopening a finished command row fetched its output again | `WorkRowView.syncCommandStreams` (TimelineWorkRows.swift:287-300) dropped the output when the row closed or recycled | Finished output stays 5 minutes after its row stops showing it, at most 64 KB each (CommandOutputBuffer's cap) | One `subscribeCommandOutput` per reopen fewer; correctness test only |
| a4b6afe184 #27440 | Threads with many images flooded a remote with URL requests | `MarkdownImages.signedURL` (MarkdownMedia.swift:178-184) signed every image a row showed at once | `AssetURLLimit`: 6 `assets.createUrl` in flight, a cancelled waiter gives its turn back | Correctness; test checks the cap of 6 |
| 6879da849a #28537 | Plan prefixes stripped with repeated `shift()` | `ProposedPlanActions.displayed` (ProposedPlanActions.swift:16-25) called `removeFirst` on an Array in a loop | An ArraySlice | Correctness; leading blank lines only |
| 89c2a5c4dd #29114 | Expanding deferred work skipped an unused rebuild | Came with deferred work, which CandyWrapper lacked | Ported with deferred work: a work page merges at the anchor only (ThreadReducer `mergeOlderHistory`) | With #26240 below |
| d2429f733c #26240 (3824) | Long threads send folded work groups as one row | CandyWrapper never asked, so it got every row | Ported, see [Deferred work](#deferred-work) | `long_work_*`, see [Deferred work](#deferred-work) |

Not ported though the cause is there:

- 1915569b19 #18416, shell deltas merged once per batch: `ShellSession` hands `ShellStore.apply` one item at a time (ShellSession.swift:274), and the store publishes once per pull, so the redraw is already once per batch, but the reducer merges row by row. It needs a shell benchmark with a 50-event chunk first.
- ebfca09e91 #29971, work-row checks cached per entry: CandyWrapper caches the failure checks per item revision (WorkLog.swift:371-388), but `toolGroupAction` runs again on every row pass (TimelineRows.swift:1001-1011, WorkLog.swift:599, 685). The row pass for a tool update on the huge thread is 67 ms off the main thread; profile it before caching.

## Already in CandyWrapper or equivalent

| Commit | What T3 fixed | CandyWrapper |
|---|---|---|
| 29f33af7d7 #26727 | Long-thread timeline rebuilds and tool updates | Entries are memoized per row and only changed rows rebuild (TimelineEntries.swift:371-470); tool updates included |
| d8c926c395 #27417 | Streaming replies re-render only their last Markdown block | Incremental streaming parse and layout reuse (`markdown_stream_delta_incremental` 0.7 ms) |
| 3cbc98241d #27419, 5cbc207d8c #27420 | Streamed text re-rendered every row | `TimelineChange` hands the view only changed rows; the streaming patch skips the row pass |
| 78fba059a1 #27480 | Revisiting a thread reuses its Markdown | Retained thread stores for 5 minutes, and settled texts over 32 KB come from a process cache (`TimelineContext.cachedSettled`); shorter ones parse again, under 30 ms each |
| bb9658d3a7 #26935 | Command output failure scan in one pass | One ICU alternation, cached per item revision (WorkLogText.swift:77-90, WorkLog.swift:371) |
| 65ffcbf647 #33438 | Escaped Markdown in long PR descriptions | `keepingWindowsPathEscapes` is a linear byte scan that skips text without a drive path (MarkdownDocument.swift:86) |
| ea95364640 #25258 | Checkpoint answers indexed in one scan | `TurnDiffs.summaries` finds each run's last answer in one pass (TurnDiffs.swift:45-60) |
| ad0b2a9d2f #27425 | Streamed text republished the queue and checkpoints | A streaming-only update skips the composer, lineage and cost (ThreadSession.swift:1153-1158) |
| 2482b03a01 #35071 | Threads load while the socket connects | Covered by connection: `startEarlyShellLoad` and the bounded HTTP snapshot behind the socket ([comparison](connection-vs-t3-desktop-4928.md)) |
| 7f39a860d9 #27110 | Huge checkpoints ship smaller | Server side; CandyWrapper reads `filesTotal` (protocol.md, Nightly 4928 changes) |
| b9522c845b #23758 | Big config on a slow link dropped the connection | `frameParts=1` and per-part liveness (connection) |
| 8851e307d8 #24309, 7c22095fcc #34623 | Slow probes and stalled reconnects | Connection and connection-2 |
| cf60628ef9 #25213 | Cache running threads when their view closes | `RunningThreadKeepAlive` and the 2 retained stores |
| 077fd62222 #33503 | Finishing a long background thread froze the app | Row passes over 1,500 rows run off the main thread (`ThreadViewModel.derive`) |
| 984fe2d45e #32179 | Usage-limit support scanned per provider per update | The server adds the usage-limits command when the config asks with `usageLimitsCommand` (ProviderWorkspaceSnapshots.swift:23), so there is no client scan |

## Does not apply

React re-render work, which CandyWrapper's AppKit views don't do: aaee7743f8 #27418, cb9629e689 #27823, aa0b3e2da6 #27795, 11df0cbc4a #27808, 2f777bdd49 #28264, 39bca5365c #28267, 35df72f268 #28270, 0c0de57dfd #28563, bcc6c08d75 #28564, 30084f0018 #27833, c1463af205 #28571, a0056dddb1 #29150, 44a8e9541b #34964, 56fd98be52 #36166, 4c2f04d35d #24055, dd5061364b #33794, f968db10d7 #33435, a6d7695064 #36995, e2afd2546e #32323, 4117bd42ec #32324, bd907328f3 #27404, facd190640 #33129, 0da2bb625c #26720.

Web libraries CandyWrapper doesn't ship: 5b357b3b89 #27685 (the remark parser), d1049c4435 #26717 (ghostty WASM), d8a829e5ec #29626 and a03f7185f2 #33956 and ff045198dc #35666 (pdf.js), 37022730ba #23569 (web favicons), e9485df152 #22340 (web upload bytes), 21483318f2 #18421 (web file tree), 47f2e91210 #37001 (DOM text measuring), 1c86881dd5 #31465 (web diff file tree), d38055656e #34301 (TAR previews), dca297cd1a #29171 (CandyWrapper discovers fonts once per page, audit 2026-10-16), 2abf7be914 #35255 (web scroll gaps), 6ea5af70ad #34397 and 6ef66b6cd1 #28539 and e8b0856870 #27041 and c2985a7cb5 #26691 and 8cb9182021 #23779 (web terminal; CandyWrapper uses SwiftTerm), 9504a09f08 #26936 and acad1d5a08 #28930 (palette search, Features/CommandPalette, another agent's area; noted for it), 8a18bbf281 #27818 (Effect settings decoding), 66e96e52a4 #30679 (Effect tracing), cddfc8db21 #30714 (web path search bounding).

Not checked, with what each needs: e4d1edaabd #27073 (compact changed-file folders once) needs a look at the tree builder behind `ChangedFilesCardView`; a98b6245eb #27467 and f981b7a226 #27460 (inbox snapshots) need a look at whether `ThreadNotifications` serializes anything per update.

Server, mobile, desktop shell or another agent's area: a96bb81049 #37002 (right panel PR tab target, another agent), 7fab4ef978 #33993 (Usage page), e1494ae25b #25761, d5a50a1d0d #32774, 238678951a #32842, 4b22bb47d4 #32911, 0ea3c0243f #27798 (pull requests, another agent), 5958d00ede #35346 (ported by settings-3), c9f0caca1b #33942 (terminal attach paging, needs the wire), facaa08b36 #27097, 0200dcf242 #27979, 0d809db501 #32947, 0c4454ca6a #29026, cedaa0de48 #19288, b7d33af938 #32927, 4596872940 #35865, c7ce74fce6 #38544, d06eaff2f4 #38707, ce268642cc #35728, 65e4272db1 #36327, c03f84bcde #34030, 32c069eed1 #33138, f6d196463c #37872, 48359de5f4 #38025 (server), 2917f28465 #28487, 9557ab46c5 #32287, 445efb6dfc #31998, dc3fdc6a3e #33306, 8b2763f638 #35072 (mobile), 3776dfb4ea #22747, 96a2f0a776 #27426, 6c3d23dcfc #29264, d353fba97e #26244 (desktop installers), 6a29d58d14 #38493 (issues, another agent), f05cd350d2 #29996 (Files panel, another agent), e5b5da3a7c #27550 (diff guides, another agent).

## Deferred work

A 4928 server folds a settled run's work group of more than 150 rows into its first row with a `deferredWork` cursor when the client asks (`deferWorkHistoryRows`, threadHistoryPaging.ts:224-262). CandyWrapper now asks on the bounded snapshot, plain history pages and the subscription, shows the turn or attempt fold without those rows, and loads them with `view: "work"` pages when the fold opens, merged between the anchor and the group's last ordinal.

The benchmark thread is the huge thread's bounded window with one settled run of 600 commands added (`longWorkFrame`), each with a short command and 12 output lines. `DeferredWorkTests.anOpenedGroupMatchesTheFullThread` checks that the folded snapshot plus its two pages gives exactly the full thread's rows, so nothing is missing when a group opens.

The 3824 and 4928 sandboxes both answer `deferWork=1` with 200. The 4928 sandbox's longest thread has 97 items, under the 150-row fold, so its snapshot is the same 110,515 bytes either way; a real fold needs a run of more than 150 tool calls, which I did not spend a turn on.

## Measurements

Two sets of three alternating rounds. Set A measured the commit with the thought line at 4,096 characters, the workflow check, file links and the subagent preview, at load averages 2.5 to 15.9. Set B measured the final ports, at load averages 2.9 to 4.7. Times are the median of the three round medians in ms, with the range of the round medians.

| Benchmark | Base | Branch | Real |
|---|---|---|---|
| `workflow_script_dividers` (24 slashes) | 57.3 (56.4 to 59.1) | 0.001 | yes |
| `file_link_labels_800` | 106.9 (106.5 to 110.2) | 3.25 (3.23 to 3.26) | yes |
| `thought_line_64k`, 4,096 characters (set A) | 37.9 (37.6 to 38.0) | 2.70 (2.67 to 4.22) | yes |
| `thought_line_64k`, 1,024 characters (set B) | 38.3 (37.3 to 67.7) | 0.85 (0.84 to 0.86) | yes |
| `inline_skills_500` | 1.31 (1.28 to 1.39) | 0.83 (0.83 to 0.87) | yes |
| `huge_reduce_stream` | 2.64 (2.46 to 2.67) | 1.03 (1.01 to 1.06) | yes |
| `thread_reducer` | 0.42 (0.40 to 0.42) | 0.32 (0.32 to 0.34) | yes |
| `huge_update_stream_answered_entries` | 4.05 (3.75 to 4.22) | 3.80 (3.77 to 3.81) | no |
| `huge_update_stream` | 2.62 (2.40 to 2.83) | 2.38 (2.35 to 2.45) | no |
| `huge_update_stream_rows_patch` | 0.044 (0.043 to 0.047) | 0.042 (0.042 to 0.044) | no |

Set A caught two regressions in the branch, both fixed before set B. The streaming patch went from 0.042 to 0.058 ms because a new `deferredWorkItemIds` field on every `TimelineRow` made each row copy retain one more reference; the anchors now sit in the fold's boxed payload. The deferred derive went from 0.31 to 0.385 ms because each fold scanned every entry; the anchors are now found once per pass.

`markdown_parse_lines` read 49.1 against 47.4 ms in set B with ranges apart. Nothing in the branch touches that parse beyond a guard that returns at once for text without links, so I take it as noise.

### Deferred work, same rounds (set B, branch)

| Stage | Full (600 command rows) | Deferred (one anchor) |
|---|---|---|
| Frame bytes | 9,266,989 | 8,294,338 |
| parse | 26.7 (26.3 to 27.0) | 22.9 (22.8 to 25.0) |
| decode | 24.4 (23.2 to 25.4) | 20.3 (19.8 to 20.8) |
| entries | 3.39 (3.23 to 3.47) | 1.85 (1.79 to 1.88) |
| derive | 5.38 (5.28 to 5.62) | 0.32 (0.32 to 0.33) |
| panel (first layout at 1200x800) | 20.5 (20.2 to 22.3) | 14.7 (14.7 to 14.9) |
| Sum | 80.4 | 60.1 |

The thread moves 972,651 bytes less, 10.5% of a frame that carries 900 runs of control data, and its open runs 20 ms less, a quarter. Opening the fold adds one HTTP page per 75 rows (`THREAD_HISTORY_PAGE_POLICY.maxItems`), loaded while the skeleton shows.

## Open perf tasks from PROGRESS.md

- Large replies: a sample of the 1 MiB layout put a fifth of it in tables, where each cell's width and each word's built a TextKit stack. `TextBoxCache.natural` measures each once per layout: 3.88 s (3.81 to 3.89) to 2.92 s (2.87 to 3.00) per 1 MiB layout, three alternating rounds at load 2.7 to 8.7, same height. Most of what is left is TextKit building and laying out each text box (weak-reference and lock traffic in `NSTextContentStorage` showed high in the sample).
- Thread open regressed: the micro-benchmarks show nothing to chase (`huge_open_panel` 9.7 against 10.6 ms at the base, ranges overlapping). The 50 to 67 ms first frame and the 55 ms stall need the app scenario.
- Huge-thread stream drift: `huge_update_stream` 2.38 and `huge_update_tool` 2.37 ms, overlapping the base, so no main-thread cause showed. The reducer, which runs off the main thread for every token, was the larger cost and went from 2.64 to 1.03 ms per word.

## What an on-screen perf run should check

1. `open.big_first_frame_ms`, `open.big_reopen_first_frame_ms` and the stall monitor for the 55 ms open stall, against the 54d92da review.
2. A long thread with a run of more than 150 tool calls: first frame without the folded rows, then the fold's skeleton, the rows appearing in place without the timeline jumping, and Couldn't load work with Click to retry when the server is stopped mid-load.
3. The streaming turn's app CPU (`--stream`) for the reducer change, on the huge thread if the workload allows.
4. A 1 MiB reply with tables: the time from open to the reply replacing its estimated height, against 2.2 s.
5. Child approvals: a subagent asking for approval shows its card above the composer, Approve answers it, and the timeline's bottom inset follows the card list.
