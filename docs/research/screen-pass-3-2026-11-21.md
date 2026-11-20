# Screen pass 3, 2026-11-21

Third on-screen pass, on branch `screen-pass-3` from `catchup-4928` (480327a2), in a real window on this Mac against the 4928 sandbox (port 47392) and the 3824 sandbox (port 47391), with `--fake-t3-connect`. Images are in `~/CandyWrapper-research/sandbox/screen-pass-3-2026-11-21/`, written `$I/` below. Every T3 reference sits beside ours where `design/reference-4928` has one, in files named `...-ours-vs-t3.png`. Captures are 1x, since this screen is 1x.

The screen lock passed to `user-xcode` about 40 minutes into the pass, so I stopped driving the UI. The restore fix was proven with a unit test, not on screen, and the items marked "not reached" are those I had not got to by then.

## Ten images that show the state of the app

1. `$I/WRONG-access-menu-turn-off-overlap-default-dark-ours-vs-t3.png`
2. `$I/BROKEN-unrestricted-dialog-keys-ignored-over-picker-redesign-dark.png`
3. `$I/WRONG-new-thread-strip-unrestricted-for-codex-default-dark.png`
4. `$I/unrestricted-stacked-picker-footer-redesign-dark.png`
5. `$I/WRONG-assistant-bare-url-swallows-chinese-full-stop-default-dark.png`
6. `$I/BROKEN-settings-source-control-no-issue-trackers-section-4928-default-dark.png`
7. `$I/thread-160-tool-calls-opened-default-dark.png`
8. `$I/diff-copy-path-hidden-below-expanded-files-default-dark.png`
9. `$I/diff-changes-file-list-right-default-dark.png`
10. `$I/docked-picker-default-dark-ours-vs-t3.png`

## The build

`404faa4f` built `ComposerPickers.ModeInfo` in the app target for the new-thread strip's Unrestricted label, but the struct's memberwise init is internal to Features. `2eb19f0f` adds `ComposerPickers.unrestrictedMode` next to the other runtime modes, and the app uses it. No other error followed; `scripts/check-app-build` prints "app build ok".

## Fixed in this pass

- The Diff panel's Copy path button stayed lit while the pointer rested under the last file. The list fills the viewport and `DiffLayout.rowIndex(at:)` clamps to the last row, so empty space counted as the last file. `DiffListView.updateFileHover` now ignores points past `rowLayout.height`. Checked on screen with folded and expanded files and after an app switch, `$I/diff-copy-path-hidden-below-files-default-dark.png`, `$I/diff-copy-path-hidden-below-expanded-files-default-dark.png`.
- A Diff panel showed no files after a thread switch until Refresh, `$I/BROKEN-diff-panel-empty-after-thread-switch-before-fix-default-dark.png`. The switch cancelled a running git load but left `loadTask` set, and `setSummaries` reloads only when it is nil, so the new thread never loaded. `DiffPanelView.threadId` now clears it. `DiffCommitScopeTests.threadSwitchDuringALoadStillLoadsTheNewThread` failed before the fix and passes after. Three plain relaunches on 4928 restored the panel with its files, `$I/diff-restored-at-launch-shows-files-4928-default-dark.png`, so the bug needs a load in flight at the switch. Not rechecked on screen after the fix, because the screen lock had passed to the user.

Both are in `d7e2b7be`.

## Ranked wrong and broken items

