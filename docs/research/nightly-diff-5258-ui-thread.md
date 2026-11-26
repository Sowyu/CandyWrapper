# T3 Code Nightly: 4928 to 5258, thread, composer, sidebar and command palette

Range: v0.1.11-nightly.20261119.4928 .. v0.1.13-nightly.20261125.5258, 192 commits touching `apps/web/src/components/{chat,sidebar,timeline}` or the `Chat*`, `Composer*`, `CommandPalette*`, `Sidebar*` and `Thread*` components. Settings, pull requests, files, git, terminal, browser, connections and workflows belong to the other note. The wire side is in [nightly-diff-5258-wire.md](nightly-diff-5258-wire.md), cited here as "wire B3" or "wire A6".

T3 paths are relative to apps/web/src unless they start with packages/, and line numbers refer to the 5258 tree. "CW" is CandyWrapper, with paths under Packages/CandyKit/Sources unless they start with App/.

The five changes a daily user sees first:

1. Sidebar rows show the thread's environment on the second line, and the worktree moves into the hover card (#40736).
2. The sidebar hides when you drag its edge below a threshold, and a hover handle on the screen edge drags it back (#29546).
3. The changed-files card under each assistant turn is gone (#41317).
4. Cmd+K lists the open thread's own actions: settle, pin, snooze, copy, archive and more (#40742).
5. A starting provider shows its real startup step and logo in the live row, for example "Starting Cursor MCP servers" (#41242, #41928).

## How to read this

CW already has most of the surfaces these commits touch, so the notes say what T3 changed and whether CW has the old or the new behavior. "CW: no" means a grep of Features and App/Sources for the T3 strings and type names found nothing. Nobody has run CW against a 5258 server yet, so "already" in the commit table would mean checked by reading CW code. I found no commit that CW already has in full, so no row says `already`. Partial matches are named in the note.

Sizes: small is under 20 minutes of agent work, medium is 30 to 90 minutes, large is 2 hours or more. "Default look: yes" means the default themes draw something different, so the fidelity references for that surface need recapturing from 5258 and the tests will fail until they are. `redesign` means the surface also needs a Redesign (Experimental) variant.

## 1. Thread and timeline

### 1.1 Linked threads open read-only (large, default look: yes, redesign)

A link to a thread on a machine your server is linked to now opens that thread inside this app, read-only, in the right pane, as a page, or as a side surface. Subagents, side chats and linked threads all open the same way (#39515). The pane reads history through the link (#39406) and offers "Connect to interact" when this device is not paired with that machine (#39439). A link to a newly linked machine opens without a reload (#41722). A link to a machine this app does not know shows a "Thread unavailable" page (#42048).

- Pane: components/chat/LinkedThreadPane.tsx:45-70 (the composer replacement), :91 (`via` label), :104-157 (connect states), :163-164 ("Open this thread on {label} to see this visual."), :174 ("Could not load earlier turns. Try again."), :186 ("Thread on {label}").
- Composer replacement: components/chat/ReadOnlyComposerBar.tsx:15 is `flex min-h-12 items-center gap-3 rounded-2xl py-2 ps-5 pe-2 text-sm`. LinkedThreadPane.tsx:52 draws an `EyeIcon` at `size-4 text-muted-foreground`, then the bold label "Read-only" in `font-medium text-foreground`, then the status line "On {label} via {via}" or "On {label} via {via} · Working" in `text-muted-foreground tabular-nums`. Below 560 px of composer width the status wraps under the label (`@max-[560px]/composer-surface:flex-col`) and below 320 px the button text hides (`@max-[320px]/composer-surface:sr-only`).
- Dialog copy: LinkedThreadPane.tsx:104 "Connected to {label}", :105 "This device is paired with it and can use its threads.", :115 "Connecting to {label}…", :122 "{label} is not reachable from this device", :132 "{label} needs a pairing code", :133 "Create one on it, then add it to this device as an environment.", :140 "Enter code", :149 "Connect to interact", :157 "Try again".
- Page: components/chat/LinkedThreadPage.tsx:49-59 (breadcrumb aria-label "Thread breadcrumb"), components/chat/ReadOnlyThreadTimeline.tsx:181 (lane insets zeroed with `[--chat-lane-inset-end:0px] [--chat-lane-inset-start:0px] [--chat-timeline-gutter:0px]`).
- Unavailable page: components/ThreadRouteView.tsx, `UnreachableEnvironmentState`: title "Thread unavailable", text "This thread is on an environment this app is not connected to.", button "Open Environments" to Settings, Environments.
- Link entry point: components/chat/MarkdownThreadLink.tsx:102 (`openLinkedThreadRead`). The Lineage panel also shows elapsed time for subagents on linked machines (#41798) and its show-more keeps the last row and the focus (#31295), at components/chat/ThreadRelationshipsControl.tsx:128.
- Gate: the server must offer `peerLinks.subscribeThread`, `threadHistoryPage` and `threadItem` (wire A6). A 4928 server has none of them, so hide the surface.
- CW: partly. Settings and pairing exist (`App/Sources/PeerLinkDialog.swift`, `Features/Settings/LinkedEnvironmentsViews.swift`, `T3Protocol/Domain/PeerLink.swift`). There is no read-only thread pane, no `ReadOnlyComposerBar` and no unavailable page. Touches `Features/Thread/ThreadPanelView.swift`, `Features/Thread/TimelineView.swift` and `Features/Markdown/MarkdownContextChips.swift`.
- Commits: 1cb3a8c753 #39406, d7f6b3efca #39439, 7c6e889ddb #39515, 46f360d8dd #41722, 74d73ac23f #42048, 7e6a871a00 #41798, d27d29fe2d #31295.

### 1.2 A starting provider shows its real step and logo (medium, default look: yes, redesign)

While a turn starts, the live row names the step: "Loading {provider} plugins", "Starting {provider} MCP servers", "Loading {provider} hooks", "Loading {provider} rules and skills", "Resuming {provider} session", "Connecting to {provider}", then "Starting {provider}" (packages/client-runtime/src/state/threadExecution.ts:119-134). With no provider name it says "Starting" (:153). The row's brain icon becomes the provider's own logo (`ProviderStartingIcon`, components/chat/ProviderStartingIcon.tsx:63), at 70 percent opacity while the row is not highlighted (components/chat/TimelineWorkGroupRows.tsx, `<span className={cn("flex", !highlighted && "opacity-70")}>`). Before the server has a run, a send shows the selected provider's starting row instead of the thinking brain (components/ChatView.tsx, `providerStartingRun`, built by `presentProviderStarting` at threadExecution.ts:142).

- Also: a parent that waits only on subagents no longer reads "Thinking" (#41927, components/chat/MessagesTimeline.logic.ts), see 1.9.
- Gate: `ProviderSession.startupPhase` and `startupPhaseThreadId` (wire A7). Without them the row says "Starting {provider}".
- CW: no (`providerStarting` and `startupPhase` have no hits). Touches `T3Store/TimelineEntries.swift`, `Features/Thread/TimelineView.swift` and the live-row view in `Features/Thread/`.
- Commits: 611410683b #41242, ff6b10e0a0 #41928.

### 1.3 The changed-files card under assistant turns is removed (small, default look: yes)

T3 deleted `ChangedFilesTree.tsx` (548 lines) and the `AssistantChangedFilesSection` under each assistant reply. The turn row ends at the reply and its actions. The Diff panel and the thread details card still list changed files. Mobile dropped it too.

- T3: components/chat/TimelineAssistantRows.tsx (the section and its `ctx.onOpenTurnDiff` call are gone), components/chat/MessagesTimeline.logic.ts (`assistantTurnDiffSummary` removed from the message row).
- CW: `Features/Thread/ChangedFilesCardView.swift` still draws it. Remove the call from the assistant row, keep the view if the Redesign look still uses it, and recapture the assistant-message references.
- Commit: 1c6d41a9ba #41317.

### 1.4 Secret cards: show/hide and several fields (medium, default look: yes, redesign)

The card has a show/hide eye per masked field, takes up to 8 named fields, and keeps the caret where it was when you toggle the eye. The save button reads "Save securely" and the other button "Decline". A reference answer needs `providers:manage` too (wire B3 has the contract and the fix).

- T3: components/chat/SecretRequestCard.tsx:191 (`flex min-w-0 flex-col gap-3 rounded-xl border border-border/60 bg-card p-4`), :205-214 (label `text-sm font-medium text-foreground`, reason `text-sm wrap-anywhere text-muted-foreground`), :218-231 (URL line, `font-mono text-xs wrap-anywhere text-muted-foreground`), :236 (inputs in `gap-2.5`), :287 (`ShieldCheckIcon` `size-3.5` note), :359 (`aria-label` "Show {label}"), :366 (`EyeOffIcon` or `EyeIcon`), :375 (field label `text-xs font-medium text-muted-foreground`), packages/client-runtime/src/secretRequest.ts.
- Caret: the toggle saves `selectionStart` and `selectionEnd` and restores them (#42309).
- CW: `Features/Thread/SecretRequestRowView.swift` and `T3Store/SecretRequests.swift` draw one field with no eye.
- Commits: 0bc9b57b93 #31257, eb7cc44727 #42309, 8dc01892ad #41886.

### 1.5 Agent feedback card (medium, default look: new row, redesign)

When the user turns agent feedback on, an agent can ask to send a problem report to the T3 team. A pending request shows a card with a switch for including the conversation, and "Don't send" and "Send" buttons. Settled requests collapse to a work-log row with a check, a dash or a lock icon.

- T3: components/chat/FeedbackRequestCard.tsx:33 (row title "Feedback for the T3 team"), :55 and :61 (settled row icons `size-3.5 text-icon-muted`), :124 (`flex min-w-0 flex-col gap-3 rounded-xl border border-border/60 bg-card p-4`), :127-129 (title `text-sm font-medium`, `MessageSquareIcon size-3.5`, "Send this report to the T3 team?"), :132 ("This is everything that leaves your machine. Nothing is sent unless you press Send."), :139 ("Include the conversation"), :160 ("Only someone who can run agents on this machine can send or decline it."), :171 "Don't send", :174 "Send", :186-190 (field list `grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm`), :201 (log list `max-h-80 overflow-y-auto font-mono text-xs`).
- Gate: Labs setting `agentFeedback.mode` (`off`, `on-request`, `auto`) and the capability `agentFeedback` (components/settings/LabsSettingsPanel.tsx:399-440, wire A4). Answering uses `agentFeedback.answerRequest`.
- CW: no. `App/Sources/PaletteCommands.swift` has "Triage an issue", which is a different feature.
- Commit: fe9c98c98f #35871.

### 1.6 MCP sign-in from a warning, and the Google verify link (medium, default look: yes, redesign)

A system notice about an MCP server that needs a login gets a "Sign in" button. It opens a dialog, "Sign in to {server}", that asks the user to approve in the browser, then paste the address of the page that failed to load. After sign-in the button turns into a quiet "Signed in". A failed Antigravity turn shows a "Verify Google account" outline button with an external-link icon.

- T3: components/chat/McpSignInAction.tsx:73 (toast "Signed in to {server}"), :110 "Signed in", :114 (aria-label "Sign in to {server}"), :121 "Sign in", :125-140 (dialog `max-w-lg`, text "Approve access in your browser. It then opens a page that may not load: copy that page's address and paste it here."), :143 "Starting the sign-in…", :162 "Open sign-in page", :166 "Copy link", :170 "Address of the page your browser opened", :192 "Cancel", :196 "Try again", :206 "Finish sign-in". It is mounted at components/chat/TimelineWorkEntryRow.tsx:459. The Google link is at TimelineWorkEntryRow.tsx:404 (`ms-7 pb-1`, `Button size="xs" variant="outline"`, label "Verify Google account", `ExternalLinkIcon`).
- Row notices now expand only when cut off, and row actions keep their place on hover (#40076): `noticeCutOff` at TimelineWorkEntryRow.tsx:316 compares `scrollWidth` with `clientWidth`.
- Gate: `provider.mcpSignIn.start` and `.complete`, scope `providers:manage`, and `system_notice.mcpSignIn` (wire A5).
- CW: no.
- Commits: 669d8941e2 #39921, 3e74a0aac5 #41210, 26d81d88c1 #40076.

### 1.7 Approvals say what they approve (small, default look: small)

A push approval lists the branch and the hooks that will run, in a `dl` under the question (`grid min-w-0 grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-xs text-muted-foreground`, components/chat/PushHooksApprovalDetails.tsx:6). Agents below Full access now ask before a push runs repository hooks (a server rule). The composer offers the runtime modes any model in a multi-model send supports (`draftSupportedRuntimeModes`, components/chat/runtimeModeConfig.ts:58). Hosted pairing shows what is approved (that part is the other note's).

- CW: no for the details block. `Features/Thread/` approval row and `Features/Composer/ComposerLogic.swift` are the files.
- Commits: c4d0e05d96 #42535, eecb58c6d6 #41769.

### 1.8 Thread details card (medium, default look: yes)

- Usage limits follow the hub's model routing and show on the card (#30778): `resolveThreadDetailsLimits` at components/chat/ThreadDetailsUsage.logic.ts:26 returns an `instance` or a `pool` result. User-hosted HTTP quota sources show their accounts for the thread's provider instance (#41291, wire A11). Antigravity limits no longer come from Google's internal APIs (#43026).
- "Show N more" and "Show less" use one ghost button, `ThreadDetailsMoreButton`, `w-full active:scale-100`, with `ChevronDownIcon` or `ChevronUpIcon` at `size-4` (components/chat/ThreadDetailsControl.tsx:133). Extra linked issues collapse behind it (#39232). Expanding them no longer hides the other sections (#42771): the first link renders, the rest sit behind the toggle (components/chat/ThreadDetailsIssueRows.tsx:173). Show more keeps every repository listed (#42919): sections past `THREAD_REPOSITORY_SECTIONS_VISIBLE` get `data-thread-details-repository-overflow` (components/chat/ThreadRepositorySections.tsx:5).
- CW: `Features/Git/ThreadDetailsCardView.swift` and `Features/Thread/ThreadContextWindowMeterView.swift` have the card. No pool limits, no "Show less" toggle for issues.
- Commits: c436409da0 #30778, 16742ca802 #41291, 96423cb5e2 #43026, b111b6310a #39232, 3a63e0ca37 #42771, 67918f51cc #42919.

### 1.9 Run state rules, banners and recovery (medium, default look: small)

- The Thinking row does not show below a streaming reply (#41060): `replyIsStreaming`, components/chat/MessagesTimeline.logic.ts:2376.
- A parent parked on subagents does not read "Thinking" (#41927), and background subagents can delegate after the parent's turn ends (#38869, packages/shared/src/orchestrationV2PendingBackgroundWork.ts).
- Tool calls stay grouped after a usage-limit pause (#40905): `usageLimitRunId`, MessagesTimeline.logic.ts:1049.
- Commandless ACP tool calls no longer say "Running Ran" (#39837).
- The usage-limit banner updates its copy after the reset time passes (#39889): `limitRecoveryScheduleState`, components/chat/UsageLimitRecoveryBanner.tsx:48, with `resetPassed` and `displayPassed`.
- A later thread error with the same text shows its banner again, and dismissing a local error no longer hides repeats (#37419, #40042): the dismissal key is `threadKey NUL source NUL error` (components/chat/ThreadErrorBanner.tsx:54, components/ChatView.logic.ts:1263).
- Composer banner actions sit at `self-center` (#41803).
- A failed resume recovers thread messages and the composer sync line shows the error (#24583).
- CW: partly. `Features/Composer/ThreadErrorBannerView.swift`, `T3Store/TimelineEntries.swift`, `T3Store/UsageLimits.swift` and `Features/Composer/ComposerNoticeBannerView.swift` exist. The error key and the reset-passed copy are new.
- Commits: 0938476b95 #41060, a6c69be8df #41927, 3a60d0996a #38869, 7ddc81d639 #40905, 9294a9801e #39837, 8d37736cdd #39889, 5872b0a488 #37419, aa6fe390db #40042, c5918e5d24 #41803, 73e6472545 #24583.

### 1.10 Reading position, open at the end, minimap and floating preview (medium, default look: no)

- Resizing a side panel keeps your reading position (#41184): `preserveReadingPosition` (lib/preserveReadingPosition.ts, used at components/chat/MessagesTimeline.tsx:30). It stands down while live follow, anchored end space, find, citation positioning or thread-position restore is active.
- A thread opens at its end instead of jumping there (#41843): the restore case no longer needs `rememberedPosition.atEnd === false`.
- The timeline minimap no longer covers the Copy button when the chat lane shifts left (#42876): the gutter is now the measured lane offset, not the viewport minus content width. The hit strip takes `{ left, width }` and the minimap overlay starts at `top-[calc(-1*var(--chat-header-height,0px))]`.
- The floating preview no longer covers the last rows on a narrow chat (#42286): `resolveTimelineEndInset`, MessagesTimeline.tsx:172, adds the preview's height to the bottom inset when it sits in the lower half.
- Reasoning previews and minimap previews no longer cut an emoji in half (#42755, #42575): they slice at 1,500 characters and step back one when that splits a surrogate pair.
- CW: partly. `Features/Thread/ThreadMinimapView.swift` and `Features/Thread/TimelineView.swift` exist. No reading-position hold.
- Commits: e6ae5810a3 #41184, 4508c70681 #41843, 172309c39c #42876, 41675b3e4d #42286, f99eceb76d #42755, 6667f3c089 #42575.

### 1.11 Images and media in the thread (small, default look: small)

A running Read of an image shows a loading frame, not "Image unavailable" (#42921). The loading and the unavailable frame stay the 16:9 strip bounded at `min(100%, 30rem, {maxHeightRem*16/9}rem)` (components/chat/ChatMarkdownMedia.tsx:92, `unsizedImageFrameStyle`). Failed and in-progress reads drop out of the viewed-image previews (#42265). The expanded image dialog closes with an `XIcon` icon button at the top end, no Back button: aria-label "Close image preview" or "Close video preview" (components/chat/ExpandedImageDialog.tsx:201).

- CW: `Features/Thread/ThreadImageGalleryView.swift` and `Features/Markdown/MarkdownMedia.swift` draw the old Back button and the "Image unavailable" frame.
- Commits: cbc3057f59 #42921, 36ecdeb851 #41597, ff7d03ddfd #42265, 6f6b978667 #41963.

### 1.12 Markdown copy, find and file links (medium, default look: small)

- A chat table copies as HTML from the table menu, "Copy as HTML", next to Markdown and CSV (components/chat/MarkdownTable.tsx:81, markdown-clipboard.ts). It puts `text/html` on the pasteboard with a `<meta charset="utf-8">` prefix.
- Copying items within one list keeps their markers and task checkboxes (#39150, markdown-clipboard.ts:17).
- Thread find indexes displayed file line ranges (#39308) and scrolls wide tables and code to the selected match (#39295, components/chat/useThreadFindNavigation.ts:7).
- File links: home paths such as `~/.claude/CLAUDE.md` no longer show under the workspace folder (#39146, `isHostPath`), file names compose to NFC (#39610), ambiguous projects count (#40986), a PR description's links resolve in the PR's repository from a No-project thread (#41073), and a slow link lookup no longer replaces a file you opened from the picker (#39130).
- CW: partly. `Features/Markdown/MarkdownView.swift` and `Features/Markdown/MarkdownLayout.swift` have table copy for Markdown and CSV. `Features/Markdown/FileLinks.swift` and `Features/Markdown/ThreadFindText.swift` are the link and find files.
- Commits: b9879ede83 #33286, ff9efe89f6 #39150, 3b199e77fb #39308, 5bc2d512e4 #39295, b6afe8109c #39146, d067a04175 #39130, 55880c41b4 #40986, 7103527dcc #41073.

### 1.13 Search tool results show the matched lines (medium, default look: yes)

A Grep or search tool item opens a result list with the matched lines under each file, highlighted. Highlights cap at 20 per line and skip lines over 1,000 characters. A pattern is only used as a regex when it passes a backtracking check: at most one quantifier, at most three alternations and no quantified group.

- T3: components/chat/FileSearchResults.tsx (new, 134 lines, `MAX_HIGHLIGHTS_PER_LINE`, `MAX_HIGHLIGHTED_LINE_CHARS`, `backtracksSafely`), components/chat/V2ItemInspector.tsx:34, packages/shared/src/grepOutput.ts (new, 82 lines). Web search result links follow Open links in (#42882): `WebSearchResultLink`, V2ItemInspector.tsx:206.
- CW: no (`FileSearchResults` and `matched lines` have no hits). Touches the work-log item inspector in `Features/Thread/`.
- Commits: dfa73216cc #42429, e045a127e7 #42882.

### 1.14 Thread chips show the sidebar's thread card on hover (small, default look: yes, redesign)

Hovering a thread chip in the composer or a sent message opens the same hover card the sidebar uses, with the project and its favicon, the branch, the provider and model, and pull requests. A chip for a thread on another machine adds a warning line, "On another machine, so this machine's agent can't read it. Remove it or switch back to send."

- T3: components/ThreadChipHoverCard.tsx:22 (the `unreadable` line is `flex min-w-0 items-start gap-2 text-warning`, icon `CircleAlertIcon mt-0.5 size-3 shrink-0`), :44-50 (rows `flex min-w-0 items-center gap-2`, icons `size-3 shrink-0 stroke-muted-foreground`, text `text-foreground/75`), footer `border-t border-border/60 pt-2 pl-0.5 text-xs text-muted-foreground`. components/ThreadContextChip.tsx:15 uses `ThreadHoverCardPopup side="top"` in place of the old "Open thread" tooltip.
- The sidebar card itself changes in 3.2.
- CW: partly. `Features/Sidebar/SidebarThreadHoverCard.swift` is the card. `Features/Markdown/MarkdownContextChips.swift` draws chips with the old tooltip.
- Commit: bac0508e08 #38895.

### 1.15 Side chats and citations (small, default look: no)

- Cmd+F searches a side chat and Escape closes it (#28919), and a side chat can be referenced from its main thread with Add to chat and @ (#38323, components/chat/SideChatPane.tsx).
- A citation comment box stays open when its cited row scrolls out (#42603), clicking outside keeps its dictation (#42856), and the Cite button appears as fast after a double-click as after a drag (#33221, `immediateMultiClick`, lib/selectionActions.ts).
- CW: partly. `App/Sources/SideChatController.swift` and `Features/Markdown/AssistantSelectionToolbar.swift` exist. I did not check whether CW has a citation comment editor.
- Commits: 8032cbb66b #28919, bb1a66a3a4 #38323, 283de2e4d4 #42603, 19a6e5b57b #42856, a9447cedbd #33221.

### 1.16 HTML preview width (small, default look: no)

HTML previews in a chat can grow wider than the messages, which stay centered. A client setting `htmlPreviewWidth` takes `chat`, `wide` or `full`, labeled "Match chat", "Wide" and "Full", with the description "Let HTML previews in a chat grow wider than its messages, which stay centered." (components/settings/AppearanceSettingsPanel.tsx:85-100, packages/contracts/src/settings.ts:425). The layout adds `htmlPreview: { left, width }` and drops to the chat width while the floating frame overlaps the chat (components/chat/chatCanvasLayout.ts:184).

- CW: no. Chat width lives in `Features/Settings/AppearanceSettingsView.swift`. The setting row is the other note's, the layout is here: `Features/Thread/HtmlRenderDialogView.swift` and the timeline lane.
- Commit: 14ea095b0a #41663.

### 1.17 Unread and sounds (small, default look: no)

A run that finishes in a window that is visible but not focused stays unread: the watermark now requires `visible && focused` (components/chat/ThreadVisitWatermark.tsx:17). The desktop app plays thread sounds after a reload (#41518, web audio unlock). Mark unread is hidden on threads with no completed run or while running (see 3.5).

- CW: partly. `T3Store/ThreadVisits.swift` and `T3Store/ThreadNotifications.swift` exist. Check that the visit rule requires focus as well as visibility.
- Commit: 0a7864c887 #42084.

### 1.18 Small behavior fixes (medium as a batch, default look: small)

- Restart agent session toast: "Your next message restarts the agent. This conversation is kept." (components/CommandPalette.tsx, #42880). CW strings are in `App/Sources/ComposerController.swift` and `App/Sources/PaletteCommands.swift`.
- Terminal excerpt chips localize their line range (#42886).
- Open subagent in Background work is an outline `Button size="sm"` (#38317).
- Project actions menu re-reads t3.json on every open (#42707). CW: `App/Sources/ProjectScriptsController.swift`.
- Open in file manager waits for a file preview to load, then reveals the file in its folder (#41877): `fileManagerActionForPath` returns `open`, `reveal` or `unavailable` (components/chat/OpenInPicker.logic.ts). CW: `Features/Thread/OpenInEditors.swift`, `App/Sources/OpenInController.swift`.
- Chat links open their menu from the keyboard (#37405, components/chat/MarkdownFileLink.tsx:366).
- The empty New thread screen shows a custom theme background (#40069). CW: `App/Sources/ThemeBackgroundController.swift`.
- MCP apps run only when their document hands over its bridge, and XML assets open sandboxed (#42504, #41745, packages/shared/src/mcpApp.ts). Check CW's MCP app host (`T3Store/ThreadMcpAppDownload.swift`, the WKWebView page) against it.
- A workflow step thread's header reads "{workflow} · {step}" with the relation "Step of the workflow run" and the action "Open run" (#38884). The workflows surface is the other note's.
- Commits: 8783b9d2ea #42880, 2891419b93 #42886, 7c42bb1c5c #38317, d38dcccef8 #42707, d36fb7d263 #41877, 7e624c0c8d #37405, f4b8be84a0 #40069, 2940ff33ad #42504, d4d08aed56 #41745, 69c1d53826 #38884, 26d81d88c1 #40076, e045a127e7 #42882.

## 2. Composer and pickers

### 2.1 A send waits for images to finish preparing (medium, default look: yes, redesign)

Pasting or dropping an image starts compression. Pressing Send while a tile is still preparing arms the send and shows an info banner with a spinner and a Cancel button. The send goes out when the tile is ready. Edit the draft or press Esc to cancel.

- T3: components/chat/ComposerHeldSendBanner.tsx:21 ("Sending message", or "Sending once image is ready" and "Sending once {count} images are ready"), description "Edit or press Esc to cancel", `Spinner size="xs"`, ghost `Button size="xs"` "Cancel". Esc handling at components/chat/ChatComposer.tsx:2571, banner wiring at :2823, `isSendHeld` at :4110, tile states in components/chat/preparingComposerImages.ts:14 and components/chat/ComposerAttachmentStrip.tsx:42 ("Preparing").
- Images over 2,000 px no longer stall on "Preparing" on a busy page (#42377, lib/imageCompression.worker.ts, lib/imageCanvas.ts), screenshots keep preparing after an unanswered question closes (#39569), and a send waits for uploads (#40672).
- CW: partly. `Features/Composer/ComposerAttachments.swift` and `Features/Composer/SnapShotPendingCapture.swift` exist. There is no held-send state or banner.
- Correction (port-composer): CW already held the send (`sendAfterPreparing`, #37547). What was missing was the banner, the button state and the cancel rules. Ported in 9499e23d. A model, provider, access or plan mode change cancels the hold since the port-composer leftovers commit (preparingComposerImages.ts:193-205).
- Commits: 3b3f8808f4 #40672, c3aacf1e5b #42377, 019e55bad5 #39569.

### 2.2 The Tab hint is a button (small, default look: yes)

The "Tab" kbd hint after a prompt suggestion is now a `button` with `aria-label` "Use suggested prompt", `pointer-events-auto ml-2 inline-flex cursor-pointer rounded align-[1px] [&:hover_kbd]:text-foreground`, and a click inserts the suggestion. A late click or Tab never prepends it to a draft that already has text (`promptSuggestionToAccept`, components/chat/ChatComposer.tsx:308, :3984). A wrapped suggestion no longer overlaps the toolbar: the placeholder and the editor share one grid cell (`grid grid-cols-[minmax(0,1fr)]`, `col-start-1 row-start-1`).

- CW: `Features/Composer/ComposerPromptSuggestion.swift` has the hint as plain drawing with no click target.
- Commits: 1d975f53ea #39488, 501e39d54a #40841, 3f08098c99 #40654.

### 2.3 Queued messages (medium, default look: small)

- Editing a queued message keeps its attachment chips resolved, lets you remove and restore them (#40945, `removedEditingAttachments`, components/chat/useQueuedRunEdit.ts:266), keeps its model choice (#41814) and keeps a reply-only edit when the message leaves the queue (#40763, `originalReplyTo`, components/chat/queuedMessageEdit.ts:106).
- Queue is offered for running sessions that cannot steer (#40767): `threadCanSteer` needs `supportsActiveSteering`, or `supportsInterrupt` with `supportsSteeringByInterruptRestart` (packages/client-runtime/src/state/threadWorkflows.ts).
- A slash command sent during a turn waits in the queue. Its send-now button tooltip reads "Move this command to the front of the queue ({shortcut})" instead of "Send into the current turn ({shortcut})" (#40316, components/chat/QueuedRunsControl.tsx:335). Goal commands keep the old tooltip.
- @-file mentions show by name in the stash menu, queued rows and sidebar drafts (#40924).
- CW: partly. `Features/Composer/QueuedRunEdits.swift`, `Features/Composer/QueuedRunsView.swift` and `Features/Composer/ComposerLogic.swift` (which has the steering capabilities) exist.
- Ported (port-composer): #40316 and #40767 in 357ba3b8, #40924 in 9ff295a2, #41814 in 31975590 (the edit picks under its own key, `followsThreadSelection` decodes, `queued-run.edit` carries `modelSelection`).
- Correction (port-composer): CW's queued edit has never had T3's 4928 baseline for attachments or replies. It edits text only, `queued-run.edit` goes without `attachments`, so the server keeps them, and a reply stays an inline reference in the edit's text. So #40763 has nothing to fix here: a reply can only change by editing that text. Left: attachments in queued edits, the 4928 baseline plus #40945 (large, 726 lines in T3), and the reply shown above the composer while editing (small).
- Commits: 87554a7b86 #40945, d572ce9afe #41814, d834a4e117 #40763, c3a330d834 #40767, c385377544 #40316, 9de4ec1bfa #40924.

### 2.4 Paste and drop (medium, default look: no)

Dropped text is parsed like pasted text, so Markdown and newlines match (#31098, components/ComposerPromptEditorTiptap.tsx `insertClipboardText`). Text copied from Word inserts text, not an image (#40686, `isImageOnlyClipboardHtml`). Pasting a chat message with text and a picture keeps both (#40909, `clipboardHtmlImageContent`, components/chat/composerAttachmentFiles.ts:254). After a paste, the caret lands after closing Markdown markers (#41327, `isPasteTransaction`).

- CW: partly. `Features/Composer/ComposerPasteboard.swift` and `Features/Composer/ComposerEditor.swift` handle `public.html`. Drop parsing and the Word case are unchecked.
- Commits: d9c7e6f7fc #31098, c1fbdf6cdb #40686, 2c4310eb06 #40909, face82e8b9 #41327.
- Ported (port-composer) in 8337eb04: #31098, #40686, #40909. Left: #41327, the caret after closing Markdown markers on a paste (small).

### 2.5 Typing, triggers and dictation (medium as a batch, default look: no)

- Moving the caret no longer opens suggestions (#37122).
- Typing while dictation holds the editor read-only writes nothing (#40253), file and thread chips can still be removed during dictation (#40252), the caret returns after dictation (#38224), and queued dictation goes to its original thread after you switch (#40553).
- The Compact chip does not show after /clear (#39133): it needs `!freshSessionPending`.
- Opening Settings with Cmd+, closes an open model picker (#29282).
- CW: partly. `Features/Composer/ComposerCompaction.swift`, `ComposerEditor.swift` and `ComposerMenuController.swift` exist, and `freshContext` is in `T3Protocol/Domain/ThreadProjection.swift`.
- Commits: 6908754f0b #37122, bb0d718b31 #40253, b19ca97827 #40252, 470ca63499 #38224, 4157f383f6 #40553, a1e7ac2b24 #39133, b3fff82014 #29282.
- Ported (port-composer) in e7a7413a: #37122, #39133, #29282 (Cmd+, closes every popup in the window). The four dictation fixes do not apply: CW has no dictation.

### 2.6 Model picker and effort (small, default look: small)

- Picker search finds a model by its ID (#42041, components/chat/ModelPickerContent.tsx:80 passes `slug`).
- Typing a letter in the effort list jumps to the matching row (#40798, components/chat/ComposerModelEffort.tsx:250).
- Codex "ultra" stays off the effort bar scale (#30810), `thought_level` and `role: reasoning` count in effort summaries (#40136), and custom OpenCode models can go back to the default reasoning level (#27333).
- A provider that needs an update shows a "Provider settings" link only when the install channel can update in Settings (#39966, ModelPickerContent.tsx:218).
- CW: `Features/Composer/ComposerEffortGlyph.swift` and `Features/Composer/ComposerMenus.swift`. Typeahead and slug search are unchecked.
- Commits: 2ced06ef4a #42041, 1acfd37c17 #40798, a891304c84 #30810, 9f9ebf61fb #40136, 39480b5c88 #27333, cf94598281 #39966.
- Ported (port-composer) in 8e80f42f: #42041, #40798. Left: #30810, #40136, #27333, #39966 (small each).

### 2.7 The @ menu and the thread link picker (small, default look: no)

The @ menu lists machines the thread's server links to (#40191). Thread link search folds accents (#39557). File names compose to NFC in chips and the menu (#39610).

- CW: `Features/Composer/ComposerMenus.swift`, `Features/Markdown/MarkdownContextChips.swift`.
- Commits: d9fdd02523 #40191, 732c03f410 #39557, e28b2819ee #39610.
- Ported (port-composer) in 6fa875f4: #39557. Left: #40191 machines in the @ menu (small), #39610 NFC names (small).

### 2.8 Keybinding conditions (small, default look: no)

A new `composerEmpty` when-condition is true when no queued edit is open, no question is pending, no non-prompt content is attached and the prompt is blank (#30644, components/ChatView.tsx). Mod+S stashes a side chat's prompt (#42295). The project action keybinding field records a shortcut instead of running it (#42543, `data-keybinding-capture`).

- CW: no `composerEmpty`. `Features/Settings/Keybindings.swift` and `KeybindingsLogic.swift` hold the conditions.
- Commits: 342b58a79f #30644, 921349decf #42295, 51a8d20271 #42543.
- Ported (port-composer) in 4871c2c9: #30644. Left: #42295 Mod+S in side chats, #42543 the project action shortcut field (small each).

### 2.9 Drafts and new threads (medium, default look: yes)

- A project whose worktrees use their own setup commands asks first: the send path awaits `ensureWorktreeLayoutApproved` and an alert dialog titled "Let this project run its worktree commands?" lists each command in a `pre` (`max-h-48 overflow-auto ... bg-muted/40 font-mono text-xs`) under "Runs when a worktree thread starts, and when its folder is restored" or "Runs when a thread's worktree is removed", with "Cancel" and "Approve and continue" (components/WorktreeLayoutApprovalDialogHost.tsx:42-79, worktreeLayoutApproval.ts, components/chat/useComposerSend.ts). The draft is compared across the wait.
- A No-project draft no longer offers New worktree: `offersWorkspaceModes` needs a non-scratch project that is a git repo or tracks repositories (components/BranchToolbar.logic.ts).
- CW: no for the dialog. The settings side (#42386) is the other note's. `App/Sources/ComposerController.swift` and `Features/Composer/NewThreadDraftLaunch.swift` are the send path.
- Commits: 924d9c1fff #42386, 9f24cac6d4 #41269.
- Ported (port-composer) in 41958980: the approval dialog and its send path, and #41269. The description sets `t3.json` as plain text, and the managed-policy check is left to the server's refusal.

## 3. Sidebar

### 3.1 Hide and restore the sidebar by dragging (medium, default look: yes, redesign)

Dragging the sidebar rail below a threshold hides it. The rail previews the collapse as you drag, and releasing past the threshold closes it. A restore handle on the left screen edge drags it back open.

- T3: components/ui/sidebar.tsx:35 (`SIDEBAR_COLLAPSE_DRAG_RATIO = 0.75`), :603-648 (collapse when `rawWidth < minWidth * (1 - 0.75)`, so below 25 percent of the minimum width; `data-sidebar-drag-state` flips between `collapsed` and `expanded`; release past it calls `setOpen(false)`), :429 (the handle only exists when `collapseOnResize` is on and the sidebar is collapsed on the left), :485-570 (`SidebarRestoreHandle`: a `fixed top-1/2 left-[8px] z-41 h-16 w-[16px] -translate-y-1/2` edge zone, a button `cursor-e-resize` with `before:inset-y-0 before:left-0 before:w-1/2 before:rounded-md before:bg-sidebar-border`, `opacity-0` until the pointer enters the zone, aria-label "Show sidebar", mouse only, restore when dragged to 48 px or more, a plain click opens it). components/AppSidebarLayout.tsx:487 sets `collapseOnResize: true`. components/chat/TimelineMinimap.tsx moves with it.
- The titlebar content shifts by `--workspace-titlebar-content-left` while the drag state says collapsed (workspaceTitlebar.ts).
- Behavior: a blur or interrupt mid-drag cancels the collapse (`cancelOnInterrupt`).
- CW: no. The sidebar split lives in `App/Sources/MainWindow.swift`. `Features/Sidebar/SidebarSortSession.swift` is a different drag.
- Ported in 1feaf560. The titlebar needs no shift in CW: its header already starts right of the traffic lights. Hover, the drag and the cursor are not checked on screen (they need the real pointer); SidebarDragCollapseTests drive the mouse events.
- Commit: 801b32f3a6 #29546.

### 3.2 Rows show the environment on the second line (small, default look: yes)

The thread row's meta line now starts with the environment's machine icon and label, not the branch with its worktree glyph. The old rule showed the label only for scratch threads without a branch. Now every row with a known environment label shows it, on every row.

- T3: components/sidebar/SidebarThreadRow.tsx:1272-1300. The meta line is `mt-0.5 flex min-w-0 items-center gap-1.5 text-secondary-label text-xs`. The environment part is `EnvironmentMachineIcon` at `size-3.5 shrink-0 text-icon-muted` and `<span className="min-w-0 flex-1 truncate">`. When there is no label the row keeps `<span className="flex-1" />`. The meta line is empty, and the trailing icons move to the title line, only when there is no label, no PR badge, no issue badge, no diff and no running terminal (:1279). The label comes from `environmentLabelById.get(thread.environmentId)` at components/Sidebar.tsx:3384 and :3593.
- The remote-machine icon that used to trail the title is gone.
- The hover card moves the worktree here: a `FolderGit2Icon size-3 shrink-0 stroke-muted-foreground` row with `MiddleTruncate` of the display path, after the branch row (SidebarThreadRow.tsx:349-354). The card order is project, environment, branch, worktree (:331-354).
- Ported in abb45d0c, for card, folder and Redesign rows. The whole-sidebar reference is recaptured from 5258 in `design/reference-5258/` (21dd98f3).
- Correction (port-composer): the meta line's diff counts never draw at 5258. `latestRunDiff` returns null for every thread (SidebarThreadRow.tsx:1761-1766), so CW shows none either.
- CW: partly. `Features/Sidebar/SidebarListModel.swift:57-61` has `scratchMachineLabel`, set only when `spansEnvironments` and the thread has no branch (:764). `Features/Sidebar/SidebarRowViews.swift:794` draws it. Replace that rule with the always-on label, drop the branch from the row, and add environment and worktree rows to `Features/Sidebar/SidebarThreadHoverCard.swift`. Recapture the sidebar row references.
- Commit: cd3a57ac72 #40736.

### 3.3 Folder button, Projects filter, scoped New (small, default look: yes)

- The sidebar folder button picks or adds a project: the scope menu gains an "Add project" item with `FolderPlusIcon`, which opens the Add project palette (components/Sidebar.tsx:192, :1090, `ADD_PROJECT_SCOPE_ITEM_VALUE`). The item row keeps a `ml-auto size-7 sm:size-6` spacer so it is as tall as project rows. The button's icon changes from the filter icon to `FolderIcon size-4`, and its label from "Filter threads by project: {projects}" to "Projects: {projects}", or "Projects".
- The sidebar New button starts the thread in the scoped project, and Shift starts without it (#35185, `resolveScopedNewThreadProjectRef`, Sidebar.tsx:208). It is off with the Boring sidebar.
- A grouped project's folder New thread starts on the viewed machine's copy (#41554).
- CW: partly. `App/Sources/PaletteAddProject.swift` and `Features/CommandPalette/` have Add project. The scope menu is in `Features/Sidebar/SidebarProjectScopeView.swift`.
- Ported in 11e1c196. Redesign keeps its own Add project button and filter glyph by the Threads label. Not ported: the New button's "New thread in current project: Shift+click" tooltip line, which predates 4928 and CW never had.
- Commits: dbb5bdb582 #33057, 46ee2fc7ff #35185, 1c9ccc7127 #41554.

### 3.4 Drafts in jumps, and drafts with terminals stay listed (small, default look: no)

Numbered thread jumps and next/previous thread include unsent drafts (#39968): draft rows join `orderedRowKeys` as `draft:<id>` ahead of threads (components/Sidebar.tsx:1480). A draft with a running terminal stays listed in the sidebar (#25272, `useDraftTerminalLabels`, components/sidebar/SidebarDraftBlock.tsx:48).

- CW: no. `App/Sources/SidebarCommands.swift` holds the jumps. `Features/Sidebar/SidebarListModel.swift` builds the rows.
- Commits: 5093d11490 #39968, 1e78f37618 #25272.
- Ported (port-composer) in b7631e26: #39968. Left: #25272 drafts with a running terminal (small).

### 3.5 Order, settle, offline and menu rules (medium as a batch, default look: small)

- Settling a thread no longer jolts the list when the list is scrolled to the end: the animation tracks `scrollTop` and shifts rows by the clamp (components/Sidebar.motion.ts:27, #26661). CW: the sidebar list animation in `Features/Sidebar/SidebarListView.swift`.
- Quick clicks on different threads open each one: the trailing double-click only counts on the route's own thread (#41258, Sidebar.tsx:196).
- Right-click on a search result opens the thread actions (#31545).
- Mark unread is hidden when the thread has no completed run or is running (#41365, components/threadActionMenu.logic.ts:117). CW: `T3Store/ThreadActions.swift`.
- Settle and snooze work while the thread's machine is offline, and the row reads "Pending" with the tooltip "Waiting to sync with its environment" (#24917, components/sidebar/SidebarThreadRow.tsx:164).
- Threads can be dragged above threads from a disconnected machine: unarranged threads take an implied sort key from their anchor time (#41885, packages/client-runtime/src/state/threadSort.ts:266).
- A worktree thread of a project with tracked folders keeps its branch when git says the folder is no repository (#35925, components/Sidebar.logic.ts).
- Snooze labels follow the app language (#39494).
- Commits: bcb9217e8e #26661, 5812320a6a #41258, 42d2387285 #31545, 92199680cc #41365, 78de041d48 #24917, 9331811180 #41885, 60863edc41 #35925, 67f17528f2 #39494.
- Ported (port-composer) in fa78d3d4: #41365, #31545, #41258, #26661. Correction: #35925's sidebar rule needs nothing, CW never drops a thread's branch on a non-repository status (T3's `withoutRemovedCheckout` is an older gap the other way). #39494 needs nothing, CW is English only. Left: #24917 offline settle and snooze, an outbox of 1,171 lines (large), and #41885 implied sort keys for unarranged threads (medium).

### 3.6 Update capsule in narrow sidebars (small, default look: yes)

The sidebar update capsule shrinks to a 32 px round icon in narrow sidebars and grows to its label with a 200 ms width transition. Seven commits tuned it.

- T3: components/sidebar/SidebarUpdateCapsule.tsx:103-182. Collapsed it is `relative ml-auto flex h-8 w-8 shrink-0 items-center justify-end rounded-full bg-sidebar-control-surface text-sidebar-foreground transition-[width] duration-200`. It becomes `w-full` at `@min-[5rem]/sidebar-update`, or at `@min-[12rem]` while the restart countdown shows (`restartSeconds !== null`). The label is `hidden min-w-0 flex-1 truncate pl-3 text-xs transition-opacity duration-200 ease-out starting:opacity-0` and shows from the same width. The action link is `hidden shrink-0 cursor-pointer pr-3 pl-1.5 text-xs underline decoration-muted-foreground/60 underline-offset-3`. The countdown replaces the icon as "{seconds}s" (:182).
- Update-all rules: a restored failed run can retry (#41964), a skipped server says why: "turned off" or the connection error (components/sidebar/updateEverything.logic.ts:158, #41672), a desktop server it cannot reach says "update T3 Code on that machine" (#33030), and a rollback after an app update is reported (#33002). The provider update pill does not recount dismissed updates (#39636).
- CW: partly. `Features/Sidebar/SidebarUpdatePill.swift`, `Features/Sidebar/UpdateEverythingLogic.swift` and `App/Sources/UpdateEverything.swift` exist. CW has no capsule width states.
- Commits: 40c1e861ee, dea657a0b1, 5aae5578de, 1425613b9d, 4be39cf01a, f0f9de46c6, 98af8803fe (no PR numbers), 66259ff051 #41964, 74c6d21c7a #41672, 8ef195587d #33030, d7ae1e1791 #33002, d5a084c440 #39636.

### 3.7 Issue and PR badges share one component (small, default look: yes)

The sidebar PR and issue badges use one `ThreadLinkBadge` (`contents font-normal text-xs tabular-nums` with the tone class), and its text follows the status icon's color instead of `text-secondary-label` (#27167). A grouped issue shows its status from `useSidebarLinkedIssueState` over all linked issues (#39351).

- T3: components/ThreadStatusIndicators.tsx, components/sidebar/SidebarThreadRow.tsx.
- CW: `Features/Sidebar/SidebarIssueBadgeView.swift` and `Features/PullRequests/PullRequestBadgeView.swift`.
- Commits: 571ed76fc3 #42275, b5e1f91cba #27167, 29b42d409c #39351.

### 3.8 Tooltips on scroll, time width (small, default look: no)

Project picker tooltips fade in place on scroll instead of sliding away (#42657, `holdPositionOnExit`, components/ui/tooltip.tsx). Sidebar search times use `min-w-8` and no longer wrap in translated languages (#42011).

- CW: `Features/Sidebar/SidebarSearchRowViews.swift`.
- Commits: 221953fbf3 #42657, 28d8a63d7f #42011.
- Ported (port-composer) in 75700d91: #42011. Correction: CW sized the time to its text, so short times widened the title. Left: #42657 (small).

## 4. Command palette

### 4.1 The open thread's actions (medium, default look: yes)

Cmd+K lists the open thread's menu actions as rows: Find in thread, Pin or Unpin thread, Settle or Unsettle thread, Snooze (a submenu with Custom), Wake thread, Regenerate title, Mark unread, Share with guest, Copy (a submenu: path, branch, thread, thread ID), Archive and more. They come from the same menu model as the sidebar's context menu, so a new thread action shows up in both.

- T3: components/CommandPaletteThreadActions.tsx:51 (`SKIPPED` drops Rename and Project settings), :53 (`SHORTCUTS`: settle and unsettle `thread.settle`, pin and unpin `thread.pin`, regenerate-title `thread.regenerateTitle`), :62 (`useCommandPaletteThreadActions`), :100-107 (row: `value: thread-action:<id>`, `title: item.label`, icon from the menu's icon name, `description: item.detail`, `disabled`, shortcut, `checked`). A menu item with children becomes a submenu whose group label is the item's label and whose addon icon is the same icon. Wiring at components/CommandPalette.tsx:787. Items: components/threadActionMenu.logic.ts:164-320. Default keys: packages/shared/src/keybindings.ts:136 (`mod+shift+s` settle) and :137 (`mod+shift+p` pin).
- Icons map: archive, circle-check, clock, copy, folder, folder-plus, git-branch, hash, mail-open, message-square, message-square-plus, pin, pin-off, refresh-cw, timer, trash.
- Correction (port-composer, 2026-11-25): the palette's menu passes no find handler and `canShareWithGuest: false` (CommandPaletteThreadActions.tsx:66, useThreadActionMenu.ts), so Find in thread and Share with guest are not among these rows. The palette's own "Find in current thread" and "Share with guest" rows stay. The rows sit after Restart agent session (CommandPalette.tsx:1621). Ported in bff82880. Since the leftovers commit, the auto-settle submenu reads "Follow settings" and "Never" (threadActionMenu.logic.ts:270-279), and a snooze preset's time is its `detail`: the palette's second line, the themed menu's shortcut column (contextMenuFallback.ts:490-498) and "label (time)" in native menus (ElectronMenu.ts:81-83).
- CW: no. `App/Sources/PaletteCommands.swift` has "Find in current thread", "Rewrite title" (CandyWrapper's own, per docs/decisions.md) and "Copy thread reference" as separate rows. `T3Store/ThreadActions.swift` and `Features/Sidebar/DitherThreadMenu.swift` hold the menu model. Keep Rewrite title in place of Regenerate title.
- Commit: 95411e3cd7 #40742.

### 4.2 Add project from a draft moves the draft (small, default look: no)

Opening Add project from a draft's project picker remembers the draft. After the project is added, a draft with content moves to it and does not stay behind (#42889, lib/moveDraftToProject.ts, `OpenAddProject` carries `draftId`, components/CommandPalette.tsx).

- CW: no. `App/Sources/PaletteAddProject.swift`, `Features/Composer/NewThreadDraftLaunch.swift`.
- Commit: 83a7c75b88 #42889.
- Ported (port-composer) in df350067. A just-created project may not be in the shell yet, so the draft keys by its project id until it arrives.

### 4.3 A quoted query finds its words together (small, default look: no)

A query wrapped in straight or curly double quotes, longer than two characters, matches its words together as typed, for example `"fix sidebar"`. Single quotes and backticks still wrap and unwrap as before.

- T3: packages/shared/src/paletteSearch.ts (`isExactQuery`, `unwrapQuery`, `foldSearchQuery` keeps straight double quotes for exact queries), components/chat/threadFindStore.ts.
- CW: `Features/CommandPalette/PaletteScoring.swift` and `T3Store/ThreadSearch.swift` strip all wrapping quotes.
- Correction (port-composer): this is medium, not small. The commit rewrites 234 lines of paletteSearch.ts scoring and touches the server's ThreadSearch.
- Ported (port-composer) in 8eebfe14: titles, branches and other fields. A 4928 server strips the quotes and answers the words apart, which the palette still shows. Left: the exact message match (`EXACT_PHRASE_GAP`, `findExactPhrase`) and the in-thread find (small to medium).
- Commit: 62e8042b21 #37700.

### 4.4 Keys in the palette (small, default look: no)

Holding Esc closes the file or content search and stops on the palette: a repeating Escape is cancelled (components/CommandPalette.tsx:350, #42279). Backspace leaves a submenu only on a plain, non-repeating, non-IME press with an empty query (:2828, #42205).

- CW: `Features/CommandPalette/CommandPaletteController.swift`.
- Ported in 8a847157.
- Commits: 51a721da44 #42279, ccdafe1f61 #42205.

### 4.5 Project picker eligibility (small, default look: no)

The palette's project picker and the contextual project use `pickableProjectGroups` and `isPickableProjectMember`, so an archived copy is never the target (#38984).

- CW: `Features/Sidebar/SidebarProjectOrder.swift`, `App/Sources/PaletteCommands.swift`.
- Commit: c9359f6535 #38984.
- Ported (port-composer) in a1ae5918: the groups were already pickable, the open project's archived copy was not skipped.

## 5. Commit table

Status values: `port` names the note above. `n/a` gives the reason in a few words. No commit is `not read`: I read the diff or the changed lines of every row, though the small rows only in part. The area comes from the files, so treat it as a hint.

| Commit | PR | Subject | Area | Status |
|---|---|---|---|---|
| c4d0e05d96 | #42535 | fix(server): agents below Full access ask before a push runs repository hooks | thread | ported 956f0e5a (push hooks details under the question, inline and child approvals; the server rule itself needs no client change) |
| 96423cb5e2 | #43026 | fix(server): stop reading Antigravity usage limits from Google's internal APIs | thread | n/a (server reads Antigravity limits) |
| cbc3057f59 | #42921 | fix(web,mobile): a running Read's image shows a loading frame, not "Image unavailable" | thread | ported 255b7394 (a running Read's image holds the 16:9 loading frame without asking for the file; Redesign shows its skeleton) |
| 7d8c03fd99 | #42948 | fix(terminal): keep other input out of large bracketed pastes | other | n/a (terminal, other agent) |
| a3a4592cf5 | #42897 | fix(web): release terminal reply ownership when the drawer closes | other | n/a (terminal, other agent) |
| 67918f51cc | #42919 | fix(web): Show more in Thread Details keeps every repository listed | thread | left: repository sections need T3's thread-repositories runtime (task folders, pins, a git control per repository). L, about 2 h |
| 2891419b93 | #42886 | fix(web): localize terminal excerpt line ranges | composer | nothing to port: English only, and CW's chip already reads "{terminal} line N" or "lines N-M" (ComposerMenus.swift:859) |
| 83a7c75b88 | #42889 | fix(web,mobile): adding a project from a draft's picker no longer leaves the draft behind | palette | ported df350067 |
| e045a127e7 | #42882 | fix(web): web search result links follow Open links in | thread | ported 3f79fad2 |
| 8783b9d2ea | #42880 | fix(web): Restart agent session toast says the conversation is kept | palette | ported 2995f10a |
| 172309c39c | #42876 | fix(web): timeline minimap no longer covers the Copy button when the chat lane is shifted left | thread | already: `layoutMinimap` takes the gutter from `laneFrame.x`, the measured lane offset |
| 19a6e5b57b | #42856 | fix(web): clicking outside a citation comment keeps its dictation | thread | n/a here: same composer citation editor |
| 3a63e0ca37 | #42771 | fix(web): expanding linked issues no longer hides thread details sections | thread | ported d414425c (issue rows sit in their own list; the other sections stay) |
| f99eceb76d | #42755 | fix(web): reasoning previews no longer cut emojis in half | thread | already: Swift slices previews by character, so no surrogate pair splits |
| d38dcccef8 | #42707 | fix(web): project actions menu re-reads t3.json each time it opens | thread | ported f4fddadf (the actions menu, inline and in Redesign's header menu, reads t3.json again on every open and keeps the scripts read before until the new read lands) |
| 9eaac040de | #42697 | test(web): sidebar shift guard tests no longer race the click against fake time | sidebar | n/a (test only) |
| 9b671699d4 | #42582 | perf(web): thread switches paint the timeline in their first frame | thread | n/a (React render speed) |
| 221953fbf3 | #42657 | fix(web): fade project picker tooltips in place on scroll | sidebar | port (3.8) |
| 95411e3cd7 | #40742 | feat(web): settle, pin, snooze and more for the current thread from cmd+k | palette | ported bff82880 |
| 3e74a0aac5 | #41210 | fix(antigravity): link directly to Google account verification on failed turns | thread | ported 0dfe2558 |
| 283de2e4d4 | #42603 | fix(web): citation comment box stays open when its cited row scrolls out | thread | n/a here: the citation comment box is the composer's citation chip editor, composer agent |
| 89047261b1 | #42574 | fix(web): Option and Cmd arrows reach full-screen terminal apps | other | n/a (terminal, other agent) |
| 6667f3c089 | #42575 | fix(web): timeline minimap previews no longer cut an emoji in half | thread | already: ThreadMinimapView's `prefix(1_500)` counts characters |
| 62e8042b21 | #37700 | feat(search): a query in double quotes finds its words together | palette | ported 8eebfe14 (fields); message match left |
| 801b32f3a6 | #29546 | feat(web): hide and restore the sidebar by dragging | sidebar | ported 1feaf560 |
| 51a8d20271 | #42543 | fix(web): project action keybinding field records shortcuts instead of running them | composer | port (2.8) |
| b6869fad67 | #30664 | feat(terminal): Add keybindings for cycling through terminals | other | n/a (terminal, other agent) |
| ea63274413 | #42489 | chore(deps): bump vite-plus to 1.8.0 | other | n/a (dependency bump) |
| 2940ff33ad | #42504 | fix(web): MCP apps run only when their document hands over its bridge | thread | ported 7a0e6330 (an MCP app whose first message is not its document's port gets no bridge and shows T3's "needs a newer server" line; tested in a live web view) |
| c3aacf1e5b | #42377 | fix(web): pasted images over 2000 px no longer stall on "Preparing" on busy pages | composer | n/a (web canvas worker; CW prepares images with ImageIO off the main thread) |
| 78de041d48 | #24917 | fix: settle and snooze threads while their machine is offline | sidebar | left: offline outbox (large) |
| dfa73216cc | #42429 | fix(web): search results show the matched lines | thread | ported d11002d4 (not seen on screen: the sandbox turn used Bash grep) |
| 16742ca802 | #41291 | feat(usage): support user-hosted HTTP quota sources | thread | ported d414425c (the card's quota rows; snapshots' `http` sources decode; the Usage page's quota section is still left) |
| 924d9c1fff | #42386 | feat(projects): worktree layout commands run only once a person approves them | composer | ported 41958980 |
| eb7cc44727 | #42309 | fix(web): showing or hiding a requested secret keeps the caret in place | thread | ported f15f9c8d |
| 571ed76fc3 | #42275 | fix(web): sidebar issue and pull request badges share one component | sidebar | port (3.7) |
| 921349decf | #42295 | fix(web): Mod+S stashes a side chat's prompt | composer | port (2.8) |
| 51a721da44 | #42279 | fix(web): a held Esc in file or content search stops on the Command Palette | palette | ported 8a847157 |
| 41675b3e4d | #42286 | fix(web): floating preview no longer covers the last timeline rows on a narrow chat | thread | n/a until CW has T3's floating preview frame over the chat (`chatCanvasLayout` `overlapsChat`); CW's lane has no such overlay |
| ff7d03ddfd | #42265 | fix(client-runtime): omit failed image reads from viewed-image previews | thread | ported 255b7394 |
| e9b227b021 | #42183 | fix(web): typing / or $ in the composer no longer waits for the suggestion menu to render | composer | n/a (React render timing) |
| ccdafe1f61 | #42205 | fix(web): held or modified Backspace no longer leaves a Command Palette submenu | palette | ported 8a847157 |
| 7c42bb1c5c | #38317 | fix(web): Open subagent in Background work looks like a button | thread | n/a here: CW has no Background work dialog (`BackgroundWorkDetails.tsx`); its banner and Redesign's waiting menu link the subagents directly. Port with the dialog |
| d7ae1e1791 | #33002 | fix(web): report server rollback after an app update | sidebar | port (3.6) |
| 6f6b978667 | #41963 | fix(web): image preview closes with an × again instead of a Back button | thread | ported 255b7394, reference recaptured from 5258 in the next commit with the popup's titlebar inset and centering |
| 0a7864c887 | #42084 | fix(web): a run finishing in a background window stays unread | thread | ported 98004311 |
| 74d73ac23f | #42048 | fix(web): a thread link to an unconnected environment shows why instead of a blank pane | thread | ported d9f298a4 (unit tested and seen on screen from a synthetic test build in dark and Redesign) |
| 28d8a63d7f | #42011 | fix(web): sidebar search times no longer wrap in translated languages | sidebar | ported 75700d91 |
| 2ced06ef4a | #42041 | fix(web): model picker search finds a model by its ID | composer | ported 8e80f42f |
| a891304c84 | #30810 | fix(web): keep Codex Ultra off the effort bar scale | composer | port (2.6) |
| 66259ff051 | #41964 | fix(web): a failed server update restored after the app relaunches can retry | sidebar | port (3.6) |
| 74c6d21c7a | #41672 | fix(web): the update dialog says why a server was skipped | sidebar | port (3.6) |
| a6c69be8df | #41927 | fix(web,mobile): a parent parked on subagents no longer reads as Thinking | thread | ported ad384d3e (the server half, #38869, is not a client change) |
| ff6b10e0a0 | #41928 | feat: starting providers show their real startup step and logo | thread | ported 3a1892b1 and 816b0031 + eec3b345 (the starting row before the server has a run, from the unconfirmed optimistic send and the composer's selected instance; unit tested, not seen on screen) |
| b3fff82014 | #29282 | fix(web): Settings opened with Cmd+, no longer leaves the model picker open over it | composer | ported e7a7413a |
| 8032cbb66b | #28919 | fix(web): Cmd+F searches a side chat, and Escape closes it | thread | ported d727b761: Cmd+F already searched a side chat (its ComposerController registers chat.find on the pane's table, run while focus is in the pane); Escape anywhere in the chat or side chat now closes find through `cancelOperation`. Not driven on screen |
| a4029d4b91 | #41899 | fix(web): an IME Escape no longer dismisses the citation highlight | thread | n/a (AppKit handles IME) |
| 9331811180 | #41885 | fix(clients): threads can be dragged above threads from a disconnected machine | sidebar | left: implied sort keys (medium) |
| 3d9a14d4da | #41875 | fix(web): IME keys no longer trigger or close the prompt stash menu | composer | n/a (AppKit handles IME) |
| 8dc01892ad | #41886 | fix(server): answering a secret request with a reference needs provider management | thread | n/a (CW has no reference sources, so the card is always typed) |
| d36fb7d263 | #41877 | fix(web): Open in file manager waits for a file preview to load, then shows the file in its folder | thread | left for the files agent: the change is in the file preview's Open in picker (`fileManagerActionForPath`, FilePreviewPanel.tsx), which is FilesController's. Small |
| 14ea095b0a | #41663 | feat(web): add an HTML preview width setting separate from chat width | thread | ported bc4d8e34 (wide 72rem and full, centered on the lane and clear of the details card; unit tested, not seen on screen: no HTML preview in the sandboxes) |
| 4508c70681 | #41843 | fix(web): opening a thread lands at its end instead of jumping there | thread | already: a `.thread` change sets `followsEnd` before the anchor is taken, so the restore and every later footer change land at the end (test `aSwitchedThreadOpensAtItsEndWithoutLandingShort`) |
| 4162207ddd | #29771 | fix(web): file menu opens remote files over SSH instead of on the server | thread | n/a (web icons, wire A18) |
| 8ef195587d | #33030 | fix(web): tell update-all users where to update desktop servers it can't reach | sidebar | port (3.6) |
| d9c7e6f7fc | #31098 | fix(web): dropped text is parsed like pasted text in the composer | composer | ported 8337eb04 |
| d572ce9afe | #41814 | fix(chat): preserve model choices when editing queued messages | composer | ported 31975590 |
| 7e6a871a00 | #41798 | fix(web): Lineage panel shows elapsed time for subagents on linked machines | thread | left for the details agent: CW's Lineage has no remote subagent rows yet (`RemoteSubagentRow`, ThreadRelationshipsControl.tsx:300-370), and the section is Features/Git's `ThreadLineageSectionView`. Small with the rows |
| c5918e5d24 | #41803 | fix(web): align composer banner details with status text | composer | already: CW's details button shares the 24pt row with the text, so it is centered |
| eecb58c6d6 | #41769 | fix: approvals and hosted pairing show what is being approved | composer | ported 956f0e5a for the approval half; `draftSupportedRuntimeModes` is the composer's (2.x), hosted pairing the other note's |
| 46f360d8dd | #41722 | fix(client): a link to a newly linked machine's thread opens without a reload | thread | ported 7c048ec6: a link naming a machine the cached peerLinks.names lack reads the names once more (`refreshNamesLacking`) |
| 78cffe29ec | #41761 | fix: a merge or review stays on the commit you opened the pull request on | other | n/a (pull requests, other agent) |
| 5e62206e7d | #41757 | fix(desktop): preview pages run in their own JavaScript world and popups open web links only | thread | n/a (Electron only) |
| d4d08aed56 | #41745 | fix: XML assets open sandboxed and MCP apps bind to their document | thread | ported 7a0e6330 for the MCP app half (`attachMcpAppDocumentLink` in the bridge's isolated world, probes over the document's port); XML assets opening sandboxed is server side |
| 1c6d41a9ba | #41317 | feat(web,mobile): remove the changed-files card under assistant turns | thread | ported 31bbc675 |
| cdb0e238ed | #41674 | fix(web): keyboard-opened context menus start on their first action | other | n/a (AppKit native menus) |
| b5e1f91cba | #27167 | fix(web): color sidebar PR text to match status icons | sidebar | port (3.7) |
| 36ecdeb851 | #41597 | fix(web): an unavailable work-log image keeps the 10rem strip instead of filling the row | thread | ported 255b7394 (CW drops a failed viewed image from the row, so only the loading frame keeps the strip) |
| da7d298fae | #41582 | fix(web): triple-click selects the whole line past draggable file chips | thread | n/a (Chromium CSS quirk) |
| a369642c1c | #41578 | fix(web): keys pressed on a focused video stay with the player | composer | n/a (web focus redirect) |
| 1c9ccc7127 | #41554 | fix(web): a grouped project's folder New thread starts on the viewed machine's copy | sidebar | ported 11e1c196 |
| 3b08d975ab | #41518 | fix(web): the desktop app plays thread sounds after a reload | thread | n/a (web audio unlock) |
| 7e624c0c8d | #37405 | fix(web): chat links open their menu from the keyboard on macOS | thread | n/a: a Chromium on macOS workaround for Shift+F10 on focused links; CW's Markdown links take no keyboard focus |
| 92199680cc | #41365 | fix(web): hide Mark unread on threads with no completed run | sidebar | ported fa78d3d4 |
| face82e8b9 | #41327 | fix(web): caret lands after closing Markdown markers after a paste | composer | left (small) |
| f4c38ca3e7 | #27236 | fix(web): remote open uses the environment's saved SSH route | thread | n/a (SSH route, wire A18) |
| 9f24cac6d4 | #41269 | fix(web): No project drafts no longer offer New worktree | composer | ported 41958980 |
| 10765a4e47 | #41262 | fix(web): a refused desktop install shows as failed instead of downloaded | sidebar | n/a (desktop updater, Electron) |
| 5812320a6a | #41258 | fix(web): quick clicks on different sidebar threads open each one | sidebar | ported fa78d3d4 |
| 611410683b | #41242 | feat(cursor): show which step Cursor is in while a turn starts | thread | ported 3a1892b1 |
| e6ae5810a3 | #41184 | fix(web): preserve reading position when side panels resize | thread | ported 7a68cd54 (the text line, not a contenteditable caret: CW's timeline has none) |
| 69c1d53826 | #38884 | feat: workflows on web and mobile | thread | n/a here: the workflow step header ("{workflow} · {step}", Open run) belongs to the workflows agent |
| 7103527dcc | #41073 | fix(web): PR description file links resolve in the PR's repository from a No-project thread | thread | left: CW renders PR bodies in the pull request views (other agent), which pass no checkout cwd yet. Small |
| 0938476b95 | #41060 | fix(web): Thinking row no longer shows below a streaming reply | thread | ported ad384d3e |
| a3323d4a43 | #41070 | perf(web): new thread opens its draft without waiting on t3.json | composer | n/a (React load order) |
| fe9c98c98f | #35871 | feat: agents can report T3 Code problems when you turn feedback on | thread | ported 47f71d35 (not seen on screen: needs a turn that asks for feedback with feedback on) |
| dbb5bdb582 | #33057 | feat(web): sidebar folder button picks or adds a project | sidebar | ported 11e1c196 |
| 67f17528f2 | #39494 | fix(web): snooze labels follow the app language | sidebar | nothing to port: English only |
| c7df7004af | #41021 | fix(web): a photo picked on a phone attaches even when the composer collapses | composer | n/a (phone photo picker) |
| 55880c41b4 | #40986 | fix(client-runtime): count ambiguous projects in chat file links | thread | ported dd1cfae1 |
| 87554a7b86 | #40945 | fix(web): editing a queued message keeps its attachment chips resolved | composer | left: CW edits text only, no 4928 attachment baseline (large) |
| 7ddc81d639 | #40905 | fix(web): tool calls stay grouped after a usage-limit pause again | thread | ported 00aa8a70 |
| 9de4ec1bfa | #40924 | fix(web,mobile): @-file mentions show by name in message previews, not as raw links | composer | ported 9ff295a2 |
| 2c4310eb06 | #40909 | fix(web): pasting a chat message with text and a picture keeps both | composer | ported 8337eb04 |
| 1e78f37618 | #25272 | fix(web): keep script-only drafts reachable in the sidebar | sidebar | port (3.4) |
| 501e39d54a | #40841 | fix(web): clicking the Tab hint inserts short prompt suggestions again | composer | ported 0a35f251 |
| bcb9217e8e | #26661 | fix(web): settling a thread no longer jolts the sidebar list | sidebar | ported fa78d3d4 |
| d834a4e117 | #40763 | fix(web): preserve reply-only edits when a queued message leaves the queue | composer | nothing to port: the reply stays in the edit text |
| d27d29fe2d | #31295 | fix(web): lineage show-more no longer clips the last row or drops focus | thread | left for the details agent: Lineage show-more lives in Features/Git's `ThreadLineageSectionView`. Small |
| 671e05bc8c | #40768 | fix(issues): an Activity cross-reference opens the issue or pull request it came from | other | n/a (issues, other agent) |
| 1acfd37c17 | #40798 | fix(web): restore effort picker keyboard typeahead | composer | ported 8e80f42f |
| c3a330d834 | #40767 | fix(web): show Queue for running sessions that cannot steer | composer | ported 357ba3b8 |
| cd3a57ac72 | #40736 | feat(web): sidebar thread rows show the environment instead of the branch | sidebar | ported abb45d0c, reference 21dd98f3 |
| 11224f63d2 | #40703 | fix(client-runtime): a new thread's first message and a queued send-now or steer survive a dropped socket | composer | n/a (resend rule, wire section 5) |
| 4ac5e6e791 | #40682 | fix(client-runtime): typing a bare Windows drive lists its folders | palette | n/a (Windows drive paths) |
| 3b3f8808f4 | #40672 | fix(web): wait for image uploads before sending | composer | ported 9499e23d |
| c1fbdf6cdb | #40686 | fix(web): pasting text copied from Word inserts the text instead of an image | composer | ported 8337eb04 |
| 0fb6ac6e65 | #27866 | perf(web): Markdown renders with Words as static islands under one shared tooltip; remark leaves the web app | thread | n/a (markdown render speed) |
| 3f08098c99 | #40654 | fix(web): wrapped prompt suggestion no longer overlaps the composer toolbar | composer | left (2.2: wrapped suggestion overlap, not checked on screen) |
| a9447cedbd | #33221 | fix(web): Cite button appears as fast after a double-click as after a drag | thread | ported d33f7446 (CW already showed Cite at once; a multi-click now anchors it under the selection) |
| 76b421864b | #40628 | fix(web): Ctrl+click in the composer no longer outlines the whole line | composer | n/a (web editor selection) |
| 10586f9e31 | #40594 | feat: read feature flags from one T3CODE_FEATURE_FLAGS service | other | n/a (feature flags, wire A9) |
| 4157f383f6 | #40553 | fix(web): send queued dictation to original thread after switching th… | composer | nothing to port: no dictation |
| 1cedd4b4ed | #37314 | fix(web): scheduled task times follow the Time format setting | other | n/a (scheduled tasks, other agent) |
| 8cf94f2542 | #40390 | fix(web): a modified click on a remote server opens it after forwarding | thread | n/a (desktop port forward) |
| c385377544 | #40316 | fix(server): slash commands sent during a turn wait instead of steering | composer | ported 357ba3b8 (client tooltip) |
| 47525fa3d6 | #40215 | fix(web): switching threads no longer restarts the Changes and git status reads | other | n/a (git reads, other agent) |
| bb0d718b31 | #40253 | fix(web): typing and pasting no longer write into the read-only composer during dictation | composer | nothing to port: no dictation |
| b19ca97827 | #40252 | fix(web): inline file and thread chips can be removed during dictation | composer | nothing to port: no dictation |
| 1425613b9d | - | fix(web): keep restart seconds visible in narrow sidebars | sidebar | port (3.6) |
| 4be39cf01a | - | fix(web): keep the update icon in place while the capsule shrinks | sidebar | port (3.6) |
| dea657a0b1 | - | fix(web): show the update capsule at default sidebar width with a short grow-in | sidebar | port (3.6) |
| 5aae5578de | - | fix(web): show the update capsule label in narrower sidebars | sidebar | port (3.6) |
| 9f9ebf61fb | #40136 | fix(client-runtime): recognize thought_level and role: reasoning in effort summaries | composer | port (2.6) |
| f4b8be84a0 | #40069 | fix(web): show custom theme backgrounds on the empty New thread screen | thread | already: CW's timeline paints no background of its own, and ThreadPanelView goes clear while a theme image shows (ThreadPanelView.swift:313). Not checked on screen |
| d9fdd02523 | #40191 | fix(client-runtime): @ menu offers machines the thread's server links to | composer | port (2.7) |
| cf94598281 | #39966 | fix(client-runtime): don't ask for a provider update the install channel lacks | composer | port (2.6) |
| 60863edc41 | #35925 | feat(projects): a project covers several repositories | sidebar | nothing to port in the sidebar: CW keeps the branch |
| cfb720fa8a | #40131 | fix(web): guest share status expires at exact timestamp instead of start of minute | other | n/a (guest share, other agent) |
| 39480b5c88 | #27333 | fix(opencode): custom models can go back to the default reasoning level | composer | port (2.6) |
| 73e6472545 | #24583 | fix(client-runtime): recover thread messages after a failed resume | thread | already for the resume (ThreadSession.applyWire drops the cursor on a failed apply, the next subscribe takes a snapshot); the composer sync line's error is left, composer area |
| aa6fe390db | #40042 | fix(web): dismissing a local thread error no longer suppresses repeat errors | thread | ported fe5d9cd0 |
| bac0508e08 | #38895 | feat(web): thread chips show the sidebar's thread card on hover | thread | ported 32609bf7 for chips in sent messages; the composer's chips and their "On another machine" line are the composer agent's (Features/Composer) |
| e8b28328da | #29681 | feat(web): duplicate browser tabs from the context menu | other | n/a (browser tabs, other agent) |
| b9879ede83 | #33286 | feat(web): copy a chat table as HTML | thread | ported dd1cfae1 (unaligned columns say left: Foundation reports no "none" alignment) |
| 26d81d88c1 | #40076 | fix(web): timeline row actions stay put on hover, and notices expand only when cut off | thread | ported 239ed38d (the row's chevron and click follow the cut-off check; not seen on screen) |
| e28b2819ee | #39610 | fix(shared): compose NFD file names in link chips and the @ menu | composer | port (2.7) |
| 9ab7da2a3e | #34646 | fix(web): screen readers can read expanded tool output | thread | n/a (web screen reader markup) |
| af99412e9d | #24603 | fix(web): keep file path tooltips open for selection | thread | n/a (web tooltip hover) |
| 5093d11490 | #39968 | fix(web): numbered jumps and next/previous thread include unsent drafts | sidebar | ported b7631e26 |
| e7b1b88bef | #37274 | fix(web): IME composition replaces selected text beside chips | composer | n/a (AppKit handles IME) |
| 46ee2fc7ff | #35185 | feat(web): sidebar New starts the thread in the scoped project | sidebar | ported 11e1c196 |
| 1d975f53ea | #39488 | feat(web): click the Tab hint to use the suggested prompt | composer | ported 0a35f251 |
| c436409da0 | #30778 | fix: proxied usage limits follow the hub's model routing and show on the thread card | thread | ported d414425c (the card's hub pool; the report keeps 4928's driver match, see the ponytail in UsageLimits.swift) |
| 342b58a79f | #30644 | feat(web): add a composerEmpty keybinding condition | composer | ported 4871c2c9 |
| 285558eb10 | #34027 | feat(desktop): dictate on this Mac with Apple Speech | composer | n/a (desktop IPC, wire A19) |
| 669d8941e2 | #39921 | feat: sign in to an agent's MCP server from its warning | thread | ported ca680ce9 (seen offscreen only: no sandbox MCP server needs a login) |
| 3027c2c840 | #40011 | fix(voice): start dictation capture sooner on iOS and desktop | composer | n/a (web audio capture) |
| 6908754f0b | #37122 | fix(web): caret navigation no longer opens composer suggestions | composer | ported e7a7413a |
| 8d37736cdd | #39889 | fix(web,mobile): usage-limit recovery banner updates copy after reset passes | thread | ported fe5d9cd0 |
| 7c6e889ddb | #39515 | feat: subagents, side chats and linked threads open the same way | thread | ported 7c048ec6 for linked threads opening as a panel tab; subagents and side chats keep their own paths. Left: the shared open intent (alternate click to the main screen), small |
| d7f6b3efca | #39439 | feat: connect to a linked environment from its read-only thread | thread | ported d55ba5d3 (pairClient with access:write, address probes, pairing, the three notices and Enter code; unit tested, the notices seen on screen from a synthetic build, the real round trip not run) |
| 1cb3a8c753 | #39406 | feat: read a linked environment's threads from the client | thread | ported 7c048ec6 (read-only panel tab: peerLinks.subscribeThread while it shows, threadHistoryPage paging, threadItem rows, ReadOnlyComposerBar, failure copy and the 15 s retry; seen on screen against two linked 5258 sandboxes). Left: the main-screen page for `sideThreadOpenTarget` main (LinkedThreadPage.tsx), medium |
| 9294a9801e | #39837 | fix(acp,web): stop showing "Running Ran" for commandless ACP tool calls | thread | ported ad384d3e |
| 0bc9b57b93 | #31257 | feat: secret cards get a show/hide toggle and multi-value fields | thread | ported f15f9c8d (multi-value fields were already in from the wire port) |
| d5a084c440 | #39636 | fix(web): the provider update pill no longer recounts dismissed updates | sidebar | port (3.6) |
| 019e55bad5 | #39569 | fix(composer): keep screenshots preparing after an unanswered question closes | composer | left (2.1: screenshot preparing after a question closes, not checked) |
| 732c03f410 | #39557 | fix(web): fold accents in thread link picker search | composer | ported 6fa875f4 |
| 22936ae669 | #39552 | fix(web): ignore superseded microphone refreshes in voice setup | composer | n/a (web mic setup) |
| 29b42d409c | #39351 | fix(web): show status for grouped sidebar issues | sidebar | port (3.7) |
| 3a60d0996a | #38869 | fix(server): background subagents can delegate after their parent's turn ends | thread | ported 5aa812be (the client half: a subagent card after the turn's reply adds no turn time; the server half needs no client change) |
| bb1a66a3a4 | #38323 | feat(web): reference a side chat from its main thread with Add to chat and @ | thread | n/a here: the @ menu and Add to chat are the composer's (composerThreadItems.ts), composer agent |
| 5872b0a488 | #37419 | fix(web): a later thread error with the same text shows its banner again | thread | ported fe5d9cd0 (source is the shell's latest run and its end time, not the failure item; ponytail marker) |
| dcf158c591 | #39415 | feat(server): setting and managed policy to turn off the preview tunnel | other | n/a (preview tunnel, wire A10) |
| 420d1b5900 | #39393 | feat(desktop): forward another environment's ports to this machine | palette | n/a (desktop IPC, wire A19) |
| 296f9131f7 | #39340 | fix(web): Cmd+W closes the browser tab when the page has focus | other | n/a (browser tabs, other agent) |
| b111b6310a | #39232 | fix(web): collapse extra linked issues in thread details | thread | ported d414425c (compact issue rows with state, key, tracker and comments; the first row, the rest behind Show N more) |
| 98af8803fe | - | refactor(web): share restart countdown seconds in update capsule | sidebar | n/a (refactor) |
| f0f9de46c6 | - | fix(web): localize compact restart countdown | sidebar | port (3.6) |
| 40c1e861ee | - | fix(web): keep sidebar update control readable when narrow | sidebar | port (3.6) |
| 3b199e77fb | #39308 | fix: index displayed file line ranges in thread search | thread | ported dd1cfae1 (CW had no range label at all: chips now show `L42–64`; image destinations as file chips are not indexed) |
| c5badf4e40 | #39305 | fix(web): scope Git controls to the active checkout | other | n/a (git controls, other agent) |
| 73caab68e3 | #38912 | fix(client): commands run as Effects on the caller's fiber, so interrupting a caller stops them | other | n/a (client effects refactor) |
| 5bc2d512e4 | #39295 | fix(web): scroll wide tables to the selected Find match | thread | already: wide tables share the code blocks' `.scroll` item, so `activeFindRect` scrolls them (test added in dd1cfae1) |
| 42d2387285 | #31545 | fix(web): right-clicking a sidebar search result now opens its thread actions | sidebar | ported fa78d3d4 |
| a1e7ac2b24 | #39133 | fix(web): the Compact chip no longer shows after /clear | composer | ported e7a7413a |
| ff9efe89f6 | #39150 | fix(web): copying items within one list keeps their list markers | thread | ported dd1cfae1 (markers only: CW's selection copy is still plain text, not T3's Markdown serializer) |
| b6afe8109c | #39146 | fix(web): home paths like ~/.claude/CLAUDE.md no longer show under the workspace folder | thread | ported dd1cfae1 |
| d067a04175 | #39130 | fix(web): a slow chat file link no longer replaces a file opened from the picker | thread | ported dd1cfae1 |
| 470ca63499 | #38224 | fix(web): restore the composer caret after dictation | composer | nothing to port: no dictation |
| 2c7bfcec84 | #38225 | fix(desktop): restore clicks across the floating dictation controls | composer | n/a (Electron drag region) |
| c9359f6535 | #38984 | fix(mobile): project picker starts a chat in an open copy, not an archived one | palette | ported a1ae5918 |

Counts: 147 port, 45 n/a, 0 already, 0 not read, 192 in all. By area: composer 52, other 17, palette 9, sidebar 34, thread 80.

## 6. Port order

Sorted by how much a daily user sees it. Sizes: S small, M medium, L large.

1. 3.2 Rows show the environment (S). Every row changes. Recapture sidebar references.
2. 1.3 Changed-files card removed (S). Every assistant turn changes. Recapture user and assistant message references.
3. 3.6 Update capsule (S).
4. 3.3 Folder button, Projects label, scoped New (S).
5. 4.1 Palette thread actions (M).
6. 3.1 Sidebar drag to hide, restore handle (M, redesign).
7. 1.2 Provider startup step and logo (M, redesign).
8. 2.1 Held send while images prepare (M, redesign).
9. 2.2 Tab hint button (S).
10. 1.10 Reading position, open at end, minimap, floating preview (M).
11. 1.9 Run state rules, banners and recovery (M).
12. 2.3 Queued messages (M).
13. 1.4 Secret cards (M, redesign). Do it with wire B3, which is a break.
14. 1.8 Thread details card (M).
15. 1.13 Search results with matched lines (M).
16. 2.4 Paste and drop (M).
17. 1.1 Linked threads read-only (L, redesign). Needs wire A6.
18. 1.5 Agent feedback card (M, redesign).
19. 1.6 MCP sign-in and Google verify (M, redesign).
20. The rest: 1.7, 1.11, 1.14, 1.15, 1.16, 1.17, 2.5 to 2.9, 3.4, 3.5, 3.7, 3.8, 4.2 to 4.5, and the 1.18 batch.

Sizes per group:

| Group | Small | Medium | Large | Agent time |
|---|---|---|---|---|
| Thread and timeline (1.1 to 1.18) | 7 | 10 | 1 | about 9 h |
| Composer and pickers (2.1 to 2.9) | 4 | 5 | 0 | about 5 h |
| Sidebar (3.1 to 3.8) | 6 | 2 | 0 | about 3 h |
| Command palette (4.1 to 4.5) | 4 | 1 | 0 | about 1.5 h |
| Total | 21 | 18 | 1 | about 18.5 h |

Agent time counts 15 minutes per small, 45 per medium and 2 hours per large. Plus about 1 hour of review for the fidelity recaptures in items 1, 2, 3 and 4.

Items with a break or a new server field behind them: 1.4 (wire B3), 1.1 (wire A6), 1.2 (wire A7), 1.5 (wire A4), 1.6 (wire A5), 1.8 (wire A11). Everything else works against a 4928 server.

## What I could not settle by reading

- Whether CW has a citation comment editor with dictation (1.15). I found `AssistantSelectionToolbar.swift` but no comment box.
- Whether CW's MCP app host binds messages to a document the way #42504 and #41745 require (1.18).
- Whether CW's visit watermark already requires window focus (1.17).
- Which of the 2.4 paste cases CW already handles: drop parsing, Word HTML, text with a picture.
- The exact gating of the linked-thread surfaces beyond the wire methods: T3 hides them without a capability check I could find in the pane itself, so confirm with a 5258 server (1.1).
