# Large replies off the main thread (2026-10-27)

The [2026-10-26 audit](../research/responsiveness-audit-2026-10-26/README.md#cold-markdown) measured 984 ms of parse and layout at 256 KiB and 4.11 s at 1 MiB. Those were component times. The whole path was much worse: a 1 MiB reply in a real timeline also built about 50,000 buttons and link views on the main thread, and every draw walked every item of the layout. Opening one blocked the main thread for 48 s.

## What changed

- `MarkdownLayout` no longer needs the main actor. Its caches sit behind locks, and the few main-actor lookups (chip measuring, image sizes, Mermaid results) go through `onMain`, which hops to the main thread. The main thread never waits for a layout, so the hop can't deadlock.
- Off the main thread, a long message lays out its top-level blocks in parallel chunks on four workers. A counting pass gives each chunk its code, table and display formula indices, and a chunk that ends on other counts falls back to a serial layout. More workers held the Objective-C runtime's locks often enough that the main thread's own view layout waited on them: eight workers gave 100 to 180 ms stalls on resize.
- `MarkdownView.laysOutInBackground`, set by the assistant row for replies of 32 KiB or more, makes every layout of that view in the background, one at a time. Until it lands, the view shows its last layout, or reserves the timeline's height estimate. A streaming answer extends its previous layout in the background too. Results carry the view's message identity and settings, so a recycled view never shows another message and a font change never keeps old boxes.
- `TimelineContext.document(background: true)` parses settled replies of 32 KiB or more in a detached task, one per message at a time, and so does a streaming update the incremental parse can't extend (a reference definition or an HTML block). A reply that just finished streaming keeps its incremental parse, which equals the full one.
- Buttons, link areas and chips get views only within 600 pt of the visible rect once a message has more than 200 of them. A draw pass walks only the top-level blocks its dirty rect touches, from counts the layout records per block.
- Layouts and parsed documents of long replies are freed on a background queue, including when a view, a timeline or a background result goes away. Freeing a 1 MiB layout took the main thread up to 2 s.
- The streaming fade drops bands that finished fading and gives an update that adds more than 32 blocks one band. Before, a steady stream kept every band until it paused.
- `endsInOpenFence` and the timeline's height estimate scan bytes instead of splitting the text into lines.

## Method

`LargeReplyResponsivenessStress` in `Packages/CandyKit/Tests/FeaturesTests/LargeReplyResponsivenessTests.swift` uses the audit's two fixtures (mixed blocks, and one long soft-break paragraph) in a real `TimelineView` in a 1000x800 window. A run loop observer records the longest main run loop pass, wake to sleep, as the app's `StallMonitor` counts stalls. A test step does what one turn does: the change, layout, display and a Core Animation flush, then lets the main queue run.

- Open: a thread whose last answer is the settled reply, until the answer shows its real layout, then 21 scroll positions through it, then the window narrowed to 760 pt until the new layout shows, then the window closed with 3 s to settle. Five runs, each with a fresh text so no cache helps.
- Stream: the mixed fixture growing in 128 updates, then settling, then the window closed. Three runs.

```
CW_LARGE_REPLY_STRESS=1 scripts/test -c release -Xswiftc -enable-testing --no-parallel --filter LargeReplyResponsivenessStress
```

`CW_LARGE_REPLY_ONLY=1048576:mixed` limits it to one fixture, and `CW_LARGE_REPLY_STEPS=1` prints the slowest steps. Release builds, the same harness on both sides: main at d7e229d5 in a separate worktree, then this branch, one after the other on a quiet machine.

## Results

Longest main-thread stall, p50 (max), in ms.

| Fixture | Phase | main | branch |
|---|---|---:|---:|
| Mixed 256 KiB | open | 3,637 (4,758) | 6.5 (15) |
| | scroll | 79 (101) | 4.2 (9) |
| | resize | 3,245 (3,820) | 6.5 (11) |
| | close | 509 (530) | 4.9 (12) |
| Soft breaks 256 KiB | open | 417 (424) | 6.3 (7) |
| | resize | 135 (137) | 8.2 (9) |
| Mixed 1 MiB | open | 48,441 (76,429) | 16.7 (18) |
| | scroll | 421 (473) | 7.2 (8) |
| | resize | 43,567 (43,664) | 15.9 (17) |
| | close | 3,504 (3,572) | 11.9 (14) |
| Soft breaks 1 MiB | open | 1,724 (2,174) | 13.1 (13) |
| | resize | 576 (712) | 9.6 (10) |
| Mixed 256 KiB stream | updates | 2,438 (2,826) | 34 (34) |
| | settle | 3,095 (3,252) | 5.4 (7) |
| | close | 330 (338) | 8.5 (15) |
| Mixed 1 MiB stream | updates | 40,563 (40,979) | 75 (80) |
| | settle | 43,019 (44,744) | 9.6 (12) |
| | close | 2,373 (2,518) | 16.4 (24) |

The answer now appears after its background parse and layout: mixed 0.5 s at 256 KiB and 2.2 s at 1 MiB, soft breaks 0.4 s and 1.7 s. On main it appeared when the main thread came free, after the stall above. Until then the row holds the timeline's estimated height.

The streaming worst case at 1 MiB is the first update in a new window: an 8 KiB reply laid out on the main thread, below the 32 KiB threshold, plus the window's first buttons and icons. Later updates stay near 30 ms.

## Perf review

[fc84216](2026-10-27-fc84216-w1.md) against the last three saved runs flagged `open.stall_max_ms` (one 55 ms stall) and `bench.markdown_stream_delta_full` (31.2 ms, range 24.4 to 55). A review of main without this work, [54d92da](2026-10-27-54d92da-w1.md), shows the same open stall (55.7 ms) and the same first frame (67 ms against 50 ms in the saved runs), so it came with other commits on main since those runs, not with this change. A quiet rerun of the Markdown benchmarks with this work measured `markdown_stream_delta_full` at 18.1 ms, `markdown_layout` at 47.3 ms and `markdown_parse` at 13.4 ms. Idle CPU, wakeups, idle and big-thread memory and scrolling stayed within thresholds.
