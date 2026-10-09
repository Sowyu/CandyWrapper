# T3 Code satellite contracts: field-level domain model

Source checkout: /Users/mrm/CandyWrapper-research/t3code, tag v0.0.46-nightly.20261009.2861 (HEAD 3b6af0bd1).
Effect version 4.0.1 (pnpm-workspace.yaml:49). The local effect patch (patches/effect@4.0.1.patch) only touches ai/McpServer, http/HttpClientResponse and rpc/RpcClient files, not Schema.

Citation convention: `name.ts:N` means `packages/contracts/src/name.ts:N`. Every other path is repo-relative.

Research was read-only. Effect's own source is not in the checkout (no node_modules), so Effect semantics below are backed by in-repo tests and comments where cited. Anything else is marked UNVERIFIED.

---

## 0. Scope: what orchestrationV2.ts imports

orchestrationV2.ts:1-74 contains all import statements of the file (Effect modules plus the following contract modules).

| Module | Symbols imported | Main V2 usage sites (orchestrationV2.ts line) |
|---|---|---|
| composerContext.ts | OrchestrationMessageContext | 1125, 1387, 2165, 2847, 2950, 3198 |
| baseSchemas.ts | CheckpointId, CheckpointRef, CheckpointScopeId, CommandId, ContextHandoffId, ContextTransferId, EventId, IsoDateTime, MessageId, NodeId, ForwardCompatibleUnion, ForwardCompatibleUnionArray, hasUnknownUnionTag, isUnknownUnionMember, NonNegativeInt, PlanId, PositiveInt, ProjectId, ProviderSessionId, ProviderThreadId, ProviderTurnId, RawEventId, RunAttemptId, RunId, RuntimeRequestId, ScheduledTaskId, ThreadId, TrimmedNonEmptyString, TurnItemId | everywhere; forward-compat helpers at 1586-1603, 1806, 2386, 3312 |
| chatAttachment.ts | ChatAttachment | 1126, 1388, 1395, 2166, 2173, 2848, 2957, 3199 |
| checkpointDiff.ts | OrchestrationGetFullThreadDiffInput, OrchestrationGetFullThreadDiffResult, OrchestrationGetTurnDiffInput, OrchestrationGetTurnDiffResult | RPC schema map 3570-3577 |
| modelSelection.ts | ModelSelection | 370, 546, 678, 834, 1517, 1842, 2292, 2619, 2828, 2851, 3010, 3052, 3190 |
| threadPullRequest.ts | ThreadLinkedPullRequest, ThreadPullRequestLink, ThreadPullRequestKey, ThreadPullRequestLinkSource, ThreadPullRequestSnapshot, ThreadPullRequestStack, ThreadPullRequestWatch | 377-380, 1848-1851, 2753-2803, 3072-3075 |
| providerPolicy.ts | ProviderApprovalDecision, ProviderApprovalOption, ProviderInteractionMode, ProviderRequestKind, ProviderUserInputAnswers, UserInputAttachments, UserInputAttachmentAnswerPayload, RuntimeMode | see section 7 |
| providerInstance.ts | ProviderDriverKind, ProviderInstanceId | see section 3 |
| orchestrationProject.ts | OrchestrationProjectShell | 1941, 1962, 3158 |
| providerRuntime.ts | TurnTokenUsage, ToolActivitySurface, ToolActivityIcon, ToolActivitySource, ThreadTokenUsageSnapshot | 1002, 1318-1320, 895 |

Transitive dependencies covered below: model.ts (ProviderOptionSelections via ModelSelection), project.ts (ProjectScript, ReceivedProjectIcon via OrchestrationProjectShell), environment.ts (RepositoryIdentity, ThreadEnvMode via OrchestrationProjectShell), pullRequest.ts (PullRequestState, PullRequestReviewDecision, PullRequestChecksState, PullRequestMergeability, PullRequestActor via threadPullRequest.ts), providerUsageLimits.ts (ProviderUsageLimitsUpdate, imported at providerRuntime.ts:17 and only used inside ProviderRuntimeEvent), usageLimitSourceId.ts.

Not imported by orchestrationV2.ts (verified by grep over every importer in packages/contracts/src): provider.ts, worktreeSetup.ts, secretRequest.ts, threadTitle.ts, threadSearch.ts, assistantCitations.ts, usage.ts, mcpApps.ts. Several of them still reach the wire through rpc.ts; this is noted per section.

---

## 1. Global wire rules (apply to every table)

### 1.1 Transport
- Effect RPC with JSON serialization on both ends: apps/server/src/ws.ts:3190 (`RpcSerialization.layerJson`), packages/client-runtime/src/rpc/session.ts:211.
- Clients decode with the JSON codec derived from each schema (`Schema.toCodecJson`), see the comment "How clients decode: the JSON wire codec over the runtime schema" at baseSchemas.test.ts:24-26.

### 1.2 Optionality notation
| Notation | Effect source | Meaning on the JSON wire | Evidence |
|---|---|---|---|
| req | plain field | key required, value not null | |
| opt | `Schema.optional(T)` | key may be absent. `null` is NOT accepted. In-process an explicit `undefined` is accepted. | project.test.ts:154-157 |
| optKey | `Schema.optionalKey(T)` | key may be absent. Explicit `undefined` is rejected in-process. `null` NOT accepted. | composerContext.ts:158-160, composerContext.test.ts:225 |
| null | `Schema.NullOr(T)` | key required, value may be `null` | |
| opt or null | `Schema.optional(Schema.NullOr(T))` | key absent, `null`, or value | |
| default(v) | `T.pipe(Schema.withDecodingDefault(Effect.succeed(v)))` | key may be absent in input, decodes to v. The decoded type is required, so a producer encoding a decoded value emits the key (inferred, UNVERIFIED against Effect source). | threadPullRequest.test.ts:58-84 |
| ctorDefault(v) | `Schema.withConstructorDefault` | only affects `.make()`; treat as opt on the wire (UNVERIFIED against Effect source) | |

Swift guidance: req maps to a non-optional property (decode fails on a missing key). opt and optKey map to Optional with `encodeIfPresent` (never encode null). null maps to Optional that is always encoded (nil becomes JSON null). opt or null needs a tri-state if absent and null must be distinguished on round-trip.

### 1.3 Strings
- TNES = TrimmedNonEmptyString (baseSchemas.ts:27). It is TrimmedString (baseSchemas.ts:7-15), which trims on decode AND on encode (baseSchemas.test.ts:271: "  a b  " encodes to "a b"), plus the non-blank check `value.trim().length > 0` (baseSchemas.ts:22-26). Whitespace-only values fail make, encode and decode (baseSchemas.test.ts:258-265). JSON Schema is `{type:"string", minLength:1}` (baseSchemas.test.ts:272-275).
- JS `trim()` removes Unicode whitespace including U+00A0, U+2028, U+3000 and U+FEFF; the property tests pad with exactly such characters (baseSchemas.test.ts:194). Swift `CharacterSet.whitespacesAndNewlines` does not contain U+FEFF, so trim with a JS-equivalent set.
- TS = TrimmedString: trimmed, may be empty.
- Brands (`Schema.brand`) have no runtime form: a branded id is a plain JSON string (baseSchemas.test.ts:267-271).
- `Schema.isMaxLength` and `Schema.isPattern` apply to the decoded (trimmed) value. The length unit is presumably JS `.length` (UTF-16 code units), UNVERIFIED against Effect source; use `utf16.count` in Swift.
- Patterns are JavaScript regexes; flags are noted where present.

### 1.4 Numbers
- `Schema.Int`, NonNegativeInt (integer >= 0, baseSchemas.ts:29), PositiveInt (integer >= 1, baseSchemas.ts:30) are JSON integers.
- Plain `Schema.Number` is a JSON number. How toCodecJson treats NaN or Infinity is UNVERIFIED. Producers here emit finite values; ThreadTokenUsageSnapshot.cost.amount is explicitly finite-checked.
- `Schema.Literal(1)` (every `version` field in these files) is the JSON number 1.

### 1.5 Timestamps
- IsoDateTime is `Schema.String` (baseSchemas.ts:47) with NO format validation.
- The server produces these strings with Effect `DateTime.formatIso` (example apps/server/src/orchestration-v2/Orchestrator.ts:557). Fixtures use "2026-01-01T00:00:00.000Z" (threadPullRequest.test.ts:18).
- No satellite file uses `Schema.DateTimeUtc`. orchestrationV2.ts itself uses `Schema.DateTimeUtc` and `Schema.DateTimeUtcFromString` for its own fields; those are ISO strings on the wire as well (ISO string decoded into DateTime through toCodecJson at baseSchemas.test.ts:18-37; V2 message JSON fixture at composerContext.test.ts:277-291).
- Swift: decode as String and parse leniently (fractional seconds optional); encode as ISO-8601 UTC with milliseconds and "Z".

### 1.6 Other encoding facts
- Excess keys are ignored on decode (providerRuntime.test.ts:72-96 decodes an event carrying an extra `sessionId`).
- `Schema.TaggedStruct("x", {...})` puts `"_tag": "x"` on the wire (web fixtures apps/web/src/components/chat/MessagesTimeline.logic.test.ts:3083, 3129-3130; apps/web/src/composerDraftStore.test.ts:468; apps/web/src/components/chat/ChatComposer.tsx:6105).
- `Schema.TaggedError` classes encode with `"_tag": "<ClassName>"` plus their fields. The JSON form of `cause: Schema.Defect()` is UNVERIFIED; treat it as opaque.

### 1.7 Forward compatibility summary
Tolerant of unknown variants in these satellite files:
- ChatAttachment (ChatUnknownAttachment member).
- ComposerContextRecord (UnknownContextRecord) and OrchestrationMessageContext.records (ForwardCompatibleArray drops undecodable records).
- ReceivedProjectIcon (unknown `kind` decodes to null).
- ForwardCompatibleArray fields in providerUsageLimits.ts and usage.ts.
- ProviderDriverKind and ProviderInstanceId (open slugs), ComposerContextKind (open pattern).

Everything else is a closed literal set or plain union. An unknown literal from a newer server fails the enclosing value (examples: ThreadPullRequestLinkSource, ToolActivityIcon `_tag`, ProviderOptionDescriptor `type`, RuntimeMode, WorktreeSetupStageId). In V2 the turn item union is wrapped in ForwardCompatibleUnion / ForwardCompatibleUnionArray keyed on `type` (orchestrationV2.ts:1586-1603, 1806, 2386, 3312), so an unknown turn item type is skipped, but a known turn item that contains an unknown nested literal still fails to decode.

---

## 2. baseSchemas.ts

### 2.1 Primitives and client enums
| Export | Definition | Wire | Constraints / literals | Line |
|---|---|---|---|---|
| TrimmedString | String decodeTo String, trim on decode and encode | string | may be empty | baseSchemas.ts:7-15 |
| TrimmedNonEmptyString | TrimmedString.check(isNonBlank) | string | trim().length > 0 | baseSchemas.ts:22-27 |
| NonNegativeInt | Int, >= 0 | integer | | baseSchemas.ts:29 |
| PositiveInt | Int, >= 1 | integer | | baseSchemas.ts:30 |
| PortSchema | Int between 1 and 65535 | integer | | baseSchemas.ts:31 |
| DpopFailureReason | Literals | string | "time_window", "key_mismatch", "request_mismatch", "token_mismatch", "replay", "invalid_proof" | baseSchemas.ts:37-44 |
| IsoDateTime | Schema.String | string | none | baseSchemas.ts:47 |
| RpcClientId | NonNegativeInt + brand "RpcClientId" | integer | | baseSchemas.ts:336 |
| ClientSurface | Literals | string | "web", "desktop", "mobile", "cli" (optional wherever it appears, comment 339-344) | baseSchemas.ts:345 |
| ClientOs | Literals | string | "macOS", "Windows", "Linux", "iOS", "Android", "ChromeOS", "other", "unknown" | baseSchemas.ts:348-357 |
| ClientDeviceType | Literals | string | "desktop", "phone", "tablet", "unknown" | baseSchemas.ts:360 |
| ClientWebDeployment | Literals | string | "hosted", "server" | baseSchemas.ts:363 |
| ClientConnectionMethod | Literals | string | "direct", "ssh", "relay", "unknown" | baseSchemas.ts:366 |

### 2.2 Entity id brands
All are `makeEntityId(brand)` = TNES + `Schema.brand(brand)` (baseSchemas.ts:310-312): trimmed, non-blank, no length cap, no pattern. All are covered by the trim and blank property tests (baseSchemas.test.ts:154-276). Clients must treat every id as an opaque string. The "producer format" column documents what this build generates; it is an implementation detail, not contract.

IdAllocator.ts below means packages/provider-core/src/server/IdAllocator.ts. Every part after the prefix is passed through encodeURIComponent and the parts are joined with ":" (IdAllocator.ts:192-195), so nested ids appear percent-encoded (":" becomes "%3A"). `<uuid>` is a random UUID v4 (IdAllocator.ts:235-253). This layer is the production one (apps/server/src/orchestration-v2/runtimeLayer.ts:97, 107, 115).

