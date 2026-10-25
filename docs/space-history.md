# Space page history and Trash

Piece 18 of the build plan in [Space](space.md): page history, restore, and the Trash tab's Restore and Delete forever.

## How it fits together

- `SpaceHistory` in SpaceEngine is pure. `versions(of:base:ops:)` replays the log once on top of the snapshot and returns the page's versions, newest first. Each version keeps the page record and the page's blocks at that point, trashed ones included. `restore(_:in:)` returns the changes that put the page back.
- `SpaceDocumentStore` gains `history(of:)`, `restoreChanges(_:)` and `deviceLabel(_:)`. `SpaceReplicaStore` replays its pending ops. `PersistentSpacePageStore` flushes its writer, then replays the encrypted local snapshot and log on the writer's actor, off the main thread.
- `SpacePageHistoryView` covers the page tab: the version as it was on the left, read only, in a `SpacePageEditor` on a throwaway store, and the list of versions in a 280pt column on the right. The newest version is the current one, so Restore is off for it. Up and down arrows move through versions and Escape closes.
- Restore goes through `SpacePageEditor.commitDiscrete`, so it is one change on the apply path and one undo group named "Restore Version". In a Board, Table or Timetable view it is a plain edit with no undo entry.
- `remove(_:)`, Delete forever, now takes the page and every page under it. `PersistentSpacePageStore` nulls their records through apply, then queues `SpaceLocalStore.removeBlobs` for the blobs only their blocks use. The Trash tab confirms first with the design system's dialog.

## Checking it on screen

Edits from one device within 10 minutes make one version. Launch with `-CWSpaceHistoryStretch 20` to cut the stretch to 20 seconds. A rebuilt ad hoc test app fails the Space key's Keychain ACL and asks for the login password: deny it, then delete that test app's `<bundle id>.space-key` item and its `Space` folder to start over.

Checked on 2026-10-25 against the sandbox in Redesign dark and light: three typed edits made three versions, the oldest showed read only and restored, ⌘Z undid the restore and ⇧⌘Z redid it, two pages went to Trash, one came back, the other went after the confirm, and pages, Trash and four versions survived a relaunch. Screenshots are in `~/CandyWrapper-research/notes/space-18-history/`.

## Limits

- History starts at the local snapshot. Today that is seq 0, since nothing writes local snapshots yet.
- Edits from other devices show as "Another device" until settings (piece 10) names devices.
- Each version holds a copy of the page's blocks. The ponytail note in `SpaceHistory.versions` gives the ceiling.
