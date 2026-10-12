# Niche gaps: T3 Code Nightly v0.0.46-nightly.20261009.2861 vs CandyWrapper

T3 paths are under /Users/mrm/CandyWrapper-research/t3code/apps/web/src/components (abbreviated `c/`). CW = /Users/mrm/CandyWrapper.

## Part 1: compaction, full list

C1. Compact chip before send (stale Claude session). MISSING.
- Sees: when the thread is Claude, context is 100,000 tokens or more, and the last update was 70 minutes or more ago, the send button gets a pill left of it. Pill reads "Compact 123k" (amber border), tooltip "Next send compacts 123k tokens first. Click to keep full history". Click flips it to "Full 123k" (grey), tooltip "Next send keeps all 123k tokens. Click to compact first". aria-label "Compact 123k tokens of history before sending".
- Send button while the pill is on: label "Compact and send", tooltip "Summarize 123k tokens of history, then send".
- Enter sends /compact as its own turn first, then queues the message behind it (dispatch mode forced to queue).
- Thresholds: c/chat/ContextWindowMeter.logic.ts:10-11 and :61-78 (`shouldOfferResumeCompaction`). Pill and strings: c/chat/ComposerPrimaryActions.tsx:274-277, 283-284, 304-306, 355-400. Compact-first send: c/ChatView.tsx:9267-9276, 9859-9872. Gating: c/ChatView.tsx:7696-7709 (hidden when compact is disabled, held queued runs exist, multi-model send, or dismissed).
- The off state is per thread in memory (`fullHistoryThreadKeys`, ChatView.tsx:7711-7726); a send that starts its turn clears it, a failed send keeps it.
- CW: grep for "Compact and send", "keepFullHistory", "Next send", "tokens of history", "shouldOfferResumeCompaction": nothing in Packages/CandyKit/Sources or App/Sources.

C2. Mobile collapsed composer label "Open composer to compact and send". Web or mobile only (ChatComposer.tsx:3028-3029, 6951). Not applicable on macOS.

C3. Permanent dismissal of the resume offer. MISSING (goes with C1).
- localStorage key `t3code:resume-compaction-dismissed:<environmentId>:<providerInstanceId>` (ChatView.tsx:4179-4204).
- The server's Claude dialog answer "Don't ask again" is mirrored into that key (`hasDismissedResumeCompaction`, ContextWindowMeter.logic.ts:46-62; strings in packages/shared/src/claudeCompaction.ts:8,21-28).

C4. Server resume dialog (client only renders it). Claude adapter asks a user-input question when it resumes an old session (apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:7143-7220). Header "Resume session". Question: "This session is 1h 20m old and uses 150,000 tokens. Compact it before continuing?" Options "Compact and continue" / "Keep full history" / "Don't ask again". CW shows any user-input request through the generic question panel, so this probably works but has not been checked against a real stale Claude session. CW grep for "Compact and continue" and "Don't ask again": nothing.

C5. "Compacting…" activity row. MISSING.
- Sees: after /compact is sent (Compact context button, /compact, or the chip) and until a completed compaction item for that run arrives, the working row reads "Compacting…" with a minimize icon and shimmer, and the Thinking placeholder row is blanked.
- T3: c/ChatView.tsx:3597-3619 (`isCompacting`), 3624-3628 (counts as working), 11393; c/chat/MessagesTimeline.tsx:1378-1380, 3705-3716, 3782-3789, 3793-3795.
- CW: grep "Compacting…", "isCompacting": nothing. CW shows "Working for Ns" and Thinking during a compact.

C6. Compact disabled conditions and reasons. PARTIAL.
- T3 disables manual compaction when: no write scope, no active thread, no user message other than a bare /compact, no project, not a server thread, provider has no compact command, working, reverting a checkpoint, thread detail loading, preparing worktree, environment unavailable, feedback uploading, pending approval or user input, or a plan follow-up is showing (c/ChatView.tsx:7661-7682).
- Reason strings (ChatView.tsx:7683-7691): "This connection cannot change threads." / "Choose a project before compacting" / "Compaction is unavailable for this provider" / "Compacting is unavailable right now". The meter shows the reason under a disabled button only when disabled (ContextWindowMeter.tsx:171-175).
- CW: App/Sources/ComposerController.swift:1049 checks only provider has `compact` and run busy or requests or plan follow-up. Strings are "This provider does not support manual compaction." and "Wait for the current turn to finish." Missing conditions: no project, detail loading, checkpoint revert, worktree prep, env unavailable, no user message. The slash item has its own check at ComposerController.swift:2190-2198 (uses latestUserMessageAt, busy, approval).

