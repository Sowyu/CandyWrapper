# Fidelity at Nightly 4928

Written 2026-11-19 on the Mac mini M2 Pro (task refs-4928, branch `refs-4928` from `catchup-4928` at `652c31e7`). `design/t3-source/main.css` is now 4928's `client/assets/main-Cdq43S6I.css`, the tokens are regenerated, and every component reference is recaptured with chrome-headless-shell 156.0.8078.70. No ceiling was raised and nothing was ported.

## Can this Mac reproduce the old references

Before changing anything, I regenerated all 96 specs with 3824's stylesheet and compared each PNG with the checked-in one.

- 1,784 of 1,849 PNGs came out byte-identical, after I installed KaTeX 0.16.47 under `~/CandyWrapper-research/tools/katex-0.16.47` for the math spec.
- 38 PNGs gained one or two rows or columns of empty capture margin at the bottom or right. Their overlapping pixels are identical and their `manifest.json` sizes did not change, so it is clip rounding, not drawing.
- 22 PNGs need `~/CandyWrapper-research/t3-client-assets`, which only exists on the old Mac. Those are 18 `diff` cases and `markdown/code` and `markdown/file-chips` in both themes. The specs load Shiki and Pierre's diff renderer from `file:///Users/mrm/CandyWrapper-research/t3-client-assets/*-BOiV_0uj.js`, a bundle no runtime here has.
- 5 PNGs differ in pixels. `reference-screens/project-search` differs in one text line in both themes (3,651 px, max channel delta 189). `composer-footer/cluster.bars` differs by 59 px with max delta 6 in both themes. `switch/default.mixed.focus-visible.dark` differs by 266 px with max delta 1.

Fonts and Chrome on this Mac draw the same pixels as the old Mac's, so new references are comparable. When committing 4928's references I kept the checked-in PNG for all 65 cases above wherever 4928 changed nothing else. I cropped 13 PNGs that 4928 did change back to the old size, since they had the same capture-margin growth. `diff` and `markdown/code` and `markdown/file-chips` still show 3824 and need the assets before anyone can recapture them. To get them, unpack the 4928 client bundle into `t3-client-assets` and update the paths and minified export names in `gen-diff-spec.py` and `gen-markdown-spec.py`.

## Most failures are markup changes, not stylesheet changes

Every failing case uses Tailwind utilities that 3824's stylesheet compiled and 4928's no longer has, because T3 changed those components' class lists. The spec HTML in `scripts/gen-*-spec.py` is still 3824's markup, so these references show 3824 markup drawn with 4928's CSS, which matches neither version. A port agent has to bring the generator's markup to 4928's TSX first, then rerun `scripts/component-reference` for that spec, and only then port CandyWrapper against the new reference.

40 cases in 16 specs use such classes. Only the 26 below fail, so the other 14 also need fresh markup even though they pass now: connections 8, provider-setup 2, settings-pages3 2, settings-sweep 1 and usage 1 (all the settings row grid), composer-menu 1 and markdown 1 (context chip), sidebar-search 2 (`max-w-[min(18rem,var(--available-width))]`) and threadview 4 more chips.

The baseline run on `652c31e7` with 3824's references passed all fidelity suites: 83 tests in 54 FeaturesTests suites and 66 tests in 11 DesignSystemTests suites. So every failure below comes from 4928.

## Failing cases by surface

The numbers are the share of pixels that differ, then the case's ceiling.

### Composer model and effort control

`ComposerFooterFidelityTests`, 6 cases, and the suite mean rose to 5.33% against its 5% limit. T3 4928 dropped `ps-0`, `ps-0.5` and `data-pressed:bg-transparent` from the cluster. This is the branch composer-pickers surface, section 2.1 of `nightly-diff-4928.md`.

- `cluster.access-icon` light 9.15%, dark 9.22%, ceiling 6%
- `cluster.both-icon` light 7.38%, dark 7.41%, ceiling 6%
- `cluster.bars` light 11.56%, dark 11.55%, ceiling 6%

