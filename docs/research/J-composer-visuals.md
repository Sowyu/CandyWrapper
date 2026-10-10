# J. Composer and surrounding panels visuals (milestone 5)

Source: T3 Code tag in `T3_VERSION` (0.0.46-nightly.20261009.2861), `/Users/mrm/CandyWrapper-research/t3code/apps/web/src`. Paths below are relative to `apps/web/src/components/` unless they start with `index.css` (`apps/web/src/index.css`). `main.css` is `design/t3-source/main.css`, used to confirm compiled values. All values are CSS px at the desktop breakpoint (viewport 640px and up) unless a row says otherwise. Colors use our `Palette.*` names, light / dark. Reference images are in `design/reference/` (cited by number). Format follows `H-timeline-visuals.md`.

Conventions for token names. `fg` = `Palette.foreground`, `muted` = `Palette.mutedForeground`, `secondaryLabel` = `Palette.secondaryLabel` (same values as muted: `#71717b` / `#818181`), `iconMuted` = `Palette.iconMuted`, `border` = `Palette.border` (`#e4e4e7` / `#ffffff0f`), `accent` = `Palette.accent` (`#f4f4f5` / `#ffffff0a`). A suffix `/NN` means NN percent alpha of that color. Tailwind spacing unit is 4px. Radius names: `Tokens.Radius.sm` 6, `md` 8, `lg`/`base` 10, `xl` 14, `_2xl` 18. There is no named token for the composer's 22px radius (`rounded-3xl` = `calc(var(--radius) + 12px)`, `main.css`), so add one.

Text sizes used here: `xs` 12/16, `sm` 14/20, `2xs` 11/16 (`index.css:178-179`), `3xs` 10/14 (`index.css:180-181`), `3xl` 30/36.

## 1. Composer placement

### 1.1 Where the composer sits

The composer is an overlay on the chat column, not a flex row under the timeline. `ChatView.tsx:11507-11518`:

- Overlay `div[data-chat-composer-overlay]`: `pointer-events-none absolute inset-x-0 bottom-0 z-20 pt-1.5 sm:pt-2`. Top padding is 6px below 640px viewport width and 8px at 640 and up. The overlay never blocks clicks on the timeline; only its children take pointer events.
- Lane `.chat-composer-lane` (`index.css:2323-2350`): `padding-inline` 12px below 640px viewport, 48px at 640 and up. This is the same padding as `.messages-timeline-scroll` (see H section 1.2), so bubbles and composer share edges. Add `--chat-lane-inset-start/end` (0 unless a floating preview or details card pushes chat aside).
- Stack `div[data-chat-composer-stack]` (`ChatView.tsx:11520-11524`): `pointer-events-auto relative z-10 mx-auto w-full max-w-(--chat-content-max-width)`.
- `ComposerSurface.Shell` (`chat/ComposerSurface.tsx:7-37`): again `mx-auto w-full max-w-(--chat-content-max-width)`, so nothing else narrows it.
- Under the shell, a spacer `h-[calc(env(safe-area-inset-bottom)+1rem)] sm:h-[calc(...+1.25rem)]` (`ChatView.tsx:11831`): 16px below 640 viewport width, 20px at 640 and up. This is the visible gap below the composer. Reference 01 (dark, 1100x780): composer bottom edge at y = 759, window bottom 780, gap 21 (20 plus the 1px outline).

### 1.2 Width per chat width setting

`--chat-content-max-width` (same variable as the timeline, H section 1.1): comfortable 736 (`Tokens.LengthRem.chatContentMaxWidth`), wide 1152, full 100% (`index.css:128, 2078-2084`).

Composer outer width (the outline box) = `min(max-width, W - 2*48)` where W is the chat column width (window minus sidebar minus right panel). At 1100px window with the 232px sidebar (reference 01/03a/04): W = 868, composer = 736. Reference check: left edge x = 565/1.818 = 311, right edge 1900/1.818 = 1045, width 734 plus antialiasing, so 736.

Below 640px viewport width the lane padding is 12 and the composer is `W - 24`. Reference 04n (800px window, sidebar open, column about 568 + padding): composer is 494 wide. The column is narrow while the window is 800, so the 48px padding still applies (the breakpoint is on the viewport, not the column).

Attached panels (approval, question, queue, banners) are narrower: `ComposerBanner.Attachment` width is `calc(100% - 2 * var(--chat-composer-drawer-inset))` with `--chat-composer-drawer-inset: 1.375rem` = 22px (`chat/ComposerBanner.tsx:111`, `chat/ComposerSurface.tsx:14`). At 736 that is 692 (reference 05: x 605 to 1860 display px, 690 css). The inset equals the composer's corner radius, so the panel's vertical edges start where the composer's corner arcs end.

### 1.3 What floats over what

- The timeline scroller runs full height behind the composer. The timeline reserves a footer equal to the overlay's measured height (`composerTimelineInset`, `ChatView.tsx:6992-7001`, see H section 1.4) so the last row can scroll clear of the composer.
- There is no gradient, fade or mask above the composer. Grep of `ChatView.tsx` and `MessagesTimeline.tsx` finds only the top scroll fade (24px, H section 1.4) and the collapsed-user-bubble fade. Text shows through the composer only via its glass (section 2.1).
- The "Scroll to end" pill (`ChatView.tsx:11484`, `Button size="xs" variant="glass"`, chevron-down 14px) sits `bottom: scrollToEndClearance + 4`, centered in the lane. The clearance is the overlay height minus any attached banner that overlaps the pill horizontally (`composerFooterLayout.ts:226-239`). So the pill rides 4px above the top of whatever sits highest above the composer. Its box has `py-1.5`, `z-30`. Fits `ButtonView(.glass, .xs)`.
- The overlay holds `inert` while a checkpoint revert runs (`ChatView.tsx:11508`).

### 1.4 Draft hero placement

For an empty local draft (`resolveDraftHeroState`, `ChatView.logic.ts:290-310`) the overlay becomes `pointer-events-none absolute inset-0 z-20 flex items-center` (`ChatView.tsx:11512`). The whole stack (headline, composer, context strip, bottom spacer) is vertically centered in the chat column below the 52px header. The headline is `absolute inset-x-0 bottom-full`, so it does not count toward the centering. The centered block is composer 144 + strip 32 + spacer 20 = 196, so its top sits at 416 - 98 = 318 (column area y 52 to 780, center 416). Reference 04 measures 319. Center the 196px block and hang the headline above it.

### 1.5 Narrow-width behavior

- Footer compactness is measured on the form width (`ChatComposer.tsx:3541-3586`, `composerFooterLayout.ts:1-24`): footer compact when width < 620 (or < 780 when the footer holds wide actions: a pending question or a plan follow-up). Compact footer changes the left control gap from `gap-2 sm:gap-0` to `gap-1.5`, and compact primary actions shorten labels ("Next", "Submit", px-3 instead of px-4).
- At the comfortable width (736) the question panel's actions are already compact because 736 < 780 (reference 06 shows "Next", not "Next question").
- Controls drop labels, then move into an overflow menu (section 3.7). Reference 04n: at 494px the access control keeps its lock icon and chevron but loses "Full access".
- Approval rows wrap actions to a second row below 560px of banner width (section 6.1).
- Mobile (viewport under 640 or touch) has a separate collapsed one-row composer (`ChatComposer.tsx:6896-6960`). Milestone 5 targets desktop, so ignore it (see section 11).

## 2. Composer box

### 2.1 Surface stack

Three nested elements draw the box. Native code should draw one rounded surface.

