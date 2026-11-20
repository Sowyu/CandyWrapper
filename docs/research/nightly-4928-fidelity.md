# Fidelity at Nightly 4928

Written 2026-11-19 on the Mac mini M2 Pro (task refs-4928, branch `refs-4928` from `catchup-4928` at `652c31e7`). `design/t3-source/main.css` is now 4928's `client/assets/main-Cdq43S6I.css`, the tokens are regenerated, and every component reference is recaptured with chrome-headless-shell 156.0.8078.70. No ceiling was raised and nothing was ported.

## Can this Mac reproduce the old references

Before changing anything, I regenerated all 96 specs with 3824's stylesheet and compared each PNG with the checked-in one.

- 1,784 of 1,849 PNGs came out byte-identical, after I installed KaTeX 0.16.47 under `~/CandyWrapper-research/tools/katex-0.16.47` for the math spec.
- 38 PNGs gained one or two rows or columns of empty capture margin at the bottom or right. Their overlapping pixels are identical and their `manifest.json` sizes did not change, so it is clip rounding, not drawing.
- 22 PNGs need `~/CandyWrapper-research/t3-client-assets`, which only exists on the old Mac. Those are 18 `diff` cases and `markdown/code` and `markdown/file-chips` in both themes. The specs load Shiki and Pierre's diff renderer from `file:///Users/mrm/CandyWrapper-research/t3-client-assets/*-BOiV_0uj.js`, a bundle no runtime here has.
- 5 PNGs differ in pixels. `reference-screens/project-search` differs in one text line in both themes (3,651 px, max channel delta 189). `composer-footer/cluster.bars` differs by 59 px with max delta 6 in both themes. `switch/default.mixed.focus-visible.dark` differs by 266 px with max delta 1.

Fonts and Chrome on this Mac draw the same pixels as the old Mac's, so new references are comparable. When committing 4928's references I kept the checked-in PNG for all 65 cases above wherever 4928 changed nothing else. I cropped 13 PNGs that 4928 did change back to the old size, since they had the same capture-margin growth. `diff` and `markdown/code` and `markdown/file-chips` still show 3824 and need the assets before anyone can recapture them. To get them, unpack the 4928 client bundle into `t3-client-assets` and update the paths and minified export names in `gen-diff-spec.py` and `gen-markdown-spec.py`.

## Specs at 4928 markup (task specs-4928, 2026-11-19)

Branch `specs-4928` from `catchup-4928` at `34617667`. The spec generators now hold Nightly 4928's
component markup, and every changed spec was recaptured. Earlier sections of this file describe the
state before that.

What changed:

1. `~/CandyWrapper-research/t3-client-assets` is a copy of the 4928 runtime's `client/assets`, and
   `~/CandyWrapper-research/downloads/lucide-static-0.564.0` holds lucide-static from npm, so every
   generator runs on this Mac. The diff and Markdown code cases are recaptured from 4928's bundle
   (pierre diffs 1.7.0-beta.4, the Highlights highlighter, t3-light).
2. Every class string in the spec HTML that exists only in 3824's web source now matches 4928. A
   check that compares each `class="..."` in `design/component-reference/*.json` against both source
   trees finds none left, apart from the retired meter. 35 specs and 163 PNGs were recaptured in
   `e7c4f0cd`, plus 18 diff and 16 Markdown PNGs.
3. Specs that import T3's main chunk (diff, Markdown, threadview, composer-menu, user-message) set
   `t3code:theme-appearance-mode` first. Without it main switches a dark page to light
   (useTheme.ts:162-172).
4. New: `user-message` (7 cases), `sidebar-footer` (2 cases) and `markdown/insight`.

