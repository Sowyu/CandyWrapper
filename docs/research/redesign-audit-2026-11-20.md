# Redesign audit, 2026-11-20

This audit looks at Redesign (Experimental), `candywrapper-dither`, surface by surface after the Nightly 4928 port, so the user can say what to change before anyone restyles it. It changes no app code. Images live in `~/CandyWrapper-research/sandbox/redesign-audit-2026-11-20/`, and every image name below is relative to that folder. The gallery is `index.html` in the same folder.

## How the images were made

- I built `catchup-4928` at 049215aa with `scripts/build-test-app redesign-audit`. The build failed at the known `App/Sources/ThreadSession.swift:279` region-isolation error, so I loaded the deferred work anchors one after another instead of in a task group. That is a local change in /tmp/cw-redesign-audit and is not committed.
- The app ran against the 4928 sandbox on 47392 with `--fake-t3-connect` and `CANDY_THEME=candywrapper-dither`. Light and dark came from Settings > Appearance > Color scheme. The Welcome page came from `--welcome`.
- This Mac's virtual screen is 1920x1080 at 1x, so `screencapture` gives 1x pixels. The brief asked for 2x, and that needs a HiDPI virtual display, which I did not set up. The 28 images in `baseline/` are the committed 2x Redesign baseline renders from `design/redesign-baseline/`.
- The sandbox holds three threads: Blue with an image, a 51-message thread with a shell command, a question, a context handoff and an interrupted run, and Say Four. It has no code blocks, tables, pending approval, pending question, burst, reply card, file card or diff. Those come from `baseline/` or are marked as not seen. I ran no real turns.
- I painted grey over this Mac's account name in the sidebar footer, the email in the model picker and the shell prompt in the terminal.
- The default dark captures (`default-dark-*`) show the same thread and composer as a comparison of structure, not as a target.

## Measured token inventory

I read these values from the code. `tokens/measure.py` collects literals on Redesign code paths: files named `*Dither*`, the bodies of `Dither*` types and `if <dither flag>` blocks, and the Redesign arm of `isDither ? a : b`. `tokens/inventory.json` lists every hit with file:line. Shared components that Redesign inherits unchanged are counted separately, because they render in Redesign too.

| Kind | Distinct in Redesign | Values and where |
|---|---|---|
| Corner radius | 9 named, plus computed nests | 8 control, 12 card, 16 panel and window (`SidebarView.swift:502-511`); 10 for Settings nav rows (`SettingsShellViews.swift:637`); 3 and 3.5 and 1.5 in the provider card and chips (`DitherProviderCard.swift:76,100`, `DitherProjectChips.swift:40`, `DitherDeviceRowView.swift:46`); 4 as the nest floor and full circles for the context button. `DitherChrome.nested` (`SidebarView.swift:540`) makes `outer - inset` values on top of these |
| Spacing | 13 literal steps | 1, 2, 4, 6, 8, 10, 28, 30, 32, 38, 48 in Redesign arms, plus 24 and 36 heights; `QuestionPanelView.swift:48-51,370-371,439` alone sets 4, 8, 24, 28, 30 and 38 for one card |
| Backdrop blur | 1 | 12pt `Tokens.LengthPx.glassBlur` (`Tokens.generated.swift:1016`) on all 11 `BackdropBlurView` sites |
| Shadow | 7 recipes | pill y2 r4 at 0.28 dark / 0.08 light (`DitherPillSurface.swift:37-41`); composer r14 or none (`ComposerView.swift:358,969-970`); glass popover y16 b40 -18 at 0.55 light and y18 b44 -18 at 0.8 dark (`PopupSurface.swift:37-38`); glass tooltip y20 b25 + y8 b10 at 0.25 (`PopupSurface.swift:40-41`); route modal y25 b50 -12 at 0.4 (`AppRouteModalView.swift:148`); toast y20 b25 + y8 b10 (`ToastView.swift:287`); settings card y1 b2 at 0.05 (`SettingsViews.swift:314`) |
| Surface fill opacity | 6 surface values, 3 hover fills | 0.62 pill and composer (`DitherPillSurface.swift:22`, `ComposerView.swift:961`), 0.86 settings card dark (`SettingsViews.swift:332`), 0.4 settings card light (`SettingsViews.swift:313`), 0.01 context strip tint (`ComposerContextStripView.swift:129`), 1 under Reduce Transparency; hovers 0.035, 0.055 and 0.08 (`ThreadDetailsCardView.swift:7,319`) and 0.04 and 0.065 in project chips (`DitherProjectChips.swift:408`) |
| Border opacity | 4 | 0.08 rim (`SidebarView.swift:544`); 0.07 dark context strip (`ComposerContextStripView.swift:124`); 0.05 dark neutral banner (`ComposerBannerStack.swift:317`); `contrastBorder` at 0.6 on settings cards (`SettingsViews.swift:312`) |
| Background scrim | 4 dark, 4 light, 1 veil | thread 0.35 (`ThemeRuntime.swift:79`), settings 0.8, page 0.92, hero 0; light floors 0.65, 0.77, 0.88, 0.92; chat veil 0.12 (`DitherArtView.swift:343-385`) |
| Font size | 6 in Redesign arms, 13 inherited | Redesign sets 12, 13, 14, 15, 16 and 22 (`SettingsViews.swift:119,419`, `SettingsShellViews.swift:741`, `DitherTabStripView.swift:249`). Shared views add 9, 10, 11, 18, 20, 24 and 30. `DSFont.ui` calls across the package: 9×1, 10×32, 11×105, 12×489, 13×41, 14×260, 15×4, 16×11, 18×2, 20×1, 22×1, 24×3, 30×3 |
| Motion | 2 own, 10 curves inherited | pills rise 4pt over 150 ms on (0.23, 1, 0.32, 1) (`DitherPillSurface.swift:46-62`); default controls use 150 ms on (0.4, 0, 0.2, 1). The package holds 10 distinct curves and 14 distinct durations from 0.1 to 0.9 s |

