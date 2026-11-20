# Screen pass, 2026-11-20

The first look at the Nightly 4928 port in a real window, on branch `screen-pass` from `catchup-4928` (8b1ecd8f). Images live in `~/CandyWrapper-research/sandbox/screen-pass-2026-11-20/`, called `$O` below. File names start with `BROKEN-` or `WRONG-` when they show a defect. Pairs named `ours-vs-t3` hold CandyWrapper on the left and T3's `design/reference-4928` crop on the right.

The app ran against the 4928 sandbox on port 47392 with `--fake-t3-connect`, in default dark, default light and Redesign dark, in a 1342 by 912 pt window on a 1x screen. It used 12 real Haiku 5.5 turns.

## Verdicts after screen-fixes, 2026-11-20

Branch `screen-fixes` from `catchup-4928`. Before and after crops live in `~/CandyWrapper-research/sandbox/screen-fixes-2026-11-20/`, called `$F` below. Each fix was checked in a real window against the 4928 sandbox, and the rail in default dark, default light and Redesign dark.

1. Fixed. The rail never needed the app switch: any pointer that moved right off the rail onto the card or the messages kept the fisheye and card up, because the hover area still held T3's old 352pt band and the card. At 4928 the hit strip is at most 40pt (MessagesTimeline.logic.ts:482-497) and the card is `pointer-events-none` (TimelineMinimap.tsx:229). `$F/rail-exits-after-fix-default-dark.mov`.
2. Fixed. Reply was gated on `serverUpdateStaging`, which only boot-service installs report; it now keys on `shellThreadFamilies`. `$F/reply-banner-after-default-dark.png`.
3. Fixed. The panel hid only the banners it listed when they left the stack, and the fresh-session, reply and fallback banners were missing. `$F/fresh-session-banner-on-new-thread-after-default-dark.png`.
4. Fixed in code. The link hit view gave quote cards their URL as a tooltip. Not seen on screen: synthetic drags did not select reply text, so no new quote card could be sent.
5. Not a bug. The tooltip names `sky.png` because it belongs to the `sky.png` image cell now under the still pointer; the header beside it names `sky2.png`. HoverSync opens it as Chromium's hover update after layout does.
6. Fixed. A card due 150ms after the hover opened beside a menu a quick right-click had opened; and a card the host closed left the list thinking it was open. `$F/sidebar-context-menu-no-hover-card-after-default-dark.png`.
7. Fixed. Stop now follows Submit. `$F/question-card-submit-then-stop-after-default-light.png`.
8. Fixed in part. The first click selected on this build; the second lit row was the focus fill from the model click, which T3 draws only for `focus-visible`.
9. Fixed for model rows. Redesign's list got no `mouseMoved`; it now takes HoverSync's pointer moves. `$F/docked-picker-row-hover-after-redesign-dark.png`. Legacy models opening on click is unchanged: it is a toggle, and Redesign is our own look.
10. Not a bug. The paste tool exited right after writing, and another process then reads only its first pasteboard item. With the writer alive both files attach. `$F/paste-image-and-file-together-now-default-dark.png`.
11. Already fixed before this pass: the nav reads "Source control & issues".
12. Not reproduced. Archive lit in the nav when opened from the nav and from the palette with Settings closed. `$F/settings-archive-nav-highlight-now-default-dark.png`.
13. Fixed. The dialog says "once at a set date".
14. Fixed. The workspace icon trails the environment row. `$F/thread-details-env-row-after-default-light.png`.
15. Fixed. File chip icons keep their file-type color, gray for text; seen in the composer chip.

The two side-by-side differences the pass did not rank are different states. T3's model jump keys need `isDesktop` and the reference came from the web build; "Default" shows beside a default level that is not selected, and T3's capture had Medium selected (ComposerModelEffort.tsx:219-232). The image above a bubble with text joins at a 6pt corner, `rounded-br-md` (TimelineUserMessageRow.tsx:559); T3's capture had no text.

Not reached this time: the title glimmer, folder drop, the rename field, the project filter notice, the prompt suggestion, send while uploading, "Stopping…", Resume's click guard and the undo notice's hover, which expired (5 s, as T3) before the pointer got there. Seen but not fixed: the sidebar's draft row shows its raw prompt, `[todo.txt](t3-context://…)`, in default and Redesign; that belongs to the sidebar task.

