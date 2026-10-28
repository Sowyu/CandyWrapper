# Nightly 3814 fidelity failures

Run: `CW_FIDELITY_OUT=/tmp/tokens-3814-fidelity scripts/test --filter Fidelity`. The default palettes use 3814 tokens; the existing references and components remain unchanged. These suites render the T3 default themes. The `.fidelity` trait pins `ThemeRuntimeInput()` before each annotated test. Cases named `glass.*` are T3's glass button variant. CandyWrapper's Glass and Redesign palette baselines pass exactly in the fast lane.

Diff is the share of pixels with any channel more than 8/255 away from the reference. Values below are shares (0.9559 means 95.59%). The per-case values come from the actual failing assertion, before percentage rounding. Aggregate assertions remain listed separately from their cases.

All 137 tests ran (71 Features, 66 DesignSystem). 95 test methods in 54 suites failed: 924 case assertions covering 904 distinct cases, plus 44 other assertions. Features reported 413 issues and DesignSystem reported 555, for 968 total.

The additional `OverlaysFidelityTests.vImageBlurMatchesCoreImage` failure is a worst-channel difference of 3/255 against a 2/255 ceiling, using the new default dark toggle-gallery colors. References, ceilings and components remain unchanged.

| Suite | Failing test methods | Case assertions | Diff range |
|---|---:|---:|---|
| DesignSystemTests.CommandPaletteFidelityTests | 1 | 0 | mean 0.4751 |
| DesignSystemTests.FidelityTests | 1 | 135 | 0.3540 to 0.9911 |
| DesignSystemTests.FormsFidelityTests | 24 | 185 | 0.0406 to 0.9988 |
| DesignSystemTests.OverlaysFidelityTests | 1 | 0 | channel 3/255 |
| DesignSystemTests.PopupsFidelityTests | 7 | 41 | 0.0524 to 0.9880 |
| DesignSystemTests.SidebarFidelityTests | 4 | 39 | 0.2307 to 0.9923 |
| DesignSystemTests.TogglesFidelityTests | 8 | 153 | 0.0692 to 0.9950 |
| FeaturesTests.BannerStackFidelityTests | 1 | 20 | 0.3684 to 0.5251 |
| FeaturesTests.BrowserFidelityTests | 1 | 5 | 0.7996 to 0.9904 |
| FeaturesTests.ChangedFilesFidelityTests | 1 | 10 | 0.2026 to 0.8958 |
| FeaturesTests.ComposerAttachmentsFidelityTests | 1 | 4 | 0.3229 to 0.5915 |
| FeaturesTests.ComposerFidelityTests | 1 | 2 | 0.1230 to 0.1310 |
| FeaturesTests.ComposerFooterFidelityTests | 1 | 7 | 0.1461 to 0.9984 |
| FeaturesTests.ComposerMenuFidelityTests | 1 | 6 | 0.2284 to 0.9630 |
| FeaturesTests.ComposerRichTextFidelityTests | 1 | 8 | 0.9622 to 0.9963 |
| FeaturesTests.ConnectionsFidelityTests | 1 | 18 | 0.0966 to 0.9992 |
| FeaturesTests.DesktopLeftoversFidelityTests | 1 | 5 | 0.4187 to 0.8122 |
| FeaturesTests.DesktopManagedFidelityTests | 1 | 10 | 0.7322 to 0.9627 |
| FeaturesTests.DevicePanelFidelityTests | 1 | 2 | 0.9815 to 0.9822 |
| FeaturesTests.DiffFidelityTests | 2 | 11 | 0.3890 to 0.9853 |
| FeaturesTests.FilesFidelityTests | 1 | 4 | 0.9890 to 0.9933 |
| FeaturesTests.GitFidelityTests | 1 | 7 | 0.1799 to 0.8253 |
| FeaturesTests.MarkdownFidelityTests | 2 | 9 | 0.2150 to 0.9946 |
| FeaturesTests.MathFidelityTests | 1 | 76 | 0.9599 to 0.9976 |
| FeaturesTests.McpFollowupsFidelityTests | 1 | 0 | mean 0.4805 |
| FeaturesTests.NotificationsFidelityTests | 1 | 8 | 0.1629 to 0.6793 |
| FeaturesTests.OnboardingSnapShotFidelityTests | 1 | 3 | 0.2863 to 0.9789 |
| FeaturesTests.PanelLeftoversFidelityTests | 1 | 4 | 0.5216 to 0.9888 |
| FeaturesTests.PickersFidelityTests | 1 | 1 | 0.1020 to 0.1020 |
| FeaturesTests.ProviderSetupFidelityTests | 1 | 3 | 0.6928 to 0.9601 |
| FeaturesTests.PullRequestWritesFidelityTests | 1 | 2 | 0.1402 to 0.2297 |
| FeaturesTests.PullRequestsFidelityTests | 1 | 3 | 0.8204 to 0.9790 |
| FeaturesTests.ReferenceScreensFidelityTests | 1 | 5 | 0.0956 to 0.9397 |
| FeaturesTests.RunOnFidelityTests | 1 | 11 | 0.0600 to 0.9836 |
| FeaturesTests.SettingsPages2FidelityTests | 1 | 5 | 0.1443 to 0.9645 |
| FeaturesTests.SettingsPages3FidelityTests | 1 | 5 | 0.1257 to 0.8047 |
| FeaturesTests.SettingsPagesFidelityTests | 1 | 3 | 0.1311 to 0.2260 |
| FeaturesTests.SettingsRuntimeFidelityTests | 1 | 3 | 0.9222 to 0.9869 |
| FeaturesTests.SettingsSweepFidelityTests | 1 | 8 | 0.3939 to 0.9873 |
| FeaturesTests.SidebarLeftoversFidelityTests | 1 | 13 | 0.0628 to 0.3854 |
| FeaturesTests.SidebarSearchFidelityTests | 1 | 13 | 0.1656 to 0.3088 |
| FeaturesTests.SmallAreasFidelityTests | 1 | 5 | 0.1275 to 0.9954 |
| FeaturesTests.SweepPanelsFidelityTests | 1 | 2 | 0.2226 to 0.3029 |
| FeaturesTests.TerminalDrawerFidelityTests | 1 | 3 | 0.9780 to 0.9931 |
| FeaturesTests.ThemeSettingsFidelityTests | 1 | 3 | 0.1941 to 0.8923 |
| FeaturesTests.ThreadCompletionFidelityTests | 1 | 7 | 0.5207 to 0.9711 |
| FeaturesTests.ThreadFidelityTests | 1 | 6 | 0.0951 to 0.2162 |
| FeaturesTests.ThreadLeftoversFidelityTests | 1 | 7 | 0.3803 to 0.9410 |
| FeaturesTests.ThreadLineageFidelityTests | 1 | 11 | 0.1513 to 0.9917 |
| FeaturesTests.ThreadSweepFidelityTests | 1 | 4 | 0.2127 to 0.9787 |
| FeaturesTests.ThreadViewFidelityTests | 1 | 9 | 0.1715 to 0.9907 |
| FeaturesTests.TimelineGapsFidelityTests | 1 | 12 | 0.1298 to 0.9994 |
| FeaturesTests.UsageFidelityTests | 1 | 5 | 0.2434 to 0.8219 |
| FeaturesTests.WP717FidelityTests | 1 | 3 | 0.0671 to 0.9170 |

## DesignSystemTests.CommandPaletteFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|

`commandPalette()`: Expectation failed: mean < 0.05; mean = 0.475077; limit = 0.050000