Redesign's own system is small and mostly sound: three radii, one blur, one rim, one pill height of 30 and gaps of 8 and 6. The trouble is everything around it. Shared components bring 51 distinct `BoxShadow` lines, 32 distinct white or black alpha literals and 13 font sizes. A few Redesign arms add one-off values that break its own scale, like the 10pt nav row radius beside 8pt controls.

## Surfaces

### Sidebar

Problems:

- The nav block, the "Threads" heading, the project header and the thread rows each sit on a different left inset and type size, so the column has four left edges (`dark-sidebar-rest.png`, `light-sidebar-rest.png`).
- The selected row is a filled 8pt card, hover is a lighter fill of the same shape, and the folder header has no state at all (`dark-sidebar-row-selected.png`, `dark-sidebar-row-hover.png`).
- The provider glyph on every row is grey at the same weight as the row's meta text and carries no information when every thread uses Claude (`dark-sidebar-rest.png`).
- The filter popup draws a teal underline under its search field, and the filter button keeps a teal focus ring after Escape (`dark-sidebar-filter-popup.png`, `dark-sidebar-filter-focusring.png`). Nothing else in Redesign uses the accent for focus this way.
- The thread menu has 15 rows with three dividers and mixes a checkmark ("Settle") with outline icons (`dark-sidebar-thread-menu.png`, `light-sidebar-thread-menu.png`).
- Right-clicking the project header opened nothing, so 4928's project menu with Pin project was not reachable here (`dark-sidebar-project-menu.png`).
- The account row puts CPU and memory figures under the name at 11pt with icons that read as clock and disk (`dark-account-menu-crop.png`). It is the only place the app shows its own resource use.

Good, keep:

- The flat sidebar with no art behind it gives the list a quiet, solid column, and light mode reads cleanly (`light-sidebar-rest.png`).
- Row title plus one meta line ("main · 12m") is easy to scan.

### New-thread page

Problems:

- The project pill, the composer and the machine pill are three separate surfaces with three heights, 30, about 84 and 30, and their left edges line up only by the 8pt pill inset (`dark-newthread-composer.png`).
- The placeholder is grey on a 62% glass over the art and is hard to read in dark (`dark-newthread-composer.png`).

Good, keep:

- The full-bleed art with no scrim on this page is the strongest moment in Redesign (`dark-newthread-window.png`, `light-narrow-newthread.png`).
- The glass composer reads as one object floating over the picture.

### Thread

Problems:

