# Glass Native (experimental)

A theme card the user asked for on 2026-10-13: "just glass BUT its a fully redesigned t3 code ui with native elements like the t3 code version for ipad os or vision os", "still incredibly optimised and possibly even faster". Picking it swaps the main window's custom-drawn T3 look for a native AppKit presentation modeled on T3 Code Mobile's iPad layout, with Liquid Glass chrome. Every other theme keeps today's look pixel for pixel.

Read first: `docs/research/t3-mobile-ipad-design-2026-10-13.md` (the iPad design, with file:line into `/tmp/t3code-2994/apps/mobile`) and `docs/research/glass-native-plumbing-2026-10-13.md` (CandyWrapper's theme and window seams, and the AppKit glass APIs).

## Direction

- Apple-native. SF Pro and the system's semantic colors, tinted with T3's stock tokens: `primary` #1b4ed8 light and #346bf1 dark, the status hues, and the screen and card colors. The layout and anatomy come from T3 Mobile on iPad. AppKit controls replace custom-drawn ones wherever one exists.
- It is still Glass. The detail column keeps Glass's frosted window and follows the Glass opacity slider. The sidebar is macOS's own floating glass sidebar. Toolbar buttons, the floating composer, the working pill and the command palette are Liquid Glass. Content blocks (code, diffs, tables, approval cards and the terminal) stay solid so text reads.
- Sizes are T3 Mobile's iPad sizes scaled for the Mac, about 0.875 rounded: body 14/21, footnote 12, label 12, headline 16, title 18, and a 15 semibold toolbar title. The user's font size setting scales them.
- Motion comes from the system: the split view collapse and the popover and menu animations. The only custom animation is the composer's pill-to-card morph, 220 ms, on layer properties. Nothing ticks once it ends.
- It needs macOS 26 for `NSGlassEffectView`, the glass bezel and the split view glass. Below 26 the card is hidden, and a stored "Glass Native" preference falls back to Glass.

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
6. Polish, a perf comparison with classic Glass, and a code review.

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
