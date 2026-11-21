# Plan for 1.17.0

Written on 2026-11-21, right after v1.16.0 (build 85, commit `9522729b`). Nothing here is started. The user said: "dont start 1.17.0 yet but write down everything that ought to come out in 1.17.0 so another agent with 0 context can easily pick it up and start building". Wait for the user to say go.

Read `AGENTS.md` first. It has the rules, the commands and how to check work on screen. This file only lists what to build and what was already decided.

## How the last two days worked

One session orchestrated up to five agents at a time. Each agent took one task in its own worktree and branch, built it, checked it in a real window and reported. The orchestrator merged each branch into local `main`, ran `scripts/check-app-build` and the tests, looked at the pictures, and showed them to the user. Keep that shape.

- Start agents with T3 Code's `delegate_task` and `isolation: "worktree"`, model `claude-opus-5-5` at effort `medium`. Use `high` only for work that touches every surface. Every brief says "Do not start other agents".
- Each agent sets up with `scripts/warm-worktree <task>` and frees the slot with `--done`. The warm slots, the background UI tools and `scripts/test --mine` are described in `AGENTS.md`. They were built on 2026-11-21 and no full round of agents has used them yet, so expect rough edges.
- The Mac's processor is the limit. Five agents building at once put the load near 60 and made one timing test fail. Four builders is a better number. Picture-only and research agents cost almost nothing.
- Two agents that edit the same file must run one after the other, or the second rebases over the first. The crowded files are `DitherArtView.swift`, `ThreadPanelView.swift`, `RedesignSettingsView.swift`, `RedesignTokens.swift`, `ThemePalette.swift`, `AppRouteModalView.swift` and `RedesignBaselineTests.swift` (its image count line conflicts on every merge).

## What the user wants from Redesign

Redesign is the theme `candywrapper-dither`. The user runs it every day. The default T3 themes must keep matching T3 pixel for pixel, and the fidelity tests pin that.

The user's own words and pictures, in order, are in `~/CandyWrapper-research/sandbox/redesign-user-notes/README.txt`, with every picture they sent beside it. Read all of it before any Redesign task. Some pictures show the user's real thread and project names, so never commit them or reuse them in a report.

The rules that came out of it are in `docs/research/redesign-system.md`:

- Capy (capy.ai), Linear and Devin are the bar for "premium".
- No blurred translucent surfaces. Every surface is solid with a hairline rim.
- One corner radius: 8pt for surfaces, 6pt for what sits inside one. Tokens only, and `RedesignTokenGuardTests` enforces it.
- One accent color, used for the primary action, selection and focus. Status colors are a separate small set.
- Tabler icons. One set of motion timings in `RedesignTokens.Motion`.
- Dither is a deliberate texture: the whole image in one or two inks on a fixed grid, never dots sprinkled over a photo. The picture background does not move. The user called a drifting photo "horrid".
- Floating controls always have a solid background. Two bugs shipped from forgetting this.
- Text must stay readable over any background: body text at 7:1 or better, muted at 4.5:1. In 1.16.0 the Flower background hides on a thread unless the window has a clear margin. The user first agreed to that, then asked for the flower to be a real background (item 6 below).

## How the user wants to be shown work

- Pictures before code for anything about taste. Twice an agent built a look the user then rejected (a cramped picker pane, a "shelf" for the sidebar). Mock it first, as an HTML page rendered in the thread or as PNG sheets, and let the user pick.
- Offer a few options and say which one you would choose.
- Their app shows images in a reply but not video, and not images inside an HTML file. Send motion as a frame strip PNG, or upload the clip with `filedrop` and give the link.
- Send full-resolution pictures.
- Do not predict how long things take. The user said "your not good at it".
- Plain words. Explain any term a non-engineer would not know.

## Work for 1.17.0

Suggested order. Items 1 to 8 need no answer from the user.

### 1. Video and GIFs in replies

A reply with a video path shows "Image unavailable" today. T3 plays videos.

The work is half done on branch `image-speed-2`, commit `6375f0ba`, worktree `/tmp/cw-image-speed-2`. `/tmp` may be gone after a reboot, but the branch is in the repo. It was written against an older `main`, so rebase it first. It adds T3's 16:9 frame, a first-frame poster and a play button, then AVKit inline, muted, released when off screen. Animated GIFs play only while on screen, and Reduce Motion shows a play button. None of it has been checked on screen.

Part 1 of that work is released: the disk cache and loading order in `Features/Markdown/MediaTransfer.swift`, `MediaFetchQueue.swift` and `MarkdownMedia.swift`.

Also wanted here:

- A setting for the image cache size. It is fixed at 500 MB.
- Check that the progress bar shows on a slow link. Launch with `CANDY_SLOW_LINK=<rtt ms>:<Mbit/s>` in a Debug build. The release walk could not see it because images loaded too fast.

