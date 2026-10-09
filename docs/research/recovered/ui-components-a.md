# T3 Code web UI: component inventory, part A

Spec source: the official T3 Code web UI at tag `v0.0.46-nightly.20261009.2861`.

- Repo: `/Users/mrm/CandyWrapper-research/t3code`. All component paths below are relative to `apps/web/src/components/ui/` unless a longer path is given. `index.css` means `apps/web/src/index.css`.
- Compiled stylesheet of the shipped build: `~/.t3/runtime/versions/0.0.46-nightly.20261009.2861/client/assets/main-pEuGmXiu.css` (Tailwind v4.3.3, minified).
- Shipped JS bundle: same `assets/` folder (`utils-5_-Qnp8u.js`, `select-DtYp5ZPi.js`, `popover-Dewldpee.js`, `ComboboxClear-Dng79eZR.js`, `ChatMarkdown-DkQvpFEN.js`, `command-BD0RTth6.js`, `dialog-D1ZA0Pvc.js`). Used to read base-ui defaults, because no `node_modules` are installed.
- Library versions (pnpm-lock.yaml): `@base-ui/react@1.5.0` (line 2217), `class-variance-authority@0.7.1` (7168), `tailwind-merge@3.6.0` (11096).

## 0. Method and how to read the citations

1. Every component file listed in the brief was read in full, plus `scroll-area.tsx` (used by Combobox, Autocomplete, Command and DialogPanel), `lib/utils.ts`, and, for the summary table only, `toggle.tsx`, `switch.tsx` and `spinner.tsx`.
2. Every class literal in these files was checked against the shipped JS. All of them are present verbatim (button 30/30, input 9/9, textarea 4/4, input-group 12/12, number-field 4/4, select 17/17 real class strings, combobox 16/16, autocomplete 11/11, menu 12/12, popover 12/12, tooltip 7/7, preview-card 1/1, dialog-styles 3/3, dialog 7/7, alert-dialog 6/6, sheet 10/10, command 10/10, calendar 13/13, scroll-area 7/7, color-picker spot checked). The source at this tag is the shipped build.
3. Every class token was resolved against the compiled CSS with a small parser. `#N` after a rule means "leaf style rule number N in document order of main-pEuGmXiu.css" (0-based, from my parse). The file is minified, so line numbers are useless. When two rules have equal specificity, the higher `#N` wins. I use this to settle state conflicts.
4. Pixel values assume root font size 16px and `--spacing: .25rem` (4px). "<640" means viewport narrower than 640px, ">=640" means `@media (width>=40rem)`. The desktop app window is normally >=640, so the ">=640" column is the desktop value.
5. Colours: the CSS value is given first. sRGB hex and Display P3 numbers were computed by me with the standard OKLab to linear sRGB matrices; they match Tailwind's published hex values for zinc and red-500. Values marked "out of sRGB" render in P3 on wide-gamut Macs in Chromium.
6. Things I could not verify are marked UNVERIFIED.

## 1. Global rules every component inherits

### 1.1 cn() and tailwind-merge

- `utils.ts:10`: `const twMerge = extendTailwindMerge({ extend: { theme: { text: ["2xs", "3xs", "4xs", "5xs"] } } });`
- `utils.ts:12-14`: `cn(...inputs) = twMerge(cx(inputs))`.
- cva concatenates base, then each variant in the key order of its `variants` object, then `className`. `cn` then removes earlier classes that conflict with later ones. tailwind-merge only treats classes as conflicting when their variant prefixes are identical, so `text-xs` removes `text-base` but does not remove `sm:text-sm`. This creates several size quirks documented below (Button compact, icon-micro, icon-tiny; Select compact).
- tailwind-merge in the bundle recognises `color-mix(...)` as a colour (`Wbe=/^(rgba?|hsla?|hwb|(ok)?(lab|lch)|color-mix)\(.+\)$/` in utils-5_-Qnp8u.js), so an arbitrary `border-[color-mix(...)]` replaces `border-ring`.

### 1.2 Design tokens (default theme, contrast settings at default)

At default appearance contrast (`--appearance-contrast-base: 100%`, `--appearance-contrast-boost: 0%`, index.css:91-94) every `--contrast-X` equals `X` (definitions index.css:1521-1633). Utilities map: `text-foreground` to `--contrast-foreground`, `text-muted-foreground` to `--contrast-muted-foreground`, `border-input` and `bg-input` to `--contrast-input`, `bg-border` and the default border colour to `--contrast-border`, `text-placeholder` to `--contrast-placeholder`, `text-secondary-label` to `--contrast-secondary-label`, `text-icon-muted` to `--contrast-icon-muted`, `text-accent-foreground` to `--contrast-accent-foreground`, `text-popover-foreground` to `--contrast-popover-foreground` (index.css:221-276).

| Token | Light (index.css:1081-1149) | Light computed | Dark (index.css:1151-1189) | Dark computed |
|---|---|---|---|---|
| `--background` | zinc-25 `oklch(99.2% 0 0)` (1084) | #fcfcfc | neutral-950 `oklch(14.5% 0 0)` (1155) | #0a0a0a |
| `--foreground` | zinc-800 `oklch(27.4% .006 286.033)` (1093) | #27272a | neutral-100 `oklch(97% 0 0)` (1157) | #f5f5f5 |
| `--card`, `--popover` | `#fff` (1094, 1096) | #ffffff | `color-mix(in srgb, var(--background) 97%, white)` (1158, 1160) | #111111 |
| `--popover-foreground` | zinc-800 (1097) | #27272a | neutral-100 (1161) | #f5f5f5 |
| `--primary` (also `--ring`, 1121) | `oklch(0.488 0.217 264)` (1098) | #1b4ed8, P3 (0.1618, 0.3028, 0.8151) | `oklch(0.571 0.21 264)` (1162) | #346bf1, P3 (0.2588, 0.4147, 0.9122) |
| `--primary-foreground` | `#fff` (1099) | | `#fff` | |
| `--secondary`, `--muted` | zinc-50 `oklch(98.5% 0 0)` (1100, 1102) | #fafafa | white at 3% alpha (1163, 1165) | rgba(255,255,255,0.03) |
| `--secondary-foreground` | zinc-800 (1101) | #27272a | neutral-100 (1164) | #f5f5f5 |
| `--muted-foreground` (also `--placeholder`, `--secondary-label`, `--icon-muted`, 1104-1106) | zinc-500 `oklch(55.2% .016 285.938)` (1103) | #71717b | `color-mix(in srgb, neutral-500 90%, white)` (1166) | #818181 (compiled fallback is also #818181) |
| `--accent` | zinc-100 `oklch(96.7% .001 286.375)` (1112) | #f4f4f5 | white 4% (1167) | rgba(255,255,255,0.04) |
| `--accent-foreground` | zinc-900 `oklch(21% .006 285.885)` (1113) | #18181b | neutral-100 (1168) | #f5f5f5 |
| `--border` | zinc-200 `oklch(92% .004 286.32)` (1119) | #e4e4e7 | white 6% (1173) | rgba(255,255,255,0.06) |
| `--input` | zinc-300 `oklch(87.1% .006 286.286)` (1120) | #d4d4d8 | white 8% (1174) | rgba(255,255,255,0.08) |
| `--destructive` (= `--error`, 1114, 1118) | red-500 `oklch(63.7% .237 25.331)` | #fb2c36, P3 (0.9037, 0.2626, 0.2533) | `color-mix(in srgb, red-500 90%, white)` (1169) | #fb414a (compiled fallback #fb414a) |
| `--destructive-foreground` (1115, 1122) | red-700 `oklch(50.5% .213 27.518)` | #c10007 clipped, out of sRGB, P3 (0.6927, 0.1162, 0.1047) | red-400 `oklch(70.4% .191 22.216)` (1170) | #ff6467 clipped, out of sRGB, P3 (0.9335, 0.4317, 0.4235) |
| `--warning` | amber-500 `oklch(76.9% .188 70.08)` (1127) | #fe9a00 clipped, P3 (0.9399, 0.6206, 0.0585) | same | same |
| `--warning-foreground` | amber-700 `oklch(55.5% .163 48.998)` (1128) | #bb4d00 clipped, P3 (0.6799, 0.3277, 0.0521) | amber-400 `oklch(82.8% .189 84.429)` (1177) | #ffb900 clipped, P3 (0.9592, 0.7385, 0.1183) |
| `--warning-surface` | warning at 8% (1129) | | warning at 16% (1178) | |
| `--radius` | `0.625rem` = 10px (1083) | | same | |
| `--control-radius` | `0.5rem` = 8px (index.css:101) | | same | |
| `--glass-blur` | 12px (116) | | 16px (146) | |
| `--glass-opacity` | 80% (117) | | 80% (no dark override) | |
| `--glass-saturation` | 1.14 (118) | | 1.08 (147) | |
| `--app-scrollbar-thumb` / hover | rgb(217 217 217) / rgb(191 191 191) (95-96) | #d9d9d9 / #bfbfbf | white 8% / white 12% (144-145) | |
| `--z-sheet` | 46 (115) | | | |
| `--command-shell-inset` / `--command-content-inset` | 0.5rem / 1rem (110-111) | 8px / 16px | | |
| `--thread-details-panel-width` | 17.5rem (129) | 280px | | |

Radius scale (index.css:277-282, compiled): `rounded-xs` 2px, `rounded` 4px (`.25rem`), `rounded-sm` 6px, `rounded-md` 8px, `rounded-lg` 10px, `rounded-xl` 14px, `rounded-2xl` 18px, `rounded-full` compiles to `2147483647px`.

Type scale (compiled `@layer theme`): text-xs 12px/16px, text-sm 14px/20px, text-base 16px/24px, text-lg 18px/28px, text-xl 20px/28px, text-2xs 11px/16px. `leading-none` 1, `leading-snug` 1.375, `leading-relaxed` 1.625, `tracking-widest` .1em. Weights 400/500/600/700. Fonts: `--font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif`; `--font-mono: ui-monospace, "SF Mono", "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace` (index.css:166-170).

Transitions: default duration .15s, default timing `cubic-bezier(.4, 0, .2, 1)`; `ease-in-out` is the same curve; `duration-200` is .2s.

Shadows used here (compiled): `shadow-xs` `0 1px 2px 0 #0000000d`; `shadow-xs/5` `0 1px 2px 0 rgba(0,0,0,.05)`; `shadow-sm` `0 1px 3px 0 #0000001a, 0 1px 2px -1px #0000001a`; `shadow-sm/5` same geometry at 5%; `shadow-md/5` `0 4px 6px -1px rgba(0,0,0,.05), 0 2px 4px -2px rgba(0,0,0,.05)`; `shadow-lg` `0 10px 15px -3px #0000001a, 0 4px 6px -4px #0000001a`; `shadow-lg/5` same geometry at 5%; `shadow-xl` `0 20px 25px -5px #0000001a, 0 8px 10px -6px #0000001a`.

### 1.3 Glass utilities (index.css:334-437)

