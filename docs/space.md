# Space

Space is a private, Notion-style workspace inside CandyWrapper for the user's own notes and planning. It is for the user, not for agents, and it has nothing to do with T3 threads. This is a spec only. Nothing here is built yet. Mac comes first, and the Android app must later read and write the same format.

Written 2026-10-24 for review. Facts about T3 cite `~/CandyWrapper-research/t3code` at the tag in `T3_VERSION`.

## Decisions in one place

- Space is an experimental feature, off by default, with one switch in Settings > Experimental.
- It shows only under the Redesign theme, as one "Space" row under Automations.
- Everything is a page. A page's child pages are its items, and Page, Board, Table and Timetable views show those same items.
- One machine holds Space, miniko by default, and every device keeps a full local copy for offline work.
- That machine stores only ciphertext. The app encrypts everything with a key that lives in each device's Keychain and never reaches the Space machine or any T3 surface.
- The Space machine's only job is to order and keep encrypted changes. The CandyWrapper Helper binary does it, reached through a hidden T3 terminal.
- The change log is the history. Undo is per device and syncs as ordinary changes.

## Experimental toggle

Settings > Experimental, the tab another agent is building now, gets one switch:

- Title "Space", description "Private notes, to-dos and plans, kept on one of your machines."
- Off by default. Stored in CandyWrapper's own defaults as `space.enabled`, per device, never synced, like the Orchestrator's switch (`OrchestratorConfig.enabled`, T3Store/Orchestrator.swift:93).
- Space draws only under the Redesign theme, like the Orchestrator. Under another theme the switch stays but its description adds "Shows in the Redesign theme."

While the switch is off, nothing of Space exists on screen or at run time:

- No Space row in the sidebar, no Space tabs, no menu items, no shortcuts.
- No terminal pipe to the Space machine, no reminders scheduled, no Space code on the launch path beyond reading the bool. The app makes Space's objects the first time it is on. An off launch calls the notification center only if an earlier run scheduled reminders and never finished withdrawing them (`space.remindersScheduled`).
- Turning it off closes open Space tabs, leaves Space mode in the sidebar, closes the pipe and withdraws every pending Space notification.
- The encrypted local copy and the key stay, so turning it on again is instant. "Remove Space from this Mac" under the switch deletes both after a confirmation.

When the switch is on, three more rows appear under it: "Space machine", "Recovery key" and "Remove Space from this Mac". Setup is in "Storage and sync" below.

## 1. Data model

There are two record kinds, pages and blocks. One model sits behind all four views.

A page is a node in the tree. A page's content is the ordered mix of its blocks and its child pages. Its child pages are its items, the things Board, Table and Timetable show. So "pages inside pages", a to-do and a board card are the same thing: a child page.

- A note is a page with text blocks and maybe some child pages, which show as links.
- A to-do list is a page whose fields include Done. Its child pages show as checklist rows in Page view.
- A board, table or timetable is any page viewed that way. Text blocks show only in Page view.
- Opening an item opens it as a page, with its own content and its own items.

### Page record

| Key | Value |
|---|---|
| `parent` | Page id, or null at the top of the tree. |
| `order` | Order key among the parent's blocks and pages. See "Order keys". |
| `title` | String. |
| `icon` | One emoji, or null for the default page glyph. |
| `props` | Map from a field id of the parent's `fields` to a value of that field's type. |
| `fields` | Map from field id to field definition. The schema for this page's items. |
| `views` | Map from view type (`page`, `board`, `table`, `timetable`) to that view's settings. |
| `view` | The view type shown when the page opens. |
| `trashed` | Bool. Trashed pages leave the tree and show in Trash. |
| `trashedAt` | Epoch ms, or null. |
| `created` | Epoch ms. |

Records hold no derived values like "last edited". That comes from the log, so editing a block never touches its page record and two devices editing different blocks never collide.

### Block record

| Key | Value |
|---|---|
| `page` | The page it belongs to. |
| `order` | Order key, in the same space as child pages' `order`. |
| `type` | `p`, `h1`, `h2`, `h3`, `bullet`, `number`, `quote`, `code`, `divider`, `image`, `file`. |
| `indent` | 0 to 5. Lists and paragraphs nest by indent, not by a tree. |
| `text` | Rich text. Empty for `divider` and `file`. On `image` it is the caption, shown beside the image. |
| `lang` | Code blocks only, a language id like `swift`, or null. |
| `blob` | `image` and `file` only, a blob reference. See section 7. |
| `width` | `image` only, display width in points, or null to fit the column. |
| `trashed` | Bool. A deleted block is trashed, so history can restore it. |
| `conflict` | Null, or `{"device": "<label>", "at": <ms>}` on a conflict copy. See "Conflicts". |

### Rich text

```json
{"t": "Buy milk tomorrow", "m": [[0, 3, "b"], [4, 8, "a", "https://example.com"], [9, 17, "p", "<pageId>"]]}
```

- `t` is the text. `m` lists marks as `[start, end, kind]` with an optional fourth value.
- Offsets count UTF-16 code units, which both NSString and Java strings index natively.
- Kinds: `b` bold, `i` italic, `u` underline, `s` strike, `c` inline code, `a` link with its URL, `p` page mention with its page id.
- Marks are sorted by start, then end, then kind. Overlapping marks of different kinds are fine.

### Fields

