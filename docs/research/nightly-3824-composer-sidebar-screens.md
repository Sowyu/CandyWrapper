# Nightly 3824 composer and sidebar screens

Task: `design-screens-composer-sidebar`, based on `e3acefd1`. Local commits only.

## Changes and source

All source citations below refer to `v0.1.4-nightly.20261028.3824` in the read-only T3 checkout.

- Composer 01, 03a, 04 and 04n use `design/reference-3824/` and actual native pickers. The 600...780 composer bands and full 780pt draft crops stay unchanged. New 54 uses the same composer band, sets the real `effortDisplay=bars` preference, asserts four bars with two filled, and restores the preference afterward. T3: `apps/web/src/components/chat/TraitsPicker.tsx:618-683` and `EffortGlyph.tsx:17-38,52-84`.
- Model-picker provider tabs omit repeated provider lines. Favorites, search results, subproviders and the legacy expander retain two lines. The picker measures these rows separately and updates reused rows when the tab changes. T3: `apps/web/src/components/chat/ModelPickerContent.tsx:165-169,578-605,825-833`, `ModelListRow.tsx:53-85`, and `apps/web/src/components/ui/combobox.tsx:195`.
- Effort bars and Fast glyphs now opt into AppKit drawing instead of inheriting `DSView`'s layer-update mode. Bars use the normal control foreground; words retain the muted foreground (`TraitsPicker.tsx:653-658`).
- The effort control's negative leading margin now reduces its measured flow width by 4px as well as moving its drawing. Default controls preserve fractional CSS positions; Glass and Redesign retain their existing layout. T3: `apps/web/src/components/chat/TraitsPicker.tsx:653-655` and `ChatComposer.tsx:3439-3445`.
- Screens 41 and 53 compare the combined effort/permissions popup. The old default-theme 42 standalone select is retired and its comment points at 53. The 3824 capture plan also opens the combined popup for 42. T3: `apps/web/src/components/chat/ComposerControlsBar.tsx:153-190` and `ComposerFooterControls.tsx:156-240`. The non-default permissions chip remains available.
- Popup crops follow their new border boxes: model `(578,434,362,283)`, combined menu `(699,382,298,335)`, in CSS points. The isolated 03c cluster uses the official sandbox's measured fractional anchor, recorded in `fixtures/screen-3824-composer-geometry.json`. Full composer cases still exercise `PickerControlsView` layout. Core Text measures the model label about 0.14pt wider than Chromium; stretching the isolated controls to the rounded crop had introduced a further offset. The tight 5% assertion remains unchanged. Dark still differs by about 5.18%, so that assertion remains failing.
- Queue 29 retains its 520...780 crop. The queue now sits above that band, so an additional `(256,266,844,160)` crop checks both actual bubbles and Send now actions. T3 mounts the queue in the timeline footer at `apps/web/src/components/ChatView.tsx:2948-2963`.
- Sidebar 02 keeps the original 256x780 crop and all existing horizontal bands. Its fixture matches the new titles and states. Dark 02 was captured before the last story thread and has nine visible threads; light has ten. New 31 checks the collapsed sidebar's full 1100x52 header using the web titlebar inset, crops away the native traffic-light inset and reflects the open details toggle. It also enforces the existing screen suite's 5% direct limit. T3: `apps/web/src/workspaceTitlebar.ts:1-2` and `components/sidebar/SidebarThreadRow.tsx:943-956`.
- The sidebar grain and selected-row statistics keep their sample sizes and limits. Their source coordinates follow the new rows: grain `(20,716,300,20)` device pixels, selected light `(60,1376,320,24)`, selected dark `(60,1244,320,24)`. The old locations now include text or an unselected row, so they no longer sample the intended surface.
- The Markdown reply is copied from the isolated reference sandbox and scrubbed into `fixtures/screen-3824-markdown.md`. The 3814 provider transcript supplies the catalog used by the copied 3824 sandbox, including the default draft label `6 Astra Medium`.

No settings modal, thread timeline, right-panel implementation, old screen reference directory, ceiling or tolerance changed.

## Per-case results

Values are differing pixels over the existing 8/255 channel tolerance, shown as light / dark. Before uses the original 3669 screen references on the starting integration commit; after uses 3824, so fixture/content changes are part of the migration.

| Screen or crop | Before, 3669 | After, 3824 |
|---|---|---|
| 01-running-turn | 10.51% / 20.34% | 0.90% / 0.88% |
| 03a-kitchen-sink-top | 12.84% / 13.14% | 4.73% / 4.94% |
| 04-new-thread-draft | 4.22% / 15.45% | 3.01% / 6.12% |
| 04n-new-thread-narrow | 5.43% / 15.96% | 4.04% / 8.47% |
| 54-composer-effort-bars | new / new | 3.00% / 3.27% |
| 13-model-picker | 12.55% / 12.70% | 1.44% / 1.46% |
| 41-traits-picker | 4.65% / 3.72% | 2.38% / 2.43% |
| 42-access-mode-picker | 4.37% / 5.56% | retired, see 53 |
| 53-effort-menu-permissions | new / new | 2.38% / 2.43% |
| 03c-footer-controls | 21.13% / 21.55% | 4.87% / 5.18% |
| 29-queued-messages | 8.88% / 39.54% | 1.30% / 1.28% |
| 29-queued-bubbles | new / new | 3.22% / 3.24% |
| 31-sidebar-collapsed | new / new | 1.92% / 2.04% |

