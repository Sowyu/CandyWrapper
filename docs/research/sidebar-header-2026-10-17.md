# Sidebar header polish

The user approved the prompt and browser-preview fixes, then requested changes to the sidebar header and a prettier blur. Release remains on hold for the new screenshots and explicit approval.

## Changes and source

The candy wash grows from 80pt to 112pt. Its blur starts near the top and increases to 14pt, while a smooth alpha curve dissolves the artwork directly into the sidebar. Removing the separate background-colored overlay removes the black band in dark Glass. The artwork keeps its original placement and colors; the compose button's teddy art stays unchanged. The title uses 90% white for clearer contrast.

In Glass, search has a subtle rounded surface, a hover fill and a focus border. The new-thread action has a matching 32pt surface with a clearer glyph. The three header actions have 2pt gaps. Search, filtering, project creation, new-thread shortcuts and title navigation keep their existing behavior. Other themes keep the original search and action styles.

This is the user's requested difference from the official header. Sources at the pinned Nightly 3234:

- `apps/web/src/index.css:498-518`: the original artwork alpha mask and background-colored overlay.
- `apps/web/src/components/sidebar/SidebarChrome.tsx:110-141`: home link and wordmark colors.
- `apps/web/src/components/sidebar/SidebarThreadHeader.tsx:65-143`: search, clear, project scope and new-thread behavior.
- `apps/web/src/components/sidebar/SidebarThreadHeader.tsx:148-187`: the original 28pt header actions.

The blur still bakes once per device-pixel size and shares the colorless cached image between appearances. No timers, polling, animations or new rendering contexts were added. Code review checked that appearance changes refresh both the search surface and header layout, button hover/press/focus feedback remains active, and the compact send-button artwork is unaffected.

## Screen checks

An isolated Debug app used only the sandbox server and fake T3 Connect. Native screen captures on the 1920 by 1080 display, at 1x:

- `/Users/mrm/CandyWrapper-research/sandbox/sidebar-polish/header-dark.png`
- `/Users/mrm/CandyWrapper-research/sandbox/sidebar-polish/header-light.png`
- `/Users/mrm/CandyWrapper-research/sandbox/sidebar-polish/search-light.png`
- Full windows: `dark.png` and `light.png` in the same folder.

Checked the 256pt and 360pt sidebar layouts. Typing “Count files” narrowed the sandbox list; the search focus border and clear action worked. The screenshots show sandbox data only.

## Validation

The full test suite passed: 1,530 tests. The app performance review compares against the immediately preceding prompt/preview build; unchanged model micro-benchmarks are excluded for this drawing-only change. The [saved review](../perf/2026-10-17-a4dc126-dirty-w1.md) found no threshold regressions: median 236ms to the window, 0.048% idle CPU, 38.0MB idle footprint, 85.2MB startup peak and 355.8ms scroll CPU. Three launches ran per scenario, with separate stall-monitor passes. One launch took 708ms and one long-thread sample recorded a 51ms stall; the medians passed, and the scrolling runs each recorded two dropped frames, as in the baseline. The pre-existing memory increase documented in the prompt/preview review remains open.
