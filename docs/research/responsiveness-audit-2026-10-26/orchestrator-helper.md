# Orchestrator, helper and Connectors audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

Reviewed 2026-10-26 at `43d75a5b`. Source inspection only. No builds, tests, harness runs, app launches, server calls, real config reads or mutations, accounts, live T3 files or shared-screen operations ran here. Product code and visual design are unchanged. P2 below means a reachable correctness or completion failure, with its specific trigger stated; no application-wide latency measurement is claimed.

## Findings

### OH-1: Large successful config snapshots are discarded and reported as timeouts (P2)

Confirmed by the current data path, not executed:

1. `Packages/CandyKit/Sources/AgentConfig/AgentConfig.swift:99-129` collects every server and skill without a total snapshot limit. Skill descriptions alone can be 120 characters (`:158-171`). `ConfigWire.encode` at `:463-464` makes one base64 string.
2. `Packages/CandyKit/Sources/CandyHelper/main.swift:330-331,337-342` prints `CWH-CONFIG <base64>` followed by a success/failure marker. On set, changes are already applied before printing the snapshot.
3. `App/Sources/HiddenTerminal.swift:18-20,50-53` accumulates output in an actor that keeps only its last 65,536 Swift Characters. This is a character limit, although its comment calls it KB. Base64 is ASCII, so its bytes and characters coincide.
4. The completion loop rescans only that current tail at `:37-44`. `HelperInstall.scan` at `Packages/CandyKit/Sources/T3Store/HelperInstall.swift:102-108` requires the marker at the start of a line. Once the snapshot line exceeds the tail, its marker is gone. An earlier scan cannot save it: the loop returns only when it sees a result and does not retain previously parsed config lines.
5. `App/Sources/ConnectorsController.swift:52-59` then sees success with no decodable config and displays “didn't answer in time.” A successful set has already changed the config, but the UI says the machine failed and cannot display the new state.

Trigger: Redesign Settings > Connectors on a machine whose encoded snapshot exceeds the tail, for example hundreds of server entries or skills. The exact failure threshold is lower than 65,536 base64 characters because the trailing newline, result and shell prompt also occupy the tail. A payload already over 65,536 guarantees loss. Reload repeats the same failure; a faster server does not repair it. This is not a three-minute timeout: the result marker can make it fail immediately.

A related input ceiling is separate: `ConfigWire.encodeChanges` at `AgentConfig.swift:471-475` adds line breaks but returns one String. `HiddenTerminal.swift:42` sends that whole String in one `terminal.write`. The pinned T3 contract, checked locally at `v0.1.2-nightly.20261021.3473`, limits `data` to 65,536 characters (`packages/contracts/src/terminal.ts:64-67`). A large Add command/argument list or aggregate change can exceed that bound even though every individual line is short. This path is source-traced only; no account or config was changed.

Reproduction added: `reproduce-hidden-terminal.py` extracts the exact current `OutputBox` actor and the full production `HelperInstall` scanner, then runs generated ASCII config snapshots through them at 256, 4,096 and whole-response chunk sizes. It checks one small control and 400 server entries. It is opt-in and intentionally fails when the complete config is lost. It does not emulate PTYs or execute HiddenTerminal.run, so it establishes the buffer/scanner failure, not an end-to-end terminal capture. Unexecuted here.

### OH-2: One noncompleting RPC blocks every later connector action for that machine (P2, fault-triggered)

`App/Sources/ConnectorsController.swift:35-40` chains each task behind the previous task's value. There is no cancellation action, deadline or queue reset. `HiddenTerminal.swift:28-44` has finite sleep loops, but awaits command writes and the complete stdin write outside any overall timeout. A noncompleting `terminal.write` therefore prevents it from reaching the next loop iteration or the cleanup defer. All later reads and changes for that machine remain behind it. Other machines have independent queues.

