# Space timetable

Piece 15 of the build plan in [Space](space.md): the Timetable view, mockup look A. The code lives in `Packages/CandyKit/Sources/Features/Space/`.

## How it fits together

- `SpaceTimetableLayout` holds the placement rules as pure functions with an explicit device zone: the week's Monday, each item's occurrences in the week, slots split at midnight, side-by-side columns for overlaps, all-day lanes, and the date value after a move or resize.
- `SpaceTimetableView` is the view. `SpacePageView.mount` makes one call, `SpaceTimetableView.install`, which puts it over the stub under the page header. It owns the toolbar ("‹ This week ›" and Today), the day header and the all-day strip, and draws nothing while idle.
- `SpaceTimetableGrid` is the scrolling 24-hour grid inside it. It draws the hour lines, labels and slots, and handles the drags, the context menu, title editing, Delete, Return and ⌘Z.
- The page view sizes its header to the 720pt text column. The Timetable uses the full width, so it moves the header to its own margins after each page layout. Once Board and Table land, `SpacePageView.layout` should own that rule.

## Rules this view decides

- An item's color is its first select or multi-select value by field order, else gray. Its last line is its first nonempty text field by field order, like a room.
- A timed item with no end, or with its end at its start, shows one hour long.
- Moving or resizing one occurrence of a weekly item moves the whole series. The new first occurrence is the dragged time stepped back the same number of weeks on the stored zone's wall clock, so the stored zone and the series' weekday both stay right across DST. Exceptions for one week are out of v1.
- Rows count wall-clock minutes in the device's zone, so 9:00 sits on the 9:00 row on a 23-hour or 25-hour day.
- The grid spans all 24 hours and opens scrolled to `from`. A drag that ends where it started creates nothing, so a stray click makes no item.
- A new item gets an empty title with the cursor in it. Return, Escape or a click elsewhere keeps it, as "Untitled" if empty, and ⌘Z removes it.
- Right-click on a slot opens Open, Rename, Repeat weekly and Move to Trash. Double-click opens the item's page.
- A stored filter the engine can't read shows every item rather than none.

## Checking the time zone rule

The view reads the system zone and redraws on `NSSystemTimeZoneDidChange`. To view the same Space from another zone without changing the Mac's, launch the test app with `-CWSpaceTimeZone Australia/Melbourne` after the run-app arguments. `SpaceTimetableTests` covers Melbourne's DST start on 4 October 2026 and London's end on 25 October 2026 from both sides.

## Not done here

- The toolbar has no Filter or Fields buttons yet. Stored filters apply. The editing popovers should be shared with Board and Table.
- Items can't be dragged in the all-day strip, and the strip has no drag-to-create.
- There is no line for the current time, since it would need a timer while idle.
