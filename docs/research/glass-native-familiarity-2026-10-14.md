# Glass Native familiarity pass (2026-10-14)

Phase 6's familiarity pass. I put a Debug build (`dev.candywrapper.test.gn-familiar`, `CANDY_THEME=candywrapper-glass-native`, 1100x780) in the state of each reference in `design/reference/` against the sandbox server on 47391, took a window capture and compared it region by region with the reference. Captures are `/tmp/cw-peek/familiar-<reference>.<appearance>.png`, the references at 1x in `/tmp/cw-peek/gnf-ref/`.

What doesn't count, per the Direction: SF Pro, SF Symbols for Lucide glyphs, the glass material and the macOS sidebar material, the system toolbar and traffic lights, the candy brand, `NSMenu` for T3 desktop's native menus, and the glass segmented control for the panel toggles. Sandbox data doesn't count either: the sandbox now holds newer threads (pinned MCP hub rows, "main" branch lines, "Settled 4d ago"), and the approval and question in 05 and 06 have since been answered or expired.

## Shell: toolbar, breadcrumb, window

Seen in 02, 03c, 03d, 04, 12, 44, 47.

1. Fixed (b551d6c). The project crumb was regular weight. T3 sets every crumb `font-medium`, the project in `muted-foreground` (WorkspaceBreadcrumb.tsx:52-57). The Visual spec said "14 regular", which was wrong, and now says medium.
2. Fixed (b551d6c). The crumbs sat 6 pt apart. T3 uses `gap-3`, 12 pt (WorkspaceBreadcrumb.tsx:16).
3. Fixed (b551d6c). The title's chevron always showed. T3 shows it only on hover (ChatHeader.tsx:346-350).
4. Fixed (3777241). With the right panel open, the breadcrumb kept up to 640 pt and ran across the panel's tab strip, so a long title drew over the Files tab (`familiar-12-right-panel-files.dark.png` before, a garbled "H◻Files H2"). T3's header ends at the panel. The breadcrumb now truncates 16 pt before the chat column's edge.
5. Design call. The sidebar is 320 pt by default (280 to 380). T3's is 256 (`SIDEBAR_WIDTH = "16rem"`, ui/sidebar.tsx:27). Every reference shows it: the chat column starts 58 pt further right, the composer is 55 pt narrower, and with the right panel open T3's panel is 484 pt wide against native's 420. Recommendation: default 256 and a minimum near classic's, since the native search row and brand fit in 256. This is the largest difference left, and the phase 1 spec set the numbers, so the user should pick.
6. Design call. With the right panel open, T3 splits its toggles: thread details stays at the chat header's right end, and Maximize, terminal and right panel move to the panel's header beside its tabs (ChatHeader.tsx:255-259, ChatView.tsx:11211-11232). Native keeps all four in one glass group at the window's right. Recommendation: keep one group. Moving details into the chat column would need a second toolbar item that tracks the panel's edge, for a toggle a T3 user finds by its glyph anyway.
7. Left. While the palette is open, the toolbar's breadcrumb, traffic lights and toggles stay sharp over the dimmed window; T3 dims its header too. The thread hunt already lists it.

## Sidebar

Seen in 02, 04, 20, 26.

1. Fixed (838a22f). On Usage and Pull Requests, footer Back was an `NSButton` with 13 pt text and its arrow at the fill's edge. T3's is a `SidebarMenuButton` with 14 pt text and a 16 pt arrow on the rows' 18 pt line (SidebarChrome.tsx:204-212), as Settings' Back already is in this window. Native now uses the same view.
2. Left on purpose. The search row is an `NSSearchField` with its bezel, where T3 shows a plain magnifier and "Search". The Direction names `NSSearchField`.
3. Left on purpose. The thread context menu is an `NSMenu` with only Delete's trash image, where the web reference shows a custom menu with an icon per row. T3 desktop opens a native menu with the same rule (ElectronMenu.ts:147-187), and the items and order match.
4. Not compared. Row title colors (T3 brightens unseen and Input rows) need the same rows; the sandbox's top rows have no status now.

## Thread and composer

Seen in 02, 03c, 03d, 04, 11, 13, 14, 15, 44, 47.

The timeline, user bubbles, "Worked for" folds, code cards, the Note alert, the draft hero, the composer's pills, the workspace strip, the terminal drawer's action cluster and the details card match T3 in place, order, wording and size. Their x positions differ only by the sidebar width above.

1. Left, shared with classic. The model picker shows ⌘1 to ⌘4 beside the models, which the 2861 reference lacks. Classic draws the same picker, and T3 at the pinned tag may have added them.

## Overlays and pages

Seen in 07, 08, 16a, 21, 26.

1. Left, shared with classic. Palette thread results show "demo-repo · Local" without the project chip and provider glyph the reference has. Classic draws the same rows, so it isn't native-specific.
2. Left. The palette shows a scroller on open; T3 shows none. It is the system scroller of the palette's scroll view.
3. The Git actions menu, Settings General and Usage match T3 apart from the sidebar width and the Back fix above.

## Not compared

- 01 running turn and 29 queued messages need real turns.
- 05 approval and 06 user input: the sandbox no longer has a pending approval or question.
- 09 and 10 diffs: the sandbox's current-checkout threads show "No net changes" (see the thread hunt).
- 31 sidebar collapsed: the reference shows the sidebar open, so it isn't a collapsed capture.
- 22, 27 and the remaining Settings pages (17 to 19, 32 to 40) are classic views hosted unchanged.

## Checks

The full suite passed after the fixes, fidelity tests included. On screen in light and dark, the breadcrumb truncates at the open Files panel and its tab shows (`familiar-12-right-panel-files.dark.png`). The chevron appears on hover and hides again, and Back on Usage sits on the rows' line (`familiar-26-usage-limits.light.png`).
