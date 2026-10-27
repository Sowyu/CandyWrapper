# Responsiveness and code audit, 2026-10-26

The audit retains **30 supported code findings: 7 P1, 20 P2 and 3 P3**. Twelve reproduce in component tests or isolated harnesses using production methods; eighteen have reviewed source traces and still need runtime reproduction. No product code, visual design or wire behavior changed. No release was made.

The largest measured loading bottleneck is cold Markdown work on the main thread. A 256 KiB mixed response took about **984 ms** to parse and lay out; a 1 MiB response took **4.11 s**. These are the sums of component medians, not measured click-to-paint times. Ordinary thread data delivery and image request sharing performed much better in the tested sandbox.

Product baseline: `0ced803c3ec141b3a58ab31e5bc401d6f61a06e3`, following the initial fetch of `origin/main`. All audit commits through the measurements change only tests, harnesses, notes and progress. The app uses the pinned T3 contract `v0.1.2-nightly.20261021.3473`. The shared sandbox integration server is 3234; the frozen-workload app review starts its own 3473 server.

## Fix first

| Finding | Consequence | Evidence |
| --- | --- | --- |
| [F1](files-actions.md), fixed | Comment on PR A can close or reopen PR B after navigation. | Production-method harness reproduced both targets. |
| [F2](files-actions.md), fixed | A late comment success clears PR B's unsent text. | Production-method harness reproduced text loss. |
| [C1](composer.md), fixed | Failed-send recovery restores A's prompt into B, or fails to recover A while B has text. | Extracted recovery body reproduced both cases. |
| [C3](composer.md), fixed | Upload retry sends the saved prompt and clears newer typing. | Extracted resume body reproduced lost typing. |
| [SA1](session-actions.md), fixed | A browser download's 403/404 error body replaces an existing destination file. | Production save method and real temporary files reproduced replacement; HTTP 200 control passed. |
| [SU1](settings-updates.md), fixed | Overlapping project-setting writes replace whole entries and erase earlier changes. | Source trace, including the server's replacement contract. |
| [TR-1](transport.md), fixed | A changed relay endpoint leaves history/assets using the obsolete origin while its socket connects elsewhere. | Source trace. Requires endpoint rotation and an unavailable old origin. |

Keep operation targets, drafts, file identities and revisions fixed across each await.