| Brand | Line | Imported by V2 | Producer format observed |
|---|---|---|---|
| ThreadId | 314 | yes | Clients: bare lowercase UUID v4 (apps/web/src/lib/utils.ts:46). Server allocate: `thread[:fixture:<n>][:project:<projectId>]:<uuid>` (IdAllocator.ts:297-306). Derived: `thread:delegated-task:<commandId>` (IdAllocator.ts:395-396), `thread:provider:<driver>[:provider-instance:<id>]:native-thread:<nativeId>` (IdAllocator.ts:197-214) |
| ProjectId | 316 | yes | Clients: bare UUID v4 (apps/web/src/lib/utils.ts:44). Server fixtures: `project:fixture:<name>:<uuid>` (IdAllocator.ts:290-296) |
| EnvironmentId | 318 | no (used by ThreadContextRecord, AssistantCitation) | |
| CommandId | 320 | yes | Clients: bare UUID v4 (packages/client-runtime/src/operations/commands.ts:261-267; apps/web/src/components/ChatView.tsx:8466). Derived client ids `<commandId>:model-selection` (commands.ts:595) and `<commandId>:detach:<sessionId>` (commands.ts:928). Server fixtures `command:fixture:<fixture>:<command>:<uuid>` (IdAllocator.ts:259-265) |
| EventId | 322 | yes | `event[:thread:<id>][:command:<id>][:provider-session:<id>]:<uuid>` (IdAllocator.ts:266-278); importers use their own prefixes (apps/server/src/orchestration-v2/legacy/LegacyV1ThreadImporter.ts:323) |
| MessageId | 324 | yes | Clients: bare UUID v4 (apps/web/src/lib/utils.ts:50). Server: `message:thread:<threadId>:ordinal:<n>:<uuid>` (IdAllocator.ts:307-313); derived `message:delegated-task:<commandId>` (397-398), `message:provider:<driver>:native-item:<id>` (422-425) |
| TurnId | 326 | no (V1-era provider.ts and providerRuntime.ts) | |
| RunId | 328 | yes | `run:thread:<threadId>:ordinal:<n>` (IdAllocator.ts:404) |
| RunAttemptId | 330 | yes | `run-attempt:run:<runId>:attempt:<n>` (IdAllocator.ts:405-408) |
| NodeId | 332 | yes | `node:run:<runId>:root` (409), `node:run:<runId>:attempt:<n>:root` (410-411), `node:delegated-task:<commandId>` (394), `node:provider:<driver>:native-item:<id>` (420-421), `node:runtime-request:<requestId>` (430) |
| AuthSessionId | 334 | no | |
| ProviderItemId | 369 | no (providerRuntime ProviderRefs, provider.ts ProviderEvent) | |
| ProviderSessionId | 371 | yes | `provider-session:provider-instance:<id>:thread:<threadId>:<uuid>` (IdAllocator.ts:314-320) or derived `provider-session:provider-instance:<id>:shared` (390-393) |
| ProviderThreadId | 373 | yes | `provider-thread:provider:<driver>[:provider-instance:<id>]:native-thread:<nativeId>` (IdAllocator.ts:216-233) |
| ProviderTurnId | 375 | yes | `provider-turn:provider:<driver>:native-turn:<nativeId>` (IdAllocator.ts:416-419) |
| RuntimeSessionId | 377 | no | |
| RuntimeItemId | 379 | no (providerRuntime envelope) | |
| TurnItemId | 381 | yes | `turn-item:message:<messageId>` (IdAllocator.ts:412), `turn-item:run:<runId>:signal:<signal>` (413-414), `turn-item:provider:<driver>:native-item:<id>` (426-429), `turn-item:runtime-request:<requestId>` (431-432), `turn-item:delegated-task:<commandId>` (399-400), `turn-item:created-thread:<commandId>` (401-402); ad hoc `turn-item:fork:<threadId>` (apps/server/src/orchestration-v2/ProjectionStore.ts:1237) |
| RuntimeRequestId | 383 | yes | `runtime-request:provider:<driver>[:provider-turn:<id>][:native-request:<id>]:<uuid>` (IdAllocator.ts:321-334) |
| RuntimeTaskId | 385 | no (providerRuntime task payloads) | |
| ScheduledTaskId | 387 (type alias at 391) | yes | |
| SecretRef | 389 | no | one-use handle to a stored secret (comment 388) |
| ApprovalRequestId | 392 | no (provider.ts) | |
| CheckpointRef | 394 | yes | git ref names: `refs/t3/checkpoints/<base64url(threadId)>/turn/<n>` (apps/server/src/checkpointing/Utils.ts:4-10) and `refs/t3/checkpoints/<base64url(first 32 hex chars of sha256(scopeId))>/ordinal/<n>` (apps/server/src/orchestration-v2/CheckpointService.ts:160-171) |
| CheckpointId | 396 | yes | deterministic `checkpoint:scope:<scopeId>:name:<name>` (IdAllocator.ts:341-346) |
| CheckpointScopeId | 398 | yes | deterministic `checkpoint-scope:thread:<threadId>:name:<name>` (IdAllocator.ts:335-340) |
| ContextHandoffId | 400 | yes | `context-handoff:thread:<t>:from-provider-instance:<a>:to-provider-instance:<b>:<uuid>` (IdAllocator.ts:347-360) |
| ContextTransferId | 402 | yes | `context-transfer:type:<type>:source-thread:<s>:target-thread:<t>:<uuid>` (IdAllocator.ts:361-374) |
| RawEventId | 404 | yes | `raw-event:provider-session:<id>[:method:<m>]:<uuid>` (IdAllocator.ts:279-289) |
| PlanId | 406 | yes | `plan:thread:<t>:provider:<driver>[:run:<runId>]:<uuid>` (IdAllocator.ts:375-387) |

Client UUID format: lowercase hex 8-4-4-4-12 with version 4 and RFC 4122 variant bits set from crypto.getRandomValues (apps/web/src/lib/utils.ts:36-42).

### 2.3 Forward-compatibility combinators
| Export | Behavior | Line |
|---|---|---|
| ForwardCompatibleOptional(value) | optionalKey; an unknown or invalid raw value decodes as absent; encode is plain | baseSchemas.ts:55-69 |
| ForwardCompatibleNullable(value) | unknown value or missing key decodes as null; encode is plain | baseSchemas.ts:76-87 |
| OmittedWhenNull(value) | missing or unknown key decodes as null; null encodes as a missing key | baseSchemas.ts:95-112 |
| ForwardCompatibleArray(element) | each element decoded through its own schema; elements that fail decode are dropped; elements that fail encode are dropped before the wire; null holes from older servers are dropped (baseSchemas.test.ts:75-80); decoded arrays never contain holes (baseSchemas.test.ts:82-90) | baseSchemas.ts:128-176 |
| UnknownUnionMember | class {tag, value}; decode-only marker for an unknown discriminator | baseSchemas.ts:183-190 |
| ForwardCompatibleUnion(members, tag) | known tag decodes through its member (broken known payload still fails); unknown tag decodes to UnknownUnionMember; encoding an unknown member fails | baseSchemas.ts:201-236; tests baseSchemas.test.ts:93-116 |
| hasUnknownUnionTag(members, tag) | predicate on raw undecoded values | baseSchemas.ts:243-253 |
| isUnknownUnionMember(value) | instanceof check | baseSchemas.ts:256-258 |
| ForwardCompatibleUnionArray(members, tag) | array of ForwardCompatibleUnion that drops unknown members; encodes as a plain array | baseSchemas.ts:265-286; tests baseSchemas.test.ts:118-152 |
| knownTags (internal) | every member must have a string literal tag field | baseSchemas.ts:288-305 |

---

## 3. providerInstance.ts

| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| (const) PROVIDER_SLUG_MAX_CHARS | | | | 64 | providerInstance.ts:40 |
| (const) PROVIDER_SLUG_PATTERN | | | | `/^[a-zA-Z][a-zA-Z0-9_-]*$/` | providerInstance.ts:49 |
| (const) env var name limits | | | | max 128, `/^[a-zA-Z_][a-zA-Z0-9_]*$/` | providerInstance.ts:50-51 |
| slugSchema (internal) | | TNES | | max 64 + slug pattern | providerInstance.ts:53-56 |
| ProviderDriverKind | | slug + brand "ProviderDriverKind" | | OPEN set: unknown drivers must decode, runtime marks them unavailable (module doc 16-28) | providerInstance.ts:70 |
| isProviderDriverKind | | function | | | providerInstance.ts:73-75 |
| ProviderInstanceId | | slug + brand "ProviderInstanceId" | | routing key on all V2 shapes | providerInstance.ts:82 |
| ProviderInstanceRef | instanceId | ProviderInstanceId | req | | providerInstance.ts:92 |
| | driver | ProviderDriverKind | req | | providerInstance.ts:93 |
| ProviderInstanceEnvironmentVariableName | | TNES | | max 128, env name pattern | providerInstance.ts:97-100 |
| ProviderInstanceEnvironmentVariable | name | ProviderInstanceEnvironmentVariableName | req | | providerInstance.ts:105 |
| | value | String | default("") | | providerInstance.ts:106 |
| | sensitive | Boolean | default(false) | | providerInstance.ts:107 |
| | valueRedacted | Boolean | optKey | | providerInstance.ts:108 |
| ProviderInstanceEnvironment | | Array(ProviderInstanceEnvironmentVariable) | | | providerInstance.ts:112 |
| ProviderInstanceConfig | driver | ProviderDriverKind | req | | providerInstance.ts:125 |
| | displayName | TNES | opt | | providerInstance.ts:126 |
| | accentColor | TNES | opt | | providerInstance.ts:127 |
| | environment | ProviderInstanceEnvironment | optKey | | providerInstance.ts:128 |
| | enabled | Boolean | optKey | | providerInstance.ts:129 |
| | config | Unknown | optKey | driver-owned, preserved verbatim | providerInstance.ts:130 |
| ProviderInstanceMutation | operation "create" | {instanceId, instance: ProviderInstanceConfig} | req | | providerInstance.ts:136-140 |
| | operation "upsert" | {instanceId, instance} | req | | providerInstance.ts:141-145 |
| | operation "remove" | {instanceId} | req | | providerInstance.ts:146-149 |
| ProviderInstanceConfigMap | | Record(ProviderInstanceId, ProviderInstanceConfig) | | keys must match slug (providerInstance.test.ts:199) | providerInstance.ts:157 |
| defaultInstanceIdForDriver | | function | | instance id string equals the driver string | providerInstance.ts:167-168 |

Tests: ids are trimmed before validation (providerInstance.test.ts:44), longer than 64 rejected (providerInstance.test.ts:48), must start with a letter (modelSelection.test.ts:89-99).

Built-in driver kinds in this build (apps/server/src/provider/builtInDrivers.ts:55-65, order codex, claudeAgent, cursor, grok, opencode, antigravity, pi, muse, acpRegistry). Literal sources: "codex" (apps/server/src/provider/Drivers/CodexDriver.ts:79), "claudeAgent" (apps/server/src/provider/Drivers/ClaudeDriver.ts:74), "acpRegistry" (apps/server/src/provider/Drivers/AcpRegistryDriver.ts:63), "antigravity" (apps/server/src/provider/Drivers/AntigravityDriver.ts:65), "cursor" (packages/provider-cursor/src/server/driver.ts:46), "grok" (packages/provider-grok/src/server/adapter.ts:76), "opencode" (packages/provider-opencode/src/server/driver.ts:79), "muse" (packages/provider-muse/src/server/driver.ts:40), "pi" (packages/provider-pi/src/server/adapter.ts:97). Note usage.ts uses a different closed vocabulary ("claude", not "claudeAgent"), see section 22.

Client-minted instance id example: `codex_<uuid>` (apps/web/src/components/settings/AddCodexAccountDialog.tsx:57).

V2 usage: ProviderDriverKind at orchestrationV2.ts:100 (OrchestrationV2ProviderRef.driver), 670, 728, 873, 1501 (null), 1560, 1621, 1639 (opt), 2279 (null), 2335, 2627. ProviderInstanceId at 173-174 (null), 369, 545, 604, 671, 729, 874, 964 (null), 1512-1513, 1548, 1561, 1622, 1640 (opt), 1841, 1890 (providerInstanceHistory, optional array with a pipe), 2290-2291, 2323, 2336.

---

## 4. modelSelection.ts

### 4.1 ModelSelection (modelSelection.ts:34-62)
Canonical wire shape (ModelSelectionWire, modelSelection.ts:16-20):

| Field | Type | Opt | Constraints | Line |
|---|---|---|---|---|
| instanceId | ProviderInstanceId | req | slug rules (section 3) | modelSelection.ts:17 |
| model | TNES | req | provider-owned model slug, no pattern | modelSelection.ts:18 |
| options | ProviderOptionSelections | optKey | array of {id, value}; legacy object accepted on decode only | modelSelection.ts:19 |

Decode input (ModelSelectionSource, modelSelection.ts:22-27): `provider` opt Unknown, `instanceId` opt Unknown, `model` Unknown, `options` opt Unknown.
- Decode (modelSelection.ts:38-51): instanceId comes from `instanceId` when it is not undefined, else from legacy `provider` when it is a string; `options` copied only when not undefined.
- Encode (modelSelection.ts:52-59): always `{instanceId, model}` plus `options` when defined. Legacy `provider` is never emitted.
- Example canonical JSON: `{"instanceId":"codex","model":"gpt-6-astra","options":[{"id":"reasoningEffort","value":"high"}]}`.
- Tests: legacy `provider` promoted (modelSelection.test.ts:25-36), explicit instanceId (38-46), instanceId wins over provider (48-57), unknown driver slug accepted (59-71), canonical encode (73-87), malformed id rejected (89-99), legacy object options normalized and re-encoded as array (101-124).
- Equality used by clients: option order and an omitted vs empty options list are ignored (packages/shared/src/model.ts:106-122). createModelSelection omits `options` when empty (packages/shared/src/model.ts:474-485).

V2 usage: required in OrchestrationV2AppThread (orchestrationV2.ts:370), OrchestrationV2Run (546), OrchestrationV2ThreadShell (1842), commands thread.create (2619), thread.model-selection.set (2828), delegated_task.request (3010), provider.switch (3052), OrchestrationV2ThreadLaunchInput (3190). Optional in OrchestrationV2Subagent (678), OrchestrationV2ProviderThreadNativeMetadata (834), message.dispatch (2851). Arrays `fromModelSelections` opt (1517, 2292).

---

## 5. model.ts

### 5.1 Option descriptors and selections
| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ProviderOptionDescriptorType | | Literals | | "select", "boolean" | model.ts:7 |
| ProviderOptionChoice | id | TNES | req | | model.ts:11 |
| | label | TNES | req | | model.ts:12 |
| | description | TNES | opt | | model.ts:13 |
| | isDefault | Boolean | opt | | model.ts:14 |
| (base, internal) | id, label | TNES | req | | model.ts:18-22 |
| | description | TNES | opt | | model.ts:21 |
| SelectProviderOptionDescriptor | type | Literal "select" | req | | model.ts:26 |
| | options | ProviderOptionChoice[] | req | | model.ts:27 |
| | currentValue | TNES | opt | | model.ts:28 |
| | promptInjectedValues | TNES[] | opt | values injected into the prompt instead of sent as options (for example Claude "ultrathink") | model.ts:29 |
| BooleanProviderOptionDescriptor | type | Literal "boolean" | req | | model.ts:35 |
| | currentValue | Boolean | opt | | model.ts:36 |
| ProviderOptionDescriptor | | Union(select, boolean) | | plain union on `type`, not forward-compatible | model.ts:40-43 |
| ProviderOptionSelectionValue | | Union(TNES, Boolean) | | strings trimmed and non-blank | model.ts:46 |
| ProviderOptionSelection | id | TNES | req | | model.ts:50 |
| | value | ProviderOptionSelectionValue | req | | model.ts:51 |
| ProviderOptionSelections | | Union(Array(ProviderOptionSelection), legacy object decoded to array) | | always encodes as array (modelSelection.test.ts:121-122) | model.ts:90-93 |
| (internal) LegacyProviderOptionSelectionsObject | | Record(String, Unknown) | | | model.ts:66 |
| (internal) legacy coercion | | | | keys trimmed, empty keys dropped; string values trimmed, empty dropped; booleans kept; numbers, null, objects, arrays dropped | model.ts:96-113 |
| ModelCapabilities | optionDescriptors | ProviderOptionDescriptor[] | opt | | model.ts:126 |
| CustomModelEntry | slug | TNES | req | | model.ts:136 |
| | name | TNES | opt | | model.ts:137 |
| | capabilities | ModelCapabilities | opt | | model.ts:138 |
| CustomModelSetting | | Union(String, CustomModelEntry) | | settings only (settings.ts:636, 674, 782) | model.ts:143 |

Capabilities reach clients as `ServerProviderModel.capabilities: NullOr(ModelCapabilities)` (server.ts:75-86, field at 85).

