# Performance reviews

`scripts/perf-review` runs after every merged work package and every milestone (the user's rule, PROGRESS.md "Decisions made"). Each run saves `<date>-<sha>-w<workload>.json` and `.md` here and compares itself with the median of the last three saved runs on the same workload.

## Performance and visual audit (2026-10-16)

The audit reviewed the RPC stream buffers and liveness watchdog, store update batching, thread and Markdown caches, timeline virtualization and recycling, animation visibility, Settings construction, and HTML frame ownership. The full tests exercise protocol, reconnect and lifecycle behavior, reducers, interaction behavior, and light/dark pixel references. Manual checks use an isolated app against the sandbox, on this Mac's 1x display.

Confirmed fixes:

- Markdown views kept a complete TextKit layout for every width encountered during resizing or a panel animation. They now retain the two most recently used widths. The regression test sweeps 61 widths, verifies that an old layout is released, and checks the reconstructed height against a fresh view. Streaming layout reuse and pixel references still pass.
- A recycled reasoning box kept the previous thought's scroll-follow flag. A reader who scrolled up in one thought could miss new text in the next. A new thought now starts at its live edge, while updates to the same thought still respect the reader's scroll position. Removed thoughts release their Markdown views. T3: `apps/web/src/components/chat/WorkLog.tsx:145-160`.
- HTML frame bookkeeping dropped the shared data store when inserting or touching the only frame, and did not track an expanded reply. All agent frames now keep the store alive until they release it; only inline frames count toward the three-frame eviction limit. Force Reload can reach the active store, and removing a full screen dialog releases its frame. Tests cover shared ownership, eviction, and removal. T3's separate full screen document: `apps/web/src/components/chat/HtmlRenderDialog.tsx:40-47`.
- Appearance enumerated all installed font families on the main thread for each font row and again when committing a name. One on-screen Debug trace spent 593 ms in a pass that sampled `NSFontManager.availableFontFamilies`. Font discovery now runs once per page on a detached task through Core Text. On this Mac both APIs returned the same 179 families. An open picker updates when discovery finishes, and an outdated typed value cannot overwrite a newer one. T3 also discovers and caches fonts asynchronously: `apps/web/src/components/settings/FontFamilyPicker.tsx:48-61`, `apps/web/src/appearanceFonts.ts:362-398`.
- The next Appearance trace exposed a 361 ms pass in the theme circles' first Core Image blur. Visible circles now render on a serial background actor, cancel queued work when hidden or removed, and discard stale results. Offscreen exports stay synchronous. The background renderer produces the same pixel bytes as the synchronous renderer; the existing theme fidelity references also pass. T3's gradient and blur definition: `apps/web/src/components/settings/ThemePreviewCircles.tsx:131-158`.
- The Release performance bundle had isolated preferences but did not qualify as a test build when choosing its file-backed stash directory. It now uses its own directory too. An early audit run was discarded when a real Stash badge appeared in the test app. The user's demo PID file was also missing; the review now accepts `CANDY_DEMO_PID_FILE` for a separate, verified PID file, so it can exclude the documented demo without changing or stopping it.
- The saved review caught three sidebar regressions since the preceding review. The recently added snooze-expiry scan used lazy filter/map iterators over the large `ThreadShell` value on every label refresh. Reading the two needed fields by index removes the copying overhead and keeps the same earliest-wake rule, including collapsed shelves. T3: `apps/web/src/components/Sidebar.tsx:3008-3022`. The focused rerun restored rename, label-tick and shelf-toggle times below the preceding baseline; the complete benchmark follow-up is linked below.

The two Debug stall samples above overlapped build/test work and identify blocked main-thread paths, not a controlled before/after timing comparison. The saved Release review below is the speed and resource regression check.

The [complete Release review](2026-10-16-0a2416f-dirty-w1.md), against the last saved run `a3077d8`, measured a 193 ms window, 232 ms live sidebar, 0.042% idle CPU, 0.40 interrupt wakeups/s and 34.0 MB idle footprint. The large thread opened in 65.4 ms, reopened in 48.8 ms, and painted from disk cache in 68.1 ms. Scrolling used 368 ms CPU, with two dropped frames and no main-thread stalls over 50 ms, as in the baseline. The streaming turn averaged 1.3% app CPU. These are app-process measurements on the Mac mini, not whole-machine energy or a MacBook battery-life estimate.

Idle memory rose 1.7 MB and scroll CPU rose 27 ms against the previous saved run, both below the review's regression thresholds. The initial review flagged the three sidebar microbenchmarks described above; it predates the final scan fix. All other comparable metrics were within thresholds. The review preserved those results instead of hiding the regression behind a new baseline.

The [complete benchmark follow-up](audit-2026-10-16/benchmarks.md) includes the scan fix. Rename, label tick and shelf toggle measured 0.389, 0.281 and 1.7 ms, respectively, versus 0.425, 0.296 and 1.8 ms in the saved baseline. That follow-up flagged one unchanged parser path at 61.1 ms. Two [isolated reruns](audit-2026-10-16/parse-rechecks.json), with the same binary and no code change, measured 40.7 and 39.8 ms against the 41.0 ms baseline; the initial full review measured 41.5 ms. The outlier did not reproduce. The final sidebar change only alters the scan's iteration, so the app scenarios use the preceding full review and the follow-up reruns all microbenchmarks.

A [visible/hidden idle smoke check](audit-2026-10-16/visibility-idle.txt) used that Release app on the shared sandbox's completed Markdown example. One 30-second sample each measured 0.01% visible CPU and 0.03% hidden CPU, with 0.53 and 0.60 interrupt wakeups/s. Hiding the app was confirmed through accessibility. This shows low activity in both sampled states, not zero wakeups or a measured battery-life gain. The isolated app no longer showed the user's Stash badge.

Validation: all 1,514 tests passed again after the final sidebar change (1,497 Swift Testing tests and 17 XCTest tests), including the new regressions. The new Markdown lifetime, reasoning reuse, and shared WebKit store checks failed before their fixes. Manual screenshots covered Markdown headings, tables, task lists and code in light/dark at 900 and 1100 pt, a continuous 1200-to-900 pt resize, General and Appearance, the loaded font picker, the command palette, and the open right panel. Timeline diagnostics reported no overlapping or misplaced recycled rows. In the final Release UI run, the font scan and theme blur no longer appeared in main-thread stalls; two earlier first-open passes still measured 67 and 69 ms. Theme circles fill asynchronously on their first display and match the reference once ready. A final diff review checked task cancellation and stale results, view/store ownership, cache eviction, and unchanged snooze scheduling; it found no additional blocker.

Remaining limits: the previously recorded roughly 150 ms first open of an exceptionally long Markdown reply still needs work. The tiny composer left beside a wide right panel can clip a long manual server-update action when the Stash badge also shows. T3 uses wrapping notice/action rows (`ComposerBanner.tsx:191-211,263-270`, `ComposerBannerStack.tsx:353-372`); this extreme width needs a matching reference before changing the common banner layout. The other open parity items remain in `PROGRESS.md`. These checks cover the exercised screens and workloads, not every possible server state, font collection or display scale.

## Running it

```
scripts/perf-review                          # HEAD, compared with the last three runs on this workload
scripts/perf-review --source .               # the working tree, uncommitted changes included
scripts/perf-review --commit dd10f48 --baseline docs/perf/<file>.json
scripts/perf-review --stream                 # adds one claude-haiku-5-5 turn (costs a real turn)
```

About 17 minutes per build when the machine is quiet: 3 to 5 for the Release build, 2 for the micro-benchmarks, 10 for the app runs, half of them the stall monitor's own launches. Waits for a quiet machine come on top, up to 10 minutes each. Output goes to stderr as it runs; the table prints at the end.

## Frozen workload and quiet machine (since 2026-10-10)

Before this, every run measured against the shared sandbox server on 47391. Other agents add test turns to its threads, so "Numbers 1 to 1000" was not the same thread between runs (the WP7.2 run opened it at a 33.7 MB peak, earlier runs at 87 MB). Agents also compile and run tests while a review measures, which moves launch times and micro-benchmarks.

- The workload is a frozen copy of the sandbox home in `../CandyWrapper-research/perf-home-pristine`, made once by `scripts/perf-review --make-workload`: the SQLite database through `sqlite3 .backup` so a running server can't tear it, the rest as files, without the logs. The sandbox's `session.token` works against it because the copy has the same auth tables.
- Each run copies the pristine home to `/tmp/cw-perf/home-<pid>`, starts its own server there on a free port (the `env -i` and new-session pattern of `scripts/sandbox-server`, PID in `/tmp/cw-perf/server.pid`), runs every scenario against it, then stops that PID and deletes the copy. The stream turn lands in the copy, so the pristine home never changes. Server log: `/tmp/cw-perf/home-<pid>.log`.
- The JSON records `"workload": 1`. A run compares only with saved runs of the same workload; runs from before have no workload and drop out. To change the dataset, move the pristine home away, bump `WORKLOAD` in the script and run `--make-workload` again.
- The app's own state is the perf run's too. Perf builds get the bundle id `dev.candywrapper.perf` (an `xcodebuild` setting), so their UserDefaults live in a domain of their own, and the script deletes that domain before every launch. The thread cache is `../CandyWrapper-research/perf-thread-cache-w1` (`CANDY_THREAD_CACHE`), which only ever sees the perf server. On 2026-10-10 the first WP7.6a review read `big_thread.scroll_cpu_ms` 30% worse in all three runs: an agent had left a README tab open on the big thread in the shared `dev.candywrapper.app` domain (`rightPanel.states.v1`), so the timeline scrolled beside an open right panel. Sampling showed the extra work as `MarkdownView.draw` and GPU waits in `CABackingStoreGetFrontTexture`.
- Before every app launch and before the micro-benchmarks (after their build), the script waits until no `swift-frontend`, `swift-build`, `swiftc`, `xcodebuild`, `clang`, `ld`, `xctest` or `swiftpm-testing-helper` runs, no other CandyWrapper app runs besides the user's demo app, and the 1-minute load average is under `--max-load` (default 3.0; the machine sits near 2 with the live T3 server and idle agents). It waits up to 10 minutes. Each wait goes into `quiet.waits` in the JSON and the `.md` header with its length and the load when measuring started. A run that could not get quiet is marked `"noisy": true` and says so in its notes.

## What it does

1. Builds a Release app from the commit into its own derived data (`/tmp/cw-perf/dd-<sha>`), from a detached worktree in `/tmp/cw-perf/src-<sha>`, or from `--source`.
2. Starts the private server on a copy of the frozen workload (above).
3. Launches the app through `scripts/run-app` with `--server <private server> --token-file <sandbox>/session.token --fake-t3-connect`. The fake T3 Connect flag keeps the app away from the user's saved environments and Keychain (a new build would otherwise prompt for the Clerk session on the user's screen). It checks that the PID in `/tmp/candywrapper-app.pid` belongs to its own build and stops only that PID. Before each launch it waits for a quiet machine, and it notes any run that overlapped another CandyWrapper app.
4. Runs three scenarios, each `--repeat` times (default 3), and reports the median and the range:
   - Launch and idle: opens the small finished thread "Reply with one word: candy". Window time comes from `probe window` (first on-screen window taller than 200 pt, measured from the process start time in the kernel). Sidebar times come from the app's `CANDY_LAUNCH_TIMING` lines. After 5 s of settling, 30 s of kernel counters (`proc_pid_rusage`): CPU, interrupt and package idle wakeups per second, footprint and lifetime peak footprint.
   - Large thread: opens "Numbers 1 to 1000 as words", footprint and peak 8 s after launch; then `--perf-scroll 12` makes the app scroll its timeline to the top and back, 300 pt per frame, 140 frames each way; CPU time of the whole window, then footprint and peak 3 s later. The app scrolls itself because scroll events posted to its PID never reach AppKit, and events through the HID tap would move the user's pointer.
   - Thread open: launches on the small thread with `--perf-open 4 "Numbers 1 to 1000"` and `CANDY_THREAD_TIMING=1`. Four seconds after the shell the app opens the big thread as a click would, 2 s later the small one, 2 s later the big one again. `open.big_first_frame_ms` and `open.big_reopen_first_frame_ms` run from `open(id)` to the first display refresh after the rows are placed (a `CADisplayLink` on the window), so they carry up to two frames of display latency. They flag only at 34 ms (two frames) or more, since a few ms of work can move a first frame by a whole refresh. The reopen paints from the retained store. Each run points the disk thread cache at its own empty directory (`CANDY_THREAD_CACHE`, passed through `scripts/run-app`), so the first launch opens from the network; a second launch with the directory the first one filled gives `open.big_cache_first_frame_ms`, the same open painted from the disk cache.
   - Streaming (`--stream`): a fresh haiku thread made through the RPC by `scripts/perf/turn.swift`, opened in the app, then one turn ("the numbers from 1 to 60 as English words") driven by the helper while the app only watches; CPU and wakeups across the turn, footprint and peak after.
