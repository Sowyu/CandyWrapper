# Progress

The current state and the open work. Before you stop, tick what you finished, add what the next agent must know, and keep this file short: finished work belongs in the git log, and the full history up to 2026-10-12 is in `docs/history/`.

## State on 2026-10-13

- Milestones 1 to 9 are done. Milestone 10's stress half is done (`docs/research/m10-report-2026-10-12.md`). Its side-by-side half was dropped on 2026-10-13 after keyboard shortcuts and part of the thread view.
- The latest release is v1.0.0 (build 17), the first full release, published 2026-10-13. The user runs it daily on their MacBook and reports what they see.
- The app works with T3 servers 0.0.46-nightly.20261009.2861 (pinned in `T3_VERSION`) and 20261011.2994. Its UI is caught up with 2861, plus the 2994 features listed in `docs/research/nightly-diff-2994.md` part 2 items 1, 2, 5, 6, 8 and 9 (done 2026-10-13).
- A scheduled T3 task runs `docs/nightly-catch-up.md` around 2am Melbourne time on Monday and Thursday mornings, in a new thread each time.

## Open tasks

1. Glass Native (Experimental): phases 1 to 3 and the design polish are done (`docs/glass-native.md`). Left, in order:
   - Phase 5a: native menus throughout and the glass command palette, in T3 desktop's layout, plus the composer's low contrast in dark mode. (taken 2026-10-14)
   - Phase 6: a bug hunt over every action in native mode next to classic, and a familiarity pass against T3 desktop.

The user dropped the side-by-side sweep of the parity checklist on 2026-10-13 (`docs/decisions.md`).

The code also marks 267 known shortcuts with `// ponytail:`, each naming when to fix it (`grep -rnE '// ?ponytail:' App Packages/CandyKit/Sources`). They aren't tasks on their own. Fix one when your work touches it.

## Waiting on the user

- The Allow Remote Access design was built as proposed but never confirmed (`docs/decisions.md`).
- An off-machine backup of the Sparkle signing key (`docs/release.md`).

## Different from T3 on purpose

Leave these alone during side-by-side checks.

- The sidebar title is the candy glyph and "Wrapper", and clicking it goes home.
- The app icon is a black, glossy candy. T3's logo and name stay out of CandyWrapper's branding, to avoid a takedown.
- The Glass theme and the Panel animations setting exist only here. The Glass opacity slider goes down to 10%, where T3 stops at 40%.
- Escape leaves Settings.
- Updates come from this repo's GitHub releases through Sparkle, and an update keeps agents on this Mac's server running.
- Quitting asks first only while an agent runs on this Mac's own server.
- Editing a project action without touching its shortcut keeps the shortcut, where T3 drops it.

## Looks wrong, matches T3

- A provider retry shows twice under an opened working group (T3's MessagesTimeline.logic.ts:1501-1512).
- Restoring a stash uploads its images again (T3's ChatComposer.tsx:5031-5033).
- Lineage lists three finished agents as running. The official app shows the same stale server data.

## On this Mac right now

- The user's own CandyWrapper v0.1.2 runs from `/tmp/cw-demo-012` against the live T3, PID in `/tmp/cw-demo.pid`. Leave it alone.
- A Reminders window has been open on the GUI screen since 2026-10-12. Leave it alone.
- The user builds a Zen browser fork here and needs about 80 GB for it. `scripts/preflight` guards the disk.
