# Space prerequisite probes

These throwaway programs are outside all app and package targets. They use only synthetic data and sandbox servers. Results and decisions: `docs/research/space-spikes-2026-10-24.md`, with aggregate measurements in the adjacent JSON file.

## Prepare the fixtures and server

Run from the repository root. The default ports must be free. Do not reuse a live T3 home. The server script starts T3 with a clean environment.

```sh
scripts/preflight
probe="$HOME/CandyWrapper-research/sandbox/space-spike"
mkdir -p "$probe/fixtures"
/usr/bin/python3 scripts/spikes/space/make-images.py "$probe/fixtures"
xcrun swiftc -Osize scripts/spikes/space/fixtures.swift -o "$probe/fixtures/encrypt"
"$probe/fixtures/encrypt" "$probe/fixtures"
SANDBOX_DIR="$probe/server" SANDBOX_PORT=47393 scripts/sandbox-server
```

The PNGs are exactly 1, 5 and 20 MiB. They contain random pixels plus a private ancillary padding chunk; encryption makes their original compressibility irrelevant to the transport. `fixtures.swift` encrypts each in 1 MiB AES-GCM chunks and verifies decryption before discarding the synthetic key. Only ciphertext reaches the host.

## Measure the terminal

```sh
probe="$HOME/CandyWrapper-research/sandbox/space-spike"
binary="$HOME/.t3/runtime/versions/$(sed 's/^v//' T3_VERSION)/t3"
/usr/bin/python3 scripts/spikes/space/transport.py \
  --server-home "$probe/server/t3home" --binary "$binary" \
  --work "$probe/local" --label local
```

The driver mints and redeems a sandbox pairing code with a clean CLI environment. It holds the bearer and WebSocket ticket in memory, never in argv or a token file. It opens `candywrapper-space`, execs the Python `space-serve` peer, sends a warmup and 100 small changes, then uploads and downloads images. It verifies hashes and bytes, measures history, and closes with `deleteHistory`. Each terminal write waits for its RPC result; each image chunk waits for a durable host ack. Download asks for all chunks, as the spec's `blob.get {id}` does. The peer has no application-level download ack or throttle.

If a bulk download ends the terminal stream, that is a failed download, and the driver stops that run. Use `--sizes 20 --text-count 0` in a fresh work folder to measure the remaining size. Every run writes its results into its work folder.

For the substitute remote path, start this in a separate background process and retain its PID:

```sh
/usr/bin/python3 scripts/spikes/space/proxy.py --rtt-ms 100 --mbps 10
```

Add `--ws-base http://127.0.0.1:47394` to the transport command and use a different work folder. The proxy delays both directions by 50 ms and caps each at 10 Mbps, with propagation and serialization overlapped. HTTP authentication stays local; all measured terminal RPC and output frames traverse the proxy. This is a loopback network model, not T3 Connect. A real sandbox tunnel may instead be supplied with `--ws-base`, once linked by an authorized flow.

## Measure Keychain access

```sh
probe="$HOME/CandyWrapper-research/sandbox/space-spike"
scripts/spikes/space/sign-keychain "$probe/keychain"
/usr/bin/python3 scripts/spikes/space/run-keychain.py "$probe/keychain"
```

The signer follows `scripts/release`: arm64 optimized executable, stripped, Apple Development identity, Team `8Q677AYRU7`, hardened runtime, no timestamp and no provisioning profile. It briefly unlocks and relocks the release keychain through the existing release flow, without changing its settings. It creates four independently verified binaries: plain, full app/access-group entitlements, access-group-only entitlements, and another app identifier on the same team. An ad hoc outsider supplies a further negative control.

The runner uses the GUI user's security session and disables Keychain interaction, so a denied reader cannot open a prompt. It tests a synthetic 32-byte, non-synchronizable, device-only key with data protection plus an explicit app group; then the login Keychain with an explicit `SecAccess` ACL trusting only the probe. A new process verifies authorized reading; different app identities try reading with UI disabled. Finally it deletes the test item. Failure statuses and signals are expected probe outcomes, not runner failures.

## Clean up

After copying the non-secret results, stop only the proxy and sandbox server PIDs you started. The driver closes its own terminals and deletes their history. Remove your `sandbox/space-spike` folder, including the encrypted fixtures and signed binaries. Do not stop an already-running sandbox you merely reused.
