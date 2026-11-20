# Screen pass 2, 2026-11-20

The second on-screen pass of the Nightly 4928 port, on branch `screen-pass-2` from `catchup-4928` (77ac7147). It covers what the [first pass](screen-pass-2026-11-20.md) could not reach and what merged after it. This file has its own name because the first pass already owns `screen-pass-2026-11-20.md`.

Images live in `~/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/`, called `$O` below. File names start with `BROKEN-` or `WRONG-` where the verdict is one. A name ending in `-ours-vs-t3` puts our crop on the left and T3's capture from `design/reference-4928` on the right. Those references come from T3's web client, so the desktop title-bar strip is missing from them.

The app ran in a 1100 by 780 pt window on a 1x screen. The 4928 sandbox is on port 47392 and the 3824 sandbox on 47391, both with `--fake-t3-connect`. The reconnect test used a private 4928 server on port 47430 with its own `SANDBOX_DIR`. I used 9 real Haiku 5.5 turns. Turn 9 asked for two subagents, and the sandbox's Haiku used `delegate_task`, which started two Sonnet 5.5 children and a few parent continuations.

## Ten images that show the state of the app

1. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/BROKEN-welcome-turn-on-agent-does-nothing-default-dark.png`
2. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/side-chat-pane-default-dark-ours-vs-t3.png`
3. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/welcome-default-dark-ours-vs-t3.png`
4. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/waiting-on-2-subagents-default-dark.png`
5. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/connection-reconnecting-banner-default-dark.png`
6. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/WRONG-issues-filter-values-letter-spaced-default-dark.png`
7. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/WRONG-scheduled-task-once-model-and-branch-rows-default-dark-ours-vs-t3.png`
8. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/welcome-redesign-light.png`
9. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/4928-settings-diagnostics-dark.png`
10. `/Users/administrator/CandyWrapper-research/sandbox/screen-pass-2-2026-11-20/3824-plus-menu-no-side-chat-light.png`

## The build

`scripts/build-test-app` failed on `catchup-4928`. `scripts/check-app-build` now prints every app-target error in one run.

1. `FilesController.swift:222`, switch must be exhaustive. The new `.sideChat` surface kind joins the no-op case, because the side chat pane builds itself through `onSideChatShown` in `SideChatController` (c640eabb).
2. `ThreadSession.swift:1799` and `:1802`, `composer` and `environments` not in scope, and `:657`, `ThreadController` has no `linkMetadataThread`. f822e3ac put the link metadata lookup and its cache on `ThreadSession`. They now live on `ThreadController`, which calls them and owns the composer, environments and panel.

## Ranked wrong and broken items

| # | Item | Verdict | Our file | T3 |
|---|---|---|---|---|
| 1 | Welcome, Turn on in Add more agents changes nothing, shows no toast, and the provider never shows in Settings > Providers | broken | `Features/Settings/WelcomePageView.swift:238` | `components/onboarding/WelcomePage.tsx:546-569` |
| 2 | Side chat pane opens on "Send a message to start the conversation." without T3's "Context from · parent" divider | wrong | `Features/SideChats/SideChatPaneView.swift`, `Features/Thread/TimelineParentLinkView.swift` | `components/chat/MessagesTimeline.tsx:1206-1230` |
| 3 | Stop on a "Waiting on … in background" row shows no Stopping state; the row stays until the task ends, though the task was killed | wrong | `Features/Thread/ThreadRecoveryPresentation.swift`, `ThreadPanelView.swift` | `components/chat/ThreadActivityBanners.tsx:198-250` |
| 4 | Escape does not close Settings after a click on a theme card, in default and Redesign, so the next click lands on Settings | wrong | `Features/Settings` appearance page, `App/Sources/SettingsController.swift` | base-ui Dialog closes on Escape from any focus |
| 5 | Welcome opened before the socket connects shows "Could not check projects. Disconnected: not connected" until Retry | wrong | `App/Sources/WelcomeOnboardingController.swift:121` | `WelcomePage.tsx:153` (`useProjectScans` waits for the connection) |
| 6 | Issues and Pull Requests filter rows letter-space their values, Open and Everyone, like key chords | wrong | `Features/Issues/IssuesPageView.swift:264`, `Features/PullRequests/PullRequestsPageView.swift:353` use `shortcut`; `trailingDetail` exists | `components/issue/IssueListFilterPickers.tsx:139`, `:159` |
| 7 | One-time scheduled task: Model is plain "GPT-6-Astra" text where T3 has a bordered "6 Astra" picker; Base branch is a centered "main" button where T3 has "From main (remote)" | wrong | `Features/ScheduledTasks/ScheduledTasksSettingsView.swift` | `components/settings/ScheduledTasksSettings.tsx:1878`, `:1927` |
| 8 | "No trackers to read": icon larger and the gap to the title smaller than T3's | wrong | `Features/Issues/IssuesPageView.swift` | `components/issue/IssuesPage.tsx:489-500` |
| 9 | Welcome page content scrolls up under the traffic lights; T3 desktop keeps a title-bar strip above it | wrong | `Features/Settings/WelcomePageView.swift` | `WelcomePage.tsx:278-279` |
| 10 | Settings > Voice is a placeholder, "Voice dictation isn't available in CandyWrapper yet." T3 4928 desktop shows a mic in the composer (reference 62) | wrong | Voice settings page in `Features/Settings` | `docs/parity-checklist.md:183` still says iPhone only |
| 11 | Issues: the Filters button keeps a focus ring after a click on Views | wrong | `Features/Issues/IssuesPageView.swift` | focus moves to the clicked trigger in Chromium |
| 12 | Language lists only System default and English | wrong | `Features/Settings/GeneralSettingsView.swift:288` | `i18n/locales.ts:4`, ten locales |

## Smoke tests

| Server | State | Verdict | Image |
|---|---|---|---|
| 4928 | Thread, one turn, five fast sidebar toggles, Settings, palette, default dark and light | works | `$O/4928-palette-dark.png`, `$O/4928-thread-light.png` |
| 3824 | Fresh profile showed the Welcome page, Start, a No project thread, one turn, Settings, palette, default light and dark | works | `$O/3824-welcome-light.png`, `$O/3824-thread-dark.png` |
| 3824 | No Side chat in the + menu, no `/side` or `/btw`, no Issues icon in the footer | works | `$O/3824-plus-menu-no-side-chat-light.png` |

The 3824 server showing the Welcome page is right: 4928 replaced the old wizard on the client, so T3's 4928 web client shows it there too. "Triage an issue" in the palette existed at 3824 (`server.prepareTriage` is unchanged).

## Side chats

Counts: 11 works, 1 wrong.

| Item | State | Verdict | Image |
|---|---|---|---|
| + menu entry | Right panel + menu, 4928 | works | `$O/4928-plus-menu-side-chat-dark.png` |
| `/side` and `/btw` | Parent composer | works, opens a second tab and runs | |
| Tab and state dot | Running, then settled | works | `$O/4928-side-chat-tab-running-dark.png`, `$O/4928-side-chat-tab-settled-dark.png` |
| Pane header | Title, Bring back, Delete, Close | works | `$O/4928-side-chat-pane-dark.png` |
| Empty pane | Before the first message | wrong, item 2 | `$O/side-chat-pane-default-dark-ours-vs-t3.png` |
| Bring back | Hover with slow exit, then click | works, "Brought back" toast, no turn | `$O/4928-side-chat-bring-back-hover-dark.png`, `$O/4928-side-chat-brought-back-toast-dark.png` |
| Delete | Confirm dialog, T3's text (SideChatPane.tsx:103-104) | works | `$O/4928-side-chat-delete-confirm-dark.png` |
| Close | Pane header X | works, closes the tab and the panel | |
| Closing an unused one | S in the + menu, then the tab's X | works, Bring back disabled, thread gone from the details card | |
| Switching tabs | Two side chats | works | |
| Details card section | Side chats list | works | `$O/4928-details-side-chats-section-dark.png` |
| Redesign | Pane in Redesign light | works | `$O/side-chat-pane-redesign-light.png` |

## Issues and saved views

Counts: 3 works, 3 wrong, 1 not reached.

| Item | State | Verdict | Image |
|---|---|---|---|
| Page, empty | No tracker in the sandbox | wrong, item 8 | `$O/WRONG-issues-empty-state-spacing-default-dark-ours-vs-t3.png`, `$O/issues-page-default-dark-ours-vs-t3.png` |
| Filters with search rows | Labels submenu with "Search labels" | works | |
| Filter values | Open, Everyone, Any, Anyone | wrong, item 6 | `$O/WRONG-issues-filter-values-letter-spaced-default-dark.png` |
| Focus after a click | Views clicked after Filters | wrong, item 11 | `$O/WRONG-issues-filters-focus-ring-after-views-click-default-dark.png` |
| Saved views on Issues | Save, the view in the menu, Rename, Delete | works | `$O/4928-issues-saved-view-menu-dark.png` |
| Saved views on Pull Requests | Views menu | works | `$O/4928-pull-requests-empty-dark.png` |
| Linked items with issues | Needs a tracker | not reached | |

## Welcome page

Counts: 11 works, 2 wrong, 1 broken. I launched with `--welcome` on 4928 and with a fresh profile on 3824. The agent install stopped before any terminal opened, since Turn on did nothing.

| Item | State | Verdict | Image |
|---|---|---|---|
| Default dark | Beside T3's web capture | works; T3 has no Phone row because its capture had no cloud config | `$O/welcome-default-dark-ours-vs-t3.png`, `$O/welcome-default-dark.png` |
| Default light | | works | `$O/welcome-default-light.png` |
| Redesign | Light | works | `$O/welcome-redesign-light.png` |
| Title-bar inset | At rest | works, matches the desktop strip | |
| Title-bar inset | Scrolled | wrong, item 9 | `$O/WRONG-welcome-scrolls-under-title-bar-redesign-light.png` |
| Agent rows | Claude and Codex ready | works | |
| Add more agents | Expanded grid, hover on Turn on with a slow exit | works | `$O/welcome-add-more-agents-default-dark.png` |
| Turn on | Antigravity, clicked twice | broken, item 1 | `$O/BROKEN-welcome-turn-on-agent-does-nothing-default-dark.png` |
| Import list | Review all, Select none | works | not saved: it lists the user's real Claude Code history |
| Projects before the socket | `--welcome` at launch | wrong, item 5 | `$O/WRONG-welcome-projects-not-connected-before-socket-default-dark.png` |
| Phone panel | Set up | works | `$O/welcome-phone-panel-default-dark.png` |
| Settings over the page | Cmd+, then close | works, the page comes back | `$O/welcome-settings-over-page-default-dark.png` |
| Start | Import unchecked | works, lands in the app | |
| 3824 first run | Fresh profile | works | `$O/3824-welcome-light.png` |

## Settings

Counts: 4 works, 4 wrong, 2 not reached.

| Item | State | Verdict | Image |
|---|---|---|---|
| Storage Reclaim and its dialog | Needs freed database space (DatabaseStorageNotice.tsx:67-79) | not reached, no recommendation on the sandbox | |
| Fallback model | None, with the default's provider icon as T3 (ProjectDefaultsSettings.tsx:100, :301) | works | `$O/4928-settings-fallback-model-row-dark.png` |
| Labs switches | Suggest next prompt, Boring sidebar on and off | works | `$O/4928-settings-labs-dark.png` |
| Voice | | wrong, item 10 | `$O/WRONG-settings-voice-placeholder-default-dark.png` |
| Language | | wrong, item 12 | `$O/WRONG-settings-language-english-only-default-dark.png` |
| Diagnostics in dark | Beside reference 39 | works | `$O/4928-settings-diagnostics-dark.png` |
| One-time task calendar | Once, date popover | works for the calendar, wrong for the rows, item 7 | `$O/4928-scheduled-task-once-calendar-dark.png`, `$O/WRONG-scheduled-task-once-model-and-branch-rows-default-dark-ours-vs-t3.png` |
| Connections device approvals | T3 Connect off on the sandbox | not reached, I did not turn on T3 Connect | `$O/4928-settings-sharing-access-dark.png` |
| Escape after a theme click | Appearance | wrong, item 4 | |

## Sidebar

Counts: 9 works, 6 not reached.

| Item | State | Verdict | Image |
|---|---|---|---|
| Pin from the filter popup | Hover shows gear and pin; pinned keeps the pin (ProjectPinButton.tsx:43) | works | `$O/4928-sidebar-filter-popup-pin-hover-dark.png` |
| Pin from the right-click menu | Boring sidebar folder menu, T3's order (Sidebar.tsx:1263-1285) | works | `$O/4928-sidebar-project-folder-menu-pin-dark.png` |
| Pin from the palette | Pin and Unpin project | works | `$O/4928-palette-unpin-project-dark.png` |
| Pinned-first order | One project per sandbox | not reached | |
| Turn into project | No No project thread on 4928 | not reached | |
| Title glimmer | New thread's first turn | not reached, my frames missed the row | |
| Folder drop | Needs a Finder drag | not reached | |
| Rename field | Ring and fill as SidebarThreadRow.tsx:673 | works | `$O/4928-sidebar-rename-field-dark.png` |
| Project filter notice | Filter set to demo-repo | not reached, no trigger found | |
| Undo notice and its hover | Archive, pointer on the undo icon; it expires at 5 s as T3 (SidebarThreadUndoNotice.tsx:36-75) | works | `$O/4928-sidebar-undo-after-archive-dark.png`, `$O/4928-sidebar-undo-hover-dark.png` |
| Open row at launch | Relaunch on the last thread | works, though the list fit without scrolling | |
| Click after a row slides under the pointer | | not reached | |
| Hover through an app switch | Finder and back, still pointer | works | |
| Scroll under a still pointer | Sidebar | works, hover follows the row | |
| Archive takes side chats along | Parent archived, then unarchived | works, all three came back together | |

## Thread and composer

Counts: 3 works, 1 wrong, 6 not reached.

| Item | State | Verdict | Image |
|---|---|---|---|
| Reply card and model chip in a sent message | Synthetic drags do not select reply text | not reached | |
| Sending state | Short prompt, no slow upload | works for a plain send | `$O/4928-sending-state-dark.png` |
| Stopping and Force stop | Stop on a background command | wrong, item 3; Force stop not produced | |
| Resume's click guard | No interrupted thread | not reached | |
| Prompt suggestion | Labs on, two Claude turns | not reached, the server sent none | |
| Fallback banner | Needs a provider out of usage | not reached | |
| Zen mode | Tool calls in chat set to Zen | works | `$O/zen-mode-thread-default-dark.png` |
| Waiting on N subagents | Two subagents | works | `$O/waiting-on-2-subagents-default-dark.png` |

## Pull requests and panels

Counts: 2 works, 2 not reached.

| Item | State | Verdict | Image |
|---|---|---|---|
| Linked-thread count | No pull requests on the sandbox | not reached | |
| Maintainer-edits row | No pull requests | not reached | |
| Add project's Tab completion | Local folder, Tab completes the highlighted row as CommandPalette.tsx:2774-2780 | works | not saved: it lists the home folder |
| Usage page | Limits | works; T3's capture had no providers | `$O/4928-usage-page-dark.png`, `$O/usage-limits-default-dark-ours-vs-t3.png` |

## Connection

Counts: 4 works. A private 4928 server on port 47430, killed with the app on a thread, then started again with `scripts/sandbox-server` through `env -i`.

| Item | Timing | Verdict | Image |
|---|---|---|---|
| Reconnecting banner after the server stops | Shown between 1.9 and 2.4 s | works | `$O/connection-reconnecting-banner-default-dark.png` |
| Retry now | Hover fill and a clean exit; with the server down the banner stays | works | |
| Recovery | Server listening at 20:52:52.2, banner gone at about 20:53:06, so about 14 s after about 80 s down | works; T3 backs off from 1 s, doubling (client-runtime connection/supervisor.ts:46-47) | |
| Thread after recovery | Same thread, content intact | works | |
