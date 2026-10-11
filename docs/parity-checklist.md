# T3 Code parity checklist

Target: official T3 Code v0.0.46-nightly.20261009.2861, native macOS (Swift/AppKit) client.
Status 2026-10-11: 188 🟡, 92 ➖, 133 ⏳, 12 M9, 13 n/a.

Status legend:

- `⏳` not built.
- `🟡` built but not yet verified side by side with the official app.
- `✅` reserved for milestone 10's side-by-side verification. Nothing uses it yet.
- `➖` partly built. Notes say what is missing.
- `M9` packaging work (signing, updates, CLI install) planned for milestone 9.
- `n/a` not in the official macOS app, or not to be built. Notes say why.

Source of truth is the read-only tree at `/Users/mrm/CandyWrapper-research/t3code`.

Path shorthand in the "Official source" column:

- `comp/` = `apps/web/src/components/`
- `web/` = `apps/web/src/`
- `desk/` = `apps/desktop/src/`
- `docs/` = `docs/user/`
- `contracts/` = `packages/contracts/src/`

Rows marked `needs webview: ask user` render web content or need a JS runtime in the official app. Do not build those without asking the user first. See the section "Webview and JS runtime summary" at the end.

## Sidebar

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Sidebar shell, resizable width, collapse toggle (`sidebar.toggle`) | comp/Sidebar.tsx, comp/AppSidebarLayout.tsx, comp/threadSidebarWidth.ts, comp/ui/sidebar.tsx | 🟡 | Width persisted per client; collapse animates per Panel animations setting |
| Sidebar header: wordmark, back/forward, new thread, search | comp/sidebar/SidebarThreadHeader.tsx, comp/sidebar/SidebarChrome.tsx, comp/T3Wordmark.tsx | ➖ | Missing: back/forward buttons |
| Project list grouped by project, collapsible project rows | comp/Sidebar.tsx, web/sidebarProjectGrouping.ts, web/logicalProject.ts | n/a | Same repo on several environments groups into one logical project; Missing: collapsible project rows; groups feed the scope popup and row labels; Not applicable: Collapsible project rows exist only in LegacySidebar.tsx. The current sidebar filters by project through the scope popup (`SidebarProjectScopeView`). |
| Project grouping and order (settings: Project grouping, Project order) | comp/settings/SettingsPanels.tsx, web/sidebarProjectGrouping.ts | ➖ | Missing: the two settings; fixed to updated-at order and repository grouping; Audit 2026-10-11: `SidebarModel.buildProjectGroups` groups by repository; the order setting drives the scope popup (`GeneralSettingsView`). Grouping setting is stored only. |
| Project filter ("All projects" select) and project search | comp/Sidebar.tsx | 🟡 | |
| Project favicon / monogram / custom icon with color | comp/ProjectFavicon.tsx, comp/ProjectMonogram.tsx, web/projectIconColors.ts, comp/settings/ProjectIconPickerDialog.tsx | ➖ | Favicon fetched from server asset; monogram fallback; Missing: icon picker dialog; Audit 2026-10-11: Favicon and monogram in `Features/Sidebar/ProjectIcons.swift`. Icon picker dialog missing (buttons disabled in `ProjectSettingsView`). |
| Project environment badge (remote machine marker) | comp/ProjectEnvironmentBadge.tsx, comp/EnvironmentMachineIcon.tsx | 🟡 | |
| Project row menu (new thread, rename, project settings, remove, copy path, open in editor) | comp/Sidebar.tsx | ➖ | Audit 2026-10-11: Row menu is LegacySidebar-only. The scope popup settings button (`SidebarProjectScopeView.onSettings`) calls `actions.openProjectSettings`, which no App code sets. Unwired. |
| Threads without a project ("No project" group, scratch folder) | docs/thread-sidebar.md, comp/Sidebar.tsx | ⏳ | `mod+alt+n`; folder under ~/.t3/scratch |
| Section: Pinned | comp/Sidebar.tsx, docs/thread-sidebar.md | 🟡 | Boundary label shown while dragging |
| Section: Active (ordered, new threads on top) | comp/Sidebar.tsx | 🟡 | |
| Section: Working (beta, folds running/monitoring threads) | comp/Sidebar.tsx, comp/settings/SettingsPanels.tsx | ⏳ | Setting "Working section (beta)"; disables manual ordering |
| Section: Snoozed shelf | comp/Sidebar.tsx, comp/Sidebar.snooze.ts | 🟡 | Cannot drop into it; dragging out wakes |
| Section: Settled shelf (collapsible) | comp/Sidebar.tsx | 🟡 | Ordered by settlement time |
| Thread row: title, relative time, project/branch subtitle, status badge | comp/Sidebar.tsx, comp/ThreadStatusIndicators.tsx, comp/ThreadCommandSubtitle.tsx | 🟡 | PR badge (WP7.5b): stack count, `+n`, or the number in the state tone; one link opens it, several open the thread's Pull requests tab. WP7.5c: the badge's hover mini list (`ThreadPullRequestsMiniListView` on the glass tooltip, stack depth steps, "stack · n" or "chain · n"). Missing: mini list rows as links, the branch PR from git status |
| Thread status labels: Working, Goal, Waiting, Approval, Input, Limited, Failed, Woke, Done | comp/Sidebar.tsx (around line 1297), comp/ThreadStatusIndicators.tsx | 🟡 | Colored dot or pill per state |
| Unsent draft rows with discard button | comp/Sidebar.tsx | 🟡 | Undo restores text and attachments |
| Thread hover card (summary, PR, branch) | comp/ThreadHoverCard.tsx | ⏳ | The PR rows exist (`ThreadPullRequestsMiniListView`, shown on the sidebar badge since WP7.5c); the card itself (title, project, environment, branch, provider, terminal, error rows) is not built |
| Thread row actions: settle, wake, unpin, discard, snooze | comp/Sidebar.tsx | 🟡 | Hover buttons; press-and-drag range select on Settle; Missing: row buttons are drawn but not wired to server commands; Built (audit 2026-10-11): `SidebarCommands.settle/unsettle/snooze/pin/unpin` behind the row buttons (`RowActionButton` in `SidebarRowViews`). Stale mark. |
| Thread context menu: Pin, Settle, Snooze (presets and Custom...), Archive, Delete, Rename, Regenerate title, Copy path, Copy branch, Copy thread ID, Auto-settle behavior, Move up/down, Mark unread | comp/Sidebar.tsx, comp/threadActionMenu.logic.ts | ➖ | Audit 2026-10-11: `ThreadActionMenu.items` plus `SidebarCommands.showThreadMenu/perform`: pin, settle, snooze presets, archive, regenerate title, mark unread, copy path/branch/ID, auto-settle. Missing (`SidebarCommands.unbuiltMenuItems`): rename, delete, custom snooze, new thread on branch, project settings. |
| Custom snooze dialog (date/time or duration) | comp/CustomSnoozeDialog.tsx, comp/Sidebar.snooze.ts | ⏳ | |
| Multi-select threads (cmd/shift click) with bulk actions | web/threadSelectionStore.ts, comp/Sidebar.tsx | ⏳ | Bulk settle, snooze, archive, delete, regenerate titles |
| Inline thread rename | comp/Sidebar.tsx | ⏳ | Empty title rejected with toast |
| Drag and drop reorder within and between sections with action badge (Pin, Unpin, Settle, Un-settle, Wake) | comp/Sidebar.drag.ts, comp/Sidebar.motion.ts, comp/Sidebar.pointer.ts, docs/thread-sidebar.md | ⏳ | Reduced motion respected |
| Drag thread onto composer to attach as context | comp/chat/threadContextDrag.ts, comp/chat/ThreadContextDragGhost.tsx | ⏳ | |
| Drop files onto thread row to attach in its composer | web/sidebarPendingFileDropStore.ts, docs/thread-sidebar.md | ⏳ | |
| Undo notice at bottom of sidebar (5 s, `thread.undo`) | comp/sidebar/SidebarThreadUndoNotice.tsx | 🟡 | Built (audit 2026-10-11): `SidebarUndoNoticeView`, `SidebarCommands.showUndo`, `thread.undo` shortcut. Stale mark. |
| Thread search results inside sidebar (message search, 2+ chars) | comp/Sidebar.tsx, comp/ThreadSearchMatch.tsx | 🟡 | Also in command palette |
| Thread relationships (fork, subagent, handoff) icons and navigation | comp/chat/ThreadRelationshipIcon.tsx, comp/chat/ThreadRelationshipsControl.tsx | ⏳ | |
| Sidebar footer: settings entry, usage entry, connection status | comp/Sidebar.tsx, comp/ConnectionStatusDot.tsx | 🟡 | Missing: Usage button does nothing, no connection status; Built (audit 2026-10-11): Settings, Pull Requests and Usage buttons in `SidebarContentView`. The official Sidebar.tsx does not draw a connection status dot. The Usage page behind the button is in progress. |
| Desktop update pill and release notes in sidebar | comp/sidebar/SidebarUpdatePill.tsx, comp/sidebar/SidebarUpdateReleaseNotes.tsx, comp/sidebar/DesktopUpdateStatusIcon.tsx | M9 | Milestone 9: Update pill needs the auto-updater. |
| Provider update pill in sidebar | comp/sidebar/SidebarProviderUpdatePill.tsx, comp/ProviderUpdatesAction.tsx | ⏳ | |
| T3 Connect sign-in in sidebar | comp/clerk/T3ConnectSidebarSignIn.tsx | 🟡 | Clerk sign-in UI; needs webview: ask user; Built (audit 2026-10-11): T3 puts it in the settings sidebar footer. Built in `T3ConnectSignInView` and `T3ConnectController` (native Clerk, email code and password). Stale mark. |
| Open pull requests entry (PR list page) | web/routes/_chat.pull-requests.tsx | ✅ | Opens the Pull Requests page (WP7.5b) |
| Settled/auto-settle rules (merged PR, 3 days inactive, closed PR) | docs/thread-sidebar.md | 🟡 | Server-owned; client only displays and configures; Built (audit 2026-10-11): Server-owned. The Settled shelf and sections display it (`SidebarListModel`); auto-settle settings in `GeneralSettingsView`. |
| Limited-thread recovery in sidebar (Resume at reset, Snooze until reset, Wake now) | comp/Sidebar.tsx, comp/chat/UsageLimitRecoveryBanner.tsx | ⏳ | |
| Legacy sidebar (opt-in setting) | comp/LegacySidebar.tsx | ⏳ | Low priority; setting "Sidebar (legacy)" |
| Empty states: no projects hero, no active thread | comp/NoProjectsHero.tsx, comp/NoActiveThreadState.tsx | ➖ | Missing: no-projects hero; text-only empty state; Audit 2026-10-11: Text-only empty state. `SidebarListModel` notes the missing "Add project" button; no-projects hero missing. |
| Legacy thread migration toast | comp/LegacyThreadMigrationToast.tsx, docs/thread-migration.md | ⏳ | |

