# Motion inventory, 2026-10-11

T3 source: `/Users/mrm/CandyWrapper-research/t3code/apps/web/src` (paths below are relative to it). Swift paths are relative to `Packages/CandyKit/Sources`. Read-only research, nothing was built or run.

## How T3 decides timings

- Tailwind `transition-*` with no `duration-*` runs 150 ms on `cubic-bezier(.4,0,.2,1)`. `Motion.Durations.default` and `Motion.easeInOut` in `DesignSystem/Base/ControlView.swift:164-184` are exactly that.
- `ease-in-out` in dialog and sheet classes is the CSS keyword `cubic-bezier(.42,0,.58,1)`, not Tailwind's default curve. `ease-out` is `cubic-bezier(0,0,.58,1)`. `ease-drawer` is `cubic-bezier(.32,.72,0,1)` (`index.css:190`).
- Panel animations (sidebar width, right panel, terminal drawer, grid rows, padding) run only when the user sets `panelAnimationDurationMs`, 0 to 400, and the default is 0 (`packages/contracts/src/settings.ts:121`). They also stop under Reduce Motion. Do not animate them by default.
- T3 button and sidebar row hover backgrounds are not animated. `button.tsx:11` transitions only `box-shadow` and `scale`, and the hover rules in `Sidebar.tsx:1592-1593` have no transition. Instant hover backgrounds are correct, so do not add a fade there.
- Most of the "subtle" feel in T3 comes from `transition-colors` (68 uses), `transition-opacity` (56), `transition-transform` (29) and `transition-[...]` or `transition-all` or `transition-shadow` (66) spread over about 100 files.
- Popup surfaces for menu, select, combobox, autocomplete and command lists have no `data-starting-style` classes (`menu.tsx:51`, `select.tsx:136`, `combobox.tsx:169`, `autocomplete.tsx:107`). They open instantly in T3.
- `.no-transitions` (`index.css:1072`) kills all motion during theme changes. Swift has no equivalent need because it does not animate on theme change.

## Inventory

Status: M matches, D differs, X missing. T3 count is 50 grouped items: 25 M, 7 D, 18 X.