### Settings rows

8 cases. The settings row grid changed at `apps/web/src/components/settings/settingsLayout.tsx:538` (4928): `grid-cols-[minmax(0,1fr)_minmax(10rem,auto)]` and the section's `[&>*+*]:border-t` divider classes are gone. The new references are up to 120 CSS px taller, because the old markup no longer lays out as a grid.

- `FormsFidelityTests` (DesignSystemTests) `section.one-row` dark 5.04%, ceiling 3.5%
- `FormsFidelityTests` `section.three-rows` light 3.95%, dark 5.42%, ceiling 3.5%
- `SettingsPagesFidelityTests` `general.notifications` light 5.98%, dark 10.13%, ceiling 5%
- `SettingsPages2FidelityTests` `project.overview` dark 9.07%, ceiling 4.5%
- `SettingsPages2FidelityTests` `source-control.repositories` light 8.12%, dark 14.51%, ceiling 4.5%

### Context window meter

`ThreadLeftoversFidelityTests` `threadControls`, 6 cases, ceiling 6.5%. `stroke-muted-foreground/24` is gone from the meter's track. This is section 1.4 of the diff doc.

- `meter-0` light 7.18%, dark 7.28%
- `meter-25` light 7.33%, dark 7.41%
- `meter-95` light 7.89%, dark 7.90%

### Context chips

`ThreadViewFidelityTests`, 2 cases, and the suite mean rose to 6.29% against 5%, with the per-case line check failing too. `ContextChip.tsx:9-48` (4928) rewrote the accent and ink variables, and `bg-(--context-chip-accent)/10` and `border-(--context-chip-accent)/30` are gone.

- `chip.image` light 22.66%, dark 22.81%, ceiling 12%

### Plan card split button

`TimelineGapsFidelityTests`, 2 cases, ceiling 7.5%, and its line check fails. `rounded-l-none`, `rounded-r-none` and `border-message-action-foreground/20` are gone from the implement split button.

- `plan.implement-split` light 8.17%, dark 8.12%

### Sidebar rename field

`SidebarLeftoversFidelityTests`, 2 cases, ceiling 6%. `focus:border-foreground` is gone from the rename input. The sidebar-4928 branch touched the rename field in `0166b1ef`, so check it there first.

- `rename.focus-visible` light 6.02%, dark 6.70%

## References that changed and still pass

