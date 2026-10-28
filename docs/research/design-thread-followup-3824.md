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
- `packages/contracts/src/settings.ts:445` defaults font smoothing to true; `apps/web/src/appearanceFonts.ts:96-100` applies antialiased text when it is enabled. The captured thread screens use that setting; their native fixture initially used the component harness's heavier Core Text smoothing.
- `apps/web/src/index.css:2170-2173` wraps code with `pre-wrap` and `overflow-wrap:anywhere`.
- `apps/web/src/index.css:2201-2246` defines wrapping 14px tables, padding, collapsed row borders, the 24rem cap and uncapped formulas (#26449).
- `apps/web/src/components/chat/MarkdownCodeBlock.tsx:68-88` defines the code surface and header geometry.
- `apps/web/src/components/chat/TimelineAssistantRows.tsx:32-73` and `MessagesTimeline.tsx:1430-1445` define the message insets, meta spacing and row padding.

The default Markdown renderer now uses the exact light-color transform, computed once per token kind. Its existing dynamic colors still serve dark, Glass and Redesign; other code surfaces keep their existing palette.

The screen fixtures now select the captured antialiased text setting and restore it after each synchronous render. The component harness keeps its original setting. This exposes the remaining geometry error clearly: every block near the bottom is about 4.4pt low, and the 30% viewport is about 1.3pt low.

The trailing alert lost its descendant paragraph margin when the root zeroed the alert's own margin. `ChatMarkdown.tsx:972-985` renders the note as an outer div containing paragraphs; `index.css:1869-1881` resets only the outer last child's margin. The nested paragraph's 10.4pt margin still collapses through that div and with the 6pt assistant-meta gap. Preserving it adds `10.4 - 6 = 4.4pt` to the settled row's height. That aligns the bottom viewport by 4.4pt and the 30% viewport by 1.32pt. The fix applies to default themes; the legacy layout remains exact. A regression test checks that the nested margin survives while an ordinary final paragraph still has no trailing margin.

## Validation

All three requested cases pass their unchanged 5.50% ceiling:

| Case | Before | After |
|---|---:|---:|
| 03c kitchen-sink bottom, light | 5.79% | 3.10% |
| 03c kitchen-sink bottom, dark | 5.61% | 2.48% |
| 03n narrow, light | 5.51% | 3.81% |

Narrow dark also improves from 5.14% to 3.64%. All cases in both screen suites pass. No ceiling, exception, crop, fixture text, scroll fraction or reference image changed. The existing composer inset stays unchanged.

- Fresh before images: `/tmp/design-thread-followup-before/`.
- Final ref/ours/diff images and HTML reports: `/tmp/design-thread-followup-final/`. Reviewed all three requested cases offscreen.
- Screen suites, Markdown fidelity and Markdown behavior checks pass: `/tmp/design-thread-followup-final-screens.log` (18 tests in six suites).
- Eight additional thread and timeline suites pass: `/tmp/design-thread-followup-final-components.log` (12 tests).
- Three consecutive final `scripts/test --fast` runs pass in parallel, each with 2,222 Swift Testing tests and 19 XCTest tests. Logs: `/tmp/design-thread-followup-final-fast-{1,2,3}.log`.
- The final standalone Redesign check passes all 80 images exactly: `/tmp/design-thread-followup-final-baseline.log`. The complete successful run sequence is in `/tmp/design-thread-followup-final-proof.log`.
- Reviewed the final diff; no ceiling or reference changed. `git diff --check` and the commit-range secret scan pass.

The earlier combined fidelity/baseline run reported two provider-status-dot differences in Settings (132 light pixels and 124 dark pixels). `RedesignBaselineTests` explicitly requires running alone because it owns the global theme. The standalone run passes all 80 images exactly; the final proof runs it separately too. No baseline image was recaptured.

Residual pixels include native glyph rendering, approximate token scopes and a different shell-path line break. These no longer fail any requested screen case. No GUI app or real server turn was started. No push or release was performed. The integration owner still owns the full release/performance review.
