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
4. Open: @-mentioning a machine in the composer (#17130 composer part), the @ picker listing threads on linked machines (#26201), Copy thread chips that work on linked machines (#26202), and following a delegate on a linked machine (#16719 client part).

Checked end to end on 2026-10-28 between the two 3814 sandboxes: B's switch on over RPC; A linked to B over `peerLinks.link` with a code minted on B with the scopes CW sends, and A's list then showed B reachable with Supervised access. A Claude Haiku 5.5 turn on a full-access thread on A called `t3_environment_link` with hint "sandbox b"; CW (snapshot of the Debug app against A) showed the pending card, and after the `use-existing` answer CW builds, the answered line "Linked miniko · Supervised" while the agent carried on. A supervised thread's call fails with `capability_denied`, as T3 intends. The clicks themselves couldn't be driven on miniko's screen: a stale Keychain prompt from SecurityAgent (started 08:37) held the front and synthetic input and accessibility were refused, so the app's own Link, Forget and card buttons rest on `LinkedEnvironmentsTests` and `PeerLinkTests` plus the RPC checks.

## 2. Wire changes

Filled in from group B's pass over the contracts diff and a recorded 3814 session (section 5).

## 3. The user's item list

From the user's catch-up brief, Phase 1 and Phase 2 lists, mapped to commits in this range.

| # | Item | Upstream | Status |
|---|---|---|---|
| 1 | Queued messages can't be edited while a question is open | fe507c5a1e #25593 | group A1 |
| 2 | Drafts for answered questions cleared off-thread | d5a791b940 #25457 | group A1 |
| 3 | Thread switches don't hold `thread.visit` up to 10 s; `opened`/`searchQuery` | 0a20d7ea73 #25368 | group A1 (opened/searchQuery already sent to servers with `opens`) |
| 4 | Skill chips in chat open the composer's details popover | 278588a61a #25432 | group A1 |
| 5 | Citations to older responses load their history | 1316d48b0c #25371 | group A1 |
| 6 | Warn before a second Claude or Codex account | 560ddb14d9 #25475 | group A2 |
| 7 | "Failed to start" and "could not load" recovery screens | 433837752c #25345, 6f3f0d46ea #25317 | group A2 |
| 8a | Find keeps its match after a thread switch | 3cb16cf165 #25463 | group A1 |
| 8b | Thread jump hints wait for their delay | 5effca10b3 #25636 | group A2 |
| 8c | Screen readers jump to the first and last message | 6838e31b9c #23780 | group A1 |
| 8d | Simpler "pull request created" row, armed PR confirm | 4034b5f6b5 #25613, b424c6e429 #25530 | group A2 |
| 8e | Short branch names aren't clipped | 70b0abceda #25328 | group A2 |
| 8f | Undo notice placement | 1549046fd2 #25270 | group A1 |
| 8g | Usage tabs don't jump | 32507803da #25336 | phase 2 (Usage modal) |
| 8h | Model picker doesn't jump | 5a38e6b859 #25358 | group A1 |
| 8i | Large thread counts don't shrink labels | 03851b8e7b #25355 | group A1 |
| 8j | New-thread shortcut focuses palette search | 9d6a2e57fc #25315 | group A2 |
| 8k | Switching back doesn't restore an old tab title | 3f9448747b #25521 | group A2 |
| 8l | SSH password prompts wait for their dialog | 02f4ba75a2 #25239 | group A2 |
| 8m | The picker refreshes the branch | 5b35402623 #22807 | group A2 |
| 9 | cloudflared 2026.10.4 | #25572 | group A2 checks whether CW launches it |
| 10 | Thread status moves to the end of the timeline | bd3287b640 #25401 (in 3814) | open, wave 2 |
| 11 | Settings grouped by concern, General split | 9db433f4ba #25651 (in 3814) | open, wave 2 (page assignment only; the modal is phase 2) |
| P3 | New design | 3816296021, c3888da8b4, f40c7c6435, 96fc7b9551, 72d4dc9b1e, 7df7cb9999, aa2c80b9e3, 62245d8e3a | phase 2 |
| - | Server-only fixes from the brief (#25426, #25372, #25609, #25285, #24275, #18359, #24850, #24784, #24737) | | free with runtime |

## 4. Everything else that applies

[The commit appendix](nightly-diff-3814-commits.md) lists all 246 client commits with their status. The larger open items, most visible first:

- Pending approvals on their timeline row instead of the composer drawer (1f8530ec3c #26255).
- Boring sidebar: threads grouped into project folders behind a Beta switch (4e4d4ba395 #21039), filtering by several projects (c38b265adc #25284), Working on by default (3de45c6254 #25190), your own snooze options (93a9e079b1 #26208).
- Queue: a simpler Send now row without reordering (92e645032c #25846), who sent each queued message (b31de684d2 #26159), Steer during a compaction (ad068d7c93 #25837).
- Timeline: background work line shows the newest activity (7e713926cd #25299), "Compacting for 12s" (3ef1610079), stopped runs don't look like errors (f3b058cd6a #25830), the dev servers a thread started (a27ec88bfa #22542).
- Files: inline audio and any shared file in the viewer (34e9c56b9b), SVG attachments (efea68679f), office, archive, sqlite, notebook and font previews (d69810a97a, 9d17a02782, 34ead566d4, 73afb57097).
- Model labels you'd say out loud (56695ae3ec #24205), question options with a radio and aligned key (d414cb5103 #23255).
- Pull requests: bot approvals on the summary (1702d55214), checks stay current (f4e140764f), the Code tab skips dropped commits (2083a22919), triage an issue from the palette (7e884b2df6 #22753).
- Add a remote server from a `t3code://pair` link (dde3fdb5a6 #24111), F6 between workspace areas (2525252c96).

## 5. Method and validation

Four research passes (GPT-6.1 Sol, medium) read the 246 commits that touch apps/web/src, packages/client-runtime, packages/contracts or packages/shared, one batch each, and wrote a verdict per hash (~/CandyWrapper-research/notes/nightly-3814/findings-1..4.md): 139 apply, 98 don't, 9 are server-only. The other 256 commits touch only the server, mobile, desktop or tooling.
