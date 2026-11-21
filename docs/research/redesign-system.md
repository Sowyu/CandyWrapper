# Redesign system

Redesign is a near-black app with a background the user picks in Settings > Redesign > Background: their picture dithered, the picture blurred, or a halftone in the accent with no picture. The conversation sits straight on it, and the composer, pills, menus and modals are solid surfaces with a hairline rim. Redesign draws no backdrop blur anywhere. This page fixes the values every Redesign surface and control uses. They live in code as `RedesignTokens` in `Packages/CandyKit/Sources/DesignSystem/Theme/RedesignTokens.swift`, and `RedesignTokenGuardTests` fails when Redesign drawing code writes a corner radius, a shadow or a surface opacity anywhere else. The audit that led here is `docs/research/redesign-audit-2026-11-20.md`. Redesign is CandyWrapper's own look, so nothing here is checked against T3.

## Radius

The user, 2026-11-21: "make all corner radiuses the same unless its done right and tastefully and make corner radiuses akin to [corner-radius-target.png]". That picture's corner is a circular arc spanning 15px at 2x, so 7.5pt. Capy's own, measured in the user's screenshots, are tighter: about 6pt on the content panel and 4pt on the composer.

| Token | Value | Used for |
|---|---|---|
| `Radius.card` | 8 | every surface: cards, user bubbles, code blocks, tables, banners, menus, popovers, the 30pt pills, the header pill, the composer, the details card, the content panel, modals, Settings cards |
| `Radius.panel` | 8, the same as `card` | kept as a name for the large surfaces |
| `Radius.control` | 6, `nested(in: card, inset: 2)` | what sits inside a surface: buttons, menu rows, sidebar rows, tabs, chips, segmented selections |
| `Radius.joined` | 3 | where two user bubbles of a burst meet |
| `Radius.window` | 16 | the window's own corner, measured on macOS 27 |

`DitherChrome.radius(_ stock:)` maps T3's radii onto two steps: under 5 stays (hairline rounding), 5 to 8 is `control`, 9 to 29 is `card`, 30 and over stays (full pills).

Exceptions, each deliberate:

- Full pills stay round: status chips, the send button and dots take `Radius.capsule(height)`.
- The sidebar's account row is concentric with the window, `nested(in: window, inset: 8)`, so 8. Its avatar, and the account avatar in Settings, is a rounded square at `control` (the user: "make it a square with rounded corners"): strictly concentric, 8pt inside the card's 8pt corner, it would floor at 2, a hard square at 28pt. Default themes keep the circle.
- Menus and popovers draw their 8 as a circular corner through `BoxDecorationLayer`, where the composer and pills use continuous corners. At 1x the two read the same.
- `Radius.joined` is a shape inside a burst, not a step on the scale.

## Spacing

4, 8, 12, 16, 24 and 32 between things, with 2, 6, 10 and 14 inside a control. `Space.pill` is 30, a pill's height, which is a size and not a gap. Pills keep the 8 gap between rows and the 6 gap inside a row the user shaped on 2026-10-22.

## Type

The UI font at 400 and 500. Body text is 14, row titles and the thread title 13, meta text and captions 12, and labels in a pill 12. The thread title in the band is the project at 13 in the muted color, a slash, and the title at 13 and 500 in the text color. Size and color carry the hierarchy. Nothing in Redesign is drawn at 600 or heavier.

## Shadows

| Token | y | CALayer radius (CSS blur) | Opacity dark / light | Used for |
|---|---|---|---|---|
| `Shadow.resting` | 2 | 4 (8) | 0.28 / 0.08 | surfaces that rest on the picture: the composer, the pills, the header pill, cards on the art |
| `Shadow.floating` | 8 | 12 (24) | 0.45 / 0.12 | layers over content: menus, popovers, the project menu, tooltips, toasts |

Dark needs more opacity because a light shadow vanishes on a dark picture. A surface never draws a shadow and a border that do the same job: the rim gives the edge and the shadow gives the lift. Code blocks, tables and the changed-files card draw no shadow, since they do not float.

## Surfaces