### 5.2 Constants
| Export | Value | Line |
|---|---|---|
| DEFAULT_MODEL | "gpt-6-astra" | model.ts:155 |
| PREFERRED_DEFAULT_CODEX_MODELS | ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"] | model.ts:162-166 |
| DEFAULT_TEXT_GENERATION_MODEL | "gpt-6-luna" | model.ts:167 |
| ANTIGRAVITY_DEFAULT_MODEL | "antigravity-default" (never sent to ACP) | model.ts:169 |
| DEFAULT_TEXT_GENERATION_REASONING_EFFORT | "low" | model.ts:170 |
| MUSE_DEFAULT_MODEL | "default" (never sent to Muse) | model.ts:173 |
| DEFAULT_MODEL_BY_PROVIDER | codex "gpt-6-astra", claudeAgent "claude-fable-5-1", cursor "auto", grok "grok-build", muse "default", acpRegistry "default", pi "default", opencode "openai/gpt-5", antigravity "antigravity-default" | model.ts:175-187 |
| DEFAULT_TEXT_GENERATION_MODEL_BY_PROVIDER | codex "gpt-6-luna", antigravity "antigravity-default", claudeAgent "claude-haiku-4-5", cursor "composer-2", opencode "openai/gpt-5" | model.ts:190-198 |
| MODEL_SLUG_ALIASES_BY_PROVIDER | codex: "gpt-5-codex" to "gpt-5.4", "5.4" to "gpt-5.4", "5.3" to "gpt-5.3-codex", "gpt-5.3" to "gpt-5.3-codex", "5.3-spark" to "gpt-5.3-codex-spark", "gpt-5.3-spark" to "gpt-5.3-codex-spark"; claudeAgent {}; cursor: "composer" to "composer-2", "composer-1.5" to "composer-1.5", "composer-1" to "composer-1.5", "opus-4.6-thinking" and "opus-4.6" to "claude-opus-4-6", "sonnet-4.6-thinking" and "sonnet-4.6" to "claude-sonnet-4-6", "opus-4.5-thinking" and "opus-4.5" to "claude-opus-4-5"; opencode {} | model.ts:200-224 |
| PROVIDER_DISPLAY_NAMES | antigravity "Antigravity", codex "Codex", claudeAgent "Claude", cursor "Cursor", grok "Grok", muse "Muse Code", acpRegistry "ACP Registry", pi "Pi", opencode "OpenCode" | model.ts:228-238 |

### 5.3 Option ids in practice (reasoning effort, fast mode, context window)
The contract does not enumerate option ids or values. They are provider-owned descriptors delivered per model; a client must render descriptors generically and send back `{id, value}` pairs. Ids observed in production code:
- Codex: "reasoningEffort" select (apps/server/src/provider/CodexProvider.ts:188), "serviceTier" select whose tiers come from the model list, a tier id "fast" named "Fast" (CodexProvider.ts:170-216). Legacy boolean "fastMode" true maps to serviceTier "fast" (apps/server/src/codexModelOptions.ts:7-14).
- Claude: "effort" select (apps/server/src/claudeModelOptions.ts:36; apps/server/src/provider/ClaudeModelCatalog.ts:222), "contextWindow" select (ClaudeModelCatalog.ts:249-254), "fastMode" boolean (claudeModelOptions.ts:39-41), "thinking" boolean (claudeModelOptions.ts:42-44). Effort "ultracode" sets an ultracode setting (claudeModelOptions.ts:48; ClaudeModelCatalog.ts:241). Prompt-injected efforts (for example "ultrathink") are handled by resolvePromptInjectedEffort and applyClaudePromptEffortPrefix (packages/shared/src/model.ts:495-529). Values come from a model manifest (ClaudeModelCatalog.ts:43-76), not from contracts.
- OpenCode: "variant" select with low, medium (default), high, xhigh and "agent" select with build (default), plan (packages/provider-opencode/src/server/status.ts:170-192).
- Pi: "thinking" select (packages/provider-pi/src/server/thinkingCapabilities.ts:36-45). The same id "thinking" is a boolean for Claude, so key handling off descriptor `type`, never off the id.
- Grok: "reasoningEffort" select (packages/provider-grok/src/server/status.ts:200). Muse: "reasoningEffort" select (packages/provider-muse/src/server/modelCatalog.ts:62).

---

## 6. provider.ts

Not imported by orchestrationV2.ts. Only ProviderUploadFeedbackInput / Result / Error reach the WebSocket API (method "provider.uploadFeedback", rpc.ts:393, 1281-1285). The rest are server-internal adapter contracts (V1-era, keyed by TurnId).

| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ProviderSessionStatus (const) | | Literals | | "connecting", "ready", "running", "error", "closed" | provider.ts:29-35 |
| ProviderSession | provider | ProviderDriverKind | req | | provider.ts:38 |
| | providerInstanceId | ProviderInstanceId | opt | | provider.ts:42 |
| | status | ProviderSessionStatus | req | | provider.ts:43 |
| | runtimeMode | RuntimeMode | req | | provider.ts:44 |
| | cwd | TNES | opt | | provider.ts:45 |
| | model | TNES | opt | | provider.ts:46 |
| | threadId | ThreadId | req | | provider.ts:47 |
| | resumeCursor | Unknown | opt | | provider.ts:48 |
| | activeTurnId | TurnId | opt | | provider.ts:49 |
| | createdAt, updatedAt | IsoDateTime | req | | provider.ts:50-51 |
| | lastError | TNES | opt | | provider.ts:52 |
| ProviderSessionStartInput | threadId | ThreadId | req | | provider.ts:57 |
| | provider | ProviderDriverKind | opt | | provider.ts:58 |
| | providerInstanceId | ProviderInstanceId | opt | | provider.ts:60 |
| | cwd, title | TNES | opt | | provider.ts:61-62 |
| | modelSelection | ModelSelection | opt | | provider.ts:63 |
| | resumeCursor | Unknown | opt | | provider.ts:64 |
| | approvalPolicy | ProviderApprovalPolicy | opt | | provider.ts:65 |
| | sandboxMode | ProviderSandboxMode | opt | | provider.ts:66 |
| | runtimeMode | RuntimeMode | req | | provider.ts:67 |
| ProviderSendTurnInput | threadId | ThreadId | req | | provider.ts:72 |
| | continuation | Boolean | opt | internal recovery signal | provider.ts:75 |
| | input | TNES | opt | max 120000 | provider.ts:76-78 |
| | attachments | ChatAttachment[] | opt | getProviderAttachmentLimitError filter | provider.ts:79-83 |
| | modelSelection | ModelSelection | opt | | provider.ts:84 |
| | interactionMode | ProviderInteractionMode | opt | | provider.ts:85 |
| ProviderTurnStartResult | threadId / turnId / resumeCursor | ThreadId / TurnId / Unknown | req / req / opt | | provider.ts:89-93 |
| ProviderInterruptTurnInput | threadId / turnId | ThreadId / TurnId | req / opt | | provider.ts:96-99 |
| ProviderStopSessionInput | threadId | ThreadId | req | | provider.ts:102-104 |
| ProviderRespondToRequestInput | threadId / requestId / decision | ThreadId / ApprovalRequestId / ProviderApprovalDecision | req | | provider.ts:107-111 |
| ProviderRespondToUserInputInput | threadId / requestId / answers / attachmentsByQuestionId | ThreadId / ApprovalRequestId / ProviderUserInputAnswers / UserInputAttachments | req / req / req / opt | | provider.ts:114-119 |
| ProviderUploadFeedbackInput | threadId | ThreadId | req | | provider.ts:123 |
| | reason | TNES | opt | | provider.ts:124 |
| ProviderUploadFeedbackResult | feedbackId | TNES | req | | provider.ts:129 |
| ProviderUploadFeedbackError | _tag "ProviderUploadFeedbackError", threadId | ThreadId | req | message "Failed to upload feedback for thread <id>." | provider.ts:133-143 |
| | cause | Defect | opt | | provider.ts:137 |
| ProviderEventKind (const) | | Literals | | "session", "notification", "request", "error" | provider.ts:145 |
| ProviderEvent | id | EventId | req | | provider.ts:148 |
| | kind | ProviderEventKind | req | | provider.ts:149 |
| | provider | ProviderDriverKind | req | | provider.ts:150 |
| | providerInstanceId | ProviderInstanceId | opt | | provider.ts:152 |
| | threadId | ThreadId | req | | provider.ts:153 |
| | createdAt | IsoDateTime | req | | provider.ts:154 |
| | method | TNES | req | | provider.ts:155 |
| | message | TNES | opt | | provider.ts:156 |
| | turnId | TurnId | opt | | provider.ts:157 |
| | itemId | ProviderItemId | opt | | provider.ts:158 |
| | requestId | ApprovalRequestId | opt | | provider.ts:159 |
| | requestKind | ProviderRequestKind | opt | | provider.ts:160 |
| | textDelta | String | opt | | provider.ts:161 |
| | payload | Unknown | opt | | provider.ts:162 |

---

## 7. providerPolicy.ts (directly imported by orchestrationV2.ts)

| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ProviderApprovalPolicy | | Literals | | "untrusted", "on-failure", "on-request", "never" (not imported by V2) | providerPolicy.ts:10-15 |
| ProviderSandboxMode | | Literals | | "read-only", "workspace-write", "danger-full-access" (not imported by V2) | providerPolicy.ts:18-22 |
| RuntimeMode | | Literals | | "approval-required", "auto-accept-edits", "auto", "full-access" | providerPolicy.ts:25-30 |
| DEFAULT_RUNTIME_MODE | | const | | "full-access" | providerPolicy.ts:32 |
| ProviderInteractionMode | | Literals | | "default", "plan" | providerPolicy.ts:34 |
| DEFAULT_PROVIDER_INTERACTION_MODE | | const | | "default" | providerPolicy.ts:36 |
| ProviderRequestKind | | Literals | | "command", "file-read", "file-change", "mcp-elicitation", "permission" | providerPolicy.ts:38-44 |
| AssistantDeliveryMode | | Literals | | "buffered", "streaming" (not imported by V2) | providerPolicy.ts:47 |
| ProviderApprovalDecision | | Literals | | "accept", "acceptForSession", "acceptAlways", "decline", "cancel" | providerPolicy.ts:50-56 |
| ProviderApprovalOption | decision | ProviderApprovalDecision | req | | providerPolicy.ts:60 |
| | label | TNES | req | | providerPolicy.ts:61 |
| | warning | TNES | opt | provider caution, for example a prompt injection warning | providerPolicy.ts:63 |
| ProviderUserInputAnswers | | Record(String, Unknown) | | values are any JSON | providerPolicy.ts:67 |
| UserInputAttachments | | Record(String, Array(Union(ChatImageAttachment, ChatFileAttachment))) | | each array max 100 (PROVIDER_SEND_TURN_MAX_ATTACHMENTS); ChatUnknownAttachment NOT allowed | providerPolicy.ts:70-75 |
| UserInputAttachmentAnswerPayload | requestId | TNES (not branded) | req | | providerPolicy.ts:79 |
| | questionTextById | Record(String, String) | opt | | providerPolicy.ts:80 |
| | answers | ProviderUserInputAnswers | req | | providerPolicy.ts:81 |
| | attachmentsByQuestionId | UserInputAttachments | req | | providerPolicy.ts:82 |

V2 usage:
- RuntimeMode: orchestrationV2.ts:371, 1843, 2620, 2816, 3011, 3191.
- ProviderInteractionMode: 372, 1844, 2621, 2822, 3012, 3192.
- ProviderRequestKind: 1031 (OrchestrationV2RuntimeRequest.kind is Union(ProviderRequestKind, Literals "dynamic_tool_call", "user_input", "auth_refresh"), 1030-1033), 1463 and 2241 (approval_request turn item `requestKind`).
- ProviderApprovalOption: 1468, 2246 (approval_request item `options` opt).
- ProviderApprovalDecision: 1042 (RuntimeRequest.decision opt), 2964.
- ProviderUserInputAnswers: 1043, 2965.
- UserInputAttachments: 2966. The command is `runtime-request.respond` {commandId, threadId, requestId: RuntimeRequestId, decision opt, answers opt, attachmentsByQuestionId opt} (orchestrationV2.ts:2959-2967).
- UserInputAttachmentAnswerPayload: 1423, 2201 (user_input_request item `questionAnswer` opt).

Client answer convention (web app, not contract): `Record<questionId, string | string[]>`; an option answer is `option.value ?? option.label`; multiSelect produces string[] (apps/web/src/pendingUserInput.ts:42-71, 137-152).

---

## 8. providerRuntime.ts

Wire status: ProviderRuntimeEvent is not referenced by rpc.ts or by any client package (grep over apps/web/src, packages/client-runtime/src, apps/mobile); only the server uses it (apps/server/src/provider/ProviderEventLoggers.ts). V2 imports only TurnTokenUsage (OrchestrationV2ProviderTurn.turnTokenUsage opt, orchestrationV2.ts:1002), ToolActivitySurface / ToolActivityIcon / ToolActivitySource (turn item base fields, all opt, orchestrationV2.ts:1318-1320) and ThreadTokenUsageSnapshot (provider thread `contextUsage`, opt or null with default(null), orchestrationV2.ts:895-897).

### 8.1 Vocabulary literals
| Export | Literals | Line |
|---|---|---|
| RuntimeEventRawSource (const, type exported) | "codex.app-server.notification", "codex.app-server.request", "codex.eventmsg", "claude.sdk.message", "claude.sdk.permission", "codex.sdk.thread-event", "opencode.sdk.event", "acp.jsonrpc", template `acp.<string>.extension` | providerRuntime.ts:23-33 |
| RuntimeSessionState (const) | "starting", "ready", "running", "waiting", "stopped", "error" | providerRuntime.ts:54-61 |
| RuntimeThreadState (const) | "active", "idle", "archived", "closed", "compacted", "error" | providerRuntime.ts:64-71 |
| RuntimeTurnState (const), exported as ProviderRuntimeTurnStatus | "completed", "failed", "interrupted", "cancelled" | providerRuntime.ts:74, 1205-1206 |
| RuntimePlanStepStatus (const) | "pending", "inProgress", "completed" | providerRuntime.ts:77 |
| RuntimeItemStatus (const) | "inProgress", "completed", "failed", "declined" | providerRuntime.ts:80 |
| RuntimeContentStreamKind (const) | "assistant_text", "reasoning_text", "reasoning_summary_text", "plan_text", "command_output", "file_change_output", "unknown" | providerRuntime.ts:83-91 |
| RuntimeSessionExitKind (const) | "graceful", "error" | providerRuntime.ts:94 |
| RuntimeErrorClass (const) | "provider_error", "transport_error", "permission_error", "validation_error", "unknown" | providerRuntime.ts:97-103 |
| ToolLifecycleItemType | "command_execution", "file_change", "mcp_tool_call", "dynamic_tool_call", "collab_agent_tool_call", "web_search", "image_view" | providerRuntime.ts:106-116 |
| isToolLifecycleItemType | function | providerRuntime.ts:119-121 |
| CanonicalItemType | "user_message", "assistant_message", "reasoning", "plan", the 7 tool lifecycle types, "review_entered", "review_exited", "context_compaction", "error", "unknown" | providerRuntime.ts:123-134 |
| CanonicalRequestType | "command_execution_approval", "file_read_approval", "file_change_approval", "apply_patch_approval", "exec_command_approval", "mcp_elicitation_approval", "permission_approval", "tool_user_input", "dynamic_tool_call", "auth_tokens_refresh", "unknown" | providerRuntime.ts:137-149 |
| RuntimeTaskStatus | "pending", "running", "waiting", "idle", "completed", "failed", "cancelled", "interrupted" | providerRuntime.ts:601-610 |

