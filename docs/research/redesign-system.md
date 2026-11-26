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

The UI font at 400 and 500. Body text is 14, row titles and the thread title 13, meta text and captions 12, and labels in a pill 12. The thread title in the band is the project at 13 in the muted color, a slash, and the title at 13 and 500 in the text color. Size and color carry the hierarchy. Redesign's chrome is never drawn at 600 or heavier: `LabelView` and `TextBlockView` draw T3's 600 and 700 at 500 under Redesign, custom drawing goes through `RedesignTokens.Weight.chrome`, and RedesignTokenGuardTests fails on a heavier weight that bypasses both. Message content keeps its own weights, so Markdown headings, bold and table headers, the prompt's rich text, code and math draw as T3 draws them: the thread the user shaped (`thread-markdown-top` in design/redesign-baseline) has semibold headings, and they are what the reply says, not the app's hierarchy.

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
| Ground (main panel) | `canvas` #080808 | `canvas` #f8f8f7 | none |
| Sidebar, band, chrome | #030303 | #f1f1ef | none |
| Resting: the composer, pills, the header pill, the details card | `surfaceRaised` #0f0f0f | `card` #ffffff | resting |
| Floating: menus, popovers, pickers, tooltips, the command palette | `popover` from `surfaceOverlay` #141414 | #ffffff | floating |
| Modal: Settings and Usage | the ground, #080808 | #f8f8f7 | the modal's |
| Card on the ground or a modal: code blocks, tables, Settings cards, the changed-files card | white at 0.05 over the ground, #141414 | `card` in Settings, black at 0.05 over the ground elsewhere | none |

The scrim behind a modal or the command palette is the ground at 0.72 (dark) or 0.6 (light), with no blurred snapshot (`ModalHost.blurredSnapshot` returns nil under Redesign).

The no-blur rule lives in four places: `BackdropBlurView` sets its alpha to 0 under Redesign, so a blur view that T3's own look allocates (the composer, the banners) composites nothing; `WindowGlass.syncPaneBlur` only adds a pane blur for Glass; `WindowGlass.frosted(panes: false)` keeps Redesign's palette surfaces opaque; and Redesign-only views (`DitherPillSurface`, the tab strip, the details card, user bubbles) hold no blur view at all. Glass is untouched. "Glass opacity" still drives Glass and the default themes' dropdown glass; under Redesign it changes nothing.

Measured with the sandbox's thread open in dark on 2026-11-21: 24 `BackdropBlurView`s alive before, 14 after, and all 14 at alpha 0. The Background = Blur picture is not a blur view: `DitherArt.render` blurs it once on a worker, and it stays as it was.

## Backgrounds

Four choices, the client setting `redesignBackground`: `dither` (labelled Picture, the default), `blur`, `gradient` and `flower`. Picture's own settings are Ink and Dot size, Blur's is Background dim, and Gradient and Flower share Animate background (stored as `redesignGradientAnimate`, its name from when only Gradient moved).

