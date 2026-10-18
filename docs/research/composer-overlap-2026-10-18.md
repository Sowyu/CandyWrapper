# Composer layout overlap

The reported screenshot shows the expanded footer over the prompt in a composer that still has its collapsed 50pt frame. The editor's line count did not change when expanded chrome took over, so the existing height callback never reached the parent. An external blocker such as a menu or timeline overflow could also change between the parent's height measurement and the composer's layout.

`ComposerView` now invalidates the parent's height when a refreshed state needs a different total height. Its layout checks for a remaining mismatch and queues one reconciliation after the current AppKit pass. Matching heights queue nothing. A blocker clears the previous scroll-collapse state, so removing it does not unexpectedly collapse the composer again or create a feedback loop as the timeline inset changes. No repeating timer, idle polling or protocol change was added.

## T3 source

At the tag in `T3_VERSION`, `apps/web/src/components/chat/ChatComposer.tsx:4768-4788` derives the resting layout from expanded chrome, multiline text and timeline overflow. Lines 4907-4911 clear the scroll-collapse state when expanded chrome makes collapse ineligible. Lines 7156-7178 switch the footer placement and hide its expanded controls with that same resting state. The native frame and footer now settle together while preserving the established pixels in each state.

## Regression checks

`ComposerLayoutTransitionTests` covers a submission blocker and an external blocker discovered after only the composer was invalidated. Both tests failed before the fix: the frame remained 50pt while `preferredHeight` was 144pt, and the primary action began at y=1 above the placeholder's bottom. They check that the expanded frame clears the placeholder and remains expanded after the blocker is removed.

The initial fix passed all 13 focused transition, panel and composer fidelity tests. The final code passed all 1,534 Swift Testing tests and 17 XCTest tests through `scripts/test`, and the isolated Debug app built successfully. Diff review confirmed that height reconciliation queues only on a mismatch, captures the composer weakly and leaves matched layouts alone.

After the user unlocked the remote desktop, real-window checks passed in Glass light and dark against the isolated sandbox. Scrolling the long Numbers thread collapsed the composer; clicking the prompt restored its full height with the footer below the placeholder. The model menu also opened with the expanded frame intact. Screenshots are in `~/CandyWrapper-research/sandbox/composer-overlap/`: `cw-composer-dark-collapse.png`, `cw-composer-dark-expanded.png`, `cw-composer-dark-menu.png`, `cw-composer-light-collapse.png` and `cw-composer-light-expanded.png`. The isolated app was quit and its build folder removed after the checks.

The [43 package benchmarks](../perf/2026-10-18-composer-overlap-benchmarks.md) initially flagged 21 metrics against the newest saved run containing those metrics. A [warm rerun](../perf/2026-10-18-composer-overlap-benchmarks-recheck.md) of the same binary passed all 10 benchmark tests and reduced the flags to one: `huge_full_panel`, at 5.02 ms versus a 3.97 ms baseline. That metric was 4.05 ms in the first run; its rerun range of 1.89-6.08 ms overlaps the baseline's 1.79-5.39 ms. The variation remains recorded rather than attributed to this fix. These were `--no-app` checks; no app idle CPU, memory or energy measurements were taken while the GUI was locked.

## Release

Published [v1.5.6 (build 31)](https://github.com/Sowyu/CandyWrapper/releases/tag/v1.5.6) from `827fce07d75f3ff12b2a62ae15d957cf02ddf393` on 2026-10-18 using `scripts/release`. The clean Release build and strict app signature check passed. The script verified both uploaded downloads against their local SHA-256 hashes, signed the appcast and verified that the published update-feed URL served it.

- ZIP SHA-256: `a2e555e2daa09d222f2b8b95f4912f604f89dd1a1685618ec141c3bf5bd01147`
- DMG SHA-256: `d8d613ed0bb567cf95770e25bfdfe40d754a93172a1ada281a0aaad25d42ec97`