## DesignSystemTests.FidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `button()` | `ghost-muted.sm.rest.dark` | 0.991112 | 0.0750 |
| `button()` | `ghost-destructive.sm.rest.dark` | 0.990156 | 0.0750 |
| `button()` | `ghost-muted.sm.disabled.dark` | 0.982224 | 0.0750 |
| `button()` | `ghost-destructive.sm.disabled.dark` | 0.981369 | 0.0750 |
| `button()` | `link.sm.active.dark` | 0.972476 | 0.0750 |
| `button()` | `link.sm.rest.dark` | 0.969230 | 0.0750 |
| `button()` | `ghost.sm.rest.dark` | 0.967345 | 0.0750 |
| `button()` | `ghost.sm.hover.dark` | 0.966159 | 0.0750 |
| `button()` | `link.sm.hover.dark` | 0.965614 | 0.0750 |
| `button()` | `link.sm.disabled.dark` | 0.964064 | 0.0750 |
| `button()` | `ghost.sm.disabled.dark` | 0.963474 | 0.0750 |
| `button()` | `secondary.sm.hover.dark` | 0.953252 | 0.0750 |
| `button()` | `secondary.sm.rest.dark` | 0.951681 | 0.0750 |
| `button()` | `ghost.sm.active.dark` | 0.950300 | 0.0750 |
| `button()` | `media-navigation.sm.rest.dark` | 0.947274 | 0.0750 |
| `button()` | `secondary.sm.disabled.dark` | 0.947016 | 0.0750 |
| `button()` | `ghost-destructive.sm.hover.dark` | 0.945957 | 0.0750 |
| `button()` | `ghost-muted.sm.hover.dark` | 0.944805 | 0.0750 |
| `button()` | `media-navigation.sm.hover.dark` | 0.943926 | 0.0750 |
| `button()` | `media-navigation.sm.disabled.dark` | 0.941288 | 0.0750 |
| `button()` | `secondary.sm.active.dark` | 0.936391 | 0.0750 |
| `button()` | `ghost-muted.sm.active.dark` | 0.929018 | 0.0750 |
| `button()` | `ghost-destructive.sm.active.dark` | 0.928251 | 0.0750 |
| `button()` | `glass.sm.rest.dark` | 0.915806 | 0.0750 |
| `button()` | `glass.sm.disabled.dark` | 0.914644 | 0.0750 |
| `button()` | `glass.sm.hover.dark` | 0.914062 | 0.0750 |
| `button()` | `destructive-outline.sm.active.dark` | 0.911616 | 0.1100 |
| `button()` | `media-navigation.sm.active.dark` | 0.909057 | 0.1000 |
| `button()` | `destructive-outline.sm.hover.dark` | 0.903157 | 0.0750 |
| `button()` | `warning-outline.sm.disabled.dark` | 0.901539 | 0.0750 |
| `button()` | `ghost-muted.sm.focus-visible.dark` | 0.895982 | 0.0750 |
| `button()` | `ghost-destructive.sm.focus-visible.dark` | 0.895547 | 0.0750 |
| `button()` | `glass.sm.active.dark` | 0.886622 | 0.0750 |
| `button()` | `ghost.sm.focus-visible.dark` | 0.861701 | 0.0750 |
| `button()` | `link.sm.focus-visible.dark` | 0.861054 | 0.0750 |
| `button()` | `secondary.sm.focus-visible.dark` | 0.850702 | 0.0750 |
| `button()` | `glass.sm.focus-visible.dark` | 0.830256 | 0.0750 |
| `button()` | `outline.icon-tiny.active.dark` | 0.828857 | 0.0750 |
| `button()` | `outline.icon-tiny.rest.dark` | 0.823486 | 0.0750 |
| `button()` | `outline.icon-tiny.disabled.dark` | 0.820557 | 0.0750 |
| `button()` | `outline.icon-tiny.hover.dark` | 0.820068 | 0.0750 |
| `button()` | `media-navigation.sm.focus-visible.dark` | 0.806581 | 0.0850 |
| `button()` | `outline.icon-micro.rest.dark` | 0.740355 | 0.0750 |
| `button()` | `outline.icon-micro.active.dark` | 0.738426 | 0.0750 |
| `button()` | `outline.icon-micro.disabled.dark` | 0.734954 | 0.0750 |
| `button()` | `outline.icon-micro.hover.dark` | 0.733989 | 0.0750 |
| `button()` | `outline.icon-tiny.focus-visible.dark` | 0.708252 | 0.0750 |
| `button()` | `outline.icon-xs.active.dark` | 0.694375 | 0.0750 |
| `button()` | `outline.icon-xs.disabled.dark` | 0.687344 | 0.0750 |
| `button()` | `outline.icon-xs.rest.dark` | 0.683281 | 0.0750 |
| `button()` | `outline.icon-xs.hover.dark` | 0.677813 | 0.0750 |
| `button()` | `outline.icon-sm.active.dark` | 0.636364 | 0.0750 |
| `button()` | `outline.icon-sm.rest.dark` | 0.633910 | 0.0750 |
| `button()` | `outline.icon-sm.disabled.dark` | 0.632361 | 0.0750 |
| `button()` | `outline.icon-sm.hover.dark` | 0.632102 | 0.0750 |
| `button()` | `outline.micro.active.dark` | 0.631647 | 0.0750 |
| `button()` | `outline.micro.rest.dark` | 0.625496 | 0.0750 |
| `button()` | `outline.micro.hover.dark` | 0.624107 | 0.0750 |
| `button()` | `outline.micro.disabled.dark` | 0.621726 | 0.0750 |
| `button()` | `outline.xs.active.dark` | 0.617888 | 0.0750 |
| `button()` | `outline.icon-micro.focus-visible.dark` | 0.613233 | 0.0750 |
| `button()` | `outline.xs.disabled.dark` | 0.600754 | 0.0750 |
| `button()` | `outline.xs.rest.dark` | 0.600431 | 0.0750 |
| `button()` | `outline.icon.active.dark` | 0.599392 | 0.0750 |
| `button()` | `outline.xs.hover.dark` | 0.596013 | 0.0750 |
| `button()` | `outline.icon.rest.dark` | 0.588542 | 0.0750 |
| `button()` | `outline.icon.disabled.dark` | 0.587674 | 0.0750 |
| `button()` | `outline.icon.hover.dark` | 0.586914 | 0.0750 |
| `button()` | `warning-outline.sm.active.dark` | 0.570268 | 0.1300 |
| `button()` | `outline.icon-xs.focus-visible.dark` | 0.569531 | 0.0750 |
| `button()` | `default.sm.active.dark` | 0.555000 | 0.1100 |
| `button()` | `outline.icon-lg.active.dark` | 0.554919 | 0.0750 |
| `button()` | `destructive.sm.active.dark` | 0.553711 | 0.1400 |
| `button()` | `outline.icon-lg.rest.dark` | 0.548539 | 0.0750 |
| `button()` | `outline.icon-lg.disabled.dark` | 0.547430 | 0.0750 |
| `button()` | `outline.icon-lg.hover.dark` | 0.547245 | 0.0750 |
| `button()` | `overlay.sm.active.dark` | 0.532966 | 0.0750 |
| `button()` | `outline.icon-xl.active.dark` | 0.524235 | 0.0750 |
| `button()` | `outline.icon-sm.focus-visible.dark` | 0.523373 | 0.0750 |
| `button()` | `outline.sm.active.dark` | 0.517741 | 0.0750 |
| `button()` | `outline.icon-xl.rest.dark` | 0.517459 | 0.0750 |
| `button()` | `outline.icon-xl.hover.dark` | 0.516582 | 0.0750 |
| `button()` | `outline.icon-xl.disabled.dark` | 0.514110 | 0.0750 |
| `button()` | `outline.compact.active.dark` | 0.510173 | 0.0750 |
| `button()` | `outline.micro.focus-visible.dark` | 0.506151 | 0.0750 |
| `button()` | `outline.sm.rest.dark` | 0.505682 | 0.0750 |
| `button()` | `outline.sm.hover.dark` | 0.505044 | 0.0750 |
| `button()` | `overlay.sm.rest.dark` | 0.504163 | 0.0750 |
| `button()` | `overlay.sm.hover.dark` | 0.503938 | 0.0750 |
| `button()` | `outline.sm.disabled.dark` | 0.502319 | 0.0750 |
| `button()` | `media-close.sm.active.dark` | 0.501557 | 0.1050 |
| `button()` | `outline.compact.rest.dark` | 0.500703 | 0.0750 |
| `button()` | `outline.compact.hover.dark` | 0.500108 | 0.0750 |
| `button()` | `overlay.sm.disabled.dark` | 0.499269 | 0.0750 |
| `button()` | `default.sm.disabled.dark` | 0.498239 | 0.0750 |
| `button()` | `outline.compact.disabled.dark` | 0.495617 | 0.0750 |
| `button()` | `outline.lg.active.dark` | 0.493674 | 0.0750 |
| `button()` | `outline.xs.focus-visible.dark` | 0.488254 | 0.0750 |
| `button()` | `default.sm.hover.dark` | 0.485341 | 0.0750 |
| `button()` | `default.sm.rest.dark` | 0.485284 | 0.0750 |
| `button()` | `outline.lg.rest.dark` | 0.484185 | 0.0750 |
| `button()` | `outline.lg.hover.dark` | 0.483426 | 0.0750 |
| `button()` | `outline.lg.disabled.dark` | 0.482983 | 0.0750 |
| `button()` | `outline.icon.focus-visible.dark` | 0.480903 | 0.0750 |
| `button()` | `warning-outline.sm.rest.dark` | 0.480042 | 0.0750 |
| `button()` | `destructive.sm.disabled.dark` | 0.479892 | 0.0750 |
| `button()` | `outline.default.active.dark` | 0.479756 | 0.0750 |
| `button()` | `warning-outline.sm.hover.dark` | 0.478927 | 0.0750 |
| `button()` | `destructive-outline.sm.rest.dark` | 0.468213 | 0.0750 |
| `button()` | `outline.default.rest.dark` | 0.467227 | 0.0750 |
| `button()` | `outline.default.hover.dark` | 0.465851 | 0.0750 |
| `button()` | `outline.default.disabled.dark` | 0.464377 | 0.0750 |
| `button()` | `outline.xl.active.dark` | 0.461781 | 0.0750 |
| `button()` | `destructive.sm.hover.dark` | 0.461737 | 0.0750 |
| `button()` | `destructive-outline.sm.disabled.dark` | 0.459880 | 0.0750 |
| `button()` | `destructive.sm.rest.dark` | 0.459828 | 0.0750 |
| `button()` | `outline.icon-lg.focus-visible.dark` | 0.445729 | 0.0750 |
| `button()` | `outline.xl.rest.dark` | 0.444632 | 0.0750 |
| `button()` | `outline.xl.hover.dark` | 0.443870 | 0.0750 |
| `button()` | `outline.xl.disabled.dark` | 0.442890 | 0.0750 |
| `button()` | `media-close.sm.disabled.dark` | 0.430724 | 0.0750 |
| `button()` | `outline.icon-xl.focus-visible.dark` | 0.418607 | 0.0750 |
| `button()` | `media-close.sm.rest.dark` | 0.416582 | 0.0750 |
| `button()` | `media-close.sm.hover.dark` | 0.416582 | 0.0750 |
| `button()` | `outline.sm.focus-visible.dark` | 0.405032 | 0.0750 |
| `button()` | `default.sm.focus-visible.dark` | 0.403636 | 0.0750 |
| `button()` | `overlay.sm.focus-visible.dark` | 0.402453 | 0.0750 |
| `button()` | `outline.compact.focus-visible.dark` | 0.400703 | 0.0750 |
| `button()` | `destructive.sm.focus-visible.dark` | 0.393333 | 0.0850 |
| `button()` | `outline.lg.focus-visible.dark` | 0.389550 | 0.0750 |
| `button()` | `warning-outline.sm.focus-visible.dark` | 0.388737 | 0.0950 |
| `button()` | `media-close.sm.focus-visible.dark` | 0.385522 | 0.0800 |
| `button()` | `destructive-outline.sm.focus-visible.dark` | 0.376578 | 0.0850 |
| `button()` | `outline.default.focus-visible.dark` | 0.372887 | 0.0750 |
| `button()` | `outline.xl.focus-visible.dark` | 0.354040 | 0.0750 |

