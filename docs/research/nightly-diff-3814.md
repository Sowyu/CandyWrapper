# T3 Code Nightly: 3669 to 3814

Range: v0.1.3-nightly.20261025.3669 .. v0.1.4-nightly.20261028.3814, 502 commits. Target commit ce66aab13f. Line numbers refer to the 3814 tree. "CW" is CandyWrapper, paths under Packages/CandyKit/Sources unless they start with App/.

This is phase 1 of the catch-up the user asked for on 2026-10-28: features, fixes and wire. Phase 2 is T3's new design for the default themes, pixel by pixel, including the floating Settings panel. Phase 3 carries that design into Redesign. Items that are part of the new look are marked "phase 2" and left alone here.

## Target

3814 is the newest Nightly with a GitHub release (28 assets, released 2026-10-28 08:17 UTC). 3809 and 3766 have tags but no release, so they were pulled or failed to build, and 3682 is skipped as the user asked. No issue filed by 10:52 UTC on 2026-10-28 reports 3814 broken. The user's MacBook runs 3754 and aniko runs 3717; T3 v0.1.3 (stable) shipped between them.

CW must keep working against 3473, 3669, 3717, 3754 and 3814. New features are gated on what the server sends: a capability (`peerLinks`), a setting key the server stores (`linkedEnvironmentsEnabled`), or an optional field. The release archives for 3717, 3754 and 3814 came from GitHub and matched SHA256SUMS; they are unpacked in ~/CandyWrapper-research/runtimes/.

Sandboxes used: 3814 at 47398 (a copy of the 3669 sandbox home, ~/CandyWrapper-research/sandbox-3814) and a fresh 3814 home at 47399 (sandbox-3814-b) for linking, 3669 at 47397 and 3473 at 47396. The live T3 and the main sandbox were not touched.

## 1. Linked environments (#16655, #16695, #16698, #16719, #17129, #17130, #26178, #26201, #26202)

T3 3814 lets an environment sign in to another environment's `/mcp` as an outside agent with a pairing code from it, so agents here can list, launch, message and wait on threads there (`delegate_task` with an `environmentId`, every T3 tool's `environmentId`). Work a link starts stays inside the link (`linkOrigin`, capability `linkFence`), and the other side caps the agent's modes with `T3-Mode-Limit` (`mcpModeLimitHeader`). It is a Beta, off by default, per environment.

Wire (contracts/src/peerLink.ts, rpc.ts:494-497, 773-794, environment.ts:139-150, settings.ts:1209, orchestrationV2.ts:1505-1540):

- Capabilities `peerLinks`, `mcpModeLimitHeader`, `linkFence`. Absent before 3814, so 3754 and older never offer links.
- Setting `linkedEnvironmentsEnabled`, default false. While off, nothing new starts over a link and running tasks finish.
- `peerLinks.list` returns `{links: PeerLinkSummary[]}` (status `reachable`, `unreachable` or `expired`, `lastError`). Listing probes every linked machine.
- `peerLinks.link` takes `{url, alternateUrls?, pairingCode, access, expectedEnvironmentId?, expectedLabel?}`; `peerLinks.unlink` takes `{environmentId}`. Both need `access:write` (clientRpcPermissions.ts:64-65). Errors are `PeerLinkError` with a user-facing `message`.
- An agent asks for a link with `t3_environment_link`, which adds a `link_request` turn item (`reason`, `hint`, `url?`, `environmentId?`, `requestedAccess?`, `linkStatus`). The user answers with `peerLinks.answerRequest` `{threadId, turnItemId, answer: link | use-existing | decline}`. The pairing code never enters orchestration.

Status in CW:

