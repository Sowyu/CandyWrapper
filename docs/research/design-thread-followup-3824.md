# Thread design follow-up, Nightly 3824

Task: design-thread-followup, taken 2026-10-28. Local commits only, offscreen checks only.

## Parallel theme isolation

The ten extra `toggleTable` controls in `MarkdownBackgroundLayoutTests.viewLaysOutInBackground` came from `MarkdownTableTests` changing the global Dither flags while a background layout was running. Restoring the theme with `defer` protects the next synchronous main-actor test, but does not protect concurrent background work. `RedesignSwitchTests` uses that synchronous restoration pattern; fidelity suites pin the globals before rendering. Neither mechanism makes a non-default theme safe to hold across suspension. The earlier v1.14.9 failure recorded in `PROGRESS.md` was a separate 20-second timeout under load, addressed with the existing 120-second wait. This change leaves that wait and all assertions intact.

Table tests now inject their design through a task-local scope. Background layouts capture the choice when enqueued and carry it into their parallel workers. The background suite pins its expected design explicitly, and its view-layout case exercises both the default and legacy designs with the same full-signature comparison.

The first parallel verification exposed another existing race: `ComposerLayoutTransitionTests.externalChromeRestoresTheFrameAfterOnlyTheComposerWasInvalidated` held Glass flags across `await eventually`, which selected legacy behavior in three new queue tests. The user authorized fixing that test and any other suite holding a global theme across `await`. A shared synchronous `withTheme` scope now restores the global theme before every suspension. The composer test uses it for setup, each eventual layout check and the final assertions. The opt-in gallery screenshot test was the only other test holding a non-default theme across suspension; its setup, actions and captures now use the same scope. Its image-loading waits run with the global theme restored. No assertion changed.

Audit: `SidebarUpdateCheckTests` changes themes only in synchronous tests; its async test does not change themes. Fidelity scope helpers pin the standard theme and render synchronous cases. `RedesignSwitchTests` and the other explicit theme mutators restore within their synchronous main-actor tests.

Verification: three consecutive `scripts/test --fast` runs pass in parallel, each with 2,221 Swift Testing tests and 19 XCTest tests. Logs: `/tmp/design-thread-followup-isolation-fast-{1,2,3}.log`. The opt-in `ThreadImageGalleryTests.offscreenRenders` check passes with `GALLERY_SNAPSHOTS=/tmp/design-thread-followup-gallery`. A line-by-line check confirms all existing assertions are unchanged.

## Thread screen source audit

All source citations below refer to `v0.1.4-nightly.20261028.3824`, read with `git show` because the research checkout itself still has 3669 checked out.

- `apps/web/src/lib/diffRendering.ts:3-15` selects `t3-light` for light code and keeps `pierre-dark` for dark code.
- `apps/web/src/lib/readableSyntaxTheme.ts:6-50` defines the light-color contrast transform, including the three colors with a stronger floor.
- `apps/web/src/appearanceFonts.ts:96-100` applies antialiased text when font smoothing is enabled. The captured thread screens use that setting; their native fixture initially used the component harness's heavier Core Text smoothing.
- `apps/web/src/index.css:2170-2173` wraps code with `pre-wrap` and `overflow-wrap:anywhere`.
- `apps/web/src/index.css:2201-2246` defines wrapping 14px tables, padding, collapsed row borders, the 24rem cap and uncapped formulas (#26449).
- `apps/web/src/components/chat/MarkdownCodeBlock.tsx:68-88` defines the code surface and header geometry.
- `apps/web/src/components/chat/TimelineAssistantRows.tsx:32-73` and `MessagesTimeline.tsx:1430-1445` define the message insets, meta spacing and row padding.

## Validation

Pending the final runs. Initial fresh renders reproduce 5.79% light and 5.61% dark for 03c, and 5.51% light for 03n, against the unchanged 5.50% ceiling. Initial images: `/tmp/design-thread-followup-before/`.