| # | T3 item | Element, property, duration, easing, trigger | T3 source | CandyWrapper | St |
|---|---|---|---|---|---|
| 1 | Button press | scale .97 and box-shadow, 150 ms default curve, `:active` (not for `aria-haspopup`) | `ui/button.tsx:11` | `ControlView.swift:140-158` | M |
| 2 | Button and row hover background | instant, no transition | `ui/button.tsx:11`, `Sidebar.tsx:1592` | `ButtonView.swift:213+`, `SidebarRowViews.swift:157-186` | M |
| 3 | Checkbox, radio mark | no motion, only ring `transition-shadow` | `ui/checkbox.tsx:11`, `ui/radio-group.tsx:22` | `CheckboxView.swift` | M |
| 4 | Switch | track bg and shadow 200 ms; thumb `translate .15s, border-radius .15s, scale .1s .1s, transform-origin .15s` | `ui/switch.tsx:21,38` | `SwitchView.swift:96-124` | M |
| 5 | Tooltip popup | scale .98 and opacity, 150 ms, enter and exit, `data-instant` skips it | `ui/tooltip.tsx:112` | `PopupHost.swift:190` (`.tooltip`), `PopupHost.swift:389-415` | M |
| 6 | Popover popup | scale .98 and opacity, enter only, 150 ms | `ui/popover.tsx:87` | `PopupHost.swift:188` (`.popover`) | M |
| 7 | Menu, select, combobox, autocomplete, command list popups | no motion | `ui/menu.tsx:51`, `ui/select.tsx:136` | no `motion:` passed, popups are instant | M |
| 8 | Preview card | scale .98 and opacity, 150 ms | `ui/preview-card.tsx:33` | `.tooltip` motion in `PullRequestLinkPreviewView.swift:96`, `SidebarListView.swift:304` | M |
| 9 | Command palette | backdrop and popup fade and scale | `ui/command.tsx` + `dialog-styles.ts` | `CommandPaletteController.swift:441-460` | M |
| 10 | Toast stack | `transform .5s cubic-bezier(.22,1,.36,1), opacity .5s, height .15s`; enter from the edge, exit by swipe direction | `ui/toast.tsx:579,614-629` | `ToastViewport.swift:75-150` | M |
| 11 | Toast collapsed content fade | opacity 250 ms | `ui/toast.tsx:669` | `ToastView.swift:16-17` | M |
| 12 | Anchored copy toast | scale .98 and opacity | `ui/toast.tsx:731` | `AnchoredCopyToast.swift:9` | M |
| 13 | Collapsible panel | height 200 ms, `motion-reduce:transition-none` | `ui/collapsible.tsx:33` | `CollapsibleView.swift:50-72` | M |
| 14 | Section header chevron | rotate 180, 150 ms | `ui/collapsible-section-header.tsx:39` | `CollapsibleView.swift:160-172` | M |
| 15 | Scrollbar thumb | opacity, in 100 ms, out 150 ms after 300 ms delay | `ui/scroll-area.tsx:92` | `ScrollAreaView.swift:147-215` | M |
| 16 | Skeleton | opacity pulse 2.4 s, steps(4) | `index.css:216,283` | `SkeletonView.swift:40-46` | M |
| 17 | Spinner, refresh icon | rotate 1 s linear, only while visible | `ui/spinner.tsx:7`, `ui/refresh-icon.tsx:33` | `SpinnerView.swift:21-25`, `LoopingAnimation.swift` | M |
| 18 | Status pulse | opacity 2 s, steps(6), thread rows, terminal icon, mini player | `index.css:219,302` | `SidebarRowViews.swift:813-868` | M |
| 19 | Live tool shine | gradient band 2.2 s steps(30) over text | `index.css:521-548` | `TimelineRowSupport.swift:205-220` (2.2 s linear, not steps(30)) | M |
| 20 | Preview loading bar | scaleX .04 to .9 over 5.3 s, fade 150 ms after 220 ms | `index.css:2171-2200` | `BrowserPanelView.swift:186-210` | M |
| 21 | Scroll to latest | glide 300 ms | `chat/MessagesTimeline.tsx:431` | `TimelineView.swift:612-626` | M |
| 22 | Message meta hover reveal | opacity 200 ms | `chat/MessagesTimeline.tsx:2521,2880` | `TimelineMessageRows.swift:274,353`, `TimelineRowSupport.swift:150-160` | M |
| 23 | Composer send and stop button | hover scale 1.05, 150 ms, `transition-all` | `chat/ComposerPrimaryActions.tsx:141,314` | `ComposerPrimaryButton.swift:140-155` | M |
| 24 | Sidebar list reorder, enter, exit | 150 ms ease-out, translateY, fade, max 40 faded rows | `Sidebar.motion.ts:1-130` | `SidebarListView.swift:60-120` | M |
| 25 | Settings search target pulse | box-shadow ring 650 ms ease-in-out, twice | `index.css:887-899` | `SettingsShellViews.swift:461-469` | M |
| 26 | Dialog, alert dialog, sheet | backdrop 200 ms; popup scale .98, opacity, translate, 200 ms `ease-in-out`; nested dialog translate-y-8; sheet 32 px slide | `ui/dialog-styles.ts:2,8,14`, `ui/sheet.tsx:19,90-98` | `ModalHost.swift:150-185`, `ThreadPanelView.swift:636-650` | D |
| 27 | Focus ring and border fade | `transition-shadow` 150 ms on input, textarea, checkbox, radio, toggle, badge, number field, input group, scroll area | `ui/input.tsx:68`, `textarea.tsx:20`, `checkbox.tsx:11`, `radio-group.tsx:22`, `toggle.tsx:9`, `badge.tsx:10`, `number-field.tsx:36`, `input-group.tsx:10`, `scroll-area.tsx:60` | ring appears and disappears instantly in `ControlView.stateDidChange` | D |
| 28 | Panel animations | width, left, right, grid-rows, padding-left, opacity at the user duration, `ease-out`; default 0 | `ui/sidebar.tsx:287,299,493`, `ChatView.tsx:1325,11218,11284`, `preview/PreviewPanelShell.tsx:119` | `SettingsPanelMotion.swift:1-18` translates only (`ponytail` comment) | D |
| 29 | Slider thumb | transform and box-shadow 120 ms `ease`, hover scale 1.08 | `index.css:970-995` | `SliderView.swift:48` sets the scale with no animation | D |
| 30 | Switch thumb radius while pressed | border-radius and scale-x 1.1 on `:active` | `ui/switch.tsx:38` | skipped, listed in `docs/design.md` Known gaps | D |
| 31 | Collapsible sibling slide | siblings ride the height change | `ui/collapsible.tsx:33` | siblings jump, `docs/design.md` Known gaps | D |
| 32 | Sidebar drag and drop | rows 200 ms dnd-kit transition, lifted row 150 ms ease-out, label reveal 200 ms step-end | `Sidebar.tsx:654-706`, `index.css:2207` | not checked, no drag-specific animation found in `SidebarListView.swift` | D |
| 33 | `transition-colors` on links, rows, tabs, pills, headers | color and background 150 ms | 68 uses, e.g. `chat/MessagesTimeline.tsx:2709,2733`, `chat/ChatHeader.tsx:279`, `RightPanelTabs.tsx:511`, `Sidebar.tsx:1765,5563`, `chat/ComposerPrimaryActions.tsx:373`, `ui/toast.tsx:100,159,227` | `restyle()` snaps colors | X |
| 34 | `transition-opacity` hover reveals | opacity 150 ms (200 ms on timeline strip and meta); sidebar row actions, labels, unpin, header pencil, attachment remove | 56 uses, e.g. `Sidebar.tsx:933,1827,1858,1903,2094`, `chat/ChatHeader.tsx:341`, `chat/ChatComposer.tsx:7203`, `MessagesTimeline.tsx:1792,1902,1971` | sidebar row actions flip `alphaValue` instantly (`SidebarRowViews.swift:492-494`) | X |
| 35 | Disclosure chevron rotation | rotate 180 or 90, 150 or 200 ms | `MessagesTimeline.tsx:3155,3388,5715`, `chat/ModelPickerContent.tsx:1012`, `onboarding/WelcomeWizard.tsx:1613`, `settings/ThemeColorPicker.tsx:269` (29 `transition-transform` uses) | timeline fold rows swap two icons (`TimelineFoldRows.swift:10-34`) | X |
| 36 | Streaming block fade-in | opacity 0 to 1, 600 ms ease-out, new paragraph or code block only while streaming, off under Reduce Motion | `index.css:2009-2020` | none | X |
| 37 | Composer banner stack | grid rows 150 ms ease-out; opacity and translate 150 ms ease-out in, 220 ms ease-in out | `chat/ComposerBannerStack.tsx:9,179-224` | none in `ComposerBannerView.swift` | X |
| 38 | Composer collapse and expand | mount scale .95 to 1 and opacity, 300 ms `ease-drawer`; surface bg 200 ms; model strip glass swap | `chat/ChatComposer.tsx:404,6906`, `chat/ComposerSurface.tsx:24,69` | none | X |
| 39 | Composer context label and stash badge | label opacity 180 ms `ease-drawer`; badge translate-y .5 and opacity 180 ms `ease-out`, replays on count change | `ComposerContextLabel.tsx:28`, `chat/ComposerStashBadge.tsx:28,49` | none | X |
| 40 | Context window meter | `stroke-dashoffset`, `width`, color 500 ms ease-out | `chat/ContextWindowMeter.tsx:82,126` | none in `ThreadContextWindowMeterView.swift` | X |
| 41 | Draft hero to thread transition | composer slides with `translate3d`, panel duration, `cubic-bezier(.4,0,.2,1)`; headline exits up 6 px | `ChatView.tsx:660-690`, `chat/draftHeroTransition.ts:2`, `index.css:68-90` | none (depends on item 28 setting) | X |
| 42 | Select trigger, toggle, number-field button fades | color, shadow, bg 150 ms | `ui/select.tsx:14`, `ui/toggle.tsx:34`, `ui/number-field.tsx:52,70` | snap | X |
| 43 | Tooltip and popover positioner morph | top, left, transform transition so a popup glides between triggers | `ui/tooltip.tsx:105,126`, `ui/popover.tsx:76,104` | none | X |
| 44 | Connection status ping | halo scale .75 to 2, opacity .9 to 0, 2 s steps(8) for connecting and reconnecting | `ConnectionStatusDot.tsx:21-42`, `index.css:317` | `ConnectionsHostViews.swift:307` has a `ponytail` note, no ring | X |
| 45 | Diff expand fade | 200 ms fade on expand | `diffs/StyledDiffCodeView.tsx:232,245` | `docs/design.md` Known gaps | X |
| 46 | Working activity band | translateX loop 2.2 s linear on the live row | `index.css:556-622` | none | X |
| 47 | Sidebar working row recede | whole row opacity .7 to 1 on hover or focus | `Sidebar.tsx:1598,1668` | none | X |
| 48 | Pull request panel transitions | 100, 150, 200 ms colors and opacity | `pullRequest/PullRequestDetailPanel.tsx:1687-1690,2250,2602` | none | X |
| 49 | Menu switch item thumb | same as the switch | `ui/menu.tsx:148,151` | not checked in `MenuView.swift`, treat as missing | X |
| 50 | Update pill dismiss | `transition-all` 180 ms `ease-drawer`, dismiss bar scale-x linear | `sidebar/SidebarProviderUpdatePill.tsx:128,155,165` | enter only (`SidebarProviderUpdatePill.swift:146-184`), dismiss bar not checked | X |

