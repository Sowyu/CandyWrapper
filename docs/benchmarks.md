# Benchmarks

Official T3 Code and CandyWrapper on the same machine and workload. Status on 2026-10-11: every row of the client comparison is measured for both clients ("Milestone 8 side by side"). The README numbers come from "README refresh against Nightly 3234 (2026-10-17)".

## Machine

Mac mini M4 (4 performance and 6 efficiency cores), 16 GB RAM, macOS 27.0.1, AC power, no battery. No physical display: the GUI session (logged in over Screen Sharing) draws to a virtual 1920x1080 screen at 1x and 60 Hz. ProMotion 120 Hz and the battery test cannot run here.

## Tools

- `scripts/procstat.swift`: CPU %, package idle wakeups, interrupt wakeups and physical footprint per process, from `proc_pid_rusage(RUSAGE_INFO_V6)` deltas over an interval. No root needed for the user's own processes. `--tree <pid>` includes all descendants, which matters for Electron helpers and server children. Build with `swiftc -O scripts/procstat.swift -o /tmp/procstat`.
- `top -l N -s 5 -stats pid,command,cpu,idlew,power,mem`: the POWER column is the same score Activity Monitor shows as Energy Impact. `top` reports 0 idle wakeups for most user processes on this machine, so wakeups come from procstat.
- Billed energy (`ri_billed_energy`) reads 0 for these processes without entitlements, so procstat does not report it.
- `sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n 6`: per-process Energy Impact, the number Activity Monitor shows. `top` reads 0 CPU and power for apps in the GUI session when run from the background session, so use powermetrics for those.
- `scripts/measure-launch.swift`: spawns an app binary in its own session with an isolated `T3CODE_HOME` and records when its first window appears. Run it inside the GUI session: `sudo launchctl asuser 502 sudo -u mrm /tmp/measure-launch <binary> <home>`.

## Server baseline (official runtime 0.0.46-nightly.20261009.2861)

Sandbox server with its own home, no connected clients, one idle Claude provider session left attached from a test turn. 60 second window.

| Process | CPU | Interrupt wakeups/s | Package idle wakeups/s | Footprint | top POWER |
|---|---|---|---|---|---|
| `t3 serve` | 0.14% | 10.7 | 0 | 205 MB | 0.05 |
| `claude` provider session (idle) | 0.45% | 10.0 | 0 | 146 MB | 0.40 |
| `t3-resource-monitor` | 0.08% | 0.2 | 0 | 3.6 MB | 0.02 |
| Total | 0.67% | 20.9 | 0 | 355 MB | |

The server alone wakes about 10 times per second when idle, ten times the app's target. CandyWrapper can't change the server, but it can avoid keeping provider sessions alive longer than the official app does. That needs checking in milestone 8.

## Server tuning (`scripts/server-idle-bench`)

Fresh server, throwaway home, no clients, 30 s window after 20 s settle. NODE_OPTIONS is honored by T3's packaged runtime, but only Node's allowlist: V8 tuning flags such as `--optimize-for-size` make the server exit at startup.

| Variant | Server footprint | Interrupt wakeups/s | Notes |
|---|---|---|---|
| Default | 313 MB | 12.5 | first run, cold start 3.0 s |
| `--max-semi-space-size=1` | 246 MB | 11.8 | chosen: 21% less memory, no visible cost |
| plus `--max-old-space-size=192` | 216 MB | 11.8 | rejected: a heap cap can crash the server on large threads |
| `T3CODE_TRACE_MIN_LEVEL=Error`, trace timing off | 314 MB | 11.4 | no meaningful change |
| semi-space 1 plus quiet trace | 245 MB | 10.7 | |

Warm starts take about 0.5 s. Idle wakeups stay at 11 to 12 per second regardless of options, which points at T3's internal timers. CandyWrapper's levers for those are stopping a server it started when idle, and background priority while no run is active.

## Official desktop app baseline

T3 Code (Nightly) 0.0.46-nightly.20261009.2861 from the official notarized DMG, run in the GUI session with an isolated home (`T3CODE_HOME=../CandyWrapper-research/desktop-home`) seeded with a copy of the sandbox demo data: project demo-repo, 14 threads, two of them waiting on an approval and a question.

