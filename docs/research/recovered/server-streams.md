# T3 Code orchestration v2: server-side streaming and snapshot protocol

Source: `/Users/mrm/CandyWrapper-research/t3code`, HEAD at tag `v0.0.46-nightly.20261009.2861` (checked with `git describe --tags`). All paths below are repo-relative to that checkout unless prefixed with `effect:` (meaning `.repos/effect-smol/packages/effect/src/...`, the reference copy of the Effect library).

Effect version: the catalog pins `effect: 4.0.1` (pnpm-workspace.yaml:49) and `.repos/effect-smol/packages/effect/package.json` reports `4.0.1`; `scripts/lib/reference-repos.ts` syncs that reference copy from tag `effect@<catalog version>`. There is no `node_modules` in the checkout, so the installed package itself was not inspected. The repo patches effect 4.0.1 (`patches/effect@4.0.1.patch`, listed in pnpm-workspace.yaml patchedDependencies), but the patch only touches `HttpClientResponse` cookies, `McpServer`, and the RpcClient pinger. It does not change RpcServer or the message formats.

Everything below is derived from source reading. Items marked UNVERIFIED were inferred but not proven.

---

## 1. Transport, framing, and the Effect RPC envelope

### 1.1 Endpoint and handshake

- The WebSocket route is `GET /ws` (apps/server/src/ws.ts:3136-3138).
- Before auth, the server requires the query parameter `orchestrationProtocol=2`. Constants: `ORCHESTRATION_PROTOCOL_VERSION = 2`, `ORCHESTRATION_PROTOCOL_VERSION_TEXT = "2"`, `ORCHESTRATION_PROTOCOL_QUERY_PARAM = "orchestrationProtocol"`, `ORCHESTRATION_PROTOCOL_HEADER = "x-t3-orchestration-protocol"` (packages/contracts/src/environment.ts:12-16). The check is an exact string match (ws.ts:607-612). If it fails, the server answers HTTP 426 with this JSON body (ws.ts:3142-3151):

```json
{"code":"orchestration_protocol_incompatible","message":"Update this client to one that supports orchestration protocol 2.","orchestrationProtocolVersion":2}
```

- Auth then runs `authenticateWebSocketUpgrade` (ws.ts:3152-3165). It accepts a `wsTicket` query parameter first (apps/server/src/auth/EnvironmentAuth.ts:586, 1173-1191), and otherwise falls back to normal request authentication (EnvironmentAuth.ts:1193). Auth failures go out as `EnvironmentAuthInvalidError` / `EnvironmentInternalError` HTTP responses (ws.ts:3240-3245).
- Optional analytics parameters on the upgrade URL, all lenient and ignored when malformed (ws.ts:620-684): `clientSurface` (one of `web|desktop|mobile|cli`, packages/contracts/src/baseSchemas.ts:345), `clientAppVersion` (at most 64 chars), `clientDeviceType`, `clientOs`, `clientWebDeployment`, `clientBrowser`, `connectionMethod`, `clientOsMajorVersion`, `clientDeviceModel` (enums at baseSchemas.ts:345-367).
- When the auth session is invalidated (revoked), the WebSocket handler is raced against `sessions.awaitInvalidation` and ends, which closes the socket (ws.ts:3225-3239). The close code is UNVERIFIED.
- The server negotiates permessage-deflate with clients that offer it (apps/server/src/server.ts:255-261).
- A global router middleware makes requests wait until the runtime is command-ready (server.ts:661-667, applied at 709). It certainly applies to the HTTP API routes. Whether it also delays the `/ws` upgrade is UNVERIFIED (it is a global HttpRouter middleware, so probably yes).

Example connect URL:

```
wss://HOST/ws?orchestrationProtocol=2&wsTicket=TICKET&clientSurface=desktop&clientAppVersion=0.1.0
```

### 1.2 Serialization

- The server builds the RPC protocol with `RpcServer.makeProtocolWithHttpEffectWebsocket` and `RpcSerialization.layerJson` (ws.ts:3170-3190).
- `RpcSerialization.json` (effect:rpc/RpcSerialization.ts:129-140): `contentType: "application/json"`, `includesFraming: false`. Encode is `JSON.stringify(message)`. Decode is `JSON.parse(frame)`, and if the parsed value is an array, each element is treated as one message. So each WebSocket message carries exactly one envelope from the server. The client may send one envelope per frame, or a JSON array of envelopes in one frame.
- The server writes JS strings through `ws.send` (effect:socket/Socket.ts:1107, 1122), so server frames are text frames. Incoming frames may be text or binary (the parser accepts `Uint8Array | string`, RpcSerialization.ts:78, 135).
- Payload, chunk values, and exits are encoded with `Schema.toCodecJson(schema)` (RpcSerialization.ts:37-41, codecFor; RpcServer.ts:638-657). Section 4 covers what that means for JSON shapes.
- Server options: `disableTracing: true`, `disableFatalDefects: true` (ws.ts:3121-3127). Concurrency is the default `"unbounded"` (effect:rpc/RpcServer.ts:121). With fatal defects disabled, a handler defect fails only its own request (Exit with a `Die` cause) instead of a socket-level `Defect` frame (ws.ts:3121-3123; RpcServer.ts:306-319).

### 1.3 Envelope shapes (effect:rpc/RpcMessage.ts)

Client to server (`FromClientEncoded`, RpcMessage.ts:37):

```json
{"_tag":"Request","id":7,"tag":"orchestration.subscribeThread","payload":{"threadId":"thread_abc"},"headers":[]}
{"_tag":"Ack","requestId":7}
{"_tag":"Interrupt","requestId":7}
{"_tag":"Ping"}
{"_tag":"Eof"}
```

- `Request` (RpcMessage.ts:71-81): `id` is `string | number`; `tag` is the method name; `payload` is the toCodecJson-encoded input; `headers` is an array of `[name, value]` pairs. Optional `isNotification`, `traceId`, `spanId`, `sampled` (tracing is disabled on this server, ws.ts:3125).
- Always send `"headers": []`. On WebSocket the server does `headers.concat(message.headers)` with the upgrade headers (RpcServer.ts:1582-1584), then `Headers.fromInput` (RpcServer.ts:756). What happens if `headers` is omitted is UNVERIFIED (probably a defect).
- Request ids: the server accepts a number or a string and echoes the same value (RpcServer.ts:773-784). Any other type produces a socket `Defect` ("Invalid request id"). The official client uses an incrementing number starting at 0 (effect:rpc/RpcClient.ts:217, 273). Ids are scoped per connection. Reusing an in-flight id is ignored (RpcServer.ts:247-249).
- `Interrupt` on the wire carries only `requestId` (RpcMessage.ts:147-150). The server interrupts that request's fiber and then still sends an `Exit` with an interrupt cause (RpcServer.ts:203-215, 291-325). The official client ignores it because it deleted its entry first (RpcClient.ts:675-679).
- `Eof` means "no more requests". The server ends the client after in-flight requests finish (RpcServer.ts:216-220). Not needed for a long-lived socket.

Server to client (`FromServerEncoded`, RpcMessage.ts:214-220):

```json
{"_tag":"Chunk","requestId":7,"values":[{"kind":"synchronized"}]}
{"_tag":"Exit","requestId":7,"exit":{"_tag":"Success","value":null}}
{"_tag":"Exit","requestId":7,"exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2GetThreadProjectionError","threadId":"thread_abc","message":"Failed to load orchestration V2 thread thread_abc"}}]}}
{"_tag":"Defect","defect":{"name":"SyntaxError","message":"Unexpected token"}}
{"_tag":"Pong"}
```

- `Chunk.values` is a non-empty array of stream items (RpcMessage.ts:257-261). The server encodes it with `codecFor(Schema.NonEmptyArray(successSchema))` (RpcServer.ts:645-649). A Chunk may carry several items. How items are batched into chunks is not part of the contract.
- `Exit.exit` is an encoded `Exit` (RpcMessage.ts:286-317): `{"_tag":"Success","value":...}` or `{"_tag":"Failure","cause":[...]}`. Each cause element is `{"_tag":"Fail","error":E}`, `{"_tag":"Die","defect":D}`, or `{"_tag":"Interrupt","fiberId":number|null}` (effect:test/schema/toCodec.test.ts:1605-1626). For stream RPCs the success type is `Schema.Void` (effect:rpc/Rpc.ts:1169-1195), so a stream that ends normally sends `"value": null` (Void encodes undefined as null, effect:SchemaAST.ts:1007-1009). That exact frame was not observed: UNVERIFIED but derived from code. The orchestration subscriptions in this document never end normally anyway (live tails are infinite), so in practice they end with a Failure or an Interrupt.
- A unary RPC (getTurnItem, getThreadProjection, and so on) answers with one `Exit` whose `value` is the encoded result. No Chunk is sent.
- Unknown `tag`: `Exit` with `[{"_tag":"Die","defect":"Unknown request tag: X"}]` (RpcServer.ts:785-788). Payload that fails schema decode: `Exit` with a `Die` whose defect is the formatted schema issue string (RpcServer.ts:797-803, 703-723).
- If an outgoing item fails to encode, the server sends that request an `Exit` with a `Die` and interrupts the stream (RpcServer.ts:674-701). Treat it as a stream failure and resubscribe.
- A frame the server cannot parse produces a socket-level `{"_tag":"Defect", ...}` (RpcServer.ts:1573-1594). The official client then fails every pending request (RpcClient.ts:600-602).

### 1.4 Acks and backpressure

- The WebSocket protocol sets `supportsAck: true` (RpcServer.ts:1625).
- For each stream request, the server writes one Chunk (one pull batch), closes a latch, and waits for `{"_tag":"Ack","requestId":...}` before pulling the next batch (RpcServer.ts:402-453, specifically 443-453). Exactly one chunk per stream is in flight at any time.
- The official client sends the Ack right after enqueueing the chunk's values locally, before processing them (RpcClient.ts:568-585). A native client should Ack every Chunk promptly after parsing it.
- If a client stops acking, the stream stalls. Meanwhile the server-side live buffers keep filling (section 9). When they overflow, the failure is only delivered on the next pull, and the next pull happens only after the client acks the chunk in flight (inference from RpcServer.ts:443-453 plus LiveStreamBudget.ts:139-192).
- Terminal-output RPCs use a different windowed ack scheme (apps/server/src/terminal/OutputProtocol.ts:5-67). That does not apply to orchestration streams.

### 1.5 Keepalive

- The server answers `Ping` with `Pong` (RpcServer.ts:806-808). It never sends pings itself, and none of the orchestration streams emit heartbeat items. A search of apps/server/src for heartbeat or keepalive logic found nothing related to the socket.
- The official client pings every 5 seconds (RpcClient.ts:1205-1227). With the repo patch it tolerates up to 3 missed pongs before treating the socket as dead (patches/effect@4.0.1.patch, RpcClient.js hunks starting at line 82). Idle timeouts in the `ws` library, TCP, or proxies are UNVERIFIED.

### 1.6 Authorization of orchestration RPCs

- Every RPC in `WsRpcGroup` carries `RpcScopeAuthorization` middleware (packages/contracts/src/rpc.ts:1801-1809, 1997). The failure type is `EnvironmentAuthorizationError` (packages/contracts/src/auth.ts:409-416).
- Required scopes (apps/server/src/auth/RpcAuthorization.ts:43-58): every `orchestration.subscribe*`, `get*`, and `search*` method needs `orchestration:read` (auth.ts:82). `dispatchCommand` and `launchThread` need `orchestration:operate`.
- Failure value (RpcAuthorization.ts:222-226, 267-272; auth.ts:167-172):

```json
{"_tag":"EnvironmentAuthorizationError","message":"The authenticated token is missing required scope: orchestration:read.","requiredScope":"orchestration:read","requiredPermission":"orchestration:read"}
```

`requiredScope` can be a legacy parent scope that differs from `requiredPermission` (auth.ts:167-172).

---

## 2. Methods and RPC definitions

`ORCHESTRATION_V2_WS_METHODS` (packages/contracts/src/orchestrationV2.ts:3138-3153) and `OrchestrationV2RpcSchemas` (orchestrationV2.ts:3561-3610). RPC objects are at packages/contracts/src/rpc.ts:1559-1663.

