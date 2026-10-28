# Panel and thread design merge, Nightly 3824

Task: design-merge-panels, taken 2026-10-28. Merge `t3/design-panels` at `5df1ff93` into the integration state at `811de35e`. Local commit only, no push or release. The panels handoff is in that branch's `PROGRESS.md`; its implementation commits carry the source audit. The thread handoff is [nightly-thread-3824-design.md](nightly-thread-3824-design.md).

## Conflict resolutions

Source paths below are relative to `apps/web/src/` at `v0.1.4-nightly.20261028.3824`, read with `git show` from the research checkout. The source checkout was left unchanged.

| File and conflict | Resolution and source |
|---|---|
| `DiffRowViews.swift`, four stat-color hunks | Keep the thread group's shared `ThreadDesign.diffAddition` and `diffDeletion` in all four setters. Remove the panels group's duplicate color providers. Both select foreground roles in default themes and the previous roles in Glass and Redesign. `components/chat/DiffStatLabel.tsx:29-44`. Retain the panels group's separate header, hover and syntax changes. |
| `ThreadDetailsCardView.swift`, two totals hunks | Keep one `DesignGeometry.usesClassic` gate, one gap property and one metrics updater throughout `DiffTotalsView`, including initialization. Default totals use 12pt type, a 6pt gap, foreground roles and muted zeros; classic themes retain 11pt, 4pt and their old colors. Keep the thread group's surrounding details-card implementation. `components/GitActionsControl.tsx:1629-1647`. |
| `PullRequestTabs.swift`, avatar wiring | Keep the panels group's `reviewOutcome` and `staleReview` assignment with the ring. Update the thread fidelity fixture to the same property; retain no alias. `components/pullRequest/PullRequestSummaryTab.tsx:674-703`. |
| `PullRequestViews.swift`, three avatar hunks | Keep the panels group's single avatar implementation, including its verdict creation, review-ring decoration, clipping and stale-color mixing. Remove the thread group's duplicate glyph, clipping state and appearance override. Dismissed reviews use the source's dashed circle. Default badges remain 12pt, offset -4pt, stroke 3, stale opacity 50%; classic themes retain their old face and ring. `components/pullRequest/pullRequestPresentation.tsx:274-315,350-370`. |
| `gen-git-spec.py`, source lookup | Keep the panels group's explicit 3824 source reader and the thread group's Mac mini/studio helper. Keep the current totals and plain context-row markup. `components/chat/threadDetailsPanelStyles.ts:18-47`; `components/EnvironmentMachineIcon.tsx:6-36`; `components/GitActionsControl.tsx:1632-1647`. Correct the generator's zero count to muted foreground, matching the native implementation and source. |
| `PROGRESS.md` | Preserve every line from both sides and add this merge's status. |

## Reference review

Ran `/usr/bin/python3 -I scripts/gen-git-spec.py`, then `scripts/component-reference design/component-reference/git.json`. The generated spec combines the updated machine icon with the new totals. Beyond the incoming panels branch, four Git card PNGs changed; the remaining ten Git images stayed unchanged. Inspected the light and dark card PNGs, including the muted zero. No other generator needed a merge edit; their panel references arrive together with their original generator commits. No reference ceiling, exception or pixel mask changed.

## Validation

Runs use `scripts/test` in the background with a 30-minute limit per invocation, `--no-parallel --jobs 2`, avoiding the thread handoff's known global-theme race.

The fast lane passes all 2,221 Swift Testing tests and 19 XCTest tests. RedesignBaselineTests passes all 80 images with exact pixels. Logs: `/tmp/design-merge-panels-fast.log`, `/tmp/design-merge-panels-redesign.log`.

All 22 requested fidelity suites ran, plus ReferenceScreensFidelityTests to confirm the third known thread screen failure. All 238 component images pass. The 32 screen comparisons retain only the known failures below, with no new failure outside the supplied exemptions. There are 20 failing assertions across 13 unique screen cases. Log: `/tmp/design-merge-panels-fidelity.log`. Artifacts: `/var/folders/5l/jp2p1_8x1_d7j38f8pwbgl5c0000gp/T/candywrapper-fidelity-21435/`.

| Suite | Pixel cases | Result |
|---|---:|---|
| BrowserFidelityTests | 10 | Pass |
| ChangedFilesFidelityTests | 6 | Five known old-reference screen cases; ten assertions |
| DevicePanelFidelityTests | 4 | Pass |
| DiffFidelityTests | 22 | Two known old-reference dark screen cases |
| FilesFidelityTests | 8 | Pass |
| GitFidelityTests | 14 | Pass |
| MarkdownFidelityTests | 18 | Pass |
| PanelLeftoversFidelityTests | 8 | Pass |
| PanelsFidelityTests | 8 | Three known old-reference docked cases; five assertions |
| PullRequestWritesFidelityTests | 6 | Pass |
| PullRequestsFidelityTests | 18 | Pass |
| ReferenceScreensFidelityTests | 10 | Known 03n light case, unchanged |
| SmallAreasFidelityTests | 10 | Pass |
| SweepPanelsFidelityTests | 4 | Pass |
| TerminalDrawerFidelityTests | 6 | Pass |
| ThreadCompletionFidelityTests | 14 | Pass |
| ThreadFidelityTests | 8 | Known 03c light/dark cases, unchanged |
| ThreadLeftoversFidelityTests | 14 | Pass |
| ThreadLineageFidelityTests | 22 | Pass |
| ThreadSweepFidelityTests | 8 | Pass |
| ThreadViewFidelityTests | 24 | Pass |
| TimelineGapsFidelityTests | 24 | Pass |
| WP717FidelityTests | 4 | Pass |

The unchanged thread screen differences are 03c light 5.79%, 03c dark 5.61%, and 03n light 5.51%, against their existing 5.5% ceilings. The supplied integration thread fix remains separate. ThreadView improves from the thread handoff's 4.80% mean to 4.58% with the retained panels avatar renderer.

The old-reference screen differences are Diff split/unified dark 97.04%; ChangedFiles card light 21.03%, card dark 30.37%, turn chat light 22.83%, turn chat dark 31.79%, turn panel dark 98.52%; Panels docked approval light 26.88%, dark 23.90%, and question dark 10.07%. Those suites still read the old `design/reference/` screen set. They are preserved for the integration reference refresh; no ceiling was raised.

Reviewed the merged source diff, including the default/classic gates, appearance-specific colors, totals metrics, avatar clipping and event-driven hover updates. `git diff --check` and the pre-commit identity guard pass. No protocol, polling or idle animation change was introduced by the conflict resolution. The parent integration session owns the full combined performance review.

The isolated app build passes (`CANDY_BUILD_JOBS=2 scripts/build-test-app design-merge-panels`). Build log: `/tmp/design-merge-panels-build.log`.

Launched the isolated test app with a recorded sandbox projection and `--preview-details` in light and dark, reviewed both live-window snapshots, and confirmed the details card and totals draw correctly. The previews never connected to a server or sent a turn. Both app processes exited normally, the screen lock was released, the temporary sandbox projection was removed, and `/tmp/cw-dd-design-merge-panels` was deleted. Window captures: `/tmp/design-merge-panels-window-light.png` and `/tmp/design-merge-panels-window-dark.png`. No user app or shared sandbox server was stopped.
