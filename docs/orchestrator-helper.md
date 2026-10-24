# CandyWrapper Helper

Built on 2026-10-24 to this design, with the changes noted where they happened. Checked against 3473 and 3566 sandboxes on this Mac and on aniko (Debian 13, x86_64). The Android app needs no change to coexist with it (section 5); it can reuse `HelperInstall` for its own button later.

The helper is a small background program that does the Orchestrator's relay job all the time. It carries `orchestrator-call` blocks and cross-machine events between the Orchestrator thread and every connected machine, exactly as the Mac app does while it's open (docs/orchestrator.md, "Every machine"). Any CandyWrapper client installs, updates and removes it with one button.

Today the relay runs only inside a client: the Mac while it's open, and the Android app in the foreground while the Mac is closed. When neither runs, the Orchestrator reaches only its own machine's threads. With the helper on the Orchestrator's machine, cross-machine calls and events keep working while every client is closed.

This design needs no change to T3. Every step below uses RPCs and HTTP routes that 3473 already serves, cited from `~/CandyWrapper-research/t3code`.

## What we learned from T3's source

These facts shaped every answer below.

- T3's server runtime is a Node single executable application, not a script run by a system Node. The 160 MB `t3` binary contains `node_sea.cc`, and this Mac has no `node` on the PATH while T3 runs fine. So Node is not reliably there wherever T3 runs.
- A pairing token can carry any subset of scopes: `POST /api/auth/pairing-token` takes `{label, scopes}` (`packages/contracts/src/auth.ts:401-405`, `environmentHttp.ts:566`).
- In 3473, a T3 Connect session holds `AuthStandardClientScopes`, which now include `access:read` and `access:write` (`auth.ts:149-170`, `apps/server/src/cloud/CloudLink.ts:1627-1633`). So a client connected through T3 Connect can mint a narrow pairing token on that machine. `docs/research/C-auth-connect.md` 4.8 still says "no `access:*`", which was true before 3473.
- Every session is listed with `connected`, `lastConnectedAt`, `expiresAt` and a client label in `GET /api/auth/clients`, and `subscribeAuthAccess` pushes changes (`auth.ts:277-289`, `RpcAuthorization.ts:209`). Revoking one closes its sockets at once.
- Bearer sessions last 30 days and there are no refresh tokens. Renewing means pairing again (C-auth-connect.md 1.9, `SessionStore.ts:432`).
- Every server accepts bearer tokens whatever its auth policy (`EnvironmentAuthPolicy.ts:39-52`).
- A T3 terminal runs a shell on that machine as the server's user, takes a client-chosen terminal id and needs a thread id (`packages/contracts/src/terminal.ts:24-44`). T3 strips `T3CODE_*` variables from it (`apps/server/src/terminal/Manager.ts:1291-1300`) and saves its scrollback to a history file, deleted when the terminal closes (`Manager.ts:1807, 1958`).
- T3 keeps its own server running with a launchd agent (`KeepAlive`, `ThrottleInterval`) and a systemd user unit (`Restart=always`, `RestartSec=5`, `WantedBy=default.target`) that needs lingering on Linux (`apps/server/src/cloud/bootService.ts:114-128, 176-178, 453`).
- The relay's logic is Foundation-only Swift already: `OrchestratorRelay`, `OrchestratorHandoff`, `OrchestratorReply` and the brief live in T3Store and T3Protocol, which import only Foundation (plus `os` in one T3Store file). T3Client is Apple-only (AppKit, Security, Network, CryptoKit).
- The brief already carries the limits the relay checks: the worker limit, the Models rows, the Hands off list and the ask-first window (`Packages/CandyKit/Sources/T3Store/Orchestrator.swift:210-240`).

## 1. What it's built in

Recommended: Swift, as one static binary per platform, built from the same relay code the Mac app runs.

