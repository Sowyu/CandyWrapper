# Thread-switch flicker, 2026-10-11

The user saw the whole app flicker when clicking another thread in the sidebar. The cause was a blank main panel for one to five frames on every switch, and this note covers how I measured it, where it came from and what changed.

## How it was measured

`scripts/ui/record-switch.swift` (build with `swiftc -O -o /tmp/cw-ui/record-switch scripts/ui/record-switch.swift`) streams one app window through ScreenCaptureKit at up to 60 frames a second, posts the sidebar clicks itself, and writes every frame as a PNG at 1 pixel per point with a report line per frame: time, changed share against the previous frame and the changed box. A flicker frame is one that matches neither the state before the click nor the state it settles on.

Setup: Debug build with its own bundle id, sandbox server on port 47391, window 1100x780 points, dark appearance. Threads used are all in the sandbox: Fork OK, MCP hub, fontblur-measure (empty, right panel open), Peak probe 115947 (right panel open on Files), heavy mermaid, Reply with Delta and Reply with Gamma (demo-repo), Reply with the word beta (wp711-clone) and Acknowledge with OK (git-demo). Cold opens came from the disk cache or the server, warm opens from the 5-minute retained stores.

## Before

Every switch went click, then sidebar selection plus an empty main panel, then the new thread. In the empty frame the header lost its title and its buttons, the timeline was empty and the composer was hidden; only the sidebar and the window background stayed.

| Switch | Empty panel on screen |
|---|---|
| Fork OK, cold | 0.803 to 0.873 s, 70 ms |
| MCP hub, cold | 2.383 to 2.453 s, 70 ms |
| heavy mermaid, cold | 3.987 to 4.081 s, 94 ms |
| Fork OK, retained | 5.601 to 5.636 s, 35 ms |
| MCP hub, retained | 7.182 to 7.200 s, 18 ms (one frame) |

The same happened with the right panel open and closed, within a project and across projects. The sidebar itself did not flicker: its frames show the hover and then the selection, which land in the same commit as the empty panel.

## Cause per area

- The header, timeline and composer were all cleared by `ThreadController.open`, which called `panel.setDraft(nil)` and `panel.setProjection(nil, ...)` in the click's pass. With no projection, `setProjection` hides the header's thread parts, `model.setProjection(nil)` empties the rows and `updateComposerShown` hides the composer. Core Animation committed that state at the end of the pass.
- The new rows came one or more run loop passes later. Every first render goes through the `ThreadStore` actor: `showRetained` for a retained store, `restoreFromCache` for the disk cache and the subscription for the server. A hop to the actor and back always lands after the click's commit, so even a retained thread showed one empty frame, and a cold open showed several.
- Threads of 1,500 rows or more build their rows off the main thread (`TimelinePipeline`), which added the background pass to the empty time.
- When the user had scrolled up in the old thread, the empty pass left `followsEnd` false, so the next thread could open above its end. This is likely the "thread sometimes opens scrolled above its end" seen in M5.
- The right panel did not flicker. Its per-thread state switches in the click's pass (`FilesController.show`). One frame of "Loading files..." shows when the Files surface opens on a thread after a thread without the panel, because a closed panel releases the tree (WP8.2). T3 does the same: `useDirectoryEntries` keeps the tree in component state and reloads on mount (components/files/useDirectoryEntries.ts:11-16).
- Theme, fonts, `FramePacer`, `LazyView` releases and git refreshes caused no frames of their own in these recordings.

## What T3 does

One `ChatView` stays mounted across thread routes (ThreadRouteView.tsx:27-35, routes/_chat.tsx:217-229). The header and composer switch at once from the thread's shell. The timeline keeps the last thread's rows while the new thread is loading with no rows of its own, but only within one environment (`resolveThreadSwitchTimeline` and `threadKeysShareEnvironment`, ChatView.logic.ts:392-438, used at ChatView.tsx:3964-3974). A remembered timeline for the new thread paints at once. While loading, the empty placeholder is hidden (ChatView.tsx:11474) and send says "Messages loading" (ChatView.tsx:11628).

## Fix

- `ThreadPanelView.beginThreadSwitch(projectTitle:threadTitle:keepRows:)` replaces the clear. The header takes the new title and project from the sidebar shell, the composer stays shown, and with `keepRows` the timeline keeps the old rows. The next `setProjection` swaps the timeline in one pass. Across environments, on a forced reload or from the draft page, the timeline empties to T3's loading state with the header and composer in place. A thread with no shell yet still clears, because T3 renders nothing then (ThreadRouteView.tsx:181).
- `ThreadSession` remembers the last update it rendered, and `Retained.shown` carries it. `paintRetained()` draws a retained thread inside the click's pass. The store's own state follows a moment later, as before.
- `ThreadViewModel` marks the first rows of a new thread as `TimelineChange.thread`, and `TimelineView` starts those rows at the end. The large-thread path keeps the old rows until the background rows are ready.
- Held rows keep their lineage header and footer until the first projection. Proactive panels stay idle while `switchingThread` is set, because `model.projection` still holds the old thread.

## After

| Switch | Frames between old and new |
|---|---|
| Retained (Fork OK, MCP hub, Reply with the word beta, Peak probe draft to thread) | none, one commit from the old thread to the new one |
| Cold, same environment (MCP hub, heavy mermaid, Delta, beta across projects, Acknowledge with OK) | one state for 17 to 80 ms: new header and composer over the old rows, as in T3, then the new rows |
| Cold into an empty thread with its right panel open (fontblur-measure) | one frame of the old rows in the narrower column, then the empty thread |

No recording after the fix has an empty panel frame. Test `ThreadTimelineTests.switchingThreadsNeverPaintsAnEmptyTimeline` fails without the `.thread` change and checks that no row update between two threads is empty.

## Left

- Held rows stay clickable. T3 renders them paint-only, with no working state and no find (ChatView.tsx:11327-11418). A click there acts on the newly opened thread, so gate row actions if that ever shows up (ponytail marker in `beginThreadSwitch`).
- T3 also remembers per-thread timelines beyond its retention window (`rememberThreadTimelineEntries`). We paint at once only for the two retained stores and the 5-minute window.
- Not recorded: a thread of 1,500 or more rows (the sandbox has none), and remote or relay environments, where cold opens take longer and the held state lasts longer.
