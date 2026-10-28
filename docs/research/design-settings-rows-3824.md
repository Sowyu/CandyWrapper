# Nightly 3824 settings rows

Task `design-settings-rows`, starting at `3099cee2`. Local commits only, with no push or release.

## Source and changes

Read from `~/CandyWrapper-research/t3code` at `v0.1.4-nightly.20261028.3824`:

- `apps/web/src/components/settings/settingsLayout.tsx:235`: section headings use 16pt semibold foreground text, with a 24pt line box centered in the existing 28pt header.
- `settingsLayout.tsx:489`: descriptions use full muted foreground, a 672pt maximum width and balanced wrapping. SettingsRowView now enables TextBlockView's existing cached binary search for the narrowest width that preserves the line count. Status and inline links keep their existing layout.
- `settingsLayout.tsx:473-478`: local default/environment markers wait for hover, keyboard focus or an open popup unless projects override the value. The existing resting-state implementation now refreshes on focus changes and popup open/close. A regression test checks hover, focus and values that must stay visible.
- `settingsLayout.tsx:467-499` and `apps/web/src/components/ui/select.tsx:21-31`: settings selects without an explicit width fill the minimum 160pt control column. This corrects the Last selected trigger.
- `apps/web/src/components/settings/SettingsSidebarNav.tsx:379-400`: rows have a 4pt gap and groups a 16pt gap. The native layout also counted the last row's 4pt gap before each group. Removing it fixes the existing dark Connections navigation failure.

The heading and description change is upstream `3816296021` (#24865). All geometry and text changes keep Redesign and Glass on their previous paths. No new idle work or wire behavior was added.

The Repositories off switch and TogglesFidelityTests use the same SwitchView (`SettingsRowFactory.swift:138-140`, `TogglesFidelityTests.swift:61-65`). The saved Repositories JSON omitted `dark:data-unchecked:bg-muted-foreground`, which 3824's `ui/switch.tsx:29` and the switch fixture both contain. Regenerating from the shared switch helper restores the correct grey thumb. SwitchView itself does not change.

## References

Updated the stale section/row markup in `gen-connections-spec.py` and `gen-layout-spec.py`, and removed the redundant section-heading replacement in `gen-settings-pages2-spec.py`. No generator retains the old heading class or the old `max-w-xl text-xs leading-normal text-muted-foreground/80` description class.

Regenerated connections, settings, settings-pages, settings-pages2, settings-pages3, theme-settings and usage JSON and captures with `scripts/component-reference`, using the existing 3824 stylesheet and sandbox Chromium 154.0.8037.92. Reviewed representative PNGs from all seven specs. Twenty-seven PNGs changed; capture dimensions, cases, ceilings and exceptions stay unchanged. Shared helper regeneration also restores the current select chevrons and switch classes in the affected specs.

## Validation

Both scoped runs use `scripts/test --filter 'Settings.*FidelityTests|ConnectionsFidelityTests|LayoutFidelityTests|FormsFidelityTests|TogglesFidelityTests|PopupsFidelityTests|ThemeSettingsFidelityTests|ProviderSetupFidelityTests|UsageFidelityTests|Onboarding.*FidelityTests|DesktopManagedFidelityTests' --no-parallel`. Tests run in the background with a 30-minute limit. Counts below are failing pixel cases.

| Suite | Cases | Before | After |
| --- | ---: | ---: | ---: |
| ConnectionsFidelityTests | 36 | 1 | 0 |
| DesktopManagedFidelityTests | 20 | 0 | 0 |
| FormsFidelityTests | 166 | 0 | 0 |
| LayoutFidelityTests | 124 | 0 | 0 |
| OnboardingSnapShotFidelityTests | 6 | 0 | 0 |
| PopupsFidelityTests | 78 | 0 | 0 |
| ProviderSetupFidelityTests | 6 | 0 | 0 |
| SettingsModalFidelityTests | 4 | 0 | 0 |
| SettingsPages2FidelityTests | 12 | 2 | 0 |
| SettingsPages3FidelityTests | 10 | 0 | 0 |
| SettingsPagesFidelityTests | 6 | 0 | 0 |
| SettingsRuntimeFidelityTests | 6 | 0 | 0 |
| SettingsSweepFidelityTests | 8 | 0 | 0 |
| ThemeSettingsFidelityTests | 6 | 0 | 0 |
| TogglesFidelityTests | 288 | 0 | 0 |
| UsageFidelityTests | 10 | 0 | 0 |
| Total | 786 | 3 | 0 |

Repositories improves from 5.72% to 2.19% in light and 6.29% to 2.37% in dark against the unchanged 4.5% ceiling. Connections navigation in dark improves from 7.73% to 1.65% against its unchanged 6.5% ceiling.

`scripts/test --filter RedesignBaselineTests --no-parallel` passed all 80 exact captures with zero changed pixels. The fast lane (`scripts/test --fast --no-parallel`) passed 2,218 Swift Testing tests and 19 XCTest tests, including the new inheritance-marker hover/focus regression test. No requested suite remains failing.

Built the isolated app and rebuilt after the navigation fix; verified all five affected object files postdate their final sources. Reviewed real WindowServer Source Control captures in default light and dark, including heading metrics, balanced descriptions, off switches, the select and grouped navigation. An existing Keychain dialog blocks input and was left alone; window-only captures exclude it. The app used the sandbox on 47391 with fake T3 Connect and no paid turns. Captures are in `~/CandyWrapper-research/sandbox/design-settings-rows-review/`. The app quit, the screen lock was released and `/tmp/cw-dd-design-settings-rows` was deleted. Disk stayed above 40 GB.

Logs, native pixel comparisons and per-suite counts are in `/tmp/cw-settings-rows/`. Reviewed the code diff and ran `git diff --check`. The combined whole-suite and performance review belongs to the integration task.