| # | Item | Verdict | Likely file | T3 |
|---|---|---|---|---|
| 1 | The Unrestricted dialog opened from the access menu ignores Return and Escape in every theme. The picker behind it keeps the keys, so only a click closes it. From Settings, Return cancels as intended | broken | `Features/Pickers/UnrestrictedAccess.swift:101-115`, the picker popup should close or resign key before `ModalHost.present` | CandyWrapper's own dialog; T3's AlertDialog takes focus on open |
| 2 | "Turn off Unrestricted" overlaps the third line of the hint and spills out of the menu, in default and Redesign | wrong | `Features/Pickers/ComposerPermissionsView.swift:25, 100-101`: the hint frame is fixed at 32pt and the button at y 120 | own feature |
| 3 | With a Codex model picked on a new thread, the strip still reads "Unrestricted"; the menu itself is right with four segments and Full access | wrong | `App/Sources/ComposerController.swift:1949-1957` recomputes the strip only on config refresh, not on a model change | own feature |
| 4 | Settings > Source control & issues has no Issue trackers section on the 4928 sandbox, though the sidebar shows Issues | broken | `Features/Settings/SourceControlSettingsView.swift:108, 166-171` | `SourceControlSettings.tsx:658-660` |
| 5 | A bare URL right after a CJK letter runs on through 。 in assistant Markdown. The link target was `https://example.com/a%E3%80%82%E5%A5%BD`, while the sent message's link stops at 。 | wrong | `Features/Markdown/MarkdownDocument.swift:250`: `isWord` counts any byte ≥0x80, so `见https://` is skipped and Foundation runs it on | `shared/src/markdownPipeline.ts:467-657`; micromark only blocks an ASCII letter before the scheme |
| 6 | The Auto segment shows sparkles; T3 4928 uses a shield with a check | wrong | `Features/Pickers/ComposerPickers.swift:500` | `components/chat/runtimeModeConfig.ts:27-30` |
| 7 | Settings search misses 28 of T3's 164 entries, among them both screen reader rows, Two-line folder rows and Keep awake | wrong | `Features/Settings/SettingsSearchCatalog.generated.swift`, regenerate with `scripts/gen-settings-search.py` | `components/settings/settingsSearch.ts`, e.g. :524-533 |
| 8 | The Screen reader window title switch shows on neither General nor Chat, so its "on" state can't be reached from the UI | wrong | `Features/Settings/GeneralSettingsView.swift:349-355` builds it, but no routed page shows it | `SettingsPanels.tsx:1527-1561`, on Chat |
| 9 | Two-line folder rows switched on in Labs, and folder rows stayed one line, even for Blue on `main` | wrong | `Features/Sidebar/SidebarListCache.swift:370`, `SidebarRowViews.swift:1254`; maybe cached row heights are not invalidated | #26463 |
| 10 | The Diff panel folds every file again after an app switch, since each reload re-applies the default | wrong | `Features/Diff/DiffPanelView.swift:704` | `DiffPanel.tsx:678-692` keeps fold state per scope |
| 11 | The Diff scope menu keeps "Changes" lit while the pointer is on another row, so two rows look hovered | wrong | `Features/Diff/DiffPanelView.swift:875` and the DS menu's selected row | Base UI highlight follows the pointer |
| 12 | A truncated slash command description gets its tooltip from the keyboard but not from the pointer | wrong | `Features/Composer/Panels/ComposerCommandMenuView.swift` | `ComposerCommandMenu.tsx:211-217, 282`, active row by pointer or keys |

## Verdicts after screen-fixes-3

Branch `screen-fixes-3` from `catchup-4928` (560b1f0f). Each fix was checked in a real window on the 4928 sandbox, in default dark and Redesign dark where the surface exists in both. Crops are in `~/CandyWrapper-research/sandbox/screen-fixes-3-2026-11-21/`, written `$F/` here.