- The header pill floats over the timeline with nothing behind it, so a user bubble scrolls under it and is cut mid-word, as in "ask me: c" (`dark-thread-header-overlap.png`, `light-thread2-window.png`).
- Redesign shows no thread title or project anywhere on the thread page. The default theme shows "demo-repo / Current Directory File Count" in its header (`dark-thread2-window.png` against `default-dark-thread2-window.png`).
- Assistant text, the work log and tool rows sit straight on the art with only the 0.35 scrim and the 0.12 veil. User bubbles get a solid dark card. One speaker has a surface and the other does not (`dark-thread-window.png`).
- An opened command shows its syntax-coloured command and output on the art with no container, so the output "2" floats between rows (`dark-thread-command-output.png`, `light-thread-command-output.png`).
- Tables in the baseline render have no rules or fill and sit on the art; code blocks get a dark translucent card. Two pieces of structured content get two treatments (`baseline/thread-markdown-top.dark.png`).
- The handoff divider and "Run interrupted" use hairlines that disappear over the brighter parts of the picture (`dark-thread-handoff-row.png`, `dark-thread-interrupted-status.png`).
- The timeline keeps drawing under the composer and its pills, so "Hello. What would you like to work on?" shows through between the composer and the machine pill (`dark-composer-with-file-chip.png`).
- Light mode pushes the scrim to 0.77, so the picture becomes a faint wash and the theme looks like the default with a texture (`light-thread-window.png`).

Good, keep:

- The image bubble with the image above the text bubble reads well and keeps its 12pt corner (`dark-thread-media-bubble.png`).
- The thread details card uses the same frost and rim as the composer and sits well on the art (`dark-thread-details-card.png`).
- "Worked for 3.7s" folding into a single line keeps the timeline short (`dark-thread-bubble-and-worklog.png`).

### Composer

Problems:

- Beside the composer sit the machine pill, an 8pt rounded rectangle, and the context meter, a circle. These are two shapes for two small status controls in the same row (`dark-thread-composer-supervised.png`).
- The `/` menu is a long list of 13pt rows with grey descriptions that cut off at the right edge with an ellipsis (`dark-composer-slash-menu-crop.png`).
- The `@` menu opens as a short glass list above the composer, while the `/` menu covers the timeline. One job, two placements (`dark-composer-at-menu.png`, `dark-composer-slash-menu.png`).
- The file chip in the text is teal-tinted, the only accent-coloured inline element in the composer (`dark-composer-with-file-chip.png`).

Good, keep:

- Model and effort as one "Haiku 5.5 Low" trigger beside a single teal send button (`dark-thread-composer.png`).
- The approval card in the baseline puts Decline and Approve on the right of a one-line card (`baseline/composer-approval.dark.png`).

### Model picker

Problems:

- The docked picker is an opaque dark sheet, while every other floating surface in Redesign is 62% glass with a 12pt blur (`dark-composer-model-picker.png`).
- The picker shows three accents: a green status dot, a coral usage bar and the teal check, plus the Ultracode chip in grey (`dark-composer-model-picker.png`).

Good, keep:

- Two columns, models on the left and Reasoning on the right, with "Default" named in words (`light-composer-model-picker.png`).

### Right panel

Problems:

- The panel is a flat black or white slab that joins the window edge with square corners. Everything to its left floats on glass pills (`dark-right-panel.png`, `light-right-panel.png`).
- The terminal's prompt starts at the panel's left edge with no padding (`dark-right-panel-terminal.png`).
- The tabs carry close buttons that appear under the pointer, and clicking a tab near its right edge closed Diff and then asked to close Terminal 1 (`light-dialog-close-terminal-window.png`).
- The `...` menu lists "Publish repository" twice, once as an action and once with an ellipsis (`dark-header-more.png`).
- The diff toolbar packs eight toggles at one size with no grouping (`dark-right-panel-diff-toolbar.png`).

Good, keep:

- The side chat pane reuses the Redesign composer at the bottom, so the two chats look related (`dark-sidechat-composer.png`).
- The "Open a surface" list with letter shortcuts is clear (`dark-right-panel-empty.png`).

### Settings

Problems:

- At the default window size the modal covers the whole content area, so the art behind it shows only as a dark rim (`dark-settings-modal.png`).
- Settings cards use their own fill, 0.86 in dark and 0.4 in light, their own border at `contrastBorder` 0.6 and their own shadow, not the pill recipe (`SettingsViews.swift:312-332`).
- The nav rows use a 10pt corner beside 8pt controls (`SettingsShellViews.swift:637`, `dark-settings-nav.png`).
- The section headings are 15pt regular, the page title 22pt and row titles 13pt, which is three steps that don't fit the 12, 14, 16 scale the rest of the app uses (`dark-settings-general-rows.png`).
- The interface and mono font selects look disabled because they use the muted text color (`dark-settings-typography-code.png`).