Cold launch after `sudo purge`, timed from spawn:

| Milestone | Time |
|---|---|
| Bundled server ready (`server.startup` span ends) | 1.67 s |
| First window on screen | 2.95 s |
| Shell snapshot served to the renderer (sidebar data) | 3.36 s |

Idle with the window open and no turn streaming, 30 s of powermetrics after a 60 s settle. procstat over 60 s agreed within a few percent.

| Process | CPU | Interrupt wakeups/s | Package idle wakeups/s | Energy Impact | Footprint |
|---|---|---|---|---|---|
| Main (Electron) | 0.23% | 3.7 | 2.3 | 0.21 | 82 MB |
| GPU process | 1.20% | 63.2 | 38.4 | 1.27 | 192 MB |
| Renderer | 0.46% | 6.1 | 3.5 | 0.40 | 126 MB |
| Network service | 0.05% | 0.6 | 0.4 | 0.04 | 9 MB |
| Bundled server | 0.35% | 14.3 | 7.7 | 0.91 | 133 MB |
| Resource monitor | 0.33% | 0.2 | 0 | 1.45 | 4 MB |
| Total | 2.6% | 88 | 52 | 4.29 | 544 MB |

The GPU process wakes about 63 times per second while nothing changes, which looks like a compositor frame loop held open by an animation. The seeded data has two threads waiting on input, so their sidebar indicators may be animating. Repeat with no waiting threads before quoting this number as the floor.

Bundle size: 366 MB, of which `Frameworks` (Electron) is 239 MB and `Resources` (web client, server, native modules) is 127 MB.

## Client comparison

| Metric | Target | Official app | CandyWrapper |
|---|---|---|---|
| Cold launch to interactive sidebar | < 300 ms | 3.71 s to sidebar data (window 3.44 s, bundled server ready 2.35 s), 2026-10-11 | 0.20 and 0.22 s live sidebar on relaunch (window 0.16 and 0.17 s); 0.71 s on the first launch of a new build. Server already running |
| Idle CPU, window visible, no turns | ~0% | 2.04% app processes; server 0.37%, resource monitor 0.34% | 0.00% app; server 0.48% |
| Idle wakeups, app process | < 1/s | 74.5 interrupt and 36.3 package idle per second over the app's processes (GPU process 64 and 33); server 14.5 | 0.03 interrupt, 0.02 package idle; server 11.1 |
| CPU while streaming one turn | < 5% of one core | 15.9% and 15.1% app processes (renderer 9.2/8.3, GPU 6.3/6.3); server 4.6% and 2.2% | 1.26% and 1.26% app; server 3.0% and 2.9% |
| CPU while text streams token by token into a heavy thread | < 5% of one core | not measured (T3's wire sends at most 2.5 text updates a second per item) | 1.74 to 1.96% app with T3's block cut (2.12 to 2.27% before the second pass); 3.2 to 3.6% at 2.5 uncut updates a second (4.3 to 4.6% before; 6.1 and 8.7% before the first pass); 22.2 to 22.5% at 40 a second (27.8 to 28.9% before; 37.8 and 41.6% before the first pass); WindowServer 27% at 40 a second (32% before) on this shared screen. docs/perf/README.md, "Streaming text" |
| Energy Impact idle | ~0 | 2.40 app processes; server 1.63, resource monitor 1.28 | 0.00 app; server 3.03 |
| Energy Impact streaming | < 1/5 of official | 103.5 and 66.7 app processes (mean 85.1); server 72.9 and 29.6; Claude provider 154 and 93 | 16.9 and 13.2 app (mean 15.1, 0.18 of official); server 57.6 and 47.7; Claude provider 139 and 124 |
| RAM fresh launch | < 80 MB | 469 MB app processes, idle on a thread; server 140 MB | 41.3 MB app, idle on a thread; server 195 MB |
| RAM, 50 threads + 2,000-message thread | < 200 MB | 500 MB app processes as opened (last 20 messages); 461 MB with all 2,000 loaded | 71 MB as opened; 153 MB right after paging in all 2,000, 90 MB 30 s later; lifetime peak 246 MB during the paging scroll; 148 MB at v0.1.2 (scrollpeak, same scenario) |
| Scrolling 2,000 messages | 120 fps, no frame > 16 ms | 60 Hz: 1 of 912 frame gaps over 16.7 ms (one 50 ms gap) | 60 Hz: 0 of 1,095 frame gaps over 16.7 ms, longest 16.7 ms |
| Keypress to glyph | < 16 ms | 37.8 ms median, end to end on screen | 37.8 and 38.4 ms median end to end; a bare `NSTextView` measures 29 to 30 ms the same way; at v0.1.2 keyDown to commit is 2.1 ms against 2.5 ms for a bare `NSTextView` (keystroke task) |
| Bundle size (no server runtime, no fonts) | < 25 MB | 365 MB total; Electron 239 MB, server bundle 59 MB | 21.9 MB (24.3 MB shipped with the 2.4 MB Nerd Font TTF; stripped binary 19.6 MB) |

Numbers from 2026-10-11 ("Milestone 8 side by side" below): the same seeded home (50 threads, one 2,000-message thread) for both clients, the official app at 0.0.46-nightly.20261009.2861 and CandyWrapper at 0209d52 in Release (-Osize), screen at 2x and 60 Hz.

Before that, the CandyWrapper numbers were from 2026-10-10: Release build at M3 (sidebar only, no thread view yet), sandbox home with 14 threads, window open. The screen had switched to 2x (3840x2160 backing, looks like 1920x1080) after the official baseline was taken at 1x, which makes window buffers four times larger; the official app's numbers would grow too. Launch times come from `scripts/measure-launch.swift` plus the app's `CANDY_LAUNCH_TIMING` marks, memory from `footprint`, idle from `procstat` and `powermetrics`.

Memory went from 153 MB to 27 MB after three fixes, all in drawing: the main panel and sidebar backgrounds were drawn into full-size bitmaps (27 MB each at 2x, since this screen uses 8 bytes per pixel) and are now a layer color plus replicated grain tiles; the nightly art's off-canvas blur made AppKit size its backing store to the whole window (views don't clip drawing by default since macOS 14) and is now clipped; and its transparency groups got explicit bounds.

