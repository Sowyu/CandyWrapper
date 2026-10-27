# T3 Code Nightly: 3473 to 3669

Range: v0.1.2-nightly.20261021.3473 .. v0.1.3-nightly.20261025.3669, 351 commits, 2,962 files. Target commit 5f64c5eb29. Line numbers refer to the 3669 tree. "CW" is CandyWrapper, paths under Packages/CandyKit/Sources unless they start with App/.

The range is 236 fixes, 35 refactors, 32 features and 19 perf commits. By scope it is 82 server, 79 web, 72 mobile and 11 source-control commits. 165 commits touch apps/web/src or the shared packages. The contracts diff is additive: nothing in it stops a 3473-era client, and T3 kept `compactIdleThreads` a boolean because shipped clients reject the whole config otherwise (settings.ts:647-649, 43879d9702). CW decodes the config, the 113-thread shell and the forked, compacted thread with subagents from a 3669 server (fixtures/transcripts/23-nightly-3669.jsonl, `NightlyCompatTests.recorded3669ConfigShellAndThreadDecode`).

The lazy shell, deduplicated bodies, compact ID tables and long-turn paging in this range (67c3afbd58, e57c093cdd, e19fe0837b, 80455376f0, 553203c57b) are opt-in and belong to the fast-load task in `PROGRESS.md` (docs/research/t3-fast-load-upstream.md on that branch). This document leaves them out.

## 1. Wire changes

### Behavior a 3473-era client gets wrong

1. Follow-ups steer the running turn by default (b808f7fc6d, settings.ts:431-433). CW still defaulted to queue. Fixed in T3Protocol/Domain/Settings.swift.
2. Pull request "unavailable" errors carry the host's own `requirement` text (pullRequest.ts:887-901, 233f6eac69), and the contracts dropped the table clients used to build it from. CW rebuilt it from its copy of the 3473 table, so new hosts and reworded hosts showed the generic text. Fixed: `PullRequestErrors.message` prefers `requirement` and keeps the table for older servers.
3. `UsageProviderKind` gained `muse` (usage.ts:22, c893353618). CW dropped every Muse Code usage row. Fixed in T3Protocol/Domain/Usage.swift, with T3's label "Muse Code" and color #0866ff (usageProviders.ts:43-47).

### Degrades

4. Idle compaction has three modes, `idleCompaction`: "When you return" (`onReturn`, the default), "Before the cache expires (beta)" and "Never" (settings.ts:638-660, 1163-1166, 1328-1375), plus a per-Claude-instance override with "Use default". The server still sends and accepts the boolean `compactIdleThreads` (true means `beforeCacheExpires`), so CW's switch works but can't pick "Never" or set an instance override.
5. Approvals carry `reason` and `fullAccessOverride` (`ask_rule` or `provider_check`, e749245387), and runtime requests carry `feedback` with `responseCapability.live.supportsFeedback` (b7e802bdec). CW doesn't say why a full-access approval was asked and can't send feedback.
6. Items carry `monitor`, background tasks `awaited`, and messages and items `idleCompaction` (91ea0e18eb, 0840bb209c, 0345e852ed). "Working" now holds only background work the agent waits on, monitors show as monitors, and compactions T3 starts read as one quiet working row. CW counts all background work and shows T3's compaction as a "/compact" message.
7. `ServerConfig.observability` names where each running OTLP endpoint came from, `otlp{Traces,Metrics,Logs}Source` (`environment`, `bootstrap` or `settings`) and the variable (server.ts, e78297d891). CW reads the stored setting only, so an endpoint set by the environment looks unset.
8. `thread.visit` takes `opened` and `searchQuery` (orchestrationV2.ts:2843-2852), which feed the `opens` ranking of the new Cmd+K search (bb7783e295). CW sends only `visitedAt`.
9. Guest share (fb76594d7b): `thread.guestShare`, event `thread.guest-share-updated`, shell `pendingGuestMessageCount`, `guestShare.create`, `thread.guest-share.close`, `thread.guest-message.dismiss`, `message.dispatch` with `guestMessageId`, and setting `guestSharingEnabled` (off by default). CW turns the event into an unknown event and shows a sent guest message as a plain user message.
10. `secretRequest.delivery: "file"` (e0b194021b): `request_secret` can save a CLI token to a private file. CW can't show that request.
11. The server pauses periodic pull request discovery while no client holds a foreground lease (5bb54a0f77). CW never sends `server.reportClientActivity`, so with only CW connected PR status refreshes only on demand. This raises the question already waiting on the user in `PROGRESS.md`.

