# Panel and dialog screens, Nightly 3824

Task: design-screens-panels, taken 2026-10-28. Base: `0551a0fc` on the design integration branch. Local commits only; no push, release, other agents, live-server changes or GUI input.

## Changes and sources

All upstream paths below are relative to `apps/web/src/` at `v0.1.4-nightly.20261028.3824`, read with `git show` from the read-only research checkout.

- Inline approvals use the plain work row, selectable full detail, waiting text, primary decisions and More. Preserve the response payloads, read-only/responding guards, reasons and access-override explanation. Glass and Redesign retain their existing card. Sources: `components/chat/TimelinePendingApprovalRow.tsx:43-120`, `components/chat/ComposerPendingApprovalActions.tsx:49-141`, `components/chat/WorkLog.tsx:53-91`. A focused behavior test checks the live response and refuses responses after disabling or expiring the request.
- The find bar centers its tabular count, uses the small input, and follows the pill addon's spacing. InputGroup measures the input's actual height so the 26pt unstyled small input centers inside its 36pt group. Classic themes retain the previous find layout. Sources: `components/chat/ThreadFindBar.tsx:67-125`, `components/ui/input-group.tsx:47-63,115-116`.
- Palette thread results show their status before the title, place project context beside message-match titles, and show project/provider icons in their subtitle. Optional row content is gated for classic themes, including theme changes while the palette is open. Sources: `components/CommandPaletteThreadItems.tsx:112-158,196-227`, `components/CommandPaletteResults.tsx:245-269`, `components/ThreadCommandSubtitle.tsx:64-100`, `components/ThreadStatusIndicators.tsx:617-655,659-746`, `components/Sidebar.logic.ts:1078-1092,1165-1170`. The subtitle still omits branch/worktree glyphs, marked as a deliberate shortcut in the app controller.
- Commit confirmation already exists in CandyWrapper and is wired to GitController. Added a direct screen comparison. Its VCS-status fixture deliberately shows +3 for hello.py and zero for the untracked notes.md, as in 22, while the patch/card fixtures contain +6. Source: `components/GitActionsControl.tsx:1664-1782`.

The diff and changed-files fixtures now use the two-file sandbox patch and `Document Hello Demo` projection. Approval and question fixtures use the actual replacement filename, question, options and dismiss state. Palette message ordering and approval age differ between light and dark captures and are represented separately. Read-only subscriptions recorded the notes, question and approval threads from the documented 3824 reference sandbox. No turn or file mutation was sent. The transcript contains projection messages only; home paths were scrubbed to `/Users/dev` and credentials were never recorded.

The original comparison regions and limits remain. Updated card positions follow the captured state; full-window positioning is preserved before cropping the chat column, so its header does not reserve standalone-window traffic-light space. No ceiling, threshold, mask or exception changed. Neither historical reference directory nor any `-3473` image was modified.

Full-screen fixtures follow the runtime's default font smoothing: T3's `fontSmoothing: true` means CSS `antialiased`, which is `FontRuntimeInput.smoothing = false` in the native runtime. Component references retain their existing pinned render settings. Sources: `appearanceFonts.ts:95-100`, `packages/contracts/src/settings.ts:445` from the repository root, and native `SettingsFontRuntime.swift:24-27`. Every affected test restores the pinned globals afterward.

## Screen coverage

`PanelsFidelityTests` covers 05's former drawer region and 06's question/composer. `DiffFidelityTests.panel` covers 09/10; `ChangedFilesFidelityTests.cardAndDiff` covers 47/48 at the existing main/chat/panel regions. `PanelScreensFidelityTests` adds fixed surface crops from 05, 07/08, 11, 11n, 12, 21/22, 43/44, 45/46 and 50/51. Existing find-highlight and picker component cases remain.

Two captures have no comparable offscreen NSView surface:

