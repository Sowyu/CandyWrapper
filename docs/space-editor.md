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

Measured by `SpacePageEditorTests.typingLatencyOnAThousandBlockPage` on 2026-10-24 on the shared Mac mini M4, with other agents' builds running. Run it with `scripts/test -c release --filter typingLatencyOnAThousandBlockPage`. It's left out of the fast lane.

| Measure on a 1,000-block page | Budget | Editor, Release | Plain TextKit 2 view, same steps |
|---|---|---|---|
| Key to glyph p95: insert, viewport layout, draw the edited line | 8 ms | 12.6 ms | 9.0 ms |
| Insert alone p95 | | 4.07 ms | 4.05 ms |
| First paint | 50 ms | 183 ms | 87 ms |
| Typing flush, one block | | 4.4 ms | |

The editor's own work per key is about 0.1 ms over AppKit's insert. Both budgets fail even for a bare TextKit 2 view under this harness, where a plain insert takes 1.6 ms at 10 paragraphs and 2.7 to 3.9 ms at 1,000, against 0.9 ms for TextKit 1. The rest of the editor's gap is its layout fragments and paragraph styles.

## Not done here

- Image upload, previews, width drag and the shared image pipeline are piece 16. Images go into the local copy's encrypted blob cache and draw from it, decoded once at display size.
- The main-thread replica in `PersistentSpacePageStore` keeps every op of the session as pending, since nothing confirms it yet. Sync (piece 7) should feed it the writer's frames.
- "Pick a date…" opens a native `NSDatePicker` popover. DesignSystem's `CalendarView` inside a `PopupHost` `PopoverView` got no clicks or hover from the editor, and that needs its own look.
- The device label for conflict copies is "This Mac" until settings (piece 10) names the device.
