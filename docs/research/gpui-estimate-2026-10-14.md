# GPUI prototype next to CandyWrapper, 2026-10-14

## Setup

- Prototype source: `/tmp/gpui-proto` (`src/main.rs`, 424 lines; `src/input.rs`, GPUI's `examples/input.rs` text field, 610 lines). App bundle: `/tmp/gpui-proto/GpuiProto.app`. Screenshot: `/tmp/cw-peek/gpui-proto.png`.
- GPUI 0.2.2 from crates.io (2025-10-22), Rust 1.95.0 already installed, release build with thin LTO and `strip = true`. No toolchain was added.
- The Metal compiler isn't installed (Xcode 27 ships it as a separate download), so GPUI runs with its `runtime_shaders` feature. The first launch of a new binary compiles the shaders for about 250 ms, after that the system shader cache makes it about 1 ms. All numbers below are warm launches.
- The window is 1100x780 with a 256 pt sidebar (`uniform_list`, 82 pt cards with a badge, project, title and time), a bottom-aligned variable-height `list` for the thread, and the text field at the bottom. System font, Menlo for code. Text is generated from a fixed seed.
- Two data shapes:
  - Big: 1,580 cards and 2,000 messages, 2.9 MB of text in paragraphs, bullet lists and code blocks.
  - CW shape (`--cw-shape`): what CandyWrapper's app runs actually load. The frozen perf workload has 38 threads in the sidebar, and "Numbers 1 to 1000 as words" has 15 messages, about 36 KB, one reply being 1,000 short lines. The 1,580-thread and huge-thread cases exist only in CandyWrapper's micro-benchmarks, not in its app runs.
- Method: `/tmp/gpui-proto/tools/measure.py` imports `scripts/perf-review` and uses its `PerfServer`, `probe`, `wait_quiet`, `scenario_idle` and `scenario_big_thread` unchanged for CandyWrapper (Release build `/tmp/cw-perf/dd-fff9d87`, classic theme, its own server on a copy of the frozen workload). The GPUI scenarios copy them line for line: window time from `probe window`, 5 s settle, 30 s of `proc_pid_rusage`, and for scrolling 8 s after the window, then the app scrolls itself 300 pt per frame on a 16 ms timer, 140 frames up and 140 back, like `PerfScroll`. Each round runs GPUI idle, CW idle, GPUI scroll, CW scroll, so the two apps alternate. Three rounds per data shape, six CW launches per scenario in total. No quiet waits were needed. The screen lock was taken for every launch.
- First frame with content: the prototype prints the time from the kernel's process start to the first display refresh after its first draw, which already has all its data.

## Results

Median of 3 launches, range in brackets. CW is the interleaved run of the CW-shape pass; the big-shape pass gave the same CW numbers within noise (idle 33.3 MB, scroll 348 ms, window 221 ms).

| Metric | GPUI, CW shape | GPUI, big shape | CandyWrapper | CW in today's perf review |
|---|---|---|---|---|
| Launch to window | 161 ms (154 to 163) | 188 ms (170 to 204) | 188 ms (181 to 191) | 186 ms |
| Launch to first frame with content | 134 ms (129 to 134) | 156 ms (140 to 171) | 211 ms live sidebar (203 to 236) | 222 ms |
| Footprint at rest, 15 s | 35.6 MB (35.5 to 35.6) | 40.1 MB | | |
| Footprint at rest, 35 s | 35.6 MB (35.5 to 35.6) | 40.2 MB (40.1 to 40.2) | 32.5 MB (32.4 to 34.5) | 32.0 MB |
| Peak footprint | 87.9 MB (87.8 to 87.9) | 92.4 MB (92.3 to 92.5) | 33.8 MB (33.6 to 34.7) | 32.9 MB |
| Idle CPU | 0.377% (0.373 to 0.379) | 0.371% (0.371 to 0.383) | 0.046% (0.045 to 0.048) | 0.046% |
| Idle interrupt wakeups | 60.6/s | 60.6/s | 0.40/s (0.33 to 0.47) | 0.30/s |
| Idle package idle wakeups | 18.2/s (17.9 to 19.0) | 20.4/s (20.1 to 21.3) | 0.17/s (0.13 to 0.20) | 0.13/s |
| Scroll top and back, CPU | 1,200 ms (1,178 to 1,213) | 1,175 ms (1,146 to 1,195) | 351 ms (342 to 356) | 318 ms |
| Footprint after scroll | 64.9 MB | 51.9 MB | 43.6 MB (43.5 to 44.6) | 42.9 MB |
| Peak after scroll | 115.1 MB | 102.1 MB | 98.9 MB | 97.9 MB |
| Stripped binary | 4.0 MB | 4.0 MB | 22.2 MB | 22.2 MB |
| App bundle | 4.0 MB | 4.0 MB | 30.8 MB shipped | 30.8 MB |

What the numbers come from:

- Idle: `sample` shows a `CVDisplayLink` thread running the whole time. GPUI 0.2.2 keeps the display link on while the window is visible and checks for dirty views on every refresh, so it wakes 60 times a second with nothing changing. CandyWrapper wakes about once every 2.5 s.
- Peak footprint: about 50 MB above rest right at launch, in every GPUI run and with either data shape. It is Metal device and pipeline setup, gone by the first rusage sample. CandyWrapper's launch peak stays at its rest level.
- At rest, `footprint` for the big shape: 20 MB malloc, 6.9 MB IOSurface (drawables), 4.3 MB IOAccelerator, the rest code and data pages.
- Scroll: GPUI rebuilds and lays out the visible element tree every frame. In the CW shape the 1,000-line reply is one list item about 22,000 pt tall, which GPUI lays out whole on every frame it is visible, so the small thread costs as much as the big one and leaves 65 MB behind in text layout caches. CandyWrapper's own big thread hits the top after about 75 frames and the rest of its 140 frames are cheap, and the GPUI CW shape clamps the same way.
- Launch: GPUI reaches its window 27 ms earlier than CandyWrapper on the same data, and has content in it 77 ms earlier. CandyWrapper's window time includes its server connection setup and its sidebar time includes the round trip to the perf server, which the prototype doesn't have.

## Where the comparison is unfair

Against GPUI:

- The prototype's scroll test lays out a 1,000-line item as one block. A real app would split long replies into several list items, as CandyWrapper's timeline does, which would cut the scroll cost of the CW-shape thread. The big shape has no such item and still costs 3.3 times CandyWrapper's CPU.
- GPUI 0.2.2 is a year old. Zed's main branch may have changed display link handling since; I didn't test a git pin.
- Runtime shaders cost 250 ms on the first launch of each new binary. A shipped app would precompile them.

Against CandyWrapper:

- The prototype has no networking, protocol decoding, stores, reducers, markdown parser, syntax colors, timeline row kinds, hover states beyond the sidebar, settings, terminal or window chrome. All of its numbers are a floor for a real GPUI app.
- CandyWrapper launches against a server and waits for pairing and the shell snapshot. The prototype starts with its data in memory.
- A forgotten smoke-test copy of the prototype (my PID 87790) stayed open, idle, through both passes. It cost both apps the same background noise, about 0.4% of one core.

## Estimate for a full GPUI CandyWrapper

CandyWrapper's docs have no split between UI and data layers at rest. The closest numbers are its micro-benchmarks and the window to live sidebar gap. Opening the huge thread costs 50 ms parse, 10 ms decode, 1.3 ms entries and 5.6 ms panel, which is about 60 ms of non-UI work for every 6 ms of UI work. The window to live sidebar gap is 25 to 35 ms of connection and snapshot. The glass-native audit puts CandyWrapper's custom-drawn classic window at about 34 MB with 600 to 800 views.

| Metric | Prototype floor | Added by the rest of the app | Full GPUI app, estimate | CandyWrapper today |
|---|---|---|---|---|
| Launch to window | 161 ms | 20 to 40 ms of app setup | 180 to 200 ms | 186 ms |
| Launch to live sidebar | 134 ms | 30 to 40 ms of connect and snapshot | 200 to 230 ms | 222 ms |
| Footprint at rest | 35.6 MB | 5 to 10 MB for tokio, a WebSocket client, serde_json, stores and markdown | 40 to 46 MB | 32 MB |
| Peak footprint at launch | 88 MB | none | about 90 MB | 33 MB |
| Idle CPU and wakeups | 0.38%, 60/s | none if the network layer only pings while active | 0.4%, 60/s, unless GPUI's display link is patched to stop while idle | 0.05%, 0.4/s |
| Scroll CPU | 1,200 ms | markdown, syntax colors, more row kinds: plus 20 to 50% | 1,400 to 1,800 ms | 320 to 350 ms |
| Stripped binary | 4.0 MB | CandyWrapper's own code in Rust | 10 to 18 MB | 22.2 MB |

A GPUI rewrite would win on binary size, by about half, and might tie on launch. It would lose on idle CPU and wakeups by about 8 times and 150 times, on scroll CPU by about 4 times, on launch peak memory by about 55 MB, and on resting memory by 10 to 40%. The idle loss is the one the user would notice. Fixing it means changing GPUI's macOS display link handling, which Zed hasn't done in this version.
