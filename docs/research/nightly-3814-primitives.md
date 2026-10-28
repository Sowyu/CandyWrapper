# Nightly 3814 primitives and sidebar

Local implementation for `design-primitives`, based on `37b9350e` on `catchup-new-design`. Nothing was pushed. The runtime pin stays on 3669.

## Changes

- Shared controls use 3814's token radii while fixed control radii and circular indicators keep their dimensions. `DesignGeometry` retains the previous geometry for Redesign and Glass. Keyboard caps, select chevrons, combobox fills, checkbox/radio outlines, section headers, popup corners and the command footer match the current component markup. Radius caches refresh on theme changes.
- Sidebar rows use the status foreground roles, the new read-title hierarchy, a light selected-row edge, trailing shelf counts and the plain 24pt undo line. Empty metadata lines disappear; real branches use whole-character middle truncation, and scratch machine names remain ordinary truncated text. Branch labels leave clicks on the row. Project-folder headers use the correct 14pt label, centered content, count and status dot. Open and closed folder references were added.
- Standalone pages use the dialog surface and compact header, with CandyWrapper's own branding. Native Clerk sign-in already uses DialogView, left-aligned 20pt headings, a plain Continue button and no shimmer. Its controls receive the shared changes. Theme color picker children were already clear inside PopoverView glass, matching #22348.
- Reference generators now include the actual inset switch and hue rings, radio outlines and SSH verification copy. No original spec case or state was removed. The unchanged QR encoder can be retained with `python3 scripts/gen-layout-spec.py --skip-qr`; its existing spec still renders against the new stylesheet. This avoids the old generator's assumption that an installed bundle contains a `static encodeText` marker.

Source citations use `v0.1.4-nightly.20261028.3814` in the read-only T3 checkout:

| Area | T3 source under `apps/web/src/` |
|---|---|
| Radius and surfaces | `index.css:425-451,1115` |
| Shared controls | `components/ui/button.tsx:109`, `kbd.tsx:9`, `select.tsx:55,80`, `combobox.tsx:195`, `checkbox.tsx:6-10`, `radio-group.tsx:20-28`, `switch.tsx:14,34`, `color-picker.tsx:199` |
| Headers and command footer | `components/ui/collapsible-section-header.tsx:5-8,36-44`, `command.tsx:221` |
| Sidebar geometry (#22287) | `components/ui/sidebar.tsx:723-724` |
| Sidebar rows and folders (#21039) | `components/sidebar/SidebarThreadRow.tsx:943-1040,1308-1314,1498-1560`, `SidebarProjectFolderHeader.tsx:65-109` |
| Counts, undo and scope selection | `components/sidebar/SidebarListMarkers.tsx:123-143`, `SidebarThreadUndoNotice.tsx:26-45`, `components/Sidebar.tsx:812-827` |
| Truncation | `components/ui/middle-truncate.tsx:62-133` |
| Entry surfaces (#25281) | `components/ui/standalone-page.tsx:8-35`, `components/clerk/clerkAppearance.ts:4-43` |
| Theme picker (#22348) | `components/settings/ThemeColorPicker.tsx:160` |
| SSH copy | `components/desktop/SshPasswordPromptDialog.tsx:177,182,204-205` |

The 3669-to-3814 diffs were read for the scoped UI, sidebar, command and dialog files. Components with unchanged TSX still needed current class strings where older generators had drifted from the source.

## Fidelity results

Before counts come from [the supplied token-port inventory](nightly-3814-fidelity.md). Its shared `FormsFidelityTests.run` reporter attributes several other suites' failures to Forms. The table assigns those cases to their declared suites: 88 Forms, 26 Overlays, 6 CommandPalette and 65 Layout. The two `default.rest.dark` dialog entries belong to different components and count separately.

| Suite | Failing pixel cases before | After |
|---|---:|---:|
| DesignSystemTests.FidelityTests | 135 | 0 |
| DesignSystemTests.FormsFidelityTests | 88 | 0 |
| DesignSystemTests.PopupsFidelityTests | 41 | 0 |
| DesignSystemTests.TogglesFidelityTests | 153 | 0 |
| DesignSystemTests.SidebarFidelityTests | 39 | 0 |
| DesignSystemTests.OverlaysFidelityTests | 26 | 0 |
| DesignSystemTests.CommandPaletteFidelityTests | 6 | 0 |
| FeaturesTests.SidebarLeftoversFidelityTests | 13 | 0 |
| FeaturesTests.SidebarSearchFidelityTests | 13 | 0 |
| FeaturesTests.SidebarReuseFidelityTests | 0 | 0 |
| FeaturesTests.ConnectionsFidelityTests | 18 | 0 |
| FeaturesTests.DesktopManagedFidelityTests | 10 | 0 |
| FeaturesTests.DesktopLeftoversFidelityTests | 5 | 0 |
| FeaturesTests.OnboardingSnapShotFidelityTests | 3 | 0 |
| DesignSystemTests.LayoutFidelityTests, extra shared-component coverage | 65 | 0 |

The final scoped run compared **1,178 component pixel cases**, including 124 extra Layout cases. All pass their existing case ceilings and aggregate checks. Row reuse also passes all four light/dark card/slim comparisons. Representative regenerated control, menu, command, folder and focus PNGs were inspected offscreen.

The scoped command still exits with one failure: `OverlaysFidelityTests.vImageBlurMatchesCoreImage` reports a worst-channel difference of **3/255** against **2/255**. This is the same default dark toggle-gallery comparison recorded before the component port. The two blur implementations differ by up to 3/255 on the new colors. Their kernels and this check's ceiling remain unchanged; there is no failing reference pixel case hidden by this result.

- `scripts/test --fast`: **2,208 Swift Testing tests and 19 XCTest tests pass**, including the Glass/Redesign palette checks and the branch click regression.
- `scripts/test --skip-build --filter 'RedesignBaselineTests|SidebarReuseFidelityTests'`: **80/80 Redesign images match exactly**, with zero changed channels; row reuse passes. This used the final build.
- Final logs: `/tmp/design-primitives-after-final.log`, `/tmp/design-primitives-fast-final2.log`, `/tmp/design-primitives-final-guards.log`.
- No ceiling, threshold or exception was raised or added. The existing SSH ceiling entries remain unchanged.

## Deferred checks

The old screen references were deliberately skipped: `DesignSystemTests.SidebarFidelityTests.sidebarGrainAgainstCapture`, `selectedRowFillAgainstCapture`, and `FeaturesTests.SidebarFidelityTests.wholeSidebar`. They still use `design/reference/02-sidebar-populated.*.png`; the integration pass must use the new 3814 screen captures. No screen reference was changed here.

All visual review was offscreen as requested. No GUI interaction, real sign-in, app launch or release occurred. The full cross-group suite and performance review remain integration work.

## Implementation commits

- `a130605f` `fix(design): port 3814 shared controls (#24865)`
- `0a4a454e` `fix(sidebar): match 3814 rows and project folders (#21039)`
- `f8aa6bce` `fix(dialogs): refresh 3814 entry surfaces (#25281)`
- `45291b3d` `fix(design): match 3814 inset focus states`
