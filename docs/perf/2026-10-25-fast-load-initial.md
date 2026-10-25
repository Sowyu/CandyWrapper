# Initial fast-load diagnostic on 3473 and exact main

This first pass exposed an extra config read. The subsequent fix shares the app's existing config stream. The final matrix also includes the same existing config and lifecycle streams in both clients. Keep these diagnostic measurements separate from the final results.

Three rounds of the four-cell matrix finished on 2026-10-25 at 16:08:49 UTC. Every cell synchronized and recovered the complete synthetic history. There was no compiler/test overlap. This measures real CandyWrapper client/store data readiness and protocol synchronization, not UI first paint.

The new client improves main's cold shell-plus-thread readiness by 5.6% and reduces its cold downstream traffic by 10.4%. It regresses that readiness on 3473 by 7.5%, and reconnect synchronization by about 37% on both servers. These results do not support an unconditional fast-load win.

## Setup and scope

- Old client: `8c8e6d3026128894bd48b6d410320fdf0ab4c16b`, built from its own checkout.
- New client: `d7b31a40de11895fce12c7375a9094a50f19e2a0`. Its T3Protocol, T3Transport, T3Client and T3Store sources match parent implementation `0bc18ce0` exactly. It includes the subscription ownership guard and final shell changes.
- Old runtime: separate downloaded `0.1.2-nightly.20261021.3473` binary, never installed or substituted into the user's runtime.
- Main: exact `5b35402623d7d1d88eaa472807272a6c2e78012a`, checked twice against upstream `refs/heads/main`. An independent source archive ran directly under Node 26.11.1. The published 3669 release differs in server files and was not substituted.
- Link: 400 decimal kbit/s aggregate per direction, 400 ms RTT, over a loopback counting proxy. Two 100,000-byte persistent-HTTP calibration responses took 2.408 and 2.407 s, with 100,043 downstream bytes each including headers.
- Fresh client process and no disk caches for each cold run; warm isolated server. The second connection retains the same stores/cursors. No provider turns or real accounts. T3 starts with a clean environment and explicit sandbox `--base-dir`.

The executable links the actual EnvironmentHTTP, URLSession RPC socket, ConnectionSupervisor, ThreadSnapshotLoader, ShellStore and ThreadStore. It mirrors the AppKit shell session's negotiated HTTP bootstrap, since that session itself cannot link into a Foundation-only executable. Thread HTTP bootstrap and wire restoration use the package implementation directly. Unrelated app boot subscriptions and rendering are outside this benchmark. The negotiated shell's config read is included.

The identical fixture has 1,301 threads: 81 ordinary active threads, 1,000 older settled threads, 200 idle subagent children and 20 active children. The big thread has 482 messages and 1,322 rows, including a final agent-created run with 600 tool/reasoning rows and run/attempt/root-node controls. It exercises the new agent window and both shell omission policies. Main retains exactly the 20 active children when omitting idle children.

Fixture payload hash: `c869e9cb80b913c35c708fbd336316ac384404d57fc6adb49e7dd5457e341fef`. Both homes match. The fixture is synthetic, not a reproduction of any user's thread or another benchmark's claimed factors.

## Cold load

All numbers below are medians of three runs. Ready means both the shell and initial bounded thread projection have reached their stores; synchronized additionally waits for both stream completion markers. Byte totals are delivered compressed TCP payload, including HTTP/WS headers and framing, excluding TCP/IP overhead. HTTP and socket are reported separately.

- **3473, old client:** both ready **10.234 s** (10.163–10.241), thread 9.566 s, shell 10.234 s; synchronized **10.584 s**. Down **406,092 B** = HTTP 1,379 + socket 404,713. Up **2,281 B** = HTTP 1,309 + socket 972.
- **3473, new client:** both ready **11.002 s** (10.996–11.050), thread 11.002 s, shell 4.778 s; synchronized **11.425 s**. Down **425,029 B** = HTTP 406,350 + socket 18,679. Up **4,380 B** = HTTP 3,361 + socket 1,019.
- **Main, old client:** both ready **3.453 s** (3.437–3.488), thread 2.769 s, shell 3.453 s; synchronized **3.854 s**. Down **71,424 B** = HTTP 1,361 + socket 70,063. Up **2,266 B** = HTTP 1,309 + socket 957.
- **Main, new client:** both ready **3.260 s** (3.231–3.266), thread 3.197 s, shell 3.260 s; synchronized **4.100 s**. Down **63,967 B** = HTTP 45,215 + socket 18,752. Up **4,446 B** = HTTP 3,400 + socket 1,046.

