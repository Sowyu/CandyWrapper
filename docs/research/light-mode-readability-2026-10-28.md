# Light mode readability, 2026-10-28

The user called light mode "the most unreadable theme ever". This note records what failed WCAG AA, what changed and what stays open. Screenshots are in `~/CandyWrapper-research/notes/light-mode-2026-10-28/`.

## Method

I dumped the resolved palettes (`ThemeRuntime.resolve`) for the default theme and Redesign before and after, and computed WCAG ratios for each text, icon and edge token against what sits behind it. Redesign's text often sits on the dither art, so the grounds include the art's darkest dot. `DitherArt.render` lets a dot stray `reach` (98 of 255) from the background, and the scrim then pulls it back by its own alpha. In light, the darkest dot was 185 gray under a thread (35% dim) and 151 on the new-thread hero, which shows the art with no scrim.

Targets: 4.5:1 for text, 3:1 for icons, control edges and the focus ring.

## What changed, Redesign light only

1. `DitherArt.lightScrim` puts a floor under light's scrims: 65% on the hero, 65% plus 35% of "Background dim" in a thread (77% at the default), and 88% in Settings. The darkest dot is now #d7d7d7 or lighter. Dark keeps its scrims.
2. Muted text, placeholders, secondary labels and the sidebar's muted text are #5a5a5a or #5c5c5c, down from #6c6c6c, #a2a2a2 and #898989. They keep 4.5:1 over the darkest dot.
3. T3's faded muted text, such as `text-muted-foreground/70`, draws at full strength in Redesign light, as it already does in Glass. At 70% it would fall back below 4.5:1.
4. Muted icons are #767676. The sidebar's menu icons, which T3 mixes toward the sidebar, take the same color.
5. Control edges (`--input`) are #858585, which gives 3:1. Dividers (`--border`, `--toolbar-border`) are #c2c2c2, darker than Capy's #dadada.
6. The accent is darkened in its own hue until white on it reads at 4.6:1 (`DitherAccent.lightAccent`). Teal goes from #0b9f95 to #07837a. White labels on buttons were at 3.26:1, and the focus ring was at 1.7:1 over the art.
7. Warning and error text are #983d00 and #a80005.
8. Code blocks use a Redesign light syntax palette (`CodeTokenKind.redesignLight`): pierre-light darkened in each hue to 4.5:1 on a code block over the art. Pierre-light's own colors ranged from 1.8 to 4.2:1 there.

Dark mode and the default themes resolve to exactly the same palettes as before. The palette dump compared every token in `stockLight`, `stockDark` and `ditherDark`.

## Deliberately left

- Redesign's dividers stay at about 1.7:1. WCAG 1.4.11 covers the edges that identify a control, and `--input` carries those at 3:1. Dividers at 3:1 would draw a dark rule between every row.
- Accent-colored small text, such as a sidebar drop target label or an open collapsible's header, reads at 3.2 to 4.4:1. It is rare and transient.
- The default light theme is T3's own palette, and CandyWrapper must match it pixel for pixel. Its text passes: muted #71717b reads at 4.6:1. Its hairlines (1.2 to 1.5:1), sidebar menu icons (2.3:1) and pierre-light syntax colors (2.1 to 4.2:1) fail, as they do in T3. Changing them needs the user's decision.

## Before and after