The first 3824 comparison for new 54 was 3.74% / 29.10%; the matching Markdown fixture and footer layout bring it to the final values above. New 53 starts and finishes at 2.38% / 2.43%.

| Sidebar 02 asserted band | Before, light / dark | After, light / dark |
|---|---|---|
| First card | 8.64% / 8.15% | 3.79% / 5.27% |
| List | 14.60% / 31.90% | 4.82% / 7.52% |
| Footer | 2.95% / 3.41% | 2.08% / 2.09% |
| Below the art | 16.28% / 31.41% | 7.28% / 9.02% |

All four bands retain the 11% ceiling. The pre-existing exclusion of CandyWrapper's own branded header art remains; raw whole-image differences are 16.64% / 18.21% after migration. No new band exclusion was added.

Grain after: reference/native mean 248.79/248.80 light and 3.28/3.26 dark; standard deviation 0.62/0.62 and 0.93/0.93. Selected-row mean: 254.91/255.00 light and 29.90/29.50 dark. All original scalar limits pass.

## Retired footer state

`cluster.overflow-access.rest.light/dark` cannot occur at any width in 3824. The compact permissions chip is 32 CSS px and the overflow button is 34px. Replacing one with the other makes the row wider. T3: `apps/web/src/components/chat/ComposerFooterControls.tsx:111-116`, `ComposerControl.tsx:12-19`, and `apps/web/src/components/composerFooterLayout.ts:53-75,109-117`.

The native Haiku fixture measures 146.1903pt with both trailing blocks icon-only and 148.1903pt with only permissions hidden. At 145.6903pt it moves both blocks into overflow. The new geometry assertion checks this relationship in both appearances. The generator, spec and manifest retire only the two unreachable images. The other fourteen footer images retain their 6% ceiling and 5% mean limit.

## Footer pixel cases

Values are light / dark. The retired pair passed pixels before but failed its impossible fit-state assertion.

| Case | Before | After |
|---|---|---|
| cluster.access-icon | 4.79% / 4.90% | 4.79% / 4.90% |
| cluster.both-icon | 4.02% / 4.04% | 4.02% / 4.04% |
| cluster.bars | 5.17% / 5.41% | 4.09% / 4.33% |
| cluster.overflow-both | 1.28% / 1.28% | 1.28% / 1.28% |
| menu.access | 2.00% / 2.17% | 2.00% / 2.17% |
| menu.traits-access | 2.58% / 2.66% | 2.58% / 2.66% |
| files.question | 3.12% / 3.30% | 3.12% / 3.30% |
| cluster.overflow-access | 2.93% / 2.93% | retired / retired |

## Validation

All scoped cases pass except the direct 5% assertion for `03c-footer-controls.dark`, which remains failing at about 5.18%. The per-case ceiling is 5.5%, but its separate direct assertion is stricter. The official measured anchors and label widths are retained; no threshold was relaxed. `scripts/test --fast --no-parallel` passes 2,217 Swift Testing tests and 19 XCTest tests. An earlier parallel `--fast` run also passed; two intervening parallel runs reported different failures in unchanged tests (`TerminalModalSnapshotTests.dialogSnapshotCoversTheTerminal` and `SweepPanelsTests.expandedChromeDoesNotScheduleADeferredCollapse`). Both pass in the final serial run. No terminal, collapse-state implementation or corresponding test changed. Standalone `scripts/test --filter RedesignBaselineTests` passes all 80 exact images with zero changed pixels. The baseline now owns frozen copies of its original picker factories; it previously borrowed the default-theme fixture list, which changed during this migration. No baseline image or zero-pixel assertion changed.

Offscreen review only. The existing capture runner measured official source geometry against the copied reference sandbox without a model turn. No GUI app launch, live T3 data change, push or release occurred. Source and diff review found no new timer, idle observer or hidden-view work.

Final logs: `/tmp/design-screens-complete-fidelity.log`, `/tmp/design-screens-sidebar-verified.log`, `/tmp/design-screens-complete-redesign.log`, `/tmp/design-screens-fast-serial.log`. Reviewed offscreen artifacts remain in `/tmp/design-screens-complete-fidelity` and `/tmp/design-screens-sidebar-verified`. Intermediate image copies and the temporary headless profile were removed.

## Local commits

- `66f33c10` `test(composer): retire unreachable 3824 overflow state`
- `07afcbb9` `test(composer): compare with 3824 screens`
- `c609c735` `test(sidebar): compare with 3824 screens`
