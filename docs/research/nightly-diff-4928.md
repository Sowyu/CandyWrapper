# T3 Code Nightly: 3824 to 4928, UI and behavior

Range: v0.1.4-nightly.20261028.3824 .. v0.1.11-nightly.20261119.4928, 4,312 commits without merges. 1,683 of them touch apps/web/src, packages/client-runtime or packages/shared, and each has a row in [the commit appendix](nightly-diff-4928-commits.md). The other 2,629 touch only the server, mobile, desktop, contracts or tooling. The wire audit covers contracts and the protocol, so this doc names wire only as "needs wire: X".

T3 paths are relative to apps/web/src unless they start with packages/, and line numbers refer to the 4928 tree. "CW" is CandyWrapper, with paths under Packages/CandyKit/Sources unless they start with App/.

## How to read this

The appendix gives 1,167 commits the status `port`, 444 `n/a`, 70 `skip` and 2 `free with the runtime`. Nobody checked the 1,167 `port` rows against CW one by one, so some are already there. The agent who takes a group reads the T3 commit, checks CW, and marks each row `already in CandyWrapper` or ports it.

Most of the range is small fixes: 1,368 of the 1,683 client commits are `fix`, 159 are `feat`. The groups below collect the features and the fix clusters with their own story. The rest fall into the "small fixes" batches at the end, one batch per area.

"Default look" says whether a group changes what the default themes draw. If it does, the fidelity references for that surface need recapturing from 4928, and the agent should expect fidelity tests to fail until they do.

## 1. Thread and timeline

### 1.1 Your messages get new shapes (large, default look: yes)