C1, C3, F1, F2 and SA1 were fixed on 2026-10-27; see [Fixed since the audit](#fixed-since-the-audit). The other findings are still open. These findings support focused repairs; they do not establish a need to rewrite the client. Product fixes are outside this audit commit.

## Loading measurements

### Cold Markdown

Release build, 21 fresh parser/layout samples per fixture at width 680. The mixed fixture contains headings, lists, code and tables; the soft-break fixture is one long paragraph. The reported p99 is the largest of 21 samples and is only a screening estimate. Raw samples are in [latencies.json](latencies.json).

| Fixture | Parse p50 | Layout p50 | Layout p95 |
| --- | ---: | ---: | ---: |
| Mixed, 64 KiB | 49.9 ms | 189.7 ms | 194.8 ms |
| Mixed, 256 KiB | 211.7 ms | 772.7 ms | 786.0 ms |
| Mixed, 1 MiB | 884.0 ms | 3,228.7 ms | 3,280.9 ms |
| Soft breaks, 64 KiB | 62.5 ms | 34.6 ms | 35.3 ms |
| Soft breaks, 256 KiB | 268.5 ms | 152.8 ms | 155.0 ms |
| Soft breaks, 1 MiB | 1,150.9 ms | 635.3 ms | 655.7 ms |

`MarkdownView.swift:153` constructs the document synchronously; `:258-274` constructs and caches the full `MarkdownLayout` on its view actor. Moving timeline row derivation off-main above 1,500 rows does not remove a single large visible message's parse/layout cost. This quantifies the existing long-Markdown follow-up, rather than claiming a new regression. A future repair should measure visible content readiness and input responsiveness while preserving the full reply.

### Images and real sandbox traffic

The repeated-image test mounted 20 views of a 2400 by 1600 PNG, seven rounds per configuration. Shared decoding took **29.9 ms median**, range 26.8–30.5 ms, with one decode. Independent decoding took **437.7 ms median**, range 404.9–587.9 ms, with twenty decodes. This validates the existing sharing path for repeated identical images; it is not a network-download or twenty-distinct-images result.

The production client completed 400 `server.getConfig` calls in batches of twenty, 100 subscriptions to existing sandbox threads with decoded snapshots and synchronization markers, and twenty explicit Retry/reconnect cycles. The successful final run used Debug package products.

| Operation | Samples | p50 | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| RPC at concurrency 20 | 400 | 187.3 ms | 299.3 ms | 334.5 ms | 357.6 ms |
| Thread subscribe, decode and marker | 100 | 4.6 ms | 14.7 ms | 18.5 ms | 47.6 ms |
| Retry through reconnect and probe | 20 | 15.7 ms | 15.8 ms | 22.0 ms | 22.0 ms |

These measure data readiness, not app first paint. The first Release run completed the 400-call burst at 148.6 ms p50 / 264.8 ms p99, then its reconnect assertion incorrectly imposed a 15-second deadline on repeated automatic drops. The production ladder intentionally grows to five minutes until a connection stays healthy for thirty seconds (`ConnectionSupervisor.swift:5-17`). The final harness uses the user's explicit Retry action. No product backoff changed, and the initial harness failure is not counted as a bug.

### Whole-app first frames

Release app, three runs per scenario against the frozen workload, compared with the latest saved run `14567ec`. No loading or thread-open stall regression was flagged. No main-thread stall over 50 ms occurred during the open scenarios. [Full standard report](perf/app/2026-10-26-9810696-dirty-w1.md) and [binary provenance](app-provenance.json).

| Operation | Median | Range |
| --- | ---: | ---: |
| Window visible | 242.0 ms | 224.0–808.0 ms |
| Cached sidebar | 250.0 ms | 236.0–833.0 ms |
| Live sidebar | 299.0 ms | 288.0–938.0 ms |
| Large thread, first open | 61.6 ms | 61.3–62.4 ms |
| Large thread, reopen | 48.2 ms | 32.4–62.7 ms |
| Large thread, disk cache | 64.1 ms | 48.9–65.4 ms |

Only loading and stall metrics inform this audit. The standard harness also records resource metrics; its shortened one-second idle sample is not a resource comparison.


### Saved microbenchmarks

All 43 Release metrics completed. The [original report](perf/2026-10-26-0ced803-w1.md) compares with `caadcab`; [the same samples compared with the latest saved run](perf/comparison-with-latest.md) use `14567ec`. The latter flags append work at 4.14 ms versus 3.26 ms and the classic sidebar label tick at 0.533 ms versus 0.410 ms. They are small absolute changes, not established user-visible stalls or attributed regressions. A [fresh-process focused recheck](perf/focused-recheck.json), without rebuilding, measured append at **2.57 ms** and the label tick at **0.308 ms**. Both initial flags disappeared. The first measurements remain in the report; no stable regression or cause is established. Huge disk-cache load/write medians were 27.6/35.4 ms; full huge-snapshot decode was 36.1 ms.

## Stress and correctness results

- Full baseline suite: **2,088 Swift Testing tests and 18 XCTest tests passed**. Serial execution avoids the separately documented shared-theme interference.
- Extended Release stress: **1,000 thread scenarios** across bounded history/reconnect/cache, out-of-order delivery, forks and provider subagents, plus **250 shell scenarios**. The thread cases checked **80,102 transitions** against fresh derivation. All four scenario families and shell checks passed. Normal transition p99 values ranged from 0.57 to 0.95 ms.
- **62 panel replays** passed, including background row derivation and coalesced updates.
- The larger 1,298-row fixture processed **600 updates** but failed its existing twelve-row bound twice: fifteen rows at step 73, thirteen at step 218. A separate Debug recheck reproduced both. Both events are new user messages; the changed tail contains the preceding run's work and the new live indicators. No O(total rows) update or incorrect content was demonstrated. The bound remains unchanged and the failure remains open as a test/patch-size investigation.
- The ordinary final fast run had one failure in the already documented `FrameDecoderTests.deliversNewestFrame`: the newest frame was correct, but more than two intermediate frames arrived. Both frame tests passed in a focused recheck. This flake was not hidden by reporting the whole fast lane as green.
- The read-only sandbox integration suite passed. The targeted real-client stress passed after correcting the harness's automatic-backoff assumption.
- Twelve code findings reproduced. Component tests cover IMG-1, IMG-3, TH-1, TH-2, TR-2 and OH-5. Isolated production-method/buffer harnesses cover F1, F2, C1, C3, SA1 and OH-1. Harness collaborators are fake; these are not twelve on-screen reproductions.
- The helper truncation reproduction preserved a one-entry snapshot at all three chunk widths, but lost the config marker for an 83,129-byte JSON / 110,840-character base64 snapshot at 256, 4,096 and 1,000,000-character chunk widths. Its success marker survived, proving the false-failure path.

The intentionally failing regressions assert the desired behavior. The PR harness instead exits zero when its two existing bugs reproduce; the other forensic harnesses exit nonzero on the observed defect. Their exit codes must not be combined as an ordinary green/red suite. [execution.json](execution.json) retains commands, flags, durations and exits; [the evidence index](findings.json) distinguishes executed from source-traced findings.

## All retained findings

“Executed” means a component test or isolated production-method harness, as described above. “Source” means reachable source evidence that has not been reproduced at runtime. Area reports carry exact file/line citations and trigger conditions. IDs TH/TR distinguish the two area reports' local T1/T2 names.

| ID | Priority | Evidence | Finding |
| --- | --- | --- | --- |
| [C1](composer.md) | P1 | Executed | Fixed 2026-10-27. Failed send recovery restores text into another thread |
| [C3](composer.md) | P1 | Executed | Fixed 2026-10-27. Upload retry sends old text and clears newer typing |
| [F1](files-actions.md) | P1 | Executed | Fixed 2026-10-27. Comment-and-close/reopen can act on a different pull request |
| [F2](files-actions.md) | P1 | Executed | Fixed 2026-10-27. A late comment success erases another pull request draft |
| [SA1](session-actions.md) | P1 | Executed | Fixed 2026-10-27. Browser download error bodies replace existing destination files |
| [SU1](settings-updates.md) | P1 | Source | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). Overlapping project-setting writes erase earlier changes |
| [TR-1](transport.md) | P1 | Source | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). Changed relay endpoint leaves HTTP history and assets on an obsolete origin |
| [C2](composer.md) | P2 | Source | Changing machine keeps attachment upload IDs from the previous machine |
| [C4](composer.md) | P2 | Source | Delayed thread launch success steals current navigation |
| [C5](composer.md) | P2 | Source | Restored upload verification never resumes its pending send |
| [F3](files-actions.md) | P2 | Source | Viewed-file replies overwrite another pull request marks |
| [F4](files-actions.md) | P2 | Source | Overlapping directory refreshes restore an older listing |
| [IMG-1](images.md) | P2 | Executed | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). Cancelled image/PDF load replaces the newly opened file with an error |
| [IMG-4](images.md) | P2 | Source | Orchestrator sends before selected images finish preparation |
| [OH-1](orchestrator-helper.md) | P2 | Executed | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). Large helper config output loses its marker and reports a false timeout |
| [OH-2](orchestrator-helper.md) | P2 | Source | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). An unanswered helper RPC blocks queued connector actions |
| [OH-3](orchestrator-helper.md) | P2 | Source | Relay calls can continue after Orchestrator is disabled |
| [OH-4](orchestrator-helper.md) | P2 | Source | Failed Orchestrator settings writes lose their retry state |
| [SA2](session-actions.md) | P2 | Source | Browser download Save resolves the current browser instead of its origin |
| [SA3](session-actions.md) | P2 | Source | Delayed script previews open in the newly selected thread or environment |
| [SA4](session-actions.md) | P2 | Source | Browser discovery stays subscribed to a replaced session |
| [SU2](settings-updates.md) | P2 | Source | Failed project script reads suppress same-workspace retries |
| [SU3](settings-updates.md) | P2 | Source | Add-to-machine silently abandons navigation after three seconds |
| [SU4](settings-updates.md) | P2 | Source | Connections access retains a replaced primary session subscription |
| [TH-1](threads.md) | P2 | Executed | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). One failed history request prevents further automatic paging |
| [TH-2](threads.md) | P2 | Executed | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). Old thread rows become interactive while replacement rows are pending |
| [TR-2](transport.md) | P2 | Executed | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). Early Pong removes recovery while initial configuration is still missing |
| [IMG-3](images.md) | P3 | Executed | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). Malformed image bytes leave the file preview blank |
| [IMG-5](images.md) | P3 | Source | Media Save silently drops signing and HTTP failures |
| [OH-5](orchestrator-helper.md) | P3 | Executed | Fixed 2026-10-27 ([repairs](#loading-image-and-connection-repairs-2026-10-27)). An earlier read clears the busy state of a queued connector mutation |

## Loading, image and connection repairs, 2026-10-27

Each regression test below runs in the ordinary suite now; the opt-in gates on these cases are gone.

- TH-1 fixed. A history request that ends without a page, failed or cancelled, rearms paging, so the next upward scroll retries the same cursor (`TimelineView.historyLoading` and `historyFailed`). Test: `ThreadResponsivenessAuditRegressions.failedHistoryDemandCanRetryTheSameCursor`, with a cancelled case added.
- TH-2 fixed. The timeline stays inert until the new thread's rows apply, including the background derivation (`ThreadViewModel.threadRowsPending`), and a UI-state refresh during that time can't end it early. Test: `oldRowsStayInertUntilNewRowsAreApplied`.
- IMG-1 fixed. An image or PDF load applies only when it wasn't cancelled and its view is still the shown body. Test: `ImageLoadingAuditTests.cancelledImageCannotReplaceTheNextFileWithItsError`.
- IMG-3 fixed. Bytes `NSImage` can't decode show "Unable to load workspace image." Test: `successfulHTTPWithMalformedImageReportsFailure`.
- TR-2 fixed. `subscribeServerConfig` subscribes with `snapshotFirst`, so a Pong no longer answers it and the watchdog keeps running until the snapshot arrives. Tests: `TransportResponsivenessAuditTests.pongBeforeInitialConfigMustNotRemoveLoadingRecovery` and `RPCConnectionTests.aPongDoesNotAnswerAStreamThatOwesItsSnapshot`. A server that keeps answering Pings while its config handler hangs still has no deadline.
- OH-1 fixed. `HelperInstall.MarkerReader` scans each finished output line once and keeps only the unfinished one, so a config line of any length keeps its marker. Helper input goes in 256-character writes, under T3's 65,536-character limit. Test: `HelperInstallTests.aLongConfigLineSurvivesEveryChunkSize` at 256, 4,096 and 1,000,000-character chunks with a 110,840-character line. `reproduce-hidden-terminal.py` extracts the old `OutputBox` and no longer applies.
- OH-2 fixed. Every hidden-terminal write gives up after 15 s and Interrupts the call (`ConnectionSupervisor.request(_:payload:timeout:)`), so a queued Connectors action runs after a stuck one. The Orchestrator settings sync and Settings saves use 30 s timeouts for the same reason. No fault-injection test drives the App target; the timeout helper is the existing `withTimeout`.
- OH-5 fixed. `ConnectorsStore` counts pending changes per machine, and only a change's own answer clears busy. Test: `OrchestratorHelperAuditTests.earlierReadCompletionDoesNotClearQueuedMutationBusyState`.
- SU1 reproduced in a component test and fixed. `SettingsWriteQueueTests.plansFromOneSnapshotEraseEachOther` plans two edits from one snapshot against a fake server with T3's whole-entry replacement, and the first edit is lost. Settings saves now go through `SettingsWriteQueue`: one at a time, each planned in the scope selected at the edit from the settings the earlier saves returned, with a 30 s timeout per save. A save error that lands after Settings closed shows over the thread. Test: `queuedEditsPlanFromTheLastReplyAndBothSurvive`. Not reproduced against the sandbox server, which answers too fast locally to hit the window without a delaying proxy.
- TR-1 reproduced in a component test and fixed. `EnvironmentHTTP` had an immutable base, so a relay session's history and asset calls went to the saved tunnel. A relay session now asks `T3ConnectAuthorizer.httpBaseURL` before each authenticated call, and `baseURL`, shared by every copy, follows it for asset links. Tests: `EnvironmentHTTPRelayOriginTests`. Each new session also moves `baseURL` before it resumes, and a 401 retry is rebuilt and signed on the renewed token's tunnel (`EnvironmentHTTPRelayRetryTests`). Sign-out cleanup tells relay sessions by kind, since their origin moves. Not reproduced end to end: that needs a real T3 Connect relay, and tests never sign in.

## Fixed since the audit

On 2026-10-27, commit "fix: late replies keep their own draft, thread and pull request; failed downloads leave files alone" fixed these:

- C1. `sendFailed` restores the text under the key it was sent from, and only if that draft is empty. The editor changes only while it still shows that key. A failed first send whose project key now holds a newer draft comes back under its own draft id.
- C3. `resumeSendAfterRetry` sends only if the editor still holds the text that was sent. Otherwise the newer text stays and a toast says the message wasn't sent.
- F1 and F2. Comment, review, comment-and-close, actions, edits and stack actions keep their pull request and environment. The close or reopen goes to the pull request that got the comment. A reply only touches the composer that sent it, and it reloads, clears pending state or closes an editor only during the same showing of its pull request. Leaving and coming back counts as a new showing, so an old title save can't close a newer title edit. Switching pull requests clears the old pending and saving flags.
- SA1. `DownloadedFile.save` refuses a non-2xx reply or a body that doesn't match the announced `sizeBytes`. It stages the file on the destination's volume and swaps it in with `replaceItemAt`, so the original survives any failure.

The three harnesses now assert the fixed behavior and exit 1 if a bug comes back. Run against the code before the fix, they fail every bug case: 7 composer, 2 download and 9 pull request. Their controls pass both before and after.

```sh
CW_COMPOSER_AUDIT_REPRO=1 /usr/bin/python3 scripts/audit-composer-recovery
CW_SESSION_ACTIONS_AUDIT_REPRO=1 /usr/bin/python3 scripts/audit-session-actions
python3 docs/research/responsiveness-audit-2026-10-26/files-actions-harness.py --run
scripts/test --filter DownloadedFileTests
```

## Review and coverage limits

Eight focused area reviews and one independent adjudication covered app controllers, transport/Connect, shell/thread stores and caches, protocol restoration, image/media loading, composer/drafts/uploads, files/Git/PR actions, Orchestrator/helper/connectors, terminal/browser/device/session ownership, settings and updates. The inventory contains 52 app Swift files (27,728 lines) and 619 package source Swift files (167,227 lines). This is an area-wide audit with targeted deep traces, not a claim that every source line or possible interleaving was proved correct. Visual fidelity, CPU, memory and battery optimization were outside the requested focus. Vendor internals were not exhaustively audited.

Independent [adjudication](adjudication.md) rejected IMG-2 because successful attachment preparation persists an owned copy before Send; downgraded IMG-3, IMG-5 and OH-5 to P3; and raised C3 to P1 for lost user text. The old October 18 file-identity/writer, scheduled/device subscription and asset-limit findings are addressed in current source and are not recounted. Settings SU1–SU4 were reviewed separately after that adjudication snapshot.

No real-account sign-in, live T3 mutation, provider turn, actual PR comment/close, real config write or runtime installation was used. Relay endpoint rotation, two-machine attachment migration, settings-write races and the remaining source-only findings still need controlled runtime reproductions. Existing package tests do not compile App controllers; the extracted-method harnesses bridge selected gaps without replacing a full app integration test target.

## Reproduce

Run `scripts/preflight` before building. Use the fixed sandbox, fake Connect for app runs, an isolated test bundle and the screen lock. Run one build/measurement lane at a time. Long tests need the repository's thirty-minute process limit. Commands and environment flags are in [execution.json](execution.json); the area reports link their opt-in forensic commands. Re-run intentional failures explicitly rather than adding them to the default passing lane.

Audit harnesses are [audit-composer-recovery](../../../scripts/audit-composer-recovery), [audit-session-actions](../../../scripts/audit-session-actions), [files-actions-harness.py](files-actions-harness.py), and [reproduce-hidden-terminal.py](reproduce-hidden-terminal.py). New package cases are gated by `CW_THREAD_AUDIT_REGRESSIONS`, `CW_IMAGE_AUDIT_REGRESSIONS`, `CANDY_TRANSPORT_AUDIT_FAILURES`, `CW_ORCHESTRATOR_AUDIT_REGRESSIONS`, `CW_SANDBOX_AUDIT` and `CW_THREAD_AUDIT_STRESS`. The ordinary transport cancellation/reversed-response case stays enabled.

## On-screen action checks and cleanup

An isolated Release app in Redesign ran against the shared sandbox on the 1920×1080, 1× virtual screen. Forty alternating sidebar clicks between Greeting and Run Foreground Sleep Command produced forty first-frame records: **31.4 ms p50, 40.0 ms p95, 43.3 ms maximum**. The final selected thread and content agreed. These are small retained threads, not forty cold large-thread opens. Twenty alternating General/Appearance page clicks completed with the requested page shown; this was an interaction check, not an instrumented page-load percentile.

A generated 4000×2600 PNG (155,366 bytes) was selected into the draft through the native picker. Its thumbnail request reached pixels in **15.8 ms**. Expanding it upgraded to 1024 px in **23.9 ms**, and click zoom upgraded to 1920 px in **24.3 ms**. Panning and ten reopen/dismiss cycles added no decodes beyond the initial thumbnail, fit and zoom decodes. These are local prepared-image request-to-pixel timings, not first-byte network download timings. The image was removed from the draft and no message was sent. [Raw action timings](ui-observations.json).

Screenshots and the app log remain outside Git at `~/CandyWrapper-research/notes/responsiveness-audit-2026-10-26/`. They show sandbox data. The owned app, copied bundle, derived data, completed review worktrees, generated source image and owned intermediate build outputs were removed; the app removed its draft copy. The performance server stopped and the screen lock was released. The cleanup preflight passed with 40 GB free; the later publication check reported 37 GB, below the 40 GB floor. No further builds ran. The user's installed app and live server were left alone.