### Additions CW can ignore or uses later

12. Websocket tickets can name their route, `POST /api/auth/websocket-ticket/:use` with `rpc` or `media` (environmentHttp.ts, 3cc31ed27c). A DPoP client's `rpc` ticket is then key-bound and the upgrade carries `dpop=<proof>`. The bare route still issues an unbound ticket that both routes accept (EnvironmentAuth.ts `authenticateWebSocketUpgrade`), which is what CW and the transcript recorder use.
13. RPC `pullRequests.filterOptions` (`{kind: labels|authors, projectId?, projectIds?, host?, query?}`, rpc.ts:535, 22dc1dabc6) for label and author filters that search the host.
14. Settings `threadTitleInstructions` with a project override (settings.ts:964-1001, 51273020db).
15. `thread.stop` takes `stopDelegatedTasks`, which defaults to stopping them (fbc6a08159). CW's Stop gets the new behavior unchanged.
16. Pull requests: `capabilities.review.rangeComment`, `checksAlwaysReport`, review comment `startPosition`, report-state `isDraft`, checks `observedAt`, watch `owedChecks` and `checksAwaitedSince`, and routing identities for any host. All optional.
17. `GitCommandFailureReason` gained `push_rejected_by_remote` and `push_rejected_non_fast_forward` (fb7f08782b). CW prints the reason and the server's detail as they come.
18. `payloadBudgetExceeded` left the bounded snapshot (553203c57b). CW reads it as optional.
19. previewAutomation.ts, orchestratorMcp.ts, worktreeMcp.ts, device.ts and ipc.ts changed descriptions, MCP tool inputs and desktop bridge types. CW calls none of them.

### Server behavior with no client change

- A pasted ChatGPT callback URL without `http://` is accepted (35e5d6229b). The server parses it (apps/server/src/provider/CodexChatGptAuth.ts:554), so CW's paste field gets the fix.
- A failed answer delivery fails the request (cd2b681e1a, `runtime-request.delivery.fail`), so a pending request can end without an answer. Answering an answered question says "already answered" (e822ba78ea).
- Stop stops a thread's subagents again (fbc6a08159), abandoned turns stop before a thread continues (6f6f68ad2d), and running task results tell the agent to end its turn (a96cf0818e).
- Thread tools return a ready `t3-thread://` link (003b64dfa5), and agent instructions are 60% shorter (5f64c5eb29).
- Streaming text updates that a newer one supersedes are coalesced (27e0c684c5), so CW sees fewer deltas with the same final text.
- LAN direct endpoints list background services and skip virtual interfaces (249b6ae469).

## 2. Visible changes

Most seen first. The research notes behind each item, with T3 and CW file:line for everything, are in ~/CandyWrapper-research/notes/nightly-3669/ (findings-A-wire.md, findings-B-thread.md, findings-C-composer-settings.md, findings-D-sidebar-pr-misc.md). "Status" says what this run did.

### Thread