T3 redrew the user message. Back-to-back messages from you stack as one burst with joined corners and a single steer label (#27305, #27978). Images and videos sent with text sit above the bubble as their own shape (#27306). Files sent without text show as file cards (#27324), and pasted text, snapshots and files being sent each get a shape of their own (#27377). Image-only messages show the image, not the placeholder prompt (#26769, #27383), and a very wide or tall lone image shows whole (#38558). A quote in a sent message is an inset card (#34181).

- T3: components/chat/TimelineUserMessageRow.tsx:270 (`UserMessageRow`), :109 (`UserFileCard`), components/chat/MessagesTimeline.logic.ts:645 (joined corners), components/chat/AssistantCitationChip.tsx:117 (quote card).
- CW: Features/Thread/TimelineMessageRows.swift, Features/Thread/ThreadMediaAttachmentView.swift, Features/Thread/ThreadSentFileRowView.swift, T3Store/TimelineRows.swift.
- Recapture the user-message component references.

### 1.2 Steering, Stop and Resume (medium, default look: small)

Final replies stay visible after a steer (#34501), late answers show in their own runs (#23249), and a requeued steer no longer looks delivered (#23420). Stop shows a pending state and repeat clicks no longer resume (#20809). Resume replaces Stop without a lingering Stopped button (#35755), hides while a pending request blocks the run (#28810), and Enter on an empty prompt resumes an interrupted thread (#27079). Steering waits for worktree setup (#34581).

- T3: components/chat/MessagesTimeline.logic.ts, session-logic.ts, components/ChatView.tsx.
- CW: T3Store/TimelineEntries.swift, Features/Thread/ThreadRecoveryPresentation.swift, App/Sources/ComposerController.swift.

### 1.3 Model and effort switches show in the thread (small, default look: yes, new row)

When you switch model or effort, the thread shows a row saying so (#28995). Needs wire: `modelSwitch` on user message items.

- T3: components/chat/V2LifecycleRow.tsx:643, components/chat/TimelineUserMessageRow.tsx:273, packages/client-runtime/src/handoff.ts.
- CW: Features/Thread/HandoffDividerView.swift, Features/Thread/TimelineMessageRows.swift.

### 1.4 Thread details card and context meter (medium, default look: yes)

You choose which sections the thread details card shows, in Settings (#26904). The context meter fills up and shows tokens against the limit (#27892). A Labs toggle keeps the 5-hour, weekly and context limits in view (#26859), and usage limit rows show your pace and open the Usage page (#38789). Long server lists page four at a time (#28684), many automations no longer hide the Automations section (#28585), and the card slides in on close (#28929).

- T3: components/chat/ThreadDetailsPanel.tsx:97, components/chat/ThreadDetailsUsage.tsx:45, components/settings/ThreadDetailsItemsRow.tsx:17.
- CW: Features/Git/ThreadDetailsCardView.swift, Features/Thread/ThreadContextWindowMeterView.swift, Features/Settings/GeneralSettingsView.swift.

### 1.5 Chat Markdown (medium, default look: yes in places)

Claude insight blocks render as a callout (#22239). Inline code that names a path, like `docker/Dockerfile` or `allocator.cc:217`, becomes a file chip (#32402, #32403, #37750). Bold weight is back (#25694), plain-text code blocks match the text around them (#27144), and markdown separators show in dark mode (#22367). Markdown links to apps show the app's bundle icon and open the app (an unnumbered commit, in the thread batch). Copying keeps alert callouts, list numbers, email links and blank lines (markdown-clipboard.ts, about 10 commits).

- T3: components/ChatMarkdown.tsx:378 (insight), :1118 (blockquote), components/chat/markdownStreamBlocks.ts:9, packages/shared/src/markdownLinks.ts, markdown-clipboard.ts.
- CW: Features/Markdown/MarkdownView.swift, Features/Markdown/FileLinks.swift, Features/Markdown/FileChip.swift.

### 1.6 Images and media in the thread (medium, default look: no)

Arrow keys and buttons step through the images an agent viewed (#34333), and images in expanded tool rows page through the group (#36321). Images the agent opens stay in the chat (#30473), MCP and OpenCode tool images show (#30389), and chat images reload when the agent rewrites the file (#29741). Expanded SVGs fill the viewer (#27519), and scrolling pans expanded images and Mermaid diagrams (#26630).

- T3: components/chat, components/media, assetUrls.ts.
- CW: Features/Thread/ThreadImageGallery.swift, Features/Thread/ThreadImageGalleryView.swift, Features/Thread/AgentImageCache.swift.

### 1.7 Subagents and delegated work (medium, default look: small)

Child approvals surface in the parent thread (#28516). Lineage and subagent cards name the account a subagent runs on (#24833, #24898). A run that waits on foreground subagents says so instead of Thinking (#36334). Delegated approvals open on the environment the child runs on (#28592).

- T3: components/chat/ChildThreadApprovals.tsx:87, components/chat/ThreadRelationshipsControl.tsx:470.
- CW: T3Store/ChildThreadInputs.swift, Features/Thread/SubagentCardRowView.swift, Features/Git/ThreadLineageSectionView.swift.

### 1.8 HTML renders, MCP apps and command output (small)

HTML renders keep their anchor and stop scrolling the chat (#34003, #38832), full-screen pages reflow on zoom (#22349), and html_render cards show for OpenCode, Grok and Antigravity threads. Command output keeps colors with underline styles (#21542), PASS and FAIL stay readable in dark output (#24042), and Windows `pwsh -Command` launchers unwrap in command rows (#38946).

- T3: packages/shared/src/htmlRender.ts, packages/shared/src/toolOutput.ts, packages/shared/src/terminalOutput.ts.
- CW: Features/Thread/TimelineWebRows.swift, Features/Thread/HtmlRenderWebCache.swift, Features/Thread/TimelineWorkInspector.swift.

### 1.9 Thread loading and connection (medium, no visible change)

Threads load while the socket connects, with fewer round trips (#35071, needs wire). Huge checkpoints arrive up to 75x smaller (#27110, needs wire: compact checkpoint payload). Earlier turns reveal in one load (#24417), a thread whose subscription dies resubscribes (#25919, #24400), a message the host never answers fails after 60 seconds (#35076), and retried messages keep their command id (#24761).

- T3: packages/client-runtime/src/client.ts, packages/client-runtime/src/threads.ts, packages/client-runtime/src/commands.ts.
- CW: T3Client, App/Sources/ThreadSession.swift.

## 2. Composer

### 2.1 Model and effort in one control (large, default look: yes)

You pick the model and its effort from one control (#28057). The picker stays open until dismissed, with a Show more row (#28076), opens at its final height (#26881) and uses the window's full height when short (#29017). Effort shows Default or the checkmark flush right (#28162), and Default no longer shows as the lowest bar (#38684). Ultrathink leaves the Claude effort picker (#28044) and Ultracode works with any effort (#27034). The picker checks for new models when it opens (#33511, needs wire), and providers can split their models into sub-providers (#29388, needs wire: `subProviders`).

- T3: components/chat/ComposerModelEffort.tsx:86, :525, components/chat/ProviderModelPicker.tsx:91, components/chat/ModelPickerContent.tsx:473, packages/client-runtime/src/providerSubProviders.ts.
- CW: Features/Pickers/ModelPickerView.swift, Features/Pickers/ComposerPickers.swift, Features/Pickers/ComposerControlView.swift, Features/Composer/ComposerEffortGlyph.swift.
- Recapture the composer and model picker references.

### 2.2 Labs cleanup removes plan mode (medium, default look: yes)

Labs lost its old toggles: the legacy plan mode toggle left the composer, and tool call display moved to Appearance (#33131). A tool calls option hides tool calls so a thread reads like a chat (#30000). CW still has plan mode in its composer menus and settings.

- T3: components/settings/LabsSettingsPanel.tsx:18, components/chat/ChatComposer.tsx, components/ChatView.logic.ts.
- CW: Features/Settings/BetaSettingsView.swift, Features/Composer/ComposerMenus.swift, App/Sources/ComposerController.swift, T3Protocol/Domain/Settings.swift.

### 2.3 Sending (medium, default look: small)

You can send while attachments upload (#33092). Send says why it couldn't send (#31283). Enter during image compression sends once it finishes, a failed image-only send says so, and expired uploads recover before sending (#32910). `/clear` starts a fresh session in the same thread (#30325, needs wire).

- T3: components/chat/useComposerSend.ts:298, components/chat/freshSessionArms.ts:9.
- CW: App/Sources/ComposerController.swift, Features/Composer/ComposerAttachments.swift.

### 2.4 Rich text editing (medium, default look: small)

Numbered lists nest and lift correctly, and Shift+Tab moves a nested item back out (#17138, #27016). Styled Markdown markers in the composer are editable (#30421). Wrapping a selection in backticks makes code (#14870), Backspace after a list shortcut keeps the marker, pasted CRLF keeps blank lines, and app shortcuts on Mod+B, Mod+I and Mod+E win over formatting (#34493). A rich text and Markdown source toggle landed and was reverted (#26777, #27390), so ignore it.

- T3: composer-rich-text-doc.ts, composer-markdown-source.ts, composer-list-continuation.ts.
- CW: Features/Composer/ComposerRichText.swift, Features/Composer/ComposerEditor.swift, Features/Composer/ComposerEditorBlocks.swift.

### 2.5 Context strip and provider fallback (medium, default look: small)

The new-thread context strip opens the full access menu (#30275), names the worktree folder (#28459) and shows the worktree picker at default width (#27114). When the default provider is out of usage, a new thread falls back to another, with its own reasoning setting (#26164, #27593, #27859; needs wire: fallback provider settings). Provider status banners get a Refresh button (#24861).

- T3: BranchToolbar.tsx, BranchToolbarEnvModeSelector.tsx, components/settings/ProjectDefaultsSettings.tsx, packages/shared/src/usageLimits.ts.
- CW: Features/Composer/ComposerContextStripView.swift, Features/Composer/ComposerNoticeBannerView.swift.

### 2.6 Questions and pending input (small)

Enter no longer skips an unanswered question (#23626), Claude's option previews show under their option (#34784), and typed answers survive Stop (#23617). Snoozing a thread with a pending request works (#20058, needs wire).

- T3: components/chat/usePendingThreadRequests.ts, pendingUserInput.ts.
- CW: Features/Composer, T3Store/ChildThreadInputs.swift.

## 3. Sidebar

### 3.1 Rows, shelves and the undo notice (medium, default look: yes)

The undo notice moves to the sidebar footer (#26874). Active rows show the age of the latest reply (#31825), worktree setup shows "Setting up" (#28832), and a stopped run no longer shows the green Done badge (#37475). Titles glimmer while they regenerate (#29383), and rows show linked issues beside pull requests (#38282). Threads on an unreachable environment stay in Working (#26195, then #31269 reverted that).

- T3: components/sidebar/SidebarThreadRow.tsx, components/sidebar/SidebarThreadUndoNotice.tsx, Sidebar.logic.ts.
- CW: Features/Sidebar/SidebarRowViews.swift, Features/Sidebar/SidebarUndoNoticeView.swift, Features/Sidebar/SidebarListModel.swift, T3Store/SidebarModel.swift.

### 3.2 Boring sidebar and project filter (small, default look: Labs only)

Boring sidebar can show folder threads on two lines (#26463), gets tooltips on its actions (#26477) and opens the project picker from its header (#26495). A project filter that hides every active thread says so and offers Show all projects (#35426).

- T3: components/Sidebar.tsx, components/settings.
- CW: Features/Sidebar/SidebarListView.swift, Features/Sidebar/SidebarProjectScopeView.swift.

### 3.3 Auto-settle and drop-to-add (medium)

Inactive threads settle after 7 days by default (#32325, needs wire: the auto-settle setting). Dropping a folder on the sidebar adds it as a project (#35202).

- T3: components/settings/SettingsPanels.tsx:787, components/sidebar/SidebarFolderDrop.tsx:30.
- CW: Features/Settings/GeneralSettingsView.swift, Features/Sidebar/SidebarListView.swift.

## 4. Settings

### 4.1 Welcome page (large, default look: yes)

First run is one Welcome page instead of the 3-step wizard (#33209), which T3 deleted. Onboarding rechecks an agent when its install finishes (#36477).

- T3: components/onboarding/WelcomePage.tsx:129, onboarding/welcomePage.logic.ts.
- CW: App/Sources/WelcomeOnboardingController.swift, Features/Settings/FirstRunDecision.swift.

### 4.2 Scheduled tasks (medium)

A task can run once at a date and time (#28104), run in one thread with a fresh session each time (#30326), move to another thread (#31379) and link to its thread (#31764). Deleting asks first (#23578). Needs wire: the new schedule and target fields.

- T3: components/settings/ScheduledTasksSettings.tsx, components/settings/scheduledTasksSettings.logic.ts.
- CW: Features/ScheduledTasks/ScheduledTasksSettingsView.swift, App/Sources/ScheduledTasksStore.swift.

### 4.3 Updates across machines (medium)

Update everything switches every machine between Stable and Nightly in one step (#26288), stops offering Nightly to a Stable desktop (#37490), downloads a server's update while providers install (#35346), and reconnects as soon as an updated server is ready (#35327). Checking finds provider updates on every machine (#33538).

- T3: components/sidebar/updateEverything.logic.ts, components/settings/UpdateTrackSwitchDialog.tsx:43.
- CW: Features/Sidebar/SidebarUpdateCheck.swift, App/Sources/ServerUpdates.swift, App/Sources/UpdateController.swift.

### 4.4 Agent sign-in and T3 Connect (medium)

Agents sign in through T3 Connect approval instead of a code (#33600, #33632, #33645), defaulting to Auto access (#32186). Settings shows the account's real tunnel cap (#27442). Direct links pair with the device key and renew themselves (#37990).

- T3: components/auth/ApproveAgentSurface.tsx:79, cloud/connectAgentApproval.ts.
- CW: App/Sources/T3ConnectController.swift, Features/Settings/ConnectionsSettingsView.swift.

### 4.5 Keybindings, archive and providers (small each)

You can unassign default shortcuts (#28687) and bind one to regenerate a thread's title (#33987). The archive page deletes archived threads (#22160). Removing a provider instance asks first (#29480), and an invalid provider setting is refused at its field (#35100).

- T3: components/settings/KeybindingsSettings.tsx:1438, components/settings/ArchivedThreadsPanel.tsx:47.
- CW: Features/Settings/KeybindingsLogic.swift, Features/Settings/ArchiveSettingsView.swift.

## 5. Panels

### 5.1 Diff panel (medium, default look: small)

The Diff pane reviews local commits (#19941). The pull request diff follows the file tree, with a hide-tests filter (#26730, Storybook in #29083). Changes and PR Code file lists resize (#28244), Changes totals show the comparison base (#30085), and diffs cut at the size limit say so (#36079).

- T3: components/DiffPanel.tsx:218, components/diffs/diffFileTree.logic.ts.
- CW: Features/Diff/DiffPanelView.swift, Features/Diff/DiffListView.swift, Features/Diff/DiffBaseRefChoices.swift.

### 5.2 Pull requests (large, default look: small)

PR composers complete @user mentions and #123 or !123 references (#30747, #30857). You can add PR comments to the chat (#30579). Resolved review conversations fold into avatars on their diff line (#34644), PR links jump to the comment, line, checks or commits they name (#33989), and Viewed files fold the way GitHub does (#37605). Actions show the moment you click on every host (#32774, #25761). You can manage GitHub maintainer edits (#25588) and load a too-large file's diff on demand (#37007). Cancelled checks show a gray stop sign (#34734).

- T3: components/pullRequest/PullRequestMarkdownTextarea.tsx:40, components/pullRequest/PullRequestReviewAnnotation.tsx, components/pullRequest/PullRequestCodeTab.tsx, components/pullRequest/PullRequestActionsMenu.tsx:68.
- CW: Features/PullRequests/PullRequestComposerView.swift, Features/PullRequests/PullRequestCodeView.swift, Features/PullRequests/PullRequestReviewAnnotationViews.swift, App/Sources/PullRequestsController.swift.

### 5.3 File previews (medium, partly blocked)

About 20 commits fix Word, Excel, PowerPoint, OpenDocument, EPUB, RTF, notebook, TAR, HEIC and CSV previews. The file explorer resizes (#25737), and spreadsheet previews resize rows and columns (#35548). CW never ported the Office, archive and notebook previews (PROGRESS, 3814 leftovers), so those rows wait on that task.

- T3: components/files/FilePreviewPanel.tsx:240, packages/shared/src/delimitedPreview.ts.
- CW: Features/Files/NativeFilePreviewView.swift, Features/Files/FilesPanelView.swift.

### 5.4 Usage page (medium)

Usage totals filter by provider and model (#28952, needs wire). Fable resets are offered apart from weekly resets (#34106), cost and tokens show before the full scan (#33993), and each figure reaches screen readers with its label (#37238, #37241).

- T3: components/usage/UsagePage.tsx.
- CW: Features/Usage/UsagePageView.swift, Features/Usage/UsageLimitsView.swift.

### 5.5 Add project (medium)

Add project lists only GitHub until you turn other hosts on (#34978). Clones can go into ghq-style host/owner/repo folders (#24904, needs wire). Folder search matches substrings and fuzzy subsequences (#26376), and Tab completes folder names (#28243).

- T3: components/CommandPalette.tsx, components/settings/SourceControlSettings.tsx.
- CW: App/Sources/PaletteAddProject.swift, App/Sources/ProjectCloneController.swift.

### 5.6 Notifications and screen readers (medium)

Routine success notifications are gone (#36527). Completion sounds play without delay (#29146), snoozed threads send no completion alerts (#27458), and alerts missed during a disconnect fire on reconnect (#24493). Screen readers hear the agent's messages and steps during a turn (#33900), and the window title leads with the thread's status (#34697).

- T3: ThreadNotificationCoordinator.logic.ts, components/chat/ThreadActivityAnnouncer.tsx:45.
- CW: App/Sources/ThreadNotificationCoordinator.swift, Features/Thread/TimelineView.swift.

## 6. Small fixes, one batch per area

Each batch is the `misc-*` section of the appendix. They are many small, independent fixes. An agent takes one batch, checks each row against CW, and ports or marks it.

1. Thread, 266 rows: large. Split it in two by appendix order.
2. Pull requests and git, 161 rows: large. Split it in two.
3. Composer, 120 rows: large.
4. Settings, 112 rows: large.
5. Sidebar, 74 rows: medium.
6. Connections, 46 rows: medium.
7. Terminal, 35 rows: medium. Many are link detection in terminal-links.ts, which CW does itself.
8. Usage, 34 rows: medium.
9. Files 22, diff 18, browser 18, device 10, palette 4 and issues 2: small each.

## 7. Design changes

The range is incremental. Nothing restyles a whole surface the way 3814's new design did. apps/web/src/index.css gained 129 lines and lost 25 across 20 commits, and components/ui changed 846 lines over 31 files, mostly tests.

The stylesheet-level changes are these:

- `--app-scrollbar-thumb` and `--app-scrollbar-thumb-hover` are new tokens, and dark-mode thumbs are now visible (#30031).
- Sent messages use `--contrast-message-foreground` for text and inline code, with code at 10% of that color (#26888).
- Sent messages keep list numbers and leading spaces with a `--list-gutter` rule and `[data-leading-whitespace]` (#33820, #38079).
- `.chat-markdown-file-link` is a new class that lays out file chips inline with their icon (#32334).
- `font-variant-ligatures: none` applies to the preview address bar (#21579), while the composer gains arrow ligatures (#27909).
- Bold weight is restored in rendered Markdown (#25694), and plain text code blocks drop their code styling (#27144).
- Stacked composer banners lose their dark seams (#32683).
- Sidebar metadata uses the theme's colors in dark mode (#27268).
- `.diff-render-surface` styles the search panel of @pierre/diffs 1.7 (#33627).

Component changes that move pixels in the default themes:

- The user message bubble and its new shapes, in section 1.1.
- The model and effort control, in section 2.1.
- The thread details card's usage block, in section 1.4.
- The Welcome page, in section 4.1.
- Dialog titles get a readable line height (#30527).
- Popovers fade out in place (#26716).
- Tooltips wrap naturally (#36948).
- Sparkles icons are gone everywhere (#25422).
- Q&A option outlines are visible in every theme (#34178).

Themes gained full-size background images (#36680) and CSS of up to 100,000 characters that agents can write (#35247, #37781). Those extend the theme system, and the default themes don't use them.

## 8. New features with no CW counterpart

- Issues page and issue panel for GitHub, GitLab, Azure DevOps and Linear, with issues linked to threads and issue tools for agents (#19260, #19270, #19274, 22 rows). Needs wire.
- Translation: Settings switches the UI language, and the whole app ships in 10 languages (#31313, #37893).
- Side chats run beside the main thread, opened with `/side` or `/btw` (#26901, 19 rows).
- Thread tags, with tagged threads hidden while you record your screen (#29053).
- Prompt suggestions after Claude and Codex turns, in Labs (#28047).
- Reply to an assistant response from its hover actions (#33124).
- @-mention a model to name it for the agent (#31207).
- Text generators let model APIs write titles, commits and transcript cleanup (#33147).
- "Use T3 Code in another app" sets up T3's MCP server in other apps, including the Grok Bot (#33196).
- Theme background images and agent-written theme CSS (#36680, #35247).
- Pin favorite projects and archive old ones (#26154).
- Turn a No project thread into a project (#26767).
- Reclaim freed database space in one click (#32941).
- T3 Connect requires approval for new devices (#36419).
- Saved filter views for pull requests and issues (#29387, #37963).
- Regenerate a thread's title from a shortcut, with the title glimmering meanwhile (#33987, #29383).
- GitHub star prompt after 5 prompts, with confetti (#27832, #29922, #29987).
- Pi: import terminal sessions, extension status, Fast and Ultrafast tiers (#27515, #23901, #33177).

These are skipped here. Each needs the user's go-ahead:

- Voice dictation, local and cloud, 20 rows. CW has no voice input.
- Secret providers such as 1Password, 10 rows. T3 hides them behind `T3CODE_FEATURE_SECRETS`.
- Simlock simulator pool and Expo simulators, 6 rows, marked alpha.
- Managed organization policy, including Windows Group Policy (#27197, #29862).

## 9. PROGRESS.md open tasks this range touches

- "Finish panel and dialog screen fidelity at 3824" (two entries): the references move again. Message shapes, the model control, the details card and the Welcome page change the default look, so recapture from 4928 before finishing the remaining assertions.
- "3814 leftovers skipped in phase 1": extended. Office, notebook, archive and EPUB previews gained about 20 fixes (section 5.3), and the asset URL item gains #29741.
- "T3 Connect tunnel usage from Nightly 3824": extended by #27442, which shows the account's real tunnel cap.
- "Deferred work for long threads from Nightly 3824": extended. #29114 skips a rebuild when deferred work expands, and #35071 loads threads while the socket connects.
- "Nightly 3669: pull requests use each host's term": extended by the GitLab, Forgejo and GitCafe fixes in the PR batch, such as label edits (#30483) and overview threads (#30575).
- "Nightly 3669 smaller leftovers": its right-to-left item gains #24050, #26095 and #36876.
- "Remaining 3234 parity": its ANSI colors item gains #21542 and #24042 for command output.
- "Regenerate the other component references with 3473's stylesheet": superseded. Regenerate from the 4928 stylesheet instead.
- "Two small differences found with it": unchanged. 4928 still renders sanitized HTML in replies.
- "Remaining 3315 parity: relative time labels": unchanged. #31825 adds the latest-reply age to active rows, which uses the same labels.

None of the 32 open tasks becomes obsolete.

## 10. Wire needs collected

The wire audit should confirm these: user message `modelSwitch`, compact checkpoint payloads, threads loading during connect, provider `subProviders`, model catalog refresh, fallback provider settings, `/clear` fresh sessions, snoozing pending input, the auto-settle setting, scheduled task once-at and fresh-session fields, usage totals filters, ghq clone layout, issue links and tools, saved filter views, T3 Connect device approval, the database vacuum call, text generator settings, thread deep links for Copy thread (#26290), and terminal attach history paging (#33942).
