# Connectors removal, 2026-11-21

The user asked to delete Settings > Connectors, CandyWrapper's own page for each machine's Claude and Codex MCP servers and skills ("delete this feature for mcps and skills"). This file lists every piece of it and of the CandyWrapper Helper, and what happened to each. It follows `docs/research/orchestrator-removal-2026-11-21.md`.

These are T3's and all stay: the Connections settings (environments, T3 Connect, linked machines, authorized clients), the "Use T3 Code in another app (MCP)" dialog (`SettingsUseInAnotherApp`, `UseInAnotherAppLogic.swift`, whose Claude steps say "Connectors" because that is Claude's own menu), MCP apps, MCP tool rows and previews in a thread, `T3Store/T3McpTools.swift`, skills in the composer (the `$` menu, chips and popovers) and Settings > Providers.

## Decision on the CandyWrapper Helper

The helper goes. Since the Orchestrator's removal its `main.swift` only has `config get|set` and `version`, and Connectors was the only caller of `config`. Nothing else runs it, builds it or reads its manifest.

Two pieces of the old helper code stay, because the Orchestrator cleanup needs them for 1.14.x installs:

- `App/Sources/HiddenTerminal.swift`, which `OrchestratorCleanupRunner` uses to type the uninstall line. It loses the `input` parameter and the `CWH-READY` handshake that only `config set` used.
- In `T3Store/HelperInstall.swift`: `uninstallCommand`, the session label reader `version(fromSessionLabel:)` with `sessionLabel` for its test, and `scan`, `MarkerReader` and `Line` reduced to `ok` and `failed`. `uninstallCommand` runs the binary a 1.14.x relay install left at `$d/current/candywrapper-helper`, not anything this release ships, so it needs no build of the helper. `Release`, `configCommand`, `fetch`, `Line.ready`, `Line.config` and `Line.warning` go.

With the helper gone, the release no longer builds Linux binaries, so it no longer needs swift.org's toolchain at `~/CandyWrapper-research/tools/swift-6.4.1.xctoolchain` or its Static Linux SDK. The toolchain stays on disk.

## What the feature stored

On this Mac: nothing. `ConnectorsStore` keeps machine states in memory only ("Nothing is cached between launches", `docs/connectors.md`), and no version of the feature or of `HelperController` ever wrote a UserDefaults key (checked with `git log -G 'forKey: *"(connectors|helper)'` over every branch). There are no Connectors or helper keys for a cleanup to remove.

On each machine where someone opened Connectors (1.14.3 to 1.15.1):

- The helper's download, `~/Library/Application Support/CandyWrapper Helper/versions/<version>/` on a Mac or `${XDG_DATA_HOME:-~/.local/share}/candywrapper-helper/versions/<version>/` on Linux: one `candywrapper-helper` binary and its `VERSION` file per app version. It runs only when typed in, has no service, no tokens, no sign-in and no PATH entry.
- The user's own Claude and Codex configuration the page changed: `~/.claude.json`, `~/.claude/settings.json`, `~/.claude/skills`, `~/.codex/config.toml`, `~/.codex/skills` and the like.
- `<file>.candywrapper-backup-<time>` copies that `AgentConfigStore.backUpOnce` made next to each config file before its first change.
- Nothing on a T3 server: the hidden terminal was closed with `deleteHistory: true`.

## The one-time cleanup

There is none, on purpose. The brief allowed removing the helper's folder only on machines the old state names, and the old state names no machine, because there is no old state. Typing a removal line on every connected machine would open a hidden terminal on machines that never had the helper, which the brief rules out.

What is left on a machine is inert, and removing the page removes nothing it configured:

- The MCP servers and skills set up through Connectors stay exactly as they are. They are the user's Claude and Codex configuration, and Claude Code and Codex keep reading them.
- The `.candywrapper-backup-*` copies stay, since they sit among that configuration and are the user's to keep or delete.
- The `versions/` folder stays. Anyone who wants it gone can run `rm -rf ~/Library/Application\ Support/CandyWrapper\ Helper/versions` on a Mac, or `rm -rf ${XDG_DATA_HOME:-~/.local/share}/candywrapper-helper/versions` on Linux.

`OrchestratorCleanup` is unchanged. On the machine where a 1.14.x Orchestrator relay ran it still types `HelperInstall.uninstallCommand`, whose `uninstall` deletes the relay's whole folder, `versions/` included.

## Inventory

### Features

| Path | Change | Why |
|---|---|---|
| `Features/Connectors/ConnectorsSettingsView.swift` | Delete | The page, its picker and note rows |
| `Features/Connectors/AddConnectorDialog.swift` | Delete | The Add server dialog |
| `Features/Connectors/ConnectorsStore.swift` | Delete | `ConnectorsStore` and `ConnectorRows` |
| `Features/Settings/SettingsShellViews.swift` | Edit | Drop `SettingsSection.connectors`, its label and icon, its Redesign nav insert after Providers and its nav row |
| `Features/Settings/DitherSettingsLayout.swift` | Edit | Drop `DitherSettingsSection.connectors` from the Agents group, its label, blurb, icon, page slice and `home(of:)` |
| `Features/Settings/UseInAnotherAppLogic.swift` | Keep | T3's dialog; "Connectors" is Claude's menu name |
| `Features/Settings/SettingsSearchCatalog.generated.swift` | Keep | Generated from T3's `settingsSearch.ts`, which has no Connectors entry; regenerated with no diff |