### 8.2 Reusable structs (V2-imported ones first)

ThreadTokenUsageSnapshot (providerRuntime.ts:263-286)
| Field | Type | Opt | Line |
|---|---|---|---|
| usedTokens | NonNegativeInt | req | 264 |
| totalProcessedTokens | NonNegativeInt | opt | 265 |
| maxTokens | PositiveInt | opt | 266 |
| inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens | NonNegativeInt | opt | 267-270 |
| lastUsedTokens, lastInputTokens, lastCachedInputTokens, lastOutputTokens, lastReasoningOutputTokens | NonNegativeInt | opt | 271-275 |
| toolUses, durationMs | NonNegativeInt | opt | 276-277 |
| compactsAutomatically | Boolean | opt | 278 |
| autoCompactThreshold | PositiveInt | opt | 279 |
| cost | {amount: Number (finite check), currency: TNES max 32} | opt | 280-285 |

TurnTokenUsage (providerRuntime.ts:331-351): union of two structs; semantics in the comment at 325-330 (input includes cache reads and writes; output includes reasoning; reasoningTokens is a subset of output).
| Field | Member "complete" | Member "partial" or "unavailable" | Line |
|---|---|---|---|
| usageScope | Literal "main_agent", req | same | 332 |
| cachedInputTokens, cacheCreationTokens, reasoningTokens | NonNegativeInt, opt | same | 333-335 |
| hasSubagents | Boolean, req | same | 336 |
| usageStatus | Literal "complete" | Literals "partial", "unavailable" | 341, 347 |
| inputTokens | NonNegativeInt, req | NonNegativeInt, opt | 342, 348 |
| outputTokens | NonNegativeInt, req | NonNegativeInt, opt | 343, 349 |
Test: "complete" without totals fails, "partial" without totals passes (providerRuntime.test.ts:9-53).

ToolActivitySurface (providerRuntime.ts:398): "browser", "computer".

ToolActivityNativeAppReference (providerRuntime.ts:401-411), tagged by `_tag`, plain union:
| _tag | Field | Type | Constraints | Line |
|---|---|---|---|---|
| "app-id" | appId | TNES | max 512, `/^[A-Za-z0-9._-]+$/u` | 402-407 |
| "display-name" | displayName | TNES | max 160 | 408-410 |

ToolActivityIcon (providerRuntime.ts:414-427), tagged by `_tag`, plain union (unknown `_tag` fails):
| _tag | Field | Type | Opt | Constraints | Line |
|---|---|---|---|---|---|
| "website" | pageUrl | TNES | req | max 4096 | 416 |
| | faviconUrl | TNES | opt | max 4096 | 417 |
| | faviconUrlDark | TNES | opt | max 4096 | 418 |
| "native-app" | app | ToolActivityNativeAppReference | req | | 421 |
| "themed-logo" | logoUrl | TNES | req | max 4096 | 424 |
| | logoUrlDark | TNES | opt | max 4096 | 425 |

ToolActivitySource (providerRuntime.ts:430-435)
| Field | Type | Opt | Constraints | Line |
|---|---|---|---|---|
| key | TNES | req | max 512 | 431 |
| name | TNES | req | max 160 | 432 |
| kind | Literals | req | "browser", "computer", "integration" | 433 |
| icon | ToolActivityIcon | opt | | 434 |

ItemLifecyclePayload (providerRuntime.ts:438-454)
| Field | Type | Opt | Line |
|---|---|---|---|
| itemType | CanonicalItemType | req | 439 |
| status | RuntimeItemStatus | opt | 440 |
| title, detail | TNES | opt | 441-442 |
| toolSurface | ToolActivitySurface | opt | 443 |
| toolIcon | ToolActivityIcon | opt | 444 |
| toolSource | ToolActivitySource | opt | 445 |
| data | Unknown | opt | 446 |
| agentId | TNES | opt (owning subagent) | 452 |
| parentToolUseId | TNES | opt | 453 |

Other exported structs:
| Export | Fields | Line |
|---|---|---|
| RuntimeEventRaw | source RuntimeEventRawSource req; method TNES opt; messageType TNES opt; payload Unknown req | providerRuntime.ts:36-41 |
| ProviderRequestId (const, type exported) | TNES (not branded) | providerRuntime.ts:44 |
| ProviderRefs (const, type exported) | providerTurnId TNES opt; providerItemId ProviderItemId opt; providerRequestId TNES opt | providerRuntime.ts:47-51 |
| UserInputQuestion | see section 21 | providerRuntime.ts:488-499 |
| UserInputRequestedPayload | questions UserInputQuestion[] req; responseMode Literal "message" opt | providerRuntime.ts:502-505 |
| RuntimeTaskUsage | totalTokens NonNegativeInt req; inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens, toolUses, durationMs NonNegativeInt opt | providerRuntime.ts:519-527 |
| TaskWorkflowPhase | index NonNegativeInt req; title TNES req | providerRuntime.ts:530-533 |
| TaskRunHandles | runId, scriptPath, transcriptDir, sessionUrl: TNES opt (sessionUrl http/https only per comment 540) | providerRuntime.ts:536-542 |
| TaskAgentLinkage | all opt: taskType TNES (554); agentKind "agent" or "background" (560); agentId (566); title (567); role (568); model (569); effort (571); toolUseId (572); parentAgentId (573); workflowName (574) all TNES; agentIndex NonNegativeInt (575); phaseIndex NonNegativeInt (576); phaseTitle TNES (577); phases TaskWorkflowPhase[] (578); attempt NonNegativeInt (579); runHandles TaskRunHandles (580); outputFile TNES (581); agentPath TNES (583); timelineBypass Boolean (588) | providerRuntime.ts:551-591 |

### 8.3 Event envelope
ProviderRuntimeEventBase (providerRuntime.ts:202-216). Every event = base fields + `type` literal + `payload`.
| Field | Type | Opt | Line |
|---|---|---|---|
| eventId | EventId | req | 203 |
| provider | ProviderDriverKind | req | 204 |
| providerInstanceId | ProviderInstanceId | opt | 208 |
| threadId | ThreadId | req | 209 |
| createdAt | IsoDateTime | req | 210 |
| turnId | TurnId | opt | 211 |
| itemId | RuntimeItemId | opt | 212 |
| requestId | RuntimeRequestId | opt | 213 |
| providerRefs | ProviderRefs | opt | 214 |
| raw | RuntimeEventRaw | opt | 215 |

ProviderRuntimeEventV2 (providerRuntime.ts:1149-1199) is a plain union of 49 members; ProviderRuntimeEvent is an alias (providerRuntime.ts:1202). The legacy "message.delta" type is rejected (providerRuntime.test.ts:179-190).

### 8.4 Event types and payloads
| type | Literal line | Payload fields | Payload lines |
|---|---|---|---|
| session.started | 152 | message TNES opt; resume Unknown opt | 219-222 |
| session.configured | 153 | config Record(String, Unknown) req | 225-227 |
| session.state.changed | 154 | state RuntimeSessionState req; reason TNES opt; detail Unknown opt | 230-234 |
| session.exited | 155 | reason TNES opt; recoverable Boolean opt; exitKind RuntimeSessionExitKind opt | 237-241 |
| thread.started | 156 | providerThreadId TNES opt | 244-246 |
| thread.state.changed | 157 | state RuntimeThreadState req; beforeTokens, afterTokens NonNegativeInt opt; detail Unknown opt | 249-254 |
| thread.metadata.updated | 158 | name TNES opt; metadata Record opt | 257-260 |
| thread.token-usage.updated | 159 | usage ThreadTokenUsageSnapshot req | 289-291 |
| thread.realtime.started | 160 | realtimeSessionId TNES opt | 294-296 |
| thread.realtime.item-added | 161 | item Unknown req | 299-301 |
| thread.realtime.audio.delta | 162 | audio Unknown req | 304-306 |
| thread.realtime.error | 163 | message TNES req | 309-311 |
| thread.realtime.closed | 164 | reason TNES opt | 314-316 |
| turn.started | 165 | model TNES opt; effort TNES opt | 319-322 |
| turn.completed | 166 | state RuntimeTurnState req; stopReason TNES opt or null; usage Unknown opt; modelUsage Record opt; totalCostUsd Number opt; errorMessage TNES opt; tokenUsage TurnTokenUsage opt | 354-362 |
| turn.aborted | 167 | reason TNES req; tokenUsage TurnTokenUsage opt | 365-368 |
| turn.plan.updated | 168 | explanation TNES opt or null; plan RuntimePlanStep[] req, where RuntimePlanStep = {step TNES req, status RuntimePlanStepStatus req} (371-374) | 377-380 |
| turn.proposed.delta | 169 | delta String req | 383-385 |
| turn.proposed.completed | 170 | planMarkdown TNES req | 388-390 |
| turn.diff.updated | 171 | unifiedDiff String req | 393-395 |
| item.started | 172 | ItemLifecyclePayload | 438-454 |
| item.updated | 173 | ItemLifecyclePayload | 438-454 |
| item.completed | 174 | ItemLifecyclePayload | 438-454 |
| content.delta | 175 | streamKind RuntimeContentStreamKind req; delta String req; contentIndex Int opt; summaryIndex Int opt | 457-462 |
| request.opened | 176 | requestType CanonicalRequestType req; detail TNES opt; appName TNES opt; options ProviderApprovalOption[] opt; args Unknown opt | 465-471 |
| request.resolved | 177 | requestType CanonicalRequestType req; decision TNES opt (free string); resolution Unknown opt | 474-478 |
| user-input.requested | 178 | UserInputRequestedPayload | 502-505 |
| user-input.resolved | 179 | answers Record(String, Unknown) req | 508-510 |
| task.started | 180 | taskId RuntimeTaskId req; description TNES opt; plus TaskAgentLinkage fields | 594-598 |
| task.progress | 181 | taskId req; description TNES req; summary TNES opt; usage Unknown opt; typedUsage RuntimeTaskUsage opt; lastToolName TNES opt; status RuntimeTaskStatus opt; error TNES opt; plus linkage | 613-624 |
| task.updated | 182 | taskId req; status RuntimeTaskStatus opt; description TNES opt; error TNES opt; endedAt IsoDateTime opt; isBackgrounded Boolean opt; plus linkage | 632-640 |
| task.completed | 183 | taskId req; status Literals "completed", "failed", "stopped" req; summary TNES opt; usage Unknown opt; typedUsage RuntimeTaskUsage opt; plus linkage | 643-650 |
| hook.started | 184 | hookId, hookName, hookEvent TNES req | 653-656 |
| hook.progress | 185 | hookId TNES req; output, stdout, stderr String opt | 660-665 |
| hook.completed | 186 | hookId TNES req; outcome "success", "error", "cancelled" req; output, stdout, stderr String opt; exitCode Int opt | 668-675 |
| tool.progress | 187 | toolUseId, toolName, summary TNES opt; elapsedSeconds Number opt; taskId RuntimeTaskId opt; parentToolUseId TNES opt | 678-686 |
| tool.summary | 188 | summary TNES req; precedingToolUseIds TNES[] opt | 689-692 |
| auth.status | 189 | isAuthenticating Boolean opt; output String[] opt; error TNES opt | 695-699 |
| account.updated | 190 | account Unknown req | 702-704 |
| account.rate-limits.updated | 191 | limits ProviderUsageLimitsUpdate req (section 9) | 711-713 |
| mcp.status.updated | 192 | status Unknown req | 716-718 |
| mcp.oauth.completed | 193 | success Boolean req; name TNES opt; error TNES opt | 721-725 |
| model.rerouted | 194 | fromModel, toModel, reason TNES req | 728-732 |
| config.warning | 195 | summary TNES req; details TNES opt; path TNES opt; range Unknown opt | 735-740 |
| deprecation.notice | 196 | summary TNES req; details TNES opt | 743-746 |
| files.persisted | 197 | files [{filename TNES, fileId TNES}] req; failed [{filename TNES, error TNES}] opt | 749-764 |
| tool.denied | 198 | toolName TNES req; toolUseId, reason, agentId TNES opt | 767-772 |
| runtime.warning | 199 | message TNES req; detail Unknown opt | 775-778 |
| runtime.error | 200 | message TNES req; code TNES opt; class RuntimeErrorClass opt; detail Unknown opt | 781-786 |

---

## 9. providerUsageLimits.ts and usageLimitSourceId.ts (parts reachable from V2)

Reachable only through providerRuntime.ts:17 (AccountRateLimitsUpdatedPayload), which is server-internal.

| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ServerProviderUsageWindow | id | TNES | req | stable per provider, for example "five_hour", "seven_day_opus", "primary" (comment 16-17) | providerUsageLimits.ts:21 |
| | kind | Literals | req | "session", "weekly", "monthly", "other" | providerUsageLimits.ts:22 |
| | label | TNES | req | | providerUsageLimits.ts:23 |
| | usedPercent | Number | req | between 0 and 100 | providerUsageLimits.ts:24 |
| | resetsAt | IsoDateTime | opt | | providerUsageLimits.ts:25 |
| | windowDurationMins | NonNegativeInt | opt | | providerUsageLimits.ts:26 |
| ProviderUsageLimitsUpdate | windows | ServerProviderUsageWindow[] | req | plain array (not forward-compatible); sparse, merged by id onto the published snapshot (comment 72-77) | providerUsageLimits.ts:78-80 |

Other exports in the file are not reachable from orchestrationV2.ts (listed for orientation only): ServerProviderResetCredits (35-40), ServerProviderUsageLimits (50-69, `windows` is a ForwardCompatibleArray), UsageLimitSourceAccount (88-96), UsageLimitSourceSnapshot (104-111), UsageLimitSourceSnapshots (114), UsageLimitSourceConsumeResetCreditInput (117-121), ProviderConsumeResetCreditInput (125-128), UsageLimitSourceError (131-138), ProviderConsumeResetCreditOutcome (141-146: "reset", "nothingToReset", "noCredit", "alreadyRedeemed"), ProviderConsumeResetCreditResult (149-153), UsageLimitsReport (157-175). UsageLimitSourceId is `Schema.String` + brand, not trimmed (usageLimitSourceId.ts:8).

---

## 10. composerContext.ts (composer context references)

### 10.1 Constants
| Export | Value | Line |
|---|---|---|
| COMPOSER_CONTEXT_KINDS | "image", "file", "terminal", "element", "preview-annotation", "review-comment", "mention", "skill", "thread" | composerContext.ts:21-31 |
| CONTEXT_ID_MAX_CHARS (internal) | 128 | composerContext.ts:34 |
| CONTEXT_ID_PATTERN (internal) | `/^[a-z0-9_-]+$/i` | composerContext.ts:35 |
| CONTEXT_KIND_PATTERN (internal) | `/^[a-z][a-z0-9-]{0,39}$/` | composerContext.ts:36 |
| KNOWN_KIND_PATTERN (internal) | negative lookahead: kind must not equal any known kind | composerContext.ts:37 |
| COMPOSER_CONTEXT_LABEL_MAX_CHARS | 200 | composerContext.ts:39 |
| COMPOSER_CONTEXT_TERMINAL_TEXT_MAX_CHARS | 64000 | composerContext.ts:40 |
| element html / styles max (internal) | 8000 / 8000 | composerContext.ts:41-42 |
| COMPOSER_CONTEXT_REVIEW_TEXT_MAX_CHARS | 16000 | composerContext.ts:45 |
| COMPOSER_CONTEXT_REVIEW_DIFF_MAX_CHARS | 32000 | composerContext.ts:46 |
| preview comment max (internal) | 8000 | composerContext.ts:47 |
| COMPOSER_CONTEXT_MAX_RECORDS | 200 | composerContext.ts:283 |
| max serialized records (internal) | 16,000,000 chars of JSON.stringify(records) | composerContext.ts:284 |

