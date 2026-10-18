# Progress

The current state and the open work. Before you stop, tick what you finished, add what the next agent must know, and keep this file short: finished work belongs in the git log, and the full history up to 2026-10-12 is in `docs/history/`.

## State on 2026-10-18

- Milestones 1 to 9 are done. Milestone 10's stress half is done (`docs/research/m10-report-2026-10-12.md`). Its side-by-side half was dropped on 2026-10-13 after keyboard shortcuts and part of the thread view.
- The latest release is [v1.5.5 (build 30)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.5.5), published 2026-10-18 from `9efd347`: Thinking, compaction and live tool glimmers sweep 2.5 times faster only when the running model uses Fast mode. All 1,532 tests passed; isolated light/dark screen checks and code review completed. Signed app, downloaded ZIP/DMG hashes and automatic-update feed verified. Previous: [v1.5.4 (build 29)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.5.4), published 2026-10-17 from `794afc4`: removes the rejected resting backgrounds from sidebar search and compose while keeping the softer blur and interaction feedback. All 113 focused tests and native light/dark checks passed. Signed app, downloaded ZIP/DMG hashes and automatic-update feed verified. Previous: [v1.5.3 (build 28)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.5.3), published 2026-10-17 from `77e81a9`: softer sidebar artwork and clean Glass search/compose surfaces, visible prompt text below image groups, and opaque floating browser previews placed clear of the composer and details. Full suite: 1,530 tests; final border cleanup: 113 focused tests. App performance comparison found no threshold regressions. Signed app, downloaded ZIP/DMG hashes and automatic-update feed verified. Previous: [v1.5.2 (build 27)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.5.2), published 2026-10-17: in Glass the thread header itself is the progressive blur, and rows scroll on under it. Full suite and perf review skipped at the user's request; checked on screen in Glass dark. Previous: [v1.5.1 (build 26)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.5.1), published 2026-10-17: the sidebar candy art blurs progressively into its fade, and in Glass a progressive backdrop blur replaces the hard edge under the thread header. Signed ZIP, DMG and automatic-update feed verified. Previous releases: [v1.5.0 (build 25)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.5.0), published 2026-10-17: wide tables scroll and expand, the client catches up to Nightly 3234, and CandyWrapper's own server updates independently with verified downloads, database backups and rollback. Signed ZIP, DMG and automatic-update feed verified. Remaining parity work stays listed below. Previous releases: [v1.4.3 (build 24)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.4.3), published 2026-10-16: Appearance loads fonts and theme previews off the main thread, Markdown width caches are bounded, recycled reasoning and expanded HTML lifetimes are fixed, sidebar snooze scans avoid thread copies, long task titles truncate, and compacting text draws once. Signed ZIP, DMG and automatic-update feed verified. v1.4.2 (build 23), published 2026-10-16: the Woke pill sits beside the hover actions, dismisses on click and clears when the thread is opened (a decided difference from T3), a snooze ends on time under a collapsed shelf, and opening a thread visits it at once. v1.4.1 (build 22), published 2026-10-15: CandyWrapper keeps retrying a local T3 server that is up but silent (T3 Code migrating after its own update to 3145) instead of a dead-end alert. v1.4.0 (build 21), published 2026-10-15: the optimisation pass (stalls, fewer requests per thread switch, the own server's priority and cold start, connection in bad moments, faster parsing and thread cache) and the Glass sidebar edge. v1.3.0 (build 20), published 2026-10-14: Nightly 3105's UI with Update everything and prompt links, full screen visual replies, database backups around CandyWrapper's own runtime updates, Glass on a pre-blurred wallpaper, Glass Native removed. v1.2.0 (build 19) brought frosted Glass, server updates, CandyWrapper's own T3 runtime and cached images. v1.1.0 (build 18) added Glass Native (Experimental) the same day. v1.0.0 (build 17), the first full release, came out 2026-10-13. The user runs it daily on their MacBook and reports what they see.
- The app is pinned to v0.1.1-nightly.20261017.3234 and was checked against isolated 3234 and 3105 servers. The 207-commit contracts audit found additive wire changes and verified that #19559 only prunes comments. The main 3234 UI changes are ported; remaining parity work and validation limits are in [the 3234 audit](docs/research/nightly-diff-3234.md). Older 2994 and 2861 support remains covered by recorded fixtures. CandyWrapper's own runtime now checks its T3 channel independently of this pin, with separate Download and Restart actions.
- A scheduled T3 task runs `docs/nightly-catch-up.md` around 2am Melbourne time on Monday and Thursday mornings, in a new thread each time.

- [x] Performance and visual audit (2026-10-16): removed Appearance font/preview work from the main thread, bounded Markdown width caches, fixed recycled reasoning and expanded HTML lifetimes, and removed the snooze-scan regression. All 1,514 tests pass. Release review: 193 ms window, 0.042% idle CPU, 34 MB idle footprint. Measurements, follow-up checks and remaining limits: [audit report](docs/perf/README.md#performance-and-visual-audit-2026-10-16). Released in v1.4.3.

## Open tasks

- [x] Full bug, redundancy and codebase audit (2026-10-18): three high-priority file-save risks and five medium-priority state/resource defects, plus duplication candidates and app integration test gaps. All 1,532 Swift Testing and 17 XCTest tests passed; isolated app build and sandbox snapshot passed. Product behavior is unchanged. [Audit and repair order](docs/research/codebase-audit-2026-10-18.md).

- [ ] Repair the eight findings from the [2026-10-18 codebase audit](docs/research/codebase-audit-2026-10-18.md): start with workspace file identity, environment-scoped buffers and writer ownership across editor closure. The save-handoff race was reproduced with the production coordinator; the other findings have source traces and proposed regression checks.

- [x] Fast-mode activity glimmer (2026-10-18): 0.88 second sweeps for Fast runs, 2.2 seconds for normal runs, based on the current run rather than the next prompt. All 1,532 tests passed; isolated light/dark checks and code review completed. Published v1.5.5 (build 30) from `9efd347`; signatures, ZIP/DMG downloads and signed update feed verified. [Notes](docs/research/fast-mode-glimmer-2026-10-18.md).

- [x] Published v1.5.4 (build 29) from `794afc4` on 2026-10-17: transparent sidebar search/compose controls. Signed app, ZIP/DMG downloads and update feed verified.

- [x] Removed the rejected resting backgrounds from sidebar search and compose (2026-10-17), retaining the approved blur and hover/focus feedback. All 113 focused sidebar tests passed; real light/dark screenshots checked. [Notes and screenshots](docs/research/sidebar-header-2026-10-17.md#remove-the-rejected-backgrounds). Released in v1.5.4.

- [x] Final sidebar outline cleanup and v1.5.3 release (2026-10-17): removed resting search/compose borders, kept editing and keyboard focus feedback, checked light/dark screenshots and 113 focused tests, then published build 28 from `77e81a9`. Release signatures, downloads and update feed verified.

- [x] Sidebar header polish (2026-10-17): a longer candy blur fades directly into the sidebar; Glass gets a rounded search surface with focus feedback and a softer compose action. Real-window light/dark screenshots and search interactions checked. All 1,530 tests passed; app performance review found no threshold regressions (38 MB idle, 0.048% CPU). [Review and screenshots](docs/research/sidebar-header-2026-10-17.md). Released in v1.5.3.

- [ ] Profile the memory increase already present in v1.5.2: about 38 MB idle and 85 MB startup peak, versus the pre-blur baseline of 34 MB and 34 MB. An isolated published-release control matches the prompt/preview fix build. The cause is not yet isolated. [Measurements](docs/research/prompt-preview-layout-2026-10-17.md#performance-review).

- [x] Prompt and floating preview fixes (2026-10-17): attachments keep their full height above separately collapsed prompt text; browser previews and their control bars are opaque and avoid the details card and composer. Checked in real Glass light/dark windows, including expand. Full suite: 1,530 tests; final focused checks: 9 tests. Performance matches released v1.5.2; the older baseline exposes a pre-existing memory increase. [Review and screenshot paths](docs/research/prompt-preview-layout-2026-10-17.md). Released in v1.5.3.

- [x] Progressive blur (2026-10-17): the sidebar art bakes a CIMaskedVariableBlur once per size, and Glass puts a 32pt backdrop `variableBlur` over the timeline top (its mask is read from alpha, one pixel per device pixel, so the backdrop samples at full scale). 131 focused tests passed; the user skipped the full suite and perf-review for this release. Checked on screen in Glass dark.
- [x] Release v1.5.1 (build 26), published 2026-10-17 from `8915cc0`: Release build, app signatures, downloaded ZIP/DMG hashes and published signed update feed verified.
- [x] Release v1.5.0 (build 25), published 2026-10-17 from `ab31217`: Release build, app signatures, downloaded ZIP/DMG hashes and published signed update feed verified.

- [x] Wide Markdown tables (2026-10-17): horizontal scrolling and fades, per-table expansion across streaming, Markdown/CSV copy, row-height updates, light/dark fidelity and sandbox checks including Classic Glass. Full suite: 1,501 tests, then 42 focused checks after the height fix. Perf: no threshold regressions, 198 ms window, 0.043% idle CPU, 34.2 MB idle footprint; two scroll samples had about 60 ms stalls. [Notes](docs/research/wide-tables-2026-10-17.md).
- [x] Nightly catch-up (2026-10-17): pinned 3234, audited all 207 commits, ported the main wire/UI changes and checked 3234 and 3105 sandbox turns. Full suite: 1,527 tests run; the final breadcrumb expectation was corrected, then all 107 focused checks passed. Fresh app build and light/dark screen checks passed. Perf: no threshold regressions, 182 ms window, 0.047% idle CPU, 34.2 MB; one 51 ms thread-open stall. [Audit and remaining work](docs/research/nightly-diff-3234.md), [perf](docs/perf/2026-10-17-1d8f066-dirty-w1.md).
- [x] Independent server runtime updates (2026-10-17): channel checks after 15 s and on activation, no idle poll, separate verified Download and Restart, database backup and rollback through authenticated RPC verification, and generic fallback for unfamiliar timeline items. Sandbox 3105 updated to newly published 3238 independently of the 3234 client pin; failed startup restored 3105 and retry succeeded. Full suite: 1,541 tests; final runnable update check: 17 tests. Light/dark screen checks passed. Perf: 194 ms window, 0.045% idle CPU, 34.6 MB idle footprint, 378.5 ms scroll CPU. A single streaming-memory flag did not repeat in three isolated checks (34.6–34.7 MB). [Implementation and review](docs/research/server-updates-2026-10-17.md), [full perf and follow-up](docs/perf/2026-10-17-d7db15d-dirty-w1.md). Released in v1.5.0.

- [ ] Remaining 3234 parity: cross-environment thread attachments, per-machine Update everything, Connect repair/pairing changes, smaller visual comparisons, and ANSI colors/follow-end in live command output. See [the audit](docs/research/nightly-diff-3234.md#5-review-and-remaining-work), including the PR-host validation limit.

1. Left from the 2026-10-14 nightly audit, all minor. "Use a separate review guide model" and the writer model switch copy the raw stored selection, where T3 copies the resolved `activeSelection`, disables the switch when that model can't run and toasts "Review guide model not saved" (SourceControlWritingSettings.tsx:132-143, 529-552). Update everything works out its servers again when you confirm, so a machine that came back online during the dialog gets updated although the dialog said it would be skipped; T3's dialog re-renders instead. The 2026-10-17 runtime update work arms backup recovery before the trial starts. The narrower external-write crash window remains documented in `ServerController.finishPendingRestore`. Smaller: `missingFileAccess` keys images by path without the environment (`ThreadSession.swift:648`), the Glass backdrop can show the picture on an inactive window for one render (`WallpaperBackdrop.swift:422`), and a cancelled quiet server update counts as failed where T3 counts it as skipped (no caller cancels one today).

2. Left from the 2026-10-15 optimisation pass (`docs/perf/README.md`, the sections dated 2026-10-14). These are the stalls left over 50 ms: the first open of a very long markdown reply blocks about 150 ms, since parsing it on the main thread needs a layout cache keyed by font, theme and Glass, and opening Settings and the first window draw stall once each, for 55 to 75 ms. The VCS status stream still resubscribes when a thread switch changes project. An idle frontmost window on a silently dead remote network reads "Connected" until something is sent (`docs/decisions.md`). The network change check misses two Wi-Fi networks behind the same router address. Removing a worktree from the sidebar leaves the branch picker's refs cache up to 30 s stale.
3. Battery: use as little energy as possible where the user spends hours, counting the T3 server CandyWrapper starts: idle, an agent streaming in the open thread, agents running in other threads, and the window hidden. Measure with `scripts/procstat` (kernel energy, CPU and wakeups) before and after each fix. (taken 2026-10-15)

4. Narrow composer banners: beside a wide right panel, a long manual server-update action can clip when the Stash badge also shows. Match T3's wrapping notice/action rows and add a narrow reference before changing the common banner height (`ComposerBanner.tsx:191-211,263-270`, `ComposerBannerStack.tsx:353-372`). Found during the 2026-10-16 audit.

The user dropped the side-by-side sweep of the parity checklist on 2026-10-13 (`docs/decisions.md`).

The code marks known shortcuts with `// ponytail:`, each naming when to fix it (`rg '// ?ponytail:' App Packages/CandyKit/Sources`). They aren't tasks on their own. Fix one when your work touches it.

## Waiting on the user

- The Allow Remote Access design was built as proposed but never confirmed (`docs/decisions.md`).
- An off-machine backup of the Sparkle signing key (`docs/release.md`).
- Whether Settings should note an older official T3 Code app installed next to CandyWrapper's newer T3 runtime (asked 2026-10-14).

## Different from T3 on purpose

Leave these alone during side-by-side checks.

- The sidebar title is the candy glyph and "Wrapper", and clicking it goes home.
- The app icon is a black, glossy candy. T3's logo and name stay out of CandyWrapper's branding, to avoid a takedown.
- The Glass theme and the Panel animations setting exist only here. The Glass opacity slider goes down to 10%, where T3 stops at 40%.
- Escape leaves Settings.
- Updates come from this repo's GitHub releases through Sparkle, and an update keeps agents on this Mac's server running.
- Quitting asks first only while an agent runs on this Mac's own server.
- Editing a project action without touching its shortcut keeps the shortcut, where T3 drops it.
- A Read row's file preview that fails to load removes itself, and is skipped when the result already carries the image. T3 keeps an empty slot (ChatMarkdown.tsx:1491-1510). The user asked on 2026-10-14.

## Looks wrong, matches T3

- A provider retry shows twice under an opened working group (T3's MessagesTimeline.logic.ts:1501-1512).
- Restoring a stash uploads its images again (T3's ChatComposer.tsx:5031-5033).
- Lineage lists three finished agents as running. The official app shows the same stale server data.

## On this Mac right now

- The user's own CandyWrapper v0.1.2 runs from `/tmp/cw-demo-012` against the live T3, normally tracked in `/tmp/cw-demo.pid`. That file was missing during the 2026-10-16 audit; verify the executable before using a separate `CANDY_DEMO_PID_FILE` for performance reviews. Leave the app alone.
- A Reminders window has been open on the GUI screen since 2026-10-12. Leave it alone.
- The user builds a Zen browser fork here and needs about 80 GB for it. `scripts/preflight` guards the disk.
