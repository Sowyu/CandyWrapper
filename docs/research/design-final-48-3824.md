# Final 48 turn-chat fidelity, Nightly 3824

Task: design-final-48, taken 2026-10-28. Base: `f3b127cc`. Local commits only; no push.

## Source audit

Read-only source at `v0.1.4-nightly.20261028.3824`:

- `apps/web/src/components/chat/TimelineUserMessageRow.tsx:468-475` gives the user bubble `p-3`, or 12pt per side, without a border.
- `TimelineUserMessageRow.tsx:445-448,648-678` lays out the hover footer under the bubble with a 4pt column gap; the timeline wrapper adds `pb-4`.
- `apps/web/src/components/chat/MessagesTimeline.tsx:1430-1445` adds 16pt under a user row, 6pt under a turn fold, and 8pt under an assistant message without metadata.
- `MessagesTimeline.tsx:1636-1644` gives the worked row 4pt above, 8pt below, a 1pt border and 14pt text with 1.625 line height (22.75pt).
- `apps/web/src/components/ChatMarkdown.tsx:1651-1653` gives Markdown the same 22.75pt line height.
- `apps/web/src/index.css:1865-1881` resets the first and last block margins and uses 10.4pt paragraph margins between blocks.

- `apps/web/src/appearanceFonts.ts:96-100` maps enabled smoothing to CSS `antialiased`, represented by native stem darkening off in these screen fixtures.

## Investigation

The isolated AppKit probe confirms that attaching a view to a 1x window rounds its clip bounds. A 45.5pt offset becomes 46pt on attachment; `setBoundsOrigin` also aligns to the backing pixel grid. A 2x window preserves the fraction. On the existing 1x window, `NSClipView.scroll(to:)` after attachment preserves 45.5pt through `window.display()` and the clip layer retains that exact bounds origin.

The user row in the narrow fixture starts at 76pt and measures 181.75pt. Its bottom is 257.75pt, while the next row was placed at 258pt. The fold's divider then rounded 34.75pt to 35pt inside that row. These independent snaps insert a quarter-point gap and move the divider another quarter point, despite the upstream layout keeping both fractional values. Default-theme rows and the divider now retain their calculated positions. Glass and Redesign keep the old snapping.

Snapshot now accepts a synchronous preparation closure after its temporary window has attached, laid out and displayed the view. The fixture moves its existing scroll-to-card loop into that phase, retaining the same target, crop, references and limits. Calls without a closure execute the original capture steps. A small bitmap test checks that scrolling by half a point moves a one-point black line by exactly one device pixel at 2x.

The initial full parallel run also revealed font-state contamination: the async changed-files fixture held `smoothing=false` across its diff-load suspension. Other suites could reset that setting before the fixture rendered, and the fixture could alter other suites' text rendering. The captured font smoothing now uses a task-local override limited to the synchronous snapshot. It does not invalidate live font recipes, change their generation, or hold global state across suspension. A regression checks those guarantees.

The standalone original case reproduces 4.98% light / 5.05% dark. Fixing capture timing alone gives 4.52% / 4.60%, before the production spacing correction. The contaminated initial combined run measured 5.62% / 5.30%; its other case images are not a clean control for font smoothing.

## Scoped validation

`scripts/test --filter 'ChangedFilesFidelityTests|ThreadFidelityTests|ReferenceScreensFidelityTests|TimelineGapsFidelityTests|TimelineRowPlacementTests|SnapshotTests'` passes. Features runs 10 tests in six suites; both Snapshot tests pass, including the two scroll offsets. Log: `/tmp/design-final-48-spacing.log`.

| Screen | Light | Dark |
|---|---:|---:|
| 03a top | 2.81% | 2.55% |
| 03b middle | 3.42% | 3.00% |
| 03c bottom | 2.11% | 2.07% |
| 03n narrow | 3.25% | 3.41% |
| 48 chat | 4.93% | 4.45% |
| 48 panel | 0.99% | 0.95% |

All retain their existing limits. The fixture also checks the card's actual position immediately before rendering. Native glyph rendering still accounts for residual pixels; this is not a claim of exact matching to Chromium.

The isolated app build succeeds (`/tmp/design-final-48-build.log`). Inspected the sandbox changed-files thread in light and dark native window captures (`/tmp/design-final-48-window-{light,dark}.png`). An existing Keychain password dialog obscures part of WindowServer captures and blocks interaction, so the app's own real-window layer captures supplied the unobscured review. No password or dialog action was entered. The app quit, the screen lock was released and `/tmp/cw-dd-design-final-48` was deleted.