1. Messages from other agents and automation messages fold into one-line rows: an icon, the sender thread's title or "Automation", the first line, a chevron, and "Open thread" or "Open automation" when expanded (f054d1b801, d27c6067a9, TimelineUserMessageRow.tsx:128-262, 298-335, 423-470). Server-created messages get "Sent by T3 Code". Status: ported on branch `nightly-3669` (8353ae5c). An expanded folded body isn't capped at T3's 384px with a scroll yet.
2. Compactions T3 starts read as one quiet working row: no `/compact` bubble, "Compacting after being idle…" on the working row, titled dividers such as "Context compacted after being idle", a red failed look, and quiet completion notices (0345e852ed, MessagesTimeline.logic.ts:1551-1655, packages/client-runtime/src/userMessage.ts:10-20). Status: ported on branch `nightly-3669` (704e5273).
3. Blockquotes keep the surrounding text color with a bar in that color at 35%, in messages and the composer (1df9c32943, index.css:1982-1990). Status: ported on branch `nightly-3669` (405f64bc).
4. Table cells drop the outer padding of the first and last columns and align to the top (2d620f5dcc, index.css:2138-2152). Status: ported on branch `nightly-3669` (405f64bc), except the footer's `-mx-1`, which moves the expand and copy buttons 4px outward (MarkdownTable.tsx:117). CW's buttons are subviews of the Markdown view, and 4px of each would sit outside it where clicks don't arrive.
5. The subagent card's status label moves right of its text column (2d620f5dcc, V2LifecycleRow.tsx:439-466). Status: ported on branch `nightly-3669` (1a1c37b8).
6. Scroll to end and thread switches land on the real end (fa1347daa2). Tool output images past the preview limit show "[image]" (f05599504a). Muted tool icons keep their detail in light mode (23bd753806). Links like `patches/` and `../x` outside the workspace resolve as T3 does (6de7da548d, edce5f0e53). The subagent bar and task durations stay readable when narrow (60b35a1ee0, 9b7e7dff45). Status: ported on branch `nightly-3669` (a2e59e67, be0f9462, 6465635f, 7c68e9ae), except Scroll to end, which needs a running app to reproduce. CW never draws image tool icons, so 23bd753806 needs nothing. The subagent bar stays 48pt tall when its status wraps, where T3's grows to 54.
7. A ChatGPT Business usage limit offers "Copy request for admin" (6f75bcb374, ThreadErrorBanner.tsx:25-27, 73-123). Status: ported on branch `nightly-3669` (470c1f8d).
8. Screen readers hear when the open thread starts, needs you or finishes, which background thread finished, and which thread a shortcut switched to (eb1510d249, a46f80ee28, 7f7daad985). Status: the message field's "Message <thread title>" label is ported (3263d96e). The open-thread and background-thread announcers are open: they need VoiceOver on a running app.
9. Code blocks and diffs highlight with @pierre/highlights instead of Shiki (d228f1f2c8). The theme names stay pierre-light and pierre-dark, but the tokenizer is new, so token boundaries can differ. Status: open, needs a capture of 3669 code blocks against CW's.
10. Arabic and Hebrew text reads right to left in messages, the composer, titles and the palette (3690c86253, textDirection.ts, markdownTextDirection.ts). Status: open. CW has no right-to-left layout yet.

### Composer

11. Follow-ups steer the running turn by default (b808f7fc6d). Status: pushed (52430c86).
12. Approvals in full access say why they were asked, with "Why am I being asked this?" (e749245387, ComposerPendingApprovalPanel.tsx:51-92). Status: ported on branch `nightly-3669` (cb64628a), with b7e802bdec's decline feedback.
13. After Stop, the queue holds its messages and offers "Send now" (96f09c6558, QueuedRunsControl.tsx:111, 175-192, 433-462). Status: ported on branch `nightly-3669` (9efa5147).
14. Pasted images show their upload tile at once (4dcc244fe1), Stop settles tool rows still drawn as running (d31269e46b), the usage-limit banner keeps "Wake now" (f416175804), `/compact` with instructions skips the bare compaction (16aaf5ba7d), typing a price no longer opens the skill menu (1ee0241730), DNG files attach as files (14b828e58e), and a secret request names a file delivery (e0b194021b). Status: ported on branch `nightly-3669` (4b2105b3, 13526e96, 7864f3e7, d6284f59, 7856da3b), except the pasted-image tile and the Stop reconcile, which are open.

### Sidebar