| Layer | Element | Values | Source |
|---|---|---|---|
| Glass fill | `Shell::before` | inset 0, radius 22. Fill `--card` light (`#ffffff`), `--surface-raised` dark (`#111111`), at `--glass-opacity` 80%. `backdrop-blur` 12px (`Tokens.LengthPx.glassBlur`), `backdrop-saturate` 1.14 (`Tokens.Number.glassSaturation`). Hidden when an attached banner is present (the banner and Main take over the fill). | `chat/ComposerSurface.tsx:11-24` |
| Drop shadow | `Host` | `shadow-composer` = `0 12px 28px -18px rgb(0 0 0 / 40%)` (`index.css:193`, compiled `#0006`). Dark mode: none (`dark:shadow-none`). Radius 22. | `chat/ComposerSurface.tsx:47-51`, `index.css:193-194` |
| Outline | `Host::after` | `inset 0`, radius inherit (22), 1px border. Light `rgb(0 0 0 / 8%)` (`#00000014`). Dark `white / 5%` (`#ffffff0d`) plus an inner top highlight `inset 0 1px white / 3%` (`inset-shadow-2xs` with color `--chat-composer-highlight`). | `chat/ComposerSurface.tsx:14-15, 42-43` |
| Content frame | `Main` | `p-px`, radius 22. Draws the same fill, blur, shadow and outline in place of Host/Shell only when a banner is attached. | `chat/ComposerSurface.tsx:68-86` |

So at rest, light: white at 80% with a faint 8% black hairline and a long soft shadow that falls only below (blur 28, y offset 12, spread -18, so it only shows under the bottom edge). Dark: `#111111` at 80%, 5% white hairline, 3% white inner top line, no shadow. Reference 03a/01 confirm: light has a soft underglow below the bottom edge, dark has none.

Our substitution doc replaces glass with a solid color. That is fine over flat backgrounds but the composer floats over scrolling text, so the 20% see-through plus 12px blur will differ. See section 11, item 1.

`ComposerSurface.Main` has class `group relative z-10 rounded-3xl p-px`, so the content inset is 1px. All paddings below sit inside that 1px.

When a provider sets `composerSurfaceClassName` or `composerFrameClassName` (`chat/composerProviderState.tsx:155`, only the Claude "ultrathink" frame) the surface gains extra styling. Not captured, see section 11.

### 2.2 States of the surface

- Focus: no ring, no border change. `ComposerSurface` has no `focus-within` rule and `ChatComposer.tsx:6904-6911` adds none. Reference 01 (editor focused, caret visible) shows the same outline as 03a. The caret is the only focus cue.
- Drag over (files or thread context): `bg-accent/45 ring-1 ring-primary/70` on the content (`ChatComposer.tsx:6906-6909`), transition `background-color 200ms` default easing. `Palette.accent` at 45% plus a 1px `Palette.primary` at 70% ring (`#1b4ed8` / `#346bf1`).
- Project selection required: whole surface `opacity-75` (`:6909`).
- Disabled editor (`isConnecting`, approval, choice-only question): editor `aria-readonly`, placeholder swaps (section 2.5). No visual dim besides the placeholder.

### 2.3 Padding and height

Desktop, expanded, empty prompt (reference 03a / 04: composer height 144, `260 / 1.818 = 143` measured):

| Region | Value | Source |
|---|---|---|
| Main inset | 1 | `ComposerSurface.tsx:70` |
| Body `div[data-chat-composer-body]` | `px-4`, `pt-4`, `pb-2` (16 / 16 / 8) | `ChatComposer.tsx:6977-6979` |
| Editor outer box | min-h 78, max-h 208, padding 4, margin -4 (net layout 70 min / 200 max) | `ComposerPromptEditorTiptap.tsx:999` |
| Footer | `px-4 pb-4`, row height 32 (send button) | `ChatComposer.tsx:7552` |
| Main inset (bottom) | 1 | |

Sum: 1 + 16 + 70 + 8 + 32 + 16 + 1 = 144. Matches the reference.

Variants of the same box:

- Approval state: body `pb-4` (`:6980`), editor `min-h-10` (40 minus 8 margin = 32), no footer (`:7547`: `isComposerCollapsedMobile || isComposerApprovalState ? null`). Height = 1 + 16 + 32 + 16 + 1 = 66 (reference 05: about 64).
- Pending question: footer gets `pt-2` (`:7553`). Editor stays 70 min. Height = 144 + 8 = 152 (reference 06: composer 1113 to 1380 display = 147; measure).
- Resting (scroll-collapsed) layout: see section 3.8. Height 50.
- Attachment previews above the editor (images, files, snapshots) sit inside the body above the editor with `mb-3` (12px) and 8px gaps (`:7008-7090`). Not captured, see section 11.

### 2.4 Editor height growth and scrolling

The editor is a Tiptap `div.composer-tiptap` (contenteditable) with no JS height logic. It grows with content between `min-h-19.5` (78) and `max-h-52` (208) and scrolls vertically past that (`overflow-y-auto`). Because of the `p-1 -m-1` pair, text lines start exactly at the body padding edge and the scrollbar sits 4px outside the text box on the right. Net layout height = box height - 8.

So the composer grows one text line at a time (22.75px) from 70 to 200 net, i.e. from 144 to 274 total, then the editor scrolls internally. The footer stays pinned under it. Grow and shrink are immediate (no animation). The timeline inset follows the overlay height through `ResizeObserver` (`ChatView.tsx:7040-7067`).

### 2.5 Editor typography

`ComposerPromptEditorTiptap.tsx:1744` wrapper: `font-(family-name:--font-composer, var(--font-sans)) text-(length:--font-size-prompt, var(--text-sm))`. No setting in this tag sets `--font-composer` or `--font-size-prompt` (grep found only the touch fallback at `index.css:131`), so:

- Font: system sans (`DSFont` system), 14px, weight 400.
- Line height: `leading-relaxed` = 1.625, so 22.75px (`main.css` `.leading-relaxed`).
- Color: `fg` (`text-foreground`).
- White space: `pre-wrap`, `wrap-break-word`.
- Touch devices below 640: 16px (`max-sm:pointer-coarse`). Ignore.
- Inline code `:not(pre) > code`: mono, 0.92em, `muted-foreground` at 12% oklab mix as background, radius 0.3em, padding 0.05em 0.25em (`index.css:2237-2243`).
- Rich markers (`** * \``) shown dim: `muted` at 0.75 opacity (`index.css:2245-2252`).
- Selected chip: 2px `--ring` outline, offset 1, radius 6 (`index.css:2256-2260`).
- Blockquote, lists, headings reuse `.chat-markdown` rules (`index.css:1778-1920`), see H section 4.

Placeholder (`:1790-1797`): absolutely positioned at `inset-0` of the editor container (not the padded editor), `leading-relaxed`, `text-placeholder/75`: `Palette.placeholder` (`#71717b` / `#818181`) at 75%. Starts at the first line, x = body padding (reference 03a: text at x = 595 display, composer left 565, diff 16.5).

Placeholder strings (`ChatComposer.tsx:7447-7466`, `composerPlaceholder.ts:1-2`):

| Condition | Text |
|---|---|
| Default | `Ask anything, @tag files/folders, $use skills, or / for commands` |
| Disconnected (phase `disconnected`) | `Ask for changes, send follow-ups, or attach images` |
| Approval pending | `Resolve this approval request to continue` |
| Pending question, free text | `Type your own answer, or leave this blank to use the selected option` |
| Pending question, choice only | `Choose an option above` |
| Plan follow-up | `Add feedback to refine the plan, or leave this blank to implement it` |
| Project required | `Choose a project above to start a thread` |
| No provider | `Enable a provider in Settings to send a message` |

Reference 04 shows the disconnected text on the new-thread draft (the capture had no session for the draft). Confirm whether a live draft shows the default string, see section 11.

Caret: the browser default (text color, 1px, blinking). Use `NSTextView` insertion point in `fg`.

### 2.6 Draft and pending states that change the box

- Approval: editor empty, readonly placeholder. Banner above (section 6.1).
- Question: placeholder per table, editor writable (free-text answer), footer shows Stop plus the "Next" pill.
- Drag-over, error: `ComposerPromptLengthValidation` text and `composerSubmissionError` render between body and footer (`:7620-7628`). Not captured.

## 3. Footer controls

Footer = `div[data-chat-composer-footer]` (`ChatComposer.tsx:7552`): `flex min-w-0 flex-nowrap items-center justify-between gap-2 overflow-visible px-4 pb-4`. Left cluster (`data-chat-composer-controls="left"`, `:7567`): `-m-1 -ms-3.5 flex min-w-0 flex-1 items-center gap-1 overflow-x-auto p-1 ps-3.5`, scrollbar hidden. The negative margin and padding cancel, so the cluster starts at the footer's left padding (16) and gives focus rings 4px room. Right cluster (`:7582`): `flex shrink-0 items-center justify-end gap-2`.

