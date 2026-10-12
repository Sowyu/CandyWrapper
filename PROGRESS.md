# Progress

The current state and the open work. Before you stop, tick what you finished, add what the next agent must know, and keep this file short: finished work belongs in the git log, and the full history up to 2026-10-12 is in `docs/history/`.

## State on 2026-10-13

- Milestones 1 to 9 are done. Milestone 10's stress half is done (`docs/research/m10-report-2026-10-12.md`); its side-by-side half is open.
- The latest release is v0.1.15. The user runs it daily on their MacBook and reports what they see.
- The app works with T3 servers 0.0.46-nightly.20261009.2861 (pinned in `T3_VERSION`) and 20261011.2994. Its UI is caught up with 2861; task 2 covers 2994.
- A scheduled T3 task runs `docs/nightly-catch-up.md` every Monday and Thursday at 03:00, Mac time, in a new thread each time.

## Open tasks

Do next:

1. Exercise every row of `docs/parity-checklist.md` next to T3 Code Nightly, in both themes, on the same sandbox data. A row turns ✅ only when both apps match. The method is in `docs/research/m10-side-by-side-2026-10-12.md`. This is by far the biggest task, so take one checklist section per chat and mark rows as you go.
2. Build the newer Nightly's UI from `docs/research/nightly-diff-2994.md`: shared model favorites, the pull request panel's confirm in place and comment filters, the parent thread breadcrumb, draggable right panel tabs, a searchable project picker, the storage cleanup report, OpenTelemetry export and per-project provider toggles. The app must keep working with 2861 servers. Ask the user before you re-pin `T3_VERSION`. T3's source at 2994 isn't on this Mac: `git clone --depth 1 --branch v0.0.46-nightly.20261011.2994 https://github.com/pingdotgg/t3code /tmp/t3code-2994`.
3. An 18,000-line code block takes 0.9 s and 294 MB to open, because every line lays out up front (`docs/research/m10-load-2026-10-12.md`).
4. The sidebar rebuilds fully on every change and every relative-time tick, about 20 ms at 1,580 threads.

Smaller leftovers:

5. While the sidebar slides open, the main panel reflows once instead of every frame (`SidebarView.swift:175`).
6. The right panel and the terminal still use the old slide. The sidebar's interruptible slide is the model.
7. A fresh Debug app holds the main thread 170 to 200 ms on its first thread open. Measure it in Release first.

The code also marks 267 known shortcuts with `// ponytail:`, each naming when to fix it (`grep -rnE '// ?ponytail:' App Packages/CandyKit/Sources`). They aren't tasks on their own. Fix one when your work touches it.

## Waiting on the user

- The Allow Remote Access design was built as proposed but never confirmed (`docs/decisions.md`).
- An off-machine backup of the Sparkle signing key (`docs/release.md`).

## Different from T3 on purpose

Leave these alone during side-by-side checks.

- The sidebar title is the candy glyph and "Wrapper", and clicking it goes home.
- The app icon is a black, glossy candy. T3's logo and name stay out of CandyWrapper's branding, to avoid a takedown.
- The Glass theme and the Panel animations setting exist only here.
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