- 20 is CandyWrapper's native NSMenu, as in T3's desktop menu adapter. The reference is T3's web context menu. `NativeItemContextMenu.make` and `SidebarCommands.nativeMenu` supply an NSMenu, which Snapshot cannot render as an NSView without opening a real menu. The task forbids GUI input and assigns sidebar implementation elsewhere, so no substitute web-menu fixture was added.
- 52 is the web client's pre-authentication pairing page, including its product branding. CandyWrapper has no equivalent pre-authentication page; its saved-server and connection dialogs have separate component coverage. No duplicate light capture or fabricated page was added.

## Validation

All tests use `scripts/test` in the background with a 30-minute limit, `--no-parallel --jobs 2`. The work stayed above 40 GB free. No app was launched. Offscreen reference/native/diff PNGs were inspected for every new surface.

The integration owner retains the combined performance review. This task introduces no polling or idle animation.

## Measurements

The tables below distinguish the first 3824 fixture run from newly added coverage. The supplied merge handoff used old references and reported 97.04% for dark split/unified diff, 21.03% / 30.37% for the changed-files card, 22.83% / 31.79% for turn chat, 98.52% for the dark turn panel, and 26.88% / 23.90% for docked approval. Those old-reference figures are not an apples-to-apples implementation baseline.

### Existing screen comparisons

Before means the first run against the replacement 3824 fixtures (`/tmp/design-screens-panels-before.log`); after includes the final fixture, rendering and source corrections. L/D means light/dark. The smaller inline assertion is shown where a test also has a higher FidelityCeilings entry.

| Case | Before L / D | After L / D | Effective limit | Result |
|---|---:|---:|---:|---|
| 09 split diff | 11.03% / 11.13% | 10.65% / 10.64% | 8.5% | Fail |
| 10 stacked diff | 9.82% / 9.92% | 9.48% / 9.46% | 8.5% | Fail |
| 47 changed-files card | 2.78% / 3.01% | 2.20% / 2.28% | 5% | Pass |
| 48 turn chat | 15.22% / 17.32% | 6.37% / 6.83% | 5% | Fail |
| 48 turn panel | 1.28% / 1.36% | 0.96% / 0.95% | 5% | Pass |
| 05 former drawer crop | 0.00% / 0.00% | 0.00% / 0.00% | 4% | Pass |
| 06 question | 5.18% / 5.28% | 1.54% / 1.71% | 4% | Pass |
| 05 composer | 2.15% / 2.17% | 2.08% / 2.05% | 9% | Pass |
| 06 docked question | 1.73% / 1.83% | 1.73% / 1.83% | 9% | Pass |

### New direct screen comparisons

These cases had no full-screen test at the base commit. Before means their first measured capture (`/tmp/design-screens-panels-pass2.log`), after means `/tmp/design-screens-panels-reviewed.log`. The first capture already contains the initial inline approval implementation; it is not a clean-base implementation measurement. All 28 light/dark cases pass.

| Capture | First L / D | Final L / D | Limit |
|---|---:|---:|---:|
| 05-approval-request | 8.59% / 8.81% | 3.22% / 3.36% | 4% |
| 07-palette-default | 2.78% / 2.98% | 2.16% / 2.21% | 6.5% |
| 08-palette-search | 8.49% / 8.07% | 4.09% / 4.15% | 6.5% |
| 11-terminal-drawer | 0.58% / 0.58% | 0.58% / 0.58% | 3.5% |
| 11n-right-panel-narrow | 3.75% / 4.06% | 3.64% / 3.86% | 4.5% |
| 12-right-panel-files | 1.97% / 1.98% | 1.91% / 1.91% | 4.5% |
| 21-git-actions-menu | 5.39% / 5.74% | 4.18% / 4.32% | 6% |
| 22-commit-dialog | 5.61% / 4.96% | 5.54% / 4.88% | 6% |
| 43-find-in-thread | 13.79% / 13.89% | 5.26% / 5.35% | 5.5% |
| 44-thread-details-panel | 5.04% / 5.05% | 4.91% / 4.92% | 6% |
| 45-go-to-file | 2.56% / 2.65% | 2.20% / 2.23% | 6.5% |
| 46-project-search | 1.53% / 1.47% | 1.43% / 1.33% | 6.5% |
| 50-floating-thread-settings | 5.04% / 5.05% | 4.91% / 4.92% | 6% |
| 51-composer-branch-notice | 3.24% / 47.99% | 3.10% / 3.15% | 4.5% |

