# Design system

CandyWrapper copies T3 Code's look. The official app is the spec, so every value here comes from T3's source or from a rendering of T3's own markup. Nothing is hand-copied.

Status on 2026-10-09: milestone 2 component library complete, waiting for the user's visual sign-off.

## Sources and how to regenerate

| What | Source | Command |
|---|---|---|
| Design tokens | `design/t3-source/main.css`, T3's compiled stylesheet for the version in `T3_VERSION` | `scripts/extract-tokens` |
| Icons | lucide-static 0.564.0 (the version T3 pins) and T3's brand SVGs in `apps/web/src/components/Icons.tsx` | `scripts/extract-icons` |
| Component references | T3's own component markup and class strings, rendered with `main.css` in headless Chromium | `scripts/component-reference` |
| Fidelity report | our components rendered offscreen at 2x, diffed against the references | `cd Packages/CandyKit && swift test --filter Fidelity` |

`scripts/extract-tokens` lets Chromium resolve every CSS variable (var chains, `color-mix()`, `oklch()`) in light, dark and the sidebar subtree. The extraction therefore matches T3's rendering, not our reading of the CSS. The full token sheet is generated into [design-tokens.md](design-tokens.md).

When T3 updates: bump `T3_VERSION`, copy the new compiled CSS into `design/t3-source/main.css`, run the three scripts, then the fidelity suite.

## Fonts

T3 loads no web fonts. The UI uses the system stack (`-apple-system`, so SF Pro), drawn with `NSFont.systemFont`. Code text uses `ui-monospace`, and Chromium on this machine resolves that to Menlo, so `DSFont.mono` uses Menlo. Check this against the real desktop app on a Retina Mac before milestone 4, since T3's settings label the default as "SF Mono". The terminal's Symbols Nerd Font arrives with the terminal work.

Text is drawn with Core Text with font smoothing on. Measured against Chromium, smoothing gives 2.91% differing pixels on Button and plain antialiasing 3.27%. Baselines are rounded in device pixels the way Blink does.

## Architecture

- `DSView`: base view. Layer-backed, top-left origin, redraws only when something it owns changes (`layerContentsRedrawPolicy = .onSetNeedsDisplay`).
- `ControlView`: interaction state for clickable controls. Covers hover, `:active`, `:focus-visible` (keyboard focus only), disabled, and `data-pressed` while a control's popup is open. It also handles the 0.97 press scale and the pointer cursor.
- `BoxDecorationLayer` and `BoxStyle`: paint fill, border, outer and inset shadows, `::before` highlight lines and the focus ring in CSS painting order. The result is rasterized once per state change into a layer that extends past the view, so shadows cost nothing per frame.
- `LabelView` and `TextBlockView`: single-line and wrapping text with CSS line boxes. Wrapped text breaks lines where Chromium does in every measured case.
- `PopupHost`: popups (menus, select, combobox, popover, tooltip) live inside the window, as they do in T3's web viewport. They use base-ui's positioning: flip, 5px collision padding, transform origin at the trigger.
- `ModalHost`: dialogs and sheets with backdrop, Escape, outside click, focus trap and focus return.
- `ThemeColors`, `Themed`: token colors as dynamic `NSColor`s that follow the window's appearance. Light and dark need no redraw code. Colors use Display P3 components, as Chromium renders T3's `oklch` colors.
- `ThemeRuntime`: T3's themes and the contrast setting. Each palette token is stored as the CSS expression Chromium substitutes for it (`ThemeExpressions.generated.swift`, from `scripts/extract-tokens`); a theme change evaluates them once into new palettes and tells views as an appearance change does. With no theme at 100% contrast the palettes are the extracted tokens unchanged.
- Motion: Core Animation on transform and opacity with T3's durations and curves (default 150ms `cubic-bezier(.4,0,.2,1)`). Respects Reduce Motion. Looping animations (spinner, skeleton) run in the render server only while visible.

## Component inventory and fidelity

Each row is diffed against T3's own markup in Chromium at 2x in light and dark, across the states listed in its spec. "Differing" is the share of pixels where any channel differs by more than 8/255, averaged over the cases. The remaining differences are glyph and curve antialiasing and Core Text measuring text 0.1 to 0.3px wider than Chromium, unless the notes say otherwise.

