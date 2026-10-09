# T3 wire protocol contract

Contract for the native macOS client of T3 Code. It must be wire-compatible with the official T3 server.

- Server version recorded and verified: `0.0.46-nightly.20261009.2861` (tag `v0.0.46-nightly.20261009.2861`, commit 3b6af0bd1). The tag is also in `T3_VERSION`.
- Sources: the T3 repo at tag above (cited as repo-relative `path:line`), the research notes in `docs/research/` (A to D), and three live recordings in `fixtures/transcripts/` (cited as `01-basic`, `02-turn`, `03-turn2` with the frame time `t`).
- **UNVERIFIED** marks a claim that no source line or recording confirmed. Section 12 lists them all.
- `.repos/effect-smol/...` paths are inside the T3 repo checkout (Effect 4.0.1 vendored reference source).
- Field tables use the optionality words defined in section 3.1.
- The official client packages are the reference implementation: `packages/client-runtime`, `packages/shared`, `apps/web/src`.

---

## 1. Versions and compatibility

### 1.1 Version constants

| Item | Value | Source |
| --- | --- | --- |
| Server version string | `0.0.46-nightly.20261009.2861`, reported as `serverVersion` in the descriptor | `01-basic` t=19 |
| `ORCHESTRATION_PROTOCOL_VERSION` | `2` (number) | `packages/contracts/src/environment.ts:13` |
| `ORCHESTRATION_PROTOCOL_VERSION_TEXT` | `"2"` | `packages/contracts/src/environment.ts:14` |
| WebSocket query parameter | `orchestrationProtocol=2` | `packages/contracts/src/environment.ts:15` |
| HTTP header | `x-t3-orchestration-protocol: 2` | `packages/contracts/src/environment.ts:16` |
| Shell snapshot `schemaVersion` | `2` (recorded) | `01-basic` t=37 |
| Effect version | 4.0.1 (JSON RPC serialization) | `pnpm-workspace.yaml:49` |

### 1.2 Where the protocol version is enforced

- `GET /ws` without `orchestrationProtocol=2` (or with another value) answers HTTP **426** before any authentication. Body: `{"code":"orchestration_protocol_incompatible","message":"Update this client to one that supports orchestration protocol 2.","orchestrationProtocolVersion":2}` (`apps/server/src/ws.ts:607-612`, `apps/server/src/ws.ts:3140-3151`).
- Every `GET /api/orchestration/*` request must carry the header `x-t3-orchestration-protocol: 2`. The header is a required literal in the endpoint schema, so a missing or wrong value fails schema decoding and the server answers an **empty HTTP 400** (`packages/contracts/src/environmentHttp.ts:80-84`, `.repos/effect-smol/packages/effect/src/http-api/HttpApiError.ts:470-505`).
- Other HTTP routes ignore the header. Sending it everywhere is harmless: `03-turn2` sent it on `api/auth/session` and `api/auth/websocket-ticket` and got 200.
- The official client reads `orchestrationProtocolVersion` from `GET /.well-known/t3/environment` (absent means 1) and refuses to connect when it is not 2, unless the server is old and can self-update (`packages/client-runtime/src/connection/compatibility.ts:9-27`, `packages/client-runtime/src/connection/onboarding.ts:121-125`). A native client should do the same check before redeeming a pairing code.

### 1.3 Environment descriptor and capability flags

`GET /.well-known/t3/environment` (no auth) returns `ExecutionEnvironmentDescriptor` (`packages/contracts/src/environment.ts:218-227`):

| Field | Type | Notes |
| --- | --- | --- |
| `environmentId` | string (UUID in recordings) | stable id of this T3 server |
| `label` | string | host label, for example `host` |
| `platform` | `{os, arch, machine}` | `os`: `darwin`, `linux`, `windows`, `unknown`. `arch`: `arm64`, `x64`, `other`. `machine` is a curated machine shape, for example `mac-mini` (`packages/contracts/src/environment.ts:18-60`) |
| `serverVersion` | string | |
| `orchestrationProtocolVersion` | number, optional | absent on old hosts, treat as 1 |
| `capabilities` | object | see below |

Real example (`01-basic` t=19, trimmed):

```json
{"environmentId":"cc77e38e-569c-437d-b3ff-16ac64620624","label":"host","orchestrationProtocolVersion":2,
 "platform":{"arch":"arm64","machine":"mac-mini","os":"darwin"},
 "serverVersion":"0.0.46-nightly.20261009.2861",
 "capabilities":{"attachmentUploads":true,"connectionProbe":true,"fileAttachments":{"maxUploadBytes":52428800},"pullRequests":true,"threadSnooze":true,"...":"..."}}
```

`capabilities` fields (`packages/contracts/src/environment.ts:98-215`). Only `repositoryIdentity` is required (decoding default `false`). Every other key is `optionalKey`, so **absent means false/unsupported**. A client must treat an absent key as "feature not available on this server".

| Capability | Type | Value on the recorded server | Gates |
| --- | --- | --- | --- |
| `repositoryIdentity` | bool, default false | true | `repositoryIdentity` on projects |
| `connectionProbe` | bool | true | `server.probe` |
| `attachmentUploads` | bool | true | HTTP upload flow instead of inline base64 images |
| `questionAttachments` | bool | true | files on question answers |
| `fileAttachments` | `{maxUploadBytes: int >= 1}` | 52428800 | non-image attachments |
| `pullRequests`, `pullRequestChecks` | bool | true | `pullRequests.*` |
| `inlineMessageContext` | bool | true | message `context` records |
| `requiredWorktreeBootstrap` | bool | true | server rejects a required worktree instead of falling back |
| `threadSettlement`, `threadAutoSettlement`, `threadAutoSettleOptOut` | bool | true | settle commands |
| `threadSnooze` | bool | true | `thread.snooze` |
| `threadPinning`, `threadPinReorder`, `threadActiveReorder` | bool | true | pin and order commands |
| `threadTitleRegeneration` | bool | true | `thread.metadata.update.regenerateTitle` |
| `threadVisitedTracking` | bool | true | server-side `lastVisitedAt` |
| `threadRestartContinuation` | bool | true | restart continuation runs |
| `serverResolvedCommandContext` | bool | true | |
| `threadPullRequests`, `threadPullRequestWatch`, `threadPullRequestLinking`, `pullRequestStackActions` | bool | true | PR link commands |
| `storageCleanup`, `projectWorktreeCleanup`, `worktreesDirectory` | bool | true | |
| `projectSettingsOverrides` | bool | true | |
| `environmentThemes`, `environmentIcon` | bool | true | |
| `usageLimitSources`, `usagePriceOverrides`, `usageModelAliases` | bool | true | usage settings |
| `projectCloneTracking` | bool | true | `projectClone.*` |
| `serverBrowser` | bool | true | server-hosted preview tabs |
| `agentActivityPublishing` | bool | false | push and Live Activities |
| `serverSelfUpdate` | capability enum | absent here | update UI |
| `serverInstallation` | forward-compatible optional | absent here | |
| `serverSelfUpdateProgress`, `desktopAppUpdate`, `serverUpdateThreadContinuation` | bool | absent here | |

(`01-basic` t=19 shows the exact key set; `docs/research/D-server-features.md` section 0.3 explains each flag, citing `apps/server/src/environment/ServerEnvironment.ts:217-262`.)

`server.getConfig` and `subscribeServerConfig` carry extra feature flags outside `capabilities` (`packages/contracts/src/server.ts:644-714`, set at `apps/server/src/ws.ts:1700-1740`), all `true` in `01-basic` t=67: `shellResumeCompletionMarker`, `threadResumeCompletionMarker`, `threadSnapshotPagination`, `threadFind`, `threadFindProgressive`. A client should send `requestCompletionMarker` and `acceptBoundedSnapshot` only when the matching flag is true (UNVERIFIED that the official client gates on them; the recorded server accepted both). Also present: `shellRevealInFileManager` and `shellRevealInFileManagerKind` (`"finder"` here), `scratchWorkspaceRoot`, `newProjectsRoot`.

### 1.4 Forward-compatible decoding

The server adds fields, union members, event types and turn item types between releases. A native client must tolerate them. Rules, with the official behavior as the source:

| Situation | Rule | Source |
| --- | --- | --- |
| Unknown JSON keys in an object | Ignore them. Effect Schema strips excess properties on decode. | `.repos/effect-smol/packages/effect/src/SchemaAST.ts:463` |
| Unknown domain event `type` on the thread stream | The official decoder maps it to `{kind:"unknown-event", sequence, eventType}`. Skip it **but advance the resume cursor**. | `packages/contracts/src/orchestrationV2.ts:3320-3364` |
| `turn-item.updated` whose payload `type` is unknown | Same `unknown-event` treatment. | `packages/contracts/src/orchestrationV2.ts:3320-3364` |
| Unknown turn item `type` inside `projection.turnItems`, `visibleTurnItems`, history page `items` | Drop the row. A known `type` with a malformed payload is a decode error. | `packages/contracts/src/orchestrationV2.ts:1580-1608`, `packages/contracts/src/baseSchemas.ts:261-285` |
| `ForwardCompatibleArray(X)` | Drop elements that fail to decode. | `packages/contracts/src/baseSchemas.ts:114-170` |
| `ForwardCompatibleOptional(X)` | Unknown literal decodes as absent. | `packages/contracts/src/baseSchemas.ts:50-69` |
| `ForwardCompatibleNullable(X)` | Unknown literal or missing key decodes as `null`. | `packages/contracts/src/baseSchemas.ts:71-87` |
| `ForwardCompatibleUnion` | Unknown discriminant decodes to an "unknown member". | `packages/contracts/src/baseSchemas.ts:178-200` |
| Unknown `pendingBackgroundTasks[].kind` | Decodes as `background_task`. | `packages/contracts/src/orchestrationV2.ts:760-795` |
| Unknown notification `source.kind` | Decodes as `background_task`. | `packages/contracts/src/orchestrationV2.ts:1054-1099` |
| `ProviderDriverKind` | Open slug. Unknown drivers must decode. | `packages/contracts/src/providerInstance.ts:16-28` |
| Unknown permission strings in auth responses | Ignore them. | `packages/contracts/src/auth.ts:147-150` |
| Unknown literal in a known required field (for example a new run `status`) | Rejected by the official decoder. A native client should map it to an "unknown" case instead of failing the whole snapshot. This is a client design choice. | `.repos/effect-smol/packages/effect/src/SchemaAST.ts:463` |
| Config, snapshots | Never fail a whole config or snapshot decode over one unknown member. | `docs/research/D-server-features.md` section 0.1 |

Strictness on **encode**: commands the client sends must match the schema. Unknown keys are stripped by the server, but unknown literal values fail decode and the RPC request fails with a defect (section 2.7).

---

## 2. Transport

### 2.1 Connection sequence

1. `GET <httpBase>/.well-known/t3/environment` (no auth). Check `environmentId` and `orchestrationProtocolVersion`.
2. Obtain a session token (section 4.3). Recorded request (`01-basic` t=19):
   `POST /oauth/token`, form body `grant_type=urn:ietf:params:oauth:grant-type:token-exchange&subject_token=<code>&subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap&requested_token_type=urn:ietf:params:oauth:token-type:access_token&client_label=...&client_device_type=desktop&client_os=macOS`.
3. `POST /api/auth/websocket-ticket` with `Authorization: Bearer <token>`. Response `{"ticket":"...","expiresAt":"2026-10-09T09:15:20.029Z"}` (5 minute lifetime).
4. Open the WebSocket. Recorded URL (`01-basic` t=25):
   `ws://127.0.0.1:47391/ws?orchestrationProtocol=2&wsTicket=<ticket>&clientSurface=desktop&clientAppVersion=0.0.0-recorder&clientOs=macOS&clientDeviceType=desktop&connectionMethod=direct`
5. Send the first `Request` frames. The recorded client sent, in this order and without waiting: `server.getConfig` (id 1), `subscribeServerConfig` (2), `subscribeServerLifecycle` (3), `orchestration.subscribeShell` with `requestCompletionMarker: true` (4), `server.getSettings` (5). Streams started immediately.

### 2.2 WebSocket URL and query parameters

Route: `GET <wsBase>/ws` (`apps/server/src/ws.ts:3136-3139`). A `wsBase` without a path defaults to `/ws` (`packages/client-runtime/src/authorization/remote.ts:217-221`).

| Param | Required | Values | Source |
| --- | --- | --- | --- |
| `orchestrationProtocol` | **yes** | `2` | `apps/server/src/ws.ts:607-612` |
| `wsTicket` | yes for bearer and DPoP clients | ticket from `POST /api/auth/websocket-ticket` | `apps/server/src/auth/EnvironmentAuth.ts:586`, `:1173-1191` |
| `clientSurface` | no | `web`, `desktop`, `mobile`, `cli` | `packages/contracts/src/baseSchemas.ts:345` |
| `clientAppVersion` | no | string, at most 64 chars | `apps/server/src/ws.ts:620-684` |
| `clientDeviceType` | no | `desktop`, `phone`, `tablet`, `unknown` | `packages/contracts/src/baseSchemas.ts:360` |
| `clientOs` | no | `macOS`, `Windows`, `Linux`, `iOS`, `Android`, `ChromeOS`, `other`, `unknown` | `packages/contracts/src/baseSchemas.ts:345-367` |
| `connectionMethod` | no | `direct`, `ssh`, `relay`, `unknown` | `packages/contracts/src/baseSchemas.ts:366` |
| `clientWebDeployment`, `clientBrowser` | no | only meaningful when `clientSurface=web` | `apps/server/src/ws.ts:620-689` |
| `clientOsMajorVersion`, `clientDeviceModel` | no | only meaningful when `clientSurface=mobile` | `apps/server/src/ws.ts:620-689` |

The client-identity parameters are attribution only. Malformed values are dropped, never fatal (`apps/server/src/ws.ts:620-622`). A native macOS client sends `clientSurface=desktop`, `clientOs=macOS`, `clientDeviceType=desktop`, `connectionMethod=direct|relay|ssh`. The recorder did the same and the server accepted it.

Upgrade authentication (`apps/server/src/auth/EnvironmentAuth.ts:1173-1194`): a non-blank `wsTicket` alone authenticates, with no DPoP proof on the upgrade, and a bad ticket is a 401 with no fallback to headers. Without a ticket, cookie or headers are used. Upgrade failures return the same JSON error bodies as HTTP (401 `auth_invalid`, 500 `internal_error`; `apps/server/src/ws.ts:3155-3165`).

The server closes the socket when the session is revoked or when the session `expiresAt` passes (`apps/server/src/auth/SessionStore.ts:1053-1080`). A bearer socket therefore ends about 30 days after pairing, and a DPoP (T3 Connect) socket about 1 hour after the token exchange (section 10).

### 2.3 Effect RPC JSON framing

The server builds an Effect `RpcServer` over the socket with `RpcSerialization.layerJson` (`apps/server/src/ws.ts:3171-3190`). Each WebSocket **text frame** holds one JSON message or a JSON array of messages (`.repos/effect-smol/packages/effect/src/rpc/RpcSerialization.ts:129-139`). The recordings contain only single-message frames from the server. Accept both forms on receive. Sending one message per frame works.

#### Client to server

Message types (`.repos/effect-smol/packages/effect/src/rpc/RpcMessage.ts:71-174`):