## Remaining failures

- 09/10 retain four failures at 9.48% / 9.46% stacked and 10.65% / 10.64% split against 8.5%. The 3824 git-selection renderer supplies `loadDiffFiles` and shows an expandable unknown trailing-context row after `hello.py`; CandyWrapper lacks that file-content loader and row. This shifts the expanded `notes.md` section by 24pt. There are also Python/Markdown token-color differences and split buffer stripe seams. The native component tests remain within their existing limits. A full context-loading port is needed, not a fabricated fixture row. Upstream gating: `components/DiffPanel.tsx:438-454,1215`; the bundled Pierre renderer gates the unknown context separator on partial files plus its `loadDiffFiles` option.
- 48's chat crop stays at 6.37% light / 6.83% dark against its unchanged inline 5% assertion. Its separate 7.5% FidelityCeilings entry passes. The remaining mismatch is in the narrow thread header's truncation, separator/text alignment and inline-code rendering; the right diff panel is below 1%. This belongs with the concurrently assigned thread work, so no shared thread-header or Markdown layout change was made.
- The broader ReferenceScreensFidelityTests run retains its supplied 03n light failure at 5.51% against 5.5%; 03n dark is 5.14%. That test file was not edited, and the assigned 43/45/46 direct surface cases pass.

The combined fidelity-plus-Redesign run reproduced the supplied test-state problem: only settings-models differed (132 light / 124 dark pixels) while the standalone 80-image Redesign run passed exactly. No Redesign baseline was regenerated. Final standalone verification is recorded below.

## Final checks and commits

- `scripts/test --fast --no-parallel --jobs 2`: all 2,221 Swift Testing tests and 19 XCTest tests pass. Log: `/tmp/design-screens-panels-fast-confirmed.log`.
- `scripts/test --filter RedesignBaselineTests --no-parallel --jobs 2`: all 80 images pass with zero changed pixels after the classic input-height guard. Log: `/tmp/design-screens-panels-redesign-confirmed.log`. The earlier last-run keyboard mismatch (3,189 light / 3,128 dark pixels) was a real regression caught and corrected by that guard.
- The final scoped screen run has exactly the six diff/chat issues described above. All 28 new direct comparisons, all eight Panels comparisons and all 18 Diff body comparisons pass. Log: `/tmp/design-screens-panels-verified.log`; PNG artifacts: `/tmp/design-screens-panels-verified/`.
- CommandPaletteTests, CommandPaletteFidelityTests and FormsFidelityTests pass on the final controls, including InputGroup. Log: `/tmp/design-screens-panels-reviewed.log`. Git, Files, TerminalDrawer, ThreadView and ThreadSweep fidelity suites pass in `/tmp/design-screens-panels-final.log`; ReferenceScreens retains only the supplied 03n light issue.
- The isolated app build passes. Log: `/tmp/design-screens-panels-build-reviewed.log`. The final classic-only input-height guard was subsequently compiled and checked by the package fast lane and exact Redesign suite. No app was launched; `/tmp/cw-dd-design-screens-panels` was deleted.
- Reviewed the source and fixture diff, the default/classic gates, response guards, theme changes and idle lifetimes. `git diff --check`, the configured identity guard and `scripts/secretscan 0551a0fc..HEAD` pass. No baseline, ceiling or historical screenshot changed.

Implementation commits:

| Commit | Change |
|---|---|
| `b066c20f` | Take the scoped task locally |
| `9250cc7d` | Move diff/card fixtures and comparisons to 3824 |
| `e28dd38d` | Port inline approval and find geometry; update approval/question fixtures |
| `2c838e63` | Port palette thread status, project context and subtitles |
| `fb65e4fc` | Preserve classic input-group height after the exact baseline caught the compact-field shift |

The following `test(panels): compare dialogs and panels with 3824 screens` commit adds the direct surface tests, this report and the final progress handoff. All commits stay local.
