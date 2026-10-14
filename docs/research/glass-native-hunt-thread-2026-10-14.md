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

## Round 2 (2026-10-14)

I walked the items round 1 left, in a Debug build with `CANDY_THEME=candywrapper-glass-native` and then classic Glass, on the sandbox server at 47391 with a 1100 pt window. Six real turns on `claude-haiku-5-5`. Screenshots are in `/tmp/cw-peek/hunt2-thread-*.png`.

### Fixed

1. A refused diff request showed another repo's diff. The panel retried a `review.getDiffPreview` the server refused ("must stay within the configured workspace root") at the server's own cwd, which 2861's web client did (DiffPanel.tsx:354-374). Nightly 2994 dropped that retry, since its server accepts every registered project root (ReviewService.ts:95-113), and shows the error in `text-error/80` above "No patch available for this selection." (DiffPanel.tsx:342-353, 1074-1076). `ThreadSession.gitDiffLoader` now passes the error through and `DiffPanelView` shows it, in every theme. The panel's error display already had `LaunchAndDiffStateTests.failedTurnDiffShowsErrorAndNoPatch`. 6859d40, `hunt2-thread-diff-error-after.png`.
2. The stash menu kept its old height after a delete, leaving an empty band under the last row. Both themes. `ComposerStashMenuView` rebuilt its rows but never asked its host to lay it out again from `preferredHeight`. Test `ComposerAttachmentsTests.stashMenuAsksItsHostToResize`. 1b5adc6, `hunt2-thread-stash-delete-before/after.png`.
3. Native mode: three right panel tabs overflowed into the scroll arrows. At 1100 pt the native sidebar's 320 pt leaves the panel 420 pt (classic gets 484 beside its 256 pt sidebar), and the strip reserved 176 pt for the toolbar's 152 pt control. The control's segments now take T3's 28 pt button width (`size-7`) with unscaled glyphs, 140 pt in all, and the reserve is 158. Diff, Terminal 1 and Files fit with no arrows. The toggles stay where they were. Test `RightPanelTabDragTests.nativeStripFitsThreeTabsAtTheNarrowDefault`, which fails at 176. 8a81a53, `hunt2-thread-tabstrip-before/after.png`.

### Checked, no bug

- Pasting an image shows its thumbnail, and its remove button clears it.
- `$` opens the skills menu, and Escape closes it.
- Cmd+S stashes, the badge counts, Cmd+S on an empty composer restores one entry or lists several, and the menu's delete works.
- Enter during a turn queues the message under a "Queued" header with Edit, Steer and remove. Stop interrupts the turn. Haiku finished before Steer could land, so I saw steered messages only from history, where their "Steer" labels render.
- After a stop the send button shows a play glyph, "Resume thread", while the prompt is empty. T3 does the same: `resumableRunId` is the interrupted run (ChatView.tsx:2147-2150, 11616), and `ComposerPrimaryActions.tsx:270-280, 337-339` swaps in `PlayIcon`. Classic shares the button.
- Files search filters with T3's fuzzy match. The Device panel draws its cards on the frost.
- "Numbers 1 to 1000 as words", the sandbox's longest thread: scrolling to the top and back, and rail jumps, drew nothing wrong under the toolbar fade.

### Left

- The Device panel showed "Enable the device hub" in native mode and "Allow agent control" with Done in classic a few minutes later, with a longer Android error. Both come from the server's device state, and I didn't toggle anything, so I put it down to the shared sandbox changing. Not confirmed.
- The huge synthetic perf thread exists only inside the benchmarks, so I walked the sandbox's longest real thread instead.
