# F. UI inventory: screens and states to screenshot

Source: official T3 Code v0.0.46-nightly.20261009.2861 web UI (`apps/web/src`). Shorthand: `comp/` = `apps/web/src/components/`, `web/` = `apps/web/src/`. Capture each state in light and dark, at default window width (about 1280x800) unless noted. Also capture a narrow width (about 900) for the ones marked [narrow].

## Demo data to prepare (once)

Build the data first; most states below reuse it.

- Projects: P1 "api-server" (git repo, remote on GitHub, has a custom icon), P2 "marketing-site" (git repo, favicon), P3 non-git folder, plus a "No project" scratch thread. At least one project on a second environment (remote machine) to show environment badges.
- Threads in P1, one per state: running (streaming text plus live tool calls), waiting for approval, waiting for user input (2 questions, one with options), finished (Done), failed, usage-limited (Limited, with reset time), pinned (x2), snoozed, settled (x3), archived, unsent draft, goal active (`/goal`), a thread with a proposed plan, a thread linked to a PR, a forked thread, a thread with subagents.
- One long "kitchen sink" thread containing: user message with image + file chip + terminal chip, assistant markdown (headings, lists, table, task list, code blocks in 3 languages, GitHub alert, link to file:line, inline image, Mermaid block), thinking rows, command execution (success, failure, long output), file change (multi-file), file search, web search, todo list, MCP tool call, dynamic tool call, context compaction divider, HTML render, MCP app, secret request, worktree setup card, error row, queued messages.
- Git state: P1 with uncommitted changes (modified, added, deleted, renamed, 1 large file), 2 commits ahead, a worktree thread, a branch with an open PR (checks mixed pass/fail/pending, reviews, comments, 3 files), a PR stack of 3, a merged PR, a draft PR.
- Settings data: two provider instances (Claude, Codex) healthy, one not signed in, one update available; one custom theme; one scheduled task (cron) plus one webhook task with delivery history; usage history for at least 3 providers and one limit window; one paired remote client.
- Terminal: 2 terminals, one split, running a dev server, and one with colorful output.
- Preview: a local dev server on localhost:3000 (needs webview decision first).
- Fresh data directory (for first-run wizard), with seeded Claude/Codex history for the import step.

Note: do not write to `~/.t3`. Run a separate T3 server with a temporary base dir (`--base-dir`) for all captures; this inventory only lists what to capture.

## Top 30 states (most important first)