| `_tag` | Fields | Meaning |
| --- | --- | --- |
| `Request` | `id`, `tag`, `payload`, `headers`, optional `traceId`, `spanId`, `sampled` | start an RPC. `headers` is a JSON array, send `[]`. `id` is a string or number chosen by the client; the server echoes it as `requestId`. The recorder used decimal strings: `"1"`, `"2"`. The Effect client uses a process-wide counter (`RpcClient.ts:217`) |
| `Ack` | `requestId` | acknowledges one stream `Chunk` |
| `Interrupt` | `requestId` | cancel a request or stream (unsubscribe). Not exercised in the recordings (**UNVERIFIED** on the wire: the server's reply to an interrupted stream was not recorded) |
| `Ping` | none | liveness probe, answered by `Pong` |
| `Eof` | none | defined by the protocol; not seen in any recording |

Real frames (`01-basic`):

```json
{"_tag":"Request","headers":[],"id":"1","payload":{},"tag":"server.getConfig"}
{"_tag":"Request","headers":[],"id":"4","payload":{"requestCompletionMarker":true},"tag":"orchestration.subscribeShell"}
{"_tag":"Ack","requestId":"4"}
{"_tag":"Ping"}
```

A `Request` has no separate "stream or unary" marker. The method's definition decides (catalog in `docs/research/A-rpc-catalog.md`, column Kind).

#### Server to client

Message types (`.repos/effect-smol/packages/effect/src/rpc/RpcMessage.ts:257-358`):

| `_tag` | Fields | Meaning |
| --- | --- | --- |
| `Chunk` | `requestId`, `values: [item, ...]` | one or more stream items. `values` is a non-empty array. The recordings show up to 10 items per chunk (`02-turn`). |
| `Exit` | `requestId`, `exit` | terminal response for a unary call, or the end of a stream |
| `Defect` | `defect` | protocol-level defect that affects the connection |
| `Pong` | none | answer to `Ping` |
| `ClientProtocolError` | `error` | the server reports a client protocol error to affected requests |

`exit` is `{"_tag":"Success","value":<result>}` or `{"_tag":"Failure","cause":[...]}` (section 2.6).

Stream example (`02-turn`, one chunk):

```json
{"_tag":"Chunk","requestId":"1","values":[{"kind":"project.updated","project":{"id":"712011f3-...","title":"demo-repo","workspaceRoot":"/Users/user/sandbox/demo-repo","...":"..."},"sequence":1}]}
```

Unary example (`02-turn` t=1614):

```json
{"_tag":"Exit","exit":{"_tag":"Success","value":{"sequence":2}},"requestId":"3"}
```

### 2.4 Ack backpressure

- The server writes a `Chunk` for a stream and then **waits for the client's `Ack` with the same `requestId` before it writes the next chunk of that stream** (`.repos/effect-smol/packages/effect/src/rpc/RpcServer.ts:401-438`, ack handling `:199-202`; WebSocket protocol reports `supportsAck: true`, `:1625`).
- Ack once per received `Chunk` (not once per value). The recordings show exactly this: every `Chunk` is followed by one `{"_tag":"Ack","requestId":...}` within a few milliseconds (`01-basic` t=35 and t=37).
- A client that never acks stalls every stream after its first chunk.
- While the server waits for an ack it buffers live events per subscription, up to 1,000 items or 8 MiB (including the batch awaiting the ack). Beyond that it fails the stream with `LiveStreamBufferError("The live event buffer is full. Resume from the last received sequence.")` (`apps/server/src/orchestration-v2/LiveStreamBudget.ts:12-18`, `:39`, `:66-75`). The client must resubscribe with `afterSequence`.
- Terminal streams are special: `terminal.attach` and `subscribeTerminalEvents` run under `withTerminalOutputWindow`. The server self-acks until 8 chunks or 64 KiB are outstanding and then waits for real acks (`apps/server/src/terminal/OutputProtocol.ts:5-66`, `apps/server/src/ws.ts:3173`). Still ack every chunk.
- Unary calls have no acks.

### 2.5 Ping and Pong

- The client sends `{"_tag":"Ping"}`; the server answers `{"_tag":"Pong"}` (`RpcServer.ts:806-808`). Recorded: `01-basic` t=4288 and t=4289.
- The official Effect client pings every 5 seconds and treats a missing pong before the next ping as a dead socket (`.repos/effect-smol/packages/effect/src/rpc/RpcClient.ts:1205-1227`). A native client should do the same and then reconnect.

### 2.6 Exit and Cause encoding

`Exit.Failure.cause` is an **array** of cause nodes (`.repos/effect-smol/packages/effect/src/rpc/RpcMessage.ts:283-302`):

| Node | Fields | Meaning |
| --- | --- | --- |
| `{"_tag":"Fail","error":E}` | `error` is the encoded **typed error**, itself a `_tag` object | an expected, declared failure |
| `{"_tag":"Die","defect":D}` | `defect` is arbitrary JSON, a string in the recordings | an unexpected failure (bug, bad request) |
| `{"_tag":"Interrupt","fiberId":number\|null}` | | the request was interrupted |

**Typed error** (real, `03-turn2` t=35818), a `run.interrupt` on a run that is not running:

```json
{"_tag":"Exit","requestId":"9","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{
  "_tag":"OrchestrationV2DispatchCommandError",
  "commandId":"fe6a766d-5839-435b-ba85-6bf872de7c6e","commandType":"run.interrupt",
  "message":"Run run:thread:c4ff4c86-...:ordinal:3 is not interruptible.",
  "detail":"Run run:thread:c4ff4c86-...:ordinal:3 is not interruptible.",
  "cause":{"cause":"Run run:thread:c4ff4c86-...:ordinal:3 is not interruptible.","message":"Failed to dispatch orchestration command run.interrupt (fe6a766d-...).","name":"OrchestratorDispatchError"}}}]}}
```

Show `message` (or `detail`) to the user. `cause` is `Schema.Defect()`: arbitrary JSON, keep it opaque.

**Die** (real, `01-basic` t=39), a method that is named in `WS_METHODS` but not served:

```json
{"_tag":"Exit","requestId":"6","exit":{"_tag":"Failure","cause":[{"_tag":"Die","defect":"Unknown request tag: projects.list"}]}}
```

Rules:

- A typed error is only decodable by `_tag`. Each RPC declares its own error union (catalog column Error). Every union also includes `EnvironmentAuthorizationError` `{_tag, message, requiredScope, requiredPermission?}` for scope failures (`packages/contracts/src/auth.ts:409-416`). The socket stays open after such a failure.
- A `Die` fails only that request. The server sets `disableFatalDefects: true` (`apps/server/src/ws.ts:3120-3127`).
- Causes with `Die` come from: unknown request tag (`RpcServer.ts:785-788`), payload that fails schema decode with the formatted schema issue (`RpcServer.ts:789-803`), and handler defects.
- A stream also ends with an `Exit`. A stream that fails (for example the live buffer overflow) ends with `Exit` `Failure`. A stream that completes normally ends with `Exit` `Success`.
- Treat an unknown error `_tag` as a generic failure and display any `message` field present.

### 2.7 Request-level failure modes (summary)

| Cause | Result | Source |
| --- | --- | --- |
| Unknown `tag` | `Die` `"Unknown request tag: <tag>"` | `01-basic` t=39 |
| Payload fails schema decode | `Die` with the formatted issue | `RpcServer.ts:789-803` |
| Missing scope | `Fail` `EnvironmentAuthorizationError` | `apps/server/src/auth/RpcAuthorization.ts:222-226` |
| Command rejected by the orchestrator | `Fail` `OrchestrationV2DispatchCommandError` | `03-turn2` t=35818 |
| Live stream buffer overflow | stream `Exit` `Failure` | `LiveStreamBudget.ts:66-75` |
| Session revoked or expired | socket closes | `apps/server/src/auth/SessionStore.ts:1053-1080` |

---

## 3. Schema encoding conventions

### 3.1 Optionality words

The contracts use Effect Schema. The JSON effect of each form:

| Schema form | Key in JSON | Value | Notes |
| --- | --- | --- | --- |
| `X` (required) | must be present | `X` | |
| `Schema.optionalKey(X)` | may be absent | `X` when present | exact-optional |
| `Schema.optional(X)` | may be absent | `X` (an explicit `undefined` never appears in JSON) | |
| `Schema.NullOr(X)` | **must be present** | `X` or `null` | most entity fields |
| `Schema.optional(Schema.NullOr(X))` | may be absent | `null` or `X` | clients must accept absent, `null` and a value |
| `X.pipe(withDecodingDefault(d))` | may be absent on decode | servers always send it | |
| `OmittedWhenNull(X)` | omitted when null | | `packages/contracts/src/baseSchemas.ts:89-112` |

Source: `docs/research/B-orchestration.md` header, `packages/contracts/src/baseSchemas.ts`.

Swift rule of thumb: model `NullOr` as an Optional that is always encoded, `optional` and `optionalKey` as an Optional that is omitted when nil. **Never send `null` where the schema says `optionalKey(X)` without `NullOr`**, because `null` is not an `X`. Observed example: the command `thread.create` requires `"branch": null` and `"worktreePath": null` (keys present, `NullOr`; `02-turn` t=1595), while `message.dispatch` has no `context` key when there is no context (`optional`).

### 3.2 Special encodings

| Effect type | JSON | Source |
| --- | --- | --- |
| `Schema.DateTimeUtc` | ISO-8601 UTC string with milliseconds and `Z`, for example `"2026-10-09T09:12:47.701Z"` (`Date.prototype.toISOString`). Decoding accepts any string `DateTime.make` parses. | `.repos/effect-smol/packages/effect/src/Schema.ts:11158-11185` |
| `IsoDateTime` (contracts) | plain `Schema.String` with no validation. Used for `snoozedUntil`, `visitedAt`, `resetAt`, project `createdAt` and `updatedAt`, `TokenUsage.updatedAt`, `durationAnchorAt`. Send what the server sent, or a `toISOString()` value. | `packages/contracts/src/baseSchemas.ts:47` |
| `Schema.Option(X)` | `{"_tag":"Some","value":X}` or `{"_tag":"None"}`. Used in source-control discovery. | `.repos/effect-smol/packages/effect/src/Schema.ts:13812-13823` |
| `TrimmedNonEmptyString` | string, trimmed on decode and on encode, must not be blank | `packages/contracts/src/baseSchemas.ts:7-27` |
| `NonNegativeInt`, `PositiveInt` | JSON integer >= 0, >= 1 | `packages/contracts/src/baseSchemas.ts:29-30` |
| `Schema.TaggedError` / `TaggedStruct` | object with `_tag` | Effect |
| `Schema.Defect()` | arbitrary JSON; a JS `Error` encodes as `{name, message, cause?}` | `.repos/effect-smol/packages/effect/src/Schema.ts:8973-9028` |
| Session token timestamps (inside the opaque token) | epoch **milliseconds** | `apps/server/src/auth/SessionStore.ts:435-446` |
| DPoP `iat` | epoch **seconds** | `packages/shared/src/dpop.ts:178-188` |
| Asset and upload `expiresAt` | epoch milliseconds number | `packages/contracts/src/assets.ts:81-90` |

Swift: decode dates with a fractional-seconds ISO-8601 parser and fall back to one without fractional seconds. Keep the original string for round trips of `IsoDateTime` values (for example when echoing `visitedAt` back).

### 3.3 Branded ids

All ids are branded `TrimmedNonEmptyString`. The brand is compile-time only, so **ids are opaque strings on the wire** with no schema-level pattern (`packages/contracts/src/baseSchemas.ts:308-407`). Never parse them for logic. The formats below are observed in the recordings and in the allocator source (`packages/provider-core/src/server/IdAllocator.ts`), useful for debugging and test fixtures only.

| Id | Allocated by | Observed format | Source |
| --- | --- | --- | --- |
| `CommandId` | client | UUID v4 (`c6fe81f4-1dbe-4f2b-a939-0badc0d6570e`). Server-side follow-up commands derive `<commandId>:model-selection` and `<commandId>:detach:<sessionId>` | `packages/client-runtime/src/operations/commands.ts:261-267`, `:595`, `:928` |
| `ThreadId`, `MessageId`, `ProjectId` | client | UUID v4 | `apps/web/src/lib/utils.ts:36-50` |
| `RunId` | server | `run:thread:<threadId>:ordinal:<n>` (`run:thread:14fc5e86-...:ordinal:1`) | `IdAllocator.ts:404`, `02-turn` |
| `RunAttemptId` | server | `run-attempt:run:<url-encoded runId>:attempt:<n>`. Observed: `run-attempt:run:run%3Athread%3A14fc5e86-...%3Aordinal%3A1:attempt:1` | `IdAllocator.ts:406-407` |
| root `NodeId` | server | `node:run:<url-encoded runId>:root` | `IdAllocator.ts:409-411` |
| tool `NodeId` / tool `TurnItemId` | server | `node:provider:<driver>:native-item:<nativeId>` / `turn-item:provider:<driver>:native-item:<nativeId>`, where nativeId is the provider tool id, for example `toolu_01WcXG...` | `02-turn` t=4208 |
| user message `TurnItemId` | server | `turn-item:message:<messageId>` | `IdAllocator.ts:412` |
| run signal `TurnItemId` | server | `turn-item:run:<url-encoded runId>:signal:interrupt-request` and `...:signal:interrupt-result` | `02-turn` t=128608, t=129037 |
| `CheckpointScopeId` | server | `checkpoint-scope:thread:<threadId>:name:root` | `03-turn2` |
| `CheckpointId` | server | `checkpoint:scope:<url-encoded scopeId>:name:<n>` (`...:name:0` is the baseline captured at run start, `...:name:1` after turn 1) | `03-turn2` t=13673 |
| checkpoint `TurnItemId` | server | `turn-item:provider:<driver>:native-item:checkpoint%3A<checkpointId>` | `03-turn2` t=13673 |
| `ProviderThreadId` | server | `provider-thread:provider:<driver>:native-thread:pending%3Arun%3Athread%3A<threadId>%3Aordinal%3A1` | `02-turn` |
| `ProviderTurnId` | server | `provider-turn:provider:<driver>:native-turn:turn%3Arun-attempt%3A...` | `02-turn` |
| `ProviderSessionId` | server | `provider-session:provider-instance:<instanceId>:thread:<threadId>:<uuid>` | `02-turn` t=2661 |
| `RuntimeRequestId` | server | `runtime-request:provider:<driver>:provider-turn:<url-encoded providerTurnId>:native-request:<nativeToolId>:<uuid>` | `03-turn2` t=9313 |
| approval `NodeId`, `TurnItemId` | server | `node:runtime-request:<requestId>`, `turn-item:runtime-request:<requestId>` | `IdAllocator.ts:430-432` |
| `EventId` | server | `event:thread:<threadId>[:command:<commandId>][:provider-session:<id>]:<uuid>` | `02-turn` |
| `ProviderInstanceId` | settings | slug `^[a-zA-Z][a-zA-Z0-9_-]*$`, 1 to 64 chars. For a built-in provider it equals the driver kind: `claudeAgent`, `codex`, `cursor`, `grok`, `opencode`, `antigravity`, `muse`, `pi` | `packages/contracts/src/providerInstance.ts:40-83`, `01-basic` t=67 |
| `EnvironmentId` | server | UUID | `01-basic` |

Each id component is `encodeURIComponent`-escaped before it is joined, so ids contain `%3A`-style sequences, and nesting escapes again (`%253A`, `%25253A`). That is why a `RuntimeRequestId` is long. Treat ids as opaque and compare them as raw strings (`IdAllocator.ts:192-195`).

**Turn item ordinal.** In the recordings `TurnItem.ordinal` equals `runOrdinal * 1_000_000 + n` (`1000001`, `1000002`, `2000001`...) and increases in timeline order within a run. Sort by `ordinal`, tie-break by `id`. The pattern is observed, not a documented guarantee, so do not derive the run number from it (`03-turn2` visibleTurnItems, t=38931).

### 3.4 Discriminants

| Where | Discriminant key | Values |
| --- | --- | --- |
| Command | `type` | `thread.create`, `message.dispatch`, ... (section 7.3) |
| Domain event | `type` | `thread.created`, `run.updated`, ... (section 7.4) |
| Turn item | `type` | `user_message`, `assistant_message`, `command_execution`, ... (section 7.5) |
| Shell stream item | `kind` | `snapshot`, `synchronized`, `project.updated`, `project.removed`, `thread.updated`, `thread.removed` |
| Thread stream item | `kind` | `snapshot`, `synchronized`, `event` (decode-only extra: `unknown-event`) |
| Tool or plan unions | `kind` | PlanArtifact `proposed_plan` / `todo_list`; execution node `kind` is a plain field (`tool_call`, `root_turn`, ...) |
| Server config stream event, lifecycle event, terminal events | `type` | `snapshot`, `welcome`, `ready`, `output`, ... |
| VCS status event | `_tag` | `snapshot`, `localUpdated`, `remoteUpdated` |
| Git action progress | `kind` | `action_started`, `phase_started`, ... |
| Errors, RPC messages, Exit/Cause nodes, `Option` | `_tag` | |
| Forks, fork source point | `type` | `run`, `node`, `provider_thread` / `latest_stable`, `run`, `checkpoint` |
| `dispatchMode` | `type` | `start_immediately`, `queue_after_active`, `steer_active`, `restart_active`, `defer_start` |
| Provider request response capability | `type` | `live`, `message`, `not_resumable` |

The same entity can appear under several discriminants. For example `kind: "approval_request"` is an execution **node** kind, while `type: "approval_request"` is a **turn item** type. Do not mix them.

---

## 4. Auth and pairing

Condensed from `docs/research/C-auth-connect.md` sections 1, 2 and 6, with the recorded exchange in `01-basic`. The environment issues and enforces its own sessions. A cloud or relay credential is never an environment login (`docs/internals/environment-auth.md:3-5`).

### 4.1 Scopes and permissions

Vocabulary (`packages/contracts/src/auth.ts:82-118`). `Std` is the 13-scope standard grant (`AuthStandardClientScopes`, `auth.ts:205-219`). `Admin` adds `access:read`, `access:write`, `relay:write` (`auth.ts:220-225`).

| Scope | Gates (examples) | Std | Admin |
| --- | --- | --- | --- |
| `orchestration:read` | `server.getConfig`, `server.getSettings`, `server.probe`, `orchestration.subscribe*`, `orchestration.get*`, PR reads, `subscribeServerConfig`, `subscribeVcsStatus`, `/api/orchestration/*`, `/api/projects` GET, `/api/pull-requests/diff` | yes | yes |
| `orchestration:operate` | `orchestration.dispatchCommand`, `orchestration.launchThread`, `projects.mutate`, `/api/projects/mutate`, scheduled tasks, `worktreeSetup.cancel`, OTLP trace proxy | yes | yes |
| `settings:write` | `server.updateSettings` (depends on patch), keybindings, device config | yes | yes |
| `providers:manage` | provider auth, install, update | yes | yes |
| `environment:maintain` | `server.updateServer*`, `server.signalProcess`, `server.reportHostPowerState` | yes | yes |
| `preview:operate` | `preview.*` mutations | yes | yes |
| `diagnostics:read` | trace and process diagnostics, usage, `subscribeResourceTelemetry` | yes | yes |
| `terminal:read` | `terminal.observe`, `subscribeTerminalEvents`, `subscribeTerminalMetadata` | yes | yes |
| `terminal:operate` | `terminal.open/attach/write/resize/clear/restart/close` | yes | yes |
| `source-control:write` | push, branch, clone, worktree, PR mutations | yes | yes |
| `filesystem:read` | `projects.readFile/listEntries/search*`, `filesystem.browse`, `review.*`, `assets.createUrl` for file resources | yes | yes |
| `filesystem:write` | `projects.writeFile` | yes | yes |
| `relay:read` | `cloud.getRelayClientStatus`, `GET /api/connect/link-state` | yes | yes |
| `access:read` | `GET /api/auth/pairing-links`, `GET /api/auth/clients`, `subscribeAuthAccess` | no | yes |
| `access:write` | create and revoke pairing links, revoke sessions | no | yes |
| `relay:write` | `cloud.installRelayClient`, `/api/connect/link-proof`, `relay-config`, `unlink`, `preferences` | no | yes |
| `review:write` | retired, decodes old credentials, grants nothing (`auth.ts:94-95`) | no | no |

Source for the per-RPC map: `apps/server/src/auth/RpcAuthorization.ts:43-209`, with payload-dependent overrides at `:243-264` (for example `assets.createUrl` needs `filesystem:read` for `workspace-file`, `media-file`, `draft-workspace-file`; `server.updateSettings` needs the scopes of the patch plus `providers:manage` for a `providerInstanceMutation`). The per-method required scope is in the catalog (`docs/research/A-rpc-catalog.md`).

**`scopes` versus `permissions`.** Auth responses carry two arrays. `scopes` is filtered to the frozen legacy vocabulary (`orchestration:read`, `orchestration:operate`, `terminal:operate`, `review:write`, `access:read`, `access:write`, `relay:read`, `relay:write`). `permissions` holds the exact grant (`auth.ts:130-145`). A new client reads `permissions` when the key is present, even if empty. Recorded (`01-basic` t=24): `scopes` had 7 entries and `permissions` had 16, including `settings:write`, `terminal:read`, `filesystem:read`.

When `permissions` is absent (old server), apply the legacy parent mapping (`auth.ts:152-192`):

| Permission | Legacy parent scope that implies it |
| --- | --- |
| `filesystem:read`, `diagnostics:read` | `orchestration:read` |
| `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `source-control:write`, `filesystem:write` | `orchestration:operate` |
| `terminal:read` | `terminal:operate` |

If `auth.serverUpdateScope` is present in the session response, the parent fallback does not apply (`auth.ts:181-192`). The client-side advisory guard list is `packages/contracts/src/clientRpcPermissions.ts:11-59`. The server always decides.

### 4.2 Credential transports

| Transport | Request form | Used by |
| --- | --- | --- |
| Bearer | `Authorization: Bearer <token>` | paired remote environments, desktop main process, CLI-issued sessions. **The native client baseline.** |
| DPoP | `Authorization: DPoP <token>` plus header `DPoP: <proof JWT>` | T3 Connect sessions (section 10) |
| Cookie | cookie named `auth.sessionCookieName` (recorded: `t3_session_47391_a303d7692026`) | browser sessions on the server's own web app |

Rules (`apps/server/src/auth/EnvironmentAuth.ts`):

- Precedence is cookie, then Bearer, then DPoP, then legacy cookies (`:650-676`, `:717-735`). **A cookie beats an `Authorization` header.** Disable cookie storage in `URLSession` (`httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`, or an ephemeral configuration).
- A DPoP-bound session token sent as `Bearer` fails with `dpopFailureReason: "invalid_proof"`, and a non-bound token sent with the `DPoP` scheme fails the same way (`:736-764`).
- A session whose subject is `mcp-client` is rejected everywhere except `/mcp` (`:612-619`).
- Session token format is opaque: `base64url(JSON claims) + "." + base64url(HMAC-SHA256)` (`apps/server/src/auth/SessionStore.ts:684-698`). Do not parse it.

### 4.3 Pairing and token exchange

Every pairing flow ends with a **bootstrap credential** exchanged at `POST /oauth/token`.

**Credential forms accepted as input** (`packages/shared/src/remote.ts:188-245`). The token is read from the URL fragment first, then the query:

| Input | Example |
| --- | --- |
| Direct pairing URL | `http://192.168.1.5:3773/pair#token=ABCD2345EFGH` |
| Legacy query form | `http://192.168.1.5:3773/pair?token=ABCD2345EFGH` |
| Hosted pairing URL | `https://app.t3.codes/pair?host=https%3A%2F%2Fmac.tailnet.ts.net&label=Mac#token=ABCD2345EFGH` (base URL is the `host` query value) |
| Host plus code typed manually | host `mac.tailnet.ts.net`, code `ABCD2345EFGH`; `https://` assumed without a scheme |

Schemes `http:`, `https:`, `ws:`, `wss:` are accepted. Strip the token from any URL before logging or storing it (`packages/shared/src/remote.ts:154-163`).

The one-time code is 12 characters from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, valid 5 minutes, single use (`apps/server/src/auth/PairingGrantStore.ts:254,273-306`). Whether input is case-folded is **UNVERIFIED**: nothing in the server path normalizes case.

**Exchange request.** `POST /oauth/token` with `Content-Type: application/x-www-form-urlencoded` (anything else is `415` plain text). Source: `packages/contracts/src/environmentHttp.ts:471-477`, handler `apps/server/src/auth/http.ts:353-414`, logic `apps/server/src/auth/EnvironmentAuth.ts:859-955`.

| Field | Required | Value |
| --- | --- | --- |
| `grant_type` | yes | `urn:ietf:params:oauth:grant-type:token-exchange` |
| `subject_token` | yes | the pairing code (or desktop token, or relay-minted credential) |
| `subject_token_type` | yes | `urn:t3:params:oauth:token-type:environment-bootstrap` |
| `requested_token_type` | yes | `urn:ietf:params:oauth:token-type:access_token` |
| `scope` | no | space-separated scopes to narrow to. Official clients omit it. |
| `client_label` | no | free text. A label stored on the pairing link overrides it. |
| `client_device_type` | no | `desktop`, `mobile`, `tablet`, `bot`, `unknown` |
| `client_os` | no | free text, for example `macOS` |
| header `DPoP` | only for proof-bound credentials | proof without `ath` |

Recorded success (`01-basic` t=23; secret scrubbed):

```json
{"access_token":"<secret>","expires_in":2592000,"issued_token_type":"urn:ietf:params:oauth:token-type:access_token","scope":"orchestration:read orchestration:operate settings:write providers:manage environment:maintain preview:operate diagnostics:read terminal:read terminal:operate source-control:write filesystem:read filesystem:write relay:read access:read access:write relay:write","token_type":"Bearer"}
```

- `expires_in` is 2,592,000 seconds (30 days) for Bearer. With a valid DPoP header, `token_type` is `"DPoP"` and `expires_in` about 3600 (`apps/server/src/auth/EnvironmentAuth.ts:908-918`).
- `scope` is the full exact grant. The recorded pairing was an administrative one (16 scopes); `02-turn` t=27 returned the 13 standard scopes. Scope depends on the credential.
- Scope narrowing: unknown names are dropped. Invalid syntax or an empty result is 400 `invalid_scope`; none in the grant is 400 `scope_not_granted`; neither consumes the code (`apps/server/src/auth/http.ts:359-365`, `PairingGrantStore.ts:559-561`).
- A rejected credential (unknown, used, expired, revoked) is always one indistinguishable 401 `invalid_credential`.

**Persist** per environment: `{environmentId, label, httpBaseUrl, wsBaseUrl}` plus the token in the Keychain. Never persist the pairing code. There are no refresh tokens: renew by pairing again (`docs/research/C-auth-connect.md` 1.9).

### 4.4 WebSocket ticket

`POST /api/auth/websocket-ticket`, no body, authenticated (`packages/contracts/src/environmentHttp.ts:478-484`, `apps/server/src/auth/http.ts:415-428`). Response `{"ticket":"<b64url claims>.<hmac>","expiresAt":"<ISO>"}`, `Cache-Control: no-store`. Lifetime 5 minutes. The ticket is **not single-use**: it is verified, not consumed (`apps/server/src/auth/SessionStore.ts:901-970`). The official client mints a fresh ticket for every connection attempt; do the same.

Media routes (`/api/preview-stream/*`, `/api/device-hub/*`) accept the same ticket as `?wsTicket=` because `<img>` and WebSocket cannot set headers (`apps/server/src/auth/http.ts:158-186`).

### 4.5 Session endpoint

`GET /api/auth/session` (`packages/contracts/src/environmentHttp.ts:457-461`). Headers: optional `authorization`, optional `dpop`. It **never answers 401**: without a valid credential it returns `{"authenticated":false,"auth":{...}}` (`apps/server/src/auth/EnvironmentAuth.ts:770-789`). With a credential (`01-basic` t=24):

```json
{"auth":{"bootstrapMethods":["one-time-token"],"policy":"loopback-browser","serverUpdateScope":"environment:maintain","sessionCookieName":"t3_session_47391_a303d7692026","sessionMethods":["browser-session-cookie","bearer-access-token","dpop-access-token"]},
 "authenticated":true,"expiresAt":"2026-11-08T09:10:20.026Z",
 "permissions":["orchestration:read","orchestration:operate","settings:write","..."],
 "scopes":["orchestration:read","orchestration:operate","terminal:operate","relay:read","access:read","access:write","relay:write"],
 "sessionMethod":"bearer-access-token"}
```

| Field | Type | Notes |
| --- | --- | --- |
| `authenticated` | bool | |
| `auth.policy` | `desktop-managed-local`, `loopback-browser`, `remote-reachable` (`unsafe-no-auth` exists in the contract but is never produced) | `apps/server/src/auth/EnvironmentAuthPolicy.ts:23-37` |
| `auth.bootstrapMethods` | array: `desktop-bootstrap`, `one-time-token` | |
| `auth.sessionMethods` | always the 3 methods | |
| `auth.sessionCookieName` | string | |
| `auth.serverUpdateScope` | `environment:maintain` | |
| `scopes`, `permissions` | arrays, see 4.1 | only when `authenticated` |
| `sessionMethod` | `browser-session-cookie`, `bearer-access-token`, `dpop-access-token` | |
| `expiresAt` | ISO string | |

Use it right after pairing to read `permissions` and `expiresAt`.

### 4.6 Error shapes

HTTP errors are `Schema.TaggedError` JSON bodies including `_tag` (`packages/contracts/src/environmentHttp.ts:130-242`):

| Status | `_tag` | Fields |
| --- | --- | --- |
| 400 | `EnvironmentRequestInvalidError` | `code:"invalid_request"`, `reason`: `invalid_scope`, `scope_not_granted`, `invalid_command`, `invalid_history_cursor`; `traceId` |
| 401 | `EnvironmentAuthInvalidError` | `code:"auth_invalid"`, `reason`: `missing_credential`, `invalid_credential`; optional `dpopFailureReason`; `traceId` |
| 403 | `EnvironmentScopeRequiredError` | `code:"insufficient_scope"`, `requiredScope` (legacy parent), `requiredPermission` (exact); `traceId` |
| 403 | `EnvironmentOperationForbiddenError` | `code:"operation_forbidden"`, `reason:"current_session_revoke_not_allowed"`; `traceId` |
| 404 | `EnvironmentResourceNotFoundError` | `code:"not_found"`, `reason:"thread_not_found"`; `traceId` |
| 500 | `EnvironmentInternalError` | `code:"internal_error"`, `reason` (17 values, `environmentHttp.ts:109-127`); `traceId` |

Other failure forms:

- A request that fails schema decoding (missing orchestration header, bad params, bad body) gets an **empty 400** (`.repos/effect-smol/packages/effect/src/http-api/HttpApiError.ts:470-505`).
- `/api/connect/*` management routes use `{_tag, message}` bodies with 400, 401, 403, 409, 500 and 503 `EnvironmentCloudEndpointUnavailableError` (`environmentHttp.ts:259-332`).
- `dpopFailureReason` values: `time_window`, `key_mismatch`, `request_mismatch`, `token_mismatch`, `replay`, `invalid_proof` (`packages/contracts/src/baseSchemas.ts:37-44`).
- `WWW-Authenticate: DPoP` is added to 401 when the request used the `DPoP` scheme, and on `/oauth/token` only when the proof itself fails (`apps/server/src/auth/http.ts:50-64,366-376`).
- Raw routes (assets, attachment upload, static files) answer plain text: `Bad Request` 400, `Not Found` 404, `Internal Server Error` 500, `Content-Length must match the upload size.` 400 (`apps/server/src/http.ts:396-484`).
- Over the WebSocket, a missing scope is `EnvironmentAuthorizationError` (section 2.6).

### 4.7 Session management endpoints

`packages/contracts/src/environmentHttp.ts:485-529`, handlers `apps/server/src/auth/http.ts:429-528`. All need authentication plus the scope shown.

| Method and path | Scope | Body | Response |
| --- | --- | --- | --- |
| `POST /api/auth/pairing-token` | `access:write` plus every delegated scope | `{"label"?: string, "scopes"?: AuthGrantScope[]}` | `{"id","credential","label"?,"expiresAt"}` |
| `GET /api/auth/pairing-links` | `access:read` | none | `AuthPairingLink[]` (metadata, never the secret) |
| `POST /api/auth/pairing-links/revoke` | `access:write` | `{"id"}` | `{"revoked": boolean}` |
| `GET /api/auth/clients` | `access:read` | none | `AuthClientSession[]` |
| `POST /api/auth/clients/revoke` | `access:write` | `{"sessionId"}` | `{"revoked": boolean}`; revoking your own session is 403 `operation_forbidden` |
| `POST /api/auth/clients/revoke-others` | `access:write` | none | `{"revokedCount": number}` |

`AuthClientSession` (`packages/contracts/src/auth.ts:344-366`): `{sessionId, subject, scopes, permissions, method, client:{label?, ipAddress?, userAgent?, deviceType, os?, browser?}, issuedAt, expiresAt, lastConnectedAt|null, connected, current}`. Live updates: `subscribeAuthAccess` (section 6).

There is no self-logout endpoint. "Forget this environment" means deleting the stored token.

### 4.8 Client rules that follow from the server

1. Send `orchestrationProtocol=2` on `/ws` and the orchestration header on `/api/orchestration/*`.
2. Verify `environmentId` at `/.well-known/t3/environment` before sending any credential to a new address.
3. Never put long-lived tokens in URLs. Use the 5 minute ticket for sockets.
4. Never fall back to loopback for a remote environment.
5. Treat pairing URLs and signed asset or upload URLs as passwords. They stay valid after the minting session is revoked until they expire (`docs/internals/environment-auth.md:111-120`).
6. Request bodies are JSON except `/oauth/token` and the relay `/v1/client/dpop-token`, which are form-encoded.

---

## 5. HTTP endpoints

Every route the server exposes, from `packages/contracts/src/environmentHttp.ts:440-760` (the `HttpApi` definitions), `apps/server/src/http.ts`, and the route files named per row. The `HttpApi` assembly is `EnvironmentHttpApi` at `environmentHttp.ts:761-770`.

Header shorthand: **Auth** = `Authorization: Bearer|DPoP` (plus `DPoP` proof) required. **Proto** = also requires `x-t3-orchestration-protocol: 2`. "token in path" means the signed URL itself is the credential.

### 5.1 Typed API routes (`HttpApi`)

| Method | Path | Auth and scope | Request | Response (200) | Source line |
| --- | --- | --- | --- | --- | --- |
| GET | `/.well-known/t3/environment` | none | none | `ExecutionEnvironmentDescriptor` | `environmentHttp.ts:450` |
| GET | `/api/auth/session` | optional (never 401) | optional `authorization`, `dpop` headers | `AuthSessionState` | `:457` |
| POST | `/api/auth/browser-session` | none (credential in body) | JSON `AuthBrowserSessionRequest` `{credential}` | `AuthBrowserSessionResult`; sets cookie. Native client does not use it. | `:464` |
| POST | `/oauth/token` | credential in form body; optional `dpop` | form `AuthTokenExchangeRequest` | `AuthAccessTokenResult` | `:471` |
| POST | `/api/auth/websocket-ticket` | Auth | none | `AuthWebSocketTicketResult` `{ticket, expiresAt}` | `:479` |
| POST | `/api/auth/pairing-token` | Auth, `access:write` | `AuthCreatePairingCredentialInput` | `AuthPairingCredentialResult` | `:486` |
| GET | `/api/auth/pairing-links` | Auth, `access:read` | none | `AuthPairingLink[]` | `:494` |
| POST | `/api/auth/pairing-links/revoke` | Auth, `access:write` | `{id}` | `{revoked}` | `:501` |
| GET | `/api/auth/clients` | Auth, `access:read` | none | `AuthClientSession[]` | `:509` |
| POST | `/api/auth/clients/revoke` | Auth, `access:write` | `{sessionId}` | `{revoked}` | `:516` |
| POST | `/api/auth/clients/revoke-others` | Auth, `access:write` | none | `{revokedCount}` | `:524` |
| GET | `/api/orchestration/shell` | Auth + Proto, `orchestration:read` | none | `OrchestrationV2ShellSnapshot` | `:610`, handler `apps/server/src/orchestration-v2/http.ts:151-164` |
| GET | `/api/orchestration/threads/:threadId` | Auth + Proto, `orchestration:read` | none | `OrchestrationV2ThreadDetailSnapshot` `{snapshotSequence, projection}` (full) | `:617` |
| GET | `/api/orchestration/threads/:threadId/bounded` | Auth + Proto, `orchestration:read` | query `compactTurnItems=1` optional | `OrchestrationV2ThreadBoundedSnapshot` | `:625` |
| GET | `/api/orchestration/threads/:threadId/history` | Auth + Proto, `orchestration:read` | query `cursor` (required), `throughEntryId?`, `view?` = `conversation` or `activity` | `OrchestrationV2ThreadHistoryPage` | `:634` |
| GET | `/api/projects` | Auth, `orchestration:read` | none | `ProjectSnapshot` `{projects: Project[], updatedAt}` | `:645`, handler `apps/server/src/project/http.ts:45` |
| POST | `/api/projects/mutate` | Auth, `orchestration:operate` | `ProjectMutation` (JSON union on `type`: `project.create`, `project.update`, `project.delete`) | `Project` | `:652`, `apps/server/src/project/http.ts:56` |
| POST | `/api/pull-requests/diff` | Auth, `orchestration:read` | `PullRequestDiffInput` | `PullRequestDiffResult` | `:662`, `apps/server/src/pullRequest/http.ts:19` |
| POST | `/api/connect/link-proof` | Auth, `relay:write`, loopback only | `RelayLinkProofRequest` | `RelayEnvironmentLinkProof` (a JWT string) | `:678` |
| POST | `/api/connect/relay-config` | Auth, `relay:write` | `RelayEnvironmentConfigRequest` | `EnvironmentCloudRelayConfigResult` (503 `EnvironmentCloudEndpointUnavailableError` possible) | `:686` |
| GET | `/api/connect/link-state` | Auth, `relay:read` | none | `EnvironmentCloudLinkStateResult` `{linked, cloudUserId, relayUrl, relayIssuer, managedTunnelActive?, publishAgentActivity, holdWebhooksWhileOffline?}` | `:694`, shape `:410-425` |
| POST | `/api/connect/unlink` | Auth, `relay:write` | none | `EnvironmentCloudRelayConfigResult` | `:701` |
| POST | `/api/connect/preferences` | Auth, `relay:write` | `{publishAgentActivity: bool, holdWebhooksWhileOffline?: bool}` | `EnvironmentCloudLinkStateResult` | `:708`, body `:427-432` |
| POST | `/api/t3-connect/health` | none; relay-signed JWT in body | `RelayCloudEnvironmentHealthRequest` | `RelayEnvironmentHealthResponse` | `:716` |
| POST | `/api/connect/mint-credential` (legacy) and `/api/t3-connect/mint-credential` | none; relay-signed JWT in body | `RelayCloudMintCredentialRequest` | `RelayEnvironmentMintResponse` | `:723`, `:730` |
| POST, PUT, PATCH, GET | `/api/hooks/:hookId/:token` | none; token in path | raw body | 202 `{deliveryId}` | `:753-759` |

Orchestration route errors: 404 `thread_not_found`, 400 `invalid_history_cursor`, 500 `orchestration_snapshot_failed`, `orchestration_thread_snapshot_failed`, `orchestration_thread_bounded_snapshot_failed`, `orchestration_thread_history_failed` (`environmentHttp.ts:94-139`, `apps/server/src/orchestration-v2/http.ts:91-234`).

MCP OAuth routes (agents that T3 did not launch signing in to `/mcp`; a native client does not use them) (`environmentHttp.ts:537-581`): `GET /.well-known/oauth-protected-resource`, `GET /.well-known/oauth-protected-resource/mcp`, `GET /.well-known/oauth-authorization-server`, `POST /oauth/mcp/register`, `GET /oauth/mcp/authorize`, `POST /oauth/mcp/approval`, `POST /oauth/mcp/decision`, `POST /oauth/mcp/token`. Sessions they create (`mcp-client`) are accepted only on `/mcp`.

### 5.2 Raw routes (not in the `HttpApi`)

| Method | Path | Auth | Purpose | Source |
| --- | --- | --- | --- | --- |
| GET | `/ws` | `wsTicket` query, cookie or header | RPC WebSocket | `apps/server/src/ws.ts:3136` |
| GET | `/api/assets/<kind>/<rest>` | token in path (signed, 1 hour: `ASSET_TOKEN_TTL_MS`) | asset bytes: attachments, workspace files, media, project favicon, tool-output images, native app icons, GitHub media proxy. Supports `Range` and `If-Range`. Mint the URL with RPC `assets.createUrl`. | `apps/server/src/http.ts:396-447`, `apps/server/src/assets/AssetAccess.ts:62-65` |
| POST | `/api/attachments/upload/<token>` | token in path (signed, 10 minutes: `ATTACHMENT_UPLOAD_URL_TTL_MS`) | upload attachment bytes (204 on success). `Content-Length` must match the declared size. Mint with RPC `attachments.createUploadUrl`. | `apps/server/src/http.ts:449-484`, `packages/contracts/src/assets.ts:93` |
| GET | `/api/preview-stream/ws` | `wsTicket` or cookie, `orchestration:read` (operate needed for input) | server-hosted browser tab stream (WebSocket) | `apps/server/src/preview/ServerBrowserStream.ts:28,72` |
| GET | `/api/preview-stream/download?threadId&tabId&id` | same | file a server tab downloaded | `ServerBrowserStream.ts:214-217` |
| POST | `/api/preview-stream/upload?threadId&tabId&chooser` | `orchestration:operate` | multipart `file` for a file chooser | `ServerBrowserStream.ts:236-241` |
| any | `/api/device-hub/*` and upstream WS `/api/devices/ws` | `wsTicket` or cookie; read scope, operate scope for control paths | device streaming proxy | `apps/server/src/device/DeviceHubProxy.ts:168-197` |
| POST | `/api/observability/v1/traces` | Auth, `orchestration:operate` | browser OTLP trace proxy. Not needed. | `apps/server/src/http.ts:52,325-375` |
| POST | `/mcp` (+ `/connect-agent`) | `mcp-client` session | T3's MCP server for agents. Not needed. | `apps/server/src/mcp/McpHttpServer.ts:849` |
| GET | `*` | none | static web app | `apps/server/src/http.ts:679` |

CORS: wildcard outside dev, `Origin` is never checked; allowed request headers `authorization`, `b3`, `traceparent`, `content-type`, `dpop`, `x-t3-orchestration-protocol`; methods `GET`, `POST`, `OPTIONS` (`apps/server/src/httpCors.ts:3-11`, `apps/server/src/http.ts:239-262`). Responses are compressed (`layerHttpCompression`, `http.ts:235`), so send `Accept-Encoding` and let `URLSession` decode.

### 5.3 Attachment flow

1. `attachments.createUploadUrl` RPC with `{type?: "image"|"file", name, mimeType, sizeBytes}`. Image `mimeType` must be a supported image type and `sizeBytes` 1 to `PROVIDER_SEND_TURN_MAX_IMAGE_BYTES` (10 MiB); file `sizeBytes` 1 to `PROVIDER_SEND_TURN_MAX_FILE_BYTES` (50 MiB) (`packages/contracts/src/chatAttachment.ts:14-17`). `name` max 255 chars (`packages/contracts/src/assets.ts:93-125`).
2. Result `{attachmentId, relativeUrl, expiresAt}`. `relativeUrl` is `/api/attachments/upload/<base64url claims>.<hmac>`.
3. `POST` the raw bytes to `relativeUrl` with a matching `Content-Length`.
4. Put `{type, id: attachmentId, name, mimeType, sizeBytes}` in the `attachments` array of `message.dispatch`. The server claims the pending upload, copies it into the thread store and rewrites the ids before the command runs (`apps/server/src/orchestration-v2/ThreadMessageIntake.ts:53-165`). Limits: 100 attachments, 80 MiB of images, no duplicate ids.
5. `attachments.delete {attachmentId}` discards an unused upload.
6. To show an attachment, call `assets.createUrl` with `{resource: {_tag:"attachment", attachmentId, fileName?, mimeType?, disposition?}}` and fetch `relativeUrl` (`packages/contracts/src/assets.ts:14-90`).

---

## 6. RPC methods

The authoritative list is the generated catalog `docs/research/A-rpc-catalog.md`: 185 methods in `WsRpcGroup` (`packages/contracts/src/rpc.ts:1811-1997`), each with payload, success, error and required scope. Regenerate it with `scripts/gen-rpc-catalog.py ../CandyWrapper-research/t3code`. Rules:

- **Only methods in `WsRpcGroup` are served.** `WS_METHODS` (`packages/contracts/src/rpc.ts:360-568`) also names tags the server does not serve: `projects.list`, `projects.add`, `projects.remove` (`rpc.ts:362-364`). Calling one gives `Die "Unknown request tag: projects.list"` (`01-basic` t=39). Use the shell snapshot or `GET /api/projects` instead.
- The `rpc.ts` column below is the line of the `Rpc.make(...)` definition in `packages/contracts/src/rpc.ts`. Payload and success type names are exported from `packages/contracts/src/`.
- "inline struct" means the payload is defined inline in `rpc.ts` at that line.
- Required scopes: `apps/server/src/auth/RpcAuthorization.ts:43-209`. Each method also has `EnvironmentAuthorizationError` in its error union.
- Errors shown are a truncated view from the catalog. Read the `Rpc.make` block for the full union.
- Handlers: `apps/server/src/ws.ts`.

### 6.1 Methods by milestone

#### Milestone 3: skeleton and sidebar

Connect, load config and settings, subscribe to the shell, show projects and threads. The recorded client (`01-basic`) used exactly these on startup.

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `server.getConfig` | unary | `{}` | `ServerConfig` | `KeybindingsConfigError`, `ServerSettingsError`, ... | `orchestration:read` | 588 |
| `server.getSettings` | unary | `{}` | `ServerSettings` | `ServerSettingsError`, ... | `orchestration:read` | 733 |
| `subscribeServerConfig` | stream | inline struct | `ServerConfigStreamEvent` | `KeybindingsConfigError`, `ServerSettingsError`, ... | `orchestration:read` | 1679 |
| `subscribeServerLifecycle` | stream | `{}` | `ServerLifecycleStreamEvent` | - | `orchestration:read` | 1703 |
| `orchestration.subscribeShell` | stream | `OrchestrationV2SubscribeShellInput` | `OrchestrationV2ShellStreamItem` | `OrchestrationV2GetShellSnapshotError`, ... | `orchestration:read` | 1651 |
| `orchestration.subscribeArchivedShell` | stream | `OrchestrationV2RpcSchemas.subscribeArchivedShell.input` | `OrchestrationV2RpcSchemas.subscribeArchivedShell.output` | `OrchestrationV2GetShellSnapshotError`, ... | `orchestration:read` | 1641 |
| `orchestration.getArchivedShellSnapshot` | unary | `OrchestrationV2RpcSchemas.getArchivedShellSnapshot.input` | `OrchestrationV2RpcSchemas.getArchivedShellSnapshot.output` | `OrchestrationV2GetShellSnapshotError`, ... | `orchestration:read` | 1602 |
| `server.probe` | unary | `{}` | `{}` | - | `orchestration:read` | 582 |
| `server.reportClientActivity` | unary | `ClientActivityReportInput` | `void` | - | `orchestration:read` | 900 |
| `server.getBackgroundPolicy` | unary | `{}` | `BackgroundPolicySnapshot` | - | `orchestration:read` | 910 |
| `subscribeBackgroundPolicy` | stream | `{}` | `BackgroundPolicySnapshot` | - | `orchestration:read` | 1787 |
| `projects.mutate` | unary | `ProjectMutation` | `Project` | `ProjectMutationError`, ... | `orchestration:operate` | 1187 |
| `filesystem.browse` | unary | `FilesystemBrowseInput` | `FilesystemBrowseResult` | `FilesystemBrowseError`, ... | `filesystem:read` | 1212 |

#### Milestone 4: read-only thread view

Open a thread, page history, show tool output, diffs and files.

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `orchestration.subscribeThread` | stream | `OrchestrationV2SubscribeThreadInput` | `OrchestrationV2ThreadStreamItem` | `OrchestrationV2GetThreadProjectionError`, ... | `orchestration:read` | 1658 |
| `orchestration.getThreadProjection` | unary | `OrchestrationV2GetThreadProjectionInput` | `OrchestrationV2ThreadProjection` | `OrchestrationV2GetThreadProjectionError`, ... | `orchestration:read` | 1611 |
| `orchestration.getTurnItem` | unary | `OrchestrationV2GetTurnItemInput` | `OrchestrationV2GetTurnItemResult` | `OrchestrationV2GetThreadProjectionError`, ... | `orchestration:read` | 1629 |
| `orchestration.getTurnDiff` | unary | `OrchestrationGetTurnDiffInput` | `OrchestrationGetTurnDiffResult` | `OrchestrationGetTurnDiffError`, ... | `orchestration:read` | 1565 |
| `orchestration.getFullThreadDiff` | unary | `OrchestrationGetFullThreadDiffInput` | `OrchestrationGetFullThreadDiffResult` | `OrchestrationGetFullThreadDiffError`, ... | `orchestration:read` | 1571 |
| `orchestration.searchThreads` | unary | `OrchestrationSearchThreadsInput` | `OrchestrationSearchThreadsResult` | `OrchestrationSearchThreadsError`, ... | `orchestration:read` | 1596 |
| `orchestration.searchThread` | unary | `OrchestrationV2SearchThreadInput` | `OrchestrationV2SearchThreadResult` | `OrchestrationV2SearchThreadError`, ... | `orchestration:read` | 1580 |
| `orchestration.searchThreadStream` | stream | `OrchestrationV2SearchThreadInput` | `OrchestrationV2SearchThreadResult` | `OrchestrationV2SearchThreadError`, ... | `orchestration:read` | 1586 |
| `orchestration.getWorkflowScript` | unary | `OrchestrationV2GetWorkflowScriptInput` | `OrchestrationV2GetWorkflowScriptResult` | `OrchestrationGetWorkflowScriptError`, ... | `orchestration:read` | 1620 |
| `assets.createUrl` | unary | `AssetCreateUrlInput` | `AssetCreateUrlResult` | `AssetAccessError`, ... | `orchestration:read` | 1235 |
| `projects.readFile` | unary | `ProjectReadFileInput` | `ProjectReadFileResult` | `ProjectReadFileError`, ... | `filesystem:read` | 1175 |
| `projects.listEntries` | unary | `ProjectListEntriesInput` | `ProjectListEntriesResult` | `ProjectListEntriesError`, ... | `filesystem:read` | 1169 |
| `projects.searchEntries` | unary | `ProjectSearchEntriesInput` | `ProjectSearchEntriesResult` | `ProjectSearchEntriesError`, ... | `filesystem:read` | 1157 |
| `projects.searchContents` | unary | `ProjectSearchContentsInput` | `ProjectSearchContentsResult` | `ProjectSearchContentsError`, ... | `filesystem:read` | 1163 |
| `subscribeVcsStatus` | stream | `VcsStatusSubscriptionInput` | `VcsStatusStreamEvent` | `GitManagerServiceError`, ... | `orchestration:read` | 1287 |
| `vcs.refreshStatus` | unary | `VcsStatusInput` | `VcsStatusResult` | `GitManagerServiceError`, ... | `orchestration:read` | 1300 |
| `review.getDiffPreview` | unary | `ReviewDiffPreviewInput` | `ReviewDiffPreviewResult` | `ReviewDiffPreviewError`, ... | `filesystem:read` | 1377 |
| `review.getDiffFileContents` | unary | `ReviewDiffFileContentsInput` | `ReviewDiffFileContentsResult` | `ReviewDiffPreviewError`, ... | `filesystem:read` | 1383 |

#### Milestone 5: interactive turn

Send messages, interrupt, approvals, queue, model picker, attachments. Approvals, queue and interrupt are all `orchestration.dispatchCommand` commands (section 7.3).

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `orchestration.dispatchCommand` | unary | `OrchestrationV2Command` | `OrchestrationV2DispatchCommandResult` | `OrchestrationV2DispatchCommandError`, ... | `orchestration:operate` | 1559 |
| `orchestration.launchThread` | unary | `OrchestrationV2ThreadLaunchInput` | `OrchestrationV2ThreadLaunchResult` | `OrchestrationV2ThreadLaunchError`, ... | `orchestration:operate` | 1635 |
| `attachments.createUploadUrl` | unary | `AttachmentCreateUploadUrlInput` | `AttachmentCreateUploadUrlResult` | `AttachmentUploadSigningKeyError`, ... | `orchestration:operate` | 1247 |
| `attachments.delete` | unary | `AttachmentDeleteInput` | `void` | - | `orchestration:operate` | 1253 |
| `assets.persistChatAttachments` | unary | `PersistChatAttachmentsInput` | `PersistChatAttachmentsResult` | `PersistChatAttachmentsError`, ... | `orchestration:operate` | 1241 |
| `secrets.answerRequest` | unary | `SecretRequestAnswerInput` | `void` | `SecretRequestError`, ... | `orchestration:operate` | 1757 |
| `server.refreshProviders` | unary | inline struct | `ServerProviderUpdatedPayload` | union | `orchestration:read` | 594 |
| `server.updateSettings` | unary | inline struct | `ServerSettings` | `ServerSettingsError`, ... | `settings:write` | 739 |

#### Milestone 6: T3 Connect

Most of T3 Connect is HTTP to the relay and to the environment (section 10). On the socket:

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `cloud.getRelayClientStatus` | unary | `{}` | `RelayClientStatusSchema` | - | `relay:read` | 887 |
| `cloud.installRelayClient` | stream | `{}` | `RelayClientInstallProgressEventSchema` | `RelayClientInstallFailedError`, ... | `relay:write` | 893 |
| `subscribeAuthAccess` | stream | `{}` | `AuthAccessStreamEvent` | `AuthAccessStreamError`, ... | `access:read` | 1780 |

#### Milestone 7: terminal

Terminal sessions (section 9.1).

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `terminal.open` | unary | `TerminalOpenInput` | `TerminalSessionSnapshot` | `TerminalError` | `terminal:operate` | 1389 |
| `terminal.attach` | stream | `TerminalAttachInput` | `TerminalAttachStreamEvent` | `TerminalError` | `terminal:operate` | 1395 |
| `terminal.observe` | stream | `TerminalObserveInput` | `TerminalAttachStreamEvent` | `TerminalError` | `terminal:read` | 1402 |
| `terminal.write` | unary | `TerminalWriteInput` | `void` | `TerminalError` | `terminal:operate` | 1409 |
| `terminal.resize` | unary | `TerminalResizeInput` | `void` | `TerminalError` | `terminal:operate` | 1414 |
| `terminal.clear` | unary | `TerminalClearInput` | `void` | `TerminalError` | `terminal:operate` | 1419 |
| `terminal.restart` | unary | `TerminalRestartInput` | `TerminalSessionSnapshot` | `TerminalError` | `terminal:operate` | 1424 |
| `terminal.close` | unary | `TerminalCloseInput` | `void` | `TerminalError` | `terminal:operate` | 1430 |
| `subscribeTerminalEvents` | stream | `{}` | `TerminalEvent` | - | `terminal:read` | 1665 |
| `subscribeTerminalMetadata` | stream | `{}` | `TerminalMetadataStreamEvent` | - | `terminal:read` | 1672 |

#### Milestone 7: git, VCS, worktrees, source control

Section 9.2.

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `server.discoverSourceControl` | unary | `{}` | `SourceControlDiscoveryResult` | - | `orchestration:read` | 748 |
| `sourceControl.lookupRepository` | unary | `SourceControlRepositoryLookupInput` | `SourceControlRepositoryInfo` | `SourceControlRepositoryError`, ... | `orchestration:read` | 1108 |
| `sourceControl.cloneRepository` | unary | `SourceControlCloneRepositoryInput` | `SourceControlCloneRepositoryResult` | `SourceControlRepositoryError`, ... | `source-control:write` | 1114 |
| `sourceControl.publishRepository` | unary | `SourceControlPublishRepositoryInput` | `SourceControlPublishRepositoryResult` | `SourceControlRepositoryError`, ... | `source-control:write` | 1151 |
| `subscribeWorktreeSetup` | stream | `WorktreeSetupSubscribeInput` | `WorktreeSetupStreamEvent` | - | `orchestration:read` | 1306 |
| `worktreeSetup.cancel` | unary | `WorktreeSetupCancelInput` | `WorktreeSetupCancelResult` | - | `orchestration:operate` | 1313 |
| `vcs.pull` | unary | `VcsPullInput` | `VcsPullResult` | `GitCommandError`, ... | `source-control:write` | 1294 |
| `git.runStackedAction` | stream | `GitRunStackedActionInput` | `GitActionProgressEvent` | `GitManagerServiceError`, ... | `source-control:write` | 1319 |
| `git.resolvePullRequest` | unary | `GitPullRequestRefInput` | `GitResolvePullRequestResult` | `GitManagerServiceError`, ... | `orchestration:read` | 1326 |
| `git.preparePullRequestThread` | unary | `GitPreparePullRequestThreadInput` | `GitPreparePullRequestThreadResult` | `GitManagerServiceError`, ... | `source-control:write` | 1332 |
| `vcs.listRefs` | unary | `VcsListRefsInput` | `VcsListRefsResult` | `GitCommandError`, ... | `orchestration:read` | 1338 |
| `vcs.createWorktree` | unary | `VcsCreateWorktreeInput` | `VcsCreateWorktreeResult` | `GitCommandError`, ... | `source-control:write` | 1344 |
| `vcs.removeWorktree` | unary | `VcsRemoveWorktreeInput` | `void` | `GitCommandError`, ... | `source-control:write` | 1350 |
| `vcs.createRef` | unary | `VcsCreateRefInput` | `VcsCreateRefResult` | `GitCommandError`, ... | `source-control:write` | 1355 |
| `vcs.switchRef` | unary | `VcsSwitchRefInput` | `VcsSwitchRefResult` | `GitCommandError`, ... | `source-control:write` | 1361 |
| `vcs.init` | unary | `VcsInitInput` | `void` | `VcsError` | `source-control:write` | 1367 |

#### Milestone 7: settings, keybindings, providers

Section 9.4 to 9.6.

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `server.upsertKeybinding` | unary | `ServerUpsertKeybindingInput` | `ServerUpsertKeybindingResult` | `KeybindingsConfigError`, ... | `settings:write` | 570 |
| `server.removeKeybinding` | unary | `ServerRemoveKeybindingInput` | `ServerRemoveKeybindingResult` | `KeybindingsConfigError`, ... | `settings:write` | 576 |
| `server.updateProvider` | unary | `ServerProviderUpdateInput` | `ServerProviderUpdatedPayload` | `ServerProviderUpdateError`, ... | `providers:manage` | 615 |
| `provider.auth.start` | unary | `ProviderAuthStartInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 629 |
| `provider.auth.respond` | unary | `ProviderAuthRespondInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 635 |
| `provider.auth.complete` | unary | `ProviderAuthCompleteInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 641 |
| `provider.auth.cancel` | unary | `ProviderAuthCancelInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 670 |
| `provider.auth.logout` | unary | `ProviderSetupInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 676 |
| `provider.auth.subscribe` | stream | `ProviderSetupInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 682 |
| `provider.install.start` | unary | `ProviderSetupInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `providers:manage` | 689 |
| `provider.install.cancel` | unary | `ProviderInstallCancelInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `providers:manage` | 695 |
| `provider.install.subscribe` | stream | `ProviderSetupInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `orchestration:read` | 701 |
| `provider.install.remove` | unary | `ProviderSetupInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `providers:manage` | 708 |
| `provider.consumeResetCredit` | unary | `ProviderConsumeResetCreditInput` | `ProviderConsumeResetCreditResult` | `ProviderSetupError`, `UsageLimitSourceError`, ... | `providers:manage` | 623 |
| `shell.openInEditor` | unary | `LaunchEditorInput` | `void` | `ExternalLauncherError`, ... | `orchestration:operate` | 1207 |


### 6.2 All other methods

Not needed before the milestones above. Names, kinds, payloads and scopes are in the catalog. By family:

| Family | Methods |
| --- | --- |
| Pull requests (section 9.3) | `pullRequests.list`, `pullRequests.listStats`, `pullRequests.summary`, `pullRequests.routing`, `pullRequests.routingIdentity`, `pullRequests.stack`, `pullRequests.linkedThreads`, `pullRequests.detail`, `pullRequests.preview`, `pullRequests.checks`, `pullRequests.activity`, `pullRequests.threadComments`, `pullRequests.diffFileContents`, `pullRequests.filesViewed`, `pullRequests.setFilesViewed`, `pullRequests.runAction`, `pullRequests.update`, `pullRequests.comment`, `pullRequests.updateComment`, `pullRequests.submitReview`, `pullRequests.replyToThread`, `pullRequests.setThreadResolution`, `pullRequests.setReaction`, `pullRequests.invalidate`, `pullRequests.subscribeRefreshes`, `pullRequests.reviewerCandidates`, `pullRequests.requestReviewers`, `pullRequests.labelCandidates`, `pullRequests.setLabels` |
| Project clone (section 9.2) | `projectClone.start`, `projectClone.cancel`, `projectClone.retry`, `subscribeProjectClones` |
| Scheduled tasks (section 9.9) | `scheduledTasks.list`, `scheduledTasks.subscribe`, `scheduledTasks.upsert`, `scheduledTasks.setEnabled`, `scheduledTasks.delete`, `scheduledTasks.runNow`, `scheduledTasks.rotateWebhookToken`, `scheduledTasks.listWebhookDeliveries`, `scheduledTasks.getWebhookDelivery` |
| Preview (section 9.8) | `preview.open`, `preview.navigate`, `preview.resize`, `preview.adjust`, `preview.refresh`, `preview.close`, `preview.list`, `preview.clearProfile`, `preview.reportProfiles`, `preview.reportStatus`, `subscribePreviewEvents`, `subscribeDiscoveredLocalServers` |
| Devices (section 9.8) | `device.configure`, `device.list`, `device.testHost`, `device.open`, `device.close`, `device.shutdown`, `device.detail`, `device.action`, `subscribeDeviceState` |
| ACP registry | `server.searchAcpRegistry`, `server.prepareAcpRegistryAgent`, `server.uninstallAcpRegistryManagedBinary`, `server.acceptAcpRegistryUrlAuth`, `server.listAcpRegistrySessions`, `server.importAcpRegistrySession`, `server.deleteAcpRegistrySession`, `server.listAcpRegistryProviders`, `server.setAcpRegistryProvider`, `server.disableAcpRegistryProvider`, `server.logoutAcpRegistry` |
| Diagnostics, usage, host (section 9.10) | `server.getTraceDiagnostics`, `server.getProcessDiagnostics`, `server.getHostResources`, `server.getProcessResourceHistory`, `server.getResourceTelemetryHistory`, `server.retryResourceTelemetry`, `server.getUsageSummary`, `server.refreshUsageRates`, `server.signalProcess`, `subscribeResourceTelemetry`, `server.reportHostPowerState` |
| Self update and lifecycle | `server.updateServer`, `server.updateServerWithProgress`, `server.commitDesktopUpdate` |
| Provider helpers | `provider.chatgpt.reconnect-profile`, `provider.chatgpt.import-profile`, `provider.chatgpt.handoff.subscribe`, `provider.codex.auth-callback.subscribe`, `provider.uploadFeedback` |
| Agent sessions and MCP apps | `agentSessions.scan`, `agentSessions.import`, `mcpApps.callTool`, `mcpApps.toolInfo`, `mcpApps.readResource`, `mcpApps.updateModelContext` |
| Project files | `projects.ensureScratch`, `projects.createNew`, `projects.writeFile` |
| Scheduled-task secrets | `secrets.answerRequest` |

---

## 7. Orchestration model

Condensed from `docs/research/B-orchestration.md` (sections 0 to 4, 2.1) and checked against the recordings. B ended before the command catalog; section 7.3 was written directly from `packages/contracts/src/orchestrationV2.ts:2611-3054`.

### 7.1 Entities and ids

```text
Project                                  ProjectId   (workspaceRoot on the environment host)
  AppThread (conversation)               ThreadId    sidebar row = ThreadShell
    Run (one user-visible turn)          RunId       run.status drives "working"; a queued message is a Run with status "queued"
      RunAttempt (one provider try)      RunAttemptId
        root ExecutionNode (root_turn)   NodeId
          child nodes: tool_call, approval_request, user_input_request, subagent, assistant_message, reasoning, plan, todo_list, hook, system
    ProviderThread / ProviderSession / ProviderTurn   provider-side handles
    RuntimeRequest (approval or question)             RuntimeRequestId
    ConversationMessage                  MessageId
    TurnItem (ordered render rows)       TurnItemId   the thread view renders these
    PlanArtifact                         PlanId
    CheckpointScope / Checkpoint         CheckpointScopeId / CheckpointId
    ContextTransfer / ContextHandoff     forks, provider switches, merge-back
```

Source: `docs/orchestration-v2/README.md:62-81`, `docs/orchestration-v2/core-graph-and-data-model.md:5-25`. Invariants: app ids are primary and provider ids are references. Only the root node of a run can complete the run. A subagent finishing never closes its parent run (`docs/orchestration-v2/README.md:31-42`).

Id formats and who allocates them are in section 3.3. The client allocates `commandId`, `threadId`, `messageId`, `projectId`. Everything else is server-allocated.

#### Shared vocabularies

| Name | Values | Source |
| --- | --- | --- |
| `createdBy` (Actor) | `user`, `agent`, `system` | `orchestrationV2.ts:76` |
| `creationSource` | `web`, `mobile`, `mcp`, `provider`, `server` | `orchestrationV2.ts:79-85` |
| `RuntimeMode` | `approval-required`, `auto-accept-edits`, `auto`, `full-access` (default `full-access`) | `packages/contracts/src/providerPolicy.ts:25-32` |
| `ProviderInteractionMode` | `default`, `plan` | `providerPolicy.ts:34-36` |
| `ProviderRequestKind` | `command`, `file-read`, `file-change`, `mcp-elicitation`, `permission` | `providerPolicy.ts:38-44` |
| `ProviderApprovalDecision` | `accept`, `acceptForSession`, `acceptAlways`, `decline`, `cancel` | `providerPolicy.ts:50-56` |
| `RunStatus` | `preparing`, `queued`, `starting`, `running`, `waiting`, `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back` | `orchestrationV2.ts:453-464` |
| Shell thread `status` | `idle` or any `RunStatus` | `orchestrationV2.ts:1813-1816` |
| `TurnItemStatus` | `idle`, `pending`, `running`, `waiting`, `completed`, `failed`, `cancelled`, `interrupted` | `orchestrationV2.ts:1238-1247` |
| `ExecutionNode.status` | `idle`, `pending`, `running`, `waiting`, `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back` | `orchestrationV2.ts:622-660` |
| `RunAttempt.status` | `pending`, `running`, `completed`, `interrupted`, `failed`, `cancelled`, `superseded` | `orchestrationV2.ts:597-619` |
| `RunAttempt.reason` | `initial`, `steering_restart`, `retry`, `provider_recovery` | same |
| `UserMessageInputIntent` | `turn_start`, `queued_turn`, `steer`, `promoted_queued_to_steer` | `orchestrationV2.ts:1307-1312` |
| `ProviderFailureClass` | `usage_limit`, `provider_error`, `transport_error`, `permission_error`, `validation_error`, `unknown` | `orchestrationV2.ts:1261-1268` |
| `RuntimeRequest.status` | `pending`, `resolved`, `expired`, `cancelled` | `orchestrationV2.ts:1025-1044` |
| `ModelSelection` | `{instanceId: ProviderInstanceId, model: string, options?: ProviderOptionSelection[]}`. The decoder also accepts a legacy `provider` key for `instanceId`; always send `instanceId`. Recorded: `{"instanceId":"claudeAgent","model":"claude-haiku-5-5"}` | `packages/contracts/src/modelSelection.ts:10-60` |

#### Project shell (sidebar and `project.updated`)

`OrchestrationProjectShell` (`packages/contracts/src/orchestrationProject.ts:9-27`). Real example: `02-turn` t=625.

| Field | Type | Optionality | Notes |
| --- | --- | --- | --- |
| `id` | ProjectId | required | |
| `title` | string | required | |
| `workspaceRoot` | string | required | absolute path on the host |
| `repositoryIdentity` | `RepositoryIdentity` | `optional(NullOr)` | `{canonicalKey, locator:{source:"git-remote",remoteName,remoteUrl}, webUrl?, rootPath?, displayName?, provider?, owner?, name?, origin?:{canonicalKey, displayName?}}` (`environment.ts:229-258`). Often `null` at first, then filled by an enrichment snapshot |
| `defaultModelSelection` | ModelSelection | `NullOr` | |
| `defaultThreadEnvMode` | `"local"` or `"worktree"` | `optional(NullOr)` | `environment.ts:61` |
| `autoPull` | bool | optional | |
| `faviconPath` | string | `optional(NullOr)` | |
| `projectIcon` | forward-compatible union on `kind`, decodes to icon override or `null` | `optional(NullOr)` | `project.ts:150-163` |
| `scripts` | `ProjectScript[]` | required | `{id, name, command, icon, runOnWorktreeCreate, runOnSettle?, async?, previewUrl?, autoOpenPreview?}` (`project.ts:33-45`) |
| `createdAt`, `updatedAt` | IsoDateTime | required | |

The HTTP and `projects.mutate` `Project` additionally carries `deletedAt: NullOr` (`project.ts:166-183`; recorded at `02-turn` t=575).

#### Thread shell (sidebar row): `OrchestrationV2ThreadShell`

`packages/contracts/src/orchestrationV2.ts:1836-1928`. Real example: `02-turn`, last `thread.updated`. The shell has no turn content.

| Field | Type | Optionality | Meaning |
| --- | --- | --- | --- |
| `id`, `projectId` | ids | required | |
| `title` | string | required | |
| `createdBy`, `creationSource` | enums | required | |
| `providerInstanceId`, `modelSelection`, `runtimeMode`, `interactionMode` | | required | current thread defaults |
| `branch`, `worktreePath` | string | `NullOr` | |
| `linkedPullRequest`, `branchPullRequest` | `ThreadLinkedPullRequest` | `optional(NullOr)` | `{projectId, repository, number, url}` |
| `pullRequests` | `ThreadPullRequestLink[]` | optional | recorded `[]` |
| `activeProviderThreadId` | id | `NullOr` | |
| `lineage` | `{parentThreadId: id\|null, relationshipToParent: "fork"\|"subagent"\|null, rootThreadId}` | required | `orchestrationV2.ts:108-112` |
| `forkedFrom` | `{type:"run",threadId,runId}` or `{type:"node",nodeId}` or `{type:"provider_thread",providerThreadId,providerTurnId?}` | `NullOr` | |
| `createdAt`, `updatedAt` | DateTimeUtc | required | |
| `archivedAt`, `deletedAt` | DateTimeUtc | `NullOr` | |
| `settledOverride` | `"settled"` or `"active"` | `NullOr` | explicit user override |
| `settledAt` | DateTimeUtc | `NullOr` | |
| `unsettledAt`, `snoozedUntil`, `snoozedAt`, `pinnedAt`, `autoSettleDisabledAt` | DateTimeUtc | `optional(NullOr)` | recorded as `null` |
| `limitRecovery` | `{requestId?, runId, resetAt, autoResume, snooze?}` | `optional(NullOr)` | usage-limit recovery |
| `pinOrderKey`, `activeOrderKey` | string (fractional index) | `optional(NullOr)` | |
| `lastVisitedAt` | DateTimeUtc | `optional(NullOr)` | "omitted by servers that predate server-side visited tracking" (`:1913-1917`) |
| `titleRegeneration` | `{requestId, startedAt}` | `optional(NullOr)` | |
| `latestRunId` | RunId | `NullOr` | |
| `latestRunRequestedAt`, `latestRunStartedAt`, `latestRunCompletedAt` | DateTimeUtc | `optional(NullOr)` | |
| `activeRunId` | RunId | `NullOr` | the run that can be interrupted |
| `activityRunStartedAt` | DateTimeUtc | `optional(NullOr)` | work start of the activity run |
| `activityRunStatus` | `preparing`, `starting`, `running`, `waiting` | `optional(NullOr)` | |
| `status` | `idle` or RunStatus | required | |
| `lastError`, `lastErrorClass`, `usageLimitResetAt` | string, class, IsoDateTime | `optional(NullOr)` | |
| `pendingRuntimeRequest` | `{id, kind, createdAt}` | `NullOr` | `kind` from RuntimeRequest kinds (`:1819-1823`) |
| `latestVisibleMessage` | `{id, role, text, updatedAt}` | `NullOr` | **always `null` in this build** (`apps/server/src/orchestration-v2/ProjectionStore.ts:1482-1484`). Do not build previews on it. |
| `latestUserMessageAt` | DateTimeUtc | `NullOr` | includes wakes and agent-sent messages |
| `latestUserAuthoredMessageAt` | DateTimeUtc | `optional(NullOr)` | only messages the user wrote |
| `hasActionableProposedPlan` | bool | required | |
| `pendingBackgroundTasks` | `PendingBackgroundTask[]` | optional, default `[]` | `{taskId, description?, kind: "subagent"\|"command"\|"monitor"\|"background_task", childThreadId?}` |
| `providerInstanceHistory` | ProviderInstanceId[] | optional, default `[]` | |
| `goal` | `{objective, status, tokensUsed?, tokenBudget?, timeUsedSeconds?, checks?, lastCheck?}` | `optional(NullOr)` | status: `active`, `paused`, `blocked`, `usage_limited`, `budget_limited`, `complete` |
| `itemCount`, `visibleItemCount` | NonNegativeInt | required | |

#### Thread (detail): `OrchestrationV2AppThread`

`orchestrationV2.ts:364-439`. The payload of `thread.created` and every `thread.*` event and `projection.thread`. Same fields as the shell minus the derived summary fields (`latest*`, `active*`, `status`, `lastError*`, `pendingRuntimeRequest`, `latestVisibleMessage`, `itemCount`, ...). Differences: `title` is non-empty, `settledOverride`, `settledAt`, `lastVisitedAt` have decoding default `null`, plus `historyOrigin?` (`native`, `v1_import`), `rollbackRequestId?`, `rollbackFailure?: {requestId, message}|null`. `isProviderNativeSubagentThread` (`lineage.relationshipToParent === "subagent" && creationSource === "provider"`) means the thread cannot take messages (`:442-451`).

#### Run

`OrchestrationV2Run` (`orchestrationV2.ts:541-584`). Real example: `02-turn` t=127096.

| Field | Type | Optionality |
| --- | --- | --- |
| `id`, `threadId` | ids | required |
| `ordinal` | PositiveInt (1-based counted turn) | required |
| `providerInstanceId`, `modelSelection` | | required |
| `providerThreadId`, `rootNodeId`, `activeAttemptId`, `checkpointId`, `contextHandoffId` | ids | `NullOr` |
| `userMessageId` | MessageId (the message that started the run) | required |
| `status` | RunStatus | required |
| `queuePosition` | PositiveInt | `optional(NullOr)`; set for `queued` runs |
| `queueHeld` | bool | optional; restart recovery holds the queue until `queue.resume` |
| `requestedAt` | DateTimeUtc | required |
| `startedAt`, `completedAt` | DateTimeUtc | `NullOr` |
| `restartContinuationOfRunId`, `workStartedAt`, `restartCancelledBackgroundWork`, `sourcePlanRef`, `delegatedCompletion`, `workspacePreparation` | | optional |

**A queued message is a Run with `status: "queued"`** whose `userMessageId` points at the queued user message, ordered by `queuePosition`. Recorded: `02-turn` t=125862 seq 51, `run.created` with `status:"queued"`, `queuePosition:1`.

#### Other entities (summary)

| Entity | Fields | Source |
| --- | --- | --- |
| `RunAttempt` | `id`, `nativeThreadId?`, `runId`, `attemptOrdinal`, `rootNodeId`, `providerInstanceId`, `providerThreadId`, `providerTurnId: NullOr`, `reason`, `status`, `startedAt: NullOr`, `completedAt: NullOr` | `orchestrationV2.ts:597-619` |
| `ExecutionNode` | `id`, `threadId`, `runId: NullOr`, `parentNodeId: NullOr`, `rootNodeId`, `kind` (`root_turn`, `assistant_message`, `reasoning`, `plan`, `todo_list`, `tool_call`, `approval_request`, `user_input_request`, `subagent`, `hook`, `system`), `status`, `countsForRun`, `providerThreadId`, `providerTurnId`, `nativeItemRef`, `runtimeRequestId`, `checkpointScopeId`, `startedAt`, `completedAt` (all `NullOr` except the first five and `countsForRun`) | `orchestrationV2.ts:622-660` |
| `ProviderSession` | `id`, `driver`, `providerInstanceId`, `status` (`starting`, `ready`, `running`, `waiting`, `stopped`, `error`), `cwd`, `model`, `capabilities`, `createdAt`, `updatedAt`, `lastError` | `orchestrationV2.ts:726-737`; capabilities `:193-336` |
| `ProviderThread` | `id`, `driver`, `providerInstanceId`, `providerSessionId`, `appThreadId`, `ownerNodeId`, `nativeThreadRef`, `nativeConversationHeadRef`, `status` (`not_loaded`, `idle`, `active`, `archived`, `closed`, `error`), `firstRunOrdinal`, `lastRunOrdinal`, `handoffIds`, `forkedFrom`, `pendingBackgroundTasks`, `contextUsage`, `nativeMetadata`, `goal`, `createdAt`, `updatedAt` | `orchestrationV2.ts:871-907` |
| `ProviderTurn` | `id`, `providerThreadId`, `nodeId`, `runAttemptId`, `nativeTurnRef`, `ordinal`, `status` (`pending`, `running`, `completed`, `interrupted`, `failed`, `cancelled`), `startedAt`, `completedAt`, `tokenUsage?` `{usedTokens, maxTokens?, inputTokens?, cachedInputTokens?, outputTokens?, reasoningOutputTokens?, updatedAt}`, `turnTokenUsage?`. Recorded `tokenUsage`: `{"cachedInputTokens":37193,"inputTokens":39596,"maxTokens":1000000,"outputTokens":6,"reasoningOutputTokens":0,"usedTokens":39602,"updatedAt":"..."}` (`03-turn2` t=9313) | `orchestrationV2.ts:984-1003` |
| `RuntimeRequest` | `id`, `nodeId`, `providerTurnId`, `nativeRequestRef`, `kind` (`ProviderRequestKind` or `dynamic_tool_call`, `user_input`, `auth_refresh`), `status`, `responseCapability` (`{type:"live",providerSessionId}` or `{type:"message"}` or `{type:"not_resumable",reason}`), `createdAt`, `resolvedAt`, `decision?`, `answers?` | `orchestrationV2.ts:1025-1044` |
| `ConversationMessage` | `id`, `threadId`, `runId`, `nodeId`, `role` (`user`, `assistant`, `system`), `text`, `attachments: ChatAttachment[]`, `streaming`, `createdAt`, `updatedAt`, `createdBy`, `creationSource`, optional `notification`, `scheduledTaskId`, `senderThreadId`, `context`, `delegatedCompletion` | `orchestrationV2.ts:1113-1137` |
| `PlanArtifact` | base `{id, threadId, runId, nodeId, status: draft\|active\|completed\|superseded}` plus `kind:"proposed_plan"` `{markdown}` or `kind:"todo_list"` `{steps:[{id,text,status:pending\|running\|completed,durationAnchorAt?,durationMs?}], explanation?}` | `orchestrationV2.ts:1170-1191`, `:1140-1148` |
| `CheckpointScope` | `id`, `threadId`, `runId`, `nodeId`, `parentScopeId`, `providerThreadId`, `kind` (`root_run`, `subagent`, `tool`, `provider_thread`, `manual`), `ordinalWithinParent`, `advancesAppRunCount`, `cwd`, `createdAt` | `orchestrationV2.ts:711-723` |
| `Checkpoint` | `id`, `threadId`, `scopeId`, `runId`, `nodeId`, `parentCheckpointId`, `ordinalWithinScope`, `appRunOrdinal`, `ref` (hidden git ref, `refs/t3/orchestration-v2/checkpoints/<b64>/ordinal/<n>`), `status` (`ready`, `missing`, `error`, `stale`), `files: [{path, kind, additions, deletions}]`, `capturedAt` | `orchestrationV2.ts:1202-1215`, `03-turn2` t=13673 |
| `ProviderRef` | `{driver, nativeId: string\|null, strength: strong\|weak\|none, fingerprint?, ordinal?}` | `orchestrationV2.ts:99-105` |

#### Thread projection (full read model)

`OrchestrationV2ThreadProjection` (`orchestrationV2.ts:1785-1810`): `{thread, runs, attempts, nodes, subagents, providerSessions, providerThreads, providerTurns, runtimeRequests, messages, plans, turnItems, checkpointScopes, checkpoints, contextHandoffs, contextTransfers, visibleTurnItems, updatedAt}`. All array keys are required. `03-turn2` t=38931 shows a real bounded snapshot with `turnItems: []` (compact form) and `visibleTurnItems` of 19 rows.

`ProjectedTurnItem` (`orchestrationV2.ts:1610-1616`): `{position: NonNegativeInt, visibility: "local"|"inherited"|"synthetic", sourceThreadId, sourceItemId, item}`. `visibleTurnItems` is the ordered read model the UI renders: inherited fork-source rows, synthetic markers, then local rows.

### 7.2 Command dispatch mechanics

Request: `orchestration.dispatchCommand` with an `OrchestrationV2Command` payload (union on `type`). Scope `orchestration:operate`. Success: `{"sequence": <NonNegativeInt>}`, the sequence of the last event the command committed (`orchestrationV2.ts:3212-3214`).

Server path (`apps/server/src/ws.ts:1818-1867`, `docs/research/B-orchestration.md` section 2.1):

1. For `thread.create`, `message.dispatch`, `thread.fork`, `thread.merge_back`, `delegated_task.request` the server **forces `createdBy: "user"`** and keeps `creationSource`. The client must still send both fields; the schema requires them (`apps/server/src/orchestration-v2/ThreadManagementService.ts:52-66`). Official web and desktop send `"web"`, mobile sends `"mobile"`. There is no `"desktop"` literal. A native client sends `"web"` (**UNVERIFIED** as a product decision; any value outside `web|mobile|mcp|provider|server` fails decode). The recordings used `"web"`.
2. `message.dispatch`, `queued-run.edit` and `runtime-request.respond` with attachments first have their pending uploads claimed (limits: 100 attachments, 80 MiB images, no duplicate ids) (`apps/server/src/orchestration-v2/ThreadMessageIntake.ts:53-165`).
3. The orchestrator takes a **per-thread lock**. Commands for one thread are serialized; different threads run concurrently (`apps/server/src/orchestration-v2/Orchestrator.ts:10627-10628`).
4. Decide, commit events and projections and a command receipt in one transaction. **Acceptance means the intent committed, not that provider work finished** (`docs/internals/overview.md:63-67`).

Idempotency (`Orchestrator.ts:10421-10625`):

| Situation | Result |
| --- | --- |
| New `commandId` | decide and commit; receipt `accepted` with `resultSequence` |
| Same `commandId`, accepted receipt, same thread | **replay**: returns the original `{sequence}`; the payload is not compared |
| Same `commandId`, receipt for another thread | `OrchestratorCommandIdConflictError` |
| Same `commandId`, receipt `rejected` | `OrchestratorCommandPreviouslyRejectedError` with the stored reason |
| Decide fails | a rejected receipt is stored and the error returned. Retrying with the same `commandId` keeps failing: mint a new `commandId` for a deliberate retry |
| Decide produces no events | rejected with `Command produced no domain events.` |
| `OrchestratorThreadAboveModeLimitError` | refused without a receipt |

Client rules: fresh UUID `commandId` per user action, reused only to retry the same action after a transport failure. The official runtime does not auto-replay mutations on reconnect (`docs/internals/connection-runtime.md:82-87`). Use the returned `sequence` to know when your own result is visible: the official optimistic layer keeps a pending patch until the shell `snapshotSequence >= sequence` (`packages/client-runtime/src/state/threadLifecycle.ts:51-98`).

Errors: `OrchestrationV2DispatchCommandError {_tag, commandId, commandType, message, detail?, cause?}` (`orchestrationV2.ts:3395-3404`). `message` is the innermost useful message (for example `Run run:... is not interruptible.`, `Thread <id> is archived.`), a friendly capability text (`"<Provider> cannot queue messages behind an active run."`, `"<Provider> cannot redirect an active run. Stop it first, then send the message."`, `"<Provider> cannot stop a run once it has started."`, `"<Provider> cannot rewind its conversation, so this checkpoint cannot be restored on this thread."`), or `"Failed to dispatch orchestration V2 command"` (`apps/server/src/orchestration-v2/UserFacingErrors.ts:4-110`). A payload that does not match the union never reaches the orchestrator: the request fails with a `Die` carrying the schema issue.

### 7.3 Client commands

All fields are required unless marked `?`. Every command has `commandId` (CommandId) and `type`. Commands that create content also carry the creation fields `createdBy` and `creationSource`, listed explicitly below. Source: `orchestrationV2.ts:2611-3054`. Recorded commands are marked **(rec)** with the transcript.

**Thread lifecycle and organization**

| `type` | Other fields | Notes |
| --- | --- | --- |
| `thread.create` | `createdBy`, `creationSource`, `threadId`, `projectId`, `title`, `modelSelection`, `runtimeMode`, `interactionMode`, `branch: string\|null`, `worktreePath: string\|null`, `importedNativeThread?` `{ref:{driver,nativeId,strength:"strong"}, metadata?}` | **(rec)** `02-turn` t=1595: `{"branch":null,"commandId":"...","createdBy":"user","creationSource":"web","interactionMode":"default","modelSelection":{"instanceId":"claudeAgent","model":"claude-haiku-5-5"},"projectId":"...","runtimeMode":"approval-required","threadId":"...","title":"New thread","type":"thread.create","worktreePath":null}`. Result `{sequence:2}`; the shell then shows the thread with `status:"idle"` |
| `thread.archive`, `thread.unarchive`, `thread.delete` | `threadId` | archive removes the row from the active shell (`thread.removed`) |
| `thread.settle` | `threadId`, `settledAt?` (DateTimeUtc) | needs `threadSettlement` |
| `thread.unsettle` | `threadId`, `reason: "user"` | |
| `thread.snooze` | `threadId`, `snoozedUntil` (IsoDateTime) | needs `threadSnooze` |
| `thread.unsnooze` | `threadId`, `reason: "user"` | |
| `thread.auto-settle.set` | `threadId`, `enabled: bool` | `threadAutoSettleOptOut` |
| `thread.pin` | `threadId`, `orderKey?` | `threadPinning` |
| `thread.unpin` | `threadId` | |
| `thread.pin.reorder`, `thread.active.reorder` | `threadId`, `orderKey` | fractional-index key (section 7.9) |
| `thread.visit` | `threadId`, `visitedAt` (IsoDateTime) | server keeps `max(stored, visitedAt)`; does not change `updatedAt` |
| `thread.mark-unread` | `threadId` | rewinds the read receipt |
| `thread.metadata.update` | `threadId`, `title?`, `regenerateTitle?: bool`, `branch?: string\|null`, `worktreePath?: string\|null`, `expectedWorktreePath?: string\|null`, `expectedEmpty?: bool`, `limitRecovery?: {runId, resetAt, autoResume?, snooze?}\|null` (at least one of `autoResume`, `snooze`), `linkedPullRequest?: ThreadLinkedPullRequest\|null` | |
| `thread.runtime-mode.set` | `threadId`, `runtimeMode` | |
| `thread.interaction-mode.set` | `threadId`, `interactionMode` | |
| `thread.model-selection.set` | `threadId`, `modelSelection` | |
| `provider.switch` | `threadId`, `modelSelection` | switch provider with context handoff |
| `provider-session.detach` | `threadId`, `providerSessionId`, `reason?` | |
| `thread.fork` | `createdBy`, `creationSource`, `sourceThreadId`, `targetThreadId`, `sourcePoint`, `title?`, `createdAt?` | `sourcePoint`: `{type:"latest_stable"}`, `{type:"run",runId}`, `{type:"checkpoint",checkpointId}` (`orchestrationV2.ts:134-138`) |
| `thread.merge_back` | `createdBy`, `creationSource`, `sourceThreadId`, `targetThreadId`, `sourcePoint`, `createdAt?` | |
| `thread.user-input.dismiss` | `threadId`, `requestId` (RuntimeRequestId) | dismiss a question |

**Pull-request links** (`ThreadPullRequestKey` = `{host, repository, number}`; `source` = `manual`, `created`, `agent`, `stack`, `stack-dismissed`; `threadPullRequestLinking`)

| `type` | Other fields |
| --- | --- |
| `thread.pull-request.link` | `threadId`, `host`, `repository`, `number`, `url`, `source` |
| `thread.pull-request.unlink` | `threadId`, `host`, `repository`, `number` |
| `thread.pull-request.watch` | `threadId`, `host`, `repository`, `number`, `watching: bool`, `link?: {url, source}` |
| `thread.pull-request-link.sync` | `threadId`, key fields, `snapshot: ThreadPullRequestSnapshot`, `stack: ThreadPullRequestStack\|null` |
| `thread.pull-request.sync` | `threadId`, `projectId`, `snapshotSequence`, `expected{workspaceRoot, branch, worktreePath, linkedPullRequest, branchPullRequest}`, `branchPullRequest`, `linkedPullRequest?` |
| `thread.title.regeneration.complete` | `threadId`, `requestId`, `title?` |

**Messages, runs and queue**

| `type` | Other fields | Notes |
| --- | --- | --- |
| `message.dispatch` | `createdBy`, `creationSource`, `threadId`, `messageId`, `text`, `attachments: ChatAttachment[]` (may be empty), `dispatchMode`, `titleSeed?`, `modelSelection?`, `context?`, `deliveryIntent?` (`auto`, `steer`, `restart`), `notification?`, `scheduledTaskId?`, `senderThreadId?`, `sourcePlanRef?` `{threadId,planId}`, `restartContinuationOfRunId?`, `usageLimitContinuationOfRunId?`, `manualContinuationOfRunId?`, `usageLimitRecoveryRequestId?`, `delegatedCompletion?` | `dispatchMode` below. **(rec)** `02-turn` t=2625: `{"attachments":[],"commandId":"...","createdBy":"user","creationSource":"web","dispatchMode":{"type":"start_immediately"},"messageId":"...","text":"Use your shell tool ...","threadId":"...","titleSeed":"Count files","type":"message.dispatch"}`. `titleSeed` made the server generate the title "Count files" later (`thread.metadata-updated`, `02-turn` t=8683) |
| `run.interrupt` | `threadId`, `runId`, `reason?`, `holdQueue?: bool` | **(rec)** `02-turn` t=128602 with `holdQueue:true`. Errors if the run is not interruptible (`03-turn2` t=35818) |
| `queued-run.cancel` | `threadId`, `runId` | **(rec)** `02-turn` t=127087 |
| `queued-run.edit` | `threadId`, `runId`, `text`, `attachments?`, `context?` | |
| `queued-run.reorder` | `threadId`, `runId`, `beforeRunId: RunId\|null` | |
| `queued-message.promote-to-steer` | `threadId`, `queuedRunId`, `targetRunId` | |
| `queue.resume` | `threadId` | after restart recovery held the queue |
| `runtime-request.respond` | `threadId`, `requestId` (RuntimeRequestId), `decision?` (ProviderApprovalDecision), `answers?` (`Record<string, unknown>`), `attachmentsByQuestionId?` | **(rec)** `03-turn2` t=10938: `{"commandId":"...","decision":"accept","requestId":"runtime-request:provider:claudeAgent:...","threadId":"...","type":"runtime-request.respond"}` |
| `checkpoint.rollback` | `threadId`, `scopeId`, `checkpointId`, `restoreFiles?: bool` | restore to a checkpoint |
| `prepared-run.release`, `prepared-run.retry` | `threadId`, `runId` | deferred/prepared runs (worktree setup) |
| `prepared-run.progress` | `threadId`, `runId`, `phase: "worktree"\|"setup"` | |
| `prepared-run.fail` | `threadId`, `runId`, `failure: ProviderFailure` | |
| `notification.delivery.accept` | `threadId`, `messageId` | |

`dispatchMode` (discriminated on `type`): `start_immediately`; `queue_after_active`; `steer_active` with `targetRunId`; `restart_active` with `targetRunId`; `defer_start` with `workspaceStrategy?` (`{type:"root",branch?}`, `{type:"existing_worktree",worktreePath,branch?}`, `{type:"worktree",baseRef,branch?,startFromOrigin?}`). The server rejects a mode the provider cannot do (capability texts above).

**Delegated tasks and misc**

| `type` | Other fields |
| --- | --- |
| `delegated_task.request` | `createdBy`, `creationSource`, `parentThreadId`, `parentRunId`, `parentNodeId`, `task`, `title?`, `modelSelection`, `runtimeMode`, `interactionMode`, `completionWake?` (`always`, `settled_only`), `createdAt?` |
| `delegated_task.wake-policy` | `parentThreadId`, `taskId`, `completionWake` |
| `delegated_task.completion-delivery.acknowledge` | `parentThreadId`, `taskId`, `observedByRunId: RunId\|null` |
| `delegated_task.completion-delivery.dispose` | `parentThreadId`, `taskId` |
| `thread.created.record` | `parentThreadId`, `parentRunId`, `parentNodeId`, `targetThreadId`, `targetRunId: RunId\|null` |
| `thread.auto-settle` | `threadId`, `snapshotAt`, `settledAt?`. In the union but meant for the server's settlement sweep ("never by clients", `orchestrationV2.ts` comment above the schema). Do not send. |

Server-internal commands are not in the dispatch schema and cannot be sent: `thread.pull-request-watch.sync`, `checkpoint.rollback.fail`, `thread.background-work.settle`, `thread.stop`, `secret_request.record` (`orchestrationV2.ts:3057-3132`).

**Project commands** are not orchestration commands. They use `projects.mutate` (RPC, scope `orchestration:operate`) or `POST /api/projects/mutate`, payload `ProjectMutation` (`packages/contracts/src/project.ts:220-240`):

| `type` | Fields |
| --- | --- |
| `project.create` | `commandId`, `projectId`, `title`, `workspaceRoot`, `createWorkspaceRootIfMissing?`, `defaultModelSelection?: ModelSelection\|null`, `scripts?` |
| `project.update` | `commandId`, `projectId`, `title?`, `workspaceRoot?`, `defaultModelSelection?`, `autoPull?`, `projectIcon?`, `faviconPath?`, `defaultThreadEnvMode?`, `scripts?` |
| `project.delete` | `commandId`, `projectId`, `force?: bool` |

**(rec)** `02-turn` t=569: `{"type":"project.create","projectId":"712011f3-...","title":"demo-repo","workspaceRoot":"/Users/user/sandbox/demo-repo", "commandId": "..."}`; the result is the full `Project` (t=575), the shell stream then sends `project.updated` (seq 1).

**`orchestration.launchThread`** (create a thread and optionally send the first message in one call) input (`orchestrationV2.ts:3182-3203`): `commandId`, `creationSource?`, `threadId?`, `reuseExistingThread?`, `projectId`, `title`, `generateTitle?`, `modelSelection`, `runtimeMode`, `interactionMode`, `workspaceStrategy` (same union as `defer_start`), `initialMessage?` `{messageId?, text, context?, attachments}`. Result `{threadId, projection, resumed}`. Not exercised in the recordings; the recorded client used `thread.create` + `message.dispatch`.

**Attachments in commands** (`ChatAttachment`, `packages/contracts/src/chatAttachment.ts:149-218`): `{type:"image", id, name, mimeType (image/*), sizeBytes (<= 10 MiB), source?}`, `{type:"file", id, name, mimeType, sizeBytes (1 to 50 MiB), source?}`, or an unknown `type` with `{id, name, mimeType, sizeBytes}` (forward compatible). `id` is the `attachmentId` from `attachments.createUploadUrl` (section 5.3).

### 7.4 Domain events

Every committed event has a store-assigned, strictly increasing `sequence` (global across threads and projects). Thread stream envelope: `{"kind":"event","sequence":N,"event":DomainEvent}` (`orchestrationV2.ts:3366-3392`). Persisted form `OrchestrationV2StoredEvent = {sequence, commandId|null, event}` (`:1984-1988`).

**Event base** (`orchestrationV2.ts:1634-1643`): `{id: EventId, type, threadId, runId?, nodeId?, driver?, providerInstanceId?, rawEventId?, occurredAt, payload}`. Recorded envelope (`02-turn` t=4208): `{"driver":"claudeAgent","id":"event:thread:...:provider-session:...:1c62723d-...","nodeId":"node:provider:claudeAgent:native-item:toolu_...","occurredAt":"2026-10-09T09:12:50.272Z","payload":{...},"providerInstanceId":"claudeAgent","runId":"run:thread:...:ordinal:1","threadId":"...","type":"turn-item.updated"}`.

**Every event carries the full current entity as `payload`** (replace semantics, not a patch):

| `type` | `payload` | Line |
| --- | --- | --- |
| `thread.created` | AppThread | 1646 |
| `thread.archived`, `thread.unarchived`, `thread.deleted`, `thread.settled`, `thread.unsettled`, `thread.snoozed`, `thread.unsnoozed`, `thread.pinned`, `thread.auto-settle-set`, `thread.unpinned`, `thread.pin-reordered`, `thread.active-reordered`, `thread.visited`, `thread.marked-unread`, `thread.metadata-updated`, `thread.pull-request-synced`, `thread.runtime-mode-updated`, `thread.interaction-mode-updated`, `thread.model-selection-updated`, `thread.provider-switched` | AppThread | 1651-1676 |
| `run.created`, `run.updated` | Run | 1677-1686 |
| `run.background-work-cancelled` | `{runId, restartCancelledBackgroundWork[]}` | 1687 |
| `run-attempt.created`, `run-attempt.updated` | RunAttempt | 1692-1701 |
| `node.updated` | ExecutionNode | 1702 |
| `subagent.updated` | Subagent | 1707 |
| `provider-session.attached`, `provider-session.updated` | ProviderSession | 1712-1716 |
| `provider-session.detached` | `{providerSessionId, detachedAt, reason?}` | 1717 |
| `provider-thread.updated` | ProviderThread | 1722 |
| `provider-turn.updated` | ProviderTurn | 1727 |
| `runtime-request.updated` | RuntimeRequest | 1732 |
| `message.updated` | ConversationMessage | 1737 |
| `turn-item.updated` | TurnItem | 1742 |
| `plan.updated` | PlanArtifact | 1747 |
| `checkpoint-scope.created` | CheckpointScope | 1752 |
| `checkpoint.captured` | Checkpoint | 1757 |
| `checkpoint.rollback-requested` | `{scopeId, checkpointId, requestedAt}` | 1762 |
| `context-handoff.updated` | ContextHandoff | 1767 |
| `context-transfer.created`, `context-transfer.updated` | ContextTransfer | 1772-1781 |

Recorded types in `02-turn`/`03-turn2`: `thread.metadata-updated`, `provider-thread.updated`, `run.created`, `run-attempt.created`, `node.updated`, `checkpoint-scope.created`, `message.updated`, `turn-item.updated`, `provider-session.attached`, `provider-session.updated`, `run.updated`, `run-attempt.updated`, `provider-turn.updated`, `runtime-request.updated`, `checkpoint.captured`. Project events are not in this union; they reach the client as shell `project.updated` and `project.removed`.

### 7.5 Turn items

Union on `type` (`orchestrationV2.ts:1372-1577`). Base fields on every item (`orchestrationV2.ts:1316-1335`): `id`, `threadId`, `runId: NullOr`, `nodeId: NullOr`, `providerThreadId: NullOr`, `providerTurnId: NullOr`, `nativeItemRef: NullOr<ProviderRef>`, `parentItemId: NullOr`, `ordinal: NonNegativeInt`, `status`, `title: NullOr<string>`, `startedAt: NullOr`, `completedAt: NullOr`, `updatedAt`; optional `toolNonExecutionKind`, `toolSurface`, `toolIcon`, `toolSource`.

| `type` | Extra fields |
| --- | --- |
| `user_message` | `createdBy`, `creationSource`, `messageId`, `inputIntent`, `text`, `attachments[]`, optional `scheduledTaskId`, `senderThreadId`, `context` |
| `assistant_message` | `messageId`, `text`, `streaming`, optional `attachments` |
| `reasoning` | `text`, `streaming` |
| `proposed_plan` | `planId`, `markdown`, `streaming` |
| `todo_list` | `planId`, `steps[]`, `explanation?` |
| `user_input_request` | `requestId`, `questions[]` `{id, header, question, options:[{label,description,value?}], multiSelect?, allowCustomAnswer?, initialAnswer?, required?}`, `questionAnswer?`, `responseMode?: "message"` |
| `file_change` | `fileName`, `additions?`, `deletions?`, `diffStr?`, `oldStr?`, `newStr?`, `changes?: [{operation, path, oldPath?, fileType?, mimeType?}]` |
| `command_execution` | `input`, `output?`, `outputOmitted?`, `outputIndicatesFailure?`, `exitCode?` |
| `file_search` | `pattern?`, `results?: [{fileName, line?, column?, preview?}]` |
| `web_search` | `patterns?`, `results?: [{title?, url?, snippet?}]` |
| `approval_request` | `requestId`, `requestKind`, `prompt?`, `appName?`, `options?: [{decision, label, warning?}]` |
| `checkpoint` | `checkpointId`, `scopeId`, `files: [{path, kind, additions, deletions}]` |
| `run_interrupt_request` | `message` |
| `run_interrupt_result` | `message` |
| `system_notice` | `message` |
| `error` | `failure: {class, message, code, retryable, resetAt?}`, `retry?: {attempt, maxAttempts, retryDelayMs}` |
| `compaction` | `driver`, `summary?`, `beforeTokenCount?`, `afterTokenCount?` |
| `handoff` | `contextHandoffId`, `fromProviderThreadIds`, `toProviderThreadId`, `fromProviderInstanceIds`, `toProviderInstanceId`, `fromModelSelections?`, `toModel?`, `strategy`, `summary?` |
| `fork` | `source` (`{type:"run"...}` etc.), `targetThreadId`, `providerThreadId?` |
| `thread_created` | `targetThreadId`, `targetRunId`, `targetProviderInstanceId`, `targetModel` |
| `secret_request` | `label`, `reason`, `placeholder?`, `secretStatus` (`pending`, `saved`, `declined`, `cancelled`); the value never travels |
| `subagent` | `subagentId`, `origin`, `driver`, `providerInstanceId`, `childThreadId`, `prompt`, `progress?`, `result` |
| `dynamic_tool` | `toolName`, `viewedImagePath?`, `input`, `output?`, `outputOmitted?` |
| `notification` | `source`, `outcome`, `summary`, `detail?` |

Lines: `orchestrationV2.ts:1373-1576`. Details of per-type fields: `docs/research/B-orchestration.md` section 1.10. Unknown `type` values are dropped (section 1.4).

**Wire projection (what the server strips before sending).** Every snapshot, replayed event and live event passes through `apps/server/src/orchestration-v2/WireProjection.ts:210-241`:

| Item | On the wire | Source |
| --- | --- | --- |
| `command_execution` | `output` removed; `outputOmitted: true` when there was output; `outputIndicatesFailure: true` when flagged, non-zero exit or failure-looking. **Recorded**: completed item has `input`, `outputOmitted:true`, no `output` (`02-turn` t=4208). | `WireProjection.ts:82-96` |
| `file_change` | `diffStr`, `oldStr`, `newStr` removed (fetch via `getTurnDiff`/`getFullThreadDiff`); a failed edit keeps `diffStr` truncated to 32 KiB | `WireProjection.ts:97-105` |
| `dynamic_tool` | `input` kept if <= 16 KiB JSON else `{summary, truncated:true}`; `output` compacted; `outputOmitted: true` | `WireProjection.ts:37-74`, `:113-122` |
| `subagent` | `prompt`, `progress`, `result` truncated to 32 KiB with suffix `"\n… output truncated for transport"` | `WireProjection.ts:14-35` |
| `handoff` | `summary` removed | `WireProjection.ts:78-81` |
| `ContextHandoff` | `history` and `delivery` removed, `summaryText: ""` | `WireProjection.ts:203-208` |

Full bodies come from `orchestration.getTurnItem {threadId, itemId, revision?}` → `{item: TurnItem|null}` (inputs and outputs bounded to 256 KiB; tool-output images served as `tool-output-image` assets) (`WireProjection.ts:150-201`, `orchestrationV2.ts:3458-3470`).

### 7.6 Shell stream: `orchestration.subscribeShell`

Input `{afterSequence?: NonNegativeInt, requestCompletionMarker?: boolean}` (`orchestrationV2.ts:3223-3235`). Recorded: `{"requestCompletionMarker":true}` (`01-basic` t=31).

Stream items (`orchestrationV2.ts:1945-1981`), discriminated by `kind`:

```jsonc
{ "kind": "snapshot", "snapshot": ShellSnapshot, "resolvedRepositoryIdentityRoots": ["/abs/root"] }   // roots key absent on authoritative snapshots
{ "kind": "synchronized" }                                    // only if requested
{ "kind": "project.updated", "sequence": 1, "project": ProjectShell }
{ "kind": "project.removed", "sequence": 9, "projectId": "..." }
{ "kind": "thread.updated", "sequence": 16, "location": "active", "thread": ThreadShell }
{ "kind": "thread.removed", "sequence": 20, "location": "active", "threadId": "..." }
```

`ShellSnapshot = {schemaVersion: PositiveInt, snapshotSequence: NonNegativeInt, threads: ThreadShell[], archivedThreads: ThreadShell[], projects: ProjectShell[]}` (`orchestrationV2.ts:1931-1942`). The active snapshot always has `archivedThreads: []` (`apps/server/src/orchestration-v2/ShellStream.ts:21-34`). Recorded empty server (`01-basic` t=37): `{"kind":"snapshot","snapshot":{"archivedThreads":[],"projects":[],"schemaVersion":2,"snapshotSequence":0,"threads":[]}}`, then `{"kind":"synchronized"}` (t=39).

Server behavior (`apps/server/src/ws.ts:943-1177`):

1. **No `afterSequence`**: authoritative `snapshot`, optionally a second same-sequence enrichment `snapshot` (only projects whose repository identity resolved, `threads: []`, with `resolvedRepositoryIdentityRoots`), then `synchronized` if requested, then live deltas after `snapshotSequence`. Recorded: after `project.create` the server sent exactly such an enrichment snapshot (`02-turn` t=616: `resolvedRepositoryIdentityRoots:["/Users/user/sandbox/demo-repo"]`, `snapshotSequence:1`).
2. **With `afterSequence`**: if `head - afterSequence` is negative or over `SHELL_RESUME_MAX_GAP = 1000`, or the stored payload bytes in the range exceed 8 MiB, it falls back to case 1 (`ws.ts:546-555`, `:686-713`). Otherwise it emits enrichment snapshots, replayed deltas for `(afterSequence, head]`, `synchronized`, then live deltas.
3. Enrichment refreshes can come at any time: a `snapshot` with `threads: []`, `archivedThreads: []`, only changed `projects` and `resolvedRepositoryIdentityRoots`. **Treat a snapshot that carries `resolvedRepositoryIdentityRoots` as a project-metadata patch, not a replacement of the thread list.**
4. Deltas are coalesced: within a 50 ms / 512-event window only the newest event per project or thread survives (`ShellStream.ts:85-100`). For a thread event the server re-reads the current shell and emits `thread.updated` (or `thread.removed` if archived or gone) with the sequence of the newest coalesced event. An unchanged shell (ignoring `updatedAt`) is suppressed unless the last send is 5 s old (`ShellStream.ts:224-273`).
5. `sequence` values are global application sequences: strictly increasing within a subscription, with gaps. **Gaps are normal.** Resume cursor is `max(sequence seen)`. The cursor can lag the head by up to about 5 s of suppressed deltas; resume replays them harmlessly.
6. Overflow fails the stream with `OrchestrationV2GetShellSnapshotError {message: "Failed while streaming the application shell"}` (`ws.ts:1171-1180`). Resubscribe with `afterSequence`.

HTTP alternative for first load: `GET /api/orchestration/shell` (section 5). Then subscribe with `afterSequence = snapshotSequence`.

**Archived shell.** `orchestration.subscribeArchivedShell` (input `{}`) always starts with a full snapshot `{kind:"snapshot", snapshot:{schemaVersion, snapshotSequence, projects[], threads[]}}`, then `{kind:"thread.updated", sequence, thread}` and `{kind:"thread.removed", sequence, threadId}` (no `location`) (`orchestrationV2.ts:3155-3180`, `ws.ts:1774-1806`). `getArchivedShellSnapshot` returns the snapshot once.

### 7.7 Thread stream: `orchestration.subscribeThread`

Input (`orchestrationV2.ts:3238-3257`; all `optionalKey` except `threadId`):

```json
{"threadId":"c4ff4c86-...","afterSequence":5,"requestCompletionMarker":true,"acceptBoundedSnapshot":true,"acceptCompactTurnItems":true}
```

Recorded first open (`02-turn` t=2099): `{"acceptBoundedSnapshot":true,"acceptCompactTurnItems":true,"requestCompletionMarker":true,"threadId":"..."}`.

Stream items (`orchestrationV2.ts:3366-3392`):

```jsonc
{ "kind": "synchronized" }
{ "kind": "snapshot", "snapshotSequence": 198, "projection": ThreadProjection,
  "historyCursor": "opaque" | null, "hasMoreHistory": false, "latestLocalTurnOrdinal": 3000004 | null,
  "payloadBudgetExceeded": false, "turnItemsOmitLocalVisible": true }   // the 5 extra keys are optionalKey
{ "kind": "event", "sequence": 1240, "event": DomainEvent }
```

Recorded bounded snapshot (`03-turn2` t=38931, resume with a stale `afterSequence: 5`): `{'hasMoreHistory': False, 'historyCursor': None, 'kind': 'snapshot', 'latestLocalTurnOrdinal': 3000004, 'payloadBudgetExceeded': False, 'projection': {...}, 'snapshotSequence': 198, 'turnItemsOmitLocalVisible': True}`; `projection.turnItems` was empty and `visibleTurnItems` had 19 rows.

Server behavior (`apps/server/src/ws.ts:747-940`):

1. **No `afterSequence`** → `snapshotThenLive`: with `acceptBoundedSnapshot: true`, a bounded window (`THREAD_HISTORY_SNAPSHOT_ROW_LIMIT = 75 + 2` rows, `userTurnLimit = 10`, about 1 MiB of encoded data) plus history metadata; otherwise a legacy full snapshot without history keys. Then `synchronized` (if requested), then live events with `sequence > snapshotSequence`. Recorded: snapshot at t=2114, `synchronized` at t=2115 (`02-turn`).
2. **With `afterSequence`** (`ws.ts:869-937`): replay stored events `(afterSequence, highWater]` when all hold: `afterSequence <= highWater`, at most `THREAD_RESUME_MAX_REPLAY_EVENTS = 128` events, at most 1 MiB of stored payload, the range does not contain the thread's create event of a still-existing thread, and the wire-projected replay is under 1 MiB. Then `synchronized`, then live. **Otherwise it answers with a `snapshot` item.** The client must accept either, and treat a `snapshot` as a full reset at `snapshotSequence`.
3. Live events pass through a coalescer: a `turn-item.updated` with `status:"running"` and `type` in `command_execution`, `file_change`, `file_search`, `web_search`, `dynamic_tool` is held for 50 ms (max 512 pending) and only the latest update per item survives. Every other event (including terminal updates, assistant text and run updates) flushes the window and is never dropped (`ThreadLiveEventCoalescer.ts:18-191`). Replayed events are not coalesced.
4. Several events arrive in one `Chunk.values` array. Recorded: up to 10 per chunk (`02-turn`). Process values in order.
5. Errors are `OrchestrationV2GetThreadProjectionError {threadId, message, cause?}`.

**Sequence semantics.** `sequence` is the store-wide event sequence (shared with other threads), so a thread's events have gaps. Never treat a gap as loss. Dedupe with `sequence <= lastApplied` and keep `lastApplied = max(sequence)`, including unknown events.

**Bounded snapshots over HTTP.** `GET /api/orchestration/threads/:threadId/bounded[?compactTurnItems=1]` returns the same shape without the `kind`: `{snapshotSequence, projection, historyCursor, hasMoreHistory, latestLocalTurnOrdinal, payloadBudgetExceeded?, turnItemsOmitLocalVisible?}` (`orchestrationV2.ts:3278-3302`). Then subscribe with `afterSequence = snapshotSequence`.

**Correction (recovered `server-streams.md`):** the contract comment on `OrchestrationV2ThreadBoundedSnapshot` says "full control-plane projection arrays". In practice the server windows those arrays too. Treat every array in a bounded projection as partial, and merge older pages with the history endpoint. Optional fields can also arrive as `null` on the JSON wire, so decoders must accept `null` wherever a field is optional.

**Compact form.** When `turnItemsOmitLocalVisible` is true, `projection.turnItems` omits the leading entries that duplicate local visible rows. Restore: `turnItems = visibleTurnItems.filter(isLocal).map(row => row.item) + turnItems`, where `isLocal(row) = row.visibility == "local" || row.sourceThreadId == projection.thread.id` (`packages/shared/src/orchestrationV2BoundedSnapshot.ts:6-58`). A native client can ignore `turnItems` entirely and render `visibleTurnItems`.

**History paging.** `GET /api/orchestration/threads/:threadId/history?cursor=<historyCursor>[&throughEntryId=<id>][&view=conversation|activity]` → `{snapshotSequence, items: ProjectedTurnItem[] (oldest first), nextCursor: string|null, hasMoreHistory}` (`orchestrationV2.ts:3305-3317`). The cursor is opaque (server-side base64url JSON, max 4096 chars; malformed → 400 `invalid_history_cursor`). Older pages hold up to 20 user turns (`threadHistoryPaging.ts:19`). `view=conversation` excludes `command_execution`, `reasoning`, `file_change`, `dynamic_tool` rows (`:22-25`); the official client uses it only to jump to an entry. Show "load earlier" when `hasMoreHistory || error`. Discard a page response if the cursor changed while it was in flight (`packages/client-runtime/src/state/threadHistoryMerge.ts:30-36`).

**Merge rule for older pages** (`threadHistoryMerge.ts:62-149`): dedupe by `sourceThreadId:sourceItemId`; rows already present keep their live values; prepend page rows in server order; renumber `position` 0..n-1; set history meta to `{historyCursor: page.nextCursor, hasMoreHistory: page.hasMoreHistory}`, keeping `latestLocalTurnOrdinal`.

**Streaming assistant text.** There are **no text deltas on the wire.** Assistant and reasoning text arrive as repeated `turn-item.updated` events for the same item id with `streaming: true` and `text` equal to the **full text so far**, then a final update with `streaming: false` (`message.updated` repeats this for the ConversationMessage). Replace by id. In the default `responseStreamingMode: "paragraph"` an update is stored at most every 400 ms and cut at a stable markdown boundary (`apps/server/src/orchestration-v2/assistantStreaming.ts:22-129`; `packages/contracts/src/settings.ts:992-999`). In mode `"turn"` only the final text is stored. **Recorded** (`03-turn2`): the Claude provider emitted assistant text only as one final item (`streaming:false`, for example 2919 characters at t=34706). Reasoning streamed as full-text snapshots with `streaming:true` (312 chars at t=25348, 633 at t=29167, 1487 final at t=34610).

### 7.8 Reducer rules

For both streams (`packages/client-runtime/src/state/shellReducer.ts`, `threads.ts`, `orchestrationV2Projection.ts`).

**Shell**

- Authoritative `snapshot` (no `resolvedRepositoryIdentityRoots`): replace projects, threads, `snapshotSequence`, even if lower. Keep a previously resolved non-null `repositoryIdentity` for a project with the same `workspaceRoot` while the new one is null (`shellReducer.ts:79-133`).
- Enrichment `snapshot`: patch only `repositoryIdentity` of existing projects with matching `id` and `workspaceRoot`. Roots listed accept the identity exactly, including `null`. Never touch threads or sequence (`shellReducer.ts:99-120`).
- Deltas: ignore if `event.sequence <= snapshotSequence`. `project.updated`: upsert by id. `project.removed`: remove. `thread.updated` with `location:"active"`: upsert by id and remove from `archivedThreads`. `thread.removed`: remove from both lists. Every applied delta sets `snapshotSequence = event.sequence` (`shellReducer.ts:135-200`).

**Thread**

- Items apply in arrival order under one lock. `event` and `unknown-event` items with `sequence <= lastSequence` are skipped; otherwise they advance `lastSequence` (`threads.ts:444-468`).
- `snapshot`: `lastSequence = snapshotSequence`; replace the projection; reset history metadata (`threads.ts:584-611`).
- `synchronized`: status becomes `live` (`threads.ts:571-582`).
- `thread.deleted` marks the thread deleted and stops applying (`threads.ts:486-497`).
- Event application (ignores events for another `threadId`; `updatedAt := event.occurredAt` for everything except `thread.visited` and `thread.marked-unread`):
  - every `thread.*` event: `projection.thread = payload`.
  - `run.created|updated`, `run-attempt.*`: upsert by id, recompute visibility.
  - `node.updated`, `subagent.updated`, `provider-thread.updated`, `runtime-request.updated`, `message.updated`, `plan.updated`, `checkpoint-scope.created`, `checkpoint.captured`, `context-*`: upsert by `id`, replacing the whole object.
  - `provider-session.attached|updated`: upsert; `provider-session.detached`: remove.
  - `provider-turn.updated`: upsert, but keep the previous `tokenUsage` when the new payload omits it.
  - `run.background-work-cancelled`: set that run's `restartCancelledBackgroundWork`. `checkpoint.rollback-requested`: only `updatedAt`.
  - `turn-item.updated`: upsert into `turnItems`; if visible, upsert a local row `{visibility:"local", sourceThreadId: item.threadId, sourceItemId: item.id, item}` in `visibleTurnItems` ordered by `(item.ordinal, item.id)` among local rows (inherited rows untouched), else remove its row; renumber positions (`orchestrationV2Projection.ts:152-286`).
  - On a bounded timeline, an update for an item not in the window whose `ordinal <= latestLocalTurnOrdinal` (or older than the oldest local row) is dropped, otherwise the watermark advances (`orchestrationV2Projection.ts:89-106`, `threads.ts:518-527`).
- Visibility (`packages/shared/src/orchestrationV2Timeline.ts:42-112`): hide items of `rolled_back` runs; hide a `user_message` with `inputIntent:"queued_turn"` whose run is `cancelled` (queued input never reached the provider); hide a `run_interrupt_result` on a superseded attempt unless its run has a `run_interrupt_request`. Recorded consistent with this: the queued message in `02-turn` (run ordinal 3) produced a `message.updated` but no `turn-item.updated` before the cancel.

### 7.9 Deriving sidebar state

All inputs are on the thread shell. Official clients never use their own clocks for settlement (`docs/internals/overview.md:87-96`).

**Status pill** (`resolveSidebarThreadStatus`, `apps/web/src/components/Sidebar.logic.ts:983-1013`), first match wins:

1. `pendingRuntimeRequest != null` and `kind` not `user_input` and not `auth_refresh` → `approval`.
2. `pendingRuntimeRequest.kind == "user_input"` → `input`.
3. `runtime.status` in `preparing`, `queued`, `starting`, `running`, `waiting` → `working`.
4. `runtime.status == "idle"` (parked on completion-holding background work) → `waiting`.
5. `runtime.status == "failed"` → `limited` if `lastErrorClass == "usage_limit"`, else `failed`.
6. otherwise → `ready`.

`runtime.status` (`packages/client-runtime/src/state/models.ts:174-199`): `null` when `latestRunId == null && activeProviderThreadId == null` and no completion-holding background work; else `parkAtIdle ? "idle" : (activityRunStatus ?? status)` where `parkAtIdle = backgroundWorkHoldsCompletion(pendingBackgroundTasks) && status != "failed"`. Subagents, monitors and unknown kinds hold completion; `command` does not (`packages/shared/src/orchestrationV2PendingBackgroundWork.ts:62-80`).

Top pill (`resolveSidebarV2TopStatus`, `Sidebar.logic.ts:1015-1039`): `working`, `waiting`, `approval`, `input`, `failed`, `limited`, else `woke` if woken from snooze, else `done` if unread, else none. Label `working` as "Goal" when `goal.status == "active"`. Show the working duration only for `working`, counted from `activityRunStartedAt`, formatted `Ns`, `Nm`, `Nh Mm`.

**Recorded status sequence** for one tool-using turn (`02-turn`, shell `thread.updated` items): `idle` → `running` (seq 16, `activityRunStatus:"running"`) → `waiting` (seq 32) → `completed` (seq 37, `activityRunStatus: null`). The run is `waiting` between the end of the provider turn and checkpoint capture ("a successful turn persists as waiting until checkpoint capture flips it to completed", `packages/shared/src/orchestrationV2PendingBackgroundWork.ts:31-37`), so a thread looks `working` until `completed`. With an approval pending (`03-turn2`) the shell shows `status:"running"` and `pendingRuntimeRequest:{createdAt, id, kind:"file-change"}` (seq 110). After a queued run was cancelled and the active run interrupted, `status` was `cancelled` (seq 59 to 70, `02-turn`): the latest non-held run was the cancelled one. Map `cancelled` and `interrupted` to `ready`.

**Unread.** `hasUnseenCompletion`: `latestRunCompletedAt` parses and `lastVisitedAt` is non-null and `latestRunCompletedAt > lastVisitedAt`. A never-visited thread (`lastVisitedAt == null`) is not unread. If the shell has no `lastVisitedAt` key (old server), use a locally stored watermark (`Sidebar.logic.ts:756-782`). Send `thread.visit {visitedAt: shell.updatedAt}` while a thread is open when `shell.updatedAt > lastVisitedAt`: at once if there is an unseen completion, otherwise at most every 10 s (`apps/web/src/components/ChatView.tsx:622,2938-2998`).

**Sections and order** (`Sidebar.logic.ts:138-147`, `Sidebar.tsx:2793-2848`), first match wins:

1. Snoozed: `threadSnooze` and `snoozedUntil` in the future and the thread has not raised its hand (pending approval or input, a failure newer than `snoozedAt`, a run completed after `snoozedAt`) (`packages/client-runtime/src/state/threadSettled.ts:80-176`).
2. Settled: `threadSettlement` and `settledOverride == "settled"`.
3. Pinned: `pinnedAt != null`.
4. Active.

| Section | Order | Source |
| --- | --- | --- |
| Pinned | threads with `pinOrderKey` first by plain string compare (tie-break id); then keyless threads newest `createdAt` first | `packages/client-runtime/src/state/threadSort.ts:300-338` |
| Active | threads without `activeOrderKey` first, newest anchor first where anchor = `max(createdAt, unsettledAt)`; then keyed threads by string compare. Activity does not reorder. | `threadSort.ts:120-138`, `:340-371` |
| Snoozed | soonest `snoozedUntil` first | `Sidebar.tsx:2874-2880` |
| Settled | newest `settledAt`, else latest of `latestUserMessageAt` and `latestRun*`, else `updatedAt` | `threadSort.ts:23-69` |

Exclude archived threads and threads with `lineage.relationshipToParent == "subagent"` from navigation lists (`threadShell.ts:202-215`). Order keys are fractional-index strings over `a` to `z`, compared with plain `<`; a drag writes one key to one thread (`threadSort.ts:177-301`).

**Relative time.** Row time is `latestUserMessageAt ?? updatedAt`. Format (`apps/web/src/timestampFormat.ts:235-248`): under 60 s or future "just now"; under 60 min `Nm ago`; under 24 h `Nh ago`; else `Nd ago`. The sidebar shortens "just now" to "now" and strips " ago".

**Snooze presets.** In 1 hour, In 3 hours, This evening (18:00, only if more than 1 h away), Tomorrow 09:00, Next week (Monday 09:00) (`threadSettled.ts:229-299`). Cannot snooze with a pending approval or input.

---

## 8. Turn lifecycle as wire sequences

All sequences are from the recordings. `seq` is the thread-stream (or shell-stream) `sequence`. `t` is the recorder's frame time in ms. Request ids are the recorder's. The thread stream is request `4` in `02-turn` and request `3` in `03-turn2`; the shell stream is request `1`. One chunk can hold several events. Fields are trimmed to the ones that matter.

### 8.1 Send a message (start of a turn)

`02-turn`, thread `14fc5e86-...` already subscribed.

| Dir | t | Frame |
| --- | --- | --- |
| C to S | 2625 | `Request id:"5" tag:"orchestration.dispatchCommand"`, payload `{"type":"message.dispatch","commandId":"59daef09-...","createdBy":"user","creationSource":"web","threadId":"14fc5e86-...","messageId":"3f9f5009-...","text":"Use your shell tool to run `ls -1 \| wc -l` ...","attachments":[],"dispatchMode":{"type":"start_immediately"},"titleSeed":"Count files"}` |
| S to C | 2649 | `Exit` request 5: `{"_tag":"Success","value":{"sequence":10}}` |
| S to C | 2660 | thread stream chunk, events 3 to 10: `thread.metadata-updated` (3), `provider-thread.updated` (4, status `not_loaded`), `run.created` (5, `status:"starting"`, id `run:thread:14fc5e86-...:ordinal:1`), `run-attempt.created` (6, `pending`), `node.updated` (7, `root_turn`, `pending`), `checkpoint-scope.created` (8, kind `root_run`), `message.updated` (9, user message, `streaming:false`), `turn-item.updated` (10, `user_message`, `status:"completed"`, `inputIntent:"turn_start"`, ordinal 1000001) |
| S to C | 2661 | events 11 to 16: `provider-session.attached` (11, `ready`), `provider-session.updated` (12), `provider-thread.updated` (13, `active`), `run.updated` (14, `running`), `run-attempt.updated` (15, `running`), `node.updated` (16, root, `running`) |
| S to C | 2700 | shell stream: `thread.updated` seq 16, `status:"running"`, `activityRunStatus:"running"`, `activeRunId` set |
| S to C | 2800 | `provider-turn.updated` (17, `running`, with `tokenUsage`) |

Each chunk is followed by `{"_tag":"Ack","requestId":"4"}` from the client. The `Exit` for the command arrives **before** the events it caused in this recording. Do not rely on either order.

Later (t=8683), the server generates the title from `titleSeed`: `thread.metadata-updated` (38) with the new `title` ("Count files"), and a shell `thread.updated` (38).

### 8.2 Tool call

`02-turn`, a shell command in a thread created with `runtimeMode: "approval-required"`. This read-only `ls` raised no approval request.

| t | seq | Event | Key fields |
| --- | --- | --- | --- |
| 4173 | 18, 19 | `provider-turn.updated`, `node.updated` | node id `node:provider:claudeAgent:native-item:toolu_01Wc...`, `kind:"tool_call"`, `status:"running"` |
| 4208 | 20 | `turn-item.updated` | `type:"command_execution"`, `status:"running"`, `input:"ls -1 \| wc -l"`, `ordinal:1000002` |
| 4208 | 21, 22 | `node.updated`, `turn-item.updated` | `status:"completed"`; the item has `outputOmitted:true` and **no `output`**, `completedAt` set |
| 4727 | 23 to 26 | `provider-turn.updated`, `node.updated` (`assistant_message`, `completed`), `message.updated` (`text:"3"`, `streaming:false`), `turn-item.updated` (`assistant_message`, `text:"3"`) | |

`03-turn2` shows a thinking block (`turn-item.updated` `reasoning`, `streaming:false`, seq 87), a `command_execution` and a `dynamic_tool` (an MCP tool, seq 94 to 96) running in parallel. Tool output is not in the stream; call `orchestration.getTurnItem` when the user expands a tool.

### 8.3 Approval request and response

`03-turn2`, thread `c4ff4c86-...` created with `runtimeMode: "approval-required"`, a file edit requested.

| Dir | t | seq | Frame |
| --- | --- | --- | --- |
| S to C | 9313 | 103 | `node.updated` tool node `toolu_012yt...`, `kind:"tool_call"`, `status:"running"` |
| S to C | 9313 | 104 | `turn-item.updated` `type:"file_change"`, `fileName:"/Users/user/sandbox/demo-repo/notes.md"`, `status:"running"`, ordinal 1000006 |
| S to C | 9313 | 105 | `node.updated` id `node:runtime-request:<requestId>`, `kind:"approval_request"`, `status:"waiting"` |
| S to C | 9313 | 106 | `runtime-request.updated` payload `{id:<requestId>, kind:"file-change", status:"pending", createdAt, resolvedAt:null, nodeId, providerTurnId, nativeRequestRef, responseCapability:{type:"live", providerSessionId}}` |
| S to C | 9313 | 107 | `turn-item.updated` `type:"approval_request"`, `requestId:<requestId>`, `requestKind:"file-change"`, `prompt:"notes.md"`, `status:"waiting"`, ordinal 1000007 |
| S to C | 9356 | shell 110 | `thread.updated`, `status:"running"`, `pendingRuntimeRequest:{createdAt, id:<requestId>, kind:"file-change"}` |
| C to S | 10938 | | `Request id:"5"`, payload `{"type":"runtime-request.respond","commandId":"692daf10-...","threadId":"c4ff4c86-...","requestId":<requestId>,"decision":"accept"}` |
| S to C | 10942 | | `Exit` request 5: `{"sequence":113}` |
| S to C | 10943 | 111 | `runtime-request.updated` `status:"resolved"`, `decision:"accept"`, `resolvedAt` |
| S to C | 10943 | 112, 113 | `node.updated` (approval node `completed`), `turn-item.updated` (`approval_request`, `completed`) |
| S to C | 10952 | 114, 115 | the tool node and its `file_change` item go `completed` |

A second edit then raised a second request the same way (seq 116 to 123). The `requestId` is the full `RuntimeRequestId` string from the `approval_request` turn item or from `pendingRuntimeRequest.id`; echo it exactly.

Notes:

- `responseCapability.type` must be `"live"` for the request to be answerable. A `not_resumable` request (after a server restart) cannot be answered (`orchestrationV2.ts:1025-1044`).
- `decision` values: `accept`, `acceptForSession`, `acceptAlways`, `decline`, `cancel`. The item's `options` array (when present) lists the buttons with labels and optional `warning`.
- Questions (`user_input_request`) are answered with the same command, using `answers` (and `attachmentsByQuestionId`) instead of `decision`. Not recorded.

### 8.4 Completion with a checkpoint

`02-turn` t=4986 onward. After the final assistant message the provider turn ends. The run is **not yet complete**: it passes through `waiting` while the checkpoint is captured.

| t | seq | Event | Key fields |
| --- | --- | --- | --- |
| 4986 | 27 | `provider-turn.updated` | `status:"completed"`, `completedAt` |
| 4986 | 28 | `provider-thread.updated` | `status:"active"` |
| 4987 | 29 | `run-attempt.updated` | `status:"completed"` |
| 4987 | 30 | `run.updated` | `status:"waiting"` |
| 4987 | 31 | `node.updated` | root, `status:"waiting"` |
| 4987 | 32 | `provider-thread.updated` | `status:"idle"` |
| 5033 | shell 32 | `thread.updated` | `status:"waiting"`, `activityRunStatus:"waiting"` |
| 5093 | 33 | `checkpoint.captured` | `...:name:0` baseline, `status:"ready"`, `files:[]` |
| 5093 | 34 | `checkpoint.captured` | `...:name:1`, `status:"ready"`, `appRunOrdinal` set |
| 5093 | 35 | `turn-item.updated` | `type:"checkpoint"`, `checkpointId`, `scopeId`, `files:[{path,kind,additions,deletions}]` (`03-turn2` t=13673 shows `hello.py +1` and `notes.md +3`, both `kind:"modified"`) |
| 5093 | 36 | `run.updated` | `status:"completed"`, `completedAt` |
| 5093 | 37 | `node.updated` | root, `status:"completed"` |
| 5143 | shell 37 | `thread.updated` | `status:"completed"`, `activityRunStatus:null`, `latestRunCompletedAt` set |

Show the thread as done only at the `completed` run status. Fetch the diffs with `orchestration.getTurnDiff {threadId, fromTurnCount, toTurnCount}` and `orchestration.getFullThreadDiff {threadId, toTurnCount}`. Recorded (`03-turn2` t=41003): `{"fromTurnCount":0,"threadId":"c4ff4c86-...","toTurnCount":1}`; the success value is `{"threadId","fromTurnCount","toTurnCount","diff":"diff --git a/hello.py b/hello.py\n..."}` (unified diff text). `vcs.refreshStatus {cwd}` returned `{aheadCount, behindCount, branchChanges:{baseRef,insertions,deletions}, hasPrimaryRemote, hasUpstream, hasWorkingTreeChanges, isDefaultRef, isRepo, pr, refName, workingTree:{files,insertions,deletions}, ...}`.

### 8.5 Interrupt

`02-turn` t=128602. Run 2 (`run:thread:14fc5e86-...:ordinal:2`) was streaming a long answer.

| Dir | t | seq | Frame |
| --- | --- | --- | --- |
| C to S | 128602 | | `{"type":"run.interrupt","commandId":"96...","threadId":"14fc5e86-...","runId":"run:thread:14fc5e86-...:ordinal:2","holdQueue":true}` |
| S to C | 128608 | | `Exit` `{"sequence":60}` |
| S to C | 128608 | 60 | `turn-item.updated` `type:"run_interrupt_request"`, id `turn-item:run:<runId>:signal:interrupt-request`, `message:"Interrupt requested"`, `status:"completed"` |
| S to C | 129034 | 61, 62 | `provider-turn.updated` `status:"interrupted"`; `provider-thread.updated` `idle` |
| S to C | 129037 | 63 to 67 | `run-attempt.updated` (`interrupted`), `turn-item.updated` `type:"run_interrupt_result"` (`title:"Interrupted"`, `message:"Run interrupted by user"`, `status:"interrupted"`, `parentItemId` = the request item), `run.updated` (`interrupted`), `node.updated` (`interrupted`), `provider-thread.updated` |
| S to C | 129136 | 68 to 70 | `checkpoint.captured`, `turn-item.updated` (`checkpoint`), `run.updated` (`interrupted`, final) |

`holdQueue: true` is "set by the Stop button": Stop also holds the queue, ends the thread's pull request watches and stops every delegated task under the thread (comment at `packages/contracts/src/orchestrationV2.ts:2917-2920`). Send it for a user Stop. A held queue is resumed with `queue.resume`; queued runs can also be cancelled one by one. Interrupting a run that is not `preparing`, `starting` or `running` fails with a typed error: `03-turn2` t=35818 sent `run.interrupt` on a completed run and got `OrchestrationV2DispatchCommandError` "... is not interruptible." Only offer Stop while the shell has `activeRunId != null`.

### 8.6 Queue a message, then cancel it

`02-turn` t=125820. While run 2 is starting, the client sent two commands back to back:

| Dir | t | seq | Frame |
| --- | --- | --- | --- |
| C to S | 125820 | | request 6: `message.dispatch`, `dispatchMode:{"type":"start_immediately"}`, text "Without using any tools, write the numbers from 1 to 300 ..." |
| C to S | 125820 | | request 7: `message.dispatch`, `dispatchMode:{"type":"queue_after_active"}`, text "Then say done." |
| S to C | 125841 | | `Exit` 6 `{"sequence":45}`; `Exit` 7 `{"sequence":55}` (t=125861) |
| S to C | 125860 | 39 to 45 | run 2 created (`starting`), its attempt, root node, checkpoint scope, `message.updated`, `turn-item.updated` (`user_message`, `inputIntent:"turn_start"`, ordinal 2000001) |
| S to C | 125862 | 46 to 50 | provider session and thread updated; `run.updated` (`running`) |
| S to C | 125862 | 51 to 54 | `run.created` for ordinal 3: **`status:"queued"`, `queuePosition:1`**, `userMessageId` = "Then say done." message; attempt `pending`; root node `pending`; checkpoint scope |
| S to C | 125862 | 55 | `message.updated` for the queued message (`streaming:false`). **No `user_message` turn item yet.** |
| S to C | 125891 | shell 56 | `thread.updated`, `status:"queued"` (latest run is the queued one), `activeRunId` = run 2, `activityRunStatus:"running"` |
| C to S | 127087 | | `{"type":"queued-run.cancel","commandId":"...","threadId":"14fc5e86-...","runId":"run:thread:14fc5e86-...:ordinal:3"}` |
| S to C | 127096 | | `Exit` `{"sequence":59}` |
| S to C | 127096 | 57 to 59 | `run.updated` ordinal 3: `status:"cancelled"`, `queuePosition:null`, `completedAt`; `run-attempt.updated` (`cancelled`); `node.updated` root (`cancelled`) |
| S to C | 127148 | shell 59 | `thread.updated`, `status:"cancelled"`, `activeRunId` still run 2 |

Find queued messages as runs with `status == "queued"` ordered by `queuePosition`; their text is the message with `id == run.userMessageId` in `projection.messages`. A queued message does not appear as a timeline row until its run starts (and per the visibility rules it stays hidden if the run is cancelled). Related commands: `queued-run.edit`, `queued-run.reorder`, `queued-message.promote-to-steer`, `queue.resume`.

### 8.7 Streaming text

`03-turn2` t=25348 to 34706 (a 600-word story):

- `turn-item.updated` `type:"reasoning"`, id `turn-item:provider:claudeAgent:native-item:msg_...:thinking:0`, `streaming:true`, `status:"running"`, `text` length 312 (seq 181), then 633 (182), then final 1487 with `streaming:false`, `status:"completed"` (183). Each update carries the full text so far.
- The assistant text arrived once: `message.updated` (seq 187) then `turn-item.updated` `assistant_message` `streaming:false`, 2919 characters (seq 188). Claude does not stream assistant text in this build with the default settings; plan the Markdown view around replacing the whole text of an item by id.

### 8.8 Reconnect and resume

`03-turn2` t=38926: after the first subscription, the client re-sent `orchestration.subscribeThread` with `afterSequence: 5` (stale, far behind). The server answered with a bounded `snapshot` (`snapshotSequence: 198`) then `synchronized` (t=38931, 38932), as the resume rules in section 7.7 say, because more than 128 events lay between. A client that resumes with its real last sequence gets replayed `event` items instead, then `synchronized`.

Reconnect recipe:

1. Reopen the socket with a fresh ticket (section 4.4) and resubscribe: shell with `afterSequence = lastShellSequence`, thread with `afterSequence = lastThreadSequence`, both with the completion marker.
2. Accept either replayed events or a snapshot. On `snapshot`, replace state. On `synchronized`, mark the stream live.
3. Do not auto-replay mutations. Retry a `dispatchCommand` only with its original `commandId` (section 7.2).
4. Back off per section 10.8 (`min(300 s, 2^(n+1) s)` ceiling, delay in the upper half).

---

## 9. Other server features

Terminal and git are summarised from `docs/research/D-server-features.md` (sections 1 and 2), which stops after git. For the remaining features D has no text, so each subsection below gives the method names, payload type names, scopes and `rpc.ts` lines from the catalog, plus the field-level facts that could be checked in source or the recordings. Where field lists are missing, the payload type lives in `packages/contracts/src/` under the name shown and has not been summarised (**UNVERIFIED**: field-level shape). Encoding rules for all of them are in section 3.

### 9.1 Terminal

The server owns the PTYs; clients attach over the RPC connection. Terminals belong to a thread; a thread can have several. `terminalId` is chosen by the client; the convention is `term-N` (default `term-1`) (`packages/contracts/src/terminal.ts:5-33`). Sessions are keyed by `(threadId, terminalId)`.

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `terminal.open` | unary | `TerminalOpenInput` | `TerminalSessionSnapshot` | `TerminalError` | `terminal:operate` | 1389 |
| `terminal.attach` | stream | `TerminalAttachInput` | `TerminalAttachStreamEvent` | `TerminalError` | `terminal:operate` | 1395 |
| `terminal.observe` | stream | `TerminalObserveInput` | `TerminalAttachStreamEvent` | `TerminalError` | `terminal:read` | 1402 |
| `terminal.write` | unary | `TerminalWriteInput` | `void` | `TerminalError` | `terminal:operate` | 1409 |
| `terminal.resize` | unary | `TerminalResizeInput` | `void` | `TerminalError` | `terminal:operate` | 1414 |
| `terminal.clear` | unary | `TerminalClearInput` | `void` | `TerminalError` | `terminal:operate` | 1419 |
| `terminal.restart` | unary | `TerminalRestartInput` | `TerminalSessionSnapshot` | `TerminalError` | `terminal:operate` | 1424 |
| `terminal.close` | unary | `TerminalCloseInput` | `void` | `TerminalError` | `terminal:operate` | 1430 |
| `subscribeTerminalEvents` | stream | `{}` | `TerminalEvent` | - | `terminal:read` | 1665 |
| `subscribeTerminalMetadata` | stream | `{}` | `TerminalMetadataStreamEvent` | - | `terminal:read` | 1672 |

Payloads (`packages/contracts/src/terminal.ts`). Limits: `cols` int 1 to 1000, `rows` int 1 to 500, `terminalId` max 128 chars, env keys `^[A-Za-z_][A-Za-z0-9_]*$` max 128, env values max 8192 chars, at most 128 env entries (`terminal.ts:13-26`).

| Type | Fields |
| --- | --- |
| `TerminalOpenInput` | `threadId`, `terminalId`, `cwd` (required), `worktreePath?: string\|null`, `cols?`, `rows?`, `env?: Record<string,string>`, `providerInstanceId?` (`:40-48`) |
| `TerminalAttachInput` | as open but `cwd` optional, plus `restartIfNotRunning?: bool` (`:51-60`) |
| `TerminalObserveInput` | `{threadId, terminalId}` |
| `TerminalWriteInput` | `{threadId, terminalId, data}`; `data` 1 to 65,536 chars |
| `TerminalResizeInput` | `{threadId, terminalId, cols, rows}` |
| `TerminalClearInput` | `{threadId, terminalId}` |
| `TerminalRestartInput` | `{threadId, terminalId, cwd, worktreePath?, cols, rows, env?, providerInstanceId?}` |
| `TerminalCloseInput` | `{threadId, terminalId?, deleteHistory?}`; omit `terminalId` to close all of the thread's terminals |
| `TerminalSessionSnapshot` | `threadId`, `terminalId`, `cwd`, `worktreePath: string\|null`, `status` (`starting`, `running`, `exited`, `error`), `pid: int\|null`, `history: string`, `exitCode: int\|null`, `exitSignal: int\|null`, `label` (max 128), `updatedAt` (ISO), `sequence?` (`:103-117`) |
| `TerminalSummary` | snapshot minus `history` and `sequence`, plus `hasRunningSubprocess: bool` |
| `TerminalMetadataStreamEvent` | `{type:"snapshot", terminals}`, `{type:"upsert", terminal}`, `{type:"remove", threadId, terminalId}` |
| `TerminalEvent` | each has `threadId`, `terminalId`, `sequence?`: `started{snapshot}`, `output{data}`, `exited{exitCode, exitSignal}`, `closed`, `error{message}`, `cleared`, `restarted{snapshot}`, `activity{hasRunningSubprocess, label}` (`:159-222`) |
| `TerminalAttachStreamEvent` | `{type:"snapshot", snapshot}` plus the `TerminalEvent` members except `started` |

Errors are tagged: `TerminalCwdNotFoundError`, `TerminalCwdNotDirectoryError`, `TerminalCwdStatError`, `TerminalHistoryError`, `TerminalSessionLookupError`, `TerminalProviderInstanceNotFoundError`, `TerminalProviderEnvironmentError`, `TerminalNotRunningError`, `TerminalWriteError`, `TerminalResizeError` (`terminal.ts:242-383`).

Behavior a client must know (D sections 1.5 to 1.7):

- `attach` sends a `snapshot` first, then buffered events whose `sequence` is greater than the snapshot's, then live. With no session and no `cwd` it fails with `TerminalSessionLookupError`; with `cwd` it opens one. `observe` never starts, resizes or restarts anything (`terminal:read` only).
- `output.data` is the raw PTY output as a JSON string (not base64). `snapshot.history` is sanitized (terminal query and reply sequences stripped) so replay does not provoke replies; live output is not. Detach any PTY-reply writer while replaying history.
- `sequence` restarts at 0 for a replacement session; compare only within one stream.
- Ack every chunk. After about 64 KiB outstanding the server waits for real acks (`apps/server/src/terminal/OutputProtocol.ts:5-66`).
- Last resize wins; resizes to a missing or non-running session are ignored. `write` to an exited session is a no-op.
- The server can close idle terminals itself (when a thread settles); expect `closed` and a metadata `remove` without your request.
- History cap 5,000 lines and 8 MiB per terminal; running processes do not survive a server restart (a new shell is seeded with restored history).
- Shell is chosen by the server (`$SHELL`, then zsh, bash, sh). Defaults `cols=120`, `rows=30`.
- Project scripts run by `terminal.open` then `terminal.write "<command>\r"` (`apps/web/src/components/ChatView.tsx:4955-5060`). The client sends `T3CODE_PROJECT_ROOT` and, for worktree threads, `T3CODE_WORKTREE_PATH` in `env` (`packages/shared/src/projectScripts.ts:58-71`).
- Official client buffer limits: 512 KiB and 1,024 chunks (`packages/client-runtime/src/state/terminalOutput.ts:45-47`).
- Native rendering needs a VT emulator (libghostty, as the iOS app uses, or SwiftTerm). The wire carries plain strings and needs no browser engine.

### 9.2 Git, VCS, worktrees, diffs, source control

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `server.discoverSourceControl` | unary | `{}` | `SourceControlDiscoveryResult` | - | `orchestration:read` | 748 |
| `sourceControl.lookupRepository` | unary | `SourceControlRepositoryLookupInput` | `SourceControlRepositoryInfo` | `SourceControlRepositoryError`, ... | `orchestration:read` | 1108 |
| `sourceControl.cloneRepository` | unary | `SourceControlCloneRepositoryInput` | `SourceControlCloneRepositoryResult` | `SourceControlRepositoryError`, ... | `source-control:write` | 1114 |
| `sourceControl.publishRepository` | unary | `SourceControlPublishRepositoryInput` | `SourceControlPublishRepositoryResult` | `SourceControlRepositoryError`, ... | `source-control:write` | 1151 |
| `projectClone.start` | unary | `ProjectCloneStartInput` | `ProjectCloneStartResult` | `SourceControlRepositoryError`, ... | `source-control:write` | 1122 |
| `projectClone.cancel` | unary | `ProjectCloneActionInput` | `ProjectCloneActionResult` | - | `source-control:write` | 1132 |
| `projectClone.retry` | unary | `ProjectCloneActionInput` | `ProjectCloneActionResult` | `SourceControlRepositoryError`, ... | `source-control:write` | 1138 |
| `subscribeProjectClones` | stream | `ProjectCloneSubscribeInput` | `ProjectCloneListEvent` | - | `orchestration:read` | 1144 |
| `subscribeVcsStatus` | stream | `VcsStatusSubscriptionInput` | `VcsStatusStreamEvent` | `GitManagerServiceError`, ... | `orchestration:read` | 1287 |
| `subscribeWorktreeSetup` | stream | `WorktreeSetupSubscribeInput` | `WorktreeSetupStreamEvent` | - | `orchestration:read` | 1306 |
| `worktreeSetup.cancel` | unary | `WorktreeSetupCancelInput` | `WorktreeSetupCancelResult` | - | `orchestration:operate` | 1313 |
| `vcs.pull` | unary | `VcsPullInput` | `VcsPullResult` | `GitCommandError`, ... | `source-control:write` | 1294 |
| `vcs.refreshStatus` | unary | `VcsStatusInput` | `VcsStatusResult` | `GitManagerServiceError`, ... | `orchestration:read` | 1300 |
| `git.runStackedAction` | stream | `GitRunStackedActionInput` | `GitActionProgressEvent` | `GitManagerServiceError`, ... | `source-control:write` | 1319 |
| `git.resolvePullRequest` | unary | `GitPullRequestRefInput` | `GitResolvePullRequestResult` | `GitManagerServiceError`, ... | `orchestration:read` | 1326 |
| `git.preparePullRequestThread` | unary | `GitPreparePullRequestThreadInput` | `GitPreparePullRequestThreadResult` | `GitManagerServiceError`, ... | `source-control:write` | 1332 |
| `vcs.listRefs` | unary | `VcsListRefsInput` | `VcsListRefsResult` | `GitCommandError`, ... | `orchestration:read` | 1338 |
| `vcs.createWorktree` | unary | `VcsCreateWorktreeInput` | `VcsCreateWorktreeResult` | `GitCommandError`, ... | `source-control:write` | 1344 |
| `vcs.removeWorktree` | unary | `VcsRemoveWorktreeInput` | `void` | `GitCommandError`, ... | `source-control:write` | 1350 |
| `vcs.createRef` | unary | `VcsCreateRefInput` | `VcsCreateRefResult` | `GitCommandError`, ... | `source-control:write` | 1355 |
| `vcs.switchRef` | unary | `VcsSwitchRefInput` | `VcsSwitchRefResult` | `GitCommandError`, ... | `source-control:write` | 1361 |
| `vcs.init` | unary | `VcsInitInput` | `void` | `VcsError` | `source-control:write` | 1367 |
| `review.getDiffPreview` | unary | `ReviewDiffPreviewInput` | `ReviewDiffPreviewResult` | `ReviewDiffPreviewError`, ... | `filesystem:read` | 1377 |
| `review.getDiffFileContents` | unary | `ReviewDiffFileContentsInput` | `ReviewDiffFileContentsResult` | `ReviewDiffPreviewError`, ... | `filesystem:read` | 1383 |

Payloads (`packages/contracts/src/git.ts`, `vcs.ts`, `review.ts`, `sourceControl.ts`, `worktreeSetup.ts`):

| Type | Fields |
| --- | --- |
| `VcsStatusInput` | `{cwd}`. `VcsStatusSubscriptionInput` = `{cwd, includeRemote?}` (`false` makes a passive observer) |
| `VcsStatusStreamEvent` (`_tag`) | `snapshot{local, remote: Remote\|null}`, `localUpdated{local}`, `remoteUpdated{remote}` |
| `VcsStatusLocalResult` | `isRepo`, `sourceControlProvider?{kind,name,baseUrl}`, `hasPrimaryRemote`, `isDefaultRef`, `refName: string\|null`, `hasWorkingTreeChanges`, `workingTree{files:[{path,insertions,deletions}], insertions, deletions}`, `branchChanges?{baseRef, insertions, deletions}` |
| `VcsStatusRemoteResult` | `hasUpstream`, `aheadCount`, `behindCount`, `aheadOfDefaultCount?`, `pr: {number, title, url, baseRef, headRef, state: open\|closed\|merged, isDraft?, updatedAt?}\|null` |
| `VcsListRefsInput` | `cwd`, `query?`, `cursor?`, `includeMatchingRemoteRefs?`, `refKind?` (`all`, `local`, `remote`), `refresh?`, `limit?` (1 to 200). Result `{refs:[{name,isRemote?,remoteName?,current,isDefault,worktreePath}], isRepo, hasPrimaryRemote, nextCursor, totalCount}` |
| `VcsCreateRefInput` / `VcsSwitchRefInput` | `{cwd, refName, switchRef?}` / `{cwd, refName}` |
| `VcsCreateWorktreeInput` | `{cwd, refName, newRefName?, baseRefName?, path: string\|null}`; result `{worktree:{path, refName}}`. `VcsRemoveWorktreeInput` = `{cwd, path, force?}` |
| `VcsPullInput` | `{cwd}`; result `{status: pulled\|skipped_up_to_date, refName, upstreamRef}`. Fast-forward only |
| `VcsInitInput` | `{cwd, kind?}` |
| `GitRunStackedActionInput` | `actionId`, `cwd`, `action` (`commit`, `push`, `create_pr`, `commit_push`, `commit_push_pr`), `commitMessage?`, `featureBranch?`, `filePaths?`, `threadId?`, `projectId?` |
| `GitActionProgressEvent` (`kind`) | `action_started{phases}`, `phase_started{phase,label}`, `hook_started{hookName}`, `hook_output{hookName,stream,text}`, `hook_finished{hookName,exitCode,durationMs}`, `action_finished{result}`, `action_failed{phase,message}`; all carry `actionId`, `cwd`, `action`. Exactly one `action_finished` or `action_failed` ends the stream |
| `GitPullRequestRefInput` | `{cwd, reference}`. `GitPreparePullRequestThreadInput` = `{cwd, reference, mode: local\|worktree, threadId?}` |
| `ReviewDiffPreviewInput` | `{cwd, baseRef?, ignoreWhitespace?, file?}`; result `{cwd, generatedAt, sources:[{id,kind,title,baseRef,headRef,diff,diffHash,truncated,files?}]}`. Patch output max 120,000 bytes then `truncated:true` |
| `ReviewDiffFileContentsInput` | `{cwd, sourceKind, changeType, baseRef, headRef, oldPath, newPath}` → `{oldContents, newContents}` |
| `OrchestrationGetTurnDiffInput` | `{threadId, fromTurnCount, toTurnCount, ignoreWhitespace?}` → `{threadId, fromTurnCount, toTurnCount, diff}` (**recorded**, `03-turn2` t=41003) |
| `OrchestrationGetFullThreadDiffInput` | `{threadId, toTurnCount, ignoreWhitespace?}` → same result shape |
| `WorktreeSetupSnapshot` | `threadId`, `phase` (`running`, `done`, `failed`, `cancelled`), `startedAt`, `endedAt`, `branch`, `baseRef`, `worktreePath`, `setupScript`, `stages[]` (ids `fetch`, `checkout`, `submodules`, `setup-script`, `agent`), `error`, `sequence` |
| Source control | `SourceControlProviderKind`: `github`, `gitlab`, `forgejo`, `azure-devops`, `bitbucket`, `unknown`. Lookup `{provider, repository, cwd?}`; clone `{provider?, repository?, remoteUrl?, destinationPath, protocol?}`; publish `{cwd, provider, repository, visibility, remoteName?, protocol?}` |

Notes (D 2.5 to 2.7): `subscribeVcsStatus` has no file watcher; call `vcs.refreshStatus` on window focus to see edits made outside agents. The server cannot stash, amend, rebase, cherry-pick, stage hunks or delete branches over RPC. Commit messages, branch names and PR text are generated server-side when omitted. `review.*` refuses a `cwd` outside the server launch cwd and managed worktree directories (**UNVERIFIED** interaction with other project locations). Errors: `GitCommandError {operation, command, cwd, reason?, detail, ...}` with `reason` in `authentication_failed`, `branch_already_exists`, `branch_checked_out_in_worktree`, `host_key_unverified`, `not_a_repository`, `path_already_exists`, `remote_unreachable`, `tag_would_be_clobbered`; plus `TextGenerationError`, `GitManagerError`, `VcsError` members. `Option` fields in source-control discovery use `{"_tag":"Some","value":...}` / `{"_tag":"None"}`.

### 9.3 Pull requests

Capabilities `pullRequests`, `pullRequestChecks`, `threadPullRequests`, `threadPullRequestWatch`, `threadPullRequestLinking`, `pullRequestStackActions`. Large payloads travel over `POST /api/pull-requests/diff`. Thread links use the commands in section 7.3. Field-level shapes: **UNVERIFIED** (not summarised); read `packages/contracts/src/pullRequest.ts` and `threadPullRequest.ts`.

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `pullRequests.list` | unary | `PullRequestListInput` | `PullRequestListResult` | `PullRequestRpcError` | `orchestration:read` | 922 |
| `pullRequests.listStats` | unary | `PullRequestListStatsInput` | `PullRequestListStatsResult` | `PullRequestRpcError` | `orchestration:read` | 933 |
| `pullRequests.summary` | unary | `PullRequestRef` | `PullRequestSummary` | `PullRequestRpcError` | `orchestration:read` | 951 |
| `pullRequests.routing` | unary | `PullRequestRef` | `PullRequestRoutingResult` | `PullRequestRpcError` | `orchestration:read` | 939 |
| `pullRequests.routingIdentity` | unary | `PullRequestRoutingIdentityInput` | `PullRequestRoutingIdentityResult` | `PullRequestRpcError` | `orchestration:read` | 945 |
| `pullRequests.stack` | unary | `PullRequestRef` | `null |(PullRequestStack)` | `PullRequestRpcError` | `orchestration:read` | 957 |
| `pullRequests.linkedThreads` | unary | `PullRequestRef` | `PullRequestLinkedThreadsResult` | `PullRequestRpcError` | `orchestration:read` | 963 |
| `pullRequests.detail` | unary | `PullRequestRef` | `PullRequestDetail` | `PullRequestRpcError` | `orchestration:read` | 969 |
| `pullRequests.preview` | unary | `PullRequestRef` | `PullRequestPreview` | `PullRequestRpcError` | `orchestration:read` | 975 |
| `pullRequests.checks` | unary | `PullRequestRef` | `null |(PullRequestChecks)` | `PullRequestRpcError` | `orchestration:read` | 981 |
| `pullRequests.activity` | unary | `PullRequestRef` | `PullRequestActivity` | `PullRequestRpcError` | `orchestration:read` | 987 |
| `pullRequests.threadComments` | unary | `PullRequestThreadCommentsInput` | `PullRequestThreadCommentsResult` | `PullRequestRpcError` | `orchestration:read` | 993 |
| `pullRequests.diffFileContents` | unary | `PullRequestDiffFileContentsInput` | `PullRequestDiffFileContentsResult` | `PullRequestRpcError` | `orchestration:read` | 999 |
| `pullRequests.filesViewed` | unary | `PullRequestRef` | `PullRequestFilesViewedResult` | `PullRequestRpcError` | `orchestration:read` | 1005 |
| `pullRequests.setFilesViewed` | unary | `PullRequestSetFilesViewedInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1011 |
| `pullRequests.runAction` | unary | `PullRequestActionInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1017 |
| `pullRequests.update` | unary | `PullRequestUpdateInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1023 |
| `pullRequests.comment` | unary | `PullRequestCommentInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1029 |
| `pullRequests.updateComment` | unary | `PullRequestCommentUpdateInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1035 |
| `pullRequests.submitReview` | unary | `PullRequestSubmitReviewInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1041 |
| `pullRequests.replyToThread` | unary | `PullRequestThreadReplyInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1047 |
| `pullRequests.setThreadResolution` | unary | `PullRequestThreadResolutionInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1053 |
| `pullRequests.setReaction` | unary | `PullRequestReactionInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1059 |
| `pullRequests.invalidate` | unary | `PullRequestInvalidateInput` | `Schema.Void` | `PullRequestRpcError` | `orchestration:read` | 1065 |
| `pullRequests.subscribeRefreshes` | stream | `{}` | `NonNegativeInt` | - | `orchestration:read` | 1071 |
| `pullRequests.reviewerCandidates` | unary | `PullRequestRef` | `PullRequestReviewerCandidateList` | `PullRequestRpcError` | `orchestration:read` | 1083 |
| `pullRequests.requestReviewers` | unary | `PullRequestReviewerRequestInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1089 |
| `pullRequests.labelCandidates` | unary | `PullRequestRef` | `PullRequestLabelCandidateList` | `PullRequestRpcError` | `orchestration:read` | 1096 |
| `pullRequests.setLabels` | unary | `PullRequestLabelChangeInput` | `Schema.Void` | `PullRequestRpcError` | `source-control:write` | 1102 |

### 9.4 Settings

`server.getSettings` returns `ServerSettings`; `server.updateSettings` takes `{patch: ServerSettingsPatch, providerInstanceMutation?}` and returns the new `ServerSettings`. A `settingsUpdated` event on `subscribeServerConfig` replaces the whole settings object. The scopes needed depend on the patch (`requiredScopesForServerSettingsPatch`, `packages/contracts/src/settings.ts:1596`); a `providerInstanceMutation` also needs `providers:manage`.

Top-level keys of `ServerSettings` as recorded (`01-basic` t=38): `addProjectBaseDirectory`, `autoResumeLimitedThreads`, `automaticGitFetchInterval` (ms, `30000`), `backgroundActivity` (`{overrides, profile, schemaVersion}`), `backgroundActivityProfile` (`"balanced"`), `bitbucket` (`{accessToken, apiToken, email}`), `branchNameInstructions`, `branchNamePrefix` (`"t3"`), `branchNamingMode`, `continueThreadsAfterServerUpdate`, `cursorKeychainUsageEnabled`, `defaultAutoPull`, `defaultModelSelection` (`null` or ModelSelection), `defaultProjectScripts`, `defaultRuntimeMode` (`"full-access"`), `defaultTheme`, `defaultThemeSetAt`, `deviceHosts`, `deviceOnboardingCompleted`, `enableAgentBrowserAccess`, `enableAgentDeviceAccess`, `enableDeviceSupport`, `enableProviderUpdateChecks`, `environmentIcon`, `github` (`{hosts, tokens}`), `newWorktreesStartFromOrigin`, `observability`, `previousWorktreesDirectories`, `projectAgentBrowserAccessOverrides`, `projectAutoPullOverrides`, `projectScriptOverrides`, `projectSettingsFolded`, `projectSettingsOverrides`, `providerHealthRefreshInterval`, `providerInstances` (`{}`), `pullRequestMergeMethod`, `removeAgentCreditsOnMerge`, `responseStreamingMode`, `sidebarAutoSettleAfterDays`, `sidebarAutoSettleOnMerge`, `snoozeLimitedThreads`, `sourceControlWriterModelSelection`, `sourceControlWritingStyle`, `storageCleanup`, `textGenerationModelSelection`, `usageLimitSources`, `usageModelAliases`, `usagePriceOverrides`, `worktreeCleanup`, `worktreeSubmodules`, `worktreesDirectory`. Secrets inside settings (GitHub tokens, Bitbucket token) are part of this object; do not log it. The patch shape (`ServerSettingsPatch`) is defined at `packages/contracts/src/settings.ts` (**UNVERIFIED**: field-level patch semantics).

`server.getConfig` (`ServerConfig`) keys, recorded: `auth`, `availableEditors` (`["file-manager"]`), `cwd`, `directEndpoints`, `environment`, `issues`, `keybindings`, `keybindingsConfigPath`, `newProjectsRoot`, `observability`, `providers`, `remoteOpenTargets` (`[{host, kind:"mdns"}]`), `scratchWorkspaceRoot`, `settings`, `shellResumeCompletionMarker`, `shellRevealInFileManager`, `shellRevealInFileManagerKind`, `threadFind`, `threadFindProgressive`, `threadResumeCompletionMarker`, `threadSnapshotPagination`. It is about 80 KB (`PROGRESS.md`). Fetch it once, then follow `subscribeServerConfig`.

`subscribeServerConfig` events, all `{version:1, type, ...}` (`packages/contracts/src/server.ts:784-853`): `snapshot{config}`, `keybindingsUpdated{keybindings, issues}`, `providerStatuses{providers}`, `settingsUpdated{settings}`, `environmentThemesUpdated{themes}`, `usageLimitSourcesUpdated{sources}`. Opt in to the last two with payload booleans `environmentThemes`, `usageLimitSources`; `usageLimitsCommand` makes the server add the `/usage-limits` slash command to provider catalogs. A second `snapshot` can follow when editor discovery finishes late (`apps/server/src/ws.ts:298-360`); replace the config on every snapshot, and keep themes and usage-limit sources across snapshots because they never ride in a snapshot. The recorded stream's first chunk (`01-basic` t=69) is `{"config":{...}, "type":"snapshot","version":1}`.

`subscribeServerLifecycle` events (`server.ts:865-922`): `{version:1, sequence, type:"welcome", payload:{environment, cwd, projectName, bootstrapStatus?, bootstrapProjectId?, bootstrapThreadId?, bootstrapProjectCreated?, bootstrapThreadCreated?}}` (**recorded**, `01-basic` t=35), `{type:"ready", payload:{at, environment, updateOutcome?}}`, `{type:"legacyThreadMigration", payload:{status: running\|complete, totalThreadCount}}`.

### 9.5 Keybindings

The server stores keybindings in `keybindings.json` and sends resolved rules in `ServerConfig.keybindings`. A rule (`packages/contracts/src/keybindings.ts:197-201`): `{command, shortcut: {key, metaKey, ctrlKey, shiftKey, altKey, modKey}, whenAst?}`, with `whenAst` a tree of `{type:"identifier", name}`, `{type:"not", node}` and boolean nodes (`:171-195`). `modKey` means Cmd on macOS and Ctrl elsewhere. The array is forward compatible: rules with unknown commands or `when` nodes are dropped. Recorded rules: `{"command":"sidebar.toggle","shortcut":{"altKey":false,"ctrlKey":false,"key":"b","metaKey":false,"modKey":true,"shiftKey":false}}` and `navigation.back` with `whenAst:{"node":{"name":"terminalFocus","type":"identifier"},"type":"not"}` (`01-basic` t=67).

Edit with `server.upsertKeybinding {key, command, when?, replace?{key, command, when?}}` and `server.removeKeybinding {key, command, when?}`; both return `{keybindings, issues}` (`server.ts:740-758`). `key` is a trimmed non-empty string of bounded length (`MAX_KEYBINDING_VALUE_LENGTH`); its grammar (the config-file shortcut syntax) is **UNVERIFIED** here. `issues` are `{kind:"keybindings.malformed-config", message}` or `{kind:"keybindings.invalid-entry", message, index}`. Static commands (`keybindings.ts:59-114`): `sidebar.toggle`, `navigation.back`, `navigation.forward`, `terminal.toggle`, `terminal.split`, `terminal.splitVertical`, `terminal.new`, `terminal.close`, `rightPanel.toggle`, `rightPanel.new`, `threadPanel.toggle`, `rightPanel.toggleMaximized`, `rightPanel.close`, `view.reopenClosed`, `pullRequest.copyNumber`, `diff.toggle`, `preview.toggle`, `preview.refresh`, `preview.focusUrl`, `preview.zoomIn`, `preview.zoomOut`, `preview.resetZoom`, `commandPalette.toggle`, `filePicker.toggle`, `projectSearch.toggle`, `usage.open`, `theme.select`, `appearance.cycle`, `themeEditor.toggle`, `composer.stash`, `composer.sendAlternate`, `composer.sendBackground`, `composer.sendAndNewThread`, `composer.host`, `composer.cycleHost`, `composer.effort`, `composer.mode`, `composer.workspace`, `composer.previousWorktree`, `composer.branch`, `chat.new`, `chat.newLocal`, `chat.newWithoutProject`, `chat.find`, `editor.openFavorite`, `usage.cost`, `usage.tokens`, `usage.limits`, `usage.period.{day,week,month,quarter}`, plus model-picker and thread-jump command families (`MODEL_PICKER_KEYBINDING_COMMANDS`, `THREAD_KEYBINDING_COMMANDS`) and `script.<id>.run` (`SCRIPT_RUN_COMMAND_PATTERN`).

### 9.6 Providers and models

`ServerConfig.providers` and the `providerStatuses` event carry `ServerProvider[]`. One entry per provider instance. Recorded drivers: `codex`, `claudeAgent`, `cursor`, `grok`, `opencode`, `antigravity`, `muse`, `pi` (`01-basic` t=67). Recorded `claudeAgent` entry keys: `auth` (`{status, email, label, type}`; `status` `authenticated` or `unknown`), `checkedAt`, `compatibilityAdvisory` (`{status, latestVersionStatus, message, recommendedRange, recommendedVersion}`), `continuation` (`{groupKey}`), `displayName`, `driver`, `enabled`, `installed`, `instanceId`, `models[]`, `reportsContextWindow`, `showInteractionModeToggle`, `skills[]` (`{name, description, enabled, path, scope}`), `slashCommands[]` (`{name, description, input?:{hint}}`), `status` (`ready`), `usageLimits` (`{checkedAt, windows:[{id, kind, label, resetsAt, usedPercent, windowDurationMins}]}`), `version`, `versionAdvisory` (`{canInstallVersion, canUpdate, checkedAt, currentVersion, latestVersion, message, status, updateCommand}`).

Model entry: `{slug, name, aliases[], badge?, isCustom, capabilities:{optionDescriptors:[{id, label, type: "select"|"boolean", options?:[{id,label,isDefault?}], promptInjectedValues?}]}}`. Example: Claude models expose an `effort` select and sometimes a `fastMode` boolean. The model picker builds a `ModelSelection {instanceId, model: slug, options?: ProviderOptionSelection[]}` from these. `ProviderOptionSelection` is `{id, value}` (legacy object form also decodes). Model slugs seen: `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`. Treat `instanceId` and `slug` as opaque.

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `server.refreshProviders` | unary | inline struct | `ServerProviderUpdatedPayload` | union | `orchestration:read` | 594 |
| `server.updateProvider` | unary | `ServerProviderUpdateInput` | `ServerProviderUpdatedPayload` | `ServerProviderUpdateError`, ... | `providers:manage` | 615 |
| `provider.auth.start` | unary | `ProviderAuthStartInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 629 |
| `provider.auth.respond` | unary | `ProviderAuthRespondInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 635 |
| `provider.auth.complete` | unary | `ProviderAuthCompleteInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 641 |
| `provider.auth.cancel` | unary | `ProviderAuthCancelInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 670 |
| `provider.auth.logout` | unary | `ProviderSetupInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 676 |
| `provider.auth.subscribe` | stream | `ProviderSetupInput` | `ProviderAuthState` | `ProviderSetupRpcError` | `providers:manage` | 682 |
| `provider.install.start` | unary | `ProviderSetupInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `providers:manage` | 689 |
| `provider.install.cancel` | unary | `ProviderInstallCancelInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `providers:manage` | 695 |
| `provider.install.subscribe` | stream | `ProviderSetupInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `orchestration:read` | 701 |
| `provider.install.remove` | unary | `ProviderSetupInput` | `ProviderInstallState` | `ProviderSetupRpcError` | `providers:manage` | 708 |
| `provider.consumeResetCredit` | unary | `ProviderConsumeResetCreditInput` | `ProviderConsumeResetCreditResult` | `ProviderSetupError`, `UsageLimitSourceError`, ... | `providers:manage` | 623 |
| `shell.openInEditor` | unary | `LaunchEditorInput` | `void` | `ExternalLauncherError`, ... | `orchestration:operate` | 1207 |

Provider auth and install flows (`ProviderAuthState`, `ProviderInstallState` streams) are driven by `providers:manage`; a read-only client only needs `providerStatuses`. Field-level shape of auth and install states: **UNVERIFIED** (not summarised).

### 9.7 Attachments and assets

Covered in section 5.3 (upload and download flow) and section 7.3 (`ChatAttachment`). RPC methods:

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `attachments.createUploadUrl` | unary | `AttachmentCreateUploadUrlInput` | `AttachmentCreateUploadUrlResult` | `AttachmentUploadSigningKeyError`, ... | `orchestration:operate` | 1247 |
| `attachments.delete` | unary | `AttachmentDeleteInput` | `void` | - | `orchestration:operate` | 1253 |
| `assets.createUrl` | unary | `AssetCreateUrlInput` | `AssetCreateUrlResult` | `AssetAccessError`, ... | `orchestration:read` | 1235 |
| `assets.persistChatAttachments` | unary | `PersistChatAttachmentsInput` | `PersistChatAttachmentsResult` | `PersistChatAttachmentsError`, ... | `orchestration:operate` | 1241 |

`AssetResource` is a union on `_tag`: `workspace-file {threadId, path}`, `media-file {threadId, path}`, `draft-workspace-file {cwd, path}`, `attachment {attachmentId, fileName?, mimeType?, disposition?}`, `tool-output-image {threadId, itemId, index}`, `project-favicon {cwd, path?}`, `native-app-icon {app}`, `github-media {cwd, url}` (`packages/contracts/src/assets.ts:14-68`). `assets.createUrl` returns `{relativeUrl, expiresAt (epoch ms), sourcePath?, imageDimensions?:{width,height}}`. Tokens last 1 hour. Fetch `relativeUrl` resolved against the HTTP base; the signed token in the path is the credential, so no `Authorization` header is needed.

### 9.8 Preview, server browser and devices

Preview tabs can be hosted by the server (`serverBrowser` capability, headless Chromium) and streamed over `/api/preview-stream/ws`. Devices (emulators, simulators) stream through `/api/device-hub/*`. A native client without a web view can omit both; the official clients render them in web content (see `PROGRESS.md` decisions). Field-level shapes: **UNVERIFIED** (not summarised).

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `preview.open` | unary | `PreviewOpenInput` | `PreviewSessionSnapshot` | `PreviewError` | `preview:operate` | 1435 |
| `preview.navigate` | unary | `PreviewNavigateInput` | `PreviewSessionSnapshot` | `PreviewError` | `preview:operate` | 1441 |
| `preview.resize` | unary | `PreviewResizeInput` | `PreviewSessionSnapshot` | `PreviewError` | `preview:operate` | 1447 |
| `preview.adjust` | unary | `PreviewAdjustInput` | `PreviewSessionSnapshot` | `PreviewError` | `preview:operate` | 1453 |
| `preview.refresh` | unary | `PreviewRefreshInput` | `void` | `PreviewError` | `preview:operate` | 1459 |
| `preview.close` | unary | `PreviewCloseInput` | `void` | `PreviewError` | `preview:operate` | 1464 |
| `preview.list` | unary | `PreviewListInput` | `PreviewListResult` | - | `orchestration:read` | 1469 |
| `preview.clearProfile` | unary | `PreviewClearProfileInput` | `void` | `PreviewClearProfileError`, ... | `preview:operate` | 1475 |
| `preview.reportProfiles` | unary | `PreviewReportProfilesInput` | `void` | - | `preview:operate` | 1480 |
| `preview.reportStatus` | unary | `PreviewReportStatusInput` | `void` | `PreviewError` | `preview:operate` | 1485 |
| `subscribePreviewEvents` | stream | `{}` | `PreviewEvent` | - | `orchestration:read` | 1490 |
| `subscribeDiscoveredLocalServers` | stream | inline struct | `DiscoveredLocalServerList` | - | `orchestration:read` | 1497 |
| `device.configure` | unary | `DeviceConfigureInput` | `DeviceServiceState` | `DeviceError` | `settings:write` | 1518 |
| `device.list` | unary | `DeviceListInput` | `DeviceServiceState` | `DeviceError` | `orchestration:read` | 1512 |
| `device.testHost` | unary | `SshDeviceHostConfig` | `DeviceHostSummary` | `DeviceError` | `settings:write` | 1506 |
| `device.open` | unary | `DeviceOpenInput` | `DeviceSession` | `DeviceError` | `orchestration:operate` | 1524 |
| `device.close` | unary | `DeviceCloseInput` | `void` | `DeviceError` | `orchestration:operate` | 1530 |
| `device.shutdown` | unary | `DeviceShutdownInput` | `void` | `DeviceError` | `orchestration:operate` | 1535 |
| `device.detail` | unary | `DeviceDetailInput` | `DeviceDetail` | `DeviceError` | `orchestration:read` | 1540 |
| `device.action` | unary | `DeviceActionInput` | `DeviceDetail` | `DeviceError` | `orchestration:operate` | 1546 |
| `subscribeDeviceState` | stream | `{}` | `DeviceServiceState` | - | `orchestration:read` | 1552 |

### 9.9 Scheduled tasks

Scheduled tasks send prompts into threads without a user present (trigger types and schedule syntax: **UNVERIFIED**). Webhook entry is the unauthenticated `POST|PUT|PATCH|GET /api/hooks/:hookId/:token` route (202 `{deliveryId}`; the token in the path, and an optional body signature, is the credential; `apps/server/src/scheduledTasks/ScheduledTaskService.ts:58`). Messages sent by a task carry `scheduledTaskId` (`message.dispatch`, section 7.3). Scope `orchestration:operate`. Field-level shapes: **UNVERIFIED** (not summarised).

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `scheduledTasks.list` | unary | `ScheduledTaskListInput` | `ScheduledTaskListResult` | `ScheduledTaskError`, ... | `orchestration:read` | 1710 |
| `scheduledTasks.subscribe` | stream | `ScheduledTaskListInput` | `ScheduledTaskListResult` | `ScheduledTaskError`, ... | `orchestration:read` | 1717 |
| `scheduledTasks.upsert` | unary | `ScheduledTaskUpsertInput` | `ScheduledTaskMutationResult` | `ScheduledTaskError`, ... | `orchestration:operate` | 1724 |
| `scheduledTasks.setEnabled` | unary | `ScheduledTaskSetEnabledInput` | `ScheduledTaskMutationResult` | `ScheduledTaskError`, ... | `orchestration:operate` | 1730 |
| `scheduledTasks.delete` | unary | `ScheduledTaskDeleteInput` | `ScheduledTaskDeleteResult` | `ScheduledTaskError`, ... | `orchestration:operate` | 1736 |
| `scheduledTasks.runNow` | unary | `ScheduledTaskRunNowInput` | `ScheduledTaskRunNowResult` | `ScheduledTaskError`, ... | `orchestration:operate` | 1742 |
| `scheduledTasks.rotateWebhookToken` | unary | `ScheduledTaskRotateWebhookTokenInput` | `ScheduledTaskMutationResult` | `ScheduledTaskError`, ... | `orchestration:operate` | 1748 |
| `scheduledTasks.listWebhookDeliveries` | unary | `ScheduledTaskListWebhookDeliveriesInput` | `ScheduledTaskListWebhookDeliveriesResult` | `ScheduledTaskError`, ... | `orchestration:operate` | 1762 |
| `scheduledTasks.getWebhookDelivery` | unary | `ScheduledTaskGetWebhookDeliveryInput` | `ScheduledTaskGetWebhookDeliveryResult` | `ScheduledTaskError`, ... | `orchestration:operate` | 1771 |
| `secrets.answerRequest` | unary | `SecretRequestAnswerInput` | `void` | `SecretRequestError`, ... | `orchestration:operate` | 1757 |

### 9.10 Usage, diagnostics and host

Usage limits per provider arrive inside `ServerProvider.usageLimits` (section 9.6). Cost and token summaries come from `server.getUsageSummary` (scope `diagnostics:read`). Resource telemetry streams through `subscribeResourceTelemetry`. Background-activity policy (`backgroundActivityProfile: "balanced"` in the recording) is read with `server.getBackgroundPolicy` and `subscribeBackgroundPolicy`; server polls such as the VCS remote poller respect it (D 2.5). `server.reportClientActivity` reports client activity to the server (payload semantics **UNVERIFIED**). Field-level shapes: **UNVERIFIED** (not summarised).

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `server.getUsageSummary` | unary | `UsageSummaryInput` | `UsageSummary` | `UsageReadError`, ... | `diagnostics:read` | 865 |
| `server.refreshUsageRates` | unary | `{}` | `UsagePricing` | - | `diagnostics:read` | 875 |
| `server.getHostResources` | unary | `{}` | `HostResourcesSnapshot` | - | `orchestration:read` | 838 |
| `server.getProcessDiagnostics` | unary | `{}` | `ServerProcessDiagnosticsResult` | - | `diagnostics:read` | 832 |
| `server.getTraceDiagnostics` | unary | `{}` | `ServerTraceDiagnosticsResult` | - | `diagnostics:read` | 826 |
| `server.getProcessResourceHistory` | unary | `ServerProcessResourceHistoryInput` | `ServerProcessResourceHistoryResult` | - | `diagnostics:read` | 844 |
| `server.getResourceTelemetryHistory` | unary | `ResourceTelemetryHistoryInput` | `ResourceTelemetryHistory` | - | `diagnostics:read` | 850 |
| `server.retryResourceTelemetry` | unary | `{}` | `ResourceTelemetryRetryResult` | - | `diagnostics:read` | 859 |
| `subscribeResourceTelemetry` | stream | `{}` | `ResourceTelemetrySnapshot` | - | `diagnostics:read` | 1794 |
| `server.reportClientActivity` | unary | `ClientActivityReportInput` | `void` | - | `orchestration:read` | 900 |
| `server.reportHostPowerState` | unary | `HostPowerSnapshot` | `void` | - | `environment:maintain` | 905 |
| `server.getBackgroundPolicy` | unary | `{}` | `BackgroundPolicySnapshot` | - | `orchestration:read` | 910 |
| `subscribeBackgroundPolicy` | stream | `{}` | `BackgroundPolicySnapshot` | - | `orchestration:read` | 1787 |
| `server.signalProcess` | unary | `ServerSignalProcessInput` | `ServerSignalProcessResult` | - | `environment:maintain` | 881 |

### 9.11 Projects and filesystem

Project snapshot and mutations are in sections 5 and 7.3. File access RPCs:

| Method | Kind | Payload | Success | Errors (besides `EnvironmentAuthorizationError`) | Scope | `rpc.ts` |
|---|---|---|---|---|---|---|
| `projects.listEntries` | unary | `ProjectListEntriesInput` | `ProjectListEntriesResult` | `ProjectListEntriesError`, ... | `filesystem:read` | 1169 |
| `projects.readFile` | unary | `ProjectReadFileInput` | `ProjectReadFileResult` | `ProjectReadFileError`, ... | `filesystem:read` | 1175 |
| `projects.searchEntries` | unary | `ProjectSearchEntriesInput` | `ProjectSearchEntriesResult` | `ProjectSearchEntriesError`, ... | `filesystem:read` | 1157 |
| `projects.searchContents` | unary | `ProjectSearchContentsInput` | `ProjectSearchContentsResult` | `ProjectSearchContentsError`, ... | `filesystem:read` | 1163 |
| `projects.writeFile` | unary | `ProjectWriteFileInput` | `ProjectWriteFileResult` | `ProjectWriteFileError`, ... | `filesystem:write` | 1181 |
| `projects.ensureScratch` | unary | `{}` | `ProjectEnsureScratchResult` | `OrchestrationDispatchCommandError`, ... | `orchestration:operate` | 1194 |
| `projects.createNew` | unary | `ProjectCreateNewInput` | `ProjectCreateNewResult` | `OrchestrationDispatchCommandError`, ... | `orchestration:operate` | 1201 |
| `filesystem.browse` | unary | `FilesystemBrowseInput` | `FilesystemBrowseResult` | `FilesystemBrowseError`, ... | `filesystem:read` | 1212 |
| `agentSessions.scan` | unary | `AgentSessionScanInput` | `AgentSessionScanResult` | `AgentSessionScanError`, ... | `orchestration:read` | 1218 |
| `agentSessions.import` | unary | `AgentSessionImportInput` | `AgentSessionImportResult` | `AgentSessionImportProjectChangedError`, ... | `orchestration:operate` | 1224 |
| `mcpApps.callTool` | unary | `McpAppCallToolInput` | `McpAppCallToolResult` | `McpAppRequestError`, ... | `orchestration:operate` | 1258 |
| `mcpApps.toolInfo` | unary | `McpAppToolInfoInput` | `McpAppToolInfo` | `McpAppRequestError`, ... | `orchestration:read` | 1264 |
| `mcpApps.readResource` | unary | `McpAppReadResourceInput` | `McpAppReadResourceResult` | `McpAppRequestError`, ... | `orchestration:read` | 1275 |
| `mcpApps.updateModelContext` | unary | `McpAppUpdateModelContextInput` | `void` | `McpAppRequestError`, ... | `orchestration:operate` | 1270 |

`orchestration.searchThreads`, `searchThread` and `searchThreadStream` implement thread find (`threadFind`, `threadFindProgressive` flags): see the catalog for payloads (`OrchestrationSearchThreadsInput`, `OrchestrationV2SearchThreadInput`).

---

## 10. T3 Connect

T3 Connect lets a client reach a linked environment through a hosted relay and a managed tunnel, with no port forwarding. The relay is the control plane only: after connecting, RPC traffic goes directly between client and environment (`infra/relay/README.md:9-12`). A relay token is never an environment login. Source: `docs/research/C-auth-connect.md` sections 0, 4, 6 plus relay source verified below. C's sections 3, 4.1 to 4.3, 4.5 and 5 were never written; the Clerk and relay-token parts below come from direct reading of source.

### 10.1 Identifiers and constants

| Item | Value | Source |
| --- | --- | --- |
| Relay URL | `https://relay.t3.codes` | `.env.example:22` |
| Hosted app | `https://app.t3.codes` (pairing page `/pair`, connect page `/connect`) | `packages/shared/src/connectAuth.ts:15` |
| Clerk publishable key | `pk_live_Y2xlcmsudDMuY29kZXMk` (base64 of `clerk.t3.codes$`) | `.env.example:9` |
| Clerk Frontend API | `https://clerk.t3.codes` | `packages/shared/src/relayAuth.ts:32-78` |
| Clerk JWT template | `t3-relay`, claims `{"aud":"t3-code-relay"}` | `.env.example:10`, `docs/operations/connect-setup.md:50-61` |
| Clerk CLI OAuth app | public PKCE client id `hzxSgY2cH10sDU2r`; redirect `http://127.0.0.1:34338/callback`; scopes `openid profile email offline_access`; endpoints `https://clerk.t3.codes/oauth/token` and `/oauth/device_authorization` | `.env.example:11`, `apps/server/src/cloud/publicConfig.ts:21,196-206`, `packages/shared/src/connectAuth.ts:22` |
| Relay public client ids | `t3-web` (web and desktop renderer), `t3-mobile` | `packages/contracts/src/relay.ts:747-750`, `apps/web/src/cloud/managedRelayLayer.ts:80` |
| Relay DPoP access token scopes | `environment:connect`, `environment:status`, `mobile:registration`. Client `t3-web` may request only the first two. | `packages/contracts/src/relay.ts:733-741`, `infra/relay/src/auth/RelayTokens.ts:71-85` |
| Relay DPoP access token lifetime | 30 minutes | `infra/relay/src/auth/RelayTokens.ts:29` |
| Minted environment credential | 2 min, single use, bound to the client key thumbprint (`jkt`), 13 standard scopes, subject `cloud-connect` | `apps/server/src/cloud/CloudLink.ts:1622-1628` |
| Environment DPoP session | 1 hour | `apps/server/src/auth/EnvironmentAuth.ts:913-917` |
| DPoP algorithm | ES256 on P-256, `typ: dpop+jwt` | `packages/shared/src/dpop.ts:12-13` |
| DPoP `iat` window | now - 300 s to now + 5 s | `packages/shared/src/dpop.ts:14,178-188` |
| DPoP nonce | not supported | search of `apps`, `packages`, `infra` finds no `DPoP-Nonce` |
| Managed tunnel hostnames | `prod-<digest>.<RELAY_TUNNEL_ZONE_NAME>`; the production zone value is **not in source** (UNVERIFIED) | `infra/relay/README.md:103-110` |
| Official macOS bundle id (do not reuse) | `com.t3tools.t3code`; official URL schemes `t3code://`, `t3code-dev://` | `docs/operations/connect-setup.md:63-92` |

### 10.2 Clerk sign-in

Clerk is the identity provider. Three sign-in paths exist in source:

1. **Web and desktop renderer, mobile**: the Clerk SDK (`useAuth().getToken`) yields a Clerk session JWT. The client asks for the JWT template `t3-relay` (`apps/web/src/cloud/useCloudLinkController.ts:115`, `apps/web/src/cloud/publicConfig.ts:77-83`; client option `skipCache: true`).
2. **CLI authorization-code + PKCE**: the CLI prints `https://app.t3.codes/connect#state=...&challenge=...&port=<loopback>`; the hosted page waits for a Clerk session and forwards to Clerk's authorize endpoint with redirect `http://127.0.0.1:<port>/callback`. The CLI exchanges the code at `https://clerk.t3.codes/oauth/token` and stores `access_token` and `refresh_token` (`packages/shared/src/connectAuth.ts:30-100`, `apps/server/src/cloud/CliTokenManager.ts:135-505`). The hosted `/connect` hop exists because a signed-out browser sent straight to Clerk's authorize URL loses the query parameters.
3. **CLI headless**: OAuth device authorization (RFC 8628) at `https://clerk.t3.codes/oauth/device_authorization`, then polling the token endpoint (`CliTokenManager.ts:322-409`).

Which token the relay accepts (verified in `infra/relay/src/http/Api.ts`):

| Relay route | Accepts |
| --- | --- |
| `POST /v1/client/dpop-token` (subject token in form body) | **only** a Clerk session JWT from the `t3-relay` template: signature verified with Clerk, and `aud` must contain `t3-code-relay` (`Api.ts:1013-1034`, `:1631-1650`). A Clerk OAuth access token is not accepted here. |
| `GET /v1/environments`, link challenge and other `Authorization: Bearer` routes | the same JWT, or else a Clerk **OAuth** access token validated through Clerk `authenticateRequest` with `acceptsToken: "oauth_token"` (`Api.ts:1682-1696`) |

So the CLI's OAuth access token can list environments and create link challenges (`apps/server/src/cloud/CloudLink.ts:899-901` sends it as the Bearer), but **connecting needs the `t3-relay` JWT**. A native client that wants to connect must obtain that JWT from a Clerk session. How a third-party native app should obtain a Clerk session and a `t3-relay` token is **UNVERIFIED**: options are (a) Clerk's Frontend API with a native sign-in flow, (b) a hosted-page handoff like the CLI's `/connect`, (c) reuse of the OAuth app. None is confirmed to work for a client other than the official apps; sign-up restrictions are configured in Clerk (`docs/operations/connect-setup.md`). Each option needs product-level confirmation.

### 10.3 Relay client endpoints

Base `https://relay.t3.codes`. Contract: `packages/contracts/src/relay.ts:956-1273`. Errors: section 10.9.

| Method | Path | Auth | Request | Response |
| --- | --- | --- | --- | --- |
| POST | `/v1/client/dpop-token` | header `DPoP: <proof>` (no `ath`); Clerk JWT in body | form: `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token=<Clerk JWT>`, `subject_token_type=urn:ietf:params:oauth:token-type:jwt`, `requested_token_type=urn:ietf:params:oauth:token-type:access_token`, `resource=https://relay.t3.codes`, `scope=environment:connect` (status listing uses `environment:status environment:connect`), `client_id=t3-web` or `t3-mobile` | `{access_token, issued_token_type, token_type:"DPoP", expires_in, scope}`. The client rejects a response whose `scope` differs from the request (`packages/client-runtime/src/relay/managedRelay.ts:517-522`). `resource` must equal the relay issuer or the relay answers 401. |
| GET | `/v1/environments` | `Authorization: Bearer <Clerk JWT or OAuth token>` | none | `{"environments":[{environmentId, label, endpoint:{httpBaseUrl, wsBaseUrl, providerKind}, linkedAt}]}` |
| POST | `/v1/environments/:environmentId/status` | `Authorization: DPoP <relay AT>` + `DPoP` proof with `ath` | none | `RelayEnvironmentStatusResponse` `{environmentId, endpoint, status: online\|offline, checkedAt, descriptor, error?, offlineReason?: "tunnel_released", traceId?}` |
| POST | `/v1/environments/:environmentId/connect` | `Authorization: DPoP <relay AT>` + proof | `{deviceId?, clientKeyThumbprint?, clientProofKeyThumbprint?}`. The official client sends `clientKeyThumbprint` (deprecated alias) | `{environmentId, endpoint:{httpBaseUrl, wsBaseUrl, providerKind}, credential, expiresAt}` |
| DELETE | `/v1/client/environment-links/:environmentId` | Bearer Clerk | none | `{ok}`. "Deregister" works while the host is offline |
| POST | `/v1/client/environment-link-challenges` | Bearer Clerk | `{notificationsEnabled, liveActivitiesEnabled, managedTunnelsEnabled}` | `{challenge, expiresAt}`; enabling T3 Connect on a host |
| POST | `/v1/client/environment-links` | Bearer Clerk | `{deviceId?, proof, notificationsEnabled, liveActivitiesEnabled, managedTunnelsEnabled}` | `{ok, cloudUserId, environmentId, endpoint, endpointRuntime\|null, relayIssuer, environmentCredential, cloudMintPublicKey}` |
| GET | `/v2/client/devices` | Bearer Clerk | | `{devices:[...]}` device list UI |
| GET | `/health` | none | | `{"ok":true,"service":"relay"}` |
| GET | `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource` | none | | metadata; `dpop_signing_alg_values_supported: ["ES256"]` |

Not for desktop clients: `/v1/mobile/*` (push registration, scope `mobile:registration`), `/v1/environments/:id/tunnel*`, `/hooks/wake` (environment credential), `/v1/hooks/:endpointKey/:hookId/:token` (webhooks).

`providerKind` is `manual`, `cloudflare_tunnel` or `t3_relay` (`relay.ts:158-170`). Relay request timeout 10 s (`managedRelay.ts:225`).

### 10.4 Connect sequence (client side)

From `packages/client-runtime/src/authorization/service.ts:248-337,425-511` and `packages/client-runtime/src/relay/managedRelay.ts:484-639,812-843`:

```text
 1  clerkJwt = Clerk getToken(template "t3-relay", skipCache)            (10.2)
 2  key = per-install P-256 key; jkt = RFC 7638 thumbprint(key)           (10.5)
 3  POST relay /v1/client/dpop-token  -> relay access token (30 min), cache by {account, client, relay, jkt}
 4  POST relay /v1/environments/{id}/connect {clientKeyThumbprint: jkt}   (Authorization: DPoP, fresh proof with ath)
        -> {environmentId, endpoint, credential, expiresAt}
        check environmentId == requested id
 5  GET  {httpBaseUrl}/.well-known/t3/environment ; check descriptor.environmentId == id
 6  POST {httpBaseUrl}/oauth/token   (DPoP proof for that URL, no ath)
        form: token-exchange, subject_token=<credential>, subject_token_type=...environment-bootstrap, ...
        -> {access_token, token_type:"DPoP", expires_in:3600, scope:<13 standard scopes>}
 7  POST {httpBaseUrl}/api/auth/websocket-ticket  (Authorization: DPoP <token>, proof with ath)
 8  GET  {wsBaseUrl}ws?wsTicket=...&orchestrationProtocol=2&connectionMethod=relay&clientSurface=desktop&...
 9  every later HTTP call to the environment: Authorization: DPoP <token> + fresh proof (htu = that URL, ath)
```

Behavior: the minted credential lives 2 minutes and works once; redeem it immediately with the same key. On a relay `invalid_bearer` the client drops the cached relay token and retries once. The environment DPoP token is renewed 60 s before expiry (`DPOP_ACCESS_TOKEN_REFRESH_SKEW_MS`, `packages/client-runtime/src/connection/model.ts:108`). If a cached token fails to get a ticket within 3 s it is replaced by a fresh relay-minted one (`service.ts:479-501`). One automatic renewal and retry on an HTTP `invalid_credential` (`packages/client-runtime/src/state/environmentHttpAuth.ts:148-207`). Timeouts: relay and environment requests 10 s, the whole DPoP authorization 30 s (`service.ts:89`), connection establishment 15 s (`supervisor.ts:37`).

### 10.5 DPoP proofs

Shared verifier: `packages/shared/src/dpop.ts:113-199`, environment replay store `apps/server/src/auth/dpop.ts:56-126`.

- Key: ECDSA P-256. Header `{"typ":"dpop+jwt","alg":"ES256","jwk":{"kty":"EC","crv":"P-256","x":"<b64url>","y":"<b64url>"}}`. The JWK must be exactly those four members, no `d`.
- Claims `{"htm":"POST","htu":"<url>","jti":"<uuid v4>","iat":<epoch seconds>,"ath":"<b64url(sha256(access_token))>"}`. `htm` is compared case-insensitively (send upper case). `htu` is the request URL with query and fragment removed, WHATWG-normalized (default ports dropped, host lower-case), compared by **exact string equality**. The server rebuilds it as `${x-forwarded-proto=="https" ? "https" : "http"}://${Host}${path}`, so use the scheme and authority you actually connected to. `ath` is required whenever an access token is presented and omitted on `/oauth/token` and `/v1/client/dpop-token`.
- Signature: ES256 over `ASCII(b64url(header) + "." + b64url(payload))`, **raw 64-byte `r||s`** (IEEE P1363), base64url. In CryptoKit use `signature(for:).rawRepresentation`, not DER.
- Base64url is unpadded RFC 4648 section 5.
- JWK thumbprint (RFC 7638): `base64url(SHA256(UTF8('{"crv":"P-256","kty":"EC","x":"<x>","y":"<y>"}')))` with members in that order and no whitespace (`packages/shared/src/dpop.ts:83-94`).
- Validation order: proof present and well-formed; thumbprint equals the session `jkt` (`key_mismatch`); `htm`/`htu` (`request_mismatch`); `ath` (`token_mismatch`); signature (`invalid_proof`); `iat` window (`time_window`); then replay: the environment records `jti` per thumbprint and rejects reuse with `replay` (markers pruned after 1 day) (`apps/server/src/auth/dpop.ts:87-124`). **Fresh `jti` for every request. Never retry with the same proof.**
- One key per install, shared by the relay and every environment. A Secure Enclave `SecureEnclave.P256.Signing.PrivateKey` satisfies this because only the public JWK and signatures leave the device (the official mobile app stores a software key; `apps/mobile/src/features/cloud/dpop.ts`). Whether a Secure Enclave key with the app's entitlements works end to end was not tested.

### 10.6 Tunnels, routes and learned endpoints

- A linked host publishes an endpoint `{httpBaseUrl, wsBaseUrl, providerKind}`. With managed tunnels, `providerKind` is `cloudflare_tunnel` and the URLs are `https://prod-<digest>.<zone>` / `wss://...`.
- The environment removes its tunnel after idle offline time (5 to 10 minutes with idle cleanup on) but stays linked; it recreates the tunnel when it starts. The relay reports `status:"offline"`, `offlineReason:"tunnel_released"`. UI text: "Offline for a while, so its T3 Connect tunnel was removed. Start T3 Code on that computer and update it to the latest version to reconnect." (`packages/client-runtime/src/relay/errorPresentation.ts:24-84`, `docs/user/remote-access.md:293-299`).
- `ServerConfig.directEndpoints` and `remoteOpenTargets` report LAN or tailnet addresses the host can be reached at. The official client "learns" such routes and prefers them over the tunnel (check every 60 s while on a fallback route, cooldown 300 s after a failed better route; `packages/client-runtime/src/connection/supervisor.ts:46-54`). A learned direct route reuses the DPoP access token with a proof per URL. Before sending a credential to a learned address, fetch its descriptor and require the same `environmentId` (`service.ts:142-181`).
- Never fall back to the host's loopback address for a remote environment (`docs/internals/remote.md:26-29`).

### 10.7 Linking a host (T3 Connect enable)

Only needed if the native app runs on the host and offers "Enable T3 Connect". Requires `relay:write` (administrative pairing; standard pairings lack it).

1. `POST relay /v1/client/environment-link-challenges` (Bearer Clerk) → `{challenge, expiresAt}`.
2. `POST {local}/api/connect/link-proof` `{challenge, relayIssuer, endpoint:{httpBaseUrl, wsBaseUrl, providerKind}, origin:{localHttpHost:"127.0.0.1", localHttpPort}}` → an Ed25519 JWT (`t3-env-link+jwt`, 5 minutes). The request must arrive over loopback with no forwarded headers and the port must match (`apps/server/src/cloud/CloudLink.ts:628-686`).
3. `POST relay /v1/client/environment-links` `{proof, ...}` → `{environmentId, endpoint, relayIssuer, environmentCredential, cloudMintPublicKey, ...}`.
4. `POST {local}/api/connect/relay-config` with those values.

Unlink: `POST {local}/api/connect/unlink`, then best-effort relay `DELETE /v1/client/environment-links/:id`. Status: `GET /api/connect/link-state`. Sources: `apps/web/src/cloud/linkEnvironment.ts:218-349`.

### 10.8 Reconnect and backoff constants

`packages/client-runtime/src/connection/supervisor.ts:35-49,128-141`:

| Constant | Value |
| --- | --- |
| `RETRY_BASE_DELAY_MS` | 1,000 |
| `RETRY_MAX_DELAY_MS` | 300,000 |
| Delay after `n` consecutive failures (`n` = 0 for the first retry) | ceiling `c = min(300000, 1000 * 2^(n+1))`; delay `= round(c/2 + (c/2) * random)` with `random` in [0, 1) |
| `BACKOFF_RESET_AFTER_MS` | 30,000 (the failure count resets after 30 s connected) |
| `CONNECTION_ESTABLISHMENT_TIMEOUT` | 15 s |
| `CONNECTION_PROBE_TIMEOUT` | 15 s; quick probe 3 s (resume, explicit retry, offline events) |
| `BETTER_ROUTE_CHECK_INTERVAL` | 60 s |
| `BETTER_ROUTE_COOLDOWN_MS` | 300,000 |
| Ping interval | 5 s (Effect client) |

Return to the app, network regained and explicit retry skip the wait. Expect the server to close a DPoP socket about 1 hour after the token exchange; reconnect re-runs 10.4 (usually from the cached relay token) without user action.

### 10.9 Relay errors

All relay errors are `Schema.TaggedError` bodies with `_tag`, `code`, `traceId` and a `reason` where applicable (`packages/contracts/src/relay.ts:392-608`):

| Status | `_tag` / `code` | `reason` values | Client class (`packages/client-runtime/src/connection/errors.ts:37-113`) |
| --- | --- | --- | --- |
| 401 | `RelayAuthInvalidError` / `auth_invalid` | `missing_bearer`, `invalid_bearer`, `invalid_dpop` (+`dpopFailureReason`), `not_authorized` | blocked: authentication |
| 403 | `RelayEnvironmentConnectNotAuthorizedError` | `client_proof_key_thumbprint_missing`, `environment_link_not_found`, `endpoint_provider_not_managed`, `managed_endpoint_allocation_not_found`, `managed_endpoint_base_domain_not_configured`, `managed_endpoint_allocation_not_ready`, `managed_endpoint_hostname_invalid`, `managed_endpoint_mismatch` | blocked: permission |
| 502 | `RelayEnvironmentEndpointUnavailableError` | `endpoint_request_failed`, `endpoint_response_invalid` | transient |
| 504 | `RelayEnvironmentEndpointTimedOutError` | | transient: timeout |
| 401 | `RelayEnvironmentLinkProofExpiredError` | | blocked: authentication |
| 400 | `RelayEnvironmentLinkProofInvalidError` | `invalid_signature_or_scope`, `descriptor_mismatch`, `replayed_nonce`, `challenge_invalid`, `origin_not_allowed`, `endpoint_not_secure` | blocked |
| 403 | `RelayEnvironmentLinkLimitExceededError` | `maxTunnels: number` | blocked |
| 500 | `RelayEnvironmentLinkFailedError` | `link_persistence_failed`, `credential_persistence_failed`, `replay_persistence_failed`, `internal_error` | transient |
| 503 | `RelayEnvironmentLinkUnavailableError` | `managed_endpoint_not_configured`, `managed_endpoint_provisioning_failed` | transient |
| 500 | `RelayInternalError` | `database_unavailable`, `persistence_failed`, `upstream_unavailable`, `internal_error` | transient |

A relay `environment_link_not_found` is a host state, not a credential problem (the host has not re-established its link). A transport failure should suggest another network (`packages/client-runtime/src/errors/network.ts:3-4`). A `time_window` DPoP failure usually means a wrong device clock.

### 10.10 What the environment checks on mint (for diagnostics)

`POST /api/t3-connect/mint-credential` and `/health` are called by the relay, not by clients. They verify an Ed25519 relay JWT (`typ` `t3-cloud-mint+jwt` or `t3-cloud-health+jwt`, `iss` relay issuer, `aud` `t3-env:<environmentId>`, lifetime at most 5 min with 60 s skew, scope exactly `environment:connect` or `environment:status`, `cnf.jkt` equal to the client key thumbprint, one-time `jti` and `nonce`) and answer with an Ed25519-signed `t3-env-mint+jwt` (`apps/server/src/cloud/CloudLink.ts:1449-1660`, `apps/server/src/cloud/linkChecks.ts:122-139`). A T3 Connect session never holds `access:*` or `relay:write`.

---

## 11. Local server

### 11.1 Discovery

A running server writes `<base>/userdata/server-runtime.json` (`variant "dev"` servers use `<base>/dev/`) once it is listening, and removes it on shutdown (`apps/server/src/server.ts:740-770`, `apps/server/src/config.ts:132-167`). `<base>` is `T3CODE_HOME` (or `--base-dir`), default `~/.t3` (`apps/server/src/os-jank.ts:105-111`).

Schema (`apps/server/src/serverRuntimeState.ts:11-30`), one JSON line:

| Field | Type | Notes |
| --- | --- | --- |
| `version` | `1` | |
| `pid` | int | server process id |
| `host` | string, optional | bind host as configured |
| `port` | int | |
| `origin` | string | `http://<host or 127.0.0.1>:<port>`; wildcard hosts map to `127.0.0.1` |
| `devUrl` | string, optional | set when the server fronts a dev web server |
| `startedAt` | ISO string | |
| `serviceManaged` | bool, optional | true when the boot-service launcher supervises the server |

The official `t3 pair` discovery (`apps/server/src/cli/pair.ts:255-290`) does: read the file, check `isProcessAlive(pid)` (guards against a dead server's stale file and a reused port), then `GET <origin>/.well-known/t3/environment` with a 2.5 s timeout, and only then use it. A native client should do the same. **Reading `~/.t3` files is read-only discovery; never write there.** For the user's live service the file is at `~/.t3/userdata/server-runtime.json` (the live service listens on port 3773, `CLAUDE.md`).

Default port is 3773 (`apps/server/src/config.ts:23`); in `web` mode an unspecified port picks the first free port starting there (`apps/server/src/cli/config.ts:300-309`).

### 11.2 Pairing a local server

A local server has no credential until one is minted. Ways to get a first pairing code:

- `t3 serve` prints `T3 Code server is ready.`, `Connection string:`, `Token:` and `Pairing URL: http://<host>:<port>/pair#token=<code>` plus a QR code (`apps/server/src/startupAccess.ts:122-131`). The startup credential has administrative scopes and lasts 5 minutes.
- `t3 pair` on a running server mints a one-time credential (`apps/server/src/cli/pair.ts`); `t3 auth pairing create` and `t3 auth session issue` exist (`apps/server/src/cli/auth.ts:85-248`). `--scope` (repeatable) narrows the grant.
- In the app, an already-paired admin client can call `POST /api/auth/pairing-token`.

Then follow section 4.3. Note the `loopback-browser` policy only changes how the bundled web app signs in; bearer pairing works the same way (recorded against a `loopback-browser` sandbox).

### 11.3 `t3 serve` flags and environment variables

Command files in `apps/server/src/cli/`: `serve` (headless, no browser) and `start` (`server.ts:55-71`), `pair`, `auth`, `connect`, `project`, `update`, `service`, `app`, `browser`, `trace`, `theme`, `triage`, `uninstall`. Flags (`apps/server/src/cli/config.ts:29-84`) with their environment equivalents (`:88-165`); flag beats env beats bootstrap-channel value:

| Flag | Env | Meaning |
| --- | --- | --- |
| `--mode` | `T3CODE_MODE` | `web` (default) or `desktop` |
| `--port` | `T3CODE_PORT` | HTTP and WebSocket port |
| `--host` | `T3CODE_HOST` | bind interface; default unset (all interfaces) in web mode, `127.0.0.1` in desktop mode |
| `--base-dir` | `T3CODE_HOME` | data directory (default `~/.t3`), state under `userdata/` |
| `--dev-url` | `VITE_DEV_SERVER_URL` | dev web URL |
| `--no-browser` | `T3CODE_NO_BROWSER` | do not open a browser |
| `--bootstrap-fd` | `T3CODE_BOOTSTRAP_FD` | read one-time bootstrap secrets from a file descriptor (desktop launcher) |
| `--auto-bootstrap-project-from-cwd` | `T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD` | |
| `--log-websocket-events` (`--log-ws-events`) | `T3CODE_LOG_WS_EVENTS` | |
| `--tailscale-serve`, `--tailscale-serve-port` | `T3CODE_TAILSCALE_SERVE`, `T3CODE_TAILSCALE_SERVE_PORT` | publish over Tailscale HTTPS |
| (none) | `T3CODE_LOG_LEVEL`, `T3CODE_TRACE_*`, `T3CODE_OTLP_*` | logging, tracing, OTLP export |
| (none) | `T3CODE_TELEMETRY_ENABLED` | analytics; default true (`apps/server/src/telemetry/AnalyticsService.ts:76`) |
| (none) | `T3CODE_DEV_AUTH_TOKEN`, `T3CODE_DEV_ALLOWED_ORIGINS` | dev only (needs a dev URL); ignore |

Recorded sandbox command (`scripts/sandbox-server`): `t3 serve --base-dir <dir> --port 47391 --host 127.0.0.1 --no-browser` with `T3CODE_HOME=<dir>` and `T3CODE_TELEMETRY_ENABLED=false`.

Server home layout, for orientation only (`apps/server/src/config.ts:132-167`): `<base>/userdata/` holds `statev2.sqlite`, `attachments/`, `logs/`, `keybindings.json`, `settings.json`, `themes/`, `environment-id`, `server-runtime.json`, `secrets/`; `<base>/worktrees/` and `<base>/caches/` sit beside it. A remote native client never touches these.

### 11.4 The `env -i` caveat

The live T3 service launcher passes its children `T3_SERVICE_LAUNCHER_CONTEXT` (a JSON launcher context: `protocol`, `childVersion`, `update?`) plus an IPC channel, and shells started under it inherit `T3CODE_HOME`, `T3_SERVICE_LAUNCHER_CONTEXT` and `T3_BOOT_SERVICE_UNIT` (`apps/server/src/cloud/serviceProtocol.ts:6-45`, `CLAUDE.md`). A server started from such a shell reads the variable at startup (`apps/server/src/cloud/ServiceLauncherClient.ts:111-132`):

- the context is decoded; a malformed value fails startup (`decode-context`);
- the context's `childVersion` must equal the binary's version, otherwise startup fails (`version-mismatch`);
- if a context is present but the process has no IPC channel to a parent, startup fails (`ipc-unavailable`). Observed: the process exits with code 1 and logs `ServiceLauncherClientError: The service launcher IPC channel is unavailable.` before the HTTP server binds;
- when it does have a channel, the server sets `managed = true`, writes `serviceManaged: true` into `server-runtime.json` and asks the launcher for updates, that is, it **attaches to the live service launcher**.

An inherited `T3CODE_HOME` additionally points the new server at the user's real data directory. For any test or helper server, start with a clean environment, for example `env -i HOME=... USER=... PATH=... T3CODE_HOME=<sandbox> T3CODE_TELEMETRY_ENABLED=false <t3> serve --base-dir <sandbox> --port <free> --host 127.0.0.1 --no-browser`, and pass only variables you mean to set (`scripts/sandbox-server`). The exact failure mode of an inherited context (which of the three errors above, or a silent attach) depends on the shell and was not run (**UNVERIFIED**; the three outcomes are read from source). Never start a server against `~/.t3` and never stop the live service.

---

## 12. Open questions

Every item below is **UNVERIFIED**: no source line or recording confirmed it.

**Transport**

1. Server reply to a client `Interrupt` for a stream (the `Exit` shape and timing). No recording sent `Interrupt`.
2. Whether the server ever sends array frames (several messages in one text frame) or `Eof`. Not seen in any recording; accept both.
3. Whether the official client gates `requestCompletionMarker` and `acceptBoundedSnapshot` on the `shellResumeCompletionMarker` and `threadResumeCompletionMarker` flags. The recorded server accepted both.
4. Whether `traceparent`/`b3` headers are sent by default by the official HTTP client (irrelevant to correctness).

**Orchestration**

5. `creationSource` for a native client: `"web"` is what works; there is no `"desktop"` literal. A product decision whether to ask upstream for a new literal.
6. The `holdQueue` / resume behavior beyond the `queued-run.cancel` and `run.interrupt` cases recorded (restart recovery, `queue.resume`).
7. Wire shapes of `user_input_request` answers (`runtime-request.respond` with `answers`), `thread.fork`, `checkpoint.rollback`, `orchestration.launchThread`, `thread.snooze`, pins and settle commands: read from schema, never recorded.
8. Whether `requestId` echoes verbatim for numeric ids (the recorder always used strings).
9. Exact ordering guarantee between a command `Exit` and the events it produced (observed: `Exit` first, events a few ms later).
10. Turn item `ordinal = runOrdinal * 1,000,000 + n` is observed, not documented.
11. `latestVisibleMessage` is always `null` in this build; whether later builds fill it.

**Auth and pairing**

12. Whether the server upper-cases pairing codes typed by users (nothing in the server path does).
13. Whether a DPoP session's server-side socket close at 1 hour matches the docs statement "Credential expiry does not close the socket" (`docs/internals/connection-runtime.md:40-41`). C read the source as "the server closes it"; not run.

**T3 Connect**

14. How a third-party native app obtains a Clerk session and a `t3-relay` JWT (section 10.2). The relay's `/v1/client/dpop-token` accepts only that JWT. Whether the CLI's public OAuth client (`hzxSgY2cH10sDU2r`, redirect `127.0.0.1:34338`) may be used by another app, and whether Clerk allows such sign-ups, is unconfirmed.
15. The relay schema accepts only the client ids `t3-web` and `t3-mobile` (`infra/relay/src/auth/RelayTokens.ts:52`). Whether a native macOS app should present as `t3-web` (as the official desktop renderer does) is a product decision.
16. Secure Enclave keys for the DPoP proof were not tested; the official mobile app uses a software key.
17. The production managed-tunnel zone (`RELAY_TUNNEL_ZONE_NAME`) is not in source.
18. Relay-side routes `GET /v2/client/devices`, `POST /v1/client/environment-links` bodies were read from the contract only.

**Server features (field-level shapes not summarised)**

19. Pull requests (`pullRequests.*`), previews (`preview.*`, `subscribePreviewEvents`), devices (`device.*`), scheduled tasks, usage summary and rates, diagnostics, background policy, ACP registry, agent sessions, MCP apps, provider auth and install states, `ServerSettingsPatch`, `providerInstanceMutation`: method names, payload type names and scopes only (sections 6 and 9).
20. Keybinding `key` string grammar and `when` expression syntax (the resolved form is known).
21. UTF-8 handling across `terminal.output` events (split surrogate pairs); resize debounce intervals.
22. Whether `vcs.listRefs.refresh: true` fetches from remotes; the worktree path the server picks when `vcs.createWorktree.path` is `null`; how the `review.*` cwd guard treats projects outside the server launch cwd.
23. Whether any MCP tool lets agents drive terminals.
24. Resolved 2026-10-09: a server started with an inherited `T3_SERVICE_LAUNCHER_CONTEXT` and no IPC channel exits with code 1 at startup, logging `ServiceLauncherClientError: The service launcher IPC channel is unavailable.` from `cloud.service_launcher_client.resolve_startup` (observed on the sandbox, see section 11.4).