15. The Working section keeps a thread for 2 s after it stops, so it no longer flashes through the inbox, and the completion notice waits the same 2 s (242d00cd34). Working holds only background work the agent waits on (91ea0e18eb). Status: ported on branch `nightly-3669` (b1c14a01, 99ba7b8f).
16. The sidebar follows the active thread after history, palette or link navigation (044f07257c). Cmd+B toggles the sidebar unless text is selected (7d6b5bec87). Status: ported on branch `nightly-3669` (9b6d2968, 1fc6d300).
17. The provider update launch toast is gone (b9aaff46e0), and toast text uses the full width (e54e71d725). Status: ported on branch `nightly-3669` (b130a524, 71e037d9).

### Settings, Usage and the command palette

18. Settings and Usage open as large modals over the thread: up to 1280 by 960 pt, 24 or 40 pt from the window edge, an 18 pt radius, a blurred backdrop, a 150 ms scale from 98.5%, and the thread mounted and inert behind (3faeb9e6f9, AppRouteModal.tsx:15-84, _chat.settings.tsx:94-120). Redesign keeps opening them as tabs, as the user decided on 2026-10-21. Status: open.
19. A new Settings > Beta page holds "Working section" and "Guest links" (BetaSettingsPanel.tsx, SettingsSidebarNav.tsx:90). Status: ported on branch `nightly-3669` (b6c1ccbb): the page sits after Connections, with the inline Connections link and the signed-out Sign in state; in Redesign it shows inside the Experimental section.
20. "Compact idle threads" is a three-way select with a per-Claude-instance override (d13fc84670, SettingsPanels.tsx:973-1020). Thread title instructions (51273020db), the telemetry endpoint's source (e78297d891), and a Sign in button for a signed-out T3 Connect (6548c006d4). Status: the select, title instructions and telemetry sources are ported on branch `nightly-3669` (fed6a150, ba3287f5, 93baaf95). The Sign in button is open.
21. Cmd+K ranks with T3's new fuzzy search: use history, recents by last use, subagents hidden, options found inside submenus, and an "In messages" group from indexed message search (bb7783e295, 4812dcad02, e9d61252f6, packages/shared/src/paletteSearch.ts). Status: open. `thread.visit` should send `opened` and `searchQuery` with it (section 1, item 8).
22. Guest share: "Share with guest" in the thread menu and the palette, its dialog, a header indicator with "Stop sharing", waiting guest messages with Send and Dismiss, and the sidebar's "Guest Request" status (fb76594d7b). Status: ported on branch `nightly-3669` (8b2cc5ef, 75b4860d), with `GuestShareTests`. The sandbox has no T3 Connect tunnel, so "Create link" can only show its tunnel error there. Known gaps: the dialog's "A new link ends the current one." knows only the open thread's share, so sharing another thread from the sidebar can end its link without that warning, and the dialog reads the user's permission and the setting once when it opens. The server refuses a link it shouldn't make either way.

### Pull requests and source control

23. GitLab surfaces say "merge request" and "MR", and every host uses its own term (218e5c09df, 326e08b08a, a6009faba0). Status: open.
24. Author and label filters search the host through `pullRequests.filterOptions` (22dc1dabc6), and range comments arrive in the Code tab and the guide (233f6eac69). Status: open.
25. The thread details PR row merges with the last chosen method (a35066d9f2), check counts take the newer of detail and checks (200dad3b39), and four layout fixes (0c25c2974a, c8c9ccf916, 5e3ad56b8f, 945fd1df71). Status: open. "Add project to machine" cloning the fork (0f74ff8e3a) is ported (8ee3b46e).

### Copy

26. T3 removed em dashes from product copy (d7f3b72548) and reworded other strings. A comparison of every string literal in apps/web/src and the shared packages between the two tags found 109 removed strings that CW still had (~/CandyWrapper-research/notes/nightly-3669/strings-changed-pairs.txt pairs each with its likely replacement). Status: the composer and settings strings are ported on branch `nightly-3669` (3fd8e702). The pull request strings, which now follow each host's term, and the rest are open.

## 3. Client performance