### 10.2 Building blocks
| Export | Definition | Line |
|---|---|---|
| ComposerContextId | TNES, max 128, CONTEXT_ID_PATTERN, brand "ComposerContextId". Durable identity of one payload. | composerContext.ts:50-53 |
| ComposerContextReferenceId | same rules, brand "ComposerContextReferenceId". Identity of one occurrence; not used inside records. | composerContext.ts:57-60 |
| ComposerContextKind | TNES matching CONTEXT_KIND_PATTERN (open) | composerContext.ts:64-66 |
| ContextAttachmentId (internal) | TNES, max 128, `/^[a-z0-9_-]+$/i` (same rules as ChatAttachmentId) | composerContext.ts:71-74 |
| ContextLabel (internal) | String max 200 (not trimmed, may be empty) | composerContext.ts:75 |
| BoundedString(max) / ShortString / NullableShortString (internal) | String max n / String max 2048 / NullOr(ShortString) | composerContext.ts:76-78 |
| PullRequestContextMetadata | number PositiveInt (82); title, url, headBranch, baseBranch ShortString (83-86); state "open", "closed", "merged" (87); isDraft Boolean (88); all req | composerContext.ts:81-89 |
| recordBase (internal) | version Literal 1 (93); contextId ComposerContextId (94); label ContextLabel (95); all req | composerContext.ts:92-96 |
| attachmentBinding (internal) | attachmentId ContextAttachmentId (99); name TNES max 255 (100); mimeType TNES max 100 (101); sizeBytes NonNegativeInt (102); all req | composerContext.ts:98-103 |

### 10.3 Records (all fields req unless noted; every record also has the recordBase fields)
| Record | kind | Fields | Line |
|---|---|---|---|
| ImageContextRecord | "image" | attachmentBinding fields | composerContext.ts:105-109 |
| FileContextRecord | "file" | attachmentBinding fields | composerContext.ts:112-116 |
| TerminalContextRecord | "terminal" | terminalId TNES max 255 (122); terminalLabel TNES max 255 (123); lineStart NonNegativeInt (124); lineEnd NonNegativeInt (125); text String max 64000 (126); check lineEnd >= lineStart (127) | composerContext.ts:119-127 |
| ElementContextRecord | "element" | all ElementContextDetails fields (below) | composerContext.ts:151-155 |
| PreviewAnnotationContextRecord | "preview-annotation" | annotationId ShortString (164); pageUrl ShortString (165); pageTitle NullableShortString (166); comment String max 8000 (167); targetSummary ShortString (168); styleChanges ShortString[] max 200 (169); elements optKey ElementContextDetails[] max 50 (171); elementIds optKey ShortString[] max 50 (173); regionCount optKey NonNegativeInt (176); strokeCount optKey NonNegativeInt (177); styleChangeDetails optKey array max 200 of {targetId ShortString, selector NullableShortString, property ShortString, previousValue String max 8000, value String max 8000} (178-188); screenshotContextId optKey ComposerContextId (190) | composerContext.ts:161-191 |
| ReviewCommentContextRecord | "review-comment" | sectionId TNES max 255 (197); sectionTitle ShortString (198); filePath TNES max 2048 (199); startIndex NonNegativeInt (200); endIndex NonNegativeInt (201); rangeLabel ShortString (202); text String max 16000 (203); diff String max 32000 (204); fenceLanguage optKey String max 64 (205); pullRequest optKey PullRequestContextMetadata (206); check endIndex >= startIndex (207) | composerContext.ts:194-207 |
| MentionContextRecord | "mention" | path TNES max 2048 (213) | composerContext.ts:210-214 |
| SkillContextRecord | "skill" | name TNES max 255 (220) | composerContext.ts:217-221 |
| ThreadContextRecord | "thread" | environmentId EnvironmentId (231); threadId ThreadId (232); title ContextLabel (233) | composerContext.ts:228-234 |
| UnknownContextRecord | any ComposerContextKind that is not a known kind (246) | payload Unknown that must be a JSON value whose JSON.stringify length is at most 64000 (247-260) | composerContext.ts:244-261 |

ElementContextSource (composerContext.ts:130-135): functionName NullableShortString (131); fileName NullableShortString (132); lineNumber null NonNegativeInt (133); columnNumber null NonNegativeInt (134). All keys required.

ElementContextDetails (composerContext.ts:139-148): pageUrl ShortString (140); pageTitle NullableShortString (141); tagName TNES max 255 (142); selector NullableShortString (143); htmlPreview String max 8000 (144); componentName NullableShortString (145); source null ElementContextSource (146); styles String max 8000 (147). All keys required.

Unions: KnownComposerContextRecord (composerContext.ts:264-274); ComposerContextRecord = known members then UnknownContextRecord (composerContext.ts:277-280). Plain union keyed on `kind`.

### 10.4 OrchestrationMessageContext (composerContext.ts:287-306)
| Field | Type | Opt | Constraints | Line |
|---|---|---|---|---|
| version | Literal 1 | req | | composerContext.ts:288 |
| records | raw Array(Unknown), then ForwardCompatibleArray(ComposerContextRecord) | req | raw array max 200 and JSON.stringify length at most 16,000,000 (290-299); undecodable records dropped (300); decoded contextIds must be unique, otherwise the whole context fails (301-305) | composerContext.ts:289-305 |

Behavior verified by tests: unknown kinds kept with payload (composerContext.test.ts:132-146); a malformed known kind is not accepted as unknown (148-150); unknown payload bound 64000 (152-166); bad id, version 2 or bad kind rejected (168-174); aggregate size limit (178-200); records that cannot encode (blank required field, NaN, bigint, explicit undefined in an optKey field) are dropped when sending (202-231); ids trimmed on decode (241-247); more than 200 records rejects the whole context (249-253); undecodable records dropped, siblings kept (255-265); duplicate contextIds reject the whole context (267-274); `context` is optional on messages and message.dispatch (276-311).

V2 usage: `context` opt on OrchestrationV2ConversationMessage (orchestrationV2.ts:1125), user_message turn item (1387), its JSON variant (2165), message.dispatch (2847), queued-run.edit (2950), thread launch input (3198).

Capability gate: only send `context` when the server advertises `capabilities.inlineMessageContext` (environment.ts:115-118, optKey Boolean). Otherwise serialize context into legacy text (packages/shared/src/composerContextLegacySend.ts:13; mobile wrapper apps/mobile/src/lib/composerContext.ts:232-240).

### 10.5 How references appear in message text (packages/shared/src/composerContextReferences.ts)
- Inline link: `[label](t3-context://v1/<kind>/<contextId>)`; image records use `![label](...)` (10-28, 52-60).
- Parse rules: href must start with `t3-context://v1/` and have exactly two path segments; kind matches `/^[a-z][a-z0-9-]{0,39}$/`; id matches `/^[a-z0-9_-]{1,128}$/i` (16-19, 30-40). Link regex accepts labels up to 512 characters without "]" or newline (20-24).
- Label sanitizing: "[", "]", "\\", CR and LF become spaces, whitespace collapsed, trimmed, cut to 200, empty falls back to the kind (43-50).
- Payloads live only in `context.records`, keyed by contextId; image and file records bind to a ChatAttachment by `attachmentId` (composerContext.ts:12-19).
- Provider projection (server behavior): each link becomes `[<Kind display>: <label>; ref=<contextId>]` and referenced payloads are appended once in a `<t3_context version="1">` envelope of `<context kind="..." id="...">` entries (112-131, 246-298).

composerContextClipboard.ts: COMPOSER_CONTEXT_CLIPBOARD_MIME "web application/x-t3-context-fragment+json" (composerContextClipboard.ts:12); ComposerContextClipboardFragment {version Literal 1; source {environmentId EnvironmentId req, threadId ThreadId opt, messageId MessageId opt}; records raw Array(Unknown) max 200 then ForwardCompatibleArray(ComposerContextRecord)} (composerContextClipboard.ts:14-26).

---

## 11. chatAttachment.ts

### 11.1 Constants
| Export | Value | Line |
|---|---|---|
| PROVIDER_SEND_TURN_MAX_INPUT_CHARS | 120000 | chatAttachment.ts:13 |
| PROVIDER_SEND_TURN_MAX_ATTACHMENTS | 100 | chatAttachment.ts:14 |
| PROVIDER_SEND_TURN_MAX_IMAGE_BYTES | 10 MiB = 10485760 | chatAttachment.ts:15 |
| total image bytes per message (internal) | 80 MiB = 83886080 | chatAttachment.ts:16 |
| PROVIDER_SEND_TURN_MAX_FILE_BYTES | 50 MiB = 52428800 | chatAttachment.ts:17 |
| PROVIDER_SEND_TURN_SUPPORTED_IMAGE_MIME_TYPES | "image/gif", "image/jpeg", "image/png", "image/webp" | chatAttachment.ts:18-23 |
| image data URL max (internal) | 14,000,000 chars | chatAttachment.ts:32 |
| attachment id max (internal) | 128 | chatAttachment.ts:33 |
| SNAP_SHOT_ACCESSIBLE_TEXT_MAX_CHARS | 32000 | chatAttachment.ts:41 |
| SNAP_SHOT_ACCESSIBILITY_MAX_NODES | 10000 | chatAttachment.ts:42 |
| SNAP_SHOT_ACCESSIBILITY_MAX_SERIALIZED_CHARS | 32000 | chatAttachment.ts:43 |

### 11.2 Schemas
| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ChatAttachmentId | | TNES (not branded) | | max 128, `/^[a-z0-9_-]+$/i` | chatAttachment.ts:35-38 |
| ChatImageAttachment | type | Literal "image" | req | | chatAttachment.ts:150 |
| | id | ChatAttachmentId | req | | chatAttachment.ts:151 |
| | name | TNES | req | max 255 | chatAttachment.ts:152 |
| | mimeType | TNES | req | max 100, `/^image\//i` | chatAttachment.ts:153 |
| | sizeBytes | NonNegativeInt | req | at most 10485760 | chatAttachment.ts:154 |
| | source | SnapShotSource | opt | | chatAttachment.ts:155 |
| PastedTextAttachmentSource | _tag | "pasted-text" | req | TaggedStruct with no other fields: `{"_tag":"pasted-text"}` | chatAttachment.ts:159 |
| ChatFileAttachment | type | Literal "file" | req | | chatAttachment.ts:163 |
| | id | ChatAttachmentId | req | | chatAttachment.ts:164 |
| | name | TNES | req | max 255 | chatAttachment.ts:165 |
| | mimeType | TNES | req | max 100 | chatAttachment.ts:166 |
| | sizeBytes | NonNegativeInt | req | between 1 and 52428800 | chatAttachment.ts:167-170 |
| | source | PastedTextAttachmentSource | opt | clipboard text folded by a client | chatAttachment.ts:174 |
| ChatUnknownAttachment | type | TNES | req | max 50, must not be "image" or "file" | chatAttachment.ts:189-192 |
| | id | ChatAttachmentId | req | | chatAttachment.ts:193 |
| | name | TNES | req | max 255 | chatAttachment.ts:194 |
| | mimeType | TNES | req | max 100 | chatAttachment.ts:195 |
| | sizeBytes | NonNegativeInt | req | | chatAttachment.ts:196 |
| ChatAttachment | | Union(image, file, unknown) on `type` | | tolerant of new types (chatAttachment.test.ts:19-30); malformed image/file still fails (35-51) | chatAttachment.ts:213-217 |
| UploadChatImageAttachment | id | ChatAttachmentId | opt | | chatAttachment.ts:201 |
| | type | Literal "image" | req | | chatAttachment.ts:202 |
| | name | TNES | req | max 255 | chatAttachment.ts:203 |
| | mimeType | TNES | req | max 100, `/^image\//i` | chatAttachment.ts:204 |
| | sizeBytes | NonNegativeInt | req | at most 10485760 | chatAttachment.ts:205 |
| | dataUrl | TNES | req | max 14,000,000 | chatAttachment.ts:206-208 |
| | source | SnapShotSource | opt | | chatAttachment.ts:209 |
| UploadChatAttachment | | Union(UploadChatImageAttachment) | | | chatAttachment.ts:239 |
| PersistChatAttachmentsInput | threadId / messageId / attachments | ThreadId / MessageId / UploadChatAttachment[] | req | | chatAttachment.ts:242-246 |
| PersistChatAttachmentsResult | attachments | ChatAttachment[] | req | | chatAttachment.ts:249-251 |
| PersistChatAttachmentsError | _tag, message | String | req | cause Defect opt | chatAttachment.ts:254-260 |

SnapShotSource (chatAttachment.ts:130-146): kind Literal "snap-shot" req (131); capturedAt IsoDateTime req (132); appName TNES max 255 req (133); windowTitle TrimmedString max 1000 req, may be empty (134); accessibleText TNES max 32000 opt (135-137); accessibility SnapShotAccessibility opt (138); appIdentifier TNES max 255 opt (139); appIconDataUrl TNES max 100000 matching `/^data:image\/png;base64,/i` opt (140-145).

SnapShotAccessibility (chatAttachment.ts:94-127): union on `format`: {format "flat-text", text TNES max 32000, truncated Boolean} (95-99) or {format "element-tree", coordinateSpace Literal "captured-image", imageSize {width PositiveInt, height PositiveInt}, truncated Boolean, root SnapShotAccessibilityNode} (100-106); extra check: at most 10000 nodes and JSON length at most 32000 (109-127; test chatAttachment.test.ts:53-76).

SnapShotAccessibilityNode (recursive, chatAttachment.ts:64-92): role TNES max 100 req (76); name TNES max 1000 optKey (77); value TNES max 8000 optKey (78); description TNES max 2000 optKey (79); bounds null {x NonNegativeInt, y NonNegativeInt, width PositiveInt, height PositiveInt} (45-50, 80); state optKey {active, busy, editable, enabled, expanded, focused, selected, visible: Boolean opt; checked opt "on", "off", "mixed"} (52-62, 81); actions optKey TNES max 100 array max 32 (82-86); children Node[] max 10000 req (87-91).

Helpers: isProviderSendTurnSupportedImageMimeType, case-insensitive (chatAttachment.ts:29-31; svg rejected, chatAttachment.test.ts:78-82). getProviderAttachmentLimitError (chatAttachment.ts:220-237): more than 100 attachments is an error; total sizeBytes of attachments whose type is "image" or whose mime is a supported image type above 80 MiB is an error. V2 enforces it at message intake (apps/server/src/orchestration-v2/AttachmentClaims.ts:28).