The drift check works on whole class strings. Class lists that T3 builds with `cn()` from several
parts, and elements T3 added or removed, only show up where someone read the component. I read and
updated the components the failing cases cite. These cited files changed between the tags without
leaving a stale string in any spec, so their specs may still lag in structure: ConnectionsSettings.tsx,
UsagePage.tsx, ProposedPlanCard.tsx, ThreadRelationshipsControl.tsx (thread-lineage got only its list
class), ThreadTerminalDrawer.tsx, FilePreviewPanel.tsx, RightPanelTabs.tsx, DevicePanel.tsx and
CommandPalette.tsx.

### Retired cases

- `thread-leftovers` meter-0, meter-25, meter-95: T3 deleted ContextWindowMeter.tsx in the Labs
  cleanup (521ac7c218, #33131). The context meter now lives in the thread details card
  (ThreadDetailsUsage.tsx), which has no spec yet.
- `timeline-gaps` plan.implement-split, plan.refine: the same commit removed the plan follow-up
  actions from ComposerPrimaryActions.tsx.

The cases stay in their specs with a `retired` reason, and ThreadLeftoversFidelityTests and
TimelineGapsFidelityTests skip them.

## Fidelity at 4928 markup

`scripts/test --filter Fidelity`: FeaturesTests 85 tests in 56 suites with 64 issues, DesignSystemTests
66 tests in 11 suites with 10 issues. Every case not listed below passes. Numbers are the share of
differing pixels against the case's ceiling. A box is the diff's bounding box in 2x pixels of the
reference, which includes 16 px of capture padding on each side.

Each entry below is a real difference between CandyWrapper and T3 4928 unless it says harness.

### Dialogs (DesignSystemTests DialogsFidelity, connections, git, pull-requests, timeline-gaps)

T3 4928 sets dialog, alert dialog and sheet titles `leading-snug` instead of `leading-none`
(dialog.tsx:227, alert-dialog.tsx:127, sheet.tsx:147). The taller title line moves everything below
it, so the diff covers the whole dialog.

- `dialog` default 19.56% light, 10.61% dark; default.panel 17.38%, 13.14%; bare.panel 20.92%,
  13.48%; ceiling 9%.
- `alert-dialog` default 16.48%, 10.86%; bare 19.69%, 10.37%; ceiling 9%.
- `connections` add-dialog, add-dialog.error, add-dialog.route, add-dialog.ssh, add-dialog.ssh-error
  15.3% to 19.9%, ceiling 6.5%; create-link-dialog 15.37% light, 16.66% dark, ceilings 7% and 6.5%.
- `git` dialog.commit 10.60%, 12.43%, ceiling 6%.
- `pull-requests` link-dialog 14.03%, 13.82%, ceiling 7%.
- `timeline-gaps` plan.save-dialog 14.18%, 13.67%, ceiling 7.5%.

### Composer model and effort control (ComposerFooterFidelityTests)

The cluster cases now start at the model trigger, which carries the effort as its suffix, followed by
the permissions chip (ComposerControlsBar.tsx:168-300). CandyWrapper still draws a separate traits
block. Box 34,28 to the right edge on every case, the whole cluster.

- cluster.access-icon 8.95% light, 9.07% dark; cluster.bars 9.74%, 9.84%; cluster.both-icon 7.70%,
  7.77%; cluster.overflow-both 6.88%, 6.94%; ceiling 6%. The suite mean is above 5%.
- The harness's own fit check (`v.fit == ...`, ComposerFooterFidelityTests.swift:48) fails for all
  four, because it asks for the 3824 fits. The port agent has to rewrite this harness with the cluster.
- `overflowSkipsPermissionsOnlyState` fails too: the overflow width is 188.6 against 189.1 needed. It
  reads no component reference, so it is not caused by these specs.

### Model picker (PickersFidelityTests)

`popupsAgainstReferences` 13-model-picker 12.32% both themes, ceiling 5.5%, and its width check fails.
It compares with `design/reference-3824`, not with a component reference, so it is the composer-pickers
port against the old full-screen capture, untouched by this task.

### Settings (SettingsPages2, SettingsPages3)

- `providers.list` 33.10% light, 33.62% dark, ceiling 4.5%. Box 16,44 to 559,406, the whole list:
  4928 makes the row `relative` with the absolute select button, and the switch sits in the
  pointer-events-none action span (ProviderInstanceCard.tsx:1173-1250).
- `source-control.repositories` 10.17%, 12.99%, ceiling 4.5%. Box covers the section from y 31: the
  settings row grid's control column is `auto` now, not `minmax(10rem,auto)` (settingsLayout.tsx:538).
- `provider.environment` dark 25.26%, ceiling 11%; light passes. Each variable is now a bordered card
  with the name and remove button on one line and the value and lock on the next
  (ProviderInstanceCard.tsx:466-560).
- The other settings cases that held the old row grid (connections 8, provider-setup, settings-pages,
  settings-sweep, usage, forms section) pass with the 4928 markup.

### Context chips (ThreadViewFidelityTests)

- chip.image 23.65% light, 23.76% dark, ceiling 12%. Box 18,20 to 553,57. The 4928 image chip has no
  bubble and takes T3's runtime `--context-chip-image` (#006a99 light); CandyWrapper still draws the
  tinted bubble.
- pr.merge 11.03%, 11.20%, ceiling 10%. Box 37,28 to 487,119: the Merge pill is a faint
  `bg-black/[0.035]` pill at 4928 (ThreadDetailsControl.tsx:62-66), CandyWrapper draws it solid blue.
- The suite mean and line check fail from these two.
- The other chip cases, card.* and avatar.* pass.

### Markdown (MarkdownFidelityTests)

- insight 33.13% light, 33.53% dark, ceiling 5.5%. New case. The native render's colors are the inline
  code fill (#e4e4e5) where T3 draws the info-blue callout (ChatMarkdown.tsx:377-382, #22239), so
  CandyWrapper does not take this source, the fence as INSIGHT_OPEN_PATTERN and INSIGHT_CLOSE_PATTERN
  accept it (markdownStreamBlocks.ts:10-11), as an insight, although thread-markdown ported the callout.
  Check the native fence detection against those patterns first.
- file-chips 5.52% light, 5.69% dark, ceiling 5.5%. Spread over the chips (box 17,27 to 1284,165): the
  mention color is now T3's runtime `--context-chip-mention`.
- text, lists, quotes, table, code and rule-image pass with 4928's Highlights colors.

### Sidebar (SidebarLeftoversFidelityTests, SidebarFooterFidelityTests)

- rename.rest and rename.focus-visible 12.2% to 12.4%, ceiling 6%. Box 24,32 to 439,75: the 4928 field
  is a 1px inset ring with `-mx-1` (SidebarThreadRow.tsx:660-673), not a border.
- sidebar-footer undo.archived 8.96% light, 56.26% dark; undo.archived-many.narrow 8.99%, 53.86%;
  ceiling 6%. New cases. Harness, check first: the dark diff covers the whole box and the reference's
  most common color is #111111 where the native canvas is #000000, so `SidebarBox` and the spec's
  `var(--sidebar)` disagree on the dark sidebar color before the notice itself is compared.

### Your messages (UserMessageFidelityTests)

burst 1.40% light, 1.60% dark; file-card 0.93%, 1.01%; model-switch 1.90%, 1.92%; ceiling 6%. All pass.
media.above-text, media.image-only, media.collage and quote-card have references but no native harness,
because the native row loads images through the thread's image model.

## Results after look-4928 (2026-11-19)

Branch `look-4928` off `catchup-4928`. `scripts/test --filter 'Fidelity|RedesignBaselineTests'` ran on the base
commit and on the branch. Failing case-themes per surface, before and after:

| Surface | Before | After |
|---|---|---|
| Dialogs (dialog, alert dialog, connections, git commit, PR link, plan save) | 21 | 0 |
| Composer cluster and `overflowSkipsPermissionsOnlyState` | 8 and the check | 0 |
| Model picker (13-model-picker against reference-3824) | 2 | 2 |
| Sidebar rename | 4 | 0 |
| Sidebar footer undo notice | 4 | 0 |
| Insight callout | 2 | 0 |
| Image chip, PR Merge pill, file chips | 6 | 0 |
| Settings (left to the settings agent) | 5 | 5 |
| Panel screen 22-commit-dialog against reference-3824 | 0 | 2 |

What changed:

- Dialog, alert dialog and sheet titles draw a 27.5pt `leading-snug` line in the default themes (dialog.tsx:227).
- The 4928 model trigger keeps `px-2` after its effort suffix, which moved the permissions chip 4pt. The cluster
  harness draws the whole cluster from the model trigger. The spec's `text-xs!` collapsed trigger is mobile only, so
  `both-icon` and `overflow-both` now hold the desktop's overflow state with the model shrunk to 96 and 156.5px.
- The rename harness placed the field 4pt right of the spec's `-mx-1` input. The native field already drew the ring.
- The undo notice spec drew outside `data-app-sidebar`, so its colors were the page's. Both texts now sit flush right.
- The insight harness skipped the assistant row's rewrite. CandyWrapper detected both fence forms already; it now
  also leaves list items alone, as T3's parsed ranges do, and runs T3's own cases.
- Chips take T3's solved `--context-chip-*` accents for the standard themes (themePalette.ts:736-772), the image chip
  lost its bubble and the Merge action is the faint `bg-black/[0.035]` pill.
- New native tests: media.above-text, media.image-only, media.collage and quote-card. The quote card had a real bug:
  its context lost the spaces around the marked words and the mark started at the line's end.
- New references and tests: `sidebar-leftovers` title-glimmer and issue-badge, and the `viewed-images` row.

Still failing:

- 13-model-picker, 12.32% both themes. Its reference is the 3824 full-screen capture, while CandyWrapper draws the 4928
  docked picker. The screens-4928 task is recapturing it as a real 4928 screen (its worktree holds
  `design/reference-4928/13-model-picker.*.png`) and is editing PickersFidelityTests, so no spec was written here.
- 22-commit-dialog in PanelScreensFidelityTests, 7.16% light and 9.94% dark against a 6% ceiling. It crops the 3824
  full-screen capture, whose dialog title is `leading-none`; 4928's `leading-snug` title is the change above. The
  screens-4928 task holds a 4928 capture of it.

Redesign: RedesignBaselineTests reports the same 20 differing images with the same pixel counts on the base commit
and on the branch.

## Shapes still without a reference

Done in look-4928 except the docked model picker (see above). These were asked for and were not done by specs-4928. Each needs more of T3's markup than this task had room for.

1. The docked model picker with its effort column and footer (ModelPickerContent.tsx:473,
   ComposerModelEffort.tsx:525-560 for the column, ComposerPickerFooter for the footer).
2. The title glimmer's resting state and the issue badge on a sidebar row. Both live inside
   SidebarThreadRow.tsx (glimmer :1110 and :1923 through ActivityShimmerOverlay, issue badge
   :1135-1160), and no spec holds a 4928 sidebar row to put them in.
3. The viewed-images row (TimelineWorkEntryRow.tsx ViewedImagesTimelineRow through
   ChatMarkdownAssetImage and ChatMarkdownImage in ChatMarkdownMedia.tsx).
The current full-screen set the tests read is `design/reference-3824`. Its README says headless chrome-headless-shell captured it from the 3824 web client against a seeded sandbox copy, so it needs no window. These are the gaps on this Mac:

1. A seeded 4928 sandbox. `sandbox-3824-ref` with its Markdown, commands, question, approval and changed-files threads and `demo-repo` stayed on the old Mac. Without it, `scripts/sandbox-server` with the 4928 runtime gives an empty home, and the seed plans cost about six Claude Haiku 5.5 turns, which needs the user's approval. Copying `sandbox-3824-ref` over from the old Mac avoids most of them.
2. The capture tool. `design/reference-3824/plans/capture-reference-extended.swift` still looks for Chrome only under `~/.t3/tools`, so it needs the same `findChrome()` as `scripts/capture-reference.swift`.
3. Plans for 4928. `plans/gen.py` selects the 3824 composer, so states 13, 41, 42 and 53 need the combined model and effort control's selectors. Section 1 of the diff doc also adds states worth capturing: a burst, an image message, a file card and the switch row.
4. Pairing. `run.sh` mints a pairing URL with `env -i <runtime> auth pairing create --base-dir <copy>/t3home`, which works with the 4928 runtime in `~/CandyWrapper-research/runtimes`.
5. Review. Each PNG has to be looked at before it replaces the 3824 one, so plan for the user's review time.

Captures from the desktop app on a real screen instead need the screen lock, the official Nightly app and screencapture, so they wait until the user frees the screen.

## Full-screen tests against reference-4928

Rewritten 2026-11-19 (task screens-port). Each line gives the share of differing pixels, then the ceiling, at three points: before alignment (the screens-4928 run), after the fixtures took the 4928 sandbox's data, and after the ports on branch `screens-port`. No ceiling was raised and no case was removed.

### Where the data comes from

- The markdown, commands and notes threads are recorded from `sandbox-4928-ref` through `orchestration.subscribeThread` into `fixtures/transcripts/4928-screen-threads.jsonl`. The notes thread's collapsed work rows held the repo's old path under the home folder, and the transcript rewrites it to `/Users/Shared/cw-sandbox-4928/demo-repo`.
- `fixtures/4928-panel.patch` is `git diff` of that repo, the notes thread's two one-line edits.
- The sidebar's snoozed and settled threads and the branch per row come from the sandbox's shell snapshot.
- Palette rows, ages, approval command, questions, commit files, provider versions and the archived thread come from the page text the capture run saved per state. The diagnostics counters come from the PNGs, because that text was read a moment after the screenshot.
- The screen pickers decode `26-nightly-4928`'s server config, which lists Fable 5.2 as the 4928 picker does.

Failing ceiling cases went from 61 to 36 after alignment and to 35 after the ports. The two DesignSystemTests sidebar checks pass after alignment: their sample rects moved to the 4928 gutter (y 620 px) and the open row (y 1320 px).

The sandbox server was stopped at 17:21 after the captures, and its restart marked the input and approval threads' requests cancelled with a "Server shut down" notice. The fixtures don't read those two threads, but a later capture of 05 or 06 needs them seeded again.

### Thread, `ThreadFidelityTests` wholePanel, ceiling 5.5%

All pass.

- `03a-kitchen-sink-top` light 8.33 → 1.72 → 1.72, dark 17.51 → 1.80 → 1.80
- `03b-kitchen-sink-middle` light 6.12 → 5.19 → 1.10, dark 15.30 → 5.77 → 1.22. The task items of a loose list had lost their paragraph margins (fabe84dd).
- `03c-kitchen-sink-bottom` light 5.65 → 2.84 → 4.01, dark 6.30 → 2.61 → 2.45. Light rose with the loose-list fix: its diff outlines every glyph and box from the list down (y 38 to 1144 px), a sub-point vertical offset at the end of the scroll range, not a missing surface.
- `03d-kitchen-sink-commands` light 8.61 → 1.98 → 1.98, dark 8.65 → 1.97 → 1.97. Still visible: T3 breaks `ls /nonexistent-dir` after `ls`, and AppKit breaks after the slash (Markdown inline code, UAX 14 LB13).

### Narrow, `ReferenceScreensFidelityTests`, ceiling 5.5%

- `03n-narrow` light 7.36 → 5.36 → 1.67, dark 18.44 → 5.28 → 1.79

### Diff and changed files, ceilings 8.5% and 7.5%

All pass on the ceilings.

- `09-diff-split` light 23.67 → 2.04, dark 24.17 → 2.05
- `10-diff-unified` light 20.38 → 1.48, dark 20.52 → 1.48
- `47-changed-files-card.main` dark 14.23 → 1.87 → 1.86
- `48-diff-turn-file.chat` light 19.45 → 4.19 → 4.16, dark 25.05 → 3.94 → 3.91. "Worked for 4.0s" now reads "4s" (33a1a21a).
- `48-diff-turn-file.panel` light 13.35 → 0.56, dark 13.32 → 0.53

`cardAndDiff` still fails one expectation: the card can't reach T3's top of 409.25pt in 48, because the timeline stops scrolling with it at 408.5pt. Above the card, the "Worked for" row of a turn with tools sits 1pt higher under the user message than in T3 (03d shows the same 2 px), while 03a's tool-free turn matches. I didn't find the cause. thread-4 (2026-11-19) narrowed it with pixel columns of the references: the bubble's edges match to the pixel, and the fold's rule sits 0.75pt lower in T3 (632 px against 630.5 at 2x in 48, 450 against 448.5 in 47) with its label 0.375pt lower, so T3's label row measures 23.5pt where TurnFoldTimelineRow's classes add up to 22.75 (`pt-1`, `text-sm leading-relaxed`, `pb-2`, `border-b`, MessagesTimeline.tsx:1866-1890 at 4928; the timestamp is `absolute`, TimelineRowParts.tsx:30-35). Making the row 23.5 brought 47 to 1.03%, 48's chat to 2.70 to 3.20% and 03c and 03d down, and cardAndDiff passes, but 03a went from 1.72 to 3.13% and 03b from 1.10 to 3.27%, so the extra 0.75 is not on every fold. The next step is a DOM measurement of the fold rows in 03a and 48 with the capture tool to see which box differs.

### Panels and dialogs, `PanelScreensFidelityTests` and `PanelsFidelityTests`

- `05-approval-request` light 14.16 → 11.82 → 4.80, dark 14.23 → 12.07 → 4.89, ceiling 4%. Still failing. The command now breaks only at spaces as T3's does, with T3's line positions and the font smoothing setting (b3b8eb92). The rows line up at whole pixels, and the per-band means match within 1%. What remains is glyph placement inside the mono text, drifting up to a pixel by the line's end (diff box x 16 to 1232, y 9 to 111 px, spread over all three lines).
- `22-commit-dialog` light 6.73 → 6.72 → 6.72, dark 7.53 → 7.53 → 7.52, ceiling 6%. Still failing. The description under the title starts 2pt higher than T3's and everything below follows it (diff over the whole crop, 0 to 1135 px). That is the dialogs' shared title style, which the look-4928 agent owns. The total now reads `+2/-0` (8f2060cd).
- `08-palette-search` light 20.96 → 5.30, dark 11.68 → 5.44, ceiling 6.5%. The palette ends at 326pt with four matches.
- `45-go-to-file` light 17.06 → 2.49, dark 20.40 → 2.53. The palette ends at 278pt with three files, first row highlighted.
- `46-project-search` dark 9.35 → 0.86
- `06-user-input-request` light 5.63 → 2.64, dark 5.75 → 2.79, ceiling 4%

### Sidebar, `SidebarFidelityTests` wholeSidebar, ceiling 11%

Left for look-4928. The data matches now, and the difference is the 4928 row and header design.

- `list` light 12.36 → 12.63, dark 22.03 → 13.52. Each 4928 row puts the project line above the title and the branch under it.
- `below the art` light 14.26 → 14.51, dark 22.39 → 14.61. Same rows, below the header art.

### Composer pickers and composer

Left for look-4928.

- `41-traits-picker` light 29.73, dark 24.77, and `53-effort-menu-permissions` the same, ceiling 5.5%. Both render the 3824 effort popup into the 3824 rect, while 4928 shows the docked picker (models, Reasoning column, footer) as in 13.
- `13-model-picker` light 6.65, dark 6.63. The docked popup is 362x283 in T3 and 362x267 here.
- `03c-footer-controls` light 21.43, dark 21.45. The closed control is one "Haiku 5.5 Medium" trigger at 4928.
- `54-composer-effort-bars` dark 13.33 → 14.35 → 13.83, ceiling 11.5%. Diff spread over the composer band (x 110 to 1577 px).

### Settings, `SettingsScreensFidelityTests`, ceiling 5%

All 18 failing cases pass after task settings-2 (2026-11-19), with no ceiling raised. Numbers are before, then after.

- `16a` 6.55/7.13 → 1.66/1.68, and `49` the same. `16b` 8.50/9.25 → 3.43/3.53 and `16c` 6.21/7.12 → 1.70/1.71, after General gained Terminal close confirmation and Language.
- `18-settings-providers` light 7.53 → 1.95, dark 14.02 → 1.97. The 4928 capture scrolls to 0.45 of a taller page, so the fixture scrolls to 701.5pt, not 3824's 665.5pt.
- `19-settings-keybindings` 5.23/5.31 → 4.39/4.47. `32-settings-source-control` 6.13/6.74 → 3.28/3.31.
- `39-settings-diagnostics` 5.71/42.80 → 4.34/4.31: the footprint draws inside the section card, and Host & collection follows it.
- `40-settings-integrations` 5.81/6.28 → 4.81/4.93.

What changed: Voice in the nav and "Source control & issues"; the row's control column is `auto` with `min-w-40` only for selects; descriptions wrap `text-pretty` (greedy, no one-word last line) instead of balanced; clamped text ends like Blink's line-clamp. The component cases pass too: providers.list 33.10/33.62 → 2.11/2.67 (the selected row fills with foreground/6%), source-control.repositories 10.17/12.99 → 4.18/4.50, provider.environment dark 25.26 → 2.48 (light 8.68 → 2.76) (each variable is a bordered card).

### Inventory sections

No failing screen led into 1.7 (subagents) or 5.2 (pull requests), and the diff screens pass, so no row of 5.1 was ported. Rows ported here: orchestrationTiming.ts formatDuration (33a1a21a).

## Results after sidebar-2 (2026-11-19)

Every case below was failing at the start of the task. No ceiling moved and no reference was recaptured.

- Sidebar `wholeSidebar` list 12.63% to 3.94% light, 13.52% to 4.24% dark; below the art 14.51% to 6.57%, 14.61% to 6.13%. The cause was not the row design. T3 scrolls the open row's card into view on mount (routeReveal.ts:36-66), which moved its list up 7pt, and the 02 fixture sorted two rows by age where T3 sorts by `createdAt`.
- Pickers `13-model-picker` 6.65/6.63% to 1.16/1.17%, `41-traits-picker` and `53-effort-menu-permissions` 29.73/24.81% to 1.15/1.17%. All three are T3's docked picker, 554x393pt at (407, 324), which the cases now render. The effort column takes `border-l` and `bg-foreground/[0.09]` rows.
- `03c-footer-controls` 20.90/20.91% to 4.61/4.75%: the single trigger at its 4928 x, 802.07.
- `54-composer-effort-bars` 4.49/13.82% to 1.65/1.61%: T3's capture sits at the thread's end.
- `22-commit-dialog` 7.16/8.67% to 1.41/1.40%: the case cropped the 3824 dialog's 568pt box, and the 4928 dialog is 576.5pt tall.
- Still failing: `05-approval-request` 4.80/4.89% against 4%. Glyph positions match T3's to the pixel and the ink means match, so the rest is Chrome's rasterizer against CoreText. `cardAndDiff` in 48 still lands the card 0.75pt short, as above.
