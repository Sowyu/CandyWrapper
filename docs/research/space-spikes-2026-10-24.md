# Space prerequisite spikes

2026-10-24. Both primary choices fail the prerequisite gate as currently specified. Small changes work well over the terminal, but unpaced bulk downloads lose data. The strongest Keychain option cannot run with the current release signing setup. Use the spec's login Keychain ACL fallback; request the user's approval before implementing its encrypted HTTP attachment fallback for blobs.

No shipping source, package target, release setting, real account or live T3 data changed. The probes live in `scripts/spikes/space/`. Reproduction commands are in its README. Aggregate machine-readable evidence is in `space-spikes-2026-10-24.json`.

## Terminal transport: fail

Environment: Mac mini M4, arm64, macOS 27.0.1 (26A434), isolated T3 `0.1.2-nightly.20261021.3473` sandbox. The peer execs inside a hidden terminal whose thread id is `candywrapper-space`; no actual T3 thread or project is created. Raw tty and echo-off both verified.

The peer is a throwaway Python implementation of the proposed `space-serve` wire path, not a new helper command. It accepts base64 JSON lines, reassembles 65,536-character writes, stores ciphertext, fsyncs, and acknowledges. Each 1 MiB encrypted image chunk is checked by SHA-256 at upload; successful downloads are compared byte for byte. AES-GCM fixture decryption was checked before transmission. The keys never cross the terminal.

### Small changes

One warmup, then 100 changes containing 300 random ciphertext bytes. Times include the terminal write, host log append and fsync, and returned application ack.

- Local: median 0.353 ms, p95 0.422 ms, maximum 0.509 ms.
- Substitute remote link: median 106.186 ms, p95 107.268 ms, maximum 108.355 ms.

The terminal is suitable for this small-message round trip. This does not measure two-device fan-out, editor debounce or the production host's resource budget.

### Image transfer

Sizes mean MiB (1,048,576 bytes), slightly larger than decimal MB. Each fixture is a valid 512 by 512 PNG padded to the exact byte count, encrypted in 1 MiB chunks with 28 bytes of AES-GCM overhead per chunk. Encryption makes the wire bytes incompressible.

Local:

- 1 MiB: upload 0.116 s, 8.606 MiB/s; download 0.098 s, 10.205 MiB/s; bytes match.
- 5 MiB: upload 0.598 s, 8.360 MiB/s; download 0.348 s, 14.371 MiB/s; bytes match.
- 20 MiB: upload 2.376 s, 8.417 MiB/s; download fails after 0.917 s with only 6 of 20 complete chunks. No completed-file download throughput can be reported.

Substitute remote link, modeled 100 ms RTT and 10 Mbps in each direction:

- 1 MiB: upload 4.639 s, 0.216 MiB/s; download 2.845 s, 0.352 MiB/s; bytes match.
- 5 MiB: upload 23.109 s, 0.216 MiB/s; download fails after 0.615 s with 0 of 5 complete chunks and 122,880 output characters received.
- 20 MiB: upload 92.532 s, 0.216 MiB/s; download fails after 0.615 s with 0 of 20 complete chunks and 122,880 output characters received.

All uploads completed with matching ciphertext hashes. Download failure means the global terminal subscription returned RPC `Exit Success` before all requested bytes arrived. The code detects that as failure; an RPC success does not prove a complete blob.

The actual upload framing needs 29, 145 and 580 terminal writes respectively, carrying 1,864,357, 9,321,801 and 37,287,220 characters. The spec's illustrative 107 writes for 5 MB understates this: ciphertext is already base64 inside JSON, and the proposed frame adds outer base64. This probe uses one outstanding `terminal.write` RPC at a time. Pipelining could improve upload speed, so these are measurements of this conservative implementation rather than a ceiling on the terminal's best possible throughput. It would not supply the missing application-level download flow control.

### Why bulk download fails

The host responds to `blob.get {id}` with all chunks, with no application-level acknowledgement between chunks. T3 acknowledges WebSocket stream chunks, but its output queue remains bounded and the PTY producer can outrun it. Read-only source evidence at the pinned T3 tag:

- `packages/contracts/src/terminal.ts:64-66` caps each write at 65,536 characters.
- `apps/server/src/terminal/OutputProtocol.ts:9-13` sets the outstanding stream window to eight chunks or 64 KiB.
- `apps/server/src/terminal/OutputProtocol.ts:74` caps queued output at 8 MiB; `:129-134` releases an overflowing subscription.
- `apps/server/src/terminal/OutputProtocol.ts:172-174` ends an overflowing stream without a resync function.
- `apps/server/src/ws.ts:2889-2890` gives the global subscription no resync function. `:2870-2875` gives attach a history resync, which cannot recover a 20 MiB blob from an 8 MiB tail.
- `apps/server/src/terminal/Manager.ts:95-99` caps history at 5,000 lines and 8 MiB and persists after a 250 ms debounce; `:1958` removes history on close.