### 2. Remove the Glass theme

The user: "delete this glass theme too". Glass is CandyWrapper's own theme. About 109 source files mention it.

- Remove the theme, its materials (`WindowGlass`, the glass variants of surfaces) and the "Glass opacity" settings if nothing else needs them. That setting caused the Scroll to end bug, because a button filled at the user's 10% opacity with no blur under it.
- A user who has Glass selected falls back to the default T3 Code theme and sees a one-time note saying why.
- Remove its baselines and tests. Default-theme fidelity must not move.

### 3. Redesign settings audit

The user: "we gotta make the redesign feel more integrated instead of hastily put in". Redesign replaced several T3 surfaces, but Settings still describes the old ones.

- Settings > Appearance > Interface > "Thread details" says "Choose what the thread details card shows. You can also right-click the card." Redesign has no card. The header pill replaced it, and `ThreadDetailsCardView.swift` keeps only pull requests, automations and lineage in the pill's "..." menu. So about nine of the twelve checkboxes do nothing. Rename it "Header pill" under Redesign and make the checklist choose what the pill and its menu show.
- Go through every setting, menu item, tooltip, shortcut and command palette entry that names a T3 surface Redesign replaced. For each one: make it work, reword it, or hide it while Redesign is on.
- After a settings search jump, the nav keeps General highlighted even when another page is showing. Found by the release walk, not checked against 1.15.2.
- Onboarding and welcome cards were never checked for the 8pt radius.

Do this after item 2, because both touch the same Settings and theme files.

### 4. Leftovers from the 1.16.0 release walk

The full report is `~/CandyWrapper-research/sandbox/relcheck-1.16.0/REPORT.md`, with screenshots beside it.

- The gallery tile's hover caption is hard to read over light pictures. It needs a stronger scrim.
- The model picker shows an empty Favourites tab and an OpenAI tab that says nothing when it has no models.
- The Flower hides behind the "Title kept" toast.
- The Switch to Stable error says "Could not check" twice in one message.
- Holding ⌘⇧ should hide a tooltip so screenshots do not catch it. Built, never verified, because the key tool cannot hold modifiers.
- Blur, Gradient and Flower were not walked in Redesign light.
- The Flower page uses 126 MB against 57 MB for a thread in light. That is the pre-drawn bloom and idle frames. Find out why it is more than the 5 MB the agent reported and bring it down.
- Trackpad haptics, first feedback from the user, about the message rail: "scrolling through this doesnt feel like subtly dialing something its a bit strong and clicking should have no effect lol". Fix both:
  - Too strong. `ThreadMinimapView.swift:175` fires `Haptics.tap(.alignment)` each time the hovered message changes, capped at 12 a second (`Haptics.minimumInterval`). `NSHapticFeedbackManager` has no strength setting, only three patterns (`.generic`, `.alignment`, `.levelChange`), so make it feel lighter another way: try `.generic`, a lower cap (about 5 or 6 a second), a tick only every few messages on a long thread, or a tick only while the pointer moves slowly. The user has to feel each one, so build a Debug switch that cycles the variants and ask them to pick.
  - A click on the rail must give no haptic. The click itself is the feedback. Check every other call site for the same thing (`HapticsCallSiteTests` lists them): a haptic belongs to a snap, a detent or a drop, never to a plain click.
  - The other haptics (dividers, zoom stops, drags, sliders) have still not been felt. Ask the user about each after the rail is right. Segmented controls such as Reasoning have none, because they change only by a plain click.
- `MarkdownBackgroundLayoutTests.viewLaysOutInBackground(modern: false)` fails when it runs beside `ModelPickerShrinkTests`, because the picker test sets the theme globally. It is not in the fast lane.

### 5. Settled without project groups

In 1.16.0 the sidebar's Settled section groups threads under project headers. The user asked for that on 2026-11-21, used it, and then said: "remove group by project bc its dumb". With one or two settled threads per project, every thread gets its own header and the list doubles in height. Their picture is `~/CandyWrapper-research/sandbox/redesign-user-notes/r7-settled-grouped-by-project.png`.

- Remove the project headers inside Settled (`SidebarListModel.swift`, `SidebarListView.swift`, `SidebarSettledRange.swift`, tests in `SidebarSettledTests`). The list is flat again, newest settled first.
- Keep the rest of that work: the regular two-line row, the "settled 3h ago" line, the "when" picker and its empty state, paging with "Load older".
- A flat list loses the project name. Show it on the row instead: the project's avatar at the row's left, or the project name in the second line ("portfolio · anikodev.org · settled 3h ago"). Mock both and let the user pick.
- Redesign only. The default themes keep T3's Settled section.