Each field definition is `{"name", "type", "order"}` plus type-specific keys. Types:

| Type | Value in `props` |
|---|---|
| `text` | String. |
| `number` | Number. |
| `checkbox` | Bool. |
| `select` | Option id. The field has `options`: map from option id to `{"name", "color", "order"}`. |
| `multi` | Array of option ids, same `options`. |
| `date` | A date value, below. |
| `url` | String. |

Two fields have fixed ids so every client recognizes them: `done` (checkbox, named "Done") and `due` (date, named "Due"). Typing `[] ` in a page adds `done` to it if missing. A page "is a to-do list" exactly when its `fields` has `done`. The title is not a field. It is the item page's own `title`.

Colors are a fixed set of names, `gray`, `brown`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `red`, mapped to tokens per theme on each platform.

### Date values

```json
{"start": "2026-10-27T09:00", "end": "2026-10-27T10:30", "tz": "Australia/Melbourne", "repeat": "weekly", "remind": {"before": 15}}
```

```json
{"start": "2026-10-27", "remind": {"before": 0}}
```

The rule follows Google Calendar and RFC 5545 (`DTSTART;TZID`), and Notion behaves the same way for timed dates. The user chose it on 2026-10-24.

- A date-only value has `start`, and optionally `end`, as `YYYY-MM-DD` and no `tz`. It means that calendar date wherever the device is, so a due date of the 27th is the 27th in every zone.
- A timed value has `start`, and optionally `end`, as `YYYY-MM-DDTHH:MM`, the wall-clock time in `tz`. `tz` is an IANA zone id and is required. `start` and `end` are always both timed or both date-only.
- A new timed value takes the device's current zone as `tz`.
- Every device shows a timed value converted to its own current zone. A 9:00 Melbourne meeting shows as 23:00 the day before on a device set to London.
- Editing the time keeps `tz`. The device converts the time the user picked from its own zone back into `tz` and stores that wall-clock time. Only clearing the time or setting a new date from empty takes the device's zone again.
- The date popover shows the value's zone, like "Melbourne time", only when it differs from the device's zone.
- An unknown `tz` id reads as the device's current zone, and the value is written back unchanged.
- `repeat` is null or `weekly`. Weekly is what a timetable needs. Other rules are out of v1.
- A weekly timed value repeats on the same weekday at the same wall-clock time in `tz`, from `start` on. Each occurrence is placed in `tz` first and then converted to the device's zone, so a 9:00 Melbourne slot stays 9:00 in Melbourne through daylight saving changes and can shift by an hour, or to another day, when viewed from elsewhere.
- Each occurrence's end is its start plus the first occurrence's length in minutes.
- A weekly date-only value repeats on the same weekday, in every zone.
- A wall-clock time that doesn't exist in `tz`, inside a spring-forward gap, moves later by the length of the gap. A time that happens twice, in a fall-back overlap, takes the earlier one. This is java.time's `ZonedDateTime.of` rule, and the Mac implements it explicitly so both platforms agree.
- `remind` is null, `{"before": <minutes>}` or `{"at": "YYYY-MM-DDTHH:MM"}`. On a timed value `at` is in `tz`. On a date-only value, `before` counts back from 9:00 on that date and `at` is a wall-clock time, both in the device's current zone.
- Date filters, the timetable's week and "overdue" use the device's current zone. A date-only due date is overdue once its date has ended there, and a timed one once its moment has passed.

### View settings

| View | Settings |
|---|---|
| `page` | `{}` |
| `board` | `{"group": fieldId, "show": [fieldId], "hidden": [optionId], "sort": [Sort], "filter": [Filter]}` |
| `table` | `{"cols": [{"field": fieldId, "width": points}], "sort": [Sort], "filter": [Filter]}` |
| `timetable` | `{"field": fieldId, "from": 7, "to": 22, "days": 7, "filter": [Filter]}` |

A Sort is `{"field", "desc": bool}`, at most 3. A Filter is `{"field", "op", "value"}`, and all filters must hold. The ops per type are in section 4. The title's field id in sorts, filters and columns is the reserved id `title`.

There is one view of each type per page. Several named views of one type are out of v1.

### Order keys

`order` is a string over the 62 digits `0-9A-Za-z`, compared byte by byte, with ties broken by record id. Any key strictly between two neighbors is valid, so clients only need to compare keys and make one between two others. Generate keys with the `fractional-indexing` algorithm (rocicorp, CC0) to keep them short. Android need not produce identical keys, only valid ones.

### Ids

Space, page, block, device and op ids are lowercase UUID v4 strings. Random ids tell the Space machine nothing about time or content.

## 2. File format

There are three formats. The log and snapshot payloads are the contract Android must match exactly. `fixtures/space/` holds golden files, and both platforms' tests read them.

### Keys

The Space key K is 32 random bytes. Every other key comes from it with HKDF-SHA256, salt the 16 bytes of the Space id, and these `info` strings:

| info | Used for |
|---|---|
| `cws1 ops` | Op and snapshot payloads. |
| `cws1 blob` | Blob chunks. |
| `cws1 blob-id` | HMAC that names blobs. |
| `cws1 local` | The device's local files. |
| `cws1 check` | The key check value. |

Every ciphertext is AES-256-GCM with a fresh random 12-byte nonce, stored as base64 of `nonce || ciphertext || tag`. CryptoKit and javax.crypto both do this natively, so neither platform needs a crypto library.