| T3 component (`apps/web/src/components/ui/`) | Native | Cases | Differing |
|---|---|---|---|
| button.tsx | ButtonView | 270 | 2.86% |
| input.tsx, draft-input.tsx | InputView | 42 | 1.87% |
| textarea.tsx | TextareaView | 30 | 1.25% |
| input-group.tsx | InputGroupView | 28 | 0.87% |
| number-field.tsx | NumberFieldView | 30 | 2.30% |
| label.tsx | FormLabelView | 4 | 5.57% (tight crops of text) |
| kbd.tsx | KbdView | 12 | 1.94% |
| badge.tsx | BadgeView | 24 | 3.89% |
| separator.tsx | SeparatorView | 4 | 0.00% |
| skeleton.tsx | SkeletonView | 6 | 0.00% |
| spinner.tsx | SpinnerView | 16 | 1.34% |
| toggle.tsx | ToggleView | 140 | 2.34% |
| toggle-group.tsx | ToggleView (group) | 4 | 2.57% |
| switch.tsx | SwitchView | 44 | 1.46% |
| checkbox.tsx | CheckboxView | 22 | 1.21% |
| radio-group.tsx | CheckboxView (radio) | 16 | 2.07% |
| alert.tsx | AlertView | 18 | 2.68% |
| empty.tsx | EmptyView | 8 | 1.19% |
| collapsible.tsx, collapsible-section-header.tsx | CollapsibleView | 32 | 0.72% |
| menu.tsx | MenuView | 12 | 2.05% |
| select.tsx | SelectView | 42 | 1.74% trigger, 2.14% popup |
| combobox.tsx | ComboboxView | 6 | 2.14% |
| autocomplete.tsx | ComboboxView (autocomplete) | 6 | 2.14% |
| popover.tsx | PopoverView | 6 | 2.50% |
| tooltip.tsx | TooltipView | 6 | 3.50% |
| dialog.tsx | DialogView | 6 | 3.64% |
| alert-dialog.tsx | DialogView (alert) | 4 | 2.94% |
| sheet.tsx | DialogView (sheet) | 6 | 0.63% |
| toast.tsx | ToastView, ToastViewport, ToastQueue | 10 | 2.88% |
| scroll-area.tsx | ScrollAreaView | 16 | 0.86% |
| SettingsGroup, SettingsSection, SettingsRow (the card) | SettingsViews | 4 | 1.08% |
| table.tsx | TableView | 8 | 2.05% |
| group.tsx | GroupView | 12 | 4.33% |
| standalone-page.tsx | StandalonePageView | 6 | 1.28% |
| wizard.tsx | WizardStepsView | 12 | 1.40% |
| discovery-list.tsx | DiscoveryListView | 8 | 2.25% |
| middle-truncate.tsx | MiddleTruncateView | 8 | 5.00% (cut position can differ by one character) |
| panel-tab-close-button.tsx | PanelTabCloseButton | 12 | 3.69% |
| qr-code.tsx | QRCodeView | 8 | 0.00% (matrix identical to T3's encoder) |
| sidebar.tsx (SidebarMenuButton) | SidebarMenuButton | 60 | 0.72% |
| sidebar.tsx (sub-menus) | SidebarMenuButton (sub) | 2 | 0.93% |
| sidebar.tsx (container, rail, trigger) | SidebarView | behaviour tests | width limits and persistence |
| Sidebar.tsx search result, draft rows, status lines; project scope combobox | SidebarSearchResultRowView, SidebarDraftRowView, SidebarEmptyTextRowView, SidebarProjectScopeView (Features/Sidebar) | 26 | 2.09% (spec `scripts/gen-sidebar-search-spec.py`) |
| Sidebar grain (index.css) | SidebarGrain | crop vs real capture | mean 248.79 vs 248.78 light, 3.26 vs 3.29 dark |
| command.tsx | CommandPaletteView | 8 | 0.99% (items) |
| CommandPaletteContent.tsx, CommandPaletteResults.tsx (whole popup: root, submenu, search, empty) | CommandPaletteView, CommandPaletteController (Features/CommandPalette) | 8 | 2.19% (spec `scripts/gen-command-palette-spec.py`; light cases 3.4 to 4.3%, glyph antialiasing and the light shadow band above the popup) |
| color-picker.tsx | ColorPickerView | 8 | 1.17% (hue slider) |
| calendar.tsx | CalendarView | gallery only | |
| Wrapped text | TextBlockView | 16 | 7.53% (line breaks identical; glyph antialiasing) |
| ChatMarkdown.tsx, `.chat-markdown` (index.css) | MarkdownView (Features/Markdown) | 14 | 1.61%: text 1.72/2.07, lists 1.35/1.71, quotes 1.10/1.21, table 0.94/1.35, code 2.64/1.97, rule and image 0.16/0.25, file chips 2.75/3.35 (light/dark). Spec `scripts/gen-markdown-spec.py`, code colored by T3's own Shiki in the page |
| DiffPanel.tsx, @pierre/diffs with StyledDiffCodeView.tsx CSS | DiffPanelView, DiffListView (Features/Diff) | 18 + 4 | body 2.42% against pierre itself rendering each patch in Chromium (spec `scripts/gen-diff-spec.py`; wrapped text cases 4-5%); panel against 09 and 10 5.1% light, 5.5% dark (glyph antialiasing over 23 rows of file names) |
| chat/ComposerBannerStack.tsx, ComposerBanner.tsx (notices in each variant, the floating card, the stack collapsed with its peek and expanded) | ComposerNoticeBannerView, EnvironmentBannerView, ComposerBannerStackView (Features/Composer) | 20 | 2.04% (spec `scripts/gen-banner-stack-spec.py`; the peek's `shadow-md` is drawn as the 8pt band it leaves, measured on T3's rendering) |

Behaviour tests cover popup positioning and keyboard navigation, toast timing and stacking, modal focus trapping, and sidebar resize limits.

## Substitutions

Expensive web effects drawn with a cheap native equivalent. Each image shows T3 in Chromium on the left and ours on the right.

| Effect in T3 | Where | Native equivalent | Image |
|---|---|---|---|
| `surface-glass`: 80% background plus 12/16px backdrop blur | Glass button | Solid 80% fill. Identical over flat backgrounds | [glass-button](design/substitutions/glass-button.png) |
| `dropdown-glass`: popover color plus backdrop blur | Menus, select, combobox, popover, toasts, command palette | The color the glass produces: popover at 83.6% over the background | [dropdown-glass](design/substitutions/dropdown-glass.png), [toast-glass](design/substitutions/toast-glass.png) |
| `dialog-glass` | Dialog and sheet panels | Solid `--background`. Identical over T3's backdrop tint | [dialog-glass](design/substitutions/dialog-glass.png) |
| `dialog-backdrop`: tint plus 4px blur | Behind dialogs | One blurred snapshot of the window, taken when the dialog opens, under the tint. Tint alone differed on 17% (light) and 29% (dark) of pixels. Content under the backdrop stops updating while the dialog is open | (covered by the dialog fidelity cases) |
| StandalonePage glows plus `backdrop-blur-md` card | Standalone pages | The 145deg overlay only. The glows sit under an opaque layer in T3 and never show | [standalone-page](design/substitutions/standalone-page.png) |
| Sidebar grain (SVG `feTurbulence` filter) | Sidebar background | Port of the filter, rendered once into a static tile | (statistics in the table above) |

## Deliberate differences

The user's own choices where CandyWrapper looks different from T3 on purpose.

| T3 | CandyWrapper | Where |
|---|---|---|
| `NightlySkyArt` behind the sidebar header on Nightly servers | The teddy-and-milk corner of "Candy Town" by Aya_Lu ([Pixabay](https://pixabay.com/illustrations/candy-town-city-buildings-8579300/), Pixabay Content License) as a duotone under a white title and toggle: #170a26 to #a45e8c in dark mode, #22103a to #dc8fbd in light mode. Chosen 2026-10-10; the first dark palette (#2a1240 to #ffc4df, plum title) was too light for dark mode. `scripts/gen-candy-art.swift` bakes the 8-bit luma from the 1280px public download; the app maps it and paints the duotone | `StageBackdropView`, `SidebarBrandView`, `SidebarTriggerView.mediaTint` |
| `StageBackdropButtonArt`: the Nightly sky in the send button | The teddy from the same art, a circle of 196 source pixels with both ears in and its face above the arrow. The duotone follows the sidebar (light art in dark mode, deeper art in light mode); the arrow stays white with a soft plum halo. Chosen 2026-10-10 | `StageBackdropView.compact`, `ComposerPrimaryButton` |

## Glass

The classic Glass theme (`candywrapper-glass`) is CandyWrapper's own, so its material is ours. The candy artwork fades directly into the sidebar over 112pt, with a stronger gradual blur. The user rejected the persistent search and compose backgrounds on 2026-10-17, so both stay transparent at rest and retain hover and focus feedback. The compose action has a 32pt target and the header actions have 2pt gaps. Elsewhere, layout, sizes, wording and behavior stay T3's; only the surfaces change. Every other theme is untouched: the code below runs only while `ThemeRuntime.isGlass` is true. It all lives in `WindowGlass` (DesignSystem/Components/WindowGlass.swift), and views use its colors and helpers instead of their own copies.

One frost covers the window, so the desktop shows through blurred and saturated and our tints set all the density. Every surface on it is a tinted pane. Depth comes from how dense a pane is, never from soft shadows.

The frost is the desktop picture blurred once, in `WallpaperBackdropView` (DesignSystem/Components/WallpaperBackdrop.swift):

1. It reads the picture with `NSWorkspace.desktopImageURL(for:)` and lays it out per screen from `desktopImageOptions(for:)`, as the Desktop does: fill when the options say nothing, fit, stretch and center. NSWorkspace never reports tile, so tile is reachable only through the debug override.
2. A dynamic picture that follows light and dark mode (`apple_desktop:apr`) uses the image for the current appearance. Ones that follow the time or the sun (`h24`, `solar`) and aerials change on their own, so they keep the real blur.
3. Off the main thread, with Core Graphics and a plain Gaussian rather than Core Image (which kept 5 MB and peaked 30 MB higher), it scales the picture to an eighth of the screen's pixels, blurs it by 30 pt and saturates it by 2.2 (light) or 2.4 (dark), the system backdrop's own filter values, in gamma-encoded sRGB as the window server does. No tint goes on top, because the live frost hides the material's tint layers too.
4. Each screen's picture sits in an opaque layer placed where that screen is relative to the window, so a window across two screens shows both. Moving or resizing the window only moves those layers.
5. It looks again only on notifications: the screen set or scale, the active Space, the appearance, Reduce Transparency, and the app becoming active, which is when a picture changed in System Settings shows up. An unchanged picture is never redrawn.

Only the desktop picture shows through, not the windows behind. Inactive windows and Reduce Transparency show the real material, which is a plain color then. The real blur (`WindowGlassBackdropView`, the material with its tint layers hidden) also takes over while the first picture renders, and whenever the picture is missing, unreadable, moving or in a folder macOS guards: Desktop, Documents, Downloads, the Trash, iCloud Drive, cloud storage, other apps' containers, photo libraries and anything under `/Volumes`. It checks the path and every link in it before opening anything, so it never causes a permission prompt. Debug builds take `CANDY_WALLPAPER=/path` and `CANDY_WALLPAPER_PLACEMENT` to test other pictures without touching the user's settings.

Measured on 2026-10-14 over the default picture at 1x, away from other windows: the blurred picture's average color is within 2.7/255 per channel of the live frost, and its luminance within 1.5%, in light and dark. Under the base tint the difference is under 1/255, so the contrast figures below hold. Inactive windows match the live material exactly. Against the live blur, with the Release builds, a thread open and the user's other windows animating behind: WindowServer idled at 85 ms/s of CPU instead of 326 to 344 and the GPU at 0.4% active instead of 11 to 12% (61 mW to 0), because the window no longer re-blurs whatever moves behind it. Scrolling the timeline cost the same (WindowServer 380 ms/s, GPU 14%). The app's idle footprint is unchanged and its launch peak 4 MB higher; decoding a HEIC picture leaves about 0.3 wakeups a second for under a minute.

| Level | What | Light | Dark |
|---|---|---|---|
| Base | Sidebar, main panel, right panel, settings pages | `--sidebar` or `--background` at `frostBaseAlpha` | the same |
| Pane | Cards, bubbles, the composer, selected rows, inputs, pills (`--card`, `--surface-raised`, `--toolbar-control`, `--sidebar-row-selected`, `--sidebar-row-active`) | the token, white, at 0.40 + 0.35 x opacity | the token, near black, at 0.35 + 0.40 x opacity |
| Dense | Code blocks, tables, the terminal (`--code-background`, `--terminal-background`) | 0.65 + 0.30 x opacity | 0.60 + 0.35 x opacity |
| Floating | Menus, popovers, tooltips, the command palette, dialogs, toasts (`--popover`) | 0.70 + 0.25 x opacity, over its own within-window blur | the same |

- `frostBaseAlpha` is 0.6 + 0.37 x opacity^1.5: 61% at 10, 69% at 40, 86% at the default 80 and 97% at 100. The floor keeps body text at 4.5:1 over a dark desktop in light mode and a bright one in dark mode.
- Light fills and lines T3 paints opaque a step off the background (`--accent`, `--muted`, `--secondary`, `--border`, `--input` and their sidebar twins) become the black or white overlay that paints the same color over the stock background, so a hover tints whatever pane it sits on. Dark already paints them as white overlays.
- A pane's edge is T3's border where it has one, else 1px of black at 7% (light) or white at 8% (dark). Its top highlight is 1px of white at 75% (light) or 7% (dark) just inside the top edge, clipped to the corners. `BoxStyle.pane` asks for both on a box without a border, and `GlassEdgeLayer` paints them on plain layers.
- Radius stays T3's: 8 to 10 on cards and rows, 18 on dialogs, 6 to 10 on buttons.
- Drop shadows cap at `0 2px 8px`, black at 8% (light) or 25% (dark). The composer's soft shadow goes.
- A floating pane gets a `BackdropBlurView` under it (`syncPaneBlur`), so sharp text behind it blurs away instead of showing through the tint. Only open popups, dialogs and toasts have one, so at most a few exist and none while idle.
- Text never relies on the frost: `frostReadable` moves each text color, in linear light so colored text keeps its hue, until it keeps 5:1 (text) or 3.3:1 (icons) against the worst base the slider allows, modeled as the base tint over a desktop at 10% gray (light) or 85% gray (dark). T3's faded muted text (`/70`, `/40`, the placeholder at 75%) paints at full strength.
- Motion is unchanged: fills and colors fade as T3's do, within 100 to 200 ms.

Measured over a busy striped and blocked backdrop, worst-case background next to the text, on 2026-10-14 (`/tmp` tooling, see the commit): body text 10.4:1 (light) and 6.8:1 (dark) at 10%, 13.1:1 and 13.6:1 at 80%. Muted text 6.5:1 and 5.0:1 at 10%, 5.5:1 and 4.8:1 at 80%. Icons 6.1:1 and 4.1:1 at 10%, 4.0:1 and 3.8:1 at 80%.

## Known gaps

- Pixel snapping assumes a 2x backing store, as on every Retina Mac. On a 1x screen (this Mac mini's virtual display) edges can be half a point off. Use the window's backing scale where the code says `ponytail: 2x`.
- Tooltips past their max width wrap with balanced lines; Core Text balancing can break a line differently from Chromium.
- Collapsibles animate through `CollapseMotion.run(in:)` (DesignSystem/Base/CollapseMotion.swift); `CollapsibleView` itself still jumps its siblings and is used only by the gallery. The color plane thumb skips its 80ms transition. The sidebar trigger swaps its icon instead of T3's path morph.
- Group is horizontal only. The joined outline toggle bar (one settings screen) is not built.
- Toasts lack the copy-error button and the loading spinner.
- 11 brand logos with gradients or masks, file-type icons and morphicons are not extracted yet.
- Code font: Menlo per Chromium's rendering on this machine. Verify on the real desktop app.
- File chips in markdown: clicks call `ThreadViewModel.openFile`, which the app does not set yet, so a click shows the chip's menu (copy relative or full path), as T3 does when it has no open action. No "copied" toast, no hover transition, no Open in editor or Reveal items yet.
- Markdown: the native highlighter approximates Shiki (82 to 100% of characters match per language on sample snippets; TS, JSON, YAML, TOML, HTML, diff, Markdown at 97% or more). Code block titles show the language label, not pierre's file-type icons. External links have no favicon. Tables never wrap or truncate cells and clip instead of scrolling; the expand toggle does nothing yet. Unwrapped code clips instead of scrolling. All lists render tight (Foundation does not report looseness). Images are the 16:9 loading slot.
- Diff panel: no file tree aside (the toggle only shows state), no line selection or review comments, no expanding of hidden lines (patches carry no file contents), no 200ms fade on expand, no title hover transition. Unwrapped lines share one horizontal offset across the list. Wrapping counts every character as one column, so wide CJK or emoji lines wrap later than Chromium.