## How each client number gets measured

1. Cold launch: `sudo purge`, then `scripts/measure-launch.swift` in the GUI session for first-window time. For CandyWrapper the app logs a signpost when the sidebar has data. For the official app, the sidebar time comes from the first `environment.orchestration.shellSnapshot` span in `<home>/userdata/logs/server.trace.ndjson`.
2. Idle: launch, open a finished thread, wait 60 s, then `procstat 60 --tree <app pid>`. The official app's tree includes its Electron helpers and its bundled server. Report the app processes and the server separately.
3. Streaming: the same scripted Haiku turn for both apps (the `turn2` scenario prompt that writes about 600 words), with procstat across the turn.
4. Energy Impact: `sudo powermetrics --samplers tasks --show-process-energy` over the same windows as 2 and 3. Sum the app's processes, and report the server separately.
5. Memory: footprint after launch, and after opening a seeded 2,000-message thread with 50 threads in the sidebar.
6. Scrolling and keypress latency: ScreenCaptureKit frame display times while HID input is posted, as in "Milestone 8 side by side". 120 Hz needs a ProMotion Mac.


## Milestone 8 side by side (2026-10-11)

Both clients ran one after the other on the same data, with the official app first. Each measurement window started only when the 1-minute load average was under 2 and no compiler ran. The scripts below live in `/tmp/cw-sbs-tools/` and are not committed.

### Data

`../CandyWrapper-research/sbs-home-seed` is a copy of the frozen perf workload (`perf-home-pristine`, 38 threads) plus 11 small threads and one thread of 2,000 messages (1,000 question and reply pairs, replies 20 to 80 words, every fifth with a list, every ninth with a Swift code block). I wrote them as legacy v1 rows (`projection_threads`, `projection_thread_messages`) and let T3's own `LegacyV1ThreadImporter` turn them into v2 threads on the next server start: the log reads `importedThreadCount: 12, importedMessageCount: 2020` and the shell serves 50 threads. The imported thread is message items only, with no runs, tool rows or "Worked for" separators. The official app ran on the copy `sbs-home-official` (plus `client-settings.json` and `desktop-settings.json` from `desktop-home`, no Clerk token), CandyWrapper on `sbs-home-candy` with a server started the `scripts/sandbox-server` way on port 47396. The sandbox `session.token` works against both copies, so `scripts/perf/turn.swift` drove turns on either server.