| Method string | Kind | Input | Output | Error union (besides EnvironmentAuthorizationError) |
|---|---|---|---|---|
| `orchestration.subscribeShell` | stream | `OrchestrationV2SubscribeShellInput` | `OrchestrationV2ShellStreamItem` | `OrchestrationV2GetShellSnapshotError` |
| `orchestration.subscribeArchivedShell` | stream | `{}` | `OrchestrationV2ArchivedShellStreamItem` | `OrchestrationV2GetShellSnapshotError` |
| `orchestration.subscribeThread` | stream | `OrchestrationV2SubscribeThreadInput` | `OrchestrationV2ThreadStreamItem` | `OrchestrationV2GetThreadProjectionError` |
| `orchestration.getArchivedShellSnapshot` | unary | `{}` | `OrchestrationV2ArchivedShellSnapshot` | `OrchestrationV2GetShellSnapshotError` |
| `orchestration.getThreadProjection` | unary | `{threadId}` | `OrchestrationV2ThreadProjection` | `OrchestrationV2GetThreadProjectionError` |
| `orchestration.getTurnItem` | unary | `{threadId, itemId, revision?}` | `{item: TurnItem or null}` | `OrchestrationV2GetThreadProjectionError` |
| `orchestration.getTurnDiff` | unary | `{threadId, fromTurnCount, toTurnCount, ignoreWhitespace?}` | `{threadId, fromTurnCount, toTurnCount, diff}` | `OrchestrationGetTurnDiffError` |
| `orchestration.getFullThreadDiff` | unary | `{threadId, toTurnCount, ignoreWhitespace?}` | same as above | `OrchestrationGetFullThreadDiffError` |
| `orchestration.searchThreads` | unary | `{query, limit?}` | `{matches}` | `OrchestrationSearchThreadsError` |
| `orchestration.searchThread` | unary | `OrchestrationV2SearchThreadInput` | `OrchestrationV2SearchThreadResult` | `OrchestrationV2SearchThreadError` |
| `orchestration.searchThreadStream` | stream | same | same (1 or 2 items) | `OrchestrationV2SearchThreadError` |
| `orchestration.dispatchCommand` | unary | `OrchestrationV2Command` | `{sequence}` | `OrchestrationV2DispatchCommandError` |
| `orchestration.launchThread` | unary | `OrchestrationV2ThreadLaunchInput` | `{threadId, projection, resumed}` | `OrchestrationV2ThreadLaunchError` |
| `orchestration.getWorkflowScript` | unary | `{threadId, scriptPath}` | `{scriptPath, contents, truncated}` | `OrchestrationGetWorkflowScriptError` |

How `stream: true` works in Effect 4.0.1: `Rpc.make(tag, {stream: true, success, error})` sets the success schema to `RpcSchema.Stream(success, error)` and the RPC error schema to `Never` (effect:rpc/Rpc.ts:941-991). The exit schema is `Exit(Void, Union(rpcError, streamError, middlewareErrors), Defect)` (Rpc.ts:1169-1195). So a stream failure arrives as an `Exit` Failure whose `Fail.error` is either the method's stream error or `EnvironmentAuthorizationError`.

Error classes (all `Schema.TaggedError`, so they encode as `{"_tag": <name>, ...fields}`, effect:Schema.ts:15151-15185):
- `OrchestrationV2GetThreadProjectionError {threadId, message, cause?}` (orchestrationV2.ts:3406-3413)
- `OrchestrationV2GetShellSnapshotError {message, cause?}` (orchestrationV2.ts:3415-3421)
- `OrchestrationV2DispatchCommandError {commandId, commandType, message, detail?, cause?}` (orchestrationV2.ts:3395-3404)
- `OrchestrationV2ThreadLaunchError {commandId, projectId, message, cause?}` (orchestrationV2.ts:3423-3431)
- `OrchestrationV2SearchThreadError {cause}` (orchestrationV2.ts:3552-3559)
- `OrchestrationGetTurnDiffError` / `OrchestrationGetFullThreadDiffError {message, cause?}` (packages/contracts/src/checkpointDiff.ts:51-65)
- `OrchestrationSearchThreadsError {message, cause?}` (packages/contracts/src/threadSearch.ts:36-42)

`cause` is `Schema.optional(Schema.Defect())`. Treat it as opaque (section 4.8).

`dispatchCommand` returns `{sequence: NonNegativeInt}` (orchestrationV2.ts:3212-3215; ws.ts:1853). A client can match that sequence against stream items to know when its command's events have arrived.

---

## 3. Sequences and cursors (shared concepts)

- There is one global, monotonically increasing sequence for the whole application event log. It covers both project events and v2 thread events (apps/server/src/persistence/OrchestrationEventStore.ts:1-12, "under one global sequence").
- Shell cursor: the shell snapshot's `snapshotSequence` is `latestApplicationSequence`, the max sequence over project events and v2 thread events (OrchestrationEventStore.ts:617-627; ws.ts:971-985; ShellStream.ts:42-61). Shell deltas carry the global sequence of the event that triggered them.
- Thread cursor: a thread snapshot's `snapshotSequence` is `MAX(sequence)` over that thread's v2 events only (apps/server/src/orchestration-v2/ProjectionStore.ts:4733-4750 for full snapshots, 5089-5099 for window snapshots). Thread event items carry the global sequence of the stored event. A thread's sequences are therefore sparse.
- Within one subscription, delivered sequences strictly increase. Writers publish in commit order through a "publish lane" (apps/server/src/orchestration-v2/EventSink.ts:232-262). Replay ranges are exclusive of `afterSequence` (EventSink.ts:716-760; OrchestrationEventStore.ts:651-675). Live events are filtered to `sequence > max(highWater, afterSequence)` (EventSink.ts:752-756; LiveStreamBudget.ts:300-338).
- Gaps are normal: coalescing drops superseded tool updates (thread stream, section 8) and the shell drops unchanged rows (section 5.5).
- Across resubscriptions the client should dedupe by sequence (`sequence <= lastApplied` means skip). The contract comments say so (orchestrationV2.ts:3224-3231, 3240-3246), and the official client does it (packages/client-runtime/src/state/threads.ts:444-469; packages/client-runtime/src/state/shellReducer.ts:136-143).

---

## 4. JSON encoding rules (question 5)

Both the RPC layer and the HTTP JSON bodies use `Schema.toCodecJson` (RPC: RpcSerialization.ts:41, RpcServer.ts:638-657; HTTP: effect:http-api/HttpApiEndpoint.ts:1432-1442, then `JSON.stringify` in effect:http-api/HttpApiBuilder.ts:1330-1347).

### 4.1 DateTime

- `Schema.DateTimeUtc` has a JSON codec that links to `String` (effect:Schema.ts:11158-11189). It encodes with `DateTime.formatIso`, which is `Date.prototype.toISOString()` (effect:Schema.ts:11053-11069; effect:internal/dateTime.ts:1258). On the wire that is always UTC with milliseconds and a `Z`, for example `"2026-10-09T12:00:03.000Z"`.
- Decode accepts any string `DateTime.make` accepts and normalizes to UTC. Strings without a zone are treated as UTC (effect:Schema.ts:11243-11266).
- `IsoDateTime` is just `Schema.String` (baseSchemas.ts:47) and is passed through untouched. It is used for project `createdAt`/`updatedAt` (packages/contracts/src/orchestrationProject.ts:25-26), shell `usageLimitResetAt` (orchestrationV2.ts:1872), provider failure `resetAt` (orchestrationV2.ts:1287), plan step `durationAnchorAt` (orchestrationV2.ts:1145), and search `messageCreatedAt` (threadSearch.ts:27). Do not assume these use the `toISOString` format. A test fixture uses `"2026-09-01T00:00:00Z"` (apps/server/src/orchestration-v2/ShellStream.test.ts:443-444).

### 4.2 Optional fields and null (important for Swift decoders)

- `Schema.optional(X)` means `optionalKey(UndefinedOr(X))`. Under toCodecJson, `Undefined` (and `Void`) encode as `null` (effect:SchemaAST.ts:908-934, `undefinedToNull`). The effect test suite pins it down: encoding `{a: undefined}` gives `{"a": null}`, decoding `{"a": null}` gives `{a: undefined}`, and an absent key stays absent (effect:test/schema/toCodec.test.ts:753-772).
- So a `Schema.optional` field may be absent, `null`, or a value. Concrete server cases that do emit `null`:
  - In bounded snapshots, a non-active `todo_list` plan is rebuilt with `explanation: undefined` (apps/server/src/orchestration-v2/threadHistoryPaging.ts:540), which goes out as `"explanation": null`.
  - A wire-projected `subagent` item gets `progress: truncateDetail(item.progress)` (WireProjection.ts:110). When progress was undefined, the wire shows `"progress": null`.
  - Shell rows set `lastVisitedAt` from the thread payload (ProjectionStore.ts:1514, 1769).
- Swift rule: treat `null` the same as absent for every field declared with `Schema.optional`.
- `Schema.optionalKey(X)`: the key may be absent, but if present it must be `X`. `null` is only allowed when `X` is `NullOr`. This matters for inputs: send `afterSequence` only when it has a value, never as `"afterSequence": null`. A null fails payload decode and the request gets a `Die` exit (RpcServer.ts:797-803).
- `Schema.NullOr(X)`: an explicit JSON `null`.
- `Schema.withDecodingDefault` fields (for example `pendingBackgroundTasks` and `providerInstanceHistory` on the thread shell, orchestrationV2.ts:1884-1892, or `settledOverride`, `settledAt`, `lastVisitedAt` on AppThread, orchestrationV2.ts:398-417) are filled in when missing during decode.

### 4.3 Branded IDs and strings

- Every entity id (`ThreadId`, `ProjectId`, `RunId`, `TurnItemId`, `MessageId`, `EventId`, `CommandId`, and so on) is `TrimmedNonEmptyString` plus a brand (baseSchemas.ts:7-27, 310-316). On the wire these are plain JSON strings, trimmed on both encode and decode, and never blank. No format is guaranteed. Test ids look like `"thread:compact-transport:fork"` or `"turn-item:<threadId>:<key>"`.
- Treat ids as opaque strings and percent-encode them when used as URL path segments (the test does: apps/server/src/orchestration-v2/boundedSnapshotTransport.test.ts:287).

### 4.4 Numbers

- `NonNegativeInt` and `PositiveInt` are `Schema.Int` with a bound check (baseSchemas.ts:29-30). They encode as plain JSON integers (effect:SchemaAST.ts:1912-1920: int and finite checks keep plain numbers).
- Sequences are integers, safe in Int64.
- Turn item `ordinal` values come from `runOrdinal * 1_000_000 + n`, where n runs from 1 to 999,999 within a run. Items without a run use 1 to 999,999 (apps/server/src/orchestration-v2/TurnItemPositionStore.ts:42-70). Example: the fourth item of run 7 has ordinal 7000004. Ordinals are stable per (thread, item) once allocated.
- An unconstrained `Schema.Number` would encode non-finite values as the strings `"NaN"`, `"Infinity"`, `"-Infinity"` (effect:SchemaAST.ts:4160-4166). The only unconstrained number in orchestrationV2.ts is `jsonRpcId` on raw provider events (orchestrationV2.ts:1628), which never reaches the wire.

### 4.5 Option and bigint

- No `Schema.Option`, `Schema.BigInt`, `Schema.Date`, `Map`, or `Set` appears in orchestrationV2.ts, orchestrationProject.ts, or environment.ts (grep found none). For reference only: Option encodes as `{"_tag":"Some","value":...}` / `{"_tag":"None"}` (effect:test/schema/toCodec.test.ts:1530-1536), and bigint encodes as a string (effect:internal/schema/toCodec.ts:79-82).

### 4.6 Unknown and JSON values

- `Schema.Unknown` (for example `dynamic_tool.input` and `output`, orchestrationV2.ts:1572-1573) passes through as a JSON value. The encoder validates that the value is JSON: finite numbers, strings, booleans, null, arrays, and plain objects (effect:SchemaAST.ts:5086-5089, 5162-5179, 5193-5196).
- A `dynamic_tool` item whose `input` is `undefined` is allowed by the wire projection (apps/server/src/orchestration-v2/WireProjection.test.ts:186-189). Whether it then encodes successfully is UNVERIFIED (the JSON check rejects `undefined`). Decode `input` defensively as optional.

### 4.7 Literal unions and forward compatibility

- Thread stream (orchestrationV2.ts:3320-3364, 3390-3391): an `event` whose `event.type` this build does not know, or a `turn-item.updated` whose payload `type` it does not know, decodes to the decode-only arm `{kind: "unknown-event", sequence, eventType}`. The client should skip it but still advance its resume cursor. A known type that fails to decode still fails the whole decode. The server never sends `unknown-event` itself.
- Turn item arrays: `projection.turnItems` uses `ForwardCompatibleUnionArray` (orchestrationV2.ts:1588-1590, 1797). `visibleTurnItems` and history page `items` drop rows whose nested item type is unknown (orchestrationV2.ts:1593-1608, 1802-1808, 3308-3314; helpers at baseSchemas.ts:183-286).
- `pendingBackgroundTasks` entries with an unknown `kind` decode as `background_task` (orchestrationV2.ts:770-828).
- `OrchestrationV2ShellStreamItem` and `OrchestrationV2ArchivedShellStreamItem` have no unknown arm (orchestrationV2.ts:1945-1981, 3163-3178). A newer server adding a kind would break strict decoders. A native client should skip unknown `kind` values.