### 11.3 Upload flows and attachment ids
- (a) Data URL path: WS method "assets.persistChatAttachments" (rpc.ts:382, 1241-1245) with PersistChatAttachmentsInput. Used by client-runtime for attachments that carry `dataUrl` (packages/client-runtime/src/operations/commands.ts:276 onward). The server mints a deterministic id from sha256 of [threadId, "<messageId>:<index>"] (apps/server/src/ws.ts:402; apps/server/src/attachmentStore.ts:92-104).
- (b) Upload URL path: WS method "attachments.createUploadUrl" (rpc.ts:383, 1247-1251). Input AttachmentCreateUploadUrlInput (assets.ts:94-118): image variant {type optKey Literal "image", name TNES max 255, mimeType one of the 4 supported image types, sizeBytes 1 to 10 MiB} or file variant {type Literal "file", name TNES max 255, mimeType TNES max 100, sizeBytes 1 to 50 MiB}. Result {attachmentId TNES max 256, relativeUrl TNES max 4096, expiresAt Number (epoch ms)} (assets.ts:120-124); URL TTL 10 minutes (assets.ts:92). Then HTTP POST of the raw bytes to relativeUrl, which looks like `/api/attachments/upload/<base64url payload>.<signature>`; Content-Length must equal sizeBytes; success is 204 (apps/server/src/http.ts:449-485; apps/server/src/assets/AttachmentUpload.ts:35, 72-118). The returned id is `pending-<uuid>[-<ext>]` (apps/server/src/attachmentStore.ts:64-66).
- The client then sends a ChatAttachment carrying that id in message.dispatch. The server claims pending attachments and renames them to `<threadSegment>-<uuid>[-<ext>]` (apps/server/src/orchestration-v2/ThreadMessageIntake.ts:67, 132; apps/server/src/attachmentStore.ts:207-251). Context records that reference the old id are remapped by remapComposerContextAttachments (packages/shared/src/composerContextReferences.ts:301-323).
- Delete: "attachments.delete" {attachmentId TNES max 256} (rpc.ts:384, 1253-1256; assets.ts:127-130).
- Server id grammar: `^(<thread segment [a-z0-9_]+(?:-[a-z0-9_]+)*>)-(<uuid>)(?:-(<ext [a-z0-9]{1,10}>))?$`, case-insensitive (apps/server/src/attachmentStore.ts:16-23). The thread segment is the lowercased threadId with runs of characters outside [a-z0-9_-] replaced by "-", trimmed of leading and trailing "-" and "_", max 80, and "pending" remapped to "_pending" (attachmentStore.ts:29-42).

V2 usage: `attachments` ChatAttachment[] req on OrchestrationV2ConversationMessage (orchestrationV2.ts:1126), user_message item (1388), message.dispatch (2848), thread launch (3199); opt on assistant_message item (1395, 2173) and queued-run.edit (2957, absent means keep existing attachments).

---

## 12. threadPullRequest.ts and the referenced parts of pullRequest.ts

### 12.1 pullRequest.ts (only parts referenced by thread PR links)
| Export | Field | Type | Opt | Literals | Line |
|---|---|---|---|---|---|
| PullRequestState | | Literals | | "open", "closed", "merged" | pullRequest.ts:18 |
| PullRequestReviewDecision | | Literals | | "approved", "changes-requested", "review-required" | pullRequest.ts:30-34 |
| PullRequestChecksState | | Literals | | "passing", "failing", "pending" | pullRequest.ts:71 |
| PullRequestMergeability | | Literals | | "mergeable", "conflicting", "unknown" | pullRequest.ts:74 |
| PullRequestActor | isBot | Boolean | opt | | pullRequest.ts:125 |
| | login | TNES | req | | pullRequest.ts:126 |
| | name | String | null | | pullRequest.ts:127 |
| | avatarUrl | String | null | | pullRequest.ts:129 |

### 12.2 threadPullRequest.ts
| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ThreadLinkedPullRequest (legacy single link) | projectId | ProjectId | req | | threadPullRequest.ts:25 |
| | repository | TNES | req | | threadPullRequest.ts:26 |
| | number | PositiveInt | req | | threadPullRequest.ts:27 |
| | url | TNES | req | | threadPullRequest.ts:28 |
| ThreadPullRequestLinkSource | | Literals | | "manual", "created", "agent", "stack", "stack-dismissed" (tombstone, clients hide it) | threadPullRequest.ts:35-41 |
| ThreadPullRequestSnapshot | state | PullRequestState | req | | threadPullRequest.ts:50 |
| | title | TNES | req | | threadPullRequest.ts:51 |
| | headBranch | TNES | req | | threadPullRequest.ts:52 |
| | baseBranch | TNES | req | | threadPullRequest.ts:53 |
| | isDraft | Boolean | req | | threadPullRequest.ts:54 |
| | updatedAt | IsoDateTime | null | | threadPullRequest.ts:55 |
| | syncedAt | IsoDateTime | req | | threadPullRequest.ts:56 |
| | closedAt | String | opt or null | plain String, not IsoDateTime | threadPullRequest.ts:57 |
| | mergedAt | String | opt or null | | threadPullRequest.ts:58 |
| | author | PullRequestActor | opt or null | | threadPullRequest.ts:59 |
| | additions | NonNegativeInt | opt | | threadPullRequest.ts:60 |
| | deletions | NonNegativeInt | opt | | threadPullRequest.ts:61 |
| | changedFiles | NonNegativeInt | opt | | threadPullRequest.ts:62 |
| | reviewDecision | PullRequestReviewDecision | opt or null | | threadPullRequest.ts:63 |
| | checksState | PullRequestChecksState | opt or null | | threadPullRequest.ts:64 |
| | mergeability | PullRequestMergeability | opt | | threadPullRequest.ts:65 |
| ThreadPullRequestStackLayer | number | PositiveInt | req | | threadPullRequest.ts:70 |
| | headBranch | TNES | req | | threadPullRequest.ts:71 |
| | state | PullRequestState | req | | threadPullRequest.ts:72 |
| ThreadPullRequestStack | kind | Literal "native" | req | | threadPullRequest.ts:78 |
| | id | TNES | req | | threadPullRequest.ts:79 |
| | number | PositiveInt | req | | threadPullRequest.ts:80 |
| | url | TNES | req | | threadPullRequest.ts:81 |
| | base | TNES | req | | threadPullRequest.ts:82 |
| | layers | ThreadPullRequestStackLayer[] | req | bottom to top | threadPullRequest.ts:83 |
| ThreadPullRequestKey | host | TNES | req | host-level identity | threadPullRequest.ts:90 |
| | repository | TNES | req | | threadPullRequest.ts:91 |
| | number | PositiveInt | req | | threadPullRequest.ts:92 |
| ThreadPullRequestWatch | startedAt | IsoDateTime | req | | threadPullRequest.ts:103 |
| | headSha | TNES | null | | threadPullRequest.ts:105 |
| | failedChecks | TNES[] | req | | threadPullRequest.ts:107 |
| | passed | Boolean | req | | threadPullRequest.ts:109 |
| | passedChecks | TNES[] | default([]) | | threadPullRequest.ts:114-116 |
| | remarksThrough | IsoDateTime | req | | threadPullRequest.ts:118 |
| | remarkIds | TNES[] | req | | threadPullRequest.ts:120 |
| | conflicting | Boolean | req | | threadPullRequest.ts:121 |
| | wakes | NonNegativeInt | req | | threadPullRequest.ts:123 |
| ThreadPullRequestLink | host, repository, number | from ThreadPullRequestKey | req | | threadPullRequest.ts:128 |
| | url | TNES | req | | threadPullRequest.ts:129 |
| | source | ThreadPullRequestLinkSource | req | | threadPullRequest.ts:130 |
| | linkedAt | IsoDateTime | req | | threadPullRequest.ts:131 |
| | snapshot | ThreadPullRequestSnapshot | null | null until first sync | threadPullRequest.ts:132 |
| | stack | ThreadPullRequestStack | null | | threadPullRequest.ts:133 |
| | watch | ThreadPullRequestWatch | opt | present while the server watches the PR | threadPullRequest.ts:134 |

Tests: threadPullRequest.test.ts:9-56 (snapshot and stack), 58-84 (watch without passedChecks decodes to []).

V2 usage: OrchestrationV2AppThread.linkedPullRequest opt or null (orchestrationV2.ts:377), pullRequests opt ThreadPullRequestLink[] (378), branchPullRequest opt or null (380); same three on OrchestrationV2ThreadShell (1848-1851). Commands: thread update `linkedPullRequest` opt or null, absent leaves it unchanged (2753); "thread.pull-request.link" {commandId, threadId, host, repository, number, url TNES, source} (2755-2762); "thread.pull-request.unlink" {commandId, threadId, host, repository, number} (2763-2768); "thread.pull-request-link.sync" {..., snapshot ThreadPullRequestSnapshot req, stack null} (2769-2776); "thread.pull-request.watch" {..., watching Boolean, link opt {url TNES, source}} (2777-2788); "thread.pull-request.sync" with expected/branch/linked ThreadLinkedPullRequest fields (2789-2804); "thread.pull-request-watch.sync" {..., startedAt IsoDateTime, watch null ThreadPullRequestWatch, wake opt} (3064-3080). Whether the sync commands are client-dispatchable or server-internal was not traced (UNVERIFIED).

---

## 13. checkpointDiff.ts

| Export | Field | Type | Opt | Constraints | Line |
|---|---|---|---|---|---|
| TurnCountRange | fromTurnCount | NonNegativeInt | req | | checkpointDiff.ts:8 |
| | toTurnCount | NonNegativeInt | req | check fromTurnCount <= toTurnCount (identifier "OrchestrationTurnDiffRange") | checkpointDiff.ts:9-19 |
| ThreadTurnDiff | range fields + threadId | ThreadId | req | range check preserved | checkpointDiff.ts:21-27 |
| | diff | String | req | one unified diff for the whole range | checkpointDiff.ts:24 |
| OrchestrationGetTurnDiffInput | range fields + threadId | ThreadId | req | | checkpointDiff.ts:29-35 |
| | ignoreWhitespace | Boolean | optKey | server default true when absent | checkpointDiff.ts:32 |
| OrchestrationGetTurnDiffResult | | = ThreadTurnDiff | | | checkpointDiff.ts:38 |
| OrchestrationGetFullThreadDiffInput | threadId | ThreadId | req | | checkpointDiff.ts:42 |
| | toTurnCount | NonNegativeInt | req | | checkpointDiff.ts:43 |
| | ignoreWhitespace | Boolean | optKey | | checkpointDiff.ts:44 |
| OrchestrationGetFullThreadDiffResult | | = ThreadTurnDiff | | server returns fromTurnCount 0 | checkpointDiff.ts:48 |
| OrchestrationGetTurnDiffError | _tag, message | TNES | req | cause Defect opt | checkpointDiff.ts:51-57 |
| OrchestrationGetFullThreadDiffError | _tag, message | TNES | req | cause Defect opt | checkpointDiff.ts:59-65 |

There are no file change kinds in this file. Per-file data lives in orchestrationV2.ts (OrchestrationV2FileChangeDetail at orchestrationV2.ts:1252-1259; OrchestrationV2CheckpointFileSummary {path TNES, kind TNES open string, additions, deletions NonNegativeInt} at orchestrationV2.ts:1194-1199).

RPC: "orchestration.getTurnDiff" and "orchestration.getFullThreadDiff" (orchestrationV2.ts:3140-3141, 3570-3577; rpc.ts:1565-1577, errors unioned with EnvironmentAuthorizationError).

Server semantics (apps/server/src/checkpointing/CheckpointDiffQuery.ts): ignoreWhitespace defaults to true (86); from equal to to returns an empty diff (94-103); turn counts are checkpoint `appRunOrdinal` values of ready checkpoints of completed runs (115-128, 138-140); toTurnCount above the maximum fails with CheckpointTurnRangeUnavailableError (129-136); fromTurnCount 0 means the baseline of the root_run scope (160-171); the full-thread diff is the turn diff from 0, and toTurnCount 0 returns an empty diff (51, 220-245). Tests: checkpointDiff.test.ts:15-75.

---

## 14. project.ts

### 14.1 Scripts and icons
| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ProjectScriptIcon | | Literals | | "play", "test", "lint", "configure", "build", "debug" | project.ts:23-30 |
| ProjectScript | id | TNES | req | | project.ts:34 |
| | name | TNES | req | | project.ts:35 |
| | command | TNES | req | | project.ts:36 |
| | icon | ProjectScriptIcon | req | | project.ts:37 |
| | runOnWorktreeCreate | Boolean | req | setup script role | project.ts:38 |
| | runOnSettle | Boolean | opt | run in the thread worktree when the thread settles | project.ts:40 |
| | async | Boolean | opt | start the agent while setup runs unless disabled | project.ts:42 |
| | previewUrl | TNES | opt | | project.ts:43 |
| | autoOpenPreview | Boolean | opt | | project.ts:44 |
| ProjectIconColor | | Literals | | "gray", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose" | project.ts:48-67 |
| ProjectLucideIconName (internal) | | TNES | | max 64, `/^[a-z0-9]+(?:-[a-z0-9]+)*$/` | project.ts:70-73 |
| ProjectEmoji (internal) | | TNES | | max 32 | project.ts:75 |
| ProjectMonogramText | | TNES | | max 32, `/^[\p{L}\p{N}][\p{L}\p{N}\p{M}‌‍]*$/u`; grapheme count is validated at the server command boundary, not in decoding (comment 77) | project.ts:78-81 |
| lucide icon (internal) | kind / name / color | "lucide" / ProjectLucideIconName / ProjectIconColor | req | | project.ts:83-87 |
| emoji icon (internal) | kind / emoji | "emoji" / ProjectEmoji | req | | project.ts:88-91 |
| monogram icon (internal) | kind / text / color | "monogram" / ProjectMonogramText / ProjectIconColor | req | | project.ts:92-96 |
| ProjectFaviconPath | | TNES | | max 1024, `/\.(?:avif|gif|ico|jpe?g|png|svg|webp)$/i` (used by assets.ts:55, NOT by Project.faviconPath) | project.ts:98-101 |
| ProjectIconOverride | | Union(lucide, emoji, monogram) on `kind` | | what clients send | project.ts:105-109 |
| legacy lucide (internal, read only) | + monogramText, monogram | ProjectMonogramText | opt | legacy monogram carried on a lucide icon | project.ts:117-121 |
| StoredProjectIcon | | decodes legacy monogram into monogram; writes plain shape | | | project.ts:138-146 |
| ReceivedProjectIcon | | ForwardCompatibleUnion on "kind", decoded to NullOr(ProjectIconOverride) | | unknown kind decodes to null (client shows default icon); legacy lucide plus monogram decodes to monogram; known kind with broken payload fails | project.ts:152-163 |

Icon tests: project.test.ts:174-185 (lucide and emoji accepted, bad name or color rejected), 187-206 (monogram text and colors), 214-226 (plain shape round-trips), 228-240 (legacy monogram), 242-260 (unknown kind becomes null, also inside OrchestrationProjectShell).

