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
- The sidebar's account row is concentric with the window, `nested(in: window, inset: 8)`, so 8.
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

Three choices, the client setting `redesignBackground`: `dither` (labelled Picture, the default), `blur` and `gradient`.

Gradient is the user's "a dither option without an image like capy does here" (capy-dither-no-image.mov). No picture: on the new-thread page a halftone in the accent (`palette.primary`) starts at the panel's top left and fades to the ground about two thirds across and over half way down. The dots sit on a 3pt grid and are 2pt, then 1pt, then gone as the strength falls, in Bayer order, each the accent at 22% to 45% over the ground in dark (12% to 30% in light). A thread, Settings and every other page show the plain ground; the art layer hides there, with no scrim. The canvas is 1pt per pixel and covers only the top left 75% by 60% of the panel, so a 1100 by 850 panel holds about 1.6 MB. It renders once per size, appearance and accent on a worker, like the picture; a hidden or miniaturized window drops it. The new-thread reveal plays as in Picture. Settings > Redesign marks Picture and Background dim inert while Gradient is on.

The user chose, after seeing a glass card behind the conversation on 2026-11-21: "no glass card either full blur or full dither". Nothing sits behind the conversation in either mode. The setting is the client setting `redesignBackground`, `dither` by default.

Dither is 1.15.1's background: the picture in 2pt ordered-dither dots in the main panel only, under the "Background dim" scrim and the faint veil behind the chat lane, with the sidebar and the tab band flat. Its readability rules are unchanged: muted text keeps 4.6:1 over the brightest (dark) or darkest (light) dot behind the lane.

Blur draws the same picture behind the whole window, the sidebar and the tab band included, with no edge between the sidebar and the panel. `DitherArt.render` blurs the picture once per size, appearance and picture on a worker thread: close to a Gaussian of sigma 32pt (two vImage tent passes) over a canvas of 8pt pixels, which the layer scales up smoothly. At that sigma text- and icon-sized detail in the picture is gone while its colors and window-sized shapes still read. I compared 16, 32 and 64 over Sonoma: at 16 the ripple stripes in its green still read as detail, and at 64 the red wave runs into the sky. The cached image is a sixteenth of the dots' memory: 81 KB for a 1440 by 900 window, against 1 MB for Dither's dots in the panel. Then the same fade and reach as the dots apply without the steps, so no pixel strays further from the background than the brightest dot does, and the dim, scrim and veil are Dither's. Nothing redraws while a thread scrolls or streams. The sidebar's text, muted text and icons take the same 4.6:1 floor, since they sit on the picture too. The new-thread reveal does not play in Blur.

In both modes the rows fade out above the tab band's 52 and are back in full 16 below it, through the timeline's mask, so nothing runs under the header pill and no header bar shows, which the user removed from every theme (324b6bcf). The mask leaves the picture itself in that clear top. The thread's project and title sit there on the lane's left edge, on the pill's centre line, and hide while tabs show, since the tab names the thread.

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
| Hover | text color at `State.hover` 0.06 (dark) or 0.042 (light), 150 ms |
| Pressed | text color at `State.pressed` 0.1 or 0.07, while held or while its menu is open |
| Selected | text color at `State.selected` 0.1, or the palette's `sidebarRowSelected` in the sidebar |
| Focus | the accent ring T3 draws (`BoxShadow.focusRing`), only for keyboard focus, never with an underline |

Hover clears through `HoverSync` when the pointer leaves, when the window loses key and when content scrolls under a still pointer.

## Motion

One curve, `cubic-bezier(0.23, 1, 0.32, 1)` (`Motion.curve`). Hover and press take `Motion.quick`, 150 ms. Pills and popovers that appear rise `Motion.rise`, 4pt, and fade in over 150 ms. Under Reduce Motion they appear without moving. Nothing animates at rest.

## Measured contrast

Measured on 2026-11-21 from the rendered art at the default 35% dim, against the worst pixel behind the lane (x 500 to 1200 of a 1400 by 900 window, under the scrim and veil) and, in Blur, behind the sidebar (x 0 to 280, no veil): the brightest in dark, the darkest in light. Pictures: iMac Silver (brightest), Radial Sky Blue (darkest) and Sonoma (busy), from /System/Library/Desktop Pictures. The worst of the three:

| Mode | Appearance | Lane body | Lane muted | Sidebar text | Sidebar muted |
|---|---|---|---|---|---|
| Dither | Dark | 8.0:1 | 4.6:1 | flat, unchanged | flat, unchanged |
| Dither | Light | 13.3:1 | 5.5:1 | flat, unchanged | flat, unchanged |
| Blur | Dark | 8.2:1 | 4.8:1 | 7.2:1 | 4.7:1 |
| Blur | Light | 13.4:1 | 5.5:1 | 13.1:1 | 5.3:1 |

The sidebar's icons measure 4.7:1 in both appearances. Blur never goes under Dither, since the blur averages the dots and the reach caps both. Body text stays far above 4.5:1, so Blur needs no stronger dim or veil.

## Glass

Glass shares none of the changed paths: `DesignGeometry.radius`, the popup and toast shadows, the cards and the table inset all branch on Redesign alone, and the Blur checks in `WindowGlass` and `SidebarLayoutView` read `ThemeRuntime.ditherBlur`, which only Redesign sets. Glass draws as it did.