The model trigger additionally has `-ms-2.5` (`:5557`) and `px-2.5`, so the provider icon sits at x = 16 + 1 = 17 from the composer's left edge. Reference 03a: icon left at 597 display, composer left 565, 17.6.

Order in the left cluster: model picker, separator, traits picker, separator, access mode, then (only when plan mode UI is enabled) separator and Build/Plan toggle. Right cluster: attach button, optional context meter, primary action button.

### 3.1 Shared control look (`ComposerControl`)

`chat/ComposerControl.tsx:17-26`. App-owned, not a restyled Button, so it needs its own drawing code (build as a `ControlView` subclass using `BoxStyle`). Size `sm` (expanded footer):

| Property | Value |
|---|---|
| Height | 28 |
| Padding x | 10 (`px-2.5`), 1px transparent border inside |
| Gap | 6 (`gap-1.5`) |
| Radius | 8 (`--control-radius` 0.5rem, `Tokens.LengthRem.controlRadius`) |
| Font | 14/20 (`sm:text-sm`), weight 500 (`font-medium`) |
| Text color | `secondaryLabel` (`#71717b` / `#818181`); hover `fg` |
| Icons | 16px (`sm:size-4`), color `muted` unless they set their own `text-*` class. `data-composer-control-icon` icons have `mx-0`; other svg (chevrons) have `-mx-0.5` |
| Hover bg | `accent` (`#f4f4f5` / `#ffffff0a`). No transition class, so hover is instant |
| Open (popup showing) | `data-pressed` bg `accent`, same as hover (reference 41 and 42 show the filled trigger) |
| Pressed toggle (`aria-pressed`) | bg `accent`, text `accentForeground`, hover bg `accent/80` |
| Focus (keyboard) | 2px `Palette.ring` ring with 1px offset in `background` (`focus-visible:ring-2 ring-ring ring-offset-1 ring-offset-background`) |
| Disabled | opacity 0.64, no pointer events |
| Press | scale 0.97, but only for controls without `aria-haspopup` (`[&:active:not([aria-haspopup])]:scale-[0.97]`). Only the Plan/Build toggle scales. No transition class so the scale snaps |
| Cursor | pointer |

Size `xs` (resting strip and the context strip): height 24 (`sm:h-6`), `px-1.75` (7), `gap-1` (4), 12px text weight 400, color `muted / 70%`, hover color `fg / 80%`, icons 12px (`size-3`) for composer icons or 14px otherwise, chevron `size-3 opacity-50`, chevron margin-end -4.

Chevron (`ComposerControlChevron`, `:73-92`): lucide `chevron-down`, stroke width 2.25. `sm`: 14px, color `iconMuted`. `xs`: 12px, `currentColor` at 50%.

Separator (`ComposerControlSeparator`, `:94-108`): `Separator` vertical, `mx-0.5` (2px), height 16 (`sm`) or 14 (`xs`), 1px wide, `bg-border`, hidden below 640 viewport. Fits `SeparatorView`. Between two controls the visible gap is 4 (cluster gap) + 2 + 1 + 2 + 4 = 13 from trigger box to trigger box.

Tooltips: each control has a `TooltipPopup side="top"` (`TooltipView`), default offset 4. Model trigger tooltip text is `<model name> · <shortcut>` (`ProviderModelPicker.tsx:197-199`). Traits shows the label. Access shows the mode description.

### 3.2 Model picker trigger

`chat/ProviderModelPicker.tsx:230-305`. A `ComposerControl size="sm"`: classes `min-w-0 shrink justify-between whitespace-nowrap -ms-2.5 min-w-13` (min width 52). Content: provider icon 16px (brand glyph, Claude is the asterisk, color from the provider, `ProviderInstanceIcon`), label (`getTriggerDisplayModelName`, e.g. "Claude Haiku 5.5"), 14px chevron. Icon to label gap 6. When the model is unavailable an outline "Unavailable" badge follows. Label truncates when space runs out (it shrinks before anything else, to 52px). Multi-model drafts show up to three overlapping 16px icons with `-space-x-1` and a 2px ring in the glass color, and the label becomes the first two names plus "N more" (`:177-195, 253-262`). Fits `ButtonView`-like drawing via the shared control (no existing component matches; `SelectView` trigger is close but is not this look).

Open state opens a `PopoverView` anchored left-aligned above the trigger (section 8.1).

### 3.3 Traits trigger

`chat/TraitsPicker.tsx:629-683`. Preceded by a separator. `ComposerControl size="sm"` with `shrink-0 whitespace-nowrap`, content: `BrainIcon` (lucide `brain`, 16px), label, chevron. The label comes from `buildTraitsTriggerDisplay` (`:494-566`): option labels joined by " · ", with a "Fast" speed suffix merged into the reasoning label. Reference: "Medium". Click opens a `MenuView` (section 8.3). Hidden entirely when the model has no trait descriptors (`shouldRenderTraitsControls`). Codex-style providers truncate the label at `max-w-40` (`sm:max-w-48`).

### 3.4 Access mode trigger

`ComposerFooterModeControls`, `ChatComposer.tsx:1255-1355`. Preceded by a separator. `ComposerSelectControl size="sm"` (`ComposerControl.tsx:110-127`), aria "Runtime mode", content: mode icon (16px) plus label plus chevron. Modes (`chat/runtimeModeConfig.ts:4-28`):

| Mode | Label | Icon (lucide) | Description |
|---|---|---|---|
| approval-required | Supervised | `lock` | Ask before commands and file changes. |
| auto-accept-edits | Auto-accept edits | `pen-line` | Auto-approve edits, ask before other actions. |
| auto | Auto | `sparkles` | Supported providers approve routine actions; others still ask. |
| full-access | Full access | `lock-open` | Allow commands and edits without prompts. |

Reference shows "Full access" with the open lock. The tooltip body is the description.

### 3.5 Plan / Build toggle (conditional)

Only when `planModeUiEnabled`. A separator plus `ComposerControl` with `aria-pressed` when in plan mode. Icons: `bot` 18px (`opticalSize="large"`) for Build, `pencil-ruler` 16px for Plan. Label "Build" or "Plan". Tooltip "Default mode - click to enter plan mode" / "Plan mode - click to return to normal build mode". Not visible in any reference (the reference server had plan mode off). Draw it but gate it.

### 3.6 Attach button and context meter

Attach: `Button variant="ghost" size="icon-sm"` (`ButtonView(.ghost, .iconSm)`: 28x28, radius 8), paperclip 16px, tooltip "Attach files" (`ChatComposer.tsx:7586-7615`). Shown when `showComposerAttachAction`. Reference 01/03a: icon at x = 975 css, send at 1012, so gap 8 between button boxes.

Context window meter (`ContextWindowMeter`): behind `contextWindowMeterEnabled`, default false (`packages/contracts/src/settings.ts:449`). Not in any reference, skip for M5 and reserve a slot when the meter placeholder renders (`reserveContextWindowMeter`).

### 3.7 Compact menu and overflow at narrow widths

Layout decision (`composerFooterLayout.ts:186-224`, `ChatComposer.tsx:5440-5470, 5473-5700`). The trailing blocks are `[traits (separator + trigger), mode (separator + trigger)]`. When the left cluster's content width exceeds its host width, step through:

1. Label of the last block hides (icon and chevron stay, `[data-composer-control-label]` goes `sr-only`-style invisible+absolute).
2. Label of the next block hides.
3. Last block moves into a "..." overflow menu.
4. Next block moves into it.
5. If still too wide, the model trigger shrinks to its minimum 52px.
6. If it still does not fit, the whole cluster hides (`visible: false`).

Promotion back needs 1px of slack to stop flicker (`RESTING_CONTROLS_SLACK_PX = 1`). Reference 04n shows step 1 for the access control at a 494 wide composer.