5. Bundle and binary size.
6. Micro-benchmarks: `CW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PerfBenchmarks` in `Packages/CandyKit` (`Tests/FeaturesTests/PerfBenchmarks.swift`). Deterministic inputs, a warm-up pass, then the median, min and max of 9 runs:
   - `decode_fixtures`: every frame of the 7 recorded transcripts (1.8 MB) to typed shell and thread items.
   - `thread_reducer` and `timeline_rows`: the largest recorded thread stream replayed through `ThreadReducer`, then `TimelineRows.derive` on its projection.
   - `markdown_parse` and `markdown_layout`: a generated 39 KB reply (headings, lists, code, tables) parsed, then laid out at 680 pt.
   - `sidebar_items_1000`: `SidebarListBuilder.items` for 1,000 threads in 20 projects.
   - `markdown_parse_lines`: a reply of 2,400 short lines, one paragraph of soft breaks.
   - `huge_open_*`: a synthetic huge thread, 300 copies of the largest recorded snapshot's turns (900 runs, 3,600 nodes), shaped like the server's bounded snapshot: the last 3 copies of rows and messages (57 rows) plus every run, attempt, node, checkpoint, request and provider turn of the thread, 8.3 MB as one Chunk frame. Stages: `parse` (frame to `JSONValue`), `decode` (typed `ThreadStreamItem`), `reduce`, `entries` (`TimelineRowsInput`), `derive` (`TimelineRows.derive`) and `panel` (a fresh `ThreadPanelView` at 1200x800: `setProjection` and layout). `huge_full_*` is the same thread with all 5,700 rows loaded (20 MB). `huge_open_long_*` gives every reply in the window 6 KB of markdown.
   - `huge_update_*`: main-thread time of one update to the `huge_full` thread already on screen, its newest run running: `stream` (the streaming answer grows by a word), `tool` (a tool row flips between running and completed), `append` (a new tool row). The time covers `setProjection`, applying rows a pass derived off the main thread (the pass itself is awaited, not counted) and layout. `huge_update_{stream,tool}_entries` is the incremental entry pass alone, `_rows_patch` the streaming patch, `_rows_offmain` the full row pass that runs off the main thread.
   - `huge_cache_write` and `huge_cache_load`: the `huge_open` window through the disk thread cache (encode, compress and write; read, decompress and decode), with the file size in `bytes`.

   An older checkout without the benchmark file gets today's copy.

## Verdicts

Space's pure logic has a focused lane: `scripts/perf-review --space-only --source "$PWD"`. It builds SpaceModel, SpacePlanning and their tests from the selected checkout in a temporary package, with the same `-Osize` library setting, and waits for a quiet machine before measuring. The fixture holds 2,000 pages, 20,000 items and 100,000 blocks in memory. Search reports sparse, absent, common multiword and broad title queries over 21 samples, with p95 in each JSON metric's detail, plus build time, build-time heap growth and the retained heap released by clearing the index while the input models stay alive. This lane creates no app, server, plaintext data files or persistent build copies. It saves a `-space` report and compares with the selected baseline; new metrics have no prior comparison until a Space run is saved.

Lower is better everywhere. A metric is `WORSE` or `better` only when the median moves past both thresholds and, with 3 or more samples on each side, the two ranges don't overlap. Otherwise it is `same`.

| Metric | Relative | Absolute |
|---|---|---|
| Launch times | 15% | 50 ms |
| Idle CPU | 50% | 0.05 points |
| Wakeups per second (idle) | 25% | 1 |
| Footprint | 10% | 3 MB |
| Peak footprint | 10% | 5 MB |
| Scroll CPU time | 25% | 100 ms |
| Streaming CPU | 25% | 1 point |
| Streaming wakeups | 25% | 5 per second |
| Bundle and binary size | 10% | 0.5 MB |
| Micro-benchmarks | 20% | 0.05 ms |

Idle CPU and wakeups and memory matter most: they decide battery life and the "lighter than Electron" claim. The thresholds sit above the run-to-run noise measured below.

## Comparison: milestone 5 (dd10f48) and main (ef84b1d)

Run on 2026-10-10, 3 launches per scenario, one haiku turn each. Full tables: `2026-10-10-dd10f48-dirty.md` and `2026-10-10-ef84b1d-dirty.md`. Main was measured from the working tree that adds this review (ef84b1d plus the timing marks and `--perf-scroll`).

| Metric | M5 dd10f48 | Main ef84b1d | Delta | Verdict |
|---|---|---|---|---|
| Bundle size | 12.5 MB | 14.9 MB | +19% | worse, expected |
| Binary size | 11.0 MB | 13.4 MB | +22% | worse, expected |
| Window on screen | 150 ms | 148 ms | -1% | same |
| Live sidebar | 187 ms | 176 ms | -6% | same |
| Idle CPU | 0.015% | 0.040% | +0.025 pt | same (noise, see below) |
| Idle interrupt wakeups | 0.33/s | 0.40/s | +0.07/s | same |
| Idle package idle wakeups | 0.00/s | 0.23/s | +0.23/s | same (noise) |
| Idle footprint | 30.3 MB | 31.5 MB | +1.2 MB, +4% | same, real |
| Large thread footprint | 36.0 MB | 37.5 MB | +4% | same, real |
| Large thread peak | 86.6 MB | 88.1 MB | +2% | same |
| Scroll top and back, CPU time | 302 ms | 331 ms | +9% | same |
| After scroll footprint / peak | 43.1 / 102.5 MB | 44.5 / 103.8 MB | +3% / +1% | same |
| Streaming turn CPU | 1.3% | 1.4% | +0.1 pt | same |
| Streaming footprint / peak | 85.8 / 86.5 MB | 56.6 / 87.7 MB | | same peak |
| decode_fixtures | 31.8 ms | 31.3 ms | -2% | same |
| thread_reducer | 0.424 ms | 0.426 ms | 0% | same |
| timeline_rows | 0.181 ms | 0.182 ms | 0% | same |
| markdown_parse | 14.0 ms | 13.8 ms | -1% | same |
| markdown_layout | 37.1 ms | 36.3 ms | -2% | same |
| sidebar_items_1000 | 2.58 ms | 2.87 ms | +11% | same, real |

### What changed and why

- Size, +2.4 MB. Object files per module: app target +2.0 MB, T3Client +3.2 MB (Clerk client, relay, DPoP, environment catalog), Features +1.5 MB (Settings and Connections pages), T3Store +0.6 MB. This is milestone 6's feature code, not a leak of something unneeded. Still 14.9 MB against Electron's 366 MB. Proposed: accept it and treat this run as the new baseline. If size matters later, try `-Osize` on T3Client, whose code runs only during sign-in and connects.
- Idle footprint, +1 MB. `footprint -p` puts it all in Malloc Small (18 to 19 MB). A `heap` diff of the two idle apps shows 6,500 more heap nodes: 126 more `_NSViewLayoutAux`, 29 more `IconView`, 26 more `LabelView`, 14 more `SidebarMenuButtonView` plus a `[SettingsSection: SidebarMenuButtonView]` dictionary, 204 more autoresizing constraints. `SettingsController` builds the settings sidebar, page and Connections views at launch (`App/Sources/SettingsController.swift:18-20`) and refreshes them on every environment and T3 Connect change, while nobody has opened Settings. Proposed fix: create those three views on the first `open()` and skip `refresh()` while Settings is hidden. A second, smaller part is two more `[ThreadShell]` arrays (98 KB): the per-environment snapshot and the merged one.
- `sidebar_items_1000`, +0.29 ms (+11%, ranges don't overlap). `SidebarModel.buildProjectGroups` now merges projects across environments by repository identity (`preferredEnvironmentId`), and `SidebarListBuilder.Context` runs it on every build. Under the 20% threshold; worth caching the groups per snapshot if the sidebar grows.

### Noise

Idle CPU and package idle wakeups looked worse in the two saved runs, but an interleaved check (`dd10f48`, `main`, three rounds, 30 s each, nothing else running) put both builds in the same band: CPU 0.029 to 0.047% for M5 and 0.030 to 0.046% for main, package idle wakeups 0.07 to 0.27/s and 0.13 to 0.30/s, interrupt wakeups 0.40 to 0.43/s and 0.37 to 0.40/s. Package idle wakeups count only wakeups that found the whole CPU package idle, so they depend on what else the machine does at that moment; the M5 run happened during a quieter window. Comparisons against a saved run from another time carry this noise, so the thresholds sit above it.

Other spread inside one run: the first launch of a fresh build is cold (window 445 ms against 150 ms warm; the median hides it), footprint varies by 0.5 MB, scroll CPU by 8%, micro-benchmarks by 1 to 2%. No run overlapped another CandyWrapper app besides the user's demo app. Load average during the runs was 2.1 to 2.6 (the user's live T3 server and agents).

## Stalls and dropped frames (2026-10-14)

The other numbers here are averages, so a 300 ms freeze once a minute never shows in them. `CANDY_STALLS=1` (passed through `scripts/run-app`, any build) starts `StallMonitor` (`App/Sources/StallMonitor.swift`), which prints `stall-monitor on` and then:

- `stall <ms> ms` for every main run loop pass of 50 ms or more, wake to sleep, Core Animation's commit included, followed by `sample <ms>` stacks of the main thread that a watchdog thread takes 50 ms into the pass and every 100 ms after.
- `frame-gap <ms> ms <n> dropped <reason>` when the display link misses two or more refreshes during scrolling, typing, dragging, a resize or `--perf-scroll`.
- `key-latency <ms> ms` from a key event's timestamp to the end of the pass that handled it, after its frame committed.

Off, nothing is installed. On and idle, the watchdog waits on a semaphore and the display link runs only for half a second after input, so it adds no wakeups. Frames carry the image and offset next to the symbol, so `atos` can resolve a stripped build. `scripts/perf-review` reports `launch`, `big_thread` and `open` `.stall_max_ms` and `.stall_count_50ms`, plus `big_thread.dropped_frames`.

The monitor isn't free while the app works, so the review measures stalls in launches of their own. On 2026-10-15, four interleaved launches each of caa57d8 with `CANDY_STALLS=1` and without gave `big_thread.scroll_cpu_ms` 363 to 392 ms (median 381) against 303 to 341 ms (median 338): the display link ticks every frame of `--perf-scroll` and the watchdog wakes on every run loop pass. Idle CPU, footprint, launch times and the open first frames didn't move beyond their noise, and idle interrupt wakeups rose from 0.35 to 0.47 per second. Since then each scenario run launches twice: once without the monitor for every other metric, then once with it, keeping only its stall metrics. The streaming turn runs without the monitor, so it has no stall metrics. Reviews from 2026-10-15 before this change (e72162b) took every metric with the monitor on, so their scroll CPU reads about 40 ms high.

Method: Release builds of 810aa19 plus the monitor (before) and of this change (after), run alternately twice each against a copy of `load-home-a` (1,063 threads, the 5,000 message thread, a 315 KB markdown reply, an 18,000 line code reply) on its own server, while three other agents built and tested. A script drove each run through the same clicks and keys: open five big threads, 18 quick switches between six threads, 71 characters typed and deleted in the 5,000 message thread's composer, ⌘K searches, Change theme to Glass and back through the palette, and a resize through 12 widths with the code reply open. Counts are of passes over 50 ms.

| Scenario | Before | After |
|---|---|---|
| ⌘K, typing "update deps romeo" and deleting it | 2 and 3 stalls, max 378 and 310 ms; key latency median 35 ms, max 222 ms | no stalls; median 10.5 to 11 ms, max 31 to 35 ms |
| Theme to Glass and back through ⌘K | 2 stalls each, max 270 and 279 ms | none |
| Resize with the 18,000 line code reply open | 3 stalls each, max 85 and 89 ms, 10 frames dropped | none, 4 frames dropped |
| 18 switches between six big threads | 6 stalls each, 853 and 894 ms in all | 3 stalls each, 450 and 465 ms in all, max 151 to 157 ms |
| First open of the five big threads | 2 stalls, 326 and 328 ms in all | 2 stalls, 320 to 424 ms in all |
| Typing in the 5,000 message thread | 0 or 1 stall; key latency median 9 to 10 ms, p95 18 ms | none; median 10 to 13 ms, p95 18 to 21 ms |

What they were, from the samples:

1. Every key in ⌘K ran `PaletteSearch.normalize` (NFKD, mark filtering, lowercasing) over every thread's search terms, rebuilt the root groups, sorted the projects by copying each of the 1,063 thread shells into per-project arrays, and searched settings, all before the typed glyph could commit. ASCII text now normalizes in one byte pass (same result, `asciiNormalizeMatchesUnicodePath`), the project sort keeps the newest timestamp per group without copying shells, and the search runs right after the key's frame commits (`AfterCommit`), so keys that arrive together search once. Enter, the arrows and jumps run a pending search first (`enterAfterTypingRunsTheFilteredRow`).
2. Every layout of a code block lexed and colored its whole text again, so each new width during a resize lexed the 18,000 line reply (0.1 s). Colored code of 2,000 UTF-16 units or more is kept for the last 16 blocks; the colors are dynamic, so neither width nor appearance changes it.
3. Switching back to a thread parsed its long replies again, since the timeline forgets its parses on a thread change (0.13 s for the 1.1 MB reply). Settled texts of 16 KB or more keep their parse for the last 8.

