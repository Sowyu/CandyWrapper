# E. Design tokens, theming, components, layout and motion (T3 Code v0.0.46-nightly.20261009.2861)

Research notes for the native macOS (Swift 6 + AppKit, custom-drawn) T3 Code client. The official app is the spec.
These notes feed `docs/design.md` and the token generator `scripts/extract-tokens`.

## 0. Scope, sources and conventions

- Source: `/Users/mrm/CandyWrapper-research/t3code` at tag `v0.0.46-nightly.20261009.2861` (detached HEAD, clean tree).
  Paths below are relative to that root unless they start with `~` or `/`.
- Built client shipped by the server (read-only): `~/.t3/runtime/versions/0.0.46-nightly.20261009.2861/client/`.
  The stylesheet is a single file, `assets/main-pEuGmXiu.css` (header: `tailwindcss v4.3.3`). The JS is split into about
  2,350 chunks in `assets/` (each lucide icon, each Shiki theme and grammar is its own chunk). No `.map` files ship.
- The repo has no `node_modules`, so third-party values (Tailwind palette, Pierre themes and CSS, morphicons) were read
  from the built bundle. Pinned versions come from `pnpm-workspace.yaml` (catalog) and `pnpm-lock.yaml`:
  tailwindcss and @tailwindcss/vite 4.3.3, lightningcss 1.33.0, @base-ui/react 1.5.0, class-variance-authority 0.7.1,
  tailwind-merge 3.6.0, lucide and lucide-react 0.564.0, morphicons 1.7.1, @pierre/diffs 1.5.2 (patched by
  `patches/@pierre%2Fdiffs@1.5.2.patch`), @pierre/trees 1.0.0-beta.6, @pierre/theme 2.0.0 (diffs) and 1.1.0 (trees),
  shiki 4.2.0 (@shikijs/themes 4.3.0), @formkit/auto-animate 0.9.0, culori 4.0.2, mermaid 11.17.2, electron 44.4.5,
  react 19.2.6.
- Citations are `file:line`. "Compiled CSS" means `main-pEuGmXiu.css`. Anything not verified in source or bundle is
  marked **UNVERIFIED**.
- Units: root font size is 16px by default but is user-configurable (Settings > Appearance > interface size,
  12 to 20px, see section 2). Every `rem` value scales with it; the prompt, code and terminal sizes are absolute px.
  All px conversions below assume the default 16px root.
- Tailwind spacing: `--spacing: .25rem` (compiled CSS theme layer), so `p-1` = 4px, `h-8` = 32px, `p-2.5` = 10px,
  `h-[4.875rem]` = 78px.
- Breakpoints are Tailwind defaults (no `--breakpoint-*` overrides anywhere in `apps/web/src/index.css`):
  `sm` 640px, `md` 768px, `lg` 1024px, `xl` 1280px, `2xl` 1536px. `max-sm:` means below 640px.
- Custom variants (`apps/web/src/index.css:3-15`): `dark` = `&:is(.dark, .dark *)` (class on `<html>`), `light` =
  `&:not(.dark, .dark *)`, `wco` = `&:is(.wco, .wco *)` (Windows Controls Overlay, not macOS), `any-hover` =
  `@media (any-hover: hover) { &:hover }`. Tailwind's own `hover:` compiles inside `@media (hover:hover)`.

## 1. Design tokens

### 1.1 How the token system is built

1. `@import "tailwindcss";` (`index.css:1`), Tailwind v4 CSS-first config, no `tailwind.config`. `apps/web/components.json`
   says shadcn style `base-mira`, base colour `zinc`, CSS variables on, icon library `lucide`, registries
   `@coss` (coss.com/ui) and `@spell`.
2. `@theme { --font-sans; --font-mono }` (`index.css:166-170`): real theme variables, emitted as `--font-*` in the
   compiled theme layer, so runtime overrides of `--font-sans` and `--font-mono` reach every utility.
3. `@theme inline { ... }` (`index.css:172-332`): colour, radius, text-size, shadow, easing and animation tokens that
   are inlined into utilities. Every colour utility resolves to a semantic CSS variable, for example `bg-background`
   compiles to `background-color: var(--background)` and `text-foreground` to `color: var(--contrast-foreground)`.
4. Semantic variables are defined on `:root` with a `@variant dark` block (`index.css:1081-1190`), overridden for the
   sidebar subtree (`[data-app-sidebar]`, `index.css:1195-1237`), and overridden again by theme palettes
   (`html[data-theme-id]:not([data-theme-id=""])`, `index.css:1246-1311`, values set at runtime as `--app-theme-*`).
5. A contrast layer (`index.css:1521-1633`) derives `--contrast-*` variables from the semantic ones and the user's
   contrast setting. Foreground-type utilities read the `--contrast-*` versions.
6. Opacity modifiers compile to `color-mix(in oklab, <colour> N%, transparent)`, with a plain-colour fallback outside
   `@supports (color: color-mix(in lab, red, red))` (compiled CSS, for example `.bg-card\/40`).
   `--alpha(var(--color-white) / 3%)` compiles to `color-mix(in oklab, var(--color-white) 3%, transparent)`
   (fallback `#ffffff08`).

### 1.2 Base palette in use (Tailwind 4.3.3 values from the compiled theme layer)

Tailwind only emits palette colours that are referenced. The full list emitted (all `oklch(L C h)`), with the sRGB hex
that Chromium shows on an sRGB display (my conversion, which reproduces the hex values the app itself captured in
`packages/shared/src/themePalettes.ts:137-263`). Colours marked P3 lie outside sRGB: on a wide-gamut Mac display
Chromium paints them at their real Display-P3 value, so the native app must build these colours from OKLCH
(unclamped linear sRGB, then convert to Display P3) rather than from the clipped hex.

| Token | OKLCH | sRGB hex | Display P3 (if outside sRGB) |
|---|---|---|---|
| zinc-25 (custom, `index.css:215`) | oklch(99.2% 0 0) | #fcfcfc | |
| zinc-50 | oklch(98.5% 0 0) | #fafafa | |
| zinc-100 | oklch(96.7% .001 286.375) | #f4f4f5 | |
| zinc-200 | oklch(92% .004 286.32) | #e4e4e7 | |
| zinc-300 | oklch(87.1% .006 286.286) | #d4d4d8 | |
| zinc-400 | oklch(70.5% .015 286.067) | #9f9fa9 | |
| zinc-500 | oklch(55.2% .016 285.938) | #71717b | |
| zinc-800 | oklch(27.4% .006 286.033) | #27272a | |
| zinc-900 | oklch(21% .006 285.885) | #18181b | |
| neutral-100 | oklch(97% 0 0) | #f5f5f5 | |
| neutral-500 | oklch(55.6% 0 0) | #737373 | |
| neutral-950 | oklch(14.5% 0 0) | #0a0a0a | |
| red-300 / 400 / 500 / 600 / 700 | oklch(80.8% .114 19.571) / (70.4% .191 22.216) / (63.7% .237 25.331) / (57.7% .245 27.325) / (50.5% .213 27.518) | 400 #ff6467, 500 #fb2c36, 600 #e7000b, 700 #c10007 | 400 P3(0.9335 0.4317 0.4235), 600 P3(0.8303 0.1404 0.1332), 700 P3(0.6927 0.1162 0.1047) |
| orange-400 / 500 / 600 | (75% .183 55.934) / (70.5% .213 47.604) / (64.6% .222 41.116) | 400 #ff8904, 600 #f54900 | 400 P3(0.9502 0.5618 0.2110), 600 P3(0.8875 0.3417 0.0220) |
| amber-300 / 400 / 500 / 600 / 700 | (87.9% .169 91.605) / (82.8% .189 84.429) / (76.9% .188 70.08) / (66.6% .179 58.318) / (55.5% .163 48.998) | 400 #ffb900, 500 #fe9a00, 700 #bb4d00 | 400 P3(0.9592 0.7385 0.1183), 500 P3(0.9399 0.6206 0.0585), 700 P3(0.6799 0.3277 0.0521) |
| yellow-400 / 500 / 600 | (85.2% .199 91.936) / (79.5% .184 86.047) / (68.1% .162 75.834) | | |
| lime-400 / 500 / 600 | (84.1% .238 128.85) / (76.8% .233 130.85) / (64.8% .2 131.684) | | |
| green-400 / 500 / 600 | (79.2% .209 151.711) / (72.3% .219 149.579) / (62.7% .194 149.214) | | |
| emerald-300 / 400 / 500 / 600 / 700 | (84.5% .143 164.978) / (76.5% .177 163.223) / (69.6% .17 162.48) / (59.6% .145 163.225) / (50.8% .118 165.612) | 400 #00d492, 500 #00bc7d, 600 #009966, 700 #007a55 | 400 P3(0.3347 0.8196 0.5916), 500 P3(0.2671 0.7268 0.5084), 600 P3(0.2066 0.5891 0.4140), 700 P3(0.1640 0.4702 0.3435) |
| teal-300 / 400 / 500 / 600 | (85.5% .138 181.071) / (77.7% .152 181.912) / (70.4% .14 182.503) / (60% .118 184.704) | | |
| cyan-400 / 500 / 600 | (78.9% .154 211.53) / (71.5% .143 215.221) / (60.9% .126 221.723) | | |
| sky-300 / 400 / 500 / 600 | (82.8% .111 230.318) / (74.6% .16 232.661) / (68.5% .169 237.323) / (58.8% .158 241.966) | | |
| blue-400 / 500 / 600 / 700 | (70.7% .165 254.624) / (62.3% .214 259.815) / (54.6% .245 262.881) / (48.8% .243 264.376) | 400 #51a2ff, 500 #2b7fff, 600 #155dfc, 700 #1447e6 | 400 P3(0.3974 0.6281 0.9921), 500 P3(0.2664 0.4912 0.9886) |
| indigo-300..600, violet-300..600, purple-400..600, fuchsia-400..600, pink-400..600, rose-400..600, gray-400..600 | see compiled CSS theme layer | | used by project icon colours and provider accents |
| black / white | #000 / #fff | | |

Every hue family used by `apps/web/src/projectIconColors.ts` (text `-600` light, `-400` dark, swatch `-500`) is in the
list above; the script should read the full list from the compiled theme layer (section 11).

Non-palette literals:
- Light primary `oklch(0.488 0.217 264)` = #1b4ed8; dark primary `oklch(0.571 0.21 264)` = #346bf1
  (`index.css:1098`, `1162`). Both inside sRGB.
- Dark tool error icon `#fca5a5` (`index.css:1171`).
- Terminal cursor light `rgb(38 56 78)`, dark `rgb(180 203 255)`; selection light `rgb(37 63 99 / 20%)`, dark
  `rgb(180 203 255 / 25%)` (`index.css:1148-1149`, `1187-1188`).
