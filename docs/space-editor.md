# Space page editor

Piece 12 of the build plan in [Space](space.md): Page view on TextKit 2. The code lives in `Packages/CandyKit/Sources/Features/Space/`.

## How it fits together

- `SpaceDocumentStore` extends `SpacePageStore` with blocks, a page's content, and `edit` and `undo` that return undo entries. `SpaceReplicaStore` implements it on piece 4's `SpaceReplica` in memory, and calls `onEdit` with each pending op before observers run. `PersistentSpacePageStore`, the app's store, keeps its screen state in a `SpaceReplicaStore` and queues each of those ops, undo included, to its encrypted writer in order.
- `SpacePageView` is the page tab: the header with breadcrumb, title, the "Edited" line and the Page, Board, Table and Timetable switch, over the current view. Page view is the editor. The other three are `SpaceViewStub` until pieces 13 to 15 replace their case in `SpacePageView.mount`.
- `SpacePageEditor` owns one TextKit 2 `NSTextView`. Every block and every child page is one paragraph, and the record rides on each character as the `cw.space.block` attribute (`b<uuid>` for a block, `i<uuid>` for a child page).
- `SpaceBlockFragment`, a custom `NSTextLayoutFragment`, draws everything around the text: the checklist card, checkboxes, due labels, bullets, numbers, quote rules, code wells, dividers, images and conflict banners.
- `SpaceMarkdown` holds the line-start shortcuts, Markdown paste and Markdown copy as pure functions.

## Editing rules

- After an edit that adds or removes a paragraph break, every paragraph takes the key of its first character, else its separator. If both keys are already taken, the paragraph is a new record. New paragraphs carry on lists and quotes, and turn headings, dividers and media into text. Keys that vanish are trashed, never removed.
- Typing coalesces into one change per block, sent 400 ms after the last key or every 2 s while typing goes on (spec section 3).
- Undo uses the editor's own `UndoManager` with explicit groups. A typing run is one group; when the 2 s flush lands mid-run, its entry merges into the open group with `UndoEntry.merging`. Return, shortcuts, paste, formatting and moves each get their own group. Undo writes inverse changes through the replica, then the editor reloads the page and keeps the caret in the same record.
- A to-do is a child page with a `done` value. Checklist rows and the card show only for those, so a to-do list can still hold page links. `[] ` and Return on a to-do write `done: false`.
- An image block's `text` is its caption, drawn beside the image as mockup look B shows. The spec's block table says so now.
- Headings draw as small labels in look B: `h1` 12pt semibold, `h2` the same with less space above, `h3` 12pt medium.

## Performance

Measured by `SpacePageEditorTests.typingLatencyOnAThousandBlockPage` on the shared Mac mini M4. Run it with `scripts/test -c release --filter typingLatencyOnAThousandBlockPage`. It's left out of the fast lane. It prints a plain TextKit 2 view's first paint beside the editor's, measured in the same run.

This Mac's speed varies about fourfold between runs with the same code, so compare numbers only within one session. AppKit's bare insert on the editor's text view, which the line also prints, shows the state. It read 0.74 ms in one quiet stretch at 03:40 on 2026-10-25, and 3.3 to 5.1 ms for the rest of the day, even with the load average near 2 and nothing else busy.

On 2026-10-25 I built main (`572e0731`) and this change in Release, then ran them alternately five times each, in the slow state:

| Measure on a 1,000-block page | Budget | Before, median of 5 | After, median of 5 | Plain TextKit 2 view |
|---|---|---|---|---|
| First paint | 50 ms | 205 ms (187 to 226) | 166 ms (144 to 173) | 35 to 43 ms |
| Key to glyph p95: insert, viewport layout, draw the edited line | 8 ms | 12.7 ms (11.0 to 13.0) | 12.1 ms (11.4 to 14.6) | |
| Insert alone p95 | | 4.0 ms | 4.2 ms | |
| AppKit insert alone p95, same text view | | 4.1 ms | 4.0 ms | |

First paint is lower in every one of the five pairs. Typing is unchanged, since the editor adds only about 0.2 ms to AppKit's insert and the rest is TextKit's viewport layout and drawing. In the fast state at 03:40, main measured 41.3 ms first paint and 2.30 ms key to glyph across five runs, inside both budgets, so the budgets hold only on a quiet machine.

The profile, from `sample` on a loop that opens the page 300 times, showed `SpacePageEditor.load` taking nearly all of the editor's first-paint time. TextKit's own `setAttributedString` took about 1% of the samples, because it lays out only the viewport. What changed:

- `SpaceReplicaStore.content(of:)` sorted whole `SpaceContent` records, copying two records per compare. It now sorts positions. This was about a quarter of `load`.
- `FontRuntime.font` built its cache key with string interpolation of an enum, which goes through reflection on every `DSFont` call. It now uses a struct key. This speeds up every `DSFont.ui` call in the app.
- `load` sets each paragraph's style as it builds the string, instead of a second pass that re-parsed every paragraph's key.
- The editor makes base attributes and paragraph styles once per look, not once per paragraph. Both caches empty when `FontRuntime.generation` changes.
- Text with no bold, italic or code marks skips `fixFonts`, and text without newlines skips the newline replace.

The rest of first paint is TextKit's layout and the first window's one-time costs. Lazy layout of off-screen blocks wouldn't help, since TextKit 2 already lays out only the viewport.

The budgets need a quiet Mac to judge. I propose keeping 8 ms and 50 ms for a quiet machine. On a noisy one, I propose checking the editor against the plain view from the same run: key to glyph within 1 ms of plain TextKit 2, and first paint within three times plain's.

## Not done here

- Image upload, previews, width drag and the shared image pipeline are piece 16. Images go into the local copy's encrypted blob cache and draw from it, decoded once at display size.
- The main-thread replica in `PersistentSpacePageStore` keeps every op of the session as pending, since nothing confirms it yet. Sync (piece 7) should feed it the writer's frames.
- An image that is the page's first block doesn't draw: TextKit 2 drops `paragraphSpacingBefore` on the first paragraph, which is where the image's height is reserved (`SpacePageMetrics.paragraphStyle`), so its fragment is 18pt tall and clips the image. The caption keeps its place beside it. After any other block the image draws, and its caption stays beside it across a relaunch (checked on screen 2026-10-25).
- "Pick a date…" opens DesignSystem's `CalendarView` in a `PopoverView`. It used to get no hover and leak presses into the editor, for two reasons. Its tracking area used `.inVisibleRect`, which in a popup spans the whole host, the trap `MenuView` already notes. It also didn't override `mouseDown`, so the press went up the responder chain to `MainWindow` and on to `SpacePageTextView.mouseDown`, which can add a to-do. It now tracks its bounds, follows the pointer through `HoverSyncPointerClient` and keeps the press.
- The device label for conflict copies is "This Mac" until settings (piece 10) names the device.
