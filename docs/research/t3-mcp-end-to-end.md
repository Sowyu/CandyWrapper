# T3 MCP end to end (WP7.15, 2026-10-11)

Agents that a T3 server runs get that server's `t3-code` MCP tools. This file lists every tool, what a T3 client shows when an agent calls it, what CandyWrapper showed before WP7.15 and what it shows now. Tag `v0.0.46-nightly.20261009.2861`. Paths are short: `web/` is `apps/web/src/`, `server/` is `apps/server/src/`, `cr/` is `packages/client-runtime/src/`, `shared/` is `packages/shared/src/`.

## How it was tested

1. Real `claude-haiku-5-5` turns on the sandbox server (port 47391), typed into a CandyWrapper build (`dev.candywrapper.test.mcp`) in a demo-repo thread that the agent renamed "MCP hub". 25 turns, mostly one line each, grouped several tools per turn.
2. The agent's tools acted on the sandbox only. Projects, worktrees and files stayed in `CandyWrapper-research/sandbox/` (`mcp-proj`, `mcp-clone`, `mcp-note.txt`, worktree `mcp-hub-moved`).
3. The app was rebuilt and relaunched after each fix, and the same rows were checked again on screen.
4. `scripts/outside-agent-smoke.py` signed an outside agent in through T3's MCP URL with a pairing code made by `t3 auth pairing create --base-dir <sandbox>/t3home`.

## What every T3 tool row shares

- The label comes from `T3_MCP_TOOLS` (shared/t3McpToolPresentation.ts:86-323): "Delegated a child task", "Read a T3 thread" and so on. CandyWrapper ported it before (`T3Store/T3McpTools.swift`) and the labels matched.
- The icon is T3's wordmark for `t3-code` tools, the browser app glyph for preview tools, a phone for device tools and the pull request glyph for PR tools (web/components/chat/MessagesTimeline.tsx:5267-5303 `workEntryIconName`, :4051-4092 `toolGroupSummaryIconName`, :4954-4972 `BrowserAppIcon`, :5141 `T3Wordmark`). Before: CandyWrapper drew a wrench for every T3 tool and a globe for browser groups. Now: `WorkIcons.tool` maps them, and `scripts/extract-icons` emits `brandT3Wordmark` and `brandBrowserApp` from T3's own SVGs.
- A failed call shows "Failed to …" in the tool error tone. That was ported before.

## Matrix

"Seen" means checked on screen against the sandbox. "Row" means the effect is the tool row and its output only.

### Orchestrator (server/mcp/toolkits/orchestrator/tools.ts)

