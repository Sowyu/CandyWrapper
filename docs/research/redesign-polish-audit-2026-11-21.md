# Redesign polish audit, 2026-11-21

The user asked what else would make Redesign more premium, with Capy, Linear and Devin as the references. This audit covers three of the answers: one accent colour, one type scale and spacing grid, and plain sentence-case copy. It covers Redesign (`candywrapper-dither`) only. The default T3 themes and Glass keep every pixel, and every fix below is gated on `ThemeRuntime.isDither` or lives in the Redesign palette, unless the note says it is wording that means this app in every theme.

Pictures are in `~/CandyWrapper-research/sandbox/polish-audit-2026-11-21/`. The annotated "before" sheets come first (`1-accent-before.png`, `2-type-spacing-before.png`, `3-copy-before.png`), and their numbered callouts match the numbers below. Before and after pairs follow (`pair-*.png`). The "before" renders are the Redesign baseline images in `design/redesign-baseline/` at `ec8f0624`, the ring renders come from `ContextRingRenderTests` run on main and on this branch, and the on-screen captures come from the sandbox server on port 47392.

Each finding says fixed, left or next. "Left" means it is correct under the rule or it is T3's own wording in the same place. "Next" means it is too large for this branch and carries an estimate.

## 1. Accent colour

The rule as implemented: Redesign has one accent, the one the user picks in Settings > Redesign > Accent colour (`DitherAccent`). It fills the single primary action on a surface (the send button), selection (theme rings, switches, segmented and slider fills) and keyboard focus (`--ring`). Status uses a small fixed set from the palette, never the accent: success, warning, danger (`destructive`) and info. Everything else is the text colour at a few strengths.

`DitherAccent.colors(dark:)` is the one place the accent enters the palette. It now also owns the three `update` roles, so nothing in Redesign falls back to T3's blue. `RedesignTokenGuardTests.redesignDrawsOnlyFromTokens` now also fails on a hard-coded hue on a Redesign code path: any `#rrggbb` literal whose channels differ by more than 40 of 255, or a `.systemBlue`-style system hue, outside `ThemePalette.swift`, `DitherAccent.swift` and `CandyTheme3669.swift`. Greys pass. `scannerCatchesLiterals` proves that it catches a system purple and a teal hex on the Redesign arm, and that it ignores a grey and T3's blue on the stock arm.

1. Fixed. Settings > Appearance drew Redesign's theme circles and the colour-scheme previews from the palette's own teal, while the rings, sliders, switches and send button around them followed the chosen accent. With Violet picked, the page showed teal circles inside purple rings, which matches the user's too-grey-settings.png. `ThemeCardDefinition.init` (`Features/Settings/ThemeGalleryViews.swift:33`) now merges `ThemeRuntime.ditherAccent.colors`, and `ThemeGridContent` carries the accent id, so a new accent rebuilds the cards (`AppearanceSettingsView.swift:93`).
2. Fixed. Markdown links were T3's info blue (`Features/Markdown/MarkdownLayout.swift:69`). Under Redesign they now take the accent through a new `Themed.color(redesign:stock:)` (`DesignSystem/Theme/Colors.swift`). Every accent clears 4.5:1 on the dark ground. Violet is the lowest at 4.79:1. On a table card it is 4.41:1, which I list as a known edge.
3. Fixed. The `update`, `updateForeground` and `updateSurface` roles were inherited from T3's dark palette as #346bf1, #51a2ff and #121b34, so the model picker's "new" badge (`Features/Pickers/ModelPickerView.swift:1192-1194`) stayed blue under every accent. The fix is in `ThemePalette.capyDarkColors` and `capyLightColors`, plus `DitherAccent.colors`. I didn't touch the picker's file.
4. Fixed. The context popover's legend hard-coded gray, blue and teal (`Features/Thread/ThreadContextWindowMeterView.swift:334`), so the teal clashed with any other accent. The legend now uses three strengths of the text colour.
5. Fixed. The context ring turned red above 90% whatever the provider's "Compact at" said, with no warning step. It now uses the status set (see the context pill below).
6. Left, correct. The sidebar's status chips are status colours from the palette: Done in success, Input in info and Approval in warning. My suggestion for the user, not applied: draw "Done" in the muted text colour, since a finished thread is the normal state and three green chips in a row are the loudest thing in the sidebar.
7. Left, correct. The Markdown "Note" alert is info, a status.
8. Left, exempt. Syntax highlighting, the diff's additions and deletions, project monogram colours, provider brand colours in the handoff divider (`Thread/HandoffDividerView.swift:97`) and the Usage chart's series colours are content or identity, not emphasis.
9. Left. The Redesign switch reads `ThemeRuntime.ditherAccent.darkColor` directly in dark and `\.primary` in light (`DesignSystem/Components/SwitchView.swift:137`). Both resolve to the same accent, so nothing is visible, but the dark path skips the palette. Next: read `\.primary` in both, about 10 minutes plus a switch picture check.
10. Left. `BadgeView.labelColor` defaults to `.systemBlue` (`DesignSystem/Components/BadgeView.swift:29`). No caller uses the `label` variant without setting it, so nothing draws it today. Next: default it to `\.primary`, about 5 minutes.

