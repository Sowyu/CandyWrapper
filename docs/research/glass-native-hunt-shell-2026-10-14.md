# Glass Native bug hunt: window shell and sidebar (2026-10-14)

Phase 6, half 1. I walked the window, the toolbar, the sidebar and the Settings, Pull Requests and Usage pages in a Debug build (`dev.candywrapper.test.gn-hunt-shell`) against the sandbox server, in Glass Native and in classic Glass, at 840x640, 1100x780 and full screen. The code review's findings for this half (`/tmp/gn-review-2026-10-14.md`, M1, M2, L1, L5 and L6) are folded in. Screenshots are in `/tmp/cw-peek/hunt-shell-*.png`.

## Fixed

### The brand disappeared in full screen

In full screen the toolbar lives in its own window over the top 52 pt of the content, and the brand was drawn in the sidebar at a measured x of 140 under it (`hunt-shell-brand-fullscreen-before.png`). The brand is now a toolbar item after the sidebar toggle (`NativeSplitPresentation`, `NativeBrandHost`), so the toolbar places it beside the toggle windowed and in full screen, and it hides with the sidebar. The presentation takes the brand before the toolbar is built, so a theme switch made with Settings open shows it too. The `NativeSpec.brandLeft` constant is gone. After: `hunt-shell-fullscreen-thread-after.png`, `hunt-shell-switch-native-settings-after.png`.

### Settings, Pull Requests and Usage showed their title twice

The toolbar showed the page's name and the page showed its own 52 pt header row just below it (`hunt-shell-prs-native.png`, `hunt-shell-settings-native.png`). T3 shows the header row once, in the top bar. Windowed, the pages now put their header row in the toolbar's row and the toolbar hides its breadcrumb on pages (`NativeColumnView.layout`, `syncPanelStates`). The header's controls take clicks there; I opened Usage's Limits menu from it. In full screen the toolbar covers that row, so the header sits just below it and the toolbar row stays empty. After: `hunt-shell-settings-after.png`, `hunt-shell-usage-after.png`.

### Page headers indented 70 pt with the native sidebar collapsed (review L5)

`TopbarDragView.contentStart` looked for a `SidebarLayoutView`, which native mode lacks. In native mode the header now starts after the toolbar's toggle (140 pt from the window's edge) when it sits under it, and at 20 otherwise. After: `hunt-shell-usage-collapsed-after.png`.

### The draft headline was clipped in a narrow column

At 840 pt the native detail column is 520 pt wide and "What should we build in demo-repo?" lost its first and last letters (`hunt-shell-min-native.png`). T3's `h1` wraps (DraftHeroHeadline.tsx:360-372). `DraftHeroView` now wraps at spaces when the line doesn't fit, keeps the project picker whole, and reports its height to the thread panel. A line that fits draws exactly as before, so classic's fidelity tests are unchanged. After: `hunt-shell-hero-after.png` shows the thread; the draft check is the test `draftHeadlineWrapsInANarrowColumn`.

### Native rows kept their old height when an item changed height in place (review M2)

`setItems` stored the new heights before `refresh` compared them, so `noteHeightOfRows` never ran. It now notes every kept row whose height changed. Test: `nativeListNotesHeightChangesInPlace`, which failed before the fix.

### Classic header toggles showed before a thread loaded (review M1)

`ThreadPanelView.layout()` un-hid all three header toggles on every classic layout. Only the switch back to classic restores the toggles native mode hid. Test: `classicHeaderTogglesStayHiddenWithoutAThread`.

### Toolbar items changed inside the window's layout pass (review L1)

`onMaximizableChange` and the details presentation's `onPanelTogglesChange` ran from `ThreadPanelView.layout()` and swapped or hid toolbar items mid-layout. Both now run on the next turn of the main queue. No crash reproduced either way.

### The native sidebar lost its place on a theme switch (review L6)

Each switch built a new list at the top. Both lists now report the first item on screen and scroll an item to the top, and `applyPresentation` carries it across. Test: `themeSwitchKeepsTheSidebarsPlace`. On screen the sidebar kept "Document the CLI flags" at the top across Glass to Glass Native.

## Checked and fine

- The 2026-10-13 14:01 crash came from `NativeSidebarRowView.restyle` calling `view(atColumn:)` while the table set the row up. 34739f6 fixed it, and it didn't come back through launches, resizes, full screen and six theme switches. The other reports that day are a `TelemetryExportView` text-setter recursion (03:36, now guarded by `syncing`) and three dyld "Library missing" launches of Release builds without Sparkle.
- The "on" look on the thread details toggle at launch is the glass segmented control's hover look under a resting pointer. The control's state was off.
- Settings opens and closes in the detail column, Escape leaves it in both modes and after a switch. The first Escape after a switch can close a theme card's tooltip instead, as in classic.
- The draft typed in the composer and the open thread survive switches both ways.
- Footer Back on Pull Requests and Usage spans the footer row, as classic's and T3's `SidebarMenuButton` do, so a click in the empty footer goes back.

## Left

- With the sidebar collapsed in full screen, the breadcrumb starts about 110 pt right of the toggle. AppKit keeps that room after the sidebar tracking separator; the windowed layout is right.
- Glass Native shows its window when either appearance uses it (`ThemeLibrary.usesNativePresentation`). Picking Glass Native for light and Ember for dark gives the native window with Ember's dark palette. That is a choice for the user, not a bug fix.
- Glass Native's sidebar is 280 pt at its minimum against classic's 208 at 840 pt, so the detail column is narrower than classic's at T3's minimum window. That follows the phase 1 spec.
- The window's minimum height comes out at 640, not 620, in both modes.
- I didn't get to multi-select, rename, the context menu, drag, Settle, Snooze, Wake, the Settled shelf, the project filter, search and keyboard navigation on screen in this pass.