### Method

1. Launch. The official app through `scripts/measure-launch.swift` in the GUI session, sidebar time from the first `environment.orchestration.shellSnapshot` span after spawn. CandyWrapper through `scripts/run-app --server ... --fake-t3-connect` with `CANDY_LAUNCH_TIMING=1`, window time from `probe window`. No `sudo purge`: the brief allowed sudo only for powermetrics, so neither launch is cold in the page-cache sense. The official time includes starting its bundled server; CandyWrapper's server was already running.
2. Idle: a small finished thread open ("Perf stream 7070d1f 124911"), composer focused, window frontmost, `procstat 60 --tree` and 12 powermetrics samples of 5 s in the same minute.
3. Streaming: a fresh `claude-haiku-5-5` thread made by `turn create`, opened in the client, then `turn send` with the `turn2` story prompt ("Without using tools, write a 600-word short story about a lighthouse keeper."). `probe rusage` on every process before and after the turn, powermetrics at 2 s samples, averaged over the samples inside the turn. Two turns per client.
4. Memory: the 2,000-message thread opened from Cmd+K. The official app shows the last 10 turns and a "Load earlier turns" button that adds 20 turns per click; I clicked it 50 times to reach message 1. CandyWrapper pages older messages in while scrolling; I scrolled to message 1.
5. Scrolling: `frames scroll`, a ScreenCaptureKit stream of a 400x200 pt part of the timeline with each frame's display time, while HID pixel scroll events go to the timeline every 8 ms (20 or 60 px each) for 300 events. Frames whose pixels changed count as shown frames; the gaps between them are the frame times. Input every 16 ms gave false gaps, because the posting loop runs at about 19 ms and some display frames get no event (official app: 3 to 14% gaps over 25 ms that way), so those runs don't count.
6. Keypress: `frames key` posts the `a` key 20 or 40 times, 600 ms apart, and records the display time of the first captured frame whose change is wider than a caret. This is end to end: HID event, WindowServer, the app, compositing and scan-out. A bare `NSTextView` app (`floor.swift`) measured the same way gives the floor of this pipeline on this machine.

### Raw numbers

Launch:

| | Window | Sidebar data |
|---|---|---|
| Official, first launch on the copy | 3.44 s | 3.71 s (server ready 2.35 s) |
| CandyWrapper, first launch of the new build | 0.67 s | 0.71 s |
| CandyWrapper, relaunch 2 and 3 | 0.16, 0.17 s | 0.20, 0.22 s |

Idle, 60 s (procstat CPU and wakeups, powermetrics Energy Impact):

| Process | CPU | Interrupt/s | Pkg idle/s | Energy Impact | Footprint |
|---|---|---|---|---|---|
| Official main | 0.20% | 3.4 | 1.3 | 0.21 | 85 MB |
| Official GPU | 1.24% | 64.0 | 32.7 | 1.37 | 239 MB |
| Official renderer | 0.55% | 6.5 | 2.1 | 0.76 | 136 MB |
| Official network | 0.05% | 0.7 | 0.2 | 0.06 | 8 MB |
| Official bundled server | 0.37% | 14.5 | 6.0 | 1.63 | 140 MB |
| Official resource monitor | 0.34% | 0.2 | 0.1 | 1.28 | 4 MB |
| CandyWrapper | 0.00% | 0.03 | 0.02 | 0.00 | 41 MB |
| CandyWrapper's server | 0.48% | 11.1 | 3.8 | 3.03 | 195 MB |

The official GPU process's 64 wakeups per second come from the composer's blinking caret: with the composer unfocused (after clicking "Load earlier turns") a 5 s sample read 0.6 per second and 136 MB. CandyWrapper's focused composer shows a steady caret.

