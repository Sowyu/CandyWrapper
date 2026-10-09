# Component inventory, part B

Source: `/Users/mrm/CandyWrapper-research/t3code` at tag `v0.0.46-nightly.20261009.2861`, web UI in `apps/web`. All file:line citations are relative to `apps/web/src` unless a different root is given. Compiled CSS checks were done against the shipped `~/.t3/runtime/versions/0.0.46-nightly.20261009.2861/client/assets/main-pEuGmXiu.css`. Base UI runtime behaviour was checked in the shipped JS chunks in the same `assets` folder (named below as "bundle <file>").

Locked versions (`pnpm-lock.yaml`): @base-ui/react 1.5.0 (line 2217), tailwindcss 4.3.3 (11099), tailwind-merge 3.6.0 (11096), class-variance-authority 0.7.1 (7168), lucide and lucide-react 0.564.0 (9294, 9299), morphicons 1.7.1 (9688).

---

## 0. Global conventions (apply to every component below)

**Breakpoints (compiled CSS)**
- `sm:` compiles to `@media (width>=40rem)`, which is 640px. `md:` is `@media (width>=48rem)` (768px). `max-sm:` is `@media not all and (width>=40rem)`.
- A desktop window is nearly always 640px or wider, so the **`sm:` values are the desktop values**. Both are given below as "desktop (>=640)" and "narrow (<640)".
- Mobile layout (sidebar becomes a Sheet) is `useIsMobile()`. That is `max-width: 767px` (hooks/useMediaQuery.ts:3-11, 22-25, 85-87).

**Variant compilation**
- `hover:` compiles inside `@media (hover:hover)`.
- `dark:` is `:is(.dark,.dark *)` (index.css:3).
- Opacity modifiers such as `bg-input/64` compile to `color-mix(in oklab, var(--contrast-input) 64%, transparent)`, guarded by `@supports (color:color-mix(in lab, red, red))`, with the plain token as fallback.
- Mixing with `transparent` keeps the token colour and multiplies its alpha. Example: dark `--input` is white at 8%, so `bg-input/64` is white at 5.12% alpha.

**Colour utilities**
- Colour utilities read `--contrast-*` variables for foreground, border, input and the sidebar texts (index.css:221-276).
- At default appearance contrast (100, packages/contracts/src/settings.ts:111) every `--contrast-X` equals `X` (index.css:1521-1633).
- `*{border-color: var(--contrast-border)}` sets the default border colour (index.css:684-686).

**Focus ring recipe**
- The recipe is `focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background`. It compiles to:
  - `--tw-ring-offset-shadow: 0 0 0 1px var(--background)`
  - `--tw-ring-shadow: 0 0 0 calc(2px + 1px) var(--ring)`
- `box-shadow` composes as `var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)`.
- Visually this is a 1px background-coloured gap followed by a 2px band of `--ring`. `--ring` is `--primary` (index.css:1121). The element's own `shadow-*` still paints after the ring layers.

**Transitions**
- Default transition is 150ms `cubic-bezier(.4,0,.2,1)` (`--default-transition-duration: .15s`, `--default-transition-timing-function`).
- `ease-out` is `cubic-bezier(0,0,.2,1)`.

**Pseudo-elements and the `before` highlight layer**
- `before:` and `after:` utilities emit `content: var(--tw-content)`. Its `@property` initial value is `""`, so the pseudo-elements exist.
- A recurring "highlight line" is `before:shadow-[0_1px_--theme(--color-black/4%)]`, which compiles to `0 1px` with colour black 4% (no blur, no spread).
  - It sits on a `before:absolute before:inset-0` layer with radius equal to the control radius minus 1px.
  - In light mode it draws a crisp 1px line 1px below the padding box, darkening the bottom border by black 4%.
  - The dark counterpart `0 -1px` white 6% lightens the top border.

**Class merging**
- `cn()` is `twMerge(cx(...))`, with tailwind-merge extended so `text-2xs`, `text-3xs`, `text-4xs` and `text-5xs` count as font sizes (lib/utils.ts:10-14).
- cva 0.7.1 emits base, then variant groups in declared key order, then `className`.
- Classes with different modifiers are never merged. A base `sm:text-sm` therefore survives a size-level `text-xs`. Because media-query rules come later in the CSS, the `sm:` value wins at 640px and above. Verified offsets: `.text-xs` at byte 146161, `.sm\:text-sm` at 350183.

**Disabled and lucide**
- Disabled opacity everywhere is `.64` (`opacity-64` compiles to `opacity:.64`).
- Lucide icon defaults (bundle Icon-l19w4AjM.js): `width=24 height=24 viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width=2 stroke-linecap="round" stroke-linejoin="round"`.

**Shadows used here (compiled)**

| Utility | Compiled value |
|---|---|
| `shadow-xs` | `0 1px 2px 0 #0000000d` |
| `shadow-xs/5` | `0 1px 2px 0 rgb(0 0 0 / 5%)` (compiled as oklab(0% 0 0/.05)) |
| `shadow-xs/10` | `0 1px 2px 0 rgb(0 0 0 / 10%)` |
| `shadow-sm` | `0 1px 3px 0 #0000001a, 0 1px 2px -1px #0000001a` |
| `shadow-sm/5` | `0 1px 3px 0 rgb(0 0 0/5%), 0 1px 2px -1px rgb(0 0 0/5%)` |
| `shadow-xl` + `shadow-black/25` | `0 20px 25px -5px rgb(0 0 0/25%), 0 8px 10px -6px rgb(0 0 0/25%)` |
| `shadow-2xl` + `shadow-black/20` | `0 25px 50px -12px rgb(0 0 0/20%)` |

For the `shadow-black/N` rows, `--tw-shadow-alpha` keeps its `@property` initial value of 100%.

**Glass tokens**
- `--glass-blur`: 12px light, 16px dark (index.css:116, 146).
- `--glass-saturation`: 1.14 light, 1.08 dark (index.css:118, 147).
- `--glass-opacity`: 80% (index.css:117). It is set at runtime from the user setting `glassOpacity`, default 80 and range 40 to 100 (packages/contracts/src/settings.ts:94-103). At 100 the blur is forced to 0px (routes/__root.tsx:290-301).

**Scrollbar tokens**
- `--app-scrollbar-width: 6px`.
- Thumb `rgb(217 217 217)`, hover `rgb(191 191 191)`.
- Dark: thumb `rgb(255 255 255 / 8%)`, hover `rgb(255 255 255 / 12%)` (index.css:90, 95-96, 144-145).

**Geometry tokens (index.css:101-127)**
- `--control-radius .5rem` (8px)
- `--sidebar-content-inset .5rem` (8px)
- `--sidebar-control-gap .5rem` (8px)
- `--sidebar-row-content-inset .625rem` (10px)
- `--workspace-topbar-height 52px`
- `--workspace-titlebar-control-size 1.75rem` (28px)
- `--workspace-titlebar-control-gap .75rem` (12px)
- `--workspace-controls-left calc(env(safe-area-inset-left) + .75rem)`

**px conversions**
- All px values assume a 16px root.
- UNVERIFIED: the user "interface size" preference scales rem-based dimensions (packages/contracts/src/settings.ts:122-125). Its default was not checked.

---

## 1. Toggle (`components/ui/toggle.tsx`)

**Primitive and attributes**
- Primitive: `Toggle` from `@base-ui/react/toggle` (toggle.tsx:3).
- `data-slot="toggle"` (toggle.tsx:49).
- Base UI sets `data-pressed` and `aria-pressed` when pressed. The `pressed=\`data-pressed\`` mapping was verified in bundle utils-5_-Qnp8u.js.
- `toggleVariants` is exported (toggle.tsx:56). Defaults are `size: "default"` and `variant: "default"` (toggle.tsx:11-14).

**Base class (toggle.tsx:9), verbatim:**
```
[&_svg]:-mx-0.5 relative inline-flex shrink-0 cursor-pointer select-none items-center justify-center gap-2 whitespace-nowrap rounded-lg border font-medium text-base text-foreground outline-none transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 aria-disabled:opacity-64 data-pressed:bg-input/64 data-pressed:text-accent-foreground sm:text-sm [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
```

**Sizes (toggle.tsx:16-25), verbatim:**
- compact (17-18): `h-7 min-w-7 rounded-md px-[calc(--spacing(1)-1px)] text-xs before:rounded-[calc(var(--radius-md)-1px)] [&_svg:not([class*='size-'])]:size-3.5`
- default (19): `h-9 min-w-9 px-[calc(--spacing(2)-1px)] sm:h-8 sm:min-w-8`
- lg (20): `h-10 min-w-10 px-[calc(--spacing(2.5)-1px)] sm:h-9 sm:min-w-9`
- segmented (21-22): `h-6 min-w-0 rounded-md px-2.5 text-xs before:rounded-[calc(var(--radius-md)-1px)]`
- sm (23): `h-8 min-w-8 px-[calc(--spacing(1.5)-1px)] sm:h-7 sm:min-w-7`
- xs (24): `h-7 min-w-7 px-[calc(--spacing(1)-1px)] sm:h-6 sm:min-w-6 rounded-md`

**Variants (toggle.tsx:26-35), verbatim:**
- default (27): `border-transparent`
- pill (28): `border-transparent rounded-full px-3 font-normal text-muted-foreground data-pressed:text-foreground`
- ghost (29-30): `border-transparent text-foreground shadow-none [:disabled,:active,[data-pressed]]:shadow-none before:shadow-none data-pressed:bg-accent data-pressed:text-accent-foreground disabled:opacity-100 disabled:text-muted-foreground disabled:[&_svg]:opacity-100`
- outline (31-32): `border-input bg-background not-dark:bg-clip-padding shadow-xs/5 not-disabled:not-active:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:data-pressed:bg-input dark:hover:bg-input/64 dark:not-disabled:not-active:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] dark:not-disabled:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/2%)] [:disabled,:active,[data-pressed]]:shadow-none`
- segmented (33-34): `border-transparent text-muted-foreground shadow-none transition-colors before:shadow-none hover:bg-background/55 hover:text-foreground data-pressed:bg-background data-pressed:text-foreground data-pressed:shadow-xs/10 dark:hover:bg-input/32 dark:data-pressed:bg-input/72`

**Base resolved**
- Layout: inline-flex, centred, gap 8px. Radius 10px (`rounded-lg`). Border 1px; its colour depends on the variant (transparent except outline).
- Text: weight 500, colour `--contrast-foreground`.
  - Narrow: 16px/24px.
  - Desktop: 14px/20px (`sm:text-sm`).
- Transitions: `transition-property: box-shadow`, 150ms.
- Before layer: `absolute inset-0`, radius `calc(var(--radius-lg) - 1px)` = 9px, no pointer events.
- Icons:
  - `margin-inline: -2px` (`[&_svg]:-mx-0.5`), no pointer events, shrink 0.
  - Size 18px narrow and 16px desktop, unless the svg has a `size-` class.
  - Opacity .8 unless the svg has an `opacity-` class.
- Touch: `pointer-coarse` adds a 44x44px `after` hit area. This is irrelevant with a fine pointer.

**Base states**
- Hover (hover-capable pointers): bg `--accent`.
  - Light: zinc-100.
  - Dark: white 4%.
- Pressed (`data-pressed`): bg `--contrast-input` at 64%, text `--contrast-accent-foreground`.
  - Light: zinc-300 at 64% alpha, text zinc-900.
  - Dark: white at 5.12% alpha, text neutral-100.
  - Pressed beats hover: the data-pressed rules come later in the CSS at equal specificity (offset 320805 vs 273814).
- Focus-visible: the ring recipe from section 0.
- Disabled (`:disabled` or `aria-disabled=true`): opacity .64, `pointer-events: none` (for `:disabled`).

**Sizes resolved**

| size | height desktop / narrow | min-width desktop / narrow | padding-inline | radius (before radius) | font desktop / narrow | svg desktop / narrow |
|---|---|---|---|---|---|---|
| default | 32 / 36 | 32 / 36 | 7px | 10 (9) | 14/20 / 16/24 | 16 / 18 |
| sm | 28 / 32 | 28 / 32 | 5px | 10 (9) | 14/20 / 16/24 | 16 / 18 |
| xs | 24 / 28 | 24 / 28 | 3px | 8 (9, not overridden) | 14/20 / 16/24 | 16 / 18 |
| lg | 36 / 40 | 36 / 40 | 9px | 10 (9) | 14/20 / 16/24 | 16 / 18 |
| compact | 28 / 28 | 28 / 28 | 3px | 8 (7) | 14/20 / 12/16 | 16 / 14 |
| segmented | 24 / 24 | 0 | 10px | 8 (7) | 14/20 / 12/16 | 16 / 18 |

Note on compact and segmented: the size-level `text-xs` and `[&_svg...]:size-3.5` only win below 640px. At 640px and above the base `sm:text-sm` and `sm:[&_svg:not([class*='size-'])]:size-4` survive tailwind-merge and win by source order:
- `.text-xs` at 146161, `.sm\:text-sm` at 350183.
- `[&_svg]:size-3.5` at 411308, `sm:[&_svg]:size-4` at 412741.

No ToggleGroup call site overrides this (checked DiffPanel.tsx:978, usage/UsagePage.tsx:418/435/801, settings/DiagnosticsSettings.tsx:540, pullRequest/PullRequestDetailLayout.tsx:86). Rendered size at runtime is UNVERIFIED but follows from the compiled CSS.

**Variants resolved, per state**

*default*
- Border transparent. All base states apply.

*pill*
- Radius 9999px, padding-inline 12px (overrides the size padding), weight 400, text `--contrast-muted-foreground` (light zinc-500).
- Pressed: text foreground, bg input at 64% (from base).
- Hover: bg accent.

*ghost*
- Border transparent, text foreground, no shadows on the element or the before layer.
- Pressed: bg `--accent`, text accent-foreground.
- Disabled:
  - Opacity 1 (overrides .64), text muted-foreground, svg opacity 1, still no pointer events.
  - `aria-disabled` keeps opacity .64, because the modifier differs.

*outline, light*
- Border `--contrast-input` (zinc-300).
- Background:
  - bg `--background` (zinc-25) with `background-clip: padding-box` (`not-dark` only).
  - Hover bg accent (zinc-100); pressed bg zinc-300 at 64%.
- Shadows:
  - `shadow-xs/5`, removed when `:disabled`, `:active` or pressed.
  - Before line `0 1px` black 4% while not disabled, not `:active` and not pressed.

*outline, dark*
- Border white 8%.
- Background:
  - bg input at 32% (white 2.56%).
  - Hover input at 64% (white 5.12%).
  - Pressed input at 100% (white 8%).
- Before line:
  - `0 -1px` white 6% while not disabled, not active and not pressed.
  - While `:active` (not pressed) the weaker rule applies: `0 -1px` white 2%.
  - The 6% rule has higher specificity, (0,5,0) vs (0,4,0).

*segmented*
- Default: border transparent, text muted-foreground, no shadow. Transition is `transition-colors` 150ms; it replaces `transition-shadow`, so the shadow change is not animated.
- Light:
  - Hover: bg background at 55% (zinc-25 at 55%), text foreground.
  - Pressed: bg `--background` (zinc-25), text foreground, shadow `0 1px 2px 0 rgb(0 0 0/10%)`.
