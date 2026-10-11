# WP7.13b settings runtime, 2026-10-11

Work is uncommitted in `astra-wp713b`. Only this worktree was edited. This is a partial package; the checklist records each unfinished row. Theme imports and editor spotlight listed in the broader PROGRESS item are outside this brief.

## Source and implementation

Paths below are relative to the read-only official checkout `/Users/mrm/CandyWrapper-research/t3code`; `comp` means `apps/web/src/components`, `web` means `apps/web/src` and `contracts` means `packages/contracts/src`.

| Rows | Source evidence | Implementation |
|---|---|---|
| 281, 285 | `comp/settings/ProjectFaviconPickerDialog.tsx:30-142`, `ProjectSettingsPanel.tsx:499-596`, `ProjectActionsSettings.tsx:91-195`; `contracts/t3ProjectFile.ts:13-111`; `packages/shared/src/t3ProjectFile.ts:21-24` | Image-only project search writes faviconPath across scoped members. Visible-only cancellable t3.json read, validation, deduplication and import reuse action persistence. Existing `App/Sources/ProjectScriptsController.swift:33-80` and `TerminalController.swift:401-424` already execute actions; the audit's running gap was stale. |
| 300 | `comp/ChatView.logic.ts:117-207`, `comp/ChatView.tsx:5740-5835` | Pure state reducer tracks thread, running turn, deferred checkpoint, repository state and manual panel revision. Linked PR takes priority; a completed turn opens diff at three files or 50 changed lines. |
| 311, 313, 389 | `comp/settings/ProjectDefaultsSettings.tsx:145-200`, `SettingsPanels.tsx:3048-3070,3301`, `SourceControlWritingSettings.tsx:181-229` | Shared model traits control filters prompt-injected options and writes ModelSelection options. Mixed custom writing instructions have an explicit Apply across scope. Existing server-owned submodule/origin settings remain. |
| 315 | `comp/settings/SettingsPanels.tsx:3345-3397`, `OpenSourceLicenses.tsx:31-95`, `packages/shared/src/thirdPartyLicenses.ts:1-112` | Server manifest validation, AND search, expandable notices and source links; cancels/releases data on hide. About navigates to it. |
| 316, 330 | `comp/settings/SettingsPanels.tsx:2147-2162`, `comp/sidebar/SidebarChrome.tsx:39-72`, `comp/AppSidebarLayout.tsx:88-90`, `comp/chat/ComposerPrimaryActions.tsx:119-131` | Context meter follows its setting. Release-stage identification follows artwork/pill/none in main/settings sidebars and composer send artwork. This is a stage setting, not custom per-environment colors. |
| 332 | `web/appearanceFonts.ts:35-51,97-156`, `comp/settings/FontFamilyPicker.tsx:88-118`, `SettingsFontPreviews.tsx:14-77`, `contracts/settings.ts:385-403` | Cached FontRuntime and one settings observer resolve four roles. Existing text, markdown, timeline, editor, diff, file and terminal surfaces refresh on preference changes. Detached DSViews catch up by generation. Installed-family combobox and real editor/diff/terminal previews release surfaces on hide. No new timer, key monitor or polling loop. |
| 340 | `comp/KeybindingsConfigWarning.tsx:21-62`, `KeybindingsUpdateToast.logic.ts:3-48`, `contracts/server.ts:341,650-668` | Initial/update config warnings expose Open keybindings.json through the owning server's editor RPC. Existing coalesced update toasts retained. |
| 426, 427 | `comp/settings/ResourceTelemetryDiagnostics.tsx:62-65,401-467,830-840,966-1262`, `.logic.ts:53-66`, `DiagnosticsSettings.tsx:206-235,787-810,1067-1087,1157-1288`; `contracts/resourceTelemetry.ts:395-408,466-516` | Visible-only telemetry subscription, CPU/read/write bars drawn by Core Graphics, zero-safe scaling with minimum nonzero height, bucket tooltips, retry and history windows. Telemetry samples update their section without rebuilding trace tables. Open logs uses server path/editor; trace IDs copy fully and long failures/log text expand. |

## Remaining parity work

- 281: external file chooser and generated-icon selection.
- 285: invalid-file notice and official shortcut deletion behavior on editing an unchanged shortcut.
- 300: branch-wide diff scope, complete multi-PR/capability handling and plan-sheet suppression.
- 311: client t3.json workspace-default inheritance.
- 315: packaged native-client dependency notices; current page displays the server's T3 manifest.
- 316: alternate legacy sidebar, pending the user's recorded decision.
- 330: Dev artwork in the existing stage renderer.
- 332: root rem geometry does not scale all fixed view dimensions; font changes invalidate the window tree rather than only matching roles. Exact browser smoothing is not reproduced on every surface. Simple mode lacks a combined code/terminal preview. Existing terminal default 12pt is preserved until a size preference changes, whereas T3 derives it from the simple code size. Default baseline compatibility takes precedence in this patch. Previews use real native surfaces, with existing rich-content rendering limitations.
- 426: full telemetry group summaries, power/health details, telemetry process tree and tooltips for the older process CPU chart.

## Verification

- Whole `swift test --package-path Packages/CandyKit`: 945 tests passed (262 protocol, 96 client, 125 store, 376 features, 86 design system), including the final hidden-page cleanup. Four new font tests and four settings-logic tests cover defaults, scaling, independent roles, detached labels, no-op/fallback, import validation/deduplication, licenses, chart math and deferred proactive behavior.
- Isolated xcodebuild succeeded with `/tmp/cw-dd-astra713b`, bundle `dev.candywrapper.test.astra713b`, URL scheme `candywrapper-astra713b`.
- Six new `settings-runtime` fidelity states: mean 4.77%, worst 6.91%. Existing settings suites remained 1.70%, 1.88%, 3.38%; all existing assertions passed. Reference cases cover default/custom font states and telemetry bars in both appearances. Full typography/preview-page fidelity is still partial.
- Screen: sandbox connection, General model-traits labels, About links, Appearance installed-family control and real composer preview, live interface size 16 to 17 then reset to 16, Diagnostics live CPU/memory/process values and populated history bars. The sandbox license manifest returned HTTP 200; schema/search are unit tested, but the license page interaction was not verified. Project mutations, warning injection, proactive auto-open and trace actions were not exercised live.
- Retained sandbox screenshot: `wp713b/diagnostics.png`. Shared-screen focus changed repeatedly; every input used the owned PID guard, and refused inputs were retried after activation. Only owned app PIDs 94804 and 5089 were stopped. Reused server PID 32675 was left running. Reference capture used the sandbox Chrome binary, not the user's browser profile. No sandbox project files, real agent turns, macOS permission dialogs, commits, pushes, subagents or T3 MCP calls. Local test-app font preference was restored; the isolated app retains its own navigation state. Launch helper printed a sandbox-extension warning but the app launched and connected.
- Explicit `swift test --package-path Packages/CandyKit --filter Fidelity` passed. Exact runner counts and settings fidelity summaries are in `wp713b/validation.txt`. `git diff --check` passed.