`ConnectionSupervisor.request` at `Packages/CandyKit/Sources/T3Client/ConnectionSupervisor.swift:367-369` delegates directly to `RPCConnection.request`. That request retains its continuation until reply, cancellation or transport termination (`Packages/CandyKit/Sources/T3Transport/RPCConnection.swift:145-161`). Its watchdog checks socket silence, not request age (`:358-373`); every inbound frame resets silence (`:295-297`). A server that continues returning Pongs or shell pushes while one handler never completes keeps the queue blocked indefinitely. T3 can answer Pings independently of handler completion: local `.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:806-807`.

Reachability: open Connectors, let its hidden terminal reach a write, then fault-inject a handler that withholds that write's Exit while continuing other frames. Close/reopen Settings or submit Add. The subsequent work waits forever and there is no UI cancellation. The advertised three-minute terminal result loop is not an overall operation bound. This confirms the stall mechanism under an explicit server fault, not a claim that normal writes currently hang. No such fault injection was executed. Similar serialized settings sync at `OrchestratorController.swift:980-985` has the same head-of-line exposure.

### OH-3: Turning the Orchestrator off does not cancel a relay already running (P2)

`App/Sources/OrchestratorRemote.swift:59` creates an unowned Task. `runCalls` checks relay ownership once at `:77`, marks replies handled at `:79-81`, then awaits the relay at `:83`. `reset` at `:43-46` clears dictionaries but cannot cancel that task. `OrchestratorController.tearDown` calls reset at `App/Sources/OrchestratorController.swift:164-185`.

`Packages/CandyKit/Sources/T3Store/OrchestratorRelay.swift:161-171` executes the remaining calls in order without rechecking enablement or cancellation. Sends and launches at `:279-298,301-339` check permissions/models/limits, but not whether the feature is still active.

Concrete trigger: an enabled Orchestrator emits two calls, a read and a launch. Pause the read response after runCalls has passed mayRelay, turn the Orchestrator toggle off or switch away from Redesign, then release the read. The second call can still launch a worker after the feature disappeared. The reply closure checks active at `OrchestratorController.swift:117-119`, so its result is then dropped. This is a continued later action, not an assertion that an already accepted server launch can be revoked.

There is also an identity gap if the user switches Orchestrator home machines while the relay awaits: remote.reply dispatches to the current home/thread (`:117-119`), rather than the captured origin of runCalls. Results from the old run can reach the new Orchestrator. Source-traced; no worker was launched. Central reproduction should gate a mock relay read, disable or switch, then release it and count later write requests and reply destination.

### OH-4: A failed settings write is marked synchronized before it succeeds (P2)

`App/Sources/OrchestratorController.swift:994-997` records `syncedStamps = merge.stamps` and applies the merged local config before sending its document. `:1017` discards an upsert error, then `:1018-1019` can delete duplicate documents regardless of that error. `settingsEdited` at `:968-976` only schedules a push for local stamps that differ from syncedStamps. The failed upload therefore has no dirty state left to trigger a retry.

Trigger: edit the Orchestrator prompt/notebook/other synchronized setting, let its fresh task-list read succeed, then reject or drop the upsert once. With no further edits, other devices retain the old document. Reconnecting and receiving the unchanged document also does not force retry: `settingsListChanged` compares its prompt list with seenSettings at `:961-964`. Another edit or app relaunch can prompt fresh work. Source-traced; no real scheduled task was touched.

Central deterministic scenario: fake a successful list containing an old document, fail the first upsert, deliver the identical list again, and assert a subsequent retry occurs without another local edit. Also test two documents where one contains a newer remote stamp and ensure a failed canonical upsert cannot delete the only durable copy of that newer setting.

### OH-5: An older read clears the busy state of a queued mutation (P3)

`ConnectorsStore.apply` sets a machine busy (`Packages/CandyKit/Sources/Features/Connectors/ConnectorsStore.swift:58-63`). Every earlier completion calls `set`, which unconditionally removes busy (`:37-40`). ConnectorsController starts the queued mutation after awaiting that earlier action (`App/Sources/ConnectorsController.swift:35-40`), but run does not set busy again (`:43-51`).