The overflow trigger is `ComposerControl size="sm"` with `ellipsis` (16px), aria "More composer controls" (`chat/CompactComposerControlsMenu.tsx:41-54`). Its `MenuPopup align="start"` holds, in order: traits content (when traits moved there) and a divider, a "Mode" label plus radio items Chat / Plan (only with plan UI), a divider, an "Access" label plus radio items (labels only, no descriptions). Group labels: `px-2 py-1.5 font-medium text-muted-foreground text-xs` (12/16, `muted`). Fits `MenuView` with radio items.

### 3.8 Resting (scroll-collapsed) layout

Applies only to an existing server thread whose timeline overflows, after the user scrolls the timeline by 24px (`COMPOSER_SCROLL_COLLAPSE_THRESHOLD_PX`, `ChatComposer.tsx:417`), with a single-line prompt and no expanded chrome, and `composerCollapseOnScroll` on (default true, `settings.ts:452`). Any interaction with the composer expands it again (`composerFooterLayout.ts:26-60`).

Resting values: body `py-2` (8/8), editor `max-h-8 min-h-8 leading-8 overflow-hidden whitespace-pre` (32px single line), footer becomes `absolute right-px bottom-px h-12` holding only attach and send, no left controls. Composer height = 1 + 8 + 32 + 8 + 1 = 50. The left controls move to `xs` size into the strip below the composer (a `ContextStrip` with `data-composer-model-strip`, or the git context strip when present), color `muted / 70%`, 12px.

The timeline inset keeps the expanded height while resting so a scroll to the end does not land under the re-expanded composer (`composerFooterLayout.ts:62-100`, minimum expansion 94px).

Transition between rests uses WAAPI at the user's panel animation duration, which defaults to 0 ms (`packages/contracts/src/settings.ts:121`), so by default the change is instant. See section 10. Recommend building the expanded layout first and the resting layout last (it does not show in any reference).

## 4. Primary action button

`chat/ComposerPrimaryActions.tsx`. All variants are 32px circles at desktop, except the pending-question variants (28px). Tooltips use `TooltipView`, default top.

### 4.1 Send (idle, no running turn)

`:310-355`. Classes: `relative isolate flex h-9 w-9 sm:h-8 sm:w-8 items-center justify-center overflow-hidden rounded-full shadow-xs transition-all duration-150`. So 32x32 at desktop, full radius.

Normal fill: `bg-message-action text-message-action-foreground` = `Palette.messageAction` (`#1b4ed8` / `#346bf1`) with `Palette.messageActionForeground` white. Hover `Palette.messageActionHover` (`#3160dc` / `#3061da`). Shadow `shadow-xs shadow-message-action/24` (`0 1px 2px 0` in `messageAction` at 24%) plus `inset-shadow-control-highlight` = `inset 0 1px rgb(255 255 255 / 16%)` when enabled (`index.css:188`). Hover `scale-105` over 150ms. Active: `inset 0 1px rgb(0 0 0 / 8%)` (`index.css:189`), shadow none (the scale stays at 1.05 on hover-and-press; there is no active scale-down).

Nightly or dev build variant (`useSidebarStageBackdropVariant`, `SidebarStageBackdrop.tsx:45-47`, `environmentIdentificationMode === "artwork"`): the fill is replaced by the stage art. Text `white`, shadow `black / 24%`, hover `brightness-110` instead of the fill change (`ComposerPrimaryActions.tsx:315-317`). The art is the same SVG as the sidebar header in compact mode: `viewBox="96 0 8192 96"`, `preserveAspectRatio="xMinYMin slice"`, so a 32px button shows the art region x 96 to 192, y 0 to 96 at scale 1/3 (`SidebarStageBackdrop.tsx:65-67, 100-116`). Our `StageBackdropView` (`Features/Sidebar/SidebarChromeViews.swift:29`) already draws the full-size art. Add a compact mode that crops it. References 01, 03a, 04 and 06 show this art (purple-blue gradient with a lighter lower left), because the reference server is a nightly. A stable build shows the flat blue. Decide which one we match, see section 11 item 2.

Icon: custom 14x14 arrow-up, path `M7 11.5V2.5M7 2.5L3 6.5M7 2.5L11 6.5`, stroke `currentColor` width 1.8, round caps and joins. Draw it directly (not lucide).

Disabled (`!hasSendableContent && !showResume`, or send disabled for any reason): `opacity-64`, `pointer-events-none`, `shadow-none`, `hover:scale-100`. The reference "composer at rest" (03a, 04, 13, 41, 42) shows exactly this: the button is disabled and looks washed out at 64%. That is why the art looks muted purple there, not a design color.

Busy: while `isConnecting || isSendBusy`, the arrow is replaced by `Spinner size="sm"` (`SpinnerView`), and the button is disabled.

Resume (when `canResume` and nothing to send): `play` icon, 16px, `fill-current`, enabled, type button, tooltip "Resume thread".

Editing a queued message: `check` icon 16px, aria "Update queued message".

Tooltip text (`:279-308`): "Submit message", "Queue message", "Steer message", "Resume thread", "Update queued message", "Compact and send", or the disabled reason ("Environment disconnected", "Connecting", "Preparing worktree", "Submitting message"). While running: "Click to queue, Ctrl/Cmd-click or <shortcut> to steer" (or the reverse, depending on the setting).

### 4.2 Stop (running turn, empty prompt)

`:134-159`, shown when `canInterrupt && !hasSendableContent && !isEditingQueuedMessage` (`:267`). 32x32 circle (`size-8`), fill `bg-destructive/90` = `Palette.destructive` (`#fb2c36` / `#fb414a`) at 90%, text white. Shadow `shadow-xs shadow-destructive/24` plus `inset-shadow-control-highlight`. Hover: fill `destructive` at 100% and `scale-105`. Active: pressed inset, shadow none. `transition-all 150ms`. Disabled when `!canOperateThread` (opacity 0.64, via the button base?). The class string has no explicit disabled style (`:141`), so check in the browser (section 11).

Icon: 12x12 box, filled square `x=2 y=2 w=8 h=8 rx=1.5`, `currentColor` (white). Tooltip "Interrupt". Reference 01 (dark) shows it as a bright rose circle (`#f23c4f`-like, which is `destructive` at 90% over the dark glass).

### 4.3 Queue and steer (running turn, prompt has content)

Same button as send (4.1), enabled, with the arrow replaced by a `MorphIcon` (the `morphicons` package) at 16px (`:341-342`):

- Queue (default setting `followUpBehavior: "queue"`, `settings.ts:458`): lucide `list-plus`.
- Steer (setting is steer, or Cmd/Ctrl held while the setting is queue): lucide `corner-up-right`.

The icon morphs between the two shapes when the modifier changes (`resolveComposerDispatchMode`, `alternateModifier: metaKey || ctrlKey`). Duration and easing belong to the `morphicons` library (not in the repo tree), see section 10. Fallback for Swift: cross-fade over 150ms.

### 4.4 Question and plan actions (labeled pills)

All share `messageActionPillClassName` (`:82`): `inline-flex gap-1.5 rounded-full bg-message-action font-medium text-base sm:text-sm text-message-action-foreground shadow-xs shadow-message-action/24 outline-none hover:bg-message-action-hover focus-visible:ring-2 ring-ring ring-offset-1 ring-offset-background disabled:opacity-64 disabled:shadow-none`.

| Where | Label | Height | Padding x |
|---|---|---|---|
| Pending question | "Next question" / "Submit answer" / "Submit answers"; compact: "Next" / "Submit"; busy: "Submitting..." | 28 (`sm:h-7`) | 16 (12 compact) |
| Plan follow-up with feedback text | "Refine" or "Sending..." | 32 (`sm:h-8`) | 16 (12 compact) |
| Plan follow-up, empty | "Implement" plus a joined chevron segment (`rounded-r-none` plus `rounded-l-none border-l border-message-action-foreground/20 px-2`, `chevron-down` 14px) opening a menu with "Implement in a new thread" | 32 | 16 / 8 |

For question state also: Stop appears first as a 28px circle (`size-8 sm:size-7`), then "Previous" (outline, `ButtonView(.outline, .sm)`, or in compact an `iconSm` button with `chevron-left` 14px), then the pill. Gap between them 8 (6 compact). Reference 06: Stop 28px at x = 1735 display, "Next" pill from 1772 to 1870, 28px tall, in `messageAction` dark blue (`#346bf1`) with white text. Attach sits at 1669.

