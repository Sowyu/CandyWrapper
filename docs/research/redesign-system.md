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

## Sidebar

The sidebar is the quietest part of the window, after Capy (the user, 2026-11-26: "i want to make it more like a real app"). Nav labels and thread titles are 13 at 400 in the text color at `Text.quiet` 0.72, icons in the muted color, and hover or the selected row brings both to full strength over the row fill. Nav labels, project names and one-line titles share one edge 40pt in (8 padding, 8 inset, the 16pt icon column, `Space.s`). A project header sits a row pitch plus `Space.s` below the row above it. With One line every row is 30pt from the next, centre to centre (a 29pt row with a 28pt fill at its top, plus the list's 1pt gap, as the nav rows' 28 and 2), and a header is one row pitch above its first thread. Thread rows are two lines by default, the title over the environment and provider, with "Done" muted and color kept for Input and Approval (the user saw both styles on 2026-11-26: "keep 2 lines default"). Settings > Redesign > Sidebar rows offers One line: the icon column holds the project icon, or the current provider's glyph under a project header, then the title, at 500 in the full text color only when the thread is unread or waits on the user, then the status and the age in muted 12pt tabular figures. There status is color only where the user is needed: Input and Request a glyph in info, Approval and Limited in warning, Failed in error, the dot grid and its timer while a turn runs, and nothing for Done. The environment stays in the hover card either way.

## Shadows

| Token | y | CALayer radius (CSS blur) | Opacity dark / light | Used for |
|---|---|---|---|---|
| `Shadow.resting` | 2 | 4 (8) | 0.28 / 0.08 | surfaces that rest on the ground: the composer, the pills, the header pill |
| `Shadow.floating` | 8 | 12 (24) | 0.45 / 0.12 | layers over content: menus, popovers, the project menu, tooltips, toasts |

Dark needs more opacity because a light shadow vanishes on near-black. A surface never draws a shadow and a border that do the same job: the rim gives the edge and the shadow gives the lift. Code blocks, tables and the changed-files card draw no shadow, since they do not float.

## Surfaces

The user, 2026-11-21: "in redesign no more blurs its no premium", about the thread menu. Every surface is opaque: a solid fill, a 1pt rim in the text color at 0.08 in dark and 0.12 in light (`Surface.rimLight`, since 2026-11-26: at 0.08 the light inset card and Settings dissolved into the off-white beside them, round 1, W7) and 0.24 under Increase Contrast, on its corner, and the token shadow.

| Surface | Fill (dark) | Fill (light) | Shadow |
|---|---|---|---|
| Ground (main panel) | `canvas` #080808 | `canvas` #f8f8f7 | none |
| Sidebar, band, chrome | #030303 | #f1f1ef | none |
| Resting: the composer, pills, the header pill, the details card | `surfaceRaised` #0f0f0f | `card` #ffffff | resting |
| Floating: menus, popovers, pickers, tooltips, the command palette | `popover` from `surfaceOverlay` #141414 | #ffffff | floating |
| Modal: Settings and Usage | the ground, #080808 | #f8f8f7 | the modal's |
| Card on the ground or a modal: code blocks, tables, Settings cards, the changed-files card | white at 0.05 over the ground, #141414 | `card` in Settings, black at 0.05 over the ground elsewhere | none |

The user bubble and inline code are opaque in light too: `WindowGlass.frosted` used to turn `--message-surface` and `--muted` into black overlays, so the picture's dots showed through a bubble's text and a code chip (round-0 review, W7 and T1). They left `WindowGlass.tintMembers` on 2026-11-26. The bubble draws the surface rim under Redesign, so its edge reads on light ground and over the art. Inline code is a fill with no rim, in a bubble, a card, a table or on the ground, so it never stacks a rim inside one.

The scrim behind a modal or the command palette is the ground at 0.72 (dark) or 0.6 (light), with no blurred snapshot (`ModalHost.blurredSnapshot` returns nil under Redesign).

The no-blur rule lives in four places: `BackdropBlurView` sets its alpha to 0 under Redesign, so a blur view that T3's own look allocates (the composer, the banners) composites nothing; `WindowGlass.syncPaneBlur` only adds a pane blur for Glass; `WindowGlass.frosted(panes: false)` keeps Redesign's palette surfaces opaque; and Redesign-only views (`DitherPillSurface`, the tab strip, the details card, user bubbles) hold no blur view at all. Glass is untouched. "Glass opacity" still drives Glass and the default themes' dropdown glass; under Redesign it changes nothing.

