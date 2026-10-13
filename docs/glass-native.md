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

Phase 1 is done (2026-10-13). Phase 2, the native sidebar, is next.

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