### 14.2 Project entity and mutations
| Export | Field | Type | Opt | Constraints | Line |
|---|---|---|---|---|---|
| Project | id | ProjectId | req | | project.ts:166 |
| | title | TNES | req | | project.ts:167 |
| | workspaceRoot | TNES | req | | project.ts:168 |
| | repositoryIdentity | RepositoryIdentity | opt or null | | project.ts:169 |
| | faviconPath | TNES | opt or null | not validated as ProjectFaviconPath | project.ts:170 |
| | projectIcon | ReceivedProjectIcon | opt or null | | project.ts:171 |
| | defaultModelSelection | ModelSelection | null (key required) | | project.ts:172 |
| | defaultThreadEnvMode | ThreadEnvMode | opt or null | | project.ts:173 |
| | autoPull | Boolean | opt | background sync, opt-in | project.ts:175 |
| | scripts | ProjectScript[] | req | | project.ts:176 |
| | createdAt, updatedAt | IsoDateTime | req | | project.ts:177-178 |
| | deletedAt | IsoDateTime | null | | project.ts:179 |
| ProjectSnapshot | projects / updatedAt | Project[] / IsoDateTime | req | | project.ts:183-186 |
| ProjectChange | type "project.upserted" | {project: Project} | req | | project.ts:190 |
| | type "project.deleted" | {projectId: ProjectId, deletedAt: IsoDateTime} | req | | project.ts:191-195 |
| ProjectCreatePayload | title / workspaceRoot | TNES | req | | project.ts:200-201 |
| | createWorkspaceRootIfMissing | Boolean | opt | | project.ts:202 |
| | defaultModelSelection | ModelSelection | opt or null | | project.ts:203 |
| | scripts | ProjectScript[] | opt | | project.ts:204 |
| ProjectUpdatePayload | title, workspaceRoot | TNES | opt | | project.ts:209-210 |
| | defaultModelSelection | ModelSelection | opt or null | | project.ts:211 |
| | autoPull | Boolean | opt | | project.ts:212 |
| | projectIcon | ProjectIconOverride | opt or null | | project.ts:213 |
| | faviconPath | TNES | opt or null | | project.ts:214 |
| | defaultThreadEnvMode | ThreadEnvMode | opt or null | | project.ts:215 |
| | scripts | ProjectScript[] | opt | | project.ts:216 |
| ProjectMutation | type "project.create" | commandId CommandId, projectId ProjectId + ProjectCreatePayload fields | | | project.ts:221-226 |
| | type "project.update" | commandId, projectId + ProjectUpdatePayload fields | | | project.ts:227-232 |
| | type "project.delete" | commandId, projectId, force Boolean opt | | | project.ts:233-238 |
| ProjectMutationError | _tag, commandId, message | CommandId, String | req | cause Defect opt | project.ts:242-249 |

RPC: "projects.mutate" takes ProjectMutation and returns Project (rpc.ts:370, 1187-1191); "projects.ensureScratch" takes {} and returns ProjectEnsureScratchResult (rpc.ts:371, 1193-1198); "projects.createNew" (rpc.ts:372, 1200-1205). Also served over HTTP (environmentHttp.ts:58, 647-656). Omitted, false and null values are preserved through mutation envelopes (project.test.ts:126-158).

### 14.3 Workspace file search, list, read, write
| Export | Fields | Line |
|---|---|---|
| ProjectEntryKind | "file", "directory" | project.ts:251 |
| ProjectSearchEntriesInput | cwd TNES req; query TrimmedString max 256 req (may be empty, an empty query is a frecency browse); limit PositiveInt at most 200 req; kind ProjectEntryKind opt; imageOnly Boolean opt | project.ts:254-262 |
| ProjectEntry | path TNES req; kind req; ignored Boolean opt | project.ts:265-269 |
| ProjectSearchEntriesResult | entries ProjectEntry[]; truncated Boolean | project.ts:272-275 |
| ProjectSearchContentsInput | cwd TNES; query String non-empty max 256, NOT trimmed; limit PositiveInt at most 500; caseSensitive, wholeWord, useRegex Boolean; all req | project.ts:278-287 |
| ProjectContentMatchRange | start, end NonNegativeInt | project.ts:290-293 |
| ProjectContentMatch | path TNES; lineNumber PositiveInt; lineContent String; matchRanges ProjectContentMatchRange[] | project.ts:296-301 |
| ProjectSearchContentsResult | matches; truncated Boolean; regexFallbackError String opt | project.ts:304-308 |
| ProjectListEntriesInput | cwd TNES req; directoryPath TrimmedString opt (empty means root; omitted means indexed recursive listing) | project.ts:311-316 |
| ProjectListEntriesResult | entries; truncated Boolean | project.ts:319-322 |
| ProjectEntriesFailure | "workspace_root_not_found", "workspace_root_create_failed", "workspace_root_stat_failed", "workspace_root_not_directory", "search_index_create_failed", "search_index_scan_timed_out", "search_index_search_failed", "directory_list_failed" | project.ts:325-334 |
| ProjectSearchEntriesError | cwd TNES opt; queryLength NonNegativeInt opt; limit PositiveInt opt; failure opt; normalizedCwd, timeout, detail TNES opt; message TNES req; cause opt | project.ts:350-381 |
| ProjectSearchContentsError | same fields as ProjectSearchEntriesError | project.ts:383-412 |
| ProjectListEntriesError | cwd, failure, normalizedCwd, timeout, detail opt; message req; cause opt | project.ts:414-434 |
| ProjectReadFileInput | cwd TNES; relativePath TNES max 512 (workspace-relative or absolute host path) | project.ts:436-441 |
| ProjectReadFileResult | relativePath TNES; contents String; byteLength NonNegativeInt; truncated Boolean | project.ts:444-449 |
| ProjectFileFailure | "workspace_path_outside_root", "resolved_path_outside_root", "path_not_file", "binary_file", "operation_failed" | project.ts:452-458 |
| ProjectFileOperation | "realpath-workspace-root", "realpath-target", "open", "stat", "read", "close", "make-directory", "write-file" | project.ts:461-470 |
| ProjectReadFileError | cwd, relativePath, failure, resolvedPath, resolvedWorkspaceRoot, operation, operationPath opt; message TNES req; cause opt | project.ts:484-507 |
| ProjectWriteFileInput | cwd TNES; relativePath TNES max 512; contents String | project.ts:509-513 |
| ProjectWriteFileResult | relativePath TNES | project.ts:516-518 |
| ProjectEnsureScratchResult | projectId ProjectId | project.ts:522-524 |
| ProjectCreateNewInput | name TNES max 200 | project.ts:528-530 |
| ProjectCreateNewResult | projectId req; workspaceRoot TNES req; commitError TNES optKey | project.ts:533-538 |
| ProjectWriteFileError | same fields as ProjectReadFileError | project.ts:541-564 |

Ordering: no project ordering field exists in these contracts. Sidebar sort order is a client setting SidebarProjectSortOrder "updated_at", "created_at", "manual", default "updated_at" (settings.ts:57-59, 481-483). Manual order is web-local UI state (apps/web/src/uiStateStore.ts:24, 38). Script order is the array order of `scripts`.

---

## 15. orchestrationProject.ts and the referenced parts of environment.ts

OrchestrationProjectShell (orchestrationProject.ts:9-27), "Project summary shared by the V2 shell and application project APIs":
| Field | Type | Opt | Line |
|---|---|---|---|
| id | ProjectId | req | orchestrationProject.ts:10 |
| title | TNES | req | orchestrationProject.ts:11 |
| workspaceRoot | TNES | req | orchestrationProject.ts:12 |
| repositoryIdentity | RepositoryIdentity | opt or null | orchestrationProject.ts:13 |
| defaultModelSelection | ModelSelection | null (key required) | orchestrationProject.ts:14 |
| defaultThreadEnvMode | ThreadEnvMode | opt or null; null or absent means no override, clients fall back to t3.json then the global setting (comment 15-16) | orchestrationProject.ts:17 |
| autoPull | Boolean | opt | orchestrationProject.ts:20 |
| faviconPath | TNES | opt or null | orchestrationProject.ts:22 |
| projectIcon | ReceivedProjectIcon | opt or null | orchestrationProject.ts:23 |
| scripts | ProjectScript[] | req | orchestrationProject.ts:24 |
| createdAt | IsoDateTime | req | orchestrationProject.ts:25 |
| updatedAt | IsoDateTime | req | orchestrationProject.ts:26 |

Difference from Project: no `deletedAt`. V2 usage: OrchestrationV2ShellSnapshot.projects (orchestrationV2.ts:1939-1942); shell stream item {kind "project.updated", sequence NonNegativeInt, project} (1960-1963); OrchestrationV2ArchivedShellSnapshot.projects (3155-3159).

environment.ts parts:
| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| ThreadEnvMode | | Literals | | "local", "worktree" | environment.ts:61 |
| RepositoryIdentityLocator | source | Literal "git-remote" | req | | environment.ts:230 |
| | remoteName | TNES | req | | environment.ts:231 |
| | remoteUrl | TNES | req | | environment.ts:232 |
| RepositoryOrigin | canonicalKey | TNES | req | | environment.ts:242 |
| | displayName | TNES | optKey | | environment.ts:243 |
| RepositoryIdentity | canonicalKey | TNES | req | normalized `host/owner/repo` (pullRequest.ts:1304-1306) | environment.ts:248 |
| | locator | RepositoryIdentityLocator | req | | environment.ts:249 |
| | webUrl | TNES | optKey | | environment.ts:251 |
| | rootPath | TNES | optKey | | environment.ts:252 |
| | displayName | TNES | optKey | | environment.ts:253 |
| | provider | TNES | optKey | | environment.ts:254 |
| | owner | TNES | optKey | | environment.ts:255 |
| | name | TNES | optKey | | environment.ts:256 |
| | origin | RepositoryOrigin | optKey | fork's own remote | environment.ts:257 |

Helpers: repositoryGroupingKeyOf (environment.ts:262-264), repositoryGroupingDisplayNameOf (environment.ts:267-271).

---

## 16. worktreeSetup.ts

| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| WORKTREE_SETUP_DETAIL_MAX_LENGTH / TAIL_LINE / ERROR | | const | | 200 / 400 / 1000 | worktreeSetup.ts:11-13 |
| WorktreeSetupStageId | | Literals | | "fetch", "checkout", "submodules", "setup-script", "agent" | worktreeSetup.ts:15-21 |
| WorktreeSetupStageStatus | | Literals | | "pending", "running", "done", "skipped", "warning", "failed" | worktreeSetup.ts:24-31 |
| WorktreeSetupStage | id | WorktreeSetupStageId | req | | worktreeSetup.ts:35 |
| | status | WorktreeSetupStageStatus | req | | worktreeSetup.ts:36 |
| | startedAt, endedAt | IsoDateTime | null | | worktreeSetup.ts:37-38 |
| | percent | Int | null | between 0 and 100 (checkout stage only) | worktreeSetup.ts:40 |
| | detail | String | null | max 200 | worktreeSetup.ts:42 |
| | tail | String[] | req | each max 400, newest last | worktreeSetup.ts:44 |
| WorktreeSetupPhase | | Literals | | "running", "done", "failed", "cancelled" | worktreeSetup.ts:48 |
| WorktreeSetupSnapshot | threadId | ThreadId | req | | worktreeSetup.ts:52 |
| | phase | WorktreeSetupPhase | req | | worktreeSetup.ts:53 |
| | startedAt | IsoDateTime | req | | worktreeSetup.ts:54 |
| | endedAt | IsoDateTime | null | | worktreeSetup.ts:55 |
| | branch, baseRef, worktreePath | TNES | null | | worktreeSetup.ts:56-58 |
| | setupScript | {name TNES, command TNES, terminalId TNES} | null | | worktreeSetup.ts:60-66 |
| | stages | WorktreeSetupStage[] | req | | worktreeSetup.ts:67 |
| | error | String | null | max 1000 | worktreeSetup.ts:69 |
| | sequence | NonNegativeInt | req | | worktreeSetup.ts:70 |
| WORKTREE_SETUP_ACTIVITY_KIND | | const | | "worktree-setup" | worktreeSetup.ts:82 |
| WorktreeSetupSubscribeInput | threadId | ThreadId | req | | worktreeSetup.ts:84-86 |
| WorktreeSetupStreamEvent | | NullOr(WorktreeSetupSnapshot) | | null means no setup is tracked; sent first, then after every change | worktreeSetup.ts:90 |
| WorktreeSetupCancelInput | threadId | ThreadId | req | | worktreeSetup.ts:93-95 |
| WorktreeSetupCancelResult | cancelled | Boolean | req | | worktreeSetup.ts:98-100 |
| WORKTREE_SETUP_STAGE_ORDER | | const | | fetch, checkout, submodules, setup-script, agent | worktreeSetup.ts:103-109 |
| worktreeSetupStageLabel | | function | | "Fetch base branch", "Check out files", "Init submodules", "Run setup script", "Start agent" | worktreeSetup.ts:111-124 |

RPC: "subscribeWorktreeSetup" stream (rpc.ts:556, 1306-1311) and "worktreeSetup.cancel" (rpc.ts:557, 1313-1317). Server tracker: apps/server/src/project/WorktreeSetupTracker.ts. Client helpers read a recorded "worktree-setup" activity (packages/client-runtime/src/worktreeSetup.ts:17-28), but no server reference to WORKTREE_SETUP_ACTIVITY_KIND was found by grep, so whether this build records that activity is UNVERIFIED.

---

## 17. secretRequest.ts

| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| SecretRequestAnswerInput | threadId | ThreadId | req | | secretRequest.ts:10 |
| | turnItemId | TurnItemId | req | the V2 secret_request turn item | secretRequest.ts:11 |
| | answer | Union on `type` | req | {type "save", secret TNES} or {type "decline"} | secretRequest.ts:12-15 |
| SecretRequestFailureReason | | Literals | | "load_failed", "not_found", "already_answered", "agent_stopped", "store_failed", "record_failed", "invalid_ref", "read_failed", "ref_unavailable", "ref_expired", "consume_failed" | secretRequest.ts:19-38 |
| SecretRequestError | _tag "SecretRequestError", reason | SecretRequestFailureReason | req | message from the table at 19-32 | secretRequest.ts:42-52 |
| | cause | Defect | optKey | | secretRequest.ts:46 |

Note: `secret` is TNES, so leading and trailing whitespace of a secret is trimmed by the schema.

RPC: "secrets.answerRequest" with no success payload (rpc.ts:506, 1757-1760). V2 side: secret_request turn item {type "secret_request", label TNES, reason String, placeholder String opt, secretStatus "pending", "saved", "declined", "cancelled"} (orchestrationV2.ts:1352-1370); internal command "secret_request.record" (orchestrationV2.ts:3117-3130).

---

## 18. threadTitle.ts

| Export | Field | Type | Opt | Line |
|---|---|---|---|---|
| ThreadTitleRegeneration | requestId | CommandId | req | threadTitle.ts:7 |
| | startedAt | IsoDateTime | req | threadTitle.ts:8 |

Used by MCP payloads (threadMetadataMcp.ts:12, orchestratorMcp.ts:27), not by V2. V2 defines its own inline `titleRegeneration` opt or null {requestId CommandId, startedAt DateTimeUtc} (orchestrationV2.ts:419-426, 1919-1925) and {requestId, startedAt DateTimeUtcFromString} in JSON variants (2007-2012, 2430-2436).

---

## 19. threadSearch.ts (cross-thread search)

