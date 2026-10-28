# Settings and Usage screens at 3824

Task design-screens-settings starts at 793a1c7f. Local commits only. All checks run offscreen because an existing Keychain prompt blocks input on this Mac.

## Reference inventory

Searched every Swift fidelity suite for design/reference and stems 16a, 16b, 16c, 17, 18, 19, 26, 27 and 32 through 40. No executable test reads those old screen PNGs. SettingsPagesFidelityTests mentions screen 19 in its comment; its cases, like SettingsPages2/3, SettingsSweep, SettingsRuntime, ThemeSettings, ProviderSetup, Usage and OnboardingSnapShot, actually read design/component-reference. ReferenceScreensFidelityTests reads component captures and the unrelated 03n thread screen. Those component checks remain in place.

The new SettingsScreensFidelityTests reads the actual design/reference-3824 screenshots. It compares the whole 1020 by 700 route panel at its 40pt inset in the 1100 by 780 browser viewport, including navigation, header and visible contents. General includes top, middle, bottom and the explicit 49 modal state. Usage includes 26 Limits and 26b Cost and Tokens. Both themes run without ignored bands. The established SettingsPages 5% and Usage 9.5% ceilings apply, with no exceptions. The original reference and reference-3814 directories stay unchanged. Full-window thread/backdrop fidelity is outside the panel crop; SettingsModalFidelityTests continues to check the shell and backdrop against its 2% ceiling.

## Source

All paths below refer to the read-only T3 source at v0.1.4-nightly.20261028.3824.

- apps/web/src/components/settings/SettingsSidebarNav.tsx:252-271,362-410: root sidebar palette, search, grouped navigation.
- apps/web/src/routes/_chat.settings.tsx:120-142: 48pt modal header, breadcrumb, Restore device defaults, close.
- apps/web/src/components/settings/settingsLayout.tsx:574-586: scroll gutter and page container.
- apps/web/src/components/settings/SettingsPanels.tsx:833-853,935-938: Working section copy and switch, desktop-only Quit row.

- apps/web/src/components/settings/SettingsScopeNotice.tsx:83-97,121-169 and ProjectsSettings.tsx:49-51: status sentence, project icon/name/path rows and their scope actions.
- apps/web/src/components/settings/IntegrationsSettings.tsx:1323-1445,1602-1638: inline browser profiles, desktop-only notices and the Advanced fold. The existing profile writes and row bindings stay in use.
- apps/web/src/components/settings/ResourceTelemetryDiagnostics.tsx:164-200,216-294,965-1089: native-health badge, footprint introduction, six counters and three process groups. The existing subscription owns its lifetime; there is no new timer.
- apps/web/src/index.css:1303-1309 and components/settings/ProviderSettingsPanel.tsx:1053-1059: flat provider detail groups, edge-to-edge dividers, horizontal text insets and 16pt vertical padding.
- apps/web/src/components/settings/ThemeSettings.tsx:657-699: the 140pt wireframe, the tile's border/padding and its 2pt inset selection ring.

## Implementation and fixtures

Default-theme navigation can use the root sidebar palette without changing thread navigation. General keeps its native desktop Quit row, while browser-host fixtures omit it through the context's desktop capability. CandyWrapper's menu-bar row stays on its Redesign path. Working section and provider-update descriptions follow 3824. Appearance fixes the selected tile ring and the Themes heading's line box. Projects uses the current name/path picker. Providers uses flat detail sections, separate Status and Display name rows, and one Advanced section for the health interval and idle compaction. Browser uses the current profile list and Advanced fold, preserving the existing writes and profile actions. Diagnostics adds the full footprint summary; classic themes keep their compact presentation.

The screen fixtures use the captured default project order, two provider instances and 13 Claude models, shared model preferences, idle-compaction modes, current storage capabilities, no archived or scheduled threads, the captured sandbox project, and empty Usage. Diagnostics receives synthetic, read-only telemetry matching each capture's visible values. The official sandbox was inspected with a temporary headless browser profile and a fresh sandbox pairing. No account login, settings write, Keychain access or paid turn was used.

