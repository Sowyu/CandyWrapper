# T3 Code Mobile iPad design (2994)

Paths are relative to apps/mobile in the 2994 source (/tmp/t3code-2994).

The iPad layout is a UIKit split view with native tabs, built from a patched `react-native-screens` (`Split.Host`, `Split.Column`, `Split.Inspector`, `Tabs.Host`). It is not custom React layout. `modules/t3-native-controls` does not wrap menus, pickers or glass buttons, so every control below comes from other libraries. I read these paths and did not run anything. Paths are relative to `/tmp/t3code-2994/apps/mobile`.

## 1. Overall structure at iPad width

- The native split path is on when `Platform.isPad` and the native module reports `RNSSplitHostComponentView` (`src/native/NativeWorkspaceColumns.ios.tsx:9-10`, `modules/t3-native-controls/ios/T3NativeControlsModule.swift:14-20`). The JS flex row in `AdaptiveWorkspaceLayout.tsx:167-249` is only the non-native fallback.
- Split view is used when width >= 720 and height >= 600 (`src/lib/layout.ts:16-17,110`). Below that it is a compact layout: a bottom UIKit tab bar, with tabs `text.bubble` and a pull-request icon (`WorkspaceNativeTabs.ios.tsx:62-72,89-100`).
- Structure is a `Split.Host` with three slots (`createWorkspaceStackNavigator.ios.tsx:184-283`):
  - `Split.Column` 1 is the sidebar, a nav stack with one root screen.
  - `Split.Column` 2 is the detail, a nav stack. It starts with a "workspace-empty" screen, then Thread, Terminal, Review, Files and PR routes are pushed on it.
  - `Split.Inspector` is the third pane, with its header hidden (`Split.HeaderConfig hidden`). It shows Git, Files or the review file list.
- Host props:
  - `preferredSplitBehavior="tile"`
  - `displayModeButtonVisibility="never"` (the app draws its own sidebar toggle)
  - `presentsWithGesture`
  - `showInspector={inspector.visible}` (`:187-197`)
- Display mode is `oneBesideSecondary` when the sidebar is visible or no detail is open, otherwise `secondaryOnly` (`:189-191`). In `secondaryOnly` the sidebar is hidden and the detail fills the window.
- Column metrics (`:198-203`):
  - Sidebar minimum is 280. Its maximum is `max(380, listPaneWidth)`. Its preferred width is `listPaneWidth ?? 320`.
  - `listPaneWidth = clamp(round(windowWidth*0.32), 280, 380)` (`layout.ts:131-133`).
  - The detail column's minimum width is 320.
  - No inspector width is set on the native path, so UIKit decides it.
  - The JS fallback inspector is 260-480 wide. Its default is `clamp(28% of content, 260, 320)`, and it needs content >= 960 or a viewport >= 820 (`layout.ts:22,48-52,191-194,224`).
- The sidebar is always visible on the home route (`AdaptiveWorkspaceLayout.tsx:251`). On other routes the toggle button hides and shows it. Pane animation is 260 ms, cubic in-out (`workspace-pane-animation.ts`). On the native path UIKit animates it.
- Sidebar column header (`WorkspaceRootScreen.tsx:99-148`, `WorkspaceToolbar.ios.tsx:57-124`):
  - Title is the brand lockup: T3 wordmark 15pt tall, "Code" at 21pt `DMSans-Medium` muted with -0.5 tracking, and a stage chip at 9pt bold uppercase in a `bg-subtle` pill (`CompactBrandTitle.tsx:34-67`).
  - The title slot also shows a connection status, debounced 800 ms and faded in over 250 ms (`WorkspaceConnectionTitle.tsx:24-25`). Tapping it opens the environments settings sheet.
  - Right items are `gearshape` ("Settings", opens a sheet) and `magnifyingglass` ("Search threads" or "Search pull requests").
  - Bottom toolbar has a flexible spacer and a `square.and.pencil` "New chat" button with its own glass background (`WorkspaceToolbar.ios.tsx:113-124`).
  - Under the nav bar sits a segmented control, "Threads | Pull requests" (see section 5).
