# Prompt and floating preview fixes

The user reported a five-image message whose prompt disappeared and a transparent Connecting strip across the Git card. Release stays on hold for the user's screenshot approval.

## Changes and source

- The user-message row now measures attachments separately from the collapsed text. The grid keeps its full height, the prompt gets its own 176pt preview, and the expand button sits below the prompt. Find matches use coordinates within the text, so an image grid does not make a visible match expand the message. T3 Nightly 3234: `apps/web/src/components/chat/MessagesTimeline.tsx:2420-2528` puts attachments before the collapsible body; `:4692-4758` clamps only that body.
- The floating browser has an opaque background, including while no frame has arrived. Its control bar also paints an opaque background. The old Glass ground was clear and the card's muted color was only an overlay. T3: `apps/web/src/components/preview/ThreadPreviewMiniPlayer.tsx:537` owns the card surface; `apps/web/src/browser/ServerBrowserSurface.tsx:722` paints the control bar background.
- Floating previews account for the details card and composer, including dragged positions and small canvases. The fallback stays inside the canvas when obstacles leave no free space. T3: `apps/web/src/components/preview/previewMiniPlayerLayout.ts:150-267`.
- Automatic opening remains T3's existing setting and reveal behavior. `apps/web/src/components/preview/useAgentOpenedPreviews.ts:87-125` opens new revealed tabs when Auto-show floating preview is on. This change does not alter the browser transport.

## Validation

- Full `scripts/test`: 1,530 tests passed. After the final crowded-canvas clamp correction, all 9 focused prompt/preview and browser logic tests passed.
- Regression coverage includes 1, 2, 5 and 10 images at two widths, collapsed and expanded long prompts, short and empty prompts, opaque preview surfaces in Glass light and dark at 10% opacity, and preview placement around the details card and composer.
- An isolated Debug app replayed synthetic projections from `~/CandyWrapper-research/sandbox/layout-proof/`. Five image thumbnails, readable collapsed text, expansion, and the browser's connecting state were checked in real windows. No live user data or provider turn was used. The new Debug-only preview-file arguments make this reproducible in isolated test builds.
- Screen captures are in that folder's `screenshots/`: `prompt-dark.png`, `prompt-expanded-dark.png`, `prompt-light.png`, `browser-dark.png` and `browser-light.png`. These are native window captures, not mockups.
- Diff review: no wire, credential, server lifecycle or release changes. No new timers, polling, web views or image decoding work. The extra preview placement work runs only during layout of a shown preview.

## Performance review

The full three-sample review, including package benchmarks, is in [the report](../perf/2026-10-17-d547087-dirty-w1.md). Median window time was 225 ms, idle CPU 0.049%, idle footprint 38.0 MB, startup peak 84.8 MB and scroll CPU 366.3 ms. CPU, scrolling, thread switching and package benchmarks had no threshold regressions.

The saved baseline predates the recent blur releases. It flagged idle footprint (34.2 to 38.0 MB), idle peak (34.4 to 84.8 MB) and large-thread peak (36.3 to 86.4 MB). A follow-up used an isolated copy of the published v1.5.2 build 27, with a separate bundle id and URL scheme and its updater disabled. Three 10-second idle samples measured a median 37.7 MB footprint and 84.7 MB peak; one large-thread sample measured 86.3 MB peak. The [control measurements](../perf/2026-10-17-prompt-preview-control.json) show that these memory costs already exist in v1.5.2. Their cause has not been isolated. No material memory increase was found from these visual fixes.

The control reused the performance harness and its private workload copy. Both performance servers and all test apps were stopped; the temporary app builds and control copy were removed. The user's app stayed running. Release remains unapproved.
