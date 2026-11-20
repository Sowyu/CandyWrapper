# Redesign system

Redesign is a picture behind the app, dithered, with content on blurred glass. This page fixes the values every Redesign surface and control uses. They live in code as `RedesignTokens` in `Packages/CandyKit/Sources/DesignSystem/Theme/RedesignTokens.swift`, and `RedesignTokenGuardTests` fails when Redesign drawing code writes a corner radius, a shadow or a surface opacity anywhere else. The audit that led here is `docs/research/redesign-audit-2026-11-20.md`. Redesign is CandyWrapper's own look, so nothing here is checked against T3.

## Radius

| Token | Value | Used for |
|---|---|---|
| `Radius.control` | 8 | buttons, inputs, rows, tabs, chips, the 30pt pills, the header pill |
| `Radius.card` | 12 | cards, user bubbles, code blocks, tables, banners, menus and popovers |
| `Radius.panel` | 16 | the composer, the reading column, the details card, the content panel, modals |
| `Radius.window` | 16 | the window's own corner, measured on macOS 27, so the content panel inside it is concentric |

A shape inset inside another takes `Radius.nested(in: outer, inset:)`, the outer radius less the inset, never under 2. A pill row sits 8 inside the composer, so 16 less 8 is the pills' 8. Dots, rings and lines with round ends take `Radius.capsule(height)`, half their height. That is a shape, not a step on the scale. The audit's 10, 3.5, 3 and 1.5 are gone: the Settings nav row is 8, and the dots and the usage bar are capsules.

## Spacing

4, 8, 12, 16, 24 and 32 between things, with 2, 6, 10 and 14 inside a control. `Space.pill` is 30, a pill's height, which is a size and not a gap. The reading column sits `Space.l` (16) wider than the lane on each side and `Space.s` (8) in from the window's top and the panel's bottom. Pills keep the 8 gap between rows and the 6 gap inside a row the user shaped on 2026-10-22.

## Type

The UI font at 400 and 500. Body text is 14, row titles and the thread title 13, meta text and captions 12, and labels in a pill 12. The thread title in the band is the project at 13 in the muted color, a slash, and the title at 13 and 500 in the text color. Size and color carry the hierarchy. Nothing in Redesign is drawn at 600 or heavier.

## Shadows

| Token | y | CALayer radius (CSS blur) | Opacity dark / light | Used for |
|---|---|---|---|---|
| `Shadow.resting` | 2 | 4 (8) | 0.28 / 0.08 | surfaces that rest on the picture: the composer, the pills, the header pill, cards on the art, the reading column |
| `Shadow.floating` | 8 | 12 (24) | 0.45 / 0.12 | layers over content: menus, popovers, the project menu, tooltips, toasts |

Dark needs more opacity because a light shadow vanishes on a dark picture. A surface never draws a shadow and a border that do the same job: the rim gives the edge and the shadow gives the lift. Cards inside the reading column draw no shadow, since they do not float.

## Surfaces

Every glass surface is a 12pt backdrop blur (`Tokens.LengthPx.glassBlur`), a fill and a 1pt rim on continuous corners.

| Recipe | Blur | Fill | Rim | Shadow | Reduce Transparency |
|---|---|---|---|---|---|
| Resting glass | 12 | `surfaceRaised` (dark) or `card` (light) at `Surface.resting` 0.62 | text color at 0.08 | resting | blur off, fill opaque |
| Floating glass | 12 | `popover` at `Surface.floating` 0.82 | text color at 0.08 | floating | blur off, fill opaque |
| Card on a surface | none | text color at `Surface.inset` 0.05 | text color at 0.08 | none | unchanged, it sits on an opaque surface |

Increase Contrast raises the rim to 0.24. Floating layers take the higher fill because they cover sharp text that a 0.62 tint lets read through.

A blur is allocated only where this table says a surface has one: resting and floating glass. Cards on a surface never get their own blur. The reading column's one blur replaces the blur each user bubble used to allocate.

## Reading column

An open thread draws one resting glass surface behind the lane the messages and the composer share, 16 wider than the lane on each side, so the picture shows around it. Assistant text, tool rows, the work log, command output, code blocks, tables and user bubbles sit on it. Code blocks, tables and user bubbles are cards on that surface. The composer, the question card and the approval card float over it as resting glass.

The rows fade out at the column's top: gone above the tab band's 52, back in full 16 below it, through the timeline's mask. Nothing runs under the header pill, and there is no header bar, which the user removed from every theme (324b6bcf). I tried a frosted band with a progressive blur first; it ended in a visible hard edge and read as a bar. The thread's project and title sit in the column's clear top on the lane's left edge, on the pill's centre line, and hide while tabs show, since the tab names the thread.

I tried a stronger veil, 0.55 of the background behind the lane, against the column. The choice and the measurements are in "Choosing the column" below.

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

## Choosing the column

I put both over the busy picture (Sonoma Horizon) in dark, in the same thread. The 0.55 veil leaves the dither dots sharp behind every letter, so the text sits on noise, and the rows still run under the header pill. The column blurs the dots into soft color, gives code blocks and tables a surface to sit on, and needs one blur instead of one per user bubble. I chose the column.

Measured on screen at 1x, from the column's brightest point in dark and its darkest point in light, over the brightest picture (iMac Silver), the darkest (Radial Sky Blue) and the busy one:

| Appearance | Column behind text, worst | Body text | Ratio | Muted text | Ratio |
|---|---|---|---|---|---|
| Dark | #3d3e41, L 0.049, iMac Silver | #d6d6d7 | 7.3:1 | #c8c8c8 | 6.4:1 |
| Light | #f7f7f7, L 0.931, Radial Sky Blue | #5c5c5c or darker | 6.2:1 | #5a5a5a (palette) | 6.4:1 |

The light body figure is the lightest core pixel of a 1x glyph, so the real ratio is higher.

## Glass

Glass shares none of the changed paths: `DesignGeometry.radius`, the popup and toast shadows, the bubble cards and the table inset all branch on Redesign alone, and the bubble blur removed from `WindowGlass` was Redesign's. Glass draws as it did.
