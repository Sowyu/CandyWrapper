# Space format fixtures

These synthetic examples follow `docs/space.md` sections 1, 2 and 7. They contain no personal Space data. Mac and Android should decode and re-encode each model JSON file listed below to the exact same UTF-8 bytes.

The files use compact JSON, sorted object keys, literal Unicode, unescaped slashes and no trailing newline. Arrays retain their order. This deterministic encoding is a fixture convention, not a requirement to reorder existing log frames: `recs` stays in the given order for authenticated data. Crypto vectors live in `crypto.json` from piece 3; the `ct` and `check` strings here are placeholders, not valid encrypted envelopes.

| File | Covers |
|---|---|
| `snapshot.json` | Pages, every block and field type, all option colors, all four views, UTF-16 rich text, blobs, files with PNG and rasterized SVG references, image and emoji icons, title column names, hidden title columns, trash, conflicts and unknown keys. |
| `dates.json` | Date-only and timed starts and ranges, weekly dates, both reminders, explicit nulls, missing optional keys, unknown zones and DST boundary times. |
| `op.json` | Per-key changes, nested field/prop/view paths, null removal and unknown paths. |
| `frame.json` | Ordered record/base pairs, including a null base, plus exact large integers. |
| `header.json` | Version 1 header and null `movedTo`. |
| `encrypted-snapshot.json` | Snapshot envelope. |
| `order-keys.json` | `[lower, upper, generated]` vectors for rocicorp's default base-62 fractional indexing. Null bounds mean the beginning or end. |
| `filters.json` | Every operator from section 4, including files emptiness, spelled as in the spec. |

# Swift API

`SpaceModel` is a Foundation-only CandyKit library with no T3 or UI dependency. `SpaceJSON.encode` and `decode` implement the fixture convention. Each object keeps unfamiliar keys in `extra`, including nested field, view and date objects. Nullable properties preserve the difference between missing keys and explicit nulls. Public constructors use nulls for the nullable record keys in the spec and omit absent date/view options.

Record ids belong to the snapshot map or `RecordChange.id`, never inside `PageRecord` or `BlockRecord`. `SpaceID` and its page, block, record, device and op aliases validate lowercase UUID v4 strings. `SpaceID.bytes` provides the 16 salt bytes in UUID order.

`PropertyValue` uses the actual untagged JSON shapes. Text, select and URL values all decode as `.string`; the parent's field definition tells them apart. Non-empty blob reference arrays decode as `.files`. Empty arrays decode as `.multi([])` and the field type identifies an empty files value. Unknown shapes and field/view/type strings survive a round trip. `RecordChange.set` holds raw `JSONValue` values so apply can preserve new paths. JSON integers keep their precision instead of passing through Double.

`DatePoint` stores a calendar string, not an epoch. `DateValue` requires a zone for timed values and forbids one for date-only values. It retains unknown zone ids and resolves them with the supplied device zone. `occurrence` resolves weekly starts in the stored zone before conversion, with the first occurrence's elapsed length. `settingTime` accepts picker instants, retains an existing timed value's zone and gives a newly timed value the supplied device zone. Date-only reminders resolve from 09:00 in that device zone. DST gaps move later by the gap length; overlaps use the earlier instant, matching java.time.

`OrderKey` compares bytes, and `RecordPosition` adds the record-id tie break. `between` generates short rocicorp keys. It also accepts base-62 bounds from other clients; when two arbitrary strings have no representable key between them, such as `0` and `00`, it throws `noKeyBetween`.

No model API performs I/O, starts timers, reads the Keychain or contacts T3. `SpaceCrypto` holds the crypto and `SpaceEngine` applies frames, rebases pending changes, merges text and builds undo. Storage, filter evaluation and the UI are later pieces.
