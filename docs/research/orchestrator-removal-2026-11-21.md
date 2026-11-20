# Orchestrator removal, 2026-11-21

The user asked to delete CandyWrapper's own Orchestrator feature. This file lists every piece of it and what happened to each. T3's own "orchestration" (the `orchestration.*` RPC methods, thread and turn events, `OrchestrationCommands`, `docs/research/B-orchestration.md`) is how every thread works, and all of it stays.

## Decision on the CandyWrapper Helper

The helper stays. Settings > Connectors runs `candywrapper-helper config get` and `config set` through a hidden T3 terminal to read and change each machine's Claude and Codex MCP servers and skills (`App/Sources/ConnectorsController.swift`, `docs/connectors.md`). That needs the binary, `scripts/build-helper`, the release's tarballs and `SHA256SUMS`, `helper-manifest.json` in the app, `HelperInstall.configCommand`, `HelperInstall.MarkerReader` and `HiddenTerminal`.

Only the relay goes: the always-on service that `install` set up with a LaunchAgent or a systemd user unit, its pairing, its tokens, its WebSocket links and its hand-back of the "while closed" task. Removing it lets the helper drop its dependencies on T3Protocol, T3Transport, T3Store and libcurl, so it builds from AgentConfig alone.

## What the feature stored

On this Mac:

- UserDefaults `orchestrator.v1`, the `OrchestratorConfig` JSON: the switch, name, prompt, machine, home project, worker limit, ask-first window, "while closed" minutes, models, notebook, kept-out threads, look, stash and `machines`, which maps each environment id to the Orchestrator's thread id and its check task id.
- UserDefaults `orchestrator.sync.v1`, the device id and per-setting stamps for the settings task.
- The Orchestrator composer's draft, saved under the Orchestrator thread's id in the thread composer's normal draft store. It's an ordinary draft and stays.
- No files under Application Support from the app itself.