Not motion, skipped: the autofill `background-color 5000000s` hack (`ui/input.tsx:25`), the mobile composer view-transition keyframes (`index.css:46-90`, mobile route only), `useResizeDrag`, and the JS scroll controllers that use `requestAnimationFrame` only for layout settling. T3 has no spring library and no MorphIcon in `apps/web/src`; the sidebar trigger path morph that `docs/design.md` mentions is not in the files I searched.

## Gaps ranked by how often a user sees them

1. Sidebar row actions and hover labels snap (item 34). T3 fades them in 150 ms. Native: in `SidebarRowViews` replace the `alphaValue` flips at `:492-494` with `TimelineRowBase.reveal`-style 150 ms fades, or a 150 ms `opacity` `CABasicAnimation` from the presentation value.
2. Text and icon color changes on hover snap everywhere (item 33). Native: add a 150 ms `CABasicAnimation` on `foregroundColor` / `backgroundColor` in `ControlView.stateDidChange` for views that opt in, starting from `presentation()`, skipped under `Motion.reduced`.
3. Disclosure chevrons swap instead of rotating (item 35, `MessagesTimeline.tsx:3155,3388,5715`). Native: one `IconView` and a `transform.rotation.z` animation, 150 ms, as `CollapsibleView.rotateChevron` already does at `:160-172`.
4. Focus ring appears instantly (item 27, 150 ms). Native: animate the ring layer's `opacity` in `BoxDecorationLayer` when `focusVisible` flips.
5. Streaming text pops in (item 36, 600 ms ease-out). Native: when a streamed message adds a block, add an `opacity` 0 to 1 animation on that block's layer, `cubic-bezier(0,0,.58,1)`, only for blocks inserted while `streaming`.
6. Composer shell has no motion (items 37 to 40). Native: banner stack with `opacity` plus `transform.translation.y` 150 ms in and 220 ms out; context label `opacity` 180 ms with `.32,.72,0,1`; meter arc `strokeEnd` and bar `bounds.size.width` at 500 ms ease-out.
7. Select trigger, toggle and number-field fades (item 42). Native: same `backgroundColor` animation as item 2 above, 150 ms.
8. Dialog and sheet easing and nested offset (item 26). Native: use `CAMediaTimingFunction(controlPoints: .42, 0, .58, 1)` for the popup transform and opacity in `ModalHost.animate`, keep `.4,0,.2,1` for the backdrop, add `translate-y 32` for nested dialogs.
9. Slider thumb scale and focus on controls (items 29, 30). Native: animate the thumb `transform.scale` 120 ms `ease` in `SliderView`.
10. Context-dependent extras: connection ping (44), working band (46), diff expand fade (45), positioner morph (43), draft hero (41), panel animations (28). Each is low frequency or off by default in T3.