`SpaceCrypto` in CandyKit implements this section. `fixtures/space/crypto.json` holds golden vectors for every key, AAD and ciphertext below, with fixed nonces, and Android's tests must reproduce them. Ids that enter an AAD must be lowercase UUIDs, so the text is the same on both platforms and needs no JSON escaping. The check value has an empty AAD.

### On the Space machine

The folder is `~/Library/Application Support/CandyWrapper Space/` on macOS and `$XDG_DATA_HOME/candywrapper-space/` (default `~/.local/share/candywrapper-space/`) on Linux, mode 0700. It sits outside every T3 project and outside `~/.t3`.

```
CandyWrapper Space/
  space.json            header, plaintext, no content
  lock                  flock(2) target
  log/000001.jsonl      append-only change log, one frame per line, 64 MB per segment
  revs.json             record id to rev, rebuilt from the log if missing
  snapshots/<seq>.json  the latest two snapshots
  blobs/<id>/<n>        encrypted blob chunks
```

`space.json`:

```json
{"format": "candywrapper.space", "version": 1, "spaceId": "…", "created": 1792800000000,
 "check": "<base64 AES-GCM of the ASCII string 'candywrapper space' under the check key>",
 "movedTo": null}
```

A log frame, one JSON object per line:

```json
{"seq": 812, "t": 1792800000000, "dev": "<deviceId>", "op": "<opId>",
 "recs": [["<recordId>", 805], ["<recordId>", null]], "ct": "<base64>"}
```

- `seq` starts at 1 and has no gaps. `t` is the Space machine's clock and only informs history.
- `recs` lists every record the change touches, each with the base rev the device checked, or null for no check.
- The AAD for `ct` is the UTF-8 of `cws1|<spaceId>|<op>|<dev>|` followed by `recs` serialized compactly in the order given, so the Space machine can't change which records a change claims.
- A record's rev is the `seq` of the last frame that touched it. A new record has rev 0.

The decrypted payload of a frame:

```json
{"v": 1, "at": 1792800000000, "changes": [
  {"kind": "page", "id": "…", "set": {"title": "Groceries", "fields.done": {"name": "Done", "type": "checkbox", "order": "a0"}}},
  {"kind": "block", "id": "…", "set": {"page": "…", "order": "a1", "type": "p", "indent": 0, "text": {"t": "Hi", "m": []}}}
]}
```

- `at` is the device's clock, shown in history.
- `set` maps a key, or a two-level path `props.<id>`, `fields.<id>` or `views.<type>`, to a value. Null removes a path. A record exists once any change sets it.
- Applying a frame sets each value. Keys a client doesn't know are kept and written back, so a newer client's data survives an older one.
- Within one change, keys apply in UTF-8 byte order, so `props` replaces the map before `props.<id>` sets inside it. A two-level path splits at the first dot. Null on a path whose map is missing does nothing.
- Revs follow the frame's `recs`, not the decrypted changes, so the Space machine and every client agree.
- One rule makes apply deterministic for the tree: a `parent` change that would make a page its own ancestor is ignored, and the page keeps its old parent. A page whose parent is missing shows at the top.
- Every client applies frames in `seq` order and nothing else, so every copy ends up identical.

A snapshot is `{"seq", "ct"}`, where `ct` has the AAD `cws1|<spaceId>|snapshot|<seq>` and decrypts to gzip of:

```json
{"format": "candywrapper.space-snapshot", "v": 1, "seq": 2000,
 "pages": {"<id>": {…}}, "blocks": {"<id>": {…}}, "revs": {"<id>": 1993}}
```

### On each device

The Mac keeps its copy in its Application Support folder named by its bundle id, so test builds stay apart, under `Space/<spaceId>/`:

- `snapshot.cws`, the confirmed state at some seq, encrypted with the local key.
- `log.cws`, every confirmed frame since that snapshot, the same JSONL with `ct` re-encrypted under the local key.
- `pending.cws`, local changes the Space machine hasn't confirmed yet, written before the UI shows them as saved.
- `blobs/`, the encrypted blobs, at most 1 GB. Until sync lands they are the only copies of their originals, so none is ever evicted: a new attachment that doesn't fit is refused with a message, and earlier ones stay. Once the Space machine holds a blob, this copy may be evicted, least recently used first.

Nothing in this folder is readable without the Keychain key. Decrypted images and text live only in memory.

## 3. Storage and sync

### Which machine

Settings > Experimental > Space > "Space machine" lists the same machines as the composer's Run on. It defaults to the machine labeled "miniko" when one is connected, else the primary machine. The machine needs the CandyWrapper Helper binary. Space uses only the binary, not the helper's service, pairing or tokens (docs/orchestrator-helper.md), so it installs through the existing `HelperInstall` download and hash check, skipping the pairing lines.

When the Space machine is this Mac, the app runs the same host code in process on the same folder, with no terminal.

### How agents are kept out

T3 gives clients no store that agents can't reach. Project files, `~/.t3`, scheduled task prompts, server settings and attachments are all open to agent tools or to an agent's shell, which runs as the same user on the same machine. On this Mac mini agents even have passwordless sudo, so a second Unix user would not stop them either. The barrier therefore has to be the key.