Streaming, per turn (CPU from rusage, Energy Impact from powermetrics):

| Turn | Length | App CPU | App Energy | Server CPU | Server Energy | Claude provider Energy |
|---|---|---|---|---|---|---|
| Official 1 | 15.2 s | 15.9% | 103.5 | 4.6% | 72.9 | 153.7 |
| Official 2 | 25.1 s | 15.1% | 66.7 | 2.2% | 29.6 | 93.5 |
| CandyWrapper 1 | 14.7 s | 1.26% | 16.9 | 3.0% | 57.6 | 138.9 |
| CandyWrapper 2 | 17.0 s | 1.26% | 13.2 | 2.9% | 47.7 | 123.9 |

Official app CPU splits into renderer 9.2 and 8.3%, GPU process 6.3 and 6.3%, main 0.3 and 0.4%. CandyWrapper's footprint after a turn was 102 to 103 MB, most of it Core Animation's transient renderer memory (docs/perf/README.md, "Streaming redraws"); the official app's processes held 570 MB.

Memory with the big thread (footprint of the app processes; servers separate):

| State | Official | CandyWrapper |
|---|---|---|
| As opened | 500 MB (renderer 149, GPU 249) | 71 MB |
| All 2,000 messages loaded | 461 MB (renderer 223, GPU 136, composer unfocused) | 153 MB right after, 90 MB 30 s later |
| Lifetime peak | GPU process 328 MB, renderer 203 MB | 246 MB |
| Server | 150 to 190 MB plus two idle Claude provider sessions of 122 and 125 MB | 211 to 268 MB plus its provider sessions |

Scrolling at 60 Hz, gaps between shown frames:

| Client | Runs | Gaps | Over 16.7 ms | Longest |
|---|---|---|---|---|
| Official | 5 (three at 20 px, two at 60 px per event) | 912 | 1 | 50 ms |
| CandyWrapper | 6 (three at 20 px, three at 60 px) | 1,095 | 0 | 16.7 ms |

Keypress to glyph, end to end:

| App | Keys | Median | Range |
|---|---|---|---|
| Official composer | 20 | 37.8 ms | 27.7 to 87.9 ms |
| CandyWrapper composer | 20, 40 | 37.8, 38.4 ms | 25.9 to 77.1 ms |
| Bare `NSTextView` | 20, 40 | 30.4, 29.1 ms | 21.3 to 62.9 ms |

The first key of each run is the slowest in every app (the placeholder goes away). CandyWrapper's composer sits about 8 ms, half a frame, above a bare text view.

Bundle: CandyWrapper as built 42.7 MB, of which the unstripped binary is 38.0 MB; with the binary stripped (`strip -x -S`) the bundle is 24.3 MB, and 21.9 MB without the 2.4 MB Symbols Nerd Font. The official bundle is 365 MB: Electron's `Frameworks` 239 MB, `app.asar` 104 MB (server `dist` 59 MB, the Cursor SDK 17 MB, Playwright 10 MB, the desktop shell 11 MB), unpacked native modules 20 MB, icon 3 MB.

### Against the spec

