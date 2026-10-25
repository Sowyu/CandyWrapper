# Fast-load sandbox benchmark

This harness measures CandyWrapper's real `EnvironmentHTTP`, `ConnectionSupervisor`, RPC socket, shell store and thread store. It links no AppKit target or Features module. It measures reducer data readiness and protocol synchronization, not layout or UI first paint.

Everything lives under `$HOME/CandyWrapper-research/sandbox/fast-load`. The installed runtime and the user's T3 home stay untouched. Server processes receive a clean environment and an explicit `--base-dir`. No provider commands, turns or real account sign-in are needed.

## Servers and data

The 3473 binary is the separately downloaded `CandyWrapper-research/runtimes/t3-0.1.2-nightly.20261021.3473-darwin-arm64/t3`. Main runs directly from an independent source archive at `source-main/apps/server/src/bin.ts`, using `/opt/homebrew/bin/node` (26.11.1 in the measured setup).

The source archive is exact upstream main `5b35402623d7d1d88eaa472807272a6c2e78012a`, verified against `git ls-remote origin refs/heads/main`. The published 3669 release targets `5f64c5eb299a23d278ef043c416bd4dc801bc53c` and differs in server files. It is not substituted for main.

To prepare that source without changing another agent's checkout:

```sh
bench="$HOME/CandyWrapper-research/sandbox/fast-load"
mkdir -p "$bench/source-main"
git -C "$HOME/CandyWrapper-research/t3code" archive 5b35402623d7d1d88eaa472807272a6c2e78012a | tar -x -C "$bench/source-main"
cd "$bench/source-main"
CI=true npm exec --yes pnpm@12.14.0 -- install --frozen-lockfile --ignore-scripts --store-dir "$bench/pnpm-store"
```

Check disk space first. The unfiltered workspace install uses several GB; remove the task's isolated store after installation to reclaim copies not retained by installed hard links. The server source needs production workspace dependencies plus contracts/shared/SSH/Tailscale and the MCP SDK. The measured setup pruned unrelated workspace development dependencies after installation. Recheck `scripts/preflight` before building.

`manage.py start` initializes missing sandbox databases. Then stop, seed and restart:

```sh
python3 scripts/fast-load/manage.py start
python3 scripts/fast-load/manage.py stop
python3 scripts/fast-load/seed.py > "$bench/dataset.jsonl"
python3 scripts/fast-load/manage.py start
```

The deterministic fixture has 1,301 threads: 81 ordinary active threads, 1,000 old settled threads, 200 idle subagent children and 20 active children. The big thread has 482 messages and 1,322 timeline rows, including a final agent-created run with 600 tool/reasoning rows and run/attempt/root-node controls. It covers the 75-row agent window and both shell omission policies. Both server homes get the same payload hash and expected fully paged message hash.

Startup reconciliation cancels persisted running rows. After readiness, `manage.py` restores only synthetic child read-model rows to running. It adds no command, event or outbox entry, so the engine cannot dispatch provider work. Main's omitted shell retains exactly those 20 active children and excludes the 200 idle children.

Ports are fixed to avoid accidental use of live services:

| Server | Direct origin | Throttled client | Counter control |
| --- | --- | --- | --- |
| 3473 | 47441 | 47541 | 48541 |
| Exact main | 47442 | 47542 | 48542 |

## Build and run

Use an isolated checkout of old client `8c8e6d3026128894bd48b6d410320fdf0ab4c16b`. The standalone Swift package chooses that checkout through its package dependency, rather than simulating old behavior in new code:

```sh
CANDY_BENCH_PACKAGE="$bench/client-baseline/Packages/CandyKit" scripts/fast-load/build /tmp/cw-fast-load-baseline
CANDY_BENCH_HTTP_FIRST=1 CANDY_BENCH_FAST_WIRE=1 CANDY_BENCH_SHELL_FIRST=1 scripts/fast-load/build /tmp/cw-fast-load-final
python3 scripts/fast-load/run.py 3473 --binary /tmp/cw-fast-load-baseline/release/candy-fast-load --label old-3473
python3 scripts/fast-load/run.py main --binary /tmp/cw-fast-load-baseline/release/candy-fast-load --label old-main
python3 scripts/fast-load/run.py 3473 --binary /tmp/cw-fast-load-final/release/candy-fast-load --label new-3473
python3 scripts/fast-load/run.py main --binary /tmp/cw-fast-load-final/release/candy-fast-load --label new-main
```

Wait until other compiler/test/performance processes are quiet before timing. A fresh benchmark process gives a cold client with no disk cache; the isolated server remains warm. A second connection retains the same stores and cursors. The new mode mirrors `ShellSession.prepareShell/subscribeInput/receive` from `a67b58ba` and uses the real `ThreadSnapshotLoader` and subscription-scoped `ThreadStore.applyWire` from `e97c2666`. Config is requested once per generation; omission flags govern both shell HTTP and the stream. The harness copies only the session orchestration because the AppKit session target cannot link into a Foundation-only executable.

Each JSON result records first thread projection, first shell projection, both streams synchronized, content checks and phase-specific wire bytes. Retained data is available immediately; reconnect synchronization is a separate measurement. A third, untimed correctness stage pages all history over the direct isolated origin. Its bytes are excluded from constrained-load measurements. Compare its full visible-message hash against `dataset.jsonl`, including all 482 messages and zero blank message items. Initial windows may legitimately differ between server versions.

## Link and encoding checks

The proxy limits aggregate TCP payload to 50,000 bytes/s per direction, with a queued 200 ms one-way delay. This is 400 decimal kbit/s and 400 ms RTT. It counts compressed HTTP/WS bodies, framing and HTTP headers, excluding TCP/IP overhead and retransmissions. The unthrottled control port snapshots delivered counters at every phase boundary, including persistent HTTP connections.

Calibration on one persistent HTTP connection delivered two 100,000-byte bodies in 2.408 and 2.407 seconds, with exactly 100,043 downstream bytes per response. Both response headers were observed.

`proxy.jsonl` records only selected encoding/length/upgrade headers. Authorization, cookies and WS ticket query strings are excluded. Both server versions were observed accepting URLSession's `Sec-WebSocket-Extensions: permessage-deflate` with the same extension in the 101 response. HTTP bounded requests sent `Accept-Encoding: gzip, deflate` and received `Content-Encoding: gzip`.

Source references at exact main: `apps/server/src/server.ts:320` enables per-message deflate; `packages/client-runtime/src/state/boundedThreadSnapshotHttp.ts:18` defines the HTTP timeout and `:33` requests compact/deduplicated bodies and IDs; `apps/server/src/orchestration-v2/threadHistoryPaging.ts:15` defines the 75-row agent window.

## UI grant and cleanup

The parent requested temporary token files for its sandbox UI validation. Create them privately with:

```sh
python3 scripts/fast-load/run.py 3473 --token-file "$bench/3473/session.token"
python3 scripts/fast-load/run.py main --token-file "$bench/main/session.token"
```

This writes only the fixed isolated path with mode 0600 and never prints the grant. Launch the isolated test app with the direct or throttled origin, its matching token file and `--fake-t3-connect`. Keep UI traffic out of the timed benchmark window.

After the parent's UI check, `python3 scripts/fast-load/manage.py stop` stops only recorded PIDs whose command still matches these sandbox paths. Delete the temporary token files and task-created Swift scratch folders. Remove the baseline checkout with `git worktree remove` when finished. Keep committed, scrubbed measurement results; sandbox trace logs, databases and credentials stay outside the repo.
