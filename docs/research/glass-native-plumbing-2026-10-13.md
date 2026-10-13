# Glass Native plumbing: themes, window seams and macOS 26+ glass APIs

A read-only map from 2026-10-13 for `docs/glass-native.md`. Line numbers are as of d553b78.

## Themes

- The built-ins are `ThemeDefinition.builtIns + [glass]`, as `pickerBuiltIns` (`DesignSystem/Theme/ThemePalette.swift:59`).
- Glass is `ThemeDefinition.glass`, id `candywrapper-glass` (`:55-56`), and `isWindowGlass` checks for that id (`:61`).
- Reserved ids are in `ThemePalette.reservedIds` (`:67-69`), and a new built-in id belongs there.
- `ThemeLibrary.definition(_:)` looks in `pickerBuiltIns`, then custom themes, then environment themes (`Features/Settings/ThemeLibrary.swift:105-108`).
- The Appearance page draws one `ThemeLibraryCardView` per `pickerBuiltIns` entry (`Features/Settings/AppearanceSettingsView.swift:89-93`). Card previews come from `ThemeCardDefinition` (`ThemeGalleryViews.swift:6-32`), where Glass reuses the stock T3 circles (`:31-32`). The refresh signature is at `AppearanceSettingsView.swift:66-67`.
- The selection lives in UserDefaults `theme.preference` (`ThemeLibrary.swift:32-36`), written by `setTheme` (`:147-152`). An unresolvable id falls back to "system" (`:61-63`). It never reaches the server: T3's `DefaultThemePreference` is absent from `ServerSettingsPatch` (t3code `packages/contracts/src/settings.ts:255-264`).
- `ThemeLibrary.runtimeInput` special-cases `isWindowGlass` to use stock tokens with glass on (`ThemeLibrary.swift:331-335`). A Glass Native id needs the same branch, or a flag on `ThemeDefinition`.
- `ThemeRuntime.glass` decides frost per appearance (`DesignSystem/Theme/ThemeRuntime.swift:69-71`).
- The client settings, including `glassOpacity`, are one JSON blob in UserDefaults `clientSettings.v1` (`Features/Settings/ClientSettingsStore.swift:8-14`), and stay local.
- The glass opacity range is 10...100 since d553b78. `WindowGlass.mutedLight` and `mutedDark` are tuned at 80%, and the ponytail at `DesignSystem/Components/WindowGlass.swift:18` asks for them to be derived from `alpha` now that users can go lower.

## Glass today

- `WindowGlassBackdropView` (`WindowGlass.swift:56-77`) is an `NSVisualEffectView` with `.behindWindow`, `.underWindowBackground` and `.followsWindowActiveState`. Its `hitTest` returns nil.
- `SidebarLayoutView` owns the backdrop and adds or removes it in `updateGlass()` (`DesignSystem/Components/SidebarView.swift:84, 172-188`).
- Base surfaces use `WindowGlass.surface`, at `alpha = 0.75 * glassOpacity` (`WindowGlass.swift:14, 34-40`):
  - `mainSurface`
  - `sidebarSurface`
  - `inset`, which is clear while frosted (`NoActiveThreadStateView.swift:33`, `RightPanelView.swift:433`)

## Window and seams

- `MainWindow` (`App/Sources/MainWindow.swift:8`) has `.fullSizeContentView`, a transparent titlebar, and the traffic lights moved into a 52 pt top bar (`:34-37, 83-103`). It has no toolbar and no split view controller.
- `AppDelegate.showMainWindow()` (`App/Sources/AppDelegate.swift:161-300`) builds `SidebarContentView` (`:163`), `Environments` (`:168-169`), `ThreadController` (`:176`), and `SidebarLayoutView(sidebarContent:mainContent:)` (`:179`) as `window.contentView` (`:183`). It then wires `SettingsController` (`:185`), `SidebarCommands` (`:211`), the shortcuts and the quit hold.
- `SidebarLayoutView` (`SidebarView.swift:75`) holds the sidebar, `main` (a `GrainSurfaceView`), the rail and the collapsed trigger. It also owns its slide and width drag, and keeps the width in UserDefaults.
- `ThreadPanelView` (`Features/Thread/ThreadPanelView.swift:218`) owns these views:
  - `header` (`:219`), the timeline and the composer (`:268-269`)
  - `model: ThreadViewModel` (`:408`)
  - `rightPanel` (`:482`), `terminalDrawer` (`:489`), `detailsCard` (`:496`) and toasts
  - the banners, approval and question panels, and the context strip (`:525-587`)