### 4.8 Defects and error causes

- `Schema.Defect()` encodes a JavaScript `Error` as `{"name":..., "message":..., "cause"?: ...}` (cause recursive, no stack by default). Other values go through Effect's formatter (effect:Schema.ts:8990-9028; effect:test/schema/toCodec.test.ts:1559-1580).
- The exact nested content of `cause` on orchestration errors (Effect tagged errors wrapping other errors) is UNVERIFIED. Treat it as opaque diagnostic data.

### 4.9 The `...Json` schema variants

- `OrchestrationV2ThreadProjectionJson`, `OrchestrationV2ThreadShellJson`, `OrchestrationV2ShellSnapshotJson`, `OrchestrationV2DomainEventJson`, and `OrchestrationV2StoredEventJson` (orchestrationV2.ts:1991-2016, 2143-2148, 2363-2391, 2410-2448, 2451-2454, 2604-2608) replace `DateTimeUtc` with `DateTimeUtcFromString` and add a few decoding defaults (for example `settledAt` and `lastVisitedAt` default to null, orchestrationV2.ts:1996-2006).
- They are used for persistence and client caches, not for the wire. Examples: OrchestrationEventStore.ts:199-200 stores events with `OrchestrationV2DomainEventJson`; client caches in packages/client-runtime/src/platform/orchestrationCache.ts:3-26 and apps/mobile/src/connection/shell-cache-encoding.ts:2-17.
- The wire uses toCodecJson of the plain schemas. Both produce ISO date strings and the same field names, so in practice the shapes match.

---

## 5. subscribeShell (sidebar) (question 1)

### 5.1 Input

`OrchestrationV2SubscribeShellInput` (orchestrationV2.ts:3223-3235):

| Field | Type | Required | Meaning |
|---|---|---|---|
| `afterSequence` | NonNegativeInt | optional (optionalKey) | Skip the initial full snapshot and replay shell changes after this global sequence. |
| `requestCompletionMarker` | boolean | optional (optionalKey) | Emit `{kind:"synchronized"}` between initial catch-up and live delivery. |

There is no `includeArchived` and no `sinceSequence`. Archived threads come from a separate subscription (section 6).

### 5.2 Item kinds

`OrchestrationV2ShellStreamItem` (orchestrationV2.ts:1945-1981):

| kind | Fields | Notes |
|---|---|---|
| `synchronized` | none | Only when requested. |
| `snapshot` | `snapshot: OrchestrationV2ShellSnapshot`, `resolvedRepositoryIdentityRoots?: string[]` (optionalKey) | Without the roots field: authoritative. With it: metadata-only enrichment (section 5.6). |
| `project.updated` | `sequence`, `project: OrchestrationProjectShell` | Upsert. |
| `project.removed` | `sequence`, `projectId` | |
| `thread.updated` | `sequence`, `location: "active" or "archive"`, `thread: OrchestrationV2ThreadShell` | This server only emits `"active"` (ShellStream.ts:292-319; grep found no `location: "archive"` emitter). |
| `thread.removed` | `sequence`, `location`, `threadId` | Always `"active"` from this server. |

Snapshot body `OrchestrationV2ShellSnapshot` (orchestrationV2.ts:1931-1943): `{schemaVersion: PositiveInt, snapshotSequence, threads: ThreadShell[], archivedThreads: ThreadShell[], projects: ProjectShell[]}`.
- `schemaVersion` is `ORCHESTRATION_V2_PROJECTION_SCHEMA_VERSION = 2` (ProjectionStore.ts:532, 5809-5814; ws.ts:961, 1073).
- `archivedThreads` is always `[]` on the active shell (`buildActiveShellSnapshot`, ShellStream.ts:21-34; test ShellStream.test.ts:57-84).
- `threads` holds threads that are not deleted and not archived (`WHERE t.deleted_at IS NULL` plus `archivedAt IS NULL`, ProjectionStore.ts:5289-5294). They are ordered by `updated_at ASC, thread_id ASC` (ProjectionStore.ts:5300). No lineage filter is applied, so subagent and fork child threads are included.
- `latestVisibleMessage` is always `null` in shell rows. Message bodies are deliberately kept out (ProjectionStore.ts:1482-1484, 1748).

### 5.3 Fresh subscription (no afterSequence)

Code: ws.ts:1131-1139, 1101-1129; ShellStream.ts:182-212.

1. `snapshot` (unmarked, authoritative). `snapshotSequence = latestApplicationSequence`, read in the same SQL transaction as threads and projects (ShellStream.ts:36-61). Projects carry whatever repository identity is already available. The server does not wait for git probes (ws.ts:715-745).
2. Only if some workspace roots already resolved: a second `snapshot` with the same `snapshotSequence`, `threads: []`, `archivedThreads: []`, `projects` filtered to the resolved roots, and `resolvedRepositoryIdentityRoots` listing those roots (ShellStream.ts:186-212; test ShellStream.test.ts:313-341).
3. `synchronized`, if requested (ws.ts:1101-1104, 1128-1129).
4. Live deltas for events after `snapshotSequence`, merged with enrichment refresh snapshots that can arrive at any time after step 2 (ShellStream.ts:102-113; ws.ts:1134-1138). Events committed between the snapshot read and the live subscription are replayed after the marker, because the live source starts with a catch-up replay from `snapshotSequence` (OrchestrationEventStore.ts:677-695). So `synchronized` marks the end of the initial prefix, not a guarantee of zero lag.

### 5.4 Resume (afterSequence given)

Code: ws.ts:1140-1162; helpers at ws.ts:551-555, 686-713.

- `highWater = latestApplicationSequence`.
- The server falls back to the fresh flow of section 5.3 (full authoritative snapshot) when any of these holds:
  - `highWater - afterSequence < 0` (client cursor ahead of the store), or
  - `highWater - afterSequence > SHELL_RESUME_MAX_GAP` where `SHELL_RESUME_MAX_GAP = 1_000` (ws.ts:546-551). The gap counts global events, including events of every other thread, so a busy server can exceed it after a short disconnect.
  - the sum of stored payload JSON bytes in `(afterSequence, highWater]` exceeds `ORCHESTRATION_REPLAY_PAYLOAD_BUDGET_BYTES = 8 MiB` (ws.ts:552-555, 697-711; SQL in OrchestrationEventStore.ts:577-595).
- Otherwise, in order:
  1. Optionally a metadata-only `snapshot`, only if some roots resolved, with `snapshotSequence = highWater`, empty thread arrays, and `resolvedRepositoryIdentityRoots` (ws.ts:956-970, 1115-1124, 1151; ShellStream.ts:214-222). The authoritative shell body is never re-sent on resume (test ShellStream.test.ts:344-356).
  2. Replay deltas for `(afterSequence, highWater]` (ws.ts:1152-1157).
  3. `synchronized`, if requested.
  4. Live deltas after `highWater`, merged with enrichment refreshes (ws.ts:1158-1162).
- Pitfall: the metadata snapshot in step 1 carries `snapshotSequence = highWater`. A client that adopted it as its cursor would then drop every replay delta in step 2 as already seen. Never move the cursor on a snapshot that has `resolvedRepositoryIdentityRoots`. The official client keeps its prior sequence for such frames (packages/client-runtime/src/state/shellReducer.ts:70-120).

### 5.5 How deltas are derived

Code: ws.ts:986-1048; ShellStream.ts:63-100, 224-319.

- Source events: project events (`project.created`, `project.meta-updated`, `project.deleted`, OrchestrationEventStore.ts:148-152) and all v2 thread events, reduced to identity and sequence (`toShellApplicationEvent`, ShellStream.ts:73-83).
- Events are grouped up to 512 events or 50 ms (ws.ts:1034). Each group is coalesced to the newest event per aggregate and sorted by sequence (ShellStream.ts:85-100; test ShellStream.test.ts:86-98).
- For each surviving aggregate the server re-reads the current state, with up to 8 reads in parallel (ws.ts:1015-1030):
  - `project.deleted` becomes `project.removed`. Any other project event becomes `project.updated` with the current `OrchestrationProjectShell`, or `project.removed` if the project no longer exists (ws.ts:986-1009).
  - A thread event becomes `thread.updated` (location `"active"`) with the current shell. It becomes `thread.removed` (location `"active"`) when the shell is archived, deleted, or unknown (`getThreadShell` returns null for deleted threads, ProjectionStore.ts:5831-5896, 5289) (ShellStream.ts:288-319; tests ShellStream.test.ts:165-223).
- `sequence` on a delta is the sequence of the newest event for that aggregate in the batch. Deltas are full current state, not diffs, and they may reflect events newer than their `sequence`.
- `skipUnchangedThreadShells` (ShellStream.ts:224-273) drops a `thread.updated` whose shell equals the last one sent on this subscription in every field except `updatedAt`, unless at least `UNCHANGED_THREAD_SHELL_RESEND_MS = 5_000` ms passed since that thread was last sent. A `thread.removed` resets the memory for that thread (test ShellStream.test.ts:607-632). Skipped deltas leave sequence gaps.
- Thread shell rows contain no transcript content (WireProjection.test.ts:114-167).

### 5.6 Enrichment refresh snapshots

- When repository identity resolution completes, the server emits a metadata-only `snapshot` (ws.ts:1050-1083; ShellStream.ts:160-180):
  - Batched up to 64 changes or 25 ms.
  - `snapshotSequence` is the current `latestApplicationSequence`.
  - `projects` holds only the changed projects, with their new `repositoryIdentity`.
  - `threads` and `archivedThreads` are `[]`.
  - `resolvedRepositoryIdentityRoots` lists the roots.
- `dedupeShellEnrichment` drops repeated identical metadata frames. Any project delta or authoritative snapshot resets that dedupe memory (ShellStream.ts:115-158; tests ShellStream.test.ts:435-545).
- Client rule, matching the official reducer (shellReducer.ts:79-133):
  - Without `resolvedRepositoryIdentityRoots`: replace projects, threads, archivedThreads, and `snapshotSequence`.
  - With it: for each existing project whose id and workspaceRoot match a project in the frame, set `repositoryIdentity` exactly (including null) if its root is in the list. Leave everything else alone, including the cursor.

### 5.7 Cursor handling and shapes

- Apply a delta only when `sequence > cursor`, then set `cursor = sequence` (shellReducer.ts:136-196).
- `OrchestrationProjectShell` (orchestrationProject.ts:9-27):
  - Required: `id`, `title`, `workspaceRoot`, `defaultModelSelection` (NullOr), `scripts`, `createdAt` (IsoDateTime), `updatedAt` (IsoDateTime).
  - Optional: `repositoryIdentity` (NullOr), `defaultThreadEnvMode` (NullOr), `autoPull`, `faviconPath` (NullOr), `projectIcon` (NullOr).
- `OrchestrationV2ThreadShell` (orchestrationV2.ts:1836-1928):
  - Required: `createdBy`, `creationSource`, `id`, `projectId`, `title`, `providerInstanceId`, `modelSelection`, `runtimeMode`, `interactionMode`, `branch` (NullOr), `worktreePath` (NullOr), `lineage`, `forkedFrom` (NullOr), `activeProviderThreadId` (NullOr), `latestRunId` (NullOr), `activeRunId` (NullOr), `status` (`"idle"` or a run status), `pendingRuntimeRequest` (NullOr `{id, kind, createdAt}`), `latestVisibleMessage` (NullOr, always null), `latestUserMessageAt` (NullOr), `hasActionableProposedPlan`, `itemCount`, `visibleItemCount`, `createdAt`, `updatedAt`, `archivedAt` (NullOr), `settledOverride` (NullOr `"settled"|"active"`), `settledAt` (NullOr), `deletedAt` (NullOr).
  - Optional (`Schema.optional`, so absent, null, or value): `linkedPullRequest`, `pullRequests`, `branchPullRequest`, `historyOrigin`, `latestRunRequestedAt`, `latestRunStartedAt`, `latestRunCompletedAt`, `activityRunStartedAt`, `activityRunStatus`, `lastError`, `lastErrorClass`, `usageLimitResetAt`, `latestUserAuthoredMessageAt`, `pendingBackgroundTasks` (default `[]`), `providerInstanceHistory` (default `[]`), `goal`, `unsettledAt`, `snoozedUntil`, `snoozedAt`, `limitRecovery`, `pinnedAt`, `autoSettleDisabledAt`, `pinOrderKey`, `activeOrderKey`, `lastVisitedAt`, `titleRegeneration`.
  - The server always sets most of these optional fields (`shellFromState`, ProjectionStore.ts:1697-1774). It sets `linkedPullRequest`, `branchPullRequest`, `activeOrderKey`, and `historyOrigin` only when the thread has them.