| # | New verdict | Cause and fix | Image |
|---|---|---|---|
| 1 | fixed | `PopupHost`'s key and click monitors kept routing Return and Escape to the menu under a dialog. The host now yields while a `ModalHost` sits above it, so every dialog opened from a popup owns the keyboard | `$F/item1-*` |
| 2 | fixed | The hint had a fixed 32pt frame and the button a fixed y. The hint now measures its lines and the button sits below them | `$F/item2-*` |
| 3 | fixed | `ComposerController` set the strip label only in `updatePickers`. The pickers' `onChange` now updates it too | `$F/item3-*` |
| 4 | fixed | The routed Source control page (`ConcernSettingsView` slices) never listed the `issue-trackers` group, so the section from 9c9bdc1e never showed against a server. The server and its `issues` capability were fine | `$F/item4-*` |
| 5 | fixed | The rewrite blocked any non-ASCII byte before a scheme. It now blocks only an ASCII letter, as micromark's `previousProtocol` does; `www.` keeps the word boundary | `$F/item5-*` |
| 6 | fixed | Auto uses `.shieldCheck` | `$F/item6-*` |
| 7 | fixed for the rows the app draws | The generator skips rows through `UNPORTED_IDS` and `UNPORTED_PATHS`. Two-line folder rows and Screen reader window title now exist and are searchable. 26 stay out: Screen reader announcements, Keep awake, Simlock hosts, Fast worktree checkout, Clone into host folders, Welcome page, Text generators, Device sources, the 15 Voice rows and the 2 Secrets rows, because CandyWrapper has no such row or page | `$F/item7-*` |
| 8 | fixed | Chat now has T3's Screen reader section with the window title switch. With it on, the title reads "Unknown Subject - demo-repo" | `$F/item8-*` |
| 9 | fixed | The sidebar's client settings observer ignored `boringSidebarMultilineRows`, so the switch took effect only after a relaunch. Rows with a branch go to two lines at once; a row without one keeps one line, as T3's `metaLineEmpty` does | `$F/item9-*` |
| 10 | fixed | `DiffPanelView.folds` keeps each thread and section's folds for the session (T3's `collapsedFileKeysByScopeKey`), and reloads apply them over `diffFilesCollapsed` | `$F/item10-*` |
| 11 | not a bug | T3's `MenuRadioItem` fills the checked row with `foreground/8%` (`menu.tsx:239`) while `data-highlighted` uses `--accent`, white 4% in dark (`index.css:1205`). T3 shows the same two lit rows | |
| 12 | not reproduced | The tooltip showed from the pointer with stepped moves, a single jump, entry from either side and a return to a row already shown. The earlier pass likely moved the pointer without a mouse-moved event | |
| "or start without a project" | fixed | The link opens the scratch project as the draft's project and keeps the typed text (`DraftHeroHeadline.tsx:189-203`). It hides when no machine offers a scratch folder. T3 then focuses the project trigger; here the composer keeps focus | `$F/start-without-project-after-click-default-dark.png` |

Dialogs and menus that shared the flaw:

- Item 1's cause sat in the shared popup host, so any `ModalHost` presented while a popup stays open had it, and the fix covers them all. On screen I found one such path, the Unrestricted confirm over the model picker. I did not drive every other menu-opened dialog.
- Item 11 needs no change in any menu.

Still wrong, found during the fixes:

- The draft hero gets no mouse-moved events on screen, so neither the project name's solid underline nor the new link's hover shows. It predates this branch. The hover drawing works offscreen (`ThreadPanelChromeTests.startWithoutAProjectIsAButton`).
- A Settings search for "issue trackers" opens Source control at its top, since the section loads after the scroll.

Earlier "not reached" items:

- The Diff panel restore fix (d7e2b7be) works on screen: a refresh followed at once by a thread switch, in both directions, three times, always showed the files, `$F/d7e2b7be-diff-restored-after-switch-during-load-default-dark.png`.
- The wide context strip, model chip popover, stacked banners, pasted images, queued thumbnail viewer, Zen's live line, child approvals, the full-screen HTML card, Show full message, quote card copy, issue badge colors, "vs main" and the theme background image stay not reached. Each needs a long message, a slow turn, a linked issue, a branch checkout or a fixture that this pass's turn budget and sandbox did not have.

Unrestricted is off on both sandboxes: `providerInstances.claudeAgent` reads `{"driver": "claudeAgent"}` on each, and no turn ran while it was on.

## Smoke tests

| Server | State | Verdict | Image |
|---|---|---|---|
| 4928 | Blue thread, one turn, six fast sidebar toggles, palette, Settings, in default dark, default light and Redesign dark | works | `$I/smoke-4928-*.png` |
| 3824 | No project thread, one turn, the same steps in the same three themes | works | `$I/smoke-3824-*.png` |

A fresh test profile starts in default dark with the "Wrapper" sidebar art, not Redesign. Cmd+Q holds to quit by default, so I ended my app with SIGTERM.

## Unrestricted access

Counts: 12 works, 2 wrong, 1 broken.

