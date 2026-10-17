# Fast mode glimmer

The user requested a 2.5 times faster glimmer only when the running model uses Fast mode. Thinking, active compaction and live tool labels use the shared ShineLabelView. Normal runs keep the 2.2 second sweep; Fast runs use 0.88 seconds.

## Source and behavior

T3 defines both sweeps as 2.2 seconds in 30 held steps in `apps/web/src/index.css:545,604`. `apps/web/src/components/chat/MessagesTimeline.tsx:3680-3696` applies the activity overlay. Fast controls use `fastMode: true` or Codex's `serviceTier: fast`, as shown in `apps/web/src/components/chat/TraitsPicker.tsx:497-521`. Faster Fast sweeps are an intentional user-requested difference from T3.

CandyWrapper reads the latest run by ordinal, not the next composer selection. Projection changes update visible labels even when the timeline rows are equal. Recycled labels receive the current speed when configured. The existing render-server loop, 30 fps cap, visibility gating and Reduce Motion handling remain in place; no timer or idle work was added.

## Validation

All 15 focused ThreadCompletionTests passed, including Fast options, normal and missing options, latest-run ordering and reset between threads. The isolated Debug app built successfully. Real-window light/dark sandbox previews and recorded frame sheets were inspected (`/tmp/cw-glimmer-fast-light.png`, `/tmp/cw-glimmer-normal-dark.png`, `/tmp/cw-glimmer-fast-final.mov`, `/tmp/cw-glimmer-normal.mov`). The full suite result is recorded below when it finishes.

Code review found no wire changes or new idle callbacks. The 30 fps cap remains; a faster sweep can use more render-server updates while active. This small animation change did not trigger a full performance review.