### 6. The Flower as a background, not a prop

The user, after using 1.16.0: "the lotus flower needs to be a big peice of the background not just chilling on the corner it needs to be a background not a fancy prop".

Today (`DitherArtView.swift`, `LotusArt.swift`, placement tested in `LotusPlacementTests`): on the new-thread page the flower is centred above the composer and capped at a 288pt radius. On a thread it is a small flower in the right margin, at most 150pt, and it hides when there is no margin, which is most window sizes. Pictures: `~/CandyWrapper-research/sandbox/lotus-wire-2026-11-21/00-placement-four-sizes-dark.png`.

What to build:

- The flower fills the content area like a picture would. It is large, it can run off the edges, and the composer, the pills and the conversation sit on top of it. It shows on a thread at every window size.
- Text still has to read. Behind the reading column, thin and dim the dots the way Picture does (`PictureInk.textBound`, the column rule), or give the column a plain ground if item 9 is a yes. Measure the worst cell.
- Keep the bloom on opening a thread and the slow idle turn, the stop conditions, the "Animate background" switch and Reduce Motion.
- A larger flower means larger frames. The release walk already measured 126 MB on the Flower page (item 4). Render at a coarser cell size or fewer frames, and report the footprint. Idle cost with motion stopped must stay at zero.
- Mock it first: three or four compositions (centred and oversized, low and cropped by the bottom edge, off to one side, a top-down view) on the new-thread page and on a thread, dark and light, as PNG sheets. The user picks before anything is wired in. The standalone renderer tools are in `~/CandyWrapper-research/sandbox/lotus-2026-11-21/tools/`.

### 7. Picture dither: dark photos and dot size

The user's own wallpaper looks bad in 1.16.0. It is a night photo of three street lamps in fog: almost all black, with bright lamp heads and soft cones of light. Dithered, the whole window is covered in scattered single dots and the lamps are lost. Their words: "wait my one aint look that good??? this is the og photo". Both pictures are in `~/CandyWrapper-research/sandbox/redesign-user-notes/` as `r7-user-wallpaper-streetlamps-original.png` and `-dithered.png`.

Why, in `PictureInk.swift`: the tone map stretches levels from the 1st to the 99th percentile, then lifts any dark picture with a gamma until its median reaches `medianFloor` 0.34 (`lift(median:)`, line 119). That lift was added so dark landscapes did not come out empty. On a photo that is meant to be black it turns sensor noise and faint fog into dots everywhere, and the 3pt grid cannot hold the thin lamp heads.

What to build, with this photo as the test case next to the five from the mockups:

- Tell a low-key photo from an underexposed one. If most of the frame is near black and a small part is bright (look at the histogram: a tall spike at the bottom, a small highlight tail), do not lift the median. Leave black as black.
- A black point: tones under a small threshold draw no dots at all, so noise cannot speckle the ground.
- Smooth before thresholding (a small blur at about the cell size) so grain does not flip single cells, while keeping edges of bright shapes.
- Keep small bright shapes: the lamp heads should come out as solid light-ink cells and the cones of light as a dither gradient that fades into black.
- Consider one user control in Settings > Redesign beside Ink, only if the automatic choice cannot serve both kinds of photo: "Detail" or "Brightness", with Auto as the default. The old "Background dim" row is inert in Picture today.
- The agent that collected wallpapers on 2026-11-21 wrote down which photos dither well (`~/CandyWrapper-research/sandbox/wallpapers-2026-11-21/`). Use its rejects as more test cases.
- Mock the before and after on the user's photo first and show them.

Dot size, same file. The user tried a bright, detailed photo too (a Tokyo Bay skyline, `r7-user-wallpaper-tokyo-bay-original.png` and `-dithered.png` in the notes folder): "even bright photos looks a bit eh on my laptop i feel like the pixels might be a bit big". They are right. Picture uses 3pt cells, chosen to match Capy's gradient. On a 2x laptop screen that is 6 pixels a dot, and a skyline turns into blocks. 1.15.2 used 2pt dots.

- Try 2pt and 1.5pt cells (3 pixels at 2x) on that photo and on the five mockup photos, on a 2x and a 1x screen. Smaller cells keep detail; too small and it stops reading as dither. Show 1.5, 2 and 3 side by side on the user's two photos and let them pick.
- Offer it as a setting beside Ink, "Dot size": Fine, Medium, Coarse, if one size cannot suit both a skyline and a statue. Check the cached image's size and the render time at the finer sizes (about 2.25 times the cells at 2pt, 4 times at 1.5pt).
- Gradient and Flower keep their own 3pt grid unless the user asks.
- In the same screenshot the conversation text sits on busy mid-tone dots and is hard to read, even though it passes the measured contrast floor. That is the case for item 9, the clean reading column. Show the user that screenshot when asking.

