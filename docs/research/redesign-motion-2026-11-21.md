# Redesign motion, 2026-11-21

The user agreed to this item: "One motion system. Menus, popovers, the right panel and pills should all open the same way, fast, around 150 ms with a slight ease, and buttons should respond to a press. Today some things animate and some pop in."

This covers Redesign (theme `candywrapper-dither`) only. The default themes and Glass keep T3's motion: every change below branches on `ThemeRuntime.isDither`, and the stock arm keeps its old duration and curve.

## The system

The tokens are `RedesignTokens.Motion` in `Packages/CandyKit/Sources/DesignSystem/Theme/RedesignTokens.swift`. The patterns are `RedesignMotion` in `Packages/CandyKit/Sources/DesignSystem/Base/RedesignMotion.swift`.

| Token | Value | Used for |
|---|---|---|
| `fast` | 120 ms | every exit, the hover fade out, the press |
| `standard` | 150 ms | menus and popovers opening, pills appearing, pills and toasts restacking, the segmented selection, the tab strip |
| `large` | 200 ms | modal backdrops, the right panel, a toast arriving |
| `curve` | `cubic-bezier(0.23, 1, 0.32, 1)` | everything that arrives or moves |
| `exitCurve` | `cubic-bezier(0.4, 0, 1, 1)` | everything that leaves |
| `rise` | 4 pt | how far a pill or toast travels |
| `scale` | 0.98 | what a menu, popover or modal opens from and closes to |
| `pressScale` | 0.98 | a pressed button |
| `panelShift` | 12 pt | how far the right panel travels |
| `loop` | 1.2 s | one cycle of a decorative loop (skeleton pulse, waiting dots) |

`quick` and `appear` stay as names for `standard` and `large`, since the gallery wall and the usage chart use them.

The patterns:

1. A popover or menu scales from 0.98 about its anchor edge (`transformOrigin`) and fades in over `standard`, then out over `fast`. `PopupHost.animate` applies it to every popup in Redesign, menus, selects, comboboxes and pickers included. Only an explicit `.none`, the instant tooltip that follows another one, stays instant.
2. A pill rises 4 pt and fades in over `standard`, and sinks 4 pt and fades out over `fast` (`RedesignMotion.pill`).
3. The right panel takes its room at once and its surface slides 12 pt in from the edge and fades in as one flattened layer over `large`. A closing panel leaves as a still image over `fast` (`RedesignMotion.panel`). The fade is group opacity, so no text shows through other text.
4. A press scales a button to 0.98 over `fast` on mouse down and back on mouse up or on a drag out. Rows keep their pressed fill, which is the fast dim.
5. Hover shows at once and clears over `fast` (`RedesignMotion.hoverTransition`, applied in `ControlView.state`).
6. The segmented control's fill slides from the old segment to the new one over `standard` (`ToggleGroupView.selectedIndex`).
7. A modal's backdrop fades over `large`, the dialog scales from 0.98 over `standard`, and both leave over `fast`.

Every pattern animates layer properties only. The model values are the resting frame from the first frame, so a surface takes clicks and keys at once and a fidelity or baseline capture sees its resting pixels. Each pattern removes its animations when it ends, starts from the presentation value when it reverses, and tags its runs so the end of an interrupted run never touches the run that replaced it. Under Reduce Motion pills, popovers, toasts and modals appear at once, and the panel only fades.

`RedesignTokenGuardTests` now also fails on a literal animation duration on a Redesign code path. The picture's resolve-in in `DitherArtView` is exempt, since that file belongs to the picture work.

## Inventory

Each row gives the place, what happened on main before this change and what happens now. "Pops" means no transition. Counts are at the end.

### Menus and context menus