| Item | State | Verdict | Image |
|---|---|---|---|
| Fifth segment | Claude, access menu | works | `$I/unrestricted-access-menu-fifth-segment-hover-redesign-dark.png` |
| Fifth segment absent | Codex model on a new thread | works | |
| Hint on hover | Redesign dark, default dark | works | same |
| Dialog | Redesign dark, default dark, default light | works for the look | `$I/unrestricted-dialog-redesign-dark.png`, `$I/unrestricted-dialog-default-dark.png`, `$I/unrestricted-dialog-default-light.png` |
| Cancel's initial focus and Return | From Settings | works: Return cancels and focus goes back to the switch | `$I/unrestricted-dialog-from-settings-redesign-dark.png` |
| Return and Escape | From the access menu | broken, item 1 | `$I/BROKEN-unrestricted-dialog-keys-ignored-over-picker-redesign-dark.png` |
| Turning it on | From Settings and from the menu | works: the server's `claudeAgent.environment` gains the variable with value "1" | |
| Trigger label | Default and Redesign | works | `$I/unrestricted-trigger-label-default-dark.png`, `$I/unrestricted-composer-on-redesign-dark.png` |
| Picker footer chip | Default and Redesign | works | `$I/unrestricted-docked-picker-footer-default-dark.png`, `$I/unrestricted-stacked-picker-footer-redesign-dark.png` |
| New-thread strip | Claude draft | works | `$I/unrestricted-new-thread-strip-default-dark-ours-vs-t3.png` |
| New-thread strip | Codex draft | wrong, item 3 | `$I/WRONG-new-thread-strip-unrestricted-for-codex-default-dark.png` |
| Settings switch follows a hand edit | Removing the variable row, adding it back | works both ways; a hand-added row is sensitive and redacted, and the switch still reads on | `$I/add-variable-hover-redesign-dark.png` |
| Menu with Unrestricted on | Hint and Turn off row | wrong, item 2 | `$I/WRONG-turn-off-unrestricted-overlaps-hint-*.png` |
| Turn off Unrestricted | 4928 and 3824 | works: the variable is gone from both servers' `settings.json` | |

Unrestricted is off on both sandboxes. `providerInstances.claudeAgent` reads `{"driver": "claudeAgent"}` on each, and no turn ran while it was on.

## Redesign's stacked picker

Counts: 6 works.

| Item | Verdict | Image |
|---|---|---|
| Tabs, search, account card, rows, Show more, levels and footer on one line | works | `$I/unrestricted-stacked-picker-footer-redesign-dark.png` |
| Typing filters the list | works | |
| Tab walks list, Reasoning, footer | works | |
| Right arrow to the access chip, then Return opens its menu with Unrestricted selected | works | `$I/unrestricted-access-menu-selected-keyboard-redesign-dark.png` |
| 3824: Ultracode as a full-width row under the levels, Full access in the footer | works | |
| The default themes keep T3's two-column picker | works | `$I/docked-picker-default-dark-ours-vs-t3.png` |

The account card blurs the e-mail on screen. My crops leave the card out anyway.

## Composer

Counts: 5 works, 1 wrong, 6 not reached.

| Item | Verdict | Image |
|---|---|---|
| Markdown markers appear inside bold and code and collapse when the caret leaves | works | `$I/composer-markdown-caret-*.png` |
| Undo and redo around the markers | works | |
| A file chip copied from one draft and pasted into another stays a chip | works | `$I/composer-file-chip-pasted-into-other-draft-default-dark.png` |
| Command description tooltip from the keyboard | works | `$I/composer-command-description-tooltip-keyboard-default-dark.png` |
| Command description tooltip on pointer hover | wrong, item 12 | `$I/WRONG-composer-command-tooltip-missing-on-pointer-hover-default-dark.png` |
| Undo on a typed run removes the whole run, as one insert from the type tool | works | |
| Wide context strip, model chip popover, stacked banners, pasted images at the caret, queued thumbnail viewer | not reached | |

## Sidebar

Counts: 2 works, 1 wrong, 1 not reached.

