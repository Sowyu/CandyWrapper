# T3 Code Nightly: 3315 to 3473

Range: v0.1.1-nightly.20261018.3315 .. v0.1.2-nightly.20261021.3473, 1,110 commits, 3,385 files. Target commit 1688f96568. Line numbers refer to the 3473 tree. "CW" is CandyWrapper, paths under Packages/CandyKit/Sources unless they start with App/.

The range is 883 fix commits, 70 refactors, 43 perf and 36 features. By scope it is 334 web, 299 server, 137 mobile and 56 desktop commits. The contracts diff is additive: nothing in it stops a 3315-era client, and T3 shaped the risky additions so old clients keep decoding (EAS hosts travel in their own `easHosts` list, webhook outcomes beyond the known ones are left out unless the client asks for them). CW decodes the config, the shell and all 113 sandbox threads from a 3473 server, and derives their timelines without unknown rows (fixtures/transcripts/22-nightly-3473.jsonl, `NightlyCompatTests.recorded3473ConfigShellAndThreadDecode`).

## 1. Wire changes

### Behavior a 3315-era client gets wrong

1. `thread.stop` moved from the internal commands to the public ones, behind capability `threadStop` (packages/contracts/src/orchestrationV2.ts:2565, environment.ts:128). The web client sends it when it knows no run (packages/client-runtime/src/operations/commands.ts:803-811). The server then interrupts the newest live run, or the latest run when only background work is pending, cancels idle delegated children, and records that Stop reached the run when the interrupt fails (apps/server/src/orchestration-v2/Orchestrator.ts:10032-10110). CW sent `run.interrupt` for the active run only, so commands left from earlier turns and idle delegated tasks kept running. Fixed: App/Sources/ComposerController.swift `stop()` sends `thread.stop` when the descriptor has the capability.
2. Webhook delivery outcomes `duplicate`, `coalesced` and `filtered` (scheduledTask.ts:320-325). The server drops rows with outcomes a client didn't ask for unless the list request carries `acceptAnyOutcome` (scheduledTask.ts:362, 376). Fixed: Features/ScheduledTasks/ScheduledTasksSettingsView.swift sends the flag, and T3Protocol/Domain/ScheduledTasks.swift labels the new outcomes, `pendingWindow` as "Opened window", and unknown ones with spaces (scheduledTasksSettings.logic.ts:131-147, ScheduledTasksSettings.tsx:335-347).
3. Terminal attach takes `resume` (terminal.ts:57). T3 resubscribes with `resume: true` after the first reply, so the server keeps a closed terminal closed across a reconnect (packages/client-runtime/src/state/terminal.ts:44-62). Without it CW reopened a terminal the user closed once the connection dropped and came back. Fixed in App/Sources/TerminalController.swift.

### Degrades

4. Thread shells carry `latestRunStopRequested` and `blockedOnThreadWait`, and pending request summaries carry `blocking` (orchestrationV2.ts:1828, 1834, 1792). A turn waiting on another thread reads as Waiting, an async question no longer flips a working thread to Awaiting input (Sidebar.logic.ts:894-921, 1061-1154; models.ts:226-263), and a stopped run doesn't announce "Thread completed" (ThreadNotificationCoordinator.tsx:154-160). Fixed in T3Protocol/Domain/ThreadShell.swift, T3Store/SidebarModel.swift and T3Store/ThreadNotifications.swift.
5. User messages carry `workflowScript` (orchestrationV2.ts:1099): the message is a provider-native workflow's script, and clients show a "Workflow started" block with the script behind a disclosure (apps/web/src/components/chat/WorkflowOpeningBlock.tsx). CW showed the whole script as a user bubble. Fixed: Features/Thread/TimelineMessageRows.swift draws the opening block; the workflow's phases and agents need the parent thread's projection and are still missing.
6. `ServerConfig.lastEventLoopStall` (server.ts:593-600, 637) says why a host stopped answering. T3 toasts "<host> froze for <N>s" once per stall (packages/client-runtime/src/connection/hostFreeze.ts, apps/web/src/components/HostFreezeToastCoordinator.tsx). Fixed: ComposerController toasts it from the config snapshot.
7. T3 Connect link state carries `reachability` (environmentHttp.ts:425-505), shown in Host access. Relay errors carry `endpointFailure`, `endpointStatus` and `provisioningStage` (relay.ts:389-398, 546), which feed T3's new connection diagnosis. CW shows reachability in Host access and the provisioning stage; the diagnosis is open (section 2).
8. Context transfers carry `sourceTokenUsage` (orchestrationV2.ts:189), so a fork keeps its parent's context meter, as CW now does. Token usage gained `autoCompactThreshold`, which CW already reads, and `promptCacheExpiresAt`, which only the server's idle compaction uses (orchestrationV2.ts:174-175).
9. Device state sends EAS cloud simulator hosts as `easHosts` beside `hosts` (device.ts:221-246), with settings key `easDeviceHosts` (settings.ts:1159) and RPC `device.easAccount` (rpc.ts:466, 1570). CW ignores both, so EAS hosts don't appear. Their streams need WebRTC, a question for the user (PROGRESS.md).