## DesignSystemTests.FormsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `textBlock()` | `xs13.300.rest.dark` | 0.971108 | 0.1400 |
| `textBlock()` | `clamp2.260.rest.dark` | 0.915809 | 0.1400 |
| `textBlock()` | `sm.420.rest.dark` | 0.912247 | 0.1400 |
| `textBlock()` | `sm.180.rest.dark` | 0.911110 | 0.1400 |
| `textBlock()` | `sm.343.rest.dark` | 0.910245 | 0.1400 |
| `textBlock()` | `center.260.rest.dark` | 0.902334 | 0.1400 |
| `textBlock()` | `sm.260.rest.dark` | 0.900789 | 0.1400 |
| `textBlock()` | `xl.300.rest.dark` | 0.882880 | 0.1650 |
| `textBlock()` | `xl.300.rest.light` | 0.210029 | 0.1600 |
| `textBlock()` | `center.260.rest.light` | 0.153533 | 0.1400 |
| `textBlock()` | `sm.260.rest.light` | 0.151614 | 0.1400 |
| `toast()` | `plain.wrap.rest.dark` | 0.202626 | 0.0700 |
| `toast()` | `success.rest.dark` | 0.192873 | 0.0700 |
| `toast()` | `error.rest.dark` | 0.187832 | 0.0700 |
| `toast()` | `warning.wrap.rest.dark` | 0.181005 | 0.0700 |
| `toast()` | `info.action.rest.dark` | 0.158488 | 0.0700 |
| `toast()` | `warning.wrap.rest.light` | 0.077476 | 0.0700 |
| `toast()` | `plain.wrap.rest.light` | 0.072915 | 0.0700 |
| `dialogs()` | `default.panel.rest.dark` | 0.893366 | 0.0900 |
| `dialogs()` | `bare.panel.rest.dark` | 0.870903 | 0.0900 |
| `dialogs()` | `default.rest.dark` | 0.858754 | 0.0900 |
| `dialogs()` | `default.rest.dark` | 0.887601 | 0.0900 |
| `dialogs()` | `bare.rest.dark` | 0.855472 | 0.0900 |
| `dialogs()` | `right.inset.rest.dark` | 0.087025 | 0.0300 |
| `dialogs()` | `right.rest.dark` | 0.085548 | 0.0300 |
| `dialogs()` | `left.rest.dark` | 0.085347 | 0.0300 |
| `commandPalette()` | `root.rest.dark` | 0.932272 | 0.0650 |
| `commandPalette()` | `search.rest.dark` | 0.914847 | 0.0650 |
| `commandPalette()` | `browse.rest.dark` | 0.905789 | 0.0650 |
| `commandPalette()` | `match.rest.dark` | 0.904792 | 0.0650 |
| `commandPalette()` | `submenu.rest.dark` | 0.902630 | 0.0650 |
| `commandPalette()` | `empty.rest.dark` | 0.894499 | 0.0650 |
| `label()` | `short.rest.dark` | 0.925492 | 0.1000 |
| `label()` | `text.rest.dark` | 0.913770 | 0.1000 |
| `label()` | `text.rest.light` | 0.129016 | 0.1000 |
| `label()` | `short.rest.light` | 0.110966 | 0.1000 |
| `input()` | `sm.placeholder.rest.dark` | 0.448220 | 0.0450 |
| `input()` | `sm.placeholder.disabled.dark` | 0.446001 | 0.0450 |
| `input()` | `mono.value.rest.dark` | 0.421956 | 0.0650 |
| `input()` | `mono.value.disabled.dark` | 0.420878 | 0.0600 |
| `input()` | `compact.placeholder.rest.dark` | 0.418733 | 0.0450 |
| `input()` | `compact.placeholder.disabled.dark` | 0.416801 | 0.0450 |
| `input()` | `default.placeholder.rest.dark` | 0.416077 | 0.0450 |
| `input()` | `default.placeholder.disabled.dark` | 0.414042 | 0.0450 |
| `input()` | `invalid.value.rest.dark` | 0.397257 | 0.0450 |
| `input()` | `default.value.rest.dark` | 0.396261 | 0.0450 |
| `input()` | `invalid.value.disabled.dark` | 0.395671 | 0.0450 |
| `input()` | `default.value.disabled.dark` | 0.394979 | 0.0450 |
| `input()` | `lg.placeholder.rest.dark` | 0.388878 | 0.0450 |
| `input()` | `lg.placeholder.disabled.dark` | 0.387000 | 0.0450 |
| `input()` | `sm.placeholder.focus-visible.dark` | 0.310103 | 0.0450 |
| `input()` | `mono.value.focus-visible.dark` | 0.293416 | 0.0650 |
| `input()` | `default.placeholder.focus-visible.dark` | 0.287516 | 0.0450 |
| `input()` | `compact.placeholder.focus-visible.dark` | 0.283458 | 0.0450 |
| `input()` | `lg.placeholder.focus-visible.dark` | 0.268404 | 0.0450 |
| `input()` | `default.value.focus-visible.dark` | 0.267782 | 0.0450 |
| `input()` | `invalid.value.focus-visible.dark` | 0.266459 | 0.0450 |
| `spinner()` | `lg.muted.rest.dark` | 0.990741 | 0.0400 |
| `spinner()` | `sm.muted.rest.dark` | 0.990556 | 0.0400 |
| `spinner()` | `xs.muted.rest.dark` | 0.990115 | 0.0400 |
| `spinner()` | `md.muted.rest.dark` | 0.985840 | 0.0400 |
| `spinner()` | `xs.current.rest.dark` | 0.974809 | 0.0400 |
| `spinner()` | `sm.current.rest.dark` | 0.965833 | 0.0400 |
| `spinner()` | `md.current.rest.dark` | 0.958008 | 0.0400 |
| `spinner()` | `lg.current.rest.dark` | 0.953897 | 0.0400 |
| `spinner()` | `lg.current.rest.light` | 0.052662 | 0.0400 |
| `spinner()` | `md.current.rest.light` | 0.044434 | 0.0400 |
| `spinner()` | `sm.current.rest.light` | 0.040556 | 0.0400 |
| `separator()` | `vertical.rest.dark` | 0.964706 | 0.0200 |
| `separator()` | `horizontal.rest.dark` | 0.948097 | 0.0200 |
| `badge()` | `secondary.count.rest.dark` | 0.979455 | 0.0950 |
| `badge()` | `info.default.rest.dark` | 0.958497 | 0.0950 |
| `badge()` | `error.default.rest.dark` | 0.957155 | 0.0950 |
| `badge()` | `warning.default.rest.dark` | 0.946639 | 0.0950 |
| `badge()` | `secondary.default.rest.dark` | 0.945641 | 0.0950 |
| `badge()` | `outline.sm.rest.dark` | 0.752056 | 0.0950 |
| `badge()` | `outline.lg.rest.dark` | 0.702961 | 0.0950 |
| `badge()` | `outline.default.rest.dark` | 0.667600 | 0.0950 |
| `badge()` | `default.default.rest.dark` | 0.667509 | 0.0950 |
| `badge()` | `success.default.rest.dark` | 0.647473 | 0.0950 |
| `badge()` | `destructive.default.rest.dark` | 0.630288 | 0.0950 |
| `badge()` | `outline.control.rest.dark` | 0.572917 | 0.0950 |
| `inputGroup()` | `ghost.search.rest.dark` | 0.992920 | 0.0350 |
| `inputGroup()` | `ghost.search.disabled.dark` | 0.991801 | 0.0350 |
| `inputGroup()` | `ghost.search.focus-visible.dark` | 0.818115 | 0.0350 |
| `inputGroup()` | `default.search-kbd.rest.dark` | 0.404826 | 0.0350 |
| `inputGroup()` | `default.search-kbd.disabled.dark` | 0.402893 | 0.0350 |
| `inputGroup()` | `default.search.rest.dark` | 0.396667 | 0.0350 |
| `inputGroup()` | `default.search.disabled.dark` | 0.395447 | 0.0350 |
| `inputGroup()` | `lg.search.rest.dark` | 0.370962 | 0.0350 |
| `inputGroup()` | `lg.search.disabled.dark` | 0.369835 | 0.0350 |
| `inputGroup()` | `default.search-kbd.focus-visible.dark` | 0.273966 | 0.0350 |
| `inputGroup()` | `default.search.focus-visible.dark` | 0.265889 | 0.0350 |
| `inputGroup()` | `lg.search.focus-visible.dark` | 0.248441 | 0.0350 |
| `inputGroup()` | `ghost.search.hover.dark` | 0.992961 | 0.0300 |
| `inputGroup()` | `default.search.hover.dark` | 0.396667 | 0.0300 |
| `textarea()` | `sm.placeholder.rest.dark` | 0.258615 | 0.0450 |
| `textarea()` | `sm.placeholder.disabled.dark` | 0.256510 | 0.0450 |
| `textarea()` | `default.placeholder.rest.dark` | 0.249700 | 0.0450 |
| `textarea()` | `default.placeholder.disabled.dark` | 0.247692 | 0.0450 |
| `textarea()` | `invalid.value.rest.dark` | 0.243974 | 0.0450 |
| `textarea()` | `invalid.value.disabled.dark` | 0.243797 | 0.0450 |
| `textarea()` | `lg.placeholder.rest.dark` | 0.241561 | 0.0450 |
| `textarea()` | `lg.placeholder.disabled.dark` | 0.239640 | 0.0450 |
| `textarea()` | `default.value.rest.dark` | 0.227512 | 0.0450 |
| `textarea()` | `default.value.disabled.dark` | 0.225939 | 0.0450 |
| `textarea()` | `sm.placeholder.focus-visible.dark` | 0.175177 | 0.0450 |
| `textarea()` | `default.placeholder.focus-visible.dark` | 0.168990 | 0.0450 |
| `textarea()` | `lg.placeholder.focus-visible.dark` | 0.163341 | 0.0450 |
| `textarea()` | `invalid.value.focus-visible.dark` | 0.161965 | 0.0450 |
| `textarea()` | `default.value.focus-visible.dark` | 0.157317 | 0.0450 |
| `kbd()` | `icon.rest.dark` | 0.994599 | 0.0500 |
| `kbd()` | `group.rest.dark` | 0.994329 | 0.0500 |
| `kbd()` | `cmd.rest.dark` | 0.992863 | 0.0500 |
| `kbd()` | `esc.rest.dark` | 0.984217 | 0.0500 |
| `kbd()` | `enter.rest.dark` | 0.977366 | 0.0500 |
| `kbd()` | `shortcut.rest.dark` | 0.976136 | 0.0500 |
| `skeleton()` | `block.rest.dark` | 0.564798 | 0.0200 |
| `skeleton()` | `pill.rest.dark` | 0.559245 | 0.0200 |
| `skeleton()` | `card.rest.dark` | 0.324996 | 0.0200 |
| `panelTabClose()` | `button-hover.hover.dark` | 0.998750 | 0.1200 |
| `panelTabClose()` | `tab.rest.dark` | 0.997344 | 0.1200 |
| `panelTabClose()` | `tab.focus-visible.dark` | 0.997344 | 0.1800 |
| `panelTabClose()` | `button-hover.rest.dark` | 0.997344 | 0.1200 |
| `panelTabClose()` | `tab.hover.dark` | 0.988750 | 0.1200 |
| `panelTabClose()` | `button-hover.focus-visible.dark` | 0.988750 | 0.1200 |
| `settings()` | `section.one-row.rest.dark` | 0.468222 | 0.0350 |
| `settings()` | `section.three-rows.rest.dark` | 0.259170 | 0.0350 |
| `numberField()` | `disabled.focus-visible.dark` | 0.452208 | 0.2800 |
| `numberField()` | `sm.input.rest.dark` | 0.436951 | 0.0350 |
| `numberField()` | `sm.input.hover.dark` | 0.436951 | 0.0350 |
| `numberField()` | `default.increment.rest.dark` | 0.413619 | 0.0350 |
| `numberField()` | `default.increment.hover.dark` | 0.413382 | 0.0350 |
| `numberField()` | `default.input.rest.dark` | 0.408736 | 0.0350 |
| `numberField()` | `default.input.hover.dark` | 0.408736 | 0.0350 |
| `numberField()` | `disabled.rest.dark` | 0.407197 | 0.0350 |
| `numberField()` | `disabled.hover.dark` | 0.407197 | 0.0350 |
| `numberField()` | `lg.input.rest.dark` | 0.389806 | 0.0350 |
| `numberField()` | `lg.input.hover.dark` | 0.389806 | 0.0350 |
| `numberField()` | `default.increment.focus-visible.dark` | 0.312826 | 0.0900 |
| `numberField()` | `sm.input.focus-visible.dark` | 0.297843 | 0.0350 |
| `numberField()` | `default.input.focus-visible.dark` | 0.278379 | 0.0350 |
| `numberField()` | `lg.input.focus-visible.dark` | 0.266800 | 0.0350 |
| `group()` | `default.separated.hover.dark` | 0.467462 | 0.0800 |
| `group()` | `default.separated.rest.dark` | 0.467095 | 0.0800 |
| `group()` | `outline.three.hover.dark` | 0.464497 | 0.0800 |
| `group()` | `outline.three.rest.dark` | 0.464368 | 0.0800 |
| `group()` | `outline.three.focus-visible.dark` | 0.433616 | 0.0800 |
| `group()` | `default.separated.focus-visible.dark` | 0.425891 | 0.0800 |
| `group()` | `outline.three.focus-visible.light` | 0.083911 | 0.0800 |
| `scrollArea()` | `faded.top.rest.dark` | 0.978604 | 0.0250 |
| `scrollArea()` | `faded.top.hover.dark` | 0.978604 | 0.0250 |
| `scrollArea()` | `faded.near-top.rest.dark` | 0.973366 | 0.0250 |
| `scrollArea()` | `faded.near-top.hover.dark` | 0.973366 | 0.0250 |
| `scrollArea()` | `plain.bottom.rest.dark` | 0.973328 | 0.0250 |
| `scrollArea()` | `plain.bottom.hover.dark` | 0.973317 | 0.0250 |
| `scrollArea()` | `faded.middle.rest.dark` | 0.973250 | 0.0250 |
| `scrollArea()` | `faded.middle.hover.dark` | 0.973233 | 0.0250 |
| `table()` | `selected.rest.dark` | 0.970926 | 0.0450 |
| `table()` | `selected.hover.dark` | 0.970909 | 0.0450 |
| `table()` | `rows.rest.dark` | 0.964743 | 0.0450 |
| `table()` | `rows.hover.dark` | 0.964726 | 0.0450 |
| `wizardSteps()` | `current-0.rest.dark` | 0.813915 | 0.0400 |
| `wizardSteps()` | `current-1.rest.dark` | 0.807595 | 0.0400 |
| `wizardSteps()` | `current-0.focus-visible.dark` | 0.789226 | 0.0400 |
| `wizardSteps()` | `current-1.focus-visible.dark` | 0.782906 | 0.0400 |
| `wizardSteps()` | `current-0.hover.dark` | 0.639016 | 0.0400 |
| `wizardSteps()` | `current-1.hover.dark` | 0.632696 | 0.0400 |
| `discoveryList()` | `two-rows.hover.dark` | 0.964992 | 0.0450 |
| `discoveryList()` | `two-rows.rest.dark` | 0.958333 | 0.0450 |
| `discoveryList()` | `two-rows.disabled.dark` | 0.956754 | 0.0450 |
| `discoveryList()` | `two-rows.focus-visible.dark` | 0.928031 | 0.0450 |
| `qrCode()` | `nightly-m1-128.rest.dark` | 0.251808 | 0.0650 |
| `qrCode()` | `alnum-h1-128.rest.dark` | 0.251760 | 0.0650 |
| `qrCode()` | `pairing-m2-132.rest.dark` | 0.245423 | 0.0650 |
| `qrCode()` | `numeric-l0-128.rest.dark` | 0.237389 | 0.0650 |
| `standalonePage()` | `error.rest.dark` | 0.717511 | 0.0450 |
| `standalonePage()` | `pairing.rest.dark` | 0.717085 | 0.0450 |
| `standalonePage()` | `brand.rest.dark` | 0.715363 | 0.0450 |
| `middleTruncate()` | `short.rest.dark` | 0.944897 | 0.1000 |
| `middleTruncate()` | `sha-long.rest.dark` | 0.934382 | 0.1000 |
| `middleTruncate()` | `branch.rest.dark` | 0.934205 | 0.1000 |
| `middleTruncate()` | `path.rest.dark` | 0.933248 | 0.1000 |
| `middleTruncate()` | `branch.rest.light` | 0.107781 | 0.1000 |
| `middleTruncate()` | `sha-long.rest.light` | 0.106611 | 0.1000 |

## DesignSystemTests.OverlaysFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|

`vImageBlurMatchesCoreImage()`: Expectation failed: worst <= 2; worst = 3.000000; limit = 2.000000

