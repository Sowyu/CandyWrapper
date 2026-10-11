# Performance reviews

`scripts/perf-review` runs after every merged work package and every milestone (the user's rule, PROGRESS.md "Decisions made"). Each run saves `<date>-<sha>-w<workload>.json` and `.md` here and compares itself with the median of the last three saved runs on the same workload.

## Running it

```
scripts/perf-review                          # HEAD, compared with the last three runs on this workload
scripts/perf-review --source .               # the working tree, uncommitted changes included
scripts/perf-review --commit dd10f48 --baseline docs/perf/<file>.json
scripts/perf-review --stream                 # adds one claude-haiku-5-5 turn (costs a real turn)
```

About 12 minutes per build when the machine is quiet: 3 to 5 for the Release build, 2 for the micro-benchmarks, 5 for the app runs. Waits for a quiet machine come on top, up to 10 minutes each. Output goes to stderr as it runs; the table prints at the end.

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
   - Thread open: launches on the small thread with `--perf-open 4 "Numbers 1 to 1000"` and `CANDY_THREAD_TIMING=1`. Four seconds after the shell the app opens the big thread as a click would, 2 s later the small one, 2 s later the big one again. `open.big_first_frame_ms` and `open.big_reopen_first_frame_ms` run from `open(id)` to the first display refresh after the rows are placed (a `CADisplayLink` on the window), so they carry up to two frames of display latency. The reopen paints from the retained store. Each run points the disk thread cache at its own empty directory (`CANDY_THREAD_CACHE`, passed through `scripts/run-app`), so the first launch opens from the network; a second launch with the directory the first one filled gives `open.big_cache_first_frame_ms`, the same open painted from the disk cache.
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