### App target

| Path | Change | Why |
|---|---|---|
| `ConnectorsController.swift` | Delete | Runs `config get|set`, loads `helper-manifest.json` and `CANDY_HELPER_MANIFEST` |
| `AppDelegate.swift` | Edit | Drop the controller and its toast hook |
| `SettingsPages.swift` | Edit | Drop the page factory case and the Redesign section mapping |
| `HiddenTerminal.swift` | Edit | Keep for `OrchestratorCleanupRunner`; drop `input` and the `CWH-READY` answer |
| `OrchestratorCleanupRunner.swift` | Edit | Drop the `input: nil` argument |
| `PaletteCommands.swift` | Keep | Its "connector" search term opens T3's Use in another app dialog |
| `ShellSession.swift` | Keep | "connector" there is the T3 Connect relay's connect function |

### Package modules

| Path | Change | Why |
|---|---|---|
| `Sources/CandyHelper/main.swift` | Delete | The helper; `config` was its last command |
| `Sources/AgentConfig/*` (5 files) | Delete | Only Connectors and the helper imported it |
| `Sources/T3Store/HelperInstall.swift` | Edit | Keep what the Orchestrator cleanup uses, see above |
| `Sources/T3Store/OrchestratorCleanup.swift` | Keep | Uses `HelperInstall.version(fromSessionLabel:)` |
| `Package.swift` | Edit | Drop the `AgentConfig` library and target, the `candywrapper-helper` product and `CandyHelper` target, `AgentConfig` from Features' dependencies and `AgentConfigTests` |
| `project.yml`, `CandyWrapper.xcodeproj` | Edit | Drop the app's `AgentConfig` product dependency; project regenerated |
| `T3Client`, `T3Transport`, `T3Protocol` "connector" hits | Keep | Connection functions and T3 Connect, unrelated |
| `T3Store/CacheFile.swift` `Musl` import | Keep | Unrelated portability shim |

### Settings, keys, routes and the environment

- Settings nav: the Redesign nav's Connectors row (after Models and providers) goes. T3's default themes never showed it (`shownGroups` added it only when `isDither`), so their nav doesn't change.
- Search: no entry. The generated catalog follows T3's `settingsSearch.ts`.
- Keybindings, palette commands: none of its own.
- URL route: none of its own. A `/settings/connectors` path now opens General, through the `SettingsSection(rawValue:) ?? .general` fallback.
- UserDefaults: none, see above.
- `CANDY_HELPER_MANIFEST`, `CANDY_HELPER_TEST_HOME`, `CANDY_CONNECTORS_CONFIG_HOME`: delete from `scripts/run-app` and the code. `CANDY_HELPER_HOME` stays only inside `uninstallCommand(testHome:)`, which the 1.14.x binary reads.

### Scripts and release

| Path | Change | Why |
|---|---|---|
| `scripts/build-helper` | Delete | Built and signed the helper's tarballs |
| `scripts/connectors-sandbox` | Delete | Set up a test helper release and sandbox configs |
| `scripts/run-app` | Edit | Drop the three variables above |
| `scripts/release` | Edit | Drop step 3b (build the helper, write `helper-manifest.json` into the app) and the upload of `helper/*` and `SHA256SUMS` |
| `docs/release.md` | Edit | Drop the helper step, the helper uploads and the toolchain requirement |

### Tests, images and docs

| Path | Change | Why |
|---|---|---|
| `Tests/AgentConfigTests/*` (3 files) | Delete | The module goes |
| `Tests/FeaturesTests/ConnectorRowsTests.swift`, `ConnectorsStoreQueueTests.swift` | Delete | The store goes |
| `Tests/T3StoreTests/HelperInstallTests.swift` | Edit | Drop the `configCommand`, `ready`, `warning` and `config` cases; keep the uninstall line, markers and session label |
| `Tests/T3StoreTests/OrchestratorCleanupTests.swift` | Keep | Unchanged |
| `Tests/FeaturesTests/RedesignBaselineTests.swift` | Edit | Drop the page; 84 images instead of 86 |
| `design/redesign-baseline/settings-connectors.{dark,light}.png` | Delete | The page's baselines |
| `design/redesign-baseline/` images with the Redesign Settings nav | Re-record | The nav loses a row; listed in its README |
| `design/redesign-baseline/README.md` | Edit | The image count and the re-record note |
| `docs/connectors.md` | Keep as history | Removal note at the top |
| `docs/orchestrator-helper.md`, `docs/research/responsiveness-audit-2026-10-26/*` | Keep | History |
| `docs/research/bringup-2026-11-19.md` | Keep | History of that day's bring-up |
| `docs/decisions.md` | Edit | A dated line |
| `PROGRESS.md` | Edit | Entry at the top; the "first release with the Helper" item under Waiting on the user closed |
| `README.md`, `AGENTS.md`, `docs/parity-checklist.md` | No change | None mentions Connectors or the helper |