T3's own client work in this range (17dc1afa15 skips unchanged shell and config cache writes, 7de9535a6c avoids ordering scans for streamed replacements, 5a0d1594e8, 83f118a4ac, ee33c4c65d, f7f02d779e and 9828cad49f cut React re-renders) has no wire effect. The fast-load task covers the first two for CW; the rest are React-only.

## 4. Method and validation

The release archive came from GitHub and matched SHA256SUMS. A copy of the 3473 sandbox home ran 3669 on port 47397 (CandyWrapper-research/sandbox-3669), and the 3473 sandbox ran on 47396 for compatibility. The main sandbox and the live service stayed untouched. One research pass read the whole contracts diff, and three triaged the 165 commits that touch apps/web/src or the shared packages, one area each; every hash appears in their notes. A comparison of every string literal in apps/web/src and the shared packages between the tags found the reworded copy. The CSS diff between the two client bundles found the blockquote, table and guest color changes.

The recorded 3669 session decodes (`NightlyCompatTests`), and the three wire fixes passed their suites and the fast lane before they were pushed (52430c86).

At 17:45 the disk fell to 39 GB free, under the 40 GB floor in `scripts/preflight`, so the porting agents wrote their last items without building. The disk came back to 40 GB at 18:10, and the merged branch `nightly-3669` then compiled as a package and as an app. Its fast lane ran 1,884 Swift Testing and 18 XCTest tests; the only failures were three `ServerUpdaterTests` timing out under a load average near 20, and all nine of that suite passed when run alone. The fidelity suites (136 tests) against the regenerated references failed in two places. Settings > Source Control's reference still had 3473's merge-credits text, so scripts/gen-settings-pages2-spec.py now carries 3669's. The checkbox and radio invalid-focus references came out with a blue ring because their specs (scripts/gen-toggles-spec.py, 2026-10-09) predate T3's focus rework (5dcb59ed6c), and those two references stay as they were until the specs follow 3669. After the review fixes, the whole suite passed at c77a87e1: 2,066 Swift Testing and 18 XCTest tests. The two thread stress tests first failed because their invariants still expected a `/compact` bubble and a working row, which 3669 replaces with the compaction row.

On screen, the branch's Debug app ran against the 3669 sandbox in both default themes: Settings > General's "Compact idle threads" select and thread title instructions, the Beta page with Working section and the signed-out Guest links row, a thread with subagents and its card's status on the right, one Claude Haiku 5.5 turn ("Reply with ok." answered "OK"), Cmd+B pressed six times fast with the composer focused, and the command palette. Against the 3473 sandbox it showed T3's "Server update available", hid Guest links and thread title instructions, greyed out "Never", and defaulted follow-ups to Steer. These checks didn't reach agent-sent, automation, guest or T3-started compaction messages, a stopped thread with a queue, or an approval with a reason, so those rows rest on their unit tests until someone opens them.

## 5. Review and remaining work

The main session read the merged decode changes: every new field (`awaited`, `supportsFeedback`, `remoteUrl`, `idleCompaction`, `latestRunSilent`, `lastErrorCode`, `contextHandoffId`) decodes as optional, so 3473 shells and projections read as before. Two behaviors follow T3's 3669 client against older servers rather than the 3473 client: background commands and monitors no longer hold Working unless `awaited` (which 3473 never sends), and CW's own "Compact and send" sends `idleCompaction: "onReturn"`, which a 3473 server should ignore but nobody has checked. A Codex review (GPT-6-Astra, high effort) of the merged branch found eleven problems, and nine are fixed (d3dfe720, 7683e08d). Against 3473: monitors held Working there but no longer did, "Send now" sent `queued-run.start`, which 3473 rejects, the per-Claude "Never" was stored but never read, and Guest links and title instructions wrote settings 3473 drops. CW now tells servers from 3655 by the `pendingGuestMessageCount` every 3655 shell carries, gates Send now on version 3486, and hides the rows a server can't store. Also fixed: guest requests end the Working grace, pending guest media can play, a late Stop sharing reply clears only its own thread, folded agent rows stop scanning every shell per row, and settings search sends Working section to Beta. Merging the branches took two hand resolutions: the sidebar's 2 s completion gate now also stays quiet for `latestRunSilent`, and two composer feedback tests both stay.

