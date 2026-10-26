# Settings and updates audit

Final execution results and evidence levels are in the [audit overview](README.md). The review-stage statements below describe what ran in that isolated review, not the later centralized tests.

Reviewed 2026-10-26 on `05b0aa91`, branch `t3/audit-settings-updates`. Audit only: no product changes, builds, tests, app launches, accounts, settings writes, runtime installs or screen access. All findings below are source-traced, not executed reproductions. The local upstream checkout matches `T3_VERSION`, `v0.1.2-nightly.20261021.3473`.

## Findings

### SU1. P1: rapid project-setting edits can silently erase each other

**Reachability and trigger:** Select a project scope in Settings. With responses delayed, change two different scoped settings before the first save updates the config. For example, change Agent browser access in Integrations, then Default automatic pull in Source Control. These are real switches at `Packages/CandyKit/Sources/Features/Settings/IntegrationsSettingsView.swift:26` and `SourceControlSettingsView.swift:149`. Switching pages keeps the selected scope.

**Trace:** `SettingsRowFactory.swift:137-140` sends each switch change immediately. `App/Sources/SettingsPages.swift:375` constructs a plan from the current scope, and `:383-389` launches independent saves and only applies their settings after the reply. There is no pending-write gate or optimistic settings update in this path. `Packages/CandyKit/Sources/Features/Settings/SettingsScope.swift:265-269` reads the existing project entry, and `:282-305` merges the user's edit into that snapshot and sends the entire entry.

Both requests therefore contain entries based on the same old config. If the original entry is empty, the first can send `{enableAgentBrowserAccess: true}` and the second `{defaultAutoPull: true}`. The server replaces the project entry with the second object, deleting the first setting. Both RPCs succeed; the user receives no failure notice. Existing unrelated override values can also be reverted when the second request carries their old values.

**Upstream contract:** In the local T3 checkout, `packages/shared/src/serverSettings.ts:259-278` explicitly implements whole-entry replacement, with a special exception for provider instances; `:543-551` applies it. `packages/shared/src/projectSettings.test.ts:269-295` explicitly tests replacement. Upstream `apps/web/src/components/settings/scopedSettings.ts:166-203` also constructs full entries, and `useScopedSettings.ts:55-83` starts persistence from a supplied plan. This finding establishes CandyWrapper's reachable race; it does not claim upstream is immune.

**Parent reproduction:** Delay settings replies/config notifications by two seconds. Perform those two edits under the same project scope, then read the sandbox server's resulting project entry. Both edits must survive, including when the original entry already contains other overrides. Repeat with a reset followed immediately by another setting edit. Repair needs serialization plus planning from the latest acknowledged or optimistic state; merely serializing already-built plans retains the loss.

### SU2. P2: a failed t3.json read permanently suppresses retry within that workspace

**Reachability and trigger:** Open a thread whose checkout has importable `t3.json` actions. Let its first `projects.readFile` throw during a reconnect, then recover the connection and refresh or switch between threads in that same checkout.

**Trace:** `App/Sources/ProjectScriptsController.swift:81-82` returns when the workspace key matches. `:91` sets `fileScripts = (key, [])` before the read; `:97` catches the failure and returns without clearing that key. `refresh()` at `:69-70` calls the loader again but hits the same guard. The five-minute reuse cache at `:85-89` cannot help because the matching-key return precedes it.

**User effect:** “From t3.json” actions disappear and cannot be imported for the rest of the same-workspace visit, despite successful reconnection. This confirms the parent's finding. The precise recovery is visiting a different valid workspace and returning, or recreating the controller/app. Switching only among threads in the same workspace, or waiting five minutes, does not recover. A failed read is absent from `recentFiles`, but the separate current-workspace sentinel still blocks it.

**Upstream check:** `apps/web/src/hooks/useT3ProjectFileScripts.ts:19-37` obtains file state through the environment file query. `apps/web/src/components/files/projectFilesQueryState.ts:68-80` keys the query by environment, cwd and path and permits a missing `t3.json`. No claim about an exact upstream retry interval is needed for this defect.

**Parent reproduction:** Inject one thrown read, recover service, call `show`/`refresh` on the same checkout and assert a second read eventually occurs. Include A-thread to B-thread in one checkout, A-checkout to another checkout and back, and a genuine missing-file result as a separate case. A failed transport read must remain distinguishable from a successful empty/missing file.

### SU3. P2: add-to-machine silently abandons navigation after three seconds

**Reachability and trigger:** Start Add to another machine successfully, but delay the new project's shell visibility for more than three seconds after the start RPC returns. A slow/reconnecting shell stream is enough; no clone failure is required.

**Trace:** `App/Sources/AddProjectToMachineController.swift:82-87` returns successfully to the dialog and starts `openWhenLoaded` in an untracked task. `:159-169` checks the sidebar snapshot every 100 ms until a three-second deadline, then simply returns. The success path at `:165` is the only place that moves the draft or opens the project. No later shell observer retries this navigation and there is no timeout notice. `:116` has already silenced ordinary clone toasts for the target.

**User effect:** The dialog closes as though the action completed, but the user stays on the source machine and their draft stays there, even after the clone becomes visible. This is a correctness failure at a fixed latency threshold, not a measured claim about typical shell speed.

**Upstream check:** `apps/web/src/components/AddProjectToMachineDialog.tsx:137-159` moves the captured route draft or opens a new thread using the target reference directly; `:184-185` invokes that operation after closing. It does not impose CandyWrapper's wait for the target to appear in the shell snapshot. Upstream's file-copy wait intentionally persists through failed/cancelled clones (`apps/web/src/lib/addProjectToMachine.ts:86-109`); that deliberate Retry behavior is not a new stuck-copy finding.