The 3473 sidebar reaches its store 53% sooner with HTTP bootstrap, while the combined readiness is later. On main, combined readiness improves slightly, while protocol synchronization is 6.4% later. On 3473, cold downstream grows 4.7% and protocol synchronization is 7.9% later.

The initial 3473 thread window contains 632 rows and 22 message items; main contains 75 rows and one message item. Main's old-client shell has all 1,301 threads, while the new client has 126 after negotiated omissions. Both 3473 clients have 1,301. Thus the fixture actually covers the changed row bound and omission policies.

## Retained reconnect

Both projections are already available from the stores in every retained case. The numbers here measure network synchronization, not perceived content availability.

- **3473, old client:** synchronized **2.154 s** (2.154–2.166). Down **2,026 B** = HTTP 1,379 + socket 647. Up **2,300 B** = HTTP 1,309 + socket 991.
- **3473, new client:** synchronized **2.959 s** (2.958–2.981). Down **20,092 B** = HTTP 1,379 + socket 18,713. Up **2,351 B** = HTTP 1,309 + socket 1,042.
- **Main, old client:** synchronized **2.167 s** (2.165–2.172). Down **1,930 B** = HTTP 1,361 + socket 569. Up **2,310 B** = HTTP 1,309 + socket 1,001.
- **Main, new client:** synchronized **2.959 s** (2.955–2.964). Down **20,113 B** = HTTP 1,361 + socket 18,752. Up **2,394 B** = HTTP 1,309 + socket 1,085.

The new shell reads server config once per generation. That adds about 18 KB of socket traffic here, even when both snapshots resume from retained cursors. Reconnect synchronization is 37.3% later on 3473 and 36.5% later on main. No shell or thread snapshot is re-fetched during a successful retained reconnect. Reusing the app's already acquired config is a possible follow-up; this harness has not measured that change.

## Compression and history checks

Both runtimes received URLSession's `Sec-WebSocket-Extensions: permessage-deflate` and returned that extension in the 101 upgrade. HTTP requests advertised `Accept-Encoding: gzip, deflate`; snapshot responses used `Content-Encoding: gzip`. No transport opt-in is required on this Mac. The committed encoding log excludes authorization, cookies and ticket query strings.

3473's HTTP thread response completed while bytes arrived continuously for longer than six seconds. The proxy recorded one bounded GET, followed by a cursor-only socket subscription rather than a duplicate socket snapshot. URLSession's request timeout did not impose an absolute six-second download deadline. The size-based timeout concern was not a measured failure.

After each timed pair, an untimed direct-origin validation paged every earlier row through the same store. All 12 runs ended with **1,322 rows, 482 message items and zero blank message items**. 3473 required 12 history pages; main required 14. Every fully paged message hash equals the seed:

`f483653408b8fefcf4508bbc0e59aab6b48b2206c69d786b3c4c59afc7b4f9f6`

The composite restored-visible-content hashes also match old/new clients within each server, both cold and fully paged. Their initial windows differ legitimately across servers. History validation traffic is excluded from timed byte totals. Deferred command-output fetches and UI rendering are outside this measurement.

Source references at exact main: `apps/server/src/server.ts:320` enables per-message deflate; `packages/client-runtime/src/state/boundedThreadSnapshotHttp.ts:18,33` defines the bounded fetch timeout and encoding flags; `apps/server/src/orchestration-v2/threadHistoryPaging.ts:15` defines the 75-row agent window. Shell behavior is documented in `docs/research/t3-fast-load-upstream.md`.

## Artifacts and handoff

- [Raw 36 stage/validation records](fast-load-2026-10-25-initial/matrix.jsonl).
- [Summary with all ranges and byte directions](fast-load-2026-10-25-initial/summary.json).
- [Matching fixture hashes](fast-load-2026-10-25-initial/dataset.jsonl).
- [Observed encoding headers from the timed matrix](fast-load-2026-10-25-initial/encoding-headers.jsonl).
- [Harness and reproduction instructions](../../scripts/fast-load/README.md).

The timed window ran from 16:05:27 to 16:08:49 UTC. Parent work was released immediately afterward. The benchmark leaves the requested sandbox servers/proxies available for the parent's UI check: 3473 server/proxy PIDs **21135/21136**, main **21321/21322**. Temporary `ui.token` and `session.token` files in each isolated fast-load home have mode 0600 and are not committed. Stop through `scripts/fast-load/manage.py stop` and remove those grants after UI validation. The benchmark's own Swift scratch builds and baseline checkout are removed after measurements.