| Place | Before | After |
|---|---|---|
| Dropdown menus, `MenuPopupView.show`, DesignSystem/Components/MenuView.swift:607 | pops | pattern 1 |
| Context menus, `showContextMenu`, MenuView.swift:618 | pops | pattern 1 |
| Submenus, MenuView.swift:510 | pops | pattern 1 |
| Selects, DesignSystem/Components/SelectView.swift:237 | pops | pattern 1 |
| Comboboxes, DesignSystem/Components/ComboboxView.swift:91 | pops | pattern 1 |
| Composer pickers other than the model picker (traits, access, mode), Features/Pickers/ComposerPickers.swift:260, 275, 391, 469, 523, 544, 585, 593 | pops | pattern 1 |
| Plus menu, Features/Pickers/ComposerPlusMenu.swift:37 | pops | pattern 1 |
| Branch picker, Features/Git/BranchPickerView.swift:67; project chip menu, Features/Composer/DitherProjectChips.swift:430; sidebar pickers, Features/Sidebar/SidebarView.swift:941; draft hero picker, Features/Composer/DraftHeroView.swift:284 | pops, or 150 ms `easeInOut` for the chip menu | pattern 1 |
| `/` command menu above the composer, Features/Thread/ThreadPanelView.swift:2158 | pops | rises in like a pill; closes at once, since a choice in it takes effect at once |
| Stash list above its pill, ThreadPanelView.swift:2165 | pops | rises in like a pill; closes at once |

### Popovers

| Place | Before | After |
|---|---|---|
| `PopoverView`, DesignSystem/Components/PopoverView.swift:91 | scale 0.98 and fade, 150 ms `easeInOut` both ways | pattern 1 |
| Model picker, Features/Pickers/ComposerPickers.swift:344 | the same | pattern 1, through `PopupHost` with no change to the picker's files |
| Context popover, Features/Thread/ThreadContextWindowMeterView.swift:294 | the same | pattern 1 |
| Cost card and image gallery card, Features/Thread/ThreadImageGallery.swift:423 | the same | pattern 1 |
| Tooltips, DesignSystem/Components/TooltipView.swift:169 | the same; instant when one follows another | pattern 1; the follow-on stays instant |
| Tooltip glide when its trigger scrolls, DesignSystem/Base/PopupHost.swift:423 | 150 ms `easeInOut` | `standard` on `curve` |
| Hover cards (sidebar thread, PR, issue link previews), Features/Sidebar/SidebarListView.swift:468, Features/PullRequests/PullRequestLinkPreviewView.swift:95, Features/Issues/IssueLinkPreviewView.swift:93 | the same as popovers, or pops for the PR badge list | pattern 1 |
| Thread minimap preview, Features/Thread/ThreadMinimapView.swift:156 | pops | pattern 1 |
| Anchored copy toast, DesignSystem/Components/AnchoredCopyToast.swift:9 | tooltip motion | pattern 1 |

### Modals and sheets

| Place | Before | After |
|---|---|---|
| Dialogs on `ModalHost`, DesignSystem/Components/ModalHost.swift:191 | backdrop and dialog 200 ms `easeInOut`, both ways | pattern 7 |
| Sheets on `ModalHost` | 32 pt slide, 200 ms | the same slide on pattern 7's durations and curves |
| Nested dialogs stepping back, ModalHost.swift:241 | 200 ms | unchanged, left: it moves the dialog under another, not an opening |
| Settings, Features/Settings/AppRouteModalView.swift:236 | backdrop 200 ms, surface 150 ms from 0.985, the same out | pattern 7 |
| Command palette, Features/CommandPalette/CommandPaletteController.swift:534 | 200 ms `easeInOut` | pattern 7 |

### The right panel and the sidebar

