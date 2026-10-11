# WP7.16b: onboarding and SnapShot follow-up

2026-10-11. Uncommitted implementation in `.claude/worktrees/astra-wp716b`, based on `ecd2508`. WP7.16b remains partial. The row numbers below refer to the checklist at the start of this task.

## Official source and implemented behavior

Source paths below are relative to `/Users/mrm/CandyWrapper-research/t3code/apps/`, read without edits.

| Rows | Official evidence | Implementation |
|---|---|---|
| 552 | `web/src/components/onboarding/firstRun.logic.ts:70-190`, `FirstRunGate.tsx:73-237` | `FirstRunDecision` distinguishes cached evidence, authoritative workspace state and the untouched bootstrap project/thread. Startup waits for the saved environment catalog, live shells, config and lifecycle welcome. Cached populated workspaces open without prematurely completing onboarding. A four-second one-shot deadline shows Still connecting. Corrupt persisted settings show Could not read settings and can be retried without replacing the corrupt bytes. Automatic welcome cannot be dismissed before completion. |
| 553-554 | `web/src/components/onboarding/WelcomeWizard.tsx:1330-1415,1455-1554`, `onboarding/providerReadiness.logic.ts:38-74` | Welcome offers discovered Connect machines and refresh, existing sign-in/pairing controllers, and automatic return from those forms or Providers settings. Provider readiness selects the best enabled instance for each driver. |
| 161, 347, 615-616 | `web/src/lib/snapShotSource.ts:4-54`, `web/src/components/chat/SnapShotAttachmentDetails.tsx:54-171`; `packages/contracts/src/chatAttachment.ts:43-147` (repository root); `desktop/src/snapShot/snapShot.ts:299-425` | Capture records app name, window title, identifier, icon and timestamp. Optional accessibility capture checks that the focused window matches, bounds tree work, omits secure values, clips positions to the captured image and rescales after image compression. Composer and timeline share source details with icon/monogram, gradient and a bounded accessibility JSON/text popover. Attachment wire records include `source`. Durable draft records preserve file, source, environment and destination. Restart restores and reuploads captures. |
| 617 | `desktop/src/snapShot/DesktopSnapShot.ts:97-100,574-628`, `SnapShotTransition.ts:6-40,160-180` | White flash at 0.08 opacity, 180ms fade or 60ms static. Distance-based 280-680ms flight uses cubic(.2,.8,.2,1), transform/position layers and the actual destination tile rect. Reduce Motion skips flight. Existing official sounds remain. Overlay windows close after their finite animation; no polling. |
| 363, 545 | `web/src/components/ProviderUpdateLaunchNotification.logic.ts:160-325,579-602` | Primary provider version advice and update failure/unchanged/success notices reuse the toast viewport and sidebar running pill. Driver dedupe, launch dedupe and terminal success timeout are pure tested logic. ServerProvider retains version advisory evidence. |
| 635-636 | `desktop/src/window/DesktopApplicationMenu.ts:238-268`, `DesktopWindow.ts:1023-1038` | Force Reload now differs from Reload: clear URLCache and retained thread stores, bypass persisted thread cache for the active reload, reconnect sessions. Existing root zoom and fullscreen stay intact. |
| 639 | `web/src/components/chat/BranchToolbarBranchSelector.tsx:395-410`, `web/src/components/media/MediaActions.tsx:150-174` | One shared native item menu adapter now serves existing tree/sidebar menus, branch copy and attachment Save/Copy. File chips gain viewer/editor opening and anchored copy feedback. Media actions are available in draft, timeline and expanded preview. |
| 656 | `web/src/remoteOpen.ts:69-110` | Optional saved SSH alias takes precedence over the advertised remote host; old catalog records still decode. |

`ShellSession` now owns one server lifecycle subscription. First-run and legacy migration consumers observe it instead of creating overlapping lifecycle subscriptions. SnapShot's global shortcut monitor remains installed only while capture is enabled and screen capture is ready; local matching chords are consumed by the existing sole shortcut controller.

## Deliberate limits and remaining rows

