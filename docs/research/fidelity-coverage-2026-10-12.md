# Fidelity coverage

Two kinds of cases exist. Direct cases cite a numbered file in design/reference/ by name in the test. Spec cases read design/component-reference/<name>.json, which was extracted from the official app. A "topic match" below means the test name and spec name fit the screenshot, but no test cites the screenshot number (found with grep, not by running anything).

Counts: 47 numbered reference screens (dark and light each, plus 03n, 04n, 11n variants), 91 component-reference specs, 52 *Fidelity* test files (45 in FeaturesTests, 7 in DesignSystemTests).

## Reference screens and covering tests

| Reference screen | Covering test | Link type |
|---|---|---|
| 01 running turn | ComposerFidelityTests | direct |
| 02 sidebar populated | SidebarFidelityTests (Features and DesignSystem) | direct |
| 03a kitchen sink top | ThreadFidelityTests, ComposerFidelityTests | direct |
| 03b middle, 03c bottom, 03d commands | ThreadFidelityTests (03c also PickersFidelityTests) | direct |
| 03n kitchen sink narrow | none | none |
| 04 new thread draft, 04n narrow | ComposerFidelityTests | direct |
| 05 approval, 06 user input | PanelsFidelityTests | direct |
| 07, 08 command palette | DesignSystemTests/CommandPaletteFidelityTests | topic match |
| 09 diff split, 10 diff unified | DiffFidelityTests | direct |
| 11 terminal drawer | TerminalDrawerFidelityTests | topic match |
| 11n right panel narrow, 12 right panel files | FilesFidelityTests, PanelLeftoversFidelityTests | topic match |
| 13 model picker, 41 traits, 42 access mode | PickersFidelityTests | direct |
| 14 slash menu, 15 at-mention | ComposerMenuFidelityTests | topic match |
| 16a to 16c general settings | SettingsPages*FidelityTests, SettingsSweepFidelityTests | topic match (16b also Onboarding tests) |
| 17 appearance | ThemeSettingsFidelityTests | topic match |
| 18 providers | ProviderSetupFidelityTests | topic match |
| 19 keybindings | none found (maybe SettingsPages*) | unclear |
| 20 sidebar thread context menu | SidebarLeftoversFidelityTests | topic match |
| 21 git actions menu, 22 commit dialog | GitFidelityTests | topic match |
| 26 usage limits | UsageFidelityTests | topic match |
| 27 welcome | OnboardingSnapShotFidelityTests | topic match |
| 29 queued messages | QueueFidelityTests | direct |
| 31 sidebar collapsed | none cited | none |
| 32 to 40 settings pages (source control, projects, connections, archived, scheduled tasks, snapshots, storage, diagnostics, integrations) | SettingsPages/2/3, SettingsRuntime, SettingsSweep, ConnectionsFidelityTests | topic match |
| 43 find in thread | none | none |
| 44 thread details panel | none (ThreadSweep or ThreadLeftovers may touch it) | unclear |
| 45 go to file, 46 project search | none | none |
| 47 changed files card, 48 diff turn file | ChangedFilesFidelityTests | direct |

## Surfaces with spec cases but no reference screenshot

Browser, banner stack, markdown, run-on, pull requests (and writes), thread lineage, thread completion, notifications, device panels, desktop managed, desktop leftovers, small areas, wp717, composer attachments, composer rich text, composer footer, timeline gaps.

## Surfaces with no fidelity case, ranked by how often a user sees them

1. Narrow window layout of the thread (03n). Any user with a small window sees it.
2. Collapsed sidebar (31). Common toggle, no cited case.
3. Find in thread (43). Used often in long threads.
4. Go to file (45) and project search (46). Frequent quick-open surfaces.
5. Thread details panel (44). Unclear coverage.
6. Keybindings settings page (19). Rarely opened.
7. Light/dark pairing: tests cite names without theme in several files, so check that each runs both themes.

Also: the DesignSystemTests files LayoutFidelity, TogglesFidelity, FormsFidelity, PopupsFidelity cite no reference file, so they may check only internal tokens. Not verified. Specs with no matching test name: alert, dialog, menu, popover, tooltip, toast, sheet, table, scroll-area, secret-request, mcp-followups, quit-hold-overlay, qr-code, subagent-bar, wizard-steps, standalone-page. Some may be covered by the DesignSystem files above.