1. The app encrypts every change, snapshot and blob in its own process before anything leaves it. The Space machine, the T3 server, the terminal stream and T3's terminal history file see only ciphertext.
2. The Space key lives only in each device's Keychain, as a non-synchronizable item readable only by CandyWrapper's signed app. An agent's shell can't read it without the user approving a prompt.
3. The local copy on each device is encrypted with a key derived from it, so CandyWrapper's own folder holds nothing an agent can read.
4. No T3 surface carries Space data. It never goes into a project, a thread, a scheduled task, T3's settings or T3's attachments.
5. Agents' T3 tools have no terminal access: the orchestrator MCP toolkits are attachment, device, environment, html, orchestrator, preview, previewControls, project, pullRequests, thread and worktree (`apps/server/src/mcp/toolkits/`). The pipe's terminal uses the thread id `candywrapper-space`, which names no thread, so no T3 client shows it.
6. Space exposes nothing else: no MCP server, no URL scheme that returns content, no AppleScript or Shortcuts, no Spotlight or CoreSpotlight indexing, no Quick Look previews, no widgets.

What this does not stop, stated plainly:

- An agent on the Space machine can delete or corrupt the encrypted files. AES-GCM detects tampering, and every device holds a full copy, so the app offers "Restore Space on miniko from this Mac".
- An agent can't make the app accept forged content, but a rewritten log could replay an older state. Each device remembers the highest `seq` it saw and refuses a Space machine that reports less, with the same restore banner.
- Reminder titles pass through macOS's notification store while pending and after delivery. Section 6 covers that.
- An agent with Screen Recording permission could capture Space while it's on screen. The hardened runtime blocks debugger attach to the app.

The data protection keychain with an app access group would be the strongest option, since `security` can't read it at all, but the spike showed it needs a provisioning profile the release signing doesn't have (docs/research/space-spikes-2026-10-24.md on the space-spike branch). So the key is a generic password in the file-based login Keychain, service `<bundle id>.space-key` and account the Space id, with an ACL whose only trusted application is the signed app (`SpaceKeyStore`). Any other reader gets a user prompt, or a denial with prompts off. Saving never replaces a different key. Debug builds re-sign on every build (docs/gotchas.md), so tests use an in-memory key, and `scripts/space-keychain-test` checks the real item in release-style signed builds.

### Setting up and adding devices

1. The first device makes the Space: a new Space id, a random key, `space.json` on the Space machine, and an empty log.
2. It shows the recovery key once: the 32 bytes as 52 RFC 4648 base32 characters in groups of four separated by spaces, the last character's four spare bits zero, with "I saved it". There is no Copy button and no export to a file, since any process of this user can read the pasteboard and the user's files; the key is written down or typed into a password manager. Settings > Space > "Recovery key" shows it again after a Touch ID or password check.
3. A second device that finds a `space.json` on the Space machine asks for the recovery key. It can be typed, or scanned on Android from a QR code that an existing device shows on request for 60 seconds, using the existing `QRCodeView`.
4. The device checks the key against `check` before it trusts anything, then stores the key in its Keychain.

If every device and the recovery key are lost, Space can't be read. That is the price of keeping the key off the Space machine.

### The pipe

Clients reach the Space machine through a hidden T3 terminal, as the helper install already does. That needs only `terminal:operate`, which every standard and T3 Connect session holds, and no T3 change.

1. `terminal.open` with thread id `candywrapper-space`, terminal id `space-<first 8 of deviceId>`, and the user's home as `cwd`. `ws.ts:2869` passes it straight to the terminal manager, which doesn't check that the thread exists.
2. The client types one line with a leading space: ` exec <helper path> space-serve`. The helper takes the terminal's stdio, switches the tty to raw with no echo and prints `CWS-READY <version>`.
3. Both sides then send one frame per line, base64 of a JSON message. `terminal.write` takes at most 65,536 characters (`packages/contracts/src/terminal.ts:66`), so larger messages split across writes and the helper reassembles them.
4. The pipe stays open while the app runs with Space on. Nothing flows while nothing changes, so idle costs no wakeups. On a network change or a closed terminal it reconnects with backoff, and stops trying after 10 minutes until the next network change or Space opening.
5. Closing uses `terminal.close` with `deleteHistory`, as the helper install does.

T3 keeps up to 8 MB of terminal output in a history file while the terminal is open (`Manager.ts:96`). It holds only ciphertext.

Messages from the client: `hello {spaceId, deviceId, after}`, `push {op, recs, ct}`, `blob.put {id, n, last, ct}`, `blob.get {id}`, `snapshot.put {seq, ct}`, `move {to}`.

Messages from the Space machine: `frames [...]` for catch-up and live changes, `ack {op, seq}`, `reject {op, revs}`, `blob {id, n, last, ct}`, `snapshot {seq, ct}` when a client is far behind, and `error {code}`.

The Space machine does exactly this:

1. Take the `flock` on `lock`.
2. Return the earlier `ack` for an `op` it already has, so resends are safe.
3. For each record in `recs` with a non-null base, compare it with `revs.json`. If any differ, send `reject` with the current revs.
4. Otherwise append the frame with the next `seq`, `fsync`, update `revs.json`, release the lock and send `ack`.
5. Every `space-serve` process watches the log with kqueue or inotify and sends new frames to its own client, so two devices' processes fan out through the file with no daemon.

