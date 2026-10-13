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
