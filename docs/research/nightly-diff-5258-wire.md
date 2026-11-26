# Nightly 5258 wire audit

Task wire-5258, 2026-11-25. I compared `v0.1.11-nightly.20261119.4928` (e8c4824b70) with `v0.1.13-nightly.20261125.5258` (bf961f8121). The scope is `packages/contracts`, `packages/client-runtime` and `packages/shared`, plus server code where it changes what a client receives or must send. Citations of the form `file:line` point into the 5258 tree unless they say 4928.

The contract diff is 2,359 lines added and 159 removed in 48 non-test files (2,589 and 165 in 54 files with tests). `ORCHESTRATION_PROTOCOL_VERSION` stays at 2 (`packages/contracts/src/environment.ts:13`). No RPC method was removed or renamed, no orchestration command or event type was removed, and no string literal left any contract union. Removed from the contracts: the desktop-only `PreviewAutomationElement` and `interactiveElements` (`previewAutomation.ts`, commit c3fb01dc05, PR #40520) and the `T3CODE_GITHUB_APP_CLIENT_ID` env key in `resourceTelemetry.ts`. RPC payload structs still ignore unknown keys, so nothing here stops CandyWrapper from connecting or from decoding the shell or thread streams.

Counts: 4 breaks, 20 additions, 260 RPC methods in `WsRpcGroup` at 5258 (`rpc.ts:2487`), of which 25 are new, 83 changed, 152 unchanged and none removed.

The base for this audit is CandyWrapper `main` at fe4dbfcb, which already has the 4928 fixes (`ThreadLineage.sideChat` in `T3Protocol/Domain/ThreadShell.swift:259`, the `thread.tags-updated` and `thread.issue-synced` events in `ThreadStream.swift:208-209`). The four breaks below are new in this range.

## 1. Breaks

### B1. Clearing a scheduled task's thread does nothing

Before this range, `threadId: null` in `scheduledTasks.upsert` cleared the bound thread. Now `null` or an absent `threadId` keeps the stored thread, and the client must also send `unbindThread: true` to clear it. The change stops an edit form that was opened before a first run from erasing the thread the run just bound.

- T3: `packages/contracts/src/scheduledTask.ts:291-294`, `apps/server/src/scheduledTasks/ScheduledTaskService.ts:1497` (`input.threadId ?? (input.unbindThread === true ? null : existing)`) and `:1629`.
- Commit 898c22f990, PR #39639. The `requireExisting` wording changed in 44979a5875, PR #41084.
- CandyWrapper: the task editor builds the upsert in `T3Protocol/Domain/ScheduledTasks.swift:663` and sends `"threadId": .null` when the field is empty. The server then keeps the old thread, and the editor shows the old thread again after the save.
- Fix: when `d.threadId.isEmpty` and the task already exists, send `unbindThread: true` as well as `threadId: null`. A 4928 server ignores the extra key and clears on `null`, so one payload works on both.

### B2. Workflow agent steps show up in the sidebar as threads

Durable workflows (beta) run each agent step as a thread with `lineage.workflowStep: true` and a `workflowRun` origin on the thread and its shell. T3 hides these from every thread list, the same way it hides subagents and side chats. The shell stream still sends them to every client. The feature is off by default (`workflowsEnabled` is false), so this only shows once someone turns it on from another client.

- T3: `packages/contracts/src/orchestrationV2.ts:195` (`workflowStep`), `:203-207` (`isListedThreadLineage` now also tests `workflowStep`), `:169` (`OrchestrationV2WorkflowOrigin`), `:521` and `:2436` (`workflowRun` on thread and shell); setting at `settings.ts:1535`.
- Commit e414cfd4be, PR #38882.
- CandyWrapper: `ThreadLineage.isListedLineage` in `T3Protocol/Domain/ThreadShell.swift:275` tests only `relationshipToParent` and `sideChat`. The sidebar reads it at `T3Store/SidebarModel.swift:472`. Search and settled counts use the same helper.
- Fix: add `workflowStep: Bool?` to `ThreadLineage` and to its `CodingKeys` (`:264`), add it to `isListedLineage`, and decode `workflowRun` on `ThreadShell` and `AppThread`. A 4928 server never sets the key, so the helper stays correct.

### B3. Multi-value secret cards cannot be answered

`request_secret` now takes a `fields` list (up to 8 named inputs, such as email and password), and the card stores one value per field. The answer for such a card is `{type: "save", values: {name: value}}`. CandyWrapper's card shows one input and sends `{type: "save", secret}`. The server refuses it with `SecretRequestError` reason `fields_mismatch`, and the card shows "This request asks for different values. Update the app and try again."

- T3: `packages/contracts/src/orchestrationV2.ts:1841` (`OrchestrationV2SecretRequestField`) and `:1856` (`fields` on the item), `secretRequest.ts:22-26` (the `values` answer) and its `fields_mismatch` message, `orchestratorMcp.ts` (`RequestSecretFields`, with result status `saved` and `files`), `apps/server/src/secrets/SecretRequests.ts:186-189`.
- Commit 0bc9b57b93, PR #31257. A reference answer now also needs `providers:manage` beside `orchestration:operate` (`apps/server/src/auth/RpcAuthorization.ts`, commit 8dc01892ad, PR #41886).
- CandyWrapper: `T3Store/SecretRequests.swift:44` builds the single-value reply. `Features/Thread/SecretRequestRowView.swift` draws one field. `TurnItem.swift:179` reads `url` but not `fields`.
- Fix: read `fields` (name, label, placeholder, `secret` flag, where `secret: false` shows the typed text), draw one input per field, and send `values` keyed by name. Keep the single-secret path for items without `fields`. A 4928 server never sends `fields`.

### B4. The server now writes a Pong frame every 20 seconds

Reverse proxies drop a socket after 60 seconds without upstream bytes, so the 5258 server wraps every `/ws` socket and writes `{"_tag":"Pong"}` every 20 seconds for as long as the socket is open. T3's own client counts any frame as liveness and ignores an unsolicited Pong. CandyWrapper does neither.

- T3: `apps/server/src/socketHeartbeat.ts:7` (interval), `:10` (frame), `apps/server/src/ws.ts:3952` (`withSocketHeartbeat(splitFrames ? ... : socket)`, applied to every `/ws` connection, not only ones with `frameParts`).
- Commit ad446450e1, PR #40932.
- CandyWrapper: `T3Transport/RPCConnection.swift:374-381` treats every `.pong` as the answer to its own ping. It marks every stream without `snapshotFirst` as `answered`, and it resumes every `pongWaiters` continuation. A heartbeat that lands between `awaitPong()` (`:267-281`) and the real reply releases the barrier early, so a subscription the server has not served yet is counted as served. Pings carry no id, so the two Pongs cannot be told apart.
- It also breaks the idle-cost claim in `T3Client/ConnectionSupervisor.swift:173-186` ("The T3 server never closes a quiet socket ... never pings ... idle wakeups at zero"). Every connected 5258 socket now wakes the process about 0.05 times a second while idle. The client cannot opt out.
- Fix: update that comment, and run `scripts/perf-review` against a 5258 server to see the real cost. Stop treating an unsolicited `.pong` as an ordering proof: take the barrier only from a Pong that arrives while a ping is outstanding and no earlier than the ping's send, or send the barrier ping twice. Count every inbound frame as liveness (`lastInbound` at `:345` already does), which lets the quiet-socket watchdog drop its own ping against a 5258 server.
- Telling servers apart: no capability. The first heartbeat arrives within 20 seconds of connect with no ping outstanding.

### Checked and not breaks

- `GitRefName` replaces `TrimmedNonEmptyString` on branch and ref fields across `git.ts`, `pullRequest.ts`, `review.ts`, `orchestrationV2.ts` and others (`baseSchemas.ts:54`). It trims only ASCII whitespace now, so a branch with an edge U+00A0 survives. CandyWrapper stores these as plain strings. Commit f00893a512, PR #41274.
- Pull request, issue and issue tracker operation errors now answer HTTP 503, not 502 (`issue.ts:479`, `pullRequest.ts:1036`, commit 667cb3b255, PR #42956). CandyWrapper reaches these over the RPC socket and has no code that tests 502 or 503.
- `HttpQuotaResponse` and usage sources of kind `http` are hidden from a client that does not send `clientCapabilities=httpUsageLimitSources`, so CandyWrapper's `UsageLimitSourceSnapshot.list` (`T3Protocol/Domain/UsageLimits.swift:124`, which keeps only `cliproxy`) never sees one. The server filters at `apps/server/src/serverSettings.ts:168`. Settings patches merge per entry (`settings.ts:2032-2035`), so CandyWrapper cannot delete a hidden source.
- Saving project scripts through `server.updateSettings` now needs `orchestration:operate` (`settings.ts:2061`, commit bba3918e3c, PR #41979), and approving a worktree layout needs `terminal:operate`. A session paired as the owner has both.
- A `feedback_request` turn item appears only when someone sets `agentFeedback.mode` away from `off`. CandyWrapper drops unknown item types (`T3Protocol/Domain/TurnItem.swift:50-59`), so the card is invisible but nothing fails. I could not tell whether the agent's tool call waits on the answer (see the end).
- `terminal.attach` and `terminal.observe` gain `supportsSnapshotSequenceState`. A client that omits it gets the old replay text (`apps/server/src/terminal/Manager.ts:1491-1510`). Commit e6738fd8bc, PR #42817.
- `thread.visit-recorded`, `thread.tags-updated` and `thread.issue-synced` are already in `ThreadStream.swift`. The new `run.output-submitted` event decodes as an unknown event and is dropped, which loses nothing a client displays.
- Multi-repository checkpoints: repository scopes keep their own checkpoints. T3's `deriveThreadCheckpointSummaries` builds cards from `appRunOrdinal` and `runId` and does not filter by scope, and `T3Store/TurnDiffs.swift:50-57` is a port of it. So extra cards do not appear. The per-repository patches in `ThreadTurnRepositoryDiff` are not shown (addition A1).

## 2. Additions

Each item is safe to ignore against a 4928 server. The gate says how a client tells whether the server has it.

### Projects, threads and orchestration

- A1. Multi-repository projects. Adds `Project.trackedFolders` (`project.ts:194`, entry type `:56`, max 128) with the same field on create, update and the app events, `ProjectMutation.trackFolders` and `untrackFolders` (`:255-257`), six `workspace.*` RPCs (`rpc.ts:506-511`, handlers `:1711-1744`, schemas in the new `workspaceFolders.ts`), `TaskFolder` (`workspaceFolders.ts:70`), worktree layout commands with an approval step (`:109`, scope `terminal:operate` at `clientRpcPermissions.ts:76`, `source-control:write` for adding a repository at `:74`), `t3.json` keys `ignoreRepositories` (`t3ProjectFile.ts:106`) and `worktreeLayout` (`:112`), the launch strategy field `repositories` (`orchestrationV2.ts:798`), checkpoint scope `label` and `repositoryPath` (`:1096`, `:1102`), `repositories` on turn diffs (`checkpointDiff.ts:42`), `AppThread.rollbackUnrestored` (`:580`), and the managed policy limit `worktreeLayoutCommands` (`managedPolicy.ts:87`). Commits 60863edc41 (PR #35925), 924d9c1fff (PR #42386), 29c852eada (PR #41986). Gate: `Project.trackedFolders` is absent on a 4928 server, which means a single-folder project. CandyWrapper has no code for it.
- A2. Durable workflows (beta). The new `workflow.ts` holds runs, steps, questions, hooks and definition files. Adds 10 `workflows.*` RPCs (`rpc.ts:643-652`), settings `workflowsEnabled` (`settings.ts:1535`, default false) and `workflowSkippedRunsKept` (`:1537`), and the lineage and shell fields of B2. `workflows.subscribe` takes `changes: true` (`workflow.ts:257-260`) and then sends `WorkflowRunsChange` frames. `workflows.counts` streams a badge count. Answer, resume and cancel need `orchestration:operate` (`clientRpcPermissions.ts:90-92`), and saving or deleting a definition needs `terminal:operate` (`:94-95`). Commits e414cfd4be (PR #38882), 69c1d53826 (PR #38884), 8987ba39d4 (PR #42517), 7be3a767cc (PR #42515), 5ac27b4007 (PR #42008), 462596a0f7 (PR #42518), 3b5033a28c (PR #42506), adb6064469 (PR #42522), c6162da7ec (PR #42353). Gate: the setting, and a missing method on 4928. CandyWrapper has no code.
- A3. Typed turn results. A run can carry `outputSchema` (`orchestrationV2.ts:858`) and its `output` (`:813`), written by the event `run.output-submitted` (`:2255`) after the internal command `run.output.submit` (`:3851`). Agents ask for it with `outputSchema` on `t3_thread_send` and wait with `untilOutput` (`orchestratorMcp.ts:596`). Commit 2770bf3c61, PR #38874. Gate: none, since a 4928 server ignores the keys. CandyWrapper has no code and needs none unless it renders the field.
- A4. Agent feedback. Adds `agentFeedback.answerRequest` (`rpc.ts:661`, scope `orchestration:operate`, `clientRpcPermissions.ts:107`), the setting `agentFeedback.mode` of `off`, `on-request` or `auto` (`settings.ts:1172`, `:1431`), the turn item `feedback_request` with `preview`, `conversationTrace` and `feedbackStatus` (`orchestrationV2.ts:1902`), and capability `agentFeedback` (`environment.ts:226`). Commit fe9c98c98f, PR #35871. Gate: the capability. CandyWrapper has no code.
- A5. MCP sign-in from a thread. Adds `provider.mcpSignIn.start` and `.complete` (`rpc.ts:526-527`, scope `providers:manage`, `clientRpcPermissions.ts:24-25`) and the notice field `system_notice.mcpSignIn` (`orchestrationV2.ts:2051`). Commit 669d8941e2, PR #39921. Gate: a notice that carries `mcpSignIn`. CandyWrapper has no code.
- A6. Linked environments, read through. Adds `peerLinks.names`, `subscribeThread`, `threadHistoryPage`, `threadItem`, `pairClient` and `pairLink` (`rpc.ts:605-610`), `PeerLinkName` (`peerLink.ts:39`), the link-session routes under `/api/links/thread` (`:112-114`), the route `/api/peer-link/client-pairing` (`environmentHttp.ts:1069`), `PeerLinkRemoveResult.endedThere` (`peerLink.ts:69`), `PeerLinkError.answeredAs` (`:88`), and capabilities `linkThreadStream`, `linkClientPairing` and `linkPairingForLink` (`environment.ts:195-200`). Pairing calls need `access:write` plus the access they hand out (`clientRpcPermissions.ts:105-106`, `:132-139`). The client setting `sideThreadOpenTarget` (`settings.ts:542`) sets where subagents, side chats and linked threads open. Commits 1cb3a8c753 (PR #39406), d7f6b3efca (PR #39439), 6f644f6e91 (PR #40036), 8e8ff9b243 (PR #39426), f6d941fa4f (PR #39399), 28706aceb6 (PR #41005), 7c6e889ddb (PR #39515). Gate: the three capabilities. CandyWrapper has `T3Protocol/Domain/PeerLink.swift` for list, link, unlink and answering requests, and nothing for reading a linked thread.
- A7. Turn and run fields. Adds `RunAttempt.startedModes` (`orchestrationV2.ts:902`, commit 0d6fe2141a, PR #41746), `ProviderSession.startupPhase` and `startupPhaseThreadId` (`:1127-1130`, commits 611410683b PR #41242 and ff6b10e0a0 PR #41928), `ProviderTurn.promptDropped` (`:1378`, c5fa33b27e PR #40670), `TurnCapabilities.supportsNativeResume` (`:331`, 78d74598d4 PR #39229), `ToolCapabilities.supportsBackgroundWait` (`:362`, b5453de6b5 PR #38348), `assistant_message.delivery: "async"` (`:1940`, 0a0389e517 PR #41411), `ProviderFailure.verificationUrl` for Google account checks (`:1750`, 3e74a0aac5 PR #41210), approval `pushHooks` (`:2021`, c4d0e05d96 PR #42535) and the watch command flag `checksPending` (`:3552`, da33a53d18 PR #39116). Gate: each key is absent on 4928. CandyWrapper decodes none of them. The resume rule in section 5 depends on `supportsNativeResume`.
- A8. Smaller command fields. `queued-run.edit` takes `modelSelection` (`:3738`, commit d572ce9afe, PR #41814), the thread search input takes `theme` (`:4723`, 3b199e77fb PR #39308), `thread.create` takes `titleRenamed`, and `launchThread` takes `repositories` through the strategy (A1).

### Server config, providers and settings

- A9. Config fields. `ServerConfig.featureFlags` with `secretProviders` and `tanstackSource` (`server.ts:706`, `:749`, commit 10586f9e31, PR #40594), `ServerProvider.modelsRetained` so pickers keep models after one failed check (`:283`, 1a42ba1b5f PR #39114), `ServerObservability.relayTracingAllowed` (`:387`, dc7b8802b8 PR #42356), `ServerStartupStatus` with migration progress (`:1023`, 02d104f7e0 PR #37209), `ServerSelfUpdateError.trackMismatch` (`:1096`, 2713570406 PR #38506), and `server.probe` success `serverTime` (`rpc.ts:765`, e213da2a32 PR #41037). Gate: absent on 4928. CandyWrapper decodes none.
- A10. Settings keys. `enablePreviewTunnel` (`settings.ts:1447`, default true, and changing it needs `access:write`, `:2079` and `:2102`), with capability `previewTunnelSetting` (`environment.ts:152`) and managed policy `previewTunnel` (`managedPolicy.ts:85`), commit dcf158c591, PR #39415. Also `agentFeedback`, `workflowsEnabled` and `workflowSkippedRunsKept` (A2, A4), and the client settings `htmlPreviewWidth` of `chat`, `wide` or `full` (`:425`, 14ea095b0a PR #41663) and `sideThreadOpenTarget`. The provider form annotation `visibleWhen` (`:666`, 93b8dc3465 PR #40494) hides Antigravity fields that the chosen sign-in method does not use. Gate: hide the preview tunnel switch where `previewTunnelSetting` is absent, since the tunnel stays on there.
- A11. HTTP usage sources. Usage sources of kind `http` read `HttpQuotaResponse` (`providerUsageLimits.ts:102`) and report `quotaAccounts` (`:117`). A client opts in with `clientCapabilities=httpUsageLimitSources` on the socket URL (`environment.ts:23`, `client-runtime/src/connection/compatibility.ts:56`, server filter `serverSettings.ts:168`, `ws.ts:825`). Commit 16742ca802, PR #41291. CandyWrapper sends no `clientCapabilities` at all (it builds the socket URL at `T3Transport/EnvironmentHTTP.swift:281-282` and `T3Client/Connect/T3ConnectAuthorizer.swift:375`), so it sees hubs only. The same parameter also carries `settingsSecretReferences` from the 4928 audit, so the two should be adopted together.
- A12. Auth and relay. Adds RFC 7009 revocation at `POST /oauth/mcp/revoke` (`environmentHttp.ts:731`, `auth.ts:678`), `revocation_endpoint` in the authorization metadata (`auth.ts:560`), `AuthSessionState.sessionId` (`:540`), `EnvironmentInternalError.detail` (`environmentHttp.ts:262`, 1458a42419 PR #40424), relay link-proof reason `environment_key_mismatch` (`relay.ts:355`, aa685426e7 PR #39482), a Clerk account webhook group on the relay (`relay.ts:1326`, 3380585e1b), and the guest share scope rule: `guestShare.create` now needs `access:write` and `orchestration:read` (`clientRpcPermissions.ts:99-101`, 7dd35d324d PR #41742). Commit for revocation and `sessionId`: 28706aceb6, PR #41005 (and 7be3a767cc for the `sessionId` description). Gate: `revocation_endpoint` in the metadata.

### Issues, pull requests, git and review

- A13. Issue tracker accounts and scopes. A standalone tracker can hold several accounts (`IssueTrackerAccountId`, `issue.ts:37`). `issueTrackers.list` returns `accounts` (`:651`) and `accountBindings`, connect takes `addAccount`, bindings take `accountId` and `additionalScopes` (`:600`), `issues.list` takes `excludeProjectIds` (`:286`), and activity events carry a `reference`. Capability `issueTrackerAccounts` (`environment.ts:230`). Commits 0591d32888 (PR #39179), b568fcbaa6 (PR #40023), 9fde959ac0 (PR #38799), 671e05bc8c (PR #40768), c79f618bf8 (PR #39159), cad8cd0937 (PR #42350). CandyWrapper has `App/Sources/IssuesPage.swift` and `T3Protocol/Domain/Issues.swift` with none of these fields, so it shows only each tracker's first account.
- A14. Pull requests. `PullRequestListEntry.visibility` and the same on details (`pullRequest.ts:363`, e3f9db2447 PR #40741), capability `stackAutoMerge` (`:314`, 69d8f4217f PR #41809), `PullRequestChecks.workflowApprovalsRequired` (`:692`, 2514a5ce5e PR #42523), and `PullRequestSubmitReviewInput.expectedHeadSha` (`:852`, 78cffe29ec PR #41761). Gate: absent keys or the capability.
- A15. Git and review. `vcs.refreshStatus` returns `VcsRefreshStatusResult` with `refsDigest` (`git.ts:274`, `rpc.ts:1862`, e337cee952 PR #40385). A client skips reloading its branch list when the digest is unchanged. Review previews gain `mergeBase` (`review.ts:24`, 0fd4822887 PR #40216) and `completionToken` (`:30`, 67933a2236 PR #40211), so a complete read reuses the tracked-only pass.

### Terminal, devices and the rest

- A16. Terminal. Adds `supportsSnapshotSequenceState` on attach and observe (`terminal.ts:252`) with `historySequenceState` on the snapshot (`:348`), `bracketedPaste` and `plainWrite` phases on `terminal.write` (`:283-284`, commit 7d8c03fd99, PR #42948), `expectedPid` with `TerminalProcessChangedError` (`:291`, `:622`, commit a3a4592cf5, PR #42897), `supportsConditionalWrites` on the snapshot (`:345`), `pendingControlSequence` on the cleared event (c14e9f9717, PR #42810), and the keybindings `terminal.previous` and `terminal.next` (`keybindings.ts:70`, b6869fad67 PR #30664). `TerminalWriteInput.data` may be empty only for `plainWrite: "abort"`. CandyWrapper's `Terminal.swift:75` reads `cleared` without a payload, so it ignores `pendingControlSequence`.
- A17. Voice and assets. `speechHints` on dictation requests (`speech.ts:297`, d20e6c294c PR #39884), a `cancelled` flag on the model download reply (`speech.ts`, 2526691ea5 PR #39157), and an asset `disposition: "attachment"` (`assets.ts:37`, fb4558d77d PR #40631). `Features/Settings/VoiceSettingsView.swift` is the nearest CandyWrapper code.
- A18. Editor links. `ExternalLauncherRevealTargetMissingError` (`editor.ts:309`, 15d945faef PR #40637), `windowId=_blank` on SSH folder links (550c26635b PR #41610), and `chromium` in the browser import list (`browserImport.ts`, 5a156a2af8 PR #25698).
- A19. Desktop IPC only. Port forwarding (`ipc.ts`, 420d1b5900 PR #39393), Apple Speech (285558eb10 PR #34027), context menu `iconImage`, and the readiness secret (`desktopBootstrap.ts`). CandyWrapper does not use these.
- A20. Milestones. The new `milestones.ts` defines events for outside agents polling through MCP (`apps/server/src/mcp/McpHttpServer.ts`, commit fb23f12f1f, PR #40774). No RPC or stream carries them, so a native client has nothing to adopt.

## 3. RPC methods in `WsRpcGroup` at 5258

I generated this list from `WsRpcGroup` in `packages/contracts/src/rpc.ts` at both tags (260 methods at 5258, 235 at 4928). A method is "changed" when its `Rpc.make` body changed or when a schema it reaches through payload or success changed at any depth, with error channels left out and the base `GitRefName` and forward-compatibility helpers in `baseSchemas.ts` not counted as changes. It overstates a little, because the check follows schema names, not fields. The 25 new rows and the changes named in sections 1 and 2 were checked by hand. The 152 unchanged methods are not listed. "CandyWrapper calls it" means the method name appears as a string literal under `Packages/CandyKit/Sources` or `App/Sources`.

| Method | Status | rpc.ts line | Payload | Result | CandyWrapper calls it | Types changed |
|---|---|---|---|---|---|---|
| `agentFeedback.answerRequest` | new | 2445 | `AgentFeedbackAnswerInput` | `-` | no |  |
| `assets.createUrl` | changed | 1767 | `AssetCreateUrlInput` | `AssetCreateUrlResult` | yes | AssetCreateUrlInput |
| `git.preparePullRequestThread` | changed | 1892 | `GitPreparePullRequestThreadInput` | `GitPreparePullRequestThreadResult` | yes | GitPreparePullRequestThreadResult |
| `git.resolvePullRequest` | changed | 1886 | `GitPullRequestRefInput` | `GitResolvePullRequestResult` | yes | GitResolvePullRequestResult |
| `git.runStackedAction` | changed | 1879 | `GitRunStackedActionInput` | `GitActionProgressEvent` (stream) | yes | GitActionProgressEvent |
| `issueTrackers.bindProject` | changed | 1539 | `IssueTrackerBindProjectInput` | `Schema.Void` | yes | IssueTrackerBindProjectInput |
| `issueTrackers.connect` | changed | 1533 | `IssueTrackerConnectInput` | `IssueTrackerConnection` | yes | IssueTrackerConnectInput, IssueTrackerConnection |
| `issueTrackers.list` | changed | 1523 | `Schema.Struct({})` | `IssueTrackerConnectionList` | yes | IssueTrackerConnectionList |
| `issues.candidates` | changed | 1481 | `IssueScopeRef` | `IssueCandidates` | yes | IssueCandidates, IssueScopeRef |
| `issues.comment` | changed | 1493 | `IssueCommentInput` | `Schema.Void` | yes | IssueCommentInput |
| `issues.comments` | changed | 1468 | `IssueCommentsPageInput` | `IssueCommentsPage` | yes | IssueCommentsPageInput |
| `issues.create` | changed | 1487 | `IssueCreateInput` | `IssueCreateResult` | no | IssueCreateInput |
| `issues.detail` | changed | 1455 | `IssueRef` | `IssueDetail` | yes | IssueDetail, IssueRef |
| `issues.linkedThreads` | changed | 1462 | `ThreadIssueKey` | `IssueLinkedThreadsResult` | yes | ThreadIssueKey |
| `issues.list` | changed | 1449 | `IssueListInput` | `IssueListResult` | yes | IssueListInput, IssueListResult |
| `issues.react` | changed | 1511 | `IssueReactionInput` | `Schema.Void` | yes | IssueReactionInput |
| `issues.setState` | changed | 1505 | `IssueSetStateInput` | `Schema.Void` | yes | IssueSetStateInput |
| `issues.templates` | changed | 1474 | `IssueScopeRef` | `IssueTemplateList` | no | IssueScopeRef |
| `issues.update` | changed | 1499 | `IssueUpdateInput` | `Schema.Void` | yes | IssueUpdateInput |
| `orchestration.dispatchCommand` | changed | 2121 | `dispatchCommand.input` | `dispatchCommand.output` | yes | OrchestrationV2Command |
| `orchestration.getArchivedShellSnapshot` | changed | 2164 | `getArchivedShellSnapshot.input` | `getArchivedShellSnapshot.output` | yes | OrchestrationV2ArchivedShellSnapshot |
| `orchestration.getFullThreadDiff` | changed | 2133 | `getFullThreadDiff.input` | `getFullThreadDiff.output` | yes | OrchestrationGetFullThreadDiffResult |
| `orchestration.getOlderSettledThreads` | changed | 2203 | `getOlderSettledThreads.input` | `getOlderSettledThreads.output` | yes | OrchestrationV2OlderSettledThreadsPage |
| `orchestration.getThreadFamily` | changed | 2173 | `getThreadFamily.input` | `getThreadFamily.output` | yes | OrchestrationV2ThreadFamily |
| `orchestration.getThreadProjection` | changed | 2212 | `getThreadProjection.input` | `getThreadProjection.output` | yes | OrchestrationV2ThreadProjection |
| `orchestration.getTurnDiff` | changed | 2127 | `getTurnDiff.input` | `getTurnDiff.output` | yes | OrchestrationGetTurnDiffInput, OrchestrationGetTurnDiffResult |
| `orchestration.getTurnItem` | changed | 2251 | `getTurnItem.input` | `getTurnItem.output` | yes | OrchestrationV2GetTurnItemResult |
| `orchestration.launchThread` | changed | 2257 | `launchThread.input` | `launchThread.output` | yes | OrchestrationV2ThreadLaunchInput, OrchestrationV2ThreadLaunchResult |
| `orchestration.searchThread` | changed | 2142 | `OrchestrationV2SearchThreadInput` | `OrchestrationV2SearchThreadResult` | yes | OrchestrationV2SearchThreadInput |
| `orchestration.searchThreadStream` | changed | 2148 | `OrchestrationV2SearchThreadInput` | `OrchestrationV2SearchThreadResult` (stream) | yes | OrchestrationV2SearchThreadInput |
| `orchestration.searchThreads` | changed | 2158 | `OrchestrationV2SearchThreadsInput` | `OrchestrationV2SearchThreadsResult` | yes | OrchestrationV2SearchThreadsResult |
| `orchestration.subscribeShell` | changed | 2263 | `subscribeShell.input` | `subscribeShell.output` (stream) | yes | OrchestrationV2ShellStreamItem |
| `orchestration.subscribeThread` | changed | 2270 | `subscribeThread.input` | `subscribeThread.output` (stream) | yes | OrchestrationV2ThreadStreamItem |
| `peerLinks.list` | changed | 963 | `Schema.Struct({})` | `Schema.Struct({ links: Schema.Array(PeerLinkSummary) })` | yes | PeerLinkSummary |
| `peerLinks.names` | new | 970 | `Schema.Struct({})` | `Schema.Struct({ links: Schema.Array(PeerLinkName) })` | no |  |
| `peerLinks.pairClient` | new | 1008 | `PeerLinkClientPairingInput` | `PeerLinkClientPairingResult` | no |  |
| `peerLinks.pairLink` | new | 1014 | `PeerLinkLinkPairingInput` | `PeerLinkClientPairingResult` | no |  |
| `peerLinks.subscribeThread` | new | 989 | `PeerLinkThreadInput` | `subscribeThread.output` (stream) | no |  |
| `peerLinks.threadHistoryPage` | new | 996 | `PeerLinkThreadHistoryInput` | `OrchestrationV2ThreadHistoryPage` | no |  |
| `peerLinks.threadItem` | new | 1002 | `PeerLinkThreadItemInput` | `getTurnItem.output` | no |  |
| `peerLinks.unlink` | changed | 982 | `PeerLinkRemoveInput` | `PeerLinkRemoveResult` | yes | PeerLinkRemoveResult |
| `projects.mutate` | changed | 1670 | `ProjectMutation` | `Project` | yes | Project, ProjectMutation |
| `provider.auth.cancel` | changed | 864 | `ProviderAuthCancelInput` | `ProviderAuthState` | yes | ProviderAuthState |
| `provider.auth.complete` | changed | 841 | `ProviderAuthCompleteInput` | `ProviderAuthState` | yes | ProviderAuthState |
| `provider.auth.logout` | changed | 876 | `ProviderSetupInput` | `ProviderAuthState` | yes | ProviderAuthState |
| `provider.auth.removeMethod` | changed | 870 | `ProviderAuthRemoveMethodInput` | `ProviderAuthState` | no | ProviderAuthState |
| `provider.auth.respond` | changed | 835 | `ProviderAuthRespondInput` | `ProviderAuthState` | yes | ProviderAuthRespondInput, ProviderAuthState |
| `provider.auth.start` | changed | 829 | `ProviderAuthStartInput` | `ProviderAuthState` | yes | ProviderAuthState |
| `provider.auth.subscribe` | changed | 882 | `ProviderSetupInput` | `ProviderAuthState` (stream) | yes | ProviderAuthState |
| `provider.chatgpt.handoff.subscribe` | changed | 857 | `ChatGptHandoffInput` | `ChatGptHandoffState` (stream) | yes | ChatGptHandoffState |
| `provider.chatgpt.import-profile` | changed | 852 | `ChatGptImportProfileInput` | `ProviderAuthState` | yes | ProviderAuthState |
| `provider.mcpSignIn.complete` | new | 1825 | `ProviderMcpSignInCompleteInput` | `ProviderMcpSignInCompleteResult` | no |  |
| `provider.mcpSignIn.start` | new | 1819 | `ProviderMcpSignInStartInput` | `ProviderMcpSignInStartResult` | no |  |
| `pullRequests.checks` | changed | 1285 | `PullRequestRef` | `Schema.NullOr(PullRequestChecks)` | yes | PullRequestChecks |
| `pullRequests.detail` | changed | 1273 | `PullRequestRef` | `PullRequestDetail` | yes | PullRequestDetail |
| `pullRequests.list` | changed | 1224 | `PullRequestListInput` | `PullRequestListResult` | yes | PullRequestListResult |
| `pullRequests.runAction` | changed | 1339 | `PullRequestActionInput, // Undefined unless asked for with replyWithSu` | `Schema.UndefinedOr(PullRequestSummary)` | yes | PullRequestSummary |
| `pullRequests.stack` | changed | 1261 | `PullRequestRef` | `Schema.NullOr(PullRequestStack)` | yes | PullRequestStack |
| `pullRequests.submitReview` | changed | 1364 | `PullRequestSubmitReviewInput` | `Schema.Void` | yes | PullRequestSubmitReviewInput |
| `pullRequests.summary` | changed | 1255 | `PullRequestRef` | `PullRequestSummary` | no | PullRequestSummary |
| `review.getBranchCommits` | changed | 1933 | `ReviewBranchCommitsInput` | `ReviewBranchCommitsResult` | yes | ReviewBranchCommitsInput |
| `review.getDiffFileContents` | changed | 1945 | `ReviewDiffFileContentsInput` | `ReviewDiffFileContentsResult` | yes | ReviewDiffFileContentsInput |
| `review.getDiffPreview` | changed | 1939 | `ReviewDiffPreviewInput` | `ReviewDiffPreviewResult` | yes | ReviewDiffPreviewInput, ReviewDiffPreviewResult |
| `scheduledTasks.rotateWebhookToken` | changed | 2425 | `ScheduledTaskRotateWebhookTokenInput` | `ScheduledTaskMutationResult` | yes | ScheduledTaskMutationResult |
| `scheduledTasks.runNow` | changed | 2419 | `ScheduledTaskRunNowInput` | `ScheduledTaskRunNowResult` | yes | ScheduledTaskRunNowResult |
| `scheduledTasks.setEnabled` | changed | 2407 | `ScheduledTaskSetEnabledInput` | `ScheduledTaskMutationResult` | yes | ScheduledTaskMutationResult |
| `scheduledTasks.subscribe` | changed | 2394 | `ScheduledTaskListInput` | `ScheduledTaskListResult` (stream) | yes | ScheduledTaskListResult |
| `scheduledTasks.upsert` | changed | 2401 | `ScheduledTaskUpsertInput` | `ScheduledTaskMutationResult` | yes | ScheduledTaskUpsertInput, ScheduledTaskMutationResult |
| `secrets.answerRequest` | changed | 2440 | `SecretRequestAnswerInput` | `-` | yes | SecretRequestAnswerInput |
| `server.getConfig` | changed | 770 | `Schema.Struct({})` | `ServerConfig` | yes | ServerConfig |
| `server.getSettings` | changed | 1026 | `Schema.Struct({})` | `ServerSettings` | no | ServerSettings |
| `server.probe` | changed | 762 | `Schema.Struct({})` | `Schema.Struct({ serverTime: Schema.optionalKey(IsoDateTime), })` | yes | body |
| `server.refreshProviders` | changed | 776 | `Schema.Struct({ instanceId: Schema.optional(ProviderInstanceId), cwd: ` | `ServerProviderUpdatedPayload` | yes | ServerProviderUpdatedPayload |
| `server.removeKeybinding` | changed | 756 | `ServerRemoveKeybindingInput` | `ServerRemoveKeybindingResult` | yes | ServerRemoveKeybindingInput, ServerRemoveKeybindingResult |
| `server.updateProvider` | changed | 815 | `ServerProviderUpdateInput` | `ServerProviderUpdatedPayload` | yes | ServerProviderUpdatedPayload |
| `server.updateSettings` | changed | 1032 | `Schema.Struct({ patch: ClientServerSettingsPatch, providerInstanceMuta` | `ServerSettings` | yes | ClientServerSettingsPatch, ServerSettings |
| `server.upsertKeybinding` | changed | 750 | `ServerUpsertKeybindingInput` | `ServerUpsertKeybindingResult` | yes | ServerUpsertKeybindingInput, ServerUpsertKeybindingResult |
| `sourceControl.publishRepository` | changed | 1628 | `SourceControlPublishRepositoryInput` | `SourceControlPublishRepositoryResult` | yes | SourceControlPublishRepositoryResult |
| `subscribeServerConfig` | changed | 2304 | `Schema.Struct({ /** Opt-in protects older clients that reject unknown ` | `ServerConfigStreamEvent` (stream) | yes | ServerConfigStreamEvent |
| `subscribeServerLifecycle` | changed | 2328 | `Schema.Struct({})` | `ServerLifecycleStreamEvent` (stream) | yes | ServerLifecycleStreamEvent |
| `subscribeVcsStatus` | changed | 1844 | `VcsStatusSubscriptionInput` | `VcsStatusStreamEvent` (stream) | yes | VcsStatusStreamEvent |
| `subscribeWorktreeSetup` | changed | 1866 | `WorktreeSetupSubscribeInput` | `WorktreeSetupStreamEvent` (stream) | yes | WorktreeSetupStreamEvent |
| `terminal.attach` | changed | 1957 | `TerminalAttachInput` | `TerminalAttachStreamEvent` (stream) | yes | TerminalAttachInput, TerminalAttachStreamEvent |
| `terminal.observe` | changed | 1964 | `TerminalObserveInput` | `TerminalAttachStreamEvent` (stream) | no | TerminalObserveInput, TerminalAttachStreamEvent |
| `terminal.open` | changed | 1951 | `TerminalOpenInput` | `TerminalSessionSnapshot` | yes | TerminalSessionSnapshot |
| `terminal.write` | changed | 1971 | `TerminalWriteInput` | `-` | yes | TerminalWriteInput |
| `vcs.createRef` | changed | 1916 | `VcsCreateRefInput` | `VcsCreateRefResult` | yes | VcsCreateRefInput, VcsCreateRefResult |
| `vcs.createWorktree` | changed | 1904 | `Schema.Struct({ ...VcsCreateWorktreeInput.fields, path: Schema.Null })` | `VcsCreateWorktreeResult` | no | VcsCreateWorktreeInput, VcsCreateWorktreeResult |
| `vcs.listRefs` | changed | 1898 | `VcsListRefsInput` | `VcsListRefsResult` | yes | VcsListRefsResult |
| `vcs.pull` | changed | 1851 | `VcsPullInput` | `VcsPullResult` | yes | VcsPullResult |
| `vcs.refreshStatus` | changed | 1857 | `Schema.Struct({ ...VcsStatusInput.fields, localOnly: Schema.optional(S` | `VcsRefreshStatusResult` | yes | body, VcsRefreshStatusResult, new VcsRefreshStatusResult |
| `vcs.switchRef` | changed | 1922 | `VcsSwitchRefInput` | `VcsSwitchRefResult` | yes | VcsSwitchRefInput, VcsSwitchRefResult |
| `workflows.about` | new | 2355 | `WorkflowRunsAboutInput` | `WorkflowRunsAbout` | no |  |
| `workflows.answer` | new | 2361 | `WorkflowAnswerInput` | `-` | no |  |
| `workflows.cancel` | new | 2371 | `WorkflowRunCancelInput` | `-` | no |  |
| `workflows.counts` | new | 2342 | `WorkflowRunsSubscribeInput` | `WorkflowCounts` (stream) | no |  |
| `workflows.deleteDefinition` | new | 2388 | `WorkflowDefinitionDeleteInput` | `WorkflowDefinitionChangeResult` | no |  |
| `workflows.get` | new | 2349 | `WorkflowRunGetInput` | `WorkflowRunDetail` | no |  |
| `workflows.getDefinition` | new | 2376 | `WorkflowDefinitionGetInput` | `WorkflowDefinitionFiles` | no |  |
| `workflows.resume` | new | 2366 | `WorkflowRunResumeInput` | `-` | no |  |
| `workflows.saveDefinition` | new | 2382 | `WorkflowDefinitionSaveInput` | `WorkflowDefinitionChangeResult` | no |  |
| `workflows.subscribe` | new | 2335 | `WorkflowRunsSubscribeInput` | `WorkflowRunsUpdate` (stream) | no |  |
| `workspace.addTaskFolderRepository` | new | 1729 | `WorkspaceAddTaskFolderRepositoryInput` | `TaskFolder` | no |  |
| `workspace.approveLayoutCommands` | new | 1744 | `WorkspaceApproveLayoutCommandsInput` | `WorkspaceLayoutCommandsResult` | no |  |
| `workspace.layoutCommands` | new | 1738 | `WorkspaceLayoutCommandsInput` | `WorkspaceLayoutCommandsResult` | no |  |
| `workspace.listFolders` | new | 1711 | `WorkspaceListFoldersInput` | `WorkspaceListFoldersResult` | no |  |
| `workspace.scanFolders` | new | 1717 | `WorkspaceScanFoldersInput` | `WorkspaceScanFoldersResult` | no |  |
| `workspace.taskFolder` | new | 1723 | `WorkspaceTaskFolderInput` | `WorkspaceTaskFolderResult` | no |  |

## 4. Telling a 5258 server from a 4928 server

There is no protocol version bump (still 2), so every difference is a capability, a descriptor or config field, a setting, a missing method, or a frame.

- B1 needs no check, since the extra key is ignored on 4928.
- B2 appears only when `ServerSettings.workflowsEnabled` is true. A 4928 server has no such key and never sets `lineage.workflowStep`.
- B3 appears only when an item carries `fields`. A 4928 server never sends it.
- B4 shows as a Pong with no ping outstanding, within 20 seconds of connect. Servers before ad446450e1 never send one.
- Capabilities added in `ExecutionEnvironmentCapabilities` (`environment.ts`): `previewTunnelSetting` (`:152`), `linkThreadStream` (`:195`), `linkClientPairing` (`:198`), `linkPairingForLink` (`:200`), `agentFeedback` (`:226`) and `issueTrackerAccounts` (`:230`). The PR capability `stackAutoMerge` is at `pullRequest.ts:314`.
- Socket URL parameter: `clientCapabilities` gains `httpUsageLimitSources` (`environment.ts:23`). A server that predates it ignores the parameter value.
- Methods with no flag (workflows, workspace folders, MCP sign-in, peer link reads, agent feedback): call and treat a method-not-found failure as "not on this server". `ServerConfig.featureFlags` (`server.ts:749`) carries only `secretProviders` and `tanstackSource`.
- Fields with no flag (`trackedFolders`, `workflowRun`, `startupPhase`, `refsDigest`, `serverTime`, `visibility`): absent on 4928, so decode as optional.

## 5. Client-runtime and shared behavior to mirror

None of these change a schema. Each is what T3's own client now does that a native client should match.

- Resend after a lost socket. The first message of a new thread (`launchThread`), `message.dispatch`, `queue.resume` and `queued-message.promote-to-steer` are resent up to 2 times (`operations/commands.ts:313`, `:319`) when the socket drops. It waits for the replacement session (or for the connection to become available or blocked) and reuses the same command id, so the server de-duplicates. A message dispatch also times out after 60 seconds (`:317`). Commit 11224f63d2, PR #40703.
- Offline settle and snooze. A new outbox stores a settle or snooze made while the host is unreachable and replays it (`state/threadTriageOutbox.ts`, `state/threadCommands.ts:81`, the store in `platform/threadTriageOutboxStore.ts`). Commit 78de041d48, PR #24917.
- Reconnect loop. An unexpected defect no longer stops the loop for good, and a defect in a background listener restarts it (`connection/supervisor.ts:479`, `:1222`). Commits 38bac7091a (PR #39420) and 003d53ace1 (PR #39431). CandyWrapper should check that its own supervisor retries after a non-transport error.
- Session errors. After the socket opens, a quiet host reads "stopped responding" and only a socket that never opened gets the network hint (`rpc/session.ts:209-232`). An undecodable first `ServerConfig` blocks the connection as incompatible, and an undecodable later update ends the session (`:377-405`, `closingSession` at `:320`). Commit b479ce21ed, PR #21667.
- Clock offset. A timestamp from the host is never in its own future, so `observeServerTime` raises a stale negative offset and leaves an agreeing clock alone (`clock.ts:113`). `server.probe` now returns `serverTime` (`rpc.ts:765`). Commit e213da2a32, PR #41037.
- Environment identity. When an address answers as a different environment, the error tells the user to remove and re-add the connection (`connection/errors.ts:58`). `ConnectionOnboarding.reaches` asks a host for its descriptor with a 6 second timeout (`connection/onboarding.ts:224`). A route can be removed only when another route stays (`connection/routes.ts:485`). Tailscale HTTPS is labeled apart from plain Tailscale.
- Clerk at launch. An unreachable Clerk API at launch looks signed out, so the account service stays unobserved until a real `/v1/client` response arrives (`relay/cloudAccountService.ts:22`). Commit 314a11498e, PR #24642.
- Resumable runs. `deriveResumableRunId` offers Resume for an interrupted run, or a failed run with a `usage_limit` error, and hides it when the session reports `supportsNativeResume === false` unless an unsent message can be resent (`state/threadExecution.ts:425`). Commit 78d74598d4, PR #39229. The thread error banner keys on `threadErrorSource` so a repeated error with the same text shows again (`:539`, commit 5872b0a488, PR #37419).
- Provider startup label. A run with no provider output yet shows "Loading {provider} plugins", "Starting {provider} MCP servers", "Loading {provider} hooks", "Loading {provider} rules and skills", "Resuming {provider} session", "Connecting to {provider}" or "Starting {provider}", from `ProviderSession.startupPhase` (`state/threadExecution.ts:119-230`, commits 611410683b and ff6b10e0a0). An earlier version of this note left out the provider name and pointed at `threadStream.ts`.
- Workflow lists. `workflows.subscribe` is called with `changes: true` and the client folds each frame with `applyWorkflowRunsUpdate` (`state/server.ts:1477`, `workflow.ts` helper). Commit adb6064469, PR #42522.
- Multi-repository checkpoints. Repository scopes are excluded when picking the checkpoint for a rewind, and a rewind can leave `rollbackUnrestored` (`operations/commands.ts` near `revertThreadCheckpoint`, `state/threadRepositories.ts`). Commit 60863edc41.
- Linked threads. A thread read through a link is built from its stream alone (`state/threadStream.ts:18`). Retry restarts the read, history pages survive reopening a snapshot, and lower-priority linked addresses are not waited for (commits 5bd0616f05, 464e8f7e60, 3806763022).
- Connect device notices. T3 Connect devices first seen after a per-client watermark raise a notice (`connectDeviceNotices.ts:8`). Commit ece5f21b17, PR #42311. The server side exists since 4928.
- Changed-files card. T3 removed the card under assistant turns on web and mobile. Commit 1c6d41a9ba, PR #41317. This is a UI fidelity item for the default themes.
- Commands run on the caller's fiber, so interrupting a caller stops its command (`state/runtime.ts:176`, commit 73caab68e3, PR #38912). Several callers of one single-flight command share one run.
- Server-side behavior seen by clients: a thread resume replays a deleted thread from its deletion (`apps/server/src/ws.ts`, commit 82af3cf2c3, PR #41874), revoking all other sessions also revokes unspent pairing codes and sign-ins in progress (ebf7b9a4c5 PR #39495, cc2e4c1704 PR #41884), and API request bodies have a 1 MiB limit (2dd323463a PR #41747).

## 6. Port list for the wire layer

Breaks first, then additions ranked by how much a user would notice. Each item is sized for one agent, and estimates are agent time including tests.

1. B1, scheduled task unbind. Send `unbindThread: true` with a cleared thread and add a test of the payload. About 15 minutes.
2. B3, multi-field secret cards. Decode `fields`, draw one input per field, send `values`, and keep the single-secret path. About 1 hour, plus a check against a sandbox server with a `request_secret` call that uses `fields`.
3. B4, heartbeat Pong. Stop trusting an unsolicited Pong, fix the comment in `ConnectionSupervisor.swift`, and run `scripts/perf-review` against a 5258 sandbox. About 1 hour, mostly the perf run.
4. B2, workflow step lineage. Add `workflowStep` and `workflowRun`, extend `isListedLineage`. About 20 minutes.
5. A11, `clientCapabilities`. Send `httpUsageLimitSources` together with `settingsSecretReferences` only once the matching UI exists. Showing HTTP quota sources needs a Limits row for them. About 1 hour for the wire and a new row.
6. A1, multi-repository projects. Decode `trackedFolders`, the checkpoint scope fields and `ThreadTurnRepositoryDiff`, then plan the UI separately. This is a feature area and needs its own plan.
7. A2, workflows. Also a feature area with ten RPCs and a sidebar surface. Plan it separately, after B2.
8. A6, linked environment thread reads. A new feature area. Needs its own plan.
9. A7, turn and run fields. Decode `supportsNativeResume` and `startupPhase` first, because they change when Resume shows and what the running label says. About 45 minutes.
10. A15, `refsDigest`. Skip the branch list reload when the digest matches. About 30 minutes, and it lowers idle work.

Everything else in section 2 can wait until the matching UI is ported.

Port status on branch `wire-5258`: items 1 to 4, 9 (decode and the Resume rule) and 10 are done, and 5 sends an empty `clientCapabilities` list because neither capability's decoder exists yet. Items 6 to 8 have types and calls in `T3Protocol` and no UI. B4 kept the watchdog's ping and sends two per round instead of dropping it, because a 4928 server sends no heartbeat.

## 7. Decoder strictness

CandyWrapper's stream and event decoders stay tolerant in this range.

- `TurnItemType` keeps unknown types as generic items only when their common fields decode, and drops the rest from projections (`TurnItem.swift:50-59`). That is why `feedback_request` disappears instead of failing.
- `ThreadEventType` maps `run.output-submitted` to `.unknownEvent`, which advances the cursor.
- `ServerSettings` decoding ignores `agentFeedback`, `workflowsEnabled`, `workflowSkippedRunsKept` and `enablePreviewTunnel`.
- The closed enums from the 4928 audit (`TerminalSessionStatus`, `PeerLink.Status`) kept their value sets in this range.

## What I could not determine

- Settled by the wire port (branch `wire-5258`): `fixtures/transcripts/27-nightly-5258.jsonl` records a 5258 sandbox session with one haiku turn, and `Nightly5258WireTests.recorded5258SessionDecodes` decodes it with this build. The heartbeat Pong arrived at 20.1 s with no ping sent, both refreshes carried `refsDigest`, and the Claude session reported `supportsNativeResume: true` and `startupPhase` `mcp` then `connecting`.
- Settled: a `feedback_request` card does not block the agent. The `t3_feedback` tool (`apps/server/src/mcp/toolkits/feedback/tools.ts:24-34`) answers `{status: "awaiting_approval"}` at once (`apps/server/src/feedback/FeedbackService.ts:214`), and its note tells the agent not to wait or send the report another way (`FeedbackReport.ts:58-66`). An unanswered card in CandyWrapper leaves the report unsent and the turn running normally.
- The "changed" column in section 3 follows schema names, so some rows may be marked changed only because a nested type changed elsewhere. I read the contract diffs in full and the client-runtime diffs for connection, RPC session, commands, runtime, server state and threads. The second pass marked every uncited row in section 8 (see there).
- Whether T3 plans to enable workflows or agent feedback by default.
- The multi-repository checkpoint claim (no extra cards) rests on T3's shared summary code. I did not check which `appRunOrdinal` the server writes for a repository scope.

## 8. Every commit that touches the three packages

`git -C ~/CandyWrapper-research/t3code log --oneline v0.1.11-nightly.20261119.4928..v0.1.13-nightly.20261125.5258 -- packages/contracts packages/client-runtime packages/shared` lists 245 commits. I left out 10 whose subject starts with `test`, `chore` or `refactor`. Of the 235 below, 95 are cited in sections 1 to 6 and 140 were not. The wire port's second pass gave each of the 140 a status. "read" means I read the diff of its `packages/contracts/src`, `client-runtime` or `shared` files: all 15 that touch contract sources and the client-runtime ones that can change what a client sends or decodes. "skimmed" means I classified it from its subject and the files it touches (`git show --stat`). None of the 140 changes the wire for CandyWrapper beyond what sections 1 and 2 list. Two are worth a later port: 7ef7ba0e3b (send `changeType` with a Diff panel patch read) and 73e6472545 (force a full snapshot after a resumed replay dies). The rest are UI rules for the matching UI agent, server, desktop or mobile changes, or presentation helpers.

| Commit | PR | Subject | Cited above |
|---|---|---|---|
| bf961f8121 | #43008 | fix(server): Claude no longer gets MCP app notes again after a server restart | cited |
| c4d0e05d96 | #42535 | fix(server): agents below Full access ask before a push runs repository hooks | cited |
| 8987ba39d4 | #42517 | feat(workflows): a run can declare its subject and be found by it | cited |
| 96423cb5e2 | #43026 | fix(server): stop reading Antigravity usage limits from Google's internal APIs | skimmed: usage and limits copy or math; for the Limits UI agent |
| cecbe8a89a | #43014 | fix(shared): new thread titles no longer end with a space before "..." | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 09385a33ce | #42974 | fix(shared): usage page says "record was skipped" for one malformed record | skimmed: usage and limits copy or math; for the Limits UI agent |
| cbc3057f59 | #42921 | fix(web,mobile): a running Read's image shows a loading frame, not "Image unavailable" | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 667cb3b255 | #42956 | fix(contracts): pull request and issue errors reach clients behind T3 Connect | cited |
| 93b8dc3465 | #40494 | fix(web): Antigravity settings show only the fields the chosen sign-in method uses | cited |
| 7d8c03fd99 | #42948 | fix(terminal): keep other input out of large bracketed pastes | cited |
| a3a4592cf5 | #42897 | fix(web): release terminal reply ownership when the drawer closes | cited |
| 867a9f0aec | #42927 | fix(terminal): keep line breaks when joining a running terminal | read: terminal snapshot replay helpers (terminal.ts); CandyWrapper doesn't send supportsSnapshotSequenceState, so it gets the old replay (A16) |
| 9e385083d6 | #42918 | fix(client-runtime): a composer send right after Stop queues instead of failing to steer | read: a send right after Stop queues instead of steering (threadWorkflows.ts). Composer rule; for the composer UI agent |
| 0f55a0dc37 | #42900 | fix(web): empty files and folders in archive previews show 0 bytes instead of 1 KB | skimmed: presentation logic with no wire change; for the UI agent of that area |
| c14e9f9717 | #42810 | fix(server): preserve split terminal control sequences across scrollback clears | cited |
| f1efcfb494 | #42855 | fix(client-runtime): feedback trace shows "1 character", not "1 characters" | skimmed: presentation logic with no wire change; for the UI agent of that area |
| e6738fd8bc | #42817 | fix(server): retain unfinished terminal sequences in attach history | cited |
| 07276c4197 | #42691 | fix(shared): backticked insights keep their line breaks | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 462596a0f7 | #42518 | feat(workflows): named pools cap how much runs at once, with queueing | cited |
| 3b5033a28c | #42506 | feat(server): withdraw a waiting workflow question without cancelling its run | cited |
| ef4a1643ed | #42629 | fix(telemetry): honor DO_NOT_TRACK | read: DO_NOT_TRACK env key, server telemetry only |
| 2c95b69f25 | #42627 | fix: screenshots after a caption render full size instead of as chips | skimmed: presentation logic with no wire change; for the UI agent of that area |
| c925b9ab19 | #42630 | feat(server): CI runners don't need telemetry | skimmed: server, CLI or desktop only |
| 3e74a0aac5 | #41210 | fix(antigravity): link directly to Google account verification on failed turns | cited |
| e2c3c4250d | #31561 | fix(preview): streamed browser tabs show native select menus | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 7be3a767cc | #42515 | feat(server): workflow questions take described choices, required reasons, links, and keep who answered | cited |
| 62e8042b21 | #37700 | feat(search): a query in double quotes finds its words together | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 02d104f7e0 | #37209 | fix(startup): show database migration progress | cited |
| b6869fad67 | #30664 | feat(terminal): Add keybindings for cycling through terminals | cited |
| adb6064469 | #42522 | fix(server): workflow watchers get what changed, not the whole list | cited |
| 2514a5ce5e | #42523 | fix(pr): keep CI approval in sync with running checks | cited |
| 89d9e74df4 | #42492 | fix(web,mobile): a 9.96-second workflow step reads 10s, not 10.0s | skimmed: workflow display helper (client-runtime workflows.ts); for the workflows UI agent |
| 5a156a2af8 | #25698 | fix(desktop): detect Chromium profiles for cookie import | cited |
| e4da383485 | #42467 | fix(web,mobile): CJK project names get a one-character monogram | skimmed: presentation logic with no wire change; for the UI agent of that area |
| eaa3f7da13 | #42478 | fix(chat): load HTML reports when the filename limit splits an emoji | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 78de041d48 | #24917 | fix: settle and snooze threads while their machine is offline | cited |
| 5ac27b4007 | #42008 | feat(workflows): questions have kinds and runs have tags, and Needs you filters by kind | cited |
| dfa73216cc | #42429 | fix(web): search results show the matched lines | skimmed: presentation logic with no wire change; for the UI agent of that area |
| cb09dea14d | #42427 | fix(shared): chunked Markdown previews keep a link definition right after a code fence | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 16742ca802 | #41291 | feat(usage): support user-hosted HTTP quota sources | cited |
| c6162da7ec | #42353 | fix(server): skipped workflow runs no longer keep their webhook payloads forever | cited |
| 924d9c1fff | #42386 | feat(projects): worktree layout commands run only once a person approves them | cited |
| 9c64ebc370 | #42416 | fix(usage): pooled limits no longer flip by a percent between refreshes | skimmed: usage and limits copy or math; for the Limits UI agent |
| b20d7c5c7b | #42426 | fix(dev): phones can pair through the web dev proxy again | skimmed: server, CLI or desktop only |
| 55085df2a6 | #42369 | fix(client-runtime): images read from paths with %, # or ? show their preview | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 4b9482e295 | #42405 | fix(shared): Usage hour labels honor the 12-hour preference in non-English locales | skimmed: usage and limits copy or math; for the Limits UI agent |
| dc7b8802b8 | #42356 | fix(connect): respect relay tracing opt-outs and remove machine details | cited |
| 11edf884bc | #42409 | fix(web,mobile): workflowChip keeps non-BMP characters intact | skimmed: workflow display helper (client-runtime workflows.ts); for the workflows UI agent |
| 3ba003be06 | #42376 | fix(desktop): Windows desktop applies the saved user telemetry opt-out | skimmed: server, CLI or desktop only |
| 3380585e1b | #42285 | feat(relay): delete a user's relay data when Clerk deletes the user | cited |
| cad8cd0937 | #42350 | fix(server): honor sort: "created" when merging IssueService.list entries | cited |
| e6967d9dfe | #42331 | fix(client): a tab-indented fence line in a PR description code block no longer swaps which video plays | skimmed: presentation logic with no wire change; for the UI agent of that area |
| ece5f21b17 | #42311 | feat(connect): tell people when a new T3 Connect device signs in | cited |
| dffbfdfc00 | #42305 | fix(web): shell calls without -c no longer add agent working folders | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 6c0621f78a | #42301 | fix(web): branch picker shows the right name for remotes containing slashes | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 83990ad9a2 | #42272 | fix(server): notebook attachments show a progress bar's last frame | skimmed: presentation logic with no wire change; for the UI agent of that area |
| e3ff780247 | #42266 | fix(projects): keep # in clone folders for SCP-style remotes | skimmed: presentation logic with no wire change; for the UI agent of that area |
| ff7d03ddfd | #42265 | fix(client-runtime): omit failed image reads from viewed-image previews | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 4c2e2b3734 | #42248 | fix(web,mobile): a 59.5-second workflow step reads 1m 0s, not 60s | skimmed: workflow display helper (client-runtime workflows.ts); for the workflows UI agent |
| 6d4375aaf8 | #42233 | perf(client-runtime): avoid quadratic scans when ordering diff files by imports | skimmed: presentation logic with no wire change; for the UI agent of that area |
| a7a6126a7d | #42162 | fix(web): a captioned PR video no longer hides the text and video after it | skimmed: presentation logic with no wire change; for the UI agent of that area |
| d7ae1e1791 | #33002 | fix(web): report server rollback after an app update | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 0a7864c887 | #42084 | fix(web): a run finishing in a background window stays unread | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 47329274bc | #42062 | fix(client-runtime): local repository clone folders keep # and ? in their name | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 42068f543e | #42040 | fix(shared): a Markdown piece held open for a wrapper is cut before it passes 128 KB | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 2ced06ef4a | #42041 | fix(web): model picker search finds a model by its ID | skimmed: presentation logic with no wire change; for the UI agent of that area |
| c9e22e5ff4 | #41985 | fix(desktop): a WSL backend counts as ready only when it answers as this launch | read: desktop bootstrap IPC, desktop only |
| bb0862ead4 | #41983 | fix(client): a long run of fence markers is read in one pass | skimmed: presentation logic with no wire change; for the UI agent of that area |
| bba3918e3c | #41979 | fix(server): saving project scripts requires task operation scope | cited |
| 74c6d21c7a | #41672 | fix(web): the update dialog says why a server was skipped | read: wrong-environment error text; already in the audit section 5 |
| ff6b10e0a0 | #41928 | feat: starting providers show their real startup step and logo | cited |
| d0689976cd | #39662 | feat(scripts): add a bench script so .bench.ts files actually run | read: build script only |
| 72e7e8b044 | #32017 | fix: multi-select questions can be answered with nothing checked | read: a multi-select question may be answered with an empty list; for the composer questions UI agent |
| 9331811180 | #41885 | fix(clients): threads can be dragged above threads from a disconnected machine | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 637cd28599 | #41845 | fix(client-runtime): Remove is no longer offered on a route the environment cannot lose | read: a route can be removed only when another stays; already in the audit section 5 |
| 14ea095b0a | #41663 | feat(web): add an HTML preview width setting separate from chat width | cited |
| aab127d7fb | #41862 | fix(shared): repository keys for one-segment URL remotes name only the repository | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 4162207ddd | #29771 | fix(web): file menu opens remote files over SSH instead of on the server | read: desktop IPC for SSH files, desktop only |
| 69d8f4217f | #41809 | feat: auto-merge a stack through GitHub's includeStack | cited |
| d572ce9afe | #41814 | fix(chat): preserve model choices when editing queued messages | cited |
| 700a4644a4 | #30688 | fix(provider-core): agent sessions no longer inherit the AppImage runtime env | skimmed: server, CLI or desktop only |
| e3b79cd0bf | #41767 | fix: Windows system tools run by absolute path, and mobile links and shares are handled more strictly | skimmed: server, CLI or desktop only |
| 46f360d8dd | #41722 | fix(client): a link to a newly linked machine's thread opens without a reload | read: peerLinks.names reread when a wanted machine is missing; for the linked threads UI agent with PeerLinkRPC.names |
| 78cffe29ec | #41761 | fix: a merge or review stays on the commit you opened the pull request on | cited |
| 5e62206e7d | #41757 | fix(desktop): preview pages run in their own JavaScript world and popups open web links only | read: desktop preview IPC, desktop only |
| f30874fef7 | #41756 | fix: remote logins and webhook tokens stay with their own host and reader | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 2dd323463a | #41747 | fix(server): API request bodies have a 1 MiB default limit and tag scans stay linear | cited |
| 7dd35d324d | #41742 | fix(server): link codes and guest links require the access they hand out | cited |
| 0d6fe2141a | #41746 | fix(server): mode limits follow the turn a message joins | cited |
| b654fc27ba | #41730 | fix(server): automatic port selection checks the address the server binds | skimmed: server, CLI or desktop only |
| d4d08aed56 | #41745 | fix: XML assets open sandboxed and MCP apps bind to their document | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 44f0a5858e | #41731 | fix(client-runtime): a leading env-setup eval no longer hides the command label | skimmed: presentation logic with no wire change; for the UI agent of that area |
| b718326b88 | #41342 | fix(shared): preserve literal ampersands in composer file links | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 1c6d41a9ba | #41317 | feat(web,mobile): remove the changed-files card under assistant turns | cited |
| 4328d9c95c | #41609 | fix(mobile): untitled subagent rows no longer end in a broken character | skimmed: mobile only |
| 4ab87289ac | #41552 | fix(server): recover dropped T3 MCP tool results in ACP and OpenCode Code Mode | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 1002934541 | #41596 | fix(shared): Markdown previews keep a long <details> or <table> in one piece | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 550c26635b | #41610 | fix(web): SSH projects open in a new VS Code window | cited |
| 0ea0db39e2 | #41561 | fix(shared): PascalCase test doubles like MockTransport.ts count as mocks | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 7182abeeaa | #41550 | fix(client-runtime): command failures show the server's text for string defects | read: string defects show their text; CandyWrapper already shows a defect's text |
| fd0331ca9b | #41488 | fix(client-runtime): a workflow reply with no space before the limit is cut at the limit | skimmed: workflow display helper (client-runtime workflows.ts); for the workflows UI agent |
| 8f724d6329 | #41393 | fix: treat empty PATH entries as the working directory in launcher and CLI lookups | skimmed: server, CLI or desktop only |
| e6e863c045 | #38212 | fix(shared): Open in Cursor skips a broken cursor on PATH | skimmed: server, CLI or desktop only |
| 0a0389e517 | #41411 | fix(server): Codex async alerts keep their delivery marker in the thread API | cited |
| 2a7980308e | #28106 | fix(shared): search cwd for empty POSIX PATH components | skimmed: server, CLI or desktop only |
| 3b3255ccec | #41307 | fix(server): queued messages stay visible when a restart cancels their started run | read: timeline visibility for queued runs a restart cancelled, test change only on the client side |
| 0d2d6a0233 | #41270 | fix(shared): composer file links to names with # ? & ' , % ! ~ open after sending | skimmed: presentation logic with no wire change; for the UI agent of that area |
| f00893a512 | #41274 | fix(server): branch names keep leading and trailing Unicode whitespace | cited |
| ba588ef663 | #24034 | fix(web): match macOS Option shortcuts to the active keyboard layout | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 611410683b | #41242 | feat(cursor): show which step Cursor is in while a turn starts | cited |
| df93cabbcc | #41236 | fix(contracts): ForwardCompatibleOptional drops the key for values it cannot read | read: ForwardCompatibleOptional now drops an unreadable key on the server's side; nothing to port, CandyWrapper decoders already ignore unknown values |
| 3c84f4b1c4 | #41171 | fix(ssh): accept Node versions with build metadata | skimmed: server, CLI or desktop only |
| 6cfc3bf0d5 | #41231 | fix(shared): reject keybindings with a dangling or extra '+' | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 86349553c5 | #41168 | fix(server): app links no longer leave the preview stuck loading | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 1a4932efd0 | #25537 | perf(client): skip child indexing when no child needs input | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 69c1d53826 | #38884 | feat: workflows on web and mobile | cited |
| e414cfd4be | #38882 | feat(server): durable workflows | cited |
| 0591d32888 | #39179 | feat(issues): connect more than one Linear account | cited |
| fb23f12f1f | #40774 | feat(server): outside agents poll and stream milestones as MCP events | cited |
| fb4558d77d | #40631 | fix(web,mobile,server): large files load in full without freezing the file preview | cited |
| 44979a5875 | #41084 | fix(mcp): keep deleted schedules from returning on edit | cited |
| c89ca0a2f2 | #41052 | fix(server): a worktree thread moved to the project checkout no longer holds new messages | read: orchestrationV2WorktreePending needs startedAt null; CandyWrapper's side chat check is not a port of it (SideChatController.swift:85), nothing to change |
| fe9c98c98f | #35871 | feat: agents can report T3 Code problems when you turn feedback on | cited |
| e213da2a32 | #41037 | fix(client-runtime): refresh stale server clock offset after host sleep | cited |
| f9fbb004ac | #29459 | feat(devices): double-tap Home opens the app switcher | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 67f17528f2 | #39494 | fix(web): snooze labels follow the app language | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 55880c41b4 | #40986 | fix(client-runtime): count ambiguous projects in chat file links | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 5bd0616f05 | #41020 | fix: restart linked thread reads when trying again | cited |
| 28706aceb6 | #41005 | fix(server): unlinking an environment ends its session on the other machine | cited |
| 3806763022 | #40989 | fix(client-runtime): skip waiting for lower-priority linked addresses | cited |
| 9de4ec1bfa | #40924 | fix(web,mobile): @-file mentions show by name in message previews, not as raw links | skimmed: presentation logic with no wire change; for the UI agent of that area |
| b479ce21ed | #21667 | fix(client-runtime): stop sessions on incompatible server configuration | cited |
| a985332c44 | #27391 | fix(shared): Windows command discovery no longer blocks the event loop | skimmed: server, CLI or desktop only |
| d5497d66cc | #27401 | fix(client-runtime): a resumed thread renders its catch-up once instead of stepping through stale states | read: client-runtime stream plumbing so a resumed thread renders its catch-up once; CandyWrapper's reducer already applies a catch-up batch at once |
| a35b3ca9f0 | #40806 | fix(contracts): delegate_task options example says ids differ by provider | read: MCP tool description text only |
| 671e05bc8c | #40768 | fix(issues): an Activity cross-reference opens the issue or pull request it came from | cited |
| 997103be46 | #40781 | fix(shared): find file links whose labels contain brackets | skimmed: presentation logic with no wire change; for the UI agent of that area |
| c3a330d834 | #40767 | fix(web): show Queue for running sessions that cannot steer | read (subject and stat): Queue shows for a running session that cannot steer; composer UI |
| e3f9db2447 | #40741 | fix(server): TanStack Source pull requests open from every client, and private ones work end to end | cited |
| 6f49071a3d | #40745 | fix: a failed checkpoint capture keeps Edit from here for conversation rewind | read (subject and stat): rewind keeps Edit from here after a failed checkpoint capture; UI |
| 11224f63d2 | #40703 | fix(client-runtime): a new thread's first message and a queued send-now or steer survive a dropped socket | cited |
| 4ac5e6e791 | #40682 | fix(client-runtime): typing a bare Windows drive lists its folders | skimmed: server, CLI or desktop only |
| 0fb6ac6e65 | #27866 | perf(web): Markdown renders with Words as static islands under one shared tooltip; remark leaves the web app | skimmed: presentation logic with no wire change; for the UI agent of that area |
| c5fa33b27e | #40670 | fix(server,cursor): preserve inline handoff when a failed Cursor turn drops its prompt | cited |
| 15d945faef | #40637 | fix(server): reveal no longer opens Explorer's default folder for a missing file | cited |
| 5028eb10a4 | #40634 | perf(shared): Windows command lookups reuse PATH listings across requests | skimmed: server, CLI or desktop only |
| 10586f9e31 | #40594 | feat: read feature flags from one T3CODE_FEATURE_FLAGS service | cited |
| a480167e0c | #40592 | perf(issues): reuse repository bindings when classifying markdown links | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 87ba8987aa | #40567 | fix(server): a thread named before its first message keeps its name | read: thread.create takes titleRenamed (A8); CandyWrapper names a thread at create only through the title, so nothing to send yet |
| fd4284d8b2 | #40556 | fix(vcs): refresh branch pickers after external worktree changes | read: the branch picker refresh sends localOnly: true; CandyWrapper keeps the full refresh (GitController.swift:711) |
| da57ea2bf9 | #40538 | fix(mobile): push clean default branches without a new commit | skimmed: mobile only |
| 464e8f7e60 | #40545 | fix: keep paged linked thread history when reopening the same snapshot | cited |
| c3fb01dc05 | #40520 | fix(server): preview snapshots no longer report an empty interactiveElements list | cited |
| ba4f99ae43 | #40481 | fix(web,mobile): Limits shows why a provider's limits are unavailable | skimmed: usage and limits copy or math; for the Limits UI agent |
| e452042db8 | #40490 | fix(contracts): older clients drop unknown values in RPC responses | read: server-side forward-compatible arrays for old web clients; no change for CandyWrapper |
| 1ffa099e7f | #40464 | fix(shared): file links whose title holds the other quote keep their folder labels | skimmed: presentation logic with no wire change; for the UI agent of that area |
| e2fdfd2c31 | #40452 | perf(client-runtime): opening the branch picker keeps the branch list when no ref moved | read: the branch picker's refresh also keeps refs on an unchanged refsDigest; CandyWrapper's picker goes through the same refresh, ported with A15 (3729c8b8) |
| ac0032742b | #37154 | fix(shell): non-ASCII Windows PATH entries survive the PowerShell environment probe | skimmed: server, CLI or desktop only |
| 3bf21c037d | #40418 | fix(acp): Devin's terminal commands run under Git Bash on Windows, not cmd.exe | skimmed: server, CLI or desktop only |
| 1458a42419 | #40424 | fix(server): transcript cleanup failures tell the user why | cited |
| e337cee952 | #40385 | perf(client-runtime): Git menu status refresh keeps the branch list when no ref moved | cited |
| d57b83d85e | #40376 | perf(server): branch list reloads run 6 git processes instead of 9 | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 08804b2170 | #40373 | fix(server): a queued message that names no model runs on the thread's current pick | read: comment change; the server picks the thread's model for a queued message with none |
| c385377544 | #40316 | fix(server): slash commands sent during a turn wait instead of steering | read (subject and stat): slash commands sent during a turn wait; composer rule for the composer UI agent |
| 7ef7ba0e3b | #40304 | perf(server): a tracked file's Diff panel patch skips the untracked-file listing | read: review.getDiffFileContents takes an optional changeType; CandyWrapper omits it, which costs the server one untracked listing per patch. Port with the Diff panel |
| 0fd4822887 | #40216 | fix(server): per-file diff reads reuse the preview's merge base | cited |
| d51d8c4766 | #40217 | fix(client-runtime): opening the Diff panel reads each file patch once | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 511447a9f2 | #40207 | feat(server): add a TanStack Source forge and issue tracker behind T3CODE_TANSTACK_SOURCE | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 67933a2236 | #40211 | perf(server): complete Changes preview reuses its tracked-only pass | cited |
| 9f9ebf61fb | #40136 | fix(client-runtime): recognize thought_level and role: reasoning in effort summaries | skimmed: presentation logic with no wire change; for the UI agent of that area |
| d9fdd02523 | #40191 | fix(client-runtime): @ menu offers machines the thread's server links to | skimmed: presentation logic with no wire change; for the UI agent of that area |
| dcd8df806d | #36939 | fix(web): hub accounts whose usage read fails no longer vanish silently | skimmed: usage and limits copy or math; for the Limits UI agent |
| cf94598281 | #39966 | fix(client-runtime): don't ask for a provider update the install channel lacks | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 60863edc41 | #35925 | feat(projects): a project covers several repositories | cited |
| e97e360cfc | #39967 | fix(web): Option + a letter records the letter, not the macOS glyph | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 39480b5c88 | #27333 | fix(opencode): custom models can go back to the default reasoning level | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 73e6472545 | #24583 | fix(client-runtime): recover thread messages after a failed resume | read: a resumed replay that dies forces a full snapshot next time. CandyWrapper decodes unknown events instead of dying, so it matters only for a malformed frame. Open, not ported |
| ed3b241eaa | #40133 | fix(server): signed URLs are logged and traced with the token redacted | read: server log redaction only |
| c5dc20f9f5 | #37191 | fix(client): new threads from a grouped repository start in its root checkout | skimmed: presentation logic with no wire change; for the UI agent of that area |
| b568fcbaa6 | #40023 | feat(issues): a project can list issues from several Linear teams | cited |
| e28b2819ee | #39610 | fix(shared): compose NFD file names in link chips and the @ menu | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 6f644f6e91 | #40036 | feat: link a machine through another environment that already links to it | cited |
| c436409da0 | #30778 | fix: proxied usage limits follow the hub's model routing and show on the thread card | read: usage limit accounts gain models; CandyWrapper ignores the key. For the Limits UI |
| 285558eb10 | #34027 | feat(desktop): dictate on this Mac with Apple Speech | cited |
| 669d8941e2 | #39921 | feat: sign in to an agent's MCP server from its warning | cited |
| 3027c2c840 | #40011 | fix(voice): start dictation capture sooner on iOS and desktop | skimmed: mobile only |
| 2770bf3c61 | #38874 | feat(server): a thread turn can return a typed result | cited |
| d20e6c294c | #39884 | fix(speech): project name hints no longer recase ordinary words | cited |
| ccabed086a | #39445 | feat(web): the environments page is a map of your machines | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 2713570406 | #38506 | fix(desktop): update checks say why a build with a different saved track offers nothing | cited |
| 7c6e889ddb | #39515 | feat: subagents, side chats and linked threads open the same way | cited |
| d7f6b3efca | #39439 | feat: connect to a linked environment from its read-only thread | cited |
| 1cb3a8c753 | #39406 | feat: read a linked environment's threads from the client | cited |
| 9294a9801e | #39837 | fix(acp,web): stop showing "Running Ran" for commandless ACP tool calls | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 0bc9b57b93 | #31257 | feat: secret cards get a show/hide toggle and multi-value fields | cited |
| 898c22f990 | #39639 | fix(scheduled-tasks): clearing a task's thread no longer keeps the old one | cited |
| e6d521012d | #39596 | fix(server): a PR watch tells the agent when the checks finish after a failure | read: comment on the PR watch flag, server only |
| b5453de6b5 | #38348 | fix(cursor): background commands survive the turn and wake the agent when they exit | cited |
| 20b8a9e695 | #39497 | fix(web): the preview only embeds PDFs from its own environment | skimmed: presentation logic with no wire change; for the UI agent of that area |
| aa685426e7 | #39482 | fix(relay): refuse to relink an active environment under a different key | cited |
| 9bb92a46dd | #39501 | fix(shared): count each pending subagent thread once | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 8e8ff9b243 | #39426 | feat: link several environments at once | cited |
| 3a60d0996a | #38869 | fix(server): background subagents can delegate after their parent's turn ends | skimmed: presentation logic with no wire change; for the UI agent of that area |
| c79f618bf8 | #39159 | feat(issues): a fork lists its upstream's issues and its own | cited |
| bb1a66a3a4 | #38323 | feat(web): reference a side chat from its main thread with Add to chat and @ | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 9fde959ac0 | #38799 | feat(web): choose which projects the issues list shows | cited |
| 003d53ace1 | #39431 | fix(client-runtime): connection supervisor restarts its background listeners after a defect | cited |
| 5872b0a488 | #37419 | fix(web): a later thread error with the same text shows its banner again | cited |
| 38bac7091a | #39420 | fix(client-runtime): an unexpected failure no longer stops the reconnect loop for good | cited |
| dcf158c591 | #39415 | feat(server): setting and managed policy to turn off the preview tunnel | cited |
| 420d1b5900 | #39393 | feat(desktop): forward another environment's ports to this machine | cited |
| 210996207d | #26760 | feat(mobile): pull request files follow the same review order as web | skimmed: mobile only |
| babc83baf1 | #39315 | fix(web): PR viewer renders GitHub :emoji: shortcodes | skimmed: presentation logic with no wire change; for the UI agent of that area |
| b0b2c4f952 | #39306 | fix(server): agents can tell another agent's message from the user's | read: server adds a sender note to agent-sent prompts; nothing for a client |
| b5481adcd8 | #32841 | fix(web,mobile): scheduled tasks from Settings start from the project's default branch | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 3b199e77fb | #39308 | fix: index displayed file line ranges in thread search | cited |
| c3e82a93fe | #26040 | fix(shared): T3 Connect no longer runs cloudflared releases that trust the compromised eMudhra intermediates | skimmed: server, CLI or desktop only |
| eb62a37150 | #24310 | fix(shared): atomic saves preserve file modes and sync to disk | skimmed: server, CLI or desktop only |
| 314a11498e | #24642 | fix(web): preserve Connect environments on unreachable auth at launch | cited |
| 73caab68e3 | #38912 | fix(client): commands run as Effects on the caller's fiber, so interrupting a caller stops them | cited |
| 1d3932570c | #39296 | fix(themes): keep escaped quotes in CSS text | skimmed: presentation logic with no wire change; for the UI agent of that area |
| a4d0151700 | #39290 | fix: match dotted capital I in Find in Thread | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 3c08684f1d | #35343 | fix(client-runtime): CamelCase account names get distinct badge initials | skimmed: presentation logic with no wire change; for the UI agent of that area |
| ff4197c480 | #25519 | perf(client-runtime): skip history scans when no runs are queued | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 3b4041a97a | #39217 | fix(shared): theme CSS saves with escaped quotes and quoted comment markers | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 78d74598d4 | #39229 | fix(client-runtime): hide Resume where the provider cannot continue a stopped run | cited |
| 2526691ea5 | #39157 | fix(mobile): cancelling a model download keeps the current transcription model | cited |
| da33a53d18 | #39116 | fix(server): wake when CI fails during the PR watch baseline read | cited |
| 7e004b80e2 | #39142 | fix(client-runtime): a chat file link opens a file that overlapping projects both list | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 1a42ba1b5f | #39114 | fix(server,web): models stay in the picker after one failed provider check | cited |
| d067a04175 | #39130 | fix(web): a slow chat file link no longer replaces a file opened from the picker | skimmed: presentation logic with no wire change; for the UI agent of that area |
| 0317d4f4e5 | #39109 | fix(mobile): Arabic paragraphs that open with an English word render right to left | skimmed: mobile only |
| bc6621d73a | #39068 | fix(server): Windows backend refuses projects on a WSL share | skimmed: server, CLI or desktop only |
| aced664ed9 | #39024 | fix(client-runtime): prefer newer completed compaction over stale liveUsage | skimmed: usage and limits copy or math; for the Limits UI agent |
| c9359f6535 | #38984 | fix(mobile): project picker starts a chat in an open copy, not an archived one | skimmed: mobile only |