| Export | Field | Type | Opt | Constraints / literals | Line |
|---|---|---|---|---|---|
| OrchestrationThreadSearchSource | | Literals | | "user", "assistant" | threadSearch.ts:11 |
| OrchestrationSearchThreadsInput | query | TrimmedString | req | min 2, max 200 | threadSearch.ts:17 |
| | limit | Int | optKey | between 1 and 50 | threadSearch.ts:18 |
| OrchestrationThreadSearchMatch | threadId | ThreadId | req | | threadSearch.ts:23 |
| | projectId | ProjectId | req | | threadSearch.ts:24 |
| | source | OrchestrationThreadSearchSource | req | | threadSearch.ts:25 |
| | snippet | String | req | max 240 | threadSearch.ts:26 |
| | messageCreatedAt | IsoDateTime | null | | threadSearch.ts:27 |
| OrchestrationSearchThreadsResult | matches | OrchestrationThreadSearchMatch[] | req | | threadSearch.ts:31-33 |
| OrchestrationSearchThreadsError | _tag, message | TNES | req | cause Defect opt | threadSearch.ts:36-42 |

RPC "orchestration.searchThreads" (orchestrationV2.ts:3142; rpc.ts:1596-1600). Not the same as the V2 in-thread find "orchestration.searchThread" (OrchestrationV2SearchThreadInput/Result at orchestrationV2.ts:3505-3550).

---

## 20. assistantCitations.ts

| Export | Field | Type | Opt | Constraints | Line |
|---|---|---|---|---|---|
| ASSISTANT_CITATION_MAX_TEXT_LENGTH / MAX_COMMENT_LENGTH / CONTEXT_LENGTH | | const | | 8000 / 8000 / 32 | assistantCitations.ts:4-6 |
| AssistantCitation | version | Literal 1 | req | | assistantCitations.ts:13 |
| | environmentId | EnvironmentId | req | max 512 | assistantCitations.ts:14 |
| | threadId | ThreadId | req | max 512 | assistantCitations.ts:15 |
| | messageId | MessageId | req | max 512 | assistantCitations.ts:16 |
| | text | String | req | non-empty, max 8000 | assistantCitations.ts:17-20 |
| | comment | String | opt | max 8000 | assistantCitations.ts:21-23 |
| | start | NonNegativeInt | req | at most Number.MAX_SAFE_INTEGER; UTF-16 offset in rendered text | assistantCitations.ts:24 |
| | end | NonNegativeInt | req | same | assistantCitations.ts:25 |
| | prefix | String | req | max 32 | assistantCitations.ts:26 |
| | suffix | String | req | max 32 | assistantCitations.ts:27 |
| | (struct check) | | | end > start and text.trim() non-empty | assistantCitations.ts:28-30 |

AssistantCitation is not a field of any other contract schema (grep found no other reference in packages/contracts/src). It travels inside message text as a Markdown link (packages/shared/src/assistantCitations.ts):
- `[Assistant quote](t3-citation://v1/<environmentId>/<threadId>/<messageId>?text=...&start=...&end=...&prefix=...&suffix=...[&comment=...])` (9-17, 38-51, 107-109).
- Path parts use encodeURIComponent with !'()* also percent-encoded (20-25); the query is built with URLSearchParams (42-49).
- Parse requires protocol "t3-citation:", host "v1", exactly 3 path parts, no user, password, port or hash, exactly the keys text, start, end, prefix, suffix plus optional comment, and start and end of 1 to 16 digits (53-99).

---

## 21. UserInputQuestion (two variants)

providerRuntime.ts UserInputQuestion (488-499) with UserInputQuestionOption (const 481-485, type exported 486):
| Field | Type | Opt | Line |
|---|---|---|---|
| id | TNES | req | providerRuntime.ts:489 |
| header | TNES | req | providerRuntime.ts:490 |
| question | TNES | req | providerRuntime.ts:491 |
| options | [{label TNES req (482), description String req, may be empty (483), value String opt (484)}] | req | providerRuntime.ts:492 |
| allowCustomAnswer | Boolean | opt | providerRuntime.ts:493 |
| initialAnswer | String | opt, kept verbatim (whitespace and "" preserved) | providerRuntime.ts:495 |
| multiSelect | Boolean | opt with ctorDefault(false) | providerRuntime.ts:496-498 |

orchestrationV2.ts OrchestrationV2UserInputQuestion (orchestrationV2.ts:1151-1167), the shape V2 clients receive:
| Field | Type | Opt | Line |
|---|---|---|---|
| id | TNES | req | orchestrationV2.ts:1152 |
| header | TNES | req | orchestrationV2.ts:1153 |
| question | TNES | req | orchestrationV2.ts:1154 |
| options | [{label TNES req (1157), description TNES req, must be non-blank (1158), value String opt (1159)}] | req | orchestrationV2.ts:1155-1161 |
| multiSelect | Boolean | opt (no constructor default) | orchestrationV2.ts:1162 |
| allowCustomAnswer | Boolean | opt | orchestrationV2.ts:1163 |
| initialAnswer | String | opt, verbatim | orchestrationV2.ts:1165 |
| required | Boolean | opt (V2 only) | orchestrationV2.ts:1166 |

Test: initialAnswer absent stays undefined, and "", whitespace-padded and long multi-line values are preserved exactly for both schemas (userInputQuestion.test.ts:7-22). V2 usage: user_input_request turn item `questions` (orchestrationV2.ts:1422, 2200), `questionAnswer` opt UserInputAttachmentAnswerPayload (1423, 2201), `responseMode` opt Literal "message" (1424).

---

## 22. usage.ts and mcpApps.ts

Neither file is imported by orchestrationV2.ts, so no part of them is referenced from it. For orientation only:
- usage.ts reaches the wire through "server.getUsageSummary" (rpc.ts:319, 495, 865-867). Key facts: USAGE_CONTRACT_VERSION 6 (usage.ts:24), USAGE_MERGE_COMPATIBLE_SINCE 4 (usage.ts:32), UsageProviderKind "claude", "codex", "grok", "cursor", "opencode", "antigravity" (usage.ts:34-41; a closed vocabulary distinct from ProviderDriverKind), UsageDay TNES matching `/^\d{4}-\d{2}-\d{2}$/` with brand (usage.ts:50-54), buckets and sources are ForwardCompatibleArray (usage.ts:241-242).
- mcpApps.ts reaches the wire through "mcpApps.callTool", "mcpApps.toolInfo", "mcpApps.readResource", "mcpApps.updateModelContext" (rpc.ts:387-390, 1258-1279). Every request targets a V2 tool-call turn item through {threadId ThreadId, itemId TurnItemId} (mcpApps.ts:10-13). Shapes: McpAppCallToolInput {threadId, itemId, name TNES, arguments Record(String, Unknown)} (15-19); McpAppCallToolResult {content Unknown[] req, structuredContent opt, isError Boolean opt, _meta opt} (23-28); McpAppToolInfoInput {threadId, itemId, name TNES} (31-34); McpAppToolInfo {callable Boolean, readOnly Boolean, title String opt, tool Unknown opt} (41-47); McpAppReadResourceInput {threadId, itemId, uri TNES} (50-53); McpAppReadResourceResult {contents Unknown[]} (57-59); McpAppUpdateModelContextInput {threadId, itemId, conversationThreadId ThreadId, content Unknown[] opt, structuredContent Record opt} (66-75); McpAppRequestErrorReason "not-an-app", "provider-unsupported", "session-stopped", "tool-not-callable", "unsupported-content", "request-failed" (78-85); McpAppRequestError {_tag, threadId, reason, cause opt} (88-114).

---

## 23. Helper functions clients rely on

### 23.1 Ids
- Client generators: randomUUID, newProjectId, newThreadId, newMessageId (apps/web/src/lib/utils.ts:36-50). CommandId allocation (packages/client-runtime/src/operations/commands.ts:261-267).
- Server allocator formats: packages/provider-core/src/server/IdAllocator.ts (section 2.2).
- Attachment ids: toSafeThreadAttachmentSegment (apps/server/src/attachmentStore.ts:29-42), createPendingAttachmentId (64-66), createAttachmentId (84-90), createDeterministicAttachmentId (92-104), planAttachmentClaim (207-251).
- defaultInstanceIdForDriver (providerInstance.ts:167-168); isProviderDriverKind (providerInstance.ts:73-75).

### 23.2 Model selection (packages/shared/src/model.ts unless noted)
- modelSelectionCommandType (18-25): same instanceId gives "thread.model-selection.set", a different one gives "provider.switch".
- getProviderOptionStringSelectionValue (56-62), getProviderOptionBooleanSelectionValue (64-70), getModelSelectionStringOptionValue (72-77), getModelSelectionBooleanOptionValue (79-84).
- modelSelectionsEqual (110-122).
- getProviderOptionDescriptors (190-203): merges selections into descriptor currentValue; a select value not among the options falls back to currentValue or the isDefault option (124-145).
- getProviderOptionCurrentValue (221-241), getProviderOptionCurrentLabel (243-267).
- buildProviderOptionSelectionsFromDescriptors (269-286), buildExplicitProviderOptionSelectionsFromDescriptors (288-300).
- isClaudeUltrathinkPrompt (302-304).
- normalizeModelSlug (331-345): trims and applies MODEL_SLUG_ALIASES_BY_PROVIDER, default driver codex (15). normalizeCustomModelSlug (348-354): trim only.
- readCustomModelEntries (372-402), toCustomModelSetting (408-419).
- resolveSelectableModel (421-459): exact slug, then name case-insensitive, then alias, then normalized slug.
- createModelSelection (474-485).
- resolvePromptInjectedEffort (495-508), applyClaudePromptEffortPrefix (510-529): prefixes "Ultrathink:\n" unless the text is a slash command.
- Web app (not shared): resolveDefaultProviderModelSelection keeps a valid stored selection verbatim, otherwise picks another selectable instance with its default model and no options (apps/web/src/providerInstances.ts:331-340). resolveAppModelSelectionForInstance (apps/web/src/modelSelection.ts:277-319). resolveAppModelSelectionState, the text generation fallback chain ending at DEFAULT_TEXT_GENERATION_MODEL_BY_PROVIDER (apps/web/src/modelSelection.ts:350 onward). resolveNewThreadModelSelectionOverride: the project defaultModelSelection wins, else a selection carried from another draft (apps/web/src/lib/chatThreadActions.ts:47-57).
- Server compile of options: compileClaudeModelSelection (apps/server/src/claudeModelOptions.ts:28-59), getCodexServiceTierOptionValue (apps/server/src/codexModelOptions.ts:7-14).

### 23.3 Composer context and citations
- packages/shared/src/composerContextReferences.ts: formatComposerContextHref (26-28), parseComposerContextHref (30-40), sanitizeComposerContextLabel (43-50), formatComposerContextReference (52-60), collectComposerContextReferences (73-93), replaceComposerContextReferences (95-106), formatComposerContextProviderMarker (121-131), projectComposerContextForProvider (265-298), remapComposerContextAttachments (301-323).
- serializeLegacyContextMessage (packages/shared/src/composerContextLegacySend.ts:13), mobile serializeComposerMessageForServer (apps/mobile/src/lib/composerContext.ts:232-240).
- packages/shared/src/assistantCitations.ts: withAssistantCitationComment (28-35), formatAssistantCitationHref (38-51), parseAssistantCitationHref (53-99), assistantCitationLabel (102-105), serializeAssistantCitation (107-109), collectAssistantCitations (111-125), assistantCitationsToPlainText (128-136), expandAssistantCitationsForProvider (139 onward).

### 23.4 Attachments
- isProviderSendTurnSupportedImageMimeType (chatAttachment.ts:29-31), getProviderAttachmentLimitError (chatAttachment.ts:220-237).
- Client persist step: only attachments that carry `dataUrl` are sent to "assets.persistChatAttachments" (packages/client-runtime/src/operations/commands.ts:276 onward).

### 23.5 Pull request links
- packages/shared/src/threadPullRequests.ts: normalizeThreadPullRequestKey lowercases host and repository and recovers Forgejo authorities (19-37); legacyThreadPullRequestKey (40-64); threadPullRequestKeysEqual and threadPullRequestKeyOf, key string `<host>/<repository>#<number>` (67-77); visibleThreadPullRequests hides "stack-dismissed" (81-85); resolveThreadCurrentPullRequest, unsynced links count as open (87-91, 113-142); resolveThreadCurrentPullRequestLink (145-151); legacyLinkedPullRequestOf (154-202).
- pullRequestHostOf (pullRequest.ts:1311-1332): first segment of canonicalKey, or the remote host for forgejo http(s) remotes, or the provider kind.

### 23.6 Projects
- packages/shared/src/projectScripts.ts: resolveProjectScripts (17-27), projectScriptsInheritDefaults (29-39), projectScriptCwd (49-56), projectScriptRuntimeEnv with T3CODE_PROJECT_ROOT and T3CODE_WORKTREE_PATH (58-71), setupProjectScript, the first runOnWorktreeCreate script (73-75), projectScriptMenuLabel (78-84), settleProjectScript, the first runOnSettle script (86-88).
- repositoryGroupingKeyOf / repositoryGroupingDisplayNameOf (environment.ts:262-271).

### 23.7 Worktree setup
- worktreeSetupStageLabel and WORKTREE_SETUP_STAGE_ORDER (worktreeSetup.ts:103-124).
- findRecordedWorktreeSetup (packages/client-runtime/src/worktreeSetup.ts:17-28); resolveVisibleWorktreeSetup, where the live snapshot wins when its sequence is greater than or equal to the recorded one (packages/client-runtime/src/worktreeSetup.ts:43-60).

### 23.8 User input answers
- resolvePendingUserInputAnswer (apps/web/src/pendingUserInput.ts:42-71), buildPendingUserInputAnswers (apps/web/src/pendingUserInput.ts:137-152).

### 23.9 Runtime vocabulary
- isToolLifecycleItemType (providerRuntime.ts:119-121).

---

## 24. UNVERIFIED and open items

1. Effect 4.0.1 internals could not be read (no node_modules in the checkout). UNVERIFIED: whether withDecodingDefault fields are always emitted on encode; whether withConstructorDefault affects decoding; the JSON form of `Schema.Defect()` causes in tagged errors; toCodecJson handling of NaN or Infinity in plain Schema.Number fields; that isMaxLength counts UTF-16 code units; whether a required `Schema.Unknown` field (for example RuntimeEventRaw.payload, ModelSelectionSource.model) accepts a missing key; whether `Schema.Record(String, Unknown)` accepts arrays.
2. Whether this build records the "worktree-setup" thread activity: no server reference to WORKTREE_SETUP_ACTIVITY_KIND was found. Only the live subscribeWorktreeSetup stream is verified.
3. Whether "thread.pull-request-link.sync", "thread.pull-request.sync" and "thread.pull-request-watch.sync" are client-dispatchable or server-internal was not traced.
4. Server id formats (section 2.2) and attachment id formats (section 11.3) are verified in code but are implementation details, not contract. Clients must treat every id as opaque.
5. The default `ignoreWhitespace = true` for diffs and the turn-count semantics (section 13) are server behavior, not contract.
6. ProviderRuntimeEvent and most of provider.ts are server-internal by grep (no rpc.ts or client reference); a future server could expose them.
7. Option ids and values (section 5.3) are provider-owned and dynamic; the listed ids are what this build's server code uses, not a closed set.
