# Release check for 1.15.0 (82)

Branch `release-check` from `catchup-4928` (847c7db4), worktree /tmp/cw-release-check, checked on 2026-11-20 on the Mac mini M2 Pro (Mac14,12, macOS 27.2, Xcode 27.2). The release candidate is the app `scripts/release --dry-run --version 1.15.0 --build 82 847c7db4` built and signed.

Verdict: ship with named known issues, after `scripts/release` can publish over the old-key appcast (the `release-rotation` branch) and with a release note about the one Keychain prompt per saved machine.

## Blockers found and their state

1. `scripts/release` cannot publish 1.15.0 as it stands. The dry run builds, signs and archives, then stops at "the published appcast's signature does not verify": the live appcast is signed with the old EdDSA key (`3lPq…`), and the script only extends a feed its own key signed. The "Release script key rotation" session is fixing this on branch `release-rotation` (`--previous-key`), which it reports ends the dry run cleanly. Not merged here.
2. The old Apple Development certificate (serial 3D4C…F3, issued 2026-10-12) is revoked. `spctl` reports `CSSMERR_TP_CERT_REVOKED` for the published 1.14.14, and Gatekeeper showed "Malware Blocked: CandyWrapper was not opened because it contains malware" and tried to move it to the Trash (syspolicyd: "Attempting to move malware to trash"). Every installed 1.14.14 and older will be refused at its next launch that checks revocation. Nothing in 1.15.0 can change that; it makes shipping 1.15.0 urgent, and the README's manual-install note should say the old app may be blocked or moved to the Trash, and that settings and paired machines stay.

## 1. Tests

`scripts/test`, the whole suite: 6 suites failed.

| Failure | Result |
|---|---|
| ConnectionsFidelityTests `nav.rest.dark` 10.78% against 6.5% | Stale reference, not a code bug. b8bb3f31 "Voice in the nav and Source control & issues" matches 4928's nav (settingsSearch.ts:113,125,146; SettingsSidebarNav.tsx:91): the Voice row shifts every row below it and "Source control" became "Source control & issues". `design/component-reference/connections/nav.rest.*.png` predate 4928. Light stays under its ceiling (5.39%). Fix: recapture the connections nav reference from 4928. |
| ThreadStressTests `providerNativeSubagentThreads` | Fixed in 9c093cac. First-parent bisect from v1.14.14: 25cac779 (merge of thread-5); inside thread-5: 543356f2 "one load reveals a whole earlier turn". The reducer now leaves `history.loading` set and returns the next cursor while a page holds no turn start; `ThreadSession.loadEarlier` (App/Sources/ThreadSession.swift:247-261) follows it, the stress harness (ThreadStressTests.swift:233) dropped it. Not a bug in subagent threads or anything users see. All 6 ThreadStressTests pass after the fix. |
| PanelScreensFidelityTests 05-approval-request light and dark | Known. |
| ChangedFilesFidelityTests `cardAndDiff` | Known. |
| MarkdownBackgroundLayoutTests `viewLaysOutInBackground(modern: true)` | Known load flake. |
| LocalServerRunTests `returnsStdoutOfACommandThatExits` ("`hi` did not finish in time") | Load flake: passes alone (5 of 5 in the suite). |

## 2. Upgrade from 1.14.14

Data check first: no `dev.candywrapper.app` defaults domain, no `dev.candywrapper.t3.*` Keychain items, no /tmp/cw-demo.pid. `~/Library/Application Support/CandyWrapper` and `~/Library/Caches/CandyWrapper` existed, written by test builds (`ThreadCache/` and per-test-bundle folders, all dated 2026-11-19 and 20); they were backed up first and restored byte for byte at the end.