| # | State | How to reach it | Demo data | Components |
|---|---|---|---|---|
| 1 | Main window, thread view with a running turn | Open P1, click the running thread | Streaming assistant text, 3 live tool calls, composer with Stop button | comp/ChatView.tsx, comp/chat/MessagesTimeline.tsx, comp/chat/WorkLog.tsx, comp/chat/ComposerPrimaryActions.tsx |
| 2 | Sidebar fully populated | App open, sidebar visible | All projects, Pinned, Active (mixed statuses), Snoozed, Settled shelves expanded | comp/Sidebar.tsx, comp/ThreadStatusIndicators.tsx |
| 3 | Finished thread, kitchen-sink timeline (top, middle, bottom scroll positions) | Open the long thread, scroll | Kitchen-sink thread | comp/chat/MessagesTimeline.tsx, comp/ChatMarkdown.tsx, comp/chat/HighlightedCodeLines.tsx |
| 4 | Empty new-thread draft (hero, composer, branch toolbar) | Cmd+N or "New thread" on P1 | P1 git project | comp/chat/DraftHeroHeadline.tsx, comp/chat/ChatComposer.tsx, comp/BranchToolbar.tsx |
| 5 | Approval request replacing the composer | Open the waiting-approval thread | Pending command approval with long command | comp/chat/ComposerPendingApprovalPanel.tsx, comp/chat/ComposerPendingApprovalActions.tsx |
| 6 | User input request (questions with options and free text) | Open the waiting-input thread | 2-question request, options plus "other" | comp/chat/ComposerPendingUserInputPanel.tsx |
| 7 | Command palette, default page | Cmd+K | Several recent threads | comp/CommandPalette.tsx, comp/CommandPaletteContent.tsx, comp/CommandPaletteResults.tsx |
| 8 | Command palette with search results (projects, threads, settings, message matches) | Cmd+K, type "api" | Matching content in threads | comp/CommandPalette.logic.ts, comp/ThreadSearchMatch.tsx |
| 9 | Diff panel, split view with file tree | Cmd+D on a thread with changes | Multi-file changes, one large | comp/DiffPanel.tsx, comp/diffs/DiffFileTree.tsx, comp/diffs/StyledDiffCodeView.tsx |
| 10 | Diff panel unified view with review comment annotation | Diff panel, layout toggle, click line gutter to comment | Same | comp/diffs/AnnotatableCodeView.tsx, comp/diffs/DiffCommentAnnotation.tsx |
| 11 | Terminal drawer open under chat, with split | Cmd+J, then Cmd+D | Two terminals, colorful output | comp/ThreadTerminalDrawer.tsx |
| 12 | Right panel with Files tab and an open file | Cmd+Alt+B, Files tab, click a file | P1 tree; a .ts file open | comp/files/FileBrowserPanel.tsx, comp/files/FilePreviewPanel.tsx |
| 13 | Model picker open | Cmd+Shift+M in composer | Several providers and models, favorites | comp/chat/ProviderModelPicker.tsx, comp/chat/ModelPickerContent.tsx, comp/chat/ModelPickerSidebar.tsx |
| 14 | Composer with slash menu | Type "/" | Provider commands and skills | comp/chat/ComposerCommandMenu.tsx |
| 15 | Composer with @ file mention menu and chips in text | Type "@src" | P1 files; draft with image and terminal chips | comp/chat/ComposerCommandMenu.tsx, comp/composerInlineChip.ts |
| 16 | Settings > General | Cmd+, then General (scroll top, middle, bottom) | Default settings | web/routes/settings.general.tsx, comp/settings/SettingsPanels.tsx |
| 17 | Settings > Appearance (theme gallery, fonts) | Settings > Appearance | One custom theme | comp/settings/ThemeSettings.tsx, comp/settings/SettingsPanels.tsx |
| 18 | Settings > Providers with instance cards | Settings > Providers | 2 healthy, 1 unauthenticated, 1 update available | comp/settings/ProviderSettingsPanel.tsx, comp/settings/ProviderInstanceCard.tsx |
| 19 | Settings > Keybindings | Settings > Keybindings | Defaults, one conflict | comp/settings/KeybindingsSettings.tsx |
| 20 | Sidebar thread context menu | Right-click a thread | Pinned and unpinned thread | comp/Sidebar.tsx, comp/threadActionMenu.logic.ts |
| 21 | Git actions menu open | Header Git actions button on P1 thread | Uncommitted changes, ahead commits | comp/GitActionsControl.tsx |
| 22 | Commit dialog with generated message | Git actions > Commit | Staged changes | comp/GitActionsControl.tsx |
| 23 | Pull requests page (list with filters) | Command palette "Open pull requests" | 8+ PRs mixed states | web/routes/_chat.pull-requests.tsx, comp/pullRequest/PullRequestListRow.tsx, comp/pullRequest/PullRequestListFilters.tsx |
| 24 | PR detail: Summary, Timeline, Code tabs | Click a PR in list | PR with checks, reviews, comments | comp/pullRequest/PullRequestDetailPanel.tsx, comp/pullRequest/PullRequestSummaryTab.tsx, comp/pullRequest/PullRequestTimelineTab.tsx, comp/pullRequest/PullRequestCodeTab.tsx |
| 25 | Proposed plan card plus follow-up banner | Open plan thread | Plan with 6 steps | comp/chat/ProposedPlanCard.tsx, comp/chat/ComposerPlanFollowUpBanner.tsx |
| 26 | Usage page (Cost tab, Tokens tab, Limits tab) | Cmd+U then c, t, l | History for 3 providers, limit windows | web/routes/usage.tsx, comp/usage/UsagePage.tsx, comp/usage/UsageLimitsPooled.tsx |
| 27 | Welcome wizard (3 steps) | Launch against a fresh data dir | Seeded Claude/Codex history | comp/onboarding/WelcomeWizard.tsx, comp/onboarding/FirstRunGate.tsx |
| 28 | Sidebar drag in progress (Pin/Settle badge) | Drag a thread over the Pinned and Settled headers | Pinned and active threads | comp/Sidebar.drag.ts, comp/Sidebar.motion.ts |
| 29 | Queued messages and Steer controls while running | Send 2 messages during a running turn | Running thread | comp/chat/QueuedRunsControl.tsx, comp/chat/ComposerPrimaryActions.tsx |
| 30 | Limited thread with recovery banner | Open the limited thread | Limit with reset time | comp/chat/UsageLimitRecoveryBanner.tsx, comp/Sidebar.tsx |

