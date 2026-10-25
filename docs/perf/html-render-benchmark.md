# HTML render benchmark

This workload exercises `ThreadPanelView` and `OrchestratorPaneView` in an isolated Debug app. It replays ten completed `html_render` references, two seconds apart, then scrolls back through the ten pages and returns. It never sends a provider turn or writes an orchestration command. The app stays in `--thread-preview`, so it never joins the live T3 home.

The assets are actual signed `text/html` attachments served by the sandbox T3 server on 47391. The generator writes only its thirty deterministic attachment files under `~/CandyWrapper-research/sandbox/t3home/userdata/attachments`. It derives the theme/size bootstrap from the pinned T3 source, then inserts the local PNG bytes as data URLs, matching T3's publish step. Sources: `packages/shared/src/htmlRender.ts:375-419,449-468`, `apps/server/src/htmlRender/HtmlRender.ts:407-445`, `apps/server/src/assets/AssetAccess.ts:597-635`.

## Run it

Run these commands from the checkout being measured. Keep the same display, window size, assets and Debug configuration for before and after. The default test window is 1100 by 780 points; the baseline used the 1920 by 1080 display at 1x.

```sh
scripts/preflight
scripts/sandbox-server
python3 scripts/html-benchmark/prepare.py
swiftc scripts/html-benchmark/sign.swift -o ~/CandyWrapper-research/sandbox/html-benchmark/sign
~/CandyWrapper-research/sandbox/html-benchmark/sign
scripts/build-test-app html-benchmark
scripts/ui/build
scripts/ui/screen-lock take html-benchmark
python3 scripts/html-benchmark/run.py --tag before
python3 scripts/html-benchmark/capture-one.py --tag before-one-page
scripts/ui/screen-lock give html-benchmark
python3 scripts/html-benchmark/summarize.py ~/CandyWrapper-research/sandbox/html-benchmark/before
```

`run.py` builds the small kernel measurement helper if it is missing, after preflight. It launches the app through `scripts/run-app`, resets only `dev.candywrapper.test.html-benchmark`, pins Redesign, disables thread disk caching and uses fake T3 Connect. Run it in the background with a log. The eight cases take about nine minutes. Give the screen back within fifteen minutes. Use `--case light|collage|chart`, `--mode thread|conductor` and `--appearance dark|light` to split a session. Choose a fresh `--tag` for another run; the runner refuses to overwrite event files. Sign again if the sandbox URLs expire. Do not prepare assets again in the middle of a comparison.

After all captures, quit only the app PID recorded in that run's `events.jsonl` if it did not exit, then delete `/tmp/cw-dd-html-benchmark`. Keep the sandbox artifacts. No app bundle or DerivedData is part of a baseline artifact.

## What it measures

- Light: a small report, cards and a table, 6,816 prepared HTML bytes.
- Collage: six deterministic local 240 by 240 PNGs, 1,038,948 image bytes, inlined into 1,392,065 HTML bytes. The noise tiles avoid network dependencies and compress to a predictable size.
- Chart: 1,200 deterministic samples drawn once on a canvas by the page's script, 6,555 HTML bytes.

Each case repeats its identical document across ten distinct attachment ids. `manifest.json` records the content hashes, bootstrap hash, signed sandbox URLs and sizes. Keep this file local: its URLs carry sandbox capabilities. Generated HTML, PNGs, manifests, process logs and captures stay outside the repository.

The only renderer hook is a DEBUG observer in `ThreadWebFrameView`: activate, release and messages after the normal message handler runs. The launch branch is DEBUG and restricted to test bundles. With no benchmark, the observer is nil; Release contains neither the driver nor the hook.

`arrival` is the moment the driver delivers a projection or pane state to the real UI. `paint-opportunity` comes from the page after fonts and image decode, then two animation frames. `native-layout` follows on the next native main turn after layout. The first such completion per attachment is the arrival measurement. Later arrivals can recreate old pages; those completions count separately rather than inflating the first-ready median.

During back and return, the runner records new activations, completion times from the latest scroll, and live/evicted frames intersecting each sampled viewport. A kept painted frame also gets a WebKit snapshot request; its completion time measures snapshot availability. It never activates an evicted frame by hand. A viewport with any evicted frame is a failure even if a neighbor still paints. The scrolling sequence uses ten evenly spaced positions over the current document height with two seconds at each position, so layout changes can shift which partial neighboring page is included.