The pill has no fixed width; the "Next" pill measured 98 display = 54 css wide for 14px "Next" + 2x12 padding... (text about 30 + 24 = 54). OK.

### 4.5 Compact-before-send chip

When a stale session has tokens to re-read (`compactBeforeSendTokens`, `:365-397`): a `h-7 rounded-full border px-2.5 text-xs tabular-nums gap-1.5` chip with `minimize-2` (14px) and "Compact 12k" / "Full 12k". Compact state: `border-warning/40 text-warning hover:bg-warning/8`. Full state: `border-border text-muted-foreground hover:text-foreground`. Sits left of the send button with gap 8. Not in references, build after the main states.

## 5. Running state (reference 01)

What changes in the composer while a turn runs (`phase === "running"`):

1. Primary action: send is replaced by Stop (4.2) when the prompt is empty. Typing content brings back the round button with `list-plus` (queue) or `corner-up-right` (steer).
2. Everything else stays: the editor remains enabled and focused (caret visible in reference 01), placeholder is the default string, model, traits and access controls stay active. (Disabled only when `isSendBusy` for the model picker, `ChatComposer.tsx:5521`.)
3. The attach button stays.
4. If queued messages exist, the "Queued" panel docks above (section 7).
5. No spinner, no border animation, no dimming on the composer. The "Working for 4s" line, "Thinking" rows and the sidebar spinner are timeline and sidebar chrome (H sections 3.x).

Reference 01 (dark): Stop at x = 1841/1.818 = 1013 css, 32px, same position as send. Nothing else differs from 03a.

## 6. Approval panel (05) and question panel (06)

Both are `ComposerBanner` attachments in the same dock above the composer (`ChatComposer.tsx:6738-6760` for approval, `:6761-6781` for question). Only one top drawer shows at a time.

### 6.1 Attached banner surface (shared)

`chat/ComposerBanner.tsx:37-71`. The banner is a rounded-top rectangle whose bottom 16px is hidden behind the composer.

- Position: `mx-auto w-[calc(100%-44px)]` with `-mb-[calc(1rem+1px)]` (-17px) so it slides 17px under the composer (`:111`).
- Radius: top corners `rounded-t-2xl` = 18 (`Tokens.Radius._2xl`), bottom square (hidden).
- Fill: `--chat-composer-attached-surface` = the composer glass color (`--card` light, `--surface-raised` dark) at 80% with 12px blur and 1.14 saturation. Plus the variant tint as a flat overlay: warning `Palette.warning` mix 8% (`#fd9a00` at 8%, `#fd990014`), error `Palette.error` 8%, others none.
- Outline: 1px, neutral variant = composer outline (`rgb(0 0 0 / 8%)` light, `white / 5%` dark). Warning `warning` at 28%, error `error` at 32%.
- Shadow: `shadow-composer` (light) or `shadow-composer-dark` `0 14px 32px -18px rgb(0 0 0 / 75%)` (dark).
- Bottom mask: the banner's background and outline are masked `to top`, fully transparent for the bottom 16px (`mask-t-from-4`, `mask-t-to-4`, compiled in `main.css` as `--tw-mask-top-from-position: calc(var(--spacing) * 4)`). The composer's own fill and outline cover that strip.
- Dark only: where the banner meets the composer, a 10px black shade at 18% fades upward from the 17px mark (`--background-image-composer-seam-above`, `index.css:207-214`), drawn on top of the tint layer.
- Adjacent attachments share an outline: the second one drops its top radius and top border (`:113-114`).
- Root padding: `px-1 py-1` (4px) default, `px-3 py-3` (12px) for `density="spacious"` (approval). `text-xs/4`. A hidden-bottom spacer of 17px (`after:h-(--chat-composer-attachment-overlap)`) pads the root.
- Row grid: `grid-cols-[24px_minmax(0,1fr)_auto]` (28px first column below 640 viewport), `gap-x-1`, `min-h-24`, `items-center`. Icon cell is centered with a 12px icon in `muted`.

Reference 05 (light): banner left at x = 605/1.818 = 333, composer left 311, so inset 22 ✓; banner top 1153 display = 634 css; composer top 1263 = 695, so 61 css visible above the composer.

### 6.2 Approval panel (05)

`chat/ComposerPendingApprovalPanel.tsx:38-67`, `chat/ComposerPendingApprovalActions.tsx:47-114`. Banner: `variant="warning" density="spacious"`, row `layout="approval"` (`items-start gap-x-2 gap-y-3`).

- Height: 12 + content + 12 + 17 hidden. Content = 16 (label) + 4 (gap) + 16 (detail line) = 36, so 77 total, 60 visible. Reference: 61 ✓.
- Icon cell: 24 wide, `pt-0.5`, `shield` lucide 16px (`size-4`) in `Palette.warning` (`#fd9a00` both modes).
- Label row: `text-2xs` (11/16) `muted`, `gap-2`. Kind label `font-medium text-warning`: "File change approval", "Command approval", "File read approval", "App permission approval", "App access approval". Then optional app name (truncate). Right: `1/N` `tabular-nums` when more than one is pending.
- Detail line: `max-h-20` (80px) scrollable, `text-xs` (12/16) `fg`. Command, file path and permission use mono (`DSFont.mono`, `white-space: pre`), app access uses sans with `pre-wrap`. Focus ring (keyboard) `ring-2 ring-inset ring-ring/70`. Thin horizontal scrollbar 6px. If the provider process is gone: "Provider process is gone - interrupt or restart the run to respond." (the source uses an em dash).
- Actions (right, `self-center gap-1.5`): "Decline" `ButtonView(.outline, .xs)`, "Approve" `ButtonView(.default, .xs)` (blue `Palette.primary`), then `ButtonView(.outline, .iconXs)` with `ellipsis` 14px opening a `MenuView` (top, end aligned) of the remaining decisions ("Cancel", "Always allow this session"; items `variant="ghost"`, `mb-1 last:mb-0`). Options with a `warning` show a 12px `triangle-alert` and a tooltip. Button text max width 160.
- Below 560px banner width (container query on the banner root), content spans columns 2 and 3 and the actions drop to a second row (`col-start-2 col-end-4 row-start-2`), right aligned, `gap-y-3`.
- Reference 05: Decline (outline) and Approve (blue) are 24px tall, the ellipsis button is a 24px square outline button.

The composer under it: editor readonly placeholder "Resolve this approval request to continue", no footer. Box height 66 (see 2.3).

### 6.3 Question panel (06)

`chat/ComposerPendingUserInputPanel.tsx:190-311`. Banner: `variant="info"` (neutral outline), default density. Whole header is a button (`Collapsible` trigger) toggling the body.

Header row (`ComposerBanner.Row` as button, 24px tall, `rounded-md`, focus `outline-2 outline-ring -outline-offset-2`):

- Empty icon cell (24px).
- Header text (`activeQuestion.header`, e.g. "Purpose"): `text-xs` `font-medium` `muted`. When collapsed, the question text follows, `secondaryLabel`, truncated.
- Right: `N/M` counter (`text-3xs` 10px medium `muted`, `tabular-nums`) when the prompt has more than one question, then a 24px ghost icon-xs button showing `chevron-down` 14px, rotated 180 when collapsed. Then, if dismissible, a ghost icon-xs `x` 14px (stops click bubbling).
- Title attribute: "Hide the question and its options" / "Show the question and its options".

Body (`ComposerBanner.Scroll`, `max-h-[min(24rem,40dvh)]` = 312 at a 780 window, scroll fade on overflowing edges, `radius none`): inner `ComposerBanner.Body` is `ps-7` (28; the icon column plus gap) `pe-1 pb-1`, `wrap-anywhere`.

