# Hover and focus reveals, 2026-10-11

Every place T3 shows, hides or swaps something on hover or focus, and how CandyWrapper matches it. T3 paths are relative to `/Users/mrm/CandyWrapper-research/t3code/apps/web/src`. Swift paths are relative to `Packages/CandyKit/Sources` unless they start with `App/`.

## Rules T3 follows

- `transition-opacity` with no `duration-*` fades 150 ms on `cubic-bezier(.4,0,.2,1)`. Without `transition-opacity` the reveal flips at once. Visibility flips (`hidden`, `block`, `static`, `absolute`, `pointer-events-*`) never animate, so layout moves at once while the opacity fades.
- The scope is the ancestor that carries `group` or `group/<name>`. It is often an inner element, not the whole timeline or list row.
- `group-any-hover` (`index.css:9-15`) is hover on a device with any hovering pointer. On a Mac it is plain hover.
- `pointer-coarse:` fallbacks show the control all the time on touch screens. A Mac has a fine pointer, so none of them apply. They are listed only so nobody ports them.
- `focus-within` in Chromium also turns on after a mouse click focuses a button, and clears on the next click anywhere. CandyWrapper follows keyboard focus only (`FocusWithinObserver`, fed by `ControlView` when `focusVisible` flips). AppKit gives no event for "the next click anywhere", and pinning a reveal until the next focus change read as a stuck hover.

## How CandyWrapper does it

`DesignSystem/Base/HoverReveal.swift` holds the shared pieces:

- `HoverReveal.fade(_:visible:duration:hides:)` fades `alphaValue` from the presentation value. With `hides` it also sets `isHidden` at the end, which stands in for `pointer-events-none`.
- `HoverReveal.fade(_:to:)` fades to a partial value such as `opacity-40` or `opacity-70`.
- `HoverReveal.withoutAnimation` and `snap` set the resting value with no fade when a recycled row shows another item.
- `FocusWithinObserver` is the protocol for `group-focus-within`.
- `HoverGroup` adds hover to a plain view that has no tracking of its own.

All fades snap under Reduce Motion and when the view has no window. Nothing runs after a fade ends. `TimelineRowView` gained `tracksPointerMoves`, `pointer` and `focusWithin` for reveals scoped to part of a row.

## Inventory

Status after this pass: M matches, F fixed in this pass, D still differs, X missing in CandyWrapper, n/a not a visibility reveal on a Mac.

