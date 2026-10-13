# Glass Native (experimental)

A theme card the user asked for on 2026-10-13: "just glass BUT its a fully redesigned t3 code ui with native elements like the t3 code version for ipad os or vision os", "still incredibly optimised and possibly even faster". Picking it swaps the main window's custom-drawn T3 look for a native AppKit presentation modeled on T3 Code Mobile's iPad layout, with Liquid Glass chrome. Every other theme keeps today's look pixel for pixel.

Read first: `docs/research/t3-mobile-ipad-design-2026-10-13.md` (the iPad design, with file:line into `/tmp/t3code-2994/apps/mobile`) and `docs/research/glass-native-plumbing-2026-10-13.md` (CandyWrapper's theme and window seams, and the AppKit glass APIs).

## Direction

The user, 2026-10-13: "it uses native ui but it need to resemble t3 codes ui because im a t3 code power user and i need to have familarity." That decides every conflict below.

- T3 Code desktop is the layout. Every element stays where T3 Code puts it, with T3's wording, order, shortcuts and information. That covers the sidebar rows and their order, the bottom icons, the header breadcrumb and its right-hand panel toggles, the timeline (user bubbles, "Worked for" folds, work rows), the composer (its pills, the branch and workspace strip beneath it), the right panel tabs and the terminal drawer. Today's classic CandyWrapper views match T3 desktop, so use them as the map of what goes where.
- Native is the material and the controls. AppKit controls replace custom-drawn ones where one exists: `NSTableView` rows with system selection, `NSSearchField`, `NSMenu`, `NSPopover`, glass-bezel buttons, `NSToolbar` and `NSSplitViewController`. SF Pro is the font, and SF Symbols replace T3's Lucide icons where a close match exists. Keep the same glyph meaning in the same place.
- T3 Mobile's iPad design (`docs/research/t3-mobile-ipad-design-2026-10-13.md`) is only a guide to how T3 itself maps its UI onto native controls and glass. Where it differs from T3 desktop in layout, T3 desktop wins. Examples: the iPad's "Threads | Pull requests" segmented control, its pill composer and its 960 pt column don't apply. Keep T3 desktop's sidebar shape, composer shape and content width.
- It is still Glass. The detail column keeps Glass's frosted window and follows the Glass opacity slider. The sidebar is macOS's own floating glass sidebar. Toolbar buttons, the composer surface, popovers and the command palette are Liquid Glass. Content blocks (code, diffs, tables, approval cards and the terminal) stay solid so text reads.
- Sizes follow T3 desktop, as the classic views have them. The user's font size setting scales them.
- Motion comes from the system, plus T3's own transitions where a user would notice their absence. Nothing ticks once it ends.
- It needs macOS 26 for `NSGlassEffectView`, the glass bezel and the split view glass. Below 26 the card is hidden, and a stored "Glass Native" preference falls back to Glass.
- It must work with no bugs: every action that works in classic must work in native mode. Phase 6 is a full bug hunt.

## Visual spec

Set on 2026-10-13 by the polish pass, after the user called the first native build "unpolished slop". Every native view keeps to it. The numbers live in `NativeSpec` (`Features/Native/NativeSidebarChrome.swift`).

Spacing is a 4 pt grid. Insets are 8, 12, 16 or 20, and nothing else.

The sidebar has two vertical lines that everything hangs on:

1. Surfaces start 8 pt from the column's edges. That covers the search field, every row's hover and selection fill, and the footer's buttons.
2. Text and glyphs start 18 pt in, 10 pt inside a row's fill, as classic's rows do. The search field's magnifier and the footer's first glyph land on the same line within 2 pt.

The toolbar is the window's 52 pt unified toolbar. Every item centers on the traffic lights, 26 pt down.

- The sidebar toggle is a plain glyph right of the traffic lights, where T3's sits.
- The breadcrumb is plain text: project at 14 regular in the secondary label color, the title at 14 medium.
- T3's panel toggles are one glass segmented control that shows each on state. Maximize joins it while the right panel is open.
- Rows scroll under the toolbar and fade out from 16 pt below its bottom edge to 12 pt above it. There is no band, tint or line at rest.
- New thread lives in the sidebar's search row, as in T3, not in the toolbar.

The corner radius scale has four steps.

| Radius | Used for |
|---|---|
| 6 | icon buttons' hover and pressed fills, small controls |
| 8 | row fills in the sidebar |
| 12 | cards and popovers |
| 22 | the composer (classic's `ComposerView.radius`) |

Type is SF Pro at classic's sizes: 12 for metadata, 14 for row titles, the breadcrumb and body text. It uses two weights, regular and medium. Tabular figures go on times and durations.

Icons are SF Symbols. The search row and the footer use 14 pt regular glyphs in 28 and 32 pt square buttons, as classic sizes them. Row glyphs stay at 10 to 12 pt, and the toolbar uses the system's item size.

Glass is allowed in three places: the toolbar's item groups, the composer and popovers. The sidebar is macOS's own sidebar material. Rows, the search row, the footer, the timeline and content blocks get no glass of their own.

Colors come from T3's tokens through `Themed` and `SB`: `foreground`, `mutedForeground`, `secondaryLabel`, `accent`, `sidebarRowHover`, `sidebarRowActive` and `sidebarRowSelected`. Two places can't use a token as it is, and each says why in code:

- The toolbar toggles' on tint is an opaque stand-in for T3's 4% `accent`, which vanishes on glass and makes AppKit draw the glyph dark.
- A user bubble keeps a hairline: 8% black in light mode at every opacity, and 12% white in dark mode below the default 80% Glass opacity. T3's `border` token sits too close to the bubble to show on the frost.

Content that has to read stays readable at every Glass opacity from 10 to 100: user bubbles by their hairline, code blocks and approval cards on a solid card with a `border` hairline.

| State | Rows | Icon buttons | Toolbar toggles |
|---|---|---|---|
| Hover | `sidebarRowHover` fill, plus Settle and Snooze in the status slot | `accent` fill, glyph to `foreground` | system |
| Pressed | | `sidebarRowActive` fill | system |
| Selected | `sidebarRowActive`, or `sidebarRowSelected` for a multi-selected row that isn't open | | |
| On | | `accent` fill and an accent glyph, as on the scoped project filter | a subtle grey segment, glyph in the foreground color |
| Disabled | | glyph at `mutedForeground` 50% | system |

The system's blue emphasized selection never shows. Text keeps its T3 colors on a selected row.

## Structure

- Theme id `candywrapper-glass-native`, label "Glass Native (Experimental)". It uses Glass's palette rules: stock T3 tokens, the frosted window and the same opacity slider. Add the id to `ThemePalette.reservedIds`. The choice lives in UserDefaults like every theme and never reaches the server.
- `MainWindow` gets a native mode with a unified `NSToolbar`, a transparent titlebar and a full-size content view. The content is an `NSSplitViewController` with three items:
  - The sidebar, from `sidebarWithViewController`: min 280, max 380, preferred 320.
  - The detail: min 320.
  - The inspector, from `inspectorWithViewController`: hidden until Files, Git, Diff or Pull requests open.
- Switching the theme at runtime rebuilds the window's content in the other presentation. The controllers and stores (`ThreadController`, `ThreadSession`, `ComposerController`, `SidebarCommands`, `SettingsController`) stay. Only views and the references to them change.
- The new views live in `Packages/CandyKit/Sources/Features/Native/`, and the app-side joins in `App/Sources/Native*`. The timeline keeps its engine (row recycling, `TimelineChange`, the 30 fps `FramePacer`) and gets a native row style. It is not a second timeline.
- Settings, Pull Requests and the other utility pages keep their current views in v1, hosted in the detail column.

## Performance rules

- At most about five glass views on screen at once, never per row or per message. Group the composer's glass in one `NSGlassEffectContainerView`.
- Zero idle cost, as everywhere: no timers, display links only while something moves, and `.followsWindowActiveState` behavior.
- Hidden columns hold nothing. A collapsed inspector releases its content. A hidden sidebar keeps its model but not offscreen layers.
- Use `NSTableView` with view reuse for the sidebar. The incremental update contract (`SidebarListCache` hints) still applies.
- Measure it against classic Glass on the frozen perf workload: launch, idle wakeups, memory with 1,580 threads and the huge thread, and scroll. Native must be no slower and no heavier. `CANDY_THEME=<id>` overrides the stored theme for perf runs and snapshots.

## Phases

1. Foundation: the theme card and gate, the runtime presentation switch, and the native window shell. The toolbar and the three-column split view host today's sidebar and thread views, with their custom headers hidden. Glass Native becomes usable end to end.
2. Native sidebar: an `NSTableView` with T3 Mobile's card and slim rows, the shelves, a search field, the "Threads | Pull requests" segmented control, trackpad swipe actions (Settle, Snooze), native context menus, and a glass "New chat" button.
3. Native thread: the toolbar title, subtitle and items (sidebar toggle, new task, files, git, terminal), the native timeline row style (user bubbles, full-width assistant text, SF Symbol work rows, a 960 pt content column), the approval cards, and the floating working pill.
4. Native composer: a floating glass composer that morphs from pill to card on focus, an `NSTextView` editor, a native model and options popover, and a circular send button. `ComposerController` drives it unchanged.
5. Panels and overlays: Files, Git, Diff and pull request files in the inspector, the terminal drawer restyled, a glass command palette, and native menus throughout.
6. A bug hunt over every action in native mode next to classic and the official T3 app, a familiarity pass against T3 Code desktop, a perf comparison with classic Glass, and a code review.

## Status

Phase 1 is done (2026-10-13). Phase 2, the native sidebar, is done (2026-10-13, see "Phase 2" below).

### Polish pass (2026-10-13)

The user called the first native build "unpolished slop" and circled four regions. This pass set the "Visual spec" above and took each region to it. Screenshots are in `/tmp/cw-peek/polish-*`.

1. The sidebar top and the toolbar. The sidebar toggle is a plain glyph beside the traffic lights, and New thread is back in the search row with the project filter and Add project. The panel toggles are one segmented control with T3's subtle on state. They hide on Settings, Pull Requests and Usage, as T3's do. The breadcrumb is plain 14 pt text in two weights. The grey band under the toolbar is gone: rows fade out under it (`ToolbarScrollFade`, an alpha mask on the timeline's scroll view).
2. The sidebar rows and footer. Rows draw T3's own fills (`NativeSidebarRowView`): hover, the open thread and the multi-selection, inset 8 pt, never the blue emphasized selection. Cards show T3's hover Snooze and Settle in the status slot, and slim rows their Wake, Un-settle or Settle button. Row text starts 18 pt in, on the same line as the search field's magnifier and the footer's first glyph. The footer's Pull Requests glyph is T3's Lucide icon, since SF's `arrow.triangle.pull` doesn't read at 14 pt.
3. The thread. The timeline uses the system's overlay scroller in native mode, kept between the toolbar and the composer. User bubbles keep a hairline where the frost would swallow them, and the approval card takes the `border` hairline.
4. The composer. It is one `NSGlassEffectView` in an `NSGlassEffectContainerView`, tinted with classic's surface at the Glass opacity, in place of the blur, fill, outline and shadow. Shape, pills, spacing, the context strip and the 20 pt bottom margin are classic's.
5. The project filter opens classic's combobox under the native search field: search, environment badges and per-project settings.
6. The right panel runs up under the toolbar, so its tabs share the toolbar's row as T3's share the header row with the panel toggles. The strip keeps 176 pt clear at the right for the toggles, content under the toolbar still takes clicks, and a maximized panel hides the breadcrumb, as T3 hides its header.

Left for later:

- The details card overlaps the first user bubble at the top right, as it does in classic.

Performance, Release builds on the frozen workload with `scripts/perf-review --no-bench` and `CANDY_THEME`, load average 2 to 6. Glass and the polished native ran 3 launches, the native fix 2.

| | Glass | Native before polish (76d7b4c) | Native after polish |
|---|---|---|---|
| Launch to window | 207 ms | 278 ms | 276 ms |
| Idle CPU | 0.044% | 0.045% | 0.055% |
| Idle package wakeups | 0.20/s | 0.17/s | 0.10/s |
| Footprint at rest | 34.0 MB | 44.7 MB | 45.0 MB |
| Huge thread footprint | 35.8 MB | 46.1 MB | 46.3 MB |
| Huge thread scroll CPU | 360 ms | 404 ms | 376 ms |
| After scroll footprint | 45.3 MB | 54.4 MB | 54.2 MB |

The polish costs nothing measurable. A first version used the system's preferred scroller style, which is legacy on this Mac with its mouse: the scroller took a lane, the timeline measured every row again at the narrower width, and the after-scroll footprint rose to 72 MB. The timeline now keeps the overlay style. The composer's glass and the fade mask each measured within noise. Native is still about 11 MB heavier and 70 ms slower to the window than Glass, from the window structure the Phase 2 notes describe.

What works in Glass Native now:

- The "Glass Native (Experimental)" card sits after Glass on macOS 26 and later. Picking it, or picking any other card, rebuilds the window at once, with Settings open or not.
- The window has a unified toolbar with the system's traffic lights, the thread title and "project · environment" subtitle, and the sidebar toggle, New thread, Files, Git and Terminal buttons.
- The split view holds today's sidebar (280 to 380 wide, 320 at first, width and collapse remembered under `CandyGlassNative`), the detail and a collapsed inspector. macOS gives the sidebar its own `NSGlassEffectView`.
- The detail keeps Glass's frost and tint, and runs up behind the transparent toolbar.
- Settings, Pull Requests and Usage open in the detail and close again. The toolbar title says which page shows.

The seams later phases use:

- `MainPresentation` (`Features/Native/MainPresentation.swift`) is the window's layout as the app sees it: `sidebarContent`, `mainContent`, `toggleSidebar()`, `root` for overlays, and `install(in:)`. `SidebarLayoutView` and `NativeSplitPresentation` conform. `SettingsController` and `SidebarCommands` hold one weakly and swap pages through it.
- `MainPresentationSwap.swap` moves the sidebar view, the page and any overlays to the new presentation. The views stay the same objects, so the thread, the draft, the caret, the scroll position and the selection survive.
- `CustomChromeHiding.hidesCustomChrome` hides a view's own titlebar row or header in native mode. The sidebar, Settings' navigation and the thread panel adopt it.
- `MainPresentationController` (`App/Sources/NativeMainPresentation.swift`) picks the presentation from `ThemeLibrary.usesNativePresentation`, swaps it on a theme change, re-points the controllers, and keeps the toolbar title current. A native sidebar or composer in a later phase replaces the content view it hands to the presentation.
- `NativeToolbarActions` holds the toolbar's commands as closures.

Decisions made in phase 1:

- The native presentation is on when Glass Native paints either appearance, as the base theme or as one side of a light and dark mix. A mix with Glass Native on one side still gets the native layout on both.
- The sidebar keeps its search row with the project filter and Add project buttons until phase 2 replaces it. Only New thread moved into the toolbar.
- Files toggles today's right panel, Git toggles the thread details card (branch, commit, changes, lineage) and Terminal toggles the drawer. They are disabled while Settings or a utility page shows.
- The toolbar uses the window's own title and subtitle, so the system sets their font rather than a hand-set 15 semibold.
- The split view controller sits inside a plain root view, because popups, modals and the palette add themselves to the window's content view. The sidebar still gets the system glass this way.
- Workspace zoom does nothing in native mode for now. It needs per-column scaling.
- `scripts/run-app` passes `CANDY_THEME` through. The pinned theme also ignores a stored light and dark mix.

Performance on 2026-10-13, the Release build of 6111109 against the sandbox server, three launches per theme alternated, with `CANDY_THEME` set to each. Launch-to-window comes from perf-review's window probe, and idle numbers from `procstat` over 30 s, 15 s after launch. A Zen build loaded the Mac (load average 14), so `scripts/perf-review` itself would have waited; treat the absolute numbers as rough and the comparison as fair. Medians, with the range:

| | Glass | Glass Native |
|---|---|---|
| Launch to window | 214 ms (204 to 216) | 251 ms (245 to 274) |
| Idle CPU | 0.02% (0.02 to 0.03) | 0.02% (0.02 to 0.04) |
| Idle wakeups | 0.13/s (0.07 to 0.13) | 0.10/s (0.07 to 0.17) |
| Footprint at rest | 40.9 MB (39.6 to 41.5) | 49.2 MB (48.8 to 51.2) |

Idle cost is the same. Native misses the memory target by about 8 MB and launches about 37 ms later. A heap diff puts about 4 MB in Auto Layout: the split view controller lays out with constraints, and AppKit then puts every view in the window, about 1,000 of them, into the layout engine. Classic Glass creates the same autoresizing constraints but never solves them. Hosting the sidebar and page in frame-based views beside the split view, or putting the split view in the theme frame, did not stop it. Most of the rest is the system's toolbar and sidebar glass, which AppKit builds with SwiftUI. Phases 2 and 3 replace most of those 1,000 views with fewer native ones, so measure again then.

Left for later phases: Files opens whatever surface the right panel last showed, not the files tree (phase 5 moves it to the inspector). The detail's page starts under the toolbar instead of scrolling under it (phase 3).

### Phase 3, the thread (2026-10-13)

The thread keeps T3 desktop's layout and the classic metrics. Native mode changes the material only:

- The timeline reads a row style (`TimelineStyle`, set by `ThreadPanelView.hidesCustomChrome`). Work rows show SF Symbols where a Lucide icon has a match (`NativeTimeline.symbol`), and code blocks sit on a solid card. Column, bubbles, folds, row heights and wording are the classic ones, and a style switch keeps the scroll position at the end.
- The rows scroll under the toolbar behind a soft within-window blur (`ToolbarScrollEdgeView`). The right panel and the banners start below the toolbar.
- The approval and question panels keep T3's docked shape on a solid fill. Approval buttons are AppKit push buttons in T3's labels and order, Approve the default, and the other decisions open as an `NSMenu`.
- The toolbar shows T3's breadcrumb (`NativeBreadcrumbView`): project icon, project (new thread), the parent of a subagent, and the title (thread menu on click, rename in place on double click or from the menu). Then T3's panel toggles in order: thread details, terminal drawer and right panel, with Maximize only while the right panel is open.
- The empty state is T3's draft hero, unchanged.

Dropped after the direction change: the 960 pt column, iPad bubbles and sizes, the Load earlier pill, the floating working pill, the iPad empty detail and the Git and Terminal menus.

Left for the polish pass: the toolbar's glass group and the breadcrumb's look, the grey band of the scroll edge under the toolbar, the panel toggles' on state (the toolbar items have none), Maximize's icon when the panel is maximized, and the capsule shapes.

Performance, Release build of cebf81c against the frozen workload, `scripts/perf-review --no-bench` run Glass, Glass Native, Glass back to back with `CANDY_THEME` (load average 3.0 to 3.2 for all three). Medians of three launches:

| | Glass (1st) | Glass Native | Glass (2nd) |
|---|---|---|---|
| Launch to window | 204 ms | 257 ms | 201 ms |
| Idle CPU | 0.041% | 0.040% | 0.026% |
| Idle package wakeups | 0.17/s | 0.10/s | 0.10/s |
| Footprint at rest | 34.3 MB | 46.3 MB | 34.2 MB |
| Huge thread footprint | 35.9 MB | 48.4 MB | 35.4 MB |
| Huge thread scroll CPU | 293 ms | 317 ms | 324 ms |
| After scroll footprint | 44.3 MB | 57.6 MB | 44.7 MB |
| Huge thread first frame | 58 ms | 41 ms | 55 ms |

Idle cost and scrolling are the same, and the huge thread opens faster. Native still launches about 55 ms later and sits about 12 MB heavier, against 8 MB after phase 1. This run includes phase 2's sidebar, and the thread adds only one blur view and the breadcrumb, but I did not take a heap diff, so where the extra 4 MB sits is open. Phase 6 should find it.
### Phase 2: the native sidebar

Rebuilt on 2026-10-13 after the new Direction: it is T3 Code desktop's sidebar, as classic draws it, with native controls in the custom-drawn ones' places. Screenshots: `/tmp/cw-peek/sidebar-pair-classic.png` and `sidebar-pair-native.png`.

What it has now:

- The list is a view-based source list `NSTableView` (`Features/Native/NativeSidebarListView.swift`) with the system selection, emphasized while the list has focus. Rows keep classic's anatomy and heights (`NativeSidebarCells.swift`): card rows at 82 pt with favicon, project, pin and the status or time on line 1, the title on line 2, and branch, terminal, pull request badge, remote machine and provider on line 3; slim rows at 36 pt; drafts first under their divider; Working, Snoozed and Settled shelves with "Settled (N)" and the chevron; "Show N more". Status glyphs are SF Symbols in T3's status colors. Titles take classic's weights and colors.
- The search row sits where T3 has it: an `NSSearchField` ("Search"), then the project filter and Add project as plain icon buttons. The filter opens a native menu of projects and fills while a project scope applies. New thread stays in the toolbar (phase 1). Cmd+F in the list focuses the field; results show the "You:" or "Agent:" excerpt.
- The footer is T3's row of plain icons: Settings, Pull Requests and Usage at the left, the update pill at the right, Back on Pull Requests and Usage, the undo notice and provider pill above.
- Trackpad swipes from `rowActionsForRow:edge:` stand in for T3's hover buttons: Settle and Snooze on cards (Snooze opens a native "Snooze until" menu), Un-settle on settled rows, Wake on snoozed rows, Archive on servers without settlement. Right click shows the thread menu. Arrow keys walk the list and open each thread with the list keeping focus. Double click renames in place. Drags reorder pins and the inbox through the classic planner, files drop onto rows, and a drag out carries thread context to the composer. Hover cards work.
- Removed after the Direction change: the "Threads | Pull requests" switcher, the "New chat" accessory, the glass footer circles, the Environment filter and T3 Mobile's row anatomy and order.

Seams: `SidebarItemsPresenting` (`Features/Native/NativeSidebarModel.swift`) is what `SidebarContentView` needs from a list; both lists conform, `presenter` picks the one showing and `shownItems` replaces `list.items` for the app. The native list takes the same `SidebarListCache` items and patches. A one-thread change reconfigures one cell; a clock step touches only rows whose labels changed; shelves opening or closing insert or remove only their rows (`rowChanges` skips the common head and tail). `SidebarActions.archive` is new.

Where it still differs from classic in layout (for the polish pass):

1. The sidebar column is 320 pt wide (the split view's 280 to 380), where classic is 255.
2. The header row has the toolbar's sidebar toggle and New thread items, not classic's brand and toggle. The toolbar is phase 1 and 3 territory.
3. Row content starts 26 pt from the column edge, where classic's starts 18 pt: the source list adds its own row inset around the 8 pt cell inset. The search field starts at 8.
4. The search field is the system capsule, not classic's flat field, and the row has two buttons, not three (New thread moved to the toolbar).
5. Rows have no hover fill and no hover Settle and Snooze buttons; swipes and the menu do those.
6. The project filter is a plain menu, without classic's popup search, environment badges and per-project settings button; the scoped trigger shows a filled folder, not the project's favicon.
7. Line 3's pull request badge, terminal, machine and provider glyphs are classic's custom views; the status and pin glyphs are SF Symbols. Labels sit 2 pt in from their frames (the text field inset).
8. Shelf headers and Show more are plain cells; classic's focus ring and hover fill are absent.

Performance, Release builds alternating Glass and Glass Native launches with `CANDY_THEME`, three each, taken before the redirect (the row views changed since, the window structure did not). The machine was busy, so compare the columns.

| | Glass | Glass Native |
|---|---|---|
| Sandbox: launch to window | 181 ms (171 to 181) | 255 ms (252 to 262) |
| Sandbox: footprint at rest | 38.3 MB (37.3 to 39.8) | 49.7 MB (47.5 to 50.0) |
| Five load homes, 1,580 threads: launch to window | 207 ms (206 to 788, the first launch cold) | 271 ms (270 to 275) |
| Five load homes: footprint at rest | 84.4 MB (70.8 to 84.5) | 94.7 MB (92.7 to 95.1) |
| Idle CPU and wakeups | 0.02 to 0.05%, 0.07/s | 0.03 to 0.11%, 0.10/s |

Update cost at 1,580 threads with the settled shelf open, `PerfBenchmarks.sidebarUpdates`, median main thread time with layout: a one-thread rename 0.46 ms classic and 0.61 ms native, a minute's clock step 0.31 and 0.65 ms, the settled shelf opening or closing 2.0 and 1.6 ms.

Parity is not reached: native is about 11 MB heavier and 65 to 75 ms slower to the window. A heap diff at rest puts the extra in the window structure, not the sidebar: SwiftUI view graphs behind each glass control (19 graphs, 23 glass material providers), 3,300 Auto Layout variables, method caches and Swift metadata for the extra AppKit and SwiftUI classes. The classic sidebar was never the main cost. Measure again after the polish pass settles the controls.

### Perf audit (2026-10-13)

Release builds of 76d7b4c on the frozen perf workload, Glass and Glass Native launches interleaved with `CANDY_THEME`, the first (cold) launch dropped, load average 1.5 to 2.1. Two idle perf builds that Time Profiler had launched and left behind ran during these runs, the same for both themes. Medians of three, with the range:

| | Glass | Glass Native |
|---|---|---|
| Launch to window | 177 ms (175 to 188) | 255 ms (231 to 264) |
| Footprint at rest | 33.8 MB (33.7 to 34.1) | 44.2 MB (43.6 to 45.2) |
| Peak footprint | 34.0 MB (33.9 to 34.3) | 44.6 MB (44.4 to 45.5) |
| CPU from 5 to 50 s after the window | 0.030% | 0.087% (0.032 to 0.097) |
| Package idle wakeups | 0.13/s | 0.11/s |

Where the difference goes. A scratch build took one piece out of the native window at a time (two interleaved launches each), and a bare AppKit app with 700 plain frame-laid views measured the same system pieces with no CandyWrapper code (three launches each):

| Piece | Memory | Launch | Bare AppKit window | Avoidable |
|---|---|---|---|---|
| `NSToolbar`, unified, with its glass items | 3.6 MB | 20 to 30 ms | 3.3 MB | Only without `NSToolbar`. Fewer items saved nothing. |
| `NSSplitViewController` and its Auto Layout engine | 2.7 MB | 15 to 20 ms | 1.3 MB, plus 3 KB per view in the window | Partly, with fewer views in the window |
| The native sidebar: table, search field, SF Symbols, cells | 2.7 MB | about 15 ms | | The sidebar owner's |
| Breadcrumb, scroll edge blur, column views, collapsed inspector, hidden Maximize | about 1.3 MB together, none above the noise alone | about 10 ms | | |

Toolbar and split view together took 6.3 MB and 45 ms off, and `makeKeyAndOrderFront` fell from 48 to 5 ms. The bare window showed the same 6.6 MB for them. The engine's share grows with the window: 2.0 MB at 700 views and 8.2 MB at 2,100. Classic Glass creates the same autoresizing constraints (2,500 of them) but never adds them to an engine.

The buckets the audit was asked to name:

- Auto Layout and the split view: the rows above. The engine holds every view in the window, hidden ones too.
- Toolbar: the row above. Its heap is spread thin: SwiftUI view graphs, key-value dependencies, SF Symbol parsing and AppKit method caches.
- Glass and visual effect views: the window server composites them, and the CoreAnimation region is smaller in native (1.7 MB against 2.2 MB). The glass costs sit in the toolbar's SwiftUI graphs.
- Layer backing stores: 209 layers with contents in native against 188 in classic, about 4 MB each by area.
- Inspector: collapsed on an empty controller, it never loads a view. Removing it changed nothing.
- Classic views kept in native mode: the classic sidebar's hidden chrome (scroll area, search field, buttons, pills, about 25 views) and the thread header (29 views), which the breadcrumb reads. About 0.2 MB with their engine share.
- Hidden views (counted on 7152980): 431 of the native window's 784 views are hidden or sit under a hidden view, against 355 of 631 in classic. The thread details card has 81, the header 29, the context strip and terminal drawer 28 each, the stash menu 25 and the question panel 20. They hold about 1 MB of layer contents, mostly the timeline's hidden recycled rows (307 KB), the terminal drawer (148 KB) and the header (131 KB). Taking them out before the first layout saved 2.5 MB in Glass and 3.9 MB in Glass Native.

Launch, from launch marks and Time Profiler: native spends 25 ms more building the presentation (the split view controller, the toolbar's view, the native sidebar and the breadcrumb) and 45 ms more in `makeKeyAndOrderFront`, whose first layout solves the engine (about 22 ms) and runs the toolbar's SwiftUI layout (about 16 ms).

Idle is the same once the app settles. A 65 s sample from 20 s after launch has the main thread idle throughout. From 3 s on, the only main thread work is about 13 ms of Core Animation commits and `NSPersistentUI` flushes, which is what the 5 to 50 s CPU column shows.

Fixes tried that saved nothing measurable: the sidebar accessory's buttons without the measuring convenience initializer (the accessory is gone since), fewer toolbar items, no inspector item, and content views with `translatesAutoresizingMaskIntoConstraints` off. No code fix went in. `scripts/run-app` now passes `MallocStackLogging` through, for `leaks --outputGraph` and `malloc_history -callTree`.

The target, within 2 MB and 10 ms of Glass, is out of reach while Glass Native uses `NSToolbar` and `NSSplitViewController`: those two cost 6.3 MB and 45 ms here, and the same in an empty AppKit window. Bigger fixes, with what each would save:

1. Create the thread panel's hidden panels on first show: 2.5 MB in both themes and 3.9 MB in Glass Native, so the gap shrinks by 1.4 MB, plus a few ms of the first layout. It touches `ThreadPanelView` and the panels' callers (`detailsCard` alone has 54).
2. Bring the native sidebar to classic's cost: up to 2.7 MB and 15 ms. Dropping the hidden classic chrome in native mode is about 0.2 MB of it.
3. Lay the split out by frames with our own sidebar glass instead of `NSSplitViewController`: 2.7 MB and 15 to 20 ms, but it gives up the system sidebar glass, its collapse animation and the tracking separator. A design call.
4. The toolbar has no saving short of dropping `NSToolbar`, 3.6 MB and 20 to 30 ms.

With 1 and 2 done, Glass Native would sit about 6 MB and 50 ms over Glass, which is what the system's toolbar and split view cost.
