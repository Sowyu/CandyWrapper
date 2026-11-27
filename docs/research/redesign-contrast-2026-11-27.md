# Redesign contrast and legibility, 2026-11-27

The X8 row of the round-2 rubric (`~/CandyWrapper-research/sandbox/redesign-review-2026-11-26/rubric.md`) asks for the lowest contrast of every kind of text and icon against what is really behind it, in dark and light, over Picture, Blur and Flower. The floors are body text 7:1, muted text and icons 4.5:1, and a control's edge 3:1.

## How I measured

1. I shot real windows of a test app at 1100 by 780pt, 2x, with `--snapshot`, over the sandbox thread "Add tests for unit conversions", the Sonoma Horizon picture for Picture and Blur, and Settings > General.
2. `contrast` (in `~/CandyWrapper-research/sandbox/redesign-review-2026-11-26/build/flower-thread/`, source `contrast.swift`) takes a region of a picture, calls its most common color the ground and reports the pixel farthest from it in luminance as the ink, with its coordinates. `rowdump.swift` prints a row of pixels to find rims and switch tracks.
3. The regions are in `regions-thread.txt` beside it. Pixel coordinates below are in the 2200 by 1560 picture.

A sampled ink is the darkest or lightest antialiased pixel, so thin text reads a little under its token color: light body text, #171717 at 0.8, samples near #4e4e4e. Where that matters the table gives the token ratio as well.

## Placeholder and disabled text

Placeholders are held to muted text's 4.5:1, as the brief asks. Disabled controls are held to 3:1: WCAG 1.4.3 exempts inactive components, and macOS draws disabled labels dim (`disabledControlTextColor`), so I applied a control edge's floor, not text's. The empty composer's send button is the one disabled control in these pictures.

## Before and after

Before is round 1 (`round-1/*.png`); after is this branch (`build/flower-thread/after-*.png`).

The lowest of the three backgrounds for each kind. Pictures: F is `after-thread-1100`, P `after-picture-thread-1100`, B `after-blur-thread-1100` and S `after-settings-general` in `build/flower-thread/`; the round-1 pictures are `W6-thread-flower`, `W3-thread-picture-busy`, `W4-thread-blur` and `G1-settings-general`.

| Kind | Floor | Dark before | Dark after | Light before | Light after | Where (pixel, picture) |
|---|---|---|---|---|---|---|
| Body text (sampled ink) | 7 | 9.9 | 9.9 | 7.0 | 7.0 | (1246,467) and (739,467), B |
| Muted text, "Worked for 3.3s" | 4.5 | 6.6 | 6.6 | 5.4 | 5.4 | (633,345) and (687,319), B |
| Placeholder, "Ask anything" | 4.5 | **3.1** | 5.3 | 6.5 | 6.6 | (950,1316), P and F |
| Sidebar meta and section label | 4.5 | 5.5 | 5.5 | 5.3 | 5.3 | (48,1234), F and B |
| Sidebar icons (Threads filter) | 4.5 | **2.6** | 5.7 | **4.2** | 4.8 | (400,508) before, (405,506) after; F, and B for light |
| Composer and header icons | 4.5 | 8.5 | 8.6 | 6.5 | 6.6 | (669,1372), F |
| Diff count "+59", header pill | 4.5 | 7.8 | 7.8 | **2.4** | 5.3 | (2036,53), F |
| Diff count "−1", header pill | 4.5 | 5.4 | 5.4 | **3.7** | 7.4 | (2086,54), F |
| Status chips (Done, Input, Approval) | 4.5 | 5.4 | 5.4 | 5.9 | 5.9 | `S2-sidebar-many-threads` (465,1232) |
| Text on the accent, "Open thread" | 4.5 | **3.7** | 5.1 | 4.6 | 4.6 | `before-thread-960.dark` (1669,224); after from the tokens, every accent in `RedesignContrastFloorTests` |
| Off switch track on its card | 3 | **1.5** | 3.4 | **2.7** | 3.4 | (1989,554), S |
| Disabled send button's arrow | 3 | 3.6 | 3.6 | **2.5** | 2.5 | (2041,1372), F |
| Composer rim (a control edge) | 3 | **1.4** | 1.4 | **1.1** | 1.1 | (624,1400), F |
| Selected sidebar row fill | none | 1.3 | 1.3 | 1.2 | 1.2 | `S2-sidebar-many-threads` (100,1030) |

Body text in a reply is the text color at 0.8 (`ThreadDesign.markdownBody`). In light that composes to about #4a4a4a, 7.2:1 over light Blur's ground and 7.0 at a glyph's sampled edge, so it passes with no margin. Over the Flower's column the cap (`LotusArt.columnCap`) keeps the worst cell at the floors by construction, 12:1 and 6:1 in dark, 7:1 and 4.5:1 in light, and `FlowerArtTests.columnKeepsTheTextFloorsInBothAppearances` checks that for every accent.

## Tokens that moved

