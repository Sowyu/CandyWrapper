# Composer layout overlap

The reported screenshot shows the expanded footer over the prompt in a composer that still has its collapsed 50pt frame. The editor's line count did not change when expanded chrome took over, so the existing height callback never reached the parent. An external blocker such as a menu or timeline overflow could also change between the parent's height measurement and the composer's layout.

`ComposerView` now invalidates the parent's height when a refreshed state needs a different total height. Its layout checks for a remaining mismatch and queues one reconciliation after the current AppKit pass. Matching heights queue nothing. A blocker clears the previous scroll-collapse state, so removing it does not unexpectedly collapse the composer again or create a feedback loop as the timeline inset changes. No repeating timer, idle polling or protocol change was added.

## T3 source

At the tag in `T3_VERSION`, `apps/web/src/components/chat/ChatComposer.tsx:4768-4788` derives the resting layout from expanded chrome, multiline text and timeline overflow. Lines 4907-4911 clear the scroll-collapse state when expanded chrome makes collapse ineligible. Lines 7156-7178 switch the footer placement and hide its expanded controls with that same resting state. The native frame and footer now settle together while preserving the established pixels in each state.

## Regression checks

`ComposerLayoutTransitionTests` covers a submission blocker and an external blocker discovered after only the composer was invalidated. Both tests failed before the fix: the frame remained 50pt while `preferredHeight` was 144pt, and the primary action began at y=1 above the placeholder's bottom. They check that the expanded frame clears the placeholder and remains expanded after the blocker is removed.

The initial fix passed all 13 focused transition, panel and composer fidelity tests. The final code passed all 1,534 Swift Testing tests and 17 XCTest tests through `scripts/test`, and the isolated Debug app built successfully. Diff review confirmed that height reconciliation queues only on a mismatch, captures the composer weakly and leaves matched layouts alone.

Real-window validation is pending because the remote Mac's login screen is frontmost and the isolated app cannot activate. The user was asked to unlock the session or allow automated checks only. Performance benchmarks are running; no app CPU or memory result is claimed without the window check.