C7. Provider support check. PARTIAL.
- T3 `hasAvailableCompactionProvider` (ContextWindowMeter.logic.ts:19-44) looks at all instances of the driver, narrows to the locked thread's continuation group, then resolves the selectable instance and checks its slash commands for `compact`. Server adds the command: packages/provider-core/src/server/snapshotProbe.ts:50 (description "Summarize the conversation and reduce context usage"), Pi at packages/provider-pi/src/server/commands.ts:6 (input hint "Optional instructions").
- CW: ComposerController.swift:1049 uses `menuProvider?.slashCommands`. No continuation-group logic.

C8. /compact slash item. HAVE. T3 ChatComposer.tsx:2576-2586, 2726-2728 (only when the prompt is just "/compact", no attachments, contexts, annotations or review comments, and not compact-unavailable). CW ComposerController.swift:2190-2198 and ComposerMenus.swift:283 check prompt-alone, idle, has user message, no approval. It does not check for attachments, terminal contexts or pending user input.

C9. Compact context button and send. HAVE. CW ThreadContextWindowMeterView.swift:150 and ComposerController.swift:187-192 (saves and restores the draft). T3 sends /compact via `sendStandaloneCommand` (ChatView.tsx:7421-7500, 8651-8654). Differences: T3 inserts an optimistic "/compact" user message and clears it on failure; failure text "Failed to compact context." goes to the thread error banner. CW grep "Failed to compact": nothing. Not checked: whether CW shows the optimistic /compact message.

C10. Compaction timeline row. HAVE. Label `contextCompactionLabel` (packages/client-runtime/src/work-log/presentation.ts:52-62) matches CW T3Store/WorkLog.swift:168-174; row view CW TimelineFoldRows.swift:117-150. A lone compaction row stays visible when its group folds (MessagesTimeline.logic.ts:1095-1105); CW TimelineRows.swift:634 builds the row. Not checked: fold behavior.

C11. Lifecycle-card variants. PARTIAL. V2LifecycleRow.tsx:106-120 labels: "Compacting context" (pending, running, waiting), "Context compacted", "Context compaction failed" (red detail), "Context compaction stopped" (cancelled, interrupted), detail = summary or "<before> → <after> tokens". Shown in expanded turn folds (MessagesTimeline.tsx:3096, 3398). CW TimelineFoldRows.swift:224 always says "Context compacted" with only the summary.

C12. Context window meter. MOSTLY HAVE (ThreadContextWindowMeterView.swift). Gaps:
- Popup has a 6px progress bar (role progressbar, aria-label "Context window usage") under the header (ContextWindowMeter.tsx:128-143). CW draws text lines only (ThreadContextWindowMeterView.swift:150-170). small.
- Rows "Total processed" and "Cost" are label left, value right, 11px (tabular). CW prints "Total processed  12k" in one text block with two spaces. small.
- Meter slot is held while thread detail loads (`shouldReserveContextWindowMeter`, ContextWindowMeter.logic.ts:~118-130, `ContextWindowMeterPlaceholder`) so the attach button does not jump. CW grep: nothing. small.
- Popover opens on hover after 150 ms and closes 150 ms after leave when Compact is offered (ContextWindowMeter.tsx:60-62). CW opens on mouseEntered with no delay (ThreadContextWindowMeterView.swift:134-139). small.
- Meter is hidden unless setting `contextWindowMeterEnabled`; CW honors it (ComposerController.swift:1018).

C13. Sources: auto-compaction text "Compacts automatically at N tokens." / "Context for <model> compacts automatically when needed." HAVE (ThreadContextWindowMeterView.swift:155-158). CW passes `modelSelection.model` (a slug) as the display name (ComposerController.swift:1017); T3 uses the picker's display name (ContextWindowMeter.logic.ts:93-103). small.

## Part 2: top 25 other gaps, ranked by how often a daily user hits them

