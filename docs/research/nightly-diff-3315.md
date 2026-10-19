# T3 Code Nightly: 3234 to 3315

Range: v0.1.1-nightly.20261017.3234 .. v0.1.1-nightly.20261018.3315, 385 commits, 780 files. Target commit 9c161462c9. Line numbers refer to the 3315 tree. "CW" is CandyWrapper.

Most of the range is web plumbing. 273 perf and 49 refactor commits move components onto the React Compiler and remove manual memoization, and 18 test commits move web tests into a real browser. A comparison of every string literal in `apps/web/src` before and after found no new or changed user-facing text outside the items below. The rest are moves into `RightPanelSurfaceContent.tsx`, `ChatOverlayHosts.tsx` and `packages/client-runtime`. The tooltip rewrite (#20448) only replaces a shared ref with a tracker object.

## 1. Wire changes

### Breaks

1. `vcs.createWorktree` now requires `path: null`, so clients can no longer pick the folder (packages/contracts/src/rpc.ts:1383-1390, #20449 8e0d5e5e4d). CW never calls it. The server makes worktrees when a thread starts.
2. `projects.writeFile` refuses a `cwd` that isn't a registered project root, a managed worktree or a thread worktree that `git worktree list` knows (apps/server/src/workspace/KnownWorkspaces.ts:143, WorkspaceFileSystem.ts:470). ws.ts:519-521 maps the refusal to failure `workspace_path_outside_root`. Writes into `.git` and through escaping symlinks are refused too. CW's two writers pass the thread worktree or the project root (App/Sources/FilesController.swift:492, App/Sources/ThreadSession.swift:615), so normal saves keep working. A refused save shows the server's message, as T3's does (RPCClientError.description, T3 ProposedPlanCard.tsx:150-156). Reads, listings and searches are unchanged.

### Changed defaults

3. `AuthStandardClientScopes` gains `access:read`, `access:write` and `relay:write` (auth.ts:148-169 in packages/contracts/src, #20432 19108aa7b4), and `AuthAdministrativeScopes` is gone. Pairing links, the desktop bootstrap and CLI-issued sessions all default to the 16 scopes. CW: `AuthScopes.standard` (T3Protocol/Wire/HostAccess.swift) matches, so the Create pairing link dialog's default and its Standard preset grant access and T3 Connect management, filtered by what the session may delegate (ConnectionsSettings.tsx:1023-1026, 1151).
4. `isSecretSetting` now counts every `providerSettingsForm` password control (settings.ts:529-535, #20446 8653c8f09b). OpenCode's `serverPassword` (provider-opencode/src/settings.ts:42-52) and GitCafe's token leave the settings file and reach clients as "••••••" (apps/server/src/settingsSecrets.ts:22). Writing the mask back keeps the saved value. CW marks `serverPassword` redacted (Features/Settings/ProvidersSettingsView.swift), so it shows "Stored secret, enter a new value to replace" instead of six dots in the field. CW has no GitCafe settings.

### Additions

5. Keybinding commands `composer.increaseEffort` and `composer.decreaseEffort`, unbound by default (keybindings.ts:96-97). See part 2.
6. Pending background tasks carry an optional `parentTaskId`, and subagent tasks an optional `providerInstanceId` (orchestrationV2.ts:799-826, #19750 and #19751). CW ignores unknown keys and shows neither.
7. `WorktreeMcpHandoffInput` drops `path` (worktreeMcp.ts). Agent-facing only.

### Server behavior with no client change

- A large database no longer blocks startup (#21122). CW still detects readiness with the descriptor poll.
- `t3 doctor` can delete the pre-0.1.0 database (#20948), and the server drops V1 projections nobody reads (#20947). CW calls neither, and the perf seed's legacy tables survive migration 63.
- Webhook runs wrap each request value in `<webhook-data-ID>` tags with a closing "untrusted data" note (apps/server/src/scheduledTasks/webhookTemplate.ts, #20447). T3 renders raw HTML as text (ChatMarkdown.tsx:3372), and so does CW (`MarkdownTests.webhookDataTagsStayText`).
- A running Claude workflow member's answer so far arrives as a growing assistant message in its child thread (#20786). CW updates it like any streaming message.

## 2. Visible changes

- [x] The table expand button shows only when a cell is clipped in the unwrapped layout (#19782, ChatMarkdown.tsx:540-590, 663-682). CW: Features/Markdown/MarkdownLayout.swift. The narrow-table reference in `design/component-reference/markdown` lost its button.
- [x] Clear button beside a saved provider secret (#20446, ProviderSettingsForm.tsx:414-435). CW: `SecretFieldControl` in Features/Settings/ProviderEnvironmentViews.swift, shared with the environment variable field, which now also uses T3's "Stored secret, enter a new value to replace".
- [x] Reasoning rows skip the tool failure scan, so "exit code 2 is expected" in a thought no longer marks it failed (#21146, packages/client-runtime/src/work-log/presentation.ts:368-371). CW: T3Store/WorkLog.swift.
- [x] Effort stepping from the keyboard (#19928, TraitsPicker.tsx `getReasoningTraitStep`, ChatComposer.tsx `stepReasoningEffort`, ChatView.tsx:5563-5568). CW: `ModelTraits.reasoningStep` (T3Store/ModelCatalog.swift), `ComposerPickers.stepEffort` and the handler in App/Sources/ComposerController.swift. Both commands are listed under Settings > Keybindings with no default keys. CW's effort picker has never read the provider-reported selection, so a step starts from the value the picker shows.
- [x] A snoozed thread wakes in the open chat at its wake time (#21019). CW arms one timer for the open thread's wake time (Features/Thread/ThreadLineageController.swift) and, as decided for the Woke pill (docs/decisions.md), the open thread counts as visited, so the footer clears where T3 shows "Woke from snooze".
- [x] Typed `draft:` qualifiers sync the pull request Draft menu, and qualifier lists split like T3's (#19934, packages/client-runtime/src/pullRequestQuery.ts).
- [ ] Relative time labels keep counting while shown: "· next" in thread automations, "· synced" on linked PRs, PR "opened" and "updated", the scheduled tasks list and the stash menu (#21026). CW's sidebar rows already tick, but these panels refresh on state pushes only.
- [ ] SSH environments reuse their session (#20445, packages/client-runtime/src/connection/resolver.ts:223-240, apps/web/src/connection/platform.ts:224-277). T3 keeps the first SSH bearer, starts the tunnel with `issuePairingToken: false`, checks the descriptor's environment id and the session's scopes, and pairs again only if they fail. CW pairs on every SSH connect (App/Sources/Environments.swift:215-217, 290-303), so each reconnect leaves another client session on the host. Needs an SSH host to test.

Already matching: Working threads drag into the composer as references (#19697), the settings search keeps its clamped highlight (#20764), a project action's error stays with its dialog (#20891), and each reconnect gets its own 2 s grace before the unavailable banner (#20441).

No CW counterpart: the agents pill (#20785) is mobile only, and the machine-switch fixes (#20519, #20442) and the sidebar crash (#20522) concern React state CW doesn't have.

## 3. Client performance

T3's perf work in this range is React-specific. The one rule that applies to CW is the reasoning scan above, which also saves CPU on long threads.

## 4. Method and validation

The release archive came from GitHub and matched SHA256SUMS. The 3315 sandbox ran on port 47395 with its own copy of the main sandbox home in CandyWrapper-research/sandbox-3315, and the main sandbox ran 3234 on 47391 for the compatibility checks. The live service stayed untouched. Three research passes read every fix and feature commit, the client-runtime and shared packages and the server changes a client can see. A comparison of every string literal in `apps/web/src` and the shared packages before and after found the user-visible changes. The rest moved code or removed memoization.

## 5. Review and remaining work

A Codex review (GPT-6-Astra, high effort) of the whole diff found one bug. Effort stepping read and restored the caret by serializing only the text before it, which treats a trailing horizontal rule as the end of the draft and drops its newline, so the caret jumped above the rule. `ComposerEditor.expandedCaret` now maps through the whole draft, and `ComposerRichTextBlockTypingTests.expandedCaretRoundTripsPastARule` fails on the old code. The review found the scopes, the secret masks, the clipping check, the qualifier split and the snooze timer correct. The timer holds no strong reference, never repeats and re-arms past 24 days.

The full suite ran 1,549 Swift Testing and 17 XCTest tests with no failures, with `LocalServerIntegrationTests` on the 3315 runtime and `SandboxIntegrationTests` against 3234. After the caret fix, 115 focused composer and effort tests passed.

On screen, an isolated debug build ran against 3315 in dark and light. It opened threads, sent one Haiku turn whose narrow table reply has no expand button while the wide table keeps it, toggled the sidebar quickly, and opened the command palette and Settings. Composer: Increase Effort, bound to Ctrl+Option+E, stepped Medium, High, Extra High, Max, Ultra, then wrapped to Low. An OpenCode instance with a dummy password showed the stored-secret placeholder and the Clear button. settings.json held only the mask, editing the server URL kept the password, and Clear removed it from the secret store. The instance was removed afterwards. Against 3234 one Haiku turn completed, and the composer shows T3's "Server update available" notice because that server is older than the client pin.

Performance (`docs/perf/2026-10-19-ada72ad-w1.md`, against a 3315 server): 195 ms to the first window, 0.044% idle CPU, 38.1 MB idle footprint and 392.5 ms of scroll CPU. Against the median of the last three saved runs, the review flagged one 54.7 ms stall in big-thread scrolling, one 53.8 ms stall in thread open, and slower Markdown streaming and sidebar micro-benchmarks. A same-hour A/B with the commit before this run (0d54636, results kept out of docs/perf) shows the same stalls, 55.4 and 53.0 ms, and the sidebar timings within 3%. Its Markdown layout and parse benchmarks were slower than this run's while its streaming deltas were faster, so those flags are noise. The stalls appear on both builds against 3315, and the earlier baselines ran against 3234.

Still open:

- Relative time labels that keep counting while shown (#21026).
- SSH session reuse (#20445). It changes how CW keeps SSH credentials and needs an SSH host to test.
- Nightly 3373 shipped while this catch-up ran: 394 commits after 3315. Its contracts diff is additive (browser search engine settings, workflow script messages, ended PR watches, terminal resume, a git `rootPath`), so the 3315 pin keeps working against it.
