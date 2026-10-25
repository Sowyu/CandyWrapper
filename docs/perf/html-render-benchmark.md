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
python3 scripts/html-benchmark/scroll-summary.py ~/CandyWrapper-research/sandbox/html-benchmark/before
```

`run.py` builds the small kernel measurement helper if it is missing, after preflight. It launches the app through `scripts/run-app`, resets only `dev.candywrapper.test.html-benchmark`, pins Redesign, disables thread disk caching and uses fake T3 Connect. Run it in the background with a log. The eight cases take about nine minutes. Give the screen back within fifteen minutes. Use `--case light|collage|chart`, `--mode thread|conductor` and `--appearance dark|light` to split a session. Choose a fresh `--tag` for another run; the runner refuses to overwrite event files. Sign again if the sandbox URLs expire. Do not prepare assets again in the middle of a comparison.

After all captures, quit only the app PID recorded in that run's `events.jsonl` if it did not exit, then delete `/tmp/cw-dd-html-benchmark`. Keep the sandbox artifacts. No app bundle or DerivedData is part of a baseline artifact.

## What it measures

- Light: a small report, cards and a table, 6,816 prepared HTML bytes.
- Collage: six deterministic local 240 by 240 PNGs, 1,038,948 image bytes, inlined into 1,392,065 HTML bytes. The noise tiles avoid network dependencies and compress to a predictable size.
- Chart: 1,200 deterministic samples drawn once on a canvas by the page's script, 6,555 HTML bytes.

Each case repeats its identical document across ten distinct attachment ids. `manifest.json` records the content hashes, bootstrap hash, signed sandbox URLs and sizes. Keep this file local: its URLs carry sandbox capabilities. Generated HTML, PNGs, manifests, process logs and captures stay outside the repository.

The renderer hook is a DEBUG observer in `ThreadWebFrameView`: activate, release and messages after the normal message handler runs. The launch branch is DEBUG and restricted to test bundles. With no benchmark, the observer is nil; Release contains neither the driver nor the hook.

The final driver records an already painted, live page as ready at `resident-at-scroll`. It takes no diagnostic WebKit snapshots while scrolling. The first baseline below used extra readbacks; those copies affected GPU memory and scrolling, so the final comparison repeats both builds without them. The PNG preview candidate was rejected after its measured memory cost. The current renderer takes no production snapshots either.

`scroll-summary.py` sums readiness waits across ten scroll visits, using the first live-page ready signal or an already painted resident page for every visible frame. A pass with a missing page has no complete traversal time and reports the number of complete visits. The driver deliberately waits two seconds per visit, twenty seconds per direction in every build; that fixed pacing is not a speed measurement.

`arrival` is the moment the driver delivers a projection or pane state to the real UI. `paint-opportunity` comes from the page after fonts and image decode, then two animation frames. `native-layout` follows on the next native main turn after layout. The first such completion per attachment is the arrival measurement. Later arrivals can recreate old pages; those completions count separately rather than inflating the first-ready median.

During back and return, the runner records new activations, completion times from the latest scroll, and live/evicted frames intersecting each sampled viewport. The original diagnostic build also requested snapshots of kept frames; the corrected comparison removes those requests from both builds. It never activates an evicted frame by hand. A viewport with any evicted frame is a failure even if a neighbor still paints. The scrolling sequence uses ten evenly spaced positions over the current document height with two seconds at each position, so layout changes can shift which partial neighboring page is included.

Memory samples use `proc_pid_rusage` physical footprint once a second, including the app plus new WebKit PIDs sharing the inherited responsibility PID, excluding pre-launch helpers. On this harness, the app and its helpers inherit the T3 ancestor's responsibility rather than the app's PID. Attribution is therefore an inference that requires no unrelated WebKit app to launch during a run. The logs preserve PID, process name, RSS, footprint, lifetime peak, CPU and wakeups. The combined peak is the largest simultaneous sampled sum, not a sum of independent lifetime peaks. More than three content processes can briefly exist while evicted processes exit; GPU and Networking helpers count too.

## Corrected quiet baseline

The original renderer is `6e3adef`, with benchmark instrumentation from `ba2fdef` and diagnostic-only `02104618` (four snapshot callback lines removed). Its executable SHA-256 is `806a5237ec4c1e7036166044e5646652c5cd3131ab2a1db9aa3a2137203ab969`.

Canonical raw artifacts are under `~/CandyWrapper-research/sandbox/html-benchmark/baseline-no-readback/`: `results.json`, `derived.json`, `scroll-derived.json`, metadata, the private manifest used, and each case's events, process samples and app log. Eight cases completed, 80/80 first-ready pages, zero diagnostic readbacks and zero competing-build samples. Only expired URL fields were refreshed for the same thirty ids and byte-identical attachment files. The expired attempt is preserved separately as invalid.

| Workload | Mode | Theme | Arrival median ms | Back ready wait ms, complete visits | Return ready wait ms, complete visits | Blank viewports | App / combined sampled peak MB | WebKit peak count |
|---|---|---|---:|---:|---:|---:|---:|---:|
| Light | Thread | Dark | 144.082 | 1010.690, 10/10 | unavailable, 8/10 | 2/20 | 87.131 / 173.036 | 5 |
| Light | Conductor | Dark | 188.142 | unavailable, 0/10 | unavailable, 0/10 | 20/20 | 83.772 / 180.688 | 5 |
| Collage | Thread | Dark | 144.312 | 954.436, 10/10 | unavailable, 9/10 | 1/20 | 47.073 / 198.727 | 5 |
| Collage | Conductor | Dark | 198.142 | unavailable, 0/10 | unavailable, 0/10 | 20/20 | 83.346 / 219.616 | 5 |
| Chart | Thread | Dark | 139.712 | unavailable, 9/10 | unavailable, 8/10 | 3/20 | 47.007 / 184.390 | 5 |
| Chart | Conductor | Dark | 187.453 | unavailable, 0/10 | unavailable, 0/10 | 20/20 | 78.710 / 183.768 | 5 |
| Collage | Thread | Light | 143.557 | 963.408, 10/10 | unavailable, 9/10 | 1/20 | 47.285 / 205.640 | 5 |
| Collage | Conductor | Light | 184.637 | unavailable, 0/10 | unavailable, 0/10 | 20/20 | 44.009 / 222.172 | 5 |

All before cases retained three frames. Conductor activated 31 times during ten arrivals and never reloaded during either scroll pass. A missing traversal time is a failed pass, never zero. One-second samples can miss the app's launch peak: kernel lifetime app peaks were 83.56 to 87.36 MB, recorded separately.

The earlier `baseline-v1` contains competing builds and diagnostic GPU readbacks. Its raw files remain preserved, but none of its timings establishes a speed ratio against the corrected after run.

## Rejected PNG preview candidate

The clean candidate at `6fba7ccf`, in `after-no-readback/`, completed all eighty arrivals and all 160 scroll visits, with zero sampled blanks and no competing builds. Dark arrival medians improved to 95.699/101.610 ms for light thread/Conductor, 100.102/94.744 ms for collage and 103.591/78.043 ms for chart. The complete scroll readiness sums were 349 to 751 ms per ten visits. WebKit still peaked at five processes.

It failed the memory target. Combined collage peaks rose from 198.727 to 248.567 MB in normal dark and from 219.616 to 240.473 MB in Conductor dark; light rose from 205.640 to 250.200 MB and from 222.172 to 229.200 MB. The bounded lossless PNG cache and its readbacks were therefore removed rather than shipped. Raw results and its four first-page images remain intact.

The event trace also exposed an iframe handoff race: the outgoing iframe could report a resized height through the new native message handler before the replacement script ran. This caused repeated height changes and activations. The next candidate rejects those messages until the isolated bridge confirms the new iframe has started, and hides the reused host until its replacement loads.

## Visual evidence

Authoritative before images are `baseline-one-page/collage-{thread,conductor}-{dark,light}/before.png` under the same sandbox artifact root. All four show all six local images; `capture.json` proves that page two had not arrived. The PNG candidate's matching captures are in `after-one-page-final/`. Each collage region differs at only one pixel by one color-channel level out of 370,125 normal-thread or 392,675 Conductor pixels; layout, theme and image content match on screen. These images document the rejected candidate; final-candidate captures follow its measurement.

Ten-page batch screenshot markers can race the next scroll. Use the first-page images for a precise visual comparison.

## Current implementation and validation

The candidate keeps a shown chat's shared non-persistent WebKit HTTP store and one empty reusable host, releases offscreen iframe contexts, reloads returning Conductor cards, avoids URL work for cancelled rows, and normalizes width-aware height reports before deduplicating them. It leaves the iframe URL, sandbox, CSP, theme variables, scripts, shortcut and link bridge unchanged. MCP apps and workspace previews do not enter the HTML host cache. T3's frame behavior is defined in `apps/web/src/components/chat/HtmlRenderFrame.tsx:25-108` and `apps/web/src/components/files/BrowserDocumentFrame.tsx:118-131`; asset cache policy is in `apps/server/src/http.ts:107-128`.

Focused tests, fast lane, full suite, final screenshots and final after measurements are pending. The first focused run found a missing cancellation check before an offscreen Conductor URL request; that check and a handoff-race regression are ready for the next run. Test fixtures now lay out the frame before injecting a height report and avoid calling a mutating struct method directly inside the Swift Testing macro.

## Limits

These are UI projection arrival timings with pre-signed sandbox URLs, not wire arrival, signing, provider latency or server history/subscription timings. The real session/controller plumbing is bypassed. The page's two-rAF signal plus native layout is a paint opportunity, not a display fence.

Each case has ten sequential arrivals in one quiet batch; later arrivals share caches. This is not ten independent cold process launches. Scroll readiness sums exclude the driver's fixed twenty-second pacing and report cached pixels separately in the rejected candidate. Process ownership is inferred from newly created WebKit PIDs with a shared ancestor responsibility, and one-second samples are not a continuous peak trace. The unchanged driver takes four OS screenshots per case. No performance ratio uses the earlier noisy/readback baseline.
