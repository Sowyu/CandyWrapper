# Performance reviews

`scripts/perf-review` runs after every merged work package and every milestone (the user's rule, PROGRESS.md "Decisions made"). Each run saves `<date>-<sha>.json` and `.md` here and compares itself with the previous saved run.

## Running it

```
scripts/sandbox-server                       # or let perf-review start it (it stops only a server it started)
scripts/perf-review                          # HEAD, compared with the newest saved run
scripts/perf-review --source .               # the working tree, uncommitted changes included
scripts/perf-review --commit dd10f48 --baseline docs/perf/<file>.json
scripts/perf-review --stream                 # adds one claude-haiku-5-5 turn (costs a real turn)
```

About 12 minutes per build: 3 to 5 for the Release build, 2 for the micro-benchmarks, 5 for the app runs. Output goes to stderr as it runs; the table prints at the end.

## What it does

1. Builds a Release app from the commit into its own derived data (`/tmp/cw-perf/dd-<sha>`), from a detached worktree in `/tmp/cw-perf/src-<sha>`, or from `--source`.
2. Launches the app through `scripts/run-app` with `--server http://127.0.0.1:47391 --token-file <sandbox>/session.token --fake-t3-connect`. The fake T3 Connect flag keeps the app away from the user's saved environments and Keychain (a new build would otherwise prompt for the Clerk session on the user's screen). It checks that the PID in `/tmp/candywrapper-app.pid` belongs to its own build and stops only that PID.
3. Waits until no CandyWrapper app runs besides the user's demo app (`/tmp/cw-demo.pid`), and notes any run that overlapped one.
4. Runs three scenarios, each `--repeat` times (default 3), and reports the median and the range:
   - Launch and idle: opens the small finished thread "Reply with one word: candy". Window time comes from `probe window` (first on-screen window taller than 200 pt, measured from the process start time in the kernel). Sidebar times come from the app's `CANDY_LAUNCH_TIMING` lines. After 5 s of settling, 30 s of kernel counters (`proc_pid_rusage`): CPU, interrupt and package idle wakeups per second, footprint and lifetime peak footprint.
   - Large thread: opens "Numbers 1 to 1000 as words", footprint and peak 8 s after launch; then `--perf-scroll 12` makes the app scroll its timeline to the top and back, 300 pt per frame, 140 frames each way; CPU time of the whole window, then footprint and peak 3 s later. The app scrolls itself because scroll events posted to its PID never reach AppKit, and events through the HID tap would move the user's pointer.
   - Thread open: launches on the small thread with `--perf-open 4 "Numbers 1 to 1000"` and `CANDY_THREAD_TIMING=1`. Four seconds after the shell the app opens the big thread as a click would, 2 s later the small one, 2 s later the big one again. `open.big_first_frame_ms` and `open.big_reopen_first_frame_ms` run from `open(id)` to the first display refresh after the rows are placed (a `CADisplayLink` on the window), so they carry up to two frames of display latency. The reopen paints from the retained store.
   - Streaming (`--stream`): a fresh haiku thread made through the RPC by `scripts/perf/turn.swift`, opened in the app, then one turn ("the numbers from 1 to 60 as English words") driven by the helper while the app only watches; CPU and wakeups across the turn, footprint and peak after.
5. Bundle and binary size.
6. Micro-benchmarks: `CW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PerfBenchmarks` in `Packages/CandyKit` (`Tests/FeaturesTests/PerfBenchmarks.swift`). Deterministic inputs, a warm-up pass, then the median, min and max of 9 runs:
   - `decode_fixtures`: every frame of the 7 recorded transcripts (1.8 MB) to typed shell and thread items.
   - `thread_reducer` and `timeline_rows`: the largest recorded thread stream replayed through `ThreadReducer`, then `TimelineRows.derive` on its projection.
   - `markdown_parse` and `markdown_layout`: a generated 39 KB reply (headings, lists, code, tables) parsed, then laid out at 680 pt.
   - `sidebar_items_1000`: `SidebarListBuilder.items` for 1,000 threads in 20 projects.
   - `markdown_parse_lines`: a reply of 2,400 short lines, one paragraph of soft breaks.
   - `huge_open_*`: a synthetic huge thread, 300 copies of the largest recorded snapshot's turns (900 runs, 3,600 nodes), shaped like the server's bounded snapshot: the last 3 copies of rows and messages (57 rows) plus every run, attempt, node, checkpoint, request and provider turn of the thread, 8.3 MB as one Chunk frame. Stages: `parse` (frame to `JSONValue`), `decode` (typed `ThreadStreamItem`), `reduce`, `entries` (`TimelineRowsInput`), `derive` (`TimelineRows.derive`) and `panel` (a fresh `ThreadPanelView` at 1200x800: `setProjection` and layout). `huge_full_*` is the same thread with all 5,700 rows loaded (20 MB). `huge_open_long_*` gives every reply in the window 6 KB of markdown.

   An older checkout without the benchmark file gets today's copy.

## Verdicts

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

## Noise found 2026-10-10

The milestone 6 review flagged `stream.footprint_mb` (+53%) and `stream.package_idle_wakeups_per_s` (+67%). An A/B of the streaming scenario, three rounds alternating ef84b1d and 903e0a2, showed both builds landing on either about 36-56 MB or about 86 MB one second after the turn (ef84b1d: 87.4, 86.9, 36.2; 903e0a2: 85.9, 51.4, 86.3), with the same peak (86.5 to 88.2 MB), and package idle wakeups overlapping (0.97 to 1.27 against 1.07 to 1.46). Both metrics are now informational; the stream peak and CPU still gate. Open question for milestone 8: why the stream scenario peaks near 87 MB when the idle scenario peaks at 31 MB.
