# Space local copy

Piece 6 of [the Space plan](space.md#12-build-plan) lives in CandyKit's `SpaceLocal` module. It depends on `SpaceModel` and `SpaceCrypto`, with no app, UI, apply/rebase or transport dependency. Nothing creates it on the app's launch path. The owner opens it off the main thread when Space opens, passes keys from `SpaceKeyStore`, and calls `close()` before reopening or discarding it.

## API

- `SpaceLocalStore.directory(applicationSupport:spaceID:)` adds `Space/<spaceId>` to the caller's bundle-specific Application Support directory. Test apps supply their own directory.
- `load()` returns a decoded `SnapshotPayload`, the `LogFrame`s after it, and pending operations. The caller applies records and overlays pending changes. The store never runs the apply/rebase engine.
- `replacePending(_:)` persists the complete pending queue, including each operation's payload, record bases and opaque JSON rebase context. Await success before presenting an edit as saved or sending it to a host.
- `confirm(_:)` authenticates a wire frame through `SpaceCrypto`, requires the next consecutive seq, appends it and removes a matching pending operation in one durable transaction. A repeated identical frame still in the log succeeds without another write. A pending operation with different content or bases fails. Await success before acknowledging local persistence. In local-machine mode the caller assigns the frame's seq and uses the same method.
- `saveSnapshot(_:)` saves confirmed state supplied by the caller, drops local frames through its seq and keeps later frames and pending edits. It also accepts an initial downloaded snapshot. Snapshot seqs cannot go backwards.
- `checkRemoteSequence(_:)` refuses a server seq below the durable highest confirmed seq. `payload(of:)` opens a wire frame for the caller's reducer.
- `cacheBlob(_:id:)` verifies the keyed blob id, encrypts and caches bytes. `cachedBlob(id:)` returns authenticated bytes in memory or nil for a miss; corruption throws. `cachedBlobBytes()` reports ciphertext bytes.
- `close()` releases the directory lock and drops the decoded state. A closed store rejects further work. Any failed durable mutation also requires closing and reopening, so recovery runs before the caller can rely on state again.

## Local format

This is a device format, separate from the shared host format and its golden fixtures. Every content file uses the `cws1 local` key. Each envelope is base64 of the random nonce, ciphertext and GCM tag from `SpaceEnvelope`. Its AAD is UTF-8 of `cws1|<spaceId>|local|<purpose>`.

| File | Encrypted contents | Purpose |
|---|---|---|
| `snapshot.cws` | Compact `SnapshotPayload` JSON | `snapshot` |
| `log.cws` | One envelope per line, each containing a complete compact wire `LogFrame` | `log|<seq>` |
| `pending.cws` | JSON with `confirmedSequence` and `operations` | `pending` |
| `transaction.cws` | An unfinished transaction's ciphertext replacements and append offset/bytes | `journal` |
| `cache.cws` | Blob sizes, a logical access clock and access order | `cache` |
| `blobs/<id>.cws` | One envelope per line, each holding at most 1 MiB of original bytes | `blob|<id>|<n>|<last>` |

Encrypting the whole log frame also hides its seq, device, operation id and record bases. Its inner `ct` retains the ops-key ciphertext, so callers can retransmit the original wire frame. No shared frame type or host format changes. A log reader authenticates each position, requires consecutive seqs and checks the final seq against `pending.cws`; removed complete lines, reordered lines and partial trailing lines fail closed.

Blob ids remain keyed HMAC hex filenames. Chunk AAD authenticates the expected position and the final chunk, and a read also verifies the full blob's HMAC. Empty blobs have one empty final chunk. Names, MIME types and other attachment metadata belong to encrypted records, never filenames.

The empty `lock` file is the process-lock target. Directories have mode 0700 and files have mode 0600. Temporary files contain ciphertext only. No key, plaintext, thumbnail, decrypted file or search index is written here.

## Durability and recovery

An exclusive, nonblocking `flock` admits one writer for each directory across actors and processes. File writes use an exclusive temporary file in the destination directory, `FileHandle.synchronize()` (fsync), POSIX rename and fsync of the parent directory. Directory creation also syncs its parent.

State changes first publish and fsync an encrypted redo journal. Confirmation records the old log length, the encrypted append and the new encrypted pending file. The store truncates to that length, writes and fsyncs the append, replaces and fsyncs pending, then removes the journal and fsyncs its directory. A checkpoint journals replacements for snapshot, log and pending together. Only then does the method return success.

On opening, a valid journal replays before any state is returned. Replaying the same append first truncates to its recorded offset, so repeated crashes cannot duplicate it. Interrupted temporary files are discarded. A damaged journal, wrong key, missing required state file or authentication failure throws without returning partial state. Complete replay of an older set of authenticated files cannot be detected using only those same files; the durable seq check detects a regressing host and an incompletely rolled back local log.

The blob cache is disposable, so it needs no content journal. It deletes and syncs victims before staging a new blob, syncs that blob before indexing it, and atomically saves the encrypted index. Recovery removes unindexed blobs and temps and drops missing entries. A crash can cause a cache miss. It cannot expose a partial blob as valid.

## Cache limit and checks

The cap is 1,000,000,000 bytes of blob ciphertext, including base64, newlines, nonces and tags. Index and recovery metadata live outside `blobs/`. Inserts compute the encrypted size before writing, reject a blob that cannot fit and evict the least recently used blobs first. Reads and inserts advance the encrypted logical clock, which survives restart and gives deterministic order without timers or wall-clock timestamps. Tests may lower the cap; callers cannot raise it.

`SpaceLocalTests`, `SpaceBlobCacheTests` and `SpaceRecoveryTests` interrupt initialization, pending changes, confirmation, checkpoints, insertion, eviction and recovery itself at every write boundary. They cover half-written files, rename/fsync boundaries, wrong keys, ciphertext mutations, blob reordering/truncation/substitution, lost log tails, writer exclusion, restart order and a sparse-file test just past the actual 1 GB limit. A recursive `/usr/bin/grep` scans snapshot, pending, journal, cache, blobs and interrupted temporary files for a known plaintext and must find none.