- Detail header for a thread (`useThreadHeaderOptions.tsx:31-89,142-173`):
  - Left: an 18pt spacer, then the sidebar toggle. The toggle is `arrow.up.left.and.arrow.down.right` ("Maximize content") when the sidebar is visible and `sidebar.left` ("Show thread sidebar") when hidden. Then `square.and.pencil` "New task".
  - Title is the thread title at 17pt weight 800, with a subtitle of "project · environment" (`ThreadRouteScreen.tsx:441-446`).
  - Right items, in order Files, Git, Terminal (`ThreadGitControls.tsx:444-450`):
    - `folder` is a plain button.
    - `point.topleft.down.curvedto.point.bottomright.up` opens the Git menu.
    - `terminal` opens a menu.
    - All three are plain-variant glass header items.
- Empty detail (`createWorkspaceStackNavigator.ios.tsx:219-262`, `WorkspaceEmptyDetail.tsx:39-62`):
  - Left button `sidebar.left`.
  - 34pt `sidebar.left` hierarchical icon, "Select a thread" at 21pt bold, and "Choose a thread from the sidebar or start a new task." at 16pt muted.
  - Pill button "New Task" in the primary color.
- Other chrome:
  - Header preset (`Stack.tsx:158-166`): large title off, shadow hidden, transparent glass header with scroll-edge effects, nav item style `editor` (leading-aligned title), back button minimal, title 18pt weight 800.
  - Command palette (Cmd+K): modal `GlassSurface`, width `min(600, w-32)`, height `min(520, h-80)`, radius 20 (`CommandPalette.tsx:432-441`). Its search field is 38pt tall with placeholder "Search commands, projects, and threads…".
  - Hardware shortcuts (`T3KeyboardCommandsModule.swift:36-72`):
    - Cmd+N new task, Cmd+F find, Cmd+K palette, Cmd+[ back
    - Cmd+\ toggle sidebar
    - Cmd+Shift+F, T and R open files, terminal and review
    - Cmd+Shift+C copies the thread reference
    - Cmd+Shift+H next machine
    - Cmd+1..9 jump to thread (iPad only)

## 2. Sidebar

- Data flow: `HomeRouteScreen` renders `HomeScreen` inside the primary column (`HomeRouteScreen.tsx:210-316`). Rows use `pane="sidebar"` (`HomeScreen.tsx:774`). `HomeHeader` returns null because the workspace toolbar owns the chrome (`HomeHeader.tsx:60`).
- Background is `--color-drawer` (`#fafafa` light, `#000` dark) (`HomeScreen.tsx:253,278`). The list has 8pt side padding (`:1097-1098`).
- Top segmented picker "Threads | Pull requests" is only shown when `layout.usesSplitView` (`useSystemWorkspaceTabBar.ts:4-12`, `WorkspaceSidebarTabs.ios.tsx:15-35`). Its container is `px-4 pb-3 pt-2`.
- Search is a native `UISearchController` bar, "stacked" under the nav bar, hidden until the magnifier or Cmd+F (`WorkspaceToolbar.ios.tsx:62-90`):
  - Placeholder "Search threads" or "Search pull requests".
  - Cancel button text "✕".
  - The query is stored in workspace tab state. Matching threads show a search-match excerpt under the title.
- List order (`threadListV2.ts:~479` doc comment, `:801-840`):
  - Pinned block first, with no header. Pinned rows show a `pin` glyph.
  - Then active threads, then pending or draft tasks.
  - Then a "Working" shelf (a beta feature), then "Snoozed", then "Settled".
  - Settled shows the first 10 rows, then pages of 25 (`threadListV2.ts:~161-162`), with a dashed-border "Show more" row (`thread-list-v2-items.tsx:288`).
- Section header (`thread-list-v2-items.tsx:145-215`):
  - 13pt `DMSans-Medium` label in `drawer-foreground-muted`, plus a 1px rule (`drawer-border`) and a `chevron.down` at 10pt that rotates 180 degrees when expanded.
  - Padding is `px-3 mt-4 mb-1.5`.
  - A collapsed shelf reads "Settled (12)".
- Card row anatomy for active threads (`thread-list-v2-items.tsx:972-1180`):
  - Line 1: project favicon at 15, project title at 14pt medium muted (flex), a queued-message icon, `pin` at 11, then either a status label or the time.
    - The status label is an icon (13, semibold) plus 13pt bold text.
    - The time is 13pt tabular, like "<1m", "5m", "3h", "2d" (`src/lib/time.ts:1-20`).
  - Line 2: title at 16pt `DMSans-Medium`, up to 2 lines. Background work uses regular weight.
  - Line 3 (13pt):
    - Mono branch (Menlo), then " · ", then the environment label and a machine icon at 11.
    - A failed or limited thread shows `runtime.lastError` here instead, in danger or warning color.
    - On the right: a PR chip (icon at 12, mono label) and the provider icon stack (previous owners at 12 and 30% opacity, current at 14).
  - Status labels (`:67-117`):
    - Approval: `exclamationmark.shield`, warning color.
    - Input: `questionmark.bubble`, indigo.
    - Working: `circle.dashed`, sky.
    - Waiting: `clock`, muted.
    - Failed: `exclamationmark.circle`, danger.
    - Limited: `exclamationmark.circle`, warning.
    - Done: `checkmark.circle`, emerald (unread completion only).
    - Ready has no label.
  - Receded rows (`shouldRecedeThreadRow`) render at 0.55 opacity (`:1184-1186`).
- Row container (`thread-list-v2-row-appearance.ts:25-53`): radius 12, padding 12 horizontal and 10 vertical. Idle background is `drawer`. Selected is `--color-thread-selected` (`#fff` light, `#1a1b1b` dark) with text `thread-selected-foreground`. Hover is `thread-hover` (`#fcfcfc` / `#131313`) and is hidden when selected.
- Slim row (settled and snoozed) (`thread-list-v2-items.tsx:1240-1300`):
  - Min height 44, `px-3 py-2`, gap 10.
  - Favicon at 40% opacity, 16pt single-line title in muted color, then a mono 14pt time.
  - A snoozed row shows the wake countdown instead of the time.
- Swipe left (`home/thread-swipe-actions.tsx:46-54`, `thread-list-v2-items.tsx:910-960`):
  - Actions are 58pt wide, with a 36pt circle and a 15pt icon.
  - Card rows: "Settle" (`checkmark`) plus "Snooze" (`clock`, which opens a preset menu titled "Snooze until").
  - Slim rows: "Un-settle" (`arrow.uturn.backward`).
  - Snoozed rows: "Wake" (`clock`).
  - Older servers: "Archive" (`archivebox`).
  - A full swipe runs the primary action. Spring: damping 26, mass 0.7, stiffness 330.
  - Only one row is open at a time.
- Long-press menu (`@react-native-menu/menu`, `thread-list-v2-items.tsx:119-143,721-850`):
  - Settle or Un-settle or Wake thread or Archive.
  - Arrange threads…: Move up (`arrow.up`), Move down (`arrow.down`), Pin or Unpin (`pin`, `pin.slash`).
  - Rename (`square.and.pencil`), regenerate title, auto-settle options, snooze presets.
  - New thread on branch, Copy thread ID (`doc.on.doc`), and Delete (`trash`, destructive).
- Filter menu: it exists, but the iPad toolbar does not show it (`HomeHeader.tsx:60`). The data lives in `home/home-list-filter-menu.ts`: "Environment" and "Project" submenus with "All environments" / "All projects".
- New thread button is the bottom-toolbar `square.and.pencil` (`WorkspaceToolbar.ios.tsx:115-122`), opening the NewTask sheet. The per-project and per-branch "new thread" entries are context actions.

## 3. Thread screen

- Header is described in section 1. The glass header sits over the feed with a scroll-edge effect: `soft`, or `automatic` on iOS 27+ (`HomeScreen.tsx:245-247`). Header bar buttons use `sharesBackground: true` and `variant: "plain"` (`native-glass-header-items.ts:17-34`).
- Feed (`ThreadFeed.tsx:3156-3260`) uses `KeyboardAwareLegendList` (LegendList):
  - `maintainScrollAtEnd` on data change, item layout and layout (unless a disclosure is settling).
  - `keyboardDismissMode="none"`, `keyboardLiftBehavior="whenAtEnd"`, `drawDistance=500`.
  - Content insets are automatic from UIKit, with the bottom inset coming from the composer.
- Widths:
  - Max content width is 960, centered, with a minimum side padding of 20 (`ThreadDetailScreen.tsx:846`, `layout.ts:23`, `ThreadFeed.tsx:2296-2306`).
  - If the window is wider, the padding grows by `(viewport - 960)/2`.
  - User bubble max width is 85% of the content width.
- Background is `--color-screen` (`#fcfcfc` / `#0a0a0a`). Fonts are DMSans (Regular, Medium, Bold) (`global.css:17-19`).
- User message (`ThreadFeed.tsx:1741-1760`):
  - Right-aligned bubble, radius 20, `px-3.5 py-2.5` (14/10), gap 8, `mb-5`.
  - Fill is `--color-user-bubble` (`#efeff1` light, `#161616` dark).
  - Images in the bubble have radius 14.
  - Optional attribution above it ("Sent by automation", "Sent by T3 Code") at 12pt, 60% opacity.
  - Fades in upward over 220 ms if fresh.
  - Footer row: timestamp at 13pt medium tabular, an intent badge (queued is amber, otherwise sky), edit `pencil` for pending sends, and a copy button.
- Assistant message: no bubble, rendered as native markdown (`T3MarkdownText`) at full width with 3.5pt horizontal padding.
  - Sizes at base 16: body 16/23, small 14, h1 21, h2 19, h3 17, h4-h6 15, code blocks 13 with line height 19 (`appearancePreferences.ts:154-171`).
  - Spacing xs 4, s 4, m 8, l 8, xl 16. Heading weight 700. Corner radius s 4, m 8, l 12 (`ThreadFeed.tsx:1130-1170`).
  - Code block corner radius is 8 (`rounded-lg`) with a border, `my-3` (`:990`).
  - A footer with timestamp and copy appears only on the last assistant message of a finished turn.
- Work and tool rows (`work-log-layout.tsx`, `thread-work-log.tsx`):
  - One row is a 28pt minimum height, 6px gap, icon slot 24x24, a 14pt symbol (weight medium), then a one-line 14pt label in muted color.
  - Rows are `gap-px`.
  - Press feedback is `bg-subtle` with a radius of 6.
  - Disclosure chevron rotates over 180 ms.
  - Expanded details indent with `ml-7`.
  - Detail panels fade in over 140 ms.
  - Icon map: read `eye`, edit `square.and.pencil`, command `terminal`, search `globe`, code search `magnifyingglass`, other `wrench`, reasoning `brain`, agent `sparkles`, update `hammer`, device `iphone`, PR `arrow.triangle.pull`.
  - Failed rows use rose text. Warnings use `warning-foreground`. A failed row also gets a "Retry" pill with `arrow.clockwise`.
  - Subagent cards are `rounded-xl border-border-subtle bg-card px-2.5 py-2`.
- Thinking row: shimmering `brain` icon plus "Thinking" (`thread-work-log.tsx:1433-1451`). A reasoning item expands to its text.
- Approvals (`PendingApprovalCard.tsx:23-76`): card with radius 20, border, `bg-card-alt`, padding 16, gap 10.
  - Eyebrow at 12pt bold uppercase with 1.1 tracking, then a title at 18pt bold, then 14pt detail and 12pt warning text.
  - Buttons: "Allow once", "Allow session", "Decline".
  - User-input and secret-request cards sit alongside it.
- Errors: failed runs show a danger-colored status in the sidebar. In the feed they appear as work rows with `text-adaptive-rose-600-400` (`work-log-layout.tsx:55`).
- "Load earlier activity": pill with `chevron.up`, 36pt tall, border `border-border/60`, `bg-surface/80` (`ThreadFeed.tsx:3337`).
- Floating working pill: a Liquid Glass capsule 44pt tall above the composer (`floating-working-control.tsx:58-64,174`). It shows these states:
  - working with an elapsed timer
  - syncing
  - compacting
  - background work
  - goal
  - preparing
  - connection (tappable to reconnect)

## 4. Composer

- Dock (`ThreadComposer.tsx:777-800`):
  - Side padding 12, top padding 6 (8 expanded), bottom padding 6 (8 expanded) plus the bottom inset.
  - Behind it is a fade gradient `from-screen/0 via-screen/60 to-screen/90`.
  - The dock is capped at the 960 content width and centered.
- Surface (`ThreadComposer.tsx:340-367`, `GlassSurface.tsx:36-85`):
  - `expo-glass-effect` `GlassView`, `glassEffectStyle="regular"`, transparent tint, passive (`pointerEvents="none"`).
  - Fallback is a blurred `--color-composer-surface` (`rgba(244,244,245,.94)` light, `rgba(26,27,27,.9)` dark) with a `composer-border`.
  - Shadow is `0 6px 28px` (`adaptive-black-a15-a35`).
  - Radius is 27 collapsed and 26 expanded. The radius animates with the layout.
- Two states, switched by focus (`:533`), morphing over 220 ms with `withTiming`:
  - Collapsed pill: one row with a 44pt `plus` button, a 36pt single-line editor, then dictation and a 30pt circle send button. `paddingVertical: 2`.
  - Expanded card: `minHeight 140`, `paddingTop 14`, `paddingBottom 6`. The editor is `minHeight 72`, `maxHeight 160` and scrolls. Attachment thumbnails sit above it with `px-[14px]`. The toolbar row sits below.
- Toolbar row when expanded (`:1117-1190`):
  - Left: `plus` attachment button (20pt), then the model control. The control shows the provider icon, the model label (14pt medium) and a `chevron.down` at 10. Its height is 44, its radius is 12, its max width is 190, and its press feedback is `bg-subtle` (`ComposerToolbar.tsx:30-80`).
  - Right: dictation, then the primary button.
  - The primary button is a 30pt circle inside a 44pt hit target (`ComposerToolbar.tsx:229-262`). Send is `arrow.up` on `bg-primary` (`#1b4ed8` light, `#346bf1` dark). Disabled is `primary/15`. Stop is `stop.fill` on `bg-danger`.
  - Other send icons: `checkmark` (update a queued message), `list.number` (queue), `arrow.turn.left.up` (steer). While a turn runs, long-press on send offers "Queue", "Steer now" and "Restart turn".
- Attachment menu is a UIMenu: "Photo Library" (`photo`) and "Choose Files" (`folder`). It is a plain tap when the server has no file attachments (`ComposerAttachmentButton.tsx:8-50`).
- Model, reasoning, mode and runtime are not inline controls. Tapping the model control opens the `ThreadSettingsSheet`, a formSheet with detent `[1]` (`Stack.tsx:860-873`). The sheet has an "Options" section and a "Catalog" section (`ThreadSettingsSheet.tsx:914,970`).
- Placeholder: "Ask the repo agent, or run a command…" in a thread (`ThreadDetailScreen.tsx:1434`). For a new task it is "Ask anything…" (`NewTaskDraftScreen.tsx:1474`).
- Editor is a native `UITextView` (`modules/t3-composer-editor`):
  - Font `DMSans-Regular`, default 14/20 but overridden by the body role (16/23). Zero text-container inset and zero line-fragment padding. `keyboardDismissMode = .interactive`.
  - `@file` mentions, `/skill` tokens and pasted attachments are rendered as inline chips (an image attachment drawn into the text).
  - Chip colors default to `#f2f2f7`, border `#dedee3`, text `#262626`, then are themed.
- Keyboard (`T3ComposerEditorView.swift:109-160`):
  - Return sends. Cmd+Return sends the alternate action (queue or steer). Shift+Return inserts a newline.
  - If Return behavior is set to newline, Cmd+Return sends and Cmd+Shift+Return sends the alternate action.
  - Key commands are suppressed during IME composition.
  - A slash or `@` popover appears above the composer (`ComposerCommandPopover`).

## 5. Native controls actually used

- `modules/t3-native-controls` has no menus, pickers or glass buttons. It provides:
  - `LayoutMetrics`, a view that reports safe area and reserved regions.
  - `PresentationSource`, `presentVideo`, `presentFile`, `presentFiles`, and `shareFileFromSource` (UIActivityViewController as an iPad popover, `T3NativePresentation.swift:116`).
  - `FrostedCutout` (a masked `UIBlurEffect` thin material, `T3FrostedCutoutView.swift`).
  - `ContextSheetSize`, and the key-command view.
  - `supportsWorkspaceColumns` is true when the patched `react-native-screens` is present (`T3NativeControlsModule.swift:14-20`).
- The repo has no Swift `glassEffect`, `GlassEffectContainer` or `.buttonStyle(.glass)`. The deployment target is 18.0 (`app.config.ts:443`). Liquid Glass is reached through:
  - `expo-glass-effect` `GlassView` and `GlassContainer`, in `GlassSurface.tsx` (composer, command palette, git progress overlay) and `floating-working-control.tsx`. It is gated on `isGlassEffectAPIAvailable()`, so iOS 26 or later (`native-glass.ts:6-9`). Without it there is a frosted-blur fallback.
  - Header bar items via the patched `react-native-screens`. Glass comes from bar-item shared backgrounds (`sharesBackground`, `hidesSharedBackground`). `glassEffect` is deliberately left off for normal bar buttons (`native-glass-header-items.ts:11-16`).
- Control to library map:
  - Nav bar, bar button items, `UIMenu` header menus, and toolbars: RNS `Stack.HeaderConfig` (`V5StackHeader.ios.tsx:267-309`). Items are `button`, `menu`, `spacer` and `custom`, with SF Symbol icons, `axisBehavior`, `variant` and `tintColor`.
  - Search: RNS `SearchBar`, which is `UISearchController` (`:276-295`).
  - Segmented "Threads | Pull requests": `@expo/ui/swift-ui` `Picker` with `pickerStyle("segmented")` (`WorkspaceSidebarTabs.ios.tsx:21-35`). This is the only SwiftUI control.
  - Tabs: RNS `Tabs.Host`, `tabBarControllerMode: "tabBar"` and `tabBarMinimizeBehavior: "never"` (`WorkspaceNativeTabs.ios.tsx:62-72`).
  - Row, send and attachment context menus: `@react-native-menu/menu` through `ControlPillMenu`.
  - Form sheets: native-stack `presentation: "formSheet"` with `sheetAllowedDetents` and `sheetGrabberVisible` (`native/sheet-surface.ts:5-7`).
  - Swipe rows: `react-native-gesture-handler` `ReanimatedSwipeable`, not `UISwipeActionsConfiguration`.

## 6. Panels

- Files and Git inspector (`ThreadRouteScreen.tsx:486-520,562-625`): when `fileInspector.supported` (split view and viewport >= 820), the toolbar `folder` and Git items put the pane into the third column.
  - Git inspector: `GitOverviewSheet` with `presentation="inspector"`.
  - Files inspector: `ThreadFileNavigatorPane`.
  - Inspector content mounts lazily, then the other mode is pre-warmed after 350 ms (`thread-inspector-content-stack.tsx:8,72-79`).
  - If the inspector is not supported (a narrow window), Files pushes the `ThreadFiles` route and Git presents `GitOverview` as a formSheet with detents `[0.55, 0.92]` (`Stack.tsx:825-831,892-899`).
- Terminal: pushed onto the detail column (`ThreadTerminal`, solid header, `Stack.tsx:782-786`).
  - Header: title "Terminal", subtitle the project, back `chevron.left`, and a `terminal` menu with text-size "A-" and "A+", existing sessions, and "Open new terminal" (`plus`) (`ThreadTerminalRouteScreen.tsx:113-170`).
  - The renderer is GhosttyKit in `T3TerminalView.swift`. It captures hardware keys through `UIKeyCommand` with `wantsPriorityOverSystemBehavior`.
  - The terminal has a row of extra keys: esc, tab, paste, clear, arrows, ctrl, alt, and cmd on iPad (`ThreadTerminalRouteScreen.tsx:562-582`).
- Review (diff): `ThreadReview` is a pushed route with the glass header (`Stack.tsx:807-811`).
  - Header: back `chevron.left` ("Back to chat"), a `sidebar.right` toggle ("Show/Hide changed files"), and a "Select diff" menu with Changes, Uncommitted and Latest turn (`ReviewSheet.tsx:83-135`).
  - The changed-files list registers into the inspector column (`ReviewSheet.tsx:679`). It has a "Changed files" title and a "N files" subtitle, with a left border.
  - The diff is native (`T3ReviewDiffView.swift:205-235`). Defaults: row height 24, gutter 50, change bar 4, code padding 8, file header 54 tall with radius 10, code font 12 bold, line-number font 11, hunk font 12.
- Pull requests: the second sidebar tab is the PR list. Opening one pushes `PullRequest` onto the detail column (`Stack.tsx:718-725`).
  - Its header has a title `#N`, a subtitle, and a right `ellipsis` menu with "Submit review" (`text.bubble`) and "Add comment" (`plus.bubble`) (`PullRequestRouteScreen.tsx:362-425`).
  - PR files, reviewers and the review composer are formSheets with detents `[0.6,0.92]` or `[0.75,0.92]`.
- Full-screen modals: device preview, browser preview and MCP app (`Stack.tsx:787-805,838-846`).
- Sheets: Settings, New task, Connections, queue and agents sheets.

## 7. Colors, materials and typography

- Fonts: DMSans (Regular, Medium, Bold), and Menlo for branch names, times and PR labels (`global.css:17-19`, `thread-list-v2-row-appearance.ts:4`).
- Type scale (`lib/typography.ts:1-11`, applied by `resolveTextScaleVariables` in `appearancePreferences.ts`). Format is size/line height:

  | Name | Size/line |
  |---|---|
  | micro (`text-3xs`) | 11/14 |
  | caption (`text-2xs`) | 12/16 |
  | label (`text-xs`) | 13/17 |
  | footnote (`text-sm`) | 14/19 |
  | body (`text-base`) | 16/23 |
  | headline (`text-lg`) | 18/23 |
  | title (`text-xl`) | 21/28 |
  | largeTitle | 26/32 |
  | display | 30/36 |

  The user's base-font-size preference scales all of these.
- Colors (light | dark) from `generated-uniwind-default-theme-variables.json`:

  | Token | Light | Dark |
  |---|---|---|
  | screen | `#fcfcfc` | `#0a0a0a` |
  | drawer | `#fafafa` | `#000000` |
  | thread-selected | `#ffffff` | `#1a1b1b` |
  | foreground | `#27272a` | `#f5f5f5` |
  | foreground-muted | `#6f6f79` | `#838383` |
  | border | `#e4e4e7` | `#191919` |
  | card | `#ffffff` | `#111111` |
  | primary | `#1b4ed8` | `#346bf1` |
  | md-link | `#1b4ed8` | `#3b70f1` |
  | warning-foreground | `#bb4d00` | `#ffb900` |
  | danger-foreground | `#c10007` | `#ff6467` |
  | sidebar-search | `#f4f4f5` | `#0a0a0a` |
  | backdrop | `rgba(0,0,0,.22)` | `rgba(0,0,0,.48)` |

- There are 10 theme variants: `t3-chat`, `grove`, `ocean`, `ember` and `iris`, each light and dark (`generated-uniwind-theme-names.json`).
- Status hues: approval amber, input indigo, working sky, done emerald, PR open emerald, closed rose, merged violet.
- Corner radii: row 12, user bubble 20, composer 26-27, approval card 20, command palette 20, code block 8, diff file header 10, image 14, send circle full, pills full, model control 12.
- Materials: thread header and sidebar header are transparent Liquid Glass bars on iOS 26 or later (`headerTransparent`, `scrollEdgeEffects`). Otherwise they use `--color-header` (`rgba(252,252,252,.97)` / `rgba(10,10,10,.97)`). Glass tint is `rgba(255,255,255,.22)` / `rgba(17,17,17,.22)`.
- Sheets use `--color-sheet`. Accent tint comes from the nav theme (`useMobileNavigationTheme`) and `--color-primary`.

## 8. iPad-specific and visionOS

- `Platform.isPad` branches:
  - Native columns on or off (`NativeWorkspaceColumns.ios.tsx:10,17`).
  - Sidebar segmented picker (`useSystemWorkspaceTabBar.ts:6`).
  - Native toolbar compose button (`WorkspaceToolbar.ios.tsx:22`).
  - A compact "New task" header button only when split view is off (`HomeHeader.tsx:29`).
  - The phone-only bottom search placement is off on iPad (`V5StackHeader.ios.tsx:170`).
  - Phone-only variants that iPad skips:
    - The tab bar's trailing compose action (`WorkspaceNativeTabs.ios.tsx:52`).
    - The "Duo" 18pt spacer logic and search button in the thread header (`useThreadHeaderOptions.tsx:26,111-114`).
    - 85% bubble width (`ThreadFeed.tsx:1749`).
    - The `scrollableAxes` inset behavior (`:3176`).
- Hardware keyboard (iPad only): the Cmd+K command palette and Cmd+1..9 thread jumps (`T3KeyboardCommandsModule.swift:37-72`). On iPhone Cmd+K focuses search.
- Orientation: iPad follows `UISupportedInterfaceOrientations~ipad` (`T3WorkspaceOrientationSubscriber.swift:15-18`). `supportsTablet: true` (`app.config.ts:250`).
- There are no `isVision`, Mac Catalyst or visionOS branches anywhere in `src` or `app.config.ts`.
- "Duo" and hinge code (`verticalBarEdge`, `reservedRegions`) is Surface Duo-style dual-screen support. It reuses the same column machinery and can be ignored for macOS.
- Pointer hover: only the `thread-hover` and `row-hover` colors exist. I found no explicit pointer-interaction code.

## Gaps and notes for the AppKit rebuild

- The sidebar is a single list with a Threads or Pull requests switch, not a project tree. Project grouping is a setting (`projectGroupingMode`) and affects filters, not section headers, as far as I traced.
- I did not trace the inspector's exact width on the native path, because UIKit sets it and the code passes no value.
- I did not open the compiled `react-native-screens` Swift (`deps/react-native-screens-5.0.0-t3.24.tgz`). Behavior of `Split.Host` beyond the props above is inferred from the TypeScript call sites.
- Markdown native drawing details (`modules/t3-markdown-text/ios/*.mm`) were only sampled. Sizes above come from the JS config that feeds it.
