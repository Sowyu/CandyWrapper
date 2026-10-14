# Progress

The current state and the open work. Before you stop, tick what you finished, add what the next agent must know, and keep this file short: finished work belongs in the git log, and the full history up to 2026-10-12 is in `docs/history/`.

## State on 2026-10-14

- Milestones 1 to 9 are done. Milestone 10's stress half is done (`docs/research/m10-report-2026-10-12.md`). Its side-by-side half was dropped on 2026-10-13 after keyboard shortcuts and part of the thread view.
- The latest release is v1.2.0 (build 19), published 2026-10-14: frosted Glass, server updates, CandyWrapper's own T3 runtime, cached images. v1.1.0 (build 18) added Glass Native (Experimental) the same day. v1.0.0 (build 17), the first full release, came out 2026-10-13. The user runs it daily on their MacBook and reports what they see.
- The app works with T3 servers 0.0.46-nightly.20261014.3105 (pinned in `T3_VERSION` since 2026-10-14), 20261011.2994 and 20261009.2861. Its wire is caught up with 3105 (`docs/research/nightly-diff-3105.md`). Its UI is caught up with 2861, plus the 2994 features listed in `docs/research/nightly-diff-2994.md` part 2 items 1, 2, 5, 6, 8 and 9, and the 3105 client fixes in `nightly-diff-3105.md` part 3. CandyWrapper's own runtime and its update button now install 3105.
- A scheduled T3 task runs `docs/nightly-catch-up.md` around 2am Melbourne time on Monday and Thursday mornings, in a new thread each time.

## Open tasks

2. Match the rest of Nightly 3105's UI by `docs/research/nightly-diff-3105.md` part 2. Done before: items 1, 2, 6, 8, 9, 11, most of 3, 7 and 12, Markdown links in questions and mid-message `/` search. Done 2026-10-14 (nightly-3105-ui2): "Update everything" from the sidebar update button (5, d83929ad0 and eeaac49a9: the circled arrow, the confirmation with restarts and skipped machines, providers then servers then this app, one result toast that survives the relaunch); the review guide rows with traits pickers beside the writer and review guide models (7, e688034b5), and the settings search catalog regenerated from 3105; the popover exit fade (f570294df); an open citation comment saves into the prompt when a question takes the editor (9fb4ddb2d); dropped threads go into question answers and the answer sends them as `t3-thread://` links (34f845832); the question panel references recaptured from the 3105 web client (06 now 1.7% where it was 2.7%, the drift was 3105's Markdown question text). Checked on screen: live-follow after Settings already holds in CW (83fbbc18f needs nothing), the secret input field matches T3 (`/tmp/cw-peek/3105ui2-secret-*`). Not needed: the composer border while the model strip expands (ca728ec4b), since CW doesn't animate the model strip. Left: prompt links (10, 5fe7568e8, a large feature); the full screen visual reply bug where a Mermaid diagram drew over the dialog's zoom bar: CW now decodes diagram PNGs into plain bitmaps, the suspected cause, but I couldn't reproduce the bug to confirm it; on screen still: the "Subagent needs input" banner, the merge button animation (needs a GitHub PR) and "Update everything" against a server that can update remotely. (taken 2026-10-14)
3. T3's SQLite lessons are applied to CandyWrapper's cache files (061a6d0, `docs/perf/README.md`). Left: a perf review against `docs/perf/2026-10-14-46681ff-w1.json`, which Origin's energy runs kept interrupting.

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
