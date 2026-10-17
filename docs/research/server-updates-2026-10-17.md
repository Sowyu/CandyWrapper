# Independent server updates

## Scope and source

CandyWrapper owns this update flow only for the process it starts. T3 service updates keep their existing click-to-update RPC. No release was made, and the live T3 service and home were not changed.

T3 3234 sources:

- `apps/desktop/src/updates/updateChannels.ts:3-18`: default channel from version.
- `apps/desktop/src/updates/DesktopUpdates.ts:52-53,1053-1054`: launch delay, check cadence, no automatic download or install.
- `apps/web/src/components/desktopUpdate.logic.ts:28-105`: action selection, progress, tooltip and confirmation copy.
- `apps/web/src/components/sidebar/SidebarUpdatePill.tsx`: sidebar presentation reused by the runtime controller.
- `apps/web/src/session-logic.ts:552-557`: generic timeline label and raw item data.

The activation-only cadence is an intentional difference documented in `docs/decisions.md`. `RuntimeUpdatePolicy` selects GitHub releases independently of the client pin. `scripts/check-runtime-updates` runs the decision, staging, backup and rollback checks.

## Recovery and compatibility

A verified download does not activate itself, including after app relaunch. Restart arms the database recovery marker before trying the new executable. The descriptor must report the requested version and a supported orchestration protocol, and an authenticated `server.getConfig` RPC must succeed before the backup goes away. Failure restores the main database and sidecars, removes sidecars absent from the backup, selects the previous runtime and reconnects. An empty home restores its original absence. Pending recovery also handles a crash before the trial answers. A surviving owned process is adopted and verified; another app's process is left alone.

`RuntimeChoice.swift`, including `HomeRecords`, is unchanged. Trial starts defer recording the home's highest version until successful RPC verification, preserving rollback without weakening the downgrade guard.

`21-future-server.jsonl` derives from the real 3234 recording `20-nightly-3234.jsonl`. It adds fields throughout, unfamiliar provider/auth/runtime/interaction/run status values, an unfamiliar timeline type in the snapshot and a subsequent item event, an unknown domain event, an unknown stream kind, an unknown push and a server-sent unknown RPC request. Tests preserve the original thread and rows, advance cursors, keep valid unfamiliar timeline items with the generic label, and exercise a typed unknown-method failure followed by a successful RPC on the same connection. Malformed unfamiliar timeline items remain skippable.

## Validation

- Sandbox update: started an isolated owned 3105 server with `CANDY_RUNTIMES`. The launch check found newly published 3238 without changing the 3234 client pin. Download showed progress and kept the 3105 PID and active version. A separate Install confirmation showed “Restarting…” and started 3238. The authenticated RPC succeeded, recovery files were removed, and the home floor advanced to 3238. A tiny Haiku turn completed.
- Sandbox rollback: a separate runtime store staged an intentionally failing executable as 3238. Restart restored the database and started 3105 again. The home's highest version remained 3105 and the pending backup cleared. The failure message wrapper was corrected to preserve the recovery explanation. The final build retained the retry action after reconnect; replacing only the fault fixture with the already verified real runtime and retrying completed the update through the version, protocol and RPC guards.
- All 1,541 tests passed (1,524 Swift Testing and 17 XCTest). After the final error-copy adjustment, the runnable update check passed all 17 targeted tests. A fresh debug build includes the app controller and UI.
- Code review checked process ownership, crash markers, backup retention, downgrade records, staged downloads, observer lifetimes, unknown-message handling and idle scheduling. It fixed late initial connection presentation, preservation of recovery messages, and the bulk-update pill hiding the runtime action.
- On-screen checks covered light and dark appearances, a tiny Haiku turn in each, fast sidebar toggles, Settings and the command palette. The update controls showed Download, download progress, Install confirmation, Restarting and Up to Date; the failure toast stated that the database and prior runtime were restored. Screenshots remain outside the repository.
- The final update check passed all 17 tests after the trial guards were added.
- [Full performance review](../perf/2026-10-17-d7db15d-dirty-w1.md), against the last saved run: 194 ms median window launch, 0.045% idle CPU, 34.6 MB idle footprint and 378.5 ms scroll CPU. No scrolling sample stalled for 50 ms; one thread-open sample stalled for 51.6 ms. One streaming-memory sample flagged 40.4 MB versus 35.5 MB, but three isolated repeats measured 34.6–34.7 MB. The original flag and the repeats are retained; no threshold regression remained reproducible.

## Remaining limits

The existing crash-recovery limitation around another app writing after a finished restore but before marker removal remains documented in `ServerController.finishPendingRestore`. Recovery checks current ownership; it cannot prove no other process wrote between app launches. The separate 3234 parity tasks remain in `PROGRESS.md` and the Nightly audit.
