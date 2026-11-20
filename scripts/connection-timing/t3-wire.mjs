// Replays T3 4928's desktop connect and thread-open sequence on the wire, with node's own fetch and WebSocket,
// for docs/research/connection-vs-t3-desktop-4928.md. T3's client-runtime needs its Effect workspace installed,
// which this Mac doesn't have, so this follows its source step by step instead of running it:
//   connection/driver.ts:229-270      descriptor check, prepare (ticket), session, ready
//   state/shell.ts:562-611, 640-710   HTTP shell as soon as the connection is prepared, then subscribeShell
//                                     from its cursor with knownProjectIdentities
//   rpc/session.ts:250-262            socket URL with frameParts=1, joins U+001E parts
//   rpc/session.ts:179-190            subscribeServerConfig input (web runtime.ts:37-41 options)
//   state/boundedThreadSnapshotHttp.ts:31-38, threads.ts:1111-1128   thread open
// Usage: node t3-wire.mjs <baseURL> <tokenFile> <runs> [shortThread] [longThread]
import { readFileSync } from "node:fs";

const [base, tokenFile, runsArg, shortThread, longThread] = process.argv.slice(2);
const token = readFileSync(tokenFile, "utf8").trim();
const runs = Number(runsArg ?? 5);
const auth = { authorization: `Bearer ${token}`, "x-t3-orchestration-protocol": "2" };
const PART = "\u001e";

async function get(path) {
  const response = await fetch(new URL(path, base), { headers: auth });
  const body = await response.text();
  return { status: response.status, body, bytes: Buffer.byteLength(body), json: () => JSON.parse(body) };
}

function openSocket(ticket) {
  const url = new URL("/ws", base);
  url.protocol = url.protocol.replace("http", "ws");
  const query = { orchestrationProtocol: "2", wsTicket: ticket, clientSurface: "desktop", clientAppVersion: "0.0.0-t3-wire",
    clientOs: "macOS", clientDeviceType: "desktop", connectionMethod: "direct", frameParts: "1" };
  for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  const ws = new WebSocket(url);
  const state = { rx: 0, frames: 0, waiters: new Map(), parts: [] , nextId: 1 };
  ws.onmessage = (event) => {
    const text = typeof event.data === "string" ? event.data : Buffer.from(event.data).toString();
    state.rx += Buffer.byteLength(text);
    state.frames += 1;
    // socketFrameParts.ts: a frame that starts with U+001E is a part; the last part has no marker after it.
    let whole = text;
    if (text.startsWith(PART)) {
      state.parts.push(text.slice(1));
      return;
    }
    if (state.parts.length > 0) { whole = state.parts.join("") + text; state.parts = []; }
    const parsed = JSON.parse(whole);
    for (const message of Array.isArray(parsed) ? parsed : [parsed]) {
      if (message._tag === "Chunk") ws.send(JSON.stringify({ _tag: "Ack", requestId: message.requestId }));
      const waiter = state.waiters.get(message.requestId);
      if (waiter) waiter(message);
    }
  };
  const opened = new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  const request = (tag, payload, until) => new Promise((resolve) => {
    const id = String(state.nextId++);
    state.waiters.set(id, (message) => {
      const values = message._tag === "Chunk" ? message.values : [];
      if (message._tag === "Exit" || values.some(until)) {
        state.waiters.delete(id);
        if (message._tag === "Chunk") ws.send(JSON.stringify({ _tag: "Interrupt", requestId: id }));
        resolve(message._tag === "Exit" ? message : values.find(until));
      }
    });
    ws.send(JSON.stringify({ _tag: "Request", id, tag, payload, headers: [] }));
  });
  return { ws, state, opened, request };
}

function median(values) { const s = [...values].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; }
function report(test, samples) {
  const keys = new Set(samples.flatMap((s) => Object.keys(s)));
  const medianOf = Object.fromEntries([...keys].map((k) => [k, median(samples.map((s) => s[k]).filter((v) => v !== undefined))]));
  console.log("TIMING " + JSON.stringify({ test, client: "t3-wire", server: base, runs: samples.length, median: medianOf, samples }));
}