### Offline edits and two devices

Each device keeps two layers: the confirmed state, built only from frames in `seq` order, and its pending changes on top. The screen shows confirmed plus pending.

1. An edit applies locally at once and goes into `pending.cws`.
2. Typing coalesces into one change per block, sent 400 ms after the last keystroke or every 2 seconds while typing goes on.
3. Changes that set `text` carry the block's rev as their base. Every other change carries a null base, since field-level sets merge on their own and the later `seq` wins.
4. Offline, pending changes pile up. On reconnect the device first catches up on frames, then rebases its pending changes on the new confirmed state, then pushes them in order.
5. On `reject` it catches up, rebases the rejected change and pushes again, up to five times before it waits for the next frame.

### Conflicts

Only text can conflict. Everything else is a per-key set where the later change wins, which is what one person expects.

The device that pushes second merges, with all three versions in hand: the base it edited from, the confirmed text and its own.

1. It runs a three-way merge on the text by characters, using a Myers diff.
2. Changes that don't overlap merge, and marks follow their text. If both sides changed marks in the same range, the confirmed side's marks win.
3. If the changes overlap, the confirmed text stays and the device's version becomes a new block right after it, with `conflict` set. It renders with a faint left rule and the line "Your edit on <device> at 10:42" plus Keep and Discard. Keep replaces the original with it, and Discard trashes it.

Other cases:

- Editing a page another device trashed lands in the trashed page, and the page shows "Moved to Trash on <device>" with Restore.
- Moves that would make a cycle are ignored by the apply rule above, the same way on every device.
- Two devices adding items at the same spot keep both, ordered by record id.

### Snapshots and growth

- After 2,000 frames since the last snapshot, the next idle device uploads one at its confirmed `seq`. The Space machine keeps the latest two.
- A new device downloads the latest snapshot and the frames after it.
- The log keeps every frame, which is the history. At about 300 bytes a change, a heavy year is around 100 MB.

ponytail: the log is never pruned. Add a "Keep history for" setting when the log passes 500 MB.

### Moving Space

"Space machine" set to another machine copies the latest snapshot, the whole log and every blob from this device's copy to the new machine, then writes `movedTo` with the new machine's environment id into the old `space.json`. Other devices see `movedTo` on their next hello, switch and save the choice. The old folder stays until the user removes it from the same row.

## 4. Views

The page header holds the breadcrumb, the title at 28pt, and a view switch at the right of the title row: a four-part toggle group, Page, Board, Table and Timetable, each with its icon. The choice is stored in `view` and syncs. Page view caps its text column at 720pt, and the other views use the full width. Board, Table and Timetable show a quiet toolbar row under the header with Filter, Sort and Fields, and nothing else.

Items keep one manual order everywhere: their `order` among the page's content. Dragging an item in any view without a sort changes that order.

The pure Swift engine and its detailed query and conversion conventions are described in [Space fields engine](space-fields.md).

Filter ops by type:

- Text and URL: contains, does not contain, is, is empty, is not empty.
- Number: =, ≠, <, ≤, >, ≥, is empty.
- Checkbox: is.
- Select and multi: is, is not, is empty.
- Date: before, after, on, this week, overdue, is empty.

### Page view

- One TextKit 2 `NSTextView` per page holds every block as paragraphs, with the block id as a paragraph attribute. This gives native selection across blocks, IME, spell check, accessibility and viewport layout. Edits map back to block changes after each edit.
- Dividers, images, files and item rows are attachments with view providers.
- Markdown shortcuts at line start: `# `, `## `, `### `, `- `, `1. `, `[] `, `> `, three backticks, `---`. Tab and Shift-Tab change indent.
- `/` opens a block menu in the existing `PopupHost`: Text, Headings, Bulleted list, Numbered list, To-do, Quote, Code, Divider, Image, File, Page, Board, Table, Timetable. The last four create a child page in that view.
- In a to-do list, items with a `done` value render as checklist rows: a checkbox, the title, and a due chip when `due` is set, red when overdue. A ticked row dims its title. Return on a row makes the next item. New to-dos get `done: false`, so a to-do list can still hold page links.
- Other child pages render as page link rows with their icon and title. A click on a link row opens its page, even with the caret in it. The title stays editable from the keyboard.
- The due chip's menu, and a date cell's menu in Table, have Remind me…. It offers At time, 15 minutes before, 1 hour before and 1 day before for a timed value, and On the day or 1 day before, both at 9:00, for a date-only one. Each writes `before`. "At a set time…" writes `at` on the start day. A set reminder shows in the menu, like "Reminder: 15 minutes before…", beside Remove reminder.
- Hovering a block shows a drag handle and a + at its left, 16pt each, at the existing sidebar hover timing.
- Paste of Markdown or HTML becomes blocks. Copy puts Markdown and rich text on the pasteboard.
- `@` opens a page picker and inserts a page mention.

### Board

- Columns are the options of the `group` field, in option order. A select, multi-select or checkbox field can group. A "No <field>" column comes first when any item lacks a value.
- Opening Board on a page without a select field adds a "Status" select with Not started, In progress and Done, and groups by it.
- Cards show the title, then up to three `show` fields, then the due chip. A to-do list's cards also show the checkbox.
- Dragging a card to another column sets its field. Dragging within a column reorders it, unless a sort is on.
- Each column ends with "+ New". The column header has a ⋯ menu for rename, color, hide and delete. A last "+" column adds an option.
- Columns are 260pt wide and scroll sideways.

