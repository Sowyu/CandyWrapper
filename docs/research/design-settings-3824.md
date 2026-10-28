# Settings design catch-up

This group ports the default themes from the 3669 settings pages to the 3814 route modals and settings design, then takes the settings changes in 3824. The integration branch's `b748ac6b` supplies the 3824 stylesheet. The runtime pin stays unchanged. Redesign keeps its settings tabs, navigation, layout and previous palette; Glass keeps its palette.

## Route modal

Settings and Usage retain the route underneath them. At 1100 by 780 the popup is 1020 by 700, inset 40pt. At 840 by 620 it is 792 by 572, inset 24pt. It caps at 1280 by 960, has 16pt corners, a 1pt border and the 40% black 2xl shadow. Its header is 48pt; settings navigation is 240pt wide. The close button, Escape and a press that starts and ends on the backdrop dismiss it. Selecting text inside and releasing outside does not dismiss it. Search consumes its first Escape while it has a query. Menus and nested dialogs keep their own Escape handling.

The surface takes initial focus, Tab stays inside it, and closing clears focus without returning it to the opener. Popup fade and scale run for 150ms with ease-out and a hidden scale of 0.985. The backdrop fades over 200ms. Reduce Motion skips both. The blur uses the existing ModalHost snapshot routine, taken once on open and released on close. The underlying view stays mounted. There is no modal timer or display link.

Source at 3814, unchanged in 3824:

- `apps/web/src/components/AppRouteModal.tsx:16-88`: size, border, shadow, backdrop, dismissal, initial/final focus and motion.
- `apps/web/src/routes/_chat.settings.tsx:120-143`: two columns, 48pt header and close control.
- `apps/web/src/components/usage/UsagePage.tsx:503-509`: Usage's header and close control.
- `apps/web/src/components/sidebar/mainAppLocation.ts`: the return route.
- `apps/web/src/components/ThreadRouteView.tsx`: the mounted background thread.

Native integration is in SettingsController and SidebarCommands. Settings entry points preserve a utility page underneath the modal. Redesign retains its earlier route transitions. An asynchronous composer focus request cannot take focus from an open route modal.

## Settings and Usage changes

