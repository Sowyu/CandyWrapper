# Space on this Mac

The first milestone in `space.md` section 12 uses the encrypted device copy as the local authority. It needs no helper, terminal, T3 surface or sync connection. Space is CandyWrapper's own feature, so no T3 behavior changes in this piece.

`SpaceLocalSetup` creates a Space id, device id and random K only when Space is enabled. K goes into the bundle-specific login Keychain service with `SpaceKeyStore`'s signed-app ACL. `Application Support/<bundle id>/Space/space.json` holds local setup metadata: the format header, key check, device id and recovery acknowledgment. It contains no key or page content. Each Space's encrypted copy remains under `Space/<spaceId>/`, using piece 6's format and crash journal. Setup writes and fsyncs its metadata after the initial encrypted files exist. A missing key, failed check or corrupt copy fails closed instead of substituting a blank workspace.

The first-run sheet offers Copy, I saved it and Turn Space off. It appears again after a restart until I saved it reaches disk. After acknowledgment it stays dismissed. Copy uses a clipboard restricted to this Mac. The full recovery-key reveal with authentication and the machine picker remain piece 10.

`PersistentSpacePageStore` implements `SpaceDocumentStore`, which adds blocks and undoable edits to `SpacePageStore` for the page editor (see `space-editor.md`). Its page edits appear immediately for the synchronous sidebar API. The sidebar says Saving until a serial task has persisted encrypted pending and atomically confirmed the frame with `SpaceLocalStore`. The local writer uses `SpaceReplica` and `SpaceState` for apply, rebase and revisions. Startup replays snapshot and confirmed frames, then resumes durable pending operations before showing pages. No plaintext journal, search index or cache is introduced.

Removing an optional field writes null through apply. Delete forever nulls every record key, so the typed page disappears while its encrypted history remains. Unknown keys survive typed reads and edits. The store queues observer-triggered edits in the same order as user edits and decodes only the pages each edit touches. Storage failures show Not saved, reject further edits and keep the optimistic text in memory. They never claim success. A normal quit drains queued writes; a failed drain cancels quitting.

Disabling Space removes its views, waits for queued writes, closes the local lock and drops decrypted state. It deletes neither the files nor the Keychain item. Re-enabling reads the same identity and copy. Nothing opens while the switch is off at launch.

## Verification

`PersistentSpacePageStoreTests` covers setup and the Keychain abstraction, first-run recovery acknowledgment across restart, save and reopen, disabling without deletion, nested pages, rename, move, trash and restore, unknown fields, optional-field removal, permanent removal, resuming durable pending, missing keys, corruption, observer edit order and storage failures. A recursive `/usr/bin/grep -R -a -l -F` scans every local file for a unique title and the recovery key and must return no matches. Unit tests use `SpaceKeyStore.inMemory()`; the isolated sandbox app uses its own real Keychain service. Signed-app ACL access remains covered by `scripts/space-keychain-test` from piece 3.

The isolated built app was checked against the sandbox on port 47391 with fake T3 Connect. Its real, bundle-specific Keychain item opened across a process restart. After acknowledgment the recovery sheet did not return. Both `Saved on this Mac` and `Plans stay private` returned in the tree and the last page opened after relaunch. Turning the switch off kept all seven local files byte for byte; turning it back on loaded the same pages. A second recursive grep of that app's actual Space folder found neither title. The recovery key was never captured in a screenshot.

Screenshots outside the repository:

- `~/CandyWrapper-research/notes/space-local-wiring/before-relaunch.png`
- `~/CandyWrapper-research/notes/space-local-wiring/after-relaunch.png`
- `~/CandyWrapper-research/notes/space-local-wiring/disabled.png`
- `~/CandyWrapper-research/notes/space-local-wiring/reenabled.png`

A ten-second settled sample with Space open measured 0.07% CPU, zero package idle wakeups per second, 0.50 interrupt wakeups per second and 45.1 MB footprint. This is a shared-machine sample, not a controlled comparison. `idle.txt` sits beside the screenshots. The screen lock was returned and only the test app's own PIDs were stopped.

All seven focused persistence tests passed. The full suite, with parallel testing disabled to avoid the existing shared-theme interference, passed 2,097 Swift Testing tests and 18 XCTest tests with zero failures. The final fast lane also checks the last review change, which limits typed-page decoding to the records an edit touches. The code review covered Keychain and setup ordering, authenticated replay, optional-key removal, observer edit ordering, the quit drain and failure handling. It found and fixed the detached Settings sidebar's missing sheet parent and moved the Space drain ahead of the server's asynchronous quit approval. No protocol shape, fidelity reference or ceiling changed.

The final fast lane passed 1,916 Swift Testing tests and 18 XCTest tests with parallel testing disabled. It includes all seven persistence cases after the final publication optimization. No test ceiling or reference changed.

The [combined performance review](perf/2026-10-24-space-local-wiring-w1.md) records the launch, idle, large-thread and open/reopen scenarios plus all 43 existing micro-benchmarks against the last saved run, `6f6f14b`. Both original quiet waits expired after 600 seconds because other builds and test apps were active. Remaining app waits were capped at zero, keeping the same metrics and thresholds and recording every sample as noisy. The benchmark launcher tried to rebuild after its completed Release build, so the final measurement used `scripts/test -c release -Xswiftc -enable-testing --skip-build --filter PerfBenchmarks` with `CW_BENCH=1`. A process-path probe confirmed the Release test bundle. Raw separate reports remain beside the screenshots under `app-review/` and `bench-review/`.

The noisy app sample measured 0.098% idle CPU and 42.0 MB footprint. The latest baseline has no app values, so it supplies no app regression verdict. Forty-one of 43 micro-benchmarks exceed their thresholds. These results remain unresolved, not a clean performance pass: a quiet same-code/base control is needed for attribution. The protocol parser and benchmark sources are unchanged from the baseline; the intervening store change is the separately landed Orchestrator handoff fix. The new Space store is not exercised by these existing micro-benchmarks. Its large-workspace fixture remains piece 19.
