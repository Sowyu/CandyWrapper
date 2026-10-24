# Space fields engine

`SpaceFields` implements piece 8 of [the Space plan](space.md). It depends only on `SpaceModel` and Foundation. No app target links it yet. These conventions fill in the query and conversion details that sections 1 and 4 leave open, without changing the stored model or operator strings.

## Using it

Create `FieldItem(id:page:)` values for a page's children, then call `FieldQuery.evaluate` with the parent's `fields`, sorts and filters. Pass `FieldContext(now:timeZone:)` from the device for each query. The engine never reads the system clock, locale or zone. The reserved `title` always reads the child's title, even if a malformed schema also defines it.

All filters must hold. Trash is excluded. Unknown fields, unknown field types, unsupported operators, invalid operands and more than three sorts throw, including on an empty input. Unknown or mismatched property shapes behave as empty cells and remain untouched in the records.

The text and URL operators compare with Unicode case folding and canonical composition using the fixed POSIX locale. They retain spaces and accents. Empty means missing, JSON null, an empty string, an empty multi-select, an unknown option id, or a value of the wrong shape. False and zero are present values. Unknown members of a multi-select are ignored; duplicates count once. Negative comparisons also require a present value. Option operands are single option ids; multi `is` means membership and `is not` means absence from a nonempty selection. Numeric operands use JSON numbers, checkbox operands use JSON booleans, and text operands use JSON strings. Operand-free operators ignore their stored `value`.

## Sort and group

Sorts compare text and URLs by folded UTF-8 bytes, numbers as exact `Decimal`, checkboxes false before true, and select options by option order then option id. Multi-selects compare lexicographically by their selected options in that same order, regardless of stored array order. Dates compare their stored starts as instants; a date-only start resolves to midnight in the device zone. Missing or invalid cells sort last in either direction. Ties, including an unsorted query, use manual `order` then page id. Descending affects the field comparison alone.

Call `FieldQuery.groups` on the query result for a Board. It returns an empty column first only if needed, then every option in option order, including empty columns. Checkbox columns are false then true. A multi-select card appears once in each selected column. Hidden option ids omit columns without changing cards or creating a false empty membership. Grouping retains the input's order within each column.

## Dates

Before, after and on take a `YYYY-MM-DD` string and compare the stored start's calendar day in the device zone. They exclude or include the whole day, respectively. This week is Monday inclusive through the following Monday exclusive, using Gregorian calendar arithmetic in the device zone. Timed starts resolve in their stored zone first, with the model's gap, overlap and unknown-zone rules. Date-only starts stay on their calendar date.

Overdue is strictly after a timed start's instant, or at the next local midnight for a date-only start. Local calendar arithmetic handles 23-hour and 25-hour days. Every date operator uses the stored start, including for ranges and weekly values; it does not expand recurring occurrences or inspect Done. The timetable expands occurrences separately with `DateValue.occurrence`.

## Conversion preview

`FieldConversion.convert` returns a value and an outcome: empty, kept, converted, partial or cleared. `preview` does this for each supplied item and returns a plan with the target definition. Pass every affected child, including trash if it can be restored. The plan never mutates records or creates options. A preview rejects the reserved title id and type changes to the fixed Done checkbox or Due date. The caller can show `lostValueCount` in its confirmation before applying the plan through Space's normal edit path. A partially retained multi-select or date counts as one affected value, rather than one loss per discarded member. `clearedValueCount` counts full losses only.

A no-op keeps the exact original value, including unfamiliar shapes. A same-type scalar change also retains the value and date metadata; changing only an option field's name or order retains its props too. Other conversions clear empty values without reporting a loss. A nonempty invalid source shape clears with a loss, as does an option with an empty name converted to empty text. Unknown source or target types throw.

The table describes every type pair. An unsuccessful conversion clears the value and reports a loss. Ordinary changes of representation, such as a number becoming text, count as converted. A partial result reports a loss as described below.

| From / to | Text | Number | Checkbox | Select | Multi | Date | URL |
|---|---|---|---|---|---|---|---|
| Text | Keep | Parse decimal | Parse true/false | Match option name | Match one option name | Parse date | Validate URL |
| Number | Decimal text | Keep | Only 0 or 1 | Match decimal text | Match decimal text | Clear | Clear |
| Checkbox | true/false | 1 or 0 | Keep | Match true/false | Match true/false | Clear | Clear |
| Select | Option name | Parse name | Parse name | Retain id or match name | Retain id or match name | Parse name | Validate name |
| Multi | Joined names | Parse sole name | Parse sole name | First matching option | Retain ids or match names | Parse sole name | Validate sole name |
| Date | Start text | Clear | Clear | Match start text | Match start text | Keep whole value | Clear |
| URL | Keep string | Parse string | Parse true/false | Match option name | Match one option name | Parse date | Keep |