- Grouped navigation follows SettingsSidebarNav's 16pt group gaps and 80% group labels. The modal has no thread titlebar, brand, collapse trigger or Back row. The account button keeps its 4pt padding and bottom margin (#26180, `components/clerk/T3ConnectSidebarSignIn.tsx:23-34`).
- Scope sentences use 14pt text and bordered small controls. They wrap project/environment pairs. Local inheritance indicators wait for hover or keyboard focus unless projects override the value (`settingsLayout.tsx:469-489`).
- Theme headings use 16pt semibold text, and Themes has 20pt top padding (`ThemeSettings.tsx`). Theme-circle keyboard focus uses a foreground outline 5pt inside its hit area. The existing native color picker already has no opaque inner fill, matching #22348.
- Appearance folds motion, channel artwork and persistent composer context into Advanced. Channel artwork choices follow #26138 (`AppearanceSettingsPanel.tsx:36-76,350-396`). The settings schema accepts the two fixed artwork values. Rendering those choices in the thread sidebar belongs to the sidebar group.
- Add provider leads with first-class drivers; Show more reveals fx and ACP Registry (#25753, `AddProviderInstanceDialog.tsx:75-82,463-558`). Redesign retains its existing wizard layout. Labs already has no New design toggle.
- Usage puts period controls before metric controls and omits the period on Limits. Its metric tabs retain their position (#25336, `UsagePage.tsx:394-495`). Filter chevrons stay visible at 60% opacity.

The source diffs from 3669 to 3814 were checked for AppRouteModal, AppSidebarLayout, ThreadRouteView, mainAppLocation, settingsLayout, SettingsPanels, SettingsScopeSentence, SettingsSidebarNav, SettingsFontPreviews, ProjectDefaultsSettings, AppearanceSettingsPanel, Beta/LabsSettingsPanel, SourceControlSettings, ProviderInstanceCard, ThemeSettings, ThemeEditorPanel, ThemeColorPicker and every usage component changed in the range. Existing phase 1 behavior remains in place.

## 3824 changes

The diff from 3814 to 3824 covers 18 settings/usage files. ProjectDefaultsSettings, ScheduledTasksSettings and SourceControlWritingSettings switch to a shared provider-entry helper without changing markup. ACP Registry, Add Environment, connection diagnosis, settings scope and Usage prices change state access, without visual changes.

Source Control uses a grey dot unless a provider is available and authenticated, and a secondary Not authenticated badge (#22778, `SourceControlSettings.tsx:75-109`). A new light/dark component case covers this state. Redesign retains its earlier dot and badge. The word-wrap copy drops tables (`TypographySettings.tsx:235-251`), and the default Chat page/search no longer expose Collapse composer on scroll (`SettingsPanels.tsx:1107`, `settingsSearch.ts`). Redesign keeps its previous rows and copy.

The composer group owns the new effort-display row. The scheduled 3824 catch-up owns snooze-editor and tunnel-usage behavior. SavedEnvironmentRows changes only the excluded tunnel meter/alert. Those changes are not duplicated here.

## References and checks

The nine component specs use the supplied stylesheet and source markup. `component-reference.swift` accepts an optional `viewportWidth`; existing specs keep the 900pt default, while the modal uses 1100pt and Usage uses 1100pt. This prevents wide surfaces being clipped by the capture viewport. The new modal spec isolates the shell with an empty settings navigation column; full page content has its own specs.

The modal tests also cover responsive sizes, focus and unmounting, retaining the underlying route, and stable Usage metric positions when Limits hides the period. No existing ceiling, threshold or exception changes.

The final scoped run rendered 68 component cases across nine suites. Eight suites passed. SettingsPages2FidelityTests has two remaining failures, both Repositories, against its unchanged 4.5% ceiling. The light case differs by 5.74% and the dark case by 6.35%. Their descriptions use the shared row's old color and greedy wrapping instead of full muted foreground and balanced wrapping. The shared section header also still uses its old metrics. These failures stay in place for integration.

| Suite | Before failing / cases | After failing / cases |
|---|---:|---:|
| ProviderSetupFidelityTests | 3 / 6 | 0 / 6 |
| SettingsModalFidelityTests | new | 0 / 4 |
| SettingsPages2FidelityTests | 5 / 10 | 2 / 12 |
| SettingsPages3FidelityTests | 5 / 10 | 0 / 10 |
| SettingsPagesFidelityTests | 3 / 6 | 0 / 6 |
| SettingsRuntimeFidelityTests | 3 / 6 | 0 / 6 |
| SettingsSweepFidelityTests | 4 / 8 | 0 / 8 |
| ThemeSettingsFidelityTests | 3 / 6 | 0 / 6 |
| UsageFidelityTests | 5 / 10 | 0 / 10 |

The before run uses the task's 3814-token starting point against the older component references. The after run uses 3824 markup and CSS. The Notifications case replaces the obsolete General/Behavior fixture, and Source Control adds an unauthenticated-provider case in each appearance. No existing ceiling changes.

`scripts/test --fast` passed: 2,207 Swift Testing tests and 19 XCTest tests. `scripts/test --filter RedesignBaselineTests` ran alone and passed all 80 exact light/dark captures with zero changed channels. The four modal shell cases pass at 0.82%, 0.10%, 0.76% and 0.03% differing pixels, below their fixed 2% ceiling. Responsive-frame, metric-position, initial-focus, unmounting and release checks pass. The release check drains AppKit's autorelease pool before checking the weak reference.

The isolated app build passed, and all five changed app-controller object files postdate their source edits. The final modal palette changes were checked by the package's native renders. App build output, scoped reports and baselines are under `/tmp/cw-design-settings-*.log`; `/tmp/cw-design-settings-before.json` and `after.json` record every case. Reviewed Chromium references and native modal, Usage, Source Control and settings renders offscreen. No GUI input, live server, real account or paid turn was used. Removed the isolated app build directory and exported source copy. The full combined test/performance review remains with the main session.

## Shared components needed at integration

This work leaves DesignSystem base components untouched. The primitives group needs to port `settingsLayout.tsx:232-236,486-489` in `DesignSystem/Components/SettingsViews.swift`:

- SettingsSectionView: default-theme headings become 16pt semibold, full foreground, with a 24pt line box centered in the existing 28pt header. Redesign keeps its previous metrics.
- SettingsRowView: default-theme descriptions use full muted foreground, a 672pt maximum width and balanced wrapping. Redesign keeps its previous description color and wrapping.

Default select/button geometry and the shared settings picker border/chevron styling also depend on the primitives group's port. SidebarMenuButtonView and SidebarSearchFieldView need a way to select the root palette for Settings: SettingsSidebarNav is outside `[data-app-sidebar]`, so its background is the root `--sidebar` (#111 in dark), and its labels and controls use root sidebar roles. The modal shell, search-result rows, group labels and avatar already use that context here. The shared nav buttons/search field still use the thread-sidebar context. Any resulting fidelity failures remain failures until those components are merged.

## Deferred checks

No `design/reference/` screen was changed. Whole-screen comparisons against that older directory remain for the screen-reference pass. All eight requested suites are component suites, so no case inside them was skipped. The new 3814/3824 full Settings and Usage screens can be compared after integration. No performance baseline is replaced here; the main session owns the combined diff's full review and performance run.
