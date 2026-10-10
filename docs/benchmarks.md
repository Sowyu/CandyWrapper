# Benchmarks

Official T3 Code and CandyWrapper on the same machine and workload. Status on 2026-10-09: server baseline and the official desktop app's launch and idle baseline are measured. Streaming and large-thread memory runs wait for a side-by-side harness in milestone 8.

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
| Cold launch to interactive sidebar | < 300 ms | about 3.4 s (sidebar data at 3.36 s) | 1.17 s after `purge`, 0.13 to 0.20 s warm (cached sidebar); live data 4.3 s cold, 2.9 s warm, bound by the server's start |
| Idle CPU, window visible, no turns | ~0% | 2.6% total, 1.9% excluding the server | 0.00% app; own server 0.2 to 0.85% until it idle-stops |
| Idle wakeups, app process | < 1/s | 88 interrupt and 52 package idle per second total; 74 interrupt excluding the server | 0.03 interrupt, 0 package idle |
| CPU while streaming one turn | < 5% of one core | milestone 8 | not built |
| Energy Impact idle | ~0 | 4.29 total, 1.92 excluding server and resource monitor | 0.00 app, about 0.1 server |
| Energy Impact streaming | < 1/5 of official | milestone 8 | not built |
| RAM fresh launch | < 80 MB | 544 MB total, 408 MB excluding server and resource monitor | 27 MB app (sidebar only, 2x screen); own server 182 MB |
| RAM, 50 threads + 2,000-message thread | < 200 MB | milestone 8 | not built |
| Scrolling 2,000 messages | 120 fps, no frame > 16 ms | not measurable here (60 Hz) | not built |
| Keypress to glyph | < 16 ms | milestone 8 | not built |
| Bundle size (no server runtime, no fonts) | < 25 MB | 366 MB with server; Electron alone is 239 MB | 5.5 MB |

CandyWrapper numbers are from 2026-10-10: Release build at M3 (sidebar only, no thread view yet), sandbox home with 14 threads, window open. The screen had switched to 2x (3840x2160 backing, looks like 1920x1080) after the official baseline was taken at 1x, which makes window buffers four times larger; the official app's numbers would grow too. Launch times come from `scripts/measure-launch.swift` plus the app's `CANDY_LAUNCH_TIMING` marks, memory from `footprint`, idle from `procstat` and `powermetrics`.

Memory went from 153 MB to 27 MB after three fixes, all in drawing: the main panel and sidebar backgrounds were drawn into full-size bitmaps (27 MB each at 2x, since this screen uses 8 bytes per pixel) and are now a layer color plus replicated grain tiles; the nightly art's off-canvas blur made AppKit size its backing store to the whole window (views don't clip drawing by default since macOS 14) and is now clipped; and its transparency groups got explicit bounds.

## How each client number gets measured

1. Cold launch: `sudo purge`, then `scripts/measure-launch.swift` in the GUI session for first-window time. For CandyWrapper the app logs a signpost when the sidebar has data. For the official app, the sidebar time comes from the first `environment.orchestration.shellSnapshot` span in `<home>/userdata/logs/server.trace.ndjson`.
2. Idle: launch, open a finished thread, wait 60 s, then `procstat 60 --tree <app pid>`. The official app's tree includes its Electron helpers and its bundled server. Report the app processes and the server separately.
3. Streaming: the same scripted Haiku turn for both apps (the `turn2` scenario prompt that writes about 600 words), with procstat across the turn.
4. Energy Impact: `sudo powermetrics --samplers tasks --show-process-energy` over the same windows as 2 and 3. Sum the app's processes, and report the server separately.
5. Memory: footprint after launch, and after opening a seeded 2,000-message thread with 50 threads in the sidebar.
6. Scrolling and keypress latency: Instruments (Core Animation, System Trace) once Xcode is installed. 120 Hz needs a ProMotion Mac.