Checked and clean: the sidebar scrolled through 1,063 threads, scrolling the 5,000 message thread (one 79 ms pass waiting on the GPU in `CABackingStoreGetFrontTexture`), two streamed claude-haiku-5-5 turns, the "Huge diff" thread's Diff panel with its 4,130 line file expanded and scrolled, three image threads opened twice each and scrolled, and the frame parse and typed decode, which run off the main thread (`RPCConnection`).

Left:

- Opening a thread with the 315 KB, 800 paragraph reply still lays it out on the main thread, about 150 ms each time, since a recycled row view drops its layout. A shared layout cache would have to key on the font, the theme and Glass as well; worth it if users with replies that long notice.
- The first open of a huge reply parses it on the main thread (0.13 s). Parsing off the main thread before the rows apply would fix it.
- Opening Settings and the first window draw 55 to 75 ms of glyphs and layers in Core Animation's commit, once each.

## Optimisation pass (2026-10-14)

The classic client's share of the pre-release pass (task `classic`). Baseline: `2026-10-15-810aa19-w1`. Final: `2026-10-15-e72162b-w1`, which also holds other agents' commits from the same night (server priority, palette, thread re-parse, stall logging).

| Metric | 810aa19 | e72162b | Commit |
|---|---|---|---|
| `bench.huge_full_parse` | 118.1 ms | 40.7 ms | 60603ed |
| `bench.huge_open_parse` | 52.2 ms | 16.6 ms | 60603ed |
| `bench.decode_fixtures` | 23.5 ms | 9.8 ms | 60603ed |
| `bench.huge_cache_write` | 60.2 ms | 30.1 ms | 0c4f9ec |
| `bench.huge_cache_load` | 48.4 ms | 24.3 ms | 60603ed, 0c4f9ec |
| `size.shipped_bundle_mb` | 31.1 MB | 30.2 MB | e72162b, measurement only |

`JSONScanner` (60603ed) reads frame bytes straight into `JSONValue`. JSONSerialization built every node twice, an NSObject and then the enum, and the conversion cost as much as the parse. The scanner keeps JSONSerialization's quirks: fragments, a BOM, one trailing comma, the first of duplicate keys.

The thread cache (0c4f9ec) writes through `JSONValueEncoder`, which builds a `JSONValue` tree and takes the raw wire objects as they are, then `JSONValue.utf8`. That is 27 ms against JSONEncoder's 43 ms on the huge window. LZ4 compresses it in 1 ms against LZFSE's 13 ms, to a file about twice the size, and both decompress in under 1 ms. In a Debug build the tree encoder is slower than JSONEncoder (10.5 against 1.4 ms on the recorded thread), which broke a cache test that slept 100 ms. f25aa6b made `ThreadStore` chain its cache tasks so a flush writes the newest state, and the test now awaits the flush.

The shipped bundle didn't shrink. `scripts/release` already thins Sparkle to arm64, and the review now counts it the same way. The rest is the 22.5 MB stripped binary, spread over thousands of functions with none above 30 KB, plus 6.6 MB of resources, all in use: the terminal's Nerd Font, Sparkle, the app icon at 1024 px in two scales, the grain, Mermaid and the wallpaper.

These didn't pay off:

- `markdown_parse_lines` is 35 ms, and Foundation's `AttributedString(markdown:)` takes all of it. A plain-text fast path would have to match cmark-gfm exactly, so I left it.
- `markdown_layout` spreads its 48 ms over TextKit 2 and CoreText shaping. `glyphOffsets` shapes a line again for each chip and link, about 13%. Caching it per box would hold memory for every line of every visible message.
- `huge_full_decode` spends its 31 ms on dictionary lookups, retains and Codable overhead, with no single hot spot.
- `launch.window_ms` is mostly AppKit. Of the 62 ms in `showMainWindow`, `NSWindow` init takes 25 ms and `ThreadController.init` 24 ms across many views. The browser panel built at launch costs 4 ms, which is below the metric's noise.
- `big_thread.after_scroll_peak_mb` is about 51 MB of graphics memory on top of the 45 MB the app holds while `--perf-scroll` sits at the top of "Numbers 1 to 1000". I added a canvas that backs only the visible part of a tall `MarkdownView`, and a Debug A/B gave 111 to 113 MB before and 120 MB after, so I dropped it. Limiting `prepareContent(in:)` to the visible rect changed nothing either. A layer dump at the top shows about 49 MB of backed layer area, including a 1,183 pt message, so the next step is per-row backing, not the long message.

`big_thread.scroll_cpu_ms` (276 to 365 ms) and the open first frames (56 to 68 ms, cached 44 to 69 ms) moved up with overlapping ranges, so the verdicts are "same". The 810aa19 baseline's 276 ms was low next to e34f91c's 346 ms. Six other commits landed between the two runs, so rerun before reading either as a regression.

The pre-release review, `2026-10-15-a3077d8-w1` against `810aa19`, flags nothing. Its scroll CPU is 341 ms (301 to 342) and its first frames 63, 50 and 66 ms, all within the thresholds. Five interleaved launches each of the two Release builds, with no stall monitor, gave scroll CPU 334 to 364 ms (median 344) for 810aa19 and 338 to 363 ms (median 352) for main, and first frames of 63, 48 and 66 ms on both. The rise came from two things. The e72162b review measured with the monitor on, which adds about 40 ms, and 810aa19's 276 ms was a low run.

## Sidebar updates (2026-10-13)

`CANDY_SIDEBAR_TIMING=1` (passed through `scripts/run-app`) prints `sidebar rebuild <ms>, <items> items, <n> rows built` for every sidebar update; `CANDY_SIDEBAR_TIMING=nocache` builds the list from scratch each time, for a before. Numbers and method: `docs/research/m10-load-2026-10-12.md`, "Sidebar updates".

