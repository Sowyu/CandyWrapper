# Space search and reminder planning

`SpacePlanning` implements piece 9 of [the Space plan](space.md), sections 1, 6, 8 and 10. Its only package dependency is `SpaceModel`; the implementation imports Foundation and has no UI, notification or storage APIs. No app target links it yet.

## Search

Build `SearchIndex(pages:blocks:)` on a worker actor after decrypting the local copy. Pass dictionaries keyed by model ids. The index is a Sendable value, so its owner controls isolation, cancellation and publication to the UI. It creates no tasks or timers. `updatePage` and `updateBlock` replace a single record; nil removes it permanently. A soft delete passes the full trashed record. Page moves and ancestor title changes affect paths immediately without folding block text again. Call `removeAll()` and release query results when Space closes or is disabled.

The index retains original text for snippets and folded text for matching, entirely in memory. It has no encoding conformance or persistence interface. Rebuild it from the encrypted local copy; do not serialize its plaintext into a cache. Clearing releases Swift strings; it does not promise to overwrite allocator memory.

`search(_:submitted:contentLimit:)` returns separate title and content arrays plus the set of title matches and their ancestors for filtering the tree. A blank or punctuation-only query returns empty arrays and an empty set; show the unfiltered tree in that case. All title matches are returned. Content starts at three trimmed characters or `submitted: true` for Return, and defaults to 50 pages. A nonpositive content limit suppresses content only.

Case and diacritics fold with a fixed POSIX locale. Letters, numbers and combining marks form words; punctuation separates them. Each query word must prefix a word in the same title or the same block, in any order. Terms do not combine across blocks or between a title and its content. There is no typo tolerance in the spec. Exact normalized titles rank first, followed by titles beginning with the query phrase, then other title matches. Ties use folded title then page id. A page appears once: title hits lead, otherwise its earliest matching block by manual order and block id provides the snippet. Content pages use folded title then id order.

Snippets collapse whitespace onto one line and keep about 180 characters around the first match, extending for a single longer match. Their bold ranges count UTF-16 units in the returned text and preserve graphemes, accents and case-fold expansions. Breadcrumbs contain ancestor titles from the root, excluding the hit itself. Trash, descendants of trash, missing-parent records and cycles are hidden from both search sections.

## Reminder plans

Call `ReminderPlanner.plan(pages:now:deviceTimeZone:)` with the local pages and an explicit clock and device zone. It returns the soonest 50 reminders strictly after now and through 30 local calendar days from now, inclusive. Ties use request id. All date props participate, including custom date fields and temporarily missing schemas. Done means the fixed `done` prop is the checkbox true. Trash and unreachable ancestry hide reminders; a parent's Done state does not complete its children.

Each `PlannedReminder` includes `space.<pageId>.<fieldId>.<start>`, the nominal occurrence start, the fire instant and Gregorian date components. A timed value's components carry its effective stored zone. A date-only value's components carry neither a time zone nor an embedded calendar, so the eventual notification trigger can float with the device. Unknown stored zones resolve in the explicitly supplied device zone without rewriting the record. DatePoint supplies the shared gap and overlap rules. Date-only `before` counts elapsed minutes back from local 09:00. Explicit `at` resolves in the stored zone for timed values and the device zone for date-only values.

Weekly values produce one request per occurrence. Starts advance by calendar weeks before resolving in the zone. `before` subtracts from each resolved start; an explicit weekly `at` advances its own wall-clock components by the same number of calendar weeks. This preserves the chosen reminder's wall time across DST. Requests keep the nominal start in their id even when a DST gap moves their fire time. A bounded jump finds the planning window for old weekly starts; it does not walk the intervening years. Date values without reminders and unknown reminder forms produce no requests. Invalid mutable model values throw rather than silently producing a partial plan.

The plan carries the item title, parent title and the occurrence time in the supplied device zone for the notification adapter to format with the user's locale. Recompute on date, Done or trash changes, startup, a notification firing and system zone changes. Piece 17 must reconcile pending `space.` ids with the complete returned plan, removing obsolete requests as well as adding replacements. It owns notification permission, actions, snoozes, delivered notifications and withdrawal when Space turns off. This target never schedules a notification.

## Validation

Focused tests cover ranking, word prefixes, Unicode highlights, content gating, ancestor paths, incremental edits against fresh indexes, deletions and restoration. Reminder tests cover device travel, date-only values, custom fields, completion, trash, request replacement, the horizon and cap, weekly occurrences, old starts, one-hour and half-hour DST gaps and overlaps.

`CW_BENCH=1 scripts/test -c release --filter SpacePlanningPerfBenchmarks` measures a synthetic 2,000-page, 20,000-item, 100,000-block fixture in memory. It reports build time, retained index heap growth, and 21 samples each for sparse, missing, common multiword and broad title queries, including p95. `scripts/perf-review --no-app` includes these metrics through its existing `PerfBenchmarks` filter and compares the app's unchanged headless benchmarks with the last saved run. The search index uses the spec's linear scan; a p95 above 30 ms triggers the trigram upgrade.