Good, keep:

- One column of rows grouped into cards with a heading above each group (`dark-settings-general-rows.png`).
- The typography preview with a real diff and terminal sample (`dark-settings-typography-code.png`).

### Command palette, dialogs and toasts

Problems:

- The palette blurs and darkens the whole window, so the art disappears, and its panel is the opaque default sheet (`dark-command-palette.png`).
- The close-terminal dialog is the default alert with a red Confirm and an outlined Cancel, with no Redesign treatment (`light-dialog-close-terminal.png`).
- Toasts carry their own two-layer shadow (`ToastView.swift:287`, `baseline/toast.dark.png`).

Good, keep:

- The palette footer with ↑ ↓ Enter Esc hints (`dark-command-palette-crop.png`).

### Usage, Issues and pull requests

Problems:

- The Usage breadcrumb has uneven gaps around its second slash (`dark-usage-crop.png`).
- Usage draws hatched remainder bars in grey and coral for two providers, with a white tick for "now", and the coral appears nowhere else in Redesign (`dark-usage-crop.png`).
- Issues and Pull requests sit under the 0.92 page scrim, so the art is nearly gone, while threads use 0.35. Moving between them feels like changing apps (`dark-issues-page.png`, `dark-thread2-window.png`).
- The Issues toolbar buttons are default outlined buttons, not pills (`dark-issues-toolbar.png`).

Good, keep:

- The Issues empty state is two short lines with one icon (`dark-issues-page.png`).

### Welcome

Problems:

- Welcome renders on a flat background with no art, scrim or pills in either mode. It is the default page under a Redesign window (`dark-welcome.png`, `light-welcome.png`).
- "Ready" is a bright green that is not the teal accent, and the agent logo stack mixes outline glyphs with one filled tile (`dark-welcome-rows.png`).

Good, keep:

- Three rows, Agents, Projects and Phone, with one primary button (`light-welcome.png`).

## Structure that differs from the default theme

- Redesign drops the thread title and project breadcrumb from the header. The default keeps them (`dark-thread-header.png`, `default-dark-header.png`).
- Redesign moves Search, New thread, Pull requests, Issues, Automations and Settings into a nav list at the top of the sidebar. The default keeps search in a field and the rest as footer icons. The nav list is clearer, and it costs about 180pt of list height (`dark-sidebar-rest.png`, `default-dark-sidebar.png`).
- Redesign splits the composer's machine and context controls out of the composer into separate pills below it. The default keeps them inside (`dark-thread-composer.png`, `default-dark-composer.png`).
- Redesign draws the account with CPU and memory in the footer. The default has no account row.

## Principles for a cleaned-up Redesign

1. Use three radii, 8 for controls, 12 for cards and menus and 16 for the composer and modals, and remove the 10, 3.5 and 1.5 values.
2. Give every floating surface one recipe, 62% fill, 12pt blur, 0.08 rim and the pill shadow, including popovers, the docked picker, the palette, dialogs and toasts.
3. Put anything that holds text the user must read on a surface, both speakers' messages, tool output, tables and banners, or on a scrim strong enough for 4.5:1.
4. Keep the art the same strength on every route, so threads, Issues, Usage and Settings feel like one app.
5. Use the teal accent only for send, the primary action, focus and selection, and draw status in neutral colours.
6. Take type sizes from 11, 12, 14, 16 and 22 only.
7. Let content scroll under a header only when the header has a band behind it, or keep content below the pills.
8. Show the thread's title and project on the thread page.
9. Give every 4928 surface a Redesign pass before it ships, starting with Welcome, side chats, dialogs and the right panel.
10. Use one motion, the 150 ms pill rise on (0.23, 1, 0.32, 1), for everything Redesign opens.

## The fifteen changes that would help most

