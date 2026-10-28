# T3 Code Nightly: 3814 to 3824

Range: v0.1.4-nightly.20261028.3814 .. v0.1.4-nightly.20261028.3824, 30 commits. Line numbers refer to the 3824 tree. "CW" is CandyWrapper, paths under Packages/CandyKit/Sources unless they start with App/.

3824 is the newest Nightly with a GitHub release (released 2026-10-28 12:24 UTC); 3822 also has one and sits inside this range. The release archive matched SHA256SUMS and is unpacked in ~/CandyWrapper-research/runtimes/. A sandbox copy of the 3814 sandbox runs it on port 47404 (~/CandyWrapper-research/sandbox-3824, same tokens as sandbox-3814).

Phase 2 of the 3814 catch-up (T3's new design in the default themes) was running when this audit started. Changes that only exist in the new design, or that would change a fidelity reference phase 2 is recapturing, are marked "phase 2" and left to it.

## 1. Wire changes

The server advertises the same 51 capabilities as 3814. Nothing CW sends or reads changed shape.

### Breaks

None.

### Degrades

None. Two client settings changed, and CW keeps client settings on the Mac (Features/Settings/ClientSettingsStore.swift), so neither reaches the wire:

1. `composerCollapseOnScroll` is gone (settings.ts, removed from `ClientSettingsSchema` and `ClientSettingsPatch`), because the 3824 composer no longer collapses (#25869). CW still has the setting and the collapsing composer (App/Sources/ComposerController.swift:612, Features/Settings/GeneralSettingsView.swift:302). Phase 2.
2. `effortDisplay`, `label` or `bars`, default `label` (settings.ts:330, :359, :1659): the composer shows effort as a word unless you pick bars. Phase 2, with the composer.

### Keeps working (additive, CW ignores them)

3. Deferred work (d2429f733c #26240): a client can ask for collapsed work as a cursor instead of its items. Thread subscriptions take `acceptDeferredWork` (orchestrationV2.ts:3691), the bounded snapshot and history routes take `deferWork=1` (environmentHttp.ts:660, :670), history pages take `view: "work"` (:669), and a turn item can carry `deferredWork: {cursor, itemCount, lastOrdinal}` (orchestrationV2.ts:1451). The server defers only when asked (apps/server/src/ws.ts:865, orchestration-v2/http.ts:228-233, :268-274), and CW never asks, so it still gets every item.
4. The on-demand detail of a `file_change` item now carries `diffStr`, `oldStr` and `newStr`, each cut at the on-demand byte cap (apps/server/src/orchestration-v2/WireProjection.ts:203-215). Older servers send the item without them. CW reads them for "Open diff" (section 2) and falls back to the turn's diff without them.
5. The agents' `t3_thread_list` tool takes `allProjects` and returns `projectId` per thread, and the result's `projectId` is null with `allProjects` (orchestratorMcp.ts:333, :357, :384). CW never decodes that result. Its Orchestrator's scheduled check lists each project, which every server supports.
6. `DEFAULT_MANAGED_TUNNEL_LIMIT = 3` (relay.ts:969), for the tunnel meter in #26369.
7. The default Claude model is Opus 5.5 (model.ts:143). Servers mark their catalog's default with `isDefault`, and CW picks that (T3Store/ModelCatalog.swift:33), so it follows the server.
8. A merged pull request's watch no longer holds a thread's completion (packages/shared/src/orchestrationV2PendingBackgroundWork.ts:293-299). The server computes `backgroundTasks`, and CW reads them (T3Store/SidebarModel.swift:146-149), so threads settle with the new rule against a 3824 server.

## 2. Visible changes, most seen first

1. Timeline: a reply the steer replaced after it had finished stays in the timeline like any other answer, and a cut-off attempt's fold now says "Cut off by a steer" (ec43786140 #17761, from the 2994 range, which CW never ported; MessagesTimeline.logic.ts:723-768, :770-800, MessagesTimeline.tsx:1688). Handoff rows stay out of that fold (990e9e06e5 #26333, MessagesTimeline.logic.ts:788). CW: T3Store/TimelineRows.swift:408-427 and the turn folds after it, T3Store/TimelineEntries.swift:61-75 (the attempt has no `completedAt`), Features/Thread/TimelineFoldRows.swift:71.
2. Timeline: a queued message that hasn't started yet no longer also shows as a message (10e709c337 #26355, session-logic.ts:606-611). CW: T3Store/TimelineEntries.swift:306-309.
3. Composer: one simpler composer with grouped controls, effort as a word, permissions in the effort menu and no collapsed state (bd84b1781a #25869, 40 files). Phase 2.
4. Sidebar: a subagent's question no longer marks its parent thread; only approvals do, because the coordinator answers its children's questions (975b3dc568 #26367, threadShell.ts:96-98). CW: T3Store/ChildThreadInputs.swift, `PendingSubagentRequests.byThread`.
5. Boring sidebar (Labs): folders list active threads by your latest message (80fcb7f58f #26391, Sidebar.tsx:463, :657-661), and a project with no active threads gets no folder unless you filtered to it (001d16e969 #26387, Sidebar.logic.ts:920-948, Sidebar.tsx:1283). CW: T3Store/SidebarModel.swift:517-545, Features/Sidebar/SidebarListModel.swift:542-562.
6. Chat tables open at their natural size: no expand toggle, cells wrap at word boundaries up to 24rem, the table fits the lane, and long link words break anywhere (eb751fa073 #26449, index.css, MarkdownTable.tsx, MarkdownExternalLink.tsx:57-70). Word wrap's description drops "tables". Phase 2: CW's table matches the `wide-tables` component reference, which comes from T3's stylesheet, and phase 2 is replacing that stylesheet. CW: Features/Markdown/MarkdownView.swift:586.
7. Diff panel: a file change's "Open diff" shows that one tool call's patch, or its recorded before and after text, instead of the whole turn (441a4ebd65 #26304, apps/web/src/lib/toolCallDiff.ts, DiffPanel.tsx, diffPanelStore.ts:181-191, V2ItemInspector.tsx:293-307). CW: Features/Thread/TimelineWorkInspector.swift:65, Features/Thread/ThreadViewModel.swift:237, Features/Diff/DiffPanelView.swift.
8. Pull requests: shift-click on a file's Viewed box marks every file from the last one you toggled (ff424802ed #26349, pullRequestDiff.logic.ts:43-53, PullRequestCodeTab.tsx:701-716). CW: Features/PullRequests/PullRequestCodeView.swift:82, :151.
9. Snooze options: the editor sorts rows soonest first when focus leaves the list, the amount field fits two digits, Reset ignores row order, and the custom snooze dialog links to the options (c3858bf1f7 #26427). CW: Features/Settings/SnoozePresetsSettings.swift, Features/Sidebar/SidebarCustomSnoozeDialog.swift.
10. Settings > Source control: providers that aren't ready or aren't signed in get a grey dot and a neutral "Not authenticated" badge instead of amber (dac58fa7a6 #22778, SourceControlSettings.tsx:75-108). Phase 2: it changes the GitHub dot in the `32-settings-source-control` reference. CW: Features/Settings/SourceControlSettingsView.swift:81.
11. Linked environments: a remote delegate shows its harness icon, the thread details panel gets a "Delegated from" row, and approving a link request refreshes the Connections list (96a330c957 #26434). CW decodes neither `delegatedFrom` nor `remoteChild`, so the icon and the row wait with the 3814 leftover "following a delegate onto a linked machine". The list refresh is ported. CW: App/Sources/ThreadSession.swift:1665-1690, App/Sources/SettingsLinkedEnvironments.swift:29-47.
12. T3 Connect: Saved environments shows tunnel usage ("x of 3") with a "Get more tunnels" link, and an alert when the relay refuses a tunnel at the cap; linking T3 Chat pushes the full account (9f33a1c836 #26369). Skipped: it builds on the T3 Chat link, which the 3814 phase 1 skipped too, and CW tests can't sign in to real accounts.

## 3. Every commit

The 22 commits that touch apps/web/src, packages/client-runtime, packages/contracts or packages/shared, and the 8 that don't.

| Commit | PR | Change | CW |
|---|---|---|---|
| 990e9e06e5 | #26333 | Handoffs stay out of superseded attempt folds | ported (3097a414) |
| 441a4ebd65 | #26304 | Tool call diffs open in the diff panel | ported (4c0e9800) |
| cfc8be97d7 | #26343 | CI download retry | n/a |
| c3f5e363e5 | #26331 | Server stops replaying stale Codex usage limits | free with runtime |
| ff424802ed | #26349 | Shift-click marks a range of PR files viewed | ported (5217188e) |
| 9bc4138923 | #26350 | Refactor, flattened call chains | n/a |
| 10e709c337 | #26355 | No duplicate queued message entries | ported (3097a414) |
| f17c9d202b | #26358 | New Claude threads default to Opus 5.5 | free with runtime (wire 7) |
| a4e1986585 | #26366 | Docs, tunnel limits | n/a |
| dac58fa7a6 | #22778 | Neutral source control indicators | phase 2 |
| cb4fe60a4b | #24864 | Thread details tooltip shows | already so: the toggle has its tooltip (Features/Thread/ThreadPanelView.swift:150) |
| 975b3dc568 | #26367 | Subagent questions stay off parent threads | ported (a71d76ea) |
| be2ea30d2b | #26371 | Build, public-config bootstrap | n/a |
| 4c9c7d0bb6 | | Mobile 2.2.0 | n/a |
| c677d5fc45 | #26375 | Scroll-to-end button stops jumping | n/a: a React list ref that re-attached on every render; CW's timeline scroll view attaches once |
| 07f7f97609 | #26362 | Release CI | n/a |
| 001d16e969 | #26387 | Boring sidebar hides empty project folders | ported (a71d76ea) |
| 9f33a1c836 | #26369 | T3 Connect tunnel usage, T3 Chat accounts | skipped (section 2.12) |
| 40d335a7ba | #26392 | Settling a thread doesn't scroll the sidebar | already so: CW scrolls the sidebar only to reveal a new route, for keyboard focus, rename and search (Features/Sidebar/SidebarView.swift:552-580, SidebarListView.swift:633-637) |
| 80fcb7f58f | #26391 | Boring folders put your latest message on top | ported (a71d76ea) |
| 2a738273e7 | #26395 | Threads settle when a watched PR merges | free with runtime (wire 8) |
| d2429f733c | #26240 | Long thread history in bounded pages, deferred work | open task: opt-in (wire 3), and CW gets complete items without it |
| c3858bf1f7 | #26427 | Snooze options order, width and link | ported (3cb2301a); rows sort when the pointer leaves the list, where T3 waits for focus to leave |
| 48a292364a | #26432 | File preview wrap buttons stay local | already so: the toggle changes only that surface (Features/Files/FileSurfaceView.swift:111-121) |
| bd84b1781a | #25869 | Simpler composer | phase 2 |
| 96a330c957 | #26434 | Remote delegates' icon, parent row, settings refresh | refresh ported (fb3147e2); the rest waits (section 2.11) |
| 1abf368532 | #26440 | Build, license templates | n/a |
| 0160c448f6 | #26442 | Agents list snoozed threads across projects | n/a (wire 5) |
| c280e640c1 | #26448 | Delegate model search by provider name | free with runtime |
| eb751fa073 | #26449 | Chat tables open at the right size | phase 2 |

Found while auditing: ec43786140 (#17761, 2994 range), section 2.1, ported in 3097a414.

## 4. Method and validation

The main session read every client commit's diff and checked each against CW's code, and ported everything except #26304. A GPT-6 Astra delegate (medium effort) ported #26304 in its own worktree. The main session reviewed that port and restored the size-limit notice as a `LabelView`, with the omitted-files notice in a second bar, as DiffPanel.tsx:1043-1054 stacks them.

- The affected suites passed: 123 tests, including `NightlyCompatTests.recorded3824ConfigShellAndThreadDecode` on a session recorded read-only from sandbox 3824 (fixtures/transcripts/25-nightly-3824.jsonl), plus the delegate's 67 diff tests.
- With CW's own subscription flags (`acceptBoundedSnapshot`, `acceptCompactTurnItems`), the 3814 and 3824 sandboxes return the same bounded snapshot of the forked, compacted thread: 69 items with the same tail and history cursor.
- The test app renders that thread the same from both servers in both themes, with offscreen `--snapshot` renders. A Keychain prompt that ignores synthetic input (PROGRESS.md, Waiting on the user) kept clicks from reaching the app, so no turn was sent from it.
- The 3824 server marks `claude-opus-5-5` as the Claude default in `server.getConfig`, which confirms wire item 7.
- The first renders showed a stale thread from the thread cache, which every build shares (an open task in PROGRESS.md). With `CANDY_THREAD_CACHE=off` they match.
- The full suite on 4c0e9800 ran 2,441 tests, and 6 failed.
  - Two of them were mine: the snooze editor's row order and the diff panel's notice test, both fixed in 35b7e505.
  - `ServerUpdaterTests` and `MarkdownBackgroundLayoutTests` passed when run alone.
  - `RedesignBaselineTests.exactPixels` differs at one status dot in Settings > Models (124 to 132 pixels) when it runs beside other suites. It passes alone at HEAD and at 0bcf5db0, so another suite's shared state leaks into it.
  - `ThreadStressTests.fullSnapshotsWithOutOfOrderDeliveries` (seed 10, step 22) also fails at 0bcf5db0, before this catch-up. An open task in PROGRESS.md tracks it.
