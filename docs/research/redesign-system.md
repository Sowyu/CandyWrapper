# Redesign system

Redesign is a picture behind the app, dithered or blurred ("Background" in Settings > Redesign), with the conversation straight on it and the composer, pills and menus on glass. This page fixes the values every Redesign surface and control uses. They live in code as `RedesignTokens` in `Packages/CandyKit/Sources/DesignSystem/Theme/RedesignTokens.swift`, and `RedesignTokenGuardTests` fails when Redesign drawing code writes a corner radius, a shadow or a surface opacity anywhere else. The audit that led here is `docs/research/redesign-audit-2026-11-20.md`. Redesign is CandyWrapper's own look, so nothing here is checked against T3.

## Radius

| Token | Value | Used for |
|---|---|---|
| `Radius.control` | 8 | buttons, inputs, rows, tabs, chips, the 30pt pills, the header pill |
| `Radius.card` | 12 | cards, user bubbles, code blocks, tables, banners, menus and popovers |
| `Radius.panel` | 16 | the composer, the details card, the content panel, modals |
| `Radius.window` | 16 | the window's own corner, measured on macOS 27, so the content panel inside it is concentric |

A shape inset inside another takes `Radius.nested(in: outer, inset:)`, the outer radius less the inset, never under 2. A pill row sits 8 inside the composer, so 16 less 8 is the pills' 8. Dots, rings and lines with round ends take `Radius.capsule(height)`, half their height. That is a shape, not a step on the scale. The audit's 10, 3.5, 3 and 1.5 are gone: the Settings nav row is 8, and the dots and the usage bar are capsules.

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

Every glass surface is a 12pt backdrop blur (`Tokens.LengthPx.glassBlur`), a fill and a 1pt rim on continuous corners.

| Recipe | Blur | Fill | Rim | Shadow | Reduce Transparency |
|---|---|---|---|---|---|
| Resting glass | 12 | `surfaceRaised` (dark) or `card` (light) at `Surface.resting` 0.62 | text color at 0.08 | resting | blur off, fill opaque |
| Floating glass | 12 | `popover` at `Surface.floating` 0.82 | text color at 0.08 | floating | blur off, fill opaque |
| Card on a surface | none | text color at `Surface.inset` 0.05 | text color at 0.08 | none | unchanged, it sits on an opaque surface |

Increase Contrast raises the rim to 0.24. Floating layers take the higher fill because they cover sharp text that a 0.62 tint lets read through.

A blur is allocated only where this table says a surface has one: resting and floating glass. Cards on a surface never get their own blur. In Dither a user bubble keeps its own blur, as in 1.15.1. In Blur it has none, since the picture behind it is soft already.

## Backgrounds

The user chose, after seeing a glass card behind the conversation on 2026-11-21: "no glass card either full blur or full dither". Nothing sits behind the conversation in either mode. The setting is the client setting `redesignBackground`, `dither` by default.

Dither is 1.15.1's background: the picture in 2pt ordered-dither dots in the main panel only, under the "Background dim" scrim and the faint veil behind the chat lane, with the sidebar and the tab band flat. Its readability rules are unchanged: muted text keeps 4.6:1 over the brightest (dark) or darkest (light) dot behind the lane.

Blur draws the same picture behind the whole window, the sidebar and the tab band included, with no edge between the sidebar and the panel. `DitherArt.render` blurs the picture once per size, appearance and picture on a worker thread: close to a Gaussian of sigma 32pt (two vImage tent passes) over a canvas of 8pt pixels, which the layer scales up smoothly. At that sigma text- and icon-sized detail in the picture is gone while its colors and window-sized shapes still read. I compared 16, 32 and 64 over Sonoma: at 16 the ripple stripes in its green still read as detail, and at 64 the red wave runs into the sky. The cached image is a sixteenth of the dots' memory: 81 KB for a 1440 by 900 window, against 1 MB for Dither's dots in the panel. Then the same fade and reach as the dots apply without the steps, so no pixel strays further from the background than the brightest dot does, and the dim, scrim and veil are Dither's. Nothing redraws while a thread scrolls or streams. The sidebar's text, muted text and icons take the same 4.6:1 floor, since they sit on the picture too. The new-thread reveal does not play in Blur.

In both modes the rows fade out above the tab band's 52 and are back in full 16 below it, through the timeline's mask, so nothing runs under the header pill and no header bar shows, which the user removed from every theme (324b6bcf). The mask leaves the picture itself in that clear top. The thread's project and title sit there on the lane's left edge, on the pill's centre line, and hide while tabs show, since the tab names the thread.

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