## DesignSystemTests.PopupsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `selectPopup()` | `s1.h-1.rest.dark` | 0.164226 | 0.0500 |
| `selectPopup()` | `s1.h1.rest.dark` | 0.164226 | 0.0500 |
| `selectPopup()` | `s1.h2.rest.dark` | 0.164167 | 0.0500 |
| `selectTrigger()` | `ghost.default.value.rest.dark` | 0.987995 | 0.0500 |
| `selectTrigger()` | `ghost.default.value.hover.dark` | 0.961399 | 0.0500 |
| `selectTrigger()` | `ghost.default.value.focus-visible.dark` | 0.899527 | 0.0500 |
| `selectTrigger()` | `default.sm.value.rest.dark` | 0.440630 | 0.0500 |
| `selectTrigger()` | `default.sm.value.hover.dark` | 0.440630 | 0.0500 |
| `selectTrigger()` | `default.default.placeholder.rest.dark` | 0.432219 | 0.0500 |
| `selectTrigger()` | `default.default.placeholder.hover.dark` | 0.432219 | 0.0500 |
| `selectTrigger()` | `default.default.value.open.rest.dark` | 0.411000 | 0.0500 |
| `selectTrigger()` | `default.default.value.open.hover.dark` | 0.411000 | 0.0500 |
| `selectTrigger()` | `default.default.value.rest.dark` | 0.410084 | 0.0500 |
| `selectTrigger()` | `default.default.value.hover.dark` | 0.410084 | 0.0500 |
| `selectTrigger()` | `default.lg.value.rest.dark` | 0.384237 | 0.0500 |
| `selectTrigger()` | `default.lg.value.hover.dark` | 0.384237 | 0.0500 |
| `selectTrigger()` | `default.default.placeholder.focus-visible.dark` | 0.302566 | 0.0500 |
| `selectTrigger()` | `default.sm.value.focus-visible.dark` | 0.301978 | 0.0500 |
| `selectTrigger()` | `default.default.value.focus-visible.dark` | 0.280671 | 0.0500 |
| `selectTrigger()` | `default.default.value.open.focus-visible.dark` | 0.280671 | 0.0500 |
| `selectTrigger()` | `default.lg.value.focus-visible.dark` | 0.262642 | 0.0500 |
| `selectTrigger()` | `ghost.default.value.hover.light` | 0.052379 | 0.0500 |
| `popover()` | `compact.auto.rest.dark` | 0.465698 | 0.0650 |
| `popover()` | `default.auto.rest.dark` | 0.356962 | 0.0650 |
| `popover()` | `default.md.rest.dark` | 0.230515 | 0.0650 |
| `popover()` | `compact.auto.rest.light` | 0.074870 | 0.0650 |
| `tooltip()` | `code.rest.dark` | 0.467168 | 0.0700 |
| `tooltip()` | `default.rest.dark` | 0.462021 | 0.0700 |
| `tooltip()` | `glass.rest.dark` | 0.398392 | 0.0700 |
| `comboboxPopup()` | `s1.h1.rest.dark` | 0.164226 | 0.0500 |
| `comboboxPopup()` | `s-1.h0.rest.dark` | 0.164218 | 0.0500 |
| `comboboxPopup()` | `s1.h2.rest.dark` | 0.164167 | 0.0500 |
| `menu()` | `actions.h-1.rest.dark` | 0.168411 | 0.0500 |
| `menu()` | `actions.h1.rest.dark` | 0.168377 | 0.0500 |
| `menu()` | `actions.h7.rest.dark` | 0.168371 | 0.0500 |
| `menu()` | `actions.h4.rest.dark` | 0.168364 | 0.0500 |
| `menu()` | `options.h1.rest.dark` | 0.151521 | 0.0500 |
| `menu()` | `options.h6.rest.dark` | 0.151521 | 0.0500 |
| `autocompletePopup()` | `s-1.h0.rest.dark` | 0.184598 | 0.0500 |
| `autocompletePopup()` | `s1.h1.rest.dark` | 0.184548 | 0.0500 |
| `autocompletePopup()` | `s1.h2.rest.dark` | 0.184539 | 0.0500 |

## DesignSystemTests.SidebarFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `sidebarMenuButton()` | `sm.focus-visible.dark` | 0.324642 | 0.0350 |
| `sidebarMenuButton()` | `sm.hover.dark` | 0.322428 | 0.0350 |
| `sidebarMenuButton()` | `sm.active.dark` | 0.322363 | 0.0350 |
| `sidebarMenuButton()` | `sm.rest.dark` | 0.322168 | 0.0350 |
| `sidebarMenuButton()` | `sm.disabled.dark` | 0.319987 | 0.0350 |
| `sidebarMenuButton()` | `outline.rest.dark` | 0.312119 | 0.0350 |
| `sidebarMenuButton()` | `outline.focus-visible.dark` | 0.312119 | 0.0350 |
| `sidebarMenuButton()` | `outline.disabled.dark` | 0.311310 | 0.0350 |
| `sidebarMenuButton()` | `default.focus-visible.dark` | 0.310715 | 0.0350 |
| `sidebarMenuButton()` | `selected.focus-visible.dark` | 0.309891 | 0.0350 |
| `sidebarMenuButton()` | `outline.hover.dark` | 0.308884 | 0.0350 |
| `sidebarMenuButton()` | `outline.active.dark` | 0.308746 | 0.0350 |
| `sidebarMenuButton()` | `default.rest.dark` | 0.308533 | 0.0350 |
| `sidebarMenuButton()` | `selected.rest.dark` | 0.307907 | 0.0350 |
| `sidebarMenuButton()` | `selected.hover.dark` | 0.307907 | 0.0350 |
| `sidebarMenuButton()` | `selected.active.dark` | 0.307907 | 0.0350 |
| `sidebarMenuButton()` | `default.hover.dark` | 0.307846 | 0.0350 |
| `sidebarMenuButton()` | `default.active.dark` | 0.307831 | 0.0350 |
| `sidebarMenuButton()` | `selected.disabled.dark` | 0.307022 | 0.0350 |
| `sidebarMenuButton()` | `default.disabled.dark` | 0.306595 | 0.0350 |
| `sidebarMenuButton()` | `icon.focus-visible.dark` | 0.303513 | 0.0350 |
| `sidebarMenuButton()` | `icon.rest.dark` | 0.301407 | 0.0350 |
| `sidebarMenuButton()` | `icon.disabled.dark` | 0.301376 | 0.0350 |
| `sidebarMenuButton()` | `icon.hover.dark` | 0.298172 | 0.0350 |
| `sidebarMenuButton()` | `icon.active.dark` | 0.298172 | 0.0350 |
| `sidebarMenuButton()` | `lg.focus-visible.dark` | 0.261182 | 0.0350 |
| `sidebarMenuButton()` | `lg.rest.dark` | 0.259326 | 0.0350 |
| `sidebarMenuButton()` | `lg.hover.dark` | 0.258777 | 0.0350 |
| `sidebarMenuButton()` | `lg.active.dark` | 0.258765 | 0.0350 |
| `sidebarMenuButton()` | `lg.disabled.dark` | 0.257776 | 0.0350 |
| `commandItem()` | `idle.rest.dark` | 0.992328 | 0.0400 |
| `commandItem()` | `active.rest.dark` | 0.992328 | 0.0400 |
| `commandItem()` | `idle.shortcut.rest.dark` | 0.991562 | 0.0400 |
| `commandItem()` | `active.shortcut.rest.dark` | 0.991497 | 0.0400 |
| `hueSlider()` | `h210.rest.dark` | 0.767005 | 0.0450 |
| `hueSlider()` | `h0.rest.dark` | 0.760625 | 0.0450 |
| `hueSlider()` | `h210.focus-visible.dark` | 0.266901 | 0.0450 |
| `hueSlider()` | `h0.focus-visible.dark` | 0.262292 | 0.0450 |
| `sidebarMenuSub()` | `second-active.rest.dark` | 0.230743 | 0.0350 |