- Find highlight (`index.css:377-393`, CSS Custom Highlight API): light match fg `oklch(0.216164 0.028283 77.423)`
  #21180a on bg `oklch(0.915 0.11 85)` #ffde8b (P3 0.9973 0.8749 0.5897); dark match fg `oklch(0.970151 0 0)` #f5f5f5
  on `oklch(0.55 0.1 85)` #8c6c1f; active match (both modes) bg `oklch(0.774202 0.151946 74.331)` #eea52b with the
  dark-brown fg.
- Scrollbar thumb light `rgb(217 217 217)` / hover `rgb(191 191 191)`; dark `rgb(255 255 255 / 8%)` / hover `12%`
  (`index.css:95-96`, `144-145`).

### 1.3 Semantic colour tokens, default palette (no theme selected)

By default no theme is stored, the boot script deletes `data-theme-id` (`apps/web/index.html:233-237`, `354-360`) and
`applyThemePalette` removes every `--app-theme-*` variable (`apps/web/src/themePalette.ts:1559-1562`). So the default
look is exactly the `:root` tokens below. Source `index.css:1081-1190`. The hex column is what the app itself recorded
as "the palette T3 Code wears with no theme installed, alpha tokens flattened over their real backdrop"
(`packages/shared/src/themePalettes.ts:128-263`, `T3_CODE_LIGHT_THEME_COLORS` / `T3_CODE_DARK_THEME_COLORS`). Keep
alpha tokens as alpha in the native app (they sit on different backdrops); the flattened hex is a check value.