## Thread view

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Chat canvas layout, chat width setting (comfortable, wide, full) | comp/chat/ChatCanvas.tsx, comp/chat/chatCanvasLayout.ts, comp/ChatView.tsx | ➖ | Missing: chat width setting |
| Thread header: breadcrumb (project > thread), editable title, thread actions menu | comp/chat/ChatHeader.tsx, comp/WorkspaceBreadcrumb.tsx | ➖ | Missing: editable title, thread actions menu; Audit 2026-10-11: `ThreadHeaderView` draws project / title. No editable title, no thread actions menu. |
| Header controls: Open in editor picker, git actions, project scripts, panel layout toggles | comp/chat/OpenInPicker.tsx, comp/GitActionsControl.tsx, comp/ProjectScriptsControl.tsx, comp/chat/PanelLayoutControls.tsx | ➖ | The details toggle opens the thread details card with the git actions (WP7.5a). Missing: editor picker, project scripts; Audit 2026-10-11: Details toggle and panel toggles in `ThreadHeaderView`; git actions in `ThreadDetailsCardView`. No editor picker, no project scripts control. |
| Thread details panel/card (PR rows, branch, worktree, runtime, automations) | comp/chat/ThreadDetailsPanel.tsx, comp/chat/ThreadDetailsCard.tsx, comp/chat/ThreadDetailsPrRows.tsx | ➖ | Workspace (run context) and Version Control (branch, git actions, Changes or Initialize Git). Always the popover placement under the header; T3 pins it inline and shifts the chat lane from a 1012pt column. PR rows (WP7.5b): the current link as "#n: title" in its state tone, the rest behind "Show N more", each opening its PR tab. Missing: Open in, project scripts, the PR row's second line (checks, watch, action), automations, lineage, compact densities; Audit 2026-10-11: `ThreadDetailsCardView` has workspace, version control and PR rows. Missing: inline placement, Open in, scripts, PR second line, automations, lineage, compact densities. |
| Thread status line (running, elapsed, agent activity) | comp/chat/ThreadStatusLine.tsx, comp/chat/AgentElapsed.tsx | ➖ | Missing: agent activity text; only the "Working for Ns" row exists; Audit 2026-10-11: `WorkingRowView` shows "Working for Ns". No agent activity text. |
| Timeline: user message bubble (text, chips, image shelf, file chips) | comp/chat/MessagesTimeline.tsx, comp/composerInlineChip.ts | ➖ | Image grid (`max-w-[210px]` 2 columns, 4:3, `assets.createUrl` then decoded at cell size; a click opens the preview) and rows for files without a chip. Missing: chips in the text (links still), file row preview and download, videos; Audit 2026-10-11: Image grid and file rows in `TimelineMessageRows`. Missing: chips in text, file preview and download, video. |
| Timeline: assistant message with markdown | comp/chat/MessagesTimeline.tsx, comp/ChatMarkdown.tsx | 🟡 | Incremental streaming render (web/markdown-incremental.ts) |
| Timeline: assistant meta row (model, duration, copy, timestamps) | comp/chat/MessagesTimeline.logic.ts (`assistant-meta`) | 🟡 | |
| Timeline: thinking / reasoning row | comp/chat/MessagesTimeline.logic.ts (`thinking`) | 🟡 | Collapsible |
| Timeline: working indicator row | comp/chat/MessagesTimeline.logic.ts (`working`) | 🟡 | |
| Timeline: work log group (live and folded, `work`, `work-live`, `work-toggle`) | comp/chat/WorkLog.tsx | 🟡 | Collapsed summary with "show N tool calls" toggle |
| Timeline: turn fold and attempt fold | comp/chat/MessagesTimeline.logic.ts (`turn-fold`, `attempt-fold`) | 🟡 | |
| Timeline: proposed plan card | comp/chat/ProposedPlanCard.tsx | 🟡 | Markdown body, copy, save, implement action |
| Timeline: context compaction divider | comp/chat/MessagesTimeline.logic.ts (`context-compaction`), comp/chat/TimelineSystemDivider.tsx | 🟡 | |
| Timeline: system events (`event`), lifecycle rows | comp/chat/V2LifecycleRow.tsx, comp/chat/TimelineSystemDivider.tsx | 🟡 | |
| Timeline: V2 item inspector (raw item detail) | comp/chat/V2ItemInspector.tsx | ➖ | Missing: rich blocks (search links, JSON highlighting, Open diff); Audit 2026-10-11: `WorkDetailView` shows item detail. No rich blocks or Open diff. |
| Timeline: worktree setup card (progress of setup script) | comp/chat/WorktreeSetupCard.tsx | ⏳ | |
| Timeline: secret request card | comp/chat/SecretRequestCard.tsx | ➖ | Agent asks for a secret via MCP `request_secret`; Missing: only the title row; the secret entry form is not built; Audit 2026-10-11: `EventRowView` shows a title row for `.secretRequest`. No secret entry form. |
| Timeline: HTML render frame (visual replies) | comp/chat/HtmlRenderFrame.tsx, docs/html-renders.md | ⏳ | needs webview: ask user |
| Timeline: MCP app frame (MCP Apps standard) | comp/chat/McpAppFrame.tsx, docs/html-renders.md | ⏳ | needs webview: ask user |
| Timeline: subagent items and bar | comp/chat/ProviderSubagentBar.tsx, comp/chat/SubagentTooltipContent.tsx, comp/chat/agentSpawnSummary.ts | ➖ | "Agents" follow-along; Stop also stops subagents; Missing: follow-along bar; subagents show as event cards; Audit 2026-10-11: Subagent items render as event cards (`EventRowView`). No follow-along bar. |
| Timeline: fork / handoff / thread_created items | contracts/orchestrationV2.ts (item types) | 🟡 | |
| Timeline: error rows and thread error banner | comp/chat/ThreadErrorBanner.tsx | 🟡 | |
| Provider status banner (not installed, not signed in, outdated) | comp/chat/ProviderStatusBanner.tsx | ⏳ | |
| Markdown: headings, lists, tables, task lists, blockquote, hr, links, inline code | comp/ChatMarkdown.tsx (react-markdown + remark-gfm) | 🟡 | |
| Markdown: GitHub alerts (NOTE, TIP, WARNING...) | web/markdownGithubAlerts.test.tsx, comp/ChatMarkdown.tsx | 🟡 | |
| Markdown: fenced code with syntax highlighting, copy button, language label | comp/chat/HighlightedCodeLines.tsx, comp/chat/HighlightedTokens.tsx | 🟡 | Shiki in the web app; use a native highlighter |
| Markdown: Mermaid diagrams | comp/chat/MermaidDiagram.tsx | ⏳ | needs webview: ask user (mermaid is a JS library) |
| Markdown: images and image gallery, zoomable image, expanded image dialog | comp/chat/markdownImageGallery.ts, comp/chat/ZoomableImage.tsx, comp/chat/ExpandedImageDialog.tsx | ➖ | Missing: images are a loading slot, no gallery or zoom; Audit 2026-10-11: `MarkdownLayout` .image reserves a 16:9 loading slot. No loading, gallery or zoom. |
| Markdown: video/audio attachments and media actions | comp/media/MediaVideoPlayer.tsx, comp/media/MediaActions.tsx, comp/files/AudioPreview.tsx | ➖ | AVKit natively; Audit 2026-10-11: AVKit used in `FileSurfaceView` for file tabs. No media in markdown or attachments. |
| Markdown: file links (path:line) open in file panel; external links open in browser | web/markdown-links.ts, comp/chat/MarkdownThreadLink.tsx, comp/chat/externalLinkContextMenu.ts | ➖ | WP7.6a: a click opens the file tab at its line (`panelPath`), user bubbles included. WP7.5c: web links are hit tested (`MarkdownLayout.links`, `MarkdownLinkHitView`): click opens (a pull request a project reads opens in the panel), the URL tooltip, right-click menu (Open in system browser, Copy Link) through `MarkdownView.linkHandler`. Missing: Cmd-click to the preferred editor, the chip menu's Open and Reveal items, "Open in integrated browser" in the link menu, link favicons; Audit 2026-10-11: File links open the panel, web links hit tested (`MarkdownLinkHitView`). Missing: Cmd-click to editor, chip menu Open and Reveal, link favicons. |
| Markdown: thread links, PR link previews | comp/chat/MarkdownThreadLink.tsx, comp/pullRequest/PullRequestLinkPreview.tsx | 🟡 | WP7.5c: a pull request URL a project reads gets the preview card after 350 ms (`PullRequestLinkPreviewView`, `pullRequests.detail`, cached), right-click adds Link to thread or Unlink from thread (`thread.pull-request.link`/`unlink` or the legacy meta update). Fidelity `pull-request-writes` link-preview. Missing: `t3-thread://` links, reference autolinks (`#123`) with `confirmBeforeOpen` |
| Markdown: assistant citation chips with comments | comp/chat/AssistantCitationChip.tsx, comp/chat/AssistantCitationCommentEditor.tsx | ⏳ | |
| Markdown: skill inline text, shell command block | comp/chat/SkillInlineText.tsx, comp/chat/ShellCommandBlock.tsx, comp/CommandBlock.tsx | ⏳ | |
| Markdown: copy as Markdown (chips become links) | web/markdown-clipboard.ts, comp/chat/MessageCopyButton.tsx | 🟡 | |
| Quote an assistant response / selection toolbar | comp/chat/AssistantSelectionToolbar.tsx, docs/composer.md | ⏳ | Floating toolbar on text selection |
| Tool card: command execution (command, status, exit code, expandable output) | comp/chat/WorkLog.tsx, comp/CommandBlock.tsx | 🟡 | Summaries shorten shell wrappers |
| Tool card: file change (path list, +/- counts, inline diff) | comp/chat/WorkLog.tsx, comp/chat/DiffStatLabel.tsx, comp/chat/ChangedFilesTree.tsx | ➖ | Missing: inline diff; Audit 2026-10-11: `ChangedFilesCardView` and work rows show paths and counts. No inline diff. |
| Tool card: file search / web search | comp/chat/WorkLog.tsx | 🟡 | |
| Tool card: todo list | comp/chat/WorkLog.tsx, comp/chat/ComposerTasksBadge.tsx | ⏳ | Also a tasks badge above composer |
| Tool card: dynamic / MCP tool call (name, args, result) | comp/chat/WorkLog.tsx | 🟡 | |
| Tool card: checkpoint, system notice, notification items | contracts/orchestrationV2.ts, comp/chat/WorkLog.tsx | 🟡 | |
| Changed files tree and per-turn diff summary | comp/chat/ChangedFilesTree.tsx | 🟡 | Click opens Diff panel at that turn/file |
| Approval request UI (command/file/permission): Approve, Approve for session, Decline, Cancel | comp/chat/ComposerPendingApprovalPanel.tsx, comp/chat/ComposerPendingApprovalActions.tsx | 🟡 | Replaces composer while pending |
| User input request (questions, options, free text, multi-question, file answers) | comp/chat/ComposerPendingUserInputPanel.tsx, web/pendingUserInput.ts, docs/question-attachments.md | 🟡 | Keyboard 1-9 selects options |
| Plan mode: proposed plan with follow-up banner (Implement / refine) | comp/chat/ComposerPlanFollowUpBanner.tsx, comp/chat/ProposedPlanCard.tsx, web/proposedPlan.ts | ➖ | Audit 2026-10-11: `PlanRowView` draws the proposed plan card with Expand plan. No follow-up banner (Implement or refine) and no plan actions menu. |
| Permission modes (Supervised, Auto-accept edits, Full access) and per-provider differences | docs/permission-modes.md, comp/chat/runtimeModeConfig.ts | 🟡 | |
| Permission update notice | comp/PermissionUpdateNotice.tsx | ⏳ | |
| Interrupt / Stop turn (button, `thread.stop`) | comp/chat/ComposerPrimaryActions.tsx | 🟡 | |
| Steer (send while running) and Queue follow-up | comp/chat/ComposerPrimaryActions.tsx, docs/composer.md | 🟡 | Follow-up behavior setting; `mod+enter` flips |
| Queued messages list: edit, reorder, cancel, promote to steer | comp/chat/QueuedRunsControl.tsx, comp/chat/queuedMessageEdit.ts, docs/composer.md | 🟡 | `alt+arrowup` edits, `mod+shift+enter` steers |
| Resume button in empty composer (limited or interrupted turn) | docs/thread-sidebar.md, comp/chat/UsageLimitRecoveryBanner.tsx | ➖ | Missing: usage-limit failures do not offer Resume; Audit 2026-10-11: `ComposerLogic` resume face and "Resume thread" tooltip. Usage-limit failures do not resume (ponytail at ComposerLogic.swift:169). |
| Usage limit recovery banner (auto-resume, snooze until reset) | comp/chat/UsageLimitRecoveryBanner.tsx | ⏳ | |
| Goal row above composer (`/goal`) | docs/composer.md, comp/chat/ComposerBanner.tsx | ⏳ | |
| Scroll: stick to bottom, scroll-to-bottom pill, anchoring on prepend | comp/chat/timelineScrollAnchoring.ts, comp/chat/pageScrollController.ts, comp/chat/timelineScrollTarget.ts | 🟡 | |
| Timeline minimap | comp/chat/timelineMinimapItems.ts | ⏳ | |
| Snapshot pagination of long threads (load older) | D-server-features.md (`threadSnapshotPagination`) | 🟡 | |
| Find in thread bar (`chat.find`) with highlights and next/prev | comp/chat/ThreadFindBar.tsx, comp/chat/useThreadFind.ts, comp/chat/threadFindHighlights.ts | ⏳ | Server-side thread find, progressive |
| Edit an earlier prompt and rerun / fork | docs/composer.md (Edit an earlier prompt) | ⏳ | |
| Fork thread, merge back, handoff to worktree | contracts/rpc.ts, comp/chat/ThreadRelationshipsControl.tsx, docs/portable-handoffs.md | ⏳ | |
| Restart agent session | comp/CommandPalette.tsx (line ~2000) | ⏳ | Palette action |
| Activity log | docs/activity-log.md | 🟡 | Check what UI it describes before building; Built (audit 2026-10-11): Fold summaries ("Ran 2 commands...") in `T3Store/WorkLog.swift`, `WorkLogText.swift`, `T3McpTools.swift`. The doc describes exactly this. Open diff belongs to row 88. |
| Context window meter | comp/chat/ContextWindowMeter.tsx | ⏳ | Click offers compact |
| Thread automations panel (scheduled tasks, PR watch) | comp/chat/ThreadAutomationsPanel.tsx | ⏳ | |
| Thread-linked pull requests panel | comp/pullRequest/ThreadPullRequestsPanel.tsx | 🟡 | WP7.5b: the `pull-requests` tab, rows stepped by stack depth newest chain first, unsynced rows muted, footer counts and Link, row menu (Copy link, Open, Watch, Unlink or Dismiss), empty state. Missing: Shift quick actions on rows, hover menu button |
| Agent browser cursor overlay (agent clicking in a preview) | comp/preview/AgentBrowserCursor.tsx | 🟡 | WP7.6b: `pointer` messages from the stream place `AgentCursorView` over the letterboxed frame (`placeAgentCursor`): mouse-pointer-2 in primary, a ping on clicks, full opacity for 700 ms, then 35%. Seen on screen while a haiku turn drove a tab |
| Drag files onto thread to attach | comp/chat/workspaceFileDrop.ts, comp/chat/folderDrop.ts | ⏳ | |