The same variable makes `PanelSlide` print `slide frame <gap> ms after the last, <work> ms of work, value <v>` for every display frame of a sidebar slide. With panel animations at 400 ms, a Release build and the 2,000 message thread open, both directions took 24 frames 16.7 ms apart, with 1 to 4 ms of layout per frame (the main panel reflows on each one, as T3's does). A `screencapture -v` recording showed the main panel's content column moving on every frame, and the window after a close and open slide matched the screenshot taken before it pixel for pixel. Idle afterwards the app sat at 0.6% CPU and 2.8 wakeups a second with five servers connected: no display link outlives a slide.

## Images (2026-10-14)

`CANDY_IMAGE_TIMING=1` prints `image-timing <ms since launch> <event> <detail>` for thread opens and for each image: `request` with the pixel side, `fetch` and `fetched` for server copies, `decode`, `memory` for a cache hit, `pixels`, and `drop` when a view lets go of its image. `CANDY_SLOW_LINK=<rtt ms>:<Mbit/s>` delays attachment fetches as one shared remote link would, which stands in for T3 Connect. Both pass through `scripts/run-app`. The runs used `--open-thread <other> --perf-open 6 <photo thread>`, which opens the photo thread, the other thread and the photo thread again 2 s apart. The photo thread holds three 4000 px JPEGs (1.7, 2.5 and 4.0 MB) and a 2400 px PNG (7.7 MB). All times are from the click and come from Debug builds on the 1x virtual screen.

What made images slow: a message's image cell joined its window before it had a frame, so it decoded at the 16pt floor and stayed blurry, and a cell rebuilt after a thread switch decoded again behind its file name. Decoding always ran off the main thread. The main thread only assigns the layer's contents.

| Case | Before (fff9d87) | After |
|---|---|---|
| First open, bytes fetched from the local server | 16 px pixels at 41 to 104 ms, never sharp | sharp pixels at 66 to 126 ms |
| Relaunch, bytes in the disk cache | 16 px pixels at 29 to 76 ms, never sharp | sharp pixels at 52 to 100 ms |
| Switch back to a thread whose image row was rebuilt | file name shown, pixels 32 ms after the new cell | cached pixels in the same pass, no decode |
| Switch back to a thread whose row view was kept | instant | instant |
| First open over 100 ms RTT and 20 Mbit/s | 16 px pixels at 1.0, 2.1, 3.6 and 7.0 s | sharp pixels at 1.0, 2.0, 3.7 and 7.0 s |

The slow link is bandwidth-bound: 16 MB at 20 Mbit/s takes 6.4 s, and T3's attachment route serves only the original bytes (apps/server/src/http.ts:395-423), so a faster first open there would need a thumbnail route on the server. Sent attachment cells and draft tiles keep their decoded image in a 48 MB `NSCache`, which the system empties under memory pressure. The fetched copies on disk stay under 512 MB, with the least recently read dropped at launch.

## The app's own caches on a slow disk (2026-10-14)

T3 shipped seven SQLite fixes on 2026-10-14. Here is what each changed and what it means for CandyWrapper's own storage:

- `a74ce48f9` (#19205) sets `synchronous = NORMAL` in WAL mode, so a commit no longer fsyncs the WAL on the event loop. An app crash loses nothing, and a power loss can roll back commits since the last checkpoint.
- `614b432a7` (#19304) sets `checkpoint_fullfsync = ON`, because checkpoints are now the only sync and plain `fsync()` on macOS doesn't flush the drive cache.
- `5fc1c5cb4` (#19324) runs checkpoints on a worker so a slow flush can't stall clients.
- `8659fcf14` (#19226) moves thread list reads to a reader worker, off the event loop and the writer.
- `4cd0076ec` (#19305) runs any statement that binds more than 64 KiB on a throwaway statement, so cached statements don't pin large payloads.
- `fb8d0fc19` (#18471) runs `PRAGMA optimize = 0x10012` on open, so the planner has index statistics.
- `acb90279e` (#19310) closes the Cursor provider's SQLite handles after each call.

CandyWrapper opens no SQLite database of its own. `RuntimeChoice.databaseMigration` reads one row from the server's database read only, closes it with `defer`, and runs only while no server owns the home. `URLSession.shared` keeps CFNetwork's `Cache.db` in `~/Library/Caches/<bundle id>`, which is already WAL and under 400 KB. The app's own stores are files:

- `ShellCache` holds one JSON file per environment, about 1 MB for 1,580 threads.
- `ThreadCache` holds one LZFSE file per thread, 32 MB in total.
- The attachment copies in `~/Library/Caches/CandyWrapper/attachments` are pruned once at launch on a utility queue.
- `PromptStash`, `EnvironmentCatalog` and `RuntimeStore` hold user data that can't be rebuilt, and they write rarely, so they keep their sync.

Method: a 2 GB APFS sparse image throttled with `sudo dmc start /Volumes/<name> "5400 HDD"` (26 ms access time, 100 MB/s). `CW_DISK_BENCH=<dir on the volume> swift test -c release -Xswiftc -enable-testing --filter DiskCacheBenchmarks` writes and reads the M10 load's 1,580-thread shell snapshot and the huge thread's window, the latter into a cache already holding 2,000 small files. A second run with `CW_DISK_BENCH_PHASE=load`, after `hdiutil detach` and `attach` and `dmc start` again, reads cold. `sudo fs_usage -w -f filesys swiftpm-testing-helper` counted the syscalls.

`Data.write` calls `fsync` on every write, atomic or not, which is the same per-commit sync T3 removed. The 1 MB shell snapshot spent 113 ms of its 128 ms write in `fsync`, and the first write of a run waited 8.7 s while the disk flushed. Quitting waits for that write (`ServerController.shouldTerminate`), so a slow disk held up quit. Both caches now write through `CacheFile`, which writes a temporary file beside the target and renames it over without a sync. A power loss can leave the newest file empty or torn. `ThreadCache.load` fails to decompress or decode it, removes it and the thread opens from the network. `ShellCache.load` returns nil, the sidebar waits for the server, and the next save replaces the file. `CacheFileTests` checks both with zeroed, halved and empty files.

The cached sidebar was read and decoded on the main thread before the window's first frame (`ServerController.showCached`). `AppDelegate` now starts that read on a background thread at the top of `applicationDidFinishLaunching`, and `showCached` takes the result, waiting only for what is left. Building the menu, theme and window between the two took 68 to 100 ms in three launches of a Debug build, more than the 51 ms cold read, so the read no longer delays the first frame.

| 5400 rpm profile | Before (a88adc9) | After |
|---|---|---|
| Shell cache write, 1,580 threads | 128 ms, first 8.7 s | 15.6 ms |
| Thread cache write, huge window, warm | 80 ms | 61 ms |
| Thread cache write, huge window, cold metadata | 96 ms | 96 ms |
| `fsync` calls per cache write | 1 | 0 |
| Shell cache load, warm / cold, on the main thread | 16 / 50 ms | 16 / 51 ms, overlapped with launch |
| Thread cache load, warm / cold, on the `ThreadStore` actor | 44 / 66 ms | 45 / 67 ms |

The cold thread cache write is still 96 ms. Its extra 35 ms is `evict()` listing the cache's directory with cold metadata, off the main thread at utility priority, at most once per 10 s per changing thread. A running byte total would skip that listing; add it if writes show up in a profile. The cold thread load costs 20 ms of disk on top of 44 ms of decompressing and decoding, and the decode is the larger part on any disk.

On the internal SSD `PerfBenchmarks/hugeThreadCache` gave 54.7 ms to write and 45.7 ms to load, against 55.5 and 44.2 ms in the fff9d87 run. Three `scripts/perf-review` runs of this change were stopped when the user's Origin energy runs took the machine, so it has no full review yet.

## Connection in bad moments (2026-10-14)

A 3105 server on a copy of the sandbox home (port 47395), reached through a Python TCP proxy that can blackhole both directions without closing anything, like dead Wi-Fi or a lost NAT entry. A headless client built on `T3Client` and `T3Store` subscribed the shell and one 62-message thread and logged every state change. `kill -STOP` froze the server. Times are from the fault to the state change.

| Scenario | Before | After | T3 3105 |
|---|---|---|---|
| Server frozen 5 s, 20 s, 90 s, nothing in flight | stays "Connected", catches up on CONT | same | drops after 15 s and shows "reconnecting" |
| Server frozen 20 s with a request in flight | dropped after 10.4 s | dropped after 15.8 s | 15 s |
| Server frozen 20 s while a turn runs | stays "Connected", looks live | dropped after 15.6 s | 15 s |
| Server `kill -9` | dropped within 10 ms, reconnected on the next backoff retry after the server came back | same | same |
| Network blackholed, idle | "Connected" for good | same, by choice (below) | 15 to 20 s |
| Network blackholed while a turn runs | "Connected" for good, turn looks stuck | dropped after 13.7 s | 15 to 20 s |
| Network blackholed, then a send | send failed after 10.4 s, text put back | 15.7 s | 15 s |
| Blackholed, then system wake | dropped after 3.2 s (quick probe) | same | 15 to 20 s, it has no wake signal |
| Another network while online (Wi-Fi to hotspot) | ignored until a send | quick probe, 3 s | quick probe where the browser reports a network type |

Resync after every reconnect resumes from the last sequence: the shell resubscribes with `afterSequence` and the thread with its `lastSequence`. The first connect read 39,031 bytes; each reconnect read 1,017 to 1,028 bytes and had live state in under 10 ms of the socket opening. Nothing is refetched in full, which matches T3.

Sends while disconnected. Before, the composer only blocked a send when the environment had no session at all, and a session lives on while it reconnects. A send during "reconnecting" went out, failed at once with a transport error, and the text quietly came back into the composer with no message. Now the composer follows the connection state as T3 does (ChatView.tsx:2676-2677, 8897-8907): the send button is disabled with "Environment disconnected", and Enter shows "Not connected: message not sent". Drafts are local, so editing one offline loses nothing.

Cost of the turn watch: the client checks a quiet socket only while a thread runs on that environment and the app is active. Measured with `powermetrics` over 60 s on the headless client: 0.13 wakeups/s and 0.01 ms/s CPU idle, 0.32 wakeups/s and 0.08 ms/s CPU watched. Idle with nothing running stays at zero added wakeups. The reasons for not pinging while idle are in docs/decisions.md.

Sleep and wake, from the code since this Mac can't sleep. `NSWorkspace.didWakeNotification` runs a 3 s `server.probe` (PlatformSignals.swift), so a socket that died during sleep is replaced within 3 s of wake. If Wi-Fi is still joining, the reconnect fails fast and the NWPathMonitor update to "satisfied" retries at once from the first rung. A loopback server answers the probe and the session survives sleep. A half-open socket with no wake, path change, activation, send or running turn is found only on the next of those, never by the kernel, because an idle socket sends nothing and URLSession offers no TCP keepalive.

## Server load and cold start (2026-10-14)

On a big database and a slow disk the T3 server is the bottleneck, so this pass counted what CandyWrapper asks of it and how long its own runtime takes to come up.

Method: copies of `load-home-a` (1,063 threads, threads of 2,000 to 5,000 messages) and `perf-home-pristine`, each with its own 3105 server started the `scripts/sandbox-server` way on ports 47431 to 47434, and a Debug build. `CANDY_RPC_TRACE=<file>` (new, passed through `scripts/run-app`) writes one line per RPC request, received frame and interrupt from `RPCConnection`. T3's own `userdata/logs/server.trace.ndjson` gives server time: every `ws.rpc.*` and HTTP span, and every `sqlite` span with its query, which I added up per nearest RPC or HTTP ancestor. Request counts are exact. Latencies come from a shared machine with three other agents, so the A/B timings below were interleaved.

What each action asks, home A:

| Action | Before | After | T3's web client |
|---|---|---|---|
| Launch | 11 requests, 382 KB in | same | the same subscriptions (client-runtime state/server.ts:437, :551, shell.ts:334, terminal.ts:65, vcs.ts:287, sourceControl.ts:72) |
| First thread open | 8 requests | 7 | subscribeThread, preview.list (usePreviewSession.ts:31-38), the composer's refreshProviders (ChatComposer.tsx:2300-2345), t3.json (ThreadDetailsPanel.tsx:68) |
| Six quick thread switches across two projects | 32 requests, 14 interrupts | 16 requests, 8 interrupts | about the same as after |
| Settings > Archive | 2 `getArchivedShellSnapshot` | 1 | 1 |
| Search, Settings pages, opening a diff, a turn | unchanged | | the same |

Each thread switch used to resubscribe `subscribeDeviceState` and call `device.list`. T3 keys device state by environment (apps/web/src/state/device.ts:33-39, payload `{}`), so one stream serves every thread, and it lists devices only while the device panel shows (DevicePanel.tsx:46-49). Switching back to a project also re-ran `vcs.listRefs` (a `git for-each-ref`, 46 to 70 ms on the server) and re-read `t3.json`. T3 keeps refs 30 s (vcs.ts:37) and file queries 5 minutes (runtime.ts:543). Settings > Archive loaded twice, once from `refresh` and again from `didShow`.

A streamed claude-haiku-5-5 turn made 4 `thread.visit` commands, at send, at completion and on T3's 10 s trailing throttle (ChatView.tsx:2938-3000), which matches T3. Scrolling back 1,350 turns in the 5,000 message thread fetched 68 history pages over HTTP: 476 SQLite queries, 598 ms of server time, about 14 ms a page. T3 fetches the same pages, one per "Load earlier turns" click (MessagesTimeline.tsx:1712-1726). CandyWrapper fetches them as the user scrolls near the top, so the count follows the distance scrolled. The heaviest payloads at launch and on the first open of a workspace are `server.refreshProviders` and the config push it causes, 127 to 170 KB each, which T3's composer asks for too, at most once per 5 minutes per workspace.

### Priority of CandyWrapper's own server

CandyWrapper put the server it starts into Darwin background (`PRIO_DARWIN_BG`) whenever no run was active, to save energy. Background priority throttles disk I/O, which is the slow part on a big database and a slow disk, and it applied while the user clicked through threads. With the file cache purged before each request, the bounded snapshot of the 5,000 message thread took 62, 63 and 72 ms at normal priority and 159, 126 and 239 ms in background, interleaved. T3's desktop app never lowers its backend's priority (DesktopBackendManager.ts sets none). The server now stays at normal priority while CandyWrapper is the active app and drops to background only when the app is inactive and no run is active (`ServerLifecycle` rule 6). Checked on a running app: base priority 37 frontmost, 4 behind Finder, 37 again.

### Cold start on CandyWrapper's own runtime

`CANDY_LAUNCH_TIMING` now marks `window built`, `server spawned`, `server answered` and `server resolved` too. Launches with no server running on a copy of home A, after one start had migrated it, six before and three after:

| Milestone, seconds after process start | Before | After |
|---|---|---|
| Cached sidebar and window | 0.19 to 0.24 | 0.20 to 0.22 |
| Server spawned | 0.30 to 0.38 | 0.25 to 0.27 |
| Server answered its descriptor | 2.94 to 3.19 | 1.15 to 1.16 |
| Live sidebar | 3.02 to 3.07 | 1.30 |

One after-run read 2.0 s because its window took 0.64 s to build on a busy machine. Spawn to answer was 1.0 s there too.

The server accepts connections a moment before it answers them, and a request that lands in that gap waits out its whole timeout. `waitForDescriptor` polled with a 2 s timeout, so nearly every cold start lost about 1.7 s. `curl` polling the same server every 150 ms showed it: one attempt hung for its full 3 s, the next answered in 2.5 ms. The probe now starts at 250 ms and doubles after each timeout up to 2 s. T3's desktop polls with a 1 s probe timeout (DesktopBackendManager.ts:66-68), so it pays up to a second of the same gap.

The other checks:

- The cached sidebar shows with the window, 0.2 s after launch, before the server is spawned.
- The server spawns 50 ms after the window is built. Spawning before the window would save at most 0.15 s and needs `finishPendingRestore` off the main actor first.
- CandyWrapper starts `t3 serve` with the desktop's bootstrap (`--bootstrap-fd 3`, `mode: "desktop"`). The SQLite settings live in the server code, so they are the same. The desktop runs the backend under Electron's Node with a V8 compile cache (DesktopBackendConfiguration.ts:586-596). The `t3` runtime is a Node single executable built with `useCodeCache: false` (apps/server/vite.config.ts:91-95). `NODE_COMPILE_CACHE` made no difference, 1.48 to 1.51 s against 1.49 to 1.55 s, because it covers only the few modules loaded from disk.
- The server reads the login shell's PATH on every start (os-jank.ts:20-43) unless the bootstrap says `shellEnvironmentPrepared`, as the desktop's does. CandyWrapper doesn't read the login shell itself, so it leaves that to the server.

Left alone: `subscribeVcsStatus` still resubscribes when a switch changes the workspace, where T3 keeps the old stream 10 s (vcs.ts:40). The server caches the status, so that costs little.

## Opening a thread (2026-10-10)

`CANDY_THREAD_TIMING=1` (passed through `scripts/run-app`) prints `thread-timing <ms since open> <stage> <detail>` for one open: request sent, every frame received (bytes) and parsed, typed decode with the snapshot's counts, reducer, panel pull, timeline entries, rows, apply and tile, layout, and the first display refresh. History pages print their own fetch time. URLSessionWebSocketTask hands over whole messages, so the first and last byte of a frame can't be told apart; `request sent` to `frame received` is server time plus transfer.

| Stage | Before | After |
|---|---|---|
| Synthetic huge thread, parse 8.3 MB snapshot | 87 ms | 48 ms |
| typed decode | 10.8 ms | 8.7 ms |
| entries + derive + panel | 9.4 ms | 7.1 ms |
| same thread, all 5,700 rows: parse, decode, entries, derive, panel | 230, 34, 33, 38, 127 ms | 110, 28, 18, 29, 86 ms |
| `markdown_parse_lines` (27 KB of short lines) | 302 ms | 34 ms |
| Sandbox "Numbers 1 to 1000", click to first frame | 52 to 64 ms | 28 to 48 ms |
| same, timeline tile (markdown parse and layout of the visible rows) | 18 to 21 ms | 7 to 8 ms |
| same, reopen within 5 minutes | as a cold open | 23 to 31 ms, no network before the paint |

## Caveats

- Neither commit printed sidebar times on the `--server` path; ServerController marks them, and the development path skips ServerController. Main gets the marks in `Environments` (this change). The milestone 5 build was measured with a one-line patch (`LaunchTiming.mark("live sidebar")` after the first sidebar pull in `ShellSession`) and the `--perf-scroll` hook copied into its `AppDelegate` (`dd10f48-measurement.patch`); its run is labeled `dd10f48-dirty`. To repeat it: `git worktree add --detach /tmp/cw-perf/src-dd10f48 dd10f48`, `git -C /tmp/cw-perf/src-dd10f48 apply <repo>/docs/perf/dd10f48-measurement.patch`, then `scripts/perf-review --source /tmp/cw-perf/src-dd10f48`.
- `cached sidebar` is empty on the `--server` path: nothing writes the sandbox environment's shell cache there.
- The machine has no display; the GUI session draws a virtual 1920x1080 screen at 2x (3840x2160 backing). Window buffers are four times a 1x screen's.

## OS cooperation and the performance HUD (WP8.4, 2026-10-11)

Release builds of dc64b72 plus this change (`dev.candywrapper.test.oscoop`) and of dc64b72 alone (`.oscoopbase`), against the sandbox server while three other agents built and ran turns. CPU and wakeups from `scripts/procstat`, App Nap state from `sudo taskinfo <pid>` ("req suppression (App Nap) behaviors"), assertions from `pmset -g assertions`.

Timer audit. Every repeating timer or loop, what it does and whether it runs while nothing changes:

| Where | Purpose | Runs while idle? |
|---|---|---|
| `ConnectionSupervisor.startPinging` | socket keepalive ping, 10% tolerance | only while the app is active |
| `SidebarView.scheduleLabelTimer` | one-shot aimed at the next relative-time label change, 10% | only while a visible label can change and the window is visible |
| `TimelineWorkRows`, `SubagentCardRowView`, `ProviderSubagentBarView`, `ThreadLineageSectionView` | 1 s elapsed-time labels, 10 to 25% tolerance | only while a run or subagent is live |
| `GitController.startTicking` | 1 s progress label | only while a git action runs (tolerance added) |
| `PullRequestsPage.liveTimer` | `useLiveRefresh`, 60 s | only while the page is in front (tolerance added) |
| `SettingsHostAccess` ticker | 1 s countdown labels | was: whenever Settings was open. Now: only while a link or session is listed |
| `DesktopManagedController.startPasswordClock` | SSH password expiry, 1 s | only while the prompt is visible (tolerance added) |
| `ThreadCache.drain`, `ShellCache.writeWhenQuiet` | disk cache writes | only while writes are pending (now `.utility`, tolerance added) |
| `ServerLifecycle` idle timer | stop our server after the idle timeout | one dispatch timer, `min(60 s, 10%)` leeway |
| `LoopingAnimation` (spinner, skeleton, working shine) | infinite CA loops in the render server | only while visible, unoccluded and motion allowed |
| `TerminalStatusGlyph` pulse | sidebar terminal indicator | was: whenever a terminal ran, even hidden or occluded. Now through `LoopingAnimation` |
| `BrowserPanelView` reload spin | page loading | only while loading |
| `TimelineView.markFirstFrame` | display link | development timing only, one frame |

The rest are one-shot `asyncAfter` and `Task.sleep` debounces, copy confirmations and request timeouts tied to a user action. One-shot `Timer`s that remain got at least 10% tolerance (toast dismissal, quit hold, browser resize, Codex sign-in).

App Nap. Nothing calls `beginActivity`, sets `NSAppSleepDisabled` or holds a power assertion (`pmset -g assertions` lists none for the app). Launched with `open -a` and hidden with Cmd+H, the app naps after 40 to 60 s: "active low-priority-cpu (4) timer-throttling (LATENCY_QOS_TIER_5) disk-throttling bg-sockets", the same set Safari gets when hidden. An app started by `scripts/run-app` never naps, because exec'ing the binary under `launchctl asuser` gives it no LaunchServices task role (`TASK_UNSPECIFIED`, bundleID NULL in `lsappinfo`). Measure App Nap through `open`. T3 holds no exemption during turns, so neither does the app.

| State (new build) | CPU | Interrupt wakeups/s | Footprint |
|---|---|---|---|
| Draft page, visible, update toast showing, HUD hidden | 0.26% | 0.70 | 46.5 MB |
| Welcome page, own server, HUD hidden | 0.01 to 0.02% | 0.37 | 49 to 52 MB |
| Same, HUD shown | 0.26% | 4.47 | 52.8 MB |
| Same, hidden and napping | 0.01% | 0.40 | 52.1 MB |

Settings open, 40 s windows alternating builds: dc64b72 2.30 and 1.05 wakeups/s, this change 0.53, 1.35, 0.62 and 1.30. The removed 1 Hz ticker is below the noise from the other agents' turns; the code no longer creates it.

Server. The app starts its own server only when nothing serves the home, from `ensureRunning` at launch and after an idle stop. The owned server ran with "low-priority-cpu (4) bg-allsockets" (`PRIO_DARWIN_BG`) while no run was active, idle at 0.21% CPU, 12.8 interrupt and 1.2 package idle wakeups/s and 187 MB, plus `t3-resource-monitor` at 0.55% and 0.2 wakeups/s (60 s, `procstat --tree`). That matches the M1 baseline: the wakeups are T3's own timers. Quitting with an Apple Event stopped the server and its child within 250 ms; `LocalServerIntegrationTests` reports "stop took 0.42 s, family of 2".

HUD. ⌥⇧⌘P or "hud" in the palette. It reads `proc_pid_rusage` every 0.5 s with 10% tolerance, only while the window is visible. Frame time is the longest main run loop pass, wake to sleep, since the last sample: a frame's layout, drawing and Core Animation commit happen inside one pass, and measuring it needs no display link. Events are server messages decoded by any socket, counted only while the HUD is shown. During a haiku turn it read 12.3% CPU, a 29.6 ms longest pass, 14.5 events/s and 145 MB. Showing it costs about 4 wakeups/s. Hidden it costs nothing beyond one uncontended lock per received frame.

## Energy by state (2026-10-15)

Task battery. `scripts/procstat` now prints each process's energy as an average in mW (`ri_energy_nj`; `ri_billed_energy` reads 0 here). Release build of 428998c with its own 3105 server on a copy of `perf-home-pristine`, so CandyWrapper started and owned the server, window 1100x780 frontmost unless hidden. Turns were claude-haiku-5-5 writing 300 numbers as words. CandyWrapper is under its own name, the server tree under the others, and WindowServer is the rise over its own idle of 8.0 mW (`sudo procstat`), so read that column as a rough share.

| State | CandyWrapper | WindowServer rise | T3 server | Resource monitor | Claude processes |
|---|---|---|---|---|---|
| Idle, window shown, server settled | 0.01 mW, 0.8 wk/s | | 0.25 | 1.35 | 0.3 each |
| Idle, window shown, server's first minutes | 0.00 | | 3.30 | 1.34 | none yet |
| Idle, window hidden | 0.00, 0.7 wk/s | | 0.13 | 0.49 | 0.2 to 2.5 each |
| Reply streaming, short thread, 20 s | 6.2, 6.2 wk/s | 1.6 | 11 | 2.5 | 4 to 44 |
| Reply streaming, long thread ("Numbers 1 to 1000"), 20 s | 10.0, 8.2 wk/s | 2.6 | 32 | | |
| Three agents in other threads, window shown, 30 s | 1.7, 1.4 wk/s | | 36 | 1.6 | about 26 together |
| Three agents, window hidden, 30 s | 1.25, 1.0 wk/s | | 28 | 0.6 | about 11 together |

The app itself is at the floor when idle and costs 1 to 10 mW while agents work, 3 to 15% of the total. The rest is T3's: the server, its resource monitor (`t3-resource-monitor`, a sample every 5 s without a Diagnostics subscriber or on battery, `NativeTelemetryClient.ts:42-45`) and the Claude processes, which T3 keeps 30 minutes after their last turn (`ProviderSessionManager.ts:54`, not a setting). The official app runs the same server. For scale, two hours of streaming into a long thread costs CandyWrapper about 90 J, about 0.05% of a 52 Wh charge.

At steady idle the owned server costs about the same at normal and background priority (0.25 and 0.13 mW), so the 2026-10-14 change that keeps it at normal priority while the app is active costs no measurable energy. Frames decode on a detached task at default priority; moving them to efficiency cores would save well under 1 mW while streaming.


## Battery during runs (2026-10-11)

Task battery, worktree agent-a20c5cd6caf7826c0. The states a user sits in for hours while agents run, each measured with `scripts/procstat` (CPU, interrupt and package idle wakeups) and `sudo powermetrics --samplers tasks --show-process-energy` over the same window. Debug builds against the shared sandbox server, where three other agents built and ran turns: the 1-minute load sat at 2.2 to 5 during the A/B windows and up to 12 during the single runs. A running turn that streams nothing came from a haiku turn told to wait in the foreground on `until [ -f <file> ]; do sleep 2; done` until I touched the file; a raw `sleep` or `ping` wait is refused by the agent's harness. During that wait the server sent the client nothing for 20 s, so every wakeup below is the client's own.

A/B: the HEAD build (before) and this change (after) ran at the same time, windows side by side and both visible, on the same running thread. Same second, same load.

| State | CPU before / after | Interrupt wk/s before / after | Pkg idle wk/s before / after | Energy Impact before / after |
|---|---|---|---|---|
| Running thread open, quiet, first minute of the run (50 s) | 1.45% / 0.49% | 3.18 / 3.04 | 1.78 / 1.84 | 6.72 / 0.60 |
| Running thread open, quiet, after a minute (60 s) | 0.32% / 0.26% | 3.53 / 2.88 | 1.15 / 1.03 | 1.29 / 0.68 |
| Thread running in the sidebar, another thread open (60 s) | 0.07% / 0.07% | 0.45 / 0.50 | 0.23 / 0.22 | 0.38 / 0.14 |
| Window minimized during the run (60 s) | 0.01% / 0.02% | 0.52 / 0.50 | 0.22 / 0.17 | 0.07 / 0.09 |

Single runs, one build at a time (load 3 to 12, so read them as bounds):

| State | Before | After |
|---|---|---|
| A reply streaming in the open thread (haiku, "1 to 400 as words", 40 s) | 0.51%, 3.35 wk/s | 0.25%, 2.15 wk/s (with `sample` attached) |
| A reply streaming in a thread that is not open (25 s) | | 0.24%, 1.04 wk/s |
| Terminal drawer open and idle (60 s) | 0.03%, 0.45 wk/s | |
| Right panel with Files and Diff tabs, idle (60 s) | 0.04%, 0.53 wk/s | 0.09%, 0.23 wk/s |
| Running thread open, quiet (three 60 s windows) | 0.17 to 0.60%, 3.0 to 3.65 wk/s | 0.10 to 0.13%, 2.87 wk/s |
| Window minimized during the run (60 s) | 0.07%, 0.37 wk/s | 0.00%, 0.42 wk/s |

For scale, the official app idles at 2.04% CPU and 74.5 wakeups/s across its processes and streams at 15 to 16% CPU ("Milestone 8 side by side" in docs/benchmarks.md).

What woke the app, per state (`sample` on the main thread, timer callbacks counted):

- Running thread open: the timeline's "Working for 4m 38s" label once a second. T3 does the same: `WorkingTimer` runs a 1 s `setInterval` (MessagesTimeline.tsx:3496-3516) and `formatDuration` always shows seconds (packages/shared/src/orchestrationTiming.ts:36-53), so the label really changes every second. Kept.
- Every visible sidebar row whose run was under a minute old: the label timer rebuilt the whole sidebar model (sort, shelves, row models) once a second, about 1 ms of main-thread work in Debug each time, out of phase with the timeline's tick. T3 re-renders only the `WorkingDuration` span (Sidebar.tsx:361-372). Now that tick redraws only the working rows; relative times and snooze countdowns still rebuild, because they can move rows between sections.
- Subagent cards in the timeline ticked once a second for their whole life, though `formatElapsedSeconds` drops the seconds after an hour ("1h 05m"), and kept ticking while the window was covered. The lineage section's compact times ("12m", "1.5h") change once a minute or once every six minutes and ticked once a second, also while hidden. The provider subagent bar ticked whenever it was in a window, covered or minimized. T3 ticks all three with a 1 s `setInterval` regardless (AgentElapsed.tsx:63, ProviderSubagentBar.tsx:51).
- The tool row's shine and the sidebar's terminal pulse run in the render server through `LoopingAnimation` and wake the app never; both stop while the window is covered. The sidebar's Working icon is static, as T3's `CircleDashedIcon` is (Sidebar.tsx:2060-2061), and its label has no shimmer (Sidebar.tsx:1298-1302).
- Window minimized, covered or hidden: nothing ticks. Server events of running threads still arrive and update the stores (T3's `RunningThreadKeepAlive` does the same), but a quiet run sends none.

The change. `DesignSystem/Components/LabelClock.swift` is one timer for every live elapsed or relative-time label: each label asks for a tick at the moment its text next changes, the clock rounds that up to the next whole wall-clock second, so every label due in the same second shares one wakeup. It fires only for views in a visible, unoccluded window, and delivers a due tick as soon as the window shows again (occlusion and unhide notifications), so labels are fresh after a hidden stretch. The timeline Working row, the provider subagent bar, subagent cards, the lineage section and the sidebar label refresh all use it. `ThreadRelationships.msUntilElapsedChanges` says when an elapsed text next changes. A label can now lag the exact second by up to one second; T3's `setInterval` labels lag by the same, because their phase is the mount time.

Tried and dropped: drawing the ticking label into a plain `CALayer` (`makeBackingLayer`) instead of AppKit's backing layer. A bare app with one 14 pt label redrawn once a second, 30 s each, alternating: no redraw 1.13 wakeups/s, AppKit layer 2.20 and 2.23, plain layer 3.30 and 3.10, CPU 0.05 to 0.10% either way, and no graphics memory in either (`footprint` shows 16 KB IOAccelerator). At one redraw a second AppKit drawing is the cheaper one.

Seen in passing: the user's own demo app (Release, dc64b72, on the live T3 where several agents ran) read 0.6 to 6% CPU and 1.3 to 22 interrupt wakeups/s in the same powermetrics windows. It was not touched or sampled, so its cause is open: the live home has many running threads and long streaming conversations, which the sandbox runs here did not reproduce.

## Font and dialog backdrop memory (2026-10-11, WP8.6)

Release builds of f8362c3 (before) and the WP8.6 working tree (after), both with the bundle id `dev.candywrapper.test.fontblur`, against the shared sandbox server on the thread `fontblur-measure`, run one after the other in one session. A keychain prompt from another app held the focus, so keys went straight to our PID (`CGEvent.postToPid`). Memory from `footprint <pid>` and the `All zones` line of `heap <pid>`; no malloc stack logging, so the numbers sit lower than WP8.5's.

| | Before | After |
|---|---|---|
| Terminal open, after printing Nerd Font code points | 70 MB footprint, heap 36.7 MB with three 4096 KB blocks | 58 to 59 MB, heap 24.2 MB, no 4 MB blocks |
| Five close dialogs opened and cancelled, 8 s later | 70 to 99 MB (+29), Malloc Large 9.4 to 34 MB | 58 to 63 MB (+5), Malloc Large under 1 MB |

The font: T3 ships `SymbolsNerdFontMono-Regular.woff2`, and CoreText decodes WOFF2 into heap that lives as long as the process. We now ship the same font as TTF, rebuilt from the tables CoreText exposes for the WOFF2 (`CTFontCopyAvailableTables`, `CTFontCopyTable`, a new table directory, 4-byte padding, table checksums, `head.checkSumAdjustment`). The result is 2,507,276 bytes, exactly the WOFF2 header's `totalSfntSize`, and rebuilding it again gives the same bytes. All 10,410 mapped code points have the same glyph id, advance and `CTFontCreatePathForGlyph` outline in both files. `vmmap` shows the TTF as a mapped file with 96 KB resident. The bundle grows by 1.3 MB; fonts are outside the spec's 25 MB limit.

The backdrop: `ModalHost.blurredSnapshot` drew the window at backing scale (about 10 MB at 2x) and downscaled it to a quarter of the point size before the sigma 1 blur. It now draws the view at half its point size (1/16 of the pixels) and downscales that to the quarter. Drawing straight at a quarter moved thin text and borders by up to 10 levels under the 60% tint (dark, 0.19% of pixels over the fidelity tolerance); the half-size pass keeps the worst pixel at 2 (light) and 5 (dark) levels, mean 0.03 and 0.27 (`OverlaysFidelityTests.smallSnapshotMatchesFullSize`). On screen the close dialog looks the same in light and dark. The command palette uses the same function.

## Heavy surfaces (2026-10-11, WP8.5)

Release builds of dc64b72 (before) and the WP8.5 working tree (after), both with the bundle id `dev.candywrapper.test.heavy`, against the shared sandbox server, alternating builds in one session. Three other agents built and tested meanwhile (load average 3 to 37), so the numbers below lean on main-thread samples and memory more than on CPU.

### Browser preview, animated page

Workload: a server browser tab in the right panel (about 400x545 pt, 2x) on `scratch/site/anim.html` (a 120 px square rotating every 2 s), served by `python3 -m http.server`. CPU and footprint from `proc_pid_rusage` over 10 s windows (`/tmp/cw-perf/bin/probe rusage`); before and after each window a screenshot checked that our window was frontmost and showing the page, because other agents' windows cover the same spot and an occluded window stops the stream. Main-thread time from `sample <pid> 10`: samples outside the run loop's mach port wait, over all main-thread samples.

| | Before | After |
|---|---|---|
| App CPU | 10.0, 10.4% (unchecked runs: 12.0, 10.7%) | 3.6, 3.4, 3.8, 3.5% |
| Footprint while streaming | 50 to 55 MB | 43 to 45 MB |
| Main thread busy | 14.0% | 0.2 to 0.7% |

Where the time went before: 969 of the 998 busy main-thread samples sat in `ServerBrowserView.setFrame` → `CA::Transaction::commit` → `CA::Render::copy_image` → `IIOImageProviderInfo::CopyIOSurface` → `AppleJPEGReadPlugin`. The background decode with `kCGImageSourceShouldCacheImmediately` did not help: Core Animation asks the image's ImageIO provider for an IOSurface, and ImageIO decodes the JPEG again, on the main thread, for every frame. Two dead ends on the way: a plain bitmap `CGImage` made CA color-convert every frame on the main thread at commit (17.9% CPU, 215 MB footprint), and an ImageIO draw into our own IOSurface took the main thread to 0.7% but left the total at 12% (1.6 to 1.7 ms of CPU per 800x1090 frame, a new VideoToolbox session per frame inside ImageIO). One VideoToolbox JPEG session per stream costs 0.08 ms of CPU per frame (a throwaway benchmark, 200 frames: ImageIO decode 0.93 ms, ImageIO into an IOSurface 1.6 to 1.7 ms). Colors: the square's center read (207, 50, 173) before and (206, 51, 171) after on screen; the test compares both decode paths within 2 levels.

T3's own client acks each frame on arrival (serverBrowserStream.ts:259-262) and stops the stream only when its surface is not `visible` (ChatView.tsx:10970, ServerBrowserSurface.tsx:371), staying connected under the empty and unreachable states (PreviewView.tsx:1082-1086). We do the same, and also stop while the window is occluded or minimized, as before. The protocol is unchanged.

### Mermaid web view start

Main-thread CPU (`CLOCK_THREAD_CPUTIME_ID` on the main thread) from the first `MermaidDiagrams.result` to the rendered diagram, and the wall time to the diagram, six starts per build in a Debug `swift test` probe, each after the 5 s idle release. Before and after alternated in one session.

| | Before | After |
|---|---|---|
| Main thread, cold (first start) | 111 ms | 77 ms |
| Main thread, warm | 54 to 75 ms | 27 to 29 ms |
| First diagram, warm | 174 to 223 ms | 150 to 163 ms |

What stays on the main thread is creating the `WKWebView` and handing WebKit the script; the read and LZMA unpack run in a detached task while the web content process starts, which is why the first diagram also shows sooner.

### Terminal panes opened and closed

Malloc stack logging on (`MallocStackLogging=lite`), so the absolute numbers run high: 62.7 MB before, 85.6 MB with three panes, 114.4 MB after closing them through their confirm dialogs (peak 202.8 MB). `heap` finds no terminal views, buffers or attachments after closing. `malloc_history` names what stays: three 4.1 MB `CFData` blocks from CoreText converting the WOFF2 Symbols Nerd Font to TTF on first terminal use (live for the process), and 25 MB of `Malloc Large (empty)` from the confirm dialogs' backing-scale window snapshots (`ModalHost.blurredSnapshot`), freed but kept dirty by the allocator; `malloc_zone_pressure_relief` returned 0 bytes. PROGRESS.md "Known bugs" has the two possible fixes.

## Idle footprint (WP8.2, 2026-10-11)

Method: Release builds of 35e734e, 8739e4f (`/tmp/cw-perf/dd-*`) and the WP8.2 tree, launched in turn against the sandbox server with `--fake-t3-connect`, `CANDY_THREAD_CACHE=off` and a fresh UserDefaults domain, sampled 15 s after launch with `vmmap --summary` (physical footprint, malloc zone table) and `heap` (live bytes, class counts). Three rounds alternating the builds; other agents were building at the time, so footprint wanders about 1.5 MB within a build while `heap` stays within 0.6 MB.

| Build | Idle footprint | Live heap | Thread open ("Reply with one word: candy") |
|---|---|---|---|
| 35e734e | 35.9 to 36.3 MB | 14.5 MB | 37.6 MB |
| 8739e4f | 40.4 to 40.6 MB | 17.1 MB | 42.3 to 42.7 MB |
| WP8.2 | 37.1 to 38.7 MB (median 37.4) | 14.5 MB | 40.2 to 41.4 MB |

What held it: about 260 more views at launch than 35e734e, most of them hidden (a view costs 5 to 8 KB of heap with its layer, layout aux, constraints and drawing caches), an ICU number formatter (400 KB) built by the closed pull request surface's diffstat, the composer's file link regex (133 KB) compiled for an empty prompt, the Cmd+Q overlay (290 KB) and the sidebar rename field (330 KB). Found with `MallocStackLogging=lite` and `malloc_history -callTree`, then a view census of the window (518 of 592 views in the thread panel were hidden). These are now built on first use (`LazyView`), and closing the right panel, thread search or Settings releases what they built.

Fragmentation is the rest of the gap and is the same in every build: the default zone holds 9 to 10 MB of free space inside dirty `Malloc Small` pages (40% to 44%). `MallocMaxMagazines=1` brings the WP8.2 build to 34.1 to 34.6 MB, so most of it is launch work allocating on several CPUs' magazines (JSON frames decoded through `JSONSerialization`, then `JSONValue`, then `Codable`, off the main thread). `malloc_zone_pressure_relief` frees 0 bytes, before and after closing surfaces. The same holds for closed surfaces: opening diff, files and linked pull requests, closing the panel and opening and closing Settings left the heap 9 MB higher before the release-on-close changes and 3.4 MB higher after (the diff panel, which keeps its selected turn, plus AppKit and CoreText caches), but the footprint stays near its high point because freed blocks stay in malloc.

## Milestone 7 wrap-up (2026-10-11)

`2026-10-11-8739e4f-w1` (with `--stream`) against 35e734e, 36 commits apart. Real changes, which M8 picks up:

- Idle footprint 32.9 to 39.5 MB, `Malloc Small` +5 MB at launch (a probe gave 36 to 41 MB before a turn). It grew across the feature commits; no single commit stands out yet.
- Shipped bundle 18.8 to 25.8 MB: the stripped binary 17.3 to 22.4 MB, the rest resources (the Symbols Nerd Font is 1.2 MB, Mermaid 0.75 MB).
- `-Osize` on the same commit (`/tmp/cw-perf/osize/2026-10-11-8739e4f-osize-w1`) cuts the stripped binary to 18.9 MB and the shipped bundle to 22.3 MB, with no regression verdict: benchmarks moved +2 to +8%, idle and scroll stayed the same.
- Against the spec's 25 MB bundle limit, which excludes bundled fonts: 24.6 MB at -O and 21.1 MB at -Osize. Every other spec target holds: live sidebar 226 ms, idle CPU 0.035%, 0.37 wakeups/s, 1.9% CPU while streaming, 39.5 MB at launch.

Not regressions:

- `stream.peak_footprint_mb` 34.1 to 95.6 MB is the two-mode noise below. A probe that samples `footprint` through one turn with the window drawing gave 93 MB at 35e734e and 99 MB at 8739e4f, both with 48 MB of `Owned physical footprint (unmapped) (graphics)`; 35e734e's run must have been the not-drawing mode. `stream.settled_footprint_mb` (+11.6 MB) is the same mode difference plus the idle growth: the probe read 43 and 49 MB 8 s after the turn.
- The open first-frame times move 40 to 70 ms between runs of one build (59, 64 and 60 ms at -O; 70, 54 and 44 ms at -Osize), so their deltas need an A/B before they count.

## Noise found 2026-10-10

The milestone 6 review flagged `stream.footprint_mb` (+53%) and `stream.package_idle_wakeups_per_s` (+67%). An A/B of the streaming scenario, three rounds alternating ef84b1d and 903e0a2, showed both builds landing on either about 36-56 MB or about 86 MB one second after the turn (ef84b1d: 87.4, 86.9, 36.2; 903e0a2: 85.9, 51.4, 86.3), with the same peak (86.5 to 88.2 MB), and package idle wakeups overlapping (0.97 to 1.27 against 1.07 to 1.46). Both metrics are now informational; the stream peak and CPU still gate.

On 2026-10-14 the review flagged `bench.huge_update_stream` at 1.07 ms (range 0.767 to 1.3) on fff9d87 against 0.731 ms on v1.0.0 (78b73ad). Interleaved runs of both Release test builds, `CW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PerfBenchmarks/hugeThreadUpdate`, six rounds each, put 78b73ad at 0.679 to 0.732 ms and fff9d87 at 0.675 to 0.743 ms. Four more rounds of the whole `PerfBenchmarks` suite gave 0.692 to 0.718 against 0.688 to 0.951, one outlier. The bench takes the median of only 10 updates, so one busy stretch on the machine moves it. Before you bisect a flag on it, rerun it interleaved with that filter, which takes about a minute per run once built.

### GPU drawing memory (answered 2026-10-10)

Why the stream scenario peaks near 87 MB when the idle scenario peaks at 31 MB: while a large view keeps redrawing, macOS draws it on the GPU, and the process then holds about 50 MB of GPU memory, shown as `owned unmapped (graphics)` in `vmmap -summary`. It is freed about 5 s after the last redraw. The cost is fixed per process: a bare AppKit window redrawing 17 lines of text once a second (`/tmp/cw-termmem/gpu/main.swift`, not kept) held 50.6 MB of it at 600x290 pt, 51 MB at 1150x290 and 51.4 MB at 1800x900, and none at 300x60. `drawsAsynchronously` changes nothing. Drawing into our own bitmap and setting `layer.contents` avoids it (36 MB instead of 85 to 96 MB) but costs 3.6 times the CPU at 30 redraws a second (28% against 7.6% of a core), so the app keeps AppKit's path: the spec's CPU and energy targets are hard, and the RAM targets (80 MB at launch, 200 MB with a heavy thread) leave room. The terminal drawer shows the same thing: 63.6 MB open and idle, 114.4 MB while `top` or any steady output redraws it, 52 to 54 MB 5 s after it stops. `stream.settled_footprint_mb` samples 8 s after the turn, past the release, and gates; `stream.footprint_mb` (1 s after) stays informational.

## Streaming redraws (2026-10-11)

WP8.3. Method: `/tmp/cw-exp/stream-peak.py` adapted to bring the app forward every second (other agents' windows covered it, and a covered window draws nothing, which reads as "no graphics memory"). One haiku turn ("the numbers from 1 to 60 as English words"), `footprint` every 0.25 s. A temporary swizzle of `-[NSView drawLayer:inContext:]` logged every drawn view with its clip rect; it is not in the commit. Release builds, same bundle id, run back to back: HEAD dc64b72 and the WP8.3 tree.

| | before | after |
|---|---|---|
| Drawn views, turn plus 9 s | 87 (LabelView 73, ComposerEditor 10) | 29 (LabelView 25, no ComposerEditor) |
| Drawn area | 999k pt² | 340k pt² |
| App CPU over the turn | 1.9% | 1.7% |
| Footprint before, peak, 8 s after | 42, 100, 50 MB | 40, 98, 48 MB |
| `Owned physical footprint (unmapped) (graphics)` at peak | 48 MB | 48 MB |

What redrew before: every second the sidebar row redrew five labels when only its "Ns" label changed, and the timeline's "Working for Ns" label; every projection redrew the composer's text view and two picker labels. Labels compared fresh dynamic NSColors, which are only equal to themselves, and `ComposerView.layout` reassigned the text view's inset. The Claude provider sends assistant text as one final item, and T3 stores at most one streaming update per 400 ms (docs/protocol.md, "Streaming assistant text"), so per-token redraws don't happen with it; the partial `MarkdownView` redraw shows at settle (736x38 instead of 736x126).

Why the graphics memory stays. It is Core Animation's in-process Metal renderer for AppKit view drawing: `vmmap` names a window-sized `CA Whippet Drawable` IOSurface, and the `CAEnableMetalWhippet` default turns it off. A bare test app (`/tmp/cw-sd-exp/main.swift`, not kept), 1100x800 window, one redraw 30 times a second:

| Redraw | Graphics | Footprint | CPU |
|---|---|---|---|
| Whole view, AppKit backing layer | 51 MB | 132 MB | 23% |
| 17 pt dirty rect of it | 51 MB | 159 MB | 4.6% |
| A separate 300x60 subview | 51 MB | 140 MB | 14% |
| The same subview with `makeBackingLayer() -> CALayer()` | 0 | 19 MB | 1.4% |
| Whole view with a plain `CALayer` | 0 | 28 MB | 37% |
| Changing a layer's color or position | 0 | under 25 MB | under 1% |
| A new `layer.contents` bitmap for the subview | 0 | 18 MB | 3.8% |
| Nothing redraws | 0 | 16 MB | 0 |

So the area does not matter: one AppKit redraw of any size starts the renderer for about 5 s, and a 300x60 window doesn't. `CAEnableMetalWhippet NO` is worse: it renders on the CPU and the whole-view case held 71 MB of CoreAnimation and 57 MB of Malloc Small. Plain `CALayer` backing avoids it and is ten times cheaper for small redraws, but it keeps a bitmap per drawn view where AppKit keeps a display list: the app with every drawn `DSView` on a plain layer (contentsScale set by hand, AppKit leaves it at 1) idled at 64 MB instead of 44 MB (the hidden `ThreadFileDropOverlay` alone drew 9 MB), and peaked at 67 MB during the turn instead of 101 MB. A plain layer taller than the screen also needs its own tiling: a 12,000 pt one held 101 MB. A turn draws from many places (new rows, the per-second labels, reasoning updates), so only moving all of them helps. Left for a decision: plain layers for small, often-redrawn views plus a tiled live mode for the streaming message, at a few MB of idle footprint.

## Streaming text (2026-10-12)

Task streamcpu. The user measured 9.9% of a core on their Mac while an answer streamed live into a long thread. The M8 side by side never saw this: T3's Claude provider sends a reply as one final item.

Wire facts first. T3 0.0.46 sends no text deltas: each `message.updated` and `turn-item.updated` carries the full text so far, and in the default `responseStreamingMode: "paragraph"` the server stores at most one update per item every 400 ms, cut at a finished block (assistantStreaming.ts:22-129, settings.ts:992-999). So a real stream is about 2.5 updates a second, each one a whole paragraph or more, and each delivered twice (message and turn item).

Method. A replay proxy (`/tmp/cw-streamcpu/proxy.swift`, not kept) sits between the app and a copy of the side-by-side home on port 47433, forwards every byte, and injects thread stream chunks into the app's `subscribeThread` stream with sequences after the server's: 30 heavy runs (user message, reasoning, six tools, a 500-word answer with headings, lists, code and tables), then a Codex-like answer of about 1,200 words that grows N words per tick, both events per tick. Thread "Seeded 2000 messages", window 1100x780 pt frontmost and unobstructed (checked by screenshot), Release builds, same bundle id, `CANDY_THREAD_CACHE=off`. CPU, wakeups and WindowServer (pid 165) from `probe rusage` over the stream; Time Profiler 15 s per round.

| App CPU over the stream | 40 updates a second, 1 word each | 2.5 a second, 20 words each (T3's rate) |
|---|---|---|
| Before (HEAD 37200e3) | 37.8%, 41.6% | 6.1%, 8.7% |
| After | 26.8% | 4.2%, 4.4% |

Where the main thread went at 40 a second, before: re-laying out the whole message 1.9 s of 15 s (tables 0.8 s), re-parsing it 0.5 s, the composer and lineage passes on every projection 0.6 s, layer display 0.5 s. What changed:

1. `MarkdownDocument.parse(_:extending:)` parses only the text after the last finished block. The cut is a line after a blank line, outside any fence, that starts at column 0 with a character that can't continue a list or a quote; text with reference definitions or HTML blocks of CommonMark types 1 to 5 parses whole. `MarkdownIncrementalTests` checks it against a full parse at every third character of a 1,900-character sample built to break it (loose lists, fences inside items, quotes after gaps, setext headings), and fails when the cut rule is loosened. The settled text still parses whole once.
2. `MarkdownLayout(reusing:)` keeps the layout of the unchanged leading top-level blocks (items, controls, tops, code index) and lays out only the rest. Reuse needs the same width, wrap and diagram state, body color, cwd, context chips and file chip labels.
3. A text-only update (`ThreadChangeSet.onlyStreamingText`, set by the reducer when an event only grows a streaming answer's or reasoning text) skips the composer's pickers, queue and request passes and the lineage pass; find still refreshes.
4. Recycled timeline rows and the hidden worktree setup card now wait in a hidden view outside the scroll document. Every document resize invalidates the visible rect of its whole subtree and AppKit then displays each drawing layer in it again, hidden ones included: 75 layer displays per update before, 20 after (counted with a temporary swizzle of `-[NSViewBackingLayer display]`). Empty `ButtonView` labels are hidden.
5. `canSplit` scans bytes; Foundation's case-insensitive search cost more than the parse it saved. The fence info regex runs only when the info has `=`.

PerfBenchmarks `markdown_stream_delta_*`, one delta near the end of a 2,151-word answer, release: full parse and layout 16.8 ms, incremental 0.46 ms median.

Update rate (brief step 4). `ThreadSession`'s pacer now caps at 30 updates a second on any screen (before: one per frame, so 120 on ProMotion). On this 60 Hz screen with the stream sent at 60 ticks a second: one render per frame gave 30.1% and 29.8% app, 63 wakeups/s, WindowServer 37.1% and 37.0%; the 30 cap gave 26.4% and 26.7%, 31 wakeups/s, WindowServer 40.0% and 39.9%. WindowServer idled at 12 to 20% on this shared screen (other agents' windows), so its stream numbers move with them; it did not drop with fewer updates. Recorded on screen, text at 30 updates a second still appears word by word, and the 600 ms block fade is unchanged. A working turn that streams almost nothing cost 0.59% app.

What is left at 40 a second (main thread 18% of a core): the last block's layout and draw per update, about 1 ms each; the timeline's row derivation 0.3 ms; window layout with AppKit's walk for Auto Layout views 0.25 ms; the document resize and scroll as the answer grows 0.3 ms; decoding two full-text events per tick off the main thread about 7%. At T3's real 2.5 updates a second all of this is about 4% on this thread. The rest would need fewer document resizes (growing it in steps, which changes scrolling at the end) or tiling the streaming message.

### Second pass (2026-10-12, task streamcpu2)

Same rig as above: the replay proxy (now also in `/tmp/cw-streamcpu2/`, not kept) on a copy of the side-by-side home, "Seeded 2000 messages" plus 30 heavy runs, window 1100x780 pt frontmost, Release builds, a fresh launch per round and three streams per mode. The proxy gained a `t3stream` mode that delivers text the way T3 0.0.46 does: the model writes 5 words every 100 ms, and an update goes out at most every 400 ms, cut at the last finished block by a port of `splitBufferedAssistantText`, and only when that cut moved (assistantStreaming.ts:35-128). On this answer that is 24 to 25 updates in 26 s. The `stream` mode of the first pass sends 20 words every 400 ms without cutting, so its last block grows in the middle of a paragraph or table every update; it is the heavier case and the one the first pass called T3's rate.

| App CPU over the stream | `stream`, 2.5 a second, 20 words | `t3stream` (T3's cut) | `stream`, 40 a second, 1 word |
|---|---|---|---|
| Before (HEAD d3fd7b7) | 4.62, 4.62, 4.30% | 2.27, 2.12, 2.24% | 27.95, 27.75, 28.91% |
| After | 3.57, 3.19, 3.47% | 1.96, 1.79, 1.74% | 22.17, 22.48, 22.52% |

Wakeups at 40 a second fell from 57 to 61 a second to 36 to 38; WindowServer from 32.4% to 27%. A working turn that streams almost no text costs 0.32% (the "Thinking" shine and the "Working for" clock).

Main thread per update, from Time Profiler over 60 updates of the `stream` mode at 2.5 a second (ms per update; before, each update rendered twice):

| Phase | Before | After |
|---|---|---|
| Decode (frame, JSON, typed; off the main thread) | 0.4 | 0.6 |
| Reduce (off the main thread) | 0.65 | 0.5 |
| Rows (`TimelinePipeline.run`) | 1.3 | 0.8 |
| Markdown parse | 0.6 | 0.7 |
| `preservesAssistantLineBreaks` | 0.7 | 0 |
| Markdown layout of the last blocks | 1.9 | 2.0 |
| Window layout pass | 2.0 | 0.9 |
| Layer display | 1.8 | 1.7 |
| Document resize and tracking areas | 2.1 | 1.0 |
| Main thread in all | 14.0 | 10.6 |

What changed:

1. Each streaming update reaches the panel once. T3 sends `message.updated` and then `turn-item.updated` with the same text (assistantStreaming.ts:92-128), and the subscription hands them to the store one value at a time, so the pacer pulled after the first and again after the second: two renders, two layouts and two commits per update. While text streams, `ThreadSession` asks the pacer to wait one frame (16 ms) before the first pull of a quiet spell, which catches the second event; any other change still renders at once. Panel updates went from 76 to 38 in 15 s at 2.5 a second (counted with dtrace).
2. A text-only update skips the panel's own pass (`ThreadPanelView.setProjection(..., onlyStreamingText:)`): the diff summaries, proactive panels and composer layout read nothing that text changes. The header's title setters skip unchanged values, which had set `needsLayout` on the panel and run its layout, the header's and the banner stack's on every update.
3. The streaming row is measured in `setItems` instead of getting an estimated height there and its real height in `tile`: one document resize per update instead of two.
4. Empty `ButtonView` labels leave the view tree. A zero-size layer can't hold contents, so Core Animation displayed it again in every commit, hidden or not: 55 displays in 12 s for a code block's copy and wrap buttons. With items 1 to 4, layer displays per streamed update went from 36 (two renders) to 12.
5. `TL.preservesAssistantLineBreaks` finds the "★ Insight" marker with `memmem` before the regex; `String.contains` scanned the whole answer per update.
6. `MarkdownLayout(reusing:)` also hands its text boxes to the next layout (`TextBoxCache`), keyed by everything that shapes them, so the cells of a table and the items of a list above the growing end skip TextKit. `MarkdownIncrementalTests.growingTableReusesItsCells` checks the reuse and that the result matches a fresh layout. Markdown layout per update fell from 2.8 to 2.0 ms between two otherwise equal builds.

What is left and why. The 2% target holds for T3's real cut (1.74 to 1.96%), not for the uncut `stream` mode (3.2 to 3.6%). The rest is spread thin:

- Laying out the growing last block (2 ms) is TextKit 2 laying out the whole paragraph or table again; with T3's cut the last block is finished and only new blocks are laid out.
- Layer display (1.7 ms): AppKit marks every view it drew itself (`layer.contents` is `NSViewBackingLayerContents`) as needing display whenever the visible rect of an ancestor changes, in `-[CALayer(NSViewVisibleRect) NS_viewVisibleRectDidChange]`, read from the disassembly. Every scroll step and document resize does that, so the streaming row's labels and the whole visible part of its markdown view redraw per update, not only the changed lines. Avoiding it means drawing those views into our own layer contents, which risks the text rendering the fidelity tests pin.
- The window layout pass (0.9 ms) walks all 908 views of the window looking for Auto Layout (`_findAnySubviewNeedingAutoLayoutEngine`); 661 of them are hidden (parked rows 145, the thread details card 81, closed drawers and banners). Laying the row out synchronously made AppKit walk more, not less.
- Growing the document in steps was not done: the scroll that follows the end would still move every row each update, and that scroll invalidates the same visible rects and tracking areas as the resize.
- Decoding the text twice costs 0.5 ms per update in all, off the main thread; not worth a change to the wire path.

## Redraws on scroll and resize (2026-10-12, task redraw)

Mechanism, from the disassembly of AppKit on macOS 27. `NSViewHierarchyInvalidateVisibleRect` walks into every subtree whose views remembered a visible rect (the `_hasCachedVisibleRect` and `_descendantHasCachedVisibleRect` bits) and calls `-[CALayer(NSViewVisibleRect) NS_viewVisibleRectDidChange]` on each one. That method checks only whether the layer's contents are AppKit's (`NSViewBackingLayerContents`), and if they are it calls `setNeedsDisplayInRect:`. It does not compare the old rect with the new one and does not check whether the view is hidden. A view remembers its visible rect whenever `-[NSView visibleRect]` runs, and AppKit calls that while it draws the view. Each scroll step, document resize and window resize starts the walk.

What it costs, counted with dtrace on Release builds (`/tmp/cw-redraw/*.sh`, not kept). Thread "Seeded 2000 messages" with 30 heavy runs, through the streamcpu2 replay proxy:

| Event | Visible-rect calls | Layer invalidations | Layer displays | `draw(_:)` calls |
|---|---|---|---|---|
| 31 streamed updates (`stream 2.5 20`) | 916 | 360 | 465 | 31 MarkdownView, 1 label, 1 minimap |
| 30 wheel scrolls of 40 px | 766 | 142 | 176 | 16 MarkdownView, 2 labels |
| 40 window resize steps of 5 pt | 21,400 | 10,693 | 11,280 | about 17 each for minimap, sidebar brand and project monogram |

The streamcpu2 notes said every visible label redraws on each update. That is not what happens. The invalidated layers get displayed, but AppKit calls `draw(_:)` only where something new became visible, so a clipped label mostly costs a display with no draw, about 6 µs each. Unclipped drawn views are the exception. Their visible rect reaches to the nearest clipping ancestor, so the 40x344 minimap gets an 844x780 dirty rect, and they redraw in full whenever that ancestor's area changes. A window resize is the worst case, at about 280 layer displays per step. An lldb sample by delegate class found 183 of 217 were `LabelView`, and 118 of those were hidden. Big markdown views redraw only the newly exposed strip; a test app scrolling 10 pt per step drew 21 pt strips.

Fix. `DSView.drawsWholeBounds` (true for truncating `LabelView`) answers `visibleRect` with `bounds` whenever the view is in a window. It never calls AppKit's version, so AppKit never remembers a rect for these views and never invalidates them. A label that is partly scrolled out draws its whole box, which the layer clip shows exactly as before. A hidden label draws too. A first version answered `.zero` for hidden labels, and on screen the composer's "Full access" and "Stash 1" and the header's "/" came up blank: they were displayed while hidden, and with no remembered rect nothing displayed them again when they showed. The offscreen tests don't reproduce that, so check it in the real window. The fidelity suite's output images are byte-identical with and without the change.

After, same rig, Release builds, three rounds each (before and after counts as above):

| Event | Layer displays before | Layer displays after |
|---|---|---|
| 31 streamed updates | 420 to 465 | 132 to 147 |
| 40 window resize steps | 10,400 to 11,280 | 2,200 to 2,240 |
| 30 wheel scrolls | 172 to 178 | 67 to 69 |
| `--perf-scroll` on "Numbers 1 to 1000" (perf workload) | 1,686 to 1,687 | 979 |

App CPU did not move beyond the noise of this shared screen. Streams at T3's cut measured 1.47 and 1.60% before, and 0.59 and 1.87% after. Resize and `--perf-scroll` CPU overlapped as well: 0.35 to 0.37 s before and 0.37 to 0.40 s after for the scroll. A layer display that doesn't draw costs about 6 µs, so 10 fewer per update is 0.06 ms. The gain is fewer layer commits and wakeups during a window resize, not a CPU number this rig can see. Idle footprint was unchanged at 47 to 49 MB.

`VisibleRectRedrawTests` scrolls an offscreen window. It fails without the change, because the clipped and hidden labels get marked for display, and it checks that an unclipped label still does. In the test app, 100 labels over 600 scroll steps gave these results:
- Unclipped labels made 10,000 label draws.
- Clipped labels made 66 draws but still had 4,040 invalidations and 4,240 displays.
- Answering `visibleRect` gave 0 draws, 40 invalidations and 240 displays, and process CPU fell from 479 to 355 ms and from 935 to 488 ms in two rounds.

Not changed:
- `TextBlockView`, `MarkdownView` and the minimap stay as they are because they don't clip, have subviews outside their bounds, or are taller than the screen, so AppKit has to keep drawing only their visible part.
- Drawing into our own `layer.contents` also stops the invalidation, since the contents are no longer AppKit's. It costs a bitmap per label and its font smoothing would need the fidelity tests re-pinned, so I didn't use it.
- `preparedContentRect` doesn't affect any of this.

Hidden views in layout walks. The window has 908 views, 608 of them hidden: the details card 81, terminal drawer 28, context strip 28, stash menu 25, error banner 22, question panel 20, parked rows 33, and smaller groups. `_findAnySubviewNeedingAutoLayoutEngine` walks all of them, but only on layout passes after a subview was added. That was 13 walks in 31 streamed updates, and Time Profiler put the walk at 3 ms in 15 s of streaming (about 0.1 ms a walk, under 0.02% of a core at T3's rate). Hidden labels now also drop out of the visible-rect displays, which was most of what they cost. Making the other surfaces lazy needs their state moved off the views first. The details card alone has 44 call sites pushing version control, lineage, scripts and pull request state into it. That refactor is worth about 2 to 4 MB of idle footprint at 5 to 8 KB a view, so I left it as a follow-up.

Scroll on the big thread ("Numbers 1 to 1000", `--perf-scroll`, before the change) used 260 ms on the main thread over 280 steps. `MarkdownView.draw` took 42 ms, all of it newly exposed strips. `TimelineView.tile` took 49 ms, mostly reconfiguring recycled rows and rebuilding their `MarkdownLayout` (16 ms). Window layout took 19 ms. None of that is the visible-rect redraw. The layout rebuild on row reuse belongs to the timeline and markdown work.

## Baseline: median of the last three runs (2026-10-10)

The a4a5a06 review flagged `big_thread.after_scroll_footprint_mb` (+16%) and `after_scroll_peak_mb` (+13%) against 5ed1646. An A/B of the big-thread scenario, two rounds per build, gave 44.7 and 44.3 MB (5ed1646) against 44.6 and 43.8 MB (a4a5a06) after scrolling, and peaks of 103.9 to 106.7 MB for both: no change. The 5ed1646 review run had been an outlier (38.2 MB). `scripts/perf-review` now compares each metric with the median of the last three saved runs (the range is the spread of those medians), unless `--baseline` names one file.

## Updating a long thread and the disk cache (2026-10-10)

Synthetic thread with all 5,700 rows loaded (`huge_full`), main-thread time per update, before (a4a5a06) and after:

| Update | Before | After |
|---|---|---|
| Streaming answer grows | 77 ms | 3.6 ms (entries and patch off the main thread; about 2 ms re-measures the answer) |
| Tool row changes state | 75 ms | 1.2 ms (full row pass, 36 ms, runs off the main thread) |
| New tool row | not measured | 3.6 ms |
| Fresh panel (`huge_full_panel`) | 91 ms | 3.3 ms |

Cold open of "Numbers 1 to 1000" on the local sandbox: 33.0 ms from the network, 32.6 ms from the disk cache. The cached open resumes after the cached sequence, so the server sends a 67-byte `synchronized` frame instead of the snapshot; the gain grows with the snapshot size and the link (the huge window is 8.3 MB on the wire, 160 KB on disk, 44 ms to load).

## Baseline series on workload 1 (2026-10-10)

The first three runs on the frozen workload, every scenario measured on a quiet machine (1-minute load 1.4 to 3.0, no compile or test process). They are the baseline series: `2026-10-10-{a4a5a06,7070d1f,dbfd490}-w1`. A second run of dbfd490 (kept out of this folder, `/tmp/cw-perf-agent/repeat/`) gives the run-to-run noise.

| Metric | a4a5a06 | 7070d1f (WP7.2) | dbfd490 | dbfd490 again |
|---|---|---|---|---|
| Window on screen | 180 ms | 174 ms | 176 ms | 170 ms |
| Live sidebar | 181 ms | 194 ms | 205 ms | 190 ms |
| Idle footprint | 31.2 MB | 32.1 MB | 32.1 MB | 31.8 MB |
| Idle CPU | 0.045% | 0.043% | 0.067% | 0.030% |
| Idle interrupt wakeups | 0.40/s | 0.40/s | 0.47/s | 0.37/s |
| Big thread peak after open | 32.5 MB | 33.1 MB | 33.7 MB | 33.2 MB |
| After scroll, footprint / peak | 44.7 / 105.5 MB | 45.4 / 107.0 MB | 45.9 / 107.6 MB | 45.3 / 107.0 MB |
| Scroll CPU time | 335 ms | 347 ms | 365 ms | 257 ms |
| Big thread first frame | 50.9 ms | 47.9 ms | 51.3 ms | 48.9 ms |
| Stream CPU / peak | 1.4% / 87.0 MB | 1.5% / 88.6 MB | 1.8% / 88.6 MB | not run |
| `huge_open_parse` | 47.9 ms | 48.8 ms | 50.3 ms | 48.3 ms |
| `markdown_layout` | 38.4 ms | 38.6 ms | 39.6 ms | 38.4 ms |
| `huge_full_reduce` | 0.96 ms | 1.00 ms | 1.21 ms | 1.18 ms |

On the frozen workload the big thread peaks at 33 MB on open in every build; the 87 MB of older runs came from a sandbox thread that other agents had since changed.

### WP7.2 verdict

- Launch: no cost. Window time moved -6 ms and the live sidebar +13 ms with overlapping ranges, and the two dbfd490 runs differ by 15 ms on their own. The +37 ms in the WP7.2 review was load from other agents, so no Time Profiler run was needed.
- Idle memory: a real but small cost, +0.6 to 0.9 MB footprint (31.0 to 31.3 MB before, 31.8 to 32.2 after, ranges apart in the review runs; one heap-check launch of 7070d1f sat at 31.0 MB). A `heap -s` diff of the idle apps shows +215 KB of live heap and 1,325 nodes: 360 more strings (93 KB) plus `ServerProviderSlashCommand` and `ServerProviderSkill` arrays (22 KB), the provider workspace snapshot the composer asks for with `server.refreshProviders` when a thread opens (`App/Sources/ComposerController.swift:1549`, T3 does the same on mount, ChatComposer.tsx:2257-2300); ICU regex sets (25 KB) from the composer's chip and trigger regexes; the hidden command menu view (`ThreadPanelView.commandMenu`, about 15 KB of views and constraints). The rest of the footprint delta is Malloc Small pages left dirty by decoding the refresh reply. Proposed: accept it. Deferring the refresh to the first `/` or `$` would save about 0.1 MB of live heap but changes when the server scans the workspace, which T3 does on mount.
- `huge_full_reduce` rose from about 1.0 to 1.2 ms in dbfd490, in both of its runs. `ThreadReducer` did not change in dbfd490; the benchmark file did (the new `huge_update_*` cases run before it and leave more heap behind). It is a synthetic 20 MB reduce, 0.2 ms, so it stays a note.

### Noise on a quiet machine

Two runs of the same build (dbfd490): launch times within 6 to 15 ms, idle footprint 0.3 MB, big-thread memory 0.6 MB, first frame 2.4 ms, micro-benchmarks 2 to 5% (the first run's benchmarks ran 4% slower across the board), idle CPU 0.030 against 0.067% and package idle wakeups 0.07 against 0.13/s. Scroll CPU time is bimodal, about 255 or about 350 ms in the same build (the repeat had 255, 257 and 347), so a single run's median can move by 30%; the range check keeps it from flagging.

The perf server once accepted connections and never answered (17 minutes on its first request). The readiness check now gives each probe 2 s and gives up after 60 s.

## Tables, Nightly 3234 and server updates, 2026-10-17

The [final review](2026-10-17-d7db15d-dirty-w1.md) covers the wide-table fix, the 3234 catch-up and independent runtime updates. Against the preceding saved run: 194 ms window, 0.045% idle CPU, 34.6 MB idle footprint and 378.5 ms scroll CPU. There were no 50 ms scrolling stalls and one 51.6 ms thread-open stall. A 40.4 MB settled streaming sample triggered the memory threshold; three isolated repeats were 34.6–34.7 MB, below the 35.5 MB baseline. Both the original flag and the follow-up data remain in the report. All 1,541 tests passed, followed by the 17 update checks after the final trial validation changes.