The user, 2026-11-21: "in redesign no more blurs its no premium", about the thread menu. Every surface is opaque: a solid fill, a 1pt rim in the text color at 0.08 (0.24 under Increase Contrast) on its corner, and the token shadow.

| Surface | Fill (dark) | Fill (light) | Shadow |
|---|---|---|---|
| Ground (main panel) | `canvas` #080808 | `canvas` #f9f9f9 | none |
| Sidebar, band, chrome | #030303 | #ececec | none |
| Resting: the composer, pills, the header pill, the details card | `surfaceRaised` #0f0f0f | `card` #ffffff | resting |
| Floating: menus, popovers, pickers, tooltips, the command palette | `popover` from `surfaceOverlay` #141414 | #ffffff | floating |
| Modal: Settings and Usage | the ground, #080808 | #f9f9f9 | the modal's |
| Card on the ground or a modal: code blocks, tables, Settings cards, the changed-files card | white at 0.05 over the ground, #141414 | `card` in Settings, black at 0.05 over the ground elsewhere | none |

The scrim behind a modal or the command palette is the ground at 0.72 (dark) or 0.6 (light), with no blurred snapshot (`ModalHost.blurredSnapshot` returns nil under Redesign).

The no-blur rule lives in four places: `BackdropBlurView` sets its alpha to 0 under Redesign, so a blur view that T3's own look allocates (the composer, the banners) composites nothing; `WindowGlass.syncPaneBlur` only adds a pane blur for Glass; `WindowGlass.frosted(panes: false)` keeps Redesign's palette surfaces opaque; and Redesign-only views (`DitherPillSurface`, the tab strip, the details card, user bubbles) hold no blur view at all. Glass is untouched. "Glass opacity" still drives Glass and the default themes' dropdown glass; under Redesign it changes nothing.

Measured with the sandbox's thread open in dark on 2026-11-21: 24 `BackdropBlurView`s alive before, 14 after, and all 14 at alpha 0. The Background = Blur picture is not a blur view: `DitherArt.render` blurs it once on a worker, and it stays as it was.

## Backgrounds

Three choices, the client setting `redesignBackground`: `dither` (labelled Picture, the default), `blur` and `gradient`. Picture's own setting is Ink, Blur's is Background dim, Gradient's is Animate gradient.