## Ten images that show the state of the app

1. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/BROKEN-message-rail-stuck-after-app-switch-default-dark.png`
2. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/BROKEN-reply-button-no-banner-default-dark.png`
3. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/BROKEN-fresh-session-banner-leaks-to-new-thread-default-dark.png`
4. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/WRONG-quote-card-raw-url-tooltip-default-dark.png`
5. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/WRONG-question-card-stop-before-submit-default-dark-ours-vs-t3.png`
6. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/model-switch-divider-default-dark-ours-vs-t3.png`
7. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/media-and-file-card-default-dark-ours-vs-t3.png`
8. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/approval-and-viewed-images-window-default-dark.png`
9. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/issues-empty-default-dark-ours-vs-t3.png`
10. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2026-11-20/docked-picker-default-light-ours-vs-t3.png`

## Broken and wrong, ranked by how much the user would notice

1. Broken: the message rail stays in its hovered fisheye with its card open after an app switch. Hover the rail, switch to another app and back, then move the pointer off the rail: the card and fisheye stay, 2.6 s later too, until the pointer enters the rail again. Seen in default dark (app confirmed frontmost) and Redesign dark. Likely `Features/Thread/ThreadMinimapView.swift:230` and its HoverSync area missing the exit after reactivation. T3 clears on any exit or lost focus, `TimelineMinimap.tsx:155, 185`.
2. Broken: "Reply to this response" does nothing. The button and its tooltip show, two clicks add no reply banner. `App/Sources/ComposerController.swift:2657-2673`: one of the silent `guard ... else { return }` lines or `ComposerReply.record` returning nil. T3: `TimelineAssistantRows.tsx:279` and `ChatComposer.tsx:2572`.
3. Broken: after `/clear`, the "Your next message starts a fresh session" banner leaks. Archiving that thread lands on the new-thread page and the banner floats near the window's bottom edge, away from the composer, and stays. Likely `App/Sources/ComposerController.swift:274-276` (`freshSessionArms` keyed per thread) with `Features/Thread/ThreadPanelView.swift:418-420` still showing `freshSessionKey` on the draft route. T3 scopes it to the thread, `freshSessionArms.ts` and `ChatComposer.tsx:1158`.
4. Wrong: hovering a quote card in a sent message shows its raw `t3-citation://v1/...` URL as a tooltip. T3 replaces the link with `AssistantCitationEmbed`, which has no URL tooltip, `AssistantCitationChip.tsx:117` and `ChatMarkdown.tsx` from #34181. Likely the card text keeps a `.link` attribute, `Features/Thread/ThreadAssistantCitation.swift` or `Features/Markdown/MarkdownView.swift`.
5. Wrong: after Approve on the first of two inline approvals, the rows shift under a still pointer and a full-path tooltip pops up over the "Read ..." header. `$O/WRONG-stale-path-tooltip-after-approve-default-dark.png`. Likely the TooltipController on the work row's path in `Features/Thread`.
6. Wrong: right-clicking a sidebar row opens the context menu with the row's hover card still open beside it. T3 shows no hover card with the menu, reference `20-sidebar-thread-context-menu`. Likely `Features/Sidebar` row hover card; T3 `SidebarThreadRow.tsx:617`.
7. Wrong: the question card puts Stop before Submit. T3 renders the action first and Stop after it, `ComposerPrimaryActions.tsx:296-302`. Likely `Features/Composer/ComposerPrimaryButton.swift`.
8. Wrong: in the docked picker, after a click picks a model, the first click on an effort row only highlights it. A second click selects it, and the old row stays highlighted too. `$O/WRONG-docked-picker-effort-first-click-ignored-default-dark.png`. Likely `Features/Pickers`.
9. Wrong: Redesign's docked picker rows show no hover highlight, and Legacy models opens only on click. `$O/WRONG-docked-picker-no-row-hover-redesign-dark.png`. Likely `Features/Pickers` Redesign row styling.
10. Wrong: pasting an image and a text file together attaches only the image. The text file attaches when pasted alone. Likely `Features/Composer/ComposerAttachments.swift` paste path; T3 `ChatComposer.tsx` onPaste takes every file.
11. Wrong: Settings nav says "Source control" where 4928 says "Source control & issues", `settingsSearch.ts:110`. Ours: `Features/Settings/SettingsShellViews.swift`. Voice is missing too, which may be on purpose.
12. Wrong: Settings > Archive keeps General highlighted in the nav. `Features/Settings/SettingsShellViews.swift`.
13. Wrong: the New task dialog's description lacks "once at a set date", `ScheduledTasksSettings.tsx:1698`. Ours: `Features/ScheduledTasks/ScheduledTasksSettingsView.swift`.
14. Wrong: the thread details card's environment row puts the folder icon next to the monitor icon on the left. T3 puts it at the row's right end, reference `60-thread-details-notes`.
15. Nit: the file chip in a sent bubble uses a blue file icon where T3's is gray, reference `56-model-switch-media`.