## Responsiveness findings beyond motion

- `ControlView` does not override `acceptsFirstMouse`. Only `SliderView.swift:24`, `ComposerCommandMenuView.swift:222` and `ComposerStashViews.swift:67` do. When the app window is inactive, the first click on any button probably only activates the window. Chromium delivers that click. Fix: `override func acceptsFirstMouse(for:) -> Bool { true }` in `ControlView`. I did not run it to confirm.
- Activation happens on mouse up in `ControlView.swift:96-101`. A web `click` also fires on mouse up, so buttons match. Base UI menu triggers, however, open on pointer down. `MenuView.swift:436` swallows `mouseDown` for items. I did not trace the trigger path, so check that menu and select triggers open on press and that dragging from the trigger onto an item selects it.
- Hover is driven by `mouseEntered` and `mouseExited` only (`ControlView.swift:61-70`). When a list scrolls or relayouts under a still pointer, AppKit does not send an enter until the mouse moves, so a row can stay un-hovered, or stay hovered after it moved away. Chromium re-evaluates hover after layout. Not tested here. A cheap fix is to call `window.mouseLocationOutsideOfEventStream` after scroll end and re-hit-test.
- The send path already shows sent messages at once through `ThreadViewModel.optimisticMessages` (`ThreadViewModel.swift:270-284`). I did not audit other actions (rename, pin, archive, settings toggles) for waiting on the server before updating the UI.
- Focus rings exist in 24 files via `focusVisible`. They snap rather than fade (item 27), which reads as abrupt but not broken.
- Reduce Motion is checked in every animation I found (`Motion.reduced`). `LoopingAnimation.swift:46` also pauses loops when hidden.