- Dark `placeholder` #616162 to #868687: 3.1:1 on the composer, now 5.3:1 (4.6:1 on the #1e1e1e user bubble).
- Dark `iconMuted` #686869 to #868687, and dark `--sidebar-icon-color` now takes `iconMuted`, as light already did: the Threads row's filter and new-folder icons were #505051 at 2.6:1.
- Light `iconMuted` #737371 to #646462: 4.2:1 on the sidebar, now 5.2:1, and 4.9:1 over light Blur's darkest sidebar ground.
- Light `--diff-addition` and `--diff-deletion` take success (#0e7a50) and the error text color (#a80005): the header pill's "+59 −1" was 2.4 and 3.7:1 on white, now 5.3 and 7.4:1. Dark keeps T3's (7.9 and 5.5:1).
- `DitherAccent.foreground`: white only at 4.5:1 or better, else #111111. White on dark teal was 3.7:1 ("Open thread", the send button); dark teal, blue, violet, pink, red, orange and green now carry the near-black label, light keeps white on its darkened accent.
- `RedesignTokens.Control.offTrackDark` #6b6b6d and `offTrackLight` #8a8a87 for an off switch: Capy's #353537 was 1.5:1 on the dark Settings card and T3's light track 2.7:1.

Surfaces that use these roles change with them: the composer's placeholder and its icons, the sidebar's menu icons, every primary button's label in dark, and every off switch. The composer footer and the message rail belong to another agent today; their muted icons read `iconMuted`, so they brighten in dark too.

## Left under a floor, on purpose or for the user

- Surface rims are 0.08 of the text color in dark (#292c2c on #080808, 1.4:1) and 0.12 in light (1.13:1). The composer is a control and its rim is far under 3:1. Raising the shared rim to 3:1 would put a #5f5f5f outline around every card, which round 0 and the user's rim choices moved away from, so I left it. The composer still reads by its raised fill, its shadow and its placeholder. This is the user's call.
- Selected and hover row fills are 1.3:1 (dark) and 1.2:1 (light) against the sidebar. The selected row also has full-strength text against the muted text of the rows around it, so the state never rests on the fill alone.
- The sidebar's top and bottom scroll fades take rows under them down to 3.1:1 at the very edge. That is content scrolling out of view.
- Light's segmented control selects with a white card on a #f0f0f0 track, about 1.1:1, plus the rim and shadow.
- Light's disabled send button draws its arrow at 2.5:1, under the 3:1 I hold disabled controls to. It lives in `Features/Composer`, which another agent has today.
- Light body text passes 7:1 with no margin over Blur (above). Raising `ThreadDesign.markdownBody` from 0.8 to 0.88 in Redesign light would give 10:1, and moves every light thread picture.

## Round 3, after the round-2 review (2026-11-27)

The three round-2 reviewers measured what this branch had left. These are the tokens and draws I moved for them. The ratios are worked from the token colors over the plain ground that Redesign is moving to, and each one is held by a test.

| Kind | Floor | Before | After | Held by |
|---|---|---|---|---|
| Label on the default dark teal (send, Approve, Merge, Ship it) | 4.5 | 3.7 white | 5.1 #111111 | `RedesignContrastFloorTests.accentLabelsReadInTheResolvedPalette` |
| Label on a filled destructive button, dark and light | 4.5 | 3.5 and 3.7 white | 4.6 white on a deeper red | `destructiveFillKeepsWhiteAtFourAndAHalf` |
| Usage "30 days" on Limits, light (disabled) | 3 | 2.65 | hidden in place | `UsagePageView` |
| Usage "87%" on the open share, dark | 4.5 | 4.3 | about 5.3 | `RedesignTokens.Meter.poolOpenDark` |
| Empty radio or checkbox edge, dark | 3 | 1.3 | 3.4 | `emptyRadioEdgeReads` |
| File link in a reply, dark and light | 4.5 | 4.1 and 3.4 | 7.1 and 5.7 on the chip's fill | `accentTextReadsOnItsChips` |
| Message rail's resting strip on the ground, light | 3 | 2.7 | 3.0 | `ThreadMinimapHoverTests` |
| Selected sidebar and Settings row, light | none | 1.16 | 1.31 | the palette |

Tokens that moved:

- `ThemeLibrary` merges the accent's roles for teal too, and the base dark palette's `accentForeground` and `messageActionForeground` are #111111, so the default teal follows `DitherAccent.foreground` like every other accent (docs/decisions.md, 2026-11-27).
- `RedesignTokens.Destructive.fill`: the palette's red darkened in its hue until white reads 4.6:1, for filled destructive buttons and badges. The red of text and icons stays.
- `RedesignTokens.Meter.poolOpenDark` 0.28: the open share of a usage limit in dark. Light keeps T3's 0.35.
- `RedesignTokens.Control.offTrackDark` and `offTrackLight` now also edge an empty radio or checkbox.
- `DitherAccent.text`: the accent a quarter toward white in dark and a fifth toward black in light, for file links.
- `ThreadMinimapView.restingBoost` 1.6 to 1.9.
- Light `sidebarRowSelected` and `sidebarRowActive` #00000012 to #0000001f.

Where a floor and the look pulled apart:

- Light outline buttons with a label (Add environment, New terminal, Retry connection) drew their edge in the control outline, #8a8a87 at 3.4:1, and every reviewer read them as heavy boxes. Their edge is now `Surface.strongRim` in black, about 1.8:1, which is under the 3:1 I hold control edges to. The label names the button, so WCAG 1.4.11 does not need the edge, and hover brings the full outline back. Icon-only outline buttons keep 3:1.
- The composer's rim (1.2 to 1.4:1) and light's disabled send arrow (2.5:1) are still under their floors. Both live in `Features/Composer`, which another agent has today.
- Light body text stays at 0.8 of the text color. On the plain ground it is about 9:1, so the 0.88 above is not needed once the picture goes.