## DesignSystemTests.TogglesFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `toggleGroup()` | `default.rest.dark` | 0.709230 | 0.0500 |
| `toggleGroup()` | `segmented.rest.dark` | 0.472060 | 0.0500 |
| `checkbox()` | `off.invalid.rest.dark` | 0.771240 | 0.0600 |
| `checkbox()` | `on.rest.dark` | 0.767822 | 0.0600 |
| `checkbox()` | `mixed.disabled.rest.dark` | 0.767334 | 0.0600 |
| `checkbox()` | `off.disabled.rest.dark` | 0.766846 | 0.0600 |
| `checkbox()` | `on.disabled.rest.dark` | 0.766602 | 0.0600 |
| `checkbox()` | `mixed.rest.dark` | 0.761963 | 0.0600 |
| `checkbox()` | `off.rest.dark` | 0.760986 | 0.0600 |
| `checkbox()` | `off.invalid.focus-visible.dark` | 0.642822 | 0.0600 |
| `checkbox()` | `on.focus-visible.dark` | 0.640625 | 0.0600 |
| `checkbox()` | `mixed.focus-visible.dark` | 0.638672 | 0.0600 |
| `checkbox()` | `off.focus-visible.dark` | 0.637695 | 0.0600 |
| `switchControl()` | `sm.off.focus-visible.dark` | 0.863281 | 0.0650 |
| `switchControl()` | `sm.on.focus-visible.dark` | 0.858817 | 0.0750 |
| `switchControl()` | `default.off.focus-visible.dark` | 0.840473 | 0.0650 |
| `switchControl()` | `default.on.focus-visible.dark` | 0.832481 | 0.0700 |
| `switchControl()` | `sm.on.active.dark` | 0.831659 | 0.0650 |
| `switchControl()` | `sm.off.active.dark` | 0.825893 | 0.0650 |
| `switchControl()` | `sm.on.rest.dark` | 0.814918 | 0.0650 |
| `switchControl()` | `default.on.active.dark` | 0.813459 | 0.0650 |
| `switchControl()` | `sm.off.rest.dark` | 0.810640 | 0.0650 |
| `switchControl()` | `sm.off.disabled.rest.dark` | 0.808966 | 0.0650 |
| `switchControl()` | `sm.on.disabled.rest.dark` | 0.808222 | 0.0650 |
| `switchControl()` | `default.off.active.dark` | 0.806746 | 0.0650 |
| `switchControl()` | `default.on.rest.dark` | 0.796036 | 0.0650 |
| `switchControl()` | `default.off.rest.dark` | 0.794597 | 0.0650 |
| `switchControl()` | `default.on.disabled.rest.dark` | 0.793638 | 0.0650 |
| `switchControl()` | `default.off.disabled.rest.dark` | 0.792359 | 0.0650 |
| `switchControl()` | `sm.mixed.focus-visible.dark` | 0.786830 | 0.0650 |
| `switchControl()` | `default.mixed.focus-visible.dark` | 0.744725 | 0.0650 |
| `switchControl()` | `sm.mixed.active.dark` | 0.727865 | 0.0650 |
| `switchControl()` | `sm.mixed.rest.dark` | 0.724888 | 0.0650 |
| `switchControl()` | `default.mixed.rest.dark` | 0.695332 | 0.0650 |
| `switchControl()` | `default.mixed.active.dark` | 0.695332 | 0.0650 |
| `collapsibleSectionHeader()` | `info.closed.rest.dark` | 0.988302 | 0.0350 |
| `collapsibleSectionHeader()` | `info.open.rest.dark` | 0.988281 | 0.0350 |
| `collapsibleSectionHeader()` | `muted.closed.rest.dark` | 0.981974 | 0.0350 |
| `collapsibleSectionHeader()` | `muted.open.rest.dark` | 0.981934 | 0.0350 |
| `collapsibleSectionHeader()` | `accent.closed.rest.dark` | 0.975972 | 0.0350 |
| `collapsibleSectionHeader()` | `emphasized.closed.rest.dark` | 0.975952 | 0.0350 |
| `collapsibleSectionHeader()` | `accent.open.rest.dark` | 0.975952 | 0.0350 |
| `collapsibleSectionHeader()` | `emphasized.open.rest.dark` | 0.975911 | 0.0350 |
| `collapsibleSectionHeader()` | `info.closed.focus-visible.dark` | 0.901733 | 0.0350 |
| `collapsibleSectionHeader()` | `info.open.focus-visible.dark` | 0.901713 | 0.0350 |
| `collapsibleSectionHeader()` | `muted.closed.focus-visible.dark` | 0.895406 | 0.0350 |
| `collapsibleSectionHeader()` | `muted.open.focus-visible.dark` | 0.895365 | 0.0350 |
| `collapsibleSectionHeader()` | `emphasized.closed.focus-visible.dark` | 0.889384 | 0.0350 |
| `collapsibleSectionHeader()` | `accent.open.focus-visible.dark` | 0.889384 | 0.0350 |
| `collapsibleSectionHeader()` | `emphasized.open.focus-visible.dark` | 0.889343 | 0.0350 |
| `collapsibleSectionHeader()` | `accent.closed.focus-visible.dark` | 0.889343 | 0.0350 |
| `radio()` | `on.rest.dark` | 0.811279 | 0.0750 |
| `radio()` | `on.disabled.rest.dark` | 0.802979 | 0.0750 |
| `radio()` | `off.disabled.rest.dark` | 0.800537 | 0.0750 |
| `radio()` | `off.invalid.rest.dark` | 0.799805 | 0.0750 |
| `radio()` | `off.rest.dark` | 0.794189 | 0.0750 |
| `radio()` | `on.focus-visible.dark` | 0.697266 | 0.0950 |
| `radio()` | `off.focus-visible.dark` | 0.678955 | 0.0750 |
| `radio()` | `off.invalid.focus-visible.dark` | 0.666016 | 0.0750 |
| `toggle()` | `ghost.off.disabled.dark` | 0.994967 | 0.0650 |
| `toggle()` | `pill.off.rest.dark` | 0.993359 | 0.0650 |
| `toggle()` | `pill.off.disabled.dark` | 0.990885 | 0.0650 |
| `toggle()` | `segmented.off.rest.dark` | 0.988589 | 0.0650 |
| `toggle()` | `pill.off.hover.dark` | 0.987044 | 0.0650 |
| `toggle()` | `pill.off.active.dark` | 0.987044 | 0.0650 |
| `toggle()` | `segmented.off.disabled.dark` | 0.979972 | 0.0650 |
| `toggle()` | `ghost.off.rest.dark` | 0.963483 | 0.0650 |
| `toggle()` | `ghost.off.hover.dark` | 0.962371 | 0.0650 |
| `toggle()` | `ghost.off.active.dark` | 0.962371 | 0.0650 |
| `toggle()` | `ghost.on.rest.dark` | 0.962371 | 0.0650 |
| `toggle()` | `ghost.on.hover.dark` | 0.962371 | 0.0650 |
| `toggle()` | `ghost.on.active.dark` | 0.962371 | 0.0650 |
| `toggle()` | `ghost.on.disabled.dark` | 0.962371 | 0.0650 |
| `toggle()` | `default.off.rest.dark` | 0.956580 | 0.0650 |
| `toggle()` | `default.off.hover.dark` | 0.955623 | 0.0650 |
| `toggle()` | `default.off.active.dark` | 0.955623 | 0.0650 |
| `toggle()` | `default.off.disabled.dark` | 0.952115 | 0.0650 |
| `toggle()` | `pill.off.focus-visible.dark` | 0.907031 | 0.0650 |
| `toggle()` | `segmented.off.focus-visible.dark` | 0.886316 | 0.0700 |
| `toggle()` | `ghost.off.focus-visible.dark` | 0.867158 | 0.0700 |
| `toggle()` | `ghost.on.focus-visible.dark` | 0.866866 | 0.0700 |
| `toggle()` | `default.off.focus-visible.dark` | 0.861448 | 0.0650 |
| `toggle()` | `outline.xs.rest.dark` | 0.691250 | 0.0650 |
| `toggle()` | `outline.xs.hover.dark` | 0.686250 | 0.0650 |
| `toggle()` | `outline.xs.active.dark` | 0.677031 | 0.0650 |
| `toggle()` | `outline.xs.disabled.dark` | 0.673281 | 0.0650 |
| `toggle()` | `outline.sm.active.dark` | 0.640238 | 0.0650 |
| `toggle()` | `outline.sm.rest.dark` | 0.640108 | 0.0650 |
| `toggle()` | `outline.sm.disabled.dark` | 0.639979 | 0.0650 |
| `toggle()` | `outline.sm.hover.dark` | 0.638817 | 0.0650 |
| `toggle()` | `outline.compact.active.dark` | 0.623709 | 0.0650 |
| `toggle()` | `outline.compact.rest.dark` | 0.623192 | 0.0650 |
| `toggle()` | `outline.compact.disabled.dark` | 0.622546 | 0.0650 |
| `toggle()` | `outline.compact.hover.dark` | 0.621384 | 0.0650 |
| `toggle()` | `outline.xs.focus-visible.dark` | 0.577187 | 0.0650 |
| `toggle()` | `outline.lg.active.dark` | 0.553070 | 0.0650 |
| `toggle()` | `outline.lg.rest.dark` | 0.552977 | 0.0650 |
| `toggle()` | `outline.lg.disabled.dark` | 0.552885 | 0.0650 |
| `toggle()` | `outline.lg.hover.dark` | 0.552053 | 0.0650 |
| `toggle()` | `outline.sm.focus-visible.dark` | 0.540935 | 0.0650 |
| `toggle()` | `pill.on.rest.dark` | 0.531706 | 0.0650 |
| `toggle()` | `pill.on.hover.dark` | 0.531706 | 0.0650 |
| `toggle()` | `pill.on.active.dark` | 0.531706 | 0.0650 |
| `toggle()` | `pill.on.disabled.dark` | 0.528971 | 0.0650 |
| `toggle()` | `segmented.off.hover.dark` | 0.518608 | 0.0650 |
| `toggle()` | `segmented.off.active.dark` | 0.518608 | 0.0650 |
| `toggle()` | `segmented.on.rest.dark` | 0.518513 | 0.0650 |
| `toggle()` | `segmented.on.hover.dark` | 0.518513 | 0.0650 |
| `toggle()` | `segmented.on.active.dark` | 0.518513 | 0.0650 |
| `toggle()` | `outline.compact.focus-visible.dark` | 0.512655 | 0.0650 |
| `toggle()` | `segmented.on.disabled.dark` | 0.511979 | 0.0650 |
| `toggle()` | `outline.off.active.dark` | 0.482530 | 0.0650 |
| `toggle()` | `outline.off.rest.dark` | 0.482313 | 0.0650 |
| `toggle()` | `outline.on.rest.dark` | 0.482042 | 0.0650 |
| `toggle()` | `outline.on.hover.dark` | 0.482042 | 0.0650 |
| `toggle()` | `outline.on.active.dark` | 0.482042 | 0.0650 |
| `toggle()` | `outline.off.hover.dark` | 0.481934 | 0.0650 |
| `toggle()` | `default.on.rest.dark` | 0.480442 | 0.0650 |
| `toggle()` | `default.on.hover.dark` | 0.480442 | 0.0650 |
| `toggle()` | `default.on.active.dark` | 0.480442 | 0.0650 |
| `toggle()` | `outline.off.disabled.dark` | 0.480306 | 0.0650 |
| `toggle()` | `outline.on.disabled.dark` | 0.477756 | 0.0650 |
| `toggle()` | `default.on.disabled.dark` | 0.475446 | 0.0650 |
| `toggle()` | `outline.lg.focus-visible.dark` | 0.458303 | 0.0650 |
| `toggle()` | `pill.on.focus-visible.dark` | 0.456836 | 0.0750 |
| `toggle()` | `segmented.on.focus-visible.dark` | 0.421922 | 0.0900 |
| `toggle()` | `outline.off.focus-visible.dark` | 0.391168 | 0.0650 |
| `toggle()` | `outline.on.focus-visible.dark` | 0.390354 | 0.0650 |
| `toggle()` | `default.on.focus-visible.dark` | 0.389881 | 0.0650 |
| `toggle()` | `segmented.on.focus-visible.light` | 0.095881 | 0.0800 |
| `toggle()` | `segmented.on.rest.light` | 0.080682 | 0.0650 |
| `toggle()` | `segmented.on.hover.light` | 0.080682 | 0.0650 |
| `toggle()` | `segmented.on.active.light` | 0.080682 | 0.0650 |
| `toggle()` | `segmented.off.hover.light` | 0.079072 | 0.0650 |
| `toggle()` | `segmented.off.active.light` | 0.079072 | 0.0650 |
| `toggle()` | `outline.off.focus-visible.light` | 0.071343 | 0.0650 |
| `toggle()` | `segmented.on.disabled.light` | 0.069460 | 0.0650 |
| `toggle()` | `default.off.focus-visible.light` | 0.069196 | 0.0650 |
| `alert()` | `success.rest.dark` | 0.960724 | 0.0700 |
| `alert()` | `info.rest.dark` | 0.960407 | 0.0700 |
| `alert()` | `sidebar.rest.dark` | 0.954081 | 0.0700 |
| `alert()` | `sidebar.wrap.rest.dark` | 0.943650 | 0.0800 |
| `alert()` | `default.rest.dark` | 0.264422 | 0.0700 |
| `alert()` | `warning.rest.dark` | 0.250728 | 0.0700 |
| `alert()` | `error.rest.dark` | 0.248417 | 0.0700 |
| `alert()` | `default.wrap.rest.dark` | 0.214761 | 0.0700 |
| `alert()` | `default.firstline.rest.dark` | 0.214761 | 0.0700 |
| `alert()` | `error.wrap.rest.dark` | 0.183648 | 0.0700 |
| `alert()` | `error.firstline.rest.dark` | 0.183648 | 0.0700 |
| `empty()` | `compact.rest.dark` | 0.980257 | 0.0450 |
| `empty()` | `compact.wrap.rest.dark` | 0.978540 | 0.0450 |
| `empty()` | `default.rest.dark` | 0.973850 | 0.0450 |
| `empty()` | `default.wrap.rest.dark` | 0.963026 | 0.0450 |

## FeaturesTests.BannerStackFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `bannerStack()` | `goal.rest.dark` | 0.512949 | 0.0600 |
| `bannerStack()` | `recovery.rest.dark` | 0.525139 | 0.0600 |
| `bannerStack()` | `environment.rest.dark` | 0.500870 | 0.0600 |
| `bannerStack()` | `offline.rest.dark` | 0.509945 | 0.0600 |
| `bannerStack()` | `clone-failed.rest.dark` | 0.519679 | 0.0600 |
| `bannerStack()` | `notice-dismiss.rest.dark` | 0.511927 | 0.0600 |
| `bannerStack()` | `floating.rest.dark` | 0.388814 | 0.0600 |
| `bannerStack()` | `stack-collapsed.rest.dark` | 0.445805 | 0.0600 |
| `bannerStack()` | `stack-collapsed-neutral.rest.dark` | 0.455795 | 0.0600 |
| `bannerStack()` | `stack-expanded.rest.dark` | 0.368359 | 0.0600 |
| `bannerStack()` | `goal.rest.dark` | 0.512949 | 0.0600 |
| `bannerStack()` | `recovery.rest.dark` | 0.525139 | 0.0600 |
| `bannerStack()` | `environment.rest.dark` | 0.500870 | 0.0600 |
| `bannerStack()` | `offline.rest.dark` | 0.509945 | 0.0600 |
| `bannerStack()` | `clone-failed.rest.dark` | 0.519679 | 0.0600 |
| `bannerStack()` | `notice-dismiss.rest.dark` | 0.511927 | 0.0600 |
| `bannerStack()` | `floating.rest.dark` | 0.388814 | 0.0600 |
| `bannerStack()` | `stack-collapsed.rest.dark` | 0.445805 | 0.0600 |
| `bannerStack()` | `stack-collapsed-neutral.rest.dark` | 0.455795 | 0.0600 |
| `bannerStack()` | `stack-expanded.rest.dark` | 0.368359 | 0.0600 |

## FeaturesTests.BrowserFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `browser()` | `chrome.rest.dark` | 0.990366 | 0.0750 |
| `browser()` | `empty.rest.dark` | 0.986052 | 0.0750 |
| `browser()` | `lists.rest.dark` | 0.971141 | 0.0750 |
| `browser()` | `unreachable.rest.dark` | 0.985166 | 0.0750 |
| `browser()` | `search.rest.dark` | 0.799584 | 0.0750 |

`browser()`: Expectation failed: mean < 0.05; mean = 0.485146; limit = 0.050000

## FeaturesTests.ChangedFilesFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `cardAndDiff()` | `47-changed-files-card.main.light` | 0.202595 | 0.0500 |
| `cardAndDiff()` | `48-diff-turn-file.chat.light` | 0.210645 | 0.0500 |
| `cardAndDiff()` | `47-changed-files-card.main.dark` | 0.262685 | 0.0500 |
| `cardAndDiff()` | `48-diff-turn-file.chat.dark` | 0.265519 | 0.0500 |
| `cardAndDiff()` | `48-diff-turn-file.panel.dark` | 0.895817 | 0.0500 |
| `cardAndDiff()` | `47-changed-files-card.main.light` | 0.202595 | 0.0750 |
| `cardAndDiff()` | `48-diff-turn-file.chat.light` | 0.210645 | 0.0750 |
| `cardAndDiff()` | `47-changed-files-card.main.dark` | 0.262685 | 0.0750 |
| `cardAndDiff()` | `48-diff-turn-file.chat.dark` | 0.265519 | 0.0750 |
| `cardAndDiff()` | `48-diff-turn-file.panel.dark` | 0.895817 | 0.0750 |

