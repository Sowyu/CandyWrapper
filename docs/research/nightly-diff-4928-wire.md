# Nightly 4928 wire audit

Task wire-4928, 2026-11-19. I compared `v0.1.4-nightly.20261028.3824` (eb751fa073) with `v0.1.11-nightly.20261119.4928` (e8c4824b70). The scope is `packages/contracts`, `packages/client-runtime` and `packages/shared`, plus server code where it changes what a client receives. Citations of the form `file:line` point into the 4928 tree unless they say 3824.

The contract diff is 5,553 lines added and 236 removed in 78 non-test files. `ORCHESTRATION_PROTOCOL_VERSION` stays at 2 (`packages/contracts/src/environment.ts:13`). No RPC method was removed or renamed, no orchestration command or event type was removed, and across every contract file only one string literal disappeared: `UsageSource.action: "enableCursorKeychain"`. Every RPC payload struct still ignores unknown keys, because the server never sets `onExcessProperty: "error"` on RPC schemas. So nothing in this range makes a 3824-era CandyWrapper fail to connect or fail to decode the shell or thread streams. The breaks below are places where it decodes fine but shows the wrong thing or quietly does nothing.

Counts: 7 breaks, 33 additions, 235 RPC methods in `WsRpcGroup` at 4928, of which 33 are new, 78 changed and 124 unchanged, and none removed.

## 1. Breaks

### B1. Checkpoints over 200 files arrive truncated

A 4928 server caps `files` on every checkpoint and checkpoint turn item at 200 entries and adds `filesTotal: {count, additions, deletions}` for the full list. It does this for every client, with no opt-in.

- T3: `packages/contracts/src/orchestrationV2.ts:1495` (`OrchestrationV2CheckpointFileTotals`), `:1514` and `:1833` (`filesTotal`); `apps/server/src/orchestration-v2/WireProjection.ts:27` (`MAX_WIRE_CHECKPOINT_FILES = 200`) and `:115-130`.
- Commit 7f39a860d9, PR #27110.
- CandyWrapper: `Checkpoint` in `Packages/CandyKit/Sources/T3Protocol/Domain/ThreadProjection.swift:204`, the checkpoint case of `TurnItem` in `T3Protocol/Domain/TurnItem.swift`, and their readers in `Features/Thread/ChangedFilesCardView.swift` and `Features/Thread/RightPanelView.swift`.
- Fix: decode `filesTotal` on both types. Where it is present, take the file count and the +/- totals from it, and tell the user the list is partial instead of counting `files`. Load the full list from `orchestration.getTurnDiff` or `getFullThreadDiff` when the user opens the diff.

### B2. Side chats show up in the sidebar as ordinary threads

4928 adds side chats, hidden forks marked with `lineage.sideChat: true`. T3 hides any thread where `isListedThreadLineage` is false, which now means a subagent or a side chat. The shell stream still sends side chat shells to every client.

- T3: `packages/contracts/src/orchestrationV2.ts:173` (`sideChat`), `:178-179` (`isListedThreadLineage`), `:3549` (`sideChat` on the fork command); `apps/server/src/orchestration-v2/ShellStream.ts:212` and `:244` (older-settled counts and hidden-child ancestors use it); capability `sideChats` at `packages/contracts/src/environment.ts:102`.
- Commit 50c1c5dc53, PR #26901.
- CandyWrapper: `ThreadLineage` in `T3Protocol/Domain/ThreadShell.swift:199` has no `sideChat`. The sidebar and thread relationship code filter only on `relationshipToParent == .subagent` (`T3Store/ThreadRelationships.swift:106`, `T3Store/ChildThreadInputs.swift:9`).
- Fix: add `sideChat: Bool?` to `ThreadLineage` and one `isListed` helper that mirrors `isListedThreadLineage`. Use it wherever the sidebar, search results and settled counts now test for subagents. This only shows up once a 4928 web, desktop or mobile client has opened a side chat on the same server.

### B3. Scheduled tasks with a `once` schedule disappear from the list

4928 adds a one-shot schedule, `{type: "once", runAt}`, where `runAt` is an ISO date-time with an offset. Agents create these through `schedule_task`.

- T3: `packages/contracts/src/scheduledTask.ts:67` (`ScheduledTaskOnceSchedule`), added to `ScheduledTaskSchedule` at `:197` and `ScheduledTaskUpsertSchedule` at `:212`.
- Commit 4ac97be2b6, PR #28104.
- CandyWrapper: `ScheduledTaskSchedule.init?(json:)` in `T3Protocol/Domain/ScheduledTasks.swift:16-35` returns nil for an unknown `type`. `ScheduledTask.init?(json:)` at `:126-128` then returns nil, so `scheduledTasks.subscribe` drops the task without an error.
- Fix: add `case once(runAt: String)` to the schedule enum, decode and encode it, and show it in the list and editor. Until the editor supports it, keep unknown schedules as raw JSON so a task never vanishes. Adopt `threadMode` (A23) in the same change.

### B4. T3 Connect sign-in stalls when the host requires device approval

A host can now turn on `requireConnectDeviceApproval`. The server then gives an unknown T3 Connect device a bootstrap credential that waits for approval. Exchanging that credential at `/oauth/token` fails with HTTP 403 and body `{_tag: "EnvironmentConnectApprovalPendingError", code: "connect_approval_pending", traceId}` until someone approves the device on the host. The setting defaults to false, and devices that already connected before it was turned on stay trusted.

- T3: `packages/contracts/src/environmentHttp.ts:216` (error), `packages/contracts/src/settings.ts:1394` (setting), `apps/server/src/auth/http.ts:441-450`, `apps/server/src/auth/EnvironmentAuth.ts:1249-1273` (`issueConnectCredentialLocked`), `apps/server/src/cloud/CloudLink.ts:1644`. The device shows a code made by `connectDeviceVerificationCode(thumbprint)` at `packages/contracts/src/auth.ts:343`, and the host lists it in `AuthPairingLink.connectDeviceRequest` and `AuthAccessSnapshot.connectDevices` (`auth.ts:409`).
- Commit a2edd281df, PR #36419.
- CandyWrapper: the environment token exchange in `T3Transport/EnvironmentHTTP.swift:107` decodes the error body as `EnvironmentHTTPError` (`T3Protocol/Wire/AuthHTTP.swift:122-135`), which does not know this tag. The Connect flow then shows a generic auth failure.
- Fix: recognise `code == "connect_approval_pending"`, show "waiting for approval on <host>" with the verification code derived from the DPoP key thumbprint, and retry the relay mint and exchange on a slow timer until it succeeds or the user cancels. The host side of this flow is addition A18.

### B5. The Cursor keychain usage toggle does nothing

4928 removed `cursorKeychainUsageEnabled` from settings and `action: "enableCursorKeychain"` from `UsageSource`, because Cursor usage now comes from the SDK account.

- T3: removed from `packages/contracts/src/settings.ts` (3824 line 1300) and `packages/contracts/src/usage.ts` (3824 line 94).
- Commit 4c3a9d5818, PR #32448.
- CandyWrapper: `Features/Settings/ProvidersSettingsView.swift:459` reads the key and `:489` writes it through `server.updateSettings`. The server ignores the key, so the switch flips back on the next settings event. `T3Protocol/Domain/Usage.swift:150` still documents the action.
- Fix: remove the toggle and the action handling.