Gradient is the user's "a dither option without an image like capy does here" and "capys plain dither isnt just static" (capy-dither-no-image.mov). No picture. Measured frame by frame from the recording (AVAssetImageGenerator, zero tolerance, 2.75 s to 12.5 s on the new-thread page): Capy's cells are binary, one navy (about #26314b) or off, on a fixed grid of 6px at 2x (3pt). They never shift or change size; the field under them changes. A 40px patch differs by under 2 levels from frame to frame, where a moving grid would differ by about 10. Soft lobes along the top drift and swell: one moves about 37pt a second to the right, the left one rises and fades, and one at the right grows from nothing to the brightest in about 5 s. The field stays in the top 25 to 30% (its centroid) and fades out by about 45% down. It did not repeat or settle in the 9.75 s on screen.

CandyWrapper's Gradient copies that. Cells on a 3pt grid, on where the field beats the cell's 8 by 8 Bayer threshold, in one color: the accent (`palette.primary`) at 36% over the ground in dark, 32% in light. The field is three Gaussian lobes along the top whose centres and strengths swing on whole turns of a 12 s loop, times a linear falloff to the canvas's foot, half way down the panel. `DitherArt.gradientFrames` renders the loop once on a worker as 96 one-byte alpha masks (8 a second), about 52 KB each for an 1100 by 850 panel, 5 MB in all. The view shows them through the art layer's mask, and a discrete `CAKeyframeAnimation` on the mask's contents flips them, so the app does no work per frame; the window server swaps the texture.

It moves only while every condition holds: Background is Gradient, Settings > Redesign > Animate gradient is on (the default), the new-thread page shows, the window is visible, not miniaturized or covered, and key, and Reduce Motion is off. Any one stopping removes the animation and holds the frame on screen (`DitherArtView.syncMotion`, `DitherArtTests.gradientMotionStopsWhenItCannotBeSeen`). The frames exist only while the new-thread page shows; a thread, Settings or any other page drops them and shows the plain ground with no scrim. With Animate off the page shows frame 0 still. Picture and Background dim are inert in Gradient, and Animate gradient is inert outside it.

Cost, measured on the M2 Pro with `top` over interleaved 6 s windows, the new-thread page key in dark: the app 0.02 to 0.03% CPU animating or still; the window server about 4.6% animating against about 4.2% with Animate off (the composer's caret blinks in both) and 0.3% with another app in front. So the motion costs about 0.4 points of window server CPU. Other agents' apps were drawing during the measurement, so single readings swung by several points; the averages above come from four cycles each.

Flower is the user's "a 3d dithered flower that blooms on opening a thread and moves smoothly", approved at stage 1 ("so pretty make sure its properly placed and sized"). `LotusArt` renders a lotus of six rings of eight petals, a seed pod and a receptacle under the petals, as two-ink masks on 3pt cells: the accent in dark, its hue at OKLCH L 0.46 (chroma at most 0.14) in light, deep cells at `deepAlpha` over the ground. Placement comes from the thread panel's geometry each layout (`ThreadPanelView.reportFlowerStage`, `LotusArt.spot`): the content area left of the right panel and below the band, and what the flower keeps 24pt from (the composer with its pills and cards, the reading column, the header pill, a right panel sheet). On the new-thread page it is centred across the content area and down the free run above the composer group, as large as fits up to 288pt, its dots thinning toward the composer. In a thread it sits at the top of the content area, centred in the margin right of the column, up to 150pt; below 60pt it hides, which in a thread means a window about 1,460pt wide with the sidebar open. Settings, Issues, Pull requests, Usage and other pages show the plain ground, as Gradient does.

Frames render on a worker across the cores per radius bucket (8% steps from 60pt, about 20 buckets): the open still first, then the 28 bloom masks, then the 160-frame idle loop. A drag scales the shown set on the GPU and renders the new bucket 0.15 s after it stops; a new set takes over on the same idle frame, and a running bloom carries over. The bloom plays when the new-thread page appears or another project's draft shows (`setDraft`) and when a thread switch begins (`beginThreadSwitch`), but not when a draft's first send becomes its thread, on re-renders, stream updates, scrolling, Settings closing or the window coming back. It starts from a parted bud that fades in over 0.3 s and ends on the idle loop's first frame. The stop conditions are Gradient's, and stopping holds the open flower, never the bud (`FlowerArtTests`).

Cost, measured on the M2 Pro with `top` over interleaved 6 s windows, the new-thread page key in dark, composer unfocused, both Backgrounds in the same window: Flower's idle loop raises the window server from about 0.5% to 3.4%, Gradient's from about 2.0% to 5.0%, about 3 points each. The app reads 0.0%. Gradient's 0.4 points above came from a baseline with the caret blinking. Pinning the animations' `preferredFrameRateRange` to their frame rate changed nothing. Masks are width times height bytes a frame, 189 frames a set: about 1 MB for a 1285 by 780 window's new-thread flower and at most 5.4 MB at 288pt; footprint read 61 MB with Gradient and 62 MB with Flower on the same page.

The user chose, after seeing a glass card behind the conversation on 2026-11-21: "no glass card either full blur or full dither". Nothing sits behind the conversation in either mode. The setting is the client setting `redesignBackground`, `dither` by default.

Picture (the setting value `dither`) was rebuilt on 2026-11-21 after the user called 1.15.2's "so non premium" (r3-picture-dither-cheap.png: a washed photo under a grey dim with dots in a few bands). They chose B1 from the mockups ("i like b1", "i like 2 ink") and no motion ("ok yeah no motion its horrid"). It lives in `PictureInk`:

1. The picture covers the panel at one cell per dot, on a lattice from the panel's top left. Settings > Redesign > Dot size (`redesignDotSize`, `DitherDotSize`) picks the cell: Fine 1.5pt, Medium 2pt (the default) or Coarse 3pt, Gradient's cell and 1.16.0's. The user, on 3pt on a 2x laptop: "i feel like the pixels might be a bit big". Every size is whole device pixels: Fine is 3 pixels at 2x and draws 2pt at 1x, where 1.5pt falls between pixels. I picked Medium on 2x renders of the user's Tokyo Bay skyline and street lamps and the five mockup pictures: Coarse turns a skyline into blocks, and Fine keeps the most detail but starts to read as a smooth texture instead of dots. Gradient and Flower keep 3pt.
2. Tone is gamma-encoded luma. Each cell takes the mean of about 0.75pt samples in linear light, then a 3 by 3 blur that blends neighbours within 0.06 of each other and keeps edges brighter than that (`PictureInk.smoothed`), so grain can't flip single cells. Auto levels run from the 1st to the 99th percentile, half an S-curve, then gamma 1.15. From three quarters of the range up a cell takes its brightest sample instead of its mean, so a highlight smaller than a cell, like a lamp head, still lights it.
3. A dark picture is lifted: a gamma (never under 0.5) takes the median tone up to 0.34. The mockups left Big Sur Dark's coastline and Sonoma's hills almost empty; the lift fills them, and a bright picture is untouched. A low-key picture is not lifted (`PictureInk.lowKey`): one with over 55 to 75% of the frame under luma 0.1 and under 15 to 30% between 0.1 and 0.35, like the user's night photo of street lamps in fog (97% under 0.1). Its levels also run to the 99.9th percentile, since its 99th is haze (0.2 in that photo), not its lamps. Big Sur Dark (43% under 0.1) and Sonoma (21%) keep the lift. Light applies the same rule to the inverted histogram. Tones under the black point, 0.06 after levels, draw no dot, and the tones above it ease in from none, so haze and grain leave the ground clean.
4. An 8 by 8 Bayer threshold picks between neighbouring levels only: ground, deep ink, light ink in dark; ground, light ink, deep ink in light, where the dark parts of the picture take ink. Ink covers at most 85% of a level, so a bright sky keeps a pattern.
5. Nothing of the photo shows through and no scrim or veil lies over a new thread or a thread.

The Ink setting (`redesignInk`, `redesignInkColor`) picks the inks. Auto is the mockup's rule: the picture's OKLCH hues in 24 bins scored by chroma squared (so a vivid patch beats a big dull one), ignoring pixels under chroma 0.035 or outside L 0.12 to 0.96; the best bin and its neighbours give the hue. Under 20% chromatic pixels takes Capy's navy hue; 75 to 115 degrees, which turns mustard, rotates to 130. The deep ink is L 0.52 C 0.10 and the light ink L 0.82 C 0.11 at the hue plus 12, chroma reduced into sRGB. Auto reads the hue from its own 600-pixel decode of the picture, never from the tone's larger one, so the inks never change with the window or the dot size: decoded above about 1930 pixels the Great Wave scored olive instead of blue. Golden Gate gives #95572d and #f6b576, Radial Sky Blue #077396 and #86cdff, Sonoma Horizon #557432 and #9bd694, the mockup's own values. Accent makes the accent the light ink, Custom a color from the well; either way the deep ink is that hue at L 0.52 and at most C 0.10.

The new-thread page passes its composer's frame (`DitherArtView.setComposer`) and the dots thin around it and toward the sides and the foot (`PictureInk.heroDensity`, the mockup's fall-off). A thread passes its reading column (`setColumn`). In 1.16.0 the dots behind it dropped to 40% and the near ink, and text measured 10.0:1 and 4.7:1 at the worst cell, yet read badly: the user, on grey lines over teal dots, "also see this text hard to read". They chose on 2026-11-21: "no plain near black just more blacker near the middle subtly so its not super obvious". So the picture darkens toward the middle of the thread, but only as much as reading needs. Behind the column each ink is held to a cell cap (`PictureInk.cellCap`, `capped`): the brightest luminance at which body text keeps 14:1 and muted text 6.8:1 against that one cell, the numbers the Great Wave in a 1975pt window needed to read comfortably. A cell already under the cap, the ground and any dark part of the picture, is left exactly as it is; a brighter ink is moved toward the ground in linear light until it meets the cap. Across the margin the cap relaxes on a log scale to no cap at the panel's edge, along `calmFalloff` (a smoothstep of the distance to the 1.3, flat at both ends, spread over the margin or `calmReach` 160pt, whichever is longer, so a margin narrower than that keeps part of the cap at its edge instead of ending in a bright strip) raised to `capRelax` 2. Nothing thins the dots and nothing lies on top. Where the fade crosses from the deep ink to the light one the threshold takes a hash jitter of up to 0.16 levels (`calmJitter`), never on a cell with no tone, so black stays black.

The user chose this in steps on 2026-11-21: a darkening that faded over the whole margin (C) over one that stopped at 240pt, then "even more subtle fade out on the edges". The first version of C darkened by a fixed 0.7 whatever the picture was, which took their own street-lamp wallpaper almost to black in a thread. The cap fixed that: a dark photo is untouched. On the Great Wave, relaxing at 3 brought back a bright strip beside the column; 2 keeps its fade smooth. One limit stays: the cap holds any dot behind text to about luminance 0.016, so a lamp head or a full moon behind the column reads as a dim shape of the picture, not its light. In light the same cap is mirrored, and the ink comes back across the margin with no step. Light's muted text (#5c5c5a) measures 6.3:1 on the plain ground, so its 4.5:1 floor lets cells down to luminance 0.66 behind the column: pale ink sits behind light text at its floors, as darkened ink does in dark (checked on screen 2026-11-26; `PictureInkTests.lightColumnIsClean` still feeds the older #737373 muted, at 4.47:1, where nothing but ground fits). The new-thread page keeps its fall-off around the composer.

Settings and other pages keep their heavy scrims in dark (0.8 and 0.92) and cover the art fully in light, where the leftover dots read as grey speckle between white cards. Reduce Transparency and Increase Contrast keep theirs on every page. "Background dim" now dims only Blur, and its row is inert outside Blur; Picture keeps the theme's muted text, since its render enforces the floor itself.

Picture renders once per canvas size, dot size, picture, appearance, ink, ground and page shape on a utility queue. The tone (one byte a cell) is cached for the last picture, size and dot size, so a page or ink change only re-thresholds it. Measured with an -O build on the M2 Pro for a 1440 by 900pt panel over the street lamps, Tokyo Bay, Golden Gate and Sonoma (main's 3pt took 48 to 144 ms to tone):

| Dot size | Cells | Decode and tone | Threshold | Cached image and tone |
|---|---|---|---|---|
| Coarse 3pt | 480 x 300 | 78 to 101 ms | under 1 ms | 720 KB |
| Medium 2pt | 720 x 450 | 105 to 154 ms | 1 to 2 ms | 1.62 MB |
| Fine 1.5pt | 960 x 600 | 133 to 190 ms | 2 to 3 ms | 2.88 MB |

A miniaturized or ordered-out window drops both. The new-thread reveal is gone, so Picture runs no animation at all.

While the panel's size differs from the shown canvas (a window resize or a sidebar drag), `placeArt` scales the cached image to cover the panel, centred as the picture is, so the window server scales it each frame and no band of ground shows. The sharp render follows 0.15 s after the size stops changing, or at once when a live resize ends (the user, 2026-11-21: "i need to release my mouse before it pops in"). Gradient's canvas stretches over its reach the same way. This holds for all three Backgrounds.

Blur draws the same picture behind the whole window, the sidebar and the tab band included, with no edge between the sidebar and the panel. `DitherArt.render` blurs the picture once per size, appearance and picture on a worker thread: close to a Gaussian of sigma 32pt (two vImage tent passes) over a canvas of 8pt pixels, which the layer scales up smoothly. At that sigma text- and icon-sized detail in the picture is gone while its colors and window-sized shapes still read. I compared 16, 32 and 64 over Sonoma: at 16 the ripple stripes in its green still read as detail, and at 64 the red wave runs into the sky. The cached image is a sixteenth of the dots' memory: 81 KB for a 1440 by 900 window, against 1 MB for Dither's dots in the panel. Then the same fade and reach as the dots apply without the steps, so no pixel strays further from the background than the brightest dot does, and the dim, scrim and veil are Dither's. Nothing redraws while a thread scrolls or streams. The sidebar's text, muted text and icons take the same 4.6:1 floor, since they sit on the picture too. The new-thread reveal does not play in Blur.

In both modes the rows fade out above the tab band's 52 and are back in full 16 below it, through the timeline's mask, so nothing runs under the header pill and no header bar shows, which the user removed from every theme (324b6bcf). The mask leaves the picture itself in that clear top. The only visible fade is the band's color over the window's top 20pt (`DitherArtView.topBlend`, Picture and Gradient; Blur shows the picture there). It reached the band's whole 52 until 2026-11-21, a grey slab under the title the user removed ("lets remove this early fade i only want the one up here"), and it covered the top of Gradient's dots. The thread's project and title sit there on the lane's left edge, on the pill's centre line, and hide while tabs show, since the tab names the thread.

The right panel is a card 8pt in from the thread and the window's top, right and bottom edges. Its tabs share the card's top row with the header pill (the user, 2026-11-21: "if we are going to have a floating popup then we dont need this at the top"). `CardTopRow` lays the row out: 32 tall, the pill 2pt in from the card's top and right so its 6pt corner runs parallel to the card's 8, the maximize button 8 left of the pill, and the tabs from 4pt in at the left up to 8 before maximize, 24pt controls on the pill's centre line. Before this the card left a 44pt empty strip under the pill and started its content at 96; it now starts at 40. When the pill and maximize leave the tabs less than one 60pt tab and the + (`minTabRoom`, 88), the tabs drop to a second 32pt row under the pill instead. Overflowing tabs fade at the edge where more sit and scroll with the wheel, the + stays put right after them, and the arrows show only when they leave room for one tab. A narrower strip scrolls the active tab back into view. The row lies in the window's tab band, outside the thread view's bounds, so `DitherTabStripView.passThrough` hands clicks on the band's empty space to the card. The pill glides into the card's corner with the panel, `Motion.large` in and `Motion.fast` out. The thread's inset card can use the same `CardTopRow`.

The terminal drawer is a card too (the user, 2026-11-21: "you think a floating terminal looks better?"). It keeps T3's span, under the thread only, so it never runs under the right panel: `Space.s` from the sidebar, the window's bottom and right edge, or from the right panel's card when that shows, whose bottom it shares. Solid, the rim, `Radius.panel` corners clipping the terminals, and the terminal text at the same 8pt inset as the right panel's terminal tab. Its four actions sit in the card's top row as 24pt buttons at `Radius.control`, placed by `CardTopRow`; with two or more terminals the list joins the grid on a hairline inside the card and the row sits over the list's top. The height handle fills the gap above the card with a centred line, taps at the minimum and maximum, and counts from the card's height when the drag started. The thread reaches down to the card's top, so the composer's pill row keeps the 20pt it has above the window's foot. With Panel animations off it opens with `RedesignMotion.panel` along y and closes as a still image, as the right panel does; Reduce Motion fades. While the keyboard is in a terminal the rim takes the accent at `Surface.focusRim`, 0.4. The Flower keeps clear of the card.

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

Text keeps its values. Body #f5f5f5 is 18.4:1 on the ground and 16.9:1 on a menu or card; muted #aaaaab is 8.6:1 on the ground and 7.9:1 on a menu or card (it was 7.0:1 on the old #202021). Light got its own palette on 2026-11-21: an off-white ground, a darker sidebar, white cards, quiet dividers and a white-card segmented selection. The values and their contrast are in `docs/research/redesign-light-audit-2026-11-21.md`.

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
| Picture | Dark | 15.4:1 | 7.2:1 | flat, unchanged | flat, unchanged |
| Picture | Light | 7.0:1 or more | 4.5:1 or more | flat, unchanged | flat, unchanged |
| Blur | Dark | 8.2:1 | 4.8:1 | 7.2:1 | 4.7:1 |
| Blur | Light | 13.4:1 | 5.5:1 | 13.1:1 | 5.3:1 |

The sidebar's icons measure 4.7:1 in both appearances over Blur. Body text stays far above 4.5:1 there, so Blur needs no stronger dim or veil. Picture's rows are its own floor, measured at the worst cell behind the column (`PictureInkTests.textKeepsItsFloorsBehindTheColumn`).

## Glass

Glass shares none of the changed paths: `DesignGeometry.radius`, the popup and toast shadows, the cards and the table inset all branch on Redesign alone, and the Blur checks in `WindowGlass` and `SidebarLayoutView` read `ThemeRuntime.ditherBlur`, which only Redesign sets. Glass draws as it did.