Checked and not a bug: client settings reset on relaunch only because `--fake-t3-connect` makes `ClientSettingsStore` in-memory (`Features/Settings/ClientSettingsStore.swift:11`). Sends while a run is going steer because the sandbox's Follow-up behavior is set to Steer. After the first Stop, the server kept a background wake turn running (`orchestration-v2.claude-wake-turn-detected` in its log), as T3's own capture of 57 notes; a second Stop ended it.

## Thread

| Item | State | Verdict | Image |
|---|---|---|---|
| Two quick sends | default dark | works: the second became a labeled Steer under the first, as T3's 57 shows | `$O/two-quick-sends-default-dark.png` |
| Model switch divider | default dark | works, matches 56 | `$O/model-switch-divider-default-dark-ours-vs-t3.png` |
| Image above bubble, file card | default dark | works, file icon color is a nit | `$O/media-and-file-card-default-dark-ours-vs-t3.png` |
| File chip hover and slow exit | default dark | works, underline clears | `$O/file-chip-hover-then-slow-exit-default-dark.png` |
| Inline approvals, sidebar Approval badge | default dark | works, matches 05 | `$O/approval-inline-two-pending-default-dark.png` |
| Path tooltip after Approve | default dark | wrong, item 5 | `$O/WRONG-stale-path-tooltip-after-approve-default-dark.png` |
| Viewed-images row | default dark | works | `$O/viewed-images-row-default-dark.png` |
| Image viewer and stepping | default dark | works, 1/2 to 2/2 with arrow keys | `$O/image-viewer-stepping-default-dark.png` |
| Stop, interrupted run, Stop again, Resume | default dark | works; "Stopping…" never showed in my 150 ms frame | `$O/stop-steer-interrupted-sequence-default-dark.png`, `$O/stopped-resume-button-default-dark.png` |
| Enter on an empty prompt resumes | default dark | works | `$O/stop-twice-then-resume-default-dark.png` |
| Insight callout | default dark | works | `$O/quote-card-sent-default-dark.png` |
| Cite chip and comment popover | default dark | works; the popover hangs over the sidebar, as T3's top/end anchor does (`AssistantCitationChip.tsx:300-305`) | `$O/cite-chip-on-selection-default-dark.png`, `$O/cite-comment-popover-default-dark.png` |
| Quote card in a sent message | default dark, light | works | `$O/quote-card-sent-default-dark.png`, `$O/quote-card-sent-default-light.png` |
| Quote card hover | default dark | wrong, item 4 | `$O/WRONG-quote-card-raw-url-tooltip-default-dark.png` |
| Reply button and banner | default dark | broken, item 2 | `$O/BROKEN-reply-button-no-banner-default-dark.png` |
| Question card | default dark | wrong, item 7; answering works | `$O/WRONG-question-card-stop-before-submit-default-dark-ours-vs-t3.png`, `$O/question-answered-default-dark.png` |
| Tool calls hidden | default dark | works, work rows hide, questions stay | `$O/tool-calls-hidden-thread-default-dark.png` |
| Message rail hover, slow exit, scroll under a still pointer | default dark, light | works | `$O/message-rail-hover-exit-scroll-default-dark.png`, `$O/message-rail-hover-slow-exit-default-light.png` |
| Message rail after an app switch | default dark, Redesign dark | broken, item 1 | `$O/BROKEN-message-rail-stuck-after-app-switch-default-dark.png`, `$O/BROKEN-message-rail-stuck-after-app-switch-redesign-dark.png` |
| One tiny turn | default light | works | `$O/send-tiny-turn-default-light.png` |
| Thread at rest | Redesign dark | works | `$O/thread-redesign-dark.png` |