Number parsing trims whitespace, requires a complete decimal or exponent form, and rejects overflow or a value that cannot be represented exactly as `Decimal`. Checkbox parsing trims whitespace and folds case, accepts only true and false, and never guesses from other words. Numeric 0 and 1 also convert to checkbox; text "0" and "1" do not.

Option matching trims whitespace and folds case, retains an existing id through an option rename, and otherwise matches an existing destination option's name. Duplicate names take the first option by order then id. Multi names come from source option order. Converting several choices to select keeps the first matching source choice and reports partial loss. Unknown members, unmatched names or several names collapsing into one option also report partial loss when something survives. A multi-select becomes text by joining names with ", "; text is never split on that delimiter when converting back to options.

Dates parse only the model's exact `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM` forms. A new timed value takes the supplied device zone; a date-only value has no zone. Converting a date to another type uses its raw stored start text. If it has an end, zone, recurrence, reminder or unfamiliar metadata, the surviving start reports partial loss. A same-type date keeps all of these, including unknown zone ids.

A new URL needs an absolute scheme and a nonempty scheme-specific value, with no whitespace; HTTP and HTTPS also need a host. Existing URL strings remain strings when retained or converted to text. A destination text field retains the source text exactly, including whitespace.


## Validation on 2026-10-24

All 27 SpaceFields tests pass, including the 49 source/destination type pairs, empty/no-op pairs, every filter operator, malformed and mixed cells, grouping, exact Decimal parsing, Unicode composition and time-zone/DST boundaries. The complete fast lane passes with `scripts/test --fast --no-parallel`: 1,892 Swift Testing tests and 18 XCTest tests. The diff review checked dependency isolation, comparison consistency, data retention and explicit clock/zone use. No app or UI target links SpaceFields. The final fast check after rebasing onto `9f2836b2` includes the new apply and sidebar tests. The full-suite and benchmark runs below were captured before that rebase.

The full suite ran 2,046 Swift Testing tests and 18 XCTest tests, with one MCP snapshot failure: `McpFollowupsFidelityTests.cardsAndWatch` differed by 57.84%. Running that same test alone on the unchanged base and this checkout passed at 2.61% in each. Two later fast attempts hit other existing tests: ServerUpdater's boot-service test missed its fake lifecycle subscription, and ThreadCompletion's minimap test measured one 52-pixel band among 10-pixel ticks. All nine updater tests and all 17 ThreadCompletion tests pass alone. The final fast run with parallel testing explicitly disabled passed every test. These intermittent suite failures remain open; no client, UI implementation, reference or fidelity threshold changed.


The 27 engine tests also pass from the prebuilt Release bundle. The benchmark review used `scripts/perf-review --source . --no-app` against the last saved run, `ce6dde1` (2026-10-23). Its cold Release build completed, but its test invocation began rebuilding the package. The measurement was completed with the same prebuilt Release bundle using `CW_BENCH=1 scripts/test -c release -Xswiftc -enable-testing --skip-build --filter PerfBenchmarks`, and the unmodified comparison functions from `scripts/perf-review`.

The initial noisy run flagged 40 of 43 metrics. A quiet control, with no busy compiler or foreign app and a 1-minute load of 1.40, reduced that to six alerts. Both result sets remain in `/tmp/cw-space-8-perf/`; `quiet-review.md` and `quiet-review.json` hold the control. No app scenarios were measured. The benchmark executable does not link SpaceFields, and the paths below are unchanged by this diff. A baseline control is needed to attribute these existing-path alerts; they do not measure the new field engine.

| Benchmark | Saved median, ms | Quiet median, ms |
|---|---:|---:|
| `huge_open_long_panel` | 12.653 | 15.263 |
| `huge_cache_write` | 34.005 | 41.186 |
| `huge_cache_load` | 27.682 | 35.088 |
| `huge_update_stream` | 1.995 | 2.899 |
| `huge_update_tool` | 1.896 | 2.812 |
| `huge_update_append` | 3.641 | 4.371 |