**Parent reproduction:** Delay only shell delivery for 3.5 to 5 seconds after a successful clone-start reply. Assert the draft eventually moves once the project arrives, or an actionable failure is shown. Also navigate elsewhere during the delay and check the desired navigation ownership. Do not infer successful UI navigation from the clone-start RPC alone.

### SU4. P2: Connections access stops following a replaced primary session

**Reachability and trigger:** Leave Settings open after Authorized clients loads, then replace the primary `ShellSession` while keeping the same environment id, for example during an owned runtime restart. This is different from a socket reconnect inside the same supervisor.

**Trace:** `App/Sources/SettingsHostAccess.swift:79` only reloads hosts whose cached auth session is nil. `:104-106` subscribes to the primary shell's access stream only when `accessTask == nil`. That handle is cleared only on Settings close (`:64-66`); a replaced shell has no invalidation path here. `App/Sources/Environments.swift:192-195` attaches a new primary session and `:551` sends the session-change callback. The dispatch at `App/Sources/ThreadSession.swift:925-937` refreshes the other owners but not Settings host access. `SettingsController.swift:100` observes environment changes, but its `refresh()` at `:252-260` only invokes the cached-host loader and renders.

**User effect:** Authorized clients/pairing links can retain the old list and old permissions while the replacement server is connected. Further link/session changes are not followed until Settings closes and reopens, which clears the subscription and hosts. The server still authorizes writes; this is stale management UI, not a permission bypass.

**Upstream check:** `apps/web/src/components/settings/ConnectionsSettings.tsx:358-370` derives scopes and access query from the current primary environment. CandyWrapper's own clone stream provides a concrete ownership pattern: `App/Sources/ProjectCloneController.swift:53-71` compares the shell identity, cancels/replaces the subscription, and rejects old-shell deliveries.

**Parent reproduction:** With synthetic primary sessions A and B sharing one environment id, open access on A, replace with B, then publish a different access snapshot from B. Assert the UI follows B and rejects a delayed A snapshot. Repeat replacement while Settings is hidden and reveal it. Verify permissions are reread as well as restarting the stream.

## Other reviewed paths and prior findings

Reviewed `SettingsController`, `SettingsPages`, `SettingsHostAccess`, `RuntimeUpdateController`, `ServerUpdates`, `UpdateController`, `UpdateEverything`, `OpenInController`, `UsageController`, `ProjectScriptsController`, `ProjectCloneController`, `AddProjectToMachineController`, and relevant settings, usage, update and local-server helpers/tests. Reviewed the 2026-10-18 codebase audit rather than counting its findings again.

The previous audit's positive runtime rollback observation still holds in source: `Packages/CandyKit/Sources/T3Client/LocalServer/RuntimeTrial.swift:22-45` stops ownership, backs up, arms recovery before activation, and restores database/runtime after a failed trial; `:51-67` verifies authenticated RPC. `App/Sources/ServerController.swift:400-419` reconnects after the trial and checks the expected runtime version. No new unsafe rollback defect was established. Existing `RuntimeTrialTests` in `RuntimeUpdatePolicyTests.swift:57-101` cover failed and successful trials; they were read, not rerun.

The old scheduled-task/device subscription findings are not repeated as new. SU4 concerns a separate access consumer. Project clone subscription ownership is explicitly session-aware. Sequential multi-target saves report partial success at `SettingsPages.swift:395-402`; a partially saved action/shortcut operation at `:465-481` has no rollback, but matches the documented sequence, so this report does not label partial application alone a new defect.

Open-in actions capture their RPC target before suspension (`OpenInController.swift:166-179`); no new wrong-target defect was established there. Usage caches ordinary reads by environment/window (`UsageController.swift:143-179`), so merely switching windows does not establish an old-window overwrite. Sparkle waiter/error paths were read, but no external updater execution or real install was attempted.

## Central execution and limitations

No executable harness or intentionally failing tests were added, and no test command was executed. Existing package tests cover pure plans/policies, not these App controller interleavings. In particular, `SettingsProjectTests.swift:95-105` verifies one override plan, not two overlapping writes. A green run of the following commands cannot close SU1 to SU4 without the targeted scenarios above:

```sh
scripts/test --filter SettingsProjectTests
scripts/test --filter AddProjectToMachineTests
scripts/test --filter RuntimeTrialTests
scripts/test --filter ServerUpdaterTests
scripts/test --filter UpdateEverythingLogicTests
scripts/test --filter DesktopUpdateTests
scripts/test --filter UsageLogicTests
```

Useful additional sandbox stress cases: reply-order reversal between automatic usage fetch and manual refresh (`UsageController.swift:152-179`, `:216-236`); multiple slow environments during sequential Usage refresh and scoped persistence; a failed Cursor usage opt-in (`UsageController.swift:610-620`, whose error is swallowed); Settings close/reopen while old project-file or host reads remain suspended (`SettingsPages.swift:323-335`, `SettingsHostAccess.swift:76-95`); runtime check/download completion after primary-context replacement; provider success plus server failure plus cancelled app restart in Update everything. These are coverage requests, not additional confirmed findings.

No timing numbers, on-screen outcomes, real-account recovery, installer callback ordering or full rollback fault matrix were measured. Parent owns all execution and artifact cleanup; this worktree produced only this report.