1. Settings > Beta: the Linked environments switch with T3's text and its Connections link, shown only where the server stores the setting (b047c435). CW keeps its "Beta" page name; T3 renamed the page "Labs" in the settings regroup (#25651, section 3).
2. Settings > Connections: one "Linked environments" section per connected environment that offers links, titled with the environment's name when there are several. Rows show the status dot, name, access and status ("Reachable", "Expires in N days. Link it again to renew.", the last error, "Expired. …"), the addresses and Forget with T3's confirm. Link opens "Link an environment": a machine from this app's catalog or another address, a pairing code unless this app's session there may mint one (`POST /api/auth/pairing-token` with `mcpClientScopes(access)`), and the access picker with T3's note (b047c435). Machines known only to T3 Connect aren't offered yet; type their address.
3. The thread: `link_request` items were unknown to CW and dropped, so an agent asking to link waited with nothing on screen. They now show as T3's card with Decline and "Review link…" or "Choose machine…", and answered requests as one work log line ("Linked miniko · Supervised", "Declined", "Could not link: …", "Request ended"). The dialog opens on the machine the agent named, or the best match for its hint, with its suggested access; a machine linked already is answered `use-existing` (a097e0a4, a4e56409). T3's dialog has two steps (machine, then access); CW shows both on one page, a phase 2 difference.
4. The composer: @ suggestions offer the linked machines and their threads, an environment chip survives send, restore, paste and queued edits, and Copy thread copies a chip that works on linked machines (#17130, #26201, #26202, group E). Following a delegate onto a linked machine (#16719 client part) is open.

Checked end to end on 2026-10-28 between the two 3814 sandboxes: B's switch on over RPC; A linked to B over `peerLinks.link` with a code minted on B with the scopes CW sends, and A's list then showed B reachable with Supervised access. A Claude Haiku 5.5 turn on a full-access thread on A called `t3_environment_link` with hint "sandbox b"; CW (snapshot of the Debug app against A) showed the pending card, and after the `use-existing` answer CW builds, the answered line "Linked miniko · Supervised" while the agent carried on. A supervised thread's call fails with `capability_denied`, as T3 intends. The clicks themselves couldn't be driven on miniko's screen: a stale Keychain prompt from SecurityAgent (started 08:37) held the front and synthetic input and accessibility were refused, so the app's own Link, Forget and card buttons rest on `LinkedEnvironmentsTests` and `PeerLinkTests` plus the RPC checks.

## 2. Wire changes

The contracts diff is mostly additive, but 3814 removed RPCs and HTTP routes CW still called. The full table, with each removal and what CW does now, is in [the wire audit](nightly-3814-wire.md).

Breaks a 3669-era CW has against 3814:

1. `scheduledTasks.list` is gone (rpc.ts:1828 keeps only `scheduledTasks.subscribe`). The Orchestrator listed tasks with it in four places. CW now reads the subscription's first snapshot and stops it, which 3473 and 3669 also serve (01b18e67).
2. `GET /api/auth/clients` is gone. The helper's uninstall read it to find its sessions. CW now reads one `subscribeAuthAccess` snapshot first (01b18e67).
3. T3 merged 18 MCP tools into action tools (ed44f251d8): `t3_thread_configure`, `t3_schedule` and others take an `action`. CW's work rows named such calls by tool name only; they now read the action from the input and keep the old names for older threads (49512488).

Degrades and additions now handled:

4. `providerWorkspaceSnapshotsOnDemand` (abd9d9f970): opening a thread loads 85% less data when the client asks for provider workspace snapshots on demand. CW opts in only where the server advertises it (3471d72d).
5. `t3-thread://v2/<environment>/<thread>` links name their environment and never a title (c2fbf0a524 #26239); CW resolves them in their environment only (7616fc6e).
6. Terminal snapshots carry the shared PTY's `cols` and `rows` (49a9e80e0b #24352); CW renders that grid and keeps its own size for resize reports (40182582).
7. A pairing link can no longer add a route to a saved environment it doesn't belong to (003ccd336d #26178), checked before the code is spent (b089670b).
8. A slow host no longer shows settings as read-only: session reads retry on timeout with doubled deadlines up to 60 s (024e593a63 #25526, f48eb038). Searches and pull request refreshes keep their results through an unreachable environment and refresh after reconnect (8e86eb2b4d #25703, 938aa3f8).
9. Peer links and `link_request` (section 1).

A session recorded from the 3814 sandbox (fixtures/transcripts/24-nightly-3814.jsonl: config, 129 shell threads, a forked and compacted thread with subagents) decodes without changes (`NightlyCompatTests.recorded3814ConfigShellAndThreadDecode`, a6adbcdb), next to the 3473 and 3669 recordings.

## 3. The user's item list

From the user's catch-up brief, Phase 1 and Phase 2 lists, mapped to commits in this range.

| # | Item | Upstream | Status |
|---|---|---|---|
| 1 | Queued messages can't be edited while a question is open | fe507c5a1e #25593 | ported (0c2ed9a3) |
| 2 | Drafts for answered questions cleared off-thread | d5a791b940 #25457 | ported (0c5b1475) |
| 3 | Thread switches don't hold `thread.visit` up to 10 s; `opened`/`searchQuery` | 0a20d7ea73 #25368 | ported (3b91c48d); `opened` and `searchQuery` already go to servers whose shells carry `opens` |
| 4 | Skill chips in chat open the composer's details popover | 278588a61a #25432 | ported (48da3112) |
| 5 | Citations to older responses load their history | 1316d48b0c #25371 | ported (fc007033) |
| 6 | Warn before a second Claude or Codex account | 560ddb14d9 #25475 | ported (see appendix) |
| 7 | "Failed to start" and "could not load" recovery screens | 433837752c #25345, 6f3f0d46ea #25317 | ported (1f25d823): the startup failure screen copies a triage command and diagnostics, files a bug and offers a reinstall |
| 8a | Find keeps its match after a thread switch | 3cb16cf165 #25463 | ported (4859bd12) |
| 8b | Thread jump hints wait for their delay | 5effca10b3 #25636 | n/a: fixes a held-modifier timer CW doesn't have |
| 8c | Screen readers jump to the first and last message | 6838e31b9c #23780 | ported (f80dae9d) |
| 8d | Simpler "pull request created" row, armed PR confirm | 4034b5f6b5 #25613, b424c6e429 #25530 | ported (eeeadfd0) |
| 8e | Short branch names aren't clipped | 70b0abceda #25328 | already so: CW recomputes truncation on layout |
| 8f | Undo notice placement | 1549046fd2 #25270 | ported (f4d4d618) |
| 8g | Usage tabs don't jump | 32507803da #25336 | phase 2 (Usage modal) |
| 8h | Model picker doesn't jump | 5a38e6b859 #25358 | ported (d07c98a6) |
| 8i | Large thread counts don't shrink labels | 03851b8e7b #25355 | ported (49772013) |
| 8j | New-thread shortcut focuses palette search | 9d6a2e57fc #25315 | already so: the shortcut focuses palette search |
| 8k | Switching back doesn't restore an old tab title | 3f9448747b #25521 | ported (6b2f8e0a) |
| 8l | SSH password prompts wait for their dialog | 02f4ba75a2 #25239 | ported (20b83f21) |
| 8m | The picker refreshes the branch | 5b35402623 #22807 | ported (c0172900) |
| 9 | cloudflared 2026.10.4 | #25572 | free with runtime: CW neither bundles nor launches cloudflared (no match in App, Packages, scripts or project.yml); the T3 runtime installs and runs it |
| 10 | Thread status moves to the end of the timeline | bd3287b640 #25401 (in 3814) | ported (bec4b95a): child attention, background work, sync and goal status are quiet lines at the timeline's end in the default themes; the new look is phase 2 |
| 11 | Settings grouped by concern, General split | 9db433f4ba #25651 (in 3814) | ported: pages grouped by concern, General split, Beta renamed Labs with Legacy features, a Sharing & access page; CW's settings window and Redesign's tabs stay; the floating panel is phase 2 |
| P3 | New design | 3816296021, c3888da8b4, f40c7c6435, 96fc7b9551, 72d4dc9b1e, 7df7cb9999, aa2c80b9e3, 62245d8e3a | phase 2 |
| - | Server-only fixes from the brief (#25426, #25372, #25609, #25285, #24275, #18359, #24850, #24784, #24737) | | free with runtime |

## 4. Everything else

[The commit appendix](nightly-diff-3814-commits.md) gives every one of the 246 client commits its status and the CW commit: 101 n/a, 70 ported, 27 skipped, 25 phase 2, 12 free with runtime, 11 already so. Nothing is left unclassified.

Ported beyond the user's list, most visible first: pending approvals on their timeline row, thread state at the timeline's end, project folders in the sidebar (a Labs switch), filtering by several projects, your own snooze options, the settings regroup, one update row per machine, inline audio and shared files in the viewer, SVG attachments, the question options' radio and key, the dev servers a thread started, queued edits that survive navigation, triage from the palette, fx on servers that offer it, stopped runs that don't look like errors, "Compacting for 12s", the background work line, the compact toggle's token count, Working on by default, and about twenty smaller fixes.

Waiting for phase 2, because T3 shows them only in its new design and no T3 build has them in the old look, so the default themes' references can't confirm them: spoken model labels (#24205), and the queue's Send now row, sender line and Send now during a compaction (#25846, #26159, #25837). Each was ported and reverted (068aa9c3; e08c5c01 and b330916b), so phase 2 can bring the commits back. The usage tabs (#25336) and the avatar verdict glyph (#25829) are part of phase 2's redesign too.

Skipped with a reason in the appendix (larger than this phase or needing on-screen checks): Office, archive, SQLite, notebook, font and large-file previews; shared PR-check freshness and preview-only PR reads; asset URL revision; F6 between workspace areas; Zen cookie import; T3 Chat tunnel accounts; the internal GitHub app; adding a server from a `t3code://pair` link, since that scheme belongs to the official app.

## 5. Method and validation

Four research passes (GPT-6.1 Sol, medium) read the 246 commits that touch apps/web/src, packages/client-runtime, packages/contracts or packages/shared, one batch each, and wrote a verdict per hash (~/CandyWrapper-research/notes/nightly-3814/findings-1..4.md): 139 apply, 98 don't, 9 are server-only. The other 256 commits touch only the server, mobile, desktop or tooling.

Porting ran in groups, each in its own worktree with GPT-6.1 Sol (high): wire (B), the user's list (A1 to A3), timeline and queue (C), sidebar and settings (D), the composer and files (E), the last 42 commits (F) and the 3754 references (G). The main session wrote Linked environments, about fifteen small fixes, and merged every group by cherry-picking into one branch, fixing what didn't build together, and pushed each group to main after the app built and `scripts/test --fast` and every fidelity suite passed on the merged state. The last push passed 2,206 Swift Testing and 18 XCTest tests in the fast lane and all 137 fidelity tests. A full-suite run happened only as fast lane plus fidelity, and `scripts/perf-review` wasn't run in this phase.

The disk sat near the 40 GB floor most of the day, so several agents stopped or committed untested; their builds and tests ran in the main worktree instead, and build caches of merged, clean worktrees were deleted. A Keychain prompt from SecurityAgent held miniko's screen from 08:37, so on-screen checks used `--snapshot` against sandboxes and offscreen captures rather than clicks: threads rendered against 3473, 3717, 3754 and 3814 servers, the pending link request card and its answered line against 3814, and the agents' captures of folders, the Labs page, the timeline-end status, inline approvals, dev servers and the recovery screen. Still to check by hand: Link and Forget clicks, the Link dialog's machine choice, the @ machine chips, queued-edit navigation, audio and Quick Look, the triage flow, F6-free keyboard focus in folders, and VoiceOver's first and last message.

## 6. Phase 2: the new design in the default themes (2026-10-28)

T3's new design (#24865, #25251, #25778, #25324 and the fixes after them up to 3814) now draws the default themes. Where Nightly 3824 changed a piece further, the port took 3824's version: the simpler composer with effort words and permissions in the effort menu (#25869), chat tables at their natural size (#26449) and the grey source control dots (#22778). Redesign (Experimental) renders exactly as before.

1. References. `design/reference-3814/` (117 PNGs) and `design/reference-3824/` (121 PNGs) were captured from clean sandboxes (sandbox-3814-ref on 47402, sandbox-3824-ref on 47403) with 12 Haiku turns in total. The 3669 set in `design/reference/` stays. The default-theme screen cases compare with the 3824 set.
2. Tokens. `design/t3-source/main.css` is 3824's stylesheet; 3669's and 3814's stay beside it. Every changed token is in [nightly-3814-tokens.md](nightly-3814-tokens.md): 62 changed, 8 added and 9 removed from 3669 to 3814, and two composer seam lengths removed in 3824.
3. Components, each with its report: primitives, sidebar and dialogs ([nightly-3814-primitives.md](nightly-3814-primitives.md)), the composer, queue rows and spoken labels ([nightly-3824-composer.md](nightly-3824-composer.md)), the floating Settings and Usage modals ([design-settings-3824.md](design-settings-3824.md)) and their rows ([design-settings-rows-3824.md](design-settings-rows-3824.md)), the thread and toolbar ([nightly-thread-3824-design.md](nightly-thread-3824-design.md), [design-thread-followup-3824.md](design-thread-followup-3824.md)), the right panels and avatar verdicts ([design-merge-panels-3824.md](design-merge-panels-3824.md)), and the screen passes ([nightly-3824-composer-sidebar-screens.md](nightly-3824-composer-sidebar-screens.md), [design-screens-settings-3824.md](design-screens-settings-3824.md), [design-screens-panels-3824.md](design-screens-panels-3824.md), [design-final-diff-3824.md](design-final-diff-3824.md), [design-final-misc-3824.md](design-final-misc-3824.md), [design-final-48-3824.md](design-final-48-3824.md)).
4. Fidelity. Every fidelity suite passes at its existing ceiling, with no exception added: 84 tests in 55 suites plus the Redesign guard in one parallel run. Two cases were retired because 3824 can't reach their state: the composer footer's `cluster.overflow-access` (3824's narrower controls never overflow at that width) and screen 42 (3824 folds the access mode picker into the effort menu, screen 53). The modal backdrop blur now uses Core Image's measured sigma-1 kernel (worst channel 1/255).
5. Redesign. `RedesignBaselineTests` compares 80 exact captures recorded before the port. They match with zero changed pixels. Main's own Ignore Reduce Transparency row (47a4c8da) changed the Appearance tab, so those two images were re-recorded on origin/main alone.
6. Pin. `T3_VERSION` moves to 3814. The 3824 features arrived with the scheduled 3824 catch-up, which leaves its own re-pin.

Not ported, with reasons: screen 20 (the thread context menu is a native NSMenu, which offscreen rendering can't draw), screen 52 (T3's pairing error page has no CandyWrapper counterpart, and T3 draws it dark in both themes), deferred-history loading skeletons (CandyWrapper has no matching loading state yet), and the PR count trigger's "checks" suffix (no native consumer).