Memory samples use `proc_pid_rusage` physical footprint once a second, including the app plus new WebKit PIDs sharing the inherited responsibility PID, excluding pre-launch helpers. On this harness, the app and its helpers inherit the T3 ancestor's responsibility rather than the app's PID. Attribution is therefore an inference that requires no unrelated WebKit app to launch during a run. The logs preserve PID, process name, RSS, footprint, lifetime peak, CPU and wakeups. The combined peak is the largest simultaneous sampled sum, not a sum of independent lifetime peaks. More than three content processes can briefly exist while evicted processes exit; GPU and Networking helpers count too.

## Baseline captured on 2026-10-25

Renderer base: `6e3adefca19dff5804f213824ea7cfe073086c6d`, before production changes. Debug executable SHA-256: `77225e9a107749ad1c29b12571da54af1533d33fde62fa7582a06e2d6f7a33d1`. Instrumentation was built and exercised on screen. The task's DerivedData and compiled helpers were removed after capture.

Artifacts: `~/CandyWrapper-research/sandbox/html-benchmark/baseline-v1/`. `derived.json` and each case's `derived.json` are canonical. The original `summary.json` includes repeated ready events for some cases; it is preserved but should not be used for cold medians. The pilot's memory sampler excluded helpers and is not the baseline.

| Workload | Mode | Theme | First-ready median ms | Back reload ms | Return reload ms | Viewports with blanks / checks | App / combined peak MB | WebKit peak processes |
|---|---|---|---:|---:|---:|---:|---:|---:|
| Light | Thread | Dark | 214.969 | 224.539 | 201.571 | 2 / 20 | 84.9 / 188.0 | 6 |
| Light | Conductor | Dark | 462.380 | unavailable | unavailable | 20 / 20 | 80.8 / 192.5 | 5 |
| Collage | Thread | Dark | 272.163 | 118.130 | 264.456 | 8 / 20 | 85.1 / 228.9 | 6 |
| Collage | Conductor | Dark | 552.106 | unavailable | unavailable | 20 / 20 | 81.6 / 248.6 | 8 |
| Chart | Thread | Dark | 230.351 | 202.691 | 196.369 | 3 / 20 | 84.8 / 183.0 | 5 |
| Chart | Conductor | Dark | 446.485 | unavailable | unavailable | 20 / 20 | 82.5 / 193.1 | 7 |
| Collage | Thread | Light | 485.557 | 824.505 | 454.709 | 13 / 20 | 86.0 / 239.4 | 6 |
| Collage | Conductor | Light | 770.984 | unavailable | unavailable | 20 / 20 | 82.2 / 246.3 | 10 |

All cases reached a first ready signal for all ten pages. Conductor activated 31 frames during arrival in every case and none during back or return. Its evicted pages never resumed. The normal thread also exposed blank evicted frames. Retained frame snapshot medians ranged from 4.4 to 54.7 ms across dark cases; these snapshots do not establish that all ten pages were readable.

Authoritative visual before images are `~/CandyWrapper-research/sandbox/html-benchmark/baseline-one-page/collage-{thread,conductor}-{dark,light}/before.png`. All four were inspected and show all six images. Each `capture.json` confirms that page two had not arrived. The ten-page batch screenshots use asynchronous capture markers and can race the next scroll; their labels are not reliable for exact before/after pixel comparisons.

## Limits

These are UI arrival timings using fixture projections and pre-signed URLs, not wire arrival, URL-signing latency, provider latency, or a server history/subscription benchmark. The real ThreadSession/OrchestratorController plumbing is bypassed. A two-rAF signal is a paint opportunity, not a display fence. A successful retained-frame snapshot includes snapshot overhead. Blank viewport checks test WebKit ownership and visibility, while the on-screen images provide the pixel evidence.

This is one run per mode/workload/theme, with ten sequential arrivals. Later arrivals share a warm process/cache, so first-ready medians are not ten independent cold process launches. Other tasks built during capture, especially the first case; the timings are noisy and should not be treated as a stable speed ratio. Raw values and failures are preserved. Future runner samples record competing build PIDs; this addition was made after baseline capture. Use a quiet repeated run before making a quantitative speed claim.

No fast or full suite ran after capture because disk preflight fell below 40 GB. The benchmark app had built successfully before that failure. This harness changes no production renderer behavior.