Measured with the sandbox's thread open in dark on 2026-11-21: 24 `BackdropBlurView`s alive before, 14 after, and all 14 at alpha 0.
## Backgrounds

Redesign has one background, Gradient. The user, 2026-11-27, after two days of review rounds that kept failing on text and controls sitting on art: "should we get rid of flower and get rid of photo and just do one officially supported like capy so its easy to have good ui", then "lets just only do the gradient theme". Picture, Blur and Flower are gone with their settings (Background, Picture, Ink, Dot size, Tint from picture, Flower on a thread, Dim behind text, Ignore Reduce Transparency). Their stored values, `redesignBackground` among them, stay in the settings file and nothing reads them. The one setting left is Settings > Redesign > Look > Animate background (`redesignGradientAnimate`, on by default). The target is Capy's new-thread page and thread (`sandbox/redesign-user-notes/capy-real-dark-new-thread.png`, `capy-real-dark-thread.png`): a halftone across the top of the new-thread panel that fades to near-black well above the composer, and a thread on plain near-black with nothing behind the text.

Gradient is the user's "a dither option without an image like capy does here" and "capys plain dither isnt just static" (capy-dither-no-image.mov). No picture. Measured frame by frame from the recording (AVAssetImageGenerator, zero tolerance, 2.75 s to 12.5 s on the new-thread page): Capy's cells are binary, one navy (about #26314b) or off, on a fixed grid of 6px at 2x (3pt). They never shift or change size; the field under them changes. A 40px patch differs by under 2 levels from frame to frame, where a moving grid would differ by about 10. Soft lobes along the top drift and swell: one moves about 37pt a second to the right, the left one rises and fades, and one at the right grows from nothing to the brightest in about 5 s. The field stays in the top 25 to 30% (its centroid) and fades out by about 45% down. It did not repeat or settle in the 9.75 s on screen.

CandyWrapper's Gradient copies that. Cells on a 3pt grid, on where the field beats the cell's 8 by 8 Bayer threshold, in one color: the accent (`palette.primary`) at 36% over the ground in dark and 24% in light. At light's earlier 32% the field read as a loud teal slab over the off-white card, far heavier than dark. The field is three Gaussian lobes along the top whose centres and strengths swing on whole turns of a 12 s loop, times a falloff of (1 - y)^1.5 down the canvas (`DitherArt.gradientFall`), less 0.04 (`gradientFloor`). A linear falloff with no floor left an even row of single cells that ended on a hard line at the canvas's foot; the faster falloff and the floor fade it out the way Capy's does. Frame 0 is strongest at the top left and thins to the right, as in Capy's screenshot.

The canvas covers the panel's width (the inset card's, when Inset panel is on) and reaches half its height down, or to 24pt above the top of the composer group (the context row and the composer, `DitherArtView.setComposer`, `DitherArt.gradientClearance`), whichever is shorter. With the floor the last cells are well above that line, so the composer always sits on plain ground. Compared at the same scale with Capy's screenshot at 1100, 1400 and 1700pt wide (`sandbox/redesign-review-2026-11-26/build/gradient-only/`): the field starts at the card's top edge in both, is gone by about a third of the way down, and fades over about the same distance.

`DitherArt.gradientFrames` renders the loop once on a worker as 96 one-byte alpha masks (8 a second), about 50 KB each for a 1400 by 900 window's card, under 5 MB in all. The view shows them through the art layer's mask, and a discrete `CAKeyframeAnimation` on the mask's contents flips them, so the app does no work per frame; the window server swaps the texture.