The branch went to main on 2026-10-27. After the merge with main (5c8b9ada, then e61a1883 for one docs commit), the whole suite passed at e61a1883: 2,127 Swift Testing and 18 XCTest tests, all 58 fidelity suites among them. Main's Orchestrator limit fix (6ba6eecd) then merged in, and the whole suite passed again at e5b92a44 (2,134 Swift Testing and 18 XCTest tests), the commit pushed to main. A Codex review (GPT-6.1-Sol, high) traced the eight new 3669 fields through the fast-load paths, the shell cache, equality checks and the 3473 gates, and found no semantic conflict.

The first `scripts/perf-review` of e61a1883 ran while another worker built (load up to 7) and flagged launch, big-thread scroll and thread-open regressions. Main at 74e0637, measured right after, also launched in about 1 s, and a quiet rerun of e61a1883 (load 1.2 to 1.5) matched 74e0637 on every metric: 216 ms window, 0.041% idle CPU, 42.4 MB idle footprint, 324 ms scroll CPU, 61.6/48.2/62.2 ms big-thread first frame, reopen and disk cache, no open stalls over 50 ms. That quiet run replaced the noisy one in docs/perf, next to the 74e0637 run. Against 01df2bd and caadcab, the last run before release v1.14.3, only `big_thread.after_scroll_footprint_mb` reads worse, 73.9 against about 52 MB, and 74e0637 measured 71.3 MB (range 51 to 74) with the same code as 01df2bd, so the machine moved, not the branch.

On screen, the Debug app ran in Redesign dark and light against the 3669 sandbox (47397) and the 3473 sandbox (47396): the subagent thread, one Claude Haiku 5.5 turn each ("Reply with ok."), Cmd+B six times fast, the command palette and Settings > General. Against 3473 it showed "Server update available". The re-pin is finished: ~/CandyWrapper-research/t3code is on the 3669 tag. Nightly 3726 came out on 2026-10-26.

Left, in this order:

1. Open on screen the rows the checks here didn't reach (section 4) and compare them with the official Nightly.
2. Bring the specs whose markup predates 3669 up to date with their scripts/gen-*-spec.py, starting with the toggles (checkbox and radio focus), and recapture them. The regeneration (3a5974c8) changed 64 files; besides quotes and tables, the focus-visible states of checkbox, radio, number field and panel tab close, the thread chip's text color and the PR merge row's height changed, and the old references for those came from 2861's stylesheet. All but the toggles still pass their ceilings.
3. Port the open items above, most visible first: the Settings and Usage modal, Cmd+K, the pull request terms and filters, then the rest.

## 6. Commit coverage

`git log v0.1.2-nightly.20261021.3473..v0.1.3-nightly.20261025.3669 -- apps/web/src packages/client-runtime packages/contracts packages/shared` lists 165 commits (~/CandyWrapper-research/notes/nightly-3669/commits-client.txt). Every one is accounted for:

- 150 went to the four research batches (batch-*.txt in the same folder), and each findings file names every hash of its batch with a verdict. A script checked that none is missing.
- 6 belong to the fast-load task: 67c3afbd58, e57c093cdd, e19fe0837b, 80455376f0, 17dc1afa15, 7de9535a6c.
- 8 are tests, comments, typecheck or the v0.1.2 release: bd6940beab, 4040867bb4, ef92441313, 51a7118b70, 30a405bbc1, abffeedeac, 8f26ed7e27, 68d5b7ac73.
- d7f3b72548, which takes em dashes out of product copy, is covered by the string comparison in section 2, item 26.

The other 186 commits in the range touch only apps/server, apps/mobile, apps/desktop or tooling. The wire pass read the server log for anything a client sees or must send (section 1, "Server behavior with no client change").