| Utility | Background | Backdrop filter | Border | Box shadow |
|---|---|---|---|---|
| `surface-glass` (334-342) | `color-mix(in srgb, var(--background) var(--glass-opacity), transparent)`: background at 80% alpha | `blur(var(--glass-blur)) saturate(var(--glass-saturation))`: light blur 12px sat 1.14, dark blur 16px sat 1.08 | none | none |
| `dialog-glass` (395-412) | background at 80% alpha (light #fcfcfc, dark #0a0a0a) | same | `border-color: color-mix(in srgb, var(--contrast-foreground) 10%, transparent)`; dark `color-mix(in srgb, white 8%, transparent)` | light `0 24px 64px -24px rgb(0 0 0 / 65%)`; dark `inset 0 1px rgb(255 255 255 / 4%), 0 24px 72px -20px rgb(0 0 0 / 90%)` |
| `dialog-backdrop` (414-422) | light background at 60%, dark background at 64% | `blur(4px)` | none | none |
| `dropdown-glass` (424-437) | `color-mix(in srgb, var(--popover) 18%, color-mix(in srgb, var(--popover) var(--glass-opacity), transparent))`. Premultiplied result: the popover colour at alpha 0.18 + 0.82 x 0.80 = 0.836 (light white, dark #111111) | same as surface-glass | `border: 1px solid color-mix(in srgb, var(--contrast-foreground) 10%, transparent)` (shorthand, so it also sets the 1px width): light zinc-800 at 10%, dark neutral-100 at 10% | none (components add their own) |
| `alert-glass` (344-374) | not used by Part A components | | | |

Without backdrop-filter support each glass falls back to an opaque `--background` or `--popover`; not relevant in Chromium.

### 1.4 Preflight and app base rules (compiled `@layer base`)

- `*,:after,:before,::backdrop{box-sizing:border-box;border:0 solid;margin:0;padding:0}`.
- `button,input,select,optgroup,textarea{font:inherit;letter-spacing:inherit;color:inherit;opacity:1;background-color:#0000;border-radius:0}`. Controls inherit font size and line height unless a class sets them.
- `::placeholder{opacity:1}` and, in Chromium, `color: color-mix(in oklab, currentcolor 50%, transparent)`. Input overrides this with `placeholder:text-placeholder`; Textarea does not, so a Textarea placeholder is the text colour at 50%.
- `code,kbd,samp,pre` get the mono stack and `font-size:1em`; Kbd and MenuShortcut override with `font-sans` and `text-xs`.
- `img,svg,...{display:block;vertical-align:middle}`.
- `textarea{resize:vertical}`.
- index.css:684-686 compiles to `*{border-color:var(--contrast-border);outline-color:color-mix(in oklab, var(--ring) 50%, transparent)}`. Any `border` without a colour class is `--contrast-border` (light #e4e4e7, dark white 6%).
- index.css:687-694: menu, select and popover popups never show a ring or outline when focused.
- html line-height 1.5; body colour `--contrast-foreground`.

### 1.5 How variants compile (verified in main-pEuGmXiu.css)

| Source variant | Compiled selector |
|---|---|
| `hover:x` | `.c:hover` inside `@media (hover:hover)` |
| `[:hover,[data-pressed]]:x` | `.c:is(:hover,[data-pressed])`, NOT inside a hover media query |
| `[:active,[data-pressed]]:x` | `.c:is(:active,[data-pressed])` |
| `dark:x` | `.c:is(.dark,.dark *)` (`.dark` class on `<html>`) |
| `not-dark:x` | `.c:not(:is(.dark,.dark *))` |
| `data-pressed:x`, `data-highlighted:x` | `.c[data-pressed]`, `.c[data-highlighted]` (attribute presence) |
| `aria-invalid:x` / `has-aria-invalid:x` | `.c[aria-invalid=true]` / `.c:has([aria-invalid=true])` |
| `aria-disabled:x` | `.c[aria-disabled=true]` |
| `in-data-[size=sm]:x` | `:where([data-size=sm]) .c` (specificity of one class) |
| `not-in-data-[slot=input-group]:x` | `.c:not(:where([data-slot=input-group]) *)` |
| `sm:x` / `max-sm:x` | `@media (width>=40rem)` / `@media not all and (width>=40rem)` |
| `pointer-coarse:x` | `@media (pointer:coarse)` (touch targets only; ignore on Mac) |
| `bg-X/N` | `color-mix(in oklab, var(--X) N%, transparent)` under `@supports (color:color-mix(...))`, i.e. the colour at N% alpha |
| `before:x` | `.c:before{content:var(--tw-content);...}` with `--tw-content` initial `""`, so the pseudo element always renders |

### 1.6 Shadow and ring composition

Every shadow or ring utility writes `box-shadow: var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)`. `@property` initial values: `--tw-shadow`, `--tw-inset-shadow`, `--tw-ring-shadow`, `--tw-ring-offset-shadow`, `--tw-inset-ring-shadow` are `0 0 #0000`; `--tw-ring-offset-width: 0`; `--tw-ring-offset-color: #fff`; `--tw-shadow-alpha: 100%`.

- `ring-2 ring-offset-1 ring-offset-background ring-ring` gives `0 0 0 1px var(--background)` (offset) then `0 0 0 3px var(--ring)` (2px ring outside a 1px gap).
- `ring-[3px]` with `ring-ring/24` and no offset gives `0 0 0 3px color-mix(in oklab, var(--ring) 24%, transparent)`.
- `shadow-primary/24 shadow-xs` gives `0 1px 2px 0` in the primary colour at 24% alpha.
- `inset-shadow-[0_1px_--theme(--color-white/16%)]` gives `inset 0 1px rgba(255,255,255,.16)`; the `black/8%` form gives `inset 0 1px rgba(0,0,0,.08)`.

The "highlight line" pattern used by outline buttons, inputs, select triggers, number fields, input groups, tooltips, popovers, autocomplete and sheets: `before:pointer-events-none before:absolute before:inset-0 before:rounded-[R-1px]` plus a `before:shadow-[...]`. The pseudo element covers the padding box (inside the 1px border), so its outer shadow lands on the border row:

- light `before:shadow-[0_1px_--theme(--color-black/4%)]` = `0 1px rgba(0,0,0,.04)`: a 1px 4% black line over the bottom border, following the corner radius R-1.
- dark `before:shadow-[0_-1px_--theme(--color-white/6%)]` = `0 -1px rgba(255,255,255,.06)`: a 1px 6% white line over the top border.

`not-dark:bg-clip-padding` means in light mode the fill stops inside the border; in dark mode the translucent fill also sits under the translucent border.

### 1.7 base-ui behaviour shared by all popups (from the shipped bundle)

- Positioner defaults (utils-5_-Qnp8u.js, function `c6`): `positionMethod "absolute"`, `collisionPadding 5`, `arrowPadding 5`, `sticky false`, `collisionBoundary "clipping-ancestors"`. Collision avoidance defaults to `side: "flip"`, `align: "flip"`, `fallbackAxisSide: "end"` unless a component passes another object. The flip middleware uses padding + 1px per side.
- Two constants: `Z2={fallbackAxisSide:"none"}` (dropdown style) and `Q2={fallbackAxisSide:"end"}` (popup style) (utils-5_-Qnp8u.js, `Z2={fallbackAxisSide:\`none\`},Q2={fallbackAxisSide:\`end\`}`). Menu root, Select, Combobox and Autocomplete use Z2. Submenus, Tooltip, Popover and PreviewCard use Q2.
- CSS variables written by base-ui on the positioner: `--available-width`, `--available-height`, `--anchor-width`, `--anchor-height` (size middleware), `--transform-origin` (set on the floating element; for side bottom it is `<x>px <-sideOffset>px`, i.e. the point on the trigger edge). Popups with a Viewport also get `--popup-width/height` and `--positioner-width/height`.
- Popup state attributes: `data-open`/`data-closed`, `data-side`, `data-align`, `data-starting-style` (on mount), `data-ending-style` (on close; base-ui waits for running transitions before unmounting), `data-instant`, `data-anchor-hidden`.
- Trigger state attributes (utils-5_-Qnp8u.js `R$` mapping): Menu triggers and Select triggers get both `data-popup-open` and `data-pressed` while open. Popover triggers get `data-pressed` only when the popover was opened by a press (`e&&O==="trigger-press"?M.open(e):ee.open(e)` in popover-Dewldpee.js). Tooltip triggers, submenu triggers, Dialog triggers and the Select icon get only `data-popup-open`. Because Button styles `[data-pressed]` like hover, a ghost Button that opens a menu keeps the accent fill while the menu is open.
- Modal backdrop: open modal popups render an invisible `position:fixed; inset:0; user-select:none` div with a clip-path cutout around the trigger (utils-5_-Qnp8u.js `d6`). It has no colour and no z-index. Menu.Root modal default is UNVERIFIED (behaviour only, no pixels).

## 2. Button (`button.tsx`)

Primitive: none. `useRender` + `mergeProps` from base-ui, default tag `<button>`, `type="button"` unless `render` is given (button.tsx:81-97). `data-slot="button"` (88). Merge: `cn(buttonVariants({ className, size, variant }))` (87). Defaults: size `default`, variant `default` (13-16).

### 2.1 Verbatim classes

Base (button.tsx:11):
```
[--control-icon-color:currentColor] [&_svg]:-mx-0.5 relative inline-flex shrink-0 cursor-pointer items-center justify-center gap-2 whitespace-nowrap rounded-[var(--control-radius)] border font-medium text-base outline-none transition-[box-shadow,scale] [&:active:not([aria-haspopup])]:scale-[0.97] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--control-radius)-1px)] pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 aria-disabled:cursor-not-allowed aria-disabled:opacity-64 sm:text-sm [&_svg:not([class*='text-'])]:text-[var(--control-icon-color)] [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
```

Sizes (button.tsx:18-40):
```
compact (19-20):      h-7 gap-1 rounded-md px-[calc(--spacing(2)-1px)] text-xs before:rounded-[calc(var(--radius-md)-1px)] [&_svg:not([class*='size-'])]:size-3.5
default (21):         h-9 px-[calc(--spacing(3)-1px)] sm:h-8
icon (22):            size-9 sm:size-8
icon-lg (23):         size-10 sm:size-9
icon-micro (24-25):   size-5 rounded-sm p-0 before:rounded-[calc(var(--radius-sm)-1px)] [&_svg:not([class*='size-'])]:size-3
icon-tiny (26):       size-4 p-0 [&_svg:not([class*='size-'])]:size-3
icon-sm (27):         size-8 sm:size-7
icon-xl (28-29):      size-11 sm:size-10 [&_svg:not([class*='size-'])]:size-5 sm:[&_svg:not([class*='size-'])]:size-4.5
icon-xs (30-31):      size-7 sm:size-6 not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-4 sm:not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-3.5
lg (32):              h-10 px-[calc(--spacing(3.5)-1px)] sm:h-9
micro (33-34):        h-5 gap-1 rounded-sm px-[calc(--spacing(1.5)-1px)] text-[11px] before:rounded-[calc(var(--radius-sm)-1px)] sm:text-[11px] [&_svg:not([class*='size-'])]:size-3 sm:[&_svg:not([class*='size-'])]:size-3
sm (35):              h-8 gap-1.5 px-[calc(--spacing(2.5)-1px)] sm:h-7
sm-multiline (36-37): min-h-8 gap-1.5 px-[calc(--spacing(2.5)-1px)] py-[calc(--spacing(1)-1px)] whitespace-normal sm:min-h-7
xl (38):              h-11 px-[calc(--spacing(4)-1px)] text-lg sm:h-10 sm:text-base [&_svg:not([class*='size-'])]:size-5 sm:[&_svg:not([class*='size-'])]:size-4.5
xs (39):              h-7 gap-1 px-[calc(--spacing(2)-1px)] text-sm sm:h-6 sm:text-xs [&_svg:not([class*='size-'])]:size-4 sm:[&_svg:not([class*='size-'])]:size-3.5
```

Variants (button.tsx:41-68):
```
default (42-43):             not-disabled:inset-shadow-[0_1px_--theme(--color-white/16%)] border-primary bg-primary text-primary-foreground shadow-primary/24 shadow-xs [:active,[data-pressed]]:inset-shadow-[0_1px_--theme(--color-black/8%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:bg-primary/90
destructive (44-45):         not-disabled:inset-shadow-[0_1px_--theme(--color-white/16%)] border-destructive bg-destructive text-white shadow-destructive/24 shadow-xs [:active,[data-pressed]]:inset-shadow-[0_1px_--theme(--color-black/8%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:bg-destructive/90
destructive-outline (46-47): border-input bg-popover not-dark:bg-clip-padding text-destructive-foreground shadow-xs/5 not-disabled:not-active:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:not-disabled:before:shadow-[0_-1px_--theme(--color-white/2%)] dark:not-disabled:not-active:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:border-destructive/32 [:hover,[data-pressed]]:bg-destructive/4
ghost (48-49):               [--control-icon-color:var(--contrast-muted-foreground)] border-transparent text-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent
ghost-muted (50-51):         [--control-icon-color:currentColor] border-transparent text-muted-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent [:hover,[data-pressed]]:text-foreground
ghost-destructive (52-53):   [--control-icon-color:currentColor] border-transparent text-muted-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent [:hover,[data-pressed]]:text-destructive
glass (54-55):               surface-glass [--control-icon-color:var(--contrast-muted-foreground)] rounded-full border-border/60 text-foreground shadow-sm before:rounded-full [:hover,[data-pressed]]:border-border
link (56):                   border-transparent underline-offset-4 [:hover,[data-pressed]]:underline
media-close (57-58):         [--control-icon-color:currentColor] border-transparent bg-black/65 text-white shadow-sm ring-1 ring-white/20 [:hover,[data-pressed]]:bg-black/80 focus-visible:ring-white
media-navigation (59-60):    [--control-icon-color:currentColor] absolute top-1/2 z-20 -translate-y-1/2 border-transparent text-white/90 [:hover,[data-pressed]]:bg-white/10 [:hover,[data-pressed]]:text-white focus-visible:ring-white focus-visible:ring-offset-transparent
outline (61-62):             [--control-icon-color:var(--contrast-muted-foreground)] border-input bg-popover not-dark:bg-clip-padding text-foreground shadow-xs/5 not-disabled:not-active:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:not-disabled:before:shadow-[0_-1px_--theme(--color-white/2%)] dark:not-disabled:not-active:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:bg-accent/50 dark:[:hover,[data-pressed]]:bg-input/64
overlay (63):                border-transparent bg-black/70 text-white/65 [:hover,[data-pressed]]:bg-black/90
secondary (64-65):           border-transparent bg-secondary text-secondary-foreground [:active,[data-pressed]]:bg-secondary/80 [:hover,[data-pressed]]:bg-secondary/90
warning-outline (66-67):     border-warning/32 bg-warning-surface text-warning-foreground shadow-xs/5 [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:border-warning/40 [:hover,[data-pressed]]:bg-warning/16 dark:[:hover,[data-pressed]]:bg-warning/24
```

### 2.2 Resolved base (all variants)

- Layout: inline-flex, centred both axes, gap 8px, `white-space: nowrap`, flex-shrink 0, `position: relative`, cursor pointer, padding 0 unless a size sets it.
- Border: 1px solid, colour per variant. Radius 8px (`--control-radius`); `::before` radius 7px, absolute, inset 0, pointer-events none.
- Font: weight 500; 16px/24px at <640, 14px/20px at >=640.
- Transition: `box-shadow, scale` 150ms `cubic-bezier(.4,0,.2,1)`. Background and text colour changes are instant.
- Pressed scale: `:active` without `aria-haspopup` sets `scale: .97` (compiled `.c:active:not([aria-haspopup]){scale:.97}`, #3817). Dialog triggers carry `aria-haspopup="dialog"` (dialog-D1ZA0Pvc.js), so they do not scale; Menu/Select/Popover triggers likely also carry `aria-haspopup` (UNVERIFIED in bundle).
- Focus visible (keyboard): `0 0 0 1px var(--background), 0 0 0 3px var(--ring)` layered with the variant shadows. Light: 1px #fcfcfc gap then 2px #1b4ed8. Dark: 1px #0a0a0a then 2px #346bf1.
- Disabled (`:disabled`): opacity .64, pointer-events none. `aria-disabled="true"`: opacity .64, cursor not-allowed.
- Icons (`svg` descendants): margin-inline -2px, pointer-events none, flex-shrink 0. Width/height 18px at <640 and 16px at >=640 when the svg class contains no `size-`. Colour `var(--control-icon-color)` when the svg class contains no `text-`; base value `currentColor`.
- Loading: no loading state exists in button.tsx. App code puts `<Spinner />` (`spinner.tsx:7-21`, lucide `LoaderCircleIcon`, `motion-safe:visible-animate-spin`, no default size, so the button svg rule sizes it).

### 2.3 Resolved sizes (border included in heights)

| Size | Height <640 / >=640 | Padding inline | Gap | Radius (::before) | Font <640 / >=640 | Icon (no size class) <640 / >=640 |
|---|---|---|---|---|---|---|
| micro | 20 / 20 | 5px | 4px | 6px (5px) | 11px / 11px, line-height inherited (text-[11px] sets no line-height) | 12 / 12 |
| xs | 28 / 24 | 7px | 4px | 8px (7px) | 14/20 / 12/16 | 16 / 14 |
| compact | 28 / 28 | 7px | 4px | 8px (7px) | 12/16 / 14/20 (quirk, see below) | 14 / 16 (quirk) |
| sm | 32 / 28 | 9px | 6px | 8px (7px) | 16/24 / 14/20 | 18 / 16 |
| sm-multiline | min 32 / min 28, padding-block 3px, wraps | 9px | 6px | 8px | 16/24 / 14/20 | 18 / 16 |
| default | 36 / 32 | 11px | 8px | 8px (7px) | 16/24 / 14/20 | 18 / 16 |
| lg | 40 / 36 | 13px | 8px | 8px | 16/24 / 14/20 | 18 / 16 |
| xl | 44 / 40 | 15px | 8px | 8px | 18/28 / 16/24 | 20 / 18 |
| icon-tiny | 16x16 / 16x16 | 0 | | 8px (7px) | | 12 / 16 (quirk) |
| icon-micro | 20x20 / 20x20 | 0 | | 6px (5px) | | 12 / 16 (quirk) |
| icon-xs | 28x28 / 24x24 | 0 | | 8px | | 16 / 14 outside an input group; 18 / 16 inside `[data-slot=input-group]` |
| icon-sm | 32x32 / 28x28 | 0 | | 8px | | 18 / 16 |
| icon | 36x36 / 32x32 | 0 | | 8px | | 18 / 16 |
| icon-lg | 40x40 / 36x36 | 0 | | 8px | | 18 / 16 |
| icon-xl | 44x44 / 40x40 | 0 | | 8px | | 20 / 18 |

Quirks (derived from tailwind-merge rules plus compiled rule order; not checked in a running app):
- compact: `text-xs` removes base `text-base`, but base `sm:text-sm` stays, and `sm:text-sm` (#3293, media) beats `text-xs` (#1775). Result: 14px/20px at >=640. Same for icons: `[&_svg...]:size-3.5` (#3764) loses to base `sm:[&_svg...]:size-4` (#3772) at >=640, so unsized icons are 16px. The MenuItem ghost variant adds `sm:text-xs` explicitly to dodge this (menu.tsx:93).
- icon-micro and icon-tiny: same icon issue, unsized icons are 16px at >=640. Most call sites pass `size-3` on the icon (for example `DiffFilePathCopyButton.tsx:34-37`), but some pass a bare `<XIcon />` (for example `ProviderSettingsForm.tsx:233`).
- icon-tiny keeps the base 8px radius on a 16px box, so it is a circle.
- icon-xs: `not-in-data-[slot=input-group]` rules (#3768, #3774) come after the base svg rules (#3766, #3772) at equal specificity, so outside input groups they win.

Approximate usage in app JSX (regex scan of `apps/web/src/**/*.tsx`, excluding tests): size xs 178, sm 158, no size (default) 128, icon-xs 97, icon-micro 34, icon-sm 27, compact 10, icon 9, sm-multiline 5, micro 4. Variant outline 222, ghost 143, no variant (default) 121 plus 8 explicit, ghost-muted 114, destructive 9, destructive-outline 8, ghost-destructive 5, media-close 4, overlay 4, glass 3, secondary 3, warning-outline 3, media-navigation 2, link 1.

### 2.4 Resolved variants and states

`hover/pressed` below means `:hover` OR `[data-pressed]` (one rule, not limited to hover-capable pointers).

**default** (primary)
| State | Background | Border | Text / icon | box-shadow |
|---|---|---|---|---|
| rest | `--primary` (light #1b4ed8, dark #346bf1) | `--primary` | `--primary-foreground` #fff; icons currentColor (#fff) | `inset 0 1px rgba(255,255,255,.16), 0 1px 2px 0 <primary at 24%>` |
| hover/pressed | primary at 90% alpha | primary | #fff | same as rest on hover; when `[data-pressed]` see pressed |
| active or data-pressed | primary at 90% | primary | #fff | `inset 0 1px rgba(0,0,0,.08)` only (#3823 after #2305; drop shadow removed by #3826) |
| focus-visible | rest values | | | ring layers added: `0 0 0 1px var(--background), 0 0 0 3px var(--ring)` |
| disabled | primary | | | no inset, no drop shadow; opacity .64 |

**destructive**: as default with `--destructive` (light #fb2c36, dark #fb414a), text white, shadow destructive at 24%, hover/pressed destructive at 90%.

**outline** (most used)
| State | Light | Dark |
|---|---|---|
| rest bg | `--popover` #fff clipped to padding box | `--contrast-input` at 32% = white 2.56% (under the border too) |
| border | `--contrast-input` #d4d4d8 | white 8% |
| text | foreground #27272a | #f5f5f5 |
| icons | `--control-icon-color: var(--contrast-muted-foreground)`: #71717b | #818181 |
| drop shadow | `0 1px 2px 0 rgba(0,0,0,.05)` | same |
| ::before line | `0 1px rgba(0,0,0,.04)` (bottom) when not disabled, not :active, not pressed | `0 -1px rgba(255,255,255,.06)` (top) when not disabled, not active, not pressed; `0 -1px rgba(255,255,255,.02)` when pressed/active but not disabled |
| hover/pressed bg | accent at 50% (zinc-100 at 50%, about #f9f9fa over white) | input at 64% = white 5.12% (`dark:[:hover,[data-pressed]]:bg-input/64`, specificity 0,3,0, beats light rule) |
| active/pressed/disabled | drop shadow removed | same |

**destructive-outline**: outline geometry; text `--destructive-foreground` (light red-700, dark red-400); icons currentColor (base value, so destructive colour); hover/pressed border destructive at 32% and background destructive at 4% in both themes.

**ghost**: border transparent; no fill; text foreground; icons muted-foreground; hover/pressed fill accent (light #f4f4f5, dark white 4%).

**ghost-muted**: text muted-foreground; icons currentColor; hover/pressed fill accent and text foreground.

**ghost-destructive**: text muted-foreground; icons currentColor; hover/pressed fill accent and text `--destructive`.

**glass**: `surface-glass` (background at 80% alpha, blur 12px/16px, saturate 1.14/1.08), fully rounded (button and ::before), border `--border` at 60% (light zinc-200 at 60%, dark white 3.6%), text foreground, icons muted-foreground, `shadow-sm`; hover/pressed border full `--border`.

**link**: border transparent; no colour class, so text inherits; underline offset 4px; hover/pressed underline.

**media-close**: fill black 65%, text white, icons white, `shadow-sm` plus `ring-1 ring-white/20` = `0 0 0 1px rgba(255,255,255,.2)`; hover/pressed fill black 80%; focus ring colour white (twMerge replaces `focus-visible:ring-ring`), width 2px with 1px `--background` offset.

**media-navigation**: absolute, `top: 50%`, `translate: 0 -50%`, `z-index: 20`; text white 90%; hover/pressed fill white 10%, text white; focus ring white with transparent offset.

**overlay**: fill black 70%, text white 65%, hover/pressed fill black 90%.

**secondary**: fill `--secondary` (light #fafafa, dark white 3%), text secondary-foreground; hover/pressed fill secondary at 90%; `[:active,[data-pressed]]` 80% rule (#3821) comes before the 90% rule (#3844), so a pressed or hovered-and-active button shows 90%; 80% only shows for `:active` without hover.

**warning-outline**: border warning at 32%, fill `--warning-surface` (amber-500 at 8% light, 16% dark), text warning-foreground (amber-700 light, amber-400 dark), `shadow-xs/5`; hover/pressed border warning 40%, fill warning 16% (light) or 24% (dark); active/pressed/disabled no drop shadow.

### 2.5 InlineButton (`button.tsx:103-137`)

`useRender`, default `<button>`, `data-slot="inline-button"` (129); merge `cn(inlineButtonVariants({ tone }), className)` (128).

Base (104):
```
inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 [text-align:var(--inline-button-text-align,center)] [white-space:var(--inline-button-white-space,nowrap)] hover:underline focus-visible:outline-2 focus-visible:outline-ring disabled:pointer-events-none disabled:opacity-64
```
Tones (108-115): `default: "text-foreground"`, `muted: "text-muted-foreground hover:text-foreground"`, `destructive: "text-destructive/80 hover:text-destructive"`, `picker: "gap-1.5 text-foreground underline decoration-foreground/30 decoration-dotted decoration-from-font underline-offset-4 hover:decoration-foreground hover:decoration-solid data-popup-open:decoration-foreground data-popup-open:decoration-solid"`.

Resolved: inline-flex, gap 2px, weight 500, font size inherited, underline offset 2px, hover underline; focus-visible outline 2px solid `--ring` (no offset, square outline). Picker: gap 6px, dotted underline in foreground at 30%, thickness from-font, offset 4px; hover or menu open: solid underline in full foreground.

## 3. Input (`input.tsx`) and DraftInput (`draft-input.tsx`)

Primitive: `Input` from `@base-ui/react/input` (input.tsx:3), or a plain `<input>` when `nativeInput` (39-51). `data-slot="input"` on the input (46, 56); props spread after it, so Combobox and Autocomplete replace it with `combobox-input` / `autocomplete-input`. Wrapper `<span data-slot="input-control" data-size={size}>` (63-80). Props: `size "sm" | "compact" | "default" | "lg" | number`, `font "default" | "mono"`, `unstyled`, `nativeInput` (8-14).

Inner input (input.tsx:25-35):
```
base (25):    h-8.5 w-full min-w-0 rounded-[inherit] px-[calc(--spacing(3)-1px)] leading-8.5 outline-none placeholder:text-placeholder sm:h-7.5 sm:leading-7.5 [transition:background-color_5000000s_ease-in-out_0s]
compact (26): h-7 px-[calc(--spacing(2.5)-1px)] text-xs leading-7 sm:h-7 sm:leading-7
sm (27):      h-7.5 px-[calc(--spacing(2.5)-1px)] leading-7.5 sm:h-6.5 sm:leading-6.5
lg (28):      h-9.5 leading-9.5 sm:h-8.5 sm:leading-8.5
search (30):  [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none [&::-webkit-search-results-button]:appearance-none [&::-webkit-search-results-decoration]:appearance-none
number (33):  [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none
file (35):    text-muted-foreground file:me-3 file:bg-transparent file:font-medium file:text-foreground file:text-sm
```
Wrapper (input.tsx:68, 71, 72):
```
relative inline-flex w-full rounded-lg border border-input bg-background not-dark:bg-clip-padding text-base text-foreground shadow-xs/5 ring-ring/24 transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] not-has-disabled:not-has-focus-visible:not-has-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] has-focus-visible:has-aria-invalid:border-destructive/64 has-focus-visible:has-aria-invalid:ring-destructive/16 has-aria-invalid:border-destructive/36 has-focus-visible:border-ring has-autofill:bg-foreground/4 has-disabled:opacity-64 has-[:disabled,:focus-visible,[aria-invalid]]:shadow-none has-focus-visible:ring-[3px] sm:text-sm dark:bg-input/32 dark:has-autofill:bg-foreground/8 dark:has-aria-invalid:ring-destructive/24 dark:not-has-disabled:not-has-focus-visible:not-has-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)]
compact (71): rounded-md before:rounded-[calc(var(--radius-md)-1px)]
mono (72):    font-mono tabular-nums
```

Geometry:
| Size | Inner height = line-height <640 / >=640 | Control height with border | Padding inline | Font | Radius |
|---|---|---|---|---|---|
| sm | 30 / 26 | 32 / 28 | 9px | 16px / 14px | 10px |
| compact | 28 / 28 | 30 / 30 | 9px | 12px (on the input itself) | 8px |
| default | 34 / 30 | 36 / 32 | 11px | 16px / 14px | 10px |
| lg | 38 / 34 | 40 / 36 | 11px | 16px / 14px | 10px |

States (wrapper):
| State | Light | Dark |
|---|---|---|
| rest | fill `--background` #fcfcfc (note: not white like outline buttons), border #d4d4d8, `0 1px 2px 0 rgba(0,0,0,.05)`, ::before bottom line black 4% | fill white 2.56%, border white 8%, same drop shadow, ::before top line white 6% |
| hover | no change | no change |
| focus (text inputs match `:focus-visible` on any focus, including mouse) | border `--ring` (#1b4ed8), ring `0 0 0 3px` ring at 24%, drop shadow and ::before line removed | border #346bf1, ring #346bf1 at 24% |
| aria-invalid="true" | border destructive 36% | same |
| invalid + focus | border destructive 64%, ring destructive 16% | border 64%, ring destructive 24% (dark rule #3616 after #2866) |
| disabled | opacity .64, no drop shadow | same |
| autofill | fill foreground 4% | foreground 8% |
| placeholder | `--contrast-placeholder` = muted-foreground #71717b | #818181 |

The inner `[transition:background-color 5000000s ...]` hides Chrome's autofill fill. `type="file"`: muted-foreground text, file button margin-end 12px, transparent, weight 500, foreground, 14px. `font="mono"`: mono stack plus tabular digits. `unstyled`: wrapper gets only `className`.

DraftInput (`draft-input.tsx:18-21`): renders `<Input>` with a buffered value that commits on blur or Enter (`useCommitOnBlur`). No styling of its own.

## 4. Textarea (`textarea.tsx`)

Primitive: `Field.Control` from `@base-ui/react/field` rendering `<textarea data-slot="textarea">` (27-41). Wrapper `<span data-slot="textarea-control" data-size>` (16-26). Sizes `sm | default | lg | number`.

Wrapper (20):
```
relative inline-flex w-full rounded-lg border border-input bg-background not-dark:bg-clip-padding text-base text-foreground shadow-xs/5 ring-ring/24 transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] has-focus-visible:has-aria-invalid:border-destructive/64 has-focus-visible:has-aria-invalid:ring-destructive/16 has-aria-invalid:border-destructive/36 has-focus-visible:border-ring has-disabled:opacity-64 has-[:disabled,:focus-visible,[aria-invalid]]:shadow-none has-focus-visible:ring-[3px] not-has-disabled:has-not-focus-visible:not-has-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] sm:text-sm dark:bg-input/32 dark:has-aria-invalid:ring-destructive/24 dark:not-has-disabled:has-not-focus-visible:not-has-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)]
```
Textarea (32, 34, 35):
```
base: field-sizing-content min-h-17.5 max-h-64 w-full rounded-[inherit] px-[calc(--spacing(3)-1px)] py-[calc(--spacing(1.5)-1px)] outline-none max-sm:min-h-20.5
sm:   min-h-16.5 px-[calc(--spacing(2.5)-1px)] py-[calc(--spacing(1)-1px)] max-sm:min-h-19.5
lg:   min-h-18.5 py-[calc(--spacing(2)-1px)] max-sm:min-h-21.5
```
Resolved: grows with content (`field-sizing: content`) up to 256px, then scrolls. Default: padding 5px 11px, min-height 70px at >=640 (3 lines of 20px + 10px) and 82px at <640. sm: padding 3px 9px, min 66 / 78. lg: padding 7px 11px, min 74 / 86. Text 14px/20px at >=640, 16px/24px below (inherited from the wrapper). Resize: preflight `vertical`. States: as Input (focus ring, invalid, disabled), no autofill rules. Placeholder: no class, so preflight `currentColor` at 50% (foreground at 50%).

## 5. InputGroup (`input-group.tsx`)

`<div role="group" data-slot="input-group">` (41-46); no base-ui primitive. Defaults variant `default`, size `default` (12-15). cva key order: size, then variant.

Base (10):
```
relative inline-flex w-full min-w-0 items-center rounded-[var(--control-radius)] border text-base text-foreground ring-ring/24 transition-shadow has-[input:focus-visible,textarea:focus-visible]:has-[input[aria-invalid],textarea[aria-invalid]]:border-destructive/64 has-[input:focus-visible,textarea:focus-visible]:has-[input[aria-invalid],textarea[aria-invalid]]:ring-destructive/16 has-[textarea]:h-auto has-data-[align=block-end]:h-auto has-data-[align=block-start]:h-auto has-data-[align=block-end]:flex-col has-data-[align=block-start]:flex-col has-[input:focus-visible,textarea:focus-visible]:border-ring has-[input[aria-invalid],textarea[aria-invalid]]:border-destructive/36 has-autofill:bg-foreground/4 has-[input:disabled,textarea:disabled]:opacity-64 has-[input:disabled,textarea:disabled,input:focus-visible,textarea:focus-visible,input[aria-invalid],textarea[aria-invalid]]:shadow-none has-[input:focus-visible,textarea:focus-visible]:ring-[3px] sm:text-sm dark:has-autofill:bg-foreground/8 dark:has-[input[aria-invalid],textarea[aria-invalid]]:ring-destructive/24 has-data-[align=inline-start]:**:[[data-size=sm]_input]:ps-1.5 has-data-[align=inline-end]:**:[[data-size=sm]_input]:pe-1.5 *:[[data-slot=input-control],[data-slot=textarea-control]]:contents *:[[data-slot=input-control],[data-slot=textarea-control]]:before:hidden has-[[data-align=block-start],[data-align=block-end]]:**:[input]:h-auto has-data-[align=inline-start]:**:[input]:ps-2 has-data-[align=inline-end]:**:[input]:pe-2 has-data-[align=block-end]:**:[input]:pt-1.5 has-data-[align=block-start]:**:[input]:pb-1.5 **:[textarea]:min-h-20.5 **:[textarea]:resize-none **:[textarea]:py-[calc(--spacing(3)-1px)] **:[textarea]:max-sm:min-h-23.5 **:[textarea_button]:rounded-[calc(var(--control-radius)-1px)]
```
Size (17-20): `default: null`, `lg: "h-9"`. Variants (21-30):
```
default (23): border-input bg-background not-dark:bg-clip-padding shadow-xs/5 before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--control-radius)-1px)] not-has-[input:disabled,textarea:disabled]:not-has-[input:focus-visible,textarea:focus-visible]:not-has-[input[aria-invalid],textarea[aria-invalid]]:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:not-has-[input:disabled,textarea:disabled]:not-has-[input:focus-visible,textarea:focus-visible]:not-has-[input[aria-invalid],textarea[aria-invalid]]:before:shadow-[0_-1px_--theme(--color-white/6%)]
popover (26): dropdown-glass rounded-2xl has-[input:focus-visible,textarea:focus-visible]:ring-0 has-[input:focus-visible,textarea:focus-visible]:border-[color-mix(in_srgb,var(--contrast-foreground)_18%,transparent)]
ghost (28):   border-transparent bg-transparent shadow-none hover:bg-muted/40 has-[input:focus-visible,textarea:focus-visible]:bg-background
```
Resolved:
- Radius 8px (control radius, not the 10px of Input); ::before 7px. Child `input-control` / `textarea-control` spans become `display: contents` with their ::before hidden, so the group draws the frame.
- Height comes from the input: 36 at <640, 32 at >=640 (34 or 30 plus 2px border). `lg`: fixed 36px at all widths.
- default: same fills, borders, shadow, line and focus/invalid/disabled/autofill states as Input (see section 3).
- popover: dropdown-glass fill (popover at 83.6%, blur, 1px border foreground 10%), radius 18px, no drop shadow; focus: no ring, border foreground 18% (twMerge drops `border-ring` because it recognises `color-mix` as a colour).
- ghost: no border colour, no fill, no shadow; hover fill muted at 40% (light zinc-50 at 40%, dark white 1.2%); focused fill `--background`; the base focus border ring and 3px ring still apply.
- Inputs next to an inline-start addon get padding-start 8px (6px for `data-size=sm`), next to inline-end padding-end 8px (6px). Block addons make the group a column with `height: auto`, input height auto, input padding-top 6px (block-end) or padding-bottom 6px (block-start).
- Textarea inside: min-height 82px (>=640) / 94px (<640), padding-block 11px, `resize: none`. The `**:[textarea_button]` rule targets buttons inside a textarea and can never match.
- `input[aria-invalid]` here matches any aria-invalid value, including "false" (unlike `has-aria-invalid` which compiles to `[aria-invalid=true]`).

InputGroupAddon (50-117): `data-align`, `data-slot="input-group-addon"` (97-98). Clicking it focuses the input unless the target is interactive (99-113). Default align `inline-start`.
```
base (51): [&_svg]:-mx-0.5 flex h-auto cursor-text select-none items-center justify-center gap-2 leading-none [&>kbd]:rounded-[calc(var(--radius)-5px)] in-[[data-slot=input-group]:has([data-slot=input-control],[data-slot=textarea-control])]:[&_svg:not([class*='size-'])]:size-4.5 sm:in-[[data-slot=input-group]:has([data-slot=input-control],[data-slot=textarea-control])]:[&_svg:not([class*='size-'])]:size-4 not-has-[button]:**:[svg:not([class*='opacity-'])]:opacity-80
inline-end + pill (61):   has-[>button]:me-0 pe-1 [[data-size=sm]+&]:pe-1 gap-0.5
inline-start + pill (66): has-[>button]:ms-0 ps-1 [[data-size=sm]+&]:ps-1 gap-0.5
inset pill (72):          [&_button]:rounded-full
block-end (76):    order-last w-full justify-start px-[calc(--spacing(3)-1px)] pb-[calc(--spacing(3)-1px)] [.border-t]:pt-[calc(--spacing(3)-1px)] [[data-size=sm]+&]:px-[calc(--spacing(2.5)-1px)]
block-start (78):  order-first w-full justify-start px-[calc(--spacing(3)-1px)] pt-[calc(--spacing(3)-1px)] [.border-b]:pb-[calc(--spacing(3)-1px)] [[data-size=sm]+&]:px-[calc(--spacing(2.5)-1px)]
inline-end (80):   has-[>:last-child[data-slot=badge]]:-me-1.5 has-[>button]:-me-2 order-last pe-[calc(--spacing(3)-1px)] has-[>kbd:last-child]:me-[-0.35rem] [[data-size=sm]+&]:pe-[calc(--spacing(2.5)-1px)]
inline-start (82): has-[>:last-child[data-slot=badge]]:-ms-1.5 has-[>button]:-ms-2 order-first ps-[calc(--spacing(3)-1px)] has-[>kbd:last-child]:ms-[-0.35rem] [[data-size=sm]+&]:ps-[calc(--spacing(2.5)-1px)]
```
Resolved: flex, centred, gap 8px, line-height 1, cursor text; svg margin-inline -2px; svgs 18px / 16px when the group holds an input or textarea control; svgs at 80% opacity when the addon contains no button; direct `kbd` children radius 5px. inline-start: first in order, padding-start 11px (9px when it directly follows a `data-size=sm` element), margin-start -8px if it has a direct button child, -6px if the last child is a badge, -5.6px if the last child is a kbd. inline-end mirrors this on the end side. block-start/block-end: full width, left aligned, 11px padding on the sides and the outer edge, 11px on the inner edge when the addon has `border-b` / `border-t`. Pill inset: buttons fully rounded, padding 4px on the outer side, margin 0 when a button is present, gap 2px.

InputGroupInput (119-121) is `Input` with `unstyled`.

## 6. NumberField (`number-field.tsx`)

base-ui `NumberField` parts.

- Root (19-25): `flex w-full flex-col items-start gap-2`, `data-size`, `data-slot="number-field"`.
- Group (36), `data-slot="number-field-group"`:
```
relative flex w-full justify-between rounded-lg border border-input bg-background not-dark:bg-clip-padding text-base text-foreground shadow-xs/5 ring-ring/24 transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] not-data-disabled:not-focus-within:not-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] focus-within:border-ring focus-within:ring-[3px] has-aria-invalid:border-destructive/36 has-autofill:bg-foreground/4 focus-within:has-aria-invalid:border-destructive/64 focus-within:has-aria-invalid:ring-destructive/48 data-disabled:pointer-events-none data-disabled:opacity-64 sm:text-sm dark:bg-input/32 dark:has-autofill:bg-foreground/8 dark:has-aria-invalid:ring-destructive/24 dark:not-data-disabled:not-focus-within:not-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)] [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0 [[data-disabled],:focus-within,[aria-invalid]]:shadow-none
```
- Decrement (52) / Increment (70), `data-slot` `number-field-decrement` / `number-field-increment`, children lucide `MinusIcon` / `PlusIcon` (58, 76):
```
relative flex shrink-0 cursor-pointer items-center justify-center rounded-s-[calc(var(--radius-lg)-1px)] in-data-[size=sm]:px-[calc(--spacing(2.5)-1px)] px-[calc(--spacing(3)-1px)] transition-colors pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 hover:bg-accent
```
(Increment uses `rounded-e-[...]`.)
- Input (88), `data-slot="number-field-input"`:
```
h-8.5 in-data-[size=lg]:h-9.5 in-data-[size=sm]:h-7.5 w-full min-w-0 grow bg-transparent in-data-[size=sm]:px-[calc(--spacing(2.5)-1px)] px-[calc(--spacing(3)-1px)] text-center tabular-nums in-data-[size=lg]:leading-9.5 in-data-[size=sm]:leading-7.5 leading-8.5 outline-none [transition:background-color_5000000s_ease-in-out_0s] sm:h-7.5 sm:in-data-[size=lg]:h-8.5 sm:in-data-[size=sm]:h-6.5 sm:in-data-[size=lg]:leading-8.5 sm:in-data-[size=sm]:leading-8.5 sm:leading-7.5
```
Resolved: group frame as Input (radius 10px, border input, fill background, `shadow-xs/5`, ::before line). Focus uses `:focus-within`, so clicking the +/- buttons also shows the border ring and 3px ring at 24%. Invalid descendant: border destructive 36%; focus + invalid: border 64%, ring destructive 48% (light) or 24% (dark, later rule). `data-disabled`: opacity .64, no pointer events. Steppers: fill the group height, padding-inline 11px (9px for sm), hover fill accent (150ms colour transition), outer corners 9px, icons 18px / 16px. Input: centred tabular digits, transparent; heights default 34 / 30, lg 38 / 34, sm 30 / 26 (control heights add 2px). Quirk: `sm:in-data-[size=sm]:leading-8.5` (#3322) gives a 34px line-height inside the 26px sm input at >=640 (probably unintended).

## 7. Label (`label.tsx`)

`useRender`, default `<label>`, `data-slot="label"` (8-21). Classes (11): `inline-flex items-center gap-2 text-base/4.5 sm:text-sm/4 font-medium text-foreground` = inline-flex, gap 8px, weight 500, 16px with 18px line-height at <640, 14px with 16px line-height at >=640, foreground.

## 8. Kbd, KbdGroup and shortcut display

Kbd (`kbd.tsx:5-16`), `<kbd data-slot="kbd">`, classes (9):
```
pointer-events-none inline-flex h-5 min-w-5 select-none items-center justify-center gap-1 rounded bg-muted px-1 font-medium font-sans text-muted-foreground text-xs [&_svg:not([class*='size-'])]:size-3
```
Resolved: height 20px, min-width 20px, padding-inline 4px, gap 4px, radius 4px, fill `--muted` (light #fafafa, dark white 3%), text muted-foreground (#71717b / #818181), 12px/16px, weight 500, sans (overrides preflight mono), svgs 12px, no border, no shadow.

KbdGroup (18-26): `<kbd data-slot="kbd-group">`, `inline-flex items-center gap-1` (gap 4px).

Contextual overrides:
- CommandFooter (`command.tsx:221`): `[&_[data-slot=kbd]]:bg-foreground/[0.08] [&_[data-slot=kbd]]:text-foreground [&_[data-slot=kbd]]:ring-0`, `[&_[data-slot=kbd-group]]:font-sans`. Kbd there: fill foreground 8%, text foreground.
- InputGroupAddon (`input-group.tsx:51`): kbd radius `calc(var(--radius) - 5px)` = 5px.
- Command palette footer (`components/CommandPaletteContent.tsx:67-93`): KbdGroups of `<Kbd><ArrowUpIcon/></Kbd><Kbd><ArrowDownIcon/></Kbd><span>Navigate</span>`, `<Kbd>Enter</Kbd>`, `<Kbd>Backspace</Kbd>`, `<Kbd>Esc</Kbd>` with labels; groups separated by `gap-3` (12px).

MenuShortcut (`menu.tsx:251-262`, `<kbd data-slot="menu-shortcut">`) and CommandShortcut (`command.tsx:204-215`, `data-slot="command-shortcut"`) share:
```
ms-auto font-medium font-sans text-secondary-label text-xs tracking-widest
```
Resolved: pushed to the end of the row (`margin-inline-start: auto`), 12px/16px, weight 500, sans, letter-spacing .1em (1.2px), colour `--contrast-secondary-label` = muted-foreground (#71717b light, #818181 dark). No fill, no border. It does not change on highlight.

Shortcut label text (`keybindings.ts:191-224`): on macOS the modifiers are glyphs joined with no separator, in the order Control `⌃`, Option `⌥`, Shift `⇧`, Command `⌘`, then the key (for example `⇧⌘K`). Other platforms: `Ctrl+Alt+Shift+Meta+Key`. Key labels: space is `Space`; a single character is upper-cased; `escape` is `Esc`; arrows are `Up`, `Down`, `Left`, `Right`; anything else gets its first letter capitalised (`Enter`, `Tab`). Example use: `RightPanelTabs.tsx:296-305` sets `aria-keyshortcuts` and renders `<MenuShortcut>{shortcut}</MenuShortcut>` as the last child of the MenuItem.

## 9. Select (`select.tsx`)

`Select = Select.Root` (11). `SelectTrigger` = `Select.Trigger` with `data-slot="select-trigger"` (49-58) and `Select.Icon data-slot="select-icon"` containing `ChevronDownIcon className="-me-1 size-3 opacity-50"` (55-57). `SelectButton` (66-91) gives the same look to a Menu or Combobox trigger: children wrapped in `<span className="min-w-0 flex-1 truncate text-left">` plus `<ChevronDownIcon aria-hidden className="-me-1 size-3 shrink-0 opacity-50" />` (84-85). `SelectValue` (93-101): `flex-1 truncate data-placeholder:text-placeholder`, `data-slot="select-value"`.

Trigger cva (13-37), defaults size `default`, variant `default`; key order variant then size.
```
base (14):    relative inline-flex cursor-pointer select-none items-center justify-between gap-2 border rounded-lg text-left text-base outline-none transition-[color,box-shadow,background-color] data-disabled:pointer-events-none data-disabled:opacity-64 sm:text-sm [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4
default (23): w-full min-w-36 border-input bg-background not-dark:bg-clip-padding text-foreground shadow-xs/5 ring-ring/24 before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] not-data-disabled:not-focus-visible:not-aria-invalid:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 focus-visible:border-ring focus-visible:ring-[3px] aria-invalid:border-destructive/36 focus-visible:aria-invalid:border-destructive/64 focus-visible:aria-invalid:ring-destructive/16 dark:bg-input/32 dark:aria-invalid:ring-destructive/24 dark:not-data-disabled:not-focus-visible:not-aria-invalid:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='text-'])]:text-icon-muted [[data-disabled],:focus-visible,[aria-invalid],[data-pressed]]:shadow-none
ghost (25):   border-transparent text-secondary-label focus-visible:ring-2 focus-visible:ring-ring data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent [:hover,[data-pressed]]:text-foreground
compact (29): h-7 gap-1 rounded-md px-[calc(--spacing(2)-1px)] text-xs before:rounded-[calc(var(--radius-md)-1px)] [&_svg:not([class*='size-'])]:size-3.5
default (30): min-h-9 px-[calc(--spacing(3)-1px)] sm:min-h-8
lg (31):      min-h-10 px-[calc(--spacing(3)-1px)] sm:min-h-9
sm (32):      min-h-8 gap-1.5 px-[calc(--spacing(2.5)-1px)] sm:min-h-7
xs (33):      h-7 gap-1 rounded-md px-[calc(--spacing(2)-1px)] text-sm before:rounded-[calc(var(--radius-md)-1px)] sm:h-6 sm:text-xs [&_svg:not([class*='size-'])]:size-4 sm:[&_svg:not([class*='size-'])]:size-3.5
```
Trigger sizes:
| Size | Height <640 / >=640 | Padding inline | Gap | Radius | Font <640 / >=640 |
|---|---|---|---|---|---|
| xs | 28 / 24 | 7px | 4px | 8px | 14/20 / 12/16 |
| compact | 28 / 28 | 7px | 4px | 8px | 12/16 / 14/20 (same merge quirk as Button compact; unsized svgs 14 / 16) |
| sm | min 32 / min 28 | 9px | 6px | 10px | 16/24 / 14/20 |
| default | min 36 / min 32 | 11px | 8px | 10px | 16/24 / 14/20 |
| lg | min 40 / min 36 | 11px | 8px | 10px | 16/24 / 14/20 |
Usage in app JSX: sm 40, compact 7, xs 7, default 3; ghost 3.

Default variant states:
| State | Light | Dark |
|---|---|---|
| rest | width 100%, min-width 144px, fill #fcfcfc (clipped), border #d4d4d8, `shadow-xs/5`, ::before bottom line black 4%, text foreground | fill white 2.56%, border white 8%, ::before top line white 6% |
| hover | no change | no change |
| open (`data-pressed`, `data-popup-open`) | drop shadow and ::before line removed; nothing else | same |
| focus-visible (keyboard) | border ring, `0 0 0 3px` ring at 24% | same with dark ring |
| aria-invalid | border destructive 36%; with focus border 64%, ring destructive 16% | ring destructive 24% |
| data-disabled | opacity .64, no pointer events | same |
Icons: unsized svgs 18 / 16, opacity .8 unless they carry an opacity class, colour `--contrast-icon-muted` (= muted-foreground) unless they carry a text class. The chevron is 12px, margin-inline-end -4px, opacity .5, icon-muted colour. Colour/box-shadow/background transitions 150ms.

Ghost variant: transparent border and fill, text secondary-label (muted-foreground); hover/pressed fill accent and text foreground; keyboard focus ring 2px `--ring` with no offset; chevron currentColor; no ::before.

SelectPopup (103-169). Defaults: `side "bottom"`, `sideOffset 4`, `align "start"`, `alignOffset 0`, `alignItemWithTrigger true`, `matchTriggerWidth true` (106-111).
```
Positioner (130):          z-[130] select-none                      data-slot="select-positioner"
Popup (136):               origin-(--transform-origin) rounded-lg text-foreground outline-none   data-slot="select-popup"
ScrollUpArrow (141):       top-0 z-50 flex h-6 w-full cursor-default items-center justify-center before:pointer-events-none before:absolute before:inset-x-px before:top-px before:h-[200%] before:rounded-t-[calc(var(--radius-lg)-1px)] before:bg-linear-to-b before:from-50% before:from-popover
  icon (144):              relative size-4.5 sm:size-4
Surface div (148-149):     dropdown-glass relative h-full rounded-lg shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)]   + min-w-(--anchor-width) when matchTriggerWidth
List (153):                max-h-(--available-height) overflow-y-auto p-1   data-slot="select-list"
ScrollDownArrow (160):     bottom-0 z-50 flex h-6 w-full cursor-default items-center justify-center before:pointer-events-none before:absolute before:inset-x-px before:bottom-px before:h-[200%] before:rounded-b-[calc(var(--radius-lg)-1px)] before:bg-linear-to-t before:from-50% before:from-popover
```
Resolved popup surface: popover at 83.6% alpha, blur 12px saturate 1.14 (light) or 16px / 1.08 (dark), 1px border foreground at 10%, radius 10px, shadow light `0 16px 40px -18px rgba(0,0,0,.55)`, dark `0 18px 44px -18px rgba(0,0,0,.8)`, min-width = trigger width, list padding 4px, list height capped at the available height. Scroll arrows: 24px tall, full width, z 50, chevron 18 / 16px, a fade from opaque `--popover` (from 50%) to transparent over twice the arrow height, inset 1px from the sides, outer corners 9px. Arrow positioning is base-ui internal (UNVERIFIED). No open/close animation: the popup appears and disappears instantly.

Positioning: when `alignItemWithTrigger` is active (default, except when opened by touch), base-ui sets `data-side="none"`, makes the positioner `position: fixed`, and places the list so the selected item's text sits over the trigger's value text (macOS pop-up button style). It reads positioner margins with a 10px fallback top and bottom and a 100px min-height fallback (select-DtYp5ZPi.js: `parseFloat(r.marginTop)||10`, `parseFloat(r.marginBottom)||10`, `parseFloat(r.minHeight)||100`). Otherwise: below the trigger, start aligned, 4px gap. Collision padding 5px; collision avoidance default Z2 `{fallbackAxisSide:"none"}`.

SelectItem (171-196), `data-slot="select-item"`, `Select.ItemText data-slot="select-item-text"` with `min-w-0 flex-1 [&_svg:not([class*='text-'])]:text-muted-foreground` (189). No check indicator is rendered (`hideIndicator` is ignored).
```
flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base outline-none data-selected:bg-foreground/[0.08] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
```
| State | Fill | Text |
|---|---|---|
| rest | none | foreground |
| highlighted (hover or keyboard) | accent (light #f4f4f5, dark white 4%) | accent-foreground (#18181b / #f5f5f5) |
| selected | foreground 8% (about #eeeeee over white; about #242424 over #111) | foreground |
| highlighted + selected | foreground 8% (selected rule #3022/#3023 comes after highlighted #2971) | accent-foreground |
| disabled | | opacity .64, cursor not-allowed |
Geometry: min-height 32 / 28, padding 4px 8px, radius 6px, 16px / 14px text; when `data-side=none` min-width = trigger width + 20px; unsized svgs 18 / 16, muted-foreground inside the item text.

SelectGroup (198-200), `data-slot="select-group"`. SelectGroupLabel (202-210): `px-2 py-1.5 font-medium text-muted-foreground text-xs` = 12px/16px, weight 500, muted-foreground, padding 6px 8px (28px row).

## 10. Combobox (`combobox.tsx`)

`Combobox` wraps `Combobox.Root` with a context for chips (19-29).

ComboboxInput (31-107). Props `showTrigger` (default true), `showClear` (false), `startAddon`, `size`, `unstyled`.
```
wrapper (50):       relative not-has-[>*.w-full]:w-fit w-full text-foreground has-disabled:opacity-64
start addon (54):   [&_svg]:-mx-0.5 pointer-events-none absolute inset-y-0 start-px z-10 flex items-center ps-[calc(--spacing(3)-1px)] opacity-80 has-[+[data-size=sm]]:ps-[calc(--spacing(2.5)-1px)] [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4     data-slot="combobox-start-addon"
input w/ addon (63): data-[size=sm]:*:data-[slot=combobox-input]:ps-[calc(--spacing(7.5)-1px)] *:data-[slot=combobox-input]:ps-[calc(--spacing(8.5)-1px)] sm:data-[size=sm]:*:data-[slot=combobox-input]:ps-[calc(--spacing(7)-1px)] sm:*:data-[slot=combobox-input]:ps-[calc(--spacing(8)-1px)]
input end (65/66):  has-[+[data-slot=combobox-trigger],+[data-slot=combobox-clear]]:*:data-[slot=combobox-input]:pe-6.5    (sm)   /   ...:pe-7   (others)
render Input (71-79): <Input className={cn("has-disabled:opacity-100", unstyled && "rounded-none bg-transparent text-sm")} nativeInput size={sizeValue} unstyled={unstyled} />
trigger (86) and clear (98): -translate-y-1/2 absolute top-1/2 inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-md border border-transparent opacity-80 outline-none transition-opacity pointer-coarse:after:absolute pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 hover:opacity-100 has-[+[data-slot=combobox-clear]]:hidden sm:size-7 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
  position (87/99): sizeValue === "sm" ? "end-0" : "end-0.5"
```
Resolved: the input frame is Input's (section 3). Start addon: absolute over the input, 1px from the start edge, z 10, padding-start 11px (9px before an sm input), opacity .8, icons 18 / 16, not clickable. Input padding-start with an addon: 33px / 31px (sm 29px / 27px). Padding-end with trigger or clear: 28px (sm 26px). Trigger and clear: 32x32 at <640, 28x28 at >=640, radius 8px, 1px transparent border, centred vertically, 2px from the end edge (0 for sm), opacity .8 to 1 on hover (150ms opacity transition), icons `ChevronsUpDownIcon` / `XIcon` 18 / 16; trigger hidden when a clear button follows. Disabled: the whole wrapper goes to .64 (`has-disabled:opacity-100` cancels the inner Input fade).

ComboboxSearchInput (109-127): outer `min-w-0 shrink-0 px-3 pt-2.5` (111); inner `relative -translate-y-px border-b border-border/70 pb-1.5 transition-colors focus-within:border-ring` (112); icon `pointer-events-none absolute top-1.5 left-0 size-4 shrink-0 text-muted-foreground/55` (115); ComboboxInput with `className="[&_input]:h-6.5 [&_input]:ps-5 [&_input]:font-sans [&_input]:leading-6.5"`, `showTrigger={false}`, `size="sm"`, `unstyled` (117-123). Resolved: 12px side padding, 10px top; a 1px bottom rule in `--border` at 70% that turns `--ring` while focused; 6px gap under the input; whole block lifted 1px; 16px search icon at top 6px, start 0, muted-foreground 55%; input 26px tall with 26px line-height, 14px text, padding-start 20px, padding-end 9px, no frame.

ComboboxPopup (137-184). Defaults `side "bottom"`, `sideOffset 4`, `align "start"`, `alignOffset` undefined (0); anchor = chips container when `multiple` (153-154).
```
Positioner (162): z-[130] select-none                     data-slot="combobox-positioner"
span (169):       dropdown-glass relative flex max-h-full min-w-(--anchor-width) max-w-(--available-width) origin-(--transform-origin) rounded-lg shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] transition-[scale,opacity] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)]
Popup (174):      flex min-w-0 max-h-[min(var(--available-height),23rem)] flex-1 flex-col overflow-hidden text-foreground     data-slot="combobox-popup"
```
Resolved: same glass surface and shadows as Select, radius 10px, min-width = anchor width, max-width = available width, height capped at min(available height, 368px). The transition is declared on a plain span that never receives starting/ending attributes, so open and close are instant. Positioner (ComboboxClear-Dng79eZR.js, export `o` = `G`): collision padding 5px, collision avoidance Z2 `{fallbackAxisSide:"none"}`, `lazyFlip: true`.

ComboboxItem (186-212), `data-slot="combobox-item"`; content wrapper `flex min-w-0 flex-1 items-center gap-2 [&_svg:not([class*='text-'])]:text-muted-foreground` (`data-slot="combobox-item-content"`, 205).
```
flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base outline-none not-data-disabled:hover:bg-accent data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-selected:bg-foreground/[0.08] data-selected:text-foreground data-highlighted:bg-accent data-highlighted:text-accent-foreground [&[data-highlighted][data-selected]]:bg-accent [&[data-highlighted][data-selected]]:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
```
States: hover (not disabled) accent; highlighted accent + accent-foreground; selected foreground 8% + foreground; highlighted and selected accent + accent-foreground (the explicit compound rule wins); disabled .64. Geometry as SelectItem (min 32 / 28, padding 4px 8px, radius 6px, gap 8px in the content row). No check indicator.

Others: ComboboxEmpty (218) `not-empty:p-2 text-center text-base text-muted-foreground sm:text-sm`; ComboboxList (229-231) ScrollArea with `scrollbarGutter` and `scrollFade`, list `not-empty:scroll-py-1 not-empty:px-1 not-empty:py-1` (4px padding); ComboboxListVirtualized (246) `size-full min-w-0 not-empty:px-1 not-empty:py-1`; ComboboxStatus (261) `px-3 py-2 font-medium text-muted-foreground text-xs empty:m-0 empty:p-0` (12px/16px, padding 8px 12px); ComboboxTrigger / ComboboxClear (129-135, 253-255) add only data-slots.

## 11. Autocomplete (`autocomplete.tsx`)

AutocompleteInput (12-76): same structure as ComboboxInput, with these differences: `showTrigger` default false (14); always rendered as `<Input nativeInput size={sizeValue} />` (49), no `unstyled`; start addon adds `has-[button]:pointer-events-auto` (33); trigger uses `transition-colors` (55); data-slots `autocomplete-start-addon`, `autocomplete-input`, `autocomplete-trigger`, `autocomplete-clear`, `autocomplete-icon`.

AutocompletePopup (78-122). Defaults side bottom, sideOffset 4, align start.
```
Positioner (100): z-[130] select-none     data-slot="autocomplete-positioner"
span (107):       relative flex max-h-full min-w-(--anchor-width) max-w-(--available-width) origin-(--transform-origin) rounded-lg border bg-popover not-dark:bg-clip-padding shadow-lg/5 transition-[scale,opacity] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] dark:before:shadow-[0_-1px_--theme(--color-white/6%)]
Popup (112):      flex max-h-[min(var(--available-height),23rem)] flex-1 flex-col text-foreground     data-slot="autocomplete-popup"
```
Resolved: NOT glass. Opaque `--popover` (white / #111), 1px `--contrast-border` (zinc-200 / white 6%), radius 10px, shadow `0 10px 15px -3px rgba(0,0,0,.05), 0 4px 6px -4px rgba(0,0,0,.05)`, ::before line (bottom black 4% light, top white 6% dark), max-height min(available, 368px). No animation. The positioner is the Combobox positioner (command-BD0RTth6.js imports `o as S` from ComboboxClear-Dng79eZR.js), so collision padding 5px and `{fallbackAxisSide:"none"}`.

AutocompleteItem (128), `data-slot="autocomplete-item"`:
```
flex min-h-8 cursor-default select-none items-center gap-2 rounded-sm px-2 py-1 text-base outline-none hover:bg-accent data-disabled:pointer-events-none data-selected:bg-accent/50 data-selected:text-foreground data-highlighted:bg-accent data-highlighted:text-accent-foreground [&[data-highlighted][data-selected]]:bg-accent [&[data-highlighted][data-selected]]:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='text-'])]:text-muted-foreground
```
States: hover accent; selected accent 50% + foreground; highlighted accent + accent-foreground; both accent; disabled .64. Cursor default. svgs muted-foreground.

Others: AutocompleteGroup (142) `[[role=group]+&]:mt-1.5` (6px above a group that follows a group); group label and AutocompleteListHeading (149-171) `px-2 py-1.5 font-medium text-muted-foreground text-xs`; AutocompleteEmpty (187) as ComboboxEmpty; AutocompleteList (198-200) ScrollArea (gutter, fade) + `not-empty:scroll-py-1 not-empty:p-1`; AutocompleteListVirtualized (176) `size-full min-w-0`; AutocompleteClear (212) `-translate-y-1/2 absolute end-0.5 top-1/2 inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-md border border-transparent opacity-80 outline-none transition-[color,background-color,box-shadow,opacity] pointer-coarse:after:absolute pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 hover:opacity-100 sm:size-7 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0`.

## 12. Command palette (`command.tsx`)

- `CommandDialog = Dialog.Root` (21); trigger `data-slot="command-dialog-trigger"` (25-27).
- Backdrop (29-37): `DIALOG_BACKDROP_CLASS` (see Dialog), `data-slot="command-dialog-backdrop"`, no `forceRender`.
- Viewport (43): `pointer-events-none fixed inset-0 z-50 flex flex-col items-center px-4 py-[max(--spacing(4),4vh)] sm:py-[10vh]`. Resolved: centred horizontally at the top; padding-inline 16px; padding-block max(16px, 4vh) at <640 and 10vh at >=640.
- Popup (66-67): `DIALOG_POPUP_CLASS` + `pointer-events-auto max-h-105 max-w-xl text-foreground`, `data-slot="command-dialog-popup"`. Resolved: width 100% up to 576px, max-height 420px, radius 18px, 1px border, dialog-glass fill/blur/shadow (section 15), enter/exit animation of DIALOG_POPUP_BASE_CLASS.
- Command (80-94): Autocomplete root with `inline`, `open`, `autoHighlight="always"`, `keepHighlight`.
- CommandInput (96-116): wrapper `px-[var(--command-shell-inset)] py-1.5 [&_[data-slot=autocomplete-start-addon]]:ps-[calc(var(--command-shell-inset)+0.0625rem)]` (102); AutocompleteInput `autoFocus`, `size="lg"`, `startAddon={<SearchIcon className="translate-x-0.5 text-icon-muted" />}` (110-111) with className (106):
```
border-transparent! bg-transparent! shadow-none before:hidden has-focus-visible:ring-0 placeholder:text-placeholder *:data-[slot=autocomplete-input]:ps-9! sm:*:data-[slot=autocomplete-input]:ps-[calc(var(--command-shell-inset)+1.5rem)]!
```
  Resolved: 8px side padding, 6px top and bottom; input 38px (<640) / 34px (>=640) inside an invisible 1px border (40 / 36 total); no fill, border, shadow, ::before line or focus ring (twMerge drops the 3px ring); text 16px / 14px; padding-start 36px / 32px; padding-end 11px; search icon 18px / 16px, `--contrast-icon-muted` colour, addon opacity .8, addon padding-start 9px, icon margin -2px and translateX 2px.
- CommandList (121): AutocompleteList + `not-empty:scroll-py-2 not-empty:p-2` (8px padding, `data-slot="command-list"`). CommandListVirtualized (135): `flex max-h-[inherit] flex-col`.
- CommandPanel (155): `relative min-h-0 overflow-hidden rounded-t-xl not-has-[+[data-slot=command-footer]]:rounded-b-2xl bg-transparent **:data-[slot=scroll-area-scrollbar]:mt-2 [touch-action:pan-y]` (top radius 14px; bottom radius 18px when no footer follows; scrollbars start 8px lower). App heights (`components/CommandPaletteContent.tsx:57-63`): `max-h-[min(28rem,70vh)]` default, `max-h-[min(34rem,76vh)]` for `tall-list`, flex fill for `fill`.
- CommandGroup / CommandGroupLabel / CommandListHeading (142-174): Autocomplete group styles, `data-slot="command-group"` / `command-group-label`.
- CommandItem (183-202), `data-slot="command-item"`, `data-active`:
```
py-1.5 data-selected:bg-foreground/[0.06] data-highlighted:bg-foreground/[0.09] data-highlighted:text-foreground [&[data-highlighted][data-selected]]:bg-foreground/[0.09] [&[data-highlighted][data-selected]]:text-foreground
active defined (193): cursor-pointer hover:bg-transparent hover:text-inherit data-highlighted:bg-transparent data-highlighted:text-inherit data-selected:bg-transparent data-selected:text-inherit [&[data-highlighted][data-selected]]:bg-transparent [&[data-highlighted][data-selected]]:text-inherit
active true (194): bg-accent! text-accent-foreground!
```
  Resolved on top of AutocompleteItem: padding 6px 8px, so a one-line row is 36px at <640 and 32px at >=640; radius 6px; gap 8px. Highlighted: foreground 9% fill, foreground text. Selected: foreground 6%. Both: 9%. AutocompleteItem's `hover:bg-accent` (#2644) loses to `data-highlighted` (#2972/#2973), and base-ui highlights on hover, so hover shows 9%. With `active` passed: primitive highlight visuals are neutralised and `active` rows get accent fill and accent-foreground text.
- CommandShortcut: section 8.
- CommandFooter (221):
```
relative flex items-center justify-between gap-2 rounded-b-[calc(var(--radius-2xl)-1px)] bg-foreground/[0.025] px-[var(--command-content-inset)] py-2.5 font-medium text-sm text-muted-foreground [&_[data-slot=kbd-group]]:font-sans [&_[data-slot=kbd]]:bg-foreground/[0.08] [&_[data-slot=kbd]]:text-foreground [&_[data-slot=kbd]]:ring-0
```
  Resolved: padding 10px 16px, gap 8px, fill foreground 2.5%, bottom corners 17px, 14px/20px weight 500 muted-foreground, no top border; footer kbds filled foreground 8% with foreground text.
- CommandFooterAction (237-239): `Button variant="ghost-muted" size="xs"` + `h-auto px-2 text-xs hover:bg-transparent`. Resolved: auto height, 8px padding-inline, 12px text at all widths, muted-foreground turning foreground on hover. `hover:bg-transparent` (#2691) loses to `[:hover,[data-pressed]]:bg-accent` (#3832) at equal specificity, so hover still fills accent (derived; UNVERIFIED in a running app).

## 13. Menu (`menu.tsx`)

`Menu = Menu.Root` (10). MenuTrigger (12-18): `Menu.Trigger` with `data-slot="menu-trigger"` and no classes (the app renders Buttons through `render`). While open it carries `data-popup-open` and `data-pressed`. base-ui trigger hover delay 100ms, closeDelay 0 (utils-5_-Qnp8u.js `delay:l=100,closeDelay:u=0`).

MenuPopup (20-68). Defaults `sideOffset 4`, `align "center"`, `alignOffset` undefined, `side "bottom"`, `keepMounted false` (23-28).
```
Portal (39) keepMounted
Positioner (44): z-[130]                    data-slot="menu-positioner"
Popup (51, 55, 57): dropdown-glass relative flex origin-(--transform-origin) rounded-lg shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] outline-none focus:outline-none dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)]
                    [-webkit-app-region:no-drag]
                    min-w-[min(10rem,calc(100vw-2rem))] max-w-[calc(100vw-2rem)]       data-slot="menu-popup"
inner div (63):  max-h-(--available-height) w-full overflow-y-auto p-1
```
Resolved: glass surface (popover at 83.6%, blur 12/16px, saturate 1.14/1.08, 1px border foreground 10%), radius 10px, shadow light `0 16px 40px -18px rgba(0,0,0,.55)` / dark `0 18px 44px -18px rgba(0,0,0,.8)`, min-width 160px (or viewport - 32px), max-width viewport - 32px, inner padding 4px, scrolls within the available height, never shows a focus ring, Electron no-drag. Opens below the trigger, centred, 4px gap. No open or close animation. Collision padding 5px; root menus `{fallbackAxisSide:"none"}`. base-ui context menus default to align start, alignOffset 2, sideOffset -5 (bundle).

MenuItem (74-105), `data-slot="menu-item"`, `data-density`, `data-inset`, `data-variant` (98-101). Defaults density `default`, variant `default`.
```
base (88): [&>svg]:-mx-0.5 flex min-h-8 cursor-pointer select-none items-center gap-2 rounded-sm px-2 py-1 text-base text-foreground outline-none data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-inset:ps-8 data-[variant=destructive]:text-destructive-foreground data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&>svg:not([class*='opacity-'])]:opacity-80 [&>svg:not([class*='size-'])]:size-4.5 sm:[&>svg:not([class*='size-'])]:size-4 [&>svg:not([class*='text-'])]:text-muted-foreground data-[variant=destructive]:[&>svg:not([class*='text-'])]:text-current [&>svg]:pointer-events-none [&>svg]:shrink-0
ghost (89-94): buttonVariants({ variant: "ghost", size: "compact", className: "h-auto min-h-7 w-full sm:text-xs" })
touch (95):    min-h-10 sm:min-h-10
```
| State | Fill | Text | Direct svg children |
|---|---|---|---|
| rest | none | foreground | 18px / 16px, opacity .8, muted-foreground, margin-inline -2px |
| highlighted (hover or keyboard) | accent (light zinc-100 over the glass, dark white 4%) | accent-foreground | unchanged |
| destructive | none / accent when highlighted | destructive-foreground (light red-700, dark red-400), stays when highlighted (#3128 after #2975) | currentColor |
| inset | padding-start 32px | | |
| disabled | | opacity .64, cursor not-allowed, no pointer events | |
Geometry: min-height 32 / 28 (touch density 40 at all widths), padding 4px 8px, radius 6px, gap 8px, 16px / 14px text. No transition, so the highlight is instant. Usage: 106 MenuItems, 6 destructive, 0 ghost (the ghost merge result, rounded 8px, padding 7px, 12px text, weight 500, inline-flex full width, is derived only; UNVERIFIED).

MenuItemLabel (109-120): `min-w-0 truncate in-data-[density=touch]:[text-box:trim-both_cap_alphabetic] supports-[text-box:trim-both_cap_alphabetic]:in-data-[density=touch]:py-[0.5em]`.

MenuCheckboxItem (122-176), `data-slot="menu-checkbox-item"`.
```
base (135): grid min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center gap-2 rounded-sm py-1 ps-2 text-base text-foreground outline-none data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
switch (137):  grid-cols-[1fr_auto] gap-4 pe-1.5
default (138): grid-cols-[1rem_minmax(0,1fr)] pe-4
switch track (148): inset-shadow-[0_1px_--theme(--color-black/4%)] inline-flex h-[calc(var(--thumb-size)+2px)] w-[calc(var(--thumb-size)*2-2px)] shrink-0 items-center rounded-full p-px outline-none transition-[background-color,box-shadow] duration-200 [--thumb-size:--spacing(4)] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background data-checked:bg-primary data-unchecked:bg-input data-disabled:opacity-64 sm:[--thumb-size:--spacing(3)]
switch thumb (151): pointer-events-none block aspect-square h-full in-[[data-slot=menu-checkbox-item][data-checked]]:origin-[var(--thumb-size)_50%] origin-left in-[[data-slot=menu-checkbox-item][data-checked]]:translate-x-[calc(var(--thumb-size)-4px)] in-[[data-slot=menu-checkbox-item]:active]:not-data-disabled:scale-x-110 in-[[data-slot=menu-checkbox-item]:active]:rounded-[var(--thumb-size)/calc(var(--thumb-size)*1.10)] rounded-(--thumb-size) bg-background shadow-sm/5 will-change-transform [transition:translate_.15s,border-radius_.15s,scale_.1s_.1s,transform-origin_.15s]
default indicator (156-170): inline svg, viewBox 0 0 24 24, stroke currentColor, stroke-width 2, round caps and joins, path "M5.252 12.7 10.2 18.63 18.748 5.37"
```
Resolved default variant: grid with a 16px indicator column and the label column, gap 8px, padding 4px 16px 4px 8px, min-height 32 / 28, radius 6px; the check is drawn 18px at <640 (overflowing the 16px column by 2px) and 16px at >=640, in the row text colour; no checked fill; highlight accent. Switch variant: label then switch, gap 16px, padding-end 6px; track 18x30 (<640) or 14x22 (>=640), radius full, 1px padding, `inset 0 1px rgba(0,0,0,.04)`, checked `--primary`, unchecked `--contrast-input` (zinc-300 / white 8%), 200ms colour transition, keyboard focus ring 2px + 1px offset; thumb 16px or 12px square with full radius, `--background` fill, `shadow-sm/5`, slides 12px or 8px when checked (`translate .15s`), stretches to 110% wide while the row is pressed (`scale .1s` after a .1s delay).

MenuRadioGroup (178-180). MenuRadioItem (182-202), `data-slot="menu-radio-item"`, children in `<span className="min-w-0 flex-1">` (199):
```
[&_svg]:-mx-0.5 flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base text-foreground outline-none data-checked:bg-foreground/[0.08] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
```
Checked: foreground 8% fill. Highlighted: accent, which wins over checked (#2971 after #2939). MenuRadioItemIndicator (204-219): `flex shrink-0`, default `<CheckIcon className="size-3.5" />` (14px), placed by the caller.

MenuGroupLabel (221-239), `data-slot="menu-label"`: `px-2 py-1.5 font-medium text-muted-foreground text-xs data-inset:ps-9 sm:data-inset:ps-8` = 12px/16px, weight 500, muted-foreground, padding 6px 8px (28px row), inset padding-start 36px / 32px.

MenuSeparator (241-249), `data-slot="menu-separator"`: `mx-2 my-1 h-px bg-border` = 1px line in `--contrast-border` (zinc-200 / white 6%), 8px side margins, 4px vertical margins (9px total vertical footprint).

MenuShortcut: section 8.

MenuSub (264-266) = `Menu.SubmenuRoot`. MenuSubTrigger (268-299), `data-slot="menu-sub-trigger"`:
```
[&>svg:not(:last-child)]:-mx-0.5 flex min-h-8 cursor-pointer items-center gap-2 rounded-sm px-2 py-1 text-base text-foreground outline-none data-disabled:cursor-not-allowed data-disabled:pointer-events-none data-highlighted:bg-accent data-popup-open:bg-accent data-inset:ps-8 data-highlighted:text-accent-foreground data-popup-open:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg:not([class*='text-'])]:text-muted-foreground [&>svg:not(:last-child):not([class*='opacity-'])]:opacity-80 [&_svg]:pointer-events-none [&>svg]:shrink-0
touch (287): min-h-10 sm:min-h-10
chevron (296): <ChevronRightIcon className="-me-0.5 ms-auto opacity-80" />
```
Resolved: MenuItem geometry; highlighted or submenu open: accent fill and accent-foreground text; trailing chevron 18 / 16px, opacity .8, muted-foreground, margin-end -2px, pushed to the end. base-ui submenu trigger: open on hover, delay 100ms, closeDelay 0.

MenuSubPopup (301-325): MenuPopup with `side="inline-end"`, `sideOffset 0`, `align "start"`, `alignOffset -5` when align is not center (312), `data-slot="menu-sub-content"`. The -5px equals 4px list padding + 1px border, so the first submenu row lines up with the sub-trigger row. Collision avoidance Q2 `{fallbackAxisSide:"end"}`.

## 14. Popover (`popover.tsx`)

`Popover = Popover.Root` (9), `PopoverCreateHandle` (7), PopoverTrigger `data-slot="popover-trigger"` (11-17), PopoverClose (122-124).

Maps:
```
width (21-26):   auto: "", sm: "w-64", md: "w-80", lg: "w-96"        (+ "max-w-[calc(100vw-2rem)]" when not auto, line 94)
padding (30-35): default: "py-4 [--viewport-inline-padding:--spacing(4)]"
                 compact: "py-2 [--viewport-inline-padding:--spacing(3)]"
                 none:    "rounded-[calc(var(--radius-lg)-1px)] py-0 [--viewport-inline-padding:0px]"
```
Defaults (40-50): padding `default`, variant `default`, width `auto`, side `bottom`, align `center`, sideOffset 4, alignOffset 0, tooltipStyle false, keepMounted false.

```
Positioner (76-80): h-(--positioner-height) w-(--positioner-width) max-w-(--available-width) transition-transform data-instant:transition-none
                    + panel: z-(--z-sheet) w-[min(var(--thread-details-panel-width),var(--anchor-width))] transition-none   | else: z-[130]
Popup base (87):    relative flex h-(--popup-height,auto) w-(--popup-width,auto) origin-(--transform-origin) rounded-lg text-popover-foreground outline-none transition-[width,height,scale,opacity] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] has-data-[slot=calendar]:rounded-xl has-data-[slot=calendar]:before:rounded-[calc(var(--radius-xl)-1px)] data-starting-style:scale-98 data-starting-style:opacity-0 dark:before:shadow-[0_-1px_--theme(--color-white/6%)]
  not panel (88):   dropdown-glass
  tooltipStyle (90): w-fit text-balance rounded-md text-xs shadow-md/5 before:rounded-[calc(var(--radius-md)-1px)]
  not tooltipStyle and not panel (93): shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)]
  panel (96):       w-full overflow-visible rounded-none border-0 bg-transparent shadow-none before:hidden [backdrop-filter:none] [-webkit-backdrop-filter:none]
Viewport (104):     relative size-full max-h-(--available-height) overflow-clip px-(--viewport-inline-padding) has-data-[slot=calendar]:p-2 data-instant:transition-none **:data-current:data-ending-style:opacity-0 **:data-current:data-starting-style:opacity-0 **:data-previous:data-ending-style:opacity-0 **:data-previous:data-starting-style:opacity-0 **:data-current:w-[calc(var(--popup-width)-2*var(--viewport-inline-padding)-2px)] **:data-previous:w-[calc(var(--popup-width)-2*var(--viewport-inline-padding)-2px)] **:data-current:opacity-100 **:data-previous:opacity-100 **:data-current:transition-opacity **:data-previous:transition-opacity
  (105-110):        tooltipStyle + default padding: "py-1 [--viewport-inline-padding:--spacing(2)]", else the padding map; not tooltipStyle: "not-data-transitioning:overflow-y-auto"; panel: "overflow-visible py-2 [--viewport-inline-padding:--spacing(2)]"
```
`data-slot`s: `popover-positioner`, `popover-popup`, `popover-viewport`. The Viewport is a plain div when `keepMounted` (67).

Resolved default popover: glass surface (popover at 83.6%, blur, 1px border foreground 10%), radius 10px (14px when it contains a Calendar), ::before line (bottom black 4% light, top white 6% dark), shadow light `0 16px 40px -18px rgba(0,0,0,.55)` / dark `0 18px 44px -18px rgba(0,0,0,.8)`, text popover-foreground. Padding: default 16px all round; compact 8px vertical, 12px horizontal; none 0 with a 9px inner radius; with a Calendar 8px. Width: content (auto) or 256 / 320 / 384px capped at viewport - 32px; positioner capped at the available width; the viewport scrolls vertically past the available height. Enter: from scale .98 and opacity 0 to 1 over 150ms `cubic-bezier(.4,0,.2,1)`. Exit: none (no ending style), it disappears at once. Size changes animate width/height over 150ms; when the active trigger changes, old and new content cross-fade (opacity, 150ms) and the positioner animates `transform` unless `data-instant`.

tooltipStyle: width fit-content, balanced text, radius 8px (::before 7px), 12px text, `shadow-md/5`, still glass, padding 4px 8px.

panel variant: z-index 46, width min(280px, anchor width), no positioner transition; popup full width, transparent, no border, radius, shadow, ::before or backdrop filter; viewport visible overflow, padding 8px.

PopoverTitle (129): `font-semibold text-sm leading-none` = 14px, line-height 14px, weight 600, `data-slot="popover-title"`.

Collision: padding 5px, `{fallbackAxisSide:"end"}` (popover-Dewldpee.js imports `Bi` = `Q2`). Usage: padding none 12, compact 8; width md 12, lg 6, sm 2; panel 2.

## 15. Tooltip (`tooltip.tsx`)

`TooltipProvider = Tooltip.Provider` (6). `Tooltip` (37-63) wraps Root and closes hovered tooltips on scroll inside `TooltipScrollDismissArea` (16-35). TooltipTrigger `data-slot="tooltip-trigger"` (65-81).

TooltipPopup (83-135). Defaults `align "center"`, `sideOffset 4`, `side "top"`, `variant "default"` (85-88).
```
Positioner (105): pointer-events-none z-[140] h-(--positioner-height) w-(--positioner-width) max-w-(--available-width) transition-[top,left,right,bottom,transform] data-instant:transition-none       data-slot="tooltip-positioner"
Popup base (112): relative flex h-(--popup-height,auto) w-(--popup-width,auto) origin-(--transform-origin) text-balance rounded-md text-popover-foreground text-xs transition-[width,height,scale,opacity] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-md)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] data-ending-style:scale-98 data-starting-style:scale-98 data-ending-style:opacity-0 data-starting-style:opacity-0 data-instant:duration-0 dark:before:shadow-[0_-1px_--theme(--color-white/6%)]
  glass (114):    dropdown-glass shadow-xl shadow-black/25 before:hidden
  else (115):     border bg-popover not-dark:bg-clip-padding shadow-md/5
  code (118):     max-w-120 wrap-anywhere text-left font-mono text-[11px] leading-relaxed
  else (119):     max-w-80 wrap-anywhere whitespace-normal leading-snug
Viewport (126):   relative size-full overflow-clip px-(--viewport-inline-padding) py-1 [--viewport-inline-padding:--spacing(2)] data-instant:transition-none **:data-current:data-ending-style:opacity-0 **:data-current:data-starting-style:opacity-0 **:data-previous:data-ending-style:opacity-0 **:data-previous:data-starting-style:opacity-0 **:data-current:w-[calc(var(--popup-width)-2*var(--viewport-inline-padding)-2px)] **:data-previous:w-[calc(var(--popup-width)-2*var(--viewport-inline-padding)-2px)] **:data-previous:truncate **:data-current:opacity-100 **:data-previous:opacity-100 **:data-current:transition-opacity **:data-previous:transition-opacity      data-slot="tooltip-viewport"
```
Resolved default tooltip: radius 8px, 1px `--contrast-border` (zinc-200 / white 6%), opaque `--popover` fill (white clipped to the padding box / #111), text popover-foreground (zinc-800 / neutral-100), 12px text with line-height 1.375 (16.5px; `leading-snug` #1798 beats `text-xs` #1775), balanced wrapping, `overflow-wrap: anywhere`, max-width 320px, padding 4px 8px, shadow `0 4px 6px -1px rgba(0,0,0,.05), 0 2px 4px -2px rgba(0,0,0,.05)`, ::before line (bottom black 4% light, top white 6% dark). One line is about 26.5px tall. Never interactive (positioner pointer-events none).

glass variant: dropdown-glass fill/blur/border, shadow `0 20px 25px -5px rgba(0,0,0,.25), 0 8px 10px -6px rgba(0,0,0,.25)`, no ::before. code variant: monospace 11px, line-height 1.625 (17.875px), left aligned, max-width 480px.

Motion: enter from scale .98 + opacity 0, exit to scale .98 + opacity 0, 150ms `cubic-bezier(.4,0,.2,1)` (also width/height when content changes); `data-instant` makes it 0ms. Moving between triggers slides the positioner (top/left/right/bottom/transform, 150ms) unless instant.

Delays: base-ui trigger default `delay` 600ms, `closeDelay` 0 (utils-5_-Qnp8u.js `b=c??600,x=u??0`); Provider `timeout` default 400ms (`timeout:r=400`). App call sites override, for example `Sidebar.tsx:5148` and `:5214` Provider delay 150, `ModelPickerContent.tsx:847` delay 0, `PullRequestDetailPanel.tsx:1650` delay 150 closeDelay 150 timeout 400, `settingsLayout.tsx:152` delay 200, `ContextWindowMeter.tsx:45` delay 150. Collision padding 5px, `{fallbackAxisSide:"end"}`. Usage: 325 TooltipPopups (310 default, 12 code, 3 glass).

## 16. PreviewCard (`preview-card.tsx`)

`PreviewCard = PreviewCard.Root` (5); trigger `data-slot="preview-card-trigger"` (7-9). PreviewCardPopup (11-42), defaults `align "start"`, `side "top"`, `sideOffset 6` (13-15).
```
Positioner (26): z-[140] max-w-(--available-width)       data-slot="preview-card-positioner"
Popup (33):      origin-(--transform-origin) rounded-lg border bg-popover text-popover-foreground shadow-lg outline-none transition-[scale,opacity] data-ending-style:scale-98 data-starting-style:scale-98 data-ending-style:opacity-0 data-starting-style:opacity-0      data-slot="preview-card-popup"
```
Resolved: radius 10px, 1px `--contrast-border`, opaque `--popover`, text popover-foreground, shadow `0 10px 15px -3px rgba(0,0,0,.1), 0 4px 6px -4px rgba(0,0,0,.1)`, no padding (callers add it), not glass. Enter and exit: scale .98 + opacity 0, 150ms. Opens above the trigger, start aligned, 6px gap. base-ui defaults: delay 600ms, closeDelay 300ms (ChatMarkdown-DkQvpFEN.js `b=i??600,x=a??300`); PullRequestLinkPreview passes delay 350, closeDelay 120 (bundle). Collision padding 5px, `{fallbackAxisSide:"end"}`.

## 17. Dialog (`dialog.tsx`, `dialog-styles.ts`)

dialog-styles.ts:
```
DIALOG_BACKDROP_BASE_CLASS (1-2):  fixed inset-0 z-50 transition-all duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0
DIALOG_BACKDROP_CLASS (4):         dialog-backdrop ${DIALOG_BACKDROP_BASE_CLASS}
DIALOG_MEDIA_BACKDROP_CLASS (5):   ${DIALOG_BACKDROP_BASE_CLASS} bg-black/75 backdrop-blur-none
DIALOG_POPUP_BASE_CLASS (7-8):     -translate-y-[calc(1.25rem*var(--nested-dialogs))] relative flex min-h-0 w-full min-w-0 scale-[calc(1-0.1*var(--nested-dialogs))] flex-col opacity-[calc(1-0.1*var(--nested-dialogs))] outline-none transition-[scale,opacity,translate] duration-200 ease-in-out will-change-transform data-nested:data-ending-style:translate-y-8 data-nested:data-starting-style:translate-y-8 data-nested-dialog-open:origin-top data-ending-style:scale-98 data-starting-style:scale-98 data-ending-style:opacity-0 data-starting-style:opacity-0 [-webkit-app-region:no-drag]
DIALOG_POPUP_CLASS (10):           dialog-glass ${DIALOG_POPUP_BASE_CLASS} rounded-2xl border
DIALOG_MEDIA_POPUP_CLASS (11):     ${DIALOG_POPUP_BASE_CLASS} max-h-[92vh] w-auto max-w-[92vw] overflow-visible rounded-none border border-transparent bg-transparent p-0 shadow-none
DIALOG_MOBILE_SHEET_CLASS (13-14): max-sm:max-w-none max-sm:rounded-none max-sm:border-x-0 max-sm:border-t max-sm:border-b-0 max-sm:opacity-[calc(1-min(var(--nested-dialogs),1))] max-sm:data-ending-style:translate-y-4 max-sm:data-starting-style:translate-y-4
```
dialog.tsx parts: `Dialog = Dialog.Root` (16); Portal (18); Trigger `data-slot="dialog-trigger"` (20-22, base-ui gives it `aria-haspopup="dialog"` and only `data-popup-open`); Close (24-26).
- DialogBackdrop (28-44): `forceRender`, `data-slot="dialog-backdrop"`, class per variant.
- DialogViewport (50): `fixed inset-0 z-50 grid grid-rows-[1fr_auto_1fr] justify-items-center p-4`, `data-slot="dialog-viewport"`.
- DialogPopup (59-107), defaults `showCloseButton true`, `bottomStickOnMobile true`, `variant "default"` (62-64). Backdrop gets `z-[60]` for media (74). Viewport extras: `max-sm:grid-rows-[1fr_auto] max-sm:p-0 max-sm:pt-12` (77); media `z-[60] grid-rows-1 place-items-center px-4 py-6 [-webkit-app-region:no-drag]` (79). Popup classes (83-89): popup class by variant, `row-start-2 text-popover-foreground`, default `max-h-full max-w-lg`, mobile sheet class. `data-slot="dialog-popup"`.
- Close button (94-102): `Dialog.Close aria-label="Close" className="absolute end-2 top-2" render={<Button size="icon" variant="ghost" />}` with `<XIcon />`.

Resolved, default dialog at >=640:
| Part | Value |
|---|---|
| Backdrop | fixed, z 50; light `--background` at 60% (#fcfcfc), dark at 64% (#0a0a0a); `backdrop-filter: blur(4px)` |
| Viewport | fixed, z 50, 3-row grid (1fr auto 1fr), items centred, padding 16px, so the popup is vertically centred |
| Popup | width 100% up to 512px (`max-w-lg` 32rem), max-height 100% of the viewport content box, flex column, radius 18px, 1px border |
| Popup fill | `dialog-glass`: background at 80% alpha, blur 12px saturate 1.14 (light) or 16px / 1.08 (dark) |
| Popup border | light foreground 10% (zinc-800 at 10%), dark white 8% |
| Popup shadow | light `0 24px 64px -24px rgba(0,0,0,.65)`; dark `inset 0 1px rgba(255,255,255,.04), 0 24px 72px -20px rgba(0,0,0,.9)` |
| Text | popover-foreground |
| Close button | ghost icon Button 32x32 (36x36 below 640) at 8px from top and end; X icon 16px (18px) muted-foreground; hover fill accent |
| Enter | backdrop opacity 0 to 1 (`transition-all` 200ms, default curve); popup from scale .98 + opacity 0, 200ms `cubic-bezier(.4,0,.2,1)` |
| Exit | the reverse of enter |
| Nested | parent scales to 1 - 0.1 x n, fades to 1 - 0.1 x n, moves up 20px x n; `data-nested-dialog-open` sets transform-origin top; a child dialog enters and exits with translateY 32px |

Below 640 with `bottomStickOnMobile`: the popup docks at the bottom (rows 1fr auto, 48px top padding, no side padding), full width, radius 0, only a 1px top border, opacity 1 - min(n,1) when nested, enter and exit with translateY 16px.

Media variant: backdrop black 75% with no blur, z 60; viewport z 60, single row, centred, padding 24px 16px; popup auto width, max 92vw x 92vh, transparent, no border colour, no padding or shadow, visible overflow.

DialogHeader (113): `flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4` = column, gap 8px, padding 24px; bottom padding 12px when the popup contains a DialogPanel; 16px below 640.

DialogFooter (122-141): base `flex flex-col-reverse gap-2 px-6 sm:flex-row sm:justify-end sm:rounded-b-[calc(var(--radius-2xl)-1px)]`; `default`: `border-t bg-muted/72 py-4`; `bare`: `py-4`. Resolved: padding 16px 24px, gap 8px, row aligned to the end with 17px bottom corners at >=640, reversed column below; default footer adds a 1px `--contrast-border` top line and muted at 72% (light #fafafa at 72%, dark white 2.16%). Usage: 22 default, 9 bare.

DialogTitle (146): `wrap-anywhere font-semibold text-xl leading-none` = 20px, line-height 20px, weight 600. DialogDescription (156): `text-muted-foreground text-sm` = 14px/20px muted-foreground.

DialogPanel (163-180): `ScrollArea scrollFade` (default true) around `space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1` = padding 24px, 16px between children, top padding 4px when there is a header, bottom padding 4px when the footer is bare. Scroll fade masks 24px at overflowing edges.

## 18. AlertDialog (`alert-dialog.tsx`)

- Backdrop (16-25): `forceRender`, `DIALOG_BACKDROP_CLASS`, `data-slot="alert-dialog-backdrop"`.
- Viewport (31): `fixed inset-0 z-50 grid grid-rows-[1fr_auto_1fr] justify-items-center p-4`.
- Popup (40-68): `DIALOG_POPUP_CLASS` + `row-start-2 max-h-full max-w-lg text-popover-foreground` + mobile sheet class (`bottomStickOnMobile` default true, viewport `max-sm:grid-rows-[1fr_auto] max-sm:p-0 max-sm:pt-12`, line 53); optional `portalContainer`. No close button. Visuals and motion identical to Dialog.
- Header (73): `flex flex-col gap-2 p-6 text-center max-sm:pb-4 sm:text-left` (centred text below 640, left at >=640).
- Footer (90-92): base as DialogFooter; `default`: `border-t bg-muted/72 py-4`; `bare`: `pb-6` (24px bottom, no top padding).
- Title (104) and Description (114): as Dialog.

## 19. Sheet (`sheet.tsx`)

Built on the Dialog primitive (3). Sheets sit on `--z-sheet` (46), under dialogs (comment 13-14).
```
Backdrop (19):   fixed inset-0 z-(--z-sheet) bg-background/60 backdrop-blur-xs transition-all duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0
Viewport (40-45): fixed inset-0 z-(--z-sheet) grid | bottom: grid grid-rows-[1fr_auto] pt-12 | top: grid grid-rows-[auto_1fr] pb-12 | left: flex justify-start | right: flex justify-end | inset: sm:p-4
Popup (90):      relative flex max-h-full min-h-0 w-full min-w-0 flex-col bg-popover not-dark:bg-clip-padding text-popover-foreground shadow-lg/5 transition-[opacity,translate] duration-200 ease-in-out will-change-transform before:pointer-events-none before:absolute before:inset-0 before:shadow-[0_1px_--theme(--color-black/4%)] data-ending-style:opacity-0 data-starting-style:opacity-0 max-sm:before:hidden dark:before:shadow-[0_-1px_--theme(--color-white/6%)]
  bottom (92):   row-start-2 border-t data-ending-style:translate-y-8 data-starting-style:translate-y-8
  top (94):      data-ending-style:-translate-y-8 data-starting-style:-translate-y-8 border-b
  left (96):     data-ending-style:-translate-x-8 data-starting-style:-translate-x-8 w-[calc(100%-(--spacing(12)))] max-w-md border-e
  right (98):    col-start-2 w-[calc(100%-(--spacing(12)))] max-w-md border-s data-ending-style:translate-x-8 data-starting-style:translate-x-8
  inset (100):   before:hidden sm:rounded-2xl sm:border sm:before:rounded-[calc(var(--radius-2xl)-1px)] sm:**:data-[slot=sheet-footer]:rounded-b-[calc(var(--radius-2xl)-1px)]
  instant (102): transition-none! will-change-auto! data-ending-style:translate-x-0! data-starting-style:translate-x-0! data-ending-style:translate-y-0! data-starting-style:translate-y-0! data-ending-style:opacity-100! data-starting-style:opacity-100!
Backdrop when instant (82): transition-none! data-ending-style:opacity-100! data-starting-style:opacity-100!
```
Defaults: `showCloseButton true`, `keepMounted false`, `side "right"`, `variant "default"` (57-61); `transitionDurationMs` sets an inline duration, 0 makes it instant (71-75). Close button as Dialog (110-118).

Resolved right sheet: backdrop `--background` at 60% with 4px blur, z 46; panel full height, width viewport - 48px up to 448px, 1px border on its inner (start) edge, opaque `--popover` (white / #111), `shadow-lg/5` (`0 10px 15px -3px rgba(0,0,0,.05), 0 4px 6px -4px rgba(0,0,0,.05)`), ::before line (hidden below 640). Motion: opacity and translate over 200ms `cubic-bezier(.4,0,.2,1)`, from and to 32px offset toward its edge (right +32px x, left -32px x, bottom +32px y, top -32px y). Inset variant at >=640: 16px viewport padding, radius 18px, border on all sides, ::before hidden, footer radius 17px.

SheetHeader (129): `flex flex-col gap-2 p-6 in-[[data-slot=sheet-popup]:has([data-slot=sheet-panel])]:pb-3 max-sm:pb-4`; SheetTitle (141) `font-semibold text-xl leading-none`; SheetDescription (151) `text-muted-foreground text-sm`.

## 20. Color picker (`color-picker.tsx`)

No base-ui primitive.

ColorSaturationValuePlane (65-173), `role="group"`, variant default `inset`:
```
container (119): relative cursor-crosshair touch-none overflow-hidden bg-[linear-gradient(to_top,#000,transparent),linear-gradient(to_right,#fff,transparent)] has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring has-[:focus-visible]:ring-offset-2 has-[:focus-visible]:ring-offset-popover
variant (120):   edge: "h-36 rounded-none" | inset: "h-32 rounded-lg"
inline style (124): backgroundColor: hsl(<h> 100% 50%)
focus label (157): pointer-events-none invisible absolute bottom-2 left-2 z-10 rounded bg-popover px-1.5 py-0.5 text-xs text-popover-foreground peer-focus-visible:visible
thumb (164):     pointer-events-none absolute size-3 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white shadow-[0_0_0_1px_rgb(0_0_0/0.4)]
thumb position (166-168): left calc(s * (100% - 0.75rem) + 0.375rem), top calc((1 - v) * (100% - 0.75rem) + 0.375rem)
```
Resolved: 128px tall with 10px radius (inset) or 144px with no radius (edge); hue fill with a white-to-transparent horizontal gradient and a black-to-transparent vertical gradient on top (compiled `linear-gradient(#0000,#000),linear-gradient(90deg,#fff,#0000)`); keyboard focus on either hidden range input shows a 2px ring with a 2px `--popover` gap and a label (bottom-left 8px, 4px radius, popover fill, 2px 6px padding, 12px text) reading for example `Saturation 42%`. Thumb: 12px circle, 2px white border, `0 0 0 1px rgba(0,0,0,.4)` outline, no fill, kept 6px inside the edges. Thumb motion `left 80ms linear, top 80ms linear, background-color 80ms linear`, disabled while dragging (34-36). Keys: arrows ±0.02, Shift ±0.1, Home 0, End 1 (89-112).

ColorHueSlider (175-225), `role="slider"`, tabIndex 0:
```
container (203): relative flex h-6 cursor-pointer touch-none items-center rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-popover
track (213):     h-2.5 w-full rounded-full bg-[linear-gradient(to_right,#f00,#ff0,#0f0,#0ff,#00f,#f0f,#f00)] shadow-[inset_0_0_0_1px_rgb(0_0_0_/_12%)]
thumb (216):     pointer-events-none absolute top-1/2 size-4 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white shadow-[0_0_0_1px_rgb(0_0_0/0.4)]
thumb style (218-220): left calc(h/360 * (100% - 1rem) + 0.5rem), backgroundColor hsl(h 100% 50%)
```
Resolved: 24px hit area, 10px rounded track with the rainbow gradient (compiled `linear-gradient(90deg,red,#ff0,#0f0,#0ff,#00f,#f0f,red)`) and a 1px inner 12% black outline, 16px thumb filled with the hue, 2px white border, 1px 40% black outline, kept 8px inside the ends. Keys: arrows ±1 degree, Shift ±10 (188-194).

## 21. Calendar (`calendar.tsx`)

`DayPicker` from `@daypicker/react`, `data-slot="calendar"` (102), `mode "single"`, `showOutsideDays true`, short month names in dropdowns (104). Root class (99): `w-fit [--cell-size:--spacing(10)] sm:[--cell-size:--spacing(9)]` = 40px cells below 640, 36px at >=640.
```
buttonClassNames (8-9), used for nav buttons and as day_button base:
  relative flex size-(--cell-size) text-base sm:text-sm items-center justify-center rounded-lg text-foreground not-in-data-selected:hover:bg-accent disabled:pointer-events-none disabled:opacity-64 [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0
day_button extra (59):
  in-data-disabled:pointer-events-none in-[.range-middle]:rounded-none in-[.range-end:not(.range-start)]:rounded-s-none in-[.range-start:not(.range-end)]:rounded-e-none in-[.range-middle]:in-data-selected:bg-accent in-data-selected:bg-primary in-[.range-middle]:in-data-selected:text-foreground in-data-disabled:text-muted-foreground/72 in-data-outside:text-muted-foreground/72 in-data-selected:in-data-outside:text-primary-foreground in-data-selected:text-primary-foreground in-data-disabled:line-through outline-none in-[[data-selected]:not(.range-middle)]:transition-[border-radius,box-shadow] focus-visible:z-1 focus-visible:ring-[3px] focus-visible:ring-ring/50
caption_label (55): text-base sm:text-sm font-medium flex items-center gap-2 h-full
day (56):           size-(--cell-size) text-sm py-px
dropdown (61):      absolute bg-popover inset-0 opacity-0
dropdown_root (63): relative has-focus:border-ring has-focus:ring-ring/50 has-focus:ring-[3px] border border-input shadow-xs/5 rounded-lg px-[calc(--spacing(3)-1px)] h-9 sm:h-8 [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:-me-1
dropdowns (65):     w-full flex items-center text-base sm:text-sm justify-center h-(--cell-size) gap-1.5 *:[span]:font-medium
hidden (66): invisible   month (67): w-full
month_caption (69): relative mx-(--cell-size) px-1 mb-1 flex h-(--cell-size) items-center justify-center z-2
months (70):        relative flex flex-col sm:flex-row gap-2
nav (71):           absolute top-0 flex w-full justify-between z-1
outside (72):       text-muted-foreground data-selected:bg-accent/50 data-selected:text-muted-foreground
range_end/middle/start (73-75): range-end / range-middle / range-start
today (77):         *:after:pointer-events-none *:after:absolute *:after:bottom-1 *:after:start-1/2 *:after:z-1 *:after:size-[3px] *:after:-translate-x-1/2 *:after:rounded-full *:after:bg-primary [&[data-selected]:not(.range-middle)>*]:after:bg-background [&[data-disabled]>*]:after:bg-foreground/30
week_number / weekday (78-79): size-(--cell-size) p-0 text-xs font-medium text-muted-foreground/72
```
Resolved: day and nav buttons are cell-size squares, radius 10px, 16px / 14px text, foreground; hover accent unless inside a selected day; selected day primary fill with primary-foreground text; range middle accent fill, foreground text, square corners; range start/end square on the inner side; disabled days muted-foreground 72% with line-through; outside days muted-foreground 72%; keyboard focus 3px ring at `--ring` 50%, z 1. Today: a 3px primary dot centred 4px above the bottom (background colour on a selected day, foreground 30% when disabled). Weekday headers 12px weight 500 muted-foreground 72%. Caption: 16px / 14px weight 500, height = cell, margin-bottom 4px, nav row absolute at the top with chevrons (lucide `ChevronLeftIcon`/`ChevronRightIcon`, rotated in RTL; `ChevronsUpDownIcon` for dropdowns) 18 / 16px at 80% opacity. Month/year dropdown root: 36 / 32px tall, 1px input border, `shadow-xs/5`, 10px radius, 11px padding, focus border ring + 3px ring at 50%. Months stack in a column below 640, row at >=640, gap 8px. Inside a PopoverPopup: popup radius 14px, viewport padding 8px.

## 22. ScrollArea helper (`scroll-area.tsx`)

Used by ComboboxList, AutocompleteList (so CommandList) and DialogPanel.
```
Root (51-52):     relative size-full min-h-0 overflow-hidden + rounded-[inherit] (or rounded-none)
Viewport (60):    h-full max-h-[inherit] overflow-auto overscroll-contain rounded-[inherit] outline-none transition-shadow focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background data-has-overflow-x:overscroll-x-contain
  scrollFade (63): mask-t-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-start)))] mask-b-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-end)))] mask-l-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-start)))] mask-r-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-end)))] [--fade-size:1.5rem]
  scrollFadePadding (64): scroll-p-[var(--fade-size)]
  scrollbarGutter (65): scrollbar-gutter-stable
Scrollbar (92):   flex opacity-0 transition-opacity delay-300 data-[orientation=horizontal]:mx-1 data-[orientation=horizontal]:mb-px data-[orientation=horizontal]:h-1.5 data-[orientation=vertical]:my-1 data-[orientation=vertical]:mr-px data-[orientation=vertical]:w-1.5 data-[orientation=horizontal]:flex-col data-hovering:opacity-100 data-scrolling:opacity-100 data-hovering:delay-0 data-scrolling:delay-0 data-hovering:duration-100 data-scrolling:duration-100
Thumb (100):      relative flex-1 rounded-full bg-[var(--app-scrollbar-thumb)] transition-colors hover:bg-[var(--app-scrollbar-thumb-hover)]
```
Resolved: edges that have more content fade out over up to 24px (mask), and focused or highlighted items keep 24px scroll padding; overlay scrollbar 6px wide, inset 4px from the ends and 1px from the edge, hidden until hover or scroll (fade in 100ms, fade out after 300ms delay), pill thumb #d9d9d9 (hover #bfbfbf) in light, white 8% (hover 12%) in dark.

## 23. Theme overrides (`html[data-theme-id]`, index.css:1389-1440)

These rules are unlayered in the compiled CSS (no `@layer` context), so they beat every Tailwind utility regardless of specificity, including variant hover rules.

- 1389-1392: `html[data-theme-id] [data-chat-header]` gets `background-color: var(--toolbar-background); color: var(--contrast-toolbar-foreground)`.
- 1394-1401: inside the chat header, every `[data-slot="button"]`, `[data-slot="menu-trigger"]` and `[data-toolbar-control]` gets `--control-icon-color: var(--contrast-toolbar-control-foreground); background-color: var(--toolbar-control); border-color: var(--contrast-toolbar-border); color: var(--contrast-toolbar-control-foreground)`. All Button variants there become filled toolbar controls.
- 1428-1435: the same elements on `:hover` or `[data-pressed]` get `background-color: var(--toolbar-control-hover)` (not limited to hover-capable pointers).
- 1408-1414: in `[data-panel-layout-controls]` and `[data-workspace-titlebar-controls]`, `[data-slot="toggle"]` and `[data-slot="tooltip-trigger"]` take `--control-icon-color` and `color` from `--contrast-toolbar-foreground` (fill stays ghost). Disabled (1416-1426): `color-mix(in oklab, var(--contrast-toolbar-foreground) 55%, var(--toolbar-background))`.
- 1437-1439: chat header `[data-slot="separator"]` fill `--contrast-toolbar-border`.
- Activation: `applyThemePalette` sets `root.dataset.themeId = palette.id` for a named palette and deletes it for the default theme (`themePalette.ts:1546-1561`); the theme editor preview sets it too (1532). With the default theme these rules do not apply. Named themes also remap the semantic tokens (`html[data-theme-id]:not([data-theme-id=""])`, index.css:1246-1311), which is out of scope here.
- Default toolbar tokens for reference (index.css:1086-1091): `--toolbar-background: var(--app-chrome-background)`, `--toolbar-foreground: var(--foreground)`, `--toolbar-border: var(--border)`, `--toolbar-control: var(--popover)`, `--toolbar-control-foreground: var(--foreground)`, `--toolbar-control-hover: var(--accent)`.
- index.css:1332-1335: a popover or tooltip positioner that contains `[data-theme-editor-panel]` gets `z-index: 120` (unlayered, beats `z-[130]`/`z-[140]`).

## 24. Summary tables

### 24.1 Control heights in px (<640 / >=640, border included)

| Control | Sizes |
|---|---|
| Button text sizes | micro 20/20; xs 28/24; compact 28/28; sm 32/28; sm-multiline min 32/28; default 36/32; lg 40/36; xl 44/40 |
| Button icon sizes | icon-tiny 16/16; icon-micro 20/20; icon-xs 28/24; icon-sm 32/28; icon 36/32; icon-lg 40/36; icon-xl 44/40 |
| Input | compact 30/30; sm 32/28; default 36/32; lg 40/36 |
| Textarea (min) | sm 78/66; default 82/70; lg 86/74; max 256 |
| InputGroup | default 36/32 (from the input); lg 36/36; with textarea min 94/82 (+2 border) |
| NumberField group | sm 32/28; default 36/32; lg 40/36 |
| Select trigger | xs 28/24; compact 28/28; sm min 32/28; default min 36/32; lg min 40/36 |
| Combobox/Autocomplete input | as Input; trigger/clear buttons 32/28 square |
| Command input | 40/36 (lg Input, borderless) |
| Calendar | cell 40/36; month dropdown 36/32 |
| Rows | Menu/Select/Combobox/Autocomplete item min 32/28; Menu touch density 40/40; Command item 36/32 (one line); group labels 28/28 |
| Kbd | 20/20 |
| Toggle (`toggle.tsx:17-24`, outside Part A, for reference) | segmented 24/24; xs 28/24; compact 28/28; sm 32/28; default 36/32; lg 40/36 |
| Switch (`switch.tsx:21-24`, outside Part A) | default track 22x38 / 18x30; sm 18x30 / 16x26 |
| Menu checkbox switch | track 18x30 / 14x22 |

### 24.2 Popup positioning defaults

| Popup | side | align | sideOffset | alignOffset | collisionPadding | fallbackAxisSide | Size limits |
|---|---|---|---|---|---|---|---|
| Menu (menu.tsx:23-28) | bottom | center | 4 | 0 | 5 | none | min-width min(160px, 100vw-32px), max-width 100vw-32px, max-height available height |
| Submenu (menu.tsx:303-320) | inline-end | start | 0 | -5 | 5 | end | as Menu |
| Select (select.tsx:106-111) | bottom (side "none" when aligned to trigger) | start | 4 | 0 | 5 | none | min-width trigger width; list max-height available height |
| Combobox (combobox.tsx:140-144) | bottom | start | 4 | 0 | 5 | none (lazyFlip) | min-width anchor, max-width available, max-height min(available, 368px) |
| Autocomplete (autocomplete.tsx:81-85) | bottom | start | 4 | 0 | 5 | none | as Combobox |
| Popover (popover.tsx:43-46) | bottom | center | 4 | 0 | 5 | end | width auto or 256/320/384 capped at 100vw-32px; max-width and viewport max-height = available |
| Tooltip (tooltip.tsx:85-87) | top | center | 4 | 0 | 5 | end | max-width 320px (code 480px) |
| PreviewCard (preview-card.tsx:13-15) | top | start | 6 | 0 | 5 | end | max-width available |
| Dialog | centred in a 3-row grid, 16px viewport padding | | | | | | max-width 512px, max-height viewport - 32px |
| Command dialog | top, padding-block 10vh (>=640) or max(16px, 4vh) | | | | | | 576 x 420 max |
| Sheet | docked to an edge | | | | | | width 100% - 48px, max 448px |

All popups are portaled (base-ui Portal). All positioners use the base-ui collision defaults described in 1.7.

### 24.3 Motion

| Element | Enter | Exit | Timing |
|---|---|---|---|
| Menu, Select, Combobox, Autocomplete popups | none | none | instant |
| Popover popup | scale .98 to 1, opacity 0 to 1 | none (instant) | 150ms `cubic-bezier(.4,0,.2,1)`; width/height also animate |
| Popover positioner | `transform` transition | | 150ms; none when `data-instant` or panel |
| Tooltip popup | scale .98, opacity 0 to 1 | back to scale .98, opacity 0 | 150ms; 0ms when `data-instant` |
| Tooltip positioner | top/left/right/bottom/transform transition | | 150ms; none when `data-instant` |
| PreviewCard | scale .98, opacity 0 to 1 | reverse | 150ms |
| Dialog / AlertDialog / Command popup | scale .98, opacity 0 to 1 (nested child +32px y; mobile +16px y) | reverse | 200ms `cubic-bezier(.4,0,.2,1)` |
| Dialog backdrop | opacity 0 to 1 | reverse | 200ms (`transition-all`) |
| Sheet panel | opacity 0 and 32px offset toward its edge, to rest | reverse | 200ms `cubic-bezier(.4,0,.2,1)`; inline override via `transitionDurationMs` |
| Sheet backdrop | opacity 0 to 1 | reverse | 200ms |
| Button | `:active` scale .97 (no aria-haspopup); focus ring box-shadow | | 150ms; colours change instantly |
| Select trigger | colour, box-shadow, background | | 150ms |
| Input, Textarea, NumberField, InputGroup frames | box-shadow (ring) | | 150ms |
| Menu switch thumb | translate .15s, border-radius .15s, scale .1s after .1s, transform-origin .15s | | |
| Color thumbs | left/top/background-color 80ms linear (not while dragging) | | |
| ScrollArea scrollbar | opacity to 1 on hover/scroll in 100ms | fades after a 300ms delay | 150ms default |

### 24.4 z-index values

| z-index | Where | Source |
|---|---|---|
| 140 | Tooltip positioner | tooltip.tsx:105 |
| 140 | PreviewCard positioner | preview-card.tsx:26 |
| 130 | Menu positioner (root and submenus) | menu.tsx:44 |
| 130 | Select positioner | select.tsx:130 |
| 130 | Combobox positioner | combobox.tsx:162 |
| 130 | Autocomplete positioner | autocomplete.tsx:100 |
| 130 | Popover positioner (default variant) | popover.tsx:79 |
| 120 | Popover or Tooltip positioner containing `[data-theme-editor-panel]` (unlayered override) | index.css:1332-1335 |
| 101 | `#theme-inspector-hover` (not a Part A component) | index.css:1351 |
| 100 | `#theme-inspector-spotlight` (not a Part A component) | index.css:1324 |
| 60 | Dialog media variant backdrop and viewport | dialog.tsx:74, 79 |
| 50 | Dialog, AlertDialog and Command backdrops | dialog-styles.ts:2 |
| 50 | Dialog and AlertDialog viewports | dialog.tsx:50, alert-dialog.tsx:31 |
| 50 | Command dialog viewport | command.tsx:43 |
| 50 | Select scroll arrows (inside the z-130 positioner) | select.tsx:141, 160 |
| 47 to 49 | floating preview player, per comment only (UNVERIFIED, previewMiniPlayerLayout.ts not read) | index.css:113-114 |
| 46 | Sheet backdrop and viewport (`--z-sheet`) | sheet.tsx:19, 40; index.css:115 |
| 46 | Popover `panel` variant positioner | popover.tsx:78 |
| 20 | Button `media-navigation` | button.tsx:60 |
| 10 | Combobox and Autocomplete start addon | combobox.tsx:54, autocomplete.tsx:33 |
| 10 | Color plane focus label | color-picker.tsx:157 |
| 2 | Calendar month caption | calendar.tsx:69 |
| 1 | Calendar nav row, focused day button, today dot | calendar.tsx:71, 59, 77 |
| none | base-ui modal backdrop (invisible, DOM order) | utils-5_-Qnp8u.js `d6` |

## 25. UNVERIFIED and open items

1. Nothing was checked in a running app. Values are from source, the compiled CSS and the shipped JS.
2. Quirks derived from tailwind-merge rules and compiled rule order, not observed: Button and Select `compact` render 14px text and 16px unsized icons at >=640; Button `icon-micro` and `icon-tiny` render unsized icons at 16px at >=640; CommandFooterAction still fills accent on hover; NumberField sm input line-height 34px at >=640; MenuItem `ghost` merge result (unused in app JSX).
3. base-ui details not traced in the bundle: Menu.Root `modal` default; `aria-haspopup` on Menu, Select and Popover triggers (verified only for Dialog.Trigger); Select scroll arrow positioning and visibility logic; exact conditions for `data-instant` on tooltips and popovers.
4. Hex and P3 values are my own conversions from the CSS colours (standard OKLab matrices). Composite colours over glass depend on what is behind the popup; the examples given (accent over #111 = #1b1b1b, foreground 8% over white = #eeeeee, over #111 = #242424) assume an opaque backdrop.
5. Usage counts come from a regex scan of JSX opening tags and are approximate.
6. Only the default theme is described. Named themes remap tokens (index.css:1246-1311) and enable the toolbar overrides in section 23.