| Variable | Light | Dark | Flattened hex light / dark |
|---|---|---|---|
| `--radius` | 0.625rem (10px) | same | |
| `--background` | zinc-25 | neutral-950 | #fcfcfc / #0a0a0a |
| `--app-chrome-background` | var(--background) | same | |
| `--toolbar-background` | var(--app-chrome-background) | same | #fcfcfc / #0a0a0a |
| `--toolbar-foreground` | var(--foreground) | same | #27272a / #f5f5f5 |
| `--toolbar-border` | var(--border) | same | #e4e4e7 / #191919 |
| `--toolbar-control` | var(--popover) | same | #ffffff / #111111 |
| `--toolbar-control-foreground` | var(--foreground) | same | |
| `--toolbar-control-hover` | var(--accent) | same | #f4f4f5 / #141414 |
| `--surface-raised` | color-mix(in srgb, var(--card) 20%, transparent) | color-mix(in srgb, var(--background) 97%, white) | #fcfcfc / #111111 |
| `--foreground` | zinc-800 | neutral-100 | #27272a / #f5f5f5 |
| `--card` | white | color-mix(in srgb, neutral-950 97%, white) | #ffffff / #111111 |
| `--card-foreground` | zinc-800 | neutral-100 | |
| `--popover` | white | same mix as card | #ffffff / #111111 |
| `--popover-foreground` | zinc-800 | neutral-100 | |
| `--primary` | oklch(0.488 0.217 264) | oklch(0.571 0.21 264) | #1b4ed8 / #346bf1 |
| `--primary-foreground` | white | white (not overridden) | |
| `--secondary` | zinc-50 | white 3% | #fafafa / #111111 |
| `--secondary-foreground` | zinc-800 | neutral-100 | |
| `--muted` | zinc-50 | white 3% | #fafafa / #111111 |
| `--muted-foreground` | zinc-500 | color-mix(in srgb, neutral-500 90%, white) | #71717b / #818181 |
| `--placeholder`, `--secondary-label`, `--icon-muted` | var(--muted-foreground) | same | |
| `--accent` | zinc-100 | white 4% | #f4f4f5 / #141414 |
| `--accent-foreground` | zinc-900 | neutral-100 | #18181b / #f5f5f5 |
| `--message-surface` (user bubble) | var(--accent) | same | #f4f4f5 / #141414 |
| `--message-foreground` | var(--foreground) | same | |
| `--message-action` (send button, CTA) | var(--primary) | same | #1b4ed8 / #346bf1 |
| `--message-action-foreground` | var(--primary-foreground) | same | #ffffff |
| `--message-action-hover` | color-mix(in srgb, var(--primary) 90%, var(--background)) | same formula | #3160db / #3061d9 |
| `--error` | red-500 | color-mix(in srgb, red-500 90%, white) | #fb2c36 / #fb414a |
| `--error-foreground` | red-700 | red-400 | #c10007 / #ff6467 |
| `--tool-error-icon` | var(--error) | #fca5a5 | |
| `--error-surface` | color-mix(in srgb, var(--error) 8%, transparent) | 16% | #fcebec / #301214 |
| `--destructive` | var(--error) | same | |
| `--destructive-foreground` | var(--error-foreground) | same | |
| `--border` | zinc-200 | white 6% | #e4e4e7 / #191919 |
| `--input` | zinc-300 | white 8% | #d4d4d8 / #1e1e1e |
| `--ring` | var(--primary) | same | #1b4ed8 / #346bf1 |
| `--info` | blue-500 | blue-500 | |
| `--info-foreground` | blue-700 | blue-400 | |
| `--success` | emerald-500 | emerald-500 | |
| `--success-foreground` | emerald-700 | emerald-400 | |
| `--warning` | amber-500 | amber-500 | #fe9a00 |
| `--warning-foreground` | amber-700 | amber-400 | #bb4d00 / #ffb900 |
| `--warning-surface` | color-mix(in srgb, var(--warning) 8%, transparent) | 16% | #fcf4e8 / #312108 |
| `--update` | var(--primary) | same | |
| `--update-foreground` | var(--primary) | blue-400 | #1b4ed8 / #51a2ff |
| `--update-surface` | color-mix(in srgb, var(--update) 12%, transparent) | 18% | #e0e6f7 / #121b34 |
| `--sidebar` | zinc-50 | var(--card) (then #000 in the sidebar subtree, 1.4) | #fafafa / #000000 |
| `--sidebar-foreground` | var(--foreground) | same | |
| `--sidebar-muted-foreground` | var(--muted-foreground) | same | |
| `--sidebar-control-surface` | zinc-100 | var(--muted) | |
| `--sidebar-row-hover` | zinc-25 | var(--accent) | |
| `--sidebar-row-active` | white | var(--accent) | |
| `--sidebar-row-selected` | white | var(--muted) | |
| `--sidebar-border` | var(--border) | same | |
| `--sidebar-stage-fade` | var(--sidebar) | var(--card) | |
| `--code-background` | color-mix(in srgb, var(--card) 90%, var(--background)) | same formula | #ffffff / #111111 |
| `--code-foreground` | var(--foreground) | same | |
| `--terminal-background` / `--terminal-foreground` | var(--background) / var(--foreground) | same | #fcfcfc / #0a0a0a |
| `--terminal-cursor` | rgb(38 56 78) | rgb(180 203 255) | #26384e / #b4cbff |
| `--terminal-selection-background` | rgb(37 63 99 / 20%) | rgb(180 203 255 / 25%) | #d0d6dd / #343a47 |
| `color-scheme` | light | dark | |

Two more `:root` variables: `--diff-addition: var(--success)`, `--diff-deletion: var(--destructive)`,
`--diff-addition-foreground: light-dark(emerald-600, emerald-400)`, `--diff-deletion-foreground: light-dark(red-600,
red-400)` (`index.css:2069-2074`). Colour-blind option `data-diff-color-scheme="blue-orange"` (`index.css:2086-2099`):
addition `light-dark(blue-600, blue-400)`, deletion `light-dark(orange-600, orange-400)`, foregrounds equal to them, and
the same pair is pushed into Pierre (`--diffs-addition-color-override`, `--diffs-deletion-color-override`) and the
file tree (`--trees-status-*-override`, `--trees-git-*-color-override`).

The splash and boot fallbacks are a different, hard-coded palette (section 4.2): light `#ffffff` / `#262626` /
accent `#4f46e5`, dark `#0a0a0a` / `#f5f5f5` / accent `#818cf8` (`apps/web/index.html:15-32`).

### 1.4 Sidebar subtree overrides (`[data-app-sidebar]`, `index.css:1195-1237`)

The app sidebar root carries `data-app-sidebar` (`apps/web/src/components/AppSidebarLayout.tsx:320`). Inside it the
tokens are redefined (and `--contrast-*` recomputed, because `index.css:1521-1522` targets `:root, [data-app-sidebar]`):

| Variable | Light | Dark |
|---|---|---|
| `--background` | zinc-25 | #000 |
| `--foreground` | zinc-800 | #f1f3f7 |
| `--card` | white | #000 |
| `--card-foreground` | zinc-800 | var(--foreground) |
| `--accent` | zinc-100 | #191a1d |
| `--accent-foreground` | zinc-900 | #f7f9ff |
| `--muted` | zinc-50 | #0a0a0a |
| `--muted-foreground` | zinc-500 | #a3a3a3 |
| `--border` | zinc-200 | rgb(255 255 255 / 8%) |
| `--input` | zinc-300 | rgb(255 255 255 / 18%) |
| `--sidebar` | zinc-50 | var(--card) = #000 |
| `--sidebar-foreground` | zinc-800 | var(--foreground) |
| `--sidebar-muted-foreground` | zinc-500 | var(--muted-foreground) |
| `--sidebar-control-surface` | zinc-100 | var(--muted) |
| `--sidebar-row-hover` | zinc-25 | color-mix(in srgb, var(--contrast-foreground) 8%, transparent) |
| `--sidebar-row-active` | white | ... 11% ... |
| `--sidebar-row-selected` | white | ... 7% ... |
| `--sidebar-border` | zinc-200 | var(--border) |
| `--sidebar-stage-fade` | var(--sidebar) | var(--card) |

So the default dark sidebar is pure black (#000) next to a #0a0a0a canvas; the light sidebar is zinc-50 (#fafafa)
next to a zinc-25 (#fcfcfc) canvas. When a theme is active, `html[data-theme-id] [data-app-sidebar]` maps the subtree
to the theme roles and sets the sidebar's border colour to `color-mix(in srgb, var(--contrast-sidebar-foreground) 10%,
transparent)` (dark 8%) (`index.css:1485-1510`); the T3 Chat theme keeps its pink `--contrast-sidebar-border` in dark
(`index.css:1514-1518`).

Also inside the sidebar: `--sidebar-icon-color: color-mix(in srgb, var(--contrast-sidebar-muted-foreground) 60%,
var(--sidebar))` (`index.css:104-108`).

### 1.5 The contrast layer (runtime algorithm to port)

Setting: Settings > Appearance > Contrast, integer 50 to 200, default 100 (`packages/contracts/src/settings.ts:105-111`).
`applyAppearanceContrast` (`apps/web/src/appearanceContrast.ts:3-10`) writes on `<html>`:
- `--appearance-contrast-base = min(contrast, 100)%`
- `--appearance-contrast-boost = max(contrast - 100, 0)%`
- `--appearance-contrast-border-boost = max(contrast - 100, 0) / 4 %`

and `--appearance-contrast-target` is `black` in light, `white` in dark (`index.css:94`, `143`). Then for each
foreground role X on its surface S (`index.css:1556-1627`):

```
--contrast-X = mix_oklab( mix_oklab(X, S, base) , target, boost )
  i.e. color-mix(in oklab, color-mix(in oklab, X base%, S), target boost%)
```

Pairs (X on S): foreground/background, muted-foreground/background, placeholder/background, secondary-label/background,
icon-muted/background, card-foreground/card, popover-foreground/popover, accent-foreground/accent,
secondary-foreground/secondary, message-foreground/message-surface, sidebar-foreground/sidebar,
sidebar-muted-foreground/sidebar, toolbar-foreground/toolbar-background,
toolbar-control-foreground/toolbar-control.

Borders mix in sRGB toward the foreground (`index.css:1532-1555`, `1628-1632`):

```
--contrast-B = color-mix(in srgb, color-mix(in srgb, B base%, transparent), F border-boost%)
```

for input/foreground, border/foreground, sidebar-border/sidebar-foreground, toolbar-border/toolbar-foreground.

At the default (base 100%, boosts 0%) every `--contrast-X` equals X. Below 100 the foreground fades toward its surface
(and borders fade toward transparent); above 100 it moves toward black/white. Note `color-mix` percentages: the first
colour gets the stated percentage and the second gets the remainder.

Prose also scales with contrast: assistant markdown text is `text-foreground/[calc(80%+var(--appearance-contrast-boost)/5)]`
(`apps/web/src/components/ChatMarkdown.tsx:3417`), that is foreground at 80% opacity, rising to 100% at contrast 200.

### 1.6 Utility to variable map (`@theme inline`, `index.css:221-282`)

| Utility colour name | Resolves to |
|---|---|
| background | var(--background) |
| foreground | var(--contrast-foreground) |
| card / card-foreground | var(--card) / var(--contrast-card-foreground) |
| popover / popover-foreground | var(--popover) / var(--contrast-popover-foreground) |
| primary / primary-foreground | var(--primary) / var(--primary-foreground) |
| secondary / secondary-foreground | var(--secondary) / var(--contrast-secondary-foreground) |
| muted / muted-foreground | var(--muted) / var(--contrast-muted-foreground) |
| accent / accent-foreground | var(--accent) / var(--contrast-accent-foreground) |
| placeholder, secondary-label, icon-muted | var(--contrast-placeholder), var(--contrast-secondary-label), var(--contrast-icon-muted) |
| border, input, ring | var(--contrast-border), var(--contrast-input), var(--ring) |
| destructive / destructive-foreground | var(--destructive) / var(--destructive-foreground) |
| error, error-foreground, error-surface, tool-error-icon | var(--error), var(--error-foreground), var(--error-surface), var(--tool-error-icon) |
| warning, warning-foreground, warning-surface | var(--warning), ... |
| update, update-foreground, update-surface | var(--update), ... |
| success, success-foreground, info, info-foreground | var(--success), ... |
| diff-addition(-foreground), diff-deletion(-foreground) | var(--diff-*) |
| code / code-foreground | var(--code-background) / var(--code-foreground) |
| surface-raised | var(--surface-raised) |
| message, message-foreground | var(--message-surface), var(--contrast-message-foreground) |
| message-action, message-action-foreground, message-action-hover | var(--message-action*) |
| sidebar, sidebar-foreground, sidebar-muted-foreground | var(--sidebar), var(--contrast-sidebar-foreground), var(--contrast-sidebar-muted-foreground) |
| sidebar-control-surface, sidebar-row-hover, sidebar-row-active, sidebar-row-selected | var(--sidebar-*) |
| sidebar-border | var(--contrast-sidebar-border) |
| zinc-25 | oklch(99.2% 0 0) |

Every element gets `border-color: var(--contrast-border)` and `outline-color: color-mix(in oklab, var(--ring) 50%,
transparent)` from `* { @apply border-border outline-ring/50; }` (`index.css:684-686`). Popups (`menu-popup`,
`select-popup`, `popover-popup`) suppress the focus outline and ring (`index.css:687-694`). `html, body` background is
`var(--app-chrome-background)` (`index.css:695-698`) and the body text colour is `text-foreground` (`index.css:699-701`).

### 1.7 Spacing and sizing variables (`index.css:89-161`, `2069-2084`)

| Variable | Value | Use |
|---|---|---|
| `--control-radius` | 0.5rem (8px) | shared radius for compact controls (palette rows, right panel add menu rows) |
| `--sidebar-content-inset` | 0.5rem (8px) | sidebar row vertical inset |
| `--sidebar-control-gap` | 0.5rem | |
| `--sidebar-row-content-inset` | 0.625rem (10px) | sidebar row horizontal inset |
| `--command-shell-inset` | 0.5rem | command palette shell |
| `--command-content-inset` | 1rem | command palette content |
| `--floating-content-inset` | 0.75rem | floating panels |
| `--workspace-topbar-height` | 52px | titlebar, chat header, right panel tab bar, sidebar header (WCO only: `max(40px, env(titlebar-area-height, 52px))`) |
| `--workspace-controls-top` | 0px | |
| `--workspace-controls-left` | calc(env(safe-area-inset-left) + 0.75rem); macOS desktop not fullscreen: `var(--desktop-window-controls-inset, 90px)` (`AppSidebarLayout.tsx:60`, `265-267`) | x of the fixed sidebar toggle |
| `--workspace-controls-right` | calc(env(safe-area-inset-right) + 0.75rem) | x of the fixed right panel toggles |
| `--workspace-native-controls-inset` | 0px (WCO only) | |
| `--workspace-titlebar-control-size` | 1.75rem (28px); below 640px 2rem (`ui/sidebar.tsx:162`) | |
| `--workspace-titlebar-control-gap` | 0.75rem (12px) | |
| `--workspace-titlebar-content-left` | calc(controls-left + control-size + control-gap) = 90 + 28 + 12 = 130px on macOS desktop (`ui/sidebar.tsx:170-171`) | |
| `--workspace-titlebar-scroll-fade-height` | 1.5rem (24px) | |
| `--chat-content-max-width` | 46rem (736px); `data-chat-width="wide"` 72rem; `"full"` 100% | timeline lane and composer |
| `--thread-details-panel-width` | 17.5rem (280px) | |
| `--workspace-gutter` | 0.75rem; 1.25rem from 640px | page header and chat gutters (web) |
| `--app-scrollbar-width` | 6px | |
| `--z-sheet` | 46 | |
| `--font-size-prompt-touch` | max(var(--font-size-prompt, 1rem), 16px) | phones only |

### 1.8 Radii

`--radius: 0.625rem` (`index.css:1083`). Radius utilities (`index.css:277-282`, compiled CSS):

| Utility | Value | px |
|---|---|---|
| rounded-xs | 0.125rem (Tailwind default) | 2 |
| rounded (bare) | 0.25rem | 4 |
| rounded-sm | calc(var(--radius) - 4px) | 6 |
| rounded-md | calc(var(--radius) - 2px) | 8 |
| rounded-lg | var(--radius) | 10 |
| rounded-xl | calc(var(--radius) + 4px) | 14 |
| rounded-2xl | calc(var(--radius) + 8px) | 18 |
| rounded-3xl | calc(var(--radius) + 12px) | 22 |
| rounded-full | 2147483647px | pill |

Literal radii seen in CSS: scrollbar thumb 3px (`index.css:1755`), code-block scrollbar thumb 999px, inline code 0.375rem
(6px), `pre` 0.75rem (12px), footnote refs 0.25rem, composer chip selection 6px, theme-inspector label 0.4rem,
settings pulse 0.75rem, Pierre tree items 5px (`pierre-tree-theme.ts:13`), diff spans 3px, Pierre separators 6px.
The composer uses `rounded-3xl` (22px) and its clip-path hard-codes 22px corners (`chat/ComposerSurface.tsx:22-29`).

### 1.9 Borders

- Width is 1px everywhere unless stated (`border`, `border-b`, `border-l`). Default colour `--contrast-border`.
- Common alpha variants: `border-border/60` (panel and section dividers, `.surface-subheader`), `border-border/70`
  (code blocks, table borders), `border-border/80`, `border-border/50` (settings row dividers),
  `border-input` (inputs, `--contrast-input`).
- Theme-independent: blockquote left border 2px `--contrast-border` (`index.css:1901`); `.ultrathink-frame` 2px
  gradient ring (`index.css:2128-2161`); composer-tiptap node selection outline 2px `--ring` offset 1px
  (`index.css:2256-2260`); settings slider thumb 2px `--primary` (`index.css:973`).
- Dark-mode code block border is transparent (`ChatMarkdown.tsx:774`).

### 1.10 Shadows (full strings)

Tailwind defaults used (compiled CSS; colour is overridable with `shadow-<colour>`):

| Utility | box-shadow |
|---|---|
| shadow-xs | 0 1px 2px 0 rgb(0 0 0 / 5%) (`#0000000d`) |
| shadow-sm | 0 1px 3px 0 rgb(0 0 0 / 10%), 0 1px 2px -1px rgb(0 0 0 / 10%) |
| shadow-md | 0 4px 6px -1px rgb(0 0 0 / 10%), 0 2px 4px -2px rgb(0 0 0 / 10%) |
| shadow-lg | 0 10px 15px -3px rgb(0 0 0 / 10%), 0 4px 6px -4px rgb(0 0 0 / 10%) |
| shadow-xl | 0 20px 25px -5px rgb(0 0 0 / 10%), 0 8px 10px -6px rgb(0 0 0 / 10%) |
| shadow-2xl | 0 25px 50px -12px rgb(0 0 0 / 25%) |
| inset-shadow-2xs | inset 0 1px rgb(0 0 0 / 5%) |
| ring (= ring-1) / ring-2 | 0 0 0 1px / 2px (+ offset) in `--tw-ring-color` |
| drop-shadow-sm / -md (filters) | 0 1px 2px #00000026 / 0 3px 3px #0000001f |

Custom (`index.css:188-194`, `400-406`, `976-1025`, `1355-1369`):

| Name | Value |
|---|---|
| `inset-shadow-control-highlight` | inset 0 1px rgb(255 255 255 / 16%) |
| `inset-shadow-control-pressed` | inset 0 1px rgb(0 0 0 / 8%) |
| `shadow-composer` (light composer) | 0 12px 28px -18px rgb(0 0 0 / 40%) |
| `shadow-composer-dark` | 0 14px 32px -18px rgb(0 0 0 / 75%) |
| `dialog-glass` light | 0 24px 64px -24px rgb(0 0 0 / 65%) |
| `dialog-glass` dark | inset 0 1px rgb(255 255 255 / 4%), 0 24px 72px -20px rgb(0 0 0 / 90%) |
| settings slider thumb | 0 1px 2px color-mix(in srgb, var(--contrast-foreground) 12%, transparent); hover 0 1px 3px ... 20%; focus `0 0 0 3px var(--background), 0 0 0 5px var(--ring)` |
| theme inspector hover | 0 0 0 3px ring 16%, 0 0 18px ring 38%; label 0 4px 16px rgb(0 0 0 / 24%) |
| settings search pulse | keyframe 0 0 0 2px color-mix(in oklab, var(--color-primary) 70%, transparent) |
| composer seam (dark) | gradients `--background-image-composer-seam-below/above` (`index.css:199-214`) |

Alpha modifiers on shadows multiply: `shadow-xs/5` compiles to `0 1px 2px 0 oklab(0% 0 0 / .05)` (identical to plain
shadow-xs), `shadow-message-action/24` sets the shadow colour to message-action at 24% (compiled CSS).

### 1.11 Opacity values in use

Disabled controls `opacity-64` (send button, many ui components; see section 5), receding sidebar rows `opacity-70`
and `text-sidebar-muted-foreground/75`, settled favicons `opacity-40 grayscale`, `/55`, `/60`, `/65`, `/70`, `/80`,
`/90`, `/95` text tints, glass surfaces at `--glass-opacity` (default 80%), `.composer-rich-marker` 0.75, Nerd-font-free
`[data-no-newline] span` 0.6, find dimmer `rgb(2 3 8 / 54%)`. The exact set per component is in section 5.

### 1.12 Typography tokens

Font families (`index.css:166-170`; mirrored in `apps/web/src/appearanceFonts.ts:20-26`):
- `--font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif` (on macOS this is the system UI
  font, SF Pro).
- `--font-mono: ui-monospace, "SF Mono", "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace` (SF Mono on
  macOS). When the user picks a custom code font the runtime value becomes `<custom>, "SF Mono", "SFMono-Regular",
  Menlo, Consolas, "Liberation Mono", monospace` (no `ui-monospace`, `appearanceFonts.ts:23-26`).
- `--font-composer` (runtime only, defaults to `var(--font-sans)`), used by the prompt editor
  (`ComposerPromptEditorTiptap.tsx:1744`).
- `--diffs-font-family: var(--font-mono)`, `--diffs-header-font-family: var(--font-sans)` (`index.css:1716-1719`).

Font sizes (Tailwind defaults plus `index.css:178-185`):

| Utility | Size | Line height |
|---|---|---|
| text-5xs | 0.4375rem (7px) | 1 (7px) |
| text-4xs | 0.5rem (8px) | 1 (8px) |
| text-3xs | 0.625rem (10px) | 0.875/0.625 = 14px |
| text-2xs | 0.6875rem (11px) | 1/0.6875 = 16px |
| text-xs | 0.75rem (12px) | 16px |
| text-sm | 0.875rem (14px) | 20px |
| text-base | 1rem (16px) | 24px |
| text-lg | 1.125rem (18px) | 28px |
| text-xl | 1.25rem (20px) | 28px |
| text-2xl | 1.5rem (24px) | 32px |
| text-3xl | 1.875rem (30px) | 36px |
| text-4xl | 2.25rem (36px) | 40px |

Explicit leading overrides: `leading-tight` 1.25, `leading-snug` 1.375, `leading-normal` 1.5, `leading-relaxed` 1.625;
`text-xs/4` style shorthand sets line height to 4 spacing units (16px).
Weights: normal 400, medium 500, semibold 600, bold 700. Markdown headings are 600 (`index.css:1790`).
Letter spacing: `tracking-tighter` -0.05em, `tracking-tight` -0.025em, `tracking-wide` 0.025em, `tracking-wider` 0.05em,
`tracking-widest` 0.1em. Base `html` line-height is 1.5 (Tailwind preflight).
Runtime sizes (section 2): `--font-size-prompt` default 14px, `--font-size-code` default 13px, `--diffs-font-size`
equals the code size, terminal default 12px.
Font smoothing: `-webkit-font-smoothing: antialiased` on `<html>` by default (`fontSmoothing` default true,
`packages/contracts/src/settings.ts:403`, applied in `appearanceFonts.ts:129-133`). On macOS this means grayscale
antialiasing without stem darkening; the native app should disable font smoothing (for example
`CGContextSetShouldSmoothFonts(false)`) to match, and enable it when the user turns the setting off.

### 1.13 z-index layers

From `index.css` and the layout code (the component agents' sections list the per-component values):
- `--z-sheet: 46` docked sheets; the floating preview mini player straddles its webview at 47 and 49
  (`index.css:113-115`, `apps/web/src/components/preview/previewMiniPlayerLayout.ts:14`); dialogs and popovers 50 and up.
- Fixed titlebar controls (sidebar toggle, right panel toggles) `z-50` (`AppSidebarLayout.tsx:142`, `ChatView.tsx:11208`).
- Theme editor panel positioners `z-index: 120`; theme inspector spotlight 100, hover box 101 (`index.css:1322-1351`).
- Chat: banners `z-20`, composer overlay `z-20`, scroll-to-end pill `z-30`, drop overlay `z-40`
  (`ChatView.tsx:11336-11520`).
- Right panel resize handle `z-20` (`preview/RightPanelResizeHandle.tsx:23`); sidebar dragging row `z-20`;
  sidebar jump badge `z-10`.
- Pierre diff: sticky file header `z-index: 4` (app CSS), gutter 3, annotations 2, utility button 4.

### 1.14 Motion tokens

- Default transition (Tailwind): 150ms `cubic-bezier(0.4, 0, 0.2, 1)`.
- `ease-in` cubic-bezier(0.4, 0, 1, 1); `ease-out` cubic-bezier(0, 0, 0.2, 1); `ease-in-out` cubic-bezier(0.4, 0, 0.2, 1);
  custom `ease-drawer` cubic-bezier(0.32, 0.72, 0, 1) (`index.css:190`).
- `--animate-spin` spin 1s linear infinite (`@keyframes spin { to { transform: rotate(360deg) } }`);
  `--animate-pulse` pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite (`50% { opacity: .5 }`);
  `--animate-skeleton` skeleton 2.4s infinite; `--animate-status-pulse` status-pulse 2s infinite;
  `--animate-status-ping` status-ping 2s infinite (`index.css:216-220`, keyframes `283-331`).
- Panel animation duration: user setting 0 to 400ms, default 0 (`packages/contracts/src/settings.ts:112-121`),
  exposed as `--panel-animation-duration` (`AppSidebarLayout.tsx:264`). Full inventory in section 7.

### 1.15 Blur, glass and grain tokens

- `--glass-blur` 12px light, 16px dark; `--glass-opacity` 80% (user setting `glassOpacity`, 40 to 100, default 80;
  at 100 the runtime forces `--glass-blur: 0px`, `apps/web/src/routes/__root.tsx:290-304`);
  `--glass-saturation` 1.14 light, 1.08 dark (`index.css:116-118`, `146-147`).
- Tailwind blur scale emitted: `--blur-xs` 4px, `--blur-sm` 8px, `--blur-md` 12px, `--blur-xl` 24px.
- Glass utilities (`index.css:334-437`): `surface-glass`, `alert-glass`, `dialog-glass`, `dialog-backdrop` (4px blur,
  background mix 60% light / 64% dark), `dropdown-glass`. Section 10 has the full definitions and users.
- Grain: an SVG feTurbulence tile, `baseFrequency 0.9`, `numOctaves 4`, `stitchTiles`, rect opacity 0.035, 256px tile
  (`index.css:1677-1680`); the T3 Chat theme uses a 128px tile at opacity 0.02745 (= 7/255) (`index.css:1685-1688`).
  Painted on `body` and on surfaces with the `surface-grain` utility (the sidebar, `ui/sidebar.tsx:224`).

### 1.16 Runtime-computed tokens (summary; algorithms in section 4)

| Source | What it writes | Where |
|---|---|---|
| Contrast setting | `--appearance-contrast-base/boost/border-boost` | `appearanceContrast.ts:3-10` |
| Glass setting | `--glass-opacity`, `--glass-blur: 0px` at 100 | `routes/__root.tsx:290-304` |
| Font settings | `--font-sans`, `--font-mono`, `--font-composer`, root `font-size`, `--font-size-prompt`, `--font-size-code`, `--diffs-font-size`, `-webkit-font-smoothing` | `appearanceFonts.ts:99-134` |
| Chat width | `data-chat-width` on `<html>` (comfortable, wide, full) | `routes/__root.tsx:278-281` |
| Diff colours | `data-diff-color-scheme` (red-green, blue-orange) | `routes/__root.tsx:273-276` |
| Theme palette | `data-theme-id` plus 60 `--app-theme-*` variables, `.dark` class | `themePalette.ts:1540-1563`, `hooks/useTheme.ts:323-366` |
| Panel animation | `--panel-animation-duration`, `data-panel-animations` | `AppSidebarLayout.tsx:262-311` |
| Sidebar width | `--sidebar-width` | `AppSidebarLayout.tsx:263`, `ui/sidebar.tsx:400-480` |
| macOS window controls | `--workspace-controls-left: 90px` unless fullscreen | `AppSidebarLayout.tsx:256-285` |
| Visible animations | `--visible-animation-state`, `--visible-animation-will-change` per element | `lib/visibleAnimation.ts` |
| Chat lane insets | `--chat-timeline-gutter`, `--chat-lane-inset-start/end` | `chat/ChatCanvas.tsx:128-135` |
| Stage art | `--stage-art-*`, `--stage-night-*` per built-in theme | `index.css:649-885` |

## 2. Fonts

- No web fonts are loaded for the UI. The compiled stylesheet has no `@font-face`. The only bundled font is
  `Symbols Nerd Font Mono` (`assets/SymbolsNerdFontMono-Regular-aK5vsLov.woff2`, from
  `apps/web/src/terminal/ghostty/fonts/SymbolsNerdFontMono-Regular.woff2`, MIT licence, Copyright (c) 2014 Ryan L
  McIntyre, `fonts/LICENSE`). It is registered lazily with `new FontFace(...)` by the first terminal and only supplies
  powerline/devicon glyphs (`terminal/ghostty/surface.ts:56-74`).
- UI font: system stack `-apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif` (`index.css:167`). On
  macOS Chromium renders this with the system font (SF Pro, with automatic optical sizes). Native equivalent:
  `NSFont.systemFont(ofSize:weight:)`. Weights used: 400, 500, 600 (and 700 rarely).
  **UNVERIFIED**: whether Chromium applies SF's `trak` tracking table the way AppKit does; compare a rendered string
  at 12, 13, 14px against `NSFont.systemFont` before trusting widths.
- Monospace: `ui-monospace, "SF Mono", ...` (`index.css:168-169`), i.e. SF Mono on macOS
  (`NSFont.monospacedSystemFont(ofSize:weight:)`).
- Boot splash uses the same system stack (`apps/web/index.html:413-417`). The WSL connecting splash uses
  `system-ui,-apple-system,'Segoe UI',sans-serif` at 13px (`apps/desktop/src/window/DesktopWindow.ts:215`).
- Pierre diffs fall back to `"SF Mono", Monaco, Consolas, "Ubuntu Mono", "Liberation Mono", "Courier New", monospace`
  and header `system-ui, -apple-system, ...` but the app routes both to the app tokens (`index.css:1716-1719`,
  `lib/diffRendering.ts:321-322`).
- Terminal default family (canvas renderer, concrete names only): `"SF Mono", "SFMono-Regular", Menlo, Consolas,
  "Liberation Mono", "Symbols Nerd Font Mono", "Symbols Nerd Font", "JetBrainsMono Nerd Font", "JetBrainsMono NF",
  "FiraCode Nerd Font", "Hack Nerd Font", "MesloLGS NF", "CaskaydiaCove Nerd Font", "PowerlineSymbols", monospace`
  (`terminal/ghostty/surface.ts:27-35`). Proportional custom fonts are refused (`surface.ts:96-107`).

Appearance font settings (`packages/contracts/src/settings.ts:122-157`, `384-403`; applied by `appearanceFonts.ts`):

| Setting | Default | Range | Effect |
|---|---|---|---|
| `fontSizeInterface` | 16 | 12-20 px | sets `<html>` `font-size` (scales every rem) |
| `fontSizePrompt` | 14 | 12-20 px | `--font-size-prompt` (composer text) |
| `fontSizeCode` | 13 | 10-18 px | `--font-size-code` and `--diffs-font-size` (chat code blocks, diffs, file previews) |
| `fontSizeTerminal` | 12 | 8-20 px (renderer clamps 6-32) | terminal; in "simple" typography mode the terminal follows the code size and family (`appearanceFonts.ts:35-51`, storage key `t3code:typography-advanced`) |
| `fontFamilySans` | "" | free text | prepended to the default sans stack |
| `fontFamilyCode` | "" | free text | prepended to the default code stack |
| `fontFamilyComposer` | "" | free text | composer only, falls back to `var(--font-sans)` |
| `fontFamilyTerminal` | "" | free text | terminal only |
| `fontSmoothing` | true | bool | `-webkit-font-smoothing: antialiased` |

The family picker lists installed fonts via the Local Font Access API and checks availability with canvas metric
probes (`appearanceFonts.ts:158-191`, `369-395`); "Default" is labelled "SF Pro" or "SF Mono" on Apple platforms
(`appearanceFonts.ts:303-325`).

Code text sizes in chat: `.chat-markdown .chat-markdown-shiki .shiki` and `pre code` use `var(--font-size-code, inherit)`
(`index.css:1706-1709`); inline code is 0.75rem (12px) (`index.css:1958`); composer inline code 0.92em
(`index.css:2239`).

## 3. Icons

### 3.1 Libraries and sources

| Source | Version / location | Licence | Used for |
|---|---|---|---|
| `lucide-react` | 0.564.0 | ISC | almost all UI glyphs (275 distinct import bindings in 225 non-test files under `apps/web/src`) |
| `lucide-react/dynamic` (`DynamicIcon`, `iconNames`) | 0.564.0 | ISC | user-chosen project icons: any lucide icon name can be stored as a project icon (`apps/web/src/projectIconOptions.ts:1-68`, `components/ProjectFavicon.tsx:17-18`, `settings/ProjectIconPickerDialog.tsx:170`). Because of this the build ships every lucide icon as its own chunk (about 1,680 chunks). |
| `lucide` (vanilla icon nodes) | 0.564.0 | ISC | shape data for `MorphIcon` (morphs between two lucide shapes) |
| `morphicons` | 1.7.1 | **UNVERIFIED** (not checked; read the shipped `client/third-party-licenses.json`) | `MorphIcon` path morphing (`components/MorphIcon.tsx:1-6`) |
| `@pierre/trees` built-in "complete" sprite | 1.0.0-beta.6 | **UNVERIFIED** | file-type icons in trees, diff headers, code block titles, mentions |
| App sprite `T3_FILE_ICON_SPRITE` | `apps/web/src/pierre-icons.ts:15-108` | Lucide (ISC) and Simple Icons (CC0) per comments | extra file types (video, AGENTS.md, pnpm, diff, xml, C#, Dart, Elixir, Haskell, Java, Kotlin, Lua, PHP, PowerShell, R, Scala, TOML) and the tree loading spinner |
| Custom inline SVG components | `components/Icons.tsx` (779 lines), `components/JetBrainsIcons.tsx` (610), `components/T3Wordmark.tsx`, `components/EnvironmentMachineIcon.tsx`, `components/ProjectMonogram.tsx`, `components/pullRequest/pullRequestIcons.tsx`, `components/ui/refresh-icon.tsx` | app | brand, editor, OS, VCS, provider logos |
| Provider package glyphs | `packages/provider-{cursor,grok,opencode,pi,muse}/src/client.ts` (`icon: { viewBox, fill: { light, dark }, paths }`) | app | provider logos drawn by `chat/ProviderPackageIcon.tsx` |

No icon font is used. All icons are inline SVG.

### 3.2 Default lucide geometry and styling

- lucide-react defaults: 24x24 `viewBox="0 0 24 24"`, `fill="none"`, `stroke="currentColor"`, `stroke-width="2"`,
  `stroke-linecap="round"`, `stroke-linejoin="round"` (lucide's standard attributes). The app never sets
  `absoluteStrokeWidth`, so the stroke scales with the icon: at 16px the stroke is 2 * 16/24 = 1.33px, at 14px 1.17px,
  at 12px 1px. **Native implication**: draw lucide paths scaled from the 24-unit box with stroke width 2 units, not a
  fixed 1px or 1.5px.
- Colour is `currentColor` (inherits text colour). Some surfaces set `--control-icon-color` (chat header themed
  controls, `index.css:1397`, `1412`) and the sidebar uses `--sidebar-icon-color` (60% muted-foreground mixed into
  the sidebar background, `index.css:104-108`, used by the search glyph `sidebar/SidebarThreadHeader.tsx:86`).
- Sizes used in JSX (count of icon elements with a `size-*` class, non-test files):

| Class | px | Count |
|---|---|---|
| size-3.5 | 14 | 238 |
| size-3 | 12 | 182 |
| size-4 | 16 | 108 |
| size-5 | 20 | 13 |
| size-2.5 | 10 | 8 |
| size-4.5 | 18 | 6 |
| size-2 | 8 | 2 |
| none (inherits a parent rule) | | 13 |

- Parent rules that size icons: `[&_svg:not([class*='size-'])]:size-4` (25 occurrences), `...:size-4.5` (23),
  `...:size-3.5` (8), `...:size-3` (6), `[&_svg]:size-3.5` (4), `...:size-5` (2). These live mostly in the button,
  menu, select, toggle and input variants (section 5).

### 3.3 lucide icons imported by the app (canonical lucide file names)

Counts are "number of non-test files importing it" and "references in those files outside the import line". The
canonical name is the kebab-case file in lucide's `icons/` directory. lucide-react exports both `Foo` and `FooIcon`
(and deprecated aliases); the table merges by canonical name. Aliases that are renamed upstream are resolved in the
second column where I am sure of the mapping; the rest must be resolved from lucide-react 0.564.0's export map
(section 11).

| Canonical icon | Imported as | Files | Refs |
|---|---|---|---|
| x | XIcon, X | 37 | 49 |
| check | CheckIcon, Check (lucide-react), Check (lucide, morph) | 41 | 50 |
| chevron-down | ChevronDownIcon, ChevronDown (react and lucide) | 39 | 50 |
| plus | PlusIcon, Plus (react and lucide) | 30 | 47 |
| chevron-right | ChevronRightIcon, ChevronRight (react and lucide) | 29 | 40 |
| external-link | ExternalLinkIcon, ExternalLink | 18 | 19 |
| search | SearchIcon | 14 | 16 |
| triangle-alert | TriangleAlertIcon, AlertTriangleIcon (alias) | 17 | 30 |
| download | DownloadIcon | 13 | 15 |
| info | InfoIcon | 11 | 13 |
| copy | CopyIcon, Copy (lucide, morph) | 13 | 29 |
| message-square | MessageSquareIcon | 10 | 12 |
| git-branch | GitBranchIcon | 10 | 11 |
| circle-alert | CircleAlertIcon, CircleAlert (lucide) | 10 | 16 |
| terminal | TerminalIcon | 9 | 12 |
| play | PlayIcon | 9 | 11 |
| folder | FolderIcon, Folder (lucide) | 9 | 15 |
| trash-2 | Trash2Icon, Trash2 | 10 | 11 |
| circle-check | CircleCheckIcon, CircleCheck (lucide), CheckCircle2Icon (alias) | 9 | 16 |
| folder-git-2 | FolderGit2Icon | 7 | 13 |
| eye | EyeIcon, Eye (lucide) | 9 | 11 |
| arrow-right | ArrowRightIcon, ArrowRight | 8 | 9 |
| bot | BotIcon | 7 | 8 |
| settings | SettingsIcon | 7 | 8 |
| arrow-left | ArrowLeftIcon, ArrowLeft | 7 | 9 |
| ellipsis | EllipsisIcon, MoreHorizontalIcon, MoreHorizontal (aliases) | 11 | 12 |
| minus | MinusIcon, Minus (react and lucide) | 9 | 9 |
| pencil | PencilIcon | 6 | 6 |
| rotate-ccw | RotateCcwIcon, RotateCcw | 8 | 9 |
| layers | LayersIcon | 5 | 12 |
| square-pen | SquarePenIcon | 5 | 9 |
| circle-dashed | CircleDashedIcon | 5 | 8 |
| minimize-2 | Minimize2Icon, Minimize2 (lucide) | 7 | 9 |
| hammer | HammerIcon | 5 | 6 |
| link | LinkIcon | 5 | 6 |
| chevrons-down-up | ChevronsDownUp (lucide) | 5 | 5 |
| chevrons-up-down | ChevronsUpDownIcon, ChevronsUpDown (lucide) | 8 | 8 |
| file-diff | FileDiffIcon, FileDiff | 6 | 8 |
| folder-plus | FolderPlusIcon | 4 | 11 |
| circle-x | CircleXIcon, XCircleIcon (alias) | 5 | 9 |
| smartphone | Smartphone, SmartphoneIcon | 8 | 13 |
| gauge | GaugeIcon | 4 | 7 |
| monitor | MonitorIcon | 4 | 6 |
| arrow-up-right | ArrowUpRightIcon | 4 | 5 |
| tag | TagIcon | 4 | 5 |
| eye-off | EyeOffIcon | 4 | 4 |
| panel-right | PanelRightIcon | 4 | 4 |
| palette | PaletteIcon | 3 | 7 |
| wrench | WrenchIcon | 3 | 5 |
| archive, circle-dot, git-fork, globe, hard-drive, message-square-dashed, pen-line, server, undo-2 | ...Icon | 3 each | 4 |
| arrow-down, arrow-down-up, chevron-left, chevron-up, image, lock, message-circle-question-mark (imported as MessageCircleQuestionIcon), messages-square, moon, ellipsis-vertical (MoreVertical), paintbrush, paperclip, picture-in-picture-2, rotate-cw, settings-2, sparkles, star, sun, user-round, users, text-wrap (WrapTextIcon) | | 3 each | 3 |
| alarm-clock, alarm-clock-off, pin, pin-off, loader-circle, folder-git, square-terminal (TerminalSquare), earth (Globe2, Globe2Icon), scale, brain, file-text, message-circle, mouse-pointer-click, quote, refresh-cw, zap, arrow-right-left, arrow-up, blocks, bookmark, calendar-clock, camera, chart-no-axes-column, circle, clock-3, clock, cloud, code-xml (Code2, lucide vanilla), columns-2, corner-left-up, folder-tree, git-commit-horizontal (GitCommitHorizontalIcon and GitCommitIcon), grip-vertical, laptop, link-2, list-checks, maximize-2, pilcrow, rows-3, shield-question-mark (ShieldQuestionIcon), square, table-2, text-wrap (TextWrapIcon), user-plus | | 1-2 each | |
| single-use icons | activity, archive-x, circle-arrow-up (ArrowUpCircleIcon and CircleArrowUpIcon), arrow-up-down, arrow-up-left, battery, book-open, box, bug, calendar, calendar-arrow-down, calendar-arrow-up, chevrons-left-right-ellipsis, circle-slash, cloud-download, cloud-upload, code, corner-up-right (react and lucide), cpu, database, file, file-code-corner (FileCode2Icon), file-json, file-search, file-spreadsheet, files, film, flask-conical, folder-closed (react and lucide), folder-code, folder-open, git-branch-plus, git-merge, git-pull-request-arrow, git-pull-request-closed, git-pull-request-draft, history, house (Home), inbox, keyboard, lightbulb, list-filter, list-ordered, list-plus (lucide), list-todo, lock-open (react and lucide), log-in, mail, maximize, memory-stick, message-square-off, message-square-text, message-square-warning, mouse-pointer-2, octagon-alert, package, package-plus, panel-bottom, panel-left (lucide), panel-left-close (lucide), panels-top-left, pencil-ruler, plug-2, power, presentation, qr-code, radio-tower, redo-2, route, send, shield, shield-check, sliders-horizontal, smile-plus, square-arrow-out-up-right, square-menu, square-split-horizontal, square-split-vertical, target, text-align-start (TextIcon and lucide Text), text-search, ticket, trending-down, trending-up, type, unlink-2, unplug, upload, user-check, user-lock, user-round-x, volume-2 (lucide), volume-off (lucide), wifi-off, workflow | 1 | |

Alias resolutions above were confirmed against the built bundle (the importing chunk pulls `file-code-corner-*.js`,
`text-align-start-*.js`, `text-wrap-*.js`, `house-*.js`, `git-commit-horizontal-*.js`, and `main-DYePapyp.js`
inlines `earth`, `message-circle-question-mark`, `shield-question-mark`). The lucide vanilla exports used by
MorphIcon keep the alias names (`Text`, `Code2`) but carry the same path data as `text-align-start` and `code-xml`
(see `assets/MorphIcon-ETuySZc2.js`).

`createLucideIcon` is also imported once to build a custom glyph (search `createLucideIcon` in `apps/web/src`).

Shapes used through `MorphIcon` (`lucide` vanilla data, confirmed in the built chunk `assets/MorphIcon-ETuySZc2.js`):
Check, ChevronDown, ChevronRight, ChevronUp, ChevronsDownUp, ChevronsUpDown, Circle, CircleAlert, CircleCheck, Code2,
Copy, CornerUpRight, Eye, Folder, FolderClosed, Image, ListPlus, Lock, LockOpen, Maximize2, Minimize2, Minus, Moon,
PanelLeft, PanelLeftClose, Plus, Sun, Table2, Text, Volume2, VolumeOff. Typical pairs: Copy to Check (copy buttons),
ChevronRight to ChevronDown (disclosures), Maximize2 to Minimize2 (table expand), CornerUpRight to ListPlus (send vs
queue while running, `chat/ComposerPrimaryActions.tsx:342`), Volume2 to VolumeOff, PanelLeft to PanelLeftClose,
Sun to Moon, Lock to LockOpen.

### 3.4 How to obtain the exact SVGs

1. Preferred: npm tarballs at the pinned version. `lucide-static@0.564.0` ships `icons/<name>.svg` (ready SVGs with
   the default attributes); `lucide@0.564.0` ships `dist/esm/icons/<name>.js` (icon node arrays, which are what
   MorphIcon consumes); `lucide-react@0.564.0` ships `dist/esm/icons/<name>.js` plus the alias export map
   (`dist/esm/lucide-react.js`, where each line re-exports one canonical file under all its names). Equivalent source:
   the lucide GitHub repo at tag `0.564.0`, `icons/<name>.svg`.
2. Verification against what ships: each lucide-react icon is a chunk named `<canonical>-<hash>.js` in
   `~/.t3/runtime/versions/0.0.46-nightly.20261009.2861/client/assets/` whose body is
   `r=[[\`path\`,{d:\`...\`,key:\`...\`}],...],i=t(\`<canonical>\`,r)` (for example `triangle-alert-BiHUyRl3.js`,
   `x-CSwbgjBe.js`). The extraction script can read the path data straight from these chunks to prove equality.
3. Convert to native: render each SVG to a template PDF (or keep path data and stroke it with `CGPath` at runtime).
   Stroke-based icons must keep round caps and joins and the 2-unit stroke. Never rasterise at one size.
4. Pierre file icons: the sprite comes from `getBuiltInSpriteSheet("complete")` in `@pierre/trees`; it is injected
   into the DOM together with `T3_FILE_ICON_SPRITE` (`pierre-icons.ts:183-195`). The extraction script can pull the
   sprite string out of the @pierre/trees package (or the built chunk that contains `file-tree-builtin-`) and the app
   sprite from `pierre-icons.ts:15-108`.
5. Provider and brand logos: copy the path data from `components/Icons.tsx` and the provider packages; they are not
   available elsewhere at the same geometry.

### 3.5 File-type icons

- Resolver: `createFileTreeIconResolver(T3_PIERRE_ICONS)` with `set: "complete"`, `colored: true`
  (`pierre-icons.ts:110-148`). Directories never get an icon from it (`pierre-icons.ts:174-180`).
- Name overrides: `package.json` npm logo, `tsconfig.json` TypeScript logo, `agents.md` T3 agents glyph, `pnpm-lock.yaml`
  and `pnpm-workspace.yaml` pnpm glyph. Extension overrides: video extensions (film glyph, stroke #a631be), cs/csx,
  dart, diff/patch, ex/exs, hs/lhs, java, kt/kts, lua, php, ps1/psm1/psd1, r, scala, toml, xml (`pierre-icons.ts:110-148`).
- Colours of the app sprite use `light-dark(<light>, <dark>)` pairs that match the Pierre syntax palette, for example
  C#, Haskell, Kotlin, PHP `light-dark(#693acf, #9d6afb)`; Dart `light-dark(#1ca1c7, #68cdf2)`; Elixir
  `light-dark(#a631be, #d568ea)`; Java and XML `light-dark(#d47628, #ffa359)`; Lua, PowerShell, R
  `light-dark(#1a85d4, #69b1ff)`; Scala `light-dark(#d52c36, #ff6762)`; TOML `light-dark(#84848a, #adadb1)`; diff
  `light-dark(#199f43, #5ecc71)`; pnpm `#f9ad00` plus currentColor.
- Code-fence languages map to synthetic file names (`syntheticFileNameForLanguageId`, `pierre-icons.ts:150-173`), for
  example `typescript` to `file.ts`, `bash` to `file.sh`, `dockerfile` to `Dockerfile`. A code block header shows the
  icon only (14px) when a specific icon exists, otherwise the language text (`ChatMarkdown.tsx:810-847`).
- Tree loading spinner: lucide loader-circle in the sprite, opacity 0.6, rotating 1s linear unless reduced motion
  (`pierre-tree-theme.ts:14-18`).

### 3.6 Custom and brand SVGs (`components/Icons.tsx`, line of the export, viewBox, paint)

| Component | Line | viewBox | Paint |
|---|---|---|---|
| UltrafastIcon | 5 | 0 0 24 24 | fill currentColor, stroke #163A59 |
| FinderIcon | 12 | 0 0 24 24 | multi-colour, stroke #163A59 |
| FileExplorerIcon | 28 | 0 0 24 24 | stroke currentColor |
| AppleIcon | 41 | 0 0 24 24 | fill currentColor |
| AndroidIcon | 47 | 0 0 24 24 | fill currentColor |
| LinuxIcon | 66 | -2 -2 28 28 | fill currentColor |
| GitHubIcon | 72 | 0 0 1024 1024 | fill (see source) |
| GitIcon | 84 | 0 0 256 256 | #DE4C36 |
| JujutsuIcon | 93 | 0 0 1024 1024 | #42acde and others |
| GitLabIcon | 137 | 0 0 32 32 | brand colours |
| AzureDevOpsIcon | 162 | 0 0 512 512 | gradient |
| BitbucketIcon | 326 | 8.4 14.39 2481.29 2231.21 | gradient |
| CursorIcon | 357 | 0 0 466.73 532.09 | fill currentColor |
| TraeIcon | 367 | 0 0 24 24 | fill currentColor |
| KiroIcon | 381 | 0 0 1200 1200 | brand |
| VisualStudioCode / Insiders / VSCodium | 399 / 493 / 587 | 0 0 100 100 | gradients |
| Zed | 614 | 0 0 96 96 | brand |
| OpenAI | 637 | 100 100 411 411 | `fill-current`; provider colour `text-black dark:text-white` |
| ClaudeAI | 652 | 0 0 256 257 | `fill-[#d97757]` |
| AntigravityIcon | 666 | 0 0 128 128 | embedded 128px PNG (data URL), brand text colour #5b87bf |
| ACPRegistryIcon | 672 | 0 0 576 220 | |
| ForgejoIcon | 684 | 0 0 212 212 | stroke #ff6600 |
| MacScreenRecordingIcon / MacAccessibilityIcon | 698 / 723 | 0 0 32 32 | permission prompts |
| ComputerUseAppIcon | 757 | 0 0 24 24 | white fill, stroke #315cff |

- `T3Wordmark` (`components/T3Wordmark.tsx:3-12`): one filled path, viewBox `15.5309 37 94.3941 56.96`,
  `fill="currentColor"`, drawn at `h-[1cap]` next to the word "Code" in the sidebar header (section 6).
- `JetBrainsIcons.tsx`: JetBrains IDE logos for the "Open in" picker.
- Provider package glyphs (`ProviderPackageIcon`, fill `light`/`dark` pairs): Cursor `#26251E` / `#EDECEC`
  (viewBox 0 0 466.73 532.09), Grok `#0F0F0F` / `#F5F5F5` (0 0 24 24), OpenCode `#211E1E` / `#F1ECEC` (0 0 32 40, inner
  square `#CFCECD` / `#4B4646`), Pi `#0F0F0F` / `#F5F5F5` (165.29 165.29 469.43 469.43), Muse `#171717` / `#e5e5e5`
  (0 0 150.4828 100) (`packages/provider-*/src/client.ts:17-27`).
- Provider instance icon (`chat/ProviderInstanceIcon.tsx:57-142`): glyph `size-5` by default; ACP-registry agents
  load a remote icon URL; otherwise a monogram (`text-3xs font-semibold`). Optional status dot (8px, ring 2px of the
  indicator background) and instance badge (`h-3.5 min-w-3.5 rounded-full border px-0.5 text-4xs font-semibold
  shadow-sm`, filled with `--provider-accent` when the instance has a user accent colour, otherwise `bg-card
  text-muted-foreground`). In sidebar rows the glyph is `size-3.5 opacity-60` and older providers in the stack
  `size-3 opacity-35 grayscale` (`Sidebar.tsx:379-426`).
- Assets folder (`apps/web/src/assets`): no images, only sounds (`notification-completion.mp3`,
  `notification-input.mp3`, `snap-shot-click.mp3`, `snap-shot-whoosh.mp3`). `apps/web/public`: `favicon.ico`,
  `favicon-16x16.png`, `favicon-32x32.png`, `apple-touch-icon.png` (the boot splash logo, 64x64 inside a 96x96 card,
  `index.html:440-454`), `manifest.webmanifest`.

## 4. Theming behaviour

### 4.1 Preferences and storage keys (renderer localStorage, per device)

| Key | Meaning | Default |
|---|---|---|
| `t3code:theme` | theme preference: `system`, `light`, `dark`, a built-in id, a custom id, or an environment theme id | absent, treated as `system` (`hooks/useTheme.ts:38-47`, `202-218`) |
| `t3code:theme-appearance-mode` | `system`, `light` or `dark`, independent of the theme | absent; then derived (`useTheme.ts:173-185`) |
| `t3code:theme-follow-system` | legacy boolean, read only as migration input | |
| `t3code:theme-halves:v1` | `{ "light"?: id, "dark"?: id }`, a different theme per appearance ("mix") | absent |
| `t3code:themes:v1` | array of installed custom themes (`ThemeDefinition` JSON) | absent |
| `t3code:default-theme-applied:v2:<environmentId>` | generation of the server default theme already applied | |
| `t3code:typography-advanced` | advanced typography toggle (separate terminal font) | |

The client settings (contrast, glass opacity, fonts, chat width, diff colours, panel animation duration) are not in
localStorage; they are client settings synced through `useClientSettings` (`packages/contracts/src/settings.ts:300-495`).

### 4.2 Boot (before React): `apps/web/index.html:13-402`

An inline script runs before any CSS-in-JS:
1. Reads `t3code:theme`; maps legacy ids (`t3-chat-dark` to `t3-chat` with forced dark, `t3-grove` to `grove`, and so
   on, `index.html:225-235`).
2. Resolves whether the stored id is a built-in (`BUILT_IN_THEME_PALETTES`, a boot copy of background, foreground,
   accent and chrome for each built-in and mode, `index.html:53-124`) or a stored custom theme (validated with the
   same id and label rules as the runtime, `index.html:176-217`).
3. Resolves the appearance mode: stored mode, else legacy follow-system flag, else `system` when the theme is
   `system`, else the theme's base appearance (`index.html:255-271`), then applies a stored mix half for the wanted
   appearance if it is renderable (`index.html:272-301`).
4. Sets `data-theme-id` (only when themed), `data-theme-selected="true"` (when any preference is stored), toggles
   `.dark`, sets `document.documentElement.style.backgroundColor` to the chrome colour and every
   `<meta name="theme-color">` (`index.html:354-386`). Unthemed chrome is `#ffffff` light and `#0a0a0a` dark
   (`index.html:15-16`, `370-379`). When a theme is selected it also writes `--boot-background`, `--boot-foreground`,
   `--boot-accent` for the splash.
5. On any storage error it follows the OS (dark when even matchMedia fails, `index.html:387-401`).

The splash (`index.html:404-489`): body `#ffffff` / `#262626` (dark `#0a0a0a` / `#f5f5f5`), centred 96x96 card with the
64x64 `apple-touch-icon.png`.

### 4.3 Runtime application: `apps/web/src/hooks/useTheme.ts`

`applyTheme(theme)` (`useTheme.ts:323-366`):
1. Skips while a theme-editor draft is shown (`data-theme-id="__preview"`).
2. Resolves appearance (`resolveThemeAppearance`, `themePalette.ts:1565-1591`): `system` follows
   `prefers-color-scheme` unless the theme cannot render that mode (then its base appearance); a configured half
   guarantees the appearance.
3. Adds `.no-transitions` to `<html>` when switching (sets every `transition-duration` and `animation-duration` to 0s
   with `!important`, `index.css:1072-1079`), applies the palette, toggles `.dark`, forces a reflow and removes the
   class on the next animation frame. Theme switches are therefore instant, not animated.
4. `applyThemePalette` (`themePalette.ts:1540-1563`): when a definition exists, sets `data-theme-id` and writes the
   60 `--app-theme-*` variables inline on `<html>` (role to variable map `themePalette.ts:1448-1510`); otherwise
   removes `data-theme-id` and all those variables.
5. `syncBrowserChromeTheme` copies the chrome colour (themed) or the computed background of
   `main[data-slot='sidebar-inset']` to `html`, `body` and the `theme-color` meta (`useTheme.ts:286-321`).
6. Desktop: `bridge.setTheme(resolveDesktopTheme(...))` (`useTheme.ts:368-410`) which sets
   `Electron.nativeTheme.themeSource` to `light`, `dark` or `system` (`apps/desktop/src/electron/ElectronTheme.ts:37`);
   the window background is reset to `#0a0a0a` or `#ffffff` (`apps/desktop/src/window/DesktopWindow.ts:163-165`,
   `285-301`).
7. Listeners: `prefers-color-scheme` changes and cross-window `storage` events re-apply with transitions suppressed
   (`useTheme.ts:456-509`).

Commands: command palette "Change theme" and "Change appearance"; shortcuts Cmd+Option+A (theme picker) and
Cmd+Option+Shift+A (cycle System, Light, Dark) on macOS (`docs/user/appearance.md:8-12`).

### 4.4 Theme roles and how they map to CSS

A theme is a `ThemeDefinition` (`packages/shared/src/themePalettes.ts:114-126`): `id`, `label`, `appearance`
(`light` or `dark`), `colors` (all 60 roles), optional `variants` (the other appearance), optional `collection`,
`sidebarArtwork` (built-ins only), `managed` (generated by the guided editor).

The 60 roles (`themePalettes.ts:47-109`): canvas, chrome, toolbar, toolbarForeground, toolbarBorder, toolbarControl,
toolbarControlForeground, toolbarControlHover, surface, surfaceRaised, surfaceOverlay, text, textMuted, border,
input, focus, accent, accentForeground, secondary, secondaryForeground, muted, mutedForeground, placeholder,
secondaryLabel, iconMuted, error, errorForeground, errorSurface, warning, warningForeground, warningSurface, update,
updateForeground, updateSurface, accentSurface, accentSurfaceForeground, messageSurface, messageForeground,
messageAction, messageActionForeground, messageActionHover, codeBackground, codeForeground, searchMatchBackground,
searchMatchForeground, searchMatchActiveBackground, searchMatchActiveForeground, sidebar, sidebarForeground,
sidebarMutedForeground, sidebarControlSurface, sidebarRowHover, sidebarRowActive, sidebarRowSelected, sidebarBorder,
terminalBackground, terminalForeground, terminalCursor, terminalSelection, terminalScrollbar, terminalScrollbarHover.

Role to app variable when a theme is active (`index.css:1246-1311`): background = canvas; app-chrome-background =
chrome; toolbar-* = toolbar roles; surface-raised = surfaceRaised; foreground and card/popover-foreground = text;
card = surface; popover = surfaceOverlay; **primary = messageAction** and primary-foreground =
messageActionForeground (so CTAs, switches, sliders and the send button share the action colour); secondary(-fg),
muted(-fg), placeholder, secondary-label, icon-muted direct; accent = accentSurface, accent-foreground =
accentSurfaceForeground; message-* direct; error/warning/update families direct; tool-error-icon = error-foreground;
border, input direct; **ring = focus**; sidebar family direct; sidebar-stage-fade = sidebar; code and terminal
direct. Roles `textMuted`, `accent`, `accentForeground` and the terminal scrollbars are carried as variables but only
used by specific components (for example `--app-theme-input` in the composer outline). Themed chat headers and code
blocks get extra rules (`index.css:1389-1483`).

### 4.5 Built-in themes

Five built-ins, each with a light base and a dark variant, all with `sidebarArtwork: true`
(`packages/shared/src/themePalettes.ts:265-946`): `t3-chat` (pink, label "T3 Chat"), `grove` (green), `ocean` (blue),
`ember` (orange), `iris` (violet). Every role value is a literal `oklch(...)`; the extraction script should copy the
whole objects. Boot copies of canvas/text/accent/chrome are in `index.html:53-124`.

Each built-in also sets stage-art colours for the sidebar artwork (`index.css:649-885`, defaults on `:root`, overrides
under `html[data-theme-id="..."]`, some derived with `color-mix(in oklch, ...)` at 38%, 55%, 60%, 82%).

`getDefaultThemeColors(appearance)` (the fallback for roles missing from a theme file) is the **T3 Chat** palette,
not the stock T3 Code one (`themePalette.ts:881-884`). `getStandardThemeColors` returns the stock T3 Code palette
(`T3_CODE_LIGHT_THEME_COLORS` / `T3_CODE_DARK_THEME_COLORS`) for seeding new themes (`themePalette.ts:337-342`).

### 4.6 Custom themes (installed in the client)

- Storage: `t3code:themes:v1` array. Parsing is lenient (unknown roles and bad colours are dropped, missing roles
  filled from the default palette, `themePalette.ts:133-201`).
- Colour canonicalisation: every colour is parsed with culori (any CSS literal colour), converted to OKLCH and stored as
  `oklch(L C h)` with L and C at 6 decimals and h at 3 decimals, alpha appended as ` / a` (4 decimals) when below 1;
  hue forced to 0 when C < 0.0000005 (`themePalette.ts:363-404`).
- Theme file format (export, `serializeThemeFile`, `themePalette.ts:1433-1446`), version 1:

```json
{
  "version": 1,
  "id": "my-theme",
  "name": "My Theme",
  "appearance": "dark",
  "colors": { "canvas": "oklch(0.2 0.02 300)", "...": "..." },
  "variants": { "light": { "...": "..." } },
  "collection": { "id": "open-vsx:publisher.ext", "label": "Pack" },
  "managed": true
}
```

  Rules (`parseThemeFile`, `themePalette.ts:1372-1431`): `version` must be 1; `name` 1 to 48 characters; `appearance`
  `light` or `dark`; `id` optional (derived from the name: lowercase, non-alphanumerics to `-`, max 48,
  `themeIdFromName` `themePalette.ts:1144-1152`), must match `^[a-z0-9](?:[a-z0-9-]{0,47})$` and not be reserved
  (`system`, `light`, `dark`, built-in ids and legacy `t3-*` ids, `themePalettes.ts:19-29`); `colors` must be an object
  with at least one known role and literal colours only; `variants` may only contain the other appearance.
- Import paths: T3 Code theme file, VS Code colour theme (`vscodeThemeImport.ts`), a whole VS Code extension from Open
  VSX (`openVsxThemes.ts`, search `https://open-vsx.org/api/-/search`, VSIX up to 20MB, up to 40 themes per extension,
  licence allow-list, `openVsxThemes.ts:13-87`).
- Theme editor: guided mode (canvas plus accent, generated by the vivid engine, theme marked `managed`) and advanced
  mode (per role, with family propagation, 4.8). Drafts are previewed live by writing the role variables with
  `data-theme-id="__preview"` (`themePalette.ts:1517-1538`).

### 4.7 Environment (server-published) themes: `~/.t3/userdata/themes`

- The server watches `<stateDir>/themes` (`apps/server/src/config.ts:153`, so `~/.t3/userdata/themes/` for the
  default home) and streams the set to clients (`apps/server/src/environmentTheme.ts`). The file name is the theme id
  (`nightfall.json` is id `nightfall`); id must match `^(?!(?:system|light|dark)$)[a-z0-9](?:[a-z0-9-]{0,47})$` and
  not be reserved or `t3-code` (`packages/contracts/src/server.ts:566-569`, `themePalettes.ts:37-40`).
- Limits: 32 files examined, 32KB per file, 192KB total; symlinked files rejected; fs.watch debounced 100ms
  (`environmentTheme.ts:52-63`, `98-138`, `268-272`). The folder on this machine is currently empty.
- File schema (`packages/contracts/src/server.ts:571-633`): `version?: 1`, `name` (max 48), `appearance`,
  `canvas?` and `accent?` (hex `#rgb` or `#rrggbb` only), `colors?` (role to CSS colour, max 64 characters each),
  `variants?: { light?, dark? }`. A file needs either both seeds or at least one colour.
- Short form (seeded): `{ "name": "Nightfall", "appearance": "dark", "canvas": "#1a1b26", "accent": "#7aa2f7",
  "colors": { ... } }`. Clients generate the palette with `createVividThemeColors(appearance, canvas, accent)` and then
  layer `colors` (`apps/web/src/hooks/useEnvironmentTheme.ts:21-35`). A variant for the other appearance builds on the
  default palette, not the generator.
- `t3 theme set <id>` makes it the environment default; each client applies it once per "generation" (theme plus
  set timestamp) and the user's later choice wins until the next set (`hooks/useDefaultTheme.ts`,
  `docs/user/appearance.md:45-95`). A saved custom theme with the same id wins over the published one
  (`themePalette.ts:1092-1102`).

### 4.8 Algorithms to port

**Colour maths** (`themePalette.ts:470-568`): sRGB to OKLCH via the Björn Ottosson matrices; OKLCH to sRGB with gamut
mapping by binary search on chroma (resolution 0.000001, channel tolerance 0.0001); sRGB transfer functions with the
0.04045 / 0.0031308 thresholds; WCAG relative luminance (0.03928 threshold) and contrast ratio
`(L1 + 0.05) / (L2 + 0.05)`. `solveOklchLightness` binary-searches L in 18 steps toward lighter or darker until a
contrast target is met (`themePalette.ts:570-594`).

**Readable foreground** (`themePalette.ts:822-833`): pick `rgb(255 250 255)` or `rgb(36 21 35)` (whichever contrasts
more) if either reaches 4.5:1, else pure white or black.

**Muted text** (`themePalette.ts:835-879`): mix foreground toward the background, binary search (12 steps) for the
quietest mix that keeps the target ratio; targets 4.705 (light, zinc-500 on the stock canvas) and 5.082 (dark,
`#818181` on the stock canvas).

**Standard status colours** (`themePalette.ts:602-661`): error/warning keep the stock hues (`#fb2c36`, `#c10007`,
`#fe9a00`, `#bb4d00` light; `#fb414a`, `#ff6467`, `#fe9a00`, `#ffb900` dark); surfaces are the colour mixed into the
canvas at 8% (light) or 16% (dark); foregrounds are lightness-solved to 4.6:1 on their surface. Dark vs light is
decided by canvas luminance < 0.179.

**Vivid palette engine** `createVividThemeColors(appearance, canvas, accent)` (`themePalette.ts:669-812`), used by the
guided editor, the short environment theme form and VS Code import:
- `dark = luminance(canvas) < 0.179`; `hue = accent.C < 0.02 ? canvas.h : accent.h`;
  `tintC = clamp(accent.C * 0.22, 0.008, 0.045)`; `step = dark ? +1 : -1`.
- `surfaceAt(dL, C = tintC) = { L: clamp(canvas.L + step * dL, 0.05, 0.98), C, h: hue }`.
- text: start `{ L: dark ? 0.95 : 0.2, C: min(0.035, accent.C * 0.25), h: hue }`, solved to 7:1 against the canvas.
- action (messageAction): `{ L: clamp(accent.L + (dark ? 0.06 : -0.02), 0.35, 0.85), C: max(accent.C * 0.9, 0.06),
  h: (hue + 50) mod 360 }`; hover L +0.06 (dark) or -0.06 (light).
- Surfaces (dL, C): sidebar (0.045, tintC * 1.4); surface (0.015); surfaceRaised (0.05); surfaceOverlay (0.075);
  border (dark 0.16 / light 0.12, min(0.07, accent.C * 0.35)); input (0.21 / 0.16, min(0.08, C * 0.4)); secondary
  (0.10 / 0.06, min(0.09, C * 0.5)); muted (0.06 / 0.04, min(0.06, C * 0.35)); accentSurface (0.13 / 0.08,
  min(0.11, C * 0.55)); messageSurface (0.16 / 0.10, min(0.13, C * 0.6)); codeBackground (0.035, tintC * 0.8);
  updateSurface (0.14 / 0.09, min(0.12, C * 0.55)); toolbarBorder (0.14 / 0.10, min(0.08, C * 0.4)); toolbarControl
  (0.09 / 0.05, tintC * 1.3); toolbarControlHover (0.14 / 0.09, tintC * 1.6); sidebarControlSurface (0.10 / 0.07,
  tintC * 1.5); sidebarRowHover (0.08 / 0.06, min(0.08, C * 0.45)); sidebarRowActive (0.12 / 0.09, min(0.1, C * 0.55));
  sidebarRowSelected (0.14 / 0.10, min(0.11, C * 0.6)); sidebarBorder (0.17 / 0.12, min(0.08, C * 0.4));
  terminalSelection (0.18 / 0.12, min(0.12, C * 0.55)); terminalScrollbar (0.22 / 0.16, tintC); hover (0.30 / 0.22);
  searchMatch (0.22, min(0.12, C)); searchMatchActive (0.40, min(0.18, C)).
- Foregrounds on surfaces: the text base solved to 4.6:1 on each surface; mutedForeground and placeholder via the
  muted-text search at 4.6; textMuted, secondaryLabel, iconMuted and sidebarMutedForeground via the standard muted
  contrast; accent and messageAction foregrounds via readable foreground.
- canvas = chrome = toolbar = terminalBackground = the canvas; focus = update = terminalCursor = the accent.
- Remaining roles come from the default (T3 Chat) palette, then status colours from 4.8 "Standard status colours".

**Advanced editor family propagation** `updateThemeColorFamily` (`themePalette.ts:892-1088`): editing one
representative role updates its family, for example canvas also sets chrome and toolbar; text sets toolbar
foregrounds; mutedForeground sets textMuted, placeholder, secondaryLabel, iconMuted, sidebarMutedForeground; border
sets toolbarBorder and sidebarBorder; secondary sets muted and toolbarControl and a readable secondaryForeground;
accentSurface sets toolbarControlHover; accent sets focus, update, terminalCursor and recomputes updateSurface (16% or
32%) and updateForeground; messageAction recomputes its foreground and a hover mixed 12% toward the opposite pole;
sidebarRowSelected derives hover (50%) and active (80%) mixes from the sidebar; terminalBackground derives foreground,
selection (accent at 18% or 35%) and scrollbar colours; error and warning derive surface (8% or 16%) and foreground.

**VS Code import** `parseVsCodeThemeFile` (`vscodeThemeImport.ts:190-412`): only workbench `colors` are used,
`tokenColors` are ignored (syntax colours always stay Pierre). Canvas = `editor.background`; appearance from `type`
or canvas luminance; accent = first of `focusBorder`, `button.background`, `textLink.foreground`,
`activityBarBadge.background`, `progressBar.background`, `badge.background` that differs from canvas and raised
surface by at least 1.1:1; the derived floor is `createVividThemeColors(appearance, canvas, accent at 20% over
canvas)`; then concrete keys override roles (sideBar.background, terminal.*, editorWidget.background,
menu/quickInput/dropdown backgrounds, panel.border, input.*, list selection and hover, textCodeBlock.background,
find-match colours, error and warning foregrounds), each foreground kept only if it reaches 4.5:1 on its surface.
Alpha colours are flattened over the surface they sit on. Light/dark pairs from one extension are merged into one
dual theme (`pairVsCodeThemes`, `vscodeThemeImport.ts:420-480`).

### 4.9 Contrast, accent and environment colours

- Contrast: section 1.5.
- Accent: the stock accent is the primary blue; themes set `focus` (ring) and `messageAction` (primary) separately.
- Provider accent colours: users can give a provider instance an accent (`settings/ProviderAccentColorPicker.tsx`); it
  tints the instance badge (`--provider-accent`, `chat/ProviderInstanceIcon.tsx:74-76`, `126-133`).
- Project icon colours: 18 named colours (gray, red, orange, amber, yellow, lime, green, emerald, teal, cyan, sky,
  blue, indigo, violet, purple, fuchsia, pink, rose); glyph `text-<c>-600 dark:text-<c>-400`, swatch `bg-<c>-500`
  (`apps/web/src/projectIconColors.ts:3-117`).
- Environment identification (`environmentIdentificationMode`: `artwork` (default), `pill`, `none`,
  `packages/contracts/src/settings.ts:159-161`): non-local environments are marked with stage artwork behind the
  sidebar header (`SidebarStageBackdrop.tsx`, `sidebar-stage-backdrop` utility `index.css:498-519`) or a pill badge
  next to the brand (`sidebar/SidebarChrome.tsx:44-74`). Built-in themes recolour the artwork through the
  `--stage-art-*` and `--stage-night-*` variables.