It moves only while every condition holds: Animate background is on, the new-thread page shows and is not hidden, the window is visible, not miniaturized or covered, and key, and Reduce Motion is off. Any one stopping removes the animation and holds the frame on screen (`DitherArtView.syncMotion`, `GradientArtTests.motionStopsWhenItCannotBeSeen`). The frames exist only while the new-thread page shows; a thread, the linked, unavailable and empty thread pages, Pull requests, Issues, Workflows, Settings, Usage and every other page drop them and show the plain ground, with no art, scrim, veil or dim. With Animate background off the page shows frame 0 still. A miniaturized or ordered-out window drops the frames too. While the panel's size changes, the cached mask stretches over the new canvas, and the sharp render follows 0.15 s after the size stops changing or at once when a live resize ends (the user, 2026-11-21: "i need to release my mouse before it pops in").

Cost, measured on the M2 Pro on 2026-11-27 with `top` over six interleaved 6 s windows each way, a 1400 by 900 window on the new-thread page in dark, in front and key, composer unfocused: the app 0.00 to 0.03% CPU with the loop running or still; the window server 9.2% on average with the loop running (8.2 to 9.8%) against 5.0% with Animate background off (4.1 to 6.2%). So the motion costs about 4 points of window server CPU while the new-thread page is in front and nothing while it isn't. An earlier attempt the same day read a thread by mistake and swung 1 to 22% with other agents' apps drawing; these runs were steady. The 2026-11-21 figure of 0.4 points came from a smaller canvas and a blinking caret in both windows.

The history: Gradient shipped in 1.16.0, became Flower's field on 2026-11-21 (ff17028b), and came back alone on 2026-11-27, restored from ff17028b^ and fitted to the inset card. Picture (the desktop picture as a two-ink dither, `PictureInk`), Blur (the picture blurred behind the whole window) and Flower (a dithered lotus, `LotusArt`) are in git history before the removal commit, with their notes in this file's history.

The rows fade out above the tab band's 52 and are back in full 16 below it, through the timeline's mask, so nothing runs under the header pill and no header bar shows, which the user removed from every theme (324b6bcf). The only visible fade is the band's color over the window's top 20pt (`DitherArtView.topBlend`), and only with Inset panel off. It reached the band's whole 52 until 2026-11-21, a grey slab under the title the user removed ("lets remove this early fade i only want the one up here"), and it covered the top of Gradient's dots. The thread's project and title sit there on the lane's left edge, on the pill's centre line, and hide while tabs show, since the tab names the thread.

The right panel is a card 8pt in from the thread and the window's top, right and bottom edges. Its tabs share the card's top row with the header pill (the user, 2026-11-21: "if we are going to have a floating popup then we dont need this at the top"). `CardTopRow` lays the row out: 32 tall, the pill 2pt in from the card's top and right so its 6pt corner runs parallel to the card's 8, the maximize button 8 left of the pill, and the tabs from 4pt in at the left up to 8 before maximize, 24pt controls on the pill's centre line. Before this the card left a 44pt empty strip under the pill and started its content at 96; it now starts at 40. When the pill and maximize leave the tabs less than one 60pt tab and the + (`minTabRoom`, 88), the tabs drop to a second 32pt row under the pill instead. Overflowing tabs fade at the edge where more sit and scroll with the wheel, the + stays put right after them, and the arrows show only when they leave room for one tab. A narrower strip scrolls the active tab back into view. The row lies in the window's tab band, outside the thread view's bounds, so `DitherTabStripView.passThrough` hands clicks on the band's empty space to the card. The pill glides into the card's corner with the panel, `Motion.large` in and `Motion.fast` out. With the inset panel off, the card floats over the thread's ground and draws the resting shadow from a view under it; with it on, the card sits beside the thread's card on the window's color and draws no shadow. The thread's inset card can use the same `CardTopRow`.

