# First image expansion, 2026-10-23

## The missed path

The inline image had loaded, but expanding a Markdown image constructed a fresh loader. That loader signed and downloaded the same source again before it could show pixels. Attachment thumbnails also used a cover cache key while the viewer used a fit key, so the viewer could open blank despite usable pixels in the visible view. Its pending label was the failure message, "Image unavailable. The file may have been moved or deleted."

T3 shows that failure only when the source is missing or its image reports an error: `apps/web/src/components/chat/ExpandedImageDialog.tsx:221-240`, with the image's load/error callbacks in `apps/web/src/components/chat/ZoomableImage.tsx:244-250`. The browser can reuse the source bytes between the inline and expanded image.

## Changes

- A viewer takes its first pixels directly from the clicked image view. The reference is weak and checks the image key, so an offscreen or reused cell cannot retain or supply the wrong pixels. This also works when the decoded cache has been emptied.
- Markdown and tool output expansion reuse the inline view's actual loader. That loader owns one downloaded temporary file across display sizes and zoom. A new loader still reads current workspace or web bytes; there is no global path cache that can leave edited files stale.
- Concurrent sizes share an in-flight download. Cancelling one consumer leaves other consumers running; the last consumer cancels the fetch. Temporary files are removed on a utility task when the loader and its users release them.
- Sent attachments and both draft image shelves pass their visible pixels to the viewer. A cover thumbnail is a temporary picture, and the full fitted decode still loads.
- Pending loads show "Loading image…". A real failed load without pixels shows the unavailable message. A failed sharp decode keeps the thumbnail already visible.

## Real-window measurement

An isolated Debug app displayed an assistant Markdown image from a local HTTP fixture under the sandbox. Every image response waited three seconds and sent `Cache-Control: no-store`. The generated PNG was 3000 by 2000 pixels, and the test used the 1x virtual display.

The inline 480 px decode arrived at 3,149.7 ms. Clicking that loaded image reused its pixels in the viewer and issued no new HTTP request. The 1024 px sharp decode ran from 17,696.4 to 17,736.3 ms, or 39.9 ms. Click zoom requested 1920 px and completed in 52.7 ms. The server recorded exactly one image request across inline display, expansion and zoom. Panning added no decode. Escape restored the thread. Screen captures contain sandbox data and were not committed.

These are decode request-to-pixel timings from one controlled window, not a claim that every network's first download takes 40 ms. The fix removes the second download after the inline image has loaded.

## Validation

Regression coverage holds the sharper loader behind a gate and checks that the thumbnail is visible synchronously, including after cache eviction. It also covers loader reuse, loading versus failure labels, failed upgrades, reused and released views, one source fetch across three sizes, concurrent fetch sharing, individual and last-consumer cancellation, and temporary-file cleanup.

The final focused run passed all 32 checks, including attachment fidelity. The new view checks share the existing cache suite's serialized lane, so their cache eviction cannot cancel another suite's requests. All 1,831 tests passed again after the final code and test review. The complete Release review is saved in `2026-10-23-09b113f-dirty-w1.md` and `.json`, compared with `2026-10-23-41f1730-dirty-w1.json`. It flagged no new regressions: idle CPU 0.043%, idle footprint 40.4 MB, and scroll CPU 322.0 ms versus 347.6 ms. The last open run overlapped another app, and its final stall sample began at load 3.12 after the quiet wait expired; the report retains both caveats. The review measures this image patch before the later slim-header refinement was merged; the combined release passed all 1,832 tests on `f79a93fa`. The previous whole-app review and its two image-free benchmark follow-ups remain in `image-rendering-2026-10-23.md`; this correction uses the slow-source measurement above to validate the reported delay directly.

The final code review checked source-file lifetime across suspended decodes, cancellation ownership, weak preview references, cell reuse, Force Reload rebuilding the image loaders, fit geometry, and the distinction between pending loads and actual failures. No further blocker remained.

## Release

Published as v1.12.12 (build 61) from `f79a93fa`, with the pending Redesign header, tab rim/alignment and composer pill refinements. The release script verified the signed archives and their downloads. A separate public API and feed check confirmed the exact commit, both asset names, version 1.12.12, build 61, ZIP length and the enclosure signature.