- Question: `text-sm` (14/20) `fg / 85%`.
- Multi-select hint: "Select one or more options." `text-xs` `secondaryLabel`, `mt-1`.
- Options container: `mt-2 space-y-0.5` (gap 2).
- Option row (button): `flex w-full items-center gap-2 rounded-md px-2.5 py-2 text-left` (radius 8, padding 8 / 10). Colors: idle transparent, text `fg / 85%`; hover bg `muted / 30%`; selected bg `muted / 55%`, text `fg`. Focus `ring-1 ring-primary/25`. Transition `colors 150ms` (default easing). Disabled `opacity-50`, not-allowed cursor.
- Row content: label `text-sm font-medium` (14/20, weight 500), then optional description `text-2xs` (11/16) `secondaryLabel` under it, `gap-0.5` (2). Trailing: selected check (`check` 14px, `Palette.primary`) or, for the first nine options, the number key as a `kbd` box (`size-5` 20x20, `text-3xs` 10px medium, `muted`, `tabular-nums`, no border or fill). Hand-draw: this `kbd` has no chrome, so `KbdView` (which draws a chip) does not fit. Use a plain `LabelView` in a 20px box.
- Row height: label 20 + gap 2 + description 16 = 38, + 16 padding = 54 with a description, 36 without. Reference 06: rows 102 display px apart = 56 css (54 + 2 gap) ✓.

Keyboard: digits 1 to 9 select the matching option when focus is outside an editable field (`:157-182`). Single select auto-advances 200ms after the click (`:145-148`), showing the check immediately (optimistic). Multi select toggles in place and the footer "Next" / "Submit" button advances.

Reference 06 (dark): header "Purpose" and "1/2" and chevron at right, the question line at 662 display px (364 css). Options list shows four rows with numeric hints 1 to 4 at the right edge (x = 1810 display, 996 css, so right padding 10 inside the 20px kbd box, ending near the banner's right padding).

Composer under the question: editor writable with the free-text placeholder, the footer (with `pt-2`) shows model, traits, access on the left and attach, Stop (28px, red) and "Next" pill (28px) on the right.

## 7. Queued messages (29)

`chat/QueuedRunsControl.tsx`. Neutral `ComposerBanner.Root` (outline `rgb(0 0 0 / 8%)` / `white / 5%`) docked above the composer, with `z-0` (`:247`). It sits in the same column as other banners (stack order: queue above, banners above that, `ComposerBannerStack attachedAbove={queuedRunsControl}`, `ChatComposer.tsx:6711-6717`).

Header row (button, toggles expansion, `aria-expanded`): `list-ordered` lucide 12px in `muted` in the 24px icon cell, "Queued" `text-xs` `muted`, right: count (`min-w-6 font-medium muted tabular-nums`, centered in 24px) and the 24px ghost `chevron-down` toggle (rotates 180 when collapsed). Header height 24.

List (`ol`, `ComposerBanner.Children`): `grid gap-px`, scroll area `max-h-32` (128px) with scroll fade; hidden when collapsed (`!expanded && "hidden"`, no animation). Row `li` (`ComposerBanner.Row`) `relative rounded-sm` (6px), min height 20 but buttons are 24, so rows are 24px high with 1px between (reference 29: rows 45 and 46 display apart = 25 css ✓).

Row contents, left to right:

- Grip cell (24px): `Button ghost-muted icon-xs` with `grip-vertical` 14px, cursor grab, only when reorder is allowed (`canReorder`). Aria "Reorder queued message (drag, or press the arrow keys)". Drag arms from the grip only. Reference 29 shows a six-dot grip, `muted`.
- Content (`text-foreground/80`, `gap-1`): optional 12px `clock-3` `muted/60` while saving, optional 16px image thumbnails (`size-4`, `rounded` 4, 1px `border/70`, `object-cover`, gap 2), then the text `flex-1 truncate` 12px. Tooltip with the full text, `max-w-96`.
- Actions (`gap-1`): pencil `ButtonView(.ghostMuted, .iconXs)` with `pencil` 14px, tooltip "Edit in the composer (shortcut)"; "Steer" `ButtonView(.ghostMuted, .xs)` with `corner-up-right` 14px and label, tooltip "Send as a steer instead (shortcut)" or "There is no active run to steer" (disabled when `!canPromoteToSteer`); dismiss `ButtonView(.ghost, .iconXs)` with `x` 14px, tooltip "Remove from queue".
- Editing row: `bg-accent text-accent-foreground`, actions replaced by one "Cancel" ghost xs button.
- Drag feedback: dragged row `opacity-50`, insertion line `h-0.5 rounded bg-primary/70` at the row's top or the last row's bottom.

Height: header 24 + rows 24 each + 1px gaps + root padding 4 + 4 + hidden 17. Reference 29: panel top 973 display = 535 css, composer top 1120 = 616, so 81 visible = 4 + 24 + 25 + 24 + 4 = 81 ✓.

In reference 29 the composer shows Stop (empty prompt) while two messages are queued.

## 8. Pickers

### 8.1 Model picker (13)

Container: `PopoverView` (`ProviderModelPicker.tsx:285-319`), `align="start"`, `padding="none"`, class `before:hidden` (drops the usual glass pseudo-element). Anchored to the model trigger, side bottom with default flip, so it opens upward from the composer footer. Offset 4 (`sideOffset` default, `ui/popover.tsx:45`). Reference 13: popup left at x = 578 display = 318 css (trigger left edge), bottom at 1288 display = 708, trigger top 1297 = 713. Popup content is in `data-chat-composer-floating-layer`, so clicks do not collapse the composer.

Size: `w-screen max-w-90` = 360 wide, `max-h-86.5` = 346 tall (`ModelPickerContent.tsx:850`). Height fits content up to the cap. While searching, height freezes at the height when typing started (`:851-852`).

Layout: `flex-row`, left rail 44px, right main column.

Rail (`chat/ModelPickerSidebar.tsx:90-253`): `w-11` (44), `bg-muted/30` (`Palette.muted` at 30%; light `#fafafa` at 30%, dark `#ffffff08` at 30%), inner padding 4 and gap 4. Items:

- Favorites: 36x36 button (`aspect-square w-full`, radius 8), filled `star` 20px, `fg`. Under it a 1px divider `border-b border-border/70`.
- One 36x36 button per provider instance (radius 8), provider icon 24px (`size-6`, glyph `size-5`). Hover and keyboard focus bg `fg / 10%`. Disabled: opacity 0.5. Optional 14px sparkles "new" badge top right.
- Selected indicator: 3px wide, 20px tall bar, `Palette.primary`, `rounded-l-full`, at the rail's right edge, vertically centered on the selected button. It animates `top` over 200ms `ease-out` (`:112`). Reference 13: blue bar at the right of the Claude button (the blue bar at the popup's left in the screenshot is the markdown Note alert border behind the popup, not part of the picker).
- Tooltips left of the rail, side `left`, offset 8, showing the provider name or status.

Main column: `bg-muted/40` with `border-l border-border/70`.