On a T3 server (only through T3's own RPCs, no server change):

- One ordinary thread per machine the Orchestrator ran on, started with `thread.create` and a "# Orchestrator brief" message.
- One "while closed" check task per Orchestrator thread: a scheduled task bound to that thread, prompt starting "Scheduled check: CandyWrapper is closed.", title "<name> check", created with command id `orchestrator-check:<thread>`. The Mac turned it on at every quit, so it can keep prompting the thread every 30 minutes after the code is gone.
- One "CandyWrapper Orchestrator settings" scheduled task with no thread, always off, holding the settings document.
- With the helper installed: the helper's files under `~/Library/Application Support/CandyWrapper Helper` (macOS) or `~/.local/share/candywrapper-helper` (Linux), its LaunchAgent `com.sowyu.candywrapper.helper` or systemd unit `candywrapper-helper.service`, its tokens in the Keychain or `~/.config/candywrapper-helper/credentials.json`, and one bot session per machine labelled "CandyWrapper Helper <version> on <machine>".
- Worker threads the Orchestrator launched. These are the user's threads and stay.

## The one-time cleanup

`App/Sources/OrchestratorCleanup.swift` runs only when `orchestrator.v1` is still in UserDefaults, so a profile that never had the feature does nothing. For each machine the old config names (each `machines` key plus the Orchestrator's machine), when that machine's shell arrives, once per launch:

1. On the Orchestrator's machine, when a helper session is listed there, it types `HelperInstall.uninstallCommand` into a hidden terminal. That runs the installed 1.14.x helper's own `uninstall`, which stops and removes its service, tokens and files, or prints "not installed".
2. It revokes every helper session on the machine (bot sessions whose label `HelperInstall.version(fromSessionLabel:)` reads), the call the Helper button's Uninstall used.
3. It reads the machine's scheduled tasks fresh and deletes, with `scheduledTasks.delete`, the "CandyWrapper Orchestrator settings" task (exact title, no thread) and every check task: one bound to a stored Orchestrator thread whose prompt starts "Scheduled check:", or any bound task whose prompt starts with the full "Scheduled check: CandyWrapper is closed." sentence.
4. It archives the stored Orchestrator thread of that machine with `thread.archive`, only when it's still live and top-level. Archiving keeps its history and can be undone in Settings > Archive. It never searches for threads and never touches any other thread.

A machine counts as done only when every step succeeded. When all are done it removes `orchestrator.v1`, `orchestrator.sync.v1` and its own progress key `orchestratorCleanup.done`. Each step reads fresh state first, so running it twice changes nothing the second time.

It deliberately leaves:

- Worker threads the Orchestrator launched, and every other thread.
- Helper sessions on machines the old config doesn't name; they can do nothing once the helper is uninstalled and expire after 30 days.
- The helper's files when its machine never answers the terminal; its sessions are revoked, so a leftover service exits with 78 and launchd or systemd stops restarting it.
- The Orchestrator composer's saved draft, an ordinary draft keyed by a now archived thread.
- Check tasks and Orchestrator threads made by another device (the Android app) on a machine this Mac never ran the Orchestrator on.

## Inventory

### Features (delete)

| Path | Why |
|---|---|
| `Features/Orchestrator/BotGeometry.swift`, `BotView.swift` | The bot drawing |
| `Features/Orchestrator/OrchestratorChat.swift`, `OrchestratorPaneView.swift` | The chat pane, Overview, Needs you, HTML cards |
| `Features/Orchestrator/OrchestratorStore.swift` | The `orchestrator.v1` and `orchestrator.sync.v1` store, `CANDY_ORCHESTRATOR` |
| `Features/Sidebar/OrchestratorSidebarRow.swift` | The pinned sidebar row |
| `Features/Settings/OrchestratorSettingsView.swift` | Settings > Orchestrator, with the Helper row |

### Features (edit)

| Path | Change |
|---|---|
| `Features/Sidebar/SidebarView.swift` | Drop the pinned row, its actions and pointer forwarding |
| `Features/Sidebar/SidebarListModel.swift` | Drop the hidden-thread filter |
| `Features/Settings/SettingsShellViews.swift` | Drop `SettingsSection.orchestrator`, its nav insert and observer |
| `Features/Settings/DitherSettingsLayout.swift` | Drop the Redesign Orchestrator section |
| `Features/Settings/ExperimentalSettingsView.swift` | Drop the Orchestrator switch |
| `Features/Keyboard/RouteHistory.swift`, `DitherTabList.swift` | Drop `Route.orchestrator`; routes and tabs aren't persisted, so nothing old decodes into it |
| `Features/Thread/HtmlRenderBenchmark.swift`, `scripts/html-benchmark/*.py` | Drop the "conductor" mode |
| `DesignSystem/Components/DitherArtView.swift` | Comment only; the `page` scrim serves every page |

### T3Store (delete or edit)

| Path | Change |
|---|---|
| `Orchestrator.swift`, `OrchestratorBlocks.swift`, `OrchestratorHandoff.swift`, `OrchestratorLimit.swift`, `OrchestratorRelay.swift`, `OrchestratorSettingsSync.swift` | Delete |
| `HelperInstall.swift` | Edit: drop `installCommand`, `pairingInput`, `Pairing` and `scopes`; keep `Release`, `configCommand`, `uninstallCommand` (for the cleanup), the session label reader, `scan` and `MarkerReader` |
| `OrchestrationCommands.swift` | Keep, T3's commands; comment edit |
| `T3McpTools.swift` (`orchestrator_capabilities`), `ThreadWebContent.swift` (`OrchestratorMcpFailure`), `SubagentStrip.swift` and `SidebarModel.swift` (T3's `Orchestrator.ts`) | Keep, T3 names |
| `T3Protocol/Domain/ScheduledTasks.swift` | Keep `updatedAt`; comment edit |

### App target

| Path | Change |
|---|---|
| `OrchestratorController.swift`, `OrchestratorRemote.swift`, `HelperController.swift` | Delete |
| `OrchestratorCleanup.swift` | New, the one-time cleanup |
| `ConnectorsController.swift` | Takes the helper manifest loader from `HelperController` |
| `AppDelegate.swift` | Drop the controller, quit hand-off, pane routing; start the cleanup |
| `SidebarCommands.swift` | Drop the Orchestrator utility page and the extra thread-menu rows ("Keep <name> out") |
| `SettingsPages.swift` | Drop the page and the settings-task filter in Scheduled tasks |
| `DitherTabsController.swift`, `ThreadSession.swift`, `ComposerController.swift` | Drop the Orchestrator's tab, open-as-pane hook and composer stash hand-over |
| `HiddenTerminal.swift` | Keep, Connectors and the cleanup use it; comment edit |
| `NewThreadDraftLaunch.swift` | Keep, cites T3's `Orchestrator.ts` |

### CandyHelper

| Path | Change |
|---|---|
| `Helper.swift`, `HelperStore.swift`, `Install.swift`, `MachineLink.swift`, `CurlSocket.swift` | Delete, the relay service |
| `main.swift` | Keep `config get|set`, `print-config` and `version` |
| `Sources/CCurl` and `Tests/CandyHelperTests` | Delete; only the relay's WebSocket used them |
| `Package.swift` | Helper depends on AgentConfig only |
| `scripts/build-helper`, `scripts/release`, `docs/release.md` | Keep; comment and wording edits |

### Scripts, env vars, keys, routes and menus

- `CANDY_ORCHESTRATOR=1` in `scripts/run-app` and `OrchestratorStore`: delete.
- `CANDY_HELPER_MANIFEST`, `CANDY_HELPER_TEST_HOME`: keep, Connectors uses them. `CANDY_HELPER_HOME` stays inside the shell line `configCommand` types.
- UserDefaults `orchestrator.v1`, `orchestrator.sync.v1`: removed by the cleanup.
- No keybinding or URL route of its own. The thread menu's "Keep <name> out" row, the Settings > Orchestrator section, the Experimental switch, the sidebar row and the tab: deleted.

### Tests

Delete: `BotGeometryTests`, `OrchestratorChatTests`, `OrchestratorHelperAuditTests`, `OrchestratorSettingsHelperTests`, `OrchestratorStoreSyncTests`, `OrchestratorThreadRowTests`, `OrchestratorWebViewportTests`, `SidebarOrchestratorPageTests`, `OrchestratorHandoffTests`, `OrchestratorLimitTests`, `OrchestratorRelayTests`, `OrchestratorSettingsSyncTests`, `OrchestratorTests`, `RedactTests`, `WebSocketAssemblerTests`.

Edit: `OrchestrationCommandsTests` (keep the T3 command test), `ThreadLinkResolutionTests` (drop the plan-block case), `HelperInstallTests` (drop install cases), `DitherArtScrimTests` (a plain view stands in for the pane), `ScrollAreaColumnTests` (comment), `SidebarMultiMachineTests` (drop the hidden-thread case), `RedesignBaselineTests` (drop the page).

### Images and docs

- `design/redesign-baseline/settings-orchestrator.{dark,light}.png`: delete. `settings-experimental` re-recorded without the switch.
- `docs/perf/html-render-2026-10-25/collage-conductor-*.png`: kept as history.
- `docs/orchestrator.md`, `docs/orchestrator-phase1.md`, `docs/orchestrator-helper.md`: kept as history with a removal note at the top.
- `docs/research/responsiveness-audit-2026-10-26/orchestrator-helper.md`: history, kept.
- `docs/decisions.md`: a dated line. `PROGRESS.md`: open Orchestrator tasks closed as removed, the Experimental line updated.

## T3 code checked and left alone

`orchestration.dispatchCommand`, `orchestration.searchThreads`, `orchestration.getThreadProjection` and the rest of `WsRpcGroup` in `packages/contracts/src/rpc.ts`; `scheduledTasks.subscribe`, `scheduledTasks.upsert`, `scheduledTasks.delete`, `scheduledTasks.setEnabled`; `subscribeAuthAccess` and client revocation; `terminal.open`. `T3Store/OrchestrationCommands.swift`, the orchestration event reducers, `docs/research/B-orchestration.md` and `docs/protocol.md` are unchanged.
