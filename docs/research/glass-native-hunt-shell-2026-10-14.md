# Glass Native bug hunt: window shell and sidebar (2026-10-14)

Phase 6, half 1. I walked the window, the toolbar, the sidebar and the Settings, Pull Requests and Usage pages in a Debug build (`dev.candywrapper.test.gn-hunt-shell`) against the sandbox server, in Glass Native and in classic Glass, at 840x640, 1100x780 and full screen. The code review's findings for this half (`/tmp/gn-review-2026-10-14.md`, M1, M2, L1, L5 and L6) are folded in. Screenshots are in `/tmp/cw-peek/hunt-shell-*.png`.

## Fixed

Commits: 2a8c9ca (brand and page headers), c62df52 (sidebar place), adcd957 (row heights), 8a0f32c (header toggles and toolbar callbacks), 3b1b3b7 (draft headline).

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
- Command-click multi-select, the bulk menu ("Settle (2)", "Delete (2)"), the single-row menu, Rename from the menu, hover Settle with its undo notice, search with Return to open, the project filter, New thread's project chooser, and `thread.next` and `thread.jump.2` all work as in classic. Command-Z from the composer leaves a settle alone, as T3's `thread.undo` skips editable fields. Screenshots: `hunt-shell-multiselect-native.png`, `hunt-shell-context-multi-native.png`, `hunt-shell-rename-native.png`, `hunt-shell-settle-native.png`, `hunt-shell-search-native.png`.
- Footer Back on Pull Requests and Usage spans the footer row, as classic's and T3's `SidebarMenuButton` do, so a click in the empty footer goes back.

## Left

- With the sidebar collapsed in full screen, the breadcrumb starts about 110 pt right of the toggle. AppKit keeps that room after the sidebar tracking separator; the windowed layout is right.
- Glass Native shows its window when either appearance uses it (`ThemeLibrary.usesNativePresentation`). Picking Glass Native for light and Ember for dark gives the native window with Ember's dark palette. That is a choice for the user, not a bug fix.
- Glass Native's sidebar is 280 pt at its minimum against classic's 208 at 840 pt, so the detail column is narrower than classic's at T3's minimum window. That follows the phase 1 spec.
- The window's minimum height comes out at 640, not 620, in both modes.
- I didn't walk drag to reorder, Snooze, Wake, Pin from the menu, the Settled shelf or arrow-key navigation in the list on screen in this pass.

## Round 2

I walked what round 1 left, plus the sidebar actions and the menu bar, in a Debug build (`dev.candywrapper.test.gn-hunt2-shell`) against the sandbox server, at 840x620 and in full screen. Screenshots are in `/tmp/cw-peek/hunt2-shell-*.png`.

### Fixed

- The minimum height was 640. AppKit adds a toolbar's extra height to `minSize`, so Glass Native's 52 pt unified toolbar turned T3's 620 (DesktopAppSettings.ts:61) into 640. `MainWindow` now sets `contentMinSize`, which is the frame here and stays 620 through toolbar changes. Classic was 620 all along; round 1 measured it after a switch. Commit a16c0c8. After: `hunt2-shell-minsize-after.png`.
- With the sidebar collapsed in full screen, the breadcrumb started 110 pt right of the toggle. The sidebar tracking separator keeps the items after it where the toggle sits beside the traffic lights, and in full screen the toggle moves left without them. The separator now leaves the toolbar while the sidebar is collapsed, and windowed the breadcrumb lands where it did. Commit 8613bb3, test `collapsedSidebarDropsTheTrackingSeparator`. Before and after: `hunt2-shell-fullscreen-collapsed-before.png`, `hunt2-shell-fullscreen-collapsed-after.png`.
- Dragging a row onto the Settled shelf did nothing. Classic settles it, since T3's `sectionAtSidebarSlot` reads the section off the shelf header. The native drop rule now settles a drop on or under the Settled header. Commit 6ac2090, test `dropTargets`. Before and after: `hunt2-shell-drag-settle-before.png`, `hunt2-shell-drag-settle-after.png`.
- A right click on a row of the project filter's popup opened the thread menu of the row under the popup, because AppKit asked the native table for its menu. The table now answers only when the click lands on it. Commit d2d3e1a, test `rightClickOnACoveringPopupOpensNoThreadMenu`. Before: `hunt2-shell-project-rclick-before.png`.
- The toolbar took clicks while a dialog showed, so the sidebar toggle collapsed the sidebar behind the Delete confirm. T3's backdrop covers its header. The toolbar's items now turn off while a `ModalHost` shows. Commit aa39659, test `dialogsMakeTheToolbarInert`. After: `hunt2-shell-dialog-toolbar-after.png`.
- View > Actual Size, Zoom In and Zoom Out did nothing in native mode, a ponytail from phase 1. Each column now scales its content as classic scales the window's content view. The toolbar and the column widths keep the system's size, marked with a ponytail. Commit fa15543, test `zoomScalesTheColumnsContent`. After: `hunt2-shell-zoom-native-after.png`.

- The native sidebar was 320 pt by default, between 280 and 380, which pushed the chat and narrowed the composer. It now takes T3's widths from threadSidebarWidth.ts: 256 by default, at least 208 raised to the toolbar brand's right edge plus 12 so the brand never overflows into the ">>" menu, and at most the window less 640. At 840 pt that is about 240. The split view's autosave name changed, so a width saved under the old default resets. Test `sidebarTakesT3sWidths`. After: `hunt2-shell-sidebar-256.png` at 1100, `hunt2-shell-sidebar-840.png`, `hunt2-shell-sidebar-840-light.png` and `hunt2-shell-sidebar-fullscreen.png`.

### Checked and fine

- Pin and Unpin from the menu work, with the undo notice. I restored the pins to MCP hub fork, then MCP hub.
- A pinned row dragged into the inbox unpins, as classic's planner does.
- Snooze lists In 1 hour, In 3 hours, This evening, Tomorrow, Next week and Custom. Snoozing shows the Snoozed shelf, and Wake from the menu brings the row back and removes the shelf.
- The Settled shelf opens and closes from its header, with Show N more.
- Arrow keys walk the list and open each thread while the list keeps focus. Cmd+2 opened the second row.
- Delete opens T3's confirm (`hunt2-shell-delete-confirm-native.png`). I cancelled it.
- T3's menu bar has no thread commands (`DesktopApplicationMenu.ts`). Reload, Force Reload, Toggle Full Screen and the Window menu work the same in both modes and show the same shortcuts (`hunt2-shell-view-menu-native.png`).
- Cmd+B in the composer stays with the editor in both modes, as T3's sidebar toggle skips editable fields (AppSidebarLayout.tsx:105-112).
- Neither mode's sidebar has project headers, so there is no project header menu to walk. The project filter's popup keeps classic's per-project settings buttons.

### Left

- A dialog's backdrop can't dim the native toolbar the way T3's dims its header. The items turn off instead.
- A jump shortcut doesn't scroll the sidebar to the thread it opens, in either mode.
