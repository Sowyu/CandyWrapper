# Settings sweep, 2026-10-11

This worktree contains a partial implementation sweep, not completion of every Settings row. The checklist distinguishes shipped changes from remaining implementation work and desktop/account limits. No commit was made.

## Sources and changes

All official paths below are relative to `/Users/mrm/CandyWrapper-research/t3code`. Read-only source research informed the implementation. Existing broader audits are `WP7.13b-settings-runtime.md`, `WP7.14b-providers-environments.md` and `WP7.16-onboarding-snapshots-desktop.md`.

| Area | Official evidence | Native change |
|---|---|---|
| Project image and actions | `apps/web/src/components/settings/ProjectSettingsPanel.tsx:196-204,575-590`; `ProjectActionsSettings.tsx:91-129,213-220`; `apps/web/src/components/settings/useProjectScriptSettings.ts:135-170`; `packages/contracts/src/t3ProjectFile.ts:13-141` | Image-only local Finder chooser beside existing project search/generated icon dialog. Invalid-file notice. Distinguish absent scripts from invalid files. Match removal of an unchanged shortcut. |
| Workspace inheritance | `packages/shared/src/projectSettings.ts:95-141`; `packages/contracts/src/t3ProjectFile.ts:13-141` | One cancellable read for an unresolved new draft. Project/environment/legacy values precede valid t3.json, then local. Sending waits for the read; late responses cannot replace an explicit pick or another draft. |
| Diff/context | `apps/web/src/index.css:2086-2099`; `apps/web/src/components/BranchToolbar.logic.ts:67-82` | Exact blue/orange Tailwind OKLCH tokens in light/dark. Default palette unchanged. Active-thread context strip honors persist preference. Chat width was already wired. |
| Published themes | `apps/web/src/hooks/useEnvironmentTheme.ts:21-94`; `apps/web/src/themePalette.ts:250-265`; `packages/contracts/src/server.ts:817-828` | Opt into config stream events, parse seeds and overrides, keep opposite variant based on its own defaults, reject reserved IDs, show Use/half/Duplicate gallery actions. Clear on primary disconnection. |
| Motion/fonts | `apps/web/src/components/settings/PanelAnimationsPreview.tsx:8-82`; `SettingsPanels.tsx:1460`; `SettingsFontPreviews.tsx:25-77` | Click-driven miniature preview, transition-only layer animation and Reduce Motion. Simple font mode combines code and terminal previews. No default metrics changed. |
| Native licenses | `packages/shared/src/thirdPartyLicenses.ts:1-112`; `apps/web/src/components/settings/OpenSourceLicenses.tsx`; local `docs/design.md:117` and `scripts/gen-candy-art.swift` | Bundled native notices merge with server notices and remain available offline. Generator records T3 Code, SwiftTerm, Lucide, Mermaid and authorized Candy Town art sources. |
| Provider config | `packages/contracts/src/settings.ts:716-855`; `apps/web/src/components/settings/ProviderSettingsForm.tsx:80-108,148-225,535-560` | Antigravity modes/key/GCP fields. ACP registry/local source, executable, auth method and literal argument editor in Settings and wizard. Secret fields use secure inputs. Preserve schema-significant empty strings. |
| Model preferences | `apps/web/src/modelSelection.ts:124-143`; `apps/web/src/modelOrdering.ts:35-58` | Picker filters hidden built-ins and applies explicit ordering without hiding custom entries. Existing custom editor retained. |
| Browser viewport | `apps/web/src/components/settings/IntegrationsSettings.tsx:248-395`; `packages/shared/src/previewViewport.ts`; `packages/contracts/src/preview.ts:28-42` | All 17 device presets, explicit dimensions, official bounds/area validation, rotation to freeform and reset. |
| SnapShot shortcut | `apps/web/src/lib/snapShotShortcut.ts:110-121`; `apps/web/src/components/settings/SnapShotSettings.tsx`; `SnapShotSetupDialog.tsx:223-410` | Shared recorder/reset in Settings and setup, both-sided modifier pairs, local keymap conflict feedback. Existing sole app monitor yields to the recorder. |
| Confirmations | Existing native `App/Sources/SidebarCommands.swift:514-523,666`; official `apps/web/src/components/settings/SettingsPanels.tsx` | Corrected stale checklist: Delete action and conditional confirmation were already built. |

## Remaining work

These are unfinished implementation tasks, not claims that unavailable credentials prevent coding them:

- Proactive branch diff/multi-PR/plan suppression; workspace-default tier in Settings scope display.
- Imported theme collections/radial variants, OpenVSX/VS Code import, semantic usage spotlight; dev artwork; exact panel layout interpolation and closing; full rem geometry and smoothing.
- SnapShot permission-row fidelity, OS global shortcut conflict detection and same-process AX capture.
- Wizard registry tile/icon and auth finish states; automatic native callback completion; provider accent badges; ChatGPT picker/sharing/usage/setup; ACP route/logout; update notification coordination/actions.
- Inline device/profile rows, browser device toolbar/viewport runtime and recording preference consumption.
- GitHub sharing/routing, environment SSH ownership, route reorder and complete permissions UI; full telemetry groups/power/health/tree/tooltips.

Separate limits: local updater is M9; network/Tailscale restart and Connect ownership require the desktop bridge rather than a documented server RPC. Legacy sidebar remains skipped for the user's decision. Real credentials/accounts must not be used. Existing authorized-client, outside-agent, Bitbucket, browser-link and trace rows remain implemented.

## Runtime cost and scope

No polling or additional event monitor was added. Theme changes reuse the existing config subscription; animations allocate only on transitions and honor Reduce Motion. Project file reads are bounded and cancellable. Native notices are bundled. All edits stay in the assigned worktree. No other agent, live T3 install, live daemon, account or T3 MCP tool was used.

## Validation

Final test/build counts and screen evidence are recorded in `settings-sweep/validation.txt`. New fidelity states cover both diff palettes, invalid project file and motion preview in both appearances: eight cases, mean differing pixels 1.82%, maximum 4.77%; the four diff swatches match exactly. Full existing fidelity coverage is also rerun, rather than treating these small states as whole-page proof.

The isolated app uses bundle ID `dev.candywrapper.test.sweepsettings`, URL scheme `candywrapper-sweepsettings` and `/tmp/cw-dd-astrasweepsettings`. It connects only to the existing sandbox at port 47391. Screen checks select iPhone SE (375 × 667), rotate to Responsive (667 × 375), reset, and inspect Settings. No server settings, sandbox project files, provider updates, account sign-ins, agent turns or permission dialogs were created. Test screenshots are restricted to the test app window. The launch emitted the existing sandbox-extension warning.