## Harness audit

Kept the production spacing fix identical in both controls. The first uses `f3b127cc`'s Snapshot, FontRuntime and changed-files fixture, with `ChangedFilesFidelityTests` excluded from execution. The second restores the new harness and scoped smoothing and excludes the same fixture. Both run `scripts/test --filter 'Fidelity|RedesignBaselineTests' --skip ChangedFilesFidelityTests --no-parallel`.

Both controls pass 82 Features tests in 54 suites and 66 DesignSystem tests in 11 suites. All 80 Redesign baselines match exactly in both. Compared decoded RGBA pixels for every emitted render PNG: **1,878 unchanged, zero changed, zero missing**. This separates the harness audit from the intended production spacing change. No per-case allowance or replacement reference was used.

Logs: `/tmp/design-final-48-control-{old,new}.log`. Exact image comparison: `/tmp/design-final-48-harness-comparison.txt`. The control image directories use those same prefixes. Old control reference and diff copies were removed during the disk cleanup; all compared render PNGs remain.

## Parallel font isolation follow-up

The first combined run after the geometry fix passes 48 at 4.93% light / 4.45% dark and keeps all 80 Redesign images exact, but exposes the other async screen fixture's global font mutation. `DiffFidelityTests.panel` also held smoothing off across its loader suspension. The standalone task rows and permission toast in `ThreadSweepFidelityTests` do not use timeline placement; their aggregate reaches 5.38% against its unchanged 5% limit under that leaked setting. Log: `/tmp/design-final-48-final.log`.

The diff fixture now uses the same task-local capture scope. No remaining screen fixture holds a non-default global smoothing setting across suspension. The synchronous screen helpers restore their setting before returning.

`scripts/test --filter 'DiffFidelityTests|ChangedFilesFidelityTests|ThreadSweepFidelityTests|TimelineRowPlacementTests|SnapshotTests' --no-parallel` passes all 12 tests. 48 chat is 4.35% light / 4.45% dark, and its panels are 0.96% / 0.95%. The sweep mean returns to 4.30%. Its eight images and all 22 diff images match the original control exactly. Logs and proofs: `/tmp/design-final-48-isolation.log`, `/tmp/design-final-48-diff-comparison.txt`, `/tmp/design-final-48-sweep-comparison.txt`.

## Fast validation

`scripts/test --fast` passes in parallel: 2,233 Swift Testing tests across seven targets and 19 XCTest tests, with no failures. Log: `/tmp/design-final-48-fast.log`.

## Final parallel validation

`scripts/test --filter 'Fidelity|RedesignBaselineTests'` passes in parallel: 84 Features tests in 55 suites and 66 DesignSystem tests in 11 suites, or 150 tests total. All 1,884 reported fidelity comparisons pass their unchanged checks. All 80 Redesign images match exactly. The previously exposed sweep mean is 4.30%.

| 48 region | Light | Dark | Existing limit |
|---|---:|---:|---:|
| Chat | 4.93% | 4.45% | 5% |
| Right panel | 0.99% | 0.95% | 5% |

The requested 03a, 03b, 03c and 03n results match the scoped table above and all pass. Log: `/tmp/design-final-48-verified.log`. Final ref/ours/diff PNGs and reports: `/tmp/design-final-48-verified/`, including `changed-files/48-diff-turn-file.{chat,panel}.{light,dark}.{ref,ours,diff}.png`.

The focused and combined runs are reported separately; the combined light chat result is the conservative final figure. No failure remains in either requested command.

## Review and cleanup

Reviewed the complete source and test diff, default-theme gates, task-local restoration, capture phase and existing limits. `git diff --check` and the implementation-range secret scan pass. No reference, crop, target or threshold changed. No new timer, polling, observer or retained hidden view was added.

All test commands ran in the background with a 30-minute limit each. Other build artifacts drove disk below 40 GB during validation. Preflight failed, new builds paused, and this task's diagnostic copies and compilation intermediates were removed. Builds resumed after the user freed space and preflight reported 46 GB. The isolated app and preview JSON copy are deleted. No live T3 data, real turn, sign-in, push or release was used.

## Commits

- `2cbc8805`: take the task locally.
- `da183f6a`: fractional default-theme placement, snapshot preparation, scoped smoothing and regression tests.
- `635d203d`: isolate the async diff screen fixture's smoothing.

The final documentation commit records the completed validation and closes the task in `PROGRESS.md`.