## FeaturesTests.ComposerAttachmentsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `composerAttachments()` | `shelf.rest.dark` | 0.591485 | 0.0700 |
| `composerAttachments()` | `stash-menu.rest.dark` | 0.322889 | 0.0700 |
| `composerAttachments()` | `stash-empty.rest.dark` | 0.418578 | 0.0700 |
| `composerAttachments()` | `stash-badge.rest.dark` | 0.590897 | 0.0700 |

`composerAttachments()`: Expectation failed: mean < 0.05; mean = 0.210624; limit = 0.050000

## FeaturesTests.ComposerFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `composer()` | `04-new-thread-draft.dark` | 0.122964 | 0.1150 |
| `composer()` | `04n-new-thread-narrow.dark` | 0.130992 | 0.1150 |

## FeaturesTests.ComposerFooterFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `composerFooter()` | `cluster.access-icon.rest.dark` | 0.987550 | 0.0600 |
| `composerFooter()` | `cluster.both-icon.rest.dark` | 0.986885 | 0.0600 |
| `composerFooter()` | `cluster.overflow-access.rest.dark` | 0.991501 | 0.0600 |
| `composerFooter()` | `cluster.overflow-both.rest.dark` | 0.998422 | 0.0600 |
| `composerFooter()` | `menu.access.rest.dark` | 0.178190 | 0.0600 |
| `composerFooter()` | `menu.traits-access.rest.dark` | 0.146080 | 0.0600 |
| `composerFooter()` | `files.question.rest.dark` | 0.984170 | 0.0600 |

`composerFooter()`: Expectation failed: mean < 0.05; mean = 0.388594; limit = 0.050000

## FeaturesTests.ComposerMenuFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `composerMenu()` | `slash.rest.dark` | 0.243384 | 0.0450 |
| `composerMenu()` | `mention.rest.dark` | 0.228386 | 0.0450 |
| `composerMenu()` | `skill.rest.dark` | 0.331500 | 0.0450 |
| `composerMenu()` | `pull-request.rest.dark` | 0.335324 | 0.0450 |
| `composerMenu()` | `empty.rest.dark` | 0.376897 | 0.0450 |
| `composerMenu()` | `chips.rest.dark` | 0.963016 | 0.1800 |

`composerMenu()`: Expectation failed: mean < 0.05; mean = 0.222240; limit = 0.050000

## FeaturesTests.ComposerRichTextFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `composerRichText()` | `marks.rest.dark` | 0.985654 | 0.0600 |
| `composerRichText()` | `nested.rest.dark` | 0.990429 | 0.0600 |
| `composerRichText()` | `code.rest.dark` | 0.962205 | 0.0600 |
| `composerRichText()` | `list.rest.dark` | 0.996276 | 0.0600 |
| `composerRichText()` | `nestedlist.rest.dark` | 0.996266 | 0.0600 |
| `composerRichText()` | `quote.rest.dark` | 0.992591 | 0.0600 |
| `composerRichText()` | `heading.rest.dark` | 0.986522 | 0.0600 |
| `composerRichText()` | `task.rest.dark` | 0.993034 | 0.0600 |

`composerRichText()`: Expectation failed: mean < 0.05; mean = 0.506338; limit = 0.050000

## FeaturesTests.ConnectionsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `connections()` | `nav.rest.dark` | 0.096579 | 0.0650 |
| `connections()` | `nav.back.rest.dark` | 0.333454 | 0.0650 |
| `connections()` | `header.rest.dark` | 0.999188 | 0.0650 |
| `connections()` | `this-machine.rest.dark` | 0.467892 | 0.0650 |
| `connections()` | `environments.empty.rest.dark` | 0.229630 | 0.0650 |
| `connections()` | `environments.rows.rest.dark` | 0.279486 | 0.0650 |
| `connections()` | `environments.routes.rest.dark` | 0.241159 | 0.0650 |
| `connections()` | `this-machine.full.rest.dark` | 0.147870 | 0.0650 |
| `connections()` | `this-machine.permissions.rest.dark` | 0.123212 | 0.0650 |
| `connections()` | `authorized-clients.rest.dark` | 0.299043 | 0.0650 |
| `connections()` | `authorized-clients.open.rest.dark` | 0.105885 | 0.0650 |
| `connections()` | `environments.permissions.rest.dark` | 0.370309 | 0.0650 |
| `connections()` | `create-link-dialog.rest.dark` | 0.897305 | 0.0650 |
| `connections()` | `add-dialog.rest.dark` | 0.786043 | 0.0650 |
| `connections()` | `add-dialog.error.rest.dark` | 0.793028 | 0.0650 |
| `connections()` | `add-dialog.ssh.rest.dark` | 0.723087 | 0.0650 |
| `connections()` | `add-dialog.ssh-error.rest.dark` | 0.748993 | 0.0650 |
| `connections()` | `add-dialog.route.rest.dark` | 0.785760 | 0.0650 |

`connections()`: Expectation failed: mean < 0.08; mean = 0.247218; limit = 0.080000

## FeaturesTests.DesktopLeftoversFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `copyAndWizardStates()` | `copied.dark` | 0.483302 | 0.0850 |
| `copyAndWizardStates()` | `copy-failed.dark` | 0.418739 | 0.0850 |
| `copyAndWizardStates()` | `progress-0.dark` | 0.812171 | 0.0850 |
| `copyAndWizardStates()` | `progress-1.dark` | 0.803569 | 0.0850 |
| `copyAndWizardStates()` | `progress-2.dark` | 0.795726 | 0.0850 |

`copyAndWizardStates()`: Expectation failed: mean < 0.04; mean = 0.350098; limit = 0.040000

## FeaturesTests.DesktopManagedFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `desktopManaged()` | `ssh.rest.dark` | 0.769786 | 0.1900 |
| `desktopManaged()` | `ssh-expired.rest.dark` | 0.732208 | 0.1900 |
| `desktopManaged()` | `relay-confirm.rest.dark` | 0.962729 | 0.0550 |
| `desktopManaged()` | `relay-checking.rest.dark` | 0.962720 | 0.0550 |
| `desktopManaged()` | `relay-waiting_for_lock.rest.dark` | 0.954230 | 0.0550 |
| `desktopManaged()` | `relay-downloading.rest.dark` | 0.937875 | 0.0550 |
| `desktopManaged()` | `relay-verifying.rest.dark` | 0.927929 | 0.0550 |
| `desktopManaged()` | `relay-installing.rest.dark` | 0.913902 | 0.0550 |
| `desktopManaged()` | `relay-validating.rest.dark` | 0.899751 | 0.0550 |
| `desktopManaged()` | `relay-activating.rest.dark` | 0.886481 | 0.0550 |

`desktopManaged()`: Expectation failed: mean < 0.06; mean = 0.475628; limit = 0.060000

## FeaturesTests.DevicePanelFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `devicePanel()` | `empty.rest.dark` | 0.981497 | 0.0300 |
| `devicePanel()` | `unavailable.rest.dark` | 0.982233 | 0.0300 |

`devicePanel()`: Expectation failed: mean < 0.05; mean = 0.494018; limit = 0.050000

## FeaturesTests.DiffFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `body()` | `modified.unified.dark` | 0.651125 | 0.0700 |
| `body()` | `added.unified.dark` | 0.404210 | 0.0700 |
| `body()` | `deleted.unified.dark` | 0.437624 | 0.0700 |
| `body()` | `wrap.unified.dark` | 0.444081 | 0.0850 |
| `body()` | `modified.split.dark` | 0.731941 | 0.0700 |
| `body()` | `added.split.dark` | 0.389047 | 0.0700 |
| `body()` | `deleted.split.dark` | 0.428956 | 0.0700 |
| `body()` | `wrap.split.dark` | 0.527188 | 0.0800 |
| `body()` | `collapsed.dark` | 0.985294 | 0.0700 |
| `panel(_:)` | `09-diff-split 09-diff-split.dark` | 0.962874 | 0.0850 |
| `panel(_:)` | `10-diff-unified 10-diff-unified.dark` | 0.962874 | 0.0850 |

## FeaturesTests.FilesFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `files()` | `tabs.rest.dark` | 0.993292 | 0.0450 |
| `files()` | `files.rest.dark` | 0.990949 | 0.0450 |
| `files()` | `file-header.rest.dark` | 0.991089 | 0.0450 |
| `files()` | `launcher.rest.dark` | 0.988995 | 0.0450 |

`files()`: Expectation failed: mean < 0.05; mean = 0.503925; limit = 0.050000

## FeaturesTests.GitFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `git()` | `strip.checkout.rest.dark` | 0.210148 | 0.0600 |
| `git()` | `strip.worktree.rest.dark` | 0.211409 | 0.0600 |
| `git()` | `card.commit.rest.dark` | 0.179923 | 0.0600 |
| `git()` | `card.push.rest.dark` | 0.183807 | 0.0600 |
| `git()` | `menu.publish.rest.dark` | 0.192350 | 0.0600 |
| `git()` | `menu.remote.rest.dark` | 0.181945 | 0.0600 |
| `git()` | `dialog.commit.rest.dark` | 0.825311 | 0.0600 |

`git()`: Expectation failed: mean < 0.05; mean = 0.166593; limit = 0.050000

## FeaturesTests.MarkdownFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `wideTables()` | `collapsed.dark` | 0.934909 | 0.0850 |
| `wideTables()` | `expanded.dark` | 0.940216 | 0.0850 |
| `markdown()` | `text.dark` | 0.975800 | 0.0550 |
| `markdown()` | `lists.dark` | 0.983756 | 0.0550 |
| `markdown()` | `quotes.dark` | 0.982713 | 0.0550 |
| `markdown()` | `table.dark` | 0.962188 | 0.0550 |
| `markdown()` | `code.dark` | 0.215019 | 0.0550 |
| `markdown()` | `rule-image.dark` | 0.994603 | 0.0550 |
| `markdown()` | `file-chips.dark` | 0.951909 | 0.0550 |

