# Space mockups

HTML mockups of Space's main screens in Redesign dark, made on 2026-10-24 so the user can pick a look before the UI is built. Each file shows look A above look B, with a PNG of the same page at 2x. They live outside the repo in `/tmp/space-mockups/`, and `src/gen.py` there regenerates them.

The colors, radii and row metrics come from `capyDarkColors` in `ThemePalette.swift`, `DitherChrome` and the Dither sidebar layout in `SidebarView.swift`. Icons are hand-drawn stand-ins for Hugeicons.

| Screen | File | A | B |
|---|---|---|---|
| Page view | `1-page.html` | Plain document flow, page icons in the tree, due dates as pills next to each to-do, full-width image | Bigger title with an edited line, tree without icons under a guide line, to-dos in one card with right-aligned due dates, image beside its caption |
| Board | `2-board.html` | Open columns with the option pill as the header, bordered cards with fields as pills | Faint lanes with a dot and plain header, borderless cards with fields as one muted line |
| Table | `3-table.html` | Full cell grid, type icons in headers, select pills, underlined links | Row dividers only, dot and text selects, accent links, muted notes |
| Timetable | `4-timetable.html` | Slots tinted with the course color and a colored left edge | Neutral gray slots with a color dot, dashed half-hour lines |

The sidebar differs between A and B only on the page screen. The other three screens use sidebar A in both looks, so the comparison stays on the view.