| # | T3 element | Group scope | Timing | T3 source | CandyWrapper | St |
|---|---|---|---|---|---|---|
| 1 | Work log timestamp | each work line, `group/timeline-row` on `WorkLogButton` or `WorkLogRow`, its open detail included | instant, focus-within too | `chat/MessagesTimeline.tsx:2658-2695`, `chat/WorkLog.tsx:78` | `Features/Thread/TimelineWorkRows.swift` `WorkRowView.hoverChanged` picks the hovered entry from the pointer. It showed every line's time before. | F |
| 2 | Work group header timestamp | the header row | instant | `chat/MessagesTimeline.tsx:4145` | `WorkToggleRowView.hoverChanged` | M |
| 3 | Live activity and thinking rows | none, they have no timestamp | none | `chat/MessagesTimeline.tsx:3811-3848` | `WorkRowBase` no longer reveals a time on them | F |
| 4 | Failed error row timestamp | always visible (`alwaysVisible`) | none | `chat/MessagesTimeline.tsx:5445-5449` | `pinnedTime` in `WorkRowView` | M |
| 5 | Turn fold timestamp | the fold row, `group/timeline-row` | instant | `chat/MessagesTimeline.tsx:2703-2718` | `Features/Thread/TimelineFoldRows.swift:55-60` | M |
| 6 | User message time, copy, edit-from-here | the bubble column, `group` on `flex flex-col items-end`, not the row's `pb-4` | 200 ms, focus-within | `chat/MessagesTimeline.tsx:2359,2521` | `Features/Thread/TimelineMessageRows.swift` `UserMessageRowView.hoverChanged` now excludes the bottom 16 pt and keeps it while a button has keyboard focus | F |
| 7 | Assistant meta (status, copy, fork, time) | the whole row, `group/assistant` on the row wrapper | 200 ms, focus-within | `chat/MessagesTimeline.tsx:2032-2035,2876-2883` | `AssistantMessageRowView.hoverChanged`, focus-within added | F |
| 8 | Standalone assistant meta row | always visible | none | `chat/MessagesTimeline.tsx:2841-2858` | `AssistantMetaRowView` | M |
| 9 | HTML render "Open in panel" | the frame box, `group/html-render`, not the row's `pb-2` | 150 ms, focus-within | `chat/HtmlRenderFrame.tsx:95,104` | `Features/Thread/TimelineWebRows.swift` `HtmlRenderRowView.hoverChanged` scoped to the box | F |
| 10 | Minimap gutter without a persistent gutter | the minimap | 150 ms | `chat/MessagesTimeline.tsx:1788-1792` | `Features/Thread/ThreadMinimapView.swift` `updateGutter` fades it. It drew nothing until hover before. | F |
| 11 | Minimap previous and next arrows | each arrow alone (`hover:` on the arrow) | 150 ms | `chat/MessagesTimeline.tsx:1969-1975` | `ThreadMinimapView.hoveredArrow`. Both arrows showed on strip hover before. Variant still `.ghost`, T3 uses `ghost-muted` `icon-micro`. | F, D |
| 12 | Thread title chevron | the title button, `group/thread-title` | 150 ms, focus-visible | `chat/ChatHeader.tsx:331,341` | `Features/Thread/ThreadHeaderTitleView.swift` fades it. The title is not focusable in CandyWrapper. | F |
| 13 | Sidebar card row status label and Settle, Snooze | the row, `group-any-hover/sidebar-row`; actions also on focus inside the slot or an open snooze menu | 150 ms cross-fade, slot width flips at once | `Sidebar.tsx:2016-2029,2085-2096` | `Features/Sidebar/SidebarRowViews.swift` `SidebarCardRowView.refresh` | F |
| 14 | Sidebar slim row time label | the row | 150 ms | `Sidebar.tsx:1855-1860` | `SidebarSlimRowView.refresh` | F |
| 15 | Sidebar slim row Settle, Un-settle, Wake | the row | 150 ms | `Sidebar.tsx:1903,1920,1937` | `SidebarSlimRowView.refresh` | F |
| 16 | Sidebar slim row favicon dim and grayscale | the row, hover or focus-within | opacity 150 ms, grayscale instant | `Sidebar.tsx:1825-1830` | `SidebarSlimRowView.refresh` | F |
| 17 | Sidebar receding working row | the row, hover or focus-within | `opacity-70` 150 ms | `Sidebar.tsx:1596-1598` | `SidebarCardRowView.refresh` | F |
| 18 | Sidebar slim row title color | the row, hover or focus-within | instant (only `transition-opacity`) | `Sidebar.tsx:1668,1682` | `SidebarSlimRowView.refresh` | M |
| 19 | Sidebar draft row "Discard draft" | the row | 150 ms | `Sidebar.tsx:908,933` | `Features/Sidebar/SidebarSearchRowViews.swift` `SidebarDraftRowView.refresh` | F |
| 20 | Unpin glyph swap (pin to pin-off) | the button, `group/unpin` | instant | `Sidebar.tsx:1765-1777` | `PinButton.restyle` | M |
| 21 | Sidebar row actions on row keyboard focus | T3 reveals them only for focus on the action itself | | `Sidebar.tsx:2094` | CandyWrapper's list owns focus, so `isKeyboardFocused` on the row stands in. Kept on purpose: the buttons are not reachable by Tab. | D |
| 22 | Right panel tab close swap | the tab, `group/tab`; focus-visible on the button | instant | `ui/panel-tab-close-button.tsx:26-29`, `RightPanelTabs.tsx:1140` | `DesignSystem/Components/PanelTabCloseButton.swift` | M |
| 23 | Thread details PR watch eye swap | the button, `group/watch` | instant | `chat/ThreadDetailsPrRow.tsx:361-375` | `Features/PullRequests/PullRequestWatchToggle.swift:42-43` | M |
| 24 | Thread relationship arrow | the row, `group` on the `li` | 150 ms | `chat/ThreadRelationshipsControl.tsx:446,466` | `Features/Git/ThreadLineageSectionView.swift` `hoverChanged` | M |
| 25 | Relationship Stop replacing the elapsed time | the row, hover or focus-within | instant, no transition on either | `chat/ThreadRelationshipsControl.tsx:392-394,452-458,546` | `ThreadLineageSectionView.hoverChanged`. It faded 150 ms before. | F |
| 26 | Address bar "Open in browser" | the address field, `group/address`; hidden while the field has focus | 150 ms, focus-within | `preview/PreviewChromeRow.tsx:177,210-213` | `Features/Browser/BrowserPanelView.swift` layout | F |
| 27 | Preview recent URL remove | the card, `group` | instant | `preview/PreviewRecentUrlCard.tsx:26,47` | `BrowserPanelView.RecentRow` | M |
| 28 | Floating preview dot and pill | the player, `group`; also focus-within and an open pill | 150 ms cross-fade | `preview/ThreadPreviewMiniPlayer.tsx:492,503` | `Features/Browser/BrowserMiniPlayerView.swift` `restyleHover`. The pill faded on a linear curve and the dot on Core Animation's implicit 250 ms before. | F |
| 29 | Keybinding row menu | the row, `group/row`; focus-within; open menu | 150 ms | `settings/KeybindingsSettings.tsx:989,1003` | `Features/Settings/KeybindingsSettingsView.swift` `updateMenu` | F |
| 30 | Project action edit button | the row, `group`; focus-within | instant | `settings/ProjectActionsList.tsx:59-62` | `Features/Settings/ProjectSettingsView.swift` `ProjectActionRowView`; focus-within and the `ghost-muted` variant added | F |
| 31 | Provider instance card dim | the card, `group` | `opacity-60` 150 ms | `settings/ProviderInstanceCard.tsx:914-922` | `Features/Settings/ProvidersSettingsView.swift` `restyle` | F |
| 32 | Combobox and select clear, trigger | the button itself | `opacity-80` to 100, 150 ms | `ui/combobox.tsx:86,98` | `DesignSystem/Components/ComboboxView.swift` `ComboboxTriggerView.restyle` | F |
| 33 | Autocomplete clear and trigger | the button itself | opacity snaps (`transition-colors` only) | `ui/autocomplete.tsx:55,67,212` | no autocomplete clear button found | n/a |
| 34 | Usage environment and provider chevrons | the trigger, `group/usage-*`; focus-visible; open menu | 150 ms | `usage/UsagePage.tsx:1277,1287,1398,1401` | `Features/Usage/UsagePageView.swift` `restyle` | F |
| 35 | Diff comment delete | the comment, `group/comment`; focus-within | 150 ms | `diffs/DiffCommentAnnotation.tsx:63,70` | `Features/Diff/DiffReviewAnnotationView.swift` `DiffReviewCommentCardView` | F |
| 36 | Pull request edit pencil (comment, description) | the card `article.group`, the description `div.group`; focus-within | 150 ms | `pullRequest/PullRequestEditButton.tsx:17`, `PullRequestSummaryTab.tsx:215,827` | `Features/PullRequests/PullRequestTabs.swift` `CommentCard`, `PullRequestDescriptionItem`. They were always visible. | F |
| 37 | Pull request edit pencil in the timeline tab, detail panel and review annotations | as 36 | 150 ms | `pullRequest/PullRequestTimelineTab.tsx:236`, `PullRequestDetailPanel.tsx:2396`, `PullRequestReviewAnnotation.tsx:295` | not checked in this pass | D |
| 38 | Thread pull request row actions | the row, `group/pr-row`; open menu; focus-visible | instant | `pullRequest/ThreadPullRequestsPanel.tsx:253-263` | `Features/PullRequests/ThreadPullRequestsView.swift` has no row action menu | X |
| 39 | Project scripts shortcut yielding to the edit button | the menu item, `group` | 150 ms cross-fade | `ProjectScriptsControl.tsx:214-219` | `App/Sources/ProjectScriptsController.swift` menu items have no edit button | X |
| 40 | Composer snap-shot attachment remove | the attachment, `group/attachment`; focus-within | 150 ms | `chat/ChatComposer.tsx:7103,7198-7203` | the composer belongs to another agent today; not checked | D |
| 41 | Text color on group hover (settings headers, telemetry, PR timeline title, subagent glyph, connections chip, toast link underline, changed files tree) | various | `transition-colors` 150 ms or none | `settings/SettingsPanels.tsx:2122`, `settings/ResourceTelemetryDiagnostics.tsx:253`, `pullRequest/PullRequestTimelineTab.tsx:389`, `chat/V2LifecycleRow.tsx:487`, `settings/ConnectionsSettings.tsx:2907`, `ui/toast.tsx:242`, `chat/ChangedFilesTree.tsx:237` | color, not visibility; item 33 of the motion inventory | n/a |
| 42 | Composer surface `group-has` states, theme check marks, scrollbar thumb, resize handles | not hover reveals | | `chat/ComposerSurface.tsx`, `settings/ThemeSettings.tsx:1005`, `terminal/ghostty/surface.ts:704`, `preview/RightPanelResizeHandle.tsx:30` | out of scope | n/a |
| 43 | Legacy sidebar reveals | `group/sidebar-row` | 150 ms | `LegacySidebar.tsx` (20 uses), behind `useLegacySidebarEnabled` | CandyWrapper has no legacy sidebar | n/a |
| 44 | `pointer-coarse:` fallbacks | | | 23 uses across `ui/`, `chat/`, `settings/` | a Mac pointer is fine, none apply | n/a |

## Left open

- Item 21: T3 reveals sidebar row actions only when the pointer is over the row or an action has focus. CandyWrapper also reveals them on the row's keyboard focus, because its list owns focus and the buttons are not in the Tab order.
- Items 37 to 40 need either the feature itself (38, 39) or a pass by the owner of that area (37, 40).
- Work rows keep no focus-within. CandyWrapper's work lines are not focusable, so there is nothing to follow.
- A pointer that stays still while a work group scrolls under it keeps the old line's time until the pointer moves. The control-feel pass re-hit-tests hover after scroll, and `WorkRowView.hoverChanged` reads the pointer on every call, so it picks the right line once that lands.