### Additions CW can ignore or uses later

10. RPCs: `projects.listIgnoredFiles` behind `ignoredFileListing` (rpc.ts:385, 1225; project.ts:309-324) for "Add to another machine", `pullRequests.changeBreakdown` (rpc.ts:543, 1050; pullRequest.ts:696-708), and POST /api/connect/reachability (environmentHttp.ts:778), which only T3's CLI calls.
11. Settings: client `browserSearchEngine` and `browserCustomSearchUrl` (settings.ts:270-282), `mathRenderingEnabled` (settings.ts:484, off by default), server `compactIdleThreads` (settings.ts:1163, off by default). `sourceControlWritingStyle` may now be a legacy string in settings.json, but the server always sends the struct (settings.ts:822-841).
12. Smaller fields: `ServerProvider.installedVersion` and workspace `optionDescriptors` (server.ts:262, 137), `ThreadPullRequestLink.repositoryWebUrl` and `endedWatch` (threadPullRequest.ts:105, 112), git `upstreamRef`, `workingTree.rootPath`, `isAtRepositoryRoot` and reason `ref_not_found` (git.ts:88, 226, 281, 364), clone `stalled` (projectClone.ts:35, 103), `RemoteOpenTarget.username` with `buildRemoteOpenUrl` taking a username and `isFile` (editor.ts:180-236), question option `preview` (orchestrationV2.ts:1139), workflow agent `completedAt` (:674), `forkHeadMessageId` (:851), asset `checkedPath` (assets.ts:211), a string agent session `inode` (agentSessions.ts:18) and ACP search `limit` up to 512 (acpRegistry.ts:54).
13. PR capability and permission arrays decode forward compatibly (pullRequest.ts:267, 292). CW reads them as strings already.
14. Client-side scope guards: `preview.close` needs preview operate, and a stacked action that creates a PR for a thread needs source-control write plus orchestration read (clientRpcPermissions.ts:16, 67-74). The server enforces the same. CW sessions paired as owner are unaffected.

### Server behavior with no client change