### B6. Plan mode, context meter and legacy sidebar settings are gone

4928 removed `planModeEnabled`, `contextWindowMeterEnabled` and `legacySidebarEnabled` from `ServerSettings` and the patch. The server no longer sends them and ignores writes to them. The `plan` interaction mode itself stays in `ProviderInteractionMode` (`packages/contracts/src/providerPolicy.ts:45`).

- T3: removed from `packages/contracts/src/settings.ts` (3824 lines 465, 466, 479).
- Commit 521ac7c218, PR #33131.
- CandyWrapper: `T3Protocol/Domain/Settings.swift:80`, `:81` and `:89` define specs for them. `Features/Settings/BetaSettingsView.swift:20-21` and `Features/Sidebar/SidebarView.swift:361` read `legacySidebarEnabled` as a fallback and write it as false. Nothing breaks, but the specs and fallbacks are dead and the Beta screen keeps a key T3 has dropped.
- Fix: delete the three specs and the `legacySidebarEnabled` fallback. Check UI parity for plan mode separately, since T3 removed the composer toggle in the same PR.

### B7. Thread visit events and two new thread events are dropped from the thread stream

When a thread is visited, 4928 records and streams `thread.visit-recorded` with payload `{lastVisitedAt, opens}` instead of a whole-thread `thread.visited`. The projection store applies it as `thread.visited`, so shell `thread.updated` items stay correct, but `subscribeThread` subscribers get the new type. `thread.tags-updated` and `thread.issue-synced` are new whole-thread events.

- T3: `packages/contracts/src/orchestrationV2.ts:2033` and `:2980` (`thread.visit-recorded`), `:2012` and `:2017` (tags and issue events); `apps/server/src/orchestration-v2/Orchestrator.ts:4044`; `apps/server/src/orchestration-v2/ProjectionStore.ts:2438-2445`; client reducer `packages/client-runtime/src/state/orchestrationV2Projection.ts` (`case "thread.visit-recorded"`).
- Commit d19467a59e, PR #36233 (visit). Tags and issues come from the thread tags and issue tracking work in A2 and A1.
- CandyWrapper: `ThreadEventType.threadPayloadTypes` and `known` in `T3Protocol/Domain/ThreadStream.swift:201-217` lack all three. They decode as `.unknownEvent`, which advances the cursor and discards them. The open thread's `AppThread.lastVisitedAt` and `opens` go stale until the next snapshot. Sidebar unread state reads the shell, so it is not affected.
- Fix: add `thread.tags-updated` and `thread.issue-synced` to `threadPayloadTypes`. Add `thread.visit-recorded` with a `ThreadVisit` payload that merges `lastVisitedAt` and, when present, `opens` into the held `AppThread`, as `applyOrchestrationV2ThreadVisit` does (`orchestrationV2.ts:558-567`).

### Checked and not breaks

