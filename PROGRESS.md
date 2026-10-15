# Progress

The current state and the open work. Before you stop, tick what you finished, add what the next agent must know, and keep this file short: finished work belongs in the git log, and the full history up to 2026-10-12 is in `docs/history/`.

## State on 2026-10-14

- Milestones 1 to 9 are done. Milestone 10's stress half is done (`docs/research/m10-report-2026-10-12.md`). Its side-by-side half was dropped on 2026-10-13 after keyboard shortcuts and part of the thread view.
- The latest release is v1.3.0 (build 20), published 2026-10-14: Nightly 3105's UI with Update everything and prompt links, full screen visual replies, database backups around CandyWrapper's own runtime updates, Glass on a pre-blurred wallpaper, Glass Native removed. v1.2.0 (build 19) brought frosted Glass, server updates, CandyWrapper's own T3 runtime and cached images. v1.1.0 (build 18) added Glass Native (Experimental) the same day. v1.0.0 (build 17), the first full release, came out 2026-10-13. The user runs it daily on their MacBook and reports what they see.
- The app works with T3 servers 0.0.46-nightly.20261014.3105 (pinned in `T3_VERSION` since 2026-10-14), 20261011.2994 and 20261009.2861. Its wire is caught up with 3105 (`docs/research/nightly-diff-3105.md`). Its UI is caught up with 2861, plus the 2994 features listed in `docs/research/nightly-diff-2994.md` part 2 items 1, 2, 5, 6, 8 and 9, and 3105's `nightly-diff-3105.md` parts 2 and 3. CandyWrapper's own runtime and its update button now install 3105.
- A scheduled T3 task runs `docs/nightly-catch-up.md` around 2am Melbourne time on Monday and Thursday mornings, in a new thread each time.

## Open tasks

1. Left from the 2026-10-14 nightly audit, all minor. "Use a separate review guide model" and the writer model switch copy the raw stored selection, where T3 copies the resolved `activeSelection`, disables the switch when that model can't run and toasts "Review guide model not saved" (SourceControlWritingSettings.tsx:132-143, 529-552). Update everything works out its servers again when you confirm, so a machine that came back online during the dialog gets updated although the dialog said it would be skipped; T3's dialog re-renders instead. A crash after the database backup and before any restore still leaves the backup unused (the ponytails in `DatabaseBackup.swift` and `ServerController.finishPendingRestore`). Smaller: `missingFileAccess` keys images by path without the environment (`ThreadSession.swift:648`), the Glass backdrop can show the picture on an inactive window for one render (`WallpaperBackdrop.swift:422`), a reasoning box reused for another thought may not follow the stream (`TimelineWorkRows.swift:574-590`, unconfirmed), the full screen visual reply shares the web frame budget's data store without joining the budget, so once every inline frame releases while it's open Force Reload no longer clears what it stored (`ThreadWebFrameView.swift`), and a cancelled quiet server update counts as failed where T3 counts it as skipped (no caller cancels one today).

2. Left from the 2026-10-15 optimisation pass (`docs/perf/README.md`, the sections dated 2026-10-14). These are the stalls left over 50 ms: the first open of a very long markdown reply blocks about 150 ms, since parsing it on the main thread needs a layout cache keyed by font, theme and Glass, and opening Settings and the first window draw stall once each, for 55 to 75 ms. The VCS status stream still resubscribes when a thread switch changes project. An idle frontmost window on a silently dead remote network reads "Connected" until something is sent (`docs/decisions.md`). The network change check misses two Wi-Fi networks behind the same router address. Removing a worktree from the sidebar leaves the branch picker's refs cache up to 30 s stale.

The user dropped the side-by-side sweep of the parity checklist on 2026-10-13 (`docs/decisions.md`).

The code also marks 267 known shortcuts with `// ponytail:`, each naming when to fix it (`grep -rnE '// ?ponytail:' App Packages/CandyKit/Sources`). They aren't tasks on their own. Fix one when your work touches it.

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

- The user's own CandyWrapper v0.1.2 runs from `/tmp/cw-demo-012` against the live T3, PID in `/tmp/cw-demo.pid`. Leave it alone.
- A Reminders window has been open on the GUI screen since 2026-10-12. Leave it alone.
- The user builds a Zen browser fork here and needs about 80 GB for it. `scripts/preflight` guards the disk.