1. The published 1.14.14 DMG (`gh release download v1.14.14`, helper sums verified) would not run: revoked certificate, Gatekeeper's malware block (blocker 2). I dismissed that notice's Done button; it grants nothing.
2. To stand in for a real install I re-signed a copy of 1.14.14 with the current Apple Development identity, inside-out like `scripts/release`. Same Team ID 8Q677AYRU7 and same member id, but the certificate's common name changed with the account's e-mail, so the designated requirement differs from the published 1.14.14's.
3. With that copy: paired with the 3824 sandbox through Settings > Environments > Add environment (host and a `t3 auth pairing create` code), switched on Redesign (dark), picked a picture, set dim 55% and the pink accent, turned on Ignore Reduce Transparency, In-app notifications and turned off Working section, typed the draft "release check draft [Ponytail chip] keep me" in Say Pong, turned on the Orchestrator and Tabs under Experimental, and quit. The Orchestrator's Start did nothing visible and installed no helper. 1.14.14 can't show a remote-only machine as its main workspace ("Still connecting" after declining the live T3), so the draft session used `--server` for the same environment.
4. 1.15.0 over that data, launched without `--server`: it read the Keychain token silently (same requirement), connected, and showed Say Pong with the draft and its chip, the tab strip, the Redesign picture, dim 55%, pink, Ignore Reduce Transparency, In-app notifications on and Working section off. The Redesign tab shows the right state with Stacked model picker on and Account and limits off. The Orchestrator is gone from the sidebar, from Settings and from Experimental. The window title read "No project / Say Pong".
5. The Orchestrator cleanup waits for a primary machine, so in the remote-only launch `orchestrator.v1` stayed, harmlessly. With the sandbox as primary it logged "orchestrator cleanup on 16bbc619…: done", removed `orchestrator.v1` and `orchestrator.sync.v1`, ran no helper uninstall (no helper sessions), and left the sandbox's only thread unarchived.
6. Real users' case, reproduced exactly: I rewrote the token item with the published 1.14.14's own designated requirement (a signer carrying that requirement, verified equal to `codesign -d -r-` of the published app). 1.15.0 then showed, without me clicking it: "CandyWrapper wants to use your confidential information stored in "T3 Code environment token" in your keychain. To allow this, enter the "login" keychain password." with Always Allow, Deny and Allow. Expect one such prompt per saved item (each machine's token per route, and the T3 Connect DPoP key and Clerk session if signed in). A denied read leaves the machine unconnected and deletes nothing (Environments.swift:295, :376). The prompt outlived the app it belonged to.
7. Log of 1.15.0: no errors from the app beyond Sparkle's feed message below and 8 each of AppKit's "Invalid view geometry: x/y is infinity / too large" plus one "NSLayoutConstraint constant exceeds internal limits"; 1.14.14 prints the constraint warning too.

Update path, Sparkle 2.10 in both apps (`SURequireSignedFeed` on):

- With public keys: the published feed verifies only with the old key; a feed signed with the new key and the 1.15.0 zip verify only with the new key (Ed25519 check of the feed's signed bytes and the enclosure; `sign_update --verify` agrees for the new key).
- 1.15.0 against the published feed: "Could not check for updates. The update feed is improperly signed and could not be validated. Please try again later or contact the app developer." No crash, no loop; Sparkle records `SUInitialFailedFeedSigningValidationDate`.
- 1.14.14 against a new-key feed: not seen on screen. The `SUFeedURL` override pointed at a local server but 1.14.14 never fetched it, and a stale Keychain prompt held focus for the manual check. By the key check above it fails the same way, with the same message.

What the apps stored under the real bundle id, all removed (`/tmp/cw-rc-scratch/cleanup-real.sh`):

- Defaults `dev.candywrapper.app`: `appearance.mode`, `theme.preference`, `ditherPicturePath`, `clientSettings.v1` (75 keys), `composer.prompts.v1`, `composer.draftSessions.v2`, `composer.identities.v1`, `composer.reviewComments.v1`, `composer.replyTo.v1`, `CandyWrapper.composerModelState.v1`, `experimental.threadTabs`, `orchestrator.v1`, `orchestrator.sync.v1`, `thread.lastOpenScoped`, `SULastCheckTime`, `SUUpdateGroupIdentifier`, `SUInitialFailedFeedSigningValidationDate`, `SUFeedURL` (mine), NSNavPanel keys.
- Files: `~/Library/Application Support/dev.candywrapper.app/Dither/<uuid>.heic`, `~/Library/Caches/dev.candywrapper.app`, `~/Library/HTTPStorages/dev.candywrapper.app`; in the shared `~/Library/Application Support/CandyWrapper`: `environments.json`, `PromptStash/`, `ShellCache/<env>.json` (restored from the backup).
- Keychain: generic password service `dev.candywrapper.t3.environment-token`, account `bearer:<sandbox env id>:http://127.0.0.1:47391`, label "T3 Code environment token". Deleted; none left.

## 3. On screen

Release candidate against 4928, then 3824. Default dark, default light, Redesign light, Redesign dark and Glass dark.

Works: launch, thread open, a turn on each server, seven fast sidebar toggles, every Settings tab (23, including Voice, Redesign and Experimental), the command palette, both picker layouts, the access menu with Unrestricted on and off on both servers (no turn while on), a side chat with a turn, the Issues page, the Welcome page from a fresh profile, the message rail at rest, hovered, after a slow exit and after an app switch, sidebar row hover with a slow exit, resting beside it and an app switch, "or start without a project" (inert in pass 3, works now), and window titles "demo-repo / Blue" and "No project / Say Pong".

Wrong, ranked:

1. The empty right panel's "Open a surface" list leaves out Side chat, and its S key does nothing there; the + menu has it. T3 lists it in the empty state too (RightPanelTabs.tsx:410-422, passed at :1635-1654). `SurfaceLauncherView.rebuild` and `handleKey` (RightPanelView.swift:650, :667) don't pass `sideChat`.
2. The window title keeps the last thread on the Issues page ("demo-repo / Blue"); T3's title follows the route. `WindowTitleController` reads the open thread session, not the shown page.
3. Redesign only: "Replying to" shows an info icon where the default theme shows the message ("Replying to Apple") at the same width.
4. Glass: the narrow main composer shortens the model to "Haiku…" with a wide gap before "Medium".
5. Escape in the thread doesn't cancel "Replying to" unless the composer has focus.

Not reached: the PR panel beyond its disabled rows (the sandbox repo has no remote), the Issues and side chat idle runs (below), the model chip popover in a sent message, and pass 1 to 3's items that need a linked issue, a provider out of usage, a reclaim recommendation or a Finder drag. The Welcome page's import would copy this Mac's real Claude Code and Codex history into the sandbox (the sandbox server shares HOME), so I unticked it.

## 4. Idle

procstat over 120 s after a 60 s settle, powermetrics in the same window, a 5 s sample. RC on 3824 with Say Pong open:

| State | CPU | Interrupt wakeups/s | Package idle/s | Footprint | Main thread |
|---|---|---|---|---|---|
| Thread open | 0.01% | 0.40 | 0.02 | 46.4 MB | mach_msg, 4262 of 4262 |
| Settings open | 0.02% | 0.38 | 0.03 | 68.7 MB | mach_msg |
| Window hidden | 0.00% | 0.37 | 0.05 | 61.7 MB | mach_msg |

1.14.14 on the same thread, measured the same way: 0.01% CPU, 0.38 interrupt and 0.00 package idle wakeups/s, 39.1 MB, main thread in mach_msg.

The wakeups are the same in every state, hidden included, and the same in 1.14.14, and no app timer shows in the samples: they come from the 3824 server's pushes on the open socket, not from a 1.15.0 timer. No idle timer blocks the release. The Issues page and side chat idle runs weren't done: an orphaned Keychain prompt held focus, and I don't click those. 1.15.0 holds 7 MB more than 1.14.14 on this small thread (46.4 against 39.1 MB) and 22 MB more after Settings has been opened (68.7 MB), which it keeps while hidden (61.7 MB).

Memory, thread open on 4928 (Blue, after opening the 51-message thread): 1.15.0 46.3 to 46.7 MB, 1.14.14 48.0 to 48.1 MB. docs/benchmarks.md has 41 MB idle on a thread for M8 on the old Mac, with no 1.14 number.

## 5. Performance

`scripts/perf-review --no-app` against the newest saved runs (October, on the old M4 Mac) flagged 27 regressions, which is mostly the slower M2 Pro. Run against v1.14.14 built and measured on this Mac (`--commit v1.14.14`), four metrics are over 20% slower:

| Metric | 1.14.14 | 1.15.0 | Change |
|---|---|---|---|
| paging_seeded2000_main | 1.29 ms | 3.07 ms | +137% |
| paging_seeded2000_total | 1.64 ms | 3.07 ms | +87% |
| paging_huge_main | 2.17 ms | 3.53 ms | +63% |
| huge_open_long_derive | 0.25 ms | 0.31 ms | +22% |

Paging most likely costs more because one Load earlier now pages on until a turn starts (543356f2, T3's #24417); each step is still a few ms. The sidebar at 1,580 threads takes about 25 ms per rename or clock tick in both versions (24.7 and 25.6 ms), against 0.4 to 0.7 ms in October's runs on the old Mac; that predates 1.14.14 and is worth its own look.

The app scenarios need `perf-home-pristine` with the threads "Reply with one word: candy" and "Numbers 1 to 1000", which neither sandbox has; making them costs real turns, so I measured by hand on 4928 with `CANDY_LAUNCH_TIMING` and `CANDY_THREAD_TIMING`, cold cache per launch, medians of 5 and 3 runs:

| | 1.14.14 | 1.15.0 |
|---|---|---|
| Window built | 0.177 s | 0.176 s |
| Live sidebar | 0.304 s | 0.301 s |
| Blue (10 messages) first frame, cold | 55.7 ms | 54.9 ms |
| Largest thread (51 messages) first frame, cold | 85.8 ms | 78.9 ms |
| Blue reopen | 53.1 ms | 62.0 ms (+17%) |
| Largest reopen | 61.2 ms | 62.4 ms |

No regression over 20%. Typing latency wasn't measured: the stall-monitor run lost focus to a Keychain prompt.

## 6. Hygiene

- `scripts/secretscan origin/main..catchup-4928` exits 0.
- README.md's note at the top is unchanged since main; the only change is the new "If you have 1.14.14 or older" section at line 37.
- PNGs changed since main outside design/: 9, all MCP logos in `Features/Resources/mcp-logos/`, no screenshots. No PNG changed since main (507 with design/) has the hostname, the account name, a home path or an e-mail in its bytes.
- T3 branding: new "T3 Code" strings name T3's server or products (update, restart, MCP, the phone app). The only other place is the URL scheme label `CFBundleURLName = T3 Code`, unchanged since 1.14.14. No T3 logo in the bundle.
- `codesign -dvv` of the RC: `Authority=Apple Development: <e-mail> (8TZ464JNCL)`, `TeamIdentifier=8Q677AYRU7`, hardened runtime, Sparkle key `uEahF8lF…`. The new certificate's name carries the approved public address; the published 1.14.14's carries a different, private address.

Both benchmark runs are saved for later comparisons on this Mac: `docs/perf/2026-11-20-9c093ca-w1.*` (1.15.0) and `docs/perf/2026-11-20-77e71f2-w1.*` (1.14.14).

## Fixes

- 9c093cac test(stress): follow the history cursor a page returns, like ThreadSession.

## Housekeeping

Unrestricted is off on both sandboxes, and no file in either sandbox home contains `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS`. Real turns: 3 of 12. I held the screen lock past 15 minutes once, during the idle and timing runs, until it expired at 20; another agent then took it. Two orphaned SecurityAgent prompts appeared ("T3 Code environment token" from my Keychain test, which later closed, and "security wants to use the candywrapper-release keychain" from another session's `security` call); I clicked neither. `~/Library/Application Support/CandyWrapper Helper/versions/1.15.0/` (the helper binary and VERSION) appeared at 02:02 while none of my apps ran; another session made it, so I left it. My pairing session "release-check 1.14.14" stays on the 3824 sandbox. The backup of the shared CandyWrapper folders and every scratch build are deleted; /tmp/cw-release-check stays.