| Theme | Ground | Token | Needs | Before | After |
|---|---|---|---|---|---|
| Redesign light | card over settings art | `--border` | 3:1 | 1.33 | 1.69 (fails) |
| Redesign light | card pane over thread art | `--border` | 3:1 | 1.32 | 1.69 (fails) |
| Redesign light | chrome | `--border` | 3:1 | 1.32 | 1.68 (fails) |
| Redesign light | code block over thread art | `--border` | 3:1 | 1.32 | 1.69 (fails) |
| Redesign light | hero art (darkest dot) | `--border` | 3:1 | 1.28 | 1.66 (fails) |
| Redesign light | popover over thread art | `--border` | 3:1 | 1.33 | 1.69 (fails) |
| Redesign light | settings art (darkest) | `--border` | 3:1 | 1.32 | 1.68 (fails) |
| Redesign light | sidebar | `--border` | 3:1 | 1.18 | 1.51 (fails) |
| Redesign light | thread art (darkest dot) | `--border` | 3:1 | 1.30 | 1.67 (fails) |
| Redesign light | thread art (mid dot) | `--border` | 3:1 | 1.32 | 1.68 (fails) |
| Redesign light | thread art, dim 0 (darkest dot) | `--border` | 3:1 | 1.28 | 1.66 (fails) |
| Redesign light | hero art (darkest dot) | `--destructive-foreground` | 4.5:1 | 2.20 | 5.45 |
| Redesign light | thread art (darkest dot) | `--destructive-foreground` | 4.5:1 | 3.28 | 6.12 |
| Redesign light | thread art, dim 0 (darkest dot) | `--destructive-foreground` | 4.5:1 | 2.20 | 5.45 |
| Redesign light | card over settings art | `--icon-muted` | 3:1 | 2.79 | 4.33 |
| Redesign light | card pane over thread art | `--icon-muted` | 3:1 | 2.46 | 4.20 |
| Redesign light | chrome | `--icon-muted` | 3:1 | 2.54 | 3.84 |
| Redesign light | code block over thread art | `--icon-muted` | 3:1 | 2.57 | 4.06 |
| Redesign light | hero art (darkest dot) | `--icon-muted` | 3:1 | 1.03 | 3.15 |
| Redesign light | popover over thread art | `--icon-muted` | 3:1 | 2.82 | 4.43 |
| Redesign light | settings art (darkest) | `--icon-muted` | 3:1 | 2.39 | 3.89 |
| Redesign light | sidebar | `--icon-muted` | 3:1 | 2.54 | 3.84 |
| Redesign light | thread art (darkest dot) | `--icon-muted` | 3:1 | 1.53 | 3.53 |
| Redesign light | thread art (mid dot) | `--icon-muted` | 3:1 | 2.13 | 3.91 |
| Redesign light | thread art, dim 0 (darkest dot) | `--icon-muted` | 3:1 | 1.03 | 3.15 |
| Redesign light | hero art (darkest dot) | `--info-foreground` | 4.5:1 | 2.34 | 4.73 |
| Redesign light | thread art (darkest dot) | `--info-foreground` | 4.5:1 | 3.49 | 5.31 |
| Redesign light | thread art, dim 0 (darkest dot) | `--info-foreground` | 4.5:1 | 2.34 | 4.73 |
| Redesign light | card over settings art | `--input` | 3:1 | 1.41 | 3.51 |
| Redesign light | card pane over thread art | `--input` | 3:1 | 1.40 | 3.49 |
| Redesign light | chrome | `--input` | 3:1 | 1.40 | 3.44 |
| Redesign light | code block over thread art | `--input` | 3:1 | 1.40 | 3.47 |
| Redesign light | hero art (darkest dot) | `--input` | 3:1 | 1.34 | 3.30 |
| Redesign light | popover over thread art | `--input` | 3:1 | 1.41 | 3.52 |
| Redesign light | settings art (darkest) | `--input` | 3:1 | 1.40 | 3.44 |
| Redesign light | sidebar | `--input` | 3:1 | 1.25 | 3.12 |
| Redesign light | thread art (darkest dot) | `--input` | 3:1 | 1.38 | 3.38 |
| Redesign light | thread art (mid dot) | `--input` | 3:1 | 1.40 | 3.45 |
| Redesign light | thread art, dim 0 (darkest dot) | `--input` | 3:1 | 1.34 | 3.30 |
| Redesign light | card pane over thread art | `--muted-foreground` | 4.5:1 | 4.31 | 6.38 |
| Redesign light | chrome | `--muted-foreground` | 4.5:1 | 4.44 | 5.84 |
| Redesign light | hero art (darkest dot) | `--muted-foreground` | 4.5:1 | 1.80 | 4.78 |
| Redesign light | settings art (darkest) | `--muted-foreground` | 4.5:1 | 4.18 | 5.90 |
| Redesign light | sidebar | `--muted-foreground` | 4.5:1 | 4.44 | 5.84 |
| Redesign light | thread art (darkest dot) | `--muted-foreground` | 4.5:1 | 2.69 | 5.36 |
| Redesign light | thread art (mid dot) | `--muted-foreground` | 4.5:1 | 3.73 | 5.94 |
| Redesign light | thread art, dim 0 (darkest dot) | `--muted-foreground` | 4.5:1 | 1.80 | 4.78 |
| Redesign light | card over settings art | `--placeholder` | 4.5:1 | 2.38 | 6.37 |
| Redesign light | card pane over thread art | `--placeholder` | 4.5:1 | 2.10 | 6.18 |
| Redesign light | chrome | `--placeholder` | 4.5:1 | 2.16 | 5.66 |
| Redesign light | code block over thread art | `--placeholder` | 4.5:1 | 2.19 | 5.98 |
| Redesign light | hero art (darkest dot) | `--placeholder` | 4.5:1 | 1.14 | 4.63 |
| Redesign light | popover over thread art | `--placeholder` | 4.5:1 | 2.40 | 6.53 |
| Redesign light | settings art (darkest) | `--placeholder` | 4.5:1 | 2.03 | 5.72 |
| Redesign light | thread art (darkest dot) | `--placeholder` | 4.5:1 | 1.31 | 5.20 |
| Redesign light | thread art (mid dot) | `--placeholder` | 4.5:1 | 1.81 | 5.76 |
| Redesign light | thread art, dim 0 (darkest dot) | `--placeholder` | 4.5:1 | 1.14 | 4.63 |
| Redesign light | card over settings art | `--primary` | 4.5:1 | 3.05 | 4.41 (fails) |
| Redesign light | card pane over thread art | `--primary` | 4.5:1 | 2.69 | 4.28 (fails) |
| Redesign light | chrome | `--primary` | 4.5:1 | 2.77 | 3.92 (fails) |
| Redesign light | code block over thread art | `--primary` | 4.5:1 | 2.81 | 4.14 (fails) |
| Redesign light | hero art (darkest dot) | `--primary` | 4.5:1 | 1.12 | 3.21 (fails) |
| Redesign light | popover over thread art | `--primary` | 4.5:1 | 3.09 | 4.52 |
| Redesign light | settings art (darkest) | `--primary` | 4.5:1 | 2.61 | 3.96 (fails) |
| Redesign light | sidebar | `--primary` | 4.5:1 | 2.77 | 3.92 (fails) |
| Redesign light | thread art (darkest dot) | `--primary` | 4.5:1 | 1.68 | 3.60 (fails) |
| Redesign light | thread art (mid dot) | `--primary` | 4.5:1 | 2.33 | 3.98 (fails) |
| Redesign light | thread art, dim 0 (darkest dot) | `--primary` | 4.5:1 | 1.12 | 3.21 (fails) |
| Redesign light | card pane over thread art | `--ring` | 3:1 | 2.69 | 4.28 |
| Redesign light | chrome | `--ring` | 3:1 | 2.77 | 3.92 |
| Redesign light | code block over thread art | `--ring` | 3:1 | 2.81 | 4.14 |
| Redesign light | hero art (darkest dot) | `--ring` | 3:1 | 1.12 | 3.21 |
| Redesign light | settings art (darkest) | `--ring` | 3:1 | 2.61 | 3.96 |
| Redesign light | sidebar | `--ring` | 3:1 | 2.77 | 3.92 |
| Redesign light | thread art (darkest dot) | `--ring` | 3:1 | 1.68 | 3.60 |
| Redesign light | thread art (mid dot) | `--ring` | 3:1 | 2.33 | 3.98 |
| Redesign light | thread art, dim 0 (darkest dot) | `--ring` | 3:1 | 1.12 | 3.21 |
| Redesign light | card over settings art | `--secondary-label` | 4.5:1 | 3.26 | 6.37 |
| Redesign light | card pane over thread art | `--secondary-label` | 4.5:1 | 2.87 | 6.18 |
| Redesign light | chrome | `--secondary-label` | 4.5:1 | 2.96 | 5.66 |
| Redesign light | code block over thread art | `--secondary-label` | 4.5:1 | 3.00 | 5.98 |
| Redesign light | hero art (darkest dot) | `--secondary-label` | 4.5:1 | 1.20 | 4.63 |
| Redesign light | popover over thread art | `--secondary-label` | 4.5:1 | 3.29 | 6.53 |
| Redesign light | settings art (darkest) | `--secondary-label` | 4.5:1 | 2.79 | 5.72 |
| Redesign light | sidebar | `--secondary-label` | 4.5:1 | 2.96 | 5.66 |
| Redesign light | thread art (darkest dot) | `--secondary-label` | 4.5:1 | 1.79 | 5.20 |
| Redesign light | thread art (mid dot) | `--secondary-label` | 4.5:1 | 2.48 | 5.76 |
| Redesign light | thread art, dim 0 (darkest dot) | `--secondary-label` | 4.5:1 | 1.20 | 4.63 |
| Redesign light | card over settings art | `--sidebar-icon-color` | 3:1 | 2.00 | 4.33 |
| Redesign light | card pane over thread art | `--sidebar-icon-color` | 3:1 | 1.76 | 4.20 |
| Redesign light | chrome | `--sidebar-icon-color` | 3:1 | 1.82 | 3.84 |
| Redesign light | code block over thread art | `--sidebar-icon-color` | 3:1 | 1.84 | 4.06 |
| Redesign light | hero art (darkest dot) | `--sidebar-icon-color` | 3:1 | 1.36 | 3.15 |
| Redesign light | popover over thread art | `--sidebar-icon-color` | 3:1 | 2.02 | 4.43 |
| Redesign light | settings art (darkest) | `--sidebar-icon-color` | 3:1 | 1.71 | 3.89 |
| Redesign light | sidebar | `--sidebar-icon-color` | 3:1 | 1.82 | 3.84 |
| Redesign light | thread art (darkest dot) | `--sidebar-icon-color` | 3:1 | 1.10 | 3.53 |
| Redesign light | thread art (mid dot) | `--sidebar-icon-color` | 3:1 | 1.52 | 3.91 |
| Redesign light | thread art, dim 0 (darkest dot) | `--sidebar-icon-color` | 3:1 | 1.36 | 3.15 |
| Redesign light | card over settings art | `--sidebar-muted-foreground` | 4.5:1 | 3.26 | 6.37 |
| Redesign light | card pane over thread art | `--sidebar-muted-foreground` | 4.5:1 | 2.87 | 6.18 |
| Redesign light | chrome | `--sidebar-muted-foreground` | 4.5:1 | 2.96 | 5.66 |
| Redesign light | code block over thread art | `--sidebar-muted-foreground` | 4.5:1 | 3.00 | 5.98 |
| Redesign light | hero art (darkest dot) | `--sidebar-muted-foreground` | 4.5:1 | 1.20 | 4.63 |
| Redesign light | popover over thread art | `--sidebar-muted-foreground` | 4.5:1 | 3.29 | 6.53 |
| Redesign light | settings art (darkest) | `--sidebar-muted-foreground` | 4.5:1 | 2.79 | 5.72 |
| Redesign light | sidebar | `--sidebar-muted-foreground` | 4.5:1 | 2.96 | 5.66 |
| Redesign light | thread art (darkest dot) | `--sidebar-muted-foreground` | 4.5:1 | 1.79 | 5.20 |
| Redesign light | thread art (mid dot) | `--sidebar-muted-foreground` | 4.5:1 | 2.48 | 5.76 |
| Redesign light | thread art, dim 0 (darkest dot) | `--sidebar-muted-foreground` | 4.5:1 | 1.20 | 4.63 |
| Redesign light | card pane over thread art | `--warning-foreground` | 4.5:1 | 4.13 | 6.47 |
| Redesign light | chrome | `--warning-foreground` | 4.5:1 | 4.26 | 5.92 |
| Redesign light | code block over thread art | `--warning-foreground` | 4.5:1 | 4.32 | 6.25 |
| Redesign light | hero art (darkest dot) | `--warning-foreground` | 4.5:1 | 1.72 | 4.85 |
| Redesign light | settings art (darkest) | `--warning-foreground` | 4.5:1 | 4.01 | 5.99 |
| Redesign light | thread art (darkest dot) | `--warning-foreground` | 4.5:1 | 2.57 | 5.43 |
| Redesign light | thread art (mid dot) | `--warning-foreground` | 4.5:1 | 3.57 | 6.02 |
| Redesign light | thread art, dim 0 (darkest dot) | `--warning-foreground` | 4.5:1 | 1.72 | 4.85 |
| Redesign light | code block over thread art | `syntax attribute` | 4.5:1 | 2.75 | 4.67 |
| Redesign light | code block over thread art | `syntax comment` | 4.5:1 | 4.07 | 4.69 |
| Redesign light | code block over thread art | `syntax constant` | 4.5:1 | 2.59 | 4.71 |
| Redesign light | code block over thread art | `syntax constantName` | 4.5:1 | 2.30 | 4.70 |
| Redesign light | code block over thread art | `syntax decorator` | 4.5:1 | 3.37 | 4.69 |
| Redesign light | code block over thread art | `syntax escape` | 4.5:1 | 2.53 | 4.68 |
| Redesign light | code block over thread art | `syntax keyword` | 4.5:1 | 4.22 | 4.66 |
| Redesign light | code block over thread art | `syntax operator` | 4.5:1 | 1.84 | 4.73 |
| Redesign light | code block over thread art | `syntax parameter` | 4.5:1 | 1.90 | 4.72 |
| Redesign light | code block over thread art | `syntax regex` | 4.5:1 | 2.56 | 4.67 |
| Redesign light | code block over thread art | `syntax string` | 4.5:1 | 2.96 | 4.69 |
| Redesign light | code block over thread art | `syntax tag` | 4.5:1 | 3.57 | 4.67 |
| Redesign light | code block over thread art | `syntax variable` | 4.5:1 | 2.81 | 4.71 |
| Default light | bg | `--border` | 3:1 | 1.24 | 1.24 (fails) |
| Default light | card | `--border` | 3:1 | 1.27 | 1.27 (fails) |
| Default light | sidebar | `--border` | 3:1 | 1.22 | 1.22 (fails) |
| Default light | bg | `--input` | 3:1 | 1.44 | 1.44 (fails) |
| Default light | card | `--input` | 3:1 | 1.48 | 1.48 (fails) |
| Default light | sidebar | `--input` | 3:1 | 1.42 | 1.42 (fails) |
| Default light | bg | `--sidebar-icon-color` | 3:1 | 2.31 | 2.31 (fails) |
| Default light | card | `--sidebar-icon-color` | 3:1 | 2.37 | 2.37 (fails) |
| Default light | sidebar | `--sidebar-icon-color` | 3:1 | 2.27 | 2.27 (fails) |
| Default light | code block (white) | `syntax attribute` | 4.5:1 | 3.20 | 3.20 (fails) |
| Default light | code block (white) | `syntax constant` | 4.5:1 | 3.01 | 3.01 (fails) |
| Default light | code block (white) | `syntax constantName` | 4.5:1 | 2.68 | 2.68 (fails) |
| Default light | code block (white) | `syntax decorator` | 4.5:1 | 3.93 | 3.93 (fails) |
| Default light | code block (white) | `syntax escape` | 4.5:1 | 2.94 | 2.94 (fails) |
| Default light | code block (white) | `syntax operator` | 4.5:1 | 2.14 | 2.14 (fails) |
| Default light | code block (white) | `syntax parameter` | 4.5:1 | 2.21 | 2.21 (fails) |
| Default light | code block (white) | `syntax regex` | 4.5:1 | 2.98 | 2.98 (fails) |
| Default light | code block (white) | `syntax string` | 4.5:1 | 3.45 | 3.45 (fails) |
| Default light | code block (white) | `syntax tag` | 4.5:1 | 4.16 | 4.16 (fails) |
| Default light | code block (white) | `syntax variable` | 4.5:1 | 3.27 | 3.27 (fails) |