| Place | Before | After |
|---|---|---|
| Right panel open and close, Features/Thread/ThreadPanelView.swift:1257 | pops at T3's default Panel animations of 0 ms; follows that setting when it is above 0 | pattern 3 at 0 ms; the setting's slide when it is above 0, unchanged |
| Right panel as a sheet under 980 pt | pops at 0 ms | pattern 3, with its backdrop fading over `large` |
| Right panel tab switch, Features/Thread/RightPanelView.swift | content swaps at once | unchanged, left: tab content shows on its first frame, as in Linear and Capy |
| Tab reorder drag, RightPanelView.swift:353 | 200 ms CSS `ease` | unchanged, left: it tracks the pointer during a drag |
| Tab strip in the band, DesignSystem/Components/DitherTabStripView.swift:136 | 150 ms on Capy's curve, literal | the same values, now from the tokens |
| Sidebar collapse, DesignSystem/Components/SidebarView.swift:156 | pops at 0 ms; follows Panel animations | unchanged, left: see below |

### Pills

| Place | Before | After |
|---|---|---|
| Dock pills appearing (Scroll to end, stash, notices, activity, plan follow-up), ThreadPanelView.swift:2209 | rise 4 pt and fade, 150 ms on `curve` | pattern 2 |
| Dock pills leaving | fade 150 ms on `curve`, no travel | pattern 2: sink and fade over `fast` on `exitCurve` |
| Dock pills changing rows | 150 ms literal | `standard` |
| Queue, ThreadPanelView.swift:1925 | in the timeline footer, appears with the timeline | unchanged |
| Waiting chip dots, Features/Thread/DitherWaitingView.swift:138 | 1.2 s loop, literal | `loop` token, only while waiting and shown |
| Stash count tick, Features/Composer/Panels/ComposerStashViews.swift:33 | 180 ms | unchanged, left: T3's own value in a shared view |
| Banner stack expand and dismiss, Features/Composer/Panels/ComposerBannerStack.swift:41 | 150 ms in, 220 ms out | unchanged, left: in Redesign the stack only runs exits of cards, and 220 ms is inside the limit |

### Toasts

| Place | Before | After |
|---|---|---|
| Toast arriving, DesignSystem/Components/ToastViewport.swift:88 | slides the full width in from the right, 500 ms | drops 4 pt from above its slot and fades over `large` |
| Toasts restacking | 500 ms | `standard` |
| Toast leaving | slides the full width out, 500 ms | lifts 4 pt and fades over `fast`; a swipe still leaves in its direction, over `fast` |

### Disclosure rows

| Place | Before | After |
|---|---|---|
| Settings collapsibles, DesignSystem/Base/CollapseMotion.swift:16 | 200 ms `easeInOut` height | unchanged |
| Work groups, subagents card and activity groups in the timeline, Features/Thread/TimelineWorkRows.swift:132 | chevron rotates 200 ms, rows re-tile at once | unchanged, left: the timeline re-tiles rows without motion by design (`docs/research/G-timeline-data.md`) |
| Fold rows, Features/Thread/TimelineFoldRows.swift:40 | chevron morph | unchanged |
| Details card, ThreadPanelView.swift:1018 | pops | unchanged, left: see below |

### Hover and pressed states

| Place | Before | After |
|---|---|---|
| Buttons on `ControlView`, DesignSystem/Base/ControlView.swift:350 | scale 0.97 over 150 ms `easeInOut` | pattern 4 |
| Hover on `ControlView` controls | snaps both ways, or fades 150 ms both ways for `.colors` controls | pattern 5 |
| Rows (sidebar, menu rows) | pressed fill snaps on | unchanged: the fill is the press feedback |
| Hover on controls that draw in `draw(_:)` | snaps | still snaps out: only layer fills, `BoxDecorationLayer` and labels fade |

### Selection

| Place | Before | After |
|---|---|---|
| Segmented control, DesignSystem/Components/ToggleView.swift:252 | old fill fades out and new fades in, 150 ms | pattern 6 |
| List selection (sidebar, menus) | jumps | unchanged, left: macOS and Linear move list selection at once, and keyboard repeat would queue slides |

### Skeletons, images and art