The terminal drawer is a card too (the user, 2026-11-21: "you think a floating terminal looks better?"). It keeps T3's span, under the thread only, so it never runs under the right panel: `Space.s` from the sidebar, the window's bottom and right edge, or from the right panel's card when that shows, whose bottom it shares. Solid, the rim, `Radius.panel` corners clipping the terminals, and the terminal text at the card's own inset, `Space.m`, under the title's icon, as in the right panel's terminal tab. Its four actions sit in the card's top row as 24pt buttons at `Radius.control`, placed by `CardTopRow`; with two or more terminals the list joins the grid on a hairline inside the card and the row sits over the list's top. The height handle fills the gap above the card with a centred line, taps at the minimum and maximum, and counts from the card's height when the drag started. The thread reaches down to the card's top, so the composer's pill row keeps the 20pt it has above the window's foot. It floats over the background (the user, 2026-11-26: "the crap should render behind these panels btw because its a floating panel"), which is plain ground on every page that has a drawer. With the inset panel on, the thread card keeps its full height and the drawer sits inside it, `Space.s` from the card's left, right and bottom; off, the art runs to the window's bottom behind it. The card is opaque and draws the resting shadow (`Shadow.resting`) from its own view under it, since the card clips to its corners. With Panel animations off it opens with `RedesignMotion.panel` along y and closes as a still image, as the right panel does; Reduce Motion fades. With the keyboard in a terminal the rim turns a step whiter in the text color, `Surface.keyRim` (0.16 against the resting 0.08), never the accent (the user, 2026-11-27: "not a fan of the accented outline here", then "just made the grey a little bit whiter"); the right panel's terminal tab does the same to the panel card's rim, and the block cursor turns solid as well.

The thread is a card as well when Settings > Redesign > Inset panel is on (client setting `redesignInsetPanel`, on by default), after Capy's layout (the user, 2026-11-21: "as yes thats what i was thinking about indeed" on inset-card-mock.html, "also make it a toggle"). `SidebarLayoutView` frames it: `Space.s` in from the sidebar and the window's top, bottom and right edges, `Radius.panel` continuous corners, concentric with the window's 16, and the rim drawn over the page by `InsetCardRimView`. The window around it, margins included, takes the sidebar's color. The page reports the thread card's frame (`setInsetCard`), which stops `Space.s` short of the right panel's card and of the terminal drawer's card; a page that reports nothing (Pull requests, Issues, Workflows, Settings) fills the whole card. The card's top has no band (the user, 2026-11-26, after a solid row with a hairline and then a fade into the picture: "preferably i want this", pointing at 1.19.0). The tab strip lies over the card's top, `CardTopRow.floatHeight` tall, with no ground, rule or fade. The breadcrumb and the header pill float over the page as pills with their own surface, rim and resting shadow, `CardTopRow.floatGap` (`Space.s`) in from the card's top and left, and from its top and right, or clear of the window controls while the sidebar is hidden. At that gap their 6pt corner is not concentric with the card's 8: concentric would put them 2pt from the rim, which crowds it. While the right panel shows, the header pill glides into its card's row as before and the breadcrumb stays. The timeline runs to the card's top, so the rows pass behind the pills at full strength, as decisions.md line 84 asks, with no mask; a thread at rest starts `Space.s` under the pills' band. Other pages start under `CardTopRow.rowHeight` on plain ground. Gradient draws inside the card only, because the art view takes the card's frame and corners and is its ground; the band's top blend is off. Off draws the full-bleed layout exactly, and fixtures that build their own `ThemeRuntimeInput` draw it off unless they set `insetPanel`.

## Tint from picture

Removed on 2026-11-27 with Picture and Blur, the two backgrounds it tinted from. Every surface takes the palette's own neutral value; a stored `redesignTintFromPicture` is ignored.

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

All text sits on plain ground, so its contrast is the palette's own, against the ground, cards, menus and the sidebar. The floors from `docs/research/redesign-contrast-2026-11-27.md` hold in dark and light with every accent: body 7:1, muted text, placeholders and icons 4.5:1, text on the accent 4.5:1 and a control's edge 3:1 (`RedesignContrastFloorTests`). Dark muted #aaaaab measures 8.6:1 on the ground and 7.9:1 on a card or menu; light muted #5c5c5a 6.3:1 on the ground.

Nothing in the palette compensates for art any more. `ThemeRuntime.resolve` no longer moves muted text toward white or black to clear the brightest art cell, `BackdropMarks` and the minimap's opaque marks over the art are gone, and the composer and pills lost the frosted fill they took over the Flower. The main panel's lines stay white overlays in dark and black overlays in light (`WindowGlass.frosted`), and T3's faint muted text still draws at full strength under Redesign, since both hold the floors on plain ground too. The new-thread page's cells end well above the composer group, so no text or control sits on them.

## Glass

Glass shares none of the changed paths: `DesignGeometry.radius`, the popup and toast shadows, the cards and the table inset all branch on Redesign alone. Glass draws as it did.
