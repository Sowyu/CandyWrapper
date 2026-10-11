# Navigation and sidebar status, 2026-10-11

Task navstatus. T3 source is `/Users/mrm/CandyWrapper-research/t3code/apps/web/src` unless a path says otherwise. Checked on screen against the sandbox server with a build of this worktree (bundle id `dev.candywrapper.test.navstatus`) and, for comparison, a build of the `v0.1.0` tag.

## Fixed

| What differed | T3 | Fix |
|---|---|---|
| A sidebar row clicked while Usage or Pull Requests showed only moved the highlight; the page stayed. Same for draft rows, search results and file drops | `navigateToThread` is a route change (Sidebar.tsx:3144-3160); `/usage` and `/pull-requests` are routes like any other (routes/usage.tsx, routes/_chat.pull-requests.tsx) | `SidebarCommands` wraps `openThread`, `openDraft` and `dropFiles`: the page closes, the thread opens, history gets one entry |
| The thread behind Usage or Pull Requests kept its active row, and settling, snoozing, archiving or deleting it navigated away from the page | No route thread on those pages (`routeThreadKey`, Sidebar.tsx:2490-2494), so `planForwardNavigation` (Sidebar.tsx:3318-3346) and the delete and archive fallbacks do nothing | `routeThreadId` is nil on a utility page; the active row and draft clear while the page shows and come back on Back |
| Escape on Usage always went to the thread view; Escape on Pull Requests did nothing | `useEscapeToGoBack` (hooks/useNavigateBack.ts) goes back in history, else home; UsagePage.tsx:115, _chat.pull-requests.tsx:349 | Both pages call `RouteHistory.back()`, else close |
| `usage.open` from Settings stacked Usage on Settings; `usage.open` left the palette open | `/usage` replaces `/settings`; CommandPalette.tsx:567-572 closes the palette | `openUtilityPage` closes Settings first (no extra history entry); the shortcut closes the palette |
| `chat.new`, `chat.newLocal`, `chat.newWithoutProject` and `thread.undo` worked on Settings and Usage | They live in `ChatRouteGlobalShortcuts` (_chat.tsx:36-140), which Settings and Usage are outside; Pull Requests is inside | Guarded with `onChatRoute` / `isUsagePageOpen` |
| Returning to the thread view from Settings or a utility page left focus nowhere | ChatView mounts again and focuses the composer unless the terminal is open (ChatView.tsx:6837-6845) | `ThreadController.focusComposerOnReturn` from `closeUtilityPage` and `SettingsController.close` |
| The client never marked a thread visited, so Done came back on threads already read, and a never-visited thread never showed Done | ChatView's visit effect (ChatView.tsx:2938-3000): `thread.visit` with the thread's `updatedAt`, at once for an unseen completion, else a 10 s trailing throttle (`VISIT_DISPATCH_THROTTLE_MS`, :622), deduped per watermark; a local watermark on servers without visit tracking | `T3Store/ThreadVisits.swift` (`ThreadVisitTracker`, `ThreadCommands.visit`), driven by `ThreadController.syncVisit` on every shell and route change. Test `ThreadVisitsTests` |
| Done and Woke were hidden on the open thread by a client-side `!isActive` gate | `isUnread` and `isWoke` are not gated on the active row (Sidebar.tsx:1262-1279): the visit clears Done, a timer wake and a mark-unread on the open thread stay | Gate removed in `SidebarListBuilder.rowModel` now that visits are recorded |
| A click on the sidebar's padding or the 1 pt gap between rows made the list first responder, which put the open thread's row in keyboard focus: ring on, status (Working, Done, the time) swapped for Settle and Snooze until focus left | The list is a plain div: a click there focuses nothing, and the status hides only on `focus-visible` (Sidebar.tsx:2019-2027) | `SidebarListView.becomeFirstResponder` refuses a mouse click; Tab still enters the rows |

## The "working indicator disappears after viewing it" report

Not reproduced as a model bug. On the sandbox, with the current build and with the `v0.1.0` build, a running thread kept Working while open, after switching away and back, while another client ran it, and while this app ran it. The row status is a pure function of the shell (`resolveSidebarThreadStatus`, Sidebar.logic.ts:983-1003, same as `SidebarModel.resolveSidebarThreadStatus`), and nothing in the app overlays the shell from the open thread.

What does hide it on the open thread, seen on screen:

1. A click on the list padding or a row gap focused the active row and hid its status (fixed above, present in v0.1.0 and v0.1.1).
2. A row whose hover state stuck after the click showed Settle in place of Working. v0.1.0 had no `HoverSync`; v0.1.1 has it (controlfeel package).

If the user still sees it on v0.1.1 plus this change, ask which of the two it looks like: a blue ring around the row means focus, Settle without a ring means hover.

## Checked, same as T3

- Status derivation: working (Goal with an active goal), waiting (no icon), approval, input, limited, failed, then woke, then done (`resolveSidebarV2TopStatus`, Sidebar.logic.ts:1015-1039), colors and icons (Sidebar.tsx:1290-1347).
- Recede: `shouldRecedeSidebarThread` (Sidebar.logic.ts:963-978); only a receding working row fades to 0.7 (Sidebar.tsx:1594-1598).
- Settled shelf, Snoozed shelf and Working shelf keep the route thread visible when collapsed (Sidebar.tsx:2965-3055).
- Settings Escape and Back go to the last main route (`navigateToMainApp`, sidebar/mainAppLocation.ts).
- Palette picks, notifications and history already closed Settings and utility pages before opening a thread.

## Left

- Fixed 2026-10-11 (details2): Tab into the thread list lands on the first row (Shift-Tab on the last), not the active one; Escape with a multi-selection on Usage or Settings goes back and keeps the selection; `SidebarContentView` keeps every row and draft inactive while a utility page shows, whoever sets them. Tests `tabIntoTheListStartsAtTheFirstRow`, `utilityPageKeepsRowsInactive`.
- Mark unread on a server without visit tracking does not rewind the local watermark (existing ponytail in `SidebarCommands.perform`).
