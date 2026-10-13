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

Phase 1 is next.
