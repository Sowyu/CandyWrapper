# Glass Native bug hunt, the thread half (2026-10-14)

Phase 6, half 2: the thread, the composer, the panels, the menus and the palette. I walked each action in a Debug build with `CANDY_THEME=candywrapper-glass-native`, then in classic Glass, against the sandbox server on 47391. Two real turns on `claude-haiku-5-5`. Screenshots are in `/tmp/cw-peek/hunt-thread-*.png`.

## Fixed

1. The diff kept its old width after the right panel changed size, and its Files tree showed no rows. Both themes. Maximize left a band of empty frost right of the diff, and Restore left the diff wider than the panel. The tree was laid out while hidden at zero width and never again. Cause: `ScrollAreaView` documents that size themselves to the clip (`DiffListView`, `FileTreeView`) lay out only when asked, and a new clip width didn't ask. `ScrollAreaView.layout` now marks the document for layout when the clip width changes. Test `ScrollAreaFadeTests.newClipWidthLaysTheDocumentOut`. 188f342. Screenshots `hunt-thread-diff-maximized-before/after`, `hunt-thread-diff-tree-before/after`, `hunt-thread-diff-restore-before`.
2. Review H1: the native approval card gave Approve a bare Return key equivalent. T3 binds no key (ComposerPendingApprovalActions.tsx). On screen a Return in the sidebar search and in the terminal did not approve, since those views take the key first, so it fires only when no view handles Return. It is gone, and Approve keeps its tint. Test in `NativeTimelineTests.approvalButtonsKeepT3sWording`. 531515e.
3. Review L2: after a switch to Glass Native, Maximize showed over a right panel sheet. The toolbar seed now reads the panel's `isMaximizable`. 9979bcc.
4. Review L3: native menus closed on a checkbox or a stay-open radio, where classic and Base UI keep the menu open, and lost trailing text such as "Anyone" or turned it into a live key. `NativeMenu.canExpress` now keeps those menus custom on glass. Selects still go native. Test `NativeMenuTests.stayOpenRowsAndTrailingTextStayCustom`. a41a0b5.
5. Review L4: the composer strip's Run on menu left focus on the strip in native mode, because the `NSMenu` has closed before `MenuPopupView.show` returns and no onClose hook attaches. Focus now moves right away in that case. Checked on screen: typing after a pick lands in the prompt. 1104005, `hunt-thread-runon-focus-after.png`.
6. Native menus showed no icons. macOS 27 hides `NSMenuItem` images unless `preferredImageVisibility` is `.visible` (NSMenuItem.h). It is not a user setting. Every native menu item with an image now asks for it, including the sidebar's destructive rows and the approval More menu. 14e4cd6, `hunt-thread-menu-icons-after.png`.
7. The composer's / and @ menus slid under the toolbar in a new thread, where the composer sits mid-window. The menu's room started at the window top, but the native toolbar covers the top 52 pt and draws over the content. The room and `PopupHost`'s placement area now start under the toolbar in native mode. Classic keeps the whole window. 769c32c, `hunt-thread-slash-under-toolbar-before/after.png`.

## Checked, no bug

- The coordinator's lead on the Glass opacity slider: it applies live in native mode. At 10% the detail frost and the composer both lighten at once (`hunt-thread-opacity-10-native.png`).
- Down arrow moves the palette's highlight. Typing clears the highlight on purpose and Enter still runs the first row (`CommandPaletteController`). The earlier failure was likely input sent while another app was frontmost.
- Diff with content renders in native mode: files, hunks, wrap, split, the tree after fix 1, the scope and base ref menus. The base ref chooser hides at the native panel's 410 pt width, by the same rule as classic.
- The composer collapses to one line while the timeline is scrolled up, and a thread switch returns to the bottom. Classic does both the same.
- Draft text, including multiple lines, survives a thread switch. The model, effort and access pickers, the workspace menu, the + menu with its letter keys, the terminal drawer, split and terminal tab, the browser tab, fork, the running turn's indicator and stop button and the palette's Change theme and New thread in… submenus all work.

## Left

- The sandbox servers run with cwd `/Users/mrm/CandyWrapper`, and T3 refuses a review diff outside its workspace root or managed worktrees (ReviewService.ts:70-105). `ThreadSession.gitDiffLoader` then retries with the server's cwd and silently shows that repo's diff, so every current-checkout thread in the sandbox shows "No net changes". A thread on a managed worktree shows its diff. The fallback predates Glass Native. T3 shows the error instead. Ask the user before changing it.
- With two tabs the right panel's tab strip already scrolls ("Termi…" with arrows), because the toolbar's glass control is wider than classic's three icons. It needs a layout decision, not a guard.
- While the palette is open, the toolbar's breadcrumb and panel toggles stay sharp above the dimmed window, while the brand blurs. Classic dims the whole window. Minor.
- For the shell half: in Settings, a search result left General highlighted beside Appearance; after Settings closes the footer's gear stays highlighted; the forked thread and its parent both showed a selection fill.
- Not walked for lack of time: pasting an image, $ skills, the stash, queue and steer during a turn, Files search, Pull request and Device panels, and the huge synthetic perf thread, which lives only on the perf server.
- The full suite passed once after these fixes, fidelity tests included. ThreadCacheTests and LocalServerIntegrationTests, which flaked once for the 5a agent, passed.