| Tool | T3 shows | CandyWrapper before | After |
|---|---|---|---|
| `orchestrator_capabilities` | Row | Row (wrench) | Row, seen |
| `delegate_task` | The delegate row hides once the subagent card exists (web/components/chat/MessagesTimeline.logic.ts:1250-1275). The card is an avatar with the provider glyph and status dot, title, status beside a detail, elapsed time and a chevron, with the subagent hover card (web/components/chat/V2LifecycleRow.tsx:243-327, 420-530, SubagentTooltipContent.tsx:141-191). The child's completion notification draws as the same card with "Finished" and the time (V2LifecycleRow.tsx:335-398, MessagesTimeline.tsx:5362-5381). The child shows "Subagent of" and the prompt with "Sent by another agent" (MessagesTimeline.tsx:1409-1437, 2359-2395). Lineage lists it. | Card, Lineage and "Subagent of" right. The card did not open the child, and the child's prompt had no attribution. | Card opens the child with a chevron and `hover:bg-accent/20`. Attribution shown. Seen. Follow-up: `SubagentCardRowView` draws T3's card and hover card, the notification card replaces the work line, records refresh live. "Pong check" card, hover card and "Finished · 9:29" card seen. |
| `task_status` | Row | Row | Row, seen |
| `task_cancel` | Subagent card turns "Stopped", child shows "Run interrupted" | Same | Same, seen |
| `schedule_task` | Binds to the calling thread by default (server/mcp/OrchestratorMcpService.ts:1491-1545), so the thread details card shows it under Automations (web/components/chat/ThreadAutomationsPanel.tsx:46-72) | Missing. `ThreadSession.open` ran the automations sync before the new session was set, so the card filtered by the previous thread's id and showed another thread's tasks | Fixed: sync after the session is set. "Say hello" shows on the hub only. Seen. |
| `list_scheduled_tasks` | Row | Row | Row, seen |
| `update_scheduled_task` | The Automations row updates live | Missing (same bug) | Seen (renamed "Say hello") |
| `delete_scheduled_task` | The Automations row goes away | Missing (same bug) | Live list, not rechecked on screen |
| `request_secret` | Secret card in the timeline, "Input" in the sidebar (web/components/chat/SecretRequestCard.tsx:28) | Card and sidebar right; Decline worked | Same, seen |
| `create_threads` | New thread in the sidebar. In the calling thread a "Created thread" line with "Open chat" and the card in the turn summary with "Open chat" (V2LifecycleRow.tsx:171-209, MessagesTimeline.tsx:5390-5393 and 5674-5687). The new thread's prompt reads "Sent by another agent" (server/mcp/OrchestratorMcpService.ts:2165-2185 sets `senderThreadId`) | Sidebar right. Card had no "Open chat", the line had no "Open chat", no attribution | All three added. Seen, both open the thread. |
| `t3_thread_list` | Row | Row | Row, seen |
| `t3_thread_read` | `Read thread “title”` with the title linked to the thread (MessagesTimeline.tsx:3916-3958, MessagesTimeline.logic.ts:182-209) | "Read a T3 thread" | Linked title, opens the thread. Seen. |
| `t3_thread_update` | Title changes in header and sidebar | Right | Same, seen |
| `t3_thread_send` | Message in the target with "Sent by another agent" linking back | No attribution | Seen |
| `t3_thread_wait` | Row | Row | Row, seen |
| `t3_thread_interrupt` | Target run interrupted: "Run interrupted · Run interrupted by user" divider, then the queue drains | Called once; the target had already finished, so nothing to see | Follow-up 2026-10-11: interrupted a target parked in `t3_thread_wait` on itself. Divider seen, then the queued "Reply EDITED" ran. |

### HTML (toolkits/html)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `html_render` | The page in a sandboxed frame where the call happened (web/components/chat/HtmlRenderFrame.tsx:27) | Right (WP7.10) | Seen |
| `html_preview` | Row; the screenshot goes to the agent only (toolkits/html/handlers.ts:24-37) | Row (wrench) | Row, seen |