- macOS ships a universal binary signed with the app's Team ID.
- Linux ships fully static x86_64 and arm64 binaries built with Swift's Static Linux SDK (musl), so they need no Swift runtime or libraries on the machine.
- A new executable target, `CandyHelper`, depends on T3Protocol and T3Store and adds a small cross-platform client: the WebSocket RPC, the pairing token exchange and bearer auth. It does not use T3Client.
- The one `import os` in T3Store gets a `#if canImport(os)` guard.

Why Swift: the helper then runs the exact relay, call parser, limit checks and handoff rules the Mac runs, and a fix lands in both at once. A second implementation would drift, and the Android app already has a third.

Trade-offs:

- A static Swift binary with Foundation is large, roughly 40 to 60 MB before compression. The T3 runtime next to it is 160 MB, so it's acceptable.
- WebSockets on Linux don't use URLSessionWebSocketTask. swift-corelibs-foundation passes each curl write callback, 16 KB at most, on as a whole message (WebSocketURLProtocol.swift:101-180 at swift-6.4.1-RELEASE). On aniko every shell snapshot over 16 KB then failed to decode. The helper uses libcurl's own frame API instead, `curl_ws_recv` and `curl_ws_send` through a small `CCurl` module map, and rebuilds messages from curl's `bytesleft` and `CURLWS_CONT` (`CurlRPCSocket`, `WebSocketAssembler`). curl, OpenSSL and zlib are in the Static Linux SDK already. macOS keeps URLSession.
- The Static Linux SDK isn't installed here yet (`swift sdk list` is empty). Installing it takes a few hundred MB of disk.

Rejected:

- A Node script fails because Node isn't guaranteed. T3's own runtime can't run another script, since it's a single executable application.
- Go would give 8 MB binaries and easy cross-compiling, but it means rewriting the relay and keeping it in step by hand. It stays the fallback if the Swift spike fails.

## 2. How the button installs it

Recommended: through a hidden T3 terminal on the Orchestrator's machine, which CandyWrapper can already open over its existing connection. No T3 change is needed.

The helper goes on the Orchestrator's machine, the one the Orchestrator thread runs on. It can be any OS T3 runs on. When that machine is down, the Orchestrator is down too, so nothing is lost, and the helper starts again when the machine boots. If the user moves the Orchestrator to another machine, Settings offers to move the helper with it.

The install, as the client runs it:

1. The client mints one-time pairing codes for every machine (section 3), then opens a terminal on the Orchestrator's machine with `terminal.open`, its own terminal id and the Orchestrator thread as the thread. The user never sees it.
2. It types one line, `HelperInstall.installCommand`: a `sh -c '…'` script, so zsh, bash and fish all run it, with a leading space to keep it out of history. The script reads `uname -s -m`, downloads the matching tarball from the release with `curl` or `wget` into `versions/<version>/`, and checks its SHA-256 with `sha256sum` or `shasum -a 256`.
3. The expected hashes come with the client, so a swapped release file fails the check. That pins the exact binary, which makes a separate signature check unnecessary.
4. The script runs the new binary's `install`. It turns echo off, prints `CWH-READY`, and the client then types the pairing lines.
5. `install` finds the T3 server's loopback port by asking every port the user listens on for its public descriptor until one answers as the home machine (`lsof` on macOS, `/proc/net/tcp` on Linux). T3 strips its own variables from terminals (`Manager.ts:1291-1300`), so the port can't come from the environment. The helper prefers that address for its own machine and falls back to the URL the client uses. A port only counts if the helper's new token signs in there: on aniko an old server left on the same T3 home answered as the same machine but refused the token with HTTP 401. If the loopback refuses later, the helper switches to the URL it paired at. The helper never follows a redirect, so a request and its token stay on the server they name.
6. It signs in to each machine, points `current` at the new version, writes the service (section 4) and restarts it. It then waits up to 30 seconds for the helper to report its own machine connected in `status.json`, and switches back to the previous version if it doesn't.
7. It prints `CWH-RESULT ok …` or `CWH-RESULT failed <reason>`, plus `CWH-WARNING …` when lingering is off. The script builds its own markers from pieces, so the terminal echoing the typed line never reads as a result. The client then closes the terminal with `deleteHistory`.

