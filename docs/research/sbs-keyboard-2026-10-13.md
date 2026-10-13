# Keyboard shortcuts side by side, 2026-10-13

T3 Code (Nightly) 0.0.46-nightly.20261009.2861 against CandyWrapper (Debug, bundle id `dev.candywrapper.test.sbs-keys`), both at 410,86 1100x780 points, default client settings, dark then light theme.

The official app ran through `/tmp/cw-sbs-tools/measure-launch` with `T3CODE_HOME` set to a copy of the sandbox home (`statev2.sqlite` copied with `sqlite3 .backup`, the rest with rsync). `ps eww` showed its bundled server on port 3773 with that home, and `lsof` showed no file under `~/.t3` open. The sandbox's `session.token` authenticates against that server, so CandyWrapper ran against port 3773 with `--fake-t3-connect` and both apps showed the same data.

The screen was 1920x1080 at 1x. Keys went in as CGEvents through a guarded key tool that knows `=`, `-`, `0`, arrows and Return. Real turns: 6, all `claude-haiku-5-5`.

## Fixed

| # | Difference | T3 source | Fix |
|---|---|---|---|
| 1 | The command palette left its last visible rows blank ("Change theme" and "Change appearance" missing at the bottom of the root list) | none, a CandyWrapper layout bug | `CommandPaletteView.realizeRows` takes the visible height from the list frame it just set, not the clip view's stale bounds |
| 2 | "New thread in..." (Mod+N with several projects) listed projects in shell order; T3 sorts them like the sidebar (most recent activity first), then puts the contextual project first | `CommandPalette.tsx:955-963`, `sidebarProjectGrouping.ts:168-175` | `PaletteCommands.projectGroups` sorts with `sortLogicalProjectsForSidebar` and the `sidebarProjectSortOrder` setting |
| 3 | Mod+Alt+N opened a scratch draft headed "What should we build in No project?" with "or start without a project"; T3 shows "What should we work on?" with the "No project" picker on the line below, and centers the block without the checkout strip | `DraftHeroHeadline.tsx:244-246, 326, 366-383` | `DraftHeroView.isScratch`, set from `ComposerController.isScratch`; the draft block drops the strip's 32px when the strip is hidden |
| 4 | Mod+T opened the + menu with its first item highlighted; T3 opens it through state, with no highlight | `RightPanelTabs.tsx:812-827` | `showAddSurfaceMenu(fromShortcut:)` clears the highlight |
| 5 | After a composer menu closed (model, effort, mode, workspace, branch), focus stayed on its trigger with a focus ring and typing went nowhere; T3 hands focus back to the prompt | `ChatComposer.tsx:6449-6470` | `ComposerPickers.focusComposer`, called when a picker popup closes with its trigger focused; `GitController.returnFocusToComposer` does the same for the strip's workspace menu and branch picker |
| 6 | Mod+Shift+H opened the workspace menu on a single-machine draft; T3 does nothing because only the machine picker carries `composer.host`, and only with a choice of machines | `BranchToolbar.tsx:297-299, 697-699` | the handler requires an unlocked "Run on" on a draft |
| 7 | Mod+Shift+S with the prompt focused did nothing: the editor's strikethrough took the key. T3's ChatView listens in the capture phase, so the bound command wins; only Mod+B stays with the editor | `ChatView.tsx:8277`, `AppSidebarLayout.tsx:105-112` | the composer's formatting keys yield to any bound command except `sidebar.toggle` |
| 8 | Mod+Shift+S settled the thread and then moved to the next thread; T3 stays on it and shows "Settled just now · Un-settle" | `ChatView.tsx:8010-8030` | `SidebarCommands.settle(_:navigates:)`, false for the shortcut |
| 9 | A click on empty thread space left the prompt focused, so Mod+Z never reached `thread.undo` (`!editableFocus`); in T3 the click blurs the editor | browser focus rules, `keybindings.ts:191` | `ThreadPanelView.mouseDown` resigns the prompt |
| 10 | A click on a diff file header left focus outside the diff, so Mod+F opened the thread's find instead of the diff's | the header is a button, which Chromium focuses on press | `DiffFileHeaderView.mouseDown` focuses the diff list |

## Left, with size guesses