### Preview browser (toolkits/preview, previewControls)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `preview_open` | Server-hosted tab streamed to the client, floating mini player by default, "Agent has control" with Take control and the agent cursor (web/browser/ServerBrowserSurface.tsx:748) | Right (WP7.6b): mini player, agent cursor, Take control | Seen |
| `preview_snapshot`, `preview_hover`, `preview_click`, `preview_navigate`, `preview_scroll`, `preview_set_appearance`, `preview_evaluate`, `preview_wait_for`, `preview_type`, `preview_press`, `preview_resize`, `preview_recording_start`, `preview_recording_stop` | The streamed tab follows; rows wear the browser glyph | Stream right, rows had a wrench (groups a globe) | Browser glyph. Seen in one turn each (wait_for timed out on the agent's side). |
| `preview_status`, `preview_dialog`, `preview_select`, `preview_drag`, `preview_upload` | Same stream; a pending page dialog shows its message with "Take control to respond." over the tab (web/browser/ServerBrowserSurface.tsx:833-875) | Not called | Follow-up: one turn added a select, a drag pair and a file input to example.com; the mini player showed "b", the dropped box and "README.md". A pending `alert` showed "Candy dialog / Take control to respond."; `preview_dialog` accepted it. Rows wear the browser glyph. Seen. |
| `t3_preview_list` | Row | Row | Seen |
| `t3_preview_close` | Tab and mini player close | Right | Seen |

### Devices (toolkits/device)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `device_list`, `device_open`, `device_screenshot`, `device_close` | Device panel opens on `device_open` (docs/user/devices.md) | `device_list` failed with "Agent device access is turned off for this environment". This Mac has no simulator runtimes and no Node.js for T3's device helper | Not verified; rows wear the phone glyph |

### Attachments (toolkits/attachment)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `t3_attachment_prepare_upload`, `t3_attachment_discard` | Rows | Rows | Seen |
| `t3_thread_send_attachments` | The target's message with the file chip and "Sent by another agent" | File chip right, no attribution | Seen |

### Environment (toolkits/environment)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `t3_environment_read` | Row | Row | Seen |
| `t3_environment_preferences_update` | Settings change | The sandbox server answered "internal server error" both times | Follow-up: fails on the server, not in the client. The sandbox trace logs "Service not found: t3/orchestration-v2/ThreadCommandExecutor" for the call; the handler needs that service for thread callers (server/mcp/toolkits/environment/handlers.ts:57-73). T3 shows the same failed row. |

### Projects (toolkits/project)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `t3_project_list`, `t3_project_read` | Rows | Rows | Seen |
| `t3_project_create`, `t3_project_update`, `t3_project_delete` | Sidebar project added, renamed, removed | Right | Seen |
| `t3_project_clone` | Folder cloned; registered only if asked | Right (agent did not register it) | Seen |
| `t3_thread_launch` | New thread in that project; its prompt reads "Sent by another agent" | Thread right, no attribution | Thread seen; attribution uses the same path as `create_threads` |

### Pull requests (toolkits/pullRequests)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `link_pull_request` | Sidebar PR chip, details card row "#1" (web/components/chat/ThreadDetailsPrRows.tsx) | Right | Seen |
| `watch_pull_request` | "Waiting" in the sidebar, and an eye on the PR row that turns into eye-off on hover and stops the watch, in the split group's 32pt cell after a 16pt rule (web/components/chat/ThreadDetailsPrRow.tsx:347-382, 452-458, threadDetailsPanelStyles.ts:34-40, ThreadDetailsPrRows.tsx:77-93). The server wakes the agent on PR activity | Sidebar right, wake-up notification right ("#1: stopped watching, could not read it"), no eye | Eye added; clicking it stopped the watch and "Waiting" went away. Seen. Follow-up: the eye sits in T3's split cell (`DetailsRowControl.secondary`): rule, 32pt cell with its own hover fill, eye in `foreground/80`. Seen. |
| `unwatch_pull_request` | Eye goes away, "Waiting" leaves the sidebar | Not called by the agent | Follow-up: called by the agent; the eye and "Waiting" went away. Seen. |
| `list_thread_pull_requests` | Row | Row | Seen |
| `unlink_pull_request` | Row and chip go away | Not called | Follow-up: called by the agent (`wasLinked: true`); the details card row and the sidebar chip went away. Seen. |

### Threads (toolkits/thread)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `t3_thread_organize` | Pin, snooze, settle, archive, unread show in the sidebar | Right | Seen |
| `t3_queue_list`, `t3_queue_read`, `t3_queue_edit`, `t3_queue_cancel`, `t3_queue_reorder`, `t3_queue_promote_to_steer` | The target's queue strip and "Queued"/"Steer" markers change (web/components/chat/MessagesTimeline.tsx:2560-2605) | Called once; haiku drained the queue before the calls, so nothing changed | Follow-up: the target sat in `t3_thread_wait` on itself (Claude's harness blocks a foreground `sleep`) with three queued messages. After list, read, edit, reorder and cancel the strip read "Reply Q-INDIA", "Reply EDITED" (2). Promote put "Steer" with the redo arrow on Q-INDIA in the timeline. Seen. |
| `t3_pending_request_list`, `t3_pending_request_read`, `t3_pending_request_respond` | The target's question resolves and its run continues | Right ("You picked red") | Seen |
| `t3_thread_configuration` | Row | Row | Seen |
| `t3_thread_configure` | The target's composer model changes | Right (Haiku 4.5) | Seen |
| `t3_thread_fork` | New thread with "Forked from conversation", a bordered pill that opens the source (V2LifecycleRow.tsx:159-169, TimelineSystemDivider.tsx:35-66) | Divider without the action | Pill with border and hover, opens the source. Seen. |
| `t3_thread_merge_back` | "Context handoff" divider in the target; Lineage shows the transfer (cr/state/threadRelationships.ts:105) | Right | Seen |
| `t3_thread_transfers`, `t3_thread_search` | Rows | Rows | Seen |
| `run_scheduled_task_now` | The bound thread gets the prompt with "Sent by automation" linking the task (MessagesTimeline.tsx:2359-2379, cr/userMessage.ts) | No attribution | Seen; the link opens Settings > Scheduled Tasks |