- Dark (dark rules are later and more specific):
  - Hover: bg input at 32% (white 2.56%).
  - Pressed: bg input at 72% (white 5.76%).
  - Text as in light.

**Animations**
- None besides the 150ms box-shadow (or colors) transition. No press scale.

**Theme note**
- With a named theme (`html[data-theme-id]`), toggles inside `[data-panel-layout-controls]` or `[data-workspace-titlebar-controls]` take the toolbar foreground (index.css:1408-1426). Default theme unaffected.

---

## 2. ToggleGroup (`components/ui/toggle-group.tsx`)

**Primitive and attributes**
- Primitive: `ToggleGroup` from `@base-ui/react/toggle-group` (toggle-group.tsx:4).
- `data-slot="toggle-group"` (42), `data-size` (41), `data-variant` (43).
- `orientation` defaults to `"horizontal"` (20).
- Exports `ToggleGroup`, `Toggle`, `ToggleGroupItem` (78).

**Defaults and context**
- `variant = "segmented"` (18).
- `size = variant === "segmented" ? "segmented" : "default"` (19).
- Children inherit size and variant through `ToggleGroupContext` (11-14, 24, 47). The child `Toggle` forwards `data-size` and `data-variant` (52-76).
- Context default outside a group is `{size: "default", variant: "default"}` (11-14).

**Classes (toggle-group.tsx:27-39), verbatim:**
- Always (28): `flex w-fit *:focus-visible:z-10 dark:*:[[data-slot=separator]:has(+[data-slot=toggle]:hover)]:before:bg-input/64 dark:*:[[data-slot=separator]:has(+[data-slot=toggle][data-pressed])]:before:bg-input dark:*:[[data-slot=toggle]:hover+[data-slot=separator]]:before:bg-input/64 dark:*:[[data-slot=toggle][data-pressed]+[data-slot=separator]]:before:bg-input`
- Horizontal (30): `*:pointer-coarse:after:min-w-auto`. Vertical (31): `*:pointer-coarse:after:min-h-auto`.
- segmented (33): `gap-0.5 rounded-lg bg-input/40 p-0.5`
- default (35): `gap-0.5`
- Other variants, horizontal (37): `*:not-first:not-data-[slot=separator]:before:-start-[0.5px] *:not-last:not-data-[slot=separator]:before:-end-[0.5px] *:not-first:rounded-s-none *:not-last:rounded-e-none *:not-first:border-s-0 *:not-last:border-e-0 *:not-first:before:rounded-s-none *:not-last:before:rounded-e-none`
- Other variants, vertical (38): `*:not-first:not-data-[slot=separator]:before:-top-[0.5px] *:not-last:not-data-[slot=separator]:before:-bottom-[0.5px] flex-col *:not-first:rounded-t-none *:not-last:rounded-b-none *:not-first:border-t-0 *:not-last:border-b-0 *:not-first:before:rounded-t-none *:not-last:before:rounded-b-none *:data-[slot=toggle]:not-last:before:hidden dark:*:last:before:hidden dark:*:first:before:block`

**Resolved**

*Segmented track (the default group)*
- Padding 2px, gap 2px, radius 10px.
- bg input at 40%: light zinc-300 at 40%; dark white 3.2%.
- Each item is a segmented toggle (section 1): 24px tall, radius 8px.
- Total control height is 28px.

*default variant*
- 2px gap, no track.

*outline, ghost and pill (joined bar)*
- Adjoining radii are removed.
- Inner borders collapse: `border-inline-start: 0` on non-first items, `border-inline-end: 0` on non-last items.
- The before layers extend by 0.5px into the seam.

*Common*
- The focus-visible child is raised to `z-index: 10`.
- Dark mode only: a `Separator` adjacent to a hovered toggle gets a before layer of input at 64%; adjacent to a pressed toggle it gets input at 100%.

---

## 3. Switch (`components/ui/switch.tsx`)

**Primitive and attributes**
- Primitive: `Switch.Root` and `Switch.Thumb` from `@base-ui/react/switch` (switch.tsx:3).
- Slots and attributes:
  - `data-slot="switch"` (28) and `data-slot="switch-thumb"` (42).
  - `data-size` (27).
  - `data-mixed=""` when `mixed` (29).
  - `aria-checked="mixed"` is spread only when mixed (33).
- Base UI sets `data-checked` / `data-unchecked` and `data-disabled` on the root and thumb.
- Props: `size?: "default" | "sm"` (default `"default"`, 14) and `mixed?: boolean` (default false, 15).
- The mixed state is presentational, per the doc comment at 7-11.

**Root (switch.tsx:21), verbatim:**
```
inline-flex h-[calc(var(--thumb-size)+2px)] w-[calc(var(--thumb-size)*2-2px)] shrink-0 cursor-pointer items-center rounded-full p-[2px] outline-none transition-[background-color,box-shadow] duration-200 focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background data-checked:bg-primary data-unchecked:bg-input data-disabled:cursor-not-allowed data-disabled:opacity-64 data-[mixed]:bg-input
```

**Size classes (22-24), verbatim:**
- sm: `[--thumb-size:--spacing(4)] sm:[--thumb-size:--spacing(3.5)]`
- default: `[--thumb-size:--spacing(5)] sm:[--thumb-size:--spacing(4)]`

**Thumb (38), verbatim:**
```
pointer-events-none block size-[calc(var(--thumb-size)-2px)] shrink-0 origin-left in-[[role=switch]:active,[data-slot=label]:active,[data-slot=field-label]:active]:not-data-disabled:scale-x-110 in-[[role=switch]:active,[data-slot=label]:active,[data-slot=field-label]:active]:rounded-[var(--thumb-size)/calc(var(--thumb-size)*1.1)] rounded-(--thumb-size) bg-background shadow-sm/5 will-change-transform [transition:translate_.15s,border-radius_.15s,scale_.1s_.1s,transform-origin_.15s] data-checked:origin-right data-checked:translate-x-[calc(var(--thumb-size)-4px)]
```

**Mixed thumb addition (39-40), verbatim:**
```
translate-x-[calc((var(--thumb-size)-4px)/2)] opacity-70 data-checked:translate-x-[calc((var(--thumb-size)-4px)/2)]
```
tailwind-merge replaces the checked translate with the half value.

**Geometry (T = `--thumb-size`)**
- Track: height T+2, width 2T-2, padding 2px, radius 9999px, no border.
- Thumb: (T-2) square, radius T (fully round).
- Checked translate: T-4. Mixed translate: (T-4)/2.

| size | viewport | T | track (W x H) | thumb | checked translate | mixed translate |
|---|---|---|---|---|---|---|
| default | desktop | 16px | 30 x 18 | 14 | 12px | 6px |
| default | narrow | 20px | 38 x 22 | 18 | 16px | 8px |
| sm | desktop | 14px | 26 x 16 | 12 | 10px | 5px |
| sm | narrow | 16px | 30 x 18 | 14 | 12px | 6px |

**Colours**

*Track*
- Checked: `--primary`.
  - Light: oklch(0.488 0.217 264).
  - Dark: oklch(0.571 0.21 264).
- Unchecked: `--contrast-input`. Light zinc-300; dark white 8%.
- Mixed: input. It is later in the CSS than `data-checked` (offset 328582 vs 313508), so it wins even when checked.

*Thumb*
- bg `--background`: light zinc-25; dark neutral-950 (as coded, a near-black thumb in dark).
- Shadow: `0 1px 3px 0 rgb(0 0 0/5%), 0 1px 2px -1px rgb(0 0 0/5%)`.
- Mixed thumb: opacity .7.

**States**
- Focus-visible: ring recipe on the track.
- Disabled: opacity .64, `cursor: not-allowed`.
- Press:
  - Applies while the switch, a `[data-slot=label]` or a `[data-slot=field-label]` ancestor is `:active`, and the switch is not disabled.
  - The thumb gets `scale: 110% 1`, horizontal stretch only.
  - Transform origin is left when unchecked and right when checked.
  - Border radius becomes `var(--thumb-size)/calc(var(--thumb-size) * 1.1)`.

**Animation**
- Track: `transition-property: background-color, box-shadow`, 200ms, `cubic-bezier(.4,0,.2,1)`.
- Thumb: `transition: translate .15s, border-radius .15s, scale .1s .1s, transform-origin .15s`.
  - No timing function is given, so the CSS default `ease` applies.
  - Scale has a 100ms delay.
  - Plus `will-change: transform`.

---

## 4. Checkbox (`components/ui/checkbox.tsx`)

**Primitive and attributes**
- Primitive: `Checkbox.Root` and `Checkbox.Indicator` from `@base-ui/react/checkbox` (checkbox.tsx:3).
- `data-slot="checkbox"` (14), `data-slot="checkbox-indicator"` (19).

**Root (11), verbatim:**
```
relative inline-flex size-4.5 shrink-0 items-center justify-center rounded-[.25rem] border border-input bg-background not-dark:bg-clip-padding shadow-xs/5 outline-none ring-ring transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[3px] not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] focus-visible:ring-2 focus-visible:ring-offset-1 focus-visible:ring-offset-background aria-invalid:border-destructive/36 focus-visible:aria-invalid:border-destructive/64 focus-visible:aria-invalid:ring-destructive/48 data-disabled:opacity-64 sm:size-4 dark:not-data-checked:bg-input/32 dark:aria-invalid:ring-destructive/24 dark:not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)] [[data-disabled],[data-checked],[aria-invalid]]:shadow-none
```

**Indicator (18), verbatim:**
```
-inset-px absolute flex items-center justify-center rounded-[.25rem] text-primary-foreground data-unchecked:hidden data-checked:bg-primary data-indeterminate:text-foreground
```

