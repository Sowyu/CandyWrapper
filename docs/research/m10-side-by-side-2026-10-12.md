# Milestone 10 side by side, 2026-10-12

T3 Code (Nightly) 0.0.46-nightly.20261009.2861 against CandyWrapper (this branch, Debug, bundle id `dev.candywrapper.test.sbs`), both at 410,86 1100x780 points, dark theme, default client settings.

The official app ran from `../CandyWrapper-research/apps/T3 Code (Nightly).app` through `/tmp/cw-sbs-tools/measure-launch` with `T3CODE_HOME=../CandyWrapper-research/sbs-m10-official`, a copy of the sandbox home (`statev2.sqlite` copied with `sqlite3 .backup`). Its bundled server answered on 3773 with that home, checked with `ps eww`. CandyWrapper ran against the sandbox server on 47391 with `--fake-t3-connect`.

The screen was 1920x1080 at 1x on this day, not the 2x CLAUDE.md describes. Every pixel number below is 1x.

Screenshots are in `/tmp/cw-sbs-m10/shots/` (`*-off.png` official, `*-cw.png` CandyWrapper). They are scratch files and are not committed. "Ink" is the mean channel value of a crop of text on the dark background, so more ink means heavier glyphs.

## Fixed

| # | Difference | Screenshots | T3 source | Fix |
|---|---|---|---|---|
| 1 | Typed prompt text was visibly bolder: ink 49.9 against 39.2 on the same line. Core Text smoothing (stem darkening) was on; T3 draws grayscale antialiased text. After: 40.1 against 39.2, same advance widths, aligned to the pixel. | `line-*`, `line2-*` | `appearanceFonts.ts:129-130` sets `-webkit-font-smoothing: antialiased` when `fontSmoothing` is on, the default (`packages/contracts/src/settings.ts:403`) | `ComposerEditor` draws through `GrayscaleTextLayoutFragment` with smoothing off |
| 2 | The same weight gap app-wide: header title 49.4 against 38.9, user bubble 54.4 against 44.2, timeline 17.4 against 15.7, sidebar about 12% heavier. CandyWrapper mapped T3's `fontSmoothing` the wrong way round: on meant Core Text smoothing on, the heavy look. After: 39.4/38.9, 44.25/44.22, 15.66/15.66. | `hdr-*`, `hdr2-*`, `bubble-*`, `bubble2-*`, `worked-*`, `worked2-*` | same | `SettingsFontRuntime` sets `FontRuntime.smoothing = !fontSmoothing`; the 12 drawing sites that forced smoothing on now read `FontRuntime.smoothing`. Offscreen renders and the fidelity suite keep the default (smoothing on, which is what the Chromium references were rendered with) |
| 3 | Selection color #3f638b against #355272, and the text under it 1 step lighter | `sel-*`, `sel2-*` | the editor has no `::selection` rule (`ComposerPromptEditorTiptap.tsx:999`), so Chromium blends the system color at 80% | `selectedTextAttributes` background `selectedTextBackgroundColor` at 0.8. Now #365272 |
| 4 | Placeholder 1px lower than the typed text and softer, because LabelView rounded its baseline for a 2x backing store on a 1x screen | `ph-*`, `ph2-*` | Blink lays out in device pixels | LabelView and TextBlock round baselines with the drawing context's own scale (2x renders unchanged). Placeholder columns now match pixel for pixel |
| 5 | Placeholder truncated with an ellipsis when the composer is narrow ("Ask anything, @tag files/folders,..."); T3 wraps it to two lines | `diff-both.png`, `p2-cw.png` | `ComposerPromptEditorTiptap.tsx:1791-1798` (`absolute inset-0`, wrapping) | placeholder is a TextBlockView that wraps in the full composer and stays one line in the resting row |
| 6 | Main panel had grain (mean 13.1 against flat #0a0a0a); the composer showed #111111 against #101010 because of it | `mainbg-*`, `win-*`, `win2-cw.png` | every main route covers the inset's grain with flat `bg-background`: `ChatView.tsx:11246`, `routes/settings.tsx:122`, `routes/_chat.index.tsx:128` | `layout.main.showsGrain = false` in AppDelegate. Background, composer and card colors now equal |
| 7 | Traits picker read "Medium · Standard" for GPT-6-Astra; T3 reads "Medium" | `picker-*` | `TraitsPicker.tsx:506-527`: Codex's `serviceTier` folds into the speed and the standard tier adds no label | `ModelTraits.triggerLabel(provider:)`, with a test |
| 8 | Thread hover card said "This device" with a server icon; T3 says the host name ("miniko") with the Mac mini icon | `imgthread-*`, `thr-*` | `Sidebar.tsx:2503-2509` uses `environment.label`, which is the descriptor's label (`environments/primary/context.ts:30`) | `Environments.setPrimaryDescriptor`, called by ServerController and the `--server` path (which set the label but never published it) |
| 9 | Thread hover card 2px higher than T3's | `thr3-*` (card top 266 against 268) | `Sidebar.tsx:466`, `side="right" align="start"`, anchored to the visible card | anchored to the card row's surface, not its 2pt top margin |
| 10 | Times read "07:25" and "09:19" where T3 reads "7:25 AM" and "9:19 AM" (work log header, snooze menu) | `worklog-*`, `snz-*`, `snz2-*` | Electron's `app.getSystemLocale()` (`ElectronApp.ts:132`) feeds `timestampFormat.ts:31-50`; it drops this Mac's `en_US@rg=frzzzz` region override | `TimestampFormat.t3Locale` (the locale without `@` keywords) for timeline times and snooze presets |
| 11 | The snooze menu opened at the sidebar's left edge (x 5) where T3 opens it under the clock button (x 140) | `snz-*`, `snz2-*` | `Sidebar.tsx:608` (`side="bottom" align="end"`); base-ui's `collisionAvoidance.align` defaults to "flip" (`flip` with `crossAxis: 'alignment'`, in the shipped `utils-*.js`) | `PopupPositioner.place` tries the other alignment before shifting, with a test. This applies to every start or end aligned popup |

## Left, with size guesses

| # | Difference | Screenshots | T3 source | Size |
|---|---|---|---|---|
| A | Caret: T3's is 1px wide and blinks hard on and off; ours is the system NSTextInsertionIndicator, about 2px and fading. I tried AppKit's legacy drawn caret (1px, hard blink, pixel-identical to T3), but it cost 2.25 interrupt wakeups a second at idle with the composer focused, against 0.03 today, so I reverted it. A layer caret with a discrete Core Animation blink would match without waking the app. | `caret-strip-*`, `caret3-strip-cw.png`, `caret-cmp.png` | Chromium's caret | half a day |
| B | Selection band covers the glyph height (17px) instead of the 22.75px line box | `sel-*` | Chromium highlights the line box | half a day: draw the selection with CSS line boxes in `drawBackground` (chips, code blocks and headings change line heights) |
| C | A finished subagent shows as a generic row ("Subagent "Count files via ls" finished") instead of T3's subagent card with "Finished", the result and the time | `sub-c.png`, `sub-cw-final.png`, `sub-off-exp.png` | `MessagesTimeline.tsx:5362-5381` (`SimpleWorkEntryRow`), `V2LifecycleRow.tsx:355-398` | `SubagentCardPresentation.notificationCard` exists but fell back here; needs the recorded projection to see whether `notificationChild` or the subagent record lookup failed. 2 to 4 hours |
| D | "Worked for 3.2s" headers missing over two short turns in CandyWrapper. The model's output differed between the apps, so this needs a recorded transcript replayed into both before calling it a bug | `sub-c.png`, `sub-cw-final.png` | `deriveTurnFolds`, MessagesTimeline.tsx | unknown until replayed |
| E | Header title and other single-line labels about 2px wider over 360px of text (Core Text advances against Blink's) | `hdr2-cmp.png` | none, text shaping | known gap (design.md), large |
| F | User bubble text 1px lower than T3's at 1x; markdown and timeline layout still round for 2x | `bubble2-*` | Blink device-pixel layout | 1 to 2 hours: pass the backing scale into MarkdownLayout and `TimelineRowSupport.snap` |
| G | The surface launcher's Browser row lacks T3's profile chevron when more than one browser profile exists | `diff-both.png` | `RightPanelTabs.tsx:530-555` | 1 hour |
| H | Composer model pill truncates one character earlier ("Claud..." against "Claude ...") in the narrow composer | `diff-both.png` | `ProviderModelPicker.tsx` | small, text measuring |
| I | After an approval resolves T3 stays where it was and shows "Scroll to end"; CandyWrapper follows to the end | `dec3.png` | ChatView scroll anchoring | 1 hour to confirm which is intended |
| J | The thread hover card's fill is #101010 against T3's #111111 | `thr3-*` | `dropdown-glass` | tiny |

## Not compared

Stash and restore with an image, switching threads mid-stream and the context meter were not driven: other agents held the front of the shared screen for long stretches, and CandyWrapper's stash lives in `~/Library/Application Support/CandyWrapper/PromptStash`, which every build shares with the user's demo app whatever its bundle id (`ComposerController.supportDirectory`, `ComposerController.swift:2608`), so a stash test would write to the user's own stash. The context meter showed in neither app on these threads.

## Side notes

- Something on the shared screen leaves the Command modifier down in the HID state (`CGEventSource.flagsState` reported 0x100000 twice), which turns clicks into multi-select. `/tmp/cw-sbs-m10/cmdup` posts a Command key-up.
- A second `xcodebuild` into the same derived data fails in the Trim Sparkle script ("bundle format unrecognized"): the script runs before the framework copy finishes. Deleting the built app first works.
- Real turns used: 3 in each app, all `claude-haiku-5-5`.