- Errors: `OrchestrationV2GetShellSnapshotError` with message `"Failed to prepare the application shell stream"` (setup) or `"Failed while streaming the application shell"` (during streaming) (ws.ts:1163-1182).
- Heartbeats: none (section 1.5).
- Capability flag: server config `shellResumeCompletionMarker: true` (ws.ts:1728; contract at packages/contracts/src/server.ts:670-671).

---

## 6. subscribeArchivedShell (and getArchivedShellSnapshot)

Code: ws.ts:1746-1808, 1918-1919, 2033-2034; ShellStream.ts:321-344; schema orchestrationV2.ts:3155-3180.

- Input: `{}` (orchestrationV2.ts:3598-3601). There is no resume cursor and no completion marker. Every subscription starts with a snapshot.
- First item: `{kind:"snapshot", snapshot: OrchestrationV2ArchivedShellSnapshot}`.
  - `OrchestrationV2ArchivedShellSnapshot = {schemaVersion, snapshotSequence, projects, threads}` (orchestrationV2.ts:3155-3160).
  - `threads` are the archived (archivedAt not null), non-deleted threads (ProjectionStore.ts:5289-5294).
  - `snapshotSequence = latestApplicationSequence` (ws.ts:1746-1758).
  - `projects` is the full project list with available identity (ws.ts:1760-1764).
- Deltas (no `location` field):
  - `{kind:"thread.updated", sequence, thread}` when the thread's current shell is archived.
  - `{kind:"thread.removed", sequence, threadId}` when the batch's newest event for that thread is `thread.unarchived`, or `thread.deleted` with `payload.archivedAt` not null.
  - Otherwise nothing is emitted (ShellStream.ts:321-344; tests ShellStream.test.ts:225-262).
  - No project deltas are sent on this stream.
- Live tail: thread events after `snapshotSequence` from the bounded EventSink stream (ws.ts:1778-1779; Orchestrator.ts:10918-10926), grouped 512 / 50 ms, coalesced to the newest event per thread (ShellStream.ts:275-286), shells read 8 at a time, then `bufferLiveStream` (ws.ts:1781-1798).
- Edge case (inference from code, UNVERIFIED by any test): because only the newest event per thread per 50 ms window survives, a `thread.unarchived` followed within the same window by another event for the same thread produces neither `thread.removed` nor `thread.updated` on this stream. The thread does show up as `thread.updated` on the active shell. A client holding both lists should remove a thread from its archive list when the active shell reports it.
- Errors: `OrchestrationV2GetShellSnapshotError` with `"Failed to load archived thread snapshot"` or `"Failed while streaming archived threads"` (ws.ts:1765-1771, 1799-1805).
- `getArchivedShellSnapshot` (unary) returns the same snapshot object (ws.ts:1918-1919).

---

## 7. subscribeThread (question 2)

### 7.1 Input

`OrchestrationV2SubscribeThreadInput` (orchestrationV2.ts:3238-3257):

| Field | Type | Required | Meaning |
|---|---|---|---|
| `threadId` | ThreadId | yes | |
| `afterSequence` | NonNegativeInt | optionalKey | Resume: replay events after this sequence instead of sending a snapshot. |
| `requestCompletionMarker` | boolean | optionalKey | Emit `synchronized` after the initial prefix. |
| `acceptBoundedSnapshot` | boolean | optionalKey | Any snapshot this subscription sends is a bounded window with history paging metadata. Only `true` opts in (ws.ts:614-618; ws.test.ts:43-47). |
| `acceptCompactTurnItems` | boolean | optionalKey | With bounded snapshots, allows omitting local visible items from `projection.turnItems` (`turnItemsOmitLocalVisible`). Ignored for full snapshots (boundedSnapshotTransport.test.ts:336-368). |

There is no "window size" input. The window policy is fixed on the server (section 10).

### 7.2 Item kinds

`OrchestrationV2ThreadStreamItem` (orchestrationV2.ts:3366-3392):

| kind | Fields |
|---|---|
| `synchronized` | none |
| `snapshot` | `snapshotSequence`, `projection: OrchestrationV2ThreadProjection`, plus optionalKey `historyCursor` (string or null), `hasMoreHistory`, `latestLocalTurnOrdinal` (int or null), `payloadBudgetExceeded`, `turnItemsOmitLocalVisible` (literal true) |
| `event` | `sequence`, `event: OrchestrationV2DomainEvent` |
| `unknown-event` | decode-only: `sequence`, `eventType` |

- There is no separate "reset", "batch", "caught-up", or heartbeat kind. A `snapshot` is only ever the first item of a subscription. It may arrive even when `afterSequence` was sent (resume fallback, section 7.4), so treat every snapshot as a full reset and set the cursor to `snapshotSequence`.
- Full (non-bounded) snapshots carry no history fields (ws.ts:851-855).
- Bounded snapshots always include `historyCursor`, `hasMoreHistory`, `latestLocalTurnOrdinal`, and `payloadBudgetExceeded`. They include `turnItemsOmitLocalVisible: true` only when compacted (ThreadStream.ts:47-88).
- Events are never batched into a single item. Each `event` item wraps exactly one stored event.

### 7.3 Fresh subscription (no afterSequence)

Code: ws.ts:747-860, 939.

1. `ensureLegacyTranscript(threadId)` imports a migrated v1 transcript if needed. On failure: `OrchestrationV2GetThreadProjectionError` "Failed to hydrate migrated thread <id>" (ws.ts:761-770).
2. Snapshot read:
   - Bounded: `getThreadSnapshotWindow(threadId, {rowLimit: 77, userTurnLimit: 10})`, then `buildBoundedThreadStreamSnapshot` (ws.ts:827-850; ThreadStream.ts:70-88).
   - Full: `getThreadSnapshot` plus wire projection (ws.ts:834, 851-855). The full projection includes every turn item. The perf test measured a 600-row full snapshot at 10,375,121 bytes against roughly 67 KB bounded (apps/server/src/orchestration-v2/ThreadTransportPerformance.test.ts:30-42). A native client should send `acceptBoundedSnapshot: true`.
3. Emit `snapshot`, then `synchronized` if requested, then live events from `snapshotSequence` (ws.ts:856-859).
4. The live source subscribes lazily after the prefix and starts with a catch-up replay from `snapshotSequence` (EventSink.ts:716-760), so nothing is lost between the snapshot read and the subscription. Those catch-up events arrive after the marker.

A nonexistent thread fails the stream with `OrchestrationV2GetThreadProjectionError` "Failed to load orchestration V2 thread <id>" (ws.ts:836-843). The official client asks HTTP first and treats a 404 as deleted (packages/client-runtime/src/state/threads.ts:831-867).

### 7.4 Resume (afterSequence given): catch-up limits and fallback

Code: ws.ts:862-937; ThreadStream.ts:14-40, 90-124.

- `highWater = latestAgentSequence(threadId)`, the thread's own max sequence (OrchestrationEventStore.ts:597-614).
- Falls back to `snapshotThenLive` (section 7.3, honoring the bounded and compact flags) when any of these holds:
  1. `afterSequence > highWater` (ws.ts:880-882). This includes passing a global sequence from the shell that is larger than this thread's own max.
  2. Replay stats over `(afterSequence, highWater]` (SQL counts at most 129 rows, OrchestrationEventStore.ts:547-575): `eventCount > THREAD_RESUME_MAX_REPLAY_EVENTS (128)` (ThreadStream.ts:14-15).
  3. Raw stored payload JSON bytes over the range `> THREAD_RESUME_MAX_RAW_PAYLOAD_BYTES (1,048,576)` (ThreadStream.ts:20-30; ws.ts:900-907).
  4. The range contains this thread's `thread.created` event and the thread shell currently exists (ws.ts:908-922).
  5. After loading and wire-projecting the replay (limit 129): `decideThreadResume` returns snapshot when `afterSequence > highWater`, more than 128 events, or projected JSON bytes `> THREAD_RESUME_MAX_REPLAY_ENCODED_BYTES (1,048,576)` (ThreadStream.ts:17-18, 32-40, 106-124; ws.ts:923-932; tests ThreadStream.test.ts:114-194).
- Otherwise: replay `event` items (up to 128, not coalesced), then `synchronized` if requested, then live events after `highWater` (ws.ts:933-936). If `afterSequence == highWater`, the replay is empty and only the marker (if requested) precedes live.

### 7.5 Ending

- The server does not end the stream on `thread.deleted`. There is no take-until in ws.ts:747-941. The official client treats a `thread.deleted` event as deletion and stops applying (threads.ts:489-500, 553-556).
- Stream failures are `OrchestrationV2GetThreadProjectionError` with these messages (ws.ts):
  - "Failed to hydrate migrated thread <id>" (761-770)
  - "Failed while streaming orchestration V2 thread <id>" (785-792), which includes buffer overflow
  - "Failed while replaying orchestration V2 thread <id>" (811-818)
  - "Failed to load orchestration V2 thread <id>" (836-843)
  - "Failed to prepare orchestration V2 thread <id> replay" (870-879)
  - "Failed to measure orchestration V2 thread <id> replay" (890-899)
  - "Failed to locate recreated orchestration V2 thread <id>" (909-918)

### 7.6 Event items

- `event` is `OrchestrationV2DomainEvent` (orchestrationV2.ts:1645-1782).
- Base fields (orchestrationV2.ts:1634-1643): `id`, `threadId`, `runId?`, `nodeId?`, `driver?`, `providerInstanceId?`, `rawEventId?`, `occurredAt`. Unset base fields are omitted, not null: events are built with `compactUndefined` (apps/server/src/orchestration-v2/ProviderEventIngestor.ts:269-301) and re-read with conditional spreads (OrchestrationEventStore.ts:217-243).
- Types and payloads:
  - `thread.created` and the `thread.*` family (archived, unarchived, deleted, settled, unsettled, snoozed, unsnoozed, pinned, auto-settle-set, unpinned, pin-reordered, active-reordered, visited, marked-unread, metadata-updated, pull-request-synced, runtime-mode-updated, interaction-mode-updated, model-selection-updated, provider-switched): payload is the full `OrchestrationV2AppThread`.
  - `run.created` / `run.updated`: full Run.
  - `run.background-work-cancelled`, `run-attempt.created` / `run-attempt.updated`, `node.updated`, `subagent.updated`.
  - `provider-session.attached` / `provider-session.updated` / `provider-session.detached`, `provider-thread.updated`, `provider-turn.updated`, `runtime-request.updated`.
  - `message.updated`: full `OrchestrationV2ConversationMessage` including `text`.
  - `turn-item.updated`: full turn item, wire-projected.
  - `plan.updated`, `checkpoint-scope.created`, `checkpoint.captured`, `checkpoint.rollback-requested`.
  - `context-handoff.updated`: wire-projected.
  - `context-transfer.created` / `context-transfer.updated`.
- Raw provider events (`OrchestrationV2RawProviderEvent`, orchestrationV2.ts:1619-1631) are not in the union and never reach the stream. Events only reference them through `rawEventId`.
- Every replay and live event passes through `projectDomainEventForWire` (ws.ts:779-783, 804-808; also EventSink.ts:748). It projects `turn-item.updated` payloads and `context-handoff.updated` payloads (WireProjection.ts:233-241). All other events are sent in full.
- Upsert semantics: `message.updated` and `turn-item.updated` carry the whole current object (ProviderEventIngestor.ts:454-473). Replace by id. Text fields are replacements, not deltas.

### 7.7 Resume cursor

- Cursor = `snapshotSequence` of the last snapshot, then the `sequence` of every later `event` or `unknown-event` item, but only when it is greater than the current cursor (official client threads.ts:444-469, 584-585).
- After an HTTP snapshot load, resume with `afterSequence = snapshotSequence` (threads.ts:831-893; comments at orchestrationV2.ts:3240-3246 and apps/server/src/orchestration-v2/http.ts:43-48).
- Server config advertises `threadResumeCompletionMarker: true` (ws.ts:1729; server.ts contract 677-678).

---

## 8. Live event coalescing (ThreadLiveEventCoalescer)

File: apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts. It applies only to the live tail of subscribeThread (ws.ts:772-793). It does not apply to the replay prefix (ws.ts:795-819, 933-936) or to the shell streams.

- Coalescable events (24-37): `turn-item.updated` whose `payload.status === "running"` and whose `payload.type` is one of `command_execution`, `file_change`, `file_search`, `web_search`, `dynamic_tool`.
- Window: `COALESCE_WINDOW = 50 ms`, `MAX_PENDING_UPDATES = 512` (18-19).
  - The first pending coalescable event starts a 50 ms timer (163-167). Further coalescable events join the pending list.
  - Reaching 512 pending flushes immediately (168-172).
  - Any other event, or a synchronization marker, cancels the timer and flushes immediately, including itself (176-186).
  - The end of the source also flushes (222-229, 246-254).