### 8. Thin scrollbars and one focus ring

Approved by the user as part of "what else can make this app more premium". Thin overlay scrollbars everywhere in Redesign and one focus ring style. Small.

### 9. Clean reading column in dark. Ask first.

In Redesign dark with a Picture background, conversation text sits on a thinned dither. It measures 10:1 but reads busy. Light mode already has a plain column with the picture only in the margins (`PictureInk`, `lightColumnIsClean`). The orchestrator recommended the same for dark. **The user has not answered.** Ask before building.

### 10. Inset card layout for threads. Ask first.

The largest job. The thread becomes a bordered card with its tab row inside it, like Capy, behind a switch in Settings > Redesign.

- The user saw the mock (`~/CandyWrapper-research/sandbox/redesign-user-notes/inset-card-mock.html`) and said "as yes thats what i was thinking about indeed" and "also make it a toggle".
- **Two answers are still owed:** do Diff and Terminal become tabs inside the card or stay as the separate right and bottom cards built in 1.16.0, and is the switch on or off by default. The orchestrator suggested tabs inside and on by default.
- Reuse `DesignSystem/Components/CardTopRow.swift`. It was built for the right panel's top row with this in mind.
- If item 9 is a yes, it belongs in the same change.

Do this last. It touches everything.

## Parked. Do not start without the user

- **T3 top-up.** CandyWrapper matches T3 Nightly 4928 (`T3_VERSION`). The user's servers run 0.1.12-nightly. Nobody has looked at what changed. The orchestrator offered a research-only pass first and got no answer.
- **98 catch-up rows** marked "not reached" in `docs/research/nightly-diff-4928-commits.md`, mostly the PR, git, terminal and files panels.
- **Tabs rebuild** following maria-rcks' pull request #28845.
- **Attachments on queued messages.** Editing a queued message changes only its text.
- **Translation.** Planned in `docs/research/translation-4928.md`, not started.
- **Title regeneration upstream.** T3's regenerate prompt tells the model to keep the original subject (`packages/provider-core/src/server/textGenerationPrompts.ts:426-440`), and the context always keeps 2,000 characters of the first message (`threadTitleContext.ts:67-68`). That is why long threads keep stale titles. CandyWrapper's "Deeper rename" works around it. The user may want an issue or pull request on T3. Do not open one unasked.
- **VMs for testing.** The user asked about testing in macOS VMs while the host builds. The answer given: it fixes screen contention but not build speed, so try the new background tools first and add one VM only if agents on the user's screen get in the way.

## Waiting on the user

- Export the "Apple Development" signing identity as a `.p12`. Never recreate it: a new certificate revokes the one that signed every release.
- Raise the approval dialog's fidelity ceiling from 4% to 5%, or not. `PanelScreensFidelityTests` 05-approval-request has failed since before 1.15.0, and so has `ChangedFilesFidelityTests.cardAndDiff`. Both shipped that way.
- The user saw 14% CPU and about 400 MB on their own MacBook with a very long thread open. A sandbox build idles at 0.04% and 36 MB. They were asked to run `sample CandyWrapper 5 -file ~/cw-sample.txt` with the app idle and attach it. Nothing came back.

## Before a release

1. `scripts/test` in full. The only failures allowed are the two fidelity tests above.
2. `scripts/test --fast` three times in a row, all green.
3. `scripts/perf-review --commit HEAD --baseline docs/perf/2026-11-20-0c1c6f0-w1.json`. The dataset in `~/CandyWrapper-research/perf-home-pristine` was rebuilt on 2026-11-21, so older saved runs do not compare.
4. One agent walks the whole app in a real window in Redesign dark, Redesign light, default dark and default light, and reports findings by severity. The brief used for 1.16.0 is in the release walk's thread and the result in `relcheck-1.16.0/REPORT.md`. This walk found things every test missed.
5. Look at the pictures yourself. Twice the orchestrator caught a visible bug that the agent and the walk both missed.
6. Release only when the user says so: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, run xcodegen, commit `build: version X (N)`, push, then `scripts/release --notes <file> <commit>`. Then download the ZIP and the feed and check the version, the checksum and the code signature. See `docs/release.md`.

## Mistakes not to repeat

- An agent that says "no `App/Sources` change, so I skipped `scripts/check-app-build`" has been wrong twice. The app target is stricter than `swift test`. Run it every time. It takes 15 seconds on a warm slot.
- Offscreen pictures miss overlap, missing backgrounds and anything about hover. Check in a real window.
- Do not run a command you cannot follow. Use `run_in_background` and wait on it.
- Do not launch a check with `&` from a shell call.
- A baseline re-record that is interrupted leaves half the images changed. Reset `design/redesign-baseline` and record again.
