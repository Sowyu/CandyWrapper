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