1. Put a band or fade behind the thread header pills so messages never run under them. Small, half a day.
2. Show the thread title and project in Redesign's header pill. Small, half a day.
3. Give assistant text, tool rows and command output a surface, or raise the chat veil until muted text keeps 4.5:1. Medium, one day with readability checks.
4. Make the right panel a floating 16pt glass panel with the pill rim, not a flat slab. Medium, one to two days.
5. Route the docked model picker, the command palette and dialogs through the pill recipe. Medium, one day.
6. Bring Welcome onto the art with pill rows and the teal accent for Ready. Medium, one day.
7. Cut the shadow recipes Redesign can reach from seven to two, pill and modal. Small, half a day plus a baseline re-record.
8. Use one scrim level for every route, or two at most, so Issues and Usage keep the picture. Small, half a day.
9. Fix the Settings nav radius to 8 and the Settings card fill and border to the pill recipe. Small, a few hours.
10. Set Settings type to 13 rows, 14 headings and 22 titles, or whatever scale principle 6 settles on. Small, a few hours.
11. Join the machine pill and the context meter into one status pill under the composer. Small, half a day.
12. Remove the teal focus ring and teal underline from the sidebar filter. Small, an hour.
13. Draw tables in chat on the same card as code blocks. Small, half a day.
14. Remove the duplicate "Publish repository" row from the thread menu and pad the terminal's left edge. Small, an hour each.
15. Trim the thread context menu to its most-used ten rows, with the rest under "More". Medium, one day with the user's choice of rows.

## 4928 features in Redesign

I marked each feature ported on 2026-11-19 and 2026-11-20 from what I saw on screen. Where the sandbox could not show it, the mark comes from whether its view has a Redesign branch (`grep -c isDither`), and the note says so.

| Feature | In Redesign | Note |
|---|---|---|
| Welcome page | clashes | flat default page, no art (`dark-welcome.png`); `WelcomePageView.swift` has 0 Redesign branches |
| Issues page | appears | Redesign nav row and page scrim; toolbar uses default buttons (`dark-issues-page.png`) |
| Side chats pane and tab | clashes | flat panel with default header; composer is Redesign's (`dark-right-panel-sidechat.png`); `SideChatPaneView.swift` has 0 branches |
| Side chats in the details card | appears | frost card over the art (`dark-thread-details-card.png`) |
| Docked model and effort picker | clashes | opaque sheet, not the glass recipe (`dark-composer-model-picker.png`) |
| Model and effort as one trigger | appears | "Haiku 5.5 Low" beside send (`dark-thread-composer.png`) |
| Message bursts | missing from sandbox | not seen; `TimelineMessageRows.swift` has 0 Redesign branches, so default styling |
| Images above the bubble | appears | (`dark-thread-media-bubble.png`) |
| File cards sent alone | missing from sandbox | not seen; `ThreadSentFileRowView.swift` has 0 branches |
| Reply cards and "Replying to" | missing from sandbox | not seen; no Redesign branch |
| `@` model chips | missing from sandbox | not seen |
| Insight callout and quote cards | missing from sandbox | not seen; no Redesign branch |
| Model or effort switch divider | missing from sandbox | not seen |
| Context handoff row | appears | hairline fades over bright art (`dark-thread-handoff-row.png`) |
| Answered questions row | appears | (`dark-thread2-window.png`) |
| Thread details card sections | appears | Side chats section seen; PRs, automations and lineage reached from the `...` menu |
| Pinned projects | missing | the project header has no context menu in Redesign, and the filter popup shows no pin column (`dark-sidebar-filter-popup.png`) |
| Two-line folder rows | missing | Labs switch for Boring folders; Redesign's project header stays one line |
| Settled undo row and reply age on rows | appears | "Settled (0)" and "main · 12m" (`dark-sidebar-rest.png`) |
| Settings new rows: Language, Voice, Thread details, auto-settle 7 days | appears | Voice in the nav (`dark-settings-nav.png`); baseline re-recorded for the others |
| Images popover in the header | appears | (`light-header-images-popover.png`) |
| Right panel `+` menu with Side chat and Device | clashes | default menu on the flat panel (`dark-right-panel-plus-menu.png`) |
| Diff toolbar, viewed files and test toggle | clashes | default toolbar on the flat panel (`dark-right-panel-diff-toolbar.png`) |
| Usage modal | appears | Redesign modal, coral and grey bars (`dark-usage.png`) |
| Close-terminal dialog | clashes | default alert (`light-dialog-close-terminal.png`) |

Counts: 11 appear, 6 clash with default styling, 2 are missing, and 6 could not be shown by the sandbox. All six have no Redesign branch in code, so they will render in default styling.