**Glyphs (rendered through the indicator's `render`, 20-54)**
- svg class `size-3.5 sm:size-3`, `viewBox="0 0 24 24"`, `fill="none"`, `stroke="currentColor"`, `strokeWidth="3"`, round caps and joins.
- Check path (50): `M5.252 12.7 10.2 18.63 18.748 5.37`.
- Indeterminate path (35): `M5.252 12h13.496`.

**Resolved**

*Box*
- Size 16px desktop, 18px narrow. Radius 4px.
- Border 1px `--contrast-input`: light zinc-300; dark white 8%.

*Unchecked, light*
- bg `--background` (zinc-25), `background-clip: padding-box`.
- Shadow `0 1px 2px 0 rgb(0 0 0/5%)`.
- Before layer: radius 3px, line `0 1px` black 4%.

*Unchecked, dark*
- bg input at 32% (white 2.56%).
- Before line `0 -1px` white 6%.

*Checked*
- The indicator covers the border box (`inset: -1px`), radius 4px, bg `--primary`, glyph colour `--primary-foreground` (white).
- Glyph size: 12px desktop (stroke renders 1.5px), 14px narrow (1.75px).
- The root's outer shadow is removed.

*Indeterminate*
- Base UI sets neither `data-checked` nor `data-unchecked` when indeterminate. Verified in bundle checkbox-B-SwCw9E.js: `checked(t){return e.indeterminate?{}:t?{[data-checked]:""}:{[data-unchecked]:""}}`.
- So the indicator is visible with no bg and the dash is drawn in `--contrast-foreground`.
- The root keeps the unchecked look (border, bg, before line) and gets `data-indeterminate`.

*Unchecked indicator*
- `display: none`.

*Focus-visible*
- Ring recipe (`ring-ring` is on the root).

*Invalid (`aria-invalid=true`)*
- Border destructive at 36%. The outer shadow and the before line are removed.
- Focus-visible plus invalid: border destructive at 64%, ring destructive at 48%.
- In dark, `dark:aria-invalid:ring-destructive/24` has equal specificity and comes later (offset 395034 vs 312009), so the dark focus ring is destructive at 24%.

*Disabled*
- Opacity .64, shadows removed.

**Animation**
- Only the 150ms box-shadow transition. No classes animate the indicator; it appears and disappears instantly.

---

## 5. Radio and RadioGroup (`components/ui/radio-group.tsx`)

**Primitives and attributes**
- Primitives: `Radio` from `@base-ui/react/radio` (3) and `RadioGroup` from `@base-ui/react/radio-group` (4).
- Slots: `data-slot="radio-group"` (12), `"radio"` (25), `"radio-indicator"` (30).
- Exports `RadioGroup`, `Radio`, `RadioGroupItem` (36).

**RadioGroup (11)**
- `flex flex-col gap-3`: vertical, 12px gap.

**Radio root (22), verbatim:**
```
relative inline-flex size-4.5 shrink-0 items-center justify-center rounded-full border border-input bg-background not-dark:bg-clip-padding shadow-xs/5 outline-none transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-full not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background aria-invalid:border-destructive/36 focus-visible:aria-invalid:border-destructive/64 focus-visible:aria-invalid:ring-destructive/48 data-disabled:opacity-64 sm:size-4 dark:not-data-checked:bg-input/32 dark:aria-invalid:ring-destructive/24 dark:not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)] [[data-disabled],[data-checked],[aria-invalid]]:shadow-none
```

**Indicator (29), verbatim:**
```
-inset-px absolute flex size-4.5 items-center justify-center rounded-full before:size-2 before:rounded-full before:bg-primary-foreground data-unchecked:hidden data-checked:bg-primary sm:size-4 sm:before:size-1.5
```

**Resolved**
- The circle is 16px desktop and 18px narrow.
- Border, background, shadows, focus, invalid and disabled behave exactly as the checkbox, but round.
- Checked:
  - The indicator covers the border box with a `--primary` disc.
  - The centre dot (`before`) is 6px desktop, 8px narrow, `--primary-foreground` (white), centred by flex.
- Unchecked: indicator hidden.
- No animation beyond the 150ms box-shadow transition.

---

## 6. Badge (`components/ui/badge.tsx`)

**Primitive and attributes**
- No Base UI component. It uses `useRender` and `mergeProps` from `@base-ui/react` (badge.tsx:3-4, 50-60) and renders a `span` by default; the `render` prop can make it a button or link.
- `data-slot="badge"` (53).
- Defaults: size `"default"`, variant `"default"` (12-15).
- `badgeVariants` is exported (64).

**Base (10), verbatim:**
```
relative inline-flex shrink-0 items-center justify-center gap-1 whitespace-nowrap rounded-sm border border-transparent font-medium outline-none transition-shadow focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='size-'])]:size-3.5 sm:[&_svg:not([class*='size-'])]:size-3 [&_svg]:pointer-events-none [&_svg]:shrink-0 [button&,a&]:cursor-pointer [button&,a&]:pointer-coarse:after:absolute [button&,a&]:pointer-coarse:after:size-full [button&,a&]:pointer-coarse:after:min-h-11 [button&,a&]:pointer-coarse:after:min-w-11
```

**Sizes (17-26), verbatim:**
- control (18-19): `h-7 min-w-7 rounded-[var(--control-radius)] px-[calc(--spacing(2)-1px)] text-sm sm:h-6 sm:min-w-6 sm:text-xs`
- default (20-21): `h-5.5 min-w-5.5 px-[calc(--spacing(1)-1px)] text-sm sm:h-4.5 sm:min-w-4.5 sm:text-xs`
- lg (22): `h-6.5 min-w-6.5 px-[calc(--spacing(1.5)-1px)] text-base sm:h-5.5 sm:min-w-5.5 sm:text-sm`
- sm (25): `h-5 min-w-5 rounded-[.25rem] px-[calc(--spacing(1)-1px)] text-xs leading-none sm:h-4 sm:min-w-4 sm:text-[.625rem]`

**Variants (27-40), verbatim:**
- default (28): `bg-primary text-primary-foreground [button&,a&]:hover:bg-primary/90`
- destructive (29): `bg-destructive text-white [button&,a&]:hover:bg-destructive/90`
- error (30): `bg-destructive/8 text-destructive-foreground dark:bg-destructive/16`
- info (31): `bg-info/8 text-info-foreground dark:bg-info/16`
- outline (32-33): `border-input bg-background text-foreground dark:bg-input/32 [button&,a&]:hover:bg-accent/50 dark:[button&,a&]:hover:bg-input/48`
- secondary (34): `bg-secondary text-secondary-foreground [button&,a&]:hover:bg-secondary/90`
- success (35): `bg-success/8 text-success-foreground dark:bg-success/16`
- warning (36): `bg-warning/8 text-warning-foreground dark:bg-warning/16`
- label (38-39): `bg-[color-mix(in_srgb,var(--label)_8%,transparent)] text-[color-mix(in_srgb,var(--label)_30%,var(--color-foreground))] dark:bg-[color-mix(in_srgb,var(--label)_12%,transparent)] dark:text-[color-mix(in_srgb,var(--label)_45%,var(--color-foreground))]`

**Base resolved**
- inline-flex, gap 4px, nowrap, radius 6px (`calc(var(--radius) - 4px)`), border 1px transparent, weight 500.
- 150ms box-shadow transition, ring recipe on focus-visible, disabled opacity .64.
- svg: 12px desktop, 14px narrow, opacity .8.
- `cursor: pointer` only when rendered as `button` or `a`. The compiled selectors are `button.<cls>` and `a.<cls>`.

**Sizes resolved**

| size | height desktop / narrow | min-width | padding-inline | radius | font desktop / narrow |
|---|---|---|---|---|---|
| default | 18 / 22 | 18 / 22 | 3px | 6px | 12/16 / 14/20 |
| sm | 16 / 20 | 16 / 20 | 3px | 4px | 10px, line-height 1 / 12px, line-height 1 |
| lg | 22 / 26 | 22 / 26 | 5px | 6px | 14/20 / 16/24 |
| control | 24 / 28 | 24 / 28 | 7px | 8px | 12/16 / 14/20 |

**Variants resolved (light / dark)**
- default: bg primary, text white. Hover (button or link only): primary at 90%.
- destructive: bg `--destructive`, text white; hover 90%.
  - Light: red-500.
  - Dark: `color-mix(in srgb, red-500 90%, white)`.
- error: bg destructive at 8% light, 16% dark. Text `--destructive-foreground`: red-700 light, red-400 dark.
- info: bg `--info` (blue-500 in both themes) at 8% light, 16% dark. Text blue-700 light, blue-400 dark.
- success: emerald-500 at 8% / 16%. Text emerald-700 / emerald-400.
- warning: amber-500 at 8% / 16%. Text amber-700 / amber-400.
- outline:
  - Light: border input (zinc-300), bg background (zinc-25), text foreground. Hover (button or link): accent at 50%.
  - Dark: bg input at 32%. Hover input at 48% (white 3.84%).
- secondary: bg `--secondary`, text `--contrast-secondary-foreground`, hover secondary at 90%.
  - Light: zinc-50, text zinc-800.
  - Dark: white 3%, text neutral-100.
- label:
  - Background: `color-mix(in srgb, var(--label) 8%, transparent)`; dark 12%.
  - Text: `color-mix(in srgb, var(--label) 30%, var(--color-foreground))`; dark 45%.
  - `--color-foreground` is `--contrast-foreground`; `--label` is set inline by the consumer.

---

## 7. Alert (`components/ui/alert.tsx`)

**Element and attributes**
- Plain `div`, no Base UI.
- `data-slot="alert"` (84), `data-variant` (85, `"default"` when unset), `role="alert"` (86).
- Children are routed into icon, content and action columns by `data-slot` or displayName (32-79).

**cva (7-30), verbatim**
- Base: `relative rounded-xl border px-3.5 py-3 text-card-foreground text-sm`
- surface: default `""`; glass `alert-glass`.
- variant default (19): `bg-transparent dark:bg-input/32 [&_svg]:text-muted-foreground`
- variant sidebar (20-21): `rounded-lg border-sidebar-border bg-sidebar-control-surface px-2 py-1.5 text-[11px] leading-4 [&_[data-slot=alert-description]]:block [&_[data-slot=alert-description]]:text-sidebar-muted-foreground`
- variant error (22-23): `border-error/32 bg-error-surface text-error-foreground [&_[data-slot=alert-description]]:text-error-foreground/80 [&_svg]:text-error`
- variant info (24): `border-info/32 bg-info/4 [&_svg]:text-info`
- variant success (25): `border-success/32 bg-success/4 [&_svg]:text-success`
- variant warning (26-27): `border-warning/32 bg-warning-surface text-warning-foreground [&_[data-slot=alert-description]]:text-warning-foreground/80 [&_svg]:text-warning`

**Layout (89-122)**
- Row: `flex gap-2` (8px), plus `items-center`. With `controlAlignment="first-line"` it is `items-start`, and with actions it adds `min-h-7 pt-1 sm:min-h-6 sm:pt-0.5`: min-height 24px and padding-top 2px on desktop (28px and 4px narrow).
- Icon box:
  - Centre alignment: `flex shrink-0 items-center justify-center` plus `size-4 [&>svg]:size-full` (16px).
  - First-line alignment: `h-lh w-4 [&>svg]:size-4` (one line box tall, 20px at text-sm, with a 16px icon).
- Content: `flex min-w-0 flex-1 flex-col gap-0.5` (2px).
- Actions: `flex shrink-0 items-center`, plus `self-center` or `h-lh self-start`.

**Sub-parts**
- `AlertTitle` (129): `font-medium`.
- `AlertDescription` (135): `flex flex-col gap-2.5 text-muted-foreground` (10px gap).
- `AlertAction` (143): `flex gap-1` (4px).

**Base resolved**
- Radius 14px.
- Border 1px `--contrast-border`: zinc-200 light, white 6% dark.
- Padding 14px horizontal, 12px vertical.
- Text 14px/20px, `--contrast-card-foreground`: zinc-800 light, neutral-100 dark.

**Variants resolved**

*default*
- Light bg transparent; dark bg input at 32% (white 2.56%).
- Icons muted-foreground.

*sidebar*
- tailwind-merge drops `rounded-xl px-3.5 py-3 text-sm`.
- Radius 10px, border `--contrast-sidebar-border`, padding 8px x 6px, text 11px with 16px line-height. The description is `display: block` in sidebar-muted-foreground.
- bg `--sidebar-control-surface`:
  - Light: zinc-100.
  - Dark at root: muted (white 3%).
  - Dark inside `[data-app-sidebar]`: `#0a0a0a`.

*error*
- Border error at 32%.
- bg `--error-surface`:
  - Light: red-500 at 8%.
  - Dark: `color-mix(in srgb, error 16%, transparent)` with dark error = `red-500 90% + white`.
- Text error-foreground (red-700 / red-400); description error-foreground at 80%; icons `--error`.

*info*
- Border info at 32%, bg info at 4%, icons info. Text stays card-foreground and the description stays muted.

*success*
- Border success at 32%, bg success at 4%, icons success.

*warning*
- Border warning at 32%.
- bg `--warning-surface`: amber-500 at 8% light, 16% dark.
- Text amber-700 / amber-400, description at 80%, icons warning.

**Glass surface (`alert-glass`, index.css:344-374)**
- Background (with `!important`, so it overrides the variant bg):
  - Top layer: `linear-gradient(color-mix(in srgb, var(--alert-glass-tint) 4%, transparent), color-mix(in srgb, var(--alert-glass-tint) 4%, transparent))`.
  - Over: `color-mix(in srgb, var(--background) var(--glass-opacity), transparent)`.
- Tint by `data-variant`:
  - Default: transparent.
  - error: `--destructive`.
  - info: `--info`.
  - success: `--success`.
  - warning: `--warning`.
- Effect: `backdrop-filter: blur(var(--glass-blur)) saturate(var(--glass-saturation))`.
  - Light: 12px and 1.14.
  - Dark: 16px and 1.08.
- Without backdrop-filter support it falls back to solid `--background`.

**Animations**
- None.

---

## 8. ScrollArea, scrollbars and fades (`components/ui/scroll-area.tsx`)

**Primitives and slots**
- Primitives: `ScrollArea.Root`, `.Viewport`, `.Scrollbar`, `.Thumb`, `.Corner` from `@base-ui/react/scroll-area` (3).
- Slots: `scroll-area-viewport` (69), `scroll-area-scrollbar` (95), `scroll-area-thumb` (101), `scroll-area-corner` (77). The root has no data-slot.

**Props (24-47)**

| prop | default |
|---|---|
| `scrollFade` | false |
| `scrollFadePadding` | true |
| `scrollbarGutter` | false |
| `hideScrollbars` | false |
| `chainVerticalScroll` | false |
| `radius` | `"inherit"` |
| `viewportTabIndex` | none |

**Classes, verbatim**
- Root (51-52): `relative size-full min-h-0 overflow-hidden`, plus `rounded-none` or `rounded-[inherit]`.
- Viewport (60): `h-full max-h-[inherit] overflow-auto overscroll-contain rounded-[inherit] outline-none transition-shadow focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background data-has-overflow-x:overscroll-x-contain`
- `chainVerticalScroll` (61): `overscroll-y-auto`
- `scrollFade` (63): `mask-t-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-start)))] mask-b-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-end)))] mask-l-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-start)))] mask-r-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-end)))] [--fade-size:1.5rem]`
- `scrollFade && scrollFadePadding` (64): `scroll-p-[var(--fade-size)]`
- `scrollbarGutter` (65): `scrollbar-gutter-stable`, which compiles to `scrollbar-gutter: stable`.
- `hideScrollbars` (67): `[-ms-overflow-style:none] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden`. It also stops rendering the custom scrollbars and the corner (73-79).
- Scrollbar (92): `flex opacity-0 transition-opacity delay-300 data-[orientation=horizontal]:mx-1 data-[orientation=horizontal]:mb-px data-[orientation=horizontal]:h-1.5 data-[orientation=vertical]:my-1 data-[orientation=vertical]:mr-px data-[orientation=vertical]:w-1.5 data-[orientation=horizontal]:flex-col data-hovering:opacity-100 data-scrolling:opacity-100 data-hovering:delay-0 data-scrolling:delay-0 data-hovering:duration-100 data-scrolling:duration-100`
- Thumb (100): `relative flex-1 rounded-full bg-[var(--app-scrollbar-thumb)] transition-colors hover:bg-[var(--app-scrollbar-thumb-hover)]`

**Scrollbar resolved**

*Thickness and inset*
- Thickness 6px.
- Vertical: margin-block 4px, margin-right 1px.
- Horizontal: margin-inline 4px, margin-bottom 1px.

*Positioning* (Base UI inline style, bundle scroll-area-D30euOX7.js)
- `position: absolute`.
- Vertical: `top: 0; bottom: var(--scroll-area-corner-height); inset-inline-end: 0`.
- Horizontal: `inset-inline-start: 0; inset-inline-end: var(--scroll-area-corner-width); bottom: 0`.

*Thumb*
- Fully rounded, flex-1 along the track.
- Length: `max(16px, trackLength * clientSize / scrollSize)`, moved with `translate3d` (bundle).
- Colour: `--app-scrollbar-thumb`; on its own hover, `--app-scrollbar-thumb-hover`.
  - Light: rgb(217 217 217), hover rgb(191 191 191).
  - Dark: white 8%, hover white 12%.
- Colour transition 150ms.

*Visibility*
- Hidden by default (opacity 0).
- Fade-in: when `data-hovering` or `data-scrolling` is present, opacity goes to 1 over 100ms with no delay.
- Fade-out: when both attributes go away, opacity goes to 0 over 150ms after a 300ms delay.
- `data-hovering` is set by pointerenter and pointermove from non-touch pointers whose target is inside the root. It is cleared on pointerleave.
- `data-scrolling` is set on scroll and cleared 500ms after the last scroll movement (bundle: `m.start(500, ...)`).

*Focus*
- The viewport gets the ring recipe on keyboard focus.
- `viewportTabIndex` overrides Base UI's focusable viewport.

**Fade masks (`scrollFade`)**

*Variables*
- `--scroll-area-overflow-x-start`, `-x-end`, `-y-start` and `-y-end` are registered by Base UI with `CSS.registerProperty({syntax: "<length>", inherits: false, initialValue: "0px"})`.
- They are set in px on the viewport (bundle):
  - y-start = scrollTop clamped to 0..max.
  - y-end = maxScroll minus y-start.
  - The x pair works the same way.

*Mask layers*
- Tailwind compiles each edge to a mask layer. Top: `linear-gradient(to top, black calc(100% - min(var(--fade-size), var(--scroll-area-overflow-y-start))), transparent 100%)`. The `@property` defaults are from-colour black, to-colour transparent, to-position 100%.
- Bottom, left and right are analogous.
- Layers combine with `mask-composite: intersect` (`-webkit-mask-composite: source-in`).

*Effect*
- Each edge fades linearly from opaque to fully transparent over `min(fade-size, distance scrolled away from that edge)`. There is no fade at an edge you are flush with.
- Fade size: 24px by default (`[--fade-size:1.5rem]`); SidebarContent uses 12px.
- With `scrollFadePadding`, `scroll-padding: var(--fade-size)`.
- The custom scrollbars are siblings of the viewport, so they are not masked.
- No edge shadows exist anywhere in this component; overflow is indicated only by these masks.

**Virtualized lists (`getVirtualizedScrollFadeClassName`, 7-22), verbatim**
- `virtualized-scroll-fade [--fade-size:1.5rem]` plus one of:
  - Top and bottom (14): `[--virtualized-scroll-fade-mask:linear-gradient(to_bottom,transparent,black_var(--fade-size),black_calc(100%-var(--fade-size)),transparent)]`
  - Top only (17): `[--virtualized-scroll-fade-mask:linear-gradient(to_bottom,transparent,black_var(--fade-size))]`
  - Bottom only (20): `[--virtualized-scroll-fade-mask:linear-gradient(to_bottom,black_calc(100%-var(--fade-size)),transparent)]`
- Utility (index.css:481-494):
  - `mask-image: var(--virtualized-scroll-fade-mask), linear-gradient(black, black)`
  - `mask-position: left, right; mask-repeat: no-repeat`
  - `mask-size: calc(100% - var(--app-scrollbar-width)) 100%, var(--app-scrollbar-width) 100%`
- Result: the 6px native scrollbar lane on the right is never faded. These fades are fixed at 24px when the flag is on; they are not proportional.

**Native scrollbars for non-ScrollArea scrollers (index.css:1744-1760)**
- `::-webkit-scrollbar{width: var(--app-scrollbar-width)}` (6px).
- Track transparent.
- Thumb `var(--app-scrollbar-thumb)`, radius 3px; hover `var(--app-scrollbar-thumb-hover)`.

**`topbar-scroll-fade` (index.css:439-476)**
- Used by the settings page scroller (`settings/settingsLayout.tsx:574`).
- Top mask stops: transparent 0%, 10% alpha at 10%, 30% at 24%, 58% at 42%, 82% at 62%, 96% at 82%, opaque at 100%.
- The fade spans `--workspace-titlebar-scroll-fade-height` (1.5rem) + 1px.
- The 6px right-hand scrollbar lane is excluded from the mask.

---

## 9. Separator (`components/ui/separator.tsx`)

**Primitive and attributes**
- Primitive: `Separator` from `@base-ui/react/separator` (1).
- `data-slot="separator"` (12), `orientation` default `"horizontal"` (5).

**Class (9), verbatim:**
```
shrink-0 bg-border data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full data-[orientation=vertical]:w-px data-[orientation=vertical]:not-[[class^='h-']]:not-[[class*='_h-']]:self-stretch
```

**Resolved**
- Colour `--contrast-border`: zinc-200 light, white 6% dark.
- Horizontal: 1px x 100%.
- Vertical: 1px wide, `align-self: stretch` unless the element has an `h-*` class. The compiled guard is `:not([class^=h-]):not([class*=\ h-])`.

---

## 10. Skeleton (`components/ui/skeleton.tsx`)

**Element and attributes**
- Plain `div`, `data-slot="skeleton"` (24). Size comes from the consumer's className (comment at 5-6).

**cva (7-16), verbatim**
- Base: `bg-muted-foreground/15 motion-safe:animate-skeleton`
- Shapes: block `rounded-sm`, card `rounded-lg`, pill `rounded-full`. Default `block`.

**Resolved**
- Colour: `--contrast-muted-foreground` at 15%.
  - Light: zinc-500 at 15%.
  - Dark: `color-mix(in srgb, neutral-500 90%, white)` at 15%.
- Radius: 6px (block), 10px (card), 9999px (pill).

**Animation**
- Compiled as `animation: 2.4s infinite skeleton`, only under `prefers-reduced-motion: no-preference`.
- Keyframes (index.css:283-301):
  - `0%,42% {opacity:1; animation-timing-function: steps(4)}`
  - `50%,92% {opacity:.55; animation-timing-function: steps(4)}`
  - `100% {opacity:1}`
- Effective timeline:
  - Hold 1.0 for 1.008s.
  - Over 192ms step down 1, .8875, .775, .6625, then .55 (`steps(4,end)`).
  - Hold .55 for 1.008s.
  - Over 192ms step up .55, .6625, .775, .8875, then 1.

---

## 11. Spinner (`components/ui/spinner.tsx`)

**Icon**
- `LoaderCircleIcon` from lucide-react (1).
- Single path `M21 12a9 9 0 1 1-6.219-8.56` (bundle loader-circle-B3Ce8JIQ.js), stroke 2, round caps.
- Attributes: `role="status"`, `aria-label="Loading"` (31-34).

**cva (7-21), verbatim**
- Base: `motion-safe:visible-animate-spin`
- size: xs `size-3`, sm `size-3.5`, md `size-4`, lg `size-5` (12, 14, 16, 20px). There is no default size; inside a Button the button's svg rule sizes it (comment at 6).
- tone: current `""`, muted `text-muted-foreground`. Default tone `current`.

**Animation**
- `visible-animate-spin` (index.css:550-554):
  - `animation: var(--animate-spin)`, which is `spin 1s linear infinite`; keyframes `spin{to{transform:rotate(360deg)}}`.
  - `animation-play-state: var(--visible-animation-state, paused)`.
  - `will-change: var(--visible-animation-will-change, auto)`.
- `observeVisibleAnimation` (lib/visibleAnimation.ts:10-18, 25-64) runs the animation only while the element intersects the viewport, the document is visible, and reduced motion is off. In that state it also sets `will-change: transform`. Otherwise the animation is paused.
- Only applied under `prefers-reduced-motion: no-preference`.

---

## 12. RefreshIcon (`components/ui/refresh-icon.tsx`)

**Icon**
- `RefreshCwIcon` from lucide-react (1), `aria-hidden` (29).
- Paths (bundle refresh-cw-PY_ECjtI.js):
  - `M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8`
  - `M21 3v5h-5`
  - `M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16`
  - `M8 16H3v5`

**Sizes (8-17)**
- xs `size-3`, sm `size-3.5`, md `size-4`, lg `size-5`. No default size.

**Animation**
- While `refreshing` is true it adds `motion-safe:visible-animate-spin` (33) and the visibility observer (30). This is the same 1s linear spin as Spinner.
- When `refreshing` turns false the class is removed. The icon snaps back with no settle animation.

---

## 13. Empty (`components/ui/empty.tsx`)

All parts are plain `div`s.

**Empty (14-30)**
- `data-slot="empty"`, size `"default" | "compact" | "hero"`.
- Base (22): `flex min-w-0 flex-1 flex-col items-center justify-center text-balance text-center`
- compact (9): `min-h-64 gap-4 p-6 md:p-10 [&_[data-slot=empty-media]]:mb-0 [&_[data-slot=empty-title]]:text-[1.0625rem] [&_[data-slot=empty-title]]:leading-6 [&_[data-slot=empty-description]]:text-[0.8125rem] [&_[data-slot=empty-description]]:leading-[1.125rem]`
- default (10): `gap-6 p-6 md:p-12`
- hero (11): `gap-6 p-6 md:p-12 [&_[data-slot=empty-title]]:text-2xl sm:[&_[data-slot=empty-title]]:text-3xl`

**Resolved sizes**
- default: gap 24px; padding 24px, or 48px at 768px and up.
- compact:
  - min-height 256px, gap 16px, padding 24px (40px at 768px and up).
  - Media margin 0.
  - Title 17px/24px (beats EmptyTitle's own `text-xl` by specificity).
  - Description 13px/18px.
- hero: title 24px/32px narrow, 30px/36px desktop.

**EmptyHeader (35)**
- `flex max-w-sm flex-col items-center text-center`, max-width 384px. `data-slot="empty-header"`.

**EmptyMedia (57-90)**
- Wrapper `relative mb-6` (24px margin-bottom), `data-slot="empty-media"`, `data-variant`.
- cva base (43): `flex shrink-0 items-center justify-center [&_svg]:pointer-events-none [&_svg]:shrink-0`
- variant default (50): `bg-transparent`
- variant icon (51): `relative flex size-9 shrink-0 items-center justify-center rounded-md border bg-card not-dark:bg-clip-padding text-foreground shadow-sm/5 before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-md)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] dark:before:shadow-[0_-1px_--theme(--color-white/6%)] [&_svg:not([class*='size-'])]:size-4.5`
- Icon variant resolved:
  - Box 36px, radius 8px, border 1px `--contrast-border`.
  - bg `--card`: white light; `color-mix(in srgb, neutral-950 97%, white)` dark.
  - Shadow `0 1px 3px 0 rgb(0 0 0/5%), 0 1px 2px -1px rgb(0 0 0/5%)`.
  - Before layer radius 7px with a black 4% bottom line (light) or white 6% top line (dark).
  - Icon 18px.
- Icon variant decoration: two fanned copies drawn behind the main box, each with `shadow-none`.
  - (75): `-translate-x-0.5 -rotate-10 pointer-events-none absolute bottom-px origin-bottom-left scale-84 shadow-none`. That is translate -2px, rotate -10deg, scale .84, bottom 1px.
  - (82): `pointer-events-none absolute bottom-px origin-bottom-right translate-x-0.5 rotate-10 scale-84 shadow-none`.

**EmptyTitle (94)**
- `font-semibold text-xl`: weight 600, 20px/28px.

**EmptyDescription (101-103)**
- `text-muted-foreground text-sm [&>a:hover]:text-primary [&>a]:underline [&>a]:underline-offset-4 [[data-slot=empty-title]+&]:mt-1 [[data-slot=empty-description]+&]:mt-1`
- 14px/20px, muted. Links are underlined with a 4px offset and turn primary on hover. It gets a 4px top margin after a title or another description.

**EmptyContent (115)**
- `flex w-full min-w-0 max-w-sm flex-col items-center gap-4 text-balance text-sm`
- Max-width 384px, gap 16px.

---

## 14. Group / ButtonGroup (`components/ui/group.tsx`)

**Element and attributes**
- Plain `div`, `role="group"`, `data-slot="group"`, `data-orientation` (36-44).
- Exports `Group`, `ButtonGroup`, `GroupSeparator`, `ButtonGroupSeparator`, `groupVariants` (67-73).
- Default orientation `horizontal` (12).

**Base (9), verbatim:**
```
flex w-fit *:focus-visible:z-1 has-[>[data-slot=group]]:gap-2 *:has-focus-visible:z-1 dark:*:[[data-slot=button]:hover~[data-slot=separator]:not([data-slot]:hover~[data-slot=separator]~[data-slot=separator]),[data-slot][data-pressed]~[data-slot=separator]:not([data-slot][data-pressed]~[data-slot=separator]~[data-slot=separator])]:before:bg-input/64 dark:*:[[data-slot=separator]:has(~[data-slot=button]:hover):not(:has(~[data-slot=separator]~[data-slot]:hover)),[data-slot=separator]:has(~[data-slot][data-pressed]):not(:has(~[data-slot=separator]~[data-slot][data-pressed]))]:before:bg-input/64
```

**Horizontal (17), verbatim:**
```
*:[[data-slot]~[data-slot]:not([data-slot=separator])]:before:-start-[0.5px] *:data-slot:not-data-[slot=separator]:has-[~[data-slot]]:before:-end-[0.5px] *:pointer-coarse:after:min-w-auto *:data-slot:has-[~[data-slot]]:rounded-e-none *:data-slot:has-[~[data-slot]]:border-e-0 *:data-slot:has-[~[data-slot]]:before:rounded-e-none *:[[data-slot]~[data-slot]]:rounded-s-none *:[[data-slot]~[data-slot]]:border-s-0 *:[[data-slot]~[data-slot]]:before:rounded-s-none
```

**Vertical (19), verbatim:**
```
*:[[data-slot]~[data-slot]:not([data-slot=separator])]:before:-top-[0.5px] *:data-slot:not-data-[slot=separator]:has-[~[data-slot]]:before:-bottom-[0.5px] flex-col *:pointer-coarse:after:min-h-auto *:data-slot:has-[~[data-slot]]:rounded-b-none *:data-slot:has-[~[data-slot]]:border-b-0 *:data-slot:not-data-[slot=separator]:has-[~[data-slot]]:before:hidden *:data-slot:has-[~[data-slot]]:before:rounded-b-none dark:*:last:before:hidden dark:*:first:before:block *:[[data-slot]~[data-slot]]:rounded-t-none *:[[data-slot]~[data-slot]]:border-t-0 *:[[data-slot]~[data-slot]]:before:rounded-t-none
```

**Resolved**
- Buttons are joined edge to edge:
  - Inner corner radii are removed.
  - The inline-end border is removed on every item that has a following sibling, and the inline-start border on every item after the first.
  - The before layers extend 0.5px into the seam.
- A focused child is raised to z-index 1.
- A group containing nested groups gets an 8px gap.
- Dark mode: a separator adjacent to a hovered or pressed button gets a before layer of input at 64%.

**GroupSeparator (48-65), class (58) verbatim:**
```
[[data-slot=input-control]:focus-within+&,[data-slot=input-group]:focus-within+&,[data-slot=select-trigger]:focus-visible+*+&,[data-slot=number-field]:focus-within+input+&]:-translate-x-px pointer-events-none relative z-2 bg-input before:absolute before:inset-0 has-[+[data-slot=input-control]:focus-within,+[data-slot=input-group]:focus-within,+[data-slot=select-trigger]:focus-visible+*,+[data-slot=number-field]:focus-within]:translate-x-px has-[+[data-slot=input-control]:focus-within,+[data-slot=input-group]:focus-within,+[data-slot=select-trigger]:focus-visible+*,+[data-slot=number-field]:focus-within]:bg-ring dark:before:bg-input/32 [[data-slot=input-control]:focus-within+&,[data-slot=input-group]:focus-within+&,[data-slot=select-trigger]:focus-visible+*+&,[data-slot=number-field]:focus-within+&,[data-slot=number-field]:focus-within+input+&]:bg-ring
```

**GroupSeparator resolved**
- Vertical by default (50). 1px, colour `--contrast-input`: zinc-300 light, white 8% dark. The dark before overlay is input at 32%. z-index 2.
- When the adjacent input, input-group, select or number-field is focused, the separator turns `--ring` and shifts 1px toward it.

---

## 15. Table (`components/ui/table.tsx`)

**Classes and slots, verbatim**

| part | data-slot | line | class |
|---|---|---|---|
| container | table-container | 7 | `relative w-full overflow-x-auto` |
| table | table | 10 | `w-full caption-bottom text-xs` |
| TableHeader | table-header | 18 | `[&_tr]:border-b` |
| TableBody | table-body | 25 | `[&_tr:last-child]:border-0` |
| TableRow | table-row | 36 | `border-b transition-colors hover:bg-muted/50 has-aria-expanded:bg-muted/50 data-[state=selected]:bg-muted` |
| TableHead | table-head | 49 | `h-10 px-2 text-left align-middle font-medium whitespace-nowrap text-foreground [&:has([role=checkbox])]:pr-0` |
| TableCell | table-cell | 61 | `p-2 align-middle whitespace-nowrap [&:has([role=checkbox])]:pr-0` |

**Resolved**
- Table text: 12px/16px.
- Row border: 1px `--contrast-border` at the bottom of each row; header rows too; none on the last body row.
- Row hover: muted at 50% (zinc-50 at 50% light, white 1.5% dark). The same applies to a row containing `[aria-expanded=true]`.
- Selected row (`data-state=selected`): full muted.
- Head cell: 40px tall, 8px horizontal padding, weight 500, foreground colour, left-aligned, nowrap.
- Body cell: 8px padding, nowrap.
- Cells that contain a checkbox drop the right padding.
- Row colour transition: 150ms.

---

## 16. Collapsible (`components/ui/collapsible.tsx`)

**Primitives and slots**
- Primitives: `Collapsible.Root`, `.Trigger`, `.Panel` from `@base-ui/react/collapsible` (3).
- Slots: `collapsible` (8), `collapsible-trigger` (15), `collapsible-panel` (36). `CollapsibleContent` is an alias of the panel (46).

**Classes, verbatim**
- Trigger (14): `cursor-pointer`.
- Panel (30-35): `overflow-hidden`, plus when `animate` (default true, 23): `h-(--collapsible-panel-height) transition-[height] duration-200 motion-reduce:transition-none data-ending-style:h-0 data-starting-style:h-0 data-open:data-ending-style:[height:var(--collapsible-panel-height)]`.

**Animation**
- Base UI writes `--collapsible-panel-height`, the measured content height in px, and `--collapsible-panel-width` (names verified in bundle collapsible-CJ8dulBE.js).
- Opening: the panel starts at height 0 (`data-starting-style`) and transitions to the measured height.
- Closing: it transitions to 0 (`data-ending-style`).
- `data-open` plus `data-ending-style` pins the measured height so an interrupted transition does not jump.
- Timing: `transition-property: height`, 200ms, `cubic-bezier(.4,0,.2,1)`. With reduced motion there is no transition. `animate={false}` removes the height classes, so it is instant.

**Exception inside AnimatedHeight (index.css:705-715)**
- `[data-slot="animated-height"] [data-slot="collapsible-panel"] {height:auto !important; transition:none !important}`.
- Closed panels there get `display:none`.

---

## 17. CollapsibleSectionHeader (`components/ui/collapsible-section-header.tsx`)

**Element and props**
- Plain `button type="button"` with `aria-expanded` (25-41). No data-slot.
- The caller owns the state (comment at 12).

**Tones (5-10), verbatim**
- muted: label `text-sidebar-muted-foreground/60`, line `bg-sidebar-border/60`.
- info: label `text-blue-600 dark:text-blue-400`, line `bg-blue-500/20 dark:bg-blue-400/15`.
- emphasized: label `text-sidebar-foreground/80`, line `bg-sidebar-foreground/25`.
- accent: label `text-primary`, line `bg-primary/50`.
- Default tone: `muted` (16).

**Classes, verbatim**
- Button (30): `flex h-8 w-full cursor-pointer items-center gap-2 rounded-md px-2 text-left text-xs font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring/70`, plus the tone label class.
- Label span (34): `shrink-0`.
- Rule line (35): `h-px min-w-2 flex-1`, plus the tone line class.
- Then the optional `accessory` node.
- Chevron (37-40): lucide `ChevronDownIcon` (path `m6 9 6 6 6-6`) with `size-3 shrink-0 transition-transform`, plus `rotate-180` when expanded.

**Resolved**
- Size: 32px tall, full width, gap 8px, radius 8px, padding-inline 8px. Text 12px/16px, weight 500.
- The 1px rule fills the remaining width (min 8px).
- Chevron: 12px in `currentColor`; it rotates 180deg when expanded with a 150ms `cubic-bezier(.4,0,.2,1)` transition on transform, translate, scale and rotate.
- Focus-visible: 2px inset ring of `--ring` at 70%, no outline.

**SectionHeaderStatus (45-49)**
- `shrink-0 text-3xs leading-none text-destructive-foreground`: 10px, line-height 1, red-700 light, red-400 dark.

---

## 18. Toasts (`toast.tsx`, `toast.logic.ts`, `toastHelpers.ts`, `anchoredCopyToast.ts`)

**Primitive**
- `Toast` from `@base-ui/react/toast` (toast.tsx:5): Provider, Portal, Viewport, Root, Content, Title, Description, Action, Positioner.

**Managers**
- `toastManager`: the stacked corner viewport (71).
- `anchoredToastManager`: anchored popups (72).

**Slots**
- Stacked: `toast-portal` (548), `toast-viewport` (561), `toast-close` (656/747), `toast-icon` (346/353), `toast-title` (358/739), `toast-description` (194/200/244), `toast-action` (396).
- Anchored: `toast-portal-anchored` (707), `toast-viewport-anchored` (708), `toast-positioner` (724), `toast-popup` (734).

### 18.1 Provider defaults and timing

**Providers**
- The app mounts `<ToastProvider>` and `<AnchoredToastProvider>` with no props (routes/__root.tsx:175-176, 216-217).
- Position defaults to `"top-right"` (toast.tsx:520).

**Base UI defaults (bundle toast-CJKBVZTR.js)**
- `timeout = 5e3`, so **5000ms**. `limit = 3`.
- Toasts of type `loading` are never scheduled to close: `i.type!=='loading' && s>0 && scheduleTimer(...)`.
- `timeout: 0` means persistent.
- Timers pause while the stack is expanded (hovered or focused) or the window is unfocused.
- F6 moves focus to the viewport.
- `priority: "high"` gives the root `role="alertdialog"`; otherwise `role="dialog"`.
- Toasts beyond the limit get `data-limited`.

**Toast.Root state attributes**
- `data-expanded`, `data-limited`, `data-type`, `data-swiping`, `data-swipe-direction`, plus transition attributes `data-starting-style` and `data-ending-style`.
- `Toast.Content` gets `data-expanded` and `data-behind`.

**Visible-time dismiss (toast.tsx:442-518)**
- `data.dismissAfterVisibleMs` counts down only while `document.visibilityState === "visible"` and `document.hasFocus()`. It pauses otherwise, and the remaining time persists across remounts (74, 453).
- App values:
  - Git action success: 10,000ms with `timeout: 0` (components/GitActionsControl.logic.ts:46-66).
  - Provider update success: 3,000ms (components/ProviderUpdateLaunchNotification.logic.ts:68).
- Other observed values: `timeout: 0` (persistent) in several coordinators, and 8,000ms (components/ProjectCloneToastCoordinator.tsx:155).

**Thread scoping (toast.logic.ts:108-131)**
- Toasts carrying `data.threadRef` or `data.threadId` render only when that thread is the active route.

**Helpers**
- `stackedThreadToast` (toastHelpers.ts:31-66) always sets `data.actionLayout = "stacked-end"`.
- `hiddenToastActionProps = {children: null}` (toastHelpers.ts:24-26) hides an earlier action on update (toast.logic.ts:8-17).

### 18.2 Viewport (toast.tsx:550-559), verbatim
```
fixed z-100 mx-auto flex w-[calc(100%-var(--toast-inset)*2)] max-w-90 [--toast-header-offset:var(--workspace-topbar-height)] [--toast-inset:--spacing(4)] sm:[--toast-inset:--spacing(8)]
data-[position*=top]:top-[calc(var(--toast-inset)+var(--toast-header-offset))]
data-[position*=bottom]:bottom-(--toast-inset)
data-[position*=left]:left-(--toast-inset)
data-[position*=right]:right-(--toast-inset)
data-[position*=center]:-translate-x-1/2 data-[position*=center]:left-1/2
```

**Resolved**
- `position: fixed`, z-index 100.
- Width `min(100% - 2*inset, 360px)`.
- Inset: 32px desktop, 16px narrow.
- Header offset: `--workspace-topbar-height` (52px).
- Default top-right placement: **top 84px, right 32px, width 360px** on desktop. Narrow: top 68px, right 16px.
- Inline `--toast-frontmost-height` (564) is the height of the first non-ending toast (toast.logic.ts:94-101).

### 18.3 Toast root (toast.tsx:578-630), verbatim class list
```
dropdown-glass absolute z-[calc(9999-var(--toast-index))] w-full overflow-visible select-none rounded-lg text-popover-foreground shadow-xl shadow-black/25 [transition:transform_.5s_cubic-bezier(.22,1,.36,1),opacity_.5s,height_.15s]
data-[position*=right]:right-0 data-[position*=right]:left-auto
data-[position*=left]:right-auto data-[position*=left]:left-0
data-[position*=center]:right-0 data-[position*=center]:left-0
data-[position*=top]:top-0 data-[position*=top]:bottom-auto data-[position*=top]:origin-top
data-[position*=bottom]:top-auto data-[position*=bottom]:bottom-0 data-[position*=bottom]:origin-bottom
after:absolute after:left-0 after:h-[calc(var(--toast-gap)+1px)] after:w-full
data-[position*=top]:after:top-full
data-[position*=bottom]:after:bottom-full
(index > 0) not-data-expanded:[--toast-calc-height:var(--toast-frontmost-height)] data-expanded:[--toast-calc-height:max(var(--toast-frontmost-height,var(--toast-height)),var(--toast-height))]
(index 0)   [--toast-calc-height:max(var(--toast-frontmost-height,var(--toast-height)),var(--toast-height))]
[--toast-gap:--spacing(3)] [--toast-peek:--spacing(3)] [--toast-scale:calc(max(0,1-(var(--toast-index)*.1)))] [--toast-shrink:calc(1-var(--toast-scale))]
(index > 0) not-data-expanded:h-(--toast-calc-height) data-expanded:h-auto
(index 0)   h-auto
data-[position*=top]:[--toast-calc-offset-y:calc(var(--toast-offset-y)+var(--toast-index)*var(--toast-gap)+var(--toast-swipe-movement-y))]
data-[position*=bottom]:[--toast-calc-offset-y:calc(var(--toast-offset-y)*-1+var(--toast-index)*var(--toast-gap)*-1+var(--toast-swipe-movement-y))]
data-[position*=top]:transform-[translateX(var(--toast-swipe-movement-x))_translateY(calc(var(--toast-swipe-movement-y)+(var(--toast-index)*var(--toast-peek))+(var(--toast-shrink)*var(--toast-calc-height))))_scale(var(--toast-scale))]
data-[position*=bottom]:transform-[translateX(var(--toast-swipe-movement-x))_translateY(calc(var(--toast-swipe-movement-y)-(var(--toast-index)*var(--toast-peek))-(var(--toast-shrink)*var(--toast-calc-height))))_scale(var(--toast-scale))]
data-limited:opacity-0
data-position:data-expanded:transform-[translateX(var(--toast-swipe-movement-x))_translateY(var(--toast-calc-offset-y))]
data-[position*=top]:data-starting-style:transform-[translateY(calc(-100%-var(--toast-inset)))]
data-[position*=bottom]:data-starting-style:transform-[translateY(calc(100%+var(--toast-inset)))]
data-[position*=top]:data-[position*=right]:data-starting-style:transform-[translateX(calc(100%+var(--toast-inset)))_translateY(var(--toast-calc-offset-y))]
data-ending-style:opacity-0
data-ending-style:not-data-limited:not-data-swipe-direction:transform-[translateY(calc(100%+var(--toast-inset)))]
data-[position*=top]:data-[position*=right]:data-ending-style:not-data-limited:not-data-swipe-direction:transform-[translateX(calc(100%+var(--toast-inset)))_translateY(var(--toast-calc-offset-y))]
data-ending-style:data-[swipe-direction=left]:transform-[translateX(calc(var(--toast-swipe-movement-x)-100%-var(--toast-inset)))_translateY(var(--toast-calc-offset-y))]
data-ending-style:data-[swipe-direction=right]:transform-[translateX(calc(var(--toast-swipe-movement-x)+100%+var(--toast-inset)))_translateY(var(--toast-calc-offset-y))]
data-ending-style:data-[swipe-direction=up]:transform-[translateY(calc(var(--toast-swipe-movement-y)-100%-var(--toast-inset)))]
data-ending-style:data-[swipe-direction=down]:transform-[translateY(calc(var(--toast-swipe-movement-y)+100%+var(--toast-inset)))]
(626-629: the same four swipe rules repeated with a data-expanded: prefix)
```

**Inline style (633-638)**
- `--toast-index` is the visible index and `--toast-offset-y` is the cumulative height in px of the toasts in front. Both come from `buildVisibleToastLayout` (toast.logic.ts:45-102).
- In that function, ending toasts keep their old slot while live toasts reflow immediately (51-92).
- Base UI supplies `--toast-height` and `--toast-swipe-movement-x/y`.

**Surface**

*Background (`dropdown-glass`, index.css:424-437)*
- `background: color-mix(in srgb, var(--popover) 18%, color-mix(in srgb, var(--popover) var(--glass-opacity), transparent))`. At the default 80% glass opacity this is the popover colour at alpha .836.
- Popover: white (light); `color-mix(in srgb, neutral-950 97%, white)` (dark).
- Fallback without backdrop-filter: solid popover.

*Border, blur and shadow*
- Border: `1px solid color-mix(in srgb, var(--contrast-foreground) 10%, transparent)`.
- Blur and saturate: 12px and 1.14 light; 16px and 1.08 dark.
- Shadow: `0 20px 25px -5px rgb(0 0 0/25%), 0 8px 10px -6px rgb(0 0 0/25%)`.

*Shape and stacking*
- Radius 10px, text `--contrast-popover-foreground`, `user-select: none`, `overflow: visible`.
- z-index `9999 - index`.

**Transition**
- `transform .5s cubic-bezier(.22,1,.36,1), opacity .5s, height .15s`. Opacity and height use the default `ease`.

**Stacking constants**
- `--toast-gap` 12px, `--toast-peek` 12px.
- `--toast-scale = max(0, 1 - index*0.1)`; `--toast-shrink = 1 - scale`.
- Limit 3 visible.

**Collapsed stack** (top positions, not hovered)
- The front toast is at translateY 0, scale 1, natural height.
- Toast `i` behind it:
  - Height is forced to the front toast's height H.
  - Its content is hidden: `not-data-expanded:opacity-0 pointer-events-none` via `shouldHideCollapsedToastContent`, toast.logic.ts:19-27.
  - Transform: `translateY(i*12px + (i*0.1)*H) scale(1 - i*0.1)` with origin top.
- So toast 1 (scale .9) shows a 12px strip below the front toast, and toast 2 (scale .8) a further 12px strip.
- Limited toasts (fourth and beyond) are opacity 0.

**Expanded stack** (viewport hovered or focused)
- `translateY(offsetY + i*12px)`, no scale, natural heights. The toasts lay out as a list with 12px gaps.
- Hidden content fades in: Toast.Content uses `transition-opacity duration-250`, which is 250ms `cubic-bezier(.4,0,.2,1)`.
- An `after` strip 13px tall (gap + 1px), at `top: 100%` for top positions, bridges the gaps so hover is not lost.

**Enter animation**
- Top-right: from `translateX(calc(100% + inset)) translateY(calcOffsetY)`. It slides in from the right edge over 500ms with `cubic-bezier(.22,1,.36,1)` while opacity transitions.
- Other top positions: from `translateY(calc(-100% - inset))`.
- Bottom positions: from `translateY(calc(100% + inset))`.

**Exit animation**
- Opacity goes to 0.
- Without a swipe: top-right slides out to the right by `100% + inset`; other positions move down by `100% + inset`.
- After a swipe: the toast continues in the swipe direction by `100% + inset` from the current swipe offset.

**Swipe**
- Directions (639-645):
  - Center positions: up (top) or down (bottom).
  - Left positions: left plus up/down.
  - Right positions: right plus up/down.
  - The default top-right is therefore `["right","up"]`.
- Base UI dismiss threshold is 40px (bundle constant `He=40`; the left and up checks use `-40`). Other constants in that block are `Ue=10`, `Z=.5`, `We=1`; their meaning is UNVERIFIED.

### 18.4 Close orb (toast.tsx:96-102, 652-664)
- Wrapper: `absolute z-20 -top-1.5 -right-1.5`. It is anchored at -6px top and -6px right of the toast.
- Button classes:
  - `inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-full border border-border/60 bg-popover/92 text-muted-foreground shadow-sm outline-none backdrop-blur-sm`
  - `transition-[color,background-color,box-shadow] hover:bg-popover hover:text-foreground`
  - `focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background`
- Resolved:
  - 24px circle, 1px border at border/60.
  - bg popover at 92%, backdrop blur 8px, text muted-foreground.
  - Shadow `0 1px 3px 0 rgb(0 0 0/10%), 0 1px 2px -1px rgb(0 0 0/10%)`.
  - Hover: solid popover and foreground text, 150ms.
- Icon: lucide `XIcon` at `size-3` (12px), `strokeWidth={2.25}`, paths `M18 6 6 18` and `m6 6 12 12`.
- Always visible; there is no hover reveal.
- `aria-label="Dismiss notification"`. Clicking calls `data.onClose` and then closes the toast (104-111).

### 18.5 Content and body

**Content (665-676)**
- `pointer-events-auto min-h-0 overflow-y-visible pl-3.5 text-sm transition-opacity duration-250 [overflow-x:clip] data-expanded:opacity-100`.
- Inline layout adds `py-3 flex items-center justify-between gap-1.5`, plus `pr-10` (no trailing controls) or `pr-6` (with trailing controls) (297).
- Stacked layout adds `flex flex-col gap-2 py-2.5 pr-3.5`.
- Resolved:
  - Inline: padding left 14px, vertical 12px, right 40px or 24px; gap 6px.
  - Stacked: padding 10px vertical, 14px horizontal; gap 8px.
  - Text 14px/20px.

**Body (316-405)**
- Text column: `flex min-h-0 min-w-0 flex-col gap-0.5` (2px gap), plus `pr-5` (stacked) or `flex-1` (inline).
- Title row: `flex min-w-0 gap-2` (8px).
- Leading icon box: `flex h-lh w-4 shrink-0 items-center justify-center`.
- Type icon box: `[&>svg]:h-lh [&>svg]:w-4 [&_svg]:pointer-events-none [&_svg]:shrink-0`. The svg box is 16px wide and one line (20px) tall; the 24-unit glyph renders 16x16, vertically centred.

**Icon class (355), verbatim**
`in-data-[type=error]:text-destructive in-data-[type=info]:text-info in-data-[type=success]:text-success in-data-[type=warning]:text-warning in-data-[type=loading]:opacity-80`

**Icons (76-82)**
- error: `CircleAlertIcon` (circle r10; line 12,8 to 12,12; line 12,16 to 12.01,16), colour `--destructive`.
- info: `InfoIcon` (circle r10, `M12 16v-4`, `M12 8h.01`), colour `--info`.
- success: `CircleCheckIcon` (circle r10, `m9 12 2 2 4-4`), colour `--success`.
- warning: `TriangleAlertIcon` (`m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3`, `M12 9v4`, `M12 17h.01`), colour `--warning`.
- loading: `Spinner` (spinning), opacity .8.
- Icon paths were taken from the shipped lucide chunks.

**Title and description**
- Title (358): `min-w-0 wrap-break-word font-medium`, weight 500.
- Description (188): `min-w-0 select-text wrap-break-word text-muted-foreground`.
- Error descriptions of 180 or more characters get `line-clamp-4` (85-94). Copying still uses the full text.

**Trailing controls (366-402)**
- Row: `flex items-center gap-1.5`, plus `shrink-0` (inline) or `w-full justify-end` (stacked).
- Copy-error button (113-138):
  - `Button size="icon-micro" variant="ghost-muted"`, class `[--control-icon-color:currentColor] rounded-md text-muted-foreground/80 hover:bg-transparent hover:text-muted-foreground`.
  - Icon: MorphIcon Copy, morphing to Check, at 12px (Check gets `text-success`).
  - Tooltip "Copy error" / "Copied error".
- Additional and secondary actions: `Button size="xs"`; variant defaults to `"outline"` (285).
- Primary action: `Toast.Action` with `buttonVariants({size: "xs", variant})` plus `shrink-0`; variant defaults to `"default"` (283).
- Button sizes are defined in button.tsx (part A).

**Expandable details (140-259)**
- Toggle button: `inline-flex cursor-pointer items-center gap-1 rounded-md py-0.5 text-left text-xs font-medium text-muted-foreground transition-colors hover:text-foreground`.
- Chevron: MorphIcon ChevronDown or ChevronUp, `size-3.5 shrink-0 opacity-80`, stroke 2.25.
- Labels: "Show details" / "Hide details".
- Panel: `mt-2 max-h-40 min-h-0 overflow-y-auto overscroll-contain pr-0.5 select-text` (max height 160px).

**Description-trigger mode (226-252)**
- Row: `group flex min-w-0 w-full cursor-pointer select-none items-start gap-1.5 rounded-sm text-left outline-none ring-offset-background`, plus `transition-colors hover:bg-muted/40` and the ring recipe.
- The description underlines on hover: `underline-offset-2 decoration-muted-foreground/60 group-hover:underline`.
- Chevron: `mt-0.5 size-3.5 shrink-0 text-muted-foreground opacity-80`.

### 18.6 Anchored toasts (toast.tsx:693-789, anchoredCopyToast.ts)

**Positioner (723)**
- `z-100 max-w-[min(--spacing(64),var(--available-width))]`: max width `min(256px, available width)`.
- `sideOffset` defaults to 4px in app code (726).
- Base UI defaults (bundle): side `top`, align `center`, alignOffset 0, collisionPadding 5, positionMethod `absolute`.

**Root (731-732)**
- `dropdown-glass relative overflow-visible text-balance text-popover-foreground text-xs shadow-xl shadow-black/25 transition-[scale,opacity] data-ending-style:scale-98 data-starting-style:scale-98 data-ending-style:opacity-0 data-starting-style:opacity-0`
- Plus `rounded-md` (8px) when `tooltipStyle`, otherwise `rounded-lg` (10px).

**Animation**
- Enter and exit both use scale .98 and opacity 0, transitioning over 150ms `cubic-bezier(.4,0,.2,1)`.

**Tooltip-style content (738)**
- `pointer-events-auto px-2 py-1`: padding 8px x 4px, 12px/16px text. Only the title is rendered; the description is dropped.

**Non-tooltip anchored toasts (743-779)**
- Same close orb and body as the stacked toasts, without the opacity transition.

**Copy toasts (anchoredCopyToast.ts)**
- `ANCHORED_COPY_TOAST_TIMEOUT_MS = 1000` (4).
- Title "Copied!" (16) or "Failed to copy" with `error.message` as description (30-31).
- `tooltipStyle: true`, anchored to the trigger button.

---

## 19. Sidebar (`components/ui/sidebar.tsx`, `components/ui/sidebarState.ts`) and its app wiring

### 19.1 Constants (sidebar.tsx:25-30)

| constant | value | resolved |
|---|---|---|
| `SIDEBAR_COOKIE_NAME` | `"sidebar_state"` | |
| `SIDEBAR_COOKIE_MAX_AGE` | `60 * 60 * 24 * 7` | 7 days |
| `SIDEBAR_WIDTH` | `"16rem"` | 256px |
| `SIDEBAR_WIDTH_MOBILE` | `"calc(100vw - var(--spacing(3)))"` | see note |
| `SIDEBAR_WIDTH_ICON` | `"3rem"` | 48px |
| `SIDEBAR_RESIZE_DEFAULT_MIN_WIDTH` | `16 * 16` | 256 |

Note on `SIDEBAR_WIDTH_MOBILE`: `--spacing()` is a Tailwind build-time function and is not compiled inside an inline style. The intended value is 100vw - 12px. The actual rendered mobile sheet width is UNVERIFIED. The `var()` reference is likely invalid, and the portaled SheetPopup does not inherit the wrapper's `--sidebar-width`.

### 19.2 State
- `resolveSidebarState` (sidebarState.ts:3-9) returns `"expanded"` when `isMobile ? openMobile : open`, else `"collapsed"`.
- `useIsMobile` is `max-width: 767px`.

### 19.3 SidebarProvider (94-181)

**Open state**
- `defaultOpen = true`; `open` and `onOpenChange` can control it.
- `setOpen` writes the cookie via `cookieStore.set({name: "sidebar_state", value: "true"|"false", path: "/", expires: now + 7 days})` (124-129). Nothing reads this cookie (grep found no reader), so the sidebar always starts open.
- `toggleSidebar` flips `openMobile` on mobile, `open` otherwise (135-137).

**Wrapper element**
- Class (161): `group/sidebar-wrapper flex min-h-svh w-full max-sm:[--workspace-titlebar-control-size:--spacing(8)]`. Below 640px this makes the titlebar control size 32px.
- Attributes: `data-sidebar-state` and `data-slot="sidebar-wrapper"`.
- Inline style (166-174):
  - `--sidebar-width: 16rem`
  - `--sidebar-width-icon: 3rem`
  - `--workspace-titlebar-content-left: calc(var(--workspace-controls-left) + var(--workspace-titlebar-control-size) + var(--workspace-titlebar-control-gap))`
- The content-left value is 12 + 28 + 12 = 52px by default, or 90 + 28 + 12 = 130px on windowed macOS desktop (see 19.6).

**Shortcuts**
- No keyboard shortcut lives in sidebar.tsx (see 19.6).

### 19.4 Sidebar (183-323)

**Props**
- `side` `"left"|"right"` (default left).
- `variant` `"sidebar"|"floating"|"inset"` (default sidebar).
- `collapsible` `"offcanvas"|"icon"|"none"` (default offcanvas).
- `resizable` boolean or options (default false).
- Resizable options resolve only when not mobile and collapsible is not `none`: `maxWidth` defaults to +Infinity, `minWidth` to 256, `storageKey` to null (198-211).

**collapsible="none" (217-232)**
- `flex h-full w-(--sidebar-width) flex-col bg-sidebar surface-grain text-sidebar-foreground`, `data-slot="sidebar"`.

**Mobile (234-271)**
- `Sheet` plus `SheetPopup` with:
  - className `w-(--sidebar-width) max-w-none bg-sidebar surface-grain p-0 text-sidebar-foreground` (240).
  - `data-mobile="true"`, `data-sidebar="sidebar"`, `data-slot="sidebar"`, `showCloseButton={false}`.
  - Inline `--sidebar-width: SIDEBAR_WIDTH_MOBILE`.
- Inner element: `flex h-full w-full flex-col pb-safe pt-safe`, plus `pl-safe` or `pr-safe`.
- An sr-only header reads "Sidebar" / "Displays the mobile sidebar."
- tailwind-merge overrides SheetPopup's own left-side `w-[calc(100%-(--spacing(12)))] max-w-md` (sheet.tsx:96).

**Desktop (273-322)**

*Outer element (276)*
- `group peer hidden text-sidebar-foreground md:block`.
- Attributes: `data-collapsible` (equal to `collapsible` only when collapsed, else `""`), `data-side`, `data-slot="sidebar"`, `data-state`, `data-variant`.

*Gap (284-295), `data-slot="sidebar-gap"`*
- `relative w-(--sidebar-width) bg-transparent`
- `[[data-panel-animations=true]_&]:transition-[width] [[data-panel-animations=true]_&]:[transition-duration:var(--panel-animation-duration)] [[data-panel-animations=true]_&]:ease-out`
- `group-data-[collapsible=offcanvas]:w-0`
- `group-data-[side=right]:rotate-180`
- Floating or inset: `group-data-[collapsible=icon]:w-[calc(var(--sidebar-width-icon)+(--spacing(4)))]`. Otherwise: `group-data-[collapsible=icon]:w-(--sidebar-width-icon)`.

*Container (296-311), `data-slot="sidebar-container"`; receives `className` and `...props`*
- `fixed inset-y-0 z-10 hidden h-svh w-(--sidebar-width) md:flex`
- `[[data-panel-animations=true]_&]:transition-[left,right,width] [[data-panel-animations=true]_&]:[transition-duration:var(--panel-animation-duration)] [[data-panel-animations=true]_&]:ease-out`
- Left: `left-0 group-data-[collapsible=offcanvas]:left-[calc(var(--sidebar-width)*-1)]`. Right: `right-0 group-data-[collapsible=offcanvas]:right-[calc(var(--sidebar-width)*-1)]`.
- Floating or inset: `p-2 group-data-[collapsible=icon]:w-[calc(var(--sidebar-width-icon)+(--spacing(4))+2px)]`. Otherwise: `group-data-[collapsible=icon]:w-(--sidebar-width-icon) group-data-[side=left]:border-r group-data-[side=right]:border-l`.

*Inner (313), `data-sidebar="sidebar"`, `data-slot="sidebar-inner"`*
- `flex h-full w-full flex-col bg-sidebar surface-grain group-data-[variant=floating]:rounded-lg group-data-[variant=floating]:border group-data-[variant=floating]:border-sidebar-border group-data-[variant=floating]:shadow-sm/5`

**Resolved for the app configuration** (variant sidebar, side left, offcanvas)

*Gap*
- Width `--sidebar-width`; 0 when collapsed. It pushes the main content.

*Container*
- `position: fixed`, top 0, bottom 0, height 100svh, z-index 10.
- Width `--sidebar-width`, including a 1px right border.
- Border colour: the default `--contrast-border`, evaluated inside `[data-app-sidebar]`. Light zinc-200; dark `rgb(255 255 255 / 8%)`.
- Displayed only at 768px and up.
- Collapsed: `left: calc(width * -1)`, fully off screen.

*Inner*
- bg `--sidebar` plus `surface-grain`.
- Grain: SVG fractal noise, a 256px tile at 3.5% opacity; `background-image: var(--surface-grain)`, `background-size: 256px 256px` (index.css:1066-1070, 1677-1680).
- Icon mode (unused by the app): width 48px, or 48+16(+2)px for floating and inset.

**Animation**
- Width, left and right transition only when an ancestor has `data-panel-animations="true"`.
- Duration is `var(--panel-animation-duration)`; easing is `cubic-bezier(0,0,.2,1)`.
- AppSidebarLayout sets `--panel-animation-duration` to the user setting `panelAnimationDurationMs` (AppSidebarLayout.tsx:262-268, 309-314).
- That setting defaults to **0** with range 0 to 400 (packages/contracts/src/settings.ts:112-121).
- Animations are active only when the duration is above 0, reduced motion is off, and they are not suppressed (panelAnimations.ts:34-42).
- They are suppressed for the first two animation frames after every route change (panelAnimations.ts:15-32).
- So by default **the sidebar shows and hides instantly**.

### 19.5 SidebarTrigger (325-350)

**Button**
- `Button size="icon" variant="ghost"` with class `size-[var(--workspace-titlebar-control-size)]! [-webkit-app-region:no-drag]`. That is a 28px square on desktop and 32px below 640px.
- Attributes: `aria-pressed={isOpen}`, `data-sidebar="trigger"`, `data-slot="sidebar-trigger"`.
- Icon: `MorphIcon className="size-4"` (16px).
  - Open: `PanelLeftClose` = rect 18x18 at 3,3 rx 2; `M9 3v18`; `m16 15-3-3 3-3`.
  - Closed: `PanelLeft` = rect plus `M9 3v18`.
- MorphIcon (components/MorphIcon.tsx) wraps `morphicons/react` with `reducedMotion="user"`. Icons morph by spring path interpolation with the default "snappy" spring: stiffness 420, damping 30, unit mass (bundle MorphIcon-ETuySZc2.js).
- sr-only label "Toggle Sidebar".

**App placement (AppSidebarLayout.tsx:137-165)**
- Wrapper: `pointer-events-none fixed left-[var(--workspace-controls-left)] top-[var(--workspace-controls-top)] z-50 ml-px flex h-[var(--workspace-topbar-height)] items-center`. That is left equal to `--workspace-controls-left` plus 1px, top 0, height 52px, centred vertically.
- Tooltip: "Toggle main sidebar (shortcut label)", side bottom.
- Over stage artwork the button variant becomes `"media-navigation"` (button.tsx, part A; UNVERIFIED here).

### 19.6 Keyboard and macOS insets

**Shortcut**
- Default binding `{ key: "mod+b", command: "sidebar.toggle" }` (packages/shared/src/keybindings.ts:124).
- Handled on `window` keydown in the capture phase (AppSidebarLayout.tsx:96-135).
- Ignored inside `[data-keybinding-capture]`, and when the rich-text composer has focus (Mod+B is bold there).
- The desktop menu action `"sidebar.toggle"` also toggles.

**macOS insets**
- On windowed macOS desktop, `--workspace-controls-left` is `var(--desktop-window-controls-inset, 90px)` (AppSidebarLayout.tsx:60, 265-267).
- The preload sets that variable to `90 / zoomFactor` px (apps/desktop/src/preload.ts:50-61).

### 19.7 SidebarRail (356-534)

**Class (491-499), verbatim:**
```
-translate-x-1/2 group-data-[side=left]:-right-4 absolute inset-y-0 z-20 hidden w-4 after:absolute after:inset-y-0 after:left-1/2 after:w-[2px] hover:after:bg-sidebar-border group-data-[side=right]:left-0 sm:flex [[data-collapsible=offcanvas][data-state=collapsed]_&]:pointer-events-none
[[data-panel-animations=true]_&]:transition-all [[data-panel-animations=true]_&]:[transition-duration:var(--panel-animation-duration)] [[data-panel-animations=true]_&]:ease-out
in-data-[side=left]:cursor-w-resize in-data-[side=right]:cursor-e-resize
[[data-side=left][data-state=collapsed]_&]:cursor-e-resize [[data-side=right][data-state=collapsed]_&]:cursor-w-resize
group-data-[collapsible=offcanvas]:translate-x-0 hover:group-data-[collapsible=offcanvas]:bg-sidebar group-data-[collapsible=offcanvas]:after:left-full
[[data-side=left][data-collapsible=offcanvas]_&]:-right-2
[[data-side=right][data-collapsible=offcanvas]_&]:-left-2
```

**Element**
- `data-sidebar="rail"`, `data-slot="sidebar-rail"`, `tabIndex={-1}`, `type="button"`.
- Tooltip, side right: "Drag to resize sidebar" when resizable and open, otherwise "Toggle Sidebar". `aria-label` is "Resize Sidebar" or "Toggle Sidebar".

**Geometry** (open, left side; derived from CSS)
- 16px wide, full height, hidden below 640px.
- `right: -16px`, then `translateX(-50%)`.
- The containing block is the fixed container's padding box, inside its 1px right border. So the rail is centred on the border's inner edge, extending 8px to each side.
- The `after` line is 2px wide and starts at the rail centre.
- On hover the line becomes `--contrast-sidebar-border`. No other colour change on hover.

**Cursor**
- `w-resize` while open, `e-resize` while collapsed.
- During a drag the body cursor is `col-resize`.

**Collapsed offcanvas**
- `translate: 0`, `right: -8px`, the line at `left: 100%`, and `pointer-events: none`, so the rail is inert.

**Click**
- Toggles the sidebar unless it is resizable and open (then the click is a no-op).
- A drag that moved more than 2px also suppresses the click (444-460).

**Drag** (`useResizeDrag`, hooks/useResizeDrag.ts:12-125)
- Primary button only. Uses pointer capture.
- Sets `document.body` `cursor: col-resize` and `user-select: none`.
- Sets the gap and container `transition-duration` to 0ms for the duration.
- Width = start width + pointer delta. It is applied once per animation frame by writing `--sidebar-width` on the wrapper, and clamped to [minWidth, maxWidth].
- `shouldAcceptWidth` can veto a value.
- A window blur ends the drag and commits it.
- On finish the width is saved to localStorage as JSON under `storageKey` and `onResize` is called.
- On mount the stored width is restored, clamped, before paint (462-482).

**App configuration** (AppSidebarLayout.tsx:317-344; components/threadSidebarWidth.ts:1-35)

*Sidebar props*
- `side="left" collapsible="offcanvas"`, default variant.
- `data-app-sidebar=""`, which lands on the sidebar-container, so the index.css:1195-1237 overrides cover the container, inner, rail and contents.
- `role="navigation"`, `aria-label` "Threads" or "Settings".

*Resize limits*
- minWidth = `max(208, ceil(measured brand width))`.
- maxWidth = `max(min, floor(viewport) - 640)`.
- Growing is accepted only while the wrapper width minus the new width stays at least 640px.
- Storage key `"chat_thread_sidebar_width"`.

*Initial and stored width*
- Default width 256px.
- Stored widths below 208 are raised to 208.
- Initial width is `min(preferred, viewport - 640)`.
- The wrapper gets `--sidebar-width: <clamped>px` and class `h-dvh! min-h-0!`.

*Reset*
- Double-clicking the rail removes the stored width and resets to the default (248-255, 343).

### 19.8 Content parts

**SidebarInput (537-548)**
- `Input unstyled` with `[&_[data-slot=input]]:h-auto [&_[data-slot=input]]:p-0 [&_[data-slot=input]]:font-medium [&_[data-slot=input]]:text-sidebar-foreground [&_[data-slot=input]]:text-sm [&_[data-slot=input]]:leading-normal [&_[data-slot=input]]:placeholder:text-sidebar-muted-foreground`.
- Resolved: 14px with line-height 1.5 (21px), weight 500, no padding.

**SidebarInset (550-562)**
- `<main>`: `relative flex min-w-0 w-full flex-1 flex-col bg-background surface-grain`.
- Inset variant only, at 768px and up: `md:peer-data-[variant=inset]:peer-data-[state=collapsed]:ms-2 md:peer-data-[variant=inset]:m-2 md:peer-data-[variant=inset]:ms-0 md:peer-data-[variant=inset]:rounded-xl md:peer-data-[variant=inset]:shadow-sm/5`. That is margin 8px, start margin 0 (8px when collapsed), radius 14px, `shadow-sm/5`.
- The app uses variant `sidebar`, so only the first line applies.

**SidebarHeader (564-573)**
- `flex flex-col gap-2 p-2` (8px). No usages found in the app.

**SidebarFooter (575-584)**
- `flex flex-col gap-2 px-[var(--sidebar-content-inset)] py-1`: gap 8px, padding 8px x 4px.

**SidebarContent (586-624)**
- Optional `fixedHeader` in `w-full shrink-0`.
- ScrollArea props: `hideScrollbars scrollFade scrollFadePadding={false} viewportTabIndex={-1}`, className `h-auto min-h-0 flex-1 [&>[data-slot=scroll-area-viewport]]:[--fade-size:0.75rem]`.
  - No scrollbars at all.
  - 12px proportional fades at top and bottom.
  - The viewport is out of the tab order.
  - `.h-auto` beats `.size-full` height by source order (48229 vs 45412).
- Content div: `flex w-full min-w-0 flex-col [overflow-anchor:none] group-data-[collapsible=icon]:overflow-hidden [&>[data-sidebar=group]+[data-sidebar=group]]:pt-0`, plus `[&>[data-sidebar=group]:first-child]:pt-0` with a fixed header.

**SidebarGroup (626-638)**
- `relative flex w-full min-w-0 flex-col p-[var(--sidebar-content-inset)]`: 8px padding. Stacked groups share the inset (pt 0).

**SidebarMenu (640-649)**
- `<ul>`: `flex w-full min-w-0 flex-col gap-1` (4px gap).

**SidebarMenuItem (651-660)**
- `<li>`: `group/menu-item relative`.

### 19.9 SidebarMenuButton

**cva (662-683), base verbatim:**
```
peer/menu-button flex w-full cursor-pointer items-center gap-[var(--sidebar-control-gap)] overflow-hidden text-left outline-hidden ring-ring transition-[width,height,padding] hover:bg-sidebar-row-hover hover:text-sidebar-foreground focus-visible:ring-2 active:bg-sidebar-row-active active:text-sidebar-foreground disabled:pointer-events-none disabled:opacity-64 aria-disabled:pointer-events-none aria-disabled:opacity-64 data-[active=true]:bg-sidebar-row-selected data-[active=true]:font-medium data-[active=true]:text-sidebar-foreground data-[state=open]:hover:bg-sidebar-row-hover data-[state=open]:hover:text-sidebar-foreground group-data-[collapsible=icon]:size-8! group-data-[collapsible=icon]:p-[var(--sidebar-content-inset)]! [&>span:last-child]:truncate [&>svg:not([class*='size-'])]:size-4 [&>svg]:shrink-0 [&>svg]:text-[var(--sidebar-icon-color)] hover:[&>svg]:text-sidebar-foreground active:[&>svg]:text-sidebar-foreground data-[active=true]:[&>svg]:text-sidebar-foreground
```

**Sizes (671-675), verbatim**
- default: `h-8 rounded-[var(--control-radius)] px-[var(--sidebar-row-content-inset)] py-1.5 text-sm`
- icon: `size-8 justify-center rounded-[var(--control-radius)] p-0`
- lg: `h-12 rounded-lg p-2 text-sm group-data-[collapsible=icon]:p-0!`
- sm: `h-7 rounded-lg p-2 text-xs`

**Variants (677-680), verbatim**
- default: `font-medium text-sidebar-muted-foreground/80`
- outline: `bg-sidebar-control-surface ring-1 ring-sidebar-border`

**Component (685-736)**
- Attributes: `data-active`, `data-sidebar="menu-button"`, `data-size`, `data-slot="sidebar-menu-button"`. Renders a `button` via `useRender`.
- Optional tooltip, side right, align center, shown only when the sidebar is collapsed and not mobile.

**Resolved, default size and variant**

*Box*
- Height 32px, radius 8px, padding 10px x 6px, gap 8px.
- Text 14px/20px, weight 500, colour sidebar-muted-foreground at 80%.
- The last span truncates.
- Icons are 16px in `--sidebar-icon-color`.

*States*
- Hover: bg `--sidebar-row-hover`; text and icon sidebar-foreground.
- `:active`: bg `--sidebar-row-active`; text and icon foreground.
- `data-active=true` (selected): bg `--sidebar-row-selected`; weight 500; text and icon foreground.
- Focus-visible: 2px `--ring` ring with no offset, outline hidden. For the outline variant tailwind-merge makes the ring colour sidebar-border.
- Disabled or aria-disabled: opacity .64 and no pointer events.
- Transition: width, height and padding over 150ms.
- Icon mode: 32px square with 8px padding.

*Other sizes*
- icon: 32px square, no padding.
- lg: 48px tall, radius 10px, padding 8px.
- sm: 28px tall, radius 10px, padding 8px, 12px text.
- Outline variant: bg control surface plus a 1px sidebar-border ring.

**Colours inside the app sidebar ([data-app-sidebar], index.css:1195-1237)**

| token | light | dark |
|---|---|---|
| sidebar bg | zinc-50 | `#000` |
| row hover | zinc-25 | `color-mix(in srgb, #f1f3f7 8%, transparent)` |
| row active | white | same mix at 11% |
| row selected | white | same mix at 7% |
| foreground | zinc-800 | `#f1f3f7` |
| muted foreground | zinc-500 | `#a3a3a3` |
| control surface | zinc-100 | `#0a0a0a` |
| border | zinc-200 | `rgb(255 255 255 / 8%)` |
| accent | zinc-100 | `#191a1d` |

**`--sidebar-icon-color` caveat**
- It is declared only on `:root` (index.css:104-108; the compiled CSS has a single declaration) as `color-mix(in srgb, var(--contrast-sidebar-muted-foreground) 60%, var(--sidebar))`.
- Custom properties resolve where they are declared. So inside `[data-app-sidebar]` it inherits the root value:
  - Light: zinc-500 60% / zinc-50 40%. This equals the override palette anyway.
  - Dark: `color-mix(in srgb, [neutral-500 90% + white] 60%, [neutral-950 97% + white])`. That is not derived from `#a3a3a3` and `#000`.
- Derived from CSS rules; UNVERIFIED at runtime.

### 19.10 Sub-menus

**SidebarMenuSub (738-751)**
- `mx-3.5 flex min-w-0 translate-x-px flex-col gap-1 border-sidebar-border border-l px-2.5 py-0.5`, plus `group-data-[collapsible=icon]:hidden`.
- Resolved: margin-inline 14px, translateX 1px, gap 4px, 1px left border in sidebar-border, padding 10px x 2px.

**SidebarMenuSubItem (753-762)**
- `<li>`: `group/menu-sub-item relative`.

**SidebarMenuSubButton (764-794)**
- Renders an `a`. Size `"sm" | "md"`, default md.
- Classes (776-781):
  - `-translate-x-px flex h-7 min-w-0 cursor-pointer items-center gap-2 overflow-hidden rounded-lg px-2 text-sidebar-foreground outline-hidden ring-ring hover:bg-sidebar-row-hover hover:text-sidebar-foreground focus-visible:ring-2 active:bg-sidebar-row-active active:text-sidebar-foreground disabled:pointer-events-none disabled:opacity-64 aria-disabled:pointer-events-none aria-disabled:opacity-64 [&>span:last-child]:truncate [&>svg:not([class*='size-'])]:size-4 [&>svg]:shrink-0 [&>svg]:text-sidebar-muted-foreground`
  - `data-[active=true]:bg-sidebar-row-selected data-[active=true]:text-sidebar-foreground`
  - sm `text-xs`, md `text-sm`
  - `group-data-[collapsible=icon]:hidden`
- Resolved: 28px tall, radius 10px, padding-inline 8px, gap 8px, translateX -1px, icons 16px muted.

### 19.11 Where the parts are used
- SidebarMenuButton: LegacySidebar.tsx, sidebar/SidebarThreadHeader.tsx, sidebar/SidebarChrome.tsx, settings/SettingsSidebarNav.tsx, clerk/T3ConnectSidebarSignIn.tsx.
- SidebarMenuSub and SidebarMenuSubButton: only LegacySidebar.tsx.
- SidebarRail: only AppSidebarLayout.tsx.
- Thread rows in components/Sidebar.tsx use only SidebarContent and SidebarGroup from this file. Their own row styling is not covered here (UNVERIFIED).

---

## 20. StandalonePage (`components/ui/standalone-page.tsx`)

Used for entry pages outside the app shell (comment at 12).

**Backdrops (3-10), verbatim**
- pairing: `absolute inset-x-0 top-0 h-44 bg-[radial-gradient(44rem_16rem_at_top,color-mix(in_srgb,var(--color-emerald-500)_14%,transparent),transparent)]`
- error: `absolute inset-x-0 top-0 h-44 bg-[radial-gradient(44rem_16rem_at_top,color-mix(in_srgb,var(--color-red-500)_16%,transparent),transparent)]`
- brand: `absolute inset-x-0 top-0 h-72 bg-[radial-gradient(48rem_20rem_at_top,color-mix(in_srgb,var(--color-blue-500)_12%,transparent),transparent)]`
- Pairing also adds (27): `absolute inset-y-0 left-0 w-72 bg-[radial-gradient(28rem_18rem_at_left,color-mix(in_srgb,var(--color-sky-500)_10%,transparent),transparent)]`.
- Overlay (31-34):
  - Brand: `absolute inset-0 bg-[linear-gradient(145deg,color-mix(in_srgb,var(--background)_94%,var(--color-black))_0%,var(--background)_62%)]`
  - Others: `absolute inset-0 bg-[linear-gradient(145deg,color-mix(in_srgb,var(--background)_90%,var(--color-black))_0%,var(--background)_55%)]`
- The backdrop layer is `pointer-events-none absolute inset-0 opacity-80` (24).

**Page (23)**
- `relative flex min-h-screen items-center justify-center overflow-hidden bg-background px-4 py-10 text-foreground sm:px-6`.
- Padding 16px x 40px (24px horizontal on desktop).

**Card (39)**
- `` `relative w-full max-w-xl rounded-2xl border border-border/80 shadow-2xl shadow-black/20 backdrop-blur-md ${tone === "brand" ? "overflow-hidden bg-card/94" : "bg-card/90"}` ``
- Resolved: max width 576px, radius 18px, 1px border at border/80, shadow `0 25px 50px -12px rgb(0 0 0/20%)`, backdrop blur 12px, bg card at 94% (brand) or 90%.
- Body (42): `p-6 sm:p-8` (24px, 32px on desktop).

**Header (60-64)**
- Eyebrow: `text-[11px] font-semibold tracking-[0.18em] text-muted-foreground uppercase`.
- h1: `mt-3 text-2xl font-semibold tracking-tight sm:text-3xl`. That is 24px/32px narrow, 30px/36px desktop, letter-spacing -0.025em, margin-top 12px.
- Paragraph: `mt-2 text-sm leading-relaxed text-muted-foreground`. That is 14px with line-height 1.625 (22.75px).

The gradient arbitrary classes were not individually checked in the compiled CSS (UNVERIFIED compile form; standard Tailwind arbitrary values).

---

## 21. Wizard (`components/ui/wizard.tsx`)

Composes Dialog parts from dialog.tsx; the dialog chrome itself is documented in part A.

**WizardPopup (9-27)**
- `DialogPopup` with className `overflow-x-hidden overflow-y-auto` plus `max-w-xl` (576px) or, with `size="wide"`, `max-w-3xl` (768px).
- Inner element: `flex min-h-0 flex-col`.

**WizardHeader (29-49)**
- `DialogHeader`: `flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4` (dialog.tsx:113). A WizardPanel makes the bottom padding 12px.
- `DialogTitle`: `wrap-anywhere font-semibold text-xl leading-none` (dialog.tsx:146). It is sr-only when `identity` is supplied.
- `DialogDescription`: `text-muted-foreground text-sm` (dialog.tsx:156).

**WizardFooter (51-68)**
- `DialogFooter variant="bare"`: `flex flex-col-reverse gap-2 px-6 sm:flex-row sm:justify-end sm:rounded-b-[calc(var(--radius-2xl)-1px)]` plus `py-4` (dialog.tsx:132-134).
- With a `leading` node it becomes `sm:justify-between`, and the children wrapper is `flex flex-col-reverse gap-2 sm:flex-row`.

**WizardSteps (70-138)**
- ol (88): `grid auto-cols-fr grid-flow-col gap-1 rounded-xl bg-zinc-25 p-1 ring-1 ring-black/5 dark:bg-white/4 dark:ring-white/5`.
  - Equal columns, gap 4px, padding 4px, radius 14px.
  - bg zinc-25 with a 1px black 5% ring; dark bg white 4% with a white 5% ring.
- Step (99): `flex w-full min-w-0 items-center gap-2 rounded-lg px-2.5 py-2 text-left outline-none focus-visible:ring-2 focus-visible:ring-ring max-sm:justify-center max-sm:px-2`.
  - Gap 8px, radius 10px, padding 10px x 8px.
- Clickable step (101): `cursor-pointer hover:bg-card disabled:cursor-default disabled:hover:bg-transparent`.
- Current step (103): `bg-card text-foreground shadow-xs ring-1 ring-black/5 hover:bg-card dark:shadow-none dark:ring-white/5`.
  - Shadow `0 1px 2px 0 #0000000d` plus a 1px black 5% ring.
- Number disc (111): `grid size-5 shrink-0 place-items-center rounded-full text-sm font-medium ring-1`, 20px.
  - Done (113): `bg-primary text-primary-foreground ring-primary`, with `CheckIcon size-4`.
  - Current (115): `bg-primary/10 text-primary ring-primary/30`.
  - Upcoming (116): `bg-card text-muted-foreground ring-black/10 dark:bg-white/5 dark:ring-white/10`.
- Label (124-125): `min-w-0 truncate text-sm font-medium max-sm:hidden`, coloured `text-foreground` when current, otherwise `text-muted-foreground`.

**WizardPanel (140-160)**
- `data-slot="dialog-panel"`.
- Class (153): `min-w-0 space-y-4 bg-zinc-25/80 px-6 py-5 ring-1 ring-black/5 dark:bg-white/2 dark:ring-white/5`.
  - Padding 24px x 20px, 16px vertical rhythm.
  - bg zinc-25 at 80%; dark white 2%.
- Content sits in `AnimatedHeight` (components/AnimatedHeight.tsx):
  - Height transitions over 200ms `cubic-bezier(0,0,.2,1)`, with no transition under reduced motion.
  - Height is measured as `ceil(scrollHeight)` via ResizeObserver plus two animation frames.
  - `overflow: hidden` applies only while a height change animates. It is released on transitionend or after a 250ms fallback.

---

## 22. DiscoveryList (`components/ui/discovery-list.tsx`)

**List (5)**
- `flex flex-col divide-y divide-border/60 overflow-hidden rounded-xl border border-border/70 bg-background`.
- Radius 14px, 1px border at border/70, 1px dividers at border/60, bg background.

**Row (24-36)**
- `button`, class (27): `group flex w-full items-center gap-3 px-3 py-3 text-left hover:bg-accent/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-64`.
- Resolved: padding 12px, gap 12px, hover accent at 40%, inset 2px ring on focus.
- Text column (30): `flex min-w-0 flex-1 flex-col`.
- Title (31): `truncate text-sm font-medium text-foreground`.
- Description (32): `truncate text-xs text-muted-foreground`.

---

## 23. MiddleTruncate (`components/ui/middle-truncate.tsx`)

**Element**
- `span` (32): `inline-flex min-w-0 max-w-full overflow-hidden whitespace-nowrap`.
- Head (37): `min-w-0 truncate`. Tail (38): `shrink-0`. Unsplit (41): `min-w-0 truncate`.
- `title` is the full value unless `showTitle={false}` (31).

**Split rule (47-73)**
- `DEFAULT_TAIL = 10`; `MAX_SEGMENT_TAIL = 16`.
- Splits by code points.
- For paths, the tail is the last path segment if that segment is 16 characters or fewer, otherwise 10.
- No split when the length is at most tail + 4.

---

## 24. PanelTabCloseButton (`components/ui/panel-tab-close-button.tsx`)

**Classes**
- Button (22): `cursor-pointer group/close relative flex size-4 shrink-0 items-center justify-center rounded-sm hover:bg-muted`. That is 16px, radius 6px, hover bg muted.
- Identity slot (26): `relative flex size-3 items-center justify-center group-hover/tab:hidden group-focus-visible/close:hidden` (12px).
- Close glyph (29): lucide `X` with `hidden size-3 group-hover/tab:block group-focus-visible/close:block` (12px).

**Behaviour**
- While the parent `group/tab` row is hovered, or the button has keyboard focus, the X replaces the identity glyph instantly.
- Optional Tooltip (35-40).

---

## 25. QRCodeSvg (`components/ui/qr-code.tsx`)

**Props and defaults (54-60)**
- `size = 128`, `level = "L"`, `marginSize = 0`, `foregroundColor = "#000"`, `backgroundColor = "#fff"`.
- ECC map L/M/Q/H uses `QrCode.Ecc` from `@t3tools/shared/qrCode` (15-20).

**Rendering**
- svg: `viewBox="0 0 N N"` where N = modules + 2*margin; `width` and `height` = `size`; `shapeRendering="crispEdges"`.
- `role="img"`, `aria-label` and a `<title>` only when `title` is set (66-79).
- A background rect, then one path. Each horizontal run of dark modules is emitted as `M{x} {y}h{len}v1H{x}z` (22-50).
- Memoized (52).

---

## 26. Card and panel surfaces (there is no card.tsx)

### 26.1 Canonical card: `SettingsGroup`

**Source**
- components/settings/SettingsGroup.tsx:6-29; doc comment "Shared settings card surface".
- It is also the body of every `SettingsSection`. Usage counts: 59 `<SettingsSection>`, 13 direct `<SettingsGroup>`, 156 `<SettingsRow>`.

**Classes (18-26)**
- Always: `relative overflow-visible text-foreground`
- grouped (default): `rounded-xl border border-border/60 bg-card/40 shadow-xs/5`
- plain: `space-y-1`
- grouped and divided (default true): `[&>*+*]:border-t [&>*+*]:border-border/50 [&>[data-slot=settings-row]]:rounded-none`

**Resolved**
- Radius 14px.
- Border 1px `--contrast-border` at 60%: zinc-200 at 60% light, white 3.6% dark.
- Background `--card` at 40%: white at 40% over the page light; `color-mix(in srgb, neutral-950 97%, white)` at 40% dark.
- Shadow `0 1px 2px 0 rgb(0 0 0/5%)`.
- Rows are separated by a 1px top border at border/50, with row radius 0.

### 26.2 SettingsSection (settings/settingsLayout.tsx:175-226)
- Section: `space-y-2.5`, a 10px gap between the header and the card.
- Header row (209): `flex min-h-7 items-start justify-between gap-4 px-3 sm:px-4`.
- Title wrapper (211): `flex min-w-0 items-center gap-1`.
- h2 (212): `flex min-h-7 items-center gap-2 text-sm font-normal text-foreground/70`. That is 14px, weight 400, foreground at 70%, min-height 28px.
- Header action slot (218): `flex min-h-7 min-w-7 items-center justify-end`.

### 26.3 SettingsRow (settings/settingsLayout.tsx:263-506)

**Root (463-466)**
- `@container/settings-row rounded-xl px-3 sm:px-4 aria-disabled:opacity-64 aria-disabled:[&_*]:text-muted-foreground`, plus `pt-3 pb-1` (with children) or `py-3`.
- Padding 16px horizontal on desktop (12px narrow), 12px vertical.

**Layout (469)**
- `flex flex-col gap-3 @min-[32rem]/settings-row:grid @min-[32rem]/settings-row:grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] @min-[32rem]/settings-row:items-center @min-[32rem]/settings-row:gap-8`.
- When the row is at least 512px wide (container query): a two-column grid of `minmax(0,1fr)` and `minmax(160px,auto)`, gap 32px, centred.
- Below that: stacked with a 12px gap.

**Text and controls**
- Text column (470): `min-w-0 flex-1 space-y-1`.
- Title row (471): `flex min-h-5 items-center gap-1.5`.
- Title (472): `text-sm font-medium text-foreground`.
- Indicator and reset slots (474, 478): `inline-flex h-5 w-5 shrink-0 items-center justify-center`.
- Description (483): `max-w-xl text-xs leading-normal text-muted-foreground/80`. That is 12px with an 18px line, muted at 80%, max width 576px.
- Status (488): `pt-0.5 text-xs text-muted-foreground`.
- Control column (492): `flex w-full min-w-0 shrink-0 items-center gap-2 @min-[32rem]/settings-row:w-auto @min-[32rem]/settings-row:justify-end`.

### 26.4 Settings page frame
- Scroller (settingsLayout.tsx:574): `topbar-scroll-fade scrollbar-gutter-both flex-1 overflow-y-auto` (`scrollbar-gutter: stable both-edges`).
- Content (577) uses `WorkspacePageContainer` (components/WorkspacePageContainer.tsx:7-23):
  - `mx-auto flex w-full flex-col gap-6 px-5 pt-6 pb-12 sm:px-6`, with `gap-8` from settings.
  - `max-w-4xl` (896px) readable, `max-w-5xl` (1024px) wide, `max-w-6xl` (1152px) expanded.
- Unavailable group (238-243): `border-border/60 bg-muted/20 py-1.5`, message row `flex items-start gap-2 px-3 py-2 text-xs leading-relaxed text-muted-foreground sm:px-4`, warning icon `mt-0.5 size-3.5 shrink-0 text-warning`.
- Search-jump highlight (index.css:887-907):
  - `box-shadow 0 0 0 2px color-mix(in oklab, var(--color-primary) 70%, transparent)` pulsing over 650ms `ease-in-out`, twice.
  - border-radius .75rem.

### 26.5 Other card-like surfaces (verbatim, for reference)
- Diagnostics cards: `overflow-hidden rounded-2xl border border-border/70 bg-card shadow-xs/5` (settings/ResourceTelemetryDiagnostics.tsx:1254, 1277, 1294).
  - Grid variant: `grid overflow-hidden rounded-2xl border border-border/70 bg-card shadow-xs/5 md:grid-cols-2 md:divide-x md:divide-border/60` (1117).
  - `shadow-sm/5` variant (1009).
- Theme cards:
  - `cursor-pointer overflow-hidden rounded-xl border border-border/70 bg-card/60 transition-colors hover:bg-accent/10` (settings/ThemeSettings.tsx:157).
  - `group flex min-w-0 flex-col gap-3 rounded-xl border border-border/70 bg-card/60 p-3 transition-colors hover:bg-accent/20` (settings/ThemeSearchSection.tsx:374).
- Chat artifact card: `my-[0.65rem] flex w-full min-w-0 items-center gap-3 rounded-xl border border-border/70 bg-card/60 px-3 py-2.5 text-foreground shadow-xs` (ChatMarkdown.tsx:318).
- Proposed plan card: `rounded-3xl border border-border/80 bg-card/70 p-4 sm:p-5` (chat/ProposedPlanCard.tsx:164).
- Chat index empty card: `w-full max-w-xl rounded-3xl border border-border/55 bg-card/20 px-8 py-12 shadow-sm/5` (routes/_chat.index.tsx:138).
- Sticky diagnostics table header: `sticky top-0 z-10 border-b border-border/60 bg-card text-2xs uppercase tracking-widest text-muted-foreground/70` (settings/DiagnosticsSettings.tsx:365, 591).
- The DiscoveryList (section 22), StandalonePage card (section 20) and Wizard steps and panel (section 21) are the other reusable panel surfaces.
- Floating glass surfaces use `dropdown-glass` (toasts, section 18) or `alert-glass` (section 7).

---

## 27. UNVERIFIED items (collected)

1. Desktop font and icon size of `segmented` and `compact` toggles. They are 14px text and 16px icons at 640px and up, derived from tailwind-merge rules and the verified CSS source order, but not observed in a running app.
2. Rendered width of the mobile sidebar Sheet. `SIDEBAR_WIDTH_MOBILE` uses `var(--spacing(3))` in an inline style.
3. `--sidebar-icon-color` inside a dark `[data-app-sidebar]` resolving from the `:root` values. This is from custom-property inheritance rules and was not checked at runtime.
4. Exact SidebarRail pixel placement relative to the container border. It is derived from containing-block rules.
5. Meaning of the Base UI toast swipe constants other than the 40px threshold (`10`, `.5`, `1`).
6. Whether Base UI's ScrollArea injects a style element that hides the viewport's native scrollbars. A style element is emitted by the root (bundle), but its contents were not read.
7. Whether a closed Collapsible panel gets the `hidden` attribute.
8. Compiled form of the StandalonePage radial and linear gradient arbitrary classes.
9. Button sizes and variants referenced by toasts, SidebarTrigger and the copy button (`xs`, `icon-micro`, `icon`, `ghost`, `ghost-muted`, `outline`, `media-navigation`). These are in button.tsx (part A).
10. Default value of the user "interface size" setting. All px values here assume a 16px root.
11. The exact text format of the shortcut label in the sidebar trigger tooltip.
12. Styling of thread rows in components/Sidebar.tsx. It is not part of these primitives.
