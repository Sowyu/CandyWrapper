# Footer server update follow-up

## Why the banner had no arrow

The 47391 sandbox runs T3 `0.1.1-nightly.20261017.3234`, behind the client's pinned `0.1.3-nightly.20261025.3669`. Its descriptor has no `selfUpdate` capability or installation hint. The banner therefore offers **Copy relaunch command**. T3 makes the same distinction in `apps/web/src/components/ServerUpdateAction.tsx:282-293`.

The footer counted only the automatic update plan. `UpdateEverythingLogic.serverTargets` skips a server without `selfUpdate` as **needs a manual update**, following T3 `apps/web/src/components/sidebar/updateEverything.logic.ts:66-100`. The eligible-server count was zero, so the button received no server offer. Separately, published 1.14.7 also placed Redesign's account surface above its update control; commit `65227f31` already fixes that view order.

The footer now derives version availability from the same machine snapshot as the automatic plan, before permission and update-path eligibility filter the plan. A connected, outdated manual server lights the circled arrow. Clicking it opens **Settings > Machines and connections**, whose Version row offers **Copy relaunch command**. The same guidance remains available when an automatic pass is held. Manual or permission-blocked servers do not increase **Update all (N)**. Provider-only offers stay in that menu, and app downloads retain their own action.

Two tests cover the missing-capability descriptor, the banner's manual action, the footer arrow and tooltip, guidance dispatch, app-action priority, automatic and held passes, provider-only fallback, permission limits, a current version, missing versions, disconnect and the owned-runtime exclusion. The fast lane passes 2,072 Swift Testing tests and 18 XCTest tests; all 29 focused update, sidebar and fidelity checks pass. No new timer or idle work.

## The sidebar overlap is a snapshot artifact

Paired captures from the same launches on sandbox 47391 distinguish a real window from the direct layer renderer. WindowServer captures of the owned test window, obtained with `screencapture -l <window-id>`, show **Threads**, then **Pinned 1**, then **Greeting**, without overlap. Dark and light Redesign both lay out correctly. Default light and dark also show the server arrow.

The same launches' `--snapshot` PNGs show **Pinned 1** above **Threads** and the first thread over the section label. `AppDelegate.scheduleSelfSnapshot` calls `layer.render(in:)` directly (`App/Sources/AppDelegate.swift:785`); that rendering path omits the scrolling viewport clipping AppKit applies to the live window. The displaced text is document content outside the viewport, not a misplaced navigation row. No sidebar layout change is needed. The snapshot artifact remains.

Captures live in `~/CandyWrapper-research/sandbox/footer-server-followup/`: `redesign-{dark,light}-{window,layer}.png`, `default-{dark,light}-{window,layer}.png` and `guidance-action-window.png`. The guidance capture dispatches the real footer action and shows the sandbox server's Version row with **Copy relaunch command**. Its temporary action trigger was removed before the final build. No release or server update was performed.