### Worktrees (toolkits/worktree)

| Tool | T3 shows | Before | After |
|---|---|---|---|
| `t3_worktree_status`, `t3_worktree_list` | Rows | Rows | Seen |
| `t3_worktree_handoff` | Sidebar row shows the worktree branch; the live session detaches so the turn ends; the continuation prompt queues | Right, including the provider error row the detach leaves and the queued "reply moved" | Seen |

## Counts

80 tools (79 named in `tools.ts` plus `html_render`). The sandbox agent called 70 of them in WP7.15 and 77 after the follow-up.

- Before: 49 of the 70 showed their effect as T3 does, apart from the icon. 12 did not: delegate_task, schedule_task, update_scheduled_task, delete_scheduled_task, create_threads, t3_thread_read, t3_thread_send, t3_thread_launch, t3_thread_send_attachments, run_scheduled_task_now, t3_thread_fork, watch_pull_request. Every T3 tool row had the wrong icon.
- After WP7.15: those 61 showed as T3 does, icons included.
- After the follow-up (2026-10-11): 75 show as T3 does. Added: the six queue tools, `t3_thread_interrupt`, `preview_status`, `preview_dialog`, `preview_select`, `preview_drag`, `preview_upload`, `unlink_pull_request` and `unwatch_pull_request`. `t3_environment_preferences_update` fails inside the server, so the client can only show the failed row.
- Not verified: the four device tools. This Mac has no simulator runtimes, no Node.js for T3's device helper, and agent device access is off.

## Outside agent

`scripts/outside-agent-smoke.py` against the sandbox: discovery, dynamic registration, authorize, approval details, pairing-code decision, PKCE token, MCP initialize, `tools/list` (80 tools) and `t3_project_list` pass. Listing authorized clients needs an owner session with `access:read`, which the sandbox session token lacks; the script now says so instead of crashing. I revoked the smoke agent with `t3 auth session revoke --base-dir <sandbox>/t3home`.

## Left as is

- The subagent hover card shows the raw model id and skips the workspace, branch, effort and speed lines (`resolveSubagentMetadata`, SubagentTooltipContent.tsx:62-140).
- Favicons and themed app logos on provider tool rows (`ToolActivityIcon`) still fall back to lucide glyphs.

## Follow-up turns (2026-10-11)

1. Ten prompted claude-haiku-5-5 turns, one child turn and seven queued one-word replies, typed into `dev.candywrapper.test.cmcp` against the sandbox in the threads "MCP queue target" and "MCP followups".
2. Two turns failed to start a long run: Claude's harness blocks a foreground `sleep`, and `time.sleep` too. A self-wait (`t3_thread_wait` on its own thread, `timeoutMs` 170000) held the turn instead. A queued-message wake later left that thread "Thinking" for 10 minutes; I stopped it with the composer's stop button.
3. Sandbox side effects: example.com tab opened and closed, PR #1 unwatched and unlinked from "MCP followups", a "Pong check" child thread from `delegate_task`. No files written.