- Coalescing rule (`coalesceLiveToolUpdatedEvents`, 39-86):
  - Within each run of consecutive coalescable events, keep only the latest event per key `(threadId, runId, payload.id)`.
  - Non-coalescable events are kept and act as boundaries.
  - Survivors stay in sequence order.
  - Terminal updates (status not `running`) are never dropped.
  - Tests: ThreadLiveEventCoalescer.test.ts:99-127 (different item ids are both kept; different runs are not merged; a completion flushes first), 129-168 (immediate flush on another event or marker).
- Effect on the wire: running tool progress for one item is delivered at most about every 50 ms. Sequences of dropped intermediate updates never arrive. The final state always arrives.
- Assistant text and reasoning are not coalesced here. They are throttled upstream at ingestion (section 8.1).
- The coalescer has its own budget (section 9). An overflow fails the stream.

### 8.1 Assistant text streaming (assistantStreaming.ts)

- Setting `responseStreamingMode` is `"turn" | "paragraph"` and defaults to `"paragraph"` (packages/contracts/src/settings.ts:993-999, 1133-1135). The filter runs on provider events before they become stored events (apps/server/src/orchestration-v2/RunExecutionService.ts:1187-1199). It therefore shapes what is persisted and what any stream sees.
- Rules (assistantStreaming.ts:91-129):
  - A `node.updated` for a running `assistant_message` node is dropped.
  - For assistant `message.updated` events and for `turn_item.updated` with `assistant_message` or `reasoning` items:
    - `streaming: false` (final): passes through with the full text. Throttle state resets.
    - `"turn"` mode: streaming updates are dropped. Only the final event is stored.
    - `"paragraph"` mode: at most one streaming update per 400 ms per key `event type + message id`. The `text` is cut down to the "ready" prefix, and the update is skipped if that prefix is empty or unchanged.
- The ready prefix (`splitBufferedAssistantText`, 22-89) ends at the last safe markdown boundary outside an open code fence: a blank line, a closing fence, the start of a list item, or an unindented ATX heading. A section title line holds the boundary until a content line follows it.
- On the wire, each streaming `turn-item.updated` / `message.updated` carries the whole text so far up to that boundary, with `streaming: true`. The client replaces the text.

---

## 9. Live stream budget (LiveStreamBudget)

File: apps/server/src/orchestration-v2/LiveStreamBudget.ts.

- Limits per budget: `LIVE_STREAM_MAX_ITEMS = 1_000` items and `LIVE_STREAM_MAX_SERIALIZED_BYTES = 8 MiB`. Each item is measured once with `Buffer.byteLength(JSON.stringify(item))` (17-18, 25-37).
- What is counted: every item received from the source and not yet released. A delivered batch stays charged until the next pull, which RpcServer performs only after the client's Ack ("One budget covers one subscription and its delivery stream, including the batch waiting for an RPC ACK", 39; delivery logic 139-192).
- Where budgets sit:
  - subscribeThread: stage 1 is the EventSink bounded replay plus live stream (`replayAndBufferProjectedLiveEvents`, EventSink.ts:741-750). Stage 2 is the coalescer's own budget (ThreadLiveEventCoalescer.ts:95).
  - subscribeShell: stage 1 is `OrchestrationEventStore.streamProjectedApplicationEvents` (OrchestrationEventStore.ts:677-695). Stage 2 is `bufferLiveStream` (ws.ts:1040-1048).
  - subscribeArchivedShell: EventSink bounded stream plus `bufferLiveStream` (ws.ts:1778-1798).
  - Two stages can retain at most twice the limits (LiveStreamBudget.ts:265-271).
- Replay pages from the database are charged one item at a time as they are delivered (`Stream.rechunk(1)`), so a fast reader can replay a page larger than the budget (313-326; test LiveStreamBudget.test.ts:164-184).
- Overflow:
  - Creates `LiveStreamBufferError` with message "The live event buffer is full. Resume from the last received sequence." (12-15, 68-85).
  - Closes the source and drops the PubSub subscription immediately (155-178, 232-235; tests LiveStreamBudget.test.ts:56-76, 81-125).
  - The error reaches the client on the next pull, which happens after the client acks the in-flight chunk.
- What the client sees: an `Exit` Failure with the method's error.
  - subscribeThread: `OrchestrationV2GetThreadProjectionError` with "Failed while streaming orchestration V2 thread <id>" (ws.ts:785-792).
  - subscribeShell: `OrchestrationV2GetShellSnapshotError` with "Failed while streaming the application shell" (ws.ts:1173-1182). For stage 1 the inner cause is a persistence error for operation "OrchestrationEventStore.streamApplicationEvents:buffer" (OrchestrationEventStore.ts:689-694).
  - subscribeArchivedShell: "Failed while streaming archived threads".
- Expected client reaction: resubscribe with `afterSequence` set to the last applied sequence. The official client retries expected failures after 250 ms (threads.ts:895-900; packages/client-runtime/src/state/shell.ts:406-410).

---

## 10. Bounded snapshot (question 3)

### 10.1 Policy constants

apps/server/src/orchestration-v2/threadHistoryPaging.ts:

| Constant | Value | Line |
|---|---|---|
| `THREAD_HISTORY_PAGE_POLICY.maxUserTurns` | 10 | 13-17 |
| `THREAD_HISTORY_PAGE_POLICY.maxItems` | 75 | 13-17 |
| `THREAD_HISTORY_PAGE_POLICY.maxEncodedBytes` | 1,048,576 | 13-17 |
| `OLDER_THREAD_USER_TURN_LIMIT` (history pages) | 20 | 19 |
| `THREAD_HISTORY_MAX_RAW_TURNS` | 150 | 25 |
| `THREAD_HISTORY_SNAPSHOT_ROW_LIMIT` | 77 (75 + 2) | 27-28 |
| `THREAD_HISTORY_CURSOR_MAX_LENGTH` | 4,096 | 30-31 |

Definitions (threadHistoryPaging.ts:165-177):
- Turn start: a `user_message` with `inputIntent` of `turn_start` or `queued_turn`.
- User turn: a turn start with `createdBy: "user"`. Steering messages (`steer`, `promoted_queued_to_steer`) do not start turns.

### 10.2 What the recent window contains

`selectOlderTimelinePage` / `selectRecentTimelineWindow`, threadHistoryPaging.ts:179-261. The walk goes backward over `projection.visibleTurnItems` from the newest row:

- If any user turn exists in the range: collect complete turns until 10 user turns or 150 raw turn starts are included. No item or byte cap applies in this mode (`rowBytes = 0` when a turn limit is set, line 207). One turn with heavy tool activity can therefore make the window large, which is reported as `payloadBudgetExceeded: true`.
- If no user turn exists (agent-only child threads, for example): up to 75 rows within the byte budget, and always at least one row so an oversized item cannot block paging (threadHistoryPaging.test.ts:288-309).
- For bounded snapshots the byte budget is 1 MiB minus the control-plane bytes, minus all `run_interrupt_request` items, minus 1,024 (threadHistoryPaging.ts:474-502). Local rows are charged twice because their item also appears in `turnItems` (95-104).
- Tests: 90 plain rows give 75 visible rows, a cursor, and `latestLocalTurnOrdinal` 90 (threadHistoryPaging.test.ts:162-176; ThreadStream.test.ts:196-210). With only background (agent) turn starts and one user turn, the 150 raw-turn ceiling applies (threadHistoryPaging.test.ts:178-210).

Server-side SQL pre-window (`readCanonicalProjection` with a window, ProjectionStore.ts:2718-2849), which runs before the selection above:
- Eligible items exclude rolled-back runs, `queued_turn` user messages of cancelled runs, and superseded interrupt results that have no request.
- The boundary is the oldest of the 12 most recent user-turn anchors (limit + 2), or of the 152 most recent raw turn anchors.
- Rows from the boundary on are loaded (no row limit when user anchors exist, otherwise the newest 77 rows).
- Added on top: the `run_interrupt_request` items of selected runs, and always the newest item of the thread.
- Window snapshot entry point: ProjectionStore.ts:5059-5109. Fork ancestry handling: ProjectionStore.ts:3286-3437.

### 10.3 Control-plane arrays are windowed, not full

- The contract comment says a bounded snapshot has "full control-plane projection arrays with only a recent window of timeline rows" (orchestrationV2.ts:3278-3282). The server implementation is narrower.
- With a window, the SQL loads the following only for the window cohort (runs, nodes, messages, plans, and so on referenced by window items) plus live or active rows (ProjectionStore.ts:2853-3209):
  - `runs` (active statuses or cohort), `attempts`, `nodes` (cohort, active, and their ancestors), `subagents`, `providerSessions`, `providerThreads`, `providerTurns`, `runtimeRequests` (pending/waiting or cohort)
  - `messages` (cohort message ids or messages of active runs), `plans` (active or cohort), `checkpointScopes`, `checkpoints`, `contextHandoffs`, `contextTransfers`
- Then `buildBoundedThreadProjection` (threadHistoryPaging.ts:454-575) trims further:
  - `plans`: active plans plus plans referenced by window items. Non-active `proposed_plan` gets `markdown: ""`. Non-active `todo_list` gets `explanation: undefined`, which is `null` on the wire. Both get `detailInTurnItem: true` (525-541).
  - `contextHandoffs`: pending and ready ones, plus ones referenced by window `handoff` items. Others get `summaryText: ""` and `detailInTurnItem: true` (542-553).
  - `messages`: messages referenced by window items' `messageId`, plus messages of the latest run and of preparing/starting/running/waiting/queued runs (by `runId` or the run's `userMessageId`), plus any message with `delegatedCompletion` (381-417).
  - `turnItems`: the local items of the window's visible rows (in `turnItems` order), followed by every `run_interrupt_request` item that sits outside the window (340-379, 511-523; tests threadHistoryPaging.test.ts:447-496; boundedSnapshotTransport.test.ts:322-330).
  - `visibleTurnItems`: the window rows, with `position` renumbered from 0 (510).
  - `thread` is the full `OrchestrationV2AppThread`.

### 10.4 Metadata fields

From threadHistoryPaging.ts:563-574 and ThreadStream.ts:52-68:
- `historyCursor`: a cursor for the oldest window row, or `null` when nothing older exists.
- `hasMoreHistory`: true when rows older than the window exist.
- `latestLocalTurnOrdinal`: max `ordinal` over the projection's `turnItems`. The SQL window always includes the newest item, so this is the thread's newest local ordinal (ProjectionStore.ts:2829-2838). Clients use it as a watermark: an incoming `turn-item.updated` for an item not in the window, with `ordinal <=` the watermark, belongs to unloaded history and is dropped (packages/client-runtime/src/state/orchestrationV2Projection.ts:89-150).
- `payloadBudgetExceeded`: true when the control bytes alone exceed 1 MiB, or the whole bounded projection does (572-573; test threadHistoryPaging.test.ts:636-659).

### 10.5 Compact turnItems (`turnItemsOmitLocalVisible`)

- Server (packages/shared/src/orchestrationV2BoundedSnapshot.ts:14-34): if the first N entries of `turnItems` are the same objects as the items of the N local visible rows in visible order, drop them and set the marker. If nothing would be omitted, or the shape does not match, send the unchanged projection with no marker. A row is local when `visibility === "local"` or `sourceThreadId === projection.thread.id`.
- Client restore, required before using the projection (orchestrationV2BoundedSnapshot.ts:36-58):

```
turnItems = visibleTurnItems.filter(isLocal).map(row => row.item) + turnItems
```

- Opt in over WebSocket with `acceptCompactTurnItems: true` (plus `acceptBoundedSnapshot: true`). Over HTTP use the query `compactTurnItems=1`. Any other value is ignored (environmentHttp.ts:587-593; http.ts:196; test boundedSnapshotTransport.test.ts:285-306).

### 10.6 visibleTurnItems rows

- `OrchestrationV2ProjectedTurnItem = {position, visibility: "local"|"inherited"|"synthetic", sourceThreadId, sourceItemId, item}` (orchestrationV2.ts:1610-1616).
- Fork children (`forkedFrom.type === "run"`): the parent's rows up to the fork run come first as `inherited`, then one `synthetic` fork marker (id `turn-item:fork:<threadId>`, type `fork`, ordinal 0), then the local rows (ProjectionStore.ts:1230-1254, 1312-1342, 4857-4875; test boundedSnapshotTransport.test.ts:309-321).
- `position` is relative to the window or page, not a global index. Clients renumber after merging (packages/client-runtime/src/state/threadHistoryMerge.ts:56-131).

---

## 11. HTTP endpoints (question 3, continued)

Contract: packages/contracts/src/environmentHttp.ts:583-641. Handlers: apps/server/src/orchestration-v2/http.ts:49-236.

### 11.1 Common rules

- Request headers (environmentHttp.ts:80-84):
  - `x-t3-orchestration-protocol: 2` is required, as the literal string "2".
  - `authorization` and `dpop` are optional in the schema. The official client sends `authorization: Bearer <token>`, or `authorization: DPoP <token>` plus a `dpop: <proof>` bound to method and URL. Local or primary connections use a session cookie (packages/client-runtime/src/state/environmentHttpAuth.ts:27-36, 54-96).