### Table

- Rows are items, and columns are Title then `cols`. Rows are 32pt and only the visible rows exist, as the sidebar list recycles.
- A click selects a cell. Return or typing edits it, Return commits, Escape cancels, and Tab moves on. Checkbox cells toggle in one click.
- Header menus rename, change type, sort, filter, hide and delete a column. The last "+" header adds a field. Dragging a header edge resizes it.
- "+ New" sits under the last row.
- With a sort on, row drag is off and a hint says "Clear the sort to reorder".
- Changing a field's type converts values where it can, like text to select by matching option names, and clears the rest after a confirmation that names how many values are lost.

### Timetable

- A week grid. Columns are days from Monday, or Monday to Friday when `days` is 5. Rows are hours from `from` to `to` at 48pt an hour, and the grid scrolls for earlier and later hours.
- It places every item whose `field` date has a time, from `start` to `end`, or one hour long without an end, converted to the device's zone as "Date values" describes. Weekly items show in every week from their start date on. All-day items sit in a strip above the grid.
- Overlapping items share the column side by side.
- The header has "‹ This week ›" and "Today". Today's column header uses the accent.
- Dragging on empty grid creates an item for that range and focuses its title. Dragging an item moves it, its bottom edge resizes it, both snapping to 15 minutes.
- Opening Timetable on a page without a date field adds "When" and uses it.

## 5. Sidebar and navigation

Design direction: Space looks like the rest of Redesign, with its near-black chrome, the `#131314` panel, Hugeicons duotone icons and the user's accent. The one strong element is the page title, large with room around it. Everything else stays quiet: no cover images, no default emoji, no colored chrome beyond select options.

### The Space row

- One `SidebarNavRowView`, "Space", directly under Automations, before Settings, in `navRows` (SidebarView.swift:88).
- Its icon is a Hugeicons stroke-rounded notebook in Redesign's duotone. It needs adding to the icon set.
- It exists only with the toggle on and Redesign as the theme.

### Space mode

Tapping the row switches the sidebar into Space mode. The threads list, the Orchestrator row, the Threads label and the nav rows hide. The brand row and the account footer stay. From the top:

1. "‹ Threads", a 28pt nav row with a chevron-left icon. It returns to the threads sidebar and leaves Space tabs open.
2. "Space" at 15pt medium, at the 16pt left edge. At its right, like the Threads label's buttons, one 24pt Trash button.
3. A search row in the same style as the threads search, with the placeholder "Search pages".
4. The page tree, scrolling.
5. "+ New page", a 28pt row pinned above the account footer.

The switch is a 150ms crossfade, opacity only, and instant with Reduce Motion. The sidebar remembers the mode across launches.

The page tree:

- 28pt rows with a 16pt indent per level. A chevron shows on rows with child pages, then the icon, then the title truncated at the end.
- Items of a board, table or timetable don't show in the tree. Only pages whose parent shows in Page view do, so a 300-card board doesn't flood it.
- Hover shows + for a child page and ⋯ for Rename, Move to, Duplicate and Move to Trash. Duplicate copies the page, its child pages and their live blocks in one change, with fresh ids, fresh order keys in the same order and the same blob references.
- The open page's row uses the selected row token.
- Dragging reorders and nests with the drop line from `SidebarDitherDrag`.
- Expanded rows are remembered per device, not synced.

Trash opens as a tab listing trashed pages, newest first, with Restore and Delete forever. An untitled page with no text, values or pages inside stays out of the list, since it has nothing to restore. That covers the empty to-do a second Return removes when it ends a list. Delete forever asks first, then removes the page and the pages inside it for good, though their old text stays in the history log. Their images and files leave this Mac's blob cache unless a block of another page uses the same blob.

### Tabs and keys

- A page opens as a tab in the tab band, since Redesign's tabs are routes. The tab shows the page icon and title. The header pill's cost and diff controls hide on Space tabs.
- Entering Space mode with no Space tab open opens the last page, or a "No pages yet" empty view with a New page button.
- In Space mode, ⌘N makes a page instead of a thread, and ⌘P opens page search. ⌘P is T3's `filePicker.toggle` (Keybindings.swift:351), so Space takes the new-thread and file picker commands, whatever keys they're bound to, only while Space mode shows.
- Space pages never appear in the command palette, recent threads or the menu bar.

## 6. Reminders

Every device schedules its own reminders from its local copy with `UNUserNotificationCenter`, so they fire while the app is closed.

1. A reminder comes from any date value with `remind`, on any item that isn't Done or trashed.
2. The planner schedules the soonest 50 within the next 30 days as `UNCalendarNotificationTrigger` requests, since Apple caps pending local notifications at 64 per app. Weekly items schedule each week as its own request.
3. A timed reminder's date components carry the value's `tz`, so it fires at that moment wherever the device is. A date-only reminder's components carry no zone, so it fires at its wall-clock time in whatever zone the device is in.
4. It plans again when a change touches a date, Done or trash, when a reminder fires, when the app starts and when the system time zone changes. Each request id is `space.<pageId>.<fieldId>.<start>`, so planning again replaces requests instead of doubling them.
5. The notification's title is the item title, and its body is only the time, like "9:00", in the device's zone. No other Space text goes in, not even the parent page's title. A digest of the item in `userInfo` lets a later pass replace or withdraw requests whose text no longer matches.
6. Actions are "Mark done", which writes the change and syncs, and "Snooze 10 min", which stays on that device.
7. Clicking opens the item in Space.
8. `ThreadNotificationCoordinator` is the app's notification delegate, so it hands `space.` ids to the Space reminder controller.