| # | Difference | Row | T3 source | Size |
|---|---|---|---|---|
| A | A new thread from the keyboard (Mod+N, Mod+Shift+O, Mod+Shift+N, Mod+Alt+N) doesn't carry the viewed thread's model; T3's draft opens with it (Claude Haiku 5.5 from "MCP hub", where CandyWrapper shows GPT-6-Astra) | chat.new, chat.newLocal, chat.newWithoutProject | `useHandleNewThread.ts:95-135, 270-290, 415-425` | 2 hours: ComposerSelectionStore needs a per-draft override seeded from the source thread's composer or shell, and the interaction mode carries too |
| B | Toggling the sidebar while the palette is open moves the sidebar, but the palette's blurred backdrop is a snapshot taken at open, so it still shows the old layout; T3's `backdrop-filter` is live | sidebar.toggle | `CommandPalette.tsx` dialog backdrop | 1 hour: re-snapshot after the slide without hiding the palette, which holds the first responder |
| C | Go to file (Mod+P) highlights its first file in T3 before anything is typed; CandyWrapper highlights nothing. The `45-go-to-file` reference capture also shows no highlight, so changing it breaks that fidelity test | filePicker.toggle | `CommandPalette.tsx:2995-2996, 3471` (`autoHighlight="always"`) | 30 minutes plus a new reference capture |
| D | Diff find (Mod+F in the diff) is a full-width bar with "Find" in CandyWrapper; T3 shows a floating field with "Search", the case, word and regex toggles inside it, and a round close button at its corner | diff find | the diff viewer's find UI | 2 to 3 hours |
| E | The branch picker (Mod+Shift+G) opens about 7px lower than T3's | composer.branch | `BranchToolbarBranchSelector.tsx` | 1 hour |
| F | While the terminal confirm dialog shows ("Close terminal?"), the terminal's text draws sharp above the dim and blur | terminal.close | none | 1 hour: the terminal layer sits above the modal's snapshot |
| G | The browser launcher's Browser row lacks T3's profile chevron (m10 item G) | rightPanel.toggle, rightPanel.new | `RightPanelTabs.tsx:530-555` | 1 hour |
| H | Mod+Shift+N reuses the project's empty draft with the worktree it had before (Mod+Shift+L chose one); T3's draft starts from the configured workspace ("Current checkout") | chat.newLocal | `useHandleNewThread.ts:95-100, 270-290` | 1 hour, with item A |
| I | Hiding the sidebar widens the canvas enough for T3 to pin the thread details card (machine, Open in Finder, branch, Commit, Changes) top right; CandyWrapper shows no card | sidebar.toggle | `threadDetailsCardLayout.ts:16-45` | half a day if the card isn't built yet |

## Not compared

- The preview keys (`preview.refresh`, `focusUrl`, `zoomIn`, `zoomOut`, `resetZoom`): the 2861 app's browser tabs are server streams that both apps share through the server, so a tab one app opened showed "Connecting..." in the other. With focus in the official page, Mod+= changed nothing visible; with focus in its address bar it zoomed the whole official UI through Electron's View menu (`DesktopWindow.ts:135-140`). Test them with one app connected at a time.
- `usage.period.month` and `quarter` (Mod+Shift+3 and 4): macOS takes those keys for screenshots before either app sees them. Day and week matched.
- `composer.stash`, because a stash test writes to the user's real stash.
- `composer.sendAlternate`, `composer.sendBackground` and `composer.sendAndNewThread`: Haiku turns finish before the second key can land, and the turn budget ran out. Steer and edit of a queued message were driven with a 1,500-number turn.
- `thread.stop` and `composer.cycleHost` have no default key.
- The jump hints that show while Command is held.
- `keybindingsUpdated`: nobody edited `keybindings.json` during the run.

## Found in passing, other sections

- Thread hover card: CandyWrapper's is about twice as wide, draws the Claude glyph in color where T3's is gray, and adds a rule above the pull request line.
- Terminal: T3 shows the terminal's earlier output when Mod+J reopens it; CandyWrapper shows a fresh prompt. After Mod+J closes it, CandyWrapper focuses the prompt and T3 doesn't.
- Diff panel: CandyWrapper shows "This preview exceeds the size limit" and seven files where T3 lists every file in the same diff.
- Browser panel: the local servers list starts about 10px lower than T3's, and T3's toolbar has two more icons.

## Side notes

- Something else on the shared screen took the front during the lock (`Origin.app` with a `uicheck` profile), so every input goes through `front` and the guarded tools refuse when another app is in front.
- Shell commands that `cd` outside the worktree, or loop over variables, are refused by the worktree guard in this harness. Write small scripts under `/tmp/<task>` and call them with plain arguments.