Thread: 16 works, 3 wrong, 2 broken.

## Composer

| Item | State | Verdict | Image |
|---|---|---|---|
| Docked picker open | default dark, light | works, matches 13; our ⌘1 to ⌘4 jump labels come from keybindings (`ModelPickerContent.tsx:863`) | `$O/docked-picker-open-default-dark.png`, `$O/docked-picker-default-light-ours-vs-t3.png` |
| Picker keyboard: Down, Right picks the model and moves to its levels | default dark | works, as `ModelPickerContent.tsx:1075-1093` | `$O/docked-picker-keyboard-down2-default-dark.png`, `$O/docked-picker-keyboard-right-default-dark.png` |
| Effort row click after a model click | default dark | wrong, item 8 | `$O/WRONG-docked-picker-effort-first-click-ignored-default-dark.png` |
| Picker rows and Legacy models | Redesign dark | wrong, item 9 | `$O/WRONG-docked-picker-no-row-hover-redesign-dark.png`, `$O/docked-picker-redesign-dark.png` |
| Image and file attach by paste | default dark | wrong when pasted together, item 10 | `$O/composer-image-and-file-attached-default-dark.png` |
| Live blockquote and inline code | default dark | works | `$O/composer-live-quote-and-code-default-dark.png` |
| List editing with Tab and Shift+Tab | default dark | works | `$O/composer-list-tab-shift-tab-default-dark.png` |
| @-mention a model | default dark | works, menu and chip | `$O/model-mention-menu-default-dark.png`, `$O/model-mention-chip-default-dark.png` |
| `/clear` and its banner | default dark | works in the thread; leaks after archive, item 3 | `$O/slash-clear-and-fresh-session-banner-default-dark.png`, `$O/BROKEN-fresh-session-banner-leaks-to-new-thread-default-dark.png` |

Composer: 6 works, 3 wrong, 1 broken.

## Sidebar

| Item | State | Verdict | Image |
|---|---|---|---|
| Row hover and slow exit | default dark, Redesign dark | works | `$O/sidebar-row-hover-default-dark.png`, `$O/sidebar-row-hover-exit-redesign-dark.png` |
| Snooze menu, Custom dialog, calendar | default dark | works | `$O/snooze-menu-default-dark.png`, `$O/snooze-custom-dialog-default-dark.png`, `$O/snooze-calendar-default-dark.png` |
| Row context menu | default dark | wrong, item 6 | `$O/WRONG-sidebar-context-menu-with-hover-card-default-dark-ours-vs-t3.png` |
| Undo notice after Archive at 260 pt | default dark | works, an icon as in 61; it left within about 3 s, so I could not test its hover | none kept |
| Fast toggle | default dark, light | works, settles in the last state | `$O/sidebar-fast-toggle-settles-default-dark.png`, `$O/sidebar-fast-toggle-settles-default-light.png` |

Sidebar: 4 works, 1 wrong.

## Settings

| Item | State | Verdict | Image |
|---|---|---|---|
| Modal and nav | default dark, light, Redesign dark | wrong label, item 11 | `$O/WRONG-settings-general-nav-default-dark-ours-vs-t3.png`, `$O/palette-and-settings-default-light.png`, `$O/settings-general-redesign-dark.png` |
| Thread details items row | default dark | works, all 12 items as 59 | `$O/settings-thread-details-items-menu-default-dark.png` |
| Scheduled task, Once, calendar | default dark | wrong text, item 13; the calendar works | `$O/WRONG-scheduled-task-once-calendar-default-dark-ours-vs-t3.png` |
| Keybindings Unassigned and Reset | default dark | works; I reset the sandbox shortcut afterwards | `$O/keybindings-unassigned-default-dark.png` |
| Connections > Environments | default dark | works, plus the desktop-only Local environment row | `$O/settings-environments-default-dark-ours-vs-t3web.png` |
| Archive page | default dark | wrong nav, item 12 | `$O/WRONG-settings-archive-nav-shows-general-default-dark.png` |