Evidence method: scripted extraction of user-visible strings from ChatView, Sidebar, BranchToolbar, chat/*.tsx, then a case-insensitive grep of CW sources (scripts in /tmp/cw-scan, not part of the repo). Each entry below was read in T3 and re-grepped in CW.

1. Send-blocked reasons on the send button. Sees: with the send button disabled, hover or VoiceOver says why: "Messages loading", "Rewinding conversation", "Preparing worktree", "Preparing machine", "Sending feedback", the clone block reason. When: switching to a thread whose detail is still loading, after rewind, during worktree setup. T3: ChatView.tsx:11618-11646 (also isWorking text at 3620). CW: only "Environment disconnected" and the upload block (ComposerController.swift:1036-1037); none of those strings exist. small.
2. Branch changed banner. Sees: a notice above the composer "Branch changed — was `feature-x`" with tooltip "This thread last ran on X. Sending will continue on Y.", button "Restore branch" (shows "Restoring..."), dismiss "Dismiss branch change notice"; restore asks about uncommitted changes (ChatView.tsx:11863 "You have uncommitted changes...", button "Switch branch"). When: a local-checkout thread whose branch no longer matches the checkout. T3: ChatView.tsx:7775-7840, 7742-7760 (restore), failure toasts 7328 "Failed to switch checkout" and 7352. CW: no "Branch changed" or "Restore branch"; PROGRESS.md only lists the hover-card branch line. medium.
3. "Compacting…" row and compact chip. See C5 and C1. medium each.
4. Empty server thread text "Send a message to start the conversation." Sees: centered 30% grey text in a thread with no turns. T3: MessagesTimeline.tsx:1550-1562. CW grep: nothing. small.
5. Background send failure recovery. Sees: error toast "Background task failed" with the error and an "Open draft" button; or "A background prompt could not be sent" with "Restore prompt" (and a follow-up text if the composer is not empty). When: a send started in the background fails. T3: ChatView.tsx:10092-10100, 9688-9712. CW: known ponytail at ComposerController.swift:1363-1364, strings missing. medium.
6. "Not connected: message not sent" toast. Sees: warning toast "Reconnecting to the environment. Try again once it is connected." on pressing send while the environment is down. T3: ChatView.tsx:8795-8812. CW disables the button with tooltip "Environment disconnected" (ComposerController.swift:1036) and shows no toast. small.
7. "Show notice details" info button on composer banners. Sees: an info icon button on the banner right side that opens a hover popover with the full title and description when the banner text is cut off. T3: ComposerBannerStack.tsx:256, 296-316 (aria-label "Show notice details", popup "Notice details"). CW ComposerNoticeBannerView.swift truncates with no popover (grep "notice details": nothing). medium.
8. Dismiss label "Dismiss warning" default and per-banner dismiss labels ("Dismiss update notice", "Dismiss branch change notice", "Dismiss feedback notice"). VoiceOver and tooltip only. ComposerBannerStack.tsx:374. CW has `dismissLabel` param (ComposerNoticeBannerView.swift:21) but the strings above are absent. small.
9. ChatGPT usage-limit error face. Sees: error banner with OpenAI logo, bold "ChatGPT usage limit reached" and "Review your usage settings in ChatGPT to continue." When: Codex turn fails with a ChatGPT usage limit. T3: chat/ThreadErrorBanner.tsx:55-66. CW: known ponytail ComposerFeedback.swift:142. small.
10. "No provider available" / "Open provider settings" control. Sees: in the composer footer, in place of the model picker, a red-alert control; click opens provider setup. When: no enabled provider. T3: ChatComposer.tsx:5470-5490. CW has only the placeholder "Enable a provider in Settings to send a message" (ComposerLogic.swift:85); grep for both control strings: nothing. small.
11. Failed goal and background-work actions. Sees: error text "Failed to resume goal.", "Failed to clear goal.", "Failed to stop background work.", "Failed to send plan follow-up.", "Failed to send messages." in the thread error banner. T3: ChatView.tsx:7404, 7526-7534, 10514, 9649. CW grep for all five: nothing; failures may surface with server text instead. small.
12. Stale-image paste guard. Sees: toast "Still compressing a pasted image." / "Send again once its thumbnail appears." when sending right after pasting a large image. T3: ChatComposer.tsx:4228-4247 (also "Send again once its chip resolves."). CW grep "compressing": nothing; CW may not compress at all, so this may not apply. small.
13. "Select at least one model." Sees: send disabled with this reason when multi-model mode has an empty model list. T3: ChatComposer.tsx:2188-2190. CW: nothing. small.
14. Antigravity send blocks. Sees: send disabled with "Install Antigravity in provider settings before sending.", "Sign in to Antigravity in provider settings before sending.", "Choose an Antigravity model before sending.", "Refresh Antigravity models in provider settings before sending." T3: ChatView.logic.ts:641-690, used at ChatComposer.tsx:2186. CW: no Antigravity handling in Sources. small (only for Antigravity users).
15. Annotation and composer-busy toasts. "Annotation attached to draft" (ChatView.tsx:8765), "Unable to add to chat" / "The composer is busy; try again once it is ready." (ChatView.tsx:4613, ChatComposer.tsx:6239), "The composer is not ready" / "Try citing the selection after the connection or pending input is resolved." (ChatView.tsx:1855). CW grep: none of these. small.
16. "Choose a project first" toast: "This draft no longer points to an available project." (ChatView.tsx:9210). CW: nothing. small.
17. Environment actions failures: "Could not reconnect environment", "Failed to reconnect.", "Failed to disconnect." (ChatView.tsx:2712-2741), "Could not switch machine" (4507), "Preparing machine" send block. CW grep: nothing. small.
18. Snapshot attachment viewer toggle: in the expanded image dialog a button swaps between "Show screenshot", "Show accessibility JSON" and "Show extracted text" for snapshot attachments (chat/ExpandedImageDialog.tsx:160-170, SnapShotAttachmentDetails.tsx). CW grep: nothing. medium.
19. Account label wording and toggle. T3 reveal tooltip "Click to reveal account" / "Click to hide account", aria "Toggle account label visibility" (ComposerUsageLimits.tsx:34-36). CW says "Click to reveal email" (UsageLimitsView.swift:56). small.
20. Panel toggle tooltips when unavailable: "Right panel is unavailable", "Terminal drawer is unavailable", "Toggle thread details panel", "Toggle thread details" (chat/PanelLayoutControls.tsx:45-104). CW has "Toggle terminal" (ThreadPanelView.swift:73) but not the others. small.
21. VoiceOver-only status text: "Regenerating title" (Sidebar.tsx:1840, 2155), "Fast mode on"/"Ultrafast mode on" (chat/TraitsSpeed.tsx:66), "Editing queued message:" and "Saving queued message" (chat/QueuedRunsControl.tsx:367-370), "Thread search results" (Sidebar.tsx:5155), "Thread breadcrumb" (chat/ChatHeader.tsx:263), "Stop generation" aria-label (ComposerPrimaryActions.tsx:149; tooltip "Interrupt" matches CW). CW grep: none. small (one pass).
22. Read-only connection messages: "This connection cannot change threads." on send, "Thread action unavailable" / "This connection cannot change one or more selected threads." (Sidebar.tsx:321-322, ChatView.tsx:7685, 9418, 11620). CW has them only for project settings. small, only for scoped pairings.
23. Multi-model server version guard: "Update this server before starting multiple models." (ChatView.tsx:8829) and "Update this environment's T3 Code server to browse pull requests." (11010). CW grep: nothing. small.
24. Codex feedback guard: "Start a Codex thread first" / "Send a message before you submit feedback." (ChatView.tsx:9058-9059). CW grep: nothing. small.
25. Server and Work locally items (already known): server update banner and "Update all" (ChatView.tsx:3150-3225, useAutoBalanceUpdateBanner.tsx), worktree card "Work locally" (ChatView.tsx:1883, 10824; WorktreeSetupCard.tsx:424). parity-checklist rows 91, 173, 578 list them as gaps, so skipped from the ranking beyond this line.

Checked and found already covered (no action): Mermaid expand, provider update launch and primary notifications, keybinding command ids, "Roll back this thread" dialog, queued message tooltips, project clone banner, assistant citation chips, timeline interrupt request hiding (T3 hides it too, MessagesTimeline.logic.ts:1529-1535), todo_list not shown as a row.

Not checked: the exact T3 hover timings of the meter against CW with a screen capture; whether CW shows an optimistic "/compact" user row; whether CW pasted images are compressed.