Font smoothing follows the application's default setting for these browser-screen comparisons. Component suites retain their own pinned rendering state. No component references, old screenshot directories, ceiling, threshold, ignored band or exception changed. The Browser profile list holds its binding helper weakly, so closing the page releases the helper, its row and the profile list; SettingsScopeLifetimeTests checks that the profile list and context are released.

The provider fixture uses the exact 665.5pt scroll offset logged for screen 18 in the original sandbox `main-3824.log`. A percentage of native document height gave a different viewport because offscreen sections differ in height. A fresh DOM inspection confirmed the capture offset and a 188pt provider list; the native list no longer adds an extra point after each 72pt row. The 452pt model section already matched the browser. Diagnostic aggregate headings now wrap with the source's 1pt letter spacing, and process counts use the source's muted badge.

Additional source references:

- apps/web/src/components/settings/ProviderInstanceCard.tsx:1134-1167: Status and Display name rows.
- apps/web/src/components/settings/ProviderSettingsPanel.tsx:1031-1059,1081-1155: provider list, editor padding and combined Advanced section.
- apps/web/src/components/settings/ProviderModelsSection.tsx:294-348,470-475: model toolbar, list spacing and 28pt model rows.
- apps/web/src/components/settings/ResourceTelemetryDiagnostics.tsx:263-289: aggregate header, process badge and metric pairs.

## Per-case results

Diffs are percentages of changed pixels, using the existing comparison tolerance. Before uses the new screen harness on 793a1c7f before layout and fixture changes. The [complete per-case data](design-screens-settings-3824-cases.json) includes every requested suite plus Connections and shared Layout. A missing before value means that extra suite was only included in the final validation.

| Screen | Light before | Light after | Dark before | Dark after | Ceiling |
|---|---:|---:|---:|---:|---:|
| 16a-settings-general | 4.94% | 1.65% | 6.88% | 1.66% | 5.00% |
| 16b-settings-general-mid | 4.37% | 3.45% | 5.45% | 3.61% | 5.00% |
| 16c-settings-general-bottom | 4.89% | 1.63% | 7.19% | 1.65% | 5.00% |
| 17-settings-appearance | 5.15% | 2.23% | 6.63% | 2.00% | 5.00% |
| 19-settings-keybindings | 4.75% | 4.40% | 5.82% | 4.49% | 5.00% |
| 32-settings-source-control | 3.78% | 3.16% | 4.80% | 3.20% | 5.00% |
| 33-settings-projects | 2.20% | 0.96% | 10.38% | 0.95% | 5.00% |
| 34-settings-connections | 2.11% | 1.82% | 2.88% | 1.65% | 5.00% |
| 35-settings-archived | 1.53% | 1.24% | 1.44% | 1.12% | 5.00% |
| 36-settings-scheduled-tasks | 1.34% | 1.04% | 2.25% | 1.02% | 5.00% |
| 37-settings-snapshots | 1.73% | 1.46% | 2.57% | 1.36% | 5.00% |
| 38-settings-storage | 6.50% | 1.79% | 7.28% | 1.80% | 5.00% |
| 39-settings-diagnostics | 6.88% | 4.97% | 47.18% | 4.89% | 5.00% |
| 40-settings-integrations | 5.64% | 4.57% | 7.21% | 4.69% | 5.00% |
| 49-settings-modal-general | 4.94% | 1.65% | 6.88% | 1.66% | 5.00% |
| 18-settings-providers | 7.10% | 5.25% | 11.42% | 5.48% | 5.00% |
| 26-usage-limits | 0.68% | 0.46% | 0.67% | 0.44% | 9.50% |
| 26b-usage-cost | 1.13% | 1.00% | 1.15% | 0.99% | 9.50% |
| 26b-usage-tokens | 1.10% | 0.97% | 1.12% | 0.96% | 9.50% |

