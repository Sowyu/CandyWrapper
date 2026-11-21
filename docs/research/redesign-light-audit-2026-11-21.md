# Redesign light audit, 2026-11-21

The user: "light mode fix because light mode looks so bad rn its actual slop". Redesign's dark appearance had two days of work and light almost none. This audit covers Redesign (`candywrapper-dither`) in the light appearance only. The default T3 themes, Glass and Redesign dark keep every pixel: every change below is in the light half of the Redesign palette, behind `RedesignTokens.Segment.light(in:)`, or in a light-only branch of the art (`!dark`).

Pictures are in `~/CandyWrapper-research/sandbox/light-mode-2026-11-21/`. `1-before-on-screen.png` (the sandbox server, 1x) and `2-before-offscreen.png` (the `RedesignBaselineTests` renders at 2x) carry the numbered callouts used below. `pair-*.png` are before and after per surface, and `best-of.png` holds the most improved ones. The bar was Linear's and Capy's light themes: an off-white ground, white cards that lift off it with a hairline and a small shadow, near-black text, quiet dividers, and states you can see.

## What was wrong

1. Left. New thread, Picture: the near ink in light is the picture's light ink, L 0.82 C 0.11 (Golden Gate gives #f6b576), at full strength up to the window's top and under the header pill. It is loud, but the user chose the two inks ("i like 2 ink") and light keeps them on the margins and the top. A lighter near ink for light only is the next step if the user still finds it loud, about 20 minutes plus a sheet of inks to choose from.
2. Fixed. The sidebar (#ececec) and the ground (#f9f9f9) were two greys that, with Tint from picture, both went mauve over a warm picture, and the sidebar's selected row (#00000012 over #ececec) sat close to the unselected rows' grey. The sidebar is now #f1f1ef and the ground #f8f8f7, two neutral steps, with cards white above both.
3. Fixed. Thread, Picture: behind the reading column the dots dropped to 40% and toward white until muted text kept 4.5:1. Light's muted text needs a cell of luminance 0.94 or more there, so what was left was a field of pale smudges under every paragraph. Light now keeps a clean column (`PictureInk.lightColumnDensity` = 0). Dark's 120pt feather beside it then left only sparse stray dots in a usual 40 to 60pt margin, so light leaves a 16pt clear gap and brings the ink back to full over 32pt (`lightColumnGap`, `lightColumnFeather`). The text sits on the plain ground and the picture shows as a band in the margins.
4. Left, correct. The composer and pills over the ink at the foot: they are white with the rim and the resting shadow, and read as cards.
5. Fixed. Model picker, Reasoning: the segmented track was `input` at 0.4 (#cfcfcd) under a selection of `input` at 0.72 (#a3a3a1), 1.6:1 against each other, the "muddy grey" an earlier agent saw. In light the track is now the text color at 0.06 and the selection a white card with the rim and the resting shadow (`RedesignTokens.Segment`).
6. Fixed. The Ultracode chip in the picker's footer is the same control, and had the same grey track.
7. Fixed. Settings > Redesign's Background and Ink, and the PR panel's Summary/Timeline/Code, used T3's `ToggleGroup` with the same `contrastInput` track, a heavy #cfcfcd bar on a white card. They take the same light treatment.
8. Fixed. Sidebar "Done" chips: success resolved to T3's derived #00c590, 2.0:1 on the sidebar, the loudest thing on the screen and under AA. Redesign light now uses #0e7a50 (`ThemeDefinition.capyLightSuccess`), 4.7:1 on the sidebar and 5.4:1 on a card. Warning #983d00 and error #a80005 were already dark enough.
9. Left, correct. The selected sidebar row keeps black at 0.07, now #e1e1df on the sidebar, 1.16:1 against it, against 1.13:1 for the old #dcdcdc on #ececec.
10. Fixed. Settings, Usage, the state card and every other page showed the art under a 0.88 or 0.92 scrim. In light that left grey speckle and a white diagonal between white cards, which reads as dirt. Light now covers the art fully on Settings and pages (`DitherArt.lightScrim`), so they sit on the plain ground. Dark keeps its 0.8 and 0.92.
11. Fixed. Gradient in light was "very faint": the cell was the accent at 22% over the ground, #c3dedc on #f8f8f7, 1.3:1. It is now 32%, #abd3cf, 1.5:1, close to the 1.7:1 step dark's 36% makes. No text sits on the field except the header row, which sits on a pill.
12. Left. The Usage chart's hatched series is the text color at full strength next to the coral series, so it is the heaviest mark on the page. That chart was designed with the user from dither-kit's target; changing its ink is the chart owner's call.
13. Left, correct. Code blocks over the art are the ground with black at 0.05, #ececeb, opaque, with the rim. Syntax colors keep 4.5:1 on them (`RedesignLightContrastTests.syntaxReadsOnACodeBlockOverTheArt`).
14. Fixed. Dividers (`border`, `toolbarBorder`) were #c2c2c2, 1.7:1, so every list and card header was ruled in mid grey. They carry no meaning, and are now #e3e3e0. Control outlines (`input`) keep 3:1 at #8a8a87.
15. Fixed. Text was #1e1e1e and is now #171717, 16.9:1 on the ground.

Surfaces I checked that were already right in light, on the baseline renders and on screen: menus, popovers, the command palette and toasts are white with the 0.08 rim and the floating shadow at 0.12, and now lift off an off-white ground instead of a near-white one; the gallery wall and the image card keep their pictures on the ground; the state component's title and detail sit at 16.9:1 and 6.3:1.

## The light palette

| Role | Before | After | Why |
|---|---|---|---|
| canvas (ground) | #f9f9f9 | #f8f8f7 | off-white, a touch warm, so white cards lift off it |
| chrome, toolbar, sidebar, sidebarBorder | #ececec | #f1f1ef | one step darker than the ground, as Linear's sidebar |
| surface, surfaceRaised, surfaceOverlay, toolbarControl, sidebarControlSurface | #ffffff, sidebar control #e4e4e4 | #ffffff | real white for everything that floats or holds input |
| text, foregrounds | #1e1e1e | #171717 | near-black |
| textMuted, mutedForeground, placeholder, secondaryLabel, sidebarMutedForeground | #5a5a5a, #5c5c5c | #5c5c5a | 4.5:1 over the darkest dot the art allows |
| iconMuted | #767676 | #737371 | 4.7:1 on a card, 3:1 over the darkest dot |
| border, toolbarBorder | #c2c2c2 | #e3e3e0 | quiet dividers |
| input (control outlines) | #858585 | #8a8a87 | 3:1 on the ground |
| muted | #e1e1e2 | #efefed | a fill, not a line |
| messageSurface (user bubble) | #efefef | #ededeb | a visible step on the ground |
| codeBackground | #f4f4f4 | #f3f3f1 | neutral with the ground |
| terminalBackground | T3's #fcfcfc | #ffffff | the terminal card is a card |
| secondary, accentSurface, toolbarControlHover, sidebarRowHover | #0000000d, #0000000a | #0000000a | one hover step |
| success (derived) | #00c590 | #0e7a50 | AA on the sidebar |
| segmented track | `input` at 0.4, #cfcfcd | black at 0.06 | quiet |
| segmented selection | `input` at 0.72, #a3a3a1 | white, 0.08 rim, resting shadow | the selection is the lifted thing |

Radii, spacing, shadows and the accent are unchanged. The accent stays `DitherAccent.lightAccent`, teal #07837a, dark enough for white labels.

Contrast, WCAG 2 ratios, computed from the sRGB values:

| Foreground | Ground #f8f8f7 | Sidebar #f1f1ef | Card #ffffff | Darkest dot #d7d7d7 |
|---|---|---|---|---|
| text #171717 | 16.9 | 15.9 | 17.9 | 12.5 |
| muted #5c5c5a | 6.3 | 5.9 | 6.7 | 4.7 |
| icon #737371 | 4.5 | 4.2 | 4.8 | 3.3 |
| input #8a8a87 | 3.3 | 3.1 | 3.5 | 2.4 |
| success #0e7a50 | 5.0 | 4.7 | 5.4 | 3.7 |
| warning #983d00 | 6.6 | 6.2 | 7.0 | 4.9 |
| error #a80005 | 7.4 | 7.0 | 7.9 | 5.5 |

`RedesignLightContrastTests.lightPaletteKeepsItsSteps` holds body at 7:1 and muted, success, warning and error at 4.5:1 on the ground, cards, menus, the bubble and the sidebar, and checks that the sidebar is darker than the ground and the ground darker than a card. The existing art checks now read the ground from the palette instead of a fixed 249.

## Backgrounds in light

Picture: the column is clean and the ink stays in the margins (finding 3). The new-thread page keeps its own fall-off around the composer. The text no longer sits on dots at all, so its contrast is the palette's: 16.9:1 and 6.3:1.

Blur: measured earlier at 13.4:1 body and 5.5:1 muted in the lane over the brightest test picture, and 13.1:1 and 5.3:1 in the sidebar. The sidebar's muted text still passes through `WindowGlass.readable` at 4.6:1 over the darkest blurred pixel, so the new greys keep that floor.

Gradient: finding 11.

Tint from picture and Ink: both run through the same paths in light. The tint moves the new neutral surfaces 5% toward the picture's hue and keeps their lightness (`PictureTintTests` passes in both appearances), and Ink picks the inks for the light render as before.

## Checked on screen

On the 4928 sandbox in light, 1x: the new-thread page and a thread in Picture, Blur and Gradient, the model picker with its detail pane, Settings > General and > Redesign, the command palette, a pressed sidebar row and the keyboard focus ring in the Settings nav. The before and after captures are `before/*.png` and `after/*.png`, paired in `pair-*.png`.

`RedesignBaselineTests` renders the thread art without a reading column, so its `thread-*` images still show dots behind the text. On screen the column is clean.

## Not in this branch

Re-recorded images. These light baselines change and wait for the integrator to record after merging, with `CANDY_RECORD_REDESIGN_BASELINE=1 scripts/test --filter RedesignBaselineTests`: all 56 `.light.png` under `design/redesign-baseline/`, plus the light images of `SettingsProjectListTests` and `SettingsProjectDeleteTests`. One dark image changes too: `settings-appearance.dark.png`, inside the Redesign theme card's light swatch only (x 670 to 773, y 1110 to 1213 at 2x), since that swatch previews the light palette. Every other dark image is byte-identical to the base commit's render. The palette fixture `fixtures/theme/candy-3669-baseline.json` is re-recorded in this branch; only its `candywrapper-dither/*/light` and `sidebarLight` entries change.