- Search block (`ui/combobox.tsx:109-127`): `px-3 pt-2.5`, inner `border-b border-border/70 pb-1.5`, `-translate-y-px`. Focus turns the bottom border `Palette.ring` (150ms default colors transition). 16px `search` icon at `top-1.5 left-0`, `muted / 55%`. Input height 26, `ps-5` (20), 14px `sans` (`text-sm`), `fg`. Placeholder "Search models...". The input is focused when the popup opens (reference 13 shows the blue underline). Fits `ComboboxView` search style or a plain field.
- List: LegendList with `py-1.5`, content `pl-2 pr-px`, rows separated by a 2px spacer (`ModelListSeparator`, `h-0.5`). Height = content + 20 (`modelListHeight`, `:731-733`). Scroll fades top and bottom when there is more content. Right padding leaves a stable scrollbar gutter.
- Row (`chat/ModelListRow.tsx:45-154`, `ComboboxItem`): `rounded-sm` (6), `px-2 py-1`, min-h 28. Content: model name `text-xs font-medium leading-snug` (12px, 500, line 16.5) with an optional `NEW` badge, then `mt-1` and a line with the provider icon 12px, `gap-1.5`, provider name `text-xs font-normal leading-snug muted / 70%`. Row height = 16.5 + 4 + 16.5 + 8 = 45 (reference 13: highlighted row 1102 to 1183 display = 44.5 ✓). Right: `gap-1.5` group with optional check (14px, multi-select only), optional `Kbd` jump label (`KbdView`), and the favorite star: `ghost-muted icon-xs` button with `-mr-1`, star 12px (`sm:size-3`); favorite = `fill-current text-warning` (`#fd9a00`). Tooltip "Add to favorites" / "Remove from favorites".
- Row states: hover `accent`; highlighted (keyboard or mouse) `accent` with `accentForeground`; selected `fg / 8%`; both = `accent`; disabled opacity 0.64 with tooltip on the left. Reference 13: Claude Haiku 5.5 row highlighted (selected), light gray fill `#f4f4f5`-ish with a darker second line.
- NEW badge: `rounded border border-update/35 bg-update/15 px-0.5 py-px text-3xs font-bold uppercase leading-none tracking-wide text-update-foreground` (`Palette.update` `#1b4ed8` / `#346bf1` at 35% border and 15% fill; text `Palette.updateForeground` `#1b4ed8` / `#51a2ff`). 10px bold, letter spacing 0.025em, roughly 28 x 14. Matches `BadgeView` only roughly; draw it directly.
- "Legacy models" row (`:1000-1025`): name `text-xs font-medium`, below it "9 models" `text-xs muted/70`, and a 16px `chevron-right` that rotates 90deg when expanded (`transition-transform`, 150ms default).
- Footer areas: provider setup notices (`border-t border-border/70 p-2`, `max-h-44` scroll, `text-xs`) and update-required notices (`px-3 py-2 text-xs muted`). Empty: "No models found" (`text-sm muted`, `p-2`, centered).
- Selecting a row closes the popup (`handleInstanceModelChange`). In a draft with multi-model support, selection becomes a multi-toggle with checks.

Keyboard: Left arrow or Shift+Tab from an empty search moves focus to the rail; Right arrow from the rail returns to search; Escape closes; Enter picks the highlighted row (`ModelPickerContent.tsx:921-960`, `ModelPickerSidebar.tsx:96-103`).

### 8.2 ChatGPT sharing footer

Below the list, for a single-select picker, `ChatGptSharingControl` renders when a ChatGPT-backed provider is active (`ProviderModelPicker.tsx:317`). Not in reference 13. Skip until needed.

### 8.3 Traits picker (41)

`MenuView`, `MenuPopup align="start"`, opens upward from the trigger (flip). Offset 4. Reference 41: popup left at 913 display = 502 css (trigger left), width about 158 display... (913 to 1202 = 289 display = 159 css).

Content (`chat/TraitsPicker.tsx:371-486`), per select descriptor:

- Group label (`px-2 pt-1.5 pb-1 font-medium text-muted-foreground text-xs`, 12/16 `muted`), e.g. "Reasoning".
- Optional helper line `px-2 pb-1.5 text-muted-foreground/80 text-xs`.
- `MenuRadioGroup` items with `hideIndicator` and `closeOnClick`, so no check mark. The current item shows the standard highlighted fill (reference 41: "Medium" row has the `accent` fill). Item content: label, optional "Default" `BadgeView(.outline, .sm)` after a space, and an optional description under it (`text-xs muted/80`, `max-w-56`, `text-pretty`).
- Between descriptors: `MenuDivider`.
- Boolean descriptors render a label plus "On" / "Off" radio items (`:456-486`).

Reference 41 rows: Low, Medium (with "Default" badge, selected fill), High, Extra High, Max, Ultrathink. Row height about 51 display = 28 css, matching a standard `MenuView` item.

### 8.4 Access mode picker (42)

`Select` (`SelectView`) with `SelectPopup alignItemWithTrigger={false}` (so it opens beside the trigger like a menu, not over the selected item) (`ChatComposer.tsx:1325-1350`). Offset 4 (`ui/select.tsx:107`). Left edge aligned to the trigger's left edge: reference 42 trigger box at 1143 display, popup at 1143 ✓. Opens upward.

Items: `SelectItem hideIndicator className="min-w-64"` (min 256 wide). Content: row 1 icon 14px (`size-3.5`, `muted`) plus label `font-medium fg` with `gap-1.5`, row 2 description `text-xs leading-4` (12/16) `muted`, row gap 2. Popup width is set by the longest line: "Supported providers approve routine actions; others still ask." gives about 370 (reference 42: 1143 to 1815 display = 370 css). Selected item (Full access in the reference) shows the `accent` fill. Item height in the reference: 83 display = 46 css (20 + 2 + 16 + 8 padding).

Order: Supervised, Auto-accept edits, Auto, Full access (the config object order; `compatibleRuntimeModeOptions` can drop some per provider).

## 9. New-thread draft page (04, 04n)

Layout from top: header (52px, see H section 2), then the vertically centered stack (section 1.4), then empty space.

Stack, top to bottom, all centered in the lane:

1. Hero headline block (`chat/DraftHeroHeadline.tsx:331-385`), positioned `absolute inset-x-0 bottom-full` over the composer with `pb-4` (16) between (`ChatView.tsx:11525-11536`; the padding drops to 0 when a shoulder tab is present):
   - `h1`: `w-full text-center font-normal text-2xl sm:text-3xl text-foreground tracking-tight`. At desktop: 30px / 36px, weight 400, letter spacing -0.025em (`Tokens.Raw.trackingTight`), `fg`. Text "What should we build in {project}?" with the project name as a menu trigger.
   - Project name trigger: `InlineButton tone="picker"` (`ui/button.tsx:101-117`): `font-medium` (500), `gap-1.5`, `fg`, dotted underline `decoration-foreground/30`, `underline-offset-4`, `decoration-from-font`; hover or open: solid underline in full `fg`. `max-w-64` (256) with truncation. Reference 04: "demo-repo" is visibly heavier than the sentence, with a dotted underline.
   - Below, `mt-2 flex h-6 items-center text-sm` (8px gap, 24px tall, 14px): "or start without a project" as `InlineButton tone="muted"` (`muted`, hover `fg`, weight 500, underline on hover; tooltip with the shortcut). Reference 04: color `muted`, weight 500.
   - Other texts: no project chosen: "{Choose a project} to start"; scratch draft: "What should we work on?" with the project picker moved to the second line; no projects at all: "Add a project to start" (dotted-underline button `border-b border-dotted border-muted-foreground/35`).
   - Total block height 36 + 8 + 24 = 68.
2. Composer: standard (section 2), placeholder in the capture "Ask for changes, send follow-ups, or attach images" (see 2.5). Footer: model "Claude Fable 5.1" (the default for a new draft), traits "Medium", access "Full access", attach, send disabled.
3. Context strip below the composer (`BranchToolbar.tsx:758-863`, shown when `shouldShowComposerContextStrip` is true, i.e. a git repo or environment indicator, `BranchToolbar.logic.ts:67-81`). `ComposerSurface.ContextStrip` (`ComposerSurface.tsx:89-100`): `-mt-4` (slides 16px under the composer), width `calc(100% - 44px)` centered, `ps-1 pe-2 pt-5 pb-1`, `gap-2` (BranchToolbar overrides to `gap-1`), text `text-xs font-normal muted/70`. Its `::before` is a 1px outline (same colors as the composer outline) with `rounded-b-2xl` (18), bottom corners only, masked transparent over the top 16px (`mask-b-from-4`), `shadow-composer` (dark: `shadow-composer-dark` and the dark seam gradient `--background-image-composer-seam-below` plus `border-white/7`). Height: 20 + 24 + 4 = 48, net 32 below the composer (reference 04: strip bottom at 897 display, composer bottom at 840, 31 css ✓).
   Contents (xs `ComposerControl`s, 24px tall): left, workspace/run context "Current checkout" with `folder` 12px and a 12px chevron at 50% (menu: Current checkout / New worktree, environment items); right, branch selector "main" with `git-branch` 12px and 12px chevron (`ml-auto` at `@3xl`, container width 48rem = 768 and up). At narrow widths labels collapse to icons (`resolveContextStripLabelsCompact`, 16px hysteresis).
4. Bottom spacer 20.

Reference 04n (800px window, composer 494 wide): same stack; the headline stays 30px and fits in one line (about 450 css wide); the strip shows both "Current checkout" and "main" labels. The access label is gone (icon plus chevron, section 3.7).