83 PNGs changed (the commit message of `3f9c5675` says 68, which is wrong): composer-footer 6, composer-menu 2, connections 14, markdown 3, provider-setup 6, scroll-area 6, settings 4, settings-pages 4, settings-pages2 8, settings-pages3 2, settings-sweep 2, sidebar-leftovers 2, thread-completion 4, thread-leftovers 6, threadview 8, timeline-gaps 2 and usage 4. The scroll-area ones are the new dark scrollbar thumb (`--app-scrollbar-thumb` went from `#ffffff14` to `#ffffff5c`, #30031). The rest are mostly the markup mismatch above.

## Port-branch shapes without a reference

The gen-*-spec.py flow has no case for the user message itself. `threadview`'s `chip.*` cases cover only the Markdown inside a sent message, and `timeline-gaps`' `attachment.sent` is the attachment preview panel. So I added no spec cases for the merged thread shapes. These shapes have no reference of any kind:

1. Back-to-back message bursts: joined corners, one Steer label, and the time and buttons floating beside the bubble on wide lanes (`TimelineUserMessageRow.tsx:270`, `MessagesTimeline.logic.ts:645`).
2. Images and videos above the bubble, a lone image with no bubble, and the collage (#27306, #38558).
3. File cards for files sent without text (`UserFileCard`, `TimelineUserMessageRow.tsx:109`), plus the pasted text, snapshot and sending shapes (#27377).
4. The quote inset card (`AssistantCitationChip.tsx:117`).
5. The model and effort switch row (`V2LifecycleRow.tsx:643`).

The composer's combined model and effort control (branch composer-pickers) has `composer-footer` cases, but they hold 3824's markup and now fail as listed above. Sidebar rows (branch sidebar-4928, merged into `catchup-4928` after this branch started) have `sidebar` spec cases that pass, but they also hold 3824's markup. Both need 4928 markup in their generators before they say anything about 4928. A new `gen-user-message-spec.py` with a native harness in a new `UserMessageFidelityTests` is the way to cover items 1 to 5.

## Capturing the full-screen references at 4928

The current full-screen set the tests read is `design/reference-3824`. Its README says headless chrome-headless-shell captured it from the 3824 web client against a seeded sandbox copy, so it needs no window. These are the gaps on this Mac:

1. A seeded 4928 sandbox. `sandbox-3824-ref` with its Markdown, commands, question, approval and changed-files threads and `demo-repo` stayed on the old Mac. Without it, `scripts/sandbox-server` with the 4928 runtime gives an empty home, and the seed plans cost about six Claude Haiku 5.5 turns, which needs the user's approval. Copying `sandbox-3824-ref` over from the old Mac avoids most of them.
2. The capture tool. `design/reference-3824/plans/capture-reference-extended.swift` still looks for Chrome only under `~/.t3/tools`, so it needs the same `findChrome()` as `scripts/capture-reference.swift`.
3. Plans for 4928. `plans/gen.py` selects the 3824 composer, so states 13, 41, 42 and 53 need the combined model and effort control's selectors. Section 1 of the diff doc also adds states worth capturing: a burst, an image message, a file card and the switch row.
4. Pairing. `run.sh` mints a pairing URL with `env -i <runtime> auth pairing create --base-dir <copy>/t3home`, which works with the 4928 runtime in `~/CandyWrapper-research/runtimes`.
5. Review. Each PNG has to be looked at before it replaces the 3824 one, so plan for the user's review time.

Captures from the desktop app on a real screen instead need the screen lock, the official Nightly app and screencapture, so they wait until the user frees the screen.

## Full-screen tests against reference-4928

Written 2026-11-19 (task screens-4928). `design/reference-4928` now holds the full-screen set, captured from 4928's web client against a sandbox seeded from scratch (its README has the details). Every test that read `design/reference-3824` reads `design/reference-4928`. No ceiling was raised and no app code changed. The test fixtures changed in two places to match the new seed: `fixtures/screen-4928-markdown.md` holds the new Markdown reply, and `Screen3824Fixtures.sidebar` lists the new sidebar rows. Every other fixture still draws 3824's seed data, such as the diff's file list, the palette results and the approval text, so some failures below mix data with real UI changes.

I ran `scripts/test --filter` with QueueFidelityTests, ChangedFilesFidelityTests, PickersFidelityTests, ComposerFidelityTests, SettingsScreensFidelityTests, SidebarFidelityTests (both modules), PanelsFidelityTests, ThreadFidelityTests, ReferenceScreensFidelityTests, DiffFidelityTests and PanelScreensFidelityTests. Only QueueFidelityTests passes. The other 10 suites fail on 65 cases, and the DesignSystemTests sidebar fails 2 sampled checks. The numbers are the share of pixels that differ, then the ceiling.

### Thread, `ThreadFidelityTests` wholePanel, 8 cases

The text matches the new fixture. The dark panel differs most.

- `03a-kitchen-sink-top` light 8.33%, dark 17.51%, ceiling 5.5%
- `03b-kitchen-sink-middle` light 6.12%, dark 15.30%
- `03c-kitchen-sink-bottom` light 5.65%, dark 6.30%
- `03d-kitchen-sink-commands` light 8.61%, dark 8.65%

### Sidebar, 4 cases and 2 checks

4928's default theme draws art behind the sidebar header, and each row puts the project line above the title.

- `SidebarFidelityTests` wholeSidebar `list` light 12.36%, dark 22.03%, ceiling 11%
- `SidebarFidelityTests` wholeSidebar `below the art` light 14.26%, dark 22.39%, ceiling 11%
- DesignSystemTests `sidebarGrainAgainstCapture`: the mean differs by 25.7 (light) and 27.6 (dark) against 1.0, and the deviation by 65.6 and 70.1 against 0.5. Its sample rect now lands on the header art.
- DesignSystemTests `selectedRowFillAgainstCapture`: the mean differs by 24.0 and 26.0 against 1.5. The selected markdown row moved to the bottom of the list.

### Composer pickers, `PickersFidelityTests`, 8 cases

At 4928, 13, 41 and 53 show one docked picker (models, effort column, footer). CandyWrapper still draws 41 and 53 as the 3824 effort popup.

- `41-traits-picker` light 29.73%, dark 24.77%, ceiling 5.5%
- `53-effort-menu-permissions` light 29.73%, dark 24.77%
- `03c-footer-controls` light 21.43%, dark 21.45%
- `13-model-picker` light 6.64%, dark 6.62%. The popup is 362x283 in T3 and 362x267 here.
- `ComposerFidelityTests` `54-composer-effort-bars` dark 13.33%, ceiling 11.5%

### Settings, `SettingsScreensFidelityTests`, 22 cases, ceiling 5%

4928 adds settings sections to the sidebar and changes the row grid (see "Settings rows" above).

- `16a-settings-general` light 6.55%, dark 7.13%
- `16b-settings-general-mid` light 8.50%, dark 9.25%
- `16c-settings-general-bottom` light 6.21%, dark 7.12%
- `18-settings-providers` light 7.53%, dark 14.01%
- `19-settings-keybindings` light 5.23%, dark 5.31%
- `32-settings-source-control` light 6.13%, dark 6.74%
- `39-settings-diagnostics` light 6.10%, dark 43.03%. The counters are live, and the dark capture's first card differs most.
- `40-settings-integrations` light 5.81%, dark 6.28%
- `49-settings-modal-general` light 6.55%, dark 7.13%

### Panels and dialogs, `PanelScreensFidelityTests` 9 cases and `PanelsFidelityTests` 2 cases

The fixtures still hold 3824's approval command, palette results and commit file list. Compare the data before reading these as UI changes.

- `05-approval-request` light 14.16%, dark 14.23%, ceiling 4%
- `22-commit-dialog` light 6.73%, dark 7.53%, ceiling 6%
- `08-palette-search` light 20.96%, dark 11.68%, ceiling 6.5%
- `45-go-to-file` light 17.06%, dark 20.40%, ceiling 6.5%
- `46-project-search` dark 9.35%, ceiling 6.5%
- `06-user-input-request` light 5.63%, dark 5.75%, ceiling 4%

### Diff and changed files, `DiffFidelityTests` 4 cases and `ChangedFilesFidelityTests` 5 cases

The diff fixture is 3824's two-file patch with +3 each. The new seed changes one line in each file.

- `09-diff-split` light 23.67%, dark 24.17%, ceiling 8.5%
- `10-diff-unified` light 20.38%, dark 20.52%, ceiling 8.5%
- `47-changed-files-card.main` dark 14.23%, ceiling 7.5%
- `48-diff-turn-file.chat` light 19.45%, dark 25.05%, ceiling 7.5%
- `48-diff-turn-file.panel` light 13.35%, dark 13.32%, ceiling 7.5%

### Narrow, `ReferenceScreensFidelityTests`, 2 cases

- `03n-narrow` light 7.36%, dark 18.44%, ceiling 5.5%

### Next step

Before porting from these numbers, bring the remaining fixtures to the 4928 seed: the diff patch from the notes thread, the approval command under `/Users/Shared/cw-sandbox-4928/demo-repo`, the palette thread names and the commit dialog's files. The sandbox stays seeded for that, and the IDs are in `design/reference-4928/plans/sandbox-ids.json`. Then whatever still fails is a real 4928 difference. The dark thread panel and the sidebar header art look like the largest real differences.