The same run serves install, update and renewal, so there is one code path to test. Settings shows each step's result in plain words, like "Downloading", "Signing in to 3 machines" or "Running".

Trade-offs:

- The machine needs `curl` or `wget` and access to GitHub. Every Mac has curl, and most Linux machines have one of them. If neither is there, the button says so.
- `lsof` and `ss` usually exist. Without them the helper reaches its own machine through the same URL the client uses, such as the T3 Connect tunnel, which only adds latency.
- The terminal needs `terminal:operate`, which every standard and T3 Connect session holds.

Rejected:

- Asking the Orchestrator or another agent to run the install costs turns and can go wrong in many ways.
- `projects.writeFile` writes text inside a project and can't set the executable bit.
- Shipping the Linux binaries inside the Mac app would add over 100 MB to every download, and the Android app couldn't do the same.

## 3. How it signs in, where the credential lives and how to revoke it

Recommended: one narrow pairing session per machine, created by the client and redeemed by the helper itself.

1. For each connected machine, the client calls `POST /api/auth/pairing-token` on that machine with the label "CandyWrapper Helper on <machine>" and only two scopes, `orchestration:read` and `orchestration:operate`.
2. The client passes each one-time code, with the machine's id and URL, to the helper over the install terminal's standard input. The helper reads it with echo off, so the codes appear neither in the scrollback nor in shell history.
3. The helper redeems each code at that machine's `/oauth/token` with device type `bot` and gets a 30-day bearer session.

The two scopes cover every call the relay makes: `subscribeShell`, `getThreadProjection`, `server.getConfig` and the scheduled task reads need `orchestration:read`, while `dispatchCommand`, `launchThread` and the scheduled task writes need `orchestration:operate` (`apps/server/src/auth/RpcAuthorization.ts:42-118`). The helper gets no terminal, files, settings, providers, access or relay scopes. It can't mint tokens or revoke anyone.

A pairing code is valid once and for 5 minutes. Only codes cross the terminal, never the long-lived token, and each code is spent before anyone could read it.

Where the tokens live:

- On macOS they go in the login Keychain, readable only by the signed helper binary. T3's own server needs the user logged in, so the Keychain is unlocked whenever there is anything to relay.
- On Linux they go in `~/.config/candywrapper-helper/credentials.json` with mode 0600, in a 0700 folder. Headless Linux usually has no secret service, and encrypting the file with a key stored beside it would protect nothing.

Logging: the helper never formats a token, code or request header into a string. It logs machine labels, call names and error codes only. An integration test greps the helper's whole log for every token and code it handled and fails on a match.

Renewal: no refresh tokens exist, so any open CandyWrapper client renews the helper. When a helper session on any machine expires within 7 days, the client runs the install flow again, which only re-pairs. Then it revokes the helper's old sessions itself, since the helper can't. The user opens CandyWrapper daily, so this runs long before expiry. If nobody opens a client for 30 days, the helper loses those machines and Settings asks for one renewal.

Revoking:

- Settings > Orchestrator > Helper has Uninstall (section 6) and a per-machine Revoke.
- T3's own Connections settings on each machine list "CandyWrapper Helper on <machine>" as a bot, and revoking it there works at once.
- T3 Connect stays with the user's clients. The helper never holds the Clerk sign-in, so it can't reach the account, list environments or link machines.

Reaching machines without T3 Connect: the helper uses the URL the client connected over. For a T3 Connect machine that is its tunnel's `httpBaseUrl`, and a bearer token works over it because the tunnel only forwards HTTP to the server. If a tunnel's address changes, after the relay releases it, the helper loses that machine until a client runs a renewal with the new address. Settings shows this per machine.