Gradient is the user's "a dither option without an image like capy does here" and "capys plain dither isnt just static" (capy-dither-no-image.mov). No picture. Measured frame by frame from the recording (AVAssetImageGenerator, zero tolerance, 2.75 s to 12.5 s on the new-thread page): Capy's cells are binary, one navy (about #26314b) or off, on a fixed grid of 6px at 2x (3pt). They never shift or change size; the field under them changes. A 40px patch differs by under 2 levels from frame to frame, where a moving grid would differ by about 10. Soft lobes along the top drift and swell: one moves about 37pt a second to the right, the left one rises and fades, and one at the right grows from nothing to the brightest in about 5 s. The field stays in the top 25 to 30% (its centroid) and fades out by about 45% down. It did not repeat or settle in the 9.75 s on screen.

CandyWrapper's Gradient copies that. Cells on a 3pt grid, on where the field beats the cell's 8 by 8 Bayer threshold, in one color: the accent (`palette.primary`) at 36% over the ground in dark, 22% in light. The field is three Gaussian lobes along the top whose centres and strengths swing on whole turns of a 12 s loop, times a linear falloff to the canvas's foot, half way down the panel. `DitherArt.gradientFrames` renders the loop once on a worker as 96 one-byte alpha masks (8 a second), about 52 KB each for an 1100 by 850 panel, 5 MB in all. The view shows them through the art layer's mask, and a discrete `CAKeyframeAnimation` on the mask's contents flips them, so the app does no work per frame; the window server swaps the texture.

It moves only while every condition holds: Background is Gradient, Settings > Redesign > Animate gradient is on (the default), the new-thread page shows, the window is visible, not miniaturized or covered, and key, and Reduce Motion is off. Any one stopping removes the animation and holds the frame on screen (`DitherArtView.syncMotion`, `DitherArtTests.gradientMotionStopsWhenItCannotBeSeen`). The frames exist only while the new-thread page shows; a thread, Settings or any other page drops them and shows the plain ground with no scrim. With Animate off the page shows frame 0 still. Picture and Background dim are inert in Gradient, and Animate gradient is inert outside it.

Cost, measured on the M2 Pro with `top` over interleaved 6 s windows, the new-thread page key in dark: the app 0.02 to 0.03% CPU animating or still; the window server about 4.6% animating against about 4.2% with Animate off (the composer's caret blinks in both) and 0.3% with another app in front. So the motion costs about 0.4 points of window server CPU. Other agents' apps were drawing during the measurement, so single readings swung by several points; the averages above come from four cycles each.

The user chose, after seeing a glass card behind the conversation on 2026-11-21: "no glass card either full blur or full dither". Nothing sits behind the conversation in either mode. The setting is the client setting `redesignBackground`, `dither` by default.

Picture (the setting value `dither`) was rebuilt on 2026-11-21 after the user called 1.15.2's "so non premium" (r3-picture-dither-cheap.png: a washed photo under a grey dim with dots in a few bands). They chose B1 from the mockups ("i like b1", "i like 2 ink") and no motion ("ok yeah no motion its horrid"). It lives in `PictureInk`:

1. The picture covers the panel at one sample per 3pt cell, on Gradient's lattice (top left of the panel, `PictureInk.cell` = `DitherArt.gradientUnit`).
2. Tone is gamma-encoded luma, auto levels from the 1st to the 99th percentile (a flat picture keeps its own lightness), half an S-curve, then gamma 1.15.
3. A dark picture is lifted: a gamma (never under 0.5) takes the median tone up to 0.34. The mockups left Big Sur Dark's coastline and Sonoma's hills almost empty; the lift fills them, and a bright picture is untouched.
4. An 8 by 8 Bayer threshold picks between neighbouring levels only: ground, deep ink, light ink in dark; ground, light ink, deep ink in light, where the dark parts of the picture take ink. Ink covers at most 85% of a level, so a bright sky keeps a pattern.
5. Nothing of the photo shows through and no scrim or veil lies over a new thread or a thread.

The Ink setting (`redesignInk`, `redesignInkColor`) picks the inks. Auto is the mockup's rule: the picture's OKLCH hues in 24 bins scored by chroma squared (so a vivid patch beats a big dull one), ignoring pixels under chroma 0.035 or outside L 0.12 to 0.96; the best bin and its neighbours give the hue. Under 20% chromatic pixels takes Capy's navy hue; 75 to 115 degrees, which turns mustard, rotates to 130. The deep ink is L 0.52 C 0.10 and the light ink L 0.82 C 0.11 at the hue plus 12, chroma reduced into sRGB. Golden Gate gives #95572d and #f6b576, Radial Sky Blue #077396 and #86cdff, Sonoma Horizon #557432 and #9bd694, the mockup's own values. Accent makes the accent the light ink, Custom a color from the well; either way the deep ink is that hue at L 0.52 and at most C 0.10.

The new-thread page passes its composer's frame (`DitherArtView.setComposer`) and the dots thin around it and toward the sides and the foot (`PictureInk.heroDensity`, the mockup's fall-off). A thread passes its reading column (`setColumn`). Behind it the dots drop to 40% and to the near ink only, and that ink is moved toward the ground in linear light until body text keeps 7:1 and muted text 4.5:1 against it (`PictureInk.textBound`). Over 120pt beside the column the art comes back to full, so the margins and the top keep the picture. Measured at the worst cell behind the column in a 1384 by 900 panel: body 10.0:1 and muted 4.7:1 in dark for all five test pictures. In light the floor leaves the column close to white, since the light theme's muted #737373 needs a cell of luminance 0.94 or more.

Settings and other pages keep their heavy scrims (0.8 and 0.92). Reduce Transparency and Increase Contrast keep theirs on every page. "Background dim" now dims only Blur, and its row is inert outside Blur; Picture keeps the theme's muted text, since its render enforces the floor itself.

Picture renders once per canvas size, picture, appearance, ink, ground and page shape on a utility queue. The tone (one byte a cell) is cached for the last picture and size, so a page or ink change only re-thresholds it. Measured on the M2 Pro: decoding and toning a picture for a 1384 by 900 panel takes 34 to 170 ms, a threshold 2 ms. It holds the 462 by 300 RGBA image (554 KB) and the tone (139 KB), 693 KB in all, against 1.25 MB for 1.15.2's 2pt dots in the same panel. A miniaturized or ordered-out window drops both. The new-thread reveal is gone, so Picture runs no animation at all.

While the panel's size differs from the shown canvas (a window resize or a sidebar drag), `placeArt` scales the cached image to cover the panel, centred as the picture is, so the window server scales it each frame and no band of ground shows. The sharp render follows 0.15 s after the size stops changing, or at once when a live resize ends (the user, 2026-11-21: "i need to release my mouse before it pops in"). Gradient's canvas stretches over its reach the same way. This holds for all three Backgrounds.

Blur draws the same picture behind the whole window, the sidebar and the tab band included, with no edge between the sidebar and the panel. `DitherArt.render` blurs the picture once per size, appearance and picture on a worker thread: close to a Gaussian of sigma 32pt (two vImage tent passes) over a canvas of 8pt pixels, which the layer scales up smoothly. At that sigma text- and icon-sized detail in the picture is gone while its colors and window-sized shapes still read. I compared 16, 32 and 64 over Sonoma: at 16 the ripple stripes in its green still read as detail, and at 64 the red wave runs into the sky. The cached image is a sixteenth of the dots' memory: 81 KB for a 1440 by 900 window, against 1 MB for Dither's dots in the panel. Then the same fade and reach as the dots apply without the steps, so no pixel strays further from the background than the brightest dot does, and the dim, scrim and veil are Dither's. Nothing redraws while a thread scrolls or streams. The sidebar's text, muted text and icons take the same 4.6:1 floor, since they sit on the picture too. The new-thread reveal does not play in Blur.

In both modes the rows fade out above the tab band's 52 and are back in full 16 below it, through the timeline's mask, so nothing runs under the header pill and no header bar shows, which the user removed from every theme (324b6bcf). The mask leaves the picture itself in that clear top. The only visible fade is the band's color over the window's top 20pt (`DitherArtView.topBlend`, Picture and Gradient; Blur shows the picture there). It reached the band's whole 52 until 2026-11-21, a grey slab under the title the user removed ("lets remove this early fade i only want the one up here"), and it covered the top of Gradient's dots. The thread's project and title sit there on the lane's left edge, on the pill's centre line, and hide while tabs show, since the tab names the thread.

## Tint from picture

The user, 2026-11-21: "very slightly tint the ui to the pictures colours". Settings > Redesign > Tint from picture, on by default, client setting `redesignTintFromPicture`. Under Picture and Blur, `PictureTint` averages the picture in linear light over a 16 by 16 downsample, once per picture on a worker, and caches it by path. The mean's OKLab a and b are scaled by 3, since a whole picture averages far greyer than any part of it, and capped at chroma 0.1. `ThemeRuntime.resolve` then moves the a and b of every neutral opaque surface role (ground, sidebar, chrome, cards, menus, inputs, bubbles, code, opaque lines) 5% toward it, keeping each one's L, so every surface follows through the palette. Text, icons and colored roles keep their values. Gradient takes no tint: it has no picture, and a thread in Gradient is plain ground.

Measured on screen in dark (8-bit sRGB): the composer goes from 18/18/18 to 21/17/16 over the default Golden Gate picture and to 15/20/21 over Radial Sky Blue, and stays 18/18/18 over Sonoma. `PictureTintTests` holds body text at 7:1 and muted at 4.5:1 on every text surface in both appearances for saturated red, green, blue, yellow, magenta, cyan, orange, white and black pictures, with contrast moving under 2%. Light uses the same mix; whites clamp into sRGB, so a white card takes a faint cast and stays white to the eye.

## Palette (dark)

Before 2026-11-21 Redesign dark was Capy's stylesheet grays: canvas #131314, chrome and sidebar #0a0a0b, surface #181819, raised and overlay #202021, border #232324, input #2a2a2b, muted #1c1c1d, bubbles #202021, code #0f0f10. Over the glass at the user's 10% Glass opacity, Settings read as one flat #1e1e1e to #262626 (too-grey-settings.png). Now, after Capy's real app (its window #000, panel #050505, composer #0f0f0f, selected row #1a1a1a, hairline #141414):

| Role | Before | After |
|---|---|---|
| canvas (ground) | #131314 | #080808 |
| chrome, toolbar, sidebar | #0a0a0b | #030303 |
| surface | #181819 | #0e0e0e |
| surfaceRaised, toolbarControl | #202021 / #181819 | #0f0f0f |
| surfaceOverlay (menus) | #202021 | #141414 |
| border | #232324 | #1d1d1d |
| input | #2a2a2b | #262626 |
| muted | #1c1c1d | #161616 |
| messageSurface (bubbles) | #202021 | #1e1e1e |
| codeBackground, terminal | #0f0f10 | #0c0c0c |
| sidebarRowSelected, active | #ffffff17 | #ffffff1a |

Text keeps its values. Body #f5f5f5 is 18.4:1 on the ground and 16.9:1 on a menu or card; muted #aaaaab is 8.6:1 on the ground and 7.9:1 on a menu or card (it was 7.0:1 on the old #202021). Light keeps its palette: once the surfaces were solid it showed no flatness.

## States

| State | Treatment |
|---|---|
| Hover | text color at `State.hover` 0.06 (dark) or 0.042 (light), at once in and over `Motion.fast` out |
| Pressed | text color at `State.pressed` 0.1 or 0.07, while held or while its menu is open |
| Selected | text color at `State.selected` 0.1, or the palette's `sidebarRowSelected` in the sidebar |
| Focus | the accent ring T3 draws (`BoxShadow.focusRing`), only for keyboard focus, never with an underline |

Hover clears through `HoverSync` when the pointer leaves, when the window loses key and when content scrolls under a still pointer.

## Motion

Three durations, `Motion.fast` 120 ms for exits, the hover fade out and the press, `Motion.standard` 150 ms for menus, popovers and pills, `Motion.large` 200 ms for modals and the right panel. Everything that arrives or moves takes `Motion.curve`, `cubic-bezier(0.23, 1, 0.32, 1)`, and everything that leaves `Motion.exitCurve`. Menus and popovers scale from 0.98 about their anchor, pills and toasts travel `Motion.rise`, 4pt, and a pressed button scales to 0.98. The patterns live in `RedesignMotion`, and `RedesignTokenGuardTests` fails on a literal duration on a Redesign path. Under Reduce Motion surfaces appear without moving. Nothing animates at rest. The inventory is `docs/research/redesign-motion-2026-11-21.md`.

## Measured contrast

Blur measured on 2026-11-21 from the rendered art at the default 35% dim, against the worst pixel behind the lane (x 500 to 1200 of a 1400 by 900 window, under the scrim and veil) and, in Blur, behind the sidebar (x 0 to 280, no veil): the brightest in dark, the darkest in light. Pictures: iMac Silver (brightest), Radial Sky Blue (darkest) and Sonoma (busy), from /System/Library/Desktop Pictures. The worst of the three:

| Mode | Appearance | Lane body | Lane muted | Sidebar text | Sidebar muted |
|---|---|---|---|---|---|
| Picture | Dark | 10.0:1 | 4.7:1 | flat, unchanged | flat, unchanged |
| Picture | Light | 7.0:1 or more | 4.5:1 or more | flat, unchanged | flat, unchanged |
| Blur | Dark | 8.2:1 | 4.8:1 | 7.2:1 | 4.7:1 |
| Blur | Light | 13.4:1 | 5.5:1 | 13.1:1 | 5.3:1 |

The sidebar's icons measure 4.7:1 in both appearances over Blur. Body text stays far above 4.5:1 there, so Blur needs no stronger dim or veil. Picture's rows are its own floor, measured at the worst cell behind the column (`PictureInkTests.textKeepsItsFloorsBehindTheColumn`).

## Glass

Glass shares none of the changed paths: `DesignGeometry.radius`, the popup and toast shadows, the cards and the table inset all branch on Redesign alone, and the Blur checks in `WindowGlass` and `SidebarLayoutView` read `ThemeRuntime.ditherBlur`, which only Redesign sets. Glass draws as it did.