- `server.updateSettings` takes `ClientServerSettingsPatch` (`settings.ts:1997`), which omits `defaultTheme`, `defaultThemeSetAt`, `defaultAppearance` and `defaultAppearanceSetAt`. CandyWrapper never writes them. Commit 42057b82d0, PR #35247.
- `/api/connect/link-proof` and `/api/connect/relay-config` now need the new `relay:configure` scope (`apps/server/src/cloud/http.ts:120-128`, commit a941ab544d, PR #37823). CandyWrapper calls neither. It uses `/api/connect/preferences`, which still needs `relay:write`.
- Settings secrets can now be secret provider references. A client that does not send `clientCapabilities=settingsSecretReferences` on the socket URL sees a reference as the redacted marker, and sending the marker back keeps the reference (`apps/server/src/serverSettings.ts:143-172`, `apps/server/src/ws.ts:802`). Commit a10490937d, PR #27760.
- Large server frames are split only for clients that pass `frameParts=1` (`packages/shared/src/socketFrameParts.ts:6`, `apps/server/src/ws.ts:3728`). Commit b9522c845b, PR #23758.
- The shell stream's new `snapshot-required` item and `ShellResumable` HTTP reply only reach clients that send `httpSnapshotFallback` or `resumeFrom` (`orchestrationV2.ts:2392-2396`, `:3974`; `environmentHttp.ts:737`, `:767`). CandyWrapper's `ShellStreamItem` would decode `snapshot-required` as `.unknown` anyway.
- `pullRequests.runAction` success became `UndefinedOr(PullRequestSummary)`, but the server still replies with nothing unless the request sets `replyWithSummary: true` (`pullRequest.ts:846`).
- Every new enum value lands on a field CandyWrapper reads as a `String` or an `OpenStringEnum`: `PullRequestMergeMethod` gains `fast-forward`, `AgentSessionSource` gains `pi`, review source kind gains `commit`, `PullRequestFilterOptionKind` gains `references`, composer context gains `response`, and `ServerInstallation` gains `t3-launcher`.
- Provider sign-in URLs must now be `http` or `https` (`packages/contracts/src/providerSetup.ts:18-22`, commit 0517d15c41, PR #36392). That is a server-side check, so CandyWrapper still decodes them.

## 2. Additions

Each item is safe to ignore against a 4928 server. They are grouped by area, and each names the capability flag to check where there is one.

### Threads and orchestration

- A1. Issue tracking. Adds 11 `issues.*` and 3 `issueTrackers.*` RPCs (`rpc.ts:1334-1424`), `ThreadShell.issues` and `AppThread.issues` (`orchestrationV2.ts:485`, `:2222`), commands `thread.issue.link` and `thread.issue.unlink` (`:3302`), event `thread.issue-synced`, and capability `issues` (`environment.ts:100`). Schemas are in the new `packages/contracts/src/issue.ts`. Commits 20501a0221 (PR #19259), 86863beede (PR #19274) and b6a0fd6d62 (PR #38771). CandyWrapper has no issue code yet.
- A2. Thread tags. Adds the `thread.tag.set` command (`orchestrationV2.ts:3227`), `tags` on thread and shell (`:522`, `:2278`), the `thread.tags-updated` event, and `packages/contracts/src/threadTags.ts`.
- A3. Side chats. The fork command takes `sideChat: true` (`orchestrationV2.ts:3549`) behind capability `sideChats`. This is the creating half of B2. Commit 50c1c5dc53, PR #26901.
- A4. Force stop. Adds `orchestration.forceStopThread` (`rpc.ts:2061`) with result `outcome: killed | released | releasing | shared` (`orchestrationV2.ts:4295-4320`), capability `threadForceStop` (`environment.ts:127`), and `runtime_error.unresponsiveAt` on turn items (`:1842`). Commit 6b1245cced, PR #27252.
- A5. Thread titles and link metadata. Adds `orchestration.getThreadTitles` and `orchestration.getThreadLinkMetadata` (`rpc.ts:2013`, `:2019`) and config flag `threadLinkMetadata` (`server.ts:725`). Commits 9bfecb8f1e (PR #29000) and 23e3465ec6 (PR #32830). CandyWrapper can label unloaded thread chips with these.
- A6. Prompt suggestions. Adds the `orchestration.subscribePromptSuggestion` stream of `{runId, text} | null` (`rpc.ts:2121`, `orchestrationV2.ts:3907-3915`). Commit b24959d579, PR #28047.
- A7. Native child work. Adds `orchestration.getNativeChildWork` (`rpc.ts:2076`, `orchestrationV2.ts:4346-4388`) for the steps of a provider-native subagent. Commit ab8e488e10, PR #28629.
- A8. Shell resume. Adds `subscribeShell` inputs `httpSnapshotFallback` and `knownProjectIdentities` (`orchestrationV2.ts:3974-3979`), the HTTP shell snapshot's `resumeFrom` query and `projectIdentities` (`environmentHttp.ts:737`, `orchestrationV2.ts:2371`), and the `snapshot-required` item.
- A9. Launch with a first message. `launchThread` and `thread.create` take `initialMessage` (`orchestrationV2.ts:3133`, `:3937`), and `ThreadLaunchResult.sequence` is new (`:3953`).
- A10. Turn item fields. Adds `assistant_message.phase` with values commentary, partial_answer and final_answer (`:1744`, commit 836b86a5d6, PR #34501), `user_message.modelSwitch` (`:1739`, commit c65f8d552b, PR #28995), `linkedSender` and `freshContext` on user messages, `system_notice.level` (`:1853`), `secret_request.url`, and `completionWake` on background task items.
- A11. Run and session fields. Adds `Run.steerWhenReadyRunId`, `manualContinuationOfRunId`, `usageLimitContinuationOfRunId` and `freshContext` (`:745-767`). Workflow agents gain `effort` and `speed`, and subagents gain `executedModel` and `cancelledRunId`. Also new are `ProviderSession.extensionStatuses` (`:1002`), `ProviderTurn.nativeThreadRef` and `model`, more pending background task fields, `ThreadHistoryPage.subagents` (`:4151`), and `PendingRuntimeRequestSummary.userOnly` (`:2193`).
- A12. Capability and command flags. Thread capabilities gain `canForkWhileSourceRunning` (`:291`). Turn capabilities gain `supportsNativeGoals`, `activeSteeringAcceptsAttachments` and `activeSteeringDuringCompaction` (`:298-308`). Commands gain `onlyIfUnused`, `expectedLatestRunId`, `restoreUnsettledAt`, `continuation`, `steerFollowUpOfRunId`, `freshContext`, PR watch `until` and title regeneration `outcome` (`:3172-3410`). `AppThread` gains `lastTitleRegeneration` and `titleRenamed` (`:535`), and the shell gains `latestRunBackgroundWake` (`:2235`).
- A13. Monitor notifications from pull request watches carry `pullRequest` and `otherPullRequests` stamps (`orchestrationV2.ts:1333-1376`).

### Server config, providers and settings

- A14. Provider catalog bandwidth. Adds `subscribeServerConfig` flags `providerCatalogsOnDemand`, `providerCatalogDigests` and `providerStatusDeltas` (`rpc.ts:2145-2154`), the `providerStatusDeltas` event (`server.ts:860`, with `applyServerProviderDeltas` at `:341`), and `ServerProvider` fields `catalogDigest`, `subProviders` and `workspaceRescannedAt` (`server.ts:281-303`). `server.refreshProviders` gains `modelCatalogOnly`, `reloadSecrets`, `omitProviders` and `machineCatalog`, with capability `modelCatalogRefresh`. Workspace snapshots can carry `models` and `modelsPending`.
- A15. `ServerConfig` gains `hostname` (`server.ts:706`), `managedPolicy` (`:718`, schema in new `managedPolicy.ts`, commit d897d3f3f0, PR #27197), `serverTime` (`:757`), and the `secretProviderSettings`, `secretReferences` and `secretRequestReferences` flags. Scheduled tasks gain `blockedByPolicy` (`scheduledTask.ts:265`), and the relay install failure reason gains `managed_by_policy`.
- A16. Secret references. Adds `clientCapabilities=settingsSecretReferences` (`environment.ts:19-21`), `server.checkSecretSource` (`rpc.ts:932`, capability `secretSourceCheck`), `SettingsSecretValue` (`settingsSecretValue.ts`), and `SecretReference` answers to `secrets.answerRequest`. Commits a10490937d (PR #27760) and ee9e36c8b2 (PR #31723).
- A17. Socket frame parts. Opt in with `frameParts=1` on the socket URL and join frames that start with U+001E (`packages/shared/src/socketFrameParts.ts`). This keeps a large config from tripping the liveness timeout on slow links.
- A18. Auth. Adds access token renewal: `subject_token_type` may be the access token type (`auth.ts:235`), with capability `accessTokenRenewal` (`environment.ts:90`). Pairing-link DPoP sessions renew for up to 30 days (`EnvironmentAuth.ts:91-92`, commits dd512d86c5 PR #37980 and e396bb2e26 PR #37990). Connect device approval adds `POST /api/auth/connect-devices/approve` and `/revoke` (`environmentHttp.ts:653`, `:661`), `AuthAccessSnapshot.connectDevices`, and `AuthPairingLink.connectDeviceRequest`. Pairing credentials take `access` and `purpose: "peer-link"` (`auth.ts:519`), with capabilities `mcpApprovalCodes`, `peerLinkPairingCodes` and `mcpHostedApproval`. The new scope is `relay:configure` (`auth.ts:50`).
- A19. More settings RPCs. `server.getSettings` returns (`rpc.ts:911`, commit 3a5d7f39a8, PR #26455). New are `server.reclaimDatabaseSpace` (`:882`, PR #32941), `server.listTextGeneratorModels` (`:1055`, PR #33147), `provider.auth.removeMethod` (`:794`, PR #29280) with `ProviderAuthMethod.canRemove`, and setting `requireConnectDeviceApproval`.
- A20. Server updates. Adds `server.getNpmRelease` (`rpc.ts:838`, capability `npmReleaseLookup`), `ServerSelfUpdateInput.channel`, `targetDatabaseMigration` and `stageOnly` (`server.ts:1030-1035`), capability `serverUpdateStaging`, and installation kind `t3-launcher` (`environment.ts:70-74`). `Features/Settings/ServerUpdateViews.swift:49` only builds a manual command for `npm-global`; T3 treats `t3-launcher` the same way (`apps/web/src/components/ServerUpdateAction.tsx:310`).
- A21. Usage. Adds `UsageSummaryInput.modelFilter` and `provisional`, `UsageBucket.unpricedTokens`, `ServerProviderResetCredits.options` with `creditId` on consume, `zeroSpendCap`, and usage window `modelIds` and `providerIds` (`providerUsageLimits.ts`, `usage.ts`).

### Pull requests, review, git and projects

- A22. Pull requests. Adds the `fast-forward` merge method, `reviewerCandidates` `query` (`pullRequest.ts:455`), `runAction` `replyWithSummary` and `expectedHeadSha`, and `activity.overviewThreads` (`:706`). Also new are `references` filter options with `sigil`, `rebaseRequired`, `headSha`, `autoMergeEnabled` and `autoMergeMethod` on summaries, and `mergeQueueRemoval`, `mergedBy` and `maintainerCanModify` on details. `setFilesViewed` takes `revision`, diffs take `path` and `withheldFilesReadable`, and there is a new unavailable reason, `repository-without-project`. `pullRequests.subscribeLinkedThreadRefreshes` (`rpc.ts:1293`, PR #35865) replaces polling for linked-thread counts.
- A23. Review, git and scheduled tasks. Adds `review.getBranchCommits` (`rpc.ts:1767`, PR #19941) and review source kind `commit` with `commitSha`, `metadataOnly`, `patchesDeferred`, `incomplete` and per-file `changeType` (`review.ts`). `subscribeVcsBranch` and `vcs.refreshBranch` (`rpc.ts:1665-1672`, PR #32947) come with capability `vcsBranchStatus`. Git failures gain the `ref_name_conflict` reason. Scheduled tasks gain `threadMode` (`new_thread | continue | fresh_session`, `scheduledTask.ts:231`, PR #30326) and `ScheduledTaskListResult.timeZone`.
- A24. Projects. Adds `projects.createFromThread` (`rpc.ts:1573`, capability `threadProjectFromScratch`, PR #26767) and project `pinnedAt` and `archivedAt` with update fields `pinned` and `archived` (`project.ts:166-204`, capability `projectOrganization`). Also new are the `listIgnoredFiles` `query` (capability `ignoredFileSearch`) and script `stopOnSettle`. `readFile` and `writeFile` paths are no longer trimmed.

### Devices, terminal, voice and the rest

- A25. Terminal. Adds `stopOnSettle` on open and attach, `maxHistoryBytes` on attach, `binary` and `reply` on write, `TerminalSessionSnapshot.error`, and metadata `managerId` (`terminal.ts:169-284`).
- A26. Devices. Adds Simlock hosts (`device.ts:73-90`, `DeviceServiceState.simlockHosts`), `device.simlockIdentity` (`rpc.ts:1902`, PR #26706), `incompletePlatforms`, and the `package_manager_missing` reason.
- A27. Voice. Adds the `/api/voice/*` HTTP group (`environmentHttp.ts:843-983`) with schemas in the new `speech.ts`, and the `composer.dictation` keybinding command.
- A28. Source control. Adds `sourceControl.starred` and `sourceControl.star` (`rpc.ts:1470-1477`).
- A29. Composer context. Adds kind `response` (`composerContext.ts:237`) and image `source`.
- A30. Thread links. Hosted links `https://app.t3.codes/threads/<env>/<thread>` now parse as thread links (`packages/shared/src/threadLinks.ts:50`). External MCP clients get them from `threadLinkFor` (`apps/server/src/mcp/McpInvocationContext.ts:159-168`). `T3Protocol/Domain/ThreadLinks.swift:9-24` only knows `t3-thread://v1` and `v2`.
- A31. Themes and assets. Environment themes gain `css` and `background` (`server.ts:657-667`). Assets gain resource `environment-theme-background`, an `app-path` native app icon, and `hostOnly` and `repository` fields (`assets.ts:22-75`).
- A32. Connect. `CloudLinkState` gains `tunnelHostname` and `linkableHere` (`environmentHttp.ts:557-559`), and there is a new `POST /api/connect/live-activity-preference` (`:1032`).
- A33. Smaller additions. Keybinding commands gain `thread.regenerateTitle` and `preview.find`. `AgentSessionSource` gains `pi`, and Kiro joins the model defaults. Preview automation is desktop IPC that CandyWrapper does not use.

## 3. RPC methods in `WsRpcGroup` at 4928

I generated this list from `WsRpcGroup` in `packages/contracts/src/rpc.ts` at both tags. A method is "changed" when its `Rpc.make` payload, success or stream definition changed, or when a schema it reaches through payload or success changed at any depth. Error channels are left out. "CandyWrapper calls it" means the method name appears as a string literal in `Packages/CandyKit/Sources` or `App/Sources`. "New" rows cite the commit that first added the method name.

| Method | Status | rpc.ts line | CandyWrapper calls it | What changed |
|---|---|---|---|---|
| `agentSessions.import` | unchanged | 1602 | yes |  |
| `agentSessions.scan` | changed | 1596 | yes | types changed: AgentSessionSource |
| `assets.createUrl` | changed | 1613 | yes | types changed: AssetCreateUrlResult, AssetResource, NativeAppIconReference (new) |
| `assets.persistChatAttachments` | unchanged | 1619 | no |  |
| `attachments.createUploadUrl` | changed | 1625 | yes | types changed: AttachmentCreateUploadUrlResult |
| `attachments.delete` | unchanged | 1631 | yes |  |
| `cloud.getRelayClientStatus` | unchanged | 1085 | yes |  |
| `cloud.installRelayClient` | unchanged | 1091 | yes |  |
| `device.action` | unchanged | 1942 | yes |  |
| `device.close` | unchanged | 1926 | no |  |
| `device.configure` | changed | 1914 | yes | types changed: DeviceServiceState, DeviceHostSummary, SimlockDeviceHostSummary (new), DeviceServiceStateWire |
| `device.detail` | unchanged | 1936 | yes |  |
| `device.easAccount` | changed | 1896 | no | types changed: DeviceEasAccountInput, SettingsSecretValue (new) |
| `device.list` | changed | 1908 | yes | types changed: DeviceServiceState, DeviceHostSummary, SimlockDeviceHostSummary (new), DeviceServiceStateWire |
| `device.open` | unchanged | 1920 | yes |  |
| `device.shutdown` | unchanged | 1931 | no |  |
| `device.simlockIdentity` | new | 1902 | no | added in be7d86fa66 #26706 |
| `device.testHost` | changed | 1890 | yes | types changed: DeviceHostSummary, SimlockDeviceHostSummary (new) |
| `filesystem.browse` | unchanged | 1590 | yes |  |
| `filesystem.getMetadata` | unchanged | 1584 | no |  |
| `git.preparePullRequestThread` | unchanged | 1726 | yes |  |
| `git.resolvePullRequest` | unchanged | 1720 | yes |  |
| `git.runStackedAction` | unchanged | 1713 | yes |  |
| `guestShare.create` | unchanged | 2209 | yes |  |
| `issueTrackers.bindProject` | new | 1424 | no | added in 86863beede #19274 |
| `issueTrackers.connect` | new | 1418 | no | added in 86863beede #19274 |
| `issueTrackers.list` | new | 1408 | no | added in 86863beede #19274 |
| `issues.candidates` | new | 1366 | no | added in 20501a0221 #19259 |
| `issues.comment` | new | 1378 | no | added in 20501a0221 #19259 |
| `issues.comments` | new | 1353 | no | added in 20501a0221 #19259 |
| `issues.create` | new | 1372 | no | added in 20501a0221 #19259 |
| `issues.detail` | new | 1340 | no | added in 20501a0221 #19259 |
| `issues.linkedThreads` | new | 1347 | no | added in b6a0fd6d62 #38771 |
| `issues.list` | new | 1334 | no | added in 20501a0221 #19259 |
| `issues.react` | new | 1396 | no | added in 20501a0221 #19259 |
| `issues.setState` | new | 1390 | no | added in 20501a0221 #19259 |
| `issues.templates` | new | 1359 | no | added in 20501a0221 #19259 |
| `issues.update` | new | 1384 | no | added in 20501a0221 #19259 |
| `mcpApps.callTool` | unchanged | 1636 | yes |  |
| `mcpApps.readResource` | unchanged | 1653 | yes |  |
| `mcpApps.toolInfo` | unchanged | 1642 | yes |  |
| `mcpApps.updateModelContext` | unchanged | 1648 | yes |  |
| `orchestration.dispatchCommand` | changed | 1955 | yes | types changed: OrchestrationV2Command, PullRequestWatchUntil (new), OrchestrationV2LinkedSender (new), KnownComposerContextRecord, ImageContextRecord |
| `orchestration.forceStopThread` | new | 2061 | no | added in 6b1245cced #27252 |
| `orchestration.getArchivedShellSnapshot` | unchanged | 1998 | yes |  |
| `orchestration.getFullThreadDiff` | unchanged | 1967 | yes |  |
| `orchestration.getNativeChildWork` | new | 2076 | no | added in ab8e488e10 #28629 |
| `orchestration.getOlderSettledThreads` | changed | 2037 | yes | types changed: OrchestrationV2ThreadShell, ThreadIssueLink (new), OrchestrationV2AppThread, OrchestrationV2AppThreadLineage, StoredThreadTags (new) |
| `orchestration.getThreadFamily` | changed | 2007 | yes | types changed: OrchestrationV2ThreadShell, ThreadIssueLink (new), OrchestrationV2AppThread, OrchestrationV2AppThreadLineage, StoredThreadTags (new) |
| `orchestration.getThreadLinkMetadata` | new | 2019 | no | added in 23e3465ec6 #32830 |
| `orchestration.getThreadProjection` | changed | 2046 | yes | types changed: OrchestrationV2AppThread, ThreadIssueLink (new), OrchestrationV2AppThreadLineage, StoredThreadTags (new), OrchestrationV2LastTitleRegeneration (new) |
| `orchestration.getThreadTitles` | new | 2013 | no | added in 9bfecb8f1e #29000 |
| `orchestration.getTurnDiff` | unchanged | 1961 | yes |  |
| `orchestration.getTurnItem` | changed | 2085 | yes | types changed: OrchestrationV2TurnItem, OrchestrationV2CheckpointFileTotals (new), OrchestrationV2ModelSwitch (new), OrchestrationV2SecretRequestFields, OrchestrationV2LinkedSender (new) |
| `orchestration.getWorkflowScript` | unchanged | 2067 | no |  |
| `orchestration.getWorktreeThreadIds` | unchanged | 2028 | yes |  |
| `orchestration.launchThread` | changed | 2091 | yes | types changed: KnownComposerContextRecord, ImageContextRecord, ResponseContextRecord (new), OrchestrationV2ThreadLaunchResult, OrchestrationV2AppThread |
| `orchestration.searchThread` | unchanged | 1976 | yes |  |
| `orchestration.searchThreadStream` | unchanged | 1982 | yes |  |
| `orchestration.searchThreads` | changed | 1992 | yes | types changed: OrchestrationV2ThreadShell, ThreadIssueLink (new), OrchestrationV2AppThread, OrchestrationV2AppThreadLineage, StoredThreadTags (new) |
| `orchestration.stopWorkflow` | unchanged | 2055 | yes |  |
| `orchestration.subscribeCommandOutput` | unchanged | 2111 | yes |  |
| `orchestration.subscribePromptSuggestion` | new | 2121 | no | added in b24959d579 #28047 |
| `orchestration.subscribeShell` | changed | 2097 | yes | types changed: OrchestrationV2ShellStreamItem, OrchestrationV2ThreadShell, ThreadIssueLink (new), OrchestrationV2AppThread, OrchestrationV2AppThreadLineage |
| `orchestration.subscribeThread` | changed | 2104 | yes | types changed: OrchestrationV2AppThread, ThreadIssueLink (new), OrchestrationV2AppThreadLineage, StoredThreadTags (new), OrchestrationV2LastTitleRegeneration (new) |
| `peerLinks.answerRequest` | unchanged | 905 | yes |  |
| `peerLinks.link` | unchanged | 893 | yes |  |
| `peerLinks.list` | unchanged | 887 | yes |  |
| `peerLinks.unlink` | unchanged | 899 | yes |  |
| `preview.adjust` | unchanged | 1837 | yes |  |
| `preview.clearProfile` | unchanged | 1854 | yes |  |
| `preview.close` | unchanged | 1843 | yes |  |
| `preview.list` | unchanged | 1848 | yes |  |
| `preview.open` | changed | 1825 | yes | types changed: PreviewOpenInput |
| `preview.reportProfiles` | unchanged | 1859 | yes |  |
| `preview.reportStatus` | unchanged | 1864 | no |  |
| `preview.resize` | unchanged | 1831 | yes |  |
| `preview.stopLocalServer` | unchanged | 1876 | yes |  |
| `projectClone.cancel` | unchanged | 1494 | yes |  |
| `projectClone.retry` | unchanged | 1500 | yes |  |
| `projectClone.start` | unchanged | 1484 | yes |  |
| `projects.createFromThread` | new | 1573 | yes (sidebar-2) | added in 58e60bf5e8 #26767; thread menu Turn into project behind `threadProjectFromScratch` |
| `projects.createNew` | unchanged | 1567 | yes |  |
| `projects.ensureScratch` | unchanged | 1561 | yes |  |
| `projects.listEntries` | unchanged | 1531 | yes |  |
| `projects.listIgnoredFiles` | changed | 1537 | yes | types changed: ProjectListIgnoredFilesInput |
| `projects.mutate` | changed | 1555 | yes | types changed: Project, ProjectScript, ProjectUpdatePayload |
| `projects.readFile` | changed | 1543 | yes | types changed: ProjectReadFileInput, ProjectReadFileResult |
| `projects.searchContents` | changed | 1525 | yes | types changed: ProjectSearchContentsInput |
| `projects.searchEntries` | unchanged | 1519 | yes |  |
| `projects.writeFile` | changed | 1549 | yes | types changed: ProjectWriteFileResult, ProjectWriteFileInput |
| `provider.auth.cancel` | changed | 788 | yes | types changed: ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.auth.complete` | changed | 765 | yes | types changed: ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.auth.logout` | changed | 800 | yes | types changed: ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.auth.removeMethod` | new | 794 | no | added in 1b952135a1 #29280 |
| `provider.auth.respond` | changed | 759 | yes | types changed: ProviderAuthResponse, ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.auth.start` | changed | 753 | yes | types changed: ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.auth.subscribe` | changed | 806 | yes | types changed: ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.chatgpt.handoff.subscribe` | changed | 781 | yes | types changed: ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.chatgpt.import-profile` | changed | 776 | no | types changed: ProviderAuthState, SignInUrl (new), ProviderAuthInteraction, ProviderAuthMethod |
| `provider.chatgpt.reconnect-profile` | unchanged | 771 | no |  |
| `provider.consumeResetCredit` | changed | 747 | yes | types changed: ProviderConsumeResetCreditInput |
| `provider.install.cancel` | unchanged | 819 | yes |  |
| `provider.install.remove` | unchanged | 832 | no |  |
| `provider.install.start` | unchanged | 813 | yes |  |
| `provider.install.subscribe` | unchanged | 825 | yes |  |
| `provider.uploadFeedback` | unchanged | 1659 | no |  |
| `pullRequests.activity` | changed | 1176 | yes | types changed: PullRequestActivity, PullRequestThreadComment, PullRequestOverviewThread (new) |
| `pullRequests.changeBreakdown` | unchanged | 1212 | yes |  |
| `pullRequests.checks` | changed | 1170 | yes | types changed: PullRequestCheck |
| `pullRequests.comment` | unchanged | 1237 | yes |  |
| `pullRequests.detail` | changed | 1158 | yes | types changed: PullRequestDetail, PullRequestCapabilities, PullRequestMergeMethod, PullRequestReviewerCapabilities, PullRequestEditCapabilities |
| `pullRequests.diffFileContents` | changed | 1200 | no | types changed: PullRequestDiffFileContentsInput |
| `pullRequests.filesViewed` | unchanged | 1206 | yes |  |
| `pullRequests.filterOptions` | changed | 1122 | no | types changed: PullRequestFilterOptionsInput, PullRequestFilterOptionKind, PullRequestReferenceSigil (new), PullRequestFilterOptions, PullRequestReferenceCandidate (new) |
| `pullRequests.generateReviewGuide` | unchanged | 1188 | no |  |
| `pullRequests.invalidate` | unchanged | 1273 | yes |  |
| `pullRequests.labelCandidates` | changed | 1316 | yes | types changed: PullRequestLabel |
| `pullRequests.linkedThreads` | changed | 1152 | no | types changed: PullRequestLinkedThreadsResult |
| `pullRequests.list` | changed | 1109 | yes | types changed: PullRequestProviderSummary, PullRequestListEntry, PullRequestLabel, PullRequestListInput |
| `pullRequests.listStats` | unchanged | 1116 | yes |  |
| `pullRequests.preview` | changed | 1164 | no | types changed: PullRequestPreview |
| `pullRequests.replyToThread` | unchanged | 1255 | yes |  |
| `pullRequests.reportState` | unchanged | 1279 | no |  |
| `pullRequests.requestReviewers` | changed | 1310 | yes | types changed: PullRequestReviewerRequestInput |
| `pullRequests.reviewGuide` | unchanged | 1182 | no |  |
| `pullRequests.reviewerCandidates` | changed | 1304 | yes | payload is now PullRequestReviewerCandidatesInput, PullRequestRef plus optional `query` |
| `pullRequests.routing` | unchanged | 1128 | no |  |
| `pullRequests.routingIdentity` | unchanged | 1134 | no |  |
| `pullRequests.runAction` | changed | 1224 | yes | success is `UndefinedOr(PullRequestSummary)`; a summary comes back only with `replyWithSummary: true` |
| `pullRequests.setFilesViewed` | changed | 1218 | yes | types changed: PullRequestSetFilesViewedInput |
| `pullRequests.setLabels` | changed | 1322 | yes | types changed: PullRequestLabelChangeInput |
| `pullRequests.setReaction` | unchanged | 1267 | yes |  |
| `pullRequests.setThreadResolution` | unchanged | 1261 | yes |  |
| `pullRequests.stack` | unchanged | 1146 | yes |  |
| `pullRequests.submitReview` | unchanged | 1249 | yes |  |
| `pullRequests.subscribeLinkedThreadRefreshes` | new | 1293 | no | added in 4596872940 #35865 |
| `pullRequests.subscribeRefreshes` | unchanged | 1285 | no |  |
| `pullRequests.summary` | changed | 1140 | no | types changed: PullRequestSummary, PullRequestMergeMethod |
| `pullRequests.threadComments` | changed | 1194 | yes | types changed: PullRequestThreadCommentsResult, PullRequestThreadComment |
| `pullRequests.update` | changed | 1231 | yes | types changed: PullRequestUpdateInput |
| `pullRequests.updateComment` | unchanged | 1243 | yes |  |
| `review.getBranchCommits` | new | 1767 | no | added in 5ef56853ef #19941 |
| `review.getDiffFileContents` | changed | 1779 | yes | types changed: ReviewDiffFileContentsInput, ReviewDiffPreviewSourceKind, ReviewDiffChangeType (new) |
| `review.getDiffPreview` | changed | 1773 | yes | types changed: ReviewDiffPreviewInput, ReviewDiffPreviewResult, ReviewDiffPreviewSource, ReviewDiffFileStat, ReviewDiffChangeType (new) |
| `scheduledTasks.delete` | unchanged | 2188 | yes |  |
| `scheduledTasks.getWebhookDelivery` | unchanged | 2229 | yes |  |
| `scheduledTasks.listWebhookDeliveries` | unchanged | 2220 | yes |  |
| `scheduledTasks.rotateWebhookToken` | changed | 2200 | yes | types changed: ScheduledTask, ScheduledTaskThreadMode (new), ScheduledTaskSchedule, ScheduledTaskOnceSchedule (new) |
| `scheduledTasks.runNow` | changed | 2194 | yes | types changed: ScheduledTask, ScheduledTaskThreadMode (new), ScheduledTaskSchedule, ScheduledTaskOnceSchedule (new) |
| `scheduledTasks.setEnabled` | changed | 2182 | yes | types changed: ScheduledTask, ScheduledTaskThreadMode (new), ScheduledTaskSchedule, ScheduledTaskOnceSchedule (new) |
| `scheduledTasks.subscribe` | changed | 2169 | yes | types changed: ScheduledTaskListResult, ScheduledTask, ScheduledTaskThreadMode (new), ScheduledTaskSchedule, ScheduledTaskOnceSchedule (new) |
| `scheduledTasks.upsert` | changed | 2176 | yes | types changed: ScheduledTaskUpsertInput, ScheduledTaskThreadMode (new), ScheduledTaskUpsertSchedule, ScheduledTaskOnceSchedule (new), ScheduledTask |
| `secrets.answerRequest` | changed | 2215 | yes | types changed: SecretRequestAnswerInput, SecretReference (new) |
| `server.acceptAcpRegistryUrlAuth` | unchanged | 959 | no |  |
| `server.checkOtlpEndpoint` | unchanged | 1049 | yes |  |
| `server.checkSecretSource` | new | 932 | no | added in ee9e36c8b2 #31723 |
| `server.commitDesktopUpdate` | unchanged | 857 | yes |  |
| `server.deleteAcpRegistrySession` | unchanged | 977 | yes |  |
| `server.disableAcpRegistryProvider` | unchanged | 995 | no |  |
| `server.discoverSourceControl` | unchanged | 926 | yes |  |
| `server.getConfig` | changed | 694 | yes | types changed: ServerConfig, EnvironmentTheme, ExecutionEnvironmentDescriptor, ExecutionEnvironmentCapabilities, ServerInstallation |
| `server.getDatabaseStorage` | changed | 875 | yes | types changed: DatabaseStorageStatus |
| `server.getHostResources` | unchanged | 1022 | yes |  |
| `server.getNpmRelease` | new | 838 | no | added in d2d1e4f50e #27847 |
| `server.getProcessDiagnostics` | unchanged | 1016 | yes |  |
| `server.getProcessResourceHistory` | unchanged | 1028 | yes |  |
| `server.getResourceTelemetryHistory` | unchanged | 1034 | yes |  |
| `server.getSettings` | new | 911 | no | added in 3a5d7f39a8 #26455 |
| `server.getStorageCleanupReport` | unchanged | 868 | yes |  |
| `server.getTraceDiagnostics` | unchanged | 1010 | yes |  |
| `server.getUsageSummary` | changed | 1067 | yes | types changed: UsageSummary, UsageModelFilter (new), UsageSource, UsageSourceFingerprint, UsageBucket |
| `server.importAcpRegistrySession` | unchanged | 971 | yes |  |
| `server.listAcpRegistryProviders` | unchanged | 983 | no |  |
| `server.listAcpRegistrySessions` | changed | 965 | yes | types changed: AcpRegistrySession |
| `server.listTextGeneratorModels` | new | 1055 | no | added in eb97d82156 #33147 |
| `server.logoutAcpRegistry` | unchanged | 1004 | no |  |
| `server.prepareAcpRegistryAgent` | unchanged | 944 | yes |  |
| `server.prepareTriage` | unchanged | 1061 | yes |  |
| `server.probe` | unchanged | 688 | yes |  |
| `server.reclaimDatabaseSpace` | new | 882 | no | added in 8969e1d8d0 #32941 |
| `server.refreshProviders` | changed | 700 | yes | new optional inputs `modelCatalogOnly`, `reloadSecrets`, `providerCatalogsOnDemand`, `omitProviders`, `machineCatalog` |
| `server.refreshUsageRates` | unchanged | 1073 | yes |  |
| `server.removeKeybinding` | changed | 682 | yes | types changed: KeybindingShortcut, KeybindingShortcutKey (new) |
| `server.reportClientActivity` | unchanged | 1098 | yes |  |
| `server.retryResourceTelemetry` | unchanged | 1043 | yes |  |
| `server.runStorageCleanup` | unchanged | 863 | yes |  |
| `server.searchAcpRegistry` | changed | 938 | yes | types changed: AcpRegistrySearchInput |
| `server.setAcpRegistryProvider` | unchanged | 989 | no |  |
| `server.signalProcess` | unchanged | 1079 | yes |  |
| `server.uninstallAcpRegistryManagedBinary` | unchanged | 950 | no |  |
| `server.updateProvider` | changed | 739 | yes | types changed: ServerProvider, ServerProviderUsageLimits, ServerProviderResetCredits, ServerProviderResetCreditOption (new), ServerProviderUsageWindow |
| `server.updateServer` | changed | 844 | yes | types changed: ServerSelfUpdateInput |
| `server.updateServerWithProgress` | changed | 850 | yes | types changed: ServerSelfUpdateInput |
| `server.updateSettings` | changed | 917 | yes | patch type is ClientServerSettingsPatch, which drops the four default theme and appearance keys; removed keys are ignored |
| `server.upsertKeybinding` | changed | 676 | yes | types changed: KeybindingShortcut, KeybindingShortcutKey (new) |
| `shell.openInEditor` | changed | 1579 | yes | types changed: LaunchEditorInput |
| `sourceControl.appAccess` | unchanged | 1463 | no |  |
| `sourceControl.cloneRepository` | unchanged | 1436 | yes |  |
| `sourceControl.lookupRepository` | unchanged | 1430 | yes |  |
| `sourceControl.publishRepository` | unchanged | 1513 | yes |  |
| `sourceControl.signInCancel` | unchanged | 1457 | no |  |
| `sourceControl.signInStart` | unchanged | 1443 | no |  |
| `sourceControl.signInWait` | unchanged | 1450 | no |  |
| `sourceControl.star` | new | 1477 | no | added in 5d3d78ab93 #29922 |
| `sourceControl.starred` | new | 1470 | no | added in d92c437baa #27832 |
| `subscribeAuthAccess` | changed | 2238 | yes | types changed: AuthAccessSnapshot, AuthConnectDevice (new), AuthPairingLink, AuthConnectDeviceRequest (new) |
| `subscribeDeviceState` | changed | 1948 | yes | types changed: DeviceServiceState, DeviceHostSummary, SimlockDeviceHostSummary (new), DeviceServiceStateWire |
| `subscribeDiscoveredLocalServers` | unchanged | 1881 | yes |  |
| `subscribePreviewEvents` | unchanged | 1869 | yes |  |
| `subscribeProjectClones` | unchanged | 1506 | yes |  |
| `subscribeResourceTelemetry` | unchanged | 2245 | yes |  |
| `subscribeServerConfig` | changed | 2138 | yes | new optional inputs `providerCatalogsOnDemand`, `providerCatalogDigests`, `providerStatusDeltas`; new event `providerStatusDeltas` |
| `subscribeServerLifecycle` | changed | 2162 | yes | types changed: ExecutionEnvironmentDescriptor, ExecutionEnvironmentCapabilities, ServerInstallation, InstalledPath (new) |
| `subscribeTerminalMetadata` | changed | 2131 | yes | types changed: TerminalMetadataSnapshotEvent |
| `subscribeVcsBranch` | new | 1665 | no | added in 0d809db501 #32947 |
| `subscribeVcsStatus` | unchanged | 1678 | yes |  |
| `subscribeWorktreeSetup` | unchanged | 1700 | yes |  |
| `terminal.attach` | changed | 1791 | yes | types changed: TerminalAttachInput, TerminalSessionSnapshot |
| `terminal.clear` | unchanged | 1815 | no |  |
| `terminal.close` | unchanged | 1820 | yes |  |
| `terminal.observe` | changed | 1798 | no | types changed: TerminalSessionSnapshot |
| `terminal.open` | changed | 1785 | yes | types changed: TerminalOpenInput, TerminalSessionSnapshot |
| `terminal.resize` | unchanged | 1810 | yes |  |
| `terminal.write` | changed | 1805 | yes | types changed: TerminalWriteInput |
| `vcs.createRef` | unchanged | 1750 | yes |  |
| `vcs.createWorktree` | unchanged | 1738 | no |  |
| `vcs.init` | unchanged | 1762 | yes |  |
| `vcs.listRefs` | unchanged | 1732 | yes |  |
| `vcs.pull` | unchanged | 1685 | yes |  |
| `vcs.refreshBranch` | new | 1672 | no | added in 0d809db501 #32947 |
| `vcs.refreshStatus` | unchanged | 1691 | yes |  |
| `vcs.removeWorktree` | unchanged | 1745 | yes |  |
| `vcs.switchRef` | unchanged | 1756 | yes |  |
| `worktreeSetup.cancel` | unchanged | 1707 | yes |  |

## 4. Port list for the wire layer

Breaks come first, then additions ranked by how much the user would notice. Each item is sized for one agent, and estimates are agent time including tests.

1. B1, checkpoint `filesTotal`. Decode it on `Checkpoint` and the checkpoint turn item, use it for counts and totals in the changed-files card and right panel, and add a fixture with 201 files. About 30 minutes.
2. B2 and A3, side chats. Add `ThreadLineage.sideChat` and an `isListed` helper, and swap it in for the subagent checks in the sidebar, search and settled counts. Fork with `sideChat: true` only when the T3 UI for side chats is ported. About 45 minutes for the filter.
3. B3 and A23, scheduled tasks. Add the `once` schedule and `threadMode` to `ScheduledTasks.swift` and its editor, read `timeZone`, and keep unknown schedules instead of dropping them. About 1 hour.
4. B4 and part of A18, Connect device approval. On the client side, handle `connect_approval_pending` with a waiting state, the verification code and a retry. On the host side, list `connectDevices` and pending requests in Connections, approve and revoke through the new endpoints, and add the `requireConnectDeviceApproval` toggle. About 2 hours, plus a manual check against a sandbox with the setting on.
5. B5 and B6, dead settings. Remove the Cursor keychain toggle, the `enableCursorKeychain` action, and the `planModeEnabled`, `contextWindowMeterEnabled` and `legacySidebarEnabled` specs and fallbacks. About 20 minutes.
6. B7 and A2, thread events. Add `thread.visit-recorded` with a merge into `AppThread`, add `thread.tags-updated` and `thread.issue-synced` to `threadPayloadTypes`, and decode `tags`, `issues` and `lastTitleRegeneration` on thread and shell. About 30 minutes.
7. A4, force stop. Call `orchestration.forceStopThread` behind `threadForceStop`, and show `runtime_error.unresponsiveAt`. About 45 minutes.
8. A10, turn item fields. Decode `assistant_message.phase`, `user_message.modelSwitch`, `system_notice.level` and `linkedSender`, and match T3's rendering of each. About 1 hour of wire work. The timeline UI is a separate visual task.
9. A14 and A17, config bandwidth. Opt in to `providerCatalogsOnDemand`, `providerCatalogDigests`, `providerStatusDeltas` and `frameParts=1`. Apply deltas the way `applyServerProviderDeltas` does, and join U+001E-prefixed frames in `RPCSocket`. About 1.5 hours, then a `scripts/perf-review` run since it changes idle and launch traffic.
10. A18, token renewal. Renew pairing-link DPoP sessions at `/oauth/token` with `subject_token_type` set to the access token type when `accessTokenRenewal` is advertised. About 1 hour.
11. A5 and A30, thread links. Use `getThreadLinkMetadata` for unloaded chips when `threadLinkMetadata` is set, and parse hosted `https://app.t3.codes/threads/...` links in `ThreadLinks.swift`. About 45 minutes.
12. A16, secret references. Send `clientCapabilities=settingsSecretReferences`, model `SettingsSecretValue` as string or reference, and add `server.checkSecretSource`. About 1.5 hours. Do this only together with a secret provider settings UI, because a client that declares the capability must handle references everywhere it reads secrets.
13. A22, pull request fields. Add the fast-forward merge label, `overviewThreads`, `rebaseRequired`, auto-merge fields, the reviewer search `query`, `subscribeLinkedThreadRefreshes`, and `replyWithSummary` on `runAction`. About 1.5 hours.
14. A20, server updates. Build the manual command for `t3-launcher` installs, and use `getNpmRelease`, the update channel and staging where advertised. About 45 minutes.
15. A1, issues. This is a new feature area of 14 RPCs, link commands and shell fields. It needs its own plan and should not be a single wire task.

Everything else in section 2 can wait until the matching UI is ported.

## 5. Decoder strictness

CandyWrapper's stream and event decoders are tolerant. No payload change in this range makes them throw.

- `ThreadStreamItem` (`T3Protocol/Domain/ThreadStream.swift:263-339`) maps unknown `kind` to `.unknown` and unknown event types to `.unknownEvent`, and keeps advancing the cursor. That is why B7 loses data instead of failing.
- `ShellStreamItem` (`T3Protocol/Domain/ShellStream.swift:122`) maps unknown kinds through its `default` branch, so `snapshot-required` is safe.
- `ServerConfigEvent` (`T3Protocol/Domain/ServerProviders.swift:481-522`) maps unknown event types to `.other`, so `providerStatusDeltas` would be ignored. The server sends it only on opt-in.
- `ThreadEventType`, `TurnItemType`, `LineageRelationship` and the other `OpenStringEnum` types (`T3Protocol/Domain/DomainBasics.swift:44-58`) accept any string.
- `ScheduledTaskSchedule.init?(json:)` (`T3Protocol/Domain/ScheduledTasks.swift:16-35`) does not throw, but returns nil and drops the whole task. That is B3.

These closed Swift enums throw on an unknown raw value. Their 4928 value sets are unchanged, so none breaks now, but each will throw on the next added value.

- `TerminalSessionStatus` (`T3Protocol/Domain/Terminal.swift:8`) matches `terminal.ts:242`: starting, running, exited, error.
- `GitStackedAction` (`T3Protocol/Domain/Vcs.swift:166`) matches `git.ts:18`.
- `RelayClientInstallStage` (`T3Protocol/Domain/DesktopManaged.swift:20`) matches `relayClient.ts`. Only failure reasons gained a value, `managed_by_policy`, and CandyWrapper reads those as strings.
- `PreviewEvent.Kind` (`T3Protocol/Domain/Preview.swift:123`) matches `preview.ts`: opened, navigated, resized, failed, closed.
- `PeerLink.Status` (`T3Protocol/Domain/PeerLink.swift:7`) matches `PeerLinkStatus`: reachable, unreachable, expired.
- `EnvMode` (`Features/Git/BranchToolbarLogic.swift:5`) matches `ThreadEnvMode`: local, worktree.

The safest follow-up is to make `TerminalSessionStatus` and `PeerLink.Status` `OpenStringEnum`s, because both are server-sent state. The others are either client-sent or desktop-local.

## What I could not determine

- I did not record a 4928 transcript or run any decoder against a 4928 server, because this task was read-only. The decode claims rest on reading the Swift code and the contracts.
- The "CandyWrapper calls it" column comes from matching string literals. A method name built at runtime would be missed. The `orchestration.*` names are all literals in the code I read.
- "Changed" in the table follows schema references by name, so a few rows may be marked changed only because a shared nested type changed somewhere they never use. All 33 new rows and the 5 RPC-level changes were checked by hand.
- The client-runtime and shared diffs are mostly UI state, i18n and local caching. I read only the files that touch the socket, auth, relay, thread links and settings secrets, and did not read the other 1,700 commits.
- B4 only shows up when a host turns on `requireConnectDeviceApproval`. I could not tell whether T3 plans to turn it on by default.