## Remaining states by area

### Sidebar and navigation

| State | How to reach it | Demo data | Components |
|---|---|---|---|
| Sidebar collapsed | Cmd+B | any | comp/AppSidebarLayout.tsx, comp/ui/sidebar.tsx |
| Project row menu | Right-click project | any | comp/Sidebar.tsx |
| Project search/filter active | Click search icon, type | many projects | comp/Sidebar.tsx |
| Thread hover card | Hover a thread row 1 s | thread with PR | comp/ThreadHoverCard.tsx |
| Multi-select with bulk bar | Cmd+click 3 threads | any | web/threadSelectionStore.ts, comp/Sidebar.tsx |
| Inline rename | Context menu > Rename | any | comp/Sidebar.tsx |
| Custom snooze dialog | Context menu > Snooze > Custom | any | comp/CustomSnoozeDialog.tsx |
| Undo notice after settle | Settle a thread | any | comp/sidebar/SidebarThreadUndoNotice.tsx |
| Working section folded (beta on) | Enable setting, run 2 threads | running threads | comp/Sidebar.tsx |
| Unsent draft row | Start draft, leave | draft | comp/Sidebar.tsx |
| Update pill (available, downloading, ready) | Needs a mocked update state | mock | comp/sidebar/SidebarUpdatePill.tsx |
| Provider update pill | Mock provider outdated | mock | comp/sidebar/SidebarProviderUpdatePill.tsx |
| Empty app: no projects hero | Fresh data dir after wizard | none | comp/NoProjectsHero.tsx |
| No active thread state | Project selected, no thread | P1 | comp/NoActiveThreadState.tsx |
| Remote environment projects with badge | Connect a second env | second env | comp/ProjectEnvironmentBadge.tsx |

### Thread view

| State | How to reach it | Demo data | Components |
|---|---|---|---|
| Thread header with title edit and actions menu | Click title | any | comp/chat/ChatHeader.tsx |
| Thread details panel | Header details button | PR, worktree | comp/chat/ThreadDetailsPanel.tsx |
| Work log collapsed vs expanded (show tool calls) | Click work toggle | many tool calls | comp/chat/WorkLog.tsx |
| Command execution card expanded with long output | Expand a tool call | long output | comp/CommandBlock.tsx |
| File change card with diff stats | Finished edit turn | multi-file | comp/chat/WorkLog.tsx, comp/chat/ChangedFilesTree.tsx |
| Thinking row open/collapsed | Click thinking | reasoning model | comp/chat/MessagesTimeline.tsx |
| Todo list card | Turn with todo | todos | comp/chat/WorkLog.tsx |
| Context compaction divider | Thread after /compact | compaction | comp/chat/TimelineSystemDivider.tsx |
| Error banner and error row | Failed thread | failure | comp/chat/ThreadErrorBanner.tsx |
| Provider status banner | Provider not signed in | broken provider | comp/chat/ProviderStatusBanner.tsx |
| Subagents bar and tooltip | Thread with subagents | subagents | comp/chat/ProviderSubagentBar.tsx |
| Fork and handoff rows | Forked thread | fork | comp/chat/ThreadRelationshipsControl.tsx |
| Worktree setup card running | New worktree thread start | setup script | comp/chat/WorktreeSetupCard.tsx |
| Secret request card | Agent calls request_secret | mock | comp/chat/SecretRequestCard.tsx |
| Find in thread bar with matches | Cmd+F | long thread | comp/chat/ThreadFindBar.tsx |
| Scroll-to-bottom pill, minimap | Scroll up during stream | long | comp/chat/timelineMinimapItems.ts |
| Assistant selection toolbar | Select assistant text | any | comp/chat/AssistantSelectionToolbar.tsx |
| Image expanded dialog / gallery | Click image | images | comp/chat/ExpandedImageDialog.tsx |
| Goal row above composer | /goal in a thread | goal | comp/chat/ComposerBanner.tsx |
| Context window meter popover | Click meter | long thread | comp/chat/ContextWindowMeter.tsx |
| Mermaid diagram (needs webview decision) | Assistant message with mermaid | mermaid | comp/chat/MermaidDiagram.tsx |
| HTML render and expanded view (needs webview decision) | Thread with html render | HTML page | comp/chat/HtmlRenderFrame.tsx |
| MCP app, inline and fullscreen (needs webview decision) | Thread with MCP app | MCP server | comp/chat/McpAppFrame.tsx |
| Wide, comfortable, full chat width | Settings > Appearance | any | comp/chat/chatCanvasLayout.ts |