- Pass: idle CPU, idle wakeups, idle Energy Impact, RAM at launch, streaming CPU, streaming Energy Impact (mean 15.1 against 85.1, 0.18; per turn 0.13 to 0.25, so the margin depends on how long the official turn's working phase lasts), bundle size, scrolling at 60 Hz.
- Pass with a caveat: launch to live sidebar is 0.20 to 0.22 s on relaunch but 0.71 s on the first launch of a new build, and the server was already up.
- Over the target: RAM with the big thread peaked at 246 MB while I paged in all 2,000 messages by scrolling 36,000 pt a second. As opened (71 MB) and settled (90 MB) it is under 200 MB.
- Not met by either client as measured: keypress to glyph under 16 ms. The end-to-end floor on this machine is 29 to 30 ms for a bare `NSTextView`, so the spec's number can only be an app-side time. CandyWrapper adds about 8 ms over the floor.
- Not measurable here: 120 fps. The virtual display runs at 60 Hz and ProMotion is not available.

### Caveats

- The user's demo app ran against the live T3 the whole time and showed 10 to 17% CPU while its own turns streamed; the user watched over Screen Sharing (VTEncoder and avconferenced at 20 to 35% CPU); another agent and the main session ran, and one Release build paused me for 17 minutes. Each window still started under load 2.
- The Claude provider sends the reply as one final item (docs/protocol.md, "Streaming assistant text"), so the "streaming" turn is about 15 s of the working state and one large update. The official renderer's cost is mostly that working state.
- Both servers keep a Claude provider process per finished turn alive (about 122 MB each), so memory and idle numbers taken after turns include them; they are reported separately.
- One idle window and two turns per client. The official turns' Energy Impact differs by 55% between runs.

## README refresh against Nightly 3234 (2026-10-17)

The same side by side as 2026-10-11, repeated for the README: official T3 Code (Nightly) 0.1.1-nightly.20261017.3234 from its GitHub DMG, and CandyWrapper 1.5.0 at commit 1a844cb, built Release with the perf flags (own bundle id and URL scheme, no update feed) and signed ad hoc. The official app ran with `T3CODE_DISABLE_AUTO_UPDATE=1` so its updater stayed out of the idle window, since 3238 was already published. Only one of the two apps ran at a time, with the official app first, and the 1-minute load average sat between 1.3 and 2.4 during the windows.

### Setup

- Data: fresh copies of `sbs-home-seed` as `sbs3234-home-official` and `sbs3234-home-candy` in `~/CandyWrapper-research`, the official one with the 2026-10-11 `client-settings.json`, `desktop-settings.json` and `settings.json`. The official app migrated its copy on its first launch. CandyWrapper's server was the 3234 runtime on port 47396, started with `env -i` the `scripts/sandbox-server` way.
- Tools: `scripts/procstat.swift`, `scripts/perf/probe.swift` and `turn.swift`, `powermetrics`, and a copy of `scripts/measure-launch.swift` that also sets `T3CODE_DISABLE_AUTO_UPDATE=1`. The 2026-10-11 `frames` tool was never committed and was gone from `/tmp`, so I wrote a new one with the same method: ScreenCaptureKit display times of changed frames in a screen region, HID pixel scroll events every 8 ms for 300 events, and `a` key presses 600 ms apart counted when a change wider than 4 px shows. A slow frame is a gap over 20 ms at 60 Hz.
- The official app's thread view crashed twice with "Cannot read properties of undefined (reading 'environmentId')" when I opened a thread from Cmd+K. "Try again" brought the thread back each time. That is an upstream bug in 3234.

### Raw numbers

Launch (official sidebar time from the first `environment.orchestration.shellSnapshot` span after spawn, CandyWrapper from `CANDY_LAUNCH_TIMING`):

| | Window | Sidebar data |
|---|---|---|
| Official, first launch on the copy, with the database upgrade | 4.26 s | 4.64 s |
| Official, relaunch 2, 3 and 4 | 1.78, 1.82, 1.80 s | 2.13, 2.10, 2.09 s |
| CandyWrapper, first launch of the new build | 0.61 s | 0.71 s live, 0.66 s cached |
| CandyWrapper, relaunch 2 and 3 | 0.15, 0.16 s | 0.24, 0.23 s live, 0.21, 0.20 s cached |

Idle, two 60 s windows with "Perf stream 7070d1f 124911" open and the composer focused (procstat, then powermetrics 12 x 5 s):

| Process | CPU | Interrupt/s | Pkg idle/s | Energy Impact | Footprint |
|---|---|---|---|---|---|
| Official main | 0.27, 0.25% | 3.3, 3.2 | 1.3, 1.2 | | 85 MB |
| Official GPU | 1.28, 1.26% | 63.1, 63.0 | 44.3, 44.3 | | 163 MB |
| Official renderer | 0.64, 0.62% | 6.3, 6.0 | 1.9, 2.0 | | 124 MB |
| Official network | 0.07, 0.07% | 0.65, 0.63 | 0.2, 0.3 | | 8 MB |
| Official app total | 2.26, 2.20% | 73.4, 72.9 | | 2.00, 1.97 | 381 MB |
| Official bundled server | 0.46, 0.46% | 19.3, 19.7 | 7.1, 7.1 | 1.35, 1.23 | 160 MB |
| CandyWrapper | 0.00, 0.00% | 0.03, 0.07 | 0.00, 0.00 | 0.00, 0.00 | 39.3 MB |
| CandyWrapper's server | 0.14, 0.34% (1 s samples) | 10, 21 | | 0.16, 0.13 | 238 MB |

The official GPU process still wakes about 63 times a second for the composer's blinking caret.

Streaming, the `turn2` story prompt on a fresh `claude-haiku-5-5` thread made by `turn create` and opened in the app (CPU from rusage across the turn, Energy Impact as the mean of the 2 s powermetrics samples inside it):

| Turn | Length | App CPU | App Energy | Server CPU | Server Energy |
|---|---|---|---|---|---|
| Official 1 | 26.2 s | 15.43% | 47.3 | 3.49% | 43.6 |
| Official 2 | 21.2 s | 15.37% | 45.7 | 4.44% | 49.4 |
| CandyWrapper 1 | 21.0 s | 0.95% | 9.6 | 2.57% | 37.9 |
| CandyWrapper 2 | 16.6 s | 0.88% | 9.7 | 3.71% | 37.7 |

Official app CPU splits into renderer 8.5 and 8.5%, GPU process 6.4 and 6.4%, main 0.4 and 0.4%. The official processes held 434 to 436 MB after a turn and CandyWrapper 96 to 98 MB.

Memory with "Seeded 2000 messages", 30 s after opening it from Cmd+K:

| State | Official | CandyWrapper |
|---|---|---|
| As opened | 397 MB (main 89, renderer 139, GPU 162, network 8) | 46.2 MB |
| All 2,000 messages loaded | 334 MB (renderer 178, GPU 57, composer unfocused), after 50 clicks on "Load earlier turns" | 67 to 69 MB, after scrolling to message 1 |

Scrolling at 60 Hz, a 400 x 200 pt part of the timeline, from message 1 downward:

| Client | Runs | Gaps | Over 20 ms | Longest |
|---|---|---|---|---|
| Official | 5 (three at 20 px, two at 60 px per event) | 724 | 0 | 16.7 ms |
| CandyWrapper, first set | 5 (the same) | 713 | 8 | 33.3 ms |
| CandyWrapper, second set | 5 (the same) | 713 | 3 | 33.3 ms |

Every slow CandyWrapper frame was a single dropped frame, 33.3 ms. The README counts both CandyWrapper sets, 11 of 1,426. On 2026-10-11 CandyWrapper dropped none of 1,095, so this is a regression since then.

Keypress to glyph in the small thread's composer, end to end, two runs of 20 keys each, pooled:

| App | Median | Range |
|---|---|---|
| Official | 39.7 ms (runs 36.0, 42.0) | 26.9 to 76.2 ms |
| CandyWrapper | 35.0 ms (runs 37.7, 35.1) | 22.9 to 50.2 ms |

In the 2,000-message thread with every turn loaded, the official composer took 47.5 and 49.0 ms. I didn't measure a bare `NSTextView` floor this time.

Sizes: the official `T3-Code-0.1.1-nightly.20261017.3234-arm64.dmg` is 163,473,725 bytes and its app is 379,356 KiB (370 MB) by `du -sk` inside the mounted DMG. `CandyWrapper-1.5.0-arm64.dmg` is 17,407,159 bytes and its app is 31,440 KiB (30.7 MB). On 2026-10-11 the CandyWrapper DMG was 14.6 MB and the app 27 MB.

### Caveats

- The two apps used different themes: the official app opened light and CandyWrapper dark, each with its own settings from the copied homes.
- The user's live T3 and its agents ran the whole time, and the user may have watched over Screen Sharing, so WindowServer sat near 40% CPU.
- The official all-loaded scroll set ran once. CandyWrapper ran it twice because the first set showed slow frames.
- Energy Impact for the official app came out lower than on 2026-10-11 (46.5 against 85.1). The 2026-10-11 turns differed by 55% between runs, so treat that row as rough.