Reachability: open Connectors so a read is in flight, press Add and submit a server before it finishes. The Add header action remains available while loading/busy (`Packages/CandyKit/Sources/Features/Connectors/ConnectorsSettingsView.swift:65-67,134-149`). When the read finishes, the queued mutation starts with busy already false. Existing row controls are enabled based on that false flag (`:218-244`), allowing further actions against the old snapshot while the write is pending. The UI reports no pending change during the actual mutation. A second Add can create the same sequence while an earlier mutation runs.

The per-machine task chain does serialize actual edits; this finding does not claim simultaneous writes in this controller. It concerns incorrect completion/loading state and stale interaction. Added opt-in `OrchestratorHelperAuditTests.earlierReadCompletionDoesNotClearQueuedMutationBusyState` exercises the actual store with read/change callbacks and the earlier read completion. It is intentionally failing on the baseline and unexecuted here.

## Existing findings revalidated

- IMG-4, send before Orchestrator image preparation, is already in `images.md` from parent commit `43d75a5b`; it is a duplicate, not a new finding here.
- The old 2026-10-18 audit's finding 6, scheduled task subscriptions failing to follow replaced sessions, is repaired in the current `App/Sources/ScheduledTasksStore.swift:15-16,43-46,60-67`. Ownership tracks the ShellSession, old callbacks check identity, and replacement cancels/re-subscribes. Orchestrator settings use this same store (`OrchestratorController.swift:947-955`). No new duplicate finding.
- The helper auth watcher tracks session identity at `HelperController.swift:54-66`; its callback at `:73` checks only environment identity, leaving a smaller late-old-event race across same-environment session replacement. Coverage limitation, not separately ranked without controlled event delivery.

## Coverage and centralized execution handoff

Read the current controllers, shared relay/handoff/event-batch/settings-sync paths, Connectors store and Settings actions, helper config entry point, AgentConfig snapshot/write flow, local T3 terminal contract and Ping handling. The event batch has a fixed two-minute window and deduplicates thread/kind events (`T3Store/Orchestrator.swift:581-607`); that deliberate delay is not itself a responsiveness bug. Helper install/remove operations serialize with busy guards (`HelperController.swift:116-121,156-160`) and revoke via existing sessions. No install, pairing, renewal, service or config mutation was performed.

Uncovered: real PTY fragmentation/canonical input pressure, initial snapshot versus prompt timing, T3 Connect authorization errors during helper installation, multi-client/helper takeover, and full settings-device conflict recovery. No elapsed time or UI responsiveness threshold was measured. AgentConfig retains parsed-file protections and atomic rename, but this was not a general parser or external-writer concurrency audit.

Run centrally after the parent's preflight and Origin-run checks, using the repository's background/timeout test workflow:

```sh
CW_ORCHESTRATOR_AUDIT_REGRESSIONS=1 scripts/test --filter OrchestratorHelperAuditTests
CW_ORCHESTRATOR_AUDIT_REGRESSIONS=1 python3 docs/research/responsiveness-audit-2026-10-26/reproduce-hidden-terminal.py
scripts/test --filter 'HelperInstallTests|ConnectorRowsTests|AgentConfigStoreTests|OrchestratorRelayTests|OrchestratorHandoffTests|OrchestratorSettingsSyncTests'
```

The Python harness invokes `xcrun swift` against an ephemeral extracted source file with a 90-second process deadline and deletes that directory on exit. It was not run here. The default test suite skips the deliberately failing store regression unless its environment flag is present. Both reproductions are source-reviewed only and may need compile corrections during centralized execution.

Useful additional stress: repeated open/close of Connectors during a slow first download, many Add submissions behind a failed read, hundreds of skills/servers across three output chunk sizes, a stalled terminal write with healthy Pongs, disabling between sequential remote calls, switching home between remote call and result, failed settings upsert with duplicate documents, helper disconnect midway through the one-minute fallback delay, and same-environment session replacement during auth delivery. Use only mocks or the parent's sandbox and a throwaway config home.