async function connectOnce() {
  const t0 = performance.now();
  const ms = () => performance.now() - t0;
  const marks = {};
  const descriptor = await (await fetch(new URL("/.well-known/t3/environment", base), { cache: "no-store" })).json();
  marks.descriptor = ms();
  const ticket = await (await fetch(new URL("/api/auth/websocket-ticket", base), { method: "POST", headers: auth })).json();
  marks.ticket = ms();
  const caps = descriptor.capabilities ?? {};
  const flagsKnown = caps.shellThreadFamilies !== undefined || caps.shellOlderSettled !== undefined;
  const query = [caps.shellThreadFamilies ? "omitIdleSubagents=1" : null, caps.shellOlderSettled ? "omitOlderSettled=1" : null].filter(Boolean);
  const shellPath = "/api/orchestration/shell" + (query.length ? "?" + query.join("&") : "");
  const early = flagsKnown ? get(shellPath).then((r) => { marks.httpShell = ms(); return r; }) : null;
  const socket = openSocket(ticket.ticket);
  await socket.opened;
  marks.socketOpen = ms();
  const config = await socket.request("subscribeServerConfig",
    { environmentThemes: true, usageLimitSources: true, usageLimitsCommand: true, workspaceSnapshotsOnDemand: true },
    (v) => v.type === "snapshot");
  marks.configSnapshot = ms();
  marks.configBytes = socket.state.rx;
  const shell = early ? await early : await get(shellPath).then((r) => { marks.httpShell = ms(); return r; });
  marks.httpShellBodyBytes = shell.bytes;
  const snapshot = shell.json();
  const before = socket.state.rx;
  const payload = { requestCompletionMarker: true, afterSequence: snapshot.snapshotSequence,
    ...(snapshot.projectIdentities ? { knownProjectIdentities: snapshot.projectIdentities } : {}),
    ...(config.config.shellThreadFamilies ? { omitIdleSubagents: true } : {}),
    ...(config.config.shellOlderSettled ? { omitOlderSettled: true } : {}) };
  await socket.request("orchestration.subscribeShell", payload, (v) => v.kind === "synchronized");
  marks.shellSynchronized = ms();
  marks.shellSocketBytes = socket.state.rx - before;
  marks.socketRxBytes = socket.state.rx;
  marks.socketRxFrames = socket.state.frames;
  socket.ws.close();
  return marks;
}

async function threadOpen(socket, id) {
  const t0 = performance.now();
  const r = await get(`/api/orchestration/threads/${id}/bounded?compactTurnItems=1&dedupeBodies=1&compactIds=1&deferWork=1`);
  const http = performance.now() - t0;
  const snapshot = r.json();
  const before = socket.state.rx;
  await socket.request("orchestration.subscribeThread", { threadId: id, afterSequence: snapshot.snapshotSequence, requestCompletionMarker: true,
    acceptBoundedSnapshot: true, acceptDeferredWork: true, acceptCompactTurnItems: true, acceptCompactIds: true, acceptDedupedBodies: true },
    (v) => v.kind === "synchronized");
  return { http, synchronized: performance.now() - t0, httpBodyBytes: r.bytes, socketBytes: socket.state.rx - before };
}

const samples = [];
for (let i = 0; i < runs; i++) samples.push(await connectOnce());
report("cold-connect", samples);
if (shortThread || longThread) {
  const ticket = await (await fetch(new URL("/api/auth/websocket-ticket", base), { method: "POST", headers: auth })).json();
  const socket = openSocket(ticket.ticket);
  await socket.opened;
  for (const [label, id] of [["short", shortThread], ["long", longThread]]) {
    if (!id) continue;
    const open = [];
    for (let i = 0; i < runs; i++) open.push(await threadOpen(socket, id));
    report(`thread-open-${label}`, open);
  }
  socket.ws.close();
}
process.exit(0);