- 552: the native shell remains mounted behind the input-blocking startup overlay. The hosted-only gate branch is not implemented. Unit tests cover freshness/recovery decisions; the populated sandbox exercised the automatic app path, not a genuinely empty first-run server.
- 553-555: welcome still lacks official inline computer/provider cards, install/sign-in terminal, grouped bounded project rows, complete retry/access guards and import summaries. Existing scan/import transport remains unchanged and was not invoked in this task.
- 557-558, 560-561, 662: post-sign-in publish/devices (`ConnectOnboardingDialog.tsx:35-42,242-362`), CLI/browser consent, Nightly mobile beta notice/QR links (`NightlyMobileBeta.tsx:25-28,64-140`) and dedicated permission helper/settings windows remain unbuilt. This task reuses existing sign-in, never grants real account access.
- 346-347, 615: setup still lacks exact permission rows, modifier-pair/reset recording and shortcut conflict checks. Auto-draft requires an existing project; no-project scratch creation remains.
- Accessibility: same-process AX queries synchronously called MainActor AppKit drawing from a worker and crashed the first test app. A guard now omits same-process AX trees; a main-thread native exporter is needed before claiming self-capture text support. External apps use bounded one-shot AX queries, but no external app text capture was screen-tested. Tree bounds/rescaling are unit-tested. Messaging timeout limits individual AX calls; traversal checks its deadline between nodes, so 0.75 seconds is not a hard wall-clock guarantee for a stalled app.
- 161: JSON syntax highlighting and a sent SnapShot timeline screen check remain. Composer metadata, absent-data popover and restart rendering were checked on screen. No paid turn was needed.
- 616: captures persist after attachment delivery, not between screenshot completion and delivery. Send clears the draft optimistically, so process death during send is not fully recoverable. Stash/sync/promotion metadata paths and sent local-file cleanup still need work. Restart reuploads instead of trusting stale upload IDs; an earlier pending server upload may remain until expiry. Removal deletes the local capture file and active pending upload.
- 617: no exact image-to-tile crossfade/shadow, transformed multimonitor measurement or animated fidelity capture yet.
- 363, 544-545: provider toasts lack the one-click update action and multi-environment coordination. Existing slow RPC notices still lack expanded details/config-file action. Existing anchored-copy toast remains unchanged.
- 635-636: force reload refreshes active thread data, but does not reset every file/media/browser cache. Embedded-browser independent zoom and developer-tools surface remain.
- 639: file-chip reveal/detected-editor submenu and original media file/URL actions remain. Save image exports decoded PNG rather than original file bytes.
- 656: alias precedence exists in the catalog and URL path, but an SSH-profile editor does not populate it yet. Remote hint and complete editor icons remain.

These are implementation gaps, not permission blockers. The checklist uses partial marks rather than presenting this as completed parity.

## Validation

- Whole `swift test` in `Packages/CandyKit`: 890 tests passed (262 T3Protocol, 96 T3Client, 125 T3Store, 325 Features, 82 DesignSystem).
- Explicit `swift test --filter Fidelity`: 103 tests passed (42 Features and 61 DesignSystem).
- New logic suite: nine tests cover gate authority/bootstrap/cache, corrupt settings, provider ranking/update notices, durable capture roundtrip/wire metadata, accessibility coordinate resizing and flight duration.
- New light/dark recovery and source-details browser references: connection 1.08%/1.05%, settings 1.18%/1.16%, details 1.93%/1.93%; mean 1.39%, worst 1.93%. Mean assertion is below 3%. This measures these six static states, not whole wizard or animation parity.
- App build passed with `/tmp/cw-dd-astra716b`, bundle `dev.candywrapper.test.astra716b`, URL scheme `candywrapper-astra716b`.
- `git diff --check` passed. Existing FileLinks concurrency warnings remain unrelated.

## Screen checks and side effects

Used the existing sandbox server on 47391 with `--fake-t3-connect`; did not start or stop its existing PID 32675. No T3 MCP tools, new agents, real sign-in, agent turns, imports, project writes or server settings changes.

Own test processes were 22420 (crashed), 25955 and 31365. The latter two were stopped by their exact PIDs. The first crash produced a macOS crash-report notice; its Ignore button was dismissed after verifying it referred to this test PID. No macOS permission dialog appeared or was handled. A same-process AX guard fixed the crash and subsequent capture succeeded.

Checked welcome, sign-in form, Escape return to welcome, manual welcome dismissal, SnapShot Access/test/Continue/Enable, Ctrl+Cmd+4 capture, provider launch toast, app icon/title source tile, absent-accessibility popover, full app restart with capture restored/reuploaded, and removal. The saved capture folder `~/Library/Application Support/dev.candywrapper.test.astra716b/SnapShots` was empty after removal. This capture implementation used that isolated durable folder, not the shared temporary attachment folder. No test capture files were left there. Pending sandbox upload records may remain from the first upload before restart and expire server-side. The isolated bundle's defaults and normal draft/cache state remain.

References and visual evidence are under `design/component-reference/onboarding-snapshot*` and `design/validation/wp716b/`. Build/test logs live beside the visual evidence. No commit or push was made.