## Composer

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Composer surface: rich text editor (bold, italic, code, lists, blockquote, headings, hr, task list) | comp/chat/ChatComposer.tsx, comp/ComposerPromptEditorTiptap.tsx, web/composer-rich-text.ts | ➖ | Setting "Rich text composer" toggles Markdown source mode; Missing: plain text only, no formatting |
| Fenced code block node with language picker | comp/chat/ComposerCodeBlockNodeView.tsx, comp/chat/ComposerCodeBlockLanguagePicker.tsx, web/composer-code-languages.ts | ⏳ | |
| List continuation and splitting, undo grouping | web/composer-list-continuation.ts, web/composer-undo-grouping.ts | ⏳ | |
| Send shortcut modes (Enter / mod+Enter multiline / always mod+Enter) | docs/keybindings.md, comp/chat/composerSubmission.ts | 🟡 | Setting has no UI yet; default Enter |
| Primary action button (send, stop, queue, steer) | comp/chat/ComposerPrimaryActions.tsx | 🟡 | |
| Slash command menu (`/`) incl. provider commands, T3 commands (`/model`, `/plan`, `/goal`, `/compact`) | comp/chat/ComposerCommandMenu.tsx, comp/chat/composerSlashCommandSearch.ts, comp/chat/useComposerTriggerState.ts | 🟡 | `/model` opens the picker; `/plan` and `/default` only with plan mode (no setting UI yet); `/goal`, `/compact` (idle thread with a conversation, prompt is the command alone), `/feedback` and skills come from the provider's commands (`server.refreshProviders` per cwd); provider commands only at the prompt start; `/usage-limits` opens the usage page. Fidelity `composer-menu` |
| Skill picker (`$`) and skills in slash menu | comp/chat/ComposerCommandMenu.tsx, web/providerSkillSearch.ts | 🟡 | Source badges; "Show skills in / menu" setting assumed on |
| File mention picker (`@`) with workspace file search and thread mentions | comp/chat/ComposerCommandMenu.tsx, web/composer-editor-mentions.ts | 🟡 | `projects.searchEntries` (120 ms debounce, 80 rows), up to 5 thread matches first; picks insert `[name](path)` or a thread context link with its record in `context` |
| Pull request picker (`#`) | docs/composer.md, comp/chat/ComposerCommandMenu.tsx | ➖ | `pullRequests.list` for the project's repository; picks a review-comment record. Missing: `pullRequests.detail` lookup for a number outside the 99 listed; not tried on screen (sandbox repo has no remote); Audit 2026-10-11: `PullRequestCandidatePickerView` lists the repository PRs. No `pullRequests.detail` lookup outside the listed 99. |
| Inline context chips: terminal excerpt, review comment, preview annotation, file, PR, thread, image | comp/composerInlineChip.ts, comp/ContextChip.tsx, comp/ThreadContextChip.tsx, comp/chat/FileTagChip.tsx, comp/chat/TerminalContextInlineChip.tsx | ➖ | File/folder mention, skill, thread, PR, attached image and file (size, upload percent or "upload failed") and unresolved chips in the editor, one character each (deletes as a unit); a token becomes a chip once whitespace follows. Missing: terminal, review comment and annotation chips (their producers come later), the image chip's average-color accent, hover brief, click to open, chips in sent message bubbles; Audit 2026-10-11: File, folder, skill, thread, PR and attachment chips (`ComposerChips`). Missing terminal, review comment and preview annotation chips. |
| Chip copy/paste across drafts | web/composerHandleContext.ts, comp/composerInlineTokenPaste.ts | 🟡 | Copy writes the expanded text plus T3's `data-t3-context-fragment` HTML flavor; paste imports the records the pasted links reference |
| Image thumbnail shelf, expanded preview | comp/chat/ComposerImageThumbnail.tsx, comp/chat/ExpandedImagePreview.tsx | 🟡 | 64pt tiles decoded off the main thread at tile size (ImageIO thumbnails), upload percent strip, retry, remove (asks when the text mentions the image); preview with arrows, Escape, backdrop click, decoded at the box size. Fidelity `composer-attachments`. Missing: zoom and pan, media context menu (save, copy), videos |
| Attach files (picker, drag, paste), 50 MiB per file, HTTP upload flow | docs/composer.md, comp/chat/composerAttachmentFiles.ts | 🟡 | Paperclip, drop on the composer, paste (images always, files without text, pasted image data as `image.png`); T3's classification, 100 files, 10 MiB images (HEIC to JPEG, oversized images re-encoded), 80 MiB of images, staging limit from `fileAttachments.maxUploadBytes`; `attachments.createUploadUrl` and the signed POST; files are chips (the last chip deleted drops the file); 32 KiB pastes fold into `pasted-text.txt` (Cmd+Shift+V keeps them inline); send waits for uploads; `attachments` plus image/file records in `context`. Missing: persisting draft attachments across relaunch, "Attach again" rows, inline base64 images for servers without `attachmentUploads`, attachments on queued-message edits |
| Attached file preview panel | comp/files/AttachmentFilePreview.tsx | ⏳ | |
| SnapShot attachment details | comp/chat/SnapShotAttachmentDetails.tsx | ⏳ | |
| Model picker (providers sidebar, search, favorites, multi-select with shift-click) | comp/chat/ProviderModelPicker.tsx, comp/chat/ModelPickerContent.tsx, comp/chat/ModelPickerSidebar.tsx, comp/chat/ModelListRow.tsx | ➖ | `mod+shift+m`; provider keys `mod+shift+up/down`; Missing: shift-click multi-select; Audit 2026-10-11: `ModelPickerView` has search, favorites and provider keys. No shift-click multi-select. |
| Traits picker (effort, speed, thinking, context size) | comp/chat/TraitsPicker.tsx, comp/chat/TraitsSpeed.tsx | 🟡 | `mod+shift+e` |
| Custom models editor | comp/settings/CustomModelEditor.tsx | ➖ | Audit 2026-10-11: Settings can add and remove custom models (`ProvidersSettingsView`). No composer editor. |
| Access / permission mode picker | comp/chat/CompactComposerControlsMenu.tsx, comp/chat/runtimeModeConfig.ts | 🟡 | `mod+shift+a` |
| Compact controls menu (narrow widths) | comp/chat/CompactComposerControlsMenu.tsx, comp/composerFooterLayout.ts | 🟡 | |
| Environment/host selector for new thread | comp/BranchToolbarEnvironmentSelector.tsx | 🟡 | `mod+shift+h`, cycle host unbound. In a Git project the "Run on" group sits in the run context menu |
| Workspace mode selector (current checkout / new worktree / previous worktree) | comp/BranchToolbarEnvModeSelector.tsx, comp/BranchToolbar.tsx (RunContextSelector) | 🟡 | `mod+shift+x`, `mod+shift+l`. The composer is never wider than `@3xl`, so T3 shows RunContextSelector there; the draft sends `worktree`, `existing_worktree` or `root` strategies (sent a real worktree turn on the sandbox). Start from origin does not read the project setting yet (WP7.7) |
| Branch toolbar and branch picker | comp/BranchToolbar.tsx, comp/BranchPicker.tsx, comp/BranchToolbarBranchSelector.tsx | 🟡 | `mod+shift+g`. Search with the sanitized query, paging, create and switch refs, worktree reuse, start from origin. Fidelity: scripts/gen-git-spec.py. Missing: checkout PR row and the composer PR badge (needs `projects.preparePullRequestThread`), the context menu "Copy branch name", label collapse at narrow widths |
| Worktree base branch picker | comp/WorktreeBaseBranchPicker.tsx | ➖ | T3 uses it only in Scheduled Tasks settings (WP7.7); `BranchPickerView` with the origin switch is ready for it |
| Previous worktree item | comp/PreviousWorktreeItemContent.tsx | 🟡 | History glyph, title and the branch as a muted second line |
| Draft hero headline (new thread empty state) | comp/chat/DraftHeroHeadline.tsx, comp/chat/draftHeroTransition.ts | 🟡 | |
| Composer banners stack (clone progress, server update, provider issues) | comp/chat/ComposerBannerStack.tsx, comp/chat/ComposerBanner.tsx, comp/chat/ComposerServerUpdateStatus.tsx | ➖ | Missing: only the environment reconnecting banner exists; Audit 2026-10-11: Only the environment reconnecting banner (`EnvironmentBannerView`). No clone progress, server update or provider issue banners. |
| Composer activity status | comp/chat/ComposerActivityStatus.tsx | 🟡 | "Loading messages..." / "Syncing messages..." with the spinner from the thread store's status, shown after 400 ms and kept 400 ms (`useDelayedStatus`) |
| Composer usage limits chip | comp/chat/ComposerUsageLimits.tsx | ⏳ | The `/usage-limits` banner renders the Limits windows (`LimitWindows`, `ResetCredits` from the usage page); build it with the usage page (WP7.7) |
| Prompt stash (save, restore, menu, badge) `composer.stash` | comp/chat/ComposerStashMenu.tsx, comp/chat/ComposerStashBadge.tsx, web/promptStashStore.ts | 🟡 | Cmd+S stashes (files must be uploaded and keep their reference; images saved under the 1.3 M / 2.7 M char budgets as files), empty composer restores one entry or opens the menu, 20 entries newest first in Application Support, restore checks file uploads first (24 h expiry) and only in their environment, badge pulse, menu keys. Fidelity `composer-attachments`. Missing: expired files as "Attach again" rows |
| Prompt history recall (arrow up/down) | comp/chat/composerPromptHistory.ts | 🟡 | |
| Prompt length validation | comp/chat/ComposerPromptLengthValidation.tsx | 🟡 | |
| Collapse composer on scroll (setting) | comp/chat/composerScrollGesture.ts | ⏳ | |
| Pending terminal contexts | comp/chat/ComposerPendingTerminalContexts.tsx | ⏳ | |
| Composer feedback / transient errors | comp/chat/ComposerFeedback.tsx | 🟡 | |
| Voice input | docs/composer.md | n/a | iPhone only per docs; skip on macOS unless confirmed; Not applicable: Voice input is iPhone only per the official docs. |
| Start in background (`mod+enter` new thread, `mod+alt+enter`) and send-and-new-thread | docs/thread-sidebar.md, docs/keybindings.md | ➖ | Audit 2026-10-11: `ComposerLogic` resolves `composer.sendBackground` and `sendAndNewThread`; `ComposerView` sends in the foreground (ponytail at ComposerView.swift:453). |
| Multi-model fan-out (shift-click models, one thread and worktree each) | docs/thread-sidebar.md | ⏳ | Git project only |
| Composer placeholder text rules | web/composerPlaceholder.ts | 🟡 | |

