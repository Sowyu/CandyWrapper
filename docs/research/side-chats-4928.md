# Side chats at Nightly 4928, a plan

Side chats are threads forked from the open thread that run in a right panel tab beside it. T3 added them in #26901 (`50c1c5dc53`, 102 files, +4,710 lines) and fixed them in 18 later commits, listed under "New feature side-chats" in [the commits appendix](nightly-diff-4928-commits.md). The sidebar-2 task sized this as larger than the rest of its work combined, so this file is the plan instead of the port.

Already in CandyWrapper: the lineage's `sideChat` flag decodes (`ThreadLineage.sideChat`, orchestrationV2.ts:173), `lineage.isListed` keeps side chats out of the sidebar, search, settled counts and notifications (orchestrationV2.ts:177-179), and an open side chat now selects its parent's sidebar row (`SidebarModel.resolveListedAncestorThreadId`, sidebar-2). `thread.fork` is already built in `Features/Thread/ThreadLineageController.swift:494`.

## What T3 shows

`design/reference-4928/62-side-chat-panel.{light,dark}.png` is the panel before a question. The right panel opens with one tab, "Side chat" with a message-square icon, and a `+` after the tabs. Under the tab strip sits a 36pt header (`h-9 border-b pl-3 pr-1`): "Side chat" in `text-xs font-medium`, then Bring back, a trash button and a close button (SideChatPane.tsx:132-171). The body is a full `ChatView` of the side chat thread inside `BackgroundThreadContext`, with no thread header of its own: an empty timeline that starts with a "Context from · Run Shell Commands" divider, and its own composer at the bottom with the model trigger. A deleted side chat shows "This side chat was deleted." (:174-176).

## Wire

Nothing new to decode. Starting one dispatches `thread.fork` with `sourcePoint: { type: "latest_stable" }`, `sideChat: true`, `title: "Side chat"` and a client-made `targetThreadId` (client-runtime operations/commands.ts:1101-1115). Then the client waits for the new shell, sets its runtime mode to the parent composer's if they differ (#31114, #32315 also copy the reasoning level), and starts the turn with the message (`useSideChat.ts:20-96`). A failed start deletes the empty thread with `thread.delete` `onlyIfUnused: true`. Gate it on the server: 3824 rejects `sideChat` on `thread.fork`, so offer side chats only when `isListedThreadLineage` exists, that is, when shells carry `sideChat` or the descriptor's capabilities say so. Check `ServerEnvironment.ts` at the tag for the exact capability before shipping.

## Pieces, in order

1. Right panel tab model. `rightPanelStore.ts:159, 819-840` adds `openSideChat(parentRef, threadId)` and a `side-chat` surface per side chat thread. CandyWrapper's right panel is `Features/Thread/RightPanelView.swift` with its tabs owned by `App/Sources/ThreadSession.swift`. Add a `.sideChat(ThreadId)` surface beside browser, files and diff, persisted per parent thread like the others. `RightPanelTabs.tsx:410-420` adds "Side chat" to the `+` menu, disabled with "Side chats start after the first message." until the parent has one. The tab icon shows the side chat's state (`sideChatTabState`, :727-760: working, waiting, unread).
2. The pane. A `SideChatPaneView` in its own folder, `Features/SideChat/`, with the 36pt header and a second `ThreadPanelView` in an embedded mode: no thread header, no right panel, its own composer and pickers, tool diffs and shell commands routed to the parent's diff panel and terminal drawer (`lib/sideChatPane.ts` `SideChatParentPanel`). Each side chat needs its own `ThreadSession` subscription, created when the tab shows and torn down when it hides, so a hidden tab holds nothing.
3. Opening routes. `resolveThreadOpenRoute` (`lib/sideChatPane.ts:22-31`): opening a side chat from anywhere (palette, notifications, links, a subagent of a side chat per #32907) opens its parent with the tab selected. Hook it where `ThreadSession.open` resolves a thread id.
4. Composer entry points. `/side` and `/btw` are slash items at the message start (`useComposerMenuItems.ts:260-280`, `composerSlashCommandSearch.ts:15-30`); sending text that starts with either starts a side chat with the rest as its message, keeps attachments and context (#38350), beats an open question or plan follow-up (`useComposerSend.ts:439`), refuses in a queued edit (:790-797, #37228), and shows the send arrow while a turn runs (#36932). This lives in `Features/Composer` and `App/Sources/ComposerController.swift`, beside `ComposerMenus.clearCommand`.
5. Bring back and delete. Bring back inserts the side chat's last answer into the parent composer as a quote (SideChatPane.tsx:137-152); trash deletes the thread after the usual confirm; close hides the tab and keeps the thread.
6. Focus and shortcuts. A new side chat focuses its composer (#32929), selecting its tab focuses it (#31360), right panel shortcuts work from inside it (#32117), and Shift+F6 returns to the main chat (#31931). Keyboard routing goes through `Features/Keyboard`.
7. Lifecycle fixes. Deleting a thread clears its side chats' drafts (#29832) and offers to delete a worktree they share (#36800); deleting the open thread never lands on a side chat (#30370, done by `isListed`); project removal counts only listed threads (#29917, check `SettingsPages.swift`); Go to source on a side chat quote stays on the parent (#33160); side chats open after an abandoned worktree setup (#34686); row tooltips show the full title (#28326).

## Tests and references

- A spec case for the pane header and the tab with its state icon through a new `scripts/gen-side-chat-spec.py`, with component references made by `scripts/component-reference`.
- A full-screen case against `62-side-chat-panel` in `PanelScreensFidelityTests`, at the panel ceiling.
- Unit tests for the fork payload, the start sequence's failure cleanup, `/side` and `/btw` parsing, and the open route.
- Hover tests for the header buttons and the tab through `HoverSync`, since the tab strip rebuilds as side chats come and go.
- Redesign: the pane takes Redesign's panel surface and its own buttons; record a baseline only for the new panel.

## Estimate

About 4 to 6 hours of agent work: 1 hour for the tab model and routing, 2 for the embedded thread panel and its subscription lifecycle, 1 for the composer entry points, 1 for the fixes and tests. Plus the user's time to try it on screen, and 3 to 4 short Haiku turns on the 4928 sandbox to check a real start, Bring back and delete.
