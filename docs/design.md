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
| Sidebar grain (index.css) | SidebarGrain | crop vs real capture | mean 248.79 vs 248.78 light, 3.26 vs 3.29 dark |
| command.tsx | CommandPaletteView | 8 | 0.99% (items) |
| color-picker.tsx | ColorPickerView | 8 | 1.17% (hue slider) |
| calendar.tsx | CalendarView | gallery only | |
| Wrapped text | TextBlockView | 16 | 7.53% (line breaks identical; glyph antialiasing) |
| ChatMarkdown.tsx, `.chat-markdown` (index.css) | MarkdownView (Features/Markdown) | 12 | 1.37%: text 1.72/2.07, lists 1.35/1.71, quotes 1.10/1.21, table 0.94/1.35, code 2.64/1.97, rule and image 0.16/0.25 (light/dark). Spec `scripts/gen-markdown-spec.py`, code colored by T3's own Shiki in the page |
| DiffPanel.tsx, @pierre/diffs with StyledDiffCodeView.tsx CSS | DiffPanelView, DiffListView (Features/Diff) | 18 + 4 | body 2.42% against pierre itself rendering each patch in Chromium (spec `scripts/gen-diff-spec.py`; wrapped text cases 4-5%); panel against 09 and 10 5.1% light, 5.5% dark (glyph antialiasing over 23 rows of file names) |

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
| `NightlySkyArt` behind the sidebar header on Nightly servers | The teddy-and-milk corner of "Candy Town" by Aya_Lu ([Pixabay](https://pixabay.com/illustrations/candy-town-city-buildings-8579300/), Pixabay Content License) as a duotone: #2a1240 to #ffc4df under a plum #3a1a52 title and toggle in dark mode, #22103a to #dc8fbd under a white title and toggle in light mode. Chosen 2026-10-10. `scripts/gen-candy-art.swift` bakes the 8-bit luma from the 1280px public download; the app maps it and paints the duotone | `StageBackdropView`, `SidebarBrandView`, `SidebarTriggerView.mediaTint` |
| `StageBackdropButtonArt`: the Nightly sky in the send button | The teddy from the same art, a circle of 196 source pixels with both ears in and its face above the arrow. The duotone follows the sidebar (light art in dark mode, deeper art in light mode); the arrow stays white with a soft plum halo. Chosen 2026-10-10 | `StageBackdropView.compact`, `ComposerPrimaryButton` |

## Known gaps

- Pixel snapping assumes a 2x backing store, as on every Retina Mac. On a 1x screen (this Mac mini's virtual display) edges can be half a point off. Use the window's backing scale where the code says `ponytail: 2x`.
- Tooltips are single-line, truncated at max width.
- Collapsible siblings jump instead of sliding. The switch thumb stretch skips T3's radius change. The color plane thumb skips its 80ms transition. The sidebar trigger swaps its icon instead of T3's path morph.
- Group is horizontal only. The joined outline toggle bar (one settings screen) is not built.
- Toasts lack the copy-error button and the loading spinner.
- 11 brand logos with gradients or masks, file-type icons and morphicons are not extracted yet.
- Code font: Menlo per Chromium's rendering on this machine. Verify on the real desktop app.
- Markdown: the native highlighter approximates Shiki (82 to 100% of characters match per language on sample snippets; TS, JSON, YAML, TOML, HTML, diff, Markdown at 97% or more). Code block titles show the language label, not pierre's file-type icons. External links have no favicon. Tables never wrap or truncate cells and clip instead of scrolling; the expand toggle does nothing yet. Unwrapped code clips instead of scrolling. All lists render tight (Foundation does not report looseness). Images are the 16:9 loading slot.
- Diff panel: no file tree aside (the toggle only shows state), no line selection or review comments, no expanding of hidden lines (patches carry no file contents), no 200ms fade on expand, no title hover transition. Unwrapped lines share one horizontal offset across the list. Wrapping counts every character as one column, so wide CJK or emoji lines wrap later than Chromium.