The project menu (`DraftHeroHeadline.tsx:244-310`): `MenuPopup align="center"` `max-h-80` (320) scroll. `MenuRadioGroup` of project rows (16px favicon plus truncated name, optional environment badge), an optional "No project" row (dashed message icon, 16px), a separator, "Add project" `MenuItem` with `folder-plus`. Use `MenuView`.

The draft vs thread transition: when the first message sends, the draft hero state ends and the composer animates down to the docked position (section 10).

## 10. Motion

Motion in this area is sparse and mostly instant. Default easing `Tokens.Easing.defaultTransitionTimingFunction` = `cubic-bezier(.4,0,.2,1)`, default duration 150ms.

| What | Property | Duration | Easing | Source |
|---|---|---|---|---|
| Composer content fill when drag-over | `background-color` | 200ms | default | `ChatComposer.tsx:6906` |
| Send and stop button hover scale 1.05, fill, shadow | `all` | 150ms | default | `ComposerPrimaryActions.tsx:141, 314` |
| Question option row | `colors` | 150ms | default | `ComposerPendingUserInputPanel.tsx:264` |
| Question auto-advance after a single-select click | delay | 200ms | n/a | `ComposerPendingUserInputPanel.tsx:145-148` |
| Compact chip | `colors` | 150ms | default | `ComposerPrimaryActions.tsx:373` |
| Queue and steer icon swap | morph | library default | library default | `MorphIcon.tsx` (package `morphicons`, `reducedMotion="user"`) |
| Model picker selected-rail indicator | `top` | 200ms | `ease-out` (`Tokens.Easing.easeOut`) | `ModelPickerSidebar.tsx:112` |
| Search underline border color | `colors` | 150ms | default | `ui/combobox.tsx:112` |
| Legacy models chevron rotate | `transform` | 150ms | default | `ModelPickerContent.tsx:1011` |
| Banner stack row expand | `grid-template-rows` | 150ms | ease-out | `ComposerBannerStack.tsx:179` |
| Banner stack item enter or leave | `opacity, transform` | 150ms / 220ms | ease-out / ease-in | `ComposerBannerStack.tsx:186, 196, 224` |
| Banner peek | `opacity` | 150ms | ease-out | `ComposerBanner.tsx:97` |
| Attachment frame arrival (images) | `opacity, scale` from 0.95 | 300ms | `--ease-drawer` `cubic-bezier(.32,.72,0,1)` | `ChatComposer.tsx:404`, `index.css:190` |
| Control hover, open, focus (composer controls) | none | 0 | none | `ComposerControl.tsx:17-26` has no transition class |
| Queue panel expand and collapse | none | 0 | none (`hidden` class) | `QueuedRunsControl.tsx:271` |
| Question panel collapse | `Collapsible` panel | the `ui/collapsible` default | | `ComposerPendingUserInputPanel.tsx:246` |
| Resting composer to expanded and back | height, prompt, controls | `panelAnimationDurationMs` (setting, default 0, max 400) | `cubic-bezier(.32,.72,0,1)` | `ChatComposer.tsx:420, 681-830`, `settings.ts:112-121` |
| Draft hero to docked composer | `translate3d` | `panelAnimationDurationMs` (default 0) | `cubic-bezier(.4,0,.2,1)` | `ChatView.tsx:660-682`, `chat/draftHeroTransition.ts:2` |

Because `panelAnimationDurationMs` defaults to 0 (`settings.ts:121`), a default install shows no motion for the resting and hero transitions. Reduced motion also turns them off (`panelAnimations.ts:34-40`). For M5, make both instant and add the animations only if we expose the setting.

Popups (model picker, traits, access, overflow menus, tooltips) use the shared popup transitions already built into `PopoverView`, `MenuView`, `SelectView`, `TooltipView`. No composer-specific popup motion exists.

## 11. Gaps (measure in the browser)

1. Glass over scrolling text. The composer fill is `card` (light) or `surface-raised` (dark) at 80% over a 12px blur at saturation 1.14. Our substitution renders a solid 80% fill. Over thread text the 20% show-through will look different. Capture the composer over a text-heavy timeline in both themes and decide between a cheap blur (`CIGaussianBlur` layer filter on a snapshot), `NSVisualEffectView` with a tint, or a higher fill opacity.
2. Send button art. References 01, 03a, 04 show the nightly stage art inside the 32px button. A stable T3 shows the flat blue. Decide which to match, then crop `StageBackdropView` to the compact region (x 96 to 192 of the art, scale 1/3).
3. Stop button disabled style. The class string has no `disabled:` rule (`ComposerPrimaryActions.tsx:141`). Check whether `disabled` dims it through a base style.
4. Dark composer colors. Confirm the dark outline (white 5%) and the inner 3% top highlight with a zoomed 2x capture. Also confirm the dark shadow is truly absent.
5. Exact text positions inside the composer: placeholder baseline, footer text baseline, and button label baselines. Capture 2x crops at the composer and compare to the numbers in 2.3 and 3.1.
6. Draft placeholder text. Reference 04 shows the "disconnected" string. Check what a draft with a live connection shows (default string expected).
7. Resting layout. It needs a scrolled timeline in an existing thread and is not in any reference. Capture it (scroll the timeline by more than 24px, then screenshot the composer and the strip below) before building it.
8. Context strip on existing threads. `persistComposerContextStrip` (default not checked) and the model strip show only in some states. Capture an existing thread with the strip on.
9. Question panel multi-select state (footer Next, checks, "Select one or more options.") and the last-question label "Submit answer" are not in references.
10. Banner variants (provider status, errors, usage-limit recovery, tasks drawer, stash badge) share `ComposerBanner` but are not captured. Only the pieces in this file are specified.
11. Attachment previews inside the composer (images, files, snapshots, thread-context chips), `@` and `/` menus (14, 15), and inline chips (mention, skill, pasted text) are out of scope here. They need their own pass.
12. Model picker open states not captured: search with results, empty search, a locked provider, unavailable models, multi-select with checks, favorites tab. The rail's selected indicator animation and exact tooltip delay are also unmeasured.
13. Traits picker for other providers (Codex-style, boolean "Fast mode", ultrathink-in-body-text notice) are not captured.
14. `Collapsible` open/close animation for the question panel (see `ui/collapsible.tsx`) was not read. Check the duration when building it.
15. `morphicons` morph duration and easing for the queue and steer icon swap are in a package outside this tree. Measure in the browser or default to a 150ms cross-fade.
16. Mobile and touch layout (collapsed one-row composer, 16px editor font) is skipped on purpose.
17. The 22px composer radius is derived from `calc(var(--radius) + 12px)`. Confirm with a corner crop of reference 03a.
18. Focus ring on the editor. None is specified, but the keyboard focus order across the footer controls (each control draws a 2px ring with offset 1) should be checked against a keyboard-only capture.

### Component fit summary

| Piece | Existing component |
|---|---|
| Model, traits, access, overflow triggers | none (needs a new `ComposerControlView` on `ControlView` plus `BoxStyle`) |
| Footer separators | `SeparatorView` |
| Attach, edit, steer, dismiss, grip, toggle, star | `ButtonView` (`.ghost`, `.ghostMuted`, `.iconSm`, `.iconXs`, `.xs`) |
| Decline, Approve, ellipsis, Previous | `ButtonView` (`.outline`, `.default`, `.xs`, `.iconXs`) |
| Send, stop, question pill | none (custom circle and pill, see section 4) |
| Scroll to end pill | `ButtonView(.glass, .xs)` |
| Model picker container | `PopoverView`, search row from `ComboboxView` or `InputView` |
| Traits, overflow, project menus | `MenuView` |
| Access mode | `SelectView` |
| Tooltips | `TooltipView` |
| Key hint in model rows | `KbdView` |
| Default and unavailable badges | `BadgeView(.outline, .sm)` |
| NEW badge, option number | custom (see 8.1 and 6.3) |
| Banner surface (approval, question, queue) | none (new `ComposerBannerView` using `BoxStyle` with the bottom mask) |
| Question collapse | `CollapsibleView` |
| Spinner in send button | `SpinnerView` |