- `ThreadPanelView` also owns the panel and terminal state (`:850`, `:948`).
- Settings and Pull Requests swap in by replacing `layout.sidebar.content` and `layout.main`'s subview (`App/Sources/SettingsController.swift:156-163, 188-200`). This is the existing example of swapping a presentation.
- Controllers hold concrete view types:
  - `ThreadController` owns `let panel = ThreadPanelView()` (`App/Sources/ThreadSession.swift:297-298`).
  - `ThreadSession` holds weak `panel` and `sidebar` (`:17-18`) and pushes through `panel.model`, `panel.timeline`, `panel.composer` and `panel.header` (`:416-785`).
  - `ComposerController` (`App/Sources/ComposerController.swift:20`) reads `panel.composer` (`:28`).
  - `SidebarCommands` (`App/Sources/SidebarCommands.swift:13`) holds the sidebar, the layout and the thread controller.
- `SidebarContentView.actions: SidebarActions`, a struct of closures (`Features/Sidebar/SidebarView.swift:8-14, 61-100`), is the cleanest sidebar seam.
- `ShellSession` (`App/Sources/ShellSession.swift:12`) has no UI types.
- These views own state a replacement must keep:
  - `SidebarContentView`: the list state, the snapshot and shelf expansion.
  - `ComposerView`: the draft, plan, compact and history flags, the run state and the draft route (`Features/Composer/ComposerView.swift:12-40`).
  - `ThreadPanelView`: the panel and terminal state, banners, queue and find.
  - `TimelineView`: recycling and the height cache (`TimelineView.swift:27`).
  - `SidebarLayoutView`: width and open state.
- These are pure views over a model: `ThreadHeaderView` (wired at `AppDelegate.swift:211-221`), the banner views, the timeline rows and `ThreadStatusLineView`.

## Theme change delivery

- `ThemeLibrary.changed()` runs `apply()`, notifies its observers and posts `ThemeLibrary.didChange` (`ThemeLibrary.swift:222-238`). Only the Settings page observes it (`App/Sources/SettingsPages.swift:99`).
- `ThemeRuntime.apply` bumps `generation` and walks every window's views (`ThemeRuntime.swift:76-112`).
- No code rebuilds window content on a theme change today. Swapping `window.contentView` is feasible if everything that holds `layout` is re-pointed: `SidebarCommands`, `SettingsController`, `installQuitHold` and `installShortcuts`.

## AppKit glass APIs (SDK 27.0; the deployment target is 14.0 in `project.yml:10`, so gate on `#available(macOS 26, *)`)

Paths are under `AppKit.framework/Headers`.

- `NSGlassEffectView` (`NSGlassEffectView.h:22-47`, macOS 26): has `contentView`, `cornerRadius`, `tintColor` and `style` (Regular or Clear). `effectIsInteractive` arrived in macOS 27.
- `NSGlassEffectContainerView` (`:53-65`): merges nearby glass descendants and batches render passes, with `spacing`.
- `NSBackgroundExtensionView` (`NSBackgroundExtensionView.h:23`): extends content under the safe area.
- `NSBezelStyleGlass` (`NSButtonCell.h:67`) gives a glass button. `tintProminence` on `NSButton` and `NSSlider` (`NSButton.h:124`, `NSSlider.h:33`, `NSTintProminence.h:19-23`) takes Automatic, None, Primary or Secondary.
- `NSView.prefersCompactControlSizeMetrics` (`NSView.h:630`).
- `NSSplitViewItem` has these constructors and properties:
  - `sidebarWithViewController` (`NSSplitViewItem.h:67`), `contentListWithViewController` (`:78`) and `inspectorWithViewController` (`:88`).
  - `allowsFullHeightLayout` (`:131`) and `automaticallyAdjustsSafeAreaInsets` (`:140`).
  - Top and bottom accessory view controllers (`:143-152`).
- `NSSplitViewItemAccessoryViewController.preferredScrollEdgeEffectStyle` (macOS 26.1) takes an `NSScrollEdgeEffectStyle`: automatic, soft or hard (`NSScrollEdgeEffect.h:18-30`).
- `NSToolbarItem.style` takes Plain or Prominent (`NSToolbarItem.h:20-25, 152`). `NSToolbarItemGroup.role` takes Tabs or ValueSelection (macOS 27, `NSToolbarItemGroup.h:37-84`). `NSWindowToolbarStyle` includes Unified and UnifiedCompact (`NSWindow.h:235-244`).

## Rules to keep

- Idle cost stays zero: nothing ticks while idle, and hidden views hold nothing (AGENTS.md).
- A drawing view gets a full-size backing store. Use layer properties for fills, and set `clipsToBounds` where a view draws off-canvas (`docs/gotchas.md:15`).
- `prepareForReuse()` unhides the view and sets alpha back to 1, so call it before hiding a recycled view (`gotchas.md:13`).
- The timeline gets only changed rows, and streaming is paced at 30 fps (`gotchas.md:7`).
- Fidelity tests capture the other themes at rest, and native mode must not change their pixels.
- Glass blur is composited by the window server, so don't put glass on every row. Group glass views in one container.
