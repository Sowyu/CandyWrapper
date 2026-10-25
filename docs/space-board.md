# Space board

Piece 14 of the build plan in [Space](space.md): Board view of a page's items, in mockup look B. The code lives in `Packages/CandyKit/Sources/Features/Space/`.

## How it fits together

- `SpaceBoard` holds the rules as pure functions: setup, columns, card text, moves, new cards and option edits. Each write comes back as `RecordChange`s for the store's `edit`, so it goes through apply, saves encrypted and undoes.
- `SpaceBoardView` is the view: the page header, the Filter, Sort and Fields row, and a scroll view over `SpaceBoardCanvas`. It keeps its own `UndoManager` with one group per action, like the editor.
- `SpaceBoardCanvas` draws every lane and card in one view, so 500 cards cost no views. It tracks hover, clicks and drags itself. Inline editing of a card title or column name is one `NSTextField` laid over the spot.
- `SpacePageView.itemViews` maps a view type to the view that shows it, one line per view. Table and Timetable add their own line there. Non-page views get a full-width header with 32pt margins.

## Rules

- Opening Board on a page whose settings can't group picks the first select field by field order. With no select field it adds "Status" with Not started, In progress and Done, and groups by it. New settings show up to three other fields on cards, skipping checkboxes, Done and Due.
- Columns come from the fields engine's `FieldQuery.groups` after `evaluate` with the board's sort and filter. A filter or sort naming a missing field shows the cards unfiltered rather than an empty board.
- On a checkbox board a card with no value counts as unticked, so the board has just its two columns, "Not done" and "Done".
- Dropping a card in another column sets the group value. A multi-select card swaps the source option for the target one. Without a sort the drop also writes an order key between the card's new neighbors in the page's content, which includes text blocks. Dropping at a column's end puts the card right after the column's last card. With a sort on, only the value changes.
- "+ New" makes a child page at the column's end with the column's value, and `done: false` in a to-do list, then edits its title in place. A click on a card opens it as a page. A to-do list's cards show the checkbox, and a click on it ticks the card.
- The ⋯ menu on an option column renames, recolors, hides and deletes. Delete clears that option from every card in the same change, so one undo brings both back. The last option can't be deleted. The "+" after the last column adds "Option N" in the first unused color and edits its name.
- Fields picks the group field, the fields on cards (three at most) and brings hidden columns back. Sort sets one sort or Manual; picking the current field again flips its direction. Filter only clears filters for now.
- Option dot colors are fixed per theme in `SpaceBoardCanvas.dotColor`, from the mockup's dark values with deeper light ones.

## Not done here

- Building filters from the Filter menu. It shows "No filters" or clears them. The Table view's filter editor should serve both.
- Dragging columns to reorder options, and keyboard moves for cards.
- Cards aren't separate accessibility elements yet, since the canvas draws them.

## Checked on 2026-10-25

On screen against the sandbox, in a test app with its own bundle: Board on a new page added Status and its three lanes. "+ New" added four cards, a drag moved Emma into In progress, a drag put Piranesi above Dune, and a click opened Dune as its page under "Space › Reading list". After quitting and relaunching, the cards came back in the same columns and order. Light mode drew white cards on faint lanes, and "+" added an "Abandoned" column in the next free color. The screenshots are `dark-board.png`, `dark-drag.png`, `dark-open-card.png`, `dark-after-relaunch.png`, `light-board.png` and `light-add-column.png` in `~/CandyWrapper-research/notes/space-14-board/`.

A rebuilt test app can't read the Space key an earlier build saved, since the Keychain ACL trusts only the build that made it, and asks for the login password. Use a fresh task name for each rebuild you check on screen.