Trade-offs:

- `orchestration:operate` can launch a full-access agent, which T3 itself says reaches shell authority (`auth.ts:149-151`). The relay can't work without it. A stolen helper token is therefore worth as much as a stolen client token, minus access and relay management.
- Holding the Clerk sign-in would remove the renewal and tunnel-address work, but it would give a background program the whole account. I rejected it.

## 4. How it keeps running and updates

Recommended: the same service setup T3 uses for itself, under the user's account, never as root.

- On macOS a LaunchAgent, `com.sowyu.candywrapper.helper`, in `~/Library/LaunchAgents`, with `RunAtLoad`, `KeepAlive` on a crash and a `ThrottleInterval` of 10 s. Logs go to `~/Library/Logs/CandyWrapper Helper/`.
- On Linux a systemd user unit, `candywrapper-helper.service`, with `Restart=on-failure`, `RestartSec=5`, `RestartPreventExitStatus=78` and `WantedBy=default.target`. Logs go to the journal.
- If lingering is off on Linux, the helper stops when the user logs out. The script checks `loginctl show-user`, and Settings shows T3's own message with the `sudo loginctl enable-linger` command for the user to run. A machine that already runs T3 as a boot service has lingering on.

Idle cost: the helper holds one WebSocket per machine and reacts to server pushes, like the Mac's relay. Beside the 30-second event batch while events arrive, it pings each connection every 45 seconds, so a socket a tunnel or NAT dropped without a close gets noticed and reconnected. It does not poll for updates.

Updates: the client runs them, never a timer in the helper.

- The helper's session label carries its version, like "CandyWrapper Helper 1.14.0 on miniko".
- When an open client sees an older version, it runs the install flow, which downloads the new version next to the old one, switches the `current` link, re-pairs and restarts the service.
- If the new version fails to come up within 30 seconds, the script switches the link back and restarts the old one.
- The call format lives in the brief, the settings format in the settings task, and both in the shared Swift code, so the helper and the Mac app always speak the same version after an update.

Crash loops: when every machine refuses the helper's token, it exits with 78 (EX_CONFIG). systemd shows the unit as failed and launchd shows 78 as the last exit code, and neither restarts it. `status.json` and the log say which address refused it and what T3 answered, with anything token-like redacted.

## 5. Exactly one relays at a time

Recommended: keep the "while closed" scheduled task as the one flag, and add one rule: a connected helper beats the Mac, and the Mac beats the phone.

Today, from `OrchestratorHandoff` (commit 95420e5a):

- Task on means no client is open, so the schedule checks every 30 minutes.
- The Mac turns it off while it's open, remembers the `updatedAt` of its own write, and takes it back whenever someone else wrote it since.
- The phone relays only in the foreground and only while the task is on. It turns it off while it relays, and it stops when someone else writes the task off.
- Either side waits 2 seconds before running calls and skips calls a "Result:" message already answers.

The helper extends that:

1. The helper behaves like a Mac that never closes. It turns the task off when it starts, remembers its own stamp and takes the task back whenever someone else wrote it. It runs the same `unansweredReplies` and 2-second wait.
2. The Mac learns whether the helper is alive from the Orchestrator machine's sessions: a session labelled "CandyWrapper Helper" with `connected: true`. It subscribes to `subscribeAuthAccess` only while the Orchestrator is on, so this costs a push now and then and nothing while idle.
3. `OrchestratorHandoff.verdict` gets a third answer, `standBy`, when the helper is connected. The Mac then relays nothing and never writes the task. On quit it leaves the task alone instead of turning it on.
4. When the helper's session goes to `connected: false`, the Mac's verdict becomes `resync` and it takes over exactly as today.
5. The phone needs no change. The helper keeps the task off, and the phone only relays while the task is on. An older phone that does take the task sees the helper write it back off and stops, as it does for the Mac today.