## FeaturesTests.MathFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `math()` | `01-power.dark@1x` | 0.972222 | 0.0700 |
| `math()` | `01-power.dark@2x` | 0.981692 | 0.0600 |
| `math()` | `02-scripts.dark@1x` | 0.972854 | 0.1000 |
| `math()` | `02-scripts.dark@2x` | 0.980587 | 0.0700 |
| `math()` | `03-inline-fraction.dark@1x` | 0.978030 | 0.0900 |
| `math()` | `03-inline-fraction.dark@2x` | 0.980114 | 0.0600 |
| `math()` | `04-display-fraction.dark@1x` | 0.996003 | 0.0600 |
| `math()` | `04-display-fraction.dark@2x` | 0.996767 | 0.0600 |
| `math()` | `05-square-root.dark@1x` | 0.978330 | 0.1200 |
| `math()` | `05-square-root.dark@2x` | 0.977669 | 0.0600 |
| `math()` | `06-cube-root.dark@1x` | 0.994639 | 0.0600 |
| `math()` | `06-cube-root.dark@2x` | 0.995933 | 0.0600 |
| `math()` | `07-greek.dark@1x` | 0.982592 | 0.1000 |
| `math()` | `07-greek.dark@2x` | 0.977454 | 0.0600 |
| `math()` | `08-gamma.dark@1x` | 0.967362 | 0.1100 |
| `math()` | `08-gamma.dark@2x` | 0.972317 | 0.0700 |
| `math()` | `09-display-sum.dark@1x` | 0.995542 | 0.0600 |
| `math()` | `09-display-sum.dark@2x` | 0.995918 | 0.0600 |
| `math()` | `10-inline-sum.dark@1x` | 0.962424 | 0.1300 |
| `math()` | `10-inline-sum.dark@2x` | 0.964394 | 0.0800 |
| `math()` | `11-gaussian-integral.dark@1x` | 0.991773 | 0.0600 |
| `math()` | `11-gaussian-integral.dark@2x` | 0.993570 | 0.0600 |
| `math()` | `12-inline-integral.dark@1x` | 0.964616 | 0.1600 |
| `math()` | `12-inline-integral.dark@2x` | 0.969415 | 0.1100 |
| `math()` | `13-product.dark@1x` | 0.996332 | 0.0600 |
| `math()` | `13-product.dark@2x` | 0.996164 | 0.0600 |
| `math()` | `14-limit.dark@1x` | 0.993160 | 0.0600 |
| `math()` | `14-limit.dark@2x` | 0.993673 | 0.0600 |
| `math()` | `15-energy.dark@1x` | 0.984492 | 0.1500 |
| `math()` | `15-energy.dark@2x` | 0.968717 | 0.0600 |
| `math()` | `16-relations.dark@1x` | 0.969886 | 0.1100 |
| `math()` | `16-relations.dark@2x` | 0.971875 | 0.0700 |
| `math()` | `17-delimiters.dark@1x` | 0.995788 | 0.0600 |
| `math()` | `17-delimiters.dark@2x` | 0.996643 | 0.0600 |
| `math()` | `18-matrix.dark@1x` | 0.995773 | 0.0600 |
| `math()` | `18-matrix.dark@2x` | 0.995659 | 0.0600 |
| `math()` | `19-identity-matrix.dark@1x` | 0.995107 | 0.0600 |
| `math()` | `19-identity-matrix.dark@2x` | 0.993571 | 0.0600 |
| `math()` | `20-cases.dark@1x` | 0.993448 | 0.0600 |
| `math()` | `20-cases.dark@2x` | 0.993196 | 0.0600 |
| `math()` | `21-aligned.dark@1x` | 0.996931 | 0.0600 |
| `math()` | `21-aligned.dark@2x` | 0.997593 | 0.0600 |
| `math()` | `22-text.dark@1x` | 0.965273 | 0.1300 |
| `math()` | `22-text.dark@2x` | 0.966091 | 0.0800 |
| `math()` | `23-accents.dark@1x` | 0.979408 | 0.1500 |
| `math()` | `23-accents.dark@2x` | 0.983374 | 0.1000 |
| `math()` | `24-blackboard.dark@1x` | 0.990676 | 0.1700 |
| `math()` | `24-blackboard.dark@2x` | 0.988636 | 0.1200 |
| `math()` | `25-bold.dark@1x` | 0.975723 | 0.0900 |
| `math()` | `25-bold.dark@2x` | 0.974432 | 0.0600 |
| `math()` | `26-quantifiers.dark@1x` | 0.988174 | 0.1800 |
| `math()` | `26-quantifiers.dark@2x` | 0.992008 | 0.1400 |
| `math()` | `27-binomial.dark@1x` | 0.988358 | 0.0600 |
| `math()` | `27-binomial.dark@2x` | 0.989700 | 0.0600 |
| `math()` | `28-spacing.dark@1x` | 0.988059 | 0.0900 |
| `math()` | `28-spacing.dark@2x` | 0.983918 | 0.0600 |
| `math()` | `29-divergence.dark@1x` | 0.995034 | 0.0600 |
| `math()` | `29-divergence.dark@2x` | 0.995333 | 0.0600 |
| `math()` | `30-quadratic.dark@1x` | 0.989012 | 0.0600 |
| `math()` | `30-quadratic.dark@2x` | 0.995044 | 0.0600 |
| `math()` | `31-overline.dark@1x` | 0.962216 | 0.1200 |
| `math()` | `31-overline.dark@2x` | 0.974077 | 0.0800 |
| `math()` | `32-norm.dark@1x` | 0.966162 | 0.1800 |
| `math()` | `32-norm.dark@2x` | 0.959933 | 0.0900 |
| `math()` | `33-determinant.dark@1x` | 0.970405 | 0.1200 |
| `math()` | `33-determinant.dark@2x` | 0.967912 | 0.0700 |
| `math()` | `34-euler.dark@1x` | 0.996243 | 0.0600 |
| `math()` | `34-euler.dark@2x` | 0.995361 | 0.0600 |
| `math()` | `35-set.dark@1x` | 0.980502 | 0.1700 |
| `math()` | `35-set.dark@2x` | 0.981402 | 0.1300 |
| `math()` | `36-paragraph-energy.dark@1x` | 0.985795 | 0.0600 |
| `math()` | `36-paragraph-energy.dark@2x` | 0.984066 | 0.0600 |
| `math()` | `37-paragraph-fraction.dark@1x` | 0.985841 | 0.0600 |
| `math()` | `37-paragraph-fraction.dark@2x` | 0.987640 | 0.0600 |
| `math()` | `38-paragraph-sum.dark@1x` | 0.987949 | 0.0600 |
| `math()` | `38-paragraph-sum.dark@2x` | 0.986002 | 0.0600 |

## FeaturesTests.McpFollowupsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|

`cardsAndWatch()`: Expectation failed: mean < 0.05; mean = 0.480504; limit = 0.050000

## FeaturesTests.NotificationsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `notifications()` | `thread-toast.completed.dark` | 0.168313 | 0.0500 |
| `notifications()` | `thread-toast.approval.dark` | 0.176228 | 0.0500 |
| `notifications()` | `thread-toast.failed.dark` | 0.162854 | 0.0500 |
| `notifications()` | `thread-toast.input.dark` | 0.167973 | 0.0500 |
| `notifications()` | `quit-hold-overlay.hold.light` | 0.679252 | 0.0500 |
| `notifications()` | `quit-hold-overlay.hold.dark` | 0.242225 | 0.0500 |
| `notifications()` | `quit-hold-overlay.double-click.light` | 0.666607 | 0.0500 |
| `notifications()` | `quit-hold-overlay.double-click.dark` | 0.252417 | 0.0500 |

`notifications()`: Expectation failed: mean < 0.05; mean = 0.221413; limit = 0.050000

## FeaturesTests.OnboardingSnapShotFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `recoveryAndSourceDetails()` | `connection.dark` | 0.978899 | 0.0400 |
| `recoveryAndSourceDetails()` | `settings.dark` | 0.976788 | 0.0400 |
| `recoveryAndSourceDetails()` | `details.dark` | 0.286258 | 0.0400 |

`recoveryAndSourceDetails()`: Expectation failed: mean < 0.03; mean = 0.382247; limit = 0.030000

## FeaturesTests.PanelLeftoversFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `panelLeftovers()` | `review-draft.rest.dark` | 0.521565 | 0.0600 |
| `panelLeftovers()` | `ssh-host-form.rest.dark` | 0.677339 | 0.0600 |
| `panelLeftovers()` | `review-card.rest.dark` | 0.988803 | 0.0600 |
| `panelLeftovers()` | `host-failed.rest.dark` | 0.955948 | 0.0600 |

`panelLeftovers()`: Expectation failed: mean < 0.05; mean = 0.406886; limit = 0.050000

## FeaturesTests.PickersFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `popupsAgainstReferences()` | `03c-footer-controls.dark` | 0.101960 | 0.0550 |

`popupsAgainstReferences()`: Expectation failed: total < 0.05; diff = 0.054711; limit = 0.050000; 42-access-mode-picker.dark: 5.47% differ, natural size 371.0x194.0 vs 371.0x194.0

`popupsAgainstReferences()`: Expectation failed: total < 0.05; diff = 0.101960; limit = 0.050000; 03c-footer-controls.dark: 10.20% differ, width 444.3067560195923

## FeaturesTests.ProviderSetupFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `providerSetup()` | `account.idle.rest.dark` | 0.960075 | 0.1450 |
| `providerSetup()` | `account.signed-in.rest.dark` | 0.930615 | 0.1450 |
| `providerSetup()` | `wizard.drivers.rest.dark` | 0.692794 | 0.1450 |

`providerSetup()`: Expectation failed: mean < 0.08; mean = 0.452830; limit = 0.080000

## FeaturesTests.PullRequestWritesFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `pullRequestWrites()` | `checks-popover.rest.dark` | 0.140157 | 0.1100 |
| `pullRequestWrites()` | `link-preview.rest.dark` | 0.229691 | 0.1100 |

`pullRequestWrites()`: Expectation failed: mean < 0.05; mean = 0.104617; limit = 0.050000

## FeaturesTests.PullRequestsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `pullRequests()` | `rows.rest.dark` | 0.979006 | 0.0700 |
| `pullRequests()` | `detail-header.rest.dark` | 0.915878 | 0.0700 |
| `pullRequests()` | `link-dialog.rest.dark` | 0.820436 | 0.0700 |

`pullRequests()`: Expectation failed: mean < 0.05; mean = 0.471302; limit = 0.050000

## FeaturesTests.ReferenceScreensFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `referenceScreens()` | `sidebar-collapsed.rest.dark` | 0.297648 | 0.0550 |
| `referenceScreens()` | `find.rest.dark` | 0.919021 | 0.0550 |
| `referenceScreens()` | `go-to-file.rest.dark` | 0.939677 | 0.0550 |
| `referenceScreens()` | `project-search.rest.dark` | 0.874310 | 0.0550 |
| `referenceScreens()` | `03n-narrow.dark` | 0.095648 | 0.0550 |

`referenceScreens()`: Expectation failed: mean < 0.05; mean = 0.325066; limit = 0.050000

## FeaturesTests.RunOnFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `runOn()` | `trigger.local.rest.dark` | 0.983586 | 0.0550 |
| `runOn()` | `trigger.local.hover.dark` | 0.955199 | 0.0550 |
| `runOn()` | `trigger.remote.rest.dark` | 0.977528 | 0.0550 |
| `runOn()` | `trigger.remote.hover.light` | 0.059972 | 0.0550 |
| `runOn()` | `trigger.remote.hover.dark` | 0.948897 | 0.0550 |
| `runOn()` | `locked.remote.rest.dark` | 0.977686 | 0.0550 |
| `runOn()` | `locked.remote.hover.dark` | 0.977686 | 0.0550 |
| `runOn()` | `popup.remote.rest.dark` | 0.225990 | 0.0550 |
| `runOn()` | `popup.remote.hover.dark` | 0.225990 | 0.0550 |
| `runOn()` | `strip.remote.rest.dark` | 0.206662 | 0.0550 |
| `runOn()` | `strip.remote.hover.dark` | 0.206662 | 0.0550 |

`runOn()`: Expectation failed: mean < 0.05; mean = 0.357711; limit = 0.050000

## FeaturesTests.SettingsPages2FidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `settingsPages2()` | `project.overview.rest.dark` | 0.144299 | 0.0450 |
| `settingsPages2()` | `project.actions.rest.dark` | 0.330929 | 0.0450 |
| `settingsPages2()` | `source-control.repositories.rest.dark` | 0.223886 | 0.0450 |
| `settingsPages2()` | `source-control.vcs.rest.dark` | 0.317143 | 0.0450 |
| `settingsPages2()` | `providers.list.rest.dark` | 0.964456 | 0.0450 |

`settingsPages2()`: Expectation failed: mean < 0.08; mean = 0.208914; limit = 0.080000

## FeaturesTests.SettingsPages3FidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `settingsPages3()` | `bitbucket.access.rest.dark` | 0.804650 | 0.1100 |
| `settingsPages3()` | `bitbucket.api.rest.dark` | 0.765851 | 0.1100 |
| `settingsPages3()` | `provider.environment.rest.dark` | 0.290845 | 0.1100 |
| `settingsPages3()` | `connections.load-balancing.rest.dark` | 0.125702 | 0.1100 |
| `settingsPages3()` | `provider.advisory.rest.dark` | 0.164834 | 0.1100 |

`settingsPages3()`: Expectation failed: mean < 0.08; mean = 0.234971; limit = 0.080000

## FeaturesTests.SettingsPagesFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `settingsPages()` | `nav.search.rest.dark` | 0.131124 | 0.0500 |
| `settingsPages()` | `general.behavior.rest.dark` | 0.180714 | 0.0500 |
| `settingsPages()` | `keybindings.navigation.rest.dark` | 0.226028 | 0.0500 |

`settingsPages()`: Expectation failed: mean < 0.08; mean = 0.104225; limit = 0.080000

## FeaturesTests.SettingsRuntimeFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `settingsRuntime()` | `telemetry.rest.dark` | 0.922218 | 0.1050 |
| `settingsRuntime()` | `fonts.default.rest.dark` | 0.986947 | 0.1050 |
| `settingsRuntime()` | `fonts.custom.rest.dark` | 0.959050 | 0.1050 |

`settingsRuntime()`: Expectation failed: mean < 0.08; mean = 0.513306; limit = 0.080000

## FeaturesTests.SettingsSweepFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `settingsSweepStates()` | `diff-blue-orange.rest.dark` | 0.393939 | 0.0900 |
| `settingsSweepStates()` | `diff-default.rest.dark` | 0.393939 | 0.0900 |
| `settingsSweepStates()` | `invalid-project.rest.dark` | 0.987329 | 0.0900 |
| `settingsSweepStates()` | `motion-preview.rest.dark` | 0.842611 | 0.0900 |
| `settingsSweepStates()` | `diff-blue-orange.rest.dark` | 0.393939 | 0.0750 |
| `settingsSweepStates()` | `diff-default.rest.dark` | 0.393939 | 0.0750 |
| `settingsSweepStates()` | `invalid-project.rest.dark` | 0.987329 | 0.0750 |
| `settingsSweepStates()` | `motion-preview.rest.dark` | 0.842611 | 0.0750 |

