# Final diff fidelity, Nightly 3824

Task: design-final-diff, taken 2026-10-28. Base: `3b27d2f6`. Local commits only, offscreen checks only.

## Source audit

All upstream source citations refer to `v0.1.4-nightly.20261028.3824`, read with `git show` from the read-only research checkout.

- `apps/web/src/components/DiffPanel.tsx:438-454,1206-1216` supplies a full-file loader only for a readable git selection. Turn diffs do not have it. `apps/web/src/lib/diffFileContents.ts:44-98` maps paths and source refs into `review.getDiffFileContents`; `packages/contracts/src/review.ts:44-59` defines the input and the two returned strings.
- `apps/web/src/components/diffs/StyledDiffCodeView.tsx:114-139` sets the 24px separator, neutral label, 97% background mix and 92% hover mix.
- The shipped 3824 `client/assets/getDiffFileInput-B8yME0jB.js:1` contains Pierre's `Wn` partial-file gate, `More unchanged context may be available` tail, `expandHunk`, and the default 100-line expansion count. `client/assets/FileDiff-2mMflMjT.js:1` supplies `loadFilesIfNecessary`, ignores a response after the input changes and keeps failed loads retryable. `client/assets/useNextRenderData-CsUWVGu_.js:1` maps the up/down/both expansion controls.
- `apps/web/src/components/chat/ChatHeader.tsx:275-312,349-394` reserves `pr-10` beside the open right panel and gives the title its own chevron. Native layout reserved that chevron twice, truncating the title 18pt too soon.
- `apps/web/src/index.css:469-505` masks the first 24pt below the header. The native overlay still started at the window top, mostly underneath the opaque header.
- `apps/web/src/index.css:2118-2127` gives inline code its own leading and trailing padding. Native kerning put the leading padding on the previous whitespace; TextKit discarded it when a chip started a wrapped line.

## Implementation

Git diff selections now provide the full-file RPC through the app session. Modified partial files render the unknown trailing context row only when that loader is available. Expanding a gap loads the two sides on demand, checks them against the displayed patch, reveals up to 100 lines from the requested ends, merges touching hunks and retains the fetched contents for later expansion. A new selection, a hidden view or a detached window cancels outstanding work. Failed loads keep the expansion control available for retry. Search indices and visible-line anchors follow expanded content.

The default chat header uses the correct open-panel reservation and fade. The fade has its own view between the scroller and header, because offscreen layer rendering ignores a loose layer's zPosition and painted the old overlay behind the scroller. Inline-code padding travels with its code through a line break; its background fills the transparent border area instead of losing 1pt on every edge. Every visual change is gated away from Glass and Redesign.

The 09/10 fixture now opens a git selection through the panel's actual loader path. Its patch, comparison region, references and ceilings are unchanged. No reference or exact Redesign baseline is regenerated.

## Baseline

The initial scoped run reproduced the previous report. Images: `/tmp/design-final-diff-before/`; log: `/tmp/design-final-diff-before.log`.

| Case | Light | Dark | Unchanged ceiling |
|---|---:|---:|---:|
| 09 split diff | 10.65% | 10.64% | 8.5% |
| 10 stacked diff | 9.48% | 9.46% | 8.5% |
| 47 changed-files card | 2.20% | 2.28% | 5% |
| 48 turn chat | 6.37% | 6.83% | 5% |
| 48 turn panel | 0.96% | 0.95% | 5% |

## Validation

Final images and reports: `/tmp/design-final-diff-final/`. The ref/ours/diff PNGs were inspected for split, stacked and narrow turn chat in both themes.

| Case | Final light | Final dark | Unchanged ceiling | Result |
|---|---:|---:|---:|---|
| 09 split diff | 2.68% | 2.67% | 8.5% | Pass |
| 10 stacked diff | 1.51% | 1.50% | 8.5% | Pass |
| 47 changed-files card | 2.13% | 2.21% | 5% | Pass |
| 48 turn chat | 4.98% | 5.05% | 5% | Dark fails |
| 48 turn panel | 0.96% | 0.95% | 5% | Pass |

- `scripts/test --filter 'DiffContextTests|DiffTests|DiffFidelityTests|ChangedFilesFidelityTests|Thread.*FidelityTests|.*Panel.*FidelityTests' --no-parallel --jobs 2`: all requested suites ran. Features has 44 tests in 15 suites, with the one dark chat assertion above. Its 13 fidelity suites report 170 comparisons, 169 passing. All six new context regressions and the git/turn/permission loader assertions pass. Eleven additional diff/store tests in two suites also pass. Log: `/tmp/design-final-diff-final.log`.
- `scripts/test --fast --jobs 2`: all 2,229 Swift Testing tests and 19 XCTest tests pass in parallel. Log: `/tmp/design-final-diff-fast.log`.
- Standalone `scripts/test --filter RedesignBaselineTests --no-parallel --jobs 2`: all 80 images match exactly, with zero changed pixels. Log: `/tmp/design-final-diff-redesign.log`.
- `scripts/build-test-app design-final-diff` passes, including the app RPC wiring. The app was not launched, and `/tmp/cw-dd-design-final-diff` was deleted afterward. Log: `/tmp/design-final-diff-build.log`.
- Reviewed the complete source/test diff, request paths, cancellation, theme guards, source citations and unchanged limits. `git diff --check` and the implementation-range secret scan pass.
- Every test command ran in the background with a 30-minute limit. Free disk stayed above 40 GB. No GUI app, live server access, turn, reference recapture or baseline regeneration was used. The integration owner retains the full release/performance review.

## Remaining dark chat failure

Resolved by [design-final-48](design-final-48-3824.md): the final parallel run reports 4.93% light / 4.45% dark, with all 80 Redesign images exact. The source audit and controlled image comparison explain the row snapping and capture-phase fixes.

Dark 48 still exceeds 5% by 0.05 percentage points. The final diff PNG shows small glyph-edge and divider displacements, rather than a missing surface. The requested card top remains 464.5pt. Instrumenting the rendered tree shows its actual top at 464.9pt, the assistant Markdown at 256.5pt and the turn-fold row at 213pt. This accounts for part of the remaining one- to two-device-pixel alignment error.

An isolated AppKit probe confirms that attaching Snapshot's temporary 1x window rounds an existing clip offset of 45.4pt to 45pt. A standalone 2x window accepts half-point offsets after attachment. Before attaching a window, `scroll(to:)` and `setBoundsOrigin` both preserve the fraction. Changing only the test scroll hook therefore does not fix this, and that ineffective experiment was removed. The production scroll code and Snapshot helper remain unchanged. A general offscreen backing-scale and scroll-phase correction needs an audit of the existing exact baselines; no special offset, crop, ceiling or per-case exception was added here.

There are also residual native glyph metrics in the header, worked row and changed-files labels. This task does not claim that the rounding issue explains every remaining pixel or that dark 48 passes.

## Commits

- `cc9a9f23`: take the scoped task locally.
- `e33d894c`: git full-file RPC, context controls, hydration and regression tests; 09/10 use the actual git loader path.
- `1f02ad1b`: default narrow header, hosted fade and inline-code padding/fill fixes.

The final documentation commit records this validation and leaves the remaining dark chat assertion open in `PROGRESS.md`. No commit was pushed.