- A missing or wrong protocol header fails header decoding with an empty `400 Bad Request` body (effect:http-api/HttpApiError.ts:468-503; effect:http-api/HttpApiBuilder.ts:868-870). The `EnvironmentAuthenticatedAuth` middleware wraps the whole handler, so authentication runs before header decoding (HttpApiBuilder.ts:850-853, 932-948).
- Scope check: `orchestration:read` (http.ts:156, 169, 183, 205). A missing scope returns `403 EnvironmentScopeRequiredError {code:"insufficient_scope", requiredScope, requiredPermission?, traceId}` (environmentHttp.ts:168-185; apps/server/src/auth/http.ts:122-134, 219-227).
- Bad credentials return `401 EnvironmentAuthInvalidError {code:"auth_invalid", reason:"missing_credential"|"invalid_credential", dpopFailureReason?, traceId}` (environmentHttp.ts:148-166).
- Errors are serialized as `{"_tag": <class>, ...fields}` with the status from `httpApiStatus` (environmentHttp.ts:130-242).
- Responses are `application/json`. The global compression middleware negotiates br, gzip, or deflate (in that preference) for bodies of at least 1,024 bytes (apps/server/src/http.ts:235-237; effect:http/HttpMiddleware.ts:524-554).

### 11.2 Endpoints

| Method and path | Query | Success body | Errors |
|---|---|---|---|
| `GET /api/orchestration/shell` | none | `OrchestrationV2ShellSnapshot` (`archivedThreads: []`) | 403, 500 (`orchestration_snapshot_failed`) |
| `GET /api/orchestration/threads/:threadId` | none | `{snapshotSequence, projection}`: full wire-projected projection, no history fields (http.ts:165-179) | 403, 404 (`thread_not_found`), 500 (`orchestration_thread_snapshot_failed`) |
| `GET /api/orchestration/threads/:threadId/bounded` | `compactTurnItems?` (only `"1"` opts in) | `OrchestrationV2ThreadBoundedSnapshot` (http.ts:180-200) | 403, 404, 500 (`orchestration_thread_history_failed`) |
| `GET /api/orchestration/threads/:threadId/history` | `cursor` (required), `throughEntryId?`, `view?` (`conversation` or `activity`) | `OrchestrationV2ThreadHistoryPage` (http.ts:201-234) | 400 (`invalid_history_cursor`), 403, 404, 500 (`orchestration_thread_history_failed`) |

Notes:
- The shell HTTP snapshot uses only identity that is already available, with no `resolvedRepositoryIdentityRoots` (http.ts:59-89). The WebSocket enrichment frames fill identity in later (ws.ts:1085-1095).
- The bounded HTTP route uses the same window as the WebSocket bounded fallback: `rowLimit` 77 and `userTurnLimit` 10 when no anchor is given (http.ts:114-149; ws.ts:830-833).
- `OrchestrationV2ThreadBoundedSnapshot` (orchestrationV2.ts:3283-3302):
  - Required: `snapshotSequence`, `projection`, `historyCursor` (string or null), `hasMoreHistory`, `latestLocalTurnOrdinal` (int or null).
  - `payloadBudgetExceeded` is `Schema.optional`; the server always sends a boolean.
  - `turnItemsOmitLocalVisible` is optionalKey, literal `true`.
- `OrchestrationV2ThreadDetailSnapshot` (orchestrationV2.ts:3260-3275) declares optional `historyCursor`, `hasMoreHistory`, `latestLocalTurnOrdinal`, but the full-snapshot route never sets them (http.ts:174-177). They exist for client caches.
- Deleted threads: the history page returns 404 for a thread with `deletedAt` set (ProjectionStore.ts:4899-4900). The full and bounded snapshot paths only check that the projection row exists (ProjectionStore.ts:2693-2702), and `thread.deleted` keeps the row with `deleted_at` set (ProjectionStore.ts:1801, 1834, 1864). So a soft-deleted thread may come back as a projection whose `thread.deletedAt` is non-null instead of a 404. UNVERIFIED end to end, and no hard purge was found in ThreadDeletion.ts.

### 11.3 History page semantics

Code: ProjectionStore.ts:4889-4993; threadHistoryPaging.ts:263-324; http.ts:201-234.

- The server builds the full visible timeline index for the thread, including inherited fork rows, without loading payloads (ProjectionStore.ts:4760-4883). It then finds the cursor row by identity `(sourceThreadId, sourceItemId)`. If that identity is gone, it clamps the cursor's recorded position `p` to the timeline length, so a stale cursor still pages instead of failing (threadHistoryPaging.ts:263-279; test threadHistoryPaging.test.ts:311-330).
- The page is the rows strictly older than the cursor row:
  - When user turns exist in that range: up to 20 user turns or 150 raw turns. No item or byte cap.
  - Otherwise: up to 75 rows and 1 MiB, measured after wire projection (ProjectionStore.ts:4966-4990).
- `throughEntryId` (search jump): if the row whose `item.messageId ?? item.id` equals it is older than the cursor, the page widens to cover it. `maxUserTurns` becomes `min(40, max(20, user turns between target and cursor + (target is a user turn ? 0 : 1)))` and `maxItems` doubles to 150 (threadHistoryPaging.ts:295-316; ProjectionStore.ts:4979-4981). The entry id comes from search results (section 13).
- `view=conversation`: when the page has user turns, `command_execution`, `reasoning`, `file_change`, and `dynamic_tool` rows are removed (threadHistoryPaging.ts:21-24; ProjectionStore.ts:4928-4931, 4985-4987). `nextCursor` and `hasMoreHistory` still describe the complete page. `view=activity`, or no view, returns the complete page; only `"conversation"` changes behavior (http.ts:218). The official client fetches `conversation` then the complete page for search jumps, and only the complete page advances its cursor (threads.ts:687-735).
- Response `OrchestrationV2ThreadHistoryPage` (orchestrationV2.ts:3305-3317):
  - `snapshotSequence`: the thread's max sequence at read time.
  - `items`: chronological, oldest first. Positions are renumbered 0..n-1 within the page. Each item is wire-projected (ProjectionStore.ts:4962).
  - `nextCursor`: cursor of the oldest row in this page, or `null`.
  - `hasMoreHistory`.
- End of history: `hasMoreHistory: false` and `nextCursor: null` (threadHistoryPaging.ts:230-245; test threadHistoryPaging.test.ts:299-308).
- Pages do not change when newer items are appended, because the cursor is identity-based (test threadHistoryPaging.test.ts:332-355).
- Merge on the client: dedupe by `sourceThreadId:sourceItemId`, put the page before existing rows, renumber positions (threadHistoryMerge.ts:62-131).

### 11.4 Cursor format

- Encoding (threadHistoryPaging.ts:39-45, 110-127): `base64url(JSON.stringify({v:1, seq:<snapshotSequence>, st:<sourceThreadId>, si:<sourceItemId>, p:<position>}))`, using Node's base64url (no `=` padding, URL-safe alphabet).
- The server rejects an empty cursor, a cursor longer than 4,096 chars, invalid base64/JSON, `v != 1`, or missing or invalid fields with `InvalidThreadHistoryCursorError`, which becomes `400 {code:"invalid_request", reason:"invalid_history_cursor"}` (threadHistoryPaging.ts:129-163; http.ts:206-212).
- `seq` is validated but not used for selection. A grep for `.seq` finds only the validator.
- Clients must treat the cursor as opaque (orchestrationV2.ts:3278-3281).
- Example: `eyJ2IjoxLCJzZXEiOjQ4MTkwLCJzdCI6InRocmVhZF9hYmMiLCJzaSI6InR1cm4taXRlbTp0aHJlYWRfYWJjOjQxIiwicCI6MTJ9` decodes to `{"v":1,"seq":48190,"st":"thread_abc","si":"turn-item:thread_abc:41","p":12}`.

### 11.5 Official client timeouts and fallbacks (for reference)

- Bounded snapshot: 6 s. History page: 6 s. Full snapshot: 20 s (packages/client-runtime/src/state/boundedThreadSnapshotHttp.ts:19-20; threadHistoryHttp.ts:14; threadSnapshotHttp.ts:16-22).
- If the bounded route returns a plain 404 or invalid JSON (an older server), the client tries the full snapshot route. A structured `EnvironmentResourceNotFoundError` means the thread is missing. Other failures fall back to the socket snapshot (boundedThreadSnapshotHttp.ts:60-173).

---

## 12. Wire projection (question 4)

File: apps/server/src/orchestration-v2/WireProjection.ts.

### 12.1 Where it is applied

- WebSocket thread snapshots (ws.ts:854; ThreadStream.ts:76-79)
- HTTP thread snapshots (http.ts:98-102, 135-138)
- History pages (ProjectionStore.ts:4962)
- `getThreadProjection` (ws.ts:1930-1936)
- `launchThread` result projection (ws.ts:2003-2006)
- Every replay and live thread event (ws.ts:782, 807; EventSink.ts:748)

### 12.2 Per turn item type (`projectTurnItemForWire`, 76-126)

- `command_execution`:
  - `output` is removed.
  - `outputOmitted: true` is added when the output was non-blank.
  - `outputIndicatesFailure: true` is added when it was already true, when `exitCode` is non-zero, or when the first 32 KiB of output matches failure regexes (packages/shared/src/toolOutput.ts:210-222).
  - `input` is kept whole. It is not truncated on the timeline.
  - Tests: WireProjection.test.ts:254-267, 329-344.