### Composer

| State | How to reach it | Demo data | Components |
|---|---|---|---|
| Composer focused with multiline text and code block | Type | none | comp/ComposerPromptEditorTiptap.tsx, comp/chat/ComposerCodeBlockNodeView.tsx |
| Image thumbnail shelf, expanded preview | Paste images | images | comp/chat/ComposerImageThumbnail.tsx |
| Attached file chip preview | Attach a file, click chip | files | comp/files/AttachmentFilePreview.tsx |
| Skill picker ($) | Type "$" | skills | comp/chat/ComposerCommandMenu.tsx |
| PR picker (#) | Type "#" | PRs | comp/chat/ComposerCommandMenu.tsx |
| Traits picker (effort, speed) | Cmd+Shift+E | model with traits | comp/chat/TraitsPicker.tsx |
| Access mode picker | Cmd+Shift+A | any | comp/chat/CompactComposerControlsMenu.tsx |
| Prompt stash menu with badge | Cmd+S | stash entries | comp/chat/ComposerStashMenu.tsx |
| Branch picker, workspace-mode menu | Cmd+Shift+G / X | git project | comp/BranchPicker.tsx, comp/BranchToolbarEnvModeSelector.tsx |
| Environment selector on new thread | Cmd+Shift+H | 2 envs | comp/BranchToolbarEnvironmentSelector.tsx |
| Compact composer at narrow width [narrow] | Resize window | any | comp/composerFooterLayout.ts |
| Composer banners (clone progress, server update) | Mock | mock | comp/chat/ComposerBannerStack.tsx |
| Usage limits chip in composer | Provider with limits | limits | comp/chat/ComposerUsageLimits.tsx |
| Rich text off (plain markdown) | Setting off | any | comp/ComposerPromptEditor.tsx |

### Right panel, files, browser, device

| State | How to reach it | Demo data | Components |
|---|---|---|---|
| Right panel tab strip with several tabs and + menu | Open diff, files, terminal, file | any | comp/RightPanelTabs.tsx |
| Right panel narrow sheet [narrow] | Resize window | any | comp/RightPanelSheet.tsx |
| Go to file (Cmd+P) | Cmd+P | P1 | comp/files/ProjectFilePicker.tsx |
| Project content search (Cmd+Shift+F) | Cmd+Shift+F | P1 | comp/search/ProjectContentSearchDialog.tsx |
| File viewer: markdown rendered/source, CSV table, image, audio | Open sample files | sample files | comp/files/FileMarkdownPreview.tsx, comp/files/DelimitedTablePreview.tsx |
| File editor with unsaved edit | Type in file | any | comp/files/FilePreviewPanel.tsx |
| Diff with whitespace hidden, collapsed unchanged ranges | Settings toggle | any | comp/diffs/StyledDiffCodeView.tsx |
| Diff find open | Click diff, Cmd+F | any | comp/diffs/codeViewSearch.test.ts |
| Browser panel empty state with local servers (needs webview) | + > Browser | dev server on :3000 | comp/preview/PreviewEmptyState.tsx |
| Browser panel loaded page, URL bar, more menu (needs webview) | Open localhost:3000 | dev server | comp/preview/PreviewPanel.tsx, comp/preview/PreviewMoreMenu.tsx |
| Browser unreachable (needs webview) | Open dead port | none | comp/preview/PreviewUnreachable.tsx |
| Browser element pick + annotation (needs webview) | Pick tool | dev server | desk/preview/PickPreload.ts |
| Browser floating mini player (needs webview) | Float | dev server | comp/preview/ThreadPreviewMiniPlayer.tsx |
| Device panel setup / live device / tools drawer | + > Device | Xcode simulator | comp/device/DeviceSetup.tsx, comp/device/DevicePanel.tsx, comp/device/DeviceToolsPanel.tsx |
| Terminal context menu, terminal "add to chat" | Right-click selection | output | comp/ThreadTerminalDrawer.tsx |

### Git and pull requests

| State | How to reach it | Demo data | Components |
|---|---|---|---|
| Publish repository dialog | Git actions > Publish on local-only repo | local repo | comp/GitActionsControl.tsx |
| Create PR dialog with generated title/body | Git actions > Create PR | pushed branch | comp/pullRequest/PullRequestComposer.tsx |
| PR stack header and layers | Open stacked PR | stack | comp/pullRequest/PullRequestStackHeader.tsx, comp/pullRequest/PullRequestStackLayers.tsx |
| PR checks popover | Click checks | mixed checks | comp/pullRequest/PullRequestChecksPopover.tsx |
| PR code tab with viewed marks | Code tab, tick a file | PR with files | comp/pullRequest/PullRequestCodeTab.tsx |
| PR review form | Review button | PR | comp/pullRequest/PullRequestReviewForm.tsx |
| PR edit title/body, labels, reviewers pickers | Edit button | PR | comp/pullRequest/PullRequestEditButton.tsx, comp/pullRequest/PullRequestLabelPicker.tsx |
| PR merge menu (method choices) | Merge | mergeable PR | comp/pullRequest/PullRequestDetailPanel.tsx |
| Link pull request dialog | Palette: Link pull request | threads, PRs | comp/pullRequest/LinkPullRequestDialog.tsx |
| PR link right-click menu | Right-click PR link in thread | linked PR | comp/pullRequest/pullRequestLinkContextMenu.ts |
| PRs unavailable state | No provider auth | none | comp/pullRequest/PullRequestsUnavailableState.tsx |
| Create PR thread dialog | PR list > open in thread | PR | comp/PullRequestThreadDialog.tsx |
| Clone toast with progress and failure | Palette: Add project > clone | repo URL | comp/ProjectCloneToastCoordinator.tsx |
| Add project flows: local folder browser, clone providers, new project name | Palette: Add project | none | comp/CommandPalette.tsx |

### Settings pages (each page, top and scrolled)

| State | How to reach it | Demo data | Components |
|---|---|---|---|
| Settings shell with search results | Cmd+, then type "font" | none | comp/settings/SettingsSidebarNav.tsx |
| Project settings page, overrides inherited vs overridden | Settings > Project > P1 | P1 with an override | comp/settings/ProjectSettingsPanel.tsx, comp/settings/ProjectDefaultsSettings.tsx |
| Project actions list + editor | Project > Actions > Add | scripts | comp/settings/ProjectActionsSettings.tsx, comp/projectScriptEditor.tsx |
| Appearance: theme editor open | Appearance > Create theme | none | comp/settings/ThemeEditorPanel.tsx |
| Theme import dialog | Appearance > Import | none | comp/settings/ThemeImportDialog.tsx |
| SnapShots settings and setup dialog | Settings > SnapShots, toggle on | permissions mocked | comp/settings/SnapShotSettings.tsx, comp/settings/SnapShotSetupDialog.tsx |
| Add provider instance wizard (driver step, ACP registry, auth step) | Providers > Add | none | comp/settings/AddProviderInstanceDialog.tsx |
| Provider card expanded (config form, models, custom model) | Expand a provider | Claude, Codex | comp/settings/ProviderSettingsForm.tsx, comp/settings/ProviderModelsSection.tsx |
| Integrations: devices and browser | Settings > Integrations | none | comp/settings/IntegrationsSettings.tsx |
| Scheduled tasks list, editor, webhook deliveries | Settings > Scheduled Tasks | 2 tasks | comp/settings/ScheduledTasksSettings.tsx |
| Source control providers, GitHub accounts, writing style | Settings > Source Control | gh signed in | comp/settings/SourceControlSettings.tsx |
| Storage | Settings > Storage | old worktrees | comp/settings/StorageSettings.tsx |
| Connections: this machine, environments, network access, authorized clients, T3 Connect | Settings > Connections | paired client | comp/settings/ConnectionsSettings.tsx |
| Pairing link with QR | Connections > Create link | none | comp/settings/ConnectionsSettings.tsx, comp/ui/qr-code.tsx |
| Add environment dialog / SSH | Connections > Add | none | comp/settings/ConnectionsSettings.tsx |
| Archive list | Settings > Archive | archived threads | web/routes/settings.archived.tsx |
| Diagnostics (processes, resource history, traces) | General > About > Diagnostics | none | comp/settings/DiagnosticsSettings.tsx |
| Open source licenses | General > About | none | comp/settings/OpenSourceLicenses.tsx |

### Usage, notifications, onboarding, misc

| State | How to reach it | Demo data | Components |
|---|---|---|---|
| Usage model breakdown dialog | Usage > click model | usage | comp/usage/UsageModelDialog.tsx |
| Usage price overrides | Usage > prices | usage | comp/usage/UsagePriceOverrides.tsx |
| Add limit source dialog | Usage > Limits > add | none | comp/settings/AddUsageLimitSourceDialog.tsx |
| Usage empty / scanning states | Fresh env | none | comp/usage/UsagePage.tsx |
| Toasts: error, success, undo, copy | Trigger copy actions and failures | any | comp/ui/toast.tsx |
| Confirm dialogs (delete thread, unpin, archive) | Delete from menu | any | comp/ConfirmDialogHost.tsx |
| Keybindings warning banner | Put malformed keybindings.json (test server only) | broken file | comp/KeybindingsConfigWarning.tsx |
| Wizard: connect computers, T3 Connect list, agents check, import list | Fresh data | seeded history | comp/onboarding/WelcomeWizard.tsx |
| Wizard error states (Still connecting, Could not read settings) | Mock | mock | comp/onboarding/FirstRunGate.tsx |
| Pair route | Open /pair#token | token | web/routes/pair.tsx |
| Connect-agent approval | Open /connect-agent | outside agent request | web/routes/connect-agent.tsx |
| Quit hold overlay | Hold Cmd+Q | none | comp/QuitHoldOverlay.tsx |
| Permission checklist | Mac permission flows | none | comp/permissions/PermissionChecklist.tsx |
| Slow RPC toast, server update banner, version skew block | Mock | mock | comp/SlowRpcRequestToastCoordinator.tsx, comp/ServerUpdateAction.tsx, web/versionSkew.ts |
| Native macOS app menu bar (each menu open) | Desktop app only | none | desk/window/DesktopApplicationMenu.ts |
| Window chrome: hidden-inset title bar and traffic lights | Desktop app only | none | desk/window/DesktopWindow.ts |
| Dock badge with count | Desktop app, finish a thread while unfocused | notification | desk/ipc/methods/notificationBadge.ts |

## Capture notes

- The web UI served by the server is the closest reference for all states except desktop-only items (menus, title bar, dock badge, SnapShot), which need the Electron app on macOS.
- Keep a fixed clock and fixed demo timestamps so relative times (for example "2h") match across captures.
- Capture hover, focus, pressed and disabled states for primary buttons, thread rows, menu items and tabs separately from the screens above.