The 2-second wait and the "Result:" check make a short overlap harmless, so the hand-over doesn't need to be instant.

Where the helper reads its settings: from the "CandyWrapper Orchestrator settings" task the Mac and the Android app already share (docs/orchestrator.md, "Settings on every device", `OrchestratorSettingsSync`). The helper only reads it: it merges the documents into the defaults with no stamps of its own, so every synced setting wins, and it never writes one back. It watches that task through the same `scheduledTasks.subscribe` as the check task, so a Hands off change reaches it within a second and costs no turn. A brief wouldn't do, because a brief reaches the thread only with your next message (`OrchestratorController.send`).

The helper finds the Orchestrator thread the way the Mac adopts one, through `orchestration.searchThreads` for "Orchestrator brief", preferring the brief thread a check task points at. A thread's projection holds only its newest messages, so the first message can't be read once a thread passes that window. Both the helper and the Mac now trust a search match whose snippet starts with the brief heading (ThreadSearch.ts:46-60, 100-125). That search shows only each thread's newest user message with the phrase, so a chat message that mentions the brief hides it: on 2026-10-24 the helper on miniko never found its thread and relayed nothing while the Mac stood by. Both now use `OrchestratorHandoff.findOrchestrator`: the thread a "while closed" check task is bound to first, then the first-brief or "# Updated brief" matches of two searches. The helper looks again every 30 s with one loop; an earlier version added a loop on every retry. The Mac also checks that a connected helper's events reach the thread and sends a batch itself when none did. Until it has read a settings document, the helper answers calls with one refusal asking for CandyWrapper to be opened once, and still relays events.

Trade-offs:

- Each relay remembers its own sends for the ask-first window. Right after a hand-over, the helper may treat a message the Mac relayed a few minutes earlier as the user's and ask first. That errs on the safe side.
- If the user revokes the helper in T3's settings directly, the helper can't turn the task back on. The task stays off until a CandyWrapper client opens and takes over. Revoking from CandyWrapper's button handles the task itself.
- Liveness relies on `access:read` on the Orchestrator's machine. On a server older than 3473 a T3 Connect client lacks it, so the Mac treats the helper as absent and relays too. The "Result:" check keeps calls from running twice, but events could go out twice.

Rejected: a heartbeat written into the task every few minutes would wake both the helper and the clients while idle, and it would change `updatedAt`, which the Mac's stamp check reads as a takeover.

## 6. Uninstall from the same button

Settings > Orchestrator > Helper shows Install, then Update, Renew and Uninstall once it's there. Uninstall runs through the same hidden terminal:

1. The helper hands the task back the way the Mac does on quit: on with the user's interval, or left off if the user turned the check off. A client that's open takes it right away as usual.
2. The script stops and removes the LaunchAgent or the systemd unit.
3. The script deletes the helper's folder and its credentials, the Keychain items or the 0600 file.
4. The client revokes the helper's session on every machine it can reach, found by its label and device type.

If the helper's machine is unreachable, the client still revokes the sessions on every other machine, which leaves the helper unable to do anything. Settings shows that the files remain and offers to finish when the machine is back.

## Build order, after the go

1. Prove the Swift Static Linux SDK builds a binary from T3Protocol and T3Store and holds a WebSocket to a sandbox server. About 2 hours. If WebSockets fail, try swift-nio before falling back to Go.
2. Build the helper's client, relay loop, event batch and handoff on top of the shared code, and test it on this Mac against the two 3473 sandboxes. About 1 to 2 days.
3. Add the install script, the services, pairing, renewal and uninstall. About half a day.
4. Add the Mac side: the `standBy` verdict, the quit change, and the Helper row in Settings (the settings already sync through their own task). About half a day.
5. Check it on screen and test crash recovery, revocation and the Mac and helper trading the task, all against sandboxes. About half a day.

The release that ships the helper's binaries needs `scripts/release` to build and attach them, and the client to carry their hashes. That waits for the user, like any release.