- `file_change`: `diffStr`, `oldStr`, and `newStr` are removed. A failed edit keeps `diffStr` (the provider's error) truncated to 32 KiB (WireProjection.ts:97-105; test 346-371).
- `subagent`: `prompt`, `progress`, and `result` are truncated to 32 KiB (UTF-8 safe) with the exact suffix `"\n… output truncated for transport"` (WireProjection.ts:14, 18-35, 106-112; test 233-252). An undefined `progress` comes out as `null`.
- `dynamic_tool` (WireProjection.ts:113-122):
  - `output` is replaced by compact identity metadata from `compactDynamicToolOutput` (toolOutput.ts:111-183): `isError`, `threadId`, `messageId`, `taskId`, `scheduledTaskId`, `status: "rolled_back"`, `htmlRender`, an MCP app reference (under its stored key), `thread.threadId`, and `threads[]`, bounded to 8 KiB. If none of that is present, `output` is removed.
  - `outputOmitted: true` is set when the raw output was non-empty.
  - `input` is kept if its JSON is at most 16 KiB. Otherwise it becomes `{"summary": <first non-blank line, at most 160 chars>, "truncated": true}` (WireProjection.ts:15, 37-74).
  - Tests: WireProjection.test.ts:169-231, 373-401.
- `handoff`: `summary` is removed (WireProjection.ts:78-81; test 53-77).
- Every other type passes through unchanged. That covers `user_message`, `assistant_message`, `reasoning` (full text), `proposed_plan`, `todo_list`, `user_input_request`, `file_search`, `web_search`, `approval_request`, `checkpoint`, `run_interrupt_request`, `run_interrupt_result`, `system_notice`, `error`, `compaction` (its `summary` is kept), `fork`, `thread_created`, `secret_request`, and `notification` (test 97-112).
- `projection.contextHandoffs`: `history` and `delivery` are removed and `summaryText` is set to `""` (WireProjection.ts:203-208, 224). The same applies to `context-handoff.updated` event payloads.
- Not projected: `messages` (full text), `runs`, `nodes`, `plans` (except the bounded trimming in section 10.3), and the rest of the control state.

### 12.3 Images

- At ingestion, image bytes in tool output that the asset route cannot serve are stripped before persistence. The route serves at most the first 8 images, each at most the provider image size as base64 (ProviderEventIngestor.ts:469; apps/server/src/orchestration-v2/toolOutputImageBytes.ts:1-80; toolOutput.ts:256-284).
- The timeline never carries tool output, so it never carries image bytes.
- Detail reads replace each image's bytes with `{"type":"image","mimeType":...}` at the same position (toolOutput.ts:286-300; WireProjection.ts:150-166).
- Fetch bytes through `assets.createUrl` (rpc.ts:381) with resource `{"_tag":"tool-output-image","threadId":...,"itemId":...,"index":n}` (packages/contracts/src/assets.ts:44-50, 70-90). The index is the image order in the stored output (toolOutput.ts:278-284).

### 12.4 getTurnItem (full item on demand)

- Input: `{threadId, itemId, revision?}` (orchestrationV2.ts:3458-3463). `revision` is a client cache key only. The server ignores it (ThreadManagementService.ts:293-300, 898-902).
- Output: `{item: OrchestrationV2TurnItem | null}`, where `null` means not found (orchestrationV2.ts:3466-3469).
- The lookup matches both `turn_item_id` and `thread_id` (ProjectionStore.ts:4669-4679). For inherited fork rows, pass the row's `sourceThreadId` and `sourceItemId`, as the web client does (apps/web/src/components/chat/V2ItemInspector.tsx:103-118).
- `projectTurnItemForDetail` (WireProjection.ts:168-201):
  - `command_execution`: `input` and `output` truncated to 256 KiB with the transport suffix (test WireProjection.test.ts:269-277).
  - `dynamic_tool`:
    - `input`: strings over 256 KiB are truncated; JSON over 256 KiB becomes a truncated JSON string.
    - `output`: image bytes are replaced by markers, then the result is bounded to 256 KiB. When the remainder is too large it becomes `[{"type":"text","text":<truncated JSON>}, {"type":"image","mimeType":...}, ...]` (tests 279-327).
  - `subagent`: the three text fields are truncated to 256 KiB.
  - `handoff` and `file_change`: same as the wire projection. Full diffs are not available here; use `getTurnDiff` / `getFullThreadDiff`.
  - All other types: unchanged.
- When to fetch (official client): `command_execution.outputOmitted === true`, or `dynamic_tool.outputOmitted === true`, or a `dynamic_tool` input that was summarized (packages/client-runtime/src/work-log/itemDetail.ts:139-149). The client keys its cache by item `updatedAt`, or `"live"` while the item is running (itemDetail.ts:131-137).
- Error: `OrchestrationV2GetThreadProjectionError` "Failed to load turn item" (ws.ts:1869-1879).

### 12.5 Diffs

- `getTurnDiff` input: `{threadId, fromTurnCount, toTurnCount, ignoreWhitespace?}` with `fromTurnCount <= toTurnCount`.
- `getFullThreadDiff` input: `{threadId, toTurnCount, ignoreWhitespace?}`.
- Both return `{threadId, fromTurnCount, toTurnCount, diff: string}` (checkpointDiff.ts:7-49; handlers ws.ts:1880-1899).
- Thread diffs have no HTTP route. The only diff route is `POST /api/pull-requests/diff` for pull requests (environmentHttp.ts:660-674).

### 12.6 getThreadProjection

- A compatibility RPC for older clients (ws.ts:1920-1948). It returns only a projection: a window with `rowLimit` 77, no user-turn limit in SQL, then `buildBoundedThreadProjection`, then wire projection.
- There is no cursor and no sequence, so it is not suitable for resuming.

---

## 13. Search RPCs (brief)

- `searchThreads`: input `{query: 2-200 chars after trim, limit?: 1-50}`. Output `{matches: [{threadId, projectId, source: "user"|"assistant", snippet (at most 240 chars), messageCreatedAt: IsoDateTime | null}]}` (threadSearch.ts:16-34).
- `searchThread` / `searchThreadStream` input (orchestrationV2.ts:3505-3523):
  - `threadId`
  - `query` (trimmed, 1-200 chars)
  - `skills?` (at most 1,000 entries, each `{name, displayName?}`, both at most 200 chars)
  - `index?`, `offset?` (int), `start?: {entryId, occurrence}`
- Result (orchestrationV2.ts:3526-3549): `{complete?, snapshotSequence, totalMatches, activeIndex, match: {entryId, runId, occurrence} | null, navigation?: at most 17 entries of {entryId, runId, startIndex, count}}`.
- The stream emits either:
  - one final result, or
  - an early `{complete: false, totalMatches: 1, activeIndex: 0, match}` followed by the final result. The final result omits `complete` (apps/server/src/orchestration-v2/ThreadFind.ts:357-440).
- Treat a missing `complete` as complete (official client: `result.complete !== false`, packages/client-runtime/src/state/orchestration.ts:64-69).
- `searchThread` (unary) returns the last stream item (ThreadFind.ts:443-447).
- A match's `entryId` is the value to pass as `throughEntryId` to the history route.

---

## 14. Versioning and capability negotiation (question 6)

- Protocol version 2 is required:
  - on `/ws?orchestrationProtocol=2` (426 otherwise)
  - on every orchestration HTTP route via `x-t3-orchestration-protocol: 2` (empty 400 otherwise)
- The environment descriptor `GET /.well-known/t3/environment` reports `orchestrationProtocolVersion: 2` (optionalKey Int, packages/contracts/src/environment.ts:224; apps/server/src/environment/ServerEnvironment.ts:217; route at environmentHttp.ts:449-453). The official client treats a missing value as 1 and requires equality (packages/client-runtime/src/connection/outdatedHostUpdate.ts:208; the param is set at packages/client-runtime/src/connection/compatibility.ts:40).
- Server config (RPCs `server.getConfig` and `subscribeServerConfig`, rpc.ts:462-463, 563) advertises `shellResumeCompletionMarker: true`, `threadResumeCompletionMarker: true`, `threadSnapshotPagination: true`, `threadFind: true`, and `threadFindProgressive: true` (ws.ts:1728-1732; schema at packages/contracts/src/server.ts:670-688).
  - The `threadSnapshotPagination` doc comment mentions `turnLimit`/`beforeCursor` inputs and `page` metadata (server.ts:679-684). No such inputs exist in the v2 WebSocket or HTTP APIs in this tree; a grep found them only in that comment. Read the flag as "bounded snapshots plus history paging are supported" (inference).
  - The official client sends `requestCompletionMarker` only when the matching config flag is true (shell.ts:337-341; threads.ts:808-811).
- Per-subscription opt-ins: `requestCompletionMarker`, `acceptBoundedSnapshot`, `acceptCompactTurnItems`. HTTP opt-in: `compactTurnItems=1`. Older servers ignore unknown inputs only on HTTP query strings. Sending unknown keys in an RPC payload was not tested here (UNVERIFIED; Effect structs usually ignore excess keys on decode).
- Data versioning: `schemaVersion: 2` in shell and archived snapshots (ProjectionStore.ts:532). Forward-compatible decode rules: section 4.7.
- No subscription input carries a version field.

---

## 15. Recommended client sequence (derived from the official client)

1. Fetch `/.well-known/t3/environment` and check `orchestrationProtocolVersion == 2`.
2. Open `/ws?orchestrationProtocol=2&wsTicket=...`. Send `Ping` every 5 s and Ack every Chunk.
3. Read `server.getConfig` (or `subscribeServerConfig`) for the capability flags.
4. Shell:
   - On each new socket session, `GET /api/orchestration/shell` (authoritative), then `subscribeShell {afterSequence: snapshot.snapshotSequence, requestCompletionMarker: true}`.
   - On a resubscribe within the same session, resume from the in-memory cursor.
   - If HTTP fails, subscribe without `afterSequence` (shell.ts:344-404).
5. Thread:
   - `GET /api/orchestration/threads/:id/bounded?compactTurnItems=1` and restore compact turnItems. A 404 means deleted.
   - Then `subscribeThread {threadId, afterSequence: snapshotSequence, requestCompletionMarker: true, acceptBoundedSnapshot: true, acceptCompactTurnItems: true}` (threads.ts:816-893).
6. Apply items in order:
   - Snapshot: full reset.
   - Event or unknown-event: apply only if `sequence > cursor`, then advance the cursor.
   - `synchronized`: mark live.
7. On a stream failure, resubscribe after a short delay with the current cursor.
8. Older history: `GET .../history?cursor=<historyCursor>` until `hasMoreHistory` is false.

---

## 16. JSON examples (built from the schemas)

Placeholder values are invented. Field optionality is noted after each block.

### 16.1 subscribeShell request, snapshot chunk, ack

```json
{"_tag":"Request","id":1,"tag":"orchestration.subscribeShell","payload":{"afterSequence":48211,"requestCompletionMarker":true},"headers":[]}
```
`afterSequence` and `requestCompletionMarker` are optionalKey. Omit them, do not send null.

Authoritative snapshot item (inside a Chunk):

```json
{"_tag":"Chunk","requestId":1,"values":[{"kind":"snapshot","snapshot":{"schemaVersion":2,"snapshotSequence":48211,"threads":[{"createdBy":"user","creationSource":"web","id":"thread_abc","projectId":"project_123","title":"Fix the login bug","providerInstanceId":"codex","modelSelection":{"instanceId":"codex","model":"gpt-5.4"},"runtimeMode":"full-access","interactionMode":"default","branch":"fix/login","worktreePath":null,"pullRequests":[],"lineage":{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"thread_abc"},"forkedFrom":null,"activeProviderThreadId":"pthread_1","latestRunId":"run_7","latestRunRequestedAt":"2026-10-09T11:59:58.120Z","latestRunStartedAt":"2026-10-09T11:59:58.400Z","latestRunCompletedAt":null,"activeRunId":"run_7","activityRunStatus":"running","activityRunStartedAt":"2026-10-09T11:59:58.400Z","status":"running","lastError":null,"lastErrorClass":null,"usageLimitResetAt":null,"pendingRuntimeRequest":null,"latestVisibleMessage":null,"latestUserMessageAt":"2026-10-09T11:59:58.100Z","latestUserAuthoredMessageAt":"2026-10-09T11:59:58.100Z","hasActionableProposedPlan":false,"pendingBackgroundTasks":[],"providerInstanceHistory":["codex"],"goal":null,"itemCount":42,"visibleItemCount":42,"createdAt":"2026-10-09T10:00:00.000Z","updatedAt":"2026-10-09T12:00:01.250Z","archivedAt":null,"settledOverride":null,"settledAt":null,"unsettledAt":null,"snoozedUntil":null,"snoozedAt":null,"pinnedAt":null,"autoSettleDisabledAt":null,"pinOrderKey":null,"lastVisitedAt":"2026-10-09T11:58:00.000Z","titleRegeneration":null,"limitRecovery":null,"deletedAt":null}],"archivedThreads":[],"projects":[{"id":"project_123","title":"webapp","workspaceRoot":"/Users/me/src/webapp","repositoryIdentity":null,"defaultModelSelection":null,"scripts":[],"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}]}}]}
```
```json
{"_tag":"Ack","requestId":1}
```

Thread shell optionality is listed in section 5.7. Project shell: `repositoryIdentity`, `defaultThreadEnvMode`, `autoPull`, `faviconPath`, and `projectIcon` are optional.

### 16.2 Metadata-only enrichment snapshot (never move the cursor)

```json
{"kind":"snapshot","snapshot":{"schemaVersion":2,"snapshotSequence":48230,"threads":[],"archivedThreads":[],"projects":[{"id":"project_123","title":"webapp","workspaceRoot":"/Users/me/src/webapp","repositoryIdentity":{"canonicalKey":"github.com/test/repo","locator":{"source":"git-remote","remoteName":"origin","remoteUrl":"https://github.com/test/repo.git"}},"defaultModelSelection":null,"scripts":[],"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}]},"resolvedRepositoryIdentityRoots":["/Users/me/src/webapp"]}
```
The `repositoryIdentity` shape is taken from a test fixture (ShellStream.test.ts:525-531). The schema is at packages/contracts/src/environment.ts:247 and was not read in full.

### 16.3 Shell deltas and marker

```json
{"kind":"synchronized"}
{"kind":"thread.updated","sequence":48215,"location":"active","thread":{"createdBy":"user","creationSource":"web","id":"thread_abc","projectId":"project_123","title":"Fix the login bug","providerInstanceId":"codex","modelSelection":{"instanceId":"codex","model":"gpt-5.4"},"runtimeMode":"full-access","interactionMode":"default","branch":"fix/login","worktreePath":null,"lineage":{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"thread_abc"},"forkedFrom":null,"activeProviderThreadId":"pthread_1","latestRunId":"run_7","activeRunId":null,"status":"completed","pendingRuntimeRequest":null,"latestVisibleMessage":null,"latestUserMessageAt":"2026-10-09T11:59:58.100Z","hasActionableProposedPlan":false,"itemCount":44,"visibleItemCount":44,"createdAt":"2026-10-09T10:00:00.000Z","updatedAt":"2026-10-09T12:01:10.000Z","archivedAt":null,"settledOverride":null,"settledAt":null,"deletedAt":null}}
{"kind":"thread.removed","sequence":48220,"location":"active","threadId":"thread_old"}
{"kind":"project.updated","sequence":48230,"project":{"id":"project_9","title":"api","workspaceRoot":"/Users/me/src/api","defaultModelSelection":null,"scripts":[],"createdAt":"2026-09-02T00:00:00Z","updatedAt":"2026-10-09T12:02:00Z"}}
{"kind":"project.removed","sequence":48231,"projectId":"project_8"}
```
Each line above is one item from a Chunk `values` array. The `thread.updated` example shows only the required thread shell fields. A real server sends most of the optional ones too (section 5.7).

### 16.4 subscribeArchivedShell

```json
{"_tag":"Request","id":2,"tag":"orchestration.subscribeArchivedShell","payload":{},"headers":[]}
{"kind":"snapshot","snapshot":{"schemaVersion":2,"snapshotSequence":48211,"projects":[],"threads":[]}}
{"kind":"thread.updated","sequence":48240,"thread":{"createdBy":"user","creationSource":"web","id":"thread_old","projectId":"project_123","title":"Old work","providerInstanceId":"codex","modelSelection":{"instanceId":"codex","model":"gpt-5.4"},"runtimeMode":"full-access","interactionMode":"default","branch":null,"worktreePath":null,"lineage":{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"thread_old"},"forkedFrom":null,"activeProviderThreadId":null,"latestRunId":null,"activeRunId":null,"status":"idle","pendingRuntimeRequest":null,"latestVisibleMessage":null,"latestUserMessageAt":null,"hasActionableProposedPlan":false,"itemCount":0,"visibleItemCount":0,"createdAt":"2026-08-01T00:00:00.000Z","updatedAt":"2026-10-09T12:03:00.000Z","archivedAt":"2026-10-09T12:03:00.000Z","settledOverride":null,"settledAt":null,"deletedAt":null}}
{"kind":"thread.removed","sequence":48241,"threadId":"thread_old"}
```

### 16.5 subscribeThread request and bounded compact snapshot

```json
{"_tag":"Request","id":7,"tag":"orchestration.subscribeThread","payload":{"threadId":"thread_abc","afterSequence":48190,"requestCompletionMarker":true,"acceptBoundedSnapshot":true,"acceptCompactTurnItems":true},"headers":[]}
```

A snapshot item (here as a resume fallback) with a minimal projection:

```json
{"kind":"snapshot","snapshotSequence":48190,"projection":{"thread":{"createdBy":"user","creationSource":"web","id":"thread_abc","projectId":"project_123","title":"Fix the login bug","providerInstanceId":"codex","modelSelection":{"instanceId":"codex","model":"gpt-5.4"},"runtimeMode":"full-access","interactionMode":"default","branch":"fix/login","worktreePath":null,"activeProviderThreadId":"pthread_1","lineage":{"parentThreadId":null,"relationshipToParent":null,"rootThreadId":"thread_abc"},"forkedFrom":null,"createdAt":"2026-10-09T10:00:00.000Z","updatedAt":"2026-10-09T12:00:03.000Z","archivedAt":null,"settledOverride":null,"settledAt":null,"lastVisitedAt":null,"deletedAt":null},"runs":[],"attempts":[],"nodes":[],"subagents":[],"providerSessions":[],"providerThreads":[],"providerTurns":[],"runtimeRequests":[],"messages":[],"plans":[],"turnItems":[],"checkpointScopes":[],"checkpoints":[],"contextHandoffs":[],"contextTransfers":[],"visibleTurnItems":[{"position":0,"visibility":"local","sourceThreadId":"thread_abc","sourceItemId":"turn-item:thread_abc:41","item":{"id":"turn-item:thread_abc:41","type":"command_execution","threadId":"thread_abc","runId":"run_7","nodeId":"node_7","providerThreadId":"pthread_1","providerTurnId":"pturn_3","nativeItemRef":null,"parentItemId":null,"ordinal":7000004,"status":"completed","title":"Run tests","startedAt":"2026-10-09T12:00:00.000Z","completedAt":"2026-10-09T12:00:03.000Z","updatedAt":"2026-10-09T12:00:03.000Z","input":"npm test","exitCode":1,"outputIndicatesFailure":true,"outputOmitted":true}}],"updatedAt":"2026-10-09T12:00:03.000Z"},"historyCursor":"eyJ2IjoxLCJzZXEiOjQ4MTkwLCJzdCI6InRocmVhZF9hYmMiLCJzaSI6InR1cm4taXRlbTp0aHJlYWRfYWJjOjQxIiwicCI6MTJ9","hasMoreHistory":true,"latestLocalTurnOrdinal":7000004,"payloadBudgetExceeded":false,"turnItemsOmitLocalVisible":true}
```

Notes:
- `turnItems` is empty here because the one local visible item was omitted (compact). After restore, `turnItems` is `[<that command_execution item>]`.
- AppThread required fields (orchestrationV2.ts:364-439): `createdBy`, `creationSource`, `id`, `projectId`, `title`, `providerInstanceId`, `modelSelection`, `runtimeMode`, `interactionMode`, `branch`, `worktreePath`, `activeProviderThreadId`, `lineage`, `forkedFrom`, `createdAt`, `updatedAt`, `archivedAt`, `deletedAt`. Also `settledOverride`, `settledAt`, and `lastVisitedAt`, which have decoding defaults.
- AppThread optional fields: `linkedPullRequest`, `pullRequests`, `branchPullRequest`, `historyOrigin`, `unsettledAt`, `snoozedUntil`, `snoozedAt`, `limitRecovery`, `pinnedAt`, `autoSettleDisabledAt`, `pinOrderKey`, `activeOrderKey`, `titleRegeneration`, `rollbackRequestId`, `rollbackFailure`.
- Turn item base fields (orchestrationV2.ts:1316-1335):
  - Optional: `toolNonExecutionKind`, `toolSurface`, `toolIcon`, `toolSource`.
  - Required: `id`, `threadId`, `runId` (NullOr), `nodeId` (NullOr), `providerThreadId` (NullOr), `providerTurnId` (NullOr), `nativeItemRef` (NullOr), `parentItemId` (NullOr), `ordinal`, `status`, `title` (NullOr), `startedAt` (NullOr), `completedAt` (NullOr), `updatedAt`.
- `command_execution` specific (orchestrationV2.ts:1437-1446): `input` required; `output`, `outputOmitted`, `outputIndicatesFailure`, `exitCode` optional.

### 16.6 Thread events

Streaming assistant text (full text so far, replace semantics):

```json
{"kind":"event","sequence":48191,"event":{"id":"event_abc","type":"turn-item.updated","threadId":"thread_abc","runId":"run_7","nodeId":"node_7","driver":"codex","providerInstanceId":"codex","occurredAt":"2026-10-09T12:00:04.000Z","payload":{"id":"turn-item:thread_abc:42","type":"assistant_message","threadId":"thread_abc","runId":"run_7","nodeId":"node_7","providerThreadId":"pthread_1","providerTurnId":"pturn_3","nativeItemRef":null,"parentItemId":null,"ordinal":7000005,"status":"running","title":null,"startedAt":"2026-10-09T12:00:04.000Z","completedAt":null,"updatedAt":"2026-10-09T12:00:04.000Z","messageId":"message_42","text":"I ran the tests.\n\n","streaming":true}}}
```
Event base `runId`, `nodeId`, `driver`, `providerInstanceId`, and `rawEventId` are optional and omitted when unset. The `assistant_message` field `attachments` is optional.

Message update:

```json
{"kind":"event","sequence":48195,"event":{"id":"event_abd","type":"message.updated","threadId":"thread_abc","runId":"run_7","occurredAt":"2026-10-09T12:00:09.000Z","payload":{"createdBy":"agent","creationSource":"provider","id":"message_42","threadId":"thread_abc","runId":"run_7","nodeId":"node_7","role":"assistant","text":"I ran the tests. Two failures remain.","attachments":[],"streaming":false,"createdAt":"2026-10-09T12:00:04.000Z","updatedAt":"2026-10-09T12:00:09.000Z"}}}
```
ConversationMessage optional fields (orchestrationV2.ts:1113-1137): `notification`, `scheduledTaskId`, `senderThreadId`, `context`, `delegatedCompletion`.

An event of a type newer than the client's build should be decoded as `{kind:"unknown-event", sequence, eventType}`, skipped, and still used to advance the cursor.

### 16.7 Stream failure exits

```json
{"_tag":"Exit","requestId":7,"exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2GetThreadProjectionError","threadId":"thread_abc","message":"Failed while streaming orchestration V2 thread thread_abc","cause":{"name":"Error","message":"opaque"}}}]}}
{"_tag":"Exit","requestId":1,"exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2GetShellSnapshotError","message":"Failed while streaming the application shell"}}]}}
{"_tag":"Exit","requestId":7,"exit":{"_tag":"Failure","cause":[{"_tag":"Interrupt","fiberId":null}]}}
```
The nested `cause` content is UNVERIFIED (section 4.8). The `fiberId` value on interrupts may be a number or null.

### 16.8 getTurnItem

```json
{"_tag":"Request","id":12,"tag":"orchestration.getTurnItem","payload":{"threadId":"thread_abc","itemId":"turn-item:thread_abc:41","revision":"2026-10-09T12:00:03.000Z"},"headers":[]}
{"_tag":"Exit","requestId":12,"exit":{"_tag":"Success","value":{"item":{"id":"turn-item:thread_abc:41","type":"command_execution","threadId":"thread_abc","runId":"run_7","nodeId":"node_7","providerThreadId":"pthread_1","providerTurnId":"pturn_3","nativeItemRef":null,"parentItemId":null,"ordinal":7000004,"status":"completed","title":"Run tests","startedAt":"2026-10-09T12:00:00.000Z","completedAt":"2026-10-09T12:00:03.000Z","updatedAt":"2026-10-09T12:00:03.000Z","input":"npm test","output":"FAIL src/login.test.ts\n2 failed","exitCode":1}}}}
```

### 16.9 HTTP history page

```
GET /api/orchestration/threads/thread_abc/history?cursor=eyJ2IjoxLCJzZXEiOjQ4MTkwLCJzdCI6InRocmVhZF9hYmMiLCJzaSI6InR1cm4taXRlbTp0aHJlYWRfYWJjOjQxIiwicCI6MTJ9 HTTP/1.1
x-t3-orchestration-protocol: 2
authorization: Bearer TOKEN
accept-encoding: br, gzip
```
```json
{"snapshotSequence":48230,"items":[{"position":0,"visibility":"local","sourceThreadId":"thread_abc","sourceItemId":"turn-item:thread_abc:30","item":{"id":"turn-item:thread_abc:30","type":"user_message","threadId":"thread_abc","runId":"run_5","nodeId":null,"providerThreadId":null,"providerTurnId":null,"nativeItemRef":null,"parentItemId":null,"ordinal":5000001,"status":"completed","title":null,"startedAt":null,"completedAt":"2026-10-09T11:00:00.000Z","updatedAt":"2026-10-09T11:00:00.000Z","createdBy":"user","creationSource":"web","messageId":"message_30","inputIntent":"turn_start","text":"Why does login fail?","attachments":[]}}],"nextCursor":null,"hasMoreHistory":false}
```
`user_message` optional fields: `scheduledTaskId`, `senderThreadId`, `context`. `nextCursor: null` with `hasMoreHistory: false` marks the start of history.

HTTP errors:

```json
{"_tag":"EnvironmentRequestInvalidError","code":"invalid_request","reason":"invalid_history_cursor","traceId":"trace_1"}
{"_tag":"EnvironmentResourceNotFoundError","code":"not_found","reason":"thread_not_found","traceId":"trace_2"}
{"_tag":"EnvironmentInternalError","code":"internal_error","reason":"orchestration_thread_history_failed","traceId":"trace_3"}
```
These come with status 400, 404, and 500 respectively (environmentHttp.ts:130-242; apps/server/src/auth/http.ts:114-120, 150-156, 188-200).

### 16.10 Keepalive and cancel

```json
{"_tag":"Ping"}
{"_tag":"Pong"}
{"_tag":"Interrupt","requestId":7}
```

---

## 17. UNVERIFIED items and open risks

1. The normal stream completion exit is encoded as `{"_tag":"Success","value":null}` (derived from the Void codec, not observed). Orchestration subscriptions do not normally complete.
2. What happens when `headers` is omitted from a Request (likely a defect). Always send `[]`.
3. The exact nested JSON of `cause` on orchestration error classes (Defect encoding of Effect tagged errors).
4. Whether the command-readiness middleware also delays the `/ws` upgrade during startup.
5. The WebSocket close code used when an auth session is invalidated.
6. Soft-deleted threads over the full and bounded snapshot routes may return a projection with `thread.deletedAt` set instead of 404.
7. The archived stream can miss a `thread.removed` when `thread.unarchived` is coalesced with a later event for the same thread within 50 ms (inference from ShellStream.ts:275-286, 321-344).
8. How server stream batches map to Chunk `values` (batch sizes).
9. Encoding of a `dynamic_tool` item whose `input` is undefined (the JSON check rejects undefined).
10. Idle timeouts in the `ws` library, TCP, or proxies. The server never pings.
11. The effect library source was read from the `.repos/effect-smol` reference copy (version 4.0.1). The installed package was not inspected because there is no `node_modules`.
12. Whether excess or unknown keys in RPC payloads are tolerated by older servers.
13. The contract comment claiming bounded snapshots carry "full control-plane projection arrays" does not match the windowed SQL reads (section 10.3). This is a documentation mismatch, verified from code.