Settings: 3 works, 3 wrong.

## Thread details card, Issues, palette

| Item | State | Verdict | Image |
|---|---|---|---|
| Card with usage and context sections | default dark | wrong icon placement, item 14; sections show | `$O/thread-details-card-usage-context-default-dark.png`, `$O/WRONG-thread-details-card-env-row-default-dark-ours-vs-t3.png` |
| Card right-click menu | default dark | works | `$O/thread-details-card-context-menu-default-dark.png` |
| Card row hover and exit | default dark | works | `$O/thread-details-card-hover-exit-default-dark.png` |
| Issues, "No trackers to read" | default dark | works, matches 58 | `$O/issues-empty-default-dark-ours-vs-t3.png` |
| Issues Sort, Filters, Views menus | default dark | works | `$O/issues-menus-sort-filters-views-default-dark.png` |
| Command palette | default dark, light, Redesign dark | works; "New thread" shows ⇧⌘O, a T3 default for `chat.new` | `$O/command-palette-default-dark-ours-vs-t3.png`, `$O/command-palette-redesign-dark.png` |

Card, Issues and palette: 5 works, 1 wrong.

## Not reached

- The issue badge, since no sandbox thread links an issue.
- The title glimmer, folder drop, the rename field and the project filter notice.
- The prompt suggestion, send while uploading and expired upload recovery.
- The undo notice's hover, since it left within about 3 s.
- Dialogs other than snooze and New task, like the commit dialog.
- "Stopping…", which my 150 ms frame missed, and Resume's 500 ms click guard.
- The reconnecting banner, a T3 Connect session past the hour and a send failing after 60 s, which need a network change or an hour.
- Most items in light and Redesign beyond the ones in the tables; the 12-turn budget ran out first.

## Build fix

`1bc5ebfa fix(app): load Issues pages with one main-actor task per host` makes `scripts/build-test-app` pass with Xcode 27.2. `IssuesPageController.reload` used a task group whose `@MainActor [weak self]` children tripped the region-based isolation checker at `IssuesPage.swift:262`. Each host now loads in its own main-actor `Task`, and a `pendingLoads` count clears `loading` when the current generation's last host answers. No other build error showed.

## Checklist

Collected from the "could not check on screen" lines of every PROGRESS.md entry dated 2026-11-19, plus the items the task brief names.

Thread, from thread-messages, thread-markdown, look-4928 and composer-3:

- Message bursts from two quick sends, 4pt apart and joined.
- The model or effort switch divider above a message.
- Stop shows "Stopping…", Resume ignores clicks for 500 ms, hides while a request is pending, Enter on an empty prompt resumes.
- A steer keeps the final answer, and a queued message can steer.
- Media and file cards in sent messages, the quote card and its hover.
- The `★ Insight` callout.
- Inline-code file chips and their hover.
- The viewed-images row and the image viewer stepping.
- The reply button and the reply banner, reply cards and model chips in sent messages.
- The fresh-session banner slot.

Composer, from composer-pickers, composer-3 and composer-rest:

- The model and effort trigger, one control.
- The docked model picker, its side menus and keyboard flow.
- `/clear`.
- List editing with Tab and Shift+Tab.
- @-mention a model.
- The prompt suggestion.
- Send while an upload is running, and expired upload recovery.

Sidebar, from sidebar-4928 and look-4928:

- The undo notice in the footer's utility row at narrow widths, and its hover.
- The title glimmer.
- Folder drop, the rename field, the project filter notice.
- The snooze menu and dialog.
- The issue badge.

Settings, from settings-4928:

- The thread details items row.
- Scheduled tasks with a one-time schedule and its calendar.
- Connections.
- Keybindings Unassigned.
- Tool calls hidden.

Other surfaces:

- The thread details card with its usage and context sections and right-click menu.
- Dialogs.
- The Issues page, its empty "No trackers to read" state and its menus (issues).
- The message rail at rest and hovered, and its exits (rail-fix, rail-colors).
- The reconnecting banner after network changes and sleep, a T3 Connect session past the hour, a send that fails after 60 s (connection). These need a network change or an hour, so this pass does not reach them.

App checks from docs/nightly-catch-up.md step 9: send one tiny turn, toggle the sidebar fast, open Settings and the command palette, in both default themes.