## Right panels

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Right panel container, tab strip, new tab (+) menu, close (`mod+w`), reopen closed (`mod+shift+t`) | comp/RightPanelTabs.tsx, web/rightPanelStore.ts, web/closedViewStore.ts | ➖ | WP7.6a: `T3Store/RightPanelState.swift` ports the store (surfaces, open, openFile, activate, close, close others, close to the right, close all, toggle, visibility) and the closed tab stack (20, newest first, skips open tabs, restores across threads); per-thread state persisted. Tab strip clipped at `pr-28` and following the active tab, tab context menu, middle click closes, + menu with letters, `mod+t`, "Open a surface" launcher with letters. Kinds drawn: diff, files, file, pull request, browser (WP7.6b). Missing: terminal and device tabs (shown disabled), scroll buttons, maximize state per tab, drafts. Fidelity `files` (tabs, launcher); Audit 2026-10-11: `RightPanelState` store and tab strip. No resize handle, no strip scroll buttons, Terminal and Device launcher entries disabled. |
| Right panel resize handle, sheet mode on narrow windows | comp/preview/RightPanelResizeHandle.tsx, comp/RightPanelSheet.tsx, web/rightPanelLayout.ts | ⏳ | |
| Diff panel (`diff.toggle`): turn selector, file tree, unified/split, wrap, whitespace toggle | comp/DiffPanel.tsx, comp/DiffPanelShell.tsx, web/diffPanelStore.ts | ➖ | Diffs rendered by @pierre/diffs (web worker pool); needs native renderer; Missing: file tree aside (toggle is inert); Audit 2026-10-11: `DiffPanelView` has turn scope, split/unified, wrap, whitespace. File tree aside is inert (ponytail at DiffPanelView.swift:93). |
| Diff file tree with status icons | comp/diffs/DiffFileTree.tsx, comp/diffs/DiffFileStatus.tsx | ⏳ | |
| Diff code view: syntax highlight, collapsed unchanged ranges, folded files | comp/diffs/StyledDiffCodeView.tsx | ➖ | Missing: expanding hidden lines; Audit 2026-10-11: Syntax highlight and "n unmodified lines" row (`DiffRowViews`). Hidden lines cannot be expanded. |
| Diff inline review comments (annotate, submit, add to chat as chip) | comp/diffs/AnnotatableCodeView.tsx, comp/diffs/DiffCommentAnnotation.tsx, web/reviewCommentContext.ts | ⏳ | |
| Diff find (`mod+f`, not configurable) | comp/diffs/codeViewSearch.test.ts, docs/keybindings.md | ⏳ | |
| Diff copy path, open in editor, revert file actions | comp/DiffFilePathCopyButton.tsx, web/diffFileActions.ts | ⏳ | |
| Settings: diff colors, layout, whitespace, default file state | comp/settings/SettingsPanels.tsx | ➖ | See Settings > General and Appearance; Audit 2026-10-11: Layout, wrap and whitespace read from settings (`DiffPanelView`). Diff colors stored only. |
| Files panel (project tree) | comp/files/FileBrowserPanel.tsx, web/pierre-icons.ts | 🟡 | WP7.6a: `Features/Files/FileTreeModel.swift`, `FilesPanelView.swift`: Pierre compact rows (24px, folders first, natural order, flattened single-folder chains, indent guides on hover, ignored entries dimmed), lazy `projects.listEntries` per folder, refresh, expand and collapse all, path search (`projects.searchEntries`, 120 ms, 200, hide non-matches), reveal of the open file, drag a file row into the composer as a mention. Missing: row context menu (open with, copy mention, add to chat), sticky folders, keyboard navigation, git status lane. Fidelity `files` |
| File editor/viewer tab: edit, save, breadcrumbs, line reveal | comp/files/FilePreviewPanel.tsx, comp/files/fileSaveCoordinator.ts, comp/files/FileBreadcrumbs.tsx | 🟡 | WP7.6a: `CodeFileView` (TextKit 2, diff code look, gutter, pierre colors off the main thread, wrap toggle), autosave through `projects.writeFile` with T3's coordinator (500 ms, one write at a time, newest wins, unsaved edits kept per file), truncated reads read-only with the 1 MB notice, breadcrumbs with folder menus, `path:line` reveal and mark, explorer aside (remembered), read errors with the attempted path. Missing: review comments on lines, Open in editor picker, re-read on workspace mutations (re-read on tab activation instead) |
| File preview modes: source, Markdown rendered, CSV/TSV table, image, audio | comp/files/FileMarkdownPreview.tsx, comp/files/DelimitedTablePreview.tsx, comp/files/ReadOnlySourcePreview.tsx | 🟡 | WP7.6a: rendered Markdown (MarkdownView), CSV/TSV table (`parseDelimitedPreview`, 100 rows, 30 columns), image, audio and video (AVKit) from `assets.createUrl`, render preferences remembered like T3. Missing: task list toggles in rendered Markdown, media actions menu |
| File preview: HTML and PDF rendered | comp/files/BrowserDocumentFrame.tsx, docs/composer.md | 🟡 | WP7.6a: PDF in PDFKit; HTML in a WKWebView with a non-persistent store, created while its tab shows and torn down when hidden or closed (WebContent and Networking exit at once, the GPU process within a minute). Missing: "Open file in preview browser" (WP7.6b) |
| File comments (review annotations in files) | comp/files/fileCommentAnnotations.ts | ⏳ | |
| Go to file picker (`mod+p`) | comp/files/ProjectFilePicker.tsx | 🟡 | WP7.6a: the palette in "files" mode: `projects.searchEntries` (kind file, 200, 120 ms; empty query lists recent files), server order kept, fuzzy highlights (`getProjectFilePickerMatches`), file icons, Enter opens the file tab, Escape back to commands, "Open a project to search its files." |
| Search project contents (`mod+shift+f`) | comp/search/ProjectContentSearchDialog.tsx, comp/search/HighlightedSearchLine.tsx | 🟡 | WP7.6b: the palette in "content" mode (`ContentSearchView`): `projects.searchContents` (120 ms, 500 matches, whitespace kept), Aa/ab/.* toggles in the input, status line, groups by file with count, mono rows with line numbers, pierre token colors and `bg-primary/25` marks, windows of 100 growing on scroll, arrows wrap, Enter opens the file tab at the line. Fidelity `browser` (search). Missing: sticky group headers, the ab underline, the file-access check |
| Browser/preview panel: URL bar, tabs, back/forward/reload, zoom, favicon, incognito | comp/preview/PreviewPanel.tsx, comp/preview/PreviewView.tsx, comp/preview/PreviewChromeRow.tsx, comp/preview/PreviewMoreMenu.tsx | ➖ | WP7.6b: server tabs only (previewRuntime.ts:20-29). Chrome row (back, forward, refresh with spin and the 5.3 s loading bar, address bar with select-all on focus and DuckDuckGo search, Open in system browser on hover, float toggle, more menu: Hard reload, Appearance, zoom row, Clear cookies/cache via `preview.adjust`), tabs from `preview.list` + `subscribePreviewEvents` (`reconcileBrowserSurfaces`), titles, Google favicons for public hosts, close sends `preview.close`, Mod+Shift+T reopens at the page. Viewer: JPEG frames decoded off the main thread (newest only), control bar (Take/Release control), mouse, wheel, keys, paste, copy back, dialogs, file chooser upload, downloads, popups, host setup and refused states. Fidelity `browser` (chrome). Missing: device toolbar, profiles (no `preview.reportProfiles`: it would overwrite the desktop app's list), DevTools and separate window (Electron only), IME; Audit 2026-10-11: Server tabs only, chrome row, loading bar, address bar. No desktop tabs, zoom UI beyond shortcuts, incognito. |
| Browser: empty state with discovered local servers and recent URLs | comp/preview/PreviewEmptyState.tsx, comp/preview/PreviewLocalServerCard.tsx, comp/preview/PreviewRecentUrlCard.tsx, web/portDiscoveryState.ts | 🟡 | WP7.6b: "No preview yet" or Recently used (per project, 50, 8 shown) and Local servers from `subscribeDiscoveredLocalServers` (only while the empty state shows, configured script URLs first). Fidelity `browser` (empty, lists) |
| Browser: unreachable page state | comp/preview/PreviewUnreachable.tsx | 🟡 | WP7.6b: Chromium's page in T3's styles with Details and Reload, and the file-not-shown variant with Download. Fidelity `browser` (unreachable) |
| Browser: pick element and annotate (adds chip to composer) | desk/preview/PickPreload.ts, desk/preview/Annotation.css, desk/preview/PickedElementPayload.ts | n/a | Not offered for streamed server tabs in T3 either (desktop `<webview>` only); CandyWrapper has no desktop tabs; Not applicable: T3 itself does not offer this for streamed server tabs; CandyWrapper has no desktop tabs. |
| Browser: agent control via CDP (click, type, screenshot, recording) | desk/preview/CdpRelay.ts, desk/preview/BrowserSession.ts, desk/preview/RecordingCursor.ts | 🟡 | WP7.6b: agents drive the server's own headless Chrome; this app views and steers those tabs (research note: no client can host). Missing: screenshot and recording buttons (desktop tabs only in T3); Built (audit 2026-10-11): Agents drive the server browser; the app views and steers (`ServerBrowserView`). Screenshot and recording buttons are desktop-tab only in T3. |
| Browser: floating mini player (PiP) | comp/preview/ThreadPreviewMiniPlayer.tsx, web/previewMiniPlayerStore.ts, desk/preview-pip-preload.ts | ➖ | WP7.6b: `BrowserMiniPlayerView` over the chat column, 320 box at the page's aspect, control bar at the bottom, dot handle with Open in right panel and Close, drag to move; opens for an agent's revealed tab and from the chrome row. Missing: resize handles, composer and details-card obstacles, system Picture in Picture; Audit 2026-10-11: `BrowserMiniPlayerView`. Missing resize handles. |
| Browser: remote-environment browser (server headless Chromium streamed) | docs/remote-access.md, `/api/preview-stream` | 🟡 | WP7.6b: every tab streams over `/api/preview-stream/ws` with a fresh `wsTicket` per connect, T3's backoff, 4404/4503/refusal handling, frame cap that grows with the panel |
| Browser: import sessions from other browsers | docs/browser-import.md, comp/settings/BrowserImportWizard.tsx, desk/preview/BrowserImport | n/a | needs webview: ask user; Not applicable: Imports cookies into Electron desktop tabs. CandyWrapper has no desktop tabs. |
| Browser: zoom shortcuts, refresh, focus URL | web/keybindings.ts (`preview.*`) | 🟡 | WP7.6b: `preview.refresh`, `preview.focusUrl`, `preview.zoomIn/Out/resetZoom` with `previewFocus` (focus inside the browser panel), `preview.toggle` |
| Device panel (iOS Simulator / Android Emulator stream, tabs, rename) | comp/device/DevicePanel.tsx, comp/device/DeviceWorkspace.tsx, comp/device/DeviceStreamView.tsx | ⏳ | Video stream via /api/device-hub; verify transport before deciding on webview |
| Device setup flow (hub install, platform check, agent access) | comp/device/DeviceSetup.tsx, comp/device/DeviceHostAvailability.tsx | ⏳ | |
| Device controls rail (home, back, recents, rotate, power, fold, 3D view) | comp/device/DeviceControlsRail.tsx, comp/device/DeviceAndroidFoldControls.tsx, comp/device/DeviceDuoControls.tsx | ⏳ | 3D view uses WebGL (likely needs webview or SceneKit): ask user |
| Device tools drawer (appearance, text size, location, permissions, push) | comp/device/DeviceToolsPanel.tsx, comp/device/DeviceToolVersions.tsx | ⏳ | |
| Device touch input and floating device window | comp/device/useDeviceControls.ts, comp/device/phoneTrackpad.ts | ⏳ | |
| Pull request tab in right panel | comp/pullRequest/PullRequestDetailPanel.tsx | 🟡 | WP7.5b: `pull-request:` surfaces with T3's ids, state-toned tab glyph, + menu and launcher "Pull request" and "Linked pull requests". See Git and pull requests |
| Terminal tab in right panel | comp/ThreadTerminalDrawer.tsx | ⏳ | See Terminal |

## Git and pull requests

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Git actions menu (commit, push, pull, create PR, publish, init repo) | comp/GitActionsControl.tsx, comp/GitActionsControl.logic.ts | 🟡 | Panel form in the details card: quick action, menu with disabled reasons and notes, progress with hook output and elapsed time, inline success for 10 s, error toasts, the default-ref confirmation. Commit, push, pull tested on a sandbox repo with a local bare remote. Missing: the toolbar and menu presentations T3 no longer mounts, toast CTAs |
| Commit dialog with generated message and file selection | comp/GitActionsControl.tsx | 🟡 | AI text generation via configured writer model (server side when the message is blank). Fidelity in gen-git-spec.py |
| Publish repository (public/private, provider choice) | comp/GitActionsControl.tsx | ➖ | Providers: GitHub, GitLab, Bitbucket, Azure DevOps, Forgejo/Gitea. Three-step wizard built; never published. Missing: wizard header layout and tint, Bitbucket and Azure glyphs, opening Source Control settings, no fidelity spec; Audit 2026-10-11: `PublishRepositoryDialog` three-step wizard, never run against a host. Missing header layout/tint, two glyphs, Source Control link. |
| Create pull request / change request | comp/GitActionsControl.tsx, comp/pullRequest/PullRequestComposer.tsx | ➖ | The menu and quick action run `create_pr` and the stacked forms through `git.runStackedAction` (payload unit tested, never run against a real host). PullRequestComposer is the PR page's form (WP7.5b); Audit 2026-10-11: `GitActionsLogic` runs `create_pr` through `git.runStackedAction`; `PullRequestComposerView`. Never run against a real host. |
| PR stack actions (GitHub stacks) | comp/pullRequest/PullRequestStackMenu.tsx, comp/pullRequest/PullRequestStackLayers.tsx, comp/pullRequest/PullRequestStackHeader.tsx | ➖ | WP7.5c: `pullRequests.stack` after the detail; header button `⧉ p/n` (warning when stale) with the menu (Stack #n, notice, Retry, layers top first with state glyph and check, `↳ base`, Merge stack (k), Rebase stack, the ready note), "Merge stack" beside it, the confirmation listing the layers, `runAction` with `stackNumber`/`expectedStackHeads` (payload unit tested, never run); a stack holds back the single merge (`allowsSinglePullRequestMerge`); list rows' `n/m` opens the lazy stack menu and a layer opens it. Missing: saved stack fallback from thread links (`savedPullRequestStack`); Audit 2026-10-11: Stack header, menu and layers built (`PullRequestStackViews`). Never run against a real host. |
| Pull requests page: list, filters, grouping, speed actions (Shift) | web/routes/_chat.pull-requests.tsx, comp/pullRequest/PullRequestListRow.tsx, comp/pullRequest/PullRequestListFilters.tsx, comp/pullRequest/PullRequestSpeedActions.tsx | 🟡 | WP7.5b: search with qualifiers (250 ms), Sort (7), Filters menu, provider menu, refresh with invalidate, Authored and Review requested partitions, overrides, `listStats`, Shift actions, Mod+F, 60 s live refresh, the page's own right panel. WP7.5c: cursored "Load more" (`nextCursors` per environment, regrown environments read again at a larger page), the checks popover and stack menu on rows. Fidelity `pull-requests` rows. Missing: condensed scrolled page header, the reload snapshot, server filter, drag-select Close |
| PR list empty/unavailable states | comp/pullRequest/PullRequestListEmptyState.tsx, comp/pullRequest/PullRequestsUnavailableState.tsx, comp/pullRequest/PullRequestActivityUnavailableState.tsx | ✅ | Ghost rows, branch mark, no projects, search empty, filtered empty, unavailable with Retry; checked on screen against the sandbox (empty list, provider-unsupported detail) |
| PR detail: Summary tab | comp/pullRequest/PullRequestSummaryTab.tsx, comp/pullRequest/PullRequestDetailLayout.tsx | 🟡 | Header, tab bar, Reviewers, Labels, Description, Checks, Comments (WP7.5b). WP7.5c: title edit (pencil on hover, input, Enter/Escape, `pullRequests.update`), description edit (Write/Preview editor, empty clears), comment edit for the reader's own (`updateComment`), reactions on comments, reviewer and label pickers (`reviewerCandidates`/`labelCandidates` on open, toggle with `requestReviewers`/`setLabels`, disabled with the reason), the condensed header once scrolled past the fold (per tab, with the scroll refund). Missing: comment paging and bot groups, pencils always visible on comments and the description (T3 reveals them on hover) |
| PR detail: Timeline tab (comments, reviews, events) | comp/pullRequest/PullRequestTimelineTab.tsx, comp/pullRequest/PullRequestCommentBody.tsx | 🟡 | Rail, lifecycle, commits, verdict rows, folded conversations, order toggle. Missing: reactions and comment editing on timeline rows (built on Summary and in conversations) |
| PR detail: Code tab (diff, per-commit scope, viewed marks, review comments) | comp/pullRequest/PullRequestCodeTab.tsx, comp/pullRequest/pullRequestFilesViewed.logic.ts, comp/pullRequest/PullRequestReviewAnnotation.tsx | 🟡 | WP7.5b diff, commit scope, viewed marks. WP7.5c: cursored slices (`nextCursor`, next slice near the end, "Loading more files...", Retry, `n files+`), review conversations under their lines (`DiffListView.annotations`, `ReviewThreadCard`: resolve, reply, load more, edit own, reactions; resolved folded), conversations off the loaded diff folded above the code, a click in a line's gutter starts a comment ("Add to review") that becomes a pending card. Missing: drag selection of line ranges, file tree, "Add to agent", Fix in a thread |
| PR checks popover | comp/pullRequest/PullRequestChecksPopover.tsx | ✅ | WP7.5c: `PullRequestChecksPopoverView`: headline, summary, attention and running checks first, "Show all"/"Show less", Details links; on the detail header's checks glyph (checks in hand) and on list rows (reads the detail on open). Fidelity `pull-request-writes` checks-popover |
| PR edit title/body, labels, reviewers, reactions | comp/pullRequest/PullRequestEditButton.tsx, comp/pullRequest/PullRequestLabelPicker.tsx, comp/pullRequest/PullRequestReviewerPicker.tsx, comp/pullRequest/PullRequestReactions.tsx | 🟡 | WP7.5c: all four built and wired; payloads unit tested, never run against a real repository. Missing: hover-only pencils |
| PR comment form, review form (approve, request changes, comment) | comp/pullRequest/PullRequestCommentForm.tsx, comp/pullRequest/PullRequestReviewForm.tsx | 🟡 | WP7.5c: `PullRequestComposerView` as T3 draws it: Comment/Review toggle (pending count), discard pending, close; comment box with Close or Reopen with comment and Comment; review summary kept per pull request (`PullRequestReviewStore`), verdict select, Submit review sending the pending line comments. Fidelity `pull-request-writes` review-form. Never sent against a real repository |
| PR merge (merge, squash, rebase, auto-merge), checkout, revert, close/reopen | comp/pullRequest/PullRequestDetailPanel.tsx, docs/source-control.md | 🟡 | Primary control, confirmations, ⋯ menu (WP7.5b); stack merge and rebase (WP7.5c). Never run against a real repository. Missing: checkout into a worktree or this repository from the page's Check out menu, base freshness update, project default merge method |
| Link pull request to thread dialog, unlink, candidate picker | comp/pullRequest/LinkPullRequestDialog.tsx, comp/pullRequest/PullRequestCandidatePicker.tsx, comp/pullRequest/PullRequestThreadLinks.tsx | 🟡 | Dialog with `resolveLinkPullRequestInput`, `thread.pull-request.link`/`unlink` or the legacy `thread.meta.update`; detail ⋯ "Link to this thread"/"Unlink from this thread". Linked on screen in the sandbox. Fidelity `pull-requests` link-dialog. Missing: candidate picker, thread picker from the page, linked-threads count |
| Create PR thread (open PR in new thread/worktree) | comp/PullRequestThreadDialog.tsx | 🟡 | WP7.5c: branch picker "Checkout pull request" row on a local draft, `PullRequestThreadDialog` (450 ms `git.resolvePullRequest`, card, error, Local and Worktree), `git.preparePullRequestThread` then the draft takes the branch and worktree. Checked on screen up to the resolve error (no GitHub host in the sandbox). Missing: scope checks (assumed granted), provider icon in the row and title |
| Copy PR URL and number (`mod+shift+c`, `mod+shift+k`) | web/pullRequestReference.ts | ✅ | `resolveThreadReferenceCopyTarget`: the panel's PR, the current link, else the thread ID; `pullRequest.copyNumber` with a PR tab active |
| Worktrees: create, reuse, list, cleanup, handoff | comp/BranchToolbar.tsx, web/worktreeCleanup.ts, contracts/rpc.ts (`git.*`) | ➖ | Audit 2026-10-11: New worktree mode on drafts (`BranchToolbarLogic.EnvMode`), server creates it. No list, cleanup UI or handoff. |
| Clone project with progress toast and retry | comp/ProjectCloneToastCoordinator.tsx, comp/CommandPalette.tsx | ⏳ | |
| Source control provider cards (auth status, rescan) | comp/settings/SourceControlSettings.tsx | 🟡 | See Settings; Built (audit 2026-10-11): `SourceControlSettingsView` has provider cards with auth status and rescan. Stale mark. |

## Terminal

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Terminal drawer (`terminal.toggle`, `mod+j`), resize, height persistence | comp/ThreadTerminalDrawer.tsx, web/terminalUiStateStore.ts | 🟡 | WP7.4: drawer under the chat column, header toggle and `mod+j`, 6pt drag handle (180 to 75% of the window), per-thread open/height/terminals in UserDefaults, action cluster with tooltips, empty state, close confirm. Missing: open/close animation, right-panel terminal tab (WP7.6), drawer on draft threads |
| Terminal tabs and split groups (max 4 per group), horizontal/vertical splits | comp/ThreadTerminalDrawer.tsx, web/types.ts | ➖ | One terminal shows at a time. New (`terminal.new`, `+`) opens the next `term-N` and shows it; the split buttons do the same; the terminal list aside and split grids are not drawn; Audit 2026-10-11: `TerminalDrawerView` shows one terminal; split buttons open the next `term-N` (ponytail at TerminalController.swift:194). No list aside or split grid. | `terminal.split`, `terminal.splitVertical`, `terminal.new`, `terminal.close` |
| Terminal renderer (Ghostty-based) with theme colors, fonts, selection | web/terminal/ghostty/ | 🟡 | SwiftTerm 1.19.0 (vendored, Packages/SwiftTerm), CoreText drawing: SF Mono 12, 16pt cells, 4pt padding, libghostty's default palette, T3's cursor and selection colors per appearance, 10,000 rows scrollback, blinking block cursor, no bell. Missing: font settings, bundled Symbols Nerd Font, bottom-anchored grid |
| Terminal links (URLs, file paths) open in preview/editor | web/terminal-links.ts, comp/preview/openTerminalLinkInPreview.ts | 🟡 | Plain click on a detected URL or OSC 8 link; URLs open in the browser, paths with the default app. Missing: preview panel and preferred editor routing | Opening URL in preview needs webview: ask user |
| Add terminal selection to chat as context chip | comp/ThreadTerminalDrawer.tsx, comp/chat/TerminalContextInlineChip.tsx | ⏳ | |
| Terminal context menu (copy, paste, clear, add to chat) | comp/ThreadTerminalDrawer.tsx | 🟡 | Copy, Paste, Select all, Jump to latest; Cmd+C/V/A; T3's Cmd/Option arrows, Cmd+Backspace, Cmd+K and Ctrl+L. Missing: Add to chat and the post-selection popup | |
| Terminal history retained server-side, replay on reconnect | docs/terminal.md, D-server-features.md section 1 | ✅ | `terminal.attach` snapshot replays history on open, reopen and reconnect (replies muted during replay) | |
| Project scripts / actions run in terminal (script. commands, `runOnSettle`) | comp/ProjectScriptsControl.tsx, comp/projectScriptEditor.tsx, web/projectScripts.ts | ⏳ | `script.<id>.run` keybindings |
| Provider auth terminal (sign-in helper) | comp/settings/ProviderAuthTerminal.tsx | ⏳ | |
| Idle terminals close on settle | docs/thread-sidebar.md | n/a | Server side; Not applicable: Server side; the client does nothing. |

## Settings

Route files are in `web/routes/settings.*.tsx`. Sidebar order: Project, General, Appearance, Keybindings, SnapShots, Providers, Integrations, Scheduled Tasks, Source Control, Storage, Connections, Archive. Plus Diagnostics and Open source licenses reached from General > About. Settings search (`comp/settings/settingsSearch.ts`) indexes every row below and jumps to it. A scope selector (environment or All environments) applies to scoped settings (`SettingsScopeContext.tsx`, `ScopedSwitch.tsx`, `SettingInheritance.tsx`).

### Settings shell

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Settings sidebar nav with search box and results | comp/settings/SettingsSidebarNav.tsx, comp/settings/settingsSearch.ts | 🟡 | WP7.7a: T3's catalog (generated), ranking, arrows/Return/Escape, `/` to focus, jump with pulse. WP7.7b: every page but Scheduled Tasks opens; Project shows only with a project picked. Missing: the scope notice for a search hit outside its owning scope |
| Settings breadcrumb, group and row layout, scope notice | comp/settings/SettingsBreadcrumb.tsx, comp/settings/SettingsGroup.tsx, comp/settings/SettingsScopeNotice.tsx | 🟡 | WP7.7a: reset arrows, inheritance indicator with chain popover, inert rows, scope boundary text, Restore device defaults. Missing: SettingsScopeNotice; Built (audit 2026-10-11): `SettingsScopeNoticeView` in `ScopedSettingsPage.swift`, used by `ProjectSettingsView`/`StorageSettingsView`. Stale mark. |
| Environment scope picker (All environments, per environment, mixed values) | comp/settings/SettingsScopeContext.tsx, comp/settings/settingsScope.ts | 🟡 | WP7.7a: sentence, environment axis, mixed switches and selects. WP7.7b: project axis (sidebar groups by name), project targets with resolved overrides, writes into `projectSettingsOverrides`, reset to inherited, environment-wide rows inert, chain popover with the Project layer, single-environment pages (Providers, Diagnostics). Missing: checkout axis, t3.json tier, "Reset all" for overriding projects at an environment scope, project favicons in the picker |

### Settings > Project

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Project list and per-project settings page | web/routes/settings.projects.tsx, web/routes/projects.$projectKey.tsx, comp/settings/ProjectsSettings.tsx, comp/settings/ProjectSettingsPanel.tsx | 🟡 | WP7.7b: `ProjectSettingsView`; picked through the scope sentence; no project shows T3's scope notice with one button per project. Fidelity `settings-pages2` |
| Project overview (name, path, repo identity, icon, favicon) | comp/settings/ProjectSettingsPanel.tsx, comp/settings/ProjectFaviconPickerDialog.tsx | ➖ | WP7.7b: rename across members (`project.update`), icon description and reset to Automatic, permission note. Missing: icon and image file pickers (buttons disabled); Audit 2026-10-11: Rename and reset icon (`ProjectSettingsView`). Icon and image file pickers disabled. |
| Default model, workspace mode, permissions overrides | comp/settings/ProjectDefaultsSettings.tsx | 🟡 | WP7.7b: Model and Workspace on Project; every General row overrides at a project scope. No traits picker |
| Automatically pull (keep default branch current) | comp/settings/ProjectDefaultsSettings.tsx, docs/project-settings.md | 🟡 | WP7.7b: Source Control > Repositories; the server pulls |
| Agent browser access override | comp/settings/ProjectDefaultsSettings.tsx | 🟡 | WP7.7b: Integrations; server-side |
| Actions (scripts): add, edit, run on settle, keybinding | comp/settings/ProjectActionsSettings.tsx, comp/settings/ProjectActionsList.tsx, comp/projectScriptEditor.tsx | ➖ | WP7.7b: list, Add/Edit Action dialog (icon, shortcut recorder, command, preview URL, roles), delete with confirm, reset to the environment list, shortcuts upserted and removed. Stored only: running them (`script.<id>.run`). Missing: t3.json import, invalid t3.json row. Keeps a shortcut on an edit that leaves it alone (T3 drops it); Audit 2026-10-11: Action list, editor and shortcuts (`ProjectActionEditor`, `ProjectActionsLogic`). Running is missing, t3.json import missing. |
| Worktree location and branch naming | comp/settings/BranchNamingSettings.tsx, docs/project-settings.md | 🟡 | WP7.7b: Storage > Worktree location, Source Control > Worktree branch naming (static prefix, semantic, custom instructions) |
| Webhook automations | docs/project-settings.md | ⏳ | Scheduled Tasks, WP7.7c |
| Project removal | comp/settings/ProjectSettingsPanel.tsx | 🟡 | WP7.7b: T3's confirm lines, `project.delete {force}` per member, back to the thread view; Checkouts section for groups |

### Settings > General

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Update track (stable / nightly) and update status/download/install | comp/settings/SettingsPanels.tsx (line ~453), desk/updates/updateChannels.ts | M9 | WP7.7a: Version and Update track rows shown, actions unwired until M9; Milestone 9: Rows shown without actions (`GeneralSettingsView`). Needs the updater. |
| Thread notifications (Off, Notifications, Sound only, Notifications with sound) | comp/settings/NotificationSettings.tsx, web/threadNotifications.ts | ➖ | WP7.7a: stored (client); alerts come with WP7.8; Audit 2026-10-11: Mode stored; no alerts. Delivery is the notifications package. |
| In-app notifications toggle | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: stored; toasts come with WP7.8; Audit 2026-10-11: Stored; no in-app toasts for thread events. |
| Time format (system, 12h, 24h) | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: timeline timestamps follow it live |
| Response streaming mode | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: server setting, the server applies it |
| Hide whitespace changes; Default diff file state; Diff layout | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: diff layout follows (toolbar writes it back); whitespace, wrap and collapsed state seed new diffs |
| Proactive panels | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: stored; auto-open not built; Audit 2026-10-11: Stored; auto-open not built. |
| Show skills in slash menu | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: wired into the / menu |
| Rich text composer; Collapse composer on scroll | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: stored; no rich text or resting composer yet; Audit 2026-10-11: Stored. Rich text composer and collapse on scroll not built (rows 145, 177). |
| Send shortcut; Follow-up behavior (Queue/Steer) | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: rows drive the composer |
| Provider update checks | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: server setting |
| Continue threads after restarts | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: server setting, gated on threadRestartContinuation |
| Background activity profile and advanced intervals (Git fetch, provider health, host power) | comp/settings/SettingsPanels.tsx (lines ~930-1110) | 🟡 | WP7.7a: profile select, Advanced dialog (one environment), resolve and normalize ported |
| Organization: Project grouping, Project order | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: order drives the scope popup; grouping stored only; Audit 2026-10-11: Order works, grouping stored only. |
| Organization: Auto-resume limited threads; Snooze limited threads | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: server settings |
| Organization: Working section (beta) | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: stored; shelf not built; Audit 2026-10-11: Stored; shelf not built (row 40). |
| Organization: Auto-settle merged threads; Auto-settle inactive threads; Days of inactivity | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: server settings, shown with threadAutoSettlement |
| Projects and threads: New threads defaults, Submodules, Start from origin, Add project starts in | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: New threads rows, Start from origin (seeds worktree drafts), Add project starts in. No traits picker; Audit 2026-10-11: Rows wired (`GeneralSettingsView`, `ComposerController`). Traits picker missing. |
| Confirmations: Unpin, Archive, Delete, Quit shortcut (Hold, Direct, Double press) | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: stored; prompts and the quit hold come with WP7.8; Audit 2026-10-11: Stored; prompts for unpin, archive, delete and the quit hold not built. |
| Text generation model | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: model picker writes the setting; no traits picker; Audit 2026-10-11: Model picker writes the setting; traits picker missing. |
| `t3` CLI command install row | comp/settings/CliCommandSettingsRow.tsx | M9 | Skipped: CandyWrapper installs no CLI; Milestone 9: CLI install row; CandyWrapper installs no CLI (skipped by design). |
| About: version, privacy policy, telemetry note, Diagnostics link, Open source licenses | comp/settings/SettingsPanels.tsx, comp/settings/OpenSourceLicenses.tsx, docs/telemetry.md | ➖ | WP7.7a: version, privacy policy. WP7.7b: View diagnostics opens Diagnostics. Missing: the licenses page; Audit 2026-10-11: Version and privacy policy built. Licenses page missing (ponytail at GeneralSettingsView.swift:384). |
| Legacy toggles: Plan mode, Context window indicator, Sidebar | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: folded section; plan mode wired, the other two stored; Audit 2026-10-11: Plan mode wired; context window indicator and sidebar toggle stored only. |
| Panel for "Reset to defaults" / restore | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7a: Restore device defaults with T3's confirm list |

### Settings > Appearance

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Color scheme (System, Light, Dark) | comp/settings/ThemeSettings.tsx | 🟡 | WP7.7a: tiles with T3's wireframes, wired to the appearance mode |
| Theme gallery with previews, separate light and dark themes | comp/settings/ThemeSettings.tsx, comp/settings/ThemePreviewCircles.tsx, comp/settings/ThemeWireframe.tsx | ⏳ | Built-in theme palettes in web/themePalette.ts |
| Theme search (OpenVSX) and VS Code theme import | comp/settings/ThemeSearchSection.tsx, web/openVsxThemes.ts, web/vscodeThemeImport.ts, comp/settings/ThemeImportDialog.tsx | ⏳ | Network feature; palette JSON only |
| Theme editor (pick area, color picker, advanced colors, export JSON) | comp/settings/ThemeEditorPanel.tsx, comp/settings/ThemeEditorHost.tsx, comp/settings/ThemeColorPicker.tsx, comp/settings/themeInspector.ts | ⏳ | `themeEditor.toggle` |
| Environment-published themes (Duplicate) | docs/appearance.md | ⏳ | |
| Contrast; Glass opacity | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: sliders store; no visual effect yet; Audit 2026-10-11: Sliders store; no effect. |
| Diff colors; Chat width; Composer context | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: stored; behaviors not built; Audit 2026-10-11: Diff colors, chat width and composer context are stored; no behavior. |
| Environment identification (color/label per env) | comp/settings/SettingsPanels.tsx | ➖ | WP7.7a: stored; Audit 2026-10-11: Stored; the sidebar and chrome do not draw environment colors or labels. |
| Panel animations slider 0-400 ms | comp/settings/SettingsPanels.tsx, comp/settings/PanelAnimationsPreview.tsx | ➖ | WP7.7a: slider stores; no preview, panels don't animate; Audit 2026-10-11: Slider stores; nothing animates by it. |
| Fonts: Interface, Prompt, Code, Terminal; font smoothing; word wrap; advanced typography | comp/settings/FontFamilyPicker.tsx, comp/settings/SettingsFontPreviews.tsx, web/appearanceFonts.ts | ➖ | WP7.7a: simple and advanced rows store family and size; word wrap seeds diffs and files. No previews or font picker; Audit 2026-10-11: Family and size stored (ponytail at AppearanceSettingsView.swift:140); text styles ignore them. |

### Settings > Keybindings

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Command list with search, current binding, default, conflicts | comp/settings/KeybindingsSettings.tsx, comp/settings/KeybindingsSettings.logic.ts | 🟡 | WP7.7a: groups, search, Mod+F, source badges, conflicts |
| Record new shortcut, remove, reset, add when-clause | comp/settings/KeybindingsSettings.tsx | 🟡 | WP7.7a: recorder, Save, Reset to default, Remove, Add keybinding, When editor (text; no visual node editor) |
| Open keybindings.json; config warnings and update toasts | comp/KeybindingsConfigWarning.tsx, comp/KeybindingsUpdateToast.logic.ts | ➖ | WP7.7a: opens the local file; no config warnings or update toasts; Audit 2026-10-11: Opens the file. No config warnings or update toasts. |

### Settings > SnapShots

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Enable toggle and setup dialog (screen recording, accessibility, shortcut) | comp/settings/SnapShotSettings.tsx, comp/settings/SnapShotSetupDialog.tsx, docs/snap-shot.md | ➖ | WP7.7b: the page (no scope sentence) with the enable switch, stored. Missing: capture, permissions, setup dialog (WP7.8); Audit 2026-10-11: Page and switch stored. No capture, permissions or setup dialog. |
| Include app text; Capture shortcut recorder; sound; flash; animations | comp/settings/SnapShotSettings.tsx, comp/settings/CaptureShortcutConfig.tsx | ➖ | WP7.7b: rows store the client settings; the shortcut shows read-only; Audit 2026-10-11: Rows store values; shortcut recorder read-only. |

### Settings > Providers

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Provider instance cards (Claude, Codex, Cursor, OpenCode, Pi, Muse, Antigravity, Grok, ACP agents) | comp/settings/ProviderSettingsPanel.tsx, comp/settings/ProviderInstanceCard.tsx, docs/providers-*.md | 🟡 | WP7.7b: one environment at a time; list (status, version, enable) beside the editor (display name, Runtime, Models), reset or delete instances through `providerInstanceMutation`. Fidelity `settings-pages2` |
| Add provider instance wizard (driver choice, ACP registry search, auth step) | comp/settings/AddProviderInstanceDialog.tsx, comp/settings/AcpRegistrySearchStep.tsx, comp/settings/ProviderWizardAuthenticationStep.tsx | ⏳ | WP7.7b: both entry points drawn disabled |
| Provider status (installed, version, auth, update available) and Update now | comp/settings/providerStatus.ts, comp/ProviderUpdatesAction.tsx | ➖ | WP7.7b: summaries, version labels, refresh with "Checked …". Missing: version advisory popover and Update now; Audit 2026-10-11: Summaries, versions and refresh. No advisory popover or Update now. |
| Provider config form (binary path, home dir, env vars with redaction, args) | comp/settings/ProviderSettingsForm.tsx, comp/settings/RedactedSensitiveText.tsx | ➖ | WP7.7b: text fields per driver (Codex, Claude, Grok, Muse, Pi, OpenCode). Missing: environment variables editor, Antigravity and ACP fields, accent color; Audit 2026-10-11: Text fields per driver. No env var editor, Antigravity or ACP fields, accent color. |
| Provider sign-in terminal and auth callback | comp/settings/ProviderAuthTerminal.tsx, comp/settings/ProviderAuthenticationSection.tsx, comp/settings/ProviderAuthCallbackCoordinator.tsx | ⏳ | OAuth callback arrives as a deep link |
| Models list, custom models, accent color | comp/settings/ProviderModelsSection.tsx, comp/settings/ProviderAccentColorPicker.tsx | ➖ | WP7.7b: grouped list, favorites (wired to the model picker), filter, move, hide, Disable all, add and remove custom models with T3's validation. Stored only: hidden models and order (the picker doesn't read them). Missing: custom model editor, accent color; Audit 2026-10-11: Grouped list, favorites, custom models. Hidden models and order stored only; no custom model editor, accent color. |
| Codex setup, add Codex account, ChatGPT account/sharing/usage | comp/settings/CodexSetupSection.tsx, comp/settings/AddCodexAccountDialog.tsx, comp/settings/ChatGptConnectionButton.tsx, comp/settings/ChatGptAccountPicker.tsx | ⏳ | |
| ACP session management section | comp/settings/AcpSessionManagementSection.tsx | ⏳ | |
| Usage providers (incl. Cursor account usage via Keychain) | comp/settings/UsageProviderSettings.tsx | ⏳ | |
| Health check interval | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7b: Providers > Advanced, written to that environment |
| Provider update notifications (launch and primary) | comp/ProviderUpdateLaunchNotification.tsx, comp/ProviderUpdatePrimaryNotification.tsx | ⏳ | |

### Settings > Integrations

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Devices: device hub toggle, agent device access, simulator support, device hosts (SSH) | comp/settings/IntegrationsSettings.tsx, comp/settings/DeviceHostsSettings.tsx, comp/settings/DeviceHostEditor.tsx | ➖ | WP7.7b: hub and agent access rows show the values; agent access overrides at a project scope. Missing: `device.configure`, simulator status, device hosts; Audit 2026-10-11: Hub and agent access rows show values. Missing `device.configure`, simulator status, device hosts. |
| Browser: profiles, default profile, viewport, zoom, appearance | comp/settings/IntegrationsSettings.tsx | ➖ | WP7.7b: agent browser access (server); viewport (Fill or Responsive), zoom and appearance store. Missing: profiles, presets and sizes; Audit 2026-10-11: Viewport, zoom, appearance store. Profiles and presets missing. |
| Browser: recording frame rate, show key presses, show mouse presses | comp/settings/IntegrationsSettings.tsx | ➖ | WP7.7b: stored; the browser reads them with WP7.6b; Audit 2026-10-11: Stored; the browser does not read them. |
| Browser: Open links in, Auto-show floating preview | comp/settings/IntegrationsSettings.tsx | ➖ | WP7.7b: stored; Audit 2026-10-11: Stored; Open links in and Auto-show floating preview not honoured. |
| MCP / outside agents (listed under Connections) | docs/outside-agents.md | ➖ | See Remote environments; Audit 2026-10-11: Copy MCP URL only (see row 407). |

### Settings > Scheduled Tasks

See the "Scheduled tasks" section.

### Settings > Source Control

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Server environment selector and Rescan | comp/settings/SourceControlSettings.tsx | 🟡 | WP7.7b: `server.discoverSourceControl` on the representative environment, Rescan, empty state |
| Provider rows: GitHub, GitLab, Bitbucket, Azure DevOps, Forgejo/Gitea (auth state) | comp/settings/SourceControlSettings.tsx | 🟡 | WP7.7b: marks, status dots, badges, T3's summaries. Bitbucket, Azure and Jujutsu glyphs missing (dot only). Fidelity `settings-pages2` |
| GitHub accounts and token; per-host routing | comp/settings/GitHubAccountSettings.tsx, comp/settings/GitHubTokenSettings.tsx, comp/settings/GitHubRoutingSettings.tsx | ➖ | WP7.7b: token per host (write-only, Save and Remove). Missing: accounts and routing (need `gh`); Audit 2026-10-11: Token per host. Accounts and routing need `gh`. |
| Bitbucket credentials | comp/settings/BitbucketCredentialsSettings.tsx | ⏳ | |
| Git fetch interval; Automatically pull | comp/settings/SettingsPanels.tsx | 🟡 | WP7.7b: fetch interval in the Git row's details, automatic pull in Repositories |
| Worktree branch naming | comp/settings/BranchNamingSettings.tsx | 🟡 | WP7.7b |
| Writing style (Repository conventions, Conventional Commits, Custom), writer model, follow templates | comp/settings/SourceControlWritingSettings.tsx | ➖ | WP7.7b: style select with custom instructions, templates, writer model switch and picker. Missing: "Write custom instructions for all" when mixed, traits picker; Audit 2026-10-11: Style select, templates, writer model. Missing "Write custom instructions for all" and traits picker. |
| Default merge method; Remove agent credits when merging | comp/settings/SourceControlSettings.tsx | ➖ | WP7.7b: both rows. Stored only for this client: the pull request merge tab still starts from the last-picked method; Audit 2026-10-11: Rows stored; the merge tab does not start from them. |

### Settings > Storage

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Automatic worktree cleanup (deleted threads, inactive, merged, unchanged) | comp/settings/StorageSettings.tsx | 🟡 | WP7.7b: rules per environment; Inherit, Off or Custom per project; capability notices. The days field commits on each step |
| Worktree location | comp/settings/StorageSettings.tsx | 🟡 | WP7.7b |
| Artifacts and logs (old browser artifacts, rotated logs) | comp/settings/StorageSettings.tsx | 🟡 | WP7.7b |

### Settings > Connections

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| This machine: environment name, icon, version, update | comp/settings/ConnectionsSettings.tsx, comp/settings/EnvironmentIconPicker.tsx, comp/settings/LocalEnvironmentSetting.tsx | ➖ | Missing: update actions, row menu; Audit 2026-10-11: Name, icon, version (`ConnectionsSettingsView`). Update actions and row menu missing; update is M9 work. |
| Environments list (add backend, SSH, remote link, route, remove, reconnect status) | comp/settings/ConnectionsSettings.tsx, comp/settings/EnvironmentRow.tsx, comp/settings/EnvironmentRoutesList.tsx | ➖ | Missing: SSH, drag reorder of routes, permissions panel; Audit 2026-10-11: Add by pairing link, reconnect, remove. No SSH, route reorder, permissions panel only partly (`PermissionsDisclosureRow` exists). |
| Network access toggle; Tailscale HTTPS; pairing link with QR | comp/settings/ConnectionsSettings.tsx, comp/ui/qr-code.tsx | ➖ | Audit 2026-10-11: Toggles show state but stay disabled (bridge-only, `SettingsController.bridgeTooltip`). Pairing link with QR is built (`PairingLinkRowView`). |
| Authorized clients list, revoke one/others | comp/settings/ConnectionsSettings.tsx, comp/settings/SessionPermissions.tsx | 🟡 | Built (audit 2026-10-11): `AuthorizedClientsSectionView`, `ClientSessionRowView`, revoke and revoke others. Stale mark. |
| T3 Connect toggle, Publish agent activity, Hold webhooks while offline | comp/settings/ConnectionsSettings.tsx | ➖ | Audit 2026-10-11: Publish agent activity and Hold webhooks built (`SettingsHostAccess`). The T3 Connect link switch is disabled (linking left to T3 Code). |
| Outside agents: MCP URL copy, approve sign-in | comp/settings/ConnectionsSettings.tsx, web/routes/connect-agent.tsx | ➖ | Missing: only Copy MCP URL in the environment row menu; no sign-in approval; Audit 2026-10-11: Copy MCP URL in the environment menu. No sign-in approval. |
| Load balancing (Prefer, Normal, Less often, Manual only) | comp/settings/LoadBalancingSettings.tsx | ⏳ | |
| GitHub sharing (Read PRs / Read and act) | comp/settings/ConnectionsSettings.tsx | ⏳ | |
| WSL backend | comp/settings/ConnectionsSettings.tsx | n/a | Windows only; skip; Not applicable: Windows only. |
| Trace ID copy | comp/settings/ConnectionsSettings.tsx | 🟡 | |

### Settings > Archive

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Archived threads list with Unarchive and Delete | web/routes/settings.archived.tsx, comp/settings/SettingsPanels.tsx (line ~3470) | 🟡 | WP7.7b: `orchestration.getArchivedShellSnapshot` per environment, by project, Unarchive, context menu with Delete (confirm when "Confirm thread deletion" is on) |

### Settings > Diagnostics (from General > About)

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Live processes with signal actions | comp/settings/DiagnosticsSettings.tsx, comp/settings/ProcessSignalActions.tsx | 🟡 | WP7.7b: stats, process tree with collapse, INT and KILL (`server.signalProcess`, KILL asks first) |
| Resource history charts (5m, 15m, 30m, 1h) | comp/settings/DiagnosticsSettings.tsx, comp/settings/ResourceTelemetryDiagnostics.tsx | ➖ | WP7.7b: window selector, stats, CPU bars, top processes. Missing: the resource telemetry block (its own stream), bar tooltips; Audit 2026-10-11: Window selector, stats, CPU bars, top processes. Missing telemetry stream, tooltips. |
| Trace diagnostics (latest failures, common failures, slowest spans, span logs, top names) | comp/settings/DiagnosticsSettings.tsx | ➖ | WP7.7b: stats and the five tables. Missing: open logs folder, copy trace id, expandable text; Audit 2026-10-11: Stats and five tables. Missing open logs folder, copy trace id, expandable text. |

## Command palette

Opened with `mod+k` (`commandPalette.toggle`). Source: `comp/CommandPalette.tsx`, `comp/CommandPaletteContent.tsx`, `comp/CommandPaletteResults.tsx`, `comp/CommandPalette.logic.ts`, `comp/ui/command.tsx`.

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Palette dialog, input, virtualized grouped results, footer hints, back navigation (sub-pages) | comp/CommandPaletteContent.tsx, comp/CommandPaletteResults.tsx | 🟡 | WP7.1: `Features/CommandPalette`, `CommandPaletteView`; every row is built (no virtualization), the panel scrolls with fades; fidelity 2.19% over 8 cases |
| Group: Actions (default page), Recent Threads | comp/CommandPalette.logic.ts | 🟡 | First row highlighted on open; typing or a submenu hides the highlight until ArrowDown |
| Search groups: Projects, Threads (title and message search, 2+ chars), Settings | comp/CommandPalette.logic.ts | ➖ | Projects and Threads with `orchestration.searchThreads` (2+ chars, 200 ms debounce) and T3's ranking; Settings waits for settings search (WP7.7); thread rows use a text subtitle; Audit 2026-10-11: Projects and Threads built (`PaletteCommands`). Settings group missing though `SettingsSearch` now exists. |
| New thread in... (project chooser incl. No project) | comp/CommandPalette.tsx (line ~1917) | ➖ | Project groups with `thread.jump.N` shortcuts; no "No project" (scratch threads); Audit 2026-10-11: `new-thread-in:` pages built. No "No project". |
| New thread without a project | comp/CommandPalette.tsx (line ~1929) | ⏳ | |
| Find in current thread | comp/CommandPalette.tsx (line ~1940) | ⏳ | |
| Link pull request to thread; Show linked pull requests | comp/CommandPalette.tsx (lines ~1973-1990) | ✅ | Capability-gated like T3 |
| Restart agent session | comp/CommandPalette.tsx (line ~2000) | ⏳ | |
| Go to file | comp/CommandPalette.tsx (line ~2041) | 🟡 | WP7.6a, keeps the palette open in files mode |
| Search project contents | comp/CommandPalette.tsx (line ~2054) | 🟡 | WP7.6b: the "Search project contents" action (`projectSearch.toggle`) |
| New project (name, optional private GitHub repo) | comp/CommandPalette.tsx (line ~2068) | ⏳ | |
| Add project: local folder browser (directories list with ".."), clone from provider or URL, existing project | comp/CommandPalette.tsx (lines ~2099, 2840, 2935) | ➖ | "Add project" runs the desktop folder picker; browse, clone and the environment step wait; Audit 2026-10-11: Folder picker only. No browser, clone or environment step. |
| Open WSL folder | comp/CommandPalette.tsx (line ~2112) | n/a | Windows only; skip; Not applicable: Windows only. |
| Change theme (sub-page with live preview) | comp/CommandPalette.tsx (line ~2126) | ⏳ | `theme.select` |
| Change appearance (System, Light, Dark) | comp/CommandPalette.tsx (line ~2175) | 🟡 | Kept in UserDefaults `appearance.mode`; `--appearance` still wins for development |
| Toggle theme editor | comp/CommandPalette.tsx (line ~2221) | ⏳ | |
| Open pull requests; Open usage; Open settings; Project settings | comp/CommandPalette.tsx (lines ~2242-2299) | ➖ | Pull requests and usage open the placeholder pages; Project settings not wired yet (the page exists since WP7.7b); Audit 2026-10-11: Pull requests, settings built; Usage opens a page being built; Project settings not wired. |
| Environment picker inside multi-env flows | comp/CommandPalette.tsx (lines ~1803, 2906) | ⏳ | |
| Command palette bus (open to a given page from elsewhere) | web/commandPaletteBus.ts | ➖ | `chat.new` opens "New thread in..." with several projects; the sidebar's new-thread button still creates directly; Audit 2026-10-11: `chat.new` opens the project page; the sidebar new-thread button creates directly. |
| Copy thread ID (`thread.copyReference`) | comp/CommandPalette.tsx (line ~1950) | ✅ | "Copy PR link" when the thread has one |
| Thread find/search within palette using server `thread.find` | comp/ThreadSearchMatch.tsx | ➖ | Message search through `orchestration.searchThreads`; the match line is plain text; Audit 2026-10-11: Message search built; match line is plain text. |

## Keyboard shortcuts

Defaults are in `packages/shared/src/keybindings.ts` (`DEFAULT_KEYBINDINGS`, lines 123-210), command IDs in `contracts/keybindings.ts`. `mod` is Command on macOS. Users override via `keybindings.json` on the server (last matching rule wins; see docs/keybindings.md Precedence). Rules with no when-clause apply everywhere. `script.<id>.run` is a dynamic command created per project action.

| Command | Key | When | Status |
|---|---|---|---|
| Engine: defaults, the primary environment's resolved rules merged per command, `keybindingsUpdated` live, last matching rule wins, when-clauses, shortcut labels | (system) | (all) | 🟡 WP7.1: `T3Protocol/Domain/Keybindings.swift`, `Features/Keyboard/ActiveKeymap.swift`, `App/Sources/Shortcuts.swift` (one dispatcher) |
| sidebar.toggle | mod+b | (none) | 🟡 |
| navigation.back | mod+[ | !terminalFocus | ⏳ no route history yet |
| navigation.forward | mod+] | !terminalFocus | ⏳ no route history yet |
| terminal.toggle | mod+j | (none) | 🟡 |
| rightPanel.toggle | mod+alt+b | (none) | 🟡 WP7.6a: hides an open panel, else shows its tabs or the launcher |
| rightPanel.new | mod+t | rightPanelOpen && !terminalFocus | 🟡 WP7.6a: the + menu |
| terminal.split | mod+d | terminalFocus | ⏳ splits not drawn |
| terminal.splitVertical | mod+shift+d | terminalFocus | ⏳ splits not drawn |
| terminal.new | mod+n | terminalFocus | 🟡 one terminal shows |
| terminal.close | mod+w | terminalFocus | 🟡 |
| rightPanel.close | mod+w | !terminalFocus | 🟡 WP7.6a: closes the active tab |
| view.reopenClosed | mod+shift+t | (none) | 🟡 WP7.6a: panel tabs only |
| diff.toggle | mod+d | !terminalFocus | 🟡 |
| preview.toggle | mod+shift+j | (none) | 🟡 WP7.6b |
| preview.refresh | mod+r | previewFocus | 🟡 WP7.6b |
| preview.focusUrl | mod+l | previewFocus | 🟡 WP7.6b |
| preview.zoomIn | mod+= and mod++ | previewFocus | 🟡 WP7.6b |
| preview.zoomOut | mod+- | previewFocus | 🟡 WP7.6b |
| preview.resetZoom | mod+0 | previewFocus | 🟡 WP7.6b |
| commandPalette.toggle | mod+k | !terminalFocus | 🟡 |
| filePicker.toggle | mod+p | !terminalFocus | 🟡 WP7.6a |
| projectSearch.toggle | mod+shift+f | !terminalFocus | 🟡 WP7.6b: the palette's content mode |
| usage.open | mod+u | !terminalFocus | ➖ placeholder page |
| theme.select | mod+alt+a | !terminalFocus | ⏳ themes, WP7.7 |
| appearance.cycle | mod+alt+shift+a | !terminalFocus | 🟡 |
| themeEditor.toggle | mod+alt+shift+t | (none) | ⏳ WP7.7 |
| composer.stash | mod+s | !terminalFocus | 🟡 WP7.3 |
| thread.steerQueuedMessage | mod+shift+enter | !terminalFocus | 🟡 |
| thread.editQueuedMessage | alt+arrowup | composerFocus | 🟡 |
| composer.sendAlternate | mod+enter | composerFocus && turnRunning | 🟡 |
| composer.sendBackground | mod+enter | composerFocus && draftThreadRoute | ➖ resolved; sends in the foreground until start-in-background lands |
| composer.sendBackground | mod+alt+enter | composerFocus && draftThreadRoute | ➖ resolved; sends in the foreground until start-in-background lands |
| composer.sendAndNewThread | mod+alt+enter | composerFocus && !draftThreadRoute | ➖ resolved; sends without opening a new thread yet |
| chat.new | mod+n | !terminalFocus | 🟡 |
| chat.new | mod+shift+o | !terminalFocus | 🟡 |
| chat.newLocal | mod+shift+n | !terminalFocus | 🟡 |
| chat.newWithoutProject | mod+alt+n | !terminalFocus | ⏳ scratch threads |
| chat.find | mod+f | !terminalFocus && !previewFocus | ⏳ thread find, WP7.8 |
| modelPicker.toggle | mod+shift+m | !terminalFocus | 🟡 |
| composer.host | mod+shift+h | !terminalFocus | 🟡 |
| composer.effort | mod+shift+e | !terminalFocus | 🟡 |
| composer.mode | mod+shift+a | !terminalFocus | 🟡 |
| composer.workspace | mod+shift+x | !terminalFocus | 🟡 |
| composer.branch | mod+shift+g | !terminalFocus | 🟡 |
| composer.previousWorktree | mod+shift+l | !terminalFocus | 🟡 |
| pullRequest.copyNumber | mod+shift+k | !terminalFocus | ✅ WP7.5b, with a pull request tab active |
| modelPicker.previousProvider | mod+shift+arrowup | modelPickerOpen | 🟡 |
| modelPicker.nextProvider | mod+shift+arrowdown | modelPickerOpen | 🟡 |
| editor.openFavorite | mod+o | (none) | ⏳ WP7.8 |
| thread.previous | mod+shift+[ | (none) | 🟡 |
| thread.next | mod+shift+] | (none) | 🟡 |
| thread.copyReference | mod+shift+c | !terminalFocus | ➖ thread ID only, PR link with WP7.5 |
| thread.settle | mod+shift+s | !terminalFocus | 🟡 |
| thread.pin | mod+shift+p | !terminalFocus | 🟡 |
| thread.undo | mod+z | !terminalFocus && !editableFocus | 🟡 |
| thread.jump.1 to thread.jump.9 (`THREAD_JUMP_KEYBINDING_COMMANDS`) | mod+1 to mod+9 | isDesktop | 🟡 |
| modelPicker.jump.1 to .9 (`MODEL_PICKER_JUMP_KEYBINDING_COMMANDS`) | mod+1 to mod+9 | modelPickerOpen && isDesktop | ➖ no hint labels on the rows |
| usage.cost | c | usagePageOpen | ⏳ usage page |
| usage.tokens | t | usagePageOpen | ⏳ usage page |
| usage.limits | l | usagePageOpen | ⏳ usage page |
| usage.period.day / week / month / quarter | mod+shift+1 / 2 / 3 / 4 | usagePageOpen | ⏳ usage page |
| thread.stop | (no default) | (none) | 🟡 |
| composer.cycleHost | (no default) | (none) | ⏳ |
| script.<id>.run | (no default, user-assigned) | (none) | ⏳ project scripts, WP7.4 |
| Fixed, not configurable: diff find | mod+f inside a diff | diff focused | ⏳ |
| Fixed: copy PR URL | mod+shift+c | PR open in panel or PR page | 🟡 beside a thread; the Pull Requests page has no copy shortcut yet |
| Fixed: quit | mod+q (hold 1.2 s, or double press within 500 ms) | desktop | ⏳ WP7.8 |
| When-clause context keys to implement | terminalFocus, previewFocus, composerFocus, editableFocus, rightPanelOpen, turnRunning, draftThreadRoute, modelPickerOpen, usagePageOpen, isDesktop | n/a | ➖ composerFocus, editableFocus, rightPanelOpen, turnRunning, draftThreadRoute, modelPickerOpen, usagePageOpen, isDesktop, isWeb set; terminal and preview keys read false until WP7.4 and WP7.6 |

Row note: the `mod+shift+c` PR copy shortcut in docs shares its key with `thread.copyReference`; the app picks the PR URL when a PR is the selected context.

## Notifications and dock badge

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Notification coordinator: events when a thread finishes, fails, or needs approval/input | comp/ThreadNotificationCoordinator.tsx, web/threadNotifications.ts | ⏳ | Server `Notification` stream per environment |
| Modes: Off, Notifications, Sound only, Notifications with sound | comp/settings/NotificationSettings.tsx | ⏳ | |
| System notification (click focuses the thread) | comp/ThreadNotificationCoordinator.tsx | ⏳ | UNUserNotificationCenter |
| Notification sound, audio unlock | web/threadNotifications.ts | ⏳ | |
| Dock badge count of threads with unread notifications; cleared on window focus | desk/ipc/methods/notificationBadge.ts | ⏳ | `app.setBadgeCount` on macOS |
| In-app toasts (toast manager, anchored copy toast, undo toasts) | comp/ui/toast.tsx, comp/ui/toastHelpers.ts | ➖ | Missing: toast component and copy toasts only; Audit 2026-10-11: `ToastQueue`, `ToastViewport` and the undo notice exist. No anchored copy toast seen. |
| Slow RPC toast, keybinding update toast, provider update toast | comp/SlowRpcRequestToastCoordinator.tsx, comp/KeybindingsUpdateToast.logic.ts | ⏳ | |
| Mobile push / Live Activities for agent activity | docs/mobile-notifications.md | n/a | Server publishes when "Publish agent activity" is on; no macOS client work; Not applicable: Server publishes; no macOS client work. |

## Onboarding and welcome

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| First-run gate (decides wizard vs app; Still connecting; Could not read settings) | comp/onboarding/FirstRunGate.tsx, web/routes/welcome.tsx | ⏳ | |
| Welcome wizard step 1: connect computers (T3 Connect list, add a computer by pairing link) | comp/onboarding/WelcomeWizard.tsx, comp/cloud/CloudEnvironmentConnectList.tsx | ⏳ | T3 Connect sign-in uses Clerk; needs webview: ask user |
| Welcome wizard step 2: check agents (Claude Code, Codex install/sign-in via terminal) | comp/onboarding/WelcomeWizard.tsx | ⏳ | |
| Welcome wizard step 3: import projects (scan, groups, select all/none, conversation import) | comp/onboarding/WelcomeWizard.tsx, docs/welcome-wizard.md | ⏳ | |
| Wizard progress bar and navigation | comp/ui/wizard.tsx | ⏳ | |
| Connect onboarding dialog | comp/cloud/ConnectOnboardingDialog.tsx | ⏳ | |
| Permission checklist (macOS permissions) | comp/permissions/PermissionChecklist.tsx, desk/permissions/MacPermissions.ts | ⏳ | |
| Pairing route (`/pair`) | web/routes/pair.tsx, comp/auth/PairingRouteSurface.tsx | ⏳ | |
| Connect CLI auth and connect-agent surfaces | web/routes/connect.tsx, web/routes/connect-agent.tsx, comp/cloud/ConnectCliAuthSurface.tsx, comp/auth/ConnectAgentSurface.tsx | ⏳ | |
| Nightly mobile beta promo | comp/NightlyMobileBeta.tsx | ⏳ | Optional |

## Remote environments and T3 Connect

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Local environment spawned and managed by the app | desk/backend/DesktopBackendManager.ts | 🟡 | See Desktop-only |
| Add remote environment by pairing link / token (LAN, Tailscale) | docs/remote-access.md, web/pairingUrl.ts, web/hostedPairing.ts | 🟡 | |
| Desktop-managed SSH environments (password prompt dialog) | desk/ssh, comp/desktop/SshPasswordPromptDialog.tsx | ⏳ | |
| T3 Connect: sign in (Clerk), cloud environments list, connect/remove | comp/clerk/T3ConnectAccountPages.tsx, comp/cloud/CloudEnvironmentConnectList.tsx, comp/clerk/RemoveT3ConnectEnvironmentDialog.tsx | 🟡 | Clerk UI needs webview: ask user; Missing: client library and Clerk sign-in code exist, no sign-in UI, not wired in the app; Built (audit 2026-10-11): `T3ConnectController`, `T3ConnectAccountView`, `T3ConnectSignInView`, `T3Client/Connect/`. Live with the user's account. Stale mark. |
| T3 Connect relay client install dialog | comp/cloud/RelayClientInstallDialog.tsx | ⏳ | |
| Account profile pages (user, mobile clients) | comp/clerk/T3ConnectUserProfilePage.tsx, comp/clerk/MobileClientsUserProfilePage.tsx | ➖ | needs webview: ask user; Audit 2026-10-11: Account menu and `T3ConnectAccountView` built. Mobile clients page skipped. |
| Electron-managed auth shell (browser handoff, passkeys) | comp/clerk/ElectronManagedAuthShell.tsx, desk/app/DesktopClerk.ts | ➖ | Native: ASWebAuthenticationSession; Audit 2026-10-11: Native Clerk sheet (email code and password). Social buttons and passkeys left out. |
| Environment connection status dots, reconnecting reasons | comp/ConnectionStatusDot.tsx, comp/settings/ConnectionsSettings.logic.ts | 🟡 | Missing: status text and reconnect banner only, no dots; Built (audit 2026-10-11): Dot, status text and tooltip per environment (`ConnectionsSettingsView.Dot`), reconnect banner (`EnvironmentBannerView`). Stale mark. |
| Multi-environment thread/project merge in sidebar | web/environmentGrouping.ts, web/environments/ | 🟡 | |
| Version skew blocking (app newer than server and vice versa) | web/versionSkew.ts, docs/updating.md | ➖ | Missing: protocol mismatch shows "Client not supported"; no skew blocking flow; Audit 2026-10-11: Protocol mismatch shows "Client not supported". No skew blocking flow. |
| Remote server update (self-update progress, desktop-managed update) | comp/ServerUpdateAction.tsx, desk/updates/DesktopRemoteUpdates.ts | ⏳ | |
| Load balancing of new threads across machines | comp/settings/LoadBalancingSettings.tsx, docs/remote-access.md | ⏳ | |
| Outside agents (Claude Code, Codex, ChatGPT connect via MCP URL + OAuth approval) | docs/outside-agents.md, web/routes/connect-agent.tsx | ⏳ | |
| Hosted web app (app.t3.codes) pairing | docs/remote-access.md | 🟡 | Web only |
| Background service (`t3 service`) | docs/background-service.md | n/a | CLI, not a UI feature; Not applicable: CLI, not a UI feature. |
| Threads from older versions (migration) | docs/thread-migration.md | ⏳ | |

## Usage and limits

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Usage page route and shell, environment dropdown, refresh | web/routes/usage.tsx, comp/usage/UsagePage.tsx | ⏳ | `mod+u` |
| Tabs: Cost, Tokens, Limits (keys c, t, l) and period (day, week, month, quarter) | comp/usage/UsagePage.tsx, comp/usage/usagePagePreferences.ts, comp/usage/usageShortcuts.ts | ⏳ | |
| Charts by provider/model, token-type split, cache savings, premium/other cost | comp/usage/UsageProviderChart.tsx, comp/usage/UsageShareBar.tsx, comp/usage/usageBreakdown.ts | ⏳ | Needs native chart drawing (Swift Charts or custom) |
| Model breakdown detail dialog | comp/usage/UsageModelDialog.tsx | ⏳ | |
| Custom model prices and aliases | comp/usage/UsagePriceOverrides.tsx, comp/usage/usagePriceTable.ts | ⏳ | |
| Limits: pooled subscription windows per provider, per-account segments, reset times, Use reset | comp/usage/UsageLimitsPooled.tsx, comp/usage/UsageLimits.tsx | ⏳ | |
| Limit sources: add CLIProxyAPI hub | comp/settings/AddUsageLimitSourceDialog.tsx | ⏳ | |
| Subscription usage widget (composer / header) | comp/chat/ComposerUsageLimits.tsx, docs/usage.md | ⏳ | |
| `/usage-limits` slash command result above composer | docs/usage.md | ⏳ | |
| Enable Cursor usage (Keychain) | comp/settings/UsageProviderSettings.tsx | ⏳ | |

## Scheduled tasks

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Settings page: per-environment task list with enable switch, Run now, Delete | comp/settings/ScheduledTasksSettings.tsx, web/routes/settings.scheduled-tasks.tsx | ⏳ | |
| Task editor (title, prompt, project, model, schedule: cron/interval/once, mode) | comp/settings/ScheduledTasksSettings.tsx, comp/settings/scheduledTasksSettings.logic.ts | ⏳ | |
| Webhook triggers: URL, rotate token, delivery history (headers, query, body) | comp/settings/ScheduledTasksSettings.tsx, docs/project-settings.md | ⏳ | |
| Thread automations panel (tasks tied to a thread) | comp/chat/ThreadAutomationsPanel.tsx | ⏳ | |
| Pull request watch (agent wakes on PR activity) | contracts/rpc.ts (`pullRequests.watch`), comp/pullRequest/ThreadPullRequestsPanel.tsx | ⏳ | |

## Devices and SnapShot

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Device panel (see Right panels) | comp/device/ | ⏳ | |
| Device hosts over SSH, tool updates | comp/settings/DeviceHostsSettings.tsx, comp/device/DeviceHostUpdates.tsx, docs/devices.md | ⏳ | |
| SnapShot capture: global shortcut (both Shift keys by default), active window capture, attach to draft | desk/snapShot/MacSnapShot.ts, desk/snapShot/DesktopSnapShot.ts, desk/snapShot/MacModifierPairShortcutProcess.ts | ⏳ | Native on macOS: ScreenCaptureKit + AX tree |
| SnapShot coordinator in renderer (attach, pending captures on disk) | comp/desktop/SnapShotCoordinator.tsx, comp/desktop/SnapShotShortcutKeys.tsx | ⏳ | |
| SnapShot capture feedback (sound, flash, animation) | desk/snapShot/NativeCaptureFeedback.ts | ⏳ | |

## Desktop-only

### Application menu (macOS)

Source: `desk/window/DesktopApplicationMenu.ts`.

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| App menu: About T3 Code | desk/window/DesktopApplicationMenu.ts (line 169) | 🟡 | |
| App menu: Check for Updates... | same (line 171) | M9 | Also under Help; Milestone 9: Needs the updater. |
| App menu: Settings... (Cmd+,) | same (line 176) | 🟡 | |
| App menu: Services | same (line 181) | 🟡 | |
| App menu: Hide T3 Code, Hide Others, Show All | same (lines 183-185) | 🟡 | |
| App menu: Quit T3 Code (Cmd+Q, hold-to-quit logic) | same (line 187), desk/window/QuitHold.ts, comp/QuitHoldOverlay.tsx | ➖ | Overlay shown while holding; Missing: hold-to-quit |
| File menu: Close (Cmd+W) | same (lines 194-206) | ⏳ | Close role; app rebinds mod+w to panel/terminal close first |
| Edit menu: Undo, Redo, Cut, Copy, Paste, Paste as Text (Cmd+Shift+V), Delete, Select All, Speech (Start/Stop Speaking) | same (lines 210-231) | 🟡 | |
| View menu: Reload (Cmd+R), Force Reload (Shift+Cmd+R), Toggle Developer Tools (Alt+Cmd+I) | same (lines 238-255) | n/a | Dev tools and reload need a web inspector; native build can omit or map to debug tools; Not applicable: Reload and developer tools need a web inspector. No equivalent. |
| View menu: Actual Size (Cmd+0), Zoom In (Cmd+=, Cmd+Plus), Zoom Out (Cmd+-), Toggle Full Screen | same (lines 258-268) | ⏳ | Zoom scales the whole UI |
| Window menu (system Window role: Minimize, Zoom, Bring All to Front) | same (line 271) | 🟡 | |
| Help menu: Check for Updates... | same (lines 272-279) | M9 | Milestone 9: Needs the updater. |
| Context menus (native menu for items, fallback in web) | desk/electron/ElectronMenu.ts, web/contextMenuFallback.ts | ➖ | Use NSMenu everywhere; Missing: only file chip and menu popups use native menus; Audit 2026-10-11: NSMenu used for thread menus, file chips, popups. Several right-click targets still have none. |

### Window behaviour

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Hidden inset title bar with traffic lights at custom position; custom top bar height | desk/window/DesktopWindow.ts (lines 267-279), web/workspaceTitlebar.ts | 🟡 | Needed for identical look |
| Minimum window size 840 wide | desk/window/DesktopWindow.ts (line 407) | 🟡 | |
| Window bounds persisted and restored (display-aware) | desk/window/DesktopWindow.ts (lines 168-190) | 🟡 | |
| Window vibrancy / glass opacity | desk/window/DesktopWindow.ts, comp/settings/SettingsPanels.tsx | ⏳ | Verify vibrancy parameters in source |
| Window drag region in sidebar and header | web/index.css (`-webkit-app-region`) | 🟡 | |
| Running-thread keep alive (prevent App Nap / sleep while agents run) | comp/desktop/RunningThreadKeepAlive.tsx, desk/electron/ElectronPowerMonitor.ts | ⏳ | |
| Single instance; second launch focuses existing window | desk/app/DesktopClerk.ts (`second-instance`), desk/app/DesktopAppActivation.ts | ⏳ | |
| App activation coordination (focus thread on notification click) | comp/desktop/DesktopAppActivationCoordinator.tsx, web/desktopAppActivation.ts | ⏳ | |
| Native theme sync (window appearance follows chosen mode) | desk/electron/ElectronTheme.ts | 🟡 | Built (audit 2026-10-11): `PaletteCommands` sets `NSApp.appearance` for System, Light, Dark. Stale mark. |
| Safe storage for secrets (Keychain) | desk/electron/ElectronSafeStorage.ts | 🟡 | |
| Shell environment resolution (PATH from login shell) | desk/shell/DesktopShellEnvironment.ts | 🟡 | Needed to spawn the bundled server |
| Open in editor / file manager / reveal in Finder | comp/chat/OpenInPicker.tsx, web/editorPreferences.ts, desk/electron/ElectronShell.ts | ⏳ | `editor.openFavorite` |
| Native dialogs (folder pick, confirm) | desk/electron/ElectronDialog.ts, web/confirmDialog.ts, comp/ConfirmDialogHost.tsx | 🟡 | |
| Tray / menu bar icon | none found in desk/src | n/a | No tray implemented in the official app; do not build; Not applicable: The official app has no tray. Checklist says do not build. |
| Desktop settings stores (client settings, saved environments, connection catalog) | desk/settings/, desk/app/DesktopConnectionCatalogStore.ts | ➖ | Per-device preferences live here, not on server; Missing: saved environments only; no client settings store; Audit 2026-10-11: UserDefaults stores (`ClientSettingsStore`, environments). Row note says no client settings store; one exists. |
| Spawned backend lifecycle (start, restart, pool, exposure on LAN) | desk/backend/DesktopBackendManager.ts, desk/backend/DesktopServerExposure.ts | 🟡 | See D-server-features.md |
| CLI shim install (`t3` command) | desk/app/DesktopCliShim.ts, desk/app/DesktopCliCommand.ts | M9 | Milestone 9: CLI shim install. |
| macOS permission helper and settings window | desk/permissions/MacPermissionHelper.ts, desk/permissions/MacSettingsWindow.ts | ⏳ | Screen Recording, Accessibility |

### Updates

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Auto-update (check, download, install on restart, state machine) | desk/updates/DesktopUpdates.ts, desk/updates/updateMachine.ts, desk/electron/ElectronUpdater.ts | M9 | Use Sparkle natively; same channels; Milestone 9: Updater work. |
| Update channels (stable, nightly) | desk/updates/updateChannels.ts | M9 | Milestone 9: Updater work. |
| Release notes in sidebar pill | desk/updates/releaseNotes.ts, comp/sidebar/SidebarUpdateReleaseNotes.tsx | M9 | Milestone 9: Updater work. |
| Update toasts | comp/desktopUpdate.toast.tsx, comp/desktopUpdate.logic.ts | M9 | Milestone 9: Updater work. |
| Remote desktop update of a connected machine | desk/updates/DesktopRemoteUpdates.ts, desk/updates/remoteUpdateFlow.ts | M9 | Milestone 9: Updater work. |

### Deep links and protocols

| Feature | Official source (file path) | Status | Notes |
|---|---|---|---|
| Custom scheme `t3code://app` serves the renderer (internal, not user-facing) | desk/electron/ElectronProtocol.ts, desk/app/DesktopEnvironment.ts | n/a | Native app needs no equivalent; Not applicable: Internal to the Electron renderer. |
| `t3code://` open-url handling for provider auth hand-off and resume (Codex OAuth callback) | desk/app/DesktopClerk.ts (lines 187-196), desk/app/CodexAuthCallback.ts | ⏳ | Register URL scheme in Info.plist |
| Default protocol client registration | desk/electron/ElectronApp.ts (line 168), desk/app/DesktopLinuxUrlHandler.ts | M9 | Milestone 9: Info.plist registration at packaging time. |
| Pairing link (`/pair#...`) handling when opened | web/routes/pair.tsx, web/pairingUrl.ts | ⏳ | HTTPS link; open in the app if possible |

## Webview and JS runtime summary

Features marked `needs webview: ask user`:

1. Built-in browser/preview panel with agent control, element picking, annotation, recording, PiP, remote streaming, session import.
2. HTML renders / visual replies (`HtmlRenderFrame.tsx`) running scripts in a sandbox.
3. MCP apps (`McpAppFrame.tsx`).
4. Mermaid diagrams (`MermaidDiagram.tsx`).
5. HTML file preview in the file viewer (`BrowserDocumentFrame.tsx`). PDF can use PDFKit.
6. Clerk-hosted UI for T3 Connect sign-in and account pages.
7. Device 3D view (WebGL) and possibly the device stream renderer; confirm transport first.
8. Terminal renderer is Ghostty in JS/WASM in the web app. A native emulator avoids the webview.
9. Diff rendering (`@pierre/diffs`) and file tree (`@pierre/trees`) are JS libraries. Native replacements are required, no webview needed unless we choose to reuse them.