| Item | Verdict | Image |
|---|---|---|
| Labs shows the Two-line folder rows switch once Boring sidebar is on | works | `$I/labs-two-line-folder-rows-switch-default-dark.png` |
| Folder rows on two lines | wrong, item 9 | `$I/sidebar-two-line-folder-rows-default-dark.png` |
| Project filter popup below the icon, start-aligned, 288pt (`Sidebar.tsx:3064-3067`) | works | `$I/sidebar-project-filter-popup-default-dark.png` |
| Issue badge colors | not reached: no thread links an issue | |

## Thread

Counts: 4 works, 1 wrong, 5 not reached.

| Item | Verdict | Image |
|---|---|---|
| 160 tool calls load folded as "Worked for 34s" and "Ran 160 commands" | works | `$I/thread-160-tool-calls-folded-default-dark.png` |
| Opening both levels after a reload keeps the user message in place | works | `$I/thread-160-tool-calls-opened-default-dark.png` |
| Cited file link: the tooltip shows the sandbox path and a click opens the file | works | `$I/thread-cited-file-link-hover-default-dark.png`, `$I/thread-cited-file-link-opens-file-default-dark.png` |
| Bare URL before 。 in a sent message | works | `$I/thread-bare-url-before-chinese-punctuation-default-dark.png` |
| Bare URL before 。 in an answer | wrong, item 5 | `$I/WRONG-assistant-bare-url-swallows-chinese-full-stop-default-dark.png` |
| Zen's live answer line | not reached: Haiku answered within 1.5 s | |
| Child approvals card, full-screen HTML card, Show full message, quote card copy | not reached | |

## Pull requests and panels

Counts: 8 works, 3 wrong, 2 fixed, 1 not reached.

| Item | Verdict | Image |
|---|---|---|
| Changes file list on the right | works | `$I/diff-changes-file-list-right-default-dark.png` |
| Its drag handle resizes the list | works | `$I/diff-file-list-after-drag-default-dark.png` |
| Commits submenu, "No commits on this branch." on `main` | works | `$I/WRONG-diff-scope-menu-highlight-stays-on-changes-default-dark.png` |
| Two lit rows in the scope menu | wrong, item 11 | same |
| "Uncommitted" scope label | works | |
| "vs main" label | not reached: the sandbox checkout is on `main` | |
| Hide-tests toggle hides `src/util.test.ts` | works | `$I/diff-hide-tests-on-default-dark.png` |
| Pressed and unpressed header toggles look the same | unverified, no T3 capture with them pressed | |
| Files fold again after an app switch | wrong, item 10 | |
| Copy path below the last file | fixed | see above |
| Panel empty after a thread switch | fixed | see above |
| No project details card on 3824: machine, Open in Finder, Add project script, no git rows | works | `$I/no-project-details-card-3824-default-dark-ours-vs-t3-project-thread.png` |
| Window title "project / thread" with the switch off | works: "No project / Say Pong", "demo-repo / Blue" | |
| Window title with the switch on | wrong, item 8: the switch can't be reached | |

## Settings

Counts: 0 works, 2 wrong, 1 broken, 1 not reached.

| Item | Verdict | Image |
|---|---|---|
| Issue trackers under Source control | broken, item 4 | `$I/BROKEN-settings-source-control-no-issue-trackers-section-4928-default-dark.png` |
| Search for "screen reader" | wrong, item 7 | |
| Screen reader window title row | wrong, item 8 | |
| Theme background image | not reached: no fixture has a published theme with an image | |

## "or start without a project"

The link is still inert, and CandyWrapper should match T3. At 4928 the link shows only when the server offers a scratch root and the draft is not already scratch (`DraftHeroHeadline.tsx:323-346`). A click runs `projectEnvironment.openScratch`, then selects the scratch project as the draft's project and focuses the project trigger (`DraftHeroHeadline.tsx:189-203`, `useScratchProject.ts:65-92`). CandyWrapper already has the request in `App/Sources/PaletteCommands.swift:631` (`startScratchThread`), but that opens a new thread, while the link keeps the current draft and changes its project. The inert link is `Features/Composer/DraftHeroView.swift:133`.

## Turns

5 of 10 Haiku turns: two smoke turns, the 160-command turn, the URL turn and the file link turn.