| Place | Before | After |
|---|---|---|
| Thread loading skeleton to content, ThreadPanelView.swift:639 | skeleton pulses on a 1.2 s loop and hides at once | the loop reads `loop`; the swap stays instant so text is readable on its first frame |
| Image viewer, Features/Composer/ExpandedImagePreviewView.swift:181 | fades in 140 ms ease-out | unchanged, left: image-speed owns this file |
| Image zoom, Features/Thread/ImageZoom.swift:130 | `quick` on `curve` | unchanged (same values) |
| Gallery wall, Features/Thread/ThreadImageWallView.swift:686 | `appear` and `quick` on `curve` | unchanged (same values) |
| Dithered usage chart entrance, Features/Usage/UsageChartView.swift:450 | `quick` on `curve` | unchanged, listed only |
| Gradient background, DesignSystem/Components/DitherArtView.swift | discrete keyframe loop over 12 s, only while seen | unchanged, listed only |
| Picture resolve-in, DitherArtView.swift:172 | 750 ms | unchanged, exempt from the guard |

## On screen

Recorded on the M2 Pro (1920 by 1080 at 1x) with `screencapture -v`, main at 778a928e against this branch, the sandbox server on 47392, Redesign with the dithered picture. The strips are in `~/CandyWrapper-research/sandbox/motion-2026-11-21/`, one PNG per pattern, main above and this branch below, each frame labelled in ms from the first frame of the main change. `screencapture` writes a frame only when the screen changes, so the times are the frames it kept.

| Pattern | Main | This branch |
|---|---|---|
| Header menu (`menu.png`) | one frame, pops | about 100 ms of frames, scale and fade |
| Model picker (`popover.png`) | about 117 ms | about 100 ms, with the ease-out's long tail under the threshold |
| Right panel opening (`panel.png`) | one frame, pops | about 117 ms of visible slide and fade, ends on the frame main shows |
| Right panel closing (`panel-close.png`) | one frame, pops | about 117 ms |
| Settings (`modal.png`) | about 100 ms | about 100 ms |
| Press on the composer's + (`press.png`) | 0.97 | 0.98; a 2% scale of a 24 pt button moves under a pixel, so the strip shows little |

The app's CPU in `top`, one-second samples, read 0.0% one second after the panel opened and closed, and 0.0 to 0.1% at idle after each pattern. No pattern leaves an animation on its layer (`RedesignMotionTests`, `RedesignPanelMotionTests`).

## What I left and why

1. The sidebar collapse still follows the Panel animations setting. It reflows the main panel on every display-link frame, which is the per-frame CPU work this system avoids. A layer-only version would slide the sidebar's image while the content takes its new width at once, which reads as a jump on a surface this wide.
2. The details card and the subagents panel still pop. They sit in the header band and resize the timeline under them, so they need the same still-image treatment as the right panel. That is the next step if the user notices them.
3. The `/` menu and the stash list close at once. A choice in them takes effect at the same moment, and a fade there would sit over the composer while the user types.

## For picker-detail

The model picker opens through `PopupHost` with `.popover`, so in Redesign it now opens on pattern 1 (150 ms in on `curve`, 120 ms out on `exitCurve`, from 0.98 about the anchor edge) with no change to its files. Its "Show more" row at Features/Pickers/ModelPickerView.swift:919 grows the list at once. Its submenus and the traits picker at ComposerPickers.swift:391 and 469 open with the same motion.

## Counts

Out of the 57 rows above:

| | Before | After |
|---|---|---|
| Moving on one shared set of values | 18 | 45, all on the tokens |
| Mismatched: other durations or curves next to their siblings | 20 (500 ms toasts, 200 ms modals beside 150 ms popovers, a 0.97 press on `easeInOut`, a segmented fill that faded, literal durations) | 6, kept on purpose: nested dialogs, tab reorder, the stash count, the banner stack, the image viewer, the picture's resolve-in |
| Pops | 19 (every menu, select and picker, the right panel, the minimap preview) | 6, by choice: sidebar collapse, details card, tab content, list selection, the skeleton swap, hover on views that draw in `draw(_:)` |