Permission: setting the first reminder asks for notification permission if the user hasn't granted it. Turning Space off withdraws all `space.` requests and delivered notifications.

Both the Mac and the phone remind, as Calendar does. A reminder added on another device reaches this Mac when the pipe delivers it. The app keeps the pipe open while it runs, so only a Mac that was closed misses it, and the phone that set it covers that.

macOS stores pending and delivered notification text in its own database, outside CandyWrapper. An agent can't read it without Full Disk Access, but the user should know.

## 7. Images and attachments

- Images arrive by paste, drop or the `/` menu. Files arrive the same way as `file` blocks.
- Limits are 20 MB per image and 50 MB per file, checked before upload with a plain message.
- The app keeps the original bytes and also makes a preview at 1,600pt on the long edge as HEIC, so phones and lists don't fetch originals.
- A blob reference is `{"id", "preview", "name", "mime", "size", "w", "h"}`. `w` and `h` are for images only.
- A blob's id is the HMAC-SHA256 of its bytes under the blob-id key, as hex. It dedupes without letting the Space machine match a known file.
- Blobs encrypt in 1 MiB chunks. Each chunk's AAD is `cws1|<spaceId>|<blobId>|<n>|<last>`, with `n` counting from 0 and `last` written `true` or `false`, so chunks can't be reordered or cut short. An empty blob is one empty last chunk.
- Upload starts at once and the block shows progress. The change that adds the block is pushed after the blob's last chunk is acknowledged, so other devices never see a missing blob.
- Images render through the app's existing image pipeline, with shared decodes, release of hidden pixels and the expand and zoom viewer. Dragging an image's edge sets `width`.
- Opening a file in another app writes a decrypted copy to the app's temporary folder, deleted when that app's document closes or when CandyWrapper quits. That copy is readable while it exists, and the open action says so the first time.

The pipe is a slow road for big files: a 5 MB image is about 7 MB of base64 in 107 writes. The spike measures it. If it's too slow over T3 Connect, the fallback is T3's HTTP attachment upload of the encrypted bytes, moved into the Space folder by `space-serve`. That needs the user's approval, because it touches T3's attachment store.

## 8. Search

All search runs on the device, since the Space machine can't read anything.

- The sidebar's "Search pages" field matches titles as you type, and the tree filters to matches and their ancestors.
- Pressing Return, or typing three or more characters, adds content results under the title results: each shows the page title, a one-line snippet with the match in bold, and the breadcrumb.
- Matching ignores case and diacritics and matches word prefixes. All words must match.
- The index is the folded text of every title and block, held in memory and built off the main thread when Space first opens. Changes update it per record.
- ponytail: a linear scan of folded text. Add a trigram index if p95 passes 30 ms.

## 9. Undo and history

Undo:

- Each window keeps its own undo stack through `NSUndoManager`, grouped the way `NSTextView` groups typing.
- Undoing writes a new change that puts the old values back, so it syncs like any edit.
- Undoing the creation of a record trashes it, since records are never removed.
- If another device has changed a key since, undo leaves that key alone and does the rest.
- Undo covers block edits, moves, trash, field and view changes and item changes in every view.

History:

- "Page history" in the page's ⋯ menu, and the history button beside the view switch, lists versions, one per device per 10-minute stretch of edits counted from the stretch's first edit, like "Today 10:42 · MacBook".
- Picking one shows the page as it was, read only, built by replaying the local log up to that point.
- "Restore this version" writes one change that sets every block back, trashes blocks added since and restores blocks trashed since. It puts the title and icon back too. Child pages stay where they are, since history covers the page's own text. In Page view the change joins the editor's undo stack.
- Trash holds trashed pages until the user deletes them. Trashed blocks live on in history only.

## 10. Performance budgets

Target size: 2,000 pages, 100,000 blocks, 20,000 items and 2 GB of attachments. Measure with Release builds through `scripts/perf-review`, which gains a Space fixture at that size.

| What | Budget |
|---|---|
| Toggle off | No added memory, wakeups or launch time beyond reading one bool. |
| Toggle on, idle | 0 wakeups a second, 0% CPU, no timers. The pipe is silent. |
| Launch with Space on | Under 5 ms more main-thread time. Loading runs off the main thread. |
| Opening Space cold | Under 300 ms to the tree, decrypt and parse included. |
| Memory with Space open | Under 40 MB more at the target size. |
| Opening a 1,000-block page | First paint under 50 ms. |
| Typing | Key to glyph under 8 ms at p95 on a 1,000-block page. |
| Switching views | Under 50 ms for 1,000 items. |
| Table and Board scrolling and drag | No dropped frames at 5,000 rows or 500 cards. |
| Search | Under 30 ms at p95 over the target size. |
| Sync, both devices open | An edit shows on the other device within 1 s plus network time. |
| Page history | Under 2 s to list versions for 100,000 frames. |
| `space-serve` on the Space machine | Under 15 MB resident, 0% CPU while idle. |

