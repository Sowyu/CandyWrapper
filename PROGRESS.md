# Progress

The current state and the open work. Before you stop, tick what you finished, add what the next agent must know, and keep this file short: finished work belongs in the git log, and the full history up to 2026-10-12 is in `docs/history/`.

## State on 2026-10-14

- Milestones 1 to 9 are done. Milestone 10's stress half is done (`docs/research/m10-report-2026-10-12.md`). Its side-by-side half was dropped on 2026-10-13 after keyboard shortcuts and part of the thread view.
- The latest release is v1.2.0 (build 19), published 2026-10-14: frosted Glass, server updates, CandyWrapper's own T3 runtime, cached images. v1.1.0 (build 18) added Glass Native (Experimental) the same day. v1.0.0 (build 17), the first full release, came out 2026-10-13. The user runs it daily on their MacBook and reports what they see.
- The app works with T3 servers 0.0.46-nightly.20261014.3105 (pinned in `T3_VERSION` since 2026-10-14), 20261011.2994 and 20261009.2861. Its wire is caught up with 3105 (`docs/research/nightly-diff-3105.md`). Its UI is caught up with 2861, plus the 2994 features listed in `docs/research/nightly-diff-2994.md` part 2 items 1, 2, 5, 6, 8 and 9, and the 3105 client fixes in `nightly-diff-3105.md` part 3. CandyWrapper's own runtime and its update button now install 3105.
- A scheduled T3 task runs `docs/nightly-catch-up.md` around 2am Melbourne time on Monday and Thursday mornings, in a new thread each time.

## Open tasks

1. Classic Glass gets a pre-blurred wallpaper layer in place of the live blur, the user's Origin technique (`docs/decisions.md`). (taken 2026-10-14)
2. Match the rest of Nightly 3105's UI, most visible first, by `docs/research/nightly-diff-3105.md` part 2. The wire, the reconnect and server-owner fixes and the client fixes are done (2026-10-14). Done: the pending context handoff row and the models on handoff dividers (item 1). Left: full-screen visual replies (2), the timeline fixes in item 3 including the stepped Thinking shimmer (`steps(30)`, index.css:604), the "Subagent needs input" banner, which CandyWrapper lacks altogether (ChatView.tsx:7461-7497, threadShell.ts:33-45), the composer and settings items (4, 7), "Update everything" in the sidebar pill (5), the secret input placeholder (part 1 item 3) and the host-image file access message (11). (taken 2026-10-14)
3. Apply T3's SQLite lessons (#19205, #19226, #19304, #19305, #19324, #18471) to CandyWrapper's own databases and caches. (taken 2026-10-14)

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