- The shell stream coalesces deltas for slow clients, so sequences skip, and fails with "The live event buffer is full" past 1,000 items or 8 MB unacknowledged (apps/server/src/orchestration-v2/ShellStream.ts, LiveStreamBudget.ts, #14859). CW tolerates gaps (T3Store/ShellReducer.swift) and its supervisor resubscribes from the last sequence after a stream failure (T3Client/ConnectionSupervisor.swift `subscribe`). It acks each chunk as the store takes it.
- Requests that arrive before the HTTP handlers attach get 503 with Retry-After (#12291). CW treats a 503 as transient and retries (`ConnectionFailure.classify`).
- A user send releases a held queue (#21473), and after Stop an explicit steer fails with "Target run <id> is stopping and cannot be steered." while plain sends queue (#16926). CW shows command failures verbatim.
- Run ordinals follow start order and can skip (#17773). T3's web client looks up the prior checkpoint the same way CW does (T3Store/ThreadPromptRewind.swift), so both hide the restore action in the same cases.
- `compactIdleThreads` sends a visible "/compact" with `createdBy: "agent"` about 2 minutes before a Claude prompt cache expires (apps/server/src/orchestration-v2/IdleCompaction.ts). CW renders it like any agent-sent message.
- `thread.create` with an id that exists or was deleted now fails (#19704). CW makes a new UUID per create.
- Plan mode always raises Claude approval requests, even under Full access (#17963). Error texts got more specific (provider failures, SQLite busy, Git index lock, Claude context overflow).
- Auto-settle covers empty threads, settling clears a snooze, and quiet PRs refresh every five minutes (#15783, #17547, #22073).

## 2. Visible changes

Ported in this run, most seen first. Each commit message cites its T3 file:line.

- [x] Thread: workflow threads open with "Workflow started" and the script behind "Show full script" (WorkflowOpeningBlock.tsx). Steers split a finished turn's work into folds labeled "Continued for <duration>" (MessagesTimeline.logic.ts:1038-1075, 1180-1221). "From queue" is gone, answered questions stay visible after the turn settles, the compaction divider draws an arrow icon, the minimap preview shows plain text, diff counts use the diff palette, scratch threads read "No project", and durations round before picking a unit.
- [x] Thread status: Waiting for a turn blocked on another thread, Working through an async question, no "Thread completed" after Stop, one sound for threads finishing together. Lineage shows a supervisor running while its worker is active, a resumed subagent's card shows its live status, and the subagent bar shows effort only when stated or reported.
- [x] T3 tool summaries: "Started writing review guides", "Unwatching", "a delegated task" (packages/shared/src/t3McpToolPresentation.ts).
- [x] Markdown: Windows paths keep their backslashes, an image alone on its line breaks around it, and the file link menu hides "Copy relative path" outside the workspace and copies `:line:col`.
- [x] Composer: urgent and error notices sort first, the compact tooltip has two lines, the meter says "about", Mod+Shift+Enter is the alternate send when Mod+Enter sends, up-arrow recall skips automation and agent messages, `/tmp/build.sh` doesn't open the slash menu, favorited legacy models list with current ones, pasted folders become references, `_` stays literal while typing, a bare "2." takes Return, numbered lists renumber, `reasoning_effort` counts as effort, "Edit from here?" has the new sentence and a destructive-outline button, a thread chip from another machine blocks the send, Send retries failed uploads, image-only first messages title the thread "Attached image(s)", queued previews show quoted text, thread errors unwrap nested JSON behind "Show full error", a fork shows its parent's context usage, clipped banner titles get "Show title details", and the Run on and workspace tooltips name their shortcuts.
- [x] Sidebar, palette and keys: a "Failed" status pill until the thread is visited (CW draws no legacy pill yet, so this is logic only), Escape out of a palette child view restores the query, new-thread keys run their palette row, and the keybinding recorder records the layout character.
- [x] Settings: "Start from remote" replaces "Start from origin" in General, the branch picker and the toolbar ("From main (remote)"); "Compact idle Claude threads (beta)"; the address bar search engine with a custom URL template; Antigravity "Installed · Sign-in not checked"; the provider update toast's manual sentence; the full ACP registry list; the pending window delivery detail; one Database section for reclaim notices; "Show all environments".
- [x] Panels: terminal attach resumes; a host freeze toast; the new network and unresponsive host texts; skipped checks use circle-slash; the bare-number link message; per-provider limit bar colors; "Expand all folders" skips ignored folders and an empty search says "No matching files."; a file opened from the timeline expands in the diff; hour labels follow the 12 or 24 hour setting; the off-head checkout warning; clone "Stalled"; Open in over SSH with the user and `:1:1`; "Confirm close?"; the relay provisioning stage; T3 Connect reachability in Host access (polled every 30 s only while that page shows an active tunnel); the PR diff failure screen; the even-pace tick and "Even pace" row; "Using reset credit…" under the pool.

Still open, roughly by how often a user meets them:

- [ ] Sending while approvals are pending declines them and redirects the agent, with four race toasts (ChatComposer.tsx:6177, ChatView.tsx:5225-5263). CW still locks the composer. Large.
- [ ] The background work banner above the composer, with "Show" for one subagent (ThreadActivityBanners.tsx:100-170). Medium.
- [ ] Thread links in assistant Markdown render as chips (MarkdownThreadLink.tsx, 15dc7b0130). Medium.
- [ ] Mermaid diagrams use T3's new "pele" renderer, and closed fences render while streaming (fcb20e49aa, 48b486bd73). CW bundles mermaid 11. Large; the bundle can come from the 3473 runtime's `client/` assets.
- [ ] Opt-in math rendering with KaTeX (`mathRenderingEnabled`, MarkdownMath.tsx, MathTypeset.tsx). Large, and it needs the user's decision on a WKWebView renderer (see PROGRESS.md).
- [ ] Workflow phases and member agents in the opening block, and the native coordinator status on the parent Lineage row. Both need the parent thread's projection, which CW doesn't load.
- [ ] PR panel: review thread replies nested with "More replies" and "View on host" (70a869d262), the change breakdown tooltip through `pullRequests.changeBreakdown` (92a6f6d731), and checks popover columns (618c46478a).
- [ ] Connection diagnosis: a failure model with hop, cause, trace id and the "Details" block with "What to try", "Retry now" and "Copy diagnostics" (packages/client-runtime/src/connection/diagnosis.ts). Large.
- [ ] Add to another machine: the dialog, `projects.listIgnoredFiles` and the ignored file copy (AddProjectToMachineDialog.tsx, lib/addProjectToMachine.ts). Large.
- [ ] Scheduled task webhook filters and dedupe fields in the form (ScheduledTasksSettings.tsx:162-250, 1535-1603). Medium.
- [ ] Usage: weekly-exhausted accounts and their refill estimate (`poolMember`, 5b72385065), the freshest snapshot for one account on two instances (780b62dd26).
- [ ] Storage cleanup results as a Machine, Project, Folder and Thread grid (5803c8b299). It needs a width-dependent detail row in DesignSystem.
- [ ] Smaller: Cmd+Z undoes a settle while an editor has focus (21da3061aa), the Browser settings sections merged into one, the dark switch thumb (`muted-foreground`, needs new switch references), "Load earlier turns" as a button between dividers, the composer's code-pair caret rule (7259e4f594) and the blank line after a quote (02e9d2417a), the host freeze toast's environment label from the descriptor, the reachability line's "More info" link, EAS cloud simulator hosts (needs WebRTC; see PROGRESS.md).

No CW counterpart: the hosted web app's empty states, the mobile composer and keyboard fixes, Electron webview and zoom fixes, desktop default-browser and passkey handling, browser preview recording, and React state or focus fixes.

## 3. Client performance

T3's perf commits are React-specific. The steer segments add a membership set per fold to each row pass; `ThreadStressTests.largeThreadStepsStayUnderAFrame` measures that pass (see section 5).

## 4. Method and validation

The release archive came from GitHub and matched SHA256SUMS. A copy of the 3315 sandbox home ran 3473 on port 47396 (CandyWrapper-research/sandbox-3473), and the 3315 sandbox ran on 47395 for compatibility. The main sandbox and the live service stayed untouched. Four research passes read the contracts diff in full and triaged the 1,110 commits by area, but 115 commits that change the web UI or the shared packages left no trace in their notes (section 6); a comparison of every string literal in apps/web/src and the shared packages found the new user-facing text. Four agents then ported the changes in separate worktrees, one area each, and the main session merged, reviewed and tested them. The per-commit research notes, with T3 file:line and CW pointers for every item including the open ones, are in ~/CandyWrapper-research/notes/nightly-3473/ (findings-thread.md, findings-composer-settings.md, findings-panels.md, findings-server.md). The 48-diff-turn-file panel reference was recaptured from the 3473 web client, since 3473 expands a file opened from the card (design/reference/README.md).

## 5. Review and remaining work

A Codex review (GPT-6-Astra, high effort) of the whole diff from a39a89b5 found three bugs, all fixed with checks where the logic allows one. Continuing a numbered list whose number was past JavaScript's safe integers trapped on a UInt64 overflow (now bounded as composer-list-continuation.ts:87-91 does, `ComposerRichTextTests`). Send retried a failed upload without deleting its staged server copy (now through `retryAttachment`, as attachmentUploadQueue.ts:556-572 does). The 30 s reachability poll kept running while the window was hidden or minimized (now it follows the window's occlusion). The review found no wire breaks against 3315 or 3473, no main-thread stalls and no URL or path issues. My own pass checked the terminal `resume` against client-runtime/src/state/terminal.ts:51-63, the renumber edit order in the composer, the workflow opening mark after the memoized entry pass, and the steer segments' extra sets per row pass.

The full suite ran 1,589 Swift Testing and 18 XCTest tests with `LocalServerIntegrationTests` on the 3473 runtime. One test expected the pre-3473 layout of a steered turn and was updated to 3473's second fold. After the review fixes the whole suite ran again with no failures. `ThreadStressTests.largeThreadStepsStayUnderAFrame` measured a p95 of 8.2 ms per step against its 48 ms debug budget. Earlier the same day it failed at 97 ms while four agents compiled, and the cache and ping timing tests failed under that load too; all pass on a quieter machine.

On screen, an isolated debug build ran against 3473 in dark and 3315 in light. In each it opened a thread, sent one Haiku turn that answered "ok", toggled the sidebar in bursts of four and three (it ended shown, then hidden), and opened the command palette and Settings. Against 3315 the composer showed "Server update available", as the official 3473 client does. Settings search found "Compact idle Claude threads (beta)", "Start from remote" and "Search engine", and the Search engine row sits between "Auto-show floating preview" and the pull request links row as in IntegrationsSettings.tsx.

The first perf review flagged the huge-thread micro-benchmarks as up to 24 times slower. The cause was the new 3473 fixture: its 249-row thread became the base of the synthetic huge thread, a 104 MB input against 20 MB before. The benchmarks now read only the fixtures they were calibrated on (`PerfBenchmarks.benchmarkFixtures`), and that run was discarded.

Performance (docs/perf/2026-10-21-80ed242-w1.md, against a 3473 server): 218 ms to the first window, 0.045% idle CPU, 39.2 MB idle footprint and 421 ms of scroll CPU, with no app metric past its threshold. Against the median of the saved runs from 2026-10-18 and 19, the review flagged Markdown parsing and layout, the huge-thread update benchmarks and the sidebar item list. A same-hour A/B with a39a89b5, the commit before this run (kept out of docs/perf), shows those were already slower before this run: this run moved no benchmark by more than 13% (row derive +12%, Markdown line parsing +13%) and made the huge-thread updates 11 to 30% faster. The Windows path pass in Markdown now skips text without a drive path. Why a39a89b5 already measured slower than the 2026-10-19 runs (a commit, the Swift 6.3 build change or the machine) is an open task in PROGRESS.md.

Still open: section 2's list. Also: T3 always offers "Revert files too" in "Edit from here?", where CandyWrapper offers it only for a thread with a worktree (a rule older than this run), and the parent thread's projection, which would unlock workflow phases and the parent Lineage row status, is not loaded.

## 6. Commits the first pass missed

On 2026-10-22 a check of the research notes against `git log 3315..3473 -- apps/web/src packages/client-runtime packages/contracts packages/shared` found 115 commits, tests and refactors left out, that no note cites by hash or PR number. Three agents read each one against CandyWrapper: 60 can't matter here (web rendering, mobile, Windows, dev tooling, server internals), 18 CandyWrapper already matches, 3 need a look on screen and 33 are gaps. Their per-commit lines are in ~/CandyWrapper-research/notes/nightly-3473/audit-batch-{1,2,3}.md. The audit only read code, so each gap is confirmed against T3's source before it is fixed.

Terminal, project scripts, files and panels:
- [ ] Terminal output gets no clickable file paths; T3 detects them, keeps Unicode paths whole and skips logged request routes (terminal-links.ts, 9ac1355e01, 10b86829e8).
- [ ] Project scripts reach the shell history; T3 sends a leading space (projectScripts.ts, b92ebce0ad).
- [ ] A project script can reuse a right-panel terminal when the drawer is empty (projectScriptTerminal.ts, 687bd55533).
- [ ] A tall terminal drawer can push the composer into the header on a short window (ThreadTerminalDrawer.tsx, 055a8418c1).
- [ ] Revealing a deep file loads one folder at a time; T3 loads four (loadFileAncestors.ts, 1ea378c6f4).
- [ ] A changed file opened from the commit dialog resolves against the project folder, not the repository root (771fd93fc5).

Composer:
- [ ] The approval menu takes its content's width and the approval editor its smaller minimum height (d356059c84).
- [ ] A SnapShot taken while a question is open attaches to the answer (SnapShotCoordinator.tsx, b874ff6c22).
- [ ] The draft's model pick yields once another client sets the thread to that model (composerDraftStore.ts, 2767012996).
- [ ] The model preferences migration stops resending against servers that predate it (useSettings.ts, b34501a466).
- [ ] A draft that starts with a list or quote sits 10 pt too low (index.css:2003-2010, 3ec095bc8b).
- [ ] `@namespace.foo(bar)` stays text instead of becoming a file chip (composerInlineTokens.ts, 729924af29).
- [ ] The context handoff footer hides for a provider the next send would skip (ChatView.tsx:3974-3985, a9af48a3d2).

Thread, Markdown and sidebar:
- [ ] A finished run no longer ends a snooze, a failed run wakes it only when it failed after the snooze, and re-snoozing to the same time restamps it (threadSettled.ts, d2fb83a973 reverting b14120fbc8, 69ba80dfae, 699c1c5d4c).
- [ ] The Working row ends with a failed Codex turn that is still settling (threadExecution.ts, 07d38b8d17).
- [ ] The sidebar update pill shows updates on non-default provider instances (f15aa815f3).
- [ ] The code block scrollbar is 6 px (index.css:2073, b5a0696a98).
- [ ] Rows of the changed-files card show the pointing hand (72ebd98cc6).
- [ ] Expanded wide tables wrap to fit a lane of 36rem or more (f8b06c5fd0).
- [ ] Media missing on a remote host says "Media unavailable" with the host and checked path (ChatMarkdown.tsx:536-575, 826ef55b74).

Git, pull requests, settings and palette:
- [ ] The SSH prompt says "SSH verification required" and asks for a password or verification code (cc93dc10d2).
- [ ] A slow `vcs.refreshStatus` waits 120 s before the slow-request toast (requestLatencyState.ts:43, 069e63b117).
- [ ] Azure DevOps Server pull request links on any host are recognised (changeRequestUrl.ts, fa68107b8b).
- [ ] The default-branch dialog disables "Check out feature branch" on a clean tree and says why (7241e7ee50).
- [ ] The branch select row has separate hover fills for its label and chevron (2fc244a438).
- [ ] A long PR badge list scrolls within the screen (219afe344c).
- [ ] A maximized right panel draws one border next to the sidebar, not two (06ce02f194).
- [ ] Palette icons top-align with the title line, and thread results show the PR badge (26c6df72f8, 8a9d0e0dd5).
- [ ] The Antigravity install row with its download bar, an older gap that 6a00484478 restyled.

To check on screen: focus after closing the right panel from the keyboard (5088aff613), the branch strip after a failed worktree bootstrap (77ed46a8aa), and the editor's focus around the Implement menu (232e930cd2). CandyWrapper also never sends `server.reportClientActivity`; what the server uses it for is being looked up.