History measured exactly 8,388,608 bytes after every run. Local close took 10.102 ms; substitute closes took 122.310 and 122.760 ms. All three closes removed their history files and stopped their exact peer PIDs. No additional terminal output arrived during a two-second idle observation; this is not a CPU or wakeup measurement.

### T3 Connect limitation and fallback

The fresh sandbox reports `linked: false` and has no configured Connect session. Linking requires a real Clerk account credential (`apps/web/src/cloud/linkEnvironment.ts:295-349`), while AGENTS.md forbids tests signing in to real accounts. No account credentials were borrowed, and no real T3 Connect tunnel was tested.

The closest measured path was a loopback TCP proxy with 50 ms one-way propagation and a 10 Mbps ceiling per direction. Propagation and transmission overlap; all measured WebSocket requests, stream acks and output cross it. Auth HTTP remains local and outside the timing. This is a deterministic latency/bandwidth model, not Internet or Connect evidence. The modeled limit alone would carry 20 MiB of ciphertext over raw HTTP in about 16.8 seconds before overhead; that is arithmetic, not an HTTP fallback benchmark.

Verdict: fail on incomplete blob delivery, without inventing an image speed threshold the spec never supplied. Keep the terminal for small encrypted changes. For blobs, use the section 7 fallback: T3 HTTP attachment upload of encrypted bytes, moved by `space-serve` into the Space folder. This requires the user's approval because it touches T3's attachment store, and it has not been implemented or benchmarked here. Its download path must also be defined and checked. An alternative would need a specified bounded application-level blob protocol and a new spike; a sleep between chunks would not establish reliable delivery. A real Connect run remains required before claiming that gate passes.

## Strongest Keychain protection: fail

The spec says Developer ID, but the actual release script uses `Apple Development`, Team `8Q677AYRU7` (`scripts/release:23-27`). It strips executables and signs with `--options runtime --timestamp=none` (`:131-143`). There is no release app entitlement file or provisioning profile in this checkout. The spike matches that actual setup, without changing it, using an arm64 `-Osize` binary stripped before signing. Every signed variant passed `codesign --verify --strict`, reported the requested team, and had the hardened runtime.

The requested item is a synthetic 32-byte generic password, `kSecAttrSynchronizable: false`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecUseDataProtectionKeychain: true`, with the explicit access group `8Q677AYRU7.dev.candywrapper.space-spike`.

- Current release-style signing, without restricted entitlements: add and read both return `-34018` (`errSecMissingEntitlement`). Add takes 0.164 ms; read takes 0.144 ms. No key is stored.
- Signed with application identifier, team identifier and keychain access-group entitlements: the OS kills the process with signal 9 before its entry point.
- Signed with only `keychain-access-groups`: also killed with signal 9. The failure is not merely caused by an unnecessary application-identifier entitlement.
- The system log explicitly reports `Disallowing ... because no eligible provisioning profiles found` and AMFI `No matching profile found`. Signing and static verification succeed; executable launch is where provisioning enforcement fails.

This does not prove that a properly provisioned future Developer ID build would fail. It proves that the strongest option cannot be added to the current release setup unchanged.

### Login Keychain ACL fallback: pass

A separate run drops data protection and the access group and supplies a `SecAccess` ACL with only the signed probe as a trusted application. It keeps the non-synchronizable, device-only item options.

- Add returns 0 in 12.491 ms; reading the exact 32 bytes returns 0 in 1.242 ms.
- A fresh process of the same signed binary reads successfully and gets the exact key.
- An ad hoc binary with a different identifier is denied: `-25293` (`errSecAuthFailed`), no key bytes.
- A different app identifier signed with the same Apple Development team is also denied: `-25293`, no key bytes.
- Interaction is disabled for all probe processes. Thus these checks verify denial without approval; they deliberately do not exercise a user approval prompt.
- The authorized binary deletes the synthetic item successfully (0).

Use the section 3 fallback: the file-based login Keychain with an explicit ACL trusting only CandyWrapper's signed designated requirement. The access-control test passed with this release identity; never rely on a team partition alone or an unqualified generic-password query. A production implementation still needs normal update continuity and user-prompt behavior checked as part of its own work.

## Verification and cleanup

Both Swift programs compiled with optimization. The image fixture round trips authenticated encryption; macOS ImageIO tools recognized the PNG. All Python files parsed, the signing shell script passed `zsh -n`, and the diff was reviewed for shipping-path and secret changes. No app test suite or app performance review was run because no app or package code changed.

Only the probe-owned sandbox server and proxy were stopped. Their terminals were closed with history deletion, test Keychain items were deleted, the release keychain was relocked, and all private working fixtures and signed binaries were removed. No app was launched, no release was made, and nothing was pushed.
