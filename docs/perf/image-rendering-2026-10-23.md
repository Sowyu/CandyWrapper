# Image rendering, 2026-10-23

## Changes

- Immutable attachment, draft preview, diagram and tool output views share requests and the existing 48 MB decoded-image cache. A smaller decode finishing late cannot replace sharper cached pixels. Workspace paths and ordinary web URLs stay uncached so a new view reads current bytes. Inline data URLs also stay outside this cache: their potentially large source text would become an additional cache key allocation.
- Resizing, a backing scale change and zoom can request sharper pixels. Existing pixels remain visible during the upgrade, and shrinking and panning reuse them. Failed upgrades do not loop on layout. The viewer requests sizes in 128 px steps, up to 4096 px on the longer side.
- Hiding or removing a view drops its pixels and cancels its subscription. The last subscriber cancels the loader. A generation check rejects completions from a previous use of the view. Force Reload clears pending shared work too.
- ImageIO runs on a background actor, one decode at a time, with an autorelease pool. Cancelled queued work skips ImageIO. This limits transient source-buffer memory when several large images arrive together. Network requests can still run concurrently.
- Cover thumbnails read their source header once and cap pathological panorama decodes at 4096 px. Attachment previews retain the source's exact dimensions, so thumbnail rounding does not move the frame or pan anchor when sharper pixels arrive.
- The expanded preview uses its destination window's backing scale before it joins the window. The previous fallback requested twice the necessary side on the 1x virtual display.

T3's fitted size comes from natural image dimensions, and its 1 to 8 zoom multiplies that fitted size: `apps/web/src/components/chat/ZoomableImage.tsx:51-58,106-124`. Resize resets the zoom at `:136-142`. The native preview keeps those rules. The 4096 px decode ceiling remains a client memory limit.

## Controlled gallery measurement

`CW_IMAGE_BENCH=1 scripts/test --filter ImageRenderingBenchmarks` renders twenty copies of one generated 2400 by 1600 PNG at a 192 px decode side. Seven cold-cache runs per mode compare independent requests with sharing, in the same Debug build on the 1x display. Counts and bytes cover unique decoded images held by the twenty views; they are not whole-process footprint figures.

- Independent requests: 20 decodes, 1,966,080 decoded bytes. Median 375.63 ms, range 369.16 to 389.99 ms.
- Shared requests: 1 decode, 98,304 decoded bytes. Median 22.84 ms, range 21.50 to 22.86 ms.
- This repeated-image workload uses 95% fewer decodes and decoded bytes and completes about 16 times faster. Distinct images still need their own decodes; this comparison does not claim that speedup for every gallery.

## Review

The code review covered request ownership, cancellation before and during decode, stale completions, cache replacement order, mutable file freshness, source orientation, failure retries, size and scale changes, and geometry during sharp-image replacement. The cache stores the requested side as its quality level, since a naturally small image can satisfy a larger request without being enlarged by ImageIO.

Regression checks cover twenty simultaneous consumers, one consumer leaving while another stays, last-consumer cancellation, hidden views, larger and smaller frames, failed upgrades, late smaller cache writes, zoom geometry, bounded panorama pixels, source dimensions, queued cancellation and background decode concurrency.

A real isolated sandbox window displayed a generated 3600 by 2400 grid. Fit requested 1024 px and click zoom requested 1920 px. Dragging added no decode; closing and reopening used the 1920 px cached image immediately. Escape restored the thread. Screen captures used only sandbox content and were not committed.

The full suite passed all 1,817 tests, including the default-theme fidelity suites. A final focused run passed all 25 image cache, decoder, Markdown media and attachment fidelity checks after the last review edit. The isolated Debug app built successfully and the final source dimensions were checked in the real window.

## Standard performance review

The [full review](2026-10-23-41f1730-dirty-w1.md), compared with the last saved run on October 21, found no app-level regression: median idle CPU 0.040%, idle footprint 40.0 MB, scrolling CPU 347.6 ms (previously 431.4 ms), and first-open latency 61.7 ms (previously 68.4 ms). Wakeups, launch time, stalls and missed frames also stayed within the review thresholds.

The initial benchmark run flagged huge cache load, streaming, tool updates and appended rows. A [focused recheck without rebuilding](2026-10-23-image-bench-recheck.json) measured cache load at 24.89 ms and append at 2.59 ms, both within the older baseline. Streaming remained 1.74 ms versus 1.00 ms, and tool updates 1.55 ms versus 0.80 ms. Those two comparisons remain open performance follow-ups.

The huge-thread benchmark uses the 19-row snapshot in `03-turn2.jsonl`, repeated 300 times. It contains no image attachments or Markdown image syntax. The cache benchmark exercises `ThreadCache` without views; the update benchmark measures the whole thread panel. A direct run of the immediate parent commit would be needed to attribute the remaining differences. The review does not establish an image regression from these measurements.