## 2. Type and spacing

What Redesign draws today, counted over `Packages/CandyKit/Sources` and `App/Sources` (shared with the default themes, so these are calls, not Redesign-only):

| Size | `DSFont.ui` calls | Used for |
|---|---|---|
| 9, 10 | 2, 34 | badges, kbd chips, chart ticks |
| 11 | 96 | captions, popover notes |
| 12 | 486 | meta text, pill labels, row details |
| 13 | 38 | row titles, the thread title, tabs |
| 14 | 271 | body, Settings row titles, buttons |
| 15 | 1 | Redesign's Settings section titles (`DesignSystem/Components/SettingsViews.swift:430`) |
| 16, 18, 20, 22, 24, 30 | 11, 2, 1, 1, 3, 3 | dialog titles, Usage figures |

Weights in use are 400, 500 (260 calls), 600 (35) and 700 (3). Mono runs at 10 to 14. Line heights follow the size: 16 for 11 and 12, 18 for 13, 20 for 14, 24 for 15 and 16. Text opacity is the text colour at 1, muted (#aaaaab in dark), the Settings subheading's 0.7, and the placeholder.

The proposed scale has five sizes: 11 for captions, 12 for meta and pill labels, 13 for row titles, 14 for body, and 16 for section and page titles. Display figures such as the Usage total stay at 24 and up, as a separate step. Weights are 400 and 500 only. The grid is 4pt with 2, 6, 10 and 14 allowed inside a control, as `RedesignTokens.Space` already says. Pills are 30 tall.

1. Fixed. The terminal drew its text 4pt in from its pane, T3's `CONTENT_PADDING`. With the pane's own inset that put the prompt about 3pt from the card's edge, where code blocks and rows sit 8 or more in (`Features/Terminal/TerminalSurfaceView.swift:14`). Under Redesign the inset is now `RedesignTokens.Space.s`, 8, and the scrollbar follows it.
2. Fixed. The context pill now has a figure, and it uses tabular figures (`TL.tabular(12)`).
3. Fixed. Settings > Projects drew the thread count in proportional figures, so counts in the column didn't line up (`Features/Settings/SettingsProjectListView.swift:165`). It now uses `monospacedDigits`.
4. Left, already right. Most numbers that change in place were tabular already: sidebar thread ages (`SB.tabular`, `SidebarRowViews.swift:1145`), the working ticker (`DitherWorkingTicker.swift:86`), the Usage tables, totals and session counts (`UsageTableViews.swift:114`, `UsagePageView.swift:439`), and the context popover's figure and thread details usage.
5. Fixed. In Settings > About, the Mobile app row's iPhone and Android buttons were 32pt, and every other button in that card is the 28pt small button (`Features/Settings/NightlyMobileBetaView.swift:18`). Under Redesign they now take the small button's own height.
6. Fixed. Settings section headers came in two styles on one page. Appearance's "Color scheme" and "Themes" were 14pt at 0.7 (`SettingsSubheadingView`, `Features/Settings/SettingsPageKit.swift:558`), while "Interface", "Motion" and "Typography" below them were 15pt at full strength. Under Redesign the subheading now matches.
7. Next. The section title's 15pt is the only 15 in the app and sits off the scale. Move Redesign section titles and subheadings to 16 at 400. That is about 15 minutes, plus re-recording every Settings baseline, which waits for the Picture background change.
8. Next. Redesign's own doc says nothing is drawn at 600 or heavier, but 35 call sites ask for `.semibold`. In Redesign that shows on the Usage hero figure (`UsagePageView.swift:439`, 36pt), the SnapShots setup title (`SnapShotSetupView.swift:35`) and dialog titles. A cap in `DSFont.ui` under Redesign is the token-level fix. Fonts are made once per view, so it needs the views that cache a font to rebuild on a theme switch. That is about 1 to 2 hours, plus a full baseline review.
9. Left. The pill row above the composer is consistent at 30: Stash, the waiting pill, Scroll to end and the subagent pill all use `DitherPill.height`. The context pill was the one exception, a 30pt square with a 13pt ring. It keeps 30 and now grows in width to hold its figure.
10. Left, stale comment. The Stash pill's comment says "Redesign's 32pt pill: 13pt text" (`Features/Composer/Panels/ComposerStashViews.swift:74`), but the pill is 30 and its label is 12. Next: correct the comment, 2 minutes.

### The context pill

The user, 2026-11-21: "this is borderline unreadable lets be honest" (r4-context-ring-unreadable.png). It was a 13pt ring with a 1.5pt stroke, a track at 35% muted, no number, and red only above 90%.

Under Redesign it is now a 30pt pill like its neighbours. A 12pt ring sits in the Stash pill's icon column, followed by the share used as text, such as "95%", at 12pt in tabular figures (`ThreadContextWindowMeterView.swift`, `ThreadPanelView.swift:2005`). The track is the hairline rim token and the fill is the text colour at full strength. The stroke is 2pt with round caps, starting at 12 o'clock and running clockwise.

Colour follows `ThreadContextWindowUsage.level`, judged on the figure the pill shows. Danger is at or past "Compact at" (`autoCompactThreshold` over `maxTokens`) or from 95%. Warning covers the 10 points before "Compact at", or starts at 80% when no threshold is reported. Below that it is neutral. The ring and the figure both take `warning` or `destructive`, and the accent never appears here.

Nothing shows until the provider reports usage: no empty ring and no "0%". When there is no maximum, it shows the token count alone. Hover and pressed fills are the other pills' fills. The tooltip and the accessibility value both read "Context: 949K of 1M used (95%)". A value change eases over `RedesignTokens.Motion.appear`, 200ms, on the shared curve, and nothing runs at rest. The popover is unchanged, and still shows only figures the provider reported.

`ContextRingLevelTests` covers the threshold-to-colour mapping and the summary. The pictures are `ring-*.png` and `pair-ring-*.png`.

### Inline web frames

The user, 2026-11-21: "make it so html previews get rounded (same radius as the other ui elements) corners" (r4-html-preview-square-corners.png). An agent's HTML render was a square black slab among 8pt cards. MCP apps were worse: T3's `rounded-lg border` drew a rounded rim over square content, so the corners showed through.

11. Fixed. Under Redesign, `ThreadWebFrameView.roundsInRedesign` clips the frame's layer, and so the WKWebView and its cached preview image inside it, to `RedesignTokens.Radius.card` on a continuous corner (`Features/Thread/ThreadWebFrameView.swift`). The HTML render row and the MCP app row set it (`Features/Thread/TimelineWebRows.swift`). An MCP app clears it when it goes full screen and sets it again when it comes back. The expand dialog (`HtmlRenderDialogView`) and the Files panel's HTML file preview keep their own chrome. T3 draws the HTML render square (HtmlRenderFrame.tsx:87) and MCP apps square unless `prefersBorder` (McpAppFrame.tsx:464), so the default themes are unchanged. `HtmlFrameCornerTests` checks both themes.
12. Left. A Mermaid diagram sits in a transparent box with no visible frame (`MarkdownLayout.diagramBlock`, from MarkdownCodeBlock.tsx:223-232), so it has no corner to round.

## 3. Copy

1. Fixed, Redesign only. Settings > About's update button said "Check for Updates" and "Up to Date" (`Features/Updates/DesktopUpdateState.swift:241`). That is T3's wording (SettingsPanels.tsx:320-323), so the default themes keep it, and Redesign now says "Check for updates" and "Up to date". The macOS menu bar items "Check for Updates..." stay in title case, as the macOS menu convention and T3 both have them.
2. "T3 Code" where it means this app. An earlier count found 82 literals, and most correctly name T3's server, T3 Connect or the T3 app. Here is each decision in the files named:
   - `ConnectionDiagnosis.swift:124`, "T3 Code reconnects on its own": the client reconnects, so it now says CandyWrapper. Fixed.
   - `ConnectionDiagnosis.swift:130-131`, "T3 Code retries on its own": the same, fixed.
   - `ConnectionDiagnosis.swift:142`, "Restart T3 Code on this device." becomes "Restart CandyWrapper." Fixed.
   - `ConnectionDiagnosis.swift:238`, the copied diagnostics' first line, "T3 Code connection to": it is this app's report, fixed.
   - `ConnectionDiagnosis.swift` "T3 Code on \(host)": that is the server. Kept.
   - `GeneralSettingsView.swift:254`, notifications "while T3 Code is open" becomes CandyWrapper. Fixed.
   - `GeneralSettingsView.swift:581`, "the anonymous usage data T3 Code collects": T3's server collects it and the link is T3's policy. It now reads "How T3 handles your data, including the anonymous usage data the T3 Code server collects." Fixed.
   - `GeneralSettingsView.swift:586`, "tools used by T3 Code": the page lists CandyWrapper's bundled notices and the server's. It now reads "used by CandyWrapper and the T3 Code server." Fixed.
   - `DesktopManagedDialogs.swift:36, 108, 139`, the SSH prompt and the relay client install: this app runs the SSH process and installs the relay client, so they say CandyWrapper. Fixed.
   - `StorageSettingsView.swift:151, 186, 200`: these restart the server. Kept.
   - `WelcomePageView.swift:68`, "T3 Code collects anonymous usage data": the server does. Kept. Lines 401 and 907 name T3's phone app. Kept.
   - `ServerController.swift:172-488`: these name the T3 install and its server. Kept.
   - `SettingsHostAccess.swift:25-26`: these name the official T3 app. Kept. Line 196, "Turn off to use T3 Code only with remote environments", means this app, but `ConnectionsFidelityTests` pins that row against T3's reference, so I left it and list it here.
   - `BrowserController.swift:905`, "Open T3 Code in the desktop app": the toast only shows where the browser isn't available, and it is T3's wording. Kept. Next: say "This build has no in-app preview".
   - The browser tab "T3 Code (Beta)" is the `<title>` of T3's own page, shown as page content. Kept.
3. Left. "SnapShots" against "snapshots": T3 itself calls the feature "SnapShots" in the nav and section title (SnapShotSettings.tsx:368) and writes "snapshots" in prose ("Enable snapshots", "Animate snapshots"). CandyWrapper copies both in the same places. The feature is window capture into a draft, and "SnapShots" is T3's product name for it. Next, if the user wants it: "Snapshots" in Redesign's nav and section title, about 10 minutes.
4. Fixed in part. Tooltips on icon-only buttons: 20 files hold more icon-only `ButtonView`s than tooltips. Redesign's own tab strip had none on "+" or a tab's close button (`DesignSystem/Components/DitherTabStripView.swift:48, 242`). They now read "New thread in a new tab" and "Close tab". Neither action has a shortcut in the keymap, so the tooltips show none. Next, about 1 hour: the device panel (6 buttons, 0 tooltips), the browser panel (10, 4), the HTML render dialog (3, 0), the image preview (4, 1), the right panel (3, 1), diff rows (2, 0), the sidebar view (2, 0) and Scheduled tasks (2, 0). Each should name its action plus the shortcut from `ActiveKeymap.label(for:)` where one exists.
5. Left, already right. The errors I read say what failed and what to try. `ConnectionDiagnosis` gives a headline plus steps, licenses say "Could not load open-source licenses." plus the reason, and the project list's empty and no-match states give a title and a next step.
6. Fixed. Settings > Projects showed "0 threads" on a project with none. The count column is now empty there, and the accessibility label skips it (`SettingsProjectListView.swift:24`).
7. Fixed. Settings > Projects sorts pinned projects first but didn't show which were pinned, so the order looked wrong. A pinned row now shows the sidebar's 12pt pin before its count, and its accessibility label says "pinned".
8. Left, T3's. The sidebar's "Settled (0)" shows a zero count (`Features/Sidebar/SidebarListModel.swift:560`, from Sidebar.tsx:5457-5499).

## Findings for the picker agent

I didn't edit the model picker's files. On this branch:

1. The "new" badge (`ModelPickerView.swift:1192-1194`) reads `\.update`. Under Redesign that is now the user's accent. A badge is status, not selection, so consider the muted text colour on a hairline rim, since the accent already marks the selected model.
2. The effort labels are Title Case, "Extra High" (`PickersGallery.swift:16`, `ComposerCustomModelEditor.swift:208`). That is T3's wording. The segmented control in Redesign could say "Extra high".
3. The segmented control's selected segment is a 6pt corner in an 8pt track, which matches the tokens and the user's taste. Keep it.

## Not in this branch

- Re-recorded Redesign baselines. `RedesignBaselineTests` will differ on the Settings pages whose copy or headers changed (About, General, Appearance, Projects list) and anywhere a link or the context pill shows. Another agent is about to change every baseline image for the new Picture background, so I didn't commit new images. Record them after that lands, with `CANDY_RECORD_REDESIGN_BASELINE=1 scripts/test --filter RedesignBaselineTests`.
- Type scale and weight cap, sections 2.7 and 2.8.
- The tooltip sweep, section 3.4.