| Suite | Cases | Before failing | After failing | Worst after |
|---|---:|---:|---:|---:|
| ConnectionsFidelityTests | 36 | Not measured | 0 | 4.76% |
| LayoutFidelityTests | 124 | Not measured | 0 | 18.63% |
| OnboardingSnapShotFidelityTests | 6 | 0 | 0 | 2.76% |
| ProviderSetupFidelityTests | 6 | 0 | 0 | 4.44% |
| ReferenceScreensFidelityTests | 10 | 6 | 6 | 94.09% |
| SettingsModalFidelityTests | 4 | 0 | 0 | 0.82% |
| SettingsPages2FidelityTests | 12 | 0 | 0 | 2.59% |
| SettingsPages3FidelityTests | 10 | 0 | 0 | 7.25% |
| SettingsPagesFidelityTests | 6 | 0 | 0 | 2.58% |
| SettingsRuntimeFidelityTests | 6 | 0 | 0 | 6.84% |
| SettingsScreensFidelityTests | 38 | 16 | 2 | 5.48% |
| SettingsSweepFidelityTests | 8 | 0 | 0 | 2.62% |
| ThemeSettingsFidelityTests | 6 | 0 | 0 | 3.07% |
| UsageFidelityTests | 10 | 0 | 0 | 6.51% |

## Validation and remaining failures

The final scoped run uses `scripts/test --filter 'Settings.*FidelityTests|ThemeSettingsFidelityTests|ProviderSetupFidelityTests|UsageFidelityTests|Onboarding.*FidelityTests|ReferenceScreensFidelityTests|ConnectionsFidelityTests|LayoutFidelityTests' --no-parallel --jobs 2`. It renders 282 cases: 274 pass and eight fail. All 74 existing Settings, Theme, ProviderSetup, Usage and Onboarding component cases pass. Connections' 36 cases and shared Layout's 124 cases pass at their existing per-case limits.

The new screen suite improves from 16 failing Settings cases to two. General 49 and all six Usage cases pass. Diagnostics passes at 4.97% light and 4.89% dark. Providers remains failing at 5.25% light and 5.48% dark against 5%. Its row and section positions still differ slightly, and its model toolbar and text metrics need more work. The captured viewport is pinned rather than adjusted to conceal those differences. No ceiling, comparison tolerance, ignored band or exception changed.

ReferenceScreens retains six failures and its aggregate failure, with exactly the same per-case measurements as the starting branch:

| Existing case | Before and after | Ceiling |
|---|---:|---:|
| sidebar-collapsed.rest.dark | 29.76% | 5.50% |
| find.rest.dark | 91.90% | 5.50% |
| go-to-file.rest.dark | 94.09% | 5.50% |
| project-search.rest.dark | 87.53% | 5.50% |
| 03n-narrow.light | 7.26% | 5.50% |
| 03n-narrow.dark | 19.64% | 5.50% |

Those cases exercise thread, search and sidebar views, not Settings or Usage. Their renderers and references belong to the parallel screen tasks and remain unchanged here. No existing fidelity case read welcome screen 27; the six existing Onboarding component cases remain covered. Full-window dimmed-thread pixels remain outside the allowed panel crops used by this suite.

The standalone `scripts/test --filter RedesignBaselineTests --no-parallel --jobs 2` passes all 80 exact image comparisons, including after the final provider-list and resource-badge changes. The final `scripts/test --fast --no-parallel --jobs 2` passes 2,219 Swift Testing tests and 19 XCTest tests, including the Browser profile lifetime regression. All tests run through scripts/test in background subprocesses with a 30-minute timeout. No direct swift test invocation, native app launch or screen input was used.

Reviewed the diff and offscreen captures of General, Appearance, Providers, Projects, Browser, Diagnostics and Usage. Changes add no polling or idle timer and retain the existing settings writes and telemetry lifetime. Performance review and full-window interaction checks were not run under the task's offscreen-only constraint. The temporary headless profile and capture copies are removed after validation; the existing sandbox server remains running.

Artifacts remain in `/tmp/cw-settings-screens-final/`, with logs in `/tmp/cw-settings-screens-final.log`, `/tmp/cw-settings-screens-final-redesign.log` and `/tmp/cw-settings-screens-final-fast.log`. No screenshots or credentials are committed.
