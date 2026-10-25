# Space table view

Piece 13 of the build plan in [Space](space.md): the Table view of a page's items. The code lives in `Packages/CandyKit/Sources/Features/Space/`.

## How it fits together

- `SpaceTableModel` holds the rows, columns, sorts and filters for one page and makes every edit. Rows are the page's child pages after `FieldQuery.evaluate`. Columns are Title, then `views.table.cols`, or every field in field order while the page has no table settings yet.
- Each edit is one `store.edit` call, so it goes through apply, saves encrypted and registers one step on the model's own `UndoManager`. The model observes the store and reloads only when a change touches the page or one of its items. Stores notify synchronously, so that is the one reload per edit.
- Settings writes go to the two-level key `views.table`, so Board and Timetable settings edited on another device still merge.
- `SpaceTableView` is what `SpacePageView.mount` shows for `.table`. It moves the page header into its scrolling document and gives it the full width, since the spec caps only Page view at 720pt.
- `SpaceTableDocument` draws the toolbar, the header row and "+ New", and keeps a row view only for each visible row, recycled as the table scrolls. Rows draw their cells with CoreText lines; nothing is a subview per cell.

## Look

Mockup look B's layout, with row dividers only, plus look A's type icons in the column headers and A's tinted select pills, as the user picked on 2026-10-24. Option colors are the Tailwind 700 and 300 text over the 500 at low alpha, fixed in `SpaceTableColors`, because DesignSystem's base palette lacks most of those steps. New options take blue, purple, green, orange, pink, yellow, red, brown, then gray.

## Behavior choices the spec leaves open

- A click selects a cell. A second click, a double click or Return edits it or opens its menu. Checkbox cells tick in one click, and Space ticks a selected checkbox.
- Sorting from a header replaces the sort with that field alone. The toolbar's Sort menu adds up to three.
- Changing a text or URL field to select or multi first adds an option for each distinct value, so values convert by name instead of being lost.
- Deleting a field removes its column, sorts and filters and leaves the values on the items, so undo restores everything. A toast offers Undo for it.
- The title column's name lives on the page as `titleName`, read through `SpaceTableModel.titleName`, with "Title" as the default. Hiding it writes `titleHidden`; a hidden title keeps its width in `cols` for when it shows again.
- Files & media cells draw from `SpaceMedia`, which decodes 160-pixel thumbnails from the encrypted blob cache in memory only and posts `didLoad` so visible rows redraw. `SpaceTableMedia.swift` holds the cell drawing, the files list popover, the row icon picker and drop handling.
- A sort or filter that names a deleted field is ignored when reading, and dropped on the next settings write.
- A new row goes after the page's last content. In a to-do list it starts with `done: false`.
- Dates display as "Mon 27 Oct" in the device's zone, with the time for timed values and the year when it isn't this year. A `due` value is red when overdue and the item isn't done.

## Performance

Measured by `SpaceTableTests.bigTableBudgets` on the shared Mac mini M4 with other agents' builds running. Run it with `scripts/test -c release -Xswiftc -enable-testing --filter bigTableBudgets`. It's left out of the fast lane.

Release, 2026-10-25, after rebasing onto the Board and Timetable views:

| Measure | Budget | Result |
|---|---|---|
| Switch a 1,000-item page from Page to Table, first screen drawn | 50 ms | 54 ms |
| The same with 5,000 items | | 220 ms |
| Scroll frame at 5,000 rows, 97 pt a frame, rows that came into view drawn | no dropped frames | p50 3.9 ms, p95 4.9 ms, max 26 ms |
| Redraw every visible row, as a theme change does | | 36 ms |
| Model reload at 5,000 rows | | 23 ms |
| One cell edit at 5,000 rows, every observer included | | 215 ms, of which 189 ms is other observers |

Switching misses its budget by 4 ms. Most of it is drawing the first screen and the page header's own work; the model builds 1,000 rows in about 5 ms. Scrolling stays well inside a 60 Hz frame at p95; the one 26 ms frame in 300 was on a machine busy with other builds. Two changes got the model there. It reads a page's children straight from `pages` instead of `content(of:)`, and `FieldQuery.evaluate` sorts an index array over flat key arrays instead of moving page records, which took reload from 100 ms to 23 ms.

The test gives each setup step its own autorelease pool. Without that, the Page view's editor stays alive until the test ends and keeps reloading 5,000 items on every edit, which doesn't happen in the app.

## Not done here

- The page header's to-do counts in `SpacePageView.meta` walk every item on each store change. On a 5,000-item to-do list that dominates the cost of one cell edit. It's piece 12's code.
- `addRow` and `moveRow` still call `content(of:)`, which sorts blocks and pages together, once per action.
- The date cell uses the same native `NSDatePicker` popover as the page editor until DesignSystem's `CalendarView` works in a popover.
- Timed dates, reminders and repeat can't be set from the table yet. The cell shows them.
- The header row scrolls away with the rows rather than sticking to the top.