## FeaturesTests.SidebarLeftoversFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `sidebarLeftovers()` | `no-projects.rest.dark` | 0.187342 | 0.0600 |
| `sidebarLeftovers()` | `no-projects.hover.dark` | 0.188612 | 0.0600 |
| `sidebarLeftovers()` | `rename.rest.light` | 0.066641 | 0.0600 |
| `sidebarLeftovers()` | `rename.rest.dark` | 0.377333 | 0.0600 |
| `sidebarLeftovers()` | `rename.focus-visible.light` | 0.097873 | 0.0600 |
| `sidebarLeftovers()` | `rename.focus-visible.dark` | 0.378129 | 0.0600 |
| `sidebarLeftovers()` | `pill.warning.rest.dark` | 0.333708 | 0.0600 |
| `sidebarLeftovers()` | `pill.error.rest.dark` | 0.326351 | 0.0600 |
| `sidebarLeftovers()` | `hover-card.rest.light` | 0.062843 | 0.0600 |
| `sidebarLeftovers()` | `hover-card.rest.dark` | 0.173581 | 0.0700 |
| `sidebarLeftovers()` | `ghost.rest.light` | 0.062977 | 0.0600 |
| `sidebarLeftovers()` | `ghost.rest.dark` | 0.385448 | 0.0600 |
| `sidebarLeftovers()` | `ghost.many.rest.dark` | 0.380240 | 0.0600 |

`sidebarLeftovers()`: Expectation failed: mean < 0.06; mean = 0.174307; limit = 0.060000

## FeaturesTests.SidebarSearchFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `sidebarSearch()` | `result.rest.dark` | 0.303869 | 0.0600 |
| `sidebarSearch()` | `result.hover.dark` | 0.308795 | 0.0600 |
| `sidebarSearch()` | `result.highlighted.rest.dark` | 0.308594 | 0.0600 |
| `sidebarSearch()` | `result.user-match.rest.dark` | 0.294356 | 0.0600 |
| `sidebarSearch()` | `result.user-match.hover.dark` | 0.297659 | 0.0600 |
| `sidebarSearch()` | `result.agent-match.rest.dark` | 0.291542 | 0.0600 |
| `sidebarSearch()` | `draft.rest.dark` | 0.201508 | 0.0600 |
| `sidebarSearch()` | `draft.hover.dark` | 0.201454 | 0.0600 |
| `sidebarSearch()` | `draft.active.rest.dark` | 0.214415 | 0.0600 |
| `sidebarSearch()` | `status.search.rest.dark` | 0.226969 | 0.0600 |
| `sidebarSearch()` | `status.empty.rest.dark` | 0.227346 | 0.0600 |
| `sidebarSearch()` | `scope.all.rest.dark` | 0.165617 | 0.0600 |
| `sidebarSearch()` | `scope.empty.rest.dark` | 0.199277 | 0.0600 |

`sidebarSearch()`: Expectation failed: mean < 0.06; mean = 0.139728; limit = 0.060000

## FeaturesTests.SmallAreasFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `smallAreas()` | `no-active-thread.rest.dark` | 0.995364 | 0.0600 |
| `smallAreas()` | `hover-card.mismatch.rest.dark` | 0.127507 | 0.0600 |
| `smallAreas()` | `publish.bitbucket.rest.dark` | 0.980059 | 0.0600 |
| `smallAreas()` | `publish.azure-devops.rest.dark` | 0.986137 | 0.0600 |
| `smallAreas()` | `slow-requests.open.rest.dark` | 0.128388 | 0.0600 |

`smallAreas()`: Expectation failed: mean < 0.04; mean = 0.337766; limit = 0.040000

## FeaturesTests.SweepPanelsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `panelLeftovers()` | `language-filter.rest.dark` | 0.222561 | 0.0950 |
| `panelLeftovers()` | `language-empty.rest.dark` | 0.302883 | 0.0950 |

`panelLeftovers()`: Expectation failed: mean < 0.05; mean = 0.154044; limit = 0.050000

## FeaturesTests.TerminalDrawerFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `terminalDrawer()` | `split.rest.dark` | 0.983929 | 0.0350 |
| `terminalDrawer()` | `drawer.rest.dark` | 0.993123 | 0.0350 |
| `terminalDrawer()` | `empty.rest.dark` | 0.977999 | 0.0350 |

`terminalDrawer()`: Expectation failed: mean < 0.05; mean = 0.496999; limit = 0.050000

## FeaturesTests.ThemeSettingsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `themeSettings()` | `header.rest.dark` | 0.892286 | 0.0550 |
| `themeSettings()` | `cards.rest.dark` | 0.194074 | 0.0550 |
| `themeSettings()` | `editor.rest.dark` | 0.802393 | 0.0550 |

`themeSettings()`: Expectation failed: mean < 0.08; mean = 0.330092; limit = 0.080000

## FeaturesTests.ThreadCompletionFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `threadCompletionControls()` | `minimap-0.dark` | 0.971059 | 0.0600 |
| `threadCompletionControls()` | `minimap-2.dark` | 0.971059 | 0.0600 |
| `threadCompletionControls()` | `tasks-3-1.dark` | 0.521788 | 0.0600 |
| `threadCompletionControls()` | `tasks-3-3.dark` | 0.520662 | 0.0600 |
| `threadCompletionControls()` | `tasks-11-2.dark` | 0.521049 | 0.0600 |
| `threadCompletionControls()` | `inspector-file.dark` | 0.940965 | 0.0600 |
| `threadCompletionControls()` | `inspector-failed.dark` | 0.949041 | 0.0600 |

`threadCompletionControls()`: Expectation failed: mean < 0.05; mean = 0.396848; limit = 0.050000

## FeaturesTests.ThreadFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `wholePanel()` | `03a-kitchen-sink-top.light` | 0.132452 | 0.0550 |
| `wholePanel()` | `03a-kitchen-sink-top.dark` | 0.193573 | 0.0550 |
| `wholePanel()` | `03b-kitchen-sink-middle.dark` | 0.099178 | 0.0550 |
| `wholePanel()` | `03c-kitchen-sink-bottom.dark` | 0.095091 | 0.0550 |
| `wholePanel()` | `03d-kitchen-sink-commands.light` | 0.143242 | 0.0550 |
| `wholePanel()` | `03d-kitchen-sink-commands.dark` | 0.216224 | 0.0550 |

## FeaturesTests.ThreadLeftoversFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `threadControls()` | `empty.dark` | 0.387861 | 0.0650 |
| `threadControls()` | `matches.dark` | 0.380312 | 0.0650 |
| `threadControls()` | `none.dark` | 0.383906 | 0.0650 |
| `threadControls()` | `loading.dark` | 0.384675 | 0.0650 |
| `threadControls()` | `meter-0.dark` | 0.922521 | 0.0650 |
| `threadControls()` | `meter-25.dark` | 0.940987 | 0.0650 |
| `threadControls()` | `meter-95.dark` | 0.932593 | 0.0650 |

`threadControls()`: Expectation failed: mean < 0.05; mean = 0.321612; limit = 0.050000

## FeaturesTests.ThreadLineageFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `lineageBarAndSecret()` | `thread-lineage.agents.dark` | 0.964833 | 0.0550 |
| `lineageBarAndSecret()` | `thread-lineage.forks.dark` | 0.969758 | 0.0550 |
| `lineageBarAndSecret()` | `thread-lineage.expanded.dark` | 0.968671 | 0.0550 |
| `lineageBarAndSecret()` | `thread-lineage.paged.dark` | 0.980853 | 0.0550 |
| `lineageBarAndSecret()` | `subagent-bar.completed.dark` | 0.983226 | 0.0700 |
| `lineageBarAndSecret()` | `subagent-bar.failed.dark` | 0.983333 | 0.0550 |
| `lineageBarAndSecret()` | `subagent-bar.starting.dark` | 0.991723 | 0.0550 |
| `lineageBarAndSecret()` | `secret-request.pending.dark` | 0.164514 | 0.0550 |
| `lineageBarAndSecret()` | `secret-request.no-reason-error.dark` | 0.151313 | 0.0550 |
| `lineageBarAndSecret()` | `secret-request.saved.dark` | 0.988774 | 0.0550 |
| `lineageBarAndSecret()` | `secret-request.elsewhere.dark` | 0.986495 | 0.0550 |

`lineageBarAndSecret()`: Expectation failed: mean < 0.05; mean = 0.432028; limit = 0.050000

## FeaturesTests.ThreadSweepFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `threadSweepStates()` | `task-completed.dark` | 0.972497 | 0.0700 |
| `threadSweepStates()` | `task-running.dark` | 0.954542 | 0.0700 |
| `threadSweepStates()` | `task-pending.dark` | 0.978727 | 0.0700 |
| `threadSweepStates()` | `permission-stacked.dark` | 0.212726 | 0.0700 |

`threadSweepStates()`: Expectation failed: mean < 0.05; mean = 0.420812; limit = 0.050000

## FeaturesTests.ThreadViewFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `threadview()` | `card.full.rest.dark` | 0.171528 | 0.1000 |
| `threadview()` | `card.compact.rest.dark` | 0.200762 | 0.1000 |
| `threadview()` | `card.essential.rest.dark` | 0.221709 | 0.1000 |
| `threadview()` | `pr.merge.rest.dark` | 0.990708 | 0.1000 |
| `threadview()` | `chip.thread.rest.dark` | 0.943187 | 0.1000 |
| `threadview()` | `chip.terminal.rest.dark` | 0.957132 | 0.1000 |
| `threadview()` | `chip.file.rest.dark` | 0.947631 | 0.1000 |
| `threadview()` | `chip.image.rest.dark` | 0.948033 | 0.1200 |
| `threadview()` | `chip.folder.rest.dark` | 0.955207 | 0.1000 |

`threadview()`: Expectation failed: mean < 0.05; mean = 0.381249; limit = 0.050000

`threadview()`: Expectation failed: lines.allSatisfy { $0.1 < 0.08 }

## FeaturesTests.TimelineGapsFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `timelineGaps()` | `plan.save-dialog.rest.dark` | 0.802601 | 0.0750 |
| `timelineGaps()` | `plan.implement-split.rest.dark` | 0.459600 | 0.0750 |
| `timelineGaps()` | `plan.refine.rest.dark` | 0.521419 | 0.0750 |
| `timelineGaps()` | `citation.empty.rest.dark` | 0.136121 | 0.0750 |
| `timelineGaps()` | `citation.comment.rest.dark` | 0.129808 | 0.0750 |
| `timelineGaps()` | `inspector.file-change.rest.dark` | 0.952448 | 0.0750 |
| `timelineGaps()` | `inspector.web-search.rest.dark` | 0.981721 | 0.0750 |
| `timelineGaps()` | `inspector.dynamic-tool.rest.dark` | 0.999379 | 0.0750 |
| `timelineGaps()` | `inspector.checkpoint.rest.dark` | 0.903842 | 0.0750 |
| `timelineGaps()` | `inspector.fork.rest.dark` | 0.892560 | 0.0750 |
| `timelineGaps()` | `attachment.draft.rest.dark` | 0.976570 | 0.0750 |
| `timelineGaps()` | `attachment.sent.rest.dark` | 0.994303 | 0.0750 |

`timelineGaps()`: Expectation failed: mean < 0.05; mean = 0.380422; limit = 0.050000

`timelineGaps()`: Expectation failed: lines.allSatisfy { $0.1 < 0.08 }

## FeaturesTests.UsageFidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `usage()` | `header.rest.dark` | 0.798499 | 0.0950 |
| `usage()` | `chart.rest.dark` | 0.821905 | 0.0950 |
| `usage()` | `limits-banner.rest.dark` | 0.311232 | 0.0950 |
| `usage()` | `scheduled-tasks.rest.dark` | 0.243439 | 0.0950 |
| `usage()` | `task-schedule.rest.dark` | 0.677421 | 0.0950 |

`usage()`: Expectation failed: mean < 0.08; mean = 0.310520; limit = 0.080000

## FeaturesTests.WP717FidelityTests

| Test | Case | Diff | Ceiling |
|---|---|---:|---:|
| `assistantSelectionToolbar()` | `cite.dark` | 0.917029 | 0.0650 |
| `assistantSelectionToolbar()` | `shorten.light` | 0.067134 | 0.0650 |
| `assistantSelectionToolbar()` | `shorten.dark` | 0.894133 | 0.0650 |

`assistantSelectionToolbar()`: Expectation failed: mean < 0.05; mean = 0.483002; limit = 0.050000