## 11. Not in v1

- Sharing, guests, comments, publishing to the web.
- Any agent or AI access, and any AI feature.
- The Android app. The format and fixtures are ready for it.
- Other themes than Redesign.
- Several views of one type, month calendar, Gantt and list views.
- Formulas, relations, rollups, created and edited fields, inline databases inside other pages.
- Toggle blocks, callouts, simple tables, embeds, math, Mermaid, synced blocks, backlinks.
- Templates, cover images, page fonts and widths.
- Repeat rules beyond weekly, a time zone picker on dates, a moving "now" line in the timetable. A now line would need a timer, so today's column is tinted instead.
- Import from Notion and export. Markdown export is the likely first follow-up.
- Key rotation, account-based recovery, pruning history.
- Spotlight, widgets, Shortcuts, Quick Look.

## 12. Build plan

Fast pieces are plumbing, models, tests and file IO that a quick coder can do from this spec. Quality pieces are UI and tricky logic. Times assume one agent working with the existing code. Every piece ships behind the toggle with its tests, and AGENTS.md's limit of four agents at once applies.

| # | Piece | Tag | Time | Needs |
|---|---|---|---|---|
| 1 | Spike: `space-serve` over a hidden terminal on the sandbox server, measuring throughput through T3 Connect, raw tty, large writes, history and close. Also the Keychain access group on a Developer ID build. | quality | 1 day | nothing |
| 2 | Model types: records, rich text, date values, fields, view settings, order keys, JSON coding, golden fixtures in `fixtures/space/`. | fast | 1 day | nothing |
| 3 | Crypto and keys: HKDF, AES-GCM envelopes, AAD, blob chunking, check value, recovery key coding, Keychain item. | quality | 1 day | 1 for the Keychain choice |
| 4 | Apply and rebase: apply frames, the cycle rule, confirmed plus pending, rebase, three-way text merge, conflict copies, undo as inverse changes. | quality | 2.5 days | 2 |
| 5 | Host: `candywrapper-helper space-serve` with flock, JSONL log, revs, check and append, file watch fan-out, blobs, snapshots, `movedTo`. Mac and Linux builds. | fast | 1.5 days | 1, 2 |
| 6 | Local copy: encrypted snapshot, log and pending files, write before ack, blob cache with its 1 GB cap. | fast | 1 day | 2, 3 |
| 7 | Sync client: pipe lifecycle, hello and catch-up, push, ack and reject, reconnect, blob transfer, snapshot upload, seq regression check, restore and move. | quality | 2 days | 3, 4, 5, 6 |
| 8 | Fields, sort and filter engine, with type conversion. Pure logic and tests. | fast | 1 day | 2 |
| 9 | Search index and the reminder planner. Pure logic and tests. | fast | 1 day | 2 |
| 10 | Settings: the switch in the Experimental tab, setup, machine picker, helper install reuse, recovery key show and entry, QR, remove from this Mac. | quality | 1.5 days | 3, 7, and the Experimental tab |
| 11 | Sidebar Space mode: the row, mode switch, tree with drag, search results, + New page, Trash tab, page tabs, ⌘N and ⌘P. | quality | 2 days | 2, with an in-memory store until 7 lands |
| 12 | Page view editor on TextKit 2: blocks, shortcuts, `/` menu, item rows, mentions, paste and copy, undo grouping, conflict copies. | quality | 4 days | 2, 4 |
| 13 | Table view. | quality | 2 days | 8 |
| 14 | Board view. | quality | 1.5 days | 8 |
| 15 | Timetable view. | quality | 1.5 days | 8 |
| 16 | Images and files in pages: upload with progress, previews, the image pipeline, width drag, open in another app. | quality | 1 day | 6, 12 |
| 17 | Reminder notifications: requests, actions, delegate hand-off, withdrawal. | fast | 0.5 day | 9 |
| 18 | Page history and Trash views, restore. | quality | 1 day | 4, 11 |
| 19 | Full review: Space perf fixture in perf-review, the whole suite, code review, on-screen check on the sandbox with two app copies as two devices. | quality | 1 day | all |

About 28 agent-days in total. With four lanes at once it's about 9 working days:

1. Start 1, 2 and 8 together. 8 needs only the types from 2, so it starts once 2 has its first commit.
2. When 2 lands, run 4, 5, 9 and 11 in parallel.
3. When 3 and 4 land, run 6 and 12. Then 7, then 10 and 16.
4. 13, 14 and 15 run in parallel once 8 lands, alongside 12.
5. 17 and 18 fill gaps. 19 goes last.

A useful first milestone for the user to try is Space on this Mac only, with the Space machine set to the local one: pieces 2, 3, 4, 6, 11 and 12. It needs no pipe, so it ships before the sync work is done.

## Decided by the user on 2026-10-24

1. Recovery: losing every device and the recovery key loses Space, and that's acceptable. No passphrase-wrapped key goes on the Space machine.
2. Space is Redesign only, like the Orchestrator.
3. Reminder notifications show item titles.
4. Space uses the helper binary on miniko, with no service and no tokens.
5. Time zones follow other apps: timed values store their zone and show in the device's zone, date-only values stay on their date, and weekly slots stay tied to the zone they were made in. The exact rule is in "Date values".

The two spikes in piece 1 go to another agent.
